(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon Usb keyboard support

Reference: http://www.usb.org

30.09.2000 cp first release
18.10.2000 cp fix size of interrupt endpoint and add warning message if keyboard fails
2026 me@rochus-keller.ch: replaced i386 inline assembly tables with plain arrays
*)

MODULE UsbKeyboard; (** portable **) 

IMPORT Usb, Kernel, SYSTEM, Files, Input;

CONST

 VersionString = "Usb Keyboarddriver 1.0";

TYPE

 Keyboard = POINTER TO RECORD
  Device : Usb.UsbDevice;
  InterfaceNum : INTEGER;
  IntReq, ControlReq : Usb.UsbTReq;
  Message : ARRAY 64 OF CHAR;
  Pressed : ARRAY 6 OF CHAR;
  DeadKey : SHORTINT;
  NumKeyVal : INTEGER;
  Flags : SET;
  next : Keyboard;
 END;

CONST

 ScrollLock = 0;  NumLock = 1;  CapsLock = 2;  LAlt = 3;  RAlt = 4;
 LCtrl = 5;  RCtrl = 6;  LShift = 7;  RShift = 8;  GreyEsc = 9;
 DeadKey = 0;

VAR

 KeyboardDriver : Usb.UsbDriver;
 KeyboardList : Keyboard;

 KeyboardFileTable : POINTER TO ARRAY OF CHAR;
 KeyboardTable : LONGINT;

 EscNeutralise : BOOLEAN;

 KeyboardBuffer : ARRAY 256 OF CHAR;
 KeyboardModBuffer : ARRAY 256 OF SET;
 KeyboardFirstEntry, KeyboardLastEntry : INTEGER;

 (* USB HID scancode to AT scancode translation table *)
 (* Replaces i386 inline assembly UsbScanTab procedure *)
 UsbScanTabData : ARRAY 256 OF CHAR;

 (* US keyboard translation table *)
 (* Replaces i386 inline assembly TableUS procedure *)
 TableUSData : ARRAY 1024 OF CHAR;
 TableUSLen : LONGINT;

(* Translation table format:  

 table = { scancode unshifted-code shifted-code flags }  0FFX .
 scancode = <scancode byte from keyboard, bit 7 set for "grey" extended keys>
 unshifted-code = <CHAR produced by this scancode, without shift>
 shifted-code = <CHAR produced by this scancode, with shift>
 flags = <bit-mapped flag byte indicating special behaviour>
 
 flag bit function
  0 01 DeadKey: Set dead key flag according to translated key code (1-7)
  1 02 NumLock: if set, the state of NumLock will reverse the action of shift (for num keypad)
  2 04 CapsLock: if set, the state of CapsLock will reverse the action of shift (for alpha keys)
  3 08 LAlt:  \ the state of these two flags in the table and the current state of the two...
  4 10 RAlt: / ...Alt keys must match exactly, otherwise the search is continued.
  5 20 \
  6 40  >  dead key number (0-7), must match current dead key flag
  7 80 /
 
 The table is scanned sequentially (speed not critical).  Ctrl-Break, Ctrl-F10 and Ctrl-Alt-Del
 are always defined and are not in the table.   The control keys are also always defined. *)

