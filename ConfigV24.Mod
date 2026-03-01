(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE ConfigV24; (** portable *) (* afi - 30 Jun. 2001 *)

(** V24/RS-232 serial communications interface - Base addresses and IRQs. *)

(* Supports 4 COM ports / afi *)

IMPORT Oberon, Texts, V24;

VAR W: Texts.Writer;

(* Test if this value is a duplicate of the values already assigned *)
PROCEDURE IsDup(value: LONGINT; p: INTEGER): BOOLEAN;
VAR i: INTEGER;
BEGIN
 i := 0;
 WHILE (i < p) & (value # V24.portBase[i]) DO INC(i) END;
 RETURN i # p
END IsDup;

(** The standard base addresses of the four possible serial ports of a machine are: 3F8, 2F8H, 3E8H and 2E8H.
 A machine is usually equiped with two serial ports with the following default assignments:
  COM1 - 3F8H - IRQ 4
  COM2 - 2F8H - IRQ 3

 These assignments can be changed with the System Setup utility at boot time. Ports can also be disabled.

 If an add-on I/O card with additional serial ports is installed, the address and the IRQ assigned to each port
 are normally jumpered on the card. It is not possible to obtain this information by software.

 It is allowed to reshuffle the addresses and their corresponding IRQ among the COM ports.
 This command is best placed in Oberon.Text ahead of a possible ConfigInput.Mouse or
 ConfigInput.WatchMouse command.

 Usage: SerialPorts.SetIRQs { [ xxxH | 000H ] IRQx } ~ Four pairs: port base address + IRQ
 The base addresses chosen must be present. No duplicate address is allowed.
 Uninstalled, disabled ports are assigned the address 000H.

 The IRQs may be chosen among the free (i.e. non-conflicting) IRQs of the machine.
 Duplicate IRQs may be assigned, provided the ports are not used simultaneously.
 It is common practice to see COM3 using IRQ 4 and COM4 using IRQ 3, as is done in V24.Mod
 when the machine is started.

 The final setting is displayed in the System log in the form of a new SetIRQs command ready
 for editing and executing. *)

PROCEDURE SetIRQs*;
VAR S: Texts.Scanner; p: INTEGER;

 PROCEDURE SetPair(port: INTEGER);
 VAR present, dup: BOOLEAN;
 BEGIN
  V24.portBase[port] := 0;
  Texts.Scan(S);
  IF (S.class = Texts.Int) & (S.i # 0) THEN
   dup := IsDup(S.i, port);
   IF dup THEN
    Texts.WriteString(W, "Duplicate address on COM"); Texts.WriteInt(W, port+1, 0);
    Texts.WriteLn(W)
   ELSE
    present := V24.Present(S.i);
    IF present THEN
     V24.portBase[port] := S.i
    ELSE
     Texts.WriteString(W, "Invalid address on COM"); Texts.WriteInt(W, port+1, 0);
     Texts.WriteLn(W)
    END
   END
  END;
  V24.irq[port] := 0;
  Texts.Scan(S);
  IF (S.class = Texts.Int) & (S.i # 0) & present & ~dup THEN V24.irq[port] := SHORT(S.i) END
 END SetPair;

BEGIN
 Texts.OpenScanner(S,Oberon.Par.text,Oberon.Par.pos);
 FOR p := 0 TO 3 DO SetPair(p) END;
 GetIRQs
END SetIRQs;

(** Get the base addresses and the IRQ numbers of the installed serial ports. *)
PROCEDURE GetIRQs*;
VAR p: LONGINT;

 (* Write a hexadecimal representation of x *)
 PROCEDURE Hex (x: LONGINT): ARRAY OF CHAR;
    VAR i, y: LONGINT; a: ARRAY 10 OF CHAR;
   BEGIN
  COPY("      ", a);
  i := 6;
     REPEAT y := x MOD 10H;
       IF y < 10 THEN a[i] := CHR(y + 30H) ELSE a[i] := CHR(y + 37H) END;
       x := x DIV 10H; DEC(i)
     UNTIL i = 3;
  a[7] := "H"; a[8] := 0X;
     RETURN a
 END Hex;

BEGIN
 Texts.WriteString(W, "Serial port addr. & IRQs     COM1      COM2      COM3      COM4"); Texts.WriteLn(W);
 Texts.WriteString(W, "         ConfigV24.SetIRQs");
 FOR p := 0 TO 3 DO
  Texts.WriteString(W, Hex(V24.portBase[p])); Texts.WriteInt(W, V24.irq[p], 3)
 END;
 Texts.WriteString(W, " ~");
 Texts.WriteLn(W);
 Texts.Append(Oberon.Log, W.buf)
END GetIRQs;

BEGIN
 Texts.OpenWriter(W)
END ConfigV24.

ConfigV24.GetIRQs