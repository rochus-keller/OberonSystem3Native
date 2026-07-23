MODULE UsbDriver;  

(*
 Native Oberon ARM DWC2 (DesignWare USB 2.0 OTG) host controller support
 for Raspberry Pi 2/3 and Zero 2 (BCM2835/BCM2836/BCM2837).

 Replaces UsbUhci.Mod (Intel UHCI) with the Synopsys DesignWare USB 2.0
 OTG controller found on BCM283x SoCs.  Uses memory-mapped registers
 instead of PCI I/O ports.
 The following code is a synthesis from these sources: 
 Synopsys DesignWare Cores USB 2.0 OTG Databook
 USPi bare-metal driver by R. Stange https://github.com/rsta2/uspi
 https://github.com/Chadderz121/csud
 https://github.com/torvalds/linux/tree/master/drivers/usb/dwc2
 https://github.com/ultibohub/Core file dwcotg.pas

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
  MaxControllers = 1;  (* RPi has only one USB controller *)
  NumChannels = 8;     (* DWC2 on BCM2835 has 8 host channels *)
  MaxTransferSize = 4096; (* Max size for a single bounce buffer transfer *)

  (** BCM2835 DWC2 USB controller base address (RPi 2/3 peripheral space) *)
  USBBase = 3F980000H;

  (** ARM system timer counter (low 32 bits) *)
  SysTimerCLO = 3F003004H;

  (** Core Global Registers (offsets from USBBase) *)
  rGOTGCTL    = 000H;
  rGOTGINT    = 004H;
  rGAHBCFG    = 008H;
  rGUSBCFG    = 00CH;
  rGRSTCTL    = 010H;
  rGINTSTS    = 014H;
  rGINTMSK    = 018H;
  rGRXFSIZ    = 024H;
  rGNPTXFSIZ  = 028H;
  rGNPTXSTS   = 02CH;
  rGVENDORID  = 040H;
  rGHWCFG2    = 048H;
  rGHWCFG3    = 04CH;
  rGHPTXFSIZ  = 100H;

  (** rGAHBCFG bits *)
  bAhbGlblIntrEn = 0;
  bAhbDmaEn      = 5;
  bAhbWaitAxi    = 4;

  (** rGUSBCFG bits *)
  bUsbPhyIf     = 3;
  bUsbUlpiSel   = 4;
  bUsbSrp       = 8;
  bUsbHnp       = 9;
  bUsbUlpiFsls  = 17;
  bUsbUlpiClk   = 19;
  bUsbUlpiVbus  = 20;
  bUsbTermSel   = 22;
  bUsbForceHost = 29;

  (** rGRSTCTL bits *)
  bRstCsftrst    = 0;
  bRstRxfflsh    = 4;
  bRstTxfflsh    = 5;
  rstTxfnumShift = 6;
  bRstAhbidle    = 31;

  (** Host Registers (offsets from USBBase) *)
  rHCFG     = 400H;
  rHFIR     = 404H;
  rHFNUM    = 408H;
  rHPTXSTS  = 410H;
  rHAINT    = 414H;
  rHAINTMSK = 418H;
  rHPRT     = 440H;

  (** rHPRT bits *)
  bPrtConn    = 0;
  bPrtConnDet = 1;
  bPrtEna     = 2;
  bPrtEnaChg  = 3;
  bPrtOca     = 4;
  bPrtOcaChg  = 5;
  bPrtRes     = 6;
  bPrtSusp    = 7;
  bPrtRst     = 8;
  bPrtPwr     = 12;
  prtSpdShift = 17;
  spdHigh = 0;
  spdFull = 1;
  spdLow  = 2;

  (** Host Channel Registers *)
  rHCCHAR0   = 500H;
  rHCSPLT0   = 504H;
  rHCINT0    = 508H;
  rHCINTMSK0 = 50CH;
  rHCTSIZ0   = 510H;
  rHCDMA0    = 514H;
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
  bHcXfercomp   = 0;
  bHcChhltd     = 1;
  bHcAhberr     = 2;
  bHcStall      = 3;
  bHcNak        = 4;
  bHcAck        = 5;
  bHcNyet       = 6;
  bHcXacterr    = 7;
  bHcBblerr     = 8;
  bHcDatatglerr = 10;

  (** VideoCore Mailbox for USB power control *)
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
    nextPoll: LONGINT;  (* next poll time in microseconds, for async interrupt scheduling *)
  END;

VAR
  FirstController: Dwc2Controller;
  ControllerCount: INTEGER;

  (* When set (via the "Qemu=1" boot config variable), interrupt endpoints
     use the original fully asynchronous DWC2 handling *)
  qemuMode: BOOLEAN;

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

(* Data Synchronization Barrier *)
PROCEDURE -DSB;
CODE {SYSTEM.arm}
  DCW 0F04FH, 0F57FH
END DSB;

(* Data Memory Barrier *)
PROCEDURE -DMB;
CODE {SYSTEM.arm}
  DCW 0F05FH, 0F57FH
END DMB;

(* Clean D-Cache line by virtual address (Host -> Device) *)
PROCEDURE -CleanDCacheLine(adr: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F3AH, 0EE07H
  ADD SP, SP, #4
END CleanDCacheLine;

(* Invalidate D-Cache line by virtual address (Device -> Host) *)
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

(* Convert a virtual address to a bus address (set bits 30..31 for GPU/DMA access) *)
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
      IF h < 10 THEN Kernel.WriteInt(h, 0)
      ELSE Kernel.WriteChar(CHR(ORD("A") + h - 10)) END
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

(* Microsecond-precision busy wait using the ARM system timer *)
PROCEDURE MicroWait(us: LONGINT);
VAR start: LONGINT;
BEGIN
  start := GetWord(SysTimerCLO);
  WHILE GetWord(SysTimerCLO) - start < us DO END
END MicroWait;



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

(* Power on the USB controller via the VideoCore mailbox property interface *)
PROCEDURE PowerOnUSB(): BOOLEAN;
VAR mbuf, resp, i: LONGINT;
BEGIN
  mbuf := SYSTEM.ADR(mbufRaw[0]);
  mbuf := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, mbuf + 63) - {0..5});
  i := 0;
  PutWord(mbuf + i, 32); INC(i, 4);          (* total size *)
  PutWord(mbuf + i, 0); INC(i, 4);           (* request code *)
  PutWord(mbuf + i, tagSetPower); INC(i, 4);    (* tag: set power *)
  PutWord(mbuf + i, 8); INC(i, 4);              (* value buffer size *)
  PutWord(mbuf + i, 8); INC(i, 4);              (* request size *)
  PutWord(mbuf + i, deviceUSB); INC(i, 4);      (* device: USB *)
  PutWord(mbuf + i, 3); INC(i, 4);              (* state: on + wait *)
  PutWord(mbuf + i, tagEnd); INC(i, 4);         (* end tag *)
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
  IF ~WaitForBit(rGRSTCTL, bRstTxfflsh, FALSE, 100) THEN END;
