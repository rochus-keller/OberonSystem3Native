(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE DisplayMach64; (* pjm *)

IMPORT SYSTEM, AosDisplays := Displays, Kernel;

CONST
 BusCntl = 28H*4;
 GenTestCntl = 34H*4;
 DstOffPitch = 40H*4;
 (*DstX = 41H*4;*)
 (*DstY = 42H*4;*)
 DstYX = 43H*4;
 (*DstWidth = 44H*4;*)
 DstHeight = 45H*4;
 DstHeightWidth = 46H*4;
 DstBresErr = 49H*4;
 DstBresInc = 4AH*4;
 DstBresDec = 4BH*4;
 DstCntl = 4CH*4;
 SrcOffPitch = 60H*4;
 SrcYX = 63H*4;
 SrcWidth1 = 64H*4;
 SrcHeight1Width1 = 66H*4;
 SrcYXStart = 69H*4;
 SrcCntl = 6DH*4;
 SrcHeight2Width2 = 6CH*4;
 HostData0 = 80H*4;
 HostData15 = 8FH*4;
 HostCntl = 90H*4;
 PatReg0 = 0A0H*4;
 PatReg1 = 0A1H*4;
 PatCntl = 0A2H*4;
 ScLeft = 0A8H*4;
 ScRight = 0A9H*4;
 ScTop = 0ABH*4;
 ScBottom = 0ACH*4;
 DpBkgdClr = 0B0H*4;
 DpFrgdClr = 0B1H*4;
 DpWriteMsk = 0B2H*4;
 DpChainMsk = 0B3H*4;
 DpPixWidth = 0B4H*4;
 DpMix = 0B5H*4;
 DpSrc = 0B6H*4;
 DstXY = 0BAH*4;
 (*DstWidthHeight = 0BBH*4;*)
 ClrCmpClr = 0C0H*4;
 ClrCmpMsk = 0C1H*4;
 ClrCmpCntl = 0C2H*4;
 FifoStat = 0C4H*4;
 ContextMsk = 0C8H*4;
 GuiTrajCntl = 0CCH*4;
 GuiStat = 0CEH*4;

VAR
 d: Display;
 base0, truecol: LONGINT;
 
TYPE
 Display* = OBJECT (AosDisplays.Display)
 
  PROCEDURE ReplConst*(col, x, y, w, h: LONGINT);
  BEGIN
   IF (w > 0) & (h > 0) & (col >= 0) THEN (* opaque or invert *)
    IF ASH(col, 1) >= 0 THEN
     WaitFIFO(4);
     SYSTEM.PUT(base0+DpFrgdClr, TransColor(col));
     SYSTEM.PUT(base0+DpSrc, {8});
     SYSTEM.PUT(base0+DstXY, ASH(y, 16) + x MOD 10000H);
     SYSTEM.PUT(base0+DstHeightWidth, ASH(w, 16) + h MOD 10000H)
    ELSE (* invert *)
     WaitFIFO(6);
     SYSTEM.PUT(base0+DpFrgdClr, TransColor(col));
     SYSTEM.PUT(base0+DpMix, {0, 1, 16, 18}); (* DST xor SRC / DST *)
     SYSTEM.PUT(base0+DpSrc, {8});
     SYSTEM.PUT(base0+DstXY, ASH(y, 16) + x MOD 10000H);
     SYSTEM.PUT(base0+DstHeightWidth, ASH(w, 16) + h MOD 10000H);
     SYSTEM.PUT(base0+DpMix, {0, 1, 16, 17, 18}) (* SRC / DST *)
    END
   END
  END ReplConst;
  
  PROCEDURE Dot*(col, x, y: LONGINT);
  BEGIN
   IF col >= 0 THEN (* opaque or invert *)
    IF ASH(col, 1) >= 0 THEN
     WaitFIFO(4);
     SYSTEM.PUT(base0+DpFrgdClr, TransColor(col));
     SYSTEM.PUT(base0+DpSrc, {8});
     SYSTEM.PUT(base0+DstXY, ASH(y, 16) + x MOD 10000H);
     SYSTEM.PUT(base0+DstHeightWidth, SYSTEM.VAL(LONGINT, 10001H))
    ELSE (* invert *)
     WaitFIFO(6);
     SYSTEM.PUT(base0+DpFrgdClr, TransColor(col));
     SYSTEM.PUT(base0+DpMix, {0, 1, 16, 18}); (* DST xor SRC / DST *)
     SYSTEM.PUT(base0+DpSrc, {8});
     SYSTEM.PUT(base0+DstXY, ASH(y, 16) + x MOD 10000H);
     SYSTEM.PUT(base0+DstHeightWidth, SYSTEM.VAL(LONGINT, 10001H));
     SYSTEM.PUT(base0+DpMix, {0, 1, 16, 17, 18}) (* SRC / DST *)
    END
   END
  END Dot;
  
  PROCEDURE CopyBlock*(sx, sy, w, h, dx, dy: LONGINT);
  VAR s: SET;
  BEGIN
   IF (w > 0) & (h > 0) THEN
    IF sy >= dy THEN s := {1} ELSE s := {}; INC(sy, h-1); INC(dy, h-1) END;
    IF sx >= dx THEN INCL(s, 0) ELSE INC(sx, w-1); INC(dx, w-1) END;
    WaitFIFO(8);
    SYSTEM.PUT(base0+DstCntl, s);
    SYSTEM.PUT(base0+DpSrc, {8, 9}); (* BLIT / BG *)
    SYSTEM.PUT(base0+SrcYX, ASH(sx, 16) + sy MOD 10000H);
    SYSTEM.PUT(base0+SrcWidth1, w);
    SYSTEM.PUT(base0+DstYX, ASH(dx, 16) + dy MOD 10000H);
    SYSTEM.PUT(base0+DstHeightWidth, ASH(w, 16) + h MOD 10000H);
    SYSTEM.PUT(base0+DpSrc, {8}); (* FG / BG *)
    SYSTEM.PUT(base0+DstCntl, {0, 1, 5})
    ;WaitIdle
   END
  END CopyBlock;
  
  PROCEDURE PaintMask*(VAR buf: ARRAY OF CHAR; bitofs, stride, fg, bg, x, y, w, h: LONGINT);
  VAR p, i, j, out: LONGINT; ch: CHAR;
  BEGIN
   IF (w > 0) & (h > 0) THEN
    WaitFIFO(7);
    IF stride < 0 THEN
     INC(y, h-1); INC(bitofs, (h-1)*stride*8);
     stride := -stride;
     SYSTEM.PUT(base0+GuiTrajCntl, {0, 5}) (* left-to-right, bottom-to-top *)
    ELSE
     SYSTEM.PUT(base0+GuiTrajCntl, {0, 1, 5}) (* left-to-right, top-to-bottom *)
    END;
    p := SYSTEM.ADR(buf[0]) + bitofs DIV 8;
    bitofs := bitofs MOD 8;
    CASE format OF
     1: SYSTEM.PUT(base0+DpPixWidth, {1, 29})
     |2: SYSTEM.PUT(base0+DpPixWidth, {2, 30})
     |4: SYSTEM.PUT(base0+DpPixWidth, {1, 2, 29, 30})
    END;
    SYSTEM.PUT(base0+DpSrc, {8, 17}); (* FG / BG / Mono Host *)
    SYSTEM.PUT(base0+DpFrgdClr, TransColor(fg));
    SYSTEM.PUT(base0+DpBkgdClr, TransColor(bg));
    SYSTEM.PUT(base0+DstYX, ASH(x, 16) + y MOD 10000H);
    SYSTEM.PUT(base0+DstHeightWidth, ASH(w, 16) + h MOD 10000H);
    j := 0; out := 0;
    LOOP
     FOR i := 0 TO (w-1) DIV 8 DO
      SYSTEM.GET(p+i, ch);
      out := ASH(out, -8) + ASH(ORD(ch), 24);
      INC(j);
      IF j MOD 4 = 0 THEN
       WaitFIFO(1);
       SYSTEM.PUT(base0+HostData0, out);
       out := 0
      END
     END;
     DEC(h);
     IF h = 0 THEN EXIT END;
     INC(p, stride)
    END;
    IF j MOD 4 # 0 THEN
     REPEAT out := ASH(out, -8); INC(j) UNTIL j MOD 4 = 0;
     WaitFIFO(1);
     SYSTEM.PUT(base0+HostData0, out)
    END;
    WaitFIFO(3);
    SYSTEM.PUT(base0+DpSrc, {8}); (* FG / BG *)
    SYSTEM.PUT(base0+GuiTrajCntl, {0, 1, 5}); (* left-to-right, top-to-bottom *)
    CASE format OF
     1: SYSTEM.PUT(base0+DpPixWidth, {1, 9, 17, 29})
     |2: SYSTEM.PUT(base0+DpPixWidth, {2, 10, 18, 30})
     |4: SYSTEM.PUT(base0+DpPixWidth, {1, 2, 9, 10, 17, 18, 29, 30})
    END
   END
  END PaintMask;
  
  PROCEDURE Transfer*(VAR buf: ARRAY OF CHAR; ofs, stride, x, y, w, h, op: LONGINT);
  VAR bufadr, w0, dw: LONGINT; ch: CHAR;
  BEGIN
   WaitIdle;
   Transfer^(buf, ofs, stride, x, y, w, h, op)
(*
   IF op = AosDisplays.set THEN
    IF (w > 0) & (h > 0) THEN
     bufadr := SYSTEM.ADR(buf[ofs]);
     WaitFIFO(4);
     SYSTEM.PUT(base0+DpSrc, {9}); (* HOST / BG *)
     SYSTEM.PUT(base0+GuiTrajCntl, {0, 1, 5}); (* left-to-right, top-to-bottom *)
     SYSTEM.PUT(base0+DstYX, ASH(x, 16) + y MOD 10000H);
     SYSTEM.PUT(base0+DstHeightWidth, ASH(w, 16) + h MOD 10000H);
     w := w * format; (* convert to bytes *)
     REPEAT
      w0 := w;
      WHILE w0 >= 16*4 DO
       WaitFIFO(16);
       SYSTEM.MOVE(bufadr, base0+HostData0, 16*4);
       DEC(w0, 16*4); INC(bufadr, 16*4)
      END;
      IF w0 >= 4 THEN
       WaitFIFO(w0 DIV 4);
       REPEAT
        SYSTEM.GET(bufadr, dw);
        SYSTEM.PUT(base0+HostData0, dw);
        DEC(w0, 4); INC(bufadr, 4)
       UNTIL w0 < 4
      END;
      IF w0 > 0 THEN
       WaitFIFO(w0);
       REPEAT
        SYSTEM.GET(bufadr, ch);
        SYSTEM.PUT(base0+HostData0, ch);
        DEC(w0); INC(bufadr)
       UNTIL w0 = 0
      END;
      INC(bufadr, stride-w);
      DEC(h)
     UNTIL h = 0;
     WaitFIFO(1);
     SYSTEM.PUT(base0+DpSrc, {8}) (* FG / BG *)
    END
   ELSE
    WaitIdle;
    TransferBlock^(buf, ofs, stride, x, y, w, h, op)
   END
*)
  END Transfer;
  
 END Display;

PROCEDURE WaitFIFO(n: LONGINT);
VAR x: LONGINT;
BEGIN
 REPEAT SYSTEM.GET(base0+FifoStat, x) UNTIL x MOD 10000H <= ASH(8000H, -n)
END WaitFIFO;

PROCEDURE WaitIdle;
VAR s: SET;
BEGIN
 WaitFIFO(16);
 REPEAT SYSTEM.GET(base0+GuiStat, s) UNTIL ~(0 IN s)
END WaitIdle;

(* Translate a Color value to display format. *)

PROCEDURE TransColor(col: LONGINT): LONGINT;
BEGIN
 CASE truecol OF
  0: (* 8-bit indexed *)
   IF 30 IN SYSTEM.VAL(SET, col) THEN
    col := SYSTEM.VAL(LONGINT, 
      SYSTEM.VAL(SET, ASH(col, 7-23)) * {5..7} +
      SYSTEM.VAL(SET, ASH(col, 4-15)) * {2..4} +
      SYSTEM.VAL(SET, ASH(col, 1-7)) * {0..1});
    IF col # 0 THEN RETURN col ELSE RETURN 15 END
   ELSE
    RETURN SYSTEM.VAL(LONGINT, 
      SYSTEM.VAL(SET, ASH(col, 7-23)) * {5..7} +
      SYSTEM.VAL(SET, ASH(col, 4-15)) * {2..4} +
      SYSTEM.VAL(SET, ASH(col, 1-7)) * {0..1})
   END
  |1: (* 16-bit hicolor *)
   IF SYSTEM.VAL(SET, col) * {0..23,30} = {30} THEN
    RETURN 0FFFFH
   ELSE
    RETURN SYSTEM.VAL(LONGINT, 
     SYSTEM.VAL(SET, ASH(col, 15-23)) * {11..15} +
     SYSTEM.VAL(SET, ASH(col, 10-15)) * {5..10} +
     SYSTEM.VAL(SET, ASH(col, 4-7)) * {0..4})
   END
  |2: (* 24/32-bit truecolor *)
   IF SYSTEM.VAL(SET, col) * {0..23,30} = {30} THEN
    RETURN 0FFFFFFH
   ELSE
    RETURN col MOD 1000000H
   END
 END
END TransColor;

PROCEDURE GetVal(str: ARRAY OF CHAR;  default: LONGINT): LONGINT;
VAR i: SHORTINT;  v: LONGINT;  s: ARRAY 10 OF CHAR;
BEGIN
 Kernel.GetConfig(str, s);
 IF s[0] = 0X THEN
  v := default
 ELSE
  v := 0;  i := 0;
  WHILE s[i] # 0X DO v := v*10+(ORD(s[i])-48); INC(i) END
 END;
 RETURN v
END GetVal;

PROCEDURE InitPalette;
VAR col: LONGINT; ch: CHAR;
BEGIN
 SYSTEM.PORTIN(3DAH, ch);
 SYSTEM.PORTOUT(3C0H, 11X);
 SYSTEM.PORTOUT(3C0H, 0X); (* palette entry 0 is black *)
 SYSTEM.PORTOUT(3C0H, 20X);
 FOR col := 0 TO 255 DO
  SYSTEM.PORTOUT(3C8H, CHR(col));
  SYSTEM.PORTOUT(3C9H, CHR(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, col) * {5..7}) DIV 4));
  SYSTEM.PORTOUT(3C9H, CHR(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(col, 7-4)) * {5..7}) DIV 4));
  SYSTEM.PORTOUT(3C9H, CHR(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(col, 7-1)) * {6..7}) DIV 4))
 END
