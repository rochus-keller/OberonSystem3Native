(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Net3Com90x;

(** Card Configuration
 3C90xMedia =
  1 -> 10Base-T
  2 -> 10 Mbps AU
  4 -> 10Base2
  5 -> 100Base-TX
  6 -> 100Base-FX
  7 -> MII
  9 -> Auto (3C90xB only)
 3C90xDuplex =
  0 -> read duplex setting from EPROM
  1 -> half-duplex
  2 -> full-duplex
*) (* WARNING: these values correspond to the xcvrSelect values + 1. 3C90x-TR, p4-10 *)
 
(*
 Driver for 3Com90xB NIC cards
 Supporded cards:  see InstallDevice procedure
 
 ToDo:
  * use card checksum features
 
 Authors and Contributors:
  Reto Strobl, Pieter Muller, Jaco Geldenhuys, Patrik Reali
 
 History:
 0.9.5 /
   * support for 3C556 (tornado)
 
 0.9.4 /
   * 3C90xDuplex
   * Avail: drop frame if there's an error in it
   * EepromRead: reg is an INTEGER
   * IN/OUT checked for data size
   
 0.9.3 /
   * Cleanup procedure
   * handling of rxUnderrun (FifoDiagnostic w4/4) -> ArxUnderrun
   * handling of txOverrun (FifoDiagnostic w4/4) -> AtxOverrun
   * ResetRx procedure
   * ResetTx procedure
   * Avail, trace errors
   * InitHostInterface: writes words instead of bytes
   * support for 90x NICs
   * mark 905B specific stuff -> (* 905B only *)
    InitHostInterface, autonegotiation
   * device.typeB set for 3C90xB cards
   * set default media for every device
   * allow overriding the default media
 
 0.9.2 / 03 April 2000 / Patrik Reali
   * card detection fixed: only first card installed, bug in detection fixed
 
 0.9.1 / March 2000 / Patrik Reali
   refactoring of design:
   * autodetection removed (did not work)
   * card setup is determined by the vendorId (InitHostInterface)
   * card detection simplified
   * removed unused variables and constants
   * output to Kernel Log only
 
 0.9.0 / 
   first version by Reto Strobl (Semesterarbeit summer 1998)
   co-assistance: Jaco Geldenhuys
   supervisor: Pieter Muller
 
 Summer 98:
   first version as Semester Work by Reto Strobl
   http://www.cs.inf.ethz.ch/gutknecht/stud_work/1998WS_rstrobl/
*) 
(* beta *)

 IMPORT SYSTEM, PCI, Kernel, NetBase;

 CONST
  debug = FALSE;
  EthernetFrameSize = 1514; (*ethernet frame size*)
  
 (* number of frames buffered by the driver *)
  UpBufferSize = 10;  DownBufferSize = 8;
 
 (*Registers*)
  DownListPtr = 24H;
  CommReg = 0EH;
  DmaCtr = 20H;
  
 (*command Register commands (without parameters) *)
  RxThresh = 8800H;
  RxEnable = 2000H;
  RxReset = 2800H;
  TxEnable = 4800H;
  TxReset = 5800H;
  UpUnstall = 3001H;
  DnStall = 3002H;
  DnUnstall = 3003H;
  EnableDcConverter = 1000H;
  DisableDcConverter = 0D800H;
  
 (* Media Types *)
  MediaMask = {20..23};
  Base10T = {};  AUI = {20};  Base10Coax = {21, 20};  Base100TX = {22};  
  Base100FX = {22, 20};  MII = {22, 21};  Auto = {23};
    
 (* Flags, Card Configuration *)
  typeB = 1; (* 3C90xB cards (newer NICs) *)
  tornado = 2; (* 3C556 *)
  
 TYPE
  DPDDesc = RECORD
   next: LONGINT;
      status: LONGINT;
      data0Adr, data0Len: LONGINT;  (* the ethernet-packet descriptor, points to the header at end *)
      dataAdr, dataLen : LONGINT;
      header: ARRAY 18 OF CHAR;  (* frame header: integrated in the dpd to avoid separate allocation, though
                     not part of a dpd *)
   padding: ARRAY 6 OF CHAR;
  END; (* !! SIZE(DPDDesc) MOD 8 = 0 !! -> DPD Type 0 must point to addresses on 8-byte boundaries *)
  
  UPD = POINTER TO UPDDesc;
  UPDDesc = RECORD
   next : UPD;
   status : SET;
   fragAddr, fragLen : LONGINT;
   packet: ARRAY EthernetFrameSize OF CHAR;  (* buffer for the incoming frames *)
  END;
  
  Device = POINTER TO DeviceDesc;
  DeviceDesc = RECORD(NetBase.DeviceDesc)
   base: LONGINT; (* mapped I/O address *)
   devId: LONGINT; (* device id from PCI *)
   config: SET;
   media: SET;  (* media set in internalConfig (W3/0), cached field *)
   
   up : UPD;
   dpd : POINTER TO ARRAY DownBufferSize OF DPDDesc; (*down-buffer, dyn. allocated to ensure alignment*)
   curdpd: LONGINT;
  END;
   
 VAR
  overrideMedia, overrideDuplex: LONGINT;
  
  last: Device; (* debug: last device allocated *)
  
  AdetectedHosts, AupError,
  AupOverrun, AruntFrame, AalignmentError, AcrcError, AoversizedFrame, AdribbleBits, AupOverflow,
  ArxUnderrun, AtxOverrun, AdroppedFrames,
  AsentFrames, AsentBytes, AreceivedFrames, AreceivedBytes,
  AtxStatusOverflow, AmaxCollisions, AtxUnderrun, AtxJabber,
  AsendNonEmpty, AsendFull: LONGINT; (*counters*)


PROCEDURE SwitchToWindow(base: LONGINT;  window : INTEGER);
BEGIN
 ASSERT((0 <= window) & (window <= 7));
 SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, 800H + window));
END SwitchToWindow;

(* IssueCommand - Issue a command and wait for completition *)

PROCEDURE IssueCommand(base: LONGINT;  cmd: INTEGER);
VAR  s: INTEGER;
BEGIN
 SYSTEM.PORTOUT(base + CommReg, cmd);
 REPEAT
  SYSTEM.PORTIN(base+CommReg, s)
 UNTIL ~(12 IN SYSTEM.VAL(SET, s));
END IssueCommand;

