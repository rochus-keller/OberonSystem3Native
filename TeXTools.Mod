MODULE TeXTools; (* pjm *)

(** Simple text-based tools for TeX files. *)

IMPORT Texts, Oberon, Out;

VAR
 w: Texts.Writer;
 verb: ARRAY 10 OF CHAR;

PROCEDURE IsSpecial(ch: CHAR): BOOLEAN;
BEGIN
 RETURN (ch = "#") OR (ch = "$") OR (ch = "%") OR (ch = "&") OR (ch = "_") OR (ch = "{") OR (ch = "}")
END IsSpecial;

PROCEDURE IsVerbatim(ch: CHAR): BOOLEAN;
BEGIN
 RETURN (ch = "~") OR (ch = "^") OR (ch = "\") OR (ch = ">") OR (ch = "<") OR (ch = "|") OR (ch = "*")
END IsVerbatim;

(** Convert selected text in-place from readable text to LaTeX tabbing environment syntax. *)

PROCEDURE Tabbing*; (** ^ *)
VAR text: Texts.Text; beg, end, time: LONGINT; r: Texts.Reader; ch: CHAR;
BEGIN
 Oberon.GetSelection(text, beg, end, time);
 IF time # -1 THEN
  Texts.OpenReader(r, text, beg); Texts.Read(r, ch);
  WHILE ~r.eot & (Texts.Pos(r) <= end) DO
   IF ch = 9X THEN Texts.WriteString(w, "\>")
   ELSIF (ch = 0DX) & (Texts.Pos(r) # end) THEN Texts.WriteString(w, "\\"); Texts.WriteLn(w)
   ELSIF IsSpecial(ch) THEN Texts.Write(w, "\"); Texts.Write(w, ch)
   ELSIF IsVerbatim(ch) THEN Texts.WriteString(w, "\verb"); Texts.Write(w, 22X); Texts.Write(w, ch); Texts.Write(w, 22X)
   ELSE Texts.Write(w, ch)
   END;
   Texts.Read(r, ch)
  END;
  Texts.Insert(text, end, w.buf);
  Texts.Delete(text, beg, end)
 ELSE
  Texts.WriteString(w, "No text selected"); Texts.WriteLn(w);
  Texts.Append(Oberon.Log, w.buf)
 END
END Tabbing;

(** Convert selected text in-place from LaTeX tabbing environment syntax to readable text. *)

PROCEDURE Tabs*;
VAR text: Texts.Text; beg, end, time, i: LONGINT; r: Texts.Reader; ch: CHAR; s: ARRAY 10 OF CHAR;
BEGIN
 Oberon.GetSelection(text, beg, end, time);
 IF time # -1 THEN
  Texts.OpenReader(r, text, beg); Texts.Read(r, ch);
  WHILE ~r.eot & (Texts.Pos(r) <= end) DO
   IF ch = "\" THEN
    Texts.Read(r, ch);
    IF ch = 0X THEN (* skip *)
    ELSIF ch = ">" THEN Texts.Write(w, 9X)
    ELSIF ch = "\" THEN (* skip *)
    ELSIF IsSpecial(ch) THEN Texts.Write(w, ch)
    ELSIF ch = "v" THEN  (* possibly \verb"x" *)
     s := "\v"; i := 2;
     Texts.Read(r, ch);
     WHILE (ch # 0X) & (ch = verb[i]) DO s[i] := ch; INC(i); Texts.Read(r, ch) END;
     IF (ch # 0X) & (verb[i] = 0X) THEN (* full match *)
      s[i] := ch; INC(i); (* starting quote *)
      Texts.Read(r, ch); (* special character *)
      IF IsVerbatim(ch) THEN
       Texts.Write(w, ch);
       Texts.Read(r, ch); (* closing quote *)
       i := 0; ch := 0X
      END
     END;
     s[i] := 0X; Texts.WriteString(w, s);
     IF ch # 0X THEN Texts.Write(w, ch) END
    ELSE Texts.Write(w, "\"); Texts.Write(w, ch)
    END
   ELSE Texts.Write(w, ch)
   END;
   IF ~r.eot THEN Texts.Read(r, ch) END
  END;
  Texts.Insert(text, end, w.buf);
  Texts.Delete(text, beg, end)
 ELSE
  Texts.WriteString(w, "No text selected"); Texts.WriteLn(w);
  Texts.Append(Oberon.Log, w.buf)
 END
END Tabs;

PROCEDURE MergeLines*;
VAR t1, t2: Texts.Text; r1, r2: Texts.Reader; beg, end, time, pos, len: LONGINT; ch: CHAR;
BEGIN
 t1 := Oberon.MarkedText();
 Oberon.GetSelection(t2, beg, end, time);
 IF (t1 # NIL) & (t2 # NIL) & (time # -1) THEN
  Texts.OpenReader(r1, t1, 0); Texts.OpenReader(r2, t2, beg);
  LOOP
   REPEAT Texts.Read(r1, ch) UNTIL r1.eot OR (ch = 0DX);
   IF r1.eot THEN EXIT END;
   pos := Texts.Pos(r1); len := 1;
   Texts.Write(w, " ");
   LOOP
    Texts.Read(r2, ch);
    IF r2.eot OR (ch = 0DX) THEN EXIT END;
    Texts.Write(w, ch); INC(len)
   END;
   Texts.Insert(t1, Texts.Pos(r1)-1, w.buf);
   IF r2.eot THEN EXIT END;
   Texts.OpenReader(r1, t1, pos+len)
  END
 END
END MergeLines;

PROCEDURE SizeTable*;
CONST Total = FALSE;
VAR t1, t2: Texts.Text; s1, s2: Texts.Scanner; i, var, const, code, sum, lines, beg, end, time: LONGINT;
BEGIN
 t1 := Oberon.MarkedText();
 Oberon.GetSelection(t2, beg, end, time);
 IF t1 # NIL THEN
  var := 0; const := 0; code := 0; lines := 0;
  Texts.OpenScanner(s1, t1, 0);
  IF time # -1 THEN Texts.OpenScanner(s2, t2, beg) END;
  LOOP
   Texts.Scan(s1);
   IF s1.class # Texts.Name THEN EXIT END;
   i := 0; WHILE (s1.s[i] # 0X) & (s1.s[i] # ".") DO INC(i) END;
   IF s1.s[i] # "." THEN EXIT END;
   s1.s[i] := 0X;
   IF time # -1 THEN
    Texts.Scan(s2);
    IF s2.class # Texts.Name THEN EXIT END;
    i := 0; WHILE (s2.s[i] # 0X) & (s2.s[i] # ".") DO INC(i) END;
    IF s2.s[i] # "." THEN EXIT END;
    s2.s[i] := 0X;
    IF s1.s # s2.s THEN
     s2.s[i] := ".";
     Out.String(s1.s); Out.Char(" "); Out.String(s2.s); Out.Ln;
     s2.s[i] := 0X
    END
   END;
   Texts.WriteString(w, "\ident{");
   Texts.WriteString(w, s1.s); Texts.WriteString(w, "} &"); Texts.Write(w, 9X);
   sum := 0;
   Texts.Scan(s1); ASSERT((s1.class = Texts.Name) & (s1.s = "var"));
   Texts.Scan(s1); ASSERT(s1.class = Texts.Int);
   Texts.WriteInt(w, s1.i, 1); Texts.WriteString(w, " &"); Texts.Write(w, 9X);
   INC(sum, s1.i); INC(var, s1.i);
   Texts.Scan(s1); ASSERT((s1.class = Texts.Name) & (s1.s = "const"));
   Texts.Scan(s1); ASSERT(s1.class = Texts.Int);
   Texts.WriteInt(w, s1.i, 1); Texts.WriteString(w, " &"); Texts.Write(w, 9X);
   INC(sum, s1.i); INC(const, s1.i);
   Texts.Scan(s1); ASSERT((s1.class = Texts.Name) & (s1.s = "code"));
   Texts.Scan(s1); ASSERT(s1.class = Texts.Int);
   Texts.WriteInt(w, s1.i, 1);
   INC(sum, s1.i); INC(code, s1.i);
   IF Total THEN
    Texts.WriteString(w, " &"); Texts.Write(w, 9X); Texts.WriteInt(w, sum, 1)
   END;
   IF time # -1 THEN
    Texts.WriteString(w, " &"); Texts.Write(w, 9X);
    Texts.Scan(s2); ASSERT(s1.class = Texts.Int);
    Texts.WriteInt(w, s2.i, 1);
    INC(lines, s2.i);
    Texts.Scan(s2); ASSERT(s2.class = Texts.Name)
   END;
   Texts.WriteString(w, " \\"); Texts.WriteLn(w)
  END;
  Texts.Write(w, 9X); Texts.WriteString(w, "\hline"); Texts.WriteLn(w);
  Texts.WriteString(w, "{\em Total} &"); Texts.Write(w, 9X);
  Texts.WriteInt(w, var, 1); Texts.WriteString(w, " &"); Texts.Write(w, 9X);
  Texts.WriteInt(w, const, 1); Texts.WriteString(w, " &"); Texts.Write(w, 9X);
  Texts.WriteInt(w, code, 1);
  IF Total THEN
   Texts.WriteString(w, " &"); Texts.Write(w, 9X); Texts.WriteInt(w, var+const+code, 1)
  END;
  IF time # -1 THEN
   Texts.WriteString(w, " &"); Texts.Write(w, 9X);
   Texts.WriteInt(w, lines, 1)
  END;
  Texts.WriteString(w, " \\"); Texts.WriteLn(w);
  NEW(t1); Texts.Open(t1, "");
  Texts.Append(t1, w.buf);
  Oberon.OpenText("", t1, 400, 400)
 END
END SizeTable;

PROCEDURE TableTotal*;
VAR t1: Texts.Text; s1: Texts.Scanner; var, const, code, lines, beg, end, time: LONGINT;
BEGIN
 Oberon.GetSelection(t1, beg, end, time);
 IF time # -1 THEN
  var := 0; const := 0; code := 0; lines := 0;
  Texts.OpenScanner(s1, t1, beg);
  LOOP
   Texts.Scan(s1);
   IF s1.class # Texts.Name THEN EXIT END;
   REPEAT Texts.Scan(s1) UNTIL s1.class # Texts.Name;
   ASSERT((s1.class = Texts.Char) & (s1.c = "&"));
   Texts.Scan(s1); ASSERT(s1.class = Texts.Int);
   INC(var, s1.i);
   Texts.Scan(s1); ASSERT((s1.class = Texts.Char) & (s1.c = "&"));
   Texts.Scan(s1); ASSERT(s1.class = Texts.Int);
   INC(const, s1.i);
   Texts.Scan(s1); ASSERT((s1.class = Texts.Char) & (s1.c = "&"));
   Texts.Scan(s1); ASSERT(s1.class = Texts.Int);
   INC(code, s1.i);
   Texts.Scan(s1); ASSERT((s1.class = Texts.Char) & (s1.c = "&"));
   Texts.Scan(s1); ASSERT(s1.class = Texts.Int);
   INC(lines, s1.i);
   Texts.Scan(s1); ASSERT((s1.class = Texts.Char) & (s1.c = "\"));
   Texts.Scan(s1); ASSERT((s1.class = Texts.Char) & (s1.c = "\"))
  END;
  Texts.WriteString(w, "{\em Total} &"); Texts.Write(w, 9X);
  Texts.WriteInt(w, var, 1); Texts.WriteString(w, " &"); Texts.Write(w, 9X);
  Texts.WriteInt(w, const, 1); Texts.WriteString(w, " &"); Texts.Write(w, 9X);
  Texts.WriteInt(w, code, 1); Texts.WriteString(w, " &"); Texts.Write(w, 9X);
  Texts.WriteInt(w, lines, 1); Texts.WriteString(w, " \\"); Texts.WriteLn(w);
  Texts.Append(Oberon.Log, w.buf)
 END
END TableTotal;

BEGIN
 Texts.OpenWriter(w);
 verb := "\verb"
END TeXTools.

(*
to do:
o > and < should really be math mode
*)

System.Free TeXTools ~

TeXTools.Tabbing
TeXTools.Tabs
TeXTools.MergeLines
TeXTools.SizeTable
TeXTools.TableTotal
