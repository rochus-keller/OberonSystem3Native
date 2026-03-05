(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE NetNe2000; (* Peter Ryser, 11.1.2000 *)
 (* based on Linux source code: ne8390.h, ne8390.c, ne2kpci.c *)
 (** Ethernet driver for NE2000 clones
  *)

 (* for ISA cards set the config string: NE2000X0="port,irq"
  - no spaces
  - eg. for port 300, interuupt 10: NE2000X0="300H,10"
 *)
 
 (* known features:
  - up to 10 Mbit/s data rate on an idle 10Base-2 network
  - supports multiple cards (not tested)
 *)
 (* missing features (to do):
  - 32 bit IO support
 *)
 
 (* HISTORY
  31.5.2000 adapted driver to work with original Novell NE2000
        - fixed busy loop waiting for timer in RxOverrun
        - number of pages reduced from 3FH to 2FH
        - only read MAC address from EEPROM
  15.1.2000 ISA support added
  17.1.2000 removed the compiling problem in HandleCounters
 *)
  
 IMPORT SYSTEM, PCI, Kernel, NetBase, Files;

 CONST
  debug = FALSE; senddebug = FALSE; devlistdebug = FALSE; intdebug = FALSE; recdebug = FALSE;
  debugIgnoreIsa = FALSE;
  
  DevIDs = 10;
  MinPacketSize = 60;
  MaxPacketSize = 1516; (* 1514 + 2 byte padding to 32 bit boundary *)
  BufSize = 2048; (* OF LONGINT *)
  
  ConfigStr = "NE2000X0"; ConfigStrPos = 7;
  
 (*Registers*)
  E8390Cmd = 0; E8390DataPort = 10H; E8390Reset = 1FH;
  En0CldaLo = 1; En0StartPg = 1;
  En0CldaHi = 2; En0StopPg = 2;
  En0Boundary = 3;
  En0Tsr = 4; En0TpSr = 4;
  En0Ncr = 5; En0TcntLo = 5;
  EN0Fifo = 6; En0TcntHi = 6;
  En0Isr = 7;
  En0CrdaLo = 8; En0RsarLo = 8;
  En0CrdaHi = 9; En0RsarHi = 9;
  En0RcntLo = 0AH;
  En0RcntHi = 0BH;
  En0Rsr = 0CH; En0RxCr = 0CH;
  En0TxCr = 0DH; En0Counter0 = 0DH;
  En0Dcfg = 0EH; En0Counter1 = 0EH;
  En0Imr = 0FH; En0Counter2 = 0FH;
  
  En1Phys = 1; En1CurPag = 7; En1Mult = 8;

 (* cmd register bits *)
  E8390Page0 = 0; E8390Page1 = 40H; E8390Page2 = 80H; E8390Page3 = 0C0H;
  E8390Stop = 1; E8390Start = 2; E8390Trans = 4;
  E8390Rread = 8; E8390Rwrite = 10H;
  E8390NoDma = 20H;
  
 (* isr register bits *)
  EnIsrRx = 1; EnIsrTx = 2; EnIsrRxErr = 4; EnIsrTxErr = 8;
  EnIsrOver = 10H; EnIsrCounters = 20H; EnIsrRdc = 40H; EnIsrReset = 80H;
  EnIsrAll = 3FX; (* Interrupts we will enable *)
 
 (* tsr register bits *)
  EnTsrPtx = 1; EnTsrNd = 2; EnTsrCol = 4; EnTsrAbt = 8;
  EnTsrCrs = 10H; EnTsrFu = 20H; EnTsrCdh = 40H; EnTsrOwc = 80H;
  
 (* rsr register bits *)
  EnRsrRxOk = 1; EnRsrCrc = 2; EnRsrFae = 4; EnRsrFo = 8;
  EnRsrMpa = 10H; EnRsrPhy = 20H; EnRsrDis = 40H; EnRsrDef = 80H;
  
 (* other register bits *)
  E8390TxIrqMask = 0AH; E8390RxIrqMask = 5;
  E8390RxConfig = 4; E8390RxOff = 20H;
  E8390TxConfig = 0; E8390TxOff = 2;
  
 (* misc. *)
  StartPage = 40H; StopPage = 60H; TxPages = 12;
  
 TYPE
  Device = POINTER TO DeviceDesc;
  DeviceDesc = RECORD (NetBase.DeviceDesc)
   memaccess: BOOLEAN;
   memadr, ioport, intL: LONGINT;
   (* ethernet card specific variables *)
   tx1, tx2, txQueue, lastTx: LONGINT;
   interrupt, tBusy, txIng, dmaIng, irqLock: BOOLEAN;
   txStartPage, rxStartPage, stopPage, curPage: LONGINT;
   rxErrors, rxLengthErrors, rxFifoErrors: LONGINT;
   rxPackets, rxBytes, rxDropped: LONGINT;
   rxFrameErrors, rxCrcErrors, rxMissedErrors, rxOverErrors: LONGINT;
   txPackets, txErrors, txBytes: LONGINT;
   multicast, collisions: LONGINT;
   txAbortedErrors, txCarrierErrors, txFifoErrors, txWindowErrors, txHeartbeatErrors: LONGINT;
   (* receive buffer *)
   bufhead, buftail: LONGINT;
   buf: ARRAY BufSize OF LONGINT;
  END;
  
  PCIDevice = POINTER TO PCIDeviceDesc;
  PCIDeviceDesc = RECORD (DeviceDesc)
   IoBaseAdr, MemBaseAdr, devId, vendId, cmd, status, revId, classCode, CLS, latTimer, hdrType,
   CIS, subId, subVenId, baseAdrROM: LONGINT;
   devIdx, busNr, devNr, fktNr: LONGINT;
   intP, minGnt, maxLat: LONGINT;
  END;
  
  E8390PktHdr = RECORD
   status, next: CHAR;
   count: INTEGER
  END;
  
 VAR
  Devs: ARRAY DevIDs OF Device;
  IDs: ARRAY DevIDs OF RECORD
   devId, vendId: LONGINT;
   desc: ARRAY 32 OF CHAR
  END;
  DevNum : LONGINT;
  Ints: SET; (* Interrupts *)
  intCounter: LONGINT;
  
  logging: BOOLEAN;
  log: Files.Rider;

 (* debug procedures *)
 
 PROCEDURE LogChar(ch: CHAR);
 BEGIN
  Kernel.WriteChar(ch)
 END LogChar;
 
 PROCEDURE LogString(s: ARRAY OF CHAR);
 BEGIN
  Kernel.WriteString(s)
 END LogString;

 PROCEDURE LogInt(i: LONGINT);
 BEGIN
  Kernel.WriteInt(i, 0)
 END LogInt;

 PROCEDURE LogHex(i: LONGINT);
 BEGIN
  Kernel.WriteHex(i, 0)
 END LogHex;
 
 PROCEDURE LogReal(x: LONGREAL);
 VAR a, b: LONGREAL; s: ARRAY 30 OF CHAR; i: LONGINT;
 BEGIN
  IF x < 0 THEN Kernel.WriteChar("-"); x := ABS(x) END;
  a := ENTIER(x); b := x - a; i := -1;
  REPEAT
   INC(i); s[i] := CHR(ENTIER(a) MOD 10 + ORD("0")); a := ENTIER(a / 10)
  UNTIL a = 0;
  WHILE i >= 0 DO Kernel.WriteChar(s[i]); DEC(i) END;
  Kernel.WriteChar(".");
  REPEAT
   b := b*10; Kernel.WriteChar(CHR(ENTIER(b) + ORD("0"))); b := b-ENTIER(b)
  UNTIL b = 0
 END LogReal;

 PROCEDURE LogLn;
 BEGIN
  Kernel.WriteLn
 END LogLn;
 
 PROCEDURE Read8(dev: Device; adr: LONGINT; VAR val: CHAR);
 BEGIN
  IF dev.memaccess THEN (* Memory mapped access *)
   SYSTEM.GET(adr + dev.memadr, val)
  ELSE (* IO based access *)
   SYSTEM.PORTIN(adr + dev.ioport, val)
  END
 END Read8;
 
 PROCEDURE Read32(dev: Device; adr: LONGINT; VAR val: LONGINT);
 VAR valc: CHAR;
 BEGIN
  IF dev.memaccess THEN (* Memory mapped access *)
   SYSTEM.GET(adr + dev.memadr, val)
  ELSE (* IO based access *)
(*   SYSTEM.PORTIN(adr + dev.ioport, val) *)
   SYSTEM.PORTIN(adr + dev.ioport, valc); val := LONG(ORD(valc));
   SYSTEM.PORTIN(adr + dev.ioport, valc); val := val + LONG(ORD(valc))*100H;
   SYSTEM.PORTIN(adr + dev.ioport, valc); val := val  + LONG(ORD(valc))*10000H;
   SYSTEM.PORTIN(adr + dev.ioport, valc); val := val + LONG(ORD(valc))*1000000H;
  END
 END Read32;
 
 PROCEDURE Write8(dev: Device; adr: LONGINT; val: CHAR);
 BEGIN
  IF dev.memaccess THEN (* Memory mapped access *)
   SYSTEM.PUT(adr + dev.memadr, val)
  ELSE (* IO based access *)
   SYSTEM.PORTOUT(adr + dev.ioport, val)
  END
 END Write8;
 
 PROCEDURE Write32(dev: Device; adr, val: LONGINT);
 BEGIN
  IF dev.memaccess THEN (* Memory mapped access *)
   SYSTEM.PUT(adr + dev.memadr, val)
  ELSE (* IO based access *)
(*   SYSTEM.PORTOUT(adr + dev.ioport, val) *)
   SYSTEM.PORTOUT(adr + dev.ioport, CHR(val)); val := val DIV 100H;
   SYSTEM.PORTOUT(adr + dev.ioport, CHR(val)); val := val DIV 100H;
   SYSTEM.PORTOUT(adr + dev.ioport, CHR(val)); val := val DIV 100H;
   SYSTEM.PORTOUT(adr + dev.ioport, CHR(val));
  END
 END Write32;
 
 PROCEDURE InitIDs;
 BEGIN
  IDs[0].devId := 8029H; IDs[0].vendId := 10ECH; IDs[0].desc := "RealTek RTL-8029";
  IDs[1].devId := 940H; IDs[1].vendId := 1050H; IDs[1].desc := "Winbond 89C940";
  IDs[2].devId := 1401H; IDs[2].vendId := 11F6H; IDs[2].desc := "Compex RL2000";
  IDs[3].devId := 3000H; IDs[3].vendId := 8E2EH; IDs[3].desc := "KTI ET32P2";
  IDs[4].devId := 5000H; IDs[4].vendId := 4A14H; IDs[4].desc := "NetVin NV5000SC";
  IDs[5].devId := 926H; IDs[5].vendId := 1106H; IDs[5].desc := "Via 86C926";
  IDs[6].devId := 0E34H; IDs[6].vendId := 10BDH; IDs[6].desc := "SureCom NE34";
  IDs[7].devId := 5A5AH; IDs[7].vendId := 1050H; IDs[7].desc := "Winbond";
  IDs[8].devId := 58H; IDs[8].vendId := 12C3H; IDs[8].desc := "Holtek HT80232";
  IDs[9].devId := 5598H; IDs[9].vendId := 12C3H; IDs[9].desc := "Holtek HT80229";
 END InitIDs;

 PROCEDURE PCIFindNetDevice(dev: PCIDevice): LONGINT;
 VAR res, res1, regVal: LONGINT;
 BEGIN
  res := PCI.FindPCIDevice(dev.devId, dev.vendId, dev.devIdx, dev.busNr, dev.devNr, dev.fktNr);
  IF devlistdebug THEN
   LogString("PCIFindNetDevice"); LogLn;
   LogString("   Device: "); LogHex(dev.devId); LogLn;
   LogString("   Vendor: "); LogHex(dev.vendId); LogLn;
   LogString("   Index: "); LogInt(dev.devIdx); LogLn;
   LogString("   res: "); LogHex(res); LogLn;
  END;
  
  IF res = PCI.Done THEN
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.CmdReg, regVal); ASSERT(res1 = PCI.Done, 100);
   dev.cmd := regVal MOD 10000H; dev.status := regVal DIV 10000H;
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.RevIdReg, regVal); ASSERT(res1 = PCI.Done, 101);
   dev.revId := regVal MOD 100H; dev.classCode := regVal DIV 100H;
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.CLSReg, regVal); ASSERT(res1 = PCI.Done, 102);
   dev.CLS := regVal MOD 100H; dev.latTimer := (regVal DIV 100H) MOD 100H;
   dev.hdrType := (regVal DIV 10000H) MOD 100H;
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.Adr0Reg, dev.IoBaseAdr); ASSERT(res1 = PCI.Done, 110);
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.Adr1Reg, dev.MemBaseAdr); ASSERT(res1 = PCI.Done, 111);
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.CISReg, dev.CIS); ASSERT(res1 = PCI.Done, 103);
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.SubvReg, regVal); ASSERT(res1 = PCI.Done, 104);
   dev.subVenId := regVal MOD 10000H; dev.subId := regVal DIV 10000H;
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.ROMReg, dev.baseAdrROM); ASSERT(res1 = PCI.Done, 105);
   res1 := PCI.ReadConfigDword(dev.busNr, dev.devNr, dev.fktNr, PCI.IntlReg, regVal); ASSERT(res1 = PCI.Done, 106);
   dev.intL := regVal MOD 100H; dev.intP := (regVal DIV 100H) MOD 100H;
   dev.minGnt := (regVal DIV 10000H) MOD 100H; dev.maxLat := (regVal DIV 1000000H);
   dev.ioport := dev.IoBaseAdr - 1; dev.memadr := dev.MemBaseAdr;
   dev.memaccess := FALSE;
   INCL(Ints, dev.intL) (* Ints = set der Interrupts *)
  END;
  RETURN res
 END PCIFindNetDevice;

 (* test whether last found device was already config'd by hand *)
 PROCEDURE ReplaceDevice(VAR Devices: ARRAY OF Device; VAR num: LONGINT);
 VAR i: LONGINT; dev: Device;
 BEGIN
  i := 0; dev := Devices[num];
  WHILE (i < num) & (Devices[i].ioport # dev.ioport) DO INC(i) END;
  IF i < num THEN
   ASSERT(Devices[i].intL = dev.intL, 100);
   Devices[i] := dev; DEC(num)
  END
 END ReplaceDevice;
 
 PROCEDURE BuildDeviceList(VAR Devices: ARRAY OF Device; VAR num: LONGINT);
 VAR i, j: LONGINT; dev, prevdev: PCIDevice;
 BEGIN
  i := 0; NEW(dev); Devices[num] := dev;
  WHILE i < DevIDs DO
   dev.devId := IDs[i].devId;
   dev.vendId := IDs[i].vendId;
   dev.devIdx := 0;
   WHILE (i < DevIDs) & (PCIFindNetDevice(dev) # PCI.DeviceNotFound) DO
    ReplaceDevice(Devices, num);
    INC(num); prevdev := dev; NEW(dev); Devices[num] := dev;
    dev.devIdx := prevdev.devIdx+1;
    dev.devId := prevdev.devId;
    dev.vendId := prevdev.vendId
   END;
   INC(i)
  END
 END BuildDeviceList; 
 
 PROCEDURE ShowDeviceList(VAR Devices: ARRAY OF Device; max: LONGINT);
 VAR i: LONGINT; d: Device;
 BEGIN
  LogLn; LogString("Show Device List and Details : "); LogLn;
  i := 0;
  WHILE i < max DO
   d := Devices[i];
   LogString("Device "); LogInt(i); LogLn;
   IF d IS PCIDevice THEN
    WITH d: PCIDevice DO
     LogString("   busNr: "); LogInt(d.busNr); LogLn;
     LogString("   devNr: "); LogInt(d.devNr); LogLn;
     LogString("   fktNr: "); LogInt(d.fktNr); LogLn;
     LogString("   devIdx: "); LogInt(d.devIdx); LogLn;
     LogString("   vendId: "); LogHex(d.vendId); LogLn;
     LogString("   devId: "); LogHex(d.devId); LogLn;
     LogString("   cmd: "); LogInt(d.cmd); LogLn;
     LogString("   status: "); LogInt(d.status); LogLn;
     LogString("   revId: "); LogInt(d.revId); LogLn;
     LogString("   classCode: "); LogInt(d.classCode); LogLn;
     LogString("   CLS: "); LogInt(d.CLS); LogLn;
     LogString("   latTimer: "); LogInt(d.latTimer); LogLn;
     LogString("   hdrType: "); LogInt(d.hdrType); LogLn;
     LogString("   IoBaseAdr: "); LogInt(d.IoBaseAdr); LogLn;
     LogString("   MemBaseAdr: "); LogInt(d.MemBaseAdr); LogLn;
     LogString("   CIS: "); LogInt(d.CIS); LogLn;
     LogString("   subId: "); LogInt(d.subId); LogLn;
     LogString("   subVenId: "); LogInt(d.subVenId); LogLn;
     LogString("   baseAdrROM: "); LogInt(d.baseAdrROM); LogLn;
     LogString("   Int Pin: "); LogInt(d.intP); LogLn;
     LogString("   Min Gnt: "); LogInt(d.minGnt); LogLn;
     LogString("   Max Lat: "); LogInt(d.maxLat); LogLn
    END
   END;
   LogString("   card access: ");
   IF d.memaccess THEN LogString("memory mapped") ELSE LogString("IO") END; LogLn;
   LogString("   IO port: "); LogHex(d.ioport); LogLn;
   LogString("   Mem adr: "); LogHex(d.memadr); LogLn;
   LogString("   Int Line: "); LogInt(d.intL); LogLn;
   INC(i)
  END;
 END ShowDeviceList;

(* 
 PROCEDURE TestMemory(dev: Device);
 VAR t, valli: LONGINT; val: CHAR; vali: INTEGER;
 BEGIN
  LogString("Test memory"); LogLn;
  Read8(dev, 0AH, val); LogString("   En0Isr: "); LogHex(ORD(val)); LogLn;
  Read8(dev, 0BH, val); LogString("   En0Isr: "); LogHex(ORD(val)); LogLn;
  LogString("    writing"); LogLn;
  Write8(dev, En0Dcfg, 48X);
  Write8(dev, En0Isr, CHR(EnIsrRdc));
  Write8(dev, En0RcntLo, 80X); Write8(dev, En0RcntHi, 0X);
  Write8(dev, En0RsarLo, 0X); Write8(dev, En0RsarHi, 40X); (* DMA starts at address 0 *)
  Write8(dev, E8390Cmd, CHR(E8390Rwrite+E8390Start));
  FOR t := 0 TO 7FH DO Write8(dev, E8390DataPort, CHR(t)) END;
  Read8(dev, En0Isr, val); LogString("   En0Isr: "); LogHex(ORD(val)); LogLn;
  Write8(dev, En0Isr, CHR(EnIsrRdc));
  LogString("    reading"); LogLn;
  Write8(dev, En0Dcfg, 49X);
  Write8(dev, En0RcntLo, 80X); Write8(dev, En0RcntHi, 0X);
  Write8(dev, En0RsarLo, 0X); Write8(dev, En0RsarHi, 40X); (* DMA starts at address 0 *)
  Write8(dev, E8390Cmd, CHR(E8390Rread+E8390Start));
  FOR t := 0 TO 1DH DO
(*   Read32(dev, E8390DataPort, valli); *)
   SYSTEM.PORTIN(dev.ioport + E8390DataPort, vali);
   LogString("   "); LogHex(vali); LogLn
   END;
  Read8(dev, En0Isr, val); LogString("   En0Isr: "); LogHex(ORD(val)); LogLn;
 END TestMemory;
*)
  
 PROCEDURE InitDevice(dev: Device);
 VAR val: CHAR; t: LONGINT; prom: ARRAY 32 OF CHAR;
 BEGIN
  (* reset receive buffer *)
  dev.bufhead := 0; dev.buftail := 0;
  
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Stop));
  (* Reset device *)
  Read8(dev, E8390Reset, val); Write8(dev, E8390Reset, val);
  t := Kernel.GetTimer() + 2000; (* 2 seconds *)
  REPEAT
   Read8(dev, En0Isr, val)
  UNTIL ODD(ORD(val) DIV EnIsrReset) OR (t < Kernel.GetTimer());
  Write8(dev, En0Isr, 0FFX); (* ack all interrupts *)
  
  (* initialize registers *)
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Stop)); (* select page 0 *)
  Write8(dev, En0Dcfg, 49X); (* word-wide access *)
  Write8(dev, En0RcntLo, 0X); Write8(dev, En0RcntHi, 0X); (* clear count regs *)
  Write8(dev, En0Imr, 0X); Write8(dev, En0Isr, 0FFX); (* disable and ack all interrupts *)
  Write8(dev, En0RxCr, CHR(E8390RxOff)); (* set to monitor *)
  Write8(dev, En0TxCr, CHR(E8390TxOff)); (* internal loopback mode *)
  
  (* read prom *)
  Write8(dev, En0RcntLo, 18X); Write8(dev, En0RcntHi, 0X);
  Write8(dev, En0RsarLo, 0X); Write8(dev, En0RsarHi, 0X); (* DMA starts at address 0 *)
  Write8(dev, E8390Cmd, CHR(E8390Rread+E8390Start));
  FOR t := 0 TO 11 DO Read8(dev, E8390DataPort, prom[t]) END;
  IF debug THEN
   Read8(dev, En0Isr, val); LogString("   En0Isr: "); LogHex(ORD(val)); LogLn;
   LogString("PROM content:"); LogLn;
   FOR t := 0 TO 31 DO LogString("     "); LogHex(ORD(prom[t])); LogLn END;
  END;
  
