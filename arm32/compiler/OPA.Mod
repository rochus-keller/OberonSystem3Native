(* OPA - Inline assembler for ARM32 (ARMv7-A A32 encoding only, no Thumb) 

  Supported instruction categories:
    - Data processing (ADD, SUB, AND, ORR, EOR, BIC, MOV, MVN, CMP, CMN, TST, TEQ, RSB, RSC, ADC, SBC)
    - Multiply (MUL, MLA, UMULL, UMLAL, SMULL, SMLAL)
    - Divide (SDIV, UDIV)
    - Load/Store (LDR, LDRB, LDRH, LDRSB, LDRSH, STR, STRB, STRH)
    - Branch (B, BL, BX, BLX)
    - VFP scalar (VADD, VSUB, VMUL, VDIV, VABS, VNEG, VCMP, VMOV, VLDR, VSTR, VCVT, VMRS)
    - System (NOP, DMB, DSB, ISB, BKPT, SVC, CPSIE, CPSID, MRS, MSR, MCR, MRC)
    - Stack (PUSH, POP)
    - Shift/Rotate (LSL, LSR, ASR, ROR, RRX)
    - Bit manipulation (CLZ, RBIT, REV, MOVW, MOVT)
    - Data directives (DCD, DCB, DCW)
    
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

MODULE OPA; (** non-portable *)
 IMPORT SYSTEM, OPM, OPS, OPT, OPB;

 CONST
  none = -1;

  (* Processor targets *)
  ARMv7A = 0;

  (* Node classes for inline instructions *)
  Nassembler = 29;
  Ncode = 30;
  Nfixup = 31;

  (* Own Symbol Table types *)
  StLabel = 0; StFwdLabel = 1;
  StConst = 3; StType = 4; StVar = 5; StVarPar = 6; StGlobal = 7;
  StMod = 11;

  (* Addressing modes for ARM32 *)
  RegMode = 08H;     (* GPR register R0-R15 *)
  SRegMode = 10H;    (* Single-precision VFP register S0-S31 *)
  DRegMode = 18H;    (* Double-precision VFP register D0-D31 *)
  ImmMode = 20H;     (* Immediate value *)
  MemMode = 28H;     (* Memory [Rn, #offset] or [Rn, Rm] *)
  LabelMode = 30H;   (* Label reference *)
  FwdLabelMode = 31H; (* Forward label reference *)
  ShiftMode = 38H;   (* Shift specifier: LSL, LSR, ASR, ROR *)
  RegListMode = 40H; (* Register list {R0, R1, ...} *)
  CondMode = 48H;    (* Condition code *)

  (* ARM32 condition codes *)
  CondEQ = 0; CondNE = 1; CondCS = 2; CondCC = 3;
  CondMI = 4; CondPL = 5; CondVS = 6; CondVC = 7;
  CondHI = 8; CondLS = 9; CondGE = 10; CondLT = 11;
  CondGT = 12; CondLE = 13; CondAL = 14;

  (* Shift types *)
  ShLSL = 0; ShLSR = 1; ShASR = 2; ShROR = 3;

  (* Instruction categories *)
  CatDP = 0;      (* Data processing *)
  CatMul = 1;     (* Multiply *)
  CatDiv = 2;     (* Divide *)
  CatLdSt = 3;    (* Load/Store word/byte *)
  CatLdStH = 4;   (* Load/Store halfword/signed *)
  CatBranch = 5;  (* Branch *)
  CatBX = 6;      (* Branch exchange *)
  CatVFP2 = 7;    (* VFP 2-operand *)
  CatVFP3 = 8;    (* VFP 3-operand *)
  CatVLdSt = 9;   (* VFP load/store *)
  CatSys = 10;    (* System instructions *)
  CatPushPop = 11; (* PUSH/POP *)
  CatMOVW = 12;   (* MOVW/MOVT 16-bit immediate *)
  CatCLZ = 13;    (* Count leading zeros *)
  CatNOP = 14;    (* NOP and barriers *)
  CatCPS = 15;    (* CPSIE/CPSID *)
  CatCopro = 16;  (* Coprocessor MCR/MRC *)
  CatMSR = 17;    (* MSR/MRS *)
  CatData = 18;   (* DCD, DCB, DCW data directives *)
  CatVMOV = 19;   (* VMOV between GPR and VFP *)
  CatVMRS = 20;   (* VMRS/VMSR *)
  CatVCVT = 21;   (* VFP conversion *)
  CatShift = 22;  (* LSL, LSR, ASR, ROR as instructions *)

  (* Scanner: ASCII codes *)
  TAB = 09X;
  CR = 0DX;
  LF = 0AX;
  SPACE = 20X;

  (* Scanner: Sym values *)
  ScUndef = 0;
  ScIdent = 1;
  ScSemicolon = 2;
  ScAt = 3;
  ScNumber = 4;
  ScComma = 5;
  ScLBrak = 6;
  ScRBrak = 7;
  ScCR = 8;
  ScMult = 9;
  ScEnd = 10;
  ScLabel = 11;
  ScColon = 12;
  ScPlus = 13;
  ScMinus = 14;
  ScDiv = 15;
  ScLPar = 16;
  ScRPar = 17;
  ScString = 18;
  ScPoint = 19;
  ScLBrace = 20;
  ScRBrace = 21;
  ScHash = 22;
  ScExcl = 23;

  (* Structure sizes *)
  NameLen = 32;
  MaxStrLen = 256;
  MnemoLen = 12;

  (* Instruction table sizes *)
  MaxInstr = 256;
  InstrHashSize = 512;

  (* Data processing opcodes *)
  dpAND = 0; dpEOR = 1; dpSUB = 2; dpRSB = 3;
  dpADD = 4; dpADC = 5; dpSBC = 6; dpRSC = 7;
  dpTST = 8; dpTEQ = 9; dpCMP = 10; dpCMN = 11;
  dpORR = 12; dpMOV = 13; dpBIC = 14; dpMVN = 15;

 TYPE
  Name = OPS.Name;
  Mnemo = ARRAY MnemoLen OF CHAR;

  Object = POINTER TO ObjDesc;
  FixPnt = POINTER TO FixPntDesc;

  InstrDesc = RECORD
   name: Mnemo;
   cat: SHORTINT;       (* instruction category *)
   op: LONGINT;         (* primary opcode or subop *)
   flags: SET;          (* instruction flags *)
  END;

  Operand = RECORD
   mode: LONGINT;
   reg: INTEGER;       (* register number *)
   imm: LONGINT;       (* immediate value *)
   disp: LONGINT;      (* displacement *)
   base: INTEGER;      (* base register for memory *)
   index: INTEGER;     (* index register for memory *)
   shift: INTEGER;     (* shift type *)
   shiftAmt: INTEGER;  (* shift amount *)
   regList: SET;       (* register list for PUSH/POP *)
   obj: Object;        (* for fixups *)
   writeback: BOOLEAN; (* writeback flag '!' *)
   preIndex: BOOLEAN;  (* pre-indexed addressing *)
   dbl: BOOLEAN;       (* double-precision for VFP *)
  END;

  ObjDesc = RECORD
   typ: LONGINT;
   val, size: LONGINT;
   name: Name;
   left, right, next: Object;
   fix: FixPnt;
   obj: OPT.Object
  END;

  FixPntDesc = RECORD
   pc: LONGINT;
   node: OPT.Node;
   pos: LONGINT;
   next: FixPnt;
  END;

 VAR
  root: Object;
  InstrTab: ARRAY MaxInstr OF InstrDesc;
  InstrHash: ARRAY InstrHashSize OF INTEGER; (* hash -> InstrTab index, -1 = empty *)
  nofInstr: INTEGER;
  SizeTab: ARRAY 17 OF SHORTINT;

  export, inline: BOOLEAN;
  FirstTime: BOOLEAN;
  Target: SET;
  pc: LONGINT;

  sym: LONGINT;
  ident: Name;
  val: LONGINT;
  str: ARRAY MaxStrLen OF CHAR;
  errpos: LONGINT;

  first, last: OPT.Node;
  fixlist: OPT.Node;

  condCode: SHORTINT; (* condition code for current instruction *)

(* ------------------------------------------------------------------- *)
(* Utility functions *)

 PROCEDURE AND(a, b: LONGINT): LONGINT;
 BEGIN RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, a) * SYSTEM.VAL(SET, b))
 END AND;

 PROCEDURE ORL(a, b: LONGINT): LONGINT;
 BEGIN RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, a) + SYSTEM.VAL(SET, b))
 END ORL;

