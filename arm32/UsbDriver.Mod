MODULE UsbDriver;  

(*
 Native Oberon ARM DWC2 (DesignWare USB 2.0 OTG) host controller support
 for Raspberry Pi 2/3 (BCM2835/BCM2836/BCM2837).

 Replaces UsbUhci.Mod (Intel UHCI) with the Synopsys DesignWare USB 2.0
 OTG controller found on BCM283x SoCs.  Uses memory-mapped registers
 instead of PCI I/O ports.
 The following code is a synthesis from these sources: 
 Synopsys DesignWare Cores USB 2.0 OTG Databook
 USPi bare-metal driver by R. Stange https://github.com/rsta2/uspi
 https://github.com/Chadderz121/csud
 https://github.com/torvalds/linux/tree/master/drivers/usb/dwc2

 (c) 2026 Rochus Keller <mailto:me@rochus-keller.ch>

 GNU General Public License Usage
 This file may be used under the terms of the GNU General Public
 License (GPL) versions 2.0 or 3.0 as published by the Free Software
 Foundation and appearing in the file LICENSE.GPL included in
 the packaging of this file. Please review the following information
 to ensure GNU General Public Licensing requirements will be met:
 http://www.fsf.org/licensing/licenses/info/GPLv2.html and
 http://www.gnu.org/copyleft/gpl.html.
*)

IMPORT Usb, SYSTEM, Kernel;

CONST
  traceDebug = FALSE;

  MaxControllers = 1;  (* RPi has only one USB controller *)
  NumChannels = 8;     (* DWC2 on BCM2835 has 8 host channels *)

  (** BCM2835 DWC2 USB controller base address (RPi 2/3 peripheral space) *)
  USBBase = 3F980000H;

  (** Core Global Registers (offsets from USBBase) *)
  rGOTGCTL    = 000H;  (* OTG Control and Status *)
  rGOTGINT    = 004H;  (* OTG Interrupt *)
  rGAHBCFG    = 008H;  (* AHB Configuration *)
  rGUSBCFG    = 00CH;  (* USB Configuration *)
  rGRSTCTL    = 010H;  (* Reset Control *)
  rGINTSTS    = 014H;  (* Interrupt Status *)
  rGINTMSK    = 018H;  (* Interrupt Mask *)
  rGRXFSIZ    = 024H;  (* Receive FIFO Size *)
  rGNPTXFSIZ  = 028H;  (* Non-Periodic TX FIFO Size *)
  rGNPTXSTS   = 02CH;  (* Non-Periodic TX FIFO Status *)
  rGVENDORID  = 040H;  (* Vendor ID *)
  rGHWCFG2    = 048H;  (* Hardware Config 2 *)
  rGHWCFG3    = 04CH;  (* Hardware Config 3 *)
  rGHPTXFSIZ  = 100H;  (* Host Periodic TX FIFO Size *)

  (** rGAHBCFG bits *)
  bAhbGlblIntrEn = 0;     (* bit 0: Global interrupt enable *)
  bAhbDmaEn       = 5;     (* bit 5: DMA enable *)
  bAhbWaitAxi     = 4;     (* bit 4: Wait for AXI writes, BCM2835 *)

  (** rGUSBCFG bits *)
  bUsbPhyIf     = 3;
  bUsbUlpiSel  = 4;
  bUsbSrp       = 8;
  bUsbHnp       = 9;
  bUsbUlpiFsls = 17;
  bUsbUlpiClk  = 19;
  bUsbUlpiVbus = 20;
  bUsbTermSel  = 22;
  bUsbForceHost = 29;

  (** rGRSTCTL bits *)
  bRstCsftrst      = 0;     (* Core soft reset *)
  bRstRxfflsh      = 4;     (* RX FIFO flush *)
  bRstTxfflsh      = 5;     (* TX FIFO flush *)
  rstTxfnumShift = 6;     (* TX FIFO number shift *)
  bRstAhbidle      = 31;    (* AHB master idle *)

  (** rGINTSTS / rGINTMSK bits *)
  bIntSof          = 3;     (* Start of Frame *)
  bIntRxflvl       = 4;     (* RX FIFO non-empty *)
  bIntNptxfemp     = 5;     (* Non-periodic TX FIFO empty *)
  bIntPrtint       = 24;    (* Host port interrupt *)
  bIntHcint        = 25;    (* Host channels interrupt *)
  bIntConidchg     = 28;    (* Connector ID status change *)
  bIntDisconn      = 29;    (* Disconnect detected *)

  (** Host Registers (offsets from USBBase) *)
  rHCFG       = 400H;  (* Host Configuration *)
  rHFIR       = 404H;  (* Host Frame Interval *)
  rHFNUM      = 408H;  (* Host Frame Number *)
  rHPTXSTS    = 410H;  (* Host Periodic TX FIFO Status *)
  rHAINT      = 414H;  (* Host All Channels Interrupt *)
  rHAINTMSK   = 418H;  (* Host All Channels Interrupt Mask *)
  rHPRT       = 440H;  (* Host Port Control and Status *)

  (** rHPRT bits *)
  bPrtConn      = 0;   (* Port Connect Status *)
  bPrtConnDet   = 1;   (* Port Connect Detected *)
  bPrtEna       = 2;   (* Port Enable *)
  bPrtEnaChg    = 3;   (* Port Enable Changed *)
  bPrtOca       = 4;   (* Overcurrent *)
  bPrtOcaChg    = 5;   (* Overcurrent Changed *)
  bPrtRes       = 6;   (* Port Resume *)
  bPrtSusp      = 7;   (* Port Suspend *)
  bPrtRst       = 8;   (* Port Reset *)
  bPrtPwr       = 12;  (* Port Power *)
  prtSpdShift = 17;  (* Port Speed shift *)
  prtSpdMask  = 3;   (* Port Speed mask (2 bits) *)
  spdHigh = 0;
  spdFull = 1;
  spdLow  = 2;

  (** Host Channel Registers (each channel offset by 20H) *)
  rHCCHAR0    = 500H;   (* Channel 0 Characteristics *)
  rHCSPLT0    = 504H;   (* Channel 0 Split Control *)
  rHCINT0     = 508H;   (* Channel 0 Interrupt *)
  rHCINTMSK0  = 50CH;   (* Channel 0 Interrupt Mask *)
  rHCTSIZ0    = 510H;   (* Channel 0 Transfer Size *)
  rHCDMA0     = 514H;   (* Channel 0 DMA Address *)
  chanStep   = 020H;   (* Offset between channels *)

  (** HCCHAR bits *)
  charMpsMask = 7FFH;         (* Max Packet Size mask, bits 0..10 *)
  charEpnumShift = 11;        (* Endpoint Number shift *)
  charEpnumMask  = 0FH;       (* Endpoint Number mask *)
  bCharEpdirIn    = 15;        (* bit 15: Endpoint Direction IN *)
  bCharLsdev       = 17;        (* bit 17: Low-speed device *)
  charEptypeShift = 18;       (* Endpoint Type shift *)
  charEptypeMask = 3;         (* Endpoint Type mask *)
  eptControl   = 0;
  eptIso       = 1;
  eptBulk      = 2;
  eptInterrupt = 3;
  charMcShift    = 20;        (* Multi Count shift *)
  charDevaddrShift = 22;      (* Device Address shift *)
  charDevaddrMask = 7FH;      (* Device Address mask *)
  bCharOddfrm      = 29;        (* bit 29: Odd frame *)
  bCharChdis       = 30;        (* bit 30: Channel Disable *)
  bCharChen        = 31;        (* bit 31: Channel Enable *)

  (** HCTSIZ bits *)
  tsizXfersizeMask = 7FFFFH;  (* Transfer size mask, bits 0..18 *)
  tsizPktcntShift  = 19;      (* Packet Count shift *)
  tsizPktcntMask   = 3FFH;    (* Packet Count mask, bits 19..28 *)
  tsizPidShift     = 29;      (* PID shift *)
  tsizPidMask      = 3;       (* PID mask, bits 29..30 *)
  pidData0 = 0;
  pidData2 = 1;
  pidData1 = 2;
  pidSetup = 3;
  pidMdata = 3;

  (** HCINT bits (channel interrupt status) *)
  bHcXfercomp    = 0;   (* Transfer Complete *)
  bHcChhltd      = 1;   (* Channel Halted *)
  bHcAhberr      = 2;   (* AHB Error *)
  bHcStall       = 3;   (* Stall Response *)
  bHcNak         = 4;   (* NAK Response *)
  bHcAck         = 5;   (* ACK Response *)
  bHcNyet        = 6;   (* NYET Response *)
  bHcXacterr     = 7;   (* Transaction Error *)
  bHcBblerr      = 8;   (* Babble Error *)
  bHcFrmovrun    = 9;   (* Frame Overrun *)
  bHcDatatglerr  = 10;  (* Data Toggle Error *)

  (** Mailbox for USB power on *)
  mboxBase   = 3F00B880H;
  mboxStatusOfs = 18H;
  mboxWriteOfs  = 20H;
  mboxReadOfs   = 0;
  mboxFull   = 80000000H;
  mboxEmpty  = 40000000H;
  mboxChanProp = 8;

  (** Power management tag *)
  tagSetPower = 28001H;
  tagEnd = 0;
  deviceUSB = 3;

