 MODULE Kernel;
(*
 * Port of the ETH Native Oberon System 3 v2.3.7 inner core to RISC-V RV32IMAF.
 * Target: Olimex ESP32-P4-PC board 
 * Testing: QEMU qemu-system-riscv32 -machine virt -semihosting
 *
 * Migrated from the ARMv7 version for Raspberry Pi 3B/Zero 2.
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
  (* Heap/GC constants - same as ARM version *)
  B = 32;
  N = 9;
  MarkBit = 0;  ArrayBit = 1;  FreeBit = 2;  SubObjBit = 3;
  mark = {MarkBit};  array = {ArrayBit};  free = {FreeBit};  subobj = {SubObjBit};
  ReserveSize = 65536 - 8;
  DefaultStackSize = 128*1024;
  AlwaysGC = TRUE;

  (* Platform constants for RV32 / ESP32-P4 *)
  DefaultRAMSize = 0C0000000H;  (* ImageBase + 1GB for QEMU virt *)
  BootStackSize = 8192;
  ImageBase = 80000000H;  (* must match multibootlinker --base argument; QEMU virt RAM *)
  TimeUnit* = 1000;
  LittleEndian* = TRUE;
  LsbIs0* = TRUE;

  (* RISC-V trap cause codes (mcause values) *)
  ExcInstrMisalign = 0;  ExcInstrFault = 1;  ExcIllegal = 2;
  ExcBreakpoint = 3;  ExcLoadMisalign = 4;  ExcLoadFault = 5;
  ExcStoreMisalign = 6;  ExcStoreFault = 7;
  ExcEcallU = 8;  ExcEcallS = 9;  ExcEcallM = 11;
  ExcInstrPage = 12;  ExcLoadPage = 13;  ExcStorePage = 15;
  (* Interrupt causes (mcause bit 31 = 1) *)
  IntMSoftware = 3;  IntMTimer = 7;  IntMExternal = 11;

  IRQ* = 32;
  MaxInts = 4;
  IDTSize = 48;
  MaxFrames = 10;

  (* QEMU virt machine CLINT addresses *)
  CLINTBase = 02000000H;
  MTimeCmpLo = 02004000H;  (* mtimecmp low 32 bits *)
  MTimeCmpHi = 02004004H;  (* mtimecmp high 32 bits *)
  MTimeLo = 0200BFF8H;     (* mtime low 32 bits *)
  MTimeHi = 0200BFFCH;     (* mtime high 32 bits *)

  (* QEMU virt NS16550A UART *)
  QemuUartBase = 10000000H;
  QemuUartTHR = 10000000H;   (* Transmit Holding Register *)
  QemuUartLSR = 10000005H;   (* Line Status Register *)

  (* ESP32-P4 USB Serial JTAG console *)
  ESP32UsbBase = 500D2000H;  (* DR_REG_USB_SERIAL_JTAG_BASE *)
  ESP32UsbEP1 = 500D2000H;  (* EP1 data register *)
  ESP32UsbConf = 500D2004H;  (* EP1 config register *)

  LogNone = 0; LogUart = 1; LogSemi = 2; LogEspUsb = 3;

  (* RISC-V CSR addresses for reference *)
  csrMstatus = 300H;
  csrMie = 304H;
  csrMtvec = 305H;
  csrMscratch = 340H;
  csrMepc = 341H;
  csrMcause = 342H;
  csrMtval = 343H;
  csrMip = 344H;
  csrFcsr = 003H;

TYPE
  ADDRESS = LONGINT;
  Name* = ARRAY 32 OF CHAR;
  Proc* = PROCEDURE;

  (* Module descriptor, must match multibootlinker's DumpModuleDesc layout *)
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
  ModuleDesc* = RECORD
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

  Tag = POINTER TO TypeDesc;
  TypeDesc = RECORD
    size: LONGINT;
    ptroff: LONGINT
  END;

  FreeBlockPtr = POINTER TO FreeBlock;
  FreeBlock = RECORD
    tag: Tag;
    size: LONGINT;
    next: ADDRESS
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
  PtrElemDesc = RECORD a: SYSTEM.PTR END;

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
  version*: ARRAY 32 OF CHAR;
  modules*: Module;
  StackOrg*: ADDRESS;
  bt*: ADDRESS;
  tspeed*: LONGINT;
  tbase*: INTEGER;
  break*: BOOLEAN;
  copro*: BOOLEAN;
  inGC*: BOOLEAN;
  logMode: SHORTINT;
  EnableGC*, DisableGC*: Proc;
  timer*: Proc;
  runtime*: ARRAY 3 OF ADDRESS;
  shutdown*: LONGINT;
  ticks*: LONGINT;

  memTop, heapTop: ADDRESS;
  firstBlock, endBlock: ADDRESS;
  A: ARRAY N+1 OF ADDRESS;
  reserve: BlockPtr;
  ptrElemTag: ADDRESS;
  candidates: ARRAY 1024 OF ADDRESS;
  nofcand: INTEGER;
  firstTry: BOOLEAN;
  GCstack: BOOLEAN;
  FinObjs: FinObj;
  traceheap: SET;
  GClevel: LONGINT;

  traceBufAdr, traceBufSize, traceHead, traceTail, traceMark: LONGINT;

  configadr: ADDRESS;
  cmdlineBuf: ARRAY 1024 OF CHAR;
  kpar: ARRAY 16 OF LONGINT;

  handler0, handler: TrapHandler;
  handlingtrap: BOOLEAN;
  loop: Proc;
  intHandler: ARRAY IDTSize, MaxInts OF Proc;
  defaultHandler: Proc;

  (* RISC-V trap handler state *)
  trapStack: ARRAY 4096 OF LONGINT;
  trapStackTop: LONGINT;
  trapSPSR: LONGINT;  (* saved mstatus at trap *)
  trapHandlerBuf: ARRAY 128 OF LONGINT;  (* machine code for trap entry *)
  trapHandlerBase: ADDRESS;
  scratchBuf: ARRAY 16 OF LONGINT;  (* scratch area pointed to by mscratch *)

  timerPeriod: LONGINT;

  second, minute, hour, day, month, year: INTEGER;


(* Read a 32-bit word from an absolute memory address. *)
PROCEDURE GetWord(adr: LONGINT): LONGINT;
VAR val: LONGINT;
BEGIN
  SYSTEM.GET(adr, val);
  RETURN val
END GetWord;

(* Write a 32-bit word to an absolute memory address. *)
PROCEDURE PutWord(adr, val: LONGINT);
BEGIN
  SYSTEM.PUT(adr, val)
END PutWord;

(* Return current stack pointer (x2/sp) *)
PROCEDURE -GetSP(): LONGINT;
CODE {SYSTEM.riscv}
  DCD 000010513H (* MV a0, sp = ADDI a0, sp, 0 *)
END GetSP;

(* Return current frame pointer (x8/s0). *)
PROCEDURE -GetFP(): LONGINT;
CODE {SYSTEM.riscv}
  DCD 000040513H (* MV a0, s0 = ADDI a0, s0, 0 *)
END GetFP;

(* Read mstatus CSR *)
PROCEDURE -GetMStatus(): SET;
CODE {SYSTEM.riscv}
  DCD 030002573H (* CSRRS a0, mstatus, x0 *)
END GetMStatus;

(* Write mstatus CSR from a0.
   Inline arg on stack: val at [SP]. *)
PROCEDURE -SetMStatus(val: SET);
CODE {SYSTEM.riscv}
  LW a0, 0(sp)
  DCD 030051073H (* CSRRW x0, mstatus, a0 *)
  ADDI sp, sp, 4
END SetMStatus;

(* Set mtvec CSR, trap vector base address *)
PROCEDURE -SetMTVEC(adr: LONGINT);
CODE {SYSTEM.riscv}
  LW a0, 0(sp)
  DCD 030551073H (* CSRRW x0, mtvec, a0 *)
  ADDI sp, sp, 4
END SetMTVEC;

(* Read mtvec CSR *)
PROCEDURE -GetMTVEC(): LONGINT;
CODE {SYSTEM.riscv}
  DCD 030502573H (* CSRRS a0, mtvec, x0 *)
END GetMTVEC;

(* Write mscratch CSR *)
PROCEDURE -SetMScratch(adr: LONGINT);
CODE {SYSTEM.riscv}
  LW a0, 0(sp)
  DCD 034051073H (* CSRRW x0, mscratch, a0 *)
  ADDI sp, sp, 4
END SetMScratch;

(* Spin forever *)
PROCEDURE -Spin;
CODE {SYSTEM.riscv}
  DCD 010500073H (* WFI *)
  DCD 0FFDFF06FH (* JAL x0, -4 *)
END Spin;

(* store val to absolute address adr *)
PROCEDURE -MmioPut(adr, val: LONGINT);
CODE {SYSTEM.riscv}
  LW a1, 0(sp)
  LW a0, 4(sp)
  SW a1, 0(a0)
  ADDI sp, sp, 8
END MmioPut;

(* load 32-bit value from absolute address adr *)
PROCEDURE -MmioGet(adr: LONGINT): LONGINT;
CODE {SYSTEM.riscv}
  LW a0, 0(sp)
  LW a0, 0(a0)
  ADDI sp, sp, 4
END MmioGet;

PROCEDURE -DataSyncBarrier;
CODE {SYSTEM.riscv}
  FENCE
END DataSyncBarrier;

(* instruction cache barrier *)
PROCEDURE -InstrSyncBarrier;
CODE {SYSTEM.riscv}
  DCD 00000100FH (* FENCE.I *)
END InstrSyncBarrier;

PROCEDURE -GetFCSR(): SET;
CODE {SYSTEM.riscv}
  DCD 000302573H (* CSRRS a0, fcsr, x0 *)
END GetFCSR;

PROCEDURE -SetFCSR(val: SET);
CODE {SYSTEM.riscv}
  LW a0, 0(sp)
  DCD 000351073H (* CSRRW x0, fcsr, a0 *)
  ADDI sp, sp, 4
END SetFCSR;

(* RISC-V semihosting: write a single character.
   Parameter ch is at 0(sp) in inline procedures. *)
PROCEDURE -SemiWriteChar(ch: CHAR);
CODE {SYSTEM.riscv}
  MV a1, sp
  ADDI a0, x0, 3
  DCD 001F01013H (* SLLI x0, x0, 0x1f *)
  EBREAK
  DCD 040705013H (* SRAI x0, x0, 7 *)
  ADDI sp, sp, 4
END SemiWriteChar;

(* Write a NUL-terminated string via semihosting (SYS_WRITE0 = 0x04).
   Parameter adr is at 0(sp). *)
PROCEDURE -SemiWrite0(adr: LONGINT);
CODE {SYSTEM.riscv}
  LW a1, 0(sp)
  ADDI a0, x0, 4
  DCD 001F01013H (* SLLI x0, x0, 0x1f *)
  EBREAK
  DCD 040705013H (* SRAI x0, x0, 7 *)
  ADDI sp, sp, 4
END SemiWrite0;

(* Write character to QEMU NS16550A UART *)
PROCEDURE QemuUartWriteC(c: CHAR);
VAR status: LONGINT;
BEGIN
  IF c = 0AX THEN QemuUartWriteC(0DX) END;
  REPEAT
    status := MmioGet(QemuUartLSR)
  UNTIL SYSTEM.VAL(SET, status) * {5} # {};  (* bit 5 = THR empty *)
  MmioPut(QemuUartTHR, ORD(c))
END QemuUartWriteC;

(* Write character to ESP32-P4 USB Serial JTAG console *)
PROCEDURE EspUsbWriteC(c: CHAR);
VAR status: LONGINT;
BEGIN
  IF c = 0AX THEN EspUsbWriteC(0DX) END;
  REPEAT
    status := MmioGet(ESP32UsbConf)
  UNTIL SYSTEM.VAL(SET, status) * {1} # {};  (* bit 1 = FIFO free *)
  MmioPut(ESP32UsbEP1, ORD(c));
  MmioPut(ESP32UsbConf, 1)  (* commit byte *)
END EspUsbWriteC;

(* Unified character output *)
PROCEDURE WriteChar*(c: CHAR);
BEGIN
  IF logMode = LogSemi THEN SemiWriteChar(c)
  ELSIF logMode = LogUart THEN QemuUartWriteC(c)
  ELSIF logMode = LogEspUsb THEN EspUsbWriteC(c)
  END
END WriteChar;

PROCEDURE WriteString*(s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  IF logMode = LogSemi THEN SemiWrite0(SYSTEM.ADR(s[0]))
  ELSE i := 0;  WHILE s[i] # 0X DO WriteChar(s[i]);  INC(i) END
  END
END WriteString;

PROCEDURE WriteLn*;
BEGIN WriteChar(0DX);  WriteChar(0AX)
END WriteLn;

PROCEDURE Hello*(s: ARRAY OF CHAR);
BEGIN
  WriteString(s); WriteLn
END Hello;

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


(* Initialize console output for QEMU virt or ESP32-P4. *)
PROCEDURE InitLog;
VAR s: ARRAY 8 OF CHAR;
BEGIN
  GetConfig("TracePort", s);
  IF s = "0" THEN logMode := LogNone
  ELSIF s = "1" THEN logMode := LogUart  (* QEMU NS16550A *)
  ELSIF s = "2" THEN logMode := LogSemi  (* QEMU semihosting *)
  ELSIF s = "3" THEN logMode := LogEspUsb  (* ESP32-P4 USB-JTAG *)
  ELSE logMode := LogNone
  END
END InitLog;


(* Parse the image header and extract configuration.
   On RISC-V, the boot info pointer may be passed in a1 (x11)
   by the multibootlinker preamble (pushed onto stack).
   For QEMU virt, a1 typically points to a device tree blob. *)
PROCEDURE ReadBootTable;
VAR
  base, ramSize: LONGINT;
  i: INTEGER;
BEGIN
  (* Multibootlinker header layout at ImageBase:
       +0: JAL x0, entry    +4: LinkBase    +8: HeapStart
      +12: ImageSize        +16: RAMSize *)
  base := GetWord(ImageBase + 4);  (* read LinkBase from image header *)
  ramSize := GetWord(base + 16);   (* read RAMSize from header *)
  IF ramSize > 0 THEN memTop := ImageBase + ramSize
  ELSE memTop := DefaultRAMSize
  END;

  (* On RV32/QEMU, there are no ATAGS. Use built-in default config. *)
  cmdlineBuf[0] := 0X;
  configadr := SYSTEM.ADR(cmdlineBuf[0]);

  (* Default config: semihosting output for QEMU *)
  logMode := LogSemi;
  WriteString("Kernel: using default boot config (semihosting)"); WriteLn;

  i := 0;
  cmdlineBuf[i] := "D"; INC(i); cmdlineBuf[i] := "i"; INC(i);
  cmdlineBuf[i] := "s"; INC(i); cmdlineBuf[i] := "k"; INC(i);
  cmdlineBuf[i] := "D"; INC(i); cmdlineBuf[i] := "e"; INC(i);
  cmdlineBuf[i] := "v"; INC(i); cmdlineBuf[i] := "i"; INC(i);
  cmdlineBuf[i] := "c"; INC(i); cmdlineBuf[i] := "e"; INC(i);
  cmdlineBuf[i] := 0X; INC(i);
  cmdlineBuf[i] := "S"; INC(i); cmdlineBuf[i] := "D"; INC(i);
  cmdlineBuf[i] := "0"; INC(i);
  cmdlineBuf[i] := 0X; INC(i);
  cmdlineBuf[i] := "T"; INC(i); cmdlineBuf[i] := "r"; INC(i);
  cmdlineBuf[i] := "a"; INC(i); cmdlineBuf[i] := "c"; INC(i);
  cmdlineBuf[i] := "e"; INC(i); cmdlineBuf[i] := "P"; INC(i);
  cmdlineBuf[i] := "o"; INC(i); cmdlineBuf[i] := "r"; INC(i);
  cmdlineBuf[i] := "t"; INC(i);
  cmdlineBuf[i] := 0X; INC(i);
  cmdlineBuf[i] := "2"; INC(i);  (* semihosting *)
  cmdlineBuf[i] := 0X; INC(i);
  cmdlineBuf[i] := "A"; INC(i); cmdlineBuf[i] := "o"; INC(i);
  cmdlineBuf[i] := "s"; INC(i); cmdlineBuf[i] := "F"; INC(i);
  cmdlineBuf[i] := "S"; INC(i);
  cmdlineBuf[i] := 0X; INC(i);
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
  cmdlineBuf[i] := 0X; INC(i);
  cmdlineBuf[i] := "S"; INC(i); cmdlineBuf[i] := "y"; INC(i);
  cmdlineBuf[i] := "s"; INC(i); cmdlineBuf[i] := "t"; INC(i);
  cmdlineBuf[i] := "e"; INC(i); cmdlineBuf[i] := "m"; INC(i);
  cmdlineBuf[i] := "."; INC(i); cmdlineBuf[i] := "I"; INC(i);
  cmdlineBuf[i] := "n"; INC(i); cmdlineBuf[i] := "i"; INC(i);
  cmdlineBuf[i] := "t"; INC(i);
  cmdlineBuf[i] := 0X; INC(i);
  cmdlineBuf[i] := 0X
END ReadBootTable;

PROCEDURE CheckMemory;
BEGIN
  IF memTop > DefaultRAMSize THEN memTop := DefaultRAMSize END
END CheckMemory;


PROCEDURE Fill4(dst, count, filler: LONGINT);
BEGIN
  WHILE count > 0 DO
    SYSTEM.PUT(dst, filler);
    INC(dst, 4);  DEC(count)
  END
END Fill4;


(* Heap Allocator and Garbage Collector, identical to ARM version *)
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


PROCEDURE Mark(block: BlockPtr);
TYPE Tag0 = POINTER TO RECORD ptroff: SET END;
VAR father, field, currElem: BlockPtr;
  offset: LONGINT;
  tag, downtag, marked: Tag0;
  arraybit: SET;
BEGIN
  SYSTEM.GET(SYSTEM.VAL(ADDRESS, block) - 4, tag);
  IF ~(SubObjBit IN SYSTEM.VAL(SET, block)) THEN
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
          ELSE
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
            IF subobj * SYSTEM.VAL(SET, field) = {} THEN
              marked := SYSTEM.VAL(Tag0, SYSTEM.VAL(SET, downtag) + mark);
              IF downtag # marked THEN
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
            ELSE
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
  ELSE
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


PROCEDURE CheckCandidates;
VAR i, j, h, p: LONGINT;  block: Blockm4Ptr;  tag, notmarked, tdesc: Tag;
BEGIN
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
    ELSIF p MOD 16 = 8 THEN
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
    IF tag = notmarked THEN
      IF lastsize = 0 THEN lastp := SYSTEM.VAL(FreeBlockPtr, p) END;
      INC(lastsize, size)
    ELSE
      p.tag := notmarked;
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


PROCEDURE ^NewSys(VAR p: ADDRESS;  size: LONGINT);

PROCEDURE GC*;
VAR m: Module;  i, p, sp, ptradr: LONGINT;  ptr: BlockPtr;
BEGIN
  IF AlwaysGC OR (GClevel > 0) THEN
    inGC := TRUE;
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
    IF GCstack THEN
      SYSTEM.GETREG(2, sp);  (* RV32: x2 = SP *)
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

PROCEDURE RegisterObject*(obj: SYSTEM.PTR;  fin: Finalizer;  basic: BOOLEAN);
VAR n: FinObj;
BEGIN
  ASSERT(obj # NIL);
  NEW(n);  n.next := FinObjs;  n.obj := SYSTEM.VAL(LONGINT, obj);
  n.marked := FALSE;  n.fin := fin;
  FinObjs := n
END RegisterObject;


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

(* Display RISC-V machine state after a trap.
   RV32 frame layout: [s0+0]=param1, [s0-4]=saved_ra, [s0-8]=saved_s0 *)
PROCEDURE ShowState(err, fp, pc, pf: LONGINT);
VAR x: LONGINT;  m: Module;
BEGIN
  IF handlingtrap THEN
    WriteString(" [Recursive TRAP]");  WriteLn
  ELSE
    handlingtrap := TRUE;
    WriteLn;
    WriteString("TRAP ");  WriteInt(err, 1);
    WriteChar(" ");  WriteString(version);  WriteLn;
    WriteString(" PC=");  WriteHex(pc, 9);
    WriteString(" FP=");  WriteHex(fp, 9);
    WriteString(" SP=");  WriteHex(GetSP(), 9);
    WriteString(" FAR=");  WriteHex(pf, 9);  WriteLn;
    WriteString(" MSTATUS=");  WriteHex(SYSTEM.VAL(LONGINT, trapSPSR), 9);
    WriteString(" TCK=");  WriteInt(ticks, 1);  WriteLn;
    (* Stack backtrace via s0 frame chain.
       RV32 frame: [s0-4] = saved ra (return address)
                   [s0-8] = saved s0 (previous frame pointer)
       s0 points to base of locals, above saved ra/s0. *)
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
      SYSTEM.GET(fp - 4, pc);  (* [s0-4] = saved ra = return address *)
      SYSTEM.GET(fp - 8, fp);  (* [s0-8] = saved s0 = previous frame *)
      WriteString(", ");
      INC(x);
      IF x = MaxFrames THEN WriteString("...");  EXIT END
    END;
    WriteLn
  END;
  handlingtrap := FALSE
END ShowState;

PROCEDURE InstallTrap*(p: TrapHandler);
BEGIN handler := p
END InstallTrap;

PROCEDURE InstallLoop*(p: Proc);
BEGIN loop := p
END InstallLoop;

PROCEDURE Unexpected;
BEGIN
  WriteString("Unexpected interrupt, halting"); WriteLn;
  LOOP END
END Unexpected;

PROCEDURE InstallIP*(p: Proc;  i: INTEGER);
VAR j: INTEGER;
BEGIN
  IF intHandler[i, 0] = defaultHandler THEN
    intHandler[i, 0] := p
  ELSE
    j := 1;
    WHILE intHandler[i, j] # NIL DO INC(j) END;
    ASSERT(j < MaxInts - 1);
    intHandler[i, j + 1] := NIL;
    intHandler[i, j] := p
  END
END InstallIP;

PROCEDURE RemoveIP*(p: Proc;  i: INTEGER);
VAR j: INTEGER;
BEGIN
  IF p # NIL THEN
    j := 0;
    WHILE (intHandler[i, j] # p) & (intHandler[i, j] # NIL) DO INC(j) END;
    ASSERT(intHandler[i, j] = p)
  ELSE
    ASSERT(intHandler[i, 1] = NIL);
    j := 0
  END;
  SYSTEM.CLI();
  REPEAT
    INC(j);  intHandler[i, j - 1] := intHandler[i, j]
  UNTIL intHandler[i, j] = NIL;
  IF intHandler[i, 0] = NIL THEN
    intHandler[i, 0] := defaultHandler
  END;
  SYSTEM.STI()
END RemoveIP;

(* Restart the main loop after a trap *)
PROCEDURE RestartLoop(newsp, ip: LONGINT);
BEGIN
  (* Enable interrupts via CSR *)
  SetMStatus(GetMStatus() + {3});  (* set MIE bit *)
  SYSTEM.PUTREG(2, newsp);   (* SP = newsp *)
  SYSTEM.PUTREG(8, 0);       (* s0/FP = 0 *)
  (* Jump to ip - use inline asm to avoid normal return *)
END RestartLoop;

(* trap dispatcher, called from the machine-code trap handler with:
     excNo = exception/interrupt number
     pc = faulting PC (mepc)
     mstat = saved mstatus *)
PROCEDURE DispatchException(excNo, pc, mstat: LONGINT);
VAR err, fp, pf: LONGINT;
BEGIN
  SYSTEM.STI();  

  SetFCSR(GetFCSR() * {5..31});  (* clear exception flags bits 0-4 *)

  trapSPSR := mstat;
  err := excNo;
  fp := GetFP();
  pf := 0;

  (* Step back one frame to get the faulting context *)
  IF fp # 0 THEN SYSTEM.GET(fp - 8, fp) END;

  IF handler0 # NIL THEN handler0(err, fp, pc, pf) END;
  IF handler # NIL THEN handler(err, fp, pc, pf) END;

  IF (loop # NIL) & ~inGC THEN
    RestartLoop(StackOrg, SYSTEM.VAL(LONGINT, loop))
  ELSE
    WriteString("Trap in kernel, err=");  WriteInt(err, 1);  WriteLn;
    LOOP END
  END
END DispatchException;


(* Build the RISC-V trap handler as machine code.
   On RISC-V, all traps go through mtvec. The handler must:
   1. Save registers to mscratch-based scratch area
   2. Read mcause to determine trap type
   3. For timer interrupt: increment ticks, reload mtimecmp, mret
   4. For exceptions: switch to trap stack, call DispatchException

   The trap handler is built as raw machine code in trapHandlerBuf.
   We use a simplified approach: save minimal context, handle timer
   interrupt inline, and dispatch exceptions to Oberon code.

   Register usage in trap handler:
     t0 (x5) = scratch
     t1 (x6) = scratch
     mscratch = saved sp *)
PROCEDURE BuildTrapHandler;
VAR base: LONGINT;
BEGIN
  base := SYSTEM.ADR(trapHandlerBuf[0]);
  base := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, base + 3) - {0, 1});
  trapHandlerBase := base;

  SYSTEM.PUT(base + 0, 0340292F3H); (* CSRRW t0, mscratch, t0  *)
  SYSTEM.PUT(base + 4, 00022A023H); (* SW sp, 0(t0) *)
  SYSTEM.PUT(base + 8, 000A2A223H); (* SW a0, 4(t0) *)
  SYSTEM.PUT(base + 12, 000B2A423H); (* SW a1, 8(t0) *)
  SYSTEM.PUT(base + 16, 00012A623H); (* SW ra, 12(t0) *)
  SYSTEM.PUT(base + 20, 000C2A823H); (* SW a2, 16(t0)  *)
  SYSTEM.PUT(base + 24, 034202573H); (* CSRRS a0, mcause, x0 *)
  SYSTEM.PUT(base + 28, 002054663H); (* BLT a0, x0, +44, branch to [18] *)

  (* Exception path *)
  SYSTEM.PUT(base + 32, 0341025F3H); (* CSRRS a1, mepc, x0 *)
  SYSTEM.PUT(base + 36, 030002673H); (* CSRRS a2, mstatus, x0 *)
  SYSTEM.PUT(base + 40, 00142A103H); (* LW sp, 20(t0) *)
  SYSTEM.PUT(base + 44, 0FF410113H); (* ADDI sp, sp, -12 *)
  SYSTEM.PUT(base + 48, 000A12423H); (* SW a0, 8(sp) *)
  SYSTEM.PUT(base + 52, 000B12223H); (* SW a1, 4(sp) *)
  SYSTEM.PUT(base + 56, 000C12023H); (* SW a2, 0(sp) *)
  SYSTEM.PUT(base + 60, 00182A503H); (* LW a0, 24(t0) *)
  SYSTEM.PUT(base + 64, 0000500E7H); (* JALR ra, a0, 0 *)
  SYSTEM.PUT(base + 68, 0FFDFF06FH); (* JAL x0, -4, infinite loop *)

  (* Interrupt path: restore and MRET *)
  SYSTEM.PUT(base + 72, 00102A603H); (* [18] LW a2, 16(t0) *)
  SYSTEM.PUT(base + 76, 000C2A083H); (* LW ra, 12(t0) *)
  SYSTEM.PUT(base + 80, 00082A583H); (* LW a1, 8(t0) *)
  SYSTEM.PUT(base + 84, 00042A503H); (* LW a0, 4(t0) *)
  SYSTEM.PUT(base + 88, 00002A103H); (* LW sp, 0(t0) *)
  SYSTEM.PUT(base + 92, 0340292F3H); (* CSRRW t0, mscratch, t0 *)
  SYSTEM.PUT(base + 96, 030200073H); (* MRET *)

END BuildTrapHandler;


PROCEDURE InitInterrupts;
VAR i, j: INTEGER; scratchAdr: LONGINT;
    proc: PROCEDURE(excNo, pc, mstat: LONGINT);
BEGIN
  defaultHandler := Unexpected;
  FOR i := 0 TO IDTSize - 1 DO
    intHandler[i, 0] := defaultHandler;
    FOR j := 1 TO MaxInts - 1 DO intHandler[i, j] := NIL END
  END;

  trapStackTop := SYSTEM.ADR(trapStack[4095]) + 4;

  BuildTrapHandler;

  (* Initialize scratch buffer pointed to by mscratch.
     Layout: [0] saved sp  [4] saved a0  [8] saved a1
             [12] saved ra [16] saved a2
             [20] trapStackTop  [24] DispatchException addr *)
  scratchAdr := SYSTEM.ADR(scratchBuf[0]);
  scratchBuf[0] := 0;  scratchBuf[1] := 0;  scratchBuf[2] := 0;
  scratchBuf[3] := 0;  scratchBuf[4] := 0;
  scratchBuf[5] := trapStackTop;
  proc := DispatchException;
  scratchBuf[6] := SYSTEM.VAL(LONGINT, proc);

  SetMScratch(scratchAdr);

  SetMTVEC(trapHandlerBase);
  DataSyncBarrier;
  InstrSyncBarrier
END InitInterrupts;

PROCEDURE InitTrapHandling;
BEGIN
  handler0 := ShowState;
  handler := NIL;
  handlingtrap := FALSE;
  loop := NIL
END InitTrapHandling;


PROCEDURE GetTimer*(): LONGINT;
BEGIN
  RETURN ticks
END GetTimer;

PROCEDURE SetTimer*(VAR t: MilliTimer;  ms: LONGINT);
BEGIN
  IF TimeUnit # 1000 THEN
    ms := ms * TimeUnit DIV 1000
  END;
  t.target := ticks + ms
END SetTimer;

PROCEDURE Expired*(VAR t: MilliTimer): BOOLEAN;
BEGIN
  RETURN ticks - t.target >= 0
END Expired;


PROCEDURE ReloadTimer;
VAR lo, hi: LONGINT;
BEGIN
  lo := MmioGet(MTimeLo);
  hi := MmioGet(MTimeHi);
  (* Set mtimecmp = mtime + timerPeriod *)
  (* Write high word first with max value to prevent spurious interrupt *)
  MmioPut(MTimeCmpHi, 07FFFFFFFH);
  lo := lo + timerPeriod;
  (* Simple overflow handling *)
  IF lo < timerPeriod THEN INC(hi) END;
  MmioPut(MTimeCmpLo, lo);
  MmioPut(MTimeCmpHi, hi)
END ReloadTimer;

(* Simple timer tick handler - called from trap handler or polled.
   For initial QEMU testing, we use polling instead of interrupts. *)
PROCEDURE PollTimer*;
VAR ctl: LONGINT;
BEGIN
  ctl := MmioGet(MTimeLo);
  IF timerPeriod > 0 THEN
    ticks := ctl DIV timerPeriod
  END
END PollTimer;

PROCEDURE InitTimer;
VAR freq: LONGINT;
BEGIN
  ticks := 0;
  (* QEMU virt: mtime runs at 10 MHz by default *)
  freq := 10000000;  (* 10 MHz *)
  timerPeriod := freq DIV TimeUnit;  (* ticks per 1ms *)

  (* Disable mtimecmp by setting it to max value (no timer interrupt) *)
  MmioPut(MTimeCmpHi, 07FFFFFFFH);
  MmioPut(MTimeCmpLo, 07FFFFFFFH);

END InitTimer;

PROCEDURE InitClock;
BEGIN
  second := 0;  minute := 0;  hour := 12;
  day := 1;  month := 1;  year := 2025
END InitClock;

PROCEDURE GetClock*(VAR time, date: LONGINT);
BEGIN
  time := LONG(hour)*4096 + LONG(minute)*64 + LONG(second);
  date := LONG(year-1900)*512 + LONG(month)*32 + LONG(day)
END GetClock;

PROCEDURE SetClock*(time, date: LONGINT);
BEGIN
  hour := SHORT(time DIV 4096 MOD 32);
  minute := SHORT(time DIV 64 MOD 64);
  second := SHORT(time MOD 64);
  year := SHORT(date DIV 512 MOD 128 + 1900);
  month := SHORT(date DIV 32 MOD 16);
  day := SHORT(date MOD 32)
END SetClock;


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

PROCEDURE Used*(): LONGINT;
BEGIN
  RETURN endBlock - firstBlock - Available()
END Used;

PROCEDURE GetInit*(n: LONGINT;  VAR val: LONGINT);
BEGIN
  IF (n >= 0) & (n < LEN(kpar)) THEN val := kpar[n]
  ELSE val := 0
  END
END GetInit;

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

PROCEDURE SetLogMark*;
BEGIN
  traceMark := traceTail
END SetLogMark;

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

PROCEDURE DisableTracing*(recadr, fldadr: ADDRESS);
BEGIN (* stub *)
END DisableTracing;

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
  virtAdr := physAdr  (* identity mapping, no MMU *)
END MapPhysical;

PROCEDURE NewDMA*(size: LONGINT;  VAR adr, phys: ADDRESS);
VAR p: ADDRESS;
BEGIN
  IF size > 0 THEN
    NewSys(p, size);
    adr := p;  phys := p
  ELSE
    adr := 0;  phys := 0
  END
END NewDMA;

PROCEDURE DisposeDMA*(size: LONGINT;  adr: ADDRESS);
BEGIN (* stub *)
END DisposeDMA;

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
  LOOP END
END Shutdown;

PROCEDURE Idle*(code: LONGINT);
BEGIN
  (* WFI to save power while waiting *)
END Idle;



(* Heap Allocator (NewBlock, NewRec, NewSys, NewArr), identical to ARM version *)
PROCEDURE NewBlock(size: LONGINT): InitPtr;
VAR i, rest: LONGINT;  adr, AN: ADDRESS;  ptr: InitPtr;  restptr: FreeBlockPtr;
BEGIN
  IF break THEN break := FALSE;  SYSTEM.HALT(13) END;
  IF size < 0 THEN SYSTEM.HALT(14) END;
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
  SYSTEM.PUT(adr, ptr.z1);
  rest := ptr.z0 + 4 - size;
  restptr := SYSTEM.VAL(FreeBlockPtr, SYSTEM.VAL(ADDRESS, ptr) + size);
  IF rest > 0 THEN
    i := rest DIV B;
    IF i > N THEN i := N END;
    restptr.tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, SYSTEM.ADR(restptr.size)) + free);
    restptr.size := rest - 4;
    restptr.next := A[i];  A[i] := SYSTEM.VAL(ADDRESS, restptr)
  END;
  RETURN ptr
END NewBlock;

PROCEDURE NewRec(VAR p: ADDRESS;  tag: Tag);
VAR size: LONGINT;  ptr, init: InitPtr;
BEGIN
  ASSERT(SYSTEM.VAL(LONGINT, tag) MOD 8 = 0);
  IF tag = NIL THEN tag := SYSTEM.VAL(Tag, ptrElemTag) END;
  size := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, tag.size + (4 + B-1)) - SYSTEM.VAL(SET, B-1));
  ptr := NewBlock(size);
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
  IF eltag.ptroff = -4 THEN
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


