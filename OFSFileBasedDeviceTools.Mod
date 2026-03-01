(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSFileBasedDeviceTools; (* be *)

IMPORT Disks, OFS, OFSFileBasedDevices, In, Out;

(** Open - registers a file as a virtual device *)
PROCEDURE Open*; (** devicename prefix filename *)
VAR devname: Disks.Name;
 prefix: OFS.Prefix;
 filename: ARRAY 1024 OF CHAR;
 res:LONGINT;
BEGIN
 In.Open;
 In.String(devname); 
 In.String(prefix);
 In.String(filename);
 IF In.Done THEN
  OFSFileBasedDevices.Open(devname, prefix, filename, FALSE, TRUE, res);
  IF (res = 0) THEN Out.String("Ok") ELSE Out.String("Error") END;
  Out.Ln
 END
END Open;

(** Close - unregisters a virtual device *)
PROCEDURE Close*; (** devicename *)
VAR devname: Disks.Name;
 devtable : Disks.DeviceTable;
 idx: LONGINT;
BEGIN
 In.Open; In.Name(devname);
 IF In.Done THEN
  Disks.GetRegistered(devtable);
  IF (devtable # NIL) THEN
   idx := 0;
   WHILE (idx < LEN(devtable)) DO
    IF (devtable[idx].name = devname) THEN
     Disks.Unregister(devtable[idx]);
     Out.String("Device "); Out.String(devtable[idx].name); Out.String(" unregistered"); Out.Ln;
     RETURN
    END;
    INC(idx)
   END;
  END
 END
END Close;

END OFSFileBasedDeviceTools.

OFSFileBasedDeviceTools.Open devname prefix filename
OFSFileBasedDeviceTools.Open VDSK0 FAT Oberon.Dsk ~ 
OFSFileBasedDeviceTools.Open VDSK1 /WINNT/TEMP/OBERON.FS  M~
OFSFileBasedDeviceTools.Close devname
OFSFileBasedDeviceTools.Close ^ VDSK0 VDSK1
!OFSFileBasedDevice.Resize VDSK0 4096 ~

Partitions.Show
Partitions.Unsafe
Partitions.ChangeType VDSK0#1 0 76 ~ 76: Aos, 79: NatFS, 80: NatFS2
Partitions.Format SCSI0.0#5 AosFS -1 Native.bin~
Partitions.Format VDSK0#1 AosFS -1 Native.bin~

OFSTools.Watch
OFSTools.Mount A AosFS VDSK0#01 ~
OFSTools.Mount NEW AosFS SCSI0.0#5 ~
OFSTools.Unmount ^ A ~ B ~
OFSTools.SetDefault ^

System.Directory ^ A:* ~ B:* ~ 
System.CopyFiles SYS:Oberon.Text => A:Oberon.Text ~
System.CopyFiles A:Oberon.Text => B:Coolio.Text ~
System.CopyFiles SYS:Apps1.Arc => A:Apps1.Arc ~
System.DeleteFiles SYS:Coolio.Text ~
System.CopyFiles System.zip => A:System.zip Gadgets.zip => A:Gadgets.zip Apps1.zip => A:Apps1.zip Apps2.zip => A:Apps2.zip 
 Build.zip => A:Build.zip Docu.zip => A:Docu.zip Source1.zip => A:Source1.zip Source2.zip => A:Source2.zip 
 Source3.zip => A:Source3.zip ~


Partitions.GetConfig Diskette0#0 ~
Partitions.SetConfig Diskette0#00 
  AosFS="OFSDiskVolumes.New OFSAosFiles.NewFS"
  RamFS="OFSRAMVolumes.New OFSAosFiles.NewFS"
  DosBasedFS="OFSDosBasedVolumes.New OFSN2KFiles.NewFS"
  FatFS="OFSBufferedDiskVolumes.New OFSFATFiles.NewFS"
  MT="PS2"
  MP="1"
  MB="-3"
  DMASize="14800H"
  TraceModules="1"
  Display="Displays."
  DDriver="DisplayLinear"
  Init="b8024fbb0741cd10b8014fb90701cd10268b4d28268b552a"
  DWidth="1024"
  DHeight="768"
  DDepth="8"
  BakBootVol="SYS 200 1000 AosFS IDE1#3"
  VirtualDevice="VD0 OBERON.FS Fat FatFS PROBE"
  BootVol="SYS 200 1000 AosFS IDE1#3"
  BakBootVol1="TEST 200 1000 AosFS VD0#1"
~


Configuration.DoCommands
OFSFileBasedDeviceTools.Open VDSK0 FAT Oberon.Dsk ~ 
Partitions.Unsafe
Partitions.Format VDSK0#01 AosFS -1 ~
OFSTools.Mount A AosFS VDSK0#01 ~
OFSTools.SetDefault A
ZipTool.ExtractAll \o Build.zip System.zip  Gadgets.zip  Apps1.zip  Apps2.zip  Docu.zip ~
ZipTool.ExtractAll \o Source1.zip  Source2.zip  Source3.zip  SourceB.zip SourceP.zip  ~ 
System.CopyFiles 
 SYS:Oberon.Text => A:Oberon.Text
 SYS:PopupsII.Tool => A:PopupsII.Tool ~
 
~
OFSTools.Watch ~
OFSTools.SetDefault SYS
System.Directory A: ~
OFSTools.Unmount A ~
OFSFileBasedDeviceTools.Close VDSK0 ~ 

OFS.Tool