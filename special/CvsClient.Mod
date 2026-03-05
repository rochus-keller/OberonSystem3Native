(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

 MODULE CvsClient; (* pjm   *)

(** Oberon client for CVS. *)

IMPORT Files, Objects, Fonts, Reals, Texts, Display, Oberon;

CONST
 Version = "CvsClient0.2";
 Ext = ".txt";

VAR
 w: Texts.Writer;
 enumR: Files.Rider;
 enumObj: Objects.Object;
 hex: ARRAY 17 OF CHAR;
 isStrCh, isPlainCh: ARRAY 256 OF BOOLEAN;
 init: LONGINT;

(* Append "from" to "to"; trap on overflow. *)

PROCEDURE Append(from: ARRAY OF CHAR; VAR to: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 j := 0; WHILE to[j] # 0X DO INC(j) END;
 i := 0; WHILE from[i] # 0X DO to[j] := from[i]; INC(i); INC(j) END;
 to[j] := 0X
END Append;

(* Various ASCII file write procedures. *)

PROCEDURE WriteLn(VAR r: Files.Rider);
BEGIN
 Files.Write(r, 0AX)
END WriteLn;

PROCEDURE WriteHexByte(VAR r: Files.Rider; x: CHAR);
BEGIN
 Files.Write(r, hex[ORD(x) DIV 10H]);
 Files.Write(r, hex[ORD(x) MOD 10H])
END WriteHexByte;

PROCEDURE WriteHex(VAR r: Files.Rider; x: LONGINT);
BEGIN
 WriteHexByte(r, CHR(x DIV 1000000H MOD 100H));
 WriteHexByte(r, CHR(x DIV 10000H MOD 100H));
 WriteHexByte(r, CHR(x DIV 100H MOD 100H));
 WriteHexByte(r, CHR(x MOD 100H))
END WriteHex;

(* Write a quoted character. *)

PROCEDURE WriteQuote(VAR r: Files.Rider; x: CHAR);
BEGIN
 Files.Write(r, "%"); WriteHexByte(r, x)
END WriteQuote;

(* Write a character, quoting special characters. *)

PROCEDURE Write(VAR r: Files.Rider; x: CHAR);
BEGIN
 IF x = 0DX THEN
  WriteLn(r)
 ELSIF (x = 9X) OR (x >= 20X) & (x <= 7EX) & (x # "%") THEN
  Files.Write(r, x)
 ELSE
  WriteQuote(r, x)
 END
END Write;

(* Write a string, quoting special characters. *)

PROCEDURE WriteString(VAR r: Files.Rider; s: ARRAY OF CHAR);
VAR i: LONGINT; ch: CHAR;
BEGIN
 i := 0;
 LOOP
  ch := s[i];
  IF ch = 0X THEN EXIT END;
  IF isStrCh[ORD(ch)] THEN
   Files.Write(r, ch)
  ELSE
   WriteQuote(r, ch)
  END;
  INC(i)
 END
END WriteString;

(* Write the escape sequence. *)

PROCEDURE WriteEsc(VAR r: Files.Rider);
BEGIN
 Files.Write(r, "%"); Files.Write(r, "!")
END WriteEsc;

(* Enumerator for WriteAttr. *)

PROCEDURE EnumAttr(name: ARRAY OF CHAR);
VAR msg: Objects.AttrMsg; high, low: LONGINT;
BEGIN
 msg.res := -1; msg.id := Objects.get; COPY(name, msg.name);
 enumObj.handle(enumObj, msg);
 IF (msg.res >= 0) & (msg.class # Objects.Inval) THEN
  Write(enumR, ","); WriteString(enumR, name); Write(enumR, "=");
  CASE msg.class OF
   Objects.String:
    Write(enumR, 22X); WriteString(enumR, msg.s); Write(enumR, 22X)
   |Objects.Int:
    Write(enumR, "i"); WriteHex(enumR, msg.i)
   |Objects.Real:
    Write(enumR, "r"); WriteHex(enumR, Reals.Int(msg.x))
   |Objects.LongReal:
    Write(enumR, "R"); Reals.IntL(msg.y, high, low);
    WriteHex(enumR, high); WriteHex(enumR, low)
   |Objects.Char:
    Write(enumR, "c"); WriteHexByte(enumR, msg.c)
   |Objects.Bool:
    IF msg.b THEN Write(enumR, "T") ELSE Write(enumR, "F") END
  END
 END
END EnumAttr;

(* Write the attributes of an object. *)

PROCEDURE WriteAttr(VAR r: Files.Rider; obj: Objects.Object);
VAR msg: Objects.AttrMsg;
BEGIN
 msg.res := -1; msg.id := Objects.enum; msg.Enum := EnumAttr;
 enumObj := obj;
 Files.Set(enumR, Files.Base(r), Files.Pos(r));
 obj.handle(obj, msg);
 Files.Set(r, Files.Base(r), Files.Pos(enumR));
 Files.Set(enumR, NIL, 0);
 enumObj := NIL
END WriteAttr;

(* Get string attribute from an object. *)

PROCEDURE GetStr(obj: Objects.Object; name: ARRAY OF CHAR; VAR val: ARRAY OF CHAR);
VAR msg: Objects.AttrMsg;
BEGIN
 msg.res := -1; msg.id := Objects.get; COPY(name, msg.name);
 obj.handle(obj, msg);
 IF (msg.res >= 0) & (msg.class = Objects.String) THEN
  COPY(msg.s, val)
 ELSE
  val[0] := 0X
 END
END GetStr;

(* Check for objects that can be stored losslessly (no warning generated for these). *)

PROCEDURE SimpleObj(VAR gen: ARRAY OF CHAR): BOOLEAN;
BEGIN
 RETURN (gen = "TextGadgets.NewStyleProc") OR (gen = "TimeStamps.New") OR (gen = "TextGadgets.NewControl")
END SimpleObj;

(* Convert a text to encoded ASCII file format.  "lost" returns the number of objects converted with loss. *)

PROCEDURE ExportText(t: Texts.Text; VAR r: Files.Rider; VAR lost: LONGINT);
VAR
 tr: Texts.Reader; lib: Objects.Library; obj: Objects.Object;
 vofs, col: SHORTINT; ch: CHAR; gen: ARRAY 64 OF CHAR;
BEGIN
 lost := 0;
 lib := Fonts.Default; vofs := 0; col := Display.FG;
 WriteEsc(r); WriteString(r, "Encoded"); Write(r, ","); WriteString(r, Version); WriteLn(r);
 Texts.OpenReader(tr, t, 0);
 Texts.Read(tr, ch);
 WHILE ~tr.eot DO
  IF ~((tr.lib = lib) & (tr.col = col) & (tr.voff = vofs)) THEN (* attribute change or object *)
   IF tr.lib IS Fonts.Font THEN (* attribute change *)
    IF (tr.lib = lib) & (tr.voff = vofs) THEN (* only color change *)
     lib := tr.lib; col := tr.col; vofs := tr.voff;
     WriteEsc(r); WriteString(r, "Color"); Write(r, ","); WriteHexByte(r, CHR(col));
     WriteLn(r); Write(r, ch)
    ELSE
     lib := tr.lib; col := tr.col; vofs := tr.voff;
     WriteEsc(r); WriteString(r, "Font"); Write(r, ","); WriteString(r, lib.name); Write(r, ",");
     WriteHexByte(r, CHR(col)); Write(r, ","); WriteHexByte(r, CHR(vofs));
     WriteLn(r); Write(r, ch)
    END
   ELSE (* object *)
    tr.lib.GetObj(tr.lib, ORD(ch), obj);
    GetStr(obj, "Gen", gen);
    WriteEsc(r); WriteString(r, "Obj"); Write(r, ","); WriteString(r, gen);
    WriteAttr(r, obj); WriteLn(r);
    IF ~SimpleObj(gen) THEN INC(lost) END
   END
  ELSE
   Write(r, ch)
  END;
  Texts.Read(tr, ch)
 END
END ExportText;

(** Export Oberon texts to ASCII file format. *)

PROCEDURE Export*; (** { text ["=>" file] } ~ *)
VAR
 t: Texts.Text; r: Files.Rider; lost, errors, files: LONGINT; s: Texts.Scanner;
 in, out: ARRAY 64 OF CHAR;
BEGIN
 files := 0; errors := 0;
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
 WHILE s.class IN {Texts.Name, Texts.String} DO
  COPY(s.s, in); Texts.Scan(s);
  IF (s.class = Texts.Char) & (s.c = "=") THEN
   Texts.Scan(s);
   IF (s.class = Texts.Char) & (s.c = ">") THEN Texts.Scan(s) ELSE s.class := Texts.Inval END;
   IF s.class IN {Texts.Name, Texts.String} THEN
    COPY(s.s, out); Texts.Scan(s)
   ELSE
    s.class := Texts.Inval
   END
  ELSE
   COPY(in, out); Append(Ext, out)
  END;
  IF s.class # Texts.Inval THEN
   INC(files); Texts.WriteString(w, in);
   NEW(t); Texts.Open(t, in);
   IF t.len # 0 THEN
    Texts.WriteString(w, " => "); Texts.WriteString(w, out);
    Files.Set(r, Files.New(out), 0);
    IF Files.Base(r) # NIL THEN
     ExportText(t, r, lost);
     Files.Register(Files.Base(r));
     IF lost # 0 THEN
      Texts.WriteString(w, " lost "); Texts.WriteInt(w, lost, 1);
      Texts.WriteString(w, " object(s)"); INC(errors)
     END
    ELSE
     Texts.WriteString(w, " create error"); INC(errors)
    END
   ELSE
    Texts.WriteString(w, " empty, skipped"); INC(errors)
   END
  ELSE
   Texts.WriteString(w, "Syntax error")
  END;
  Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf)
 END;
 IF (files > 1) & (errors # 0) THEN
  Texts.WriteInt(w, errors, 1); Texts.WriteString(w, " error(s)");
  Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf)
 END
END Export;

PROCEDURE IsHexChar(ch: CHAR): BOOLEAN;
BEGIN
 RETURN ((ch >= "0") & (ch <= "9")) OR ((CAP(ch) >= "A") & (CAP(ch) <= "F"))
END IsHexChar;

PROCEDURE HexVal(ch: CHAR): LONGINT;
BEGIN
 IF (ch >= "0") & (ch <= "9") THEN
  RETURN ORD(ch)-ORD("0")
 ELSIF (CAP(ch) >= "A") & (CAP(ch) <= "F") THEN
  RETURN ORD(CAP(ch))-ORD("A")+10
 ELSE
  HALT(99)
 END
END HexVal;

PROCEDURE GenObject(gen: ARRAY OF CHAR): Objects.Object;
VAR obj: Objects.Object; res: INTEGER;
BEGIN
 Objects.NewObj := NIL;
 Oberon.Call(gen, Oberon.Par, FALSE, res);
 obj := Objects.NewObj; Objects.NewObj := NIL;
 RETURN obj
END GenObject;

PROCEDURE ImportText(VAR r: Files.Rider; t: Texts.Text): BOOLEAN;
VAR b: Texts.Writer; i: LONGINT; ch: CHAR; ok: BOOLEAN; s: ARRAY 64 OF CHAR;

 PROCEDURE Error(msg: ARRAY OF CHAR);
 BEGIN
  Texts.WriteString(w, msg); Texts.WriteString(w, " at ");
  Texts.WriteInt(w, Files.Pos(r), 1); ok := FALSE
 END Error;

 PROCEDURE ReadHex2(VAR x: LONGINT);
 BEGIN
  x := 0;
  IF IsHexChar(ch) THEN
   x := HexVal(ch)*10H; Files.Read(r, ch);
   IF IsHexChar(ch) THEN
    INC(x, HexVal(ch)); Files.Read(r, ch)
   ELSE
    Error("hexadecimal character expected")
   END
  ELSE
   Error("hexadecimal character expected")
  END
 END ReadHex2;

 PROCEDURE ReadHInt(VAR x: LONGINT);
 VAR i, j: LONGINT;
 BEGIN
  i := 0; x := 0;
  WHILE (i # 4) & ok DO
   ReadHex2(j); x := x * 100H + j;
   INC(i)
  END
 END ReadHInt;
 
 PROCEDURE ReadTextAttr; (* "%!Font," already read *)
 VAR col, vofs: LONGINT; font: Fonts.Font;
 BEGIN
  ReadString(s);
  IF (s # "") & (ch = ",") THEN
   Files.Read(r, ch); ReadHex2(col);
   IF ok THEN
    IF ch = "," THEN
     Files.Read(r, ch); ReadHex2(vofs);
     IF ok THEN
      IF ch = 0AX THEN
       Files.Read(r, ch);
       font := Fonts.This(s);
       IF font # NIL THEN
        Texts.SetFont(b, font);
        Texts.SetOffset(b, SHORT(SHORT(vofs)));
        Texts.SetColor(b, SHORT(SHORT(col)))
       ELSE
        Error("font not found")
       END
      ELSE
       Error("LF expected")
      END
     END
    ELSE
     Error("',' expected")
    END
   END
  ELSE
   Error("',' expected")
  END
 END ReadTextAttr;
 
 PROCEDURE ReadColor; (* "%!Color," already read *)
 VAR col: LONGINT;
 BEGIN
  ReadHex2(col);
  IF ok THEN
   IF ch = 0AX THEN
    Files.Read(r, ch);
    Texts.SetColor(b, SHORT(SHORT(col)))
   ELSE
    Error("LF expected")
   END
  END
 END ReadColor;
 
 PROCEDURE ReadObj; (* "%!Obj," already read *)
 VAR obj: Objects.Object; low, high: LONGINT; msg: Objects.AttrMsg;
 BEGIN
  ReadString(s); obj := GenObject(s);
  IF obj # NIL THEN
   WHILE (ch = ",") & ok DO
    Files.Read(r, ch); ReadString(s); COPY(s, msg.name);
    IF msg.name # "" THEN
     IF ch = "=" THEN
      Files.Read(r, ch);
      IF ch = 22X THEN (* astr *)
       msg.class := Objects.String;
       Files.Read(r, ch); ReadString(msg.s);
       IF ch = 22X THEN Files.Read(r, ch) ELSE Error('" expected') END
      ELSIF ch = "i" THEN (* aint *)
       msg.class := Objects.Int; Files.Read(r, ch); ReadHInt(msg.i)
      ELSIF ch = "r" THEN
       msg.class := Objects.Real; Files.Read(r, ch); ReadHInt(low); msg.x := Reals.Real(low)
      ELSIF ch = "R" THEN
       msg.class := Objects.LongReal; Files.Read(r, ch); ReadHInt(high); ReadHInt(low);
       msg.y := Reals.RealL(high, low)
      ELSIF ch = "c" THEN
       msg.class := Objects.Char; Files.Read(r, ch); ReadHex2(low); msg.c := CHR(low)
      ELSIF (ch = "T") OR (ch = "F") THEN
       msg.class := Objects.Bool; msg.b := (ch = "T"); Files.Read(r, ch)
      ELSE
       Error("attribute value expected")
      END;
      IF ok THEN
       msg.id := Objects.set; msg.res := -1;
       obj.handle(obj, msg);
       IF msg.res < 0 THEN
        Append(" attribute set error", s); Error(s)
       END
      END
     ELSE
      Error("= expected")
     END
    ELSE
     Error("attribute name expected")
    END
   END;
   IF ok THEN
    IF ch = 0AX THEN Files.Read(r, ch) ELSE Error("LF expected") END
   END;
   IF ok THEN Texts.WriteObj(b, obj) END
  ELSE
   Append(" object not found", s); Error(s)
  END
 END ReadObj;

 PROCEDURE ReadString(VAR s: ARRAY OF CHAR);
 VAR i, x: LONGINT;
 BEGIN
  i := 0;
  LOOP
   (*Texts.Write(w, "("); Texts.WriteInt(w, ORD(ch), 1); Texts.Write(w, ")");*)
   IF r.eof OR (i = LEN(s)-1) OR ~ok THEN EXIT END;
   IF ch = "%" THEN
    Files.Read(r, ch);
    IF IsHexChar(ch) THEN (* quoted *)
     ReadHex2(x); ch := CHR(x)
    ELSE
     Error("hexadecimal character expected")
    END
   ELSIF ~isStrCh[ORD(ch)] THEN
    EXIT
   ELSE
    (* ok *)
   END;
   s[i] := ch; INC(i); Files.Read(r, ch)
  END;
  (*Texts.Write(w, "["); Texts.WriteString(w, s); Texts.Write(w, "]");*)
  s[i] := 0X
 END ReadString;
 
 PROCEDURE ReadHeader;
 BEGIN
  Files.Read(r, ch); s[0] := ch; Files.Read(r, ch); s[1] := ch; s[2] := 0X;
  IF s = "%!" THEN
   Files.Read(r, ch); ReadString(s);
   IF s = "Encoded" THEN
    IF ch = "," THEN
     Files.Read(r, ch); ReadString(s);
     IF s = Version THEN
      IF ch = 0AX THEN
       Files.Read(r, ch)
      ELSE
       Error("LF expected")
      END
     ELSE
      Error("incompatible version")
     END
    ELSE
     Error("',' expected")
    END
   ELSE
    Error("'Encoded' expected")
   END
  ELSE
   Error("%! expected")
  END
 END ReadHeader;
 
BEGIN
 ok := TRUE; ReadHeader;
 IF ok THEN
  Texts.OpenWriter(b);
  WHILE ~r.eof & ok DO
   IF ch = "%" THEN (* quoted or textattr or obj *)
    Files.Read(r, ch);
    IF ch = "!" THEN (* textattr or color or obj *)
     Files.Read(r, ch); ReadString(s);
     IF ch = "," THEN
      Files.Read(r, ch);
      IF s = "Font" THEN (* textattr *)
       ReadTextAttr
      ELSIF s = "Color" THEN (* color *)
       ReadColor
      ELSIF s = "Obj" THEN (* obj *)
       ReadObj
      ELSE
       Error("unknown keyword")
      END
     ELSE
      Error("',' expected")
     END
    ELSIF IsHexChar(ch) THEN (* quoted *)
     ReadHex2(i); Texts.Write(b, CHR(i))
    ELSE
     Error("unexpected character")
    END
   ELSIF isPlainCh[ORD(ch)] THEN
    IF ch = 0AX THEN Texts.WriteLn(b) ELSE Texts.Write(b, ch) END;
    Files.Read(r, ch)
   ELSE
    Error("plain character expected")
   END
  END;
  Texts.Append(t, b.buf)
 END;
 RETURN ok
END ImportText;

(** Import Oberon texts from ASCII file format. *)

PROCEDURE Import*; (** { file ["=>" text] } ~ *)
VAR
 t: Texts.Text; r: Files.Rider; i, j: LONGINT; f: Files.File; s: Texts.Scanner;
 in, out: ARRAY 64 OF CHAR;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
 WHILE s.class IN {Texts.Name, Texts.String} DO
  COPY(s.s, in); Texts.Scan(s);
  IF (s.class = Texts.Char) & (s.c = "=") THEN
   Texts.Scan(s);
   IF (s.class = Texts.Char) & (s.c = ">") THEN Texts.Scan(s) ELSE s.class := Texts.Inval END;
   IF s.class IN {Texts.Name, Texts.String} THEN
    COPY(s.s, out); Texts.Scan(s)
   ELSE
    s.class := Texts.Inval
   END
  ELSE
   out := Ext;
   i := 0; WHILE in[i] # 0X DO INC(i) END;
   j := 0; WHILE out[j] # 0X DO INC(j) END;
   WHILE (i # 0) & (j # 0) & (in[i] = out[j]) DO DEC(i); DEC(j) END;
   IF (i # 0) & (j = 0) THEN (* Ext occurs at end of in *)
    COPY(in, out); out[i] := 0X (* chop off Ext *)
   ELSE
    COPY(in, out); Append(".Text", out)
   END
  END;
  IF s.class # Texts.Inval THEN
   Texts.WriteString(w, in);
   Files.Set(r, Files.Old(in), 0);
   IF Files.Base(r) # NIL THEN
    Texts.WriteString(w, " => "); Texts.WriteString(w, out); Texts.Write(w, " ");
    f := Files.New(out);
    IF f # NIL THEN
     NEW(t); Texts.Open(t, "");
     IF ImportText(r, t) THEN
      Texts.Store(t, f, 0, i); (* ignore i *) (* what about text document? *)
      Files.Register(f)
     END
    ELSE
     Texts.WriteString(w, " create error")
    END
   ELSE
    Texts.WriteString(w, " not found, skipped")
   END
  ELSE
   Texts.WriteString(w, "Syntax error")
  END;
  Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf)
 END
END Import;

BEGIN
 Texts.OpenWriter(w);
 hex := "0123456789ABCDEF";
  (* plain characters *)
 FOR init := 0 TO 1FH DO isPlainCh[init] := FALSE END;
 isPlainCh[9] := TRUE; isPlainCh[0AH] := TRUE;
 FOR init := 20H TO 7EH DO isPlainCh[init] := TRUE END;
 isPlainCh[25H] := FALSE;
 FOR init := 7FH TO 0FFH DO isPlainCh[init] := FALSE END;
  (* string characters *)
 FOR init := 0 TO 20H DO isStrCh[init] := FALSE END;
 FOR init := 21H TO 7EH DO isStrCh[init] := TRUE END;
 isStrCh[22H] := FALSE; isStrCh[25H] := FALSE; isStrCh[2CH] := FALSE; isStrCh[3DH] := FALSE;
 FOR init := 7FH TO 0FFH DO isStrCh[init] := FALSE END
END CvsClient.

(*
Encoded file format

file = "%!Encoded," version 0AX { plain | quoted | textattr | color | obj } .
version = "CvsClient0.2" .
plain =  9X | 0AX | 20X..24X | 26X..7EX .
quoted = "%" hex2 .
hex2 = hex hex .
hex = "0".."9" | "A".."F" .
textattr = "%!Font," font "," col "," vofs 0AX .
color = "%!Color," col 0AX .
font = str .
col = hex2 .
vofs = hex2 .
str = { 21X | 23X..24X | 26X..2BX | 2DX..3CX | 3EX..7EX | quoted } .
obj = "%!Obj," gen { "," objattr } 0AX .
gen = str .
objattr = name "=" val .
name = str .
val = astr | aint | areal | alongreal | achar | abool .
astr = 22X str 22X .
aint = "i" hint .
areal = "r" hint .
alongreal = "R" hint hint .
achar = "c" hex2 .
abool = "T" | "F" .
hint = hex2 hex2 hex2 hex2 .

Notes:
o CR are converted to LF during encoding, and vice versa when decoding.
o The words "Encoded" and "Font" are not allowed as generator names.
o The exporter always generates a "plain" or "quoted" after "attr".

Known issues:
o Most object state is lost during conversion (except for published attributes).
o E.g. Export does not save the state of a TimeStamp gadget (it is not available as an attribute).
o Export ignores the attachments (attributes and links) of a TextDoc.
o Import creates a plain text file, not a TextDoc.
o Export may create too large names for file system due to added .txt suffix.
*)

CvsClient.Export CvsClient.Mod ~

EditTools.OpenUnix CvsClient.Mod.txt ~

CvsClient.Import CvsClient.Mod.txt => Temp.Text ~
