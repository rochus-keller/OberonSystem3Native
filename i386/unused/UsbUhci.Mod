(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

(*
Native Oberon Intel UHCI support

Reference: http://www.intel.com

30.09.2000 cp first release
18.10.2000 cp bugfixes, added new debug support
20.10.2000 cp memory fragmentation fixed
22.10.2000 cp TD allocation changed, IRQ spread fixed, irq-out bugfix
*)

(* Future improvment: PROCEDURES marked with "**** MUTEX ****" must use a monitor in AOS *)

MODULE UsbUhci;  (** non-portable **)  (** cp **)

IMPORT Usb, SYSTEM, Kernel, PCI;

CONST

 DEBUG = FALSE;

 MaxControllers = 4;
 MaxTDPerController = 100000; (* 1 TD is 16 Byte of RAM - we need 24576 TD's for 12Mbit/s *)
 MaxGCEntries = 3;

 (* Offset of USB Registers from base io-address *)
 
 USBCMD = 0H;
 USBSTS = 2H;
 USBINTR = 4H;
 FRNUM = 6H;
 FLBASEADD = 8H;
 SOFMOD = 0CH;
 PORTSC1 = 10H;
 PORTSC2 = 12H;

 (* Bits of the USB Command (USBCMD) Register *)
 
 CommandMaxPacket = { 7 };
 CommandCF = { 6 };
 CommandSoftwareDebug = { 5 };
 CommandForceGlobalResume = { 4 };
 CommandEnterGlobalSuspend = { 3 };
 CommandGlobalReset = { 2 };
 CommandHostControllerReset = { 1 };
 CommandRunStop = { 0 };
 
 (* Bits of the USB Status (USBSTS) Register *)
 
 StatusHChalted = { 5 };
 StatusProcessError = { 4 };
 StatusSystemError = { 3 };
 StatusResumeDetect = { 2 };
 StatusErrorInt = { 1 };
 StatusInt = { 0 };

 (* Bits of the USB Interrupt Enable (USBINTR) Register *)
 
 IntShortPacket = { 3 };
 IntIOC = { 2 };
 IntResume = { 1 };
 IntTimeoutCRC = { 0 };

 (* Bits of the USB Port Status and Control (PORTSC) Register *)

 PortSuspend = { 12 };
 PortReset = { 9 };
 PortLowSpeed = { 8 };
 PortResumeDetect = { 6 };
 PortLineStatus = { 4,5 };
 Portedchange = { 3 };
 Ported = { 2 };
 Portcschange = { 1 };
 Portcs = { 0 };

 (* Bits of the TD Link Pointer DWORD*)

 TDTerminate = { 0 };
 TDQHSelect = { 1 };
 TDDepthFirst = { 2 };
      
 (* Bits of the TD Control and Status DWORD *)

 TDBitStuff = { 17 };
 TDCrcTimeout = { 18 };
 TDNak = { 19 };
 TDBabble = { 20 };
 TDDataBuffer = { 21 };
 TDStalled = { 22 };
 TDActive = { 23 };
 TDIOC = { 24 };
 TDIOS = { 25 };
 TDLS = { 26 };
 TDERR0 = {}; TDERR1 = { 27 }; TDERR2 = { 28 }; TDERR3 = { 27, 28 };
 TDSPD = { 29 };
    
 (* Bits of the TD Token DWORD *)

 TDDataToggle = { 19 };

 (* USB Stuff - not uhci specific *)
 
 PidOut = 0E1H;
 PidIn = 069H;
 PidSetup = 02DH;

TYPE

 UhciFrameList = POINTER TO RECORD
  index : LONGINT;
  framelistbase : LONGINT;
  field : ARRAY 2*1024 OF LONGINT; (* hack: double it, so that we pass a 4K page boundary *)
 END;

 UhciTDList = POINTER TO RECORD
  index : LONGINT;
  tdlistbase : LONGINT;
  field : ARRAY ((MaxTDPerController + 1) * 4) OF LONGINT; (* plus one, for the 16byte boundary alignment*)
  freelist : ARRAY MaxTDPerController OF LONGINT;
  first, last : LONGINT;
 END;

 UhciController = POINTER TO RECORD (Usb.UsbController)
  idx : INTEGER;
  iobase: LONGINT;
  irq : INTEGER;
  portCount : INTEGER;
  port : POINTER TO ARRAY OF LONGINT;
  framelist : UhciFrameList;
  tdlist : UhciTDList;
  ControlTD : LONGINT;
  BulkTD : LONGINT;
  InterruptTD : ARRAY 11 OF LONGINT;
  TReqList : Usb.UsbTReq;
  GCqueueList : ARRAY MaxGCEntries OF LONGINT;
  GCqueueTimestamp :  ARRAY MaxGCEntries OF INTEGER;
  next : UhciController;
 END;

 UhciConSpec = POINTER TO RECORD (Usb.UsbConSpecData)
   qh : LONGINT;
   queue : LONGINT;
 END;

VAR

 (* Since we have such a nice controller object, the following seems to be a hack,
  but it is necessary for the communication with the interrupt handler procedure in Native Oberon *)

 IntControllerActive : ARRAY MaxControllers OF BOOLEAN;
 IntControllerRunning : ARRAY MaxControllers OF BOOLEAN; 
 IntControllerBase : ARRAY MaxControllers OF LONGINT;
 IntControllerStatus : ARRAY MaxControllers OF SET;
 IntControllerCounter : ARRAY MaxControllers OF LONGINT;

 UsbInterrupts : SET;
 FirstController : UhciController;
 ControllerCount : INTEGER;

(* ========================================================================= *)
(*                       Some helper stuff here                                                                                         *)
(* ========================================================================= *)

PROCEDURE PrintHex(was: LONGINT);
VAR z,d,h,i:LONGINT;
BEGIN
 z := 0;
 d := 16*16*16*16*16*16*16; (* what a quick hack, hopefully the compiler is intelligent enough *)
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
(*                                                                   Upcalls                                                                      *)
(* ========================================================================= *)

(* ========================== UpcallResetController ============================ *)

PROCEDURE UpcallResetController(con: Usb.UsbController);
VAR
 ucon : UhciController;
BEGIN

 ucon := con (UhciController);
 ResetController(ucon);

END UpcallResetController;

(* ============================= UpcallEnablePort ============================ *)

PROCEDURE UpcallEnablePort(usbcon : Usb.UsbController; port : INTEGER);
VAR
 con : UhciController;
BEGIN

 con := usbcon (UhciController);
 EnablePort(con, port);

END UpcallEnablePort;

(* ============================= UpcallDisablePort ============================ *)

PROCEDURE UpcallDisablePort(usbcon : Usb.UsbController; port : INTEGER);
VAR
 con : UhciController;
BEGIN

 con := usbcon (UhciController);
 DisablePort(con, port);

END UpcallDisablePort;

(* ========================== UpcallGetPortStatus ============================= *)

PROCEDURE UpcallGetPortStatus(usbcon : Usb.UsbController; port : INTEGER):SET;
VAR
 con : UhciController;
BEGIN

 con := usbcon (UhciController);
 RETURN GetPortStatus(con, port);

END UpcallGetPortStatus;

(* =========================== UpcallGetPortCount =========================== *)

PROCEDURE UpcallGetPortCount(usbcon : Usb.UsbController):INTEGER;
VAR
 con : UhciController;
BEGIN

 con := usbcon (UhciController);
 RETURN GetPortCount(con);

END UpcallGetPortCount;

(* ============================== UpcallSendReq ============================== *)

PROCEDURE UpcallSendReq(con : Usb.UsbController; req : Usb.UsbTReq);
BEGIN

 WITH con : UhciController DO
  IF req.Typ = Usb.TransferControl THEN req.Status := PrepareControl(con, req);
  ELSIF req.Typ = Usb.TransferBulk THEN req.Status := PrepareBulk(con, req);
  ELSIF req.Typ = Usb.TransferInterrupt THEN req.Status := PrepareInterrupt(con, req);
  ELSE req.Status := Usb.ResInternal; END;
 END;

END UpcallSendReq;

(* ========================================================================= *)
(*                       Uhci interrupt handler (sort of upcall...)                                                              *)
(* ========================================================================= *)

(* ============================ UpcallInterruptHandler ========================= *)

PROCEDURE UpcallInterruptHandler;
VAR
 i : INTEGER;
 s : SET;
BEGIN

 FOR i:=0 TO (MaxControllers - 1) DO
  IF IntControllerActive[ i ] = TRUE THEN
   SYSTEM.PORTIN(IntControllerBase[ i ] + USBSTS, SYSTEM.VAL(INTEGER, s));
   IF s # {} THEN
    IntControllerStatus[ i ] := s;
    IF (s * StatusHChalted) # {} THEN IntControllerRunning[ i ] := FALSE; END;
    SYSTEM.PORTOUT(IntControllerBase[ i ] + USBSTS, SYSTEM.VAL(INTEGER, s));
    INC (IntControllerCounter[ i ]);
   END;
  END;
 END;

END UpcallInterruptHandler;

(* ========================================================================= *)
(*                      Low level Uhci port stuff                                                                                       *)
(* ========================================================================= *)

(* ============================== ResetController ============================= *)

PROCEDURE ResetController(con: UhciController);
BEGIN

 (* do a global reset for 50ms, disconnect all devices *)

 SYSTEM.PORTOUT(con.iobase + USBCMD, SYSTEM.VAL(INTEGER, 4) );
 MilliWait ( 50 );
 SYSTEM.PORTOUT(con.iobase + USBCMD, SYSTEM.VAL(INTEGER, 0) ); 
 MilliWait ( 10 );

END ResetController;

(* ============================= StartController =============================== *)

PROCEDURE StartController(con: UhciController):BOOLEAN;
VAR
 t : LONGINT;
 s : SET;
BEGIN

 (* start a hc-reset phase, the controller signals the end of the reset*)

 SYSTEM.PORTOUT(con.iobase + USBCMD, SYSTEM.VAL(INTEGER, 2) );

 t := 10000;

 REPEAT
  SYSTEM.PORTIN(con.iobase + USBCMD, SYSTEM.VAL(INTEGER, s) );
  DEC( t );
 UNTIL ((t = 0) OR (  ~ ( 1 IN s)));

 (* if we are in luck at try #10000, stop anyway; my computer (dual-celeron 540Mhz, bus 72Mhz) is ready at try #1 *)

 IF t = 0 THEN RETURN FALSE END;

 (* enable all interrupts, but remember: perhaps they are not being routed by the PIIX4 *)

 SYSTEM.PORTOUT(con.iobase + USBINTR, SYSTEM.VAL(INTEGER, IntShortPacket + IntIOC + IntResume + IntTimeoutCRC) );

 (* we start at frame 0 and also set the framelistbase address *)

 SYSTEM.PORTOUT(con.iobase + FRNUM, SYSTEM.VAL(INTEGER, 0) ); (* 16 bit! *)
 SYSTEM.PORTOUT(con.iobase + FLBASEADD, SYSTEM.VAL(LONGINT, con.framelist.framelistbase));

 (* start the controller, set max-packet size (64byte) and set the pseudo-semaphore which we don't need *)

 IntControllerRunning[con.idx] := TRUE;

 SYSTEM.PORTOUT(con.iobase + USBCMD, SYSTEM.VAL(INTEGER, CommandRunStop + CommandCF + CommandMaxPacket) );

 RETURN TRUE;

END StartController;

(* =========================== GetFrame =============================== *)

PROCEDURE GetFrame(con : UhciController) : INTEGER;
VAR
 frame : INTEGER;
BEGIN

 SYSTEM.PORTIN(con.iobase + FRNUM, frame);
 frame := SHORT(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, frame) * {0..10}));
 RETURN frame;

END GetFrame;

(* ========================= EnablePort ================================ *)

PROCEDURE EnablePort(con : UhciController; port : INTEGER);
BEGIN

 SYSTEM.PORTOUT(con.port[port], SYSTEM.VAL(INTEGER, 0200H));
 MilliWait ( 10 );
 SYSTEM.PORTOUT(con.port[port], SYSTEM.VAL(INTEGER, 0));
 MilliWait ( 1 ); (* HMMMMMMMMMM MASSIVE HACK *)
 SYSTEM.PORTOUT(con.port[port], SYSTEM.VAL(INTEGER, 4));
 MilliWait ( 50 );

END EnablePort;

(* ============================= DisablePort ============================ *)

PROCEDURE DisablePort(con : UhciController; port : INTEGER);
BEGIN

 SYSTEM.PORTOUT(con.port[port], SYSTEM.VAL(INTEGER, 0));

END DisablePort;

(* =========================== GetPortStatus ============================ *)

PROCEDURE GetPortStatus(con : UhciController; port : INTEGER):SET;
VAR
 status, t : SET;
BEGIN

 SYSTEM.PORTIN(con.port[port], SYSTEM.VAL(INTEGER, t));
 status := {};
 IF (t * Portcs) # {} THEN status := status + Usb.PortStatusDevicePresent END;
 IF (t * Ported) # {} THEN status := status + Usb.PortStatusEnabled END;
 IF (t * PortLowSpeed) # {} THEN status := status + Usb.PortStatusLowSpeed END;
 
 IF (t * (Portedchange + Portcschange)) # {} THEN
  SYSTEM.PORTOUT(con.port[port], SHORT(SYSTEM.VAL(LONGINT, t * (Ported + Portedchange + Portcschange))));
 END;
 RETURN status;

END GetPortStatus;

(* =============================== GetPortCount ============================= *)

PROCEDURE GetPortCount(con : UhciController):INTEGER;
BEGIN

 RETURN con.portCount;

END GetPortCount;

(* ========================================================================= *)
(*                       Uhci TD Format                                                                                                    *)
(* ========================================================================= *)

(*  Offset:             Value:                                                                                                                *)
(*   00   Link Pointer                                                                                                                      *)
(*   04   Flags - Status - Actlen                                                                                                     *)
(*   08   MaxLen - D Toggle - EndPt - Device Address - PID                                                       *)
(*   12   Buffer Pointer                                                                                                                   *)

(* ========================================================================= *)
(*                       Uhci QH Format                                                                                                   *)
(* ========================================================================= *)

(*  Offset:             Value:                                                                                                                *)
(*   00   Queue Head Link Pointer                                                                                                 *)
(*   04   Queue Element Link Pointer                                                                                            *)
(*   08   [Oberon specific]  Original Queue Element Link Pointer  (= first TD in queue)              *)
(*   12   [Oberon specific]  Pointer to last TD in queue                                                                 *)

(* ========================================================================= *)
(*                       TD (De-)Allocation Routines                                                                               *)
(* ========================================================================= *)

(* =============================== AllocTD =================================== *)

PROCEDURE AllocTD(con : UhciController):LONGINT;
VAR
 retval : LONGINT;
 timenow, i : INTEGER;
 needwait, entryfound : BOOLEAN;
BEGIN

 (* see if the list is empty (we keep always one element in the queue) *)

 IF (con.tdlist.first = con.tdlist.last) THEN

  (* ups, no more td's, let's see if there are perhaps some in the GC queue *)

  timenow := GetFrame(con); needwait := FALSE; entryfound := FALSE;

  FOR i:= 0 TO MaxGCEntries - 1 DO
   IF con.GCqueueList[i] # 1 THEN (* ok, entry found *)
    IF (timenow # con.GCqueueTimestamp[i]) THEN (* good, entry can be free'd NOW *)
     FreeDeadQHChain(con, con.GCqueueList[i]);
     con.GCqueueList[i] := 1;
     needwait := FALSE; entryfound := TRUE;
    ELSE
     IF entryfound = FALSE THEN needwait := TRUE; END; (* only wait for this entry if there is no other *)
    END;
   END;
  END;

  IF needwait THEN
   WHILE (GetFrame(con) = timenow) DO (* nothing *) END;
   (* we can do the following, since in Native Oberon there wont be any new entries,
   there is no concurrency *)   
   FOR i:= 0 TO MaxGCEntries - 1 DO
    IF con.GCqueueList[i] # 1 THEN FreeDeadQHChain(con, con.GCqueueList[i]); con.GCqueueList[i] := 1; END;
   END;
  END;

  (* still no free TD's ?? *)
  IF (con.tdlist.first = con.tdlist.last) THEN
   Kernel.WriteString("UsbUhci: No more free TD's. Please increase the TD count in UsbUhci.Mod"); Kernel.WriteLn;
   RETURN -1; (* alternatively we could use '1' since this is not valid too (alignment) *)
  END;
 END;

 retval := con.tdlist.freelist[ con.tdlist.first];

 con.tdlist.first := (con.tdlist.first + 1) MOD MaxTDPerController;

 RETURN retval;

END AllocTD;

(* =============================== FreeTD =================================== *)

PROCEDURE FreeTD(con: UhciController; tdaddr : LONGINT);
BEGIN

 con.tdlist.last := (con.tdlist.last + 1) MOD MaxTDPerController;
 
 IF con.tdlist.first = con.tdlist.last THEN
  HALT(303); (* something is REALLY going wrong, freeing something but nothing allocated?? *)
 END;

 IF (SYSTEM.VAL(SET, tdaddr) * {0..3}) # {} THEN
  HALT(303); (* nice try *)
 END;

 IF (tdaddr < con.tdlist.tdlistbase) OR (tdaddr > (con.tdlist.tdlistbase + MaxTDPerController*16)) THEN
  HALT(303); (* again, we cannot accept this *)
 END;

 con.tdlist.freelist[ con.tdlist.last ] := tdaddr;

END FreeTD;

(* =========================== FreeDeadQhChain ============================== *)

(* The dead version is very fast, since it knows that the UHCI does not access this queue (=> dead) *)

PROCEDURE FreeDeadQHChain(con : UhciController; addr : LONGINT);
VAR
 nexttd : LONGINT;
BEGIN

 (* Get link element pointer from qh *)

 SYSTEM.GET(addr + 8, SYSTEM.VAL(LONGINT, nexttd)); (* nexttd := link pointer *)

 FreeTD(con, addr);

 (* Free all the TDs in the chain *)

 LOOP
  IF (SYSTEM.VAL(SET, nexttd) * {0}) # {} THEN EXIT; END; (* nexttd is not valid, break *)
  addr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, nexttd) * {4..31}); (* addr := physical addr of nexttd *)
  SYSTEM.GET(addr, SYSTEM.VAL(LONGINT, nexttd)); (* nexttd := link pointer of td at addr *)
  FreeTD(con, addr);
 END;

END FreeDeadQHChain;

(* =========================== FreeLiveQhChain ============================== *)

(*
Live meaning: The UHCI does perhaps still access this queue, so we must be careful
when we free some element of the queue.
We do this by using a waitqueue.
*)

PROCEDURE FreeLiveQHChain(con : UhciController; addr : LONGINT);
VAR
 nexttd : LONGINT;
 timenow, i, freeentry : INTEGER;
BEGIN

 timenow := GetFrame(con); freeentry := -1;

 FOR i:= 0 TO MaxGCEntries - 1 DO
  IF con.GCqueueList[i] = 1 THEN
   freeentry := i; (* found a free entry to use *)
  ELSIF con.GCqueueTimestamp[i] # timenow THEN
    FreeDeadQHChain(con, con.GCqueueList[i]);
    con.GCqueueList[i] := 1;
    freeentry := i; (* found a free entry to use *)
  END;
 END;
 IF freeentry # -1 THEN
  con.GCqueueList[freeentry] := addr;
  con.GCqueueTimestamp[freeentry] := timenow;
 ELSE
  (* THIS IS VERY UNLIKELY *)
  IF DEBUG THEN Kernel.WriteString("UsbUhci: Bad luck, GCqueue full"); Kernel.WriteLn; END;
  WHILE (GetFrame(con) = timenow) DO (* nothing *) END;
  FreeDeadQHChain(con, addr);
  (* we can do the following, since in Native Oberon there wont be any new entries,
  there is no concurrency *)
  FOR i:= 0 TO MaxGCEntries - 1 DO
   IF con.GCqueueList[i] # 1 THEN FreeDeadQHChain(con, con.GCqueueList[i]); con.GCqueueList[i] := 1; END;
  END;
 END;
 
END FreeLiveQHChain;

(* ========================================================================= *)
(*                       The transaction scheduler                                                                                    *)
(* ========================================================================= *)

(* ============================== DoSchedule ================================ *)

PROCEDURE DoSchedule(con : UhciController; req : Usb.UsbTReq; qh : LONGINT);
VAR
 iclast, icnow, queue : LONGINT;
 t : Kernel.MilliTimer;
 status : SET;
BEGIN

 queue := InsertQH(con, req, qh);

 iclast := IntControllerCounter[con.idx];

 IF req.Timeout = -1 THEN
  LOOP
   REPEAT icnow := IntControllerCounter[con.idx] UNTIL icnow # iclast;
   status := GetQueueStatus(req, qh);
   IF (status * Usb.ResInProgress) = {} THEN EXIT END;
   iclast := icnow;  
  END;
 ELSE
  Kernel.SetTimer(t, req.Timeout);
  LOOP
   REPEAT icnow := IntControllerCounter[con.idx] UNTIL (Kernel.Expired(t) OR (icnow # iclast));
   status := GetQueueStatus(req, qh);
   IF Kernel.Expired(t) OR ((status * Usb.ResInProgress) = {}) THEN EXIT; END;
   iclast := icnow;
  END;
 END;

 IF DEBUG THEN Kernel.WriteString("UsbUhci: transfer finished"); Kernel.WriteLn; END;

 req.Status := status;

 DeleteQH(con, req, queue, qh);

END DoSchedule;

(* ============================= UpcallDeleteTrans ============================= *)

PROCEDURE UpcallDeleteTrans(con : Usb.UsbController; req : Usb.UsbTReq);
VAR
 spec : UhciConSpec;
BEGIN

 IF DEBUG THEN Kernel.WriteString("UsbUhci: got request for deleting transfer"); Kernel.WriteLn; END; 

 IF req.ConSpec = NIL THEN
  Kernel.WriteString("UsbUhci: Warning, trying to delete trans again"); Kernel.WriteLn;
  RETURN
 END;

 WITH con : UhciController DO
  spec := req.ConSpec (UhciConSpec);
  DeleteQH(con, req, spec.queue, spec.qh);
  FreeLiveQHChain(con, spec.qh);
  req.ConSpec := NIL;
 END;

 IF DEBUG THEN Kernel.WriteString("UsbUhci: request deleted"); Kernel.WriteLn; END; 

END UpcallDeleteTrans;


(* ============================ UpcallRestartInterrupt ========================== *)

PROCEDURE UpcallRestartInterrupt(con : Usb.UsbController; req : Usb.UsbTReq);
VAR
 spec : UhciConSpec;
BEGIN

 IF DEBUG THEN Kernel.WriteString("UsbUhci: got request for restarting interrupt"); Kernel.WriteLn; END;

 IF (req.Typ # Usb.TransferInterrupt) THEN HALT(303); END;

 IF req.ConSpec = NIL THEN
  Kernel.WriteString("UsbUhci: Warning, trying to restart blocking interrupt"); Kernel.WriteLn;  
  req.Status := Usb.ResInternal;
  RETURN;
 END;

 IF (req.Status * Usb.ResInProgress) # {} THEN RETURN END; (* don't restart allready started transfers *)

 WITH con : UhciController DO
  spec := req.ConSpec (UhciConSpec);
  req.Status := Usb.ResInProgress;
  RestartInterruptQH(req, spec.qh);
 END;

END UpcallRestartInterrupt;

(* ============================= UpcallProbeTrans ============================= *)

PROCEDURE UpcallProbeTrans(con : Usb.UsbController; req : Usb.UsbTReq);
VAR
 spec : UhciConSpec;
BEGIN

 IF req.ConSpec = NIL THEN
  Kernel.WriteString("UsbUhci: Warning, trying to probe blocking transfer"); Kernel.WriteLn;
  req.Status := Usb.ResInternal;
  RETURN;
 END;

 WITH con : UhciController DO
  spec := req.ConSpec (UhciConSpec);
 END;

 req.Status := GetQueueStatus(req, spec.qh);
 
END UpcallProbeTrans;

(* ============================= InsertQH ============================== *)

PROCEDURE InsertQH(con : UhciController; req : Usb.UsbTReq; qh : LONGINT) : LONGINT; (* ******* MUTEX !!!!!!!! ******* *)
VAR
 qhtmp, queue : LONGINT;
 slots : LONGINT; index, queueslots : INTEGER;
BEGIN

 IF req.Typ = Usb.TransferControl THEN
  queue := con.ControlTD;
 ELSIF req.Typ = Usb.TransferBulk THEN
  queue := con.BulkTD;
 ELSIF req.Typ = Usb.TransferInterrupt THEN

  slots := 1024 DIV req.IRQInterval;
  index := 0; queueslots := 1024;

  LOOP
   IF queueslots = 0 THEN index := 10; EXIT; END;
   IF slots >= queueslots THEN EXIT END;
   queueslots := queueslots DIV 2; INC (index);
  END;

  queue := con.InterruptTD[index];
 ELSE
  HALT(303);
 END;

 SYSTEM.GET(queue, SYSTEM.VAL(LONGINT, qhtmp));
 SYSTEM.PUT(qh, SYSTEM.VAL(LONGINT, qhtmp));
 SYSTEM.PUT(queue, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, qh) + {1} ));

 req.next := con.TReqList;
 con.TReqList := req;

 RETURN queue;

END InsertQH;

(* ============================= DeleteQH ============================== *)

PROCEDURE DeleteQH(con : UhciController; req : Usb.UsbTReq; queue, qh : LONGINT); (* ******* MUTEX !!!!!!!! ******* *)
VAR
 qhtmp, delthis : LONGINT;
 reqtmp : Usb.UsbTReq;
BEGIN

 reqtmp := con.TReqList;

 IF reqtmp = req THEN
  con.TReqList := req.next;
 ELSE
  WHILE (reqtmp.next # req) DO
   reqtmp := reqtmp.next;
  END;
  reqtmp.next := req.next;
 END;

 delthis := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, qh) + {1} );

 LOOP
  SYSTEM.GET(queue, SYSTEM.VAL(LONGINT, qhtmp));
  IF qhtmp = 1 THEN
   Kernel.WriteString("UsbUhci: Fatal, DeleteQH cannot find qh entry in queue"); Kernel.WriteLn;
   HALT(303);
  END;
  IF qhtmp = delthis THEN
   SYSTEM.GET(qh, SYSTEM.VAL(LONGINT, qhtmp));
   SYSTEM.PUT(queue, SYSTEM.VAL(LONGINT, qhtmp));
   EXIT;
  END;
  queue := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, qhtmp) - {1} );
 END;

