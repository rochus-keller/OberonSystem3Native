(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE Adaptec71; (** prk  **)

(**
  driver for Adaptec 7xxx SCSI adapters. Currently only PCI adapters supported
  
  Based on the linux aic7xxx driver (Version = 5.1.15/3.2.4).
  
  Ported by Patrik Reali (reali@acm.org), 30.3.99
  
  Manual Driver Configuration (with kernel strings):
  -Ada7Config:
   01H: no drive disconnection
   02H: all devices are 8-bit / async
  
  -Ada7Debug: (print debug information)
   01H: Trace Calls
   02H: Trace Interrupts
   04H: Trace Messages
   08H: --
   10H: Trace Sequencer
   20H: Trace Resets
   40H: Trace Configuration
   80H: --
   100H: Trace SCSI Commands / SCBS
   200H: Trace Eeprom data
   400H: Trace Termination Information
  
  -Ada7ResetDelay:  reset delay in ms. Default = 1000
  
  -Ada7Hack: (override some values/configurations)
   (0) 01H: Force auto-termination configuration
  -Ada7ID: (override card id)
   for all cards! still testing
  
  
  open problems:
   Improve  ParseMessage
   Simplify initialisation, set goals always to max
   
   ResetHost: not needed, assume that bus has to be reset anyway!
  
  0.9.6:
  4.
   ConfigDevice: fix for EJZ, async device can nevertheless be ultra.
   ShowDevices: added
   FastEnable flag now TRUE (to test ShowDevices)
   Fix in ResetDevice: check only the allocated scb, not 255
   Fix in RunDoneQueue: only to allocated-1 (off by 1)
   Fix in TransferMessage: inc(len) before Done, otherwise message phase doesn't terminate 
   
   Simplify Sync/Width negotiation
    Done: no scheduling of negotiation after Inquiry
    ConfigDevice: schedule negotiation (width already there!)
   
   New Width/Synch handling strategy:
    * ConfigDevice: set current/goal/need
    * Execute: schedule, clear need
    * Reset: clear current / set need
    * MsgAccept: set current
    * MsgReject: set goal
    
  3.
   Trace termination information
   Simplify tracing, remove variables
   
  2.
   AscsiSelto, AscsiPErr, AscsiUnknown, AscsiBusFree, AscsiReset added
   
  1.
   Trace bus state
   FastEnable flag (to allow width/sync negotiation)
   Debug counters
   Bug in InterruptCmdComplete: status/result where inverted!
   
   further cleanups, reordering of procedures
   
   remove tagged/ordered queues
   remove scb.tagAction (used only for tagged queues)
   remove QueueDepth, QueueFull
   
   * remove wait / delayed
    * ResetDevice, very complicated!
   
   * timers removed, just fail!
   * scb.tag removed, it's just same as index
   
  0.9.5: (in progress)
   simplifying SyncRate structure and use (now RateTable)
   better debug output.
   TraceBeta: new features are always traced
*)

(*
  Improve:
   ResetChip: move out the config stuff (but only after implementing the VL cards)
   LoadSeeprom: move out the config stuff
  
   * find cards on the VL/EISA and initialize all the other params, ev. detect special features
   * ensure that the class of an SCB (queue is in) correspond to the state.
   
   * what about the timer?
    -> jiffies, TimerTimeout, HZ
   
   * check for newer Linux versions:
    -> InterruptScsi, SELTO with invalid Waiting SCB. Now uses an "emergency" solution". Must be improved

Understanding the driver:

 Each host has:
  255 hwscb: scsi control block, a command to the sequencer, 255 (FFx) is NIL
  --- scb: driver infos about the command executed by the hwscb
  
 commands can be in the following states:
 * free (not in use)
 * disconnected (command send, waiting for reconnection when device has data)
 * delayed (cannot be run now)
 * waiting (to be queued, not sent to the sequencer)
 * queued
 
 the sequencer has the following queues (first element, chaining through the next field):
 * free
 * disconnected
 * waiting
 the host has also these queues, but must keep them up-to-date!
 
 * infifo: ?
 * outfifo: ?
 
 Width/Period simplification:
 * curX : current width period
 * goalX: wished period
 * needX: need to trasmit it by the next message
 * pendingX: in trasmission, awaiting response
*)

IMPORT
 SCSI := SCSI1, Script := Adaptec7Script, Kernel, SYSTEM, PCI;
 
CONST
  (*Debug Configuration*)
 DebugNoWrites = FALSE; (* never write to registers *)
 TraceBeta = FALSE; (* trace new features (betas) *)
 
  (*Unimplemented Trap*)
 Unimplemented = 0DAH;
 
  (*Host.chip: enumeration  ProgTools.Enum 1 AIC7770 AIC7850 AIC7860 AIC7870 AIC7880 AIC7890 AIC7895 AIC7896 ~ *)
 AIC7770 = 1; AIC7850 = 2; AIC7860 = 3; AIC7870 = 4; AIC7880 = 5; AIC7890 = 6; 
 AIC7895 = 7; AIC7896 = 8; 

  (*Host.feature  ProgTools.Enum 1 FeatUltra  FeatUltra2  FeatWide  FeatTwin FeatMoreSRAM  FeatCmdChan
   FeatQueueRegs  FeatSGPreload FeatSpioCap ~ *)
 FeatUltra = 1; FeatUltra2 = 2; FeatWide = 3; FeatTwin = 4; FeatMoreSRAM = 5; FeatCmdChan = 6; 
 FeatQueueRegs = 7; FeatSGPreload = 8; FeatSpioCap = 9; 
 
  (*Host.flag ProgTools.Enum 1
   FlagPageSCB FlagNewEepromFMT FlagBiosEnabled FlagMultiChannel FlagChnlB FlagChnlC
   FlagSeepromFound FlagChannelBPrimary FlagExtendTransA FlagExternalSRam FlagAbortPending FlagHandlingReqInits ~ *)
 FlagPageSCB = 1; FlagNewEepromFMT = 2; FlagBiosEnabled = 3; FlagMultiChannel = 4; FlagChnlB = 5; FlagChnlC = 6; 
 FlagSeepromFound = 7; FlagChannelBPrimary = 8; FlagExtendTransA = 9; FlagExternalSRam = 10; FlagAbortPending = 11; 
 FlagHandlingReqInits = 12; 

 
  (*Host.epromType: the number is also the word size of the eprom*)
 C46 = 6;  C56 = 8;
 
  (* Offsets and Periods *)
 MaxOffsetUltra2 = 7FH;
 MaxOffset16Bit = 08H;
 MaxOffset8Bit = 0FH;
 HostMsg = 0FFH;
 
  (*HSCB Control *)
 HwScbTypeMask = 03X; HwScbMsgMask = 0F6X;
 HwScbDisconnected = 3; HwScbDiscEnable = 6; HwScbMessage = 7;
 
  (*SCB Flags ProgTools.Enum 8 ScbFree ScbWaitingQ ScbActive ScbSense ScbAbort ScbDeviceReset ScbReset ScbRecovery ScbWasBusy  
   ScbMsgSent ScbMsgWidth ScbMsgSync ScbQueuedAbort ScbQueuedForDone ~ *)
 ScbFree = 8; ScbWaitingQ = 9; ScbActive = 10; ScbAbort = 12; ScbDeviceReset = 13; 
 ScbReset = 14; ScbRecovery = 15; ScbWasBusy = 16; ScbMsgSent = 17; ScbMsgWidth = 18; ScbMsgSync = 19; 
 ScbQueuedAbort = 20; ScbQueuedForDone = 21; 
 ScbMsgMask = {ScbMsgSent, ScbMsgWidth, ScbMsgSync};
 
  (*Device Flags ProgTools.Enum 0
  DevicePresent DeviceBusResetPending DeviceTimeout DeviceSuccess DeviceTaggedSuccess DeviceScanned ~ *)
 DevicePresent = 0; DeviceBusResetPending = 1; DeviceTimeout = 2; DeviceSuccess = 5; 
 DeviceScanned = 7; 

  (*Msg Types*)
 MsgTypeNone = 0; MsgTypeInitiatorMsgOut = 1; MsgTypeInitiatorMsgIn = 2;
 
  (*MachScb special parameters*)
 AllTargets = -1; AllChannels = -1; AllLuns = -1;
 
  (*SetWidth / SetSyncRate special flags*)
 TransActive = 0; TransCur = 1; TransGoal = 2;
 
   (*Host.termination Termination flags ProgTools.Enum 1 TermA TermB TermSELow TermSEHigh ~ *)
 TermAuto = 16; TermS = 19; TermSW = 20; TermSEAuto =26; TermSLvd = 27; (*dont change! same values as in BIOS*)

 TermA = 1; TermB = 2; TermSELow = 3; TermSEHigh = 4; 
 
 
(*SCSI Register Block *)
 (* 00H SCSI Sequence Control *) SCSISEQ = 00H;
  (* Bit 0 SCSI Reset Out *)  SCSIRSTO = 0;
  (* Bit 1 Enable Auto ATN on parity *)  ENAUTOATNP = 1;
  (* Bit 4 Enable Reselection *)  ENRSELI = 4;
  (* Bit 5 Enable Selection in *)  ENSELI = 5;
  (* Bit 6 Enable Selection out *)  ENSELO = 6;
 (* 01H SCSI Transfer Control 0 Register *) SXFRCTL0 = 01H;
  (* Bit 3 SCSI PIO Enable *)  SPIOEN = 3;
  (* Bit 5 *)  FAST20 = 5;
  (* Bit 7 Digital Filtering On *)  DFON = 7;
 (* 02H SCSI Transfer Control 1 Register *) SXFRCTL1 = 02H;
  (* Bit 0 SCSI Termination Power Enable *)  STPWEN = 0;
  (* Bit 1 Active Negation Enable *)  ACTNEGEN = 1;
  (* Bit 2 Enable Selection timeout *)  ENSTIMER = 2;
  (* Bit 5 Enable Parity Check *)  ENSPCHK = 5;
 (* 03H SCSI Control Signal *) SCSISIG = 03H;
  (* Bit 0 Ack *)  ACK = 0;
  (* Bit 1 *)  REQ = 1;
  (* Bit 2 *)  BSY = 2;
  (* Bit 3 *)  SEL = 3;
  (* Bit 4 *)  ATN = 4;
  (* Bit 5 *)  MSG = 5;
  (* Bit 6 *)  IO = 6;
  (* Bit 7 *)  CD = 7;
 (* 04H SCSI Rate Control *) SCSIRATE = 04H;
  (* Bit 7 Wide Transer control *)  WIDEXFER = 7;
 (* 05H SCSI ID *) SCSIID = 05H;
     SCSIOFFSET = 05H;
 (* 06H SCSI Data Low *) SCSIDATL = 06H;
 (* 0BH SCSI Status 0 *) SSTAT0 = 0BH;
 (* 0BH Clear SCSI Interrupt 0 *) CLRSINT0 = 0BH;
  (* Bit 1 CLRSPIORDY *)  CLRSPIORDY = 1;
  (* Bit 3 CLRSWRAP *)  CLRSWRAP = 3;
  (* Bit 4 CLRSELINGO *)  CLRSELINGO = 4;
  (* Bit 5 CLRSELDI *)  CLRSELDI = 5;
  (* Bit 6 CLRSELDO *)  CLRSELDO = 6;
 (* 0CH SCSI Status 1 *) SSTAT1 = 0CH;
  (* Bit 0 *)  REQINIT = 0;
  (* Bit 2 SCSI Parity Error *)  SCSIPERR = 2;
  (* Bit 3 Bus Free Flag *)  BUSFREE = 3;
  (* Bit 5 Scsi Reset *)  SCSIRSTI = 5;
  (* Bit 7 Selection Time Out *)  SELTO = 7;
 (* 0CH Clear SCSI Interrupt 1 *) CLRSINT1 = 0CH;
  (* Bit 0 CLRREQINIT *)  CLRREQINIT = 0;
  (* Bit 1 CLRPHASECHG *)  CLRPHASECHG = 1;
  (* Bit 2 CLRSCSIPERR *)  CLRSCSIPERR = 2;
  (* Bit 3 CLRBUSFREE *)  CLRBUSFREE = 3;
  (* Bit 5 CLRSCSIRSTI *)  CLRSCSIRSTI = 5;
  (* Bit 6 CLRATNO *)  CLRATNO = 6;
  (* Bit 7 CLRSELTIMEO *)  CLRSELTIMEO = 7;
      CLRSINT1ALL = {0..3, 5..7};
 (* 0DH SCSI Status 2 *) SSTAT2 = 0DH;
  (* Bit 4 SCSI Expander Active *)  EXPACTIVE = 4;
 (* 0FH SCSI ID for Ultra2 Chips *) SCSIIDULTRA2 = 0FH;
 (* 10H SCSI Interrupt Mode 0 *) SIMODE0 = 10H;
  
 (* 11H SCSI Interrupt Mode 1 *) SIMODE1 = 11H;
  (* Bit 1 Enable ReqInit *)  ENREQINIT = 1;
  (* Bit 2 Enable Scsi Parity Error *)  ENSCSIPERR = 2;
  (* Bit 3 Enable Bus Free *)  ENBUSFREE = 3;
  (* Bit 5 Enable Scsi Reset *)  ENSCSIRST = 5;
  (* Bit 7 Enable Time-out *)  ENSELTIMO = 7;
 (* 12H SCSI Bus Low *) SCSIBUSL = 12H;
 (* 1BH Serial Port I/O Cabability register *) SPIOCAP = 1BH;
  (* Bit 0  Termination and cable detection *)  SSPIOCPS = 0;
 (* 1DH Board Control *) BRDCTL = 1DH;
  (* Bit 0 7890 only: Board Strobe *)  BRDSTBULTRA2 = 0;
  (* Bit 1 7890 only: Board Read/Write *)  BRDRWULTRA2 = 1;
  (* Bit 2 Board Read/Write *)  BRDRW = 2;
  (* Bit 3 Board Chip Select *)  BRDCS = 3;
  (* Bit 4 Board Strobe *)  BRDSTB = 4;
 (* 1EH Serial EEPROM Control *) SEECTL = 1EH;
  (* Bit 0 Serial EEPROM Data In *)  SEEDI = 0;
  (* Bit 1 Serial EEPROM Data Out *)  SEEDO = 1;
  (* Bit 2 Serial EEPROM Clock *)  SEECK = 2;
  (* Bit 3 Serial EEPROM Chip Select *)  SEECS = 3;
  (* Bit 4 Serial EEPROM Ready *)  SEERDY = 4;
  (* Bit 5 Serial EEPROM Mode Select *)  SEEMS = 5;
 (* 1FH SCSI Block Control *) SBLKCTL = 1FH;
  (* Bit 1 Select Wide *)  SELWIDE = 1;
  (* Bit 3 SELBUSB *)  SELBUSB = 3;
  (* Bit 3 LVD transceiver active *)  ENAB40 = 3;
  (* Bit 5 Auto Flush Disable *)  AUTOFLUSHDIS = 5;
  (* Bit 6 Diagnostic LED on *)  DIAGLEDON = 6;
  (* Bit 7 Diagnostic LED Enable *)  DIAGLEDEN =7;

(* Scratch RAM *)
 (* 20H 1 byte per target starting at this address for configuration values*) TARGSCSIRATE = 20H;
 (* 30H Bit vector of targets that have ULTRA enabled. *) ULTRAENB = 30H;
  (* 32H  Bit vector of targets that have disconnection disabled*) DISCDSB = 32H;
  (* 34H buffer to designate the type or message to send to a target*) MSGOUT = 34H;
  (* 35H Parameters for DMA Logic*) DMAPARAMS = 35H;
  (* 36H *)  SEQFLAGS = 36H;
  (* 37H SAVED_TCL*) SAVEDTCL = 37H;
  (* 38H SG_COUNT*)
  (* 39H SG_NEXT*)
  (* 3DH LASTPHASE*) LASTPHASE = 3DH;
   (* Signals are declared in SCSISIG *)  PHASEMASK = {CD, MSG, IO};
   (* Patterns*)
   PhaseStatus = {CD, IO};
   PhaseCommand = {CD};
   PhaseMsgOut = {CD, MSG};
   PhaseMsgIn = {CD, MSG, IO};
   PhaseDataIn = {IO};
   PhaseDataOut = {};
   PhaseBusFree = {0};
  (* 3EH WAITINGSCBH*) WAITINGSCBH = 3EH;
  (* 3FH DISCONNECTEDSCBH*) DISCONNECTEDSCBH = 3FH;
  (* 40H head of list of SCBs that are not in use.  Used for SCB paging*) FREESCBH = 40H;
  (* 41H HSCB_ADDR*) HSCBARRAY = 41H;
  (* 45H SCBID_ADDR*) SCBIDADDR = 45H;
  (* 49H TMODE_CMDADDR*) TMODECMDADDR = 49H;
  (* 4DH KERNEL_QINPOS*) KERNELQINPOS = 4DH;
  (* 4EH QINPOS*) QINPOS = 4EH;
  (* 4FH QOUTPOS*) QOUTPOS = 4FH;
  (* 50H TMODE_CMDADDR_NEXT*) TMODECMDADDRNEXT = 50H;
  (* 51H ARG_1 / RETURN_1*) RETURN1 = 51H;
   (* Phase Mismatch *)  MSGOUTPHASEMIS = {4};
   (*  Send Sense *)  SENDSENSE = {6};
   (*  Send Msg *)  SENDMSG = {7};
  (* 52H ARG_2 *)
  (* 53H LAST_MSG*) LASTMSG = 53H;
  (* 54H PREFETCH_CNT*)
  
 (* 5AH Scsi Configuration *) SCSICONF = 5AH;
  (* Bit 6 Reset SCSI-Bus at boot *)  RESETSCSI = 6;
  (* Bit 7 Termination Enable *)  TERMENB = 7;
 (* 60H Sequencer Control *) SEQCTL = 60H;
  (* Bit 0 Load Ram *)  LOADRAM = 0;
  (* Bit 1 Reset *)  SEQRESET = 1;
  (* Bit 4 Fast Mode *)  FASTMODE = 4;
  (* Bit 5 Fail disable *)  FAILDIS = 5;
  (* Bit 7 Parity Error disable *)  PERRORDIS = 7;
 (* 61H Sequencer RAM Data *) SEQRAM = 61H;
 (* 62H Sequencer Address Registers *) SEQADDR0 = 62H;
 (* 63H *)  SEQADDR1 = 63H;
 (* 65H *)  SINDEX = 65H;
(* Sequencer (SCSI Phase Engine)*)
 (* 70H 1 byte per target SCSI offset values for Ultra2 controllers *) TARGOFFSET = 70H;
(* Host Registers*)
 (* 84H Board Control*) BCTL = 84H;
  (* Bit 0  Enable *)  ENABLE = 0;
 (* 84H Device Space Command*) DSCOMMAND0 = 84H;
  (* Bit 0 *)  CIOPARCKEN = 0;
  (* bit 1 *)  USCBSIZE32 = 1;
  (* Bit 5 Memory Parity Check Enable *)  MPARCKEN = 5;
  (* Bit 6 Data Parity Check Enable *)  DPARCKEN = 6;
  (* Bit 7 Cache Threshold Enable *)  CACHETHEN = 7;
 (* 86H DSPCI Status *) DSPCISTATUS = 86H;
  (* Read when 100% empty, write when 100% full *)  DFTHRSH100 = {6, 7};
 (* 87H Host Control, Overall host control of the device*) HCNTRL = 87H;
  (* Bit 0 Chip Reset / Chip Reset Acknowledge *)  CHIPRST = 0;
  (* Bit 1 Interrupt Enable *)  INTEN = 1;
  (* Bit 2 Pause Enable *)  PAUSE = 2;
 (* 90H Gate one of the four SCBs into the SCBARRAY window*) SCBPTR = 90H;
 (* 91H Interrupt Status *) INTSTAT = 91H;
  (* Bit 0 Sequencer Interrupt *)  SEQINT = 0H;
  (* Bit 1 Command Completed *)  CMDCMPLT = 1H;
  (* Bit 2 Scsi Interrupt *)  SCSIINT = 2H;
  (* Bit 3 Break address *)  BRKADRINT = 3H;
  (* Sequencer Interrupt Mask *)  SEQINTMASK = {0, 4..7};
  (* Interrupt Values*)
   DataOverrun = 0EH; MsgInPhaseMis = 0DH; TracePoint2 = 0CH;
   TracePoint = 0BH; AwaitingMsg = 0AH; Residual = 08H;
   BadStatus = 07H; RejectMsg = 06H; AbortRequested = 05H;
   ExtendedMsg = 04H; NoMatch = 03H; NoIdent = 02H;
   SendReject = 01H; BadPhase = 00H;
 (* 92H Write: Clear Interrupt Status *) CLRINT = 92H;
  (* Bit 0 Clear Sequencer Interrupt *)  CLRSEQINT = 0;
  (* Bit 1 Clear Command Complete Interrupt *)  CLRCMDINT = 1;
  (* Bit 2 Clear SCSI Interrupt *)  CLRSCSIINT = 2;
  (* Bit 3 Clear Break Address Interrupt *)  CLRBRKADRINT = 3;
  (* Bit 4 Clear Parity Errors*)  CLRPARERR = 4;
 (* 92H Read: Hard Error *) ERROR = 92H;
  (* Bit 0 Illegal Hardware Address *)  ILLHADDR = 0;
  (* Bit 1 Illegal Software Address *)  ILLSADDR = 1;
  (* Bit 2 Illegal Opcode Error *)  ILLOPCODE = 2;
  (* Bit 3 Sequencer Parity Error *)  SQPARERR = 3;
  (* Bit 6 Pci error *)  PCIERRSTAT = 6;
  
(* SCB Definition: this field give direct access to the scb pointed by SCBPTR*)
 (* A0H SCB Control *) SCBCONTROL = 0A0H;
  (* Bit 3 Disconnected*)  DISCONNECTED = 3;
  (* Bit 6 Disconnect Enabled*)  DISCENB = 6;
 (* A1H *)  SCBTCL = 0A1H;
 (* A2H Target Status *) SCBTARGETSTATUS = 0A2H;
 (* A3H SG / Count *) SCBSGCOUNT = 0A3H;
 (* A4H SG / Ptr *) SCBSGPTR = 0A4H;
 (* A8H *)  SCBRESIDSGCNT = 0A8H;
 (* A9H *)  SCBRESIDDCNT = 0A9H;
 (* ACH *)  SCBDATAPTR = 0ACH;
 (* B0H *)  SCBDATACNT = 0B0H;
 (* B4H *)  SCBCMDPTR = 0B4H;
 (* B8H *)  SCBCMDLEN = 0B8H;
 (* B9H *)  SCBTAG = 0B9H;
 (* BAH *)  SCBNEXT = 0BAH;
 (* BBH *)  SCBPREV = 0BBH;
 (* BCH *)  SCBBUSYTARGETS = 0BCH;
  
 (* F0H CCSCBBADDR, 7895/6/7 only *) CCSCBBADDR = 0F0H;
 (* F4H Host New SCB Queue Offset *) HNSCBQOFF = 0F4H;
 (* F6H Sequencer New SCB Queue Offset *) SNSCBQOFF = 0F6H;
 (* F8H Sequencer Done SCB Queue Offset *) SDSCBQOFF = 0F8H;
 (* FAH Queue Offset Control & Status *) QOFFCTLSTA = 0FAH;
  (* Queue size = 256 *)  SCBQSIZE256 = {1, 2};
 (* FBH Data FIFO Threshold *) DFFTHRSH = 0FFH;
  (* Write starts when 75% full *)  WRDFFTHRSH75 = {6};
  (* Read starts when 75% empty *)  RDDFFTHRSH75 = {2};

(*PCI Registers*)
 (* 40H Device Configuration *) DEVCONFIG = 40H;
  (* Bit 2 RAMPSM_ULTRA2 7895/6 only? *)  RAMPSMULTRA2 = 2;
  (* Bit 3 Byte Parity Error Enable *)  BERREN = 3;
  (* Bit 3 SCBRAMSELULTRA2??? *)  SCBRAMSELULTRA2 = 3;
  (* Bit 4 External SCB Parity Enable *)  EXTSCBPEN = 4;
  (* Bit 7 SCB RAM Select,  not 7890 *)  SCBRAMSEL = 7;
  (* Bit 9 RAM Present Mode *)  RAMPSM = 9;
  (* Bit 16 SCBSIZE32, 7895 only? *)  SCBSIZE32 = 16;
  (* Bit 31 PCI Error Generation Disable *)  PCIERRGENDIS = 31;
 
  SCAMCTL = 1AH;   (*ultra2 only*)
 
 
 MaxScb = 255; (*DON'T FORGET TO CHANGE THE SCB MASK IN THE SEQUENCER CODE IF THIS IS MODIFIED!*)
 MaxTargets = 16;
 
 ScbNull = 0FFX;  ScbNullSet = {0..15} (*=SYSTEM.VAL(SET, ScbNull)*);
  
TYPE
  (*helper structures*)
 BigSet = ARRAY 256 DIV 32 OF SET;  (* set with 256 elements*)

  (*SCSI Command. Used to communicate with the rest of the world*)
  (* Hardware SCB. This is the format used by the host card sequencer. 
   It's used to communicate between the driver and the sequencer.
   WARNING: avoid alignment of the fields
  *)
 long = LONGINT; (* If the long fields are not aligned use ARRAY 4 OF CHAR *)
 HwScbDesc =  RECORD (*aic7xxx_hwscb*)
  (* 0 *) control, 
  (* 1 *) targ, 
  (* 2 *) status, 
  (* 3 *) SGcnt: CHAR;
  (* 4 *) SGptr: long;
  (* 8 *) resSGcnt: CHAR;
  (* 9 *) resDataCnt: ARRAY 3 OF CHAR;
  (* 12 *) dataPtr: long;
  (* 16 *) dataCnt: long;
  (* 20 *) cmdPtr: long;
  (* 24 *) cmdLen: CHAR;
  (* 25 *) tag,
  (* 26 *) next,
  (* 27 *) prev: CHAR;
  (* 28 *) par: long;
 END;
 
 ScbData = POINTER TO RECORD
  flags: SET;
  next: ScbData; (* used for the queues *)
  cmd: RECORD target, chan, lun, status, result: SHORTINT; cmd, data, ptrToCmd: LONGINT END;(*Copy of Cmd relevant fields*)
 END (*ScbDataDesc*);
 
 
 Host = POINTER TO HostDesc;
 Put1Proc = PROCEDURE (d: Host; offset: LONGINT; val: SET);
 Get1Proc = PROCEDURE (d: Host; offset: LONGINT): SET;

 DeviceDesc = RECORD
  curOffset, curPeriod, goalOffset, goalPeriod: LONGINT;
  commandsSent, commandsActive: INTEGER;
  flags: SET;
 END;
 
 Msg = RECORD
  index, len, type: SHORTINT;
  buf: ARRAY 9 OF CHAR
 END;

CONST RecordPadding =  32-16;

TYPE
 HostDesc = RECORD (SCSI.DriverDesc)
  padding: ARRAY RecordPadding OF CHAR;
  hwscb: ARRAY 256 OF HwScbDesc;  (*must be aligned to 32!*)
  
   (*hw communication*)
  Put1: Put1Proc;
  Get1: Get1Proc;
  
   (*scb informations*)
  allocated, active: INTEGER;
  freeList: BigSet;
  scb: ARRAY 256 OF ScbData;
   (*ugly implementation of a buffer, but the sequencer takes the address of
      untagged and __assumes__ that the in-queue is at +100H and the out-queue at +200H offset.
      This prevents the use of an abstract data structure here!
    *)
  untagged, out, in: ARRAY 256 OF CHAR;
  inNext, outNext: INTEGER;
  
   (*bord configuration*)
  flags, features: SET;
  termination: SET; (*was adapterCtrl*)
  
  epromSize, epromType: SHORTINT;
  chip, irq, scsiId, scsiIdB: SHORTINT;
  iobase, membase: LONGINT;
  interruptable: BOOLEAN;
  
   (*devices configuration*)
  dev: ARRAY 16 OF DeviceDesc;
  disconnect, ultra: SET;
  curWidth, goalWidth: SET;  (*clear = 8 bit, set = 16 bit. No support for 32 bit *)
  needWidthTrasm, widthPending, needSyncTrasm, syncPending: SET;
  
   (*debug, trace*)
  intCount, spuriousInt: LONGINT;
  
  (*cache, pre-computed values*)
  nofTargets: SHORTINT; (* 8 or 16*)
  msg: Msg;
  
  (*other*)
  maxScb: LONGINT; (*nof scbs supported on this card*)
  
  next: Host;
 END;
 
 PCIHost = POINTER TO PCIHostDesc;
 PCIHostDesc = RECORD (HostDesc)
  busNo, devNo, slot: LONGINT;
 END;

 DNames = ARRAY 32, 32 OF CHAR;
 
 RateTableDesc = RECORD
  period: SHORTINT; (* 1/4 of nsec, same as sync negotiation message *)
  rate: CHAR; (* rate for normal/fast/ultra cards *)
  u2rate: CHAR; (* rate ultra2 cards *)
 END;
 
VAR
 HostRoot: Host;
 
 (*Global Data*)
 RateTable: ARRAY 13 OF RateTableDesc;
 ResetDelay: LONGINT;
 
 InstalledIRQ: SET;
 
 (*Debug*)
 DFlag, DFeat, DDev, DChip, DTerm: DNames;
 DIntName: ARRAY 16, 16 OF CHAR;
 
 (*Tracing*)
 Trace: SET;
 Ada7Hack: SET;
 Ada7ID: LONGINT;
 ConfDisconnectEnable, ConfFastEnable: BOOLEAN;
 
 AwidthNegotiation, AsyncNegotiation,
 AseqNoMatch, AseqSendReject, AseqNoIdent, AseqBadPhase, AseqExtendedMsg,
 AseqRejectMsg, AseqBadStatus, AseqBadTerminated, AseqBusy, AseqAwaitingMsg, AseqDataOverrun,
 AcmpltGood, AcmpltBad, Aexecute,
 AscsiSelto, AscsiPErr, AscsiUnknown, AscsiBusFree, AscsiReset: LONGINT;

CONST
 (* Card Configuration *)
 ConfigNoDisconnection = 0;
 ConfigAllAsync = 1;

 (*Trace Configuration *)
 TraceCalls = 0;
 TraceInts = 1;
 TraceMsg = 2;
 TraceSequencer = 4;
 TraceReset = 5;
 TraceConfig = 6;
 TracePeriod = 7;
 TraceCmds = 8;
 TraceSeeprom = 9;
 TraceTermination = 10;

(*Debug Functions --------------------------------------------------*)
PROCEDURE WriteChar(ch: CHAR);
CONST
 num = ORD("0");  char = ORD("A")-10;
VAR byte: LONGINT;
BEGIN
 byte := ORD(ch);
 IF (byte DIV 16) < 10 THEN  Kernel.WriteChar(CHR(byte DIV 16+num)) ELSE Kernel.WriteChar(CHR(byte DIV 16+char)) END;
 IF (byte MOD 16) < 10 THEN  Kernel.WriteChar(CHR(byte MOD 16+num)) ELSE Kernel.WriteChar(CHR(byte MOD 16 +char)) END
END WriteChar;

PROCEDURE WriteCharArray(a: ARRAY OF CHAR;  len: LONGINT);
VAR i: LONGINT;
BEGIN
 FOR i := 0 TO len-1 DO  WriteChar(a[i]);  Kernel.WriteChar(" ")  END
END WriteCharArray;

PROCEDURE WriteBool(b: BOOLEAN);
BEGIN IF b THEN Kernel.WriteString("TRUE") ELSE Kernel.WriteString("FALSE") END
END WriteBool;

PROCEDURE WriteHost(d: Host);
BEGIN Kernel.WriteString("SCSI"); Kernel.WriteInt(d.number,0); Kernel.WriteString("   ")
END WriteHost;

PROCEDURE WriteDevice(d: Host; target: LONGINT);
BEGIN
 Kernel.WriteString("SCSI"); Kernel.WriteInt(d.number,0);
 Kernel.WriteChar("."); Kernel.WriteInt(target,0); Kernel.WriteChar(" ")
END WriteDevice;

PROCEDURE WriteWidth(wide: BOOLEAN);
BEGIN
 IF wide THEN Kernel.WriteString("16bit") ELSE Kernel.WriteString("8bit") END
END WriteWidth;

PROCEDURE TrmFlags(flags: SET);
BEGIN
 IF TransCur IN flags THEN Kernel.WriteString(" Current") END;
 IF TransActive IN flags THEN Kernel.WriteString(" Active") END;
 IF TransGoal IN flags THEN Kernel.WriteString(" Goal") END;
END TrmFlags;

PROCEDURE WriteDeviceConf(d: Host; target: LONGINT);
BEGIN
 WriteDevice(d, target);
 Kernel.WriteString(" current ("); Kernel.WriteInt(d.dev[target].curPeriod,0);
 Kernel.WriteChar("/"); Kernel.WriteInt(d.dev[target].curOffset,0);
 Kernel.WriteChar("/");
 IF target IN d.curWidth THEN Kernel.WriteChar("0") ELSE Kernel.WriteChar("1") END;
 
 Kernel.WriteString("), goal ("); Kernel.WriteInt(d.dev[target].goalPeriod,0);
 Kernel.WriteChar("/"); Kernel.WriteInt(d.dev[target].goalOffset,0);
 Kernel.WriteChar("/");
 IF target IN d.goalWidth THEN Kernel.WriteChar("1") ELSE Kernel.WriteChar("0") END;
 Kernel.WriteChar(")"); Kernel.WriteLn
END WriteDeviceConf;

PROCEDURE DumpQueue(d: Host;  queue: LONGINT;  name: ARRAY OF CHAR);
VAR  cur, ptr: LONGINT;
BEGIN
 WriteHost(d); Kernel.WriteString(name);
 cur := SYSTEM.VAL(LONGINT, d.Get1(d, SCBPTR));
 ptr := SYSTEM.VAL(LONGINT, d.Get1(d, queue));
 WHILE ptr # 0FFH DO
  Kernel.WriteChar(" ");  Kernel.WriteHex(ptr, -3);
  d.Put1(d, SCBPTR, SYSTEM.VAL(SET, ptr));
  ptr := SYSTEM.VAL(LONGINT, d.Get1(d, SCBNEXT));
 END;
 d.Put1(d, SCBPTR, SYSTEM.VAL(SET, cur));  Kernel.WriteLn;
END DumpQueue;

PROCEDURE WriteReg(str: ARRAY OF CHAR; ch: CHAR);
BEGIN
 Kernel.WriteString(str);  Kernel.WriteString(" = ");  WriteChar(ch);
END WriteReg;

PROCEDURE ShowDevices*;
VAR  d: Host;  i, rate: LONGINT;  wide: BOOLEAN;
BEGIN
 d := HostRoot;
 WHILE d # NIL DO
  FOR i := 0 TO d.nofTargets-1 DO
   IF  DevicePresent IN d.dev[i].flags  THEN
    WriteDevice(d, i);
    wide := i IN d.curWidth;
    CASE  d.dev[i].curPeriod  OF
    |  0:   rate := 0
    |  10:  rate := 400
    |  11:  rate := 333
    |  12:  rate := 200
    |  15:  rate := 160
    |  18:  rate := 134
    |  25:  rate := 100
    |  31:  rate := 80
    |  37:  rate := 66
    |  43:  rate := 57
    |  50:  rate := 50
    |  56:  rate := 44
    |  62:  rate := 40
    |  68:  rate := 36
    ELSE  rate := 99999
    END;
    IF rate = 0 THEN
     Kernel.WriteString("asynchronous")
    ELSE
     IF wide THEN  rate := rate*2  END;
     Kernel.WriteInt(rate DIV 10, 2); Kernel.WriteChar("."); Kernel.WriteInt(rate MOD 10, 1);
     Kernel.WriteString("MB/s,  offset = ");  Kernel.WriteInt(d.dev[i].curOffset, 2)
    END;
    IF  wide  THEN  Kernel.WriteString("  wide ")  END;
    Kernel.WriteLn
   END   
  END;
  d := d.next
 END;
END ShowDevices;

(* ========================================================================*)
(* ============================Helper Functions===============================*)
(* ========================================================================*)

(* GetEntry - Find first entry in the list and remove it *)

PROCEDURE GetEntry(VAR set: ARRAY OF SET): LONGINT;
VAR i, j: LONGINT;
BEGIN
 i := 0;
 WHILE (i < LEN(set)) & (set[i] = {}) DO  INC(i)  END;
 IF i = LEN(set) THEN
  RETURN -1
 ELSE
  j := 0;
  WHILE ~(j IN set[i]) DO  INC(j)  END;
  EXCL(set[i], j);
  RETURN i*32+j
 END
END GetEntry;

(* SetEntry - Insert entry in the list *)

PROCEDURE SetEntry(VAR s: ARRAY OF SET; x: LONGINT);
BEGIN
 ASSERT(~((x MOD 32) IN s[x DIV 32]));
 INCL(s[x DIV 32], x MOD 32)
END SetEntry;

(* ========================================================================*)
(* =================LOW LEVEL I/O FUNCTIONS, installed into the driver============*)
(* ========================================================================*)
PROCEDURE PortPut(d: Host;  off: LONGINT; val: SET);
BEGIN
 IF ~DebugNoWrites THEN
  SYSTEM.PORTOUT(d.iobase+off, SYSTEM.VAL(CHAR, val))
 END
END PortPut;

PROCEDURE MemoryPut(d: Host;  off: LONGINT; val: SET);
BEGIN
 IF ~DebugNoWrites THEN
  SYSTEM.PUT(d.membase+off, SYSTEM.VAL(CHAR, val))
 END
END MemoryPut;

PROCEDURE PortGet(d: Host; off: LONGINT): SET;
VAR val: SET;
BEGIN SYSTEM.PORTIN(d.iobase+off, SYSTEM.VAL(CHAR, val));  RETURN val
END PortGet;

PROCEDURE MemoryGet(d: Host; off: LONGINT): SET;
VAR val: SET;
BEGIN SYSTEM.GET(d.membase+off, SYSTEM.VAL(CHAR, val));  RETURN val
END MemoryGet;

PROCEDURE Get2(d: Host; off: LONGINT): SET;
BEGIN
 RETURN  d.Get1(d, off) + SYSTEM.ROT(d.Get1(d, off+1),8)
END Get2;

PROCEDURE Put2(d: Host;  off: LONGINT;  s: SET);
BEGIN
 d.Put1(d, off, s);
 d.Put1(d, off+1, SYSTEM.LSH(s, -8));
END Put2;

PROCEDURE Put4(d: Host; off, val: LONGINT);
VAR  s: SET;
BEGIN
 s := SYSTEM.VAL(SET, val);
 d.Put1(d, off, s);
 d.Put1(d, off+1, SYSTEM.LSH(s, -8));
 d.Put1(d, off+2, SYSTEM.LSH(s, -16));
 d.Put1(d, off+3, SYSTEM.LSH(s, -24));
END Put4;

PROCEDURE Delay(ms: LONGINT);  (*wait ~t ms. Assume TimeUnit=1000*)
VAR t: Kernel.MilliTimer;
BEGIN
 Kernel.SetTimer(t, ms);
 REPEAT UNTIL Kernel.Expired(t)
END Delay;


(* Set Functions for Integers *)
PROCEDURE -CSETBIT(VAR a: CHAR; b: SHORTINT);
CODE {SYSTEM.i386}
 POP EBX
 POP EAX
 AND EBX, 7  ;security
 BTS 0[EAX], EBX
END CSETBIT;

PROCEDURE -CBIT(a: CHAR; b: SHORTINT):BOOLEAN;
CODE {SYSTEM.i386}
 POP EBX
 POP EAX
 AND EAX, 0FFH
 BT EAX, EBX
 SETB AL
END CBIT;

(* ========================================================================*)
(* ====================Rate/Period conversions================================*)
(* ========================================================================*)

PROCEDURE SetPeriodOffset(d: Host;  device, period, offset: LONGINT; type: SET);
VAR  ultra2, ultra: BOOLEAN;  idx: LONGINT;  ctrl0, rate: SET;
BEGIN
 ASSERT((0 <= device) & (device <= 15));
 ultra2 :=  FeatUltra2 IN d.features;  ultra := device IN d.ultra;
 IF TraceConfig IN Trace THEN
  WriteDevice(d, device); Kernel.WriteString("SetPeOff "); 
  Kernel.WriteInt(period, 0); Kernel.WriteChar("/"); Kernel.WriteInt(offset, 0);
  TrmFlags(type); Kernel.WriteLn
 END;
 IF TransCur IN type THEN
  rate := d.Get1(d, TARGSCSIRATE + device) * {WIDEXFER};
  idx := FindRate(ultra2, ultra, period);
  IF idx = -1 THEN  offset := 0  END; (*use async*)
  IF ultra2 THEN
   IF idx # -1 THEN  rate := rate + SYSTEM.VAL(SET, RateTable[idx].u2rate)  END;
   IF TransActive IN type THEN
    d.Put1(d, SCSIRATE, rate);
    d.Put1(d, SCSIOFFSET, SYSTEM.VAL(SET, offset))
   END;
   d.Put1(d, TARGSCSIRATE+device, rate);
   d.Put1(d, TARGOFFSET+device, SYSTEM.VAL(SET, offset))
  ELSE
   IF idx # -1 THEN  rate := rate + SYSTEM.VAL(SET, RateTable[idx].rate) * {4..6} + SYSTEM.VAL(SET, offset) * {0..3}  END;
   IF TransActive IN type THEN
    d.Put1(d, SCSIRATE, rate);
    ctrl0 := d.Get1(d, SXFRCTL0) - {FAST20};
    IF device IN d.ultra THEN  INCL(ctrl0, FAST20)  END;
    d.Put1(d, SXFRCTL0, ctrl0)
   END;
   d.Put1(d, TARGSCSIRATE+device, rate);
   Put2(d, ULTRAENB, d.ultra);
  END;
  d.dev[device].curPeriod := period;
  d.dev[device].curOffset := offset
 END;
 IF TransGoal IN type THEN
  d.dev[device].goalPeriod := period;
  d.dev[device].goalOffset := offset
 END;
 IF d.dev[device].curPeriod < d.dev[device].goalPeriod THEN  INCL(d.needSyncTrasm, device)  END
END SetPeriodOffset;

PROCEDURE SetWidth(d: Host;  device: LONGINT; wide: BOOLEAN; flags: SET); (* aic7xxx_set_width *)
VAR rate: SET;
BEGIN
 IF TraceConfig IN Trace THEN
  WriteDevice(d, device); Kernel.WriteString("SetWidth "); WriteWidth(wide); TrmFlags(flags); Kernel.WriteLn
 END;
 IF TransCur IN flags THEN
  rate := d.Get1(d, TARGSCSIRATE + device);
  IF wide THEN  INCL(rate, WIDEXFER) ELSE  EXCL(rate, WIDEXFER)  END;
  d.Put1(d, TARGSCSIRATE + device, rate);
  IF TransActive IN flags THEN  d.Put1(d, SCSIRATE, rate)  END;
  IF  wide  THEN  INCL(d.curWidth, device)  ELSE  EXCL(d.curWidth, device)  END
 END;
 IF TransGoal IN flags THEN
  IF wide THEN  INCL(d.goalWidth, device)  ELSE  EXCL(d.goalWidth, device)  END;
 END;
 IF device IN (d.goalWidth - d.curWidth) THEN  INCL(d.needWidthTrasm, device)  END 
END SetWidth;

PROCEDURE FindPeriod(ultra2, ultra: BOOLEAN;  rate: CHAR): LONGINT;
VAR i: LONGINT;
BEGIN
 IF TracePeriod IN Trace THEN
  Kernel.WriteString("FindPeriod "); WriteBool(ultra2); WriteBool(ultra); Kernel.WriteHex(ORD(rate), -3)
 END;
 rate := CHR(ORD(rate) MOD 80H); (* clear wide *)
 IF ultra2 THEN
  i := 0;
  WHILE (i < LEN(RateTable)) & (RateTable[i].u2rate # rate) DO  INC(i)  END
 ELSE
  IF ultra THEN  i := 2  ELSE  i := 5  END;
  WHILE (i < LEN(RateTable)) & (RateTable[i].rate # rate) DO  INC(i)  END
 END;
 IF i < LEN(RateTable) THEN
  IF TracePeriod IN Trace THEN  Kernel.WriteString(" -> "); Kernel.WriteInt(RateTable[i].period, 4); Kernel.WriteLn  END;
  RETURN RateTable[i].period
 ELSE
  IF TracePeriod IN Trace THEN  Kernel.WriteString(" ->   0"); Kernel.WriteLn  END;
  RETURN 0 (*async*)
 END
END FindPeriod;

(* FindRate - return index in the rate table for a given period or -1 (async) *)

PROCEDURE FindRate(ultra2, ultra: BOOLEAN; period: LONGINT): LONGINT; (* aic7xxx_find_syncrate *)
VAR i: LONGINT;
BEGIN
 IF TracePeriod IN Trace THEN
  Kernel.WriteString("FindRate "); WriteBool(ultra2); WriteBool(ultra); Kernel.WriteInt(period, 4)
 END;
 IF ultra2 THEN i := 0 ELSIF ultra THEN i := 2 ELSE i := 5 END;
 WHILE  (i < LEN(RateTable)) & (period > RateTable[i].period) DO INC(i) END;
 IF i < LEN(RateTable) THEN
  IF TracePeriod IN Trace THEN Kernel.WriteString(" -> (pos)"); Kernel.WriteInt(i, 4); Kernel.WriteLn END;
  RETURN i
 ELSE
  IF TracePeriod IN Trace THEN Kernel.WriteString(" -> (pos)   -1"); Kernel.WriteLn END;
  RETURN -1
 END
END FindRate;

(* ========================================================================*)
(* ==========================Sequencer======================================*)
(* ========================================================================*)
PROCEDURE LoadSequencer(d: Host);  (*aic7xxx_loadseq, aic7xxx_download_instr*)
VAR  i: LONGINT; line: SET;
BEGIN
 IF TraceCalls IN Trace THEN  WriteHost(d); Kernel.WriteString("LoadSequencer"); Kernel.WriteLn  END;
 Script.Init(FeatUltra2 IN d.features, FeatUltra IN d.features, FeatWide IN d.features, FeatTwin IN d.features,
    FlagPageSCB IN d.flags, FeatQueueRegs IN d.features, FeatCmdChan IN d.features, FALSE, AIC7895 = d.chip);
 i := 0;
 d.Put1(d, SEQCTL, {PERRORDIS,LOADRAM,FAILDIS,FASTMODE});
 d.Put1(d, SEQADDR0, {}); d.Put1(d, SEQADDR1, {});
 WHILE Script.GetNext(line) DO
  d.Put1(d, SEQRAM, line);
  d.Put1(d, SEQRAM, SYSTEM.LSH(line, -8));
  d.Put1(d, SEQRAM, SYSTEM.LSH(line, -16));
  d.Put1(d, SEQRAM, SYSTEM.LSH(line, -24));
  INC(i)
 END;
 IF TraceSequencer IN Trace THEN
  WriteHost(d); Kernel.WriteString("Sequencer: "); 
  WriteBool(FeatUltra2 IN d.features); WriteBool(FeatUltra IN d.features); WriteBool(FeatWide IN d.features);
  WriteBool(FeatTwin IN d.features); WriteBool(FlagPageSCB IN d.flags); WriteBool(FeatQueueRegs IN d.features);
  WriteBool(FeatCmdChan IN d.features); Kernel.WriteLn;
  WriteHost(d); Kernel.WriteString("Sequencer: "); Kernel.WriteInt(i, 4); 
  Kernel.WriteString(" lines loaded"); Kernel.WriteLn
 END;
 d.Put1(d, SEQCTL, {FASTMODE,SEQRESET});
END LoadSequencer;


(* ========================================================================*)
(* ==========================SEEPROM Functions==============================*)
(* ========================================================================*)
PROCEDURE -SeepromRelease(d: Host);
BEGIN d.Put1(d, SEECTL, {})
END SeepromRelease;

PROCEDURE SeepromAquire(d: Host): BOOLEAN;
VAR t: Kernel.MilliTimer;
BEGIN
 Kernel.SetTimer(t, 1000);  (*max wait: 1 sec*)
 d.Put1(d, SEECTL, {SEEMS});
 REPEAT  UNTIL  (SEERDY IN d.Get1(d, SEECTL))  OR  Kernel.Expired(t);
 IF ~(SEERDY IN d.Get1(d, SEECTL)) THEN
  SeepromRelease(d);
  RETURN FALSE
 END;
 RETURN TRUE
END SeepromAquire;

PROCEDURE SeepromWriteWord(d: Host; bits, count: LONGINT);
VAR msg: SET;
BEGIN
 WHILE count > 0 DO
  DEC(count);
  IF ODD(SYSTEM.LSH(bits, -count)) THEN  msg := {SEEDO}  ELSE msg := {}  END;
  d.Put1(d, SEECTL,  {SEEMS, SEECS} + msg );
  REPEAT  UNTIL  SEERDY IN d.Get1(d, SEECTL);
  d.Put1(d, SEECTL,  {SEEMS, SEECS, SEECK} + msg);
  REPEAT  UNTIL  SEERDY IN d.Get1(d, SEECTL);
 END
END SeepromWriteWord;
 
PROCEDURE SeepromReadWord(d: Host; VAR word: LONGINT);
VAR msg: SET; count: LONGINT;
BEGIN
 msg := {};
 count := 17; (*read 16 bits. first bit read is always 0. MSB is read first*)
 WHILE count > 0 DO
  DEC(count);
  d.Put1(d, SEECTL,  {SEEMS, SEECS});
  REPEAT  UNTIL  SEERDY IN d.Get1(d, SEECTL);
  IF SEEDI IN d.Get1(d, SEECTL) THEN INCL(msg, count) END;
  d.Put1(d, SEECTL,  {SEEMS, SEECS, SEECK});
  REPEAT  UNTIL  SEERDY IN d.Get1(d, SEECTL);
 END;
 word := SYSTEM.VAL(LONGINT, msg * {0..15})
END SeepromReadWord;

PROCEDURE SeepromRead(d: Host; VAR data: ARRAY OF SYSTEM.BYTE; count, chip: LONGINT): BOOLEAN;
VAR k, word, offset: LONGINT; checksum: INTEGER;
BEGIN
 IF ~SeepromAquire(d) THEN  RETURN FALSE  END;
 checksum := 0;
 IF FlagChnlB IN d.flags THEN offset := 20H
 ELSIF FlagChnlC IN d.flags THEN offset := 40
 ELSE offset := 0
 END;
 FOR k := 0 TO count-1 DO
  d.Put1(d, SEECTL, {SEEMS, SEECS, SEECK});
  REPEAT UNTIL SEERDY IN d.Get1(d, SEECTL);
  SeepromWriteWord(d, 6H, 3); (*send 110 / read command*)
  SeepromWriteWord(d, k+offset, chip); (* send address *)
  SeepromReadWord(d, word); (*read 17 bits, first bit is a 0*)
  data[2*k] := SYSTEM.VAL(SYSTEM.BYTE, word); (*lsb*)
  data[2*k+1] := SYSTEM.VAL(SYSTEM.BYTE, word DIV 100H); (*msb*)
  IF k < count-1 THEN INC(checksum, SHORT(word)) END;
  
  d.Put1(d, SEECTL, {SEEMS});
  REPEAT  UNTIL  SEERDY IN d.Get1(d, SEECTL);
  d.Put1(d, SEECTL, {SEEMS, SEECK});
  REPEAT  UNTIL  SEERDY IN d.Get1(d, SEECTL);
  d.Put1(d, SEECTL, {SEEMS});
  REPEAT  UNTIL  SEERDY IN d.Get1(d, SEECTL);
 END;
 SeepromRelease(d);
 RETURN checksum = SHORT(word)
END SeepromRead;

(* ConfigDevice - *)

PROCEDURE ConfigDevice(d: Host; i: LONGINT; sync, wide: BOOLEAN; biosrate: LONGINT);
VAR rate, offset: LONGINT;  ultra, ultra2: BOOLEAN;
BEGIN
 IF TraceConfig IN Trace THEN  
  WriteDevice(d, i);  Kernel.WriteString(" Initial Config: "); WriteWidth(wide);
  IF sync THEN  Kernel.WriteHex(biosrate, -3)  END;
  Kernel.WriteLn
 END;
  (*offset/period*)
 ultra := i IN d.ultra;  ultra2 := FeatUltra2 IN d.features;
 
 SetWidth(d, i, FALSE, {TransCur}); (*ensure that the registers are correctly set, FALSE because bus will be reset*)
 SetWidth(d, i, wide, {TransGoal});
 
 IF ~sync THEN
  EXCL(d.ultra, i);
  SetPeriodOffset(d, i, 0, 0, {TransCur, TransGoal})
 ELSE
  INCL(d.needSyncTrasm, i); (*force negotiation*)
  IF ultra2 THEN
   offset := MaxOffsetUltra2;
   IF ultra THEN rate := biosrate + 18H ELSE rate := biosrate + 10H END
  ELSIF wide THEN
   rate := SYSTEM.LSH(biosrate, 4);
   offset := MaxOffset16Bit
  ELSE
   rate := SYSTEM.LSH(biosrate, 4);
   offset := MaxOffset8Bit
  END;
  SetPeriodOffset(d, i, 0, 0, {TransCur});
  SetPeriodOffset(d, i, FindPeriod(ultra2, ultra, CHR(rate)), offset, {TransGoal});
 END;
END ConfigDevice;



(* ConfigFromBios - Read BIOS and configure card. FALSE if no BIOS found *)

PROCEDURE ConfigFromBios(d: Host): BOOLEAN;
CONST
(*
 Eeprom configuration:

HostFlags:*)
 (*bit 0..2 Syncronous Transfer Rate /             CFXFER*)
 (*bit 3    enable synchronous transfer *)         CFSYNCH = 3;
 (*bit 4    enable disconnection *)                CFDISC = 4;
 (*bit 5    wide bus device (wide) *)              CFWIDEB = 5;
 (*bit 6    CFSYNC is an ultra offset / *)         CFSYNCHISULTRA = 6;
 (*bit 7    unused*)
 (*bit 8    send start unit SCSI command           CFSTART = 8;*)
 (*bit 9    include in BIOS scan                   CFINCBIOS = 9;*)
 (*bit10    report even if not found               CFRNFOUND = 10;*)
 (*bit11    probe mult luns in BIOS scan           CFMULTILUN = 11;*)
(*Bios Control Bits:*)
 (*bit 0    support all removable drives           CFSUPREM = 0;*)
 (*bit 1    support removable drives for boot only CFSUPREMB = 1;*)
 (*bit 2    BIOS enabled *)                        CFBIOSEN = 2;
 (*bit 4    support more than two drives           CFSM2DRV = 4;*)
 (*bit 5    extended translation (284x) *)         CF284XEXTEND = 5;
 (*bit 7    extended translation enabled *)        CFEXTEND = 7;
(*Host Adapter Control Bits:*)
 (*bit 0    Perform Auto termination *)            CFAUTOTERM = 0+16;
 (*bit 1    Ultra SCSI speed enable (Ultra)*)      CFULTRAEN = 1+16;
 (*bit 2    Selection timeout (284x cards)         CF284XSELTO = 2+16;*)
 (*bit 3    SCSI low byte termination *)           CFSTERM = 3+16;
 (*bit 4    SCSI high byte termination (wide) *)   CFWSTERM = 4+16;
 (*bit 5    SCSI parity *)                         CFSPARITY = 5+16;
 (*bit 6    SCSI low byte termination (284x) *)    CF284XSTERM = 6+16;
 (*bit 7    reset SCSI bus at boot                 CFRESETB = 7+16;*)
 (*bit 8    Channel B primary on 7895 chipsets *)  CFBPRIMARY = 8+16;
 (*bit 10    aic7890 Perform SE Auto Term *)       CFSEAUTOTERM = 10+16;
 (*bit 11    aic7890 LVD Termination *)            CFLVDSTERM = 11+16;
TYPE
 SeepromConfig = RECORD
  Flags: ARRAY 16 OF INTEGER;
  Control: SET;
  BrTime, MaxTargets: INTEGER;
  pad: ARRAY 11 OF INTEGER;
  Checksum: INTEGER;
 END;
VAR
 config: SeepromConfig; s: SET; dev: LONGINT;  cur: Host;
 
BEGIN
 IF (d.chip = AIC7770) & ~(d IS PCIHost) THEN RETURN FALSE END;
 IF ~SeepromRead(d, config, d.epromSize, d.epromType) THEN
  IF d.epromType = C56 THEN
   IF ~SeepromRead(d, config, d.epromSize, C46) THEN RETURN FALSE END (*try the other eeprom kind*)
  ELSE
   IF ~SeepromRead(d, config, d.epromSize, C56) THEN RETURN FALSE END
  END
 END;
 IF TraceBeta OR (TraceConfig IN Trace) THEN WriteHost(d); Kernel.WriteString("configure from SEEPROM"); Kernel.WriteLn END;
 INCL(d.flags, FlagSeepromFound);
 d.scsiId := SHORT(config.BrTime MOD 16);
 d.termination := config.Control * {CFAUTOTERM, CFSTERM, CFWSTERM, CFSEAUTOTERM, CFLVDSTERM};
 ASSERT(CFAUTOTERM = TermAuto); ASSERT(CFSTERM = TermS); ASSERT(CFWSTERM = TermSW); (*consistency*)
 ASSERT(CFSEAUTOTERM = TermSEAuto); ASSERT(CFLVDSTERM = TermSLvd);
 IF d.chip = AIC7770 THEN
  IF CF284XEXTEND IN config.Control THEN  INCL(d.flags, FlagExtendTransA)  END;
  IF CF284XSTERM IN config.Control THEN  d.termination := d.termination + {TermSELow, TermSEHigh}  END
 ELSE
  IF CFEXTEND IN config.Control THEN  INCL(d.flags, FlagExtendTransA)  END;
  IF CFSTERM IN config.Control THEN  d.termination :=  d.termination + {TermSELow, TermSEHigh}  END;
  IF CFBIOSEN IN config.Control THEN
   INCL(d.flags, FlagBiosEnabled)
  ELSE
   EXCL(d.flags, FlagBiosEnabled)
  END
 END;
 
 dev := config.MaxTargets MOD 100H;
 IF TraceBeta OR (TraceSeeprom IN Trace) THEN
  WriteHost(d); Kernel.WriteString("SEEPROM: "); Kernel.WriteLn;
  FOR dev := 0 TO 15 DO
   Kernel.WriteString(" dev"); Kernel.WriteInt(dev, 0);
   Kernel.WriteString("   "); Kernel.WriteHex(config.Flags[dev], 0); Kernel.WriteLn
  END;
  Kernel.WriteString(" control   "); Kernel.WriteHex(SYSTEM.VAL(LONGINT, config.Control), 0); Kernel.WriteLn;
  Kernel.WriteString(" brtime   "); Kernel.WriteHex(config.BrTime, 0); Kernel.WriteLn;
  Kernel.WriteString(" MaxTarg   "); Kernel.WriteHex(config.MaxTargets, 0); Kernel.WriteLn;
  WriteHost(d); Kernel.WriteString("targets: "); Kernel.WriteInt(dev, 0); Kernel.WriteLn
 END;
 IF (dev > 16) & ({FeatTwin, FeatWide} * d.features # {}) THEN dev :=16
 ELSIF dev > 8 THEN dev := 8
 END;
 
 WHILE dev > 0 DO
  DEC(dev);
  s := SYSTEM.VAL(SET, config.Flags[dev]);
  IF CFDISC IN s THEN INCL(d.disconnect, dev) END;
  IF CFULTRAEN IN config.Control  THEN
   INCL(d.ultra, dev)
  ELSIF (FeatUltra IN d.flags) & (CFSYNCHISULTRA IN s) THEN
   INCL(d.flags, FlagNewEepromFMT);
   INCL(d.ultra, dev)
  END;
  ConfigDevice(d, dev, (CFSYNCH IN s), (CFWIDEB IN s), config.Flags[dev] MOD 8);
 END;
 (*d.adapterCtrl := config.Control;*)
 IF d.chip IN {AIC7895, AIC7896} THEN
  IF CFBPRIMARY IN config.Control THEN  INCL(d.flags, FlagChannelBPrimary)  END;
   (* make sure the channel B primary flag is set properly on 7895 controllers,
    We also have to catch the fact that when you disable the BIOS on the 7895 on the Intel DK440LX
    motherboard, and possibly others, it only sets the BIOS disabled bit on the A channel *)
  IF d(PCIHost).devNo # 0 THEN (*find the a channel*)
   cur := HostRoot;
   WHILE cur # d DO
    IF (cur IS PCIHost) & (d(PCIHost).busNo = cur(PCIHost).busNo) & (d(PCIHost).slot = cur(PCIHost).slot) THEN
     ASSERT(cur(PCIHost).devNo = 0);
     IF FlagChannelBPrimary IN cur.flags THEN  INCL(d.flags, FlagChannelBPrimary)  END;
     IF FlagBiosEnabled IN cur.flags THEN  INCL(d.flags, FlagBiosEnabled)  ELSE  EXCL(d.flags, FlagBiosEnabled)  END
    END;
    cur := cur.next
   END
  END;
 END;
 IF d IS PCIHost THEN
  s := SYSTEM.VAL(SET, d.scsiId);
  IF (CFSPARITY IN config.Control) THEN  INCL(s, ENSPCHK)  END;
  d.Put1(d, SCSICONF, s);  d.Put1(d, SCSICONF+1, SYSTEM.VAL(SET, d.scsiId))
 END;
 RETURN TRUE
END ConfigFromBios;

(* ConfigFromScratchRam - Get configuration from scratch ram *)

PROCEDURE ConfigFromScratchRam(d: Host): BOOLEAN;
VAR s: SET; sync: BOOLEAN; rate, dev: LONGINT;
BEGIN
 IF d.Get1(d, SCSISEQ) = {} THEN RETURN FALSE END;
 IF TraceBeta OR (TraceConfig IN Trace) THEN WriteHost(d); Kernel.WriteString("configure from Scratch RAM"); Kernel.WriteLn END;
 INCL(d.flags, FlagNewEepromFMT);
 IF  STPWEN IN d.Get1(d, SXFRCTL1)  THEN
  d.termination := {TermS, TermSW, TermSLvd, TermSELow, TermSEHigh};
 END;
 
 IF ({FeatTwin, FeatWide} * d.features # {}) THEN dev :=16 ELSE dev := 8 END;
 
 d.disconnect := -Get2(d, DISCDSB);
 d.ultra := Get2(d, ULTRAENB);
 
 WHILE dev > 0 DO
  DEC(dev);
  s := d.Get1(d, TARGSCSIRATE+dev);
  rate := SYSTEM.VAL(LONGINT, s * {0..2});
  sync := FALSE; rate := 0;
  IF FeatUltra2 IN d.flags THEN
   IF d.Get1(d, TARGOFFSET+dev) # {} THEN
    sync := TRUE;
    IF s * {4,5} = {4,5} THEN INCL(d.ultra, dev) END
   END
  ELSE
   IF s-{WIDEXFER} # {} THEN
    sync := TRUE;
    IF FeatUltra IN d.features THEN INCL(d.ultra, dev) END
   END
  END;
  ConfigDevice(d, dev, sync, WIDEXFER IN s, rate)
 END;
 IF d IS PCIHost THEN
  d.Put1(d, SCSICONF, {ENSPCHK, RESETSCSI});  d.Put1(d, SCSICONF+1, SYSTEM.VAL(SET, d.scsiId))
 END;
 RETURN TRUE
END ConfigFromScratchRam;

PROCEDURE ConfigDefault(d: Host);
VAR dev: LONGINT;
BEGIN
 IF TraceBeta OR (TraceConfig IN Trace) THEN WriteHost(d); Kernel.WriteString("configure from default"); Kernel.WriteLn END;
 EXCL(d.flags, FlagBiosEnabled);
 d.scsiId := 7;  d.scsiIdB := 7;
 d.termination := {TermS, TermSW, TermSLvd, TermSELow, TermSEHigh};
 d.disconnect := {0..MaxTargets};
 IF ({FeatTwin, FeatWide} * d.features # {}) THEN dev :=16 ELSE dev := 8 END;
 
 WHILE dev > 0 DO
  DEC(dev);
  d.Put1(d, TARGSCSIRATE+dev, {});
  IF FeatUltra2 IN d.features THEN
   d.Put1(d, TARGOFFSET+dev, {});
   ConfigDevice(d, dev, TRUE, FeatWide IN d.features, 3)
  ELSE
   IF FeatUltra IN d.features THEN INCL(d.ultra, dev) END;
   ConfigDevice(d, dev, TRUE, FeatWide IN d.features, 0)
  END
 END;
 IF d IS PCIHost THEN
  d.Put1(d, SCSICONF, {ENSPCHK, RESETSCSI});
  d.Put1(d, SCSICONF+1, SYSTEM.VAL(SET, d.scsiId))
 END;
END ConfigDefault;

(* ConfigHost - Initial configuration from eeprom/bios/default *)

PROCEDURE ConfigHost(d: Host);
VAR i: LONGINT;
BEGIN
 d.disconnect := {};  d.ultra := {}; d.termination := {};
 d.curWidth := {};  d.goalWidth := {};  d.needWidthTrasm := {};
 IF ~ConfigFromBios(d) THEN
  IF ~ConfigFromScratchRam(d) THEN ConfigDefault(d) END
 END;
 IF TraceBeta OR (TraceConfig IN Trace) THEN
  WriteHost(d); Kernel.WriteString("termination config: ");
  FOR i := 0 TO 31 DO
   IF i IN d.termination THEN Kernel.WriteString(DTerm[i]); Kernel.WriteChar(" ") END
  END;
  Kernel.WriteLn;
 END;
 d.Put1(d, DISCDSB, -d.disconnect);  d.Put1(d, DISCDSB+1, SYSTEM.LSH(-d.disconnect, -8));
END ConfigHost;

(*Useful procedures, often used*)
PROCEDURE Pause(d: Host);
BEGIN
 IF TraceCalls IN Trace THEN  Kernel.WriteString("Adaptec7.Pause")  END;
 d.Put1(d, HCNTRL, {INTEN, PAUSE});
 WHILE ~(PAUSE IN d.Get1(d, HCNTRL)) DO  END;
END Pause;

PROCEDURE Unpause(d: Host);
BEGIN
 IF TraceCalls IN Trace THEN  Kernel.WriteString("Adaptec7.Unpause")  END;
 IF ~(FlagHandlingReqInits IN d.flags) THEN
  IF TraceCalls IN Trace THEN  Kernel.WriteString("*")  END;
  d.Put1(d, HCNTRL, {INTEN})
 END;
 IF TraceCalls IN Trace THEN  Kernel.WriteLn  END;
END Unpause;

(* ========================================================================*)
(* ============================Board Control=================================*)
(* ========================================================================*)
PROCEDURE WriteBoardCtrl(d: Host; s: SET); (* write_brdctl *)
VAR x: SET;
BEGIN
 ASSERT((d.chip # AIC7895) OR (FeatUltra2 IN d.features));  (*I did a simplification: assume 7895 is never Ultra2!*)
 IF FeatUltra2 IN d.features THEN
  d.Put1(d, BRDCTL, {});  Delay(1);
  d.Put1(d, BRDCTL, s);  Delay(1);
  d.Put1(d, BRDCTL, s+{BRDSTBULTRA2});  Delay(1);
  d.Put1(d, BRDCTL, {});  Delay(1)
 ELSE
  x := {BRDSTB, BRDCS};
  IF (d.chip = AIC7895) & ~(FlagChnlB IN d.flags) THEN  x := {BRDSTB}  END;
  d.Put1(d, BRDCTL, x);  Delay(1);
  x := x + s;
  d.Put1(d, BRDCTL, x);  Delay(1);
  d.Put1(d, BRDCTL, x-{BRDSTB});  Delay(1);
  d.Put1(d, BRDCTL, x-{BRDSTB, BRDCS});  Delay(1)
 END;
END WriteBoardCtrl;

PROCEDURE ReadBoardCtrl(d: Host): SET;  (* read_brdctl *)
VAR x: SET;
BEGIN
 ASSERT((d.chip # AIC7895) OR (FeatUltra2 IN d.features));  (*I did a simplification!*)
 IF FeatUltra2 IN d.features THEN
  d.Put1(d, BRDCTL, {BRDRWULTRA2}); Delay(1);
 ELSIF (d.chip = AIC7895) & ~(FlagChnlB IN d.flags) THEN
  d.Put1(d, BRDCTL, {BRDRW}); Delay(1);
 ELSE
  d.Put1(d, BRDCTL, {BRDRW, BRDCS}); Delay(1);
 END;
 x := d.Get1(d, BRDCTL);
 d.Put1(d, BRDCTL, {});  Delay(1);
 RETURN x
END ReadBoardCtrl;

(* ========================================================================*)
(* ======================Termination Handling=================================*)
(* ========================================================================*)
PROCEDURE ConfigureTermination(d: Host);  (* configure_termination *)
  VAR  SEHigh, SELow, LVDHigh, LVDLow, Int50, Int68, Ext, Wide: BOOLEAN;  xctrl1, BrdDat: SET; trace: BOOLEAN;
 PROCEDURE Ultra2TermDetect;
 VAR s: SET;
 BEGIN
  Int50 := FALSE; Int68 := Wide; Ext := TRUE;
  s := ReadBoardCtrl(d);
  IF TermSEAuto IN d.termination THEN
   SEHigh := 6 IN s;  SELow := 5 IN s
  ELSE
   SELow := TermS IN d.termination;
   SEHigh := TermSW IN d.termination
  END;
  IF  TermAuto IN d.termination  THEN
   LVDHigh := 4 IN s;  LVDLow := 3 IN s
  ELSE
   LVDLow := TermSLvd IN d.termination; LVDHigh := LVDLow
  END;
 END Ultra2TermDetect;
 
 PROCEDURE AIC787xCableDetect;
 VAR s: SET;
 BEGIN
  WriteBoardCtrl(d, {});  s := ReadBoardCtrl(d);
  Int50 := ~(6 IN s);
  Int68 := ~(7 IN s) & Wide;
  WriteBoardCtrl(d, {5});  s := ReadBoardCtrl(d);
  Ext := ~(6 IN s);
  IF Int50 & Int68 & Ext THEN
   Int50 := FALSE; Ext := FALSE; SEHigh := TRUE; SELow := TRUE
  END;
 END AIC787xCableDetect;
 
 PROCEDURE AIC785xCableDetect;
 VAR s: SET;
 BEGIN
  d.Put1(d, BRDCTL, {BRDRW, BRDCS});  Delay(1);
  d.Put1(d, BRDCTL, {});  Delay(1);
  s := d.Get1(d, BRDCTL);  Delay(1);
  Int50 := ~(5 IN s);
  Ext := ~(6 IN s);
 END AIC785xCableDetect;
BEGIN
 trace := (TraceConfig IN Trace) OR (TraceTermination IN Trace);
 IF trace THEN WriteHost(d); Kernel.WriteString("Configure Termination"); Kernel.WriteLn END;
 IF SeepromAquire(d) THEN
  BrdDat := {};
  xctrl1 := d.Get1(d, SXFRCTL1);
  Wide := (FeatWide IN d.features) OR (FeatTwin IN d.features);
  d.Put1(d, SEECTL, {SEEMS, SEECS});
  EXCL(xctrl1, STPWEN);
  IF (TermAuto IN d.termination) OR (FeatUltra2 IN d.features) THEN
   IF trace THEN  WriteHost(d); Kernel.WriteString("Autotermination detected"); Kernel.WriteLn END;
   IF FeatUltra2 IN d.features THEN
    Ultra2TermDetect;
   ELSIF d.chip >= AIC7870 THEN
    AIC787xCableDetect;
   ELSE
    AIC785xCableDetect
   END;
   IF trace THEN  WriteHost(d); Kernel.WriteString("Cables Present ");
    IF Int50 THEN Kernel.WriteString("Int50 ") END;
    IF Int68 THEN Kernel.WriteString("Int68 ") END;
    IF Ext THEN Kernel.WriteString("Ext ") END;
    Kernel.WriteLn
   END;
   
   IF Wide & ( ~Ext OR ~Int68 OR SEHigh) THEN
    INCL(BrdDat, 6);
    INCL(d.termination, TermSEHigh)
   END;
   IF ~(Int68 OR Ext) OR ~(Int50 OR (Int68 & Ext)) THEN (*none or only one of the flags*)
    IF FeatUltra2 IN d.features THEN  INCL(BrdDat, 5)
    ELSE INCL(xctrl1, STPWEN)
    END;
    INCL(d.termination, TermSELow)
   END;
   IF LVDLow THEN INCL(xctrl1, STPWEN) END;
   IF LVDHigh THEN  INCL(BrdDat, 4)  END
  ELSE
   IF TermS IN d.termination THEN
    IF FeatUltra2 IN d.features THEN   INCL(BrdDat, 5)  ELSE  INCL(xctrl1, STPWEN)  END
   END;
   IF TermSW IN d.termination THEN  INCL(BrdDat, 6)  END
  END;
  IF trace THEN
   WriteHost(d); Kernel.WriteString("TermConfig: ");
   WriteReg("BrdCtrl", SYSTEM.VAL(CHAR, BrdDat));
   WriteReg("SXFRCTL1", SYSTEM.VAL(CHAR, xctrl1));
   Kernel.WriteLn
  END;
  WriteBoardCtrl(d, BrdDat);
  SeepromRelease(d);
  d.Put1(d, SXFRCTL1, xctrl1)
 END
END ConfigureTermination;

(* ========================================================================*)
(* ========================Message Handling=================================*)
(* ========================================================================*)

(* StartMsg - Prepare the host adapter to send a message to the device *)

PROCEDURE StartMsg(d: Host;  VAR msg: Msg;  type: SHORTINT);
BEGIN
 msg.index := 0;  msg.len := 0;  msg.type := type;
 INCL(d.flags, FlagHandlingReqInits);
 d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) + {ENREQINIT});
END StartMsg;

(* StopMsg - Terminate the message transmission *)

PROCEDURE StopMsg(d: Host;  VAR msg: Msg);
BEGIN
 IF TraceCalls IN Trace THEN Kernel.WriteString("StopMsg"); Kernel.WriteLn END;
 msg.len := 0;  msg.index := 0;  msg.type := MsgTypeNone;
 d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) - {ENREQINIT});
 d.Put1(d, CLRINT, {CLRSCSIINT});
 EXCL(d.flags, FlagHandlingReqInits);
END StopMsg;

(* ComposeMsg - compose the message to be sent according to the device flags *)

PROCEDURE ComposeMsg(d: Host;  device: LONGINT;  VAR buf: ARRAY OF CHAR;  VAR len: SHORTINT);
VAR index: LONGINT; scb: ScbData;
BEGIN
 index := ORD(SYSTEM.VAL(CHAR, d.Get1(d, SEQADDR0)));
 index := index + 100*(ORD(SYSTEM.VAL(CHAR, d.Get1(d, SEQADDR1)))MOD 2);
 IF TraceInts IN Trace THEN
  WriteDevice(d, device);  Kernel.WriteString(" ComposeMsg"); (*Kernel.WriteInt(index, 4);*) Kernel.WriteLn
 END;
 index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
 scb := d.scb[index];
 IF ScbDeviceReset IN scb.flags THEN
  buf[0] := SCSI.MsgBusDevReset;  len := 1
 ELSIF ScbAbort IN scb.flags THEN
  buf[0] := SCSI.MsgAbort;  len := 1
 ELSIF ScbMsgWidth IN scb.flags THEN
  buf[0] := SCSI.MsgExtended;  buf[1] := SCSI.MsgExtWdTrLen;  buf[2] := SCSI.MsgExtWdTr;
  IF device IN d.goalWidth THEN
   buf[3] := SCSI.MsgExtWdTr16Bit
  ELSE
   buf[3] := SCSI.MsgExtWdTr8Bit
  END;
  len := 4
 ELSIF ScbMsgSync IN scb.flags THEN
  buf[0] := SCSI.MsgExtended;  buf[1] := SCSI.MsgExtSdTrLen;  buf[2] := SCSI.MsgExtSdTr;
  buf[3] := CHR(d.dev[device].goalPeriod);  buf[4] := CHR(d.dev[device].goalOffset);
  len := 5
 ELSE
  (* awaiting an unexpected message *)
  SYSTEM.STI(); HALT(99)
 END;
 INCL(scb.flags, ScbMsgSent);
 IF TraceMsg IN Trace THEN
  WriteDevice(d, device);  Kernel.WriteString(" SEND Message ");
  WriteCharArray(buf, len); Kernel.WriteLn
 END;
END ComposeMsg;

PROCEDURE ParseMsg(d: Host; scb: ScbData): BOOLEAN;  (* aic7xxx_parse_msg *)
VAR target, chan, lun: SHORTINT; done, reply, reject, width: BOOLEAN; 
 index, period, offset: LONGINT;
 
BEGIN
 target := scb.cmd.target; chan := scb.cmd.chan; lun := scb.cmd.lun;
 reply := FALSE; done := FALSE;
 index := target + chan*8;
 
 reject := d.msg.buf[0] # SCSI.MsgExtended;
 IF ~reject & (d.msg.len > 2) THEN
  CASE d.msg.buf[2] OF
  | SCSI.MsgExtSdTr:
    EXCL(d.syncPending, index);
    IF d.msg.buf[1] # SCSI.MsgExtSdTrLen THEN
     IF TraceMsg IN Trace THEN WriteDevice(d, target); Kernel.WriteString(" MsgSync rejected"); Kernel.WriteLn END;
     reject := TRUE
    ELSIF d.msg.len < ORD(SCSI.MsgExtSdTrLen)+2 THEN
     RETURN FALSE (*message incomplete*)
    ELSE
     done := TRUE;
     period := ORD(d.msg.buf[3]);
     offset := ORD(d.msg.buf[4]);
     IF TraceMsg IN Trace THEN
      WriteDevice(d, index); Kernel.WriteString(" SET Sync "); Kernel.WriteInt(period, 3); 
      Kernel.WriteChar("/"); Kernel.WriteInt(offset, 3); Kernel.WriteLn;
     END;
     SetPeriodOffset(d, index, period, offset, {TransActive, TransCur, TransGoal});
     IF (ScbMsgSent IN scb.flags) & (ScbMsgSync IN scb.flags) THEN
      scb.flags := scb.flags - ScbMsgMask
     ELSE
      IF TraceMsg IN Trace THEN
       WriteDevice(d, index); Kernel.WriteString(" resend sync message"); Kernel.WriteLn
      END;
      scb.flags := scb.flags - ScbMsgMask + {ScbMsgSync};
      d.Put1(d, MSGOUT, SYSTEM.VAL(SET, HostMsg));
      d.Put1(d, SCSISIG, d.Get1(d, SCSISIG) + {ATN});
     END;
     done := TRUE
    END
  | SCSI.MsgExtWdTr:
    EXCL(d.widthPending, index);
    IF d.msg.buf[1] # SCSI.MsgExtWdTrLen THEN
     IF TraceMsg IN Trace THEN WriteDevice(d, index); Kernel.WriteString(" MsgWidth rejected"); Kernel.WriteLn END;
     reject := TRUE
    ELSIF d.msg.len < ORD(SCSI.MsgExtWdTrLen)+2 THEN
     RETURN FALSE (*message incomplete*)
    ELSE
     IF (ScbMsgSent IN scb.flags) & (ScbMsgWidth IN scb.flags) THEN
      width := d.msg.buf[3] = SCSI.MsgExtWdTr16Bit;
      scb.flags := scb.flags - ScbMsgMask;
     ELSE
      scb.flags := scb.flags - ScbMsgMask + {ScbMsgWidth};
      reply := TRUE;
      width := (d.msg.buf[3] = SCSI.MsgExtWdTr16Bit) & (FeatWide IN d.features) & (index IN d.goalWidth);
      EXCL(d.needWidthTrasm, index); (*msg not requested!*)
      d.Put1(d, MSGOUT, SYSTEM.VAL(SET, HostMsg));
      d.Put1(d, SCSISIG, d.Get1(d, SCSISIG) + {ATN})
     END;
     IF TraceMsg IN Trace THEN
      WriteDevice(d, index); Kernel.WriteString(" WIDTH = ");
      IF width THEN Kernel.WriteString("16") ELSE Kernel.WriteString("8") END;
      Kernel.WriteString(" bits"); Kernel.WriteLn
     END;
     SetWidth(d, index, width, {TransActive, TransCur, TransGoal});
     done := TRUE
    END
  ELSE
   IF TraceMsg IN Trace THEN WriteDevice(d, index); Kernel.WriteString(" Unknown Msg, reject"); Kernel.WriteLn END;
   reject := TRUE
  END
 END;
 IF reject THEN
  d.Put1(d, MSGOUT, SYSTEM.VAL(SET, SCSI.MsgMessageReject));
  d.Put1(d, SCSISIG, d.Get1(d, SCSISIG) + {ATN})
 END;
 RETURN done OR reject
END ParseMsg;

PROCEDURE TransferMsg(d: Host;  scb: ScbData;  VAR msg: Msg;  VAR done: BOOLEAN);
VAR ch: CHAR;
BEGIN
 done := FALSE;
 IF msg.type = MsgTypeInitiatorMsgOut THEN
  ASSERT(msg.len # 0, 110);
  IF msg.index = msg.len-1 THEN (* last byte *)
   done := TRUE;
   d.Put1(d, SINDEX, SYSTEM.VAL(SET, msg.buf[msg.index]));
   d.Put1(d, RETURN1, {})
  ELSIF (d.Get1(d, SCSISIG) * PHASEMASK) # PhaseMsgOut  THEN (* Phase Mismatch *)
   done := TRUE;
   d.Put1(d, RETURN1, MSGOUTPHASEMIS)
  ELSE
   d.Put1(d, CLRSINT1, {CLRREQINIT});
   d.Put1(d, CLRINT, {CLRSCSIINT});
   d.Put1(d, SCSIDATL, SYSTEM.VAL(SET, msg.buf[msg.index]));
   INC(msg.index);
  END
 ELSE
  done := (d.Get1(d, SCSISIG) * PHASEMASK) # PhaseMsgIn; (* Phase Mismatch *)
  IF ~done THEN
   msg.buf[msg.index] := SYSTEM.VAL(CHAR, d.Get1(d, SCSIBUSL));
   INC(msg.len);  INC(msg.index);
   done := ParseMsg(d, scb);
   
   d.Put1(d, CLRSINT1, {CLRREQINIT});
   d.Put1(d, CLRINT, {CLRSCSIINT});
   ch := SYSTEM.VAL(CHAR, d.Get1(d, SCSIDATL));
  END
 END
END TransferMsg;

(* ========================================================================*)
(* ========================Interrupt Handling=================================*)
(* ========================================================================*)
PROCEDURE ClearPCIInt(d: PCIHost);
CONST DPR = 0;  RMA = 5;  RTA = 4;
VAR res, dw: LONGINT;
BEGIN
 res := PCI.ReadConfigByte(d.busNo, d.devNo, d.slot, 7H, dw);
 res := PCI.WriteConfigByte(d.busNo, d.devNo, d.slot, 7H, dw); (* Clear PCI-Status *)
 IF {DPR, RMA, RTA} * SYSTEM.VAL(SET, dw) # {} THEN
  d.Put1(d, CLRINT, {CLRPARERR})
 END;
END ClearPCIInt;

PROCEDURE ClearIntStat(d: Host); (*aic7xxx_clear_intstat*)
BEGIN
 d.Put1(d, CLRSINT0, {CLRSELDO, CLRSELDI, CLRSELINGO});
 d.Put1(d, CLRSINT1, CLRSINT1ALL);
 d.Put1(d, CLRINT, {CLRSCSIINT, CLRSEQINT, CLRBRKADRINT, CLRPARERR})
END ClearIntStat;

PROCEDURE InterruptCmdComplete(d: Host);
VAR index, t: LONGINT; scb: ScbData;
BEGIN
 IF TraceInts IN Trace THEN WriteHost(d); Kernel.WriteString("cmd complete-int"); Kernel.WriteLn  END;
 d.Put1(d, CLRINT, {CLRCMDINT});
 WHILE d.out[d.outNext] # ScbNull DO
  index := ORD(d.out[d.outNext]); d.out[d.outNext] := ScbNull;
  d.outNext := (d.outNext+1) MOD 256;
  scb := d.scb[index];
  IF index >= d.allocated THEN
   Kernel.WriteString("CMDCMPLT with invalid SCB index ");
   Kernel.WriteInt(index, 0); Kernel.WriteLn
  ELSIF (scb.cmd.ptrToCmd = SYSTEM.VAL(LONGINT, NIL)) THEN
   Kernel.WriteString("CMDCMPLT without command for SCB index ");
   Kernel.WriteInt(index, 0); Kernel.WriteLn;
  ELSIF ~(ScbActive IN scb.flags) THEN
   Kernel.WriteString("CMDCMPLT with inactive scb for SCB index ");
   Kernel.WriteInt(index, 0); Kernel.WriteLn;
  ELSIF (ScbQueuedAbort IN scb.flags) & (d.Get1(d, LASTPHASE) * PHASEMASK = PhaseBusFree) & 
    (SYSTEM.VAL(CHAR, d.Get1(d, SCBTAG)) = d.hwscb[index].tag) THEN
   Pause(d); Unpause(d);
  ELSE
   IF (ScbQueuedAbort IN scb.flags) THEN
    Pause(d);
    scb.flags := scb.flags - {ScbQueuedForDone, ScbReset, ScbAbort, ScbQueuedAbort};
    Unpause(d)
   ELSIF ScbAbort IN scb.flags THEN
    scb.flags := scb.flags - {ScbAbort, ScbReset}
   END;
   CASE ORD(d.hwscb[index].status) OF
   | SCSI.QueueFull, SCSI.Busy:
    INC(AcmpltBad);
    d.hwscb[index].status := 0X;
    scb.cmd.status := SCSI.Busy;
    scb.cmd.result := SCSI.BusBusy;
    Done(d, index)
   ELSE
    INC(AcmpltGood);
    IF d.hwscb[index].resSGcnt # 0X THEN
     CalculateResidual(d, index)
    END;
    (*scb.cmd.result := scb.cmd.status;*)
    t := scb.cmd.target + scb.cmd.chan*8;
    d.dev[t].flags := d.dev[t].flags + {DeviceSuccess, DevicePresent};
    Done(d, index)
   END
  END
 END
END InterruptCmdComplete;

PROCEDURE InterruptBrkAdr(d: Host);
VAR errno: SET; addr: LONGINT;
BEGIN
 IF TraceInts IN Trace THEN  WriteHost(d); Kernel.WriteString("break addr - int"); Kernel.WriteLn  END;
 errno := d.Get1(d, ERROR);
 IF PCIERRSTAT IN errno THEN  ClearPCIInt(d(PCIHost))  END;
 IF {SQPARERR, ILLOPCODE, ILLSADDR} * errno # {} THEN
  addr := SYSTEM.VAL(LONGINT, SYSTEM.LSH(d.Get1(d, SEQADDR1),8)*{8..15} + d.Get1(d, SEQADDR0)*{0..7});
  SYSTEM.STI(); HALT(99)
 END;
 IF ILLHADDR IN errno THEN
  Kernel.WriteString("AIC7xxx.InterruptBrkAdr: BUG, driver accessed chip without pausing controller");
  Kernel.WriteLn;
 END;
 d.Put1(d, CLRINT, {CLRPARERR, CLRBRKADRINT});
 Unpause(d)
END InterruptBrkAdr;

PROCEDURE HandleDeviceReset(d: Host; target, channel: LONGINT);  (* handle_device_reset *)
VAR index: LONGINT;
BEGIN
 IF TraceCalls IN Trace THEN Kernel.WriteString("Adaptec7.HandleDeviceReset"); Kernel.WriteLn  END;
 index := target + channel*8;
 EXCL(d.syncPending, index);
 EXCL(d.widthPending, index);
 SetWidth(d, index, FALSE, {TransCur});
 SetPeriodOffset(d, index, 0, 0, {TransCur});
 ResetDevice(d, target, channel, AllLuns);
 IF TraceReset IN Trace THEN  Kernel.WriteString("Bus Device Reset delivered"); Kernel.WriteLn END;
 RunDoneQueue(d)
END HandleDeviceReset;

PROCEDURE CurrentTarget(d: Host;  VAR target, channel, lun, device: LONGINT);
VAR  t: LONGINT;
BEGIN
 t := SYSTEM.VAL(LONGINT, d.Get1(d, SAVEDTCL));
 target := SYSTEM.LSH(t, -4) MOD 16;
 channel := 0;  device := target;
 lun := t MOD 7;
 IF (d.chip = AIC7770) & (SELBUSB IN d.Get1(d, SBLKCTL)) THEN  channel := 1; INC(device, 8)  END
END CurrentTarget;

PROCEDURE InterruptSequencer(d: Host; intcode: LONGINT); (* handle_seqint *)
VAR target, channel, lun, device, index, sindex: LONGINT;  scb: ScbData; active, prev, next: SET;
BEGIN
 CurrentTarget(d, target, channel, lun, device);
 d.Put1(d, CLRINT, {CLRSEQINT});
 IF TraceInts IN Trace THEN
  WriteHost(d); Kernel.WriteString("Int Seq / "); Kernel.WriteString(DIntName[intcode]); Kernel.WriteLn
 END;
 CASE intcode OF
 | NoMatch:
   INC(AseqNoMatch);
   d.Put1(d, SCSISEQ, d.Get1(d, SCSISEQ) * {ENSELI, ENRSELI, ENAUTOATNP})
 | SendReject:
   INC(AseqSendReject)
 | NoIdent:
   INC(AseqNoIdent);
   ResetChannel(d, channel, TRUE);
   RunDoneQueue(d)
 | BadPhase:
   INC(AseqBadPhase);
   IF d.Get1(d, LASTPHASE) = PhaseBusFree THEN  d.Put1(d, SEQCTL, {FASTMODE, SEQRESET})  END
 | ExtendedMsg:
   INC(AseqExtendedMsg);
   StartMsg(d, d.msg, MsgTypeInitiatorMsgIn);
   RETURN
 | RejectMsg:
  INC(AseqRejectMsg);
  index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
  IF ScbMsgWidth IN d.scb[index].flags THEN
   EXCL(d.widthPending, device);
   d.scb[index].flags := d.scb[index].flags - ScbMsgMask;
   SetWidth(d, target+8*channel, FALSE, {TransActive, TransCur, TransGoal});
  ELSIF ScbMsgSync IN d.scb[index].flags THEN
   EXCL(d.syncPending, device);
   EXCL(d.scb[index].flags, ScbMsgSync);
   SetPeriodOffset(d, target+8*channel, 0, 0, {TransActive, TransCur, TransGoal})
  END
 | BadStatus:
  INC(AseqBadStatus);
  d.Put1(d, RETURN1, {});
  index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
  IF (ScbActive IN d.scb[index].flags)  & (d.scb[index].cmd.ptrToCmd # 0) THEN
   d.hwscb[index].status := SYSTEM.VAL(CHAR, d.Get1(d, SCBTARGETSTATUS));
   d.scb[index].cmd.status := SYSTEM.VAL(SHORTINT, d.hwscb[index].status);
   d.scb[index].cmd.result := d.scb[index].cmd.status;
   CASE d.scb[index].cmd.result OF
   | SCSI.Good:
     IF TraceInts IN Trace THEN  Kernel.WriteString(" / Good"); Kernel.WriteLn  END;
   | SCSI.CommandTerminated, SCSI.CheckCondition:
     INC(AseqBadTerminated);
     IF TraceInts IN Trace THEN  Kernel.WriteString(" / Term or Condition"); Kernel.WriteLn  END;
     scb := d.scb[index];
     IF d.hwscb[index].resSGcnt # 0X THEN
      CalculateResidual(d, index)
     END;
     d.untagged[ORD(d.hwscb[index].targ)] := CHR(index);
   | SCSI.QueueFull, SCSI.Busy:
    INC(AseqBusy);
    IF TraceBeta OR (TraceInts IN Trace) THEN  Kernel.WriteString(" / QueueFull or Busy"); Kernel.WriteLn  END;
    active := d.Get1(d, SCBPTR);
    next := d.Get1(d, WAITINGSCBH);
    prev := ScbNullSet; sindex := ORD(ScbNull);
    WHILE SYSTEM.VAL(CHAR, next) # ScbNull DO
     d.Put1(d, SCBPTR, next);
     Kernel.WriteString("Busy/Full, WAITING -> "); Kernel.WriteHex(SYSTEM.VAL(SHORTINT, next), -3); Kernel.WriteLn;
     sindex := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
     IF sindex < d.allocated THEN
      IF MatchScb(d, sindex, target, channel, lun) THEN
       HALT(99); (* hmmm.... I've only one cmd for this device, and it must be the active one! *)
       (* IF ScbWaitingQ IN d.scb[sindex].flags THEN
        INC(d.dev[device].commandsActive);
        INC(d.active);  (*c says --, but here ++ seems correct to me*)
        d.dev[device].delayed.Remove(d.scb[sindex]);
       ELSE
        HALT(99); (*where is this scb from?*)
       END;
       d.dev[device].delayed.PutFirst(d.scb[sindex]);
       INCL(d.scb[sindex].flags, ScbWaitingQ);
       DEC(d.dev[device].commandsActive);
       DEC(d.active);
       next := d.Get1(d, SCBNEXT);
       FreeCurScb(d);
       IF SYSTEM.VAL(CHAR, prev) = ScbNull THEN
        d.Put1(d, SCSISEQ, d.Get1(d, SCSISEQ) - {ENSELO});
        d.Put1(d, CLRSINT1, {CLRSELTIMEO});
        d.Put1(d, WAITINGSCBH, next)
       ELSE
        d.Put1(d, SCBPTR, prev);
        d.Put1(d, SCBNEXT, next)
       END *)
      ELSE
       prev := next;
       next := d.Get1(d, SCBNEXT)
      END
     END (*sindex < d.allocated*)
    END;
    d.Put1(d, SCBPTR, active);
    DEC(d.dev[device].commandsActive);
    DEC(d.active);
    d.scb[index].flags := d.scb[index].flags + {ScbQueuedForDone, ScbWasBusy};
    IF scb.cmd.result = SCSI.QueueFull THEN
     Kernel.WriteString("QueueFull: this cannot happen, I'm sending only one cmd per device!"); Kernel.WriteLn
    END
   ELSE (*CASE cmd.result*)
    IF scb.cmd.status # SCSI.OK THEN  scb.cmd.status := SCSI.Error  END
   END (*CASE cmd.result*)
  END
 | AwaitingMsg:
   INC(AseqAwaitingMsg);
   StartMsg(d, d.msg, MsgTypeInitiatorMsgOut);
   ComposeMsg(d, device, d.msg.buf, d.msg.len)
 | DataOverrun:
   INC(AseqDataOverrun);
   index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
   scb := d.scb[index];
   scb.cmd.status := SCSI.Error
 END;
 Unpause(d)
END InterruptSequencer;


PROCEDURE InterruptScsi(d: Host); (* handle_scsiint *)
VAR index, target, channel, scbptr: LONGINT; status, lastphase: SET; msg: CHAR; scb: ScbData;  done: BOOLEAN;
BEGIN
 index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
 target := SYSTEM.VAL(LONGINT, SYSTEM.LSH(d.Get1(d, SAVEDTCL), -4) * {0..3});
 lastphase := d.Get1(d, LASTPHASE);
 status := d.Get1(d, SSTAT1);
 scb := d.scb[index];
 IF (index >= d.allocated) OR ~(ScbActive IN scb.flags) THEN
  scb := NIL
 END;
 IF SCSIRSTI IN status THEN
  INC(AscsiReset);
  IF TraceInts IN Trace THEN  WriteHost(d); Kernel.WriteString("scsi-int / Reset-In"); Kernel.WriteLn  END;
  channel := 0;
  IF (d.chip =AIC7770) & (SELBUSB IN d.Get1(d, SBLKCTL)) THEN  channel := 1  END;
  IF TraceReset IN Trace THEN  WriteHost(d); Kernel.WriteString("Someone else reset the channel"); Kernel.WriteLn  END;
  ResetChannel(d, channel, FALSE);
  RunDoneQueue(d);
  scb := NIL
 ELSIF SELTO IN status THEN
  INC(AscsiSelto);
  IF TraceInts IN Trace THEN  WriteHost(d); Kernel.WriteString("scsi-int / Selection Time-out"); Kernel.WriteLn  END;
  scbptr := SYSTEM.VAL(LONGINT, d.Get1(d, WAITINGSCBH));
  IF scbptr > d.allocated THEN
   Kernel.WriteString("Invalid WAITING_SCBH value "); Kernel.WriteInt(scbptr, 1); Kernel.WriteLn;
   scbptr := d.allocated-1;
   WHILE (scbptr > 0) & (ScbActive IN d.scb[scbptr].flags) DO  DEC(scbptr)  END;
   Kernel.WriteString("Trying with "); Kernel.WriteInt(scbptr, 1); Kernel.WriteLn;
  END;
  d.Put1(d, SCBPTR, SYSTEM.VAL(SET, scbptr));
  index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
  scb := d.scb[index];
  IF (index >= d.allocated) OR ~(ScbActive IN scb.flags) THEN
   scb := NIL
  END;
  IF scb = NIL THEN
   Kernel.WriteString("Refenced SCB not valid during SELTO "); Kernel.WriteInt(index, 2); Kernel.WriteLn;
   Kernel.WriteInt(scbptr, 3); Kernel.WriteInt(d.allocated, 3); Kernel.WriteLn;
   Kernel.WriteMemory(d.membase + SCBCONTROL, 32); Kernel.WriteLn;
   Kernel.WriteMemory(d.membase, 100H); Kernel.WriteLn;
(*
   (*Kernel.WriteString("!!!!!!!!DANGER, int not reenabled !!!!!!!! ");*)
   d.Put1(d, CLRINT, {CLRSCSIINT});
   RETURN;
*)
  ELSE
   scb.cmd.status := SCSI.CommandTerminated;
   scb.cmd.result := SCSI.TimeOut;
   d.Put1(d, SCBCONTROL, {});
   d.Put1(d, MSGOUT, SYSTEM.VAL(SET, SCSI.MsgNoop));
   d.Put1(d, WAITINGSCBH, d.Get1(d, SCBNEXT));
   FreeCurScb(d);
   IF ScbQueuedAbort IN scb.flags THEN
    scb.cmd.result := SCSI.OK;
    EXCL(scb.flags, ScbQueuedAbort);
    scb := NIL
   END
  END;
  d.Put1(d, SCSISEQ, {});
  d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) - {ENREQINIT, ENBUSFREE});
  EXCL(d.flags, FlagHandlingReqInits);
  d.Put1(d, CLRSINT1, {CLRSELTIMEO,CLRBUSFREE});
  d.Put1(d, CLRINT, {CLRSCSIINT});
  d.Put1(d, SEQCTL, {FASTMODE, SEQRESET});
  Unpause(d)
 ELSIF (BUSFREE IN status) THEN
  INC(AscsiBusFree);
  IF TraceInts IN Trace THEN  WriteHost(d); Kernel.WriteString("scsi-int / BusFree"); Kernel.WriteLn  END;
  channel := 0;
  IF (d.chip =AIC7770) & (SELBUSB IN d.Get1(d, SBLKCTL)) THEN  channel := 1  END;
  d.Put1(d, SCSISEQ, d.Get1(d, SCSISEQ) * {ENSELI, ENRSELI, ENAUTOATNP});
  IF lastphase = PhaseMsgOut THEN
   msg := SYSTEM.VAL(CHAR, d.Get1(d, SINDEX));
   IF msg = SCSI.MsgAbort THEN
    ResetDevice(d, target, channel, AllLuns);
    RunDoneQueue(d);
    scb := NIL
   ELSIF msg = SCSI.MsgAbortTag THEN
    HALT(99); (* tag not used anymore, should not happen *)
    ResetDevice(d, target, channel, AllLuns);
    RunDoneQueue(d);
    scb := NIL
   ELSIF msg = SCSI.MsgBusDevReset THEN
    HandleDeviceReset(d, target, channel);
    scb := NIL
   END
  END;
  IF scb # NIL THEN
   ResetDevice(d, target, channel, AllLuns);
   RunDoneQueue(d)
  ELSE
   scb := NIL
  END;
  EXCL(d.flags, FlagHandlingReqInits);
  d.Put1(d, MSGOUT, SYSTEM.VAL(SET, SCSI.MsgNoop));
  d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) - {ENBUSFREE, ENREQINIT});
  d.Put1(d, CLRSINT1, {CLRBUSFREE});
  d.Put1(d, CLRINT, {CLRSCSIINT});
  d.Put1(d, SEQCTL, {FASTMODE, SEQRESET});
  Unpause(d)
 ELSIF scb = NIL THEN
  WriteHost(d); Kernel.WriteString("scsi-int / Referenced SCB not valid! "); Kernel.WriteInt(index, 0); Kernel.WriteLn;
  d.Put1(d, CLRSINT1, status);
  d.Put1(d, CLRINT, {CLRSCSIINT});
  Unpause(d)
 ELSIF SCSIPERR IN status THEN
  INC(AscsiPErr);
  IF TraceInts IN Trace THEN  WriteHost(d); Kernel.WriteString("scsi-int / Parity error"); Kernel.WriteLn  END;
  msg := SCSI.MsgNoop;
  IF lastphase = PhaseDataOut THEN
   Kernel.WriteString("Parity Error during Data-Out phase"); Kernel.WriteLn
  ELSIF lastphase = PhaseDataIn THEN
   msg := SCSI.MsgInitiatorDetErr;
   Kernel.WriteString("Parity Error during Data-In phase"); Kernel.WriteLn
  ELSIF lastphase = PhaseCommand THEN
   Kernel.WriteString("Parity Error during Command phase"); Kernel.WriteLn
  ELSIF lastphase = PhaseMsgOut THEN
   Kernel.WriteString("Parity Error during Message-Out phase"); Kernel.WriteLn
  ELSIF lastphase = PhaseStatus THEN
   msg := SCSI.MsgInitiatorDetErr;
   Kernel.WriteString("Parity Error during Status phase"); Kernel.WriteLn
  ELSIF lastphase = PhaseMsgIn THEN
   msg := SCSI.MsgParityError;
   Kernel.WriteString("Parity Error during Message_In phase"); Kernel.WriteLn
  ELSE
   Kernel.WriteString("Parity Error during unknown phase"); Kernel.WriteLn
  END;
  IF msg # SCSI.MsgNoop THEN
   d.Put1(d, MSGOUT, SYSTEM.VAL(SET, msg));  scb := NIL
  END;
  d.Put1(d, CLRSINT1, {CLRSCSIPERR});
  d.Put1(d, CLRINT, {CLRSCSIINT});
  Unpause(d)
 ELSIF (REQINIT IN status) & (FlagHandlingReqInits IN d.flags) THEN
  IF TraceInts IN Trace THEN  Kernel.WriteString("Int Scsi / Req Init"); Kernel.WriteLn  END;
  TransferMsg(d, scb, d.msg, done);
  IF done THEN  StopMsg(d, d.msg);  Unpause(d)  END;
  RETURN
 ELSIF (1 IN status) & (FlagHandlingReqInits IN d.flags) THEN (*phasechg*)
  IF TraceInts IN Trace THEN
   WriteHost(d); Kernel.WriteString("scsi-int / PhaseChg -- not handling"); Kernel.WriteLn
  END;
  Unpause(d);
  scb := NIL;
 ELSE
  INC(AscsiUnknown);
  WriteHost(d); Kernel.WriteString("scsi-int / Unknown"); Kernel.WriteHex(SYSTEM.VAL(LONGINT, status),0);        Kernel.WriteLn;
(*
  d.Put1(d, CLRSINT1, status);
  d.Put1(d, CLRINT, {CLRSCSIINT});
*)
  Unpause(d);
  scb := NIL
 END;
 IF scb # NIL THEN Done(d, index) END;
END InterruptScsi;

(* InterruptHandler - handle incoming interrupt *)

PROCEDURE InterruptHandler; (*this is the interrupt handler for all devices*)
VAR  irq, ebp: LONGINT;  d: Host;  intstat: SET;
BEGIN
 SYSTEM.GETREG(SYSTEM.EBP, ebp);  SYSTEM.GET(ebp+40, irq);  DEC(irq, Kernel.IRQ);
 d := HostRoot;
 WHILE d # NIL DO
  IF (d.irq = irq) & d.interruptable THEN
   intstat := d.Get1(d, INTSTAT);
   IF {CMDCMPLT, BRKADRINT, SEQINT, SCSIINT} * intstat # {} THEN
    INC(d.intCount);
    IF CMDCMPLT IN intstat THEN  InterruptCmdComplete(d)  END;
    IF BRKADRINT IN intstat THEN  InterruptBrkAdr(d)  END;
    IF SEQINT IN intstat THEN  InterruptSequencer(d, SYSTEM.LSH(SYSTEM.VAL(LONGINT, intstat), -4))  END;
    IF SCSIINT IN intstat THEN  InterruptScsi(d)  END
   END
  END;
  d := d.next
 END
END InterruptHandler;

(* ========================================================================*)
(* ==========================SCB Functions===================================*)
(* ========================================================================*)
PROCEDURE DetectMaxSCB(d: Host); (*detect_maxscb*)
VAR i: LONGINT;  quit: BOOLEAN;
BEGIN
 IF TraceCalls IN Trace THEN  WriteHost(d); Kernel.WriteString("DetectMaxSCB"); Kernel.WriteLn  END;
 IF d.maxScb = 0 THEN
  d.Put1(d, FREESCBH, {});
  i := 0;  quit := FALSE;
  WHILE (i < 255) & ~quit DO
   d.Put1(d, SCBPTR, SYSTEM.VAL(SET, i));
   d.Put1(d, SCBCONTROL, SYSTEM.VAL(SET, i));
   IF i # SYSTEM.VAL(LONGINT, d.Get1(d, SCBCONTROL)) THEN
    quit := TRUE
   ELSE
    d.Put1(d, SCBPTR, {});
    IF d.Get1(d, SCBCONTROL) # {} THEN
     quit := TRUE
    ELSE
     d.Put1(d, SCBPTR, SYSTEM.VAL(SET, i));
     d.Put1(d, SCBCONTROL, {});
     d.Put1(d, SCBNEXT, SYSTEM.VAL(SET, i+1));
     d.Put1(d, SCBPREV, SYSTEM.VAL(SET, i-1));
     d.Put1(d, SCBTAG, SYSTEM.VAL(SET, -1));
     d.Put1(d, SCBBUSYTARGETS, SYSTEM.VAL(SET, -1));
     d.Put1(d, SCBBUSYTARGETS+1, SYSTEM.VAL(SET, -1));
     d.Put1(d, SCBBUSYTARGETS+2, SYSTEM.VAL(SET, -1));
     d.Put1(d, SCBBUSYTARGETS+3, SYSTEM.VAL(SET, -1));
     INC(i)
    END
   END
  END;
  d.Put1(d, SCBPTR, SYSTEM.VAL(SET, i-1)); (*last SCB terminates the list*)
  d.Put1(d, SCBNEXT, SYSTEM.VAL(SET, -1));
  
  d.Put1(d, SCBPTR, SYSTEM.VAL(SET, 0)); (*clear first SCB control byte ????IS THIS REALLY USEFUL????*)
  d.Put1(d, SCBCONTROL, {});
  d.maxScb := i;
  IF i = 255 THEN  EXCL(d.flags, FlagPageSCB)  END;
 END;
 IF TraceConfig IN Trace THEN
  WriteHost(d); Kernel.WriteInt(d.maxScb, 0); Kernel.WriteString("  SCB detected"); Kernel.WriteLn
 END
END DetectMaxSCB;

PROCEDURE AllocateSCB(d: Host): LONGINT;
BEGIN
 ASSERT(d.allocated < 256);
 NEW(d.scb[d.allocated]); (*d.scb[d.allocated].tag := CHR(d.allocated);*)
 INC(d.allocated);
 RETURN d.allocated-1
END AllocateSCB;

PROCEDURE CalculateResidual(d: Host; index: LONGINT); (* aic7xxx_calc_residual *)
VAR sum: LONGINT;
BEGIN
 IF ~CBIT(d.hwscb[index].control, DISCONNECTED) THEN
  ASSERT(ORD(d.hwscb[index].resSGcnt) <= 1);
  sum := 10000H*ORD(d.hwscb[index].resDataCnt[2]) + 100H*ORD(d.hwscb[index].resDataCnt[1]) + 100H*ORD(d.hwscb[index].resDataCnt[0]);
  (*Kernel.WriteString("SG-Residual, "); Kernel.WriteInt(sum, 4); Kernel.WriteLn;*)
 END;
 d.hwscb[index].resSGcnt := 0X;
 d.hwscb[index].resDataCnt[2] := 0X;
 d.hwscb[index].resDataCnt[1] := 0X;
 d.hwscb[index].resDataCnt[0] := 0X;
END CalculateResidual;

PROCEDURE FreeCurScb(d: Host); (* aic7xxx_add_curscb_to_free_list *)
BEGIN
 d.Put1(d, SCBTAG, ScbNullSet);
 d.Put1(d, SCBCONTROL, {});
 d.Put1(d, SCBNEXT, d.Get1(d, FREESCBH));
 d.Put1(d, FREESCBH, d.Get1(d, SCBPTR))
END FreeCurScb;

PROCEDURE MatchScb(d: Host; index: LONGINT; target, channel, lun: LONGINT): BOOLEAN;
 (*aic7xxx_match_scb*)
VAR targ: LONGINT;
BEGIN
 targ := ORD(d.hwscb[index].targ);
 RETURN
 (((SYSTEM.LSH(targ, -4) MOD 16) = target) OR (target = AllTargets)) &
 (((SYSTEM.LSH(targ, -3) MOD 2) = channel) OR (channel = AllChannels)) &
 (((targ MOD 8) = lun) OR (lun = AllLuns))
END MatchScb;

PROCEDURE ScbOnQOutFifo(d: Host; index: LONGINT): BOOLEAN;
BEGIN
 HALT(Unimplemented)
END ScbOnQOutFifo;

PROCEDURE FreeScb(d: Host; index: LONGINT);
VAR scb: ScbData;
BEGIN
 IF TraceCalls IN Trace THEN  WriteHost(d); Kernel.WriteString("FreeScb"); Kernel.WriteHex(index, -3); Kernel.WriteLn  END;
 scb := d.scb[index];
 scb.flags := {ScbFree};
 scb.cmd.ptrToCmd := SYSTEM.VAL(LONGINT, NIL);
 d.hwscb[index].control := 0X;
 d.hwscb[index].status := 0X;
 d.hwscb[index].targ := ScbNull;
 SetEntry(d.freeList, index)
END FreeScb;

PROCEDURE Done(d: Host; index: LONGINT); (* aic7xxx_done *)
VAR t, dev: LONGINT; scb: ScbData;
BEGIN
 scb := d.scb[index];
 dev := scb.cmd.target + scb.cmd.chan*8;
 IF TraceCalls IN Trace THEN WriteDevice(d, dev); Kernel.WriteString("  Done")  END;
 
 IF ScbRecovery IN scb.flags THEN EXCL(d.flags, FlagAbortPending) END;
 IF (ScbReset IN scb.flags) OR (ScbAbort IN scb.flags) THEN
  scb.cmd.result := SCSI.Reset
 ELSIF ~(DeviceScanned IN d.dev[dev].flags) THEN
  INCL(d.dev[dev].flags, DeviceScanned)
 ELSIF scb.flags * {ScbMsgWidth, ScbMsgSync} # {} THEN
  IF ScbMsgWidth IN scb.flags THEN
   EXCL(d.widthPending, dev);
  END;
  IF  ScbMsgSync IN scb.flags THEN
   EXCL(d.syncPending, dev);
  END
 END;
 DEC(d.dev[dev].commandsActive);
 DEC(d.active);
 IF d.untagged[ORD(d.hwscb[dev].targ)] = d.hwscb[dev].tag THEN
  d.untagged[ORD(d.hwscb[dev].targ)] := ScbNull
 END;
 (* XXX here make statistics, now skipped *)
 t := scb.cmd.ptrToCmd;
 SYSTEM.PUT(t + 0, scb.cmd.status);  (*pass status/result to the command*)
 SYSTEM.PUT(t + 1, scb.cmd.result);
 IF TraceCalls IN Trace THEN Kernel.WriteInt(scb.cmd.status, 4); Kernel.WriteInt(scb.cmd.result, 4); Kernel.WriteLn  END;
 FreeScb(d, index);
 SYSTEM.PUT(t + 2, TRUE);
END Done;

PROCEDURE RunDoneQueue(d: Host);  (* aic7xxx_run_done_queue *)
VAR i: LONGINT;
BEGIN
 IF TraceCalls IN Trace THEN Kernel.WriteString("Adaptec7.RunDoneQueue"); Kernel.WriteLn  END;
 FOR i := 0 TO d.allocated-1 DO
  IF ScbQueuedForDone IN d.scb[i].flags THEN  Done(d, i)  END
 END;
END RunDoneQueue;

(* ========================================================================*)
(* ========================Reset/Init Functions================================*)
(* ========================================================================*)
PROCEDURE ResetChip(d: Host);
VAR s: SET; t: Kernel.MilliTimer; msg: ARRAY 64 OF CHAR;
BEGIN
 IF {TraceCalls, TraceReset} * Trace # {} THEN  WriteHost(d); Kernel.WriteString("ResetChip"); Kernel.WriteLn  END;
 d.Put1(d, HCNTRL, {PAUSE, CHIPRST});
 Kernel.SetTimer(t, 1000); (*1 sec*)
 WHILE ~Kernel.Expired(t) & ~(CHIPRST IN d.Get1(d, HCNTRL)) DO  END; (*wait 1 sec or till bit set*)
 Pause(d); (*pause, clear rst bit*)
 
 s := d.Get1(d, SBLKCTL) * {SELWIDE, SELBUSB};
 IF d IS PCIHost THEN  EXCL(s, SELBUSB)  END;
 
 IF s = {} THEN (*normal card*)
 ELSIF  {SELWIDE} = s  THEN  INCL(d.features, FeatWide);
 ELSIF  {SELBUSB} = s  THEN  INCL(d.features, FeatTwin);  INCL(d.flags, FlagMultiChannel)
 ELSE
  msg := "SELWIDE and SELBUSB set! Unknown card";
  HALT(99)
 END
END ResetChip;

PROCEDURE ResetDevice(d: Host; target, channel, lun: LONGINT);
VAR min, max, j, index, tcl: LONGINT; scb: ScbData; prev, next, active: SET; initLists: BOOLEAN;

 PROCEDURE RemoveCurrentFromList(d: Host;  list: LONGINT): SET;
 VAR prev, next: SET;
 BEGIN
  next := d.Get1(d, SCBNEXT);
  prev := d.Get1(d, SCBPREV);
  IF prev # ScbNullSet THEN
   d.Put1(d, SCBPTR, prev); d.Put1(d, SCBNEXT, next)
  ELSE
   d.Put1(d, list, next)
  END;
  RETURN next
 END RemoveCurrentFromList;

 (*PROCEDURE TraverseQueue(VAR queue: Queue);
 VAR p, q: ScbData; j: LONGINT;
 BEGIN
  j := 0; p := NIL; q := queue.head;
  WHILE (q # NIL) & (j < d.allocated) DO
   INC(j);
   IF MatchScb(d, ORD(q.tag), target, channel, lun) THEN
    IF p = NIL THEN  queue.head := q.next  ELSE  p.next := q.next  END;
    IF ScbWaitingQ IN q.flags THEN
     INC(d.dev[min].commandsActive);
     INC(d.active)
    END;
    q.flags := q.flags - {ScbActive, ScbWaitingQ} + {ScbReset, ScbQueuedForDone};
    q := q.next
   ELSE
    p := q; q := q.next
   END
  END;
  IF j > d.allocated THEN
   queue.Init;
   HALT(99);  (*where to with the scbs in delayed?*)
  END;
 END TraverseQueue;*)
 
BEGIN
 IF TraceBeta OR (TraceCalls IN Trace) THEN WriteDevice(d, target); Kernel.WriteString("  ResetDevice"); Kernel.WriteLn  END;
 active := d.Get1(d, SCBPTR);
 IF target = AllTargets THEN
  IF channel = 0 THEN
   min := 0;
   IF FeatWide IN d.features THEN max := 15 ELSE max := 7 END
  ELSIF channel = 1 THEN
   min := 8; max := 15
  ELSE
   min := 0;
   IF {FeatWide, FeatTwin} * d.features # {} THEN max := 15 ELSE max := 7 END
  END
 ELSE
  min := target;
  ASSERT(channel IN {0, 1});
  IF channel = 1 THEN  INC(min, 8)  END;  (*Bug? Here linux ORs the channel in the min!*)
  max := min
 END;
 WHILE min <= max DO
  EXCL(d.dev[min].flags, DeviceBusResetPending);
  j := 0; WHILE j < 8 DO
   ASSERT(channel IN {0, 1}, 130);
   IF channel=1 THEN
    tcl := (min MOD 8) * 16 + 8 + j
   ELSE
    tcl := min * 16 + j
   END;
   d.untagged[tcl] := ScbNull;
   INC(j)
  END;
  INC(min)
 END;
 
 j := 0;
 prev := ScbNullSet;  next := d.Get1(d, WAITINGSCBH);
 WHILE (next # ScbNullSet) & (j < d.allocated) DO
  INC(j);
  d.Put1(d, SCBPTR, next);
  index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
  IF index >= d.allocated THEN
   Kernel.WriteString("AIC7xxx: Wait List inconsistency!!"); Kernel.WriteLn;
   next := d.Get1(d, SCBNEXT);
   FreeCurScb(d)
  ELSE
   ASSERT(index = SYSTEM.VAL(LONGINT, next));
   scb := d.scb[index];
   IF MatchScb(d, index, target, channel, lun) THEN
    next := RemoveCurrentFromList(d, WAITINGSCBH);
    IF ScbWaitingQ IN scb.flags THEN
     INC(d.dev[scb.cmd.target + scb.cmd.chan*8].commandsActive);
     INC(d.active)
    END;
    scb.flags := scb.flags - {ScbActive, ScbWaitingQ} + {ScbReset, ScbQueuedForDone};
    IF prev = ScbNullSet THEN
     d.Put1(d, SCSISEQ, d.Get1(d, SCSISEQ) - {ENSELO});
     d.Put1(d, CLRSINT1, {CLRSELTIMEO})
    END
   ELSE
    prev := next; next := d.Get1(d, SCBNEXT)
   END
  END
 END;
 IF j > d.allocated THEN
  Kernel.WriteString("AIC7xxx: There is a loop in the wait list!!"); Kernel.WriteLn;
  initLists := TRUE
 END;
 
 IF FlagPageSCB IN d.features THEN
  j := 0;
  next := d.Get1(d, DISCONNECTEDSCBH);
  WHILE (next # ScbNullSet) & (j < d.allocated) DO
   INC(j);
   d.Put1(d, SCBPTR, next);
   index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
   IF index >= d.allocated THEN
    Kernel.WriteString("AIC7xxx: Disconnected List inconsistency!!"); Kernel.WriteLn;
    next := RemoveCurrentFromList(d, DISCONNECTEDSCBH)
   ELSE
    scb := d.scb[index];
    IF MatchScb(d, index, target, channel, lun) THEN
     next := RemoveCurrentFromList(d, DISCONNECTEDSCBH);
     IF ScbWaitingQ IN scb.flags THEN
      INC(d.dev[scb.cmd.target + scb.cmd.chan*8].commandsActive);
      INC(d.active)
     END;
     scb.flags := scb.flags - {ScbActive, ScbWaitingQ} + {ScbReset, ScbQueuedForDone};
     d.hwscb[index].control := 0X;
    ELSE
     next := d.Get1(d, SCBNEXT)
    END
   END
  END;
  IF j > d.allocated THEN
   Kernel.WriteString("AIC7xxx: There is a loop in the Disconnected list!!"); Kernel.WriteLn;
   initLists := TRUE
  END;
  
  j := 0;
  next := d.Get1(d, FREESCBH);
  IF (SYSTEM.VAL(LONGINT, next) >= d.allocated) & (next # ScbNullSet) THEN
   Kernel.WriteString("AIC7xxx: Bogus Free SCBH!!"); Kernel.WriteLn;
   initLists := TRUE;
   next := ScbNullSet
  END;
  WHILE (next # ScbNullSet) & (j < d.allocated) DO
   INC(j);
   d.Put1(d, SCBPTR, next);
   IF SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG)) >= d.allocated THEN
    Kernel.WriteString("AIC7xxx: FREE-SCBH List inconsistency!!"); Kernel.WriteLn;
    initLists := TRUE;
    next := ScbNullSet
   ELSE
    d.Put1(d, SCBTAG, ScbNullSet);
    d.Put1(d, SCBCONTROL, {});
    next := d.Get1(d, SCBNEXT)
   END
  END;
  IF j > d.allocated THEN
   Kernel.WriteString("AIC7xxx: There is a loop in the Free list!!"); Kernel.WriteLn;
   initLists := TRUE
  END 
 END;
 
 IF initLists THEN
  d.Put1(d, FREESCBH, ScbNullSet);
  d.Put1(d, WAITINGSCBH, ScbNullSet);
  d.Put1(d, DISCONNECTEDSCBH, ScbNullSet)
 END;
 
 FOR j := 0 TO 255 DO (* linux goes 255..0 here*)
  d.Put1(d, SCBPTR, SYSTEM.VAL(SET, j));
  IF initLists THEN
   d.Put1(d, SCBTAG, ScbNullSet);
   d.Put1(d, SCBNEXT, ScbNullSet);
   d.Put1(d, SCBPREV, ScbNullSet);
   d.Put1(d, SCBCONTROL, {})
  ELSE
   index := SYSTEM.VAL(LONGINT, d.Get1(d, SCBTAG));
   ASSERT(index = j); (* I'm just wondering.... this could be simplified*)
   IF index < d.allocated THEN
    IF MatchScb(d, index, target, channel, lun) THEN
     d.Put1(d, SCBCONTROL, {});
     d.Put1(d, SCBTAG, ScbNullSet);
     FreeCurScb(d)
    END
   END
  END
 END;
 
 FOR j := 0 TO d.allocated-1 DO
  scb := d.scb[j];
  IF (ScbActive IN scb.flags) & MatchScb(d, index, target, channel, lun) & ~ScbOnQOutFifo(d, index) THEN
   IF ScbWaitingQ IN scb.flags THEN
    INC(d.dev[scb.cmd.target + scb.cmd.chan*8].commandsActive);
    INC(d.active)
   END;
   scb.flags := scb.flags - {ScbActive, ScbWaitingQ} + {ScbReset, ScbQueuedForDone}
  END
 END;
 d.Put1(d, SCBPTR, active)
END ResetDevice;

PROCEDURE ResetBus(d: Host);  (* aic7xxx_reset_current_bus *)
BEGIN
 IF (TraceCalls IN Trace) OR (TraceReset IN Trace) THEN  WriteHost(d); Kernel.WriteString("ResetBus"); Kernel.WriteLn  END;
 d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) - {ENSCSIRST});
 d.Put1(d, SCSISEQ, d.Get1(d, SCSISEQ) + {SCSIRSTO});
 WHILE ~(SCSIRSTO IN d.Get1(d, SCSISEQ)) DO  Delay(5)  END;
 Delay(10);
 d.Put1(d, SCSISEQ, {});
 Delay(5);
 ClearIntStat(d);
 d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) + {ENSCSIRST})
END ResetBus;

PROCEDURE ResetChannel(d: Host; channel: LONGINT; reset: BOOLEAN); (* aic7xxx_reset_channel *)
VAR  min, max: LONGINT; sblkctl: SET; curChan: LONGINT;
BEGIN
 IF TraceCalls IN Trace THEN WriteHost(d); Kernel.WriteString("ResetChannel"); Kernel.WriteLn  END;
 min := 0;  max := d.nofTargets;
 IF channel = 1 THEN  min := 8  END;
 d.widthPending := d.widthPending - {min..max-1};
 d.syncPending := d.syncPending  - {min..max-1};
 WHILE min < max DO
  SetWidth(d, min, FALSE, {TransCur});
  SetPeriodOffset(d, min, 0, 0, {TransCur});
  INC(min)
 END;
 sblkctl := d.Get1(d, SBLKCTL);
 IF (d.chip = AIC7770) & (SELBUSB IN sblkctl) THEN  curChan := 1  ELSE curChan := 0  END;
 IF (curChan # channel) & (FeatTwin IN d.features) THEN
   (* Command for another bus is active *)
  d.Put1(d, SBLKCTL, sblkctl / {SELBUSB});
  d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) - {ENBUSFREE});
  IF reset THEN  ResetBus(d)  END;
  d.Put1(d, SCSISEQ, d.Get1(d, SCSISEQ) * {ENSELI, ENRSELI, ENAUTOATNP});
  ClearIntStat(d);
  d.Put1(d, SBLKCTL, sblkctl)
 ELSE
   (* A command from this bus is active or we're idle *)
  d.Put1(d, SIMODE1, d.Get1(d, SIMODE1) - {ENBUSFREE, ENREQINIT});
  EXCL(d.flags, FlagHandlingReqInits);
  d.msg.type := MsgTypeNone;
  d.msg.len := 0;
  IF reset THEN  ResetBus(d)  END;
  d.Put1(d, SCSISEQ, d.Get1(d, SCSISEQ) * {ENSELI, ENRSELI, ENAUTOATNP});
  ClearIntStat(d);
 END;
 ResetDevice(d, AllTargets, channel, AllLuns);
 IF ~(FeatTwin IN d.features) THEN  d.Put1(d, SEQCTL, {FASTMODE, SEQRESET})  END
END ResetChannel;

PROCEDURE ConfigureChannels(d: PCIHost);
BEGIN
 (*special setups for multichannel boards*)
 IF  FlagMultiChannel IN d.flags THEN
  CASE d.chip OF
  | AIC7870, AIC7880:
   IF d.slot = 5 THEN  INCL(d.flags, FlagChnlB)   (*3940, 3940Ultra*)
   ELSIF d.slot = 8 THEN INCL(d.flags, FlagChnlB)   (*3985, 3985Ultra*)
   ELSIF d.slot = 12 THEN INCL(d.flags, FlagChnlC)   (*3985, 3985Ultra*)
   END
  | AIC7895, AIC7896:
   IF d.devNo # 0 THEN  INCL(d.flags, FlagChnlB) END;
  END;
 END;
 (*set of DEVCONFIG.SCBSIZE32 for 7895 done in InitPCIHost*)
 
 (*load seeprom*)
 CASE d.chip OF
 | AIC7890, AIC7896:
  d.Put1(d, SCAMCTL, {});
  d.Put1(d, DSCOMMAND0, d.Get1(d, DSCOMMAND0)
   + {CACHETHEN, MPARCKEN, USCBSIZE32, CIOPARCKEN} - {DPARCKEN})
 | AIC7850, AIC7860:
  d.Put1(d, DSCOMMAND0, d.Get1(d, DSCOMMAND0)+ {CACHETHEN, MPARCKEN}- {DPARCKEN})
 ELSE
 END;
END ConfigureChannels;


PROCEDURE InitHost(d: Host);
VAR   t: SET; i: LONGINT;
BEGIN
 IF TraceCalls IN Trace THEN Kernel.WriteString("Adaptec7.InitHost"); Kernel.WriteLn  END;
 IF {FeatTwin, FeatWide} * d.features # {} THEN
  d.nofTargets := 8
 ELSE
  d.nofTargets := 16
 END;
 
 (* Implements aic7xxx_alloc and aic7xxx_register *)
 (* aic7xxx_alloc*)
 i := 0;  WHILE i < 256 DO
  d.hwscb[i].control := 0X;
  d.hwscb[i].tag := CHR(i);
  d.untagged[i] := ScbNull;
  d.out[i] := ScbNull;
  d.in[i] := ScbNull;
  INC(i)
 END;
 INCL(d.freeList[0], 0); (*allocate first SCB*)
 d.allocated := 0;  i := AllocateSCB(d);
 ASSERT(i = 0);
 
  (* aic7xxx_register *)
 d.intCount := 0;
 
 d.inNext := 0; d.outNext := 0;
 
 i := 0; WHILE i < 16 DO
  d.dev[i].flags := {};
  d.dev[i].commandsSent := 0;
  d.dev[i].commandsActive :=0;
  INC(i)
 END;
 
 d.Put1(d, SEQFLAGS, {});
 DetectMaxSCB(d);
 IF (FlagSeepromFound IN d.flags) & 
  ((FeatSpioCap IN d.features) & (SSPIOCPS IN d.Get1(d, SPIOCAP)) OR (d.chip >= AIC7870)) THEN
   ConfigureTermination(d)
 ELSIF 0 IN Ada7Hack THEN
  WriteHost(d); Kernel.WriteString("force auto-termination ");
  Kernel.WriteString("seeprom="); WriteBool(FlagSeepromFound IN d.flags);
  Kernel.WriteString(" SpioCap="); WriteBool(FeatSpioCap IN d.features);
  Kernel.WriteHex(SYSTEM.VAL(LONGINT, d.Get1(d, SPIOCAP)), 0);
  Kernel.WriteString(" chip = "); Kernel.WriteString(DChip[d.chip]);
  Kernel.WriteLn;
  ConfigureTermination(d)
 END;
 LoadSequencer(d);
 
 IF d.chip = AIC7770 THEN  d.Put1(d, BCTL, {ENABLE})  END;
 d.Put1(d, SBLKCTL, d.Get1(d, SBLKCTL) - {AUTOFLUSHDIS});
 ClearIntStat(d);
 
 (*Set SCSI ID, XCtrl0 XCtrl1, SIMODE1*)
 IF FeatTwin IN d.features THEN (*Channel B*)
  d.Put1(d, SBLKCTL, d.Get1(d, SBLKCTL) + {SELBUSB});
  d.Put1(d, SCSIID, SYSTEM.VAL(SET, d.scsiIdB));
  t := d.Get1(d, SCSICONF+1)*{ENSPCHK} + {ENSTIMER, ACTNEGEN};
  IF TermB IN d.termination THEN  INCL(t, STPWEN)  END;
  d.Put1(d, SXFRCTL0, {DFON, SPIOEN});
  d.Put1(d, SXFRCTL1, t);
  d.Put1(d, SIMODE0, {});
  d.Put1(d, SIMODE1, {ENSELTIMO, ENSCSIRST, ENSCSIPERR});
  d.Put1(d, SCSIRATE, {});
  d.Put1(d, SBLKCTL, d.Get1(d, SBLKCTL) - {SELBUSB});
 END;
 IF FeatUltra2 IN d.flags THEN
  d.Put1(d, SCSIIDULTRA2, SYSTEM.VAL(SET, d.scsiId))
 ELSE
  d.Put1(d, SCSIID, SYSTEM.VAL(SET, d.scsiId))
 END;
 t := d.Get1(d, SCSICONF)*{ENSPCHK} + {ENSTIMER, ACTNEGEN};
 IF TermSELow IN d.termination THEN  INCL(t, STPWEN)  END;
 d.Put1(d, SXFRCTL0, {DFON, SPIOEN});
 d.Put1(d, SXFRCTL1, t);
 IF TraceTermination IN Trace THEN WriteHost(d); WriteReg("SXFRCTL1", SYSTEM.VAL(CHAR, t)); Kernel.WriteLn END;
 d.Put1(d, SIMODE0, {});
 d.Put1(d, SIMODE1, {ENSELTIMO, ENSCSIRST, ENSCSIPERR});
 d.Put1(d, SCSIRATE, {});
 
 ASSERT(SYSTEM.ADR(d.hwscb[0]) MOD 32 = 0, 110);
 Put4(d, HSCBARRAY, SYSTEM.ADR(d.hwscb[0]));
 Put4(d, SCBIDADDR, SYSTEM.ADR(d.untagged[0]));
 d.Put1(d, QINPOS, {});
 d.Put1(d, KERNELQINPOS, {});
 d.Put1(d, QOUTPOS, {});
 
 IF FeatQueueRegs IN d.features THEN
  d.Put1(d, QOFFCTLSTA, SCBQSIZE256);
  d.Put1(d, SDSCBQOFF, {});
  d.Put1(d, SNSCBQOFF, {});
  d.Put1(d, HNSCBQOFF, {})
 END;
 
 d.Put1(d, WAITINGSCBH, ScbNullSet);
 d.Put1(d, DISCONNECTEDSCBH, ScbNullSet);
 
 d.Put1(d, MSGOUT, SYSTEM.VAL(SET, SCSI.MsgNoop));
 d.Put1(d, LASTMSG, SYSTEM.VAL(SET, SCSI.MsgNoop));
 
 Put4(d, TMODECMDADDR, 0);
 d.Put1(d, TMODECMDADDRNEXT, {});

 ClearIntStat(d);
 
  (*reset*)
 IF FeatTwin IN d.features THEN
  d.Put1(d, SBLKCTL, d.Get1(d, SBLKCTL) + {SELBUSB});
  ResetBus(d);
  d.Put1(d, SBLKCTL, d.Get1(d, SBLKCTL) - {SELBUSB});
 END;
 IF FeatUltra2 IN d.features THEN  Delay(250)  END;
 ResetBus(d);
 
 d.interruptable := TRUE;
 IF ~(d.irq IN InstalledIRQ) THEN
  IF InstalledIRQ = {} THEN  Kernel.InstallTermHandler(Cleanup)  END;
  INCL(InstalledIRQ, d.irq);
  Kernel.InstallIP(InterruptHandler, Kernel.IRQ+d.irq)
 END;
 Unpause(d)
END InitHost;



PROCEDURE InitPCIHost(d: PCIHost);
VAR res, dw, bus, dev, slot: LONGINT;
BEGIN
 bus:=d.busNo;  dev:=d.devNo;  slot:=d.slot;
 res:=PCI.ReadConfigByte(bus, dev, slot, PCI.IntlReg, dw); (*irq*)
 d.irq := SHORT(SHORT(dw MOD 100H));
 res:=PCI.ReadConfigDword(bus, dev, slot, PCI.Adr0Reg, dw); (*iobase*)
 d.iobase := dw - 1;
 res:=PCI.ReadConfigDword(bus, dev, slot, PCI.Adr1Reg, dw); (*memio*)
 IF dw = 0 THEN
  d.Put1 := PortPut;  d.Get1 := PortGet
 ELSE
  dw := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, dw) * {3..31}); (* clear io mode & 64 bits*)
  Kernel.MapPhysical(dw, 4*1024, d.membase);
(*
  WriteHost(d);  Kernel.WriteString(" map "); Kernel.WriteHex(dw, 8); Kernel.WriteString(" => ");
  Kernel.WriteHex(d.membase, 8); Kernel.WriteLn;
*)
  d.Put1 := MemoryPut;  d.Get1 := MemoryGet
 END;
 
 res:=PCI.ReadConfigWord(bus, dev, slot, PCI.CmdReg, dw); (*COMMAND*)
 dw := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, dw) + {8, 6, 4, 2, 1, 0}); (*Serren, Perren, Mwricen, Master, MSpace, ISpace*)
 res:=PCI.WriteConfigWord(bus, dev, slot, PCI.CmdReg, dw);
 
 res:=PCI.ReadConfigDword(bus, dev, slot, DEVCONFIG, dw);
 dw := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, dw) + {PCIERRGENDIS} - {BERREN});
 IF d.chip = AIC7895 THEN
  dw := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, dw) + {SCBSIZE32});
 END;
 res:=PCI.WriteConfigDword(bus, dev, slot, DEVCONFIG, dw);
 Pause(d);
 ClearPCIInt(d);