END FlushTxFIFO;

PROCEDURE FlushRxFIFO;
BEGIN
  WriteReg(rGRSTCTL, SYSTEM.VAL(LONGINT, {bRstRxfflsh}));
  IF ~WaitForBit(rGRSTCTL, bRstRxfflsh, FALSE, 100) THEN END
END FlushRxFIFO;



PROCEDURE ResetCore(): BOOLEAN;
BEGIN
  IF ~WaitForBit(rGRSTCTL, bRstAhbidle, TRUE, 100) THEN RETURN FALSE END;
  SetBits(rGRSTCTL, {bRstCsftrst});
  IF ~WaitForBit(rGRSTCTL, bRstCsftrst, FALSE, 100) THEN RETURN FALSE END;
  MilliWait(100);
  RETURN TRUE
END ResetCore;

(* Initialize the DWC2 core: configure PHY, AHB, and USB settings.
   PHY configuration is done AFTER core reset (important for real hardware). *)
PROCEDURE InitCore(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  (* Clear ULPI/VBUS/TermSel bits before reset *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bUsbUlpiVbus, bUsbTermSel});
  WriteReg(rGUSBCFG, val);

  IF ~ResetCore() THEN RETURN FALSE END;

  (* Configure for internal UTMI+ PHY (clear ULPI selection bits) *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bUsbUlpiSel, bUsbPhyIf, bUsbUlpiFsls, bUsbUlpiClk});
  WriteReg(rGUSBCFG, val);

  (* Configure AHB: disable global interrupts, enable DMA, enable wait for AXI writes,
     clear AXI burst length bits 1-2 *)
  val := ReadReg(rGAHBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bAhbGlblIntrEn, 1, 2} + {bAhbWaitAxi, bAhbDmaEn});
  WriteReg(rGAHBCFG, val);

  (* Disable HNP and SRP (not needed for host mode) *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {bUsbHnp, bUsbSrp});
  WriteReg(rGUSBCFG, val);
  RETURN TRUE
END InitCore;

(* Initialize the DWC2 host controller: configure host mode, FIFO sizes,
   and disable all channels *)
PROCEDURE InitHost(): BOOLEAN;
CONST rPCGCCTL = 0E00H;  (* Power and Clock Gating Control register *)
VAR val, rxfsiz, nptxfsiz, i: LONGINT;
BEGIN
  (* Ensure PHY clocks are running (clear any power/clock gating) *)
  WriteReg(rPCGCCTL, 0);

  (* Force host mode *)
  val := ReadReg(rGUSBCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bUsbForceHost});
  WriteReg(rGUSBCFG, val);
  MilliWait(50);

  (* High-Speed mode for root internal hub (clear FSLSSupp and FSLSPclkSel) *)
  val := ReadReg(rHCFG);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) - {0, 1, 2});
  WriteReg(rHCFG, val);

  (* Configure FIFO sizes: Rx=1024, Non-periodic Tx=1024, Periodic Tx=1024 *)
  rxfsiz := 1024; nptxfsiz := 1024;
  WriteReg(rGRXFSIZ, rxfsiz);
  WriteReg(rGNPTXFSIZ, SYSTEM.VAL(LONGINT,
    SYSTEM.VAL(SET, ASH(nptxfsiz, 16)) + SYSTEM.VAL(SET, rxfsiz)));
  WriteReg(rGHPTXFSIZ, SYSTEM.VAL(LONGINT,
    SYSTEM.VAL(SET, ASH(nptxfsiz, 16)) + SYSTEM.VAL(SET, rxfsiz + nptxfsiz)));
  FlushTxFIFO(10H); FlushRxFIFO;

  (* Explicitly disable all channels to clear bootloader state *)
  FOR i := 0 TO NumChannels - 1 DO
    val := ReadReg(rHCCHAR0 + i * chanStep);
    val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
    WriteReg(rHCCHAR0 + i * chanStep, val);
    WriteReg(rHCINT0 + i * chanStep, SYSTEM.VAL(LONGINT, {0..31}))
  END;

  WriteReg(rHAINTMSK, 0);
  WriteReg(rGINTSTS, SYSTEM.VAL(LONGINT, {0..31}));
  RETURN TRUE
END InitHost;

