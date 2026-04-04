MODULE DisplayLinear; 

(* 
 Linear framebuffer display driver for Oberon System 3 on Raspberry Pi 2/3.

 Uses the BCM2835 mailbox property tag interface (channel 8) to request
 a framebuffer from the VideoCore GPU.  Replaces the i386 VESA/V86-based
 driver with ARM-native MMIO mailbox calls.
 The following code is a synthesis from these sources:
 https://github.com/bztsrc/raspi3-tutorial/tree/master/09_framebuffer
 https://github.com/BrianSidebotham/arm-tutorial-rpi/tree/master/part-5
 https://github.com/s-matyukevich/raspberry-pi-os
 
 (c) 2026 Rochus Keller <mailto:me@rochus-keller.ch>

 GNU General Public License Usage
 This file may be used under the terms of the GNU General Public
 License (GPL) versions 2.0 or 3.0 as published by the Free Software
 Foundation and appearing in the file LICENSE.GPL included in
 the packaging of this file. Please review the following information
 to ensure GNU General Public Licensing requirements will be met:
 http://www.fsf.org/licensing/licenses/info/GPLv2.html and
 http://www.gnu.org/copyleft/gpl.html.
*)

IMPORT SYSTEM, Kernel, Displays, Modules;

CONST
  Header = "DisplayLinear: ";

  (* BCM2835 mailbox register base (RPi 2/3 peripheral space) *)
  MboxBase   = 3F00B880H;
  MboxRead   = 0;       (* offset: read register *)
  MboxStatus = 18H;     (* offset: status register *)
  MboxWrite  = 20H;     (* offset: write register *)
  MboxFull   = 80000000H;  (* status bit: mailbox full *)
  MboxEmpty  = 40000000H;  (* status bit: mailbox empty *)
  MboxChanProp = 8;     (* property tags channel *)

  (* Mailbox property tag IDs *)
  TagGetPhysWH  = 40003H;   (* Get physical display width/height *)
  TagGetDepth   = 40005H;   (* Get depth (bits per pixel) *)
  TagSetPhysWH  = 48003H;   (* Set physical display width/height *)
  TagSetVirtWH  = 48004H;   (* Set virtual display width/height *)
  TagSetDepth   = 48005H;   (* Set depth (bits per pixel) *)
  TagSetPixOrd  = 48006H;   (* Set pixel order (0=BGR, 1=RGB) *)
  TagAllocBuf   = 40001H;   (* Allocate framebuffer *)
  TagGetPitch   = 40008H;   (* Get pitch (bytes per line) *)
  TagEnd        = 0;

  BufWords = 36;  (* number of 32-bit words in our mailbox message buffer *)
  QBufWords = 12; (* number of 32-bit words in the query message buffer *)

TYPE
  Display = OBJECT (Displays.Display)
  END Display;

VAR
  display: Display;
  (* 64-byte aligned mailbox message buffer to prevent cache line false sharing *)
  mbufRaw: ARRAY BufWords * 4 + 64 OF CHAR;



