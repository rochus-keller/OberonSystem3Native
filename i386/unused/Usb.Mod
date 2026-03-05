(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon Usb core support

Reference: http://www.usb.org

30.09.2000 cp first release
17.10.2000 cp Removed the oberon task (=> Import of Oberon and Input module not needed anymore)
                        Usb.Connect will now be called from an other module periodically
18.10.2000 cp add new result code and two arrays for easier&faster access to the pipes maxpacketsizes,
                        Usb.Info: some cosmetic changes (no long lines for Kernel.Log)
20.10.2000 cp modified "handy" helper procedures, so that they don't invite people to fragment the memory
                        (one has to pass an (empty) TReq record, this is not anymore allocated on the fly by Usb.Mod)
*)

MODULE Usb; (** non-portable **)  (** cp **)

IMPORT SYSTEM, Kernel;

CONST

 (** Oberon USB specific hub port status bits **)

 PortStatusDevicePresent* = {0};
 PortStatusEnabled* = {1};
 PortStatusLowSpeed* = {2};
 PortStatusHighSpeed* = {3};
 PortStatusReset* = {4};
 PortStatusError* = {5};

 (** Transfer types for TReq **)
 
 TransferControl* = 1;
 TransferInterrupt* = 2;
 TransferBulk* = 3;
 TransferISO* = 4;

 (** Result codes for TReq **)
 
 ResOK* = {0};
 ResNAK* = {1};
 ResCRCTimeout* = {2};
 ResBitStuff* = {3};
 ResStalled* = {4};
 ResDataBuffer* = {5};
 ResBabble* = {6};
 ResShortPacket* = {7};
 ResInProgress* = {8};
 ResInternal* = {9};
 ResDisconnect* = {10};

 (** Constants defined in Usb Specification 1.1 / 2.0 **)

 CommandGetStatus* = 0;
 CommandClearFeature* = 1;
 CommandSetFeature* = 3;
 CommandSetAddress* = 5;
 CommandGetDescriptor* = 6;
 CommandSetDescriptor* = 7;
 CommandGetConfiguration* = 8;
 CommandSetConfiguration* = 9;
 CommandGetInterface* = 10;
 CommandSetInterface* = 11;
 CommandSynchFrame* = 12;

 DescriptorDevice* = 1;
 DescriptorConfiguration* = 2; 
 DescriptorString* = 3;
 DescriptorInterface* = 4;
 DescriptorEndpoint* = 5;
 DescriptorHub* = 29H;

 FeatureDeviceRemoteWakeup* = 1;
 FeatureEndpointHalt* = 0;

 (** Usb HID Specification **)

 CommandGetReport* = 1;
 CommandGetIdle* = 2;
 CommandGetProtocol* = 3;
 CommandSetReport* = 9;
 CommandSetIdle* = 10;
 CommandSetProtocol* = 11;

 ReportTypeInput* = 1;
 ReportTypeOutput* = 2;
 ReportTypeFeature* = 3;

TYPE

(** Usb host controller **)

UsbController* = POINTER TO RECORD

  (** Root Hub operations **)

  OpReset* : PROCEDURE(con : UsbController);
  OpGetPortStatus* : PROCEDURE(con : UsbController; port : INTEGER):SET;
  OpGetPortCount* : PROCEDURE(con : UsbController) : INTEGER;
  OpEnablePort* : PROCEDURE(con : UsbController; port : INTEGER);
  OpDisablePort* : PROCEDURE(con : UsbController; port : INTEGER);

  (** Transfer operations **)

  OpSendReq* : PROCEDURE(con : UsbController; req : UsbTReq);
  OpProbeTrans* : PROCEDURE(con : UsbController; req : UsbTReq);
  OpDeleteTrans* : PROCEDURE(con : UsbController; req : UsbTReq);
  OpRestartInterrupt* : PROCEDURE(con : UsbController; req : UsbTReq);

  (* Internal data *)

  RootHub : UsbDevice;
  AdrRange : ARRAY 128 OF BOOLEAN;
  ActiveState : BOOLEAN;
  next : UsbController;

 END;

(** Usb Device Driver **)

UsbDriver* = POINTER TO RECORD
  DriverName*: ARRAY 32 OF CHAR;
  OpProbe* : PROCEDURE(dev : UsbDevice; interface : INTEGER);
  OpDisconnect* : PROCEDURE(dev : UsbDevice);
  next : UsbDriver;
END;

(** information about an attached Usb device **)

UsbDevice* = POINTER TO RECORD
  Address* : INTEGER;
  LowSpeed* : BOOLEAN;
  HighSpeed* : BOOLEAN;
  Descriptor* : UsbDeviceDescriptor;
  Configurations* : POINTER TO ARRAY OF UsbDeviceConfiguration;
  ActConfiguration* : UsbDeviceConfiguration;
  DataToggleIn* : ARRAY 16 OF BOOLEAN;
  DataToggleOut* : ARRAY 16 OF BOOLEAN;
  MaxPacketSizeIn* : ARRAY 16 OF INTEGER;
  MaxPacketSizeOut* : ARRAY 16 OF INTEGER;
  Controller: UsbController; (* private, so every transaction can only be started by Usb.Mod *)
  Port : INTEGER;
  Parent : UsbDevice;
  HubFlag : BOOLEAN;
  Ports : INTEGER;
  HubTime2Good : INTEGER;
  HubPortDevices : POINTER TO ARRAY OF UsbDevice;
  HubPortPermanentDisabled : POINTER TO ARRAY OF BOOLEAN;
END;

(** UsbDeviceDescriptor: As specified in the Universal Serial Bus Specification 1.1/2.0 **)

UsbDeviceDescriptor* = POINTER TO RECORD
  bcdUSB* : INTEGER;
  bDeviceClass* : INTEGER;
  bDeviceSubClass* : INTEGER;
  bDeviceProtocol* : INTEGER;
  bMaxPacketSize0* : INTEGER;
  idVendor* : INTEGER;
  idProduct* : INTEGER;
  bcdDevice* : INTEGER;
  iManufacturer* : INTEGER;
  iProduct* : INTEGER;
  iSerialNumber* : INTEGER;
  bNumConfigurations* : INTEGER;
END;

(** As specified in the Universal Serial Bus Specification 1.1/2.0 **)

UsbDeviceConfiguration* = POINTER TO RECORD
  wTotalLength* : INTEGER;
  bNumInterfaces* : INTEGER;
  bConfigurationValue* : INTEGER;
  iConfiguration* : INTEGER;
  bmAttributes* : SET;
  MaxPower* : INTEGER;
  Interfaces* : POINTER TO ARRAY OF UsbDeviceInterface;
END;

(** UsbDeviceInterface: As specified in the Universal Serial Bus Specification 1.1/2.0

Oberon Usb addition: "Driver" points to the device driver for this interface, NIL means no driver (yet) attached
to this interface

**)