END DeleteQH;

(* ========================== RestartInterruptQH ============================ *)

PROCEDURE RestartInterruptQH(req : Usb.UsbTReq; qh : LONGINT);
VAR
 tdtmp, val, pid : LONGINT;
 status : SET; datatoggle : BOOLEAN;
BEGIN

 SYSTEM.GET(qh + 8, SYSTEM.VAL(LONGINT, tdtmp));

 (* modify the data0/1 bit *)

 SYSTEM.GET(tdtmp + 8, SYSTEM.VAL(LONGINT, val));
 pid := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) * {0..7});
 status := SYSTEM.VAL(SET, val);

 IF pid = PidOut THEN
  datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
  req.Device.DataToggleOut[req.Endpoint MOD 16] := ~datatoggle;
 ELSIF pid = PidIn THEN
  datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
  req.Device.DataToggleIn[req.Endpoint MOD 16] := ~datatoggle;
 ELSE
  HALT(303);
 END;

 IF datatoggle THEN
  status := status + TDDataToggle;
 ELSE
  status := status - TDDataToggle;
 END;
 SYSTEM.PUT(tdtmp + 8, SYSTEM.VAL(LONGINT, status)); 

 (* reactivate it *)

 SYSTEM.GET(tdtmp + 4, SYSTEM.VAL(LONGINT, val));
 status := SYSTEM.VAL(SET, val) + TDActive + TDERR3;
 SYSTEM.PUT(tdtmp + 4, SYSTEM.VAL(LONGINT, status));

 (* set the queue element pointer so that the uhci will execute the element again *)

 SYSTEM.PUT(qh + 4, SYSTEM.VAL(LONGINT, tdtmp));

