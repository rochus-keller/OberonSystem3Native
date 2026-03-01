(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Types; (** non-portable *)     (* RC 16.1.92 / MH 30.8.93 adapted to Oberon for Windows *)

(** Module Types allow mappings between type names and types, and for exploring the type extensions at run time. 
*)

IMPORT Modules, Kernel, S := SYSTEM;

TYPE
 Type* = POINTER TO TypeDesc;
 TypeDesc* = RECORD
  tdsize: LONGINT;
  sentinel: LONGINT; (* -4 *)
  tag*: LONGINT;
  ext0: RECORD
   extlev: SHORTINT;
   filler: ARRAY 3 OF CHAR
  END;
  name*: ARRAY 32 OF CHAR;
  module*: Modules.Module (** Module where type is defined. *)
 END;

VAR
 newRec: PROCEDURE(VAR p: LONGINT;  tag: LONGINT);

(** Returned the named (record) type from module mod. *)
PROCEDURE This* (mod: Modules.Module; name: ARRAY OF CHAR): Type;
 VAR type: Type; i: LONGINT;
BEGIN
 IF name # "" THEN
  i := LEN(mod.tdescs);
  WHILE i > 0 DO DEC(i); type := S.VAL(Type, mod.tdescs[i]);
   S.GET(S.VAL(LONGINT, type) - 4, type);
   IF type.name = name THEN RETURN type END
  END
 END;
 RETURN NIL
END This;

(** Return the type extension level level of type t. *)
PROCEDURE BaseOf* (t: Type; level: INTEGER): Type;
BEGIN
 S.GET(t.tag - 8 - 4*level, t);
 IF t # NIL THEN
  S.GET(S.VAL(LONGINT, t) - 4, t)
 END;
 RETURN t
END BaseOf;

(** What is the extension level of t? *)
PROCEDURE LevelOf* (t: Type): INTEGER;
BEGIN
 RETURN LONG(t.ext0.extlev)
END LevelOf;

(** What is the type of pointer based type o? *)
PROCEDURE TypeOf* (o: S.PTR): Type;
 VAR type: Type;
BEGIN
 S.GET(S.VAL(LONGINT, o)-4, type);
 S.GET(S.VAL(LONGINT, type)-4, type);
 RETURN type
END TypeOf;

(** Allocate a new pointer-based record variable of type t, assigning it to o. *)
PROCEDURE NewObj* (VAR o: S.PTR; t: Type);
 VAR otype: Type;
BEGIN
 S.GET(S.VAL(LONGINT, o) - 4, otype); (* uses compiler hack in OPC.Parameter *)
 IF BaseOf(t, LevelOf(otype)) # otype THEN o := NIL; RETURN END ;
 newRec(S.VAL(LONGINT, o), t.tag)
END NewObj;

BEGIN
 S.GET(S.ADR(Kernel.runtime[0]), newRec)
END Types.
