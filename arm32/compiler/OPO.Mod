(* OPO -  Low-level code emission for the ARM32 backend

	The code buffer stores bytes; each PutWord emits 4 bytes in little-endian order.

	Key differences from i386 OPO:
	- Fixed 4-byte instruction width (no variable-length encoding)
	- No ModR/M, SIB, or prefix bytes
	- Condition codes are part of each instruction word
	- Immediate values use 8-bit rotated encoding for data processing
	- Load/store use 12-bit immediate offsets
	- VFP instructions use coprocessor encoding (cp10/cp11)
	
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

MODULE OPO;
 IMPORT OPT, OPM, SYSTEM;

 CONST

 (* item modes for ARM32 (must not overlap item basemodes, > 13) *)
  Reg* = 15; Abs* = 16; RegRel* = 17; Coc* = 18;

  (* mode and scale factors - ARM32 uses shift amounts instead of x86 scale *)
  noScale* = 0; Scale1* = 0; Scale2* = 1; Scale4* = 2; Scale8* = 3;
  RegReg*  = 0; (* register to register *)
  RegMem*  = 1; (* register to memory *)
   MemReg*  = 2; (* memory to register *)
  ImmReg*  = 3; (* immediate to register *)
  ImmMem*  = 4; (* immediate to memory *)

  (* aliases *)
  Regs*  = RegReg;
  Mem*  = MemReg;
  Imme*  = ImmReg;

 (* code and data length per module *)
  CodeLength*  = 130000;
  MaxConstLength* = 64*1024;

  (* ARM32 GPR numbers *)
  R0* = 0; R1* = 1; R2* = 2; R3* = 3;
  R4* = 4; R5* = 5; R6* = 6; R7* = 7;
  R8* = 8; R9* = 9; R10* = 10;
  FP* = 11; R11* = 11;  (* frame pointer *)
  IP* = 12; R12* = 12;  (* intra-procedure scratch *)
  SP* = 13; R13* = 13;  (* stack pointer *)
  LR* = 14; R14* = 14;  (* link register *)
  PC* = 15; R15* = 15;  (* program counter - not directly usable *)

 (* register/memory size indicators *)
  Bit8* = 1; Bit16* = 2; Bit32* = 0; Bit64* = 5;
   (* Note: Bit32 = 0 to match i386 convention where EAX=0 means 32-bit *)

 noDisp* = 0; none = -1;
 noBase* = none; noInx* = none; noImm* = 0;

 BUG = 42;

  (* A32 condition codes *)
  CondEQ* = 0;  (* equal, Z set *)
  CondNE* = 1;  (* not equal, Z clear *)
  CondCS* = 2;  (* carry set / unsigned higher or same *)
  CondHS* = 2;
  CondCC* = 3;  (* carry clear / unsigned lower *)
  CondLO* = 3;
  CondMI* = 4;  (* minus / negative *)
  CondPL* = 5;  (* plus / positive or zero *)
  CondVS* = 6;  (* overflow *)
  CondVC* = 7;  (* no overflow *)
  CondHI* = 8;  (* unsigned higher *)
  CondLS* = 9;  (* unsigned lower or same *)
  CondGE* = 10; (* signed greater or equal *)
  CondLT* = 11; (* signed less than *)
  CondGT* = 12; (* signed greater than *)
  CondLE* = 13; (* signed less or equal *)
  CondAL* = 14; (* always *)

   (* A32 data processing opcodes (bits [24:21]) *)
  dpAND* = 0; dpEOR* = 1; dpSUB* = 2; dpRSB* = 3;
  dpADD* = 4; dpADC* = 5; dpSBC* = 6; dpRSC* = 7;
  dpTST* = 8; dpTEQ* = 9; dpCMP* = 10; dpCMN* = 11;
  dpORR* = 12; dpMOV* = 13; dpBIC* = 14; dpMVN* = 15;

  (* Shift types (bits [6:5] in operand 2) *)
  ShiftLSL* = 0; ShiftLSR* = 1; ShiftASR* = 2; ShiftROR* = 3;

TYPE
  ConstArray* = POINTER TO ARRAY OF CHAR;

 VAR
 pc*, dsize*: LONGINT;   (* code size in bytes, data size *)
 csize*: LONGINT;  (* constant size *)
 lastImmSize*: SHORTINT;
 constant*: ConstArray;
 code*: ARRAY CodeLength OF CHAR;
 CodeErr*: BOOLEAN;

(* Low-level byte emission *)

 PROCEDURE PutByte*(b: LONGINT);
 BEGIN
  IF pc < CodeLength THEN
   code[pc] := CHR(b MOD 256); INC(pc)
  ELSE
   IF ~CodeErr THEN OPM.err(210); CodeErr := TRUE END
  END
 END PutByte;

 PROCEDURE PutWord*(w: LONGINT);
 BEGIN
  PutByte(w MOD 100H);
  PutByte(w DIV 100H MOD 100H);
  PutByte(w DIV 10000H MOD 100H);
  PutByte(w DIV 1000000H MOD 100H)
 END PutWord;

 PROCEDURE PutWordAt*(pos: LONGINT; w: LONGINT);
 BEGIN
  code[pos] := CHR(w MOD 100H);
  code[pos+1] := CHR(w DIV 100H MOD 100H);
  code[pos+2] := CHR(w DIV 10000H MOD 100H);
  code[pos+3] := CHR(w DIV 1000000H MOD 100H)
 END PutWordAt;

 PROCEDURE GetWord*(pos: LONGINT; VAR w: LONGINT);
 BEGIN
  w := ORD(code[pos]) + ORD(code[pos+1]) * 100H +
       ORD(code[pos+2]) * 10000H + ORD(code[pos+3]) * 1000000H 
       (* little-endian *)
 END GetWord;

 PROCEDURE PutByteAt*(pos: LONGINT; b: INTEGER);
 BEGIN
  code[pos] := CHR(b MOD 256)
 END PutByteAt;

 PROCEDURE PutDWord*(w: LONGINT);
 BEGIN PutWord(w)
 END PutDWord;

 PROCEDURE PutDWordAt*(pos: LONGINT; w: LONGINT);
 BEGIN PutWordAt(pos, w)
 END PutDWordAt;

 PROCEDURE GetDWord*(pos: LONGINT; VAR w: LONGINT);
 BEGIN GetWord(pos, w)
 END GetDWord;

(* Constant area *)

 PROCEDURE PutConsDWord*(pos: LONGINT; val: LONGINT);
 BEGIN
  constant[pos] := CHR(val MOD 100H);
  constant[pos+1] := CHR(val DIV 100H MOD 100H);
  constant[pos+2] := CHR(val DIV 10000H MOD 100H);
  constant[pos+3] := CHR(val DIV 1000000H MOD 100H)
 END PutConsDWord;

 PROCEDURE GetConsDWord*(pos: LONGINT; VAR val: LONGINT);
 BEGIN
  val := ORD(constant[pos]) + ORD(constant[pos+1]) * 100H +
         ORD(constant[pos+2]) * 10000H + ORD(constant[pos+3]) * 1000000H
 END GetConsDWord;

(*  encoding helpers *)

 PROCEDURE CanEncodeImm*(imm: LONGINT; VAR encoding: LONGINT): BOOLEAN;
  VAR val, rot: LONGINT;
 BEGIN
  val := imm;
  rot := 0;
  IF (val >= 0) & (val <= 255) THEN
   encoding := val; RETURN TRUE
  END;
  (* Try all 16 rotation values *)
  rot := 1;
  WHILE rot <= 15 DO
    (* Rotate val right by 2*rot to see if we get an 8-bit value *)
    val := SYSTEM.ROT(imm, rot*2);   
    IF (val >= 0) & (val <= 255) THEN
    encoding := rot * 100H + val;
    RETURN TRUE
   END;
   INC(rot)
  END;
  RETURN FALSE
 END CanEncodeImm;

 PROCEDURE EncodeImm12*(imm: LONGINT): LONGINT;
  VAR encoding: LONGINT;
 BEGIN
  IF CanEncodeImm(imm, encoding) THEN RETURN encoding
  ELSE HALT(BUG); RETURN 0
  END
 END EncodeImm12;

(* Data Processing *)

 PROCEDURE GenDataProcImm*(cond, op, S, Rd, Rn, imm12: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 2000000H + (* I=1 *)
           op * 200000H + S * 100000H +
           Rn * 10000H + Rd * 1000H + imm12;
  PutWord(instr)
 END GenDataProcImm;

 PROCEDURE GenDataProcReg*(cond, op, S, Rd, Rn, Rm, shiftType, shiftAmt: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + (* I=0 *)
           op * 200000H + S * 100000H +
           Rn * 10000H + Rd * 1000H +
           shiftAmt * 80H + shiftType * 20H + Rm;
  PutWord(instr)
 END GenDataProcReg;

 PROCEDURE GenDataProcRegShiftReg*(cond, op, S, Rd, Rn, Rm, shiftType, Rs: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H +
           op * 200000H + S * 100000H +
           Rn * 10000H + Rd * 1000H +
           Rs * 100H + shiftType * 20H + 10H + Rm;
  PutWord(instr)
 END GenDataProcRegShiftReg;

(* wrappers for common data processing *)

 PROCEDURE GenMOVImm*(cond, Rd, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpMOV, 0, Rd, 0, enc)
 END GenMOVImm;

 PROCEDURE GenMOVReg*(cond, Rd, Rm: LONGINT);
 BEGIN
  GenDataProcReg(cond, dpMOV, 0, Rd, 0, Rm, ShiftLSL, 0)
 END GenMOVReg;

 PROCEDURE GenMVNImm*(cond, Rd, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpMVN, 0, Rd, 0, enc)
 END GenMVNImm;

 PROCEDURE GenADD*(cond, Rd, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpADD, 0, Rd, Rn, Rm, ShiftLSL, 0)
 END GenADD;

 PROCEDURE GenADDImm*(cond, Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpADD, 0, Rd, Rn, enc)
 END GenADDImm;

 PROCEDURE GenSUB*(cond, Rd, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpSUB, 0, Rd, Rn, Rm, ShiftLSL, 0)
 END GenSUB;

 PROCEDURE GenSUBImm*(cond, Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpSUB, 0, Rd, Rn, enc)
 END GenSUBImm;

 PROCEDURE GenRSB*(cond, Rd, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpRSB, 0, Rd, Rn, Rm, ShiftLSL, 0)
 END GenRSB;

 PROCEDURE GenRSBImm*(cond, Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpRSB, 0, Rd, Rn, enc)
 END GenRSBImm;

 PROCEDURE GenANDReg*(cond, Rd, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpAND, 0, Rd, Rn, Rm, ShiftLSL, 0)
 END GenANDReg;

 PROCEDURE GenANDImm*(cond, Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpAND, 0, Rd, Rn, enc)
 END GenANDImm;

 PROCEDURE GenORRReg*(cond, Rd, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpORR, 0, Rd, Rn, Rm, ShiftLSL, 0)
 END GenORRReg;

 PROCEDURE GenORRImm*(cond, Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpORR, 0, Rd, Rn, enc)
 END GenORRImm;

 PROCEDURE GenEORReg*(cond, Rd, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpEOR, 0, Rd, Rn, Rm, ShiftLSL, 0)
 END GenEORReg;

 PROCEDURE GenEORImm*(cond, Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpEOR, 0, Rd, Rn, enc)
 END GenEORImm;

 PROCEDURE GenBICReg*(cond, Rd, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpBIC, 0, Rd, Rn, Rm, ShiftLSL, 0)
 END GenBICReg;

 PROCEDURE GenBICImm*(cond, Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpBIC, 0, Rd, Rn, enc)
 END GenBICImm;

 PROCEDURE GenCMPReg*(cond, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpCMP, 1, 0, Rn, Rm, ShiftLSL, 0)
 END GenCMPReg;

 PROCEDURE GenCMPImm*(cond, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpCMP, 1, 0, Rn, enc)
 END GenCMPImm;

 PROCEDURE GenTSTReg*(cond, Rn, Rm: LONGINT);
 BEGIN GenDataProcReg(cond, dpTST, 1, 0, Rn, Rm, ShiftLSL, 0)
 END GenTSTReg;

 PROCEDURE GenTSTImm*(cond, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  enc := EncodeImm12(imm);
  GenDataProcImm(cond, dpTST, 1, 0, Rn, enc)
 END GenTSTImm;

(*  Shift/Rotate *)

 PROCEDURE GenShiftImm*(cond, Rd, Rm, shiftType, shiftAmt: LONGINT);
 BEGIN
  GenDataProcReg(cond, dpMOV, 0, Rd, 0, Rm, shiftType, shiftAmt)
 END GenShiftImm;

 PROCEDURE GenShiftReg*(cond, Rd, Rm, shiftType, Rs: LONGINT);
 BEGIN
  GenDataProcRegShiftReg(cond, dpMOV, 0, Rd, 0, Rm, shiftType, Rs)
 END GenShiftReg;

(*  Multiply  *)

 PROCEDURE GenMUL*(cond, Rd, Rm, Rs: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H +
           Rd * 10000H + Rs * 100H + 90H + Rm;
  PutWord(instr)
 END GenMUL;

 PROCEDURE GenMLA*(cond, Rd, Rm, Rs, Rn: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 200000H +
           Rd * 10000H + Rn * 1000H + Rs * 100H + 90H + Rm;
  PutWord(instr)
 END GenMLA;

 PROCEDURE GenSDIV*(cond, Rd, Rn, Rm: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 710000H * 10H +
           Rd * 10000H + 0F000H + Rm * 100H + 10H + Rn;
  PutWord(instr)
 END GenSDIV;

 PROCEDURE GenUDIV*(cond, Rd, Rn, Rm: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 730000H * 10H +
           Rd * 10000H + 0F000H + Rm * 100H + 10H + Rn;
  PutWord(instr)
 END GenUDIV;


 PROCEDURE GenMOVW*(cond, Rd, imm16: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 3000000H +
           (imm16 DIV 1000H MOD 10H) * 10000H +
           Rd * 1000H + (imm16 MOD 1000H);
  PutWord(instr)
 END GenMOVW;

 PROCEDURE GenMOVT*(cond, Rd, imm16: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 3400000H +
           (imm16 DIV 1000H MOD 10H) * 10000H +
           Rd * 1000H + (imm16 MOD 1000H);
  PutWord(instr)
 END GenMOVT;

 PROCEDURE LoadImm32*(cond, Rd, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF CanEncodeImm(imm, enc) THEN
   GenDataProcImm(cond, dpMOV, 0, Rd, 0, enc)
  ELSIF CanEncodeImm(-1-imm, enc) THEN (* try MVN *)
   GenDataProcImm(cond, dpMVN, 0, Rd, 0, enc)
  ELSE
   GenMOVW(cond, Rd, imm MOD 10000H);
   IF (imm < 0) OR (imm >= 10000H) THEN
    GenMOVT(cond, Rd, imm DIV 10000H MOD 10000H)
   END
  END
 END LoadImm32;

(*  Load/Store  *)

 PROCEDURE GenLDR*(cond, Rd, Rn, offset: LONGINT);
 (* Encoding: cond 01 I=0 P=1 U W=0 L=1 Rn Rd offset12 *)
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 5100000H + U * 800000H +
           Rn * 10000H + Rd * 1000H + offset;
  PutWord(instr)
 END GenLDR;

 PROCEDURE GenLDRB*(cond, Rd, Rn, offset: LONGINT);
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 5500000H + U * 800000H +
           Rn * 10000H + Rd * 1000H + offset;
  PutWord(instr)
 END GenLDRB;

 PROCEDURE GenLDRH*(cond, Rd, Rn, offset: LONGINT);
 (*  Encoding: cond 000 P=1 U 1 W=0 L=1 Rn Rd imm4H 1011 imm4L *)
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 100H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 15000B0H + U * 800000H +
           Rn * 10000H + Rd * 1000H +
           (offset DIV 10H) * 100H + (offset MOD 10H);
  PutWord(instr)
 END GenLDRH;

 PROCEDURE GenLDRSB*(cond, Rd, Rn, offset: LONGINT);
  (*Enc: cond 000 P=1 U 1 W=0 L=1 Rn Rd imm4H 1101 imm4L *)
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 100H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 15000D0H + U * 800000H +
           Rn * 10000H + Rd * 1000H +
           (offset DIV 10H) * 100H + (offset MOD 10H);
  PutWord(instr)
 END GenLDRSB;

 PROCEDURE GenLDRSH*(cond, Rd, Rn, offset: LONGINT);
 (* cond 000 P=1 U 1 W=0 L=1 Rn Rd imm4H 1111 imm4L *)
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 100H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 15000F0H + U * 800000H +
           Rn * 10000H + Rd * 1000H +
           (offset DIV 10H) * 100H + (offset MOD 10H);
  PutWord(instr)
 END GenLDRSH;

 PROCEDURE GenSTR*(cond, Rd, Rn, offset: LONGINT);
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 5000000H + U * 800000H +
           Rn * 10000H + Rd * 1000H + offset;
  PutWord(instr)
 END GenSTR;

 PROCEDURE GenSTRB*(cond, Rd, Rn, offset: LONGINT);
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 5400000H + U * 800000H +
           Rn * 10000H + Rd * 1000H + offset;
  PutWord(instr)
 END GenSTRB;

 PROCEDURE GenSTRH*(cond, Rd, Rn, offset: LONGINT);
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 100H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 14000B0H + U * 800000H +
           Rn * 10000H + Rd * 1000H +
           (offset DIV 10H) * 100H + (offset MOD 10H);
  PutWord(instr)
 END GenSTRH;

 PROCEDURE GenLDRReg*(cond, Rd, Rn, Rm, shiftType, shiftAmt: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 7100000H + 800000H + (* P=1, I=1, U=1, L=1 *)
           Rn * 10000H + Rd * 1000H +
           shiftAmt * 80H + shiftType * 20H + Rm;
  PutWord(instr)
 END GenLDRReg;

 PROCEDURE GenSTRReg*(cond, Rd, Rn, Rm, shiftType, shiftAmt: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 7000000H + 800000H + (* P=1, I=1, U=1, L=0 *)
           Rn * 10000H + Rd * 1000H +
           shiftAmt * 80H + shiftType * 20H + Rm;
  PutWord(instr)
 END GenSTRReg;


 PROCEDURE GenSTRPre*(cond, Rd, Rn, offset: LONGINT);
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 5200000H + U * 800000H +
           Rn * 10000H + Rd * 1000H + offset;
  PutWord(instr)
 END GenSTRPre;

 PROCEDURE GenLDRPre*(cond, Rd, Rn, offset: LONGINT);
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
  instr := cond * 10000000H + 5300000H + U * 800000H +
           Rn * 10000H + Rd * 1000H + offset;
  PutWord(instr)
 END GenLDRPre;

 PROCEDURE GenLDRPost*(cond, Rd, Rn, offset: LONGINT);
  VAR instr, U: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
  (* Post-indexed: P=0, W=0, L=1 -> bits[27:26]=01 + 0x00100000 + U*0x00800000 *)
  instr := cond * 10000000H + 4000000H + 100000H + U * 800000H +
           Rn * 10000H + Rd * 1000H + offset;
  PutWord(instr)
 END GenLDRPost;

PROCEDURE GenSTRPost*(cond, Rd, Rn, offset: LONGINT);
 VAR instr, U: LONGINT;
BEGIN
 IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
 IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
 (* Post-indexed: P=0, W=0, L=0 -> bits[27:26]=01 + U*0x00800000 *)
 instr := cond * 10000000H + 4000000H + U * 800000H +
          Rn * 10000H + Rd * 1000H + offset;
 PutWord(instr)
END GenSTRPost;

PROCEDURE GenLDRBPost*(cond, Rd, Rn, offset: LONGINT);
(* Same as GenLDRPost but with B bit (bit 22) = 0x00400000 *)
 VAR instr, U: LONGINT;
BEGIN
 IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
 IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
 instr := cond * 10000000H + 4000000H + 400000H + 100000H + U * 800000H +
          Rn * 10000H + Rd * 1000H + offset;
 PutWord(instr)
END GenLDRBPost;

PROCEDURE GenSTRBPost*(cond, Rd, Rn, offset: LONGINT);
 VAR instr, U: LONGINT;
BEGIN
 IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
 IF offset >= 1000H THEN OPM.err(200); offset := 0 END;
 instr := cond * 10000000H + 4000000H + 400000H + U * 800000H +
          Rn * 10000H + Rd * 1000H + offset;
 PutWord(instr)
END GenSTRBPost;

PROCEDURE GenLDRHPost*(cond, Rd, Rn, offset: LONGINT);
(* Post-indexed halfword load: LDRH Rd, [Rn], #offset
   Encoding: cond 000 P=0 U I=1 W=0 L=1 Rn Rd imm4H 1011 imm4L *)
 VAR instr, U: LONGINT;
BEGIN
 IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
 IF offset >= 100H THEN OPM.err(200); offset := 0 END;
 instr := cond * 10000000H + 5000B0H + U * 800000H +
          Rn * 10000H + Rd * 1000H +
          (offset DIV 10H) * 100H + (offset MOD 10H);
 PutWord(instr)
END GenLDRHPost;

PROCEDURE GenSTRHPost*(cond, Rd, Rn, offset: LONGINT);
(* Post-indexed halfword store: STRH Rd, [Rn], #offset
   Encoding: cond 000 P=0 U I=1 W=0 L=0 Rn Rd imm4H 1011 imm4L *)
 VAR instr, U: LONGINT;
BEGIN
 IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
 IF offset >= 100H THEN OPM.err(200); offset := 0 END;
 instr := cond * 10000000H + 4000B0H + U * 800000H +
          Rn * 10000H + Rd * 1000H +
          (offset DIV 10H) * 100H + (offset MOD 10H);
 PutWord(instr)
END GenSTRHPost;

(* Push/Pop  *)

 PROCEDURE GenPushReg*(cond, Rd: LONGINT);
 BEGIN
  GenSTRPre(cond, Rd, SP, -4)
 END GenPushReg;

 PROCEDURE GenPopReg*(cond, Rd: LONGINT);
 BEGIN
  GenLDRPost(cond, Rd, SP, 4)
 END GenPopReg;

 PROCEDURE GenPUSH*(cond, regList: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 92D0000H + regList;
  PutWord(instr)
 END GenPUSH;

 PROCEDURE GenPOP*(cond, regList: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 8BD0000H + regList;
  PutWord(instr)
 END GenPOP;

(* Branches *)

 PROCEDURE GenB*(cond, offset: LONGINT);
 (* offset is in bytes from current PC+8; will be divided by 4 for encoding *)
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 0A000000H +
           (offset DIV 4) MOD 1000000H;
  PutWord(instr)
 END GenB;

 PROCEDURE GenBL*(cond, offset: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 0B000000H +
           (offset DIV 4) MOD 1000000H;
  PutWord(instr)
 END GenBL;

 PROCEDURE GenBX*(cond, Rm: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 12FFF10H + Rm;
  PutWord(instr)
 END GenBX;

 PROCEDURE GenBLX*(cond, Rm: LONGINT);
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 12FFF30H + Rm;
  PutWord(instr)
 END GenBLX;

(*  VFP (Vector Floating Point) *)

 PROCEDURE GenVLDR*(cond, single: LONGINT; Vd, Rn, offset: LONGINT);
  VAR instr, U, D, Vdn: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF (offset MOD 4 # 0) OR (offset >= 400H) THEN OPM.err(200); offset := 0 END;
  IF single # 0 THEN
   D := Vd MOD 2; Vdn := Vd DIV 2;
   instr := cond * 10000000H + 0D100A00H + U * 800000H + D * 400000H +
            Rn * 10000H + Vdn * 1000H + (offset DIV 4)
  ELSE
   D := Vd DIV 16; Vdn := Vd MOD 16;
   instr := cond * 10000000H + 0D100B00H + U * 800000H + D * 400000H +
            Rn * 10000H + Vdn * 1000H + (offset DIV 4)
  END;
  PutWord(instr)
 END GenVLDR;

 PROCEDURE GenVSTR*(cond, single: LONGINT; Vd, Rn, offset: LONGINT);
  VAR instr, U, D, Vdn: LONGINT;
 BEGIN
  IF offset >= 0 THEN U := 1 ELSE U := 0; offset := -offset END;
  IF (offset MOD 4 # 0) OR (offset >= 400H) THEN OPM.err(200); offset := 0 END;
  IF single # 0 THEN
   D := Vd MOD 2; Vdn := Vd DIV 2;
   instr := cond * 10000000H + 0D000A00H + U * 800000H + D * 400000H +
            Rn * 10000H + Vdn * 1000H + (offset DIV 4)
  ELSE
   D := Vd DIV 16; Vdn := Vd MOD 16;
   instr := cond * 10000000H + 0D000B00H + U * 800000H + D * 400000H +
            Rn * 10000H + Vdn * 1000H + (offset DIV 4)
  END;
  PutWord(instr)
 END GenVSTR;

 PROCEDURE EncodeVFPReg(reg: LONGINT; single: LONGINT; VAR hiNib, loBit: LONGINT);
 (* For single: Sd -> Vd = Sd[4:1], D = Sd[0]; double: Dd -> Vd = Dd[3:0], D = Dd[4] *)
 BEGIN
  IF single # 0 THEN
   hiNib := reg DIV 2;
   loBit := reg MOD 2
  ELSE
   hiNib := reg MOD 16;
   loBit := reg DIV 16
  END
 END EncodeVFPReg;

 PROCEDURE GenVFPDataProc*(cond, single: LONGINT; opc1, opc2: LONGINT; Vd, Vn, Vm: LONGINT);
 (* Generic VFP data processing: cond 1110 opc1[3:0] Vn Vd 101x opc2[1:0] 0 Vm *)
  VAR instr, D, Dd, N, Dn, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vn, single, Dn, N);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H;
  instr := instr + 0E000000H; (* 1110 xxxx *)
  instr := instr + (opc1 MOD 10H) * 100000H;
  instr := instr + D * 400000H;
  instr := instr + Dn * 10000H;
  instr := instr + Dd * 1000H;
  instr := instr + cpnum * 100H;
  instr := instr + N * 80H;
  instr := instr + (opc2 MOD 4) * 40H;
  instr := instr + M * 20H;
  instr := instr + Dm;
  PutWord(instr)
 END GenVFPDataProc;

 PROCEDURE GenVADD*(cond, single: LONGINT; Vd, Vn, Vm: LONGINT);
  VAR instr, D, Dd, N, Dn, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vn, single, Dn, N);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0E300000H + D * 400000H +
           Dn * 10000H + Dd * 1000H + cpnum * 100H +
           N * 80H + M * 20H + Dm;
  PutWord(instr)
 END GenVADD;

 PROCEDURE GenVSUB*(cond, single: LONGINT; Vd, Vn, Vm: LONGINT);
  VAR instr, D, Dd, N, Dn, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vn, single, Dn, N);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0E300000H + D * 400000H +
           Dn * 10000H + Dd * 1000H + cpnum * 100H +
           N * 80H + 40H + M * 20H + Dm;
  PutWord(instr)
 END GenVSUB;

 PROCEDURE GenVMUL*(cond, single: LONGINT; Vd, Vn, Vm: LONGINT);
  VAR instr, D, Dd, N, Dn, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vn, single, Dn, N);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0E200000H + D * 400000H +
           Dn * 10000H + Dd * 1000H + cpnum * 100H +
           N * 80H + M * 20H + Dm;
  PutWord(instr)
 END GenVMUL;

 PROCEDURE GenVDIV*(cond, single: LONGINT; Vd, Vn, Vm: LONGINT);
  VAR instr, D, Dd, N, Dn, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vn, single, Dn, N);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0E800000H + D * 400000H +
           Dn * 10000H + Dd * 1000H + cpnum * 100H +
           N * 80H + M * 20H + Dm;
  PutWord(instr)
 END GenVDIV;

 PROCEDURE GenVABS*(cond, single: LONGINT; Vd, Vm: LONGINT);
   VAR instr, D, Dd, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0EB00000H + D * 400000H +
           Dd * 1000H + cpnum * 100H +
           0C0H + M * 20H + Dm;
  PutWord(instr)
 END GenVABS;

 PROCEDURE GenVNEG*(cond, single: LONGINT; Vd, Vm: LONGINT);
  VAR instr, D, Dd, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0EB10000H + D * 400000H +
           Dd * 1000H + cpnum * 100H +
           40H + M * 20H + Dm;
  PutWord(instr)
 END GenVNEG;

 PROCEDURE GenVCMP*(cond, single: LONGINT; Vd, Vm: LONGINT);
  VAR instr, D, Dd, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0EB40000H + D * 400000H +
           Dd * 1000H + cpnum * 100H +
           40H + M * 20H + Dm;
  PutWord(instr)
 END GenVCMP;

 PROCEDURE GenVMRS*(cond: LONGINT);
 (* Rt must be 0xF (APSR_nzcv), not 0x0 (R0) *)
  VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 0EF1FA10H;
  PutWord(instr)
 END GenVMRS;

 PROCEDURE GenVMOVGPRtoS*(cond, Sn, Rt: LONGINT);
  VAR instr, N, Vn: LONGINT;
 BEGIN
  N := Sn MOD 2; Vn := Sn DIV 2;
  instr := cond * 10000000H + 0E000A10H +
           Vn * 10000H + Rt * 1000H + N * 80H;
  PutWord(instr)
 END GenVMOVGPRtoS;

 PROCEDURE GenVMOVStoGPR*(cond, Rt, Sn: LONGINT);
  VAR instr, N, Vn: LONGINT;
 BEGIN
  N := Sn MOD 2; Vn := Sn DIV 2;
  instr := cond * 10000000H + 0E100A10H +
           Vn * 10000H + Rt * 1000H + N * 80H;
  PutWord(instr)
 END GenVMOVStoGPR;

 PROCEDURE GenVCVTF32S32*(cond, Sd, Sm: LONGINT);
  VAR instr, D, Dd, M, Dm: LONGINT;
 BEGIN
  D := Sd MOD 2; Dd := Sd DIV 2;
  M := Sm MOD 2; Dm := Sm DIV 2;
  instr := cond * 10000000H + 0EB80AC0H + D * 400000H +
           Dd * 1000H + M * 20H + Dm;
  PutWord(instr)
 END GenVCVTF32S32;

 PROCEDURE GenVCVTF64S32*(cond, Dd, Sm: LONGINT);
  VAR instr, D, Ddn, M, Dmn: LONGINT;
 BEGIN
  D := Dd DIV 16; Ddn := Dd MOD 16;
  M := Sm MOD 2; Dmn := Sm DIV 2;
  instr := cond * 10000000H + 0EB80BC0H + D * 400000H +
           Ddn * 1000H + M * 20H + Dmn;
  PutWord(instr)
 END GenVCVTF64S32;

 PROCEDURE GenVCVTF64F32*(cond, Dd, Sm: LONGINT);
  VAR instr, D, Ddn, M, Dmn: LONGINT;
 BEGIN
  D := Dd DIV 16; Ddn := Dd MOD 16;
  M := Sm MOD 2; Dmn := Sm DIV 2;
  instr := cond * 10000000H + 0EB70AC0H + D * 400000H +
           Ddn * 1000H + M * 20H + Dmn;
  PutWord(instr)
 END GenVCVTF64F32;

 PROCEDURE GenVCVTF32F64*(cond, Sd, Dm: LONGINT);
    VAR instr, D, Ddn, M, Dmn: LONGINT;
 BEGIN
  D := Sd MOD 2; Ddn := Sd DIV 2;
  M := Dm DIV 16; Dmn := Dm MOD 16;
  instr := cond * 10000000H + 0EB70BC0H + D * 400000H +
           Ddn * 1000H + M * 20H + Dmn;
  PutWord(instr)
 END GenVCVTF32F64;

 PROCEDURE GenVCVTMS32F32*(cond, Sd, Sm: LONGINT);
 (* Since targets include Cortex-A53 (ARMv8), we use VCVTM: *)
  VAR instr, D, Dd, M, Dm: LONGINT;
 BEGIN
  D := Sd MOD 2; Dd := Sd DIV 2;
  M := Sm MOD 2; Dm := Sm DIV 2;
  instr := 0FEBB0A40H + D * 400000H + 0F000H +
           Dd * 1000H + M * 20H + Dm;
  PutWord(instr)
 END GenVCVTMS32F32;

 PROCEDURE GenVCVTMS32F64*(cond, Sd, Dm: LONGINT);
  VAR instr, D, Dd, M, Dmn: LONGINT;
 BEGIN
  D := Sd MOD 2; Dd := Sd DIV 2;
  M := Dm DIV 16; Dmn := Dm MOD 16;
  instr := 0FEBB0B40H + D * 400000H + 0F000H +
           Dd * 1000H + M * 20H + Dmn;
  PutWord(instr)
 END GenVCVTMS32F64;

 PROCEDURE GenVCVTS32F32*(cond, Sd, Sm: LONGINT);
  VAR instr, D, Dd, M, Dm: LONGINT;
 BEGIN
  D := Sd MOD 2; Dd := Sd DIV 2;
  M := Sm MOD 2; Dm := Sm DIV 2;
  instr := cond * 10000000H + 0EBD0AC0H + D * 400000H +
           Dd * 1000H + M * 20H + Dm;
  PutWord(instr)
 END GenVCVTS32F32;

 PROCEDURE GenVCVTS32F64*(cond, Sd, Dm: LONGINT);
  VAR instr, D, Dd, M, Dmn: LONGINT;
 BEGIN
  D := Sd MOD 2; Dd := Sd DIV 2;
  M := Dm DIV 16; Dmn := Dm MOD 16;
  instr := cond * 10000000H + 0EBD0BC0H + D * 400000H +
           Dd * 1000H + M * 20H + Dmn;
  PutWord(instr)
 END GenVCVTS32F64;

 PROCEDURE GenVMOVF*(cond, single: LONGINT; Vd, Vm: LONGINT);
  VAR instr, D, Dd, M, Dm, cpnum: LONGINT;
 BEGIN
  EncodeVFPReg(Vd, single, Dd, D);
  EncodeVFPReg(Vm, single, Dm, M);
  IF single # 0 THEN cpnum := 0AH ELSE cpnum := 0BH END;
  instr := cond * 10000000H + 0EB00000H + D * 400000H +
           Dd * 1000H + cpnum * 100H +
           40H + M * 20H + Dm;
  PutWord(instr)
 END GenVMOVF;


 PROCEDURE GenVPUSHS*(cond, Sd, count: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Sd MOD 2; Vd := Sd DIV 2;
  instr := cond * 10000000H + 0D2D0A00H + D * 400000H +
           Vd * 1000H + count;
  PutWord(instr)
 END GenVPUSHS;

 PROCEDURE GenVPUSHD*(cond, Dd, count: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Dd DIV 16; Vd := Dd MOD 16;
  instr := cond * 10000000H + 0D2D0B00H + D * 400000H +
           Vd * 1000H + count * 2;
  PutWord(instr)
 END GenVPUSHD;

 PROCEDURE GenVPOPS*(cond, Sd, count: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Sd MOD 2; Vd := Sd DIV 2;
  instr := cond * 10000000H + 0CBD0A00H + D * 400000H +
           Vd * 1000H + count;
  PutWord(instr)
 END GenVPOPS;

 PROCEDURE GenVPOPD*(cond, Dd, count: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Dd DIV 16; Vd := Dd MOD 16;
  instr := cond * 10000000H + 0CBD0B00H + D * 400000H +
           Vd * 1000H + count * 2;
  PutWord(instr)
 END GenVPOPD;

 PROCEDURE GenVSTMDBS*(cond, Rn, Sd: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Sd MOD 2; Vd := Sd DIV 2;
  instr := cond * 10000000H + 0D200A00H + D * 400000H +
           Rn * 10000H + Vd * 1000H + 1;
  PutWord(instr)
 END GenVSTMDBS;

 PROCEDURE GenVSTMDBD*(cond, Rn, Dd: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Dd DIV 16; Vd := Dd MOD 16;
  instr := cond * 10000000H + 0D200B00H + D * 400000H +
           Rn * 10000H + Vd * 1000H + 2;
  PutWord(instr)
 END GenVSTMDBD;

 PROCEDURE GenVLDMIAS*(cond, Rn, Sd: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Sd MOD 2; Vd := Sd DIV 2;
  instr := cond * 10000000H + 0CB00A00H + D * 400000H +
           Rn * 10000H + Vd * 1000H + 1;
  PutWord(instr)
 END GenVLDMIAS;

 PROCEDURE GenVLDMIAD*(cond, Rn, Dd: LONGINT);
  VAR instr, D, Vd: LONGINT;
 BEGIN
  D := Dd DIV 16; Vd := Dd MOD 16;
  instr := cond * 10000000H + 0CB00B00H + D * 400000H +
           Rn * 10000H + Vd * 1000H + 2;
  PutWord(instr)
 END GenVLDMIAD;

(*  Data Memory Barrier *)

 PROCEDURE GenDMBISH*;
 (* Spec says 0xF57FF05A which is DMB ISHST *)
 BEGIN
  PutWord(057FF05AH + 0F0000000H) (* 0xF57FF05A *)
 END GenDMBISH;

(* Sign/Zero Extension etc. *)

 PROCEDURE GenSXTB*(cond, Rd, Rm: LONGINT);
 BEGIN
  PutWord(cond * 10000000H + 6AF0070H + Rd * 1000H + Rm)
 END GenSXTB;

 PROCEDURE GenSXTH*(cond, Rd, Rm: LONGINT);
 BEGIN
  PutWord(cond * 10000000H + 6BF0070H + Rd * 1000H + Rm)
 END GenSXTH;

 PROCEDURE GenUXTB*(cond, Rd, Rm: LONGINT);
 BEGIN
  PutWord(cond * 10000000H + 6EF0070H + Rd * 1000H + Rm)
 END GenUXTB;

 PROCEDURE GenUXTH*(cond, Rd, Rm: LONGINT);
 BEGIN
  PutWord(cond * 10000000H + 6FF0070H + Rd * 1000H + Rm)
 END GenUXTH;

 PROCEDURE GenCLZ*(cond, Rd, Rm: LONGINT);
   VAR instr: LONGINT;
 BEGIN
  instr := cond * 10000000H + 16F0F10H + Rd * 1000H + Rm;
  PutWord(instr)
 END GenCLZ;

 PROCEDURE GenNOP*(cond: LONGINT);
 BEGIN
  GenMOVReg(cond, R0, R0)
 END GenNOP;

 PROCEDURE InlineCode*(VAR asmCode: ARRAY OF CHAR; parSize: INTEGER);
  VAR i, n: INTEGER;
 BEGIN
  n := ORD(asmCode[0]); i := 1;
  WHILE i <= n DO PutByte(ORD(asmCode[i])); INC(i) END
 END InlineCode;

BEGIN
 NEW(constant, 1024)
END OPO.