PROCEDURE ResetRx(d: Device;  setThresh: BOOLEAN);
VAR  base: LONGINT;
BEGIN
 base := d.base;
 IssueCommand(base, RxReset);
 IF setThresh THEN
  SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, RxThresh+1500 DIV 4));
  SYSTEM.PORTOUT(base + DmaCtr, SYSTEM.VAL(LONGINT, 20H));   (* DmaCtr: upRxEarlyEnable *)
 END;
 SYSTEM.PORTOUT(base + 38H, SYSTEM.ADR(d.up^));   (* UpListPtr *)
 SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER,8007H));  (*RxFilter: individual, broadcast, multicast *)
END ResetRx;

PROCEDURE ResetTx(d: Device);
VAR  base: LONGINT;
BEGIN
 base := d.base;
 IssueCommand(base, TxReset);
 SYSTEM.PORTOUT(base + DownListPtr, SYSTEM.VAL(LONGINT, 0)); 
END ResetTx;

(* MII Procedures 
PROCEDURE Wait200;
VAR  t: Kernel.MilliTimer;
BEGIN
 Kernel.SetTimer(t, 2);  REPEAT  UNTIL Kernel.Expired(t)
END Wait200;

PROCEDURE ZCycle;
CONST clk = 0;  data = 1;  dir = 2;
VAR  i: INTEGER;
BEGIN
 SYSTEM.PORTIN(BaseAdr+08H,  i);
 SYSTEM.PORTOUT(BaseAdr+08H,  SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, i) - {clk}));  Wait200;
 SYSTEM.PORTOUT(BaseAdr+08H,  SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, i) - {dir}));  Wait200
END ZCycle;

PROCEDURE WriteCycle(base: SET;  data, len: LONGINT); (*write from msb to lsb *)
CONST clk = 0;  dta = 1;  dir = 2;
BEGIN
 WHILE (len > 0) DO
  DEC(len);
  SYSTEM.PORTOUT(BaseAdr+08H,  SYSTEM.VAL(INTEGER, base));  Wait200;
  IF ODD(SYSTEM.LSH(data, -len)) THEN
   SYSTEM.PORTOUT(BaseAdr+08H,  SYSTEM.VAL(INTEGER, base+{clk+dta}))
  ELSE
   SYSTEM.PORTOUT(BaseAdr+08H,  SYSTEM.VAL(INTEGER, base+{clk}))
  END;
  Wait200;
 END
END WriteCycle;

PROCEDURE ReadCycle(base: SET;  VAR data: LONGINT;  len: LONGINT);
CONST clk = 0;  dta = 1;  dir = 2;
VAR  x: INTEGER;
BEGIN
 WHILE (len > 0) DO
  SYSTEM.PORTOUT(BaseAdr+08H,  SYSTEM.VAL(INTEGER, base));  Wait200;
  SYSTEM.PORTOUT(BaseAdr+08H,  SYSTEM.VAL(INTEGER, base+{clk}));  Wait200;
  SYSTEM.PORTIN(BaseAdr+08H,  x);  Wait200;
  data := data * 2;
  IF  dta IN SYSTEM.VAL(SET, x)  THEN  INC(data)  END;
  DEC(len)
 END
END ReadCycle;

PROCEDURE ReadFrame(phiadr, regadr: LONGINT;  VAR data: LONGINT);
VAR  error: BOOLEAN;  base: SET;
BEGIN
 base := {2};
 WriteCycle(base, -1, 32);
 WriteCycle(base, 6, 4);
 WriteCycle(base, phiadr, 5);
 WriteCycle(base, regadr, 5);
 ZCycle;
 data := 0;  ReadCycle({}, data, 1);
 error := data # 0;
 ReadCycle({}, data, 16);
 ZCycle;
 IF error THEN data := -1 END;
END ReadFrame;

PROCEDURE Test*;
VAR i, data: LONGINT;
BEGIN
 FOR i := 0 TO 6 DO
  ReadFrame(18H, i, data);
  Texts.WriteInt(W, i, 3); Texts.WriteHex(W, data);  Texts.WriteLn(W);
  Texts.Append(T, W.buf);
 END;
END Test;
*)

(* EepromRead - Read one eeprom register *)

PROCEDURE EepromRead(base: LONGINT;  flags: SET;  reg: INTEGER;  VAR val: INTEGER);
BEGIN
 ASSERT(( 0<=reg) & (reg< 64));
 IF tornado IN flags THEN  INC(reg, 230H)  ELSE  INC(reg, 80H)  END;
 SwitchToWindow(base, 0);
 SYSTEM.PORTOUT(base+0AH, reg); (* Read Register - 162 us *)
 REPEAT
  SYSTEM.PORTIN(base+0AH, val);
 UNTIL ~(15 IN SYSTEM.VAL(SET, val)); (*  Wait till ~eepromBusy *)
 SYSTEM.PORTIN(base+0CH, val);
END EepromRead;

(* InitHostAdress - Read Ethernet Address from eeprom and set the NIC *)

PROCEDURE InitHostAddress(d: Device);
VAR base: LONGINT;  i: INTEGER; word : ARRAY 3 OF INTEGER; 
BEGIN
 base := d.base;
 EepromRead(base, d.config, 0AH, word[0]); (* OEM Node Address / word 0 *)
 EepromRead(base, d.config, 0BH, word[1]); (* OEM Node Address / word 1 *)
 EepromRead(base, d.config, 0CH, word[2]); (* OEM Node Address / word 2 *)
 SwitchToWindow(base, 2);
 FOR i := 0 TO 2 DO
  word[i] := SYSTEM.ROT(word[i], 8);
  d.hostAdr[2*i] := CHR(word[i]);
  d.castAdr[2*i] := 0FFX;
  d.hostAdr[2*i+1] := CHR(word[i] DIV 256);
  d.castAdr[2*i+1] := 0FFX;
  SYSTEM.PORTOUT(base+2*i, word[i]); (* configure StationAddress *)
  SYSTEM.PORTOUT(base+6+2*i, SYSTEM.VAL(INTEGER, 0))    (* configure StationMask, no mask*)
 END;
  (* address also displayed by NetSystem.Show *)
 Kernel.WriteString("Net3Com90x: Host Address ");
 FOR i := 0 TO 4 DO
  Kernel.WriteHex(ORD(d.hostAdr[i]), -2); Kernel.WriteChar(":")
 END;
 Kernel.WriteHex(ORD(d.hostAdr[5]), -2);
 Kernel.WriteLn

END InitHostAddress;

(* Configure the communication interface (auto, MII) *)