(* Read a 32-bit word from an absolute memory address. *)
PROCEDURE -GetWord(adr: LONGINT): LONGINT;
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  LDR R0, [R0, #0]
  ADD SP, SP, #4
END GetWord;

(* Write a 32-bit word to an absolute memory address. *)
PROCEDURE -PutWord(adr, val: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #4]
  LDR R1, [SP, #0]
  STR R1, [R0, #0]
  ADD SP, SP, #8
END PutWord;

(* Data Synchronization Barrier.
  DSB SY = 0xF57FF04F *)
PROCEDURE -DSB;
CODE {SYSTEM.arm}
  DCW 0F04FH, 0F57FH
END DSB;

(* Data Memory Barrier.
  DMB SY = 0xF57FF05F *)
PROCEDURE -DMB;
CODE {SYSTEM.arm}
  DCW 0F05FH, 0F57FH
END DMB;

(* Clean and Invalidate Data Cache line by MVA to PoC
  MCR p15, 0, R0, c7, c14, 1 = 0xEE070F3E *)
PROCEDURE -CleanAndInvalidateDCache(adr: LONGINT);
CODE {SYSTEM.arm}
  LDR R0, [SP, #0]
  DCW 00F3EH, 0EE07H
END CleanAndInvalidateDCache;

(* Flush data cache range to ensure ARM/GPU memory coherence *)
PROCEDURE FlushDCache(adr, size: LONGINT);
VAR end: LONGINT;
BEGIN
  end := adr + size;
  WHILE adr < end DO
    CleanAndInvalidateDCache(adr);
    INC(adr, 32) (* Cortex-A53 cache line is 64 bytes, stepping by 32 is safe *)
  END;
  DSB
END FlushDCache;

(* Convert ARM physical address to VideoCore bus address (OR 0xC0000000) *)
PROCEDURE GetBusAdr(adr: LONGINT): LONGINT;
BEGIN
  RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, adr) + {30, 31})
END GetBusAdr;


(* Write a message to the mailbox.
  data: 32-bit address of message buffer
  channel: 0..15 *)
PROCEDURE MboxWriteMsg(data, channel: LONGINT);
BEGIN
  DMB;
  (* Wait until mailbox is not full *)
  WHILE SYSTEM.VAL(SET, GetWord(MboxBase + MboxStatus)) * SYSTEM.VAL(SET, MboxFull) # {} DO END;
  (* Write data | channel *)
  PutWord(MboxBase + MboxWrite, SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) + SYSTEM.VAL(SET, channel)));
  DMB
END MboxWriteMsg;

(* Read from the mailbox for a given channel.
  Returns the upper 28 bits of the response. *)
PROCEDURE MboxReadMsg(channel: LONGINT): LONGINT;
VAR data: LONGINT;
BEGIN
  LOOP
    DMB;
    (* Wait until mailbox is not empty *)
    WHILE SYSTEM.VAL(SET, GetWord(MboxBase + MboxStatus)) * SYSTEM.VAL(SET, MboxEmpty) # {} DO END;
    (* Read data *)
    data := GetWord(MboxBase + MboxRead);
    DMB;
    (* Check if it is for our channel *)
    IF SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) * {0..3}) = channel THEN
      RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, data) - SYSTEM.VAL(SET, data) * {0..3})
    END
    (* else: wrong channel, try again *)
  END
END MboxReadMsg;



PROCEDURE StrToInt(VAR i: LONGINT; VAR s: ARRAY OF CHAR): LONGINT;
VAR vd, vh, sgn, d: LONGINT; hex: BOOLEAN;
BEGIN
  vd := 0; vh := 0; hex := FALSE;
  IF s[i] = "-" THEN sgn := -1; INC(i) ELSE sgn := 1 END;
  LOOP
    IF (s[i] >= "0") & (s[i] <= "9") THEN d := ORD(s[i]) - ORD("0")
    ELSIF (CAP(s[i]) >= "A") & (CAP(s[i]) <= "F") THEN d := ORD(CAP(s[i])) - ORD("A") + 10; hex := TRUE
    ELSE EXIT
    END;
    vd := 10*vd + d; vh := 16*vh + d;
    INC(i)
  END;
  IF CAP(s[i]) = "H" THEN hex := TRUE; INC(i) END;
  IF hex THEN vd := vh END;
  RETURN sgn * vd
END StrToInt;

PROCEDURE GetVal(name: ARRAY OF CHAR; default: LONGINT): LONGINT;
VAR v: LONGINT; s: ARRAY 12 OF CHAR; p: LONGINT;
BEGIN
  Kernel.GetConfig(name, s);
  IF s[0] = 0X THEN
    v := default
  ELSE
    p := 0; v := StrToInt(p, s)
  END;
  RETURN v
END GetVal;



PROCEDURE Install*;
BEGIN
  IF display # NIL THEN Displays.main := display END
END Install;



(* Query the GPU for the current physical display size and depth.
  The GPU firmware negotiates these from EDID (if HDMI connected) or config.txt.
  Returns TRUE if valid dimensions were returned. *)
PROCEDURE QueryDisplay(VAR w, h, d: LONGINT): BOOLEAN;
VAR mbuf, resp: LONGINT; i: LONGINT;
  qbufRaw: ARRAY QBufWords * 4 + 64 OF CHAR;