END RestartInterruptQH;

(* ========================================================================= *)
(*                       TD Constructing code                                                                                           *)
(* ========================================================================= *)

(* =============================== BuildTD ================================== *)

PROCEDURE BuildTD(td, f1, f2, f3, f4 : LONGINT);
BEGIN
 SYSTEM.PUT(td, SYSTEM.VAL(LONGINT, f1));
 SYSTEM.PUT(td+4, SYSTEM.VAL(LONGINT, f2));
 SYSTEM.PUT(td+8, SYSTEM.VAL(LONGINT, f3));
 SYSTEM.PUT(td+12, SYSTEM.VAL(LONGINT, f4));
END BuildTD;

(* =========================== BuildTDLinkPointer ============================= *)

PROCEDURE BuildTDLinkPointer (VAR td:LONGINT; flags : SET; LinkPointer : LONGINT);
BEGIN
 ASSERT( SYSTEM.VAL( SET, LinkPointer) * {0..3} = {} );
 SYSTEM.PUT(td, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, LinkPointer) + flags));
END BuildTDLinkPointer;

(* ========================== BuildTDControlStatus ============================ *)

PROCEDURE BuildTDControlStatus (VAR td:LONGINT; status : SET);
BEGIN
 SYSTEM.PUT(td+4, SYSTEM.VAL(LONGINT, status));
