(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE ReleaseDocs; (** non-portable *) (* pjm *)

IMPORT Files, Modules, Fonts, Texts, Oberon, Objects, Attributes, Gadgets, Release;

CONST
 HTMLIndex = "Rel.Definitions.html";
 GenerateCommand = "ReleaseDocs.GenDefinitionsTool";
 
 ShowNullControls = FALSE; (* also show text controls with null commands *)
 CheckCommands = TRUE; (* check if commands exist in modules *)

 NormCol = 15;
 WarnCol = 1;

TYPE
 File = Release.File;
 
VAR
 w: Texts.Writer;
 warnings, pos: LONGINT;
 
PROCEDURE ShowMacros(obj: Objects.Object;  s: ARRAY OF CHAR);
VAR val: ARRAY 64 OF CHAR;  i, j: LONGINT;

 PROCEDURE Ok(ch: CHAR): BOOLEAN;
 BEGIN
  RETURN (ch = ".") OR ((ch >= "0") & (ch <= "9")) OR ((CAP(ch) >= "A") & (CAP(ch) <= "Z"));
 END Ok;
 
BEGIN
 i := 0;
 WHILE s[i] # 0X DO
  IF s[i] = "#" THEN
   INC(i);  j := 0;  WHILE Ok(s[i]) DO val[j] := s[i];  INC(i);  INC(j) END;
   val[j] := 0X;
   IF val # "" THEN
    Texts.Write(w, 9X);  Texts.WriteString(w, val);  Texts.WriteString(w, " = ");
    Attributes.GetString(obj, val, val);
    Texts.Write(w, 22X);  Texts.WriteString(w, val);  Texts.Write(w, 22X);  Texts.WriteLn(w)
   END
  ELSE
   INC(i)
  END
 END
END ShowMacros;

(* SplitCmd - Split a command string into command and filename parameter. *)

PROCEDURE SplitCmd(s: ARRAY OF CHAR;  VAR cmd, par: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 i := 0;  WHILE (s[i] # 0X) & (s[i] # " ") DO cmd[i] := s[i]; INC(i) END;
 cmd[i] := 0X;
 LOOP
  WHILE s[i] = " " DO INC(i) END;
  IF s[i] # Oberon.OptionChar THEN EXIT END;
  WHILE (s[i] # 0X) & (s[i] # " ") DO INC(i) END
 END;
 j := 0;  WHILE s[i] # 0X DO par[j] := s[i]; INC(i); INC(j) END;
 par[j] := 0X
END SplitCmd;

(* CheckFile - Check for non-existent files and package cross-links. *)

PROCEDURE CheckFile(files, f: File;  name: ARRAY OF CHAR);
VAR g: File;
BEGIN
 g := files;  WHILE (g # NIL) & (g.name # name) DO g := g.next END;
 Texts.Write(w, 9X);  Texts.Write(w, "[");  Texts.WriteString(w, name);
 IF g = NIL THEN
  Texts.SetColor(w, WarnCol);  Texts.WriteString(w, " NOT FOUND");  Texts.SetColor(w, NormCol);
  INC(warnings)
 ELSIF ~(Release.InRelease IN g.flags) THEN
  Texts.SetColor(w, WarnCol);  Texts.WriteString(w, " NOT IN RELEASE");  Texts.SetColor(w, NormCol);
  INC(warnings);
  g := NIL
 ELSIF g.package # f.package THEN
  Texts.WriteString(w, " crosslink ");  Texts.WriteString(w, f.package.name);
  Texts.WriteString(w, " -> ");  Texts.WriteString(w, g.package.name)
 ELSE
  Texts.WriteString(w, " ok")
 END;
 Texts.Write(w, "]")
END CheckFile;

(* CheckCommand - Heuristic check of command call. *)

PROCEDURE CheckCommand(files, f: File;  val: ARRAY OF CHAR);
VAR cmd, name, pre, mid, suf, obj: ARRAY 64 OF CHAR;  i: LONGINT;  mod: Modules.Module;  ok: BOOLEAN;
BEGIN
 SplitCmd(val, cmd, name);
 IF name[0] # 0X THEN
  IF (cmd = "Watson.ShowDef") OR (cmd = "Watson.ShowObj") OR (cmd = "Browser.ShowDef") THEN
   i := Release.FindChar(name, 0, ".");  IF i >= 0 THEN name[i] := 0X END;
   Release.JoinName("", name, Release.SymExt, name)
  ELSIF (cmd = "Gadgets.Insert") OR (cmd = "Gadgets.Link") THEN
   i := Release.FindChar(name, 0, ".");  IF i >= 0 THEN name[i] := 0X END;
   Release.JoinName("", name, Release.ObjExt, name)
  END
 END;
 Texts.WriteString(w, f.name);  Texts.Write(w, " ");  Texts.WriteInt(w, pos, 1);
 Texts.WriteString(w, " [");  Texts.WriteString(w, val);  Texts.Write(w, "]");
 IF CheckCommands THEN
  Release.SplitName(cmd, pre, mid, suf);  Release.JoinName("", mid, Release.ObjExt, obj);
  ok := (pre = "") & (Release.FindFile(files, obj) # NIL);
  IF ok THEN mod := Modules.ThisMod(mid);  ok := (mod # NIL) END;
  ok := ok & (Modules.ThisCommand(mod, suf) # NIL);
  IF ~ok THEN
   Texts.Write(w, 9X);  Texts.Write(w, "[");  Texts.WriteString(w, cmd);
   Texts.SetColor(w, WarnCol);  Texts.WriteString(w, " NO SUCH COMMAND");  Texts.SetColor(w, NormCol);
   Texts.Write(w, "]");
   INC(warnings);
   name := "" (* avoid parameter check *)
  END
 END;
 IF (CAP(name[0]) >= "A") & (CAP(name[0]) <= "Z") & (Release.FindChar(name, 0, "@") < 0) THEN
  CheckFile(files, f, name)
 END;
 Texts.WriteLn(w)
END CheckCommand;

(* GenLinkReport - Generate link report for texts and tools. *)

PROCEDURE GenLinkReport*;
VAR
 obj: Objects.Object;  text: Texts.Text;  f: File;  val, pre, mid, suf: ARRAY 64 OF CHAR;
 find: Texts.Finder;  scan: Texts.Scanner;  out: Texts.Text;
BEGIN
 IF Release.files # NIL THEN
  warnings := 0;
  obj := Gadgets.CreateObject("TextStyle");  Attributes.SetString(obj, "Tabs", "12,350");
  NEW(text);  Texts.WriteObj(w, obj);
  Texts.WriteString(w, "# Link report");  Texts.WriteLn(w);
  f := Release.files;
  WHILE f # NIL DO
   Release.SplitName(f.name, pre, mid, suf);
   IF (suf = "Text") OR (suf = "Tool") OR (suf = "html") THEN
    Texts.Open(text, f.name);
    IF text.len # 0 THEN
     IF suf = "html" THEN
      Texts.OpenScanner(scan, text, 0);  Texts.Scan(scan);  pos := Texts.Pos(scan);
      WHILE ~scan.eot DO
       WHILE ~scan.eot & (scan.class = Texts.Name) & (scan.s = "CMD") DO
        Texts.Scan(scan);
        IF (scan.class = Texts.Char) & (scan.c = "=") THEN
         Texts.Scan(scan);
         IF (scan.class = Texts.String) & (scan.s # "") THEN
          CheckCommand(Release.files, f, scan.s)
         END
        END
       END;
       Texts.Scan(scan);  pos := Texts.Pos(scan)
      END
     ELSE
      Texts.OpenFinder(find, text, 0);  pos := find.pos;  Texts.FindObj(find, obj);
      WHILE ~find.eot DO
       Attributes.GetString(obj, "Gen", val);
       IF (val = "TextGadgets.NewControl") OR (val = "HyperDocs.NewLinkControl") THEN
        Attributes.GetString(obj, "Cmd", val);
        IF (ShowNullControls OR (val # "")) & (val # "B") THEN
         CheckCommand(Release.files, f, val);
         ShowMacros(obj, val)
        END
       END;
       pos := find.pos;  Texts.FindObj(find, obj)
      END
     END
    ELSE
     Texts.WriteString(w, f.name);  Texts.WriteString(w, " not opened");  Texts.WriteLn(w)
    END
   END;
   f := f.next
  END;
  Texts.WriteLn(w);  Texts.WriteInt(w, warnings, 1);  Texts.WriteString(w, " warnings");  Texts.WriteLn(w);
  NEW(out);  Texts.Open(out, "");
  Texts.Append(out, w.buf);
  Oberon.OpenText("Temp.Links", out, 640, 400)
 ELSE
  Texts.WriteString(w, "Execute Release.Build first");  Texts.WriteLn(w);
  Texts.Append(Oberon.Log, w.buf)
 END
END GenLinkReport;

(* Filename - Heuristic to decide if a name is a file name. *)

PROCEDURE Filename(VAR s: ARRAY OF CHAR): BOOLEAN;
VAR i, j: LONGINT;  suf: ARRAY 10 OF CHAR;  f: BOOLEAN;
BEGIN
 i := 0;  j := -1;  f := FALSE;
 WHILE s[i] # 0X DO
  IF s[i] = "." THEN j := i END;
  INC(i)
 END;
 IF j # -1 THEN
  i := 0;  INC(j);
  WHILE (s[j] # 0X) & (i # 9) DO suf[i] := s[j];  INC(i);  INC(j) END;
  suf[i] := 0X;
  IF suf = Release.ObjExt THEN
   f := TRUE
  ELSIF CAP(suf[0]) = "A" THEN
   f := (suf = "ARC") OR (suf = "Arc")
  ELSIF suf[0] = "B" THEN
   f := (suf = "Bak") OR (suf = "Book")
  ELSIF suf[0] = "D" THEN
   f := (suf = "Def") OR (suf = "DB") OR (suf = "Desk")
  ELSIF suf[0] = "F" THEN
   f := (suf = "Fnt")
  ELSIF suf[0] = "G" THEN
   f := (suf = "Graph")
  ELSIF suf[0] = "L" THEN
   f := (suf = "Log") OR (suf = "Lib")
  ELSIF suf[0] = "M" THEN
   f := (suf = "Mod")
  ELSIF suf[0] = "O" THEN
   f := (suf = "Obj")
  ELSIF suf[0] = "P" THEN
   f := (suf = "Panel")
  ELSIF suf[0] = "T" THEN
   f := (suf = "Text") OR (suf = "Tool")
  ELSIF suf[0] = "z" THEN
   f := (suf = "zip")
  END
 END;
 RETURN f
END Filename;

PROCEDURE GenNameReport*;
VAR
 obj: Objects.Object;  text: Texts.Text;  f: File;  pre, mid, suf: ARRAY 64 OF CHAR;
 s: Texts.Scanner;  out: Texts.Text;  i: LONGINT;
BEGIN
 IF Release.files # NIL THEN
  warnings := 0;
  obj := Gadgets.CreateObject("TextStyle");  Attributes.SetString(obj, "Tabs", "12,350");
  NEW(text);  Texts.WriteObj(w, obj);
  Texts.WriteString(w, "# Name report");  Texts.WriteLn(w);
  f := Release.files;
  WHILE f # NIL DO
   Release.SplitName(f.name, pre, mid, suf);
   IF (suf = "Text") OR (suf = "Tool") THEN
    Texts.Open(text, f.name);
    IF text.len # 0 THEN
     Texts.OpenScanner(s, text, 0);  pos := 0;  Texts.Scan(s);
     WHILE ~s.eot DO
      IF s.class = Texts.Name THEN
       i := 0;
       WHILE (s.s[i] # 0X) & (s.s[i] # ".") & (s.s[i] # "@") & (s.s[i] # ":") DO INC(i) END;
       IF (i >= 2) & (s.s[i] = ".") & (s.s[i+1] # 0X) & (s.s[i+2] # 0X) THEN
        WHILE s.s[i] # 0X DO INC(i) END;
        IF s.s[i-1] = "." THEN s.s[i-1] := 0X END;
        IF Filename(s.s) THEN
         Texts.WriteString(w, f.name);  Texts.Write(w, " ");  Texts.WriteInt(w, pos, 1);
         CheckFile(Release.files, f, s.s);  Texts.WriteLn(w)
        ELSE
         CheckCommand(Release.files, f, s.s)
        END
       END
      END;
      pos := Texts.Pos(s);  Texts.Scan(s)
     END
    ELSE
     Texts.WriteString(w, f.name);  Texts.WriteString(w, " not opened");  Texts.WriteLn(w)
    END
   END;
   f := f.next
  END;
  Texts.WriteLn(w);  Texts.WriteInt(w, warnings, 1);  Texts.WriteString(w, " warnings");  Texts.WriteLn(w);
  NEW(out);  Texts.Open(out, "");
  Texts.Append(out, w.buf);
  Oberon.OpenText("Temp.Names", out, 640, 400)
 ELSE
  Texts.WriteString(w, "Execute Release.Build first");  Texts.WriteLn(w);
  Texts.Append(Oberon.Log, w.buf)
 END
END GenNameReport;

PROCEDURE S(VAR r: Files.Rider; s: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN
 i := 0;
 WHILE s[i] # 0X DO
  IF s[i] = "'" THEN Files.Write(r, 22X) ELSE Files.Write(r, s[i]) END;
  INC(i)
 END
END S;

PROCEDURE C(VAR r: Files.Rider; ch: CHAR);
BEGIN
 Files.Write(r, ch)
END C;

PROCEDURE L(VAR r: Files.Rider);
BEGIN
 Files.Write(r, 0AX)
END L;

PROCEDURE StartHTML(VAR r: Files.Rider);
BEGIN
 Files.Set(r, Files.New(HTMLIndex), 0);
 S(r, "<!DOCTYPE HTML PUBLIC '-//W3C//DTD HTML 4.01 Transitional//EN'>"); L(r);
 S(r, "<HTML>"); L(r);
 S(r, "<!-- Generated with "); S(r, GenerateCommand); S(r, " -->"); L(r);
 S(r, "<HEAD>"); L(r);
 S(r, "<TITLE>ETH Oberon Portable Interfaces</TITLE>"); L(r);
 S(r, "</HEAD>"); L(r); L(r);
 S(r, "<BODY BGCOLOR='#FFFFFF'>"); L(r);
 S(r, "<H1>ETH Oberon Portable Interfaces</H1>"); L(r);
 L(r); S(r, "<P>These definitions were generated by Watson directly from the module source code."); L(r);
 S(r, "If your application uses only portable interfaces it will compile on all current ports of "); L(r);
 S(r, "ETH Oberon.  Look for the 'portable' and 'non-portable' "); L(r);
 S(r, "comments in the module definitions.</P>"); L(r)
END StartHTML;

PROCEDURE EndHTML(VAR r: Files.Rider);
BEGIN
 L(r); S(r, "<P><ADDRESS>"); L(r);
 S(r, "Homepage: <A HREF='http://www.oberon.ethz.ch/'>http://www.oberon.ethz.ch/</A>"); L(r);
 S(r, "</ADDRESS>"); L(r);
 L(r); S(r, "</BODY>"); L(r);
 S(r, "</HTML>"); L(r);
 Files.Register(Files.Base(r));
 Texts.WriteString(w, HTMLIndex); Texts.WriteString(w, " written");
 Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf)
END EndHTML;

PROCEDURE CopyName(VAR from, to: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 i := 0; WHILE (from[i] # 0X) & (from[i] # ".") DO INC(i) END;
 IF from[i] = "." THEN INC(i) ELSE i := 0 END;
 j := 0; WHILE from[i] # 0X DO to[j] := from[i]; INC(i); INC(j) END;
 to[j] := 0X
END CopyName;

PROCEDURE GenDefinitionsTool*;
CONST Cols = 4; HTMLCols = 8; W = 384;  H = 400;  W2 = 640; LinkCol = 3;
TYPE
 List = POINTER TO RECORD
  next, allnext: List;
  name, fname: ARRAY 32 OF CHAR
 END;
VAR
 root, p, n, all: List;  s: Texts.Scanner;  i, j: LONGINT;  t: Texts.Text;  obj: Objects.Object;
 name: ARRAY 32 OF CHAR;  r: Files.Rider;
BEGIN
 NEW(root);  root.name := "~";  all := root;  all.allnext := all;
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 obj := Gadgets.CreateObject("TextStyle");
 Attributes.SetInt(obj, "Width", 360);
 Texts.SetFont(w, Fonts.This("Oberon10i.Scn.Fnt"));
 Attributes.SetString(obj, "Tabs", "10,100,190,280");
 Texts.WriteObj(w, obj);
 Texts.WriteString(w, "ETH Oberon Portable Interfaces");
 Texts.SetFont(w, Fonts.Default);
 Texts.WriteLn(w);  Texts.WriteLn(w);
 Texts.WriteString(w, "This list contains modules that are of interest to Oberon programmers.  ");
 Texts.WriteString(w, "For programming examples, see ");
 Texts.SetColor(w, LinkCol);
 Texts.WriteString(w, "SamplePrograms.Tool");
 obj := Gadgets.CreateObject("TextHyperlink");
 Attributes.SetString(obj, "Cmd", "Desktops.OpenDoc SamplePrograms.Tool");
 Texts.SetColor(w, NormCol);
 Texts.WriteObj(w, obj);
 Texts.WriteLn(w);
 StartHTML(r);
 WHILE s.class = Texts.String DO
  root.next := root;
  Texts.WriteLn(w);
  Texts.SetFont(w, Fonts.This("Oberon10i.Scn.Fnt"));
  Texts.WriteString(w, s.s);  Texts.WriteLn(w);
  L(r); S(r, "<H2>"); S(r, s.s); S(r, "</H2>"); L(r);
  Texts.Scan(s);
   (* read and sort names *)
  WHILE s.class = Texts.Name DO
   NEW(n);  COPY(s.s, n.fname); CopyName(s.s, n.name);
   (*n.allnext := all; all := n;*)
   p := root;  WHILE n.name > p.next.name DO p := p.next END;
   n.next := p.next;  p.next := n;
   n.allnext := p.allnext;  p.allnext := n;
   Texts.Scan(s)
  END;
   (* output names in columns *)
  S(r, "<TABLE>"); L(r);
  Texts.SetFont(w, Fonts.Default);
  n := root.next;  i := 0;
  WHILE n # root DO
   IF i MOD HTMLCols = 0 THEN S(r, "<TR>"); L(r) END;
   INC(i);
   Texts.Write(w, 9X);
   Texts.SetColor(w, LinkCol);
   Texts.WriteString(w, n.name);
   obj := Gadgets.CreateObject("TextHyperlink");
   Attributes.SetString(obj, "Name", n.name);
   Attributes.SetString(obj, "Cmd", "Watson.ShowDef #Name");
   Texts.SetColor(w, NormCol);
   Texts.WriteObj(w, obj);
   C(r, 9X); S(r, "<TD>");
   S(r, "<A HREF='"); S(r, n.name); S(r, ".Def.html'>"); S(r, n.name); S(r, "</A>");
   S(r, "</TD>"); L(r);
   IF i MOD Cols = 0 THEN Texts.WriteLn(w) END;
   IF i MOD HTMLCols = 0 THEN S(r, "</TR>"); L(r) END;
   n := n.next
  END;
  IF i MOD Cols # 0 THEN Texts.WriteLn(w) END;
  IF i MOD HTMLCols # 0 THEN S(r, "</TR>"); L(r) END;
  S(r, "</TABLE>"); L(r)
 END;
 Texts.SetFont(w, Fonts.Default);
 Texts.WriteLn(w);  Texts.WriteString(w, "These definitions were generated by ");
 Texts.SetColor(w, LinkCol);
 Texts.WriteString(w, "Watson");
 obj := Gadgets.CreateObject("TextHyperlink");
 Attributes.SetString(obj, "Cmd", "Desktops.OpenDoc Watson.Panel");
 Texts.SetColor(w, NormCol);
 Texts.WriteObj(w, obj);
 Texts.WriteString(w, " directly from the module source code.  ");
 Texts.WriteString(w, "If your application uses only portable interfaces it will compile on all current ports of ");
 Texts.WriteString(w, "ETH Oberon.  Look for the 'portable' and 'non-portable' ");
 Texts.WriteString(w, "comments in the module definitions.");
 Texts.WriteLn(w);
 NEW(t);  Texts.Open(t, "");
 Texts.Append(t, w.buf);
 Oberon.OpenText("Definitions.Tool", t, W, H);
  (* generate Watson tool *)
 Texts.WriteString(w, "Configuration.DoCommands");  Texts.WriteLn(w);  Texts.WriteLn(w);
 FOR j := 0 TO 3 DO
  CASE j OF
   0:
    Texts.WriteString(w, "Watson.MakeDefs")
   |1:
    Texts.WriteString(w, "System.DeleteFiles Definitions.Arc ~");  Texts.WriteLn(w);
    Texts.WriteString(w, "Compress.Add Definitions.Arc")
   |2:
    Texts.WriteString(w, "System.DeleteFiles")
   |3:
    Texts.WriteString(w, "Watson.MakeDefs \c")
  END;
  n := all.allnext; i := Release.Cols;
  WHILE n # all DO
   CASE j OF
    0,3: Release.JoinName("", n.fname, "Mod", name)
    |1,2: Release.JoinName("", n.name, "Def", name)
   END;
   INC(i, 1+Release.Length(name));
   IF i > Release.Cols THEN i := 0; Texts.WriteLn(w); Texts.Write(w, 9X) ELSE Texts.Write(w, " ") END;
   Texts.WriteString(w, name);
   n := n.allnext
  END;
  Texts.WriteString(w, " ~");  Texts.WriteLn(w)
 END;
 Texts.WriteString(w, "~");  Texts.WriteLn(w);
 NEW(t);  Texts.Open(t, "");
 Texts.Append(t, w.buf);
 Oberon.OpenText("", t, W2, H);
 EndHTML(r)
END GenDefinitionsTool;

(* Crude parser for descriptions. *)

PROCEDURE ParseDesc(VAR wd: Texts.Writer; fname: ARRAY OF CHAR);
VAR s: Texts.Scanner; t: Texts.Text; author, desc: ARRAY 64 OF CHAR; pre, mid, suf: ARRAY 32 OF CHAR;
BEGIN
 NEW(t); Texts.Open(t, fname);
 Texts.OpenScanner(s, t, 0); Texts.Scan(s);
 author := ""; desc := "";
 WHILE ~s.eot DO
  IF s.class = Texts.Name THEN
   IF (s.s = "AUTHOR") & (author = "") THEN
    Texts.Scan(s);
    IF s.class = Texts.String THEN COPY(s.s, author) END
   ELSIF  (s.s = "PURPOSE") & (desc = "") THEN
    Texts.Scan(s);
    IF s.class = Texts.String THEN COPY(s.s, desc) END
   ELSIF (s.s = "IMPORT") OR (s.s = "CONST") OR (s.s = "TYPE") OR (s.s = "VAR") OR (s.s = "PROCEDURE") THEN
    s.eot := TRUE
   END
  END;
  IF ~s.eot THEN Texts.Scan(s) END
 END;
 Release.SplitName(fname, pre, mid, suf);
 Texts.WriteString(wd, mid); Texts.Write(wd, 9X);
 Texts.WriteString(wd, author); Texts.Write(wd, 9X);
 Texts.WriteString(wd, desc); Texts.WriteLn(wd)
END ParseDesc;

PROCEDURE GenModuleList*; (** name {file.Mod} *)
VAR wd: Texts.Writer; out: Texts.Text; s: Texts.Scanner; obj: Objects.Object; name: ARRAY 64 OF CHAR;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
 COPY(s.s, name); Texts.Scan(s);
 Texts.OpenWriter(wd);
 obj := Gadgets.CreateObject("TextStyle");
 Attributes.SetString(obj, "Tabs", "140,280");
 Texts.WriteObj(wd, obj);
 WHILE s.class = Texts.Name DO
  ParseDesc(wd, s.s); Texts.Scan(s)
 END;
 NEW(out);  Texts.Open(out, "");
 Texts.Append(out, wd.buf);
 Oberon.OpenText(name, out, 640, 400)
END GenModuleList;

BEGIN
 Texts.OpenWriter(w);  Texts.SetColor(w, NormCol)
END ReleaseDocs.

(Release.Build must be executed first)

Release.GenLinkReport
Release.GenNameReport

Compiler.Compile \s Release.Mod ReleaseDocs.Mod ~

System.Free ReleaseDocs Release ~