PROCEDURE InitHostInterface(d: Device);
VAR  config: SET;  base: LONGINT;
BEGIN
 base := d.base;
 SwitchToWindow(base, 3);
 SYSTEM.PORTIN(base + 0H, config);  (* Win 3 / Off 0 - InternalConfig, p 4-8 *)
 IF overrideMedia # 0 THEN
  d.media := SYSTEM.VAL(SET,  SYSTEM.LSH(overrideMedia-1, 20)) * MediaMask
 ELSIF  ~(24 IN config)  THEN
  d.media := config * MediaMask  (* autoselect off, no changes needed *)
 (*ELSE
    d.media set in DetectHost *)
 END;
 Kernel.WriteString("Net3Com90x: using media ");
 CASE  SYSTEM.LSH(SYSTEM.VAL(LONGINT, d.media), -20)  OF
 |  0:  Kernel.WriteString("10Base-T")
 |  1:  Kernel.WriteString("10 Mbps AUI")
 |  3:  Kernel.WriteString("10Base2")
 |  4:  Kernel.WriteString("100Base-TX")
 |  5:  Kernel.WriteString("100Base-FX")
 |  6:  Kernel.WriteString("MII")
 |  8:  Kernel.WriteString("Auto-negotiation")
 END;
 IF overrideMedia # 0 THEN  Kernel.WriteString("  (overridden)")  END;
 Kernel.WriteLn;
 config := config - MediaMask + d.media;
 SYSTEM.PORTOUT(base + 0H, config);  (* Win 3 / Off 0 - InternalConfig, p 4-8 *)
END InitHostInterface;

(* Configure the host registers *)

PROCEDURE InitHostRegisters(d: Device);
VAR  mac, w: INTEGER;  b: SHORTINT;  base, i: LONGINT;  full: BOOLEAN; s: SET;
BEGIN
 base := d.base;
 IF tornado IN d.config THEN (* Invert MII-Power *)
  SwitchToWindow(base, 2);
  SYSTEM.PORTIN(base + 12, w);
  w := SHORT(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, LONG(w)) + {14}));
  SYSTEM.PORTOUT(base + 12, w)
 END;
 (* enable the 10Base2 converter if Media is 10base2 *)
 IF d.media = Base10Coax THEN
  SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, EnableDcConverter)) (* W*/0E, command register *)
 ELSE
  SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, DisableDcConverter)) (* W*/0E, command register *)
 END;
 (* set the duplexmode if required *)
 IF overrideDuplex = 0 THEN
  EepromRead(base, d.config, 0DH, w);  (* Software information *)
  IF 15 IN SYSTEM.VAL(SET, w) THEN
   mac := 20H;  full := TRUE
  ELSE
   mac := 0;  full := FALSE
  END
 ELSE
  IF overrideDuplex = 1 THEN (* 1 => half duplex *)
   mac := 0;  full := FALSE
  ELSE (* 2 => full duplex *)
   mac := 20H;  full := TRUE
  END
 END;
 SwitchToWindow(base, 3);
 SYSTEM.PORTOUT(base + 06H, mac); (* Win3/Off 6: MacControl Register;  p 12-2 *)
 Kernel.WriteString("Net3Com90x: ");
 IF full THEN Kernel.WriteString("Full") ELSE Kernel.WriteString("Half") END;
 Kernel.WriteString(" duplex"); Kernel.WriteLn;
 ResetTx(d);
 ResetRx(d, TRUE);
 (* for normal use switch to window 7*)
 SwitchToWindow(base, 7);
 (*  Bus Master Procedures .. *)
 SYSTEM.PORTOUT(base + 2FH, CHR(1536 DIV 256));   (* TxFree: for older NICS... *)
 (* clear all interrupts / indications *)
 SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, 7800H)); (* SetIndicationEnable, nothing *)
 SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, 7000H)); (* SetInterruptEnable, nothing *)
 SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, 6800H+0769H)); (* AckInterrupt, all *)
 (* clear all statistics by reading *)
 SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, 0B000H)); (* StatsDisable *)
 SwitchToWindow(base, 6);
 FOR i := 0 TO 9 DO  SYSTEM.PORTIN(base + i, b)  END;
 SYSTEM.PORTIN(base + 10, i);  SYSTEM.PORTIN(base + 12, i);
 SwitchToWindow(base, 4);
 SYSTEM.PORTIN(base + 12, b);
 SYSTEM.PORTOUT(base + CommReg, SYSTEM.VAL(INTEGER, 0A800H)); (* enable Statistics *)
 (* start the host *)
 SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, RxEnable)); (* RxEnable*)
 SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, TxEnable)); (* TxEnable*)
 SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, UpUnstall));
END InitHostRegisters;

PROCEDURE InitHostLists(d: Device);
 VAR i: LONGINT;  upd, last: UPD;
BEGIN
 d.curdpd := 0;
 NEW(d.dpd);
 FOR i:= 0 TO DownBufferSize-1 DO
  ASSERT(SYSTEM.ADR(d.dpd[i]) MOD 8 = 0);
  d.dpd[i].data0Adr := SYSTEM.ADR(d.dpd[i].header[0]);
  d.dpd[i].data0Len := LEN(d.dpd[i].header);
  SYSTEM.MOVE(SYSTEM.ADR(d.hostAdr[0]),  SYSTEM.ADR(d.dpd[i].header[6]),  6)
 END;
 d.up := NIL; last := NIL;
 FOR i := 0 TO UpBufferSize-1 DO
  NEW(upd);
  ASSERT(SYSTEM.VAL(LONGINT, upd) MOD 8 = 0); (* alignment constraint *)
  upd.status := {};  upd.next := NIL;
  upd.fragAddr := SYSTEM.ADR(upd.packet[0]);
  upd.fragLen := EthernetFrameSize;
  IF last = NIL THEN
   d.up := upd
  ELSE
   last.next := upd
  END;
  last := upd
 END;
 last.next := d.up
END InitHostLists;
 
