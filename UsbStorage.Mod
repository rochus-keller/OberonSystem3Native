(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon Usb Storage Support

Reference: http://www.usb.com

SCSI commands borrowed from SCSI.Mod

30.09.2000 cp first release
20.10.2000 cp many improvements (BulkOnly, UTS)
*)

MODULE UsbStorage;  (** non-portable **)  (** cp **)

IMPORT Usb, Kernel, SYSTEM, Disks;

CONST

DEBUG = FALSE; (* Show detail messages, ONLY for development *)
SOFTDEBUG = TRUE; (* Show important messages *)

DriverNameVersion = "Usb Storage Driver 1.0";

NoData = {};
DataIn = {1};
DataOut = {2};

TransportDone = {1};
TransportError = {2};
TransportFatal = {3};
TransportTimeout = {4};
TransportSenseError = {5};
TransportShort = {6};

MethodCBI = 1;
MethodCB = 2;
MethodBulkOnly = 3;
MethodSCMShuttle = 4;

ProtocolUFI = 100;  (* UFI = *)
ProtocolUTS = 101; (* USB TRANSPARENT SCSI => UTS (plattner definition) *)
ProtocolRBC = 102; (* RBC = reduced block commands, often used for flash devices *)
Protocol8020 = 103; (* ATAPI for CDROM *)
Protocol8070 = 104; (* ATAPI for floppy drives and similar devices *)
ProtocolQIC157 = 105; (* QIC, meaning the tape company. Typically used by tape devices *)

(* These are the error codes for the Disks module. It allows to send custom errors (> 0) *)

ErrorDiskFail = 30; (* the catch all code... *)
ErrorShortTransfer = 31;

(* Constans for the SCM USB-ATAPI Shuttle device *)

ScmATA = 40X; ScmISA = 50X;

(* data registers *)
ScmUioEpad = 80X; ScmUioCdt = 40X; ScmUio1 = 20X; ScmUio0 = 10X;

(* user i/o enable registers *)
ScmUioDrvrst = 80X; ScmUioAckd = 40X; ScmUioOE1 = 20X; ScmUioOE0 = 10X;

TYPE

 TransportProc = PROCEDURE (sdev : StorageDevice; VAR cmd : ARRAY OF CHAR; cmdlen : INTEGER; dir :  SET;
  VAR buffer : ARRAY OF CHAR; ofs, bufferlen : LONGINT; VAR tlen: LONGINT; timeout : LONGINT):SET;
 TransportResetProc = PROCEDURE (sdev : StorageDevice; timeout : LONGINT) : SET;
 TransportSpecialInitProc = PROCEDURE(sdev : StorageDevice) : BOOLEAN;

 StorageDevice = POINTER TO RECORD (Disks.DeviceDesc)
  UsbDevice : Usb.UsbDevice;
  Interface : INTEGER;
  BulkInEndpoint, BulkOutEndpoint, InterruptEndpoint, InterruptInterval : INTEGER;
  number : INTEGER;
  TransportMethod : INTEGER;
  TransportProtocol : INTEGER;
  TransportHandler : TransportProc;
  TransportResetHandler : TransportResetProc;
  req : Usb.UsbTReq;
  DeviceType : INTEGER;
  next : StorageDevice;
 END;

VAR

 UsbStorageDriver : Usb.UsbDriver;
 StorageDeviceList : StorageDevice;
 ProbeDev : StorageDevice;
(* --------------------------------------------------------------------------- *)
(*                                                                        Helpers                                                                    *)
(* --------------------------------------------------------------------------- *)

PROCEDURE MilliWait(ms : LONGINT);
VAR
 t: Kernel.MilliTimer;
BEGIN

 Kernel.SetTimer(t, ms);
 REPEAT
  (* active wait - not very efficient - could do some FFT for seti@home here :) *)
 UNTIL Kernel.Expired(t)

END MilliWait;

(* --------------------------------------------------------------------------- *)
(*                                                        SCM Shuttle Transport Layer                                                   *)
(* --------------------------------------------------------------------------- *)

PROCEDURE ScmShortPack(p1, p2 : CHAR) : INTEGER;
BEGIN
 RETURN SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, ORD(p2)*256) + SYSTEM.VAL(SET, ORD(p1)));
END ScmShortPack;

PROCEDURE ScmSendControl(sdev : StorageDevice; endpoint : INTEGER; req, reqtyp, value, index : INTEGER;
 VAR buffer : ARRAY OF CHAR; ofs, bufflen, timeout : LONGINT) : SET;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN
 Message[0] := CHR(reqtyp); Message[1] := CHR(req);
 Message[2] := CHR(value); Message[3] := CHR(SYSTEM.LSH(value, -8));
 Message[4] := CHR(index); Message[5] := CHR(SYSTEM.LSH(index, -8));
 Message[6] := CHR(bufflen); Message[7] := CHR(SYSTEM.LSH(bufflen, -8));

 res := Usb.OpSendControl(sdev.req, sdev.UsbDevice, endpoint, Message, buffer, ofs, bufflen, timeout);

 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on Transport SCM Control"); Kernel.WriteLn; END;
  IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, endpoint) THEN
   RETURN TransportError
  ELSE
   IF SOFTDEBUG THEN
    Kernel.WriteString("UsbStorage: Failure on Transport SCM clear halt on Controlpipe");
    Kernel.WriteLn;
   END;
   RETURN TransportFatal 
  END;
 END;
 IF (res * Usb.ResInProgress) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on Transport SCM Control"); Kernel.WriteLn; END;
  RETURN TransportTimeout;
 END;
 IF res # Usb.ResOK THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on Transport SCM Control"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;
 RETURN TransportDone;
END ScmSendControl;

PROCEDURE ScmBulkTransport(sdev: StorageDevice; dir : SET; VAR buffer : ARRAY OF CHAR; ofs, bufferlen : LONGINT;
 VAR tlen : LONGINT; timeout : LONGINT):SET;
VAR
 bulkendpoint : INTEGER;
 res : SET;
BEGIN
 tlen := 0;
 IF bufferlen = 0 THEN RETURN TransportDone END;
 IF dir = DataIn THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: Transfering SCM DataIn"); Kernel.WriteLn; END;
  bulkendpoint := sdev.BulkInEndpoint;
 ELSIF dir = DataOut THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: Transfering SCM DataOut"); Kernel.WriteLn; END;
  bulkendpoint := sdev.BulkOutEndpoint;
 ELSE HALT(303);
 END;
 res := Usb.OpSendBulk(sdev.req, sdev.UsbDevice, bulkendpoint, buffer, ofs, bufferlen, timeout);
 tlen := sdev.req.BufferLen;
 (* clear halt if STALL occured, but do not abort!!! *)
 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on SCM data phase"); Kernel.WriteLn; END;
  (* only abort if clear halt fails *)
  IF ~Usb.ClearHalt(sdev.req, sdev.UsbDevice, bulkendpoint) THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on SCM bulk clear halt"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  END;
 END;
 IF (res * Usb.ResInProgress) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on SCM data phase"); Kernel.WriteLn; END;
  RETURN TransportTimeout;
 ELSIF (res - (Usb.ResOK  + Usb.ResStalled + Usb.ResShortPacket)) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on SCM bulk"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;
 IF tlen # bufferlen THEN
  IF DEBUG THEN
   Kernel.WriteString("UsbStorage: ScmBulkTransport short read: ");
   Kernel.WriteInt(bufferlen, 0); Kernel.WriteChar("/"); Kernel.WriteInt(tlen, 0); Kernel.WriteLn;
  END;
  RETURN TransportShort;
 END;
 RETURN TransportDone;
END ScmBulkTransport;

PROCEDURE ScmWaitNotBusy(sdev : StorageDevice; timeout : LONGINT):SET;
VAR
 res : SET; status : CHAR;
BEGIN
 LOOP
  res := ScmRead(sdev, ScmATA, 17X, status, 1000);
  IF res # TransportDone THEN IF res = TransportFatal THEN RETURN res ELSE RETURN TransportError END;
  ELSIF (SYSTEM.VAL(SET, status) * {0}) # {} THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: ScmWaitNotBusy: check condition"); Kernel.WriteLn; END;
   RETURN TransportError;
  ELSIF (SYSTEM.VAL(SET, status) * {5}) # {} THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: ScmWaitNotBusy: device fault"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  ELSIF (SYSTEM.VAL(SET, status) * {7}) = {} THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: ScmWaitNotBusy: good"); Kernel.WriteLn; END;
   RETURN TransportDone;
  END;
  IF timeout # -1 THEN
   timeout  := timeout - 10; IF timeout < 0 THEN EXIT END;
  END;
  MilliWait(10);
 END;
 IF DEBUG THEN Kernel.WriteString("UsbStorage: ScmWaitNotBusy: Timeout"); Kernel.WriteLn; END;
 RETURN TransportTimeout;
END ScmWaitNotBusy;

PROCEDURE ScmReadUserIO(sdev : StorageDevice; VAR dataflags: CHAR; timeout : LONGINT) : SET;
VAR
 readbuffer : ARRAY 1 OF CHAR; res : SET;
BEGIN
 res := ScmSendControl(sdev, 128, 82H, 0C0H, 0, 0, readbuffer, 0, 1, timeout);
 dataflags := readbuffer[0];
 RETURN res;
END ScmReadUserIO;

PROCEDURE ScmWriteUserIO(sdev : StorageDevice; enableflags, dataflags: CHAR; timeout : LONGINT) : SET;
VAR
 dummybuffer : ARRAY 1 OF CHAR;
BEGIN
 RETURN ScmSendControl(sdev, 0, 82H, 40H, ScmShortPack(enableflags, dataflags), 0, dummybuffer, 0, 0, timeout);
END ScmWriteUserIO;

PROCEDURE ScmRead(sdev : StorageDevice; access, reg : CHAR; VAR content: CHAR; timeout : LONGINT) : SET;
VAR
 readbuffer : ARRAY 1 OF CHAR; res : SET;
