(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE PPPTest; (** non-portable *) (* pjm *)
(* $VCS   4, Edgar@EdgarSchwarz.de, 06.06.00 22:03:24 $
    $Log$
$   4, Edgar@EdgarSchwarz.de, 06.06.00 22:03:24
better decoding of David Denny
$   3, Edgar@EdgarSchwarz.de, 25 Apr :0, 11:19:10
decoding stuff added, ShowLog opens PPPDebug.Log
$   2, Edgar.Schwarz@z.zgs.de, 6 Sep 99, 22:5:49
ShowLog and ShowHex removed
$   1, Edgar.Schwarz@z.zgs.de, 28 Feb 99, 21:19:47
first versioned version, with configurable logging
*)
(* Test procedures for PPP *)

IMPORT SYSTEM, PPPDebug, PPPHDLC, PPPFSM, Texts, Oberon, Fonts, Out;

CONST
 MaxSize = 10000H;
 (* codes not exported by PPPFSM *)
 TermReq = 5; (* termination request *)
 TermAck = 6; (* termination ack *)
 CodeRej = 7; (* code reject *)
 ProtRej = 8;  (* protocol reject *)
 EchoReq = 9;
 EchoReply = 10;
 DiscardReq = 11;
 (* LCP option types *)
 MRU = 1;
 AsyncControl = 2;
 Authentication = 3;
 Quality = 4;
 Magic = 5;
 RESERVED = 6;
 ProtComp = 7;
 AddrCtrlComp = 8;
 (* IPCP option types *)
 IpAddrs = 1;
 IpComp = 2;
 IpAddr = 3;
 (* Authentification codes *)
 AuthReq = 1;
 AuthAck = 2;
 AuthNak = 3;
 
VAR
 w: Texts.Writer;


(* for hex numbers less than MAX(LONGINT) *)
PROCEDURE HexToInt(hexStr: ARRAY OF CHAR): LONGINT;
VAR pos, int: LONGINT;
BEGIN
 pos := 0; int := 0;
 WHILE hexStr[pos] # 0X DO
  CASE hexStr[pos] OF
   "0".."9": int := 16 * int + ORD(hexStr[pos]) - ORD("0");
   | "a".."f": int := 16 * int + ORD(hexStr[pos]) - ORD("a") + 10;
   | "A".."F": int := 16 * int + ORD(hexStr[pos]) - ORD("A") + 10;
  END;
  INC(pos);
 END;
 RETURN int;
END HexToInt;

PROCEDURE ReadHexByteString(VAR r: Texts.Reader; VAR hexStr: ARRAY OF CHAR);
VAR hexPos: LONGINT; ch: CHAR;
BEGIN
 hexPos := 0;
 LOOP
  Texts.Read(r, ch);
  CASE ch OF 
   "0".."9", "a".."f", "A".."F":
    hexStr[hexPos] := ch; INC(hexPos);
    IF hexPos = 2 THEN
     hexStr[hexPos] := 0X; RETURN;
    END;
   ELSE
  END;
 END;
END ReadHexByteString;

PROCEDURE ReadHexByte(VAR r: Texts.Reader): LONGINT;
VAR hexPos: LONGINT;
 hexStr: ARRAY 3 OF CHAR; ch: CHAR;
BEGIN
 hexPos := 0;
 LOOP
  Texts.Read(r, ch);
  CASE ch OF 
   "0".."9", "a".."f", "A".."F":
    hexStr[hexPos] := ch; INC(hexPos);
    IF hexPos = 2 THEN
     hexStr[hexPos] := 0X; RETURN HexToInt(hexStr);
     hexPos := 0;
    END;
   ELSE
  END;
 END;
END ReadHexByte;
 
PROCEDURE WriteHex(x, width: LONGINT);
VAR
 buf: ARRAY 9 OF CHAR;
 i, j: LONGINT;
BEGIN
 buf[0] := " "; buf[1] := 0X;
 IF width >= 0 THEN j := 8 ELSE j := 2; width := -width END;
 FOR i := j+1 TO width DO Texts.WriteString(w, buf) END;
 FOR i := j-1 TO 0 BY -1 DO
  buf[i] := CHR(x MOD 10H + 48);
  IF buf[i] > "9" THEN
   buf[i] := CHR(ORD(buf[i]) - 48 + 65 - 10)
  END;
  x := x DIV 10H
 END;
 buf[j] := 0X;
 Texts.WriteString(w, buf)
END WriteHex;

PROCEDURE LCPConfOpt(VAR r: Texts.Reader; VAR read: LONGINT);
VAR type, len, i: LONGINT; hexStr: ARRAY 3 OF CHAR;
BEGIN
 type := ReadHexByte(r); INC(read);
 CASE type OF
  MRU:
   Out.String("  MRU");  len := ReadHexByte(r);
   Out.Int(256*ReadHexByte(r) + ReadHexByte(r), 6);
   Out.Ln(); INC(read, 3);
  | AsyncControl:
   Out.String("  AsyncControl "); len := ReadHexByte(r);
   FOR len := 0 TO 3 DO
    ReadHexByteString(r, hexStr); Out.String(hexStr);
   END;
   Out.Ln(); INC(read, 5);
  | Authentication: Out.String("  Authentication "); len := ReadHexByte(r);
   FOR i := 1 TO len-2 DO
    ReadHexByteString(r, hexStr); Out.String(hexStr);
   END;
   Out.Ln(); INC(read, 1+len-2);
  | Quality: Out.String("Quality");
  | Magic: Out.String("  Magic "); len := ReadHexByte(r);
   FOR i := 0 TO 3 DO
    ReadHexByteString(r, hexStr); Out.String(hexStr);
   END;
   Out.Ln(); INC(read, 5);
  | RESERVED: Out.String("RESERVED");
  | ProtComp:
   Out.String("  Protocol-Field-Compression"); len := ReadHexByte(r);
   Out.Ln(); INC(read, 1);
  | AddrCtrlComp:
   Out. String("  Address-and-Control-Field-Compression"); len := ReadHexByte(r);
   Out.Ln(); INC(read, 1);
  ELSE
   Out.String("  unknown option"); Out.Int(type, 4); len := ReadHexByte(r);
   Out.Int(len, 4); Out.Char(" ");
   FOR i := 1 TO len - 2 DO
    ReadHexByteString(r, hexStr); Out.String(hexStr);
   END;
   Out.Ln(); INC(read, 1+len-2);
 END;
END LCPConfOpt;

PROCEDURE LCPConfOptions(VAR r: Texts.Reader);
VAR len, read: LONGINT;
BEGIN
 Out.Int(ReadHexByte(r), 4); (* identifier (message number) *)
 len := 256*ReadHexByte(r) + ReadHexByte(r); Out.Int(len, 4); Out.Ln();
 read := 4;
 WHILE read < len DO LCPConfOpt(r, read); END;
END LCPConfOptions;

(* System.Free PPPTest ~ Builder.Compile * PPPTest.LCPDecode ^ *)
PROCEDURE LCPDecode*;
VAR
 text: Texts.Text; r: Texts.Reader;
 hexPos, beg, end, time: LONGINT;
 hexStr: ARRAY 10 OF CHAR; ch: CHAR;
BEGIN
 Oberon.GetSelection(text, beg, end, time);
 Texts.OpenReader(r, text, beg);
 CASE ReadHexByte(r) OF
     PPPFSM.ConfReq: Out.String("ConfReq"); LCPConfOptions(r);
  | PPPFSM.ConfAck: Out.String("ConfAck"); LCPConfOptions(r);
  | PPPFSM.ConfNak: Out.String("ConfNak");
  | PPPFSM.ConfRej: Out.String("ConfRej"); LCPConfOptions(r);
  | TermReq: Out.String("TermReq");
  | TermAck: Out.String("TermAck");
  | CodeRej: Out.String("CodeRej");
  | ProtRej: Out.String("ProtocolRej");
  | EchoReq: Out.String("EchoReq");
  | EchoReply: Out.String("EchoReply");
  ELSE Out.String("*** illegal code ***");
 END;
END LCPDecode;

PROCEDURE IPCPConfOpt(VAR r: Texts.Reader; VAR read: LONGINT);
VAR type, len, i: LONGINT; hexStr: ARRAY 3 OF CHAR;
BEGIN
 type := ReadHexByte(r); INC(read);
 CASE type OF
  IpAddrs:
   Out.String("  IP-Addresses");  len := ReadHexByte(r);
   Out.Int(256*ReadHexByte(r) + ReadHexByte(r), 6);
   Out.Ln(); INC(read, 3);
  | IpComp:
   Out.String("  IP-Compression Protocol "); len := ReadHexByte(r);
   FOR len := 1 TO len-2 DO
    ReadHexByteString(r, hexStr); Out.String(hexStr);
   END;
   Out.Ln(); INC(read, 1+len-2);
  | IpAddr: Out.String("  IP-Address "); len := ReadHexByte(r);
   FOR i := 1 TO len-2 DO
    ReadHexByteString(r, hexStr); Out.String(hexStr);
   END;
   Out.Ln(); INC(read, 1+len-2);
  ELSE
   Out.String("  unknown option"); Out.Int(type, 4); len := ReadHexByte(r);
   Out.Int(len, 4); Out.Char(" ");
   FOR i := 1 TO len - 2 DO
    ReadHexByteString(r, hexStr); Out.String(hexStr);
   END;
   Out.Ln(); INC(read, 1+len-2);
 END;
END IPCPConfOpt;

PROCEDURE IPCPConfOptions(VAR r: Texts.Reader);
VAR len, read: LONGINT;
BEGIN
 Out.Int(ReadHexByte(r), 4); (* identifier (message number) *)
 len := 256*ReadHexByte(r) + ReadHexByte(r); Out.Int(len, 4); Out.Ln();
 read := 4;
 WHILE read < len DO IPCPConfOpt(r, read); END;
END IPCPConfOptions;

(* System.Free PPPTest ~ Builder.Compile * PPPTest.IPCPDecode ^ *)
PROCEDURE IPCPDecode*;
VAR
 text: Texts.Text; r: Texts.Reader;
 hexPos, beg, end, time: LONGINT;
 hexStr: ARRAY 10 OF CHAR; ch: CHAR;
BEGIN
 Oberon.GetSelection(text, beg, end, time);
 Texts.OpenReader(r, text, beg);
 CASE ReadHexByte(r) OF
     PPPFSM.ConfReq: Out.String("ConfReq"); IPCPConfOptions(r);
  | PPPFSM.ConfAck: Out.String("ConfAck"); IPCPConfOptions(r);
  | PPPFSM.ConfNak: Out.String("ConfNak"); IPCPConfOptions(r);
  | PPPFSM.ConfRej: Out.String("ConfRej"); IPCPConfOptions(r);
  | TermReq: Out.String("TermReq");
  | TermAck: Out.String("TermAck");
  | CodeRej: Out.String("CodeRej");
  ELSE Out.String("*** illegal code ***");
 END;
END IPCPDecode;

(* System.Free PPPTest ~ Builder.Compile * PPPTest.PAPDecode ^ *)
PROCEDURE PAPDecode*;
VAR
 text: Texts.Text; r: Texts.Reader;
 hexPos, beg, end, time, read, len: LONGINT;
 hexStr: ARRAY 10 OF CHAR; ch: CHAR;
BEGIN
 Oberon.GetSelection(text, beg, end, time);
 Texts.OpenReader(r, text, beg);
 CASE ReadHexByte(r) OF
     AuthReq: Out.String("AuthReq");
    Out.Int(ReadHexByte(r), 4); (* identifier (message number) *)
    len := 256*ReadHexByte(r) + ReadHexByte(r); Out.Int(len, 4); Out.Ln();
    read := 4;
    len := ReadHexByte(r);
    Out.String("Peer-ID"); Out.Int(len, 4); Out.Char(" ");
    FOR time := 1 TO len DO Out.Char(CHR(ReadHexByte(r))); END; Out.Ln();
    INC(read, 1+len);
    len := ReadHexByte(r);
    Out.String("Passwd"); Out.Int(len, 4); Out.Char(" ");
    FOR time := 1 TO len DO Out.Char(CHR(ReadHexByte(r))); END; Out.Ln();
    INC(read, 1+len);
  | AuthAck: Out.String("AuthAck");
    Out.Int(ReadHexByte(r), 4); (* identifier (message number) *)
    len := 256*ReadHexByte(r) + ReadHexByte(r); Out.Int(len, 4); Out.Ln();
    read := 4;
    len := ReadHexByte(r);
    Out.String("Msg"); Out.Int(len, 4); Out.Char(" ");
    FOR time := 1 TO len DO Out.Char(CHR(ReadHexByte(r))); END; Out.Ln();
    INC(read, 1+len);
  | AuthNak: Out.String("AuthNak");
    Out.Int(ReadHexByte(r), 4); (* identifier (message number) *)
    len := 256*ReadHexByte(r) + ReadHexByte(r); Out.Int(len, 4); Out.Ln();
    read := 4;
(* ohne Msg-Length (daviddenny/elena99) *)
    Out.String("Msg "); 
    FOR time := 1 TO len-4 DO Out.Char(CHR(ReadHexByte(r))); END; Out.Ln();
    read := len;
(* laut RFC 1334
    len := ReadHexByte(r);
    Out.String("Msg"); Out.Int(len, 4); Out.Char(" ");
    FOR time := 1 TO len DO Out.Char(CHR(ReadHexByte(r))); END; Out.Ln();
    INC(read, 1+len);
*)
  ELSE Out.String("*** illegal code ***");
 END;
END PAPDecode;

(* not sure whether still necessary because log is now going to a Text 
PROCEDURE ShowLogHex*;
CONST W = 16;
VAR t: Texts.Text;  i, j, k, adr, size: LONGINT;  x: SHORTINT;
BEGIN
 NEW(t);  Texts.Open(t, "");
 size := PPPDebug.LogLen;
 i := 0;  adr := SYSTEM.ADR(PPPDebug.Log[0]);
 WHILE (i < size) DO
  WriteHex(adr+i, 8);  Texts.WriteString(w, "H: ");
  (* Do Hex dump. *)
  j := i;
  WHILE (j < i+W) & (j < size) DO
   SYSTEM.GET(adr+j, x);
   WriteHex(x, -3);
   INC(j)
  END;
  (* Spaces between Hex dump and ASCII dump. *)
  FOR k := j TO i+W-1 DO Texts.WriteString(w, "   ") END;
  Texts.WriteString(w, "     ");
  (* Do ASCII dump. *)
  j := i;
  WHILE (j < i+W) & (j < size) DO
   SYSTEM.GET(adr+j, x);
   IF (x > 01FH) & (x < 07FH) THEN Texts.Write(w, CHR(x))
   ELSE Texts.Write(w, ".") END;
   INC(j)
  END;
  Texts.WriteLn(w);
  INC(i, W)
 END;
 Texts.Append(t, w.buf);
 Oberon.OpenText("", t, 400, 200)
END ShowLogHex;
***)

PROCEDURE ShowLog*;
BEGIN
 Oberon.OpenText("PPP.Log", PPPDebug.Log, 400, 200)
END ShowLog;

(** managing the flag for logging PPP traffic for debugging. Default is off *)
PROCEDURE LogState*;
BEGIN
 IF PPPHDLC.debug THEN
  Out.String("PPP logging is on"); Out.Ln;
 ELSE
  Out.String("PPP logging is off"); Out.Ln;
 END;
END LogState;
 
PROCEDURE LogOn*;
BEGIN
 PPPHDLC.debug := TRUE;
 Out.String("PPP logging turned on"); Out.Ln;
END LogOn;

PROCEDURE LogOff*;
BEGIN
 PPPHDLC.debug := FALSE;
 Out.String("PPP logging turned off"); Out.Ln;
END LogOff;

BEGIN
 Texts.OpenWriter(w);  Texts.SetFont(w, Fonts.This("Courier10.Scn.Fnt"))
END PPPTest.

(*
PPPTest.ShowLog
PPPTest.ShowLogHex
*)

PPPTest.LogState
PPPTest.LogOn
PPPTest.LogOff
