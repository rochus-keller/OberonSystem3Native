(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE TestV86; (* pjm *)

(* Experimental! *)

IMPORT SYSTEM, V86, Files, Display, Oberon, In, Texts;

VAR
 w: Texts.Writer;
 
PROCEDURE Beep*;
VAR reg: V86.Regs;
BEGIN
 reg.EAX := 0E07H;  reg.EBX := 0;
 V86.Video(reg)
END Beep;

(*
PROCEDURE Real*;
VAR reg: V86.Regs;
BEGIN
 reg.EAX := 3H;  V86.Video(reg);
 SYSTEM.PUT(0B8000H, ORD("a")+0F00H);
 V86.RealMode
END Real;
*)

PROCEDURE WriteString(VAR w: Texts.Writer;  adr: LONGINT);
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
END WriteString;

PROCEDURE Normalize(VAR adr: LONGINT);
BEGIN
 adr := ASH(ASH(adr, -16) MOD 10000H, 4) + adr MOD 10000H
END Normalize;

PROCEDURE Bits(VAR w: Texts.Writer;  s: ARRAY OF CHAR;  x: SET;  ofs, n: LONGINT);
BEGIN
 Texts.WriteString(w, s);  Texts.Write(w, "=");
 REPEAT
  DEC(n);
  IF (ofs+n) IN x THEN Texts.Write(w, "1") ELSE Texts.Write(w, "0") END
 UNTIL n = 0
END Bits;

PROCEDURE VesaInfo*; (* TestV86.VesaInfo *)
VAR
 reg: V86.Regs;  s: ARRAY 8 OF CHAR;  mode: ARRAY 64 OF LONGINT;
 ver, size, m, width, height, wgran, wsize, sega, segb, line: INTEGER;  
 proc, a, i, n: LONGINT;  t: Texts.Text;  attr: SET;
 cwidth, cheight, planes, bpp, banks, memtype, banksize, pages, rsize, rpos, gsize, gpos, bsize, bpos, esize, epos, cflag: SHORTINT;
 linbuf, offscreen, osize: LONGINT;
BEGIN
 V86.Init;
 
 s := "VBE2";
 SYSTEM.MOVE(SYSTEM.ADR(s[0]), V86.bufadr, 4);
 
 reg.EAX := 4F00H;
 reg.ES := V86.bufadr DIV 16;
 reg.EDI := V86.bufadr MOD 16;
 V86.Video(reg);
 
 IF reg.EAX MOD 10000H = 4FH THEN
  SYSTEM.MOVE(V86.bufadr, SYSTEM.ADR(s[0]), 4);  s[4] := 0X;
  SYSTEM.GET(V86.bufadr+4, ver);
  Texts.WriteString(w, s);  Texts.WriteInt(w, ver DIV 100H, 2);  Texts.Write(w, ".");  
  Texts.WriteInt(w, ver MOD 100H, 1);
  SYSTEM.GET(V86.bufadr+6, a);  Normalize(a);
  Texts.Write(w, " ");  Texts.Write(w, 22X);  WriteString(w, a);  Texts.Write(w, 22X);
  SYSTEM.GET(V86.bufadr+18, size);
  Texts.Write(w, " ");  Texts.WriteInt(w, LONG(size)*64, 1);  Texts.Write(w, "k");
  SYSTEM.GET(V86.bufadr+10, a);
  Texts.WriteHex(w, a);
  
  SYSTEM.GET(V86.bufadr+14, a);  Normalize(a);
  n := 0;
  LOOP
   SYSTEM.GET(a, m);
   IF m = -1 THEN EXIT END;
   mode[n] := m;  INC(n);
   INC(a, 2)
  END;
  Texts.Write(w, " ");  Texts.WriteInt(w, n, 1);  Texts.WriteString(w, " modes");  Texts.WriteLn(w);

  FOR i := 0 TO n-1 DO
   Texts.WriteLn(w);  Texts.WriteString(w, "mode");  Texts.WriteHex(w, mode[i]);
   
   reg.EAX := 4F01H;
   reg.ECX := mode[i];
   reg.ES := V86.bufadr DIV 16;
   reg.EDI := V86.bufadr MOD 16;
   V86.Video(reg);

   IF reg.EAX MOD 10000H = 4FH THEN
    SYSTEM.GET(V86.bufadr, attr); (* 0..15=mode attr, 16..23=window A attr, 24..31=window B attr *)
    SYSTEM.GET(V86.bufadr+4, wgran);
    SYSTEM.GET(V86.bufadr+6, wsize);
    SYSTEM.GET(V86.bufadr+8, sega);
    SYSTEM.GET(V86.bufadr+0AH, segb);
    SYSTEM.GET(V86.bufadr+0CH, proc);
    SYSTEM.GET(V86.bufadr+10H, line);
    Texts.WriteString(w, ", attr");  Texts.WriteHex(w, SYSTEM.VAL(LONGINT, attr));
    Texts.WriteString(w, ", wgran ");  Texts.WriteInt(w, wgran, 1);
    Texts.WriteString(w, "k, wsize ");  Texts.WriteInt(w, wsize, 1);
    Texts.WriteString(w, "k, sega");  Texts.WriteHex(w, LONG(sega) MOD 10000H);
    Texts.WriteString(w, ", segb");  Texts.WriteHex(w, LONG(segb) MOD 10000H);
    Texts.WriteString(w, ", proc");  Texts.WriteHex(w, proc);
    Texts.WriteString(w, ", line ");  Texts.WriteInt(w, line, 1);
    Texts.WriteLn(w);  Texts.WriteString(w, "  ");
    Bits(w, "supported", attr, 0, 1);
    Bits(w, ", output", attr, 2, 1);
    Bits(w, ", color", attr, 3, 1);
    Bits(w, ", graphics", attr, 4, 1);
    Bits(w, ", linbuf/banks/vga", attr / {5,6}, 5, 3);
    Bits(w, ", win a", attr, 16, 3);
    Bits(w, ", win b", attr, 24, 3);
     (* optional, depending on bit 1 of attr *)
    IF 1 IN attr THEN
     SYSTEM.GET(V86.bufadr+12H, width);
     SYSTEM.GET(V86.bufadr+14H, height);
     SYSTEM.GET(V86.bufadr+16H, cwidth);
     SYSTEM.GET(V86.bufadr+17H, cheight);
     SYSTEM.GET(V86.bufadr+18H, planes);
     SYSTEM.GET(V86.bufadr+19H, bpp);
     SYSTEM.GET(V86.bufadr+1AH, banks);
     SYSTEM.GET(V86.bufadr+1BH, memtype);
     SYSTEM.GET(V86.bufadr+1CH, banksize);
     SYSTEM.GET(V86.bufadr+1DH, pages);
     IF ver >= 0102H THEN (* 1.2+ *)
      SYSTEM.GET(V86.bufadr+1FH, rsize);
      SYSTEM.GET(V86.bufadr+20H, rpos);
      SYSTEM.GET(V86.bufadr+21H, gsize);
      SYSTEM.GET(V86.bufadr+22H, gpos);
      SYSTEM.GET(V86.bufadr+23H, bsize);
      SYSTEM.GET(V86.bufadr+24H, bpos);
      SYSTEM.GET(V86.bufadr+25H, esize);
      SYSTEM.GET(V86.bufadr+26H, epos);
      SYSTEM.GET(V86.bufadr+27H, cflag)
     END;
     IF ver >= 0200H THEN (* 2.0+ *)
      SYSTEM.GET(V86.bufadr+28H, linbuf);
      SYSTEM.GET(V86.bufadr+2CH, offscreen);
      SYSTEM.GET(V86.bufadr+30H, osize)
     END;
     Texts.WriteLn(w);
     Texts.WriteString(w, "  ");  Texts.WriteInt(w, width, 1);  Texts.WriteString(w, "x");  Texts.WriteInt(w, height, 1);
     Texts.WriteString(w, ", ");  Texts.WriteInt(w, cwidth, 1);  Texts.WriteString(w, "x");  Texts.WriteInt(w, cheight, 1);
     Texts.WriteString(w, ", planes ");  Texts.WriteInt(w, planes, 1);
     Texts.WriteString(w, ", bpp ");  Texts.WriteInt(w, bpp, 1);
     Texts.WriteString(w, ", banks ");  Texts.WriteInt(w, banks, 1);
     Texts.WriteString(w, ", memtype ");  Texts.WriteInt(w, memtype, 1);
     Texts.WriteString(w, ", banksize ");  Texts.WriteInt(w, banksize, 1);
     Texts.WriteString(w, "k, pages ");  Texts.WriteInt(w, LONG(pages) MOD 100H, 1);
     IF ver >= 0102H THEN (* 1.2+ *)
      Texts.WriteLn(w);
      Texts.WriteString(w, "  red ");  Texts.WriteInt(w, rsize, 1);  Texts.Write(w, "/");  Texts.WriteInt(w, rpos, 1);
      Texts.WriteString(w, ", green ");  Texts.WriteInt(w, gsize, 1);  Texts.Write(w, "/");  Texts.WriteInt(w, gpos, 1);
      Texts.WriteString(w, ", blue ");  Texts.WriteInt(w, bsize, 1);  Texts.Write(w, "/");  Texts.WriteInt(w, bpos, 1);
      Texts.WriteString(w, ", extra ");  Texts.WriteInt(w, esize, 1);  Texts.Write(w, "/");  Texts.WriteInt(w, epos, 1);
      Texts.WriteString(w, ", flag ");  Texts.WriteInt(w, cflag, 1)
     END;
     IF ver >= 0200H THEN (* 2.0+ *)
      Texts.WriteLn(w);
      Texts.WriteString(w, "  linbuf");  Texts.WriteHex(w, linbuf);
      Texts.WriteString(w, ", offscreen");  Texts.WriteHex(w, offscreen);
      Texts.WriteString(w, ", osize");  Texts.WriteHex(w, osize)
     END
    END
   ELSE
    Texts.WriteString(w, " error ");  Texts.WriteInt(w, ASH(reg.EAX, -8) MOD 100H, 1)
   END;
   Texts.WriteLn(w);
  END;
  NEW(t);  Texts.Open(t, "");
  Texts.Append(t, w.buf);
  Oberon.OpenText("VESA.Text", t, 400, 400)
 END;
 V86.Cleanup
END VesaInfo;

PROCEDURE ShowModes*;
VAR
 reg: V86.Regs; a, n, linbuf, i, modes: LONGINT; ver, size, width, height, m: INTEGER; s: ARRAY 8 OF CHAR;
 bpp, rsize, gsize, bsize, esize, memtype: SHORTINT;
 mode: ARRAY 64 OF LONGINT; attr: SET; t: Texts.Text;
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
  Texts.WriteString(w, s);  Texts.WriteInt(w, ver DIV 100H, 2);  Texts.Write(w, ".");  
  Texts.WriteInt(w, ver MOD 100H, 1);
  SYSTEM.GET(V86.bufadr+6, a);  Normalize(a);
  Texts.Write(w, " ");  Texts.Write(w, 22X);  WriteString(w, a);  Texts.Write(w, 22X);
  SYSTEM.GET(V86.bufadr+18, size);
  Texts.Write(w, " ");  Texts.WriteInt(w, LONG(size)*64, 1);  Texts.Write(w, "k");
  Texts.WriteLn(w);
  
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
        Texts.WriteInt(w, width, 4); Texts.WriteInt(w, height, 5); Texts.WriteInt(w, bpp, 3);
        Texts.WriteHex(w, mode[i]); Texts.WriteHex(w, linbuf); Texts.WriteLn(w);
        INC(modes)
       END
      END
     END
    END
   END
  END;
  IF modes = 0 THEN
   Texts.WriteString(w, "No suitable VESA modes found"); Texts.WriteLn(w);
   Texts.Append(Oberon.Log, w.buf)
  ELSE
   NEW(t);  Texts.Open(t, "");
   Texts.Append(t, w.buf);
   Oberon.OpenText("ShowModes", t, 400, 400)
  END
 ELSE
  Texts.WriteString(w, "VESA not found"); Texts.WriteLn(w);
  Texts.Append(Oberon.Log, w.buf)
 END;
 V86.Cleanup
END ShowModes;

PROCEDURE ResetPalette;
VAR F: Files.File; R: Files.Rider; i, cols: INTEGER; r, g, b: CHAR;
BEGIN
 IF Display.Depth(0) >= 8 THEN cols := 256 ELSE cols := 16 END;
 F := Files.Old("Default.Pal");
 IF F # NIL THEN
  Files.Set(R, F, 0);
  FOR  i := 0 TO cols-1 DO
   Files.Read(R, r); Files.Read(R, g); Files.Read(R, b);
   Display.SetColor(i, ORD(r), ORD(g), ORD(b))
  END
 END
END ResetPalette;

PROCEDURE UpdateDisplay;
VAR dcm: Display.ControlMsg;  cm: Oberon.ControlMsg;
BEGIN
 cm.F := NIL;  cm.id := Oberon.neutralize;  Display.Broadcast(cm);
 Oberon.FadeCursor(Oberon.Mouse);  Oberon.FadeCursor(Oberon.Pointer);
 dcm.F := NIL;  dcm.id := Display.suspend;  Display.Broadcast(dcm);
 dcm.F := NIL;  dcm.id := Display.restore;  Display.Broadcast(dcm)
END UpdateDisplay;
   
PROCEDURE Mode*;
VAR col: INTEGER;  mode: LONGINT;
BEGIN
 In.Open;  In.Int(col);  In.LongInt(mode);
 IF In.Done THEN
  Display.SetMode(col, SYSTEM.VAL(SET, mode));
  ResetPalette;
  UpdateDisplay
 END
END Mode;

BEGIN
 Texts.OpenWriter(w)
END TestV86.

TestV86.Beep
TestV86.VesaInfo
TestV86.ShowModes

TestV86.Mode 1 0211H   640  480  64k  P16
TestV86.Mode 1 0111H   640  480  64k  P16
TestV86.Mode 2 0212H   640  480  16m  P24
TestV86.Mode 2 0112H   640  480  16m  P32

TestV86.Mode 0 0103H   800  600  256  P8
TestV86.Mode 1 0114H   800  600  64k  P16
TestV86.Mode 2 0115H   800  600  16m  P32

TestV86.Mode 0 0105H  1024  768  256  P8
TestV86.Mode 1 0117H  1024  768  64k  P16
TestV86.Mode 2 0118H  1024  768  16m  P32
TestV86.Mode 0 0205H  1024  768  256  P8

TestV86.Mode 1 011AH  1280 1024  64k  P16
TestV86.Mode 0 0107H  1280 1024  256  P8

TestV86.Real