(* Enable root port power *)
PROCEDURE EnableRootPort(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  val := ReadReg(rHPRT);
  (* Preserve status, clear W1C bits, set power *)
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg} + {bPrtPwr});
  WriteReg(rHPRT, val);
  MilliWait(50);
  RETURN TRUE
END EnableRootPort;

(* Reset the root port and wait for it to become enabled.
   On real hardware, we must wait for HPRT.PrtEna to be set by the DWC2
   after de-asserting reset, then allow SOF frames to stabilize. *)
PROCEDURE ResetRootPort(): BOOLEAN;
VAR val: LONGINT;
BEGIN
  (* Assert port reset *)
  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg} + {bPrtRst});
  WriteReg(rHPRT, val);
  MilliWait(60);

  (* De-assert port reset *)
  val := ReadReg(rHPRT);
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bPrtConnDet, bPrtEna, bPrtEnaChg, bPrtOcaChg, bPrtRst});
  WriteReg(rHPRT, val);

  (* Wait for port to actually become enabled (up to 500ms) *)
  IF ~WaitForBit(rHPRT, bPrtEna, TRUE, 500) THEN RETURN FALSE END;

  (* Allow SOF frames to stabilize and device to settle *)
  MilliWait(100);
  RETURN TRUE
END ResetRootPort;



(* Wait for a host channel transaction to complete.
   Returns the HCINT register contents indicating the result.
   On NAK with no split active, automatically re-enables the channel for retry.
   On error or timeout, flushes the Tx FIFO to clear stale data. *)
PROCEDURE WaitForChannelComplete(ch: INTEGER; timeoutUs: LONGINT): SET;
VAR chint: SET; intofs, val, splt, start: LONGINT;
BEGIN
  intofs := rHCINT0 + ch * chanStep;
  start := GetWord(SysTimerCLO);
  chint := {};

  LOOP
    chint := SYSTEM.VAL(SET, ReadReg(intofs));

    IF bHcChhltd IN chint THEN
      (* Channel has halted - check the reason *)
      splt := ReadReg(rHCSPLT0 + ch * chanStep);
      IF (bHcNak IN chint) & (SYSTEM.VAL(SET, splt) * {31} = {}) THEN
        (* NAK on non-split transaction: clear NAK+Halt and re-enable channel *)
        WriteReg(intofs, SYSTEM.VAL(LONGINT, {bHcNak, bHcChhltd}));
        val := ReadReg(rHCCHAR0 + ch * chanStep);
        val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChen} - {bCharChdis});
        WriteReg(rHCCHAR0 + ch * chanStep, val)
      ELSE
        (* Completion, error, or NAK during split: flush Tx FIFO if error *)
        IF ~(bHcXfercomp IN chint) & ~(bHcAck IN chint)
           & ~(bHcNyet IN chint) & ~(bHcNak IN chint) THEN
          FlushTxFIFO(10H)
        END;
        EXIT
      END
    END;

    (* Timeout: forcibly halt the channel *)
    IF GetWord(SysTimerCLO) - start > timeoutUs THEN
      val := ReadReg(rHCCHAR0 + ch * chanStep);
      val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
      WriteReg(rHCCHAR0 + ch * chanStep, val);
      MicroWait(2000);
      chint := SYSTEM.VAL(SET, ReadReg(intofs));
      FlushTxFIFO(10H);
      EXIT
    END
  END;

  WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
  RETURN chint
END WaitForChannelComplete;

(* Program and start a host channel for a USB transaction.
   Sets up HCCHAR, HCTSIZ, bounce buffer DMA, and enables the channel.
   isSplit: TRUE if this is part of a split transaction (affects odd/even frame scheduling).
   isLS: TRUE if the target device is low-speed (sets HCCHAR.LSdev bit). *)
PROCEDURE StartChannel(ch: INTEGER; dev: Usb.UsbDevice; endpoint, eptype: INTEGER;
    dirIn: BOOLEAN; pid: INTEGER; buffer, buflen: LONGINT; mps: INTEGER;
    isSplit, isLS: BOOLEAN);
VAR charVal, tsizVal, base: LONGINT; pktcnt: LONGINT;
BEGIN
  base := ch * chanStep;

  (* DWC2 workaround: non-HS interrupt transfers use control endpoint type.
     Both Linux dwc2 and Ultibo do this (Ultibo line 2877).  The hardware
     has scheduling issues with LS/FS interrupt endpoints; treating them
     as control transfers avoids odd/even frame problems. *)
  IF (eptype = eptInterrupt) & ~dev.HighSpeed THEN
    eptype := eptControl
  END;

  (* Clear all pending interrupts and set interrupt mask *)
  WriteReg(rHCINT0 + base, SYSTEM.VAL(LONGINT, {0..31}));
  WriteReg(rHCINTMSK0 + base, SYSTEM.VAL(LONGINT,
    {bHcXfercomp, bHcChhltd, bHcAhberr, bHcStall, bHcNak, bHcAck,
     bHcNyet, bHcXacterr, bHcBblerr, bHcDatatglerr}));

  (* Build HCCHAR: MPS, endpoint number, direction, speed, type, multi-count, device address *)
  charVal := mps;
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal)
             + SYSTEM.VAL(SET, ASH(endpoint MOD 16, charEpnumShift)));
  IF dirIn THEN
    charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharEpdirIn})
  END;
  IF isLS THEN
    charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharLsdev})
  END;
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal)
             + SYSTEM.VAL(SET, ASH(eptype, charEptypeShift))
             + SYSTEM.VAL(SET, ASH(1, charMcShift)));
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal)
             + SYSTEM.VAL(SET, ASH(dev.Address, charDevaddrShift)));

  (* For periodic endpoints or split transactions, set odd/even frame bit *)
  IF (eptype = eptInterrupt) OR (eptype = eptIso) OR isSplit THEN
    IF TestBits(rHFNUM, {0}) THEN
      charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) - {29})
    ELSE
      charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {29})
    END
  END;

  WriteReg(rHCCHAR0 + base, charVal);

  (* Build HCTSIZ: transfer size, packet count, PID *)
  IF buflen > MaxTransferSize THEN buflen := MaxTransferSize END;
  IF buflen > 0 THEN pktcnt := (buflen + mps - 1) DIV mps ELSE pktcnt := 1 END;
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, buflen) * SYSTEM.VAL(SET, tsizXfersizeMask));
  tsizVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, tsizVal)
             + SYSTEM.VAL(SET, ASH(pktcnt, tsizPktcntShift))
             + SYSTEM.VAL(SET, ASH(pid, tsizPidShift)));
  WriteReg(rHCTSIZ0 + base, tsizVal);

  (* Set up bounce buffer: copy out-data to DMA buffer or invalidate cache for in-data *)
  IF buflen > 0 THEN
    IF ~dirIn THEN
      IF buffer # 0 THEN SYSTEM.MOVE(buffer, chanBuf[ch], buflen) END;
      CleanDCache(chanBuf[ch], buflen)
    ELSE
      InvalidateDCache(chanBuf[ch], buflen)
    END
  END;

  (* Set DMA address and enable the channel *)
  WriteReg(rHCDMA0 + base, GetBusAdr(chanBuf[ch]));
  DSB;
  charVal := ReadReg(rHCCHAR0 + base);
  charVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, charVal) + {bCharChen} - {bCharChdis});
  WriteReg(rHCCHAR0 + base, charVal);
  DSB
