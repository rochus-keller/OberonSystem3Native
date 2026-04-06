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
  MaxTransferSize = 4096; (* Max size for a single bounce buffer transfer *)

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
  spdHigh = 0;
  spdFull = 1;
  spdLow  = 2;

  (** Host Channel Registers *)
  rHCCHAR0    = 500H;
  rHCSPLT0    = 504H;
  rHCINT0     = 508H;
  rHCINTMSK0  = 50CH;
  rHCTSIZ0    = 510H;
  rHCDMA0     = 514H;
  chanStep   = 020H;

  (** HCCHAR bits *)
  charEpnumShift = 11;
  bCharEpdirIn    = 15;
  bCharLsdev       = 17;
  charEptypeShift = 18;
  eptControl   = 0;
  eptIso       = 1;
  eptBulk      = 2;
  eptInterrupt = 3;
  charMcShift    = 20;
  charDevaddrShift = 22;
  bCharChdis       = 30;
  bCharChen        = 31;

  (** HCTSIZ bits *)
  tsizXfersizeMask = 7FFFFH;
  tsizPktcntShift  = 19;
  tsizPidShift     = 29;
  pidData0 = 0;
  pidData2 = 1;
  pidData1 = 2;
  pidSetup = 3;

  (** HCINT bits *)
  bHcXfercomp    = 0;
  bHcChhltd      = 1;
  bHcAhberr      = 2;
  bHcStall       = 3;
  bHcNak         = 4;
  bHcAck         = 5;
  bHcNyet        = 6;
  bHcXacterr     = 7;
  bHcBblerr      = 8;
  bHcDatatglerr  = 10;

  (** Mailbox for USB power on *)
  mboxBase   = 3F00B880H;
  mboxStatusOfs = 18H;
  mboxWriteOfs  = 20H;
  mboxReadOfs   = 0;
  mboxFull   = 80000000H;
  mboxEmpty  = 40000000H;
  mboxChanProp = 8;
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
    splitState: INTEGER;
    ssplitVal: LONGINT;
    csplitVal: LONGINT;
  END;

VAR
  FirstController: Dwc2Controller;
  ControllerCount: INTEGER;
    
  mbufRaw: ARRAY 128 OF CHAR;
  chanBufRaw: ARRAY NumChannels * MaxTransferSize + 64 OF CHAR;
  chanBuf: ARRAY NumChannels OF LONGINT;


PROCEDURE -GetWord(adr: LONGINT): LONGINT;
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  LDR R0, [R0, #0]
  ADD SP, SP, #4
END GetWord;

PROCEDURE -PutWord(adr, val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #4]
  LDR R1, [SP, #0]
  STR R1, [R0, #0]
  ADD SP, SP, #8
END PutWord;

PROCEDURE -DSB;
CODE {SYSTEM.arm}
  DCW 0F04FH, 0F57FH
END DSB;

PROCEDURE -DMB;
CODE {SYSTEM.arm}
  DCW 0F05FH, 0F57FH
END DMB;

(* Clean Cache (Host -> Device) *)
PROCEDURE -CleanDCacheLine(adr: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F3AH, 0EE07H
  ADD SP, SP, #4
END CleanDCacheLine;

(* Invalidate Cache (Device -> Host) *)
PROCEDURE -InvalidateDCacheLine(adr: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F36H, 0EE07H
  ADD SP, SP, #4
END InvalidateDCacheLine;

PROCEDURE CleanDCache(adr, size: LONGINT);
VAR end: LONGINT;
BEGIN
  end := adr + size;
  adr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, adr) - {0..5});
  WHILE adr < end DO CleanDCacheLine(adr); INC(adr, 32) END;
  DSB
END CleanDCache;

PROCEDURE InvalidateDCache(adr, size: LONGINT);
VAR end: LONGINT;
BEGIN
  end := adr + size;
  adr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, adr) - {0..5});
  WHILE adr < end DO InvalidateDCacheLine(adr); INC(adr, 32) END;
  DSB
END InvalidateDCache;

PROCEDURE GetBusAdr(adr: LONGINT): LONGINT;
BEGIN RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, adr) + {30, 31})
END GetBusAdr;

PROCEDURE ReadReg(offset: LONGINT): LONGINT;
BEGIN RETURN GetWord(USBBase + offset)
END ReadReg;

PROCEDURE WriteReg(offset, val: LONGINT);
BEGIN PutWord(USBBase + offset, val)
END WriteReg;

PROCEDURE SetBits(offset: LONGINT; bits: SET);
VAR v: LONGINT;
BEGIN
  v := ReadReg(offset);
  v := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, v) + bits);
  WriteReg(offset, v)
END SetBits;

PROCEDURE TestBits(offset: LONGINT; bits: SET): BOOLEAN;
BEGIN RETURN SYSTEM.VAL(SET, ReadReg(offset)) * bits # {}
END TestBits;

PROCEDURE PrintHex(was: LONGINT);
VAR z, d, h, i: LONGINT;
BEGIN
  z := 0; d := 16*16*16*16*16*16*16;
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

