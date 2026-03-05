(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSBoot; (* pjm *)

(*
Generic boot module.  Mounts configured file systems and then executes a configured command.

Config strings:
 BootVol# = prefix [hash] [cache] alias [par] . (* # is empty or "1".."9" *)
 alias = gen gen . (* defines a volume and file system generator *)
 gen = mod "." cmd .
 
Examples:
 BootVol="SYS 500 1000 NatFS IDE0#2"
 BootVol1="RAM RamFS -50 2048"
 
 NatFS="OFSDiskVolumes.New OFSN2KFiles.NewFS"
 AosFS="OFSDiskVolumes.New OFSAosFiles.NewFS"
 RamFS="OFSRAMVolumes.New OFSN2KFiles.NewFS"
 ISOFS="OFSISO9660Volumes.New OFSISO9660Files.NewFS"
 DosBasedFS="OFSDosBasedVolumes.New OFSN2KFiles.NewFS"
*)

IMPORT Kernel, OFS, Modules, OFSCacheVolumes;

CONST
 DefaultSystem = "System.Init";

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
  Kernel.WriteString("OFSBoot: "); Kernel.WriteString(Modules.resMsg); Kernel.WriteLn
 END;
 RETURN c # NIL
END Call;

PROCEDURE StrToInt(VAR i: LONGINT;  VAR s: ARRAY OF CHAR): LONGINT;
VAR vd, vh, sgn, d: LONGINT;  hex: BOOLEAN;
BEGIN
 vd := 0; vh := 0; hex := FALSE;
 IF s[i] = "-" THEN sgn := -1; INC(i) ELSE sgn := 1 END;
 LOOP
  IF (s[i] >= "0") & (s[i] <= "9") THEN d := ORD(s[i])-ORD("0")
  ELSIF (CAP(s[i]) >= "A") & (CAP(s[i]) <= "F") THEN d := ORD(CAP(s[i]))-ORD("A")+10; hex := TRUE
  ELSE EXIT
  END;
  vd := 10*vd + d;  vh := 16*vh + d;
  INC(i)
 END;
 IF CAP(s[i]) = "H" THEN hex := TRUE; INC(i) END; (* optional H *)
 IF hex THEN vd := vh END;
 RETURN sgn * vd
END StrToInt;

PROCEDURE GetString(VAR i: LONGINT; VAR r, s: ARRAY OF CHAR): BOOLEAN;
VAR j: LONGINT;
BEGIN
 WHILE r[i] = " " DO INC(i) END;
 j := 0; WHILE r[i] > " " DO s[j] := r[i]; INC(j); INC(i) END;
 s[j] := 0X;
 RETURN j # 0
END GetString;

PROCEDURE GetInt(VAR i: LONGINT; VAR r: ARRAY OF CHAR; VAR x: LONGINT): BOOLEAN;
VAR ok: BOOLEAN;
BEGIN
 ok := FALSE; x := 0;
 WHILE r[i] = " " DO INC(i) END;
 IF (r[i] >= "0") & (r[i] <= "9") THEN
  x := StrToInt(i, r); ok := TRUE
 END;
 RETURN ok
END GetInt;

PROCEDURE Error(VAR config, val: ARRAY OF CHAR; i: LONGINT);
VAR j: LONGINT; s: ARRAY 32 OF CHAR;
BEGIN
 s := "OFSBoot: Bad ";
 Kernel.WriteString(s);
 j := 0; WHILE s[j] # 0X DO INC(j) END; INC(i, j);
 Kernel.WriteString(config);
 j := 0; WHILE config[j] # 0X DO INC(j) END; INC(i, j);
 Kernel.WriteChar("="); Kernel.WriteChar(22X); INC(i, 2);
 Kernel.WriteString(val); Kernel.WriteChar(22X); Kernel.WriteLn;
 WHILE i > 0 DO Kernel.WriteChar(" "); DEC(i) END;
 Kernel.WriteChar("^"); Kernel.WriteLn
END Error;

PROCEDURE OpenVolume(config: ARRAY OF CHAR; first: BOOLEAN);
VAR
 i, j, hashsize, cachesize: LONGINT; cache: OFSCacheVolumes.Volume;
 prefix, alias: OFS.Prefix; gen: ARRAY 64 OF CHAR; s: ARRAY 256 OF CHAR;
BEGIN
 Kernel.GetConfig(config, s); (* s = prefix [hash] [cache] alias [par] . *)
 IF s = "" THEN
  IF first THEN Kernel.WriteString("OFSBoot: No BootVol set!"); Kernel.WriteLn END;
  RETURN
 END;
 i := 0;
 IF ~GetString(i, s, prefix) THEN Error(config, s, i); RETURN END;
 IF ~GetInt(i, s, hashsize) THEN hashsize := 0 END;
 IF ~GetInt(i, s, cachesize) THEN cachesize := hashsize END;
 IF ~GetString(i, s, alias) THEN Error(config, s, i); RETURN END;
  (* set parameter string *)
 IF s[i] = " " THEN INC(i) END;
 j := 0; WHILE s[i] # 0X DO s[j] := s[i]; INC(i); INC(j) END;
 s[j] := 0X; OFS.SetPar(s);
  (* call volume generator *)
 Kernel.GetConfig(alias, s); (* s = gen gen . ; gen = mod "." cmd . *)
 i := 0; OFS.NewVol := NIL;
 IF ~GetString(i, s, gen) THEN Error(alias, s, i); RETURN END;
 IF Call(gen, FALSE) & (OFS.NewVol # NIL) THEN
  INCL(OFS.NewVol.flags, OFS.Boot);
  IF cachesize # 0 THEN (* initialize cache *)
   IF cachesize >= 1000 THEN hashsize := cachesize DIV 5 ELSE hashsize := cachesize END;
   NEW(cache); OFSCacheVolumes.Init(cache, OFS.NewVol, hashsize, cachesize);
   OFS.NewVol := cache
  END;
   (* call file system generator *)
  OFS.SetPar(prefix);
  IF GetString(i, s, gen) THEN
   IF Call(gen, FALSE) THEN OFS.NewVol := NIL END
  ELSE
   Error(alias, s, i)
  END
 END;
 IF OFS.This(prefix) = NIL THEN
  Kernel.WriteString("OFSBoot: Mount failed on "); Kernel.WriteString(config); Kernel.WriteLn;
  IF OFS.NewVol # NIL THEN
   OFS.NewVol.Finalize(OFS.NewVol); OFS.NewVol := NIL (* unmount volume *)
  END
 END
END OpenVolume;

PROCEDURE OpenVolumes;
VAR config: ARRAY 16 OF CHAR; i: LONGINT;
BEGIN
 config := "BootVol";
 OpenVolume(config, TRUE);
 FOR i := 1 TO 9 DO
  config[7] := CHR(ORD("0") + i); config[8] := 0X;
  OpenVolume(config, FALSE)
 END
END OpenVolumes;

PROCEDURE BootSystem;
VAR s: ARRAY 32 OF CHAR;
BEGIN
 Kernel.GetConfig("BootSystem", s);
 IF s = "" THEN s := DefaultSystem END;
 IF Call(s, TRUE) THEN (* ignore *) END (* typically call will not return *)
END BootSystem;

BEGIN
 OpenVolumes;
 BootSystem
END OFSBoot.
