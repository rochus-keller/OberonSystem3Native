(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSFileVolumes; (* pjm *)

(* OFS.Volume implementation that be used to mount DOS-based Native Oberon disk files. *)

IMPORT SYSTEM, Kernel, OFS, Files;

CONST
 VBS = 4096;

TYPE
 Volume* = POINTER TO RECORD (OFS.Volume)
  f: Files.File
 END;

PROCEDURE GetBlock(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR r: Files.Rider; pos: LONGINT;
BEGIN
 WITH vol: Volume DO
  IF (adr < 1) OR (adr > vol.size) THEN SYSTEM.HALT(15) END;
  pos := (adr-1)*vol.blockSize;
  ASSERT(pos + vol.blockSize <= Files.Length(vol.f));
  Files.Set(r, vol.f, pos);
  Files.ReadBytes(r, blk, vol.blockSize);
  IF r.res # 0 THEN SYSTEM.HALT(17) END
 END
END GetBlock;

PROCEDURE PutBlock(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR r: Files.Rider; pos: LONGINT;
BEGIN
 WITH vol: Volume DO
  IF (adr < 1) OR (adr > vol.size) THEN SYSTEM.HALT(15) END;
  pos := (adr-1)*vol.blockSize;
  ASSERT(pos + vol.blockSize <= Files.Length(vol.f));
  Files.Set(r, vol.f, pos);
  Files.WriteBytes(r, blk, vol.blockSize);
  IF r.res # 0 THEN SYSTEM.HALT(17) END
 END
END PutBlock;

PROCEDURE Finalize(vol: OFS.Volume);
BEGIN
 WITH vol: Volume DO
  Files.Close(vol.f); vol.f := NIL; OFS.FinalizeVol(vol)
 END
END Finalize;

PROCEDURE InitVol(vol: Volume; f: Files.File; size, vbs: LONGINT);
BEGIN
 Files.GetName(f, vol.name); vol.f := f;
 ASSERT(Files.Length(f) MOD vbs = 0);
 vol.blockSize := vbs; vol.size := size; vol.flags := {OFS.Removable};
 vol.AllocBlock := OFS.AllocBlock; vol.FreeBlock := OFS.FreeBlock;
 vol.MarkBlock := OFS.MarkBlock; vol.Marked := OFS.Marked;
 vol.Available := OFS.Available;
 vol.GetBlock := GetBlock; vol.PutBlock := PutBlock;
 vol.Sync := OFS.Sync;
 vol.Finalize := Finalize
END InitVol;

(** Generate a new file volume object. OFS.Par: file *)
PROCEDURE New*;
VAR i: LONGINT; vol: Volume; f: Files.File; name: OFS.FileName; ch: CHAR;
BEGIN
 OFS.NewVol := NIL;
 REPEAT OFS.ReadPar(ch) UNTIL ch # " ";
 i := 0;
 WHILE ch > " " DO name[i] := ch; INC(i); OFS.ReadPar(ch) END;
 name[i] := 0X;
 f := Files.Old(name);
 IF f # NIL THEN
  IF (Files.Length(f) MOD VBS = 0) OR (Files.Length(f) < VBS) THEN
   NEW(vol); InitVol(vol, f, Files.Length(f) DIV VBS, VBS);
   OFS.InitVol(vol);
   OFS.NewVol := vol;
   OFS.SetPar("")
  ELSE
   OFS.SetPar("Bad file size")
  END
 ELSE
  OFS.SetPar("Bad file name")
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
 Kernel.InstallTermHandler(Cleanup)
END OFSFileVolumes.

OFSTools.Watch

OFSTools.Mount TEST FileFS Temp.dsk ~
OFSTools.Unmount TEST

System.Free OFSTools OFSFileVolumes ~