END InitPCIHost;

(* Scan PCI bus for host adapters *)

PROCEDURE DetectPCIHosts;
VAR  idx, bus, dev, slot, dw, res,  VenID, DevID: LONGINT;  host: PCIHost;  conf, s: SET;
 PROCEDURE Set(chip: SHORTINT; flags, features: SET; name: ARRAY OF CHAR; EpromSize, EpromType: SHORTINT);
 BEGIN
  NEW(host);
  host.flags := flags;  host.features := features;
  COPY(name, host.name);  host.submit := Execute;
  host.chip := chip;
  host.epromSize := EpromSize;  host.epromType := EpromType;
  host.busNo := bus;  host.devNo := dev;  host.slot := slot;
  host.interruptable := FALSE;
  host.next := HostRoot;  HostRoot := host
 END Set;
BEGIN
 idx := 0;
 WHILE PCI.Done = PCI.FindPCIClassCode(010000H (*scsi card*), idx, bus, dev, slot) DO
  res := PCI.ReadConfigWord(bus, dev, slot, PCI.DevReg, VenID);
  res := PCI.ReadConfigWord(bus, dev, slot, PCI.DevReg+2, DevID);
  host := NIL;
  IF (VenID = 9004H) & (DevID MOD 100H = 78H) THEN (* Adaptec, DevID = xx78H *)
   CASE DevID DIV 100H OF
   |  50H:  Set(AIC7850, {}, {FeatSpioCap}, "Adaptec AIC-7850", 32, C46);
   |  55H:  Set(AIC7850, {FlagPageSCB}, {FeatSpioCap}, "Adaptec AIC-7855", 32, C46);
   |  60H:  Set(AIC7860, {FlagPageSCB, FlagNewEepromFMT, FlagBiosEnabled}, {FeatUltra, FeatSpioCap}, 
        "Adaptec AIC-7860 Ultra", 32, C46);
   |  61H:  Set(AIC7860, {FlagPageSCB, FlagNewEepromFMT, FlagBiosEnabled}, {FeatUltra, FeatSpioCap},
        "Adaptec AHA-2940A Ultra", 32, C46);
   |  70H:  Set(AIC7870, {FlagPageSCB, FlagBiosEnabled}, {}, "Adaptec AIC-7870", 32, C46);
   |  71H:  Set(AIC7870, {FlagPageSCB, FlagBiosEnabled}, {}, "Adaptec AHA-294X", 32, C46);
   |  72H:  Set(AIC7870, {FlagPageSCB, FlagBiosEnabled, FlagMultiChannel}, {}, "Adaptec AHA-394X", 32, C56);
   |  73H:  Set(AIC7870, {FlagPageSCB, FlagBiosEnabled, FlagMultiChannel}, {}, "Adaptec AHA-398X", 32, C56);
   |  74H:  Set(AIC7870, {FlagPageSCB, FlagBiosEnabled}, {}, "Adaptec AHA-2944", 32, C46);
   |  80H:  Set(AIC7880, {FlagPageSCB, FlagBiosEnabled}, {FeatUltra}, "Adaptec AIC-7880 Ultra", 32, C46);
   |  81H:  Set(AIC7880, {FlagPageSCB, FlagBiosEnabled}, {FeatUltra}, "Adaptec AHA-294X Ultra", 32, C46);
   |  82H:  Set(AIC7880, {FlagPageSCB, FlagBiosEnabled, FlagMultiChannel}, {FeatUltra},
      "Adaptec AHA-394X Ultra", 32, C56);
   |  83H:  Set(AIC7880, {FlagPageSCB, FlagBiosEnabled, FlagMultiChannel}, {FeatUltra},
      "Adaptec AHA-398X Ultra", 32, C56);
   |  84H:  Set(AIC7880, {FlagPageSCB, FlagBiosEnabled}, {FeatUltra},"Adaptec AHA-2944 Ultra", 32, C46);
   ELSE
   END;
  ELSIF (VenID = 9004H) & (DevID = 7895H) THEN
   Set(AIC7895, {FlagPageSCB, FlagNewEepromFMT, FlagBiosEnabled, FlagMultiChannel},
        {FeatMoreSRAM, FeatUltra, FeatCmdChan}, "Adaptec AIC-7895 Ultra", 32, C56);
  ELSIF (VenID = 9005H) THEN (* Adaptec2 *)
   CASE DevID OF
   |  001FH:  Set(AIC7890, {FlagPageSCB, FlagNewEepromFMT, FlagBiosEnabled},
        {FeatMoreSRAM, FeatUltra2, FeatCmdChan, FeatQueueRegs, FeatSGPreload},
        "Adaptec AIC-7890/1 Ultra2", 32, C46);
   |  0010H:  Set(AIC7890, {FlagPageSCB, FlagNewEepromFMT, FlagBiosEnabled},
        {FeatMoreSRAM, FeatUltra2, FeatCmdChan, FeatQueueRegs, FeatSGPreload},
        "Adaptec AHA-294X Ultra2", 32, C46);
   |  005FH:  Set(AIC7896, {FlagPageSCB, FlagNewEepromFMT, FlagBiosEnabled, FlagMultiChannel},
        {FeatMoreSRAM, FeatUltra2, FeatCmdChan, FeatQueueRegs, FeatSGPreload},
        "Adaptec AIC-7896/7 Ultra2", 32, C56);
   |  0050H:  Set(AIC7896, {FlagPageSCB, FlagNewEepromFMT, FlagBiosEnabled, FlagMultiChannel},
        {FeatMoreSRAM, FeatUltra2, FeatCmdChan, FeatQueueRegs, FeatSGPreload},
        "Adaptec AHA-394X Ultra2", 32, C56);
   ELSE
   END;
  END;
  IF host # NIL THEN
   InitPCIHost(host);
   ResetChip(host);
   ConfigureChannels(host);
   ConfigHost(host);

   IF host.chip IN {AIC7895, AIC7896} THEN
    res := PCI.ReadConfigDword(bus, slot, dev, DEVCONFIG, dw);
    conf := SYSTEM.VAL(SET, dw);
    IF FeatUltra2 IN host.features THEN
     s := host.Get1(host, DSCOMMAND0);
     IF RAMPSMULTRA2 IN s THEN
      host.Put1(host, DSCOMMAND0, s - {SCBRAMSELULTRA2});
      INCL(host.flags, FlagExternalSRam);
      INCL(conf, EXTSCBPEN)
     END
    ELSIF RAMPSM IN conf THEN
     conf := conf + {SCBRAMSEL} - {EXTSCBPEN};
     INCL(host.flags, FlagExternalSRam)
    END;
    res := PCI.WriteConfigDword(bus, slot, dev, DEVCONFIG, SYSTEM.VAL(LONGINT, conf));
    IF host.flags * {FlagExternalSRam, FlagChnlB} # {} THEN  host.Put1(host, CCSCBBADDR, {0})  END
   END;
   
   host.Put1(host, SBLKCTL, host.Get1(host, SBLKCTL) - {DIAGLEDEN, DIAGLEDON});
   IF FeatUltra2 IN host.features THEN
    host.Put1(host, DFFTHRSH, WRDFFTHRSH75 + RDDFFTHRSH75)
   ELSE
    host.Put1(host, DSPCISTATUS, DFTHRSH100)
   END
  END;
  INC(idx)
 END (* FindClassCode *)
