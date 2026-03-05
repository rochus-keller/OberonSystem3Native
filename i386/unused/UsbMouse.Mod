(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon Usb mouse support

Reference: http://www.usb.org

30.09.2000 cp first release
18.10.2000 cp fix packetsize of interrupt endpoint and add warning message if mouse fails
*)

MODULE UsbMouse;  (** non-portable **) (** cp **)

IMPORT Usb, Kernel, SYSTEM, Input;

CONST

VersionString = "Usb Mousedriver 1.0";

TYPE

 Mouse = POINTER TO RECORD
  Device : Usb.UsbDevice;
  Req : Usb.UsbTReq;
  Message : ARRAY 64 OF CHAR;
  next : Mouse;
 END;

VAR

 MouseDriver : Usb.UsbDriver;
 MouseList : Mouse;

PROCEDURE MouseInputPoller (VAR keys: SET; VAR dx, dy, dz: INTEGER): BOOLEAN;
VAR
 ActionFlag : BOOLEAN;
 act : Mouse;
BEGIN

 IF MouseList = NIL THEN RETURN FALSE END; (* save some time *)
 
 dx := 0; dy := 0; dz := 0; keys := {}; ActionFlag := FALSE; act := MouseList;
 
 WHILE act # NIL DO
  IF act.Req # NIL THEN
   Usb.OpProbeTrans(act.Req); (* poll it *)
   IF (act.Req.Status * Usb.ResInProgress) = {} THEN
    IF (act.Req.Status * (Usb.ResOK + Usb.ResShortPacket) # {}) & (act.Req.BufferLen >= 3) THEN
     dx := dx + SYSTEM.VAL(SHORTINT, act.Message[1]);
     dy := dy + SYSTEM.VAL(SHORTINT, act.Message[2]);
     dz := dz + SYSTEM.VAL(SHORTINT, act.Message[3]);
     IF (SYSTEM.VAL(SET, act.Message[0]) * {0}) # {} THEN INCL(keys, 2); END;
     IF (SYSTEM.VAL(SET, act.Message[0]) * {1}) # {} THEN INCL(keys, 0); END;
     IF (SYSTEM.VAL(SET, act.Message[0]) * {2}) # {} THEN INCL(keys, 1); END;
     Usb.OpRestartInterrupt(act.Req);
     ActionFlag := TRUE;
    ELSE     
     Kernel.WriteString("Usb Mouse error. Disabling mouse polling for this mouse."); Kernel.WriteLn;
     Usb.OpDeleteTrans(act.Req); act.Req := NIL;
     ActionFlag := TRUE; (* Important! Stops polling if an error occurs during a mouse-click *)
    END;
   END;
  END;
  act := act.next;
 END;

 RETURN ActionFlag;

END MouseInputPoller;

PROCEDURE MouseProbe(dev : Usb.UsbDevice; intfc : INTEGER);
VAR
 if : Usb.UsbDeviceInterface;
 m : Mouse;
 req : Usb.UsbTReq;
BEGIN
 
 if := dev.ActConfiguration.Interfaces[intfc];
  
 IF if.bInterfaceClass # 3 THEN RETURN END;
 IF if.bInterfaceSubClass # 1 THEN RETURN END;
 IF if.bInterfaceProtocol # 2 THEN RETURN END;
 IF if.bNumEndpoints # 1 THEN RETURN END;

 Kernel.WriteString("Usb Mouse found."); Kernel.WriteLn;

 if.Driver := MouseDriver;

 NEW(m);
 NEW(req);

 m.Device := dev;
 m.Req := req;
 m.next := MouseList;

 (* Start the interrupt transaction *)

 req.Device := dev;
 req.Endpoint := SHORT(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, if.Endpoints[0].bEndpointAddress) * {0,1,2,3,7}));
 req.Typ := Usb.TransferInterrupt;
 req.Buffer := SYSTEM.ADR(m.Message[0]);
 req.BufferLen := dev.MaxPacketSizeIn[req.Endpoint MOD 16];
 req.Timeout := 0;
 req.IRQInterval := if.Endpoints[0].bInterval;
 Usb.OpTransReq(req);

 (* Add this mouse to the polling list *)

 MouseList := m;
 
END MouseProbe;

PROCEDURE MouseDisconnect(dev : Usb.UsbDevice);
VAR
 tmp, last : Mouse;
BEGIN

 Kernel.WriteString("Usb Mouse disconnecting."); Kernel.WriteLn;

 tmp := MouseList; last := NIL;

 WHILE tmp # NIL DO
  IF tmp.Device = dev THEN
   IF tmp.Req # NIL THEN Usb.OpDeleteTrans(tmp.Req); END;
   IF last = NIL THEN MouseList := tmp.next; ELSE last.next := tmp.next; END;
   tmp := tmp.next;
  ELSE
   last := tmp; tmp := tmp.next;
  END;
 END;
 
END MouseDisconnect;

PROCEDURE Init*();
BEGIN
 (* dummy *)
END Init;

PROCEDURE Cleanup();
VAR
 act : Mouse;
BEGIN
 act := MouseList;
 WHILE act # NIL DO
  IF act.Req # NIL THEN Usb.OpDeleteTrans(act.Req); act.Req := NIL END;
  act := act.next;
 END;
 Input.RemoveMouse(MouseInputPoller);
 Usb.RemoveDriver(MouseDriver);
END Cleanup;

BEGIN

 MouseList := NIL;

 NEW(MouseDriver);
 MouseDriver.DriverName := VersionString;
 MouseDriver.OpProbe := MouseProbe;
 MouseDriver.OpDisconnect := MouseDisconnect;
 Usb.RegisterDriver(MouseDriver);

 Input.AddMouse(MouseInputPoller);

 Kernel.InstallTermHandler(Cleanup);

END UsbMouse.

(** Init: UsbMouse.Init **)