BEGIN
 res := ScmSendControl(sdev, 128, ORD(access), 0C0H, ORD(reg), 0, readbuffer, 0, 1, timeout);
 content := readbuffer[0];
 RETURN res;
END ScmRead;

PROCEDURE ScmWrite(sdev : StorageDevice; access, reg, content : CHAR; timeout : LONGINT):SET;
VAR
 dummybuffer : ARRAY 1 OF CHAR;
BEGIN
 access := SYSTEM.VAL(CHAR, SYSTEM.VAL(SET, access) + {0});
 RETURN ScmSendControl(sdev, 0, ORD(access), 040H, ScmShortPack(reg, content), 0, dummybuffer, 0, 0, timeout);
END ScmWrite;

PROCEDURE ScmMultipleWrite(sdev : StorageDevice; access : CHAR; VAR registers, dataout: ARRAY OF CHAR;
  numregs : INTEGER; timeout : LONGINT):SET;
VAR
 Command : ARRAY 8 OF CHAR;
 data : ARRAY 14 OF CHAR;
 res : SET; i : INTEGER; tlen : LONGINT;
BEGIN

 IF numregs > 7 THEN HALT(303); END;

 Command[0] := 40X; Command[1] := SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, access)+ {0,1,2}));
 Command[2] := 0X; Command[3] := 0X; Command[4] := 0X; Command[5] := 0X;
 Command[6] := CHR(numregs*2); Command[7] := CHR(SYSTEM.LSH(numregs*2, -8));

 FOR i:= 0 TO numregs - 1 DO
  data[i*2] := registers[i]; data[(i*2)+1] := dataout[i];
 END;

 res := ScmSendControl(sdev, 0, 80H, 040H, 0, 0, Command, 0, 8, timeout);
 IF res # TransportDone THEN RETURN res END;

 res := ScmBulkTransport(sdev, DataOut, data, 0, numregs*2, tlen, timeout);
 IF res # TransportDone THEN RETURN res END;

 RETURN ScmWaitNotBusy(sdev, timeout);

END ScmMultipleWrite;

PROCEDURE ScmReadBlock(sdev : StorageDevice; access, reg : CHAR; VAR content : ARRAY OF CHAR;
 ofs, len: LONGINT; VAR tlen : LONGINT; timeout : LONGINT):SET;
VAR
 Command : ARRAY 8 OF CHAR; res : SET;
BEGIN
 Command[0] := 0C0X; Command[1] := SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, access)+ {1}));
 Command[2] := reg; Command[3] := 0X; Command[4] := 0X; Command[5] := 0X;
 Command[6] := CHR(len); Command[7] := CHR(SYSTEM.LSH(len, -8));
 tlen := 0;
 res := ScmSendControl(sdev, 0, 80H, 40H, 0, 0, Command, 0, 8, timeout);
 IF res # TransportDone THEN RETURN res END;
 res := ScmBulkTransport(sdev, DataIn, content, ofs, len, tlen, timeout);
 RETURN res;
END ScmReadBlock;

PROCEDURE ScmWriteBlock(sdev : StorageDevice; access, reg : CHAR; VAR content : ARRAY OF CHAR;
 ofs, len : LONGINT; VAR tlen : LONGINT; timeout : LONGINT):SET;
VAR
 Command : ARRAY 8 OF CHAR; res : SET;
BEGIN
 Command[0] := 40X; Command[1] := SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, access)+ {0,1}));
 Command[2] := reg; Command[3] := 0X; Command[4] := 0X; Command[5] := 0X;
 Command[6] := CHR(len); Command[7] := CHR(SYSTEM.LSH(len, -8));
 tlen := 0;
 res := ScmSendControl(sdev, 0, 80H, 40H, 0, 0, Command, 0, 8, timeout);
 IF res # TransportDone THEN RETURN res END;
 res := ScmBulkTransport(sdev, DataOut, content, ofs, len, tlen, timeout);
 IF res # TransportDone THEN RETURN res END;
 RETURN ScmWaitNotBusy(sdev, timeout);
END ScmWriteBlock;

PROCEDURE ScmRWBlockTest(sdev : StorageDevice; access : CHAR; VAR registers, dataout : ARRAY OF CHAR;
 numregs :INTEGER; datareg, statusreg, atapitimeout, qualifier : CHAR; dir : SET; VAR content : ARRAY OF CHAR;
 ofs, contentlen: LONGINT; VAR tlen : LONGINT; timeout : LONGINT): SET;
VAR
 Command : ARRAY 16 OF CHAR;
 Data : ARRAY 38 OF CHAR; tmpreg : CHAR; res : SET;
 status : CHAR; i, msgindex, msglen : INTEGER;
 tmplen : LONGINT;
BEGIN
 IF numregs > 19 THEN
  Kernel.WriteString("UsbStorage: ScmRWBlockTest too many registers"); Kernel.WriteLn;
  HALT(303);
 END;
 Command[0] := 40X; Command[1] := SYSTEM.VAL(CHAR, SYSTEM.VAL(SET,access) + {0,1,2});
 Command[2] := 7X; Command[3] := 17X; Command[4] := 0FCX; Command[5] := 0E7X; 
 Command[6] := CHR(numregs*2); Command[7] := CHR(SYSTEM.LSH(numregs*2, -8));
 IF dir = DataOut THEN
  Command[8] := 40X; Command[9] := SYSTEM.VAL(CHAR, SYSTEM.VAL(SET, access) + {0,2});
 ELSIF dir = DataIn THEN
  Command[8] := 0C0X; Command[9] := SYSTEM.VAL(CHAR, SYSTEM.VAL(SET, access) + {2});
 ELSE
  HALT(303)
 END;
 Command[10] := datareg; Command[11] := statusreg; Command[12] := atapitimeout;
 Command[13] := qualifier; Command[14] := CHR(contentlen); Command[15] := CHR(SYSTEM.LSH(contentlen, -8));

 FOR i:=0 TO numregs -1 DO
  Data[i*2] := registers[i]; Data[(i*2)+1] := dataout[i];
 END;

 tlen := 0;

 FOR i:=0 TO 19 DO
  IF i = 0 THEN msgindex := 0; msglen := 16 ELSE msgindex := 8; msglen := 8 END;
  res := ScmSendControl(sdev, 0, 80H, 40H, 0, 0, Command, msgindex, msglen, 1000);
  IF res # TransportDone THEN
   IF (res = TransportFatal) OR (res = TransportTimeout) THEN RETURN res ELSE RETURN TransportError END;
  END;
  IF i = 0 THEN
   res := ScmBulkTransport(sdev, DataOut, Data, 0, numregs*2, tmplen, 1000);
   IF res # TransportDone THEN
    IF (res = TransportFatal) OR (res = TransportTimeout) THEN RETURN res ELSE RETURN TransportError END;
   END;
  END;
  res := ScmBulkTransport(sdev, dir, content, 0, contentlen, tlen, timeout);
  IF res = TransportShort THEN
   IF (dir = DataIn) & (i=0) THEN (* hm. makes somehow no sense, but that's life *)
    IF ~Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkOutEndpoint) THEN
     Kernel.WriteString("UsbStorage: ScmRWBlockTest clear halt failed"); Kernel.WriteLn;
    END
   END;
   IF dir = DataOut THEN tmpreg := 17X; ELSE tmpreg := 0EX; END;
   res := ScmRead(sdev, ScmATA, tmpreg, status, 1000);
   IF res # TransportDone THEN IF res = TransportFatal THEN RETURN res ELSE RETURN TransportError END;
   ELSIF (SYSTEM.VAL(SET, status) * {0}) # {} THEN
    IF DEBUG THEN Kernel.WriteString("UsbStorage: ScmRWBlockTest: check condition"); Kernel.WriteLn; END;
    RETURN TransportError;
   ELSIF (SYSTEM.VAL(SET, status) * {5}) # {} THEN
    IF DEBUG THEN Kernel.WriteString("UsbStorage: ScmRWBlockTest: device fault"); Kernel.WriteLn; END;
    RETURN TransportFatal;
   END;
  ELSIF res # TransportDone THEN
   IF (res = TransportFatal) OR (res = TransportTimeout) THEN RETURN res ELSE RETURN TransportError END;
  ELSE
   RETURN ScmWaitNotBusy(sdev, timeout);
  END;
 END;

 IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: ScmRWBlockTest failed 20 times!"); Kernel.WriteLn; END;
 
 RETURN TransportError;

END ScmRWBlockTest;

PROCEDURE ScmSelectAndTestRegisters(sdev : StorageDevice):BOOLEAN;
VAR
 selector : INTEGER; status : CHAR;