END BuildTDControlStatus;

(* ============================== BuildTDToken ============================== *)

PROCEDURE BuildTDToken (VAR td:LONGINT; PID, DeviceAddress, EndPoint : LONGINT; DataBit : BOOLEAN;
 MaxLen : LONGINT);
VAR
 s : SET;
BEGIN
 IF MaxLen = 0 THEN MaxLen := 07FFH; ELSE MaxLen := MaxLen - 1; END;
 s := {};
 IF DataBit THEN s := s + TDDataToggle END;
 SYSTEM.PUT(td + 8, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET,
  PID + ASH(DeviceAddress, 8) + ASH(EndPoint, 15) + ASH(MaxLen, 21)) + s));
END BuildTDToken;

(* ============================= PrepareInterrupt ============================ *)

PROCEDURE PrepareInterrupt(con : UhciController; req : Usb.UsbTReq) : SET;
VAR
 qh, td, firsttd, lasttd : LONGINT;
 status : SET; datatoggle : BOOLEAN;
 spec : UhciConSpec; pid : INTEGER;
BEGIN

 IF DEBUG THEN Kernel.WriteString("UsbUhci: got request for interrupt transfer"); Kernel.WriteLn; END;

 (* the specs say that values  0 < x < 256 are ok, but since the controller supports it, we allow for higher values *)
 (* perhaps needed for special usb driver test code *)

 IF (req.IRQInterval < 0) OR (req.IRQInterval > 1000) THEN
  RETURN Usb.ResInternal;
 END;

 status := TDActive + TDIOC + TDERR3;
 IF req.Device.LowSpeed THEN status := status + TDLS; END;

 IF (SYSTEM.VAL(SET, req.Endpoint) * {7}) = {} THEN
  datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
  IF req.BufferLen < req.Device.MaxPacketSizeOut[req.Endpoint MOD 16] THEN
   RETURN Usb.ResInternal;
  END;
  pid := PidOut;
 ELSE
  datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
  IF req.BufferLen < req.Device.MaxPacketSizeIn[req.Endpoint MOD 16] THEN
   RETURN Usb.ResInternal;
  END;
  status := status + TDSPD;
  pid := PidIn;
 END;

 qh := AllocTD(con);
 IF (qh = -1) THEN RETURN Usb.ResInternal; END;

 td := AllocTD(con);
 IF (td = -1) THEN
  FreeTD(con, qh);
  RETURN Usb.ResInternal;
 END;

 firsttd := td;
 lasttd := td;

 BuildTDLinkPointer(td, TDTerminate, 0);
 BuildTDControlStatus(td, status);
 BuildTDToken(td, pid, req.Device.Address, req.Endpoint MOD 16, datatoggle, req.BufferLen);
 SYSTEM.PUT(td + 12, SYSTEM.VAL(LONGINT, req.Buffer));

 (* Build qh *)

 BuildTD(qh, 1, firsttd, firsttd, lasttd);

 req.Status := Usb.ResInProgress;

 IF req.Timeout # 0 THEN
  IF DEBUG THEN Kernel.WriteString("UsbUhci: starting interrupt transfer"); Kernel.WriteLn; END; 
  DoSchedule(con, req, qh);
  FreeLiveQHChain(con, qh);
  req.ConSpec := NIL;
 ELSE
  IF DEBUG THEN Kernel.WriteString("UsbUhci: starting nonblocking interrupt transfer"); Kernel.WriteLn; END;  
  NEW(spec); spec.qh := qh; req.ConSpec := spec;
  spec.queue := InsertQH(con, req, qh);
 END;

 RETURN req.Status;

