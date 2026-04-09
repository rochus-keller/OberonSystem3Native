MODULE EMMCDisks; (** non-portable *)
(** 
 * BCM2835/2836 EMMC (SDHCI) SD card driver for Raspberry Pi 2/3.
 * Implements the Disks.Device interface for block read/write.
 *
 * Based on jncronin/rpi-boot emmc.c (MIT license) and the
 * BCM2835 ARM Peripherals Guide.
 *
 * Uses polling (no DMA, no interrupts) for simplicity.
 * QEMU raspi2b emulates the BCM2835 SDHCI controller.
 *
 * Register base: 0x3F300000 (RPi 2/3 peripheral space)
 *
 * (c) 2026 Rochus Keller <mailto:me@rochus-keller.ch>
 *
 * GNU General Public License Usage
 * This file may be used under the terms of the GNU General Public
 * License (GPL) versions 2.0 or 3.0 as published by the Free Software
 * Foundation and appearing in the file LICENSE.GPL included in
 * the packaging of this file. Please review the following information
 * to ensure GNU General Public Licensing requirements will be met:
 * http://www.fsf.org/licensing/licenses/info/GPLv2.html and
 * http://www.gnu.org/copyleft/gpl.html.
 *)

IMPORT SYSTEM, Kernel, Disks;

CONST
  Header = "EMMCDisks: ";
  BS = 512;  (** SD block size in bytes *)

  (** EMMC register offsets from base *)
  oARG2        = 0;
  oBLKSIZECNT  = 4;
  oARG1        = 8;
  oCMDTM       = 12;
  oRESP0       = 16;
  oRESP1       = 20;
  oRESP2       = 24;
  oRESP3       = 28;
  oDATA        = 32;
  oSTATUS      = 36;
  oCONTROL0    = 40;
  oCONTROL1    = 44;
  oINTERRUPT   = 48;
  oIRPTMASK   = 52;
  oIRPTEN     = 56;
  oCONTROL2    = 60;
  oSLOTISRVER = 252;

  (** Command register bit fields *)
  (* SD_CMD_INDEX(a) = a << 24 *)
  CMDISDATA     = 2097152;   (* 1 << 21 *)
  CMDIXCHKEN   = 1048576;   (* 1 << 20 *)
  CMDCRCCHKEN  = 524288;    (* 1 << 19 *)
  CMDRSPNSNONE = 0;
  CMDRSPNS136  = 65536;     (* 1 << 16 *)
  CMDRSPNS48   = 131072;    (* 2 << 16 *)
  CMDRSPNS48B  = 196608;    (* 3 << 16 *)
  CMDRSPNSMASK = 196608;    (* 3 << 16 *)
  CMDMULTIBLOCK = 32;       (* 1 << 5 *)
  CMDDATDIRCH = 16;        (* 1 << 4, card-to-host = read *)
  CMDBLKCNTEN  = 2;         (* 1 << 1 *)
  CMDTYPEABORT = 12582912;  (* 3 << 22 *)

  (** Interrupt flags *)
  INTCMDDONE   = 1;         (* 1 << 0 *)
  INTDATADONE  = 2;         (* 1 << 1 *)
  INTWRITERDY  = 16;        (* 1 << 4 *)
  INTREADRDY   = 32;        (* 1 << 5 *)
   INTERR        = 32768;     (* 1 << 15 *)

  (* Pre-built command register values for common SD commands 
   CMD0  = GO_IDLE_STATE: no response 
   CMD2  = ALL_SEND_CID: R2 response (136-bit) 
   CMD3  = SEND_RELATIVE_ADDR: R6 response 
   CMD7  = SELECT_CARD: R1b response 
   CMD8  = SEND_IF_COND: R7 response 
   CMD12 = STOP_TRANSMISSION: R1b + abort 
   CMD13 = SEND_STATUS: R1 response 
   CMD16 = SET_BLOCKLEN: R1 response 
   CMD17 = READ_SINGLE_BLOCK: R1 + data read 
   CMD18 = READ_MULTIPLE_BLOCK: R1 + data read + multi + blkcnt 
   CMD24 = WRITE_BLOCK: R1 + data write 
   CMD25 = WRITE_MULTIPLE_BLOCK: R1 + data write + multi + blkcnt 
   CMD55 = APP_CMD: R1 response 
   ACMD41 = SD_SEND_OP_COND: R3 response (no CRC check) 
   ACMD6  = SET_BUS_WIDTH: R1 response *)

  MaxRetries = 3;
  CmdTimeout = 500000;    (** busy-wait iterations for command complete *)
  DataTimeout = 5000000;  (** busy-wait iterations for data transfer *)

