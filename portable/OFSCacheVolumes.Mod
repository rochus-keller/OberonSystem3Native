(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSCacheVolumes; (* pjm *)

(* Cache for arbitrary volumes. *)

IMPORT SYSTEM, OFS;

TYPE
 Buffer = POINTER TO RECORD
  adr, index: LONGINT;
  nextHash, prevHash, nextLRU, prevLRU: Buffer
 END;
 
 Volume* = POINTER TO RECORD (OFS.Volume)
  real*: OFS.Volume;
  hashSize*, cacheSize*: LONGINT;
  getCount*, putCount*, getHitCount*, putHitCount*: LONGINT;
  data: POINTER TO ARRAY OF ARRAY OF CHAR; (* use a single heap block to reduce GC overhead *)
  hashTable: POINTER TO ARRAY OF Buffer;
  lru: Buffer
 END;

PROCEDURE FindBuffer(vol: Volume; adr: LONGINT): Buffer;
VAR buf: Buffer;
BEGIN
 ASSERT(adr > 0);
 buf := vol.hashTable[adr MOD LEN(vol.hashTable)];
 WHILE (buf # NIL) & (buf.adr # adr) DO buf := buf.nextHash END;
 IF buf # NIL THEN (* move to end of lru list *)
  buf.prevLRU.nextLRU := buf.nextLRU; buf.nextLRU.prevLRU := buf.prevLRU;
  buf.prevLRU := vol.lru.prevLRU; buf.nextLRU := vol.lru;
  buf.prevLRU.nextLRU := buf; buf.nextLRU.prevLRU := buf
 END;
 RETURN buf
END FindBuffer;

PROCEDURE ReplaceBuffer(vol: Volume; adr: LONGINT): Buffer;
VAR buf: Buffer; old, new: LONGINT;
BEGIN
 buf := vol.lru; vol.lru := vol.lru.nextLRU; (* re-use buffer and move to end of lru list *)
 old := buf.adr MOD LEN(vol.hashTable);
 new := adr MOD LEN(vol.hashTable);
 buf.adr := adr;
 IF old # new THEN
   (* remove *)
  IF buf.prevHash # NIL THEN
   buf.prevHash.nextHash := buf.nextHash
  ELSE
   vol.hashTable[old] := buf.nextHash
  END;
  IF buf.nextHash # NIL THEN buf.nextHash.prevHash := buf.prevHash END;
   (* add in front *)
  buf.prevHash := NIL; buf.nextHash := vol.hashTable[new]; vol.hashTable[new] := buf;
  IF buf.nextHash # NIL THEN buf.nextHash.prevHash := buf END
 END;
 RETURN buf
END ReplaceBuffer;

(*
read-ahead experiment: speeds up Oberon-0 booting from 0:40 to 0:26, but might also slow it down significantly

PROCEDURE ReadAhead(vol: Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
CONST Num = 2*18*512 DIV 2048;
VAR n: LONGINT; buf: Buffer;
BEGIN
 ASSERT(vol.blockSize = 2048);
 DEC(adr, (adr-1) MOD Num); (* round down 1-based adr to start of Num-block region *)
 FOR n := 0 TO Num-1 DO
  buf := FindBuffer(vol, adr);
  IF buf = NIL THEN
   vol.real.GetBlock(vol.real, adr, blk);
   buf := ReplaceBuffer(vol, adr);
   SYSTEM.MOVE(SYSTEM.ADR(blk[0]), SYSTEM.ADR(vol.data[buf.index,0]), vol.blockSize)
  END;
  INC(adr)
 END
END ReadAhead;
*)

PROCEDURE GetBlock(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR buf: Buffer;
BEGIN
 WITH vol: Volume DO
  (*IF (vol.cacheSize = 1440 DIV 2) & (vol.blockSize = 2048) THEN
   ReadAhead(vol, adr, blk)
  END;*)
  INC(vol.getCount);
  buf := FindBuffer(vol, adr);
  IF buf # NIL THEN (* copy from cache *)
   INC(vol.getHitCount);
   SYSTEM.MOVE(SYSTEM.ADR(vol.data[buf.index,0]), SYSTEM.ADR(blk[0]), vol.blockSize)
  ELSE (* replace a buffer *)
   vol.real.GetBlock(vol.real, adr, blk);
   buf := ReplaceBuffer(vol, adr);
   SYSTEM.MOVE(SYSTEM.ADR(blk[0]), SYSTEM.ADR(vol.data[buf.index,0]), vol.blockSize)
  END
 END
END GetBlock;

PROCEDURE PutBlock(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR buf: Buffer;
BEGIN
 WITH vol: Volume DO
  INC(vol.putCount);
  buf := FindBuffer(vol, adr);
  IF buf # NIL THEN (* refresh data *)
   INC(vol.putHitCount);
   SYSTEM.MOVE(SYSTEM.ADR(blk[0]), SYSTEM.ADR(vol.data[buf.index,0]), vol.blockSize)
  END;
  vol.real.PutBlock(vol.real, adr, blk)
 END
END PutBlock;

PROCEDURE AllocBlock(vol: OFS.Volume; hint: OFS.Address; VAR adr: OFS.Address);
BEGIN
 WITH vol: Volume DO
  vol.real.AllocBlock(vol.real, hint, adr)
 END
END AllocBlock;

PROCEDURE FreeBlock(vol: OFS.Volume; adr: OFS.Address);
BEGIN
 WITH vol: Volume DO
  vol.real.FreeBlock(vol.real, adr)
 END
END FreeBlock;

PROCEDURE MarkBlock(vol: OFS.Volume; adr: OFS.Address);
BEGIN
 WITH vol: Volume DO
  vol.real.MarkBlock(vol.real, adr)
 END
END MarkBlock;

PROCEDURE Marked(vol: OFS.Volume; adr: OFS.Address): BOOLEAN;
BEGIN
 WITH vol: Volume DO
  RETURN vol.real.Marked(vol.real, adr)
 END
END Marked;

PROCEDURE Available(vol: OFS.Volume): LONGINT;
BEGIN
 WITH vol: Volume DO
  RETURN vol.real.Available(vol.real)
 END
END Available;

(** Write back any cached information to the real volume. *)
PROCEDURE Update*(vol: Volume);
BEGIN
 (* write back *)
END Update;

(** Write back any cached information to the real volume. *)
PROCEDURE Sync*(vol: OFS.Volume);
BEGIN Update(vol(Volume))
END Sync;

PROCEDURE Finalize(vol: OFS.Volume);
BEGIN
 WITH vol: Volume DO
  Update(vol);
  vol.real.Finalize(vol.real);
  vol.real := NIL; vol.data := NIL; vol.hashTable := NIL; vol.lru := NIL
 END
END Finalize;

(** Initialize a cache volume with underlying volume "real". *)
PROCEDURE Init*(vol: Volume; real: OFS.Volume; hashSize, cacheSize: LONGINT);
VAR i, n: LONGINT; buf: Buffer;
BEGIN
 ASSERT(hashSize <= cacheSize);
 COPY(real.name, vol.name);
 vol.blockSize := real.blockSize; vol.size := real.size;
 vol.flags := real.flags; vol.AllocBlock := AllocBlock;
 vol.FreeBlock := FreeBlock; vol.MarkBlock := MarkBlock;
 vol.Marked := Marked; vol.Available := Available;
 vol.GetBlock := GetBlock; vol.PutBlock := PutBlock;
 vol.Sync := Sync; vol.Finalize := Finalize; vol.real := real;
 vol.hashSize := hashSize; vol.cacheSize := cacheSize;
 vol.getCount := 0; vol.putCount := 0; vol.getHitCount := 0; vol.putHitCount := 0;
 NEW(vol.data, cacheSize, vol.blockSize);
 NEW(vol.hashTable, hashSize);
 FOR i := 0 TO hashSize-1 DO vol.hashTable[i] := NIL END;
 NEW(vol.lru); vol.lru.nextLRU:= vol.lru; vol.lru.prevLRU := vol.lru; (* dummy *)
 FOR i := 0 TO cacheSize-1 DO
  NEW(buf); buf.adr := -i; buf.index := i;
  n := buf.adr MOD LEN(vol.hashTable);
  buf.prevHash := NIL; buf.nextHash := vol.hashTable[n]; vol.hashTable[n] := buf;
  IF buf.nextHash # NIL THEN buf.nextHash.prevHash := buf END;
  buf.prevLRU := vol.lru.prevLRU; buf.nextLRU := vol.lru;
  buf.prevLRU.nextLRU := buf; buf.nextLRU.prevLRU := buf
 END;
 vol.lru.prevLRU.nextLRU := vol.lru.nextLRU; vol.lru.nextLRU.prevLRU := vol.lru.prevLRU; (* remove dummy *)
 vol.lru := vol.lru.nextLRU
END Init;

END OFSCacheVolumes.

(*
to do:
? termination handler to remove cache when module is freed
? write-back caching
*)

OFSTools.Mount AOS 101 1000 AosFS IDE2 5 ~
OFSTools.Mount AOS 1 1000 AosFS IDE2 5 ~
OFSTools.Unmount AOS

OFSTools.InstallCache SYS 101 1000
OFSTools.RemoveCache SYS

OFSTools.Watch

System.State OFSCacheVolumes ~

!System.Free OFSTools OFSCacheVolumes ~
