(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Hyphen; (* ejz,   *)
 IMPORT SYSTEM, Files, Texts, Oberon;

 CONST
  FileSize = 48000;
  HashTabSize = 4096;

 VAR
  hyphen: POINTER TO ARRAY FileSize OF CHAR;
  hashTab: POINTER TO ARRAY HashTabSize OF LONGINT;
  W: Texts.Writer;

 PROCEDURE LowCase(ch: CHAR): CHAR;
 BEGIN
  IF (ch >= "A") & (ch <= "Z") THEN
   RETURN CHR(ORD(ch)-ORD("A")+ORD("a"))
  ELSE
   RETURN ch
  END
 END LowCase;

 PROCEDURE HashCode(VAR str: ARRAY OF CHAR; beg, end: LONGINT): LONGINT;
  VAR
   i, code: LONGINT;
   ch: CHAR;
 BEGIN
  i := beg; code := 0;
  ch := str[i];
  WHILE (ch # 0X) & (i <= end) DO
   IF (ch >= "a") & (ch <= "z") THEN
    code := SYSTEM.ROT(code+ORD(ch), 1)
   END;
   INC(i); ch := str[i]
  END;
  RETURN code MOD HashTabSize
 END HashCode;

(** Returns all possible hyphenation positions for hword. *)
 PROCEDURE Word*(VAR hword: ARRAY OF CHAR; VAR hyphpos: ARRAY OF LONGINT);
  VAR
   i, j, k, l, code, pos, beg: LONGINT;
   hyph: ARRAY 64 OF LONGINT;
   word: ARRAY 64 OF CHAR;
   ch: CHAR;
 BEGIN
  FOR i := 0 TO LEN(hyph)-1 DO
   hyph[i] := 0
  END;
  word[0] := "."; l := 0;
  WHILE hword[l] # 0X DO
   word[l+1] := LowCase(hword[l]); INC(l)
  END;
  INC(l); word[l] := "."; INC(l); word[l] := 0X;
  FOR i := 2 TO l DO
   FOR j := 0 TO l-i DO
    code := HashCode(word, j, j+i-1);
    IF hashTab[code] >= 0 THEN
     beg := -1; pos := hashTab[code]; ch := hyphen[pos];
     WHILE (beg < 0) & (ch # 0X) DO
      beg := pos; ch := hyphen[pos]; k := j;
      WHILE ch # 0X DO
       IF (ch < "0") OR (ch > "9") THEN
        IF word[k] # ch THEN
         beg := -1
        END;
        INC(k)
       END;
       INC(pos); ch := hyphen[pos]
      END;
      INC(pos); ch := hyphen[pos]
     END;
     IF beg >= 0 THEN
      k := 0; pos := beg; ch := hyphen[pos];
      WHILE ch # 0X DO
       IF (ch >= "0") & (ch <= "9") THEN
        IF ORD(ch) > hyph[j-k+pos-beg] THEN
         hyph[j-k+pos-beg] := ORD(ch)
        END;
        INC(k)
       END;
       INC(pos); ch := hyphen[pos]
      END
     END
    END
   END
  END;
  hyph[0] := 0; hyph[1] := 0; hyph[2] := 0;
  hyph[l-2] := 0; hyph[l-1] := 0; hyph[l] := 0;
  j := 0; i := 1;
  WHILE word[i+1] # 0X DO
   IF (hyph[i] MOD 2) # 0 THEN
    hyphpos[j] := i-1; INC(j)
   END;
   INC(i)
  END;
  hyphpos[j] := -1
 END Word;

(** Loads hyphenation patterns *) 
 PROCEDURE Load*(pattext: ARRAY OF CHAR);
  VAR
   T: Texts.Text;
   R: Texts.Reader;
   pat: ARRAY 32 OF CHAR;
   i, code, pos: LONGINT;
   ch: CHAR;
 BEGIN
  FOR i := 0 TO HashTabSize-1 DO
   hashTab[i] := -1
  END;
  pos := 0;
  NEW(T); Texts.Open(T, pattext);
  Texts.OpenReader(R, T, 0); Texts.Read(R, ch);
  WHILE ~R.eot DO
   i := 0;
   WHILE ~R.eot & (ch >= " ") DO
    pat[i] := ch; INC(i);
    Texts.Read(R, ch)
   END;
   pat[i] := 0X;
   code := HashCode(pat, 0, MAX(INTEGER));
   IF hashTab[code] < 0 THEN
    hyphen[pos] := 0X; INC(pos);
    hashTab[code] := pos
   END;
   i := 0;
   WHILE pat[i] # 0X DO
    hyphen[pos] := pat[i];
    INC(pos); INC(i)
   END;
   hyphen[pos] := 0X; INC(pos);
   Texts.Read(R, ch);
   WHILE ~R.eot & (ch <= " ") DO
    Texts.Read(R, ch)
   END
  END;
  hyphen[pos] := 0X
 END Load;

(** Hyphen.LoadPats oberonfile
 Loads hyphenation patterns *)
 PROCEDURE LoadPats*;
  VAR S: Texts.Scanner;
 BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Texts.Scan(S);
  IF S.class IN {Texts.Name, Texts.String} THEN
   Load(S.s)
  END
 END LoadPats;

(** Hyphen.Word word
 Show all possible hyphenations for word *)
 PROCEDURE ShowWord*;
  VAR
   S: Texts.Scanner;
   hyphpos: ARRAY (*LEN(S.s)*) 64 OF LONGINT;
   i, j: LONGINT;
 BEGIN
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Texts.Scan(S);
  IF S.class IN {Texts.Name, Texts.String} THEN
   Word(S.s, hyphpos);
   i := 0; j := 0;
   WHILE S.s[i] # 0X DO
    IF hyphpos[j] = i THEN
     Texts.Write(W, "-"); INC(j)
    END;
    Texts.Write(W, S.s[i]); INC(i)
   END;
   Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
  END
 END ShowWord;

(** Hyphen.Convert texfile oberonfile
 Converts a tex hyphenation file into an oberon hyphenation file.
 Note: If you want to change a hyphen file re-run Hyphen.Convert on the changed hyphenation file. *)
 PROCEDURE Convert*;
  VAR
   S: Texts.Scanner;
   T, Ts: Texts.Text;
   R: Texts.Reader;
   F: Files.File;
   pat: ARRAY 32 OF CHAR;
   i, j, code, pats, len: LONGINT;
   ch: CHAR;
 BEGIN
  FOR i := 0 TO HashTabSize-1 DO
   hashTab[i] := -1
  END;
  Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
  Texts.Scan(S);
  NEW(T); Texts.Open(T, S.s);
  NEW(Ts); Texts.Open(Ts, "");
  Texts.OpenReader(R, T, 0); Texts.Read(R, ch);
  pats := 0;
  WHILE ~R.eot DO
   j := 0;
   WHILE ~R.eot & (ch >= " ") DO
    pat[j] := ch; INC(j); Texts.Read(R, ch)
   END;
   IF j >= 2 THEN
    pat[j] := 0X; INC(pats);
    IF (pats MOD 100) = 0 THEN
     Texts.Write(W, "."); Texts.Append(Oberon.Log, W.buf)
    END;
    code := HashCode(pat, 0, MAX(INTEGER));
    Texts.WriteString(W, pat); Texts.WriteLn(W);
    IF hashTab[code] >= 0 THEN
     Texts.Insert(Ts, hashTab[code], W.buf);
     FOR i := 0 TO HashTabSize-1 DO
      IF hashTab[i] > hashTab[code] THEN
       hashTab[i] := hashTab[i]+j+1
      END
     END;
     hashTab[code] := hashTab[code]+ j+1
    ELSE
     Texts.Append(Ts, W.buf); hashTab[code] := Ts.len
    END;
    Texts.Read(R, ch);
    WHILE ~R.eot & (ch <= " ") DO
     Texts.Read(R, ch)
    END
   ELSIF j > 0 THEN
    HALT(99)
   ELSE
    R.eot := TRUE
   END
  END;
  Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf);
  Texts.Scan(S); F := Files.New(S.s);
  Texts.Store(Ts, F, 0, len); Files.Register(F)
 END Convert;

(*
 PROCEDURE GetMarked(VAR T: Texts.Text);
  VAR
   F, V: Display.Frame;
   obj: Objects.Object;
   u, v: INTEGER;
 BEGIN
  T := NIL;
  Gadgets.ThisFrame(Oberon.Pointer.X, Oberon.Pointer.Y, F, u, v);
  IF F = NIL THEN
   V := Oberon.MarkedViewer();
   IF (V # NIL) & (V.dsc # NIL) THEN
    F := V.dsc.next
   END
  END;
  IF F # NIL THEN
   Links.GetLink(F, "Model", obj);
   IF (obj # NIL) & (obj IS Texts.Text) THEN
    T := obj(Texts.Text)
   END
  END
 END GetMarked;

 PROCEDURE AllText*;
  CONST HyphenCh = 01FX;
  VAR
   T: Texts.Text;
   S: Texts.Scanner;
   hyphpos: ARRAY LEN(S.s) OF LONGINT;
   pos, i, j: LONGINT;
   R: Texts.Reader;
   ch: CHAR;
 BEGIN
  GetMarked(T);
  IF T # NIL THEN
   Texts.OpenScanner(S, T, 0);
   pos := Texts.Pos(S)-1; Texts.Scan(S);
   WHILE ~S.eot DO
    IF S.class = Texts.Name THEN
     Word(S.s, hyphpos);
     i := 0; j := 0;
     Texts.OpenReader(R, T, pos);
     Texts.Read(R, ch);
     WHILE ch > " " DO
      IF hyphpos[j] = i THEN
       Texts.Write(W, HyphenCh);
       Texts.Insert(T, pos+i+j-1, W.buf);
       INC(j); Texts.OpenReader(R, T, pos+i+j)
      END;
      INC(i); Texts.Read(R, ch)
     END;
     Texts.OpenScanner(S, T, Texts.Pos(R))
    END;
    pos := Texts.Pos(S); Texts.Scan(S)
   END
  END
 END AllText;
*)

BEGIN
 NEW(hashTab); NEW(hyphen);
 Texts.OpenWriter(W)
END Hyphen.

!Hyphen.Convert HyphenD.TeX HyphenDS.Text

!Hyphen.Convert HyphenE.TeX HyphenES.Text


Hyphen.LoadPats HyphenES.Text

Hyphen.ShowWord implementation
Hyphen.ShowWord Oberon
Hyphen.ShowWord system
Hyphen.ShowWord release
Hyphen.ShowWord gadgets


Hyphen.LoadPats HyphenDS.Text

Hyphen.ShowWord Rechtschreibung
Hyphen.ShowWord Ichneumoniden
Hyphen.ShowWord "wässerlein"
Hyphen.ShowWord "wässerigkeit"
Hyphen.ShowWord "Atmosphäre"
Hyphen.ShowWord Publikum