TYPE
  Device = POINTER TO RECORD (Disks.DeviceDesc)
    cardRCA: LONGINT;       (** relative card address, upper 16 bits *)
    sdhc: BOOLEAN;          (** card supports SDHC (block addressing) *)
    cardSize: LONGINT;      (** device size in 512-byte blocks *)
    lastR0: LONGINT;        (** last response R0 *)
    lastR1: LONGINT;
    lastR2: LONGINT;
    lastR3: LONGINT;
    lastError: LONGINT;     (** last error interrupt bits *)
    lastSuccess: BOOLEAN;
  END;

VAR
  emmcBase: LONGINT;       (** EMMC register base address *)
  dev0: Device;            (** the single SD device *)
  partOffset: LONGINT;     (** block offset to AOS partition (0 = whole disk) *)


(** Read a 32-bit word from an absolute memory address. *)
PROCEDURE -GetWord(adr: LONGINT): LONGINT;
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  LDR R0, [R0, #0]
END GetWord;

(** Write a 32-bit word to an absolute memory address. *)
PROCEDURE -PutWord(adr, val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #4]
  LDR R1, [SP, #0]
  STR R1, [R0, #0]
END PutWord;

PROCEDURE ReadReg(offset: LONGINT): LONGINT;
BEGIN
  RETURN GetWord(emmcBase + offset)
END ReadReg;

PROCEDURE WriteReg(offset, val: LONGINT);
BEGIN
  PutWord(emmcBase + offset, val)
END WriteReg;

(** Simple busy-wait delay.  count ~ microseconds on QEMU (approximate). *)
PROCEDURE Delay(count: LONGINT);
VAR i: LONGINT;
BEGIN
  i := 0;
  WHILE i < count DO INC(i) END
END Delay;


(** Build command register value for a given SD command index.
  cmdIdx: 0..63
  Returns: cmdIdx << 24 *)
PROCEDURE CmdIndex(cmdIdx: LONGINT): LONGINT;
BEGIN
  RETURN cmdIdx * 1000000H  (* << 24 *)
END CmdIndex;

(** Build a complete command register word for standard SD commands. *)
PROCEDURE BuildCmdReg(cmdIdx: LONGINT): LONGINT;
VAR reg: LONGINT;
BEGIN
  reg := CmdIndex(cmdIdx);
  (* Set response type and flags based on command *)
  IF cmdIdx = 0 THEN
    (* CMD0: no response *)
  ELSIF cmdIdx = 2 THEN
    (* CMD2: R2, 136-bit with CRC *)
    reg := reg + CMDRSPNS136 + CMDCRCCHKEN
  ELSIF cmdIdx = 3 THEN
    (* CMD3: R6, 48-bit with CRC *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN
  ELSIF cmdIdx = 7 THEN
    (* CMD7: R1b, 48-bit busy with CRC *)
    reg := reg + CMDRSPNS48B + CMDCRCCHKEN
  ELSIF cmdIdx = 8 THEN
    (* CMD8: R7, 48-bit with CRC *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN
  ELSIF cmdIdx = 12 THEN
    (* CMD12: R1b + abort *)
    reg := reg + CMDRSPNS48B + CMDCRCCHKEN + CMDTYPEABORT
  ELSIF cmdIdx = 13 THEN
    (* CMD13: R1, 48-bit with CRC *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN
  ELSIF cmdIdx = 16 THEN
    (* CMD16: R1 *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN
  ELSIF cmdIdx = 17 THEN
    (* CMD17: R1 + single block read *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN + CMDISDATA + CMDDATDIRCH
  ELSIF cmdIdx = 18 THEN
    (* CMD18: R1 + multi block read *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN + CMDISDATA + CMDDATDIRCH
        + CMDMULTIBLOCK + CMDBLKCNTEN
  ELSIF cmdIdx = 24 THEN
    (* CMD24: R1 + single block write *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN + CMDISDATA
  ELSIF cmdIdx = 25 THEN
    (* CMD25: R1 + multi block write *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN + CMDISDATA
        + CMDMULTIBLOCK + CMDBLKCNTEN
  ELSIF cmdIdx = 41 THEN
    (* ACMD41: R3, 48-bit, no CRC check *)
    reg := reg + CMDRSPNS48
  ELSIF cmdIdx = 55 THEN
    (* CMD55: R1, 48-bit with CRC *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN
  ELSIF cmdIdx = 6 THEN
    (* ACMD6: R1, 48-bit with CRC *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN
  ELSE
    (* Default: R1 *)
    reg := reg + CMDRSPNS48 + CMDCRCCHKEN
  END;
  RETURN reg
END BuildCmdReg;

(* Issue a raw command to the EMMC controller (polling).
  cmdReg: pre-built CMDTM register value
  arg: command argument
  Sets dev.lastSuccess, dev.lastR0..R3, dev.lastError *)
PROCEDURE IssueCommandInt(d: Device; cmdReg, arg: LONGINT);
VAR irpts, rspType, timeout: LONGINT;
    isData, isWrite: BOOLEAN;
BEGIN
  d.lastSuccess := FALSE;
  d.lastError := 0;

  (* Wait for Command Inhibit (CMD) to clear *)
  timeout := CmdTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oSTATUS)) * {0} # {}) DO
    DEC(timeout)
  END;
  IF timeout = 0 THEN
    Kernel.WriteString(Header); Kernel.WriteString("CMD inhibit timeout"); Kernel.WriteLn;
    RETURN
  END;

  (* Check if busy response and wait for DAT inhibit *)
  rspType := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, cmdReg) * SYSTEM.VAL(SET, CMDRSPNSMASK));
  IF rspType = CMDRSPNS48B THEN
    (* Wait for DAT line to be free, unless abort command *)
    IF SYSTEM.VAL(SET, cmdReg) * SYSTEM.VAL(SET, CMDTYPEABORT) = {} THEN
      timeout := CmdTimeout;
      WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oSTATUS)) * {1} # {}) DO
        DEC(timeout)
      END
    END
  END;

  (* Set block size and count for data commands *)
  isData := SYSTEM.VAL(SET, cmdReg) * SYSTEM.VAL(SET, CMDISDATA) # {};
  IF isData THEN
    (* block size = 512, count = 1 (set by caller for multi-block) *)
  END;

  (* Write argument *)
  WriteReg(oARG1, arg);

  (* Write command register - this starts the command *)
  WriteReg(oCMDTM, cmdReg);

  Delay(2000);

  (* Wait for command complete or error *)
  timeout := CmdTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oINTERRUPT)) * {0, 15} = {}) DO
    DEC(timeout)
  END;
  irpts := ReadReg(oINTERRUPT);

  (* Clear command complete status *)
  WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFF0001H)));

  (* Check for errors *)
  IF SYSTEM.VAL(SET, irpts) * {0} = {} THEN
    (* No command complete - timeout or error *)
    d.lastError := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, irpts) * SYSTEM.VAL(SET, 0FFFF0000H));
    RETURN
  END;
  IF SYSTEM.VAL(SET, irpts) * {15} # {} THEN
    (* Error flag set *)
    d.lastError := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, irpts) * SYSTEM.VAL(SET, 0FFFF0000H));
    RETURN
  END;

  Delay(2000);

  (* Read response *)
  rspType := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, cmdReg) * SYSTEM.VAL(SET, CMDRSPNSMASK));
  IF (rspType = CMDRSPNS48) OR (rspType = CMDRSPNS48B) THEN
    d.lastR0 := ReadReg(oRESP0)
  ELSIF rspType = CMDRSPNS136 THEN
    d.lastR0 := ReadReg(oRESP0);
    d.lastR1 := ReadReg(oRESP1);
    d.lastR2 := ReadReg(oRESP2);
    d.lastR3 := ReadReg(oRESP3)
  END;

  (* For data commands, handle data transfer via PIO in the caller 
    For busy responses without data, wait for transfer complete *)
  IF (rspType = CMDRSPNS48B) & ~isData THEN
    (* Wait for transfer complete *)
    IF SYSTEM.VAL(SET, ReadReg(oSTATUS)) * {1} # {} THEN
      timeout := DataTimeout;
      WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oINTERRUPT)) * {1, 15} = {}) DO
        DEC(timeout)
      END;
      irpts := ReadReg(oINTERRUPT);
      WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFF0002H)));
      IF SYSTEM.VAL(SET, irpts) * {1} = {} THEN
        d.lastError := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, irpts) * SYSTEM.VAL(SET, 0FFFF0000H));
        RETURN
      END
    ELSE
      WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFF0002H)))
    END
  END;

  d.lastSuccess := TRUE
