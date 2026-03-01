(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE V24; (** portable, except where noted *) (* pjm/ejz *)

(** V24/RS232 serial communications interface. *)

(* Supports 4 COM ports / afi - 30 Jun. 2001 *)

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
  
 BufSize = 4096;

 (* Port registers *)
 IER = 1; (* Interrupt Enable Register -  read / write
      Baud Rate Divisor MSB if bit 7 of LCR is set *)
 IIR = 2; (* Interrupt Identification Register - read only *)
 FCR = 2; (* 16550 FIFO Contro Register write only *)
 LCR = 3; (* Line Control Register -  read / write *)
 MCR = 4; (* Modem Control Register -  read / write *)
 LSR = 5; (* Line Status Register -  read only*)
 MSR = 4; (* Modem Status Register - read only *)
 
TYPE
 Port = POINTER TO PortDesc;
 PortDesc = RECORD
  base: LONGINT;
  head, tail: LONGINT;
  buf: ARRAY BufSize OF CHAR
 END;

VAR
 ports: ARRAY 4 OF Port;
 portBase*: ARRAY 4 OF LONGINT;  (** non-portable - port base address *)
 irq*: ARRAY 4 OF INTEGER;  (** non-portable - port irq *)
 interruptHandler: ARRAY 4 OF Kernel.Proc;  (* The Interrupt handlers assigned *)
 numports: LONGINT; (* Maximum number of ports *)

PROCEDURE *InterruptHandler0;
VAR p: Port;  c: CHAR;  n: LONGINT;
BEGIN
 LOOP
  p := ports[0];
  SYSTEM.PORTIN(p.base+IIR, c); (* IIR *)
  IF ODD(ORD(c)) THEN EXIT END; (* nothing pending *)
  SYSTEM.PORTIN(p.base, c); (* RBR *)
  n := (p.tail+1) MOD BufSize;
  IF n # p.head THEN
   p.buf[p.tail] := c;  p.tail := n
  END
 END
END InterruptHandler0;

PROCEDURE *InterruptHandler1;
VAR p: Port;  c: CHAR;  n: LONGINT;
BEGIN
 LOOP
  p := ports[1];
  SYSTEM.PORTIN(p.base+IIR, c); (* IIR *)
  IF ODD(ORD(c)) THEN EXIT END; (* nothing pending *)
  SYSTEM.PORTIN(p.base, c);
  n := (p.tail+1) MOD BufSize;
  IF n # p.head THEN
   p.buf[p.tail] := c;  p.tail := n
  END
 END
END InterruptHandler1;

PROCEDURE *InterruptHandler2;
VAR p: Port;  c: CHAR;  n: LONGINT;
BEGIN
 LOOP
  p := ports[2];
  SYSTEM.PORTIN(p.base+IIR, c); (* IIR *)
  IF ODD(ORD(c)) THEN EXIT END; (* nothing pending *)
  SYSTEM.PORTIN(p.base, c); (* RBR *)
  n := (p.tail+1) MOD BufSize;
  IF n # p.head THEN
   p.buf[p.tail] := c;  p.tail := n
  END
 END
END InterruptHandler2;

PROCEDURE *InterruptHandler3;
VAR p: Port;  c: CHAR;  n: LONGINT;
BEGIN
 LOOP
  p := ports[3];
  SYSTEM.PORTIN(p.base+IIR, c); (* IIR *)
  IF ODD(ORD(c)) THEN EXIT END; (* nothing pending *)
  SYSTEM.PORTIN(p.base, c);
  n := (p.tail+1) MOD BufSize;
  IF n # p.head THEN
   p.buf[p.tail] := c;  p.tail := n
  END
 END
END InterruptHandler3;

(** NumberOfPorts - Return the number of ports present - 0 to 4. *)

PROCEDURE NumberOfPorts*(): LONGINT;
BEGIN
 RETURN numports
END NumberOfPorts;

(** Start - Open a serial port (numbered from 0).  bps is the required bits per second.
 data is the number of bits per communication unit.  parity is the parity mode (Par 
 values above).  stop is the number of stop bits (Stop values above).  res returns 0 
 if ok, or error code on error.  1 means port already in use.  2 means no such port.  
 3 means bad bps value.  4 means bad data/parity/stop.   DTR and RTS are enabled. *)
 
PROCEDURE Start*(port, bps, data, parity, stop: LONGINT;  VAR res: LONGINT);
VAR p: Port;  base: LONGINT;  s: SET;
BEGIN
 IF (port >= COM1) & (port <= COM4) & (portBase[port] # 0) & (irq[port] # 0) THEN
  base := portBase[port];
  IF Present(base) THEN
   IF (bps > 0) & (115200 MOD bps = 0) THEN
    IF (data >= 5) & (data <= 8) & (parity >= ParNo) & (parity <= ParSpace) & (stop >= Stop1) & (stop <= Stop1dot5) THEN
     IF ports[port] = NIL THEN
      NEW(p);  bps := 115200 DIV bps;
      p.base := base;  p.head := 0;  p.tail := 0;
       (* disable interrupts *)
      SYSTEM.PORTOUT(base+LCR, 0X); (* LCR - clear DLAB *)
      SYSTEM.PORTOUT(base+IER, 0X); (* IER *)
       (* clear latches *)
      SYSTEM.PORTIN(base+LSR, SYSTEM.VAL(CHAR, s)); (* LSR *)
      SYSTEM.PORTIN(base+IIR, SYSTEM.VAL(CHAR, s)); (* IIR *)
      SYSTEM.PORTIN(base+MSR, SYSTEM.VAL(CHAR, s)); (* MSR *)
       (* enable FIFO & check for 16550 *)
      SYSTEM.PORTOUT(base+FCR, 1X); (* FCR *)
      SYSTEM.PORTIN(base+IIR, SYSTEM.VAL(CHAR, s)); (* IIR *)
      IF s * {6,7} = {6,7} THEN
       SYSTEM.PORTOUT(base+IIR, 47X) (* 16550 setup: EnableFifo, CLRRX, CLRTX, SIZE4 *)
      ELSE
       SYSTEM.PORTOUT(base+IIR, 0X)
      END;
       (* set parameters *)
      SYSTEM.PORTOUT(base+LCR, 80X); (* LCR *)
      SYSTEM.PORTOUT(base, CHR(bps));
      SYSTEM.PORTOUT(base+IER, CHR(bps DIV 100H));
      CASE data OF
       5: s := {}
       |6: s := {0}
       |7: s := {1}
       |8: s := {0,1}
      END;
      IF stop # Stop1 THEN INCL(s, 2) END;
      CASE parity OF
       ParNo:
       |ParOdd: INCL(s, 3)
       |ParEven: s := s + {3,4}
       |ParMark: s := s + {3,5}
       |ParSpace: s := s + {3..5}
      END;
      SYSTEM.PORTOUT(base+LCR, SYSTEM.VAL(CHAR, s)); (* LCR *)
      SYSTEM.PORTOUT(base+MCR, SYSTEM.VAL(CHAR, {0,1,3})); (* MCR: DTR, RTS, OUT2 *)
       (* install interrupt handler *)
      Kernel.InstallIP(interruptHandler[port], Kernel.IRQ+irq[port]);
      ports[port] := p;
       (* enable receive interrupts *)
      SYSTEM.PORTOUT(base+IER, 01X); (* ICR *)
      res := Ok
     ELSE res := PortInUse (* port in use *)
     END
    ELSE res := WrongData (* bad data/parity/stop *)
    END
   ELSE res := WrongBPS (* bad bps *)
   END
  ELSE res := NoSuchPort (* no such port *)
  END
 ELSE res := NoSuchPort (* no such port *)
 END
END Start;

(** Stop - Close the specified port.  Effect on Modem Control lines is undefined. *)

PROCEDURE Stop*(port: LONGINT);
VAR base, a: LONGINT;  s: SET;
BEGIN
 IF (port >= COM1) & (port <= COM4) THEN
  base := ports[port].base;
  REPEAT (* wait for last byte to leave *)
   a := base+LSR;  SYSTEM.PORTIN(a, SYSTEM.VAL(CHAR, s)) (* LSR *)
  UNTIL 6 IN s;
   (* disable interrupts *)
  a := base+IER;  SYSTEM.PORTOUT(a, 0X); (* IER *)
   (* remove interrupt handler *)
  Kernel.RemoveIP(interruptHandler[port], Kernel.IRQ+irq[port]);
  ports[port] := NIL
 ELSE HALT(99)
 END
END Stop;

(** Available - Return the number of bytes available in the specified port's buffer. *)

PROCEDURE Available*(port: LONGINT): LONGINT;
VAR p: Port;
BEGIN
 p := ports[port];
 (*IF p = NIL THEN RETURN -1 END*)
 RETURN (p.tail-p.head) MOD BufSize
END Available;

(** Receive - Read one byte from the specified port.  Waits until a byte is available.  res = Ok iff ok. *)

PROCEDURE Receive*(port: LONGINT;  VAR x: SYSTEM.BYTE;  VAR res: LONGINT);
VAR p: Port;
BEGIN
 p := ports[port];
 REPEAT UNTIL p.tail # p.head;
 x := p.buf[p.head];  p.head := (p.head+1) MOD BufSize;
 res := Ok
END Receive;

(** ReceiveBytes - Read n bytes from the specified port.  Waits until n bytes are available.  res = Ok iff ok. *)

PROCEDURE ReceiveBytes*(port: LONGINT;  VAR x: ARRAY OF SYSTEM.BYTE;  n: LONGINT;  VAR res: LONGINT);
VAR i: LONGINT;
BEGIN
 i := 0;  res := Ok;
 WHILE (i # n) & (res = Ok) DO
  Receive(port, x[i], res);  INC(i)
 END
END ReceiveBytes;

(** Send - Send a byte to the specified port.  Waits until buffer space is available.  res = Ok iff ok. *)

PROCEDURE Send*(port: LONGINT;  x: SYSTEM.BYTE;  VAR res: LONGINT);
VAR p: Port;  s: SET;
BEGIN
 p := ports[port];
 REPEAT (* wait for transmitter empty *)
  SYSTEM.PORTIN(p.base+LSR, SYSTEM.VAL(CHAR, s)) (* LSR *)
 UNTIL 5 IN s;
 SYSTEM.PORTOUT(p.base, x);  res := Ok
END Send;

(** SendBytes - Send n bytes to the specified port.  Waits until buffer space is available.  res = Ok iff all ok. *)

PROCEDURE SendBytes*(port: LONGINT;  VAR x: ARRAY OF SYSTEM.BYTE;  n: LONGINT;  VAR res: LONGINT);
VAR i: LONGINT;
BEGIN
 i := 0;  res := Ok;
 WHILE (i # n) & (res = Ok) DO
  Send(port, x[i], res);  INC(i)
 END
END SendBytes;

(** ClearMC - Clear the specified Modem Control lines of the specified port.  s may contain DTR, RTS & Break. *)

PROCEDURE ClearMC*(port: LONGINT;  s: SET);
VAR p: LONGINT;  t: SET;
BEGIN
 IF s * {DTR, RTS} # {} THEN
  p := ports[port].base+MCR; (* MCR *)
  SYSTEM.PORTIN(p, SYSTEM.VAL(CHAR, t));
  t := t - (s * {DTR, RTS}); (* modify only bits 0 & 1 *)
  SYSTEM.PORTOUT(p, SYSTEM.VAL(CHAR, t))
 END;
 IF Break IN s THEN
  p := ports[port].base+LCR; (* LCR *)
  SYSTEM.PORTIN(p, SYSTEM.VAL(CHAR, t));
  EXCL(t, 6); (* break off *)
  SYSTEM.PORTOUT(p, SYSTEM.VAL(CHAR, t))
 END
END ClearMC;

(** SetMC - Set the specified Modem Control lines of the specified port.  s may contain DTR, RTS & Break. *)

PROCEDURE SetMC*(port: LONGINT;  s: SET);
VAR p: LONGINT;  t: SET;
BEGIN
 IF s * {DTR, RTS} # {} THEN
  p := ports[port].base+MCR; (* MCR *)
  SYSTEM.PORTIN(p, SYSTEM.VAL(CHAR, t));
  t := t + (s * {DTR, RTS}); (* modify only bits 0 & 1 *)
  SYSTEM.PORTOUT(p, SYSTEM.VAL(CHAR, t))
 END;
 IF Break IN s THEN
  p := ports[port].base+LCR; (* LCR *)
  SYSTEM.PORTIN(p, SYSTEM.VAL(CHAR, t));
  INCL(t, 6); (* break on *)
  SYSTEM.PORTOUT(p, SYSTEM.VAL(CHAR, t))
 END
END SetMC;

(** GetMC - Return the state of the specified Modem Control lines of the specified port.  s contains
 the current state of DSR, CTS, RI, DCD & Break. *)
 
PROCEDURE GetMC*(port: LONGINT;  VAR s: SET);
VAR p: LONGINT;  t: SET;
BEGIN
 s := {};  p := ports[port].base+MSR; (* MSR *)
 SYSTEM.PORTIN(p, SYSTEM.VAL(CHAR, t)); (* note: this clears bits 0-3 *)
 IF 4 IN t THEN INCL(s, CTS) END;
 IF 5 IN t THEN INCL(s, DSR) END;
 IF 6 IN t THEN INCL(s, RI) END;
 IF 7 IN t THEN INCL(s, DCD) END;
 DEC(p); (* LSR *)
 SYSTEM.PORTIN(p, SYSTEM.VAL(CHAR, t)); (* note: this clears bits 1-4 *)
 IF 4 IN t THEN INCL(s, Break) END
END GetMC;

(** Attempt to detect a serial port at the specified I/O base address. *)

PROCEDURE Present*(base: LONGINT): BOOLEAN; (** non-portable *)
VAR s: SET;
BEGIN
 INC(base, 4);  SYSTEM.PORTIN(base, SYSTEM.VAL(CHAR, s));
 RETURN s * {5..7} = {}
END Present;

PROCEDURE Init; (* Define the default setup values for the four COM ports *)
BEGIN
 numports := 0;
 IF Present(3F8H) THEN
  portBase[0] := 3F8H; irq[0] := 4;
  INC(numports)
 ELSE irq[0] := 0
 END;
 IF Present(2F8H) THEN
  portBase[1] := 2F8H; irq[1] := 3;
  INC(numports)
 ELSE irq[1] := 0
 END;
 IF Present(3E8H) THEN
  portBase[2] := 3E8H; irq[2] := 4;
  INC(numports)
 ELSE irq[2] := 0
 END;
 IF Present(2E8H) THEN
  portBase[3] := 2E8H; irq[3] := 3;
  INC(numports)
 ELSE irq[3] := 0
 END
END Init;

BEGIN
 ports[0] := NIL;  ports[1] := NIL;  ports[2] := NIL;  ports[3] := NIL;
 interruptHandler[0] := InterruptHandler0;
 interruptHandler[1] := InterruptHandler1;
 interruptHandler[2] := InterruptHandler2;
 interruptHandler[3] := InterruptHandler3;
 Init
END V24.
