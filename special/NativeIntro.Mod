(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE NativeIntro; (** portable *) (* devil@cs.sun.ac.za *)

(* Sierpinski carpet *)

IMPORT
 Display, Fonts, Objects, Input, Texts, Oberon;

CONST
 System = "Oberon_0";

VAR
 font: Fonts.Font;

PROCEDURE DisplayString(col, x, y, mx: INTEGER;  s: ARRAY OF CHAR);
VAR i: INTEGER;  obj: Objects.Object;  char: Fonts.Char;
BEGIN
 i := 0;
 WHILE s[i] # 0X DO
  font.GetObj(font, ORD(s[i]), obj);
  char := obj(Fonts.Char);
  IF x + char.x + char.w <= mx THEN
   Display.CopyPattern(col, char.pat, x + char.x, y + char.y, Display.invert)
  END;
  x := x + char.dx;
  INC(i)
 END
END DisplayString;
 
PROCEDURE StringWidth(s: ARRAY OF CHAR): INTEGER;
VAR i, w: INTEGER;  obj: Objects.Object;
BEGIN
 i := 0;  w := 0;
 WHILE s[i] # 0X DO
  font.GetObj(font, ORD(s[i]), obj);
  INC(w, obj(Fonts.Char).dx);
  INC(i)
 END;
 RETURN w+2
END StringWidth;

PROCEDURE Center(y: INTEGER;  s: ARRAY OF CHAR);
VAR w: INTEGER;
BEGIN
 w := StringWidth(s);
 DisplayString(Display.FG, (Display.Width DIV 8 * 5-w) DIV 2, y - 4, MAX(INTEGER), s)
END Center;

PROCEDURE Carpet(startx, starty, stopx, stopy, level : INTEGER);
CONST H = 10;
VAR
 xbreak, ybreak,
 i, j, k, l, m, n, w: INTEGER;
 s: ARRAY 32 OF CHAR;
BEGIN
 xbreak := (stopx - startx) DIV 3;
 ybreak := (stopy - starty) DIV 3;
 IF (xbreak > 0) & (ybreak > 0) & (level > 0) THEN
  k := startx + xbreak;
  l := stopx - xbreak;
  m := starty + ybreak;
  n := stopy - ybreak;
  Carpet(startx, starty, k, m, level - 1);
  Carpet(k, starty, l, m, level -1);
  Carpet(l, starty, stopx, m, level - 1);
  Carpet(startx, m, k, n, level - 1);
  Display.ReplConst((15 - level), k, m, l - k, n - m, Display.replace);
  s := "Welcome";  w := StringWidth(s);
  IF w < l - k THEN
   DisplayString(Display.FG, k + (l-k-w) DIV 2, m + (n-m-5*H) DIV 2 + 4*H, MAX(INTEGER), s);
   s := "to";  w := StringWidth(s);
   DisplayString(Display.FG, k + (l-k-w) DIV 2, m + (n-m-5*H) DIV 2 + 2*H, MAX(INTEGER), s);
   s := System;  w := StringWidth(s);
   DisplayString(Display.FG, k + (l-k-w) DIV 2, m + (n-m-5*H) DIV 2, MAX(INTEGER), s)
  END;
  Carpet(l, m, stopx, n, level - 1);
  Carpet(startx, n, k, stopy, level - 1);
  Carpet(k, n, l, stopy, level - 1);
  Carpet(l, n, stopx, stopy, level - 1)
 END
END Carpet;

PROCEDURE Draw*; (* [delay.ms] ~ *)
VAR s: Texts.Scanner;  t: LONGINT;
BEGIN
 Display.ReplConst(Display.BG, 0, 0, Display.Width, Display.Height, Display.replace);
 Carpet(0, 0, Display.Width, Display.Height, 6);
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class = Texts.Int THEN
  t := Input.Time() + s.i*1000 DIV Input.TimeUnit;
  REPEAT UNTIL Input.Time() - t > 0
 END
END Draw;

BEGIN
 font := Fonts.This("Oberon10.Scn.Fnt")
END NativeIntro.

NativeIntro.Draw 1000
NativeIntro.Draw ~
