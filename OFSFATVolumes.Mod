(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSFATVolumes; (* be *)

(** write-behind/read-ahead cached OFS.Volume implementation based on Disks. *)
 
(** ATTENTION !! THIS VOLUME MUST NOT BE CACHED USING OFSCacheVolumes.Mod !! *)

IMPORT SYSTEM, Kernel, Modules, Disks, OFS, Unicode;

CONST
 moduleName = "OFSFATVolumes: ";
 Trace = FALSE;
 Detail = Trace & FALSE;
 SystemMove = TRUE;
 
 (** cache types *)
 FAT* = 0;
 Data* = 1;
 
 (* cache default settings *)
 Caching = TRUE;
 FATHashSize = 512; (* number of entries in hash table *)
 FATCacheSizeKB = 256; (* in KBytes *)
 DataHashSize = 256; (* number of entries *)
 DataCacheSizeKB = 1024; (* in KBytes *)
 FlushBufferSize = 256; (* in KBytes *)
 LazyWriting = TRUE;
 
 (** Result values *)
 Ok* = 0;
 Error* = -1;      (** unknown/unspecified error *)
 ERootFull* = -2;    (** root directory of FAT12/FAT16 file system full *)
 EInvalidFilename* = -3; (** invalid filename *)
 
 (** FAT Types *)
 FAT12* = 12;
 FAT16* = 16;
 FAT32* = 32;

 (* FSInfo Constants *)
 fsiLeadSig = 41615252H; 
 fsiStrucSig = 61417272H;
 fsiTrailSig = 0AA550000H;
 
 (** FAT Constants *)
 FREE* = 0;
 EOC* = -1;
 BAD* = -2;
 NONE* = -3;
 (* EOC values (end of clusterchain); test for greater or equal *)
 fat12EOC = 0FF8H;  
 fat16EOC = 0FFF8H;
 fat32EOC = 0FFFFFF8H; 
 (* BAD CLUSTER values; test for equality *)
 fat12BAD = 0FF7H; 
 fat16BAD = 0FFF7H;
 fat32BAD = 0FFFFFF7H; 
 (* FREE CLUSTER *)
 fatFREE = 0;
 
 (** lengths of filenames *)
 MaxUCSNameLen* = 256;   (** maximal length of a filename in Unicode format *)
 MaxUTFNameLen* = 3*MaxUCSNameLen; (** max length in UTF8 format => every character may be up to 3 bytes long *)
 MaxShortNameLen* = 12;   (** max length of short name in ASCII format *)
 DirEntrySize = 32;      (* size of one physical directory entry *)
 
 (** Directory Entriy Constants *)
 deLAST* = 0X;
 deFREE = 0E5X;
 deFree = 0;
 deLast = 1;
 deVolumeID = 2;
 deFirstLong = 3;
 deLong = 4;
 deShort = 5;
 
 (** File Attributes *)
 faReadOnly* = 0; 
 faHidden* = 1; 
 faSystem* = 2; 
 faVolumeID* = 3; 
 faDirectory* = 4; 
 faArchive* = 5;
 faLongName = { faReadOnly, faHidden, faSystem, faVolumeID };
 
 (* DirCache Types *)
 dcInvalid = -1;
 dcSentinel = 0;
 dcFree = 1;
 dcValid = 2;
 
TYPE
 PCharArray = POINTER TO ARRAY OF CHAR;

 Buffer = POINTER TO RECORD
  adr, index: LONGINT;
  dirty: BOOLEAN;
  nextHash, prevHash, nextLRU, prevLRU: Buffer
 END;
 
 Volume* = POINTER TO RECORD(OFS.Volume)
  dev: Disks.Device;
  partIdx: LONGINT;
  startSector, numSectors: LONGINT;
  IOError*, MountedReadOnly*: BOOLEAN; (** IOError: TRUE iff this volume had I/O errors *)
  data: ARRAY 2 OF POINTER TO ARRAY OF ARRAY OF CHAR;
  hash: ARRAY 2 OF POINTER TO ARRAY OF Buffer;
  getCount, putCount, getHitCount, putHitCount, physicalPutCount: LONGINT;
  lazyWriting: BOOLEAN;
  lru: ARRAY 2 OF Buffer;
  (* FAT specific data *)
  bpb*: BPB; (** Bios Parameter Block *)
  clusterSize: LONGINT; (* to allow local declarations ARRAY vol.clusterSize *)
  unsafe: BOOLEAN; (* if TRUE, Get/PutFATEntry do not validate the cluster number. 
           This flag is reset by every call of Get/PutFATEntry *)
  dirCache: DirCache (* caches the most recently accessed directory *)
 END;
 
 CharArray = ARRAY MAX(LONGINT) OF CHAR;
 
 (** base type for parameter passing via 'EnumerateDirectory' *)
 Param* = POINTER TO ParamDesc;
 ParamDesc* = RECORD
  direntry*: DirEntry;
 END;
 
 TailGenParam = POINTER TO RECORD(ParamDesc)
  short: ShortName;   (* holds the short name *)
  tailmask: SET;     (* defines what tail lengths we are checking *)
  tails: POINTER TO ARRAY OF SET; (* bit-array, if a tail is found the corresponding bit is set  *)
 END;
 
 UpDirParam = POINTER TO RECORD(ParamDesc)
  upCluster, dirCluster: LONGINT;
  found: BOOLEAN;
 END;

 (** File Names *)
 UCSName = ARRAY MaxUCSNameLen OF INTEGER;
 LongName* = ARRAY MaxUTFNameLen OF CHAR;
 ShortName* = ARRAY MaxShortNameLen OF CHAR;
 
 FATTime = RECORD
  time: LONGINT;
  tenth: INTEGER;
 END;
 
 (** client handler called by 'EnumerateDirectory' *)
 EnumDirHandler* = PROCEDURE(p: Param; VAR continue: BOOLEAN);
           
 Address = OFS.Address;
 
 (** BIOS Parameter Block *)
 BPB* = RECORD (* BIOS Parameter Block *)
  jmpBoot*: ARRAY 3 OF CHAR;
  OEMName*: ARRAY 9 OF CHAR; (* including 0X at the end *)
  BytsPerSec*: LONGINT; (* valid values: 512, 1024, 2048, 4096 *)
  SecPerClus*: INTEGER; (* valid values: 1,2,4,8,16,32,64,128 *)
  RsvdSecCnt*: LONGINT; 
  NumFATs*: INTEGER; 
  RootEntCnt*: LONGINT;
  TotSec16*: LONGINT;
  Media*: CHAR; 
  FATSz16*: LONGINT;
  SecPerTrk*: LONGINT;
  NumHeads*: LONGINT;
  HiddSec*: LONGINT;
  TotSec32*: LONGINT;
  VolLab*: ARRAY 12 OF CHAR; (* including 0X at the end *)
  FSInfoSec: LONGINT;
  FSInfo*: FSINFO; (* for FAT12/FAT16 partitions, this has to be initialized *)
  FreeCountValid: BOOLEAN; (* TRUE iff FSInfo.FreeCount equals count of free clusters  *)
  
  (* the following fields are only valid for FAT32 partitions *)
  FATSz32*: LONGINT;
  ExtFlags*: LONGINT;
  FSVer*: RECORD
    Major*, Minor*: CHAR;
   END;
  RootClus*: LONGINT;
  BkBootSec*: LONGINT;
  
  (* addidional information *)
  FATType*: SHORTINT;
  FATSz*: LONGINT;
  RootDirSectors*: LONGINT;
  FirstFATSector*: LONGINT; (* sector number of the start of the first active FAT *)
  FirstDataSector*: LONGINT; (* relative to the start of the partition *)
  CountOfClusters*: LONGINT;
  BytesPerCluster*: LONGINT;
  ActiveFAT*: INTEGER; (* number of active FAT, -1 if all FATs are mirrored at runtime *)
  MirroredFATs*: INTEGER; (* number of active FATs - 1, i.e. 0 if just one FAT is active, 1 if two FATs are active, etc *)
 END;

 FSINFO* =  RECORD (* FAT32 FSnfo Sector *)
  FreeCount*: LONGINT;
  NextFree*: LONGINT;
 END;
 
 DirInfo* = RECORD
  dirCluster*, (** cluster no. of directory containing this entry *)
  cluster*,  (** no of cluster containing the first physical entry of this entry, -1 if this is a new file *)
  pos*,   (** position in cluster *)
  num*: LONGINT;  (** spans 'num' FAT entries (may cross sector/cluster boundaries) *)
 END;
 
 (** logical Directory entry *)
 DirEntry* = RECORD
  long*: LongName; (** long filename (UTF-8) *)
  short*: ShortName; (** short filename (OEM) *)
  namechanged*: BOOLEAN; (** TRUE if the file was renamed *)
  attr*: SET; (** file attributes *)
  NTRes*: CHAR; (** reserved for use by Windows NT. Set to 0 if the file is created, don't touch it otherwise *)
  modified*: BOOLEAN; (** TRUE if this entry has been modified and needs to be written back to then FAT *)
  size*, (** size of file *)
  cluster*, (** first cluster of file *)
  creationDate*, creationTime*, (** all dates/times in Oberon format *)
  accessDate*,
  writeDate*, writeTime*: LONGINT;
  dirInfo*: DirInfo
 END;
 
 DirCache = POINTER TO RECORD
  type: SHORTINT;
  entry: DirEntry;
  next: DirCache;
 END;
 
(**  Cache Handling *)

(** a FAT volume contains two caches: one for the FAT area (including the root directory) and
 one for the data area.
 Buffers in the FAT area are on sector big, the size of those in the data area is equal to the cluster size.
 
 The cache settings can be changed by calling SetCacheSettings. Cache settings can be change seperatly for FAT and data.
 The caches can be in lazy writing mode; this can be controlled using SetCacheMode.
 Dirty buffers can be flushed to disk using the volume's sync command.
 All buffers are flushed at the end of WriteDirectoryEntry (i.e., after calling Files.Register)
*)
(*  
 These procedures were taken from OFSCacheVolumes and modified. 
*)

(* all FAT volumes share one flushBuffer. This buffer is used only during FlushBuffer calls and can thus be shared.
 WARNING: this will not work in a multi tasking environment !!! *)

VAR flushBuffer: PCharArray; 

PROCEDURE FlushBuffer(vol: Volume; cache: SHORTINT; buf: Buffer);
VAR sector, numsectors, res, bufSize, fbPos, lastDirty, i: LONGINT; nextBuf: Buffer;
BEGIN
 IF Detail THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("flushing buffer (type: ");
  Kernel.WriteInt(cache, 0); Kernel.WriteString("; address: "); Kernel.WriteInt(buf.adr, 0); 
  Kernel.WriteChar(")"); Kernel.WriteLn
 END;

 IF Detail THEN Kernel.WriteString("Flush: "); Kernel.WriteLn; Kernel.WriteInt(buf.adr, 7); Kernel.WriteChar("d") END;
 IF (cache = FAT) THEN bufSize := vol.blockSize ELSE bufSize := vol.clusterSize END;
 IF SystemMove THEN
  ASSERT(bufSize <= LEN(flushBuffer));
  SYSTEM.MOVE(SYSTEM.ADR(vol.data[cache, buf.index]), SYSTEM.ADR(flushBuffer[0]), bufSize);
 ELSE
  FOR i := 0 TO bufSize-1 DO
   flushBuffer[i] := vol.data[cache, buf.index, i]
  END
 END;
 fbPos := bufSize; lastDirty := bufSize;
 nextBuf := FindBuffer(vol, cache, buf.adr+1);
 WHILE (nextBuf # NIL) & (fbPos < LEN(flushBuffer)) DO
  IF SystemMove THEN
   ASSERT(bufSize <= LEN(flushBuffer)-fbPos);
   SYSTEM.MOVE(SYSTEM.ADR(vol.data[cache, nextBuf.index]), SYSTEM.ADR(flushBuffer[fbPos]), bufSize);
  ELSE
   FOR i := 0 TO bufSize-1 DO
    flushBuffer[fbPos+i] := vol.data[cache, nextBuf.index, i]
   END
  END;
  INC(fbPos, bufSize);
  IF Detail THEN Kernel.WriteInt(nextBuf.adr, 5) END;
  IF nextBuf.dirty THEN 
   IF Detail THEN Kernel.WriteChar("d") END;
   lastDirty := fbPos; nextBuf.dirty := FALSE
  END;
  IF (fbPos < LEN(flushBuffer)) THEN nextBuf := FindBuffer(vol, cache, nextBuf.adr+1) END
 END;
 IF Detail THEN Kernel.WriteLn END;
 
 IF (cache = FAT) THEN sector := buf.adr ELSE sector := GetFirstSectorOfCluster(vol, buf.adr) END;
 numsectors := lastDirty DIV vol.blockSize;
 IF Detail THEN Kernel.WriteString("  # sectors: "); Kernel.WriteInt(numsectors, 0); Kernel.WriteLn END;
 vol.dev.transfer(vol.dev, Disks.Write, vol.startSector + sector, numsectors, flushBuffer^, 0, res);
 IF (res # 0) THEN SYSTEM.HALT(17) END;
 buf.dirty := FALSE; INC(vol.physicalPutCount)
END FlushBuffer;

PROCEDURE FindBuffer(vol: Volume; cache: SHORTINT; adr: LONGINT): Buffer;
VAR buf: Buffer;
BEGIN
 ASSERT(adr >= 0);
 buf := vol.hash[cache][adr MOD LEN(vol.hash[cache])];
 WHILE (buf # NIL) & (buf.adr # adr) DO buf := buf.nextHash END;
 IF buf # NIL THEN (* move to end of lru list *)
  buf.prevLRU.nextLRU := buf.nextLRU; buf.nextLRU.prevLRU := buf.prevLRU;
  buf.prevLRU := vol.lru[cache].prevLRU; buf.nextLRU := vol.lru[cache];
  buf.prevLRU.nextLRU := buf; buf.nextLRU.prevLRU := buf
 END;
 RETURN buf
END FindBuffer;

PROCEDURE ReplaceBuffer(vol: Volume; cache: SHORTINT; adr: LONGINT): Buffer;
VAR buf: Buffer; old, new: LONGINT;
BEGIN
 buf := vol.lru[cache]; vol.lru[cache] := vol.lru[cache].nextLRU; (* re-use buffer and move to end of lru list *)
 IF buf.dirty THEN FlushBuffer(vol, cache, buf) END;
 old := buf.adr MOD LEN(vol.hash[cache]);
 new := adr MOD LEN(vol.hash[cache]);
 buf.adr := adr;
 IF old # new THEN
  (* remove *)
  IF buf.prevHash # NIL THEN
   buf.prevHash.nextHash := buf.nextHash
  ELSE
   vol.hash[cache][old] := buf.nextHash
  END;
  IF buf.nextHash # NIL THEN buf.nextHash.prevHash := buf.prevHash END;
   (* add in front *)
  buf.prevHash := NIL; buf.nextHash := vol.hash[cache][new]; vol.hash[cache][new] := buf;
  IF buf.nextHash # NIL THEN buf.nextHash.prevHash := buf END
 END;
 RETURN buf
END ReplaceBuffer;

(** GetBlock: Addresses > 0 are considered to be cluster numbers whereas addresses < 0 are treated as absolute disk addresses *)
PROCEDURE GetBlock(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR buf: Buffer; cache: SHORTINT; sector, numsectors, res, i: LONGINT;
BEGIN
 WITH vol: Volume DO
  INC(vol.getCount);
  IF (adr > 0) THEN
   ASSERT((adr >= 2) & (adr <= vol.bpb.CountOfClusters+1));
   cache := Data; sector := GetFirstSectorOfCluster(vol, adr); numsectors := vol.bpb.SecPerClus
  ELSIF (adr < 0) THEN
   adr := -adr;
   ASSERT(adr < vol.bpb.FirstDataSector);
   cache := FAT; sector := adr; numsectors := 1; 
  ELSE (* read block 0: BPB *)
   ASSERT(vol.dev.blockSize <= LEN(blk));
   vol.dev.transfer(vol.dev, Disks.Read, vol.startSector, 1, SYSTEM.VAL(CharArray, blk), 0, res);
   RETURN
  END;
  IF Caching THEN
   buf := FindBuffer(vol, cache, adr);
   IF buf # NIL THEN (* copy from cache *)
    INC(vol.getHitCount);
    IF SystemMove THEN
     ASSERT(vol.blockSize*numsectors <= LEN(blk));
     SYSTEM.MOVE(SYSTEM.ADR(vol.data[cache, buf.index,0]), SYSTEM.ADR(blk[0]), vol.blockSize*numsectors)
    ELSE
     FOR i := 0 TO vol.blockSize*numsectors-1 DO
      blk[i] := vol.data[cache, buf.index,i]
     END
    END
   ELSE (* replace a buffer *)
    ASSERT(vol.dev.blockSize * numsectors <= LEN(blk));
    vol.dev.transfer(vol.dev, Disks.Read, vol.startSector + sector, numsectors, SYSTEM.VAL(CharArray, blk), 0, res);
    IF (res # 0) THEN SYSTEM.HALT(17) END; (* trap 17: disk error *)
    buf := ReplaceBuffer(vol, cache, adr);
    IF SystemMove THEN
     ASSERT(vol.blockSize*numsectors <= (LEN(vol.data[cache])-buf.index)*LEN(vol.data[cache,0]));
     SYSTEM.MOVE(SYSTEM.ADR(blk[0]), SYSTEM.ADR(vol.data[cache, buf.index,0]), vol.blockSize*numsectors)
    ELSE
     FOR i := 0 TO vol.blockSize*numsectors-1 DO
      vol.data[cache, buf.index,i] := CHR(blk[i])
     END
    END
   END
  ELSE
   ASSERT(vol.dev.blockSize * numsectors <= LEN(blk));
   vol.dev.transfer(vol.dev, Disks.Read, vol.startSector + sector, numsectors, SYSTEM.VAL(CharArray, blk), 0, res);
   IF (res # 0) THEN SYSTEM.HALT(17) END (* trap 17: disk error *)
  END
 END
END GetBlock;

(** PutBlock: Addresses > 0 are considered to be cluster numbers whereas addresses < 0 are treated as absolute disk addresses *)
PROCEDURE PutBlock(vol: OFS.Volume; adr: LONGINT; VAR blk: ARRAY OF SYSTEM.BYTE);
VAR buf: Buffer; cache: SHORTINT; sector, numsectors, i, res: LONGINT;
BEGIN
 IF (Disks.ReadOnly IN vol.flags) THEN ErrorMsg("volume is write protected"); SYSTEM.HALT(21) END;
 WITH vol: Volume DO
  INC(vol.putCount);
  ASSERT(adr # 0); (* writing block 0 is not allowed *)
  IF (adr > 0) THEN
   cache := Data;
   sector := GetFirstSectorOfCluster(vol, adr); numsectors := vol.bpb.SecPerClus
  ELSIF (adr < 0) THEN
   cache := FAT;
   sector := -adr; numsectors := 1; adr := -adr
  END;
  IF Caching THEN
   buf := FindBuffer(vol, cache, adr);
   IF buf # NIL THEN INC(vol.putHitCount)
   ELSE buf := ReplaceBuffer(vol, cache, adr)
   END;
   (* refresh data *)
   IF SystemMove THEN
    ASSERT(vol.blockSize*numsectors <= (LEN(vol.data[cache])-buf.index)*LEN(vol.data[cache,0]));
    SYSTEM.MOVE(SYSTEM.ADR(blk[0]), SYSTEM.ADR(vol.data[cache, buf.index,0]), vol.blockSize*numsectors);
   ELSE
    FOR i := 0 TO vol.blockSize*numsectors-1 DO
     vol.data[cache, buf.index,i] := CHR(blk[i])
    END
   END;
   IF ~vol.lazyWriting THEN FlushBuffer(vol, cache, buf)
   ELSE buf.dirty := TRUE
   END
  ELSE
   ASSERT(vol.dev.blockSize * numsectors <= LEN(blk));
   vol.dev.transfer(vol.dev, Disks.Write, vol.startSector + sector, numsectors, SYSTEM.VAL(CharArray, blk), 0, res);
   IF (res # 0) THEN SYSTEM.HALT(17) END
  END
 END
END PutBlock;

(** Available - returns the number of free blocks (=sectors) *)
PROCEDURE Available(vol: OFS.Volume): LONGINT;
VAR c, free: LONGINT;
BEGIN
 WITH vol: Volume DO
  IF vol.bpb.FreeCountValid THEN free := vol.bpb.FSInfo.FreeCount
  ELSE
   free := 0;
   FOR c := 2 TO vol.bpb.CountOfClusters+1 DO
    IF (GetFATEntry(vol, c) = FREE) THEN INC(free) END
   END;
   vol.bpb.FSInfo.FreeCount := free;
   vol.bpb.FreeCountValid := TRUE
  END;
  RETURN free*vol.bpb.SecPerClus
 END
END Available;

(** Write back any cached information to the volume. *)
PROCEDURE Sync*(vol: OFS.Volume);
VAR type: SHORTINT; buf: Buffer; i: LONGINT; cnt: ARRAY 2 OF LONGINT;
BEGIN
 WITH vol: Volume DO
  cnt[FAT] := 0; cnt[Data] := 0;
  FOR type := 0 TO 1 DO
   IF (vol.hash[type] # NIL) THEN
    FOR i := 0 TO LEN(vol.hash[type])-1 DO
     buf := vol.hash[type, i];
     WHILE (buf # NIL) DO
      IF buf.dirty THEN FlushBuffer(vol, type, buf); INC(cnt[type]) END;
      buf := buf.nextHash
     END
    END
   END
  END
 END;
 IF Trace THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("Sync: "); Kernel.WriteInt(cnt[FAT], 0); 
  Kernel.WriteString(" FAT buffers, "); Kernel.WriteInt(cnt[Data], 0); Kernel.WriteString(" data buffers written"); 
  Kernel.WriteLn
 END
END Sync;

(** Finalize - finalizes a volume (i.e. flushes all modified buffers) and closes its device *)
PROCEDURE Finalize(vol: OFS.Volume);
VAR res: LONGINT;
BEGIN
 WITH vol: Volume DO
  IF ~(Disks.ReadOnly IN vol.flags) THEN
   WriteFSInfoSector(vol);  
   WriteVolumeFlags(vol, TRUE, FALSE)
  END;
  Sync(vol);
  Disks.Unmount(vol.dev, vol.partIdx);
  Disks.Close(vol.dev, res); (* ignore res *)
  vol.dev := NIL;
  vol.partIdx := -1;
  vol.startSector := MAX(LONGINT);
  OFS.FinalizeVol(vol)
 END
END Finalize;


(**  Volume Initialization  *)

(** New - Generate a new disk volume object. OFS.Par: device ["#" part] [",R"] [",X"] *)
PROCEDURE New*;
VAR name: Disks.Name; dirty, readonly, override: BOOLEAN;  i, res: LONGINT;  part: INTEGER;
 dev: Disks.DeviceTable; vol: Volume;
BEGIN
 OFS.NewVol := NIL; readonly := FALSE; Kernel.SetLogMark;
 GetParams(name, part, readonly, override);
 IF (name # "") THEN 
  CheckDiskette(name);
  Disks.GetRegistered(dev);
  IF (dev # NIL) THEN
   Kernel.WriteString(moduleName); Kernel.WriteString(name);
   i := 0; WHILE (i # LEN(dev)) & (dev[i].name # name) DO INC(i) END;
   IF (i # LEN(dev)) THEN
    Disks.Open(dev[i], res);
    IF (res = Disks.Ok) THEN
     Kernel.WriteChar("#"); Kernel.WriteInt(part, 1); Kernel.WriteChar(" ");
     IF (part < LEN(dev[i].table)) THEN
      Disks.Mount(dev[i], part, res);
      IF (res = Disks.Ok) THEN
       NEW(vol);
       IF readonly THEN INCL(vol.flags, Disks.ReadOnly)  END;
       vol.dev := dev[i]; COPY(vol.dev.name, vol.name);
       OFS.AppendStr("#", vol.name); OFS.AppendInt(part, vol.name);
       vol.partIdx := part;
       vol.startSector := dev[i].table[part].start;
       vol.numSectors := dev[i].table[part].size;
       vol.size := vol.numSectors;
       vol.blockSize := dev[i].blockSize;
       vol.Available := Available;
       vol.GetBlock := GetBlock; vol.PutBlock := PutBlock;
       vol.Sync := Sync;
       vol.Finalize := Finalize;
       vol.MountedReadOnly := readonly;
       IF Caching THEN
        SetCacheSize(vol, FAT, 11, 32); (* a valid FAT cache is necessary for ReadBPB *)
       END;
       IF ReadBPB(vol) THEN
        IF ~IsOberonBootDisk(vol) THEN
         IF ~IsOberonFileSystem(vol) THEN
          IF (vol.bpb.FSVer.Major = 0X) & (vol.bpb.FSVer.Minor = 0X) THEN   
           vol.clusterSize := vol.bpb.BytesPerCluster;
           IF Caching THEN
            SetCacheSize(vol, FAT, FATHashSize, FATCacheSizeKB);
            SetCacheSize(vol, Data, DataHashSize, DataCacheSizeKB);
            SetCacheMode(vol, LazyWriting);
           END;
           IF ~VolumeIsClean(vol) THEN 
            dirty := TRUE; 
            IF ~override THEN INCL(vol.flags, Disks.ReadOnly) END
           END;
           vol.size := (vol.bpb.CountOfClusters+1)*vol.bpb.SecPerClus;
           WriteVolumeFlags(vol, FALSE, FALSE);
           NEW(vol.dirCache); vol.dirCache.type := dcInvalid;
           Kernel.WriteString("mounted");
           IF (Disks.ReadOnly IN vol.flags) THEN Kernel.WriteString(" (read-only)") END;
           IF dirty THEN
            Kernel.WriteLn;
            Kernel.WriteString("   This volume was not properly unmounted or had disk I/O errors."); Kernel.WriteLn;
            Kernel.WriteString("   Please run a disk repair utility program under MS-DOS."); Kernel.WriteLn;
            IF ~override THEN Kernel.WriteString("   The volume is mounted read-only.")
            ELSE Kernel.WriteString("   WARNING: readonly protection overridden ! Data may be lost !")
            END;
            Kernel.WriteLn
           END;
           OFS.NewVol := vol
          ELSE
           Kernel.WriteLn;
           Kernel.WriteString("  This FAT32 file system driver was designed for version 0.0, "); Kernel.WriteLn;
           Kernel.WriteString("  The device contains a FAT32 file system, version "); Kernel.WriteInt(ORD(vol.bpb.FSVer.Major), 0);
           Kernel.WriteChar("."); Kernel.WriteInt(ORD(vol.bpb.FSVer.Minor), 0)
          END
         ELSE Kernel.WriteString("contains an Oberon file system")
         END
        ELSE Kernel.WriteString("is an Oberon boot device")
        END
       ELSE Kernel.WriteString("can not read Bios Parameter Block")
       END;
       IF (OFS.NewVol = NIL) THEN Disks.Unmount(dev[i], part) END
      ELSE Kernel.WriteString("already mounted")
      END
     ELSE Kernel.WriteString("not found")
     END    
    ELSE Kernel.WriteString("error "); Kernel.WriteInt(res, 1)
    END;
    IF (OFS.NewVol = NIL) THEN Disks.Close(dev[i], res) END
   ELSE Kernel.WriteString("not found")
   END;
   Kernel.WriteLn
  END
 END
END New;

(** SetCacheSize - set the cache size. 'cache' is either 'FAT' or 'Data'. [hashSize]=elements, [cacheSize]=kiloBytes*)
PROCEDURE SetCacheSize*(vol: Volume; cache: SHORTINT; hashSize, cacheSizeKB: LONGINT);
VAR bufSize, cacheSize, i, n: LONGINT; buf: Buffer;
BEGIN
 Sync(vol);
 IF (cache = FAT) THEN bufSize := vol.blockSize
 ELSE bufSize := vol.blockSize*vol.bpb.SecPerClus
 END;
 cacheSize := cacheSizeKB * 1024 DIV bufSize; 
 NEW(vol.data[cache], cacheSize, bufSize);
 NEW(vol.hash[cache], hashSize);
 FOR i := 0 TO hashSize-1 DO vol.hash[cache, i] := NIL END;
 NEW(vol.lru[cache]); vol.lru[cache].nextLRU:= vol.lru[cache]; vol.lru[cache].prevLRU := vol.lru[cache]; (* dummy *)
 FOR i := 0 TO cacheSize-1 DO
  NEW(buf); buf.adr := -i; buf.index := i; buf.dirty := FALSE;
  n := buf.adr MOD LEN(vol.hash[cache]);
  buf.prevHash := NIL; buf.nextHash := vol.hash[cache, n]; vol.hash[cache, n] := buf;
  IF buf.nextHash # NIL THEN buf.nextHash.prevHash := buf END;
  buf.prevLRU := vol.lru[cache].prevLRU; buf.nextLRU := vol.lru[cache];
  buf.prevLRU.nextLRU := buf; buf.nextLRU.prevLRU := buf
 END;
 vol.lru[cache].prevLRU.nextLRU := vol.lru[cache].nextLRU; vol.lru[cache].nextLRU.prevLRU := vol.lru[cache].prevLRU; (* remove dummy *)
 vol.lru[cache] := vol.lru[cache].nextLRU
END SetCacheSize;

(** GetCacheSize - returns the cache size. 'cache' is either 'FAT' or 'Data'. [hashSize]=elements, [cacheSize]=kiloBytes *)
PROCEDURE GetCacheSize*(vol: Volume; cache: SHORTINT; VAR hashSize, cacheSize: LONGINT);
BEGIN hashSize := LEN(vol.hash[cache]); cacheSize := LEN(vol.data[cache]) DIV 1024
END GetCacheSize;

(** SetCacheMode - enable/disable lazy writing *)
PROCEDURE SetCacheMode*(vol: Volume; lazyWriting: BOOLEAN);
BEGIN
 vol.lazyWriting := lazyWriting;
 IF ~lazyWriting THEN Sync(vol) END
END SetCacheMode;

(** GetCacheMode - returns TRUE if lazy writing is enabled, FALSE otherwise *)
PROCEDURE GetCacheMode*(vol: Volume): BOOLEAN;
BEGIN RETURN vol.lazyWriting
END GetCacheMode;

(** GetCacheStatistics - returns the cache performance counters *)
PROCEDURE GetCacheStatistics*(vol: Volume; VAR getCount, getHitCount, putCount, putHitCount, physicalPutCount: LONGINT);
BEGIN
 getCount := vol.getCount; getHitCount := vol.getHitCount; 
 putCount := vol.putCount; putHitCount := vol.putHitCount; 
 physicalPutCount := vol.physicalPutCount
END GetCacheStatistics;

(* GetParams - get the params from OFS.Mod *)
PROCEDURE GetParams(VAR device: ARRAY OF CHAR; VAR part: INTEGER; VAR ReadOnly, Override: BOOLEAN);
VAR ch: CHAR; i: LONGINT; stop: BOOLEAN;
BEGIN
 (* parameter: dev#par [,R] [,X] *)
 REPEAT OFS.ReadPar(ch) UNTIL (ch # " ");
 i := 0;
 WHILE (ch # 0X) & (ch # "#") DO device[i] := ch;  INC(i);  OFS.ReadPar(ch) END;
 device[i] := 0X;
 part := 0;
 OFS.ReadPar(ch);
 WHILE (ch >= "0") & (ch <= "9") DO
  part := 10*part + (ORD(ch) - ORD("0"));
  OFS.ReadPar(ch)
 END;
 
 stop := FALSE; ReadOnly := FALSE; Override := FALSE;
 REPEAT
  CASE ch OF
  | " " : 
  | "," : OFS.ReadPar(ch); 
   IF (ch = "R") THEN ReadOnly := TRUE
   ELSIF (ch = "X") THEN Override := TRUE
   ELSE stop := TRUE
   END
  ELSE stop := TRUE
  END;
  OFS.ReadPar(ch)
 UNTIL stop
  
 (*WHILE (ch = " ") DO OFS.ReadPar(ch) END;
 IF (ch = ",") THEN
  REPEAT
   OFS.ReadPar(ch);
   IF (ch = "R") THEN ReadOnly := TRUE END
   IF (ch
  UNTIL (ch < " ") OR (ch = "~")
 END*)
END GetParams;

(* CheckDiskette - installs the floppy disk as a device if 'name' starts with "Diskette" *)
PROCEDURE CheckDiskette(name: ARRAY OF CHAR);
VAR m: Modules.Module; c: Modules.Command;
BEGIN
 name[8] := 0X; (* assume large enough *)
 IF name = "Diskette" THEN
  m := Modules.ThisMod("Diskettes");
  IF m # NIL THEN
   c := Modules.ThisCommand(m, "Install");
   IF c # NIL THEN c() END
  END
 END
END CheckDiskette;

(** FAT Initialization *)

(* ReadBPB - reads the BIOS parameter block of partition 'vol.part' from 'vol.dev' and fills the 'vol.bpb' parameter *)
PROCEDURE ReadBPB(vol: Volume): BOOLEAN;
VAR b: ARRAY vol.blockSize OF CHAR; TotSec, DataSec: LONGINT;
BEGIN
 GetBlock(vol, 0, b);
 GetCharacters(b, 0, vol.bpb.jmpBoot, 3);
 GetCharacters(b, 3, vol.bpb.OEMName, 8); vol.bpb.OEMName[8] := 0X;
 vol.bpb.BytsPerSec := GetUnsignedInteger(b, 11);
 vol.bpb.SecPerClus := ORD(b[13]);
 vol.bpb.RsvdSecCnt := GetUnsignedInteger(b, 14);
 vol.bpb.NumFATs := ORD(b[16]);
 vol.bpb.RootEntCnt := GetUnsignedInteger(b, 17);
 vol.bpb.TotSec16 := GetUnsignedInteger(b, 19);
 vol.bpb.Media := b[21];
 vol.bpb.FATSz16 := GetUnsignedInteger(b, 22);
 vol.bpb.SecPerTrk := GetUnsignedInteger(b, 24);
 vol.bpb.NumHeads := GetUnsignedInteger(b, 26);
 vol.bpb.HiddSec := GetLongint(b, 28);
 vol.bpb.TotSec32 := GetLongint(b, 32);
 vol.bpb.FATSz32 := GetLongint(b, 36);
 vol.bpb.FSInfo.FreeCount := 0; (* unknown for FAT12/FAT16 *)
 vol.bpb.FSInfo.NextFree := 2; (* by default start searching at cluster 2 *)
 
 IF ~(((vol.bpb.jmpBoot[0] = 0EBX) & (vol.bpb.jmpBoot[2] = 090X)) OR (vol.bpb.jmpBoot[0] = 0E9X)) THEN 
  RETURN FALSE
 END;
 IF (vol.blockSize # vol.bpb.BytsPerSec) OR (vol.blockSize MOD DirEntrySize # 0) THEN
  ErrorMsg("Invalid block size"); RETURN FALSE
 END;
 
 (* determine FAT type *)
 IF (vol.bpb.TotSec16 # 0) THEN TotSec := vol.bpb.TotSec16 ELSE TotSec := vol.bpb.TotSec32 END;
 vol.bpb.RootDirSectors := ((vol.bpb.RootEntCnt * 32) + (vol.blockSize-1)) DIV vol.blockSize; (* round up *)
 IF (vol.bpb.FATSz16 # 0) THEN vol.bpb.FATSz := vol.bpb.FATSz16 ELSE vol.bpb.FATSz := vol.bpb.FATSz32 END;
 vol.bpb.FirstDataSector := vol.bpb.RsvdSecCnt + (vol.bpb.NumFATs * vol.bpb.FATSz) + vol.bpb.RootDirSectors;
 DataSec := TotSec - (vol.bpb.RsvdSecCnt + (vol.bpb.NumFATs * vol.bpb.FATSz) + vol.bpb.RootDirSectors);
 vol.bpb.CountOfClusters := DataSec DIV vol.bpb.SecPerClus;
 vol.bpb.BytesPerCluster := vol.bpb.SecPerClus * vol.blockSize;
 
 IF (vol.bpb.CountOfClusters < 4085) THEN vol.bpb.FATType := FAT12
 ELSIF (vol.bpb.CountOfClusters < 65525) THEN vol.bpb.FATType := FAT16
 ELSE vol.bpb.FATType := FAT32
 END;
 
 vol.bpb.ActiveFAT := -1;
 vol.bpb.MirroredFATs := vol.bpb.NumFATs-1;
 vol.bpb.FirstFATSector := vol.bpb.RsvdSecCnt;
 vol.bpb.FreeCountValid := FALSE;
 IF (vol.bpb.FATType # FAT32) THEN
  GetCharacters(b, 43, vol.bpb.VolLab, 11); vol.bpb.VolLab[11] := 0X;
  vol.bpb.FATSz32 := 0
  (* the FSInfo structure is missing in FAT12/16 *)
 ELSE
  vol.bpb.FATSz32 := GetLongint(b, 36);
  vol.bpb.ExtFlags := GetUnsignedInteger(b, 40);
  IF (AND(vol.bpb.ExtFlags, 80H) = 80H) THEN
   (* only one FAT is active, it is the one referenced in bits 0-3 *)
   vol.bpb.ActiveFAT := SHORT(AND(vol.bpb.ExtFlags, 0FH));
   IF (vol.bpb.ActiveFAT >= vol.bpb.NumFATs) THEN
    Kernel.WriteString(" bios parameter block error");
    RETURN FALSE
   END;
   vol.bpb.MirroredFATs := 0; 
   IF (vol.bpb.FATType = FAT16) THEN INC(vol.bpb.FirstFATSector, vol.bpb.ActiveFAT*vol.bpb.FATSz16)
   ELSE INC(vol.bpb.FirstFATSector, vol.bpb.ActiveFAT*vol.bpb.FATSz32)
   END
  END;
  vol.bpb.FSVer.Major := b[42];
  vol.bpb.FSVer.Minor := b[43];
  vol.bpb.RootClus := GetLongint(b, 44);
  vol.bpb.BkBootSec := GetUnsignedInteger(b, 50);
  GetCharacters(b, 71, vol.bpb.VolLab, 11); vol.bpb.VolLab[11] := 0X;
  vol.bpb.FSInfoSec := GetUnsignedInteger(b, 48);
  ReadFSInfoSector(vol) 
 END;
 RETURN TRUE
END ReadBPB;

(* ReadFSInfoSector - reads the FSInfo sector (FAT32 volumes only) *)
PROCEDURE ReadFSInfoSector(vol: Volume);
VAR b: ARRAY vol.blockSize OF CHAR;
BEGIN
 IF (vol.bpb.FATType = FAT32) THEN
  vol.GetBlock(vol, -vol.bpb.FSInfoSec, b);
  IF (GetLongint(b, 0) = fsiLeadSig) & (GetLongint(b, 484) = fsiStrucSig) & (GetLongint(b, 508) = fsiTrailSig) THEN
   vol.bpb.FSInfo.FreeCount := GetLongint(b, 488);
   vol.bpb.FSInfo.NextFree := GetLongint(b, 492);
   vol.bpb.FreeCountValid := TRUE
  ELSE
   Kernel.WriteString(" (warning: wrong FSInfo sector signature)")
  END  
 END
END ReadFSInfoSector;

(* WriteFSInfoSector - writes the FSInfo sector (FAT32 volumes only) *)
PROCEDURE WriteFSInfoSector(vol: Volume);
VAR b: ARRAY vol.blockSize OF CHAR;
BEGIN
 IF (vol.bpb.FATType = FAT32) THEN
  vol.GetBlock(vol, -vol.bpb.FSInfoSec, b);
  IF (GetLongint(b, 0) = fsiLeadSig) & (GetLongint(b, 484) = fsiStrucSig) & (GetLongint(b, 508) = fsiTrailSig) THEN
   PutLongint(b, 488, vol.bpb.FSInfo.FreeCount);
   PutLongint(b, 492, vol.bpb.FSInfo.NextFree);
   vol.PutBlock(vol, -vol.bpb.FSInfoSec, b)
  END  
 END
END WriteFSInfoSector;

(* IsOberonBootDisk - checks if a 'FAT12' file system has the OEM id set to 'OBERON' *)
PROCEDURE IsOberonBootDisk(vol: Volume): BOOLEAN;
BEGIN RETURN vol.bpb.OEMName = "OBERON"
END IsOberonBootDisk;

(* IsOberonFileSystem - checks if a 'FAT12' file system has the first byte of the root directory set to 0FFX.
 This method is used in Diskette.OpenVol to determine if a floppy disk contains an Oberon file system *)
PROCEDURE IsOberonFileSystem(vol: Volume): BOOLEAN;
VAR buf: ARRAY vol.blockSize OF CHAR; dirStart: LONGINT;
BEGIN
 IF (vol.bpb.FATType = FAT12) THEN
  dirStart := vol.bpb.RsvdSecCnt + (vol.bpb.NumFATs * vol.bpb.FATSz16);
  GetBlock(vol, -dirStart, buf);
  RETURN buf[0] = 0FFX
 ELSE RETURN FALSE
 END
END IsOberonFileSystem;

(* VolumeIsClean - checks two bits in FAT entry 1: CleanShutdown and IOError
 returns TRUE if both bits are 1
 file system drivers set CleanShutdown to 1 if the volume was properly unmounted
 IOError is set to 0 if the file system drivers encountered disk read/write errors *)
PROCEDURE VolumeIsClean(vol: Volume): BOOLEAN;
VAR EOCMark, BitMask: SET;
BEGIN
 IF (vol.bpb.FATType # FAT12) THEN
  vol.unsafe := TRUE;
  EOCMark := SYSTEM.VAL(SET, GetFATEntry(vol, 1));
  IF (vol.bpb.FATType = FAT16) THEN BitMask := {15, 14} 
  ELSE BitMask := {31, 30}
  END;
  RETURN (EOCMark * BitMask = BitMask)
 ELSE RETURN TRUE
 END 
END VolumeIsClean;

(* WriteVolumeFlags - if the volume is not mounted readonly, sets the two bits in FAT entry 1: CleanShutdown and IOError. *)
PROCEDURE WriteVolumeFlags(vol: Volume; CleanShutdown, IOError: BOOLEAN);
VAR EOCMark: SET;
BEGIN
 IF ~(Disks.ReadOnly IN vol.flags) & (vol.bpb.FATType # FAT12) THEN
  vol.unsafe := TRUE;
  EOCMark := SYSTEM.VAL(SET, GetFATEntry(vol, 1));
  IF (vol.bpb.FATType = FAT16) THEN
   IF CleanShutdown THEN INCL(EOCMark, 15) ELSE EXCL(EOCMark, 15) END;
   IF ~IOError THEN INCL(EOCMark, 14) ELSE EXCL(EOCMark, 14) END
  ELSE
   IF CleanShutdown THEN INCL(EOCMark, 31) ELSE EXCL(EOCMark, 31) END;
   IF ~IOError THEN INCL(EOCMark, 30) ELSE EXCL(EOCMark, 30) END
  END;
  vol.unsafe := TRUE;
  PutFATEntry(vol, 1, SYSTEM.VAL(LONGINT, EOCMark))
 END
END WriteVolumeFlags;

(** File Allocation Table  Handling  *)

(** GetFATEntry - reads an entry at index 'cluster' from the active FAT *)
PROCEDURE GetFATEntry*(vol: Volume; cluster: LONGINT): LONGINT;
VAR data: ARRAY vol.blockSize OF CHAR; unsafe: BOOLEAN; FAT12Buffer: ARRAY 2 OF CHAR;
 FATOffset, ThisFATSecNum, ThisFATEntOffset, res: LONGINT;
BEGIN
 unsafe := vol.unsafe; vol.unsafe := FALSE;
 IF (cluster = EOC) OR (cluster = BAD) OR (~unsafe & ((cluster < 2) OR (cluster > vol.bpb.CountOfClusters+1))) THEN
  Kernel.WriteInt(cluster, 0); ErrorMsg(": bad cluster number"); SYSTEM.HALT(15)
 END;
 
 IF (vol.bpb.FATType = FAT12) THEN 
  FATOffset := cluster + cluster DIV 2;
  ThisFATSecNum := vol.bpb.FirstFATSector + (FATOffset DIV vol.blockSize);
  ThisFATEntOffset := FATOffset MOD vol.blockSize;
  
  vol.GetBlock(vol, -ThisFATSecNum, data);
  FAT12Buffer[0] := data[ThisFATEntOffset];
  IF (ThisFATEntOffset = vol.blockSize-1) & (ThisFATSecNum # vol.bpb.FirstDataSector-1) THEN
   (* this FAT entry spans a sector boundary in the FAT *)
   vol.GetBlock(vol, -(ThisFATSecNum+1), data); 
   FAT12Buffer[1] := data[0]
  ELSE 
   FAT12Buffer[1] := data[ThisFATEntOffset+1]
  END;
  
  res := GetUnsignedInteger(FAT12Buffer, 0);
  IF ODD(cluster) THEN res := SYSTEM.LSH(res, -4) (* get the high 12 bits *)
  ELSE res := AND(res, 0FFFH) (* get the low 12 bits *)
  END;
  
  IF ~unsafe THEN 
   IF (res >= fat12EOC) THEN res := EOC
   ELSIF (res = fat12BAD) THEN res := BAD
   END
  END 
 ELSE (* FAT16/FAT32 *)
  IF (vol.bpb.FATType = FAT16) THEN FATOffset := cluster*2 
  ELSE FATOffset := cluster*4
  END;
  ThisFATSecNum := vol.bpb.FirstFATSector + (FATOffset DIV vol.blockSize);
  ThisFATEntOffset := FATOffset MOD vol.blockSize;
  

  vol.GetBlock(vol, -ThisFATSecNum, data);
  IF (vol.bpb.FATType = FAT16) THEN
   res := GetUnsignedInteger(data, ThisFATEntOffset);
   IF ~unsafe THEN 
    IF (res >= fat16EOC) THEN res := EOC
    ELSIF (res = fat16BAD) THEN res := BAD
    END
   END
  ELSE (* FAT32 *)  
   res := GetLongint(data, ThisFATEntOffset);
   IF ~unsafe THEN 
    res := AND(res, 0FFFFFFFH);
    IF (res >= fat32EOC) THEN res := EOC
    ELSIF (res = fat32BAD) THEN res := BAD
    END
   END
  END
 END;
 RETURN res
END GetFATEntry;

(** PutFATEntry - writes 'link' to entry 'cluster' into the active FAT or all FATs if they are mirrored at runtime *)
PROCEDURE PutFATEntry*(vol: Volume; cluster, link: LONGINT);
VAR data: ARRAY vol.blockSize OF CHAR; unsafe: BOOLEAN; FAT12Buffer: ARRAY 2 OF CHAR;
 FATOffset, ThisFATSecNum, ThisFATEntOffset, fatIdx, res: LONGINT;
BEGIN
 unsafe := vol.unsafe; vol.unsafe := FALSE;
 IF (cluster = BAD) OR (~unsafe & ((cluster < 2) OR (cluster > vol.bpb.CountOfClusters+1)) OR 
  (~unsafe & (link # FREE) & (link # EOC) & ((link < 2) OR (link > vol.bpb.CountOfClusters+1)))) THEN 
  ErrorMsg("Bad cluster number"); SYSTEM.HALT(15)
 END;

 IF (vol.bpb.FATType = FAT12) THEN
  IF ~unsafe THEN
   IF (link = FREE) THEN link := fatFREE
   ELSIF (link = EOC) THEN link := fat12EOC
   END
  END;
   
  FATOffset := cluster + cluster DIV 2;
  ThisFATSecNum := vol.bpb.FirstFATSector + (FATOffset DIV vol.blockSize);
  ThisFATEntOffset := FATOffset MOD vol.blockSize;
  
  vol.GetBlock(vol, -ThisFATSecNum, data);
  FAT12Buffer[0] := data[ThisFATEntOffset];
  IF (ThisFATEntOffset = vol.blockSize-1) & (ThisFATSecNum # vol.bpb.FirstDataSector-1) THEN
   (* this FAT entry spans a sector boundary in the FAT *)
   vol.GetBlock(vol, -(ThisFATSecNum+1), data);
   FAT12Buffer[1] := data[0]
  ELSE
   FAT12Buffer[1] := data[ThisFATEntOffset+1]
  END;
    
     res := GetUnsignedInteger(FAT12Buffer, 0);
  IF ODD(cluster) THEN (* set the high 12 bits, preserve the low 4 bits *)
   PutInteger(FAT12Buffer, 0, SHORT(SYSTEM.LSH(link, 4) + AND(res, 0FH)))
  ELSE (* set the low 12 bits, preserve the high 4 bits *)
   PutInteger(FAT12Buffer, 0, SHORT(AND(res, 0F000H) + link))
  END;  
  
  vol.GetBlock(vol, -ThisFATSecNum, data);
  data[ThisFATEntOffset] := FAT12Buffer[0];
  IF (ThisFATEntOffset = vol.blockSize-1) & (ThisFATSecNum # vol.bpb.FirstDataSector-1) THEN
   (* this FAT entry spans a sector boundary in the FAT *)
   FOR fatIdx := 0 TO vol.bpb.MirroredFATs DO
    vol.PutBlock(vol, -ThisFATSecNum, data);
    INC(ThisFATSecNum, vol.bpb.FATSz)
   END;
   ThisFATSecNum := vol.bpb.FirstFATSector + (FATOffset DIV vol.blockSize)+1;
   vol.GetBlock(vol, -ThisFATSecNum, data);
   data[0] := FAT12Buffer[1]
  ELSE
   data[ThisFATEntOffset+1] := FAT12Buffer[1]
  END;

  FOR fatIdx := 0 TO vol.bpb.MirroredFATs DO
   vol.PutBlock(vol, -ThisFATSecNum, data);
   INC(ThisFATSecNum, vol.bpb.FATSz)
  END
 ELSE (* FAT16/FAT32 *)
  IF ~unsafe THEN
   IF (link = FREE) THEN link := fatFREE
   ELSIF (link = EOC) THEN 
    IF (vol.bpb.FATType = FAT16) THEN link := fat16EOC ELSE link := fat32EOC END
   END
  END;
  IF (vol.bpb.FATType = FAT16) THEN FATOffset := cluster*2 
  ELSE FATOffset := cluster*4
  END;
  ThisFATSecNum := vol.bpb.FirstFATSector + (FATOffset DIV vol.blockSize);
  ThisFATEntOffset := FATOffset MOD vol.blockSize;
  vol.GetBlock(vol, -ThisFATSecNum, data); (* copy same block to all mirrored fats *)
  FOR fatIdx := 0 TO vol.bpb.MirroredFATs DO
   IF (vol.bpb.FATType = FAT16) THEN
    PutInteger(data, ThisFATEntOffset, SHORT(link))
   ELSE (* FAT32: preserve the high 4 bits, set the low 28 bits *)
    IF unsafe THEN PutLongint(data, ThisFATEntOffset, link)
    ELSE
     res := GetLongint(data, ThisFATEntOffset);
     PutLongint(data, ThisFATEntOffset, AND(res, 0F0000000H) + link)
    END
   END;
   vol.PutBlock(vol, -ThisFATSecNum, data);
   INC(ThisFATSecNum, vol.bpb.FATSz)
  END
 END
END PutFATEntry;

(** AllocateCluster - searches a free cluster and links it with 'cluster'. If the disk is full, a trap is raised *)
PROCEDURE AllocateCluster*(vol: Volume; cluster: LONGINT): LONGINT;
VAR clus, res, cnt: LONGINT;
BEGIN
 clus := vol.bpb.FSInfo.NextFree;
 res := GetFATEntry(vol, clus); cnt := 1;
 WHILE (res # FREE) & (cnt < vol.bpb.CountOfClusters) DO
  INC(clus); IF (clus = vol.bpb.CountOfClusters+2) THEN clus := 2 END;
  INC(cnt);
  res := GetFATEntry(vol, clus)
 END;
 IF (res = FREE) THEN 
  IF (clus < vol.bpb.CountOfClusters+1) THEN  vol.bpb.FSInfo.NextFree := clus+1
  ELSE vol.bpb.FSInfo.NextFree := 2
  END;
  IF (cluster # NONE) THEN 
   PutFATEntry(vol, cluster, clus) 
  END;
  PutFATEntry(vol, clus, EOC);
  DEC(vol.bpb.FSInfo.FreeCount);
  RETURN clus
 ELSE SYSTEM.HALT(16) (* disk full *)
 END
END AllocateCluster;

(** GetFirstSectorOfCluster - returns the sector number of the first sector of cluster 'cluster' *)
PROCEDURE GetFirstSectorOfCluster*(vol: Volume; cluster: LONGINT): LONGINT;
BEGIN RETURN ((cluster-2) * vol.bpb.SecPerClus) + vol.bpb.FirstDataSector
END GetFirstSectorOfCluster;

(** GetClusterOfSector - returns the cluster sector belongs to *)
PROCEDURE GetClusterOfSector*(vol: Volume; sector: LONGINT): LONGINT;
BEGIN RETURN (sector - vol.bpb.FirstDataSector) DIV vol.bpb.SecPerClus + 2
END GetClusterOfSector;

(** GetNextSector - returns the next cluster/sector pair for a given cluster/sector combination
 If it is the last sector of a cluster chain, then 'sector' is set to -1 and 'cluster' remains unchanged *)
PROCEDURE GetNextSector*(vol: Volume; VAR cluster, sector: LONGINT);
VAR firstSector, nextCluster : LONGINT;
BEGIN
 IF (cluster < 2) OR (cluster > vol.bpb.CountOfClusters+1) THEN ErrorMsg("Bad cluster number"); SYSTEM.HALT(17) END;
 firstSector := GetFirstSectorOfCluster(vol, cluster);
 IF (sector = -1) THEN sector := firstSector
 ELSIF (sector - firstSector < vol.bpb.SecPerClus-1) THEN INC(sector)
 ELSE (* first sector of next cluster *)
  nextCluster := GetFATEntry(vol, cluster);
  IF (nextCluster >= 2) & (nextCluster <= vol.bpb.CountOfClusters+1) THEN 
   cluster := nextCluster;
   sector := GetFirstSectorOfCluster(vol, cluster)
  ELSIF (nextCluster = EOC) THEN sector := -1
  ELSE ErrorMsg("Error in cluster chain"); SYSTEM.HALT(17)
  END
 END
END GetNextSector;


(** Directory Enumeration *)

PROCEDURE GetDirectoryCluster*(vol: Volume; directory: LONGINT; cluster: LONGINT; VAR data: ARRAY OF CHAR): LONGINT;
VAR firstSector, lastSector, sector, i, k, j: LONGINT; block: ARRAY vol.blockSize OF CHAR;
BEGIN
 IF (directory = 0) & (vol.bpb.FATType # FAT32) THEN (* root directory of FAT12/16 *)
  firstSector := vol.bpb.RsvdSecCnt + (vol.bpb.NumFATs * vol.bpb.FATSz16);
  lastSector := firstSector + vol.bpb.RootEntCnt DIV (vol.blockSize DIV DirEntrySize) - 1;
  sector := firstSector + (cluster * vol.bpb.SecPerClus);
  FOR i := 0 TO vol.bpb.SecPerClus-1 DO
   IF (sector + i <= lastSector) THEN
    GetBlock(vol, -(sector + i), block);
    IF SystemMove THEN
     ASSERT(vol.blockSize <= LEN(data)-i*vol.blockSize);
     SYSTEM.MOVE(SYSTEM.ADR(block[0]), SYSTEM.ADR(data[i*vol.blockSize]), vol.blockSize)
    ELSE
     FOR j := 0 TO vol.blockSize-1 DO
      data[i*vol.blockSize+j] := block[j]
     END
    END
   ELSE 
    FOR k := 0 TO vol.blockSize-1 DO data[i*vol.blockSize+k] := 0X END
   END
  END;
  RETURN cluster+1
 ELSE
  IF (directory = 0) & (cluster = 0) THEN cluster := vol.bpb.RootClus END;
  GetBlock(vol, cluster, data);
  RETURN GetFATEntry(vol, cluster)
 END
END GetDirectoryCluster;

PROCEDURE PutDirectoryCluster(vol: Volume; directory, cluster: LONGINT; VAR data: ARRAY OF CHAR): LONGINT;
VAR firstSector, lastSector, sector, i, k, j: LONGINT; block: ARRAY vol.blockSize OF CHAR;
BEGIN
 IF (directory = 0) & (vol.bpb.FATType # FAT32) THEN (* root directory of FAT12/16 *)
  firstSector := vol.bpb.RsvdSecCnt + (vol.bpb.NumFATs * vol.bpb.FATSz16);
  lastSector := firstSector + vol.bpb.RootEntCnt DIV (vol.blockSize DIV DirEntrySize) - 1;
  sector := firstSector + (cluster * vol.bpb.SecPerClus);
  FOR i := 0 TO vol.bpb.SecPerClus-1 DO
   IF (sector + i <= lastSector) THEN
    IF SystemMove THEN
     ASSERT(vol.blockSize <= LEN(block));
     SYSTEM.MOVE(SYSTEM.ADR(data[i*vol.blockSize]), SYSTEM.ADR(block[0]), vol.blockSize);
    ELSE
     FOR j := 0 TO vol.blockSize-1 DO
      block[j] := data[i*vol.blockSize+j]
     END
    END;
    PutBlock(vol, -(sector + i), block)
   ELSE
    FOR k := 0 TO (vol.blockSize DIV DirEntrySize)-1 DO
     IF (data[i*vol.blockSize+k*DirEntrySize] # deLAST) THEN (* writing past the end of the root directory traps *)
      ErrorMsg("Root directory overflow"); HALT(20)
     END
    END      
   END
  END;
  RETURN cluster + 1
 ELSE
  IF (directory = 0) & (cluster = 0) THEN cluster := vol.bpb.RootClus END;
  PutBlock(vol, cluster, data);
  RETURN GetFATEntry(vol, cluster)
 END
END PutDirectoryCluster;

(* ExtractLongName - extracts and returns the long name in one physical directory entry, converted to UTF-8 *)
PROCEDURE ExtractLongName(VAR buf: ARRAY OF CHAR; pos: LONGINT; VAR s: ARRAY OF CHAR);
VAR k: INTEGER; ucs4: ARRAY 14 OF LONGINT;
BEGIN
 FOR k := 0 TO 4 DO ucs4[k] := GetUnsignedInteger(buf, pos + 1 + 2*k) END;
 FOR k := 0 TO 5 DO ucs4[k+5] := GetUnsignedInteger(buf, pos + 14 + 2*k) END;
 FOR k := 0 TO 1 DO ucs4[k+11] := GetUnsignedInteger(buf, pos + 28 + 2*k) END;
 ucs4[13] := 0;
 Unicode.UCS4toUTF8(ucs4, s)
END ExtractLongName;

(* CheckSum - calculates the checksum for a short name. The short name starts at position 'pos' in 'b' *)
PROCEDURE CheckSum(VAR b: ARRAY OF CHAR; pos: LONGINT): CHAR;
VAR sum, i: INTEGER;
BEGIN
 sum := 0;
 FOR i := 0 TO 10 DO
  IF ODD(sum) THEN sum := 80H + sum DIV 2
  ELSE sum := sum DIV 2
  END;
  sum := (sum + ORD(b[pos+i])) MOD 256
 END;
 RETURN CHR(sum MOD 256)
END CheckSum;

(* GetDirectoryEntry - reads one physical directory entry from 'b' at position 'pos' and returns its contents in 'direntry' *)
PROCEDURE GetDirectoryEntry*(FATType: SHORTINT; VAR b: ARRAY OF CHAR; pos: LONGINT; VAR direntry: DirEntry; VAR chksum: CHAR;
 VAR index: INTEGER): INTEGER;
VAR ch: CHAR; res, i : INTEGER; ft: FATTime;
BEGIN
 ch := b[pos];
 IF (ch = deFREE) THEN res := deFree
 ELSIF (ch = deLAST) THEN res := deLast
 ELSE
  IF (b[pos] = 05X) THEN b[pos] := 0EFX END;
  direntry.attr := SYSTEM.VAL(SET, b[pos+11]) * {0,1,2,3,4,5,6,7};
  IF (direntry.attr * faLongName = faLongName) THEN
   index := ORD(b[pos]);
   IF (AND(index, 40H) # 0) THEN index := SHORT(AND(3FH, index)); res := deFirstLong
   ELSE res := deLong
   END;
   ExtractLongName(b, pos, direntry.long);    
   chksum := b[pos+13]
  ELSE (* short name or volume entry *)
   FOR i := 0 TO 10 DO direntry.short[i] := b[pos+i] END; direntry.short[11] := 0X;
   IF (faVolumeID IN direntry.attr) THEN res := deVolumeID
   ELSE
    direntry.NTRes := b[pos+12];
    IF (FATType = FAT32) THEN direntry.cluster := GetUnsignedInteger(b, pos+20) * 10000H
    ELSE direntry.cluster := 0
    END;
    direntry.cluster := direntry.cluster + GetUnsignedInteger(b, pos+26);
    IF ~(faDirectory IN direntry.attr) & (direntry.cluster = 0) THEN direntry.cluster := NONE END;
    direntry.size := GetLongint(b, pos+28);
    direntry.creationDate := DateFAT2Oberon(GetUnsignedInteger(b, pos+16));
    ft.time := GetUnsignedInteger(b, pos+14);
    ft.tenth := ORD(b[pos+13]) MOD 200 DIV 100;
    direntry.creationTime := TimeFAT2Oberon(ft);
    direntry.accessDate := DateFAT2Oberon(GetUnsignedInteger(b, pos+18));
    direntry.writeDate := DateFAT2Oberon(GetUnsignedInteger(b, pos+24));
    ft.time := GetUnsignedInteger(b, pos+22); ft.tenth := 0;
    direntry.writeTime := TimeFAT2Oberon(ft);
    res := deShort
   END
  END
 END;
 RETURN res
END GetDirectoryEntry;

PROCEDURE NewDirCacheEntry(VAR dirCache: DirCache; type: SHORTINT; dirCluster, cluster, pos, num: LONGINT);
BEGIN
 IF (dirCache.type # dcInvalid) THEN
  IF (dirCache.next = NIL) THEN NEW(dirCache.next) END; (* recycle to reduce GC overhead *)
  dirCache := dirCache.next
 END;
 dirCache.type := type;
 dirCache.entry.dirInfo.dirCluster := dirCluster;
 dirCache.entry.dirInfo.cluster := cluster;
 dirCache.entry.dirInfo.pos := pos;
 dirCache.entry.dirInfo.num := num
END NewDirCacheEntry;

(* ProcessDirectoryCluster - concatenates single physical directory entries to one logical entry and calls 'handler' *)
PROCEDURE ProcessDirectoryCluster(vol: Volume; VAR dirCache: DirCache; VAR lastFree: BOOLEAN; 
 dirCluster, cluster: LONGINT; VAR b: ARRAY OF CHAR;  VAR direntry: DirEntry;  VAR longidx: INTEGER; VAR chksum: CHAR): BOOLEAN;
VAR pde: DirEntry; long: LongName; index, i, k, n, m, res: INTEGER; cs: CHAR; stop: BOOLEAN;
BEGIN
 i := 0;
 REPEAT
  res := GetDirectoryEntry(vol.bpb.FATType, b, DirEntrySize*i, pde, cs, index);
  IF (res = deFree) THEN
   IF ~lastFree THEN NewDirCacheEntry(dirCache, dcFree, dirCluster, cluster, i*DirEntrySize, 1)
   ELSE INC(dirCache.entry.dirInfo.num)
   END;
   lastFree := TRUE
  ELSIF (res = deLast) THEN
   IF ~lastFree THEN NewDirCacheEntry(dirCache, dcSentinel, dirCluster, cluster, i*DirEntrySize, -1)
   ELSE dirCache.type := dcSentinel; dirCache.entry.dirInfo.num := -1
   END;
   dirCache.next := NIL;
   stop := TRUE
  ELSE
   lastFree := FALSE;
   CASE res OF
   | deVolumeID :
   | deFirstLong : 
     longidx := index; chksum := cs; direntry.long := pde.long;      
     direntry.dirInfo.dirCluster := dirCluster; direntry.dirInfo.cluster := cluster; 
     direntry.dirInfo.pos := i*DirEntrySize; direntry.dirInfo.num := longidx + 1 (* including the short entry *)
   | deLong :
     IF (index = longidx-1) & (cs = chksum) THEN
      DEC(longidx);
      n := 0; WHILE(pde.long[n] # 0X) DO long[n] := pde.long[n]; INC(n) END;
      m := 0; WHILE (direntry.long[m] # 0X) DO long[n] := direntry.long[m]; INC(n); INC(m) END;
      direntry.long := long; direntry.long[n] := 0X
     ELSE longidx := -1; direntry.long := "" (* ignore long name *)
     END
   | deShort :
     long := direntry.long;
     pde.dirInfo := direntry.dirInfo; direntry := pde;
     IF (long = "") OR (CheckSum(b, DirEntrySize*i) # chksum) THEN
      (* no long name or checksum does not match: discard long name and copy short name into long name *)
      FOR n := 0 TO 7 DO long[n] := pde.short[n] END;
      WHILE (long[n-1] = " ") DO DEC(n) END;
      IF (pde.short[8] # " ") OR (pde.short[9] # " ") OR (pde.short[10] # " ") THEN
       long[n] := "."; INC(n);
       FOR k := 8 TO 10 DO long[n] := pde.short[k]; INC(n) END;
       WHILE (long[n-1] = " ") DO DEC(n) END;
      END;
      long[n] := 0X;
      direntry.dirInfo.dirCluster := dirCluster; direntry.dirInfo.cluster := cluster; 
      direntry.dirInfo.pos := i*DirEntrySize; direntry.dirInfo.num := 1
     END;
     direntry.long := long;
     NewDirCacheEntry(dirCache, dcValid, -1, -1, -1, -1);
     dirCache.entry := direntry;
     direntry.long := ""
   END
  END;
  INC(i)
 UNTIL (i = vol.clusterSize DIV DirEntrySize) OR stop;
 RETURN ~stop
END ProcessDirectoryCluster;

(* EnumerateDirectory - enumerates the contens of a directory identified by its first cluster *)
PROCEDURE EnumerateDirectory*(vol: Volume; directory: LONGINT; handler: EnumDirHandler; param: Param);
VAR direntry: DirEntry; cluster, dirCluster, nextCluster: LONGINT; longidx: INTEGER; continue, lastFree: BOOLEAN;
 chksum: CHAR; data: ARRAY vol.clusterSize OF CHAR; dirCache: DirCache;
BEGIN
 IF Trace THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("EnumerateDirectory "); Kernel.WriteInt(directory, 0); 
  Kernel.WriteLn
 END;
 chksum := 0X; longidx := 0;
 IF (directory = 0) & (vol.bpb.FATType = FAT32) THEN dirCluster := vol.bpb.RootClus (* FAT32 root directory *)
 ELSE dirCluster := directory
 END;
 
 IF (vol.dirCache.type = dcInvalid) OR (vol.dirCache.entry.dirInfo.dirCluster # dirCluster) THEN
  dirCache := vol.dirCache; dirCache.type := dcInvalid; dirCache.entry.dirInfo.dirCluster := directory;
  continue := TRUE; lastFree := TRUE; nextCluster := dirCluster;
  REPEAT
   cluster := nextCluster;
   nextCluster := GetDirectoryCluster(vol, dirCluster, cluster, data);
  UNTIL ~ProcessDirectoryCluster(vol, dirCache, lastFree, directory, cluster,  data, direntry, longidx, chksum) OR (nextCluster = -1);
    
  (* fix sentinel *)
  IF (cluster < 0) THEN 
   (* the directory does not contain a deLAST mark because the last entry in the last sector is not free *)
   IF Detail THEN Kernel.WriteString(" adding sentinel"); Kernel.WriteLn END;
   NewDirCacheEntry(dirCache, dcSentinel, dirCluster, -cluster, 0, -1)
  END;  
  IF Detail THEN DumpDirCache(vol) END
 END;
 dirCache := vol.dirCache; continue := TRUE;
 
 IF (handler # NIL) THEN
  WHILE (dirCache # NIL) & (dirCache.type # dcSentinel) & continue DO
   IF (dirCache.type = dcValid) THEN
    param.direntry := dirCache.entry;
    handler(param, continue);
   END;
   dirCache := dirCache.next
  END
 END
END EnumerateDirectory;

(* Writing Directory Entries *)

(* ValidShortChar - checks if a char 'ch' at position 'i' in a short name is valid *)
PROCEDURE ValidShortChar(ch: CHAR; pos: INTEGER): BOOLEAN;
VAR lossy: BOOLEAN;
BEGIN
 (* invalid characters (in order of appearance):  < " ", """, "*", "+", ",", ".", "/", ":", ";", "<", "=", ">", "?", "[", "\", "]", "|" *)
 IF ((ch >= 20X) & (ch # 22X) & (~((ch >= 2AX) & (ch <= 2CX))) & (ch # 2EX) & (ch # 2FX) & (~((ch >= 3AX) & (ch <= 3FX))) &
  (~((ch >= 5BX) & (ch <= 5DX))) & (ch # 7CX)) OR ((ch = 05X) & (pos = 0)) THEN
  RETURN Unicode.UpperCh(ch, lossy) = ch
 ELSE RETURN FALSE
 END
END ValidShortChar;

(* IsShortName - checks if a long name 'l' could be stored in a short name entry *)
PROCEDURE IsShortName(l: LongName): BOOLEAN;
VAR s: ARRAY 12 OF CHAR; i, estart: INTEGER; lossy: BOOLEAN;
BEGIN
 IF (l = ".") OR (l = "..") THEN RETURN TRUE
 ELSIF Unicode.UTF8toASCII(l, s, lossy)  & ~lossy THEN
  i := 0;
  WHILE (i < 11) & (s[i] # 0X) & ValidShortChar(s[i], i) DO INC(i) END;
  IF (s[i] = ".") & (i < 8) THEN
   INC(i); estart := i;
   WHILE ValidShortChar(s[i], i) DO INC(i) END;
   RETURN (s[i] = 0X) & (i - estart <= 3)
  ELSE RETURN (s[i] = 0X)
  END
 END;
 RETURN FALSE
END IsShortName;

(* TailGeneration - generates a short name that does not collides with an existing long or short name *)
PROCEDURE TailGenHandler(p: Param; VAR continue: BOOLEAN);
VAR i,k: INTEGER;
 tail,idx,ofs,offset,delta: LONGINT;
BEGIN
 WITH p: TailGenParam DO
  continue := TRUE;
  (* compare names *)
  i := 0; WHILE (i < 8) & (p.direntry.short[i] = p.short[i]) DO INC(i) END;
  k := 8; WHILE (k < 11) & (p.direntry.short[k] = p.short[k]) DO INC(k) END;
  IF (k = 11) THEN
   IF (i = 8) THEN INCL(p.tails[0], 0) (* identical filename *)
   ELSE
    IF (p.direntry.short[i] = "~") THEN
     (* extract tail value and calculate offset in bit array *)
     tail := 0; k := i+1; offset := 0; delta := 1;
     WHILE (k < 8) & (p.direntry.short[k] >= "0") & (p.direntry.short[k] <= "9") DO
      tail := 10*tail + ORD(p.direntry.short[k]) - ORD("0");
      IF ~(k-i-1 IN p.tailmask) THEN (* k-i-1 is the length of the tail - 1 *)
       (* ajust offset to bit-array *)
       offset := offset - delta + delta DIV 10 
      END; 
      delta := delta * 10;
      INC(k)
     END;
     (* set bit in bitmask *)
     IF (k-i-1 IN p.tailmask) THEN (* k-i-1 is the length of the tail *)
      (* check tail range. If the tail is outside the range we can ignore it since we won't generate a conflicting tail *)
      IF (delta DIV 10 <= tail) & (tail < delta) THEN
       idx := (offset + tail) DIV 32;
       ofs := (offset + tail) MOD 32;
       INCL(p.tails[idx], ofs)
      END;
      RETURN
     END;
    END
   END
  END
 END
END TailGenHandler;

PROCEDURE TailFinder(vol: Volume; directory: Address; p: TailGenParam; VAR tail: LONGINT): BOOLEAN;
VAR delta,i,idx,l,ofs,offset,rlow,t: LONGINT;
BEGIN
 (* calculate size of bit-array and initialize it *)
 offset := 1; delta := 10;
 FOR l := 1 TO 6 DO
  IF (l IN p.tailmask) THEN offset := offset + delta - (delta DIV 10) END;
  delta := delta * 10
 END;
 NEW(p.tails, (offset + 31) DIV 32);
 FOR i := 0 TO LEN(p.tails)-1 DO p.tails[i] := {} END;

 (* seach directory *) 
 INCL(p.tailmask, 0);
 EnumerateDirectory(vol, directory, TailGenHandler, p);
 
 (* try to find a free tail number *)
 tail := 0;
 IF (0 IN p.tails[0]) THEN
  rlow := 1; (* range is rlow....10*rlow-1 *)
  delta := 10; offset := 0;
  FOR l := 1 TO  6 DO
   IF (l IN p.tailmask) THEN
    FOR t := offset+rlow TO offset+10*rlow-1 DO
     idx := t DIV 32;
     ofs := t MOD 32;
     IF ~(ofs IN p.tails[idx]) THEN 
      (* we have found a free tail number, exit *)
      tail := t - offset; RETURN TRUE
     END
    END
   ELSE
    offset := offset - delta;
   END;
   delta := delta * 10;
   rlow := rlow * 10
  END
 ELSE RETURN TRUE
 END;
 RETURN FALSE
END TailFinder;

PROCEDURE TailGeneration(vol: Volume; directory: Address; VAR shortname: ShortName; TailNeeded: BOOLEAN);
VAR tp: TailGenParam; l, len, max, pos, tail: LONGINT;
BEGIN
 IF Detail THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("Tail Generation for '"); 
  Kernel.WriteString(shortname); Kernel.WriteChar("'"); Kernel.WriteLn
 END;
 NEW(tp);
 tp.short := shortname;
 (* first, we look for tails with lengths 1,2 or 3 (~x, ~xx, ~xxx) *)
 tp.tailmask := {1, 2, 3};
 IF ~TailFinder(vol, directory, tp, tail) THEN
  (* now look at each tail length seperately *)
  l := 4;
  REPEAT
   tp.tailmask := {l};
   INC(l)
  UNTIL TailFinder(vol, directory, tp, tail) OR (l = 7)
 END;
 IF TailNeeded OR (0 IN tp.tails[0]) THEN
  IF (tail = 0) & TailNeeded THEN tail := 1 END;
  IF (tail # 0) THEN (* tail found *)
   (* calc length of tail *)
   len := 1; max := 10; WHILE (max-1 < tail) DO max := max*10; INC(len) END;
   (* insert tail, avoid spaces in short name *)
   pos := 7-len;
   WHILE (pos > 0) & (shortname[pos-1] = " ") DO DEC(pos) END;
   shortname[pos] := "~";
   WHILE (len > 0) DO
    shortname[pos+len] := CHR(ORD("0") + tail MOD 10);
    tail := tail DIV 10;
    DEC(len)
   END 
  ELSE 
   (* argh, all possible tails (= 1111105 !) occupied. Raise "You are a Moron" exception *)
   Kernel.WriteString(moduleName); Kernel.WriteString("Too many files with similar names"); 
   Kernel.WriteLn; SYSTEM.HALT(20)
  END
 END;
 IF Detail THEN Kernel.WriteString(" name: '"); Kernel.WriteString(shortname); Kernel.WriteChar("'"); Kernel.WriteLn END 
END TailGeneration;

(* GetShortName - returns a valid short name for a given long name and a directory *)
PROCEDURE GetShortName(vol: Volume; VAR direntry: DirEntry; VAR unicode: UCSName; VAR res: INTEGER);
VAR extPos, i,k, n: LONGINT; ascii: ARRAY 256 OF CHAR; l, lossy: BOOLEAN;
BEGIN
 IF Trace THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("GetShortName ("); Kernel.WriteString(direntry.long);
  Kernel.WriteString("')"); Kernel.WriteLn
 END;
 res := Ok;
 (* calculate the number of physical directory entries needed to store the new name *)
 IF ~IsShortName(direntry.long) THEN
  FOR i := 0 TO 255 DO unicode[i] := -1 END; (* = 0FFFFH *)
  n := 0;
  IF Unicode.UTF8toUCS2(direntry.long, unicode, n) THEN direntry.dirInfo.num := SHORT((n-1 + 12) DIV 13 + 1)
  ELSE ErrorMsg("Filename too long"); SYSTEM.HALT(17)
  END
 ELSE (* short name only *)
  FOR i := 0 TO 10 DO direntry.short[i] := " " END; direntry.short[11] := 0X;
  i := 0;
  WHILE (direntry.long[i] # 0X) & (direntry.long[i] # ".") DO direntry.short[i] := direntry.long[i]; INC(i) END;
  IF (direntry.long[i] = ".") THEN
   extPos := SHORT(i+1); i := 0;
   WHILE (direntry.long[extPos+i] # 0X) DO direntry.short[8+i] := direntry.long[extPos+i]; INC(i) END
  END;
  direntry.dirInfo.num := 1
 END;
 
 IF (direntry.dirInfo.num > 1) THEN
  (* generate short name *)
  (* step 1-4: convert name to upper case OEM (ASCII), set 'lossy conversion'-flag, strip leading and embedded spaces, strip leading periods.
   also remember, if the long name has an extension and the position of its first character *)
  IF ~Unicode.UTF8toASCII(direntry.long, ascii, lossy) THEN res := EInvalidFilename; RETURN END;
  i := 0; k := 0; extPos := -1;
  WHILE (i < 256) & (ascii[i] # 0X) DO
   ascii[k] := Unicode.UpperCh(ascii[i], l);
   IF l THEN ascii[k] := "_"; lossy := TRUE END;
   IF (ascii[k] # " ") & ((ascii[k] # ".") OR (k > 0)) THEN INC(k) END;
   IF (ascii[k] = ".") THEN extPos := -1;
   ELSIF (ascii[k] # ".") & (ascii[k-1] = ".") THEN extPos := SHORT(k)
   END;
   INC(i)
  END;
  IF Detail THEN
   Kernel.WriteString(" UTF8 -> ASCII: '"); Kernel.WriteString(ascii); Kernel.WriteString("'; lossy = "); 
   IF lossy THEN Kernel.WriteString("TRUE") ELSE Kernel.WriteString("FALSE") END
  END;
  (* step 5: copy primary portion of name *)
  FOR i := 0 TO 10 DO direntry.short[i] := " " END; direntry.short[11] := 0X;
  i := 0;
  WHILE (ascii[i] # 0X) & (ascii[i] # ".") & (i < 8) DO direntry.short[i] := ascii[i]; INC(i) END;
  (* step 6: omitted *)
  (* step 7: copy extension *)
  IF (extPos # -1) THEN
   i := 0;
   WHILE (ascii[extPos + i] # 0X) & (i < 3) DO direntry.short[8+i] := ascii[extPos+i]; INC(i) END
  END;
  IF Detail THEN
   Kernel.WriteString(" extracted short name: '"); Kernel.WriteString(direntry.short);
   Kernel.WriteChar("'"); Kernel.WriteLn
  END;
   
  (* numeric tail generation *)
  TailGeneration(vol, direntry.dirInfo.dirCluster, direntry.short, lossy);
 END;
 IF Trace THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("GetShortName: short name is '"); Kernel.WriteString(direntry.short); 
  Kernel.WriteChar("'"); Kernel.WriteLn
 END
END GetShortName;

(** RemoveDirectoryEntry - removes an existing directory entry from the FAT.
 The logical entry may span several physical entries *)
PROCEDURE RemoveDirectoryEntry*(vol: Volume; VAR direntry: DirEntry; VAR res: INTEGER);
VAR cluster, dummy, nextCluster, pos, i: LONGINT; data: ARRAY vol.clusterSize OF CHAR; p, c: DirCache;
BEGIN
 IF (direntry.dirInfo.cluster # -1) THEN
  cluster := direntry.dirInfo.cluster;
  dummy := GetDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
  pos := direntry.dirInfo.pos;
  FOR i := 0 TO direntry.dirInfo.num-1 DO
   data[pos] := 0E5X;
   INC(pos, DirEntrySize);
   IF (i < direntry.dirInfo.num-1) & (pos = vol.clusterSize) THEN
    pos := 0;
    nextCluster := PutDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
    dummy := GetDirectoryCluster(vol, direntry.dirInfo.dirCluster, nextCluster, data);
    cluster := nextCluster
   END
  END;
  dummy := PutDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
  
  (* update dirCache *)
  IF (vol.dirCache.type # dcInvalid) & (direntry.dirInfo.dirCluster = vol.dirCache.entry.dirInfo.dirCluster) THEN
   p := NIL; c := vol.dirCache;
   WHILE (c.type # dcSentinel) & ((c.entry.dirInfo.cluster # direntry.dirInfo.cluster) OR (c.entry.dirInfo.pos # direntry.dirInfo.pos)) DO
    p := c; c := c.next
   END;
   IF (c.type # dcSentinel) THEN c.type := dcFree ELSE SYSTEM.HALT(15) END;
   IF Trace THEN
    Kernel.WriteString(moduleName); Kernel.WriteString("RemoveDirectoryEntry "); Kernel.WriteInt(direntry.dirInfo.cluster, 0); 
    Kernel.WriteChar("@"); Kernel.WriteInt(direntry.dirInfo.pos, 0); Kernel.WriteChar("."); Kernel.WriteInt(direntry.dirInfo.num, 0); 
    Kernel.WriteLn;
    IF Detail THEN DumpDirCache(vol) END
   END
  END;
  (* invalidate entry *) 
  direntry.dirInfo.cluster := -1;
  direntry.dirInfo.pos := -1;
  res := Ok
 ELSE res := Error
 END
END RemoveDirectoryEntry;

(* AllocateDirectoryCluster - allocates a new cluster for a directory and clears its content *)
PROCEDURE AllocateDirectoryCluster(vol: Volume; directory, lastCluster: LONGINT; VAR newCluster: LONGINT);
VAR i, dummy: LONGINT; data: ARRAY vol.clusterSize OF CHAR;
BEGIN
 IF (directory = 0) & (vol.bpb.FATType # FAT32) THEN (* root of FAT12/16 *)
  (* no clusters can be allocated, but the contents of the virtual cluster are cleared *)
  dummy := GetDirectoryCluster(vol, directory, lastCluster+1, data);
  FOR i := 0 TO vol.clusterSize-1 DO
   IF (i MOD DirEntrySize = 0) THEN data[i] := deLAST
   ELSE data[i] := 0X
   END
  END;
  dummy := PutDirectoryCluster(vol, directory, lastCluster+1, data);
  newCluster := lastCluster+1
 ELSE (* 'normal' directory *)
  newCluster := AllocateCluster(vol, lastCluster);
  FOR i := 0 TO -1 DO
   IF (i MOD DirEntrySize = 0) THEN data[i] := deLAST
   ELSE data[i] := 0X
   END
  END;
  vol.PutBlock(vol, newCluster, data)
 END
END AllocateDirectoryCluster;

(* AssignDirectoryEntry - finds a position in the directory 'direntry.dircluster' where the directory entry can be stored *)
PROCEDURE AssignDirectoryEntry(vol: Volume; VAR direntry: DirEntry; VAR res: INTEGER);
VAR c, p, dc: DirCache; pos, num, dummy: LONGINT;
BEGIN
 IF Trace THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("AssignDirectoryEntry: "); Kernel.WriteString(direntry.long); Kernel.WriteLn 
 END;
 IF (vol.dirCache.type = dcInvalid) OR (vol.dirCache.entry.dirInfo.dirCluster # direntry.dirInfo.dirCluster) THEN (* build freeList if not cached *)
  EnumerateDirectory(vol, direntry.dirInfo.dirCluster, NIL, NIL)
 END;
 ASSERT(vol.dirCache.entry.dirInfo.dirCluster = direntry.dirInfo.dirCluster);
 IF Detail THEN
  Kernel.WriteString(" Looking in free list for "); Kernel.WriteInt(direntry.dirInfo.num, 0); Kernel.WriteString(" free entries"); Kernel.WriteLn;
  Kernel.WriteString(" directory cache: "); Kernel.WriteLn;
  DumpDirCache(vol)
 END;
 p := NIL; c := vol.dirCache;
 WHILE (c.type # dcSentinel)  & ((c.type # dcFree) OR (c.entry.dirInfo.num < direntry.dirInfo.num)) DO p := c; c := c.next END;
 direntry.dirInfo.cluster := c.entry.dirInfo.cluster; direntry.dirInfo.pos := c.entry.dirInfo.pos;
 IF Detail THEN
  Kernel.WriteString("   found at cluster "); Kernel.WriteInt(direntry.dirInfo.cluster, 0); Kernel.WriteString(", position ");
  Kernel.WriteInt(direntry.dirInfo.pos, 0); Kernel.WriteLn
 END;
 IF (c.type = dcFree) THEN
  (* we have found a slot within the directory *)
  IF Detail THEN Kernel.WriteString("   within directory"); Kernel.WriteLn END;
  IF (direntry.dirInfo.num < c.entry.dirInfo.num) THEN (* some entries remain free *)
   NEW(dc); dc.entry.dirInfo := c.entry.dirInfo; dc.next := c; 
   c.entry.dirInfo.num := c.entry.dirInfo.num - direntry.dirInfo.num;
   c.entry.dirInfo.pos := c.entry.dirInfo.pos + direntry.dirInfo.num*DirEntrySize;
   WHILE (c.entry.dirInfo.pos > vol.clusterSize) DO
    DEC(c.entry.dirInfo.pos, vol.clusterSize DIV DirEntrySize);
    dummy := GetDirectoryCluster(vol, c.entry.dirInfo.dirCluster, c.entry.dirInfo.cluster, NIL)
   END   
  ELSE dc := c
  END
 ELSE (* slot at the end of the directory *)
  IF (c.entry.dirInfo.pos = vol.clusterSize) THEN
   (* this directory does not contain a deLAST mark because the last entry is located at the end of the last cluster of this directory *)
   AllocateDirectoryCluster(vol, c.entry.dirInfo.dirCluster, c.entry.dirInfo.cluster, c.entry.dirInfo.cluster);
   direntry.dirInfo.cluster := c.entry.dirInfo.cluster; direntry.dirInfo.pos := 0; c.entry.dirInfo.pos := 0
  END;
  
  NEW(dc); dc.entry.dirInfo := c.entry.dirInfo; dc.next := c;
 
  IF Detail THEN Kernel.WriteString("   at the end of the directory; pos = "); Kernel.WriteInt(direntry.dirInfo.pos, 0); Kernel.WriteLn END;
  (* allocate new clusters until the new entry has enough free space *)
  pos := c.entry.dirInfo.pos; num := direntry.dirInfo.num;
  WHILE (pos + num*DirEntrySize > vol.clusterSize) DO
   AllocateDirectoryCluster(vol, c.entry.dirInfo.dirCluster, c.entry.dirInfo.cluster, c.entry.dirInfo.cluster);
   DEC(num, (vol.clusterSize-pos) DIV DirEntrySize); c.entry.dirInfo.pos := 0; pos := 0
  END;
  INC(c.entry.dirInfo.pos, num*DirEntrySize)
 END;
 dc.type := dcValid; dc.entry.dirInfo.num := direntry.dirInfo.num;
 IF (p = NIL) THEN vol.dirCache := dc
 ELSE p.next := dc
 END;
 IF Trace THEN
  Kernel.WriteString(" position: "); Kernel.WriteInt(direntry.dirInfo.cluster, 0); Kernel.WriteChar("@");
  Kernel.WriteInt(direntry.dirInfo.pos, 0); Kernel.WriteChar("."); Kernel.WriteInt(direntry.dirInfo.num, 0);
  Kernel.WriteLn;
  IF Detail THEN DumpDirCache(vol) END
 END
END AssignDirectoryEntry;

(** DeleteClusterChain - deletes a cluster chain, starting at 'link', marking all clusters as free *)
PROCEDURE DeleteClusterChain*(vol: Volume; VAR link: LONGINT);
VAR cluster: LONGINT;
BEGIN
 IF (link >=2) & (link <= vol.bpb.CountOfClusters+1) THEN
  REPEAT
   cluster := link;
   link := GetFATEntry(vol, cluster);
   PutFATEntry(vol, cluster, FREE); 
   INC(vol.bpb.FSInfo.FreeCount)
  UNTIL (link = EOC);
  link := NONE
 END
END DeleteClusterChain;

(* WriteShortEntry - writes a short directory entry into the buffer 'buf' at position 'pos' *)
PROCEDURE WriteShortEntry(VAR data: ARRAY OF CHAR; pos: LONGINT; direntry: DirEntry);
VAR k: INTEGER; ft: FATTime;
BEGIN
 IF (direntry.cluster = NONE) THEN direntry.cluster := 0 END;
 FOR k := 0 TO 10 DO data[pos+k] := direntry.short[k] END;
 data[pos+11] := SYSTEM.VAL(CHAR, direntry.attr);
 data[pos+12] := direntry.NTRes;
 ft := TimeOberon2FAT(direntry.creationTime);
 data[pos+13] := CHR(ft.tenth);
 PutUnsignedInteger(data, pos+14, ft.time);
 PutUnsignedInteger(data, pos+16, DateOberon2FAT(direntry.creationDate));
 PutUnsignedInteger(data, pos+18, DateOberon2FAT(direntry.accessDate));
 PutUnsignedInteger(data, pos+20, direntry.cluster DIV 10000H); (* bits 31-16 *)
 ft := TimeOberon2FAT(direntry.writeTime);
 PutUnsignedInteger(data, pos+22, ft.time);
 PutUnsignedInteger(data, pos+24, DateOberon2FAT(direntry.writeDate));
 PutUnsignedInteger(data, pos+26, direntry.cluster MOD 10000H); (* bits 15-0 *)
 IF ~(faDirectory IN direntry.attr) THEN PutLongint(data, pos+28, direntry.size)
 ELSE PutLongint(data, pos+28, 0)
 END
END WriteShortEntry;

(** WriteDirectoryEntry - writes a directory entry 'direntry' back to the volume 'vol'. 'res'=Ok indicates success *)
PROCEDURE WriteDirectoryEntry*(vol: Volume; VAR direntry: DirEntry; VAR res: INTEGER);
VAR cluster, d, idx, k, n, pos, t, dummy: LONGINT; unicode: UCSName;
 data: ARRAY vol.clusterSize OF CHAR; chksum: CHAR; dirCache: DirCache; 
BEGIN
 (* wp: direntry.long does not collide with existing long names, 
   valid field: direntry.namechanged, direntry.dircluster valid, 
    if ~direntry.namechanged: direntry.num 
    if direntry.sector # -1 then direntry.pos, direntry.NTRes must be valid
 *)
 res := Ok;
   
 IF direntry.namechanged THEN
  IF (direntry.dirInfo.cluster # -1) THEN 
   RemoveDirectoryEntry(vol, direntry, res);
   IF (res # Ok) THEN RETURN END
  END;
  GetShortName(vol, direntry, unicode, res);
  IF (res # Ok) THEN RETURN END;
  AssignDirectoryEntry(vol, direntry, res);
  IF (res # Ok) THEN RETURN END
 ELSE
  ASSERT((direntry.dirInfo.cluster # -1) & (direntry.dirInfo.pos >= 0) & 
   (direntry.dirInfo.pos < vol.clusterSize) & (direntry.dirInfo.num > 0));
 END;
 
 (* write long name *)
 IF direntry.namechanged & (direntry.dirInfo.num > 1) THEN
  n := direntry.dirInfo.num; cluster := direntry.dirInfo.cluster; pos := direntry.dirInfo.pos;
  dummy := GetDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
  chksum := CheckSum(direntry.short, 0);
  WHILE (n > 1) DO
   IF (n < direntry.dirInfo.num) THEN data[pos] := CHR(n-1) ELSE data[pos] := CHR(40H + n-1) END;
   data[pos+11] := SYSTEM.VAL(CHAR, faLongName);
   data[pos+12] := 0X;
   data[pos+13] := chksum;
   PutInteger(data, pos+26, 0);
   k := 0; idx := (n-2)*13;
   FOR k := 0 TO 4 DO PutInteger(data, pos+1+k*2, unicode[idx+k]) END;
   FOR k := 0 TO 5 DO PutInteger(data, pos+14+k*2, unicode[idx+5+k]) END;
   FOR k := 0 TO 1 DO PutInteger(data, pos+28+k*2, unicode[idx+11+k]) END;
   INC(pos, DirEntrySize);
   IF (pos >= vol.clusterSize) THEN
    cluster := PutDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
    dummy := GetDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
    pos := 0
   END;
   DEC(n)
  END;
  dummy := PutDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data)
 ELSE (* find position of short name entry *)
  n := direntry.dirInfo.num; cluster := direntry.dirInfo.cluster; pos := direntry.dirInfo.pos;
  dummy := GetDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
  WHILE (n > 1) DO
   INC(pos, DirEntrySize);
   IF (pos >= vol.clusterSize) THEN
    cluster := dummy;
    dummy := GetDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
    pos := 0
   END;
   DEC(n)
  END;
 END;
 
 (* write short name *)
 Kernel.GetClock(t, d);
 direntry.writeTime := t;
 direntry.writeDate := d;
 dummy := GetDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
 WriteShortEntry(data, pos, direntry);
 dummy := PutDirectoryCluster(vol, direntry.dirInfo.dirCluster, cluster, data);
 direntry.namechanged := FALSE;
 direntry.modified := FALSE;
 (* update dirCache *)
 IF (direntry.dirInfo.dirCluster = vol.dirCache.entry.dirInfo.dirCluster) THEN
  dirCache := vol.dirCache;
  WHILE (dirCache.entry.dirInfo.cluster # direntry.dirInfo.cluster) OR (dirCache.entry.dirInfo.pos # direntry.dirInfo.pos) DO 
   dirCache := dirCache.next 
  END;
  dirCache.entry := direntry
 END;
 (* sync *)
 Sync(vol)
END WriteDirectoryEntry;

(** CreateDirectory - creates a directory in the directory specified by 'parentDir' and returns the cluster of the 
 new directory, BAD if unsuccessful *)
PROCEDURE CreateDirectory*(vol: Volume; parentDir: Address; name: LongName): Address;
VAR de: DirEntry; cluster, dummy, i, t, d: LONGINT; res: INTEGER; data: ARRAY vol.clusterSize OF CHAR;
BEGIN
 IF Trace THEN
  Kernel.WriteString(moduleName); Kernel.WriteString(" creating directory '"); 
  Kernel.WriteString(name); Kernel.WriteChar("'"); Kernel.WriteLn
 END;
 (* find a cluster for the new directory *)
 cluster := AllocateCluster(vol, NONE);
 IF Detail THEN
  Kernel.WriteString(" data cluster of new directory is "); Kernel.WriteInt(cluster, 0); Kernel.WriteLn
 END;
 (* write directory entry into its parent directory *)
 de.long := name; INCL(de.attr, faDirectory); de.NTRes := 0X; de.size := 0; de.cluster := cluster;
 Kernel.GetClock(t, d); de.creationDate := d; de.creationTime := t; de.accessDate := d;
 de.dirInfo.dirCluster := parentDir; de.dirInfo.cluster := -1; de.namechanged := TRUE;
 WriteDirectoryEntry(vol, de, res);
 IF (res # Ok) THEN RETURN BAD END;
 (* clear the whole new cluster *)
 FOR i := 0 TO vol.clusterSize-1 DO data[i] := deLAST END;
 (* write "." and ".." entries into the new directory, bypass name generation *)
 de.dirInfo.dirCluster := cluster; de.dirInfo.cluster := cluster;
 FOR i := 0 TO 10 DO de.short[i] := " " END;
 de.short[0] := "."; de.dirInfo.num := 1; de.dirInfo.pos := 0;
 WriteShortEntry(data, 0, de);
 de.short[1] := "."; de.cluster := parentDir; de.dirInfo.pos := DirEntrySize;
 WriteShortEntry(data, DirEntrySize, de);
 dummy := PutDirectoryCluster(vol, cluster, cluster, data);
 Sync(vol);
 RETURN de.dirInfo.dirCluster
END CreateDirectory;

(** GetDirectoryName - returns the name of a given directory, identified by its first cluster *)
PROCEDURE UpDirHandler(p: Param; VAR continue: BOOLEAN);
BEGIN
 WITH p: UpDirParam DO
  IF (p.direntry.long = "..") THEN p.upCluster := p.direntry.cluster END;
  p.found := (p.direntry.cluster = p.dirCluster) OR 
   ((p.dirCluster = -1) & (p.direntry.long = "..")); (* during the first pass, we need the '..' entry to find the parent dir *)
  continue := ~p.found
 END
END UpDirHandler;

PROCEDURE FindUpDir(vol: Volume; VAR path: LongName; VAR pos:LONGINT; p: UpDirParam);
VAR dirname: LongName; upcluster, i: LONGINT;
BEGIN
 IF (p.dirCluster = 0) THEN path[pos] := "/"; INC(pos) (* root *)
 ELSE
  upcluster := p.upCluster;
  EnumerateDirectory(vol, upcluster, UpDirHandler, p);
  IF p.found THEN
   IF (p.dirCluster # -1) THEN dirname := p.direntry.long ELSE dirname := "" END;
   p.dirCluster := upcluster;
   FindUpDir(vol, path, pos, p);
   IF (dirname # "") THEN
    i := 0;
    WHILE (i < LEN(path)-2) & (dirname[i] # 0X) DO
     path[pos] := dirname[i];
     INC(pos); INC(i)
    END;
    path[pos] := "/"; INC(pos); path[pos] := 0X
   END 
  ELSE ErrorMsg("Invalid directory link"); SYSTEM.HALT(17)
  END
 END 
END FindUpDir;

PROCEDURE GetDirectoryName*(vol: Volume; cluster: LONGINT; VAR path: LongName);
VAR p: UpDirParam; pos: LONGINT;
BEGIN
 IF (cluster # 0) THEN
  NEW(p); p.dirCluster := -1; p.upCluster := cluster; pos := 0;
  FindUpDir(vol, path, pos, p)
 ELSE 
  path := "/"
 END
END GetDirectoryName;

(** GetDirectorySize - returns the size of a given directory, identified by its first cluster.
 the size is a multiple of the cluster size or, in the case of the root directory of a FAT12/FAT16 volume,
 a multiple of the sector size. *)
PROCEDURE GetDirectorySize*(vol: Volume; cluster: LONGINT): LONGINT;
VAR size: LONGINT;
BEGIN
 size := 0;
 IF (cluster = 0) & (vol.bpb.FATType # FAT32) THEN (* root directory of FAT12/16 *)
  size := vol.bpb.RootDirSectors * vol.blockSize
 ELSE
  IF (cluster = 0) THEN cluster := vol.bpb.RootClus END; (* root directory of FAT32 *)
  size := vol.clusterSize;
  cluster := GetFATEntry(vol, cluster);
  WHILE (cluster # EOC) & (cluster # BAD) DO
   INC(size, vol.clusterSize);
   cluster := GetFATEntry(vol, cluster)
  END
 END;
 RETURN size 
END GetDirectorySize;

(** Helper Functions *)

(** DateFAT2Oberon, DateOberon2FAT, TimeFAT2Oberon, TimeOberon2FAT - conversion between FAT and 
 Oberon date/time values *)

(* DOS formats: 
  date: bits 15-9: count of years from 1980 (0-127)
     8-5: month of year (1-12)
     4-0: day of month (1-31)
     
  time: bits 15-11: hours (0-23)
     10-5: minutes (0-59)
     4-0: 2-second count (0-29)
     additional byte: bits 7-8: count of 0.01 seconds (0-199)
     
 Oberon formats:
  time: bits 16-12: hours
     11-6: minutes
     5-0: seconds
     
  date: 30-9: count of years from 1900
     8-5: month of year
     4-0: day of month
*)
PROCEDURE DateFAT2Oberon*(d: LONGINT): LONGINT;
BEGIN RETURN (d DIV 512 MOD 128 + 80) * 512 + d MOD 512
END DateFAT2Oberon;

PROCEDURE DateOberon2FAT*(d: LONGINT): LONGINT;
BEGIN RETURN (d DIV 512 - 80) MOD 128 * 512 + d MOD 512
END DateOberon2FAT;

PROCEDURE TimeFAT2Oberon*(ft: FATTime): LONGINT;
BEGIN RETURN ft.time DIV 2048 MOD 32 * 4096 + ft.time DIV 32 MOD 64 * 64 + ft.time MOD 32 * 2 + ft.tenth DIV 100
END TimeFAT2Oberon;

PROCEDURE TimeOberon2FAT*(t: LONGINT): FATTime;
VAR ft: FATTime;
BEGIN 
 ft.time := t DIV 4096 MOD 32 * 2048 + t DIV 64 MOD 64 * 32 + t MOD 64 DIV 2;
 ft.tenth := 100 * SHORT(AND(t, 1) MOD 200);
 RETURN ft
END TimeOberon2FAT;

(* AND - bitwise AND *)
PROCEDURE AND(a,b: LONGINT): LONGINT;
BEGIN RETURN SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, a) * SYSTEM.VAL(SET, b))
END AND;

(* GetCharacters - copies 'count' bytes from 'b' to 's', starting at 'b[ofs]' *)
PROCEDURE GetCharacters(VAR b: ARRAY OF CHAR; ofs: LONGINT; VAR s: ARRAY OF CHAR; count: LONGINT);
VAR i: INTEGER;
BEGIN 
 i := 0; WHILE (i < count) DO s[i] := b[ofs+i]; INC(i) END
END GetCharacters;

(* PutInteger - writes an integer at offset 'ofs' in 'b' which is assumed to be little endian *)
PROCEDURE PutInteger(VAR b: ARRAY OF CHAR; ofs: LONGINT; value: INTEGER);
BEGIN
 b[ofs] := SYSTEM.VAL(CHAR, value MOD 100H);
 b[ofs+1] := SYSTEM.VAL(CHAR, value DIV 100H)
END PutInteger;

(* GetUnsignedInteger - returns an unsigned integer at offset 'ofs' in 'b' which is assumed to be little endian *)
PROCEDURE GetUnsignedInteger(VAR b: ARRAY OF CHAR; ofs: LONGINT): LONGINT;
BEGIN
 RETURN 100H*LONG(ORD(b[ofs+1])) + LONG(ORD(b[ofs]))
END GetUnsignedInteger; 

(* PutUnsignedInteger - writes an unsigned integer at offset 'ofs' in 'b' which is assumed to be little endian *)
PROCEDURE PutUnsignedInteger(VAR b: ARRAY OF CHAR; ofs, value: LONGINT);
BEGIN
 b[ofs] := SYSTEM.VAL(CHAR, value MOD 100H);
 b[ofs+1] := SYSTEM.VAL(CHAR, (value DIV 100H) MOD 100H)
END PutUnsignedInteger;

(* GetLongint - returns a long integer at offset 'ofs' in 'b' which is assumed to be little endian *)
PROCEDURE GetLongint(VAR b: ARRAY OF CHAR; ofs: LONGINT): LONGINT;
BEGIN
 RETURN 1000000H*LONG(ORD(b[ofs+3])) + 10000H*LONG(ORD(b[ofs+2])) + 
  100H*LONG(ORD(b[ofs+1])) + LONG(ORD(b[ofs]))
END GetLongint; 

(* PutLongint - writes a long integer at offset 'ofs' in 'b' which is assumed to be little endian *)
PROCEDURE PutLongint(VAR b: ARRAY OF CHAR; ofs, value: LONGINT);
VAR i : INTEGER;
BEGIN
 FOR i := 0 TO 3 DO b[ofs+i] := SYSTEM.VAL(CHAR, value MOD 100H); value := value DIV 100H END
END PutLongint;

(** QuickFormat - formats a FAT volume *)
PROCEDURE QuickFormat*(vol: Volume);
VAR i, sector, dummy: LONGINT; data: PCharArray;
BEGIN
 vol.unsafe := TRUE; PutFATEntry(vol, 1, EOC);
 FOR i := 2 TO vol.bpb.CountOfClusters+1 DO
  PutFATEntry(vol, i, FREE)
 END;
 WriteVolumeFlags(vol, FALSE, FALSE);
 vol.bpb.FSInfo.NextFree := 2;
 IF (vol.bpb.FATType # FAT32) THEN
  (* clear root directory *)
  NEW(data, vol.blockSize); FOR i := 0 TO vol.blockSize-1 DO data[i] := deLAST END;
  sector := vol.bpb.RsvdSecCnt + (vol.bpb.NumFATs * vol.bpb.FATSz16);
  FOR i := 0 TO (vol.bpb.RootEntCnt DIV (vol.blockSize DIV DirEntrySize))-1 DO
   vol.PutBlock(vol, -(sector+i), data^)
  END
 ELSE
  (* create and clear root directory *)
  PutFATEntry(vol, 2, EOC); (* allocate cluster 2 for the root directory *)
  vol.bpb.RootClus := 2;
  NEW(data, vol.clusterSize);
  FOR i := 0 TO vol.clusterSize-1 DO data[i] := deLAST END;
  dummy := PutDirectoryCluster(vol, vol.bpb.RootClus, vol.bpb.RootClus, data^);
  INC(vol.bpb.FSInfo.NextFree);
  vol.bpb.FSInfo.FreeCount := vol.bpb.CountOfClusters-1
 END;
 Sync(vol);
 (* reset dirCache *)
 vol.dirCache.type := dcInvalid; vol.dirCache.entry.dirInfo.dirCluster := -1; vol.dirCache.next := NIL
END QuickFormat;

(* ErrorMsg - writes an error message into the Kernel log *)
PROCEDURE ErrorMsg(msg: ARRAY OF CHAR);
BEGIN Kernel.WriteString(msg); Kernel.WriteLn
END ErrorMsg;

(* DumpDirCache - writes the contents of the directory cache into the kernel log *)
PROCEDURE DumpDirCache(vol: Volume);
VAR cd: DirCache;
BEGIN
 Kernel.WriteString(" directory cache: "); Kernel.WriteLn;
 cd := vol.dirCache;
 WHILE (cd # NIL) DO
  Kernel.WriteString(" (");
  CASE cd.type OF
  | dcSentinel: Kernel.WriteChar("S")
  | dcFree: Kernel.WriteChar("F")
  | dcValid: Kernel.WriteChar("V")
  | dcInvalid: Kernel.WriteChar("I")
  END;
  Kernel.WriteString("; "); Kernel.WriteInt(cd.entry.dirInfo.dirCluster, 0); Kernel.WriteChar(".");
  Kernel.WriteInt(cd.entry.dirInfo.cluster, 0); Kernel.WriteChar("@"); 
  Kernel.WriteInt(cd.entry.dirInfo.pos, 0); Kernel.WriteChar("."); Kernel.WriteInt(cd.entry.dirInfo.num, 0); 
  Kernel.WriteString(") "); IF (cd.type = dcValid) THEN Kernel.WriteString(cd.entry.long) END;
  Kernel.WriteLn;
  cd := cd.next
 END;
 Kernel.WriteLn
END DumpDirCache;

BEGIN
 NEW(flushBuffer, FlushBufferSize*1024)
END OFSFATVolumes.