(*PROCEDURE ProbeMedia(media: SET): BOOLEAN;
VAR  intConfig: SET;  t, dummy: LONGINT;  mediaStatus: INTEGER;  cnt, hit: LONGINT;
BEGIN
 ASSERT(media - {20..22} = {});
 SYSTEM.PORTIN(BaseAdr+InternalConfig, intConfig);
 SYSTEM.PORTOUT(BaseAdr+InternalConfig, intConfig-{20,21,22,23}+media); (*select*)

 TxRxReset;
 IF debug THEN 
  SYSTEM.PORTIN(BaseAdr + DownListPtr, dummy);
  Texts.WriteString(W, "DnListPtr after TxReset and RxReset: ");
  Texts.WriteHex(W, dummy); Texts.WriteLn(W); 
 END;
 IF (media=Base100FX) OR (media=Base100TX) OR (media=Base10T) THEN
  (* set Link beat enable *)
  SwitchToWindow(4);
  SYSTEM.PORTIN(BaseAdr+MediaStatus, mediaStatus);
  SYSTEM.PORTOUT(BaseAdr+MediaStatus, SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, mediaStatus) + {7} ));

  (* set receive all / RxTxEnable *)
  SYSTEM.PORTOUT(BaseAdr+CommReg, SYSTEM.VAL(INTEGER,RxFilterLI+B3));
  SYSTEM.PORTOUT(BaseAdr+CommReg, RxEnable); (* RxEnable*)
  SYSTEM.PORTOUT(BaseAdr+CommReg, TxEnable); (* TxEnable*)

  (* poll the link detect bit + packet ok *)
  t := Kernel.GetTimer();
  cnt := 0;  hit := 0;
  REPEAT
   SYSTEM.PORTIN(BaseAdr+MediaStatus, mediaStatus);
   INC(cnt);
   IF (11 IN SYSTEM.VAL(SET, mediaStatus)) THEN INC(hit) END;
  UNTIL (Kernel.GetTimer()-t > 2*Kernel.TimeUnit) (*OR (11 IN SYSTEM.VAL(SET, mediaStatus))*); (*timeout/no link*)
  
  Texts.WriteString(W, "probe: "); Texts.WriteInt(W, 100*ENTIER(hit/cnt), 0);  Texts.WriteLn(W);
  Texts.Append(T, W.buf);
  
  RETURN 11 IN SYSTEM.VAL(SET, mediaStatus)
 ELSE
  HALT(99)
 END;
