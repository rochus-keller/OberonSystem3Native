(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Strip;

IMPORT
 Out, Files, Texts, Oberon;

(* keeps only the symbol file of an object file *)
PROCEDURE StripObj (FromN, ToN: ARRAY OF CHAR);
 VAR FromF, ToF: Files.File; From, To: Files.Rider; ch:CHAR; i, version: LONGINT;
BEGIN
 Out.String (FromN);
 IF FromN # ToN THEN Out.String (" => "); Out.String (ToN) END;
 Out.Ln;
 FromF := Files.Old (FromN); ToF := Files.New (ToN);
 IF FromF = NIL THEN
  Out.String (FromN); Out.String (" doesn't exist "); Out.Ln; HALT (99)
 END;
 Files.Set (From, FromF, 0); Files.Set (To, ToF, 0);
 Files.Read (From, ch); Files.Write (To, ch);
 IF ch # 0BBX THEN
  Out.String (FromN); Out.String(": wrong file type"); Out.Ln; HALT (99)
 END;
 Files.Read (From, ch); Files.Write (To, ch); version := ORD (ch);
 Files.ReadNum (From, i); Files.WriteNum (To, i);
 WHILE i > 0 DO
  Files.Read (From, ch); Files.Write (To, ch); DEC (i)
 END;
 Files.Register (ToF); Files.Close (ToF); Files.Close (FromF)
END StripObj;

(* keeps only the object file of an object file *)
PROCEDURE StripSym (FromN, ToN: ARRAY OF CHAR);
 VAR FromF, ToF: Files.File; From, To: Files.Rider; ch:CHAR; i, version: LONGINT;
BEGIN
 Out.String (FromN);
 IF FromN # ToN THEN Out.String (" => "); Out.String (ToN) END;
 Out.Ln;
 FromF := Files.Old (FromN); ToF := Files.New (ToN);
 IF FromF = NIL THEN
  Out.String (FromN); Out.String (" doesn't exist "); Out.Ln; HALT (99)
 END;
 Files.Set (From, FromF, 0); Files.Set (To, ToF, 0);
 Files.Read (From, ch); Files.Write (To, ch);
 IF ch # 0BBX THEN
  Out.String (FromN); Out.String(": wrong file type"); Out.Ln; HALT (99)
 END;
 Files.Read (From, ch); Files.Write (To, ch); version := ORD (ch);
 Files.ReadNum (From, i); Files.WriteNum (To, 0);
 Files.Set(From, FromF, Files.Pos(From)+i);
 Files.Read (From, ch);
 WHILE ~From.eof DO
  Files.Write (To, ch); Files.Read (From, ch);
 END;
 Files.Register (ToF); Files.Close (ToF); Files.Close (FromF)
END StripSym;

PROCEDURE DoStrip(proc: PROCEDURE(FromN, ToN: ARRAY OF CHAR));
 VAR S: Texts.Scanner; from: ARRAY 64 OF CHAR;
BEGIN
 Texts.OpenScanner (S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan (S);
 WHILE ~S.eot & (S.class = Texts.Name) DO
  COPY (S.s, from); Texts.Scan (S);
  IF (S.class = Texts.Char) & (S.c = "=") THEN
   Texts.Scan (S);
   IF (S.class = Texts.Char) & (S.c = ">") THEN
    Texts.Scan (S);
    proc (from, S.s);
    Texts.Scan (S);
   ELSE HALT (99)
   END
  ELSE proc (from, from)
  END 
 END;
END DoStrip;

PROCEDURE Sym*; (** Remove Symbol file information from a file*)
BEGIN DoStrip(StripSym)
END Sym;

PROCEDURE Obj*; (** Remove Object file information from a file*)
BEGIN DoStrip(StripObj)
END Obj;

END Strip.
