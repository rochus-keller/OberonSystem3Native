(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSISO9660Volumes; (** non-portable *)

 (* FAT file system *)
 
 IMPORT
  SYSTEM, Kernel, OFS, Disks;
 
 CONST
  debug = FALSE; mountDebug = FALSE; getBlockDebug = FALSE;
  
 CONST (* svr *)
  SS = 2048; (* sector size *)
  MaxRetries = 10;
  
 TYPE
  Volume* = POINTER TO RECORD (OFS.Volume)
   dev: Disks.Device;
   bpc: LONGINT; (* bytes per sector *)
   spc: LONGINT; (* sectors per cluster *)
  END;
  
  DataBlock = ARRAY MAX(LONGINT) OF CHAR;
  
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
 
 PROCEDURE LogLn;
 BEGIN
  Kernel.WriteLn
 END LogLn;
 
 (* -- Shared procedures -- *)
 
 
 PROCEDURE GetBlock(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
 VAR res, i: LONGINT;
 BEGIN
  WITH vol: Volume DO
   ASSERT(vol # NIL, 100);
   ASSERT(vol.dev # NIL, 101);
   i := 0;
   REPEAT
    vol.dev.transfer(vol.dev, Disks.Read, adr, 1, SYSTEM.VAL(DataBlock, blk), 0, res);
    INC(i)
   UNTIL (res = 0) OR (i >= MaxRetries);
   IF getBlockDebug & (i > 1) THEN LogString("GetBlock; "); LogInt(i); LogString(" retries"); LogLn END;
   ASSERT(res = 0, 102)
  END
 END GetBlock;


 PROCEDURE Lock(dev: Disks.Device; VAR res: LONGINT);
 VAR i: LONGINT; lockMsg: Disks.LockMsg;
 BEGIN
  ASSERT(dev # NIL, 100);
  i := 0;
  REPEAT dev.handle(dev, lockMsg, res); INC(i) UNTIL (res = Disks.Ok) OR (i >= MaxRetries);
  IF mountDebug & (i > 1) THEN LogString("Lock; "); LogInt(i); LogString(" retries"); LogLn END;
 END Lock;
 
 (** Open the device and increment its open count if successful.  If the device is opened for the first time, lock it and update its partition table. *)
 PROCEDURE Open(dev: Disks.Device;  VAR res: LONGINT);
 BEGIN
  IF mountDebug THEN dev.openCount := 0 END;
  IF dev.openCount = 0 THEN
   Lock(dev, res); ASSERT(res = Disks.Ok, 100);
   dev.openCount := 1
  ELSE res := Disks.DeviceInUse
  END
 END Open;
 
 PROCEDURE Available(vol: OFS.Volume): LONGINT;
 BEGIN
  RETURN 0
 END Available;
 
 PROCEDURE FetchString(VAR name: ARRAY OF CHAR; VAR ch: CHAR);
 VAR i: LONGINT;
 BEGIN
  WHILE ch = " " DO OFS.ReadPar(ch) END;
  i := 0;
  WHILE (ch # 0X) & (ch # " ") & (ch # ",") DO name[i] := ch;  INC(i);  OFS.ReadPar(ch) END;
  name[i] := 0X
 END FetchString;
 
 PROCEDURE GetParams(VAR name: ARRAY OF CHAR);
 VAR ch: CHAR;
 BEGIN
  OFS.ReadPar(ch); FetchString(name, ch);
 END GetParams;
 
 PROCEDURE Finalize(vol: OFS.Volume);
 VAR res: LONGINT;
 BEGIN
  IF debug THEN LogString("Entering OFSISO9660Volumes.Finalize"); LogLn END;
  WITH vol: Volume DO
   ASSERT(vol.dev.openCount = 1, 100);
   Disks.Close(vol.dev, res); (* ignore res *)
   vol.dev := NIL; OFS.FinalizeVol(vol)
  END
 END Finalize;

 PROCEDURE GetISO9660Volume(VAR newvol: OFS.Volume; dev: Disks.Device);
 VAR vol: Volume; b: ARRAY SS OF CHAR;
 BEGIN
  NEW(vol); vol.flags := {}; vol.dev := dev;
  INCL(vol.flags, OFS.ReadOnly); INCL(vol.flags, OFS.Removable);
  vol.bpc := SS; vol.spc := 1;
  GetBlock(vol, 16, b); (* dummy; necessary after disc change *)
  COPY(vol.dev.name, vol.name);
  vol.blockSize := vol.bpc;
  vol.AllocBlock := NIL;  vol.FreeBlock := NIL;
  vol.MarkBlock := NIL;  vol.Marked := NIL;
  vol.Available := Available;
  vol.GetBlock := GetBlock; vol.PutBlock := NIL;
  vol.Sync := OFS.Sync; vol.Finalize := Finalize;
  IF debug THEN
   LogString("GetISO9660Volume"); LogLn;
   LogString("  spc="); LogInt(vol.spc); LogString("  bpc="); LogInt(vol.bpc); LogLn
  END;
  newvol := vol
 END GetISO9660Volume;

 PROCEDURE New*;
 VAR
  name: Disks.Name;  i, res: LONGINT;
  dev: Disks.DeviceTable;  
 BEGIN (* Pre: num is a valid drive number *)
  OFS.NewVol := NIL;
  GetParams(name);
  IF name # "" THEN
   Disks.GetRegistered(dev);
   IF dev # NIL THEN
    LogString("OFSISO9660Volumes: Device ");  LogString(name);
    i := 0;  WHILE (i # LEN(dev)) & (dev[i].name # name) DO INC(i) END;
    IF (i # LEN(dev)) THEN
     Open(dev[i], res);
     IF res = Disks.Ok THEN
      GetISO9660Volume(OFS.NewVol, dev[i]);
      IF OFS.NewVol = NIL THEN Disks.Close(dev[i], res) END (* close again - ignore res *)
     ELSE LogString(" already mounted")
     END
    ELSE LogString(" not found")
    END;
    LogLn
   END
  END
 END New;
 
(* Clean up when module freed. *)
PROCEDURE Cleanup;
VAR fs: OFS.FileSystem;
BEGIN
 IF Kernel.shutdown = 0 THEN
  REPEAT (* unmount all file systems using our volume *)
   fs := OFS.First(); (* look for fs to unmount *)
   WHILE (fs # NIL) & ((fs.vol = NIL) OR ~(fs.vol IS Volume)) DO
    fs := OFS.Next(fs)
   END;
   IF fs # NIL THEN OFS.Remove(fs) END
  UNTIL fs = NIL
 END
END Cleanup;

BEGIN
 Kernel.InstallTermHandler(Cleanup)
END OFSISO9660Volumes.

OFSTools.Mount TEST "IDE1.0" OFSISO9660Volumes.New OFSN2KFiles.NewFS
OFSTools.Mount A "Diskette0" OFSISO9660Volumes.New OFSN2KFiles.NewFS
OFSTools.Unmount ^ TEST A


System.Free OFSISO9660Volumes ~