TYPE

  Dwc2Controller = POINTER TO RECORD (Usb.UsbController)
    idx: INTEGER;
    portCount: INTEGER;
    portSpeed: INTEGER;  (* speed of device on root port *)
    chanAllocated: SET;  (* one bit per channel *)
    TReqList: Usb.UsbTReq;
  END;

  Dwc2ConSpec = POINTER TO RECORD (Usb.UsbConSpecData)
    chan: INTEGER;       (* allocated channel number, or -1 *)
  END;

VAR
  FirstController: Dwc2Controller;
  ControllerCount: INTEGER;
  mbufRaw: ARRAY 80 OF CHAR;  (* mailbox buffer *)



PROCEDURE -GetWord(adr: LONGINT): LONGINT;
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  LDR R0, [R0, #0]
END GetWord;

PROCEDURE -PutWord(adr, val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #4]
  LDR R1, [SP, #0]
  STR R1, [R0, #0]
END PutWord;

(** DSB SY = 0xF57FF04F *)
PROCEDURE -DSB;
CODE {SYSTEM.arm}
  DCW 0F04FH, 0F57FH
END DSB;

(** DMB SY = 0xF57FF05F *)
PROCEDURE -DMB;
CODE {SYSTEM.arm}
  DCW 0F05FH, 0F57FH
END DMB;



PROCEDURE ReadReg(offset: LONGINT): LONGINT;
BEGIN
  RETURN GetWord(USBBase + offset)
END ReadReg;

PROCEDURE WriteReg(offset, val: LONGINT);
BEGIN
  PutWord(USBBase + offset, val)
END WriteReg;

PROCEDURE SetBits(offset: LONGINT; bits: SET);
VAR v: LONGINT;
BEGIN
  v := ReadReg(offset);
  v := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, v) + bits);
  WriteReg(offset, v)
END SetBits;

PROCEDURE ClearBits(offset: LONGINT; bits: SET);
VAR v: LONGINT;
BEGIN
  v := ReadReg(offset);
  v := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, v) - bits);
  WriteReg(offset, v)
