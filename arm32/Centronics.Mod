(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Centronics; (** dummy *) 

(* Native version *)

IMPORT Kernel, Input, SYSTEM;

CONST 
 LPT1* = 0;
 LPT2* = 1;
 LPT3* = 2; 

PROCEDURE Halt(msg: ARRAY OF CHAR);
VAR error: ARRAY 32 OF CHAR;
BEGIN
 COPY(msg, error);
 HALT(99)
END Halt;

(** Start - Open parallel port. *)

PROCEDURE Start*(port: INTEGER);
BEGIN
 Halt("Not implemented")
END Start;

(** Reset - Reset parallel port. *)

PROCEDURE Reset*(port: INTEGER);
BEGIN
 Halt("Not implemented")
END Reset;

(** Stop - Close parallel port. *)

PROCEDURE Stop*(port: INTEGER);
BEGIN
 Halt("Not implemented")
END Stop;

(** Send - Send byte to parallel port, waiting until it is ready. *)

PROCEDURE Send*(port: INTEGER; x: CHAR);
BEGIN
 Halt("Not implemented")
END Send;

(** SendPoll - Send byte to parallel port.  done indicates success or failure. *)

PROCEDURE SendPoll*(port: INTEGER;  x: CHAR;  VAR done: BOOLEAN);
BEGIN
 Halt("Not implemented")
END SendPoll;

(** Available - Returns number of bytes available for reading (implementation optional). *)

PROCEDURE Available*(port: INTEGER): LONGINT;
BEGIN
 Halt("Not implemented")
END Available;

(** Receive - Read a byte from the parallel port (implementation optional). *)

PROCEDURE Receive*(port: INTEGER; VAR x: CHAR);
BEGIN
 Halt("Not implemented")
END Receive;

END Centronics.
