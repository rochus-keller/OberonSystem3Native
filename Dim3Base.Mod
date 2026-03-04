(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Dim3Base; (** portable *) (* David Ulrich Nov  95 - März 96 *)
(* This module contains not portable procedures for the Native version **)

IMPORT S := SYSTEM, Pictures;
CONST Black* = 15; White* = 0; (** black and white of the windows color table **)
VAR
 baseAdr, lineW, height: LONGINT;

(** correct color table for Native version **)
PROCEDURE CheckColorTab*(VAR R, G, B: ARRAY OF INTEGER);
BEGIN
 (* nothing to do *)
END CheckColorTab;

(** convert color number to Dim3 color palette **)
PROCEDURE GetRealColor*(color: INTEGER):INTEGER;
BEGIN
 RETURN color
END GetRealColor;

(** calculate picture addresses **)
PROCEDURE SetPicture*(P: Pictures.Picture);
BEGIN
 baseAdr := P.address;
 lineW := P.width; height := P.height;
END SetPicture;

(** get address of position X in current scanline Y of actual picture **)
PROCEDURE GetAddress*(X, Y: INTEGER): LONGINT;
BEGIN
 RETURN baseAdr + lineW * Y + X;
END GetAddress;

(** ReplConst in previosly set picture with mode replace, H = 1 **)
PROCEDURE ReplConst*(col, X, Y, W: INTEGER);
VAR col4: SET; color: CHAR; pictAdr: LONGINT; color4: ARRAY 4 OF CHAR;
BEGIN
 color := CHR(col);
 color4[0] := color; color4[1] := color; color4[2] := color; color4[3] := color; 
 col4 := S.VAL(SET, color4);
 pictAdr := baseAdr + lineW * Y + X;
 WHILE W > 4 DO S.PUT(pictAdr, col4); DEC(W, 4); INC(pictAdr, 4) END;
 WHILE W > 0 DO S.PUT(pictAdr, color); DEC(W); INC(pictAdr) END;
END ReplConst;

END Dim3Base.