END ClearBits;

PROCEDURE TestBits(offset: LONGINT; bits: SET): BOOLEAN;
BEGIN
  RETURN SYSTEM.VAL(SET, ReadReg(offset)) * bits # {}
END TestBits;



PROCEDURE PrintHex(was: LONGINT);
VAR z, d, h, i: LONGINT;
BEGIN
  z := 0;
  d := 16*16*16*16*16*16*16;
  FOR i := 0 TO 7 DO
    h := (was DIV d) MOD 16;
    IF (z = 1) OR (h # 0) OR (i = 7) THEN
      z := 1;
      IF h < 10 THEN Kernel.WriteInt(h, 0) ELSE Kernel.WriteChar(CHR(ORD("A") + h - 10)) END
    END;
    d := d DIV 16
  END
END PrintHex;

PROCEDURE MilliWait(ms: LONGINT);
VAR t: Kernel.MilliTimer;
BEGIN
  Kernel.SetTimer(t, ms);
  REPEAT UNTIL Kernel.Expired(t)
END MilliWait;



PROCEDURE MboxWriteMsg(data, channel: LONGINT);
BEGIN
  DMB;
  WHILE SYSTEM.VAL(SET, GetWord(mboxBase + mboxStatusOfs)) * SYSTEM.VAL(SET, mboxFull) # {} DO END;
  PutWord(mboxBase + mboxWriteOfs, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) + SYSTEM.VAL(SET, channel)));
  DMB
END MboxWriteMsg;

PROCEDURE MboxReadMsg(channel: LONGINT): LONGINT;
VAR data: LONGINT;
BEGIN
  LOOP
    DMB;
    WHILE SYSTEM.VAL(SET, GetWord(mboxBase + mboxStatusOfs)) * SYSTEM.VAL(SET, mboxEmpty) # {} DO END;
    data := GetWord(mboxBase + mboxReadOfs);
    DMB;
    IF SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) * {0..3}) = channel THEN
      RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) - SYSTEM.VAL(SET, data) * {0..3})
    END
  END
END MboxReadMsg;

PROCEDURE PowerOnUSB(): BOOLEAN;
VAR mbuf, resp, i: LONGINT;
BEGIN
  mbuf := SYSTEM.ADR(mbufRaw[0]);
  mbuf := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, mbuf + 15) - {0..3});

  i := 0;
  PutWord(mbuf + i, 32); INC(i, 4);       (* total size = 32 bytes *)
  PutWord(mbuf + i, 0); INC(i, 4);        (* request code *)
  PutWord(mbuf + i, tagSetPower); INC(i, 4);  (* tag: Set Power State *)
  PutWord(mbuf + i, 8); INC(i, 4);        (* value buffer size *)
  PutWord(mbuf + i, 0); INC(i, 4);        (* request indicator *)
  PutWord(mbuf + i, deviceUSB); INC(i, 4);  (* device ID = 3 = USB HCD *)
  PutWord(mbuf + i, 3); INC(i, 4);        (* state: bit0=on, bit1=wait *)
  PutWord(mbuf + i, tagEnd); INC(i, 4);   (* end tag *)

  DSB;
  MboxWriteMsg(mbuf, mboxChanProp);
  resp := MboxReadMsg(mboxChanProp);
  DSB;

  resp := GetWord(mbuf + 4);
  IF resp # SYSTEM.VAL(LONGINT, 80000000H) THEN
    Kernel.WriteString("UsbDriver: power on mailbox failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Check power state response *)
  resp := GetWord(mbuf + 24);
  IF SYSTEM.VAL(SET, resp) * {0} = {} THEN
    Kernel.WriteString("UsbDriver: USB power on failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  RETURN TRUE
END PowerOnUSB;



PROCEDURE AllocateChannel(con: Dwc2Controller): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO NumChannels - 1 DO
    IF ~(i IN con.chanAllocated) THEN
      INCL(con.chanAllocated, i);
      RETURN i
    END
  END;
  RETURN -1
END AllocateChannel;

PROCEDURE FreeChannel(con: Dwc2Controller; ch: INTEGER);
BEGIN
  IF (ch >= 0) & (ch < NumChannels) THEN
    EXCL(con.chanAllocated, ch)
  END
END FreeChannel;



PROCEDURE WaitForBit(offset: LONGINT; bit: INTEGER; set: BOOLEAN; ms: LONGINT): BOOLEAN;
VAR t: Kernel.MilliTimer;
BEGIN
  Kernel.SetTimer(t, ms);
  LOOP
    IF set THEN
      IF TestBits(offset, {bit}) THEN RETURN TRUE END
    ELSE
      IF ~TestBits(offset, {bit}) THEN RETURN TRUE END
    END;
    IF Kernel.Expired(t) THEN RETURN FALSE END
  END
END WaitForBit;

PROCEDURE FlushTxFIFO(fifo: LONGINT);
VAR val: LONGINT;
BEGIN
  val := SYSTEM.VAL(LONGINT, {bRstTxfflsh} + SYSTEM.VAL(SET, ASH(fifo, rstTxfnumShift)));
  WriteReg(rGRSTCTL, val);
  IF ~WaitForBit(rGRSTCTL, bRstTxfflsh, FALSE, 100) THEN
    Kernel.WriteString("UsbDriver: TX FIFO flush timeout"); Kernel.WriteLn
  END;
  MilliWait(1)
END FlushTxFIFO;

PROCEDURE FlushRxFIFO;
BEGIN
  WriteReg(rGRSTCTL, SYSTEM.VAL(LONGINT, {bRstRxfflsh}));
  IF ~WaitForBit(rGRSTCTL, bRstRxfflsh, FALSE, 100) THEN
    Kernel.WriteString("UsbDriver: RX FIFO flush timeout"); Kernel.WriteLn
  END;
  MilliWait(1)
END FlushRxFIFO;

PROCEDURE ResetCore(): BOOLEAN;
BEGIN
  (* Wait for AHB idle *)
  IF ~WaitForBit(rGRSTCTL, bRstAhbidle, TRUE, 100) THEN
    Kernel.WriteString("UsbDriver: AHB not idle"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Soft reset *)
  SetBits(rGRSTCTL, {bRstCsftrst});
  IF ~WaitForBit(rGRSTCTL, bRstCsftrst, FALSE, 100) THEN
    Kernel.WriteString("UsbDriver: core soft reset timeout"); Kernel.WriteLn;
    RETURN FALSE
  END;

  MilliWait(100);
  RETURN TRUE
END ResetCore;

PROCEDURE InitCore(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  (* Configure USB: internal PHY, UTMI+, 8-bit *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bUsbUlpiSel, bUsbPhyIf,
      bUsbUlpiClk, bUsbUlpiFsls, bUsbUlpiVbus, bUsbTermSel});
  WriteReg(rGUSBCFG, val);

  (* Reset after PHY selection *)
  IF ~ResetCore() THEN RETURN FALSE END;

  (* Configure AHB: no DMA for slave mode, enable global interrupts later *)
  val := ReadReg(rGAHBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bAhbDmaEn, bAhbGlblIntrEn});
  (* BCM2835 specific: Wait for AXI writes *)
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bAhbWaitAxi});
  WriteReg(rGAHBCFG, val);

  (* No HNP/SRP *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bUsbHnp, bUsbSrp});
  WriteReg(rGUSBCFG, val);

  RETURN TRUE
