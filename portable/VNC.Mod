(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE VNC; (** Jörg Kreienbühl   *)
(** Module for opening the VNC connection and doing the initialisations *)

 IMPORT Input, NetSystem, Oberon, In, Texts, Gadgets, Display, Objects, Strings, 
  Images, VNCViewers, DES, VNCTask;

 CONST
  TimeOut =  2;
  StrSize = 64;
  DefaultPort = 5001;
  LogLevel = 0;

VAR
 w: Texts.Writer;
 
 PROCEDURE LogInt(x: LONGINT);
 BEGIN
  Texts.Write(w, " "); Texts.WriteInt(w, x, 0); Texts.Append(Oberon.Log, w.buf)
 END LogInt;

 PROCEDURE LogStr(s: ARRAY OF CHAR);
 BEGIN
  Texts.WriteString(w, s); Texts.Append(Oberon.Log, w.buf)
 END LogStr;

 PROCEDURE LogLn;
 BEGIN
  Texts.WriteLn(w); Texts.Append(Oberon.Log, w.buf)
 END LogLn;

 (* Opens the connection and waits until server initialisation data is available *)
 PROCEDURE OpenConnection(task: VNCTask.Task; host: ARRAY OF CHAR; port: INTEGER);
  VAR
   IP: NetSystem.IPAdr;
   n, time: LONGINT;
   res: INTEGER;
 BEGIN
  LogStr(host); LogInt(port); IF LogLevel > 0 THEN LogLn ELSE LogStr(" ") END;
  NetSystem.GetIP(host, IP);
  NetSystem.OpenConnection(task.c, NetSystem.anyport, IP, port, res);
  
  IF res = NetSystem.done THEN
  (* wait for a response *)
   n := NetSystem.Available(task.c); time := Input.Time()+TimeOut*Input.TimeUnit;
   WHILE (n <= 0) & (Input.Time() - time < 0) DO
    n := NetSystem.Available(task.c)
   END;
   IF n = 0 THEN
    task.c := NIL;
    LogStr("TimeOut");  LogLn
   END;
  ELSE
   task.c := NIL;
   LogStr("Connection Failed"); LogLn
  END;
 END OpenConnection;
 
 (* Ignores the version number from the server and sends back the current version ("RFB 003.003") *)
 PROCEDURE SetVersion(task: VNCTask.Task): REAL;
  VAR 
   str: ARRAY StrSize OF CHAR;
   ver: REAL;
   pos: INTEGER;
   v1, v2: LONGINT;
 BEGIN
  IF task.c = NIL THEN VNCTask.UnInstall(task); RETURN 0 END;
  NetSystem.ReadBytes(task.c, 0, 12, str);  (* Version *)
  str[12] := 0X;
  IF LogLevel > 0 THEN LogStr("Version: "); LogStr(str);  LogLn END;
  pos := 3; Strings.StrToIntPos(str, v1, pos); INC(pos); Strings.StrToIntPos(str, v2, pos);
  ver := v1 + v2 / 1000;
    
  COPY("RFB 003.003", str); str[11] := 0AX;  (* Version back to the server *)
  NetSystem.WriteBytes(task.c, 0, 12, str);
  RETURN ver
 END SetVersion;
 
 (* Authenticates the client, normally by DES-encrypting a 16-Byte challange with John Stouts DES-Module *)
 PROCEDURE Authenticate(task: VNCTask.Task; host: ARRAY OF CHAR);
 VAR 
  user, str, pwd, cipher: ARRAY StrSize OF CHAR;
  longBuf: LONGINT;
 BEGIN
  IF (task.c= NIL) OR (NetSystem.State(task.c) # NetSystem.inout) THEN VNCTask.UnInstall(task); RETURN END;  
  NetSystem.ReadLInt(task.c, longBuf);      (* Auth Schema *)
  IF LogLevel > 1 THEN LogStr("Auth Schema: "); LogInt(longBuf); LogLn END;

  IF longBuf = 0 THEN          (* Failed *)
   NetSystem.ReadLInt(task.c, longBuf);
   ASSERT(longBuf < StrSize);
   LogStr("Reason: "); 
   NetSystem.ReadBytes(task.c, 0, longBuf, str); str[longBuf] := CHR(0);
   LogStr(str); LogLn;
   task.c := NIL
  ELSIF longBuf = 2 THEN         (* VNC Auth *)
   NetSystem.ReadBytes(task.c, 0, 16, str);
   NetSystem.GetPassword("vnc", host, user, pwd);
   DES.SetKey(pwd);
   DES.encrypt(str, 0, cipher, 0);  (* Two 8-Byte-Blocks *)
   DES.encrypt(str, 8, cipher, 8);
   NetSystem.WriteBytes(task.c, 0, 16, cipher);
      
   NetSystem.ReadLInt(task.c,  longBuf);
   IF (LogLevel > 0) OR (longBuf # 0) THEN
    LogStr("Auth-Code (0=OK):"); LogInt(longBuf); LogLn;
    LogStr("NetSystem.SetUser vnc://user@"); LogStr(host); LogStr(" ~"); LogLn
   END;
   IF longBuf # 0 THEN NetSystem.CloseConnection(task.c); task.c := NIL END;
  END;  
 END Authenticate; 

 (* Reads the initialisation messages from the server and creates the GfxMap for the framebuffer with 
  appropriate pixelformat and dimensions *)
 PROCEDURE ReadServerInit(task: VNCTask.Task);  
  VAR
   str: ARRAY StrSize OF CHAR;
   longBuf, dispFormat: LONGINT;
   intBuf, w, h: INTEGER;
 BEGIN
  IF (task.c= NIL) OR (NetSystem.State(task.c) # NetSystem.inout) THEN VNCTask.UnInstall(task); RETURN END;
    
  NetSystem.Write(task.c, 1X);                     (* Client-Init: 1=Shared *)

  NetSystem.ReadInt(task.c, w);    (* Server-Init *)
  NetSystem.ReadInt(task.c, h);
  IF LogLevel > 0 THEN LogStr("Screen: "); LogInt(w); LogInt(h); LogLn END;
  
  NEW(task.img);
  dispFormat := Display.TransferFormat(0);
  IF LogLevel > 0 THEN LogStr("Framebuffer is ") END;
  IF (dispFormat = Display.color8888) OR (dispFormat = Display.color888) THEN
   Images.Create(task.img, w, h, Images.BGRA8888); LogStr("BGRA8888 ")
  ELSIF dispFormat = Display.color555 THEN
   Images.Create(task.img, w, h, Images.BGR555); LogStr("BGR555 ")
  ELSIF dispFormat = Display.color664 THEN
   Images.Create(task.img, w, h, Images.BGR466); LogStr("BGR466 ")
  ELSIF (dispFormat = Display.index8) OR ((dispFormat = Display.unknown) & ~Display.TrueColor(0)) THEN
   Images.Create(task.img, w, h, Images.D8); LogStr("D8 ")
  ELSE
   Images.Create(task.img, w, h, Images.BGR565); LogStr("BGR565 ")
  END; 
  IF LogLevel > 0 THEN LogLn END;
  
  (* Pixel Format of the server. Will be overriden by a PixelFomatMsg *)
  IF LogLevel > 1 THEN LogStr("Server-Config:"); LogLn END;
  NetSystem.Read(task.c, str[0]); IF LogLevel > 1 THEN LogStr("    bits-per-pixel: "); LogInt(ORD(str[0])); LogLn END;
  NetSystem.Read(task.c, str[0]); IF LogLevel > 1 THEN LogStr("    depth: "); LogInt(ORD(str[0])); LogLn END;
  NetSystem.Read(task.c, str[0]); IF LogLevel > 1 THEN LogStr("    big-endian-flag "); LogInt(ORD(str[0])); LogLn END;
  NetSystem.Read(task.c, str[0]); IF LogLevel > 1 THEN LogStr("    true-color-flag "); LogInt(ORD(str[0])); LogLn END;
  
  IF LogLevel > 1 THEN LogStr("    MaxValues (RGB): ") END;
  NetSystem.ReadInt(task.c, intBuf);  IF LogLevel > 1 THEN LogInt(intBuf) END;
  NetSystem.ReadInt(task.c, intBuf);  IF LogLevel > 1 THEN LogInt(intBuf) END;
  NetSystem.ReadInt(task.c, intBuf);  IF LogLevel > 1 THEN LogInt(intBuf); LogLn END;
  
  IF LogLevel > 1 THEN LogStr("    Shifts (RGB): ") END;
  NetSystem.Read(task.c, str[0]);  IF LogLevel > 1 THEN LogInt(ORD(str[0])) END;
  NetSystem.Read(task.c, str[0]);  IF LogLevel > 1 THEN LogInt(ORD(str[0])) END;
  NetSystem.Read(task.c, str[0]);  IF LogLevel > 1 THEN LogInt(ORD(str[0])); LogLn END;
  
  NetSystem.ReadBytes(task.c, 0, 3, str); (* Pad *)
  
  NetSystem.ReadLInt(task.c, longBuf);
  ASSERT(longBuf < StrSize);
  NetSystem.ReadBytes(task.c, 0, longBuf, str); str[longBuf] := 0X;
  IF LogLevel > 0 THEN LogStr("Name: "); LogStr(str); LogLn END;
 END ReadServerInit;
    
 (* Installs the task in the VNC-TaskChain and in the Oberon tasklist *)
 PROCEDURE InstallTask(task: VNCTask.Task); 
 BEGIN
  VNCTask.Init(task);
  Oberon.Install(task);
 END InstallTask;
 
 PROCEDURE SendInit(task: VNCTask.Task);
  VAR i: INTEGER;
 BEGIN
  NetSystem.Write(task.c, 2X);                              (* Encoding-MSG *)
  NetSystem.Write(task.c, 0X);  (* pad *)
  NetSystem.WriteInt(task.c, 5); (* No of Formats *)
  NetSystem.WriteLInt(task.c, 1); (* CopyRect *)
  NetSystem.WriteLInt(task.c, 5); (* Hextile *)
  NetSystem.WriteLInt(task.c, 4); (* CoRRE *)
  NetSystem.WriteLInt(task.c, 2); (* RRE *)
  NetSystem.WriteLInt(task.c, 0); (* RAW *)

  task.netFmt := task.img.fmt;
  IF task.netFmt.code = Images.d8 THEN task.netFmt := Images.BGR565 
  ELSIF task.netFmt.bpp >= 24 THEN task.netFmt := Images.BGRA8888 END;

  NetSystem.Write(task.c, 0X);       (* Pixelformat-MSG *)
  FOR i := 1 TO 3 DO NetSystem.Write(task.c, 0X) END; (* Pad *)
  IF LogLevel > 0 THEN LogStr("Net-Pixelformat is ") END;
  
  NetSystem.Write(task.c, CHR(task.netFmt.bpp DIV 8 * 8));   (* BitsPerPixel *)
  NetSystem.Write(task.c, CHR(task.netFmt.bpp));       (* Depth *)
  NetSystem.Write(task.c, 0X);           (* BigEndian *)
  NetSystem.Write(task.c, 1X);           (* True Colour *)
  
  IF task.netFmt.bpp >= 24 THEN
   NetSystem.WriteInt(task.c, 255);          (* RedMax *)
   NetSystem.WriteInt(task.c, 255);          (* GreenMax *)
   NetSystem.WriteInt(task.c, 255);          (* BlueMax *)
   NetSystem.Write(task.c, CHR(16));         (* RedShift *)
   NetSystem.Write(task.c, CHR(8));          (* GreenShift *)
   NetSystem.Write(task.c, CHR(0));          (* BlueShift *)
   LogStr("BGR32 "); LogLn
  ELSIF task.netFmt.code = Images.bgr565 THEN
   NetSystem.WriteInt(task.c, 31);          (* RedMax *)
   NetSystem.WriteInt(task.c, 63);          (* GreenMax *)
   NetSystem.WriteInt(task.c, 31);          (* BlueMax *)
   NetSystem.Write(task.c, CHR(11));         (* RedShift *)
   NetSystem.Write(task.c, CHR(5));          (* GreenShift *)
   NetSystem.Write(task.c, CHR(0));          (* BlueShift *)
   LogStr("BGR565 "); LogLn
  ELSIF task.netFmt.code = Images.bgr555 THEN
   NetSystem.WriteInt(task.c, 31);          (* RedMax *)
   NetSystem.WriteInt(task.c, 31);          (* GreenMax *)
   NetSystem.WriteInt(task.c, 31);          (* BlueMax *)
   NetSystem.Write(task.c, CHR(10));         (* RedShift *)
   NetSystem.Write(task.c, CHR(5));          (* GreenShift *)
   NetSystem.Write(task.c, CHR(0));          (* BlueShift *)
   LogStr("BGR555 "); LogLn
  ELSIF task.netFmt.code = Images.bgr466 THEN
   NetSystem.WriteInt(task.c, 63);          (* RedMax *)
   NetSystem.WriteInt(task.c, 63);          (* GreenMax *)
   NetSystem.WriteInt(task.c, 15);          (* BlueMax *)
   NetSystem.Write(task.c, CHR(10));         (* RedShift *)
   NetSystem.Write(task.c, CHR(4));          (* GreenShift *)
   NetSystem.Write(task.c, CHR(0));          (* BlueShift *)
   LogStr("BGR466 "); LogLn
  ELSE LogStr("Unknown Pixelformat for network"); LogLn; HALT(120);
  END;
  FOR i := 1 TO 3 DO NetSystem.Write(task.c, 0X) END; (* Pad *)
  IF LogLevel > 0 THEN LogLn END;
 END SendInit;

 (* Opens a VNCViewer with the image created in ReadServerInit *)
 PROCEDURE OpenViewer(task: VNCTask.Task);
  VAR
   (*msg: Display.ConsumeMsg;*)
   vncFrame: VNCViewers.Frame;
 BEGIN
(*
  VNCViewers.NewFrame;
  msg.F := Objects.NewObj (VNCViewers.Frame);
  vncFrame := Objects.NewObj (VNCViewers.Frame);
  msg.obj := task.map;
  msg.id := Display.drop;
  Objects.NewObj.handle(vncFrame, msg);
  VNCViewers.SetTask(vncFrame, task);
*)
  NEW(vncFrame);  VNCViewers.InitFrame(vncFrame, task.img);
  VNCViewers.SetTask(vncFrame, task);
  Objects.NewObj := vncFrame
 END OpenViewer;

 (** Opens A connection. Name has the format host:Port, where Port is normally 5900 + DisplayNumber *)
 PROCEDURE Open*(name: ARRAY OF CHAR);
 VAR 
  port: LONGINT;
  i: INTEGER;
  task: VNCTask.Task;
 BEGIN 
  (* Port und Hostname parsen *)
  port := DefaultPort;
  i := 0;
  WHILE name[i] # 0X DO
   IF name[i] = ':' THEN
    name[i] := 0X; INC(i);
    Strings.StrToIntPos(name, port, i)
   ELSE INC(i) END
  END;
  
  
  NEW(task); task.c := NIL;
  OpenConnection(task, name, SHORT(port));
  IF SetVersion(task) >= 3.003 THEN
   Authenticate(task, name)
  END;
  ReadServerInit(task);
  IF task.c = NIL THEN Objects.NewObj := NIL; RETURN END;
  
  InstallTask(task);
  SendInit(task);
  OpenViewer(task)
 END Open;

 (** Opens a VNCViewer-Gadget (without document). Name is read with In.Open and has the same format as in Open *)
 PROCEDURE OpenGadget*;
  VAR 
   name: ARRAY 256 OF CHAR;
 BEGIN
  In.Open;
  In.String(name); 
  Open(name);
  Gadgets.Integrate(Objects.NewObj)
 END OpenGadget;
 
BEGIN
 Texts.OpenWriter(w);
 LogStr("VNC 0.1 - Sep 99/jk"); LogLn
END VNC.


NetSystem.SetUser vnc:jkreienb@cs-zz3.ethz.ch
VNC.OpenGadget "cs-zz3.ethz.ch:5905"
Desktops.OpenDoc "cs-zz3.ethz.ch:5906" (VNCViewerDocs.NewDoc)
System.Free VNCViewerDocs VNC VNCViewers VNCTask ~
VNCTask.UnInstallAll
