(* OPTR -  target-specific properties for the front end 

	Register numbering scheme for ARM32:
	0..14  = R0..R14 (32-bit GPRs; R13=SP, R15=PC not included)
	R11 = FP (frame pointer, dedicated)
	R13 = SP (stack pointer, dedicated)
	R14 = LR (link register)

	ValidRegType: All registers can hold any 32-bit-or-smaller type.
	RegIndex: Identity (ARM register number = index).
  
	Copyright 2025 Rochus Keller <mailto:me@rochus-keller.ch>

	GNU General Public License Usage
	This file may be used under the terms of the GNU General Public
	License (GPL) versions 2.0 or 3.0 as published by the Free Software
	Foundation and appearing in the file LICENSE.GPL included in
	the packaging of this file. Please review the following information
	to ensure GNU General Public Licensing requirements will be met:
	http://www.fsf.org/licensing/licenses/info/GPLv2.html and
	http://www.gnu.org/copyleft/gpl.html.
*)

MODULE OPTR; (** non-portable *)

 CONST
  (* Structure forms - needed for ValidRegType *)
  Undef = 0; Byte = 1; Bool = 2; Char = 3; SInt = 4; Int = 5; LInt = 6;
  Real = 7; Set = 9; NilTyp = 11;
  Pointer = 13; ProcTyp = 14;

 TYPE
  EnterConstProc* = PROCEDURE(name: ARRAY OF CHAR; value: LONGINT);

 VAR
  Target* : ARRAY 8 OF CHAR;
  MinRegNr*: LONGINT;
  MaxRegNr*: LONGINT;

 PROCEDURE ValidRegType*(regNr: LONGINT; typeForm: SHORTINT): BOOLEAN;
 (* ARM32: all GPRs R0-R14 are 32-bit and can hold any scalar type *)
 BEGIN
  IF (0 <= regNr) & (regNr <= 14) THEN
   RETURN typeForm IN {Undef..Real, Set, NilTyp, Pointer, ProcTyp}
  ELSE
   RETURN FALSE
  END
 END ValidRegType;

 PROCEDURE RegIndex*(regNr: LONGINT): LONGINT;
 (* ARM32: register number IS the index (uniform 32-bit registers) *)
 BEGIN
  RETURN regNr
 END RegIndex;

 PROCEDURE IsLegacyReg*(regNr: LONGINT): BOOLEAN;
 (* ARM32: no legacy register concept; all registers are uniform 32-bit *)
 (* Return TRUE for all valid GPRs so the front end treats them normally *)
 BEGIN
  RETURN (0 <= regNr) & (regNr <= 14)
 END IsLegacyReg;

 PROCEDURE EnterRegisters*(enter: EnterConstProc);
 (* Make ARM32 register names available for SYSTEM.GETREG/PUTREG *)
 BEGIN
  enter("R0", 0); enter("R1", 1); enter("R2", 2); enter("R3", 3);
  enter("R4", 4); enter("R5", 5); enter("R6", 6); enter("R7", 7);
  enter("R8", 8); enter("R9", 9); enter("R10", 10);
  enter("FP", 11); enter("R11", 11);
  enter("IP", 12); enter("R12", 12);
  enter("SP", 13); enter("R13", 13);
  enter("LR", 14); enter("R14", 14)
 END EnterRegisters;

BEGIN
 Target := "ARMv7";
 MinRegNr := 0;
 MaxRegNr := 14
END OPTR.
