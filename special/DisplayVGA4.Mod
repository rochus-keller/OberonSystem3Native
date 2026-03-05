(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

 MODULE DisplayVGA4; (* pjm *)

(*
16-color VGA display driver for Native Oberon with virtual truecolor.

Config strings:
 Display="Displays."
 DDriver="DisplayVGA4"
 Init="b81200cd10"
*)

IMPORT SYSTEM, Kernel, CLUTs, Displays;

CONST
 Width = 640; Height = 480;

VAR
 d: Display;
 base: LONGINT;
 clut: POINTER TO CLUTs.CLUT;
 pal: ARRAY 16 OF LONGINT;
 shadow: POINTER TO ARRAY OF CHAR;
 pelmask: LONGINT; (* trace *)

TYPE
 Display* = OBJECT (Displays.Display)
  
  PROCEDURE Transfer*(VAR buf: ARRAY OF CHAR;  ofs, stride, x, y, w, h, op: LONGINT);
  VAR bufadr, buflow, bufhigh, dispadr, scradr: LONGINT;
  BEGIN
   IF w > 0 THEN
    bufadr := SYSTEM.ADR(buf[ofs]);
    IF op = Displays.set THEN
     buflow := SYSTEM.ADR(shadow[0]); bufhigh := buflow + LEN(shadow^);
     dispadr := SYSTEM.ADR(shadow[0]) + ((y*Width)+x);
     scradr := base + (x DIV 8 + y*(Width DIV 8)) MOD 10000H;
     WHILE h > 0 DO
      ASSERT((dispadr >= buflow) & (dispadr+w <= bufhigh)); (* index check *)
      SYSTEM.MOVE(bufadr, dispadr, w);
      CopyLineTo(bufadr, scradr, x, w);
      INC(bufadr, stride); INC(dispadr, Width); INC(scradr, Width DIV 8);
      DEC(h)
     END
    ELSIF op = Displays.get THEN
     buflow := SYSTEM.ADR(buf[0]); bufhigh := buflow + LEN(buf);
     dispadr := SYSTEM.ADR(shadow[0]) + ((y*Width)+x);
     WHILE h > 0 DO
      ASSERT((bufadr >= buflow) & (bufadr+w <= bufhigh)); (* index check *)
      SYSTEM.MOVE(dispadr, bufadr, w);
      INC(bufadr, stride); INC(dispadr, Width);
      DEC(h)
     END
    ELSE (* skip *)
    END
   END
  END Transfer;
  
(*
  PROCEDURE Dot*(col, x, y: LONGINT);
  VAR ch: CHAR;
  BEGIN
   y := base + (x + y*Width) DIV 8 MOD 10000H;
   SYSTEM.PORTOUT(3CEH, SYSTEM.VAL(INTEGER, 8 + ASH(100H, 7-x MOD 8)));
   IF ASH(col, 1) >= 0 THEN (* replace *)
    SYSTEM.GET(y, ch);
    SYSTEM.PUT(y, CHR(CLUTs.Match(clut^, col)))
   ELSE (* invert *)
    SYSTEM.PORTOUT(3CEH, SYSTEM.VAL(INTEGER, 1803H));
    SYSTEM.GET(y, ch);
    SYSTEM.PUT(y, CHR(CLUTs.Match(clut^, col)));
    SYSTEM.PORTOUT(3CEH, SYSTEM.VAL(INTEGER, 0003H))
   END
  END Dot;
*)
  
  PROCEDURE ColorToIndex*(col: LONGINT): LONGINT;
  BEGIN
   RETURN CLUTs.Match(clut^, col)
  END ColorToIndex;
  
  PROCEDURE IndexToColor*(index: LONGINT): LONGINT;
  BEGIN
   RETURN pal[index MOD 16]
  END IndexToColor;
  
 END Display;

(* Copy a line of pixels to the display. *)

PROCEDURE CopyLineTo(src, dst, x, w: LONGINT);
CODE {SYSTEM.i386}
 MOV ESI, src[EBP]
 MOV EDI, dst[EBP]
 MOV EBX, x[EBP]
 MOV EDX, 3CEH
 MOV AL, 8
new:
 MOV CH, [ESI] ; CH = current pixel color
 MOV AH, 80H ; AH = mask for current pixels (at left of byte)
 MOV CL, BL
 AND CL, 7 ; CL = offset to shift mask right
 JMP loop
same:
 SAR AH, 1
loop:
 DEC w[EBP]
 JZ done
 INC EBX
 INC ESI
 TEST BL, 7
 JZ edge
 CMP CH, [ESI]
 JE same
diff:
 SHR AH, CL
 OUT DX, AX
 MOV CL, [EDI]
 MOV [EDI], CH
 JMP new
edge:
 SHR AH, CL ; adjust mask
 OUT DX, AX ; set mask
 MOV CL, [EDI] ; latch
 MOV [EDI], CH ; output color
 INC EDI
 JMP new
done:
 SHR AH, CL
 OUT DX, AX
 MOV CL, [EDI]
 MOV [EDI], CH
end:
END CopyLineTo;

PROCEDURE Install*;
BEGIN
 IF d # NIL THEN Displays.main := d END
END Install;

PROCEDURE InitPalette;
VAR i, col: LONGINT; ch: CHAR;
BEGIN
  (* standard Oberon colours *)
 pal[0] := 0; pal[1] := 0FF0000H; pal[2] := 000FF00H;
 pal[3] := 00000FFH; pal[4] := 0FF00FFH; pal[5] := 0FFFF00H;
 pal[6] := 000FFFFH; pal[7] := 0AA0000H; pal[9] := 000009AH;
 pal[10] := 0A6CBF3H; pal[11] := 0008282H; pal[12] := 08A8A8AH;
 pal[13] := 0BEBEBEH; pal[14] := 0DFDFDFH; pal[15] := 0FFFFFFH;
  (* set attribute controller registers *)
 SYSTEM.PORTIN(3DAH, ch); (* clear flip/flop *)
 FOR i := 0 TO 0FH DO
  SYSTEM.PORTOUT(3C0H, CHR(i)); (* EGA palette register i *)
  SYSTEM.PORTOUT(3C0H, CHR(i)) (* maps to VGA palette i *)
 END;
 SYSTEM.PORTOUT(3C0H, 11X); (* overscan color *)
 SYSTEM.PORTOUT(3C0H, 0X); (* black/EGA palette 0/VGA palette 0 *)
 SYSTEM.PORTOUT(3C0H, 12X); (* color plane enable *)
 SYSTEM.PORTOUT(3C0H, 0FX); (* enable all planes *)
 SYSTEM.PORTOUT(3C0H, 14X); (* color select *)
 SYSTEM.PORTOUT(3C0H, 0X); (* use first 16 colors in VGA palette *)
 SYSTEM.PORTOUT(3C0H, 20X); (* enable display to use palette again *)
  (* set up VGA palette and reverse lookup table *)
 NEW(clut);
 SYSTEM.PORTOUT(3C8H, 0X); (* select index 0 *)
 FOR i := 0 TO 15 DO
  col := pal[i]; CLUTs.Set(clut^, i, col);
  SYSTEM.PORTOUT(3C9H, CHR(col DIV 10000H MOD 100H DIV 4));
  SYSTEM.PORTOUT(3C9H, CHR(col DIV 100H MOD 100H DIV 4));
  SYSTEM.PORTOUT(3C9H, CHR(col MOD 100H DIV 4))
 END;
 FOR i := 16 TO 255 DO
  SYSTEM.PORTOUT(3C9H, 0X);
  SYSTEM.PORTOUT(3C9H, 0X);
  SYSTEM.PORTOUT(3C9H, 0X)
 END;
 CLUTs.Init(clut^, 16, 3);
 SYSTEM.PORTIN(3C6H, ch); pelmask := ORD(ch)
END InitPalette;
(*
  IF i = 6 THEN j := 14H
  ELSIF i > 7 THEN j := i+30H
  ELSE j := i
  END;
*)

PROCEDURE Init;
BEGIN
 NEW(d);
 d.width := Width; d.height := Height; d.offscreen := 0;
 d.format := Displays.index8; d.unit := 10000;
 Kernel.MapPhysical(0A0000H, 10000H, base);
 NEW(shadow, Width*Height);
  (* data rotate 0 *)
 SYSTEM.PORTOUT(3CEH, SYSTEM.VAL(INTEGER, 0003H));
  (* write mode 2 *)
 SYSTEM.PORTOUT(3CEH, SYSTEM.VAL(INTEGER, 0205H));
  (* set/reset disabled *)
 SYSTEM.PORTOUT(3CEH, SYSTEM.VAL(INTEGER, 0001H));
  (* no set/reset *)
 SYSTEM.PORTOUT(3CEH, SYSTEM.VAL(INTEGER, 0000H));
  (* map mask enable all planes *)
 SYSTEM.PORTOUT(3C4H, SYSTEM.VAL(INTEGER, 0F02H));
 InitPalette
END Init;

BEGIN
 Init; Install
END DisplayVGA4.

(*
to do:
1 fix for Mach64
1 remove shadow (read from real display)
1 offscreen
*)