(* ------------------------------------------------------------------- *)
(* Symbol Table functions *)

 PROCEDURE insert(VAR name: ARRAY OF CHAR; VAR obj: Object);
  VAR ob0, ob1: Object; d: LONGINT;
 BEGIN
  ob0 := root; ob1 := ob0.right; d := 1;
  LOOP
   IF ob1 = NIL THEN
    NEW(ob1); COPY(name, ob1.name); ob1.typ := StFwdLabel;
    ob1.left := NIL; ob1.right := NIL; ob1.fix := NIL; ob1.obj := NIL;
    ob1.next := root.next; root.next := ob1;
    ob1.val := OPM.errpos;
    IF d < 0 THEN ob0.left := ob1 ELSE ob0.right := ob1 END;
    EXIT
   ELSIF name < ob1.name THEN d := -1; ob0 := ob1; ob1 := ob1.left
   ELSIF name > ob1.name THEN d := 1; ob0 := ob1; ob1 := ob1.right
   ELSE EXIT
   END
  END;
  obj := ob1
 END insert;

 PROCEDURE ConvertObj(ob: OPT.Object): Object;
  VAR obj: Object;
 BEGIN
  IF ob # NIL THEN
   NEW(obj);
   CASE ob.mode OF
    1: (* Var *)
     obj.val := 1; obj.size := SizeTab[ob.typ.form];
     IF ob.mnolev <= 0 THEN obj.typ := StGlobal
     ELSE obj.typ := StVar
     END
    | 2: (* VarPar *)
     obj.typ := StVarPar; obj.val := 1; obj.size := 4
    | 3: (* Con *)
     obj.typ := StConst; obj.val := ob.conval.intval;
     IF (ob.typ.form > 6) OR (ob.typ.form = 2) THEN OPM.err(51) END
    | 5: (* Type *)
     obj.typ := StType; obj.size := SizeTab[ob.typ.form]; OPM.err(514)
    | 11: (* Mod *)
     obj.typ := StMod
   ELSE
    obj.typ := StConst; obj.val := 0; OPM.err(514)
   END;
   obj.obj := ob
  END;
  RETURN obj
 END ConvertObj;

 PROCEDURE find(VAR name: Name; VAR obj: Object);
  VAR ob0: Object; ob: OPT.Object;
 BEGIN
  ob0 := root.right;
  WHILE (ob0 # NIL) & (ob0.name # name) DO
   IF name < ob0.name THEN ob0 := ob0.left ELSE ob0 := ob0.right END
  END;
  obj := ob0;
  IF obj = NIL THEN
   COPY(name, OPS.name); OPT.Find(ob);
   IF ob # NIL THEN obj := ConvertObj(ob)
   ELSE insert(name, obj)
   END
  END
 END find;

(* ------------------------------------------------------------------- *)
(* Instruction Table - Embedded directly (no external OPA.Data file) *)

 PROCEDURE HashInstr(VAR name: ARRAY OF CHAR): LONGINT;
  VAR i, k: LONGINT;
 BEGIN
  i := 0; k := 0;
  WHILE name[i] # 0X DO
   k := (k * 31 + ORD(name[i])) MOD InstrHashSize;
   INC(i)
  END;
  RETURN k
 END HashInstr;

 PROCEDURE AddInstr(name: ARRAY OF CHAR; cat: SHORTINT; op: LONGINT; flags: SET);
  VAR h, n: LONGINT;
 BEGIN
  ASSERT(nofInstr < MaxInstr);
  COPY(name, InstrTab[nofInstr].name);
  InstrTab[nofInstr].cat := cat;
  InstrTab[nofInstr].op := op;
  InstrTab[nofInstr].flags := flags;
  (* Insert into hash table *)
  h := HashInstr(name);
  WHILE InstrHash[h] >= 0 DO h := (h + 1) MOD InstrHashSize END;
  InstrHash[h] := nofInstr;
  INC(nofInstr)
 END AddInstr;

 PROCEDURE FindInstruction(VAR name: ARRAY OF CHAR; VAR inx: LONGINT);
  VAR h, n: LONGINT;
 BEGIN
  h := HashInstr(name);
  n := 0;
  WHILE (n < InstrHashSize) & (InstrHash[h] >= 0) DO
   IF InstrTab[InstrHash[h]].name = name THEN
    inx := InstrHash[h]; RETURN
   END;
   h := (h + 1) MOD InstrHashSize;
   INC(n)
  END;
  inx := -1
 END FindInstruction;

 PROCEDURE BuildInstrTable;
 (* Build the complete ARM32 A32 instruction table *)
 (* All tables are embedded directly - no external file needed *)
 BEGIN
  nofInstr := 0;

  (* Data Processing instructions *)
  (* CatDP: op field = data processing opcode (0-15) *)
  AddInstr("AND", CatDP, dpAND, {});
  AddInstr("EOR", CatDP, dpEOR, {});
  AddInstr("SUB", CatDP, dpSUB, {});
  AddInstr("RSB", CatDP, dpRSB, {});
  AddInstr("ADD", CatDP, dpADD, {});
  AddInstr("ADC", CatDP, dpADC, {});
  AddInstr("SBC", CatDP, dpSBC, {});
  AddInstr("RSC", CatDP, dpRSC, {});
  AddInstr("TST", CatDP, dpTST, {});
  AddInstr("TEQ", CatDP, dpTEQ, {});
  AddInstr("CMP", CatDP, dpCMP, {});
  AddInstr("CMN", CatDP, dpCMN, {});
  AddInstr("ORR", CatDP, dpORR, {});
  AddInstr("MOV", CatDP, dpMOV, {});
  AddInstr("BIC", CatDP, dpBIC, {});
  AddInstr("MVN", CatDP, dpMVN, {});

  (* Shift instructions (as standalone instructions) *)
  AddInstr("LSL", CatShift, ShLSL, {});
  AddInstr("LSR", CatShift, ShLSR, {});
  AddInstr("ASR", CatShift, ShASR, {});
  AddInstr("ROR", CatShift, ShROR, {});

  (* Multiply instructions *)
  (* CatMul: op field = 0=MUL, 1=MLA, 2=UMULL, 3=UMLAL, 4=SMULL, 5=SMLAL *)
  AddInstr("MUL", CatMul, 0, {});
  AddInstr("MLA", CatMul, 1, {});
  AddInstr("UMULL", CatMul, 2, {});
  AddInstr("UMLAL", CatMul, 3, {});
  AddInstr("SMULL", CatMul, 4, {});
  AddInstr("SMLAL", CatMul, 5, {});

  (* Divide instructions *)
  AddInstr("SDIV", CatDiv, 0, {});
  AddInstr("UDIV", CatDiv, 1, {});

  (* Load/Store word and byte *)
  (* CatLdSt: op = 0=LDR, 1=LDRB, 2=STR, 3=STRB *)
  AddInstr("LDR", CatLdSt, 0, {});
  AddInstr("LDRB", CatLdSt, 1, {});
  AddInstr("STR", CatLdSt, 2, {});
  AddInstr("STRB", CatLdSt, 3, {});

  (* Load/Store halfword and signed *)
  (* CatLdStH: op = 0=LDRH, 1=LDRSH, 2=LDRSB, 3=STRH *)
  AddInstr("LDRH", CatLdStH, 0, {});
  AddInstr("LDRSH", CatLdStH, 1, {});
  AddInstr("LDRSB", CatLdStH, 2, {});
  AddInstr("STRH", CatLdStH, 3, {});

  (* Branch instructions *)
  AddInstr("B", CatBranch, 0, {});
  AddInstr("BL", CatBranch, 1, {});
  AddInstr("BX", CatBX, 0, {});
  AddInstr("BLX", CatBX, 1, {});

  (* PUSH/POP *)
  AddInstr("PUSH", CatPushPop, 0, {});
  AddInstr("POP", CatPushPop, 1, {});

  (* MOVW/MOVT - 16-bit immediate *)
  AddInstr("MOVW", CatMOVW, 0, {});
  AddInstr("MOVT", CatMOVW, 1, {});

  (* CLZ and bit manipulation *)
  AddInstr("CLZ", CatCLZ, 0, {});
  AddInstr("RBIT", CatCLZ, 1, {});
  AddInstr("REV", CatCLZ, 2, {});

  (* NOP and barriers *)
  (* CatNOP: op = 0=NOP, 1=DMB, 2=DSB, 3=ISB *)
  AddInstr("NOP", CatNOP, 0, {});
  AddInstr("DMB", CatNOP, 1, {});
  AddInstr("DSB", CatNOP, 2, {});
  AddInstr("ISB", CatNOP, 3, {});
  AddInstr("BKPT", CatNOP, 4, {});
  AddInstr("SVC", CatNOP, 5, {});

  (* CPS instructions *)
  AddInstr("CPSIE", CatCPS, 0, {});
  AddInstr("CPSID", CatCPS, 1, {});

  (* Coprocessor access *)
  AddInstr("MCR", CatCopro, 0, {});
  AddInstr("MRC", CatCopro, 1, {});

  (* MSR/MRS *)
  AddInstr("MSR", CatMSR, 0, {});
  AddInstr("MRS", CatMSR, 1, {});

  (* VFP 3-operand: VADD, VSUB, VMUL, VDIV *)
  (* CatVFP3: op = 0=VADD, 1=VSUB, 2=VMUL, 3=VDIV *)
  AddInstr("VADD", CatVFP3, 0, {});
  AddInstr("VSUB", CatVFP3, 1, {});
  AddInstr("VMUL", CatVFP3, 2, {});
  AddInstr("VDIV", CatVFP3, 3, {});

  (* VFP 2-operand: VABS, VNEG, VCMP, VSQRT, VMOV (VFP) *)
  (* CatVFP2: op = 0=VABS, 1=VNEG, 2=VCMP, 3=VSQRT, 4=VMOV *)
  AddInstr("VABS", CatVFP2, 0, {});
  AddInstr("VNEG", CatVFP2, 1, {});
  AddInstr("VCMP", CatVFP2, 2, {});
  AddInstr("VSQRT", CatVFP2, 3, {});

  (* VFP load/store *)
  AddInstr("VLDR", CatVLdSt, 0, {});
  AddInstr("VSTR", CatVLdSt, 1, {});

  (* VFP move between GPR and VFP *)
  AddInstr("VMOV", CatVMOV, 0, {});

  (* VMRS/VMSR *)
  AddInstr("VMRS", CatVMRS, 0, {});
  AddInstr("VMSR", CatVMRS, 1, {});

  (* VFP conversion *)
  AddInstr("VCVT", CatVCVT, 0, {});

  (* Data directives *)
  AddInstr("DCD", CatData, 4, {});
  AddInstr("DCW", CatData, 2, {});
  AddInstr("DCB", CatData, 1, {});
 END BuildInstrTable;

(* ------------------------------------------------------------------- *)
(* Scanner functions *)

 PROCEDURE skipBlanks;
 BEGIN
  WHILE (OPS.ch = SPACE) OR (OPS.ch = TAB) DO OPM.Get(OPS.ch) END;
  IF OPS.ch = ";" THEN
   WHILE (OPS.ch # CR) & (OPS.ch # LF) DO OPM.Get(OPS.ch) END
  END
 END skipBlanks;

 PROCEDURE GetIdent(VAR name: Name);
  VAR i: LONGINT;
 BEGIN
  i := 0; OPM.errpos := OPM.curpos - 1;
  REPEAT
   IF i < NameLen - 1 THEN name[i] := OPS.ch; INC(i) END;
   OPM.Get(OPS.ch)
  UNTIL ~(("A" <= CAP(OPS.ch)) & (CAP(OPS.ch) <= "Z") OR ("0" <= OPS.ch) & (OPS.ch <= "9")
     OR (OPS.ch = ".") OR (OPS.ch = "_"));
  name[i] := 0X
 END GetIdent;

 PROCEDURE Get(VAR sym: LONGINT);

  PROCEDURE Comment;
  BEGIN
   OPM.Get(OPS.ch);
   LOOP
    LOOP
     WHILE OPS.ch = "(" DO OPM.Get(OPS.ch);
      IF OPS.ch = "*" THEN Comment END
     END;
     IF OPS.ch = "*" THEN OPM.Get(OPS.ch); EXIT END;
     IF OPS.ch = OPM.Eot THEN EXIT END;
     OPM.Get(OPS.ch)
    END;
    IF OPS.ch = ")" THEN OPM.Get(OPS.ch); EXIT END;
    IF OPS.ch = OPM.Eot THEN OPM.Mark(5, OPM.errpos); EXIT END
   END
  END Comment;

  PROCEDURE Str;
   VAR och: CHAR; i: LONGINT;
  BEGIN
   och := OPS.ch; i := 0;
   LOOP
    OPM.Get(OPS.ch);
    IF OPS.ch = och THEN EXIT
    ELSIF OPS.ch < " " THEN OPM.err(3); EXIT
    ELSIF i = MaxStrLen - 1 THEN OPM.err(241); EXIT
    END;
    str[i] := OPS.ch; INC(i)
   END;
   OPM.Get(OPS.ch);
   str[i] := 0X; val := i
  END Str;

 BEGIN
  skipBlanks;
  OPM.errpos := OPM.curpos;
  CASE OPS.ch OF
   "A".."Z", "a".."z":
    GetIdent(ident);
    IF OPS.ch = ":" THEN
     OPM.Get(OPS.ch); sym := ScLabel
    ELSIF ident = "END" THEN
     sym := ScEnd
    ELSE
     sym := ScIdent
    END
   | "0".."9":
    val := 0; sym := ScNumber;
    OPS.Number;
    ASSERT(OPS.numtyp <= 2);
    val := OPS.intval
   | ";": OPM.Get(OPS.ch); sym := ScSemicolon
   | "@": OPM.Get(OPS.ch); sym := ScAt
   | ",": OPM.Get(OPS.ch); sym := ScComma
   | "[": OPM.Get(OPS.ch); sym := ScLBrak
   | "]": OPM.Get(OPS.ch); sym := ScRBrak
   | "{": OPM.Get(OPS.ch); sym := ScLBrace
   | "}": OPM.Get(OPS.ch); sym := ScRBrace
   | CR: OPM.Get(OPS.ch); sym := ScCR
   | LF: OPM.Get(OPS.ch); sym := ScCR
   | "*": OPM.Get(OPS.ch); sym := ScMult
   | "/": OPM.Get(OPS.ch); sym := ScDiv
   | "+": OPM.Get(OPS.ch); sym := ScPlus
   | "-": OPM.Get(OPS.ch); sym := ScMinus
   | "(": OPM.Get(OPS.ch);
    IF OPS.ch = "*" THEN Comment; Get(sym)
    ELSE sym := ScLPar
    END
   | ")": OPM.Get(OPS.ch); sym := ScRPar
   | ":": OPM.Get(OPS.ch); sym := ScColon
   | ".": OPM.Get(OPS.ch); sym := ScPoint
   | "#": OPM.Get(OPS.ch); sym := ScHash
   | "!": OPM.Get(OPS.ch); sym := ScExcl
   | 22X, 27X: Str; sym := ScString
  ELSE
   sym := ScUndef; OPM.Get(OPS.ch)
  END
 END Get;

 PROCEDURE Check(s: LONGINT);
 BEGIN
  IF sym # s THEN OPM.err(SHORT(s)) END;
  Get(sym)
 END Check;

 PROCEDURE Expression(VAR x: LONGINT);
  VAR y, op: LONGINT;

  PROCEDURE Factor(VAR x: LONGINT);
  BEGIN
   IF sym = ScNumber THEN x := val; Get(sym)
   ELSIF sym = ScLPar THEN
    Get(sym); Expression(x);
    Check(ScRPar)
   ELSE OPM.err(601); x := 0
   END
  END Factor;

  PROCEDURE Term(VAR x: LONGINT);
   VAR y, op: LONGINT;
  BEGIN
   Factor(x);
   WHILE (sym = ScMult) OR (sym = ScDiv) DO
    op := sym; Get(sym);
    Factor(y);
    IF op = ScMult THEN x := x * y ELSE x := x DIV y END
   END
  END Term;

 BEGIN
  IF sym = ScMinus THEN Get(sym); Term(x); x := -x
  ELSE Term(x)
  END;
  WHILE (sym = ScPlus) OR (sym = ScMinus) DO
   op := sym; Get(sym);
   Term(y);
   IF op = ScPlus THEN x := x + y ELSE x := x - y END
  END
 END Expression;

(* ------------------------------------------------------------------- *)
(* Condition code parsing *)

 PROCEDURE ParseCondition(VAR name: ARRAY OF CHAR; VAR cond: SHORTINT; VAR nameLen: LONGINT);
 (* Check if the instruction name ends with a condition code suffix *)
 (* Returns the condition code and the length of the base mnemonic *)
  VAR len: LONGINT;
 BEGIN
  len := 0;
  WHILE name[len] # 0X DO INC(len) END;
  cond := CondAL; nameLen := len;
  IF len >= 3 THEN
   (* Check 2-character condition suffixes *)
   IF (name[len-2] = "E") & (name[len-1] = "Q") THEN cond := CondEQ; nameLen := len - 2
   ELSIF (name[len-2] = "N") & (name[len-1] = "E") THEN cond := CondNE; nameLen := len - 2
   ELSIF (name[len-2] = "C") & (name[len-1] = "S") THEN cond := CondCS; nameLen := len - 2
   ELSIF (name[len-2] = "H") & (name[len-1] = "S") THEN cond := CondCS; nameLen := len - 2
   ELSIF (name[len-2] = "C") & (name[len-1] = "C") THEN cond := CondCC; nameLen := len - 2
   ELSIF (name[len-2] = "L") & (name[len-1] = "O") THEN cond := CondCC; nameLen := len - 2
   ELSIF (name[len-2] = "M") & (name[len-1] = "I") THEN cond := CondMI; nameLen := len - 2
   ELSIF (name[len-2] = "P") & (name[len-1] = "L") THEN cond := CondPL; nameLen := len - 2
   ELSIF (name[len-2] = "V") & (name[len-1] = "S") THEN cond := CondVS; nameLen := len - 2
   ELSIF (name[len-2] = "V") & (name[len-1] = "C") THEN cond := CondVC; nameLen := len - 2
   ELSIF (name[len-2] = "H") & (name[len-1] = "I") THEN cond := CondHI; nameLen := len - 2
   ELSIF (name[len-2] = "L") & (name[len-1] = "S") THEN cond := CondLS; nameLen := len - 2
   ELSIF (name[len-2] = "G") & (name[len-1] = "E") THEN cond := CondGE; nameLen := len - 2
   ELSIF (name[len-2] = "L") & (name[len-1] = "T") THEN cond := CondLT; nameLen := len - 2
   ELSIF (name[len-2] = "G") & (name[len-1] = "T") THEN cond := CondGT; nameLen := len - 2
   ELSIF (name[len-2] = "L") & (name[len-1] = "E") THEN cond := CondLE; nameLen := len - 2
   ELSIF (name[len-2] = "A") & (name[len-1] = "L") THEN cond := CondAL; nameLen := len - 2
   END
  END
 END ParseCondition;

(* ------------------------------------------------------------------- *)
(* Operand parsing *)

 PROCEDURE ParseRegister(VAR name: Name; VAR reg: INTEGER; VAR mode: LONGINT): BOOLEAN;
 (* Parse a register name and return its number and mode *)
 BEGIN
  mode := RegMode;
  IF name = "R0" THEN reg := 0; RETURN TRUE
  ELSIF name = "R1" THEN reg := 1; RETURN TRUE
  ELSIF name = "R2" THEN reg := 2; RETURN TRUE
  ELSIF name = "R3" THEN reg := 3; RETURN TRUE
  ELSIF name = "R4" THEN reg := 4; RETURN TRUE
  ELSIF name = "R5" THEN reg := 5; RETURN TRUE
  ELSIF name = "R6" THEN reg := 6; RETURN TRUE
  ELSIF name = "R7" THEN reg := 7; RETURN TRUE
  ELSIF name = "R8" THEN reg := 8; RETURN TRUE
  ELSIF name = "R9" THEN reg := 9; RETURN TRUE
  ELSIF name = "R10" THEN reg := 10; RETURN TRUE
  ELSIF name = "R11" THEN reg := 11; RETURN TRUE
  ELSIF name = "R12" THEN reg := 12; RETURN TRUE
  ELSIF name = "R13" THEN reg := 13; RETURN TRUE
  ELSIF name = "R14" THEN reg := 14; RETURN TRUE
  ELSIF name = "R15" THEN reg := 15; RETURN TRUE
  ELSIF name = "FP" THEN reg := 11; RETURN TRUE
  ELSIF name = "IP" THEN reg := 12; RETURN TRUE
  ELSIF name = "SP" THEN reg := 13; RETURN TRUE
  ELSIF name = "LR" THEN reg := 14; RETURN TRUE
  ELSIF name = "PC" THEN reg := 15; RETURN TRUE
  (* VFP single-precision registers S0-S31 *)
  ELSIF name[0] = "S" THEN
   mode := SRegMode;
   IF name = "S0" THEN reg := 0; RETURN TRUE
   ELSIF name = "S1" THEN reg := 1; RETURN TRUE
   ELSIF name = "S2" THEN reg := 2; RETURN TRUE
   ELSIF name = "S3" THEN reg := 3; RETURN TRUE
   ELSIF name = "S4" THEN reg := 4; RETURN TRUE
   ELSIF name = "S5" THEN reg := 5; RETURN TRUE
   ELSIF name = "S6" THEN reg := 6; RETURN TRUE
   ELSIF name = "S7" THEN reg := 7; RETURN TRUE
   ELSIF name = "S8" THEN reg := 8; RETURN TRUE
   ELSIF name = "S9" THEN reg := 9; RETURN TRUE
   ELSIF name = "S10" THEN reg := 10; RETURN TRUE
   ELSIF name = "S11" THEN reg := 11; RETURN TRUE
   ELSIF name = "S12" THEN reg := 12; RETURN TRUE
   ELSIF name = "S13" THEN reg := 13; RETURN TRUE
   ELSIF name = "S14" THEN reg := 14; RETURN TRUE
   ELSIF name = "S15" THEN reg := 15; RETURN TRUE
   ELSIF name = "S16" THEN reg := 16; RETURN TRUE
   ELSIF name = "S17" THEN reg := 17; RETURN TRUE
   ELSIF name = "S18" THEN reg := 18; RETURN TRUE
   ELSIF name = "S19" THEN reg := 19; RETURN TRUE
   ELSIF name = "S20" THEN reg := 20; RETURN TRUE
   ELSIF name = "S21" THEN reg := 21; RETURN TRUE
   ELSIF name = "S22" THEN reg := 22; RETURN TRUE
   ELSIF name = "S23" THEN reg := 23; RETURN TRUE
   ELSIF name = "S24" THEN reg := 24; RETURN TRUE
   ELSIF name = "S25" THEN reg := 25; RETURN TRUE
   ELSIF name = "S26" THEN reg := 26; RETURN TRUE
   ELSIF name = "S27" THEN reg := 27; RETURN TRUE
   ELSIF name = "S28" THEN reg := 28; RETURN TRUE
   ELSIF name = "S29" THEN reg := 29; RETURN TRUE
   ELSIF name = "S30" THEN reg := 30; RETURN TRUE
   ELSIF name = "S31" THEN reg := 31; RETURN TRUE
   ELSE mode := RegMode; RETURN FALSE (* SP already handled above *)
   END
  (* VFP double-precision registers D0-D31 *)
  ELSIF name[0] = "D" THEN
   mode := DRegMode;
   IF name = "D0" THEN reg := 0; RETURN TRUE
   ELSIF name = "D1" THEN reg := 1; RETURN TRUE
   ELSIF name = "D2" THEN reg := 2; RETURN TRUE
   ELSIF name = "D3" THEN reg := 3; RETURN TRUE
   ELSIF name = "D4" THEN reg := 4; RETURN TRUE
   ELSIF name = "D5" THEN reg := 5; RETURN TRUE
   ELSIF name = "D6" THEN reg := 6; RETURN TRUE
   ELSIF name = "D7" THEN reg := 7; RETURN TRUE
   ELSIF name = "D8" THEN reg := 8; RETURN TRUE
   ELSIF name = "D9" THEN reg := 9; RETURN TRUE
   ELSIF name = "D10" THEN reg := 10; RETURN TRUE
   ELSIF name = "D11" THEN reg := 11; RETURN TRUE
   ELSIF name = "D12" THEN reg := 12; RETURN TRUE
   ELSIF name = "D13" THEN reg := 13; RETURN TRUE
   ELSIF name = "D14" THEN reg := 14; RETURN TRUE
   ELSIF name = "D15" THEN reg := 15; RETURN TRUE
   ELSIF name = "D16" THEN reg := 16; RETURN TRUE
   ELSIF name = "D17" THEN reg := 17; RETURN TRUE
   ELSIF name = "D18" THEN reg := 18; RETURN TRUE
   ELSIF name = "D19" THEN reg := 19; RETURN TRUE
   ELSIF name = "D20" THEN reg := 20; RETURN TRUE
   ELSIF name = "D21" THEN reg := 21; RETURN TRUE
   ELSIF name = "D22" THEN reg := 22; RETURN TRUE
   ELSIF name = "D23" THEN reg := 23; RETURN TRUE
   ELSIF name = "D24" THEN reg := 24; RETURN TRUE
   ELSIF name = "D25" THEN reg := 25; RETURN TRUE
   ELSIF name = "D26" THEN reg := 26; RETURN TRUE
   ELSIF name = "D27" THEN reg := 27; RETURN TRUE
   ELSIF name = "D28" THEN reg := 28; RETURN TRUE
   ELSIF name = "D29" THEN reg := 29; RETURN TRUE
   ELSIF name = "D30" THEN reg := 30; RETURN TRUE
   ELSIF name = "D31" THEN reg := 31; RETURN TRUE
   ELSE mode := RegMode; RETURN FALSE
   END
  ELSE RETURN FALSE
  END
 END ParseRegister;

 PROCEDURE ParseRegList(VAR regList: SET);
 (* Parse a register list: {R0, R1, R3-R7, ...} *)
  VAR reg, reg2: INTEGER; mode: LONGINT; name: Name;
 BEGIN
  regList := {};
  REPEAT
   IF sym = ScIdent THEN
    COPY(ident, name);
    IF ParseRegister(name, reg, mode) & (mode = RegMode) THEN
     Get(sym);
     IF sym = ScMinus THEN
      (* Range: R3-R7 *)
      Get(sym);
      IF sym = ScIdent THEN
       COPY(ident, name);
       IF ParseRegister(name, reg2, mode) & (mode = RegMode) THEN
        Get(sym);
        WHILE reg <= reg2 DO INCL(regList, reg); INC(reg) END
       ELSE OPM.err(506)
       END
      ELSE OPM.err(506)
      END
     ELSE
      INCL(regList, reg)
     END
    ELSE OPM.err(506)
    END
   ELSE OPM.err(506)
   END;
   IF sym = ScComma THEN Get(sym) END
  UNTIL sym = ScRBrace;
  Get(sym)
 END ParseRegList;

 PROCEDURE GetOperand(VAR o: Operand);
 (* Parse one ARM32 operand *)
  VAR obj: Object; name: Name; reg: INTEGER; mode: LONGINT;
 BEGIN
  o.mode := none; o.reg := none; o.imm := 0; o.disp := 0;
  o.base := none; o.index := none; o.shift := none; o.shiftAmt := 0;
  o.regList := {}; o.obj := NIL; o.writeback := FALSE;
  o.preIndex := FALSE; o.dbl := FALSE;
  IF sym = ScHash THEN
   (* Immediate: #expr *)
   Get(sym);
   Expression(o.imm);
   o.mode := ImmMode
  ELSIF sym = ScLBrak THEN
   (* Memory: [Rn, #offset] or [Rn, Rm] or [Rn, Rm, LSL #n] *)
   Get(sym);
   o.mode := MemMode;
   o.preIndex := TRUE;
   IF sym = ScIdent THEN
    COPY(ident, name);
    IF ParseRegister(name, reg, mode) & (mode = RegMode) THEN
     o.base := reg; Get(sym);
     IF sym = ScComma THEN
      Get(sym);
      IF sym = ScHash THEN
       (* [Rn, #offset] *)
       Get(sym);
       Expression(o.disp)
      ELSIF sym = ScIdent THEN
       (* [Rn, Rm] or [Rn, Rm, shift #n] *)
       COPY(ident, name);
       IF ParseRegister(name, reg, mode) & (mode = RegMode) THEN
        o.index := reg; Get(sym);
        IF sym = ScComma THEN
         Get(sym);
         IF sym = ScIdent THEN
          IF ident = "LSL" THEN o.shift := ShLSL
          ELSIF ident = "LSR" THEN o.shift := ShLSR
          ELSIF ident = "ASR" THEN o.shift := ShASR
          ELSIF ident = "ROR" THEN o.shift := ShROR
          ELSE OPM.err(506)
          END;
          Get(sym);
          IF sym = ScHash THEN Get(sym); Expression(o.imm); o.shiftAmt := SHORT(o.imm)
          ELSE OPM.err(506)
          END
         END
        END
       ELSE OPM.err(506)
       END
      ELSIF sym = ScMinus THEN
       (* [Rn, -Rm] or [Rn, #-offset] *)
       Get(sym);
       IF sym = ScHash THEN
        Get(sym); Expression(o.disp); o.disp := -o.disp
       ELSIF sym = ScIdent THEN
        COPY(ident, name);
        IF ParseRegister(name, reg, mode) & (mode = RegMode) THEN
         o.index := reg; o.shift := -1; (* negative offset flag *)
         Get(sym)
        ELSE OPM.err(506)
        END
       ELSE OPM.err(506)
       END
      END
     END;
     (* Expect ] *)
     IF sym = ScRBrak THEN Get(sym) ELSE OPM.err(507) END;
     (* Check for writeback *)
     IF sym = ScExcl THEN o.writeback := TRUE; Get(sym) END
    ELSE OPM.err(506)
    END
   ELSE OPM.err(506)
   END
  ELSIF sym = ScLBrace THEN
   (* Register list: {R0, R1, ...} *)
   Get(sym);
   ParseRegList(o.regList);
   o.mode := RegListMode
  ELSIF sym = ScIdent THEN
   COPY(ident, name);
   IF ParseRegister(name, reg, mode) THEN
    o.mode := mode; o.reg := reg;
    Get(sym)
   ELSE
    (* Could be a label or other identifier *)
    find(name, obj);
    IF (obj # NIL) & (obj.typ = StLabel) THEN
     o.mode := LabelMode; o.imm := obj.val;
     Get(sym)
    ELSIF (obj # NIL) & (obj.typ = StFwdLabel) THEN
     o.mode := FwdLabelMode; o.obj := obj;
     Get(sym)
    ELSIF (obj # NIL) & (obj.typ = StConst) THEN
     o.mode := ImmMode; o.imm := obj.val;
     Get(sym)
    ELSE
     o.mode := ImmMode; o.imm := 0;
     OPM.err(500)
    END
   END
  ELSIF sym = ScNumber THEN
   o.mode := ImmMode;
   Expression(o.imm)
  ELSIF sym = ScMinus THEN
   o.mode := ImmMode;
   Expression(o.imm)
  ELSE
   o.mode := none
  END
 END GetOperand;

(* ------------------------------------------------------------------- *)
(* Fixpoint handling *)

 PROCEDURE CheckLabels;
  VAR obj, obj1, obj2: Object;
 BEGIN
  obj1 := root.next; obj := NIL;
  WHILE obj1 # NIL DO
   obj2 := obj1.next; obj1.next := obj; obj := obj1; obj1 := obj2
  END;
  WHILE obj # NIL DO
   IF obj.typ = StFwdLabel THEN
    OPM.Mark(128, obj.val)
   END;
   obj := obj.next
  END
 END CheckLabels;

 PROCEDURE InsertFix(VAR obj: Object; pc: LONGINT);
  VAR fix: FixPnt; x: OPT.Node;
 BEGIN
  CASE obj.typ OF
   StFwdLabel:
    NEW(fix); fix.pc := pc;
    fix.node := last;
    fix.pos := ORD(last.conval.ext[0]) - 3;
    fix.next := obj.fix; obj.fix := fix
   | StVar, StVarPar, StGlobal:
    IF export & inline THEN OPM.err(517) END;
    x := OPT.NewNode(Nfixup);
    x.obj := obj.obj; x.conval := OPT.NewConst();
    x.conval.intval := pc; x.conval.intval2 := OPM.errpos;
    x.link := fixlist; fixlist := x
  ELSE
   OPM.err(607)
  END
 END InsertFix;

 PROCEDURE FixDisp(VAR fix: FixPnt);
  VAR pos: LONGINT; disp, i: LONGINT;
 BEGIN
  disp := pc - fix.pc;
  FOR i := 0 TO 3 DO
   fix.node.conval.ext[fix.pos + i] := CHR(disp MOD 256);
   disp := disp DIV 256
  END
 END FixDisp;

(* ------------------------------------------------------------------- *)
(* Code Generation *)

 PROCEDURE NewNode;
  VAR x: OPT.Node;
 BEGIN
  x := OPT.NewNode(Ncode); x.conval := OPT.NewConst();
  x.conval.ext := OPT.NewExt(); x.conval.ext[0] := 0X;
  x.conval.intval := OPM.errpos;
  OPB.Link(first, last, x)
 END NewNode;

 PROCEDURE PutByte(b: LONGINT);
  VAR pos: LONGINT;
 BEGIN
  pos := ORD(last.conval.ext[0]) + 1;
  IF pos > 255 THEN NewNode; pos := 1 END;
  last.conval.ext[pos] := CHR(b);
  last.conval.ext[0] := CHR(pos);
  INC(pc)
 END PutByte;

 PROCEDURE PutWord(w: LONGINT);
 (* Emit a 32-bit A32 instruction word (little-endian) *)
 BEGIN
  PutByte(AND(w, 0FFH));
  PutByte(AND(w DIV 100H, 0FFH));
  PutByte(AND(w DIV 10000H, 0FFH));
  PutByte(AND(w DIV 1000000H, 0FFH))
 END PutWord;

 PROCEDURE CanEncodeImm(imm: LONGINT; VAR encoding: LONGINT): BOOLEAN;
 (* Try to encode a 32-bit immediate as an 8-bit value with 4-bit rotation *)
 (* ARM A32 modified immediate: imm12 = rot4:imm8, value = imm8 ROR (rot4*2) *)
  VAR rot, val: LONGINT;
 BEGIN
  IF (imm >= 0) & (imm < 256) THEN
   encoding := imm; RETURN TRUE
  END;
  rot := 0;
  WHILE rot < 16 DO
   (* Rotate imm left by rot*2 bits, check if fits in 8 bits *)
   val := ORL(AND(imm, 0FFFFFFFFH), 0);
   (* Rotate right by (32 - rot*2) MOD 32 = rotate left by rot*2 *)
   IF rot > 0 THEN
    val := ORL(
     AND(SYSTEM.VAL(LONGINT, SYSTEM.LSH(SYSTEM.VAL(SET, imm), rot * 2)),
      0FFFFFFFFH),
     AND(SYSTEM.VAL(LONGINT, SYSTEM.LSH(SYSTEM.VAL(SET, imm), -(32 - rot * 2))),
      0FFFFFFFFH))
   END;
   IF (val >= 0) & (val < 256) THEN
    encoding := rot * 256 + val;
    RETURN TRUE
   END;
   INC(rot)
  END;
  RETURN FALSE
 END CanEncodeImm;

 PROCEDURE GenDataProc(cond: SHORTINT; op: LONGINT; S: BOOLEAN;
   Rd, Rn: INTEGER; VAR op2: Operand);
 (* Generate a data processing instruction *)
  VAR w, encoding: LONGINT; sbit: LONGINT;
 BEGIN
  IF S THEN sbit := 100000H ELSE sbit := 0 END;
  IF op2.mode = ImmMode THEN
   (* Immediate form *)
   IF CanEncodeImm(op2.imm, encoding) THEN
    w := cond * 10000000H + 2000000H + op * 200000H + sbit +
      Rn * 10000H + Rd * 1000H + encoding;
    PutWord(w)
   ELSE
    OPM.err(501) (* cannot encode immediate *)
   END
  ELSIF op2.mode = RegMode THEN
   (* Register form with optional shift *)
   w := cond * 10000000H + op * 200000H + sbit +
     Rn * 10000H + Rd * 1000H;
   IF op2.shift >= 0 THEN
    w := w + op2.shiftAmt * 80H + op2.shift * 20H + op2.reg
   ELSE
    w := w + op2.reg
   END;
   PutWord(w)
  ELSE
   OPM.err(501)
  END
 END GenDataProc;

 PROCEDURE GenShiftInstr(cond: SHORTINT; shiftType: LONGINT;
   Rd, Rm: INTEGER; VAR op2: Operand);
 (* Generate shift instruction: LSL, LSR, ASR, ROR Rd, Rm, #imm or Rs *)
  VAR w: LONGINT;
 BEGIN
  IF op2.mode = ImmMode THEN
   (* Shift by immediate: MOV Rd, Rm, <shift> #imm *)
   w := cond * 10000000H + dpMOV * 200000H +
     Rd * 1000H + op2.imm * 80H + shiftType * 20H + Rm;
   PutWord(w)
  ELSIF op2.mode = RegMode THEN
   (* Shift by register: MOV Rd, Rm, <shift> Rs *)
   w := cond * 10000000H + dpMOV * 200000H +
     Rd * 1000H + op2.reg * 100H + shiftType * 20H + 10H + Rm;
   PutWord(w)
  ELSE
   OPM.err(501)
  END
 END GenShiftInstr;

 PROCEDURE GenMultiply(cond: SHORTINT; op: LONGINT;
   Rd, Rm, Rs, Rn: INTEGER);
 (* Generate multiply instruction *)
  VAR w: LONGINT;
 BEGIN
  CASE op OF
   0: (* MUL Rd, Rm, Rs *)
    w := cond * 10000000H + Rd * 10000H + Rs * 100H + 90H + Rm
   | 1: (* MLA Rd, Rm, Rs, Rn *)
    w := cond * 10000000H + 200000H + Rd * 10000H + Rn * 1000H + Rs * 100H + 90H + Rm
   | 2: (* UMULL RdLo, RdHi, Rm, Rs *)
    w := cond * 10000000H + 800000H + Rd * 10000H + Rn * 1000H + Rs * 100H + 90H + Rm
   | 3: (* UMLAL RdLo, RdHi, Rm, Rs *)
    w := cond * 10000000H + 0A00000H + Rd * 10000H + Rn * 1000H + Rs * 100H + 90H + Rm
   | 4: (* SMULL RdLo, RdHi, Rm, Rs *)
    w := cond * 10000000H + 0C00000H + Rd * 10000H + Rn * 1000H + Rs * 100H + 90H + Rm
   | 5: (* SMLAL RdLo, RdHi, Rm, Rs *)
    w := cond * 10000000H + 0E00000H + Rd * 10000H + Rn * 1000H + Rs * 100H + 90H + Rm
  END;
  PutWord(w)
 END GenMultiply;

 PROCEDURE GenDivide(cond: SHORTINT; op: LONGINT; Rd, Rn, Rm: INTEGER);
 (* Generate SDIV/UDIV instruction *)
  VAR w: LONGINT;
 BEGIN
  IF op = 0 THEN (* SDIV *)
   w := cond * 10000000H + 710000H + Rd * 10000H + 0F00H + Rm * 10H + 1 + Rn
  ELSE (* UDIV *)
   w := cond * 10000000H + 730000H + Rd * 10000H + 0F00H + Rm * 10H + 1 + Rn
  END;
  PutWord(w)
 END GenDivide;

 PROCEDURE GenLdSt(cond: SHORTINT; op: LONGINT; Rt: INTEGER; VAR mem: Operand);
 (* Generate LDR/LDRB/STR/STRB *)
  VAR w, U, P, W, L, B: LONGINT;
 BEGIN
  L := 0; B := 0;
  IF (op = 0) OR (op = 1) THEN L := 100000H END; (* Load bit *)
  IF (op = 1) OR (op = 3) THEN B := 400000H END; (* Byte bit *)
  P := 1000000H; (* Pre-indexed by default *)
  U := 800000H;  (* Up (positive offset) by default *)
  W := 0;
  IF mem.writeback THEN W := 200000H END;
  IF mem.disp < 0 THEN U := 0; mem.disp := -mem.disp END;
  IF mem.index >= 0 THEN
   (* Register offset *)
   w := cond * 10000000H + 6000000H + P + U + B + W + L +
     mem.base * 10000H + Rt * 1000H + mem.index;
   IF mem.shift >= 0 THEN
    w := w + mem.shiftAmt * 80H + mem.shift * 20H
   END
  ELSE
   (* Immediate offset *)
   IF mem.disp > 0FFFH THEN OPM.err(501) END;
   w := cond * 10000000H + 4000000H + P + U + B + W + L +
     mem.base * 10000H + Rt * 1000H + AND(mem.disp, 0FFFH)
  END;
  PutWord(w)
 END GenLdSt;

 PROCEDURE GenLdStH(cond: SHORTINT; op: LONGINT; Rt: INTEGER; VAR mem: Operand);
 (* Generate LDRH/LDRSH/LDRSB/STRH *)
  VAR w, U, P, W, L, S, H: LONGINT;
 BEGIN
  P := 1000000H; U := 800000H; W := 0;
  IF mem.writeback THEN W := 200000H END;
  IF mem.disp < 0 THEN U := 0; mem.disp := -mem.disp END;
  CASE op OF
   0: L := 100000H; S := 0; H := 20H      (* LDRH *)
   | 1: L := 100000H; S := 40H; H := 20H  (* LDRSH *)
   | 2: L := 100000H; S := 40H; H := 0    (* LDRSB *)
   | 3: L := 0; S := 0; H := 20H          (* STRH *)
  END;
  IF mem.index >= 0 THEN
   (* Register offset *)
   w := cond * 10000000H + P + U + W + L +
     mem.base * 10000H + Rt * 1000H + S + H + 90H + mem.index
  ELSE
   (* Immediate offset *)
   IF mem.disp > 0FFH THEN OPM.err(501) END;
   w := cond * 10000000H + P + U + 400000H + W + L +
     mem.base * 10000H + Rt * 1000H +
     (mem.disp DIV 16) * 100H + S + H + 90H + (mem.disp MOD 16)
  END;
  PutWord(w)
 END GenLdStH;

 PROCEDURE GenBranch(cond: SHORTINT; link: BOOLEAN; VAR target: Operand);
 (* Generate B/BL instruction *)
  VAR w, offset: LONGINT;
 BEGIN
  IF link THEN w := cond * 10000000H + 0B000000H
  ELSE w := cond * 10000000H + 0A000000H
  END;
  IF target.mode = LabelMode THEN
   offset := (target.imm - (pc + 8)) DIV 4;
   w := w + AND(offset, 0FFFFFFH);
   PutWord(w)
  ELSIF target.mode = FwdLabelMode THEN
   PutWord(w); (* will be fixed up later *)
   IF target.obj # NIL THEN InsertFix(target.obj, pc - 4) END
  ELSIF target.mode = ImmMode THEN
   offset := (target.imm - (pc + 8)) DIV 4;
   w := w + AND(offset, 0FFFFFFH);
   PutWord(w)
  ELSE
   OPM.err(501)
  END
 END GenBranch;

 PROCEDURE GenBX(cond: SHORTINT; link: BOOLEAN; Rm: INTEGER);
 (* Generate BX/BLX instruction *)
  VAR w: LONGINT;
 BEGIN
  IF link THEN
   w := cond * 10000000H + 12FFF30H + Rm (* BLX Rm *)
  ELSE
   w := cond * 10000000H + 12FFF10H + Rm (* BX Rm *)
  END;
  PutWord(w)
 END GenBX;

 PROCEDURE GenPushPop(cond: SHORTINT; pop: BOOLEAN; regList: SET);
 (* Generate PUSH/POP (aliases for STMDB/LDMIA) *)
  VAR w: LONGINT;
 BEGIN
  IF pop THEN
   (* POP = LDMIA SP!, {regList} *)
   w := cond * 10000000H + 8BD0000H + SYSTEM.VAL(LONGINT, regList)
  ELSE
   (* PUSH = STMDB SP!, {regList} *)
   w := cond * 10000000H + 92D0000H + SYSTEM.VAL(LONGINT, regList)
  END;
  PutWord(w)
 END GenPushPop;

 PROCEDURE GenMOVWT(cond: SHORTINT; top: BOOLEAN; Rd: INTEGER; imm16: LONGINT);
 (* Generate MOVW/MOVT *)
  VAR w: LONGINT;
 BEGIN
  IF top THEN
   (* MOVT: 0xe34X0000 | Rd<<12 | imm4<<16 | imm12 *)
   w := cond * 10000000H + 3400000H
  ELSE
   (* MOVW: 0xe30X0000 | Rd<<12 | imm4<<16 | imm12 *)
   w := cond * 10000000H + 3000000H
  END;
  w := w + (imm16 DIV 1000H) * 10000H + Rd * 1000H + (imm16 MOD 1000H);
  PutWord(w)
 END GenMOVWT;

 PROCEDURE GenCLZetc(cond: SHORTINT; op: LONGINT; Rd, Rm: INTEGER);
 (* Generate CLZ, RBIT, REV *)
  VAR w: LONGINT;
 BEGIN
  CASE op OF
   0: (* CLZ *)
    w := cond * 10000000H + 16F0F10H + Rd * 1000H + Rm
   | 1: (* RBIT *)
    w := cond * 10000000H + 6FF0F30H + Rd * 1000H + Rm
   | 2: (* REV *)
    w := cond * 10000000H + 6BF0F30H + Rd * 1000H + Rm
  END;
  PutWord(w)
 END GenCLZetc;

 PROCEDURE GenNOPBarrier(op: LONGINT; imm: LONGINT);
 (* Generate NOP, DMB, DSB, ISB, BKPT, SVC *)
 BEGIN
  CASE op OF
   0: (* NOP *)
    PutWord(0E320F000H)
   | 1: (* DMB *)
    PutWord(0F57FF05AH) (* DMB ISH: 0xF57FF050 | 0x0A (ISH option) *)
   | 2: (* DSB *)
    PutWord(0F57FF04AH) (* DSB ISH *)
   | 3: (* ISB *)
    PutWord(0F57FF06FH) (* ISB SY *)
   | 4: (* BKPT #imm *)
    PutWord(0E1200070H + (imm DIV 16) * 100H + (imm MOD 16))
   | 5: (* SVC #imm *)
    PutWord(0EF000000H + AND(imm, 0FFFFFFH))
  END
 END GenNOPBarrier;

 PROCEDURE GenCPS(op: LONGINT);
 (* Generate CPSIE/CPSID *)
 BEGIN
  IF op = 0 THEN
   PutWord(0F1080080H) (* CPSIE i *)
  ELSE
   PutWord(0F10C0080H) (* CPSID i *)
  END
 END GenCPS;

 PROCEDURE GenVFP3op(cond: SHORTINT; op: LONGINT; dbl: BOOLEAN; Vd, Vn, Vm: INTEGER);
 (* Generate VFP 3-operand: VADD, VSUB, VMUL, VDIV *)
  VAR w, sz, opc: LONGINT;
 BEGIN
  IF dbl THEN sz := 100H ELSE sz := 0 END;
  CASE op OF
   0: opc := 0E300A00H (* VADD *)
   | 1: opc := 0E300A40H (* VSUB *)
   | 2: opc := 0E200A00H (* VMUL *)
   | 3: opc := 0E800A00H (* VDIV *)
  END;
  w := cond * 10000000H + opc + sz;
  IF dbl THEN
   w := w + (Vd DIV 16) * 400000H + (Vd MOD 16) * 1000H +
     (Vn DIV 16) * 80H + (Vn MOD 16) * 10000H +
     (Vm DIV 16) * 20H + (Vm MOD 16)
  ELSE
   w := w + (Vd MOD 2) * 400000H + (Vd DIV 2) * 1000H +
     (Vn MOD 2) * 80H + (Vn DIV 2) * 10000H +
     (Vm MOD 2) * 20H + (Vm DIV 2)
  END;
  PutWord(w)
 END GenVFP3op;

 PROCEDURE GenVFP2op(cond: SHORTINT; op: LONGINT; dbl: BOOLEAN; Vd, Vm: INTEGER);
 (* Generate VFP 2-operand: VABS, VNEG, VCMP, VSQRT *)
  VAR w, sz, opc: LONGINT;
 BEGIN
  IF dbl THEN sz := 100H ELSE sz := 0 END;
  CASE op OF
   0: opc := 0EB00AC0H (* VABS *)
   | 1: opc := 0EB10A40H (* VNEG *)
   | 2: opc := 0EB40A40H (* VCMP *)
   | 3: opc := 0EB10AC0H (* VSQRT *)
  END;
  w := cond * 10000000H + opc + sz;
  IF dbl THEN
   w := w + (Vd DIV 16) * 400000H + (Vd MOD 16) * 1000H +
     (Vm DIV 16) * 20H + (Vm MOD 16)
  ELSE
   w := w + (Vd MOD 2) * 400000H + (Vd DIV 2) * 1000H +
     (Vm MOD 2) * 20H + (Vm DIV 2)
  END;
  PutWord(w)
 END GenVFP2op;

 PROCEDURE GenVLdSt(cond: SHORTINT; store: BOOLEAN; dbl: BOOLEAN;
   Vd: INTEGER; Rn: INTEGER; offset: LONGINT);
 (* Generate VLDR/VSTR *)
  VAR w, U: LONGINT;
 BEGIN
  U := 800000H; (* positive offset *)
  IF offset < 0 THEN U := 0; offset := -offset END;
  IF offset MOD 4 # 0 THEN OPM.err(501) END;
  offset := offset DIV 4;
  IF offset > 0FFH THEN OPM.err(501) END;
  IF store THEN
   w := cond * 10000000H + 0D000A00H
  ELSE
   w := cond * 10000000H + 0D100A00H
  END;
  IF dbl THEN w := w + 100H END;
  w := w + U + Rn * 10000H + AND(offset, 0FFH);
  IF dbl THEN
   w := w + (Vd DIV 16) * 400000H + (Vd MOD 16) * 1000H
  ELSE
   w := w + (Vd MOD 2) * 400000H + (Vd DIV 2) * 1000H
  END;
  PutWord(w)
 END GenVLdSt;

 PROCEDURE GenVMOV(cond: SHORTINT; toVFP: BOOLEAN; Rt: INTEGER; Vn: INTEGER);
 (* Generate VMOV between GPR and single-precision VFP register *)
  VAR w: LONGINT;
 BEGIN
  IF toVFP THEN
   (* VMOV Sn, Rt: 0xEE0n0A10 *)
   w := cond * 10000000H + 0E000A10H +
     (Vn DIV 2) * 10000H + (Vn MOD 2) * 80H + Rt * 1000H
  ELSE
   (* VMOV Rt, Sn: 0xEE1n0A10 *)
   w := cond * 10000000H + 0E100A10H +
     (Vn DIV 2) * 10000H + (Vn MOD 2) * 80H + Rt * 1000H
  END;
  PutWord(w)
 END GenVMOV;

 PROCEDURE GenVMRS(cond: SHORTINT; toAPSR: BOOLEAN);
 (* Generate VMRS APSR_nzcv, FPSCR or VMSR FPSCR, Rt *)
 BEGIN
  IF toAPSR THEN
   PutWord(cond * 10000000H + 0EF1FA10H) (* VMRS APSR_nzcv, FPSCR *)
  ELSE
   PutWord(cond * 10000000H + 0EE10A10H) (* VMSR FPSCR, R0 (simplified) *)
  END
 END GenVMRS;

 PROCEDURE GenCopro(cond: SHORTINT; mrc: BOOLEAN; coproc, opc1, Rt, CRn, CRm, opc2: INTEGER);
 (* Generate MCR/MRC *)
  VAR w: LONGINT;
 BEGIN
  IF mrc THEN w := cond * 10000000H + 0E100010H
  ELSE w := cond * 10000000H + 0E000010H
  END;
  w := w + opc1 * 200000H + CRn * 10000H + Rt * 1000H +
    coproc * 100H + opc2 * 20H + CRm;
  PutWord(w)
 END GenCopro;

(* ------------------------------------------------------------------- *)
(* Instruction Parser and Encoder *)

 PROCEDURE ParseInstruction;
  VAR
   ind, nameLen: LONGINT;
   baseName: Mnemo;
   op: ARRAY 5 OF Operand;
   i: LONGINT;
   cond: SHORTINT;
   setFlags: BOOLEAN;
   cat: SHORTINT;
   opcode: LONGINT;
 BEGIN
  errpos := OPM.errpos;

  (* Handle data directives first *)
  IF (ident = "DCD") OR (ident = "DCW") OR (ident = "DCB") THEN
   ind := 0;
   IF ident = "DCD" THEN ind := 4
   ELSIF ident = "DCW" THEN ind := 2
   ELSE ind := 1
   END;
   Get(sym);
   WHILE (sym = ScNumber) OR (sym = ScString) OR (sym = ScHash) DO
    IF sym = ScHash THEN Get(sym) END;
    IF (sym = ScString) & (val = 1) THEN
     i := 0;
     WHILE i < ind DO PutByte(ORD(str[0])); INC(i) END
    ELSIF sym = ScNumber THEN
     i := 0;
     WHILE i < ind DO PutByte(AND(val, 0FFH)); val := val DIV 256; INC(i) END
    ELSE
     Expression(val);
     i := 0;
     WHILE i < ind DO PutByte(AND(val, 0FFH)); val := val DIV 256; INC(i) END
    END;
    Get(sym);
    IF sym = ScComma THEN Get(sym)
    ELSE RETURN
    END
   END;
   RETURN
  END;

  (* First try the full mnemonic as-is.  This avoids misinterpreting
     instruction names whose tail looks like a condition code (e.g. SVC
     where "VC" would be parsed as CondVC). *)
  COPY(ident, baseName);
  FindInstruction(baseName, ind);
  IF ind >= 0 THEN
   cond := CondAL; setFlags := FALSE
  ELSE
   (* Not found verbatim - strip condition code suffix and retry *)
   COPY(ident, baseName);
   ParseCondition(baseName, cond, nameLen);
   setFlags := FALSE;

   (* Check for S suffix (set flags) *)
   IF (nameLen > 1) & (baseName[nameLen - 1] = "S") THEN
    baseName[nameLen - 1] := 0X;
    setFlags := TRUE;
    DEC(nameLen)
   ELSE
    baseName[nameLen] := 0X
   END;

   (* Look up base instruction name *)
   FindInstruction(baseName, ind);
   IF ind < 0 THEN
    (* Try without removing S suffix *)
    COPY(ident, baseName);
    ParseCondition(baseName, cond, nameLen);
    baseName[nameLen] := 0X;
    setFlags := FALSE;
    FindInstruction(baseName, ind);
    IF ind < 0 THEN
     OPM.err(502); RETURN
    END
   END
  END;

  cat := InstrTab[ind].cat;
  opcode := InstrTab[ind].op;
  Get(sym);

  (* Parse operands based on instruction category *)
  FOR i := 0 TO 4 DO
   op[i].mode := none; op[i].reg := none; op[i].imm := 0;
   op[i].disp := 0; op[i].base := none; op[i].index := none;
   op[i].shift := none; op[i].shiftAmt := 0;
   op[i].regList := {}; op[i].obj := NIL;
   op[i].writeback := FALSE; op[i].preIndex := FALSE;
   op[i].dbl := FALSE
  END;

  IF sym # ScCR THEN
   i := 0;
   LOOP
    GetOperand(op[i]); INC(i);
    IF sym # ScComma THEN EXIT END;
    Get(sym);
    IF i >= 5 THEN OPM.err(501); EXIT END
   END
  END;

  CASE cat OF
   CatDP:
    (* Data processing: Rd, Rn, Op2 or Rd, Op2 (MOV/MVN) or Rn, Op2 (CMP/CMN/TST/TEQ) *)
    IF (opcode = dpMOV) OR (opcode = dpMVN) THEN
     (* MOV Rd, Op2 *)
     IF op[0].mode = RegMode THEN
      GenDataProc(cond, opcode, setFlags, op[0].reg, 0, op[1])
     ELSE OPM.err(501)
     END
    ELSIF (opcode = dpCMP) OR (opcode = dpCMN) OR (opcode = dpTST) OR (opcode = dpTEQ) THEN
     (* CMP Rn, Op2 *)
     IF op[0].mode = RegMode THEN
      GenDataProc(cond, opcode, TRUE, 0, op[0].reg, op[1])
     ELSE OPM.err(501)
     END
    ELSE
     (* ADD Rd, Rn, Op2 *)
     IF (op[0].mode = RegMode) & (op[1].mode = RegMode) THEN
      GenDataProc(cond, opcode, setFlags, op[0].reg, op[1].reg, op[2])
     ELSE OPM.err(501)
     END
    END

   | CatShift:
    (* Shift: Rd, Rm, #imm or Rd, Rm, Rs *)
    IF (op[0].mode = RegMode) & (op[1].mode = RegMode) THEN
     GenShiftInstr(cond, opcode, op[0].reg, op[1].reg, op[2])
    ELSE OPM.err(501)
    END

   | CatMul:
    IF opcode <= 1 THEN
     (* MUL Rd, Rm, Rs / MLA Rd, Rm, Rs, Rn *)
     IF op[0].mode = RegMode THEN
      IF opcode = 0 THEN
       GenMultiply(cond, opcode, op[0].reg, op[1].reg, op[2].reg, 0)
      ELSE
       GenMultiply(cond, opcode, op[0].reg, op[1].reg, op[2].reg, op[3].reg)
      END
     ELSE OPM.err(501)
     END
    ELSE
     (* Long multiply: UMULL/UMLAL/SMULL/SMLAL RdLo, RdHi, Rm, Rs *)
     IF op[0].mode = RegMode THEN
      GenMultiply(cond, opcode, op[1].reg, op[0].reg, op[3].reg, op[2].reg)
     ELSE OPM.err(501)
     END
    END

   | CatDiv:
    (* SDIV/UDIV Rd, Rn, Rm *)
    IF (op[0].mode = RegMode) & (op[1].mode = RegMode) & (op[2].mode = RegMode) THEN
     GenDivide(cond, opcode, op[0].reg, op[1].reg, op[2].reg)
    ELSE OPM.err(501)
    END

   | CatLdSt:
    (* LDR/LDRB/STR/STRB Rt, [Rn, #offset] *)
    IF (op[0].mode = RegMode) & (op[1].mode = MemMode) THEN
     GenLdSt(cond, opcode, op[0].reg, op[1])
    ELSE OPM.err(501)
    END

   | CatLdStH:
    (* LDRH/LDRSH/LDRSB/STRH Rt, [Rn, #offset] *)
    IF (op[0].mode = RegMode) & (op[1].mode = MemMode) THEN
     GenLdStH(cond, opcode, op[0].reg, op[1])
    ELSE OPM.err(501)
    END

   | CatBranch:
    (* B/BL target *)
    GenBranch(cond, opcode = 1, op[0])

   | CatBX:
    (* BX/BLX Rm *)
    IF op[0].mode = RegMode THEN
     GenBX(cond, opcode = 1, op[0].reg)
    ELSE OPM.err(501)
    END

   | CatPushPop:
    (* PUSH/POP {reglist} *)
    IF op[0].mode = RegListMode THEN
     GenPushPop(cond, opcode = 1, op[0].regList)
    ELSE OPM.err(501)
    END

   | CatMOVW:
    (* MOVW/MOVT Rd, #imm16 *)
    IF (op[0].mode = RegMode) & (op[1].mode = ImmMode) THEN
     GenMOVWT(cond, opcode = 1, op[0].reg, AND(op[1].imm, 0FFFFH))
    ELSE OPM.err(501)
    END

   | CatCLZ:
    (* CLZ/RBIT/REV Rd, Rm *)
    IF (op[0].mode = RegMode) & (op[1].mode = RegMode) THEN
     GenCLZetc(cond, opcode, op[0].reg, op[1].reg)
    ELSE OPM.err(501)
    END

   | CatNOP:
    IF opcode <= 3 THEN
     GenNOPBarrier(opcode, 0)
    ELSIF opcode = 4 THEN (* BKPT *)
     IF op[0].mode = ImmMode THEN GenNOPBarrier(opcode, op[0].imm)
     ELSE GenNOPBarrier(opcode, 0)
     END
    ELSE (* SVC *)
     IF op[0].mode = ImmMode THEN GenNOPBarrier(opcode, op[0].imm)
     ELSE GenNOPBarrier(opcode, 0)
     END
    END

   | CatCPS:
    GenCPS(opcode)

   | CatCopro:
    (* MCR/MRC p#, opc1, Rt, CRn, CRm{, opc2} *)
    IF (op[2].mode = RegMode) THEN
     GenCopro(cond, opcode = 1, SHORT(op[0].imm), SHORT(op[1].imm),
       op[2].reg, SHORT(op[3].imm), SHORT(op[4].imm), 0)
    ELSE OPM.err(501)
    END

   | CatMSR:
    IF opcode = 0 THEN (* MSR *)
     IF op[1].mode = RegMode THEN
      PutWord(cond * 10000000H + 0120F000H + op[1].reg)
     ELSE OPM.err(501)
     END
    ELSE (* MRS *)
     IF op[0].mode = RegMode THEN
      PutWord(cond * 10000000H + 10F0000H + op[0].reg * 1000H)
     ELSE OPM.err(501)
     END
    END

   | CatVFP3:
    (* VADD/VSUB/VMUL/VDIV Vd, Vn, Vm *)
    IF (op[0].mode = DRegMode) THEN
     GenVFP3op(cond, opcode, TRUE, op[0].reg, op[1].reg, op[2].reg)
    ELSIF (op[0].mode = SRegMode) THEN
     GenVFP3op(cond, opcode, FALSE, op[0].reg, op[1].reg, op[2].reg)
    ELSE OPM.err(501)
    END

   | CatVFP2:
    (* VABS/VNEG/VCMP/VSQRT Vd, Vm *)
    IF (op[0].mode = DRegMode) THEN
     GenVFP2op(cond, opcode, TRUE, op[0].reg, op[1].reg)
    ELSIF (op[0].mode = SRegMode) THEN
     GenVFP2op(cond, opcode, FALSE, op[0].reg, op[1].reg)
    ELSE OPM.err(501)
    END

   | CatVLdSt:
    (* VLDR/VSTR Vd, [Rn, #offset] *)
    IF (op[0].mode = DRegMode) & (op[1].mode = MemMode) THEN
     GenVLdSt(cond, opcode = 1, TRUE, op[0].reg, op[1].base, op[1].disp)
    ELSIF (op[0].mode = SRegMode) & (op[1].mode = MemMode) THEN
     GenVLdSt(cond, opcode = 1, FALSE, op[0].reg, op[1].base, op[1].disp)
    ELSE OPM.err(501)
    END

   | CatVMOV:
    (* VMOV: GPR<->VFP or VFP<->VFP *)
    IF (op[0].mode = SRegMode) & (op[1].mode = RegMode) THEN
     GenVMOV(cond, TRUE, op[1].reg, op[0].reg)
    ELSIF (op[0].mode = RegMode) & (op[1].mode = SRegMode) THEN
     GenVMOV(cond, FALSE, op[0].reg, op[1].reg)
    ELSIF (op[0].mode = SRegMode) & (op[1].mode = SRegMode) THEN
     (* VMOV.F32 Sd, Sm: 0xEEB00A40 + encoding *)
     PutWord(cond * 10000000H + 0EB00A40H +
       (op[0].reg MOD 2) * 400000H + (op[0].reg DIV 2) * 1000H +
       (op[1].reg MOD 2) * 20H + (op[1].reg DIV 2))
    ELSIF (op[0].mode = DRegMode) & (op[1].mode = DRegMode) THEN
     (* VMOV.F64 Dd, Dm: 0xEEB00B40 + encoding *)
     PutWord(cond * 10000000H + 0EB00B40H +
       (op[0].reg DIV 16) * 400000H + (op[0].reg MOD 16) * 1000H +
       (op[1].reg DIV 16) * 20H + (op[1].reg MOD 16))
    ELSE OPM.err(501)
    END

   | CatVMRS:
    IF opcode = 0 THEN (* VMRS *)
     GenVMRS(cond, TRUE)
    ELSE (* VMSR *)
     GenVMRS(cond, FALSE)
    END

   | CatVCVT:
    (* VCVT: simplified - emit raw encoding *)
    (* Full VCVT handling would require suffix parsing (.F32.S32 etc) *)
    OPM.err(501) (* complex VFP conversions should use OPO directly *)

  ELSE
   OPM.err(502) (* unknown instruction category *)
  END
 END ParseInstruction;

 PROCEDURE ParseLabel;
  VAR obj: Object; fix: FixPnt;
 BEGIN
  ASSERT(sym = ScLabel);
  insert(ident, obj);
  IF obj.typ = StFwdLabel THEN
   fix := obj.fix;
   WHILE fix # NIL DO FixDisp(fix); fix := fix.next END;
   obj.typ := StLabel; obj.val := pc
  ELSE OPM.err(512)
  END;
  Get(sym)
 END ParseLabel;

(* ------------------------------------------------------------------- *)
(* Initialization *)

 PROCEDURE Init;
 BEGIN
  root.next := NIL; root.left := NIL; root.right := NIL;
  pc := 0; Target := {ARMv7A}
 END Init;

 PROCEDURE Close;
 BEGIN
  root.right := NIL
 END Close;

 PROCEDURE BodyInit;
  VAR i: LONGINT;
 BEGIN
  OPM.LogWLn; OPM.LogWStr("  using OP2-ASM ARM32 add-on");
  NEW(root); root.left := NIL; root.right := NIL; root.next := NIL;

  (* Initialize hash table *)
  FOR i := 0 TO InstrHashSize - 1 DO InstrHash[i] := -1 END;

  (* Build embedded instruction tables *)
  BuildInstrTable;

  (* Initialize size table for Oberon types *)
  SizeTab[0] := 0; SizeTab[1] := 1; SizeTab[2] := 1; SizeTab[3] := 1;
  SizeTab[4] := 1; SizeTab[5] := 2; SizeTab[6] := 4; SizeTab[7] := 4;
  SizeTab[8] := 8; SizeTab[9] := 4; SizeTab[10] := 4; SizeTab[11] := 4;
  SizeTab[12] := 0; SizeTab[13] := 4; SizeTab[14] := 4; SizeTab[15] := 0;
  SizeTab[16] := 8
 END BodyInit;

(* ------------------------------------------------------------------- *)
(* Entry point *)

 PROCEDURE Assemble*(VAR x: OPT.Node; exported, inlined: BOOLEAN);
 BEGIN
  export := exported; inline := inlined;
  IF FirstTime THEN BodyInit; FirstTime := FALSE END;
  Init;
  first := NIL; last := NIL; NewNode;
  fixlist := NIL;
  Get(sym);
  IF sym = ScLBrace THEN
   (* Skip target specification - ARM32 only target *)
   WHILE (sym # ScRBrace) & (sym # ScCR) & (sym # ScEnd) DO Get(sym) END;
   IF sym = ScRBrace THEN Get(sym) END
  ELSE
   Get(sym)
  END;
  WHILE (sym # ScEnd) & (sym # ScUndef) DO
   IF sym = ScLabel THEN ParseLabel END;
   IF sym = ScIdent THEN ParseInstruction END;
   WHILE (sym # ScEnd) & (sym # ScCR) DO
    Get(sym); OPM.err(510)
   END;
   Get(sym)
  END;
  IF OPM.noerr THEN CheckLabels END;
  Close;
  OPB.Construct(Nassembler, first, fixlist); x := first; x.conval := NIL
 END Assemble;

BEGIN
 FirstTime := TRUE
END OPA.