UsbDeviceInterface* = POINTER TO RECORD
  bInterfaceNumber* : INTEGER;
  bAlternateSetting* : INTEGER;
  bNumEndpoints* : INTEGER;
  bInterfaceClass* : INTEGER;
  bInterfaceSubClass* : INTEGER;
  bInterfaceProtocol* : INTEGER;
  iInterface* : INTEGER;
  NumAlternateInterfaces*: INTEGER;
  AlternateInterfaces*: POINTER TO ARRAY OF UsbDeviceInterface;
  Endpoints* : POINTER TO ARRAY OF UsbDeviceEndpoint;
  Driver* : UsbDriver;
END;

(** UsbDeviceEndpoint: As specified in the Universal Serial Bus Specification 1.1/2.0 **)

UsbDeviceEndpoint* = POINTER TO RECORD
  bEndpointAddress* : INTEGER;
  bmAttributes* : SET;
  wMaxPacketSize* : INTEGER;
  bInterval* : INTEGER;
END;

(** RECORD where host controllers can store host controller specific data **)

UsbConSpecData* = POINTER TO RECORD
 END;

(** Information about a transfer request **)

UsbTReq* = POINTER TO RECORD

 Device* : UsbDevice;
 Endpoint* : INTEGER;
 Typ* : INTEGER;
 Status* : SET;
 Buffer* : LONGINT;
 BufferLen* : LONGINT;
 ControlMessage* : LONGINT;
 IRQInterval* : INTEGER;
 Timeout* : LONGINT;
 ConSpec* : UsbConSpecData;
 next* : UsbTReq;
END;

VAR
 UsbControllerList : UsbController;
 UsbDriverList : UsbDriver;
 ConnectReq : UsbTReq; (* this TReq will be used by the hub driver *)

(* ========================================================================= *)
(*                       Some helpers                                                                                                       *)
(* ========================================================================= *)

(* Kernel.WriteHex (or was it PrintHex?) show pads with too many zeros, not handy *)

PROCEDURE PrintHex(was: LONGINT);
VAR z,d,h,i:LONGINT;
BEGIN
 z := 0;
 d := 16*16*16*16*16*16*16; (* what a quick hack *)
 FOR i:=0 TO 7 DO
  h := (was DIV d) MOD 16;
  IF (z = 1) OR (h # 0) OR (i = 7) THEN
   z := 1;
   IF h < 10 THEN Kernel.WriteInt(h,0); ELSE Kernel.WriteChar(CHR(ORD("A")+h-10)); END;
  END;
  d:=d DIV 16;
 END;
END PrintHex;

PROCEDURE MilliWait(ms : LONGINT);
VAR
 t: Kernel.MilliTimer;
BEGIN

 Kernel.SetTimer(t, ms);
 REPEAT
  (* active wait - not very efficient - could do some FFT for seti@home here :) *)
 UNTIL Kernel.Expired(t)

END MilliWait;

(* ========================================================================= *)
(*                       Debugging support                                                                                              *)
(* ========================================================================= *)

(* I don't delete it, because it is perhaps useful for further development

PROCEDURE HumanDevice(dev : UsbDevice);
VAR
 i,k,n : INTEGER;
BEGIN

 Out.String("Address: "); Out.Int(dev.Address, 0); Out.Ln;
 Out.String("# Configurations: "); Out.Int(dev.Descriptor.bNumConfigurations, 0); Out.Ln;

 FOR i:=0 TO dev.Descriptor.bNumConfigurations - 1 DO
  Out.String (" Configuration "); Out.Int(i, 0); Out.String(":"); Out.Ln;
  Out.String(" Interfaces: "); Out.Int(dev.Configurations[i].bNumInterfaces, 0); Out.Ln;
  FOR k:=0 TO dev.Configurations[i].bNumInterfaces - 1 DO
   Out.String("  Interface: "); Out.Int(k, 0); Out.String(":"); Out.Ln;
   Out.String("  Class: "); PrintHex(dev.Configurations[i].Interfaces[k].bInterfaceClass); Out.Ln;
   Out.String("H  SubClass: "); PrintHex(dev.Configurations[i].Interfaces[k].bInterfaceSubClass); Out.Ln;
   Out.String("H  Protocol: "); Out.Int(dev.Configurations[i].Interfaces[k].bInterfaceProtocol, 0); Out.Ln;
   Out.String("  Endpoints: "); Out.Int(dev.Configurations[i].Interfaces[k].bNumEndpoints, 0); Out.Ln;
   FOR n:=0 TO dev.Configurations[i].Interfaces[k].bNumEndpoints -1 DO
    Out.String("   Endpoint: "); Out.Int(n, 0); Out.String(":"); Out.Ln;
    Out.String("   Address: "); Out.Int(dev.Configurations[i].Interfaces[k].Endpoints[n].bEndpointAddress, 0); Out.Ln;
   END;
  END;
 END;

END HumanDevice;

PROCEDURE HumanPortStatus(status : SET);
BEGIN

 Out.String("Port Status:"); Out.Ln;

 IF (status * PortStatusDevicePresent) # {} THEN Out.String("  DevicePresent"); Out.Ln; END;
 IF (status * PortStatusEnabled) # {} THEN Out.String("  Port enabled"); Out.Ln; END;
 IF (status * PortStatusLowSpeed) # {} THEN Out.String("  Lowspeed"); Out.Ln; END;
 IF (status * PortStatusHighSpeed) # {} THEN Out.String("  Highspeed"); Out.Ln; END;
 IF (status * PortStatusReset) # {} THEN Out.String("  in Reset"); Out.Ln; END;
 IF (status * PortStatusError) # {} THEN Out.String("  Port Status Error"); Out.Ln; END;

END HumanPortStatus;

*)

(** ========================================================================= **)
(**                       Entrypoints for controllers                                                                                   **)
(** ========================================================================= **)

PROCEDURE RegisterController*(con : UsbController);
VAR
 i : INTEGER;
 hubdev : UsbDevice;
BEGIN

 NEW(hubdev);

 hubdev.Controller := con;
 hubdev.Parent := hubdev;
 hubdev.HubFlag := TRUE;
 hubdev.Ports := con.OpGetPortCount(con);
 NEW(hubdev.HubPortDevices, hubdev.Ports);
 NEW(hubdev.HubPortPermanentDisabled, hubdev.Ports);

 con.RootHub := hubdev;

 FOR i:= 0 TO 127 DO
  con.AdrRange[i] := FALSE;
 END;

 con.ActiveState := TRUE;

 con.next := UsbControllerList;
 UsbControllerList := con;

(* Connect(); *)

END RegisterController;

PROCEDURE RemoveController*(con: UsbController);
VAR
 p, q: UsbController;