END StartChannel;



(* Determine if a device requires split transactions.
   Returns TRUE if the device is not high-speed and is behind a high-speed hub
   (i.e. has a parent hub that is high-speed).
   Also returns the hub address and port number needed for HCSPLIT. *)
PROCEDURE GetSplitInfo(dev: Usb.UsbDevice; VAR hubAddr, hubPort: INTEGER): BOOLEAN;
VAR p, d: Usb.UsbDevice;
BEGIN
  IF (dev = NIL) OR dev.HighSpeed THEN RETURN FALSE END;
  (* Walk up the parent chain to find the nearest high-speed hub *)
  d := dev; p := d.Parent;
  WHILE (p # NIL) & (p # p.Parent) & ~p.HighSpeed DO d := p; p := p.Parent END;
  IF (p # NIL) & (p # p.Parent) & p.HighSpeed THEN
    hubAddr := p.Address; hubPort := d.Port + 1;
    RETURN TRUE
  END;
  RETURN FALSE
END GetSplitInfo;

(* Execute a control/bulk/interrupt transfer with automatic split transaction handling.
   For non-split devices, this is a simple StartChannel + WaitForChannelComplete.
   For split devices, this performs the start-split / complete-split protocol:
     1. Send start-split, wait for ACK from hub
     2. Send complete-split, wait for transfer completion
     3. Handle NYET (hub still processing) and NAK (device busy) retries *)
PROCEDURE ExecuteControlTransfer(ch: INTEGER; req: Usb.UsbTReq; endpoint, eptype: INTEGER;
    dirIn: BOOLEAN; pid: INTEGER; buffer, buflen: LONGINT; mps: INTEGER;
    timeout: LONGINT): SET;
VAR isSplit: BOOLEAN; ssplitVal, csplitVal: LONGINT; chint: SET;
    hubAddr, hubPort: INTEGER; startUs: LONGINT; csplitPid, nyetCount: INTEGER;
BEGIN
  chint := {};
  startUs := GetWord(SysTimerCLO);
  isSplit := GetSplitInfo(req.Device, hubAddr, hubPort);

  IF isSplit THEN
    (* Build HCSPLIT register values for start-split and complete-split *)
    hubAddr := hubAddr MOD 128; hubPort := hubPort MOD 128;
    ssplitVal := SYSTEM.VAL(LONGINT,
      {31, 15, 14} + SYSTEM.VAL(SET, ASH(hubAddr, 7)) + SYSTEM.VAL(SET, hubPort));
    ssplitVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ssplitVal) - {16});  (* clear complete-split bit *)
    csplitVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ssplitVal) + {16});  (* set complete-split bit *)

    LOOP
      (* Check overall timeout *)
      IF GetWord(SysTimerCLO) - startUs > timeout * 1000 THEN RETURN chint END;

      (* Start-split *)
      WriteReg(rHCSPLT0 + ch * chanStep, ssplitVal);
      StartChannel(ch, req.Device, endpoint, eptype, dirIn, pid,
                   buffer, buflen, mps, isSplit, req.Device.LowSpeed);
      chint := WaitForChannelComplete(ch, timeout * 1000);

      IF bHcXfercomp IN chint THEN RETURN chint END;
      IF ~(bHcAck IN chint) THEN RETURN chint END;

      (* Hub accepted the start-split. Complete-split *)
      MicroWait(150);
      nyetCount := 0;

      LOOP
        WriteReg(rHCSPLT0 + ch * chanStep, csplitVal);
        csplitPid := pid;
        IF ~dirIn THEN csplitPid := pidData0 END;

        IF ~dirIn THEN
          StartChannel(ch, req.Device, endpoint, eptype, dirIn, csplitPid,
                       0, 0, mps, isSplit, req.Device.LowSpeed)
        ELSE
          StartChannel(ch, req.Device, endpoint, eptype, dirIn, csplitPid,
                       buffer, buflen, mps, isSplit, req.Device.LowSpeed)
        END;

        chint := WaitForChannelComplete(ch, timeout * 1000);

        IF bHcXfercomp IN chint THEN RETURN chint END;
        IF bHcNyet IN chint THEN
          (* Hub still processing, retry complete-split *)
          INC(nyetCount);
          IF nyetCount > 200 THEN RETURN chint END;
          MicroWait(20)
        ELSIF bHcNak IN chint THEN
          (* Device NAKed via hub, retry from start-split *)
          EXIT
        ELSE
          RETURN chint  (* Error: Stall, XactErr, etc. *)
        END
      END
    END
  ELSE
    (* Non-split: simple single transaction *)
    WriteReg(rHCSPLT0 + ch * chanStep, 0);
    StartChannel(ch, req.Device, endpoint, eptype, dirIn, pid,
                 buffer, buflen, mps, isSplit, req.Device.LowSpeed);
    RETURN WaitForChannelComplete(ch, timeout * 1000)
  END