END InitCore;

PROCEDURE InitHost(): BOOLEAN;
VAR val, rxfsiz, nptxfsiz: LONGINT;
BEGIN
  (* Force host mode *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bUsbForceHost});
  WriteReg(rGUSBCFG, val);
  MilliWait(50);

  (* Host config: 48 MHz PHY clock for full-speed *)
  val := ReadReg(rHCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {0, 1});  (* clear FSLSPCLKSEL *)
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {0});      (* FSLSPCLKSEL = 1 = 48 MHz *)
  WriteReg(rHCFG, val);

  (* Configure FIFOs - dynamic FIFO sizing *)
  rxfsiz := 1024;
  nptxfsiz := 1024;

  WriteReg(rGRXFSIZ, rxfsiz);
  WriteReg(rGNPTXFSIZ, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(nptxfsiz, 16)) + SYSTEM.VAL(SET, rxfsiz)));
  WriteReg(rGHPTXFSIZ, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(nptxfsiz, 16)) + SYSTEM.VAL(SET, rxfsiz + nptxfsiz)));

  (* Flush all FIFOs *)
  FlushTxFIFO(10H);  (* flush all TX FIFOs *)
  FlushRxFIFO;

  (* Disable all channel interrupts *)
  WriteReg(rHAINTMSK, 0);

  (* Clear any pending interrupts *)
  WriteReg(rGINTSTS, SYSTEM.VAL(LONGINT, {0..31}));

  RETURN TRUE
END InitHost;

PROCEDURE EnableRootPort(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  (* Power on root port *)
  val := ReadReg(rHPRT);
  (* Clear write-to-clear bits to avoid side effects *)
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg});
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bPrtPwr});
  WriteReg(rHPRT, val);
  MilliWait(50);

  RETURN TRUE
END EnableRootPort;

PROCEDURE ResetRootPort(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  (* Assert reset *)
  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg});
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bPrtRst});
  WriteReg(rHPRT, val);

  MilliWait(60);  (* USB spec requires 50ms min *)

  (* Deassert reset *)
  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg, bPrtRst});
  WriteReg(rHPRT, val);

  MilliWait(20);

  RETURN TRUE
END ResetRootPort;


(*  Poll a channel until transfer completes or timeout *)
PROCEDURE WaitForChannelComplete(ch: INTEGER; timeout: LONGINT): SET;
VAR t: Kernel.MilliTimer; chint: SET; intofs, val: LONGINT;
BEGIN
  intofs := rHCINT0 + ch * chanStep;
  Kernel.SetTimer(t, timeout);
  LOOP
    chint := SYSTEM.VAL(SET, ReadReg(intofs));
    
    (* Exit loop on Success or Hard Errors *)
    IF (bHcXfercomp IN chint) OR (bHcStall IN chint) OR 
       (bHcAhberr IN chint) OR (bHcBblerr IN chint) THEN
      EXIT
    END;
    
    (* Handle Channel Halt *)
    IF bHcChhltd IN chint THEN
      IF bHcNak IN chint THEN
        (* NAK received: device busy. Clear flags and retry immediately *)
        WriteReg(intofs, SYSTEM.VAL(LONGINT, {bHcNak, bHcChhltd}));
        val := ReadReg(rHCCHAR0 + ch * chanStep);
        val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChen} - {bCharChdis});
        WriteReg(rHCCHAR0 + ch * chanStep, val)
      ELSE
        (* Halted for an unknown reason (e.g. timeout) *)
        EXIT
      END
    END;

    IF Kernel.Expired(t) THEN
      (* Disable channel on timeout *)
      SetBits(rHCCHAR0 + ch * chanStep, {bCharChdis});
      MilliWait(1);
      chint := SYSTEM.VAL(SET, ReadReg(intofs));
      EXIT
    END
  END;
  (* Clear all channel interrupts before returning *)
  WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
  RETURN chint