PROCEDURE MboxWriteMsg(data, channel: LONGINT): BOOLEAN;
VAR t: Kernel.MilliTimer;
BEGIN
  DMB; Kernel.SetTimer(t, 200); 
  WHILE SYSTEM.VAL(SET, GetWord(mboxBase + mboxStatusOfs)) * SYSTEM.VAL(SET, mboxFull) # {} DO 
    IF Kernel.Expired(t) THEN RETURN FALSE END
  END;
  PutWord(mboxBase + mboxWriteOfs, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) + SYSTEM.VAL(SET, channel)));
  DMB; RETURN TRUE
END MboxWriteMsg;

PROCEDURE MboxReadMsg(channel: LONGINT; VAR resp: LONGINT): BOOLEAN;
VAR data: LONGINT; t: Kernel.MilliTimer;
BEGIN
  Kernel.SetTimer(t, 500); 
  LOOP
    DMB;
    WHILE SYSTEM.VAL(SET, GetWord(mboxBase + mboxStatusOfs)) * SYSTEM.VAL(SET, mboxEmpty) # {} DO 
      IF Kernel.Expired(t) THEN RETURN FALSE END
    END;
    data := GetWord(mboxBase + mboxReadOfs);
    DMB;
    IF SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) * {0..3}) = channel THEN
      resp := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) - SYSTEM.VAL(SET, data) * {0..3});
      RETURN TRUE
    END;
    IF Kernel.Expired(t) THEN RETURN FALSE END
  END
END MboxReadMsg;

PROCEDURE PowerOnUSB(): BOOLEAN;
VAR mbuf, resp, i: LONGINT;
BEGIN
  mbuf := SYSTEM.ADR(mbufRaw[0]);
  mbuf := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, mbuf + 63) - {0..5});
  i := 0;
  PutWord(mbuf + i, 32); INC(i, 4);       
  PutWord(mbuf + i, 0); INC(i, 4);        
  PutWord(mbuf + i, tagSetPower); INC(i, 4);  
  PutWord(mbuf + i, 8); INC(i, 4);        
  PutWord(mbuf + i, 8); INC(i, 4);        
  PutWord(mbuf + i, deviceUSB); INC(i, 4);  
  PutWord(mbuf + i, 3); INC(i, 4);        
  PutWord(mbuf + i, tagEnd); INC(i, 4);   
  CleanDCache(mbuf, 32);

  IF ~MboxWriteMsg(GetBusAdr(mbuf), mboxChanProp) THEN RETURN FALSE END;
  IF ~MboxReadMsg(mboxChanProp, resp) THEN RETURN FALSE END;

  InvalidateDCache(mbuf, 32);
  resp := GetWord(mbuf + 4);
  IF resp # SYSTEM.VAL(LONGINT, 80000000H) THEN RETURN FALSE END;
  resp := GetWord(mbuf + 24);
  IF SYSTEM.VAL(SET, resp) * {0} = {} THEN RETURN FALSE END;
  RETURN TRUE
END PowerOnUSB;

PROCEDURE AllocateChannel(con: Dwc2Controller): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO NumChannels - 1 DO
    IF ~(i IN con.chanAllocated) THEN INCL(con.chanAllocated, i); RETURN i END
  END;
  RETURN -1
END AllocateChannel;

PROCEDURE FreeChannel(con: Dwc2Controller; ch: INTEGER);
BEGIN
  IF (ch >= 0) & (ch < NumChannels) THEN EXCL(con.chanAllocated, ch) END
END FreeChannel;

PROCEDURE WaitForBit(offset: LONGINT; bit: INTEGER; set: BOOLEAN; ms: LONGINT): BOOLEAN;
VAR t: Kernel.MilliTimer;
BEGIN
  Kernel.SetTimer(t, ms);
  LOOP
    IF set THEN IF TestBits(offset, {bit}) THEN RETURN TRUE END
    ELSE IF ~TestBits(offset, {bit}) THEN RETURN TRUE END END;
    IF Kernel.Expired(t) THEN RETURN FALSE END
  END
END WaitForBit;

PROCEDURE FlushTxFIFO(fifo: LONGINT);
VAR val: LONGINT;
BEGIN
  val := SYSTEM.VAL(LONGINT, {bRstTxfflsh} + SYSTEM.VAL(SET, ASH(fifo, rstTxfnumShift)));
  WriteReg(rGRSTCTL, val);
  IF ~WaitForBit(rGRSTCTL, bRstTxfflsh, FALSE, 100) THEN END;
END FlushTxFIFO;

PROCEDURE FlushRxFIFO;
BEGIN
  WriteReg(rGRSTCTL, SYSTEM.VAL(LONGINT, {bRstRxfflsh}));
  IF ~WaitForBit(rGRSTCTL, bRstRxfflsh, FALSE, 100) THEN END;
END FlushRxFIFO;

PROCEDURE ResetCore(): BOOLEAN;
BEGIN
  IF ~WaitForBit(rGRSTCTL, bRstAhbidle, TRUE, 100) THEN RETURN FALSE END;
  SetBits(rGRSTCTL, {bRstCsftrst});
  IF ~WaitForBit(rGRSTCTL, bRstCsftrst, FALSE, 100) THEN RETURN FALSE END;
  MilliWait(100);
  RETURN TRUE
END ResetCore;

