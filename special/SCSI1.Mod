(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE SCSI1; (** prk  **)
(*
 Common Interface for SCSI Drivers
 
 1.0:
  version changed
  
 0.9.6:
  dev.description
  Debugging flags (TraceSense, TraceDetection)
  Better trace messages
  DeviceClass: class names
  Transfer, used dev.BlockSize (bug found with ISO9660Volumes)
 
*)

IMPORT SYSTEM, Disks, Kernel;

CONST
(** Debugging: Trace bits for "SCSIDebug" config string *)
 TraceSense* = 0; (** 01H *)
 TraceDetection* = 1; (** 02H *)

(** SCSI Commands*) (*taken from scsi.h -> "http://lxr.linux.no/source/include/scsi/scsi.h" *)
 TestUnitReady* = 0X;
 RezeroUnit* = 1X;
 RequestSense* = 3X;
 Format* = 4X;
 ReadBlockLimits* = 5X;
 ReassignBlocks* = 7X;
 Read6* = 8X;
 Write6* = 0AX;
 Seek6* = 0BX;
 ReadReverse* = 0FX;
 WriteFilemarks* = 10X;
 Space* = 11X;
 Inquiry* = 12X;
 RecoverBufferedData* = 14X;
 ModeSelect* = 15X;
 Reserve* = 16X;
 Release* = 17X;
 Copy* = 18X;
 Erase* = 19X;
 ModeSense* = 1AX;
 StartStop* = 1BX;
 ReceiveDiagnostic* = 1CX;
 SendDiagnostic* = 1DX;
 AllowMediumRemoval* = 1EX;
 SetWindow* = 24X;
 ReadCapacity* = 25X;
 Read10* = 28X;
 Write10* = 2AX;
 Seek10* = 2BX;
 WriteVerify* = 2EX;
 Verify* = 2FX;
 SearchHigh* = 30X;
 SearchEqual* = 31X;
 SearchLow* = 32X;
 SetLimits* = 33X;
 PreFetch* = 34X;
 ReadPosition* = 34X;
 SynchronizeCache* = 35X;
 LockUnlockCache* = 36X;
 ReadDefectData* = 37X;
 MediumScan* = 38X;
 Compare* = 39X;
 CopyVerify* = 3AX;
 WriteBuffer* = 3BX;
 ReadBuffer* = 3CX;
 UpdateBlock* = 3DX;
 ReadLong* = 3EX;
 WriteLong* = 3FX;
 ChangeDefinition* = 40X;
 WriteSame* = 41X;
 ReadToc* = 43X;
 LogSelect* = 4CX;
 LogSense* = 4DX;
 ModeSelect10* = 55X;
 ModeSense10* = 05AX;
 Read12* = 0A8X;
 Write12* = 0AAX;
 WriteVerify12* = 0AEX;
 SearchHigh12* = 0B0X;
 SearchEqual12* = 0B1X;
 SearchLow12* = 0B2X;
 ReadElementStatus* = 0B8X;
 SendVolumeTag* = 0B6X;
 WriteLong2* = 0EAX;

(** SCSI Messages / 1 Byte *)
 MsgCmdComplete* = 00X;
 MsgExtended* = 01X;
 MsgSaveDataPointer* = 02X;
 MsgRestorePointers* = 03X;
 MsgDisconnect* = 04X;
 MsgInitiatorDetErr* = 05X;
 MsgAbort* = 06X;
 MsgMessageReject* = 07X;
 MsgNoop* = 08X;
 MsgParityError* = 09X;
 MsgLinkCmdComplete* = 0AX;
 MsgLinkCmdCompleteF* = 0BX;
 MsgBusDevReset* = 0CX;
 MsgAbortTag* = 0DX;
 MsgClearQueue* = 0EX;
 MsgInitRecovery* = 0FX;
 MsgRelRecovery* = 10X;
 MsgTermIOProc* = 11X;
 
(**SCSI Messages / 2 Bytes*)
 MsgSimpleQTag* = 20X;
 MsgHeadOfQTag* = 21X;
 MsgOrderedQTag* = 22X;
 MsgIgnoreWideResidue* = 23X;
 
 MsgIdentifyFlag* = 80X;
  
(**SCSI Messages / Extended*)
 MsgExtSdTr* = 01X;  MsgExtSdTrLen* = 03X;
 MsgExtWdTr* = 03X;  MsgExtWdTrLen* = 02X; MsgExtWdTr8Bit* = 0X; MsgExtWdTr16Bit* = 1X;

(**SCSI Sense Keys*)
 NoSense* = 0;  RecoveredError* = 1;  NotReady* = 2;  MediumError* = 3;  HardwareError* = 4;
 IllegalRequest* = 5;  UnitAttention* = 6;  DataProtect* = 7;
 
TYPE
(** SCSI Command, all driver must accept this structure *)
 CommandDesc* = RECORD
  status*, result*: SHORTINT; done*: BOOLEAN;   (* !!! These fields must be the first ones !!! *)
  target*, chan*, lun*: SHORTINT; (**destination*)
  cmd*: LONGINT; clen*: SHORTINT; (**command*)
  data*,dlen*: LONGINT; (**data*)
  tag*: CHAR; (*SCSI-II queued command tag*)
 END;

(** SCSI Structures for the common commands *)
 InquiryData* = RECORD
  deviceClass*, ISO*, ECMA*, ANSI*: SHORTINT;
  w32*, w16*, sync*, link*, que*, rmb*: BOOLEAN;
  manufacturer*, product*, rev*: ARRAY 32 OF CHAR;
 END;
 
CONST
(** SCSI.Command, status *)
 Good* = 0H;
 CheckCondition* = 2H;
 ConditionMet* = 4H;
 Busy* = 8H;
 Intermediate* = 0AH;
 IntermediateConditionMet* = 0DH;
 ReservationConflict* = 12H;
 CommandTerminated* = 16H;
 QueueFull* = 1CH;
 
 NotGood* = -1;
 
(** SCSI.Command, result *)
 OK* = 0H;
 NoConnect* = 01H;
 BusBusy* = 02H;
 TimeOut* = 03H;
 BadTarget* = 04H;
 Abort* = 05H;
 Parity* = 06H;
 Error* = 07H;
 Reset* = 08H;
 BadIntr* = 09H;
 PassThrough* = 0AH;
 SoftError* = 0BH;

TYPE
(** SCSI Driver *)
 Driver* = POINTER TO DriverDesc;
 SubmitProc* = PROCEDURE(d: Driver; VAR c: CommandDesc);
 EnumProc* = PROCEDURE(d: Driver; VAR stop: BOOLEAN);
 
 DriverDesc* = RECORD
  number*: LONGINT;
  wide*: BOOLEAN;
  name*: ARRAY 64 OF CHAR;
  submit*: SubmitProc;
  next: Driver;
 END;
 
(** SCSI Device *)
 Device* = POINTER TO DeviceDesc;
 DeviceDesc* = RECORD (Disks.DeviceDesc)
  driver*: Driver;  target*: SHORTINT;
  lastSense: LONGINT;
  inquiry*: InquiryData;
  started: BOOLEAN;
  next*: Device;
 END;

CONST
(** SCSI Device class*)
 DirectAccess* = 0;  SequentialAccess* = 1; Printer* = 2; Processor* = 3; WriteOnce* = 4; CDRom* = 5;
 Scanner* = 6; Optical* = 7; MediumChanger* = 8; Communication* = 9; Unknown* = 1FH;
 
 DiskDevices = {DirectAccess, CDRom};
 
VAR
 DriverList: Driver;
 DriverCount: LONGINT;
 
 DeviceList*: Device;
 
 DeviceClass: ARRAY 32, 20 OF CHAR;
 Trace: SET;

(* Debug *)
PROCEDURE DumpCmdStatus(stat, res: SHORTINT);
BEGIN
 CASE stat OF
 | Good: Kernel.WriteString("Good ")
 | CheckCondition: Kernel.WriteString("CheckCondition ")
 | ConditionMet: Kernel.WriteString("ConditionMet ")
 | Busy: Kernel.WriteString("Busy ")
 | Intermediate: Kernel.WriteString("Intermediate ")
 | IntermediateConditionMet: Kernel.WriteString("IntermediateConditionMet ")
 | ReservationConflict: Kernel.WriteString("ReservationConflict ")
 | CommandTerminated: Kernel.WriteString("CommandTerminated ")
 | QueueFull: Kernel.WriteString("QueueFull ")
 ELSE Kernel.WriteString("unk"); Kernel.WriteInt(stat, 0)
 END;
 CASE res OF
 | OK: Kernel.WriteString("OK")
 | NoConnect: Kernel.WriteString("NoConnect")
 | BusBusy: Kernel.WriteString("BusBusy")
 | TimeOut: Kernel.WriteString("TimeOut")
 | BadTarget: Kernel.WriteString("BadTarget")
 | Abort: Kernel.WriteString("Abort")
 | Parity: Kernel.WriteString("Parity")
 | Error: Kernel.WriteString("Error")
 | Reset: Kernel.WriteString("Reset")
 | BadIntr: Kernel.WriteString("BadIntr")
 | PassThrough: Kernel.WriteString("PassThrough")
 | SoftError: Kernel.WriteString("SoftError")
 ELSE Kernel.WriteString("unk"); Kernel.WriteInt(res, 0)
 END;
 Kernel.WriteLn;
END DumpCmdStatus;

PROCEDURE WriteDriver(d: Driver);
BEGIN  Kernel.WriteString("SCSI"); Kernel.WriteInt(d.number, 0); Kernel.WriteString(": ")
END WriteDriver;

PROCEDURE WriteDevice(d: Device);
BEGIN
 Kernel.WriteString(d.name);  Kernel.WriteString(": ")
END WriteDevice;

PROCEDURE WriteDevice2(d: Driver; target: LONGINT);
BEGIN
 Kernel.WriteString("SCSI"); Kernel.WriteInt(d.number, 0); 
 Kernel.WriteChar("."); Kernel.WriteInt(target, 0); Kernel.WriteString(": ")
END WriteDevice2;

PROCEDURE WriteConfig(d: Device; VAR c: InquiryData);
BEGIN
 WriteDevice(d); Kernel.WriteString("Inquiry: ");Kernel.WriteString("SCSI-");
 IF c.ANSI = 0 THEN Kernel.WriteChar("1")
 ELSIF c.ANSI = 1 THEN Kernel.WriteString("SCC")
 ELSE Kernel.WriteInt(c.ANSI, 0)
 END;
 IF c.rmb THEN Kernel.WriteString(" Removable")  END;
 IF c.w32 THEN Kernel.WriteString(" Wide-32") END;
 IF c.w16 THEN Kernel.WriteString(" Wide-16") END;
 IF c.sync THEN Kernel.WriteString(" Sync") END;
 Kernel.WriteLn
END WriteConfig;

(** Common SCSI Commands *)
PROCEDURE NewCmd(VAR c: CommandDesc; t, l: SHORTINT; ca, cl, da, dl: LONGINT);
BEGIN
 c.cmd := ca;  c.clen := SHORT(SHORT(cl));  c.data := da;  c.dlen := dl;
 c.target := t;  c.lun := l;  c.chan := 0;
END NewCmd;

PROCEDURE DoSense*(d: Driver; target, lun: SHORTINT; VAR key, code, res: LONGINT);
VAR Cmd: CommandDesc; cmd: ARRAY 6 OF CHAR; data: ARRAY 36 OF CHAR;
BEGIN
 cmd[0] := RequestSense;  cmd[1]:= CHR(lun*32);  cmd[2]:= 00X;
 cmd[3]:= 00X;  cmd[4]:= 24X;  cmd[5]:= 00X;
 NewCmd(Cmd, target, 0, SYSTEM.ADR(cmd), 6, SYSTEM.ADR(data), 36);
 d.submit(d, Cmd);  WHILE ~Cmd.done DO END;
 key := ORD(data[2]) MOD 16;
 code := 100H*ORD(data[12]) + ORD(data[13]);
 IF TraceSense IN Trace THEN
  WriteDriver(d);  Kernel.WriteString(": RequestSense"); Kernel.WriteLn;
  Kernel.WriteMemory(SYSTEM.ADR(data[0]), 36); Kernel.WriteLn
 END;
 res := Cmd.status
END DoSense;

PROCEDURE SubmitAndSense*(d: Device; VAR cmd: CommandDesc; maxtry: LONGINT; msg: ARRAY OF CHAR; VAR res: LONGINT);
VAR key, code: LONGINT; first: BOOLEAN;
BEGIN
 first := TRUE;
 REPEAT
  d.driver.submit(d.driver, cmd);  WHILE ~cmd.done DO END;
  IF cmd.status =  CheckCondition THEN
   DoSense(d.driver, d.target, 0, key, code, res);
   WriteDevice(d); Kernel.WriteString(msg);
   d.lastSense := code;
   IF (key=6) & (code = 2900H) & first THEN (*power on, ignore*)
    Kernel.WriteString(" / power on, ignore"); Kernel.WriteLn;
    INC(maxtry);  first := FALSE
   ELSIF code = 0401H THEN (*lun is in process of becoming ready*)
    Kernel.WriteString(" / getting ready...."); Kernel.WriteLn;
    INC(maxtry);  (*skip*)
   ELSIF (key#0) OR (code#0) THEN
    Kernel.WriteString(" / sense -> "); Kernel.WriteInt(key, 3); Kernel.WriteHex(code, 0); Kernel.WriteLn;
    res := NotGood;
    RETURN
   ELSE
    Kernel.WriteString(" / no sense"); Kernel.WriteLn;
    INC(maxtry)
   END
  ELSIF cmd.status # Good THEN
   WriteDevice(d);  Kernel.WriteString(msg);  Kernel.WriteString(" / ");  DumpCmdStatus(cmd.status, cmd.result);
  END;
  DEC(maxtry);
 UNTIL (cmd.status = Good) OR (maxtry <= 0);
 res := cmd.status
END SubmitAndSense;

PROCEDURE DoTestUnitReady*(d: Driver; target, lun: SHORTINT; VAR res: LONGINT);
VAR Cmd: CommandDesc; cmd: ARRAY 6 OF CHAR;
BEGIN
 cmd[0]:= TestUnitReady; cmd[1]:= CHR(lun*32); cmd[2]:= 00X;
 cmd[3]:= 00X; cmd[4]:= 00X; cmd[5]:= 00X;
 NewCmd(Cmd, target, lun, SYSTEM.ADR(cmd), 6, 0, 0);
 d.submit(d, Cmd);  WHILE ~Cmd.done DO END;
 res := Cmd.status
END DoTestUnitReady;

PROCEDURE DoInquiryDrive*(d: Driver; target: SHORTINT; VAR inq: InquiryData; VAR res: LONGINT);
VAR Cmd: CommandDesc; cmd: ARRAY 6 OF CHAR; data: ARRAY 36 OF CHAR; i: LONGINT;
BEGIN
 cmd[0]:= Inquiry; cmd[1]:= 00X; cmd[2]:= 00X;
 cmd[3]:= 00X; cmd[4]:= 24X; cmd[5]:= 00X;
 NewCmd(Cmd, target, 0, SYSTEM.ADR(cmd), 6, SYSTEM.ADR(data), 36);
 d.submit(d, Cmd);  WHILE ~Cmd.done DO END;
 res := Cmd.status;
 IF res = Good THEN
  IF TraceDetection IN Trace THEN
   WriteDriver(d);  Kernel.WriteString(": Inquiry"); Kernel.WriteLn;
   Kernel.WriteMemory(SYSTEM.ADR(data[0]), 64); Kernel.WriteLn
  END;
  inq.deviceClass := SHORT(ORD(data[0]) MOD 32);
  inq.rmb := 7 IN SYSTEM.VAL(SET, data[1]);
  inq.ANSI := SHORT(ORD(data[2]) MOD 8);
  inq.ECMA := SHORT(SYSTEM.LSH(ORD(data[2]), -3) MOD 8);
  inq.ISO  := SHORT(SYSTEM.LSH(ORD(data[2]), -6) MOD 4);
  inq.w32 := 6 IN SYSTEM.VAL(SET, data[7]);
  inq.w16 := 5 IN SYSTEM.VAL(SET, data[7]);
  inq.sync := 4 IN SYSTEM.VAL(SET, data[7]);
  inq.link := 3 IN SYSTEM.VAL(SET, data[7]);
  inq.que := 1 IN SYSTEM.VAL(SET, data[7]);
  SYSTEM.MOVE(SYSTEM.ADR(data[8]), SYSTEM.ADR(inq.manufacturer), 8); 
  i := 7;  WHILE (i >= 0) & (inq.manufacturer[i] = 20X) DO  DEC(i)  END; inq.manufacturer[i+1]:= 0X;
  SYSTEM.MOVE(SYSTEM.ADR(data[16]), SYSTEM.ADR(inq.product), 16);
  i := 15;  WHILE (i >= 0) & (inq.product[i] = 20X) DO  DEC(i)  END; inq.product[i+1]:= 0X;
  SYSTEM.MOVE(SYSTEM.ADR(data[32]), SYSTEM.ADR(inq.rev), 4);
  i := 3;  WHILE (i >= 0) & (inq.rev[i] = 20X) DO  DEC(i)  END; inq.rev[i+1]:= 0X;
 ELSIF TraceDetection IN Trace THEN
  WriteDevice2(d, target);  Kernel.WriteString("Inquiry failed with "); DumpCmdStatus(Cmd.status, Cmd.result)
 END
END DoInquiryDrive;

PROCEDURE DoStartStopUnit*(d: Device; start: BOOLEAN; VAR res: LONGINT);
VAR Cmd: CommandDesc; cmd: ARRAY 10 OF CHAR; data: ARRAY 16 OF CHAR;
BEGIN
 NewCmd(Cmd, d.target, 0, SYSTEM.ADR(cmd), 6, SYSTEM.ADR(data), 0);
 cmd[0]:= StartStop; cmd[1]:= 0X; cmd[2]:= 0X;
 cmd[3]:= 0X; cmd[5]:= 0X; 
 IF start THEN cmd[4]:= 1X ELSE cmd[4]:= 0X END;
 d.driver.submit(d.driver, Cmd);  WHILE ~Cmd.done DO END;
 res := Cmd.status
END DoStartStopUnit;

PROCEDURE PreventAllowRemoval(d: Device;  prevent: BOOLEAN;  VAR res: LONGINT);
VAR Cmd: CommandDesc; cmd: ARRAY 10 OF CHAR; data: ARRAY 16 OF CHAR;
BEGIN
 IF Disks.Removable IN d.flags THEN
  NewCmd(Cmd, d.target, 0, SYSTEM.ADR(cmd), 6, SYSTEM.ADR(data), 0);
  cmd[0]:= AllowMediumRemoval; 
  cmd[1]:= 0X;  cmd[2]:= 0X;  cmd[3]:= 0X;   cmd[5]:= 0X;
  IF prevent THEN  cmd[4]:= 1X  ELSE  cmd[4]:= 0X  END;
  SubmitAndSense(d, Cmd, 1, "PreventAllowRemoval", res)
 ELSE
  res := Disks.Unsupported
 END
END PreventAllowRemoval;

(** Disk oriented commands *)

PROCEDURE DoReadCapacity*(d: Device; VAR capacity, blockSize: LONGINT);
VAR
 requ: CommandDesc;
 cmd: ARRAY 10 OF CHAR; data: ARRAY 128 OF CHAR;
 i, res: LONGINT;
BEGIN
 capacity := 0;  blockSize := 0;
 IF (d # NIL) THEN
  NewCmd(requ, d.target, 0, SYSTEM.ADR(cmd), 10, SYSTEM.ADR(data), 16);
  cmd[0]:= ReadCapacity;  cmd[1]:= 0X;  cmd[2]:= 0X;
  cmd[3]:= 0X;  cmd[4]:= 0X;  cmd[5]:= 0X;
  cmd[6]:= 0X;  cmd[7]:= 0X;  cmd[8]:= 0X;  cmd[9]:= 0X;
  SubmitAndSense(d, requ, 1, "ReadCapacity", res);
  IF res # Good THEN  RETURN   END;
  FOR i := 0 TO 3 DO
   capacity := capacity*100H + ORD(data[i]);
   blockSize := blockSize*100H + ORD(data[4+i])
  END;
 END
END DoReadCapacity;

(*
PROCEDURE GetGeometry*(d: Device; VAR bs, cyls, hds, spt: LONGINT);
VAR
 requ: CommandDesc;
 cmd: ARRAY 10 OF CHAR; data: ARRAY 128 OF CHAR;
 capacity, i, temp, res: LONGINT; 
 code, qual: LONGINT;
BEGIN
 bs := 0; cyls := 0;  hds := 0;  spt := 0;
 IF (d # NIL) & ~d.inquiry.rmb THEN
   (*read capacity*)
  NewCmd(requ, d.target, 0, SYSTEM.ADR(cmd), 10, SYSTEM.ADR(data), 16);
  cmd[0]:= ReadCapacity; cmd[1]:= 0X; cmd[2]:= 0X;
  cmd[3]:= 0X; cmd[4]:= 0X; cmd[5]:= 0X;
  cmd[6]:= 0X; cmd[7]:= 0X; cmd[8]:= 0X; cmd[9]:= 0X;
  SubmitAndSense(d, requ, 2, "GetGeometry/ReadCapacity", res);
  IF res # Good THEN  RETURN   END;
  capacity:=0; (*bs:=0;*)
  FOR i := 0 TO 3 DO
   capacity:=capacity*100H + ORD(data[i]);
   bs:=bs*100H + ORD(data[4+i])
  END;
   (*get heads and cylinders*)
  cmd[0]:= ModeSense; cmd[1]:= 0X; cmd[2]:= 04X; cmd[3]:= 0X; cmd[4]:= 80X; cmd[5]:= 0X;
  requ.clen:= 6; requ.dlen:= 80H;
  SubmitAndSense(d, requ, 2, "GetGeometry/ModeSense", res);
  IF res # Good THEN  RETURN   END;
  i := 4 + ORD(data[3]);
  WHILE (ORD(data[i]) MOD 64 # 4) & (data[i+1] # 0X) & (i < 80H) DO  i := i + ORD(data[i+1])  END; (*search for page 04X *)
  IF (ORD(data[i]) MOD 64 # 4) THEN  RETURN  END;
  cyls:= SYSTEM.LSH(LONG(ORD(data[i+2])),16) + SYSTEM.LSH(ORD(data[i+3]),8) + ORD(data[i+4]);
  hds:= ORD(data[i+5]);
   (*set size*)
  temp := cyls*hds;
  spt := capacity DIV temp;
  IF capacity MOD temp # 0 THEN
   temp := spt * hds;
   cyls := capacity DIV temp;
   IF capacity MOD temp # 0 THEN
    temp := cyls * spt;
    hds := capacity DIV temp
   END
  END
 END
END GetGeometry;
*)

PROCEDURE InitDevice(dev: Device);
VAR
 requ: CommandDesc;
 cmd: ARRAY 10 OF CHAR; data: ARRAY 128 OF CHAR;
 end, i, res: LONGINT; 
BEGIN
 NewCmd(requ, dev.target, 0, SYSTEM.ADR(cmd), 6, SYSTEM.ADR(data), 128);
 cmd[0]:= ModeSense; cmd[1]:= 0X; cmd[2]:= 0X; cmd[3]:= 0X; cmd[4]:= 80X; cmd[5]:= 0X;
 requ.clen:= 6; requ.dlen:= 80H;
 SubmitAndSense(dev, requ, 1, "SenseDevice", res);
 IF TraceDetection IN Trace THEN
  WriteDriver(dev.driver);  Kernel.WriteString(": ModeSense"); Kernel.WriteLn;
  Kernel.WriteMemory(SYSTEM.ADR(data[0]), 64); Kernel.WriteLn
 END;
 IF (res = Good) & (ORD(data[3]) = 8) THEN
  dev.blockSize := ORD(data[4+7]);
  dev.blockSize := dev.blockSize + SYSTEM.LSH(ORD(data[4+5]), 16);
  dev.blockSize := dev.blockSize + SYSTEM.LSH(ORD(data[4+6]), 8);
 ELSE
  (*Kernel.WriteString("Sense failed"); Kernel.WriteInt(res, 3); Kernel.WriteLn;*)
  dev.blockSize := 0
 END;
END InitDevice;

(* Disks.Device.transfer *)

PROCEDURE Transfer*(d: Disks.Device; op, start, num: LONGINT; VAR data: ARRAY OF CHAR; ofs: LONGINT; VAR res: LONGINT);
VAR  dev: Device;  Cmd: CommandDesc;  cmd, str: ARRAY 32 OF CHAR;
BEGIN
 IF (op = Disks.Read) OR (op = Disks.Write) THEN
  dev := d(Device);
  ASSERT(num < 10000H);
  IF op = Disks.Read THEN
   cmd[0] := Read10;  str := "transfer/read"
  ELSE
   cmd[0] := Write10;  str := "transfer/write"
  END;
  cmd[1] := 0X;
  cmd[2] := CHR(SYSTEM.LSH(start, -24));
  cmd[3] := CHR(SYSTEM.LSH(start, -16));
  cmd[4] := CHR(SYSTEM.LSH(start, -8));
  cmd[5] := CHR(start);
  cmd[6] := 0X;
  cmd[7] := CHR(SYSTEM.LSH(num, -8));
  cmd[8] := CHR(num);
  cmd[9] := 0X;
  NewCmd(Cmd, dev.target, 0, SYSTEM.ADR(cmd), 10, SYSTEM.ADR(data[ofs]), num*dev.blockSize);
  SubmitAndSense(dev, Cmd, 1, "GetBlocks", res);
  IF res = Good THEN
   res := Disks.Ok
  ELSIF dev.lastSense DIV 100H = 3AH THEN
   res := -5
  ELSIF dev.lastSense DIV 100H = 28H THEN
   res := Disks.MediaChanged
  ELSE
   (*use internal res*)
  END
 ELSE
  res := Disks.Unsupported
 END
END Transfer;

(* Disks.Device.getSize *)

PROCEDURE GetSize*(d: Disks.Device; VAR size, res: LONGINT);
VAR  dev: Device;  blkSize: LONGINT;
BEGIN
 dev := d(Device);
 DoReadCapacity(dev, size, blkSize);
 IF size # 0 THEN
  IF dev.blockSize = 0 THEN dev.blockSize := blkSize ELSE  ASSERT(dev.blockSize = blkSize)  END;
  res := Disks.Ok  
 ELSIF dev.lastSense DIV 100H = 3AH THEN
  res := Disks.MediaMissing
 ELSIF dev.lastSense DIV 100H = 28H THEN
  res := Disks.MediaChanged
 ELSE
  res := Disks.Unsupported
 END;
END GetSize;

(* Disks.Device.handle *)

PROCEDURE Handle*(d: Disks.Device; VAR msg: Disks.Message; VAR res: LONGINT);
VAR  dev: Device;
BEGIN
 dev := d(Device);
 IF msg IS Disks.EjectMsg THEN
  res := Disks.Unsupported
 ELSIF msg IS Disks.LockMsg THEN
  PreventAllowRemoval(dev, TRUE, res)
 ELSIF msg IS Disks.UnlockMsg THEN
  PreventAllowRemoval(dev, FALSE, res)
 ELSE
  res := Disks.Unsupported
 END
END Handle;

(** Device Functions *)

PROCEDURE TerminateDevice(dev: Device);
VAR  res: LONGINT;
BEGIN
 IF dev.started THEN
  DoStartStopUnit(dev, FALSE, res);
 END;
 IF dev.inquiry.deviceClass IN DiskDevices THEN  Disks.Unregister(dev)  END;
END TerminateDevice;

PROCEDURE NumToChar(i: LONGINT): CHAR;
VAR  ch: CHAR;
BEGIN
 ASSERT(i >= 0);
 IF i < 10 THEN
  ch := CHR(i + ORD("0"))
 ELSE
  ch := CHR(i + (ORD("A") - 10))
 END;
 RETURN ch
END NumToChar;

PROCEDURE InitDriver(d: Driver);
VAR  i: SHORTINT;  dev: Device;  data: InquiryData;  j, k, c, res: LONGINT;
BEGIN
 i := 0;
 WHILE (i < 8)  OR  d.wide & (i < 16) DO
  DoInquiryDrive(d, i, data, res);
  IF res = Good THEN (*device detected*)
   NEW(dev);
   dev.name := "SCSIx.x";
   dev.name[4] := NumToChar(d.number);  dev.name[6] := NumToChar(i);
(*
   Kernel.WriteString(dev.name);  Kernel.WriteString(": ");
   Kernel.WriteString(data.manufacturer);  Kernel.WriteChar(" ");
   Kernel.WriteString(data.product);  Kernel.WriteChar(" ");
   Kernel.WriteInt(data.deviceClass, 6);  Kernel.WriteLn;
*)
   j := 0;
   WHILE data.manufacturer[j] # 0X DO  dev.desc[j] := data.manufacturer[j]; INC(j)  END;
   dev.desc[j] := 20X; INC(j);
   k := 0;
   WHILE data.product[k] # 0X DO  dev.desc[k+j] := data.product[k];  INC(k)  END;
   dev.desc[k+j] := 0X;
   dev.flags := {};
   IF data.rmb THEN  INCL(dev.flags, Disks.Removable)  END;
   dev.transfer := Transfer;
   dev.getSize := GetSize;
   dev.handle := Handle;

   dev.driver := d;  dev.target := i;  dev.inquiry := data;
   InitDevice(dev);
   
   Kernel.WriteString(dev.name);  Kernel.WriteString(": ");
   Kernel.WriteString(data.manufacturer);  Kernel.WriteChar(" ");
   Kernel.WriteString(data.product);  Kernel.WriteString(" [");
   Kernel.WriteString(DeviceClass[data.deviceClass]);  Kernel.WriteString(", ");
   IF data.rmb THEN  Kernel.WriteString("removable, ")  END;
   Kernel.WriteString("bs=");  Kernel.WriteInt(dev.blockSize, 0);
   Kernel.WriteChar("]"); Kernel.WriteLn;

   IF data.deviceClass IN DiskDevices THEN  Disks.Register(dev)  END;
   dev.next := DeviceList;  DeviceList := dev
  END;
  INC(i)
 END
END InitDriver;

(** Driver Functions *)
PROCEDURE RegisterDriver*(d: Driver);
BEGIN
 d.number := DriverCount; INC(DriverCount);
 WriteDriver(d); Kernel.WriteString(d.name); Kernel.WriteLn;
 d.next := DriverList; DriverList := d;
 InitDriver(d);
END RegisterDriver;

PROCEDURE RemoveDriver*(d: Driver);
VAR p, q: Driver; s, t: Device;
BEGIN
  (*remove driver from list*)
 IF DriverList = d THEN
  DriverList := d.next
 ELSE
  q := DriverList; p := q.next;
  WHILE (p#NIL) & (p#d) DO  q := p; p := p.next  END;
  IF p#NIL  THEN q.next := p.next  END
 END;
  (*invalidate devices*)
 WHILE (DeviceList # NIL) & (DeviceList.driver = d) DO
  TerminateDevice(DeviceList); DeviceList := DeviceList.next
 END;
 IF DeviceList # NIL THEN
  s := DeviceList; t := s.next;
  WHILE t # NIL DO
   IF t.driver = d THEN  TerminateDevice(t); t := t.next; s.next := t
   ELSE s := t; t := t.next
   END
  END
 END;
END RemoveDriver;

PROCEDURE FindDriver*(name: ARRAY OF CHAR): Driver;
VAR p: Driver;
BEGIN
 p := DriverList;
 WHILE (p # NIL) & (p.name # name) DO  p := p.next  END;
 RETURN p
END FindDriver;

PROCEDURE EnumerateDrivers*(proc: EnumProc);
VAR p: Driver; stop: BOOLEAN;
BEGIN
 stop := FALSE; p := DriverList;
 WHILE ~stop & (p#NIL) DO
  proc(p, stop);
  p := p.next
 END
END EnumerateDrivers;

(* Install the Disk upcalls. *)

PROCEDURE Install*;
BEGIN
END Install;

(* StrToInt - Convert a string to an integer *)

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

PROCEDURE Init;
VAR  str: ARRAY 32 OF CHAR;
BEGIN
 Kernel.GetConfig("SCSIDebug", str); Trace := SYSTEM.VAL(SET, StrToInt(str));
 IF Trace # {} THEN
  Kernel.WriteString("SCSIDebug = "); Kernel.WriteHex(SYSTEM.VAL(LONGINT, Trace),0); Kernel.WriteLn
 END;
END Init;

BEGIN
 Kernel.WriteString("SCSI - 1.0 / prk"); Kernel.WriteLn;
 DriverCount := 0;
 Init;
 DeviceClass[DirectAccess] := "direct-access";
 DeviceClass[SequentialAccess] := "sequential-access";
 DeviceClass[Printer] := "printer";
 DeviceClass[Processor] := "processor";
 DeviceClass[WriteOnce] := "write-once";
 DeviceClass[CDRom] := "cd-rom";
 DeviceClass[Scanner] := "scanner";
 DeviceClass[Optical] := "optical";
 DeviceClass[MediumChanger] := "medium changer";
 DeviceClass[Communication] := "communications";
 DeviceClass[Unknown] := "Unknown";
END SCSI1.


ToDo:
 get rid of the distinction between driver and device