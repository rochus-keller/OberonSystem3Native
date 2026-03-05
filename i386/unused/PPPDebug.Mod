(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE PPPDebug; (** non-portable *) (* rb, 1996 *)
(* $VCS   4, Edgar@EdgarSchwarz.de, 25 Apr :0, 10:31:10 $
Logging to kernel log. Interactive display with System.OpenKernelLog
    $Log$
$   4, Edgar@EdgarSchwarz.de, 25 Apr :0, 10:31:10
now writing to a Text: PPPDebug.Log
$   3, Edgar@EdgarSchwarz.de, 24 Apr :0, 12:3:18
problem with Kernel.WriteHex fixed
$   2, Edgar.Schwarz@z.zgs.de, 18 Aug 99, 21:31:56
using Kernel log stuff instead of own log buffer
$   1, Edgar.Schwarz@z.zgs.de, 28 Feb 99, 22:11:59
version for PPP 1.0.0
*)
 IMPORT SYSTEM, Texts;

 VAR
  HexChar: ARRAY 17 OF CHAR;
  W: Texts.Writer; Log*: Texts.Text;

 PROCEDURE String*(s: ARRAY OF CHAR);
 BEGIN Texts.WriteString(W, s); END String;
 
 PROCEDURE Int*(x, n:LONGINT);
 BEGIN Texts.WriteInt(W, x, n); END Int;
 
 PROCEDURE IntBin* (n:INTEGER);
 BEGIN String(" ");  Int(n, 1);  String(" ") END IntBin;
 
 PROCEDURE LIntBin* (n:LONGINT);
 BEGIN String(" ");  Int(n, 1);  String(" ") END LIntBin;
 
 PROCEDURE Hex*(n:LONGINT);
 BEGIN Texts.WriteHex(W, n); END Hex;
 
 PROCEDURE HexByte*(b: SYSTEM.BYTE);
 BEGIN
  Texts.Write(W, HexChar[(ORD(b) MOD 256) DIV 16]); 
  Texts.Write(W, HexChar[(ORD(b) MOD 256) MOD 16]); 
 END HexByte;
 
 PROCEDURE Char*(ch: CHAR);
 BEGIN Texts.Write(W, ch) END Char;
 
 PROCEDURE Ln*;
 BEGIN Texts.WriteLn(W); Texts.Append(Log, W.buf); END Ln;
 
 PROCEDURE LHex* (label: ARRAY OF CHAR; val: LONGINT);
 BEGIN String(label); String(": "); Hex(val); Ln END LHex;
 
 PROCEDURE Init * ();
 BEGIN
  HexChar := "0123456789ABCDEF";
  NEW(Log); Texts.Open(Log, "");
  Texts.OpenWriter(W);
  Texts.WriteString(W, "2.1/es/25.04.2000"); Texts.WriteLn(W);
  Texts.Append(Log, W.buf);
 END Init; 

BEGIN Init();
END PPPDebug.
