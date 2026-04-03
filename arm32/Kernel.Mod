MODULE Kernel;  
(*
 * Port of the ETH Native Oberon System 3 v2.3.7 i386 kernel to ARMv7.
 * for QEMU raspi2b / Raspberry Pi 3B (32-bit)
 *
 * (c) 2026 Rochus Keller <mailto:me@rochus-keller.ch>
 *
 * GNU General Public License Usage
 * This file may be used under the terms of the GNU General Public
 * License (GPL) versions 2.0 or 3.0 as published by the Free Software
 * Foundation and appearing in the file LICENSE.GPL included in
 * the packaging of this file. Please review the following information
 * to ensure GNU General Public Licensing requirements will be met:
 * http://www.fsf.org/licensing/licenses/info/GPLv2.html and
 * http://www.gnu.org/copyleft/gpl.html.
 *)

IMPORT SYSTEM;

CONST
  (* Heap/GC constants *)
  B = 32;  (* heap block size, must be a multiple of 32 *)
  N = 9;   (* number of free lists - 1 *)
  MarkBit = 0;  ArrayBit = 1;  FreeBit = 2;  SubObjBit = 3;
  mark = {MarkBit};  array = {ArrayBit};  free = {FreeBit};  subobj = {SubObjBit};
  ReserveSize = 65536 - 8;  (* bytes reserved for "out of memory" trap handling *)
  DefaultStackSize = 128*1024;
  AlwaysGC = TRUE;  (* always run GC when triggered *)

  (* Platform constants *)
  DefaultRAMSize = 40000000H;  (* 1GB for QEMU raspi2b *)
  BootStackSize = 8192;
  ImageBase = 10000H;  (* --base 0x10000 *)
  TimeUnit* = 1000;  (* timer ticks per second *)
  LittleEndian* = TRUE;
  LsbIs0* = TRUE;

  (* MMU constants *)
  L1TableSize = 4096;  (* number of 1MB section entries covering 4GB *)
  L1EntrySection = 2;  (* bits [1:0] = 10 = section descriptor *)
  (* Section descriptor attribute bits *)
  SectAP = 00C00H;  (* AP[1:0] = 11 = full access, bits 11:10 *)
  SectNormal = 0100CH;  (* TEX=001 C=1 B=0 : outer/inner write-back write-allocate + S bit 16 *)
  SectDevice = 04H;  (* TEX=000 C=0 B=1 : device memory, shared *)
  SectNormalNC = 01000H;  (* TEX=001 C=0 B=0 : normal non-cacheable *)
  SectShareable = 10000H;  (* S bit = bit 16 *)
  SectDomain0 = 0;  (* domain 0, bits [8:5] = 0000 *)

  (* ARM exception vector indices *)
  ExcReset = 0;  ExcUndef = 1;  ExcSVC = 2;  ExcPrefetchAbort = 3;
  ExcDataAbort = 4;  ExcReserved = 5;  ExcIRQ = 6;  ExcFIQ = 7;
  NVectors = 8;
  IRQ* = 32;  (* Interrupt number base for hardware IRQs, same as x86 API *)
  MaxInts = 4;  (* max handlers per interrupt slot *)
  IDTSize = 48;  (* total interrupt slots: 0..31 = exceptions, 32..47 = IRQ0..15 *)
  MaxFrames = 10;  (* max stack frames shown in ShowState *)