(*  IF debug THEN TestMemory(dev) END; *)
  
  Write8(dev, En0Dcfg, 48X); (* byte-wide access *)
  
  (* set transmit page and receive ring *)
  dev.txStartPage := StartPage;
  dev.rxStartPage := StartPage + TxPages;
  dev.stopPage := StopPage;
  dev.curPage := dev.rxStartPage;
  
  dev.tx1 := 0; dev.tx2 := 0; dev.txQueue := 0; dev.lastTx := -1;
  
  Write8(dev, En0TpSr, CHR(dev.txStartPage));
  Write8(dev, En0StartPg, CHR(dev.rxStartPage));
  Write8(dev, En0Boundary, CHR(dev.stopPage-1));
  Write8(dev, En0StopPg, CHR(dev.stopPage));
  
  (* read mac address from page1; this should automatically be set correctly *)
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page1+E8390Stop));
  FOR t := 0 TO 5 DO
   Write8(dev, E8390Cmd+t+1, prom[t]);
   Read8(dev, E8390Cmd+t+1, SYSTEM.VAL(CHAR, dev.hostAdr[t]));
   IF debug THEN LogHex(ORD(dev.hostAdr[t])); LogLn END
  END;
  
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page1+E8390Stop));
  Write8(dev, En1CurPag, CHR(dev.rxStartPage));
  
  dev.rxErrors := 0; dev.rxLengthErrors := 0; dev.rxFifoErrors := 0;
  dev.rxPackets := 0; dev.rxBytes := 0; dev.rxDropped := 0;
  dev.rxFrameErrors := 0; dev.rxCrcErrors := 0; dev.rxMissedErrors := 0; dev.rxOverErrors := 0;
  dev.txPackets := 0; dev.txErrors := 0; dev.txBytes := 0;
  dev.txAbortedErrors := 0; dev.txCarrierErrors := 0; dev.txFifoErrors := 0; dev.txWindowErrors := 0;
  dev.collisions := 0; dev.txHeartbeatErrors := 0;
  dev.multicast := 0;
  
  dev.tBusy := FALSE; dev.txIng := FALSE; dev.interrupt := FALSE;
  dev.dmaIng := FALSE; dev.irqLock := FALSE
 END InitDevice;
 
 PROCEDURE StartDevice(dev: Device);
 VAR i: LONGINT;
 BEGIN
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Stop));
  Write8(dev, En0Isr, 0FFX);
  Write8(dev, En0Imr, EnIsrAll);
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Start));
  Write8(dev, En0TxCr, CHR(E8390TxConfig));
  Write8(dev, En0RxCr, CHR(E8390RxConfig));
  (* set multicast filter to all; is this necessary? *)
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page1));
  FOR i := 0 TO 7 DO Write8(dev, En1Mult+i, 0FFX) END;
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0));
  Write8(dev, En0RxCr, CHR(E8390RxConfig)); (* hmm, why? *)