END IssueCommandInt;

(* Issue a standard SD command (handles APP_CMD prefix for ACMD). *)
PROCEDURE IssueCommand(d: Device; cmd, arg: LONGINT);
VAR rca: LONGINT;
BEGIN
  IF cmd >= 100 THEN
    (* Application command: send CMD55 first, then ACMD(cmd - 100) *)
    rca := 0;
    IF d.cardRCA # 0 THEN rca := d.cardRCA END;
    IssueCommandInt(d, BuildCmdReg(55), rca);
    IF d.lastSuccess THEN
      IssueCommandInt(d, BuildCmdReg(cmd - 100), arg)
    END
  ELSE
    IssueCommandInt(d, BuildCmdReg(cmd), arg)
  END
END IssueCommand;



(* Get a clock divider for the target rate.
  Returns the divider value to OR into CONTROL1. *)
PROCEDURE GetClockDivider(baseClock, targetRate: LONGINT): LONGINT;
VAR divisor, freqSel, upperBits, bit, i: LONGINT;
BEGIN
  IF targetRate >= baseClock THEN
    divisor := 0
  ELSE
    divisor := baseClock DIV targetRate;
    IF baseClock MOD targetRate > 0 THEN
      (* Round up to next power of 2 *)
    END;
    (* Find highest bit set *)
    i := 31;
    WHILE (i >= 0) & (SYSTEM.VAL(SET, divisor) * SYSTEM.VAL(SET, ASH(1, i)) = {}) DO
      DEC(i)
    END;
    IF i < 0 THEN i := 0 END;
    (* Check if divisor is exact power of 2 *)
    IF SYSTEM.VAL(SET, divisor) * SYSTEM.VAL(SET, divisor - 1) # {} THEN
      INC(i)  (* not power of 2, round up *)
    END;
    IF i > 0 THEN
      divisor := ASH(1, i - 1)
    ELSE
      divisor := 0
    END;
    IF divisor > 3FFH THEN divisor := 3FFH END
  END;
  freqSel := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, divisor) * SYSTEM.VAL(SET, 0FFH));
  upperBits := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(divisor, -8)) * SYSTEM.VAL(SET, 3));
  RETURN ASH(freqSel, 8) + ASH(upperBits, 6)
