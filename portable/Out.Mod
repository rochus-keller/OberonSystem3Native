(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Out; (** portable *) (* based on module from "Programming in Oberon" *)

(** Simple output routines for writing text into the Oberon log or a seperate viewer. *)

IMPORT Texts, Oberon;

VAR T: Texts.Text; W: Texts.Writer;

(** Write character. *)
PROCEDURE Char*(ch: CHAR);
BEGIN
 Texts.Write(W, ch); Texts.Append(T, W.buf)
END Char;

(** Write a string. *)
PROCEDURE String*(str: ARRAY OF CHAR);
BEGIN
 Texts.WriteString(W, str); Texts.Append(T, W.buf)
END String;

(** Write the integer i in n field positions. *)
PROCEDURE Int*(i, n: LONGINT);
BEGIN
 Texts.WriteInt(W, i, n); Texts.Append(T, W.buf)
END Int;

(** Write the integer i in hexadecimal with a leading space. *)
PROCEDURE Hex*(i: LONGINT);
BEGIN
 Texts.WriteHex(W, i); Texts.Append(T, W.buf)
END Hex;

(** Write the real x in n field positions. *)
PROCEDURE Real*(x: REAL; n: INTEGER);
BEGIN
 Texts.WriteReal(W, x, n); Texts.Append(T, W.buf)
END Real;

(** Write the real x in n field positions in fixed point notation with f fraction digits. *)
PROCEDURE RealFix*(x: REAL; n, f: INTEGER);
BEGIN
 Texts.WriteRealFix(W, x, n, f, 0); Texts.Append(T, W.buf)
END RealFix;

(** Write the longreal x in n field positions. *)
PROCEDURE LongReal*(x: LONGREAL; n: INTEGER);
BEGIN
 Texts.WriteLongReal(W, x, n); Texts.Append(T, W.buf)
END LongReal;

(** Write the longreal x in n field positions in fixed point notation with f fraction digits. *)
PROCEDURE LongRealFix*(x: LONGREAL; n, f: INTEGER);
BEGIN
 Texts.WriteLongRealFix(W, x, n, f, 0); Texts.Append(T, W.buf)
END LongRealFix;

(** Write a carriage return (CR or end-of-line). *)
PROCEDURE Ln*;
BEGIN
 Texts.WriteLn(W); Texts.Append(T, W.buf)
END Ln;

(** Open a separate viewer for output. *)
PROCEDURE Open*;
BEGIN
 IF T = Oberon.Log THEN NEW(T); Texts.Open(T, "") END;
 Oberon.OpenText("Out.Text", T, 400, 200)
END Open;

(** Revert output to the system log. *)
PROCEDURE Close*;
BEGIN
 T := Oberon.Log
END Close;

BEGIN
 Texts.OpenWriter(W);  T := Oberon.Log
END Out.

(** Remarks:

1. Out uses a Writer from module Texts to write output to the log. Writing output using 
Out is slow because the log is updated after every procedure call. For fast and flexible 
output, use module Texts.

2. Out.Open creates a new text and viewer for output.  Once this is done, output can 
be sent to the system log again by executing Close.
*)
