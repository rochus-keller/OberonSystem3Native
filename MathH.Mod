(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE MathH; (** non-portable, pc native oberon only *)  (** prk  **)

(*
 ToDo: 
  many operations are implemented in the FPU. Reimplement as quadword integers
  to make it faster.
 
 03.05.99 prk: optimization of monadic "-" using integer arithmetik
 05.05.99 adf: added ENTIER (RealToHInt is not ENTIER)
 06.05.99 prk: fix in DIV/MOD, divisor must be => 0 (check only msb)
 06.05.99 prk: fix in DIV/MOD: rounding towards -infty. Issue Trap for divide by 0 exception
 11.05.99 prk: optimization of LIntToHInt, no longer uses FPU arithmetic
 26.05.99 adf: exported low and hi so that HUGEINT can be saved to file
 03.06.99 prk: fix in DIV/MOD: exceptions must be cleared before changing the mask
*)

IMPORT
  SYSTEM;

TYPE
 HUGEINT* = RECORD low*, hi*: LONGINT END; (* 64 bits *)

VAR
 MINH*, MAXH*, ZERO*, ONE*, TWO*, TEN*: HUGEINT;
 (*
  another solution could be to alias HUGEINT and LONGREAL (same size),
  but this makes them compatible, which is wrong
 *)

CONST
 (* CC of the FPU-Status Word *)
 Eq = 4000H; Lt = 100H; Gt = 000H;

PROCEDURE -Compare(): LONGINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD 8[EBP]   ; b->ST(1)
 FILD QWORD 16[EBP]   ; a->ST(0)
 FCOMPP
 DB 9BH, 0DFH, 0E0H   ; FSTSW AX
 AND EAX, 4500H      ; use c3, c2, c0
END Compare;

(** Comparison Operators*)
PROCEDURE ">"* (a, b: HUGEINT): BOOLEAN;
BEGIN RETURN Compare()=Gt
END ">";

PROCEDURE ">"* (a: HUGEINT; b: LONGINT): BOOLEAN;
BEGIN RETURN a > LIntToHInt(b)
END ">";

PROCEDURE ">"* (a: LONGINT; b: HUGEINT): BOOLEAN;
BEGIN RETURN LIntToHInt(a) > b
END ">";

PROCEDURE ">="* (a, b: HUGEINT): BOOLEAN;
BEGIN RETURN Compare()#Lt
END ">=";

PROCEDURE ">="* (a: HUGEINT; b: LONGINT): BOOLEAN;
BEGIN RETURN a >= LIntToHInt(b)
END ">=";

PROCEDURE ">="* (a: LONGINT; b: HUGEINT): BOOLEAN;
BEGIN RETURN LIntToHInt(a) >= b
END ">=";

PROCEDURE "<"* (a, b: HUGEINT): BOOLEAN;
BEGIN RETURN Compare()=Lt
END "<";

PROCEDURE "<"* (a: HUGEINT; b: LONGINT): BOOLEAN;
BEGIN RETURN a < LIntToHInt(b)
END "<";

PROCEDURE "<"* (a: LONGINT; b: HUGEINT): BOOLEAN;
BEGIN RETURN LIntToHInt(a) < b
END "<";

PROCEDURE "<="* (a, b: HUGEINT): BOOLEAN;
BEGIN RETURN Compare()#Gt
END "<=";

PROCEDURE "<="* (a: HUGEINT; b: LONGINT): BOOLEAN;
BEGIN RETURN a <= LIntToHInt(b)
END "<=";

PROCEDURE "<="* (a: LONGINT; b: HUGEINT): BOOLEAN;
BEGIN RETURN LIntToHInt(a) <= b
END "<=";

PROCEDURE "="* (a, b: HUGEINT): BOOLEAN;
BEGIN RETURN Compare()=Eq
END "=";

PROCEDURE "="* (a: HUGEINT; b: LONGINT): BOOLEAN;
BEGIN RETURN a = LIntToHInt(b)
END "=";

PROCEDURE "="* (a: LONGINT; b: HUGEINT): BOOLEAN;
BEGIN RETURN LIntToHInt(a) = b
END "=";

PROCEDURE "#"* (a, b: HUGEINT): BOOLEAN;
BEGIN RETURN Compare()#Eq
END "#";

PROCEDURE "#"* (a: HUGEINT; b: LONGINT): BOOLEAN;
BEGIN RETURN a # LIntToHInt(b)
END "#";

PROCEDURE "#"* (a: LONGINT; b: HUGEINT): BOOLEAN;
BEGIN RETURN LIntToHInt(a) # b
END "#";

(** Monadic Arithmetic Operators*)
PROCEDURE "-"* (a: HUGEINT): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 MOV EAX, 12[EBP]
 MOV EBX, 8[EBP]
 MOV ECX, 16[EBP]
 NEG EAX
 NEG EBX
 SBB EAX,0
 MOV 4[ECX], EAX
 MOV 0[ECX], EBX
END "-";

(* old FPU version
PROCEDURE "-"* (a: HUGEINT): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD a[EBP]
 FCHS
 MOV EAX, 16[EBP]
 FISTP QWORD [EAX]
 WAIT
END "-";
*)

(** Dyadic Assignment Operator *)
PROCEDURE ":="* (VAR a : HUGEINT; b : LONGINT);
BEGIN
 a := LIntToHInt(b)
END ":=";

(** Dyadic Arithmetic Operators*)
(*FPU Version
PROCEDURE "+"* (a, b: HUGEINT): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD a[EBP]
 FILD QWORD b[EBP]
 FADDP
 MOV EAX, 24[EBP]
 FISTP QWORD [EAX]
 WAIT
END "+";

PROCEDURE "-"* (a, b: HUGEINT): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD a[EBP]
 FILD QWORD b[EBP]
 FSUBP
 MOV EAX, 24[EBP]
 FISTP QWORD [EAX]
 WAIT
END "-";
FPU Version*)

(*ASM Version *)
PROCEDURE "+"* (a, b: HUGEINT): HUGEINT;
CODE {SYSTEM.i386}
 MOV EAX, 16[EBP]
 MOV EBX, 20[EBP]
 MOV ECX, 24[EBP]
 ADD EAX, 8[EBP]
 ADC EBX,  12[EBP]
 MOV 0[ECX], EAX
 MOV 4[ECX], EBX
END "+";

PROCEDURE "+"* (a: HUGEINT; b: LONGINT): HUGEINT;
BEGIN RETURN a + LIntToHInt(b)
END "+";

PROCEDURE "+"* (a: LONGINT; b: HUGEINT): HUGEINT;
BEGIN RETURN LIntToHInt(a) + b
END "+";

(* ASM Version*)
PROCEDURE "-"* (a, b: HUGEINT): HUGEINT;
CODE {SYSTEM.i386}
 MOV EAX, 16[EBP]
 MOV EBX, 20[EBP]
 MOV ECX, 24[EBP]
 SUB EAX, 8[EBP]
 SBB EBX,  12[EBP]
 MOV 0[ECX], EAX
 MOV 4[ECX], EBX
END "-";

PROCEDURE "-"* (a: HUGEINT; b: LONGINT): HUGEINT;
BEGIN RETURN a - LIntToHInt(b)
END "-";

PROCEDURE "-"* (a: LONGINT; b: HUGEINT): HUGEINT;
BEGIN RETURN LIntToHInt(a) - b
END "-";


PROCEDURE "*"* (a, b: HUGEINT): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD a[EBP]
 FILD QWORD b[EBP]
 FMULP
 MOV EAX, 24[EBP]
 FISTP QWORD [EAX]
 WAIT
END "*";

PROCEDURE "*"* (a: HUGEINT; b: LONGINT): HUGEINT;
BEGIN RETURN a * LIntToHInt(b)
END "*";

PROCEDURE "*"* (a: LONGINT; b: HUGEINT): HUGEINT;
BEGIN RETURN LIntToHInt(a) * b
END "*";


PROCEDURE "DIV"* (a, b: HUGEINT): HUGEINT;
VAR cw, cw0: INTEGER;
CODE {SYSTEM.i386, SYSTEM.FPU}
 MOV EAX, 12[EBP]   ; b must be positive (check msb)
 CMP EAX, 0
 JGE ok
 PUSH 8       ; ASSERT Trap
 INT 3
ok:
 FNCLEX
 FSTCW cw[EBP]
 MOV cw0[EBP], 077AH   ; rounding to -infty, allow zero divide, invalid operation
 FLDCW cw0[EBP]     ;set rounding to 01, round down
 
 FILD QWORD a[EBP]
 FILD QWORD b[EBP]
 FDIVP
 MOV EAX, 24[EBP]
 FISTP QWORD [EAX]
 FLDCW cw[EBP]     ;reset rounding
 WAIT
END "DIV";

PROCEDURE "DIV"* (a: HUGEINT; b: LONGINT): HUGEINT;
BEGIN RETURN a DIV LIntToHInt(b)
END "DIV";

PROCEDURE "DIV"* (a: LONGINT; b: HUGEINT): HUGEINT;
BEGIN RETURN LIntToHInt(a) DIV b
END "DIV";


PROCEDURE "MOD"* (a, b: HUGEINT): HUGEINT;
VAR cw, cw0: INTEGER;
CODE {SYSTEM.i386, SYSTEM.FPU}
 MOV EAX, 12[EBP]   ; b must be positive (check msb)
 CMP EAX, 0
 JGE ok
 PUSH 8       ; ASSERT Trap
 INT 3
ok:
 FNCLEX
 FSTCW cw[EBP]
 MOV cw0[EBP], 077FH   ; was 77AH -> wrong because zero is not an exception here
 FLDCW cw0[EBP]     ;set rounding to 01, round down, mask exceptions
 
 FILD QWORD a[EBP]
 FILD QWORD b[EBP]
 FILD QWORD b[EBP]
 FDIVR ST, ST(2)     ; ST(0) := a DIV b = ST(2) DIV ST(0)
 FRNDINT
 FMULP
 FSUBP
 
 MOV EAX, 24[EBP]
 FISTP QWORD [EAX]
 FLDCW cw[EBP]     ;reset rounding
 WAIT
END "MOD";

PROCEDURE "MOD"* (a: HUGEINT; b: LONGINT): HUGEINT;
BEGIN RETURN a MOD LIntToHInt(b)
END "MOD";

PROCEDURE "MOD"* (a: LONGINT; b: HUGEINT): HUGEINT;
BEGIN RETURN LIntToHInt(a) MOD b
END "MOD";


(** Predefined Functions*)
PROCEDURE ABS* (a: HUGEINT): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD a[EBP]
 FABS
 MOV EAX, 16[EBP]
 FISTP QWORD [EAX]
 WAIT
END ABS;

PROCEDURE DEC* (VAR a: HUGEINT);
BEGIN
 IF a.low = 0 THEN a.hi:=a.hi-1 END;
 a.low:=a.low-1
END DEC;

PROCEDURE INC* (VAR a: HUGEINT);
BEGIN
 IF a.low = -1 THEN a.hi:=a.hi+1 END;
 a.low:=a.low+1
END INC;

PROCEDURE ODD* (a: HUGEINT): BOOLEAN;
BEGIN RETURN (a MOD TWO) = ONE
END ODD;

(** Conversion Routines *)
PROCEDURE ENTIER* (a: LONGREAL): HUGEINT;
BEGIN
 IF a < 0 THEN RETURN LRealToHInt(a) - ONE
 ELSE RETURN LRealToHInt(a)
 END
END ENTIER;

(* FPU version
PROCEDURE LIntToHInt*(i: LONGINT): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD DWORD i[EBP]
 MOV EAX, 12[EBP]
 FISTP QWORD [EAX]
 WAIT
END LIntToHInt; *)

PROCEDURE LIntToHInt*(i: LONGINT): HUGEINT;
CODE {SYSTEM.i386}
 MOV EAX, i[EBP]
 CDQ
 MOV EBX, 12[EBP]
 MOV 0[EBX], EAX
 MOV 4[EBX], EDX
END LIntToHInt;

PROCEDURE RealToHInt*(r: REAL): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FLD DWORD r[EBP]
 MOV EAX, 12[EBP]
 FISTP QWORD [EAX]
 WAIT
END RealToHInt;

PROCEDURE LRealToHInt*(r: LONGREAL): HUGEINT;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FLD QWORD r[EBP]
 MOV EAX, 16[EBP]
 FISTP QWORD [EAX]
 WAIT
END LRealToHInt;

PROCEDURE HIntToReal*(h: HUGEINT): REAL;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD h[EBP]
 WAIT
END HIntToReal;

PROCEDURE HIntToLReal*(h: HUGEINT): LONGREAL;
CODE {SYSTEM.i386, SYSTEM.FPU}
 FILD QWORD h[EBP]
 WAIT
END HIntToLReal;

PROCEDURE SHORT*(h: HUGEINT): LONGINT;
BEGIN  RETURN h.low
END SHORT;


PROCEDURE HIntToIntStr*(x: HUGEINT; n: LONGINT; VAR str: ARRAY OF CHAR);
    VAR i, j: LONGINT; x0: HUGEINT; a: ARRAY 20 OF CHAR;
BEGIN i := 0; j := 0;
    IF x < ZERO THEN
      IF x = MINH THEN COPY("-9223372036854775808", str); RETURN
      ELSE n:=n-1; x0 := -x
      END
    ELSE x0 := x
    END;
    REPEAT
      a[i] := CHR(SHORT(x0 MOD TEN) + 30H); x0 := x0 DIV TEN; i:=i+1
    UNTIL x0 = ZERO;
    WHILE (n > i) & (j < LEN(str)) DO str[j] := " "; j := j+1; n := n-1 END;
    IF x < ZERO THEN str[j] := "-"; j := j+1 END;
    REPEAT i:=i-1; str[j] := a[i]; j := j+1 UNTIL (i = 0) OR (j = LEN(str)-1);
    str[j] := 0X
END HIntToIntStr;

PROCEDURE HIntToHexStr*(x: HUGEINT; VAR str: ARRAY OF CHAR);
VAR j: LONGINT;
 PROCEDURE Hex(x: LONGINT);
  VAR i: INTEGER; y: LONGINT;
 BEGIN i := 8;
  WHILE (i > 0) & (j < LEN(str)-1) DO
   i := i-1; y := x MOD 10H;
   IF y < 10 THEN str[j+i] := CHR(y + 30H) ELSE str[j+i] := CHR(y + 37H) END;
   x := x DIV 10H
  END;
  j := j + 8-i
 END Hex;
BEGIN 
 j := 0; Hex(x.hi); Hex(x.low); str[j] := 0X
END HIntToHexStr;

BEGIN
 MINH.low:=0; MINH.hi:=80000000H;
 MAXH.low:=0FFFFFFFFH; MAXH.hi:=7FFFFFFFH;
 ZERO:=LIntToHInt(0); ONE:=LIntToHInt(1); TWO:=LIntToHInt(2); TEN:=LIntToHInt(10);
END MathH.