END WaitForChannelComplete;

(* Convert DWC2 channel interrupt bits to Usb result codes *)
PROCEDURE TranslateStatus(chint: SET): SET;
VAR status: SET;
BEGIN
  status := {};
  IF bHcXfercomp IN chint THEN status := Usb.ResOK END;
  IF bHcStall IN chint THEN status := status + Usb.ResStalled END;
  IF bHcXacterr IN chint THEN status := status + Usb.ResCRCTimeout END;
  IF bHcBblerr IN chint THEN status := status + Usb.ResBabble END;
  IF bHcAhberr IN chint THEN status := status + Usb.ResDataBuffer END;
  IF bHcDatatglerr IN chint THEN status := status + Usb.ResBitStuff END;
  IF bHcNak IN chint THEN status := status + Usb.ResNAK END;
  IF status = {} THEN
    IF (bHcChhltd IN chint) & ~(bHcXfercomp IN chint) THEN
      status := Usb.ResCRCTimeout  (* timeout/halt without transfer complete *)
    END
  END;
  RETURN status
END TranslateStatus;

(* Program and enable a DWC2 host channel for a single transaction *)
PROCEDURE StartChannel(ch: INTEGER; dev: Usb.UsbDevice; endpoint, eptype: INTEGER;
    dirIn: BOOLEAN; pid: INTEGER; buffer, buflen: LONGINT; mps: INTEGER);
VAR charVal, tsizVal: LONGINT; pktcnt: LONGINT; base: LONGINT;
BEGIN
  base := ch * chanStep;

  (* Clear pending interrupts *)
  WriteReg(rHCINT0 + base, SYSTEM.VAL(LONGINT, {0..31}));

  (* Enable all channel interrupts for polling *)
  WriteReg(rHCINTMSK0 + base, SYSTEM.VAL(LONGINT,
    {bHcXfercomp, bHcChhltd, bHcAhberr, bHcStall,
     bHcNak, bHcAck, bHcXacterr, bHcBblerr, bHcDatatglerr}));

  (* No split transactions for root port direct connections *)
  WriteReg(rHCSPLT0 + base, 0);

  (* Build HCCHAR *)
  charVal := mps;  (* bits 0..10: max packet size *)
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) +
    SYSTEM.VAL(SET, ASH(endpoint MOD 16, charEpnumShift)));
  IF dirIn THEN
    charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharEpdirIn})
  END;
  IF dev.LowSpeed THEN
    charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharLsdev})
  END;
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) +
    SYSTEM.VAL(SET, ASH(eptype, charEptypeShift)));
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) +
    SYSTEM.VAL(SET, ASH(1, charMcShift)));  (* multi count = 1 *)
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) +
    SYSTEM.VAL(SET, ASH(dev.Address, charDevaddrShift)));

  WriteReg(rHCCHAR0 + base, charVal);

  (* Build HCTSIZ *)
  IF buflen > 0 THEN pktcnt := (buflen + mps - 1) DIV mps
  ELSE pktcnt := 1
  END;
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, buflen) * SYSTEM.VAL(SET, tsizXfersizeMask));
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, tsizVal) +
    SYSTEM.VAL(SET, ASH(pktcnt, tsizPktcntShift)));
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, tsizVal) +
    SYSTEM.VAL(SET, ASH(pid, tsizPidShift)));

  WriteReg(rHCTSIZ0 + base, tsizVal);

  (* For slave mode (no DMA), we need to write data to FIFO manually for OUT.
    But QEMU DWC2 model supports DMA - use buffer address directly *)
  WriteReg(rHCDMA0 + base, buffer);

  DSB;

  (* Enable channel *)
  charVal := ReadReg(rHCCHAR0 + base);
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharChen} - {bCharChdis});
  WriteReg(rHCCHAR0 + base, charVal);

  DSB
END StartChannel;



PROCEDURE DoControlTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR
  ch: INTEGER;
  chint, status: SET;
  pid: INTEGER;
  dirIn: BOOLEAN;
  mps: INTEGER;
  restlen, curlen, databuf: LONGINT;
  datatoggle: BOOLEAN;
  timeout: LONGINT;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  mps := req.Device.Descriptor.bMaxPacketSize0;
  IF mps = 0 THEN mps := 8 END;
  timeout := req.Timeout;
  IF timeout = 0 THEN timeout := 5000 END;
  IF timeout = -1 THEN timeout := 30000 END;

  IF traceDebug THEN
    Kernel.WriteString("UsbDriver: control transfer addr=");
    Kernel.WriteInt(req.Device.Address, 0);
    Kernel.WriteString(" ep="); Kernel.WriteInt(req.Endpoint, 0);
    Kernel.WriteString(" len="); Kernel.WriteInt(req.BufferLen, 0);
    Kernel.WriteLn
  END;

  (* SETUP stage *)
  StartChannel(ch, req.Device, req.Endpoint MOD 16, eptControl,
    FALSE, pidSetup, req.ControlMessage, 8, mps);
  chint := WaitForChannelComplete(ch, timeout);
  IF ~(bHcXfercomp IN chint) THEN
    status := TranslateStatus(chint);
    IF status = {} THEN status := Usb.ResCRCTimeout END;
    FreeChannel(con, ch);
    RETURN status
  END;

  (* DATA stage (if any) *)
  IF req.BufferLen > 0 THEN
    dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
    datatoggle := TRUE;  (* control data starts with DATA1 *)
    restlen := req.BufferLen;
    databuf := req.Buffer;

    WHILE restlen > 0 DO
      IF restlen > mps THEN curlen := mps ELSE curlen := restlen END;
      IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

      StartChannel(ch, req.Device, req.Endpoint MOD 16, eptControl,
        dirIn, pid, databuf, curlen, mps);
      chint := WaitForChannelComplete(ch, timeout);
      IF ~(bHcXfercomp IN chint) THEN
        status := TranslateStatus(chint);
        IF status = {} THEN status := Usb.ResCRCTimeout END;
        FreeChannel(con, ch);
        RETURN status
      END;

      datatoggle := ~datatoggle;
      INC(databuf, curlen);
      DEC(restlen, curlen)
    END
  END;

  (* STATUS stage *)
  IF (req.BufferLen = 0) OR (SYSTEM.VAL(SET, req.Endpoint) * {7} = {}) THEN
    dirIn := TRUE  (* status IN for host-to-device or no-data *)
  ELSE
    dirIn := FALSE  (* status OUT for device-to-host *)
  END;

  StartChannel(ch, req.Device, req.Endpoint MOD 16, eptControl,
    dirIn, pidData1, 0, 0, mps);
  chint := WaitForChannelComplete(ch, timeout);

  FreeChannel(con, ch);

  IF bHcXfercomp IN chint THEN RETURN Usb.ResOK
  ELSE RETURN TranslateStatus(chint)
  END