END ProbeMedia;
*)
(*PROCEDURE AutoSelect;
VAR mediaOptions: INTEGER;
BEGIN
 SYSTEM.PORTIN(BaseAdr+MediaOption, mediaOptions);
 IF {1,3} * SYSTEM.VAL(SET, mediaOptions) # {} THEN
  SYSTEM.PORTIN(BaseAdr+InternalConfig, intConfig);
  SYSTEM.PORTOUT(BaseAdr+InternalConfig, intConfig-{20..23}+{23}); (*set autonegotiation*)
  HALT(99)
 ELSE
  HALT(99)
 END;
END AutoSelect;
*)
(*PROCEDURE InitDriver; 
VAR 
 res: CHAR;  
 i, link, ic0, ic1, info1, cmreg, adr, mediaStatus, mediaOptions: INTEGER; 
 s, intConfig,val, medStatus : SET; 
 dummy, res1, version, lastPCIbus, hwMech, dev, t: LONGINT;
 dummyb: SYSTEM.BYTE;
 tryPort: MediaList;
 found, stillTrying: BOOLEAN;
BEGIN
 intCounter := 0;
 DevNum := 0; ASSERT(Ints = {});
 res1 := PCI.PCIPresent(version, lastPCIbus, hwMech);
 IF res1 = PCI.Done THEN
  DevNum := BuildDeviceList(Devs, DevIDs);
  IF devlistdebug THEN ShowDeviceList(Devs, DevNum) END;
  BaseAdr := Devs[0].IoBaseAdr-1; (*entferne letztes bit das nur zur identifikation des IoBaseAdr. dient *)
  IF debug THEN
   Texts.WriteString(W, "Base Address: "); Texts.WriteHex(W, BaseAdr); Texts.WriteLn(W);
   Texts.WriteString(W, "DevId: "); Texts.WriteHex(W, Devs[0].devId); Texts.WriteLn(W);
   SwitchToWindow(d, 4); SYSTEM.PORTIN(BaseAdr+0AH, s);
   Texts.WriteString(W, "MediaStatus: "); Texts.WriteSet(W, s); Texts.WriteLn(W);
   Dump;
   Texts.WriteLn(W); 
  END;
  (* First select the Media Port *)
  NEW(tryPort);
  InitMediaList(tryPort, Devs[0].devId);
  SwitchToWindow(d, 3);
  SYSTEM.PORTIN(BaseAdr+InternalConfig, intConfig);
  IF (24 IN intConfig) THEN (* Autoselect *)
   SYSTEM.PORTIN(BaseAdr+MediaOption, mediaOptions);
   ASSERT( {1, 3} * SYSTEM.VAL(SET, mediaOptions) # {}); (*only 10BaseT and 100BaseTx implemented*)
   SYSTEM.PORTOUT(BaseAdr+InternalConfig, intConfig-{20,21,22,23}+Auto); (*set autonegotiation*)
   CommonSetup;
   
   (*IF ProbeMedia(Base10T) THEN
    Texts.WriteString(W, "Media OK")
   ELSE
    Texts.WriteString(W, "Media bad")
   END;
   Texts.WriteLn(W); Texts.Append(T, W.buf);*)
   
   (* TxEnable and RxEnable *)
   SYSTEM.PORTOUT(BaseAdr+CommReg, RxEnable); (* RxEnable*)
   SYSTEM.PORTOUT(BaseAdr+CommReg, TxEnable); (* TxEnable*)
   SYSTEM.PORTOUT(BaseAdr+CommReg, UpUnstall);
   RETURN
(*
  ELSIF AUTOSELECT OR (24 IN intConfig) THEN (* Autoselect; start with 100BaseTx IF available, else go through the medialist*)
   SYSTEM.PORTIN(BaseAdr+MediaOption, mediaOptions);
   WHILE ~(tryPort=NIL)&~(tryPort.type IN SYSTEM.VAL(SET, mediaOptions)) DO
    tryPort := tryPort.next
   END;
   (* try first this port... *)
   SYSTEM.PORTOUT(BaseAdr+InternalConfig, intConfig-{20,21,22,23}+tryPort.xcvr);
   IF debug THEN 
    Texts.WriteString(W, "Inital Media type that we try is... "); Texts.WriteString(W, tryPort.name); Texts.WriteLn(W)
   END;
   TxRxReset;
   found := FALSE;
*) 
  ELSE (* use default media; selected in the BIOS ROM and automatically copied into 
     the NIC's internal Config Register. => Do nothing... *)
   CommonSetup;
   SYSTEM.PORTOUT(BaseAdr+CommReg, RxEnable); (* RxEnable*)
   SYSTEM.PORTOUT(BaseAdr+CommReg, TxEnable); (* TxEnable*)
   SYSTEM.PORTOUT(BaseAdr+CommReg, UpUnstall);
   RETURN
  END;
(*  no autoselection!
  REPEAT
   (* set the duplexmode if required *)
   EepromRead(0DH, info1);  (* Software information *)
   SwitchToWindow(3);
   IF 15 IN SYSTEM.VAL(SET, info1) THEN
    SYSTEM.PORTOUT(BaseAdr+MacControl, B5)
   ELSE
    SYSTEM.PORTOUT(BaseAdr+MacControl, 0)
   END;
   TxRxReset; (* TxReset and RxReset*)
   IF debug THEN 
    SYSTEM.PORTIN(BaseAdr + DownListPtr, dummy);
    Texts.WriteString(W, "DnListPtr after TxReset and RxReste: ");
    Texts.WriteHex(W, dummy); Texts.WriteLn(W); 
   END;
   Dump;
   (* mit SetInterruptEnable koennen nur diese Bits gesetzt werden, welche mit Set Indication Enable 
    Enabled worden sind. Ausser interruptLatch; dies ist immer enabled *)
   SYSTEM.PORTOUT(BaseAdr+CommReg, SetIndicationEnable); 
  (* Kernel.InstallIP(InterruptHandler, Kernel.IRQ+SHORT(Interrupt));
   Kernel.InstallTermHandler(Cleanup); *)
   InitStationAdress();
   (* enable the 10Base2 converter if Media is 10base2 *)
   SwitchToWindow(3);
   SYSTEM.PORTIN(BaseAdr+InternalConfig, intConfig);
   IF  intConfig * {20..23} = {20,21} THEN 
    SYSTEM.PORTOUT(BaseAdr + CommReg, EnableDcConverter)
   END;  
   (* set Link beat enable *)
   SwitchToWindow(4);
   SYSTEM.PORTIN(BaseAdr+MediaStatus, mediaStatus);
   val := SYSTEM.VAL(SET, mediaStatus) -{3,6,7};
   val := val + {7}; (* haengt ab vom media type => noch eine tabelle aufbauen!!*)
   SYSTEM.PORTOUT(BaseAdr+MediaStatus, SYSTEM.VAL(INTEGER, val));   
   (* clear all statistics by reading *)
   SYSTEM.PORTOUT(BaseAdr+CommReg, SYSTEM.VAL(INTEGER,B15+B13+B12)); (* StatsDisable *)
   SwitchToWindow(6);
   FOR i:=0 TO 9 DO
    SYSTEM.PORTIN(BaseAdr+i, dummyb)
   END;
   SYSTEM.PORTIN(BaseAdr+10, i);
   SYSTEM.PORTIN(BaseAdr+12, i);
   SwitchToWindow(4);
   SYSTEM.PORTIN(BaseAdr+12, dummyb);
   (* for normal use switch to window 7*)
   SwitchToWindow(7);
    (*  Bus Maser Procedures .. *)
    SYSTEM.PORTOUT(BaseAdr+CommReg, SYSTEM.VAL(INTEGER, RxThresh)+1500 DIV 4);
    SYSTEM.PORTOUT(BaseAdr+DmaCtr, SYSTEM.VAL(LONGINT, 20H)); (* upRxEarlyEnable *)
   (* Set the UpListPtr auf die up und starte Upload Engine *)
   SYSTEM.PORTOUT(BaseAdr+UpListPtr, SYSTEM.ADR(up^));  
   SYSTEM.PORTOUT(BaseAdr+2FH, CHR(1536 DIV 256)); (* for older NICS... *)
   SYSTEM.PORTOUT(BaseAdr+DownListPtr, SYSTEM.VAL(LONGINT, 0)); 
   (* Set Receive filter: individual, broadcast, multicast *)
   SYSTEM.PORTOUT(BaseAdr+CommReg, SYSTEM.VAL(INTEGER,RxFilterLI+B0+B1+B2));  
   SYSTEM.PORTOUT(BaseAdr+CommReg, SYSTEM.VAL(INTEGER, B15+B13+B11)); (* enable Statistics *)
   (* TxEnable and RxEnable *)
   SYSTEM.PORTOUT(BaseAdr+CommReg, RxEnable); (*Rx Enable*)
   SYSTEM.PORTOUT(BaseAdr+CommReg, TxEnable); (* TxEnable*)
   (* allow Statusbits to be seen *)
   SYSTEM.PORTOUT(BaseAdr+CommReg, SetIndicationEnable+7FEH (*B7+B6+B2+B1*));
   SYSTEM.PORTOUT(BaseAdr+CommReg, AcknowledgeInterrupt+B0+B5+B6+B9+B10); 
   (* war: 6868H IntLatch, TxAvailable?, Rxearly, Intreq ->see IntStatus Reg (s. 8-3)*)
   (* SetinterruptEnable legt fest, welche interruptBits einen Interrupt generieren koennen
    !Wichtig!: Sie muessen zuerst mit SetIndicationEnable enabled worden sein! *)
   SYSTEM.PORTOUT(BaseAdr+CommReg, SetInterruptEnable );
   (* Set Interrupts enable: rxComplete, intRequest*)  
   (* check if the right port was selected; if not, try another one and wait again... *)
   IF ~found THEN
    SwitchToWindow(3);
    SYSTEM.PORTIN(BaseAdr+MediaOption, mediaOptions);
    SwitchToWindow(4); 
    IF (tryPort.type=1 (*100BaseTx*)) OR (tryPort.type = 3 (*10baseT*)) OR (tryPort.type = 2 (*100baseFx*)) THEN
     t := Kernel.GetTimer();
     REPEAT SYSTEM.PORTIN(BaseAdr+MediaStatus, i); 
     UNTIL (Kernel.GetTimer()-t > 2*Kernel.TimeUnit) OR (11 IN SYSTEM.VAL(SET,i));
     IF 11 IN SYSTEM.VAL(SET, i) THEN
       found := TRUE; link := tryPort.type 
     ELSE
      ConfigNextValidMedia(tryPort, link);
     END
    ELSIF (tryPort.type = 5 (*AUI*)) OR (tryPort.type = 4 (*10base2*)) THEN
     FOR i:= 1 TO 3 DO
      IF TestPacket() THEN
       found := TRUE; link := tryPort.type
      END
     END;
     IF ~found THEN 
      IF (tryPort.name = "10base2")  THEN
       SYSTEM.PORTOUT(BaseAdr+CommReg, SYSTEM.VAL(INTEGER,DisableDcConverter)) 
      END;
      ConfigNextValidMedia(tryPort, link)
     END
    ELSE (* MII ... *)      
    END
   END;
  (* IF (~found)&(tryPort#NIL) THEN
    Cleanup
   END *)
  UNTIL found OR (tryPort = NIL);
  IF debug THEN
   Texts.WriteLn(W);
   IF tryPort=NIL THEN Texts.WriteString(W, "keinen Port ")
   ELSE Texts.WriteString(W, tryPort.name)
   END;
   Texts.WriteString(W, " erkannt"); 
   Texts.WriteLn(W);
     t := Kernel.GetTimer();
     REPEAT SYSTEM.PORTIN(BaseAdr+MediaStatus, i); 
     UNTIL (Kernel.GetTimer()-t > 2*Kernel.TimeUnit) OR (11 IN SYSTEM.VAL(SET,i));   
   Dump
  END;
  SYSTEM.PORTOUT(BaseAdr+CommReg, UpUnstall);
  SYSTEM.PORTOUT(BaseAdr + CommReg, TxReset); 
  REPEAT SYSTEM.PORTIN(BaseAdr+CommReg, s) UNTIL ~(12 IN s);
  IF debug THEN 
   SwitchToWindow(3);
   Texts.WriteLn(W);
   Texts.WriteString(W, "Internal Config ist: ");
   SYSTEM.PORTIN(BaseAdr+InternalConfig, intConfig);
   Texts.WriteSet(W, intConfig);
   Texts.Append(T, W.buf);
   SwitchToWindow(4);
   SYSTEM.PORTIN(BaseAdr+MediaStatus, i);
   Texts.WriteLn(W);
   Texts.WriteString(W, "MediaStatus  ");
   Texts.WriteHex(W,  i);
   Texts.WriteLn(W);
  END;
*)
 END; (* if PCI.Done ende *)
 IF debug THEN 
  Texts.Append(T, W.buf);
 END;
END InitDriver;
*)


(* Check the transmission state (TxStatus): p. 6-23 *)

PROCEDURE CheckTransmission(base: LONGINT);
 VAR ch: CHAR;  status: SET;  reset, enable: BOOLEAN;  txStatus: LONGINT;
BEGIN
 enable := FALSE;  reset := FALSE;
 txStatus := base + 1BH;
 SYSTEM.PORTIN(txStatus, ch);
 status := SYSTEM.VAL(SET, ch);
 WHILE 7 IN status DO  (* txComplete set, check for troubles *)
  IF 2 IN status THEN (*txStatusOverflow*)
   INC(AtxStatusOverflow);
   enable := TRUE
  END;
  IF 3 IN status THEN (*maxCollisions*)
   INC(AmaxCollisions);
   enable := TRUE
  END;
  IF 4 IN status THEN (*txUnderrun*)
   INC(AtxUnderrun);
   enable := TRUE;  reset := TRUE
  END;
  IF 5 IN status THEN (*txJabber*)
   INC(AtxJabber);
   reset := TRUE
  END;
  SYSTEM.PORTOUT(txStatus, ch);
  SYSTEM.PORTIN(txStatus, ch);
  status := SYSTEM.VAL(SET, ch)
 END;
 IF reset THEN
  IssueCommand(base, TxReset)
 END;
 IF enable THEN
  SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, TxEnable))
 END
END CheckTransmission;

PROCEDURE CheckFifo(d: Device); (* 90x only!, check Fifodiag (p. 9-4) *)
VAR  fifodiag: INTEGER;  base: LONGINT;
BEGIN
 base := d.base;
 SwitchToWindow(base, 4);
 SYSTEM.PORTIN(base+4, fifodiag);
 IF 13 IN SYSTEM.VAL(SET, fifodiag) THEN (* rxUnderrun *)
  INC(ArxUnderrun);
  ResetRx(d, FALSE);
  SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, RxEnable));
  SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, UpUnstall))
 ELSIF 10 IN SYSTEM.VAL(SET, fifodiag) THEN (* txOverrun *)
  INC(AtxOverrun);
  ResetTx(d);
  SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, TxEnable));
  SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER, UpUnstall))
 END