END InitPalette;

PROCEDURE Init;
VAR w, h, f, mem, adr: LONGINT; s: SET;
BEGIN
 w := GetVal("DWidth", 1024); (* assume 1024 if not specified *)
 h := GetVal("DHeight", 768); (* assume 768 if not specified *)
 f := GetVal("DDepth", 8) DIV 8;
 truecol := f DIV 2;
 mem := GetVal("DMem", 0)*1024;
 IF mem = 0 THEN (* compute default *)
  mem := 512*1024;
  WHILE w*h*f >= mem DO mem := mem*2 END
 END;
 Kernel.GetInit(1, adr);
 Kernel.MapPhysical(adr, 800000H, adr);
 ASSERT(adr # 0);
 base0 := adr + 7FFC00H;
 NEW(d);
 d.width := w; d.height := h; d.offscreen := mem DIV (w*f) - h;
 d.format := f; d.unit := 10000;
 d.InitFrameBuffer(adr, mem);
 IF f = 1 THEN InitPalette END;
 SYSTEM.GET(base0+38H*4, s);
 Kernel.WriteString("ConfigChipID=");
 Kernel.WriteHex(SYSTEM.VAL(LONGINT, s), 8); Kernel.WriteLn;
  (* reset the FIFO *)
 SYSTEM.GET(base0+GenTestCntl, s); SYSTEM.PUT(base0+GenTestCntl, s - {8});
 SYSTEM.GET(base0+GenTestCntl, s); SYSTEM.PUT(base0+GenTestCntl, s + {8});
 SYSTEM.GET(base0+BusCntl, s); SYSTEM.PUT(base0+BusCntl, s + {23});
  (* initialize the engine (sec. 5.5.1) *)
 WaitFIFO(14);
 SYSTEM.PUT(base0+ContextMsk, {0..31});
 SYSTEM.PUT(base0+DstOffPitch, ASH(w, 22-3));
 SYSTEM.PUT(base0+DstYX, {});
 SYSTEM.PUT(base0+DstHeight, {});
 SYSTEM.PUT(base0+DstBresErr, {});
 SYSTEM.PUT(base0+DstBresInc, {});
 SYSTEM.PUT(base0+DstBresDec, {});
 SYSTEM.PUT(base0+DstCntl, {0, 1, 5});
 SYSTEM.PUT(base0+SrcOffPitch, ASH(w, 22-3));
 SYSTEM.PUT(base0+SrcYX, {});
 SYSTEM.PUT(base0+SrcHeight1Width1, {0, 16});
 SYSTEM.PUT(base0+SrcYXStart, {});
 SYSTEM.PUT(base0+SrcHeight2Width2, {0, 16});
 SYSTEM.PUT(base0+SrcCntl, {});
 WaitFIFO(13);
 SYSTEM.PUT(base0+HostCntl, {}); (* no byte align *)
 SYSTEM.PUT(base0+PatReg0, {});
 SYSTEM.PUT(base0+PatReg1, {});
 SYSTEM.PUT(base0+PatCntl, {});
 SYSTEM.PUT(base0+ScLeft, {});
 SYSTEM.PUT(base0+ScTop, {});
 SYSTEM.PUT(base0+ScBottom, (h+d.offscreen)-1);
 SYSTEM.PUT(base0+ScRight, w-1);
 SYSTEM.PUT(base0+DpBkgdClr, {});
 SYSTEM.PUT(base0+DpFrgdClr, {0..31});
 SYSTEM.PUT(base0+DpWriteMsk, {0..31});
 SYSTEM.PUT(base0+DpMix, {0, 1, 16, 17, 18}); (* SRC / DST *)
 SYSTEM.PUT(base0+DpSrc, {8}); (* FG / BG *)
 WaitFIFO(5);
 SYSTEM.PUT(base0+ClrCmpClr, {});
 SYSTEM.PUT(base0+ClrCmpMsk, {0..31});
 SYSTEM.PUT(base0+ClrCmpCntl, {});
 CASE f OF
  1: SYSTEM.PUT(base0+DpPixWidth, {1, 9, 17, 29});
   SYSTEM.PUT(base0+DpChainMsk, SYSTEM.VAL(LONGINT, 8080H))
  |2: SYSTEM.PUT(base0+DpPixWidth, {2, 10, 18, 30});
   SYSTEM.PUT(base0+DpChainMsk, SYSTEM.VAL(LONGINT, 4210H))
  |4: SYSTEM.PUT(base0+DpPixWidth, {1, 2, 9, 10, 17, 18, 29, 30});
   SYSTEM.PUT(base0+DpChainMsk, SYSTEM.VAL(LONGINT, 8080H))
 END;
 WaitIdle
END Init;

PROCEDURE Install*;
BEGIN
 IF d # NIL THEN AosDisplays.main := d END
END Install;

BEGIN
 Init; Install
END DisplayMach64.

DisplayTools.TryDriver DisplayMach64.Install 0 ~
DisplayTools.Restore
System.Free DisplayMach64 ~

(*
to do:
1 map register aperture
*)
