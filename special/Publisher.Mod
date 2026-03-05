(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Publisher; (* jm 12.5.95 - afi 19 Feb 1997, 3 Sep 1997 *)

IMPORT
 Objects, Printer, Printer3, Display, Display3, Attributes, Texts, Fonts, Oberon, Modules,
 Gadgets, TextGadgets, TextGadgets0, TextDocs, Hyphen, Out, Input, Strings, EditTools, Documents;

CONST
 DisplayUnit = LONG(10000);
 boxdsr = 3; (* standard descender for boxes *)
 MaxChar = 300;
 MaxLines = 4; (* must be 4 ! Better approach to combat Hurenkinder and Schusterknaben. *)
 CR = 0DX; TAB = 9X;

TYPE
 Glyph = RECORD
  ch: CHAR;
  fnt: SHORTINT;
  col: SHORTINT;
  voff: INTEGER;
  dx: INTEGER
 END;

 (* A Line is almost like a piece of text in Texts. Each char or Glyph has attributes
  character, font (index in a font list), color, vertical offset and width. *)
 Line = POINTER TO LineDesc;
 LineDesc = RECORD
  next: Line;
  w, h, asr, dsr, len: INTEGER;
  style: TextGadgets.Style;
  eot, hyphen, fullstop, revision: BOOLEAN; RevColor: INTEGER;
  char: ARRAY MaxChar OF Glyph
 END;

VAR
 scrfont: ARRAY 127 OF Objects.Library; (* screen fonts *)
 metfont: ARRAY 127 OF Fonts.Font; (* corresponding metric fonts *)

 (* Variables set by default in SetDefaultPageLayout. *)
 PageWidth*, PageHeight*: LONGINT;
 Xoffset*, Yoffset*: LONGINT;
 OddSideMargin*, EvenSideMargin*, CurrentMargin*: LONGINT;
 TopMargin*: LONGINT;
 HeaderHeight*: LONGINT;
 HeaderSeparator*, FooterSeparator*: LONGINT;
 TextWidth*, TextHeight*: LONGINT;
 DoubleSided*: BOOLEAN;
 LineSpacing*: LONGINT;
 EmptyLineCompression*: INTEGER;
 PageNoFont*, HeaderFont*: Fonts.Font;
 HyphenFactor*: INTEGER;
 Marker*: LONGINT;
 MinLineH*: LONGINT;

 (* Variables set by information contained in the formatting instructions file, or by default. *)
 OddHeader, EvenHeader: ARRAY 256 OF CHAR;
 PrintPageMarkers: BOOLEAN;
 PrintPageNo: BOOLEAN;
 PrintHeaders: BOOLEAN;
 PrintFooters: BOOLEAN;
 ColorPrint: BOOLEAN;
 MarkRevisions: BOOLEAN;
 RomanPageNo: BOOLEAN;

 TopOfText: LONGINT;
 CurrentPage*, ChapterPage*: INTEGER;
 beginpage, endpage: INTEGER;

 validletter: ARRAY 256 OF BOOLEAN;

 adjust, debug, UseBold: BOOLEAN;
 FirstChapter: BOOLEAN;
 WL, WD, WT, WF, WI: Texts.Writer;
  (* WL: writer collecting data for the Oberon log.
   WD: writer collecting debugging data, if debug = TRUE.
   WT: writer collecting table of contents data.
   WF: writer collecting figures data.
   WI: writer collecting index data. *)
  TT, TF, TI: Texts.Text;
  firststyle: Objects.Object;
  (* The first Style found in a chapter text is used later as first Style for pseudo-files. *)
  Figure, Table: ARRAY 8 OF CHAR;
  section: ARRAY 64 OF CHAR; (* A chapter, index, lof or toc. *)
  RevBegin, RevEnd, YWas: INTEGER; EndOfP: BOOLEAN;
  revpos, CurColor: INTEGER;

PROCEDURE Check (n: INTEGER);
BEGIN IF Input.Available() > 0 THEN HALT(100) END
END Check;
(*============================================*)
(* The next 8 procedures are extracted from TextGadgets.Mod. *)

PROCEDURE Dev (x: INTEGER): INTEGER;
BEGIN RETURN SHORT((LONG(x) * DisplayUnit + Printer.Unit DIV 2) DIV Printer.Unit)
END Dev;

PROCEDURE Max (x, y: INTEGER): INTEGER;
BEGIN IF x > y THEN RETURN x; ELSE RETURN y; END
END Max;

PROCEDURE Below (x, y: INTEGER): INTEGER;
BEGIN
 IF x < y THEN RETURN y - x; ELSE RETURN 0 END
END Below;

PROCEDURE Above (x, y: INTEGER): INTEGER;
BEGIN
 IF x > y THEN RETURN x - y; ELSE RETURN 0 END
END Above;

PROCEDURE FindStyle (T: Texts.Text; beg: LONGINT): TextGadgets.Style;
VAR F: Texts.Finder; obj: Objects.Object; style: TextGadgets.Style;
BEGIN
 Texts.OpenFinder(F, T, 0); style := NIL;
 WHILE ~F.eot & (F.pos <= beg) DO
  Texts.FindObj(F, obj);
  IF (obj # NIL) & (obj IS TextGadgets.Style) THEN style := obj(TextGadgets.Style) END
 END;
 RETURN style
END FindStyle;

PROCEDURE Voff (obj: Objects.Object): INTEGER;
VAR A: Objects.AttrMsg;
BEGIN
 A.id := Objects.get; A.name := "LineupHY"; A.class := Objects.Inval; A.res := -1;
 obj.handle(obj, A);
 IF (A.res >= 0) & (A.class = Objects.Int) THEN RETURN -SHORT(A.i)
 ELSE RETURN 0
 END
END Voff;

PROCEDURE PrinterTabSize (obj: TextGadgets.Style; w: INTEGER; VAR pdx: INTEGER);
VAR t, dx: INTEGER;
BEGIN
 IF obj # NIL THEN
  (* convert w back to display coordinates *)
  w := SHORT(LONG(w) * Printer.Unit DIV DisplayUnit);
  IF (obj.noTabs > 0) & (TextGadgets.left IN obj.mode) THEN
   t := 0;
   WHILE (t # obj.noTabs) & (w >= obj.tab[t]) DO INC(t); Check(7) END;
   IF t < obj.noTabs THEN
    dx := obj.tab[t] - w + 1; pdx := Dev(dx)
   END
  END
 END
END PrinterTabSize;

PROCEDURE CacheLib (L: Objects.Library): SHORTINT;
VAR i: INTEGER; font: Fonts.Font;
BEGIN
 i := 0;
 WHILE (i < 128) & (scrfont[i] # NIL) & (scrfont[i] # L) DO INC(i) END;
 IF scrfont[i] = NIL THEN
  scrfont[i] := L;
  IF L IS Fonts.Font THEN
   font := Printer.GetMetric(L(Fonts.Font))
  ELSE
   font := Fonts.Default
  END;
  metfont[i] := Fonts.This(font.name)
 END;
 RETURN SHORT(i)
END CacheLib;
(*=============================================*)
(* Regress in the line character by character until the line length in under maxW and the first blank is found. *)
PROCEDURE WrapLine (L: Line; maxW: LONGINT; VAR resW, resLen: INTEGER): BOOLEAN;
VAR i, W: INTEGER;
BEGIN
 i := L.len; W := L.w;
 REPEAT
  DEC(i); DEC(W, L.char[i].dx); Check(1);
 UNTIL (i <= 0) OR ((W <= maxW) & (L.char[i].ch <= " ") & (scrfont[L.char[i].fnt] IS Fonts.Font));
 IF i > 0 THEN
  resLen := i + 1; (* include last space in the length of the line *)
  resW := W;
  RETURN TRUE
 END;
 resLen := L.len; resW := SHORT(maxW);
 RETURN FALSE
END WrapLine;

PROCEDURE HyphenateLine (L: Line; maxW: LONGINT; VAR resW, resLen: INTEGER; VAR appendHyphen: BOOLEAN): BOOLEAN;
VAR i, j, k, pos, W, up, hyphenW: INTEGER; word: ARRAY 128 OF CHAR; offset, place: ARRAY 128 OF LONGINT;
 obj: Objects.Object; Oname: INTEGER; (* Oberon names (commands, types, ...) must not be hyphenated. *)
BEGIN
 resLen := L.len; resW := SHORT(maxW); appendHyphen := FALSE;

 i := L.len;
 DEC(i);
 WHILE (L.char[i].ch <= " ") & (scrfont[L.char[i].fnt] IS Fonts.Font) DO DEC(i); Check(2); END;
 WHILE (i > 0) & ((L.char[i].ch > " ") & (scrfont[L.char[i].fnt] IS Fonts.Font)) DO DEC(i); Check(3) END;
 ASSERT(i > 0);

 INC(i); pos := 0; up := 0; Oname := 0;
 WHILE (i < L.len) & (L.char[i].ch > " ") DO
  IF validletter[ORD(L.char[i].ch)] THEN
   IF (L.char[i].ch >= "A") & (L.char[i].ch <= "Z") THEN INC(up) END; (* Count no. of uppercase characters. *)
   IF (scrfont[L.char[i].fnt].name[0] = "A") THEN INC(Oname) END; (* Count no. of Arial characters. *)
   word[pos] := L.char[i].ch;
   offset[pos] := i;
   INC(pos)
  END;
  INC(i);
  Check(4)
 END;
 word[pos] := 0X;
 IF pos = 0 THEN RETURN FALSE END;
 IF (up = pos) OR (Oname = pos) THEN RETURN FALSE END;
 (* All uppercase or all Arial, do not hyphenate *)

 Hyphen.Word(word, place);
 metfont[L.char[offset[0]].fnt].GetObj(metfont[L.char[offset[0]].fnt], ORD("-"), obj);
 hyphenW := obj(Fonts.Char).dx;

 W := L.w;
 i := 0; WHILE place[i] # -1 DO INC(i) END; DEC(i);
 IF i < 0 THEN (* error *)
 ELSE
  j := L.len-1;
  LOOP
   WHILE j >= offset[place[i]] DO DEC(W, L.char[j].dx); DEC(j); Check(5) END;
   IF W + hyphenW <= maxW THEN EXIT END;
   DEC(i);
   IF i < 0 THEN EXIT END;
   Check(6)
  END;
  IF W + hyphenW <= maxW THEN
   IF L.char[j].ch = "-" THEN (* good, line break at a - in text *)
    ASSERT(hyphenW = L.char[j].dx, 110);
    resW := W + hyphenW; resLen := j + 1
   ELSE
    resW := W + hyphenW; resLen := j+1; appendHyphen := TRUE
   END;
   IF debug THEN
    Texts.WriteString(WD, " word="); Texts.WriteString(WD, word);
    Texts.WriteString(WD, " cut=");
    k := j; WHILE k < L.len DO Texts.Write(WD, L.char[k].ch); INC(k) END
   END;
   RETURN TRUE
  END
 END;
 RETURN FALSE
END HyphenateLine;

PROCEDURE Format (T: Texts.Text; pos: LONGINT; L: Line; VAR break: BOOLEAN);
VAR R: Texts.Reader; maxW: LONGINT; ch: CHAR; obj, mobj: Objects.Object; lastlib: Objects.Library; fntno: SHORTINT;
 dx: INTEGER;
 wrapW, wrapL, hypW, hypL: INTEGER; appendH: BOOLEAN;
BEGIN
 break := FALSE;
 L.len := 0; L.w := 0; L.h := 0; L.asr := 0; L.dsr := 0; L.eot := FALSE; L.hyphen := FALSE; L.fullstop := FALSE;
 L.revision := FALSE; L.RevColor := 15;
 L.style := FindStyle(T, pos);
 IF L.style # NIL THEN maxW := Dev(L.style.width)
 ELSE maxW := TextWidth
 END;

 lastlib := NIL; fntno := -1;
 Texts.OpenReader(R, T, pos);
 LOOP Check(8);
  Texts.Read(R, ch);
  IF R.eot THEN L.eot := TRUE; EXIT END;
  R.lib.GetObj(R.lib, ORD(ch), obj);
  IF obj # NIL THEN
   IF obj IS Fonts.Char THEN
    WITH obj: Fonts.Char DO
     L.char[L.len].ch := ch;
     L.char[L.len].col := R.col;
     IF R.col # Display.FG THEN (* A revised text in color # from black starts here in the current line. *)
      IF ~L.revision THEN L.RevColor := R.col END;
      L.revision := TRUE
     END;
     L.char[L.len].voff := Dev(R.voff);
     IF R.lib # lastlib THEN
      fntno := CacheLib(R.lib); lastlib := R.lib;
      L.dsr := Max(L.dsr, metfont[fntno].minY); L.dsr := Max(L.dsr, Below(L.char[L.len].voff, 0));
      L.asr := Max(L.asr, metfont[fntno].maxY); L.asr := Max(L.asr, Above(L.char[L.len].voff, 0));
      L.h := L.dsr + L.asr;
     END;
     L.char[L.len].fnt := fntno;
     IF (ch = CR) & (lastlib IS Fonts.Font) THEN dx := 0;
     ELSIF (ch = TAB) & (lastlib IS Fonts.Font) THEN
      metfont[fntno].GetObj(metfont[fntno], ORD(ch), mobj);
      dx := mobj(Fonts.Char).dx;
      PrinterTabSize(L.style, L.w, dx)
     ELSE
      metfont[fntno].GetObj(metfont[fntno], ORD(ch), mobj);
      dx := mobj(Fonts.Char).dx
     END;
     L.char[L.len].dx := dx;
     INC(L.w, dx);
     INC(L.len);

     IF ch = CR THEN EXIT END;
     IF (ch = " ") & (lastlib IS Fonts.Font) THEN
      IF L.w > maxW THEN EXIT END
     END
    END
   ELSIF obj IS Display.Frame THEN
    WITH obj: Display.Frame DO
     L.char[L.len].ch := ch; L.char[L.len].fnt := CacheLib(R.lib); lastlib := R.lib;

     IF ~(obj IS TextGadgets.Control) THEN
      IF (obj IS TextGadgets.Style) & (L.len # 0) THEN (* not first character is style, terminate formatting*)
       EXIT
      END;
      dx := Dev(obj.W);
      IF (L.w + dx > maxW) & ~(obj IS TextGadgets.Style) & (L.len # 0) THEN (* does not fit *)
       EXIT
      END;
      L.char[L.len].dx := dx;
      INC(L.w, dx); L.char[L.len].voff := Dev(R.voff + Voff(obj));
      L.dsr := Max(L.dsr, Below(L.char[L.len].voff - Dev(boxdsr), 0));
      L.asr := Max(L.asr, Above(L.char[L.len].voff + Dev(obj.H), 0));
      L.h := L.dsr + L.asr;
      INC(L.len);
      IF obj IS TextGadgets.Style THEN
       L.h := 0; L.asr := 0; L.dsr := 0; L.w := 0; (* not visible *)
       IF TextGadgets.pagebreak IN obj(TextGadgets.Style).mode THEN break := TRUE END;
       EXIT
      ELSIF debug THEN
       Texts.WriteString(WD, " img "); Texts.WriteInt(WD, L.asr, 6); Texts.WriteInt(WD, L.dsr, 6); Texts.WriteLn(WD)
      END
     ELSE L.char[L.len].dx := 0; INC(L.len)
     END
    END
   END
  END
 END;
 IF L.w >= maxW THEN (* last character on line must be a space *)
  IF WrapLine(L, maxW, wrapW, wrapL) THEN
   IF HyphenateLine(L, maxW, hypW, hypL, appendH) THEN
    Texts.WriteString(WD, " diff="); Texts.WriteInt(WD, hypW - wrapW, 0);
    Texts.WriteString(WD, " thres="); Texts.WriteInt(WD, maxW DIV HyphenFactor, 0);
    IF (hypW - wrapW) >= maxW DIV HyphenFactor THEN L.w := hypW; L.len := hypL; L.hyphen := appendH;
    ELSE L.w := wrapW; L.len := wrapL
    END
   ELSE L.w := wrapW; L.len := wrapL
   END
  END
 ELSE (* everything fits on the line, must be terminated with CR *)
  IF (L.len > 1) & (L.char[L.len - 1].ch = CR) & (L.char[L.len - 2].ch = ".") THEN
   L.fullstop := TRUE END
 END;
END Format;

 PROCEDURE ReadL(VAR R: Texts.Reader; VAR line: ARRAY OF CHAR);
  VAR
   i, l: LONGINT; ch: CHAR;
 BEGIN
  l := LEN(line)-1;
  i := 0;
  Texts.Read(R, ch);
  WHILE ~R.eot & (ch # CR) DO
   IF i < l THEN line[i] := ch; INC(i) END;
   Texts.Read(R, ch)
  END;
  line[i] := 0X
 END ReadL;

 (* Get the position of a new alpha string in an alphabetically sorted list of lines. *)
 PROCEDURE GetPos(VAR new: ARRAY OF CHAR; TT: Texts.Text; VAR exists: BOOLEAN): LONGINT;
  VAR
   R: Texts.Reader;
   old: ARRAY 512 OF CHAR;
   pos: LONGINT;
   i: INTEGER;
 BEGIN
  Texts.OpenReader(R, TT, 0);
  exists := FALSE;
  pos := 0;
  ReadL(R, old);
  WHILE ~R.eot DO
   IF CAP(old[0]) > CAP(new[0]) THEN
    RETURN pos
   ELSIF CAP(old[0]) = CAP(new[0]) THEN
    i := 1;
    WHILE (new[i] # 0X) & (CAP(old[i]) = CAP(new[i])) DO
     INC(i)
    END;
    IF ((new[i] # 0X) & (CAP(old[i]) > CAP(new[i]))) OR
     ((new[i] = 0X) & (CAP(old[i]) > TAB)) THEN
     RETURN pos
    ELSIF (new[i] = 0X) & (old[i] =  TAB) THEN (* name matches exactly old which ends with a TAB. *)
     exists := TRUE
    END
   END;
   pos := Texts.Pos(R);
   ReadL(R, old)
  END;
  pos := TT.len;
  RETURN pos
 END GetPos;

 (* Delimit each alphabetical group with an empty line or (optionally) decorate the index with alphabet letters. *)
 PROCEDURE Alphabet (TT: Texts.Text);
  VAR
   R: Texts.Reader;
   old: ARRAY 512 OF CHAR;
   firstletter: CHAR;
   pos: LONGINT;
 BEGIN
  firstletter := " ";
  Texts.OpenReader(R, TT, 0);
  pos := 0; ReadL(R, old);
  WHILE ~R.eot DO
   IF CAP(old[0]) > firstletter THEN
    firstletter := CAP(old[0]);
(* Option: decorate with a letter.
    Texts.WriteLn(WI);
    Texts.Write(WI, firstletter);
*)
    Texts.WriteLn(WI);
    Texts.Insert(TI, pos, WI.buf);
(*    Texts.OpenReader(R, TT, pos + 3) *)
    Texts.OpenReader(R, TT, pos + 1)
   END;
   pos := Texts.Pos(R); ReadL(R, old)
  END
 END Alphabet;

(* Draw a vertical line as revision mark. The line extends over all the revised lines
 appearing in a color which differs from from black (Display.FG = 15). *)
PROCEDURE Revision (L: Line);
BEGIN
 IF MarkRevisions THEN
  (* A running revision may end now, because the color changes or because of end of page. *)
 IF (RevBegin # 0) & ((L.RevColor # CurColor) OR EndOfP) THEN
  RevEnd := YWas; 
  IF CurColor = 1 THEN CurColor := 2 END;
  IF CurColor = 3 THEN CurColor := 5 END;
  IF (CurrentPage >= beginpage) & (CurrentPage <= endpage) THEN
   Printer3.Line(NIL, Display.FG, Printer3.Pattern[CurColor], revpos, RevBegin, revpos, RevEnd, 16, Display.paint);
  END;
  RevBegin := 0;
 END;
 (* A new revision may start now. *)
 IF L.revision & (RevBegin = 0) THEN RevBegin := YWas;
  CurColor := L.RevColor
 END
 END
END Revision;

PROCEDURE PrintLine (L: Line; X, Y: INTEGER);
VAR maxW: LONGINT; margin, offset, a, b, i, x, spaces: INTEGER; mode: SET;
 buf: ARRAY 1024 OF CHAR; bufpos, px, py, lastvoff, lastcol: INTEGER;
 fnt, lastfnt: Objects.Library;
 obj: Objects.Object;
 P: Display.DisplayMsg; RR: Display3.Mask; OM: Display3.OverlapMsg;
 s: ARRAY 8 OF CHAR; name, command: ARRAY 32 OF CHAR; wordpos: LONGINT; found: BOOLEAN;

 PROCEDURE InitBuf;
 BEGIN px := X; py := Y; bufpos := 0; lastfnt := NIL; lastvoff := 0
 END InitBuf;

 PROCEDURE FlushBuf;
 BEGIN
  IF bufpos > 0 THEN
   buf[bufpos] := 0X;
   IF (CurrentPage >= beginpage) & (CurrentPage <= endpage) THEN
    IF ~ColorPrint THEN lastcol := Display.FG END; (* Print the string stored in the buffer in black. *)
    Printer3.String(NIL, lastcol, px, py + lastvoff, lastfnt(Fonts.Font), buf, Display.paint);
   END;
   bufpos := 0;
  END;
  px := x; py := Y
 END FlushBuf;

 PROCEDURE PutBuf (ch: CHAR; fnt: Objects.Library; voff, col: INTEGER);
 BEGIN
  IF (fnt # lastfnt) OR (voff # lastvoff) OR (col # lastcol) THEN FlushBuf; lastfnt := fnt; lastvoff := voff; lastcol := col END;
  buf[bufpos] := ch; INC(bufpos)
 END PutBuf;

BEGIN
 (* Position the line according to the specifications of the TextStyle, or use default values. *)
 IF L.style # NIL THEN maxW := Dev(L.style.width); margin := Dev(L.style.leftM); mode := L.style.mode
        ELSE maxW := SHORT(TextWidth); margin := 0; mode := {TextGadgets.left}
 END;

 IF   TextGadgets.middle IN mode THEN offset := SHORT((maxW - L.w) DIV 2)
 ELSIF TextGadgets.right IN mode THEN offset := SHORT(maxW - L.w)
 ELSE offset := 0
 END;

 spaces := 0; i := 0;
 WHILE i < L.len DO Check(10); (* Count the spaces in this line. *)
  IF (L.char[i].ch = " ") & (scrfont[L.char[i].fnt] IS Fonts.Font) THEN INC(spaces) END;
  INC(i)
 END;
 DEC(i);
 IF i >= 0 THEN
  IF (L.char[i].ch = " ") & (scrfont[L.char[i].fnt] IS Fonts.Font) THEN DEC(spaces)
  ELSIF (L.char[i].ch = CR) & (scrfont[L.char[i].fnt] IS Fonts.Font) THEN spaces := 0
  END;
 END;

 IF (TextGadgets.pad IN mode) & (spaces > 0) THEN
  a := SHORT((maxW - L.w) DIV spaces); b := SHORT((maxW - L.w) MOD spaces)
 ELSE a := 0; b := 0; spaces := 0
 END;

 x := X + margin + offset; (* The line starts at this abscissa x. *)
 revpos := x + SHORT(maxW) + 80;
 InitBuf;

 IF debug THEN
  Texts.WriteString(WD, "     x="); Texts.WriteInt(WD, x, 0); Texts.WriteString(WD, " y="); Texts.WriteInt(WD, Y, 0);
  Texts.WriteString(WD, " maxw="); Texts.WriteInt(WD, maxW, 0);
  Texts.WriteString(WD, " L.w="); Texts.WriteInt(WD, L.w, 0);
  IF (TextGadgets.pad IN mode) & (spaces > 0) THEN
   Texts.WriteString(WD, " pad="); Texts.WriteInt(WD, maxW - L.w, 0)
  END;
  IF L.hyphen THEN Texts.WriteString(WD, " HYPHENATED") END;
  Texts.WriteLn(WD);
  i := 0;
  WHILE i < L.len DO Texts.Write(WD, L.char[i].ch); INC(i) END;
  IF L.hyphen THEN Texts.Write(WD, "-") END;
  Texts.WriteLn(WD)
 END;

 i := 0;
 WHILE i < L.len DO Check(11); (* Process each character or object in this line. *)
  fnt := scrfont[L.char[i].fnt];
  IF fnt IS Fonts.Font THEN (* character *)
   IF L.char[i].ch = " " THEN
    PutBuf(" ", fnt, L.char[i].voff, L.char[i].col); INC(x, L.char[i].dx);
    IF spaces > 0 THEN INC(x, a) END; DEC(spaces);
    IF b > 0 THEN INC(x); DEC(b) END;
    FlushBuf  (* Shortcut PutBuf *)
   ELSIF L.char[i].ch = TAB THEN
    INC(x, L.char[i].dx);
    FlushBuf  (* Shortcut PutBuf *)
   ELSIF L.char[i].ch < " " THEN INC(x, L.char[i].dx)
   ELSE
    PutBuf(L.char[i].ch, fnt, L.char[i].voff, L.char[i].col);
    INC(x, L.char[i].dx)
   END
  ELSE (* object *)
   fnt.GetObj(fnt, ORD(L.char[i].ch), obj);
   WITH obj: Display.Frame DO
    IF ~(obj IS TextGadgets.Control) & ~(obj IS TextGadgets.Style) THEN
     IF debug THEN Texts.WriteString(WD, "Write object.") END;
     FlushBuf;
     IF (CurrentPage >= beginpage) & (CurrentPage <= endpage) THEN
     NEW(RR); Display3.Open(RR); Display3.Add(RR, 0, -obj.H + 1, obj.W, obj.H);
     OM.F := obj; OM.M := RR; OM.x := 0; OM.y := 0; OM.dlink := NIL; OM.res := -1; obj.handle(obj, OM);
     P.F := obj; P.device := Display.printer; P.id := Display.full; P.x := x; P.y := Y + L.char[i].voff; P.res := -1; P.dlink := NIL; Objects.Stamp(P);
     obj.handle(obj, P);
     Printer.UseColor(0, 0, 0);
     END;
     INC(x, L.char[i].dx);
     InitBuf
    END;
    IF obj IS TextGadgets.Control THEN (* This TextHyperlink hides a string to be placed in the index. *)
     Attributes.GetString(obj, "Name", name);
     Attributes.GetString(obj, "Cmd", command);
     wordpos := GetPos(name, TI, found);
     IF found THEN (* name exists in table *)
      Texts.WriteString(WI, ", ");
      Strings.IntToStr(CurrentPage, s);
      IF command[0] = "B" THEN
      Texts.SetFont(WI, Fonts.This("Syntax12m.Scn.Fnt"))
      END;
      Texts.WriteString(WI, s);
      Texts.Insert(TI, wordpos - 1, WI.buf)
     ELSE (* new entry in table *)
      Texts.WriteString(WI, name);
      Texts.Write(WI, TAB);
      Strings.IntToStr(CurrentPage, s);
      IF command[0] = "B" THEN
       Texts.SetFont(WI, Fonts.This("Syntax12m.Scn.Fnt"))
      END;
      Texts.WriteString(WI, s);
      Texts.WriteLn(WI);
      Texts.Insert(TI, wordpos, WI.buf)
     END;
     Texts.SetFont(WI, Fonts.This("Syntax12.Scn.Fnt"))
    END
   END
  END;
  INC(i)
 END;
 IF L.hyphen THEN PutBuf("-", fnt, 0, lastcol) END;
 FlushBuf;
 FlushBuf;

(* This piece of code is now replaced by a more elaborate procedure Revision.
  But printing is faster when a simple character is added to a revised line, instead of drawing a vertical line. *)

(* Mark the revised lines with a character (String) or with a rectangle (Rect): choose one or the other.
 IF L.revision THEN
  Printer3.String(NIL, Display.FG, X + SHORT(maxW), py + lastvoff, Fonts.This("Syntax14b.Scn.Fnt"), "   l", Display.paint);
  Printer3.Rect(NIL, Display.FG, 0, X + offset +SHORT(maxW) + 70, Y, 12, L.asr + L.dsr , 8, Display.paint);
 END;
*)

 IF EndOfP THEN YWas := Y END; (* Note the very bottom of the page in that case. *)
END PrintLine;

PROCEDURE SetDefaultPageLayout;

 PROCEDURE mm (x: LONGINT): LONGINT;
 BEGIN RETURN (x * 36000 + Printer.Unit DIV 2) DIV Printer.Unit
 END mm;

BEGIN
 PageWidth := mm(170);
 TextWidth := mm(125);
 OddSideMargin := mm(26);
 EvenSideMargin := PageWidth - TextWidth - OddSideMargin;
 
 PageHeight := mm(240);
 TopMargin := mm(19);
 HeaderHeight := mm(5);
 HeaderSeparator := mm(10);
 TextHeight := mm(180);
 FooterSeparator := mm(10);

 DoubleSided := TRUE;
 LineSpacing := 25; EmptyLineCompression := 100;

 PageNoFont := Fonts.This("Times10.Scn.Fnt"); HeaderFont := Fonts.This("Times10.Scn.Fnt");
 PrintPageMarkers := FALSE; PrintPageNo := TRUE; PrintHeaders := TRUE; PrintFooters := TRUE;
 RomanPageNo := FALSE;
 HyphenFactor := 20;
 Marker := mm(10);
 MinLineH := mm(20);
END SetDefaultPageLayout;

(* Format and print a chapter, the index, the list of figures or the table of contents. *)
PROCEDURE PrintText (T: Texts.Text);
VAR org: LONGINT; XP, YP, Y, lineno: INTEGER;
 line: ARRAY MaxLines OF Line;
 L, recycle: Line; pagebreak: BOOLEAN; PrevWasEmpty: BOOLEAN;

 PROCEDURE PrintMarkers;
 VAR L: LONGINT;
 
  PROCEDURE ReplConst (x, y, w, h: LONGINT);
  BEGIN Printer.ReplConst(SHORT(x), SHORT(y), SHORT(w), SHORT(h))
  END ReplConst;
 
 BEGIN
  IF PrintPageMarkers THEN
   L := Marker;
   (* Bottom Left *)
   ReplConst(Xoffset - L, Yoffset, L, 1);
   ReplConst(Xoffset, Yoffset - L, 1, L);
   (*Bottom Right *)
   ReplConst(Xoffset + PageWidth, Yoffset, L, 1);
   ReplConst(Xoffset + PageWidth, Yoffset - L, 1, L);
   (* Top Left *)
   ReplConst(Xoffset - L, Yoffset + PageHeight, L, 1);
   ReplConst(Xoffset, Yoffset + PageHeight, 1, L);
   (* Top Right *)
   ReplConst(Xoffset + PageWidth, Yoffset + PageHeight, L, 1);
   ReplConst(Xoffset + PageWidth, Yoffset + PageHeight, 1, L);
  END
 END PrintMarkers;

 PROCEDURE PrintFooter;
 VAR w, h, dsr, X, Y: INTEGER; s: ARRAY 8 OF CHAR;
 BEGIN
  IF PrintFooters & (lineno > 0) THEN
   IF  PrintPageNo & (ChapterPage = 1) THEN (* Print the page number. *)
    Strings.IntToStr(CurrentPage, s);
    Printer3.StringSize(s, PageNoFont, w, h, dsr);
    X := SHORT(Xoffset + CurrentMargin + TextWidth - w); (* Print at the right. *)
   (* X := SHORT(Xoffset + CurrentMargin + TextWidth DIV 2 - w DIV 2); Print at the center. *)
    Y := SHORT(TopOfText - TextHeight - FooterSeparator - h);
    Printer.String(X, Y, s, PageNoFont)
   END
  END
 END PrintFooter;


 PROCEDURE ConvertToRoman (P: INTEGER; VAR s: ARRAY OF CHAR);
 BEGIN
  COPY("", s);
  IF (20 < P) & (P < 30) THEN
   Strings.Append(s, "x"); P := P - 10
  END;
  IF (10 < P) & (P < 20) THEN
   Strings.Append(s, "x"); P := P - 10
  END;
  IF P = 1 THEN Strings.Append(s, "i")
  ELSIF P = 2 THEN Strings.Append(s, "ii")
  ELSIF P = 3 THEN Strings.Append(s, "iii")
  ELSIF P = 4 THEN Strings.Append(s, "iv")
  ELSIF P = 5 THEN Strings.Append(s, "v")
  ELSIF P = 6 THEN Strings.Append(s, "vi")
  ELSIF P = 7 THEN Strings.Append(s, "vii")
  ELSIF P = 8 THEN Strings.Append(s, "viii")
  ELSIF P = 9 THEN Strings.Append(s, "ix")
  END
 END ConvertToRoman;

 PROCEDURE PrintHeader;
 VAR w, h, dsr, X, Y: INTEGER; s: ARRAY 8 OF CHAR;
 BEGIN
  IF PrintHeaders & (lineno > 0) THEN
   IF ODD(CurrentPage) THEN
    IF ChapterPage # 1 THEN
     Printer3.StringSize(OddHeader, HeaderFont, w, h, dsr);
     X := SHORT(Xoffset + CurrentMargin);
     Y := SHORT(Yoffset + PageHeight - TopMargin - h);
     Printer.String(X, Y, OddHeader, HeaderFont)
    END
   ELSE
    Printer3.StringSize(EvenHeader, HeaderFont, w, h, dsr);
    X := SHORT(Xoffset + CurrentMargin + TextWidth - w);
    Y := SHORT(Yoffset + PageHeight - TopMargin - h);
    Printer.String(X, Y, EvenHeader, HeaderFont)
   END;
 
   X := SHORT(Xoffset + CurrentMargin);
   Y := SHORT(Yoffset + PageHeight - TopMargin - HeaderHeight);
   Printer.ReplConst(X, Y, SHORT(TextWidth), 2);
 
   (* Edit page numbers *)
   IF PrintPageNo THEN
    IF RomanPageNo THEN
     ConvertToRoman(CurrentPage, s)
    ELSE
     Strings.IntToStr(CurrentPage, s)
    END;
    Printer3.StringSize(s, PageNoFont, w, h, dsr);
    Y := SHORT(Yoffset + PageHeight - TopMargin - h);
    IF ODD(CurrentPage) THEN
     IF ChapterPage # 1 THEN
      X := SHORT(Xoffset + CurrentMargin + TextWidth - w);
      Printer.String(X, Y, s, PageNoFont)
     END
    ELSE
     X := SHORT(Xoffset + CurrentMargin);
     Printer.String(X, Y, s, PageNoFont)
    END;
   END
  END
 END PrintHeader;

 (* A line in bold font is considered as a heading and is copied to the table of contents and
  a line starting with "Figure" or "Table" is copied to the list of figures and tables. *)
 PROCEDURE CheckHeading (L: Line);
 VAR i, j: INTEGER; isFigure: BOOLEAN;
 
  PROCEDURE BoldFont (F: Objects.Library): BOOLEAN;
  VAR i: INTEGER;
  BEGIN
   i := 0; WHILE (F.name[i] # 0X) & (F.name[i] # ".") DO INC(i) END;
   RETURN (F.name[i] = ".") & (F.name[i-1] = "b")
  END BoldFont;
 
 BEGIN
  IF UseBold & BoldFont(scrfont[L.char[0].fnt]) THEN
   i := 0;
   IF (L.char[3].ch = ".") OR (L.char[4].ch = ".") THEN (* Indent this line by two blank characters. *)
    (* A very crude solution, indeed !! *)
    IF L.char[5].ch = "." THEN Texts.WriteString(WT, "  ") END;
    Texts.WriteString(WT, "  ")
   END;
   WHILE i < L.len DO
    IF L.char[i].ch # CR THEN Texts.Write(WT, L.char[i].ch) END;
    INC(i)
   END;
   Texts.Write(WT, TAB);
   Texts.WriteInt(WT, CurrentPage, 0); Texts.WriteLn(WT)
  ELSE (* Is this a "Figure i.j" or "Table i.j" to insert in the List of Figures and Tables? *)
   isFigure := FALSE;
   i := 0;
   WHILE (i < 8) & (i < L.len) & (L.char[i].ch = Figure[i]) DO
    INC(i)
   END;
   IF i = 7 THEN j := 7; isFigure := TRUE END;
   i := 0;
   WHILE (i < 7) & (i < L.len) & (L.char[i].ch = Table[i]) DO
    INC(i)
   END;
   IF i = 6 THEN j := 6; isFigure := TRUE END;
   IF isFigure THEN
    WHILE j < L.len DO
     IF L.char[j].ch # CR THEN Texts.Write(WF, L.char[j].ch) END;
     INC(j)
    END;
    Texts.Write(WF, TAB);
    Texts.WriteInt(WF, CurrentPage, 0); Texts.WriteLn(WF);
    Texts.Append(TF, WF.buf)
   END
  END
 END CheckHeading;

 PROCEDURE EmptyLine (L: Line): BOOLEAN;
 BEGIN RETURN L.len = 1
 END EmptyLine;

 PROCEDURE Height (L: Line): INTEGER;
 BEGIN
  IF L # NIL THEN
   IF EmptyLine(L) THEN RETURN L.h * EmptyLineCompression DIV 100
   ELSIF L.h < MinLineH THEN RETURN L.h + SHORT(L.h * LineSpacing DIV 100)
   ELSE RETURN L.h
   END
  ELSE RETURN 0
  END
 END Height;

 (* Bump one line out of the buffer and print it. *)
 PROCEDURE Shift;
 VAR i: INTEGER;
 BEGIN
  IF line[0] # NIL THEN
   IF EmptyLine(line[0]) THEN
    PrevWasEmpty := TRUE;
    IF lineno # 0 THEN
     YWas := Y; (* Note Y before skipping to the next one. *)
     (* This line is NOT printed. *)
     line[0].revision := FALSE;
     Revision(line[0]);
     DEC(Y, Height(line[0])); INC(lineno);
     Texts.WriteString(WD, " EMPTY LINE "); Texts.WriteLn(WD)
    ELSIF debug THEN
     Texts.WriteString(WD, " SUPPRESSED EMPTY LINE "); Texts.WriteLn(WD)
    END
   ELSE
    PrevWasEmpty := FALSE;
    IF section # "Biblio.Text" THEN CheckHeading(line[0]) END;;
    YWas := Y; (* Note Y before printing the next one. *)
    PrintLine(line[0], SHORT(Xoffset + CurrentMargin), Y - line[0].asr);
    Revision(line[0]); (* See if a revision ends or starts here. *)
    DEC(Y, Height(line[0]));
    INC(lineno)
   END;

   (* Dispose of this line[0]. *)
   line[0].next := recycle; recycle := line[0]

  END;
  FOR i := 0 TO MaxLines - 2 DO line[i] := line[i+1] END;
  line[MaxLines - 1] := NIL
 END Shift;

 PROCEDURE FreshPage (flush: BOOLEAN; limit: INTEGER);
 VAR i: INTEGER; s: ARRAY 8 OF CHAR;
 BEGIN
  IF debug THEN Texts.WriteString(WD, "lineno: "); Texts.WriteInt(WD, lineno, 3); END;
  IF (lineno > 0) THEN
   (* Expedite the printing of a limited number of lines on the current page. *)
   IF flush THEN
    FOR i := 0 TO limit DO
     IF debug THEN Texts.WriteString(WD, "Flushed line.") END;
     IF i = limit THEN (* This is the very last line. If a revision mark is pending, force print. *)
      EndOfP := TRUE
     END;
     Shift
    END
   END;
   
   (* Finish current page. *)
   IF (CurrentPage >= beginpage) & (CurrentPage <= endpage) THEN
   PrintHeader; PrintFooter; PrintMarkers;
   Printer.Page(1);
   END;
   IF RomanPageNo THEN
    ConvertToRoman(CurrentPage, s);
    Out.String(s); Out.String("  ")
   ELSE
    Out.Int(CurrentPage, 4)
   END;
   IF CurrentPage MOD 10 = 0 THEN Out.Ln END;
(*
   Out.String("  pos ");  Out.Int(org, 1);  Out.String("  page ");  Out.Int(CurrentPage, 1);  Out.Ln;
*)
   INC(CurrentPage); INC(ChapterPage)
  END;
  
  (* Start a new page. *)
  lineno := 0; Y := SHORT(TopOfText);
  RevBegin := 0; RevEnd := 0; EndOfP := FALSE; CurColor := 15;
  CurrentMargin := OddSideMargin;
  IF DoubleSided & ~ODD(CurrentPage) THEN CurrentMargin := EvenSideMargin END;
  IF debug THEN
   Texts.WriteString(WD, "PAGE "); Texts.WriteInt(WD, CurrentPage, 0); Texts.WriteLn(WD)
  END;
 END FreshPage;

 PROCEDURE AppendLine (L: Line);

  (* Measure the total height of the four lines in the buffer array. *)
  PROCEDURE WindowHeight (): INTEGER;
  VAR i, j: INTEGER;
  BEGIN j := 0;
   FOR i := 0 TO MaxLines - 1 DO INC(j, Height(line[i])) END;
   RETURN j
  END WindowHeight;

 BEGIN
  IF L.fullstop THEN Texts.Write(WD, "#") END;
  IF Y - WindowHeight() < TopOfText - TextHeight THEN (* does not fit on the page *)
   IF debug THEN
    Texts.WriteString(WD, " WINDOW: ");
    IF EmptyLine(line[MaxLines-4]) THEN Texts.Write(WD, "T") ELSE Texts.Write(WD, "F") END;
    IF EmptyLine(line[MaxLines-3]) THEN Texts.Write(WD, "T") ELSE Texts.Write(WD, "F") END;
    IF EmptyLine(line[MaxLines-2]) THEN Texts.Write(WD, "T") ELSE Texts.Write(WD, "F") END;
    IF EmptyLine(line[MaxLines-1]) THEN Texts.Write(WD, "T") ELSE Texts.Write(WD, "F") END;
    IF EmptyLine(L) THEN Texts.Write(WD, "T") ELSE Texts.Write(WD, "F") END;
   END;

   IF EmptyLine(L) & ~EmptyLine(line[3]) & ~EmptyLine(line[2]) THEN
   (* In principle according to Y - WidowHeight there is no more space for line[3] on the current page
    but because it is followed by an empty line it would appear at the top of the next page
    (called "Hurenkind" in German).
    Force this line to appear on the current page. The next line, which is empty, will be suppressed. *)
    FreshPage(TRUE, MaxLines - 1)
   ELSE
   IF debug & line[1].fullstop THEN Texts.WriteString(WD, " FullStop ") END;

   (* This section deals with loose lines surrounded by empty lines at the end of a page
    (called "Schusterknaben" in German).
    The strategy consists in letting a few lines print on the current page whilst forcing
    the rest to appear on the next page.
   *)
   IF EmptyLine(line[0]) THEN
    IF EmptyLine(line[1]) THEN Shift; FreshPage(FALSE, 0)
    ELSE
     IF EmptyLine(line[2]) & ~EmptyLine(L) & PrevWasEmpty THEN Shift; FreshPage(FALSE, 0)
     ELSIF line[1].fullstop THEN FreshPage(TRUE, MaxLines - 3)
     ELSE FreshPage(TRUE, MaxLines - 2)
     END
    END
   ELSE
    IF EmptyLine(line[1]) THEN
     IF PrevWasEmpty THEN FreshPage(FALSE, 0); Shift
      (* Note that Shift comes after the new page. Otherwise the L overwrites line[2]. *)
     ELSE Shift; FreshPage(FALSE, 0)
     END
    ELSE
     IF EmptyLine(line[2]) & ~EmptyLine(L) & PrevWasEmpty THEN FreshPage(TRUE, MaxLines - 3)
      (* The two lines [0] and [1] between two empty lines are printed on the current page. *)
     ELSIF line[1].fullstop THEN FreshPage(TRUE, MaxLines - 3)
     ELSE FreshPage(TRUE, MaxLines - 2)
     END
    END
   END
   END
  ELSE Shift
  END;
  line[MaxLines-1] := L
 END AppendLine;

BEGIN
 lineno := 0;
 recycle := NIL; 
 org := 0;
 
 IF FirstChapter THEN
  firststyle := FindStyle (T, 0);

  Texts.OpenWriter(WT);
  Texts.SetFont(WT, Fonts.This("Syntax12.Scn.Fnt"));
  Texts.OpenWriter(WI);
  Texts.SetFont(WI, Fonts.This("Syntax12.Scn.Fnt"));
  Texts.OpenWriter(WF);
  Texts.SetFont(WF, Fonts.This("Syntax12.Scn.Fnt"));
  FirstChapter := FALSE
 END;

 ChapterPage := 1;
 FreshPage(TRUE, MaxLines - 1);
 IF (section # "toc") & (section # "lof") THEN
   (* Add a line to the toc for each section: chapter, appendix, index but NOT lof and toc. *)
  Texts.WriteLn(WT); Texts.WriteLn(WT);
  Texts.SetFont(WT, Fonts.This("Syntax14b.Scn.Fnt"));
  Texts.WriteString(WT, EvenHeader);
  Texts.SetFont(WT, Fonts.This("Syntax12.Scn.Fnt"));
  IF (section = "Biblio.Text") OR (section = "index") THEN
   Texts.Write(WT, TAB);
   Texts.WriteInt(WT, CurrentPage, 0)
  ELSE
   Texts.WriteLn(WT)
  END;
  Texts.WriteLn(WT);
  Texts.SetFont(WT, Fonts.This("Syntax12.Scn.Fnt"))
 END;
 Texts.WriteLn(WF); (* Separation line in list of figures. *)
 (* Make sure that the new chapter starts on the right hand side. If not, leave an empty, even number page. *)
 IF DoubleSided & ~ODD(CurrentPage) THEN
   (* Force the printing of a header line on an even page. *)
   XP := SHORT(Xoffset + CurrentMargin);
   YP := SHORT(Yoffset + PageHeight - TopMargin - HeaderHeight);
   Printer.ReplConst(XP, YP, SHORT(TextWidth), 2);

  Printer.String(0, 0, "Empty page", HeaderFont); (* print some empty text *)
  Printer.Page(1); Out.Int(CurrentPage, 4); Out.String(" [Empty]");
  INC(CurrentPage);
  IF CurrentPage MOD 10 = 0 THEN Out.Ln END
 END;

 LOOP (* Process line by line until end of text. *)
  (* Prepare a new line. *)
  IF recycle = NIL THEN NEW(L) ELSE L := recycle; recycle := recycle.next END;
  (* Format a line: a piece of text ending with a carrier return. *)
  Format (T, org, L, pagebreak);
  AppendLine (L);
  IF pagebreak THEN
   FreshPage (TRUE, MaxLines - 1)
  END;
  INC(org, LONG(L.len));
  IF L.eot THEN EXIT END
 END;
 (* Append 4 empty lines to flush the line buffers. *)
 NEW(L); AppendLine(L);
 AppendLine(L);
 AppendLine(L);
 AppendLine(L);
 FreshPage(TRUE, MaxLines - 1);
 Out.Ln
END PrintText;

(** Format a text document to a PostScript file ready for publication, and direct it to the default Windows printer.

   Publisher.Print formatdata | *

 The Publisher reads a good looking WYSIWYG Oberon text document with chapter headings, section headings
 and paragraphs, including tables and gadgets (Panels, RembrandtFrames, etc) and transforms it to a PS file.
 The formatting instructions and the name of the text files to print are contained in the formatdata,
 or else, the marked text is printed. In the latter case, no formatting instructions can be supplied:
 default formatting instructions are used instead, e.g. AdjustBaseFont cannot apply.
 The formatdata contains a mixture of formatting instructions and of names of text files to format.
 Each text file is treated as a chapter of a book. The program automatically collects index information,
 a table of figures and a table of contents. These are saved in internal text objects which may be
 assimilated to pseudo-files.
 
 Default Page Layout:
 Quite a few page layout values are hard-coded in the SetDefaultPageLayout procedure.
 Variables with their default values are:
  PageWidth 170mm PageHeight 240mm
  TextWidth 125mm  TextHeight 180mm
  LineSpacing 25 pixels
  TopMargin 19mm
  HeaderHeight 5mm
  HeaderSeparator 10mm
  FooterSeparator 10mm
  DoubleSided TRUE
  RomanPageNo FALSE
 Markers in the four corners of pages, useful for cutting the paper correctly, are controlled
 by the MarkersOn/MarkersOff switch.
 When DoubleSided is TRUE, each chapter starts on an odd numbered page,
 possibly leaving an empty even numbered page.
 RomanPageNo must be set to TRUE for the second run of Publisher.Print to print
 the Preface, the table of contents and the list of figures with roman numbers.

 Pages to print:
  PrintPageNos begin => end.  Begin and end page numbers.
  Default 1 => 1000 (i.e. eot hopefully).

 Text hyphenation and text format control with TextStyles:
 Formatting is essentially hyphenating the text lines with the help of the Hyphen module. A line
 is a text stretch ending with a carrier return.
 A "-" character in a word, e.g. "object-based" is accepted as hyphen.
 This version uses the HyphenES.Text file, for english texts. Use HyphenDS.Text for German.
 Otherwise, formatting is controlled by TextStyle gadgets having tabs or not, with or without
 PageBreak. The first TextStyle in the first"chapter" is used as reference.
 Words made exclusiveley of capital letters are not hyphenated.
 Oberon names (command name, type name, etc.) in Arial typeface are not hyphenated.
 
 Fonts:
 Use the PrinterFontSubstitution value in the [System] section of the Registry to control the fonts.
 To produce a document ready for printing use a Times font for instance:
  PrinterFontSubstitution=Syntax Times
 
 Oberon cannot represent odd size fonts in their true size: the default system font is used instead,
 which is typically Syntax10.Scn.Fnt. However, for printing on a printer with a larger font palette
 is made possible with the AdjustBaseFont oldsize => newsize format instruction. It can adjust the
 base font size from say 12, to 13 without altering the look of the original text. Refer to the
  EditTools.ChangeSize command.

 For the Oberon Companion, the base font size is 12. Printing in Times12 is too small and Times14
 is too large. Therefore, the size is changed from 12 to 13. However, Arial12 is the correct size
 for printing.

 Colors:
 Printout of colored text is controlled by the ColorsOn/ColorsOff switch.

 Revision marks:
 Revised text may be highlighted in red or blue (in principle colors 1 to 8 could be used, but
 a useable pattern is provided by the values 2 to 7 only). The text color is mapped onto a pattern
 provided in module Printer3 which is used for drawing a vertical line alongside the revised text.
 Printout of the revision marks is controlled by the RevisionsOn/RevisionsOff switch.

 Index:
 Information destined for the construction of an index in hidden in the text itself which contains
 TextHyperlinks at strategical locations. The Name attribute of a TextHyperlink is used as hiding place
 for the information to be placed in the alphabetical index. This information is associated
 with the CurrentPage value at which the TextHyperlink is detected.
 The Cmd attribute may be assigned the value "B" to indicate that the page number should appear in
 bold face. Meaning: this entry is best explained there.
 The internal object name is "index" (pseudo-file).

 List of Figures:
 Formatting instructions destined to format a table of figures which is constructed
 with the lines starting with "Figure". The internal object name is "lof" (pseudo-file).

 Table of Contents:
 Formatting instructions destined to format a table of contents which is constructed
 with the lines having a first character in bold style. The internal object name is "toc" (pseudo-file).

 Printer:
 The DefaultPrinter value is ignored. The WinPrinter will be installed automatically.
 
 The DoubleSided variable is used to control the formatting of odd/even pages only. Double side
 printing is controlled by the printer setup.
 
 Debug:
 A debugging facility is integrated: set debug := TRUE.
 
*)
PROCEDURE Print*;
VAR T, TD: Texts.Text; F: Display.Frame; S: Attributes.Scanner; Mod: Modules.Module; Cmd: Modules.Command;
  oldsize, newsize: INTEGER;

 PROCEDURE SkipArrow (VAR S: Attributes.Scanner);
 BEGIN Attributes.Scan(S);
  IF (S.class = Attributes.Char) & (S.c = "=") THEN Attributes.Scan(S);
   IF (S.class = Attributes.Char) & (S.c = ">") THEN Attributes.Scan(S) ELSE S.class := Attributes.Inval END
  ELSE S.class := Attributes.Inval
  END
 END SkipArrow;

 PROCEDURE OpenPrinter (name: ARRAY OF CHAR);
 VAR retries: INTEGER;
 BEGIN
  retries := 4;
  Printer.Open(name, "");
  WHILE (Printer.res > 0) & (Printer.res <4 ) & (retries > 0) DO
   Out.Char("-"); Printer.Open(name, ""); DEC(retries)
  END;

  (* Center output on page *)
  Xoffset := Printer.Width DIV 2 - PageWidth DIV 2;
  Yoffset := Printer.Height DIV 2 - PageHeight DIV 2;
  TopOfText := Yoffset + PageHeight - TopMargin - HeaderHeight - HeaderSeparator
 END OpenPrinter;

 PROCEDURE PrinterErr;
 VAR err: ARRAY 32 OF CHAR;
 BEGIN
  IF       Printer.res = 1 THEN err := " no connection"
  ELSIF Printer.res = 2 THEN err := " no link"
  ELSIF Printer.res = 3 THEN err := " printer not ready"
  ELSIF Printer.res = 4 THEN err := " no permission"
  END;
  Texts.WriteString(WL, err); Texts.WriteLn(WL); Texts.Append(Oberon.Log, WL.buf)
 END PrinterErr;

(* Finalize the pseudo-file (index, lof or toc), store it as a TextDoc (any.Text) and print it. *)
PROCEDURE PrintPF (VAR PFT: Texts.Text);
 VAR obj: Objects.Object; PFW: Texts.Writer; D: Documents.Document; f: TextGadgets.Frame;
   sectionF: ARRAY 64 OF CHAR;
 BEGIN
  UseBold := FALSE;
  Texts.OpenWriter(PFW);
  Texts.WriteObj(PFW, firststyle);
  Texts.SetFont(PFW, Fonts.This("Syntax12.Scn.Fnt"));
  obj := NIL; (* Throw this object away. *)
  obj := Gadgets.CreateObject("TextStyle");
  IF section = "index" THEN
   Attributes.SetString(obj, "Tabs", "200")
  ELSE
   Attributes.SetString(obj, "Tabs", "60,400")
  END;
  Attributes.SetInt(obj, "Width", 450);
  Texts.WriteObj(PFW, obj);
  Texts.SetFont(PFW, Fonts.This("Syntax16b.Scn.Fnt"));
  Texts.WriteString(PFW, EvenHeader);
  Texts.WriteLn(PFW);
  IF (section = "index") OR (section = "lof") THEN
   Texts.WriteLn(PFW)
  END;
  Texts.Insert(PFT, 0, PFW.buf);
  NEW(D); TextDocs.InitDoc(D);
  COPY(section, sectionF);
  Strings.Append(sectionF, ".Text");
  Attributes.SetString(D, "DocumentName", sectionF);
  NEW(f); TextGadgets.Init(f, PFT, FALSE);
  Documents.Init(D, f); (* Merge together *)
  D.Store(D);
  IF adjust THEN EditTools.ChangeFontSize (PFT, 0, PFT.len, oldsize, newsize) END;
  IF debug THEN TextDocs.ShowText("Publisher.debug", PFT, Display.Width DIV 2, 300) END;
  PrintText(PFT)
 END PrintPF;

BEGIN
 adjust := FALSE;
 NEW(TI); Texts.Open(TI, "");
 NEW(TF); Texts.Open(TF, "");
(*
 (* Install the WinPrinter, required for this kind of printing. *)
 IF Printer.current.name # "WinPrinter.Install" THEN
  Mod := Modules.ThisMod("WinPrinter");
  IF Modules.res = 0 THEN
   Cmd := Modules.ThisCommand(Mod, "Install");
   IF Modules.res = 0 THEN
    Cmd()
   END
  END
 END;
*)
 Attributes.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Attributes.Scan(S);
 IF S.class IN {Attributes.Name, Attributes.String} THEN
  OpenPrinter(S.s); (* Printer file name. *)
  (*OpenPrinter("");*)
  SetDefaultPageLayout;
  IF Printer.res = 0 THEN
   CurrentPage := 1;
   ChapterPage := 1;
   FirstChapter := TRUE;
   beginpage := 1;
   endpage := 1000;
   LOOP
    Attributes.Scan(S);
    IF (S.class = Attributes.Char) & (S.c = "*") THEN
     T := TextDocs.GetText(F);
     IF T # NIL THEN
      Out.String("Publisher.Print *");
      PrintText(T)
     ELSE Out.String("  marked text not found")
     END;
     Out.Ln;
     EXIT
    ELSIF S.class IN {Attributes.Name, Attributes.String} THEN
     IF S.s = "OddHeader" THEN
      Out.String("   OddHeader=");
      Attributes.Scan(S);
      IF S.class IN {Attributes.Name, Attributes.String} THEN
       COPY(S.s, OddHeader);
       Out.String(OddHeader)
      ELSE Out.String("  not found"); EXIT
      END
     ELSIF S.s = "EvenHeader" THEN
      Out.String("   EvenHeader=");
      Attributes.Scan(S);
      IF S.class IN {Attributes.Name, Attributes.String} THEN
       COPY(S.s, EvenHeader);
       Out.String(EvenHeader)
      ELSE Out.String("  not found"); EXIT
      END
     ELSIF S.s = "AdjustBaseFont" THEN
      Out.String("   AdjustBaseFont=");
      Attributes.Scan(S);
      IF (S.class = Texts.Char) & (S.c = "?") THEN oldsize := -1 ELSE oldsize := SHORT(S.i) END;
      SkipArrow(S);
      IF (S.class = Texts.Int) & (-16 <= S.i) & (S.i < 16) THEN
       newsize := SHORT(S.i);
       adjust := TRUE
      END
     ELSIF S.s = "PrintPageNos" THEN
      Out.String("   PrintPageNos=");
      Attributes.Scan(S);
      IF (S.class = Texts.Int) THEN beginpage := SHORT(S.i) END;
      SkipArrow(S);
      IF (S.class = Texts.Int) THEN
       endpage := SHORT(S.i)
      END
     ELSIF S.s = "PageNumbersOn" THEN PrintPageNo := TRUE; Out.String("   PageNumbersOn")
     ELSIF S.s = "PageNumbersOff" THEN PrintPageNo := FALSE; Out.String("   PageNumbersOff")
     ELSIF S.s = "HeadersOn" THEN PrintHeaders := TRUE; Out.String("   HeadersOn")
     ELSIF S.s = "HeadersOff" THEN PrintHeaders := FALSE; Out.String("   HeadersOff")
     ELSIF S.s = "FootersOn" THEN PrintFooters := TRUE; Out.String("   FootersOn")
     ELSIF S.s = "FootersOff" THEN PrintFooters := FALSE; Out.String("   FootersOff")
     ELSIF S.s = "MarkersOn" THEN PrintPageMarkers := TRUE; Out.String("   MarkersOn")
     ELSIF S.s = "MarkersOff" THEN PrintPageMarkers := FALSE; Out.String("   MarkersOff")
     ELSIF S.s = "ColorsOn" THEN ColorPrint := TRUE; Out.String("   ColorsOn")
     ELSIF S.s = "ColorsOff" THEN ColorPrint := FALSE; Out.String("   ColorsOff")
     ELSIF S.s = "RevisionsOn" THEN MarkRevisions := TRUE; Out.String("   RevisionsOn")
     ELSIF S.s = "RevisionsOff" THEN MarkRevisions := FALSE; Out.String("   RevisionsOff")
     ELSIF S.s = "RomanPageNo" THEN RomanPageNo := TRUE; Out.String("   RomanPageNo")
     ELSE
      UseBold := TRUE;
      COPY(S.s, section);
      IF S.s = "toc" THEN (* Print contents. *)
       NEW(TT); Texts.Open(TT, "");
       Texts.Append(TT, WT.buf);
       PrintPF(TT)
      ELSIF S.s = "lof" THEN (* Print list of figures and tables. *)
       Texts.Append(TF, WF.buf);
       PrintPF(TF) (* Print list of figures. *)
      ELSIF S.s = "index" THEN Alphabet(TI); PrintPF(TI) (* Print index. *)
      ELSE (* Try as file *)
       NEW(T); Texts.Open(T, S.s);
       IF T.len > 0 THEN (* Format and print this chapter of a book. *)
        Out.String("Publisher.Print "); Out.String(S.s); Out.Ln;
        IF adjust THEN EditTools.ChangeFontSize (T, 0, T.len, oldsize, newsize) END;
        PrintText(T)
       ELSE Out.String(S.s); Out.String("  not found")
       END
      END
     END;
     Out.Ln
    ELSE EXIT
    END
   END;
   Printer.Close;

   IF debug THEN
    NEW(TD); Texts.Open(TD, "");
    Texts.Append(TD, WD.buf);
    TextDocs.ShowText("Publisher.debug", TD, Display.Width DIV 2, 300)
   END
  ELSE PrinterErr
  END
 ELSE Out.String("  no printer specified"); Out.Ln
 END
END Print;

(* Used only by AdjustStyles and SetStyles. *)
PROCEDURE pixel (x: LONGINT): LONGINT;
BEGIN RETURN (x * Printer.Unit + DisplayUnit DIV 2) DIV DisplayUnit;
END pixel;

PROCEDURE AdjustStyles*;
VAR T: Texts.Text; F: Display.Frame; R: Texts.Reader; ch: CHAR; obj: Objects.Object;
BEGIN
 T := TextDocs.GetText(F);
 IF T # NIL THEN
  Texts.OpenReader(R, T, 0);
  Texts.Read(R, ch);
  WHILE ~R.eot DO
   IF ~(R.lib IS Fonts.Font) THEN
    R.lib.GetObj(R.lib, ORD(ch), obj);
    IF obj IS TextGadgets.Style THEN
     WITH obj: TextGadgets.Style DO
      IF obj.leftM + obj.width > pixel(TextWidth) THEN
       obj.width := SHORT(pixel(TextWidth) - obj.leftM); obj.W := obj.leftM + obj.width
      END
     END
    END
   END;
   Texts.Read(R, ch)
  END;
  F(TextGadgets0.Frame).trailer := NIL; Gadgets.Update(F)
 END
END AdjustStyles;

PROCEDURE SetStyles*;
VAR T: Texts.Text; F: Display.Frame; R: Texts.Reader; ch: CHAR; obj: Objects.Object;
BEGIN
 T := TextDocs.GetText(F);
 IF T # NIL THEN
  Texts.OpenReader(R, T, 0);
  Texts.Read(R, ch);
  WHILE ~R.eot DO
   IF ~(R.lib IS Fonts.Font) THEN
    R.lib.GetObj(R.lib, ORD(ch), obj);
    IF obj IS TextGadgets.Style THEN
     WITH obj: TextGadgets.Style DO
      IF obj.leftM + obj.width # pixel(TextWidth) THEN
       obj.width := SHORT(pixel(TextWidth) - obj.leftM); obj.W := obj.leftM + obj.width
      END
     END
    END
   END;
   Texts.Read(R, ch)
  END;
  F(TextGadgets0.Frame).trailer := NIL; Gadgets.Update(F)
 END
END SetStyles;

PROCEDURE InitHyphenator;
VAR i: INTEGER;
BEGIN
 Hyphen.Load("HyphenES.Text");
 FOR i := 0 TO 255 DO validletter[i] := FALSE END;
 FOR i := ORD("A") TO ORD("Z") DO validletter[i] := TRUE END;
 FOR i := ORD("a") TO ORD("z") DO validletter[i] := TRUE END;
 validletter[ORD("ä")] := TRUE;
 validletter[ORD("Ä")] := TRUE;
 validletter[ORD("ü")] := TRUE;
 validletter[ORD("Ü")] := TRUE;
 validletter[ORD("ö")] := TRUE;
 validletter[ORD("Ö")] := TRUE;
 validletter[ORD("é")] := TRUE;
 validletter[ORD("è")] := TRUE;
 validletter[ORD("ß")] := TRUE;
 validletter[ORD("-")] := TRUE
END InitHyphenator;

BEGIN
 Texts.OpenWriter(WD); debug := FALSE;
 Texts.OpenWriter(WL);
 SetDefaultPageLayout; InitHyphenator;
 COPY("Figure ", Figure); COPY("Table ", Table)
END Publisher.
----------------------------
Sample formatting instruction file:

Publisher.Print
 AdjustBaseFont 12 => 13
 MarkersOff

 HeadersOn FootersOn
 RevisionsOn ColorsOff

 EvenHeader "Chapter 1"
 OddHeader "Introduction and Design Principles"
  Chapter1.Text

 EvenHeader "Chapter 2"
 OddHeader "The Basic System"
  Chapter2.Text

 EvenHeader "Index"
 OddHeader "The Oberon Companion"
  index

 EvenHeader "Contents"
 OddHeader "The Oberon Companion"
  toc
~
------------------------