END GetClockDivider;

(* Switch the SD clock rate. *)
PROCEDURE SwitchClockRate(baseClock, targetRate: LONGINT): BOOLEAN;
VAR divider, control1, timeout: LONGINT;
BEGIN
  divider := GetClockDivider(baseClock, targetRate);

  (* Wait for CMD and DAT inhibit to clear *)
  timeout := CmdTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oSTATUS)) * {0, 1} # {}) DO
    DEC(timeout)
  END;

  (* Disable SD clock *)
  control1 := ReadReg(oCONTROL1);
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) - {2});  (* clear bit 2 *)
  WriteReg(oCONTROL1, control1);
  Delay(2000);

  (* Write new divider *)
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) - SYSTEM.VAL(SET, 0FFE0H));  (* clear old divider *)
  control1 := control1 + divider;
  WriteReg(oCONTROL1, control1);
  Delay(2000);

  (* Re-enable SD clock *)
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) + {2});
  WriteReg(oCONTROL1, control1);
  Delay(2000);

  RETURN TRUE
END SwitchClockRate;



(* Reset the CMD line after an error. *)
PROCEDURE ResetCmd(): BOOLEAN;
VAR control1, timeout: LONGINT;
BEGIN
  control1 := ReadReg(oCONTROL1);
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) + {25});  (* SD_RESET_CMD = 1 << 25 *)
  WriteReg(oCONTROL1, control1);
  timeout := CmdTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oCONTROL1)) * {25} # {}) DO
    DEC(timeout)
  END;
  RETURN SYSTEM.VAL(SET, ReadReg(oCONTROL1)) * {25} = {}
END ResetCmd;

(* Initialize the EMMC controller and SD card.
  Returns TRUE on success. *)
PROCEDURE InitCard(d: Device): BOOLEAN;
VAR control1, ver, sdVer, status, timeout: LONGINT;
    fid, baseClock: LONGINT;
    v2Later, cardBusy: BOOLEAN;
    v2Flags, acmd41Arg, cmd3Resp: LONGINT;
    blkCnt: LONGINT;
    ok: BOOLEAN;