END CheckFifo;

(* Avail - Return TRUE iff a packet is available *)

PROCEDURE Avail(dev: NetBase.Device): BOOLEAN;
VAR  d: Device; status: SET;
BEGIN
 d := dev(Device);  status := d.up.status;
 IF 14 IN status THEN
  INC(AupError);
  IF 16 IN status THEN  INC(AupOverrun)  END;
  IF 17 IN status THEN  INC(AruntFrame)  END;
  IF 18 IN status THEN  INC(AalignmentError)  END;
  IF 19 IN status THEN  INC(AcrcError)  END;
  IF 20 IN status THEN  INC(AoversizedFrame)  END;
  IF 21 IN status THEN  INC(AdribbleBits)  END;
  IF 22 IN status THEN  INC(AupOverflow)  END;
  IF 15 IN status THEN (* RxComplete, drop packet *)
   INC(AdroppedFrames);
   d.up.status := {};  d.up := d.up.next;
   SYSTEM.PORTOUT(d.base + CommReg, SYSTEM.VAL(INTEGER, UpUnstall));
   EXCL(status, 15)
  END
 END;
 IF  15 IN status  THEN  RETURN TRUE
 ELSIF ~(typeB IN d.config) THEN  CheckFifo(d)
 END;
 RETURN FALSE
END Avail;

(* Send - Insert a packet in the send (DPD) queue *)

PROCEDURE Send(dev: NetBase.Device; prno: INTEGER; VAR dest: ARRAY OF SYSTEM.BYTE; item: NetBase.Item);
VAR base, DnListPtr: LONGINT;  d: Device;
BEGIN
 INC(AsentFrames);
 INC(AsentBytes, item.len);
 d := dev(Device);  base := d.base;
 IF (item.len < 0) OR (item.len > 1500) THEN  RETURN END; (* packet too big *)
 
 IssueCommand(base, DnStall);
 CheckTransmission(base);
 SYSTEM.PORTIN(base+DownListPtr, DnListPtr);
 IF DnListPtr # 0 THEN
  INC(AsendNonEmpty);
  IF DnListPtr = SYSTEM.ADR(d.dpd[(d.curdpd + 1) MOD DownBufferSize]) THEN (* buffer is full *)
   INC(AsendFull);
   SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER,DnUnstall)); (* unstall the downloadengine*)
   REPEAT
    CheckTransmission(base);
    SYSTEM.PORTIN(base+DownListPtr, DnListPtr);
   UNTIL DnListPtr # SYSTEM.ADR(d.dpd[(d.curdpd + 1) MOD DownBufferSize]);
   IssueCommand(base, DnStall)
  END;
  d.dpd[d.curdpd].next := SYSTEM.ADR(d.dpd[(d.curdpd + 1) MOD DownBufferSize]);
  d.curdpd := (d.curdpd + 1) MOD DownBufferSize;
 END;
 
 (* build the header *)
 SYSTEM.MOVE(SYSTEM.ADR(dest[0]), SYSTEM.ADR(d.dpd[d.curdpd].header[0]), 6);
 d.dpd[d.curdpd].header[12] := CHR(SYSTEM.LSH(prno, -8));
 d.dpd[d.curdpd].header[13] := CHR(prno);
 (* build the DPD *)
 d.dpd[d.curdpd].next := 0;
 d.dpd[d.curdpd].status :=  14+item.len + 80000000H; (* dnIndicate / type 0 *)
 d.dpd[d.curdpd].data0Adr := SYSTEM.ADR(d.dpd[d.curdpd].header[0]);
 d.dpd[d.curdpd].data0Len := 14 ;
 d.dpd[d.curdpd].dataAdr := SYSTEM.ADR(item.data[item.ofs]);
 d.dpd[d.curdpd].dataLen := item.len + 80000000H;  (* dnFragLast set *)
 IF DnListPtr = 0 THEN
  SYSTEM.PORTOUT(base+DownListPtr, SYSTEM.ADR(d.dpd[d.curdpd])); (* send the packet*)
  SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER,DnUnstall)); (* unstall the downloadengine*)
 END;
 SYSTEM.PORTOUT(base+CommReg, SYSTEM.VAL(INTEGER,DnUnstall)); (* unstall the downloadengine*)