TYPE
  ADDRESS = LONGINT;
  Name* = ARRAY 32 OF CHAR;
  Proc* = PROCEDURE;

  (* Module descriptor ? must match multibootlinker's DumpModuleDesc layout *)
  Cmd* = RECORD
    name*: Name;
    adr*: ADDRESS
  END;
  Module* = POINTER TO ModuleDesc;
  ExportPtr* = POINTER TO ExportDesc;
  ExportDesc* = RECORD
    fp*: LONGINT;  adr*: LONGINT;
    nofExp*: INTEGER;
    dsc*: POINTER TO ARRAY OF ExportDesc
  END;
  ArrayPtr* = POINTER TO ARRAY OF LONGINT;
  ModuleDesc* = RECORD  (* if changed, also update the static Linker *)
    next*: Module;
    name*: Name;
    init*, trapped*: BOOLEAN;
    refcnt*, sb*: LONGINT;
    entries*: POINTER TO ARRAY OF ADDRESS;
    cmds*: POINTER TO ARRAY OF Cmd;
    ptrTab*, tdescs*: POINTER TO ARRAY OF ADDRESS;
    imports*: POINTER TO ARRAY OF Module;
    data*, code*, refs*: POINTER TO ARRAY OF CHAR;
    publics*, privates*: LONGINT;
    nofimp*: INTEGER;  import*: ArrayPtr;
    nofstrc*: INTEGER;  struct*: ArrayPtr;
    nofreimp*: INTEGER;  reimp*: ArrayPtr;
    export*: ExportDesc;
    term*: Proc
  END;

  (* Type descriptors ? used by GC for pointer tracing *)
  Tag = POINTER TO TypeDesc;
  TypeDesc = RECORD
    size: LONGINT;
    ptroff: LONGINT  (* first pointer offset; -4 = no pointers. Followed by more offsets, terminated by -4. *)
  END;

  (* Heap block types *)
  FreeBlockPtr = POINTER TO FreeBlock;
  FreeBlock = RECORD
    tag: Tag;       (* off-4: tag with FreeBit set *)
    size: LONGINT;  (* off0: block size, aligned to B, size MOD B = B-4 *)
    next: ADDRESS   (* off4: next free block in same size class *)
  END;
  BlockPtr = POINTER TO Block;
  Block = RECORD
    lastElemToMark, currElem, firstElem: BlockPtr
  END;
  Blockm4Ptr = POINTER TO Blockm4;
  Blockm4 = RECORD
    tag: Tag;
    lastElemToMark, currElem, firstElem: LONGINT
  END;
  InitPtr = POINTER TO RECORD tag: Tag; z0, z1, z2, z3, z4, z5, z6, z7: LONGINT END;
  PtrElemDesc = RECORD a: SYSTEM.PTR END;  (* has same type descriptor as ARRAY OF POINTER element *)

  (* Interrupt/Trap types *)
  TrapHandler* = PROCEDURE (err, fp, pc, pf: LONGINT);
  Finalizer* = PROCEDURE (obj: SYSTEM.PTR);
  FinObj = POINTER TO FinObjNode;
  FinObjNode = RECORD
    next: FinObj;
    obj: LONGINT;
    marked: BOOLEAN;
    fin: Finalizer
  END;

  MilliTimer* = RECORD target: LONGINT END;

VAR
  (* Exported variables *)
  version*: ARRAY 32 OF CHAR;
  modules*: Module;  (* list of modules, patched by Linker *)
  StackOrg*: ADDRESS;  (* highest address on stack *)
  bt*: ADDRESS;  (* boot table *)
  tspeed*: LONGINT;
  tbase*: INTEGER;  (* trace base port ? not used on ARM, kept for API compatibility *)
  break*: BOOLEAN;
  copro*: BOOLEAN;
  inGC*: BOOLEAN;
  EnableGC*, DisableGC*: Proc;
  timer*: Proc;
  runtime*: ARRAY 3 OF ADDRESS;  (* [0]=NewRec, [1]=NewSys, [2]=NewArr *)
  traceConsole*: BOOLEAN;
  shutdown*: LONGINT;
  ticks*: LONGINT;

  (* Heap/GC variables *)
  memTop, heapTop: ADDRESS;
  firstBlock, endBlock: ADDRESS;
  A: ARRAY N+1 OF ADDRESS;  (* free list heads, A[i] = first free block of size i*B *)
  reserve: BlockPtr;  (* reserved memory for out-of-memory trap *)
  ptrElemTag: ADDRESS;  (* type tag for ARRAY OF POINTER elements *)
  candidates: ARRAY 1024 OF ADDRESS;  (* conservative stack pointer candidates *)
  nofcand: INTEGER;
  firstTry: BOOLEAN;
  GCstack: BOOLEAN;
  FinObjs: FinObj;
  traceheap: SET;
  GClevel: LONGINT;

  (* Tracing *)
  traceBufAdr, traceBufSize, traceHead, traceTail, traceMark: LONGINT;

  (* Config *)
  configadr: ADDRESS;
  cmdlineBuf: ARRAY 1024 OF CHAR;  (* parsed config: key0 NUL val0 NUL ... NUL NUL *)
  kpar: ARRAY 16 OF LONGINT;  (* init parameters, indexed by GetInit *)

  (* Trap/Interrupt handling *)
  handler0, handler: TrapHandler;  (* default and user trap handlers *)
  handlingtrap: BOOLEAN;
  loop: Proc;  (* procedure to return to after trap *)
  intHandler: ARRAY IDTSize, MaxInts OF Proc;  (* interrupt handler table *)
  defaultHandler: Proc;  (* default handler for unexpected interrupts *)
  vectorTableBuf: ARRAY NVectors * 2 + 8 OF LONGINT;  (* oversized buffer for 32-byte alignment *)
  vectorTableBase: ADDRESS;  (* aligned base address within vectorTableBuf *)

  (* MMU *)
  l1TableBuf: ARRAY L1TableSize + 4096 OF LONGINT;  (* 16KB table + 16KB padding for alignment *)
  l1TableBase: ADDRESS;  (* 16KB-aligned base within l1TableBuf *)

  (* Timer *)
  irqStack: ARRAY 64 OF LONGINT;  (* 256 bytes for IRQ mode stack *)
  abtStack, undStack: ARRAY 64 OF LONGINT; (* Stacks for Traps *)
  irqStub: ARRAY 14 OF LONGINT;  (* IRQ handler machine code + data *)
  timerPeriod: LONGINT;  (* CNTFRQ / TimeUnit = counter ticks per timer tick *)

  (* Clock *)
  second, minute, hour, day, month, year: INTEGER;  (* dummy clock state *)



(* Park cores: Check MPIDR core ID; if not core 0, loop forever.
  Must be called before any other code to prevent secondary cores from
  executing the kernel. QEMU raspi2b starts all 4 cores at the same address.
  Uses DCD raw words because MRC needs 6 operands (assembler limit is 5)
  and branch-to-self needs a relative offset not expressible via labels.
    0EE100FB0H = MRC p15, 0, R0, c0, c0, 5  (read MPIDR)
    0E2000003H = AND R0, R0, #3              (isolate core ID bits)
    0E3500000H = CMP R0, #0                  (is it core 0?)
    00A000000H = BEQ +1 instruction          (skip loop if core 0)
    0EAFFFFFFEH = B self                     (infinite loop for cores 1-3) *)
PROCEDURE -ParkSecondaryCores;
CODE {SYSTEM.arm}
  DCW 00FB0H, 0EE10H
  DCW 00003H, 0E200H
  DCW 00000H, 0E350H
  DCW 00000H, 00A00H
  DCW 0FFFEH, 0EAFFH
END ParkSecondaryCores;

(* Read a 32-bit word from an absolute memory address. *)
PROCEDURE -GetWord(adr: LONGINT): LONGINT;
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  LDR R0, [R0, #0]
  ADD SP, SP, #4
END GetWord;

(* Write a 32-bit word to an absolute memory address. *)
PROCEDURE -PutWord(adr, val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #4]
  LDR R1, [SP, #0]
  STR R1, [R0, #0]
  ADD SP, SP, #8
END PutWord;

(* Return current stack pointer value (R13). *)
PROCEDURE -GetSP(): LONGINT;
CODE {SYSTEM.arm}
  MOV R0, SP
END GetSP;

(* Return current frame pointer value (R11). *)
PROCEDURE -GetR11(): LONGINT;
CODE {SYSTEM.arm}
  MOV R0, R11
END GetR11;

(* Return current program status register. *)
PROCEDURE -GetCPSR(): SET;
CODE {SYSTEM.arm}
  DCW 00000H, 0E10FH
END GetCPSR;

(* Set the Vector Base Address Register (CP15 c12).
  Inline arg on stack: adr at [SP]. *)
PROCEDURE -SetVBAR(adr: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F10H, 0EE0CH
END SetVBAR;

(* ARM DSB instruction. *)
PROCEDURE -DataSyncBarrier;
CODE {SYSTEM.arm}
  DCW 0F04FH, 0F57FH
END DataSyncBarrier;

(* ARM ISB instruction. *)
PROCEDURE -InstrSyncBarrier;
CODE {SYSTEM.arm}
  DCW 0F06FH, 0F57FH
END InstrSyncBarrier;

(* MMU CP15 Operations: *)

(* Write TTBR0 (Translation Table Base Register 0).
  MCR p15, 0, R0, c2, c0, 0 = 0xEE020F10 *)
PROCEDURE -SetTTBR0(adr: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F10H, 0EE02H
END SetTTBR0;

(* Write TTBCR (Translation Table Base Control Register).
  MCR p15, 0, R0, c2, c0, 2 = 0xEE020F50 *)
PROCEDURE -SetTTBCR(val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F50H, 0EE02H
END SetTTBCR;

(* Write DACR (Domain Access Control Register).
  MCR p15, 0, R0, c3, c0, 0 = 0xEE030F10 *)
PROCEDURE -SetDACR(val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F10H, 0EE03H
END SetDACR;

(* Read SCTLR (System Control Register).
  MRC p15, 0, R0, c1, c0, 0 = 0xEE110F10 *)
PROCEDURE -GetSCTLR(): LONGINT;
CODE {SYSTEM.arm}
  DCW 00F10H, 0EE11H
END GetSCTLR;

(* Write SCTLR (System Control Register).
  MCR p15, 0, R0, c1, c0, 0 = 0xEE010F10 *)
PROCEDURE -SetSCTLR(val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F10H, 0EE01H
END SetSCTLR;

(* Invalidate entire unified TLB.
  MCR p15, 0, R0, c8, c7, 0 = 0xEE080F17 *)
PROCEDURE -InvalidateTLB;
CODE {SYSTEM.arm}
  MOV R0, #0
  DCW 00F17H, 0EE08H
END InvalidateTLB;

(* Invalidate instruction cache.
  MCR p15, 0, R0, c7, c5, 0 = 0xEE070F15 *)
PROCEDURE -InvalidateICache;
CODE {SYSTEM.arm}
  MOV R0, #0
  DCW 00F15H, 0EE07H
END InvalidateICache;

(* Invalidate data cache (by set/way - simplified: invalidate all).
  MCR p15, 0, R0, c7, c6, 0 = 0xEE070F16  -- Invalidate entire data cache *)
PROCEDURE -InvalidateDCache;
CODE {SYSTEM.arm}
  MOV R0, #0
  DCW 00F16H, 0EE07H
END InvalidateDCache;

(* Read VFP Floating-Point Status and Control Register*)
PROCEDURE -GetFPSCR(): SET;
CODE {SYSTEM.arm}
  DCW 00A10H, 0EEF1H
END GetFPSCR;

(* Write VFP Floating-Point Status and Control Register.
  Inline arg on stack: val at [SP] *)
PROCEDURE -SetFPSCR(val: SET);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00A10H, 0EEE1H
END SetFPSCR;

(* Read ARM Generic Timer frequency register *)
PROCEDURE -GetCNTFRQ(): LONGINT;
CODE {SYSTEM.arm}
  DCW 00F10H, 0EE1EH
END GetCNTFRQ;

(* Write ARM Generic Timer countdown value *)
PROCEDURE -SetCNTPTVAL(val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F12H, 0EE0EH
END SetCNTPTVAL;

(* Write ARM Generic Timer control register.
  MCR p15, 0, R0, c14, c2, 1 = 0xEE0E0F32
  Bit 0: ENABLE, Bit 1: IMASK (1=masked) *)
PROCEDURE -SetCNTPCTL(val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F32H, 0EE0EH
END SetCNTPCTL;

(* Read ARM Generic Timer control register.
  MRC p15, 0, R0, c14, c2, 1 = 0xEE1E0F32
  Bit 2: ISTATUS (1=timer expired) *)
PROCEDURE -GetCNTPCTL(): LONGINT;
CODE {SYSTEM.arm}
  DCW 00F32H, 0EE1EH
END GetCNTPCTL;

(* Switch to IRQ mode, set SP_irq, switch back to SVC.
  MRS R1, CPSR          = 0xE10F1000
  BIC R2, R1, #0x1F     = 0xE3C1201F
  ORR R2, R2, #0x12     = 0xE3822012  (IRQ mode)
  MSR CPSR_c, R2        = 0xE121F002
  MOV SP, R0            (native asm)
  MSR CPSR_c, R1        = 0xE121F001  (restore SVC mode) *)
PROCEDURE -SetIRQStack(sp: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 01000H, 0E10FH
  DCW 0201FH, 0E3C1H
  DCW 02012H, 0E382H
  DCW 0F002H, 0E121H
  MOV SP, R0
  DCW 0F001H, 0E121H
END SetIRQStack;


(* Write a single character via ARM semihosting with runtime CPU detection. *)
PROCEDURE -SemiWriteC*(ch: CHAR);
CODE {SYSTEM.arm}
  LDRB R1, [R11, #8]       (* load character from parameter *)
  STRB R1, [R11, #-4]      (* store to scratch space on stack *)
  SUB  R1, R11, #4         (* r1 = pointer to the byte *)
  MOV  R0, #3              (* SYS_WRITEC *)
  
  DCD 0EE102F10H           (* MRC p15, 0, r2, c0, c0, 0  ; Read CPU ID into R2 *)
  DCD 0E2022A0FH           (* AND r2, r2, #0xF000        ; Mask ID *)
  DCD 0E3520A0DH           (* CMP r2, #0xD000            ; Check if Cortex-A53 (RPi 3) *)
  DCD 01A000001H           (* BNE +1                     ; If NOT Cortex-A53, jump over HLT and B *)
  DCD 0E10F0070H           (* HLT 0xF000                 ; Cortex-A53 Semihosting Trap *)
  DCD 0EA000000H           (* B +0                       ; Jump over SVC *)
  DCD 0EF123456H           (* SVC 0x123456               ; Cortex-A7 (QEMU) Semihosting Trap *)
END SemiWriteC;

PROCEDURE WriteChar*(c: CHAR);
BEGIN
  SemiWriteC(c)
END WriteChar;

PROCEDURE WriteString*(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN i := 0;  WHILE s[i] # 0X DO WriteChar(s[i]);  INC(i) END
END WriteString;

PROCEDURE WriteLn*;
BEGIN WriteChar(0DX);  WriteChar(0AX)
END WriteLn;

(* Write x as a decimal number. w is the field width. *)
PROCEDURE WriteInt*(x, w: LONGINT);
VAR i: LONGINT;  x0: LONGINT;  a: ARRAY 12 OF CHAR;  s: ARRAY 2 OF CHAR;
BEGIN
  IF x < 0 THEN
    IF x = MIN(LONGINT) THEN
      WriteString("-2147483648");
      RETURN
    ELSE
      DEC(w); x0 := -x
    END
  ELSE
    x0 := x
  END;
  i := 0;
  REPEAT
    a[i] := CHR(x0 MOD 10 + 30H); x0 := x0 DIV 10; INC(i)
  UNTIL x0 = 0;
  s[0] := " ";  s[1] := 0X;
  WHILE w > i DO WriteString(s); DEC(w) END;
  s[0] := "-";
  IF x < 0 THEN WriteString(s) END;
  REPEAT DEC(i); s[0] := a[i]; WriteString(s) UNTIL i = 0
END WriteInt;

(* Write x as a hexadecimal number. |w| is field width. *)
PROCEDURE WriteHex*(x, w: LONGINT);
VAR
  buf: ARRAY 10 OF CHAR;
  i, j: LONGINT;
BEGIN
  IF w >= 0 THEN j := 8 ELSE j := 2; w := -w END;
  FOR i := j+1 TO w DO WriteChar(" ") END;
  FOR i := j-1 TO 0 BY -1 DO
    buf[i] := CHR(x MOD 10H + 48);
    IF buf[i] > "9" THEN
      buf[i] := CHR(ORD(buf[i]) - 48 + 65 - 10)
    END;
    x := x DIV 10H
  END;
  buf[j] := 0X;
  WriteString(buf)
END WriteHex;


PROCEDURE Cap(ch: CHAR): CHAR;
BEGIN
  IF (ch >= "a") & (ch <= "z") THEN ch := CHR(ORD(ch) - 32) END;
  RETURN ch
END Cap;

PROCEDURE StrToInt(s: ARRAY OF CHAR): LONGINT;
VAR i, j: SHORTINT;  v, sgn, m: LONGINT;
BEGIN
  j := 0;  WHILE s[j] # 0X DO INC(j) END;
  IF (j > 0) & (Cap(s[j-1]) = "H") THEN m := 16; DEC(j) ELSE m := 10 END;
  v := 0;  i := 0;
  IF s[i] = "-" THEN sgn := -1; INC(i) ELSE sgn := 1 END;
  WHILE i < j DO
    IF (s[i] >= "0") & (s[i] <= "9") THEN v := v*m + (ORD(s[i])-ORD("0"))
    ELSIF (Cap(s[i]) >= "A") & (Cap(s[i]) <= "F") THEN v := v*m + (ORD(Cap(s[i]))-ORD("A")+10)
    ELSE sgn := 0;  j := i
    END;
    INC(i)
  END;
  RETURN sgn*v
END StrToInt;

(* Return value of a named config parameter.
  Scans the config area (key0 NUL val0 NUL key1 NUL val1 NUL ... NUL NUL).
  configadr points to cmdlineBuf which is populated from ATAGS. *)
PROCEDURE GetConfig*(name: ARRAY OF CHAR;  VAR val: ARRAY OF CHAR);
VAR i, src: LONGINT;  ch: CHAR;
BEGIN
  src := configadr;
  IF src # 0 THEN
    i := 0;  WHILE name[i] # 0X DO name[i] := Cap(name[i]);  INC(i) END;
    LOOP
      SYSTEM.GET(src, ch);
      IF ch = 0X THEN EXIT END;
      i := 0;
      LOOP
        SYSTEM.GET(src, ch);
        IF (Cap(ch) # name[i]) OR (name[i] = 0X) THEN EXIT END;
        INC(i);  INC(src)
      END;
      IF (ch = 0X) & (name[i] = 0X) THEN
        i := 0;
        REPEAT
          INC(src); SYSTEM.GET(src, ch); val[i] := ch; INC(i);
          IF i = LEN(val) THEN val[0] := 0X; RETURN END
        UNTIL ch = 0X;
        val[i] := 0X; RETURN
      ELSE
        WHILE ch # 0X DO INC(src); SYSTEM.GET(src, ch) END;
        INC(src);
        REPEAT SYSTEM.GET(src, ch);  INC(src) UNTIL ch = 0X
      END
    END
  END;
  val[0] := 0X
END GetConfig;



PROCEDURE DefaultEnableGC;
BEGIN INC(GClevel)
END DefaultEnableGC;

PROCEDURE DefaultDisableGC;
BEGIN DEC(GClevel)
END DefaultDisableGC;


(* Initialise trace buffer and GC tracing flags *)
PROCEDURE InitTracing(VAR top: LONGINT);
VAR s: ARRAY 32 OF CHAR;
BEGIN
  GetConfig("TraceSize", s);
  traceBufSize := StrToInt(s);
  IF traceBufSize <= 0 THEN traceBufSize := 2048 END;
  DEC(top, traceBufSize);
  traceBufAdr := top;
  traceHead := 0;
  traceTail := 0;
  traceMark := 0
END InitTracing;



(* Parse the image header to find RAM size, then
  extract the command-line config string from ATAGS. *)
PROCEDURE ReadBootTable;
VAR
  base, ramSize: LONGINT;
  atagsPtr: LONGINT;
  tagSize, tagId, ptr, val: LONGINT;
  i: INTEGER;
  ch: CHAR;
BEGIN
  base := GetWord(ImageBase + 4);  (* read LinkBase from image header *)
  ramSize := GetWord(base + 16);   (* read RAMSize from header *)
  IF ramSize > 0 THEN memTop := ramSize
  ELSE memTop := DefaultRAMSize
  END;

  (* Robust ATAGS pointer search:
     The multibootlinker pushed R2 onto the stack just before calling us.
     StackOrg points near the top of the stack. We scan upwards a few bytes 
     to find a pointer that points to the ATAG_CORE magic number. *)
  atagsPtr := 0;
  ptr := StackOrg;
  WHILE (atagsPtr = 0) & (ptr <= StackOrg + 128) DO
    val := GetWord(ptr);
    (* Must be a valid, aligned RAM address *)
    IF (val > 0) & (val < 10000000H) & (val MOD 4 = 0) THEN
      tagId := GetWord(val + 4);
      IF tagId = 54410001H THEN (* ATAG_CORE magic number *)
        atagsPtr := val
      END
    END;
    INC(ptr, 4)
  END;

  (* Fallback: Check the legacy hardcoded address (0x100) just in case *)
  IF atagsPtr = 0 THEN
    IF GetWord(100H + 4) = 54410001H THEN
      atagsPtr := 100H
    END
  END;

  cmdlineBuf[0] := 0X;
  configadr := SYSTEM.ADR(cmdlineBuf[0]);

  (* Walk ATAGS chain. *)
  IF atagsPtr > 0 THEN
    tagSize := GetWord(atagsPtr);
    tagId := GetWord(atagsPtr + 4);
    WHILE (tagSize > 0) & (tagId # 0) DO
      IF tagId = 54410009H THEN  (* ATAG_CMDLINE *)
        (* Data starts at offset 8 from tag start.
          Contains a NUL-terminated string
          Format: ";;key=val;key=val;..."  We convert '=' and ';' to 0 
          Surprise: raspi prefixes the format with other stuff, so we skip until we find ";;". *)
        ptr := atagsPtr + 8;
        LOOP
          SYSTEM.GET(ptr, ch);
          IF ch = 0X THEN 
            (* ";;" not found. Fall back to start of string. *)
            ptr := atagsPtr + 8; 
            EXIT 
          END;
          
          IF ch = ";" THEN
            SYSTEM.GET(ptr + 1, ch);
            IF ch = ";" THEN
              INC(ptr, 2);  (* Found start. Skip the ";;" *)
              EXIT
            END
          END;
          INC(ptr)
        END;
        
        (* Now do the normal parsing into cmdlineBuf... *)
        i := 0;
        SYSTEM.GET(ptr, ch);
        WHILE (ch # 0X) & (i < LEN(cmdlineBuf) - 2) DO
          IF (ch = "=") OR (ch = ";") THEN
            cmdlineBuf[i] := 0X
          ELSE
            cmdlineBuf[i] := ch
          END;
          INC(i);  INC(ptr);
          SYSTEM.GET(ptr, ch)
        END;
        cmdlineBuf[i] := 0X;
        cmdlineBuf[i + 1] := 0X
      END;
      (* Advance to next tag: tagSize is in 32-bit words *)
      INC(atagsPtr, tagSize * 4);
      tagSize := GetWord(atagsPtr);
      tagId := GetWord(atagsPtr + 4)
    END
  END;

  (* Fallback: if no ATAG_CMDLINE was found, use built-in default config. *)
  IF cmdlineBuf[0] = 0X THEN
    WriteString("Kernel: no ATAGS, using default boot config"); WriteLn;
    i := 0;
    cmdlineBuf[i] := "D"; INC(i); cmdlineBuf[i] := "i"; INC(i);
    cmdlineBuf[i] := "s"; INC(i); cmdlineBuf[i] := "k"; INC(i);
    cmdlineBuf[i] := "D"; INC(i); cmdlineBuf[i] := "e"; INC(i);
    cmdlineBuf[i] := "v"; INC(i); cmdlineBuf[i] := "i"; INC(i);
    cmdlineBuf[i] := "c"; INC(i); cmdlineBuf[i] := "e"; INC(i);
    cmdlineBuf[i] := 0X; INC(i);  (* key end *)
    cmdlineBuf[i] := "S"; INC(i); cmdlineBuf[i] := "D"; INC(i);
    cmdlineBuf[i] := "0"; INC(i);
    cmdlineBuf[i] := 0X; INC(i);  (* val end *)
    cmdlineBuf[i] := "A"; INC(i); cmdlineBuf[i] := "o"; INC(i);
    cmdlineBuf[i] := "s"; INC(i); cmdlineBuf[i] := "F"; INC(i);
    cmdlineBuf[i] := "S"; INC(i);
    cmdlineBuf[i] := 0X; INC(i);  (* key end *)
    cmdlineBuf[i] := "O"; INC(i); cmdlineBuf[i] := "F"; INC(i);
    cmdlineBuf[i] := "S"; INC(i); cmdlineBuf[i] := "D"; INC(i);
    cmdlineBuf[i] := "i"; INC(i); cmdlineBuf[i] := "s"; INC(i);
    cmdlineBuf[i] := "k"; INC(i); cmdlineBuf[i] := "V"; INC(i);
    cmdlineBuf[i] := "o"; INC(i); cmdlineBuf[i] := "l"; INC(i);
    cmdlineBuf[i] := "u"; INC(i); cmdlineBuf[i] := "m"; INC(i);
    cmdlineBuf[i] := "e"; INC(i); cmdlineBuf[i] := "s"; INC(i);
    cmdlineBuf[i] := "."; INC(i); cmdlineBuf[i] := "N"; INC(i);
    cmdlineBuf[i] := "e"; INC(i); cmdlineBuf[i] := "w"; INC(i);
    cmdlineBuf[i] := "~"; INC(i); cmdlineBuf[i] := "O"; INC(i);
    cmdlineBuf[i] := "F"; INC(i); cmdlineBuf[i] := "S"; INC(i);
    cmdlineBuf[i] := "A"; INC(i); cmdlineBuf[i] := "o"; INC(i);
    cmdlineBuf[i] := "s"; INC(i); cmdlineBuf[i] := "F"; INC(i);
    cmdlineBuf[i] := "i"; INC(i); cmdlineBuf[i] := "l"; INC(i);
    cmdlineBuf[i] := "e"; INC(i); cmdlineBuf[i] := "s"; INC(i);
    cmdlineBuf[i] := "."; INC(i); cmdlineBuf[i] := "N"; INC(i);
    cmdlineBuf[i] := "e"; INC(i); cmdlineBuf[i] := "w"; INC(i);
    cmdlineBuf[i] := "F"; INC(i); cmdlineBuf[i] := "S"; INC(i);
    cmdlineBuf[i] := 0X; INC(i);  (* val end *)
    cmdlineBuf[i] := "S"; INC(i); cmdlineBuf[i] := "y"; INC(i);
    cmdlineBuf[i] := "s"; INC(i); cmdlineBuf[i] := "t"; INC(i);
    cmdlineBuf[i] := "e"; INC(i); cmdlineBuf[i] := "m"; INC(i);
    cmdlineBuf[i] := "."; INC(i); cmdlineBuf[i] := "I"; INC(i);
    cmdlineBuf[i] := "n"; INC(i); cmdlineBuf[i] := "i"; INC(i);
    cmdlineBuf[i] := "t"; INC(i);
    cmdlineBuf[i] := 0X; INC(i);  (* command end *)
    cmdlineBuf[i] := 0X           (* double-NUL terminator *)
  END
END ReadBootTable;

(* Clamp memTop to DefaultRAMSize *)
PROCEDURE CheckMemory;
BEGIN
  IF memTop > DefaultRAMSize THEN memTop := DefaultRAMSize END
END CheckMemory;


(* Fill "count" dwords at "dst" with "filler" *)
PROCEDURE Fill4(dst, count, filler: LONGINT);
BEGIN
  WHILE count > 0 DO
    SYSTEM.PUT(dst, filler);
    INC(dst, 4);  DEC(count)
  END
END Fill4;


(* Return total free heap space in bytes *)
PROCEDURE Available*(): LONGINT;
VAR i, avail: LONGINT;  ptr: FreeBlockPtr;
BEGIN
  avail := 0;  i := 0;
  WHILE i <= N DO
    ptr := SYSTEM.VAL(FreeBlockPtr, A[i]);
    WHILE ptr # NIL DO
      INC(avail, ptr.size);  ptr := SYSTEM.VAL(FreeBlockPtr, ptr.next)
    END;
    INC(i)
  END;
  RETURN avail
END Available;

(* Return size of largest free block in bytes *)
PROCEDURE LargestAvailable*(): LONGINT;
VAR i, max: LONGINT;  ptr: FreeBlockPtr;
BEGIN
  i := N;  max := 0;
  WHILE (i >= 0) & (max = 0) DO
    ptr := SYSTEM.VAL(FreeBlockPtr, A[i]);
    WHILE ptr # NIL DO
      IF ptr.size > max THEN max := ptr.size END;
      ptr := SYSTEM.VAL(FreeBlockPtr, ptr.next)
    END;
    DEC(i)
  END;
  RETURN max
END LargestAvailable;



(* Traverses all pointer fields of a heap block and its sub-objects,
  setting the MarkBit in each block tag.  *)
PROCEDURE Mark(block: BlockPtr);
TYPE Tag0 = POINTER TO RECORD ptroff: SET END;
  (* size skipped, because accessed via tag = actual tag + 4 *)
VAR father, field, currElem: BlockPtr;
  offset: LONGINT;
  tag, downtag, marked: Tag0;
  arraybit: SET;
BEGIN
  SYSTEM.GET(SYSTEM.VAL(ADDRESS, block) - 4, tag);
  IF ~(SubObjBit IN SYSTEM.VAL(SET, block)) THEN  (* not a subobject *)
    marked := SYSTEM.VAL(Tag0, SYSTEM.VAL(SET, tag) + mark);
    IF tag # marked THEN
      SYSTEM.PUT(SYSTEM.VAL(ADDRESS, block) - 4, marked);
      SYSTEM.GET(SYSTEM.VAL(ADDRESS, SYSTEM.VAL(SET, tag) - array) - 4, marked);
      EXCL(SYSTEM.VAL(SET, marked), MarkBit);
      SYSTEM.GET(SYSTEM.VAL(ADDRESS, marked) - 4, arraybit);
      INCL(arraybit, MarkBit);
      SYSTEM.PUT(SYSTEM.VAL(ADDRESS, marked) - 4, arraybit);
      arraybit := SYSTEM.VAL(SET, tag) * array;
      IF arraybit # {} THEN
        currElem := block.firstElem;
        tag := SYSTEM.VAL(Tag0, SYSTEM.VAL(SET, tag) - arraybit)
      ELSE
        currElem := block
      END;
      father := NIL;
      LOOP
        INC(SYSTEM.VAL(ADDRESS, tag), 4);
        offset := SYSTEM.VAL(LONGINT, tag.ptroff - {ArrayBit});
        IF offset < 0 THEN
          INC(SYSTEM.VAL(ADDRESS, tag), offset);
          IF (arraybit # {}) & (currElem # block.lastElemToMark) THEN
            INC(SYSTEM.VAL(ADDRESS, currElem), SYSTEM.VAL(LONGINT, tag.ptroff - {ArrayBit}))
          ELSE  (* up *)
            SYSTEM.PUT(SYSTEM.VAL(ADDRESS, block) - 4, SYSTEM.VAL(SET, tag) + arraybit + mark);
            IF father = NIL THEN EXIT END;
            SYSTEM.GET(SYSTEM.VAL(ADDRESS, father) - 4, tag);
            arraybit := SYSTEM.VAL(SET, tag) * array;
            tag := SYSTEM.VAL(Tag0, SYSTEM.VAL(SET, tag) - (array + mark));
            IF arraybit # {} THEN currElem := father.currElem
            ELSE currElem := father
            END;
            offset := SYSTEM.VAL(ADDRESS, currElem) + SYSTEM.VAL(LONGINT, tag.ptroff - {ArrayBit});
            SYSTEM.GET(offset, field);
            SYSTEM.PUT(offset, block);
            block := father;
            father := field
          END
        ELSE
          offset := SYSTEM.VAL(ADDRESS, currElem) + offset;
          SYSTEM.GET(offset, field);
          IF field # NIL THEN
            SYSTEM.GET(SYSTEM.VAL(ADDRESS, field) - 4, downtag);
            IF subobj * SYSTEM.VAL(SET, field) = {} THEN  (* not a subobject *)
              marked := SYSTEM.VAL(Tag0, SYSTEM.VAL(SET, downtag) + mark);
              IF downtag # marked THEN  (* down *)
                SYSTEM.PUT(SYSTEM.VAL(ADDRESS, field) - 4, marked);
                SYSTEM.PUT(SYSTEM.VAL(ADDRESS, block) - 4, SYSTEM.VAL(SET, tag) + arraybit + mark);
                IF arraybit # {} THEN block.currElem := currElem END;
                SYSTEM.GET(SYSTEM.VAL(ADDRESS, SYSTEM.VAL(SET, downtag) - array) - 4, marked);
                EXCL(SYSTEM.VAL(SET, marked), MarkBit);
                SYSTEM.GET(SYSTEM.VAL(ADDRESS, marked) - 4, arraybit);
                INCL(arraybit, MarkBit);
                SYSTEM.PUT(SYSTEM.VAL(ADDRESS, marked) - 4, arraybit);
                arraybit := SYSTEM.VAL(SET, downtag) * array;
                IF arraybit # {} THEN currElem := field.firstElem ELSE currElem := field END;
                SYSTEM.PUT(offset, father);
                father := block;
                block := field;
                tag := SYSTEM.VAL(Tag0, SYSTEM.VAL(SET, downtag) - arraybit)
              END
            ELSE  (* do not mark subobject *)
              SYSTEM.GET(SYSTEM.VAL(ADDRESS, SYSTEM.VAL(SET, downtag) - array) - 4, marked);
              EXCL(SYSTEM.VAL(SET, marked), MarkBit);
              SYSTEM.GET(SYSTEM.VAL(ADDRESS, marked) - 4, downtag);
              INCL(SYSTEM.VAL(SET, downtag), MarkBit);
              SYSTEM.PUT(SYSTEM.VAL(ADDRESS, marked) - 4, downtag)
            END
          END
        END
      END
    END
  ELSE  (* do not mark subobject, subobjects are not traced *)
    SYSTEM.GET(SYSTEM.VAL(ADDRESS, SYSTEM.VAL(SET, tag) - array) - 4, tag);
    EXCL(SYSTEM.VAL(SET, tag), MarkBit);
    SYSTEM.GET(SYSTEM.VAL(ADDRESS, tag) - 4, arraybit);
    INCL(arraybit, MarkBit);
    SYSTEM.PUT(SYSTEM.VAL(ADDRESS, tag) - 4, arraybit)
  END
END Mark;


PROCEDURE CheckFinObjs;
VAR n: FinObj;  tag: LONGINT;
BEGIN
  n := FinObjs;
  WHILE n # NIL DO
    SYSTEM.GET(n.obj - 4, tag);
    n.marked := MarkBit IN SYSTEM.VAL(SET, tag);
    n := n.next
  END;
  n := FinObjs;
  WHILE n # NIL DO
    IF ~n.marked THEN Mark(SYSTEM.VAL(BlockPtr, n.obj)) END;
    n := n.next
  END
END CheckFinObjs;

PROCEDURE FinalizeObjs;
VAR n, prev: FinObj;
BEGIN
  n := FinObjs;
  WHILE n # NIL DO
    IF ~n.marked THEN
      IF n = FinObjs THEN FinObjs := FinObjs.next ELSE prev.next := n.next END;
      n.fin(SYSTEM.VAL(SYSTEM.PTR, n.obj))
    ELSE prev := n
    END;
    n := n.next
  END
END FinalizeObjs;



(* Sort candidates and mark valid heap pointers *)
PROCEDURE CheckCandidates;
VAR i, j, h, p: LONGINT;  block: Blockm4Ptr;  tag, notmarked, tdesc: Tag;
BEGIN
  (* Shell sort candidates in increasing order *)
  h := 1;  REPEAT h := h*3 + 1 UNTIL h > nofcand;
  REPEAT h := h DIV 3;  i := h;
    WHILE i < nofcand DO
      p := candidates[i];  j := i;
      WHILE (j >= h) & (candidates[j - h] > p) DO
        candidates[j] := candidates[j - h];  j := j - h
      END;
      candidates[j] := p;  INC(i)
    END
  UNTIL h = 1;
  (* Walk heap blocks and mark matching candidates *)
  block := SYSTEM.VAL(Blockm4Ptr, firstBlock);
  i := 0;  p := candidates[i];
  LOOP
    IF p <= SYSTEM.VAL(ADDRESS, block) + 4 THEN
      IF p = SYSTEM.VAL(ADDRESS, block) + 4 THEN Mark(SYSTEM.VAL(BlockPtr, p)) END;
      INC(i);
      IF i = nofcand THEN EXIT END;
      p := candidates[i]
    ELSIF p <= SYSTEM.VAL(ADDRESS, block) + 28 THEN
      IF p = SYSTEM.VAL(ADDRESS, block) + 28 THEN Mark(SYSTEM.VAL(BlockPtr, SYSTEM.VAL(ADDRESS, block) + 4)) END;
      INC(i);
      IF i = nofcand THEN EXIT END;
      p := candidates[i]
    ELSE
      tag := block.tag;
      notmarked := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, tag) - (mark + free));
      tdesc := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, notmarked) - array);
      IF notmarked # tdesc THEN
        h := block.lastElemToMark + tdesc.size - SYSTEM.VAL(ADDRESS, block)
      ELSE
        h := tdesc.size + 4
      END;
      INC(SYSTEM.VAL(ADDRESS, block), SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, h + B-1) - SYSTEM.VAL(SET, B-1)));
      IF block = SYSTEM.VAL(Blockm4Ptr, endBlock) THEN EXIT END
    END
  END;
  nofcand := 0
END CheckCandidates;

(* Check if a stack value could be a valid heap pointer *)
PROCEDURE Candidate(p: LONGINT);
VAR tag, tag0: LONGINT;
BEGIN
  IF (p > firstBlock) & (p < endBlock) THEN
    IF p MOD B = 0 THEN
      SYSTEM.GET(p - 4, tag);
      IF tag MOD 8 IN {0, 2} THEN
        candidates[nofcand] := p;  INC(nofcand);
        IF nofcand = LEN(candidates) THEN CheckCandidates END
      END
    ELSIF p MOD 16 = 8 THEN  (* subobj *)
      SYSTEM.GET(p - 4, tag);
      IF (tag MOD B = 0) & (tag > firstBlock) & (tag < endBlock) THEN
        SYSTEM.GET(tag - 4, tag0);
        IF tag0 = tag THEN
          candidates[nofcand] := p;  INC(nofcand);
          IF nofcand = LEN(candidates) THEN CheckCandidates END
        END
      END
    END
  END
END Candidate;


(* Walk the heap, collect unmarked blocks to free lists *)
PROCEDURE Sweep;
VAR p, endp: Blockm4Ptr;  lastp: FreeBlockPtr;
  tag, notmarked, tdesc: Tag;
  size, lastsize, i: LONGINT;
  lastA: ARRAY N+1 OF ADDRESS;
BEGIN
  i := 0;
  WHILE i <= N DO A[i] := 0;  lastA[i] := SYSTEM.ADR(A[i]);  INC(i) END;
  p := SYSTEM.VAL(Blockm4Ptr, firstBlock);
  endp := SYSTEM.VAL(Blockm4Ptr, endBlock);
  lastsize := 0;
  WHILE p # endp DO
    tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, p.tag) - free);
    notmarked := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, tag) - mark);
    tdesc := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, notmarked) - array);
    IF notmarked # tdesc THEN
      size := p.lastElemToMark + tdesc.size - SYSTEM.VAL(ADDRESS, p)
    ELSE
      size := tdesc.size + 4
    END;
    size := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, size + B-1) - SYSTEM.VAL(SET, B-1));
    IF tag = notmarked THEN  (* collect  not marked *)
      IF lastsize = 0 THEN lastp := SYSTEM.VAL(FreeBlockPtr, p) END;
      INC(lastsize, size)
    ELSE  (* live marked *)
      p.tag := notmarked;  (* clear mark bit *)
      IF lastsize > 0 THEN
        lastp.size := lastsize - 4;
        lastp.tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, SYSTEM.ADR(lastp.size)) + free);
        i := lastsize DIV B;
        IF i > N THEN i := N END;
        lastp.next := 0;
        SYSTEM.PUT(lastA[i], lastp);
        lastA[i] := SYSTEM.ADR(lastp.next);
        lastsize := 0
      END
    END;
    INC(SYSTEM.VAL(ADDRESS, p), size)
  END;
  (* last collected block *)
  IF lastsize > 0 THEN
    lastp.size := lastsize - 4;
    lastp.tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, SYSTEM.ADR(lastp.size)) + free);
    i := lastsize DIV B;
    IF i > N THEN i := N END;
    lastp.next := 0;
    SYSTEM.PUT(lastA[i], lastp);
    lastA[i] := SYSTEM.ADR(lastp.next)
  END
END Sweep;


(* Immediately activate the garbage collector.
  uses SYSTEM.GETREG(13, sp) to read the stack pointer (R13).
  Conservative stack scanning: every 4-byte aligned word on the stack
  that looks like a valid heap pointer is treated as a candidate root. *)

PROCEDURE ^NewSys(VAR p: ADDRESS;  size: LONGINT);

PROCEDURE GC*;
VAR m: Module;  i, p, sp, ptradr: LONGINT;  ptr: BlockPtr;
BEGIN
  IF AlwaysGC OR (GClevel > 0) THEN
    inGC := TRUE;
    (* Mark phase: walk all module roots *)
    m := modules;
    WHILE m # NIL DO
      Mark(SYSTEM.VAL(BlockPtr, m));
      i := LEN(m.ptrTab);
      IF i > 0 THEN ptradr := SYSTEM.ADR(m.ptrTab[0]) END;
      WHILE i > 0 DO
        SYSTEM.GET(ptradr, p);  SYSTEM.GET(p, ptr);
        IF ptr # NIL THEN Mark(ptr) END;
        DEC(i);  INC(ptradr, 4)
      END;
      i := LEN(m.tdescs);
      IF i > 0 THEN ptradr := SYSTEM.ADR(m.tdescs[0]) END;
      WHILE i > 0 DO
        SYSTEM.GET(ptradr, ptr);  Mark(ptr);
        DEC(i);  INC(ptradr, 4)
      END;
      m := m.next
    END;
    (* Conservative stack scanning *)
    IF GCstack THEN
      SYSTEM.GETREG(13, sp);  (* ARM R13 = SP *)
      nofcand := 0;
      WHILE sp < StackOrg DO
        SYSTEM.GET(sp, p);  Candidate(p);  INC(sp, 4)
      END;
      IF nofcand > 0 THEN CheckCandidates END
    END;
    CheckFinObjs;
    Sweep;
    IF (reserve = NIL) & firstTry THEN
      IF LargestAvailable() >= ReserveSize THEN
        NewSys(p, ReserveSize);  reserve := SYSTEM.VAL(BlockPtr, p)
      END
    END;
    inGC := FALSE;
    FinalizeObjs
  END;
  IF break THEN
    break := FALSE;
    SYSTEM.HALT(13)
  END
END GC;

(* Register an object for ref-counted weak finalization *)
PROCEDURE RegisterObject*(obj: SYSTEM.PTR;  fin: Finalizer;  basic: BOOLEAN);
VAR n: FinObj;
BEGIN
  ASSERT(obj # NIL);
  NEW(n);  n.next := FinObjs;  n.obj := SYSTEM.VAL(LONGINT, obj);
  n.marked := FALSE;  n.fin := fin;
  FinObjs := n
END RegisterObject;



(* Find the module containing the given code address *)
PROCEDURE GetMod*(pc: LONGINT): Module;
VAR m: Module;  codeBase, codeTop: LONGINT;
BEGIN
  m := modules;
  WHILE m # NIL DO
    IF m.code # NIL THEN
      codeBase := SYSTEM.ADR(m.code[0]);
      codeTop := codeBase + LEN(m.code^);
      IF (pc >= codeBase) & (pc < codeTop) THEN RETURN m END
    END;
    m := m.next
  END;
  RETURN NIL
END GetMod;

(* Display ARM machine state after a trap.
  Parameters match the x86 TrapHandler signature:
    err = negative exception number or positive HALT code
    fp  = frame pointer (R11) at point of exception
    pc  = program counter at point of exception
    pf  = fault address (Data Abort FAR, or 0) *)
PROCEDURE ShowState(err, fp, pc, pf: LONGINT);
VAR x: LONGINT;  m: Module;  cpsr: SET;
BEGIN
  IF handlingtrap THEN
    WriteString(" [Recursive TRAP]");  WriteLn
  ELSE
    handlingtrap := TRUE;
    WriteLn;
    WriteString("TRAP ");  WriteInt(err, 1);
    WriteChar(" ");  WriteString(version);  WriteLn;
    (* Show key registers *)
    WriteString(" PC=");  WriteHex(pc, 9);
    WriteString(" FP=");  WriteHex(fp, 9);
    WriteString(" SP=");  WriteHex(GetSP(), 9);
    WriteString(" FAR=");  WriteHex(pf, 9);  WriteLn;
    cpsr := GetCPSR();
    WriteString(" CPSR=");  WriteHex(SYSTEM.VAL(LONGINT, cpsr), 9);
    WriteString(" TCK=");  WriteInt(ticks, 1);  WriteLn;
    (* Stack backtrace via R11 frame chain *)
    x := 0;
    LOOP
      m := GetMod(pc);
      IF m = NIL THEN
        WriteString("Unknown PC=");  WriteHex(pc, 9);
        IF x # 0 THEN EXIT END
      ELSE
        WriteString(m.name);  WriteString(" PC=");
        WriteInt(pc - SYSTEM.ADR(m.code[0]), 1)
      END;
      IF fp >= StackOrg THEN EXIT END;
      IF fp = 0 THEN EXIT END;
      SYSTEM.GET(fp + 4, pc);  (* [R11+4] = saved LR = return address *)
      SYSTEM.GET(fp, fp);      (* [R11+0] = saved R11 = previous frame *)
      WriteString(", ");
      INC(x);
      IF x = MaxFrames THEN WriteString("...");  EXIT END
    END;
    WriteLn
  END;
  handlingtrap := FALSE
END ShowState;

(* Install a user trap handler *)
PROCEDURE InstallTrap*(p: TrapHandler);
BEGIN handler := p
END InstallTrap;

(* Install procedure to return to after a trap *)
PROCEDURE InstallLoop*(p: Proc);
BEGIN loop := p
END InstallLoop;

(* Default handler *)
PROCEDURE Unexpected;
BEGIN
  WriteString("Unexpected interrupt, halting"); WriteLn;
  LOOP END
END Unexpected;

(* Install interrupt handler for vector i *)
PROCEDURE InstallIP*(p: Proc;  i: INTEGER);
VAR j: INTEGER;
BEGIN
  IF intHandler[i, 0] = defaultHandler THEN
    intHandler[i, 0] := p  (* overwrite default with user handler *)
  ELSE
    j := 1;
    WHILE intHandler[i, j] # NIL DO INC(j) END;
    ASSERT(j < MaxInts - 1);
    intHandler[i, j + 1] := NIL;
    intHandler[i, j] := p
  END
END InstallIP;

(* Uninstall interrupt handler for vector i. *)
PROCEDURE RemoveIP*(p: Proc;  i: INTEGER);
VAR j: INTEGER;  flags: SET;
BEGIN
  IF p # NIL THEN
    j := 0;
    WHILE (intHandler[i, j] # p) & (intHandler[i, j] # NIL) DO INC(j) END;
    ASSERT(intHandler[i, j] = p)
  ELSE
    ASSERT(intHandler[i, 1] = NIL);
    j := 0
  END;
  flags := GetCPSR();  SYSTEM.CLI();
  REPEAT
    INC(j);  intHandler[i, j - 1] := intHandler[i, j]
  UNTIL intHandler[i, j] = NIL;
  IF intHandler[i, 0] = NIL THEN
    intHandler[i, 0] := defaultHandler
  END;
  SYSTEM.STI()
END RemoveIP;

(* Called from ARM exception vector stubs.
  excNo = ARM exception index (0..7).
  lr    = link register value saved by the stub (points near faulting PC).
  This procedure dispatches to the appropriate Oberon handler. *)
PROCEDURE DispatchException(excNo, lr: LONGINT);
VAR err, pc, fp, pf: LONGINT;
BEGIN
  (* Convert ARM exception to error code *)
  CASE excNo OF
    ExcUndef:         err := -1;  pc := lr - 4  (* LR_und = faulting instr + 4 *)
  | ExcSVC:           err := -2;  pc := lr - 4  (* LR_svc = SVC instr + 4 *)
  | ExcPrefetchAbort: err := -3;  pc := lr - 4  (* LR_abt = faulting instr + 4 *)
  | ExcDataAbort:     err := -4;  pc := lr - 8  (* LR_abt = faulting instr + 8 *)
  | ExcIRQ:           err := -6;  pc := lr - 4  (* LR_irq = next instr + 4 *)
  | ExcFIQ:           err := -7;  pc := lr - 4
  ELSE                err := -excNo;  pc := lr
  END;
  (* Get frame pointer and fault address *)
  fp := GetR11();
  pf := 0;  (* TODO read DFAR/IFAR via MRC for abort exceptions *)
  (* Call trap handlers *)
  IF handler0 # NIL THEN handler0(err, fp, pc, pf) END;
  IF handler # NIL THEN handler(err, fp, pc, pf) END;
  (* If we get here, try to return to the loop procedure *)
  IF (loop # NIL) & ~inGC THEN
    loop()
  ELSE
    WriteString("Trap in kernel, err=");  WriteInt(err, 1);  WriteLn;
    LOOP END
  END
END DispatchException;



PROCEDURE TrapData;
VAR fp, lr: LONGINT;
BEGIN
  fp := GetR11();
  SYSTEM.GET(fp + 4, lr);
  ShowState(4, fp, lr - 8, 0); (* Data Abort LR is Faulting PC + 8 *)
  LOOP END
END TrapData;

PROCEDURE TrapUndef;
VAR fp, lr: LONGINT;
BEGIN
  fp := GetR11();
  SYSTEM.GET(fp + 4, lr);
  ShowState(1, fp, lr - 4, 0); (* Undef LR is Faulting PC + 4 *)
  LOOP END
END TrapUndef;

PROCEDURE TrapOther;
VAR fp, lr: LONGINT;
BEGIN
  fp := GetR11();
  SYSTEM.GET(fp + 4, lr);
  ShowState(99, fp, lr, 0);
  LOOP END
END TrapOther;

PROCEDURE BuildVectorTable;
VAR i, ldrPC, base: LONGINT;
    tUndef, tData, tOther: Proc;
BEGIN
  base := SYSTEM.ADR(vectorTableBuf[0]);
  base := (base + 31) DIV 32 * 32; 
  vectorTableBase := base;
  ldrPC := SYSTEM.VAL(LONGINT, 0E59FF018H);
  
  FOR i := 0 TO NVectors - 1 DO PutWord(base + i * 4, ldrPC) END;
  
  tUndef := TrapUndef;
  tData := TrapData;
  tOther := TrapOther;
  
  PutWord(base + (NVectors + ExcReset) * 4, base); 
  PutWord(base + (NVectors + ExcUndef) * 4, SYSTEM.VAL(LONGINT, tUndef));
  PutWord(base + (NVectors + ExcSVC) * 4, SYSTEM.VAL(LONGINT, tOther));
  PutWord(base + (NVectors + ExcPrefetchAbort) * 4, SYSTEM.VAL(LONGINT, tOther));
  PutWord(base + (NVectors + ExcDataAbort) * 4, SYSTEM.VAL(LONGINT, tData));
  PutWord(base + (NVectors + ExcReserved) * 4, SYSTEM.VAL(LONGINT, tOther));
  PutWord(base + (NVectors + ExcIRQ) * 4, SYSTEM.VAL(LONGINT, tOther));
  PutWord(base + (NVectors + ExcFIQ) * 4, SYSTEM.VAL(LONGINT, tOther));
END BuildVectorTable;

PROCEDURE -SetAbortStack(sp: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 01000H, 0E10FH   (* MRS R1, CPSR *)
  DCW 0201FH, 0E3C1H   (* BIC R2, R1, #0x1F *)
  DCW 02017H, 0E382H   (* ORR R2, R2, #0x17 -> Abort mode *)
  DCW 0F002H, 0E121H   (* MSR CPSR_c, R2 *)
  MOV SP, R0           (* Set SP_abt *)
  DCW 0F001H, 0E121H   (* MSR CPSR_c, R1 (Back to SVC) *)
END SetAbortStack;

PROCEDURE -SetUndefStack(sp: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 01000H, 0E10FH   (* MRS R1, CPSR *)
  DCW 0201FH, 0E3C1H   (* BIC R2, R1, #0x1F *)
  DCW 0201BH, 0E382H   (* ORR R2, R2, #0x1B -> Undef mode *)
  DCW 0F002H, 0E121H   (* MSR CPSR_c, R2 *)
  MOV SP, R0           (* Set SP_und *)
  DCW 0F001H, 0E121H   (* MSR CPSR_c, R1 (Back to SVC) *)
END SetUndefStack;

(* Initialize the ARM interrupt/exception vector table
  and install default handlers. *)
PROCEDURE InitInterrupts;
VAR i, j: INTEGER;
BEGIN
  defaultHandler := Unexpected;
  FOR i := 0 TO IDTSize - 1 DO
    intHandler[i, 0] := defaultHandler;
    FOR j := 1 TO MaxInts - 1 DO intHandler[i, j] := NIL END
  END;
  
  (* Give traps a safe stack so they don't double-fault *)
  SetAbortStack(SYSTEM.ADR(abtStack[63]) + 4);
  SetUndefStack(SYSTEM.ADR(undStack[63]) + 4);
  
  BuildVectorTable;
  SetVBAR(vectorTableBase);
  DataSyncBarrier;
  InstrSyncBarrier
END InitInterrupts;

(* set up the default trap handler *)
PROCEDURE InitTrapHandling;
VAR i: INTEGER;  int: Proc;
BEGIN
  handler0 := ShowState;
  handler := NIL;
  handlingtrap := FALSE;
  loop := NIL
END InitTrapHandling;


(* Return "ticks" since initialisation (TimeUnit ticks per second).
  ticks is incremented by the IRQ handler at TimeUnit Hz. *)
PROCEDURE GetTimer*(): LONGINT;
BEGIN
  RETURN ticks
END GetTimer;

(* Set timer to expire in approximately ms milliseconds. *)
PROCEDURE SetTimer*(VAR t: MilliTimer;  ms: LONGINT);
BEGIN
  IF TimeUnit # 1000 THEN
    ms := ms * TimeUnit DIV 1000
  END;
  t.target := ticks + ms
END SetTimer;

(* Check if a timer has expired. *)
PROCEDURE Expired*(VAR t: MilliTimer): BOOLEAN;
BEGIN
  RETURN ticks - t.target >= 0
END Expired;

(* Construct the IRQ handler as raw machine code in irqStub.
  Layout: 10 ARM instructions + 2 data words = 48 bytes.
  [0]  SUB LR, LR, #4             ; adjust return address
  [1]  STMFD SP!, {R0-R3, R12, LR} ; save on IRQ stack
  [2]  LDR R0, [PC, #24]           ; load &ticks
  [3]  LDR R1, [R0]               ; load ticks value
  [4]  ADD R1, R1, #1             ; increment
  [5]  STR R1, [R0]               ; store back
  [6]  LDR R0, [PC, #12]          ; load timerPeriod
  [7]  MCR p15,0,R0,c14,c2,0      ; reload CNTP_TVAL
  [8]  DSB SY                     ; memory barrier
  [9]  LDMFD SP!, {R0-R3, R12, PC}^ ; restore & return from IRQ
  [10] <address of ticks>          ; data word
  [11] <timerPeriod>               ; data word *)
PROCEDURE BuildIRQStub;
BEGIN

  irqStub[0] := SYSTEM.VAL(LONGINT, 0E24EE004H);   (* SUB LR, LR, #4 *)
  irqStub[1] := SYSTEM.VAL(LONGINT, 0E92D500FH);   (* STMFD SP!, {R0-R3, R12, LR} *)
  irqStub[2] := SYSTEM.VAL(LONGINT, 0E59F0018H);   (* LDR R0, [PC, #24] *)
  irqStub[3] := SYSTEM.VAL(LONGINT, 0E5901000H);   (* LDR R1, [R0] *)
  irqStub[4] := SYSTEM.VAL(LONGINT, 0E2811001H);   (* ADD R1, R1, #1 *)
  irqStub[5] := SYSTEM.VAL(LONGINT, 0E5801000H);   (* STR R1, [R0] *)
  irqStub[6] := SYSTEM.VAL(LONGINT, 0E59F000CH);   (* LDR R0, [PC, #12] *)
  irqStub[7] := SYSTEM.VAL(LONGINT, 0EE0E0F12H);   (* MCR p15,0,R0,c14,c2,0 *)
  irqStub[8] := SYSTEM.VAL(LONGINT, 0F57FF04FH);   (* DSB SY *)
  irqStub[9] := SYSTEM.VAL(LONGINT, 0E8FD900FH);   (* LDMFD SP!, {R0-R3, R12, PC}^ *)
  (* Data words ? patched with runtime addresses *)
  irqStub[10] := SYSTEM.ADR(ticks);                 (* &ticks *)
  irqStub[11] := timerPeriod                        (* reload value *)
END BuildIRQStub;

(* Set up the ARM Generic Timer for periodic interrupts.
  Uses CP15 CNTP_TVAL/CNTP_CTL for the physical timer *)
PROCEDURE InitTimer;
VAR freq: LONGINT;
BEGIN
  ticks := 0;
  (* Read counter frequency *)
  freq := GetCNTFRQ();
  IF freq = 0 THEN freq := 62500000 END;  (* fallback: 62.5 MHz *)
  timerPeriod := freq DIV TimeUnit;  (* ticks per 1ms *)
  (* Set up IRQ mode stack *)
  SetIRQStack(SYSTEM.ADR(irqStack[63]) + 4);
  (* Build the IRQ handler stub *)
  BuildIRQStub;
  (* Install IRQ handler address in vector table *)
  PutWord(vectorTableBase + (NVectors + ExcIRQ) * 4, SYSTEM.ADR(irqStub[0]));
  DataSyncBarrier;
  InstrSyncBarrier;
  (* Set countdown timer *)
  SetCNTPTVAL(timerPeriod);
  (* Enable timer: bit 0 = enable, bit 1 = 0 (not masked) *)
  SetCNTPCTL(1);
  (* Route nsCNTP IRQ to core 0 via BCM2836 ARM local interrupt controller.
    Register at 0x40000040, bit 1 = nsCNTPNSIRQ enable. *)
  PutWord(40000040H, 2);
  (* Enable IRQs in CPSR *)
  SYSTEM.STI()
END InitTimer;

(* Initialise clock (stub: returns fixed dummy time). *)
PROCEDURE InitClock;
BEGIN
  second := 0;  minute := 0;  hour := 12;
  day := 1;  month := 1;  year := 2025
END InitClock;

(* Return current time and date.
  Time format: hr*4096 + min*64 + sec.
  Date format: yr*512 + mo*32 + day. *)
PROCEDURE GetClock*(VAR time, date: LONGINT);
BEGIN
  time := LONG(hour)*4096 + LONG(minute)*64 + LONG(second);
  date := LONG(year-1900)*512 + LONG(month)*32 + LONG(day)
END GetClock;

(* Set current time and date. *)
PROCEDURE SetClock*(time, date: LONGINT);
BEGIN
  hour := SHORT(time DIV 4096 MOD 32);
  minute := SHORT(time DIV 64 MOD 64);
  second := SHORT(time MOD 64);
  year := SHORT(date DIV 512 MOD 128 + 1900);
  month := SHORT(date DIV 32 MOD 16);
  day := SHORT(date MOD 32)
END SetClock;


(* Dump memory as hex + ASCII, 16 bytes per line. *)
PROCEDURE WriteMemory*(adr, size: LONGINT);
VAR i, j: LONGINT;  ch: CHAR;
BEGIN
  size := adr + size - 1;
  FOR i := adr TO size BY 16 DO
    WriteHex(i, 9);
    FOR j := i TO i + 15 DO
      IF j <= size THEN
        SYSTEM.GET(j, ch);
        WriteHex(SYSTEM.VAL(SHORTINT, ch), -3)
      ELSE
        WriteString("   ")
      END
    END;
    WriteChar(" ");
    FOR j := i TO i + 15 DO
      IF j <= size THEN
        SYSTEM.GET(j, ch);
        IF (ch < " ") OR (ch >= CHR(127)) THEN ch := "." END;
        WriteChar(ch)
      END
    END;
    WriteLn
  END
END WriteMemory;


(* Return approximate heap usage in bytes. *)
PROCEDURE Used*(): LONGINT;
BEGIN
  RETURN endBlock - firstBlock - Available()
END Used;

(* Return parameter value from Init string by index. *)
PROCEDURE GetInit*(n: LONGINT;  VAR val: LONGINT);
BEGIN
  IF (n >= 0) & (n < LEN(kpar)) THEN val := kpar[n]
  ELSE val := 0
  END
END GetInit;

(* Retrieve and consume the trace log buffer contents. *)
PROCEDURE GetLog*(VAR val: ARRAY OF CHAR);
VAR i, max: LONGINT;  pass: BOOLEAN;
BEGIN
  i := 0;
  IF traceBufAdr # 0 THEN
    max := LEN(val) - 1;  pass := FALSE;
    WHILE (i < max) & (traceHead # traceTail) DO
      SYSTEM.GET(traceBufAdr + traceHead, val[i]);
      IF traceHead = traceMark THEN pass := TRUE END;
      traceHead := (traceHead + 1) MOD traceBufSize;
      INC(i)
    END;
    IF pass THEN traceMark := traceHead END
  END;
  val[i] := 0X
END GetLog;

(* Set a "mark" in the log. *)
PROCEDURE SetLogMark*;
BEGIN
  traceMark := traceTail
END SetLogMark;

(* Retrieve the section of the log between the last mark and the end. *)
PROCEDURE GetMarkedLog*(VAR val: ARRAY OF CHAR);
VAR i, max: LONGINT;
BEGIN
  i := 0;
  IF traceBufAdr # 0 THEN
    max := LEN(val) - 1;
    WHILE (i < max) & (traceMark # traceTail) DO
      SYSTEM.GET(traceBufAdr + traceMark, val[i]);
      traceMark := (traceMark + 1) MOD traceBufSize;
      INC(i)
    END
  END;
  val[i] := 0X
END GetMarkedLog;

(* Disable GC tracing for a specific pointer field.
  Stub: on ARM without full tracing infrastructure, this is a no-op. *)
PROCEDURE DisableTracing*(recadr, fldadr: ADDRESS);
BEGIN (* stub, tracing infrastructure not implemented on ARM *)
END DisableTracing;

(* install a procedure to execute when a module is freed. *)
PROCEDURE InstallTermHandler*(h: Proc);
VAR codebase, handlerAdr: LONGINT;  m: Module;  found: BOOLEAN;
BEGIN
  m := modules;  handlerAdr := SYSTEM.VAL(LONGINT, h);  found := FALSE;
  WHILE (m # NIL) & ~found DO
    codebase := SYSTEM.ADR(m.code[0]);
    IF (codebase <= handlerAdr) & (handlerAdr <= codebase + LEN(m.code)) THEN found := TRUE
    ELSE m := m.next
    END
  END;
  IF found THEN m.term := h END
END InstallTermHandler;

(*  Execute all object finalizers registered by a module,
  and then execute its termination handler. *)
PROCEDURE FinalizeModule*(m: Module);
VAR h: Proc;  beg, endm: LONGINT;  n, prev: FinObj;
BEGIN
  beg := SYSTEM.ADR(m.code[0]);  endm := beg + LEN(m.code);
  n := FinObjs;
  WHILE n # NIL DO
    IF (beg <= SYSTEM.VAL(LONGINT, n.fin)) & (SYSTEM.VAL(LONGINT, n.fin) <= endm) THEN
      IF n = FinObjs THEN FinObjs := FinObjs.next ELSE prev.next := n.next END;
      n.fin(SYSTEM.VAL(SYSTEM.PTR, n.obj))
    ELSE prev := n
    END;
    n := n.next
  END;
  IF m.term # NIL THEN
    h := m.term;  m.term := NIL;  h
  END
END FinalizeModule;

PROCEDURE MapPhysical*(physAdr, size: LONGINT;  VAR virtAdr: LONGINT);
BEGIN
  virtAdr := physAdr  (* identity mappingmj, no MMU for display access *)
END MapPhysical;

(* Stub: no DMA controller on ARM bare-metal yet; allocates from normal heap. *)
PROCEDURE NewDMA*(size: LONGINT;  VAR adr, phys: ADDRESS);
VAR p: ADDRESS;
BEGIN
  IF size > 0 THEN
    NewSys(p, size);
    adr := p;  phys := p  (* flat mapping, phys = virt *)
  ELSE
    adr := 0;  phys := 0
  END
END NewDMA;

PROCEDURE DisposeDMA*(size: LONGINT;  adr: ADDRESS);
BEGIN (* stub *)
END DisposeDMA;

(* code: 0=running, 1=power off, 2=reboot. *)
PROCEDURE Shutdown*(code: LONGINT);
VAR m: Module;
BEGIN
  shutdown := code;
  m := modules;
  WHILE m # NIL DO
    FinalizeModule(m);
    m := m.next
  END;
  SYSTEM.CLI();
  LOOP END  (* halt *)
END Shutdown;

PROCEDURE Idle*(code: LONGINT);
BEGIN
  (* not implemented *)
END Idle;

(* allocate a block of the given size from the free lists.
  size MOD B = 0. Returns pointer to the block (tag is at ptr-4 offset). *)
PROCEDURE NewBlock(size: LONGINT): InitPtr;
VAR i, rest: LONGINT;  adr, AN: ADDRESS;  ptr: InitPtr;  restptr: FreeBlockPtr;
BEGIN
  IF break THEN break := FALSE;  SYSTEM.HALT(13) END;
  IF size < 0 THEN SYSTEM.HALT(14) END;  (* NEW(p, MAX(LONGINT)) *)
  i := size DIV B;
  IF i > N THEN i := N END;
  adr := SYSTEM.ADR(A[0]) + 4*i;
  AN := SYSTEM.ADR(A[N]);
  LOOP
    SYSTEM.GET(adr, ptr);
    IF adr = AN THEN
      LOOP
        IF ptr = NIL THEN
          IF firstTry THEN
            GC;
            firstTry := FALSE;  ptr := NewBlock(size);  firstTry := TRUE;
            RETURN ptr
          ELSE
            reserve := NIL;  GC;  firstTry := TRUE;  SYSTEM.HALT(14)
          END
        END;
        IF ptr.z0 + 4 >= size THEN EXIT END;
        adr := SYSTEM.ADR(ptr.z1);  SYSTEM.GET(adr, ptr)
      END;
      EXIT
    END;
    IF ptr # NIL THEN EXIT END;
    INC(adr, 4)
  END;
  (* ptr # NIL *)
  SYSTEM.PUT(adr, ptr.z1);
  rest := ptr.z0 + 4 - size;
  restptr := SYSTEM.VAL(FreeBlockPtr, SYSTEM.VAL(ADDRESS, ptr) + size);
  IF rest > 0 THEN  (* >= B >= 16 *)
    i := rest DIV B;
    IF i > N THEN i := N END;
    restptr.tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, SYSTEM.ADR(restptr.size)) + free);
    restptr.size := rest - 4;
    restptr.next := A[i];  A[i] := SYSTEM.VAL(ADDRESS, restptr)
  END;
  RETURN ptr
END NewBlock;

(* Implementation of NEW(ptr). Do not call directly. *)
PROCEDURE NewRec(VAR p: ADDRESS;  tag: Tag);
VAR size: LONGINT;  ptr, init: InitPtr;
BEGIN
  ASSERT(SYSTEM.VAL(LONGINT, tag) MOD 8 = 0);
  IF tag = NIL THEN tag := SYSTEM.VAL(Tag, ptrElemTag) END;
  size := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, tag.size + (4 + B-1)) - SYSTEM.VAL(SET, B-1));
  ptr := NewBlock(size);
  (* Zero-fill the block in 32-byte chunks *)
  init := SYSTEM.VAL(InitPtr, SYSTEM.VAL(ADDRESS, ptr) + size - 32);
  init.z0 := 0;  init.z1 := 0;  init.z2 := 0;  init.z3 := 0;
  init.z4 := 0;  init.z5 := 0;  init.z6 := 0;
  WHILE init # ptr DO
    DEC(SYSTEM.VAL(ADDRESS, init), 32);
    init.z0 := 0;  init.z1 := 0;  init.z2 := 0;  init.z3 := 0;
    init.z4 := 0;  init.z5 := 0;  init.z6 := 0;  init.z7 := 0
  END;
  ptr.tag := tag;
  p := SYSTEM.VAL(ADDRESS, ptr) + 4
END NewRec;

(* implementation of SYSTEM.NEW. Do not call directly. *)
PROCEDURE NewSys(VAR p: ADDRESS;  size: LONGINT);
VAR ptr, init: InitPtr;
BEGIN
  size := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, size + (28 + B-1)) - SYSTEM.VAL(SET, B-1));
  ptr := NewBlock(size);
  init := SYSTEM.VAL(InitPtr, SYSTEM.VAL(ADDRESS, ptr) + size - 32);
  WHILE init # ptr DO
    init.tag := NIL;  init.z0 := 0;  init.z1 := 0;  init.z2 := 0;
    init.z3 := 0;  init.z4 := 0;  init.z5 := 0;  init.z6 := 0;
    DEC(SYSTEM.VAL(ADDRESS, init), 32)
  END;
  ptr.tag := SYSTEM.VAL(Tag, SYSTEM.ADR(ptr.z0));
  ptr.z0 := size - 4;
  ptr.z1 := -4;
  init.z2 := 0;  init.z3 := 0;  init.z4 := 0;
  ptr.z5 := SYSTEM.ADR(ptr.z0);
  init.z6 := 0;
  p := SYSTEM.VAL(ADDRESS, ptr) + 28
END NewSys;

(* implementation of NEW for arrays. Do not call directly. *)
PROCEDURE NewArr(VAR p: ADDRESS;  eltag: Tag;  nofelem, nofdim: LONGINT);
VAR size, firstElem, elSize, arrSize, vectSize: LONGINT;  ptr, init: InitPtr;
BEGIN
  ASSERT(SYSTEM.VAL(LONGINT, eltag) MOD 4 = 0);
  IF eltag = NIL THEN
    eltag := SYSTEM.VAL(Tag, ptrElemTag)
  END;
  elSize := eltag.size;
  arrSize := nofelem * elSize;
  IF arrSize = 0 THEN NewSys(p, nofdim*4 + 12);  RETURN END;
  ASSERT(arrSize > 0);
  vectSize := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 4*nofdim) + SYSTEM.VAL(SET, 4));
  IF eltag.ptroff = -4 THEN  (* no pointers in element type *)
    NewSys(p, arrSize + vectSize + 12);
    SYSTEM.PUT(p, SYSTEM.VAL(SET, arrSize + vectSize + 15) - SYSTEM.VAL(SET, 3));
    RETURN
  END;
  size := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, arrSize + vectSize + (16 + B-1)) - SYSTEM.VAL(SET, B-1));
  ptr := NewBlock(size);
  init := SYSTEM.VAL(InitPtr, SYSTEM.VAL(ADDRESS, ptr) + size - 32);
  WHILE init # ptr DO
    init.tag := NIL;  init.z0 := 0;  init.z1 := 0;  init.z2 := 0;
    init.z3 := 0;  init.z4 := 0;  init.z5 := 0;  init.z6 := 0;
    DEC(SYSTEM.VAL(ADDRESS, init), 32)
  END;
  ptr.tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, eltag) + array);
  firstElem := SYSTEM.ADR(ptr.z3) + vectSize;
  ptr.z0 := firstElem + arrSize - elSize;
  ptr.z2 := firstElem;
  ptr.z3 := 0;  ptr.z4 := 0;  ptr.z5 := 0;  ptr.z6 := 0;
  p := SYSTEM.VAL(ADDRESS, ptr) + 4
END NewArr;


(* Set up ARMv7 MMU with identity mapping (VA = PA).
  Uses L1 section descriptors (1MB each) covering the 4GB address space.
  Memory regions:
    0x00000000 - 0x3BFFFFFF : Normal memory, write-back cacheable, shareable (RAM)
    0x3C000000 - 0x3EFFFFFF : Normal memory, non-cacheable (GPU framebuffer)
    0x3F000000 - 0x3FFFFFFF : Device memory (BCM2835 peripherals)
    0x40000000 - 0x40FFFFFF : Device memory (ARM local peripherals)
    0x41000000 - 0xFFFFFFFF : Fault (unmapped)
  Disables alignment fault checking (SCTLR.A = 0) so unaligned accesses
  are handled by hardware. Enables I-cache and D-cache. *)
PROCEDURE InitMMU;
VAR i, entry, sctlr: LONGINT;  base: ADDRESS;
BEGIN
  (* Align L1 table to 16KB (14 bits) boundary *)
  base := SYSTEM.ADR(l1TableBuf[0]);
  base := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, base + 16383) - {0..13});
  l1TableBase := base;

  (* Build L1 section table: 4096 entries, one per 1MB section *)
  FOR i := 0 TO L1TableSize - 1 DO
    IF i < 03C0H THEN
      (* 0x00000000 - 0x3BFFFFFF: Normal cacheable RAM *)
      entry := (i * 100000H) + L1EntrySection + SectAP + SectNormal + SectShareable + SectDomain0
    ELSIF i < 03F0H THEN
      (* 0x3C000000 - 0x3EFFFFFF: Normal non-cacheable (framebuffer) *)
      entry := (i * 100000H) + L1EntrySection + SectAP + SectNormalNC + SectShareable + SectDomain0
    ELSIF i < 0410H THEN
      (* 0x3F000000 - 0x40FFFFFF: Device memory (peripherals + ARM local) *)
      entry := (i * 100000H) + L1EntrySection + SectAP + SectDevice + SectShareable + SectDomain0
    ELSE
      (* Fault entry: unmapped *)
      entry := 0
    END;
    SYSTEM.PUT(base + i * 4, entry)
  END;

  (* Disable MMU, caches, and alignment check before reconfiguring *)
  sctlr := GetSCTLR();
  sctlr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, sctlr) - {0, 1, 2, 12});
  (* bit 0 = M (MMU), bit 1 = A (alignment), bit 2 = C (D-cache), bit 12 = I (I-cache) *)
  SetSCTLR(sctlr);
  InstrSyncBarrier;

  (* Invalidate TLB and caches *)
  InvalidateTLB;
  InvalidateICache;
  InvalidateDCache;
  DataSyncBarrier;
  InstrSyncBarrier;

  (* Set TTBCR.N = 0: use TTBR0 for entire 4GB address space *)
  SetTTBCR(0);

  (* Set TTBR0 to our L1 table base address.
    Bits [13:0] = 0 (14-bit aligned). Lower bits can specify cache attributes
    for page table walks; we use inner/outer non-cacheable (0) for safety. *)
  SetTTBR0(l1TableBase);

  (* Set DACR: domain 0 = Manager (11b = no permission checks) *)
  SetDACR(3);

  DataSyncBarrier;
  InstrSyncBarrier;

  (* Enable MMU with caches, disable alignment fault.
    bit 0 = M (MMU enable)
    bit 1 = A (alignment fault) - CLEAR to disable alignment checking
    bit 2 = C (D-cache enable)
    bit 12 = I (I-cache enable)
    bit 28 = TEX remap - CLEAR to use TEX/C/B directly *)
  sctlr := GetSCTLR();
  sctlr := SYSTEM.VAL(LONGINT, (SYSTEM.VAL(SET, sctlr) + {0, 2, 12}) - {1, 28});
  SetSCTLR(sctlr);

  DataSyncBarrier;
  InstrSyncBarrier
END InitMMU;


(*  Memory layout:
    [ImageBase .. heapStart]  = boot image (code, data, module descriptors) at 0x8000
    [heapStart .. heapTop]    = free heap
  heapTop was already adjusted by InitTracing (trace buffer at top). *)
PROCEDURE InitHeap;
VAR
  base, heapStart, low0, high1, i, t: LONGINT;
  f: FreeBlockPtr;  m: Module;
  td: POINTER TO RECORD filler: ARRAY 4 OF LONGINT;  name: Name END;
BEGIN
  inGC := FALSE;  break := FALSE;  FinObjs := NIL;  traceheap := {};
  ptrElemTag := 0;

  (* Find ptrElemTag from module type descriptors.
    The linker patches 'modules' to point to the Kernel ModuleDesc. *)
  m := modules;
  WHILE (m # NIL) & (m.name # "Kernel") DO m := m.next END;
  IF m # NIL THEN
    IF m.tdescs # NIL THEN
      i := LEN(m.tdescs);
      WHILE (i > 0) & (ptrElemTag = 0) DO
        DEC(i);  t := m.tdescs[i];  SYSTEM.GET(t - 4, td);
        IF td.name = "PtrElemDesc" THEN ptrElemTag := t END
      END
    END
  END;

  (* Get heap boundaries from image header *)
  base := GetWord(ImageBase + 4);      (* LinkBase *)
  heapStart := GetWord(base + 8);      (* HeapStart ? first free byte after image *)

  (* the linker sets SP = HeapStart (top of image).
    The stack grows dwn from SP.  We must not allocate heap memory that
    overlaps the stack.  StackOrg (captured at module body entry) is the
    initial SP value.  Advance heapStart past the stack region. *)
  IF heapStart < StackOrg THEN heapStart := StackOrg END;

  (* Align low boundary to B-byte boundary, offset by 4 for tag word *)
  low0 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, heapStart + 4 + B-1) - SYSTEM.VAL(SET, B-1)) - 4;

  (* High boundary: heapTop already adjusted by InitTracing *)
  high1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, heapTop - 1) - SYSTEM.VAL(SET, B-1)) - 4;

  IF high1 <= low0 + 2*B THEN
    WriteString("FATAL: not enough heap"); WriteLn;  SYSTEM.HALT(14)
  END;

  firstBlock := low0;  (* must be aligned block start, not raw heapStart *)
  endBlock := high1;
  (* StackOrg captured at module body entry via GetSP() *)

  (* Initialize free list array *)
  FOR i := 0 TO N DO A[i] := 0 END;

  (* Initialize the free block header (only 12 bytes, not clearing entire heap).
    NewBlock/NewRec/NewSys/NewArr zero-fill allocated blocks individually. *)
  SYSTEM.PUT(low0, 0);  (* tag placeholder *)
  SYSTEM.PUT(low0 + 4, 0);  (* size placeholder *)
  SYSTEM.PUT(low0 + 8, 0);  (* next placeholder *)

  (* Create single initial free block spanning the entire heap *)
  f := SYSTEM.VAL(FreeBlockPtr, low0);
  f.tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, SYSTEM.ADR(f.size)) + free);
  f.size := high1 - low0 - 4;
  f.next := 0;
  A[N] := SYSTEM.VAL(ADDRESS, f);

  (* Initialize allocator state *)
  reserve := NIL;  firstTry := TRUE;
  GClevel := 0;  GCstack := TRUE;

END InitHeap;


PROCEDURE InitRuntime;
VAR
  newRec: PROCEDURE(VAR p: ADDRESS;  tag: Tag);
  newSys: PROCEDURE(VAR p: ADDRESS;  size: LONGINT);
  newArr: PROCEDURE(VAR p: ADDRESS;  eltag: Tag;  nofelem, nofdim: LONGINT);
BEGIN
  newRec := NewRec;
  newSys := NewSys;
  newArr := NewArr;
  runtime[0] := SYSTEM.VAL(ADDRESS, newRec);  (* entry 253 *)
  runtime[1] := SYSTEM.VAL(ADDRESS, newSys);  (* entry 252 *)
  runtime[2] := SYSTEM.VAL(ADDRESS, newArr);  (* entry 251 *)
END InitRuntime;


BEGIN
  (* capture stack top immediately *)
  StackOrg := GetSP();

  (* VFP software configuration.
    Hardware enable (CPACR + FPEXC) is done by the linker preamble.
    Here we configure FPSCR: clear exception trap enables (bits 8-12),
    rounding mode (bits 22-23), flush-to-zero (bit 24);
    set default NaN (bit 25) for consistent NaN handling. *)
  copro := TRUE;
  SetFPSCR((GetFPSCR() - {8..12, 22, 23, 24}) + {25});

  tspeed := 0;  tbase := 0;  traceBufAdr := 0;  timer := NIL;
  traceConsole := FALSE;  shutdown := 0;  ticks := 0;

  ReadBootTable;
  CheckMemory;
  heapTop := memTop;

  InitMMU;

  InitTracing(heapTop);

  version := "ARM Native v2.3.7";
  WriteString("ETH Oberon / ");  WriteString(version);  WriteLn;

  EnableGC := DefaultEnableGC;
  DisableGC := DefaultDisableGC;

  InitHeap;
  InitRuntime;

  InitInterrupts;
  InitTrapHandling;

  InitTimer;
  InitClock;

END Kernel.
