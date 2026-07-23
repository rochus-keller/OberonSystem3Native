(* OPIR - Intermediate Representation for the OP2 compiler *)
(* Defines the pseudo-RISC instruction set opcodes, data structures, and pseudo registers *)
(* These definitions are target-independent and shared between the code generator (OPC) *)
(* and the target-specific lowering modules (e.g. OPL for i386) *)

MODULE OPIR;
 IMPORT OPT, OPM;

 CONST
  (* opcode of pseudo RISC processor *)
  (* integer operations *)
  ld* = 32; ldbdw* = 64; ldwdw* = 96; ldbw* = 128; 
  ldbdwu* = 160; ldwdwu* = 196; ldbwu* = 224; getReg* = 256 ;
  putReg* = 288; ldProc* = 320; ldXProc* = 352; lea* = 384; 
  store* = 416; push* = 448; pop* = 480; add* = 512; 
  sub* = 544; mul* = 576; div* = 608; mod* = 640; 
  neg*= 960; abs* = 992; cmp* = 1056; je* = 1504; 
  jne* = 1536; jl* = 1568; jle* = 1600; jg* = 1632; 
  jge* = 1664; ja* = 1696; jae* = 1728; jb* = 1760; 
  jbe* = 1792; jc* = 1824; jnc* = 1856; jmp* = 1888; 
  jmpReg* = 1920; sete* = 1120; setne* = 1152; setl* = 1184; 
  setle* = 1216; setg* = 1248; setge* = 1280; seta* = 1312; 
  setae* = 1344; setb* = 1376; setbe* = 1408; setc* = 1440; 
  setnc* = 1472; te* = 1952; tne* = 1984; tle* = 2944;
  ta* = 2016; tae* = 2880; to* = 2912; 
  trap* = 2048; or* = 672; xor* = 704; and* = 736; 
  not* = 1024; bt* = 1088; btr* = 768; bts* = 800; test* = 3424;
  call* = 2080; callReg* = 2112; xcall* = 2144; ret* = 2176; 
  enter* = 2208; leave* = 2240; sal* = 832; sar* = 864; 
  shr* = 896; rol* = 928; cld* = 2272; repMovs* = 2304; 
  cmpString* = 2336; pushReg* = 2368; popReg* = 2400; case* = 2432; 
  short* = 2976; phi* = 2464; label* = 2496; entier* = 3104;
  cli* = 3168; sti* = 3200; in* = 3232; out* = 3264;
  assembler* = 3296;
  clear*= 3328; std*= 3392;
  dmb* = 3456;   (* memory barrier, ARM DMB ISH; no-op on i386/RV32 *)

  (* floating point operations *)
  fload*= 2528; fstore* = 2560; fist*= 2592; fild* = 2624;
  fadd* = 2656; fsub* = 2688; fmul* = 2720; fdiv* = 2752;
  fabs* = 2784; fchs* = 2816; fcmp* = 2848;

  newStat* = 3136;

  (* predefined registers of the pseudo RISC machine *)
  none* = -1; FP* = -2; SP* = -3;

  (* hints for the pseudo machine *)
  noHint* = -1;
  useReg0* = 0; useReg1* = 1; useReg2* = 2; useReg3* = 3;
  useReg4* = 4; useReg5* = 5; useReg6* = 6; useReg7* = 7;
  useFReg* = 8;
  tryReg0* = 16; tryReg1* = 17; tryReg2* = 18; tryReg3* = 19;
  tryReg6* = 22; tryReg7* = 23;

  (* item modes (must not overlap item basemodes, > 13) *)
  Reg* = 15; Abs* = 16; RegRel* = 17; Coc* = 18;

  (* instruction addressing modes *)
  RegReg* = 0; (* register to register *)
  RegMem* = 1; (* register to memory *)
  MemReg* = 2; (* memory to register *)
  ImmReg* = 3; (* immediate to register *)
  ImmMem* = 4; (* immediate to memory *)

  (* scale factors *)
  noScale* = 0; Scale1* = 0; Scale2* = 1; Scale4* = 2; Scale8* = 3;

  (* register/memory operand size *)
  Bit8* = 16; Bit16* = 8; Bit32* = 0; Bit64* = 40;

  (* Traps *)
  WithTrap* = 1; CaseTrap* = 2; FuncTrap* = 3; OverflowTrap* = 4;
  EqualGuardTrap* = 5; GuardTrap* = 6; RangeTrap* = 7; DimTrap* = 9;

  (* predefined Entry numbers and Link indices *)
  NewLinkIndex* = 2; NewEntryNr* = 253;
  NewSysLinkIndex* = 3; NewSysEntryNr* = 252;
  NewArrayLinkIndex* = 4; NewArrayEntryNr* = 251;
  StartIndex* = 5; StartEntryNr* = 250;
  AwaitIndex* = 6; AwaitEntryNr* = 249;
  LockIndex* = 7; LockEntryNr* = 247;
  UnlockIndex* = 8; UnlockEntryNr* = 246;

  (* Software arithmetic sysfixes — used when hardware support is absent *)
  DivModLinkIndex* = 9;   DivModEntryNr* = 245;   (* integer DIV/MOD *)
  F64AddLinkIndex* = 10;  F64AddEntryNr* = 244;   (* LONGREAL + *)
  F64SubLinkIndex* = 11;  F64SubEntryNr* = 243;   (* LONGREAL - *)
  F64MulLinkIndex* = 12;  F64MulEntryNr* = 242;   (* LONGREAL * *)
  F64DivLinkIndex* = 13;  F64DivEntryNr* = 241;   (* LONGREAL / *)
  F64CmpLinkIndex* = 14;  F64CmpEntryNr* = 240;   (* LONGREAL compare *)
  F64CvtIFLinkIndex* = 15; F64CvtIFEntryNr* = 239; (* INT to LONGREAL *)
  F64CvtFILinkIndex* = 16; F64CvtFIEntryNr* = 238; (* LONGREAL to INT *)
  F64NegLinkIndex* = 17;  F64NegEntryNr* = 237;   (* LONGREAL negation *)
  F64AbsLinkIndex* = 18;  F64AbsEntryNr* = 236;   (* LONGREAL ABS *)

  Nil* = OPM.LANotAlloc; (* for Instr[..].pc initialization *)
  
 TYPE
  Instruction* = RECORD 
   scale*, reg*: SHORTINT;
   op*: INTEGER;
   dest*, src1*, src2*, inx*, pc*, hint*: LONGINT; (* pc: PC on the target machine, used for jumps *)
   link*, used*: INTEGER;
   node*: OPT.Node;
   abs*: BOOLEAN; (* absolute address, should not be fixed. Def = FALSE. *)  (* GetPut *)
  END;
  InstructionTable* = POINTER TO ARRAY OF Instruction;

  Map* = POINTER TO MapDesc;
  MapDesc* = ARRAY OF RECORD
   pos*, pc* : LONGINT
  END;

 VAR
  Instr*:  InstructionTable; (* Pseudo Code *)
  mapSize* : LONGINT;
  map* : Map;

BEGIN
 NEW(Instr, 500)
END OPIR.