END DetectPCIHosts;


PROCEDURE Detect;
VAR  dummy, i: LONGINT;  host: Host;
BEGIN
 IF TraceCalls IN Trace THEN Kernel.WriteString("Adaptec7.Detect"); Kernel.WriteLn  END;
 
 IF PCI.Done = PCI.PCIPresent(dummy, dummy, dummy) THEN  DetectPCIHosts  END;
 
 (* Now Linux sorts the hosts. I won't do it, unless I find a good reason for it *)
 host := HostRoot;
 WHILE host # NIL DO
  IF Ada7ID # -1 THEN host.scsiId := SHORT(SHORT(Ada7ID)) END; (*override!!!*)
  IF TraceConfig IN Trace THEN
   WriteHost(host);
   Kernel.WriteString(DChip[host.chip]);
   Kernel.WriteString("  "); Kernel.WriteString(host.name); Kernel.WriteHex(host.membase, 9); Kernel.WriteLn;
   WriteHost(host); Kernel.WriteString("Features: ");
   FOR i := FeatUltra TO FeatSpioCap DO
    IF i IN host.features THEN Kernel.WriteString(DFeat[i]); Kernel.WriteString(" ")  END
   END; Kernel.WriteLn;
   WriteHost(host); Kernel.WriteString("Flags: ");
   FOR i := FlagPageSCB TO FlagExternalSRam DO
    IF i IN host.flags THEN  Kernel.WriteString(DFlag[i]); Kernel.WriteString(" ")  END
   END; Kernel.WriteLn;
   WriteHost(host); Kernel.WriteString("SCSI ID="); Kernel.WriteInt(host.scsiId, 0); Kernel.WriteLn;
  END;
  InitHost(host); host := host.next
 END;
 Delay(ResetDelay);
 host := HostRoot;
 WHILE host # NIL DO
  host.wide := FeatWide IN host.features;
  SCSI.RegisterDriver(host);  host := host.next
 END;
 ShowDevices
END Detect;

(* =========================================================================== *)
(* High level commands *)
(* =========================================================================== *)

(** Execute - schedule a scsi command for execution *)

PROCEDURE Execute*(sd: SCSI.Driver; VAR c: SCSI.CommandDesc); (* linux: aic7xxx_queue *)
VAR  index: LONGINT; target, dst: SHORTINT; scb: ScbData; d: Host; i: LONGINT; ch: CHAR;
BEGIN
 INC(Aexecute);
 d := sd(Host);  target := c.target;
 IF {TraceCalls, TraceCmds} * Trace # {} THEN
  WriteDevice(d, target); Kernel.WriteString("  -> Execute  ");
  i := 0;
  WHILE i < c.clen DO  SYSTEM.GET(c.cmd+i, ch); WriteChar(ch); Kernel.WriteChar(" "); INC(i)  END;
  Kernel.WriteLn;
 END;
 index := GetEntry(d.freeList);
 IF index = -1 THEN index := AllocateSCB(d) END;
 scb := d.scb[index];
  (*link tag to command*)
 c.done := FALSE;  c.status := SCSI.Good;  c.result := SCSI.OK;
 scb.cmd.target := target;  scb.cmd.lun := c.lun;  scb.cmd.status := c.status;
 scb.cmd.result := c.result;  scb.cmd.cmd := c.cmd;  scb.cmd.data := c.data;
 scb.cmd.ptrToCmd := SYSTEM.ADR(c);
  (*build hwscb*)
 d.hwscb[index].control := 0X;
 scb.flags := {};
 IF ConfFastEnable & (DeviceScanned IN d.dev[target].flags) & (c.lun = 0) & ~(target IN (d.widthPending+d.syncPending)) &
  (target IN (d.needWidthTrasm+d.needSyncTrasm))THEN
  IF (target IN d.needWidthTrasm) THEN
   INC(AwidthNegotiation);
   IF TraceMsg IN Trace THEN WriteDevice(d, target); Kernel.WriteString(" schedule width handling"); Kernel.WriteLn  END;
   EXCL(d.needWidthTrasm, target); INCL(d.widthPending, target); INCL(scb.flags, ScbMsgWidth)
  ELSIF (target IN d.needSyncTrasm) THEN
   INC(AsyncNegotiation);
   IF TraceMsg IN Trace THEN WriteDevice(d, target); Kernel.WriteString(" schedule sync handling"); Kernel.WriteLn  END;
   EXCL(d.needSyncTrasm, target); INCL(d.syncPending, target); INCL(scb.flags, ScbMsgSync)
  END;
  d.hwscb[index].control := SYSTEM.VAL(CHAR, {HwScbMessage});
 END;
 IF ConfDisconnectEnable & (target IN d.disconnect) THEN
  CSETBIT(d.hwscb[index].control, HwScbDiscEnable);
 END;
 d.hwscb[index].targ := CHR(SYSTEM.LSH(target MOD 16, 4)+SYSTEM.LSH(c.chan MOD 2, 3)+c.lun MOD 8);
 d.hwscb[index].cmdLen := CHR(c.clen);
 d.hwscb[index].cmdPtr := c.cmd;
 
 (* do not use scatter-gather list now, simplify*)
 d.hwscb[index].resSGcnt := 0X;
 IF c.dlen # 0 THEN
  d.hwscb[index].SGcnt := 1X;
  d.hwscb[index].SGptr := SYSTEM.ADR(c.data);
  d.hwscb[index].dataPtr := c.data;
  d.hwscb[index].dataCnt := c.dlen;
 ELSE
  d.hwscb[index].SGcnt := 0X;
  d.hwscb[index].SGptr := 0;
  d.hwscb[index].dataPtr := 0;
  d.hwscb[index].dataCnt := 0
 END;
 scb.flags := scb.flags + {ScbActive};
 
 dst := scb.cmd.target + scb.cmd.chan * 8;
 INC(d.dev[dst].commandsActive);
 ASSERT(d.dev[dst].commandsActive = 1);
 SYSTEM.CLI();
 d.untagged[ORD(d.hwscb[index].targ)] := CHR(index);  (*aic7xxx_busy_target*)
 IF TraceCmds IN Trace THEN
  Kernel.WriteString("SCB "); Kernel.WriteInt(index, 3);
  Kernel.WriteString(" -> in @ ");  Kernel.WriteInt(d.inNext, 3);  Kernel.WriteLn
 END;
 d.in[d.inNext] := CHR(index); d.inNext := (d.inNext+1) MOD 256;
 IF FeatQueueRegs IN d.features THEN
  d.Put1(d, HNSCBQOFF, SYSTEM.VAL(SET, d.inNext))
 ELSE
  Pause(d);
  d.Put1(d, KERNELQINPOS, SYSTEM.VAL(SET, d.inNext));
  Unpause(d)
 END;
 SYSTEM.STI();
 WHILE ~c.done DO END;
 IF {TraceCalls, TraceCmds} * Trace # {} THEN
  WriteDevice(d, target); Kernel.WriteString("  <- Execute  "); SYSTEM.GET(c.cmd, ch); WriteChar(ch);
  Kernel.WriteString("  with result "); Kernel.WriteInt(c.status, 2);
  Kernel.WriteLn;
 END;
END Execute;

(** Cleanup - Remove driver *)

PROCEDURE Cleanup*;
VAR i: SHORTINT; p: Host;
BEGIN
 p := HostRoot;
 WHILE p # NIL DO  SCSI.RemoveDriver(p);  p := p.next  END;
 FOR i := 0 TO 31 DO
  IF i IN InstalledIRQ THEN  Kernel.RemoveIP(InterruptHandler, Kernel.IRQ+i)  END
 END;
 InstalledIRQ := {}
END Cleanup;

(** Install the Disk upcalls. *)

PROCEDURE Install*;
BEGIN  SCSI.Install
END Install;

(* StrToInt - Convert a string to an integer *)

PROCEDURE StrToInt(s: ARRAY OF CHAR): LONGINT;
VAR i, j: SHORTINT;  v, sgn, m: LONGINT;
BEGIN
 j := 0;  WHILE s[j] # 0X DO INC(j) END;
 IF (j > 0) & (CAP(s[j-1]) = "H") THEN m := 16; DEC(j) ELSE m := 10 END;
 v := 0;  i := 0;
 IF s[i] = "-" THEN sgn := -1; INC(i) ELSE sgn := 1 END;
 WHILE i < j DO
  IF (s[i] >= "0") & (s[i] <= "9") THEN v := v*m + (ORD(s[i])-ORD("0"))
  ELSIF (CAP(s[i]) >= "A") & (CAP(s[i]) <= "F") THEN v := v*m + (ORD(CAP(s[i]))-ORD("A")+10)
  ELSE sgn := 0;  j := i
  END;
  INC(i)
 END;
 RETURN sgn*v
END StrToInt;

(* Init - Initialize module, read kernel configuration *)

PROCEDURE Init;
VAR str: ARRAY 32 OF CHAR;  s: SET;
BEGIN
 Kernel.GetConfig("Ada7Config", str); s := SYSTEM.VAL(SET, StrToInt(str));
 ConfDisconnectEnable := ~(ConfigNoDisconnection IN s);
 ConfFastEnable := ~(ConfigAllAsync IN s);
 IF s # {} THEN
  Kernel.WriteString("Adaptec7: Ada7Config = "); Kernel.WriteHex(SYSTEM.VAL(LONGINT, s),0); Kernel.WriteLn
 END;
 
 Kernel.GetConfig("Ada7Debug", str); Trace := SYSTEM.VAL(SET, StrToInt(str));
 IF Trace # {} THEN
  Kernel.WriteString("Adaptec7: Ada7Debug = "); Kernel.WriteHex(SYSTEM.VAL(LONGINT, Trace),0); Kernel.WriteLn
 END;
 
 Kernel.GetConfig("Ada7ResetDelay", str); ResetDelay := StrToInt(str);
 IF ResetDelay = 0 THEN  ResetDelay := 1000  END;
 Kernel.WriteString("Adaptec7: Ada7ResetDelay = "); Kernel.WriteInt(ResetDelay, 0); Kernel.WriteLn;

 Kernel.GetConfig("Ada7Hack", str); Ada7Hack := SYSTEM.VAL(SET, StrToInt(str));
 IF Ada7Hack # {} THEN
  Kernel.WriteString("Ada7Hack = "); Kernel.WriteHex(SYSTEM.VAL(LONGINT, Ada7Hack), 0); Kernel.WriteLn
 END;
 
 Kernel.GetConfig("Ada7ID", str);
 IF str="" THEN Ada7ID := -1 ELSE Ada7ID := StrToInt(str) END;
 (*
  rates 0, 1 are only for ultra2 cards
  rates 1, 2, 3 (rate) only for ultra cards
 *)
 RateTable[0].period := 10;  RateTable[0].rate := 0FFX;  RateTable[0].u2rate := 13X;
 RateTable[1].period := 11;  RateTable[1].rate := 0FFX;  RateTable[1].u2rate := 14X;
 RateTable[2].period := 12;  RateTable[2].rate := 00X;  RateTable[2].u2rate := 15X;
 RateTable[3].period := 15;  RateTable[3].rate := 10X;  RateTable[3].u2rate := 16X;
 RateTable[4].period := 18;  RateTable[4].rate := 20X;  RateTable[4].u2rate := 17X;
 RateTable[5].period := 25;  RateTable[5].rate := 00X;  RateTable[5].u2rate := 18X;
 RateTable[6].period := 31;  RateTable[6].rate := 10X;  RateTable[6].u2rate := 19X;
 RateTable[7].period := 37;  RateTable[7].rate := 20X;  RateTable[7].u2rate := 1AX;
 RateTable[8].period := 43;  RateTable[8].rate := 30X;  RateTable[8].u2rate := 1BX;
 RateTable[9].period := 50;  RateTable[9].rate := 40X;  RateTable[9].u2rate := 1CX;
 RateTable[10].period := 56;  RateTable[10].rate := 50X;  RateTable[10].u2rate := 0FFX;
 RateTable[11].period := 62;  RateTable[11].rate := 60X;  RateTable[11].u2rate := 0FFX;
 RateTable[12].period := 68;  RateTable[12].rate := 70X;  RateTable[12].u2rate := 0FFX;
END Init;

BEGIN
 Kernel.WriteString("Adaptec7 - 0.9.6.4 / prk"); Kernel.WriteLn;
 InstalledIRQ := {};
 HostRoot := NIL;
 Init;
 (*debug trace*)
 (* ProgTools.DebugList DFlag ^ *)
 DFlag[FlagPageSCB] := "PageSCB";
 DFlag[FlagNewEepromFMT] := "NewEepromFMT";
 DFlag[FlagBiosEnabled] := "BiosEnabled";
 DFlag[FlagMultiChannel] := "MultiChannel";
 DFlag[FlagChnlB] := "ChnlB";
 DFlag[FlagChnlC] := "ChnlC";
 DFlag[FlagSeepromFound] := "SeepromFound";
 DFlag[FlagChannelBPrimary] := "ChannelBPrimary";
 DFlag[FlagExtendTransA] := "ExtendTransA";
 DFlag[FlagExternalSRam] := "ExternalSRam";
 DFlag[FlagHandlingReqInits] := "HandlingReqInits";
 
 (* ProgTools.DebugList DFeat ^ *)
 DFeat[FeatUltra] := "Ultra";
 DFeat[FeatUltra2] := "Ultra2";
 DFeat[FeatWide] := "Wide";
 DFeat[FeatTwin] := "Twin";
 DFeat[FeatMoreSRAM] := "MoreSRAM";
 DFeat[FeatCmdChan] := "CmdChan";
 DFeat[FeatQueueRegs] := "QueueRegs";
 DFeat[FeatSGPreload] := "SGPreload";
 DFeat[FeatSpioCap] := "SpioCap";
 
 (* ProgTools.DebugList DDev ^ *)
 DDev[DevicePresent] := "DevicePresent";
 DDev[DeviceBusResetPending] := "DeviceBusResetPending";
 DDev[DeviceTimeout] := "DeviceTimeout";
 DDev[DeviceSuccess] := "DeviceSuccess";
 DDev[DeviceScanned] := "DeviceScanned";

 (* ProgTools.DebugList DChip ^ *)
 DChip[AIC7770] := "AIC7770";
 DChip[AIC7850] := "AIC7850";
 DChip[AIC7860] := "AIC7860";
 DChip[AIC7870] := "AIC7870";
 DChip[AIC7880] := "AIC7880";
 DChip[AIC7890] := "AIC7890";
 DChip[AIC7895] := "AIC7895";
 DChip[AIC7896] := "AIC7896";

 (* ProgTools.DebugList DTerm ^ *)
 DTerm[TermAuto] := "TermAuto";
 DTerm[TermS] := "TermS";
 DTerm[TermSW] := "TermSW";
 DTerm[TermSEAuto] := "TermSEAuto";
 DTerm[TermSLvd] := "TermSLvd";
 DTerm[TermA] := "TermA";
 DTerm[TermB] := "TermB";
 DTerm[TermSELow] := "TermSELow";
 DTerm[TermSEHigh] := "TermSEHigh";
 
 DIntName[00H] := "BadPhase";
 DIntName[01H] := "SendReject";
 DIntName[02H] := "NoIdent";
 DIntName[03H] := "NoMatch";
 DIntName[04H] := "ExtendedMsg";
 DIntName[05H] := "AbortRequested";
 DIntName[06H] := "RejectMsg";
 DIntName[07H] := "BadStatus";
 DIntName[08H] := "Residual";
 DIntName[0AH] := "AwaitingMsg";
 DIntName[0BH] := "TracePoint1";
 DIntName[0CH] := "TracePoint2";
 DIntName[0DH] := "MsgInPhaseMis";
 DIntName[0EH] := "DataOverrun";

 ASSERT((SIZE(SCSI.DriverDesc) + RecordPadding) MOD 32 = 0, 110);
 
 Detect;
 Install
END Adaptec71.


AIC7xxx.Invariant

-- init
AIC7xxx.Detect

-- debug
AIC7xxx.DList  Dump the device list
AIC7xxx.DState

AIC7xxx.Cleanup

System.Free AIC7xxx AIC7xxxScript ~