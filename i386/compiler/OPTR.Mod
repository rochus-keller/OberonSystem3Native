(* OPTR - Target module for the OP2 compiler *)
(* Abstracts target-specific properties for the front end *)
(* i386 implementation *)

MODULE OPTR; (** non-portable *)

 IMPORT OPM;
 
 CONST
  (* Structure forms - needed for ValidRegType *)
  Undef = 0; Byte = 1; Bool = 2; Char = 3; SInt = 4; Int = 5; LInt = 6;
  Real = 7; Set = 9; NilTyp = 11;
  Pointer = 13; ProcTyp = 14;
  
 TYPE
  EnterConstProc* = PROCEDURE(name: ARRAY OF CHAR; value: LONGINT);

 VAR
  Target* : SHORTINT;
  MinRegNr*: LONGINT;
  MaxRegNr*: LONGINT;

 PROCEDURE ValidRegType*(regNr: LONGINT; typeForm: SHORTINT): BOOLEAN;
 BEGIN
  IF (0 <= regNr) & (regNr < 8) THEN
   RETURN typeForm IN {Undef..Real, Set, NilTyp, Pointer, ProcTyp}  (*old definition*)
  ELSIF (8 <= regNr) & (regNr < 16) THEN
   RETURN typeForm IN {LInt, Real, Set, Pointer, ProcTyp}  (*EAX .. EDI*)
  ELSIF (16 <= regNr) & (regNr < 24) THEN
   RETURN typeForm IN {Int}  (*AX .. DI*)
  ELSIF (24 <= regNr) & (regNr < 32) THEN
   RETURN typeForm IN {Byte, Bool, Char, SInt}  (*AL .. BH*)
  ELSE
   RETURN FALSE
  END
 END ValidRegType;

 PROCEDURE RegIndex*(regNr: LONGINT): LONGINT;
 BEGIN
  RETURN regNr MOD 8
 END RegIndex;

 PROCEDURE IsLegacyReg*(regNr: LONGINT): BOOLEAN;
 BEGIN
  RETURN (0 <= regNr) & (regNr < 8)
 END IsLegacyReg;

 PROCEDURE EnterRegisters*(enter: EnterConstProc);
 BEGIN
  enter("EAX", 8); enter("ECX", 9);
  enter("EDX", 10); enter("EBX", 11);
  enter("ESP", 12); enter("EBP", 13);
  enter("ESI", 14); enter("EDI", 15);

  enter("AX", 16); enter("CX", 17);
  enter("DX", 18); enter("BX", 19);
  enter("SP", 20); enter("BP", 21);
  enter("SI", 22); enter("DI", 23);

  enter("AL", 24); enter("CL", 25);
  enter("DL", 26); enter("BL", 27);
  enter("AH", 28); enter("CH", 29);
  enter("DH", 30); enter("BH", 31)
 END EnterRegisters;

BEGIN
 Target := OPM.i386;
 MinRegNr := 0;
 MaxRegNr := 31
END OPTR.