(*  IF debug THEN TestMemory(dev) END; *)
 END StartDevice;
 
 PROCEDURE Stop*;
 VAR i: INTEGER;
 BEGIN
  FOR i := 0 TO 31 DO
   IF i IN Ints THEN Kernel.RemoveIP(InterruptHandler, Kernel.IRQ+i) END
  END;
  Ints := {};
 END Stop;

 PROCEDURE GetInt(VAR s: ARRAY OF CHAR; VAR pos, val, res: LONGINT);
 VAR d, h, v: LONGINT; hex: BOOLEAN; ch: CHAR;
 BEGIN
  res := 0; d := 0; h := 0; hex := FALSE;
  ch := s[pos];
  WHILE (ch # 0X) & (ch # ",") & (res = 0) DO
   v := -1;
   IF (ch >= "0") & (ch <= "9") THEN v := ORD(ch)-ORD("0");
   ELSIF (CAP(ch) >= "A") & (CAP(ch) <= "F") THEN v := ORD(CAP(ch))-ORD("A")+10; hex := TRUE
   ELSIF CAP(ch) = "H" THEN hex := TRUE
   ELSE res := -1
   END;
   IF v # -1 THEN d := d*10+v; h := h*16+v END;
   INC(pos); ch := s[pos]
  END;
  IF hex THEN val := h ELSE val := d END;
 END GetInt;
 
 PROCEDURE GetInfo(VAR s: ARRAY OF CHAR; VAR port, irq, res: LONGINT);
 VAR i, d, h: LONGINT; hex: BOOLEAN;
 BEGIN
  i := 0; GetInt(s, i, port, res);
  IF res = 0 THEN
   IF s[i] = "," THEN INC(i); GetInt(s, i, irq, res)
   ELSE res := -2
   END
  END 
 END GetInfo;
 
 PROCEDURE GetConfigCards(VAR Devices: ARRAY OF Device; VAR num: LONGINT);
 VAR s, config: ARRAY 32 OF CHAR; n, port, irq, res: LONGINT; dev: Device;
 BEGIN
  config := ConfigStr; n := 0;
  Kernel.GetConfig(config, s);
  WHILE s[0] # 0X DO
   GetInfo(s, port, irq, res);
   IF res = 0 THEN
    NEW(dev); Devices[num] := dev; INC(num);
    dev.memaccess := FALSE; dev.ioport := port; dev.intL := irq;
    INCL(Ints, irq)
   END;
   INC(n); config[ConfigStrPos] := CHR(n + ORD("0"));
   Kernel.GetConfig(config, s)
  END 
 END GetConfigCards;

 
 PROCEDURE InitDriver;
 VAR 
  res, version, lastPCIbus, hwMech, dev: LONGINT; i: INTEGER;
 BEGIN
  intCounter := 0;
  DevNum := 0; ASSERT(Ints = {});
  IF ~debugIgnoreIsa THEN
   GetConfigCards(Devs, DevNum);
  END;
  res := PCI.PCIPresent(version, lastPCIbus, hwMech);
  IF res = PCI.Done THEN BuildDeviceList(Devs, DevNum) END;
  IF devlistdebug THEN ShowDeviceList(Devs, DevNum) END;
  dev := 0;
  WHILE dev < DevNum DO InitDevice(Devs[dev]); StartDevice(Devs[dev]); INC(dev) END;
  FOR i := 0 TO 31 DO
   IF i IN Ints THEN Kernel.InstallIP(InterruptHandler, Kernel.IRQ+i) END;
  END
 END InitDriver;  
 
 PROCEDURE BlockOutput(dev: Device; count: LONGINT; VAR buf: ARRAY OF LONGINT; startPage: LONGINT);
 VAR i: LONGINT; val: CHAR;
 BEGIN
  IF senddebug THEN
   LogString("Entering BlockOutput"); LogLn;
   LogString("   count: "); LogInt(count); LogLn;
   LogString("   startPage: "); LogHex(startPage); LogLn
  END;
  count := (count+3) DIV 4;
  ASSERT(~dev.dmaIng, 100);
  dev.dmaIng := TRUE;

  Write8(dev, E8390Cmd, CHR(E8390Page0+E8390Start+E8390NoDma));
  
  Write8(dev, En0Isr, CHR(EnIsrRdc));
  Write8(dev, En0RcntLo, CHR(count * 4));
  Write8(dev, En0RcntHi, CHR((count * 4) DIV 100H));
  Write8(dev, En0RsarLo, 0X);
  Write8(dev, En0RsarHi, CHR(startPage));
  Write8(dev, E8390Cmd, CHR(E8390Rwrite+E8390Start));
  
  IF senddebug THEN LogString("   Data sent:"); LogLn END;
  i := 0;
  WHILE i < count DO
   Write32(dev, E8390DataPort, buf[i]);
(*
   IF senddebug THEN LogString("   "); LogHex(buf[i]); LogLn END;
   IF senddebug THEN
    Read8(dev, En0Isr, val);
    LogString("   i: "); LogInt(i); LogString(", En0Isr: "); LogHex(ORD(val)); LogLn 
   END;
*)
   INC(i)
  END;

  IF senddebug THEN
   Read8(dev, En0Isr, val);
   LogString("   En0Isr: "); LogHex(ORD(val)); LogLn
  END;
  
  REPEAT Read8(dev, En0Isr, val) UNTIL ODD(ORD(val) DIV EnIsrRdc);

  IF senddebug THEN
   Read8(dev, En0Isr, val);
   LogString("   En0Isr: "); LogHex(ORD(val)); LogLn
  END;
  
  Write8(dev, En0Isr, CHR(EnIsrRdc));
  dev.dmaIng := FALSE;
  IF senddebug THEN LogString("Leaving BlockOutput"); LogLn END;
 END BlockOutput;
 
 (* Send - Send a packet.  Interrupts must be enabled. *)
 
 PROCEDURE Send(dev: NetBase.Device; prno: INTEGER; VAR dest: ARRAY OF SYSTEM.BYTE; item: NetBase.Item);
 VAR len, outputPage, t: LONGINT; data: ARRAY MaxPacketSize DIV 4 OF LONGINT; val: CHAR;
 BEGIN
  WITH dev: Device DO
   len := item.len;
   IF (len < 0) OR (len > 1500) THEN INC(dev.txErrors); RETURN END; (* packet too big *)
   SYSTEM.MOVE(SYSTEM.ADR(dest[0]), SYSTEM.ADR(data[0]), 6); (* set up sendhdr *)
   SYSTEM.MOVE(SYSTEM.ADR(dev.hostAdr[0]), SYSTEM.ADR(data[0])+6, 6);
   SYSTEM.PUT(SYSTEM.ADR(data[0])+12, SYSTEM.ROT(prno, 8));
   SYSTEM.MOVE(SYSTEM.ADR(item.data[item.ofs]), SYSTEM.ADR(data[0])+14, len);
   INC(len, 14);
   IF len < 60 THEN len := 60 END; (* some OS don't accept packets smaller than 60 bytes *)
   

   IF senddebug & dev.tBusy THEN
    Read8(dev, En0Isr, val);
    LogString("ISTAT: "); LogHex(ORD(val)); LogLn;
    Read8(dev, En0Tsr, val);
    LogString("   TSR: "); LogHex(ORD(val)); LogLn;
   END;
   WHILE dev.tBusy DO END;
   Write8(dev, En0Imr, 0X); (* mask interrupts *)
   ASSERT(~dev.interrupt, 100);
   dev.irqLock := TRUE;
   
   IF dev.tx1 = 0 THEN
    outputPage := dev.txStartPage;
    dev.tx1 := len
   ELSIF dev.tx2 = 0 THEN
    outputPage := dev.txStartPage + TxPages DIV 2;
    dev.tx2 := len
   ELSE HALT(101)
   END;
   
   BlockOutput(dev, len, data, outputPage);
   IF ~dev.txIng THEN
    IF senddebug THEN
     LogString("Send; Calling TriggerSend"); LogLn;
     LogString("   len: "); LogInt(len); LogLn;
     LogString("   outputPage: "); LogHex(outputPage); LogLn
    END;
    dev.txIng := TRUE;
    TriggerSend(dev, len, outputPage);
    IF outputPage = dev.txStartPage THEN dev.tx1 := -1; dev.lastTx := -1
    ELSE dev.tx2 := -1; dev.lastTx := -2
    END
   ELSE INC(dev.txQueue)
   END;
   dev.tBusy := (dev.tx1 # 0) & (dev.tx2 # 0);
   
   IF logging THEN
    t := Kernel.GetTimer();
    Files.WriteLInt(log, t DIV Kernel.TimeUnit);  
    Files.WriteLInt(log, ((t MOD Kernel.TimeUnit)*1000 DIV Kernel.TimeUnit)*1000+1);
    Files.WriteLInt(log, len+14);  Files.WriteLInt(log, len+14);
    Files.WriteBytes(log, data, len)
   END;
   
   dev.irqLock := FALSE;
   Write8(dev, En0Imr, EnIsrAll);
   INC(dev.txBytes, len)
  END
 END Send;

 (* Avail - Return TRUE iff a packet is available *)
 
 PROCEDURE Avail(dev: NetBase.Device): BOOLEAN;
 BEGIN
  WITH dev: Device DO
   RETURN dev.bufhead # dev.buftail
  END
 END Avail;
 
 (* Copy4 - Copy len dwords from src to dst. *)
 
 PROCEDURE Copy4(src, dst, len: LONGINT);
 CODE {SYSTEM.i386}
  MOV ESI, src[EBP]
  MOV EDI, dst[EBP]
  MOV ECX, len[EBP]
  CLD
  REP MOVSD
 END Copy4;
 
 (* Copy - Copy size bytes from source to dest.  (No overlap allowed) *)
 
 PROCEDURE Copy(source, dest, size: LONGINT);
 CODE {SYSTEM.i386}
  MOV ESI, source[EBP]
  MOV EDI, dest[EBP]
  MOV ECX, size[EBP]
  CLD
  CMP ECX, 8
  JB bytemove
  XOR EAX, EAX
  SHRD EAX, ESI, 2
  JZ copyd
  TEST EDI, 3
  JZ copyd
  SHRD EAX, EDI, 2
  SHR EAX, 28
  CMP AL, 10
  JZ mov2
  CMP AL, 5
  JZ mov3
  NOT AL
  AND AL, 5
  JNZ copyd
  MOVSB
  DEC ECX
  JMP copyd
 mov3:
  MOVSB
  DEC ECX
 mov2:
  MOVSW
  SUB ECX, 2
 copyd:
  SHRD EAX, ECX, 2
  SHR ECX, 2
  REP MOVSD
  SHLD ECX, EAX, 2
 bytemove:
  REP MOVSB
 END Copy;
 
 (* ReceivePacket - Remove a packet from the input buffer *)
 
 PROCEDURE Receive(dev: NetBase.Device;  VAR prno: INTEGER; VAR src: ARRAY OF SYSTEM.BYTE; VAR item: NetBase.Item);
 VAR len, size, left, dlen: INTEGER;  t: LONGINT; dbuf: ARRAY MaxPacketSize OF CHAR;
 BEGIN
  WITH dev: Device DO
   IF dev.bufhead # dev.buftail THEN
    size := SHORT(dev.buf[dev.bufhead] DIV 10000H);
    len := SHORT(dev.buf[dev.bufhead] MOD 10000H);
    SYSTEM.CLI();  INC(dev.bufhead);  IF dev.bufhead = BufSize THEN dev.bufhead := 0 END;  SYSTEM.STI();
    left := SHORT(BufSize - dev.bufhead);  dlen := len-14;
    IF size > left THEN (* split packet - double copy *)
      (* first move to dbuf & unsplit *)
     Copy4(SYSTEM.ADR(dev.buf[dev.bufhead]), SYSTEM.ADR(dbuf[0]), left);
     Copy4(SYSTEM.ADR(dev.buf[0]), SYSTEM.ADR(dbuf[left*4]), size-left);
      (* then move to buffer & split *)
     SYSTEM.MOVE(SYSTEM.ADR(dbuf[6]), SYSTEM.ADR(src[0]), 6); (* source address *)
     SYSTEM.GET(SYSTEM.ADR(dbuf[12]), prno);
     Copy(SYSTEM.ADR(dbuf[14]), SYSTEM.ADR(item.data[0]), dlen)
    ELSE (* ~split *)
     SYSTEM.MOVE(SYSTEM.ADR(dev.buf[dev.bufhead])+6, SYSTEM.ADR(src[0]), 6); (* source address *)
     SYSTEM.GET(SYSTEM.ADR(dev.buf[dev.bufhead])+12, prno);
     Copy(SYSTEM.ADR(dev.buf[dev.bufhead])+14, SYSTEM.ADR(item.data[0]), dlen)
    END;
    prno := SYSTEM.ROT(prno, 8);
    IF logging THEN
     t := Kernel.GetTimer();
     Files.WriteLInt(log, t DIV Kernel.TimeUnit);  
     Files.WriteLInt(log, ((t MOD Kernel.TimeUnit)*1000 DIV Kernel.TimeUnit)*1000+1);
     Files.WriteLInt(log, len);  Files.WriteLInt(log, len);
     IF size > left THEN Files.WriteBytes(log, dbuf, dlen+14)  (* split packet *)
     ELSE Files.WriteBytes(log, dev.buf[dev.bufhead], dlen+14)
     END
    END;
    SYSTEM.CLI();  dev.bufhead := (dev.bufhead+size) MOD BufSize;  SYSTEM.STI();
    item.len := dlen
   ELSE
    item.len := 0
   END
  END
 END Receive;

 PROCEDURE PrintStatistics(dev: Device);
 BEGIN
  LogString("Receive Statistics"); LogLn;
  LogString("   Packets: "); LogInt(dev.rxPackets); LogLn;
  LogString("   Bytes: "); LogInt(dev.rxBytes); LogLn;
  LogString("   dropped: "); LogInt(dev.rxDropped); LogLn;
  LogString("   Errors: "); LogInt(dev.rxErrors); LogLn;
  LogString("   Length Errors: "); LogInt(dev.rxLengthErrors); LogLn;
  LogString("   Fifo Errors: "); LogInt(dev.rxFifoErrors); LogLn;
  LogString("   Frame Errors: "); LogInt(dev.rxFrameErrors); LogLn;
  LogString("   CRC Errors: "); LogInt(dev.rxCrcErrors); LogLn;
  LogString("   missed Errors: "); LogInt(dev.rxMissedErrors); LogLn;
  LogString("   Overrun Errors: "); LogInt(dev.rxOverErrors); LogLn;
  LogString("Transmit Statistics"); LogLn;
  LogString("   Packets: "); LogInt(dev.txPackets); LogLn;
  LogString("   Bytes: "); LogInt(dev.txBytes); LogLn;
  LogString("   Errors: "); LogInt(dev.txErrors); LogLn;
  LogString("   Aborted Errors: "); LogInt(dev.txAbortedErrors); LogLn;
  LogString("   Carrier Errors: "); LogInt(dev.txCarrierErrors); LogLn;
  LogString("   Fifo Errors: "); LogInt(dev.txFifoErrors); LogLn;
  LogString("   Window Errors: "); LogInt(dev.txWindowErrors); LogLn;
  LogString("   Heartbeat Errors: "); LogInt(dev.txHeartbeatErrors); LogLn;
  LogString("Other Statistics"); LogLn;
  LogString("   Multicast: "); LogInt(dev.multicast); LogLn;
  LogString("   Collisions: "); LogInt(dev.collisions); LogLn;
  LogString("   Interrupts: "); LogInt(intCounter); LogLn
 END PrintStatistics;
 
 (** SetMode - Set receive mode (0-6) *)

 PROCEDURE SetMode*(device, mode: LONGINT);
 VAR f: Files.File; dev: Device;
 BEGIN
  IF device < DevNum THEN
   dev := Devs[device];
   CASE mode OF
    0: mode := E8390RxConfig (* normal mode *)
    |1: mode := E8390RxOff (* no packets, monitor mode *)
    |2: mode := 0H (* only packets to this interface, physical address mut match *)
    |3: mode := 4H (* mode 2 & broadcast *)
    |4: mode := 0CH (* mode 3 & limited multicast *)
    |5: mode := 0CH (* mode 3 and all multicast *)
    |6: mode := 1FH (* all packets accepted*)
    |-1: (* logging on *)
     IF ~logging THEN
      f := Files.New("EtherNet.Log");  Files.Set(log, f, 0); (* tcpdump compatible log file *)
      Files.WriteLInt(log, 0A1B2C3D4H);  Files.WriteInt(log, 2);
      Files.WriteInt(log, 4);  Files.WriteLInt(log, 0);  Files.WriteLInt(log, 0);
      Files.WriteLInt(log, MaxPacketSize);  Files.WriteLInt(log, 1);
      logging := TRUE
     END
    |-2: (* logging off *)
     IF logging THEN
      logging := FALSE;  Files.Register(Files.Base(log));  Files.Set(log, NIL, 0)
     END
    |-3: (* output statistics *)
     PrintStatistics(dev)
   END;
   IF mode >= 0 THEN Write8(dev, En0RxCr, CHR(mode)) END;
  END;
 END SetMode;

 (* InterruptHandler - Handle interrupts *)
 
 PROCEDURE TriggerSend(dev: Device; length, startPage: LONGINT);
 VAR val: CHAR;
 BEGIN
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0));
  Read8(dev, E8390Cmd, val);
  ASSERT(~ODD(ORD(val) DIV E8390Trans), 100);
  Write8(dev, En0TcntLo, CHR(length));
  Write8(dev, En0TcntHi, CHR(length DIV 256));
  Write8(dev, En0TpSr, CHR(startPage));
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Trans+E8390Start))
 END TriggerSend;
 
 PROCEDURE Get8390Hdr(dev: Device; VAR pktHdr: E8390PktHdr; ringPage: LONGINT);
 BEGIN
  ASSERT(~dev.dmaIng, 100);
  dev.dmaIng := TRUE;
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Start));
  Write8(dev, En0RcntLo, CHR(SIZE(E8390PktHdr))); ASSERT(SIZE(E8390PktHdr) = 4, 100);
  Write8(dev, En0RcntHi, 0X);
  Write8(dev, En0RsarLo, 0X);
  Write8(dev, En0RsarHi, CHR(ringPage));
  Write8(dev, E8390Cmd, CHR(E8390Rread+E8390Start));
  Read32(dev, E8390DataPort, SYSTEM.VAL(LONGINT, pktHdr));
  IF recdebug THEN
   LogString("   Get8390Hdr; status: "); LogHex(ORD(pktHdr.status)); LogLn;
   LogString("   Get8390Hdr; next: "); LogHex(ORD(pktHdr.next)); LogLn;
   LogString("   Get8390Hdr; count: "); LogHex(pktHdr.count); LogLn
  END;
  
  Write8(dev, En0Isr, CHR(EnIsrRdc));
  dev.dmaIng := FALSE
 END Get8390Hdr;
 
 PROCEDURE RxReceive(dev: Device);
 VAR
  rxPktCount, rxIngPage, thisFrame, nextFrame, currentOffset: LONGINT;
  numRxPages: LONGINT;
  pktLen, pktStat, pktNext: LONGINT;
  size: LONGINT;
  val: CHAR; 
  rxFrame: E8390PktHdr;
 BEGIN
  IF recdebug THEN LogString("Entering RxReceive"); LogLn END;
  IF recdebug THEN Read8(dev, En0Rsr, val); LogString("   En0Rsr: "); LogHex(ORD(val)); LogLn END;
  rxPktCount := 0; numRxPages := dev.stopPage - dev.rxStartPage;
  LOOP
   IF rxPktCount >= 10 THEN EXIT END;
   INC(rxPktCount);
   (* Get the rx page (incoming packet pointer). *)
   Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page1));
   Read8(dev, En1CurPag, val); rxIngPage := ORD(val);
   Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0));
   
   (* Remove one frame from the ring.  Boundary is always a page behind. *)
   Read8(dev, En0Boundary, val); thisFrame := ORD(val) + 1;
   IF thisFrame >= dev.stopPage THEN thisFrame := dev.rxStartPage END;
   ASSERT(thisFrame = dev.curPage, 100); (* if always true then remove previous and set thisFrame := dev.curPage *)
   
   IF recdebug THEN
    LogString("   thisFrame: "); LogHex(thisFrame); LogLn;
    LogString("   rxIngPage: "); LogHex(rxIngPage); LogLn;
   END;
   
   IF thisFrame = rxIngPage THEN EXIT END;
   
   currentOffset := thisFrame * 100H;
   Get8390Hdr(dev, rxFrame, thisFrame);
   pktLen := rxFrame.count - SIZE(E8390PktHdr);
   pktStat := ORD(rxFrame.status);
   pktNext := ORD(rxFrame.next);
   IF recdebug THEN
    LogString("   pktLen: "); LogInt(pktLen); LogLn;
    LogString("   pktStat: "); LogHex(pktStat); LogLn;
    LogString("   pktNext: "); LogHex(pktNext); LogLn
   END;
   nextFrame := thisFrame + 1 + ((pktLen+4) DIV 256);
   IF (pktNext # nextFrame) & (pktNext # nextFrame+1) & (pktNext # nextFrame - numRxPages) &
     (pktNext # nextFrame - numRxPages + 1) THEN
    IF recdebug THEN LogString("RxReceive; bogosity: check that!!!"); LogLn END;
    dev.curPage := rxIngPage;
    Write8(dev, En0Boundary, CHR(dev.curPage-1));
    INC(dev.rxErrors)
   ELSE
    IF (pktLen < MinPacketSize) OR (pktLen > MaxPacketSize) THEN
     IF recdebug THEN LogString("RxReceive; invalid packet size: "); LogInt(pktLen); LogLn END;
     INC(dev.rxErrors); INC(dev.rxLengthErrors)
    ELSIF pktStat MOD 10H = EnRsrRxOk THEN
     size := (pktLen+7) DIV 4; (* 2 bytes for len, 2 bytes for size, 3 bytes for Read32 padding *)
     IF size < (dev.bufhead - dev.buftail - 1) MOD BufSize THEN (* there is space *)
      DEC(size);
      dev.buf[dev.buftail] := size*10000H + pktLen;
      dev.buftail := (dev.buftail+1) MOD BufSize;
      ASSERT(~dev.dmaIng, 100);
      dev.dmaIng := TRUE;
      Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Start));
      Write8(dev, En0RcntLo, CHR(size*4));
      Write8(dev, En0RcntHi, CHR((size*4) DIV 100H));
      Write8(dev, En0RsarLo, CHR(currentOffset + SIZE(E8390PktHdr)));
      Write8(dev, En0RsarHi, CHR((currentOffset + SIZE(E8390PktHdr)) DIV 100H));
      Write8(dev, E8390Cmd, CHR(E8390Rread+E8390Start));
      WHILE size > 0 DO
       Read32(dev, E8390DataPort, dev.buf[dev.buftail]);
       IF recdebug THEN LogString("   "); LogHex(dev.buf[dev.buftail]); LogLn END;
       dev.buftail := (dev.buftail+1) MOD BufSize;
       DEC(size)
      END;
      Write8(dev, En0Isr, CHR(EnIsrRdc));
      dev.dmaIng := FALSE;
      INC(dev.rxPackets); INC(dev.rxBytes, pktLen);
      IF ODD(pktStat DIV EnRsrPhy) THEN INC(dev.multicast) END
     ELSE INC(dev.rxDropped)
     END
    ELSE
     IF recdebug THEN LogString("RxReceive; invalid packet status: "); LogInt(pktStat); LogLn END;
     INC(dev.rxErrors);
     IF ODD(pktStat DIV EnRsrFo) THEN INC(dev.rxFifoErrors) END
    END;
    nextFrame := pktNext;
    ASSERT(nextFrame < dev.stopPage, 101);
    dev.curPage := nextFrame;
    Write8(dev, En0Boundary, CHR(nextFrame-1))
   END
  END;
  Write8(dev, En0Isr, CHR(EnIsrRx+EnIsrRxErr));
  IF recdebug THEN LogString("Leaving RxReceive"); LogLn END;
 END RxReceive;
 
 PROCEDURE TxSend(dev: Device);
 VAR txstat: CHAR; txstati: LONGINT;
 BEGIN
  Read8(dev, En0Tsr, txstat);
  Write8(dev, En0Isr, CHR(EnIsrTx));

  DEC(dev.txQueue);
  IF dev.tx1 < 0 THEN
   dev.tx1 := 0; dev.tBusy := FALSE;
   IF dev.tx2 > 0 THEN
    dev.txIng := TRUE;
    TriggerSend(dev, dev.tx2, dev.txStartPage + (TxPages DIV 2));
    dev.tx2 := -1; dev.lastTx := 2
   ELSE dev.lastTx := 20; dev.txIng := FALSE
   END
  ELSIF dev.tx2 < 0 THEN
   dev.tx2 := 0; dev.tBusy := FALSE;
   IF dev.tx1 > 0 THEN
    dev.txIng := TRUE;
    TriggerSend(dev, dev.tx1, dev.txStartPage);
    dev.tx1 := -1; dev.lastTx := 1
   ELSE dev.lastTx := 10; dev.txIng := FALSE
   END
  END;
  
  txstati := ORD(txstat);
  IF ODD(txstati DIV EnTsrCol) THEN INC(dev.collisions) END;
  IF ODD(txstati DIV EnTsrPtx) THEN INC(dev.txPackets)
  ELSE
   INC(dev.txErrors);
   IF ODD(txstati DIV EnTsrAbt) THEN INC(dev.txAbortedErrors); INC(dev.collisions, 16) END;
   IF ODD(txstati DIV EnTsrCrs) THEN INC(dev.txCarrierErrors) END;
   IF ODD(txstati DIV EnTsrFu) THEN INC(dev.txFifoErrors) END;
   IF ODD(txstati DIV EnTsrCdh) THEN INC(dev.txHeartbeatErrors) END;
   IF ODD(txstati DIV EnTsrOwc) THEN INC(dev.txWindowErrors) END
  END;
 END TxSend;
 
 PROCEDURE RxOverrun(dev: Device);
 VAR mustResend, wasTxIng: BOOLEAN; t: LONGINT; val: CHAR;
 BEGIN
  mustResend := FALSE;
  Read8(dev, E8390Cmd, val);
  wasTxIng := ODD(ORD(val) DIV E8390Trans);
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Stop));
  
  IF recdebug THEN LogString("Receiver overrun"); LogLn END;
  INC(dev.rxOverErrors);
  
  (* wait 10 ms *)
  SYSTEM.STI();
  t := Kernel.GetTimer()+10;
  WHILE Kernel.GetTimer() < t DO END;
  SYSTEM.CLI();
  
  Write8(dev, En0RcntLo, 0X);
  Write8(dev, En0RcntHi, 0X);
  
  IF wasTxIng THEN
   Read8(dev, En0Isr, val);
   mustResend := ~ODD(ORD(val) DIV EnIsrTx) & ~ODD(ORD(val) DIV EnIsrTxErr)
  END;
  
  Write8(dev, En0TxCr, CHR(E8390TxOff));
  Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Start));

  RxReceive(dev);
  Write8(dev, En0Isr, CHR(EnIsrOver));
  
  Write8(dev, En0TxCr, CHR(E8390TxConfig));
  IF mustResend THEN Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Start+E8390Trans)) END
 END RxOverrun;
 
 PROCEDURE TxError(dev: Device);
 VAR txstat: CHAR; txstati: LONGINT;
 BEGIN
  Read8(dev, En0Tsr, txstat);
  txstati := ORD(txstat);
  Write8(dev, En0Isr, CHR(EnIsrTxErr));
  
  IF ODD(txstati DIV EnTsrAbt) OR ODD(txstati DIV EnTsrFu) THEN TxSend(dev)
  ELSE
   INC(dev.txErrors);
   IF ODD(txstati DIV EnTsrCrs) THEN INC(dev.txCarrierErrors) END;
   IF ODD(txstati DIV EnTsrCdh) THEN INC(dev.txHeartbeatErrors) END;
   IF ODD(txstati DIV EnTsrCrs) THEN INC(dev.txWindowErrors) END;
  END
 END TxError;

 PROCEDURE HandleCounters(dev: Device);
 VAR val: CHAR;
 BEGIN
  Read8(dev, En0Counter0, val); dev.rxFrameErrors := dev.rxFrameErrors + ORD(val);
  Read8(dev, En0Counter1, val); dev.rxCrcErrors := dev.rxCrcErrors + ORD(val);
  Read8(dev, En0Counter2, val); dev.rxMissedErrors := dev.rxMissedErrors + ORD(val);
  Write8(dev, En0Isr, CHR(EnIsrCounters))
 END HandleCounters;

 PROCEDURE InterruptHandler;
 VAR nr, device: LONGINT; dev: Device; istat, tsr: CHAR; istati: LONGINT;
 BEGIN
  IF intdebug THEN LogString("Entering InterruptHandler"); LogLn END;
  INC(intCounter);
  nr := 0; device := 0;
  WHILE device < DevNum DO
   dev := Devs[device];
   IF intdebug THEN LogString("Device nr: "); LogInt(device); LogLn; END;
   ASSERT(~dev.interrupt); dev.interrupt := TRUE;
   REPEAT
    Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0));
    Read8(dev, En0Isr, istat);
