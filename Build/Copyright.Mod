(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Copyright; (** portable *)
 IMPORT Files, Fonts, Texts, Oberon;

 CONST
  Tag = "(*! "; (* 4 characters *)
  
 VAR
  W: Texts.Writer;

 PROCEDURE Check(T: Texts.Text);
  VAR
   R: Texts.Reader;
   copy: ARRAY 5 OF CHAR;
   ch: CHAR;
 BEGIN
  Texts.OpenReader(R, T, 0);
  Texts.Read(R, copy[0]); Texts.Read(R, copy[1]);
  Texts.Read(R, copy[2]); Texts.Read(R, copy[3]);
  copy[4] := 0X;
  IF (copy # "(*$C") & (copy # Tag) & (copy # "(* O") & (copy # "(* E") THEN HALT(99) END;
  Texts.Read(R, ch);
  WHILE ~R.eot & (ch # "*") DO Texts.Read(R, ch) END;
  IF ch # "*" THEN HALT(99) END;
  Texts.Read(R, ch);
  IF ch # ")" THEN HALT(99) END;
  Texts.Read(R, ch);
  WHILE ~R.eot & ((ch = " ") OR (ch = 9X) OR (ch = 0DX)) DO Texts.Read(R, ch) END;
  IF ~R.eot THEN HALT(99) END
 END Check;

 PROCEDURE GetName(VAR name: ARRAY OF CHAR);
 VAR f: Files.File;
 BEGIN
  f := Files.Old(name);
  IF f # NIL THEN Files.GetName(f, name) END
 END GetName;

 PROCEDURE Scan(VAR S: Texts.Scanner);
 BEGIN
  Texts.Scan(S);
  IF (S.class = Texts.Char) & (S.c = Oberon.OptionChar) THEN
   Texts.Scan(S);  Texts.Scan(S)
  END
 END Scan;
 
 PROCEDURE Add*;
  VAR
   S: Texts.Scanner;
   C, T: Texts.Text;
   B: Texts.Buffer;
   F: Files.File;
   len: LONGINT;
 BEGIN
  NEW(C); Texts.Open(C, "Copyright.Text"); Check(C);
  NEW(B); Texts.OpenBuf(B);
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Scan(S);
  WHILE S.class IN {Texts.Name, Texts.String} DO
   GetName(S.s);
   Texts.Save(C, 0, C.len, B);
   Texts.WriteString(W, S.s); Texts.Append(Oberon.Log, W.buf);
   NEW(T); Texts.Open(T, S.s);
   Texts.Insert(T, 0, B);
   F := Files.New(S.s); len := 0;
   Texts.Store(T, F, 0, len); Files.Register(F);
   Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
   Scan(S)
  END
 END Add;

 PROCEDURE Remove*;
  VAR
   S: Texts.Scanner;
   T: Texts.Text;
   F: Files.File;
   len: LONGINT;
   R: Texts.Reader;
   copy, copy2: ARRAY 5 OF CHAR;
   ch: CHAR;
 BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Scan(S); copy[4] := 0X;  copy2[3] := 0X;
  WHILE S.class IN {Texts.Name, Texts.String} DO
   GetName(S.s);
   Texts.WriteString(W, S.s); Texts.Append(Oberon.Log, W.buf);
   NEW(T); Texts.Open(T, S.s);
   Texts.OpenReader(R, T, 0);
   Texts.Read(R, copy[0]); Texts.Read(R, copy[1]);
   Texts.Read(R, copy[2]); Texts.Read(R, copy[3]);
   IF (copy = "(* O") OR (copy = "(* E") THEN
    Texts.Read(R, copy2[0]); Texts.Read(R, copy2[1]);  Texts.Read(R, copy2[2])
   END;
   IF (copy = "(*$C") OR (copy = Tag) OR ((copy = "(* O") & (copy2 = "BER")) OR ((copy = "(* E") & (copy2 = "TH ")) THEN
    WHILE ~R.eot & (ch # "*") DO
     Texts.Read(R, ch)
    END;
    IF ch = "*" THEN
     Texts.Read(R, ch); Texts.Read(R, ch);
     WHILE ~R.eot & (ch <= " ") & (R.lib IS Fonts.Font) DO
      Texts.Read(R, ch)
     END
    END;
    Texts.Delete(T, 0, Texts.Pos(R)-1);
    F := Files.New(S.s); len := 0;
    Texts.Store(T, F, 0, len);
    Files.Register(F);
   ELSE
    Texts.WriteString(W, " no copyright found")
   END;
   Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
   Scan(S)
  END
 END Remove;

 PROCEDURE Replace*;
  VAR
   S: Texts.Scanner;
   C, T: Texts.Text;
   B: Texts.Buffer;
   F: Files.File;
   len: LONGINT;
   R: Texts.Reader;
   copy, copy2: ARRAY 5 OF CHAR;
   ch: CHAR;
 BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Scan(S); copy[4] := 0X;  copy2[3] := 0X;
  NEW(C); Texts.Open(C, "Copyright.Text");  Check(C);
  NEW(B); Texts.OpenBuf(B);
  WHILE S.class IN {Texts.Name, Texts.String} DO
   GetName(S.s);
   Texts.WriteString(W, S.s); Texts.Append(Oberon.Log, W.buf);
   NEW(T); Texts.Open(T, S.s);
   Texts.OpenReader(R, T, 0);
   Texts.Read(R, copy[0]); Texts.Read(R, copy[1]);
   Texts.Read(R, copy[2]); Texts.Read(R, copy[3]);
   IF (copy = "(* O") OR (copy = "(* E") THEN
    Texts.Read(R, copy2[0]); Texts.Read(R, copy2[1]);  Texts.Read(R, copy2[2])
   END;
   IF (copy = "(*$C") OR (copy = Tag) OR ((copy = "(* O") & (copy2 = "BER")) OR ((copy = "(* E") & (copy2 = "TH ")) THEN
    WHILE ~R.eot & (ch # "*") DO
     Texts.Read(R, ch)
    END;
    IF ch = "*" THEN
     Texts.Read(R, ch); Texts.Read(R, ch);
     WHILE ~R.eot & (ch <= " ") & (R.lib IS Fonts.Font) DO
      Texts.Read(R, ch)
     END
    END;
    Texts.Delete(T, 0, Texts.Pos(R)-1);
    Texts.Save(C, 0, C.len, B);
    Texts.Insert(T, 0, B);
    F := Files.New(S.s); len := 0;
    Texts.Store(T, F, 0, len);
    Files.Register(F);
   ELSE
    Texts.WriteString(W, " no copyright found")
   END;
   Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
   Scan(S)
  END
 END Replace;
 
BEGIN
 Texts.OpenWriter(W)
END Copyright.

Copyright.Add Copyright.Mod ~
Copyright.Remove Copyright.Mod ~
Copyright.Replace Copyright.Mod ~

Copyright.Text

System.Directory *.Mod
