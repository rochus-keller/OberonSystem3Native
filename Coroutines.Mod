(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Coroutines; (** non-portable *)
(* NW 3. 8. 89/JG 22. 5. 92/ARD 2. 9. 92 *)
(* ARD 6. 10. 93, Oberon version, compile with /no *)
(* pjm 14.11.96, port to Native Oberon *)
(* eos 13.8.98, added Init *)

IMPORT SYSTEM;

TYPE Coroutine* = POINTER TO CorDesc;

  Proc* = PROCEDURE(me: Coroutine);
  
  Stack* = POINTER TO RECORD END;
  
  CorDesc* = RECORD
   SP: LONGINT; P*: Proc; S*: Stack; L*: LONGINT; 
  END;
  
VAR
 main*: Coroutine; (** main Coroutine *)
 cur: Coroutine;

(** Initialising a Coroutine c:
 NEW(c);  Init(c, Handler, stackSize); *)

PROCEDURE Init*(me: Coroutine; proc: Proc; size: LONGINT);
BEGIN
 me.P := proc; me.L := size; SYSTEM.NEW(me.S, size)
END Init;

(** Start - Transfer control to a coroutine for the first time *)

PROCEDURE Start*(me: Coroutine);
CODE {SYSTEM.i386}
 MOV ECX, cur
 MOV [ECX], EBP
 MOV EAX, me[EBP]
 MOV EBX, 8[EAX]
 ADD EBX, 12[EAX]
 MOV ESP, EBX
 PUSH EAX
 MOV cur, EAX
 CALL DWORD 4[EAX]
 PUSH 29
 INT 3
END Start;

(** Transfer - Transfer control to a coroutine *)

PROCEDURE Transfer*(to: Coroutine);
CODE {SYSTEM.i386}
 MOV ECX, cur
 MOV [ECX], EBP
 MOV ECX, to[EBP]
 MOV EBP, [ECX]
 MOV cur, ECX
END Transfer;

BEGIN
 NEW(main); cur := main
END Coroutines.