END PrepareInterrupt;

(* ============================= PrepareControl ============================== *)

PROCEDURE PrepareControl(con : UhciController; req : Usb.UsbTReq) : SET;

VAR
 qh, td, tdnext, firsttd, lasttd, pretd : LONGINT;
 pid : INTEGER;
 curlen, restlen, databuff : LONGINT;
 datatoggle : BOOLEAN;
 status : SET;
 spec : UhciConSpec;
BEGIN

 IF DEBUG THEN
  Kernel.WriteString("UsbUhci: got request for control transfer"); Kernel.WriteLn;
  Kernel.WriteString("UsbUhci: details:");
  Kernel.WriteString(" address "); Kernel.WriteInt(req.Device.Address, 0);
  Kernel.WriteString(" endpoint "); Kernel.WriteInt(req.Endpoint, 0);
  Kernel.WriteString(" len: "); Kernel.WriteInt(req.BufferLen, 0); Kernel.WriteLn;
 END;

 qh := AllocTD(con);
 IF (qh = -1) THEN RETURN Usb.ResInternal; END;

 td := AllocTD(con);
 IF (td = -1) THEN
  FreeTD(con, qh);
  RETURN Usb.ResInternal;
 END;

 firsttd := td;

 (* Build Setup td *)
 
 tdnext := AllocTD(con);
 IF (tdnext = -1) THEN RETURN Usb.ResInternal; END;

 status := TDActive + TDERR3;
 IF req.Device.LowSpeed THEN status := status + TDLS; END; 

 BuildTDLinkPointer(td, TDDepthFirst, tdnext);
 BuildTDControlStatus(td, status);
 BuildTDToken(td, PidSetup, req.Device.Address, req.Endpoint MOD 16, FALSE, 8);
 SYSTEM.PUT(td + 12, SYSTEM.VAL(LONGINT, req.ControlMessage));
 
 (* Build Data td's, if any *) 

 IF req.BufferLen # 0 THEN

  datatoggle := TRUE;
  restlen := req.BufferLen;
  databuff := req.Buffer;

  IF (SYSTEM.VAL(SET, req.Endpoint) * {7}) = {} THEN pid := PidOut; ELSE pid := PidIn; status := status + TDSPD; END;

  WHILE restlen >  0 DO

   pretd := td;
   td := tdnext;
   tdnext := AllocTD(con);
   IF (tdnext = -1) THEN
    BuildTDLinkPointer(pretd, TDTerminate, 0);
    BuildTD(qh, 1, firsttd, firsttd, pretd);
    FreeDeadQHChain(con, qh);
    RETURN Usb.ResInternal;
   END;

   IF restlen > req.Device.Descriptor.bMaxPacketSize0 THEN
    curlen := req.Device.Descriptor.bMaxPacketSize0
   ELSE
    curlen := restlen;
   END;

   BuildTDLinkPointer(td, TDDepthFirst, tdnext);
   BuildTDControlStatus(td, status);
   BuildTDToken(td, pid, req.Device.Address, req.Endpoint MOD 16, datatoggle, curlen);
   SYSTEM.PUT(td + 12, SYSTEM.VAL(LONGINT, databuff));
  
   datatoggle := ~ datatoggle;
      
   databuff := databuff + curlen;
   restlen := restlen - curlen;

  END;
   
 END;

 td := tdnext;
  
 IF ((SYSTEM.VAL(SET, req.Endpoint) * {7}) = {} ) OR (req.BufferLen = 0) THEN pid := PidIn; ELSE pid := PidOut; END;
 
 status := (status - (TDSPD + TDERR3)) + TDIOC;
 
 BuildTDLinkPointer(td, TDTerminate, 0);
 BuildTDControlStatus(td, status + TDIOC); 
 BuildTDToken(td, pid, req.Device.Address, req.Endpoint MOD 16, TRUE, 0);
 SYSTEM.PUT(td + 12, SYSTEM.VAL(LONGINT, 0));

 lasttd := td;

 (* Build qh *)

 BuildTD(qh, 1, firsttd, firsttd, lasttd);

 req.Status := Usb.ResInProgress;

 IF req.Timeout # 0 THEN
  IF DEBUG THEN Kernel.WriteString("UsbUhci: starting control transfer"); Kernel.WriteLn; END;
  DoSchedule(con, req, qh);
  FreeLiveQHChain(con, qh);
  req.ConSpec := NIL;
 ELSE
  IF DEBUG THEN Kernel.WriteString("UsbUhci: starting nonblocking control transfer"); Kernel.WriteLn; END;
  NEW(spec); spec.qh := qh; req.ConSpec := spec;
  spec.queue := InsertQH(con, req, qh);
 END;

 RETURN req.Status;

END PrepareControl;

(* ============================= PrepareBulk ============================== *)

PROCEDURE PrepareBulk(con : UhciController; req : Usb.UsbTReq) : SET;

VAR
 qh, td, tdnext, firsttd, lasttd, pretd : LONGINT;
 pid, pipesize : INTEGER;
 curlen, restlen, databuff : LONGINT;
 datatoggle : BOOLEAN;
 status : SET;
 spec : UhciConSpec;
BEGIN

 qh := AllocTD(con);
 IF (qh = -1) THEN RETURN Usb.ResInternal; END;

 td := AllocTD(con);
 IF (td = -1) THEN
  FreeTD(con, qh);
  RETURN Usb.ResInternal;
 END;

 firsttd := td;
 tdnext := td;

 status := TDActive + TDERR3;
 IF req.Device.LowSpeed THEN status := status + TDLS; END; 

 restlen := req.BufferLen;
 databuff := req.Buffer;

 IF (SYSTEM.VAL(SET, req.Endpoint) * {7}) = {} THEN
  datatoggle := req.Device.DataToggleOut[req.Endpoint MOD 16];
  pipesize := req.Device.MaxPacketSizeOut[req.Endpoint MOD 16];
  pid := PidOut;
 ELSE
  datatoggle := req.Device.DataToggleIn[req.Endpoint MOD 16];
  pipesize := req.Device.MaxPacketSizeIn[req.Endpoint MOD 16]; 
  pid := PidIn;
  status := status + TDSPD;
 END;

 LOOP

  pretd := td;
  td := tdnext;

  IF restlen > pipesize THEN
   curlen := pipesize;
   tdnext := AllocTD(con);
   IF (tdnext = -1) THEN
    BuildTDLinkPointer(pretd, TDTerminate, 0);
    BuildTD(qh, 1, firsttd, firsttd, pretd);
    FreeDeadQHChain(con, qh);
    RETURN Usb.ResInternal;
   END;
   BuildTDLinkPointer(td, TDDepthFirst, tdnext);
  ELSE
   curlen := restlen;
   BuildTDLinkPointer(td, TDTerminate, 0);
  END;

  BuildTDControlStatus(td, status);

  BuildTDToken(td, pid, req.Device.Address, req.Endpoint MOD 16, datatoggle, curlen);
  SYSTEM.PUT(td + 12, SYSTEM.VAL(LONGINT, databuff));
  
  datatoggle := ~datatoggle;
   
  databuff := databuff + curlen;
  restlen := restlen - curlen;

  IF restlen = 0 THEN
   BuildTDControlStatus(td, status + TDIOC);
   EXIT;
  END;

 END;

 lasttd := td;

 IF pid = PidOut THEN
  req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle;
 ELSE
  req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle;
 END;

 (* Build qh *)

 BuildTD(qh, 1, firsttd, firsttd, lasttd);

 req.Status := Usb.ResInProgress;

 IF req.Timeout # 0 THEN
  DoSchedule(con, req, qh);
  FreeLiveQHChain(con, qh);
  req.ConSpec := NIL;
 ELSE
  IF DEBUG THEN Kernel.WriteString("UsbUhci: starting nonblocking bulk transfer"); Kernel.WriteLn; END;  
  NEW(spec); spec.qh := qh; req.ConSpec := spec;
  spec.queue := InsertQH(con, req, qh);
 END;

 RETURN req.Status;

END PrepareBulk;

(* ========================== GetTransferredLen ============================ *)

PROCEDURE GetTransferredLen(req : Usb.UsbTReq; qh : LONGINT);
VAR
 td, addr, actlen, thislen, val : LONGINT;
 s : SET;
BEGIN

 actlen := 0;

 SYSTEM.GET(qh + 8, SYSTEM.VAL(LONGINT, td)); (* get first element of queue *)

 LOOP
  IF (SYSTEM.VAL(SET, td) * {0}) # {} THEN EXIT; END;

  addr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, td) * {4..31}); (* addr := physical addr of td *)

  SYSTEM.GET(addr+4, SYSTEM.VAL(LONGINT, val)); (* get 4 bytes - td control and status *)
  s := SYSTEM.VAL(SET, val);

  IF (s * TDActive) # {} THEN EXIT; END;

  thislen := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, (val+1)) * {0..10});
  SYSTEM.GET(addr+8, SYSTEM.VAL(LONGINT, val)); (* get 4 bytes - td token*)
  IF SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) * {0..7}) # PidSetup THEN actlen := actlen + thislen; END;

  IF (s * (TDCrcTimeout + TDDataBuffer + TDStalled + TDBitStuff + TDBabble + TDNak)) # {} THEN EXIT END;

  SYSTEM.GET(addr, SYSTEM.VAL(LONGINT, td)); (* td := link pointer of td at addr *)
 END;

 req.BufferLen := actlen;