BEGIN
  emmcBase := 3F300000H;  (* BCM2835/2836 EMMC controller base *)

  (* Read controller version *)
  ver := ReadReg(oSLOTISRVER);
  sdVer := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(ver, -16)) * SYSTEM.VAL(SET, 0FFH));
  Kernel.WriteString(Header); Kernel.WriteString("SDHCI version ");
  Kernel.WriteInt(sdVer, 1); Kernel.WriteLn;

  (* Reset the controller *)
  control1 := ReadReg(oCONTROL1);
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) + {24});  (* reset all *)
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) - {2});   (* disable clock *)
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) - {0});   (* disable internal clock *)
  WriteReg(oCONTROL1, control1);

  (* Wait for reset to complete *)
  timeout := 1000000;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oCONTROL1)) * {24, 25, 26} # {}) DO
    DEC(timeout)
  END;
  IF timeout = 0 THEN
    Kernel.WriteString(Header); Kernel.WriteString("reset timeout"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Assume base clock is 100 MHz (typical for QEMU and RPi) *)
  (* baseClock := 100000000; works on rpi3b, fails on zero2 *)
  (* Set to half of the Pi 3/Zero2 actual 400MHz core_freq *)
  (* This perfectly aligns the driver's math with the hardware's 2*N divider *)
  baseClock := 200000000;

  (* Set clock to 400 kHz identification frequency *)
  control1 := ReadReg(oCONTROL1);
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) + {0});  (* enable internal clock *)
  fid := GetClockDivider(baseClock, 400000);
  control1 := control1 + fid;
  control1 := control1 + ASH(7, 16);  (* data timeout = TMCLK * 2^10 *)
  WriteReg(oCONTROL1, control1);

  (* Wait for clock to stabilize *)
  timeout := 1000000;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oCONTROL1)) * {1} = {}) DO
    DEC(timeout)
  END;
  IF timeout = 0 THEN
    Kernel.WriteString(Header); Kernel.WriteString("clock unstable"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Enable SD clock *)
  Delay(2000);
  control1 := ReadReg(oCONTROL1);
  control1 := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, control1) + {2});
  WriteReg(oCONTROL1, control1);
  Delay(2000);

  (* Disable interrupt signaling to ARM, reset pending, enable status *)
  WriteReg(oIRPTEN, 0);
  WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFFFFFFH)));
  (* Enable all interrupts in IRPT_MASK except card interrupt (bit 8) *)
  WriteReg(oIRPTMASK, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFFFEFFH)));
  Delay(2000);



  (* CMD0: GO_IDLE_STATE *)
  IssueCommand(d, 0, 0);
  IF ~d.lastSuccess THEN
    Kernel.WriteString(Header); Kernel.WriteString("CMD0 failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* CMD8: SEND_IF_COND - voltage check *)
  v2Later := FALSE;
  IssueCommand(d, 8, 1AAH);
  IF d.lastSuccess THEN
    IF SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, d.lastR0) * SYSTEM.VAL(SET, 0FFFH)) = 1AAH THEN
      v2Later := TRUE
    ELSE
      Kernel.WriteString(Header); Kernel.WriteString("unusable card"); Kernel.WriteLn;
      RETURN FALSE
    END
  ELSE
    (* CMD8 timeout is normal for v1.x cards *)
    ok := ResetCmd();
    WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 10000H)));  (* clear CMD_TIMEOUT *)
    v2Later := FALSE
  END;

  (* ACMD41: SD_SEND_OP_COND - wait for card ready 
     First, inquiry ACMD41 with voltage window = 0 *)
  IssueCommand(d, 141, 0);  (* 141 = 100 + 41 = ACMD41 *)
  IF ~d.lastSuccess THEN
    Kernel.WriteString(Header); Kernel.WriteString("ACMD41 inquiry failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Now loop ACMD41 until card is ready *)
  cardBusy := TRUE;
  WHILE cardBusy DO
    v2Flags := 0;
    IF v2Later THEN
      v2Flags := 40000000H  (* SDHC support = bit 30 *)
    END;
    acmd41Arg := 0FF8000H + v2Flags;  (* voltage window + flags *)
    IssueCommand(d, 141, acmd41Arg);
    IF ~d.lastSuccess THEN
      Kernel.WriteString(Header); Kernel.WriteString("ACMD41 failed"); Kernel.WriteLn;
      RETURN FALSE
    END;
    IF SYSTEM.VAL(SET, d.lastR0) * {31} # {} THEN
      (* Card is ready *)
      d.sdhc := SYSTEM.VAL(SET, d.lastR0) * {30} # {};
      cardBusy := FALSE
    ELSE
      Delay(500000)
    END
  END;

  IF d.sdhc THEN
    Kernel.WriteString(Header); Kernel.WriteString("SDHC card detected"); Kernel.WriteLn
  ELSE
    Kernel.WriteString(Header); Kernel.WriteString("SDSC card detected"); Kernel.WriteLn
  END;

  (* CMD2: ALL_SEND_CID *)
  IssueCommand(d, 2, 0);
  IF ~d.lastSuccess THEN
    Kernel.WriteString(Header); Kernel.WriteString("CMD2 failed"); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* CMD3: SEND_RELATIVE_ADDR *)
  IssueCommand(d, 3, 0);
  IF ~d.lastSuccess THEN
    Kernel.WriteString(Header); Kernel.WriteString("CMD3 failed"); Kernel.WriteLn;
    RETURN FALSE
  END;
  cmd3Resp := d.lastR0;
  d.cardRCA := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(cmd3Resp, -16)) * SYSTEM.VAL(SET, 0FFFFH));
  d.cardRCA := ASH(d.cardRCA, 16);  (* store RCA in upper 16 bits for CMD7/CMD13 *)

  (* Switch clock to 25 MHz normal mode; do this here so it also works with older SD cards *)
  ok := SwitchClockRate(baseClock, 25000000);
  Delay(5000);

  (* CMD7: SELECT_CARD *)
  IssueCommand(d, 7, d.cardRCA);
  IF ~d.lastSuccess THEN
    Kernel.WriteString(Header); Kernel.WriteString("CMD7 failed"); Kernel.WriteLn;
    RETURN FALSE
  END;
  status := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(d.lastR0, -9)) * SYSTEM.VAL(SET, 0FH));
  IF (status # 3) & (status # 4) THEN
    Kernel.WriteString(Header); Kernel.WriteString("bad card state "); Kernel.WriteInt(status, 1); Kernel.WriteLn;
    RETURN FALSE
  END;

  (* Set block size to 512 *)
  IF ~d.sdhc THEN
    IssueCommand(d, 16, 512);
    IF ~d.lastSuccess THEN
      Kernel.WriteString(Header); Kernel.WriteString("SET_BLOCKLEN failed"); Kernel.WriteLn;
      RETURN FALSE
    END
  END;

  (* Set controller block size register *)
  blkCnt := ReadReg(oBLKSIZECNT);
  blkCnt := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, blkCnt) - SYSTEM.VAL(SET, 0FFFH));
  blkCnt := blkCnt + 200H;  (* 512 bytes *)
  WriteReg(oBLKSIZECNT, blkCnt);

  (* Reset interrupt register *)
  WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFFFFFFH)));

  Kernel.WriteString(Header); Kernel.WriteString("card initialized OK"); Kernel.WriteLn;
  RETURN TRUE
