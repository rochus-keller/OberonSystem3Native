(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE PSDImages; (** portable *) (* ejz   *)
 IMPORT SYSTEM, Files, Images;

(* Photoshop 3.0, Grayscale, Indexed & RGB, 8 bit, RLE compressed *)

 TYPE
  Header = RECORD
   width, height: LONGINT;
   channels, depth, mode: INTEGER;
   data: LONGINT;
   pal: Images.Palette
  END;

 PROCEDURE ReadLInt(VAR R: Files.Rider; VAR i: LONGINT);
  VAR ch: CHAR;
 BEGIN
  Files.Read(R, ch); i := ORD(ch);
  Files.Read(R, ch); i := ORD(ch)+SYSTEM.LSH(i, 8);
  Files.Read(R, ch); i := ORD(ch)+SYSTEM.LSH(i, 8);
  Files.Read(R, ch); i := ORD(ch)+SYSTEM.LSH(i, 8)
 END ReadLInt;

 PROCEDURE ReadInt(VAR R: Files.Rider; VAR i: INTEGER);
  VAR ch: CHAR;
 BEGIN
  Files.Read(R, ch); i := ORD(ch);
  Files.Read(R, ch); i := ORD(ch)+SYSTEM.LSH(i, 8)
 END ReadInt;

 PROCEDURE CheckFormat(VAR R: Files.Rider): BOOLEAN;
  VAR sig: LONGINT; ver: INTEGER;
 BEGIN
  ReadLInt(R, sig);
  IF sig # 038425053H THEN RETURN FALSE END;
  ReadInt(R, ver);
  IF ver # 1 THEN RETURN FALSE END;
  ReadLInt(R, sig);
  IF sig # 0 THEN RETURN FALSE END;
  Files.ReadInt(R, ver);
  RETURN ver = 0
 END CheckFormat;

 PROCEDURE ReadHeader(VAR R: Files.Rider; VAR h: Header);
 BEGIN
  ReadInt(R, h.channels); (* 1 .. 24 *)
  ReadLInt(R, h.height); ReadLInt(R, h.width);
  ReadInt(R, h.depth); (* 1, 8, 16 *)
  ReadInt(R, h.mode) (* Bitmap=0; Grayscale=1; Indexed=2; RGB=3; CMYK=4; Multichannel=7; Duotone=8; Lab=9 *)
 END ReadHeader;

 PROCEDURE ReadColors(VAR R: Files.Rider; VAR h: Header);
  VAR pos, len, i: LONGINT;
 BEGIN
  h.pal := NIL;
  ReadLInt(R, len); pos := Files.Pos(R);
  IF h.mode = 2 THEN (* Indexed *)
   NEW(h.pal); i := 0;
   WHILE i < 256 DO
    Files.Read(R, h.pal.col[i, Images.r]);
    Files.Read(R, h.pal.col[i, Images.g]);
    Files.Read(R, h.pal.col[i, Images.b]);
    INC(i)
   END
  ELSIF h.mode = 1 THEN (* Grayscale *)
   NEW(h.pal); i := 0;
   WHILE i < 256 DO
    h.pal.col[i, Images.r] := CHR(i);
    h.pal.col[i, Images.g] := CHR(i);
    h.pal.col[i, Images.b] := CHR(i);
    INC(i)
   END
  END;
  Files.Set(R, Files.Base(R), pos+len)
 END ReadColors;

 PROCEDURE SkipSection(VAR R: Files.Rider);
  VAR len: LONGINT;
 BEGIN
  ReadLInt(R, len);
  Files.Set(R, Files.Base(R), Files.Pos(R)+len)
 END SkipSection;

 PROCEDURE LoadRLEInd8(VAR R: Files.Rider; VAR h: Header; img: Images.Image);
  VAR F: Files.File; pos, pix: LONGINT; i, n, nb, x, y: INTEGER; rle: SHORTINT; ch: CHAR;
 BEGIN
  F := Files.Base(R);
  pos := h.data + h.channels*h.height*2;
  y := 0; pix := 0;
  WHILE y < h.height DO
   Files.Set(R, F, h.data+y*2);
   ReadInt(R, nb);
   Files.Set(R, F, pos);
   pos := pos+nb;
   x := 0; pix := (h.height-y-1)*ABS(img.bpr);
   WHILE (x < h.width) & (nb > 0) DO
    Files.Read(R, rle); DEC(nb);
    IF rle >= 0 THEN
     n := LONG(rle)+1;
     WHILE n > 0 DO
      Files.Read(R, ch); DEC(nb);
      img.mem[pix] := ch; INC(pix);
      DEC(n); INC(x)
     END 
    ELSIF rle # -128 THEN
     n := 1-LONG(rle);
     Files.Read(R, ch); DEC(nb);
     i := 0;
     WHILE i < n DO
      img.mem[pix] := ch; INC(pix);
      INC(i)
     END;
     INC(x, n)
    END
   END;
   INC(y)
  END
 END LoadRLEInd8;

 PROCEDURE LoadRLERGB888(VAR R: Files.Rider; VAR h: Header; img: Images.Image);
  VAR F: Files.File; pos, pix, c: LONGINT; i, n, nb, x, y: INTEGER; rle: SHORTINT; ch: CHAR;
 BEGIN
  F := Files.Base(R);
  pos := h.data + h.channels*h.height*2;
  c := 0;
  WHILE c < 3 DO
   y := 0; pix := 0;
   WHILE y < h.height DO
    Files.Set(R, F, h.data + (c*h.height+y)*2);
    ReadInt(R, nb);
    Files.Set(R, F, pos);
    pos := pos+nb;
    x := 0; pix := (h.height-y-1)*ABS(img.bpr) + 2-c;
    WHILE (x < h.width) & (nb > 0) DO
     Files.Read(R, rle); DEC(nb);
     IF rle >= 0 THEN
      n := LONG(rle)+1;
      WHILE n > 0 DO
       Files.Read(R, ch); DEC(nb);
       img.mem[pix] := ch; INC(pix, 3);
       DEC(n); INC(x)
      END 
     ELSIF rle # -128 THEN
      n := 1-LONG(rle);
      Files.Read(R, ch); DEC(nb);
      i := 0;
      WHILE i < n DO
       img.mem[pix] := ch; INC(pix, 3);
       INC(i)
      END;
      INC(x, n)
     END
    END;
    INC(y)
   END;
   INC(c)
  END
 END LoadRLERGB888;

 PROCEDURE Load(img: Images.Image; VAR fname: ARRAY OF CHAR; VAR done: BOOLEAN);
  VAR F: Files.File; R: Files.Rider; h: Header; comp: INTEGER; fmt: Images.Format;
 BEGIN
  done := FALSE;
  F := Files.Old(fname); Files.Set(R, F, 0);
  IF (F # NIL) & CheckFormat(R) THEN
   ReadHeader(R, h);
   IF h.depth = 8 THEN
    ReadColors(R, h);
    SkipSection(R); (* image resources *)
    SkipSection(R); (* layer and mask information *)
    ReadInt(R, comp); (* Raw data = 0, RLE compressed = 1 *)
    h.data := Files.Pos(R);
    IF ((h.mode = 1) OR (h.mode = 2)) & (comp = 1) THEN
     Images.InitPaletteFormat(fmt, h.pal);
     Images.Create(img, SHORT(h.width), SHORT(h.height), fmt);
     LoadRLEInd8(R, h, img);
     done := TRUE
    ELSIF (h.mode = 3) & (comp = 1) THEN
     Images.Create(img, SHORT(h.width), SHORT(h.height), Images.BGR888);
     LoadRLERGB888(R, h, img);
     done := TRUE
    END
   END
  END
 END Load;

 PROCEDURE Install*;
 BEGIN
  Images.LoadProc := Load
 END Install;

END PSDImages.

SET "ImageFormats\psd" := PSDImages.Install