PROCEDURE InitHeap;
VAR
  base, heapStart, low0, high1, i, t: LONGINT;
  f: FreeBlockPtr;  m: Module;
  td: POINTER TO RECORD filler: ARRAY 4 OF LONGINT;  name: Name END;
BEGIN
  inGC := FALSE;  break := FALSE;  FinObjs := NIL;  traceheap := {};
  ptrElemTag := 0;

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

  base := GetWord(ImageBase + 4);
  heapStart := GetWord(base + 8);

  IF heapStart < StackOrg THEN heapStart := StackOrg END;

  low0 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, heapStart + 4 + B-1) - SYSTEM.VAL(SET, B-1)) - 4;
  high1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, heapTop - 1) - SYSTEM.VAL(SET, B-1)) - 4;

  IF high1 <= low0 + 2*B THEN
    WriteString("FATAL: not enough heap"); WriteLn;  SYSTEM.HALT(14)
  END;

  firstBlock := low0;
  endBlock := high1;

  FOR i := 0 TO N DO A[i] := 0 END;

  SYSTEM.PUT(low0, 0);
  SYSTEM.PUT(low0 + 4, 0);
  SYSTEM.PUT(low0 + 8, 0);

  f := SYSTEM.VAL(FreeBlockPtr, low0);
  f.tag := SYSTEM.VAL(Tag, SYSTEM.VAL(SET, SYSTEM.ADR(f.size)) + free);
  f.size := high1 - low0 - 4;
  f.next := 0;
  A[N] := SYSTEM.VAL(ADDRESS, f);

  reserve := NIL;  firstTry := TRUE;
  GClevel := 0;  GCstack := TRUE
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
  runtime[0] := SYSTEM.VAL(ADDRESS, newRec);
  runtime[1] := SYSTEM.VAL(ADDRESS, newSys);
  runtime[2] := SYSTEM.VAL(ADDRESS, newArr)
END InitRuntime;



BEGIN
  StackOrg := GetSP();

  (* Enable FPU: set mstatus.FS = Initial (bit 13) before any FPU instruction *)
  SetMStatus(GetMStatus() + {13});

  copro := TRUE;
  SetFCSR(GetFCSR() * {5..31});  (* clear exception flags 0-4 *)

  tspeed := 0;  tbase := 0;  traceBufAdr := 0;  timer := NIL;
  shutdown := 0;  ticks := 0;
  logMode := LogNone;

  ReadBootTable;
  CheckMemory;
  heapTop := memTop;

  InitTracing(heapTop);

  version := "RV32 Native v2.3.7";
  WriteString("ETH Oberon / ");  WriteString(version);  WriteLn;

  (* Set up trap handler BEFORE anything that might fault.
     On ARM, InitInterrupts is after InitHeap because the ARM boot ROM
     sets up default exception vectors.  On RISC-V bare-metal (-bios none),
     mtvec defaults to 0 so any trap before InitInterrupts causes a double fault. *)
  InitInterrupts;
  InitTrapHandling;

  EnableGC := DefaultEnableGC;
  DisableGC := DefaultDisableGC;

  InitHeap;
  InitRuntime;

  InitTimer;
  InitClock;

END Kernel.
