(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Input; (* portable *) (* pjm / me@rochus-keller.ch *)

(*
Module Input is responsible for event timing, mouse and keyboard input.
Reduced for ARM: all i386 PS/2 and serial mouse/keyboard hardware drivers removed.
USB (or other) drivers register themselves via AddMouse/AddKeyboard.
*)

IMPORT
 Kernel, SYSTEM;

CONST
 TimeUnit* = 1000; (* portable, but VAR on other ports *) (* timer ticks per second (platform dependent). *)

 SHIFT* = 0;  CTRL* = 1;  ALT* = 2; (* for KeyState *)

 BufSize = 32; (* keyboard buffer size *)

TYPE
 PollMouse* = PROCEDURE (VAR keys: SET; VAR dx, dy, dz: INTEGER): BOOLEAN; (* non-portable *)
 PollKeyboard* = PROCEDURE (VAR ch: CHAR; VAR keys: SET): BOOLEAN; (* non-portable *)

 MousePoller = POINTER TO RECORD
  poll: PollMouse;
  next: MousePoller
 END;

 KeyboardPoller = POINTER TO RECORD
  poll: PollKeyboard;
  next: KeyboardPoller
 END;

VAR
  (* mouse state *)
 mouse: MousePoller;
 minX, minY, maxX, maxY, mouseX, mouseY, height: LONGINT;
 lastkeys: SET;
 buttons: SHORTINT;
 mapkeys: ARRAY 8 OF SET;
 threshold: INTEGER;
 speedup: LONGINT;

  (* keyboard state *)
 keyboard: KeyboardPoller;
 buffer: ARRAY 1+BufSize OF CHAR; (* first byte not used (System.State security) *)
 head, tail: SHORTINT;
 flags, pollkeys: SET;
 breakproc: Kernel.Proc;


(* DisableInterrupts - Disable IRQs and return original CPSR *)

(*
PROCEDURE -DisableInterrupts(): SET;
CODE {SYSTEM.arm}
 DCW 00000H, 0E10FH  (* MRS R0, CPSR *)
 DCW 00080H, 0F10CH  (* CPSID i *)
END DisableInterrupts;*)

(* RestoreInterrupts - Restore CPSR to previous state *)

(*
PROCEDURE -RestoreInterrupts(state: SET);
CODE {SYSTEM.arm}
 LDR R0, [SP, #0]
 DCW 0F000H, 0E121H  (* MSR CPSR_c, R0 *)
END RestoreInterrupts;*)


(* Returns the number of keystrokes in the keyboard input buffer. *)
PROCEDURE Available*() : INTEGER;
VAR state, keys: SET; p: KeyboardPoller; x: INTEGER; ch: CHAR; i: SHORTINT;
BEGIN
  (* poll all registered keyboards *)
 p := keyboard; pollkeys := {};
 WHILE p # NIL DO
  IF p.poll(ch, keys) THEN
   (*state := DisableInterrupts();*)
   SYSTEM.CLI();
   i := (tail+1) MOD BufSize;
   IF i # head THEN
    buffer[1+tail] := ch;  tail := i;
   END;
   (*RestoreInterrupts(state)*)
   SYSTEM.STI();
  END;
  pollkeys := pollkeys + keys;
  p := p.next
 END;
  (* check buffer *)
 (*state := DisableInterrupts();*)
 SYSTEM.CLI();
 x := (tail-head) MOD BufSize;
 (* RestoreInterrupts(state); *)
 SYSTEM.STI();
 RETURN x
END Available;

(* Reads the current mouse position x, y and the key state of the mouse buttons
(also called keys). The mouse buttons are numbered from the right to the left as
0, 1, 2 (i.e. 1 is the middle mouse button). For example, when the left and middle
buttons are pressed, keys will be set to {1, 2}. *)
PROCEDURE Mouse*(VAR keys: SET; VAR x, y: INTEGER);
VAR dx, dy, dz: INTEGER;  ok: BOOLEAN;  mousekeys, rawkeys: SET; p: MousePoller;
BEGIN
 IF Kernel.break THEN Kernel.break := FALSE; SYSTEM.HALT(13) END;
 REPEAT (* get all available mouse events, or until keys change *)
  p := mouse; rawkeys := {}; ok := FALSE;
  WHILE p # NIL DO (* poll all mice and sum keys and movements *)
   IF p.poll(mousekeys, dx, dy, dz) THEN
    ok := TRUE;
    rawkeys := rawkeys + mousekeys;
    IF (ABS(dx) > threshold) OR (ABS(dy) > threshold) THEN
     dx := SHORT(dx*speedup DIV 10); dy := SHORT(dy*speedup DIV 10)
    END;
    INC(mouseX, LONG(dx));  INC(mouseY, LONG(dy))
   END;
   p := p.next
  END
 UNTIL ~ok OR (rawkeys # lastkeys);
 IF ok THEN
  IF ~(1 IN lastkeys) & (1 IN rawkeys) THEN (* mouse generated middle button *)
   IF buttons = -3 THEN buttons := 3 END (* switch off emulation *)
  END;
  lastkeys := rawkeys (* save last known mouse key state *)
 ELSE
  rawkeys := lastkeys (* restore last known mouse key state *)
 END;
  (* middle button emulation *)
 IF buttons # 3 THEN (* -2, 2, -3 *)
  IF buttons = 2 THEN (* 2 => Ctrl is middle button *)
   IF flags * {CTRL} # {} THEN INCL(rawkeys, 1)
   ELSE EXCL(rawkeys, 1)
   END
  ELSE (* -2 OR -3 => MM or Ctrl is middle button *)
   IF flags * {CTRL} # {} THEN INCL(rawkeys, 1) END
  END
 END;
  (* key mapping *)
 keys := mapkeys[SYSTEM.VAL(LONGINT, rawkeys * {0,1,2})];
 IF mouseX < minX THEN mouseX := minX
 ELSIF mouseX > maxX THEN mouseX := maxX
 END;
 IF mouseY < minY THEN mouseY := minY
 ELSIF mouseY > maxY THEN mouseY := maxY
 END;
 x := SHORT(mouseX); y := SHORT(height-1-mouseY)
END Mouse;

(* Read a character from the keyboard buffer. Blocks if no character is available. *)
PROCEDURE Read*(VAR ch: CHAR);
VAR state: SET;
BEGIN
 REPEAT (* skip *) UNTIL (Available() # 0) OR Kernel.break;
 IF Kernel.break THEN Kernel.break := FALSE; SYSTEM.HALT(13) END;
 (* state := DisableInterrupts(); *)
 SYSTEM.CLI();
 ch := buffer[1+head];  head := (head+1) MOD BufSize;
 (*RestoreInterrupts(state);*)
 SYSTEM.STI();
 (* --- Test (To be removed) --- 
 Kernel.WriteString("Input: Read ["); 
 Kernel.WriteChar(ch); 
 Kernel.WriteString("]"); Kernel.WriteLn;
  ----------------------- *)
END Read;

(* Returns the elapsed number of timer ticks from Oberon startup. *)
PROCEDURE Time*(): LONGINT;
BEGIN
 IF Kernel.break THEN Kernel.break := FALSE; SYSTEM.HALT(13) END;
 RETURN Kernel.GetTimer()
END  Time;

(* Return the state of the shift keys. *)
PROCEDURE KeyState*(VAR keys: SET);
BEGIN
 keys := pollkeys
END KeyState;

(* Restricts the extent of the mouse coordinates returned by Mouse. *)
PROCEDURE SetMouseLimits*(x, y, w, h: INTEGER); (* non-portable *)
BEGIN
 IF height = 0 THEN height := h END;
 y := SHORT(height-1) - y;
 minX := x;  maxY := y;  maxX := x + w-1;  minY := y - (h-1);
 mouseX := minX + (maxX-minX) DIV 2;
 mouseY := minY + (maxY-minY) DIV 2
END SetMouseLimits;

(* Add a mouse driver.  The poll procedure will be called from Mouse and should 
  return the next mouse event, including the current key state.  It returns TRUE 
  iff a mouse event is available. *)
PROCEDURE AddMouse*(poll: PollMouse); (* non-portable *)
VAR n: MousePoller;
BEGIN
 NEW(n); n.poll := poll; n.next := mouse; mouse := n
END AddMouse;

(* Remove a mouse driver. *)
PROCEDURE RemoveMouse*(poll: PollMouse); (* non-portable *)
VAR p, n: MousePoller;
BEGIN
 p := NIL; n := mouse;
 WHILE (n # NIL) & (n.poll # poll) DO p := n; n := n.next END;
 IF n # NIL THEN
  IF p = NIL THEN mouse := n.next
  ELSE p.next := n.next
  END
 END
END RemoveMouse;

(* Add a keyboard driver.  The poll procedure will be called from Available and Read and 
  should return the next ASCII character.  It returns TRUE iff a key is available.  The 
  current shift state (SHIFT, CTRL, ALT) should always be returned, and will be added to KeyState. *)
PROCEDURE AddKeyboard*(poll: PollKeyboard); (* non-portable *)
VAR n: KeyboardPoller;
BEGIN
 NEW(n); n.poll := poll; n.next := keyboard; keyboard := n
END AddKeyboard;

(* Remove a keyboard driver. *)
PROCEDURE RemoveKeyboard*(poll: PollKeyboard); (* non-portable *)
VAR p, n: KeyboardPoller;
BEGIN
 p := NIL; n := keyboard;
 WHILE (n # NIL) & (n.poll # poll) DO p := n; n := n.next END;
 IF n # NIL THEN
  IF p = NIL THEN keyboard := n.next
  ELSE p.next := n.next
  END
 END
END RemoveKeyboard;

(* Configure input device parameters.  Normally only used by installation program. *)
PROCEDURE Configure*(config, value: ARRAY OF CHAR); (* non-portable *)
VAR mk: ARRAY 3 OF LONGINT;  i: SHORTINT;
BEGIN
 IF config = "MB" THEN (* mouse buttons *)
  IF value = "2" THEN buttons := 2
  ELSIF value = "3" THEN buttons := 3
  ELSIF value = "-2" THEN buttons := -2
  ELSE buttons := -3 (* default MM and Ctrl *)
  END
 ELSIF config = "MM" THEN (* mouse key remapping *)
  mk[0] := 0;  mk[1] := 1;  mk[2] := 2;
  IF value[0] # 0X THEN
   mk[0] := ORD(value[0])-48;
   IF value[1] # 0X THEN
    mk[1] := ORD(value[1])-48;
    IF value[2] # 0X THEN
     mk[2] := ORD(value[2])-48
    END
   END
  END;
  FOR i := 0 TO 7 DO
   mapkeys[i] := {};
   IF 0 IN SYSTEM.VAL(SET, i) THEN INCL(mapkeys[i], mk[0]) END;
   IF 1 IN SYSTEM.VAL(SET, i) THEN INCL(mapkeys[i], mk[1]) END;
   IF 2 IN SYSTEM.VAL(SET, i) THEN INCL(mapkeys[i], mk[2]) END
  END
 ELSE
  (* unknown setting, ignore *)
 END
END Configure;

PROCEDURE Setting(name: ARRAY OF CHAR);
VAR s: ARRAY 32 OF CHAR;
BEGIN
 Kernel.GetConfig(name, s);  Configure(name, s)
END Setting;

PROCEDURE *UnsafeBreak;
BEGIN
 SYSTEM.HALT(13)
END UnsafeBreak;

BEGIN
 mouse := NIL; keyboard := NIL; pollkeys := {};
 head := 0;  tail := 0;  buffer[0] := 0X;
 flags := {};  lastkeys := {};
 maxX := 0; height := 0;
 breakproc := UnsafeBreak;
  (* default mouse config *)
 threshold := 5;  speedup := 15;  buttons := -3;
 Setting("MB");  Setting("MM")
END Input.

