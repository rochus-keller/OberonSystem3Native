(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE V86; (* pjm *) (** non-portable *)

(** Access to virtual 8086 mode. Experimental! May crash with some BIOS's. *)

IMPORT SYSTEM, Kernel, Modules;

CONST
 V86EnterInt = 28;  V86ExitInt = 29; (* copy of Kernel constants *)
 
 V86Size = 4096; (* total DMA buffer for V86 mode *)
 V86BufSize = 512; (* buffer *)

TYPE
 Regs* = RECORD (* copy of Kernel.V86Regs *)
  EDI*, ESI*, EBP*, fillerESP, EBX*, EDX*, ECX*, EAX*: LONGINT;
  int, errCode: LONGINT;
  EIP*, CS*: LONGINT;
  EFLAGS*: SET;
  ESP*, SS*, ES*, DS*, FS*, GS*: LONGINT
 END;

VAR
 bufadr*: LONGINT; (** read-only *)
 bufsize*: LONGINT; (** read-only *)
 vmem: LONGINT;

PROCEDURE Cleanup*;
BEGIN
 IF vmem # 0 THEN
  Kernel.DisposeDMA(V86Size, vmem); (* deallocate DMA buffer *)
  vmem := 0
 END
END Cleanup;

PROCEDURE Init*;
VAR adr: LONGINT;
BEGIN
 IF vmem = 0 THEN
  Kernel.NewDMA(V86Size, adr, vmem); (* allocate DMA buffer *)
  ASSERT(vmem MOD 16 = 0);  ASSERT(vmem < 100000H); (* sanity *)
  ASSERT(adr = vmem); (* implementation restriction *)
  bufadr := vmem+V86Size-V86BufSize;
  bufsize := V86BufSize
 END
END Init;

PROCEDURE -GetFlags(): SET;
CODE {SYSTEM.i386}
 PUSHFD
 POP EAX
END GetFlags;

PROCEDURE -V86Call;
CODE {SYSTEM.i386}
 INT V86EnterInt
END V86Call;

(** Video - Call INT 10H service. *)

PROCEDURE Video*(VAR vreg: Regs);
VAR a: LONGINT;
BEGIN
 IF vmem = 0 THEN Init END;
  (* assemble 8086 code *)
 SYSTEM.PUT(vmem, 401EFF9CH); (* PUSHF;  CALL FAR [40H];  INT V86ExitInt *)
 SYSTEM.PUT(vmem+4, ASH(V86ExitInt, 16)+0CD00H);
 
 vreg.CS := SHORT(vmem DIV 16);
 vreg.EIP := 0;
 vreg.EFLAGS := GetFlags();
 vreg.DS := 0;
 vreg.SS := vreg.CS;
 vreg.ESP := V86Size-V86BufSize;
 
 SYSTEM.PUTREG(0, SYSTEM.VAL(LONGINT, 0)); (* EAX *)
 SYSTEM.PUTREG(3, SYSTEM.ADR(vreg)); (* EBX *)
 V86Call
END Video;

(** Read a machine status register. *)

PROCEDURE ReadMSR*(msr: LONGINT;  VAR low, high: SET);
VAR l, h: SET;
BEGIN
 SYSTEM.PUTREG(0, SYSTEM.VAL(LONGINT, 2)); (* EAX *)
 SYSTEM.PUTREG(1, msr); (* ECX *)
 V86Call;
 SYSTEM.GETREG(0, l); (* EAX *)
 SYSTEM.GETREG(2, h); (* EDX *)
 low := l;  high := h
END ReadMSR;

(** Write a machine status register. *)

PROCEDURE WriteMSR*(msr: LONGINT;  low, high: SET);
BEGIN
 SYSTEM.PUTREG(0, SYSTEM.VAL(LONGINT, 3)); (* EAX *)
 SYSTEM.PUTREG(1, msr); (* ECX *)
 SYSTEM.PUTREG(2, high); (* EDX *)
 SYSTEM.PUTREG(3, low); (* EBX *)
 V86Call
END WriteMSR;

(*
(** Real mode test. *)

PROCEDURE RealMode*;
BEGIN
 SYSTEM.PUTREG(0, SYSTEM.VAL(LONGINT, 5)); (* EAX *)
 V86Call
END RealMode;
*)

BEGIN
 vmem := 0;
 Modules.InstallTermHandler(Cleanup)
END V86.
