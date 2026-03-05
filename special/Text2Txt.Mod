(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Text2Txt; (* pjm *)

(* Simple text formatter for generating DOS-format .txt files. 

Paragraphs in the input text are seperated by carriage returns.
The output text is wrapped to 79 columns by default.
Gadgets (e.g. styles) in the input text are ignored.
Input text in Courier10 font is considered pre-formatted.
A paragraph starting with a single "o" character is formatted as a hanging paragraph.
*)

IMPORT Files, Fonts, Texts, Oberon, In, Out;

VAR
 w: Texts.Writer;

PROCEDURE Read(VAR r: Texts.Reader;  VAR ch: CHAR);
BEGIN
 REPEAT Texts.Read(r, ch) UNTIL r.eot OR (r.lib IS Fonts.Font);
 IF ch >= 7FX THEN
  Out.String("  pos");  Out.Int(Texts.Pos(r), 6);
  Out.String(" char ");  Out.Int(ORD(ch), 1);  Out.Ln
 END
END Read;

(* ReadWord - Read the next word, skipping objects. *)

PROCEDURE ReadWord(VAR r: Texts.Reader;  VAR word: ARRAY OF CHAR;  VAR len: LONGINT;  VAR eol: BOOLEAN);
VAR i: LONGINT;  ch: CHAR;
BEGIN
 i := 0;  REPEAT Read(r, ch) UNTIL r.eot OR (ch # " ");
 WHILE ~r.eot & ((ch # " ") OR (r.lib.name = "Courier10.Scn.Fnt")) & (ch # 0DX) DO
  word[i] := ch;  INC(i);  Read(r, ch)
 END;
 word[i] := 0X;
 eol := (ch = 0DX) OR r.eot;
 len := i
END ReadWord;

PROCEDURE Write(VAR r: Files.Rider;  ch: CHAR);
BEGIN
 IF ch = 9X THEN Files.Write(r, " ");  Files.Write(r, " ")
 ELSIF ch = "_" THEN Files.Write(r, " ")
 ELSE Files.Write(r, ch)
 END
END Write;

(** Text2Txt.Convert from to [width]- Convert an Oberon text into a ASCII text, with formatting. *)

PROCEDURE Convert*;
VAR
 from, to: ARRAY 32 OF CHAR;  text: Texts.Text;  file: Files.File;  col, len, width, i: LONGINT;  in: Texts.Reader;
 word: ARRAY 100 OF CHAR;  out: Files.Rider;  eol, hp: BOOLEAN;
BEGIN
 In.Open;  In.Name(from);  In.Name(to);
 IF In.Done THEN
  In.LongInt(width);  IF ~In.Done THEN width := 79 END;
  Out.String(from);  Out.String(" => ");  Out.String(to);  Out.Ln;
  NEW(text);  Texts.Open(text, from);
  file := Files.New(to);
  IF (text.len # 0) & (file # NIL) THEN
   col := 0;  hp := FALSE;  Texts.OpenReader(in, text, 0);  Files.Set(out, file, 0);
   REPEAT
    ReadWord(in, word, len, eol);
    IF col+len+1 > width THEN (* wrap *)
     Write(out, 0DX);  Write(out, 0AX);  col := 0;
     IF hp THEN Write(out, " ");  Write(out, " ");  INC(col, 2) END
    ELSIF col # 0 THEN (* space *)
     Write(out, " ");  INC(col)
    ELSE (* skip *)
    END;
    IF (col = 0) & (word = "o") THEN hp := TRUE END; (* start hanging paragraph *)
    i := 0;  WHILE i # len DO Write(out, word[i]);  INC(i) END;
    INC(col, len);
    IF eol THEN Write(out, 0DX);  Write(out, 0AX);  col := 0;  hp := FALSE END (* end paragraph *)
   UNTIL in.eot;
   Files.Register(file)
  END
 END
END Convert;

(** Text2Txt.Contents from - Extract table of contents from formatted text. *)

PROCEDURE Contents*;
CONST MaxLine = 100;
VAR
 from: ARRAY 32 OF CHAR;  text: Texts.Text;  in: Texts.Reader;
 line: ARRAY MaxLine OF CHAR;  i: LONGINT;  ch: CHAR;
BEGIN
 In.Open;  In.Name(from);
 IF In.Done THEN
  NEW(text);  Texts.Open(text, from);
  IF text.len # 0 THEN
   Texts.OpenReader(in, text, 0);
   REPEAT
    i := 0;
    REPEAT
     Read(in, ch);
     IF i # MaxLine-1 THEN line[i] := ch;  INC(i) END;
    UNTIL in.eot OR (ch = 0DX);
    line[i] := 0X;
    IF (line[0] >= "0") & (line[0] <= "9") & (line[1] = ".") THEN Texts.WriteString(w, line) END
   UNTIL in.eot;
   NEW(text);  Texts.Open(text, "");
   Texts.Append(text, w.buf);
   Oberon.OpenText("", text, 400, 200)
  END
 END
END Contents;

BEGIN
 Texts.OpenWriter(w)
END Text2Txt.

Text2Txt.Convert Install.Text t
Text2Txt.Contents Install.Text
EditTools.OpenAscii t
Hex.Open t
Mail.Mono *