BEGIN
  mbuf := SYSTEM.ADR(qbufRaw[0]);
  (* Align to 64-byte cache line boundary *)
  mbuf := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, mbuf + 63) - {0..5});

  i := 0;
  PutWord(mbuf + i, QBufWords * 4); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);

  (* Tag: Get physical width/height *)
  PutWord(mbuf + i, TagGetPhysWH); INC(i, 4);
  PutWord(mbuf + i, 8); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);

  (* Tag: Get depth *)
  PutWord(mbuf + i, TagGetDepth); INC(i, 4);
  PutWord(mbuf + i, 4); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);

  (* End tag *)
  PutWord(mbuf + i, TagEnd); INC(i, 4);

  (* Flush ARM Data Cache to ensure RAM matches buffer *)
  FlushDCache(mbuf, QBufWords * 4);

  (* Write using the VideoCore Bus Address alias *)
  MboxWriteMsg(GetBusAdr(mbuf), MboxChanProp);
  resp := MboxReadMsg(MboxChanProp);

  (* Invalidate cache to ensure CPU reads fresh VideoCore response from RAM *)
  FlushDCache(mbuf, QBufWords * 4);

  resp := GetWord(mbuf + 4);
  IF resp # SYSTEM.VAL(LONGINT, 80000000H) THEN RETURN FALSE END;

  w := GetWord(mbuf + 8 + 12);
  h := GetWord(mbuf + 8 + 16);
  d := GetWord(mbuf + 28 + 12);

  RETURN (w > 0) & (h > 0) & (d > 0)
END QueryDisplay;



