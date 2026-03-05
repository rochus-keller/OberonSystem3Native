(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSFileBasedDevices; (* be *)

(** Disks.Device implementation based on any file on any file system *)

IMPORT SYSTEM, Kernel, Disks, OFS;

CONST
 moduleName = "OFSFileBasedDevices: ";
 Trace = FALSE;
 
 (* General Constants *)
 DeviceMessage1 = "ETH Oberon Virtual Device.";
 DeviceMessage2 = "Do not edit or modify this file or you will destroy the data it contains !";
 DeviceMessage3 = "ETH Oberon, Copyright 2001 ETH Zuerich Institut fuer Computersysteme";
 DeviceMessage4 = "http://www.oberon.ethz.ch";
 BS = 512; (* device block size *)
 
TYPE
 FileDevice = POINTER TO RECORD(Disks.Device)
  fs: OFS.FileSystem;
  file: OFS.File;
  rider: OFS.Rider;
  size: LONGINT; (* in blocks *)
 END;
  
 DataBlock = ARRAY MAX(LONGINT) OF CHAR;
 
VAR
 error*: ARRAY 60 OF CHAR; (* report initialisation errors *)
 
(** transfer - read from/write to device. ofs # 0 is not supported *)
PROCEDURE transfer(dev: Disks.Device; op, lba, num: LONGINT; VAR data: ARRAY OF CHAR; ofs: LONGINT; VAR res: LONGINT);
BEGIN
 IF (op = Disks.Write) & (Disks.ReadOnly IN dev.flags) THEN SYSTEM.HALT(21) END;
 IF (ofs # 0) THEN SYSTEM.HALT(23) END; (* implementation restriction *)
 WITH dev: FileDevice DO
  IF (lba < 0) OR (lba + num > dev.size) THEN SYSTEM.HALT(15) END;
  dev.file.fs.Set(dev.rider, dev.file, lba*BS);
  IF (op = Disks.Read) THEN dev.file.fs.ReadBytes(dev.rider, data, num*BS); res := dev.rider.res
  ELSIF (op = Disks.Write) THEN dev.file.fs.WriteBytes(dev.rider, data, num*BS); res := dev.rider.res
  ELSE res := Disks.Unsupported
  END
 END 
END transfer;
  
(** getSize - returns the size (in blocks) of the device *)
PROCEDURE getSize(dev: Disks.Device;  VAR size, res: LONGINT);
BEGIN
 size := dev(FileDevice).size; res := Disks.Ok
END getSize;

(** handle - message handler *)
PROCEDURE handle(dev: Disks.Device; VAR msg: Disks.Message; VAR res: LONGINT);
BEGIN
 WITH dev: FileDevice DO
  IF (msg IS Disks.GetGeometryMsg) THEN
   WITH msg: Disks.GetGeometryMsg DO
    msg.cyls := dev.size;
    msg.hds := 1;
    msg.spt := 1;
    res := Disks.Ok   
   END
  ELSE  
   res := Disks.Unsupported
  END
 END
END handle;

PROCEDURE HasValidMBR(dev: FileDevice): BOOLEAN;
VAR b: ARRAY BS OF CHAR;
 res: LONGINT;
BEGIN
 dev.transfer(dev, Disks.Read, 0, 1, b, 0, res);
 IF (res = Disks.Ok) THEN 
  RETURN (b[1FEH] = 055X) & (b[1FFH] = 0AAX) & (b[1BEH+04H] # 0X)
 ELSE RETURN FALSE
 END
END HasValidMBR;

PROCEDURE WriteMBR(dev: FileDevice);
CONST (* partition table entry start in MBR and size of partition table entry *)
 PTEStart = 1BEH;
 PTESize = 10H;
VAR b: ARRAY BS OF CHAR;
 msg: ARRAY 446 OF CHAR;
 CRLF: ARRAY 2 OF CHAR;
 EoF: ARRAY 1 OF CHAR;
 i, res: LONGINT;

 PROCEDURE PartitionEntry(VAR b: ARRAY OF CHAR; Index: SHORTINT; State, Type: CHAR; FirstSector, NumSectors: LONGINT);
 (* Index: primary partition index (0..3); FirstSector: #sectors betweed MBR and the first sector in the partition *)
 VAR base: INTEGER; 
  h,c,s: INTEGER;
 BEGIN
  ASSERT((0 <= Index) & (Index < 4)); (* Index = 0...3 *)
  base := PTEStart + Index*PTESize;
  b[base] := State;
  (* beginning of partition - Head, Cylinder & Sector *)
  (* b[base+01H] = Head (1 Byte) *)
  (* b[base+02H] = Cylinder/Sector (2 Bytes *)
  (* Encoding for cylinder/sector: 16 bits = c[7..0] c[9..8] s[5..0] (c: cylinder, s: sector) *)
  h := 255;
  s := 63;
  c := SHORT(FirstSector DIV LONG(h*s));
  b[base+01H] := CHR(h);   
  PutInteger(b, base+02H, SHORT(SYSTEM.LSH(AND(c, 00FFH), 8) + SYSTEM.LSH(AND(c, 0300H), 6) + s));   
  b[base+04H] := Type;
  (* end of partition - Head, Cylinder & Sector *)
  h := 255;
  s := 63;
  c := SHORT((FirstSector + NumSectors) DIV LONG(h*s));
  b[base+05H] := CHR(h);   
  PutInteger(b, base+06H, SHORT(SYSTEM.LSH(AND(c, 00FFH), 8) + SYSTEM.LSH(AND(c, 0300H), 6) + s));   
  PutLongint(b, base+08H, FirstSector);
  PutLongint(b, base+0CH, NumSectors)
 END PartitionEntry;

BEGIN
 Kernel.WriteString(moduleName); Kernel.WriteString("writing new a new MBR to virtual device"); Kernel.WriteLn;
 FOR i := 0 TO BS-1 DO b[i] := 0X END;
 (* put a informative string at the beginning of the MBR (instead of executable code) *)
 i := 0; CRLF[0] := 0DX; CRLF[1] := 0AX; EoF[0] := 1AX;
 PutCharacters(b, i, DeviceMessage1, Length(DeviceMessage1)); PutCharacters(b, i, CRLF, 2);
 PutCharacters(b, i, DeviceMessage2, Length(DeviceMessage2)); PutCharacters(b, i, CRLF, 2); PutCharacters(b, i, CRLF, 2);
 PutCharacters(b, i, DeviceMessage3, Length(DeviceMessage3)); PutCharacters(b, i, CRLF, 2); 
 PutCharacters(b, i, DeviceMessage4, Length(DeviceMessage4)); PutCharacters(b, i, EoF, 1);
 (* create one primary partition that spans the entire device *) 
 PartitionEntry(b, 0, 080X, 04CX, 1, dev.size-1); (* set partition type to Native Oberon, Aos *)
 PartitionEntry(b, 1, 0X, 0X, 0, 0);
 PartitionEntry(b, 2, 0X, 0X, 0, 0);
 PartitionEntry(b, 3, 0X, 0X, 0, 0);
 b[1FEH] := 055X;
 b[1FFH] := 0AAX;
 dev.transfer(dev, Disks.Write, 0, 1, b, 0, res) (* ignore res *)
END WriteMBR;

(** Open - generate a new dos based virtual device. If FixMBR=TRUE, write new MBR & create one primary partition *)
PROCEDURE Open*(VAR devname: Disks.Name; VAR prefix, filename: ARRAY OF CHAR; 
  ReadOnly, FixMBR: BOOLEAN; VAR res: LONGINT); 
VAR file: OFS.File;
 device: FileDevice;
 fullname: ARRAY 1024 OF CHAR;
BEGIN
 res := -1;
 Kernel.WriteString(moduleName);  Kernel.WriteString(filename); 
 OFS.JoinName(prefix, filename, fullname);
 file := OFS.Old(fullname);  
 IF file # NIL THEN
  NEW(device);
  device.name := devname;
  (*device.desc := "virtual device based on a file";*)
  COPY(fullname, device.desc);
  IF ReadOnly THEN INCL(device.flags, Disks.ReadOnly) END;
  device.file := file;
  device.blockSize := BS;
  device.size := file.fs.Length(file) DIV BS;
  device.transfer := transfer;
  device.getSize := getSize;
  device.handle := handle;
  IF ~HasValidMBR(device) THEN
   IF FixMBR THEN WriteMBR(device);
   ELSE RETURN
   END
  END;
  Disks.Register(device);
  Kernel.WriteString(" registered");
  res := 0
 ELSE Kernel.WriteString(" not found")
 END;
 Kernel.WriteLn
END Open;

(* helper functions *)

(* AND - bitwise AND *)
PROCEDURE AND(a,b: LONGINT): LONGINT;
BEGIN RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, a) * SYSTEM.VAL(SET, b));
END AND;
 
(* Length - length of string, exlcuding the ending 0X *)
PROCEDURE Length(s: ARRAY OF CHAR): LONGINT;
VAR pos: LONGINT;
BEGIN
 pos := 0;
 WHILE (pos < LEN(s)) & (s[pos] # 0X) DO INC(pos) END;
 RETURN pos
END Length;
 
(* PutCharacters - copies 'count' bytes from 's' to 'b', starting at 'b[ofs]' *)
PROCEDURE PutCharacters(VAR b: ARRAY OF CHAR; VAR ofs: LONGINT; s: ARRAY OF CHAR; count: LONGINT);
VAR i: INTEGER;
BEGIN 
 i := 0; 
 WHILE (i < count) DO b[ofs+i] := s[i]; INC(i) END;
 ofs := ofs + i;
END PutCharacters;

(* PutInteger - writes an integer at offset 'ofs' in 'b' which is assumed to be little endian *)
PROCEDURE PutInteger(VAR b: ARRAY OF CHAR; ofs: LONGINT; value: INTEGER);
BEGIN
 b[ofs] := SYSTEM.VAL(CHAR, value MOD 100H);
 b[ofs+1] := SYSTEM.VAL(CHAR, value DIV 100H)
END PutInteger;

(* PutLongint - writes a long integer at offset 'ofs' in 'b' which is assumed to be little endian *)
PROCEDURE PutLongint(VAR b: ARRAY OF CHAR; ofs, value: LONGINT);
VAR i : INTEGER;
BEGIN
 FOR i := 0 TO 3 DO b[ofs+i] := SYSTEM.VAL(CHAR, value MOD 100H); value := value DIV 256 END
END PutLongint;

END OFSFileBasedDevices.
 

System.Free OFSFileBasedDevices ~

OFSFileBasedDeviceTools.Open VDSK0 SYS Oberon.Dsk~ 
OFSFileBasedDeviceTools.Open VDSK1 FAT Oberon.Dsk~
OFSFileBasedDeviceTools.Close  VDSK1 ^ VDSK0 VDSK1
!OFSFileBasedDevice.Resize VDSK0 4096 ~

Partitions.Show
Partitions.Unsafe
Partitions.ChangeType VDSK0#1 0 76 ~ 76: Aos, 79: NatFS, 80: NatFS2
Partitions.Format VDSK0#01 AosFS -1 Native.bin~
Partitions.Format VDSK1#01 AosFS -1 Native.bin~

OFSTools.Watch
OFSTools.Mount A TestFS VDSK0#01 ~
OFSTools.Mount B AosFS VDSK1#01 ~
OFSTools.Unmount ^ A ~ B ~

System.Directory ^ A:* ~ B:* ~ 
System.CopyFiles SYS:Oberon.Text => A:Oberon.Text ~
System.CopyFiles A:Oberon.Text => B:Coolio.Text ~
System.CopyFiles SYS:Apps1.Arc => A:Apps1.Arc ~
System.DeleteFiles SYS:Coolio.Text ~

