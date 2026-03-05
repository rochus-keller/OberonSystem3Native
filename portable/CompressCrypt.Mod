(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE CompressCrypt; (** portable *) (* ejz   *)
 IMPORT Files, Strings, Compress;

 PROCEDURE *Decrypt(VAR Rin: Files.Rider; nIn: LONGINT; VAR Rout: Files.Rider; key: ARRAY OF CHAR; VAR res: INTEGER);
  VAR
   i, n: LONGINT;
   ch: CHAR;
 BEGIN
  n := Strings.Length(key); i := 0;
  WHILE i < nIn DO
   Files.Read(Rin, ch);
   Files.Write(Rout, CHR( (ORD(ch)+ORD(key[i MOD n])) MOD 256 ) );
   INC(i)
  END;
  res := Compress.Done
 END Decrypt;

 PROCEDURE *Encrypt(VAR Rin: Files.Rider; nIn: LONGINT; VAR Rout: Files.Rider; key: ARRAY OF CHAR; VAR res: INTEGER);
  VAR
   i, n: LONGINT;
   ch: CHAR;
 BEGIN
  n := Strings.Length(key); i := 0;
  WHILE i < nIn DO
   Files.Read(Rin, ch);
   Files.Write(Rout, CHR( (ORD(ch)-ORD(key[i MOD n])) MOD 256 ) );
   INC(i)
  END;
  res := Compress.Done
 END Encrypt;

 PROCEDURE Install*;
 BEGIN
  Compress.Decrypt := Decrypt;
  Compress.Encrypt := Encrypt
 END Install;

END CompressCrypt.