PROCEDURE InitCore(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  (* Minimal pre-reset: clear ext vbus and term select *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bUsbUlpiVbus, bUsbTermSel});
  WriteReg(rGUSBCFG, val);

  IF ~ResetCore() THEN RETURN FALSE END;

  (* AFTER reset: select UTMI+ PHY, 8-bit interface *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
    - {bUsbUlpiSel, bUsbPhyIf, bUsbUlpiFsls, bUsbUlpiClk});
  WriteReg(rGUSBCFG, val);

  (* Configure AHB: enable DMA, wait for AXI writes, clear AXI burst bits *)
  val := ReadReg(rGAHBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
    - {bAhbGlblIntrEn, 1, 2}             (* clear global int + AXI burst bits 1-2 *)          
    + {bAhbWaitAxi, bAhbDmaEn});
  WriteReg(rGAHBCFG, val);

  (* Disable HNP and SRP *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bUsbHnp, bUsbSrp});
  WriteReg(rGUSBCFG, val);
  RETURN TRUE
END InitCore;

PROCEDURE InitHost(): BOOLEAN;
CONST rPCGCCTL = 0E00H;   (* Power and Clock Gating Control *)
VAR val, rxfsiz, nptxfsiz, i: LONGINT;
BEGIN
  WriteReg(rPCGCCTL, 0);  (* Restart PHY clock - ensure no clock gating *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bUsbForceHost});
  WriteReg(rGUSBCFG, val);
  MilliWait(50);

  val := ReadReg(rHCFG);
  (* High-Speed mode for root internal hub (clear FSLSSupp and FSLSPclkSel) *)
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {0, 1, 2}); 
  WriteReg(rHCFG, val);

  rxfsiz := 1024; nptxfsiz := 1024;
  WriteReg(rGRXFSIZ, rxfsiz);
  WriteReg(rGNPTXFSIZ, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(nptxfsiz, 16)) + SYSTEM.VAL(SET, rxfsiz)));
  WriteReg(rGHPTXFSIZ, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(nptxfsiz, 16)) + SYSTEM.VAL(SET, rxfsiz + nptxfsiz)));

  FlushTxFIFO(10H); FlushRxFIFO;
  
  (* Explicitly disable all channels to clear bootloader state *)
  FOR i := 0 TO NumChannels - 1 DO
    val := ReadReg(rHCCHAR0 + i * chanStep);
    val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
    WriteReg(rHCCHAR0 + i * chanStep, val);
    WriteReg(rHCINT0 + i * chanStep, SYSTEM.VAL(LONGINT, {0..31}))
  END;

  WriteReg(rHAINTMSK, 0); WriteReg(rGINTSTS, SYSTEM.VAL(LONGINT, {0..31}));
  
  RETURN TRUE
END InitHost;

PROCEDURE EnableRootPort(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg});
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bPrtPwr});
  WriteReg(rHPRT, val);
  MilliWait(50);
  RETURN TRUE
END EnableRootPort;

PROCEDURE ResetRootPort(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg});
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bPrtRst});
  WriteReg(rHPRT, val);
  MilliWait(60);

  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg, bPrtRst});
  WriteReg(rHPRT, val);

  (* Wait for port to actually become enabled (up to 500ms) *)
  IF ~WaitForBit(rHPRT, bPrtEna, TRUE, 500) THEN
    Kernel.WriteString("UsbDriver: port not enabled after reset");
    Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Allow SOF frames to stabilize and device to settle *)
  MilliWait(100);

  RETURN TRUE
END ResetRootPort;

PROCEDURE WaitForChannelComplete(ch: INTEGER; timeout: LONGINT): SET;
VAR t: Kernel.MilliTimer; chint: SET; intofs, val, splt: LONGINT;
BEGIN
  intofs := rHCINT0 + ch * chanStep;
  Kernel.SetTimer(t, timeout);
  LOOP
    chint := SYSTEM.VAL(SET, ReadReg(intofs));
    IF bHcChhltd IN chint THEN
      splt := ReadReg(rHCSPLT0 + ch * chanStep);
      IF (bHcNak IN chint) & (SYSTEM.VAL(SET, splt) * {31} = {}) THEN
        WriteReg(intofs, SYSTEM.VAL(LONGINT, {bHcNak, bHcChhltd}));
        val := ReadReg(rHCCHAR0 + ch * chanStep);
        val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChen} - {bCharChdis});
        WriteReg(rHCCHAR0 + ch * chanStep, val)
      ELSE
        IF ~(bHcXfercomp IN chint) & ~(bHcAck IN chint) & ~(bHcNyet IN chint) & ~(bHcNak IN chint) THEN
          FlushTxFIFO(10H)
        END;
        EXIT
      END
    END;
    IF Kernel.Expired(t) THEN
      val := ReadReg(rHCCHAR0 + ch * chanStep);
      val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
      WriteReg(rHCCHAR0 + ch * chanStep, val);
      MilliWait(2);
      chint := SYSTEM.VAL(SET, ReadReg(intofs));
      FlushTxFIFO(10H);
      EXIT
    END
  END;
  WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
  RETURN chint
