(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE ListRiders; (** portable *)  (** ps, based on Rider by rv,   *)

IMPORT Objects, Gadgets;

CONST
 (** id for UpdateMsg *)
 insert* = 0; delete* = 1; state* = 2;

TYPE
 Data* = POINTER TO DataDesc;
 DataDesc* = RECORD
 END;

 Bool* = POINTER TO BoolDesc;
 BoolDesc* = RECORD (DataDesc) b*: BOOLEAN END;

 Char* = POINTER TO CharDesc;
 CharDesc* = RECORD (DataDesc) c*: CHAR END;

 String* = POINTER TO StringDesc;
 StringDesc* = RECORD (DataDesc) s*: ARRAY 64 OF CHAR END;

 Int* = POINTER TO IntDesc;
 IntDesc* = RECORD (DataDesc) i*: LONGINT END;

 Real* = POINTER TO RealDesc;
 RealDesc* = RECORD (DataDesc) x*: REAL END;

 LReal* = POINTER TO LRealDesc;
 LRealDesc* = RECORD (DataDesc) x*: LONGREAL END;

 
 Method* = POINTER TO MethodDesc;
 
 Rider* = POINTER TO RiderDesc;
 RiderDesc* = RECORD
  d*: Data; (** Data of the current item *)
  do*: Method; (** Method block *)
  base*: Objects.Object; (** Model object on which the rider is working *)
  dsc*, eol*: BOOLEAN (** Has-descendant, End-of-list *)
 END;
 
 MethodDesc* = RECORD
  Key*: PROCEDURE (R: Rider): LONGINT; (** Get the current item's key *)
  Seek*: PROCEDURE (R: Rider; key: LONGINT); (** Position rider R on the item having the given key *)
  Pos*: PROCEDURE (R: Rider): LONGINT; (** Get current position of the rider *)
  Set*: PROCEDURE (R: Rider; pos: LONGINT); (** Position rider R on the item having the given pos *)
  Write*: PROCEDURE (R: Rider; d: Data); (** Insert data at the current position of R *)
  WriteLink*: PROCEDURE (R, linkR: Rider); (** Link the item at the position of linkR to the current position of R *)
  DeleteLink*: PROCEDURE (R, linkR: Rider); (** Delete link from R to linkR *)
  State*: PROCEDURE (R: Rider): LONGINT; (** Get the state of the current item *)
  SetState*: PROCEDURE (R: Rider; s: LONGINT); (** Set the state of the current item *)
  (** Get a rider working on the descendants of the item on the position of R. If old is NIL, then a new rider
  is allocated. old is recycled if not NIL *)
  Desc*: PROCEDURE (R, old: Rider): Rider;
  GetStamp*: PROCEDURE (R: Rider): LONGINT; (** Get stamp value of the item at the current position of R *)
  SetStamp*: PROCEDURE (R: Rider; stamp: LONGINT) (** Set stamp value of the item at the current position of R *)
 END;

 (** Get a new initialized rider from a model gadget. Sent by a client to a model gadget. *)
 ConnectMsg* = RECORD (Objects.ObjMsg)
  R*: Rider
 END;
 
 (** Message broadcast to indicate that a model object changed *)
 UpdateMsg* = RECORD (Gadgets.UpdateMsg)
  id*: INTEGER (** insert, delete or state *)
 END;

VAR
 stamp: LONGINT;

PROCEDURE Stamp*(): LONGINT;
BEGIN INC(stamp); RETURN stamp
END Stamp;

BEGIN stamp := MIN(LONGINT)
END ListRiders.