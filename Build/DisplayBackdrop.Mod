(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE DisplayBackdrop; (* pjm *)

(* Display a backdrop in the user track filler *)

IMPORT Modules, Objects, Display, Viewers, Texts, Oberon, Effects, Display3, Colors, Images, ImageGadgets, ColorModels;

VAR
 oldhandle: Objects.Handler;
 fill: Display.Frame;
 f: ImageGadgets.Frame;
 color: Display.Color;
 
PROCEDURE Restore(x, y, w, h: INTEGER);
VAR fx, fy: INTEGER;  m: Display3.Mask;
BEGIN
 IF f.W >= fill.W THEN fx := 0 ELSE fx := (fill.W-f.W) DIV 2 END;
 IF f.H >= Display.Height THEN fy := 0 ELSE fy := (Display.Height-f.H) DIV 2 END;
 NEW(f.mask);  Display3.Open(f.mask);
 Display3.Add(f.mask, x, y, w, h);
 Display3.Copy(f.mask, m);
 Display3.Subtract(m, fx, fy, f.W, f.H);
 Oberon.RemoveMarks(x, y, w, h);
 Display3.ReplConst(m, color, x, y, w, h, Display.replace);
 ImageGadgets.Restore(f, 0, 0, f.W, f.H, fx, fy, f.mask)
END Restore;

PROCEDURE Handler(v: Objects.Object;  VAR m: Objects.ObjMsg);
BEGIN
 WITH v: Viewers.Viewer DO
  IF m IS Display.DisplayMsg THEN
   WITH m: Display.DisplayMsg DO
    IF (m.device = Display.screen) & ((m.F = v) OR (m.F = NIL)) THEN
     Restore(v.X, v.Y, v.W, v.H)
    ELSE
     oldhandle(v, m)
    END
   END
  ELSIF m IS Display.ControlMsg THEN
   WITH m: Display.ControlMsg DO
    IF (m.id = Display.restore) & (v.W > 0) & (v.H > 0) THEN
     Restore(v.X, v.Y, v.W, v.H)
    ELSE
     oldhandle(v, m)
    END
   END
  ELSIF m IS Display.ModifyMsg THEN
   WITH m: Display.ModifyMsg DO
    IF (m.F = v) & (m.id = Display.extend) THEN
     Restore(v.X, m.Y, v.W, v.Y - m.Y)
    ELSE
     oldhandle(v, m)
    END
   END
  ELSIF m IS Oberon.InputMsg THEN
   WITH m: Oberon.InputMsg DO
    IF m.id = Oberon.track THEN
     Oberon.DrawCursor(Oberon.Mouse, Effects.Arrow, m.X, m.Y)
    ELSE
     oldhandle(v, m)
    END
   END
  ELSE
   oldhandle(v, m)
  END
 END
END Handler;

PROCEDURE Close*;
VAR ctrl: Display.ControlMsg;
BEGIN
 IF fill # NIL THEN
  fill.handle := oldhandle;
  IF (fill.W > 0) & (fill.H > 0) THEN
   ctrl.id := Display.restore;  ctrl.F := NIL;  ctrl.x := 0;  ctrl.y := 0;  ctrl.res := -1;
   fill.handle(fill, ctrl)
  END;
  fill := NIL;  f := NIL
 END
END Close;

PROCEDURE Open*; (* name [color] *)
VAR
 bot, alt, max: Display.Frame;  done: BOOLEAN;  name: ARRAY 32 OF CHAR;
 m: Images.Image;  s: Texts.Scanner;  r, g, b: REAL;  ok: BOOLEAN;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class = Texts.Name THEN
  COPY(s.s, name);
  color := 12;
  Texts.Scan(s);
  IF s.class = Texts.Int THEN
   color := s.i
  ELSIF s.class = Texts.Name THEN
   ColorModels.StrToRGB(s.s, r, g, b, ok);
   IF ok THEN
    IF Display.TrueColor(0) THEN
     color := Display.RGB(ENTIER(r*255), ENTIER(g*255), ENTIER(b*255))
    ELSE
     color := Colors.Match(Colors.DisplayIndex, Colors.DisplayBits, SHORT(ENTIER(r*255)), SHORT(ENTIER(g*255)), SHORT(ENTIER(b*255)))
    END
   END
  ELSE
   (* skip *)
  END;
  NEW(m);  Images.Load(m, name, done);
  IF done THEN
   IF fill # NIL THEN Close END;
   NEW(f);  ImageGadgets.Init(f, m);
   Viewers.Locate(0, 0, fill, bot, alt, max);
   oldhandle := fill.handle;
   fill.handle := Handler;
   IF (fill.W > 0) & (fill.H > 0) THEN Restore(fill.X, fill.Y, fill.W, fill.H) END
  END
 END
END Open;

BEGIN
 fill := NIL;
 Modules.InstallTermHandler(Close)
END DisplayBackdrop.

DisplayBackdrop.Open chagall1.jpg Black
DisplayBackdrop.Open chapmanspeak.bmp RoyalBlue
DisplayBackdrop.Open tafelbird.bmp DeepSkyBlue
DisplayBackdrop.Open ArlesCloitre5.jpg DarkGoldenRod
DisplayBackdrop.Open sunflowers.bmp DarkGoldenRod

DisplayBackdrop.Close

System.Free DisplayBackdrop ~