END WaitForChannelComplete;

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
    IF (bHcChhltd IN chint) & ~(bHcXfercomp IN chint) THEN status := Usb.ResCRCTimeout END
  END;
  RETURN status
END TranslateStatus;

PROCEDURE StartChannel(ch: INTEGER; dev: Usb.UsbDevice; endpoint, eptype: INTEGER;
    dirIn: BOOLEAN; pid: INTEGER; buffer, buflen: LONGINT; mps: INTEGER);
VAR charVal, tsizVal, base: LONGINT; pktcnt: LONGINT;
BEGIN
  base := ch * chanStep;
  WriteReg(rHCINT0 + base, SYSTEM.VAL(LONGINT, {0..31}));
  WriteReg(rHCINTMSK0 + base, SYSTEM.VAL(LONGINT,
    {bHcXfercomp, bHcChhltd, bHcAhberr, bHcStall, bHcNak, bHcAck, bHcNyet, bHcXacterr, bHcBblerr, bHcDatatglerr}));

  charVal := mps;  
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + SYSTEM.VAL(SET, ASH(endpoint MOD 16, charEpnumShift)));
  IF dirIn THEN charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharEpdirIn}) END;
  IF dev.LowSpeed THEN charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharLsdev}) END;
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + SYSTEM.VAL(SET, ASH(eptype, charEptypeShift)));
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + SYSTEM.VAL(SET, ASH(1, charMcShift)));  
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + SYSTEM.VAL(SET, ASH(dev.Address, charDevaddrShift)));
  
  (* Schedule periodic transfers into the opposite microframe boundary *)
  IF (eptype = eptInterrupt) OR (eptype = eptIso) THEN
    IF TestBits(rHFNUM, {0}) THEN
      charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) - {29}); 
    ELSE
      charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {29}); 
    END
  END;

  WriteReg(rHCCHAR0 + base, charVal);

  IF buflen > MaxTransferSize THEN buflen := MaxTransferSize END;
  IF buflen > 0 THEN pktcnt := (buflen + mps - 1) DIV mps ELSE pktcnt := 1 END;
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, buflen) * SYSTEM.VAL(SET, tsizXfersizeMask));
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, tsizVal) + SYSTEM.VAL(SET, ASH(pktcnt, tsizPktcntShift)));
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, tsizVal) + SYSTEM.VAL(SET, ASH(pid, tsizPidShift)));
  WriteReg(rHCTSIZ0 + base, tsizVal);

  IF buflen > 0 THEN
    IF ~dirIn THEN
      IF buffer # 0 THEN SYSTEM.MOVE(buffer, chanBuf[ch], buflen) END;
      CleanDCache(chanBuf[ch], buflen)
    ELSE
      InvalidateDCache(chanBuf[ch], buflen)
    END
  END;
  
  WriteReg(rHCDMA0 + base, GetBusAdr(chanBuf[ch]));

  DSB;
  charVal := ReadReg(rHCCHAR0 + base);
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharChen} - {bCharChdis});
  WriteReg(rHCCHAR0 + base, charVal);
  DSB
END StartChannel;

PROCEDURE GetSplitInfo(dev: Usb.UsbDevice; VAR hubAddr, hubPort: INTEGER): BOOLEAN;
VAR p, d: Usb.UsbDevice;
BEGIN
  IF (dev = NIL) OR dev.HighSpeed THEN RETURN FALSE END;
  
  d := dev; p := d.Parent;
  WHILE (p # NIL) & (p # p.Parent) & ~p.HighSpeed DO
    d := p; p := p.Parent
  END;

  IF (p # NIL) & (p # p.Parent) & p.HighSpeed THEN
    hubAddr := p.Address; hubPort := d.Port + 1;
    RETURN TRUE
  END;

  RETURN FALSE
END GetSplitInfo;

PROCEDURE ExecuteTransfer(ch: INTEGER; req: Usb.UsbTReq; endpoint, eptype: INTEGER;
    dirIn: BOOLEAN; pid: INTEGER; buffer, buflen: LONGINT; mps: INTEGER; timeout: LONGINT): SET;
VAR isSplit: BOOLEAN; ssplitVal, csplitVal: LONGINT; chint: SET; 
    hubAddr, hubPort: INTEGER; t: Kernel.MilliTimer;
BEGIN
  Kernel.SetTimer(t, timeout);
  isSplit := GetSplitInfo(req.Device, hubAddr, hubPort);
  IF isSplit THEN
    ssplitVal := SYSTEM.VAL(LONGINT, {31, 15, 14} + SYSTEM.VAL(SET, ASH(hubAddr, 7)) + SYSTEM.VAL(SET, hubPort));
    csplitVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ssplitVal) + {16});

    LOOP
      WriteReg(rHCSPLT0 + ch * chanStep, ssplitVal);
      StartChannel(ch, req.Device, endpoint, eptype, dirIn, pid, buffer, buflen, mps);
      chint := WaitForChannelComplete(ch, timeout);
      
      IF bHcXfercomp IN chint THEN RETURN chint END;
      IF ~(bHcAck IN chint) THEN RETURN chint END;
      
      MilliWait(1); 
      
      LOOP
        WriteReg(rHCSPLT0 + ch * chanStep, csplitVal);
        
        IF ~dirIn THEN
          StartChannel(ch, req.Device, endpoint, eptype, dirIn, pid, 0, 0, mps);
        ELSE
          StartChannel(ch, req.Device, endpoint, eptype, dirIn, pid, buffer, buflen, mps);
        END;
        
        chint := WaitForChannelComplete(ch, timeout);
        
        IF bHcXfercomp IN chint THEN RETURN chint END;
        IF bHcNyet IN chint THEN
          IF Kernel.Expired(t) THEN RETURN chint END;
          MilliWait(1);
        ELSIF bHcNak IN chint THEN
          EXIT 
        ELSE
          RETURN chint
        END
      END;
      IF Kernel.Expired(t) THEN RETURN chint END;
    END
  ELSE
    WriteReg(rHCSPLT0 + ch * chanStep, 0);
    StartChannel(ch, req.Device, endpoint, eptype, dirIn, pid, buffer, buflen, mps);
    RETURN WaitForChannelComplete(ch, timeout)
  END
