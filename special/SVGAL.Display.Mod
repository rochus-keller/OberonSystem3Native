(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Display; (* pjm *)

(* Native Oberon VESA display driver, pr 11.1.2000
    based on SVGA driver by pjm and PDR

     - only supports cards with linear framebuffer
     - supports adjustment of vertical refresh frequency (iff VESA version >= 3.0)
     
     in the boot environment set the following variables:
     DWidth=x  ; mandatory, horizontal number of pixels (eg. DWidth="1024")
     DHeight=y  ; mandatory, vertical number of pixels (eg. DHeight="768")
     DDepth=d  ; mandatory, pixel depth (8, 16, 32) (eg. DDepth="32")
     DVFreq=h  ; optional, the desired vertical refresh rate (eg. DVFreq="75")
           be careful: a too high refresh rate may damage your screen
     DMem=m  ; optional, size of video memory in kilo bytes (for 32 MB eg. DMem="8000H")
     PageHeap=p ; optional, on a corresponding error message  (eg. "PageHeap=64")
     
     do not set the following variables:
     MapVesa
     Init
*)

IMPORT SYSTEM, Objects, Kernel, DisplayTool;

CONST
 BG* = 0; FG* = 15;
 
 replace* = 0; (** replace destination. *)
 paint* = 1; (** paint over destination.  *)
 invert* = 2; (** invert destination. *)
 
 remove* = 0; suspend* = 1; restore* = 2; newprinter* = 3; (** ControlMsg id. *)
 reduce* = 0; extend* = 1; move* = 2; (** ModifyMsg id. *)
 display* = 0; state* = 1; (** ModifyMsg mode. *)
 screen* = 0; printer* = 1; (** DisplayMsg device *)
 full* = 0; area* = 1; contents* = 2; (** DisplayMsg id. *)
 get* = 0; set* = 1; reset* = 2; (** SelectMsg id. *)
 drop* = 0; integrate* = 1; (** ConsumeMsg id. *)
 
 unknown* = 0; index8* = 8; color555* = 16; color565* = 17; color664* = 18; color888* = 24; color8888* = 32;
 
TYPE
 Color* = LONGINT;
 
 Pattern* = LONGINT;
 PatternPtr = POINTER TO RECORD
  w, h: CHAR;
  pixmap: ARRAY 8192 OF CHAR
 END;
 List = POINTER TO ListDesc;
 ListDesc = RECORD
  next: List;
  pat: PatternPtr
 END;

 Frame* = POINTER TO FrameDesc; (** Base type of all displayable objects. *)
 FrameDesc* = RECORD (Objects.ObjDesc)
  next*, dsc*: Frame; (** Sibling, child pointers. *)
  X*, Y*, W*, H*: INTEGER (** Coordinates. *)
 END;

 FrameMsg* = RECORD (Objects.ObjMsg) (** Base type of messages sent to frames. *)
  F*: Frame; (*target*) (** Message target, NIL for broadcast. *)
  x*, y*: INTEGER; (** Message origin. *)
  res*: INTEGER (** Result code: <0 = error or no response, >=0 response. *)
 END;

 ControlMsg* = RECORD (FrameMsg)
  id*: INTEGER (** remove, suspend, restore. *)
 END;

 ModifyMsg* = RECORD (FrameMsg) (** Change coordinates in container frame. *)
  id*: INTEGER; (** reduce, extend, move. *)
  mode*: INTEGER; (** Modes display, state. *)
  dX*, dY*, dW*, dH*: INTEGER; (** Change from old coordinates (delta). *)
  X*, Y*, W*, H*: INTEGER (** New coordinates. *)
 END;

 DisplayMsg* = RECORD (FrameMsg) (** Display a frame, a part of it or its contents. *)
  device*: INTEGER; (** screen, printer *)
  id*: INTEGER; (** full, area, contents. *)
  u*, v*, w*, h*: INTEGER (** Area to be restored. *)
 END;

 LocateMsg* = RECORD (FrameMsg) (** Locate frame in display space. *)
  loc*: Frame; (** Result. *)
  X*, Y*: INTEGER; (** Absolute location. *)
  u*, v*: INTEGER (** Relative coordinates in loc. *)
 END;

 SelectMsg* = RECORD (FrameMsg) (** Selection control. *)
  id*: INTEGER; (** get, set, reset. *)
  time*: LONGINT; (** Time of selection. *)
  sel*: Frame; (** Parent of selection. *)
  obj*: Objects.Object (** List of objects involved, linked with slink. *)
 END;

 ConsumeMsg* = RECORD (FrameMsg) (** Drop, integrate frames. *)
  id*: INTEGER; (** drop, integrate. *)
  u*, v*: INTEGER; (** Relative coordinates in destination when drop. *)
  obj*: Objects.Object (** List of objects to be consumed, linked with slink. *)
 END;

 MsgProc* = PROCEDURE (VAR M: FrameMsg);

VAR
 Unit*: LONGINT; (** RasterUnit = Unit/36000 mm *)
 
 Left*, (** Left margin of black-and-white screen. *)
 ColLeft*, (** Left margin of secondary display, often same as Left. *)
 Bottom*, (** Bottom of primary map. *)
 UBottom*, (** Bottom of offscreen area (negative), 0 if not supported. *)
 Width*, (** Display width. *)
 Height*: INTEGER; (** Display height. *)
 arrow*,  (** Oberon cursor. *)
 star*,  (** Star marker to mark documents and viewers. *)
 cross*,  (** Insertion marker. *)
 downArrow*,  (** Marker to indicate disk operation. *)
 hook*, (** Text caret pattern. *)
 grey0*, grey1*, grey2*, ticks*, solid*: Pattern; (** Simulated grey levels. *)
 Broadcast*: MsgProc; (** Message broadcast to all frames in the display space. *)
 
 palette: ARRAY 256 OF LONGINT;
 depth: LONGINT;
 displayWidth, displayHeight, displayHeight1, displayDepth, displayVFreq: LONGINT;
 clipX1, clipY1, clipX2, clipY2: LONGINT; (* bottom left corner & top right corner, in Oberon coordinates *)
 pattern: List;

 (*PDR:*)
 VesaAdr: LONGINT;   (* virtual address for linear frame buffer *)
 truecol: LONGINT;
 colmap: ARRAY 256 OF LONGINT; (* identity mapping (256-color) or soft palette (hicolor, truecolor) *)
 bytesPerScan, bytesPerPixel: LONGINT;

(*PDR:*)
PROCEDURE SetColor*(col: Color; red, green, blue: LONGINT); (* 0 <= col, red, green, blue < 256 *)
VAR ch: CHAR; val: LONGINT;
BEGIN
 palette[col] := ASH(ASH(red, 8) + green, 8) + blue;
 CASE truecol OF
  0: (* indexed *)
   val := col MOD 100H;
   colmap[col] := ASH(val, 24) + ASH(val, 16) + ASH(val, 8) + val;
   IF (col = 0) OR (col = 15) THEN (* either 0 or 15 must be black.  set the border to black. *)
     (* note: the S3 uses the palette for the border colour too *)
    SYSTEM.PORTIN(3DAH, ch);
    SYSTEM.PORTOUT(3C0H, 11X);
    IF (red = 0) & (green = 0) & (blue = 0) THEN SYSTEM.PORTOUT(3C0H, CHR(col))
    ELSE SYSTEM.PORTOUT(3C0H, CHR(15-col))
    END;
    SYSTEM.PORTOUT(3C0H, 20X)
   END;
   SYSTEM.PORTOUT(3C8H, CHR(col));
   SYSTEM.PORTOUT(3C9H, CHR(red DIV 4));
   SYSTEM.PORTOUT(3C9H, CHR(green DIV 4));
   SYSTEM.PORTOUT(3C9H, CHR(blue DIV 4))
  |1: (* 565 hicolor *)
   val := ASH(ASH(ASH(red, -3), 6) + ASH(green, -2), 5) + ASH(blue, -3);
   colmap[col] := ASH(val, 16) + val
  |2: (* 888 truecolor *)
   colmap[col] := ASH(ASH(red, 8) + green, 8) + blue
 END
END SetColor;

(** Retrieve color palette entry or color components. 0 <= red, green, blue < 256. *)
PROCEDURE GetColor*(col: Color; VAR red, green, blue: INTEGER);
BEGIN
 IF col >= 0 THEN col := palette[col] END;
 red := SHORT(ASH(col, -16) MOD 256);
 green := SHORT(ASH(col, -8) MOD 256);
 blue := SHORT(col MOD 256)
END GetColor;

(** Return color with specified components. 0 <= red, green, blue < 256. *)
PROCEDURE RGB*(red, green, blue: LONGINT): Color;
BEGIN
 RETURN MIN(LONGINT) + ASH(red, 16) + ASH(green, 8) + blue
END RGB;

(** Returns the number of bits per pixel for the given x coordinate. Typical values are 1, 4, 8, 24. *)
PROCEDURE Depth*(x: LONGINT): INTEGER;
BEGIN
 RETURN SHORT(depth)
END Depth;

PROCEDURE TrueColor*(x: LONGINT): BOOLEAN;
BEGIN
 RETURN truecol > 0
END TrueColor;

(** Get the current clip rectangle. *)
PROCEDURE GetClip*(VAR x, y, w, h: INTEGER);
BEGIN
 x := SHORT(clipX1);  y := SHORT(clipY1);
 w := SHORT(clipX2-clipX1+1);  h := SHORT(clipY2-clipY1+1)
END GetClip;

(** Set the new clipping rectangle. *)
PROCEDURE SetClip*(x, y, w, h: LONGINT);
BEGIN
 clipX1 := x;  clipY1 := y;
 clipX2 := clipX1+w-1;  clipY2 := clipY1+h-1
END SetClip;
 
(** Intersect with current clip rectangle resulting in a new clip rectangle. *)
PROCEDURE AdjustClip*(x, y, w, h: LONGINT);
VAR x2, y2: LONGINT;
BEGIN
 x2 := x + w - 1;  y2 := y + h - 1;
 IF x > clipX1 THEN clipX1 := x END;
 IF y > clipY1 THEN clipY1 := y END;
 IF x2 < clipX2 THEN clipX2 := x2 END;
 IF y2 < clipY2 THEN clipY2 := y2 END
END AdjustClip;

(** Reset the current clipping rectangle to the whole display, including offscreen area. *)
PROCEDURE ResetClip*;
BEGIN
 clipX1 := 0;  clipY1 := UBottom;
 clipX2 := displayWidth-1;  clipY2 := displayHeight-1;
END ResetClip;
 
(*PDR:
 Translate a Color value 

 col >= 0 => index through colmap
 col < 0 & truecol = 0 => undefined
 col < 0 & truecol = 1 => translate 888 to 565
 col < 0 & truecol = 2 => keep lower 24 bits
 
 Note: when mode = invert & truecol # 0 & col = FG, the caller sets col to 80FFFFFFH.
 This is a special case for backward compatability with older viewers to invert using FG.
*)

PROCEDURE -TransColor(col: Color): LONGINT;
CODE {SYSTEM.i386}
 POP EAX
 CMP EAX, 0
 JGE index
 AND EAX, 0FFFFFFH
 CMP truecol, 1
 JNE end
 MOV EBX, EAX
 MOV ECX, EAX
 SHR EAX, 8 ; 23..19 -> 15..11
 SHR EBX, 5 ; 15..10 -> 10..5
 SHR ECX, 3 ; 7..3 -> 4..0
 AND EAX, 0F800H ; 15..11
 AND EBX, 007E0H ; 10..5
 AND ECX, 0001FH ; 4..0
 OR EAX, EBX
 OR EAX, ECX
 MOV EBX, EAX ; 31..16 := 15..0
 SHL EBX, 16
 OR EAX, EBX
 JMP end
index:
 AND EAX, 0FFH
 LEA EBX, colmap
 MOV EAX, [EBX][EAX*4]
end:
END TransColor;
 
PROCEDURE CopyBlock0(src, dst, h, w, lineInc, dir: LONGINT);
CODE {SYSTEM.i386}
 MOV EAX, w[EBP]
 MOV ESI, src[EBP]
 MOV EDI, dst[EBP]
 MOV EDX, h[EBP]
 MOV EBX, lineInc[EBP]
 
 TEST dir[EBP], 1
 JZ moveRight
 STD
 JMP copyLine
moveRight:
 CLD

copyLine:
 MOV ECX, EAX
 SHR ECX, 2 ; size DIV 4
 REP MOVSD

 TEST dir[EBP], 1
 JZ copyRest
 ADD EDI, 3
 ADD ESI, 3

copyRest:
 MOV ECX, EAX
 AND ECX, 3
 REP MOVSB
 
 ADD ESI, EBX
 ADD EDI, EBX
 DEC EDX
 JNZ copyLine
exit: 
END CopyBlock0; 

(** Copy source block sx, sy, w, h to destination dx, dy using operation mode. A block is given by its lower 
left corner sx, sy and its dimension w, h. Some drivers only implement mode = replace. *)
PROCEDURE CopyBlock*(sx, sy, w, h, dx, dy, mode: LONGINT);
VAR w0, h0, dx0, dy0, src, dst: LONGINT;
BEGIN (* only the destination block is clipped *)
 w0 := w;  h0 := h;  dx0 := dx;  dy0 := dy;
 IF dx < clipX1 THEN dx := clipX1;  DEC(w, dx-dx0) END;
 IF dy < clipY1 THEN dy := clipY1;  DEC(h, dy-dy0) END;
 IF (w > 0) & (h > 0) & (w <= w0) & (h <= h0) THEN
  IF dx+w-1 > clipX2 THEN DEC(w, dx+w-1 - clipX2) END;
  IF dy+h-1 > clipY2 THEN DEC(h, dy+h-1 - clipY2) END;
  IF (w > 0) & (h > 0) & (w <= w0) & (h <= h0) THEN
   sy := displayHeight-sy-h;  dy := displayHeight-dy-h; (* convert to hardware coordinates *)
   IF sy < dy THEN
    IF sx < dx THEN (* start at bottom right *)
     src := (sy+h-1)*bytesPerScan + (sx+w) * bytesPerPixel + VesaAdr-4;
     dst := (dy+h-1)*bytesPerScan + (dx+w) * bytesPerPixel + VesaAdr-4;
     CopyBlock0(src, dst, h, w*bytesPerPixel, w*bytesPerPixel-bytesPerScan-3, 1)
    ELSE (* start at bottom left *)
     src := (sy+h-1)*bytesPerScan + sx * bytesPerPixel + VesaAdr;
     dst := (dy+h-1)*bytesPerScan + dx * bytesPerPixel + VesaAdr;
     CopyBlock0(src, dst, h, w*bytesPerPixel, -w*bytesPerPixel-bytesPerScan, 0)
    END
   ELSE
    IF sx < dx THEN (* start at top right *)
     src := sy*bytesPerScan + (sx+w) * bytesPerPixel + VesaAdr - 4;
     dst := dy*bytesPerScan + (dx+w) * bytesPerPixel + VesaAdr - 4;
     CopyBlock0(src, dst, h, w*bytesPerPixel, w*bytesPerPixel+bytesPerScan-3, 1)
    ELSE (* start at top left *)
     src := sy*bytesPerScan + sx * bytesPerPixel + VesaAdr;
     dst := dy*bytesPerScan + dx * bytesPerPixel + VesaAdr;
     CopyBlock0(src, dst, h, w*bytesPerPixel, -w*bytesPerPixel+bytesPerScan, 0)
    END
   END
  END
 END
END CopyBlock;

(* CopyPattern0 - Copy pixels from src to dst, with no clipping.  ofs is the pixel offset to start at (max 7).  src is the 
pattern source address.  dst is the screen destination address.  w is the number of pixels to copy (max pat.w).  
col & mode are the colour and mode respectively. *)

PROCEDURE CopyPattern0(ofs, src, dst, w, cols, mode: LONGINT);
VAR ch: CHAR;  m, i: LONGINT;  s: SET; bg: LONGINT;
BEGIN
 REPEAT (* loop over w pixels *)
  SYSTEM.GET(src, ch);
  i := ofs; (* start bit *)
  m := 8; (* stop bit *)
  IF m > ofs+w THEN m := ofs+w END;
  REPEAT (* loop over bits *)
   (*ASSERT((base # 0A0000H) OR (dst >= 0A0000H) & (dst < 0B0000H));*)
   IF ODD(ASH(ORD(ch), -i)) THEN (* pixel on *)
    (*PR:*)
    IF mode = invert THEN
     CASE truecol OF
     | 0: SYSTEM.GET(dst, SYSTEM.VAL(CHAR, s));
      SYSTEM.PUT(dst, SYSTEM.VAL(CHAR, SYSTEM.VAL(SET, cols) / s))
     | 1: SYSTEM.GET(dst, SYSTEM.VAL(INTEGER, s));
      SYSTEM.PUT(dst, SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, cols) / s))
     | 2: SYSTEM.GET(dst, s);
      SYSTEM.PUT(dst, SYSTEM.VAL(SET, cols) / s)
     END
    ELSE (* paint & replace *)
     CASE truecol OF
     | 0: SYSTEM.PUT(dst, CHR(cols))
     | 1: SYSTEM.PUT(dst, SHORT(cols))
     | 2: SYSTEM.PUT(dst, cols)
     END
    END
   ELSIF mode = replace THEN (* pixel off *)
    bg := TransColor(BG);
    CASE truecol OF
    | 0: SYSTEM.PUT(dst, CHR(bg))
    | 1: SYSTEM.PUT(dst, SHORT(bg))
    | 2: SYSTEM.PUT(dst, bg)
    END
   ELSE (* skip *)
   END;
   INC(dst, bytesPerPixel);  INC(i)
  UNTIL i = m;
  INC(src);  DEC(w, m-ofs);  ofs := 0
 UNTIL w = 0
END CopyPattern0;

(* CopyPattern1 - Copy pixels from src (x,y), with full clipping.  Slower version of CopyPattern0, with individual clipping
of every pixel.  ofs is always 0.  (x,y) is the screen destination. *)

PROCEDURE CopyPattern1(src, x, y, w, col, mode: LONGINT);
VAR ch: CHAR;  m, i: LONGINT;
BEGIN
 REPEAT (* loop over w pixels *)
  SYSTEM.GET(src, ch);
  i := 0; (* start bit *)
  m := 8; (* stop bit *)
  IF m > w THEN m := w END;
  REPEAT (* loop over bits *)
   IF ODD(ASH(ORD(ch), -i)) THEN (* pixel on *)
    Dot(SHORT(col), SHORT(x), SHORT(y), SHORT(mode))
   ELSIF mode = replace THEN (* pixel off *)
    Dot(BG, SHORT(x), SHORT(y), replace)
   ELSE (* skip *)
   END;
   INC(x);  INC(i)
  UNTIL i = m;
  INC(src);  DEC(w, m)
 UNTIL w = 0
END CopyPattern1;

(** Copy pattern pat in color col to x, y using operation mode. *)
PROCEDURE CopyPattern*(col: Color; pat: Pattern; x, y, mode: LONGINT);
VAR cols, x2, y2, w, w0, h, src, dst: LONGINT;  ch: CHAR;
BEGIN
 (*PDR:*)
 IF (mode = invert) & (truecol # 0) & (col = FG) THEN col := 80FFFFFFH END;
 (*PR:*)
 cols := TransColor(col);
 SYSTEM.GET(pat, ch);  w := ORD(ch);
 SYSTEM.GET(pat+1, ch);  h := ORD(ch);
 IF (w > 0) & (h > 0) THEN
  x2 := x+w-1;  y2 := y+h-1; (* (x,y) bottom left & (x2,y2) top right *)
  IF (x >= clipX1) & (y >= clipY1) & (x2 <= clipX2) & (y2 <= clipY2) THEN (* fully visible - common case *)
   w0 := (w+7) DIV 8; (* bytes in pattern line *)
   src := pat+2 + (h-1)*w0; (* last line of pattern *)
   y := displayHeight-y-h; (* convert to screen coordinate *)
   dst := y * bytesPerScan + x*bytesPerPixel;
   INC(dst, VesaAdr);
   REPEAT
    CopyPattern0(0, src, dst, w, cols, mode);
    DEC(h);  INC(dst, bytesPerScan);  DEC(src, w0)
   UNTIL h = 0
  ELSIF (x2 >= clipX1) & (y2 >= clipY1) & (x <= clipX2) & (y <= clipY2) THEN (* partially visible *)
   w0 := (w+7) DIV 8; (* bytes in pattern line *)
   src := pat+2; (* last line of pattern *)
   REPEAT (* loop over h lines *)
    CopyPattern1(src, x, y, w, col, mode);
    INC(y);  INC(src, w0);  DEC(h)
   UNTIL h = 0
  ELSE (* invisible *)
  END
 END
END CopyPattern;

(* FillPattern0 - Copy pixels from src to dst, with no clipping, with wraparound in the source.  ofs is the pixel offset to 
start at.  src is the pattern source address.  dst is the screen destination address.  w is the number of pixels to copy.  
pw is the pattern width.  col & mode are the colour and mode respectively. *)

PROCEDURE FillPattern0(ofs, src, dst, w, pw, cols, mode: LONGINT);
VAR ch: CHAR;  m, i, src0, left: LONGINT;  s: SET; bg: LONGINT;
BEGIN
 left := pw-ofs; (* pixels left to do in pattern *)
 src0 := src;  INC(src, ofs DIV 8);  ofs := ofs MOD 8; (* start position *)
 REPEAT (* loop over w pixels *)
  SYSTEM.GET(src, ch);
  i := ofs; (* start bit *)
  m := 8; (* stop bit *)
  IF m > ofs+left THEN m := ofs+left END; (* max left times *)
  IF m > ofs+w THEN m := ofs+w END; (* max w times *)
  REPEAT (* loop over bits *)
   (*ASSERT((base # 0A0000H) OR (dst >= 0A0000H) & (dst < 0B0000H));*)
   (*PDR:*)
   IF ODD(ASH(ORD(ch), -i)) THEN (* pixel on *)
    (*PR:*)
    IF mode = invert THEN
     CASE truecol OF
     | 0: SYSTEM.GET(dst, SYSTEM.VAL(CHAR, s));
      SYSTEM.PUT(dst, SYSTEM.VAL(CHAR, SYSTEM.VAL(SET, cols) / s))
     | 1: SYSTEM.GET(dst, SYSTEM.VAL(INTEGER, s));
      SYSTEM.PUT(dst, SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, cols) / s))
     | 2: SYSTEM.GET(dst, s);
      SYSTEM.PUT(dst, SYSTEM.VAL(SET, cols) / s)
     END
    ELSE (* paint & replace *)
     CASE truecol OF
     | 0: SYSTEM.PUT(dst, CHR(cols))
     | 1: SYSTEM.PUT(dst, SHORT(cols))
     | 2: SYSTEM.PUT(dst, cols)
     END
    END
   ELSIF mode = replace THEN (* pixel off *)
    bg := TransColor(BG);
    CASE truecol OF
    | 0: SYSTEM.PUT(dst, CHR(bg))
    | 1: SYSTEM.PUT(dst, SHORT(bg))
    | 2: SYSTEM.PUT(dst, bg)
    END
   ELSE (* skip *)
   END;
   INC(dst, bytesPerPixel);  INC(i)
  UNTIL i = m;
  INC(src);  DEC(left, m-ofs);  DEC(w, m-ofs);  ofs := 0;
  IF left = 0 THEN src := src0;  left := pw END (* wrap to start of pattern *)
 UNTIL w = 0
END FillPattern0;

(** Replicate pattern pat in color col into block x, y, w, h using operation mode, proceeding from left to right and from bottom to top, starting at lower left corner. The pattern origin is placed at px, py. *)
PROCEDURE FillPattern*(col: Color; pat: Pattern; px, py, x, y, w, h, mode: LONGINT);
VAR cols, pw, ph, x2, y2, w0, src0, src, dst: LONGINT;  ch: CHAR;
BEGIN
 (*PDR:*)
 IF (mode = invert) & (truecol # 0) & (col = FG) THEN col := 80FFFFFFH END;
 (*PR:*)
 cols := TransColor(col);
 x2 := x+w-1;  y2 := y+h-1; (* (x,y) bottom left & (x2,y2) top right *)
 IF x < clipX1 THEN DEC(w, clipX1-x);  x := clipX1
 ELSIF x > clipX2 THEN DEC(w, x-clipX2);  x := clipX2
 END;
 IF y < clipY1 THEN DEC(h, clipY1-y);  y := clipY1
 ELSIF y > clipY2 THEN DEC(h, y-clipY2);  y := clipY2
 END;
 IF x2 < clipX1 THEN DEC(w, clipX1-x2)
 ELSIF x2 > clipX2 THEN DEC(w, x2-clipX2)
 END;
 IF y2 < clipY1 THEN DEC(h, clipY1-y2)
 ELSIF y2 > clipY2 THEN DEC(h, y2-clipY2)
 END;
 IF (w > 0) & (h > 0) THEN
  SYSTEM.GET(pat, ch);  pw := ORD(ch);
  SYSTEM.GET(pat+1, ch);  ph := ORD(ch);
  IF (pw > 0) & (ph > 0) THEN
   INC(pat, 2); (* adr of bitmap *)
   w0 := (pw+7) DIV 8; (* bytes in pattern line *)
   src0 := pat + (ph-1)*w0; (* last line of pattern *)
   src := pat + (h-1 + y-py) MOD ph * w0; (* start line of pattern *)
   px := (x - px) MOD pw; (* start pixel offset *)
   y := displayHeight-y-h; (* convert to screen coordinate *)
   dst := y * bytesPerScan + x * bytesPerPixel;
   INC(dst, VesaAdr);
   REPEAT (* loop over h lines *)
    FillPattern0(px, src, dst, w, pw, cols, mode);
    DEC(h);  INC(dst, bytesPerScan);
    IF src = pat THEN src := src0 ELSE DEC(src, w0) END
   UNTIL h = 0
  END
 END
END FillPattern;

(** Like FillPattern, but the pattern origin is placed at 0, 0. *)
PROCEDURE ReplPattern*(col: Color; pat: Pattern; x, y, w, h, mode: LONGINT);
BEGIN
 FillPattern(col, pat, 0, 0, x, y, w, h, mode)
END ReplPattern;

(* ReplConst0 - Replicate a constant in a line in replace mode. *)

(*PR:*)
PROCEDURE ReplConst0(dst, w, cols: LONGINT);
BEGIN
 (*ASSERT((base # 0A0000H) OR (dst >= 0A0000H) & (dst < 0B0000H));
 ASSERT((w >= 0) & (w <= displayWidth));*)
 w := w*bytesPerPixel;
 IF (dst MOD 2 # 0) & (w # 0) THEN
  ASSERT(truecol = 0, 99);
  SYSTEM.PUT(dst, CHR(cols));
  INC(dst);  DEC(w)
 END;
 IF (dst MOD 4 # 0) & (w >= 2) THEN
  ASSERT(truecol <= 1, 98);
  SYSTEM.PUT(dst, SHORT(cols));
  INC(dst, 2);  DEC(w, 2)
 END;
 WHILE w >= 4 DO
  SYSTEM.PUT(dst, cols);
  INC(dst, 4);  DEC(w, 4)
 END;
 IF w >= 2 THEN
  ASSERT(truecol <= 1, 97);
  SYSTEM.PUT(dst, SHORT(cols));
  INC(dst, 2); DEC(w, 2)
 END;
 IF w # 0 THEN ASSERT(truecol = 0, 96); SYSTEM.PUT(dst, CHR(cols)) END;
END ReplConst0;

(* ReplConst2 - Replicate a constant in a line in invert mode. *)

PROCEDURE ReplConst2(dst, w, cols: LONGINT);
VAR s: SET;
BEGIN
 (*ASSERT((base # 0A0000H) OR (dst >= 0A0000H) & (dst < 0B0000H));
 ASSERT((w >= 0) & (w <= displayWidth));*)
 (*PR:*)
 w := w*bytesPerPixel;
 IF (dst MOD 2 # 0) & (w # 0) THEN
  ASSERT(truecol = 0, 99);
  SYSTEM.GET(dst, SYSTEM.VAL(CHAR, s));
  SYSTEM.PUT(dst, SYSTEM.VAL(CHAR, s / SYSTEM.VAL(SET, cols)));
  INC(dst);  DEC(w)
 END;
 IF (dst MOD 4 # 0) & (w >= 2) THEN
  ASSERT(truecol <= 1, 98);
  SYSTEM.GET(dst, SYSTEM.VAL(INTEGER, s));
  SYSTEM.PUT(dst, SYSTEM.VAL(INTEGER, s / SYSTEM.VAL(SET, cols)));
  INC(dst, 2);  DEC(w, 2)
 END;
 WHILE w >= 4 DO
  SYSTEM.GET(dst, s);
  SYSTEM.PUT(dst, s / SYSTEM.VAL(SET, cols));
  INC(dst, 4);  DEC(w, 4)
 END;
 IF w >= 2 THEN
  ASSERT(truecol <= 1, 97);
  SYSTEM.GET(dst, SYSTEM.VAL(INTEGER, s));
  SYSTEM.PUT(dst, SYSTEM.VAL(INTEGER, s / SYSTEM.VAL(SET, cols)));
  INC(dst, 2); DEC(w, 2)
 END;
 IF w # 0 THEN
  ASSERT(truecol = 0, 96);
  SYSTEM.GET(dst, SYSTEM.VAL(CHAR, s));
  SYSTEM.PUT(dst, SYSTEM.VAL(CHAR, s / SYSTEM.VAL(SET, cols)));
 END;
END ReplConst2;

(** Block fill in color col and operation mode.  mode paint and replace are equivalent. *)
PROCEDURE ReplConst*(col: Color; x, y, w, h, mode: LONGINT);
VAR cols, dst, x2, y2: LONGINT;
BEGIN
 x2 := x+w-1;  y2 := y+h-1; (* (x2,y2) is top right corner *)
 (*PR:*)
 IF (mode = invert) & (truecol # 0) & (col = FG) THEN col := 80FFFFFFH END;
 cols := TransColor(col);
 IF x < clipX1 THEN DEC(w, clipX1-x);  x := clipX1
 ELSIF x > clipX2 THEN DEC(w, x-clipX2);  x := clipX2
 END;
 IF y < clipY1 THEN DEC(h, clipY1-y);  y := clipY1
 ELSIF y > clipY2 THEN DEC(h, y-clipY2);  y := clipY2
 END;
 IF x2 < clipX1 THEN DEC(w, clipX1-x2)
 ELSIF x2 > clipX2 THEN DEC(w, x2-clipX2)
 END;
 IF y2 < clipY1 THEN DEC(h, clipY1-y2)
 ELSIF y2 > clipY2 THEN DEC(h, y2-clipY2)
 END;
 IF (w > 0) & (h > 0) THEN
  y := displayHeight-y-h; (* convert to screen coordinate *)
  dst := y * bytesPerScan + x * bytesPerPixel;
  INC(dst, VesaAdr);
  REPEAT
   IF mode = invert THEN ReplConst2(dst, w, cols) ELSE ReplConst0(dst, w, cols) END;
   DEC(h);  INC(dst, bytesPerScan)
  UNTIL h = 0
 END
END ReplConst;

(** Place a dot of color col in operation mode at x, y. Effect equivalent to ReplConst with a block of size 1, 1. *)
PROCEDURE Dot*(col: Color; x, y, mode: LONGINT);
VAR cols, dst: LONGINT;  s: SET;
BEGIN
 (*PR:*)
 IF (mode = invert) & (truecol # 0) & (col = FG) THEN col := 80FFFFFFH END;
 cols := TransColor(col);
 IF (x >= clipX1) & (x <= clipX2) & (y >= clipY1) & (y <= clipY2) THEN
  dst := (displayHeight-1-y) * bytesPerScan + x * bytesPerPixel;
  INC(dst, VesaAdr);
  IF mode = invert THEN
   CASE truecol OF
   | 0: SYSTEM.GET(dst, SYSTEM.VAL(CHAR, s));
    SYSTEM.PUT(dst, SYSTEM.VAL(CHAR, SYSTEM.VAL(SET, col) / s))
   | 1: SYSTEM.GET(dst, SYSTEM.VAL(INTEGER, s));
    SYSTEM.PUT(dst, SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, cols) / s))
   | 2: SYSTEM.GET(dst, s);
    SYSTEM.PUT(dst, SYSTEM.VAL(SET, cols) / s)
   END
  ELSE (* paint & replace *)
   CASE truecol OF
   | 0: SYSTEM.PUT(dst, CHR(cols))
   | 1: SYSTEM.PUT(dst, SHORT(cols))
   | 2: SYSTEM.PUT(dst, cols)
   END
  END
 END
END Dot;

(** Returns the dimensions of a pattern. *)
PROCEDURE GetDim*(pat: Pattern; VAR w, h: INTEGER);
VAR ch: CHAR;
BEGIN
 SYSTEM.GET(pat, ch);  w := ORD(ch);
 SYSTEM.GET(pat+1, ch);  h := ORD(ch)
END GetDim;

(** Define a new pattern. *)
PROCEDURE NewPattern*(w, h: LONGINT; VAR image: ARRAY OF SET): Pattern;
VAR len, src, dest, i: LONGINT;  p: PatternPtr;  pl: List;
BEGIN
 len := (w+7) DIV 8;
 SYSTEM.NEW(p, 4+len*h);  p.w := CHR(w);  p.h := CHR(h);
 src := SYSTEM.ADR(image[0]);  dest := SYSTEM.ADR(p.pixmap[0]);
 i := 0;
 WHILE i < h DO SYSTEM.MOVE(src, dest, len);  INC(src, 4);  INC(dest, len);  INC(i) END;
 NEW(pl);  pl.pat := p;  pl.next := pattern;  pattern := pl; (* put in list to avoid GC *)
 RETURN SYSTEM.ADR(p.w)
END NewPattern;
 
(* Define standard patterns. *)
PROCEDURE CreatePatterns;
VAR image: ARRAY 16 OF SET;
BEGIN
 image[0] := {13};
 image[1] := {12..14};
 image[2] := {11..13};
 image[3] := {10..12};
 image[4] := {9..11};
 image[5] := {8..10};
 image[6] := {7..9};
 image[7] := {0, 6..8};
 image[8] := {0, 1, 5..7};
 image[9] := {0..2, 4..6};
 image[10] := {0..5};
 image[11] := {0..4};
 image[12] := {0..5};
 image[13] := {0..6};
 image[14] := {0..7};
 arrow := NewPattern(15, 15, image);
 
 image[0] := {0, 10};
 image[1] := {1, 9};
 image[2] := {2, 8};
 image[3] := {3, 7};
 image[4] := {4, 6};
 image[5] := {};
 image[6] := {4, 6};
 image[7] := {3, 7};
 image[8] := {2, 8};
 image[9] := {1, 9};
 image[10] := {0, 10};
 cross := NewPattern(11, 11, image); 
 
 image[0] := {6};
 image[1] := {5..7};
 image[2] := {4..8};
 image[3] := {3..9};
 image[4] := {2..10};
 image[5] := {5..7};
 image[6] := {5..7};
 image[7] := {5..7};
 image[8] := {5..7};
 image[9] := {5..7};
 image[10] := {5..7};
 image[11] := {5..7};
 image[12] := {5..7};
 image[13] := {5..7};
 image[14] := {};
 downArrow := NewPattern(11, 15, image);
 
 image[0] := {0, 4, 8, 12};
 image[1] := {};
 image[2] := {2, 6, 10, 14};
 image[3] := {};
 image[4] := {0, 4, 8, 12};
 image[5] := {};
 image[6] := {2, 6, 10, 14};
 image[7] := {};
 image[8] := {0, 4, 8, 12};
 image[9] := {};
 image[10] := {2, 6, 10, 14};
 image[11] := {};
 image[12] := {0, 4, 8, 12};
 image[13] := {};
 image[14] := {2, 6, 10, 14};
 image[15] := {};
 grey0 := NewPattern(16, 16, image);
 
 image[0] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[1] := {1, 3, 5, 7, 9, 11, 13, 15};
 image[2] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[3] := {1, 3, 5, 7, 9, 11, 13, 15};
 image[4] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[5] := {1, 3, 5, 7, 9, 11, 13, 15};
 image[6] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[7] := {1, 3, 5, 7, 9, 11, 13, 15};
 image[8] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[9] := {1, 3, 5, 7, 9, 11, 13, 15};
 image[10] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[11] := {1, 3, 5, 7, 9, 11, 13, 15};
 image[12] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[13] := {1, 3, 5, 7, 9, 11, 13, 15};
 image[14] := {0, 2, 4, 6, 8, 10, 12, 14};
 image[15] := {1, 3, 5, 7, 9, 11, 13, 15};
 grey1 := NewPattern(16, 16, image);
 
 image[0] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[1] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[2] := {2, 3, 6, 7, 10, 11, 14, 15};
 image[3] := {2, 3, 6, 7, 10, 11, 14, 15};
 image[4] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[5] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[6] := {2, 3, 6, 7, 10, 11, 14, 15};
 image[7] := {2, 3, 6, 7, 10, 11, 14, 15};
 image[8] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[9] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[10] := {2, 3, 6, 7, 10, 11, 14, 15};
 image[11] := {2, 3, 6, 7, 10, 11, 14, 15};
 image[12] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[13] := {0, 1, 4, 5, 8, 9, 12, 13};
 image[14] := {2, 3, 6, 7, 10, 11, 14, 15};
 image[15] := {2, 3, 6, 7, 10, 11, 14, 15};
 grey2 := NewPattern(16, 16, image);
 
 image[0] := {0..2, 8..11};
 image[1] := {0..2, 7..10};
 image[2] := {0..2, 6..9};
 image[3] := {0..2, 5..8};
 image[4] := {0..2, 4..7};
 image[5] := {0..6};
 image[6] := {0..5};
 image[7] := {0..4};
 image[8] := {0..3};
 image[9] := {0..2};
 image[10] := {0, 1};
 image[11] := {0};
 hook := NewPattern(12, 12, image);
 
 image[0] := {7};
 image[1] := {7};
 image[2] := {2, 7, 12};
 image[3] := {3, 7, 11};
 image[4] := {4, 7, 10};
 image[5] := {5, 7, 9};
 image[6] := {6..8};
 image[7] := {0..6, 8..14};
 image[8] := {6..8};
 image[9] := {5, 7, 9};
 image[10] := {4, 7, 10};
 image[11] := {3, 7, 11};
 image[12] := {2, 7, 12};
 image[13] := {7};
 image[14] := {7};
 star := NewPattern(15, 15, image);
 
 image[0] := {};
 image[1] := {};
 image[2] := {0};
 image[3] := {};
 image[4] := {};
 image[5] := {};
 image[6] := {};
 image[7] := {};
 image[8] := {};
 image[9] := {};
 image[10] := {};
 image[11] := {};
 image[12] := {};
 image[13] := {};
 image[14] := {};
 image[15] := {};
 ticks := NewPattern(16, 16, image);
 
 image[0] := -{};
 image[1] := -{};
 image[2] := -{};
 image[3] := -{};
 image[4] := -{};
 image[5] := -{};
 image[6] := -{};
 image[7] := -{};
 solid := NewPattern(16, 8, image)
END CreatePatterns;
 
(** Return the format of a display region, for TransferBlock. *)
PROCEDURE TransferFormat*(x: LONGINT): LONGINT;
BEGIN
 CASE truecol OF
  0: x := index8
  |1: x := color565
  |2: x := color8888
 END;
 RETURN x
END TransferFormat;

(** Transfer a block of pixels in display format to (mode = set) or from (mode = get)  the display.  Pixels in the rectangular area are transferred from bottom to top and left to right.  The pixels are transferred to or from buf, starting at ofs, and with line increment stride, which may be < 0. *)
PROCEDURE TransferBlock*(VAR buf: ARRAY OF CHAR;  ofs, stride, x, y, w, h, mode: LONGINT);
VAR src, dst: LONGINT;
BEGIN
 ASSERT(mode IN {set, get}, 99);
 ASSERT(x+w <= displayWidth, 100);
 ASSERT( y+h <= displayHeight, 101);
 src := SYSTEM.ADR(buf[0]) + ofs + (h-1)*stride;
 dst := (displayHeight-y-h)*bytesPerScan + x*bytesPerPixel;
 INC(dst, VesaAdr);
 REPEAT
  IF mode = set THEN SYSTEM.MOVE(src, dst, w*bytesPerPixel)
  ELSE SYSTEM.MOVE(dst, src, w*bytesPerPixel)
  END;
  DEC(h);  INC(dst, bytesPerScan); DEC(src, stride)
 UNTIL h = 0
END TransferBlock;

(** Change screen mode. *)
PROCEDURE SetMode*(x: LONGINT; s: SET);
BEGIN
END SetMode;

(* DisplayBlock0 - Display a line in replace mode. *)

PROCEDURE DisplayBlock0(src, dst, w: LONGINT);
VAR col: LONGINT;
BEGIN
 (*ASSERT((base # 0A0000H) OR (dst >= 0A0000H) & (dst < 0B0000H));
 ASSERT((w >= 0) & (w <= displayWidth));*)
 (*PR:*)
 WHILE w # 0 DO
  SYSTEM.GET(src, SYSTEM.VAL(CHAR, col));
  CASE truecol OF
  | 0: SYSTEM.PUT(dst, CHR(col)); INC(dst)
  | 1: SYSTEM.PUT(dst, SYSTEM.VAL(INTEGER, colmap[col])); INC(dst, 2)
  | 2: SYSTEM.PUT(dst, colmap[col]); INC(dst, 4)
  END;
  DEC(w); INC(src)
 END
END DisplayBlock0;

(* DisplayBlock2 - Display a line in invert mode. *)

PROCEDURE DisplayBlock2(src, dst, w: LONGINT);
VAR s: SET;  col: LONGINT;
BEGIN
 (*ASSERT((base # 0A0000H) OR (dst >= 0A0000H) & (dst < 0B0000H));
 ASSERT((w >= 0) & (w <= displayWidth));*)
 (*PR:*)
 WHILE w # 0 DO
  SYSTEM.GET(src, SYSTEM.VAL(CHAR, col));
  CASE truecol OF
  | 0: SYSTEM.GET(dst, SYSTEM.VAL(CHAR, s));
    SYSTEM.PUT(dst, SYSTEM.VAL(CHAR, s / SYSTEM.VAL(SET, colmap[col])));
    INC(dst)
  | 1: SYSTEM.GET(dst, SYSTEM.VAL(INTEGER, s));
    SYSTEM.PUT(dst, SYSTEM.VAL(INTEGER, s / SYSTEM.VAL(SET, colmap[col])));
    INC(dst, 2)
  | 2: SYSTEM.GET(dst, s);
    SYSTEM.PUT(dst, s / SYSTEM.VAL(SET, colmap[col]));
    INC(dst, 4)
  END;
  DEC(w); INC(src)
 END
END DisplayBlock2;

(** Display a picture.  Used internally by Pictures module only. *)
PROCEDURE DisplayBlock*(adr, dx, dy, w, h, sx, sy, mode: LONGINT);
VAR pw, pd, x, y, src, x2, y2, dst: LONGINT;
BEGIN
 x := sx;  y := sy;
 x2 := x+w-1;  y2 := y+h-1; (* (x2,y2) is top right corner *)
 IF x < clipX1 THEN DEC(w, clipX1-x);  INC(dx, clipX1-x);  x := clipX1
 ELSIF x > clipX2 THEN DEC(w, x-clipX2)
 END;
 IF y < clipY1 THEN DEC(h, clipY1-y);  INC(dy, clipY1-y);  y := clipY1
 ELSIF y > clipY2 THEN DEC(h, y-clipY2)
 END;
 IF x2 < clipX1 THEN DEC(w, clipX1-x2)
 ELSIF x2 > clipX2 THEN DEC(w, x2-clipX2)
 END;
 IF y2 < clipY1 THEN DEC(h, clipY1-y2)
 ELSIF y2 > clipY2 THEN DEC(h, y2-clipY2)
 END;
 IF (w > 0) & (h > 0) THEN
  pd := 0;  SYSTEM.GET(adr+4, SYSTEM.VAL(INTEGER, pd));
  IF pd = 8 THEN
   SYSTEM.GET(adr+8, pw);
   SYSTEM.GET(adr+12, src);
   INC(src, (dy+h-1)*pw + dx); (* top left corner *)
   y := displayHeight-y-h; (* convert to screen coordinate *)
   dst := y*bytesPerScan + x*bytesPerPixel;
   INC(dst, VesaAdr);
   REPEAT
    IF mode = invert THEN DisplayBlock2(src, dst, w) ELSE DisplayBlock0(src, dst, w) END;
    DEC(h);  DEC(src, pw);  INC(dst, bytesPerScan)
   UNTIL h = 0
  ELSE (* depth not supported *)
   ReplConst(3, sx, sy, w, h, mode)
  END
 END
END DisplayBlock;

(** Return address of display located at x, or 0 if not supported. *)
PROCEDURE Map*(x: LONGINT): LONGINT;
BEGIN
 RETURN VesaAdr
END Map;

(* StrToInt - Convert a string to an integer *)

PROCEDURE StrToInt(VAR i: LONGINT;  VAR s: ARRAY OF CHAR): LONGINT;
VAR vd, vh, sgn, d: LONGINT;  hex: BOOLEAN;
BEGIN
 vd := 0;  vh := 0;  hex := FALSE;
 IF s[i] = "-" THEN sgn := -1; INC(i) ELSE sgn := 1 END;
 LOOP
  IF (s[i] >= "0") & (s[i] <= "9") THEN d := ORD(s[i])-ORD("0")
  ELSIF (CAP(s[i]) >= "A") & (CAP(s[i]) <= "F") THEN d := ORD(CAP(s[i]))-ORD("A")+10; hex := TRUE
  ELSE EXIT
  END;
  vd := 10*vd + d;  vh := 16*vh + d;
  INC(i)
 END;
 IF CAP(s[i]) = "H" THEN hex := TRUE; INC(i) END; (* optional H *)
 IF hex THEN vd := vh END;
 RETURN sgn * vd
END StrToInt;

(* GetVal - Get config string and convert to integer. *)

PROCEDURE GetVal(name: ARRAY OF CHAR;  default: LONGINT): LONGINT;
VAR v: LONGINT;  s: ARRAY 10 OF CHAR;  p: LONGINT;
BEGIN
 Kernel.GetConfig(name, s);
 IF s[0] = 0X THEN v := default
 ELSE p := 0;  v := StrToInt(p, s)
 END;
 RETURN v
END GetVal;

(* MapFrameBuffer - Map linear frame buffer. *)

PROCEDURE MapFrameBuffer(modeNr: LONGINT; VAR memSize: LONGINT);
VAR physAdr, size: LONGINT;
BEGIN
 DisplayTool.GetFrameBuffer(modeNr, physAdr, size);
 memSize := GetVal("DMem", size DIV 1024) * 1024;
 Kernel.MapPhysical(physAdr, memSize, VesaAdr)
END MapFrameBuffer;

(* Init - Initialize the screen dimensions. *)

PROCEDURE Init;
VAR chipSet, mem, modeNr, res: LONGINT;
BEGIN
 Kernel.WriteString("SVGA: ");
 displayWidth := GetVal("DWidth", 1024); (* assume 1024 if not specified *)
 displayHeight := GetVal("DHeight", 768); (* assume 768 if not specified *)
 displayDepth := GetVal("DDepth", 8);  (* assume 8 if not specified *)
 displayVFreq := GetVal("DVFreq", 60);  (* assume 60 Hz if not specified *)
 modeNr := DisplayTool.SearchVideoMode(displayWidth, displayHeight, displayDepth);
 IF modeNr = 0 THEN modeNr := DisplayTool.SearchVideoMode(1024, 768, 8) END;
 IF modeNr = 0 THEN modeNr := DisplayTool.SearchVideoMode(640, 480, 8) END;
 IF modeNr = 0 THEN Kernel.WriteString("no video mode found"); HALT(99) END;
 MapFrameBuffer(modeNr, mem);
 Kernel.traceConsole := FALSE;
 DisplayTool.SetVideoMode(modeNr, displayVFreq, TRUE, TRUE, res); ASSERT(res=0, 100);

 (*PR:*)
 truecol := displayDepth DIV 16; (* 0, 1 or 2 *)
 bytesPerPixel := displayDepth DIV 8;
 bytesPerScan := displayWidth * bytesPerPixel;
 IF GetVal("Color", 1) = 0 THEN depth := 1 ELSE depth := 8 END;

 (*PDR:*)
 displayHeight1 := mem DIV bytesPerScan; (* maximum lines in display memory *)
 Kernel.WriteChar(" ");  Kernel.WriteInt(displayWidth, 1);
 Kernel.WriteChar("x");  Kernel.WriteInt(displayHeight, 1);
 Kernel.WriteChar("x");  Kernel.WriteInt(displayDepth, 1);
 Kernel.WriteChar("@");  Kernel.WriteInt(displayVFreq, 1);
 Kernel.WriteString(" Hz  (+");  Kernel.WriteInt(displayHeight1-displayHeight, 1);
 Kernel.WriteString(" lines offscreen)");
 Kernel.WriteLn
END Init;
 
BEGIN
 Init;
 Unit := 10000;
 Left := 0;  ColLeft := 0;
 Bottom := 0;  UBottom := SHORT(displayHeight-displayHeight1+1);
 Width := SHORT(displayWidth);  Height := SHORT(displayHeight);
 pattern := NIL;
 CreatePatterns;
 ResetClip
END Display.


Compiler.Compile SVGAL.Display.Mod\X ~

TestSVGA.Mod

System.CopyFiles Display.Obj => SVGALPR.Display.Obj ~
System.CopyFiles Display.Obj => TestDisplay.Obj ~