END InitCard;



PROCEDURE EnsureDataMode(d: Device): BOOLEAN;
VAR status, curState, timeout: LONGINT;
BEGIN
  IF d.cardRCA = 0 THEN RETURN FALSE END;

  (* Send CMD13 to get status *)
  IssueCommand(d, 13, d.cardRCA);
  IF ~d.lastSuccess THEN
    RETURN FALSE
  END;

  curState := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(d.lastR0, -9)) * SYSTEM.VAL(SET, 0FH));

  IF curState = 3 THEN
    (* Stand-by: select card *)
    IssueCommand(d, 7, d.cardRCA);
    IF ~d.lastSuccess THEN RETURN FALSE END
  ELSIF curState = 5 THEN
    (* Data transfer in progress: stop *)
    IssueCommand(d, 12, 0);
    IF ~d.lastSuccess THEN RETURN FALSE END
  ELSIF curState # 4 THEN
    (* Not in transfer state *)
    RETURN FALSE
  END;

  RETURN TRUE
END EnsureDataMode;



(* Read a single block from the SD card.
  blockNo: block number (512-byte blocks)
  VAR buf: destination buffer
  ofs: byte offset in buf to write to
  Returns 0 on success, nonzero on error. *)
PROCEDURE ReadBlock(d: Device; blockNo: LONGINT; VAR buf: ARRAY OF CHAR; ofs: LONGINT): LONGINT;
VAR cmdReg, arg, irpts, timeout: LONGINT;
    i, word, byteVal: LONGINT;
