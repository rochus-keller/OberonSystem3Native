(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

 MODULE FileDir; (* pjm *)

(* Native-compatible FileDir module based on OFS *)

IMPORT OFS;

TYPE
 FileName* = OFS.FileName;
 
 EntryHandler* = PROCEDURE (name: ARRAY OF CHAR; time, date, size: LONGINT; VAR continue: BOOLEAN);

VAR
 PathChar*: CHAR;
 handler: EntryHandler;

PROCEDURE Handler(name: ARRAY OF CHAR; time, date, size: LONGINT; VAR flags: SET);
VAR b: BOOLEAN;
BEGIN
 IF ~(OFS.EnumSize IN flags) THEN size := MIN(LONGINT) END;
 b := TRUE; handler(name, time, date, size, b);
 IF ~b THEN INCL(flags, OFS.EnumStop) END
END Handler;

(** Enumerate files matching the mask.  proc is upcalled for every file.  Iff detail is TRUE, the time, date and size parameters will be valid.  Recursive calls to Enumerate are not allocated in proc. *)
PROCEDURE Enumerate*(mask: ARRAY OF CHAR; detail: BOOLEAN; proc: EntryHandler);
VAR flags: SET;
BEGIN
 IF detail THEN flags := {OFS.EnumSize, OFS.EnumTime} ELSE flags := {} END;
 handler := proc;
 OFS.Enumerate(mask, flags, Handler)
END Enumerate;

(** Compare two filenames. *)
PROCEDURE SameName*(VAR a, b: ARRAY OF CHAR): BOOLEAN;
BEGIN
 RETURN a = b (* to do: improve implementation to check underlying file system *)
END SameName;

BEGIN
 PathChar := "/"
END FileDir.
