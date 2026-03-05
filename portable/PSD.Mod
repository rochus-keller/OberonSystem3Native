(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE PSD; (** portable *) (* ejz   *)
 IMPORT SYSTEM, Files, Objects, Display, Pictures;

(* Photoshop 3.0, Grayscale & Indexed, 8 bit, RLE compressed *)

 TYPE
  Header = RECORD
   width, height: LONGINT;
   channels, depth, mode: INTEGER;
   data: LONGINT;
   pal: ARRAY 256 OF Display.Color
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
  VAR pos, len, i: LONGINT; r, g, b: CHAR;
 BEGIN
  ReadLInt(R, len); pos := Files.Pos(R);
  IF h.mode = 2 THEN (* Indexed *)
   i := 0;
   WHILE i < 256 DO
    Files.Read(R, r); Files.Read(R, g); Files.Read(R, b);
    h.pal[i] := Display.RGB(ORD(r), ORD(g), ORD(b)); INC(i)
   END
  ELSIF h.mode = 1 THEN (* Grayscale *)
   i := 0;
   WHILE i < 256 DO
    h.pal[i] := Display.RGB(i, i, i); INC(i)
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

 PROCEDURE CopyPal(VAR h: Header; P: Pictures.Picture);
  VAR i: LONGINT; r, g, b: INTEGER;
 BEGIN
  i := 0;
  WHILE i < 256 DO
   Display.GetColor(h.pal[i], r, g, b);
   Pictures.SetColor(P, SHORT(i), r, g, b);
   INC(i)
  END
 END CopyPal;

 PROCEDURE LoadRLEInd8(VAR R: Files.Rider; VAR h: Header; P: Pictures.Picture);
  VAR F: Files.File; pos: LONGINT; n, nb, x, y, py: INTEGER; rle: SHORTINT; ch: CHAR;
 BEGIN
  Pictures.Create(P, SHORT(h.width), SHORT(h.height), 8);
  CopyPal(h, P); F := Files.Base(R);
  pos := h.data + h.channels*h.height*2;
  y := 0;
  WHILE y < h.height DO
   Files.Set(R, F, h.data+y*2);
   ReadInt(R, nb);
   Files.Set(R, F, pos);
   pos := pos+nb;
   x := 0; py := SHORT(h.height-y-1);
   WHILE (x < h.width) & (nb > 0) DO
    Files.Read(R, rle); DEC(nb);
    IF rle >= 0 THEN
     n := LONG(rle)+1;
     WHILE n > 0 DO
      Files.Read(R, ch); DEC(nb);
      Pictures.Dot(P, ORD(ch), x, py, Display.replace);
      DEC(n); INC(x)
     END 
    ELSIF rle # -128 THEN
     n := 1-LONG(rle);
     Files.Read(R, ch); DEC(nb);
     Pictures.ReplConst(P, ORD(ch), x, py, n, 1, Display.replace);
     INC(x, n)
    END
   END;
   INC(y)
  END
 END LoadRLEInd8;

 PROCEDURE Load(VAR R: Files.Rider; VAR P: Pictures.Picture);
  VAR h: Header; comp: INTEGER;
 BEGIN
  IF CheckFormat(R) THEN
   ReadHeader(R, h);
   IF ((h.mode = 1) OR (h.mode = 2)) & (h.depth = 8) THEN
    ReadColors(R, h);
    SkipSection(R); (* image resources *)
    SkipSection(R); (* layer and mask information *)
    ReadInt(R, comp); (* Raw data = 0, RLE compressed = 1 *)
    h.data := Files.Pos(R);
    IF comp = 1 THEN
     LoadRLEInd8(R, h, P)
    END
   END
  END
 END Load;

 PROCEDURE Handle*(obj: Objects.Object; VAR M: Objects.ObjMsg);
 BEGIN
  WITH obj: Pictures.Picture DO
   IF M IS Objects.AttrMsg THEN
    WITH M: Objects.AttrMsg DO 
     IF (M.id = Objects.get) & (M.name = "Gen") THEN
      M.class := Objects.String; M.s := "Pictures.NewPicture"; M.res:=0 
     END;
    END;
   ELSIF M IS Objects.FileMsg THEN
    WITH M: Objects.FileMsg DO
     IF M.id = Objects.load THEN
      obj.depth := 0; Load(M.R, obj);
      IF obj.depth = 0 THEN M.len := 0 ELSE M.len := Files.Length(Files.Base(M.R)) END
     ELSE
      Pictures.Handle(obj, M)
     END
    END
   ELSE 
    Pictures.Handle(obj, M)
   END
  END
 END Handle;

 PROCEDURE InitPicture*;
 BEGIN
  Objects.NewObj.handle := Handle
 END InitPicture;

 PROCEDURE NewPicture*;
  VAR P: Pictures.Picture;
 BEGIN
  NEW(P); P.handle := Handle;
  Objects.NewObj := P
 END NewPicture;

END PSD.

SET "PictureConverters\psd" := PSD.InitPicture
SET "Gadgets\Documents\psd" := RembrandtDocs.NewDoc
SET "MIME\image/psd" := psd
