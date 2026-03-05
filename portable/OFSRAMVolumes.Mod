(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSRAMVolumes; (* pjm *)

(* OFS.Volume implementation in ram. *)

IMPORT SYSTEM, Kernel, OFS;

CONST
 DirMark = 9B1EA38DH; (* for NatFS and AosFS *)
 
TYPE
 Volume* = POINTER TO RECORD (OFS.Volume)
  data: POINTER TO ARRAY OF POINTER TO ARRAY OF CHAR;
 END;

VAR
 count: LONGINT;
 
(** Get block from adr [1..size] of volume vol *)
PROCEDURE GetBlock*(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR i: LONGINT;
BEGIN
 WITH vol: Volume DO
  IF (adr < 1) OR (adr > vol.size) THEN SYSTEM.HALT(15) END;
  ASSERT(LEN(blk) >= vol.blockSize);
  IF vol.data[adr-1] # NIL THEN
   SYSTEM.MOVE(SYSTEM.ADR(vol.data[adr-1]^[0]), SYSTEM.ADR(blk[0]), vol.blockSize)
  ELSE
   FOR i := 0 TO vol.blockSize-1 DO blk[i] := 0X END
  END
 END
END GetBlock;

(** Put block to adr [1..size] of volume vol *)
PROCEDURE PutBlock*(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
BEGIN
 WITH vol: Volume DO
  IF (adr < 1) OR (adr > vol.size) THEN SYSTEM.HALT(15) END;
  ASSERT(LEN(blk) >= vol.blockSize);
  IF vol.data[adr-1] = NIL THEN NEW(vol.data[adr-1], vol.blockSize) END;
  SYSTEM.MOVE(SYSTEM.ADR(blk[0]), SYSTEM.ADR(vol.data[adr-1]^[0]), vol.blockSize)
 END
END PutBlock;

PROCEDURE Finalize*(vol: OFS.Volume);
BEGIN
 WITH vol: Volume DO
  vol.data := NIL; OFS.FinalizeVol(vol)
 END
END Finalize;

(* Fetch integer parameter passed in OFS.Par *)
PROCEDURE FetchInt(VAR x: LONGINT);
VAR sgn: LONGINT; ch: CHAR;
BEGIN
 x := 0;
 OFS.ReadPar(ch);
 WHILE ch = " " DO OFS.ReadPar(ch) END;
 IF ch = "-" THEN sgn := -1; OFS.ReadPar(ch) ELSE sgn := 1 END;
 WHILE (ch >= "0") & (ch <= "9") & (x < MAX(LONGINT) DIV 10) DO
  x := x*10 + (ORD(ch) - ORD("0"));
  OFS.ReadPar(ch)
 END;
 x := sgn*x
END FetchInt;

(** Generate a new ram volume object. OFS.Par: size blocksize .  If size < 0, use as percentage of free memory. *)
PROCEDURE New*;
VAR vol: Volume; size, vbs: LONGINT;
BEGIN
 OFS.NewVol := NIL;
 FetchInt(size); FetchInt(vbs);
 IF (size # 0) & (vbs > 0) THEN
  IF size < 0 THEN (* use as percentage of free memory *)
   size := Kernel.LargestAvailable() DIV vbs * (-size) DIV 100
  END;
  NEW(vol); NEW(vol.data, size);
  NEW(vol.data[0], vbs); (* hack: pre-format with empty NatFS/AosFS *)
  SYSTEM.PUT(SYSTEM.ADR(vol.data[0]^[0]), DirMark);
  vol.name := "RAM"; OFS.AppendInt(count, vol.name); INC(count);
  vol.blockSize := vbs; vol.size := size; vol.flags := {};
  vol.AllocBlock := OFS.AllocBlock; vol.FreeBlock := OFS.FreeBlock;
  vol.MarkBlock := OFS.MarkBlock; vol.Marked := OFS.Marked;
  vol.Available := OFS.Available;
  vol.GetBlock := GetBlock; vol.PutBlock := PutBlock;
  vol.Sync := OFS.Sync; vol.Finalize := Finalize;
  OFS.InitVol(vol);
  OFS.NewVol := vol; OFS.SetPar("")
 ELSE
  OFS.SetPar("OFSRAMVolumes: bad parameters")
 END
END New;

(* Clean up when module freed. *)
PROCEDURE Cleanup;
VAR fs: OFS.FileSystem;
BEGIN
 IF Kernel.shutdown = 0 THEN
  REPEAT (* unmount all file systems using our volume *)
   fs := OFS.First(); (* look for fs to unmount *)
   WHILE (fs # NIL) & ((fs.vol = NIL) OR ~(fs.vol IS Volume)) DO
    fs := OFS.Next(fs)
   END;
   IF fs # NIL THEN OFS.Remove(fs) END
  UNTIL fs = NIL
 END
END Cleanup;

BEGIN
 count := 0;
 Kernel.InstallTermHandler(Cleanup)
END OFSRAMVolumes.
