(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE TestHalt; (* pjm *)

(*
Torture-test Oberon trap handling.

Ideally, every command in this module should cause a trap, and no system hang or crash.
Some Oberon systems may not pass all the tests.

Compile with all checks turned on, and with optimization turned off.
Some Native-specific features are used.  If you get compilation errors, just delete the offending code.
The results for Native Oberon 2.3.0 (December 9, 1998) are shown at the end.
*)

IMPORT SYSTEM, Kernel, Input, Texts, Oberon;

VAR
 W: Texts.Writer;

PROCEDURE First*; (* trap in first procedure in module *)
VAR t: LONGINT;
BEGIN
 HALT(99)
END First;

PROCEDURE Div0*;
VAR a,b,c: LONGINT;
BEGIN
 b := 1;  c := 0;
 a := b DIV c
END Div0;

PROCEDURE With*;
TYPE
 T0 = POINTER TO T0D;  T0D = RECORD END;
 T1 = POINTER TO T1D;  T1D = RECORD (T0D) END;
VAR
 f: T0;
BEGIN
 NEW(f);
 WITH f: T1 DO END
END With;

PROCEDURE Case*;
VAR i: INTEGER;
BEGIN
 i := 1;
 CASE i OF 
  0:
 END
END Case;

PROCEDURE Return*; (* missing RETURN possibly found at compile-time *)
 PROCEDURE f(): LONGINT;
 BEGIN
 END f;
BEGIN
 IF f() = 0 THEN END
END Return;

PROCEDURE ImpGuardRec*;
TYPE
 R0 = RECORD END;
 R1 = RECORD (R0) END;
VAR
 r1: R1; 

 PROCEDURE A(VAR r: R0);
 VAR r0: R0;
 BEGIN
  r := r0
 END A;
 
BEGIN
 A(r1)
END ImpGuardRec;

PROCEDURE ImpGuardPtr*;
TYPE
 R0 = POINTER TO RECORD END;
 R1 = POINTER TO RECORD (R0) END;
 R2 = POINTER TO RECORD (R0) END;
VAR
  r1: R1;  r2: R2;

 PROCEDURE A(r1, r2: R0);
 BEGIN
  r1^ := r2^
 END A;
 
BEGIN
 NEW(r1);  NEW(r2);
 A(r1, r2)
END ImpGuardPtr;

PROCEDURE Guard*;
TYPE
 T1 = RECORD END;  T2 = RECORD (T1) END;
 P1 = POINTER TO T1;  P2 = POINTER TO T2;
VAR
 t1: P1;  t2: P2;
BEGIN
 NEW(t1);  t2 := t1(P2)
END Guard;

PROCEDURE Index*;
VAR a: ARRAY 2 OF CHAR;  i: INTEGER;
BEGIN
 i := 3;  a[i] := 1X
END Index;

PROCEDURE Assert*;
VAR b: BOOLEAN;
BEGIN
 b := FALSE;
 ASSERT(b)
END Assert;

PROCEDURE DimNeg*;
VAR p: POINTER TO ARRAY OF CHAR;  i: LONGINT;
BEGIN
 i := -1;
 NEW(p, i)
END DimNeg;

PROCEDURE Dim0*; (* some run-time environments may allow this *)
VAR p: POINTER TO ARRAY OF CHAR;  i: LONGINT;
BEGIN
 i := 0;
 NEW(p, i)
END Dim0;

PROCEDURE SoftBreak*; (* press Ctrl-Break to exit *)
VAR ch: CHAR;
BEGIN
 LOOP Input.Read(ch) END
END SoftBreak;

PROCEDURE HardBreak*; (* press Ctrl-Break twice to exit *)
BEGIN
 LOOP END
END HardBreak;

PROCEDURE GCBreak*; (* press Ctrl-Break to exit *)
BEGIN
 LOOP Kernel.GC END
END GCBreak;

PROCEDURE OutOfMem*; (* if this does not trap, you either have a broken GC, or too much memory :-) *)
TYPE
 N = POINTER TO RECORD
  space: ARRAY 4000 OF CHAR;
  next: N
 END;
VAR
 root, t: N;
BEGIN
 NEW(root);
 LOOP
  NEW(t);  t.next := root;  root := t
 END
END OutOfMem;

PROCEDURE Halt20*;
BEGIN
 HALT(20)