END DoControlTransfer;


PROCEDURE DoBulkTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR
  ch, pid, pipesize: INTEGER;
  chint, status: SET;
  dirIn: BOOLEAN;
  datatoggle: BOOLEAN;
  restlen, curlen, databuf: LONGINT;
  timeout: LONGINT;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};

  IF dirIn THEN
    datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE
    datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16]
  END;
  IF pipesize = 0 THEN pipesize := 8 END;

  timeout := req.Timeout;
  IF timeout = 0 THEN timeout := 5000 END;
  IF timeout = -1 THEN timeout := 30000 END;

  restlen := req.BufferLen;
  databuf := req.Buffer;

  WHILE restlen > 0 DO
    IF restlen > pipesize THEN curlen := pipesize ELSE curlen := restlen END;
    IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

    StartChannel(ch, req.Device, req.Endpoint MOD 16, eptBulk,
      dirIn, pid, databuf, curlen, pipesize);
    chint := WaitForChannelComplete(ch, timeout);

    IF ~(bHcXfercomp IN chint) THEN
      status := TranslateStatus(chint);
      IF bHcNak IN chint THEN
        (* NAK is not fatal for bulk, retry *)
        (* but don't toggle *)
      ELSE
        (* Update toggle state *)
        IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
        ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle
        END;
        FreeChannel(con, ch);
        IF status = {} THEN status := Usb.ResCRCTimeout END;
        RETURN status
      END
    ELSE
      datatoggle := ~datatoggle;
      INC(databuf, curlen);
      DEC(restlen, curlen)
    END
  END;

  (* Update data toggle *)
  IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
  ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle
  END;

  FreeChannel(con, ch);
  RETURN Usb.ResOK
END DoBulkTransfer;



PROCEDURE DoInterruptTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR
  ch, pid, pipesize: INTEGER;
  chint, status: SET;
  dirIn: BOOLEAN;
  datatoggle: BOOLEAN;
  timeout: LONGINT;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};

  IF dirIn THEN
    datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE
    datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16]
  END;
  IF pipesize = 0 THEN pipesize := 8 END;

  timeout := req.Timeout;
  IF timeout = 0 THEN timeout := 5000 END;
  IF timeout = -1 THEN timeout := 30000 END;

  IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

  StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt,
    dirIn, pid, req.Buffer, req.BufferLen, pipesize);
  chint := WaitForChannelComplete(ch, timeout);

  IF bHcXfercomp IN chint THEN
    datatoggle := ~datatoggle;
    status := Usb.ResOK
  ELSE
    status := TranslateStatus(chint);
    IF status = {} THEN status := Usb.ResCRCTimeout END
  END;

  IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
  ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle
  END;

  FreeChannel(con, ch);
  RETURN status
END DoInterruptTransfer;


PROCEDURE PrepareAsyncInterrupt(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR
  ch, pid, pipesize: INTEGER;
  dirIn: BOOLEAN;
  datatoggle: BOOLEAN;
  spec: Dwc2ConSpec;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};

  IF dirIn THEN
    datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE
    datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16]
  END;
  IF pipesize = 0 THEN pipesize := 8 END;

  IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

  StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt,
    dirIn, pid, req.Buffer, req.BufferLen, pipesize);

  NEW(spec);
  spec.chan := ch;
  req.ConSpec := spec;

  req.Status := Usb.ResInProgress;

  (* Add to transfer request list *)
  req.next := con.TReqList;
  con.TReqList := req;

  RETURN Usb.ResInProgress
END PrepareAsyncInterrupt;


PROCEDURE UpcallReset(con: Usb.UsbController);
VAR dummy: BOOLEAN;
BEGIN
  WITH con: Dwc2Controller DO
    dummy := ResetRootPort()
  END
END UpcallReset;

PROCEDURE UpcallGetPortStatus(con: Usb.UsbController; port: INTEGER): SET;
VAR val: LONGINT; status: SET; spd: LONGINT;
BEGIN
  status := {};
  val := ReadReg(rHPRT);

  IF SYSTEM.VAL(SET, val) * {bPrtConn} # {} THEN
    status := status + Usb.PortStatusDevicePresent
  END;
  IF SYSTEM.VAL(SET, val) * {bPrtEna} # {} THEN
    status := status + Usb.PortStatusEnabled
  END;
  IF SYSTEM.VAL(SET, val) * {bPrtRst} # {} THEN
    status := status + Usb.PortStatusReset
  END;

  spd := ASH(val, -prtSpdShift) MOD 4;
  IF spd = spdLow THEN status := status + Usb.PortStatusLowSpeed
  ELSIF spd = spdHigh THEN status := status + Usb.PortStatusHighSpeed
  END;

  RETURN status
