(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE VNCViewers; (** Jörg Kreienbühl    **)
(** VNC-Viewer for the AT&T (orig. Olivetti) VNC-Server from http://www.uk.research.att.com/vnc/
 Inherits from ImageGadget which displays an Images.Image as Model.
 The job of this viewer is to send the Input-Events. The Update is done by the VNCTask. *)

 IMPORT SYSTEM, Display, Input, Oberon, Objects, Gadgets, NetSystem, ImageGadgets, Images, VNCTask, Texts;
 
 TYPE
  Frame* = POINTER TO FrameDesc;
  FrameDesc = RECORD (ImageGadgets.FrameDesc)
   c: NetSystem.Connection;    (* ShortCut to task.c *)
   task: VNCTask.Task;       (* Task, that reads the updates *)
   focus: BOOLEAN;
   refCount: INTEGER;
  END;
  
 VAR
  LastTrack: Oberon.InputMsg;  (* Last mouse-data *)
  LastShift, OldShift: SET;    (* Last Shift-state sinc last request and last change *)
  AltLock: BOOLEAN;    (* The Alt-key remains active for the next key-event *)
  LastSelTime, LastKeyStamp: LONGINT; (* Last Selection and Last key-event (for avoiding multiple key messages *)
  MouseDot: Display.Pattern;
  DotMarker: Oberon.Marker;
  emptyImg: Images.Image;

 PROCEDURE ConnectionValid(f: Frame): BOOLEAN;
 BEGIN
  RETURN (f.c # NIL) & (NetSystem.State(f.c) = NetSystem.inout);
 END ConnectionValid;
 
 (* Oberon-> X-Keys/Char*)
 PROCEDURE TranslateKey(k: CHAR): LONGINT;
  VAR i: INTEGER;
 BEGIN
  i := 0;
  VNCTask.KeyTab[LEN(VNCTask.KeyTab)-1].o := k; VNCTask.KeyTab[LEN(VNCTask.KeyTab)-1].x := ORD(k); (* Sentinel *)
  WHILE VNCTask.KeyTab[i].o # k DO INC(i) END;
  RETURN VNCTask.KeyTab[i].x
 END TranslateKey;

 PROCEDURE CheckSelection(f: Frame);
  VAR 
   sel: Texts.Text;
   beg, end, time, i: LONGINT;
   r: Texts.Reader;
   buf: POINTER TO ARRAY OF CHAR;
 BEGIN
  Oberon.GetSelection(sel, beg, end, time);
  IF (time # -1) & (time - LastSelTime > 0) THEN
   Texts.OpenReader(r, sel, beg);
   NEW(buf, end-beg+1);
   FOR i := 0 TO end-beg-1 DO Texts.Read(r, buf[i]) END;
   buf[end-beg] := 0X;
   FOR i:= 0 TO end-beg-1 DO (* Newlines Codieren *)
    IF buf[i] = 0DX THEN buf[i] := 0AX ELSE buf[i] := CHR(TranslateKey(buf[i])) END
   END;
   
   NetSystem.Write(f.c, 06X);   (* 6 = Client Cut Text *)
   FOR i:= 0 TO 2 DO NetSystem.Write(f.c, 0X) END; (* Pad *)
   NetSystem.WriteLInt(f.c, end-beg);
   NetSystem.WriteBytes(f.c, 0, end-beg, buf^);
   LastSelTime := time
  END
 END CheckSelection;
  
 PROCEDURE SendKey(f: Frame; k: LONGINT; up: BOOLEAN);
 BEGIN
  IF NetSystem.Available(f.c) > 0 THEN f.task.handle(f.task) END;
  NetSystem.Write(f.c, 4X); (* Code 4 = Taste *)
  IF up THEN
   NetSystem.Write(f.c, 0X)
  ELSE
   NetSystem.Write(f.c, 1X)
  END;
  NetSystem.Write(f.c, 0X); NetSystem.Write(f.c, 0X); (* Pad *)
  NetSystem.WriteLInt(f.c, k);
  f.task.handle(f.task)
 END SendKey;
 
 PROCEDURE KeyEvent(f: Frame; k: CHAR);
 BEGIN
  IF AltLock THEN SendKey(f, 0FFE9H, FALSE) END;
  SendKey(f, TranslateKey(k), FALSE);
  SendKey(f, TranslateKey(k), TRUE);
  IF AltLock THEN SendKey(f, 0FFE9H, TRUE); AltLock := FALSE END
 END KeyEvent;
 
 PROCEDURE SetShifts(f: Frame; keys: SET);
 VAR 
  shiftCodes: ARRAY 3 OF LONGINT;
  i: INTEGER;
 BEGIN
  IF keys = LastShift THEN RETURN END;
  
  shiftCodes[0] := 0FFE1H;
  shiftCodes[1] := 0FFE3H;
  shiftCodes[2] := 0FFE9H;
  
  FOR i:=0 TO 2 DO (* alle releases *)
   IF i IN LastShift - keys THEN SendKey(f, shiftCodes[i], TRUE) END
  END;
  
  FOR i:=0 TO 2 DO (* alle presses *)
   IF i IN keys - LastShift THEN SendKey(f, shiftCodes[i], FALSE) END
  END;
  IF Input.ALT IN keys-LastShift THEN AltLock := ~AltLock END;
  
  IF keys # LastShift THEN OldShift := LastShift END;
  LastShift := keys
 END SetShifts;
 
 PROCEDURE ShiftEvents(f: Frame);
  VAR keys: SET;
 BEGIN
  Input.KeyState(keys);
  SetShifts(f, keys)
 END ShiftEvents;
 
 PROCEDURE Consume(f: Frame; msg: Oberon.ConsumeMsg);
  VAR 
   r: Texts.Reader;
   c: CHAR;
 BEGIN
  Texts.OpenReader(r, msg.text, msg.beg);
  WHILE Texts.Pos(r) # msg.end DO
   Texts.Read(r, c);
   SendKey(f, TranslateKey(c), FALSE);
   SendKey(f, TranslateKey(c), TRUE)
  END
 END Consume;
  
 PROCEDURE HandleFrame* (obj: Objects.Object; VAR msg: Objects.ObjMsg);
 VAR
  f: Frame;
  i: INTEGER;
  keys: SET;
 BEGIN
  f := obj(Frame);
  
  IF msg IS Oberon.InputMsg THEN
   IF ~ConnectionValid(f) THEN RETURN END;
   WITH msg: Oberon.InputMsg DO
    IF (msg.id = Oberon.track) & Gadgets.InActiveArea(f, msg) THEN
     IF ~f.focus & (msg.keys # {}) THEN Oberon.Defocus; f.focus := TRUE END;  (* Fokus with Click in the Window *)
     IF (1 IN msg.keys) & ~(Input.SHIFT IN LastShift) THEN CheckSelection(f) END;
     REPEAT
      ShiftEvents(f);
      Oberon.DrawCursor(Oberon.Mouse, DotMarker, msg.X, msg.Y);
      IF NetSystem.Available(f.c) > 0 THEN (* Always read first to avoid deadlock! *)
       f.task.handle(f.task)
      (* Oberon sends many Track-messages. This would block other viewers.
       -> filter redundant messages: *)
      ELSIF (msg.X # LastTrack.X) OR (msg.Y # LastTrack.Y) OR (msg.keys # LastTrack.keys) THEN
       VNCTask.FastRequests(f.task);
       
       LastTrack := msg;
       NetSystem.Write(f.c, 5X);         (* Code 5 = PointerMsg *)
       (* Keys umkehren, weil sie in Oberon anders rum sind *)
       keys := {};
       FOR i:=0 TO 2 DO IF i IN msg.keys THEN keys := keys + {2-i} END END;
       NetSystem.Write(f.c, SYSTEM.VAL(CHAR, keys));
       NetSystem.WriteInt(f.c, msg.X - f.X- msg.x);
       NetSystem.WriteInt(f.c, f.task.img.height - (msg.Y - f.Y - msg.y));
       f.task.handle(f.task)
      END;
      Input.Mouse(msg.keys, msg.X, msg.Y)
     UNTIL msg.keys = {};
     msg.res := 0
    ELSIF (msg.id = Oberon.consume) & f.focus & (msg.stamp # LastKeyStamp) THEN
     ShiftEvents(f);
     (* Hack: Because the Keyboard sends wrong shift-Events, when a Key belonging to the cursor-block is pressed,
      these events will be undone by setting the State of the Shift-Key to the State in OldShift to OldShift *)
     IF (0A0X <= msg.ch) & (msg.ch <= 0C4X) THEN 
      OldShift := (LastShift - {Input.SHIFT}) + (OldShift *  {Input.SHIFT});
      SetShifts(f, OldShift)
     END;
     
     LastKeyStamp := msg.stamp;
     VNCTask.FastRequests(f.task);
     IF (Input.CTRL IN LastShift) & (0X < msg.ch) & (msg.ch < 20X) THEN (* deacivate Control/Shift-coding *)
      msg.ch := CHR(ORD(msg.ch) + 60H)
     END;
     KeyEvent(f, msg.ch);
     ShiftEvents(f);
     OldShift := LastShift;
    END;
   END (* WITH InputMsg *)
  ELSIF msg IS Oberon.SelectMsg THEN
   WITH msg: Oberon.SelectMsg DO
    IF (msg.id = Oberon.get) THEN
     IF (f.task.selTime # -1) & (f.task.selTime - msg.time > 0) & (msg.time # 0) & (f.task.selection.len # 0) THEN
      VNCTask.FastRequests(f.task);
      msg.time := f.task.selTime; msg.sel := f;
      msg.text := f.task.selection; msg.beg := 0; msg.end := f.task.selection.len
     END
    ELSE Gadgets.framehandle(f, msg)
    END
   END
  ELSIF msg IS Oberon.ControlMsg THEN
   IF (msg(Oberon.ControlMsg).id = Oberon.defocus) OR (msg(Oberon.ControlMsg).id = Oberon.neutralize) THEN
    f.focus := FALSE; AltLock := FALSE;
    IF msg(Oberon.ControlMsg).id = Oberon.neutralize THEN
     f.task.selTime := -1
    END
   END
  ELSIF msg IS Oberon.ConsumeMsg THEN
   IF f.focus THEN Consume(f, msg(Oberon.ConsumeMsg)); VNCTask.FastRequests(f.task) END
  ELSIF msg IS Objects.AttrMsg THEN
   WITH msg: Objects.AttrMsg DO
    IF msg.id = Objects.get THEN
     IF msg.name = "Gen" THEN
      msg.class := Objects.String; msg.s := "VNCViewers.NewFrame"; msg.res := 0
     ELSIF msg.name = "Locked" THEN
      msg.class := Objects.Bool; msg.b := FALSE; msg.res := 0
     ELSE
      Gadgets.framehandle(f, msg)
     END
    ELSIF msg.id = Objects.set THEN
      Gadgets.framehandle(f, msg)
    ELSIF msg.id = Objects.enum THEN
     msg.Enum("Locked");
     Gadgets.framehandle(f, msg)
    END
   END (* WITH AttrMsg *)
  ELSE
   ImageGadgets.Handle(obj, msg);
  END; (* msgType-IF *)
 END HandleFrame;
 
 PROCEDURE SetTask*(f: Frame; t: VNCTask.Task); (** Sets the task for the frame *)
 BEGIN
  f.task := t;
  f.c := t.c;
 END SetTask;
 
 PROCEDURE CloseRef*(f: Frame);       (** Refconting for the frame. If Count = 0 then close the Task *)
 BEGIN
  DEC(f.refCount);
  IF f.refCount <=0 THEN VNCTask.UnInstall(f.task) END
 END CloseRef;
 
 PROCEDURE NewRef*(f: Frame);       (** One more reference *)
 BEGIN
  IF f.refCount > 0 THEN INC(f.refCount) END
 END NewRef;
 
 PROCEDURE InitFrame*(f: Frame; img: Images.Image);
 BEGIN
  ImageGadgets.Init(f, img);
  f.handle := HandleFrame; 
  f.task := NIL; f.c := NIL;
  f.focus := FALSE;
  f.refCount := 1
 END InitFrame;

 PROCEDURE NewFrame*;
  VAR frame: Frame;
 BEGIN
  NEW(frame); InitFrame(frame, emptyImg);
  Objects.NewObj := frame
 END NewFrame;
 
 PROCEDURE DrawDot(x, y: INTEGER);
 BEGIN
  Display.CopyPattern(Display.FG, MouseDot, x-1, y-3, Display.invert)
 END DrawDot;
 
 PROCEDURE InitPattern;
  VAR 
   p: ARRAY 4 OF SET;
 BEGIN
  p[0] := {1, 2};
  p[1] := {0, 1, 2, 3};
  p[2] := p[1]; p[3] := p[0];
  
  MouseDot := Display.NewPattern(4, 4, p);
  DotMarker.Fade := DrawDot;
  DotMarker.Draw := DrawDot
 END InitPattern;

BEGIN
 NEW(emptyImg);
 Images.Create(emptyImg, 10, 10, Images.BGR555);
 LastSelTime := 0;
 AltLock := FALSE;
 OldShift := {};
 InitPattern
END VNCViewers.
 

Gadgets.Insert VNCViewers.NewFrame