(*
    istati := ORD(istat);
    FOR i := 0 TO 7 DO
     Display.ReplConst(device+1, Display.Width-i*35-30, Display.Height DIV 2 - 15, 30, 10, Display.invert);
     IF ODD(istati) THEN Display.ReplConst(device+1, Display.Width-i*35-30, Display.Height DIV 2, 30, 30, Display.invert) END;
     istati := istati DIV 2
    END;
*)
    istati := ORD(istat);
    IF intdebug THEN LogInt(nr); LogString(" ISTAT: "); LogHex(ORD(istat)); LogLn; END;
    IF ODD(istati DIV EnIsrOver) THEN RxOverrun(dev)
    ELSIF ODD(istati DIV EnIsrRx) OR ODD(istati DIV EnIsrRxErr) THEN RxReceive(dev)
    END;
    IF intdebug THEN
     Read8(dev, En0Tsr, tsr);
     LogString("   TSR: "); LogHex(ORD(tsr)); LogLn;
     Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page3));
     Read8(dev, 3, tsr);
     LogString("   CONFIG0: "); LogHex(ORD(tsr)); LogLn;
     Read8(dev, 5, tsr);
     LogString("   CONFIG2: "); LogHex(ORD(tsr)); LogLn;
     Read8(dev, 6, tsr);
     LogString("   CONFIG3: "); LogHex(ORD(tsr)); LogLn;
     Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0));
    END;
    IF ODD(istati DIV EnIsrTx) THEN TxSend(dev)
    ELSIF ODD(istati DIV EnIsrTxErr) THEN TxError(dev)
    END;
    IF ODD(istati DIV EnIsrCounters) THEN HandleCounters(dev) END;
    IF ODD(istati DIV EnIsrRdc) THEN Write8(dev, En0Isr, CHR(EnIsrRdc)) END;
    Write8(dev, E8390Cmd, CHR(E8390NoDma+E8390Page0+E8390Start));
    INC(nr);