END UpcallGetPortStatus;

PROCEDURE UpcallGetPortCount(con: Usb.UsbController): INTEGER;
BEGIN
  RETURN 1  (* DWC2 has one root port *)
END UpcallGetPortCount;

PROCEDURE UpcallEnablePort(con: Usb.UsbController; port: INTEGER);
VAR dummy: BOOLEAN;
BEGIN
  dummy := ResetRootPort()
END UpcallEnablePort;

PROCEDURE UpcallDisablePort(con: Usb.UsbController; port: INTEGER);
VAR val: LONGINT;
BEGIN
  val := ReadReg(rHPRT);
  (* Clear write-to-clear bits, then clear enable *)
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg});
  WriteReg(rHPRT, val)
END UpcallDisablePort;

PROCEDURE UpcallSendReq(con: Usb.UsbController; req: Usb.UsbTReq);
BEGIN
  WITH con: Dwc2Controller DO
    IF req.Typ = Usb.TransferControl THEN
      req.Status := DoControlTransfer(con, req)
    ELSIF req.Typ = Usb.TransferBulk THEN
      req.Status := DoBulkTransfer(con, req)
    ELSIF req.Typ = Usb.TransferInterrupt THEN
      IF req.Timeout # 0 THEN
        req.Status := DoInterruptTransfer(con, req)
      ELSE
        req.Status := PrepareAsyncInterrupt(con, req)
      END
    ELSE
      req.Status := Usb.ResInternal
    END
  END
END UpcallSendReq;

PROCEDURE UpcallProbeTrans(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec; chint: SET; intofs: LONGINT;
    dirIn: BOOLEAN; datatoggle: BOOLEAN; pid, pipesize: INTEGER;
BEGIN
  IF req.ConSpec = NIL THEN
    req.Status := Usb.ResInternal;
    RETURN
  END;

  spec := req.ConSpec(Dwc2ConSpec);
  intofs := rHCINT0 + spec.chan * chanStep;
  chint := SYSTEM.VAL(SET, ReadReg(intofs));

  IF (bHcXfercomp IN chint) OR (bHcStall IN chint) OR 
     (bHcAhberr IN chint) OR (bHcBblerr IN chint) THEN

    (* Transfer finished (OK or hard error) *)
    WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));

    IF bHcXfercomp IN chint THEN
      req.Status := Usb.ResOK;
      (* Toggle data toggle *)
      dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
      IF dirIn THEN
        datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
        req.Device.DataToggleIn[req.Endpoint MOD 16] := ~datatoggle
      ELSE
        datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
        req.Device.DataToggleOut[req.Endpoint MOD 16] := ~datatoggle
      END
    ELSE
      req.Status := TranslateStatus(chint);
      IF req.Status = {} THEN req.Status := Usb.ResCRCTimeout END
    END

  ELSIF bHcChhltd IN chint THEN
    IF bHcNak IN chint THEN
      (* NAK received: device has no data yet. Clear interrupts and fully restart channel. *)
      WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
      
      dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
      IF dirIn THEN
        datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
        pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
      ELSE
        datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
        pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16]
      END;
      IF pipesize = 0 THEN pipesize := 8 END;
      IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;
      
      (* Reprogram HCTSIZ, HCDMA, and re-enable HCCHAR *)
      StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt,
        dirIn, pid, req.Buffer, req.BufferLen, pipesize);
        
      RETURN (* Leave req.Status as ResInProgress *)
    ELSE
      (* Halted for an unknown reason without transfer complete *)
      WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
      req.Status := TranslateStatus(chint);
      IF req.Status = {} THEN req.Status := Usb.ResCRCTimeout END
    END
  END
  (* else: still in progress, leave status as ResInProgress *)
END UpcallProbeTrans;

