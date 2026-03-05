(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE CD; (** non-portable *)

VAR
 devID*: INTEGER;

PROCEDURE Error;
VAR error: ARRAY 32 OF CHAR;
BEGIN
 error := "No CD configured";  HALT(99)
END Error;
 
PROCEDURE Eject*;
BEGIN
 Error
END Eject;

PROCEDURE Stop*;
BEGIN
 Error
END Stop;

PROCEDURE Load*;
BEGIN
 Error
END Load;

PROCEDURE Pause*;
BEGIN
 Error
END Pause;

PROCEDURE Resume*;
BEGIN
 Error
END Resume;

PROCEDURE ReadTocHdr*(VAR first, last: INTEGER);
BEGIN
 Error
END ReadTocHdr;

PROCEDURE ReadTocEntry*(track: INTEGER; VAR min, sec, frame: INTEGER);
BEGIN
 Error
END ReadTocEntry;

PROCEDURE Play*(min0, sec0, frame0, min1, sec1, frame1: INTEGER);
BEGIN
 Error
END Play;

PROCEDURE ReadLen*(VAR len: LONGINT);
BEGIN
 Error
END ReadLen;

PROCEDURE Sense*(VAR acs, acsq: CHAR);
BEGIN
 Error
END Sense;

PROCEDURE GetPosition*(VAR track, minute, second: INTEGER);
BEGIN
 Error
END GetPosition;

PROCEDURE MediumType*(VAR medtyp: CHAR);
BEGIN
 Error
END MediumType;

BEGIN
 devID := -1
END CD.