END ExecuteTransfer;

PROCEDURE DoControlTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR ch: INTEGER; chint, status: SET; pid: INTEGER; dirIn: BOOLEAN; mps: INTEGER;
  restlen, curlen, databuf: LONGINT; datatoggle: BOOLEAN; timeout: LONGINT;
  bmRequestType: CHAR;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  mps := req.Device.Descriptor.bMaxPacketSize0; 
  IF mps = 0 THEN mps := 8 END;
  (* Prevent Ethernet STALL during initial probing by overriding Usb.Mod's default 8 *)
  IF req.Device.HighSpeed & (mps = 8) & (req.Device.Address = 0) THEN mps := 64 END;

  timeout := req.Timeout; IF timeout = 0 THEN timeout := 5000 END; IF timeout = -1 THEN timeout := 30000 END;

  SYSTEM.MOVE(req.ControlMessage, chanBuf[ch], 8);
  CleanDCache(chanBuf[ch], 8);
  chint := ExecuteTransfer(ch, req, req.Endpoint MOD 16, eptControl, FALSE, pidSetup, 0, 8, mps, timeout);
  
  IF ~(bHcXfercomp IN chint) THEN
    Kernel.WriteString("UsbDriver: Setup phase failed! HCINT: "); PrintHex(SYSTEM.VAL(LONGINT, chint)); Kernel.WriteLn;
    status := TranslateStatus(chint); IF status = {} THEN status := Usb.ResCRCTimeout END;
    FreeChannel(con, ch); RETURN status
  END;

  IF req.BufferLen > 0 THEN
    SYSTEM.GET(req.ControlMessage, bmRequestType);
    dirIn := SYSTEM.VAL(SET, bmRequestType) * {7} # {}; 
    datatoggle := TRUE;  
    restlen := req.BufferLen; databuf := req.Buffer;

    WHILE restlen > 0 DO
      IF restlen > mps THEN curlen := mps ELSE curlen := restlen END;
      IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;
      chint := ExecuteTransfer(ch, req, req.Endpoint MOD 16, eptControl, dirIn, pid, databuf, curlen, mps, timeout);

      IF (dirIn) & (bHcXfercomp IN chint) & (databuf # 0) THEN
        InvalidateDCache(chanBuf[ch], curlen);
        SYSTEM.MOVE(chanBuf[ch], databuf, curlen)
      END;

      IF ~(bHcXfercomp IN chint) THEN
        Kernel.WriteString("UsbDriver: Data phase failed! HCINT: "); PrintHex(SYSTEM.VAL(LONGINT, chint)); Kernel.WriteLn;
        status := TranslateStatus(chint); IF status = {} THEN status := Usb.ResCRCTimeout END;
        FreeChannel(con, ch); RETURN status
      END;

      datatoggle := ~datatoggle; INC(databuf, curlen); DEC(restlen, curlen)
    END
  END;

  IF req.BufferLen > 0 THEN
    SYSTEM.GET(req.ControlMessage, bmRequestType);
    dirIn := ~(SYSTEM.VAL(SET, bmRequestType) * {7} # {})
  ELSE
    dirIn := TRUE
  END;

  chint := ExecuteTransfer(ch, req, req.Endpoint MOD 16, eptControl, dirIn, pidData1, 0, 0, mps, timeout);
  FreeChannel(con, ch);
  
  IF bHcXfercomp IN chint THEN RETURN Usb.ResOK 
  ELSE 
    Kernel.WriteString("UsbDriver: Status phase failed! HCINT: "); PrintHex(SYSTEM.VAL(LONGINT, chint)); Kernel.WriteLn;
    RETURN TranslateStatus(chint) 
  END
END DoControlTransfer;

PROCEDURE DoBulkTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR ch, pid, pipesize: INTEGER; chint, status: SET; dirIn, datatoggle: BOOLEAN;
  restlen, curlen, databuf: LONGINT; timeout: LONGINT;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
  IF dirIn THEN datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16] END;
  IF pipesize = 0 THEN pipesize := 8 END;

  timeout := req.Timeout; IF timeout = 0 THEN timeout := 5000 END; IF timeout = -1 THEN timeout := 30000 END;
  restlen := req.BufferLen; databuf := req.Buffer;

  WHILE restlen > 0 DO
    IF restlen > pipesize THEN curlen := pipesize ELSE curlen := restlen END;
    IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;
    chint := ExecuteTransfer(ch, req, req.Endpoint MOD 16, eptBulk, dirIn, pid, databuf, curlen, pipesize, timeout);

    IF (dirIn) & (bHcXfercomp IN chint) & (databuf # 0) THEN
      InvalidateDCache(chanBuf[ch], curlen);
      SYSTEM.MOVE(chanBuf[ch], databuf, curlen)
    END;

    IF ~(bHcXfercomp IN chint) THEN
      status := TranslateStatus(chint);
      IF bHcNak IN chint THEN (* retry *)
      ELSE
        IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
        ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle END;
        FreeChannel(con, ch); IF status = {} THEN status := Usb.ResCRCTimeout END; RETURN status
      END
    ELSE
      datatoggle := ~datatoggle; INC(databuf, curlen); DEC(restlen, curlen)
    END
  END;

  IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
  ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle END;
  FreeChannel(con, ch); RETURN Usb.ResOK
END DoBulkTransfer;

PROCEDURE DoInterruptTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR ch, pid, pipesize: INTEGER; chint, status: SET; dirIn, datatoggle: BOOLEAN; timeout: LONGINT;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
  IF dirIn THEN datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16] END;
  IF pipesize = 0 THEN pipesize := 8 END;

  timeout := req.Timeout; IF timeout = 0 THEN timeout := 5000 END; IF timeout = -1 THEN timeout := 30000 END;
  IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

  chint := ExecuteTransfer(ch, req, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize, timeout);

  IF (dirIn) & (bHcXfercomp IN chint) & (req.Buffer # 0) THEN
    InvalidateDCache(chanBuf[ch], req.BufferLen);
    SYSTEM.MOVE(chanBuf[ch], req.Buffer, req.BufferLen)
  END;

  IF bHcXfercomp IN chint THEN
    datatoggle := ~datatoggle; status := Usb.ResOK
  ELSE
    status := TranslateStatus(chint); IF status = {} THEN status := Usb.ResCRCTimeout END
  END;

  IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
  ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle END;
  FreeChannel(con, ch); RETURN status
END DoInterruptTransfer;

PROCEDURE PrepareAsyncInterrupt(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR ch, pid, pipesize: INTEGER; dirIn, datatoggle, isSplit: BOOLEAN; spec: Dwc2ConSpec;
    hubAddr, hubPort: INTEGER;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  NEW(spec); spec.chan := ch; req.ConSpec := spec; req.Status := Usb.ResInProgress;
  req.next := con.TReqList; con.TReqList := req;

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
  IF dirIn THEN datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16] END;
  IF pipesize = 0 THEN pipesize := 8 END;
  IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

  isSplit := GetSplitInfo(req.Device, hubAddr, hubPort);
  IF isSplit THEN
    spec.ssplitVal := SYSTEM.VAL(LONGINT, {31, 15, 14} + SYSTEM.VAL(SET, ASH(hubAddr, 7)) + SYSTEM.VAL(SET, hubPort));
    spec.csplitVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, spec.ssplitVal) + {16});
    spec.splitState := 1;
    WriteReg(rHCSPLT0 + ch * chanStep, spec.ssplitVal);
  ELSE
    spec.ssplitVal := 0; spec.csplitVal := 0;
    spec.splitState := 0;
    WriteReg(rHCSPLT0 + ch * chanStep, 0);
  END;

  StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize);
  RETURN Usb.ResInProgress
