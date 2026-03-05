(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSBoot0; (* pjm *)

(* Boot file system loader for Oberon-0 *)

IMPORT SYSTEM, Kernel, OFS, Modules, OFSDiskVolumes, OFSCacheVolumes, OFSRAMVolumes, OFSN2KFiles, Files, Zip;

CONST
 RAMPrefix = "RAM";
 SRCPrefix = "SRC";
 Archive = "Oberon0.zip";
 BootVol0 = "Diskette0,R";
 RamDiskSize = "-50"; (* positive number for number of blocks, negative number for percentage of free memory *)
 
 CacheSize = 1440 DIV 2; (* enough for a full diskette *)
 HashSize = CacheSize DIV 2;
 
 Trace = FALSE;
 
VAR
 tracecol, tracetime: LONGINT;

PROCEDURE Call(cmd: ARRAY OF CHAR; protect: BOOLEAN): BOOLEAN;
VAR i, j: LONGINT; m: Modules.Module; c: Modules.Command;
BEGIN
 m := NIL; c := NIL;
 i := 0; WHILE (cmd[i] # ".") & (cmd[i] # 0X) DO INC(i) END;
 IF cmd[i] = "." THEN cmd[i] := 0X; m := Modules.ThisMod(cmd) END;
 IF m # NIL THEN
  IF protect THEN INC(m.refcnt) END; (* disallow unloading of the module *)
  j := 0; INC(i);
  WHILE cmd[i] # 0X DO cmd[j] := cmd[i]; INC(i); INC(j) END;
  cmd[j] := 0X;
  c := Modules.ThisCommand(m, cmd);
  IF c # NIL THEN c() END
 END;
 IF Modules.res # 0 THEN
  Kernel.WriteString("OFSBoot0: "); Kernel.WriteString(Modules.resMsg); Kernel.WriteLn
 END;
 RETURN c # NIL
END Call;

PROCEDURE GenName(prefix, buf: ARRAY OF CHAR; VAR fname: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 i := 0; WHILE prefix[i] # 0X DO fname[i] := prefix[i]; INC(i) END;
 fname[i] := ":"; INC(i);
 j := 0; WHILE buf[j] # 0X DO fname[i] := buf[j]; INC(i); INC(j) END;
 fname[i] := 0X
END GenName;

PROCEDURE TraceBorder;
VAR ch: CHAR;
BEGIN
 IF tracecol >= 0 THEN
  IF Kernel.GetTimer() - tracetime >= Kernel.TimeUnit DIV 4 THEN
   tracetime := Kernel.GetTimer();
   tracecol := (tracecol+1) MOD 16;
   SYSTEM.PORTIN(3DAH, ch);
   SYSTEM.PORTOUT(3C0H, 11X);
   SYSTEM.PORTOUT(3C0H, CHR(tracecol));
   SYSTEM.PORTOUT(3C0H, 20X)
  END
 END
END TraceBorder;

PROCEDURE UnpackZip(name, prefix: ARRAY OF CHAR; VAR res: LONGINT);
VAR a: Zip.Archive; e: Zip.Entry; f: Files.File; r: Files.Rider; pname: ARRAY 64 OF CHAR;
BEGIN
 a := Zip.OpenArchive(name, res);
 IF res = Zip.Ok THEN
  e := Zip.FirstEntry(a);
  WHILE (e # NIL) & (res = Zip.Ok) DO
   TraceBorder;
   GenName(prefix, e.name, pname);
   f := Files.New(pname);
   Files.Set(r, f, 0);
   Zip.ExtractEntry(a, e, r, res);
   IF Trace THEN
    Kernel.WriteString(e.name); Kernel.WriteString(" => ");
    Kernel.WriteString(pname); Kernel.WriteChar(" "); Kernel.WriteInt(res, 1); 
    Kernel.WriteLn
   END;
   IF res = Zip.Ok THEN Files.Register(f); e := Zip.NextEntry(e) END
  END
 END
END UnpackZip;

PROCEDURE OpenBootVolume;
VAR fs: OFS.FileSystem; res: LONGINT; cache: OFSCacheVolumes.Volume; s: ARRAY 64 OF CHAR;
BEGIN
 Kernel.GetConfig("TraceBoot", s);
 IF s[0] = "0" THEN tracecol := -1 ELSE tracecol := 0 END;
 tracetime := Kernel.GetTimer();
 Kernel.GetConfig("RamDiskSize", s);
 IF s = "" THEN s := RamDiskSize END;
 OFS.AppendStr(" 2048", s); (* block size *)
 OFS.SetPar(s);
 OFSRAMVolumes.New;
 ASSERT(OFS.NewVol # NIL);
 OFS.SetPar(RAMPrefix);
 OFSN2KFiles.NewFS;
 fs := OFS.This(RAMPrefix);
 ASSERT(fs # NIL);
 IF fs.vol # NIL THEN INCL(fs.vol.flags, OFS.Boot) END;

 Kernel.GetConfig("BootVol0", s);
 IF s = "" THEN s := BootVol0 END;
 OFS.SetPar(s);
 OFSDiskVolumes.New;
 TraceBorder;
 ASSERT(OFS.NewVol # NIL);
 OFS.SetPar(SRCPrefix);
 OFSN2KFiles.NewFS;
 fs := OFS.This(SRCPrefix);
 ASSERT(fs # NIL);
 IF fs.vol # NIL THEN INCL(fs.vol.flags, OFS.Boot) END;
 
 Kernel.GetConfig("BootVolCache", s);
 IF (s # "0") & (fs.vol # NIL) THEN
  NEW(cache); OFSCacheVolumes.Init(cache, fs.vol, HashSize, CacheSize);
  fs.vol := cache
 END;
 
 Kernel.GetConfig("Archive", s);
 IF s = "" THEN s := Archive END;
 UnpackZip(s, RAMPrefix, res);
 IF res # 0 THEN
  Kernel.WriteString(s); Kernel.WriteString(" unpack error ");
  Kernel.WriteInt(res, 1); Kernel.WriteLn
 END;
 
 OFS.Remove(fs)
END OpenBootVolume;

BEGIN
 OpenBootVolume;
 IF Call("System.Init", TRUE) THEN (* ignore *) END (* typically call will not return *)
END OFSBoot0.