BEGIN
  (* For SDSC, convert block address to byte address *)
  IF d.sdhc THEN arg := blockNo
  ELSE arg := blockNo * BS
  END;

  (* Set block size and count *)
  WriteReg(oBLKSIZECNT, 200H + ASH(1, 16));  (* 512 bytes, 1 block *)

  (* Issue CMD17 (READ_SINGLE_BLOCK) *)
  IssueCommandInt(d, BuildCmdReg(17), arg);
  IF ~d.lastSuccess THEN RETURN 1 END;

  (* Wait for buffer read ready *)
  timeout := DataTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oINTERRUPT)) * {5, 15} = {}) DO
    DEC(timeout)
  END;
  irpts := ReadReg(oINTERRUPT);
  WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFF0000H)) + INTREADRDY);

  IF SYSTEM.VAL(SET, irpts) * {5} = {} THEN
    (* Read ready not set *)
    RETURN 2
  END;
  IF SYSTEM.VAL(SET, irpts) * {15} # {} THEN
    RETURN 3
  END;

  (* Read 512 bytes (128 words) from DATA register *)
  i := 0;
  WHILE i < BS DO
    word := ReadReg(oDATA);
    buf[ofs + i] := CHR(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, word) * SYSTEM.VAL(SET, 0FFH)));
    buf[ofs + i + 1] := CHR(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(word, -8)) * SYSTEM.VAL(SET, 0FFH)));
    buf[ofs + i + 2] := CHR(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(word, -16)) * SYSTEM.VAL(SET, 0FFH)));
    buf[ofs + i + 3] := CHR(SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, ASH(word, -24)) * SYSTEM.VAL(SET, 0FFH)));
    INC(i, 4)
  END;

  (* Wait for transfer complete *)
  timeout := DataTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oINTERRUPT)) * {1, 15} = {}) DO
    DEC(timeout)
  END;
  irpts := ReadReg(oINTERRUPT);
  WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFF0002H)));

  IF SYSTEM.VAL(SET, irpts) * {1} = {} THEN
    RETURN 4
  END;
  RETURN 0
END ReadBlock;



(* Write a single block to the SD card. *)
PROCEDURE WriteBlock(d: Device; blockNo: LONGINT; VAR buf: ARRAY OF CHAR; ofs: LONGINT): LONGINT;
VAR cmdReg, arg, irpts, timeout: LONGINT;
    i, word, b0, b1, b2, b3: LONGINT;
BEGIN
  IF d.sdhc THEN arg := blockNo
  ELSE arg := blockNo * BS
  END;

  WriteReg(oBLKSIZECNT, 200H + ASH(1, 16));

  (* Issue CMD24 (WRITE_BLOCK) *)
  IssueCommandInt(d, BuildCmdReg(24), arg);
  IF ~d.lastSuccess THEN RETURN 1 END;

  (* Wait for buffer write ready *)
  timeout := DataTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oINTERRUPT)) * {4, 15} = {}) DO
    DEC(timeout)
  END;
  irpts := ReadReg(oINTERRUPT);
  WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFF0000H)) + INTWRITERDY);

  IF SYSTEM.VAL(SET, irpts) * {4} = {} THEN RETURN 2 END;
  IF SYSTEM.VAL(SET, irpts) * {15} # {} THEN RETURN 3 END;

  (* Write 512 bytes (128 words) to DATA register *)
  i := 0;
  WHILE i < BS DO
    b0 := ORD(buf[ofs + i]);
    b1 := ORD(buf[ofs + i + 1]);
    b2 := ORD(buf[ofs + i + 2]);
    b3 := ORD(buf[ofs + i + 3]);
    word := b0 + ASH(b1, 8) + ASH(b2, 16) + ASH(b3, 24);
    WriteReg(oDATA, word);
    INC(i, 4)
  END;

  (* Wait for transfer complete *)
  timeout := DataTimeout;
  WHILE (timeout > 0) & (SYSTEM.VAL(SET, ReadReg(oINTERRUPT)) * {1, 15} = {}) DO
    DEC(timeout)
  END;
  irpts := ReadReg(oINTERRUPT);
  WriteReg(oINTERRUPT, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, 0FFFF0002H)));

  IF SYSTEM.VAL(SET, irpts) * {1} = {} THEN RETURN 4 END;

  RETURN 0
END WriteBlock;



(* Transfer blocks to/from the SD card.
  op: Disks.Read or Disks.Write
  block: starting block number (512-byte blocks)
  num: number of blocks
  data: buffer
  ofs: byte offset in data
  res: result code (0 = ok) *)
PROCEDURE Transfer(dev: Disks.Device; op, block, num: LONGINT; VAR data: ARRAY OF CHAR; ofs: LONGINT; VAR res: LONGINT);
VAR d: Device; i, r, physBlock: LONGINT;
BEGIN
  d := dev(Device);
  IF ~EnsureDataMode(d) THEN res := 1; RETURN END;

  res := Disks.Ok;
  i := 0;
  WHILE (i < num) & (res = Disks.Ok) DO
    physBlock := partOffset + block + i;
    IF op = Disks.Read THEN
      r := ReadBlock(d, physBlock, data, ofs + i * BS)
    ELSIF op = Disks.Write THEN
      r := WriteBlock(d, physBlock, data, ofs + i * BS)
    ELSE
      r := -1
    END;
    IF r # 0 THEN
      res := r
    END;
    INC(i)
  END