END GetTransferredLen;

(* =========================== GetQueueStatus ============================ *)

PROCEDURE GetQueueStatus(req : Usb.UsbTReq; qh : LONGINT) : SET;
VAR
 val, td, addr, actlen, maxlen, pid : LONGINT;
 status, s : SET; datatoggle : BOOLEAN;
BEGIN

 (* Test if the queue was finished *)

 SYSTEM.GET(qh+4, SYSTEM.VAL(LONGINT, td)); (* get qh element link pointer *)

 IF td = 1 THEN (* yes, fetch status of last td in queue *)
  SYSTEM.GET(qh + 12, SYSTEM.VAL(LONGINT, td));
 ELSE
  td := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, td) * {4..31});
 END;

 addr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, td) * {4..31}); (* addr := physical addr of td *)

 SYSTEM.GET(addr+4, SYSTEM.VAL(LONGINT, val)); (* get 4 bytes - td control and status *)
 s := SYSTEM.VAL(SET, val);
 (* actlen := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, (val+1)) * {0..10}); *)

 status := {};

 (* NAK occured? Set it, it is not an error - we can still be in progress *)

 IF (s * TDNak) # {} THEN status := status + Usb.ResNAK END;

 IF (s * TDActive) # {} THEN
  RETURN status + Usb.ResInProgress;
 END;

 SYSTEM.GET(addr+8, SYSTEM.VAL(LONGINT, val)); (* get 4 bytes - td token*)
 maxlen := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(val, -21) + 1) * {0..10});
 pid := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, val) * {0..7});
 IF (SYSTEM.VAL(SET, val) * TDDataToggle) # {} THEN datatoggle := TRUE ELSE datatoggle := FALSE END;

 (* Test for errors *)

 actlen := req.BufferLen; GetTransferredLen(req, qh);
 IF req.BufferLen < actlen THEN status := status + Usb.ResShortPacket END;

 IF (s * (TDCrcTimeout + TDDataBuffer + TDStalled + TDBitStuff + TDBabble)) # {} THEN (* marginal speed up *)
  IF (s * TDCrcTimeout) # {} THEN status := status + Usb.ResCRCTimeout END;
  IF (s * TDDataBuffer) # {} THEN status := status + Usb.ResDataBuffer END;
  IF (s * TDStalled) # {} THEN status := status + Usb.ResStalled END;
  IF (s * TDBitStuff) # {} THEN status := status + Usb.ResBitStuff END;
  IF (s * TDBabble) # {} THEN status := status + Usb.ResBabble END;
 END;

 IF status = {} THEN status := Usb.ResOK; END;

 IF (req.Typ = Usb.TransferBulk) OR (req.Typ = Usb.TransferInterrupt) THEN

  (* if we receive an ACK, do the toggle *)

  IF (status = Usb.ResOK) OR (status = Usb.ResShortPacket) THEN
   datatoggle := ~datatoggle;
  END;

  (* write the toggle back *)

  IF pid = PidOut THEN
   req.Device.DataToggleOut[req.Endpoint MOD 16] := datatoggle;
  ELSIF pid = PidIn THEN
   req.Device.DataToggleIn[req.Endpoint MOD 16] := datatoggle;
  ELSE
   HALT(303);
  END;
 END;
  
 RETURN status;

END GetQueueStatus;

(* ========================================================================= *)
(*                       Debug code for transactions                                                                                *)
(* ========================================================================= *)

