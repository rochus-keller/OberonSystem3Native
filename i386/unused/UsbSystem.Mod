(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon UsbSystem (User frontend, Hub poller)

Reference: http://www.usb.org

17.11.2000 cp first release
*)

MODULE UsbSystem; (** non-portable **)  (** cp **)

IMPORT Kernel, Oberon, Input, Usb, UsbUhci;

VAR

 UsbTask : Oberon.Task;

PROCEDURE OberonHandler(me : Oberon.Task);
BEGIN

 me.time := Oberon.Time() + Input.TimeUnit DIV 3; (* 3 times a second *)
 Usb.Connect();

END OberonHandler;

PROCEDURE Cleanup();
BEGIN
 IF UsbTask # NIL THEN
  Oberon.Remove(UsbTask);
  UsbTask := NIL;
 END;
END Cleanup;

PROCEDURE Start*();
BEGIN
 (* dummy *)
END Start;

BEGIN

 UsbUhci.Init;

 (* future improvement: add UsbOhci.Init here :) *)

 Usb.Connect;

 Kernel.InstallTermHandler(Cleanup);

 NEW(UsbTask);
 UsbTask.time := Oberon.Time();
 UsbTask.safe := FALSE;
 UsbTask.handle := OberonHandler;
 Oberon.Install(UsbTask);

END UsbSystem.

(** Init: UsbSystem.Start **)