PROCEDURE InitFB(VAR w, h, d: LONGINT; VAR adr, size, pitch: LONGINT): BOOLEAN;
VAR mbuf, resp: LONGINT; i: LONGINT;
BEGIN
  (* Align to 64-byte cache line boundary *)
  mbuf := SYSTEM.ADR(mbufRaw[0]);
  mbuf := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, mbuf + 63) - {0..5});

  (* Build mailbox property tag message buffer *)
  i := 0;
  PutWord(mbuf + i, BufWords * 4); INC(i, 4);
  (* Word 1: request code = 0 *)
  PutWord(mbuf + i, 0); INC(i, 4);

  (* Tag: Set physical width/height *)
  PutWord(mbuf + i, TagSetPhysWH); INC(i, 4);
  PutWord(mbuf + i, 8); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, w); INC(i, 4);
  PutWord(mbuf + i, h); INC(i, 4);

  (* Tag: Set virtual width/height *)
  PutWord(mbuf + i, TagSetVirtWH); INC(i, 4);
  PutWord(mbuf + i, 8); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, w); INC(i, 4);
  PutWord(mbuf + i, h); INC(i, 4);

  (* Tag: Set depth *)
  PutWord(mbuf + i, TagSetDepth); INC(i, 4);
  PutWord(mbuf + i, 4); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, d); INC(i, 4);

  (* Tag: Set pixel order = RGB *)
  PutWord(mbuf + i, TagSetPixOrd); INC(i, 4);
  PutWord(mbuf + i, 4); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, 1); INC(i, 4);

  (* Tag: Allocate framebuffer *)
  PutWord(mbuf + i, TagAllocBuf); INC(i, 4);
  PutWord(mbuf + i, 8); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, 16); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);

  (* Tag: Get pitch *)
  PutWord(mbuf + i, TagGetPitch); INC(i, 4);
  PutWord(mbuf + i, 4); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);
  PutWord(mbuf + i, 0); INC(i, 4);

  (* End tag *)
  PutWord(mbuf + i, TagEnd); INC(i, 4);

  (* Flush ARM Data Cache to ensure RAM matches buffer *)
  FlushDCache(mbuf, BufWords * 4);

  (* Send the message via mailbox channel 8 using VC Bus Address *)
  MboxWriteMsg(GetBusAdr(mbuf), MboxChanProp);

  (* Read the response *)
  resp := MboxReadMsg(MboxChanProp);

  (* Invalidate cache to ensure CPU reads fresh VideoCore response from RAM *)
  FlushDCache(mbuf, BufWords * 4);

  (* Check response code at word 1 *)
  resp := GetWord(mbuf + 4);
  IF resp # SYSTEM.VAL(LONGINT, 80000000H) THEN
    Kernel.WriteString(Header); Kernel.WriteString("mailbox failed, code=");
    Kernel.WriteHex(resp, 8); Kernel.WriteLn;
    RETURN FALSE
  END;
  
  (* RPi can override the requested dimensions/depth based on config.txt limits or defaults. *)
  w := GetWord(mbuf + 8 + 12);
  h := GetWord(mbuf + 8 + 16);
  d := GetWord(mbuf + 48 + 12);

  (* Parse AllocBuf response at offset 80 *)
  adr := GetWord(mbuf + 80 + 12);
  size := GetWord(mbuf + 80 + 16);

  (* Convert GPU bus address to ARM physical address *)
  adr := SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, adr) * {0..29});

  (* Get pitch at offset 100 *)
  pitch := GetWord(mbuf + 100 + 12);

  RETURN (adr # 0) & (size > 0)
END InitFB;



PROCEDURE GetStr(name: ARRAY OF CHAR; VAR s: ARRAY OF CHAR);
BEGIN Kernel.GetConfig(name, s)
END GetStr;

PROCEDURE Init;
VAR w, h, d, f, mem, adr, size, pitch: LONGINT;
  mode: ARRAY 12 OF CHAR; autoDetect: BOOLEAN;
BEGIN
  GetStr("DMode", mode);
  autoDetect := (mode[0] = "*");

  IF autoDetect THEN
    Kernel.WriteString(Header); Kernel.WriteString("auto-detecting display..."); Kernel.WriteLn;
    IF QueryDisplay(w, h, d) THEN
      Kernel.WriteString(Header); Kernel.WriteString("detected ");
      Kernel.WriteInt(w, 0); Kernel.WriteChar("x");
      Kernel.WriteInt(h, 0); Kernel.WriteChar("x");
      Kernel.WriteInt(d, 0); Kernel.WriteLn
    ELSE
      Kernel.WriteString(Header); Kernel.WriteString("auto-detect failed, using defaults"); Kernel.WriteLn;
      w := 1024; h := 768; d := 16
    END
  ELSE
    w := GetVal("DWidth", 1024);
    h := GetVal("DHeight", 768);
    d := GetVal("DDepth", 16)
  END;

  Kernel.WriteString(Header); Kernel.WriteString("requesting ");
  Kernel.WriteInt(w, 0); Kernel.WriteChar("x");
  Kernel.WriteInt(h, 0); Kernel.WriteChar("x");
  Kernel.WriteInt(d, 0); Kernel.WriteLn;

  IF InitFB(w, h, d, adr, size, pitch) THEN
    Kernel.WriteString(Header); Kernel.WriteString("FB at ");
    Kernel.WriteHex(adr, 8); Kernel.WriteString(" size ");
    Kernel.WriteInt(size, 0); Kernel.WriteString(" pitch ");
    Kernel.WriteInt(pitch, 0); Kernel.WriteLn;
    
    Kernel.WriteString(Header); Kernel.WriteString("negotiated ");
    Kernel.WriteInt(w, 0); Kernel.WriteChar("x");
    Kernel.WriteInt(h, 0); Kernel.WriteChar("x");
    Kernel.WriteInt(d, 0); Kernel.WriteLn;

    CASE d OF
      8:  f := Displays.index8
      |16: f := Displays.color565
      |24: f := Displays.color888
      |32: f := Displays.color8888
    ELSE
      f := Displays.color565; d := 16
    END;

    mem := size;

    NEW(display);
    
    (* Accommodate GPU pitch padding. *)
    display.width := pitch DIV (d DIV 8);
    display.height := h;
    display.offscreen := mem DIV pitch - h;
    IF display.offscreen < 0 THEN display.offscreen := 0 END;
    display.format := f; display.unit := 10000;

    (* Force an uncached MMU mapping *)
    Kernel.MapPhysical(adr, mem + (-mem) MOD 4096, adr);

    display.InitFrameBuffer(adr, mem);
    Kernel.WriteString(Header); Kernel.WriteString("initialized OK"); Kernel.WriteLn
  ELSE
    Kernel.WriteString(Header); Kernel.WriteString("FB init FAILED"); Kernel.WriteLn;
    display := NIL
  END
END Init;

BEGIN
  Init; Install
END DisplayLinear.