(* Deactivated, but not deleted.

PROCEDURE HumanTD(nexttd: LONGINT);
VAR
 addr, val : LONGINT;
 s : SET;
BEGIN

 LOOP

  addr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, nexttd) * {4..31});

  SYSTEM.GET(addr, SYSTEM.VAL(LONGINT, val));
  s := SYSTEM.VAL(SET, val); 
  Kernel.WriteString("LInkPTR:");
  IF (s * TDDepthFirst) # {} THEN Kernel.WriteString(" [Depthfirst]"); END;
  IF (s * TDQHSelect) # {} THEN Kernel.WriteString(" [QH]"); ELSE Kernel.WriteString(" [TD]"); END;
  IF (s * TDTerminate) # {} THEN Kernel.WriteString(" [Terminate]"); END;
  Kernel.WriteString(" [PTR Val: "); PrintHex((val DIV 16) * 16 ); Kernel.WriteString(" ]");
  Kernel.WriteLn;

  SYSTEM.GET(addr+4, SYSTEM.VAL(LONGINT, val));
  s := SYSTEM.VAL(SET, val); 
  Kernel.WriteString("ControlStatus:");
  IF (s * TDActive) # {} THEN Kernel.WriteString(" [Active]"); END;
  IF (s * TDIOC) # {} THEN Kernel.WriteString(" [IOC]"); END;
  IF (s * TDIOS) # {} THEN Kernel.WriteString(" [IOS]"); END;
  IF (s * TDLS) # {} THEN Kernel.WriteString(" [LowSpeed]"); END;
  IF (s * TDERR1) # {} THEN Kernel.WriteString(" [Err1]"); END;
  IF (s * TDERR2) # {} THEN Kernel.WriteString(" [Err2]"); END;
  IF (s * TDSPD) # {} THEN Kernel.WriteString(" [SPD]"); END;
  IF (s * TDCrcTimeout) # {} THEN Kernel.WriteString(" [CRC/Timeout]"); END;
  IF (s * TDNak) # {} THEN Kernel.WriteString(" [NAK]"); END;
  IF (s * TDDataBuffer) # {} THEN Kernel.WriteString(" [DataBuffer]"); END;
  IF (s * TDStalled) # {} THEN Kernel.WriteString(" [Stalled]"); END;
  IF (s * TDBitStuff) # {} THEN Kernel.WriteString(" [BitStuff]"); END;
  IF (s * TDBabble) # {} THEN Kernel.WriteString(" [Babble]"); END;
  Kernel.WriteString (" [Actlen: ");
  Kernel.WriteInt(SYSTEM.VAL(INTEGER, SYSTEM.VAL(SET, SYSTEM.VAL(INTEGER, s) + 1) * {0..10}), 0);
  Kernel.WriteString(" ]"); Kernel.WriteLn;
  Kernel.WriteLn;

  SYSTEM.GET(addr, SYSTEM.VAL(LONGINT, nexttd));
  IF (SYSTEM.VAL(SET, nexttd) * {0}) # {} THEN EXIT; END;

 END;

END HumanTD;

*)

(* ========================================================================= *)
(*                       Show diagnostics of a controller                                                                          *)
(* ========================================================================= *)

PROCEDURE HumanStatus(con: UhciController);
VAR
 s: SET;
 framenum : LONGINT;
 i : INTEGER;
BEGIN

 SYSTEM.PORTIN (con.iobase + FRNUM, SYSTEM.VAL(INTEGER, framenum));
 framenum := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, framenum) * {0..10});

 SYSTEM.PORTIN (con.iobase + USBSTS, SYSTEM.VAL(INTEGER, s));
 Kernel.WriteString ("Diagnostics of UHCI at base 0"); PrintHex(con.iobase); Kernel.WriteString("H, Irq ");
 Kernel.WriteInt (con.irq, 0); Kernel.WriteString(", frame 0"); PrintHex(framenum); Kernel.WriteString("H, Int Cnt: ");
 Kernel.WriteInt(IntControllerCounter[con.idx], 0); Kernel.WriteLn;

 s := IntControllerStatus[con.idx];
 Kernel.WriteString(" LastStatus:");
 IF (s # {}) THEN
  IF (s * StatusHChalted) # {} THEN Kernel.WriteString (" [HChalted]"); END;
  IF (s * StatusProcessError) # {} THEN Kernel.WriteString (" [Process Error]"); END;
  IF (s * StatusSystemError) # {} THEN Kernel.WriteString (" [System Error]"); END;
  IF (s * StatusResumeDetect) # {} THEN Kernel.WriteString (" [Resume Detect]"); END;
  IF (s * StatusErrorInt) # {} THEN Kernel.WriteString (" [ErrorInt]"); END;
  IF (s * StatusInt) # {} THEN Kernel.WriteString (" [Int]"); END;
  Kernel.WriteLn;
 ELSE
  Kernel.WriteString(" [ok]");
  Kernel.WriteLn;
 END;

 SYSTEM.PORTIN (con.iobase + USBINTR, SYSTEM.VAL(INTEGER, s));
 Kernel.WriteString (" IRQ enable status:");
 IF (s * IntShortPacket) # {} THEN Kernel.WriteString(" [Short Packet]"); END;
 IF (s * IntIOC) # {} THEN Kernel.WriteString (" [IOC]"); END;
 IF (s * IntResume) # {} THEN Kernel.WriteString (" [Resume]"); END;
 IF (s * IntTimeoutCRC) # {} THEN Kernel.WriteString (" [Timeout/CRC]"); END;
 Kernel.WriteLn;

 FOR i:=0 TO con.portCount -1 DO
  SYSTEM.PORTIN (con.iobase + PORTSC1 + i*2, SYSTEM.VAL(INTEGER, s));
  Kernel.WriteString (" Port "); Kernel.WriteInt(i+1, 0); Kernel.WriteString(" status:");
  IF (s * Ported) # {} THEN Kernel.WriteString(" [enabled]"); ELSE Kernel.WriteString(" [disabled]"); END;
  IF (s * PortSuspend) # {} THEN Kernel.WriteString (" [susp]"); END;
  IF (s * PortLowSpeed) # {} THEN Kernel.WriteString (" [lowspeed]"); END;
  IF (s * Portcs) # {} THEN Kernel.WriteString (" [device present]"); END;
  Kernel.WriteLn;
 END;

END HumanStatus;

(* ========================================================================= *)
(*                       Init a controller                                                                                                    *)
(* ========================================================================= *)

PROCEDURE InitController(base: LONGINT; irq : INTEGER) : BOOLEAN;
VAR
 i, k, j : LONGINT;
 con : UhciController;
BEGIN

 IF (ControllerCount >= MaxControllers) OR (irq > 15) THEN RETURN FALSE END;

 NEW(con);

 con.OpReset := UpcallResetController;
 con.OpEnablePort := UpcallEnablePort;
 con.OpDisablePort := UpcallDisablePort;
 con.OpGetPortStatus := UpcallGetPortStatus;
 con.OpGetPortCount := UpcallGetPortCount;
 
 con.OpSendReq := UpcallSendReq;
 con.OpProbeTrans := UpcallProbeTrans;
 con.OpDeleteTrans := UpcallDeleteTrans;
 con.OpRestartInterrupt := UpcallRestartInterrupt;

 NEW(con.framelist);
 NEW(con.tdlist);

 con.idx := ControllerCount;
 con.iobase := base;
 con.irq := irq;

 (* configure the ports *)
 
 con.portCount := 2; (* no more documented in the specs, but 3-4 possible *)

 NEW(con.port, con.portCount);

 FOR i := 0 TO con.portCount - 1 DO
  con.port[ i ] := con.iobase + PORTSC1 + i*2;
 END;

 (* setup the free td list, a little bit of own memory managment, since we don't like memory fragmentation *)

 con.tdlist.tdlistbase := SYSTEM.VAL(LONGINT,
   SYSTEM.VAL(SET, SYSTEM.ADR(con.tdlist.field[0]) + 15) * {4..31});
 
 con.tdlist.index := ( con.tdlist.tdlistbase - SYSTEM.ADR(con.tdlist.field[0]) ) DIV 4;

 FOR i:=0 TO MaxTDPerController - 1 DO
  con.tdlist.freelist[ i ] := con.tdlist.tdlistbase + i*16;
 END;

 con.tdlist.first := 0;
 con.tdlist.last := MaxTDPerController - 1;

 FOR i := 0 TO MaxGCEntries - 1 DO
  con.GCqueueList[i] := 1; (* 1 = no entry *)
 END;

 (* calculate the address of the 4K boundary contained in the 8K buffer *)
 
 con.framelist.framelistbase := SYSTEM.VAL(LONGINT,
   SYSTEM.VAL(SET, SYSTEM.ADR(con.framelist.field[0]) + 1024*4 - 1) * {12..31});

 (* calculate the index which points to the element positioned at the 4K boundary *)
 
 con.framelist.index := ( con.framelist.framelistbase - SYSTEM.ADR(con.framelist.field[0]) ) DIV 4;
 
 (* set up the frame list pointer skeleton *)

 con.ControlTD := AllocTD(con);
 con.BulkTD := AllocTD(con);

 IF (con.ControlTD = -1) OR (con.BulkTD = -1) THEN
  con := NIL; RETURN FALSE;
 END;

 (* ========================= Interrupt spread ================================== *)

 FOR i := 0 TO 10 DO
  con.InterruptTD[i] := AllocTD(con);
  IF con.InterruptTD[i] = -1 THEN
   con := NIL; RETURN FALSE;
  END;
 END;

 BuildTD(con.BulkTD, 1, 1, 0, 0);
 BuildTD(con.ControlTD, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, con.BulkTD) + {1} ), 1, 0, 0);
 BuildTD(con.InterruptTD[0], SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, con.ControlTD) + {1} ), 1, 0, 0);

 FOR i:=1 TO 10 DO
  BuildTD(con.InterruptTD[i], SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, con.InterruptTD[i-1]) + {1} ), 1, 0, 0);
 END;

 (* => end of queue 10 points to 9, end of 8 points to 7 , ..., end of 1 points to 0 *)
 (* => if we start at queue 10, then we will pass all others too; if we start at 9 then we will pass all queues < 9, too etc.*)

 (* queue 0 executes 1024x, queue 1 executes 512x, queue 2 executes 256x,  queue 3 executes 128x*)
 (* queue 4 executes 64x, queue 5 executes 32x, queue 6 executes 16x,  queue 7 executes 8x*)
 (* queue 8 executes 4x, queue 9 executes 2x, queue 10 executes 1x *)

 (* What does the following mean? => We count the 1's (starting at lsb) until we pass a zero *)
 (* This count gives the queue number for a given slot *)

 FOR i := 0 TO 1023 DO (* i is slot number, we want to calc the queue number (k) for this slot *)
  k := 0; j := i;
  LOOP
   IF (SYSTEM.VAL(SET, j) * {0}) = {} THEN EXIT; END;
   INC(k); j := j DIV 2;
  END;
  con.framelist.field[con.framelist.index + i] := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, con.InterruptTD[k]) + {1} );
 END;

 IntControllerBase[ con.idx ] := con.iobase;
 IntControllerStatus[ con.idx ] := {};
 IntControllerCounter[ con.idx ] := 0;
 IntControllerRunning[ con.idx ] := FALSE;

 ResetController(con);

 (* try to start the controller *)

 IF StartController(con) = FALSE THEN
  ResetController(con);
  RETURN FALSE;
 END;

 IntControllerActive[ con.idx ] := TRUE; 

 IF ~(con.irq IN UsbInterrupts) THEN
  INCL (UsbInterrupts, con.irq);
  Kernel.InstallIP(UpcallInterruptHandler, SHORT(Kernel.IRQ + con.irq));
 END;

 INC(ControllerCount);
 con.next := FirstController; FirstController := con;

 Usb.RegisterController(con);

 RETURN TRUE;

