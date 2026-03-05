(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE FileSystem; (* pjm *)

IMPORT Modules, Texts, Oberon, In, Out, OFS, OFSCacheVolumes, Files := (*OFS*)Files, NatFiles := Files;

VAR
 W: Texts.Writer;
 
PROCEDURE ExpandAlias(VAR alias, genvol, genfs: ARRAY OF CHAR);
VAR t: ARRAY 64 OF CHAR; s: Texts.Scanner; i, j: LONGINT;
BEGIN
 genvol[0] := 0X; genfs[0] := 0X;
 t := "OFS.Alias.";
 i := 0; WHILE t[i] # 0X DO INC(i) END;
 j := 0; WHILE alias[j] # 0X DO t[i] := alias[j]; INC(i); INC(j) END;
 t[i] := 0X;
 Oberon.OpenScanner(s, t);
 IF s.class = Texts.Name THEN
  COPY(s.s, genvol); Texts.Scan(s);
  IF s.class = Texts.Name THEN
   COPY(s.s, genfs)
  END
 END
END ExpandAlias;

PROCEDURE OutErrMsg(cmd: ARRAY OF CHAR);
VAR ch: CHAR;
BEGIN
 OFS.ReadPar(ch); (* output error message *)
 IF ch < " " THEN Out.String(cmd); Out.String(" failed") END;
 WHILE ch >= " " DO Out.Char(ch); OFS.ReadPar(ch) END;
END OutErrMsg;

PROCEDURE GetSelection(VAR par: ARRAY OF CHAR);
VAR t: Texts.Text; r: Texts.Reader; beg, end, time, i: LONGINT; ch: CHAR;
BEGIN
 Oberon.GetSelection(t, beg, end, time);
 IF (time # -1) & (t # NIL) THEN
  Texts.OpenReader(r, t, beg);
  i := 0; Texts.Read(r, ch);
  WHILE (ch >= " ") & (i # LEN(par)-1) DO par[i] := ch; INC(i); Texts.Read(r, ch) END;
  par[i] := 0X
 ELSE
  In.Done := FALSE
 END
END GetSelection;

PROCEDURE Mount*; (** prefix [hashSize] [cachesize] alias (params ~ | ^ ) *)
VAR
 par, alias, genvol, genfs: ARRAY 64 OF CHAR; prefix: OFS.Prefix; res: INTEGER;
 s: Texts.Scanner; hashSize, cacheSize, i: LONGINT; cache: OFSCacheVolumes.Volume;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
 IF s.class = Texts.Name THEN COPY(s.s, prefix); Texts.Scan(s) ELSE s.class := Texts.Inval END;
 IF s.class = Texts.Int THEN hashSize := s.i; Texts.Scan(s) ELSE hashSize := 0 END;
 IF s.class = Texts.Int THEN cacheSize := s.i; Texts.Scan(s) ELSE cacheSize := hashSize END;
 IF s.class = Texts.Name THEN COPY(s.s, alias) ELSE s.class := Texts.Inval END;
 IF s.class # Texts.Inval THEN
  i := -1;
  REPEAT INC(i); Texts.Read(s, par[i]) UNTIL s.eot OR (par[i] < 20X) OR (par[i] = "~");
  par[i] := 0X;
  IF par[0] = "^" THEN GetSelection(par) END;
  ExpandAlias(alias, genvol, genfs);
  Out.String(prefix); Out.String(": ");
  IF OFS.This(prefix) # NIL THEN
   Out.String("already used")
  ELSIF (genvol[0] = 0X) OR (genfs[0] = 0X) THEN
   Out.String("unknown alias "); Out.String(alias)
  ELSE
   OFS.NewVol := NIL;  res := 0;
   IF genvol # "NIL" THEN
    OFS.SetPar(par);
    Oberon.Call(genvol, Oberon.Par, FALSE, res);
    IF res # 0 THEN
     Out.Ln;  Out.String(Modules.resMsg)
    ELSE
     IF OFS.NewVol = NIL THEN OutErrMsg(genvol); res := 1 END
    END
   END;
   IF res = 0 THEN
    IF (cacheSize # 0) & (OFS.NewVol # NIL) THEN
     NEW(cache); OFSCacheVolumes.Init(cache, OFS.NewVol, hashSize, cacheSize);
     OFS.NewVol := cache
    END;
    OFS.SetPar(prefix);
    Oberon.Call(genfs, Oberon.Par, FALSE, res);
    IF res # 0 THEN
     Out.Ln;  Out.String(Modules.resMsg)
    ELSIF OFS.This(prefix) = NIL THEN
     OutErrMsg(genfs); res := 1
    ELSE
     Out.String("mounted")
    END;
    IF (res # 0) & (OFS.NewVol # NIL) THEN
     OFS.NewVol.Finalize(OFS.NewVol) (* unmount volume *)
    END;
    OFS.NewVol := NIL
   ELSE
    (* skip *)
   END
  END;
  Out.Ln
 END
END Mount;

PROCEDURE Unmount*; (** prefix *)
VAR prefix: OFS.Prefix; fs: OFS.FileSystem; i: LONGINT;
BEGIN
 In.Open;  In.Name(prefix);
 IF In.Done THEN
  i := 0; WHILE (prefix[i] # 0X) & (prefix[i] # ":") DO INC(i) END;
  prefix[i] := 0X;
  Out.String(prefix); Out.Char(":");
  fs := OFS.This(prefix);
  IF fs # NIL THEN
   IF (fs.vol = NIL) OR ~(OFS.Boot IN fs.vol.flags) THEN
    OFS.Remove(fs);
    Out.String(" unmounted")
   ELSE
    Out.String(" can't unmount boot volume")
   END
  ELSE
   Out.String(" not found")
  END;
  Out.Ln
 END
END Unmount;

PROCEDURE InstallCache*; (** prefix hashSize cacheSize *)
VAR
 prefix: OFS.Prefix; s: Texts.Scanner; hashSize, cacheSize, i: LONGINT;
 fs: OFS.FileSystem; cache: OFSCacheVolumes.Volume;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
 IF s.class = Texts.Name THEN COPY(s.s, prefix); Texts.Scan(s) ELSE s.class := Texts.Inval END;
 IF s.class = Texts.Int THEN hashSize := s.i; Texts.Scan(s) ELSE s.class := Texts.Inval END;
 IF s.class = Texts.Int THEN cacheSize := s.i ELSE s.class := Texts.Inval END;
 IF s.class # Texts.Inval THEN
  i := 0; WHILE (prefix[i] # 0X) & (prefix[i] # ":") DO INC(i) END;
  prefix[i] := 0X;
  Out.String(prefix); Out.String(": ");
  fs := OFS.This(prefix);
  IF fs # NIL THEN
   IF ~(fs.vol IS OFSCacheVolumes.Volume) THEN
    IF hashSize > cacheSize THEN hashSize := cacheSize END;
    NEW(cache); OFSCacheVolumes.Init(cache, fs.vol, hashSize, cacheSize);
    fs.vol := cache;
    Out.Int(cacheSize, 1); Out.String(" block cache installed")
   ELSE
    Out.String("already cached!")
   END
  ELSE
   Out.String("not found")
  END;
  Out.Ln
 END
END InstallCache;

PROCEDURE RemoveCache*; (** prefix *)
VAR prefix: OFS.Prefix; s: Texts.Scanner; fs: OFS.FileSystem; i: LONGINT;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
 IF s.class = Texts.Name THEN
  COPY(s.s, prefix);
  i := 0; WHILE (prefix[i] # 0X) & (prefix[i] # ":") DO INC(i) END;
  prefix[i] := 0X;
  Out.String(prefix); Out.String(": ");
  fs := OFS.This(prefix);
  IF fs # NIL THEN
   IF fs.vol IS OFSCacheVolumes.Volume THEN
    OFSCacheVolumes.Update(fs.vol(OFSCacheVolumes.Volume));
    Out.Int(fs.vol(OFSCacheVolumes.Volume).cacheSize, 1);
    Out.String(" block cache removed");
    fs.vol := fs.vol(OFSCacheVolumes.Volume).real
   ELSE
    Out.String("not cached!")
   END
  ELSE
   Out.String("not found")
  END;
  Out.Ln
 END
END RemoveCache;

PROCEDURE SetDefault*; (** prefix *)
VAR prefix: OFS.Prefix; fs: OFS.FileSystem; i: LONGINT;
BEGIN
 In.Open;  In.Name(prefix);
 IF In.Done THEN
  i := 0; WHILE (prefix[i] # 0X) & (prefix[i] # ":") DO INC(i) END;
  prefix[i] := 0X;
  fs := OFS.This(prefix);
  IF fs # NIL THEN
   OFS.Promote(fs);
   Out.String("Path: ");
   fs := OFS.First();
   WHILE fs # NIL DO
    Out.String(fs.prefix);  Out.String(" ");
    fs := OFS.Next(fs)
   END
  ELSE
   Out.String(prefix);  Out.String(": not found")
  END;
  Out.Ln
 END
END SetDefault;

PROCEDURE ModifyName(in, prefix: ARRAY OF CHAR;  add: BOOLEAN;  VAR out: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 IF add THEN
  i := 0; WHILE prefix[i] # 0X DO out[i] := prefix[i]; INC(i) END;
  j := 0; WHILE in[j] # 0X DO out[i] := in[j]; INC(i); INC(j) END;
  out[i] := 0X
 ELSE
  i := 0; WHILE (prefix[i] # 0X) & (in[i] = prefix[i]) DO INC(i) END;
  IF prefix[i] # 0X THEN i := 0 END;
  j := 0; WHILE in[i] # 0X DO out[j] := in[i]; INC(i); INC(j) END;
  out[j] := 0X
 END
END ModifyName;

PROCEDURE *List(name: ARRAY OF CHAR;  time, date, size: LONGINT; VAR flags: SET);
BEGIN
 Texts.WriteString(W, name);
 Texts.WriteLn(W)
END List;

PROCEDURE GenCopyFiles*; (** remprefix addprefix ( "mask" | &file | { file [=> file] } ) ~ *)
VAR s: Texts.Scanner; t: Texts.Text; prefix1, prefix2: OFS.Prefix; name: OFS.FileName; flags: SET;
BEGIN
 StartScan(s);
 IF s.class IN {Texts.Name, Texts.String} THEN COPY(s.s, prefix1); Texts.Scan(s) END;
 IF s.class IN {Texts.Name, Texts.String} THEN COPY(s.s, prefix2); Texts.Scan(s) END;
 IF s.class = Texts.String THEN (* directory mask *)
  flags := {}; OFS.Enumerate(s.s, flags, List);
  NEW(t);  Texts.Open(t, "");
  Texts.Append(t, W.buf);
  Texts.OpenScanner(s, t, 0);  Texts.Scan(s)
 ELSIF (s.class = Texts.Char) & (s.c = "&") THEN
  Texts.Scan(s);
  IF s.class = Texts.Name THEN
   NEW(t);  Texts.Open(t, s.s);
   Texts.OpenScanner(s, t, 0);  Texts.Scan(s)
  END
 END;
 Texts.WriteString(W, "System.CopyFiles");  Texts.WriteLn(W);
 WHILE s.class = Texts.Name DO
  Texts.WriteString(W, "  ");  Texts.WriteString(W, s.s);  Texts.WriteString(W, " => ");
  COPY(s.s, name);
  Texts.Scan(s);
  IF (s.class = Texts.Char) & (s.c = "=") THEN
   Texts.Scan(s);
   IF (s.class = Texts.Char) & (s.c = ">") THEN
    Texts.Scan(s);
    IF s.class = Texts.Name THEN
     COPY(s.s, name);
     Texts.Scan(s)
    ELSE
     (* skip *)
    END
   ELSE
    (* skip *)
   END
  END;
  ModifyName(name, prefix1, FALSE, name);
  ModifyName(name, prefix2, TRUE, name);
  Texts.WriteString(W, name);  Texts.WriteLn(W)
 END;
 Texts.Write(W, "~");
 NEW(t);  Texts.Open(t, "");
 Texts.Append(t, W.buf);
 Oberon.OpenText("", t, 200, 200)
END GenCopyFiles;

PROCEDURE StartScan(VAR S: Texts.Scanner);
VAR beg, end, time: LONGINT;  T: Texts.Text;
BEGIN
 Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(S);
 IF (S.class = Texts.Char) & (S.c = "^") OR (S.line # 0) THEN
  Oberon.GetSelection(T, beg, end, time);
  IF time >= 0 THEN Texts.OpenScanner(S, T, beg); Texts.Scan(S) END
 END
END StartScan;

PROCEDURE CopyTo*; (** dstprefix srcprefix ( &file | { file [=> file]} ) ~ *)
CONST BufSize = 32768;
VAR
 S: Texts.Scanner;  sf: NatFiles.File;  df: Files.File;  sr: NatFiles.Rider;  dr: Files.Rider;
 sLen, dLen, i: INTEGER;  ch: CHAR;  src, dest: ARRAY 64 OF CHAR;  t: Texts.Text;
 buf: ARRAY BufSize OF CHAR;
BEGIN
 StartScan(S);
 IF ~(S.class IN {Texts.Name, Texts.String}) THEN
  Texts.WriteString(W, "Missing destination prefix");  Texts.WriteLn(W)
 ELSE
  dLen := 0;  WHILE S.s[dLen] # 0X DO  dest[dLen] := S.s[dLen];  INC(dLen)  END;
  Texts.Scan(S);
  IF ~(S.class IN {Texts.Name, Texts.String}) THEN
   Texts.WriteString(W, "Missing source prefix");  Texts.WriteLn(W)
  ELSE
   sLen := 0;  WHILE S.s[sLen] # 0X DO  src[sLen] := S.s[sLen];  INC(sLen)  END;
   Texts.Scan(S);
   IF (S.class = Texts.Char) & (S.c = "&") THEN
    Texts.Scan(S);
    IF S.class IN {Texts.Name, Texts.String} THEN
     NEW(t);  Texts.Open(t, S.s);
     Texts.OpenScanner(S, t, 0);  Texts.Scan(S)
    END
   END;
   WHILE S.class IN {Texts.Name, Texts.String} DO
    i := 0;  ch := S.s[i];
    WHILE ch # 0X DO  src[sLen+i] := ch;  dest[dLen+i] := ch;  INC(i);  ch := S.s[i]  END;
    src[sLen+i] := 0X;  dest[dLen+i] := 0X;
    Texts.WriteString(W, src);
    sf := NatFiles.Old(src);
    IF sf # NIL THEN
     Texts.Scan(S);
     IF (S.class = Texts.Char) & (S.c = "=") THEN
      Texts.Scan(S);
      IF (S.class = Texts.Char) & (S.c = ">") THEN
       Texts.Scan(S);
       IF S.class IN {Texts.Name, Texts.String} THEN
        i := 0;  ch := S.s[i];
        WHILE ch # 0X DO  dest[dLen+i] := ch;  INC(i);  ch := S.s[i]  END;
        dest[dLen+i] := 0X;
        Texts.Scan(S)
       ELSE
        (* skip *)
       END
      ELSE
       (* skip *)
      END
     END;
     Texts.WriteString(W, " => ");  Texts.WriteString(W, dest);
     df := Files.New(dest);
     IF df # NIL THEN
      Texts.WriteString(W, " copying");
      Texts.Append(Oberon.Log, W.buf);
      NatFiles.Set(sr, sf, 0);  Files.Set(dr, df, 0);
      LOOP
       NatFiles.ReadBytes(sr, buf, BufSize);
       IF sr.res = BufSize THEN EXIT END;
       Files.WriteBytes(dr, buf, BufSize - sr.res)
      END;
      Files.Register(df);
      ASSERT(Files.Length(df) = Files.Length(sf))
     ELSE
      Texts.WriteString(W, " create failed");
      S.class := Texts.Inval
     END
    ELSE
     Texts.WriteString(W, " open failed");
     S.class := Texts.Inval
    END;
    Texts.WriteLn(W)
   END
  END
 END;
 Texts.Append(Oberon.Log, W.buf)
END CopyTo;

PROCEDURE WriteK(VAR W: Texts.Writer;  k: LONGINT);
VAR suffix: CHAR;
BEGIN
 IF k < 10*1024 THEN suffix := "K"
 ELSIF k < 10*1024*1024 THEN suffix := "M"; k := k DIV 1024
 ELSE suffix := "G"; k := k DIV (1024*1024)
 END;
 Texts.WriteInt(W, k, 1);  Texts.Write(W, suffix);  Texts.Write(W, "B")
END WriteK;

PROCEDURE Watch*; (** no parameters *)
VAR free, total: LONGINT; fs: OFS.FileSystem; cache: OFSCacheVolumes.Volume;
BEGIN
 Texts.WriteString(W, "FileSystem.Watch");  Texts.WriteLn(W);
 fs := OFS.First();
 WHILE fs # NIL DO
  Texts.WriteString(W, fs.prefix);  Texts.WriteString(W, ": ");
  Texts.WriteString(W, fs.desc);
  IF fs.vol # NIL THEN
   Texts.WriteString(W, " on "); Texts.WriteString(W, fs.vol.name);
   IF OFS.ReadOnly IN fs.vol.flags THEN Texts.WriteString(W, " (read-only)") END;
   IF OFS.Removable IN fs.vol.flags THEN Texts.WriteString(W, " (removable)") END;
   IF OFS.Boot IN fs.vol.flags THEN Texts.WriteString(W, " (boot)") END;
   Texts.WriteLn(W);  Texts.Write(W, 9X);
   free := ENTIER(fs.vol.Available(fs.vol)/1024.0D0 * fs.vol.blockSize);
   total := ENTIER(fs.vol.size/1024.0D0 * fs.vol.blockSize);
   WriteK(W, free);  Texts.WriteString(W, " of ");
   WriteK(W, total);  Texts.WriteString(W, " free");
   IF fs.vol IS OFSCacheVolumes.Volume THEN
    cache := fs.vol(OFSCacheVolumes.Volume);
    Texts.WriteLn(W);  Texts.Write(W, 9X);
    WriteK(W, ENTIER(cache.cacheSize/1024.0D0 * cache.blockSize));
    Texts.WriteString(W, " cache, ");
    Texts.WriteInt(W, cache.cacheSize, 1); Texts.WriteString(W, " blocks, ");
    Texts.WriteInt(W, cache.hashSize, 1); Texts.WriteString(W, " hash entries");
    Texts.WriteLn(W);  Texts.Write(W, 9X);
    Texts.WriteInt(W, cache.getCount, 1); Texts.WriteString(W, " gets, ");
    Texts.WriteInt(W, cache.putCount, 1); Texts.WriteString(W, " puts, ");
    Texts.WriteInt(W, cache.getHitCount, 1); Texts.WriteString(W, " get hits (");
    IF cache.getCount # 0 THEN
     Texts.WriteInt(W, cache.getHitCount*100 DIV cache.getCount, 1)
    ELSE
     Texts.Write(W, "0")
    END;
    Texts.WriteString(W, "%), ");
    Texts.WriteInt(W, cache.putHitCount, 1); Texts.WriteString(W, " put hits (");
    IF cache.putCount # 0 THEN
     Texts.WriteInt(W, cache.putHitCount*100 DIV cache.putCount, 1)
    ELSE
     Texts.Write(W, "0")
    END;
    Texts.WriteString(W, "%)")
   END
  END;
  Texts.WriteLn(W);
  fs := OFS.Next(fs)
 END;
 Texts.Append(Oberon.Log, W.buf)
END Watch;

(*
(* Cross-tools *)

PROCEDURE CopyFrom*; (** srcprefix dstprefix ( &file | { file [=> file] } ) ~ *)
VAR
 S: Texts.Scanner;  sf: Files.File;  df: NatFiles.File;  sr: Files.Rider;  dr: NatFiles.Rider;
 sLen, dLen, i: INTEGER;  ch: CHAR;  src, dest: ARRAY 64 OF CHAR;  t: Texts.Text;
BEGIN
 StartScan(S);
 IF ~(S.class IN {Texts.Name, Texts.String}) THEN
  Texts.WriteString(W, "Missing source prefix");  Texts.WriteLn(W)
 ELSE
  sLen := 0;  WHILE S.s[sLen] # 0X DO  src[sLen] := S.s[sLen];  INC(sLen)  END;
  Texts.Scan(S);
  IF ~(S.class IN {Texts.Name, Texts.String}) THEN
   Texts.WriteString(W, "Missing destination prefix");  Texts.WriteLn(W)
  ELSE
   dLen := 0;  WHILE S.s[dLen] # 0X DO  dest[dLen] := S.s[dLen];  INC(dLen)  END;
   Texts.Scan(S);
   IF (S.class = Texts.Char) & (S.c = "&") THEN
    Texts.Scan(S);
    IF S.class IN {Texts.Name, Texts.String} THEN
     NEW(t);  Texts.Open(t, S.s);
     Texts.OpenScanner(S, t, 0);  Texts.Scan(S)
    END
   END;
   WHILE S.class IN {Texts.Name, Texts.String} DO
    i := 0;  ch := S.s[i];
    WHILE ch # 0X DO  src[sLen+i] := ch;  dest[dLen+i] := ch;  INC(i);  ch := S.s[i]  END;
    src[sLen+i] := 0X;  dest[dLen+i] := 0X;
    Texts.WriteString(W, src);
    sf := Files.Old(src);
    IF sf # NIL THEN
     Texts.Scan(S);
     IF (S.class = Texts.Char) & (S.c = "=") THEN
      Texts.Scan(S);
      IF (S.class = Texts.Char) & (S.c = ">") THEN
       Texts.Scan(S);
       IF S.class IN {Texts.Name, Texts.String} THEN
        i := 0;  ch := S.s[i];
        WHILE ch # 0X DO  dest[dLen+i] := ch;  INC(i);  ch := S.s[i]  END;
        dest[dLen+i] := 0X;
        Texts.Scan(S)
       ELSE
        (* skip *)
       END
      ELSE
       (* skip *)
      END
     END;
     Texts.WriteString(W, " => ");  Texts.WriteString(W, dest);
     df := NatFiles.New(dest);
     IF df # NIL THEN
      Texts.WriteString(W, " copying");
      Texts.Append(Oberon.Log, W.buf);
      Files.Set(sr, sf, 0);  NatFiles.Set(dr, df, 0);
      Files.Read(sr, ch);
      WHILE ~sr.eof DO
       NatFiles.Write(dr, ch);  Files.Read(sr, ch)
      END;
      NatFiles.Register(df);
      Texts.Scan(S)
     ELSE
      Texts.WriteString(W, " create failed");
      S.class := Texts.Inval
     END
    ELSE
     Texts.WriteString(W, " open failed");
     S.class := Texts.Inval
    END;
    Texts.WriteLn(W)
   END
  END
 END;
 Texts.Append(Oberon.Log, W.buf)
END CopyFrom;

PROCEDURE showFile(name: ARRAY OF CHAR;  time, date, size: LONGINT; VAR cont: BOOLEAN);
BEGIN
 INC(count);
 Texts.WriteString(W, name);
 IF (time # 0) & (date # 0) & (size # MIN(LONGINT)) THEN
  Texts.WriteString(W, "  "); Texts.WriteDate(W, time, date);
  Texts.WriteString(W, "  "); Texts.WriteInt(W, size, 5); INC(total, size)
 END;
 Texts.WriteLn(W)
END showFile;

PROCEDURE Directory*; (** [mask] *)
VAR
 par: Oberon.ParList; R: Texts.Reader; T, t: Texts.Text; beg, end, time: LONGINT; i: INTEGER; 
 diroption, ch: CHAR; pat: ARRAY 32 OF CHAR;
BEGIN
 par := Oberon.Par; 
 Texts.OpenReader(R, par.text, par.pos); Texts.Read(R, ch);
 WHILE (ch <= " ") & (ch # 0DX) DO Texts.Read(R, ch) END;
 IF (ch = "^") OR (ch = 0DX) THEN
  Oberon.GetSelection(T, beg, end, time);
  IF time >= 0 THEN
   Texts.OpenReader(R, T, beg); Texts.Read(R, ch);
   WHILE ch <= " " DO Texts.Read(R, ch) END
  END
 END;
 i := 0;
 WHILE (ch > " ") & (ch # Oberon.OptionChar) DO pat[i] := ch; INC(i); Texts.Read(R, ch) END;
 pat[i] := 0X;
 IF ch = Oberon.OptionChar THEN Texts.Read(R, diroption) ELSE diroption := 0X END;
 NEW(t);  Texts.Open(t, "");
 count := 0; total := 0;
 OFS.Enumerate(pat, (diroption = "d"), showFile);
 IF count > 1 THEN
  Texts.WriteLn(W);  Texts.WriteInt(W, count, 1); Texts.WriteString(W, " files");
  IF diroption = "d" THEN
   Texts.WriteString(W, " use "); Texts.WriteInt(W, (total+512) DIV 1024, 1);
   Texts.WriteString(W, "K bytes")
  END
 END;
 Texts.WriteLn(W); Texts.Append(t, W.buf);
 Oberon.OpenText("Directory", t, Display.Width DIV 8*3, 240)
END Directory;

PROCEDURE ShowMounted*; (** *)
VAR fs: OFS.FileSystem;
BEGIN
 fs := OFS.First();
 WHILE fs # NIL DO
  Out.String(fs.prefix);  Out.String(": ");
  Out.String(fs.desc);  Out.Ln;
  fs := OFS.Next(fs)
 END
END ShowMounted;
*)

BEGIN
 Texts.OpenWriter(W)
END FileSystem.

FileSystem.Tool

System.Free FileSystem ~