BEGIN
 FOR selector := 0A0H TO 0B0H BY 10H DO (* actually, test 0A0H and 0B0H *)
  IF ScmWrite(sdev, ScmATA, 16X, CHR(selector), 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmRead(sdev, ScmATA, 17X, status, 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmRead(sdev, ScmATA, 16X, status, 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmRead(sdev, ScmATA, 14X, status, 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmRead(sdev, ScmATA, 15X, status, 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmWrite(sdev, ScmATA, 14X, 55X, 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmWrite(sdev, ScmATA, 15X, 0AAX, 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmRead(sdev, ScmATA, 14X, status, 1000) # TransportDone THEN RETURN FALSE END;
  IF ScmRead(sdev, ScmATA, 15X, status, 1000) # TransportDone THEN RETURN FALSE END;
 END;
 RETURN TRUE;
END ScmSelectAndTestRegisters;

PROCEDURE ScmSetShuttleFeatures(sdev : StorageDevice; externaltrigger, eppcontrol, maskbyte, testpattern,
 subcountH, subcountL : CHAR):BOOLEAN;
VAR
 Command: ARRAY 8 OF CHAR;
BEGIN
 Command[0] := 40X; Command[1] := 81X; Command[2] := eppcontrol; Command[3] := externaltrigger;
 Command[4] := testpattern; Command[5] := maskbyte; Command[6] := subcountL; Command[7] := subcountH;
 IF ScmSendControl(sdev, 0, 80H, 40H, 0, 0, Command, 0, 8, 1000) # TransportDone THEN RETURN FALSE; END;
 RETURN TRUE;
END ScmSetShuttleFeatures;

PROCEDURE TransportSCMShuttleInit(sdev : StorageDevice):BOOLEAN;
VAR
 res : SET;
 status : CHAR;
BEGIN
 res := ScmWriteUserIO(sdev, SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, ScmUioOE0) + SYSTEM.VAL(SET, ScmUioOE1))),
  SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, ScmUioEpad) + SYSTEM.VAL(SET, ScmUio1))), 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 1"); Kernel.WriteLn; RETURN FALSE; END;
 MilliWait(2000);
 res := ScmReadUserIO(sdev, status, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 2"); Kernel.WriteLn; RETURN FALSE; END;
 res := ScmReadUserIO(sdev, status, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 3"); Kernel.WriteLn; RETURN FALSE; END;
 res := ScmWriteUserIO(sdev, SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, ScmUioDrvrst) + SYSTEM.VAL(SET, ScmUioOE0)
  + SYSTEM.VAL(SET, ScmUioOE1))), SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, ScmUioEpad)
  + SYSTEM.VAL(SET, ScmUio1))), 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 4"); Kernel.WriteLn; RETURN FALSE; END;
 res := ScmWriteUserIO(sdev, SYSTEM.VAL(CHAR, SYSTEM.VAL(SET, ScmUioOE0) + SYSTEM.VAL(SET, ScmUioOE1)),
   SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, ScmUioEpad) + SYSTEM.VAL(SET, ScmUio1))), 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 5"); Kernel.WriteLn; RETURN FALSE; END;
 MilliWait(250);
 res := ScmWrite(sdev, ScmISA, 03FX, 080X, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 6"); Kernel.WriteLn; RETURN FALSE; END;
 res := ScmRead(sdev, ScmISA, 027X, status, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 7"); Kernel.WriteLn; RETURN FALSE; END;
 res := ScmReadUserIO(sdev, status, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 8"); Kernel.WriteLn; RETURN FALSE; END;
 IF ~ScmSelectAndTestRegisters(sdev) THEN
  Kernel.WriteString("UsbStorage: SCM Init error, step 9"); Kernel.WriteLn; RETURN FALSE;
 END;
 res := ScmReadUserIO(sdev, status, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 10"); Kernel.WriteLn; RETURN FALSE; END;
 res := ScmWriteUserIO(sdev, SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, ScmUioAckd) + SYSTEM.VAL(SET, ScmUioOE0)
  + SYSTEM.VAL(SET, ScmUioOE1))), SYSTEM.VAL(CHAR, (SYSTEM.VAL(SET, ScmUioEpad)
  + SYSTEM.VAL(SET, ScmUio1))), 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 11"); Kernel.WriteLn; RETURN FALSE; END;
 res := ScmReadUserIO(sdev, status, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 12"); Kernel.WriteLn; RETURN FALSE; END;
 MilliWait(1400);
 res := ScmReadUserIO(sdev, status, 1000);
 IF res # TransportDone THEN Kernel.WriteString("UsbStorage: SCM Init error, step 13"); Kernel.WriteLn; RETURN FALSE; END;
 IF ~ScmSelectAndTestRegisters(sdev) THEN
  Kernel.WriteString("UsbStorage: SCM Init error, step 14"); Kernel.WriteLn; RETURN FALSE;
 END;
 IF ~ScmSetShuttleFeatures(sdev, 83X, 0X, 88X, 08X, 15X, 14X) THEN
  Kernel.WriteString("UsbStorage: SCM Init error, step 15"); Kernel.WriteLn; RETURN FALSE;
 END;
 IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: SCM USB-ATAPI Shuttle initialised"); Kernel.WriteLn; END;
 RETURN TRUE;
END TransportSCMShuttleInit;

PROCEDURE TransportSCMShuttle(sdev : StorageDevice; VAR cmd : ARRAY OF CHAR; cmdlen : INTEGER; dir : SET;
 VAR buffer : ARRAY OF CHAR; ofs, bufferlen : LONGINT; VAR tlen : LONGINT; timeout : LONGINT):SET;
VAR
 registers, data : ARRAY 32 OF CHAR;
 i : INTEGER; res : SET; status : CHAR;
 atapilen, tmplen, sector, transfered : LONGINT;
BEGIN

 registers[0] := 11X; registers[1] := 12X; registers[2] := 13X; registers[3] := 14X;
 registers[4] := 15X; registers[5] := 16X; registers[6] := 17X;
 data[0] := 0X; data[1] := 0X; data[2] := 0X; data[3] := CHR(bufferlen);
 data[4] := CHR(SYSTEM.LSH(bufferlen, -8)); data[5] := 0B0X; data[6] := 0A0X;
 FOR i:= 7 TO 18 DO
  registers[i] := 010X;
  IF (i - 7) >= cmdlen THEN data[i] := 0X; ELSE data[i] := cmd[i-7]; END;
 END;

 tlen := 0;

 IF dir = DataOut THEN
  Kernel.WriteString("UsbStorage: SCM DataOut not supported!!!"); Kernel.WriteLn;
  RETURN TransportError;
 END;

 IF bufferlen > 65535 THEN
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Too large request for SCM USB-ATAPI Shuttle"); Kernel.WriteLn;
  END;
  RETURN TransportError;
 END;

 IF cmd[0] = 28X THEN (* READ 10 command *)
  IF bufferlen < 10000H THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: Doing SCM single read"); Kernel.WriteLn; END;
   res := ScmRWBlockTest(sdev, ScmATA, registers, data, 19, 10X, 17X, 0FDX, 30X, DataIn,
    buffer, ofs, bufferlen, tlen, timeout);
   RETURN res;
  ELSE
   IF DEBUG THEN Kernel.WriteString("UsbStorage: Doing SCM multi read"); Kernel.WriteLn; END;
   tmplen := (65535 DIV sdev.blockSize) * sdev.blockSize;
   sector := SYSTEM.LSH(ScmShortPack(data[10], data[9]), 16) + ScmShortPack(data[12], data[11]);
   transfered := 0;
   WHILE transfered # bufferlen DO
    IF tmplen > (bufferlen - transfered) THEN tmplen := bufferlen - transfered END;
    data[3] := CHR(tmplen); data[4] := CHR(SYSTEM.LSH(tmplen, -8));
    data[9] := CHR(SYSTEM.LSH(sector, -24));
    data[10] := CHR(SYSTEM.LSH(sector, -16));
    data[11] := CHR(SYSTEM.LSH(sector, -8));
    data[12] := CHR(sector);
    data[14] := CHR(SYSTEM.LSH(tmplen DIV sdev.blockSize, -8));
    data[15] := CHR(tmplen DIV sdev.blockSize);
    res := ScmRWBlockTest(sdev, ScmATA, registers, data, 19, 10X, 17X, 0FDX, 30X, DataIn,
     buffer, ofs+transfered, tmplen, atapilen, timeout);
    transfered := transfered + atapilen;
    tlen := transfered;
    sector := sector + (tmplen DIV sdev.blockSize);
    IF res # TransportDone THEN RETURN res END;
   END;
   RETURN TransportDone;
  END;
 END;

 IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending SCM registers"); Kernel.WriteLn; END;
 res := ScmMultipleWrite(sdev, ScmATA, registers, data, 7, 1000);
 IF res # TransportDone THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: SCM register setup failed"); Kernel.WriteLn; END;
  RETURN TransportError
 END;

 IF cmdlen # 12 THEN
  Kernel.WriteString("UsbStorage: SCM command len # 12"); Kernel.WriteLn;
  HALT(303);
 END;

 IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending SCM command"); Kernel.WriteLn; END;
 res := ScmWriteBlock(sdev, ScmATA, 10X, cmd, 0, 12, tmplen, timeout);
 IF res # TransportDone THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: SCM command transfer failed"); Kernel.WriteLn; END;
  RETURN TransportError
 END;

 IF (bufferlen # 0) & (dir = DataIn) THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: SCM  data transfer"); Kernel.WriteLn; END;
  res := ScmRead(sdev, ScmATA, 014X, status, 1000);
  IF res # TransportDone THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: ScmRead failed"); Kernel.WriteLn; END;
   RETURN TransportError
  END;
  atapilen := ORD(status);
  IF bufferlen > 255 THEN
   res := ScmRead(sdev, ScmATA, 015X, status, 1000);
   IF res # TransportDone THEN
    IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: ScmRead2 failed"); Kernel.WriteLn; END;
    RETURN res;
   END;
   atapilen := atapilen + (ORD(status) * 256);
  END;
  IF DEBUG THEN
   Kernel.WriteString("UsbStorage: Scm Transfer: Want: "); Kernel.WriteInt(bufferlen, 0);
   Kernel.WriteString(" / have: "); Kernel.WriteInt(atapilen, 0); Kernel.WriteLn;
  END;
  tmplen := atapilen;
  IF atapilen < bufferlen THEN
   IF SOFTDEBUG THEN
    Kernel.WriteString("UsbStorage: Scm has FEWER bytes in the atapi buffer"); Kernel.WriteLn;
   END;
  ELSIF atapilen > bufferlen THEN
   IF SOFTDEBUG THEN
    Kernel.WriteString("UsbStorage: Scm has MORE bytes in the atapi buffer"); Kernel.WriteLn;
   END;
   tmplen := bufferlen;
  END;
  res := ScmReadBlock(sdev, ScmATA, 10X, buffer, ofs, tmplen, tlen, timeout);
  IF DEBUG THEN
   IF (res = TransportDone) OR (res = TransportShort) THEN
    Kernel.WriteString("UsbStorage: wanted: "); Kernel.WriteInt(tmplen, 0);
    Kernel.WriteString(" / got: "); Kernel.WriteInt(tlen, 0); Kernel.WriteLn;
   END;
  END;
  IF (res = TransportDone) & (atapilen < bufferlen) THEN res := TransportShort END;
  IF (res # TransportDone) & (res # TransportShort) THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: ScmReadBlock failed"); Kernel.WriteLn; END;
   RETURN res;
  END;
 ELSE
  tlen := 0;
 END;

 RETURN TransportDone;

END TransportSCMShuttle;

(* --------------------------------------------------------------------------- *)
(*                                                             CB/I Transport Layer                                                          *)
(* --------------------------------------------------------------------------- *)


PROCEDURE TransportCBIReset(sdev : StorageDevice; timeout : LONGINT) : SET;
VAR
 Message : ARRAY 8 OF CHAR;
 Buffer : ARRAY 12 OF CHAR;
 InterruptData : ARRAY 8 OF CHAR;
 i : INTEGER; res : SET;
BEGIN

 Message[0] := CHR(33); (* Class specific request (32), Type Interface (1) *)
 Message[1] := CHR(0);
 Message[2] := CHR(0);
 Message[3] := CHR(0);
 Message[4] := CHR(sdev.UsbDevice.ActConfiguration.Interfaces[sdev.Interface].bInterfaceNumber);
 Message[5] := CHR(0);
 Message[6] := CHR(12);
 Message[7] := CHR(0);
 
 FOR i := 0 TO 11 DO Buffer[i] := CHR(255) END;
 Buffer[0] := CHR(1DH); Buffer[1] := CHR(4);

 IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending CB/I reset ControlTransfer"); Kernel.WriteLn; END;
 res := Usb.OpSendControl(sdev.req, sdev.UsbDevice, 0, Message, Buffer, 0, 12, timeout);
 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on TransportCB/I-Reset Control"); Kernel.WriteLn; END;
  IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, 0) THEN
   RETURN TransportError
  ELSE
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I-Reset clear halt on Controlpipe"); Kernel.WriteLn; END;
   RETURN TransportFatal
  END;
 END;
 IF (res * Usb.ResInProgress) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on TransportCB/I-Reset Control"); Kernel.WriteLn; END;
  RETURN TransportTimeout;
 END;
 IF res # Usb.ResOK THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I-Reset Control"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 IF sdev.TransportMethod = MethodCBI THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending CB/I reset InterruptTransfer"); Kernel.WriteLn; END;
  res := Usb.OpSendInterrupt(sdev.req, sdev.UsbDevice, sdev.InterruptEndpoint, InterruptData, 0, 2,
   timeout, sdev.InterruptInterval);
  IF (res * Usb.ResStalled) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on TransportCB/I-Reset Interrupt"); Kernel.WriteLn; END;
   IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, 0) THEN RETURN TransportError END;
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I-Reset clear halt on Interruptpipe"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  END;
  IF (res * Usb.ResInProgress) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on TransportCB/I-Reset Interrupt"); Kernel.WriteLn; END;
   RETURN TransportTimeout;
  END;
  IF res # Usb.ResOK THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I-Reset Interrupt"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  END;
 END;
  
 IF (~Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkInEndpoint))
  OR (~Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkOutEndpoint)) THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on CB/I reset ClearHalt"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 IF DEBUG THEN Kernel.WriteString("UsbStorage: CB/I reset OK"); Kernel.WriteLn; END;
  
 RETURN TransportDone;

END TransportCBIReset;

PROCEDURE TransportCBI(sdev : StorageDevice; VAR cmd : ARRAY OF CHAR; cmdlen : INTEGER; dir : SET;
 VAR buffer : ARRAY OF CHAR; ofs, bufferlen : LONGINT; VAR tlen : LONGINT; timeout : LONGINT):SET;
VAR
 Message :  ARRAY 8 OF CHAR;
 InterruptData : ARRAY 2 OF CHAR;
 res : SET;
 bulkendpoint : INTEGER;
BEGIN

 Message[0] := CHR(33); (* Class specific request (32), Type Interface (1) *)
 Message[1] := CHR(0);
 Message[2] := CHR(0);
 Message[3] := CHR(0);
 Message[4] := CHR(sdev.UsbDevice.ActConfiguration.Interfaces[sdev.Interface].bInterfaceNumber);
 Message[5] := CHR(0);
 Message[6] := CHR(cmdlen);
 Message[7] := CHR(SYSTEM.LSH(cmdlen, -8));

 IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending TransportCB/I Control"); Kernel.WriteLn; END; 
 res := Usb.OpSendControl(sdev.req, sdev.UsbDevice, 0, Message, cmd, 0, cmdlen, timeout);
 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on TransportCB/I Control"); Kernel.WriteLn; END;
  IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, 0) THEN
   RETURN TransportError
  ELSE
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I clear halt on Controlpipe"); Kernel.WriteLn; END;
   RETURN TransportFatal 
  END;
 END;
 IF (res * Usb.ResInProgress) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on TransportCB/I Control"); Kernel.WriteLn; END;
  RETURN TransportTimeout;
 END;
 IF res # Usb.ResOK THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I Control"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 IF (bufferlen # 0) THEN
  IF dir = DataIn THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending TransportCB/I BulkIn"); Kernel.WriteLn; END;
   bulkendpoint := sdev.BulkInEndpoint;
  ELSIF dir = DataOut THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending TransportCB/I BulkOut"); Kernel.WriteLn; END;
   bulkendpoint := sdev.BulkOutEndpoint;
  ELSE HALT(303);
  END;
  res := Usb.OpSendBulk(sdev.req, sdev.UsbDevice, bulkendpoint, buffer, ofs, bufferlen, timeout);
  tlen := sdev.req.BufferLen;
  IF (res * Usb.ResStalled) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on TransportCB/I Bulk"); Kernel.WriteLn; END;
   IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, bulkendpoint) THEN RETURN TransportError END;
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I clear halt on Bulkpipe"); Kernel.WriteLn; END;
   RETURN TransportFatal
  ELSIF (res * Usb.ResInProgress) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on TransportCB/I Bulk"); Kernel.WriteLn; END;
   RETURN TransportTimeout;
  ELSIF res # Usb.ResOK THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I Bulk"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  END;
 ELSE
  tlen := 0;
 END;

 IF sdev.TransportMethod = MethodCBI THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending TransportCB/I Interrupt"); Kernel.WriteLn; END;
  res := Usb.OpSendInterrupt(sdev.req, sdev.UsbDevice, sdev.InterruptEndpoint, InterruptData, 0, 2,
   timeout, sdev.InterruptInterval);
  IF (Usb.ResStalled * res)  # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on TransportCB/I Interrupt"); Kernel.WriteLn; END;
   IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, 0) THEN RETURN TransportError END;
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I clear halt on Interruptpipe"); Kernel.WriteLn; END;
   RETURN TransportFatal 
  END;
  IF (res * Usb.ResInProgress) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on TransportCB/I Interrupt"); Kernel.WriteLn; END;
   RETURN TransportTimeout;
  END;
  IF res # Usb.ResOK THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on TransportCB/I Interrupt"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  END;

  IF (sdev.TransportProtocol = ProtocolUFI) THEN
   IF (cmd[0] = 12X) OR (cmd[0] = 03X) THEN
    (* UFI Inquiry + Sense do not change the sense data, so we cannot be sure that those commands succeded!!! *)
    (* just go on and hope the best! *)
   ELSIF (InterruptData[0] # 0X) THEN
    IF DEBUG THEN
     Kernel.WriteString("UsbStorage: asc = "); Kernel.WriteHex(ORD(InterruptData[0]), 0);
     Kernel.WriteString(" ascq = "); Kernel.WriteHex(ORD(InterruptData[1]), 0);
     Kernel.WriteString(" Error on CBI/UFI"); Kernel.WriteLn;
    END;
    RETURN TransportSenseError;
   END;
   (* go on *)
  ELSIF InterruptData[0] # 0X THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: CBI returned invalid interupt data block"); Kernel.WriteLn; END;
   RETURN TransportSenseError; (* try to recover by manual sensing *)
  ELSE
   res := SYSTEM.VAL(SET, InterruptData[1]) * {0,1};
   IF (res = {0,1}) OR (res = {0}) THEN
    IF DEBUG THEN Kernel.WriteString("UsbStorage: Sense # 0 Error on TransportCB/I"); Kernel.WriteLn; END;
    RETURN TransportSenseError;
   ELSIF res = {1} THEN
    IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Fatal sense on Transport CB/I"); Kernel.WriteLn; END;
    RETURN TransportFatal;
   END;
  END;

 END;

 IF tlen # bufferlen THEN RETURN TransportShort; END;

 RETURN TransportDone;

END TransportCBI;

(* --------------------------------------------------------------------------- *)
(*                                                          Bulk Only Transport Layer                                                     *)
(* --------------------------------------------------------------------------- *)

PROCEDURE TransportBulkOnlyReset(sdev : StorageDevice; timeout : LONGINT) : SET;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN
 Message[0] := CHR(33); (* Class specific request (32), Type Interface (1) *)
 Message[1] := CHR(255); (* Bulk Only specific request (reset) *)
 Message[2] := CHR(0);
 Message[3] := CHR(0);
 Message[4] := CHR(sdev.UsbDevice.ActConfiguration.Interfaces[sdev.Interface].bInterfaceNumber);
 Message[5] := CHR(0);
 Message[6] := CHR(0);
 Message[7] := CHR(0);
 IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending BulkOnlyReset Control"); Kernel.WriteLn; END; 
 res := Usb.OpSendControl(sdev.req, sdev.UsbDevice, 0, Message, Message, 0, 0, timeout);
 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on BulkOnlyReset Control"); Kernel.WriteLn; END;
  IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, 0) THEN
   RETURN TransportError
  ELSE
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnlyReset clear halt on Controlpipe"); Kernel.WriteLn; END;
   RETURN TransportFatal 
  END;
 END;
 IF (res * Usb.ResInProgress) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on BulkOnlyReset Control"); Kernel.WriteLn; END;
  RETURN TransportTimeout;
 END;
 IF res # Usb.ResOK THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnlyReset Control"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 IF (~Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkInEndpoint))
  OR (~Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkOutEndpoint)) THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnly reset ClearHalt"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 IF DEBUG THEN Kernel.WriteString("UsbStorage: BulkOnlyReset OK"); Kernel.WriteLn; END; 
 
 RETURN TransportDone;
