(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

 MODULE FileDisks; (* pjm *)

(* A virtual disk driver based on Files. *)

IMPORT Disks, Files, Modules, In, Out;

CONST
 BS = 512;
 
TYPE
 Device = POINTER TO RECORD (Disks.Device)
  f: Files.File;
  size, cyls , hds , spt: LONGINT;
  new: BOOLEAN
 END;

PROCEDURE Transfer(d: Disks.Device; op, lba, num: LONGINT; VAR data: ARRAY OF CHAR; ofs: LONGINT; VAR res: LONGINT);
VAR dev: Device; pos, n: LONGINT; r: Files.Rider;
BEGIN
 ASSERT(ofs = 0); (* implementation restriction *)
 IF (op = Disks.Read) OR (op = Disks.Write) THEN
  dev := d(Device);
  IF (lba >= 0) & (num >= 0) & ((lba < dev.size) & (lba+num <= dev.size)) THEN
   ASSERT(num*dev.blockSize <= LEN(data)-ofs); (* range check *)
   pos := lba*dev.blockSize;
   CASE op OF
    Disks.Read:
     IF pos < Files.Length(dev.f) THEN (* inside file *)
      Files.Set(r, dev.f, pos);
      Files.ReadBytes(r, data, num*dev.blockSize) (* fixme: should read at ofs *)
     ELSE
      r.res := num*dev.blockSize
     END;
     IF r.res # 0 THEN (* fill rest of block with 0 *)
      pos := num*dev.blockSize - r.res + ofs; n := r.res;
      WHILE n # 0 DO data[pos] := 0X; INC(pos); DEC(n) END
     END;
     res := Disks.Ok
    |Disks.Write:
     IF pos > Files.Length(dev.f) THEN (* outside file *)
      n := pos - Files.Length(dev.f);
      Files.Set(r, dev.f, Files.Length(dev.f));
      WHILE n > 0 DO Files.Write(r, 0X); DEC(n) END
     END;
     Files.Set(r, dev.f, pos);
     Files.WriteBytes(r, data, num*dev.blockSize); (* fixme: should read at ofs *)
     IF r.res = 0 THEN res := Disks.Ok ELSE res := 2 END
   END (* CASE *)
  ELSE
   res := 1
  END
 ELSE
  res := Disks.Unsupported
 END
END Transfer;

PROCEDURE GetSize(d: Disks.Device;  VAR size, res: LONGINT);
BEGIN
 size := d(Device).size; res := Disks.Ok
END GetSize;

PROCEDURE Handle(d: Disks.Device; VAR msg: Disks.Message; VAR res: LONGINT);
BEGIN
 WITH d: Device DO
  IF (msg IS Disks.GetGeometryMsg) & (d.cyls > 0) THEN
   WITH msg: Disks.GetGeometryMsg DO
    msg.cyls := d.cyls; msg.hds := d.hds; msg.spt := d.spt; res := Disks.Ok
   END
  ELSE
   res := Disks.Unsupported
  END
 END
END Handle;

(** Open a new virtual disk volume in specified file.  If size is specified, a new file of the specified number of blocks is generated.  Afterwards the virtual disk device will be visible with Partitions.Show and can be used like any other device.  The file should preferably be on a boot volume, or otherwise Close must be called before rebooting, to ensure clean shutdown of the virtual device. *)
PROCEDURE Open*; (** name [size [cyls hds spt] ] ~ *)
VAR name: ARRAY 64 OF CHAR; dev: Device;
BEGIN
 In.Open; In.Name(name);
 IF In.Done THEN
  Out.String(name);
  NEW(dev); Disks.InitDevice(dev, name); dev.blockSize := BS; dev.cyls := -1;
  In.LongInt(dev.size);
  dev.new := In.Done;
  IF dev.new THEN
   dev.f := Files.New(name);
   In.LongInt(dev.cyls); In.LongInt(dev.hds); In.LongInt(dev.spt);
   IF ~In.Done THEN dev.cyls := -1 END
  ELSE
   dev.f := Files.Old(name);
   IF (dev.f # NIL) & (Files.Length(dev.f) MOD BS = 0) THEN
    dev.size := Files.Length(dev.f) DIV BS
   ELSE
    dev.f := NIL
   END
  END;
  IF dev.f # NIL THEN
   dev.flags := {Disks.Removable};
   dev.transfer := Transfer; dev.getSize := GetSize; dev.handle := Handle;
   Disks.Register(dev);
   Out.String(" opened")
  ELSE
   Out.String(" bad file")
  END;
  Out.Ln
 END
END Open;

PROCEDURE Unregister(dev: Device);
VAR n: LONGINT; r: Files.Rider;
BEGIN
 Disks.Unregister(dev);
 Out.String("Closing "); Out.String(dev.name); Out.Char(" ");
 n := dev.size*BS - Files.Length(dev.f);
 IF n > 0 THEN (* not complete *)
  Files.Set(r, dev.f, Files.Length(dev.f));
  WHILE n > 0 DO Files.Write(r, 0X); DEC(n) END
 END;
 Out.Int(Files.Length(dev.f) DIV 1024, 1); Out.String("KB"); Out.Ln;
 IF dev.new THEN Files.Register(dev.f) ELSE Files.Close(dev.f) END;
 dev.f := NIL
END Unregister;

PROCEDURE Mounted(dev: Disks.Device): BOOLEAN;
VAR i: LONGINT;
BEGIN
 IF dev.table # NIL THEN
  FOR i := 0 TO LEN(dev.table)-1 DO
   IF Disks.Mounted IN dev.table[i].flags THEN RETURN TRUE END
  END
 END;
 RETURN FALSE
END Mounted;

(** Close the specified virtual disk device.  Be sure to first unmount any file system that has been mounted on the device, otherwise a trap will appear when the file system is accessed again. *)
PROCEDURE Close*; (** name *)
VAR name: ARRAY 64 OF CHAR; dev: Disks.DeviceTable; i: LONGINT; found: BOOLEAN;
BEGIN
 In.Open; In.Name(name);
 IF In.Done THEN
  found := FALSE;
  Disks.GetRegistered(dev);
  IF dev # NIL THEN
   FOR i := 0 TO LEN(dev)-1 DO
    IF dev[i].name = name THEN
     IF ~Mounted(dev[i]) THEN
      Unregister(dev[i](Device))
     ELSE
      Out.String(name); Out.String(" has mounted file systems"); Out.Ln
     END;
     found := TRUE
    END
   END
  END;
  IF ~found THEN Out.String(name); Out.String(" not found"); Out.Ln END
 END
END Close;

PROCEDURE Cleanup;
VAR dev: Disks.DeviceTable; i: LONGINT;
BEGIN
 Disks.GetRegistered(dev);
 IF dev # NIL THEN
  FOR i := 0 TO LEN(dev)-1 DO
   IF dev[i] IS Device THEN Unregister(dev[i](Device)) END
  END
 END
END Cleanup;

BEGIN
 Modules.InstallTermHandler(Cleanup)
END FileDisks.

FileDisks.Open SYS:oberon0.dsk ~
FileDisks.Close ^

OFSTools.Mount SRC NatFS SYS:oberon0.dsk ~
OFSTools.Unmount SRC

Partitions.Show

System.Free FileDisks ~
