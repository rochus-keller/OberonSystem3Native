(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

 MODULE Disks; (** non-portable *) (* pjm *)

(** Block devices. *)

(* Based on AosDisks *)

IMPORT Kernel;

CONST
 Read* = 0; Write* = 1; (** Device.transfer.op *)
 
  (** res parameter *)
 Ok* = 0; (** no error *)
 
  (** common errors - a device may also return its own error codes > 0 *)
 MediaChanged* = -1; (** media in removable device was changed unexpectedly *)
 WriteProtected* = -2; (** write failed because media is write-protected *)
 Unsupported* = -3; (** operation is currently not supported on this device *)
 DeviceInUse* = -4; (** the device is open (UpdatePartitionTable) or mounted already *)
 MediaMissing* = -5; (** the device media is not present *)

  (** Device.flags *)
 ReadOnly* = 0; (** the current media can not be written to *)
 Removable* = 1; (** the device has removable media *)
 
  (** Partition.flags *)
 Mounted* = 0; (** a file system is currently mounted on the partition (set by file system implementations) *)
 Primary* = 1; (** a primary partition *)
 Boot* = 2; (** a bootable partition *)
 Valid* = 3; (** media contains a valid partition table. *)

 BS = 512; (* default block size *)
 
 Trace = FALSE;
 
TYPE
 Name* = ARRAY 32 OF CHAR;
 Description* = ARRAY 64 OF CHAR;
 
 Message* = RECORD END;
 
 Device* = POINTER TO DeviceDesc;
 
 Partition* = RECORD
  type*: LONGINT; (** partition type *)
  start*, size*: LONGINT; (** start block and size of partition in blocks *)
  flags*: SET; (** Mounted, Primary, Boot, Valid *)
  ptblock*: LONGINT; (** block containing partition table entry *)
  ptoffset*: LONGINT; (** offset in partition table of entry, 0 if unknown *)
 END;
 PartitionTable* = POINTER TO ARRAY OF Partition;

 TransferProc* = PROCEDURE (dev: Device; op, block, num: LONGINT; VAR data: ARRAY OF CHAR; ofs: LONGINT; VAR res: LONGINT);
 GetSizeProc* = PROCEDURE (dev: Device; VAR size, res: LONGINT);
 HandleProc* = PROCEDURE (dev: Device; VAR msg: Message; VAR res: LONGINT);

(** The base for block devices. It provides operations on an abstract array of disk blocks of blockSize bytes, 
numbered from 0 to size-1. If applicable, a PC-format partition table starts at block 0, and can be read into 
the table field with Open or UpdatePartitionTable. *)

 DeviceDesc* = RECORD (** fields read-only, initialized by extender *)
  name*: Name; (** unique device name *)
  desc*: Description; (** device description for Partition.Show etc. *)
  blockSize*: LONGINT; (** in bytes - unit of block, num & size parameters *)
  flags*: SET; (** ReadOnly, Removable *)
  transfer*: TransferProc; (** read or write blocks *)
  getSize*: GetSizeProc; (** get total size of device *)
  handle*: HandleProc; (** handle optional messages *)
  table*: PartitionTable; (** cache for partition table *)
  openCount*: LONGINT; (** number of times device has been opened *)
 END;
 
 EjectMsg* = RECORD (Message) END; (** eject the media *)
 LockMsg* = RECORD (Message) END; (** disallow manual ejection *)
 UnlockMsg* = RECORD (Message) END; (** allow manual ejection *)
 SavePowerMsg* = RECORD (Message) END; (** spin down the device *)
 GetGeometryMsg* = RECORD (Message) (** return physical geometry *)
  cyls*, hds*, spt*: LONGINT
 END;
 ShutdownMsg* = RECORD (Message) END; (** shut down the device (driver) *)

 DeviceTable* = POINTER TO ARRAY OF Device;

 DiskBlock = ARRAY BS OF CHAR;

VAR
 num: LONGINT;
 dev: DeviceTable;

PROCEDURE Transfer(dev: Device; op, block, num: LONGINT; VAR data: ARRAY OF CHAR; ofs: LONGINT; VAR res: LONGINT);
BEGIN
 res := Unsupported
END Transfer;

PROCEDURE GetSize(dev: Device; VAR size, res: LONGINT);
BEGIN
 res := Unsupported
END GetSize;

PROCEDURE Handle(dev: Device; VAR msg: Message; VAR res: LONGINT);
BEGIN
 res := Unsupported
END Handle;

(** Initialize a device. Defaults: blockSize = 512, flags = {}, all methods return res = Unsupported. *)

PROCEDURE InitDevice*(d: Device; name: ARRAY OF CHAR);
BEGIN
 COPY(name, d.name); d.desc := "";
 d.blockSize := BS; d.flags := {}; d.table := NIL; d.openCount := 0;
 d.transfer := Transfer; d.getSize := GetSize; d.handle := Handle
END InitDevice;

(** Register a new device. *)

PROCEDURE Register*(d: Device);
VAR old: DeviceTable; i: LONGINT;
BEGIN
 FOR i := 0 TO num-1 DO
  ASSERT(d.name # dev[i].name) (* name must be unique *)
 END;
 IF num = LEN(dev) THEN
  old := dev; NEW(dev, 2*LEN(dev));
  FOR i := 0 TO LEN(old)-1 DO dev[i] := old[i] END
 END;
 dev[num] := d; INC(num)
END Register;

(** Unregister a device. Existing clients may still have pointers to the device! *)

PROCEDURE Unregister*(d: Device);
VAR i: LONGINT;
BEGIN
 ASSERT(d # NIL);
 i := 0; WHILE dev[i] # d DO INC(i) END; (* must be registered *)
 WHILE i+1 < num DO dev[i] := dev[i+1]; INC(i) END;
 DEC(num); dev[num] := NIL;
 d.transfer := Transfer; d.getSize := GetSize; d.handle := Handle (* restore null methods *)
END Unregister;

(** Get a table of currently registered devices. *)

PROCEDURE GetRegistered*(VAR table: DeviceTable);
VAR i: LONGINT;
BEGIN
 IF num # 0 THEN
  NEW(table, num);
  FOR i := 0 TO num-1 DO table[i] := dev[i] END
 ELSE
  table := NIL
 END
END GetRegistered;

(* 
Partition table starts at 01BEH in partition table sector and consists of 4 records of the type:
 
 00  bootind: Types.Byte;
 01  head: Types.Byte;
 02  sectorcyl: Types.Byte;
 03  cyl: Types.Byte;
 04  type: Types.Byte;
 05  head2: Types.Byte;
 06  sector2cyl: Types.Byte;
 07  cyl2: Types.Byte;
 08  start: Types.DWord;
 12  num: Types.DWord

References: 
 MSKB Q69912 MS-DOS Partitioning Summary
 MSKB Q51978 Order in Which MS-DOS and Windows 95 Assigns Drive Letters 
 MSKB Q151414 Windows 95 Partition Types Not Recognized by Windows NT
 MSKB Q93373 Default Drive Letters and Partitions in Windows NT
*)

PROCEDURE Resize(VAR p: PartitionTable; n: LONGINT);
VAR old: PartitionTable; i, len: LONGINT;
BEGIN
 len := LEN(p); WHILE len < n DO len := 2*len END;
 old := p; NEW(p, len);
 FOR i := 0 TO LEN(old)-1 DO p[i] := old[i] END
END Resize;

PROCEDURE Get4(VAR b: ARRAY OF CHAR; i: LONGINT): LONGINT;
BEGIN
 RETURN ORD(b[i]) + ASH(ORD(b[i+1]), 8) + ASH(ORD(b[i+2]), 16) + ASH(ORD(b[i+3]), 24)
END Get4;

PROCEDURE Extended(type: LONGINT): BOOLEAN;
BEGIN
 RETURN (type = 5) OR (type = 15)
END Extended;

(*
PROCEDURE ValidFlag(f: CHAR): BOOLEAN;
BEGIN
  (* to do: this fails with some tables generated by some partitioning tools (e.g. efdisk) *)
 RETURN (f = 0X) OR (f = 80X) OR (f = 81X)
END ValidFlag;
*)

(* Read primary partition table entries into p *)

PROCEDURE ReadPrimary(dev: Device; devsize: LONGINT; VAR p: PartitionTable; VAR n, res: LONGINT; VAR valid: BOOLEAN);
VAR b: DiskBlock; e, size, i: LONGINT;
BEGIN
 n := 0;
 dev.transfer(dev, Read, 0, 1, b, 0, res);
 IF (res = Ok) & (b[510] = 055X) & (b[511] = 0AAX) THEN (* signature ok *)
  (*valid := ~((b[21] = 0F0X) & (b[24] = CHR(18)) & (b[26] = CHR(2)));*)
   (* this check must determine if the drive contains a valid partition table (is not a floppy) *)
  (*valid := ValidFlag(b[01BEH]) & ValidFlag(b[01BEH+16]) & ValidFlag(b[01BEH+32]) & ValidFlag(b[01BEH+48]);*)
  valid := TRUE;
  FOR i := 0 TO 3 DO
   e := 01BEH + 16*i; size := Get4(b, e+12);
   IF (b[e+4] # 0X) & (size # 0) THEN (* non-empty partition *)
    Resize(p, n+1); p[n].type := ORD(b[e+4]);
    p[n].start := Get4(b, e+8); p[n].size := size; p[n].flags := {Valid, Primary};
    IF b[e] # 0X THEN INCL(p[n].flags, Boot) END;
    p[n].ptblock := 0; p[n].ptoffset := e;
    valid := valid & (p[n].start >= 0) & (p[n].start < devsize) & (size > 0) & (p[n].start+size <= devsize);
    INC(n)
   END
  END;
  IF ~valid THEN n := 0 END
 ELSE
  IF Trace THEN
   Kernel.WriteString("Disks: ReadPrimary = "); Kernel.WriteInt(res, 1);
   Kernel.WriteString(" on "); Kernel.WriteString(dev.name); Kernel.WriteLn
  END
 END
END ReadPrimary;

(* Read "logical drive" partitions into p *)

PROCEDURE ReadLogical(dev: Device; first: LONGINT; VAR p: PartitionTable; VAR n, res: LONGINT);
VAR b: DiskBlock; e, sec, size, i: LONGINT; found: BOOLEAN;
BEGIN
 sec := first;
 REPEAT
  found := FALSE;
  dev.transfer(dev, Read, sec, 1, b, 0, res);
  IF (res = Ok) & (b[510] = 055X) & (b[511] = 0AAX) THEN
   FOR i := 0 TO 3 DO (* look for partition entry (max one expected) *)
    e := 01BEH + 16*i; size := Get4(b, e+12);
    IF (b[e+4] # 0X) & ~Extended(ORD(b[e+4])) & (size # 0) THEN
     Resize(p, n+1); p[n].type := ORD(b[e+4]);
     p[n].start := sec + Get4(b, e+8); p[n].size := size; p[n].flags := {Valid};
     IF b[e] # 0X THEN INCL(p[n].flags, Boot) END;
     p[n].ptblock := sec; p[n].ptoffset := e;
     INC(n)
    END
   END;
   i := 0;
   WHILE (i # 4) & ~found DO (* look for nested extended entry (max one expected) *)
    e := 01BEH + 16*i; size := Get4(b, e+12);
    IF Extended(ORD(b[e+4])) & (size # 0) THEN (* found *)
     sec := first + Get4(b, e+8);
     i := 4; found := TRUE
    ELSE
     INC(i)
    END
   END
  ELSE
   IF Trace THEN
    Kernel.WriteString("Disks: ReadLogical = "); Kernel.WriteInt(res, 1);
    Kernel.WriteString(" on "); Kernel.WriteString(dev.name);
    Kernel.WriteString(" sector "); Kernel.WriteInt(sec, 1); Kernel.WriteLn
   END
  END
 UNTIL ~found
END ReadLogical;

(** Read a PC-format partition table starting at block 0 and initialize dev.table. dev.table[0] is a virtual 
partition spanning the entire device, with type = 256. If the device has been opened before, do nothing and 
return DeviceInUse, otherwise return Ok. On any other error dev.table is set NIL. *)

PROCEDURE UpdatePartitionTable*(dev: Device; VAR res: LONGINT);
VAR p, t: PartitionTable; i, pn, tn, size: LONGINT; valid: BOOLEAN;
BEGIN
 IF dev.openCount = 0 THEN
  tn := 0; res := Ok;
  dev.table := NIL;
  dev.getSize(dev, size, res);
  IF (res = Ok) & (dev.blockSize = BS) THEN
   NEW(p, 4); NEW(t, 8);
   ReadPrimary(dev, size, p, pn, res, valid);
   i := 0;
   WHILE valid & (i # pn) & (res = Ok) DO
    Resize(t, tn+1); t[tn] := p[i]; INC(tn);
    IF Extended(p[i].type) THEN
     ReadLogical(dev, p[i].start, t, tn, res)
    END;
    INC(i)
   END
  END;
  IF res = Ok THEN
   NEW(dev.table, tn+1);
   dev.table[0].type := 256;
   IF valid THEN dev.table[0].flags := {Valid} ELSE dev.table[0].flags := {} END;
   dev.table[0].start := 0; dev.table[0].size := size;
   FOR i := 1 TO tn DO dev.table[i] := t[i-1] END
  END
 ELSE
  res := DeviceInUse (* could not update partition table *)
 END
END UpdatePartitionTable;

(** Open the device and increment its open count if successful. If the device is opened for the first time, 
lock it and update its partition table. *)
PROCEDURE Open*(dev: Device; VAR res: LONGINT);
VAR lockMsg: LockMsg; unlockMsg: UnlockMsg; ignore: LONGINT;
BEGIN
 res := Ok;
 IF dev.openCount = 0 THEN
  dev.handle(dev, lockMsg, res);
  IF res = Unsupported THEN res := Ok END;
  IF res = Ok THEN
   UpdatePartitionTable(dev, res);
   IF res # Ok THEN dev.handle(dev, unlockMsg, ignore) END
  END
 END;
 IF res = Ok THEN INC(dev.openCount) END
END Open;

(** Close the device and decrement its open count. Unlock it if the open count has reached 0. *)
PROCEDURE Close*(dev: Device; VAR res: LONGINT);
VAR unlockMsg: UnlockMsg;
BEGIN
 res := Ok;
 IF dev.openCount > 0 THEN
  DEC(dev.openCount);
  IF dev.openCount = 0 THEN
   dev.handle(dev, unlockMsg, res);
   IF res = Unsupported THEN res := Ok END;
   dev.table := NIL
  END
 ELSE
  IF Trace THEN
   Kernel.WriteString("Disks: Device "); Kernel.WriteString(dev.name);
   Kernel.WriteString(" not open"); Kernel.WriteLn
  END
 END
END Close;

(** Mount the specified partition, if not already mounted. *)
PROCEDURE Mount*(dev: Device; part: LONGINT; VAR res: LONGINT);
BEGIN
 IF dev.table # NIL THEN
  IF ~(Mounted IN dev.table[part].flags) THEN
   INCL(dev.table[part].flags, Mounted); res := Ok
  ELSE
   res := DeviceInUse
  END
 ELSE
  res := Unsupported
 END
END Mount;

(** Return TRUE iff the specified partition is already mounted. *)
PROCEDURE IsMounted*(dev: Device; part: LONGINT): BOOLEAN;
BEGIN
 RETURN (dev.table # NIL) & (Mounted IN dev.table[part].flags)
END IsMounted;

(** Unmount the specified partition. *)
PROCEDURE Unmount*(dev: Device; part: LONGINT);
BEGIN
 IF (dev.table # NIL) & (Mounted IN dev.table[part].flags) THEN
  EXCL(dev.table[part].flags, Mounted)
 END
END Unmount;

(* Clean up the installed devices. *)
PROCEDURE Cleanup;
VAR dev: DeviceTable; i, res: LONGINT; msg: ShutdownMsg;
BEGIN
 GetRegistered(dev);
 IF dev # NIL THEN
  FOR i := 0 TO LEN(dev^)-1 DO
   dev[i].handle(dev[i], msg, res) (* ignore res *)
  END
 END
END Cleanup;

BEGIN
 Kernel.Hello("Disks");
 num := 0; NEW(dev, 4);
 Kernel.InstallTermHandler(Cleanup)
END Disks.

(**
 o Further Transfer op numbers may be added in future, therefore devices should check explicitly for op = Read or op = Write.
o The ofs parameter in Transfer specifies the byte offset in data where the transfer will occur (typically 0).
o Positive res numbers are device-specific. Negative res numbers are reserved.
o Block size 512 and LONGINT block number limit us to 1Tb = 1024Gb.
o When the media is changed in a removable device, the next operation (transfer, getSize, handle) will fail 
with res = MediaChanged. After that the new media can be accessed as usual.  [RFC: Perhaps the MediaChanged flag should be sticky until the next LockMsg].
o The ReadOnly flag and blockSize may depend on the current media and is only valid after a successful access 
operation to a drive with removable media (transfer, getSize).
o When receiving a LockMsg, the device should clear the media not present flag. This means clients using Open/Close can treat the MediaChanged error as a real error and don't have to retry any operations.
o When the system is shut down, a ShutdownMsg is sent to every device. The driver has to perform whatever is necessary to clean up. A driver that handles multiple devices must expect one shutdown message per device.
*)

(*
to do:
o partition table valid check should only check that partitions are non-overlapping and positive
o if partition says disk is larger than device driver reports, believe the partition table
o if disk has no MBR signature, add one?
o remember bootable CD emulates a LARGE floppy
*)