END Send;

(* ReceivePacket - Remove a packet from the input buffer *)

PROCEDURE Receive(dev: NetBase.Device;  VAR prno: INTEGER; VAR src: ARRAY OF SYSTEM.BYTE; VAR item: NetBase.Item);
VAR  prno0, dlen: INTEGER;  d: Device;
BEGIN
 d := dev(Device);
 IF Avail(dev) THEN                   (* There is a uploaded Packet availible *)
  INC(AreceivedFrames);
  dlen := SHORT(SYSTEM.VAL(LONGINT, d.up.status) MOD 2000H);
  SYSTEM.MOVE(d.up.fragAddr+6, SYSTEM.ADR(src[0]), 6);     (* source address *)
  SYSTEM.MOVE(d.up.fragAddr+14, SYSTEM.ADR(item.data[0]), dlen  - 14 (*Ethernet Header*) );
  SYSTEM.GET(d.up.fragAddr+12, prno0);             (* get protocoll number *)
  prno := SYSTEM.ROT(prno0, 8); (* convert big to little Endian *)
  
  item.ofs := 0; 
  item.len := dlen-14;
  INC(AreceivedBytes, item.len);
  d.up.status := {};
  d.up := d.up.next;
  SYSTEM.PORTOUT(d.base + CommReg, SYSTEM.VAL(INTEGER, UpUnstall));
 ELSE
  HALT(100); (*kein Packet availible *)
 END
END Receive;


PROCEDURE InstallHost(d: Device);
BEGIN
 IF debug THEN Dump END;
 InitHostAddress(d);
 InitHostLists(d);
 InitHostInterface(d);
 InitHostRegisters(d);
 IF debug THEN Dump END;
 d.sndCnt := 0;  d.recCnt := 0;
 d.typ := NetBase.broadcast;  d.state := NetBase.closed;
 d.Receive := Receive;  d.Send := Send;  d.Available := Avail;
 NetBase.InstallDevice(d);
END InstallHost;


(* DetectHosts - Scan the PCI bus for the given vendor/device id *)

PROCEDURE DetectHosts(vendor, device: LONGINT;  name: ARRAY OF CHAR;  config, defaultMedia: SET);
VAR  index, bus, dev, fct, res: LONGINT;  d: Device;
BEGIN
 index := 0;
 WHILE (PCI.Done =  PCI.FindPCIDevice(device, vendor, index, bus, dev, fct)) & (last = NIL) DO
  INC(AdetectedHosts);
  IF (*debug*) TRUE THEN
   Kernel.WriteString("Net3Com90x: found ");
   Kernel.WriteHex(vendor*10000H+device, 0); 
   Kernel.WriteString(" / "); Kernel.WriteString(name);  Kernel.WriteLn
  END;
  NEW(d);  last := d;
  res := PCI.ReadConfigDword(bus, dev, fct, PCI.Adr0Reg, d.base); ASSERT(res = PCI.Done, 110);
  ASSERT(ODD(d.base));  DEC(d.base); (*entferne letztes bit das nur zur identifikation des IoBaseAdr. dient *)
  d.devId := device;  d.config := config;  d.media := defaultMedia;
  InstallHost(d);
  INC(index)
 END
END DetectHosts;

(** InstallDevice - Detect the host cards, install them *)

PROCEDURE InstallDevice*;
BEGIN
 last := NIL;
 DetectHosts(10B7H, 6055H, "3C556  - Laptop Tornado", {tornado}, MII);

 DetectHosts(10B7H, 9200H, "3C905C - ???",            {typeB}, Auto);
 DetectHosts(10B7H, 9055H, "3C905B - XL 10/100",      {typeB}, Auto);
 DetectHosts(10B7H, 9056H, "3C905B - 10/100Mb T4",    {typeB}, MII);
 DetectHosts(10B7H, 9004H, "3C900B - 10Mb TPO",       {typeB}, Auto);
 DetectHosts(10B7H, 9005H, "3C900B - Combo",          {typeB}, Auto);
 
 DetectHosts(10B7H, 9050H, "3C905 - 10/100Mb TX",     {}, MII);
 DetectHosts(10B7H, 9000H, "3C900 - 10Mb-only TPO",   {}, Base10T);
 DetectHosts(10B7H, 9001H, "3C900 - 10Mb-only COMBO", {}, Base10T);
END InstallDevice;

(*====================================debug and test Procedures==========================*)

