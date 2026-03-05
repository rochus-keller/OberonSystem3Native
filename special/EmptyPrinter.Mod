(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE EmptyPrinter; (** non-portable *)  (* pjm *)

IMPORT Files, Modules, Printer, Fonts, Pictures;

TYPE
 EmptyPrinter* = POINTER TO EmptyPrinterDesc;
 EmptyPrinterDesc* = RECORD (Printer.PrinterDesc)
  (*printF*: Files.File*)
 END;
 
PROCEDURE SetMetrics(P: Printer.Printer);
VAR dpi: LONGINT;
BEGIN
 dpi := 300;
 P.Unit := 914400 DIV dpi;
 P.Depth := 24;
 P.Width := 0;  P.Height := 0;
 P.FrameX := 0;  P.FrameY := 0;
 P.FrameW := 0;  P.FrameH := 0
END SetMetrics;

PROCEDURE InitMetrics*(P: Printer.Printer);
BEGIN
 SetMetrics(P)
END InitMetrics;

PROCEDURE Open*(P: Printer.Printer;  printer, options: ARRAY OF CHAR);
BEGIN
 WITH P: EmptyPrinter DO
  P.res := 1; (* no such printer *)
(*
  P.printF := Files.New(printer);
  IF P.printF # NIL THEN
   i := 0;
   WHILE (options[i] # 0X) & (options[i] # Oberon.OptionChar) DO
    (* check options *)
    INC(i)
   END;
   SetMetrics(P)
  END
*)
 END
END Open;

PROCEDURE UseListFont*(P: Printer.Printer;  name: ARRAY OF CHAR);
BEGIN
END UseListFont;

PROCEDURE ReplConst*(P: Printer.Printer;  x, y, w, h: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END ReplConst;
 
PROCEDURE ContString*(P: Printer.Printer;  s: ARRAY OF CHAR;  fnt: Fonts.Font);
BEGIN
 WITH P: EmptyPrinter DO
 END
END ContString;

PROCEDURE String*(P: Printer.Printer;  x, y: INTEGER;  s: ARRAY OF CHAR;  fnt: Fonts.Font);
BEGIN
 WITH P: EmptyPrinter DO
 END
END String;

PROCEDURE ReplPattern*(P: Printer.Printer;  x, y, w, h, col: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END ReplPattern;

PROCEDURE Picture*(P: Printer.Printer; pict: Pictures.Picture; sx, sy, sw, sh, dx, dy, dw, dh, mode: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END Picture;

PROCEDURE Circle*(P: Printer.Printer;  x0, y0, r: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END Circle;

PROCEDURE Ellipse*(P: Printer.Printer;  x0, y0, a, b: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END Ellipse;

PROCEDURE Line*(P: Printer.Printer;  x0, y0, x1, y1: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END Line;

PROCEDURE UseColor*(P: Printer.Printer;  red, green, blue: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END UseColor;

PROCEDURE Spline*(P: Printer.Printer;  x0, y0, n, open: INTEGER;  VAR X, Y: ARRAY OF INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END Spline;

PROCEDURE Page*(P: Printer.Printer;  nofcopies: INTEGER);
BEGIN
 WITH P: EmptyPrinter DO
 END
END Page;

PROCEDURE Close*(P: Printer.Printer);
BEGIN
 WITH P: EmptyPrinter DO
  (* Printer.Spool(P.printF);  P.res := Printer.res *)
 END
END Close;

PROCEDURE GetMetric* (P: Printer.Printer;  fnt: Fonts.Font): Fonts.Font;
BEGIN
 (* return printer metric for font *)
 RETURN NIL
END GetMetric;

PROCEDURE NewPrinter*(): Printer.Printer;
VAR P: EmptyPrinter;
BEGIN
 NEW(P);
 P.name := "EmptyPrinter.Install";
 P.InitMetrics := InitMetrics;
 P.Open := Open;
 P.Close := Close;
 P.Page := Page;
 P.ReplConst := ReplConst; 
 P.ReplPattern := ReplPattern;
 P.Line := Line;
 P.Circle := Circle;
 P.Ellipse := Ellipse;
 P.Spline := Spline;
 P.Picture := Picture;
 P.UseListFont := UseListFont;
 P.String := String;
 P.ContString := ContString;
 P.UseColor := UseColor;
 P.GetMetric := GetMetric;
 RETURN P
END NewPrinter;

PROCEDURE Install*;
BEGIN
 (* register font loader for special metrics, if needed *)
 Printer.Install(NewPrinter());
END Install;

PROCEDURE Cleanup;
BEGIN
 IF (Printer.current # NIL) & (Printer.current IS EmptyPrinter) THEN
  Printer.current := NIL
 END
END Cleanup;

BEGIN
 Modules.InstallTermHandler(Cleanup)
END EmptyPrinter.

System.Free EmptyPrinter ~

EmptyPrinter.Install