END InitController;

(* ========================================================================= *)
(*                       Find a controller on the pci bus                                                                            *)
(* ========================================================================= *)

PROCEDURE PCIFindUhci(id, vendor: LONGINT);
VAR index, bus, dev, fkt, iobase, IrqRouting: LONGINT;

 PROCEDURE ReadDWord(adr: LONGINT;  VAR s: LONGINT);
 VAR res: LONGINT;
 BEGIN
  res := PCI.ReadConfigDword(bus, dev, fkt, adr, s);
  IF res # PCI.Done THEN s := 0 END
 END ReadDWord;

 PROCEDURE ReadByte(adr: LONGINT;  VAR s: LONGINT);
 VAR res: LONGINT;
 BEGIN
  res := PCI.ReadConfigByte(bus, dev, fkt, adr, s);
  IF res # PCI.Done THEN s := 0 END
 END ReadByte;

 PROCEDURE WriteWord(adr: LONGINT;  s: LONGINT);
 VAR res: LONGINT;
 BEGIN
  res := PCI.WriteConfigWord(bus, dev, fkt, adr, s);
  (* ignore res *)
 END WriteWord;

BEGIN

 index := 0;

 WHILE (PCI.FindPCIDevice(id, vendor, index, bus, dev, fkt) = PCI.Done) DO

  ReadByte(3CH, IrqRouting); (* Register set by PCI Bios *)

  ReadDWord(20H, iobase);
  iobase := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, iobase) * {1..31});

  IF (IrqRouting = 0) THEN
   Kernel.WriteString("UsbUhci: Please enable USB-IRQ in BIOS for UHCI Controller at base 0");
   PrintHex(iobase); Kernel.WriteChar("H"); Kernel.WriteLn;
  ELSE
   WriteWord(0C0H, 2000H); (* disable legacy emulation *)
   IF InitController(iobase, SHORT(IrqRouting)) THEN
    Kernel.WriteString("UsbUhci: Initialised USB UHCI controller at base 0"); PrintHex(iobase); 
    Kernel.WriteString("H, Irq: "); Kernel.WriteInt(IrqRouting, 0); Kernel.WriteLn;
   ELSE
    Kernel.WriteString("UsbUhci: ERROR: Cannot init USB UHCI controller at base 0"); PrintHex(iobase); 
    Kernel.WriteString("H, Irq: "); Kernel.WriteInt(IrqRouting, 0); Kernel.WriteLn;
   END;
  END;

 INC(index);

 END;

END PCIFindUhci;

(* ========================================================================= *)
(*                       Cleanup (module unloading)                                                                                *)
(* ========================================================================= *)

PROCEDURE Cleanup();
VAR
 i: INTEGER;
 con : UhciController;
BEGIN

 FOR i:=0 TO 31 DO
  IF i IN UsbInterrupts THEN
   Kernel.RemoveIP(UpcallInterruptHandler, Kernel.IRQ + i);
  END;
 END;
 UsbInterrupts := {};

 con := FirstController;
 WHILE con # NIL DO
  Usb.RemoveController(con);
  ResetController(con);
  con := con.next;
 END;

END Cleanup;

(* ========================================================================= *)
(*                                                       Exported Procedure : Init                                                     *)
(* ========================================================================= *)

(* ================================= Init ==================================== *)

(** Find all Intel UHCI compatible controllers and register them in the USB core module **)
(** Currently, this is equivalent to the following chipsets:                                                  **)
(** Intel PIIX3, PIIX4, PIIX4E, 82801AA, 82901 AB (Whitney & co.)                                    **)

PROCEDURE Init*;
BEGIN

 IF ControllerCount # 0 THEN RETURN END;

 PCIFindUhci(7020H, 8086H); (* Intel PIIX3 *)
 PCIFindUhci(7112H, 8086H); (* Intel PIIX4 + PIIX4E *)
 PCIFindUhci(2412H, 8086H); (* Intel 82801 AA *)
 PCIFindUhci(2422H, 8086H); (* Intel 82901 AB *)
 PCIFindUhci(3038H, 1106H); (* VIA UHCI USB *)

END Init;

(* ========================================================================= *)
(*                   Exported Procedure : Diag (Show diagnostics of all Uhci controllers)                    *)
(* ========================================================================= *)

(* ================================= Diag =================================== *)

(** Show diagnostics of all activated UHCI controllers **)

PROCEDURE Diag*;
VAR
 con : UhciController;
BEGIN
 con := FirstController;
 WHILE con # NIL DO
  HumanStatus(con);
  con := con.next;
 END;
END Diag;

PROCEDURE Init0;
VAR i: INTEGER;
BEGIN
 FOR i:=0 TO (MaxControllers - 1) DO
  IntControllerActive[ i ] := FALSE;
 END;
 UsbInterrupts := {};
 ControllerCount := 0;

 Kernel.InstallTermHandler(Cleanup);
END Init0;

(* ========================================================================= *)
(*                       Start UhciController.Mod                                                                                     *)
(* ========================================================================= *)

BEGIN
 Init0();
 Init()
END UsbUhci.

(* Init: UsbUhci.Init  Diagnostics: UsbUhci.Diag *)
