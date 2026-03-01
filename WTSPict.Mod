(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE WTSPict; (** portable *)

 IMPORT WTS, Pictures, Objects, Files, Rembrandt;
 
 PROCEDURE Load(P: Pictures.Picture; VAR R: Files.Rider);
  VAR len: LONGINT; ch: CHAR;
 BEGIN Files.Read(R, ch); Files.Read(R, ch);
  Files.Read(R, ch); Files.Read(R, ch); (*pict id*)
  Pictures.Load(P, Files.Base(R), Files.Pos(R), len);
  (*Files.Set(R, Files.Base(R), Files.Pos(R)+len)*)
 END Load;

 PROCEDURE New*;
  VAR pict: Pictures.Picture; F: Rembrandt.Frame;
 BEGIN NEW(pict); Load(pict, WTS.R);
  NEW(F);
  Rembrandt.NewP(F, pict); Objects.NewObj := F
 END New;

END WTSPict.