END Halt20;

PROCEDURE Halt255*;
BEGIN
 HALT(255)
END Halt255;

PROCEDURE HaltMaxInt*; (* not really legal Oberon *)
BEGIN
 HALT(MAX(INTEGER));
 HALT(MAX(INTEGER))
END HaltMaxInt;

PROCEDURE OverflowMul2*;
VAR a,b: LONGINT;
BEGIN
 a := MAX(LONGINT);
 b := a*2
END OverflowMul2;

PROCEDURE OverflowMul3*;
VAR a,b: LONGINT;
BEGIN
 a := MAX(LONGINT);
 b := a*3
END OverflowMul3;

PROCEDURE OverflowAdd*;
VAR a,b: LONGINT;
BEGIN
 a := MAX(LONGINT);
 b := a+1
END OverflowAdd;

PROCEDURE OverflowInc*;
VAR a: LONGINT;
BEGIN
 a := MAX(LONGINT);
 INC(a)
END OverflowInc;

PROCEDURE InvInstr*; (* Native only *)
CODE {SYSTEM.i386}
 DB 0FH, 04H
END InvInstr;

PROCEDURE GPF*; (* Native only *)
VAR p: LONGINT;
BEGIN
 SYSTEM.GET(-1, p)
END GPF;

PROCEDURE PF*; (* Native only *)
VAR p: LONGINT;
BEGIN
 SYSTEM.GET(80000000H, p)
END PF;

PROCEDURE NilWrite*;
VAR p: POINTER TO RECORD c: CHAR END;
BEGIN
 p := NIL;  p.c := 0X
END NilWrite;

PROCEDURE NilRead*;
VAR p: POINTER TO RECORD c: CHAR END;
BEGIN
 p := NIL;  IF p.c = 0X THEN END
END NilRead;

PROCEDURE NilTag*;
TYPE
 T0 = POINTER TO T0D;  T0D = RECORD END;
 T1 = POINTER TO T1D;  T1D = RECORD (T0D) END;
VAR
 p: T0;
BEGIN
 p := NIL;  IF p IS T1 THEN END
END NilTag;

PROCEDURE NilProc*;
VAR p: PROCEDURE;
BEGIN
 p := NIL;
 p
END NilProc;

PROCEDURE StackTight*;
BEGIN
 StackTight
END StackTight;

PROCEDURE StackSkip*;
VAR x: ARRAY 8 OF LONGINT; (* only used to make larger skips *)
BEGIN
 StackSkip
END StackSkip;

PROCEDURE FloatDiv0*; (* by default Native does not trap *)
VAR a: REAL;
BEGIN
 a := 0;
 a := 1.0/a;
 Texts.WriteReal(W, a, 10);  Texts.WriteLn(W);
 Texts.Append(Oberon.Log, W.buf)
END FloatDiv0;

PROCEDURE FloatOverflow*; (* by default Native does not trap *)
VAR a: REAL;
BEGIN
 a := MAX(REAL);
 a := a*a;
 Texts.WriteReal(W, a, 10);  Texts.WriteLn(W);
 Texts.Append(Oberon.Log, W.buf)
END FloatOverflow;

PROCEDURE Float*; (* by default Native does not trap *)
VAR a: REAL;
BEGIN
 a := 0;
 a := a/a;
 Texts.WriteReal(W, a, 10);  Texts.WriteLn(W);
 Texts.Append(Oberon.Log, W.buf)
END Float;

