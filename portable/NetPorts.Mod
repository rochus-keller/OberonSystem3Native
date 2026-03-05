(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE NetPorts; (** non-portable *) (* 16.08.96 mg *)

IMPORT SYSTEM, NetIP;

CONST
 anyport* = 0; minport = 1023; maxport = 2000;

 passive* = 0; active* = 1; conctless* = 3;
  
TYPE
 Port* = POINTER TO PortDesc;
 
 PortDesc* = RECORD
  lport*, rport*: INTEGER;
  lip*, rip*: NetIP.Adr;
  mode: SHORTINT;
  next: Port
 END;

 EntryHandler = PROCEDURE (port: Port);

VAR
 ports: Port;
 portnr: INTEGER;

PROCEDURE Available* (lip: NetIP.Adr; VAR lport: INTEGER; rip: NetIP.Adr; rport: INTEGER): BOOLEAN;
VAR
 curr: Port;
 oldnr: INTEGER;
BEGIN
 IF lport = 0 THEN oldnr := portnr;
  REPEAT
   IF portnr = maxport THEN portnr := minport ELSE INC(portnr) END;
   curr := ports.next;
   WHILE (curr # ports) & (curr.lport # portnr) DO curr := curr.next END
  UNTIL (curr = ports) OR (portnr = oldnr);
  lport := portnr
 ELSE oldnr := 0;
  curr := ports.next;
  LOOP
   IF curr = ports THEN EXIT END;
   IF (SYSTEM.VAL(LONGINT, curr.rip) = SYSTEM.VAL(LONGINT, rip)) & (curr.lport = lport) & (curr.rport = rport) THEN
    EXIT
   END;
   curr := curr.next
  END
 END;
 RETURN (curr = ports) & ~(portnr = oldnr)
END Available;

PROCEDURE Access* (port: Port; lip: NetIP.Adr; loc: INTEGER; rip: NetIP.Adr; rmt: INTEGER; mode: SHORTINT): BOOLEAN;
BEGIN port.mode := mode;
 port.lport := loc; port.rport := rmt;
 port.lip := lip; port.rip := rip;
 port.next := ports.next; ports.next := port;
 RETURN TRUE
END Access;

PROCEDURE Search* (lip: NetIP.Adr; loc: INTEGER; rip: NetIP.Adr; rmt: INTEGER; startup: BOOLEAN; VAR port: Port): BOOLEAN;
VAR
 nport: Port;
BEGIN
 nport := NIL; port := ports.next;
 LOOP
  IF port = ports THEN EXIT END;
  IF port.lport = loc THEN
   IF (SYSTEM.VAL(LONGINT, port.rip) = SYSTEM.VAL(LONGINT, rip)) & (port.rport = rmt) THEN EXIT END;
   IF (port.mode = passive) OR (port.mode = conctless) THEN
    IF SYSTEM.VAL(LONGINT, port.rip) = SYSTEM.VAL(LONGINT, NetIP.IPany) THEN
     IF (port.rport = rmt) OR (port.rport = anyport) THEN nport := port END
    ELSIF SYSTEM.VAL(LONGINT, port.rip) = SYSTEM.VAL(LONGINT, rip) THEN
     IF port.rport = anyport THEN nport := port END
    END
   END
  END;
  port := port.next
 END;
 IF port = ports THEN
  IF startup OR (nport # NIL) & (nport.mode = conctless) THEN port := nport ELSE port := NIL END
 END; 
 RETURN port # NIL
END Search;

PROCEDURE Release* (port: Port);
VAR
 prev, curr: Port;
BEGIN prev := ports; curr := ports.next;
 WHILE (curr # ports) & (curr # port) DO
  prev := curr; curr := curr.next
 END;
 IF curr # ports THEN prev.next := curr.next END
END Release;

PROCEDURE Enumerate* (proc: EntryHandler);
VAR curr: Port;
BEGIN
 curr := ports.next;
 WHILE curr # ports DO proc(curr); curr := curr.next END
END Enumerate;

PROCEDURE Init*;
BEGIN
 ports.next := ports; portnr := minport
END Init;

BEGIN
 NEW(ports); Init
END NetPorts.
