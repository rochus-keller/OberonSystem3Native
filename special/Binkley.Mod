(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Binkley; (** non-portable *)

IMPORT SYSTEM, Objects, Attributes, Gadgets, Links, Display, In, Out, Dates, Oberon, Texts, TextGadgets0, Desktops, 
 Documents, TextDocs, Compress, Kernel, Files, FileDir;

VAR
 w: Texts.Writer;  col, seed, time, date: LONGINT;  sectors: LONGINT;
 prefix: ARRAY 32 OF CHAR;
 
PROCEDURE Neutralise*;
VAR N: Oberon.ControlMsg;
BEGIN
 N.F := NIL; N.id := Oberon.neutralize; Display.Broadcast(N);
 (*Oberon.FadeCursor(Oberon.Mouse); Oberon.FadeCursor(Oberon.Pointer)*)
END Neutralise;

PROCEDURE Redraw*;
VAR dcm: Display.ControlMsg;  cm: Oberon.ControlMsg;
BEGIN
 cm.F := NIL;  cm.id := Oberon.neutralize;  Display.Broadcast(cm);
 Oberon.FadeCursor(Oberon.Mouse);  Oberon.FadeCursor(Oberon.Pointer);
 dcm.F := NIL;  dcm.id := Display.suspend;  Display.Broadcast(dcm);
 dcm.F := NIL;  dcm.id := Display.restore;  Display.Broadcast(dcm)
END Redraw;

PROCEDURE FindFrame(x, y: INTEGER): Display.Frame;
VAR L: Display.LocateMsg;
BEGIN
 L.loc := NIL; L.X := x; L.Y := y; L.F := NIL; L.res := -1;  L.loc := NIL;
 Display.Broadcast(L);
 RETURN L.loc
END FindFrame;

(** Change color of Gadgets frame at specified position *)

PROCEDURE Color*; (* color x y *)
VAR col, x, y: INTEGER;  f: Display.Frame;
BEGIN
 In.Open;  In.Int(col);  In.Int(x);  In.Int(y);
 IF In.Done THEN
  f := FindFrame(x, y); (* top right *)
  IF f # NIL THEN
   Attributes.SetInt(f, "Color", col);
   Gadgets.Update(f)
  END
 END
END Color;

(** Like Color, but only works on release x (for startup) *)

PROCEDURE ColorX*;
VAR s: Texts.Scanner;
BEGIN
 Texts.OpenScanner(s, Oberon.Log, 0);
 REPEAT Texts.Scan(s) UNTIL s.eot OR ((s.class = Texts.Name) & (s.s = "Release"));
 IF ~s.eot THEN
  Texts.Scan(s);
  IF s.nextCh = "x" THEN Color END
 END
END ColorX;

PROCEDURE WriteDate (VAR W: Texts.Writer; d: LONGINT);

 PROCEDURE WritePair(ch: CHAR; x: LONGINT);
 BEGIN
  IF ch # 0X THEN Texts.Write(W, ch) END;
  Texts.Write(W, CHR(x DIV 10 + 30H)); Texts.Write(W, CHR(x MOD 10 + 30H))
 END WritePair;

BEGIN
 WritePair(0X, d MOD 32); WritePair(".", d DIV 32 MOD 16);  WritePair(".", d DIV 512 MOD 100)
END WriteDate;

(** Insert a date stamp with day of week at the start of the current text *)

PROCEDURE NewLogEntry*;
VAR t, d: LONGINT;  w: Texts.Writer;  doc: Documents.Document; T: Texts.Text;  option: ARRAY 32 OF CHAR;  plain: BOOLEAN;
BEGIN
 In.Open;  In.Name(option);
 plain := In.Done & (option = "plain");
 Texts.OpenWriter(w);  IF ~plain THEN Texts.SetColor(w, 1) END;
 Oberon.GetClock(t, d);  WriteDate(w, d);
 IF ~plain THEN
  Texts.Write(w, " ");
  t := Dates.DayOfWeek(d);
  CASE t OF
   0: Texts.WriteString(w, "mon")
   |1: Texts.WriteString(w, "tue")
   |2: Texts.WriteString(w, "wed")
   |3: Texts.WriteString(w, "thu")
   |4: Texts.WriteString(w, "fri")
   |5: Texts.WriteString(w, "sat")
   |6: Texts.WriteString(w, "sun")
  END
 END;
 Texts.WriteLn(w);  IF ~plain THEN Texts.SetColor(w, 15) END;
 IF plain THEN Texts.WriteString(w, "-------") END;
 Texts.WriteLn(w);  Texts.WriteLn(w);  Texts.WriteLn(w);
 doc := Desktops.CurDoc(Gadgets.context);
 IF (doc # NIL) & (doc.dsc IS TextGadgets0.Frame) THEN
  T := doc.dsc(TextGadgets0.Frame).text;
  Texts.Insert(T, 0, w.buf);
  IF plain THEN
   TextDocs.SetCaret(doc.dsc, T, 17)
  ELSE
   TextDocs.SetCaret(doc.dsc, T, 14)
  END
 END
END NewLogEntry;

PROCEDURE FindGadgets*; (* { name.Mod } *)
VAR name: ARRAY 32 OF CHAR;  t: Texts.Text;  s: Texts.Scanner;  gen: BOOLEAN;
BEGIN
 NEW(t);
 In.Open;  In.Name(name);
 WHILE In.Done DO
  Texts.Open(t, name);
  IF t.len # 0 THEN
   Texts.OpenScanner(s, t, 0);
   Texts.Scan(s);  gen := FALSE;
   WHILE ~s.eot DO
    IF (s.class = Texts.String) & (s.s = "Gen") THEN
     gen := TRUE
    ELSIF gen & (s.class = Texts.String) THEN
     Out.String(s.s);  Out.Char(" ");  Out.String(name);  Out.Ln;
     gen := FALSE
    END;
    Texts.Scan(s)
   END
  END;
  In.Name(name)
 END
END FindGadgets;

PROCEDURE CheckGadgetAlias*; (* {alias generator label} *)
TYPE
 Alias = POINTER TO AliasDesc;
 AliasDesc = RECORD
  next: Alias;
  alias, gen: ARRAY 32 OF CHAR
 END;
VAR
 s: Texts.Scanner;  alias, gen: ARRAY 32 OF CHAR;
 list, a: Alias;
BEGIN
 list := NIL;
 Oberon.OpenScanner(s, "Gadgets.Aliases");
 WHILE ~s.eot & (s.class = Texts.Name) DO
  NEW(a);  COPY(s.s, a.alias);  Texts.Scan(s);  Texts.Scan(s);  COPY(s.s, a.gen);
  a.next := list;  list := a;
  Texts.Scan(s)
 END;
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 WHILE ~s.eot & ((s.class = Texts.Name) OR ((s.class = Texts.Char) & (s.c = "-"))) DO
  IF s.class = Texts.Char THEN s.s := "" END;
  COPY(s.s, alias);  Texts.Scan(s);  COPY(s.s, gen);  Texts.Scan(s);
  a := list;  WHILE (a # NIL) & (a.alias # alias) DO a := a.next END;
  IF a = NIL THEN
   Out.String(gen);
   IF alias # "" THEN Out.String(" (");  Out.String(alias);  Out.Char(")") END;
   Out.String(" has no entry");  Out.Ln
  ELSIF a.gen # gen THEN
   Out.String(gen);
   IF alias # "" THEN Out.String(" (");  Out.String(alias);  Out.Char(")") END;
   Out.String(" mismatches entry ");  Out.String(a.gen);  Out.Ln
  END;
  Texts.Scan(s)
 END
END CheckGadgetAlias;

PROCEDURE EditMenu*; (* copy selected iconizer menu for editing *)
VAR obj1, obj2: Objects.Object;  time: LONGINT;  name, cmd: ARRAY 32 OF CHAR;  t: Texts.Text;  f: Display.Frame;
BEGIN
 Gadgets.GetSelection(obj1, time);
 IF (time >= 0) & (obj1 # NIL) THEN
  Attributes.GetString(obj1, "Gen", name);
  IF name = "Icons.NewIconizer" THEN
   Links.GetLink(obj1, "Closed", obj2);
   IF (obj2 # NIL) & (obj2 IS Display.Frame) THEN
    name := "";
    f := obj2(Display.Frame).dsc; (* first child *)
    WHILE f # NIL DO
     Attributes.GetString(f, "Gen", name);
     IF name = "TextFields.NewCaption" THEN
      Attributes.GetString(f, "Value", name);  f := NIL
     ELSE
      name := "";  f := f.next
     END
    END
   END;
   Links.GetLink(obj1, "Open", obj2);
   IF (obj2 # NIL) & (obj2 IS TextGadgets0.Frame) THEN
    obj2 := Gadgets.Clone(obj2, TRUE);
    WITH obj2: TextGadgets0.Frame DO
     obj2.state0 := obj2.state0 + {TextGadgets0.sizeadjust, TextGadgets0.grow, TextGadgets0.shrink}
    END;
    NEW(t);  Texts.Open(t, "");
    Texts.WriteString(w, "Binkley.MakeMenu ");
    Texts.Write(w, 22X);  Texts.WriteString(w, name);  Texts.Write(w, 22X);  Texts.Write(w, " ");
    Attributes.GetString(obj2, "Cmd", cmd);
    Texts.Write(w, 22X);  Texts.WriteString(w, cmd);  Texts.Write(w, 22X);
    Texts.Write(w, " ");  Texts.WriteInt(w, obj1(Display.Frame).W, 1);
    Texts.Write(w, " ");  Texts.WriteInt(w, obj1(Display.Frame).H, 1);
    Texts.WriteLn(w);
    Texts.WriteObj(w, obj2);  Texts.WriteLn(w);
    Texts.Append(t, w.buf);
    Oberon.OpenText("", t, 200, 200)
   ELSE Out.String("no text");  Out.Ln
   END
  ELSE Out.String("not an Iconizer");  Out.Ln
  END
 ELSE Out.String("no selection");  Out.Ln
 END
END EditMenu;

PROCEDURE MakeMenu*; (* "name" "cmd" [W H] obj *)
CONST XX = 12;
VAR
 name, cmd: ARRAY 32 OF CHAR;  s: Texts.Scanner;  obj1, obj2, obj3: Objects.Object;
 w, h, cx, cy: INTEGER;  f: Display.Frame;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);  Texts.Scan(s);
 IF s.class = Texts.String THEN
  COPY(s.s, name);  Texts.Scan(s);
  IF s.class = Texts.String THEN
   COPY(s.s, cmd);  Texts.Scan(s);
   IF s.class = Texts.Int THEN w := SHORT(s.i); Texts.Scan(s) ELSE w := 64 END;
   IF s.class = Texts.Int THEN h := SHORT(s.i);  Texts.Scan(s) ELSE h := 25 END;
   IF s.class = Texts.Object THEN
    obj1 := Gadgets.CreateObject("Iconizer");
    Attributes.SetBool(obj1, "Popup", TRUE);
    (*Attributes.SetBool(obj1, "Pin", FALSE);*)
    Gadgets.ModifySize(obj1(Display.Frame), w, h);
    obj2 := Gadgets.Clone(s.obj, TRUE); (* open contents *)
    Attributes.SetString(obj2, "Cmd", cmd);
    Links.SetLink(obj1, "Open", obj2);
    obj2 := Gadgets.CreateObject("Panel"); (* closed contents *)
    Gadgets.ModifySize(obj2(Display.Frame), w, h);
    obj3 := Gadgets.CreateObject("Caption");
    Attributes.SetString(obj3, "Value", name);
    f := obj3(Display.Frame);
    cx := (w - f.W) DIV 2 + 1;  cy := (h - f.H) DIV 2 - h;
    IF cx < XX THEN cx := XX END;
    Gadgets.Consume(obj2(Gadgets.Frame), obj3(Gadgets.Frame), cx, cy);
    Attributes.SetBool(obj2, "Locked", TRUE);
    Links.SetLink(obj1, "Closed", obj2);
    Gadgets.Integrate(obj1)
   ELSE Out.String("no gadget");  Out.Ln
   END
  END
 END
END MakeMenu;

PROCEDURE ReadLine(VAR r: Texts.Reader;  VAR line: ARRAY OF CHAR);
VAR i: LONGINT;  ch: CHAR;
BEGIN
 i := 0;  Texts.Read(r, ch);
 WHILE ~r.eot & (ch # 0DX) DO
  IF i # LEN(line)-1 THEN line[i] := ch;  INC(i) END;
  Texts.Read(r, ch)
 END;
 line[i] := 0X
END ReadLine;

PROCEDURE Random (N: LONGINT): LONGINT;
BEGIN
 seed := (seed + 773) * 13 MOD 9999991; 
 RETURN SHORT (seed MOD N)
END Random;

PROCEDURE RandomLine*;
TYPE
 Node = POINTER TO NodeDesc;
 NodeDesc = RECORD
  line: ARRAY 100 OF CHAR;
  next: Node
 END;
VAR first, n: Node;  text: Texts.Text;  r: Texts.Reader;  name: ARRAY 32 OF CHAR;  num: LONGINT;
BEGIN
 first := NIL;  num := 0;  In.Open;  In.Name(name);
 IF In.Done THEN
  NEW(text);  Texts.Open(text, name);
  IF text.len # 0 THEN
   Texts.OpenReader(r, text, 0);  NEW(n);
   WHILE ~r.eot DO
    ReadLine(r, n.line);
    IF n.line # "" THEN
     n.next := first;  first := n;  NEW(n);  INC(num)
    END
   END;
   num := Random(num);
   n := first;  WHILE num # 0 DO n := n.next;  DEC(num) END;
   Out.String(n.line);  Out.Ln
  END
 END
END RandomLine;

PROCEDURE List(h: Compress.Header;  VAR stop: BOOLEAN);
VAR len: LONGINT;
BEGIN
 len := ENTIER(h.length / h.ratio * 100.0);
 INC(sectors, (len + 2047) DIV 2048)
END List;

PROCEDURE Meg(k: LONGINT);
BEGIN
 Out.Int(k, 1);  Out.String("K (");
 INC(k, 512 DIV 10); (* round up *)
 Out.Int(k DIV 1024, 1);  Out.Char(".");
 Out.Int(k*10 DIV 1024 MOD 10, 1);
 Out.String("M)")
END Meg;

PROCEDURE ArcFileSizes*; (* {arcfile} ~ *)
VAR name: ARRAY 32 OF CHAR;  res: INTEGER;  f: Files.File;
BEGIN
 In.Open;  In.Name(name);
 WHILE In.Done DO
  Out.String(name);  Out.Char(" ");
  f := Files.Old(name);
  IF f # NIL THEN
   sectors := 0;
   Compress.Enumerate(name, List, FALSE, res);
   Meg((Files.Length(f)+512) DIV 1024);  Out.Char(" ");
   Meg(sectors*2)
  ELSE
   Out.String("not found")
  END;
  Out.Ln;
  In.Name(name)
 END
END ArcFileSizes;

PROCEDURE ListNames(h: Compress.Header;  VAR stop: BOOLEAN);
CONST Width = 65;
VAR len: LONGINT;
BEGIN
 len := 0;  WHILE h.name[len] # 0X DO INC(len) END;
 IF (col # 0) & (col + len > Width) THEN (* start new line *)
  Texts.WriteLn(w);  Texts.WriteString(w, "  ");
  col := 0
 END;
 INC(col, len+1);
 Texts.WriteString(w, h.name);  Texts.Write(w, " ")
END ListNames;

PROCEDURE ArcFileList*; (* {arcfile} ~ *)
VAR name: ARRAY 32 OF CHAR;  res: INTEGER;  t: Texts.Text;
BEGIN
 In.Open;  In.Name(name);
 WHILE In.Done DO
  Texts.WriteString(w, name);  Texts.WriteLn(w);
  Texts.WriteString(w, "  ");  col := 0;
  Compress.Enumerate(name, ListNames, FALSE, res);
  Texts.WriteLn(w);
  In.Name(name)
 END;
 NEW(t);  Texts.Open(t, "");
 Oberon.OpenText("", t, 400, 400);
 Texts.Append(t, w.buf)
END ArcFileList;

PROCEDURE MapFilesHandler(name: ARRAY OF CHAR; time, date, size: LONGINT; VAR continue: BOOLEAN);
CONST Width = 80;
VAR len, i, j: LONGINT;  newname: ARRAY 32 OF CHAR;
BEGIN
 i := 0;  WHILE (name[i] # 0X) & (name[i] = prefix[i]) DO INC(i) END;
 IF (prefix[i] = 0X) & (i # 0) THEN
  j := 0;  WHILE name[i] # 0X DO newname[j] := name[i];  INC(i);  INC(j) END;
  newname[j] := 0X;  len := i+j+5
 ELSE
  WHILE name[i] # 0X DO INC(i) END;
  newname[0] := 0X;  len := i+1
 END;
 IF (col # 0) & (col + len > Width) THEN (* start new line *)
  Texts.WriteLn(w);  Texts.WriteString(w, "  ");
  col := 0
 END;
 INC(col, len);
 Texts.WriteString(w, name);
 IF newname[0] # 0X THEN
  Texts.WriteString(w, " => ");  Texts.WriteString(w, newname)
 END;
 Texts.Write(w, " ")
END MapFilesHandler;

PROCEDURE MapFiles*; (* prefix { mask } ~ *)
VAR t: Texts.Text;  s: Texts.Scanner;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class IN {Texts.Name, Texts.String} THEN
  COPY(s.s, prefix);  Texts.Scan(s);
  Texts.WriteString(w, "  ");  col := 0;
  WHILE s.class IN {Texts.Name, Texts.String} DO
   FileDir.Enumerate(s.s, FALSE, MapFilesHandler);
   Texts.Scan(s)
  END;
  Texts.WriteLn(w);
  NEW(t);  Texts.Open(t, "");
  Texts.Append(t, w.buf);
  Oberon.OpenText("", t, 400, 400)
 END
END MapFiles;

(* Q&D module import list scanner for
 http://loki.cs.brown.edu:8081/graphserver/ *)

PROCEDURE ScanModules*; (* { module.Mod } *)
VAR s: Texts.Scanner;  name, name2: ARRAY 32 OF CHAR;  t: Texts.Text;
BEGIN
 NEW(t);
 In.Open;  In.Name(name);
 WHILE In.Done DO
  Texts.Open(t, name);
  Texts.OpenScanner(s, t, 0);
  REPEAT Texts.Scan(s) UNTIL (s.class = Texts.Name) & (s.s = "MODULE") OR s.eot;
  IF ~s.eot THEN
   Texts.Scan(s);  COPY(s.s, name);
   REPEAT Texts.Scan(s) UNTIL (s.class = Texts.Name) & (s.s = "IMPORT") OR s.eot;
   Texts.Scan(s);
   WHILE s.class = Texts.Name DO
    COPY(s.s, name2);
    Texts.Scan(s);
    IF (s.class = Texts.Char) & (s.c = ":") THEN
     Texts.Scan(s); ASSERT((s.class = Texts.Char) & (s.c = "="));
     Texts.Scan(s); ASSERT(s.class = Texts.Name);
     COPY(s.s, name2);
     Texts.Scan(s)
    END;
    IF TRUE THEN
     Texts.WriteString(w, name2);  Texts.WriteString(w, " ");  Texts.WriteString(w, name);  Texts.WriteLn(w)
    ELSE
     Texts.WriteString(w, name);  Texts.WriteString(w, " > ");  Texts.WriteString(w, name2);  Texts.WriteLn(w)
    END;
    IF (s.class = Texts.Char) & (s.c = ",") THEN Texts.Scan(s) END
   END
  END;
  In.Name(name)
 END;
 Texts.Open(t, "");  Texts.Append(t, w.buf);
 Oberon.OpenText("", t, 200, 200)
END ScanModules;

(* Q&D module import list scanner for daVinci *)

PROCEDURE ScanModules2*; (* { leafmodule | module.Mod } *)
VAR s: Texts.Scanner;  name: ARRAY 32 OF CHAR;  t: Texts.Text;
BEGIN
 NEW(t);
 In.Open;  In.Name(name);
 Texts.Write(w, "[");  Texts.WriteLn(w);
 WHILE In.Done DO
  Texts.Open(t, name);
  Texts.OpenScanner(s, t, 0);
  IF t.len # 0 THEN
   REPEAT Texts.Scan(s) UNTIL (s.class = Texts.Name) & (s.s = "MODULE") OR s.eot;
   Texts.Scan(s);  COPY(s.s, name)
  END;
  Texts.WriteString(w, 'l("');  Texts.WriteString(w, name);
  Texts.WriteString(w, '", n("module", [a("OBJECT","');
  Texts.WriteString(w, name);   Texts.WriteString(w, '")],');
  IF t.len # 0 THEN
   REPEAT Texts.Scan(s) UNTIL (s.class = Texts.Name) & (s.s = "IMPORT") OR s.eot;
   IF ~s.eot THEN
    Texts.WriteLn(w);  Texts.WriteString(w, '  [');  Texts.WriteLn(w);
    Texts.Scan(s);
    WHILE s.class = Texts.Name DO
     Texts.WriteString(w, '  l("');  Texts.WriteString(w, name);
     Texts.Write(w, "-");  Texts.WriteString(w, s.s);
     Texts.WriteString(w, '", e("import", [], r("');  Texts.WriteString(w, s.s);
     Texts.WriteString(w, '")))');
     Texts.Scan(s);
     IF (s.class = Texts.Char) & (s.c = ",") THEN
      Texts.Scan(s);  Texts.WriteString(w, ',')
     ELSIF (s.class = Texts.Char) & (s.c = ":") THEN
      Out.String(":= in "); Out.String(name); Out.Ln
     END;
     Texts.WriteLn(w)
    END;
    Texts.WriteString(w, '  ]))')
   ELSE
    Texts.WriteString(w, ' []))')
   END
  ELSE
   Texts.WriteString(w, ' []))')
  END;
  In.Name(name);
  IF In.Done THEN Texts.WriteString(w, ',') END; 
  Texts.WriteLn(w)
 END;
 Texts.Write(w, "]");  Texts.WriteLn(w);
 Texts.Open(t, "");  Texts.Append(t, w.buf);
 Oberon.OpenText("Temp.daVinci", t, 200, 200)
END ScanModules2;

PROCEDURE ShowTime*;
BEGIN
 Texts.WriteInt(w, Oberon.Time(), 1);
 Texts.WriteString(w, " ticks"); Texts.WriteLn(w);
 Texts.Append(Oberon.Log, w.buf)
END ShowTime;

(*
PROCEDURE ReadStr(VAR r: Texts.Reader; VAR str: ARRAY OF CHAR);
VAR i: LONGINT; ch: CHAR;
BEGIN
 i := 0;
 REPEAT Texts.Read(r, ch) UNTIL r.eot OR (ch = 22X);
 IF ~r.eot THEN
  LOOP
   Texts.Read(r, ch);
   IF r.eot OR (ch = 22X) OR (i+1 >= LEN(str)) THEN EXIT END;
   str[i] := ch; INC(i)
  END
 END;
 str[i] := 0X
END ReadStr;
*)

PROCEDURE WriteCol(VAR w: Texts.Writer; VAR buf, str: ARRAY OF CHAR; col: LONGINT; VAR first: BOOLEAN);
VAR i: LONGINT;
BEGIN
 LOOP
  WHILE (buf[i] # 22X) & (buf[i] # 0X) DO INC(i) END;
  IF buf[i] = 0X THEN EXIT END;
  INC(i);
  IF col = 0 THEN
   IF (buf[i] # 22X) & (buf[i] # 0X) THEN
    IF ~first THEN Texts.WriteString(w, ", ") ELSE first := FALSE END;
    WHILE (buf[i] # 22X) & (buf[i] # 0X) DO
     IF buf[i] < " " THEN Texts.Write(w, " ") ELSE Texts.Write(w, buf[i]) END;
     INC(i)
    END;
    IF str[0] # 0X THEN Texts.WriteString(w, str) END
   END;
   EXIT
  END;
  WHILE (buf[i] # 22X) & (buf[i] # 0X) DO INC(i) END;
  IF buf[i] = 0X THEN EXIT END;
  INC(i);
  DEC(col)
 END
END WriteCol;

PROCEDURE ConvertAddressBook*; (** [col { "," col } ] ^  col = int [str] . *)
CONST Max = 16; BufSize = 1024;
VAR
 s: Texts.Scanner; t: Texts.Text; i, num, beg, end, time: LONGINT; first: BOOLEAN;
 col: ARRAY Max OF RECORD int: LONGINT; str: ARRAY 32 OF CHAR END;
 buf: ARRAY BufSize OF CHAR;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s); num := 0;
 WHILE (s.class = Texts.Int) & (num < Max) DO
  col[num].int := s.i; col[num].str := "";
  Texts.Scan(s);
  IF s.class = Texts.String THEN COPY(s.s, col[num].str); Texts.Scan(s) END;
  IF (s.class = Texts.Char) & (s.c = ",") THEN Texts.Scan(s) END;
  INC(num)
 END;
 IF num = 0 THEN
  REPEAT col[num].int := num; col[num].str := ""; INC(num) UNTIL num = Max
 END;
 Oberon.GetSelection(t, beg, end, time);
 IF time # -1 THEN
  Texts.OpenReader(s, t, beg);
  LOOP
   ReadLine(s, buf);
   IF buf[0] # 22X THEN EXIT END;
   first := TRUE;
   FOR i := 0 TO num-1 DO
    WriteCol(w, buf, col[i].str, col[i].int, first)
   END;
   Texts.WriteLn(w)
  END;
  NEW(t);  Texts.Open(t, "");
  Texts.Append(t, w.buf);
  Oberon.OpenText("", t, 400, 200)
 END
END ConvertAddressBook;

BEGIN
 Texts.OpenWriter(w);
 Kernel.GetClock(time, date);
 seed := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, time) / SYSTEM.VAL(SET, date));
END Binkley.

Binkley.ConvertAddressBook 3 1 5 "(m)" 6 "(h)" 19 "(wm)" 20 "(w)" 9 23 33 ^  Sort.Sort *

Binkley.Color 3 1022 766
Binkley.ColorX 3 1022 766
Binkley.Neutralise
Binkley.FindGadgets ~
Binkley.CheckGadgetAlias ~
Binkley.EditMenu ^
Binkley.FindNames ^
Binkley.FindNames *
Binkley.RandomLine CD.Text
Binkley.ArcFileSizes apps.arc docu.arc eamon.arc gadgets.arc pr3fonts.arc pr6fonts.arc tools.arc tutorial.arc web.arc ~
Binkley.ArcFileSizes srcsys.arc srctools.arc srcweb.arc srcgadgt.arc srcapps.arc ~
Binkley.ArcFileSizes source1.arc source2.arc source3.arc ~
Binkley.ArcFileList source1.arc source2.arc ~
Binkley.ShowTime

Binkley.MapFiles ARM. "ARM.*.Obj" "ARM.*.Pict" "ARM.*.Text" "ARM.*.Data" "ARM.*.Pal" 
 "ARM.*.Tool" "ARM.*.Panel" "ARM.*.Desk" "ARM.*.Scn.Fnt" "ARM.*.Lib" "ARM.*.Sym" 
 "ARM.*.poly" "ARM.BartSimpson.Mod" ~

Binkley.ScanModules2 SYSTEM AosBoot.Mod AosProcessor.Mod AosLocks.Mod AosOut.Mod AosMemory.Mod 
 AosStorage.Mod AosBuffers.Mod AosInterrupts.Mod AosModules.Mod AosTrap.Mod 
 AosTick.Mod AosThreads.Mod AosSMP.Mod ~
Binkley.ScanModules2 SYSTEM AosBoot AosOut AosMemory AosStorage 
 AosInterrupts AosModules AosTick AosThreads AosSMP
 AosClock.Mod AosDisks.Mod Aos.Kernel.Mod AosPCI.Mod AosATADisks.Mod 
 ISOStrings.Mod AosFiles.Mod AosInput.Mod Aos.Files.Mod AosLoader.Mod 
 AosConsole.Mod Aos.Mod AosDisplays.Mod OGLDisplay.Mod CLUTs.Mod 
 AosDisplayPermedia2.Mod AosDisplayLinear.Mod 
 Aos.Modules.Mod Objects.Mod Aos.Display.Mod Aos.V24.Mod Aos.Input.Mod
 Viewers.Mod Fonts.Mod Reals.Mod Texts.Mod Aos.Oberon.Mod MenuViewers.Mod 
 TextFrames.Mod Aos.System.Mod 
~ 

Binkley.ScanModules AosProcessor.Mod AosLocks.Mod AosMemory.Mod ~
 AosStorage.Mod AosBuffers.Mod AosInterrupts.Mod AosExceptions.Mod   
 AosThreads.Mod AosSMP.Mod 
~ 

 Binkley.ScanModules 
ARM.OFW.Mod ARM.Kernel.Mod ARM.NetBase.Mod ARM.NetIP.Mod ARM.NetPorts.Mod ARM.NetUDP.Mod 
ARM.NetTCP.Mod ARM.NetDNS.Mod ARM.CS8900.Mod 
NCFSVolumes.Mod NCFSRamVolumes.Mod CRC32.Mod NCFSNetVolumes.Mod ARM.FileDir.Mod ARM.Files.Mod 
ARM.NCFSRemoteFileDir.Mod ARM.NCFSRemoteFiles.Mod ARM.SoftFloat.Mod ARM.NetSystem0.Mod ARM.Modules.Mod 
Objects.Mod ARM.Display.Mod ARM.V24.Mod ARM.Input.Mod ARM.Reals.Mod ARM.Fonts.Mod Texts.Mod Viewers.Mod Oberon.Mod MenuViewers.Mod TextFrames.Mod ARM.System.Mod ARM.Bitmaps.Mod In.Mod Out.Mod ARM.Pictures.Mod Display3.Mod ARM.Centronics.Mod Printer.Mod Edit.Mod ARM.Effects.Mod Dates.Mod Strings.Mod ARM.NetSystem.Mod Attributes.Mod Links.Mod Printer3.Mod Gadgets.Mod TextGadgets0.Mod TextGadgets.Mod TextFields.Mod Documents.Mod Views.Mod Desktops.Mod TextDocs.Mod Icons.Mod Panels.Mod PSPrinter.Mod LPRPrinter.Mod BasicGadgets.Mod EmptyPrinter.Mod NamePlates.Mod ListRiders.Mod ListGadgets.Mod Finder.Mod ARM.Math.Mod ARM.MathL.Mod RandomNumbers.Mod XYplane.Mod Lists.Mod Clocks.Mod Organizers.Mod ColorWells.Mod Rembrandt0.Mod Rembrandt.Mod RembrandtDocs.Mod ColorTools.Mod Sisiphus.Mod Cards.Mod Solitaire.Mod Streams.Mod TextStreams.Mod BasicFigures.Mod MIME.Mod BTrees.Mod HyperDocs.Mod ARM.NetTools.Mod FTPDocs.Mod Terminals.Mod TerminalFrames.Mod Telnet.Mod TextMail.Mod MineSweeper.Mod TerminalGadgets.Mod ARM.TelnetGadgets.Mod Compress.Mod HTTPDocs0.Mod HTMLDocs.Mod PanelDocs.Mod ListModels.Mod Navigators.Mod Styles.Mod ScriptFrames.Mod Script.Mod V24Log.Mod ARM.V24Gadgets.Mod FTP.Mod RefGadgets.Mod ScrollViews.Mod Columbus.Mod EditTools.Mod Scrollbars.Mod RembrandtTools.Mod BIT.Mod Hex.Mod ARM.Magnifier.Mod HTTPDocs.Mod HTMLForms.Mod HTMLImages.Mod HTMLTables.Mod ARM.Dim3Base.Mod Dim3Paint.Mod Dim3Engine.Mod Dim3Read.Mod Dim3Frames.Mod AsciiCoder.Mod MD5.Mod Mail.Mod ColorModels.Mod XBM.Mod GIF.Mod BMP.Mod ICO.Mod IFF.Mod TGA.Mod PCX.Mod JPEG.Mod UnZip.Mod ASCIITab.Mod Shanghai.Mod Sokoban.Mod ARM.Asteroids.Mod DiffGadgets.Mod Diff.Mod Conversions.Mod HPCalc.Mod Calculator.Mod EditKeys.Mod Calc.Mod Find.Mod ARM.FontEditor.Mod RXA.Mod RX.Mod ARM.Snapshot.Mod Sort.Mod Outlines.Mod Freecell.Mod Spider.Mod Tetris.Mod ProgressMeters.Mod CalculatorGadgets.Mod TimeStamps.Mod FindFile.Mod UUDecoder.Mod Base64.Mod BinHex.Mod ET.Mod Graphics.Mod GraphicFrames.Mod Rectangles.Mod Curves.Mod Splines.Mod Draw.Mod CompressTools.Mod ARM.Miscellaneous.Mod Directories.Mod News.Mod Finger.Mod Gopher.Mod HyperDocTools.Mod Swarm.Mod ARM.OBM.Mod ARM.OBS.Mod ARM.OBT.Mod ARM.OBC.Mod ARM.OBE.Mod ARM.OBH.Mod  ARM.OBA.Mod ARM.ARMCompiler.Mod ARM.ARMBrowser.Mod ARM.ARMDecoder.Mod ARM.TextPopups.Mod ARM.NCFS.Mod ARM.PowerDoc.Mod ColorSystem.Mod Configuration.Mod Native.GfxFonts0.Mod GfxMatrix.Mod GfxMaps.Mod GfxPictures.Mod GfxPaths.Mod GfxRegions.Mod ARM.GfxFonts.Mod Gfx.Mod GfxRaster.Mod GfxPrinter.Mod GfxBuffer.Mod GfxDisplay.Mod ARM.GfxPS.Mod GfxPens.Mod Solver.Mod ARM.Figures.Mod ARM.FigureGadgets.Mod LeoFrames.Mod Leonardo.Mod Leo.Pens.Mod LeoPens.Mod LeoBasic.Mod LeoText.Mod LeoPaths.Mod LeoDraw.Mod Leo.FancyPens.Mod Leo.Captions.Mod Leo.Segments.Mod Leo.Areas.Mod Leo.Shapes.Mod OTInt.Mod OTScan.Mod OType.Mod OTFonts.Mod ARM.Watson0.Mod ARM.Watson.Mod QuotedPrintable.Mod SaveScreen.Mod SaveTiles.Mod SaveParticles.Mod SaveDecay.Mod SaveSisyphus.Mod DayTime.Mod Images.Mod ImageGadgets.Mod ImageDocs.Mod PictImages.Mod BMPImages.Mod JPEGImages.Mod GIFImages.Mod Log.Mod VNCTask.Mod VNCViewers.Mod DES.Mod VNC.Mod VNCViewerDocs.Mod ~

Binkley.ScanModules2 SYSTEM Files FileDir Math Display Fonts Texts Oberon Strings Printer 
 BIT OType Colors Images PictImages 
 GfxMatrix.Mod GfxImages.Mod GfxPaths.Mod GfxRegions.Mod 
 Native.GfxFonts0.Mod GfxFonts.Mod Gfx.Mod GfxRaster.Mod GfxPrinter.Mod
 GfxBuffer.Mod GfxDisplay.Mod GfxPS.Mod GfxOType.Mod Native.GfxPKFonts.Mod 
~ 

Binkley.ScanModules2 SYSTEM Files Display Objects Texts Oberon Out Strings Pictures 
 Colors.Mod Images.Mod PictImages.Mod 
~ 