PROCEDURE Vars*;
CONST Size = 32;
TYPE Ptr = POINTER TO RECORD END;  Proc = PROCEDURE;  Record = RECORD field: LONGINT END;
VAR
 varbyte: SYSTEM.BYTE;  varboolean: BOOLEAN;  varchar: CHAR;
 varshortint: SHORTINT;  varinteger: INTEGER;  varlongint, i: LONGINT;
 varreal: REAL;  varlongreal: LONGREAL;  varset: SET;  varstring: ARRAY 128 OF CHAR;
 varpointer: Ptr;  varproc: PROCEDURE;
 varrecord: Record;
 arraybyte: ARRAY Size OF SYSTEM.BYTE;
 arrayboolean: ARRAY Size OF BOOLEAN;
 arraychar: ARRAY Size OF CHAR;
 arrayshortint: ARRAY Size OF SHORTINT;
 arrayinteger: ARRAY Size OF INTEGER;
 arraylongint: ARRAY Size OF LONGINT;
 arrayreal: ARRAY Size OF REAL;
 arraylongreal: ARRAY Size OF LONGREAL;
 arrayset: ARRAY Size OF SET;
 arraypointer: ARRAY Size OF Ptr;
 arrayproc: ARRAY Size OF Proc;
 arrayrecord: ARRAY Size OF Record;

 PROCEDURE Trap(string: ARRAY OF CHAR;  openbyte: ARRAY OF SYSTEM.BYTE;
   openboolean: ARRAY OF BOOLEAN;  openchar: ARRAY OF CHAR;
   openshortint: ARRAY OF SHORTINT;  openinteger: ARRAY OF INTEGER;
   openlongint: ARRAY OF LONGINT;  openreal: ARRAY OF REAL;
   openlongreal: ARRAY OF LONGREAL;  openset: ARRAY OF SET;
   openpointer: ARRAY OF Ptr;  openproc: ARRAY OF Proc;
   openrecord: ARRAY OF Record);
 BEGIN
  HALT(100)
 END Trap;
 
BEGIN
 varbyte := 1;  varboolean := TRUE;  varchar := "A";
 varshortint := 10;  varinteger := -10;  varlongint := MIN(LONGINT);
 varreal := 3.1415;  varlongreal := 3.1415D0;  varset := {0,2,7..12,31};
 varstring := "It was a dark and stormy night...  Suddenly a shot rang out.  Meanwhile, back in Kansas, the little boy was growing up.";
 NEW(varpointer);  varproc := Vars;
 FOR i := 0 TO Size-1 DO
  arraybyte[i] := CHR(i);  arrayboolean[i] := ODD(i);
  arraychar[i] := CHR(i MOD 10 + 48); (* not 0X-terminated *)
  arrayshortint[i] := SHORT(SHORT(i+100));  arrayinteger[i] := SHORT(-i);  arraylongint[i] := i;
  arrayreal[i] := i;  arraylongreal[i] := LONG(arrayreal[i]) * arrayreal[i];
  arrayset[i] := {0..(i MOD 32)};  NEW(arraypointer[i]);
  arrayproc[i] := Vars
 END;
 Trap("Hello world", arraybyte, arrayboolean, arraychar, arrayshortint, arrayinteger, arraylongint, 
   arrayreal, arraylongreal, arrayset, arraypointer, arrayproc, arrayrecord)
END Vars;

PROCEDURE NilVAR*;
TYPE P = POINTER TO RECORD a: LONGINT END;
VAR p: P;

 PROCEDURE Proc(VAR p: P);
 VAR a: LONGINT;
 BEGIN
  a := p.a
 END Proc;

BEGIN
 p := NIL;
 Proc(p)
END NilVAR;

PROCEDURE NilArray*;
TYPE F = POINTER TO RECORD a: LONGINT;  n: ARRAY 8 OF CHAR END;
VAR f: F;

 PROCEDURE Proc(n: ARRAY OF CHAR);
 VAR ch: CHAR;
 BEGIN
  ch := n[0]
 END Proc;

BEGIN
 f := NIL;
 Proc(f.n)
END NilArray;

PROCEDURE NilNewRec*;
VAR
 p: POINTER TO RECORD
  p: POINTER TO RECORD END
 END;
BEGIN
 NEW(p.p)
END NilNewRec;

PROCEDURE PentiumBreak*;
CODE {SYSTEM.i386}
 CLI
loop:
 STI
 CLI
 JMP loop
END PentiumBreak;

PROCEDURE Last*; (* trap in last procedure in module *)
VAR t: LONGINT;
BEGIN
 HALT(99)
END Last;

BEGIN
 Texts.OpenWriter(W)
END TestHalt.

TestHalt.PentiumBreak

 Intel CPU errors (- 0..31)
0 Division by zero
-1 Debug exception
-2 NMI interrupt
-3 Breakpoint (HALT)
-4 Overflow
-5 Bound exception
-6 Invalid opcode
-7 Device not available (FPU emulator)
-8 Double fault
-9 Coprocessor segment overrun
-10 Invalid TSS
-11 Segment not present
-12 Stack fault exception
-13 General protection fault
-14 Page fault (stack overflow, NIL reference)
-15
-16 Floating-point error (also IRQ13)
-17 Alignment check exception
-18 Machine check exception
-19..-31

