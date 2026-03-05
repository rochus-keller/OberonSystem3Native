(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
SaveDecay: A Sample fader for SaveScreen.
1999.11.05 - Ben Smith-Mannschott
 - initial release
*)

MODULE SaveDecay;

 IMPORT Out, Modules, SaveScreen, Display;
 CONST
  versionString = "SaveDecay 1999.11.05";
  
 VAR
  depth: ARRAY 1280 OF INTEGER;
 
 PROCEDURE Start;
  VAR i: INTEGER;
 BEGIN
  SaveScreen.SetFrameRate(30);
  FOR i := 0 TO Display.Width - 1 DO
   depth[i] := Display.Height
  END;
 END Start;

 PROCEDURE Step;
  VAR 
   i, x: INTEGER;
 BEGIN
  FOR i := 1 TO 128  DO
   x := SaveScreen.Rand(Display.Width);
   DEC(depth[x]);
   IF depth[x] < 0 THEN depth[x] := 0 END;
   Display.Dot(Display.FG, x, depth[x], Display.replace);
  END;
 END Step;
 
 PROCEDURE Stop;
 BEGIN
 END Stop;
 
 PROCEDURE Install*;
 BEGIN
  SaveScreen.InstallFader(Start, Step, Stop);
 END Install;
 
 PROCEDURE Remove;
 BEGIN
  SaveScreen.RemoveFader(Start, Step, Stop);
 END Remove;

BEGIN
 Modules.InstallTermHandler(Remove);
 Out.String(versionString); Out.Ln;
END SaveDecay.Install