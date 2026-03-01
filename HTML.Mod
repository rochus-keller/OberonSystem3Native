(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE HTML; (** portable *) (* jm 26.8.94 *)

IMPORT
 Files, Objects, Texts, Oberon, Out;

CONST
(* possible values of the variable typ denoting the paragraph type *)
 para = 0;   (* Normal paragraph in xxx12.Scn.Fnt or xxx12i.Scn.Fnt *)
        (* Paragraphs are delimited by one or more empty lines *)
 title = 1;    (* Title when first character is red *)
 heading = 2;   (* Heading when in xxx12b.Scn.Fnt *)
 bullet = 3;    (* Bullet when "*" is first character on a line *)
 line = 4;    (* Horizontal ruler when "-" is first character on a line *)
 pre = 5;    (* pre-formatted when in xxx10.Scn.Fnt *)

 tab = 09X;
 
 DocHeader = TRUE; (* include document header comment *)
 BodyColor = TRUE; (* set body color - HTML 4-specific *)

VAR
 out: Files.Rider;
 italic: BOOLEAN;
 sep: CHAR;

PROCEDURE S(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
 i := 0;
 WHILE s[i] # 0X DO Files.Write(out, s[i]); INC(i) END
END S;

PROCEDURE C(ch: CHAR); BEGIN Files.Write(out, ch) END C;

PROCEDURE L; BEGIN Files.Write(out, sep); END L;

(* Check if font matches type.  type = digit { digit } ("." | "b" | "i"). *)
PROCEDURE MatchFont(font: ARRAY OF CHAR;  type: ARRAY OF CHAR): BOOLEAN;
VAR i, j: LONGINT;
BEGIN
 i := 0;
 WHILE (font[i] # 0X) & ((font[i] < "0") OR (font[i] > "9")) DO (* skip name *)
  INC(i)
 END;
 j := 0;
 WHILE (font[i] # 0X) & (font[i] >= "0") & (font[i] <= "9") & (font[i] = type[j]) DO
  INC(i);  INC(j)
 END;
 RETURN (font[i] = type[j])
END MatchFont;

(* Delimit a paragraph: begins at lastnl and ends at end *)
PROCEDURE GetPara(T: Texts.Text; VAR R: Texts.Reader; VAR beg, end: LONGINT; VAR typ: SHORTINT);
VAR ch, firstch: CHAR; firstfnt: Objects.Library; firstcol: INTEGER; lastnl: LONGINT;
BEGIN
 beg := Texts.Pos(R); end := beg; lastnl := beg;
 
 (* skip empty lines *)
 Texts.Read(R, ch);
 WHILE ~R.eot & (ch <= " ") DO
  INC(beg);
  IF ch = 0DX THEN lastnl := beg END;
  Texts.Read(R, ch)
 END;
 
 IF ~R.eot THEN
  firstch := ch; firstfnt := R.lib; firstcol := R.col;
  LOOP
   WHILE ~R.eot & (ch # 0DX) DO Texts.Read(R, ch) END; (* read till first nl *)
   IF R.eot THEN EXIT END;
   IF ch = 0DX THEN
    end := Texts.Pos(R)-1;
    Texts.Read(R, ch);
    WHILE ~R.eot & (ch = " ") OR (ch = tab) DO Texts.Read(R, ch) END;
    IF ch = "*" THEN Texts.OpenReader(R, T, Texts.Pos(R)-1); EXIT END;
    IF ch = 0DX THEN EXIT END
   END
  END;
  IF firstcol = 1 THEN (* red *) typ := title
  ELSIF MatchFont(firstfnt.name, "12b") THEN typ := heading
  ELSIF MatchFont(firstfnt.name, "10.") THEN typ := pre; beg := lastnl;
  ELSIF firstch = "*" THEN typ := bullet
  ELSIF firstch = "-" THEN typ := line
  ELSE typ := para
  END
 END
END GetPara;

PROCEDURE WriteStretch(T: Texts.Text; beg, end: LONGINT);
VAR R: Texts.Reader; ch: CHAR; lastlib: Objects.Library;
BEGIN
 IF end > beg THEN 
  Texts.OpenReader(R, T, beg);
  Texts.Read(R, ch); lastlib := R.lib;
  WHILE beg < end DO
   IF R.lib # lastlib THEN
    IF MatchFont(R.lib.name, "12i") THEN
     IF ~italic THEN S("<i>"); italic := TRUE END
    ELSE
     IF italic THEN S("</i>"); italic := FALSE END
    END;
    lastlib := R.lib
   END;
   IF ch = "ü" THEN S("&uuml;")
   ELSIF ch = "Ü" THEN S("&Uuml;")
   ELSIF ch = "ù" THEN S("&ugrave;")
   ELSIF ch = "ä" THEN S("&auml;")
   ELSIF ch = "Ä" THEN S("&Auml;")
   ELSIF ch = "á" THEN S("&aacute;")
   ELSIF ch = "à" THEN S("&agrave;")
   ELSIF ch = "ë" THEN S("&euml;")
   ELSIF ch = "é" THEN S("&eacute;")
   ELSIF ch = "è" THEN S("&egrave;")
   ELSIF ch = "ö" THEN S("&ouml;")
   ELSIF ch = "Ö" THEN S("&Ouml;")
   ELSIF ch = "ò" THEN S("&ograve;")
   ELSIF ch = "ï" THEN S("&iuml;")
   ELSIF ch = "ì" THEN S("&igrave;")
   ELSIF ch = 0DX THEN C(" "); C(sep)
   ELSIF ch = tab THEN S("&nbsp; &nbsp; &nbsp;")
   ELSIF (ch >= " ") OR (ch = "-") THEN
    C(ch)
   END;
   Texts.Read(R, ch);
   INC(beg)
  END
 END
END WriteStretch;

PROCEDURE WritePara(T: Texts.Text; beg, end: LONGINT);
VAR R: Texts.Reader; ch: CHAR; col: INTEGER;
 pos, lstart: LONGINT; anchor: ARRAY 512 OF CHAR; apos: INTEGER;
BEGIN col := -1; pos := beg; anchor := "";
 Texts.OpenReader(R, T, beg);
 Texts.Read(R, ch); 
 WHILE pos < end DO
  IF (R.col = 3) & (col # 3) THEN (* start link *)
   WriteStretch(T, beg, pos); beg := pos
  END;
  col := R.col;
   
  IF (col = 3) & (ch = "{") THEN (* reading an anchor *)
   lstart := pos;
   INC(pos); Texts.Read(R, ch);
   apos := 0;
   WHILE ~R.eot & (apos < LEN(anchor)) & (ch # "}") DO
    anchor[apos] := ch; INC(apos);
    INC(pos);
    Texts.Read(R, ch)
   END;
   anchor[apos] := 0X;
   S("<a href="); C(22X); S(anchor); C(22X); C(">");
   WriteStretch(T, beg, lstart); beg := pos+1;
   S("</a>")
  ELSE INC(pos); Texts.Read(R, ch)
  END
 END;
 WriteStretch(T, beg, end)
END WritePara;

PROCEDURE GetPrefix(T: Texts.Text; VAR beg, end: LONGINT; VAR s: ARRAY OF CHAR);
VAR R: Texts.Reader; old: LONGINT; ch: CHAR; i: INTEGER;
BEGIN
 old := beg; i := 0;
 Texts.OpenReader(R, T, beg);
 Texts.Read(R, ch);
 WHILE ~R.eot & (ch # ":") & (beg < end) DO
  IF (ch > " ") & (i < LEN(s) - 1) THEN s[i] := ch; INC(i) END;
  INC(beg);
  Texts.Read(R, ch)
 END;
 IF ch = ":" THEN s[i] := 0X; INC(beg)
 ELSE s[0] := 0X; beg := old
 END
END GetPrefix;

PROCEDURE ConvertText(T: Texts.Text; start: LONGINT; VAR filename: ARRAY OF CHAR);
VAR R: Texts.Reader; beg, end, nbeg, nend: LONGINT; typ, ntyp: SHORTINT; body: BOOLEAN;

 PROCEDURE StartBody;
 BEGIN
  S("</head>"); L;
  IF BodyColor THEN
   S("<body BGCOLOR="); C(22X); S("#FFFFFF"); C(22X); S(">"); L
  ELSE
   S("<body>"); L
  END;
  body := TRUE
 END StartBody;
 
BEGIN
 italic := FALSE; body := FALSE;
 Texts.OpenReader(R, T, start);
 GetPara(T, R, beg, end, typ);
 IF DocHeader THEN
  S("<!DOCTYPE HTML PUBLIC "); C(22X); S("-//W3C//DTD HTML 4.01 Transitional//EN"); C(22X); S(">"); L
 END;
 S("<html>"); L;
 S("<head>"); L;
 S("<title>");
 IF typ = title THEN
  GetPrefix(T, beg, end, filename); (* Skip that file name, discarding it *)
  WritePara(T, beg, end);
  beg := end (* title paragraph already written *)
 ELSE
  S("Untitled")
 END;
 S("</title>"); L;
 S('<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">'); L;
 WHILE ~R.eot DO
  IF ~body & (typ # title) THEN StartBody END; (* first non-title paragraph starts body *)
  GetPara(T, R, nbeg, nend, ntyp);
  IF body & (ntyp = title) THEN ntyp := para END; (* treat a title paragraph in body like normal *)
  IF typ = bullet THEN S("<li>"); INC(beg)
  ELSIF typ = heading THEN S("<h2>")
  ELSE (* skip *)
  END;
  IF typ = line THEN S("<hr>") (* Horizontal Ruler *)
  (*ELSIF typ = title THEN*) (* skip *)
  ELSE
   WritePara(T, beg, end); (* write previous *)
   IF typ = pre THEN C(0DX) END
  END;
  IF typ = heading THEN S("</h2>") END;
  IF beg # end THEN L END;
  
  (* List *)
  IF (ntyp = bullet) & (typ # bullet) THEN (* open list *)
   S("<ul>"); L
  ELSIF (ntyp # bullet) & (typ = bullet) THEN (* close list *)
   S("</ul>"); L
  END;
  
  (* Pre-formatted text *)
  IF (ntyp = pre) & (typ # pre) THEN (* start pre-formatted text *)
   IF ~body THEN StartBody END;
   S("<pre>")
  ELSIF (ntyp # pre) & (typ = pre) THEN
   S("</pre>"); L
  END;
  
  (* Separate 2 consecutive "normal" paragraphs with a paragraph break, except two preformatteds *)
  IF (ntyp = para) & (typ = para) THEN S("<p>"); L END;
  
  end := nend; beg := nbeg; typ := ntyp
 END;
 IF ~body & (typ # title) THEN StartBody END;
 WritePara(T, beg, end); (* write previous *)
 IF (typ = bullet) THEN (* close list *)
  S("</ul>"); L
 END;
 IF (typ = pre) THEN
  S("</pre>"); L
 END;
 S("</body>"); L;
 S("</html>"); L
END ConvertText;

(** Show a preview of the HTML text in a text viewer - Processes ONLY one text! *) 
PROCEDURE Show*;
VAR S: Texts.Scanner; T, t: Texts.Text; time, beg, end: LONGINT;
 filename: ARRAY 64 OF CHAR; f: Files.File;
BEGIN
 sep := 0DX;
 beg := 0;  (* Process from the beginning of the text. Modified if "@" used *)
 Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(S); T := NIL;
 IF (S.class = Texts.Char) & (S.c = "*") THEN
  T := Oberon.MarkedText()
 ELSIF (S.class = Texts.Char) & (S.c = "^") THEN
  Oberon.GetSelection(T, beg, end, time);
  IF time >= 0 THEN
   Texts.OpenScanner(S, T, beg);
   Texts.Scan(S);
   IF (S.class = Texts.Name) THEN
    NEW(T); Texts.Open(T, S.s);
    IF T.len = 0 THEN T := NIL END
   END
  ELSE T := NIL
  END
 ELSIF (S.class = Texts.Char) & (S.c = "@") THEN
  Oberon.GetSelection(T, beg, end, time);
  IF time < 0 THEN T := NIL END
 END;
 IF T # NIL THEN
  f := Files.New("Temp.HTML.tmp");
  Files.Set(out, f, 0);
  ConvertText(T, beg, filename);
  Files.Register(f);
  NEW(t); Texts.Open(t, "Temp.HTML.tmp");
  Oberon.OpenText(filename, t, 400, 200)
 END
END Show;

PROCEDURE Compile*;
 VAR S: Texts.Scanner; T: Texts.Text; filename: ARRAY 64 OF CHAR; f: Files.File; beg, end, time: LONGINT;

 PROCEDURE CompileT();
  VAR R: Texts.Reader; beg, end: LONGINT; typ: SHORTINT;
    res, i: INTEGER; bak: ARRAY 64 OF CHAR;
 BEGIN
  IF T.len > 0 THEN
  (* Get the file name from the source text, at the beginning i.e. pos 0 *)
   Texts.OpenReader(R, T, 0);
   GetPara(T, R, beg, end, typ);
   IF typ = title THEN
    GetPrefix(T, beg, end, filename)
   END;
  (* *)
   IF filename # "" THEN
    Out.String(filename);
   (* Rename the file 'fileName.Bak' *)
    i := 0;
    WHILE filename[i] # 0X DO bak[i] := filename[i]; INC(i) END;
    bak[i] := "."; bak[i+1] := "B"; bak[i+2] := "a"; bak[i+3] := "k"; bak[i+4] := 0X;
    Files.Rename(filename, bak, res);
   (* *)
    f := Files.New(filename);
    Files.Set(out, f, 0);
    ConvertText(T, 0, filename);
    Files.Register(f);
    Out.Int(Files.Length(f), 10);
   ELSE Out.String("no destination file name in text")
   END
  END;
  Out.Ln
 END CompileT;
 
BEGIN
 sep := 0AX;
 Out.String("HTML.Compile"); Out.Ln;
 Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(S);
 IF (S.class = Texts.Char) & (S.c = "*") THEN
  T := Oberon.MarkedText();
  IF T # NIL THEN
   CompileT()
  END
 ELSE
  end := MAX(LONGINT) - 100;
  IF (S.class = Texts.Char) & (S.c = "^") THEN
   Oberon.GetSelection(T, beg, end, time);
   IF time >= 0 THEN Texts.OpenScanner(S, T, beg); Texts.Scan(S) END
  END;
  WHILE (S.class = Texts.Name) & (Texts.Pos(S) < end + S.len + 1) DO
   Out.String(S.s); Out.String(" => ");
   NEW(T); Texts.Open(T, S.s);
   CompileT();
   Texts.Scan(S)
  END
 END
END Compile;

END HTML.

System.Free HTML ~

HTML.Compile ^ HTML.Compile *

HTML.Show ^  HTML.Show *  HTML.Show @