Intel FPU errors (- 32..38)
-32 Floating-point division by 0
-33 Floating-point overflow
-34 Invalid floating-point operation
-35 Floating-point stack fault
-36 Denormalized floating-point operand
-37 Floating-point underflow
-38 Floating-point precision loss

Compiler-generated errors (1..9)
1 WITH guard failed
2 CASE invalid
3 RETURN missing
4 (Overflow)
5 Implicit type guard failed
6 Type guard failed
7 Index out of range
8 ASSERT failed
9 Array dimension error

Inner core errors (13..19)
13 Keyboard interrupt
14 Out of memory
15 Bad sector number
16 Disk full
17 Disk error
18 File too big
19 Buffer overflow

User-generated errors (20..)

Watson special assert values (100..129)
100..109 precondition
110..119 invariant
120..129 postcondition

 Test Command Trap output Note

TestHalt.Div0 TRAP 0  Division by zero
TestHalt.With TRAP 1  WITH guard failed
TestHalt.Case TRAP 2  CASE invalid
TestHalt.Return TRAP 3  RETURN missing
 TRAP 4  Overflow see -4
TestHalt.ImpGuardRec TRAP 5  Implicit type guard failed
TestHalt.ImpGuardPtr TRAP 5  Implicit type guard failed
TestHalt.Guard TRAP 6  Type guard failed
TestHalt.Index TRAP 7  Index out of range
TestHalt.Assert TRAP 8  ASSERT failed
TestHalt.DimNeg TRAP 9  Array dimension error
TestHalt.Dim0  allowed
TestHalt.SoftBreak TRAP 13  Keyboard interrupt Ctrl-Break
TestHalt.HardBreak TRAP 13  Keyboard interrupt Ctrl-Break twice
TestHalt.GCBreak TRAP 13  Keyboard interrupt Ctrl-Break
TestHalt.OutOfMem TRAP 14  Out of memory
 TRAP 15  Bad sector number Disk
 TRAP 16  Disk full Disk
 TRAP 17  Disk error Disk
 TRAP 18  File too large Files
 TRAP 19  Buffer overflow Files
TestHalt.Halt20 TRAP 20  HALT statement
TestHalt.Halt255 TRAP 255  HALT statement
TestHalt.HaltMaxInt TRAP 32767  Trace xx HALT does not abort
TestHalt.OverflowMul2 TRAP -4  Overflow use \v switch
TestHalt.OverflowMul3 TRAP -4  Overflow use \v switch
TestHalt.OverflowAdd TRAP -4  Overflow use \v switch
TestHalt.OverflowInc TRAP -4  Overflow use \v switch
TestHalt.InvInstr TRAP -6  Invalid instruction
 TRAP -12  Stack overflow
TestHalt.GPF TRAP -13  General protection fault
TestHalt.PF TRAP -14  Page fault ( 80000000H )
TestHalt.NilWrite TRAP -14  NIL reference ( 00000000H )
TestHalt.NilRead TRAP -14  NIL reference ( 00000000H )
TestHalt.NilTag TRAP -14  NIL reference ( FFFFFFFCH )
TestHalt.NilProc TRAP -14  NIL reference ( 00000000H )
TestHalt.NilVAR TRAP -14  NIL reference ( 00000000H )
TestHalt.NilArray TRAP -14  NIL reference ( 00000004H ) n = NIL reference ( 00000004H )
TestHalt.NilNewRec TRAP -14  NIL reference ( 00000000H )
TestHalt.StackTight TRAP -14  Stack overflow ( xxxxxxxxH )
TestHalt.StackSkip TRAP -14  Stack overflow ( xxxxxxxxH )
 TRAP -16  Floating-point error
TestHalt.FloatDiv0 TRAP -32  Floating-point division by 0 INF
TestHalt.FloatOverflow TRAP -33  Floating-point overflow INF
TestHalt.Float TRAP -34  Floating-point operation invalid NaN
 TRAP -35  Floating-point stack fault
 TRAP -xx CPU exception
TestHalt.Vars TRAP 100  HALT statement check local variables
TestHalt.First
TestHalt.Last

Compiler.Compile *\vs  Compiler.Compile *\vf  Decoder.Decode TestHalt.Obj