BEGIN

 con.ActiveState := FALSE;

 RemoveDevice(con.RootHub);

 IF UsbControllerList = con THEN
  UsbControllerList := con.next
 ELSE
  q := UsbControllerList; p := q.next;
  WHILE (p # NIL) & (p # con) DO q := p; p := p.next END;
  IF p # NIL THEN q.next := p.next END
 END;

END RemoveController;

(** ========================================================================= **)
(**                       Entrypoints for drivers                                                                                         **)
(** ========================================================================= **)

PROCEDURE RegisterDriver*(drv : UsbDriver);
BEGIN
 IF LEN(drv.DriverName) = 0 THEN
  HALT(303);
 END;
 drv.next := UsbDriverList;
 UsbDriverList := drv;
 ProbeDrivers();
END RegisterDriver;

PROCEDURE RemoveDriverChain(dev : UsbDevice; drv : UsbDriver);
VAR
 n : INTEGER;
BEGIN

 IF dev.HubFlag THEN
  FOR n:=0 TO dev.Ports - 1 DO
   IF dev.HubPortDevices[n] # NIL THEN
    RemoveDriverChain(dev.HubPortDevices[n], drv);
   END;
  END;
 ELSE
  FOR n:=0 TO dev.ActConfiguration.bNumInterfaces - 1 DO
   IF dev.ActConfiguration.Interfaces[n].Driver = drv THEN
    dev.ActConfiguration.Interfaces[n].Driver := NIL;
    (* and configure drive to init state - hack - todo *)
   END;
  END;
 END;

END RemoveDriverChain;

PROCEDURE RemoveDriver*(drv: UsbDriver);
VAR
 p, q: UsbDriver;
 con : UsbController;
BEGIN

 con := UsbControllerList;

 WHILE con # NIL DO
  RemoveDriverChain(con.RootHub, drv);
  con := con.next;
 END;

 IF UsbDriverList = drv THEN
  UsbDriverList := drv.next
 ELSE
  q := UsbDriverList; p := q.next;
  WHILE (p # NIL) & (p # drv) DO q := p; p := p.next END;
  IF p # NIL THEN q.next := p.next END
 END;

END RemoveDriver;

(** ========================================================================= **)
(**                       Wrappers to hide controllers (so drivers cannot talk directly to them)               **)
(** ========================================================================= **)

PROCEDURE OpTransReq*(req : UsbTReq);
BEGIN
 IF req.Device.Controller.ActiveState = FALSE THEN
  req.Status := ResDisconnect;
 ELSE
  req.Device.Controller.OpSendReq(req.Device.Controller, req);
 END;

END OpTransReq;

PROCEDURE OpProbeTrans*(req : UsbTReq);
BEGIN
 IF req.Device.Controller.ActiveState = FALSE THEN
  req.Status := ResDisconnect;
 ELSE
  req.Device.Controller.OpProbeTrans(req.Device.Controller, req);
 END;
END OpProbeTrans;

PROCEDURE OpDeleteTrans*(req : UsbTReq);
BEGIN
 IF req.Device.Controller.ActiveState = FALSE THEN
  req.Status := ResDisconnect;
 ELSE
  req.Device.Controller.OpDeleteTrans(req.Device.Controller, req);
 END;
END OpDeleteTrans;

PROCEDURE OpRestartInterrupt*(req : UsbTReq);
BEGIN
 IF req.Device.Controller.ActiveState = FALSE THEN
  req.Status := ResDisconnect;
 ELSE
  req.Device.Controller.OpRestartInterrupt(req.Device.Controller, req);
 END;
END OpRestartInterrupt;

(** ========================================================================= **)
(**                       Helpers (not essential, but handy)                                                                       **)
(** ========================================================================= **)

PROCEDURE ClearHalt*(req : UsbTReq; dev : UsbDevice; endpoint : INTEGER) : BOOLEAN;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN

 IF (SYSTEM.VAL(SET, endpoint) * {7}) = {} THEN
  dev.DataToggleOut[endpoint MOD 16] := FALSE;
 ELSE
  dev.DataToggleIn[endpoint MOD 16] := FALSE;
 END;

 Message[0] := CHR(2); (* Recipient is endpoint *)
 Message[1] := CHR(CommandClearFeature);
 Message[2] := CHR(FeatureEndpointHalt);
 Message[3] := CHR(0);
 Message[4] := CHR(endpoint);
 Message[5] := CHR(0);
 Message[6] := CHR(0);
 Message[7] := CHR(0);

 res := OpSendControl(req, dev, 0, Message, Message, 0, 0, 500);

 RETURN res = ResOK;

END ClearHalt;

PROCEDURE SetIdle*(req : UsbTReq; dev : UsbDevice; if : INTEGER) : BOOLEAN;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN

 Message[0] := CHR(33);
 Message[1] := CHR(CommandSetIdle);
 Message[2] := CHR(0); (* applicable to all reports *)
 Message[3] := CHR(0); (* indefinite duration *)
 Message[4] := CHR(dev.ActConfiguration.Interfaces[if].bInterfaceNumber);
 Message[5] := CHR(0);
 Message[6] := CHR(0);
 Message[7] := CHR(0);

 res := OpSendControl(req, dev, 0, Message, Message, 0, 0, 500);

 RETURN res = ResOK;

END SetIdle;

PROCEDURE SetProtocol*(req : UsbTReq; dev : UsbDevice; if : INTEGER; proto : INTEGER) : BOOLEAN;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN

 Message[0] := CHR(33);
 Message[1] := CHR(CommandSetProtocol);
 Message[2] := CHR(proto);
 Message[3] := CHR(SYSTEM.LSH(proto, -8));
 Message[4] := CHR(dev.ActConfiguration.Interfaces[if].bInterfaceNumber);
 Message[5] := CHR(0);
 Message[6] := CHR(0);
 Message[7] := CHR(0);

 res := OpSendControl(req, dev, 0, Message, Message, 0, 0, 500);

 RETURN res = ResOK;

END SetProtocol;


PROCEDURE SetReport*(req : UsbTReq; dev : UsbDevice; if : INTEGER; rtype, rid : INTEGER;
 VAR buff: ARRAY OF CHAR; ofs, len : INTEGER) : BOOLEAN;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN

 Message[0] := CHR(33);
 Message[1] := CHR(CommandSetReport);
 Message[2] := CHR(rid);
 Message[3] := CHR(rtype);
 Message[4] := CHR(dev.ActConfiguration.Interfaces[if].bInterfaceNumber);
 Message[5] := CHR(0);
 Message[6] := CHR(len);
 Message[7] := CHR(SYSTEM.LSH(len, -8));

 res := OpSendControl(req, dev, 0, Message, buff, ofs, len, 500);

 RETURN res = ResOK;

END SetReport;

(** Blocking interrupt support **)
(** This is not essential - Just handy so that you don't have to build the TReq yourself **)

PROCEDURE OpSendInterrupt*(req : UsbTReq; dev: UsbDevice; endpoint: INTEGER;
 VAR buf : ARRAY OF CHAR; ofs, len, timeout : LONGINT; irqintervall : INTEGER) : SET;
BEGIN

 IF dev.Controller.ActiveState = FALSE THEN RETURN ResDisconnect END;

 IF LEN(buf) < (len + ofs)  THEN
  Kernel.WriteString("Usb OpSendInterrupt: buffer too short"); Kernel.WriteLn;
  HALT(303);
 END;

 req.Device := dev;
 req.Endpoint := endpoint;
 req.Typ := TransferInterrupt;
 req.Buffer := SYSTEM.ADR(buf[ofs]);
 req.BufferLen := len;
 req.Timeout := timeout;
 req.IRQInterval := irqintervall;

 dev.Controller.OpSendReq(req.Device.Controller, req);

 RETURN req.Status;

END OpSendInterrupt;

(** Blocking control support **)
(** This is not essential - Just handy so that you don't have to build the TReq yourself **)

PROCEDURE OpSendControl*(req : UsbTReq; dev : UsbDevice; endpoint : INTEGER; VAR msg : ARRAY OF CHAR;
 VAR buf : ARRAY OF CHAR; ofs, len, timeout : LONGINT) : SET;
BEGIN

 IF dev.Controller.ActiveState = FALSE THEN RETURN ResDisconnect END;

 IF LEN(buf) < (len + ofs)  THEN
  Kernel.WriteString("Usb OpSendControl: buffer too short"); Kernel.WriteLn;
  HALT(303);
 END;

 req.Device := dev;
 req.Endpoint := endpoint;
 req.Typ := TransferControl;
 req.Buffer := SYSTEM.ADR(buf[ofs]);
 req.BufferLen := len;
 req.ControlMessage := SYSTEM.ADR(msg[0]);
 req.Timeout := timeout;

 dev.Controller.OpSendReq(req.Device.Controller, req);

 RETURN req.Status;

END OpSendControl;

(** Blocking bulk Support **)
(** This is not essential - Just handy so that you don't have to build the TReq yourself **)

PROCEDURE OpSendBulk*(req : UsbTReq; dev : UsbDevice; endpoint : INTEGER;
 VAR buf : ARRAY OF CHAR; ofs, len, timeout : LONGINT) : SET;
BEGIN

 IF dev.Controller.ActiveState = FALSE THEN RETURN ResDisconnect END;

 IF LEN(buf) < (len + ofs)  THEN
  Kernel.WriteString("Usb OpSendBulk: buffer too short"); Kernel.WriteLn;
  HALT(303);
 END;
 
 req.Device := dev;
 req.Endpoint := endpoint;
 req.Typ := TransferBulk;
 req.Buffer := SYSTEM.ADR(buf[ofs]);
 req.BufferLen := len;
 req.Timeout := timeout;

 dev.Controller.OpSendReq(req.Device.Controller, req);

 RETURN req.Status;

END OpSendBulk;

(* ========================================================================= *)
(*                       Integrated Hub driver                                                                                          *)
(* ========================================================================= *)

PROCEDURE HubDriverProbe(dev : UsbDevice):BOOLEAN;
VAR
 Buffer : ARRAY 8 OF CHAR;
 intfc : UsbDeviceInterface;
 res : BOOLEAN;
 i : INTEGER;
BEGIN

 IF dev.Descriptor.bNumConfigurations # 1 THEN RETURN FALSE; END;
 IF dev.Configurations[0].bNumInterfaces # 1 THEN RETURN FALSE; END;

 intfc := dev.Configurations[0].Interfaces[0];

 IF intfc.bInterfaceClass # 9 THEN RETURN FALSE; END;
 IF intfc.bInterfaceSubClass # 0 THEN RETURN FALSE; END;
 IF intfc.bNumEndpoints # 1 THEN RETURN FALSE; END;
 IF intfc.bInterfaceProtocol # 0 THEN RETURN FALSE; END;

 res := GetDescriptor(dev, 128+32 , 29H, 0, 8, Buffer);
 IF res = FALSE THEN RETURN FALSE END;

 dev.Ports := ORD(Buffer[2]);
 NEW(dev.HubPortDevices, dev.Ports);
 NEW(dev.HubPortPermanentDisabled, dev.Ports);
 dev.HubTime2Good := ORD(Buffer[5]) * 2; (* PowerOn 2 PowerGood measured in 2ms steps *)

 Kernel.WriteString("Usb: Hub with "); Kernel.WriteInt(dev.Ports, 0); Kernel.WriteString(" ports detected."); Kernel.WriteLn;

 dev.HubFlag := TRUE;

 FOR i:=0 TO dev.Ports - 1 DO
  dev.HubPortDevices[i] := NIL;
  res := OpPowerPort(dev, i);
 END;

 ConnectHub(dev);

 RETURN TRUE;
END HubDriverProbe;

PROCEDURE OpGetPortStatus(hub : UsbDevice; port : INTEGER) : SET;
VAR
 res, status : SET;
 Message : ARRAY 8 OF CHAR;
 Buffer : ARRAY 4 OF CHAR;
BEGIN

 IF ~ hub.HubFlag THEN HALT(303); END;

 IF port > hub.Ports THEN HALT(303); END;

 IF hub.Parent = hub THEN
  status := hub.Controller.OpGetPortStatus(hub.Controller, port);
 ELSE

  Message[0] := CHR(128+32+3);
  Message[1] := CHR(CommandGetStatus);
  Message[2] := CHR(0);
  Message[3] := CHR(0);
  Message[4] := CHR(port + 1);
  Message[5] := CHR(0);
  Message[6] := CHR(4);
  Message[7] := CHR(0);

  res := OpSendControl(ConnectReq, hub, 0+128, Message, Buffer, 0, 4, 2000);
  IF res # ResOK THEN RETURN PortStatusError; END;

  status := {};
  IF SYSTEM.VAL(SET, ORD(Buffer[0])) * {0} # {} THEN status := status + PortStatusDevicePresent; END;
  IF SYSTEM.VAL(SET, ORD(Buffer[0])) * {1} # {} THEN status := status + PortStatusEnabled; END;
  IF SYSTEM.VAL(SET, ORD(Buffer[0])) * {4} # {} THEN status := status + PortStatusReset; END;  
  IF SYSTEM.VAL(SET, ORD(Buffer[1])) * {1} # {} THEN status := status + PortStatusLowSpeed; END;

 END;

 RETURN status;

END OpGetPortStatus;

PROCEDURE OpPowerPort(hub : UsbDevice; port : INTEGER) : BOOLEAN;
VAR
 res : SET;
 Message : ARRAY 8 OF CHAR;
BEGIN

 IF ~ hub.HubFlag THEN HALT(303); END; 

 IF hub.Parent = hub THEN
  (*  hub.Controller.OpPowerPort(hub.Controller, port); *)
  RETURN TRUE;
 ELSE

  Message[0] := CHR(32+3);
  Message[1] := CHR(CommandSetFeature);
  Message[2] := CHR(8); (* Power port *)
  Message[3] := CHR(0);
  Message[4] := CHR(port + 1);
  Message[5] := CHR(0);
  Message[6] := CHR(0);
  Message[7] := CHR(0);

  res := OpSendControl(ConnectReq, hub, 0, Message, Message, 0, 0, 2000);

  IF (res = ResOK) THEN MilliWait(hub.HubTime2Good); END;

  RETURN res = ResOK;

 END;

END OpPowerPort;

PROCEDURE OpEnablePort(hub : UsbDevice; port : INTEGER):BOOLEAN;
VAR
 res : SET;
 Message : ARRAY 8 OF CHAR;
 status : SET;
BEGIN

 IF ~ hub.HubFlag THEN HALT(303); END; 

 IF hub.Parent = hub THEN
  hub.Controller.OpEnablePort(hub.Controller, port);
  RETURN TRUE;
 END;

 Message[0] := CHR(32+3);
 Message[1] := CHR(CommandSetFeature);
 Message[2] := CHR(4); (* Reset port *)
 Message[3] := CHR(0);
 Message[4] := CHR(port + 1);
 Message[5] := CHR(0);
 Message[6] := CHR(0);
 Message[7] := CHR(0);

 res := OpSendControl(ConnectReq, hub, 0, Message, Message, 0, 0, 2000);

 IF res # ResOK THEN Kernel.WriteString("Usb: could not enable hub port"); Kernel.WriteLn; RETURN FALSE; END;

 MilliWait(50);

 status := OpGetPortStatus(hub, port);

 IF (status * PortStatusError) # {} THEN
  Kernel.WriteString("Usb: Fatal cannot get port status after enabling."); Kernel.WriteLn;
 ELSIF (status * PortStatusReset) # {} THEN
  MilliWait(50);
  Kernel.WriteString("Usb: Port still in reset (after 50ms!)"); Kernel.WriteLn;
 ELSIF (status * PortStatusEnabled) = {} THEN
  Kernel.WriteString("Usb: Could not enable hub port"); Kernel.WriteLn;
  RETURN FALSE;
 END;

 RETURN TRUE;

END OpEnablePort;

PROCEDURE OpDisablePort(hub : UsbDevice; port : INTEGER):BOOLEAN;
VAR
 res : SET;
 Message : ARRAY 8 OF CHAR;
BEGIN

 IF ~ hub.HubFlag THEN HALT(303); END; 

 IF hub.Parent = hub THEN

  hub.Controller.OpDisablePort(hub.Controller, port);
  RETURN TRUE;

 ELSE

  Message[0] := CHR(32+3);
  Message[1] := CHR(CommandClearFeature);
  Message[2] := CHR(1); (* Clear Enable port *)
  Message[3] := CHR(0);
  Message[4] := CHR(port + 1);
  Message[5] := CHR(0);
  Message[6] := CHR(0);
  Message[7] := CHR(0);

  res := OpSendControl(ConnectReq, hub, 0, Message, Message, 0, 0, 2000);

  RETURN res = ResOK;

 END;

END OpDisablePort;


(* ========================================================================= *)
(*             The topology has changed - look for new devices/hangup not connected ports         *)
(* ========================================================================= *)

PROCEDURE ConnectHub(hub : UsbDevice);
VAR
 j, i : INTEGER;
 dev : UsbDevice;
 status : SET;
 res : BOOLEAN;
BEGIN

 IF ~hub.HubFlag THEN HALT(303); END;

 FOR j:=0 TO hub.Ports - 1 DO
  
  status := OpGetPortStatus(hub, j);

  IF (status * PortStatusError) # {} THEN

   Kernel.WriteString("Usb: FATAL could not get port status."); Kernel.WriteLn;

   IF hub.HubPortDevices[j] # NIL THEN
    RemoveDevice(hub.HubPortDevices[j]);
    hub.HubPortDevices[j] := NIL;
   END;

  ELSIF (status * PortStatusReset) # {} THEN

   Kernel.WriteString("Usb: cannot connect port, port is in reset."); Kernel.WriteLn;

  ELSIF (status * PortStatusEnabled) = {} THEN

   IF hub.HubPortDevices[j] # NIL THEN
    RemoveDevice(hub.HubPortDevices[j]);
    hub.HubPortDevices[j] := NIL;
   END;
 
   IF (status * PortStatusDevicePresent) # {} THEN
    IF hub.HubPortPermanentDisabled[ j ] = FALSE THEN
     IF OpEnablePort(hub, j) THEN
      i := 4; LOOP
       dev := FindNewDevice(hub, j);
       IF dev # NIL THEN EXIT; END;
       Kernel.WriteString("Usb: Retrying to connect device."); Kernel.WriteLn;
       DEC(i); IF i = 0 THEN EXIT END;
       res := OpDisablePort(hub, j);
       res := OpEnablePort(hub, j);
      END;
      IF dev = NIL THEN
       Kernel.WriteString("Usb: FATAL, disabling port. Replug connector of device!"); Kernel.WriteLn;
       res := OpDisablePort(hub, j);
       IF ~res THEN Kernel.WriteString("Usb: Port disabling failed."); Kernel.WriteLn; END;
       hub.HubPortPermanentDisabled[ j ] := TRUE;
      ELSE
       (* new device detected *)
       dev.Port := j;
       RegisterDevice(hub, j, dev);
       IF HubDriverProbe(dev) = FALSE THEN ProbeDrivers(); END;
      END;
     ELSE
      Kernel.WriteString("Usb: Could not enable port."); Kernel.WriteLn;
      hub.HubPortPermanentDisabled[ j ] := TRUE;
     END;
    END;
   ELSE
    hub.HubPortPermanentDisabled[ j ] := FALSE; (* reset disabled status, as soon as user disconnects it *)
   END;

  ELSE

   dev := hub.HubPortDevices[j];
   IF dev = NIL THEN
    Kernel.WriteString("Usb: Port was enabled, but usb software did not knew it!"); Kernel.WriteLn;
   ELSIF dev.HubFlag THEN
    ConnectHub(dev);
   END;

  END;

 END;

END ConnectHub;

(** ========================================================================= **)
(**               Call Usb.Connect if you want to start the tree scan manually                                     **)
(**               (e.g. call it from an Oberon.Taks periodically)                                                            **)
(** ========================================================================= **)

PROCEDURE Connect*;
VAR
 con : UsbController;
BEGIN
 con := UsbControllerList;
 WHILE con # NIL DO
  ConnectHub(con.RootHub);
  con := con.next;
 END;
END Connect;

(* ========================================================================= *)
(*                       Topology handling stuff                                                                                        *)
(* ========================================================================= *)

PROCEDURE RegisterDevice(parentdev: UsbDevice; port : INTEGER; dev : UsbDevice);
BEGIN

 IF ~parentdev.HubFlag THEN HALT(303); END;

 dev.Parent := parentdev;
 parentdev.HubPortDevices[port] := dev;

END RegisterDevice;

PROCEDURE RemoveDevice(dev: UsbDevice);
VAR
 n : INTEGER;
 res : BOOLEAN;
BEGIN

 IF dev.HubFlag THEN
  FOR n:=0 TO dev.Ports - 1 DO
   IF dev.HubPortDevices[n] # NIL THEN
    RemoveDevice(dev.HubPortDevices[n]);
    IF dev.Parent = dev THEN res := OpDisablePort(dev, n); END; (* only disable ports on root hubs *)
    dev.HubPortDevices[n] := NIL;
   END;
  END;
  IF dev # dev.Parent THEN FreeAddress(dev.Controller, dev.Address); END;
 ELSE
  FOR n:=0 TO dev.ActConfiguration.bNumInterfaces - 1 DO
   IF dev.ActConfiguration.Interfaces[n].Driver # NIL THEN
    dev.ActConfiguration.Interfaces[n].Driver.OpDisconnect(dev);
   END;
  END;
 END;

 FreeAddress(dev.Controller, dev.Address);
 
END RemoveDevice;

PROCEDURE FindFreeAddress(con : UsbController) : INTEGER;
VAR
 i : INTEGER;
BEGIN
 FOR i:= 1 TO 127 DO
  IF con.AdrRange[ i ] = FALSE THEN
   con.AdrRange[ i ] := TRUE;
   RETURN i;
  END;
 END;
 RETURN 0;
END FindFreeAddress;

PROCEDURE FreeAddress(con : UsbController; adr : INTEGER);
BEGIN
 con.AdrRange[ adr ] := FALSE;
END FreeAddress;

PROCEDURE SetAddress(dev : UsbDevice; adr : INTEGER) : BOOLEAN;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN

 Message[0] := CHR(0); (* Host to Device *)
 Message[1] := CHR(CommandSetAddress); (* Set Address *)
 Message[2] := CHR(adr); (* Address *)
 Message[3] := CHR(0);
 Message[4] := CHR(0);
 Message[5] := CHR(0);
 Message[6] := CHR(0);
 Message[7] := CHR(0);

 res := OpSendControl(ConnectReq, dev, 0, Message, Message, 0, 0, 1000);

 IF res = ResOK THEN dev.Address := adr; END;
 
 RETURN res = ResOK;

END SetAddress;

PROCEDURE SetConfiguration(dev : UsbDevice; conf : INTEGER) : BOOLEAN;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET; i,e, eadr : INTEGER;
BEGIN

 Message[0] := CHR(0); (* Host to Device *)
 Message[1] := CHR(CommandSetConfiguration);
 Message[2] := CHR(dev.Configurations[conf].bConfigurationValue);
 Message[3] := CHR(0);
 Message[4] := CHR(0);
 Message[5] := CHR(0);
 Message[6] := CHR(0);
 Message[7] := CHR(0);

 res := OpSendControl(ConnectReq, dev, 0, Message, Message, 0, 0, 500);

 IF res = ResOK THEN
  dev.ActConfiguration := dev.Configurations[conf];

  dev.MaxPacketSizeOut[0] := dev.Descriptor.bMaxPacketSize0;
  dev.MaxPacketSizeIn[0] := dev.Descriptor.bMaxPacketSize0;

  FOR i := 0 TO dev.ActConfiguration.bNumInterfaces - 1 DO
   FOR e:= 0 TO dev.ActConfiguration.Interfaces[i].bNumEndpoints - 1 DO
    eadr := dev.ActConfiguration.Interfaces[i].Endpoints[e].bEndpointAddress;
    IF SYSTEM.VAL(SET, eadr) * {7} = {} THEN
     dev.MaxPacketSizeOut[eadr MOD 16] := dev.ActConfiguration.Interfaces[i].Endpoints[e].wMaxPacketSize;
    ELSE
     dev.MaxPacketSizeIn[eadr MOD 16] := dev.ActConfiguration.Interfaces[i].Endpoints[e].wMaxPacketSize;
    END;
   END;
  END;
 END;
 
 RETURN res = ResOK;
 
END SetConfiguration;

PROCEDURE GetDescriptor(dev : UsbDevice; typ, descriptor, index, len : INTEGER; VAR buf : ARRAY OF CHAR) : BOOLEAN;
VAR
 Message : ARRAY 8 OF CHAR;
 res : SET;
BEGIN

 Message[0] := CHR(typ); (* Device to host*)
 Message[1] := CHR(CommandGetDescriptor);
 Message[2] := CHR(index); (* Index in low byte *)
 Message[3] := CHR(descriptor); (* Descriptor type in high byte *)
 Message[4] := CHR(0); (* Language ID *)
 Message[5] := CHR(0);
 Message[6] := CHR(len); (* Len *)
 Message[7] := CHR(SYSTEM.LSH(len, -8));

 res := OpSendControl(ConnectReq, dev, 128, Message, buf, 0, len, 1000);

 IF (res = ResOK) & (ORD(buf[1]) # descriptor) THEN res := ResInternal; END; (* EPROTO waere besser... *)

 RETURN res = ResOK;

END GetDescriptor;

PROCEDURE ParseInterfaces(devconf : UsbDeviceConfiguration; VAR buffer : ARRAY OF CHAR; VAR idx : INTEGER) : BOOLEAN;
VAR
 n, e : INTEGER;
BEGIN

 NEW(devconf.Interfaces, devconf.bNumInterfaces); (* always > 0 *)

 FOR n:=0 TO devconf.bNumInterfaces - 1 DO

  IF idx >= devconf.wTotalLength THEN
   Kernel.WriteString("Usb: ParseInterfaces: Out of interface data."); Kernel.WriteLn;
   RETURN FALSE;
  END;

  (* Search the alternate interface 0 *)

  WHILE (ORD(buffer[idx + 1]) # DescriptorInterface) OR (ORD(buffer[idx + 3]) # 0) DO
   idx := idx + ORD(buffer[idx]);
   IF idx >= devconf.wTotalLength THEN
    Kernel.WriteString("Usb: ParseInterfaces: Interface not found."); Kernel.WriteLn;
    RETURN FALSE;
   END;
  END;

  IF ORD(buffer[idx + 3]) # 0 THEN
   Kernel.WriteString("Usb: ParseInterfaces: Alternate Interface 0 not found."); Kernel.WriteLn;
   RETURN FALSE;
  END;

  NEW(devconf.Interfaces[n]);

  devconf.Interfaces[n].bInterfaceNumber := ORD(buffer[idx + 2]);
  devconf.Interfaces[n].bAlternateSetting := ORD(buffer[idx + 3]);
  devconf.Interfaces[n].bNumEndpoints := ORD(buffer[idx + 4]);
  devconf.Interfaces[n].bInterfaceClass := ORD(buffer[idx + 5]);
  devconf.Interfaces[n].bInterfaceSubClass := ORD(buffer[idx + 6]);
  devconf.Interfaces[n].bInterfaceProtocol := ORD(buffer[idx + 7]);
  devconf.Interfaces[n].iInterface := ORD(buffer[idx + 8]);

  idx := idx + ORD(buffer[idx]);

  (* Collect endpoints for interface 0 *)

  IF devconf.Interfaces[n].bNumEndpoints > 0 THEN
   NEW(devconf.Interfaces[n].Endpoints, devconf.Interfaces[n].bNumEndpoints);
  END;
   
  FOR e := 0 TO devconf.Interfaces[n].bNumEndpoints - 1 DO
    
   IF idx >= devconf.wTotalLength THEN
    Kernel.WriteString("Usb: ParseInterfaces: Not enough endpoint data."); Kernel.WriteLn;
    RETURN FALSE;
   END;

   WHILE ORD(buffer[idx + 1]) # DescriptorEndpoint DO
    idx := idx + ORD(buffer[idx]);
    IF idx >= devconf.wTotalLength THEN
     Kernel.WriteString("Usb: ParseInterfaces: Endpoint not found."); Kernel.WriteLn;
     RETURN FALSE;
    END;
   END;

   NEW(devconf.Interfaces[n].Endpoints[e]);
    
   devconf.Interfaces[n].Endpoints[e].bEndpointAddress := ORD(buffer[idx + 2]);
   devconf.Interfaces[n].Endpoints[e].bmAttributes := SYSTEM.VAL(SET, ORD(buffer[idx + 3]));
   devconf.Interfaces[n].Endpoints[e].wMaxPacketSize := ORD(buffer[idx + 5])*256 + ORD(buffer[idx + 4]);
   devconf.Interfaces[n].Endpoints[e].bInterval := ORD(buffer[idx + 6]);

   idx := idx + ORD(buffer[idx]);

  END;   

 END;

 RETURN TRUE;

END ParseInterfaces;

PROCEDURE ParseConfigurations(dev : UsbDevice) : BOOLEAN;
VAR
 c : INTEGER;
 buffer : ARRAY 2048 OF CHAR;
 idx : INTEGER;
 res : BOOLEAN;
BEGIN

 NEW(dev.Configurations, dev.Descriptor.bNumConfigurations); (* always > 0 *)

 FOR c :=0 TO dev.Descriptor.bNumConfigurations - 1 DO

  NEW(dev.Configurations[c]);

  (* Message um erste 8 byte der c-ten Konfiguration lesen *)

  res := GetDescriptor(dev, 128, DescriptorConfiguration, c, 8, buffer);

  IF res # TRUE THEN
   Kernel.WriteString("Usb: Read first 8 bytes of configuration failed"); Kernel.WriteLn;
   RETURN FALSE;
  END;

  IF ORD(buffer[2])+ 256*ORD(buffer[3]) > 2048 THEN
   Kernel.WriteString("Usb: Configuration too big to fit in buffer!"); Kernel.WriteLn;
   RETURN FALSE;
  END;

  res := GetDescriptor(dev, 128, DescriptorConfiguration, c, ORD(buffer[2])+ 256*ORD(buffer[3]), buffer);

  IF res # TRUE THEN
   Kernel.WriteString("Usb: Get configuration failed."); Kernel.WriteLn;
   RETURN FALSE;
  END;

  dev.Configurations[c].wTotalLength := ORD(buffer[2])+ 256*ORD(buffer[3]);
  dev.Configurations[c].bNumInterfaces := ORD(buffer[4]);
  dev.Configurations[c].bConfigurationValue := ORD(buffer[5]);
  dev.Configurations[c].iConfiguration := ORD(buffer[6]);
  dev.Configurations[c].bmAttributes := SYSTEM.VAL(SET, ORD(buffer[7]));
  dev.Configurations[c].MaxPower := ORD(buffer[8]);

  idx := ORD (buffer[0]); (* idx points to first interface *)

  res := ParseInterfaces(dev.Configurations[c], buffer, idx);

  IF res # TRUE THEN
   Kernel.WriteString("Usb: ParseInterfaces failed."); Kernel.WriteLn;
   RETURN FALSE;
  END;

 END;   

 RETURN TRUE;

END ParseConfigurations;

PROCEDURE ParseDescriptors(dev : UsbDevice) : BOOLEAN;
VAR
 buffer : ARRAY 2048 OF CHAR;
 res : BOOLEAN;
BEGIN

 (* Message um Device-descriptor von Device zu lesen *)

 res := GetDescriptor(dev, 128, DescriptorDevice, 0, 8, buffer);
 
 (* we are only allowed to read 8 bytes until now - otherwise there could happen a babble error *)

 IF res # TRUE THEN
  Kernel.WriteString("Usb: Read first 8 bytes of descriptor failed."); Kernel.WriteLn;
  RETURN FALSE;
 END;

 dev.Descriptor.bMaxPacketSize0 := ORD(buffer[7]);

 res := GetDescriptor(dev, 128, DescriptorDevice, 0, 18, buffer); 

 IF res # TRUE THEN
  Kernel.WriteString("Usb: Get descriptor failed."); Kernel.WriteLn;
  RETURN FALSE;
 END;

 dev.Descriptor.bcdUSB := ORD(buffer[3])*256 + ORD(buffer[2]);
 dev.Descriptor.bDeviceClass := ORD(buffer[4]);
 dev.Descriptor.bDeviceSubClass := ORD(buffer[5]);
 dev.Descriptor.bDeviceProtocol := ORD(buffer[6]);
 dev.Descriptor.bMaxPacketSize0 := ORD(buffer[7]);
 dev.Descriptor.idVendor := ORD(buffer[9])*256 + ORD(buffer[8]);
 dev.Descriptor.idProduct := ORD(buffer[11])*256 + ORD(buffer[10]);
 dev.Descriptor.bcdDevice := ORD(buffer[13])*256 + ORD(buffer[12]);
 dev.Descriptor.iManufacturer := ORD(buffer[14]);
 dev.Descriptor.iProduct := ORD(buffer[15]);
 dev.Descriptor.iSerialNumber := ORD(buffer[16]);
 dev.Descriptor.bNumConfigurations := ORD(buffer[17]);

 res := ParseConfigurations(dev);

 RETURN res;

END ParseDescriptors;

PROCEDURE FindNewDevice(hub : UsbDevice; port : INTEGER): UsbDevice;
VAR
 res : BOOLEAN;
 adr : INTEGER;
 dev : UsbDevice;
 status : SET;
BEGIN

 IF ~hub.HubFlag THEN HALT(303); END;

 adr := FindFreeAddress(hub.Controller);
 
 IF adr = 0 THEN RETURN NIL; END; (* Sorry, bus is full *)

 NEW(dev);

 dev.Controller := hub.Controller;
 dev.Address := 0; (* default address *)
 dev.LowSpeed := FALSE;
 dev.HighSpeed := FALSE;

 status := OpGetPortStatus(hub, port);

 IF (status * PortStatusError) # {} THEN 
  Kernel.WriteString("Usb: Cannot get port status"); Kernel.WriteLn;
  RETURN NIL;
 END;

 IF (status * PortStatusLowSpeed) # {} THEN
  dev.LowSpeed := TRUE;
 ELSIF (status * PortStatusHighSpeed) # {} THEN
  dev.HighSpeed := TRUE;
 END;

 NEW(dev.Descriptor);

 dev.Descriptor.bMaxPacketSize0 := 8; (* temp., until we have read the descriptor *)

 (* SetAddr adr *)

 res := SetAddress(dev, adr);

 IF res # TRUE THEN
  FreeAddress(hub.Controller, adr);
  Kernel.WriteString("Usb: Address Setup failed."); Kernel.WriteLn;
  RETURN NIL;
 END;

 MilliWait(20); (* let the address settle *)

 res := ParseDescriptors(dev);

 IF res # TRUE THEN
  FreeAddress(hub.Controller, adr);
  Kernel.WriteString("Usb: Parsing failed."); Kernel.WriteLn;
  RETURN NIL;
 END;

 (* Set Configuration *)

 res := SetConfiguration(dev, 0);

 IF res # TRUE THEN
  FreeAddress(hub.Controller, adr);
  Kernel.WriteString("Usb: Cannot set configuration"); Kernel.WriteLn;
  RETURN NIL;
 END;

 RETURN dev;

END FindNewDevice;

PROCEDURE ProbeDeviceChain(dev : UsbDevice);
VAR
 n : INTEGER;
 drv : UsbDriver;
BEGIN

 IF dev.HubFlag THEN
  FOR n:=0 TO dev.Ports - 1 DO
   IF dev.HubPortDevices[n] # NIL THEN
    ProbeDeviceChain(dev.HubPortDevices[n]);
   END;
  END;
 ELSE
  FOR n:=0 TO dev.ActConfiguration.bNumInterfaces - 1 DO
   IF dev.ActConfiguration.Interfaces[n].Driver = NIL THEN
    drv := UsbDriverList;
    WHILE (drv # NIL) & (dev.ActConfiguration.Interfaces[n].Driver = NIL ) DO
     drv.OpProbe(dev, n);
     drv := drv.next;
    END;
   END;
  END;
 END;

END ProbeDeviceChain;

PROCEDURE ProbeDrivers();
VAR
 con : UsbController;
BEGIN

 con := UsbControllerList;
 WHILE con # NIL DO
  ProbeDeviceChain(con.RootHub);
  con := con.next;
 END;

END ProbeDrivers;

PROCEDURE InfoChain(hub : UsbDevice; spacer : INTEGER);
VAR
 j, n : INTEGER;
 dev : UsbDevice;
 drv : UsbDriver;
 sp : INTEGER;
BEGIN

 IF ~hub.HubFlag THEN HALT(303); END;

 FOR sp := 0 TO spacer - 1 DO Kernel.WriteChar(" "); END;

 IF hub.Parent = hub THEN
  Kernel.WriteString("Host Controller root-hub");
 ELSE
  Kernel.WriteString("Hub at port "); Kernel.WriteInt(hub.Port, 0);
 END;

 Kernel.WriteString(" with "); Kernel.WriteInt(hub.Ports, 0); Kernel.WriteString(" ports."); Kernel.WriteLn;
 
 FOR j:=0 TO hub.Ports - 1 DO
  dev := hub.HubPortDevices[j];
  IF dev # NIL THEN
   IF dev. HubFlag THEN
    InfoChain(dev, spacer + 2);
   ELSE
    FOR sp := 0 TO spacer+2 DO Kernel.WriteChar(" "); END;
    Kernel.WriteString("Device at port "); Kernel.WriteInt(dev.Port, 0);
    Kernel.WriteString(" Address: "); Kernel.WriteInt(dev.Address, 0);
    IF dev.LowSpeed THEN
     Kernel.WriteString(" [lowspeed]");
    ELSIF dev.HighSpeed THEN
     Kernel.WriteString(" [highspeed]");
    ELSE
     Kernel.WriteString(" [fullspeed]");
    END;
    
    Kernel.WriteString (" MaxPower: "); Kernel.WriteInt(dev.ActConfiguration.MaxPower,0); Kernel.WriteString("mA");
    Kernel.WriteLn; FOR sp := 0 TO spacer+2 DO Kernel.WriteChar(" "); END;

    Kernel.WriteString("Vendor: "); PrintHex(dev.Descriptor.idVendor MOD 10000H); (* printhex wants a longint *)
    Kernel.WriteString("H Product: "); PrintHex(dev.Descriptor.idProduct MOD 10000H); (* we must be sure that *)
    Kernel.WriteString("H Bcd: "); PrintHex(dev.Descriptor.bcdDevice MOD 10000H); (* that our integer doesnt get *)
    Kernel.WriteString(" Class: "); PrintHex(dev.Descriptor.bDeviceClass MOD 10000H); (* sign extended *)
    Kernel.WriteString("H SubClass: "); PrintHex(dev.Descriptor.bDeviceSubClass MOD 10000H); Kernel.WriteChar("H");

    FOR n:=0 TO dev.ActConfiguration.bNumInterfaces - 1 DO
     Kernel.WriteLn; FOR sp := 0 TO spacer+4 DO Kernel.WriteChar(" "); END;
     Kernel.WriteString("Interface: [Class: "); PrintHex(dev.ActConfiguration.Interfaces[n].bInterfaceClass);
     Kernel.WriteString("H Subclass: "); PrintHex(dev.ActConfiguration.Interfaces[n].bInterfaceSubClass);
     Kernel.WriteString("H Protocol: "); PrintHex(dev.ActConfiguration.Interfaces[n].bInterfaceProtocol);
     Kernel.WriteString("H #Endpoints: "); Kernel.WriteInt(dev.ActConfiguration.Interfaces[n].bNumEndpoints, 0);
     Kernel.WriteString("]"); Kernel.WriteLn;
     FOR sp := 0 TO spacer+4 DO Kernel.WriteChar(" "); END;
     drv := dev.ActConfiguration.Interfaces[n].Driver;
     IF drv # NIL THEN
      Kernel.WriteString("["); Kernel.WriteString(drv.DriverName); Kernel.WriteString ("]");
     ELSE Kernel.WriteString("[no driver found for this interface]");
     END;
    END;
   END;
  END;
 END;
 
END InfoChain;

(** ========================================================================= **)
(**            Prints information about current usb tree into kernel.log. (Handy for debugging)        **)
(** ========================================================================= **)

PROCEDURE Info*();
VAR
 con : UsbController;
 dev : UsbDevice;
BEGIN
 Kernel.WriteString("Usb tree:"); Kernel.WriteLn;
 con := UsbControllerList;
 WHILE con # NIL DO
  dev := con.RootHub;
  IF dev # NIL THEN InfoChain(dev, 0); END;
  con := con.next;
 END;
END Info;

BEGIN
 NEW(ConnectReq);
 UsbControllerList := NIL;
 UsbDriverList := NIL;
END Usb.