END PrepareAsyncInterrupt;

PROCEDURE UpcallReset(con: Usb.UsbController);
VAR dummy: BOOLEAN;
BEGIN WITH con: Dwc2Controller DO dummy := ResetRootPort() END END UpcallReset;

PROCEDURE UpcallGetPortStatus(con: Usb.UsbController; port: INTEGER): SET;
VAR val: LONGINT; status: SET; spd: LONGINT;
BEGIN
  status := {}; val := ReadReg(rHPRT);
  IF SYSTEM.VAL(SET, val) * {bPrtConn} # {} THEN status := status + Usb.PortStatusDevicePresent END;
  IF SYSTEM.VAL(SET, val) * {bPrtEna} # {} THEN status := status + Usb.PortStatusEnabled END;
  IF SYSTEM.VAL(SET, val) * {bPrtRst} # {} THEN status := status + Usb.PortStatusReset END;
  spd := ASH(val, -prtSpdShift) MOD 4;
  IF spd = spdLow THEN status := status + Usb.PortStatusLowSpeed ELSIF spd = spdHigh THEN status := status + Usb.PortStatusHighSpeed END;
  RETURN status
END UpcallGetPortStatus;

PROCEDURE UpcallGetPortCount(con: Usb.UsbController): INTEGER;
BEGIN RETURN 1 END UpcallGetPortCount;

PROCEDURE UpcallEnablePort(con: Usb.UsbController; port: INTEGER);
VAR dummy: BOOLEAN;
BEGIN 
  dummy := ResetRootPort() 
END UpcallEnablePort;

