(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE VNCTask;   (** Jörg Kreienbühl    **)
(** Task for the VNC-Viewer, that periadically polls for new Frames and sents requests for them.
 Most of the viewers state is in the task, including the framebuffer image and the connection *)

 IMPORT NetSystem, Oberon, Modules, Input, Display, Images, SYSTEM, Texts;

 CONST
  StrSize = 64;
  BufSize = 2*4096;
  
  
 TYPE
  Task* = POINTER TO TaskDesc;
  TaskDesc* = RECORD (Oberon.TaskDesc)
   c*: NetSystem.Connection;          (** Connection to the server *)
   img*: Images.Image;             (** framebuffer *)
   netFmt*: Images.Format;           (** Pixelformat for the Network *)
   selection*: Texts.Text;            (** The X-selection *)
   selTime*: LONGINT;             (** Time, the X-selection was received *)
   prevPacket, nextRequest, delay, prevAction: LONGINT;  (* Times for controlling the UpdateRequest-Rate*)
   nextVNC: Task               (* link for chaining all VNC-Tasks *) 
  END;
    
  KeyRec* = RECORD
   o*: CHAR;   (* Oberon *)
   x*: LONGINT;  (* X-Windows *)
  END;


 VAR
  NetBuffer: ARRAY BufSize OF CHAR;    (* Scratch-Buffer for Network *)
  TmpImg: Images.Image;      (* Raw-Rect Reads will be assigned to this image *)
  FastDelay: LONGINT;       (* see MODULE-BEGIN *)
  TaskChain: Task;
  KeyTab*: ARRAY 21 OF KeyRec; (* Key-Translation. Last element is sentinel *)
  

 PROCEDURE Min(a, b: LONGINT): LONGINT;
 BEGIN
  IF a > b THEN RETURN b ELSE RETURN a END
 END Min;

 PROCEDURE IgnoreBytes(C: NetSystem.Connection; n: LONGINT);
 BEGIN
  WHILE n > BufSize DO
   NetSystem.ReadBytes(C, 0, BufSize, NetBuffer);
   n := n - BufSize
  END;
  NetSystem.ReadBytes(C, 0, n, NetBuffer)
 END IgnoreBytes;
 
   
 (* (0, 0) is UpperLeft*)
 PROCEDURE ReadRawRect(task: Task; x, y, w, h: INTEGER);
  VAR
   i: LONGINT;
   l, bufH, bytesPerPixel: INTEGER;
 BEGIN
  bytesPerPixel := task.netFmt.bpp DIV 8;
  
  IF bytesPerPixel*w < BufSize THEN
   l := h;
   bufH := BufSize DIV (bytesPerPixel*w);    (* Groesse des Buffers in Zeilen *)

   WHILE l > 0 DO  (* Zeilenblock-Weise *)
    IF bufH > l THEN bufH := l END;
    l := l - bufH;   (* am Schluss ist l=0 *)
    NetSystem.ReadBytes(task.c, 0, bufH*w*bytesPerPixel, NetBuffer);
    IF bytesPerPixel = 4 THEN
     FOR i := 0 TO LONG(bufH)*w-1 DO
(*
      NetBuffer[3*i] := NetBuffer[4*i];
      NetBuffer[3*i + 1] := NetBuffer[4*i + 1];
      NetBuffer[3*i + 2] := NetBuffer[4*i + 2]
*)
      NetBuffer[4*i+3] := CHR(255)
     END
    END;
    
    Images.Init(TmpImg, w, bufH, task.netFmt, -bytesPerPixel*w,
         SYSTEM.ADR(NetBuffer[0]) + LONG(bufH-1)*bytesPerPixel*w);
    Images.Copy(TmpImg, task.img, 0, 0, w, bufH, x, task.img.height-h-(y-l), Images.SrcCopy)
   END
  ELSE
   HALT(120);
  END
 END ReadRawRect;
 
 PROCEDURE ReadPix(task: Task; VAR pix: Images.Pixel);
  VAR netPixel: ARRAY 4 OF CHAR;
 BEGIN
  NetSystem.ReadBytes(task.c, 0,  task.netFmt.bpp DIV 8, netPixel);
  task.netFmt.unpack(task.netFmt, SYSTEM.ADR(netPixel[0]), 0, pix)
 END ReadPix;
 
 
 (* RRE-Coding = several filled Rectangles *)
 PROCEDURE ReadRRE(task: Task; x, y, w, h: INTEGER);
  VAR
   pix: Images.Pixel;
   i, subRects: LONGINT;
   sx, sy, sw, sh: INTEGER; (* SubRectangles *)
 BEGIN
  NetSystem.ReadLInt(task.c, subRects);
  ReadPix(task, pix);
  Images.Fill(task.img, x, task.img.height-h-y, x+w, task.img.height-y, pix, Images.SrcCopy);
  
  FOR i:=1 TO subRects DO
   ReadPix(task, pix);
   
   NetSystem.ReadInt(task.c, sx); NetSystem.ReadInt(task.c, sy);
   NetSystem.ReadInt(task.c, sw); NetSystem.ReadInt(task.c, sh);
   INC(sx, x); INC(sy, y);
   
   Images.Fill(task.img, sx, task.img.height-sh-sy, sx+sw, task.img.height-sy, pix, Images.SrcCopy);
  END
 END ReadRRE;
 
 (* Almost the same as RRE, but Coordinates are only 8-Bit *)
 PROCEDURE ReadCoRRE(task: Task; x, y, w, h: INTEGER);
  VAR
   pix: Images.Pixel;
   i, subRects: LONGINT;
   sx, sy, sw, sh: INTEGER; (* SubRectangles *)
   c: CHAR;
 BEGIN
  NetSystem.ReadLInt(task.c, subRects);
  
  ReadPix(task, pix);
  Images.Fill(task.img, x, task.img.height-h-y, x+w, task.img.height-y, pix, Images.SrcCopy);
  
  FOR i:=1 TO subRects DO
   ReadPix(task, pix);
         
   NetSystem.Read(task.c, c); sx := ORD(c);  NetSystem.Read(task.c, c); sy := ORD(c);
   NetSystem.Read(task.c, c); sw := ORD(c);  NetSystem.Read(task.c, c); sh := ORD(c);
   INC(sx, x); INC(sy, y);
   
   Images.Fill(task.img, sx, task.img.height-sh-sy, sx+sw, task.img.height-sy, pix, Images.SrcCopy)
  END
 END ReadCoRRE;
 
 (* Rect is divided in 16x16-Tiles, which aere handled seperately, but inherit properties from the preceeding rect *)
 PROCEDURE ReadHextile(task:Task; x, y, w, h: INTEGER);
  VAR
   c: CHAR;
   subEncoding: SET;
   background, foreground, colour: Images.Pixel;
   row, col, subrects, i, tw, th, wmin, hmin, sx, sy, sw, sh: INTEGER;
  CONST 
   raw = 0;  backgroundSpec = 1; foregroundSpec = 2; anySubrects = 3; coloured = 4;
 BEGIN
  wmin := (w-1) MOD 16 + 1; hmin := (h-1) MOD 16 + 1;
  FOR row := 0 TO (h-1) DIV 16 DO
   IF row < (h-1) DIV 16 THEN th := 16 ELSE th := hmin END;
   FOR col := 0 TO (w-1) DIV 16 DO
    IF col < (w-1) DIV 16 THEN tw := 16 ELSE tw := wmin END;
    NetSystem.Read(task.c, c); subEncoding := SYSTEM.VAL(SET, LONG(ORD(c)));
    IF raw IN subEncoding THEN
     ReadRawRect(task, x + 16*col, y + 16*row, tw, th)
    ELSE
     IF backgroundSpec IN subEncoding THEN ReadPix(task, background) END;
     IF foregroundSpec IN subEncoding THEN ReadPix(task, foreground) END;
     Images.Fill(task.img, 
          x + 16*col, task.img.height - th - y - 16*row, 
          x + 16*col + tw, task.img.height - y - 16*row, 
          background, Images.SrcCopy);
     IF anySubrects IN subEncoding THEN
      NetSystem.Read(task.c, c); subrects := ORD(c);
      FOR i:=1 TO subrects DO
       colour := foreground;
       IF coloured IN subEncoding THEN ReadPix(task, colour) END;
       NetSystem.Read(task.c, c); sx := ORD(c) DIV 16; sy := ORD(c) MOD 16;
       NetSystem.Read(task.c, c); sw := ORD(c) DIV 16 + 1; sh := ORD(c) MOD 16 + 1;
       Images.Fill(task.img, 
            x + 16*col + sx, task.img.height - sh - y - 16*row - sy, 
            x + 16*col + sx + sw, task.img.height - y - 16*row - sy,
            colour, Images.SrcCopy);
      END
     END
    END (* raw, else *)
   END (* col *)
  END; (* row *)
 END ReadHextile;
 
 
  
 PROCEDURE ReadRectangle(task: Task);
  VAR
   x, y, w, h, sx, sy: INTEGER;
   encoding: LONGINT;
 BEGIN
  NetSystem.ReadInt(task.c, x);  NetSystem.ReadInt(task.c, y); 
  NetSystem.ReadInt(task.c, w);  NetSystem.ReadInt(task.c, h);

  NetSystem.ReadLInt(task.c, encoding);

  IF encoding = 0 THEN                                (* Raw Coding *)
   ReadRawRect(task, x, y, w, h)
  ELSIF encoding = 1 THEN                                      (* Copy Rect *)
   NetSystem.ReadInt(task.c, sx);  NetSystem.ReadInt(task.c, sy);
     
   Images.Copy(task.img, task.img, 
         sx, task.img.height-h-sy, sx+w, task.img.height-sy, 
         x, task.img.height-h-y, Images.SrcCopy);
  ELSIF encoding = 2 THEN         (* RRE *)
   ReadRRE(task, x, y, w, h)  
  ELSIF encoding = 4 THEN         (* CoRRE, 3 doesn't exist *)
   ReadCoRRE(task, x, y, w, h)   
  ELSIF encoding = 5 THEN         (* Hextile *)
   ReadHextile(task, x, y, w, h)
  END; (* IF Codings *)
  
  Images.Update(task.img, x, task.img.height-h-y, x+w, task.img.height-y)
 END ReadRectangle;

 
  
 PROCEDURE SetSelection(task: Task);
  VAR
   str: ARRAY StrSize OF CHAR;
   len, readLen, i, j: LONGINT;
   w: Texts.Writer;
 BEGIN
  Texts.OpenWriter(w);
  NetSystem.ReadBytes(task.c, 0, 3, str); (* Pad *)
  NetSystem.ReadLInt(task.c, len);
  
  readLen := StrSize-1;
  REPEAT
   IF len < readLen THEN readLen := len END;
   NetSystem.ReadBytes(task.c, 0, readLen, str);
   FOR i:= 0 TO readLen-1 DO 
    IF str[i] = 0AX THEN str[i] := 0DX END;                 (* Newline *)
    j := 0;                             (* Translating umlauts *)
    KeyTab[LEN(KeyTab)-1].o := str[i]; KeyTab[LEN(KeyTab)-1].x := ORD(str[i]); (* Sentinel *)
    WHILE KeyTab[j].x # ORD(str[i]) DO INC(j)END;
    str[i] := KeyTab[j].o;
   END;
   str[readLen] := 0X;
   Texts.WriteString(w, str);
   len := len - readLen;
  UNTIL len = 0;
  
  NEW(task.selection); Texts.Open(task.selection, "");
  Texts.Append(task.selection, w.buf);
  task.selTime := Oberon.Time()
 END SetSelection;

 PROCEDURE SendRequest(connection: NetSystem.Connection; incremental:BOOLEAN; x, y, w, h: INTEGER);
 BEGIN
  NetSystem.Write(connection, 3X);      (* MSG-Nr fuer Request *)
  IF incremental THEN NetSystem.Write(connection, 1X) ELSE NetSystem.Write(connection, 0X) END;
  NetSystem.WriteInt(connection, x); NetSystem.WriteInt(connection, y);
  NetSystem.WriteInt(connection, w); NetSystem.WriteInt(connection, h)
 END SendRequest;
 
 
 PROCEDURE ^UnInstall*(task: Task);
 
 PROCEDURE Read(task: Task);
  VAR
   str: ARRAY StrSize OF CHAR;
   j, rectangles: INTEGER;
 BEGIN
  IF NetSystem.Available(task.c) > 0 THEN
   NetSystem.Read(task.c, str[0]);     (* Msg-Type *)
   IF str[0] = 0X THEN                                         (* rectangle *)
    NetSystem.Read(task.c, str[0]); (* Pad *)
    NetSystem.ReadInt(task.c, rectangles);
    FOR j:=1 TO rectangles DO ReadRectangle(task) END
   ELSIF str[0] = 2X THEN                                    (* Ring a Bell *)
    Display.ReplConst(Display.BG, 0, 0, Display.Width, Display.Height, Display.invert);
    Display.ReplConst(Display.BG, 0, 0, Display.Width, Display.Height, Display.invert)
   ELSIF str[0] = 3X THEN                                    (* Cut-Buffer *)
    SetSelection(task)
   ELSE 
    UnInstall(task);
    HALT(120)
   END; (* msgType *)
   task.delay := Min((Oberon.Time() - task.prevPacket) DIV 3, task.delay);
   task.nextRequest := Oberon.Time() + task.delay;
   task.prevPacket := Oberon.Time()
  END; (* NetSystem Available *)
  
  IF Oberon.Time() - task.nextRequest >= 0 THEN
   SendRequest(task.c, TRUE, 0, 0, task.img.width, task.img.height);
   task.nextRequest := Oberon.Time() + task.delay;
   IF Oberon.Time() - task.prevAction >= 2*Input.TimeUnit THEN
    task.delay := task.delay + task.delay DIV 80  + 1
   END
  END;
  task.time := Oberon.Time() + task.delay DIV 2; (* about 2 reads for 1 request *)
 END Read;

 (** Makes the requests faster. Assumes that a user action has happened *)  
 PROCEDURE FastRequests*(task: Task);
 BEGIN
  task.time := Oberon.Time();
  task.nextRequest := task.time;
  task.prevPacket := task.time;
  task.delay := FastDelay;
  task.prevAction := task.time
 END FastRequests;
 
   
 PROCEDURE Handle(me: Oberon.Task);
 BEGIN
  Read(me(Task));
 END Handle;
 
 (* Initialises the Task and inserts into the TaskChain *)
 PROCEDURE Init*(task: Task);
 BEGIN
  FastRequests(task);
  task.safe := FALSE;
  NEW(task.selection); Texts.Open(task.selection, "");
  task.handle := Handle;
  task.nextVNC := TaskChain;
  TaskChain := task;
 END Init;
 
 PROCEDURE UnInstall*(task: Task);
  VAR p, q: Task;
 BEGIN
  Oberon.Remove(task);
  IF task.c # NIL THEN NetSystem.CloseConnection(task.c); task.c := NIL END;

  IF TaskChain = NIL THEN RETURN END;
  IF task = TaskChain THEN TaskChain := TaskChain.nextVNC; RETURN END;
  
  q := TaskChain; p := q.nextVNC;
  WHILE (p # NIL) & (p # task) DO q := p; p := p.nextVNC END;
  IF p = NIL THEN RETURN
  ELSE q.nextVNC := p.nextVNC END
 END UnInstall;
 
 (** Removes all VNC-Tasks *)
 PROCEDURE UnInstallAll*;
 BEGIN
  WHILE TaskChain # NIL DO UnInstall(TaskChain) END
 END UnInstallAll;

BEGIN
 KeyTab[0].o := 0C1X; KeyTab[0].x := 0FF52H; (* UPARROW *)
 KeyTab[1].o := 0C3X; KeyTab[1].x := 0FF53H; (* RIGHT *)
 KeyTab[2].o := 0C4X; KeyTab[2].x:= 0FF51H; (* LEFT *)
 KeyTab[3].o := 0C2X; KeyTab[3].x := 0FF54H; (* DOWN *)
 
 KeyTab[4].o := 0A2X; KeyTab[4].x := 0FF55H; (* PGUp *)
 KeyTab[5].o := 0A3X; KeyTab[5].x := 0FF56H; (* PGDn *)

 
 KeyTab[6].o := 0DX; KeyTab[6].x := 0FF0DH; (* Return *)
 KeyTab[7].o := 07FX; KeyTab[7].x := 0FF08H; (* Backspace *)
 KeyTab[8].o := 01BX; KeyTab[8].x := 0FF1BH; (* Escape *)
 KeyTab[9].o := 09X; KeyTab[9].x := 0FF09H; (* Tab *)
 
 KeyTab[10].o := 0A0X; KeyTab[10].x := 0FF63H; (* Insert *)
 KeyTab[11].o := 0A1X; KeyTab[11].x := 0FFFFH; (* Delete *)
 KeyTab[12].o := 0A8X; KeyTab[12].x := 0FF50H; (* Home *)
 KeyTab[13].o := 0A9X; KeyTab[13].x := 0FF57H; (* End *)
 
 KeyTab[14].o := 'ä'; KeyTab[14].x := 0E4H;
 KeyTab[15].o := 'ö'; KeyTab[15].x := 0F6H;
 KeyTab[16].o := 'ü'; KeyTab[16].x := 0FCH;
 KeyTab[17].o := 'Ä'; KeyTab[17].x := 0C4H;
 KeyTab[18].o := 'Ö'; KeyTab[18].x := 0D6H;
 KeyTab[19].o := 'Ü'; KeyTab[19].x := 0DCH;


 FastDelay := Input.TimeUnit DIV 2000;
 TaskChain := NIL;
 NEW(TmpImg);
 
 Modules.InstallTermHandler(UnInstallAll)
END VNCTask.

VNCTask.UnInstallAll