END ExecuteControlTransfer;



(* Execute a USB control transfer (Setup -> Data -> Status phases).
   Handles split transactions transparently via ExecuteControlTransfer. *)
PROCEDURE DoControlTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR ch: INTEGER; chint, status: SET; pid: INTEGER; dirIn: BOOLEAN; mps: INTEGER;
    restlen, curlen, databuf: LONGINT; datatoggle: BOOLEAN; timeout: LONGINT;
    c0: CHAR;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  mps := req.Device.Descriptor.bMaxPacketSize0;
  IF mps = 0 THEN mps := 8 END;
  (* High-speed devices at address 0 use 64-byte max packet size *)
  IF req.Device.HighSpeed & (mps = 8) & (req.Device.Address = 0) THEN mps := 64 END;
  (* Extra settle time for non-high-speed devices at address 0 *)
  IF (req.Device.Address = 0) & (~req.Device.HighSpeed) THEN MilliWait(50) END;

  timeout := req.Timeout;
  IF timeout = 0 THEN timeout := 5000 END;
  IF timeout = -1 THEN timeout := 30000 END;

  SYSTEM.GET(req.ControlMessage, c0);

  (* Setup phase *)
  SYSTEM.MOVE(req.ControlMessage, chanBuf[ch], 8);
  CleanDCache(chanBuf[ch], 8);
  chint := ExecuteControlTransfer(ch, req, req.Endpoint MOD 16, eptControl,
                                  FALSE, pidSetup, 0, 8, mps, timeout);
  IF ~(bHcXfercomp IN chint) THEN
    FreeChannel(con, ch);
    RETURN Usb.ResCRCTimeout
  END;

  (* Data phase (if any) *)
  IF req.BufferLen > 0 THEN
    dirIn := SYSTEM.VAL(SET, c0) * {7} # {};
    datatoggle := TRUE;
    restlen := req.BufferLen; databuf := req.Buffer;

    WHILE restlen > 0 DO
      IF restlen > mps THEN curlen := mps ELSE curlen := restlen END;
      IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;
      chint := ExecuteControlTransfer(ch, req, req.Endpoint MOD 16, eptControl,
                                      dirIn, pid, databuf, curlen, mps, timeout);

      IF (dirIn) & (bHcXfercomp IN chint) & (databuf # 0) THEN
        InvalidateDCache(chanBuf[ch], curlen);
        SYSTEM.MOVE(chanBuf[ch], databuf, curlen)
      END;

      IF ~(bHcXfercomp IN chint) THEN
        FreeChannel(con, ch);
        RETURN Usb.ResCRCTimeout
      END;

      datatoggle := ~datatoggle; INC(databuf, curlen); DEC(restlen, curlen)
    END
  END;

  (* Status phase (direction is opposite of data phase) *)
  IF req.BufferLen > 0 THEN
    dirIn := ~(SYSTEM.VAL(SET, c0) * {7} # {})
  ELSE
    dirIn := TRUE
  END;
  chint := ExecuteControlTransfer(ch, req, req.Endpoint MOD 16, eptControl,
                                  dirIn, pidData1, 0, 0, mps, timeout);
  FreeChannel(con, ch);

  IF bHcXfercomp IN chint THEN RETURN Usb.ResOK
  ELSE RETURN Usb.ResCRCTimeout END
END DoControlTransfer;

(* Execute a USB bulk transfer.
   Splits large transfers into max-packet-size chunks.
   Handles split transactions transparently via ExecuteControlTransfer. *)
PROCEDURE DoBulkTransfer(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR ch, pid, pipesize: INTEGER; chint: SET; dirIn, datatoggle: BOOLEAN;
    restlen, curlen, databuf: LONGINT; timeout: LONGINT;
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
  restlen := req.BufferLen; databuf := req.Buffer;

  WHILE restlen > 0 DO
    IF restlen > pipesize THEN curlen := pipesize ELSE curlen := restlen END;
    IF datatoggle THEN pid := pidData1 ELSE pid := pidData0 END;
    chint := ExecuteControlTransfer(ch, req, req.Endpoint MOD 16, eptBulk,
                                    dirIn, pid, databuf, curlen, pipesize, timeout);

    IF (dirIn) & (bHcXfercomp IN chint) & (databuf # 0) THEN
      InvalidateDCache(chanBuf[ch], curlen);
      SYSTEM.MOVE(chanBuf[ch], databuf, curlen)
    END;

    IF ~(bHcXfercomp IN chint) THEN
      IF bHcNak IN chint THEN
        MicroWait(50)  (* NAK: brief retry delay *)
      ELSE
        IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
        ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle END;
        FreeChannel(con, ch);
        RETURN Usb.ResCRCTimeout
      END
    ELSE
      datatoggle := ~datatoggle; INC(databuf, curlen); DEC(restlen, curlen)
    END
  END;

  IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle
  ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle END;
  FreeChannel(con, ch);
  RETURN Usb.ResOK
END DoBulkTransfer;



(* QEMU async path only: (re)arm the host channel of an interrupt IN/OUT
   endpoint and leave it running.  Programs the channel exactly like a
   non-split interrupt transaction; the completion is picked up later by the
   non-blocking status read in UpcallProbeTrans. *)
PROCEDURE ArmInterruptChannel(req: Usb.UsbTReq; ch: INTEGER);
VAR dirIn, datatoggle: BOOLEAN; pid, pipesize: INTEGER;
BEGIN
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
  WriteReg(rHCSPLT0 + ch * chanStep, 0);
  StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt,
    dirIn, pid, req.Buffer, req.BufferLen, pipesize, FALSE, req.Device.LowSpeed)
END ArmInterruptChannel;

(* Set up an asynchronous interrupt transfer.
   Allocates a channel and schedules the first poll based on IRQInterval. *)
PROCEDURE PrepareAsyncInterrupt(con: Dwc2Controller; req: Usb.UsbTReq): SET;
VAR ch: INTEGER; spec: Dwc2ConSpec;
BEGIN
  ch := AllocateChannel(con);
  IF ch = -1 THEN RETURN Usb.ResInternal END;

  NEW(spec); spec.chan := ch;
  req.ConSpec := spec;
  req.Status := Usb.ResInProgress;
  req.next := con.TReqList; con.TReqList := req;

  IF qemuMode THEN
    ArmInterruptChannel(req, ch)
  ELSE
    (* Schedule first poll *)
    spec.nextPoll := GetWord(SysTimerCLO) + req.IRQInterval * 1000
  END;
  RETURN Usb.ResInProgress
END PrepareAsyncInterrupt;



PROCEDURE UpcallReset(con: Usb.UsbController);
VAR val, spd: LONGINT;
BEGIN
  WITH con: Dwc2Controller DO
    IF ResetRootPort() THEN
      val := ReadReg(rHPRT);
      spd := ASH(val, -prtSpdShift) MOD 4;
      con.RootHub.HighSpeed := (spd = spdHigh);
      con.RootHub.LowSpeed := (spd = spdLow)
    END
  END
END UpcallReset;

PROCEDURE UpcallGetPortStatus(con: Usb.UsbController; port: INTEGER): SET;
VAR val: LONGINT; status: SET; spd: LONGINT;
BEGIN
  status := {}; val := ReadReg(rHPRT);
  IF SYSTEM.VAL(SET, val) * {bPrtConn} # {} THEN
    status := status + Usb.PortStatusDevicePresent END;
  IF SYSTEM.VAL(SET, val) * {bPrtEna} # {} THEN
    status := status + Usb.PortStatusEnabled END;
  IF SYSTEM.VAL(SET, val) * {bPrtRst} # {} THEN
    status := status + Usb.PortStatusReset END;
  spd := ASH(val, -prtSpdShift) MOD 4;
  IF spd = spdLow THEN status := status + Usb.PortStatusLowSpeed
  ELSIF spd = spdHigh THEN status := status + Usb.PortStatusHighSpeed END;
  RETURN status
END UpcallGetPortStatus;

PROCEDURE UpcallGetPortCount(con: Usb.UsbController): INTEGER;
BEGIN RETURN 1
END UpcallGetPortCount;

PROCEDURE UpcallEnablePort(con: Usb.UsbController; port: INTEGER);
VAR val, spd: LONGINT; i: INTEGER;
BEGIN
  WITH con: Dwc2Controller DO
    (* Halt all channels and flush FIFOs before re-enabling port *)
    FOR i := 0 TO NumChannels - 1 DO
      val := ReadReg(rHCCHAR0 + i * chanStep);
      val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
      WriteReg(rHCCHAR0 + i * chanStep, val);
      MicroWait(2000);
      WriteReg(rHCINT0 + i * chanStep, SYSTEM.VAL(LONGINT, {0..31}))
    END;
    con.chanAllocated := {};
    FlushTxFIFO(10H); FlushRxFIFO;

    IF ResetRootPort() THEN
      val := ReadReg(rHPRT);
      spd := ASH(val, -prtSpdShift) MOD 4;
      con.RootHub.HighSpeed := (spd = spdHigh);
      con.RootHub.LowSpeed := (spd = spdLow)
    END
  END
END UpcallEnablePort;

PROCEDURE UpcallDisablePort(con: Usb.UsbController; port: INTEGER);
VAR val: LONGINT;
BEGIN
  val := ReadReg(rHPRT);
  (* W1C: write 1 to PrtEna to disable it; clear other W1C bits to avoid side effects *)
  val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val)
         - {bPrtConnDet, bPrtEnaChg, bPrtOcaChg} + {bPrtEna});
  WriteReg(rHPRT, val)
END UpcallDisablePort;

(* Dispatch a transfer request to the appropriate handler *)
PROCEDURE UpcallSendReq(con: Usb.UsbController; req: Usb.UsbTReq);
BEGIN
  WITH con: Dwc2Controller DO
    IF req.Typ = Usb.TransferControl THEN
      req.Status := DoControlTransfer(con, req)
    ELSIF req.Typ = Usb.TransferBulk THEN
      req.Status := DoBulkTransfer(con, req)
    ELSIF req.Typ = Usb.TransferInterrupt THEN
      IF req.Timeout # 0 THEN req.Status := Usb.ResInternal
      ELSE req.Status := PrepareAsyncInterrupt(con, req) END
    ELSE
      req.Status := Usb.ResInternal
    END
  END
END UpcallSendReq;

(* Poll an async interrupt transfer for completion.
   Uses timer-based polling (nextPoll) to respect the device's IRQ interval.
   For split transactions, performs the full start-split / complete-split protocol.
   For non-split devices, does a simple channel transaction. *)
PROCEDURE UpcallProbeTrans(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec; chint: SET; dirIn, datatoggle, isSplit: BOOLEAN;
    pid, pipesize, csplitPid, ch, nyetCount, hubAddr, hubPort: INTEGER;
    timeoutUs, ssplitVal, csplitVal, intofs: LONGINT;
BEGIN
  IF req.ConSpec = NIL THEN req.Status := Usb.ResInternal; RETURN END;
  spec := req.ConSpec(Dwc2ConSpec);

  IF qemuMode THEN
    (* the channel is already running.  Just read its interrupt
       status register (non-blocking) and act on it. *)
    intofs := rHCINT0 + spec.chan * chanStep;
    chint := SYSTEM.VAL(SET, ReadReg(intofs));
    IF (bHcXfercomp IN chint) OR (bHcStall IN chint)
       OR (bHcAhberr IN chint) OR (bHcBblerr IN chint) THEN
      WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
      IF bHcXfercomp IN chint THEN
        req.Status := Usb.ResOK;
        dirIn := SYSTEM.VAL(SET, req.Endpoint) * {7} # {};
        IF dirIn THEN
          IF (req.Buffer # 0) & (req.BufferLen > 0) THEN
            InvalidateDCache(chanBuf[spec.chan], req.BufferLen);
            SYSTEM.MOVE(chanBuf[spec.chan], req.Buffer, req.BufferLen)
          END;
          req.Device.DataToggleIn[req.Endpoint MOD 16] :=
            ~req.Device.DataToggleIn[req.Endpoint MOD 16]
        ELSE
          req.Device.DataToggleOut[req.Endpoint MOD 16] :=
            ~req.Device.DataToggleOut[req.Endpoint MOD 16]
        END
      ELSE
        req.Status := Usb.ResCRCTimeout
      END
    ELSIF bHcChhltd IN chint THEN
      (* Halted: on NAK (no data yet) re-arm and stay in progress; any other
         halt is treated as a transient error and the channel is re-armed. *)
      WriteReg(intofs, SYSTEM.VAL(LONGINT, {0..31}));
      ArmInterruptChannel(req, spec.chan)
    END;
    (* else: still in progress, leave status unchanged *)
    RETURN
  END;

  (* Check if it's time to poll yet *)
  IF GetWord(SysTimerCLO) - spec.nextPoll < 0 THEN RETURN END;

  ch := spec.chan;
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

  timeoutUs := 5000;
  isSplit := GetSplitInfo(req.Device, hubAddr, hubPort);

  IF isSplit THEN
    (* Split transaction polling for devices behind a high-speed hub *)
    hubAddr := hubAddr MOD 128; hubPort := hubPort MOD 128;
    ssplitVal := SYSTEM.VAL(LONGINT,
      {31, 15, 14} + SYSTEM.VAL(SET, ASH(hubAddr, 7)) + SYSTEM.VAL(SET, hubPort));
    ssplitVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ssplitVal) - {16});
    csplitVal := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ssplitVal) + {16});

    (* Phase 1: Start-split *)
    WriteReg(rHCSPLT0 + ch * chanStep, ssplitVal);
    StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid,
                 req.Buffer, req.BufferLen, pipesize, TRUE, req.Device.LowSpeed);
    chint := WaitForChannelComplete(ch, timeoutUs);

    IF bHcXfercomp IN chint THEN
      (* Immediate completion (unlikely but possible) *)
      req.Status := Usb.ResOK;
      IF dirIn & (req.Buffer # 0) & (req.BufferLen > 0) THEN
        InvalidateDCache(chanBuf[ch], req.BufferLen);
        SYSTEM.MOVE(chanBuf[ch], req.Buffer, req.BufferLen)
      END;
      IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := ~datatoggle
      ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := ~datatoggle END;
      RETURN
    END;

    IF ~(bHcAck IN chint) THEN
      (* Hub did not accept start-split, reschedule *)
      spec.nextPoll := GetWord(SysTimerCLO) + req.IRQInterval * 1000;
      RETURN
    END;

    (* Phase 2: Complete-split (hub accepted, now wait for device data) *)
    MicroWait(125);
    nyetCount := 0;

    LOOP
      WriteReg(rHCSPLT0 + ch * chanStep, csplitVal);
      csplitPid := pid;
      IF ~dirIn THEN csplitPid := pidData0 END;

      IF ~dirIn THEN
        StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn,
                     csplitPid, 0, 0, pipesize, TRUE, req.Device.LowSpeed)
      ELSE
        StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn,
                     csplitPid, req.Buffer, req.BufferLen, pipesize, TRUE, req.Device.LowSpeed)
      END;

      chint := WaitForChannelComplete(ch, timeoutUs);

      IF bHcXfercomp IN chint THEN
        (* Transfer complete - data received *)
        req.Status := Usb.ResOK;
        IF dirIn & (req.Buffer # 0) & (req.BufferLen > 0) THEN
          InvalidateDCache(chanBuf[ch], req.BufferLen);
          SYSTEM.MOVE(chanBuf[ch], req.Buffer, req.BufferLen)
        END;
        IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := ~datatoggle
        ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := ~datatoggle END;
        RETURN
      END;

      IF bHcNyet IN chint THEN
        (* Hub still processing, retry complete-split *)
        INC(nyetCount);
        IF nyetCount > 20 THEN
          spec.nextPoll := GetWord(SysTimerCLO) + req.IRQInterval * 1000;
          RETURN
        END;
        MicroWait(100)
      ELSE
        (* NAK or error, reschedule *)
        spec.nextPoll := GetWord(SysTimerCLO) + req.IRQInterval * 1000;
        RETURN
      END
    END

  ELSE
    (* Non-split: direct interrupt poll *)
    WriteReg(rHCSPLT0 + ch * chanStep, 0);
    StartChannel(ch, req.Device, req.Endpoint MOD 16, eptInterrupt, dirIn, pid,
                 req.Buffer, req.BufferLen, pipesize, FALSE, req.Device.LowSpeed);
    chint := WaitForChannelComplete(ch, timeoutUs);

    IF bHcXfercomp IN chint THEN
      req.Status := Usb.ResOK;
      IF dirIn & (req.Buffer # 0) & (req.BufferLen > 0) THEN
        InvalidateDCache(chanBuf[ch], req.BufferLen);
        SYSTEM.MOVE(chanBuf[ch], req.Buffer, req.BufferLen)
      END;
      IF dirIn THEN req.Device.DataToggleIn[req.Endpoint MOD 16] := ~datatoggle
      ELSE req.Device.DataToggleOut[req.Endpoint MOD 16] := ~datatoggle END
    ELSE
      (* No data yet, reschedule *)
      spec.nextPoll := GetWord(SysTimerCLO) + req.IRQInterval * 1000
    END
  END
END UpcallProbeTrans;

(* Cancel and clean up an async interrupt transfer *)
PROCEDURE UpcallDeleteTrans(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec; reqtmp: Usb.UsbTReq; val: LONGINT;
BEGIN
  IF req.ConSpec = NIL THEN RETURN END;
  WITH con: Dwc2Controller DO
    spec := req.ConSpec(Dwc2ConSpec);
    IF spec.chan >= 0 THEN
      (* Halt the channel *)
      val := ReadReg(rHCCHAR0 + spec.chan * chanStep);
      val := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) + {bCharChdis, bCharChen});
      WriteReg(rHCCHAR0 + spec.chan * chanStep, val);
      MilliWait(2);
      WriteReg(rHCINT0 + spec.chan * chanStep, SYSTEM.VAL(LONGINT, {0..31}));
      FreeChannel(con, spec.chan)
    END;
    (* Remove from linked list *)
    reqtmp := con.TReqList;
    IF reqtmp = req THEN con.TReqList := req.next
    ELSE
      WHILE (reqtmp # NIL) & (reqtmp.next # req) DO reqtmp := reqtmp.next END;
      IF reqtmp # NIL THEN reqtmp.next := req.next END
    END;
    req.ConSpec := NIL
  END
END UpcallDeleteTrans;

(* Restart an async interrupt transfer after the previous one completed.
   Reschedules the next poll based on the device's IRQ interval. *)
PROCEDURE UpcallRestartInterrupt(con: Usb.UsbController; req: Usb.UsbTReq);
VAR spec: Dwc2ConSpec;
BEGIN
  IF req.Typ # Usb.TransferInterrupt THEN HALT(303) END;
  IF req.ConSpec = NIL THEN req.Status := Usb.ResInternal; RETURN END;
  IF (req.Status * Usb.ResInProgress) # {} THEN RETURN END;

  spec := req.ConSpec(Dwc2ConSpec);
  IF qemuMode THEN
    (* re-arm the channel immediately *)
    req.Status := Usb.ResInProgress;
    ArmInterruptChannel(req, spec.chan)
  ELSE
    spec.nextPoll := GetWord(SysTimerCLO) + req.IRQInterval * 1000;
    req.Status := Usb.ResInProgress
  END
END UpcallRestartInterrupt;




PROCEDURE InitController(): BOOLEAN;
VAR con: Dwc2Controller; vendorId, base, i: LONGINT; s: ARRAY 16 OF CHAR;
BEGIN
  IF ControllerCount >= MaxControllers THEN RETURN FALSE END;

  Kernel.GetConfig("Qemu", s);
  qemuMode := (s[0] # 0X) & (s # "0");
  IF qemuMode THEN
    Kernel.WriteString("UsbDriver: Qemu mode, async interrupt handling enabled"); Kernel.WriteLn
  END;

  (* Set up per-channel DMA bounce buffers, 64-byte aligned *)
  base := SYSTEM.ADR(chanBufRaw[0]);
  base := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, base + 63) - {0..5});
  FOR i := 0 TO NumChannels - 1 DO chanBuf[i] := base + i * MaxTransferSize END;

  DMB;
  IF ~PowerOnUSB() THEN END;
  MilliWait(100);

  (* Verify DWC2 vendor ID *)
  vendorId := ReadReg(rGVENDORID);
  IF SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, vendorId) * {16..31}) # 4F540000H THEN
    RETURN FALSE
  END;

  IF ~InitCore() THEN RETURN FALSE END;
  IF ~InitHost() THEN RETURN FALSE END;
  IF ~EnableRootPort() THEN RETURN FALSE END;
  MilliWait(200);

  (* Create and register the controller object *)
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

  (* Root hub speed is set by UpcallEnablePort after port reset.
     Do NOT hardcode HighSpeed here; on Pi Zero 2 W there is no internal
     LAN9514 hub, so the root port may negotiate at FS or LS. *)
  DMB;
  RETURN TRUE
END InitController;

(* Shutdown: halt all channels and unregister the controller *)
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
  IF InitController() THEN END
END Init;

BEGIN
  ControllerCount := 0; FirstController := NIL; qemuMode := FALSE;
  Kernel.InstallTermHandler(Cleanup);
  Init
END UsbDriver.