PROCEDURE UpcallDisablePort(con: Usb.UsbController; port: INTEGER);
VAR val: LONGINT;
BEGIN
  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bPrtConnDet, bPrtEnaChg, bPrtOcaChg});
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bPrtEna});
  WriteReg(rHPRT, val)
END UpcallDisablePort;

PROCEDURE UpcallSendReq(con: Usb.UsbController; req: Usb.UsbTReq);
BEGIN
  WITH con: Dwc2Controller DO
    IF req.Typ = Usb.TransferControl THEN req.Status := DoControlTransfer(con, req)
    ELSIF req.Typ = Usb.TransferBulk THEN req.Status := DoBulkTransfer(con, req)
    ELSIF req.Typ = Usb.TransferInterrupt THEN
      IF req.Timeout # 0 THEN req.Status := DoInterruptTransfer(con, req) ELSE req.Status := PrepareAsyncInterrupt(con, req) END
    ELSE req.Status := Usb.ResInternal END
  END
END UpcallSendReq;

PROCEDURE UpcallProbeTrans(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec; chint: SET; intofs: LONGINT; dirIn, datatoggle: BOOLEAN; pid, pipesize: INTEGER;
BEGIN
  IF req.ConSpec = NIL THEN req.Status := Usb.ResInternal; RETURN END;
  spec := req.ConSpec(Dwc2ConSpec); intofs := rHCINT0 + spec.chan * chanStep; 
  chint := SYSTEM.VAL(SET, ReadReg(intofs));

  IF chint * {bHcXfercomp, bHcChhltd, bHcAhberr, bHcStall, bHcNak, bHcAck, bHcNyet, bHcXacterr, bHcBblerr, bHcDatatglerr} = {} THEN
    RETURN
  END;

  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
  IF dirIn THEN datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16] END;
  IF pipesize = 0 THEN pipesize := 8 END;
  IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;

  (* Non-blocking Split Transaction State Machine *)
  IF spec.splitState = 1 THEN
    IF bHcChhltd IN chint THEN
      WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31})); 
      IF bHcAck IN chint THEN
        spec.splitState := 2; 
        WriteReg(rHCSPLT0 + spec.chan * chanStep, spec.csplitVal);
        IF ~dirIn THEN
          StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, 0, 0, pipesize);
        ELSE
          StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize);
        END;
      ELSE
        WriteReg(rHCSPLT0 + spec.chan * chanStep, spec.ssplitVal);
        StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize);
      END;
      RETURN
    END;
    RETURN
  ELSIF spec.splitState = 2 THEN
    IF bHcChhltd IN chint THEN
      IF ~(bHcXfercomp IN chint) THEN 
        WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
        IF bHcNyet IN chint THEN
          WriteReg(rHCSPLT0 + spec.chan * chanStep, spec.csplitVal);
          IF ~dirIn THEN
            StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, 0, 0, pipesize);
          ELSE
            StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize);
          END;
        ELSE 
          spec.splitState := 1;
          WriteReg(rHCSPLT0 + spec.chan * chanStep, spec.ssplitVal);
          StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize);
        END;
        RETURN
      END
    ELSE
      RETURN
    END
  END;

  (* Final Result Handling *)
  IF (bHcXfercomp IN chint) OR (bHcStall IN chint) OR (bHcAhberr IN chint) OR (bHcBblerr IN chint) THEN
    WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
    IF bHcXfercomp IN chint THEN
      req.Status := Usb.ResOK;
      IF dirIn & (req.Buffer # 0) & (req.BufferLen > 0) THEN
        InvalidateDCache(chanBuf[spec.chan], req.BufferLen);
        SYSTEM.MOVE(chanBuf[spec.chan], req.Buffer, req.BufferLen)
      END;
      IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := ~datatoggle
      ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := ~datatoggle END
    ELSE
      req.Status := TranslateStatus(chint); 
      IF req.Status = {} THEN req.Status := Usb.ResCRCTimeout END
    END;
    RETURN
  END;

  (* Non-Split NAK Handling *)
  IF bHcChhltd IN chint THEN
    WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
    IF bHcNak IN chint THEN
      StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize);
    ELSE
      req.Status := TranslateStatus(chint); 
      IF req.Status = {} THEN req.Status := Usb.ResCRCTimeout END
    END
  END
END UpcallProbeTrans;