(*PROCEDURE Reset*; 
VAR  d: Device;  base: LONGINT;
BEGIN
 d := last;  base := d.base;
 IssueCommand(base, DnStall);
 IssueCommand(base, 00H);
 (*IssueCommand(base, 00BFH);*)
END Reset;*)
(*PROCEDURE TestReceive*; 
VAR item : NetBase.Item; i, prno :INTEGER; from : ARRAY 6 OF CHAR;
BEGIN
 NEW(item);
 IF Avail(dev) THEN
  Receive(dev, prno, from, item);
  Kernel.WriteString("Packet from: ");
  FOR i := 0 TO 5 DO
   Kernel.WriteHex(ORD(from[i]));
  END;
  Kernel.WriteLn;
  Kernel.WriteString("Protokoll Number: ");
  Kernel.WriteHex(prno);
  Kernel.WriteLn;
  Kernel.WriteString("Packet Data: ");
  Kernel.WriteLn;
  FOR i := 0 TO 9 DO
   Kernel.WriteHex( ORD(item.data[i]));
  END;
  Kernel.WriteLn;  
  Kernel.WriteString("Laenge des Packets: ");
  Texts.WriteInt(W, item.len, 5);
  Kernel.WriteLn;
  
 ELSE
  Kernel.WriteString("Kein Paket erhaeltlich! ");
  Kernel.WriteLn;
 END;
 Texts.Append(T, W.buf)
END TestReceive;*)
(*PROCEDURE TestSend*;  
VAR item : NetBase.Item; i, j :LONGINT; dest : ARRAY 6 OF CHAR;
BEGIN
 NEW(item);
 item.ofs := 5; item.len := 1400;
 FOR j:=0 TO 0 DO
  FOR i := 0 TO 5 DO
   dest[i] := 0FFX;
  END;
(*
  FOR i := 5 TO 64 DO
   item.data[i] := CHR(j);
  END;
*)
  (*check: previous send is over*)
  
  Send(dev, 9, dest, item);
 END; IF debug THEN
  Texts.Append(T, W.buf);
 END;
END TestSend;*)
(*PROCEDURE TimeSend*; 
VAR t, i, j: LONGINT; item : NetBase.Item; dest : ARRAY 6 OF CHAR;  
BEGIN
 NEW(item);
 item.ofs := 5; item.len := 1400;
 FOR i := 0 TO 5 DO
  dest[i] := 0FFX;
 END;
 FOR i := 5 TO 64 DO
  item.data[i] := CHR(j);
 END;
 FOR j := 0 TO 9 DO
  t := Kernel.GetTimer();
  FOR i := 0 TO 1000 DO
   Send(dev, 9, dest, item);
  END;
  Kernel.WriteString("Sendete 1000 Pakete. Durchschnittliche Rate: ");
  Texts.WriteReal(W, 1000*((Kernel.GetTimer()-t)*Kernel.TimeUnit),10);
  Kernel.WriteString(" Pakete pro Sekunde");
  Texts.Append(T, W.buf);
  Kernel.WriteLn
 END
END TimeSend;*)

PROCEDURE Dump*;
VAR i: SHORTINT; x: INTEGER; c0, c1, c2, c3: CHAR;  base: LONGINT;
BEGIN
 base := last.base;
 FOR i := 18H TO 40H BY 4 DO
  Kernel.WriteHex(i,0); 
  SYSTEM.PORTIN(base+i+0, c0);
  SYSTEM.PORTIN(base+i+1, c1);
  SYSTEM.PORTIN(base+i+2, c2);
  SYSTEM.PORTIN(base+i+3, c3);
  Kernel.WriteString(":  ");
  Kernel.WriteHex(ORD(c0) + ASH(ORD(c1), 8) + ASH(ORD(c2), 16) + ASH(ORD(c3), 24), 0);
  Kernel.WriteLn
 END;
 Kernel.WriteString("------- WINOffsets ");
 FOR i:=0 TO 14 BY 2 DO
  Kernel.WriteHex(i, 9);
 END;
 Kernel.WriteLn;
 FOR i := 0 TO 7 DO
  SwitchToWindow(base, i);
  Kernel.WriteString("------- WINDOW "); Kernel.WriteHex(i, 0);
  SYSTEM.PORTIN(base, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  SYSTEM.PORTIN(base+2, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  SYSTEM.PORTIN(base+4, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  SYSTEM.PORTIN(base+6, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  SYSTEM.PORTIN(base+8, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  SYSTEM.PORTIN(base+10, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  SYSTEM.PORTIN(base+12, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  SYSTEM.PORTIN(base+14, x); Kernel.WriteHex(LONG(x) MOD 10000H, 9);
  Kernel.WriteLn;
 END;
 Kernel.WriteLn
END Dump; 

PROCEDURE EpromDump*;
VAR i, val: INTEGER;  base: LONGINT;
BEGIN
 base := last.base;
 Kernel.WriteString("Eeprom Dump:"); Kernel.WriteLn;
 FOR i := 0 TO 20H DO
  EepromRead(base, last.config, i, val);
  Kernel.WriteHex(i, -3); Kernel.WriteString(": "); Kernel.WriteHex(val, 9); Kernel.WriteLn
 END;
 Kernel.WriteLn
END EpromDump;

(*========================= end of debug and test procedures ===============================*)

PROCEDURE Cleanup;
BEGIN
 IF last # NIL THEN  (* reset and implicitly clear the UpListPtr and DnListPtr (NIC could write to those regions) *)
  IssueCommand(last.base, RxReset);
  IssueCommand(last.base, TxReset);
 END
END Cleanup;

PROCEDURE Init;
VAR  str: ARRAY 32 OF CHAR;

 PROCEDURE StrToInt(s: ARRAY OF CHAR): LONGINT;
 VAR i, j: SHORTINT;  v, sgn, m: LONGINT;
 BEGIN
  j := 0;  WHILE s[j] # 0X DO INC(j) END;
  IF (j > 0) & (CAP(s[j-1]) = "H") THEN m := 16; DEC(j) ELSE m := 10 END;
  v := 0;  i := 0;
  IF s[i] = "-" THEN sgn := -1; INC(i) ELSE sgn := 1 END;
  WHILE i < j DO
   IF (s[i] >= "0") & (s[i] <= "9") THEN v := v*m + (ORD(s[i])-ORD("0"))
   ELSIF (CAP(s[i]) >= "A") & (CAP(s[i]) <= "F") THEN v := v*m + (ORD(CAP(s[i]))-ORD("A")+10)
   ELSE sgn := 0;  j := i
   END;
   INC(i)
  END;
  RETURN sgn*v
 END StrToInt;
 
BEGIN
 Kernel.WriteString("Net3Com90x:  0.9.5 "); Kernel.WriteLn;
 Kernel.GetConfig("3C90xMedia", str);  overrideMedia := StrToInt(str);
 Kernel.GetConfig("3C90xDuplex", str);  overrideDuplex := StrToInt(str);
 Kernel.InstallTermHandler(Cleanup);
END Init;


BEGIN
 Init
END Net3Com90x.

SendTest:
Net3Com90x.InitDriver
Net3Com90x.InstallDevice reto~
TestSuite.Timing 
Net3Com90x.TestSend  a nb    ~
Net3Com90x.TestReceive
Net3Com90x.TimeSend

Net3Com90x.InstallDevice default
Net3Com90x.ShowAddress
Net3Com90x.Dump
Net3Com90x.EpromDump

NetSystem.Stop
NetSystem.Start

System.Free Net3Com90x ~ 

System.State Net3Com90x ~