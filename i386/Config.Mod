(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Config; (** non-portable *)

IMPORT SYSTEM, Kernel, V86, OFS, Files, Texts, Modules, Oberon, ConfigInput, MathL;

CONST
 BootFile = "Native.Bin";
 ConfigText = "OberonDrivers.Text";
 
 Normal = 15;  Command = 3; (* colors *)
 
 Inval = Texts.Inval;
 Name = Texts.Name;
 String = Texts.String;
 Int = Texts.Int;
 Char = Texts.Char;
 
 MaxLen = 62;
 CR = 0DX;
 
 NormalMode = 0; LabMode = 1;

 GTFLockVF = 1;  (* Lock to vertical frequency    *)
 GTFLockHF = 2;  (* Lock to horizontal frequency   *)
 GTFLockPF = 3;  (* Lock to pixel clock frequency   *)
 
TYPE
 Scanner = RECORD
  r: Texts.Reader;
  next: CHAR;
  class: SHORTINT;
  i: LONGINT;
  s: ARRAY MaxLen+1 OF CHAR
 END;
 
 GTFConstants = RECORD
  margin: LONGREAL; (* Margin size as percentage of display *)
  cellGran: LONGREAL; (* Character cell granularity *)
  minPorch: LONGREAL; (* Minimum front porch in lines/chars *)
  vSyncRqd: LONGREAL; (* Width of V sync in lines *)
  hSync: LONGREAL; (* Width of H sync as percent of total *)
  minVSyncBP: LONGREAL; (* Minimum vertical sync + back porch (us) *)
  m: LONGREAL; (* Blanking formula gradient *)
  c: LONGREAL; (* Blanking formula offset *)
  k: LONGREAL; (* Blanking formula scaling factor *)
  j: LONGREAL (* Blanking formula scaling factor weight *)
 END;
 
 GTFHCRTC = RECORD
  hTotal: LONGINT; (* Horizontal total *)
  hDisp: LONGINT; (* Horizontal displayed *)
  hSyncStart: LONGINT; (* Horizontal sync start *)
  hSyncEnd: LONGINT; (* Horizontal sync end *)
  hFrontPorch: LONGINT; (* Horizontal front porch *)
  hSyncWidth: LONGINT; (* Horizontal sync width *)
  hBackPorch: LONGINT (* Horizontal back porch *)
 END;

 GTFVCRTC = RECORD
  vTotal: LONGINT; (* Vertical total *)
  vDisp: LONGINT; (* Vertical displayed *)
  vSyncStart: LONGINT; (* Vertical sync start *)
  vSyncEnd: LONGINT; (* Vertical sync end *)
  vFrontPorch: LONGINT; (* Vertical front porch *)
  vSyncWidth: LONGINT; (* Vertical sync width *)
  vBackPorch: LONGINT (* Vertical back porch *)
 END;
 
 GTFTimings = RECORD
  h: GTFHCRTC; (* Horizontal CRTC paremeters *)
  v: GTFVCRTC; (* Vertical CRTC parameters *)
  hSyncPol: CHAR; (* Horizontal sync polarity *)
  vSyncPol: CHAR; (* Vertical sync polarity *)
  interlace: CHAR; (* 'I' for Interlace, 'N' for Non *)
  vFreq: LONGREAL; (* Vertical frequency (Hz) *)
  hFreq: LONGREAL; (* Horizontal frequency (KHz) *)
  dotClock: LONGREAL (* Pixel clock (Mhz) *)
 END;

VAR
 w, w2: Texts.Writer;
 keyboard, dma, cache: ARRAY 32 OF CHAR;
 fontConv, color, numLock: ARRAY 2 OF CHAR;
 display: ARRAY 512 OF CHAR;
 manual, diskset, oberon0: BOOLEAN;
 install: SHORTINT;
 config: Texts.Text;

(*
 Token = Name | String | Int | Char .
 Name = Alpha { Alpha | Digit | "." } .
 String = 22X { StrChar } 22X .
 Int = Digit { Digit } .
 Char = <anything else> .
 Alpha = "A".."Z" | "a".."z" .
 Digit = "0".."9" .
 StrChar = <anything but 0X | 0AX | 0DX | 22X> .
 Seperator = { White } .
 White = 9X | 20X | 0AX | 0DX .
*)

PROCEDURE Scan(VAR s: Scanner);
VAR i: LONGINT;  ch: CHAR;
BEGIN
 ch := s.next;
 WHILE ~s.r.eot & ((ch = 9X) OR (ch = 20X) OR (ch = 0AX) OR (ch = 0DX)) DO
  Texts.Read(s.r, ch)
 END;
 IF s.r.eot THEN
  s.class := Inval
 ELSE
  IF (CAP(ch) >= "A") & (CAP(ch) <= "Z") THEN (* name *)
   i := 0;  s.class := Name;
   REPEAT
    s.s[i] := ch;  INC(i);  Texts.Read(s.r, ch)
   UNTIL s.r.eot OR ~((ch = ".") OR (ch >= "0") & (ch <= "9") OR (CAP(ch) >= "A") & (CAP(ch) <= "Z"));
   s.s[i] := 0X
  ELSIF ch = 22X THEN (* string *)
   i := 0;
   LOOP
    Texts.Read(s.r, ch);
    IF s.r.eot OR (ch = 0X) OR (ch = 0AX) OR (ch = 0DX) THEN s.class := Inval;  EXIT END;
    IF ch = 22X THEN s.class := String;  Texts.Read(s.r, ch);  EXIT END;
    s.s[i] := ch;  INC(i);
    IF i = MaxLen THEN s.class := String;  ch := 22X;  EXIT END
   END;
   s.s[i] := 0X
  ELSIF (ch >= "0") & (ch <= "9") THEN (* int *)
   s.s[0] := ch;  i := 1;
   s.i := ORD(ch)-ORD("0");
   Texts.Read(s.r, ch);
   WHILE ~s.r.eot & (ch >= "0") & (ch <= "9") DO
    s.s[i] := ch;  INC(i);
    s.i := 10*s.i + (ORD(ch)-ORD("0")); (* ignore overflow *)
    Texts.Read(s.r, ch)
   END;
   s.s[i] := 0X;  s.class := Int
  ELSE (* char *)
   s.class := Char;  s.s[0] := ch;  s.s[1] := 0X;
   Texts.Read(s.r, ch)
  END
 END;
 s.next := ch
END Scan;

PROCEDURE OpenScanner(VAR s: Scanner;  text: Texts.Text;  pos: LONGINT);
BEGIN
 Texts.OpenReader(s.r, text, pos);
 Texts.Read(s.r, s.next);
 Scan(s)
END OpenScanner;

PROCEDURE ReadUntil(VAR r: Texts.Reader;  ch: CHAR;  VAR s: ARRAY OF CHAR);
VAR i: LONGINT; next: CHAR;
BEGIN
 i := 0;  Texts.Read(r, next);
 WHILE ~r.eot & (next # ch) DO
  IF i < LEN(s)-1 THEN
   s[i] := next; INC(i)
  END;
  Texts.Read(r, next)
 END;
 s[i] := 0X
END ReadUntil;

PROCEDURE DeleteCmd(cmd: ARRAY OF CHAR;  end: LONGINT;  VAR start: LONGINT);
VAR s: Texts.Scanner;  len: LONGINT;
BEGIN
 len := 0;  WHILE cmd[len] # 0X DO INC(len) END;
 start := Oberon.Par.pos-len; (* start of command *)
 Texts.OpenScanner(s, Oberon.Par.text, start);  Texts.Scan(s);
 IF (s.class = Texts.Name) & (s.s = cmd) THEN
  Texts.Delete(Oberon.Par.text, start, end)
 ELSE
  start := end
 END
END DeleteCmd;

PROCEDURE SetColor(n: SHORTINT);
BEGIN
 Texts.SetColor(w, n)
END SetColor;

PROCEDURE Str(s: ARRAY OF CHAR);
BEGIN
 Texts.WriteString(w, s)
END Str;

PROCEDURE Ln;
BEGIN
 Texts.WriteLn(w)
END Ln;

(*
 config = { "DEVICE" type desc { local } }
 key = <type of device as name>
 desc = <description as string>
 local = <any token except "DEVICE" >
*)

PROCEDURE Options*; (** type *)
CONST Cmd = "Config.Options";
VAR par: Texts.Scanner;  s: Scanner;  pos: LONGINT;
BEGIN
 Texts.OpenScanner(par, Oberon.Par.text, Oberon.Par.pos);  Texts.Scan(par);
 IF par.class = Texts.Name THEN
  OpenScanner(s, config, 0);
  WHILE (s.class = Name) & (s.s = "DEVICE") DO
   Scan(s);  ASSERT(s.class = Name); (* type *)
   IF s.s = par.s THEN
    Scan(s);  ASSERT(s.class = String); (* desc *)
    SetColor(Command);  Str("Config.");
    Str(par.s);  SetColor(Normal);  Texts.Write(w, " ");
    Str(s.s);  Ln
   END;
   REPEAT Scan(s) UNTIL (s.class = Name) & (s.s = "DEVICE") OR (s.class = Inval)
  END;
  DeleteCmd(Cmd, Texts.Pos(par), pos);
  Texts.Insert(Oberon.Par.text, pos, w.buf)
 END
END Options;

PROCEDURE Append(VAR to: ARRAY OF CHAR;  this: ARRAY OF CHAR);
VAR i, j: LONGINT;
BEGIN
 i := 0;  WHILE to[i] # 0X DO INC(i) END;
 j := 0;  WHILE this[j] # 0X DO to[i] := this[j];  INC(i);  INC(j) END;
 to[i] := 0X
END Append;

(*
 config = name "=" value { value } .
 name = <Name> .
 value = <String> .
*)

PROCEDURE Config(VAR s: Scanner;  VAR conf: ARRAY OF CHAR);
BEGIN
 WHILE (s.class = Name) & (s.s # "MODE") & (s.s # "DEVICE") DO
  Append(conf, " ");  Append(conf, s.s); (* name *);
  Scan(s);  ASSERT((s.class = Char) & (s.s[0] = "="));
  Append(conf, "='");
  Scan(s);  ASSERT(s.class = String);
  Append(conf, s.s);  Scan(s);
  WHILE s.class = String DO Append(conf, s.s);  Scan(s) END;
  Append(conf, "'")
 END
END Config;

PROCEDURE SkipConfig(VAR s: Scanner);
BEGIN
 WHILE (s.class # Inval) & ((s.class # Name) OR (s.s # "MODE") & (s.s # "DEVICE")) DO Scan(s) END
END SkipConfig;

PROCEDURE ModeConf(w, h, d: ARRAY OF CHAR;  VAR conf: ARRAY OF CHAR);
BEGIN
 Append(conf, " DWidth='");  Append(conf, w);
 Append(conf, "' DHeight='");  Append(conf, h);
 Append(conf, "' DDepth='");  Append(conf, d);
 Append(conf, "'");
END ModeConf;

PROCEDURE pow(x: LONGREAL; n: LONGINT): LONGREAL;
VAR s: LONGREAL;
BEGIN
 s := 1;
 WHILE n > 0 DO s := s * x; DEC(n) END;
 RETURN s
END pow;

PROCEDURE Round(v: LONGREAL): LONGREAL;
BEGIN
 RETURN ENTIER(v + 0.5)
END Round;

PROCEDURE GetInternalConstants(VAR c: GTFConstants);
VAR GC: GTFConstants;
BEGIN
 GC.margin := 1.8; GC.cellGran := 8; GC.minPorch := 1; GC.vSyncRqd := 3;
 GC.hSync := 8; GC.minVSyncBP := 550; GC.m := 600; GC.c := 40; GC.k := 128; GC.j := 20;
 
 c.margin := GC.margin; c.cellGran := Round(GC.cellGran);
 c.minPorch := Round(GC.minPorch); c.vSyncRqd := Round(GC.vSyncRqd);
 c.hSync := GC.hSync; c.minVSyncBP := GC.minVSyncBP;
 IF GC.k = 0 THEN c.k := 0.001 ELSE c.k := GC.k END;
 c.m := (c.k / 256) * GC.m; c.c := (GC.c - GC.j) * (c.k / 256) + GC.j;
 c.j := GC.j
END GetInternalConstants;

(*
Calculate a set of GTF timing parameters given a specified resolution and vertical frequency. The horizontal frequency and dot clock will be automatically generated by this routines.

For interlaced modes the CRTC parameters are calculated for a single field, so will be half what would be used in a non-interlaced mode.

hPixels - X resolution
vLines - Y resolution
freq - Frequency (Hz, KHz or MHz depending on type)
type - 1 - vertical, 2 - horizontal, 3 - dot clock
margins - True if margins should be generated
interlace - True if interlaced timings to be generated
t - Place to store the resulting timings
*)

PROCEDURE GTFCalcTimings(hPixels, vLines, freq: LONGREAL; type: LONGINT; wantMargins, wantInterlace: BOOLEAN; VAR t: GTFTimings);
VAR
 interlace,vFieldRate,hPeriod: LONGREAL;
 topMarginLines,botMarginLines: LONGREAL;
 leftMarginPixels,rightMarginPixels: LONGREAL;
 hPeriodEst,vSyncBP,vBackPorch: LONGREAL;
 vTotalLines,vFieldRateEst: LONGREAL;
 hTotalPixels,hTotalActivePixels,hBlankPixels: LONGREAL;
 idealDutyCycle,hSyncWidth,hSyncBP,hBackPorch: LONGREAL;
 idealHPeriod: LONGREAL;
 vFreq,hFreq,dotClock: LONGREAL;
 c: GTFConstants;
BEGIN
 GetInternalConstants(c);
 vFreq := freq; hFreq := freq; dotClock := freq;

 (* Round pixels to character cell granularity *)
 hPixels := Round(hPixels / c.cellGran) * c.cellGran;

 (* For interlaced mode halve the vertical parameters, and double the required field refresh rate. *)
 IF wantInterlace THEN
  vLines := Round(vLines / 2);
  vFieldRate := vFreq * 2;
  dotClock := dotClock * 2;
  interlace := 0.5;
 ELSE vFieldRate := vFreq; interlace := 0
 END;

 (* Determine the lines for margins *)
 IF wantMargins THEN
  topMarginLines := Round(c.margin / 100 * vLines);
  botMarginLines := Round(c.margin / 100 * vLines)
 ELSE topMarginLines := 0; botMarginLines := 0
 END;

 IF type # GTFLockPF THEN
  IF type = GTFLockVF THEN
   (* Estimate the horizontal period *)
   hPeriodEst := ((1/vFieldRate)-(c.minVSyncBP/1000000))/
     (vLines+(2*topMarginLines)+c.minPorch+interlace)*1000000;

   (* Find the number of lines in vSync + back porch *)
   vSyncBP := Round(c.minVSyncBP / hPeriodEst);
  ELSIF type = GTFLockHF THEN
   (* Find the number of lines in vSync + back porch *)
   vSyncBP := Round((c.minVSyncBP * hFreq) / 1000);
  END;

  (* Find the number of lines in the V back porch alone *)
  vBackPorch := vSyncBP - c.vSyncRqd;

  (* Find the total number of lines in the vertical period *)
  vTotalLines := vLines + topMarginLines + botMarginLines + vSyncBP
    + interlace + c.minPorch;

  IF type = GTFLockVF THEN
   (* Estimate the vertical frequency *)
   vFieldRateEst := 1000000 / (hPeriodEst * vTotalLines);

   (* Find the actual horizontal period *)
   hPeriod := (hPeriodEst * vFieldRateEst) / vFieldRate;

   (* Find the actual vertical field frequency *)
   vFieldRate := 1000000 / (hPeriod * vTotalLines);
  ELSIF type = GTFLockHF THEN
   (* Find the actual vertical field frequency *)
   vFieldRate := (hFreq / vTotalLines) * 1000;
  END
 END;

 (* Find the number of pixels in the left and right margins *)
 IF wantMargins THEN
  leftMarginPixels := Round(hPixels * c.margin) / (100 * c.cellGran);
  rightMarginPixels := Round(hPixels * c.margin) / (100 * c.cellGran);
 ELSE leftMarginPixels := 0; rightMarginPixels := 0
 END;

 (* Find the total number of active pixels in image + margins *)
 hTotalActivePixels := hPixels + leftMarginPixels + rightMarginPixels;

 IF type = GTFLockVF THEN
  (* Find the ideal blanking duty cycle *)
  idealDutyCycle := c.c - ((c.m * hPeriod) / 1000)
 ELSIF type = GTFLockHF THEN
  (* Find the ideal blanking duty cycle *)
  idealDutyCycle := c.c - (c.m / hFreq);
 ELSIF type = GTFLockPF THEN
  (* Find ideal horizontal period from blanking duty cycle formula *)
  idealHPeriod := (((c.c - 100) + (MathL.sqrt((pow(100-c.c,2)) +
   (0.4 * c.m * (hTotalActivePixels + rightMarginPixels +
   leftMarginPixels) / dotClock)))) / (2 * c.m)) * 1000;

  (* Find the ideal blanking duty cycle *)
  idealDutyCycle := c.c - ((c.m * idealHPeriod) / 1000);
 END;

 (* Find the number of pixels in blanking time *)
 hBlankPixels := Round((hTotalActivePixels * idealDutyCycle) /
  ((100 - idealDutyCycle) * c.cellGran)) * c.cellGran;

 (* Find the total number of pixels *)
 hTotalPixels := hTotalActivePixels + hBlankPixels;

 (* Find the horizontal back porch *)
 hBackPorch := Round((hBlankPixels / 2) / c.cellGran) * c.cellGran;

 (* Find the horizontal sync width *)
 hSyncWidth := Round(((c.hSync/100) * hTotalPixels) / c.cellGran) * c.cellGran;

 (* Find the horizontal sync + back porch *)
 hSyncBP := hBackPorch + hSyncWidth;

 IF type = GTFLockPF THEN
  (* Find the horizontal frequency *)
  hFreq := (dotClock / hTotalPixels) * 1000;

  (* Find the number of lines in vSync + back porch *)
  vSyncBP := Round((c.minVSyncBP * hFreq) / 1000);

  (* Find the number of lines in the V back porch alone *)
  vBackPorch := vSyncBP - c.vSyncRqd;

  (* Find the total number of lines in the vertical period *)
  vTotalLines := vLines + topMarginLines + botMarginLines + vSyncBP
   + interlace + c.minPorch;

  (* Find the actual vertical field frequency *)
  vFieldRate := (hFreq / vTotalLines) * 1000;
 ELSE
  IF type = GTFLockVF THEN
   (* Find the horizontal frequency *)
   hFreq := 1000 / hPeriod;
  ELSIF type = GTFLockHF THEN
   (* Find the horizontal frequency *)
   hPeriod := 1000 / hFreq;
  END;

  (* Find the pixel clock frequency *)
  dotClock := hTotalPixels / hPeriod;
 END;

 (* Find the vertical frame frequency *)
 IF wantInterlace THEN vFreq := vFieldRate / 2; dotClock := dotClock / 2;
 ELSE vFreq := vFieldRate
 END;

 (* Return the computed frequencies *)
 t.vFreq := vFreq;
 t.hFreq := hFreq;
 t.dotClock := dotClock;

 (* Determine the vertical timing parameters *)
 t.h.hTotal := ENTIER(hTotalPixels);
 t.h.hDisp := ENTIER(hTotalActivePixels);
 t.h.hSyncStart := ENTIER(t.h.hTotal - hSyncBP);
 t.h.hSyncEnd := ENTIER(t.h.hTotal - hBackPorch);
 t.h.hFrontPorch := t.h.hSyncStart - t.h.hDisp;
 t.h.hSyncWidth := ENTIER(hSyncWidth);
 t.h.hBackPorch := ENTIER(hBackPorch);

 (* Determine the vertical timing parameters *)
 t.v.vTotal := ENTIER(vTotalLines);
 t.v.vDisp := ENTIER(vLines);
 t.v.vSyncStart := ENTIER(t.v.vTotal - vSyncBP);
 t.v.vSyncEnd := ENTIER(t.v.vTotal - vBackPorch);
 t.v.vFrontPorch := t.v.vSyncStart - t.v.vDisp;
 t.v.vSyncWidth := ENTIER(c.vSyncRqd);
 t.v.vBackPorch := ENTIER(vBackPorch);

 (* Mark as GTF timing using the sync polarities *)
 IF wantInterlace THEN t.interlace := 'I' ELSE t.interlace := 'N' END;
 t.hSyncPol := '-';
 t.vSyncPol := '+'
END GTFCalcTimings;

PROCEDURE VesaConf(mode, width, height, hz: LONGINT; VAR conf: ARRAY OF CHAR);
VAR mode1: LONGINT; flags: SET; t: GTFTimings;

 PROCEDURE Hex(x: LONGINT);
 VAR s: ARRAY 2 OF CHAR;
 BEGIN
  IF x < 10 THEN s[0] := CHR(ORD("0")+x)
  ELSE s[0] := CHR(ORD("a")+x-10)
  END;
  s[1] := 0X; Append(conf, s)
 END Hex;
 
 PROCEDURE HexByte(x: LONGINT);
 BEGIN
  Hex(x DIV 10H MOD 10H); Hex(x MOD 10H)
 END HexByte;
 
 PROCEDURE HexWord(x: LONGINT);
 BEGIN
  HexByte(x MOD 100H); HexByte(x DIV 100H)
 END HexWord;
 
 PROCEDURE HexDWord(x: LONGINT);
 BEGIN
  HexWord(x MOD 10000H); HexWord(x DIV 10000H)
 END HexDWord;

BEGIN
 Append(conf, " Init='");
 IF hz > 0 THEN (* VESA 3.0 - set refresh rate *)
  mode1 := mode + 4800H;
  GTFCalcTimings(width, height, hz, GTFLockVF, FALSE, FALSE, t);
  Append(conf, "b80b4fbb0000ba"); HexWord(mode); (* mov ax, 4F0BH; mov bx, 0; mov dx, mode *)
  Append(conf, "66b9"); HexDWord(hz * t.h.hTotal * t.v.vTotal); (* mov ecx, val *)
  Append(conf, "cd1026c705"); HexWord(t.h.hTotal); (* int 10H; mov [es:di], val *)
  Append(conf, "26c74502"); HexWord(t.h.hSyncStart); (* mov [es:di+2], val *)
  Append(conf, "26c74504"); HexWord(t.h.hSyncEnd); (* mov [es:di+4], val *)
  Append(conf, "26c74506"); HexWord(t.v.vTotal); (* mov [es:di+6], val *)
  Append(conf, "26c74508"); HexWord(t.v.vSyncStart); (* mov [es:di+8], val *)
  Append(conf, "26c7450a"); HexWord(t.v.vSyncEnd); (* mov [es:di+0AH], val *)
  flags := {};
  IF t.interlace = "I" THEN INCL(flags, 1) END;
  IF t.hSyncPol = "-" THEN INCL(flags, 2) END;
  IF t.vSyncPol = "-" THEN INCL(flags, 3) END;
  Append(conf, "26c6450c"); HexByte(SYSTEM.VAL(LONGINT, flags)); (* mov [es:di+0CH], val *)
  Append(conf, "2666894d0d26c74511"); HexWord(hz*100) (* mov [es:di+0DH], ecx; mov [es:di+11H], val *)
 ELSE (* VESA 2.0 *)
  mode1 := mode + 4000H (* enable framebuffer *)
 END;
 Append(conf, "b8024fbb"); HexWord(mode1); (* mov ax, 4F02H; mov bx, mode1 *)
 Append(conf, "cd10b8014fb9"); HexWord(mode); (* int 10H; mov ax, 4F01H; mov cx, mode *)
 Append(conf, "cd10268b4d28268b552a"); (* int 10H; mov cx, [es:di+28H]; mov dx, [es:di+2AH] *)
 Append(conf, "'")
END VesaConf;

PROCEDURE WriteMode(VAR w: Texts.Writer;  VAR desc, width, height, depth: ARRAY OF CHAR; hz: LONGINT);
BEGIN
 Texts.WriteString(w, desc);
 Texts.WriteString(w, ": ");  Texts.WriteString(w, width);
 Texts.WriteString(w, "*");  Texts.WriteString(w, height);
 Texts.WriteString(w, "*");  Texts.WriteString(w, depth);
 IF hz > 0 THEN
  Texts.WriteString(w, " @ ");  Texts.WriteInt(w, hz, 1);  Texts.WriteString(w, "Hz")
 END
END WriteMode;

PROCEDURE Mode*; (** <parameter written by WriteMode> *)
VAR
 par: Texts.Reader;  s: Scanner;  width, height, depth, hz: ARRAY 8 OF CHAR;
 desc: ARRAY 64 OF CHAR;  ok, found: BOOLEAN;  vesa, vw, vh, vhz: LONGINT;
BEGIN
 Texts.OpenReader(par, Oberon.Par.text, Oberon.Par.pos+1);
 ReadUntil(par, ":", desc);  ASSERT(~par.eot);
 OpenScanner(s, Oberon.Par.text, Texts.Pos(par));
 ASSERT(s.class = Int);  COPY(s.s, width);  Scan(s);
 ASSERT(s.class = Char);  Scan(s); (* * *)
 ASSERT(s.class = Int);  COPY(s.s, height);  Scan(s);
 ASSERT(s.class = Char);  Scan(s); (* * *)
 ASSERT(s.class = Int);  COPY(s.s, depth);  Scan(s);
 IF (s.class = Char) & (s.s = "@") THEN Scan(s) END; (* @ *)
 IF s.class = Int THEN vhz := s.i; COPY(s.s, hz) ELSE vhz := 0; hz := "" END;
 OpenScanner(s, config, 0);  found := FALSE;
 WHILE (s.class = Name) & (s.s = "DEVICE") DO
  Scan(s);  ASSERT(s.class = Name); (* type *)
  IF s.s = "Display" THEN
   Scan(s);  ASSERT(s.class = String); (* desc *)
   IF s.s = desc THEN (* found *)
    display := "";  Scan(s);  Config(s, display);
    WHILE (s.class = Name) & (s.s = "MODE") DO
     ok := TRUE;
     Scan(s);  ASSERT(s.class = Int);  ok := ok & (s.s = width);  vw := s.i;
     Scan(s);  ASSERT(s.class = Int);  ok := ok & (s.s = height);  vh := s.i;
     Scan(s);  ASSERT(s.class = Int);  ok := ok & (s.s = depth);
     Scan(s);
     IF s.class = Int THEN Scan(s) END; (* hz *)
     IF (s.class = Name) & (s.s = "VESA") THEN
      Scan(s);  ASSERT(s.class = Int);  vesa := s.i;
      Scan(s)
     ELSE
      vesa := 0
     END;
     IF (s.class = Name) & (s.s = "DEFAULT") THEN Scan(s) END;
     IF ok THEN
      found := TRUE;
      Config(s, display);
      IF vesa # 0 THEN
       VesaConf(vesa, vw, vh, vhz, display)
      ELSE
       Append(display, " DRefresh='");  Append(display, hz);  Append(display, "'");
      END;
      ModeConf(width, height, depth, display);
      Str("Display: ");
      WriteMode(w, desc, width, height, depth, vhz);
      Ln;  Texts.Append(Oberon.Log, w.buf)
     ELSE
      SkipConfig(s)
     END
    END
   END
  END;
  WHILE (s.class # Inval) & ((s.class # Name) OR (s.s # "DEVICE")) DO Scan(s) END
 END;
 IF ~found THEN
  Str("Config.Options Display");  Ln;
  Texts.Append(Oberon.Log, w.buf)
 END
END Mode;

PROCEDURE Display*; (** desc *)
CONST Cmd = "Config.Display";
VAR
 par: Texts.Reader;  s: Scanner;  pos, vesa, vw, vh, vhz: LONGINT;  found: BOOLEAN;
 width, height, depth, hz: ARRAY 8 OF CHAR;  desc: ARRAY 64 OF CHAR;
BEGIN
 Texts.OpenReader(par, Oberon.Par.text, Oberon.Par.pos+1);
 ReadUntil(par, CR, desc);
 OpenScanner(s, config, 0);  found := FALSE;
 WHILE (s.class = Name) & (s.s = "DEVICE") DO
  Scan(s);  ASSERT(s.class = Name); (* type *)
  IF s.s = "Display" THEN
   Scan(s);  ASSERT(s.class = String); (* desc *)
   IF s.s = desc THEN (* found *)
    Str(desc);  Ln;
    found := TRUE;  display := "";  Scan(s);  Config(s, display);
    WHILE (s.class = Name) & (s.s = "MODE") DO
     Scan(s);  ASSERT(s.class = Int);  COPY(s.s, width);  vw := s.i;
     Scan(s);  ASSERT(s.class = Int);  COPY(s.s, height);  vh := s.i;
     Scan(s);  ASSERT(s.class = Int);  COPY(s.s, depth);
     Scan(s);
     IF s.class = Int THEN vhz := s.i; COPY(s.s, hz); Scan(s) ELSE vhz := 0; hz := "" END;
     IF (s.class = Name) & (s.s = "VESA") THEN
      Scan(s);  ASSERT(s.class = Int);  vesa := s.i;
      Scan(s)
     END;
     IF (s.class = Name) & (s.s = "DEFAULT") THEN
      Scan(s);  Config(s, display);
      IF vesa # 0 THEN
       VesaConf(vesa, vw, vh, vhz, display)
      ELSE
       Append(display, " DRefresh='");  Append(display, hz);  Append(display, "'");
      END;
      ModeConf(width, height, depth, display);
      Texts.WriteString(w2, "Display: ");
      WriteMode(w2, desc, width, height, depth, vhz);
      Texts.WriteLn(w2);  Texts.Append(Oberon.Log, w2.buf)
     ELSE
      SkipConfig(s)
     END;
     Texts.Write(w, 9X);  SetColor(Command);
     Str("Config.Mode ");  SetColor(Normal);
     WriteMode(w, desc, width, height, depth, vhz);  Ln
    END;
    DeleteCmd(Cmd, Texts.Pos(par), pos);
    Texts.Insert(Oberon.Par.text, pos, w.buf)
   END
  END;
  WHILE (s.class # Inval) & ((s.class # Name) OR (s.s # "DEVICE")) DO Scan(s) END
 END;
 IF ~found THEN
  Str("Config.Options Display");  Ln;
  Texts.Append(Oberon.Log, w.buf)
 END
END Display;

PROCEDURE WriteStringAdr(VAR w: Texts.Writer;  adr: LONGINT);
VAR ch: CHAR;
BEGIN
 IF adr = 0 THEN
  Texts.WriteString(w, "[NIL]")
 ELSE
  LOOP
   SYSTEM.GET(adr, ch);
   IF ch = 0X THEN EXIT END;
   Texts.Write(w, ch);
   INC(adr)
  END
 END
END WriteStringAdr;

PROCEDURE Normalize(VAR adr: LONGINT);
BEGIN
 adr := ASH(ASH(adr, -16) MOD 10000H, 4) + adr MOD 10000H
END Normalize;

PROCEDURE DetectVesa*;
CONST Cmd = "Config.DetectVesa";
VAR
 reg: V86.Regs; a, n, linbuf, i, modes, pos: LONGINT; ver, size, width, height, m: INTEGER; s: ARRAY 8 OF CHAR;
 bpp, rsize, gsize, bsize, esize, memtype: SHORTINT;
 mode: ARRAY 64 OF LONGINT; attr: SET; par: Texts.Reader;
BEGIN
 V86.Init;
 s := "VBE2";
 SYSTEM.MOVE(SYSTEM.ADR(s[0]), V86.bufadr, 4);
 
 reg.EAX := 4F00H;
 reg.ES := V86.bufadr DIV 16;
 reg.EDI := V86.bufadr MOD 16;
 V86.Video(reg);
 
 modes := 0;
 IF reg.EAX MOD 10000H = 4FH THEN
  SYSTEM.MOVE(V86.bufadr, SYSTEM.ADR(s[0]), 4);  s[4] := 0X;
  SYSTEM.GET(V86.bufadr+4, ver);
  Str(s);  Texts.WriteInt(w, ver DIV 100H, 2);  Texts.Write(w, ".");  
  Texts.WriteInt(w, ver MOD 100H, 1);
  SYSTEM.GET(V86.bufadr+6, a);  Normalize(a);
  Texts.Write(w, " ");  Texts.Write(w, 22X);  WriteStringAdr(w, a);  Texts.Write(w, 22X);
  SYSTEM.GET(V86.bufadr+18, size);
  Texts.Write(w, " ");  Texts.WriteInt(w, LONG(size)*64, 1);  Texts.WriteString(w, "KB");
  Ln;
  
  IF ver >= 0200H THEN (* 2.0+ *)
   SYSTEM.GET(V86.bufadr+14, a);  Normalize(a);
   n := 0;
   LOOP
    SYSTEM.GET(a, m);
    IF (m = -1) OR (n = LEN(mode)) THEN EXIT END;
    mode[n] := m;  INC(n);
    INC(a, 2)
   END;
   
   FOR i := 0 TO n-1 DO
    reg.EAX := 4F01H;
    reg.ECX := mode[i];
    reg.ES := V86.bufadr DIV 16;
    reg.EDI := V86.bufadr MOD 16;
    V86.Video(reg);
 
    IF reg.EAX MOD 10000H = 4FH THEN
     SYSTEM.GET(V86.bufadr, attr); (* 0..15=mode attr, 16..23=window A attr, 24..31=window B attr *)
     IF attr * {0,1,3,4,7} = {0,1,3,4,7} THEN (* supported, info available, color, graphics, linbuf *)
      SYSTEM.GET(V86.bufadr+12H, width);
      SYSTEM.GET(V86.bufadr+14H, height);
      SYSTEM.GET(V86.bufadr+19H, bpp);
      SYSTEM.GET(V86.bufadr+1BH, memtype);
      SYSTEM.GET(V86.bufadr+1FH, rsize);
      SYSTEM.GET(V86.bufadr+21H, gsize);
      SYSTEM.GET(V86.bufadr+23H, bsize);
      SYSTEM.GET(V86.bufadr+25H, esize);
      SYSTEM.GET(V86.bufadr+28H, linbuf);
      IF (bpp MOD 8 = 0) & (linbuf # 0) & (LONG(width)*height >= 640*480) THEN
       IF ((memtype = 4) & (bpp = 8)) OR ((memtype = 6) & (rsize+gsize+bsize+esize = bpp)) THEN
        Texts.Write(w, 9X); SetColor(Command);
        Str("Config.Vesa"); SetColor(Normal);
        Texts.WriteHex(w, mode[i]); Str("H: ");
        Texts.WriteInt(w, width, 1); Str(" * ");
        Texts.WriteInt(w, height, 1); Str(" * ");
        Texts.WriteInt(w, bpp, 1);
        IF ver >= 0300H THEN Str(" @ 75Hz") END;
        IF LONG(width)*height*(bpp DIV 8) > LONG(size)*65536 THEN
         Str(" (enough memory?)")
        END;
        Ln;
        INC(modes)
       END
      END
     END
    END
   END
  END;
  IF modes = 0 THEN
   Texts.Write(w, 9X); Str("No suitable VESA modes found"); Ln
  END
 ELSE
  Str("VESA not found"); Ln
 END;
 Texts.OpenReader(par, Oberon.Par.text, Oberon.Par.pos+1);
 ReadUntil(par, CR, s);
 DeleteCmd(Cmd, Texts.Pos(par), pos);
 Texts.Insert(Oberon.Par.text, pos, w.buf);
 V86.Cleanup
END DetectVesa;

PROCEDURE IntToStr(x: LONGINT;  VAR buf: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN
 FOR i := 7 TO 0 BY -1 DO
  buf[i] := CHR(x MOD 10H + 48);
  IF buf[i] > "9" THEN
   buf[i] := CHR(ORD(buf[i]) - 48 + 65 - 10)
  END;
  x := x DIV 10H
 END;
 buf[8] := "H";  buf[9] := 0X
END IntToStr;

PROCEDURE Vesa*; (** mode [{symbols} "@" hz] *)
VAR s: Texts.Scanner; mode, hz: ARRAY 12 OF CHAR; line: INTEGER;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class = Texts.Int THEN
  IntToStr(s.i, mode); hz := ""; line := s.line;
  Texts.Scan(s);
  WHILE (s.line = line) & ((s.class # Texts.Char) OR (s.c # "@")) DO Texts.Scan(s) END;
  IF (s.class = Texts.Char) & (s.c = "@") THEN
   Texts.Scan(s);
   IF s.class = Texts.Int THEN IntToStr(s.i, hz) END
  END;
  display := " Display='Displays.' DDriver='DisplayLinear' DMode='";
  Append(display, mode);
  IF hz # "" THEN Append(display, "' DRefresh='"); Append(display, hz) END;
  Append(display, "' TraceConsole='1'");
  Str("Vesa mode ");  Str(mode);
  Ln; Texts.Append(Oberon.Log, w.buf)
 END
END Vesa;

PROCEDURE Execute;
VAR t: Texts.Text;  par: Oberon.ParList;  s: Texts.Scanner;  res: INTEGER;
BEGIN
 Ln;
 IF manual THEN
  Texts.Append(Oberon.Log, w.buf)
 ELSE
  NEW(t);  Texts.Open(t, "");  Texts.Append(t, w.buf);
  Texts.OpenScanner(s, t, 0);  Texts.Scan(s);
  ASSERT(s.class = Texts.Name);
  NEW(par);  par.vwr := Oberon.Par.vwr;  par.frame := Oberon.Par.frame;
  par.text := t;  par.pos := Texts.Pos(s)-1;
  Oberon.Call(s.s, par, FALSE, res);
  IF res # 0 THEN
   Str("Call error: ");
   Str(Modules.resMsg);
   Ln;  Texts.Append(Oberon.Log, w.buf);
   HALT(99)
  END
 END
END Execute;

PROCEDURE ExecuteInstall(mod: ARRAY OF CHAR);
VAR i, j: LONGINT; ch: CHAR;
BEGIN
 i := 0;
 REPEAT
  WHILE mod[i] = " " DO INC(i) END;
  j := 0; WHILE mod[i] > " " DO mod[j] := mod[i]; INC(i); INC(j) END;
  ch := mod[i]; INC(i); mod[j] := 0X;
  SetColor(Command);  Str(mod); Str(".Install");  SetColor(Normal);
  Execute;
 UNTIL ch < " "
END ExecuteInstall;

PROCEDURE SetDisk(mod, import: ARRAY OF CHAR);
BEGIN
 ExecuteInstall(mod);
 SetColor(Command);  Str("BootLinker.Link ");  SetColor(Normal);
 Str(BootFile);  Str(" \refs \integrate 1000H Kernel Disks ");
 IF import # "" THEN
  Str(import);  Texts.Write(w, " ")
 END;
 Str(mod);
 Str(" OFS Files Modules OFSDiskVolumes OFSCacheVolumes");
 Str(" OFSRAMVolumes"); (* really only needed for Lab mode *)
 Str(" Unicode OFSFATVolumes OFSFATFiles OFSFileVolumes"); (* really only needed for FAT-based mode *)
(*
 Str(" Unicode OFSFATVolumes OFSFATFiles OFSFileBasedDevices OFSVBoot"); (* for DOS-based mode *)
*)
 Str(" OFSAosFiles");
 Str(" OFSBoot ~");
 Execute
END SetDisk;

PROCEDURE Disk*; (** desc *)
VAR par: Texts.Reader;  s: Scanner;  mod: ARRAY 32 OF CHAR;  imp, desc: ARRAY 64 OF CHAR;
BEGIN
 IF diskset THEN
  Str("Disk driver already selected");  Ln;
  Str("Reboot to select another driver");  Ln;
  Texts.Append(Oberon.Log, w.buf)
 ELSE
  diskset := TRUE;
  Texts.OpenReader(par, Oberon.Par.text, Oberon.Par.pos+1);
  ReadUntil(par, CR, desc);
  OpenScanner(s, config, 0);
  WHILE (s.class = Name) & (s.s = "DEVICE") DO
   Scan(s);  ASSERT(s.class = Name); (* type *)
   IF s.s = "Disk" THEN
    Scan(s);  ASSERT(s.class = String); (* desc *)
    IF s.s = desc THEN (* found *)
     Scan(s);  ASSERT(s.class IN {Name, String});  COPY(s.s, mod);
     Scan(s);  ASSERT(s.class = String);  COPY(s.s, imp);
     Str("Disk: ");  Str(desc);
     Ln;  Texts.Append(Oberon.Log, w.buf);
     SetDisk(mod, imp)
    END
   END;
   WHILE (s.class # Inval) & ((s.class # Name) OR (s.s # "DEVICE")) DO Scan(s) END
  END
 END
END Disk;

(*
PROCEDURE Keyboard*; (** desc *)
VAR par: Texts.Reader;  s: Scanner;  desc: ARRAY 64 OF CHAR;
BEGIN
 Texts.OpenReader(par, Oberon.Par.text, Oberon.Par.pos+1);
 ReadUntil(par, CR, desc);
 OpenScanner(s, config, 0);
 WHILE (s.class = Name) & (s.s = "DEVICE") DO
  Scan(s);  ASSERT(s.class = Name); (* type *)
  IF s.s = "Keyboard" THEN
   Scan(s);  ASSERT(s.class = String); (* desc *)
   IF s.s = desc THEN (* found *)
    Scan(s);  ASSERT(s.class = Name);
    IF s.s # "DEVICE" THEN COPY(s.s, keyboard);  Scan(s)
    ELSE keyboard := ""
    END;
    Str("Keyboard: ");  Str(desc);
    Ln;  Texts.Append(Oberon.Log, w.buf)
   END
  END;
  WHILE (s.class # Inval) & ((s.class # Name) OR (s.s # "DEVICE")) DO Scan(s) END
 END
END Keyboard;
*)

PROCEDURE Quote;
BEGIN
 Texts.Write(w, 22X)
END Quote;

PROCEDURE FixQuotes(VAR conf: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN
 i := 0;
 WHILE conf[i] # 0X DO
  IF conf[i] = "'" THEN conf[i] := 22X END;
  INC(i)
 END
END FixQuotes;

(* CopyConfig - Copy most Oberon-0 config strings to installed system. *)

PROCEDURE CopyConfig;
VAR p, i, type, size: LONGINT;  name: ARRAY 32 OF CHAR;  ch: CHAR;
BEGIN
  (* find config strings in table *)
 p := Kernel.bt;
 LOOP
  SYSTEM.GET(p, type);
  IF type = -1 THEN
   RETURN (* no config strings found *)
  ELSIF type = 8 THEN (* config strings *)
   p := p+8; (* configadr *)
   EXIT
  END;
  SYSTEM.GET(p+4, size);  INC(p, size)
 END;
  (* copy config strings *)
 LOOP
  i := -1;  REPEAT INC(i);  SYSTEM.GET(p, name[i]);  INC(p) UNTIL name[i] = 0X;
  IF name[0] = 0X THEN EXIT END;
  IF (name = "Init") OR (name = "DiskCache") OR 
    ((name[0] = "A") & (name[1] >= "0") & (name[1] <= "9")) THEN
   REPEAT SYSTEM.GET(p, ch);  INC(p) UNTIL ch = 0X (* skip value *)
  ELSE (* copy value *)
   Texts.Write(w, " ");  Str(name);
   Str('="');
   LOOP
    SYSTEM.GET(p, ch);  INC(p);  INC(i);
    IF ch = 0X THEN EXIT END;
    Texts.Write(w, ch)
   END;
   Quote
  END
 END
END CopyConfig;

PROCEDURE SetConfig(name, value: ARRAY OF CHAR);
BEGIN
 IF value # "" THEN
  Texts.Write(w, " ");  Str(name);
  Texts.Write(w, "=");  Quote;  Str(value);  Quote
 END
END SetConfig;

PROCEDURE Params;
BEGIN
 ConfigInput.WriteParams(w);
 SetConfig("FontConv", fontConv);
 SetConfig("DMASize", dma);
 SetConfig("Color", color);
 SetConfig("Keyboard", keyboard);
 SetConfig("NumLock", numLock);
 SetConfig("TraceModules", "1");
 FixQuotes(display);  Str(display);
 IF oberon0 THEN CopyConfig END (* strings entered at OBL prompt *)
END Params;

PROCEDURE GetBoolean(command: ARRAY OF CHAR;  VAR value: ARRAY OF CHAR);
VAR s: Texts.Scanner;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 Str(command);  Texts.Write(w, " ");
 IF (s.class = Texts.Name) & (s.s = "on") THEN
  Str("on");
  COPY("1", value)
 ELSIF (s.class = Texts.Name) & (s.s = "off") THEN
  Str("off");
  COPY("0", value)
 ELSE
  Str("on or off ?");
  COPY("", value)
 END;
 Ln;  Texts.Append(Oberon.Log, w.buf)
END GetBoolean;

PROCEDURE Color*; (** on | off *)
BEGIN
 GetBoolean("Color", color)
END Color;

PROCEDURE NumLock*; (** on | off *)
BEGIN
 GetBoolean("NumLock", numLock)
END NumLock;

PROCEDURE FontConversion*; (** on | off *)
BEGIN
 GetBoolean("FontConversion", fontConv)
END FontConversion;

PROCEDURE DMABuffer*; (** numbytes *)
VAR s: Texts.Scanner;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class = Texts.Int THEN
  IntToStr(s.i, dma);
  Str("DMABuffer ");  Str(dma);
  Ln;  Texts.Append(Oberon.Log, w.buf)
 END
END DMABuffer;

PROCEDURE DiskCache*; (** numblocks *)
VAR s: Texts.Scanner; hash: LONGINT;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class = Texts.Int THEN
  IF s.i >= 1000 THEN hash := s.i DIV 5 ELSE hash := s.i END;
  cache := ""; OFS.AppendInt(hash, cache);
  OFS.AppendStr(" ", cache); OFS.AppendInt(s.i, cache);
  Str("DiskCache "); Texts.WriteInt(w, s.i, 1);
  Str(" blocks"); Ln;
  Texts.Append(Oberon.Log, w.buf)
 END
END DiskCache;

(* GetBootVol - Get the boot volume.  Uses the volume name associated with prefix "DST". *)

PROCEDURE GetBootVol(VAR vol, fat: ARRAY OF CHAR): BOOLEAN;
VAR fs: OFS.FileSystem; i: LONGINT;
BEGIN
 fs := OFS.First(); WHILE (fs # NIL) & (fs.prefix # "DST") DO fs := OFS.Next(fs) END;
 IF fs # NIL THEN
  COPY(fs.vol.name, vol);
  i := 0; WHILE (vol[i] # 0X) & (vol[i] # ":") DO INC(i) END;
  IF vol[i] = ":" THEN (* a fat-based volume *)
   COPY(vol, fat); vol[i] := 0X;
   fs := OFS.First(); WHILE (fs # NIL) & (fs.prefix # vol) DO fs := OFS.Next(fs) END;
   IF fs # NIL THEN
    COPY(fs.vol.name, vol)
   ELSE
    Str(vol); Str(": FAT filesystem not found"); Ln;
    Texts.Append(Oberon.Log, w.buf);
    RETURN FALSE
   END
  ELSE
   fat[0] := 0X
  END;
  RETURN TRUE
 ELSE
  Str("DST: destination filesystem not found"); Ln;
  Texts.Append(Oberon.Log, w.buf);
  RETURN FALSE
 END
END GetBootVol;

PROCEDURE WriteBootVol(VAR vol, fat: ARRAY OF CHAR);
BEGIN
 Str(" BootVol="); Quote;
 IF install = LabMode THEN (* in LabMode RAM is mounted first *)
  Str("RAM RamFS -30 4096"); Quote;
  Str(" BootVol1="); Quote
 END;
 IF fat # "" THEN
  Str("FAT FatFS "); Str(vol);
  IF install = LabMode THEN Str(",R") END;
  Quote;
  IF install # LabMode THEN Str(" BootVol1=") ELSE Str(" BootVol2=") END;
  Quote; Str("SYS FileFS "); Str(fat); Quote
 ELSE
  Str("SYS ");
  IF cache # "" THEN Str(cache); Str(" ") END;
  Str("AosFS "); Str(vol);
  IF install = LabMode THEN Str(",R") END;
  Quote
 END;
 Str(" AosFS="); Quote; Str("OFSDiskVolumes.New OFSAosFiles.NewFS"); Quote;
 Str(" RamFS="); Quote; Str("OFSRAMVolumes.New OFSAosFiles.NewFS"); Quote;
 Str(" FatFS="); Quote; Str("OFSFATVolumes.New OFSFATFiles.NewFS"); Quote;
 Str(" FileFS="); Quote; Str("OFSFileVolumes.New OFSAosFiles.NewFS"); Quote
END WriteBootVol;

PROCEDURE BootDiskette*;
VAR vol, fat: ARRAY 64 OF CHAR;
BEGIN
 IF GetBootVol(vol, fat) THEN
  SetColor(Command); Str("Partitions.Format "); SetColor(Normal);
  Str("Diskette0#0 AosFS Native.Bin -1 ~");
  Execute;
  SetColor(Command);  Str("Partitions.SetConfig "); SetColor(Normal);
  Str("Diskette0#0"); WriteBootVol(vol, fat);
  Params; Str(" ~");
  Execute
 END
END BootDiskette;

PROCEDURE BootPartition*; (** menu | direct *)
VAR s: Texts.Scanner; flag: SHORTINT; vol, fat: ARRAY 64 OF CHAR;
BEGIN
 IF GetBootVol(vol, fat) THEN
  IF fat = "" THEN
   Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
   Texts.Scan(s);
   IF (s.class = Texts.Name) & (s.s = "menu") THEN flag := -2 ELSE flag := -1 END;
   SetColor(Command); Str("Partitions.SetConfig "); SetColor(Normal);
   Str(vol); WriteBootVol(vol, fat);
   Params; Str(" ~");
   Execute
  ELSE
   Str("FAT-based system can not be booted directly"); Ln;
   Texts.Append(Oberon.Log, w.buf)
  END
 END
END BootPartition;

PROCEDURE WriteString(VAR r: Files.Rider;  s: ARRAY OF CHAR);
VAR i: LONGINT;
BEGIN
 i := 0;  WHILE s[i] # 0X DO Files.Write(r, s[i]);  INC(i) END
END WriteString;

PROCEDURE WriteLn(VAR r: Files.Rider);
BEGIN
 Files.Write(r, 0DX);  Files.Write(r, 0AX)
END WriteLn;

(** Generate Native.Par file *)

PROCEDURE Generate*; (* parfilename *)
VAR t: Texts.Text; s: Texts.Scanner; f: Files.File; r: Files.Rider; ch: CHAR; quote: BOOLEAN; vol, fat: ARRAY 64 OF CHAR;
BEGIN
 IF GetBootVol(vol, fat) THEN
  Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
  Texts.Scan(s);
  IF s.class IN {Texts.Name, Texts.String} THEN
    (* write configuration to a text *)
   WriteBootVol(vol, fat);
   Params;
   NEW(t);  Texts.Open(t, "");
   Texts.Append(t, w.buf);
    (* convert it to a text file *)
   Str(s.s);
   f := Files.New(s.s);
   IF f # NIL THEN
    Files.Set(r, f, 0);
    WriteString(r, "# Configuration generated by Oberon-0");  WriteLn(r);
    Texts.OpenReader(s, t, 0);  quote := FALSE;
    LOOP
     Texts.Read(s, ch);
     IF s.eot THEN EXIT END;
     Files.Write(r, ch);
     IF ch = 0DX THEN Files.Write(r, 0AX)
     ELSIF ch = 22X THEN
      quote := ~quote;
      IF ~quote THEN WriteLn(r) END
     END
    END;
    Files.Register(f)
   ELSE
    Str(" not")
   END;
   Str(" written");  Ln;
   Texts.Append(Oberon.Log, w.buf)
  END
 END
END Generate;

PROCEDURE Manual*; (** on | off *)
VAR s: ARRAY 2 OF CHAR;
BEGIN
 GetBoolean("Manual", s);
 manual := s = "1";
 IF manual THEN
  Str("Execute blue commands in log");
  Ln;  Texts.Append(Oberon.Log, w.buf)
 END
END Manual;

PROCEDURE Oberon0*; (** on | off *)
VAR s: ARRAY 2 OF CHAR;
BEGIN
 GetBoolean("Oberon0", s);
 oberon0 := s = "1"
END Oberon0;

PROCEDURE Special*; (** "Lab" | "Normal" *)
VAR s: Texts.Scanner;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF s.class = Texts.Name THEN
  CASE CAP(s.s[0]) OF
   "L": install := LabMode
   ELSE install := NormalMode
  END
 END;
 CASE install  OF
  NormalMode: Str("Normal mode")
  |LabMode: Str("Lab mode")
 END;
 Ln; Texts.Append(Oberon.Log, w.buf)
END Special;

PROCEDURE Init*;
BEGIN
 Texts.OpenWriter(w);  Texts.OpenWriter(w2);  SetColor(Normal);
 NEW(config);  Texts.Open(config, ConfigText);
 manual := FALSE;  diskset := FALSE;  install := NormalMode; oberon0 := FALSE;
  (* defaults *)
 fontConv := "";  cache := "";  numLock := "";
 dma := "14800H"; (* reserve 82k for soundblaster, floppy needs 4800H *)
 Kernel.GetConfig("Color", color);
 Kernel.GetConfig("Keyboard", keyboard);
 display := " Display='VGA.' Init='b81200cd10'"
END Init;

BEGIN
 Init
END Config.

Install.Tool

DEVICE Keyboard "United States"
DEVICE Keyboard "United Kingdom" KeyUK.Bin
DEVICE Keyboard "Swiss German" KeyCH.Bin
DEVICE Keyboard "German" KeyD.Bin
DEVICE Keyboard "Canadian" KeyCA.Bin
DEVICE Keyboard "Norwegian" KeyN.Bin
DEVICE Keyboard "Turkish" KeyTR.Bin
DEVICE Keyboard "Polish" KeyPL.Bin
DEVICE Keyboard "Dvorak" KeyDV.Bin
DEVICE Keyboard "French" KeyFR.Bin
DEVICE Keyboard "Belgian" KeyBE.Bin
DEVICE Keyboard "Finnish" KeySF.Bin

Config.Manual on
Config.FAT
Config.EscNeutralize on
Config.FontConversion off
Config.DMABuffer 14800H
Config.Partition ^

Config.BootDiskette
Config.BootPartition
Config.Generate native.par ~

Config.Options Disk
Config.Options Keyboard
Config.Options Display

Config.DetectVesa (this command might hang some systems!)
