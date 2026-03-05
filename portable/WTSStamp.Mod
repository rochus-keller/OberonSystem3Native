(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE WTSStamp; (** portable *)

IMPORT
 TimeStamps;
 
PROCEDURE New*;
BEGIN TimeStamps.New
END New;

END WTSStamp.