END TransportBulkOnlyReset;

PROCEDURE TransportBulkOnly(sdev : StorageDevice; VAR cmd : ARRAY OF CHAR; cmdlen : INTEGER; dir :  SET;
 VAR buffer : ARRAY OF CHAR; ofs, bufferlen : LONGINT; VAR tlen : LONGINT; timeout : LONGINT):SET;
VAR
 CBWbuffer : ARRAY 31 OF CHAR;
 CSWbuffer : ARRAY 13 OF CHAR;
 bulkendpoint : INTEGER;
 res : SET; i : INTEGER;
BEGIN

 (* set up dCBWSignature *)
 CBWbuffer[0] := 55X; CBWbuffer[1] := 53X; CBWbuffer[2] := 42X; CBWbuffer[3] := 43X;

 (*set up dCBWTag "ETHO"*)
 CBWbuffer[4] := "E"; CBWbuffer[5] := "T"; CBWbuffer[6] := "H"; CBWbuffer[7] := "O";

 (* set up dCBWDataTransferLength *)
 CBWbuffer[8] := CHR(bufferlen);
 CBWbuffer[9] := CHR(SYSTEM.LSH(bufferlen, -8));
 CBWbuffer[10] := CHR(SYSTEM.LSH(bufferlen, -16));
 CBWbuffer[11] := CHR(SYSTEM.LSH(bufferlen, -24));
 
 (* set up bmCBWFlags *)
 IF dir = DataIn THEN CBWbuffer[12] := 80X; ELSE CBWbuffer[12] := 0X; END;

 (* set bCBWLUN - currently always zero *)
 CBWbuffer[13] := 0X;
 
 (*set bCBWCBLength *)
 IF (cmdlen > 16) OR (cmdlen = 0) THEN HALT(303) END;
 CBWbuffer[14] := CHR(cmdlen);

 (* copy CBWCB *)
 FOR i:=0 TO cmdlen-1 DO CBWbuffer[15+i] := cmd[i]; END;

 IF DEBUG THEN Kernel.WriteString("UsbStorage: Sending BulkOnly CBW"); Kernel.WriteLn; END; 
 res := Usb.OpSendBulk(sdev.req, sdev.UsbDevice, sdev.BulkOutEndpoint, CBWbuffer, 0, 31, timeout);
 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on BulkOnly CBW"); Kernel.WriteLn; END;
  IF Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkOutEndpoint) THEN
   RETURN TransportError
  ELSE
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnly clear halt CBW"); Kernel.WriteLn; END;
   RETURN TransportFatal 
  END;
 END;
 IF (res * Usb.ResInProgress) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on BulkOnly CBW"); Kernel.WriteLn; END;
  RETURN TransportTimeout;
 END;
 IF res # Usb.ResOK THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnly CBW"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 (* If there is data to send, enter the data stage *)

 IF bufferlen # 0 THEN 

  IF dir = DataIn THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: Transfering BulkOnly DataIn"); Kernel.WriteLn; END;
   bulkendpoint := sdev.BulkInEndpoint;
  ELSIF dir = DataOut THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: Transfering BulkOnly DataOut"); Kernel.WriteLn; END;
   bulkendpoint := sdev.BulkOutEndpoint;
  ELSE HALT(303);
  END;

  res := Usb.OpSendBulk(sdev.req, sdev.UsbDevice, bulkendpoint, buffer, ofs, bufferlen, timeout);
  tlen := sdev.req.BufferLen;

  (* clear halt if STALL occured, but do not abort!!! *)

  IF (res * Usb.ResStalled) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on BulkOnly data phase"); Kernel.WriteLn; END;
   (* only abort if clear halt fails *)
   IF ~Usb.ClearHalt(sdev.req, sdev.UsbDevice, bulkendpoint) THEN
    IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnly clear halt"); Kernel.WriteLn; END;
    RETURN TransportFatal;
   END;
  END;

  IF (res * Usb.ResInProgress) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on BulkOnly data phase"); Kernel.WriteLn; END;
   RETURN TransportTimeout;

  (* allow short packets and stalls !!! *)

  ELSIF (res - (Usb.ResOK + Usb.ResStalled + Usb.ResShortPacket)) # {} THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnly data phase"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  END;

 ELSE
  tlen := 0;
 END;

 IF DEBUG THEN Kernel.WriteString("UsbStorage: Getting BulkOnly CSW"); Kernel.WriteLn; END;

 (* enter the status phase *)

 res := Usb.OpSendBulk(sdev.req, sdev.UsbDevice, sdev.BulkInEndpoint, CSWbuffer, 0, 13, timeout);

 (* clear halt if STALL occured, and try again*)

 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall, must retry CSW phase"); Kernel.WriteLn; END;
  (* only abort if clear halt fails *)
  IF ~Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkInEndpoint) THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnly clear halt"); Kernel.WriteLn; END;
   RETURN TransportFatal;
  END;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Retrying BulkOnly CSW"); Kernel.WriteLn; END;
  res := Usb.OpSendBulk(sdev.req, sdev.UsbDevice, sdev.BulkInEndpoint, CSWbuffer, 0, 13, timeout);
 END;

 (* clear halt if STALL occured, and this time abort *)

 IF (res * Usb.ResStalled) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Stall on BulkOnly CSW phase"); Kernel.WriteLn; END;
  IF ~Usb.ClearHalt(sdev.req, sdev.UsbDevice, sdev.BulkInEndpoint) THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on BulkOnly clear halt"); Kernel.WriteLn; END;
  END;
  RETURN TransportFatal;
 ELSIF (res * Usb.ResInProgress) # {} THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Timeout on CSW phase"); Kernel.WriteLn; END;
  RETURN TransportTimeout;
 (* allow not short packet on csw phase, be strict! *)
 ELSIF res # Usb.ResOK THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Failure on CSW phase"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;
 
 (* now we have a CSW block *)

 IF (CSWbuffer[0] # 55X)OR(CSWbuffer[1] # 53X)OR(CSWbuffer[2] # 42X)OR(CSWbuffer[3] # 53X) THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Device did not send a valid CSW!"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 IF (CSWbuffer[4] # "E")OR(CSWbuffer[5] # "T")OR(CSWbuffer[6] # "H")OR(CSWbuffer[7] # "O") THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Device did send wrong tag in CSW!"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 (* now we are sure that it is valid *)

 (* parse status *)

 IF CSWbuffer[12] = 01X THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: BulkOnly CSW reports error"); Kernel.WriteLn; END;
  RETURN TransportError;
 ELSIF CSWbuffer[12] # 0X THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: BulkOnly CSW reports fatal"); Kernel.WriteLn; END;
  RETURN TransportFatal;
 END;

 (* look at transfered data difference *)
 
 IF (CSWbuffer[8] # 0X) OR (CSWbuffer[9] # 0X) OR (CSWbuffer[10] # 0X) OR (CSWbuffer[11] # 0X) THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: BulkOnly short  transfer"); Kernel.WriteLn; END;
  IF tlen = bufferlen THEN
   IF SOFTDEBUG THEN
    Kernel.WriteString("UsbStorage: BulkOnly confusion: tlen=bufferlen, but device reports short transfer");
    Kernel.WriteLn;
   END;
  END;
  RETURN TransportShort;
 END;

 RETURN TransportDone;
 
END TransportBulkOnly;

(* --------------------------------------------------------------------------- *)
(*                                                          Generic Transport Handler                                                    *)
(* --------------------------------------------------------------------------- *)

PROCEDURE InvokeTransport (sdev : StorageDevice; cmd : ARRAY OF CHAR; cmdlen : INTEGER; dir : SET;
 VAR data : ARRAY OF CHAR; ofs, datalen : LONGINT; VAR tlen : LONGINT; timeout : LONGINT) : LONGINT;
VAR
 res, senseres : SET; retry, i : INTEGER;
 sensecmd : ARRAY 12 OF CHAR;
 sensedata : ARRAY 36 OF CHAR;
 sensecmdlen : INTEGER;
 asc, ascq, sense : CHAR;
 sensetlen : LONGINT;
BEGIN

 (* here one could add additional stuff for the different protocols *)

 IF sdev.TransportProtocol = ProtocolUFI THEN
  cmdlen := 12;
 ELSIF (sdev.TransportProtocol = ProtocolUTS) OR (sdev.TransportProtocol = ProtocolRBC) THEN
  (* all ok *)
 ELSIF (sdev.TransportProtocol = Protocol8020) OR (sdev.TransportProtocol = Protocol8070) THEN
  cmdlen := 12;
 ELSIF  sdev.TransportProtocol = ProtocolQIC157 THEN
  cmdlen := 12;
 END;

 retry := 0; (* retries for "power up/reset" and "lun becoming ready" *)

 LOOP 
  res := sdev.TransportHandler(sdev, cmd, cmdlen, dir, data, ofs, datalen, tlen, timeout);
 
  IF (res = TransportFatal) OR (res = TransportTimeout) THEN
   res := sdev.TransportResetHandler(sdev, 5000);
   RETURN ErrorDiskFail;
  END;

  (* shorttransfer: the linux guys do sometimes an auto sense here, but we don't *)

  IF (res = TransportShort) & (sdev.TransportMethod # MethodCB) THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: Had a short read"); Kernel.WriteLn; END;
   RETURN ErrorShortTransfer;
  END;

  (* Do an auto-sense if something was not ok or if we are using the CB (not CBI) transport method *)

  IF (res = TransportDone) & (sdev.TransportMethod # MethodCB) THEN
   RETURN Disks.Ok;
  END;

  (* It makes no sense to auto-sense on Inquiry/Sense on UFI/CB (not CBI)*)

  IF ((res = TransportDone) OR (res = TransportShort)) & (sdev.TransportMethod = MethodCB)
   & (sdev.TransportProtocol = ProtocolUFI) & ((cmd[0] = 12X) OR (cmd[0] = 03X)) THEN
   IF res = TransportDone THEN RETURN Disks.Ok; ELSIF res = TransportShort THEN RETURN ErrorShortTransfer;
   ELSE HALT(303); END;
  END;

  IF DEBUG THEN Kernel.WriteString("UsbStorage: Doing auto sense"); Kernel.WriteLn; END;

  IF sdev.TransportProtocol = ProtocolUFI THEN
   sensecmdlen := 12;
  ELSIF (sdev.TransportProtocol = ProtocolUTS) OR (sdev.TransportProtocol = ProtocolRBC) THEN
   sensecmdlen := 6;
  ELSIF (sdev.TransportProtocol = Protocol8020) OR (sdev.TransportProtocol = Protocol8070) THEN
   sensecmdlen := 12;
  ELSIF  sdev.TransportProtocol = ProtocolQIC157 THEN
   sensecmdlen := 12;
  END;

  FOR i:= 0 TO 11 DO sensecmd[i] := CHR(0); END;
  sensecmd[0] := CHR (3);
  sensecmd[1] := CHR (0); (* lun * 32 *)
  sensecmd[4] := CHR(18);

  senseres := sdev.TransportHandler(sdev, sensecmd, sensecmdlen, DataIn, sensedata, 0, 18, sensetlen, 2000);

  IF senseres = TransportShort THEN
   IF sensetlen < 14 THEN
    IF SOFTDEBUG THEN
     Kernel.WriteString("UsbStorage: Crappy device gives not enough sense data"); Kernel.WriteLn;
    END;
    RETURN ErrorDiskFail;
   END;
   (* sense >= 14 is ok *)
  ELSIF (sdev.TransportProtocol = ProtocolUFI) & (senseres = TransportSenseError) THEN
   IF DEBUG THEN Kernel.WriteString("UsbStorage: UFI autosense TransportSenseError"); Kernel.WriteLn; END;
   (* thats ok *)
  ELSIF senseres # TransportDone THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Sense error on protocol sense"); Kernel.WriteLn; END;
   senseres := sdev.TransportResetHandler(sdev, 5000);
   RETURN ErrorDiskFail;
  END;

  sense := CHR(ORD(sensedata[2]) MOD 16); asc := sensedata[12]; ascq := sensedata[13];

  IF DEBUG THEN
   Kernel.WriteString("UsbStorage: Sense Code: "); Kernel.WriteInt(ORD(sense), 0);
   Kernel.WriteString(" asc: "); Kernel.WriteHex(ORD(asc), 0);
   Kernel.WriteString(" ascq: "); Kernel.WriteHex(ORD(ascq), 0);
   Kernel.WriteLn;
  END;

  IF sense = 0X THEN
   IF (res = TransportDone) OR (res = TransportShort) THEN RETURN Disks.Ok; END;
   IF SOFTDEBUG THEN
    Kernel.WriteString("UsbStorage: Device reports error, but auto-sense gives 0X"); Kernel.WriteLn;
   END;
   RETURN ErrorDiskFail;
  ELSIF (sense = 6X) & (asc = 29X) & (ascq = 0X) THEN
   IF SOFTDEBUG THEN
    IF retry = 0 THEN Kernel.WriteString("UsbStorage: PowerOnReset, retrying"); Kernel.WriteLn; END;
   END;
  ELSIF(asc = 4X) & (ascq = 1X) THEN
   IF SOFTDEBUG THEN
    IF retry = 0 THEN Kernel.WriteString("UsbStorage: lun becoming ready, retrying"); Kernel.WriteLn; END;
   END;
  ELSIF asc = 3AX THEN
   RETURN Disks.MediaMissing;
  ELSIF asc = 28X THEN
   RETURN Disks.MediaChanged;
  ELSE
   RETURN ErrorDiskFail;
  END;

  INC(retry);

  IF retry = 30 THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Too many protocol retries, giving up"); Kernel.WriteLn; END;
   EXIT;
  END;

  MilliWait(100);
  (* try again *)
 END;

 RETURN ErrorDiskFail;

END InvokeTransport;

(* --------------------------------------------------------------------------- *)
(*                                Transparent SCSI protocol layer +  UFI protocol layer                                    *)
(* --------------------------------------------------------------------------- *)

PROCEDURE Dotransfer (dev: Disks.Device; op, block, num: LONGINT; VAR data: ARRAY OF CHAR; ofs: LONGINT;
 VAR diskres: LONGINT);
VAR
 sdev : StorageDevice; dir : SET;
 cmd : ARRAY 12 OF CHAR;
 i : INTEGER; tlen, trans: LONGINT;
BEGIN
 sdev := dev (StorageDevice);
 FOR i:= 0 TO 11 DO cmd[i] := CHR(0); END;
 IF (op = Disks.Read) OR (op = Disks.Write) THEN
  
  IF op = Disks.Read THEN
   cmd[0] := 28X; dir := DataIn;
  ELSE
   cmd[0] := 2AX; dir := DataOut;
  END;

  WHILE num > 0 DO
   IF num > 65000 THEN trans := 65000; ELSE trans := num END;
   trans := trans * sdev.blockSize;
   cmd[2] := CHR(SYSTEM.LSH(block, -24));
   cmd[3] := CHR(SYSTEM.LSH(block, -16));
   cmd[4] := CHR(SYSTEM.LSH(block, -8));
   cmd[5] := CHR(block);
   cmd[7] := CHR(SYSTEM.LSH(num, -8));
   cmd[8] := CHR(num);
   diskres := InvokeTransport(sdev, cmd, 10, dir, data, ofs, trans, tlen, -1);
   IF diskres # Disks.Ok THEN RETURN; END;
   block := block + trans;
   num := num - trans;
  END;
 ELSE
  diskres := Disks.Unsupported;
 END;
END Dotransfer;

PROCEDURE DogetSize (dev: Disks.Device; VAR size, diskres: LONGINT);
VAR
 sdev : StorageDevice;
 cmd : ARRAY 12 OF CHAR;
 data : ARRAY 8 OF CHAR;
 tlen : LONGINT;
 i : INTEGER;
BEGIN
 sdev := dev (StorageDevice);
 
 sdev.blockSize := 0; size := 0;
 
 FOR i:= 0 TO 11 DO cmd[i] := CHR(0); END;
 cmd[0] := CHR(25H);
 
 IF DEBUG THEN Kernel.WriteString("UsbStorage: getSize doing GetCapacity command"); Kernel.WriteLn; END;

 diskres := InvokeTransport(sdev, cmd, 10, DataIn, data, 0, 8, tlen, 10000);
 IF ((diskres # Disks.Ok) & (diskres # ErrorShortTransfer)) OR (tlen < 8) THEN RETURN; END;

 FOR i := 0 TO 3 DO
  size := size*100H + ORD(data[i]);
  sdev.blockSize := sdev.blockSize*100H + ORD(data[4+i])
 END;

 INC (size);

 diskres := Disks.Ok;

END DogetSize;

PROCEDURE Dohandle (dev: Disks.Device; VAR msg: Disks.Message; VAR diskres: LONGINT);
VAR
 sdev : StorageDevice;
 cmd : ARRAY 12 OF CHAR;
 i : INTEGER;
 tlen : LONGINT;
BEGIN
 sdev := dev (StorageDevice);
 FOR i:= 0 TO 11 DO cmd[i] := CHR(0); END;

 IF msg IS Disks.GetGeometryMsg THEN
  IF sdev.TransportProtocol = ProtocolUFI THEN
   WITH msg : Disks.GetGeometryMsg DO msg.spt := 18; msg.hds := 2; msg.cyls := 80; END;
   diskres := Disks.Ok;
  ELSE
   diskres := Disks.Unsupported;
  END;
 ELSIF (msg IS Disks.LockMsg) OR (msg IS Disks.UnlockMsg) THEN
  IF sdev.TransportProtocol = ProtocolUFI THEN
   diskres := Disks.Unsupported;
  ELSE
   cmd[0] := 1EX;
   IF msg IS Disks.LockMsg THEN cmd[4] := 1X; ELSE cmd[4] := 0X; END;
   diskres := InvokeTransport(sdev, cmd, 6, NoData, cmd, 0, 0, tlen, 5000);
  END;
 ELSE
  diskres := Disks.Unsupported;
 END;
END Dohandle;

(* --------------------------------------------------------------------------- *)
(*                                                               Cleanup Device                                                                *)
(* --------------------------------------------------------------------------- *)

PROCEDURE CleanupDevice(sdev : StorageDevice);
BEGIN
 Disks.Unregister(sdev);
END CleanupDevice;
(* --------------------------------------------------------------------------- *)
(*                                                                Inquiry Device                                                                 *)
(* --------------------------------------------------------------------------- *)

PROCEDURE InquiryDevice(sdev : StorageDevice) : BOOLEAN;
VAR
 cmd : ARRAY 12 OF CHAR;
 data : ARRAY 36 OF CHAR;
 i : INTEGER; tlen, diskres : LONGINT;
BEGIN

 sdev.flags := {};

 FOR i:= 0 TO 11 DO cmd[i] := CHR(0); END;
 cmd[0] := CHR(12H); cmd[4] := CHR(36);

 IF DEBUG THEN Kernel.WriteString("UsbStorage: Doing inquiry device"); Kernel.WriteLn; END;
 
 diskres := InvokeTransport(sdev, cmd, 6, DataIn, data, 0, 36, tlen, 10000);
 IF ((diskres # Disks.Ok) & (diskres # ErrorShortTransfer)) OR (tlen < 5) THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Fatal, inquiry device error"); Kernel.WriteLn; END;
  RETURN FALSE;
 END;

 IF DEBUG THEN
  Kernel.WriteString("UsbStorage Inquiry info:"); Kernel.WriteLn;
  Kernel.WriteString("  Device type: "); Kernel.WriteInt(ORD(data[0]) MOD 16, 0); Kernel.WriteLn;
  Kernel.WriteString("  Ansi version (00): "); Kernel.WriteInt(ORD(data[2]) MOD 8, 0); Kernel.WriteLn;
  Kernel.WriteString("  Additional lenght: "); Kernel.WriteInt(ORD(data[4]), 0); Kernel.WriteLn;
 END;

 sdev.DeviceType := ORD(data[0]) MOD 32;

 IF sdev.TransportProtocol = ProtocolRBC THEN
  IF sdev.DeviceType # 0EH THEN
   IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: RBC device type is not 0EH"); Kernel.WriteLn; END;
   RETURN FALSE;
  END;
 ELSIF (sdev.DeviceType # 0) & (sdev.DeviceType # 5) THEN
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Device is not a storage device"); Kernel.WriteLn; END;
  RETURN FALSE;
 END;

 IF sdev.DeviceType = 5 THEN sdev.flags := sdev.flags + {Disks.ReadOnly}; END;

 IF 7 IN SYSTEM.VAL(SET, data[1]) THEN
  IF DEBUG THEN Kernel.WriteString("UsbStorage: Removable device found"); Kernel.WriteLn; END;
  sdev.flags := sdev.flags + {Disks.Removable};
 END;

 RETURN TRUE;

END InquiryDevice;

(* --------------------------------------------------------------------------- *)
(*                                                              Usb Device Probe                                                              *)
(* --------------------------------------------------------------------------- *)

PROCEDURE StorageProbe(dev : Usb.UsbDevice; intfc : INTEGER);
VAR
 if : Usb.UsbDeviceInterface;
 stordev, tmpd : StorageDevice;
 i, tmp, namelen : INTEGER;
 DeviceVendor, DeviceProduct, DeviceBCD : INTEGER;
 SpecialInit : TransportSpecialInitProc;
BEGIN

 SpecialInit := NIL;

 (* Set up the temporary StorageDevice *)

 ProbeDev.UsbDevice := dev; (* we make it so complicated to stop memory fragmentation *)
 ProbeDev.Interface := intfc;
 ProbeDev.BulkInEndpoint := 0; ProbeDev.BulkOutEndpoint := 0; ProbeDev.InterruptEndpoint := 0;
 ProbeDev.InterruptInterval := 0;
 ProbeDev.TransportMethod := 0; ProbeDev.TransportProtocol := 0;
 (* ProbeDev.req is already (statically) filled *)

 if := dev.ActConfiguration.Interfaces[intfc];

 (* First check if we can accept this device as a mass storage device *)

 DeviceVendor := dev.Descriptor.idVendor;
 DeviceProduct := dev.Descriptor.idProduct;
 DeviceBCD := dev.Descriptor.bcdDevice;

 IF (DeviceVendor = 03EEH) & (DeviceProduct = 0H) & (DeviceBCD <= 0245H) THEN

  (* Override for Mitsumi CD-R/RW driver *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCBI;
  ProbeDev.TransportProtocol := Protocol8020;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Mitusmi CD-R/RW Writer (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 03F0H) & (DeviceProduct = 107H) & (DeviceBCD = 200H) THEN

  (* Override for HP CDWriter+ series *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := Protocol8070;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for HP CDWriter+ series (UNTESTED)"); Kernel.WriteLn;
  END;

 ELSIF (DeviceVendor = 03F0H) & (DeviceProduct = 207H) & (DeviceBCD = 1H) THEN

  (* Override for HP CDWriter 8200e series *) (* BETA !!!! *)

  ProbeDev.TransportMethod := MethodSCMShuttle;
  ProbeDev.TransportProtocol := Protocol8070;
  SpecialInit := TransportSCMShuttleInit;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for HP CDWriter 8200e series (BETA)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 04E6H) & (DeviceProduct = 01H) & (DeviceBCD = 200H) THEN

  (* Override for Matshita LS-120 *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := Protocol8020;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Matshita LS-120 (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 04E6H) & (DeviceProduct = 06H) & (DeviceBCD >= 100H) & (DeviceBCD <= 200H) THEN

  (* Override for Shuttle eUSB MMC Adapter *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for Shuttle eUSB MMC Adapter (UNTESTED)"); Kernel.WriteLn;
  END;

 ELSIF (DeviceVendor = 04E6H) & (DeviceProduct = 07H) & (DeviceBCD >= 100H) & (DeviceBCD <= 200H) THEN

  (* Override for Sony Hifd *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Sony Hifd (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 04E6H) & (DeviceProduct = 09H) & (DeviceBCD = 200H) THEN

  (* Override for Shuttle eUSB ATAPI Adapter *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := Protocol8020;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for Shuttle eUSB ATAPI Adapter (UNTESTED)"); Kernel.WriteLn;
  END;

 ELSIF (DeviceVendor = 04E6H) & (DeviceProduct = 0AH) & (DeviceBCD = 200H) THEN

  (* Override for Shuttle Compactflash Adapter *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := Protocol8020;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for Shuttle Compactflash Adapter (UNTESTED)"); Kernel.WriteLn;
  END;

 ELSIF (DeviceVendor = 04E6H) & (DeviceProduct = 101H) & (DeviceBCD = 200H) THEN

  (* Override for Shuttle CD-RW Device *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := Protocol8020;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for Shuttle CD-RW Device (UNTESTED)"); Kernel.WriteLn;
  END;

 ELSIF (DeviceVendor = 054CH) & (DeviceProduct = 10H) & (DeviceBCD >= 106H) & (DeviceBCD <= 210H) THEN

  (* Override for Sony DSC-S30/S70/505V/F505 *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for Sony DSC-S30/S70/505V/F505 (UNTESTED)");
   Kernel.WriteLn;
  END;

 ELSIF (DeviceVendor = 054CH) & (DeviceProduct = 2DH) & (DeviceBCD = 100H) THEN

  (* Override for Sony Memorystick MSAC-US1 *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for Sony Memorystick MSAC-US1 (UNTESTED)"); Kernel.WriteLn; 
  END;

 ELSIF (DeviceVendor = 057BH) & (DeviceProduct = 0H) & (DeviceBCD < 0300H) THEN

  (* The Y-E Data floppy (The Sony "Vaio" floppy) with rev.number < 3.00) *)
  (* has a bug, must use CB, not CBI *)
  
  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUFI;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Y-E Data Floppy rev < 3.00"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 059FH) & (DeviceProduct = 0A601H) & (DeviceBCD = 200H) THEN

  (* Override for LaCie USB Hard Disk *) (* UNTESTED !!!!! *)
  
  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolRBC;
  IF SOFTDEBUG THEN
   Kernel.WriteString("UsbStorage: Override for LaCie USB Hard Disk (UNTESTED)"); Kernel.WriteLn;
  END;

 ELSIF (DeviceVendor = 05ABH) & (DeviceProduct = 31H) & (DeviceBCD = 100H) THEN

  (* Override for In-System USB/IDE bridge (ATAPI) *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodBulkOnly;
  ProbeDev.TransportProtocol := Protocol8070;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for In-System USB/IDE bridge (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 0644H) & (DeviceProduct = 0H) & (DeviceBCD = 100H) THEN

  (* Override for Teac floppy drive *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUFI;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Teac Floppy (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 0693H) & (DeviceProduct = 2H) & (DeviceBCD = 100H) THEN

  (* Override for Hagiwara Flashgate Smartmedia *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodBulkOnly;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Hagiwara Smartmedia (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 0693H) & (DeviceProduct = 5H) & (DeviceBCD = 100H) THEN

  (* Override for Hagiwara Flashgate xx? *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodBulkOnly;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Hagiwara Flashgate (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 0781H) & (DeviceProduct = 1H) & (DeviceBCD = 200H) THEN

  (* Override for Sandisk Imagemate SDDR-05a *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Sandisk SDDR-05a (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 0781H) & (DeviceProduct = 100H) & (DeviceBCD = 100H) THEN

  (* Override for Sandisk Imagemate SDDR-12 *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodCB;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Sandisk SDDR-12 (UNTESTED)"); Kernel.WriteLn; END;

 ELSIF (DeviceVendor = 0781H) & (DeviceProduct = 2H) & (DeviceBCD = 9H) THEN

  (* Override for Sandisk Imagemate SDDR-31 *) (* UNTESTED !!!!! *)

  ProbeDev.TransportMethod := MethodBulkOnly;
  ProbeDev.TransportProtocol := ProtocolUTS;
  IF SOFTDEBUG THEN Kernel.WriteString("UsbStorage: Override for Sandisk SDDR-31 (UNTESTED)"); Kernel.WriteLn; END;

 ELSE (* generic devices detect *)

  IF if.bInterfaceClass # 8 THEN RETURN END;

  IF if.bInterfaceProtocol = 0 THEN ProbeDev.TransportMethod := MethodCBI;
  ELSIF if.bInterfaceProtocol = 1 THEN ProbeDev.TransportMethod := MethodCB;
  ELSIF if.bInterfaceProtocol = 50H THEN ProbeDev.TransportMethod := MethodBulkOnly
  ELSE RETURN;
  END;

  IF if.bInterfaceSubClass = 1 THEN ProbeDev.TransportProtocol := ProtocolRBC;
  ELSIF if.bInterfaceSubClass = 2 THEN ProbeDev.TransportProtocol := Protocol8020;
  ELSIF if.bInterfaceSubClass = 3 THEN ProbeDev.TransportProtocol := ProtocolQIC157;
  ELSIF if.bInterfaceSubClass = 4 THEN ProbeDev.TransportProtocol := ProtocolUFI;
  ELSIF if.bInterfaceSubClass = 5 THEN ProbeDev.TransportProtocol := Protocol8070;
  ELSIF if.bInterfaceSubClass = 6 THEN ProbeDev.TransportProtocol := ProtocolUTS;
  ELSE RETURN;
  END;
 END;

 (* now parse all endpoints *)

 IF (if.bNumEndpoints # 2) & (if.bNumEndpoints # 3) THEN RETURN END;

 FOR i:= 0 TO if.bNumEndpoints - 1 DO
  tmp := SHORT(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, if.Endpoints[i].bEndpointAddress) * {0,1,2,3,7}));
  IF (if.Endpoints[i].bmAttributes = {1}) & (SYSTEM.VAL(SET, if.Endpoints[i].bEndpointAddress) * {7} = {} ) THEN
   ProbeDev.BulkOutEndpoint := tmp;
  ELSIF  (if.Endpoints[i].bmAttributes = {1}) & (SYSTEM.VAL(SET, if.Endpoints[i].bEndpointAddress) * {7} # {} ) THEN
   ProbeDev.BulkInEndpoint := tmp;
  ELSIF  (if.Endpoints[i].bmAttributes = {0,1}) & (SYSTEM.VAL(SET, if.Endpoints[i].bEndpointAddress) * {7} # {} ) THEN
   ProbeDev.InterruptEndpoint := tmp; ProbeDev.InterruptInterval := if.Endpoints[i].bInterval;
  END;
 END;

 (* Decide which transport method to use *)

 IF ProbeDev.TransportMethod = MethodCBI THEN
   IF (ProbeDev.BulkInEndpoint = 0) OR (ProbeDev.BulkOutEndpoint = 0)
    OR (ProbeDev.InterruptEndpoint = 0) THEN RETURN END;
   ProbeDev.TransportHandler := TransportCBI; ProbeDev.TransportResetHandler := TransportCBIReset;
 ELSIF ProbeDev.TransportMethod = MethodCB THEN
   IF (ProbeDev.BulkInEndpoint = 0) OR (ProbeDev.BulkOutEndpoint = 0) THEN RETURN END;
   ProbeDev.TransportHandler := TransportCBI; ProbeDev.TransportResetHandler := TransportCBIReset;
 ELSIF ProbeDev.TransportMethod = MethodBulkOnly THEN
   IF (ProbeDev.BulkInEndpoint = 0) OR (ProbeDev.BulkOutEndpoint = 0) THEN RETURN END;
   ProbeDev.TransportHandler := TransportBulkOnly; ProbeDev.TransportResetHandler := TransportBulkOnlyReset;
 ELSIF ProbeDev.TransportMethod = MethodSCMShuttle THEN
   IF (ProbeDev.BulkInEndpoint = 0) OR (ProbeDev.BulkOutEndpoint = 0) THEN RETURN END;
   ProbeDev.TransportHandler := TransportSCMShuttle; ProbeDev.TransportResetHandler := TransportCBIReset;
 ELSE
  HALT(303);
 END;

 (* Decide which protocol method to use *)

 IF ProbeDev.TransportProtocol = ProtocolUFI THEN
  ProbeDev.desc := "Usb UFI Floppy drive";
 ELSIF ProbeDev.TransportProtocol = ProtocolUTS THEN
  ProbeDev.desc := "Usb Transparent SCSI device";
 ELSIF ProbeDev.TransportProtocol = ProtocolRBC THEN
  ProbeDev.desc := "Usb Reduced Block Command Drive";
 ELSIF ProbeDev.TransportProtocol = ProtocolQIC157 THEN
  ProbeDev.desc := "Usb QIC-157 Tape device";
 ELSIF ProbeDev.TransportProtocol = Protocol8020 THEN
  ProbeDev.desc := "Usb SFF8020i ATAPI device";
 ELSIF ProbeDev.TransportProtocol = Protocol8070 THEN
  ProbeDev.desc := "Usb SFF8070i ATAPI device";
 ELSE
  HALT(303);
 END;

 (* Special init, if necessary *)
 
 IF SpecialInit # NIL THEN
  IF ~(SpecialInit(ProbeDev)) THEN RETURN; END;
 END;

 (* test if drive is working and is of mass storage type (important for SCSI devices) *)

 IF ~InquiryDevice(ProbeDev) THEN RETURN; END;

 (* OK, the drive is working and a mass storage device, now we can allocate memory for it *)

 NEW(stordev);
 (* fields from Disk.Mod *)
 stordev.desc := ProbeDev.desc; stordev.blockSize := 0; stordev.flags := ProbeDev.flags;
 stordev.transfer := Dotransfer; stordev.getSize := DogetSize; stordev.handle := Dohandle;
 stordev.table := NIL; stordev.openCount := 0;
 (* our fields *)
 stordev.UsbDevice := ProbeDev.UsbDevice; ProbeDev.UsbDevice := NIL;
 stordev.Interface := ProbeDev.Interface;
 stordev.BulkInEndpoint := ProbeDev.BulkInEndpoint;
 stordev.BulkOutEndpoint := ProbeDev.BulkOutEndpoint;
 stordev.InterruptEndpoint := ProbeDev.InterruptEndpoint;
 stordev.InterruptInterval := ProbeDev.InterruptInterval;
 stordev.number := ProbeDev.number;
 stordev.TransportMethod := ProbeDev.TransportMethod;
 stordev.TransportProtocol := ProbeDev.TransportProtocol;
 stordev.TransportHandler := ProbeDev.TransportHandler;
 stordev.TransportResetHandler := ProbeDev.TransportResetHandler;
 stordev.DeviceType := ProbeDev.DeviceType;
 NEW(stordev.req);

 (* give it a name *)

 IF stordev.DeviceType = 5 THEN
  stordev.name := "USBCDxxx"; namelen := 5;
 ELSIF stordev.TransportProtocol = ProtocolRBC THEN
  stordev.name := "USBRBCxxx"; namelen := 6;
 ELSIF stordev.TransportProtocol = ProtocolUFI THEN
  stordev.name := "USBUFIxxx"; namelen := 6;
 ELSIF stordev.TransportProtocol = ProtocolUTS THEN
  stordev.name := "USBSCSIxxx"; namelen := 7;
 ELSIF (stordev.TransportProtocol = Protocol8020) OR (stordev.TransportProtocol = Protocol8070) THEN
  stordev.name := "USBATAPIxxx"; namelen := 8;
 ELSIF stordev.TransportProtocol = ProtocolQIC157 THEN
  stordev.name := "USBQICxxx"; namelen := 6;
 ELSE
  HALT(303);
 END;

 stordev.number := 0;  tmpd := StorageDeviceList;
 LOOP IF tmpd = NIL THEN EXIT END;
  i :=0; WHILE (stordev.name[i] = tmpd.name[i]) & (i < namelen) DO INC(i); END;
  IF (i = namelen) & (tmpd.number = stordev.number) THEN
   tmpd := StorageDeviceList; INC(stordev.number);
  ELSE
   tmpd := tmpd.next;
  END;
 END;

 IF stordev.number < 10 THEN
  stordev.name[namelen] := CHR(ORD("0") + stordev.number); stordev.name[namelen+1] := 0X;
 ELSIF stordev.number < 100 THEN
  stordev.name[namelen] := CHR(ORD("0") + stordev.number DIV 10);
  stordev.name[namelen+1] := CHR(ORD("0") + stordev.number MOD 10); stordev.name[namelen+2] := 0X;
 ELSE
  stordev.name[namelen] := CHR(ORD("0") + stordev.number DIV 100);
  stordev.name[namelen+1] := CHR(ORD("0") + ((stordev.number DIV 10) MOD 10));
  stordev.name[namelen+2] := CHR(ORD("0") + stordev.number MOD 10); stordev.name[namelen+3] := 0X;
 END;

 (* show something to the kernel log/serial *)

 Kernel.WriteString("UsbStorage: Device detected."); Kernel.WriteLn;

 (* Register the device in the Disks module *)

 Disks.Register(stordev);

 stordev.next := StorageDeviceList;
 StorageDeviceList := stordev;

 (* And now (and not earlier!!!) show the usb layer that we are responsible for this interface *)

 if.Driver := UsbStorageDriver; 

END StorageProbe;

(* --------------------------------------------------------------------------- *)
(*                                                             Usb device disconnect                                                        *)
(* --------------------------------------------------------------------------- *)

PROCEDURE StorageDisconnect(dev : Usb.UsbDevice);
VAR
 tmp, last : StorageDevice;
BEGIN
 Kernel.WriteString("USB storage device disconnecting."); Kernel.WriteLn;
 tmp := StorageDeviceList; last := NIL;
 WHILE tmp # NIL DO
  IF tmp.UsbDevice = dev THEN
   CleanupDevice(tmp);
   IF last = NIL THEN StorageDeviceList := tmp.next; ELSE last.next := tmp.next; END;
   tmp := tmp.next;
  ELSE
   last := tmp; tmp := tmp.next;
  END;
 END;
END StorageDisconnect;

(* --------------------------------------------------------------------------- *)
(*                                                                            Init                                                                       *)
(* --------------------------------------------------------------------------- *)

PROCEDURE Install*();
BEGIN
 (* dummy *)
END Install;

(* --------------------------------------------------------------------------- *)
(*                                                                         Cleanup                                                                  *)
(* --------------------------------------------------------------------------- *)

PROCEDURE Cleanup();
VAR
 act : StorageDevice;
BEGIN
 act := StorageDeviceList; 
 WHILE act # NIL DO CleanupDevice(act); act := act.next; END;
 Usb.RemoveDriver(UsbStorageDriver);
END Cleanup;

(* --------------------------------------------------------------------------- *)
(*                                                                      ModuleInit                                                                 *)
(* --------------------------------------------------------------------------- *)

BEGIN
 StorageDeviceList := NIL;
 NEW(ProbeDev);
 NEW(ProbeDev.req);
 NEW(UsbStorageDriver);
 UsbStorageDriver.DriverName := DriverNameVersion;
 UsbStorageDriver.OpProbe := StorageProbe;
 UsbStorageDriver.OpDisconnect := StorageDisconnect;
 Usb.RegisterDriver(UsbStorageDriver);
 Kernel.InstallTermHandler(Cleanup);
END UsbStorage.

(** Init: UsbStorage.Init **)
