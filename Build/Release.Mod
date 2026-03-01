(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Release; (** non-portable *) (* pjm *)

IMPORT Files, Texts, Oberon, OPM, OPS;

CONST
 IsModule* = 0; (* file with .Mod extension, compile *)
 InSource* = 1; (* include in source archive, unless InRelease or Private *)
 InRelease* = 2; (* include this file in the release archive *)
 ImportsSystem* = 3; (* this module imports SYSTEM *)
 Private* = 4; (* this should never be released *)
 MakeDef* = 5; (* make a Watson def file for this module *)
 
 NoMode = 0;  PackageMode = 1;  PrivateMode = 2;
 
 module = OPS.module; ident = OPS.ident; semicolon = OPS.semicolon; import = OPS.import; 
 becomes = OPS.becomes; comma = OPS.comma;
 
 CheckModules = TRUE; (* check module import consistency *)
 CheckFiles = FALSE; (* check if all files exist *)
 DoWatson = FALSE;
 
 Cols* = 70;
 
 ZipCommand = "ZipTool.Add \9 ";
 
TYPE
 Package* = POINTER TO RECORD
  name*, archive, source: ARRAY 32 OF CHAR;
  next: Package;
  dosource, sourcedone: BOOLEAN
 END;
 File* = POINTER TO RECORD
  name*: ARRAY 32 OF CHAR;
  package*: Package;
  flags*: SET;
  options: ARRAY 8 OF CHAR;
  next*: File
 END;

VAR
 files*: File;
 ObjExt*, SymExt*: ARRAY 8 OF CHAR;
 pos: LONGINT;
 curpack: Package;
 error: BOOLEAN;
 w: Texts.Writer;
 mode: LONGINT;
 sym: SHORTINT;
 packages: Package;

(* -- Output -- *)

(* Length - Return the length of a string. *)

PROCEDURE Length*(VAR s: ARRAY OF CHAR): LONGINT;
VAR i: LONGINT;
BEGIN
 i := 0;  WHILE s[i] # 0X DO INC(i) END;
 RETURN i
END Length;

(** SplitName - Split a filename into prefix, middle and suffix, seperated by ".". The prefix may contain dots ("."). *)

PROCEDURE SplitName*(name: ARRAY OF CHAR;  VAR pre, mid, suf: ARRAY OF CHAR);
VAR i, j, d0, d1: LONGINT;
BEGIN
 i := 0;  d0 := -1;  d1 := -1;
 WHILE name[i] # 0X DO
  IF name[i] = "." THEN
   d0 := d1;
   d1 := i
  END;
  INC(i)
 END;
 i := 0;
 IF (d0 # -1) & (d1 # d0) THEN (* have prefix *)
  WHILE i # d0 DO pre[i] := name[i]; INC(i) END
 ELSE
  d0 := -1
 END;
 pre[i] := 0X;
 i := d0+1;  j := 0;
 WHILE (name[i] # 0X) & (i # d1) DO mid[j] := name[i];  INC(i);  INC(j) END;
 mid[j] := 0X;  j := 0;
 IF d1 # -1 THEN
  i := d1+1;
  WHILE name[i] # 0X DO suf[j] := name[i];  INC(i);  INC(j) END
 END;
 suf[j] := 0X
END SplitName;

(** JoinName - Join a filename from prefix, middle and suffix, seperated by ".". *)

PROCEDURE JoinName*(pre, mid, suf: ARRAY OF CHAR;  VAR name: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 i := 0;  j := 0;
 WHILE pre[i] # 0X DO name[j] := pre[i];  INC(i);  INC(j) END;
 IF i # 0 THEN name[j] := ".";  INC(j) END;
 i := 0;
 WHILE mid[i] # 0X DO name[j] := mid[i];  INC(i);  INC(j) END;
 IF i # 0 THEN name[j] := ".";  INC(j) END;
 i := 0;
 WHILE suf[i] # 0X DO name[j] := suf[i];  INC(i);  INC(j) END;
 name[j] := 0X
END JoinName;

(** FindChar - Search from pos i for character ch in s and return position or -1 if not found. *)

PROCEDURE FindChar*(VAR s: ARRAY OF CHAR;  i: LONGINT;  ch: CHAR): LONGINT;
BEGIN
 WHILE (s[i] # 0X) & (s[i] # ch) DO INC(i) END;
 IF s[i] # ch THEN i := -1 END;
 RETURN i
END FindChar;

(* GenCompile - Generate compile command. *)

PROCEDURE GenCompile(compiler: ARRAY OF CHAR; packages: Package;  files: File);
VAR f: File; p: Package; c: LONGINT;
BEGIN
 Texts.WriteLn(w);  Texts.WriteString(w, "# Compile all modules");
 IF CheckModules THEN Texts.WriteString(w, " (red modules import SYSTEM)") END;
 Texts.WriteLn(w);  Texts.WriteString(w, "Configuration.DoCommands");
 Texts.WriteLn(w);  Texts.WriteString(w, "System.Time start");
 Texts.WriteLn(w);  Texts.WriteString(w, compiler);
 f := files; c := Cols; p := NIL;
 WHILE f # NIL DO
  IF IsModule IN f.flags THEN
   INC(c, 1+Length(f.name));
   IF f.options # "" THEN INC(c, 1+Length(f.options)) END;
   IF (c > Cols) OR (p # f.package) THEN
    c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ")
   END;
   IF ImportsSystem IN f.flags THEN Texts.SetColor(w, 1) END;
   Texts.WriteString(w, f.name);
   IF f.options # "" THEN
    Texts.Write(w, Oberon.OptionChar);  Texts.WriteString(w, f.options)
   END;
   IF ImportsSystem IN f.flags THEN Texts.SetColor(w, 15) END;
   p := f.package
  END;
  f := f.next
 END;
 Texts.WriteString(w, " ~");  Texts.WriteLn(w);
 Texts.WriteString(w, "System.Time lap"); Texts.WriteLn(w);
 Texts.WriteString(w, "~"); Texts.WriteLn(w)
END GenCompile;

(* GenCopyright - Generate copyright command. *)

PROCEDURE GenCopyright(packages: Package;  files: File);
VAR f, g: File;  c: LONGINT;
BEGIN
 Texts.WriteLn(w);  Texts.WriteString(w, "# Update copyright");  Texts.WriteLn(w);
 Texts.WriteString(w, "!Copyright.Replace");
 f := files;  c := Cols;
 WHILE f # NIL DO
  IF f.flags * {IsModule, InSource} # {} THEN
   g := files; WHILE (g # f) & (g.name # f.name) DO g := g.next END;
   IF g = f THEN
    INC(c, 1+Length(f.name));
    IF c > Cols THEN c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
    Texts.WriteString(w, f.name)
   END
  END;
  f := f.next
 END;
 Texts.WriteString(w, " ~");  Texts.WriteLn(w)
END GenCopyright;

(* GenWatson - Generate Watson command. *)

PROCEDURE GenWatson(packages: Package;  files: File);
VAR f: File;  c, i: LONGINT;  val, pre, mid, suf: ARRAY 64 OF CHAR;
BEGIN
 Texts.WriteLn(w);  Texts.WriteString(w, "# Generate Watson definitions");  Texts.WriteLn(w);
 Texts.WriteString(w, "Watson.MakeDefs ");
 f := files;  c := Cols;
 WHILE f # NIL DO
  IF (MakeDef IN f.flags) & (FindChar(f.options, 0, "X") < 0) THEN (* non-prefixed module *)
   INC(c, 1+Length(f.name));
   IF c > Cols THEN c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
   Texts.WriteString(w, f.name)
  END;
  f := f.next
 END;
 Texts.WriteString(w, " ~");  Texts.WriteLn(w);  Texts.WriteLn(w);
 Texts.WriteString(w, "# Archive Watson definitions");  Texts.WriteLn(w);
 Texts.WriteString(w, "System.DeleteFiles Definitions.zip ~");  Texts.WriteLn(w);
 FOR i := 1 TO 2 DO
  IF i = 1 THEN
   Texts.WriteString(w, "ZipTool.Add Definitions.zip")
  ELSE
   Texts.WriteString(w, "System.DeleteFiles")
  END;
  f := files;  c := Cols;
  WHILE f # NIL DO
   IF (MakeDef IN f.flags) & (FindChar(f.options, 0, "X") < 0) THEN (* non-prefixed module *)
    SplitName(f.name, pre, mid, suf);
    JoinName("", mid, "Def", val);
    INC(c, 1+Length(val));
    IF c > Cols THEN c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
    Texts.WriteString(w, val)
   END;
   f := f.next
  END;
  Texts.WriteString(w, " ~");  Texts.WriteLn(w)
 END
END GenWatson;

(* GenArchive - Generate archive command. *)

PROCEDURE GenArchive(prefix: ARRAY OF CHAR; packages: Package;  files: File);
VAR f: File;  c: LONGINT;  p: Package;  pre, mid, suf: ARRAY 64 OF CHAR;
BEGIN
 p := packages;
 WHILE p # NIL DO
  Texts.WriteLn(w);  Texts.WriteString(w, "# Package ");  Texts.WriteString(w, p.name);
  IF p.archive # "" THEN
   Texts.WriteLn(w);  Texts.WriteString(w, "System.DeleteFiles ");
   Texts.WriteString(w, p.archive); Texts.WriteString(w, " ~"); Texts.WriteLn(w);
   Texts.WriteString(w, ZipCommand);  Texts.WriteString(w, p.archive)
  ELSE
   Texts.WriteString(w, " (no archive)")
  END;
  f := files;  c := Cols;
  WHILE f # NIL DO
   IF (f.package = p) & (f.flags * {InRelease, Private} = {InRelease}) THEN
    SplitName(f.name, pre, mid, suf);
    INC(c, 1+Length(f.name));
    IF pre = prefix THEN
     JoinName("", mid, suf, mid);
     INC(c, 2+Length(mid))
    END;
    IF c > Cols THEN c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
    Texts.WriteString(w, f.name);
    IF pre = prefix THEN Texts.WriteString(w, "=>"); Texts.WriteString(w, mid) END
   END;
   f := f.next
  END;
  Texts.WriteString(w, " ~");  Texts.WriteLn(w);
  p := p.next
 END
END GenArchive;

(*
(* GenSystem - Generate boot diskette command. *)

PROCEDURE GenSystem(prefix: ARRAY OF CHAR; packages: Package;  files: File);
VAR f: File;  c: LONGINT;  p: Package;  rename: BOOLEAN;  pre, mid, suf: ARRAY 64 OF CHAR;
BEGIN
 p := packages;
 WHILE (p # NIL) & (p.name # "System") DO p := p.next END;
 IF p # NIL THEN
  Texts.WriteLn(w);  Texts.WriteString(w, "# Package ");  Texts.WriteString(w, p.name);
  Texts.WriteLn(w);  Texts.WriteString(w, "FDInstall.CreateInstallFloppy BasicSystem");
  f := files;  c := Cols;
  WHILE f # NIL DO
   IF (f.package = p) & (f.flags * {InRelease, Private} = {InRelease}) THEN
    INC(c, 1+Length(f.name));  rename := FALSE;
    SplitName(f.name, pre, mid, suf);
    IF pre = prefix THEN rename := TRUE;  INC(c, Length(f.name)-4+2) END;
    IF c > Cols THEN c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
    Texts.WriteString(w, f.name);
    IF rename THEN
     JoinName("", mid, suf, mid);
     Texts.WriteString(w, "=>");  Texts.WriteString(w, mid)
    END
   END;
   f := f.next
  END;
  Texts.WriteString(w, " ~");  Texts.WriteLn(w)
 END
END GenSystem;
*)

(* GenSource - Generate source archive command. *)

PROCEDURE GenSource(packages: Package;  files: File);
VAR f: File;  c: LONGINT;  p, q: Package;  src: ARRAY 32 OF CHAR;  sep: ARRAY 4 OF CHAR;
BEGIN
 p := packages;
 WHILE p # NIL DO
  IF ~p.sourcedone THEN
   COPY(p.source, src); (* new source file *)
   
   Texts.WriteLn(w);  Texts.WriteString(w, "# Source for");
   q := packages;  sep := " ";
   WHILE q # NIL DO
    IF q.source = src THEN
     Texts.WriteString(w, sep);  Texts.WriteString(w, q.name);  sep := ", ";
     q.dosource := TRUE;  q.sourcedone := TRUE
    ELSE
     q.dosource := FALSE
    END;
    q := q.next
   END;
   IF src = "" THEN
    Texts.WriteString(w, " (no archive)")
   ELSE
    Texts.WriteLn(w);  Texts.WriteString(w, "System.DeleteFiles ");
    Texts.WriteString(w, src); Texts.WriteString(w, " ~"); Texts.WriteLn(w);
    Texts.WriteString(w, ZipCommand);  Texts.WriteString(w, src)
   END;
   f := files;  c := Cols;
   WHILE f # NIL DO
    IF f.package.dosource & (f.flags * {InSource, InRelease, Private} = {InSource}) THEN
     INC(c, 1+Length(f.name));
     IF c > Cols THEN c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
     Texts.WriteString(w, f.name)
    END;
    f := f.next
   END;
   Texts.WriteString(w, " ~");  Texts.WriteLn(w)
  END;
  p := p.next
 END
END GenSource;

PROCEDURE GenManifest(privatearc: ARRAY OF CHAR; packages: Package);
VAR p, sorted: Package;

 PROCEDURE Insert(name: ARRAY OF CHAR);
 VAR q, n: Package;
 BEGIN
  q := sorted; WHILE (q.next # NIL) & (q.next.name < name) DO q := q.next END;
  IF (q.next = NIL) OR (q.next.name # name) THEN
   NEW(n); COPY(name, n.name); n.next := q.next; q.next := n
  END
 END Insert;
 
BEGIN
 NEW(sorted); sorted.next := NIL; Insert(privatearc);
 p := packages;
 WHILE p # NIL DO
  IF p.archive # "" THEN Insert(p.archive) END;
  IF p.source # "" THEN Insert(p.source) END;
  p := p.next
 END;
 Texts.WriteLn(w); Texts.WriteString(w, "# Manifest"); Texts.WriteLn(w);
 LOOP
  sorted := sorted.next;
  IF sorted = NIL THEN EXIT END;
  Texts.Write(w, 9X); Texts.WriteString(w, sorted.name); Texts.WriteLn(w)
 END;
 Texts.WriteLn(w)
END GenManifest;

(* GenPrivate - Generate private archive command. *)

PROCEDURE GenPrivate(privatearc: ARRAY OF CHAR; packages: Package;  files: File);
VAR f: File;  c: LONGINT;
BEGIN
 Texts.WriteLn(w);  Texts.WriteString(w, "# Private Source");  Texts.WriteLn(w);
 Texts.WriteString(w, "System.DeleteFiles "); Texts.WriteString(w, privatearc);
 Texts.WriteString(w, " ~"); Texts.WriteLn(w);
 Texts.WriteString(w, ZipCommand);  Texts.WriteString(w, privatearc);
 f := files;  c := Cols;
 WHILE f # NIL DO
  IF Private IN f.flags THEN
   INC(c, 1+Length(f.name));
   IF c > Cols THEN c := 0;  Texts.WriteLn(w);  Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
   Texts.WriteString(w, f.name)
  END;
  f := f.next
 END;
 Texts.WriteString(w, " ~");  Texts.WriteLn(w); Texts.WriteLn(w);
 Texts.WriteString(w, "System.Time lap"); Texts.WriteLn(w);
 Texts.WriteString(w, "~"); Texts.WriteLn(w)
END GenPrivate;

(* Output - Generate output. *)

PROCEDURE Output(prefix, name, compiler, privatearc: ARRAY OF CHAR; packages: Package;  files: File);
VAR out: Texts.Text;  t, d: LONGINT;
BEGIN
 Texts.WriteString(w, "Native Oberon release tool, automatically generated on");
 Oberon.GetClock(t, d);  Texts.WriteDate(w, t, d);  Texts.WriteLn(w);
 GenCompile(compiler, packages, files);
 Texts.WriteLn(w); Texts.WriteString(w, "Configuration.DoCommands");
 Texts.WriteLn(w); Texts.WriteString(w, "System.Time start");
 IF DoWatson THEN GenWatson(packages, files) END;
 (*GenSystem(prefix, packages, files);*)
 IF DoWatson THEN
  Texts.WriteLn(w); Texts.Write(w, 9X); Texts.WriteString(w, "Configuration.DoCommands");
  Texts.WriteLn(w); Texts.Write(w, 9X); Texts.WriteString(w, "System.Time start")
 END;
 GenArchive(prefix, packages, files);
 GenSource(packages, files);
 GenPrivate(privatearc, packages, files);
 GenCopyright(packages, files);
 GenManifest(privatearc, packages);
 NEW(out);  Texts.Open(out, "");
 Texts.Append(out, w.buf);
 Oberon.OpenText(name, out, 640, 400)
END Output;

(* -- Module parsing -- *)

PROCEDURE Error(msg: ARRAY OF CHAR);
BEGIN
 Texts.Write(w, 9X);  Texts.WriteString(w, "pos ");  Texts.WriteInt(w, pos, 1);
 Texts.WriteString(w, "  ");  Texts.WriteString(w, msg);
 IF (curpack # NIL) & (curpack.name # "") THEN
  Texts.WriteString(w, " in ");  Texts.WriteString(w, curpack.name)
 END;
 Texts.WriteLn(w);  Texts.Append(Oberon.Log, w.buf);
 error := TRUE
END Error;

PROCEDURE Error2(msg, par0, par1: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 Texts.Write(w, 9X);  Texts.WriteString(w, "pos ");  Texts.WriteInt(w, pos, 1);
 Texts.WriteString(w, "  ");
 i := 0; j := 0;
 WHILE msg[i] # 0X DO
  IF msg[i] = "#" THEN
   CASE j OF
    0: Texts.WriteString(w, par0)
    |1: Texts.WriteString(w, par1)
   END;
   INC(j)
  ELSE
   Texts.Write(w, msg[i])
  END;
  INC(i)
 END;
 IF (curpack # NIL) & (curpack.name # "") THEN
  Texts.WriteString(w, " in ");  Texts.WriteString(w, curpack.name)
 END;
 Texts.WriteLn(w);  Texts.Append(Oberon.Log, w.buf);
 error := TRUE
END Error2;

PROCEDURE Warning(msg: ARRAY OF CHAR);
BEGIN
 Texts.Write(w, 9X);  Texts.WriteString(w, "pos ");  Texts.WriteInt(w, pos, 1);
 Texts.WriteString(w, "  Warning: ");  Texts.WriteString(w, msg);
 IF (curpack # NIL) & (curpack.name # "") THEN
  Texts.WriteString(w, " in ");  Texts.WriteString(w, curpack.name)
 END;
 Texts.WriteLn(w);  Texts.Append(Oberon.Log, w.buf)
END Warning;

PROCEDURE MatchSym(s: INTEGER): BOOLEAN;
BEGIN
 IF s = sym THEN OPS.Get(sym); RETURN TRUE
 ELSE RETURN FALSE
 END
END MatchSym;

(** FindFile - Find a file. *)

PROCEDURE FindFile*(files: File;  name: ARRAY OF CHAR): File;
VAR f: File;
BEGIN
 f := files;  WHILE (f # NIL) & (f.name # name) DO f := f.next END;
 RETURN f
END FindFile;

PROCEDURE Import(files, m: File);
VAR import: ARRAY 32 OF CHAR;
BEGIN
 IF sym = ident THEN (* ident *)
  COPY(OPS.name, import); OPS.Get(sym);
  IF sym = becomes THEN (* := *)
   OPS.Get(sym);
   IF sym = ident THEN
    COPY(OPS.name, import); OPS.Get(sym)
   ELSE
    Error("module syntax error")
   END
  END;
  IF import = "SYSTEM" THEN
   INCL(m.flags, ImportsSystem)
  ELSE
   JoinName("", import, SymExt, import);
   IF FindFile(files, import) = NIL THEN Error(import) END
  END
 ELSE
  Error("module syntax error")
 END
END Import;

PROCEDURE ParseMod(files, f: File;  fname: ARRAY OF CHAR);
VAR r: Texts.Reader;  t: Texts.Text;  pre, mid, suf, name: ARRAY 32 OF CHAR;
BEGIN
 NEW(t);  Texts.Open(t, fname);
 Texts.OpenReader(r, t, 0);  OPM.Init({}, {}, r, Oberon.Log);
 OPS.Init;  OPS.Get(sym);
 IF MatchSym(module) THEN (* module *)
  IF sym = ident THEN (* ident *)
   COPY(OPS.name, name);
   SplitName(fname, pre, mid, suf);
   IF name # mid THEN
    Error("module name mismatch")
   ELSE
    OPS.Get(sym);
    IF MatchSym(semicolon) & MatchSym(import) THEN (* ; IMPORT *)
     LOOP
      Import(files, f);
      IF sym = semicolon THEN EXIT END; (* ; *)
      IF sym # comma THEN Error("module syntax error") ELSE OPS.Get(sym) END (* , *)
     END
    ELSE (* no import *)
    END
   END
  ELSE
   Error("module name not found")
  END
 ELSE
  Error("module not found")
 END
END ParseMod;

(* -- Command parsing -- *)

(* Like Texts.Scan, but skip comments. *)

PROCEDURE Scan(VAR s: Texts.Scanner);
VAR line: INTEGER;
BEGIN
 IF ~s.eot THEN
  Texts.Scan(s);  pos := Texts.Pos(s);
  WHILE ~s.eot & (s.class = Texts.Char) & (s.c = "#") DO
   line := s.line;  WHILE ~s.eot & (s.line = line) DO Texts.Scan(s) END
  END
 ELSE
  s.class := Texts.Inval
 END
END Scan;

PROCEDURE StartPackage(VAR packages: Package;  name: ARRAY OF CHAR);
VAR p, prev: Package;
BEGIN
 p := packages;  prev := NIL;
 WHILE (p # NIL) & (p.name # name) DO prev := p;  p := p.next END;
 IF p = NIL THEN
  NEW(p);  p.next := NIL;  p.dosource := FALSE;  p.sourcedone := FALSE;
  COPY(name, p.name);  p.archive := "";  p.source := "";
  IF prev = NIL THEN packages := p ELSE prev.next := p END
 END;
 curpack := p
END StartPackage;

PROCEDURE SetArchive(name: ARRAY OF CHAR);
BEGIN
 IF curpack.archive # "" THEN Error("package already has archive name")
 ELSE COPY(name, curpack.archive)
 END
END SetArchive;

PROCEDURE SetSource(name: ARRAY OF CHAR);
BEGIN
 IF curpack.source # "" THEN Error("package already has source archive name")
 ELSE COPY(name, curpack.source)
 END
END SetSource;

PROCEDURE AddFile(VAR files: File;  flag: CHAR;  name, options: ARRAY OF CHAR);
VAR f, prev: File;  pre, mid, suf: ARRAY 32 OF CHAR;  dup: BOOLEAN;  i: LONGINT;
BEGIN
 dup := FALSE;
 f := files;  WHILE f # NIL DO dup := dup OR (f.name = name);  prev := f;  f := f.next END;
 IF CheckFiles & (Files.Old(name) = NIL) THEN
  Error("file does not exist")
 ELSE
  NEW(f);  COPY(name, f.name);  f.package := curpack;  f.next := NIL;
  COPY(options, f.options);
  IF prev = NIL THEN files := f ELSE prev.next := f END;
  SplitName(name, pre, mid, suf);
  IF suf = "Mod" THEN
   IF flag = "*" THEN (* source in release, not in source, no Watson def *)
    f.flags := {IsModule, InRelease}
   ELSIF flag = "-" THEN (* no Watson def *)
    f.flags := {IsModule, InSource}
   ELSIF flag = "+" THEN (* no compile *)
    f.flags := {InSource}
   ELSE
    f.flags := {IsModule, InSource, MakeDef}
   END;
   IF CheckModules THEN ParseMod(files, f, name) END;
   IF FindChar(f.options, 0, "X") >= 0 THEN (* prefixed *)
    JoinName("", mid, SymExt, name);
    IF FindFile(files, name) = NIL THEN Error(name) END; (* check for base (compilation order) *)
    JoinName(pre, mid, ObjExt, name);
    AddFile(files, 0X, name, options)
   ELSE
    IF SymExt # ObjExt THEN
     JoinName("", mid, SymExt, name);
     AddFile(files, 0X, name, options)
    END;
    JoinName("", mid, ObjExt, name);
    AddFile(files, 0X, name, options)
   END
  ELSE
   f.flags := {InRelease}
  END;
  IF FindChar(f.options, 0, "X") >= 0 THEN
   i := 0;  WHILE f.options[i] # 0X DO INC(i) END;
   f.options[i] := "s";  f.options[i+1] := 0X;
   IF dup THEN EXCL(f.flags, InSource) END; (* don't duplicate source in case of base module for \X *)
  ELSIF dup THEN Error("duplicate file")
  END
 END
END AddFile;

PROCEDURE SetPrivate(files: File;  name: ARRAY OF CHAR);
VAR f: File;
BEGIN
 f := FindFile(files, name);
 IF f = NIL THEN
  Warning("name not found")
 ELSE
  INCL(f.flags, Private)
 END
END SetPrivate;

PROCEDURE Move(f: File;  p: Package;  file, from, to: ARRAY OF CHAR);
BEGIN
 WHILE (f # NIL) & (f.name # file) DO f := f.next END;
 IF f # NIL THEN
  IF f.package.name = from THEN
   WHILE (p # NIL) & (p.name # to) DO p := p.next END;
   IF p # NIL THEN
    f.package := p
   ELSE Error("package not found")
   END
  ELSE Error2("file # is in package #", file, f.package.name)
  END
 ELSE Error2("file # not found", file, "")
 END;
 error := FALSE (* errors here not serious *)
END Move;

PROCEDURE MoveIndirect(f: File;  p: Package;  listfile, from, to: ARRAY OF CHAR);
VAR t: Texts.Text; s: Texts.Scanner;  file: ARRAY 32 OF CHAR;
BEGIN
 NEW(t); Texts.Open(t, listfile);
 IF t.len # 0 THEN
  Texts.OpenScanner(s, t, 0); Texts.Scan(s);
  WHILE s.class IN {Texts.Name, Texts.String} DO
   COPY(s.s, file); Texts.Scan(s);
   IF (s.class = Texts.Char) & (s.c = "=") THEN
    Texts.Scan(s);
    IF (s.class = Texts.Char) & (s.c = ">") THEN
     Texts.Scan(s);
     IF s.class IN {Texts.Name, Texts.String} THEN
      COPY(s.s, file); Texts.Scan(s)
     ELSE
      Error("=> expected in list file"); RETURN
     END
    ELSE
     Error("=> expected in list file"); RETURN
    END
   END;
   Move(files, packages, file, from, to)
  END
 ELSE
  Error2("file # not found", listfile, "")
 END
END MoveIndirect;

(** Build a release tool. *)

PROCEDURE Build*; (* "name" <release spec> *)
VAR
 s: Texts.Scanner;  outname, compiler, privatearc, name, options, file, from: ARRAY 64 OF CHAR;
 flag: CHAR; indirect: BOOLEAN; prefix: ARRAY 16 OF CHAR;
BEGIN
 files := NIL;  packages := NIL;  curpack := NIL;
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Scan(s);  error := FALSE;  mode := NoMode;
 outname := "Release.Tool"; compiler := "Compiler.Compile \s";
 privatearc := "SYS:sourceprv.arc"; prefix := "Rel";
 ObjExt := "Obj"; SymExt := ObjExt;
 LOOP
  IF s.eot THEN
   Error("unexpected end of text")
  ELSIF s.class IN {Texts.String, Texts.Name} THEN
   IF s.s = "END" THEN
    mode := NoMode;
    EXIT
   ELSIF s.s = "TOOL" THEN
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN COPY(s.s, outname)
    ELSE Error("tool name expected")
    END
   ELSIF s.s = "COMPILER" THEN
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN COPY(s.s, compiler)
    ELSE Error("compiler command expected")
    END
   ELSIF s.s = "OBJ" THEN
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN COPY(s.s, ObjExt); COPY(s.s, SymExt)
    ELSE Error("Obj extension expected")
    END
   ELSIF s.s = "PACKAGE" THEN
    mode := PackageMode;
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN StartPackage(packages, s.s)
    ELSE Error("package name expected")
    END
   ELSIF s.s = "ARCHIVE" THEN
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN SetArchive(s.s)
    ELSE Error("archive name expected")
    END
   ELSIF s.s = "SOURCE" THEN
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN SetSource(s.s)
    ELSE Error("source archive name expected")
    END
   ELSIF s.s = "PRIVATEARC" THEN
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN COPY(s.s, privatearc)
    ELSE Error("archive name expected")
    END
   ELSIF s.s = "PREFIX" THEN
    Scan(s);
    IF s.class IN {Texts.String, Texts.Name} THEN COPY(s.s, prefix)
    ELSE Error("prefix name expected")
    END
   ELSIF s.s = "PRIVATE" THEN
    mode := PrivateMode
   ELSIF s.s = "MOVE" THEN
    indirect := FALSE; Scan(s);
    IF (s.class = Texts.Char) & (s.c = "^") THEN indirect := TRUE; Scan(s) END;
    IF s.class = Texts.Name THEN
     COPY(s.s, file);  Scan(s);
     IF s.class IN {Texts.String, Texts.Name} THEN
      COPY(s.s, from);  Scan(s);
      IF s.class IN {Texts.String, Texts.Name} THEN
       IF indirect THEN
        MoveIndirect(files, packages, file, from, s.s)
       ELSE
        Move(files, packages, file, from, s.s)
       END
      ELSE Error("to archive expected")
      END
     ELSE Error("from archive expected")
     END
    ELSE Error("name expected")
    END
   ELSIF mode = PackageMode THEN
    COPY(s.s, name);  options := "";
    IF (s.nextCh = "*") OR (s.nextCh = "-") OR (s.nextCh = "+") THEN flag := s.nextCh;  Scan(s)
    ELSE flag := 0X
    END;
    IF s.nextCh = Oberon.OptionChar THEN
     Scan(s);  Scan(s);
     IF s.class IN {Texts.String, Texts.Name} THEN COPY(s.s, options)
     ELSE Error("options expected")
     END
    END;
    AddFile(files, flag, name, options)
   ELSIF mode = PrivateMode THEN
    IF s.class IN {Texts.String, Texts.Name} THEN SetPrivate(files, s.s)
    ELSE Error("name expected")
    END
   ELSE
    Error("unexpected token")
   END
  ELSE
   Error("unexpected character")
  END;
  IF error THEN EXIT END;
  Scan(s)
 END;
 IF ~error THEN Output(prefix, outname, compiler, privatearc, packages, files) END;
 curpack := NIL
END Build;

BEGIN
 Texts.OpenWriter(w);
 ObjExt := "Obj"; SymExt := ObjExt
END Release.

System.Free Release ~

Native.Tool