(*
    istati := ORD(istat);
    FOR i := 0 TO 7 DO
     Display.ReplConst(device+1, Display.Width-i*35-30, Display.Height DIV 2 - 15, 30, 10, Display.invert);
     IF ODD(istati) THEN Display.ReplConst(device+1, Display.Width-i*35-30, Display.Height DIV 2, 30, 30, Display.invert) END;
     istati := istati DIV 2
    END;
    istati := ORD(istat);
*)
   UNTIL istati = 0;
   dev.interrupt := FALSE;
   INC(device)
  END;
  IF intdebug THEN LogString("Leaving InterruptHandler"); LogLn; END;
 END InterruptHandler;

 (** InstallDevice - Command to install ethernet device.  Device name is parameter. *)
 
 PROCEDURE InstallDevice*; (* devname *)
 VAR i: SHORTINT; dev: Device;
 BEGIN
  InitDriver;
  dev := Devs[0];
  dev.typ := NetBase.broadcast;  dev.state := NetBase.closed;
  dev.sndCnt := 0;  dev.recCnt := 0;
  FOR i := 0 TO 5 DO dev.castAdr[i] := 0FFX END;
  dev.Receive := Receive;  dev.Send := Send;  dev.Available := Avail;
  NetBase.InstallDevice(dev)
 END InstallDevice;

