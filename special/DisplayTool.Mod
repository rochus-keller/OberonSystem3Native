(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE DisplayTool;

 IMPORT V86, SYSTEM, MathL, Kernel (*, Log, Texts, Oberon, In *);
 
 CONST
  textsDebug = TRUE;
 
 CONST
  GTFLockVF = 1;  (* Lock to vertical frequency    *)
  GTFLockHF = 2;  (* Lock to horizontal frequency   *)
  GTFLockPF = 3;  (* Lock to pixel clock frequency   *)
  
 TYPE
  GTFConstants = RECORD
   margin: LONGREAL;   (* Margin size as percentage of display  *)
   cellGran: LONGREAL;  (* Character cell granularity    *)
   minPorch: LONGREAL;  (* Minimum front porch in lines/chars  *)
   vSyncRqd: LONGREAL;  (* Width of V sync in lines     *)
   hSync: LONGREAL;   (* Width of H sync as percent of total  *)
   minVSyncBP: LONGREAL;  (* Minimum vertical sync + back porch (us) *)
   m: LONGREAL;    (* Blanking formula gradient    *)
   c: LONGREAL;    (* Blanking formula offset     *)
   k: LONGREAL;    (* Blanking formula scaling factor   *)
   j: LONGREAL;    (* Blanking formula scaling factor weight *)
  END;
  
  GTFHCRTC = RECORD
   hTotal: LONGINT;          (* Horizontal total                     *)
   hDisp: LONGINT;    (* Horizontal displayed     *)
   hSyncStart: LONGINT;      (* Horizontal sync start                *)
   hSyncEnd: LONGINT;       (* Horizontal sync end                  *)
   hFrontPorch: LONGINT;  (* Horizontal front porch    *)
   hSyncWidth: LONGINT;   (* Horizontal sync width    *)
   hBackPorch: LONGINT;   (* Horizontal back porch    *)
  END;
  
  GTFVCRTC = RECORD
   vTotal: LONGINT;          (* Vertical total                       *)
   vDisp: LONGINT;     (* Vertical displayed                   *)
   vSyncStart: LONGINT;      (* Vertical sync start                  *)
   vSyncEnd: LONGINT;        (* Vertical sync end                    *)
   vFrontPorch: LONGINT;  (* Vertical front porch     *)
   vSyncWidth: LONGINT;   (* Vertical sync width     *)
   vBackPorch: LONGINT;   (* Vertical back porch     *)
  END;
  
  GTFTimings = RECORD
   h: GTFHCRTC;    (* Horizontal CRTC paremeters   *)
   v: GTFVCRTC;    (* Vertical CRTC parameters    *)
   hSyncPol: CHAR;  (* Horizontal sync polarity    *)
   vSyncPol: CHAR;  (* Vertical sync polarity    *)
   interlace: CHAR;  (* 'I' for Interlace, 'N' for Non  *)
   vFreq: LONGREAL;   (* Vertical frequency (Hz)    *)
   hFreq: LONGREAL;   (* Horizontal frequency (KHz)   *)
   dotClock: LONGREAL;  (* Pixel clock (Mhz)     *)
  END;
 
 VAR
  GC: GTFConstants;
  
 TYPE
  VBEString = ARRAY 32 OF CHAR;
  
  VideoMode = POINTER TO VideoModeDesc;
  VideoModeDesc = RECORD
   modeNr: LONGINT;
   (* mandatory for all VBE revisions *)
   modeAttr, winAAttr, winBAttr: SET;
   winGranularity, winSize, winASeg, winBSeg, bytesPerScanLine: LONGINT;
   winFuncPtr: LONGINT;
   (* mandatory for VBE 1.2 and above *)
   xRes, yRes, xCharSize, yCharSize, nrOfPlanes, bitsPerPixel, nrOfBanks: LONGINT;
   memoryModel, bankSize, nrOfImgPages: LONGINT;
   (* direct color fields (for direct/6 and YUV/7) *)
   redMaskSize, redFieldPos: LONGINT;
   greenMaskSize, greenFieldPos: LONGINT;
   blueMaskSize, blueFieldPos: LONGINT;
   rsvdMaskSize, rsvdFieldPos: LONGINT;
   directColorModeInfo: SET;
   (* mandatory for VBE 2.0 and above *)
   physBasePtr: LONGINT;
   (* mandatory for VBE 3.0 and above *)
   linBytesPerScanLine, bnkNrOfImgPages, linNrOfImgPages: LONGINT;
   linRedMaskSize, linRedFieldPos: LONGINT;
   linGreenMaskSize, linGreenFieldPos: LONGINT;
   linBlueMaskSize, linBlueFieldPos: LONGINT;
   linRsvdMaskSize, linRsvdFieldPos, maxPixelClock: LONGINT;
   next: VideoMode
  END;
  
  VBEControllerInfo = RECORD
   sig: ARRAY 5 OF CHAR;
   version, oemSoftwareRev, totalMem: LONGINT;
   oemString, oemVendor, oemProductName, oemProductRev: VBEString;
   dac8, vga, extDac, stereo, stereoEVC, available: BOOLEAN;
   vmodes: VideoMode
  END;
 
 VAR
  Width*, Height*, Depth*, Hz*: LONGINT;
  HSyncStart, HSyncEnd, VSyncStart, VSyncEnd: LONGINT;
  vbe: VBEControllerInfo;
(*  W: Texts.Writer;
  T: Texts.Text; *)
 
 PROCEDURE LogStr(s: ARRAY OF CHAR);
 BEGIN
(*  IF textsDebug THEN Texts.WriteString(W, s); Texts.Append(T, W.buf)
  ELSE Log.Str(s)
  END *)
 END LogStr;
 
 PROCEDURE LogHex(x: LONGINT);
 BEGIN
(*  IF textsDebug THEN Texts.WriteHex(W, x); Texts.Append(T, W.buf)
  ELSE Log.Hex(x)
  END *)
 END LogHex;
 
 PROCEDURE LogInt(x: LONGINT);
 BEGIN
(*  IF textsDebug THEN Texts.WriteInt(W, x, 0); Texts.Append(T, W.buf)
  ELSE Log.Int(x)
  END *)
 END LogInt;
 
 PROCEDURE LogLn;
 BEGIN
(*  IF textsDebug THEN Texts.WriteLn(W); Texts.Append(T, W.buf)
  ELSE Log.Ln
  END *)
 END LogLn;
 
 (* GTF *)
 PROCEDURE pow(x: LONGREAL; n: LONGINT): LONGREAL;
 VAR s: LONGREAL;
 BEGIN
  s := 1;
  WHILE n > 0 DO s := s * x; DEC(n) END;
  RETURN s
 END pow;
 
 PROCEDURE Round(v: LONGREAL): LONGREAL;
 BEGIN
  RETURN ENTIER(v + 0.5)
 END Round;

 PROCEDURE GetInternalConstants(VAR c: GTFConstants);
 BEGIN
  c.margin := GC.margin; c.cellGran := Round(GC.cellGran);
  c.minPorch := Round(GC.minPorch); c.vSyncRqd := Round(GC.vSyncRqd);
  c.hSync := GC.hSync; c.minVSyncBP := GC.minVSyncBP;
  IF GC.k = 0 THEN c.k := 0.001 ELSE c.k := GC.k END;
  c.m := (c.k / 256) * GC.m; c.c := (GC.c - GC.j) * (c.k / 256) + GC.j;
  c.j := GC.j;
 END GetInternalConstants;

 (****************************************************************************
 *
 * Function:  GTF_calcTimings
 * Parameters: hPixels  - X resolution
 *    vLines  - Y resolution
 *    freq  - Frequency (Hz, KHz or MHz depending on type)
 *    type  - 1 - vertical, 2 - horizontal, 3 - dot clock
 *    margins  - True if margins should be generated
 *    interlace - True if interlaced timings to be generated
 *    t   - Place to store the resulting timings
 *
 * Description:  Calculates a set of GTF timing parameters given a specified
 *    resolution and vertical frequency. The horizontal frequency
 *    and dot clock will be automatically generated by this
 *    routines.
 *
 *    For interlaced modes the CRTC parameters are calculated for
 *    a single field, so will be half what would be used in
 *    a non-interlaced mode.
 *
 ****************************************************************************)
 PROCEDURE GTFCalcTimings(hPixels, vLines, freq: LONGREAL; type: LONGINT; wantMargins, wantInterlace: BOOLEAN;
    VAR t: GTFTimings);
 VAR
  interlace,vFieldRate,hPeriod: LONGREAL;
  topMarginLines,botMarginLines: LONGREAL;
  leftMarginPixels,rightMarginPixels: LONGREAL;
  hPeriodEst,vSyncBP,vBackPorch: LONGREAL;
  vTotalLines,vFieldRateEst: LONGREAL;
  hTotalPixels,hTotalActivePixels,hBlankPixels: LONGREAL;
  idealDutyCycle,hSyncWidth,hSyncBP,hBackPorch: LONGREAL;
  idealHPeriod: LONGREAL;
  vFreq,hFreq,dotClock: LONGREAL;
  c: GTFConstants;
 BEGIN
  GetInternalConstants(c);
  vFreq := freq; hFreq := freq; dotClock := freq;

  (* Round pixels to character cell granularity *)
  hPixels := Round(hPixels / c.cellGran) * c.cellGran;

  (* For interlaced mode halve the vertical parameters, and double the required field refresh rate. *)
  IF wantInterlace THEN
   vLines := Round(vLines / 2);
   vFieldRate := vFreq * 2;
   dotClock := dotClock * 2;
   interlace := 0.5;
  ELSE vFieldRate := vFreq; interlace := 0
  END;

  (* Determine the lines for margins *)
  IF wantMargins THEN
   topMarginLines := Round(c.margin / 100 * vLines);
   botMarginLines := Round(c.margin / 100 * vLines)
  ELSE topMarginLines := 0; botMarginLines := 0
  END;

  IF type # GTFLockPF THEN
   IF type = GTFLockVF THEN
    (* Estimate the horizontal period *)
    hPeriodEst := ((1/vFieldRate)-(c.minVSyncBP/1000000))/
      (vLines+(2*topMarginLines)+c.minPorch+interlace)*1000000;

    (* Find the number of lines in vSync + back porch *)
    vSyncBP := Round(c.minVSyncBP / hPeriodEst);
   ELSIF type = GTFLockHF THEN
    (* Find the number of lines in vSync + back porch *)
    vSyncBP := Round((c.minVSyncBP * hFreq) / 1000);
   END;

   (* Find the number of lines in the V back porch alone *)
   vBackPorch := vSyncBP - c.vSyncRqd;
 
   (* Find the total number of lines in the vertical period *)
   vTotalLines := vLines + topMarginLines + botMarginLines + vSyncBP
     + interlace + c.minPorch;

   IF type = GTFLockVF THEN
    (* Estimate the vertical frequency *)
    vFieldRateEst := 1000000 / (hPeriodEst * vTotalLines);

    (* Find the actual horizontal period *)
    hPeriod := (hPeriodEst * vFieldRateEst) / vFieldRate;

    (* Find the actual vertical field frequency *)
    vFieldRate := 1000000 / (hPeriod * vTotalLines);
   ELSIF type = GTFLockHF THEN
    (* Find the actual vertical field frequency *)
    vFieldRate := (hFreq / vTotalLines) * 1000;
   END
  END;

  (* Find the number of pixels in the left and right margins *)
  IF wantMargins THEN
   leftMarginPixels := Round(hPixels * c.margin) / (100 * c.cellGran);
   rightMarginPixels := Round(hPixels * c.margin) / (100 * c.cellGran);
  ELSE leftMarginPixels := 0; rightMarginPixels := 0
  END;

  (* Find the total number of active pixels in image + margins *)
  hTotalActivePixels := hPixels + leftMarginPixels + rightMarginPixels;

  IF type = GTFLockVF THEN
   (* Find the ideal blanking duty cycle *)
   idealDutyCycle := c.c - ((c.m * hPeriod) / 1000)
  ELSIF type = GTFLockHF THEN
   (* Find the ideal blanking duty cycle *)
   idealDutyCycle := c.c - (c.m / hFreq);
  ELSIF type = GTFLockPF THEN
   (* Find ideal horizontal period from blanking duty cycle formula *)
   idealHPeriod := (((c.c - 100) + (MathL.sqrt((pow(100-c.c,2)) +
    (0.4 * c.m * (hTotalActivePixels + rightMarginPixels +
    leftMarginPixels) / dotClock)))) / (2 * c.m)) * 1000;

   (* Find the ideal blanking duty cycle *)
   idealDutyCycle := c.c - ((c.m * idealHPeriod) / 1000);
  END;

  (* Find the number of pixels in blanking time *)
  hBlankPixels := Round((hTotalActivePixels * idealDutyCycle) /
   ((100 - idealDutyCycle) * c.cellGran)) * c.cellGran;

  (* Find the total number of pixels *)
  hTotalPixels := hTotalActivePixels + hBlankPixels;

  (* Find the horizontal back porch *)
  hBackPorch := Round((hBlankPixels / 2) / c.cellGran) * c.cellGran;

  (* Find the horizontal sync width *)
  hSyncWidth := Round(((c.hSync/100) * hTotalPixels) / c.cellGran) * c.cellGran;

  (* Find the horizontal sync + back porch *)
  hSyncBP := hBackPorch + hSyncWidth;

  IF type = GTFLockPF THEN
   (* Find the horizontal frequency *)
   hFreq := (dotClock / hTotalPixels) * 1000;

   (* Find the number of lines in vSync + back porch *)
   vSyncBP := Round((c.minVSyncBP * hFreq) / 1000);

   (* Find the number of lines in the V back porch alone *)
   vBackPorch := vSyncBP - c.vSyncRqd;

   (* Find the total number of lines in the vertical period *)
   vTotalLines := vLines + topMarginLines + botMarginLines + vSyncBP
    + interlace + c.minPorch;

   (* Find the actual vertical field frequency *)
   vFieldRate := (hFreq / vTotalLines) * 1000;
  ELSE
   IF type = GTFLockVF THEN
    (* Find the horizontal frequency *)
    hFreq := 1000 / hPeriod;
   ELSIF type = GTFLockHF THEN
    (* Find the horizontal frequency *)
    hPeriod := 1000 / hFreq;
   END;

   (* Find the pixel clock frequency *)
   dotClock := hTotalPixels / hPeriod;
  END;

  (* Find the vertical frame frequency *)
  IF wantInterlace THEN vFreq := vFieldRate / 2; dotClock := dotClock / 2;
  ELSE vFreq := vFieldRate
  END;

  (* Return the computed frequencies *)
  t.vFreq := vFreq;
  t.hFreq := hFreq;
  t.dotClock := dotClock;

  (* Determine the vertical timing parameters *)
  t.h.hTotal := ENTIER(hTotalPixels);
  t.h.hDisp := ENTIER(hTotalActivePixels);
  t.h.hSyncStart := ENTIER(t.h.hTotal - hSyncBP);
  t.h.hSyncEnd := ENTIER(t.h.hTotal - hBackPorch);
  t.h.hFrontPorch := t.h.hSyncStart - t.h.hDisp;
  t.h.hSyncWidth := ENTIER(hSyncWidth);
  t.h.hBackPorch := ENTIER(hBackPorch);

  (* Determine the vertical timing parameters *)
  t.v.vTotal := ENTIER(vTotalLines);
  t.v.vDisp := ENTIER(vLines);
  t.v.vSyncStart := ENTIER(t.v.vTotal - vSyncBP);
  t.v.vSyncEnd := ENTIER(t.v.vTotal - vBackPorch);
  t.v.vFrontPorch := t.v.vSyncStart - t.v.vDisp;
  t.v.vSyncWidth := ENTIER(c.vSyncRqd);
  t.v.vBackPorch := ENTIER(vBackPorch);

  (* Mark as GTF timing using the sync polarities *)
  IF wantInterlace THEN t.interlace := 'I' ELSE t.interlace := 'N' END;
  t.hSyncPol := '-';
  t.vSyncPol := '+';
 END GTFCalcTimings;

 (* VBE *)
 
 PROCEDURE CopyVBEString(adr: LONGINT; VAR s: ARRAY OF CHAR);
 VAR adr0, i: LONGINT; adr1: INTEGER;
 BEGIN
  SYSTEM.GET(adr+2, adr1); adr0 := LONG(adr1) * 16;
  SYSTEM.GET(adr, adr1); adr0 := adr0+adr1;
  i := -1;
  REPEAT INC(i); SYSTEM.GET(adr0, s[i]); INC(adr0) UNTIL s[i] = 0X
 END CopyVBEString;
 
 PROCEDURE UpDown*;
 BEGIN
 END UpDown;
 
 PROCEDURE LeftRight*;
 BEGIN
 END LeftRight;
 
 PROCEDURE ChangeHz*;
 BEGIN
 END ChangeHz;
 
 PROCEDURE Set*;
 BEGIN
 END Set;
 
 PROCEDURE SetVideoMode*(modeNr, vFreq: LONGINT; blank, linear: BOOLEAN; VAR res: LONGINT);
 VAR vmem, adr: LONGINT; flags: SET; p: VideoMode; regs: V86.Regs; t: GTFTimings; 
 BEGIN
  modeNr := modeNr MOD 200H; res := 0;
  Kernel.NewDMA(256, adr, vmem); (* allocate DMA buffer *)
  ASSERT(vmem MOD 16 = 0);  ASSERT(vmem < 100000H); (* sanity *)
  ASSERT(adr = vmem); (* implementation restriction *)
  
  p := vbe.vmodes;
  WHILE (p # NIL) & (p.modeNr # modeNr) DO p := p.next END;
  IF p # NIL THEN
   IF (vbe.version >= 300H) & (vFreq > 0) THEN
    GTFCalcTimings(p.xRes, p.yRes, vFreq, GTFLockVF, FALSE, FALSE, t);
    regs.EAX := 4F0BH; regs.EBX := 0;
    regs.ECX := vFreq*t.h.hTotal*t.v.vTotal; regs.EDX := modeNr;
    V86.Video(regs); ASSERT(regs.EAX = 4FH, 100);
    SYSTEM.PUT(vmem, SYSTEM.VAL(INTEGER, t.h.hTotal));
    SYSTEM.PUT(vmem+2, SYSTEM.VAL(INTEGER, t.h.hSyncStart));
    SYSTEM.PUT(vmem+4, SYSTEM.VAL(INTEGER, t.h.hSyncEnd));
    SYSTEM.PUT(vmem+6, SYSTEM.VAL(INTEGER, t.v.vTotal));
    SYSTEM.PUT(vmem+8, SYSTEM.VAL(INTEGER, t.v.vSyncStart));
    SYSTEM.PUT(vmem+10, SYSTEM.VAL(INTEGER, t.v.vSyncEnd));
    flags := {};
    IF t.interlace = "I" THEN INCL(flags, 1) END;
    IF t.hSyncPol = "-" THEN INCL(flags, 2) END;
    IF t.vSyncPol = "-" THEN INCL(flags, 3) END;
    SYSTEM.PUT(vmem+12, SYSTEM.VAL(CHAR, flags));
    SYSTEM.PUT(vmem+13, regs.ECX);
    SYSTEM.PUT(vmem+17, SYSTEM.VAL(INTEGER, vFreq*100));
    regs.EBX := 800H
   ELSE regs.EBX := 0
   END;
   regs.EAX := 4F02H; INC(regs.EBX, modeNr);
   IF ~blank THEN INC(regs.EBX, 8000H) END;
   IF linear THEN INC(regs.EBX, 4000H) END;
   regs.ES := SHORT(vmem DIV 16); regs.EDI := 0;
   V86.Video(regs); ASSERT(regs.EAX MOD 10000H= 4FH, 101);
  ELSE res := 1
  END;
  
  Kernel.DisposeDMA(256, vmem); (* deallocate DMA buffer *)
 END SetVideoMode;
 
 PROCEDURE GetFrameBuffer*(modeNr: LONGINT; VAR physAdr, size: LONGINT);
 VAR p: VideoMode;
 BEGIN
  modeNr := modeNr MOD 200H;
  p := vbe.vmodes;
  WHILE (p # NIL) & (p.modeNr # modeNr) DO p := p.next END;
  IF p = NIL THEN physAdr := -1; size := 0 ELSE physAdr := p.physBasePtr; size := vbe.totalMem END
 END GetFrameBuffer;
 
 PROCEDURE SearchVideoMode*(width, height, depth: LONGINT): LONGINT;
 VAR modeNr: LONGINT; p: VideoMode;
 BEGIN
  p := vbe.vmodes;
  WHILE (p # NIL) & ((p.xRes # width) OR (p.yRes # height) OR (p.bitsPerPixel # depth)) DO p := p.next END;
  IF p # NIL THEN modeNr := p.modeNr ELSE modeNr := 0 END;
  RETURN modeNr;
 END SearchVideoMode;
 
 PROCEDURE GetCurrentVideoMode*(): LONGINT;
 VAR regs: V86.Regs;
 BEGIN
  regs.EAX := 4F03H;
  V86.Video(regs);
  RETURN regs.EBX  
 END GetCurrentVideoMode;
 
 PROCEDURE ShowVideoModes;
 VAR p: VideoMode;
 BEGIN
  LogStr("VideoModes"); LogLn;
  p := vbe.vmodes;
  WHILE p # NIL DO
   LogStr("Mode: "); LogHex(p.modeNr); LogLn;
   LogStr("mode attributes: "); LogLn;
   LogStr("   "); IF ~(0 IN p.modeAttr) THEN LogStr("no ") END; LogStr("HW support"); LogLn;
   LogStr("   "); IF ~(2 IN p.modeAttr) THEN LogStr("no ") END; LogStr("TTY output support"); LogLn;
   LogStr("   "); IF 3 IN p.modeAttr THEN LogStr("color") ELSE LogStr("monochrome") END; LogLn;
   LogStr("   "); IF 4 IN p.modeAttr THEN LogStr("graphics") ELSE LogStr("text") END; LogLn;
   LogStr("   "); IF ~(5 IN p.modeAttr) THEN LogStr("not ") END; LogStr("VGA compatible"); LogLn;
   LogStr("   "); IF 6 IN p.modeAttr THEN LogStr("no ") END; LogStr("VGA comp. windowing"); LogLn;
   LogStr("   "); IF ~(7 IN p.modeAttr) THEN LogStr("no ") END; LogStr("linear frame buffer available"); LogLn;
   LogStr("   "); IF ~(8 IN p.modeAttr) THEN LogStr("no ") END; LogStr("double scanning available"); LogLn;
   LogStr("   "); IF ~(9 IN p.modeAttr) THEN LogStr("no ") END; LogStr("interlacing available"); LogLn;
   LogStr("   "); IF ~(10 IN p.modeAttr) THEN LogStr("no ") END; LogStr("HW triple buffering support"); LogLn;
   LogStr("   "); IF ~(11 IN p.modeAttr) THEN LogStr("no ") END; LogStr("HW stereoscopic support"); LogLn;
   LogStr("   "); IF ~(12 IN p.modeAttr) THEN LogStr("no ") END; LogStr("dual display start address support"); LogLn;
   LogStr("window A attributes: "); LogLn;
   IF 0 IN p.winAAttr THEN LogStr("   relocatable window") ELSE LogStr("   single non-relocatable window") END; LogLn;
   LogStr("   Window "); IF ~(1 IN p.winAAttr) THEN LogStr("not ") END; LogStr("readable"); LogLn;
   LogStr("   Window "); IF ~(2 IN p.winAAttr) THEN LogStr("not ") END; LogStr("writeable"); LogLn;
   LogStr("window B attributes: "); LogLn;
   IF 0 IN p.winBAttr THEN LogStr("   relocatable window") ELSE LogStr("   single non-relocatable window") END; LogLn;
   LogStr("   Window "); IF ~(1 IN p.winBAttr) THEN LogStr("not ") END; LogStr("readable"); LogLn;
   LogStr("   Window "); IF ~(2 IN p.winBAttr) THEN LogStr("not ") END; LogStr("writeable"); LogLn;
   LogStr("window granularity in KB: "); LogInt(p.winGranularity); LogLn;
   LogStr("window size: "); LogInt(p.winSize); LogLn;
   LogStr("window A start segment: "); LogHex(p.winASeg); LogLn;
   LogStr("window B start segment: "); LogHex(p.winBSeg); LogLn;
   LogStr("real mode pointer to window function: "); LogHex(p.winFuncPtr); LogLn;
   LogStr("bytes per scan line: "); LogInt(p.bytesPerScanLine); LogLn;
   IF vbe.version >= 102H THEN (* VBE 1.2 and above *)
    LogStr("horizontal resolution: "); LogInt(p.xRes); LogLn;
    LogStr("vertical resolution: "); LogInt(p.yRes); LogLn;
    LogStr("character cell width: "); LogInt(p.xCharSize); LogLn;
    LogStr("character cell height: "); LogInt(p.yCharSize); LogLn;
    LogStr("planes: "); LogInt(p.nrOfPlanes); LogLn;
    LogStr("bits per pixel: "); LogInt(p.bitsPerPixel); LogLn;
    LogStr("number of banks: "); LogInt(p.nrOfBanks); LogLn;
    LogStr("memory model: "); LogInt(p.memoryModel); LogStr(", ");
    CASE p.memoryModel OF
     0: LogStr("text mode")
    | 1: LogStr("CGA graphics")
    | 2: LogStr("Hercules graphics")
    | 3: LogStr("planar")
    | 4: LogStr("packed pixel")
    | 5: LogStr("non-chain 4, 256 color")
    | 6: LogStr("direct color")
    | 7: LogStr("YUV")
    | 8..0FH: LogStr("reserverd (VESA)")
    ELSE LogStr("OEM defined")
    END;
    LogLn;
    LogStr("bank size: "); LogInt(p.bankSize); LogLn;
    LogStr("number of images: "); LogInt(p.nrOfImgPages); LogLn;
    IF (p.memoryModel = 6) OR (p.memoryModel = 7) THEN
     LogStr("red mask size: "); LogInt(p.redMaskSize); LogLn;
     LogStr("red field position: "); LogInt(p.redFieldPos); LogLn;
     LogStr("green mask size: "); LogInt(p.greenMaskSize); LogLn;
     LogStr("green field position: "); LogInt(p.greenFieldPos); LogLn;
     LogStr("blue mask size: "); LogInt(p.blueMaskSize); LogLn;
     LogStr("blue field position: "); LogInt(p.blueFieldPos); LogLn;
     LogStr("reserved mask size: "); LogInt(p.rsvdMaskSize); LogLn;
     LogStr("reserved field position: "); LogInt(p.rsvdFieldPos); LogLn;
     LogStr("direct color mode information: "); LogLn;
     LogStr("   color ramp "); IF 0 IN p.directColorModeInfo THEN LogStr("programmable") ELSE LogStr("fixed") END; LogLn;
     LogStr("   reserved field "); IF 1 IN p.directColorModeInfo THEN LogStr("usable") ELSE LogStr("reserved") END; LogLn
    END
   END;
   IF vbe.version >= 200H THEN
    LogStr("start address of linear frame buffer: "); LogHex(p.physBasePtr); LogLn
   END;
   IF vbe.version >= 300H THEN
    LogStr("linear bytes per scan line: "); LogInt(p.linBytesPerScanLine); LogLn;
    LogStr("# images for banked modes: "); LogInt(p.bnkNrOfImgPages); LogLn;
    LogStr("# images for linear modes: "); LogInt(p.linNrOfImgPages); LogLn;
    LogStr("linear red mask size: "); LogInt(p.linRedMaskSize); LogLn;
    LogStr("linear red field position: "); LogInt(p.linRedFieldPos); LogLn;
    LogStr("linear green mask size: "); LogInt(p.linGreenMaskSize); LogLn;
    LogStr("linear green field position: "); LogInt(p.linGreenFieldPos); LogLn;
    LogStr("linear blue mask size: "); LogInt(p.linBlueMaskSize); LogLn;
    LogStr("linear blue field position: "); LogInt(p.linBlueFieldPos); LogLn;
    LogStr("linear reserved mask size: "); LogInt(p.linRsvdMaskSize); LogLn;
    LogStr("linear reserved field position: "); LogInt(p.linRsvdFieldPos); LogLn;
    LogStr("maximum pixel clock (Hz): "); LogInt(p.maxPixelClock); LogLn
   END;
   p := p.next
  END
 END ShowVideoModes;
 
 PROCEDURE ShowVesaInfo*;
 BEGIN
  LogStr("VESA signature: "); LogStr(vbe.sig); LogLn;
  LogStr("version: "); LogHex(vbe.version); LogLn;
  LogStr("OEM: "); LogStr(vbe.oemString); LogLn;
  LogStr("OEM vendor: "); LogStr(vbe.oemVendor); LogLn;
  LogStr("OEM product: "); LogStr(vbe.oemProductName); LogLn;
  LogStr("OEM product revision: "); LogStr(vbe.oemProductRev); LogLn;
  LogStr("OEM software revision: "); LogHex(vbe.oemSoftwareRev); LogLn;
  LogStr("total memory (MB): "); LogInt(vbe.totalMem DIV (1024 * 1024)); LogLn;
  LogStr("Capabilities: ");
  IF vbe.dac8 THEN LogStr("8-bit DAC") ELSE LogStr("6-bit DAC") END; LogStr(", ");
  IF ~vbe.vga THEN LogStr("not VGA comp") ELSE LogStr("VGA comp") END; LogStr(", ");
  IF vbe.extDac THEN LogStr("extended RAMDAC") ELSE LogStr("normal RAMDAC") END; LogStr(", ");
  IF vbe.stereo THEN LogStr("stereoscopic support") ELSE LogStr("no stereoscopic support") END; LogStr(", ");
  IF vbe.stereoEVC THEN LogStr("stereo. over VESA EVC") ELSE LogStr("stereo. over external VESA conn.") END; LogLn;
  ShowVideoModes
 END ShowVesaInfo;
 
 PROCEDURE GetModeInfo(p: VideoMode);
 VAR adr, vmem: LONGINT; regs: V86.Regs; vali: INTEGER; valc: CHAR;
 BEGIN
  Kernel.NewDMA(256, adr, vmem); (* allocate DMA buffer *)
  ASSERT(vmem MOD 16 = 0);  ASSERT(vmem < 100000H); (* sanity *)
  ASSERT(adr = vmem); (* implementation restriction *)
  
  regs.EAX := 4F01H; regs.ECX := p.modeNr;
  regs.ES := SHORT(vmem DIV 16); regs.EDI := 0;
  V86.Video(regs);
  
  SYSTEM.GET(vmem, vali); p.modeAttr := SYSTEM.VAL(SET, vali);
  SYSTEM.GET(vmem+2, valc); p.winAAttr := SYSTEM.VAL(SET, valc);
  SYSTEM.GET(vmem+3, valc); p.winBAttr := SYSTEM.VAL(SET, valc);
  SYSTEM.GET(vmem+4, vali); p.winGranularity := vali;
  SYSTEM.GET(vmem+6, vali); p.winSize := vali;
  SYSTEM.GET(vmem+8, vali); p.winASeg := vali;
  SYSTEM.GET(vmem+10, vali); p.winBSeg := vali;
  SYSTEM.GET(vmem+12, p.winFuncPtr);
  SYSTEM.GET(vmem+16, vali); p.bytesPerScanLine := vali;
  SYSTEM.GET(vmem+18, vali); p.xRes := vali;
  SYSTEM.GET(vmem+20, vali); p.yRes := vali;
  SYSTEM.GET(vmem+22, valc); p.xCharSize := ORD(valc);
  SYSTEM.GET(vmem+23, valc); p.yCharSize := ORD(valc);
  SYSTEM.GET(vmem+24, valc); p.nrOfPlanes := ORD(valc);
  SYSTEM.GET(vmem+25, valc); p.bitsPerPixel := ORD(valc);
  SYSTEM.GET(vmem+26, valc); p.nrOfBanks := ORD(valc);
  SYSTEM.GET(vmem+27, valc); p.memoryModel := ORD(valc);
  SYSTEM.GET(vmem+28, valc); p.bankSize := ORD(valc);
  SYSTEM.GET(vmem+29, valc); p.nrOfImgPages := ORD(valc);
  SYSTEM.GET(vmem+31, valc); p.redMaskSize := ORD(valc);
  SYSTEM.GET(vmem+32, valc); p.redFieldPos := ORD(valc);
  SYSTEM.GET(vmem+33, valc); p.greenMaskSize := ORD(valc);
  SYSTEM.GET(vmem+34, valc); p.greenFieldPos := ORD(valc);
  SYSTEM.GET(vmem+35, valc); p.blueMaskSize := ORD(valc);
  SYSTEM.GET(vmem+36, valc); p.blueFieldPos := ORD(valc);
  SYSTEM.GET(vmem+37, valc); p.rsvdMaskSize := ORD(valc);
  SYSTEM.GET(vmem+38, valc); p.rsvdFieldPos := ORD(valc);
  SYSTEM.GET(vmem+39, valc); p.directColorModeInfo := SYSTEM.VAL(SET, valc);
  SYSTEM.GET(vmem+40, p.physBasePtr);
  SYSTEM.GET(vmem+50, vali); p.linBytesPerScanLine := vali;
  SYSTEM.GET(vmem+52, valc); p.bnkNrOfImgPages := ORD(valc);
  SYSTEM.GET(vmem+53, valc); p.linNrOfImgPages := ORD(valc);
  SYSTEM.GET(vmem+54, valc); p.linRedMaskSize := ORD(valc);
  SYSTEM.GET(vmem+55, valc); p.linRedFieldPos := ORD(valc);
  SYSTEM.GET(vmem+56, valc); p.linGreenMaskSize := ORD(valc);
  SYSTEM.GET(vmem+57, valc); p.linGreenFieldPos := ORD(valc);
  SYSTEM.GET(vmem+58, valc); p.linBlueMaskSize := ORD(valc);
  SYSTEM.GET(vmem+59, valc); p.linBlueFieldPos := ORD(valc);
  SYSTEM.GET(vmem+60, valc); p.linRsvdMaskSize := ORD(valc);
  SYSTEM.GET(vmem+61, valc); p.linRsvdFieldPos := ORD(valc);
  SYSTEM.GET(vmem+62, p.maxPixelClock);
  
  Kernel.DisposeDMA(256, vmem); (* deallocate DMA buffer *)
 END GetModeInfo;
 
 PROCEDURE GetVideoModes(adr: LONGINT; VAR vmode: VideoMode);
 VAR adr0: LONGINT; adr1, vali: INTEGER; p: VideoMode;
 BEGIN
  SYSTEM.GET(adr+2, adr1); adr0 := LONG(adr1) * 16;
  SYSTEM.GET(adr, adr1); adr0 := adr0+adr1;
  LOOP
   SYSTEM.GET(adr0, vali);
   IF vali = -1 THEN EXIT END;
   NEW(p); p.next := vmode; vmode := p;
   p.modeNr := vali;
   GetModeInfo(p);
   INC(adr0, 2)
  END
 END GetVideoModes;

 PROCEDURE GetVBEControllerInfo;
 VAR adr, vmem: LONGINT; regs: V86.Regs; vali: INTEGER; vals: SET;
 BEGIN
  vbe.vmodes := NIL;
  
  Kernel.NewDMA(512, adr, vmem); (* allocate DMA buffer *)
  ASSERT(vmem MOD 16 = 0);  ASSERT(vmem < 100000H); (* sanity *)
  ASSERT(adr = vmem); (* implementation restriction *)
  
  SYSTEM.MOVE(SYSTEM.ADR("VBE2"), vmem, 4);
  regs.EAX := 4F00H; regs.ES := SHORT(vmem DIV 16); regs.EDI := 0;
  V86.Video(regs);
  
  vbe.available := regs.EAX = 4FH;
  IF vbe.available THEN
   SYSTEM.MOVE(vmem, SYSTEM.ADR(vbe.sig), 4); vbe.sig[4] := 0X;
   SYSTEM.GET(vmem+4, vali); vbe.version := vali;
   CopyVBEString(vmem+6, vbe.oemString);
   SYSTEM.GET(vmem+10, vals);
   vbe.dac8 := 0 IN vals; vbe.vga := ~(1 IN vals); vbe.extDac := 2 IN vals;
   vbe.stereo := 3 IN vals; vbe.stereoEVC := 4 IN vals;
   GetVideoModes(vmem+14, vbe.vmodes);
   SYSTEM.GET(vmem+18, vali); vbe.totalMem := LONG(vali)*64*1024;
   SYSTEM.GET(vmem+20, vali); vbe.oemSoftwareRev := vali;
   CopyVBEString(vmem+22, vbe.oemVendor);
   CopyVBEString(vmem+26, vbe.oemProductName);
   CopyVBEString(vmem+30, vbe.oemProductRev)
  END;
  Kernel.DisposeDMA(512, vmem); (* deallocate DMA buffer *)
 END GetVBEControllerInfo;
 
 PROCEDURE GetVideoBios;
 BEGIN
  GetVBEControllerInfo
 END GetVideoBios;

 PROCEDURE InitGtf;
 BEGIN
  GC.margin := 1.8; GC.cellGran := 8; GC.minPorch := 1; GC.vSyncRqd := 3;
  GC.hSync := 8; GC.minVSyncBP := 550; GC.m := 600; GC.c := 40; GC.k := 128; GC.j := 20
 END InitGtf;
 
 PROCEDURE Init;
 BEGIN
(*  IF textsDebug THEN
   NEW(T);  Texts.Open(T, "");
   Oberon.OpenText("", T, 400, 200);
   Texts.OpenWriter(W)
  END; *)
  InitGtf;
  GetVideoBios
 END Init;
 
(* PROCEDURE DoSearch*;
 VAR w, h, d, modeNr: LONGINT;
 BEGIN
  In.Open; In.LongInt(w); In.LongInt(h); In.LongInt(d);
  IF In.Done THEN
   modeNr := SearchVideoMode(w, h, d);
   LogStr("Mode Nr: "); LogHex(modeNr); LogLn
  END
 END DoSearch;
 
 PROCEDURE DoGetCurrentVideoMode*;
 VAR modeNr: LONGINT;
 BEGIN
  modeNr := GetCurrentVideoMode();
  LogStr("Mode Nr: "); LogHex(modeNr); LogLn
 END DoGetCurrentVideoMode;
 
 PROCEDURE DoSetVideoMode*;
 VAR modeNr, res, w, h, d, vFreq: LONGINT;
 BEGIN
  In.Open; In.LongInt(w); In.LongInt(h); In.LongInt(d); In.LongInt(vFreq);
  IF In.Done THEN
   modeNr := SearchVideoMode(w, h, d); ASSERT(modeNr # 0, 100);
   SetVideoMode(modeNr, vFreq, FALSE, TRUE, res); ASSERT(res = 0, 101)
  END
 END DoSetVideoMode; *)
 
BEGIN
 Init
END DisplayTool.


DisplayTool.ShowVesaInfo
DisplayTool.DoSearch 1024 768 32
DisplayTool.DoGetCurrentVideoMode
DisplayTool.DoSetVideoMode 1024 768 32 105
DisplayTool.DoSetVideoMode 1024 768 32 100
DisplayTool.DoSetVideoMode 1600 1200 16 74
DisplayTool.DoSetVideoMode 1600 1200 16 60