PROCEDURE UpcallDeleteTrans(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec; reqtmp: Usb.UsbTReq;
BEGIN
  IF req.ConSpec = NIL THEN
    RETURN
  END;

  WITH con: Dwc2Controller DO
    spec := req.ConSpec(Dwc2ConSpec);

    (* Disable the channel *)
    IF spec.chan >= 0 THEN
      SetBits(rHCCHAR0 + spec.chan * chanStep, {bCharChdis});
      MilliWait(1);
      WriteReg(rHCINT0 + spec.chan * chanStep, SYSTEM.VAL(LONGINT, {0..31}));
      FreeChannel(con, spec.chan)
    END;

    (* Remove from TReqList *)
    reqtmp := con.TReqList;
    IF reqtmp = req THEN
      con.TReqList := req.next
    ELSE
      WHILE (reqtmp # NIL) & (reqtmp.next # req) DO
        reqtmp := reqtmp.next
      END;
      IF reqtmp # NIL THEN reqtmp.next := req.next END
    END;

    req.ConSpec := NIL
  END
END UpcallDeleteTrans;

PROCEDURE UpcallRestartInterrupt(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec;
    dirIn: BOOLEAN;
    datatoggle: BOOLEAN;
    pipesize, pid: INTEGER;
BEGIN
  IF req.Typ # Usb.TransferInterrupt THEN HALT(303) END;

  IF req.ConSpec = NIL THEN
    req.Status := Usb.ResInternal;
    RETURN
  END;

  IF (req.Status * Usb.ResInProgress) # {} THEN RETURN END;

  spec := req.ConSpec(Dwc2ConSpec);

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
  IF dirIn THEN
    datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE
    datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
    pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16]
  END;
  IF pipesize = 0 THEN pipesize := 8 END;

  IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

  req.Status := Usb.ResInProgress;

  (* Clear old interrupts and restart the channel *)
  WriteReg(rHCINT0 + spec.chan * chanStep, SYSTEM.VAL(LONGINT, {0..31}));

  StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt,
    dirIn, pid, req.Buffer, req.BufferLen, pipesize)
END UpcallRestartInterrupt;


PROCEDURE InitController(): BOOLEAN;
VAR con: Dwc2Controller; vendorId: LONGINT;
BEGIN
  IF ControllerCount >= MaxControllers THEN RETURN FALSE END;

  Kernel.WriteString("UsbDriver: InitController start"); Kernel.WriteLn;
  DMB;

  (* Power on USB via mailbox *)
  Kernel.WriteString("UsbDriver: powering on USB"); Kernel.WriteLn;
  IF ~PowerOnUSB() THEN
    Kernel.WriteString("UsbDriver: PowerOnUSB failed"); Kernel.WriteLn;
    RETURN FALSE
  END;
  Kernel.WriteString("UsbDriver: power on OK"); Kernel.WriteLn;
  MilliWait(100);

  (* Verify vendor ID *)
  vendorId := ReadReg(rGVENDORID);
  IF traceDebug THEN
    Kernel.WriteString("UsbDriver: Vendor ID = ");
    PrintHex(vendorId); Kernel.WriteLn
  END;

  (* Initialize core *)
  IF ~InitCore() THEN
    Kernel.WriteString("UsbDriver: core init failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Initialize host mode *)
  IF ~InitHost() THEN
    Kernel.WriteString("UsbDriver: host init failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Enable and power the root port *)
  IF ~EnableRootPort() THEN
    Kernel.WriteString("UsbDriver: root port power failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Wait for device connection *)
  MilliWait(200);

  IF ~TestBits(rHPRT, {bPrtConn}) THEN
    Kernel.WriteString("UsbDriver: no device connected to root port"); Kernel.WriteLn;
    (* Not fatal - system can run without USB devices *)
  END;

  (* Reset the root port to enable it *)
  (* We cannot do this here, otherwise Usb.Mod get's confused
  IF ~ResetRootPort() THEN
    Kernel.WriteString("UsbDriver: root port reset failed"); Kernel.WriteLn;
    RETURN FALSE
  END; *)

  (* Create controller record *)
  NEW(con);

  con.OpReset := UpcallReset;
  con.OpEnablePort := UpcallEnablePort;
  con.OpDisablePort := UpcallDisablePort;
  con.OpGetPortStatus := UpcallGetPortStatus;
  con.OpGetPortCount := UpcallGetPortCount;
  con.OpSendReq := UpcallSendReq;
  con.OpProbeTrans := UpcallProbeTrans;
  con.OpDeleteTrans := UpcallDeleteTrans;
  con.OpRestartInterrupt := UpcallRestartInterrupt;

  con.idx := ControllerCount;
  con.portCount := 1;
  con.chanAllocated := {};
  con.TReqList := NIL;

  INC(ControllerCount);
  FirstController := con;

  Usb.RegisterController(con);

  DMB;

  Kernel.WriteString("UsbDriver: controller initialized"); Kernel.WriteLn;

  RETURN TRUE
END InitController;


PROCEDURE Cleanup;
VAR i: INTEGER;
BEGIN
  IF FirstController # NIL THEN
    FOR i := 0 TO NumChannels - 1 DO
      SetBits(rHCCHAR0 + i * chanStep, {bCharChdis});
      WriteReg(rHCINT0 + i * chanStep, SYSTEM.VAL(LONGINT, {0..31}))
    END;
    Usb.RemoveController(FirstController)
  END
END Cleanup;

PROCEDURE Init*;
BEGIN
  IF ControllerCount # 0 THEN RETURN END;

  IF InitController() THEN
    Kernel.WriteString("UsbDriver: USB DWC2 controller ready"); Kernel.WriteLn
  ELSE
    Kernel.WriteString("UsbDriver: USB DWC2 controller init failed"); Kernel.WriteLn
  END
END Init;

PROCEDURE Diag*;
VAR val: LONGINT;
BEGIN
  Kernel.WriteString("UsbDriver Diagnostics:"); Kernel.WriteLn;

  val := ReadReg(rGVENDORID);
  Kernel.WriteString("  Vendor ID: "); PrintHex(val); Kernel.WriteLn;

  val := ReadReg(rGHWCFG2);
  Kernel.WriteString("  HW Config2: "); PrintHex(val); Kernel.WriteLn;
  Kernel.WriteString("  Channels: "); Kernel.WriteInt(ASH(val, -14) MOD 16 + 1, 0); Kernel.WriteLn;

  val := ReadReg(rHPRT);
  Kernel.WriteString("  Port status: "); PrintHex(val);
  IF SYSTEM.VAL(SET, val) * {bPrtConn} # {} THEN Kernel.WriteString(" [connected]") END;
  IF SYSTEM.VAL(SET, val) * {bPrtEna} # {} THEN Kernel.WriteString(" [enabled]") END;
  IF SYSTEM.VAL(SET, val) * {bPrtPwr} # {} THEN Kernel.WriteString(" [powered]") END;
  Kernel.WriteLn
END Diag;

BEGIN
  ControllerCount := 0;
  FirstController := NIL;
  Kernel.InstallTermHandler(Cleanup);
  Init
END UsbDriver.

