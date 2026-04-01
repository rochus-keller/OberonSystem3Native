(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE V24; (** portable *) (* pjm/ejz/me@rochus-keller.ch *)

(** V24/RS232 serial communications interface, all stubs *)

IMPORT SYSTEM, Kernel;

CONST
 (** port aliases  (check with NumberOfPorts) *)
 COM1* = 0;  COM2* = 1;  COM3* = 2;  COM4* = 3;
 
 (** parity *)
 ParNo* = 0;  ParOdd* = 1;  ParEven* = 2;  ParMark* = 3;  ParSpace* = 4;
 (** stop bits *)
 Stop1* = 1;  Stop2* = 2;  Stop1dot5* = 3;
 (** modem control - MC *)
 DTR* = 0;  RTS* = 1; (** output *)
 Break* = 2; (** input/output *)
 DSR* = 3;  CTS* = 4;  RI* = 5;  DCD* = 6; (** input *)
 
 Ok* =  0; PortInUse* =  1; NoSuchPort* =  2; WrongBPS* =  3; WrongData* =  4; WrongParity* =  5;
 WrongStop* =  6; Failed* =  MAX(INTEGER);
  

(** NumberOfPorts - Return the number of ports present - 0 to 4. *)

PROCEDURE NumberOfPorts*(): LONGINT;
BEGIN
 RETURN 0
END NumberOfPorts;

(** Start - Open a serial port (numbered from 0).  bps is the required bits per second.
 data is the number of bits per communication unit.  parity is the parity mode (Par 
 values above).  stop is the number of stop bits (Stop values above).  res returns 0 
 if ok, or error code on error.  1 means port already in use.  2 means no such port.  
 3 means bad bps value.  4 means bad data/parity/stop.   DTR and RTS are enabled. *)
 
PROCEDURE Start*(port, bps, data, parity, stop: LONGINT;  VAR res: LONGINT);
BEGIN
 res := NoSuchPort (* no such port *)
END Start;

(** Stop - Close the specified port.  Effect on Modem Control lines is undefined. *)

PROCEDURE Stop*(port: LONGINT);
BEGIN

END Stop;

(** Available - Return the number of bytes available in the specified port's buffer. *)

PROCEDURE Available*(port: LONGINT): LONGINT;
BEGIN
 RETURN 0
END Available;

(** Receive - Read one byte from the specified port.  Waits until a byte is available.  res = Ok iff ok. *)

PROCEDURE Receive*(port: LONGINT;  VAR x: SYSTEM.BYTE;  VAR res: LONGINT);
BEGIN
 res := Ok
END Receive;

(** ReceiveBytes - Read n bytes from the specified port.  Waits until n bytes are available.  res = Ok iff ok. *)

PROCEDURE ReceiveBytes*(port: LONGINT;  VAR x: ARRAY OF SYSTEM.BYTE;  n: LONGINT;  VAR res: LONGINT);
BEGIN

END ReceiveBytes;

(** Send - Send a byte to the specified port.  Waits until buffer space is available.  res = Ok iff ok. *)

PROCEDURE Send*(port: LONGINT;  x: SYSTEM.BYTE;  VAR res: LONGINT);
BEGIN

END Send;

(** SendBytes - Send n bytes to the specified port.  Waits until buffer space is available.  res = Ok iff all ok. *)

PROCEDURE SendBytes*(port: LONGINT;  VAR x: ARRAY OF SYSTEM.BYTE;  n: LONGINT;  VAR res: LONGINT);
BEGIN

END SendBytes;

(** ClearMC - Clear the specified Modem Control lines of the specified port.  s may contain DTR, RTS & Break. *)

PROCEDURE ClearMC*(port: LONGINT;  s: SET);
BEGIN

END ClearMC;

(** SetMC - Set the specified Modem Control lines of the specified port.  s may contain DTR, RTS & Break. *)

PROCEDURE SetMC*(port: LONGINT;  s: SET);
BEGIN

END SetMC;

(** GetMC - Return the state of the specified Modem Control lines of the specified port.  s contains
 the current state of DSR, CTS, RI, DCD & Break. *)
 
PROCEDURE GetMC*(port: LONGINT;  VAR s: SET);
BEGIN

END GetMC;

(** Attempt to detect a serial port at the specified I/O base address. *)

PROCEDURE Present*(base: LONGINT): BOOLEAN; (** non-portable *)
BEGIN

END Present;

END V24.
