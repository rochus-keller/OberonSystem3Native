(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE PrinterInfo; (** portable *)
 IMPORT Objects, Display, Fonts, Printer, Pictures, Strings, Texts, Oberon, Attributes, Gadgets;

 VAR
  W: Texts.Writer;

 PROCEDURE Int(name: ARRAY OF CHAR; val: LONGINT);
  VAR obj: Objects.Object;
 BEGIN
  obj := Gadgets.FindObj(Gadgets.context, name);
  IF obj # NIL THEN
   Attributes.SetInt(obj, "Value", val);
   Gadgets.Update(obj)
  END
 END Int;

 PROCEDURE FixedStr(val: REAL; VAR str: ARRAY OF CHAR);
  VAR v, i: LONGINT;
 BEGIN
  v := ENTIER(val*100.0+0.5); i := 1;
  IF v >= 1000 THEN
   str[0] := CHR(ORD("0")+v DIV 1000)
  ELSE
   COPY(" ", str)
  END;
  str[i] := CHR(ORD("0")+(v DIV 100) MOD 10); INC(i);
  str[i] := "."; INC(i);
  str[i] := CHR(ORD("0")+(v DIV 10) MOD 10); INC(i);
  str[i] := CHR(ORD("0")+v MOD 10); INC(i);
  str[i] := 0X
 END FixedStr;

 PROCEDURE Fixed(name: ARRAY OF CHAR; val: REAL);
  VAR
   obj: Objects.Object;
   str: ARRAY 8 OF CHAR;
 BEGIN
  obj := Gadgets.FindObj(Gadgets.context, name);
  IF obj # NIL THEN
   FixedStr(val, str);
   Attributes.SetString(obj, "Value", str);
   Gadgets.Update(obj)
  END
 END Fixed;

 PROCEDURE Str(name, val: ARRAY OF CHAR);
  VAR obj: Objects.Object;
 BEGIN
  obj := Gadgets.FindObj(Gadgets.context, name);
  IF obj # NIL THEN
   Attributes.SetString(obj, "Value", val);
   Gadgets.Update(obj)
  END
 END Str;

 PROCEDURE unit(VAR cm: BOOLEAN);
  VAR
   obj: Objects.Object;
   i: LONGINT;
 BEGIN
  obj := Gadgets.FindObj(Gadgets.context, "unit");
  IF obj # NIL THEN
   Attributes.GetInt(obj, "Value", i);
   cm := i = 0
  ELSE
   cm := TRUE
  END
 END unit;

 PROCEDURE PrInfo();
  VAR
   P: Printer.Printer;
   cm: BOOLEAN;
 BEGIN
  unit(cm);
  P := Printer.current;
  IF P # NIL THEN
   Str("driver", P.name);
   Int("res", 914400 DIV P.Unit);
   IF cm THEN
    Fixed("width", P.Unit*P.Width / 360000.0);
    Fixed("height", P.Unit*P.Height / 360000.0)
   ELSE
    Fixed("width", P.Unit*P.Width / 36000.0 / 25.4);
    Fixed("height", P.Unit*P.Height / 36000.0 / 25.4)
   END
  ELSE
   Str("driver", "no printer installed");
   Fixed("width", 0.0); Fixed("height", 0.0);
   Fixed("res", 0.0)
  END
 END PrInfo;

 PROCEDURE PgInfo();
  VAR
   P: Printer.Printer;
   cm: BOOLEAN;
 BEGIN
  unit(cm);
  P := Printer.current;
  IF P # NIL THEN
   IF cm THEN
    Fixed("left", P.Unit*P.FrameX / 360000.0);
    Fixed("bottom", P.Unit*P.FrameY / 360000.0);
    Fixed("right", P.Unit*(P.Width-P.FrameW-P.FrameX) / 360000.0);
    Fixed("top", P.Unit*(P.Height-P.FrameH-P.FrameY) / 360000.0)
   ELSE
    Fixed("left", P.Unit*P.FrameX / 36000.0 / 25.4);
    Fixed("bottom", P.Unit*P.FrameY / 36000.0 / 25.4);
    Fixed("right", P.Unit*(P.Width-P.FrameW-P.FrameX) / 36000.0 / 25.4);
    Fixed("top", P.Unit*(P.Height-P.FrameH-P.FrameY) / 36000.0 / 25.4)
   END
  ELSE
   Fixed("left", 0.0); Fixed("right", 0.0);
   Fixed("top", 0.0); Fixed("bottom", 0.0)
  END
 END PgInfo;

 PROCEDURE Update*;
  VAR
   S: Texts.Scanner;
   res: INTEGER;
 BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Texts.Scan(S);
  IF S.class = Texts.Name THEN
   Oberon.Call(S.s, Oberon.Par, FALSE, res);
   Gadgets.context := Gadgets.context.dlink
  END;
  PrInfo(); PgInfo()
 END Update;

 PROCEDURE Print*;
  VAR
   S: Texts.Scanner;
   fnt: Fonts.Font;
   str: ARRAY 64 OF CHAR;
   text: ARRAY 256 OF CHAR;
   P: Printer.Printer;
   t, d: LONGINT;
   pict: Pictures.Picture;
   cm1, cm4, left, left1, left2, FrameTop, y, dy, i, r, g, b: INTEGER;
   cm: BOOLEAN;
 BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Texts.Scan(S);
  IF S.class IN {Texts.Name, Texts.String} THEN
   COPY(S.s, str); Texts.Scan(S);
   IF S.class IN {Texts.Name, Texts.String} THEN
    COPY(S.s, text)
   ELSE
    text := ""
   END;
   Strings.AppendCh(text, Oberon.OptionChar);
   Strings.Append(text, "Oberon System 3 Printer Test Page");
   Printer.Open(str, text);
   IF Printer.res = 0 THEN
    P := Printer.current; unit(cm);
    Texts.WriteString(W, "Printing test page on "); Texts.WriteString(W, str);
    Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
    IF S.s # "" THEN
     Texts.WriteString(W, ", options: "); Texts.WriteString(W, S.s)
    END;
    FrameTop := P.FrameY+P.FrameH;

    Printer.ReplConst(P.FrameX, P.FrameY, P.FrameW, 1);
    Printer.ReplConst(P.FrameX, P.FrameY, 1, P.FrameH);
    Printer.ReplConst(P.FrameX, FrameTop-1, P.FrameW, 1);
    Printer.ReplConst(P.FrameX+P.FrameW-1, P.FrameY, 1, P.FrameH);

    cm1 := SHORT(ENTIER((360000.0 / P.Unit)+0.5));
    left := SHORT(ENTIER(P.FrameX+0.5*cm1+0.5));
    left1 := SHORT(ENTIER(left+0.5*cm1+0.5)); left2 := SHORT(ENTIER(left+3.0*cm1+0.5));

    fnt := Fonts.This("Syntax24.Scn.Fnt"); text := "Oberon System 3 Printer Test Page";
    Printer.String(left, SHORT(ENTIER(FrameTop-1.25*cm1+0.5)), text, fnt);
    Printer.ReplConst(P.FrameX, SHORT(ENTIER(FrameTop-2.0*cm1+0.5)), P.FrameW, 1);

    y := SHORT(ENTIER(FrameTop-3.0*cm1+0.5)); dy := SHORT(ENTIER(0.5*cm1+0.5));
    fnt := Fonts.This("Syntax12m.Scn.Fnt"); text := "Printer Information";
    Printer.String(left, y, text, fnt); DEC(y, dy);

    fnt := Fonts.This("Syntax12.Scn.Fnt"); text := "Printer Driver:";
    Printer.String(left1, y, text, fnt);
    Printer.String(left2, y, P.name, fnt); DEC(y, dy);

    text := "Resolution:";
    Printer.String(left1, y, text, fnt);
    Strings.IntToStr(914400 DIV P.Unit, text); Strings.Append(text, " dpi");
    Printer.String(left2, y, text, fnt); DEC(y, dy);

    IF cm THEN
     text := "Page Width:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.Width / 360000.0, text); Strings.Append(text, " cm");
     Printer.String(left2, y, text, fnt); DEC(y, dy);
 
     text := "Page Height:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.Height / 360000.0, text); Strings.Append(text, " cm");
     Printer.String(left2, y, text, fnt); DEC(y, dy);
    ELSE
     text := "Page Width:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.Width / 36000.0 / 25.4, text); Strings.Append(text, " inch");
     Printer.String(left2, y, text, fnt); DEC(y, dy);
 
     text := "Page Height:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.Height / 36000.0, text); Strings.Append(text, " inch");
     Printer.String(left2, y, text, fnt); DEC(y, dy)
    END;

    y := SHORT(ENTIER(FrameTop-3.0*cm1+0.5)); left := SHORT(ENTIER(P.FrameX+P.FrameW/2.0+0.5));
    left1 := SHORT(ENTIER(left+0.5*cm1+0.5)); left2 := SHORT(ENTIER(left+3.0*cm1+0.5));
    fnt := Fonts.This("Syntax12m.Scn.Fnt"); text := "Page Setup";
    Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Syntax12.Scn.Fnt"); DEC(y, dy);

    IF cm THEN
     text := "Left Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.FrameX / 360000.0, text); Strings.Append(text, " cm");
     Printer.String(left2, y, text, fnt); DEC(y, dy);

     text := "Right Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*(P.Width-P.FrameW-P.FrameX) / 360000.0, text); Strings.Append(text, " cm");
     Printer.String(left2, y, text, fnt); DEC(y, dy);

     text := "Bottom Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.FrameY / 360000.0, text); Strings.Append(text, " cm");
     Printer.String(left2, y, text, fnt); DEC(y, dy);

     text := "Top Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*(P.Height-P.FrameH-P.FrameY) / 360000.0, text); Strings.Append(text, " cm");
     Printer.String(left2, y, text, fnt); DEC(y, dy)
    ELSE
     text := "Left Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.FrameX / 36000.0 / 25.4, text); Strings.Append(text, " inch");
     Printer.String(left2, y, text, fnt); DEC(y, dy);

     text := "Right Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*(P.Width-P.FrameW-P.FrameX) / 36000.0 / 25.4, text); Strings.Append(text, " inch");
     Printer.String(left2, y, text, fnt); DEC(y, dy);

     text := "Bottom Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*P.FrameY / 36000.0 / 25.4, text); Strings.Append(text, " inch");
     Printer.String(left2, y, text, fnt); DEC(y, dy);

     text := "Top Margin:";
     Printer.String(left1, y, text, fnt);
     FixedStr(P.Unit*(P.Height-P.FrameH-P.FrameY) / 36000.0 / 25.4, text); Strings.Append(text, " inch");
     Printer.String(left2, y, text, fnt); DEC(y, dy)
    END;

    left := SHORT(ENTIER(P.FrameX+0.5*cm1+0.5));
    DEC(y, dy); fnt := Fonts.This("Syntax12m.Scn.Fnt"); text := "Font Test";
    Printer.String(left, y, text, fnt);
    DEC(y, dy); DEC(y, dy);

    fnt := Fonts.This("Syntax10.Scn.Fnt"); text := "Syntax10 "; Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Syntax12.Scn.Fnt"); text := "Syntax12 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax14.Scn.Fnt"); text := "Syntax14 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax16.Scn.Fnt"); text := "Syntax16 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax20.Scn.Fnt"); text := "Syntax20 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax24.Scn.Fnt"); text := "Syntax24 "; Printer.ContString(text, fnt);
    DEC(y, dy); DEC(y, dy);

    fnt := Fonts.This("Syntax10i.Scn.Fnt"); text := "Syntax10i "; Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Syntax12i.Scn.Fnt"); text := "Syntax12i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax14i.Scn.Fnt"); text := "Syntax14i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax16i.Scn.Fnt"); text := "Syntax16i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax20i.Scn.Fnt"); text := "Syntax20i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax24i.Scn.Fnt"); text := "Syntax24i "; Printer.ContString(text, fnt);
    DEC(y, dy); DEC(y, dy);

    fnt := Fonts.This("Syntax10m.Scn.Fnt"); text := "Syntax10m "; Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Syntax12m.Scn.Fnt"); text := "Syntax12m "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax14m.Scn.Fnt"); text := "Syntax14m "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax16m.Scn.Fnt"); text := "Syntax16m "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax20m.Scn.Fnt"); text := "Syntax20m "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax24m.Scn.Fnt"); text := "Syntax24m "; Printer.ContString(text, fnt);
    DEC(y, dy); DEC(y, dy);

    fnt := Fonts.This("Syntax10b.Scn.Fnt"); text := "Syntax10b "; Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Syntax12b.Scn.Fnt"); text := "Syntax12b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax14b.Scn.Fnt"); text := "Syntax14b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax16b.Scn.Fnt"); text := "Syntax16b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax20b.Scn.Fnt"); text := "Syntax20b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Syntax24b.Scn.Fnt"); text := "Syntax24b "; Printer.ContString(text, fnt);
    DEC(y, dy); DEC(y, dy);

    fnt := Fonts.This("Oberon10.Scn.Fnt"); text := "Oberon10 "; Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Oberon12.Scn.Fnt"); text := "Oberon12 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon14.Scn.Fnt"); text := "Oberon14 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon16.Scn.Fnt"); text := "Oberon16 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon20.Scn.Fnt"); text := "Oberon20 "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon24.Scn.Fnt"); text := "Oberon24 "; Printer.ContString(text, fnt);
    DEC(y, dy); DEC(y, dy);

    fnt := Fonts.This("Oberon10i.Scn.Fnt"); text := "Oberon10i "; Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Oberon12i.Scn.Fnt"); text := "Oberon12i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon14i.Scn.Fnt"); text := "Oberon14i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon16i.Scn.Fnt"); text := "Oberon16i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon20i.Scn.Fnt"); text := "Oberon20i "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon24i.Scn.Fnt"); text := "Oberon24i "; Printer.ContString(text, fnt);
    DEC(y, dy); DEC(y, dy);

    fnt := Fonts.This("Oberon10b.Scn.Fnt"); text := "Oberon10b "; Printer.String(left, y, text, fnt);
    fnt := Fonts.This("Oberon12b.Scn.Fnt"); text := "Oberon12b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon14b.Scn.Fnt"); text := "Oberon14b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon16b.Scn.Fnt"); text := "Oberon16b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon20b.Scn.Fnt"); text := "Oberon20b "; Printer.ContString(text, fnt);
    fnt := Fonts.This("Oberon24b.Scn.Fnt"); text := "Oberon24b "; Printer.ContString(text, fnt);
    DEC(y, dy);

    DEC(y, dy); fnt := Fonts.This("Syntax12m.Scn.Fnt"); text := "Pattern Test";
    Printer.String(left, y, text, fnt);
    DEC(y, dy); DEC(y, dy); DEC(y, dy);
    left1 := SHORT(ENTIER(P.FrameX+(P.FrameW-16*cm1)/2.0+0.5));
    FOR i := 0 TO 15 DO
     Printer.ReplPattern(left1+i*cm1, y, cm1, cm1, i)
    END; DEC(y, dy);

    DEC(y, dy); fnt := Fonts.This("Syntax12m.Scn.Fnt"); text := "Color Test";
    Printer.String(left, y, text, fnt); DEC(y, dy); DEC(y, cm1);
    cm4 := SHORT(ENTIER((360000.0 / P.Unit / 4.0)+0.5));

    FOR i := 0 TO 255 DO
     Display.GetColor(i, r, g, b);
     Printer.UseColor(r, g, b);
     Printer.ReplConst(left1+(i MOD 64)*cm4, y+(i DIV 64)*cm4, cm4, cm4)
    END;
    Printer.UseColor(0, 0, 0);

    DEC(y, dy); DEC(y, dy); fnt := Fonts.This("Syntax12m.Scn.Fnt"); text := "Miscellaneous Test";
    Printer.String(left, y, text, fnt); DEC(y, dy);

    Printer.Line(left1, y-cm1, left1, y); Printer.Line(left1+16*cm1, y-cm1,left1+16*cm1, y);
    Printer.Line(left1, y-cm1, left1+16*cm1, y);  Printer.Line(left1, y, left1+16*cm1, y-cm1);
    Printer.Line(left1, y, left1+16*cm1, y); Printer.Line(left1, y-cm1, left1+16*cm1, y-cm1);
    Printer.Circle(left1+8*cm1, SHORT(ENTIER(y-cm1/2.0+0.5)), SHORT(ENTIER(cm1/2.0+0.5)));
    FOR i := 1 TO 8 DO
     Printer.Ellipse(left1+8*cm1, SHORT(ENTIER(y-cm1/2.0+0.5)), i*cm1, SHORT(ENTIER(cm1/2.0+0.5)))
    END;

    NEW(pict); Pictures.Open(pict, "Default.Pict", TRUE);
    Printer.Picture(pict, 0, 0, pict.width, pict.height, left1, SHORT(ENTIER(P.FrameY+1.5*cm1+0.5)), 16*cm1, y-P.FrameY-3*cm1, Display.replace);

    Printer.ReplConst(P.FrameX, P.FrameY+cm1, P.FrameW, 1);
    fnt := Fonts.This("Syntax12.Scn.Fnt"); text := "Printed on ";
    Strings.Append(text, str);
    IF S.s # "" THEN
     Strings.Append(text, ", options: "); Strings.Append(text, S.s)
    END;
    Printer.String(left, SHORT(ENTIER(P.FrameY+0.3*cm1+0.5)), text, fnt);
    Oberon.GetClock(t, d);
    Strings.TimeToStr(t, text); Strings.DateToStr(d, str);
    Strings.AppendCh(text, " "); Strings.Append(text, str);
    Printer.String(SHORT(ENTIER(Printer.FrameX+P.FrameW-3.5*cm1+0.5)), SHORT(ENTIER(P.FrameY+0.3*cm1+0.5)),
     text, fnt);
 
    Printer.Page(1); Printer.Close()
   ELSE
    Texts.WriteString(W, "Printer.Open failed")
   END;
   Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
  END
 END Print;

BEGIN
 Texts.OpenWriter(W)
END PrinterInfo.

PrinterInfo.Panel

System.Free PrinterInfo ~
