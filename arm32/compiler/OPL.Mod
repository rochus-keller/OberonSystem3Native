(* OPL - ARM32 A32 Code Generator (translation from Pseudo RISC to ARM32)
 
	Architecture: ARMv7-A A32 (32-bit ARM encoding only, no Thumb)
	FPU: VFPv3-D32 scalar (D0-D31 / S0-S63)
	Calling convention: stack-based, callee-cleans
	- All parameters on stack, right-to-left
	- Prologue: PUSH {FP, LR}; MOV FP, SP; SUB SP, SP, #locSize
	- Epilogue: MOV SP, FP; POP {FP, LR}; ADD SP, SP, #parSize; BX LR
	- Return values: R0 (int/ptr), S0 (REAL), D0 (LONGREAL)
	Register allocation:
	- Allocatable GPRs: R0-R3 (scratch), R4-R10 (callee-saved)
	- R11 (FP): frame pointer - dedicated
	- R12 (IP): scratch - used for large immediates/calls
	- R13 (SP): stack pointer - dedicated
	- R14 (LR): link register
	VFP registers: S0-S31 (single), D0-D15 (double, overlapping S0-S31)
	- Allocate from S2/D1 upward (S0/D0 reserved for return values)
 
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

MODULE OPL; (** non-portable *)
 IMPORT OPT, OPIR, OPO, OPM, SYSTEM;

 CONST
  NewRef = TRUE;

  (* Aliases for OPIR opcodes - short form (divided by 32) *)
  Ld = OPIR.ld DIV 32; Ldbdw = OPIR.ldbdw DIV 32; Ldwdw = OPIR.ldwdw DIV 32;
  Ldbw = OPIR.ldbw DIV 32;
  Ldbdwu* = OPIR.ldbdwu DIV 32; Ldwdwu* = OPIR.ldwdwu DIV 32;
  Ldbwu* = OPIR.ldbwu DIV 32; GETreg* = OPIR.getReg DIV 32;
  PUTreg* = OPIR.putReg DIV 32; LdProc = OPIR.ldProc DIV 32;
  LdXProc = OPIR.ldXProc DIV 32; Lea = OPIR.lea DIV 32;
  Sto = OPIR.store DIV 32; Push = OPIR.push DIV 32; Pop = OPIR.pop DIV 32;
  Add = OPIR.add DIV 32; Sub = OPIR.sub DIV 32; Mul = OPIR.mul DIV 32;
  Div = OPIR.div DIV 32; Mod = OPIR.mod DIV 32;
  Neg = OPIR.neg DIV 32; Abso = OPIR.abs DIV 32; Cmp = OPIR.cmp DIV 32;
  Je = OPIR.je DIV 32; Jne = OPIR.jne DIV 32; Jl = OPIR.jl DIV 32;
  Jle = OPIR.jle DIV 32; Jg = OPIR.jg DIV 32; Jge = OPIR.jge DIV 32;
  Ja = OPIR.ja DIV 32; Jae = OPIR.jae DIV 32; Jb = OPIR.jb DIV 32;
  Jbe = OPIR.jbe DIV 32; Jc = OPIR.jc DIV 32; Jnc = OPIR.jnc DIV 32;
  Jmp = OPIR.jmp DIV 32; JmpReg = OPIR.jmpReg DIV 32;
  Sete = OPIR.sete DIV 32; Setne = OPIR.setne DIV 32;
  Setl = OPIR.setl DIV 32; Setle = OPIR.setle DIV 32;
  Setg = OPIR.setg DIV 32; Setge = OPIR.setge DIV 32;
  Seta = OPIR.seta DIV 32; Setae = OPIR.setae DIV 32;
  Setb = OPIR.setb DIV 32; Setbe = OPIR.setbe DIV 32;
  Setc = OPIR.setc DIV 32; Setnc = OPIR.setnc DIV 32;
  Te = OPIR.te DIV 32; Tne = OPIR.tne DIV 32; Tle = OPIR.tle DIV 32;
  Ta = OPIR.ta DIV 32; Tae = OPIR.tae DIV 32; To = OPIR.to DIV 32;
  Trap = OPIR.trap DIV 32;
  oR = OPIR.or DIV 32; Xor = OPIR.xor DIV 32; And = OPIR.and DIV 32;
  Not = OPIR.not DIV 32; Bt = OPIR.bt DIV 32; Btr = OPIR.btr DIV 32;
  Bts = OPIR.bts DIV 32; Test = OPIR.test DIV 32;
  Call = OPIR.call DIV 32; CallReg = OPIR.callReg DIV 32;
  Xcall = OPIR.xcall DIV 32; Ret = OPIR.ret DIV 32;
  Enter = OPIR.enter DIV 32; Leave = OPIR.leave DIV 32;
  Sal = OPIR.sal DIV 32; Sar = OPIR.sar DIV 32;
  Shr = OPIR.shr DIV 32; Rol = OPIR.rol DIV 32;
  Cld = OPIR.cld DIV 32; RepMovs = OPIR.repMovs DIV 32;
  CmpString = OPIR.cmpString DIV 32;
  PushReg = OPIR.pushReg DIV 32; PopReg = OPIR.popReg DIV 32;
  Case = OPIR.case DIV 32;
  Short* = OPIR.short DIV 32; Phi = OPIR.phi DIV 32;
  Label = OPIR.label DIV 32; Entier = OPIR.entier DIV 32;
  Cli = OPIR.cli DIV 32; Sti = OPIR.sti DIV 32;
  In = OPIR.in DIV 32; Out = OPIR.out DIV 32;
  Assembler = OPIR.assembler DIV 32;
  Clear = OPIR.clear DIV 32; Std = OPIR.std DIV 32;
  Dmb = OPIR.dmb DIV 32;
  FLoad = OPIR.fload DIV 32; FStore = OPIR.fstore DIV 32;
  Fist = OPIR.fist DIV 32; Fild = OPIR.fild DIV 32;
  Fadd = OPIR.fadd DIV 32; Fsub = OPIR.fsub DIV 32;
  Fmul = OPIR.fmul DIV 32; Fdiv = OPIR.fdiv DIV 32;
  Fabs = OPIR.fabs DIV 32; Fchs = OPIR.fchs DIV 32;
  Fcmp = OPIR.fcmp DIV 32;
  NewStat = OPIR.newStat DIV 32;

  (* Full opcode aliases for exported use *)
  ld* = OPIR.ld; ldbdw* = OPIR.ldbdw; ldwdw* = OPIR.ldwdw; ldbw* = OPIR.ldbw;
  ldbdwu* = OPIR.ldbdwu; ldwdwu* = OPIR.ldwdwu; ldbwu* = OPIR.ldbwu;
  getReg* = OPIR.getReg; putReg* = OPIR.putReg;
  ldProc* = OPIR.ldProc; ldXProc* = OPIR.ldXProc; lea* = OPIR.lea;
  store* = OPIR.store; push* = OPIR.push; pop* = OPIR.pop;
  add* = OPIR.add; sub* = OPIR.sub; mul* = OPIR.mul;
  div* = OPIR.div; mod* = OPIR.mod;
  neg* = OPIR.neg; abs* = OPIR.abs; cmp* = OPIR.cmp;
  je* = OPIR.je; jne* = OPIR.jne; jl* = OPIR.jl; jle* = OPIR.jle;
  jg* = OPIR.jg; jge* = OPIR.jge; ja* = OPIR.ja; jae* = OPIR.jae;
  jb* = OPIR.jb; jbe* = OPIR.jbe; jc* = OPIR.jc; jnc* = OPIR.jnc;
  jmp* = OPIR.jmp; jmpReg* = OPIR.jmpReg;
  sete* = OPIR.sete; setne* = OPIR.setne; setl* = OPIR.setl;
  setle* = OPIR.setle; setg* = OPIR.setg; setge* = OPIR.setge;
  seta* = OPIR.seta; setae* = OPIR.setae; setb* = OPIR.setb;
  setbe* = OPIR.setbe; setc* = OPIR.setc; setnc* = OPIR.setnc;
  te* = OPIR.te; tne* = OPIR.tne; tle* = OPIR.tle;
  ta* = OPIR.ta; tae* = OPIR.tae; to* = OPIR.to;
  trap* = OPIR.trap; or* = OPIR.or; xor* = OPIR.xor; and* = OPIR.and;
  not* = OPIR.not; bt* = OPIR.bt; btr* = OPIR.btr; bts* = OPIR.bts;
  test* = OPIR.test;
  call* = OPIR.call; callReg* = OPIR.callReg; xcall* = OPIR.xcall;
  ret* = OPIR.ret; enter* = OPIR.enter; leave* = OPIR.leave;
  sal* = OPIR.sal; sar* = OPIR.sar; shr* = OPIR.shr; rol* = OPIR.rol;
  cld* = OPIR.cld; repMovs* = OPIR.repMovs; cmpString* = OPIR.cmpString;
  pushReg* = OPIR.pushReg; popReg* = OPIR.popReg; case* = OPIR.case;
  short* = OPIR.short; phi* = OPIR.phi; label* = OPIR.label;
  entier* = OPIR.entier;
  cli* = OPIR.cli; sti* = OPIR.sti; in* = OPIR.in; out* = OPIR.out;
  assembler* = OPIR.assembler;
  clear* = OPIR.clear; std* = OPIR.std; dmb* = OPIR.dmb;
  fload* = OPIR.fload; fstore* = OPIR.fstore; fist* = OPIR.fist;
  fild* = OPIR.fild; fadd* = OPIR.fadd; fsub* = OPIR.fsub;
  fmul* = OPIR.fmul; fdiv* = OPIR.fdiv; fabs* = OPIR.fabs;
  fchs* = OPIR.fchs; fcmp* = OPIR.fcmp;
  newStat* = OPIR.newStat;

  (* Pseudo-register constants from OPIR *)
  none* = OPIR.none; RiscFP* = OPIR.FP; RiscSP* = OPIR.SP;
  noScale = OPIR.noScale; Scale1 = OPIR.Scale1;
  Scale2 = OPIR.Scale2; Scale4 = OPIR.Scale4;
  RegReg = OPIR.RegReg; RegMem = OPIR.RegMem;
  MemReg = OPIR.MemReg; ImmReg = OPIR.ImmReg; ImmMem = OPIR.ImmMem;
  Nil* = OPIR.Nil;

  (* Traps *)
  WithTrap* = OPIR.WithTrap; CaseTrap* = OPIR.CaseTrap;
  FuncTrap* = OPIR.FuncTrap; OverflowTrap* = OPIR.OverflowTrap;
  EqualGuardTrap* = OPIR.EqualGuardTrap; GuardTrap* = OPIR.GuardTrap;
  RangeTrap* = OPIR.RangeTrap; DimTrap* = OPIR.DimTrap;
  nofTrapFixups = 10;

  (* Hints from OPIR *)
  noHint* = OPIR.noHint;
  useR0* = OPIR.useReg0; useR1* = OPIR.useReg1;
  useR2* = OPIR.useReg2; useR3* = OPIR.useReg3;
  useR4* = OPIR.useReg4; useR5* = OPIR.useReg5;
  useR6* = OPIR.useReg6; useR7* = OPIR.useReg7;
  useFReg* = OPIR.useFReg;
  tryR0* = OPIR.tryReg0; tryR1* = OPIR.tryReg1;
  tryR2* = OPIR.tryReg2; tryR3* = OPIR.tryReg3;
  tryR6* = OPIR.tryReg6; tryR7* = OPIR.tryReg7;

  useReg = {useR0, useR1, useR2, useR3, useR4, useR5, useR6, useR7};
  tryReg = {tryR0, tryR1, tryR2, tryR3, tryR6, tryR7};

  (* ARM32 GPR numbers (from OPO) *)
  R0 = OPO.R0; R1 = OPO.R1; R2 = OPO.R2; R3 = OPO.R3;
  R4 = OPO.R4; R5 = OPO.R5; R6 = OPO.R6; R7 = OPO.R7;
  R8 = OPO.R8; R9 = OPO.R9; R10 = OPO.R10;
  FP = OPO.FP; (* R11 - frame pointer *)
  IP = OPO.IP; (* R12 - intra-procedure scratch *)
  SP = OPO.SP; (* R13 - stack pointer *)
  LR = OPO.LR; (* R14 - link register *)
  PC = OPO.PC; (* R15 - program counter *)

  (* ARM32 condition codes (from OPO) *)
  CondEQ = OPO.CondEQ; CondNE = OPO.CondNE;
  CondCS = OPO.CondCS; CondCC = OPO.CondCC;
  CondMI = OPO.CondMI; CondPL = OPO.CondPL;
  CondVS = OPO.CondVS; CondVC = OPO.CondVC;
  CondHI = OPO.CondHI; CondLS = OPO.CondLS;
  CondGE = OPO.CondGE; CondLT = OPO.CondLT;
  CondGT = OPO.CondGT; CondLE = OPO.CondLE;
  CondAL = OPO.CondAL;

  (* Shift types *)
  ShiftLSL = OPO.ShiftLSL; ShiftLSR = OPO.ShiftLSR;
  ShiftASR = OPO.ShiftASR; ShiftROR = OPO.ShiftROR;

  (* Size constants *)
  Bit8 = OPIR.Bit8; Bit16 = OPIR.Bit16;
  Bit32 = OPIR.Bit32; Bit64 = OPIR.Bit64;

  noBase = OPO.noBase; noInx = -1; noImm = OPO.noImm;
  noDisp = OPO.noDisp;

  (* Register allocation states *)
  free = -1; Occupied = MIN(INTEGER); (* Splitted not needed for ARM32 *)

  BUG = 41;

  (* Object file tags *)
  VarEntryTag = 8CX;
  EntryTag = 82X;
  commandTag = 83X;
  pointerTag = 84X;
  importTag = 85X;
  VarConsLinkTag = 8DX;
  LinkTag = 86X;
  DataTag = 87X;
  ExportTag = 88X;
  CodeTag = 89X;
  UseTag = 8AX;
  TypeTag = 8BX;
  RefTag = 8CX;

  (* Export/Use section *)
  EUEnd = 0X; EURecord = 1X; EUProcFlag = 080000000H;

  (* sysflag *)
  notag = 1; stdcall = 2; cdecl = 3; untraced = 4; delegate = 5;

  (* Object modes *)
  Var = 1; VarPar = 2; Con = 3; Fld = 4; Typ = 5;
  LProc = 6; XProc = 7; CProc = 9; IProc = 10; Module = 11; TProc = 13;

  (* Structure forms *)
  Undef = 0; Byte = 1; Bool = 2; Char = 3; SInt = 4; Int = 5; LInt = 6;
  Real = 7; LReal = 8; Set = 9; String = 10; NilTyp = 11; NoTyp = 12;
  Pointer = 13; ProcTyp = 14; Comp = 15; HInt = 16;

  (* Composite structure forms *)
  Basic = 1; StaticArr = 2; SDynArr = 3; DynArr = 4; OpenArr = 5; Record = 6;

  (* Module visibility *)
  internal = 0; external = 1; externalR = 2;

  (* Object type flags *)
  hasBody = 1; slNeeded = 3; activeObj = 5;

  false = 0; true = 1;
  noEntry = -1;

  (* Predefined entry numbers and link indices *)
  CaseTabelIndex = 0; CaseTableEntryNr = 255;
  LocProcAssIndex = 1; LocProcAssEntryNr = 254;
  NewLinkIndex* = OPIR.NewLinkIndex; NewEntryNr* = OPIR.NewEntryNr;
  NewSysLinkIndex* = OPIR.NewSysLinkIndex; NewSysEntryNr* = OPIR.NewSysEntryNr;
  NewArrayLinkIndex* = OPIR.NewArrayLinkIndex; NewArrayEntryNr* = OPIR.NewArrayEntryNr;
  StartIndex* = OPIR.StartIndex; StartEntryNr* = OPIR.StartEntryNr;
  AwaitIndex* = OPIR.AwaitIndex; AwaitEntryNr* = OPIR.AwaitEntryNr;
  LockIndex* = OPIR.LockIndex; LockEntryNr* = OPIR.LockEntryNr;
  UnlockIndex* = OPIR.UnlockIndex; UnlockEntryNr* = OPIR.UnlockEntryNr;

  (* Software arithmetic sysfixes *)
  DivModLinkIndex* = OPIR.DivModLinkIndex; DivModEntryNr* = OPIR.DivModEntryNr;
  F64AddLinkIndex* = OPIR.F64AddLinkIndex; F64AddEntryNr* = OPIR.F64AddEntryNr;
  F64SubLinkIndex* = OPIR.F64SubLinkIndex; F64SubEntryNr* = OPIR.F64SubEntryNr;
  F64MulLinkIndex* = OPIR.F64MulLinkIndex; F64MulEntryNr* = OPIR.F64MulEntryNr;
  F64DivLinkIndex* = OPIR.F64DivLinkIndex; F64DivEntryNr* = OPIR.F64DivEntryNr;
  F64CmpLinkIndex* = OPIR.F64CmpLinkIndex; F64CmpEntryNr* = OPIR.F64CmpEntryNr;
  F64CvtIFLinkIndex* = OPIR.F64CvtIFLinkIndex; F64CvtIFEntryNr* = OPIR.F64CvtIFEntryNr;
  F64CvtFILinkIndex* = OPIR.F64CvtFILinkIndex; F64CvtFIEntryNr* = OPIR.F64CvtFIEntryNr;
  F64NegLinkIndex* = OPIR.F64NegLinkIndex; F64NegEntryNr* = OPIR.F64NegEntryNr;
  F64AbsLinkIndex* = OPIR.F64AbsLinkIndex; F64AbsEntryNr* = OPIR.F64AbsEntryNr;
  InitLinks = 19;

  MaxCommands = 128;
  MaxNewMethods = 16;
  MaxExtensions = 15;
  MaxEntry* = 128;
  LinkLength = 512;
  MaxSaveLevel = 32;

  (* VFP register allocation 
    Single-precision: S0 reserved for return, allocate S2..S31 
    Double-precision: D0 reserved for return, allocate D1..D15 *)
    
  (* We use a flat array of 16 VFP "slots" for double registers D0..D15 *)
  MaxFRegs = 16; (* D0..D15 *)
  FRegBase = 0;  (* D0 is index 0 *)

  (* Number of allocatable GPRs: R0-R10 (11 registers, R11=FP, R12=IP, R13=SP, R14=LR) *)
  MaxGPRs = 11; (* R0..R10 *)

  PtrInit = 5;

 TYPE
  Instruction* = OPIR.Instruction;
  InstructionTable* = OPIR.InstructionTable;
  Map* = OPIR.Map;
  MapDesc* = OPIR.MapDesc;

  LinkRec = RECORD
   offset: LONGINT;
   mod, entry: INTEGER;
  END;

  VarConsRec = RECORD
   mod, entry, noflinks, index: INTEGER
  END;
  VarConsTable = POINTER TO ARRAY OF VarConsRec;

  VarConsLinkRec = RECORD
   offset, next: INTEGER
  END;
  VarConsLinkTable = POINTER TO ARRAY OF VarConsLinkRec;

  SavedRegRec = RECORD
   reg: ARRAY MaxGPRs OF INTEGER;  (* saved GPR allocation states *)
   freg: ARRAY MaxFRegs OF INTEGER; (* saved VFP allocation states *)
  END;

  PtrTable = POINTER TO ARRAY OF LONGINT;
  RecTable = POINTER TO ARRAY OF OPT.Struct;
  EntryTable = POINTER TO ARRAY OF INTEGER;
  ExpTable = POINTER TO ARRAY OF LONGINT;

 VAR
  ptrTab: PtrTable;
  recTab: RecTable;
  entry: EntryTable;

  varConsLink: VarConsTable;
  link: ARRAY LinkLength OF LinkRec;
  varConsTab: VarConsLinkTable;
  nofVarCons, noVarEntries, nofEntries, nofVarConsLinks, nofLinks, nofrecs: INTEGER;
  nofptrs: LONGINT;
  ConstErr, RegErr, VarEntryErr, LinkErr: BOOLEAN;

  (* register allocation 
    regTab[i] = free (-1), Occupied (MIN(INTEGER)), or pReg index (>= 0)
     Indices 0..10 correspond to R0..R10 *)
  regTab: ARRAY MaxGPRs OF LONGINT;

  (* VFP register allocation: fregTab[i] for D0..D15 *)
  fregTab: ARRAY MaxFRegs OF LONGINT;

  savedRegs: ARRAY MaxSaveLevel OF SavedRegRec;
  nofSavedLevel: INTEGER;

   trapFixupTab: ARRAY nofTrapFixups OF LONGINT;

  nofStr: INTEGER;
  linkTable*: LONGINT;
  gVarLink*: LONGINT;
  hasHWDiv*: BOOLEAN; (* TRUE: emit SDIV/UDIV; FALSE: emit sysfix call to DivMod32 *)

  (* VFP return value tracking *)
  currentProcRetForm: SHORTINT; (* return type form of current procedure: Real=7, LReal=8, or 0 *)
  lastFstoreFreg: SHORTINT; (* D-register index used by last Fstore, or -1 *)
  spSubPending: BOOLEAN; (* TRUE when Gen3 Sub from SP occurred, consumed by Fstore/RepMovs *)

  explist: ExpTable; exppos: LONGINT;

 PROCEDURE Init*;
 BEGIN
  OPO.CodeErr := FALSE; ConstErr := FALSE;
  VarEntryErr := FALSE; LinkErr := FALSE;
  OPO.dsize := 0; OPO.csize := 0; OPO.pc := 0;
  noVarEntries := 0; nofptrs := 0; nofVarConsLinks := 0;
  nofrecs := 0; nofEntries := 0; nofSavedLevel := 0;
  lastFstoreFreg := -1; currentProcRetForm := 0; spSubPending := FALSE;
  OPO.csize := 4; (* module.SELF *)
  varConsLink[0].noflinks := 0; varConsLink[0].entry := -1;
  varConsLink[0].noflinks := 0; varConsLink[0].index := noEntry;
  nofVarCons := 1;
  link[0].mod := 0; link[0].entry := CaseTableEntryNr; link[0].offset := Nil;
  link[1].mod := 0; link[1].entry := LocProcAssEntryNr; link[1].offset := Nil;
  link[2].mod := 0; link[2].entry := NewEntryNr; link[2].offset := Nil;
  link[3].mod := 0; link[3].entry := NewSysEntryNr; link[3].offset := Nil;
  link[4].mod := 0; link[4].entry := NewArrayEntryNr; link[4].offset := Nil;
  link[5].mod := 0; link[5].entry := StartEntryNr; link[5].offset := Nil;
  link[6].mod := 0; link[6].entry := AwaitEntryNr; link[6].offset := Nil;
  link[7].mod := 0; link[7].entry := LockEntryNr; link[7].offset := Nil;
  link[8].mod := 0; link[8].entry := UnlockEntryNr; link[8].offset := Nil;
  (* Software arithmetic sysfixes *)
  link[9].mod := 0; link[9].entry := DivModEntryNr; link[9].offset := Nil;
  link[10].mod := 0; link[10].entry := F64AddEntryNr; link[10].offset := Nil;
  link[11].mod := 0; link[11].entry := F64SubEntryNr; link[11].offset := Nil;
  link[12].mod := 0; link[12].entry := F64MulEntryNr; link[12].offset := Nil;
  link[13].mod := 0; link[13].entry := F64DivEntryNr; link[13].offset := Nil;
  link[14].mod := 0; link[14].entry := F64CmpEntryNr; link[14].offset := Nil;
  link[15].mod := 0; link[15].entry := F64CvtIFEntryNr; link[15].offset := Nil;
  link[16].mod := 0; link[16].entry := F64CvtFIEntryNr; link[16].offset := Nil;
  link[17].mod := 0; link[17].entry := F64NegEntryNr; link[17].offset := Nil;
  link[18].mod := 0; link[18].entry := F64AbsEntryNr; link[18].offset := Nil;
  nofLinks := InitLinks;
  hasHWDiv := TRUE;
 END Init;


 PROCEDURE RegToGPR(reg: SHORTINT): SHORTINT;
 (* Convert regTab index (0..10) to ARM32 GPR number (R0..R10) *)
 BEGIN
  RETURN reg (* identity: index 0 = R0, ..., index 10 = R10 *)
 END RegToGPR;

 PROCEDURE GPRToReg(gpr: SHORTINT): SHORTINT;
 (* Convert ARM32 GPR number to regTab index *)
 BEGIN
  RETURN gpr (* identity *)
 END GPRToReg;

 PROCEDURE IsAllocatable(gpr: SHORTINT): BOOLEAN;
 (* Returns TRUE if the GPR can be allocated (R0-R10) *)
 BEGIN
  RETURN (gpr >= R0) & (gpr <= R10)
 END IsAllocatable;

 PROCEDURE loaded(pReg: LONGINT): BOOLEAN;
 BEGIN
  IF pReg > none THEN RETURN OPIR.Instr[pReg].reg > none
  ELSE RETURN (pReg = RiscSP) OR (pReg = RiscFP)
  END
 END loaded;

      PROCEDURE GetReg(VAR reg: SHORTINT);
 (* Returns any free allocatable GPR (R0-R10) and marks it occupied *)
 (* Allocation order: R0-R3 (scratch) first, then R4-R10 (callee-saved) *)
 (* If all registers are full, evict a re-computable instruction *)
      VAR r: SHORTINT; pReg, bestPReg: LONGINT; bestR, op: SHORTINT;

   PROCEDURE Evictable(op: SHORTINT): BOOLEAN;
   (* Returns TRUE if the instruction category can be re-computed by Load() *)
   BEGIN
    RETURN ((op >= Ld) & (op <= Ldbwu)) (* Load instructions: op/32 = 1..7 *)
        OR (op = Lea)                    (* LEA: address computation *)
        OR (op = Add) OR (op = Sub)      (* Binary arithmetic *)
        OR (op = Neg) OR (op = Not)      (* Unary arithmetic *)
   END Evictable;

    BEGIN
     (* Try R0..R10 in order *)
     r := R0;
     WHILE (r <= R10) & (regTab[r] # free) DO INC(r) END;
     IF r > R10 THEN
      (* All registers occupied: try to evict a re-computable instruction.
         Load, Lea, Add, Sub, Neg, Not can all be re-executed by Load(). *)
      bestR := none; bestPReg := -1;
      r := R10;
      WHILE r >= R0 DO
       pReg := regTab[r];
       IF (pReg > none) & (pReg # Occupied) THEN
        op := SHORT(OPIR.Instr[pReg].op DIV 32);
        IF Evictable(op) THEN
         (* Prefer evicting the oldest (lowest pReg number) to minimize re-use distance *)
         IF (bestR = none) OR (pReg < bestPReg) THEN
          bestR := r; bestPReg := pReg
         END
        END
       END;
       DEC(r)
      END;
      IF bestR # none THEN
       (* Evict: mark the pReg as not loaded so FindLoadReg will reload it *)
       OPIR.Instr[bestPReg].reg := (-2) - bestR;
       regTab[bestR] := free;
       r := bestR
      ELSE
       OPM.err(215); RegErr := TRUE; reg := R0; RETURN
      END
     END;
     regTab[r] := Occupied;
     reg := r
    END GetReg;

 PROCEDURE GetThisReg(this: SHORTINT);
 (* Marks 'this' GPR as occupied. If occupied, moves its value to another register *)
  VAR r: SHORTINT; pReg: LONGINT;
 BEGIN
  ASSERT(IsAllocatable(this));
  IF regTab[this] # free THEN
   IF regTab[this] = Occupied THEN
    (* Register is occupied but not tracking a pReg - just mark it *)
    (* This can happen for SP/FP which are always occupied *)
   ELSE
    (* Move the current occupant to another register *)
    pReg := regTab[this];
    ASSERT(pReg >= 0);
    GetReg(r);
    regTab[r] := pReg;
    OPIR.Instr[pReg].reg := r;
    OPO.GenMOVReg(CondAL, r, this)
   END
  END;
  regTab[this] := Occupied
 END GetThisReg;

  PROCEDURE FreeReg(reg: SHORTINT);
 (* Releases a GPR *)
  VAR pReg: LONGINT;
 BEGIN
  IF (reg > none) & IsAllocatable(reg) THEN
   pReg := regTab[reg];
   IF pReg > none THEN OPIR.Instr[pReg].reg := -2 - reg END;
   regTab[reg] := free
  END
 END FreeReg;

 PROCEDURE DecReg(reg: SHORTINT);
 (* Decrements use count of register; frees if count reaches 0 *)
  VAR pReg: LONGINT;
 BEGIN
  IF reg > none THEN
   IF IsAllocatable(reg) THEN pReg := regTab[reg]
   ELSE pReg := none
   END;
   IF pReg > none THEN
    DEC(OPIR.Instr[pReg].used);
    IF (OPIR.Instr[pReg].used = 0) & (OPIR.Instr[pReg].reg > Nil) THEN
     FreeReg(OPIR.Instr[pReg].reg)
    END
   END
  END
 END DecReg;

 PROCEDURE LastUse(reg: SHORTINT): BOOLEAN;
  VAR pReg: LONGINT;
 BEGIN
  IF ~IsAllocatable(reg) THEN RETURN FALSE END;
  pReg := regTab[reg];
  IF pReg > none THEN RETURN OPIR.Instr[pReg].used = 1
  ELSE RETURN TRUE
  END
 END LastUse;

 PROCEDURE AssignNewReg(pReg: LONGINT);
 (* Assigns pReg to any free register *)
  VAR reg: SHORTINT;
 BEGIN
  GetReg(reg);
  regTab[reg] := pReg;
  OPIR.Instr[pReg].reg := reg
 END AssignNewReg;

  PROCEDURE AssignThisReg(pReg: LONGINT; this: SHORTINT);
 (* Assigns pReg to register 'this'. Moves 'this' if occupied. *)
 BEGIN
  IF ~IsAllocatable(this) THEN
   (* Non-allocatable register (IP/SP/FP/LR): redirect to a free allocatable register.
      IP is used as scratch by Load/Store/EmitXxxImm; assigning IR results to it
      causes silent clobbering because IP is not tracked in regTab. *)
   AssignNewReg(pReg); RETURN
  END;
  GetThisReg(this);
  regTab[this] := pReg;
  OPIR.Instr[pReg].reg := this
 END AssignThisReg;

  PROCEDURE AssignReg(pReg: LONGINT; VAR reg, base, inx: SHORTINT);
 (* Assigns pReg to a register, considering hints and reuse.
    When a useReg hint forces AssignThisReg, the existing occupant of the
    target register may be moved to a different register.  We must fixup
    the VAR parameters reg/base/inx so callers (especially DecCheckReg)
    see the up-to-date register numbers - otherwise they operate on stale
    values and can evict the instruction that was just assigned. *)
   VAR hint, pRegReg, pRegBase, pRegInx: LONGINT;
 BEGIN
   hint := OPIR.Instr[pReg].hint;
   IF hint >= tryR0 THEN
    IF regTab[hint - tryR0] = free THEN
     AssignThisReg(pReg, SHORT(SHORT(hint - tryR0)));
     RETURN
    END;
    hint := noHint
   END;
   IF hint <= noHint THEN
    IF (reg = none) OR ~IsAllocatable(reg) OR ~LastUse(reg) THEN AssignNewReg(pReg)
    ELSE OPIR.Instr[pReg].reg := reg
    END
   ELSE
    (* Save pReg indices before AssignThisReg may move occupants *)
    pRegReg := none; pRegBase := none; pRegInx := none;
    IF (reg > none) & IsAllocatable(reg) THEN pRegReg := regTab[reg] END;
    IF (base > none) & IsAllocatable(base) THEN pRegBase := regTab[base] END;
    IF (inx > none) & IsAllocatable(inx) THEN pRegInx := regTab[inx] END;
    AssignThisReg(pReg, SHORT(SHORT(hint)));
    (* Fixup: occupants may have been moved to new registers *)
    IF (reg > none) & (pRegReg > none) THEN reg := OPIR.Instr[pRegReg].reg END;
    IF (base > none) & (pRegBase > none) THEN base := OPIR.Instr[pRegBase].reg END;
    IF (inx > none) & (pRegInx > none) THEN inx := OPIR.Instr[pRegInx].reg END
   END
 END AssignReg;

 PROCEDURE DecCheckReg(pReg: LONGINT; src, base, inx: SHORTINT);
 (* Decrements use counts and updates register tracking *)
  VAR reg: SHORTINT;

  PROCEDURE ReleaseReg(r: SHORTINT);
   VAR p: LONGINT;
  BEGIN
   IF r > none THEN
    IF IsAllocatable(r) THEN p := regTab[r]
    ELSE p := none
    END;
    IF p > none THEN OPIR.Instr[p].reg := -2 - r END
   END
  END ReleaseReg;

  PROCEDURE CheckRegister(r, s: SHORTINT);
  BEGIN
   IF r = s THEN ReleaseReg(s)
   ELSE DecReg(s)
   END
  END CheckRegister;

 BEGIN
  reg := OPIR.Instr[pReg].reg;
  CheckRegister(reg, src);
  CheckRegister(reg, base);
  CheckRegister(reg, inx);
  IF (reg > none) & IsAllocatable(reg) THEN
   regTab[reg] := pReg
  END
 END DecCheckReg;

  PROCEDURE FindReg(pReg: LONGINT; VAR reg: SHORTINT);
 BEGIN
  IF pReg > none THEN
   IF ~loaded(pReg) THEN Load(OPIR.Instr[pReg]) END;
   reg := OPIR.Instr[pReg].reg
  ELSIF pReg = RiscSP THEN reg := SP
  ELSIF pReg = RiscFP THEN reg := FP
  ELSE reg := none
  END
 END FindReg;

 PROCEDURE^ Load(VAR instr: Instruction);

 PROCEDURE FindLoadReg(pReg: LONGINT; VAR reg: SHORTINT);
 BEGIN
  IF pReg > none THEN
   IF ~loaded(pReg) THEN Load(OPIR.Instr[pReg]) END;
   reg := OPIR.Instr[pReg].reg
  ELSIF pReg = RiscSP THEN reg := SP
  ELSIF pReg = RiscFP THEN reg := FP
  ELSE reg := none
  END
 END FindLoadReg;

 PROCEDURE FindMemReg(VAR instr: Instruction; VAR mode, size, base, inx: SHORTINT; VAR disp: LONGINT);
 BEGIN
  size := SHORT(instr.op MOD 8) * 8;
  mode := SHORT((instr.op DIV 8) MOD 4);
  IF mode IN {MemReg, RegMem} THEN
   FindLoadReg(instr.src1, base); disp := instr.src2;
   FindLoadReg(instr.inx, inx)
  ELSIF mode = RegReg THEN
   FindLoadReg(instr.src1, base);
   disp := noDisp; inx := none
  ELSE (* ImmReg *)
   base := noBase; disp := noDisp; inx := none
  END
 END FindMemReg;

(*  VFP  *)

 PROCEDURE GetFreg(VAR freg: SHORTINT);
 (* Returns any free VFP double register D0..D15 *)
  VAR i: SHORTINT;
 BEGIN
  (* Start from D1 to keep D0 for return values *)
  i := 1;
  WHILE (i < MaxFRegs) & (fregTab[i] # free) DO INC(i) END;
  IF i >= MaxFRegs THEN
   (* Try D0 as last resort *)
   IF fregTab[0] = free THEN i := 0
   ELSE OPM.err(216); RegErr := TRUE; freg := 0; RETURN
   END
  END;
  fregTab[i] := Occupied;
  freg := i
 END GetFreg;

 PROCEDURE FreeFreg(freg: SHORTINT);
 BEGIN
  IF freg > none THEN
   IF fregTab[freg] > free THEN OPIR.Instr[fregTab[freg]].reg := -2 - freg END;
   fregTab[freg] := free
  END
 END FreeFreg;

 PROCEDURE AssignFreg(pReg: LONGINT);
  VAR freg: SHORTINT;
 BEGIN
  GetFreg(freg);
  fregTab[freg] := pReg;
  OPIR.Instr[pReg].reg := freg
 END AssignFreg;

 PROCEDURE FindFreg(pReg: LONGINT; VAR freg: SHORTINT);
 BEGIN
  ASSERT((pReg >= 0) & (OPIR.Instr[pReg].reg >= 0));
  freg := OPIR.Instr[pReg].reg
 END FindFreg;

 PROCEDURE LastUseF(freg: SHORTINT): BOOLEAN;
 BEGIN
  ASSERT((freg >= 0) & (freg < MaxFRegs) & (fregTab[freg] >= 0));
  RETURN OPIR.Instr[fregTab[freg]].used = 1
 END LastUseF;

 PROCEDURE DecCheckFreg(freg: SHORTINT);
  VAR pReg: LONGINT;
 BEGIN
  IF freg > none THEN
   pReg := fregTab[freg];
   DEC(OPIR.Instr[pReg].used);
   IF OPIR.Instr[pReg].used = 0 THEN FreeFreg(freg) END
  END
 END DecCheckFreg;

 PROCEDURE IsSinglePrec(instr: Instruction): BOOLEAN;
 (* Returns TRUE if the FP instruction operates on single-precision (REAL) *)
 BEGIN
  RETURN (instr.op MOD 8) = 3 (* size=3 means float/single *)
 END IsSinglePrec;

 PROCEDURE FregToSreg(freg: SHORTINT): SHORTINT;
 (* Convert double-register index to single-register index *)
 (* D0 -> S0, D1 -> S2, D2 -> S4, etc. (each D-reg = 2 S-regs) *)
 BEGIN
  RETURN freg * 2
 END FregToSreg;

(*  Object file  *)

 PROCEDURE NewVarCons*(mod, entry: INTEGER; VAR index: LONGINT);
  VAR i: LONGINT; var: VarConsTable;
 BEGIN
  IF nofVarCons >= LEN(varConsLink) THEN
   NEW(var, LEN(varConsLink) * 2);
   FOR i := 0 TO LEN(varConsLink) - 1 DO var[i] := varConsLink[i] END;
   varConsLink := var
  END;
  varConsLink[nofVarCons].mod := mod; varConsLink[nofVarCons].entry := entry;
  varConsLink[nofVarCons].noflinks := 0; varConsLink[nofVarCons].index := noEntry;
  index := nofVarCons;
  INC(nofVarCons)
 END NewVarCons;

 PROCEDURE VarConsLink(index, offset: LONGINT);
  VAR i: LONGINT; var: VarConsLinkTable;
 BEGIN
  IF nofVarConsLinks >= LEN(varConsTab) THEN
   NEW(var, LEN(varConsTab) * 2);
   FOR i := 0 TO LEN(varConsTab) - 1 DO var[i] := varConsTab[i] END;
   varConsTab := var
  END;
  INC(varConsLink[index].noflinks);
  IF varConsLink[index].noflinks = 1 THEN
   varConsLink[index].index := nofVarConsLinks
  ELSE
   index := varConsLink[index].index;
   WHILE varConsTab[index].next # noEntry DO index := varConsTab[index].next END;
   varConsTab[index].next := nofVarConsLinks
  END;
  varConsTab[nofVarConsLinks].offset := SHORT(offset DIV 4);
  varConsTab[nofVarConsLinks].next := noEntry;
  INC(nofVarConsLinks)
 END VarConsLink;

 PROCEDURE AbsAccess(node: OPT.Node; offset: LONGINT);
 BEGIN
  IF OPM.noerr THEN
   IF (node # NIL) & (node.link = NIL) & (node.obj = NIL) &
      (node.left = NIL) & (node.right = NIL) THEN
    VarConsLink(0, offset)
   ELSE
    WHILE (node # NIL) & (node.left # NIL) DO node := node.left END;
    IF (node = NIL) OR (node.obj.mnolev = 0) THEN
     VarConsLink(0, offset)
    ELSE
     VarConsLink(node.obj.adr DIV 10000H, offset)
    END
   END
  END
 END AbsAccess;

 PROCEDURE NewEntry*(VAR entryNr: LONGINT);
  VAR table: EntryTable; i: LONGINT;
 BEGIN
  IF nofEntries >= LEN(entry) THEN
   NEW(table, LEN(entry) * 2);
   FOR i := 0 TO LEN(entry) - 1 DO table[i] := entry[i] END;
   entry := table
  END;
  entry[nofEntries] := Nil;
  entryNr := nofEntries;
  INC(nofEntries)
 END NewEntry;

 PROCEDURE NewLink*(mod, entry: LONGINT; VAR index: LONGINT);
 BEGIN
  IF nofLinks >= LinkLength THEN
   IF ~LinkErr THEN OPM.err(231); LinkErr := TRUE; index := 0 END
  ELSE
   link[nofLinks].mod := SHORT(mod); link[nofLinks].entry := SHORT(entry);
   link[nofLinks].offset := Nil;
   index := nofLinks;
   INC(nofLinks)
  END
 END NewLink;

 PROCEDURE AddLink(index, offset: LONGINT);
 (* BL instruction is at 'offset'; store fixup chain in the BL's imm24 field *)
 (* The chain stores the previous offset as a word offset (byte offset DIV 4) *)
  VAR old: LONGINT;
 BEGIN
  IF ~LinkErr THEN
   OPO.GetWord(offset, old);
   IF link[index].offset = Nil THEN
    (* First entry: encode -1 as sentinel (0xFFFFFF) *)
    OPO.PutWordAt(offset, (old DIV 1000000H) * 1000000H + 0FFFFFFH)
   ELSE
    (* Chain: encode previous offset as word offset *)
    OPO.PutWordAt(offset, (old DIV 1000000H) * 1000000H +
     (link[index].offset DIV 4 MOD 1000000H))
   END;
   link[index].offset := offset
  END
 END AddLink;

 PROCEDURE AllocConst*(VAR s: ARRAY OF SYSTEM.BYTE; len, align: LONGINT; VAR adr: LONGINT);
  VAR fill: LONGINT; table: OPO.ConstArray;
 BEGIN
  IF ~ConstErr THEN
   adr := OPO.csize;
   OPO.csize := OPO.csize + len;
   fill := (-len) MOD align;
   IF OPO.csize + fill > OPO.MaxConstLength THEN
    OPM.err(230); ConstErr := TRUE
   ELSE
    IF OPO.csize + fill >= LEN(OPO.constant) THEN
     NEW(table, LEN(OPO.constant) * 2);
     SYSTEM.MOVE(SYSTEM.ADR(OPO.constant[0]), SYSTEM.ADR(table[0]), adr);
     OPO.constant := table
    END;
    WHILE fill > 0 DO
     OPO.constant[OPO.csize] := 0X; INC(OPO.csize); DEC(fill)
    END;
    SYSTEM.MOVE(SYSTEM.ADR(s[0]), SYSTEM.ADR(OPO.constant[adr]), len)
   END
  ELSE adr := 0
  END
 END AllocConst;

 PROCEDURE AllocCaseTab*(low, high: LONGINT; VAR tab: LONGINT);
  VAR len, i: LONGINT; table: OPO.ConstArray;
 BEGIN
  IF ~ConstErr THEN
   len := 4 * (high - low + 1);
   tab := OPO.csize;
   OPO.csize := OPO.csize + len;
   IF OPO.csize > OPO.MaxConstLength THEN
    OPM.err(230); ConstErr := TRUE
   ELSE
    IF OPO.csize >= LEN(OPO.constant) THEN
     NEW(table, LEN(OPO.constant) * 2);
     SYSTEM.MOVE(SYSTEM.ADR(OPO.constant[0]), SYSTEM.ADR(table[0]), tab);
     OPO.constant := table
    END;
    i := tab;
    WHILE i < OPO.csize DO OPO.constant[i] := CHR(255); INC(i) END
   END
  ELSE tab := 0
  END
 END AllocCaseTab;

 PROCEDURE AllocTypDesc*(typ: OPT.Struct);
  VAR nil: LONGINT; table: RecTable; i: LONGINT;
 BEGIN
  IF typ.comp = Record THEN
   nil := 0; AllocConst(nil, 4, 4, typ.tdadr);
   IF typ.extlev > MaxExtensions THEN OPM.err(233)
   ELSIF typ.mno = 0 THEN
    IF nofrecs >= LEN(recTab) THEN
     NEW(table, LEN(recTab) * 2);
     FOR i := 0 TO LEN(recTab) - 1 DO table[i] := recTab[i] END;
     recTab := table
    END;
    recTab[nofrecs] := typ; INC(nofrecs)
   END
  END
 END AllocTypDesc;

 PROCEDURE CaseJump*(Label, tab, from, to: LONGINT);
 BEGIN
  IF ~ConstErr THEN
   from := tab + 4 * from; to := tab + 4 * to;
   WHILE from <= to DO
    OPO.PutConsDWord(from, Label);
    from := from + 4
   END
  END
 END CaseJump;

(* Load / Store / LEA  *)

 PROCEDURE MapSysReg(hint: LONGINT): SHORTINT;
 BEGIN
  IF hint = 4 THEN RETURN SP
  ELSIF hint = 5 THEN RETURN FP
  ELSE RETURN SHORT(SHORT(hint))
  END
 END MapSysReg;
 
 PROCEDURE Load(VAR instr: Instruction);
   VAR
    mode, size, base, inx, dummy, memBase: SHORTINT;
    disp: LONGINT;
    op: LONGINT;
 BEGIN
   op := instr.op DIV 32;
  IF (op = Neg) OR (op = Not) THEN
   IF loaded(instr.src1) THEN base := OPIR.Instr[instr.src1].reg
   ELSE FindLoadReg(instr.src1, base) END;
   dummy := none;
   AssignReg(instr.dest, base, dummy, dummy);
   IF op = Neg THEN
    OPO.GenDataProcImm(CondAL, OPO.dpRSB, 0, instr.reg, base, 0)
   ELSE
    OPO.GenDataProcReg(CondAL, OPO.dpMVN, 0, instr.reg, 0, base, ShiftLSL, 0)
   END;
   IF (instr.reg = base) & IsAllocatable(base) THEN
    IF regTab[base] > none THEN OPIR.Instr[regTab[base]].reg := -2 - base END
   END;
   IF (instr.reg > none) & IsAllocatable(instr.reg) THEN
    regTab[instr.reg] := instr.dest
   END;
   RETURN
  ELSIF (op = Add) OR (op = Sub) THEN
   (* Re-compute a displaced binary arithmetic instruction.
      This can happen when register pressure causes a previously computed
      Add/Sub result to lose its register via FreeReg/ReleaseReg. *)
   mode := SHORT((instr.op DIV 8) MOD 4);
   FindLoadReg(instr.src1, base);
   dummy := none;
   IF mode = ImmReg THEN
    inx := none;
    AssignReg(instr.dest, base, dummy, dummy);
    IF op = Add THEN EmitAddImm(CondAL, instr.reg, base, instr.src2)
    ELSE EmitSubImm(CondAL, instr.reg, base, instr.src2) END
   ELSE
    FindLoadReg(instr.src2, inx);
    AssignReg(instr.dest, base, inx, dummy);
    IF op = Add THEN OPO.GenADD(CondAL, instr.reg, base, inx)
    ELSE OPO.GenSUB(CondAL, instr.reg, base, inx) END
   END;
   IF (instr.reg = base) & IsAllocatable(base) THEN
    IF regTab[base] > none THEN OPIR.Instr[regTab[base]].reg := -2 - base END
   END;
   IF (instr.reg > none) & IsAllocatable(instr.reg) THEN
    regTab[instr.reg] := instr.dest
   END;
   RETURN
  END;
  FindMemReg(instr, mode, size, base, inx, disp);
  IF op # PUTreg THEN AssignReg(instr.dest, base, base, inx) END;
  
  IF (mode IN {RegMem, MemReg}) & (base = noBase) THEN
   (* Use IP to build the address to prevent overwriting 'inx' 
      if the allocator reused the index register for instr.reg *)
   OPO.GenMOVW(CondAL, IP, disp MOD 10000H);
   IF ~instr.abs THEN AbsAccess(instr.node, OPO.pc - 4) END;
   OPO.GenMOVT(CondAL, IP, disp DIV 10000H MOD 10000H);
   IF inx > none THEN
    IF instr.scale > 0 THEN
     OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, IP, inx, ShiftLSL, instr.scale)
    ELSE OPO.GenADD(CondAL, IP, IP, inx) END
   END;
   CASE op OF
    Ld:
     IF size = Bit8 THEN OPO.GenLDRB(CondAL, instr.reg, IP, 0)
     ELSIF size = Bit16 THEN OPO.GenLDRH(CondAL, instr.reg, IP, 0)
     ELSE OPO.GenLDR(CondAL, instr.reg, IP, 0) END
    | Lea:
     IF instr.reg # IP THEN OPO.GenMOVReg(CondAL, instr.reg, IP) END
    | Ldbdw, Ldbw: OPO.GenLDRSB(CondAL, instr.reg, IP, 0)
    | Ldwdw: OPO.GenLDRSH(CondAL, instr.reg, IP, 0)
    | Ldbdwu, Ldbwu: OPO.GenLDRB(CondAL, instr.reg, IP, 0)
    | Ldwdwu: OPO.GenLDRH(CondAL, instr.reg, IP, 0)
   ELSE HALT(BUG) END;
   dummy := none;
   DecCheckReg(instr.dest, dummy, base, inx);
   RETURN
  END;

  IF mode IN {MemReg, RegMem} THEN
   AdjustLargeOffset(base, disp, GetOffsetLimit(op, size))
  END;
  memBase := base;
  IF inx > none THEN
   IF instr.scale > 0 THEN
    OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, base, inx, ShiftLSL, instr.scale)
   ELSE OPO.GenADD(CondAL, IP, base, inx) END;
   memBase := IP
  END;
  CASE op OF
   | Ld:
    IF mode = ImmReg THEN
     OPO.LoadImm32(CondAL, instr.reg, instr.src2)
    ELSIF mode = RegReg THEN
     IF instr.reg # memBase THEN OPO.GenMOVReg(CondAL, instr.reg, memBase) END
    ELSE
	    IF size = Bit8 THEN OPO.GenLDRB(CondAL, instr.reg, memBase, disp)
	    ELSIF size = Bit16 THEN OPO.GenLDRH(CondAL, instr.reg, memBase, disp)
	    ELSE OPO.GenLDR(CondAL, instr.reg, memBase, disp) END
    END
   | Lea:
    IF disp = 0 THEN
     IF instr.reg # memBase THEN OPO.GenMOVReg(CondAL, instr.reg, memBase) END
    ELSE
     IF instr.reg # memBase THEN OPO.GenMOVReg(CondAL, instr.reg, memBase) END;
     EmitAddImm(CondAL, instr.reg, instr.reg, disp)
    END
   | Ldbdw, Ldbw:
    IF mode = RegReg THEN OPO.GenSXTB(CondAL, instr.reg, memBase)
    ELSE OPO.GenLDRSB(CondAL, instr.reg, memBase, disp) END
   | Ldwdw:
    IF mode = RegReg THEN OPO.GenSXTH(CondAL, instr.reg, memBase)
    ELSE OPO.GenLDRSH(CondAL, instr.reg, memBase, disp) END
   | Ldbdwu, Ldbwu:
    IF mode = RegReg THEN OPO.GenUXTB(CondAL, instr.reg, memBase)
    ELSE OPO.GenLDRB(CondAL, instr.reg, memBase, disp) END
   | Ldwdwu:
    IF mode = RegReg THEN OPO.GenUXTH(CondAL, instr.reg, memBase)
    ELSE OPO.GenLDRH(CondAL, instr.reg, memBase, disp) END
   | PUTreg:
    IF mode = ImmReg THEN OPO.LoadImm32(CondAL, MapSysReg(instr.hint), instr.src2)
    ELSE
     IF MapSysReg(instr.hint) # base THEN OPO.GenMOVReg(CondAL, MapSysReg(instr.hint), base) END
    END
  ELSE HALT(BUG) END;
  dummy := none;
  DecCheckReg(instr.dest, dummy, base, inx)
 END Load;

 PROCEDURE LoadProc(VAR instr: Instruction);
  VAR dummy: SHORTINT;
 BEGIN
  dummy := none;
  AssignReg(instr.dest, dummy, dummy, dummy);
  IF instr.op DIV 32 = LdProc THEN
   (* Local procedure: emit MOVW/MOVT pair with entry number; linker patches *)
   OPO.GenMOVW(CondAL, instr.reg, SHORT(instr.src1 MOD 10000H));
   OPO.GenMOVT(CondAL, instr.reg, SHORT(instr.src1 MOD 10000H));
   AddLink(LocProcAssIndex, OPO.pc - 8)
  ELSE (* LdXProc: imported procedure *)
   OPO.GenMOVW(CondAL, instr.reg, 0FFFFH);
   OPO.GenMOVT(CondAL, instr.reg, 0FFFFH);
   AddLink(SHORT(instr.src1 MOD 10000H), OPO.pc - 8)
  END;
  DecCheckReg(instr.dest, dummy, dummy, dummy)
 END LoadProc;

 PROCEDURE Store(VAR instr: Instruction);
   VAR
    mode, size, reg, base, inx, memBase: SHORTINT;
    disp: LONGINT;
  BEGIN
   FindMemReg(instr, mode, size, base, inx, disp);

   IF instr.op DIV 32 # GETreg THEN
    FindLoadReg(instr.dest, reg);
   ELSE
    reg := none;
   END;

   IF (mode IN {RegMem, MemReg}) & (base = noBase) THEN
    OPO.GenMOVW(CondAL, IP, disp MOD 10000H);
    IF ~instr.abs THEN AbsAccess(instr.node, OPO.pc - 4) END;
    OPO.GenMOVT(CondAL, IP, disp DIV 10000H MOD 10000H);
    IF inx > none THEN
     IF instr.scale > 0 THEN
      OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, IP, inx, ShiftLSL, instr.scale)
     ELSE OPO.GenADD(CondAL, IP, IP, inx) END
    END;
    IF instr.op DIV 32 = GETreg THEN
     (* Translate system register hints to real hardware SP/FP *)
     IF size = Bit8 THEN OPO.GenSTRB(CondAL, MapSysReg(instr.hint), IP, 0)
     ELSIF size = Bit16 THEN OPO.GenSTRH(CondAL, MapSysReg(instr.hint), IP, 0)
     ELSE OPO.GenSTR(CondAL, MapSysReg(instr.hint), IP, 0) END
    ELSE
     IF size = Bit8 THEN OPO.GenSTRB(CondAL, reg, IP, 0)
     ELSIF size = Bit16 THEN OPO.GenSTRH(CondAL, reg, IP, 0)
     ELSE OPO.GenSTR(CondAL, reg, IP, 0) END
    END;
    DecReg(reg); DecReg(base); DecReg(inx);
    RETURN
   END;

   IF mode IN {MemReg, RegMem} THEN
    AdjustLargeOffset(base, disp, GetOffsetLimit(Sto, size))
   END;
   memBase := base;
   IF inx > none THEN
    IF instr.scale > 0 THEN
     OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, base, inx, ShiftLSL, instr.scale)
    ELSE OPO.GenADD(CondAL, IP, base, inx) END;
    memBase := IP
   END;
   IF instr.op DIV 32 = GETreg THEN
    (* CRITICAL FIX: Translate system register hints to real hardware SP/FP *)
    IF size = Bit8 THEN OPO.GenSTRB(CondAL, MapSysReg(instr.hint), memBase, disp)
    ELSIF size = Bit16 THEN OPO.GenSTRH(CondAL, MapSysReg(instr.hint), memBase, disp)
    ELSE OPO.GenSTR(CondAL, MapSysReg(instr.hint), memBase, disp) END
   ELSE
    IF size = Bit8 THEN OPO.GenSTRB(CondAL, reg, memBase, disp)
    ELSIF size = Bit16 THEN OPO.GenSTRH(CondAL, reg, memBase, disp)
    ELSE OPO.GenSTR(CondAL, reg, memBase, disp) END
   END;
  DecReg(reg); DecReg(base); DecReg(inx)
 END Store;

 PROCEDURE GenPush(VAR instr: Instruction);
 (* push: push value onto stack *)
  VAR reg: SHORTINT;
 BEGIN
  IF (instr.op DIV 8) MOD 4 = ImmReg THEN
   (* Push immediate: load into IP then push *)
   OPO.LoadImm32(CondAL, IP, instr.src2);
   OPO.GenSTRPre(CondAL, IP, SP, -4)
  ELSE
   FindLoadReg(instr.src1, reg);
   OPO.GenSTRPre(CondAL, reg, SP, -4);
   DecReg(reg)
  END
 END GenPush;

 PROCEDURE GenPop(VAR instr: Instruction);
 (* pop: pop value from stack into register *)
  VAR dummy: SHORTINT;
 BEGIN
  dummy := none;
  AssignReg(instr.dest, dummy, dummy, dummy);
  OPO.GenLDRPost(CondAL, instr.reg, SP, 4)
 END GenPop;

(* ---- Immediate helpers: handle arbitrary 32-bit immediates ---- *)
(* ARM32 data processing instructions can only encode 8-bit rotated immediates.
   These helpers try the immediate encoding first, and fall back to loading
   the value into IP (R12) scratch register if it doesn't fit. *)

  PROCEDURE EmitAddImm(cond: LONGINT; Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpADD, 0, Rd, Rn, enc)
  ELSIF OPO.CanEncodeImm(-imm, enc) THEN
   (* ADD Rd, Rn, -X = SUB Rd, Rn, X; avoids LoadImm32 clobbering IP when Rn=IP *)
   OPO.GenDataProcImm(cond, OPO.dpSUB, 0, Rd, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenADD(cond, Rd, Rn, IP)
  END
 END EmitAddImm;

  PROCEDURE EmitSubImm(cond: LONGINT; Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpSUB, 0, Rd, Rn, enc)
  ELSIF OPO.CanEncodeImm(-imm, enc) THEN
   (* SUB Rd, Rn, -X = ADD Rd, Rn, X; avoids LoadImm32 clobbering IP when Rn=IP *)
   OPO.GenDataProcImm(cond, OPO.dpADD, 0, Rd, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenSUB(cond, Rd, Rn, IP)
  END
 END EmitSubImm;

 PROCEDURE EmitCmpImm(cond: LONGINT; Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpCMP, 1, 0, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenCMPReg(cond, Rn, IP)
  END
 END EmitCmpImm;

 PROCEDURE EmitTstImm(cond: LONGINT; Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpTST, 1, 0, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenTSTReg(cond, Rn, IP)
  END
 END EmitTstImm;

 PROCEDURE EmitAndImm(cond: LONGINT; Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpAND, 0, Rd, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenANDReg(cond, Rd, Rn, IP)
  END
 END EmitAndImm;

 PROCEDURE EmitOrrImm(cond: LONGINT; Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpORR, 0, Rd, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenORRReg(cond, Rd, Rn, IP)
  END
 END EmitOrrImm;

 PROCEDURE EmitEorImm(cond: LONGINT; Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpEOR, 0, Rd, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenEORReg(cond, Rd, Rn, IP)
  END
 END EmitEorImm;

 PROCEDURE EmitRsbImm(cond: LONGINT; Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpRSB, 0, Rd, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenRSB(cond, Rd, Rn, IP)
  END
 END EmitRsbImm;

 PROCEDURE AdjustLargeOffset(VAR base: SHORTINT; VAR disp: LONGINT; limit: LONGINT);
 (* If |disp| >= limit, materialize base+disp into IP and reset disp to 0.
    PRECONDITION: base # IP (guaranteed for local vars where base = FP = R11).
    This must be called BEFORE the indexed-access code (IF inx > none) so that
    the index computation naturally incorporates the adjusted base. *)
 BEGIN
  IF (disp >= limit) OR (disp <= -limit) THEN
   ASSERT(base # IP); (* base must not be IP; locals always have base=FP=R11 *)
   EmitAddImm(CondAL, IP, base, disp);
   base := IP;
   disp := 0
  END
 END AdjustLargeOffset;

 PROCEDURE GetOffsetLimit(op, size: LONGINT): LONGINT;
 (* Return the maximum absolute offset for the ARM memory instruction that
    will be used for the given pseudo-opcode and operand size. *)
 BEGIN
  CASE op OF
   Ld, Sto:
    IF size = Bit16 THEN RETURN 256  (* LDRH/STRH: 8-bit split offset *)
    ELSE RETURN 4096  (* LDR/STR/LDRB/STRB: 12-bit offset *)
    END
   | Ldbdw, Ldbw: RETURN 256  (* LDRSB: 8-bit split offset *)
   | Ldwdw: RETURN 256  (* LDRSH: 8-bit split offset *)
   | Ldbdwu, Ldbwu: RETURN 4096  (* LDRB: 12-bit offset *)
   | Ldwdwu: RETURN 256  (* LDRH: 8-bit split offset *)
   | FLoad, Fild, FStore, Fist: RETURN 1024  (* VLDR/VSTR: 8-bit word-aligned *)
  ELSE RETURN 4096
  END
 END GetOffsetLimit;

 PROCEDURE EmitBicImm(cond: LONGINT; Rd, Rn, imm: LONGINT);
  VAR enc: LONGINT;
 BEGIN
  IF OPO.CanEncodeImm(imm, enc) THEN
   OPO.GenDataProcImm(cond, OPO.dpBIC, 0, Rd, Rn, enc)
  ELSE
   OPO.LoadImm32(cond, IP, imm);
   OPO.GenBICReg(cond, Rd, Rn, IP)
  END
 END EmitBicImm;

 PROCEDURE EmitMovImm(cond: LONGINT; Rd, imm: LONGINT);
 (* MOV Rd, #imm - handles arbitrary 32-bit values *)
 BEGIN
  OPO.LoadImm32(cond, Rd, imm)
 END EmitMovImm;

(* ---- Part 3: Integer Arithmetic ---- *)

 PROCEDURE Gen2(VAR instr: Instruction);
 (* neg, not *)
  VAR src, dummy: SHORTINT; op: LONGINT;
 BEGIN
  op := instr.op DIV 32;
  FindLoadReg(instr.src1, src);
  dummy := none;
  AssignReg(instr.dest, src, dummy, dummy);
  IF op = Neg THEN
   (* NEG: RSB Rd, Rs, #0 *)
   OPO.GenDataProcImm(CondAL, OPO.dpRSB, 0, instr.reg, src, 0)
  ELSE (* Not: MVN Rd, Rs *)
   OPO.GenDataProcReg(CondAL, OPO.dpMVN, 0, instr.reg, 0, src, ShiftLSL, 0)
  END;
  DecCheckReg(instr.dest, src, dummy, dummy)
 END Gen2;

 PROCEDURE Gen3(VAR instr: Instruction);
 (* add, sub, or, xor, and, sal, sar, shr, rol, bts, btr *)
  VAR
   mode, size, src, base, inx: SHORTINT;
   disp: LONGINT;
   op: LONGINT;
 BEGIN
  op := instr.op DIV 32;
  mode := SHORT((instr.op DIV 8) MOD 4);
  size := SHORT(instr.op MOD 8) * 8;
  IF mode = ImmReg THEN
   FindLoadReg(instr.src1, src);
   base := none; inx := none; disp := noDisp
  ELSIF ~loaded(instr.src1) THEN
   IF ~loaded(instr.src2) THEN
    FindLoadReg(instr.src1, src);
    FindLoadReg(instr.src2, base)
   ELSIF (op = Add) OR (op = oR) OR (op = Xor) OR (op = And) THEN
    FindReg(instr.src2, src);
    FindLoadReg(instr.src1, base)
   ELSE
    FindLoadReg(instr.src1, src);
    FindReg(instr.src2, base)
   END;
   inx := none; disp := noDisp
  ELSIF ~loaded(instr.src2) THEN
   FindReg(instr.src1, src);
   FindLoadReg(instr.src2, base);
   inx := none; disp := noDisp
  ELSE
   FindReg(instr.src1, src);
   FindReg(instr.src2, base);
   inx := none; disp := noDisp
  END;
  AssignReg(instr.dest, src, base, inx);
  
  CASE op OF
   Add:
    IF mode = ImmReg THEN EmitAddImm(CondAL, instr.reg, src, instr.src2)
    ELSE OPO.GenADD(CondAL, instr.reg, src, base) END
   | Sub:
    IF mode = ImmReg THEN EmitSubImm(CondAL, instr.reg, src, instr.src2)
    ELSE OPO.GenSUB(CondAL, instr.reg, src, base) END;
    IF src = SP THEN spSubPending := TRUE END
   | oR:
    IF mode = ImmReg THEN EmitOrrImm(CondAL, instr.reg, src, instr.src2)
    ELSE OPO.GenORRReg(CondAL, instr.reg, src, base) END
   | Xor:
    IF mode = ImmReg THEN EmitEorImm(CondAL, instr.reg, src, instr.src2)
    ELSE OPO.GenEORReg(CondAL, instr.reg, src, base) END
   | And:
    IF mode = ImmReg THEN EmitAndImm(CondAL, instr.reg, src, instr.src2)
    ELSE OPO.GenANDReg(CondAL, instr.reg, src, base) END
   | Sal:
    IF mode = ImmReg THEN OPO.GenShiftImm(CondAL, instr.reg, src, ShiftLSL, SHORT(instr.src2))
    ELSE OPO.GenShiftReg(CondAL, instr.reg, src, ShiftLSL, base) END
   | Sar:
    IF mode = ImmReg THEN OPO.GenShiftImm(CondAL, instr.reg, src, ShiftASR, SHORT(instr.src2))
    ELSE OPO.GenShiftReg(CondAL, instr.reg, src, ShiftASR, base) END
   | Shr:
    IF mode = ImmReg THEN OPO.GenShiftImm(CondAL, instr.reg, src, ShiftLSR, SHORT(instr.src2))
    ELSE OPO.GenShiftReg(CondAL, instr.reg, src, ShiftLSR, base) END
   | Rol:
    IF mode = ImmReg THEN
     OPO.GenShiftImm(CondAL, instr.reg, src, ShiftROR, SHORT((32 - instr.src2) MOD 32))
    ELSE
     EmitRsbImm(CondAL, IP, base, 32);
     OPO.GenShiftReg(CondAL, instr.reg, src, ShiftROR, IP)
    END
   | Bts:
    IF mode = ImmReg THEN
     OPO.LoadImm32(CondAL, IP, 1);
     OPO.GenShiftImm(CondAL, IP, IP, ShiftLSL, SHORT(instr.src2));
     OPO.GenORRReg(CondAL, instr.reg, src, IP)
    ELSE
     OPO.LoadImm32(CondAL, IP, 1);
     OPO.GenShiftReg(CondAL, IP, IP, ShiftLSL, base);
     OPO.GenORRReg(CondAL, instr.reg, src, IP)
    END
   | Btr:
    IF mode = ImmReg THEN
     OPO.LoadImm32(CondAL, IP, 1);
     OPO.GenShiftImm(CondAL, IP, IP, ShiftLSL, SHORT(instr.src2));
     OPO.GenBICReg(CondAL, instr.reg, src, IP)
    ELSE
     OPO.LoadImm32(CondAL, IP, 1);
     OPO.GenShiftReg(CondAL, IP, IP, ShiftLSL, base);
     OPO.GenBICReg(CondAL, instr.reg, src, IP)
    END
  ELSE HALT(BUG)
  END;
  DecCheckReg(instr.dest, src, base, inx)
 END Gen3;

 PROCEDURE GenAbs(VAR instr: Instruction);
 (* abs: absolute value *)
  VAR src, dummy: SHORTINT;
 BEGIN
  FindLoadReg(instr.src1, src);
  dummy := none;
  AssignReg(instr.dest, src, dummy, dummy);
  IF instr.reg # src THEN OPO.GenMOVReg(CondAL, instr.reg, src) END;
  (* CMP Rd, #0; RSBLT Rd, Rd, #0 *)
  EmitCmpImm(CondAL, instr.reg, 0);
  OPO.GenDataProcImm(CondLT, OPO.dpRSB, 0, instr.reg, instr.reg, 0);
  DecCheckReg(instr.dest, src, dummy, dummy)
 END GenAbs;

  PROCEDURE GenMul(VAR instr: Instruction);
 (* mul: integer multiply *)
  VAR src, base, dummy: SHORTINT; mode: LONGINT;
 BEGIN
  mode := (instr.op DIV 8) MOD 4;
  IF mode = ImmReg THEN
   FindLoadReg(instr.src1, src);
   (* MUL doesn't support immediate; load into IP *)
   OPO.LoadImm32(CondAL, IP, instr.src2);
   base := IP
  ELSIF loaded(instr.src2) THEN
   FindReg(instr.src2, base);
   IF ~loaded(instr.src1) THEN FindLoadReg(instr.src1, src)
   ELSE FindReg(instr.src1, src)
   END
  ELSE
   IF ~loaded(instr.src1) THEN FindLoadReg(instr.src1, src)
   ELSE FindReg(instr.src1, src)
   END;
   FindLoadReg(instr.src2, base)
  END;
  dummy := none;
  AssignReg(instr.dest, src, base, dummy);
  OPO.GenMUL(CondAL, instr.reg, src, base);
  DecCheckReg(instr.dest, src, base, dummy)
 END GenMul;

 PROCEDURE GenDivMod(VAR instr: Instruction);
 (* div, mod: Oberon floor division/modulo *)
  VAR
   src, base, dummy: SHORTINT;
   mode: LONGINT;
   isDiv: BOOLEAN;
 BEGIN
  mode := (instr.op DIV 8) MOD 4;
  isDiv := instr.op DIV 32 = Div;
  IF mode = ImmReg THEN
   FindLoadReg(instr.src1, src);
   OPO.LoadImm32(CondAL, IP, instr.src2);
   base := IP
  ELSIF loaded(instr.src2) THEN
   FindReg(instr.src2, base);
   IF ~loaded(instr.src1) THEN FindLoadReg(instr.src1, src)
   ELSE FindReg(instr.src1, src) END
  ELSE
   IF ~loaded(instr.src1) THEN FindLoadReg(instr.src1, src)
   ELSE FindReg(instr.src1, src) END;
   FindLoadReg(instr.src2, base)
  END;
  dummy := none;
  AssignReg(instr.dest, src, base, dummy);

  IF hasHWDiv THEN
   OPO.GenPushReg(CondAL, src);   
   OPO.GenPushReg(CondAL, base);  
   OPO.GenSDIV(CondAL, instr.reg, src, base);
   OPO.GenPushReg(CondAL, instr.reg);
   OPO.GenLDR(CondAL, instr.reg, SP, 0);  
   OPO.GenLDR(CondAL, IP, SP, 4);         
   OPO.GenMUL(CondAL, IP, instr.reg, IP); 
   OPO.GenLDR(CondAL, instr.reg, SP, 8);  
   OPO.GenSUB(CondAL, IP, instr.reg, IP); 
   EmitCmpImm(CondAL, IP, 0);             
   OPO.GenLDR(CondAL, instr.reg, SP, 8);  
   OPO.GenLDR(CondNE, IP, SP, 4);         
   OPO.GenEORReg(CondNE, IP, instr.reg, IP); 
   OPO.GenShiftImm(CondAL, IP, IP, ShiftASR, 31); 
   OPO.GenLDR(CondAL, instr.reg, SP, 0);           
   OPO.GenADD(CondAL, instr.reg, instr.reg, IP);   
   IF ~isDiv THEN
    OPO.GenLDR(CondAL, IP, SP, 4);                 
    OPO.GenMUL(CondAL, IP, instr.reg, IP);         
    OPO.GenLDR(CondAL, instr.reg, SP, 8);          
    OPO.GenSUB(CondAL, instr.reg, instr.reg, IP)   
   END;
   OPO.GenADDImm(CondAL, SP, SP, 12)
  ELSE
   (* === Sysfix BL path (fallback) === *)
   OPO.GenPushReg(CondAL, base);  
   OPO.GenPushReg(CondAL, src);   
   OPO.GenBL(CondAL, 0);
   AddLink(DivModLinkIndex, OPO.pc - 4);
   IF isDiv THEN
    IF instr.reg # 0 THEN OPO.GenMOVReg(CondAL, instr.reg, 0) END
   ELSE
    IF instr.reg # 1 THEN OPO.GenMOVReg(CondAL, instr.reg, 1) END
   END;
   (* Removed OPO.GenADDImm(CondAL, SP, SP, 8).
      Oberon uses callee-cleanup. DivMod32 pops its own 8 bytes.*)
  END;

  DecCheckReg(instr.dest, src, base, dummy)
 END GenDivMod;

 PROCEDURE Flags(VAR instr: Instruction);
 (* cmp, bt, test: set condition flags *)
  VAR
   mode, size, base, inx, reg: SHORTINT;
   disp: LONGINT;
   op: LONGINT;
 BEGIN
  op := instr.op DIV 32;
  mode := SHORT((instr.op DIV 8) MOD 4);
  size := SHORT(instr.op MOD 8) * 8;
  IF mode = ImmReg THEN
   FindLoadReg(instr.src1, reg);
   base := none; inx := none; disp := noDisp
  ELSIF ~loaded(instr.src1) THEN
   IF ~loaded(instr.src2) THEN
    FindLoadReg(instr.src1, reg);
    FindLoadReg(instr.src2, base)
   ELSE
    FindReg(instr.src2, base);
    FindLoadReg(instr.src1, reg)
   END;
   inx := none; disp := noDisp
  ELSIF ~loaded(instr.src2) THEN
   FindReg(instr.src1, reg);
   FindLoadReg(instr.src2, base);
   inx := none; disp := noDisp
  ELSE
   FindReg(instr.src1, reg);
   FindReg(instr.src2, base);
   inx := none; disp := noDisp
  END;
  IF op = Cmp THEN
   IF mode = ImmReg THEN EmitCmpImm(CondAL, reg, instr.src2)
   ELSE OPO.GenCMPReg(CondAL, reg, base) END
  ELSIF op = Test THEN
   IF mode = ImmReg THEN EmitTstImm(CondAL, reg, instr.src2)
   ELSE OPO.GenTSTReg(CondAL, reg, base) END
  ELSE (* Bt: bit test - test bit position *)
   (* Shift bit to MSB and compare natively via scratch register IP.
      This prevents tmp register clobbering and guarantees correct Carry (CS/CC) flags! *)
   IF mode = ImmReg THEN
    OPO.GenShiftImm(CondAL, IP, reg, ShiftLSL, SHORT(31 - (instr.src2 MOD 32)));
    OPO.PutWord(0E35C0102H) (* CMP IP, #0x80000000 *)
   ELSE
    EmitRsbImm(CondAL, IP, base, 31);
    OPO.GenShiftReg(CondAL, IP, reg, ShiftLSL, IP);
    OPO.PutWord(0E35C0102H) (* CMP IP, #0x80000000 *)
   END
  END;
  DecReg(reg); DecReg(base); DecReg(inx)
 END Flags;

 PROCEDURE Setcc(VAR instr: Instruction);
 (* sete, setne, setl, setle, setg, setge, seta, setae, setb, setbe, setc, setnc *)
 (* use conditional MOV to set 0 or 1 *)
  VAR dummy: SHORTINT; cond: SHORTINT;
 BEGIN
  dummy := none;
  AssignReg(instr.dest, dummy, dummy, dummy);
  (* Map IR setcc opcode to ARM condition code *)
  CASE instr.op DIV 32 OF
   Sete:  cond := CondEQ
   | Setne: cond := CondNE
   | Setl:  cond := CondLT
   | Setle: cond := CondLE
   | Setg:  cond := CondGT
   | Setge: cond := CondGE
   | Seta:  cond := CondHI
   | Setae: cond := CondCS
   | Setb:  cond := CondCC
   | Setbe: cond := CondLS
   | Setc:  cond := CondCS
   | Setnc: cond := CondCC
  ELSE HALT(BUG)
  END;
  (* MOV Rd, #0; MOVcond Rd, #1 *)
  OPO.GenDataProcImm(CondAL, OPO.dpMOV, 0, instr.reg, 0, 0);
  OPO.GenDataProcImm(cond, OPO.dpMOV, 0, instr.reg, 0, 1)
 END Setcc;

   PROCEDURE GenRepMovs(VAR instr: Instruction);
 (* repMovs: block memory copy 
   implement as a loop using LDR/STR or LDRB/STRB 
  instr.inx = moveSize (Bit8, Bit16, Bit32); instr.hint = 1 for reversed (backward) copy *)
  VAR dest, src, nofElem: SHORTINT; Lloop: LONGINT;
    step: LONGINT; reverse, stackPush: BOOLEAN;
 BEGIN
  (* Load all three operands safely using loaded() checks to prevent cascading eviction *)
  IF loaded(instr.dest) THEN FindReg(instr.dest, dest) ELSE FindLoadReg(instr.dest, dest) END;
  IF loaded(instr.src1) THEN FindReg(instr.src1, src) ELSE FindLoadReg(instr.src1, src) END;
  IF loaded(instr.src2) THEN FindReg(instr.src2, nofElem) ELSE FindLoadReg(instr.src2, nofElem) END;
  reverse := instr.hint = 1;
  (* Determine step size from moveSize *)
  IF instr.inx = Bit32 THEN step := 4
  ELSIF instr.inx = Bit16 THEN step := 2
  ELSE step := 1 (* Bit8 *)
  END;
  IF reverse THEN step := -step END;
  (* Forward copy to stack (dest=SP) fix.
     On i386 the front-end does SUB ESP,size then REP MOVSD to [EDI] leaving ESP
     unchanged.  On ARM the copy loop used post-increment on SP, moving SP past
     the data.  The callee cleanup (ADD SP,paramSize) then over-corrects SP.
     Fix: when dest=SP and forward, copy in REVERSE order using pre-decrement
     stores (STR IP,[SP,#-step]!).  This naturally decrements SP by totalBytes
     (allocating stack space) and leaves the data in the correct order for the
     callee to read at [FP+8].  The callee ADD SP,paramSize then correctly
     restores SP.  We first adjust src to point to the END of the source. *)
  stackPush := ~reverse & (dest = SP);
  (* Clear spSubPending: GenRepMovs handles SP itself via the stackPush mechanism *)
  IF spSubPending THEN spSubPending := FALSE END;
  IF stackPush THEN
   (* Point src past end of source: ADD src, src, nofElem LSL log2(step) *)
   IF step = 4 THEN
    OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, src, src, nofElem, ShiftLSL, 2)
   ELSIF step = 2 THEN
    OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, src, src, nofElem, ShiftLSL, 1)
   ELSE
    OPO.GenADD(CondAL, src, src, nofElem)
   END
  END;
  (* CMP nofElem, #0; BEQ past loop *)
  EmitCmpImm(CondAL, nofElem, 0);
  (* Use CondLE (Less/Equal) instead of CondEQ. *)
  OPO.GenB(CondLE, 12); 
  Lloop := OPO.pc;
  IF stackPush THEN
   (* Pre-decrement copy: read backward from source end, push onto stack *)
   OPO.GenLDRPre(CondAL, IP, src, -step);
   OPO.GenSTRPre(CondAL, IP, dest, -step)
  ELSIF instr.inx = Bit32 THEN
   (* Word copy: use LDR/STR post-indexed *)
   OPO.GenLDRPost(CondAL, IP, src, step);
   OPO.GenSTRPost(CondAL, IP, dest, step)
  ELSIF instr.inx = Bit16 THEN
   (* Halfword copy: use LDRH/STRH post-indexed *)
   OPO.GenLDRHPost(CondAL, IP, src, step);
   OPO.GenSTRHPost(CondAL, IP, dest, step)
  ELSE
   (* Byte copy: use LDRB/STRB post-indexed *)
   OPO.GenLDRBPost(CondAL, IP, src, step);
   OPO.GenSTRBPost(CondAL, IP, dest, step)
  END;
  OPO.GenDataProcImm(CondAL, OPO.dpSUB, 1, nofElem, nofElem, 1);
  OPO.GenB(CondNE, Lloop - (OPO.pc + 8));
  IF reverse THEN
   OPO.GenMOVReg(CondAL, SP, 4)  (* MOV SP, R4 *)
  END;
  DecReg(dest); DecReg(src); DecReg(nofElem)
 END GenRepMovs;

 PROCEDURE GenCmpString(VAR instr: Instruction);
 (* cmpString: compare two null-terminated strings *)
  VAR srcAdr, src2Adr, ch1, ch2: SHORTINT; Lloop, Ldone: LONGINT;
 BEGIN
  IF loaded(instr.src2) THEN
   FindReg(instr.src2, src2Adr);
   IF ~loaded(instr.src1) THEN FindLoadReg(instr.src1, srcAdr)
   ELSE FindReg(instr.src1, srcAdr) END
  ELSE
   IF ~loaded(instr.src1) THEN FindLoadReg(instr.src1, srcAdr)
   ELSE FindReg(instr.src1, srcAdr) END;
   FindLoadReg(instr.src2, src2Adr)
  END;
  GetReg(ch1); GetReg(ch2);
  Lloop := OPO.pc;
  OPO.GenLDRBPost(CondAL, ch1, srcAdr, 1);
  OPO.GenLDRBPost(CondAL, ch2, src2Adr, 1);
  OPO.GenCMPReg(CondAL, ch1, ch2);
  
  OPO.GenB(CondNE, 4); Ldone := OPO.pc - 4;
  
  OPO.GenDataProcImm(CondAL, OPO.dpCMP, 1, 0, ch1, 0);
  OPO.GenB(CondNE, Lloop - (OPO.pc + 8));
  
  FreeReg(ch1); FreeReg(ch2);
  DecReg(srcAdr); DecReg(src2Adr)
 END GenCmpString;

  PROCEDURE GenShort(VAR instr: Instruction);
 (* short: truncate to shorter type with correct sign-extension *)
  VAR src, dummy: SHORTINT; size: LONGINT;
 BEGIN
  FindLoadReg(instr.src1, src);
  size := (instr.op MOD 8) * 8;
  dummy := none;
  AssignReg(instr.dest, src, dummy, dummy);
  IF size = Bit16 THEN
   OPO.GenSXTH(CondAL, instr.reg, src)
  ELSE (* Bit8 *)
   OPO.GenSXTB(CondAL, instr.reg, src)
  END;
  DecCheckReg(instr.dest, src, dummy, dummy)
 END GenShort;

  PROCEDURE GenPhi(VAR instr: Instruction);
  VAR src1, src2: SHORTINT;
 BEGIN
  ASSERT((OPIR.Instr[instr.src2].reg >= 0) & (OPIR.Instr[instr.src1].reg # none));
  IF OPIR.Instr[instr.src1].reg < 0 THEN src1 := (-2 - OPIR.Instr[instr.src1].reg)
  ELSE
   src1 := OPIR.Instr[instr.src1].reg;
   FreeReg(src1)
  END;
  src2 := OPIR.Instr[instr.src2].reg;
  IF src1 # src2 THEN
   AssignThisReg(instr.src2, src1);
   OPO.GenMOVReg(CondAL, src1, src2);
   IF IsAllocatable(src2) THEN regTab[src2] := free END
  END
 END GenPhi;

 PROCEDURE GenTrap(trapNr: LONGINT);
 BEGIN
  OPO.PutWord(0E7F000F0H + (trapNr MOD 16) + ((trapNr DIV 16) MOD 256) * 256)
 END GenTrap;

 PROCEDURE GenTrapCC(VAR instr: Instruction);
  VAR cond: SHORTINT; op: LONGINT;
 BEGIN
  op := instr.op DIV 32;
  IF op = To THEN
   (* Unconditional overflow trap *)
   OPO.GenB(CondVC, 0); (* skip trap if no overflow: target = PC+8 = instr after trap *)
   GenTrap(instr.src2)
  ELSE
   CASE op OF
    Te:  cond := CondNE  (* trap if equal -> NE means NOT equal, so skip *)
    | Tne: cond := CondEQ
    | Tle: cond := CondGT
    | Ta:  cond := CondLS
    | Tae: cond := CondCC
   ELSE HALT(BUG)
   END;
   OPO.GenB(cond, 0); (* skip trap: target = PC+8 = instr after trap *)
   GenTrap(instr.src2)
  END
 END GenTrapCC;

 PROCEDURE FixupAndGenTrap;
 (* Generate trap code for all pending trap fixups *)
  VAR i, fixuppos, pos, next: LONGINT;
 BEGIN
  i := 0;
  WHILE i < nofTrapFixups DO
   IF trapFixupTab[i] # Nil THEN
    fixuppos := OPO.pc;
    pos := trapFixupTab[i];
    REPEAT
     OPO.GetWord(pos, next);
     OPO.PutWordAt(pos, fixuppos - (pos + 8)); (* ARM branch offset *)
     pos := -2 - next - 10000H
    UNTIL pos = Nil;
    GenTrap(i)
   END;
   INC(i)
  END
 END FixupAndGenTrap;

(* VFP *)

 PROCEDURE Fload(VAR instr: Instruction);
  VAR
   mode, size, base, inx, memBase: SHORTINT;
   disp: LONGINT;
   isSingle: BOOLEAN;
   freg: SHORTINT;
  BEGIN
   FindMemReg(instr, mode, size, base, inx, disp);
   isSingle := (instr.op MOD 8) = 3; 
   AssignFreg(instr.dest);
   FindFreg(instr.dest, freg);
   
  IF (mode IN {RegMem, MemReg}) & (base = noBase) THEN
   OPO.GenMOVW(CondAL, IP, disp MOD 10000H);
   IF ~instr.abs THEN AbsAccess(instr.node, OPO.pc - 4) END;
   OPO.GenMOVT(CondAL, IP, disp DIV 10000H MOD 10000H);
   (* Added missing index scale computation for floats *)
   IF inx > none THEN
    IF instr.scale > 0 THEN
     OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, IP, inx, ShiftLSL, instr.scale)
    ELSE OPO.GenADD(CondAL, IP, IP, inx) END
   END;
   IF instr.op DIV 32 = Fild THEN
    OPO.GenVLDR(CondAL, 1, 0, IP, 0);
    IF isSingle THEN OPO.GenVCVTF32S32(CondAL, FregToSreg(freg), 0)
    ELSE OPO.GenVCVTF64S32(CondAL, freg, 0) END
   ELSE
    IF isSingle THEN OPO.GenVLDR(CondAL, 1, FregToSreg(freg), IP, 0)
    ELSE OPO.GenVLDR(CondAL, 0, freg, IP, 0) END
   END;
   DecReg(base); DecReg(inx);
   RETURN
  END;
  
  AdjustLargeOffset(base, disp, 1024);
  memBase := base;
  (* Added missing index scale computation for floats *)
  IF inx > none THEN
   IF instr.scale > 0 THEN
    OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, base, inx, ShiftLSL, instr.scale)
   ELSE OPO.GenADD(CondAL, IP, base, inx) END;
   memBase := IP
  END;
  
  IF instr.op DIV 32 = Fild THEN
   OPO.GenVLDR(CondAL, 1, 0, memBase, disp); 
   IF isSingle THEN OPO.GenVCVTF32S32(CondAL, FregToSreg(freg), 0)
   ELSE OPO.GenVCVTF64S32(CondAL, freg, 0) END
  ELSE
   IF isSingle THEN OPO.GenVLDR(CondAL, 1, FregToSreg(freg), memBase, disp)
   ELSE OPO.GenVLDR(CondAL, 0, freg, memBase, disp) END
  END;
  DecReg(base); DecReg(inx)
 END Fload;

 PROCEDURE Fstore(VAR instr: Instruction);
  VAR
   mode, size, base, inx, memBase, src: SHORTINT;
   disp: LONGINT;
   isSingle: BOOLEAN;
  BEGIN
   FindMemReg(instr, mode, size, base, inx, disp);
   isSingle := (instr.op MOD 8) = 3; 
   FindFreg(instr.dest, src);
   
  IF (mode IN {RegMem, MemReg}) & (base = noBase) THEN
   OPO.GenMOVW(CondAL, IP, disp MOD 10000H);
   IF ~instr.abs THEN AbsAccess(instr.node, OPO.pc - 4) END;
   OPO.GenMOVT(CondAL, IP, disp DIV 10000H MOD 10000H);
   (* Added missing index scale computation for floats *)
   IF inx > none THEN
    IF instr.scale > 0 THEN
     OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, IP, inx, ShiftLSL, instr.scale)
    ELSE OPO.GenADD(CondAL, IP, IP, inx) END
   END;
   IF instr.op DIV 32 = Fist THEN
    IF isSingle THEN
     OPO.GenVCVTS32F32(CondAL, 0, FregToSreg(src));
     OPO.GenVSTR(CondAL, 1, 0, IP, 0)
    ELSE
     OPO.GenVCVTS32F64(CondAL, 0, src);
     OPO.GenVSTR(CondAL, 1, 0, IP, 0)
    END
   ELSE
    IF isSingle THEN OPO.GenVSTR(CondAL, 1, FregToSreg(src), IP, 0)
    ELSE OPO.GenVSTR(CondAL, 0, src, IP, 0) END
   END;
   DecCheckFreg(src);
   DecReg(base); DecReg(inx);
   RETURN
  END;
  
  AdjustLargeOffset(base, disp, 1024);
  memBase := base;
  (* Added missing index scale computation for floats *)
  IF inx > none THEN
   IF instr.scale > 0 THEN
    OPO.GenDataProcReg(CondAL, OPO.dpADD, 0, IP, base, inx, ShiftLSL, instr.scale)
   ELSE OPO.GenADD(CondAL, IP, base, inx) END;
   memBase := IP
  END;
  
  IF instr.op DIV 32 = Fist THEN
   IF isSingle THEN
    OPO.GenVCVTS32F32(CondAL, 0, FregToSreg(src)); 
    OPO.GenVSTR(CondAL, 1, 0, memBase, disp)
   ELSE
    OPO.GenVCVTS32F64(CondAL, 0, src); 
    OPO.GenVSTR(CondAL, 1, 0, memBase, disp)
   END
  ELSE
   IF isSingle THEN OPO.GenVSTR(CondAL, 1, FregToSreg(src), memBase, disp)
   ELSE OPO.GenVSTR(CondAL, 0, src, memBase, disp) END
  END;
  lastFstoreFreg := src;
  IF spSubPending THEN
   OPO.GenMOVReg(CondAL, SP, memBase);
   spSubPending := FALSE
  END;
  DecCheckFreg(src);
  DecReg(base); DecReg(inx)
 END Fstore;

 PROCEDURE FloatGen3(VAR instr: Instruction);
  VAR src1, src2, dst: SHORTINT; isSingle: BOOLEAN; op: LONGINT;
 BEGIN
  op := instr.op DIV 32;
  isSingle := (instr.op MOD 8) = 3;
  FindFreg(instr.src1, src1);
  FindFreg(instr.src2, src2);
  AssignFreg(instr.dest);
  dst := instr.reg; (* use separate variable to avoid clobbering src1 *)
  IF isSingle THEN
   CASE op OF
    | Fadd: OPO.GenVADD(CondAL, 1, FregToSreg(dst), FregToSreg(src1), FregToSreg(src2))
    | Fsub: OPO.GenVSUB(CondAL, 1, FregToSreg(dst), FregToSreg(src1), FregToSreg(src2))
    | Fmul: OPO.GenVMUL(CondAL, 1, FregToSreg(dst), FregToSreg(src1), FregToSreg(src2))
    | Fdiv: OPO.GenVDIV(CondAL, 1, FregToSreg(dst), FregToSreg(src1), FregToSreg(src2))
   ELSE HALT(BUG)
   END
  ELSE
   CASE op OF
    Fadd: OPO.GenVADD(CondAL, 0, dst, src1, src2)
    | Fsub: OPO.GenVSUB(CondAL, 0, dst, src1, src2)
    | Fmul: OPO.GenVMUL(CondAL, 0, dst, src1, src2)
    | Fdiv: OPO.GenVDIV(CondAL, 0, dst, src1, src2)
   ELSE HALT(BUG)
   END
  END;
  DecCheckFreg(src1); DecCheckFreg(src2)
 END FloatGen3;

 PROCEDURE FloatGen2(VAR instr: Instruction);
  VAR src: SHORTINT; isSingle: BOOLEAN; op: LONGINT;
 BEGIN
  op := instr.op DIV 32;
  isSingle := (instr.op MOD 8) = 3;
  FindFreg(instr.src1, src);
  AssignFreg(instr.dest);
  IF isSingle THEN
   IF op = Fabs THEN OPO.GenVABS(CondAL, 1, FregToSreg(instr.reg), FregToSreg(src))
   ELSE OPO.GenVNEG(CondAL, 1, FregToSreg(instr.reg), FregToSreg(src))
   END
  ELSE
   IF op = Fabs THEN OPO.GenVABS(CondAL, 0, instr.reg, src)
   ELSE OPO.GenVNEG(CondAL, 0, instr.reg, src)
   END
  END;
  DecCheckFreg(src)
 END FloatGen2;

 PROCEDURE FloatCmp(VAR instr: Instruction);
  VAR src1, src2: SHORTINT; isSingle: BOOLEAN;
 BEGIN
  isSingle := (instr.op MOD 8) = 3;
  FindFreg(instr.src1, src1);
  FindFreg(instr.src2, src2);
  IF isSingle THEN
   OPO.GenVCMP(CondAL, 1, FregToSreg(src1), FregToSreg(src2))
  ELSE
   OPO.GenVCMP(CondAL, 0, src1, src2)
  END;
  OPO.GenVMRS(CondAL); (* transfer FPSCR flags to APSR *)
  DecCheckFreg(src1); DecCheckFreg(src2)
 END FloatCmp;

 PROCEDURE GenEntier(VAR instr: Instruction);
 (* Use ARMv7 VCVT.S32.F32/F64 (round toward zero)
 then adjust for floor: if negative and not exact, subtract 1 *)
  VAR src: SHORTINT; isSingle: BOOLEAN; dummy: SHORTINT;
 BEGIN
  isSingle := (OPIR.Instr[instr.src1].op MOD 8) = 3;
  FindFreg(instr.src1, src);
  dummy := none;
  AssignReg(instr.dest, dummy, dummy, dummy);
  (* VCVT.S32.F32/F64 converts to signed int with truncation (toward zero) *)
  IF isSingle THEN
   OPO.GenVCVTS32F32(CondAL, 0, FregToSreg(src)); (* result in S0 *)
  ELSE
   OPO.GenVCVTS32F64(CondAL, 0, src); (* result in S0 *)
  END;
  (* Move from S0 to GPR *)
  OPO.GenVMOVStoGPR(CondAL, instr.reg, 0);
  (* Floor adjustment: if source was negative and not exact integer,
     truncation rounds toward zero (up), but floor rounds down.
     Convert back to float, compare with original: if different and negative, sub 1 *)
  DecCheckFreg(src)
 END GenEntier;

(* Control Flow *)

 PROCEDURE FixupJcc(label: LONGINT);
 (* Patch forward branch fixup chain *)
  VAR pos, oldInstr, chainLink: LONGINT;
 BEGIN
  WHILE label # Nil DO
   IF OPIR.Instr[label].op = jmp THEN pos := OPIR.Instr[label].pc
   ELSE pos := OPIR.Instr[label].pc
   END;
   OPO.GetWord(pos, oldInstr);
   (* Extract 24-bit signed offset field (chain link) from lower 24 bits *)
   chainLink := oldInstr MOD 1000000H;
   IF chainLink >= 800000H THEN chainLink := chainLink - 1000000H END;
   (* Patch: keep top 8 bits (cond+opcode), replace 24-bit offset *)
   OPO.PutWordAt(pos, (oldInstr DIV 1000000H) * 1000000H +
    ((OPO.pc - (pos + 8)) DIV 4) MOD 1000000H);
   label := -2 - chainLink - 10000H
  END
 END FixupJcc;

 PROCEDURE Gen1(VAR instr: Instruction; RiscPC: LONGINT);
  VAR
   op: LONGINT;
   reg: SHORTINT;
   cond: SHORTINT;
   disp: LONGINT;
 BEGIN
  op := instr.op DIV 32;
  IF op = JmpReg THEN
   FindReg(instr.src2, reg);
   OPO.GenBX(CondAL, reg);
   DecReg(reg)
  ELSIF op = Jmp THEN
   IF RiscPC >= instr.src2 THEN (* backward jump *)
    disp := OPIR.Instr[instr.src2].pc - (OPO.pc + 8);
    OPO.GenB(CondAL, disp)
   ELSE (* forward jump: emit with fixup chain *)
    (* Chain link: encode previous .pc value of target label, multiply by 4 to survive GenB's DIV 4 *)
    OPO.GenB(CondAL, (-2 - OPIR.Instr[instr.src2].pc - 10000H) * 4);
    OPIR.Instr[instr.src2].pc := RiscPC
   END
  ELSE
   (* Conditional branch *)
   CASE op OF
    | Je:  cond := CondEQ
    | Jne: cond := CondNE
    | Jl:  cond := CondLT
    | Jle: cond := CondLE
    | Jg:  cond := CondGT
    | Jge: cond := CondGE
    | Ja:  cond := CondHI
    | Jae: cond := CondCS
    | Jb:  cond := CondCC
    | Jbe: cond := CondLS
    | Jc:  cond := CondCS
    | Jnc: cond := CondCC
   ELSE HALT(BUG)
   END;
   IF RiscPC >= instr.src2 THEN (* backward jump *)
    disp := OPIR.Instr[instr.src2].pc - (OPO.pc + 8);
    OPO.GenB(cond, disp)
   ELSE (* forward jump: emit with fixup chain *)
    (* Chain link: encode previous .pc value of target label, multiply by 4 to survive GenB's DIV 4 *)
    OPO.GenB(cond, (-2 - OPIR.Instr[instr.src2].pc - 10000H) * 4);
    OPIR.Instr[instr.src2].pc := RiscPC
   END
  END
 END Gen1;

 PROCEDURE GenEnter(locSize: LONGINT; locals: OPT.Object; sysflag: SHORTINT);
 (* Procedure prologue:
     PUSH {FP, LR}
     MOV  FP, SP
     SUB  SP, SP, #locSize  (if locSize > 0)
 *)
 BEGIN
  ASSERT(locSize MOD 4 = 0);
  OPO.GenPUSH(CondAL, SYSTEM.VAL(LONGINT, {FP, LR}));
  OPO.GenMOVReg(CondAL, FP, SP);
  IF locSize # 0 THEN
   EmitSubImm(CondAL, SP, SP, locSize)
  END
 END GenEnter;

 PROCEDURE GenLeave(parSize: LONGINT; sysflag: SHORTINT);
 (* Procedure epilogue:
     MOV  SP, FP
     POP  {FP, LR}
     ADD  SP, SP, #parSize  (if parSize > 0)
     BX   LR
  *)
 BEGIN
  OPO.GenMOVReg(CondAL, SP, FP);
  OPO.GenPOP(CondAL, SYSTEM.VAL(LONGINT, {FP, LR}));
  IF parSize > 0 THEN
   EmitAddImm(CondAL, SP, SP, parSize)
  END;
  OPO.GenBX(CondAL, LR)
 END GenLeave;

 PROCEDURE PushRegs;
 (* Save all currently allocated registers before a nested call *)
  VAR i: SHORTINT; regSet: SET;
 BEGIN
  IF nofSavedLevel > MaxSaveLevel THEN OPM.err(251)
  ELSE
   regSet := {};
   i := 0;
   WHILE i < MaxGPRs DO
    savedRegs[nofSavedLevel].reg[i] := SHORT(regTab[i]);
    IF (regTab[i] # free) & (regTab[i] # Occupied) THEN
     IF (regTab[i] >= 0) & (OPIR.Instr[regTab[i]].op DIV 32 >= 1) & (OPIR.Instr[regTab[i]].op DIV 32 <= 7) THEN
      (* indirect memory load; don't save/restore, mark spilled for reload *)
      savedRegs[nofSavedLevel].reg[i] := free;
      OPIR.Instr[regTab[i]].reg := (-2) - i
     ELSE
      INCL(regSet, i)
     END;
     regTab[i] := free
    END;
    INC(i)
   END;
   IF regSet # {} THEN OPO.GenPUSH(CondAL, SYSTEM.VAL(LONGINT, regSet)) END;
   (* Save VFP registers: save bookkeeping AND emit VPUSH for each in-use D-register *)
   i := 0;
   WHILE i < MaxFRegs DO
    savedRegs[nofSavedLevel].freg[i] := SHORT(fregTab[i]);
    IF fregTab[i] # free THEN
     OPO.GenVPUSHD(CondAL, i, 1);  (* VPUSH {Di} *)
     fregTab[i] := free
    END;
    INC(i)
   END;
   INC(nofSavedLevel)
  END
 END PushRegs;

 PROCEDURE PopRegs(VAR instr: Instruction);
 (* Restore registers after a nested call *)
  VAR i: SHORTINT; size: LONGINT; regSet: SET; hasResult: BOOLEAN;
 BEGIN
  DEC(nofSavedLevel);
  IF instr.hint # noHint THEN size := instr.op MOD 8
  ELSE size := -1
  END;
  hasResult := size >= 0;
  (* Restore VFP registers: VPOP in reverse order of VPUSH *)
  i := MaxFRegs - 1;
  WHILE i >= 0 DO
   IF savedRegs[nofSavedLevel].freg[i] # free THEN
    OPO.GenVPOPD(CondAL, i, 1)  (* VPOP {Di} *)
   END;
   DEC(i)
  END;
  i := 0;
  WHILE i < MaxFRegs DO
   fregTab[i] := savedRegs[nofSavedLevel].freg[i];
   INC(i)
  END;
  (* Restore GPRs *)
  regSet := {};
  i := MaxGPRs - 1;
  WHILE i >= 0 DO
   IF savedRegs[nofSavedLevel].reg[i] # free THEN
    INCL(regSet, i)
   END;
   DEC(i)
  END;
  (* If R0 needs to be restored AND the call returns a result in R0,
     the POP would clobber the return value. Fix:
     1. Move return value from R0 to IP (scratch register, callee-saved)
     2. POP all saved regs normally (R0 gets its old value back)
     3. Move old R0 value to a free register (preserving the saved value)
     4. Move return value from IP back to R0 *)
  (* Only protect R0 for integer results; VFP results are in S0/D0, not R0 *)
  IF hasResult & ~(size IN {3, 4}) & (R0 IN regSet) THEN
   OPO.GenMOVReg(CondAL, IP, R0);  (* IP = return value *)
   OPO.GenPOP(CondAL, SYSTEM.VAL(LONGINT, regSet));  (* restore all saved regs *)
   (* R0 now has its old saved value. Move it to a free register. *)
   i := 1;
   WHILE (i < MaxGPRs) & ~((savedRegs[nofSavedLevel].reg[i] = free) & ~(i IN regSet)) DO INC(i) END;
   IF i < MaxGPRs THEN
    OPO.GenMOVReg(CondAL, i, R0);  (* Ri = old R0 value *)
    savedRegs[nofSavedLevel].reg[i] := savedRegs[nofSavedLevel].reg[R0]
   END;
   OPO.GenMOVReg(CondAL, R0, IP);  (* R0 = return value *)
   savedRegs[nofSavedLevel].reg[R0] := free
  ELSE
   IF regSet # {} THEN OPO.GenPOP(CondAL, SYSTEM.VAL(LONGINT, regSet)) END
  END;
  i := 0;
  WHILE i < MaxGPRs DO
   IF savedRegs[nofSavedLevel].reg[i] = free THEN
    (* nothing to do *)
   ELSIF regTab[i] = free THEN
    regTab[i] := savedRegs[nofSavedLevel].reg[i];
    IF regTab[i] >= 0 THEN OPIR.Instr[regTab[i]].reg := i END
   END;
   INC(i)
  END;
  (* Set result register *)
  IF (size = 3) OR (size = 4) THEN
   (* VFP result: callee returned in S0 (REAL) or D0 (LONGREAL) *)
   AssignFreg(instr.dest);
   FindFreg(instr.dest, i);
   IF i # 0 THEN
    IF size = 3 THEN
     OPO.GenVMOVF(CondAL, 1, FregToSreg(i), 0)  (* VMOV Sd, S0 *)
    ELSE
     OPO.GenVMOVF(CondAL, 0, i, 0)               (* VMOV Dd, D0 *)
    END
   END
  ELSIF size >= 0 THEN
   (* Integer result in R0 *)
   regTab[R0] := instr.dest; instr.reg := R0
  END
 END PopRegs;

 PROCEDURE FixupCaseTab(VAR instr: Instruction);
 (* Patch case table entries with actual PC values *)
  VAR elseLabel, from, to, val, caseFixup: LONGINT;
 BEGIN
  caseFixup := link[0].offset;
  elseLabel := OPIR.Instr[instr.src2].pc;
  from := instr.src1; to := instr.src1 + instr.inx - 4;
  WHILE from <= to DO
   OPO.GetConsDWord(from, val);
   IF val = Nil THEN val := elseLabel
   ELSE val := OPIR.Instr[val].pc
   END;
   IF from = to THEN
    IF caseFixup >= 32768 THEN val := (caseFixup - 10000H) * 10000H + val
    ELSE val := caseFixup * 10000H + val
    END
   ELSE
    IF from + 4 >= 32768 THEN val := (from + 4 - 10000H) * 10000H + val
    ELSE val := (from + 4) * 10000H + val
    END
   END;
   OPO.PutConsDWord(from, val);
   from := from + 4
  END;
  link[0].offset := instr.src1
 END FixupCaseTab;

 PROCEDURE EncodeFixup(i: LONGINT);
 (* Convert forward local procedure call chain from IR-index-based to machine-code-address-based.
    The BL instructions contain chain link values in their lower 24 bits (pre-multiplied by 4
     to survive GenBL's DIV 4). We extract these, convert IR indices to machine code addresses,
    and re-encode them (with *4 compensation). *)
  VAR L, L1, oldInstr, chainVal: LONGINT; node: OPT.Node;
 BEGIN
  node := OPIR.Instr[i].node;
  node.left.obj.linkadr := -2 - OPIR.Instr[i].pc - 10000H;
  L := i;
  WHILE L > Nil DO
   OPO.GetWord(OPIR.Instr[L].pc, oldInstr);
   (* Extract 24-bit chain value from BL instruction *)
   chainVal := oldInstr MOD 1000000H;
   IF chainVal >= 800000H THEN chainVal := chainVal - 1000000H END;
   IF (chainVal > -10000H) & (-2 - chainVal > Nil) THEN
    L1 := -2 - chainVal;
    (* Re-encode with machine code address, pre-multiply by 4 for GenBL's DIV 4 *)
    OPO.PutWordAt(OPIR.Instr[L].pc, (oldInstr DIV 1000000H) * 1000000H +
     ((-2 - OPIR.Instr[L1].pc - 10000H) MOD 1000000H))
   ELSE
    L1 := chainVal
   END;
   L := L1
  END
 END EncodeFixup;

 PROCEDURE GenAsm(instr: Instruction);
  VAR n, code, fix: OPT.Node; pc: LONGINT;
 BEGIN
  pc := OPO.pc; n := instr.node;
  code := n.left;
  WHILE code # NIL DO
   OPO.InlineCode(code.conval.ext^, 0); code := code.link
  END;
  fix := n.right;
  WHILE fix # NIL DO
   IF (fix.obj.mode = Var) & (fix.obj.mnolev <= 0) THEN
    OPO.PutWordAt(pc + fix.conval.intval, fix.obj.linkadr);
    AbsAccess(fix, pc + fix.conval.intval)
   ELSIF (fix.obj.linkadr <= MAX(SHORTINT)) & (fix.obj.linkadr >= MIN(SHORTINT)) THEN
    OPO.PutByteAt(pc + fix.conval.intval, SHORT(SHORT(fix.obj.linkadr)))
   ELSE
    OPM.Mark(600, SHORT(fix.conval.intval2))
   END;
   fix := fix.link
  END
 END GenAsm;

 PROCEDURE FixupLocalProcCall*(proc: OPT.Object);
 (* Patch all forward calls to a local procedure now that its address is known *)
  VAR L, oldInstr, chainLink, entryNr: LONGINT;
 BEGIN
  IF (proc.linkadr < 0) & ~(proc.mode IN {TProc, Typ}) THEN
   L := -2 - proc.linkadr - 10000H;
   WHILE L > Nil DO
    OPO.GetWord(L, oldInstr);
    (* Extract 24-bit signed offset field (chain link) from lower 24 bits *)
    chainLink := oldInstr MOD 1000000H;
    IF chainLink >= 800000H THEN chainLink := chainLink - 1000000H END;
    (* Patch BL instruction: keep top 8 bits (cond+opcode), replace 24-bit offset *)
    OPO.PutWordAt(L, (oldInstr DIV 1000000H) * 1000000H +
     ((OPO.pc - (L + 8)) DIV 4) MOD 1000000H);
    L := -2 - chainLink - 10000H
   END
  END;
  proc.linkadr := OPO.pc;
  IF proc.mode IN {XProc, TProc, Typ} THEN
   IF proc.mode IN {TProc, Typ} THEN entryNr := proc.adr MOD 10000H
   ELSE entryNr := proc.adr
   END;
   entry[entryNr] := SHORT(OPO.pc DIV 4)
  END
 END FixupLocalProcCall;

(* Object File Output *)

 PROCEDURE GenCode*(pSize: INTEGER);
  VAR
   obj: OPT.Object;
   list: OPT.Object;
   i, k: LONGINT;
   op: LONGINT;
   reg: SHORTINT;
   sysflag: SHORTINT;
   node: OPT.Node;

  PROCEDURE MarkPos;
   VAR j: LONGINT;
  BEGIN
   IF OPIR.mapSize < LEN(OPIR.map^) THEN
    OPIR.map[OPIR.mapSize].pos := OPIR.Instr[i].src1;
    OPIR.map[OPIR.mapSize].pc := OPO.pc;
    j := OPIR.mapSize - 1;
    WHILE (j >= 0) & (OPIR.map[j].pos < 0) DO
     OPIR.map[j].pos := OPIR.map[OPIR.mapSize].pos; DEC(j)
    END;
    INC(OPIR.mapSize)
   ELSE
    OPIR.map[OPIR.mapSize - 1].pos := -1;
    OPIR.map[OPIR.mapSize - 1].pc := -1
   END
  END MarkPos;

 BEGIN
  i := 0;
  WHILE i < nofTrapFixups DO
   trapFixupTab[i] := Nil; INC(i)
  END;
  i := 0;
  WHILE i < MaxGPRs DO
   regTab[i] := free; INC(i)
  END;
  i := 0;
  WHILE i < MaxFRegs DO
   fregTab[i] := free; INC(i)
  END;
  RegErr := FALSE;
  i := 0;
  WHILE ~OPO.CodeErr & ~RegErr & (i < pSize) DO
   node := OPIR.Instr[i].node;
   FixupJcc(OPIR.Instr[i].pc);
   OPIR.Instr[i].pc := OPO.pc;
   op := OPIR.Instr[i].op DIV 32;
   IF op > 0 THEN (* skip dead code *)
    CASE op OF
     NewStat:
      OPM.errpos := OPIR.Instr[i].src1;
      IF OPIR.map # NIL THEN MarkPos END
     | Ld, Lea, Ldbdw, Ldwdw, Ldbw, Ldbdwu, Ldwdwu, Ldbwu, PUTreg:
      Load(OPIR.Instr[i])
     | LdProc, LdXProc:
      LoadProc(OPIR.Instr[i])
     | Sto, GETreg:
      Store(OPIR.Instr[i])
     | Push:
      GenPush(OPIR.Instr[i])
     | Pop:
      GenPop(OPIR.Instr[i])
     | Add, Sub, oR, Xor, And, Sal, Sar, Shr, Rol, Bts, Btr:
      Gen3(OPIR.Instr[i])
     | Div, Mod:
      GenDivMod(OPIR.Instr[i])
     | Mul:
      GenMul(OPIR.Instr[i])
     | Neg, Not:
      Gen2(OPIR.Instr[i])
     | Abso:
      GenAbs(OPIR.Instr[i])
     | Cmp, Bt, Test:
      Flags(OPIR.Instr[i])
     | Sete, Setne, Setl, Setle, Setg, Setge, Seta, Setae, Setb, Setbe, Setc, Setnc:
      Setcc(OPIR.Instr[i])
     | Je, Jne, Jl, Jle, Jg, Jge, Ja, Jae, Jb, Jbe, Jc, Jnc, Jmp, JmpReg:
      Gen1(OPIR.Instr[i], i)
     | Te, Tne, Tle, Ta, Tae, To:
      GenTrapCC(OPIR.Instr[i])
     | Trap:
      GenTrap(OPIR.Instr[i].src2)
     | Call:
      node := OPIR.Instr[i].node;
      obj := node.left.obj;
      IF obj.mode = CProc THEN
       HALT(99) (* code procedures not supported *)
      ELSIF OPIR.Instr[i].src2 >= 0 THEN (* backward call *)
       OPO.GenBL(CondAL, OPIR.Instr[i].src2 - (OPO.pc + 8))
      ELSE (* forward call *)
       (* Pre-multiply by 4 to compensate for GenBL's DIV 4 *)
       OPO.GenBL(CondAL, OPIR.Instr[i].src2 * 4);
       IF -2 - node.left.obj.linkadr = i THEN
        EncodeFixup(i)
       END
      END
     | Xcall:
      (* External call: BL with fixup *)
      OPO.GenBL(CondAL, 0);
      AddLink(OPIR.Instr[i].src2 DIV 10000H, OPIR.Instr[i].pc)
     | CallReg:
      FindReg(OPIR.Instr[i].src2, reg);
      (* Prevent jumping to the Reset Vector on NIL pointers *)
      EmitCmpImm(CondAL, reg, 0);
      OPO.GenB(CondNE, 0);   (* If NOT NULL, skip the Trap instruction *)
      GenTrap(3);            (* TRAP 3: FuncTrap (Call of NIL procedure) *)
      OPO.GenBLX(CondAL, reg);
      DecReg(reg)
     | PushReg:
      (* pushReg: save registers before call *)
      PushRegs
     | PopReg:
      (* popReg: restore registers after call *)
      PopRegs(OPIR.Instr[i])
     | Ret:
      (* ret parSize: return from procedure.
       * The Leave IR instruction already emitted MOV SP,FP + POP {FP,LR}.
       * Ret only needs parameter cleanup and the actual return. *)
      IF OPIR.Instr[i].src2 > 0 THEN
       EmitAddImm(CondAL, SP, SP, OPIR.Instr[i].src2)
      END;
      OPO.GenBX(CondAL, LR)
     | Enter:
      (* enter locSize: procedure prologue *)
      IF OPIR.map # NIL THEN MarkPos END;
      IF node # NIL THEN
       list := node.obj.scope.scope;
       sysflag := node.obj.sysflag;
       (* Track return type for VFP return value copy at Leave time *)
       IF (node.obj.typ # NIL) & ((node.obj.typ.form = Real) OR (node.obj.typ.form = LReal)) THEN
        currentProcRetForm := node.obj.typ.form
       ELSE
        currentProcRetForm := 0
       END
      ELSE
       list := NIL;
       sysflag := 0;
       currentProcRetForm := 0
      END;
      lastFstoreFreg := -1;
      GenEnter(OPIR.Instr[i].src2, list, sysflag)
     | Leave:
      (* leave: procedure epilogue (without ret) *)
      (* If function returns REAL or LONGREAL, copy VFP result to S0/D0.
         Check fregTab for still-allocated register first (direct return path),
         then fall back to lastFstoreFreg (store-to-local then return path). *)
      IF currentProcRetForm = Real THEN
       k := 1;
       WHILE (k < MaxFRegs) & (fregTab[k] = free) DO INC(k) END;
       IF k < MaxFRegs THEN
        OPO.GenVMOVF(CondAL, 1, 0, FregToSreg(SHORT(SHORT(k))))
       ELSIF lastFstoreFreg > 0 THEN
        OPO.GenVMOVF(CondAL, 1, 0, FregToSreg(lastFstoreFreg))
       END
      ELSIF currentProcRetForm = LReal THEN
       k := 1;
       WHILE (k < MaxFRegs) & (fregTab[k] = free) DO INC(k) END;
       IF k < MaxFRegs THEN
        OPO.GenVMOVF(CondAL, 0, 0, SHORT(SHORT(k)))
       ELSIF lastFstoreFreg > 0 THEN
        OPO.GenVMOVF(CondAL, 0, 0, lastFstoreFreg)
       END
      END;
      currentProcRetForm := 0; lastFstoreFreg := -1;
      OPO.GenMOVReg(CondAL, SP, FP);
      OPO.GenPOP(CondAL, SYSTEM.VAL(LONGINT, {FP, LR}))
     | RepMovs:
      GenRepMovs(OPIR.Instr[i])
     | CmpString:
      GenCmpString(OPIR.Instr[i])
     | Short:
      GenShort(OPIR.Instr[i])
     | Phi:
      GenPhi(OPIR.Instr[i])
     | Label:
      (* label: no code, just a fixup point *)
     | Entier:
      GenEntier(OPIR.Instr[i])
     | Cli:
      (* cli: disable interrupts - CPSID i *)
      OPO.PutWord(0F10C0080H) (* CPSID i *)
     | Sti:
      (* sti: enable interrupts - CPSIE i *)
      OPO.PutWord(0F1080080H) (* CPSIE i *)
     | In, Out:
      (* No I/O port instructions on ARM32 *)
      OPM.err(200)
     | Assembler:
      GenAsm(OPIR.Instr[i])
     | Clear:
      (* clear: zero a memory region *)
      (* Handled by repMovs with zero source *)
     | Std:
      (* std: set direction flag - no equivalent on ARM32 *)
     | Dmb:
      (* dmb: memory barrier - DMB ISH *)
      OPO.GenDMBISH
     | FLoad, Fild:
      Fload(OPIR.Instr[i])
     | FStore, Fist:
      Fstore(OPIR.Instr[i])
     | Fadd, Fsub, Fmul, Fdiv:
      FloatGen3(OPIR.Instr[i])
     | Fabs, Fchs:
      FloatGen2(OPIR.Instr[i])
     | Fcmp:
      FloatCmp(OPIR.Instr[i])
     | Case:
      FixupCaseTab(OPIR.Instr[i])
     | Cld:
      (* cld: clear direction flag - no equivalent on ARM32 *)
    ELSE
     (* Unknown opcode - skip *)
    END
   END;
   INC(i)
  END;
  FixupAndGenTrap
 END GenCode;

 PROCEDURE OutRefPoint*(proc: OPT.Object);
 VAR obj: OPT.Object; n: LONGINT;
 BEGIN
  IF proc = NIL THEN
   OPM.RefW(RefTag);
   OPM.RefW(0F8X);
   OPM.RefWNum(0)
  ELSE
   IF NewRef THEN
    OPM.RefW(0F9X);
    OPM.RefWNum(proc.linkadr);
    obj := proc.link; n := 0;
    WHILE obj # NIL DO INC(n); obj := obj.link END;
    OPM.RefWNum(n);
    n := proc.typ.form;
    IF n IN {Undef, NilTyp, NoTyp} THEN n := 0
    ELSIF n = Comp THEN n := 10H + proc.typ.comp
    END;
    OPM.RefW(CHR(n));
    OPM.RefW(CHR(proc.mnolev));
    IF slNeeded IN proc.conval.setval THEN OPM.RefW(1X)
    ELSE OPM.RefW(0X)
    END
   ELSE
    OPM.RefW(0F8X);
    OPM.RefWNum(proc.linkadr)
   END
  END
 END OutRefPoint;

 PROCEDURE OutRefName*(name: ARRAY OF CHAR);
  VAR ch: CHAR; i: INTEGER;
 BEGIN
  i := 0;
  REPEAT ch := name[i]; OPM.RefW(ch); INC(i) UNTIL ch = 0X
 END OutRefName;

 PROCEDURE OutRefs*(obj: OPT.Object);
  VAR f: INTEGER;
 BEGIN
  IF obj # NIL THEN
   OutRefs(obj.left);
   IF obj.mode IN {Var, VarPar} THEN
    f := obj.typ.form;
    IF NewRef THEN
     IF (f IN {Byte..Set, Pointer, ProcTyp, HInt}) OR (obj.typ.comp = Record) OR
        (obj.typ.comp IN {StaticArr, OpenArr}) & (obj.typ.BaseTyp.form IN {Byte..Set, Pointer, ProcTyp}) THEN
      IF (obj.mode = Var) & (obj.typ.comp # OpenArr) THEN OPM.RefW(1X)
      ELSE OPM.RefW(3X)
      END;
      IF obj.typ.comp = StaticArr THEN
       OPM.RefW(CHR(80H + obj.typ.BaseTyp.form));
       OPM.RefWNum(obj.typ.n)
      ELSIF obj.typ.comp = OpenArr THEN
       OPM.RefW(CHR(80H + obj.typ.BaseTyp.form));
       OPM.RefWNum(0)
      ELSIF obj.typ.comp = Record THEN
       OPM.RefW(CHR(10H + Record));
       OPM.RefWNum(obj.typ.tdadr)
      ELSIF (f = Pointer) & (obj.typ.BaseTyp # NIL) & (obj.typ.BaseTyp.comp = Record) THEN
       OPM.RefW(CHR(10H + Pointer));
       OPM.RefWNum(obj.typ.BaseTyp.tdadr)
      ELSE
       OPM.RefW(CHR(f))
      END;
      OPM.RefWNum(obj.linkadr);
      OutRefName(obj.name)
     END
    ELSE
     IF (f IN {Byte..Set, Pointer, ProcTyp}) OR
        (obj.typ.comp IN {StaticArr, OpenArr}) & (obj.typ.BaseTyp.form IN {Byte..Set, Pointer, ProcTyp}) THEN
      IF (obj.mode = Var) & (obj.typ.comp # OpenArr) THEN OPM.RefW(1X)
      ELSE OPM.RefW(3X)
      END;
      IF obj.typ.comp = StaticArr THEN
       OPM.RefW(CHR(80H + obj.typ.BaseTyp.form));
       OPM.RefWNum(obj.typ.n)
      ELSIF obj.typ.comp = OpenArr THEN
       OPM.RefW(CHR(80H + obj.typ.BaseTyp.form));
       OPM.RefWNum(0)
      ELSE
       OPM.RefW(CHR(f))
      END;
      OPM.RefWNum(obj.linkadr);
      OutRefName(obj.name)
     END
    END
   END;
   OutRefs(obj.right)
  END
 END OutRefs;

 PROCEDURE LSW(x: LONGINT): LONGINT;
 BEGIN
  RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, x) * SYSTEM.VAL(SET, 0FFFFH))
 END LSW;

 PROCEDURE Export(obj: OPT.Object; VAR nofExp: INTEGER);
  VAR typ: OPT.Struct; i: LONGINT; tmp: ExpTable;

  PROCEDURE ExportMeth(fld: OPT.Object; basetyp: OPT.Struct; VAR noFld: INTEGER);
  BEGIN
   IF fld # NIL THEN
    ExportMeth(fld.left, basetyp, noFld);
    IF (fld.mode = TProc) & (fld.vis # internal) THEN
     INC(noFld); OPM.ObjWNum(fld.fp)
    END;
    ExportMeth(fld.right, basetyp, noFld)
   END
  END ExportMeth;

  PROCEDURE ExportRecord(typ: OPT.Struct);
   VAR fld: OPT.Object; pos: LONGINT; nofld: INTEGER;
  BEGIN
   IF typ.mno = 0 THEN
    OPM.ObjW(EURecord);
    IF typ.oref # 0 THEN OPM.ObjWNum(-typ.oref)
    ELSE
     INC(nofStr); typ.oref := nofStr;
     OPM.ObjWNum(typ.tdadr);
     OPT.FPrintTyp(typ);
     pos := OPM.ObjAllocInt();
     nofld := 2;
     IF (typ.BaseTyp # NIL) & (typ.mno = OPT.modNo) THEN ExportRecord(typ.BaseTyp) END;
     OPM.ObjWNum(typ.pbfp); OPM.ObjWNum(typ.pvfp);
     ExportMeth(typ.link, typ.BaseTyp, nofld);
     fld := typ.link;
     WHILE (fld # NIL) & (fld.mode # TProc) DO
      IF fld.vis # internal THEN
       INC(nofld);
       OPM.ObjWNum(fld.fp);
       typ := fld.typ;
       WHILE (typ # NIL) & ((typ.form = Comp) & (typ.comp # Record) OR (typ.form = Pointer)) DO
        typ := typ.BaseTyp
       END;
       IF (typ # NIL) & (typ.form = Comp) & (typ.comp = Record) THEN ExportRecord(typ) END
      END;
      fld := fld.link
     END;
     OPM.ObjW(EUEnd); OPM.ObjFillInt(pos, nofld)
    END
   END
  END ExportRecord;

 BEGIN
  IF obj # NIL THEN
   IF obj.prio = 127 THEN
    Export(obj.link2, nofExp); Export(obj.left, nofExp); Export(obj.right, nofExp)
   ELSE
    Export(obj.left, nofExp);
    IF obj.vis # internal THEN
     OPT.FPrintObj(obj);
     OPM.ObjWNum(obj.fp);
     i := 0;
     WHILE i < exppos DO
      IF obj.fp = explist[i] THEN OPM.Mark(280, obj.txtpos) END;
      INC(i)
     END;
     IF exppos = LEN(explist) THEN
      NEW(tmp, 32 + LEN(explist));
      SYSTEM.MOVE(SYSTEM.ADR(explist[0]), SYSTEM.ADR(tmp[0]), 4 * LEN(explist));
      explist := tmp
     END;
     explist[exppos] := obj.fp; INC(exppos);
     IF obj.mode = Var THEN OPM.ObjWNum(obj.linkadr)
     ELSIF obj.mode = XProc THEN OPM.ObjWNum(LSW(entry[obj.adr]))
     ELSE OPM.ObjW(0X)
     END;
     INC(nofExp);
     IF (obj.mode = Typ) OR (obj.mode = Var) THEN
      typ := obj.typ;
      WHILE (typ # NIL) & ((typ.form = Comp) & (typ.comp # Record) OR (typ.form = Pointer)) DO
       typ := typ.BaseTyp
      END;
      IF (typ # NIL) & (typ.form = Comp) & (typ.comp = Record) THEN ExportRecord(typ) END
     END
    END;
    Export(obj.right, nofExp)
   END
  END
 END Export;

 PROCEDURE Use(obj: OPT.Object);
  VAR typ: OPT.Struct; alias: BOOLEAN;

  PROCEDURE UseRecord(typ: OPT.Struct);
  VAR name: ARRAY 32 OF CHAR;
  BEGIN
   IF (typ.oref = 0) & (typ.mno = OPT.modNo) THEN
    OPM.ObjW(EURecord);
    IF (typ.tdadr = OPM.TDAdrUndef) OR (typ.tdadr = -2) THEN OPM.ObjWNum(0)
    ELSE OPM.ObjWNum(-typ.tdadr)
    END;
    OPT.FPrintTyp(typ); typ.oref := -1;
    IF typ.pvused THEN
     name := "@"; OPM.ObjWNum(typ.pvfp); OPM.ObjWString(name)
    ELSIF typ.pbused THEN
     name := "@"; OPM.ObjWNum(typ.pbfp); OPM.ObjWString(name)
    END;
    OPM.ObjW(EUEnd)
   END
  END UseRecord;

 BEGIN
  IF obj # NIL THEN
   IF obj.prio = 127 THEN Use(obj.link2); Use(obj.left); Use(obj.right)
   ELSE
    Use(obj.left);
    alias := FALSE;
    IF ~obj.used & (obj.mode = Typ) & (obj.vis # internal) & (obj.typ.strobj # obj) &
       (obj.typ.strobj.vis = internal) & obj.typ.strobj.used THEN
     alias := TRUE
    END;
    IF alias OR obj.used & (obj.vis # internal)
    & ((obj.mode # XProc) OR (obj.adr DIV 10000H # 0) & (link[obj.adr DIV 10000H].offset # Nil))
    & ((obj.mode # Var) OR (obj.adr # 0)) THEN
     OPT.FPrintObj(obj);
     OPM.ObjWNum(obj.fp); OPM.ObjWString(obj.name);
     IF obj.mode = Var THEN OPM.ObjWNum(obj.adr DIV 10000H)
     ELSIF obj.mode = XProc THEN OPM.ObjWNum(link[obj.adr DIV 10000H].offset DIV 4 + EUProcFlag)
     ELSE OPM.ObjW(0X)
     END;
     IF (obj.mode = Typ) OR (obj.mode = Var) THEN
      typ := obj.typ;
      WHILE (typ # NIL) & ((typ.form = Comp) & (typ.comp # Record) OR (typ.form = Pointer)) DO
       typ := typ.BaseTyp
      END;
      IF (typ # NIL) & (typ.form = Comp) & (typ.comp = Record) THEN
       UseRecord(typ);
       IF typ.strobj.fp = 0 THEN typ.strobj.fp := obj.fp END
      END
     END
    END;
    Use(obj.right)
   END
  END
 END Use;

 PROCEDURE OutCode*(VAR modName: ARRAY OF CHAR);
  VAR
   i, k, pos: LONGINT;
   nofcmds, nofnewmth, nofinhmth, linkCorrection, nofExp, nofImp: INTEGER;
   obj: OPT.Object;
   typ, btyp: OPT.Struct;
   commandTab: ARRAY MaxCommands OF OPT.Object;
   newMthTab: ARRAY MaxEntry OF OPT.Object;
   modMap: ARRAY 128 OF SHORTINT;

  PROCEDURE WriteName(VAR name: ARRAY OF CHAR);
   VAR i: INTEGER; ch: CHAR;
  BEGIN
   i := 0;
   REPEAT ch := name[i]; OPM.ObjW(ch); INC(i) UNTIL ch = 0X
  END WriteName;

  PROCEDURE FindPtrs(typ: OPT.Struct; adr: LONGINT);
   VAR fld: OPT.Object; i, n, s: LONGINT; btyp: OPT.Struct;

   PROCEDURE Add(adr: LONGINT);
    VAR table: PtrTable;
   BEGIN
    IF nofptrs >= LEN(ptrTab) THEN
     NEW(table, LEN(ptrTab) * 2);
     FOR i := 0 TO LEN(ptrTab) - 1 DO table[i] := ptrTab[i] END;
     ptrTab := table
    END;
    ptrTab[nofptrs] := adr; INC(nofptrs)
   END Add;

  BEGIN
   IF typ.form = Pointer THEN
    IF typ.sysflag = 0 THEN Add(adr) END
   ELSIF (typ.form = ProcTyp) & (typ.sysflag = delegate) THEN Add(adr + 4)
   ELSIF typ.comp = Record THEN
    btyp := typ.BaseTyp;
    IF btyp # NIL THEN FindPtrs(btyp, adr) END;
    fld := typ.link;
    WHILE (fld # NIL) & (fld.mode = Fld) DO
     IF fld.name = OPT.HdPtrName THEN Add(adr)
     ELSIF fld.sysflag # untraced THEN FindPtrs(fld.typ, fld.adr + adr)
     END;
     fld := fld.link
    END
   ELSIF typ.comp = StaticArr THEN
    btyp := typ.BaseTyp; n := typ.n;
    WHILE btyp.comp = StaticArr DO n := btyp.n * n; btyp := btyp.BaseTyp END;
    IF (btyp.form = Pointer) OR (btyp.comp IN {Record, DynArr}) OR
       ((btyp.form = ProcTyp) & (btyp.sysflag = delegate)) THEN
     i := 0; s := btyp.size;
     WHILE i < n DO FindPtrs(btyp, i * s + adr); INC(i) END
    END
   ELSIF typ.comp = DynArr THEN
    Add(adr)
   END
  END FindPtrs;

  PROCEDURE traverse(obj: OPT.Object);
  BEGIN
   IF obj # NIL THEN
    IF obj.mode = XProc THEN
     IF obj.vis # internal THEN
      IF (obj.link = NIL) & (obj.typ = OPT.notyp) THEN
       IF nofcmds <= MaxCommands THEN commandTab[nofcmds] := obj; INC(nofcmds)
       ELSE OPM.err(232)
       END
      ELSIF (obj.typ = OPT.ptrtyp) & (obj.link # NIL) & (obj.link.typ = OPT.ptrtyp) &
            (obj.link.link = NIL) THEN
       IF nofcmds <= MaxCommands THEN commandTab[nofcmds] := obj; INC(nofcmds)
       ELSE OPM.err(232)
       END
      END
     END
    ELSIF (obj.mode = Var) & (obj.sysflag # untraced) THEN FindPtrs(obj.typ, obj.linkadr)
    ELSIF obj.mode = Module THEN OPT.modules[-obj.mnolev].used := TRUE
    END;
    traverse(obj.left); traverse(obj.right)
   END
  END traverse;

  PROCEDURE FindNewMths(obj: OPT.Object);
  BEGIN
   IF obj # NIL THEN
    IF (obj.mode = TProc) OR ((obj.mode = Typ) & (obj.conval # NIL) & (hasBody IN obj.conval.setval)) THEN
     newMthTab[nofnewmth] := obj; INC(nofnewmth)
    END;
    IF obj.mode = Typ THEN FindNewMths(obj.typ.link)
    ELSE FindNewMths(obj.left); FindNewMths(obj.right)
    END
   END
  END FindNewMths;

 BEGIN (* OutCode *)
  modMap[0] := 0;
  linkCorrection := 0; i := 0;
  WHILE i < nofLinks DO
   IF (link[i].offset = Nil) OR (link[i].mod > 0) THEN INC(linkCorrection) END;
   INC(i)
  END;
  i := (-OPO.csize) MOD 4;
  WHILE i > 0 DO OPO.constant[OPO.csize] := 0X; INC(OPO.csize); DEC(i) END;
  nofcmds := 0;
  traverse(OPT.topScope.right);
  nofImp := 0; i := 1;
  WHILE i < OPT.nofmod DO
   IF OPT.modules[i].used THEN INC(nofImp); modMap[i] := SHORT(nofImp) END;
   INC(i)
  END;
  i := 0;
  (* header block *)
  (* NOTE: the uint16 code size is no longer measured in bytes, but in words, because
     in ARMv7 each instruction is a 32 bit value which causes programs to be ~ 1.5 times
     the size of i386, so some of the large Oberon system files (Objects, etc.) exceed
     the uint16 size. We avoid this limitation by counting instructions instead of bytes.
     multibootlinker.c, objdump.c and Modules.Mod have been updated accordingly.
     2026-03-13 me@rochus-keller.ch *)
  OPM.ObjWInt(nofEntries); OPM.ObjWInt(nofcmds);
  IF nofptrs > MAX(INTEGER) THEN OPM.err(222) END;
  OPM.ObjWInt(SHORT(nofptrs)); OPM.ObjWInt(nofrecs);
  OPM.ObjWInt(nofImp);
  OPM.ObjWInt(nofVarCons); OPM.ObjWInt(nofLinks - linkCorrection);
  OPM.ObjWBytes(OPO.dsize, 4); OPM.ObjWInt(SHORT(OPO.csize)); OPM.ObjWInt(SHORT(OPO.pc DIV 4));
  WriteName(modName);
  (* entry block *)
  OPM.ObjW(EntryTag);
  i := 0; WHILE i < nofEntries DO OPM.ObjWInt(entry[i]); INC(i) END;
  (* command block *)
  OPM.ObjW(commandTag);
  i := 0;
  WHILE i < nofcmds DO
   obj := commandTab[i];
   IF obj.link # NIL THEN OPM.ObjW("$") END;
   WriteName(obj.name); OPM.ObjWInt(entry[obj.adr MOD 10000H]);
   INC(i)
  END;
  (* pointer block *)
  OPM.ObjW(pointerTag);
  i := 0;
  WHILE i < nofptrs DO OPM.ObjWBytes(ptrTab[i], 4); INC(i) END;
  (* import block *)
  OPM.ObjW(importTag);
  i := 1;
  WHILE i < OPT.nofmod DO
   obj := OPT.modules[i];
   IF obj.used THEN WriteName(obj.name) END;
   INC(i)
  END;
  (* VarConsLink block *)
  OPM.ObjW(VarConsLinkTag);
  i := 0;
  WHILE i < nofVarCons DO
   OPM.ObjW(CHR(modMap[varConsLink[i].mod]));
   OPM.ObjWInt(varConsLink[i].entry); OPM.ObjWInt(varConsLink[i].noflinks);
   k := varConsLink[i].index;
   WHILE k # noEntry DO OPM.ObjWInt(varConsTab[k].offset); k := varConsTab[k].next END;
   INC(i)
  END;
  (* link block *)
  OPM.ObjW(LinkTag);
  i := 0;
  WHILE i < nofLinks DO
   IF (link[i].offset # Nil) & (link[i].mod <= 0) THEN
    OPM.ObjW(CHR(modMap[link[i].mod])); OPM.ObjW(CHR(link[i].entry));
    IF link[i].entry = CaseTableEntryNr THEN OPM.ObjWInt(SHORT(link[i].offset))
    ELSE OPM.ObjWInt(SHORT(link[i].offset DIV 4))
    END
   END;
   INC(i)
  END;
  (* data block *)
  OPM.ObjW(DataTag);
  i := 0; WHILE i < OPO.csize DO OPM.ObjW(OPO.constant[i]); INC(i) END;
  (* export block *)
  OPM.ObjW(ExportTag);
  pos := OPM.ObjAllocInt();
  nofExp := 0; nofStr := 0; OPT.modNo := 0;
  exppos := 0;
  Export(OPT.topScope.right, nofExp);
  OPM.ObjW(EUEnd); OPM.ObjFillInt(pos, nofExp);
  (* code block *)
  OPM.ObjW(CodeTag);
  i := 0; WHILE i < OPO.pc DO OPM.ObjW(OPO.code[i]); INC(i) END;
  (* use block *)
  OPM.ObjW(UseTag);
  i := 1;
  WHILE i < OPT.nofmod DO
   IF OPT.modules[i].used THEN
    OPM.ObjWString(OPT.modules[i].name);
    OPT.modNo := SHORT(i);
    Use(OPT.modules[i].right);
    OPM.ObjW(EUEnd)
   END;
   INC(i)
  END;
  OPM.ObjW(EUEnd);
  (* type block *)
  OPM.ObjW(TypeTag);
  i := 0;
  WHILE i < nofrecs DO
   typ := recTab[i];
   nofptrs := 0;
   FindPtrs(typ, 0);
   OPM.ObjWBytes(typ.size, 4);
   OPM.ObjWInt(SHORT(typ.tdadr));
   btyp := typ.BaseTyp;
   IF btyp = NIL THEN
    nofinhmth := 0;
    OPM.ObjWInt(-1); OPM.ObjWLInt(-1)
   ELSE
    nofinhmth := SHORT(btyp.n);
    OPM.ObjWInt(modMap[btyp.mno]);
    IF btyp.mno = 0 THEN OPM.ObjWBytes(btyp.tdadr, 4)
    ELSE OPM.ObjWLInt(btyp.strobj.fp)
    END
   END;
   OPM.ObjWInt(SHORT(typ.n));
   OPM.ObjWInt(nofinhmth);
   nofnewmth := 0;
   FindNewMths(typ.strobj);
   OPM.ObjWInt(nofnewmth);
   IF nofptrs > MAX(INTEGER) THEN OPM.err(221) END;
   OPM.ObjWInt(SHORT(nofptrs));
   IF (typ.strobj # NIL) & (typ.strobj.mnolev = 0) THEN
    IF typ.ptr # NIL THEN
     IF typ.ptr.strobj = NIL THEN WriteName(typ.strobj.name)
     ELSE WriteName(typ.ptr.strobj.name)
     END
    ELSE WriteName(typ.strobj.name)
    END
   ELSE OPM.ObjW(0X)
   END;
   WHILE nofnewmth > 0 DO
    DEC(nofnewmth);
    OPM.ObjWInt(SHORT(newMthTab[nofnewmth].adr DIV 10000H));
    OPM.ObjWInt(SHORT(newMthTab[nofnewmth].adr MOD 10000H))
   END;
   k := 0;
   WHILE k < nofptrs DO OPM.ObjWBytes(ptrTab[k], 4); INC(k) END;
   INC(i)
  END;
  (* ref block written in OPM.CloseRefObj *)
  OPM.CloseObj
 END OutCode;

 PROCEDURE Close*;
  VAR i: LONGINT;
 BEGIN
  FOR i := 0 TO LEN(OPIR.Instr) - 1 DO OPIR.Instr[i].node := NIL END;
  i := 0; WHILE i < LEN(recTab) DO recTab[i] := NIL; INC(i) END
 END Close;

BEGIN
 NEW(ptrTab, 512); NEW(recTab, 64); NEW(entry, 128);
 NEW(varConsLink, 100); NEW(varConsTab, 500);
 NEW(explist, 32)
END OPL.