END Transfer;

(** Return device size in 512-byte blocks. *)
PROCEDURE GetSize(dev: Disks.Device; VAR size, res: LONGINT);
VAR d: Device;
BEGIN
  d := dev(Device);
  size := d.cardSize;
  res := Disks.Ok
END GetSize;

(** Handle optional device messages. *)
PROCEDURE Handle(dev: Disks.Device; VAR msg: Disks.Message; VAR res: LONGINT);
BEGIN
  res := Disks.Unsupported
END Handle;

(** ---- MBR Partition Detection ---- *)

(** Detect an AOS partition by reading the MBR (sector 0).
  If a valid MBR signature (55AAH) is found, scan the four partition
  table entries for the first non-FAT, non-empty partition and set
  partOffset to its start LBA.
  If no MBR is found, partOffset remains 0 (whole disk = AOS). *)
PROCEDURE DetectPartition(d: Device);
VAR mbr: ARRAY 512 OF CHAR;
    r, i, ptype, lba: LONGINT;
    ofs: LONGINT;
BEGIN
  partOffset := 0;
  r := ReadBlock(d, 0, mbr, 0);
  IF r # 0 THEN
    Kernel.WriteString(Header); Kernel.WriteString("MBR read failed, using whole disk"); Kernel.WriteLn;
    RETURN
  END;

  (* Check MBR signature: bytes 510=55H, 511=AAH *)
  IF (ORD(mbr[510]) # 55H) OR (ORD(mbr[511]) # 0AAH) THEN
    Kernel.WriteString(Header); Kernel.WriteString("no MBR found, using whole disk"); Kernel.WriteLn;
    RETURN
  END;

  (* Scan 4 partition entries at offsets 446, 462, 478, 494 *)
  i := 0;
  WHILE i < 4 DO
    ofs := 446 + i * 16;
    ptype := ORD(mbr[ofs + 4]);
    IF (ptype # 0) (* not empty *)
      & (ptype # 1) & (ptype # 4) & (ptype # 6)   (* not FAT12/16 *)
      & (ptype # 0BH) & (ptype # 0CH) & (ptype # 0EH)  (* not FAT32/LBA *)
      & (ptype # 0EEH)  (* not GPT protective *)
    THEN
      (* LBA start at bytes 8..11 of the entry (little-endian) *)
      lba := ORD(mbr[ofs + 8]) + ASH(ORD(mbr[ofs + 9]), 8)
          + ASH(ORD(mbr[ofs + 10]), 16) + ASH(ORD(mbr[ofs + 11]), 24);
      IF lba > 0 THEN
        partOffset := lba;
        Kernel.WriteString(Header); Kernel.WriteString("AOS partition at LBA ");
        Kernel.WriteInt(partOffset, 1); Kernel.WriteLn;
        RETURN
      END
    END;
    INC(i)
  END;

  Kernel.WriteString(Header); Kernel.WriteString("no AOS partition found, using whole disk"); Kernel.WriteLn
END DetectPartition;



PROCEDURE Init;
VAR ok: BOOLEAN;
BEGIN
  partOffset := 0;
  NEW(dev0);
  Disks.InitDevice(dev0, "SD0");
  dev0.desc := "BCM2835 EMMC SD card";
  dev0.cardRCA := 0;
  dev0.sdhc := FALSE;
  dev0.cardSize := 0;
  dev0.lastR0 := 0; dev0.lastR1 := 0; dev0.lastR2 := 0; dev0.lastR3 := 0;
  dev0.lastError := 0;
  dev0.lastSuccess := FALSE;

  ok := InitCard(dev0);
  IF ok THEN
    (* Detect AOS partition from MBR before registering *)
    DetectPartition(dev0);

    (* Try to determine card size.
       For now, report a large size; the filesystem layer will
       use only what it needs from the partition table or boot block. *)
    dev0.cardSize := 2000000;  (* ~1GB in 512-byte blocks *)
    dev0.blockSize := BS;
    dev0.flags := {};
    dev0.transfer := Transfer;
    dev0.getSize := GetSize;
    dev0.handle := Handle;
    Disks.Register(dev0);
    Kernel.WriteString(Header); Kernel.WriteString("SD0 registered"); Kernel.WriteLn
  ELSE
    Kernel.WriteString(Header); Kernel.WriteString("init failed, no device registered"); Kernel.WriteLn
  END
END Init;

BEGIN
  Init
END EMMCDisks.
