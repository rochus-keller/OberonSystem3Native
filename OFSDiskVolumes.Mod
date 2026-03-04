(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSDiskVolumes; (* pjm *)

(* OFS.Volume implementation based on Disks. *)

IMPORT SYSTEM, Kernel, Disks, OFS;

CONST
 Header = "OFSDiskVolumes: ";
 
 BS = 512; (* supported device block size *)
 CDBS = 2048; (* cd device block size *)
 
 FSID = 21534F41H; FSVer = 1; AosSS = 4096;
 NSS = 2048;
 
TYPE
 Volume* = POINTER TO RECORD (OFS.Volume)
  dev: Disks.Device;
  startfs: LONGINT (* file system start offset on device in terms of BS-byte sectors *)
 END;

 DataBlock = ARRAY MAX(LONGINT) OF CHAR;
 
VAR
 cdid: ARRAY 32 OF CHAR;

(** Get block from adr [1..size] of volume vol *)
PROCEDURE GetBlock*(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR res, dadr: LONGINT;  dev: Disks.Device;
BEGIN
 WITH vol: Volume DO
  IF (adr < 1) OR (adr > vol.size) THEN SYSTEM.HALT(15) END;
  dev := vol.dev;
  ASSERT(vol.startfs > 0); (* startfs initialized *)
  ASSERT(LEN(blk) >= vol.blockSize);
  dadr := vol.startfs + (adr-1) * (vol.blockSize DIV BS); (* transfer position in terms of BS-sized blocks *)
  IF vol.dev.blockSize = BS THEN
   dev.transfer(dev, Disks.Read, dadr, vol.blockSize DIV BS, SYSTEM.VAL(DataBlock, blk), 0, res)
  ELSE
   ASSERT(vol.dev.blockSize = CDBS);
   ASSERT(dadr MOD (CDBS DIV BS) = 0); (* volume blocks must be aligned on device blocks *)
   ASSERT(vol.blockSize MOD CDBS = 0); (* volume blocks must be multiple of device blocks *)
   dev.transfer(dev, Disks.Read, dadr DIV (CDBS DIV BS), vol.blockSize DIV CDBS, SYSTEM.VAL(DataBlock, blk), 0, res)
  END;
  IF res # Disks.Ok THEN SYSTEM.HALT(17) END
 END
END GetBlock;

(** Put block to adr [1..size] of volume vol *)
PROCEDURE PutBlock*(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR res, dadr: LONGINT;  dev: Disks.Device;
BEGIN
 WITH vol: Volume DO
  IF (adr < 1) OR (adr > vol.size) THEN SYSTEM.HALT(15) END;
  dev := vol.dev;
  ASSERT(vol.startfs > 0); (* startfs initialized *)
  ASSERT(LEN(blk) >= vol.blockSize);
  dadr := vol.startfs + (adr-1) * (vol.blockSize DIV BS); (* transfer position in terms of BS-sized blocks *)
  IF vol.dev.blockSize = BS THEN
   dev.transfer(dev, Disks.Write, dadr, vol.blockSize DIV BS, SYSTEM.VAL(DataBlock, blk), 0, res)
  ELSE
   ASSERT(vol.dev.blockSize = CDBS);
   ASSERT(dadr MOD (CDBS DIV BS) = 0); (* volume blocks must be aligned on device blocks *)
   ASSERT(vol.blockSize MOD CDBS = 0); (* volume blocks must be multiple of device blocks *)
   dev.transfer(dev, Disks.Read, dadr DIV (CDBS DIV BS), vol.blockSize DIV CDBS, SYSTEM.VAL(DataBlock, blk), 0, res)
  END;
  IF res # Disks.Ok THEN SYSTEM.HALT(17) END
 END
END PutBlock;

(** Finalize a volume and close its device. *)
PROCEDURE Finalize*(vol: OFS.Volume);
VAR res, i, j: LONGINT;  ptable: Disks.PartitionTable;
BEGIN
 WITH vol: Volume DO
  i := 0;  j := -1;  ptable := vol.dev.table;
  WHILE i # LEN(ptable) DO
   IF (vol.startfs > ptable[i].start) & (vol.startfs < ptable[i].start + ptable[i].size) THEN
    j := i
   END;
   INC(i)
  END;
  IF j # -1 THEN
   ASSERT(Disks.Mounted IN ptable[j].flags);
   EXCL(ptable[j].flags, Disks.Mounted)
  END;
  Disks.Close(vol.dev, res); (* ignore res *)
  vol.dev := NIL; OFS.FinalizeVol(vol)
 END
END Finalize;

PROCEDURE Get4(VAR b: ARRAY OF CHAR; i: LONGINT): LONGINT;
BEGIN
 RETURN ORD(b[i]) + ASH(ORD(b[i+1]), 8) + ASH(ORD(b[i+2]), 16) + ASH(ORD(b[i+3]), 24)
END Get4;

(* Get number of reserved disk blocks and size of file system in disk blocks *)
PROCEDURE GetOberonFS(dev: Disks.Device;  pstart, psize: LONGINT;  VAR reserved, size, vbs, res: LONGINT);
VAR i, bc, fsofs: LONGINT; b: ARRAY CDBS OF CHAR;
BEGIN
 reserved := 0; size := 0;  vbs := 0; fsofs := 0;
 IF (dev.blockSize = BS) & (psize > 0) THEN
  dev.transfer(dev, Disks.Read, pstart, 1, b, 0, res) (* read boot block of partition/disk *)
 ELSIF (dev.blockSize = CDBS) & (psize > 17) THEN
  (* typically pstart = 0 *)
  dev.transfer(dev, Disks.Read, pstart + 17, 1, b, 0, res); (* read El Torito boot record *)
  IF res = Disks.Ok THEN
   bc := Get4(b, 47H); (* boot catalog location *)
   i := 0; WHILE (i < 20H) & (b[i] = cdid[i]) DO INC(i) END;
   IF (i = 20H) & (bc > 0) & (bc < psize) THEN
    dev.transfer(dev, Disks.Read, pstart + bc, 1, b, 0, res); (* read boot catalog *)
    IF (b[0] = 1X) & (b[1EH] = 55X) & (b[1FH] = 0AAX) THEN (* validation entry ok (skip checksum) *)
     fsofs := Get4(b, 20H+8); (* start of virtual disk *)
     IF (fsofs > 0) & (fsofs < psize) THEN
      dev.transfer(dev, Disks.Read, pstart + fsofs, 1, b, 0, res); (* read boot block of virtual disk *)
      fsofs := pstart + fsofs * (CDBS DIV BS) (* convert to 512-byte block address *)
     ELSE
      res := 3 (* not bootable CD *)
     END
    ELSE
     res := 3 (* not bootable CD *)
    END
   ELSE
    res := 3 (* not bootable CD *)
   END
  END
 ELSE
  res := 2 (* unsupported device block size *)
 END;
 IF res = Disks.Ok THEN (* check boot sector *)
  b[0] := "x"; b[1] := "x"; b[2] := "x"; b[9] := 0X;
  IF (b[510] = 55X) & (b[511] = 0AAX) THEN
   IF (Get4(b, 1F8H) = FSID) & (b[1FCH] = CHR(FSVer)) & (ASH(1, ORD(b[1FDH])) = AosSS) THEN (* Aos boot block id found *)
    vbs := AosSS;
    reserved := fsofs + Get4(b, 1F0H);
    size := Get4(b, 1F4H) * (vbs DIV BS);
    ASSERT((reserved + size) DIV (dev.blockSize DIV BS) <= psize)
   ELSIF b = "xxxOBERON" THEN (* Oberon boot block id found *)
    vbs := NSS;
    reserved := ORD(b[0EH]) + 256*LONG(ORD(b[0FH])); (* reserved *)
    size := ORD(b[13H]) + 256*LONG(ORD(b[14H])); (* small size *)
    IF size = 0 THEN size := Get4(b, 20H) END; (* large size *)
    IF size > psize * (dev.blockSize DIV BS) THEN (* limit to partition/disk size *)
     size := psize * (dev.blockSize DIV BS)
    END;
    DEC(size, reserved);
    INC(reserved, fsofs)
   ELSE
    res := 1 (* unknown file system *)
   END
  ELSE
   res := 1 (* boot block id not found (unformatted?) *)
  END
 END
END GetOberonFS;

PROCEDURE InitVol(vol: Volume; reserved, size, vbs, part: LONGINT;  ptable: Disks.PartitionTable);
BEGIN
 COPY(vol.dev.name, vol.name);  OFS.AppendStr("#", vol.name);  OFS.AppendInt(part, vol.name);
 ASSERT(vbs MOD BS = 0);
 vol.blockSize := vbs;
 vol.size := size DIV (vbs DIV BS);
 vol.startfs := ptable[part].start+reserved;
 vol.flags := {};
 IF Disks.ReadOnly IN vol.dev.flags THEN INCL(vol.flags, OFS.ReadOnly) END;
 IF Disks.Removable IN vol.dev.flags THEN INCL(vol.flags, OFS.Removable) END;
 vol.AllocBlock := OFS.AllocBlock;  vol.FreeBlock := OFS.FreeBlock;
 vol.MarkBlock := OFS.MarkBlock;  vol.Marked := OFS.Marked;
 vol.Available := OFS.Available;
 vol.GetBlock := GetBlock;  vol.PutBlock := PutBlock;
 vol.Sync := OFS.Sync; vol.Finalize := Finalize;
 INCL(ptable[part].flags, Disks.Mounted)
END InitVol;

(* Fetch positive integer parameter passed in OFS.Par *)

PROCEDURE ScanInt(VAR ch: CHAR; VAR x: LONGINT);
BEGIN
 x := 0;
 WHILE ch = " " DO OFS.ReadPar(ch) END;
 WHILE (ch >= "0") & (ch <= "9") & (x < MAX(LONGINT) DIV 10) DO
  x := x*10 + (ORD(ch) - ORD("0"));
  OFS.ReadPar(ch)
 END
END ScanInt;

PROCEDURE GetParam(VAR name: ARRAY OF CHAR; VAR part: LONGINT; VAR readonly: BOOLEAN);
VAR i: LONGINT; ch: CHAR;
BEGIN
 readonly := FALSE; part := 0;
 REPEAT OFS.ReadPar(ch) UNTIL ch # " ";
 i := 0;
 WHILE (ch > " ") & (ch # "#") & (ch # ",") DO name[i] := ch; INC(i); OFS.ReadPar(ch) END;
 name[i] := 0X;
 IF (ch = "#") OR (ch = " ") THEN OFS.ReadPar(ch); ScanInt(ch, part) END;
 IF ch = "," THEN
  REPEAT
   OFS.ReadPar(ch);
   IF ch = "R" THEN readonly := TRUE END
  UNTIL ch <= " "
 END
END GetParam;

(* Try to open the specified volume.  Sets OFS.NewVol # NIL on success. *)

PROCEDURE TryOpen(dev: Disks.Device; part, dbs: LONGINT; readonly: BOOLEAN);
VAR vol: Volume; reserved, size, vbs, res: LONGINT; ptable: Disks.PartitionTable;
BEGIN
 Kernel.WriteString(Header); Kernel.WriteString(dev.name);
 Disks.Open(dev, res);
 IF res = Disks.Ok THEN
  ptable := dev.table;
  IF ((LEN(ptable) = 1) & (part = 0)) OR ((part > 0) & (part < LEN(ptable))) THEN
   IF (dbs = -1) OR (dev.blockSize = dbs) THEN
    Kernel.WriteChar("#"); Kernel.WriteInt(part, 1);
    IF ~(Disks.Mounted IN ptable[part].flags) THEN
     GetOberonFS(dev, ptable[part].start, ptable[part].size, reserved, size, vbs, res);
     IF (res = Disks.Ok) & (size > 0) & (vbs MOD dev.blockSize = 0) THEN
      NEW(vol); vol.dev := dev;
      InitVol(vol, reserved, size, vbs, part, ptable);
      IF readonly OR (Disks.ReadOnly IN dev.flags) THEN INCL(vol.flags, OFS.ReadOnly) END;
      OFS.InitVol(vol);
      OFS.NewVol := vol
     ELSE
      CASE res OF
       1: Kernel.WriteString(" partition not formatted")
       |2: Kernel.WriteString(" bad block size")
       ELSE Kernel.WriteString(" boot block error "); Kernel.WriteInt(res, 1);
       Kernel.WriteString(" reserved="); Kernel.WriteInt(reserved, 1);
       Kernel.WriteString(" size="); Kernel.WriteInt(size, 1);
       Kernel.WriteString(" vbs="); Kernel.WriteInt(vbs, 1);
       Kernel.WriteString(" start="); Kernel.WriteInt(ptable[part].start, 1)
      END
     END
    ELSE
     Kernel.WriteString(" blocksize="); Kernel.WriteInt(dev.blockSize, 1)
    END
   ELSE
    Kernel.WriteString(" wrong block size")
   END
  ELSE
   Kernel.WriteString(" invalid partition")
  END;
  IF OFS.NewVol = NIL THEN Disks.Close(dev, res) END (* close again - ignore res *)
 ELSE
  Kernel.WriteString(" error ");  Kernel.WriteInt(res, 1)
 END
END TryOpen;

(** Generate a new disk volume object. OFS.Par: device ["#" part] [",R"] *)
PROCEDURE New*;
VAR
 part, i: LONGINT; table: Disks.DeviceTable; readonly, retry: BOOLEAN;
 name: Disks.Name; s: ARRAY 64 OF CHAR;
BEGIN
 OFS.NewVol := NIL; retry := FALSE;
 GetParam(name, part, readonly);
 Disks.GetRegistered(table);
 Kernel.SetLogMark;
 IF table # NIL THEN
  IF name # "" THEN
   i := 0; WHILE (i # LEN(table)) & (table[i].name # name) DO INC(i) END;
   IF i # LEN(table) THEN
    TryOpen(table[i], part, -1, readonly)
   ELSE
    Kernel.WriteString(Header); Kernel.WriteString(name); Kernel.WriteString(" not found")
   END
  ELSE
   i := 0;
   LOOP
    TryOpen(table[i], part, CDBS, readonly);
    INC(i);
    IF (OFS.NewVol # NIL) OR (i >= LEN(table)) THEN EXIT END;
    Kernel.WriteLn; Kernel.SetLogMark
   END
  END
 ELSE
  Kernel.WriteString(Header); Kernel.WriteString("no devices")
 END;
 Kernel.WriteLn;
 Kernel.GetMarkedLog(s); OFS.SetPar(s)
END New;

BEGIN
 Kernel.Hello("OFSDiskVolumes");
 cdid := "?CD001?EL TORITO SPECIFICATION?";
 cdid[0] := 0X; cdid[6] := 1X; cdid[30] := 0X; cdid[31] := 0X
END OFSDiskVolumes.

(*
to do:
o add search option which will search through all devices for suitable partition
*)

System.Free OFSDiskVolumes ~

OFSTools.Mount TEST TestFS IDE2#02 ~
OFSTools.Mount TEST TestFS #0 ~
OFSTools.Unmount TEST
