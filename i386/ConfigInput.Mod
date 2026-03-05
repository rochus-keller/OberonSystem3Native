(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE ConfigInput; (* pjm *)

(* based on TableFrames *)
(* autodetect mouse PDR 23.3.00 - see also changes to Input.Mod *)

IMPORT Kernel, OFS, Objects, Display, Input, Viewers, Fonts, Texts, Oberon, MenuViewers, TextFrames, V24;

CONST
 right = 0;  middle = 1;  left = 2; (* mouse keys *)

 BG = 14;  Black = 15;  White = 0;
 
 Width = 16;  Height = 24;  Space = 2;
 MWidth = 3*Width + 2*Space;  MHeight = 3*Height + Space;

 NumTypes = 10;
 
 PS2 = 0; MSI = 1; LM1 = 2; MSM = 9;
 
 WaitTime = Input.TimeUnit DIV 100;
 
 FullScreen = TRUE;
 
TYPE
 Frame* = POINTER TO RECORD (Display.Frame)
  keys: SET;
  x, y: INTEGER;
  text: Texts.Text
 END;

VAR
 w: Texts.Writer;
 type: INTEGER;
 mt, mp: ARRAY 8 OF CHAR;
 V: MenuViewers.Viewer;
 maxport: CHAR;
 ps2: BOOLEAN;
 mouseIdent: POINTER TO ARRAY OF CHAR;
 watch: Oberon.Task;
 watchx, watchy: INTEGER;
 watchshift: BOOLEAN;

PROCEDURE WriteParams*(VAR w: Texts.Writer);

 PROCEDURE Quote;
 BEGIN
  Texts.Write(w, 22X)
 END Quote;
 
BEGIN
 Texts.WriteString(w, " MT=");  Quote;  Texts.WriteString(w, mt);  Quote;
 Texts.WriteString(w, " MP=");  Quote;  Texts.WriteString(w, mp);  Quote;
 Texts.WriteString(w, ' MB="-3"')
END WriteParams;

PROCEDURE DrawButton(F: Frame;  num: INTEGER;  pressed: BOOLEAN);
CONST W = Width-Space;  H = Height-Space;
VAR x, y, h: INTEGER;
BEGIN
 x := F.x + 1 + num*Width + Space;  y := F.y + 1 + 2*Height;  h := H;
 IF (num = 1) & Oberon.New THEN DEC(h, H DIV 3); INC(y, H DIV 3) END;
 Oberon.RemoveMarks(x, y, W, h);
 IF pressed THEN
  Display.ReplConst(Black, x, y, W, h, Display.replace)
 ELSE
  Display.ReplConst(Black, x, y, W, 1, Display.replace);
  Display.ReplConst(Black, x, y+h-1, W, 1, Display.replace);
  Display.ReplConst(Black, x, y, 1, h, Display.replace);
  Display.ReplConst(Black, x+W-1, y, 1, h, Display.replace);
  Display.ReplConst(White, x+1, y+1, W-2, h-2, Display.replace)
 END
END DrawButton;

PROCEDURE DrawMouse(F: Frame;  x, y: INTEGER;  keys: SET);
BEGIN
 DEC(x, MWidth DIV 2);  DEC(y, MHeight DIV 2);
 IF x < F.X THEN x := F.X
 ELSIF x+MWidth > F.X+F.W THEN x := F.X+F.W-MWidth
 END;
 IF y < F.Y THEN y := F.Y
 ELSIF y+MHeight > F.Y+F.H THEN y := F.Y+F.H-MHeight
 END;
 IF (F.W >= MWidth) & (F.H >= MHeight) THEN
  IF (x # F.x) OR (y # F.y) THEN
   Oberon.RemoveMarks(F.x, F.y, MWidth, MHeight);
   Display.ReplConst(BG, F.x, F.y, MWidth, MHeight, Display.replace);
   F.x := x;  F.y := y;
   Oberon.RemoveMarks(x, y, MWidth, MHeight);
   Display.ReplConst(Black, x, y, MWidth, 1, Display.replace);
   Display.ReplConst(Black, x, y+MHeight-1, MWidth, 1, Display.replace);
   Display.ReplConst(Black, x, y, 1, MHeight, Display.replace);
   Display.ReplConst(Black, x+MWidth-1, y, 1, MHeight, Display.replace);
   Display.ReplConst(White, x+1, y+1, MWidth-2, MHeight-2, Display.replace);
   F.keys := -keys
  END;
  IF keys # F.keys THEN
   F.keys := keys;
   DrawButton(F, 0, left IN keys);
   DrawButton(F, 1, middle IN keys);
   DrawButton(F, 2, right IN keys)
  END
 END
END DrawMouse;

PROCEDURE SetMT(value: ARRAY OF CHAR);
BEGIN
 Input.Configure("MT", value);
 COPY(value, mt)
END SetMT;

PROCEDURE UpdateMenu(F: Frame;  s: ARRAY OF CHAR);
VAR r: Texts.Reader;  ch: CHAR;  beg, end: LONGINT;
BEGIN
 IF s[0] = 0X THEN Texts.WriteString(w, "Detecting...")
 ELSE Texts.WriteString(w, mt);
  Texts.WriteString(w, " (");
  Texts.WriteString(w, s);
  Texts.WriteString(w, ") on ");
  IF type = PS2 THEN
   Texts.WriteString(w, "mouse port")
  ELSE
   Texts.WriteString(w, "COM");  Texts.WriteString(w, mp)
  END;
  IF mouseIdent # NIL THEN
   Texts.WriteString(w, " ["); Texts.WriteString(w, mouseIdent^); Texts.Write(w, "]")
  END
 END;

 Texts.OpenReader(r, F.text, 0);
 REPEAT Texts.Read(r, ch) UNTIL ch = "|";
 beg := Texts.Pos(r)+1;
 REPEAT Texts.Read(r, ch) UNTIL ch = 0DX;
 end := Texts.Pos(r)-1;
 Texts.Delete(F.text, beg, end);
 Texts.Insert(F.text, beg, w.buf)
END UpdateMenu;

PROCEDURE SetType(F: Frame);
VAR s: ARRAY 50 OF CHAR; ch: CHAR; 
BEGIN
 IF ~ps2 & (type = PS2) THEN INC(type) END;
 DrawMouse(F, F.x + MWidth DIV 2, F.y + MHeight DIV 2, {0..2});
 IF type # PS2 THEN
  Input.Configure("MP", mp)
 END;
 CASE type OF
  0: SetMT("PS2");  s := "PS/2-style"
  |1: SetMT("MSI");  s := "Microsoft IntelliMouse or new Logitech"
  |2: SetMT("LM1");  s := "Logitech type 1"
  |3: SetMT("LM2");  s := "Logitech type 2"
  |4: SetMT("LM3");  s := "Logitech type 3"
  |5: SetMT("MS1");  s := "Mouse Systems type 1"
  |6: SetMT("MS2");  s := "Mouse Systems type 2"
  |7: SetMT("MS3");  s := "Mouse Systems type 3"
  |8: SetMT("MS4");  s := "Mouse Systems type 4"
  |9: SetMT("MSM");  s := "Microsoft 2-button"
 END;
 WHILE Input.Available() # 0 DO Input.Read(ch) END;
 
 Input.Configure("MB", "-3"); (* middle button & Ctrl *)
 UpdateMenu(F, s)
END SetType;

PROCEDURE Reset(F: Frame);
 VAR np: INTEGER;
 
 PROCEDURE Detect(port: INTEGER): BOOLEAN;
  VAR portString: ARRAY 2 OF CHAR; ch: CHAR; n, i: INTEGER;
 BEGIN
  portString := "0"; portString[0] := CHR(ORD("0") + port);
  Input.Configure("MP", portString); Input.Configure("MT", "MSM"); (*arbitrary*)
  n := Input.Available();
  mouseIdent := NIL;
  IF n = 0 THEN RETURN FALSE END;
  REPEAT Input.Read(ch); DEC(n) UNTIL (n = 0) OR (ch = "M");
  IF ch # "M" THEN RETURN FALSE END;
  INC(n); NEW(mouseIdent, n+1); mouseIdent[0] := ch; i := 1;
  WHILE i < n DO Input.Read(ch);
   IF (ch < " ") OR (ch >= 7FX) THEN ch := "." END;
   mouseIdent[i] := ch; INC(i)
  END;
  mouseIdent[i] := 0X;
  COPY(portString, mp);
  RETURN TRUE
 END Detect;

BEGIN
 UpdateMenu(F, "");
 np := SHORT(V24.NumberOfPorts());
 IF (np >= 1) & Detect(1) OR (np >= 2) & Detect(2) OR (np >= 3) & Detect(3) OR (np >= 4) & Detect(4) THEN
  IF mouseIdent[1] = "3" THEN type := LM1
  ELSIF mouseIdent[1] = "Z" THEN type := MSI
  ELSE type := MSM
  END
 ELSE type := PS2;  mp := "1"
 END;
 SetType(F); mouseIdent := NIL
END Reset;

PROCEDURE Close;
BEGIN
 IF FullScreen THEN Viewers.CloseTrack(0)
 ELSE Viewers.Close(V);  V := NIL
 END;
 Input.SetMouseLimits(0, 0, Viewers.curW, Display.Height);
 Texts.WriteString(w, "ConfigInput.Mouse ");
 Texts.WriteString(w, mt); Texts.WriteString(w, " ");
 Texts.WriteString(w, mp); Texts.WriteString(w, " -3 ~");
 Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf)
END Close;

PROCEDURE InputMsg(F: Frame; VAR M: Oberon.InputMsg);
BEGIN
 IF M.id = Oberon.track THEN
  Oberon.FadeCursor(Oberon.Mouse);
  DrawMouse(F, M.X, M.Y, M.keys)
 ELSIF M.id = Oberon.consume THEN
  IF CAP(M.ch) = "M" THEN
   type := (type+1) MOD NumTypes;
   SetType(F)
  ELSIF (M.ch >= "1") & (M.ch <= maxport) THEN
   IF type = PS2 THEN INC(type) END;
   mp[0] := M.ch;  mp[1] := 0X;
   SetType(F)
  ELSIF CAP(M.ch) = "C" THEN
   Close
  ELSIF CAP(M.ch) = "R" THEN
   Reset(F)
  ELSE (* skip *)
  END
 END
END InputMsg;

PROCEDURE Neutralize (F : Frame);
BEGIN
 Oberon.RemoveMarks (F.X, F.Y, F.W, F.H)
END Neutralize;

PROCEDURE ControlMsg(F: Frame; VAR M: Oberon.ControlMsg);
BEGIN
 IF M.id = Oberon.neutralize THEN Neutralize(F) END
END ControlMsg;

PROCEDURE CopyMsg(F: Frame; VAR M: Objects.CopyMsg);
VAR F1: Frame;
BEGIN
 NEW(F1);  F1.handle := Handler;  
 F1.keys := F.keys; F1.text := F.text;
 M.obj := F1
END CopyMsg;

PROCEDURE ModifyMsg(F: Frame; M: Display.ModifyMsg);
BEGIN
 Neutralize(F);
 F.X := M.X;  F.Y := M.Y;
 F.W := M.W;  F.H := M.H;
 Display.ReplConst(BG, F.X, F.Y, F.W, F.H, Display.replace);
 Input.SetMouseLimits(F.X, F.Y, F.W, F.H);
 F.x := F.X+1;  F.y := 0;
 DrawMouse(F, F.X, F.Y, F.keys)
END ModifyMsg;

PROCEDURE Handler*(F: Objects.Object; VAR M: Objects.ObjMsg);
BEGIN
 WITH F: Frame DO
  IF M IS Oberon.InputMsg THEN InputMsg(F, M(Oberon.InputMsg))
  ELSIF M IS Oberon.ControlMsg THEN ControlMsg(F, M(Oberon.ControlMsg))
  ELSIF M IS Objects.CopyMsg THEN CopyMsg(F, M(Objects.CopyMsg))
  ELSIF M IS Display.ModifyMsg THEN ModifyMsg(F, M(Display.ModifyMsg))
  ELSE
  END
 END
END Handler;

PROCEDURE New*(t: Texts.Text): Frame;
VAR F: Frame;
BEGIN
 NEW(F);  F.handle := Handler;
 F.text := t;  F.keys := {};
 RETURN F
END New;

PROCEDURE SelectMouse*;
VAR menuF: TextFrames.Frame; mainF: Frame;  X, Y: INTEGER;
BEGIN
 menuF := TextFrames.NewMenu("Mouse Configuration", "");
 Texts.WriteLn(w);
 Texts.WriteLn(w);
 Texts.WriteString(w, "Moving the mouse should result in the icon below moving correspondingly.  Check that all combinations of the three mouse");
 Texts.WriteLn(w);
 Texts.WriteString(w, "buttons function correctly.  Press F8 to switch the special two-button mouse mode on or off.  If the current driver is ok,");
 Texts.WriteLn(w);
 Texts.WriteString(w, "press 'C' to continue, or otherwise press 'M' to switch the mouse type, or 'R' to reset it.  Press '1' for COM1 or '2' for COM2.");
 Texts.Append(menuF.text, w.buf);
 mainF := New(menuF.text);
 IF FullScreen THEN
  X := Display.Width;
  IF X > 640 THEN X := 640 END;
  Oberon.OpenTrack(0, X)
 END;
 Oberon.AllocateUserViewer (Oberon.Mouse.X, X, Y);
 V := MenuViewers.New (menuF, mainF, TextFrames.menuH + 4*Fonts.Default.height+2, X, Y);
 Reset(mainF)
END SelectMouse;

PROCEDURE Keyboard*; (** KeyXX.Bin | ^ *)
VAR s: Texts.Scanner; text: Texts.Text; beg, end, time: LONGINT;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF (s.class = Texts.Char) & (s.c = "^") THEN
  Oberon.GetSelection(text, beg, end, time);
  IF time # -1 THEN
   Texts.OpenScanner(s, text, beg);
   Texts.Scan(s)
  END
 END;
 IF s.class IN {Texts.Name, Texts.String} THEN
  Input.Configure("Keyboard", s.s)
 END
END Keyboard;

PROCEDURE ConfigInt(name: ARRAY OF CHAR; i: LONGINT);
VAR s: ARRAY 16 OF CHAR;
BEGIN
 s := ""; OFS.AppendInt(i, s);
 Input.Configure(name, s)
END ConfigInt;

PROCEDURE Mouse*; (** mt mp mb ~ *)
VAR s: Texts.Scanner; mp, mb: LONGINT; mt: ARRAY 32 OF CHAR;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class = Texts.Name THEN
  mp := 0; mb := -3;
  COPY(s.s, mt); Texts.Scan(s);
  IF s.class = Texts.Int THEN
   mp := s.i; Texts.Scan(s);
   IF s.class = Texts.Int THEN
    mb := s.i
   END
  END;
  IF mt # "PS2" THEN ConfigInt("MP", mp) END;
  Input.Configure("MTX", mt);
  ConfigInt("MB", mb)
 END
END Mouse;

PROCEDURE Watcher(me: Oberon.Task);
VAR keys: SET; x, y: INTEGER;
BEGIN
 IF watch # NIL THEN
  me.time := Input.Time() + WaitTime;
  IF watchshift THEN
   Input.KeyState(keys);
   IF keys * {Input.SHIFT} = {Input.SHIFT} THEN
    SelectMouse;
    Oberon.Remove(watch); watch := NIL
   END
  END;
  Input.Mouse(keys, x, y);
  IF (x = watchx) & (y = watchy) THEN (* mouse has not moved *)
   IF ~watchshift THEN
    Texts.WriteString(w, "Press Shift to configure mouse");
    Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf);
    watchshift := TRUE (* start watching the shift keys *)
   END
  ELSE
   IF watchshift THEN
    Texts.WriteString(w, "Mouse movement detected");
    Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf)
   END;
   Oberon.Remove(watch); watch := NIL
  END
 END
END Watcher;

PROCEDURE WatchMouse*; (** [seconds] *)
VAR keys: SET; s: Texts.Scanner;
BEGIN
 IF watch = NIL THEN
  Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
  IF s.class # Texts.Int THEN s.i := 5 END; (* default timeout in seconds *)
  Input.Mouse(keys, watchx, watchy);
  watchshift := FALSE;
  NEW(watch); watch.safe := FALSE;
  watch.time := Input.Time() + s.i * Input.TimeUnit;
  watch.handle := Watcher;
  Oberon.Install(watch)
 END
END WatchMouse;

BEGIN
 Texts.OpenWriter(w);
 maxport := CHR(ORD("0") + V24.NumberOfPorts());
 Kernel.GetConfig("PS2", mp);
 ps2 := mp # "0"; mouseIdent := NIL;
 watch := NIL
END ConfigInput.

System.Free Config ConfigInput ~

System.Directory Key*.Bin
ConfigInput.Keyboard ^
ConfigInput.Keyboard ""

ConfigInput.SelectMouse

ConfigInput.WatchMouse 5