PROCEDURE InitUsbScanTab;
VAR i: LONGINT;
BEGIN
 FOR i := 0 TO 255 DO UsbScanTabData[i] := CHR(0) END;
 (* USB HID usage ID to AT set 1 scancode mapping *)
 (* Row 0: 00-0F *)
 UsbScanTabData[004H] := CHR(030); (* a *)
 UsbScanTabData[005H] := CHR(048); (* b *)
 UsbScanTabData[006H] := CHR(046); (* c *)
 UsbScanTabData[007H] := CHR(032); (* d *)
 UsbScanTabData[008H] := CHR(018); (* e *)
 UsbScanTabData[009H] := CHR(033); (* f *)
 UsbScanTabData[00AH] := CHR(034); (* g *)
 UsbScanTabData[00BH] := CHR(035); (* h *)
 UsbScanTabData[00CH] := CHR(023); (* i *)
 UsbScanTabData[00DH] := CHR(036); (* j *)
 UsbScanTabData[00EH] := CHR(037); (* k *)
 UsbScanTabData[00FH] := CHR(038); (* l *)
 (* Row 1: 10-1F *)
 UsbScanTabData[010H] := CHR(050); (* m *)
 UsbScanTabData[011H] := CHR(049); (* n *)
 UsbScanTabData[012H] := CHR(024); (* o *)
 UsbScanTabData[013H] := CHR(025); (* p *)
 UsbScanTabData[014H] := CHR(016); (* q *)
 UsbScanTabData[015H] := CHR(019); (* r *)
 UsbScanTabData[016H] := CHR(031); (* s *)
 UsbScanTabData[017H] := CHR(020); (* t *)
 UsbScanTabData[018H] := CHR(022); (* u *)
 UsbScanTabData[019H] := CHR(047); (* v *)
 UsbScanTabData[01AH] := CHR(017); (* w *)
 UsbScanTabData[01BH] := CHR(045); (* x *)
 UsbScanTabData[01CH] := CHR(021); (* y *)
 UsbScanTabData[01DH] := CHR(044); (* z *)
 UsbScanTabData[01EH] := CHR(002); (* 1 *)
 UsbScanTabData[01FH] := CHR(003); (* 2 *)
 (* Row 2: 20-2F *)
 UsbScanTabData[020H] := CHR(004); (* 3 *)
 UsbScanTabData[021H] := CHR(005); (* 4 *)
 UsbScanTabData[022H] := CHR(006); (* 5 *)
 UsbScanTabData[023H] := CHR(007); (* 6 *)
 UsbScanTabData[024H] := CHR(008); (* 7 *)
 UsbScanTabData[025H] := CHR(009); (* 8 *)
 UsbScanTabData[026H] := CHR(010); (* 9 *)
 UsbScanTabData[027H] := CHR(011); (* 0 *)
 UsbScanTabData[028H] := CHR(028); (* Enter *)
 UsbScanTabData[029H] := CHR(001); (* Esc *)
 UsbScanTabData[02AH] := CHR(014); (* Backspace *)
 UsbScanTabData[02BH] := CHR(015); (* Tab *)
 UsbScanTabData[02CH] := CHR(057); (* Space *)
 UsbScanTabData[02DH] := CHR(012); (* - *)
 UsbScanTabData[02EH] := CHR(013); (* = *)
 UsbScanTabData[02FH] := CHR(026); (* [ *)
 (* Row 3: 30-3F *)
 UsbScanTabData[030H] := CHR(027); (* ] *)
 UsbScanTabData[031H] := CHR(043); (* \ *)
 UsbScanTabData[032H] := CHR(043); (* non-US # *)
 UsbScanTabData[033H] := CHR(039); (* ; *)
 UsbScanTabData[034H] := CHR(040); (* ' *)
 UsbScanTabData[035H] := CHR(041); (* ` *)
 UsbScanTabData[036H] := CHR(051); (* , *)
 UsbScanTabData[037H] := CHR(052); (* . *)
 UsbScanTabData[038H] := CHR(053); (* / *)
 UsbScanTabData[039H] := CHR(058); (* CapsLock *)
 UsbScanTabData[03AH] := CHR(059); (* F1 *)
 UsbScanTabData[03BH] := CHR(060); (* F2 *)
 UsbScanTabData[03CH] := CHR(061); (* F3 *)
 UsbScanTabData[03DH] := CHR(062); (* F4 *)
 UsbScanTabData[03EH] := CHR(063); (* F5 *)
 UsbScanTabData[03FH] := CHR(064); (* F6 *)
 (* Row 4: 40-4F *)
 UsbScanTabData[040H] := CHR(065); (* F7 *)
 UsbScanTabData[041H] := CHR(066); (* F8 *)
 UsbScanTabData[042H] := CHR(067); (* F9 *)
 UsbScanTabData[043H] := CHR(068); (* F10 *)
 UsbScanTabData[044H] := CHR(087); (* F11 *)
 UsbScanTabData[045H] := CHR(088); (* F12 *)
 UsbScanTabData[046H] := CHR(099); (* PrintScreen *)
 UsbScanTabData[047H] := CHR(070); (* ScrollLock *)
 UsbScanTabData[048H] := CHR(119); (* Pause *)
 UsbScanTabData[049H] := CHR(210); (* Insert *)
 UsbScanTabData[04AH] := CHR(199); (* Home *)
 UsbScanTabData[04BH] := CHR(201); (* PageUp *)
 UsbScanTabData[04CH] := CHR(211); (* Delete *)
 UsbScanTabData[04DH] := CHR(207); (* End *)
 UsbScanTabData[04EH] := CHR(209); (* PageDown *)
 UsbScanTabData[04FH] := CHR(205); (* Right *)
 (* Row 5: 50-5F *)
 UsbScanTabData[050H] := CHR(203); (* Left *)
 UsbScanTabData[051H] := CHR(208); (* Down *)
 UsbScanTabData[052H] := CHR(200); (* Up *)
 UsbScanTabData[053H] := CHR(069); (* NumLock *)
 UsbScanTabData[054H] := CHR(181); (* KP / *)
 UsbScanTabData[055H] := CHR(055); (* KP * *)
 UsbScanTabData[056H] := CHR(074); (* KP - *)
 UsbScanTabData[057H] := CHR(078); (* KP + *)
 UsbScanTabData[058H] := CHR(156); (* KP Enter *)
 UsbScanTabData[059H] := CHR(079); (* KP 1 *)
 UsbScanTabData[05AH] := CHR(080); (* KP 2 *)
 UsbScanTabData[05BH] := CHR(081); (* KP 3 *)
 UsbScanTabData[05CH] := CHR(075); (* KP 4 *)
 UsbScanTabData[05DH] := CHR(076); (* KP 5 *)
 UsbScanTabData[05EH] := CHR(077); (* KP 6 *)
 UsbScanTabData[05FH] := CHR(071); (* KP 7 *)
 (* Row 6: 60-6F *)
 UsbScanTabData[060H] := CHR(072); (* KP 8 *)
 UsbScanTabData[061H] := CHR(073); (* KP 9 *)
 UsbScanTabData[062H] := CHR(082); (* KP 0 *)
 UsbScanTabData[063H] := CHR(083); (* KP . *)
 UsbScanTabData[064H] := CHR(086); (* non-US \ *)
 UsbScanTabData[065H] := CHR(127); (* App *)
 UsbScanTabData[066H] := CHR(116); (* Power *)
 UsbScanTabData[067H] := CHR(117); (* KP = *)
 UsbScanTabData[068H] := CHR(085); (* F13 *)
 UsbScanTabData[069H] := CHR(089); (* F14 *)
 UsbScanTabData[06AH] := CHR(090); (* F15 *)
 UsbScanTabData[06BH] := CHR(091); (* F16 *)
 UsbScanTabData[06CH] := CHR(092); (* F17 *)
 UsbScanTabData[06DH] := CHR(093); (* F18 *)
 UsbScanTabData[06EH] := CHR(094); (* F19 *)
 UsbScanTabData[06FH] := CHR(095); (* F20 *)
 (* Row 7: 70-7F *)
 UsbScanTabData[070H] := CHR(120); (* F21 *)
 UsbScanTabData[071H] := CHR(121); (* F22 *)
 UsbScanTabData[072H] := CHR(122); (* F23 *)
 UsbScanTabData[073H] := CHR(123); (* F24 *)
 UsbScanTabData[074H] := CHR(134); (* Execute *)
 UsbScanTabData[075H] := CHR(138); (* Help *)
 UsbScanTabData[076H] := CHR(130); (* Menu *)
 UsbScanTabData[077H] := CHR(132); (* Select *)
 UsbScanTabData[078H] := CHR(128); (* Stop *)
 UsbScanTabData[079H] := CHR(129); (* Again *)
 UsbScanTabData[07AH] := CHR(131); (* Undo *)
 UsbScanTabData[07BH] := CHR(137); (* Cut *)
 UsbScanTabData[07CH] := CHR(133); (* Copy *)
 UsbScanTabData[07DH] := CHR(135); (* Paste *)
 UsbScanTabData[07EH] := CHR(136); (* Find *)
 UsbScanTabData[07FH] := CHR(113); (* Mute *)
 (* Row 8-9: 80-9F (mostly 0, some at end) *)
 UsbScanTabData[080H] := CHR(115); (* VolumeUp *)
 UsbScanTabData[081H] := CHR(114); (* VolumeDown *)
 UsbScanTabData[087H] := CHR(124); (* International 1 (Ro) *)
 (* Row E: E0-EF modifier keys *)
 UsbScanTabData[0E0H] := CHR(029); (* LCtrl *)
 UsbScanTabData[0E1H] := CHR(042); (* LShift *)
 UsbScanTabData[0E2H] := CHR(056); (* LAlt *)
 UsbScanTabData[0E3H] := CHR(125); (* LGui *)
 UsbScanTabData[0E4H] := CHR(097); (* RCtrl *)
 UsbScanTabData[0E5H] := CHR(054); (* RShift *)
 UsbScanTabData[0E6H] := CHR(100); (* RAlt *)
 UsbScanTabData[0E7H] := CHR(126); (* RGui *)
 UsbScanTabData[0E8H] := CHR(164); (* Media Play/Pause *)
 UsbScanTabData[0E9H] := CHR(166); (* Media Stop/Eject *)
 UsbScanTabData[0EAH] := CHR(165); (* Media Prev *)
 UsbScanTabData[0EBH] := CHR(163); (* Media Next *)
 UsbScanTabData[0ECH] := CHR(161); (* Media Eject *)
 UsbScanTabData[0EDH] := CHR(115); (* Volume Up *)
 UsbScanTabData[0EEH] := CHR(114); (* Volume Down *)
 UsbScanTabData[0EFH] := CHR(113); (* Mute *)
 UsbScanTabData[0F0H] := CHR(150); (* WWW *)
 UsbScanTabData[0F1H] := CHR(158); (* Back *)
 UsbScanTabData[0F2H] := CHR(159); (* Forward *)
 UsbScanTabData[0F3H] := CHR(128); (* Stop *)
 UsbScanTabData[0F4H] := CHR(136); (* Find/Search *)
 UsbScanTabData[0F5H] := CHR(177); (* ScrollUp *)
 UsbScanTabData[0F6H] := CHR(178); (* ScrollDown *)
 UsbScanTabData[0F7H] := CHR(176); (* Edit *)
 UsbScanTabData[0F8H] := CHR(142); (* Sleep *)
 UsbScanTabData[0F9H] := CHR(152); (* Coffee/Lock *)
 UsbScanTabData[0FAH] := CHR(173); (* Refresh *)
 UsbScanTabData[0FBH] := CHR(140); (* Calc *)
END InitUsbScanTab;

PROCEDURE InitTableUS;
VAR i: LONGINT;

 PROCEDURE E(sc: LONGINT; unsh, sh: CHAR; fl: LONGINT);
 BEGIN
  IF i < 1020 THEN
   TableUSData[i] := CHR(sc); INC(i);
   TableUSData[i] := unsh; INC(i);
   TableUSData[i] := sh; INC(i);
   TableUSData[i] := CHR(fl); INC(i)
  END
 END E;

BEGIN
 i := 0;
 (* alphabet - CapsLock flag = 4 *)
 E(01EH, "a", "A", 4); E(030H, "b", "B", 4); E(02EH, "c", "C", 4); E(020H, "d", "D", 4);
 E(012H, "e", "E", 4); E(021H, "f", "F", 4); E(022H, "g", "G", 4); E(023H, "h", "H", 4);
 E(017H, "i", "I", 4); E(024H, "j", "J", 4); E(025H, "k", "K", 4); E(026H, "l", "L", 4);
 E(032H, "m", "M", 4); E(031H, "n", "N", 4); E(018H, "o", "O", 4); E(019H, "p", "P", 4);
 E(010H, "q", "Q", 4); E(013H, "r", "R", 4); E(01FH, "s", "S", 4); E(014H, "t", "T", 4);
 E(016H, "u", "U", 4); E(02FH, "v", "V", 4); E(011H, "w", "W", 4); E(02DH, "x", "X", 4);
 E(015H, "y", "Y", 4); E(02CH, "z", "Z", 4);
 (* numbers at top *)
 E(00BH, "0", ")", 0); E(002H, "1", "!", 0); E(003H, "2", "@", 0); E(004H, "3", "#", 0);
 E(005H, "4", "$", 0); E(006H, "5", "%", 0); E(007H, "6", "^", 0); E(008H, "7", "&", 0);
 E(009H, "8", "*", 0); E(00AH, "9", "(", 0);
 (* symbol keys *)
 E(028H, "'", 22X, 0); E(033H, ",", "<", 0); E(00CH, "-", "_", 0); E(034H, ".", ">", 0);
 E(035H, "/", "?", 0); E(027H, ";", ":", 0); E(00DH, "=", "+", 0); E(01AH, "[", "{", 0);
 E(02BH, "\", "|", 0); E(01BH, "]", "}", 0); E(029H, "`", "~", 0);
 (* control keys *)
 E(00EH, 7FX, 7FX, 0); (* backspace *)
 E(00FH, 09X, 09X, 0); (* tab *)
 E(01CH, 0DX, 0DX, 0); (* enter *)
 E(039H, 20X, 20X, 0); (* space *)
 E(001H, 0FEX, 1BX, 0); (* esc *)
 (* keypad *)
 E(04FH, 0A9X, "1", 2); (* end/1 *)
 E(050H, 0C2X, "2", 2); (* down/2 *)
 E(051H, 0A3X, "3", 2); (* pgdn/3 *)
 E(04BH, 0C4X, "4", 2); (* left/4 *)
 E(04CH, 0FFX, "5", 2); (* center/5 *)
 E(04DH, 0C3X, "6", 2); (* right/6 *)
 E(047H, 0A8X, "7", 2); (* home/7 *)
 E(048H, 0C1X, "8", 2); (* up/8 *)
 E(049H, 0A2X, "9", 2); (* pgup/9 *)
 E(052H, 0A0X, "0", 2); (* insert/0 *)
 E(053H, 0A1X, 2EX, 2); (* del/. *)
 (* gray keys *)
 E(04AH, "-", "-", 0); (* gray - *)
 E(04EH, "+", "+", 0); (* gray + *)
 E(0B5H, "/", "/", 0); (* gray / *)
 E(037H, "*", "*", 0); (* gray * *)
 E(0D0H, 0C2X, 0C2X, 0); (* gray down *)
 E(0CBH, 0C4X, 0C4X, 0); (* gray left *)
 E(0CDH, 0C3X, 0C3X, 0); (* gray right *)
 E(0C8H, 0C1X, 0C1X, 0); (* gray up *)
 E(09CH, 0DX, 0DX, 0); (* gray enter *)
 E(0D2H, 0A0X, 0A0X, 0); (* gray ins *)
 E(0D3H, 0A1X, 0A1X, 0); (* gray del *)
 E(0C9H, 0A2X, 0A2X, 0); (* gray pgup *)
 E(0D1H, 0A3X, 0A3X, 0); (* gray pgdn *)
 E(0C7H, 0A8X, 0A8X, 0); (* gray home *)
 E(0CFH, 0A9X, 0A9X, 0); (* gray end *)
 (* function keys *)
 E(03BH, 0A4X, 0FFX, 0); (* F1 *)
 E(03CH, 0A5X, 0FFX, 0); (* F2 *)
 E(03DH, 1BX, 0FFX, 0); (* F3 *)
 E(03EH, 0A7X, 0FFX, 0); (* F4 *)
 E(03FH, 0F5X, 0FFX, 0); (* F5 *)
 E(040H, 0F6X, 0FFX, 0); (* F6 *)
 E(041H, 0F7X, 0FFX, 0); (* F7 *)
 E(042H, 0F8X, 0FFX, 0); (* F8 *)
 E(043H, 0F9X, 0FFX, 0); (* F9 *)
 E(044H, 0FAX, 0FFX, 0); (* F10 *)
 E(057H, 0FBX, 0FFX, 0); (* F11 *)
 E(058H, 0FCX, 0FFX, 0); (* F12 *)
 (* terminator *)
 TableUSData[i] := 0FFX;
 TableUSLen := i
END InitTableUS;

PROCEDURE TableUS(): LONGINT;
BEGIN
 RETURN SYSTEM.ADR(TableUSData[0])
END TableUS;

PROCEDURE UsbScanTab(): LONGINT;
BEGIN
 RETURN SYSTEM.ADR(UsbScanTabData[0])
END UsbScanTab;

PROCEDURE LoadKeyboardTable():LONGINT;
VAR f: Files.File;  r: Files.Rider;  len: LONGINT; i : INTEGER; k : ARRAY 32 OF CHAR;
BEGIN

 Kernel.GetConfig("EscCompat", k);
 EscNeutralise := (k # "0");

 Kernel.GetConfig("Keyboard", k);
 i := 0;  WHILE (k[i] # 0X) & (k[i] # ".") DO INC(i) END;

 IF k[i] = "." THEN
  Kernel.WriteString("UsbKeyboard: Using table ");  Kernel.WriteString(k);
  f := Files.Old(k);
  IF f # NIL THEN
   len := Files.Length(f);
   IF len MOD 4 = 0 THEN
    NEW(KeyboardFileTable, len+1);
    Files.Set(r, f, 0);  Files.ReadBytes(r, KeyboardFileTable^, len);
    IF r.res = 0 THEN
     Kernel.WriteLn;
     KeyboardFileTable[len] := 0FFX;
     RETURN SYSTEM.ADR(KeyboardFileTable[0]);
    END
   END
  END;
  Kernel.WriteString(" (error, using default)");  Kernel.WriteLn;
 END;

 RETURN TableUS();

END LoadKeyboardTable;

(* Translate - Translate scan code "c" to key. *)

PROCEDURE Translate(flags: SET;  c: CHAR; VAR KeyboardDeadKey : SHORTINT; VAR KeyboardKeyVal : INTEGER): INTEGER;
CONST
 Alt = {LAlt, RAlt};  Ctrl = {LCtrl, RCtrl};  Shift = {LShift, RShift};
VAR a: LONGINT;  s1: CHAR;  s: SET;  k: INTEGER;  dkn: SHORTINT;
BEGIN
 IF (c = 46X) & (flags * Ctrl # {}) THEN RETURN -2 END; (* Ctrl-Break - break *)
 IF (c = 44X) & (flags * Ctrl # {}) THEN RETURN 0FFH END; (* Ctrl-F10 - exit *)
 IF (c = 53X) & (flags * Ctrl # {}) & (flags * Alt # {}) THEN RETURN 0FFH END; (* Ctrl-Alt-Del - exit *)
 IF GreyEsc IN flags THEN c := CHR(ORD(c)+80H) END;
 a := KeyboardTable;
 LOOP
  SYSTEM.GET(a, s1);
  IF s1 = 0FFX THEN (* end of table, unmapped key *)
   k := -1;  KeyboardDeadKey := 0;  EXIT
  ELSIF s1 = c THEN (* found scan code in table *)
   SYSTEM.GET(a+3, SYSTEM.VAL(CHAR, s)); (* flags from table *)
   dkn := SHORT(SHORT(SYSTEM.VAL(LONGINT, SYSTEM.LSH(s * {5..7}, -5))));
   s := s * {DeadKey, NumLock, CapsLock, LAlt, RAlt, LCtrl, RCtrl};  k := 0;
   IF ((s * Alt = flags * Alt) OR (NumLock IN s)) & (dkn = KeyboardDeadKey) THEN (* Alt & dead keys match exactly *)
    IF flags * Shift # {} THEN INCL(s, LShift) END; (* check if shift pressed *)
     (* handle CapsLock *)
    IF (CapsLock IN s) & (CapsLock IN flags) THEN s := s / {LShift} END;
     (* handle NumLock *)
    IF NumLock IN s THEN
     IF flags * Alt # {} THEN INCL(s, LShift)
     ELSIF NumLock IN flags THEN s := s / {LShift}
     END
    END;
     (* get key code *)
    IF LShift IN s THEN SYSTEM.GET(a+2, SYSTEM.VAL(CHAR, k)) (* shifted value *)
    ELSE SYSTEM.GET(a+1, SYSTEM.VAL(CHAR, k)) (* unshifted value *)
    END;
    IF (DeadKey IN s) & (k <= 7) THEN (* dead key *)
     KeyboardDeadKey := SHORT(k);  k := -1 (* set new dead key state *)
    ELSIF k = 0FFH THEN (* unmapped key *)
     k := -1;  KeyboardDeadKey := 0 (* reset dead key state *)
    ELSE (* mapped key *)
     IF flags * Ctrl # {} THEN
      IF ((k >= 64) & (k <= 95)) OR ((k >= 97) & (k <= 122)) THEN
       k := SHORT(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, k) * {0..4})) (* control *)
      ELSIF k = 13 THEN (* Ctrl-Enter *)
       k := 10
      END
     END;
     IF flags * Alt # {} THEN (* Alt-keypad *)
      IF (k >= ORD("0")) & (k <= ORD("9")) & (NumLock IN s) THEN (* keypad num *)
       IF KeyboardKeyVal = -1 THEN KeyboardKeyVal := k-ORD("0")
       ELSE KeyboardKeyVal := (10*KeyboardKeyVal + (k-ORD("0"))) MOD 1000;
       END;
       k := -1
      END
     END;
     KeyboardDeadKey := 0 (* reset dead key state *)
    END;
    EXIT
   END
  END;
  INC(a, 4)
 END; (* LOOP *)
 RETURN k
END Translate;

PROCEDURE KeyboardInputPoller (VAR ch: CHAR; VAR keys: SET): BOOLEAN;
VAR
 ActionFlag : BOOLEAN;
 act : Keyboard;
 c : CHAR;
 i, j, k : INTEGER;
 oldflags : SET;
 LEDBuffer : ARRAY 1 OF CHAR;
 IgnoreResult : BOOLEAN;
BEGIN

 keys := {}; act := KeyboardList;

 IF act = NIL THEN RETURN FALSE END; (* save some time *)
 
 WHILE act # NIL DO
  IF act.IntReq # NIL THEN
   Usb.OpProbeTrans(act.IntReq); (* poll it *)
   IF (act.IntReq.Status * Usb.ResInProgress) = {} THEN
     IF ((act.IntReq.Status * (Usb.ResOK+ Usb.ResShortPacket)) # {}) & (act.IntReq.BufferLen >= 8) THEN
     
      oldflags := act.Flags;
      act.Flags := act.Flags * {NumLock, CapsLock};

      c := act.Message[0];
      IF (SYSTEM.VAL(SET, c) * {0}) # {} THEN INCL(act.Flags, LCtrl) END;
      IF (SYSTEM.VAL(SET, c) * {1}) # {} THEN INCL(act.Flags, LShift) END;
      IF (SYSTEM.VAL(SET, c) * {2}) # {} THEN INCL(act.Flags, LAlt) END;
      (* IF (SYSTEM.VAL(SET, c) * {3}) # {} THEN INCL(act.Flags, X) END; (* LGUI *) ??? *)
      IF (SYSTEM.VAL(SET, c) * {4}) # {} THEN INCL(act.Flags, RCtrl) END;
      IF (SYSTEM.VAL(SET, c) * {5}) # {} THEN INCL(act.Flags, RShift) END;
      IF (SYSTEM.VAL(SET, c) * {6}) # {} THEN INCL(act.Flags, RAlt) END;
      (* IF (SYSTEM.VAL(SET, c) * {7}) # {} THEN INCL(act.Flags, 5) END; (* RGUI *) ??? *)

      ActionFlag := FALSE;
      FOR i := 2 TO 7 DO
       c := act.Message[i];
       SYSTEM.GET(UsbScanTab() + ORD(c), c);
       IF (c = CHR(58)) OR (c = CHR(69)) THEN
        FOR j:= 0 TO 5 DO IF act.Pressed[j] = c THEN c := CHR(0) END END;
        IF c = CHR(58) THEN act.Flags := act.Flags /  {CapsLock}; ActionFlag := TRUE;
        ELSIF c = CHR(69) THEN act.Flags := act.Flags /  {NumLock}; ActionFlag := TRUE; END;
       END;
      END;
      IF ActionFlag THEN
       LEDBuffer[0] := CHR(0);
       IF CapsLock IN act.Flags THEN LEDBuffer[0] := CHR(ORD(LEDBuffer[0]) + 2) END;
       IF NumLock IN act.Flags THEN LEDBuffer[0] := CHR(ORD(LEDBuffer[0]) + 1) END;
       IgnoreResult := Usb.SetReport(act.ControlReq, act.Device, act.InterfaceNum,
        Usb.ReportTypeOutput, 0, LEDBuffer, 0, 1);
      END;

      IF  ( {LAlt, RAlt} * oldflags # {} ) & ( {LAlt, RAlt} * act.Flags = {} )
       & (act.NumKeyVal > 0) & (act.NumKeyVal < 255) THEN
       IF ((KeyboardLastEntry + 1) MOD 256) # KeyboardFirstEntry THEN
        KeyboardModBuffer[KeyboardLastEntry] := act.Flags;
        KeyboardBuffer[KeyboardLastEntry] := CHR(act.NumKeyVal);
        KeyboardLastEntry := (KeyboardLastEntry + 1) MOD 256;
       END;
       act.NumKeyVal := -1;
      END;

      FOR i := 2 TO 7 DO
       c := act.Message[i];
       IF (ORD(c) > 1) THEN
        FOR j:= 0 TO 5 DO IF act.Pressed[j] = c THEN c := CHR(0) END END;
        IF c # CHR(0) THEN
         SYSTEM.GET(UsbScanTab() + ORD(c), c);
          IF (c # CHR(58)) & (c # CHR(69)) THEN
          k := Translate(act.Flags, c, act.DeadKey, act.NumKeyVal);
          IF k = 0FEH THEN (* map Esc to Neutralise or Esc *)
           IF EscNeutralise THEN k := 0A5H ELSE k := 1BH END
          END;
          IF k > 0 THEN
           IF ((KeyboardLastEntry + 1) MOD 256) # KeyboardFirstEntry THEN
            KeyboardModBuffer[KeyboardLastEntry] := act.Flags;
            KeyboardBuffer[KeyboardLastEntry] := CHR(k);
            KeyboardLastEntry := (KeyboardLastEntry + 1) MOD 256;
           END;
          END;
         END;
        END;
       END;
      END;

      FOR i := 0 TO 5 DO act.Pressed[i] := act.Message[i+2]; END;

      keys := keys + act.Flags; (* if no yes was pressed, then return sum of all modifier keys of all keyboards... *)

      Usb.OpRestartInterrupt(act.IntReq);

     ELSE
      Kernel.WriteString("Usb Keyboard error. Disabling polling for this keyboard."); Kernel.WriteLn;
      Usb.OpDeleteTrans(act.IntReq); act.IntReq := NIL;
     END;
   END;
  END;
  act := act.next;
 END;

 IF KeyboardFirstEntry # KeyboardLastEntry THEN
  ch := KeyboardBuffer[KeyboardFirstEntry];
  keys := KeyboardModBuffer[KeyboardFirstEntry];
  KeyboardFirstEntry := (KeyboardFirstEntry + 1) MOD 256;
  RETURN TRUE;
 END;

 RETURN FALSE;

END KeyboardInputPoller;

PROCEDURE KeyboardProbe(dev : Usb.UsbDevice; intfc : INTEGER);
VAR
 if : Usb.UsbDeviceInterface;
 k : Keyboard;
 i : INTEGER;
BEGIN
 
 if := dev.ActConfiguration.Interfaces[intfc];

 IF if.bInterfaceClass # 3 THEN RETURN END;
 IF if.bInterfaceSubClass # 1 THEN RETURN END;
 IF if.bInterfaceProtocol # 1 THEN RETURN END;
 IF if.bNumEndpoints # 1 THEN RETURN END;

 Kernel.WriteString("Usb Keyboard found."); Kernel.WriteLn;

 if.Driver := KeyboardDriver;

 NEW(k);
 NEW(k.IntReq);
 NEW(k.ControlReq);

 k.Device := dev;
 k.InterfaceNum := intfc;
 k.next := KeyboardList;
 FOR i:= 0 TO 5 DO k.Pressed[i] := CHR(0) END;
 k.DeadKey := 0;
 k.NumKeyVal := -1;
 k.Flags := {};

 IF Usb.SetProtocol(k.ControlReq, dev, intfc, 0) = FALSE THEN
  if.Driver := NIL;
  Kernel.WriteString("Error. Cannot set keyboard into boot protocol mode."); Kernel.WriteLn;
  RETURN;
 END;

 IF Usb.SetIdle(k.ControlReq, dev, intfc) = FALSE THEN
  if.Driver := NIL;
  Kernel.WriteString("Error. Cannot set idle the keyboard."); Kernel.WriteLn;
  RETURN;
 END;

 (* Start the interrupt transaction *)

 k.IntReq.Device := dev;
 k.IntReq.Endpoint := SHORT(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, if.Endpoints[0].bEndpointAddress) * {0,1,2,3,7}));
 k.IntReq.Typ := Usb.TransferInterrupt;
 k.IntReq.Buffer := SYSTEM.ADR(k.Message[0]);
 k.IntReq.BufferLen := dev.MaxPacketSizeIn[k.IntReq.Endpoint MOD 16];
 k.IntReq.Timeout := 0;
 k.IntReq.IRQInterval := if.Endpoints[0].bInterval;
 Usb.OpTransReq(k.IntReq);

 (* Add this keyboard to the polling list *)

 KeyboardList := k;
 
END KeyboardProbe;

PROCEDURE KeyboardDisconnect(dev : Usb.UsbDevice);
VAR
 tmp, last : Keyboard;
BEGIN

 Kernel.WriteString("Usb Keyboard disconnecting."); Kernel.WriteLn;

 tmp := KeyboardList; last := NIL;

 WHILE tmp # NIL DO
  IF tmp.Device = dev THEN
   IF tmp.IntReq # NIL THEN Usb.OpDeleteTrans(tmp.IntReq); END;
   IF last = NIL THEN KeyboardList := tmp.next; ELSE last.next := tmp.next; END;
   tmp := tmp.next;
  ELSE
   last := tmp; tmp := tmp.next;
  END;
 END;
 
END KeyboardDisconnect;

PROCEDURE Init*();
BEGIN
 (* dummy *)
END Init;

PROCEDURE Cleanup();
VAR
 act : Keyboard;
BEGIN
 act := KeyboardList;
 WHILE act # NIL DO
  IF act.IntReq # NIL THEN Usb.OpDeleteTrans(act.IntReq); act.IntReq := NIL END;
  act := act.next;
 END;
 Input.RemoveKeyboard(KeyboardInputPoller);
 Usb.RemoveDriver(KeyboardDriver);
END Cleanup;

BEGIN

 KeyboardList := NIL;

 KeyboardFirstEntry := 0;
 KeyboardLastEntry := 0;

 InitUsbScanTab;
 InitTableUS;

 KeyboardTable := LoadKeyboardTable();

 NEW(KeyboardDriver);
 KeyboardDriver.DriverName := VersionString;
 KeyboardDriver.OpProbe := KeyboardProbe;
 KeyboardDriver.OpDisconnect := KeyboardDisconnect;
 Usb.RegisterDriver(KeyboardDriver);

 Input.AddKeyboard(KeyboardInputPoller);

 Kernel.InstallTermHandler(Cleanup);

END UsbKeyboard.

(** Init: UsbKeyboard.Init **)

(*
to do:
o make keyboard table configurable
*)
