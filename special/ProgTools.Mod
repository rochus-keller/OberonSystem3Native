(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE ProgTools; (** portable *) (** PRK **)

IMPORT
 Out, Texts, Oberon, Display, Objects, Files, Fonts, Attributes;


VAR
 Hex: ARRAY 16 OF CHAR;
 i: LONGINT;
 W: Texts.Writer;

PROCEDURE Error (p, msg: ARRAY OF CHAR);
BEGIN
 Out.String (p); Out.String (": "); Out.String (msg); Out.Ln;
END Error;


(** ProgTools.Enum [base] {name} ~ generate an enumeration *)
PROCEDURE Enum*;
 CONST Elems = 6;
 VAR S: Texts.Scanner; W: Texts.Writer; base, cnt: LONGINT;
   M: Oberon.CaretMsg; export: BOOLEAN;
BEGIN
 Texts.OpenScanner (S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan (S);
 Texts.OpenWriter (W);
 IF S.class = Texts.Int THEN base := S.i; Texts.Scan (S) ELSE base := 0 END;
 IF (S.class = Texts.Char) & (S.c = "*") THEN  export := TRUE; Texts.Scan (S) ELSE  export := FALSE  END;
 WHILE ~S.eot & (S.class = Texts.Name) DO
  IF cnt MOD Elems = 0 THEN Texts.Write (W, 9X) END; 
  Texts.WriteString (W, S.s);
  IF export THEN  Texts.Write(W, "*")  END;
  Texts.WriteString (W, " = ");
  Texts.WriteInt (W, base+cnt, 0); Texts.WriteString (W, "; ");
  IF cnt MOD Elems = Elems-1 THEN Texts.WriteLn (W) END;
  INC (cnt); Texts.Scan (S)
 END;
 IF cnt MOD Elems # 0 THEN Texts.WriteLn (W) END;
 M.id := Oberon.get;
 Display.Broadcast (M);
 IF M.text = NIL THEN
  Texts.Append (Oberon.Log, W.buf)
 ELSE
  Texts.Insert (M.text, M.pos, W.buf)
 END
END Enum;

(** ProgTools.DebugList base {name} ~ generate an debuglist  base[name]:="name" *)
PROCEDURE DebugList*;
 VAR S: Texts.Scanner; W: Texts.Writer; base: ARRAY 32 OF CHAR; M: Oberon.CaretMsg; export: BOOLEAN;
  t: Texts.Text; beg, end, time: LONGINT;
BEGIN
 Texts.OpenScanner (S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan (S);
 Texts.OpenWriter (W);
 IF S.class = Texts.Name THEN COPY(S.s, base); Texts.Scan (S) ELSE RETURN END;
 IF (S.class = Texts.Char) & (S.c = "^") THEN
  Oberon.GetSelection(t, beg, end, time);
  IF time = -1 THEN RETURN END;
  Texts.OpenScanner(S, t, beg); Texts.Scan(S)
 ELSE end := MAX(LONGINT)
 END;
 WHILE ~S.eot & (Texts.Pos(S) < end) & ((S.class # Texts.Char)OR(S.c # "~")) DO
  IF S.class = Texts.Name THEN
   Texts.Write(W, 9X);
   Texts.WriteString(W, base); Texts.Write(W, "[");
   Texts.WriteString (W, S.s); Texts.WriteString(W, '] := "');
   Texts.WriteString (W, S.s); Texts.WriteString(W, '";');
   Texts.WriteLn (W)
  END;
  Texts.Scan (S)
 END;
 M.id := Oberon.get;
 Display.Broadcast (M);
 IF M.text = NIL THEN
  Texts.Append (Oberon.Log, W.buf)
 ELSE
  Texts.Insert (M.text, M.pos, W.buf)
 END
END DebugList;

(** ProgTool.ColorFilter (keep|filter) {colnr[=>colnr]} {src => trg} ~ *)
PROCEDURE ColorFilter*;
 VAR cm: ARRAY 256 OF LONGINT; i, j: LONGINT; mode: BOOLEAN;
  T: Texts.Text; R: Texts.Reader; W: Texts.Writer; S: Texts.Scanner; ch: CHAR; fnt: Objects.Library;
  f: Files.File; src: ARRAY 64 OF CHAR;
 
BEGIN
 (* parse parameters *)
 Texts.OpenScanner (S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan (S);
 IF S.class # Texts.Name THEN Error ("ColorFilter", "keep or filter expected"); RETURN
 ELSIF S.s = "filter" THEN FOR i := 0 TO 255 DO cm[i] := i END; mode := TRUE
 ELSIF S.s = "keep" THEN FOR i := 0 TO 255 DO cm[i] := -1 END; mode := FALSE
 ELSE Error ("ColorFilter", "keep or filter expected"); RETURN
 END;
 Texts.Scan (S);
 WHILE S.class = Texts.Int DO
  IF (S.i < 0) OR (S.i > 255) THEN Error ("ColorFilter", "color range is = 0 .. 255")
  ELSE
   i := S.i;
   Texts.Scan (S);
   IF (S.class = Texts.Char) & (S.c = "=") THEN
    Texts.Scan (S);
    IF (S.class = Texts.Char) & (S.c = ">") THEN
     Texts.Scan (S);
     IF (S.class # Texts.Int) OR (S.i < 0) OR (S.i > 255) THEN Error ("ColorFilter", "color range is = 0 .. 255")
     ELSE cm[i] := S.i; Texts.Scan (S)
     END
    ELSE Error ("ColorFilter", "=> expected")
    END
   ELSIF mode THEN cm[i] := -1
   ELSE cm[i] := i
   END
  END
 END;
 
 WHILE S.class = Texts.Name DO 
  IF S.class # Texts.Name THEN Error ("ColorFilter", "source file name expected"); RETURN END;
  NEW (T); Texts.Open (T, S.s); COPY (S.s, src);
  IF T.len = 0 THEN Error ("ColorFilter", "Source text empty or non existent"); RETURN END;
  Texts.OpenReader (R, T, 0);
  
  Texts.Scan (S);
  IF (S.class # Texts.Char) & (S.c # "=") THEN Error ("ColorFilter", "=> expected"); RETURN END;
  Texts.Scan (S);
  IF (S.class # Texts.Char) & (S.c # ">") THEN Error ("ColorFilter", "=> expected"); RETURN END;
  Texts.Scan (S);
  IF S.class # Texts.Name THEN Error ("ColorFilter", "target file name expected"); RETURN END;
  Out.String ("ColorFilter: "); Out.String (src); Out.String (" => "); Out.String (S.s); Out.Ln;
  Texts.OpenWriter (W); i := -1; fnt := NIL;
  Texts.Read (R, ch);
  REPEAT
   IF cm[R.col] # -1 THEN
    IF R.col # i THEN Texts.SetColor (W, SHORT(SHORT(cm[R.col]))); i := R.col END;
    IF R.lib # fnt THEN Texts.SetFont (W, R.lib); fnt := R.lib END;
    Texts.Write (W, ch)
   END;
   Texts.Read (R, ch);
  UNTIL R.eot;
  NEW (T); Texts.Open (T, ""); Texts.Append (T, W.buf);
  f := Files.New (S.s); Texts.Store (T, f, 0, i); Files.Register (f); Files.Close (f);
  Texts.Scan (S)
 END;
END ColorFilter;

(** ProgTools.Comment [limiter color] - Comment the selected text *)
PROCEDURE Comment*;
 VAR W: Texts.Writer; S: Texts.Scanner; col: SHORTINT; M: Oberon.SelectMsg;
BEGIN
 (* parse parameters *)
 Texts.OpenScanner (S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan (S);
 IF S.class = Texts.Int THEN col := SHORT(SHORT(S.i))
 ELSE col := 15
 END;
 M.id := Oberon.get; M.F := NIL; M.time := -1; M.text := NIL;
 Display.Broadcast (M);
 IF M.time > 0 THEN
  Texts.OpenWriter (W); Texts.SetColor (W, col); Texts.WriteString (W, "*)"); Texts.Insert (M.text, M.end, W.buf);
  Texts.OpenWriter (W); Texts.SetColor (W, col); Texts.WriteString (W, "(*"); Texts.Insert (M.text, M.beg, W.buf);
  M.id := Oberon.set; (*M.frame := NIL; M.text := text; M.beg := beg;*)  M.end := M.end+4;
  Display.Broadcast (M);
 END
END Comment;

(** ProgTools.Uncomment - Remove the comments *)
PROCEDURE Uncomment*;
 VAR text: Texts.Text; beg, end, time: LONGINT; r: Texts.Reader; ch: CHAR;
BEGIN
 Oberon.GetSelection (text, beg, end, time);
 IF time > 0 THEN
  Texts.OpenReader (r, text, beg);
  Texts.Read (r, ch); IF ch # "(" THEN Out.String ("Uncomment, wrong selection"); RETURN END;
  Texts.Read (r, ch); IF ch # "*" THEN Out.String ("Uncomment, wrong selection"); RETURN END;
  Texts.OpenReader (r, text, end-2);
  Texts.Read (r, ch); IF ch # "*" THEN Out.String ("Uncomment, wrong selection"); RETURN END;
  Texts.Read (r, ch); IF ch # ")" THEN Out.String ("Uncomment, wrong selection"); RETURN END;
  Texts.Delete (text, end-2, end);
  Texts.Delete (text, beg, beg+2);
 END
END Uncomment;

(** ProgTools.FindLine n[--m] - Find and mark the n-th line [to the m-th line] in the marked text *)
PROCEDURE FindLine*;
VAR  t: Texts.Text; f: Display.Frame; S: Attributes.Scanner; R: Texts.Reader; line, line1: LONGINT; ch: CHAR;
 M: Oberon.CaretMsg; SM: Oberon.SelectMsg;
BEGIN
  (*get line number*)
 Attributes.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 REPEAT  Attributes.Scan(S)  UNTIL S.eot OR (S.class = Attributes.Int);
 IF S.class # Attributes.Int THEN  RETURN  END;
 line := S.i-1;
 IF S.nextCh = "-" THEN
  Attributes.Scan(S); Attributes.Scan(S); line1 := -S.i-line
 ELSE line1 := 1
 END;
  (*find line*)
 t := Oberon.MarkedText(); ASSERT(t # NIL);
 f := Oberon.MarkedFrame();
 Texts.OpenReader(R, t, 0);
 WHILE (line > 0) & ~R.eot DO
  Texts.Read(R, ch);
  IF ch = 0DX THEN  DEC(line)  END
 END;
 IF ~R.eot THEN
  SM.beg := Texts.Pos(R);
  REPEAT
   Texts.Read(R, ch);
   IF ch = 0DX THEN DEC(line1) END;
  UNTIL R.eot OR (line1 = 0);
  SM.end := Texts.Pos(R);
   (*set caret and select line*)
  M.id := Oberon.set; M.F := f; M.car := f; M.text := t; M.pos := SM.beg; Display.Broadcast(M);
  SM.id := Oberon.set; SM.F := f; SM.sel := f; SM.time := -1; SM.text := t; Display.Broadcast(SM);
 END;
END FindLine;


(** ProgTools.Surround begin end - Surround the selected text, with the specified strings. *)
PROCEDURE Surround*;
 VAR W: Texts.Writer; S: Texts.Scanner; M: Oberon.SelectMsg;  begin: ARRAY 64 OF CHAR;
BEGIN
 (* parse parameters *)
 Texts.OpenScanner (S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan (S);
 IF (S.class IN {Texts.Name,Texts.String}) THEN
  COPY(S.s, begin);  Texts.Scan(S);
  IF (S.class IN {Texts.Name,Texts.String}) THEN
   M.id := Oberon.get; M.F := NIL; M.time := -1; M.text := NIL;
   Display.Broadcast (M);
   IF M.time > 0 THEN
    Texts.OpenWriter (W); Texts.WriteString (W, S.s); Texts.Insert (M.text, M.end, W.buf);
    Texts.OpenWriter (W); Texts.WriteString (W, begin); Texts.Insert (M.text, M.beg, W.buf);
    M.id := Oberon.set; (*M.frame := NIL; M.text := text; M.beg := beg;*)  M.end := M.end+4;
    Display.Broadcast (M)
   END
  END
 END
END Surround;

PROCEDURE HexDump*;
VAR S: Texts.Scanner; f: Files.File; r: Files.Rider; buf: ARRAY 16 OF CHAR; i, l: LONGINT; t: Texts.Text;
BEGIN
 Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
 IF S.class = Texts.Name THEN
  f := Files.Old(S.s);
  IF f # NIL THEN
   Texts.SetFont(W, Fonts.This("Courier10.Scn.Fnt")); l := Files.Length(f);
   Files.Set(r, f, 0);
   WHILE ~r.eof DO
    Texts.WriteHex(W, Files.Pos(r)); Texts.WriteString(W, ":  ");
    Files.ReadBytes(r, buf, 16);
    FOR i := 0 TO 15 DO
     IF (l-i) > 0 THEN
      Texts.Write(W, Hex[ORD(buf[i]) DIV 16 MOD 16]);
      Texts.Write(W, Hex[ORD(buf[i]) MOD 16]);
      Texts.WriteString(W, " ")
     ELSE
      Texts.WriteString(W, "   ")
     END;
    END;
    FOR i := 0 TO 15 DO
     IF (l-i <= 0) THEN Texts.Write(W, " ")
     ELSIF (buf[i]<20X) OR (buf[i]> 7EX) THEN Texts.Write(W, ".")
     ELSE Texts.Write(W, buf[i])
     END
    END;
    DEC(l, 16);
    Texts.WriteLn(W)
   END;
   NEW(t); Texts.Open(t, ""); Texts.Append(t, W.buf); Oberon.OpenText("", t, 640, 400)
  END;
 END;
END HexDump;

PROCEDURE End*;
 VAR entry: ARRAY 64 OF RECORD name: ARRAY 32 OF CHAR; pos: LONGINT  END; 
  nr: LONGINT; S: Texts.Scanner; t: Texts.Text; beg, end, time: LONGINT; W: Texts.Writer;
BEGIN
 Oberon.GetSelection(t, beg, end, time);
 IF time # -1 THEN
  nr:=0; Texts.OpenWriter(W);
  Texts.OpenScanner(S, t, beg); Texts.Scan(S);
  WHILE ~S.eot & (Texts.Pos(S) < end) DO
   IF (S.class = Texts.Name) & (S.s = "PROCEDURE") THEN
    Texts.Scan(S);
    IF S.class = Texts.Name THEN
     COPY(S.s, entry[nr].name);
     time:=S.line;
     REPEAT
      entry[nr].pos:=Texts.Pos(S); Texts.Scan(S)
     UNTIL S.line#time;
     INC(nr)
    END
   END
  END;
  WHILE nr > 0 DO
   DEC(nr);
   Texts.Write(W, 9X); Texts.WriteString(W, "END "); Texts.WriteString(W, entry[nr].name);
   Texts.Write(W, ";"); Texts.WriteLn(W); Texts.WriteLn(W);
   Texts.Insert(t, entry[nr].pos, W.buf)
  END
 END;
END End;

PROCEDURE ChangeFont*;
VAR T: Texts.Text; S: Texts.Scanner; f: Fonts.Font;
BEGIN
 Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
 f := Fonts.This(S.s); T := Oberon.MarkedText();
 IF (f # NIL) & (T # NIL) THEN   Texts.ChangeLooks(T, 0, T.len, {0}, f, 0, 0)  END
END ChangeFont;


BEGIN
 Texts.OpenWriter(W);
 FOR i := 0 TO 9 DO  Hex[i] := CHR(ORD("0")+i)  END;
 FOR i := 0 TO 5 DO  Hex[i+10] := CHR(ORD("A")+i)  END;
END ProgTools.


ProgTools.Enum
 a b c d e ~
 

 a = 0; b = 1; c = 2; d = 3; e = 4; 

ProgTools.ColorFilter filter 03 08 CC.Parser.2.Mod => t ~
ProgTools.ColorFilter keep 03 08 CC.Parser.2.Mod => t ~
ProgTools.ColorFilter filter 03=>01 08 CC.Parser.2.Mod => t ~
ProgTools.ColorFilter keep 03=>01 08 CC.Parser.2.Mod => t ~

ProgTools.Comment
ProgTools.Comment 01

ProgTools.Uncomment


ProgTools.End