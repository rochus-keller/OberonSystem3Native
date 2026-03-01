(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon Usb keyboard support

Reference: http://www.usb.org

30.09.2000 cp first release
18.10.2000 cp fix size of interrupt endpoint and add warning message if keyboard fails
*)

MODULE UsbKeyboard; (** non-portable **) (** cp **)

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

(* TableUS - US keyboard translation table (dead keys: ^=1, '=2, `=3, ~=4, "=5) *)

PROCEDURE TableUS(): LONGINT;
CODE {SYSTEM.i386}
 CALL L1
L1:
 POP EAX
 ADD EAX,8
 POP EBP
 RET
  (* alphabet *)
 DB 1EX, "a", "A", 4X, 30X, "b", "B", 4X, 2EX, "c", "C", 4X, 20X, "d", "D", 4X
 DB 12X, "e", "E", 4X, 21X, "f", "F", 4X, 22X, "g", "G", 4X, 23X, "h", "H", 4X
 DB 17X, "i", "I", 4X, 24X, "j", "J", 4X, 25X, "k", "K", 4X, 26X, "l", "L", 4X
 DB 32X, "m", "M", 4X, 31X, "n", "N", 4X, 18X, "o", "O", 4X, 19X, "p", "P", 4X
 DB 10X, "q", "Q", 4X, 13X, "r", "R", 4X, 1FX, "s", "S", 4X, 14X, "t", "T", 4X
 DB 16X, "u", "U", 4X, 2FX, "v", "V", 4X, 11X, "w", "W", 4X, 2DX, "x", "X", 4X
 DB 15X, "y", "Y", 4X, 2CX, "z", "Z", 4X
  (* Oberon accents (LAlt & RAlt) *)
 DB 1EX, "ä", "Ä", 0CX, 12X, "ë", 0FFX, 0CX, 18X, "ö", "Ö", 0CX, 16X, "ü", "Ü", 0CX
 DB 17X, "ï", 0FFX, 0CX, 1FX, "ß", 0FFX, 0CX, 2EX, "ç", 0FFX, 0CX, 31X, "ñ", 0FFX, 0CX
 DB 1EX, "ä", "Ä", 14X, 12X, "ë", 0FFX, 14X, 18X, "ö", "Ö", 14X, 16X, "ü", "Ü", 14X
 DB 17X, "ï", 0FFX, 14X, 1FX, "ß", 0FFX, 14X, 2EX, "ç", 0FFX, 14X, 31X, "ñ", 0FFX, 14X
  (* dead keys (LAlt & RAlt) *)
 DB 07X, 0FFX, 1X, 9X, 28X, 2X, 5X, 9X, 29X, 3X, 4X, 9X,
 DB 07X, 0FFX, 1X, 11X, 28X, 2X, 5X, 11X, 29X, 3X, 4X, 11X,
  (* following keys *)
 DB 1EX, "â", 0FFX, 20X, 12X, "ê", 0FFX, 20X, 17X, "î", 0FFX, 20X, 18X, "ô", 0FFX, 20X
 DB 16X, "û", 0FFX, 20X, 1EX, "à", 0FFX, 60X, 12X, "è", 0FFX, 60X, 17X, "ì", 0FFX, 60X
 DB 18X, "ò", 0FFX, 60X, 16X, "ù", 0FFX, 60X, 1EX, "á", 0FFX, 40X, 12X, "é", 0FFX, 40X
 DB 1EX, "ä", "Ä", 0A4X, 12X, "ë", 0FFX, 0A0X, 17X, "ï", 0FFX, 0A0X, 18X, "ö", "Ö", 0A4X
 DB 16X, "ü", "Ü", 0A4X, 31X, "ñ", 0FFX, 80X
  (* numbers at top *)
 DB 0BX, "0", ")", 0X, 02X, "1", "!", 0X, 03X, "2", "@", 0X, 04X, "3", "#", 0X
 DB 05X, "4", "$", 0X, 06X, "5", "%", 0X, 07X, "6", "^", 0X, 08X, "7", "&", 0X
 DB 09X, "8", "*", 0X, 0AX, "9", "(", 0X
  (* symbol keys *)
 DB 28X, "'", 22X, 0X, 33X, ",", "<", 0X, 0CX, "-", "_", 0X, 34X, ".", ">", 0X
 DB 35X, "/", "?", 0X, 27X, ";", ":", 0X, 0DX, "=", "+", 0X, 1AX, "[", "{", 0X
 DB 2BX, "\", "|", 0X, 1BX, "]", "}", 0X, 29X, "`", "~", 0X
  (* control keys *)
 DB 0EX, 7FX, 7FX, 0X (* backspace *)
 DB 0FX, 09X, 09X, 0X (* tab *)
 DB 1CX, 0DX, 0DX, 0X (* enter *)
 DB 39X, 20X, 20X, 0X (* space *)
 DB 01X, 0FEX, 1BX, 0X (* esc *)
   (* keypad *)
 DB 4FX, 0A9X, "1", 2X (* end/1 *)
 DB 50X, 0C2X, "2", 2X (* down/2 *)
 DB 51X, 0A3X, "3", 2X (* pgdn/3 *)
 DB 4BX, 0C4X, "4", 2X (* left/4 *)
 DB 4CX, 0FFX, "5", 2X (* center/5 *)
 DB 4DX, 0C3X, "6", 2X (* right/6 *)
 DB 47X, 0A8X, "7", 2X (* home/7 *)
 DB 48X, 0C1X, "8", 2X (* up/8 *)
 DB 49X, 0A2X, "9", 2X (* pgup/9 *)
 DB 52X, 0A0X, "0", 2X (* insert/0 *)
 DB 53X, 0A1X, 2EX, 2X (* del/. *)
  (* gray keys *)
 DB 4AX, "-", "-", 0X (* gray - *)
 DB 4EX, "+", "+", 0X (* gray + *)
 DB 0B5X, "/", "/", 0X (* gray / *)
 DB 37X, "*", "*", 0X (* gray * *)
 DB 0D0X, 0C2X, 0C2X, 0X (* gray down *)
 DB 0CBX, 0C4X, 0C4X, 0X (* gray left *)
 DB 0CDX, 0C3X, 0C3X, 0X (* gray right *)
 DB 0C8X, 0C1X, 0C1X, 0X (* gray up *)
 DB 09CX, 0DX, 0DX, 0X (* gray enter *)
 DB 0D2X, 0A0X, 0A0X, 0X (* gray ins *)
 DB 0D3X, 0A1X, 0A1X, 0X (* gray del *)
 DB 0C9X, 0A2X, 0A2X, 0X (* gray pgup *)
 DB 0D1X, 0A3X, 0A3X, 0X (* gray pgdn *)
 DB 0C7X, 0A8X, 0A8X, 0X (* gray home *)
 DB 0CFX, 0A9X, 0A9X, 0X (* gray end *)
  (* function keys *)
 DB 3BX, 0A4X, 0FFX, 0X (* F1 *)
 DB 3CX, 0A5X, 0FFX, 0X (* F2 *)
 DB 3DX, 1BX, 0FFX, 0X (* F3 *)
 DB 3EX, 0A7X, 0FFX, 0X (* F4 *)
 DB 3FX, 0F5X, 0FFX, 0X (* F5 *)
 DB 40X, 0F6X, 0FFX, 0X (* F6 *)
 DB 41X, 0F7X, 0FFX, 0X (* F7 *)
 DB 42X, 0F8X, 0FFX, 0X (* F8 *)
 DB 43X, 0F9X, 0FFX, 0X (* F9 *)
 DB 44X, 0FAX, 0FFX, 0X (* F10 *)
 DB 57X, 0FBX, 0FFX, 0X (* F11 *)
 DB 58X, 0FCX, 0FFX, 0X (* F12 *)
 DB 0FFX
END TableUS;

PROCEDURE UsbScanTab() : LONGINT;
CODE {SYSTEM.i386}
 CALL L1
L1:
 POP EAX
 ADD EAX,8
 POP EBP
 RET

 (* Keyboard table stolen from Linux Usb keyboard driver, and corrected for Oberon *)
 DB 000, 000, 000, 000, 030, 048, 046, 032, 018, 033, 034, 035, 023, 036, 037, 038
 DB 050, 049, 024, 025, 016, 019, 031, 020, 022, 047, 017, 045, 021 ,044, 002, 003
 DB 004, 005, 006, 007, 008, 009, 010, 011, 028, 001, 014, 015 ,057, 012, 013, 026
 DB 027, 043, 043, 039, 040, 041, 051, 052, 053, 058, 059, 060, 061, 062, 063, 064
 DB 065, 066, 067, 068, 087, 088, 099, 070, 119, 210, 199, 201, 211, 207, 209, 205
 DB 203, 208, 200, 069, 181, 055, 074, 078, 156, 079, 080, 081, 075, 076, 077, 071
 DB 072, 073, 082, 083, 086, 127, 116, 117, 085, 089, 090, 091, 092, 093, 094, 095
 DB 120, 121, 122, 123, 134, 138, 130, 132, 128, 129, 131, 137, 133, 135, 136, 113
 DB 115, 114, 000, 000, 000, 000, 000, 124, 000, 000, 000, 000, 000, 000, 000, 000
 DB 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000
 DB 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000
 DB 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000
 DB 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000
 DB 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000, 000
 DB 029, 042, 056, 125, 097, 054, 100, 126, 164, 166, 165, 163, 161, 115, 114, 113
 DB 150, 158, 159, 128, 136, 177, 178, 176, 142, 152, 173, 140, 000, 000, 000, 000

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