PROCEDURE UpcallDeleteTrans(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec; reqtmp: Usb.UsbTReq; val: LONGINT;
BEGIN
  IF req.ConSpec = NIL THEN RETURN END;
  WITH con: Dwc2Controller DO
    spec := req.ConSpec(Dwc2ConSpec);
    IF spec.chan >= 0 THEN
      val := ReadReg(rHCCHAR0 + spec.chan * chanStep);
      val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
      WriteReg(rHCCHAR0 + spec.chan * chanStep, val);
      MilliWait(2);
      WriteReg(rHCINT0 + spec.chan * chanStep, SYSTEM.VAL(LONGINT, {0..31}));
      FreeChannel(con, spec.chan)
    END;
    reqtmp := con.TReqList;
    IF reqtmp = req THEN con.TReqList := req.next
    ELSE
      WHILE (reqtmp # NIL) & (reqtmp.next # req) DO reqtmp := reqtmp.next END;
      IF reqtmp # NIL THEN reqtmp.next := req.next END
    END;
    req.ConSpec := NIL
  END
END UpcallDeleteTrans;

PROCEDURE UpcallRestartInterrupt(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec; dirIn, datatoggle: BOOLEAN; pipesize, pid: INTEGER;
BEGIN
  IF req.Typ # Usb.TransferInterrupt THEN HALT(303) END;
  IF req.ConSpec = NIL THEN req.Status := Usb.ResInternal; RETURN END;
  IF (req.Status * Usb.ResInProgress) # {} THEN RETURN END;

  spec := req.ConSpec(Dwc2ConSpec);
  dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
  IF dirIn THEN datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]
  ELSE datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16]; pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16] END;
  IF pipesize = 0 THEN pipesize := 8 END;
  IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;
  req.Status := Usb.ResInProgress;
  
  IF spec.ssplitVal # 0 THEN
    spec.splitState := 1;
    WriteReg(rHCSPLT0 + spec.chan * chanStep, spec.ssplitVal);
  ELSE
    spec.splitState := 0;
    WriteReg(rHCSPLT0 + spec.chan * chanStep, 0);
  END;

  WriteReg(rHCINT0 + spec.chan * chanStep, SYSTEM.VAL(LONGINT, {0..31}));
  StartChannel(spec.chan, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid, req.Buffer, req.BufferLen, pipesize)
END UpcallRestartInterrupt;

PROCEDURE InitController(): BOOLEAN;
VAR con: Dwc2Controller; vendorId, base, i: LONGINT;
BEGIN
  IF ControllerCount >= MaxControllers THEN RETURN FALSE END;

  base := SYSTEM.ADR(chanBufRaw[0]);
  base := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, base + 63) - {0..5});
  FOR i := 0 TO NumChannels - 1 DO chanBuf[i] := base + i * MaxTransferSize END;

  Kernel.WriteString("UsbDriver: InitController start"); Kernel.WriteLn;
  DMB;

  Kernel.WriteString("UsbDriver: powering on USB"); Kernel.WriteLn;
  IF ~PowerOnUSB() THEN Kernel.WriteString("UsbDriver: PowerOnUSB failed (ignoring, falling back to Vendor ID check)"); Kernel.WriteLn
  ELSE Kernel.WriteString("UsbDriver: power on OK"); Kernel.WriteLn END;
  MilliWait(100);

  vendorId := ReadReg(rGVENDORID);
  IF SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, vendorId) * {16..31}) # 4F540000H THEN
    Kernel.WriteString("UsbDriver: Invalid USB Vendor ID: "); PrintHex(vendorId); Kernel.WriteLn; RETURN FALSE
  END;

  IF ~InitCore() THEN Kernel.WriteString("UsbDriver: core init failed"); Kernel.WriteLn; RETURN FALSE END;
  IF ~InitHost() THEN Kernel.WriteString("UsbDriver: host init failed"); Kernel.WriteLn; RETURN FALSE END;
  IF ~EnableRootPort() THEN Kernel.WriteString("UsbDriver: root port power failed"); Kernel.WriteLn; RETURN FALSE END;

  MilliWait(200);

  NEW(con);
  con.OpReset := UpcallReset; con.OpEnablePort := UpcallEnablePort; con.OpDisablePort := UpcallDisablePort;
  con.OpGetPortStatus := UpcallGetPortStatus; con.OpGetPortCount := UpcallGetPortCount; con.OpSendReq := UpcallSendReq;
  con.OpProbeTrans := UpcallProbeTrans; con.OpDeleteTrans := UpcallDeleteTrans; con.OpRestartInterrupt := UpcallRestartInterrupt;
  con.idx := ControllerCount; con.portCount := 1; con.chanAllocated := {}; con.TReqList := NIL;
  INC(ControllerCount); FirstController := con;
  Usb.RegisterController(con);
  
  (* The Root Hub itself is natively High-Speed. *)
  con.RootHub.HighSpeed := TRUE;

  DMB; Kernel.WriteString("UsbDriver: controller initialized"); Kernel.WriteLn;
  RETURN TRUE
END InitController;

PROCEDURE Cleanup;
VAR i: INTEGER; val: LONGINT;
BEGIN
  IF FirstController # NIL THEN
    FOR i := 0 TO NumChannels - 1 DO
      val := ReadReg(rHCCHAR0 + i * chanStep);
      val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
      WriteReg(rHCCHAR0 + i * chanStep, val);
      WriteReg(rHCINT0 + i * chanStep, SYSTEM.VAL(LONGINT, {0..31}))
    END;
    Usb.RemoveController(FirstController)
  END
END Cleanup;

PROCEDURE Init*;
BEGIN
  IF ControllerCount # 0 THEN RETURN END;
  IF InitController() THEN Kernel.WriteString("UsbDriver: USB DWC2 controller ready"); Kernel.WriteLn
  ELSE Kernel.WriteString("UsbDriver: USB DWC2 controller init failed"); Kernel.WriteLn END
END Init;

BEGIN
  ControllerCount := 0; FirstController := NIL; Kernel.InstallTermHandler(Cleanup); Init
END UsbDriver.