(*====================================debug and test Procedures==========================*)

 PROCEDURE TestReceive*;
 VAR item : NetBase.Item; i, prno :INTEGER; from : ARRAY 6 OF CHAR; dev: Device;
 BEGIN
  dev := Devs[0];
  NEW(item);
  IF Avail(dev) THEN
   Receive(dev, prno, from, item);
   LogString("Packet from: ");
   FOR i := 0 TO 5 DO
    LogHex(ORD(from[i]));
   END;
   LogLn;
   LogString("Protokoll Number: ");
   LogHex(prno);
   LogLn;
   LogString("Packet Data: ");
   LogLn;
   FOR i := 0 TO 9 DO
    LogHex( ORD(item.data[i]));
   END;
   LogLn;  
   LogString("Laenge des Packets: ");
   LogInt(item.len);
   LogLn;
   
  ELSE
   LogString("Kein Paket erhaeltlich! ");
   LogLn;
  END;
 END TestReceive;

 
 PROCEDURE TestSend*;
 VAR item : NetBase.Item; i, j :LONGINT; dest : ARRAY 6 OF CHAR; dev: Device;
 BEGIN
  dev := Devs[0];
  Write8(dev, En0Dcfg, 42X);
  Write8(dev, En0TxCr, 3X); (* 0: normal; 2, 4, 6: loopback *)
  Write8(dev, En0RxCr, 1FX); (* accept all packets *)
  NEW(item);
  item.ofs := 0; item.len := 4;
  FOR j:=0 TO 0 DO
   FOR i := 0 TO 5 DO dest[i] := 0FFX END;
   dest[0]:= 0X; dest[1] := 0C0X; dest[2] := 26X; dest[3] := 0EEX; dest[4] := 3X; dest[5] := 0B6X;
 
   FOR i := 0 TO item.len-1 DO item.data[i] := CHR(i) END;
   item.data[0] := 020X; item.data[1] := 0ACX; item.data[2] := 0ECX; item.data[3] := 0BEX;
   item.data[50] := 0ECX; item.data[51] := 05X; item.data[52] := 0AEX; item.data[53] := 0A2X;
 
   (*check: previous send is over*)
   
   Send(dev, 9, dest, item);
  END;
 END TestSend;

 PROCEDURE ReadFifo*;
 VAR i: LONGINT; val: CHAR;
 BEGIN
  LogString("FIFO contents:"); LogLn;
  FOR i := 0 TO 7 DO
   Read8(Devs[0], 6, val);
   LogString("   "); LogHex(ORD(val)); LogLn
  END
 END ReadFifo;
 
 PROCEDURE TimeSend*;
 CONST N = 1000; Len = 1400; Ofs = 0;
 VAR t, i, j: LONGINT; item : NetBase.Item; dest : ARRAY 6 OF CHAR;   dev: Device;
 BEGIN
  dev := Devs[0];
  NEW(item);
  item.ofs := Ofs; item.len := Len;
  FOR i := 0 TO 5 DO dest[i] := 0FFX END;
  FOR i := 0 TO Len-1 DO item.data[Ofs+i] := CHR(i) END;
  FOR j := 0 TO 9 DO
   t := Kernel.GetTimer();
   FOR i := 0 TO N-1 DO Send(dev, 9, dest, item) END;
   t := Kernel.GetTimer()-t;
   
   LogInt(N); LogString(" packets sent. Avg. data rate: ");
   LogReal(1000*Kernel.TimeUnit*(Len+14)/t*8);
   LogString(" Bit/s"); LogLn
  END
 END TimeSend;

 PROCEDURE ShowAddress*;
 VAR i: LONGINT;
 BEGIN
  FOR i := 0 TO 5 DO
   LogHex(ORD(Devs[0].hostAdr[i]))
  END;
  LogLn;
 END ShowAddress;

 PROCEDURE ShowStatistics*;
 BEGIN
  PrintStatistics(Devs[0])
 END ShowStatistics;
 
(*========================= end of debug and test procedures ===============================*)

BEGIN
 logging := FALSE;
 Ints := {};
 Kernel.InstallTermHandler(Stop);
 intCounter := 0; 
 InitIDs;
END NetNe2000.
 
 SendTest:
 NetNe2000.InitDriver
 NetNe2000.InstallDevice 
 TestSuite.Timing 
 NetNe2000.TestSend      NetNe2000.ReadFifo
 NetNe2000.TestReceive
 NetNe2000.TimeSend
 
 NetNe2000.InstallDevice
 NetNe2000.ShowAddress    NetNe2000.ShowStatistics
 NetNe2000.Stop
 
 NetSystem.Stop
 NetSystem.Start
 
 System.Free
  FTPDocs 
  TelnetGadgets NetTools HyperDocs MIME TextStreams Streams BTrees NetNe2000
  NetSystem NetDNS NetTCP NetUDP NetPorts NetIP NetBase  ~
  
 telnet:pluto
 