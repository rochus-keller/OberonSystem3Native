(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSFATTools; (* be *)

IMPORT
 SYSTEM, Oberon, Disks, OFS, Unicode, OFSFATVolumes, 
 OFSFATFiles, Objects, Texts, Files;

CONST
 FREE = OFSFATVolumes.FREE;
 BAD = OFSFATVolumes.BAD;
 (*NONE = OFSFATVolumes.NONE;*)
 USED = -4;
   
TYPE
 FileEntry = POINTER TO RECORD
  name: OFSFATFiles.Filename;
  next: FileEntry
 END;
 
VAR HexTab: ARRAY 16 OF CHAR;
 sdfiles: FileEntry; (* used by Scandisk *)
 safe: BOOLEAN;
 w: Texts.Writer;

PROCEDURE NewStyle(width: LONGINT; tabs: ARRAY OF CHAR): Objects.Object;
VAR obj: Objects.Object; res: INTEGER; a: Objects.AttrMsg;
BEGIN
 Objects.NewObj := NIL;
 Oberon.Call("TextGadgets.NewStyleProc", Oberon.Par, FALSE, res); (* ignore res *)
 obj := Objects.NewObj; Objects.NewObj := NIL;
 IF obj # NIL THEN
  a.id := Objects.set; a.name := "Width"; a.res := -1; Objects.Stamp(a);
  a.class := Objects.Int; a.i := width; obj.handle(obj, a);
  a.id := Objects.set; a.name := "Tabs"; a.res := -1; Objects.Stamp(a);
  a.class := Objects.String; COPY(tabs, a.s); obj.handle(obj, a)
 END;
 RETURN obj
END NewStyle;

PROCEDURE Str(VAR w: Texts.Writer; s: ARRAY OF CHAR);
BEGIN Texts.WriteString(w, s)
END Str;

PROCEDURE Int(VAR w: Texts.Writer; i: LONGINT);
BEGIN Texts.WriteInt(w, i, 0)
END Int;
   
PROCEDURE Tab(VAR w: Texts.Writer); 
BEGIN Texts.Write(w, 09X) 
END Tab;

PROCEDURE Ln(VAR w: Texts.Writer); 
BEGIN Texts.WriteLn(w)
END Ln;

PROCEDURE Bits(VAR w: Texts.Writer; b,n: LONGINT);
VAR s: SET;
BEGIN s := SYSTEM.VAL(SET, b);
 WHILE (n >= 0) DO
  IF (s * {n} = {n}) THEN Texts.Write(w, "1") ELSE Texts.Write(w, "0") END;
  DEC(n)
 END;
 Str(w, "b ")
END Bits;

PROCEDURE Hex(VAR w: Texts.Writer; h,n: LONGINT); 
VAR d: LONGINT;
BEGIN d := 1; 
 DEC(n); WHILE (n > 0) DO d := d*16; DEC(n) END;
 WHILE (d > 0) DO Texts.Write(w, HexTab[(h DIV d) MOD 16]); d := d DIV 16 END;
 Str(w, "H ")
END Hex;
 
PROCEDURE Flush(VAR w: Texts.Writer);
BEGIN
 Texts.Append(Oberon.Log, w.buf)
END Flush;

PROCEDURE PrintInfo(VAR w: Texts.Writer; vol: OFSFATVolumes.Volume);
VAR bpb: OFSFATVolumes.BPB;
 style: Objects.Object;
BEGIN
 bpb := vol.bpb;
 style := NewStyle(600, "200");
 IF (style # NIL) THEN Texts.WriteObj(w, style) END;
 Str(w, " BIOS parameter block"); Ln(w);
 Str(w, "  volume label: "); Tab(w); Str(w, bpb.VolLab); Ln(w);
 Str(w, "  jmpBoot: "); Tab(w); Hex(w, ORD(bpb.jmpBoot[0]),2); Hex(w, ORD(bpb.jmpBoot[1]),2); 
  Hex(w, ORD(bpb.jmpBoot[2]),2); Ln(w);
 Str(w, "  OEM name: "); Tab(w); Str(w, bpb.OEMName); Ln(w);
 Str(w, "  bytes/sector: "); Tab(w); Texts.WriteInt(w, bpb.BytsPerSec, 0); Ln(w);
 Str(w, "  sectors/cluster: "); Tab(w); Texts.WriteInt(w, bpb.SecPerClus, 0); Ln(w);
 Str(w, "  reserved sectors: "); Tab(w); Texts.WriteInt(w, bpb.RsvdSecCnt, 0); Ln(w);
 Str(w, "  number of FATs: "); Tab(w); Texts.WriteInt(w, bpb.NumFATs, 0); Ln(w);
 Str(w, "  root entry count: "); Tab(w); Texts.WriteInt(w, bpb.RootEntCnt, 0); Ln(w);
 Str(w, "  total sectors (16bit): "); Tab(w); Texts.WriteInt(w, bpb.TotSec16, 0); Ln(w);
 Str(w, "  media type: "); Tab(w); Hex(w, ORD(bpb.Media), 2); Ln(w);
 Str(w, "  sectors/FAT (16bit): "); Tab(w); Texts.WriteInt(w, bpb.FATSz16, 0); Ln(w);
 Str(w, "  sectors/track (INT 13H): "); Tab(w); Texts.WriteInt(w, bpb.SecPerTrk, 0); Ln(w);
 Str(w, "  number of heads (INT 13H): "); Tab(w); Texts.WriteInt(w, bpb.NumHeads, 0); Ln(w);
 Str(w, "  hidden sectors: "); Tab(w); Texts.WriteInt(w, bpb.HiddSec, 0); Ln(w);
 Str(w, "  total sectors (32bit): "); Tab(w); Texts.WriteInt(w, bpb.TotSec32, 0); Ln(w);
 Str(w, "  FSInfo: free count: "); Tab(w); Texts.WriteInt(w, bpb.FSInfo.FreeCount, 0); Ln(w);
 Str(w, "  FSInfo: next free: "); Tab(w); Texts.WriteInt(w, bpb.FSInfo.NextFree, 0); Ln(w);
 IF (bpb.FATType = OFSFATVolumes.FAT32) THEN
  Str(w, "  sectors/FAT (32bit): "); Tab(w); Texts.WriteInt(w, bpb.FATSz32, 0); Ln(w);
  Str(w, "  extended flags: "); Tab(w); Bits(w, bpb.ExtFlags, 8); Ln(w);
  Str(w, "  FS version: "); Tab(w); Texts.WriteInt(w, ORD(bpb.FSVer.Major), 0); Texts.Write(w, "."); 
   Texts.WriteInt(w, ORD(bpb.FSVer.Minor), 0); Ln(w);
  Str(w, "  root cluster: "); Tab(w); Texts.WriteInt(w, bpb.RootClus, 0); Ln(w);
  Str(w, "  backup boot sector: "); Tab(w); Texts.WriteInt(w, bpb.BkBootSec, 0); Ln(w);
 END;
 Str(w, "  FAT type: "); Tab(w); Str(w, "FAT");
  IF (bpb.FATType = OFSFATVolumes.FAT12) THEN Str(w, "12")
  ELSIF (bpb.FATType = OFSFATVolumes.FAT16) THEN Str(w, "16")
  ELSE Str(w, "32")
  END; Ln(w);
 Str(w, "  sectors/FAT: "); Tab(w); Texts.WriteInt(w, bpb.FATSz, 0); Ln(w);
 Str(w, "  sectors/root directory: "); Tab(w); Texts.WriteInt(w, bpb.RootDirSectors, 0); Ln(w);
 Str(w, "  first FAT sector: "); Tab(w); Texts.WriteInt(w, bpb.FirstFATSector, 0); Ln(w);
 Str(w, "  first data sector: "); Tab(w); Texts.WriteInt(w, bpb.FirstDataSector, 0); Ln(w);
 Str(w, "  count of clusters: "); Tab(w); Texts.WriteInt(w, bpb.CountOfClusters, 0); Ln(w);
 Str(w, "  bytes/cluster: "); Tab(w); Texts.WriteInt(w, bpb.BytesPerCluster, 0); Ln(w);
 Str(w, "  active FAT: "); Tab(w); 
  IF (bpb.ActiveFAT # -1) THEN Texts.WriteInt(w, bpb.ActiveFAT, 0) ELSE Str(w, "all") END; Ln(w);
 Str(w, "  number of mirrored FATs: "); Tab(w); Texts.WriteInt(w, bpb.MirroredFATs+1, 0); Ln(w); 
 Texts.WriteLn(w);
 style := NewStyle(600, "");
 IF (style # NIL) THEN Texts.WriteObj(w, style) END
END PrintInfo;

PROCEDURE PrintFileInfo(VAR w: Texts.Writer; key: LONGINT; de: OFSFATVolumes.DirEntry);
VAR style: Objects.Object;
BEGIN
 style := NewStyle(600, "200");
 IF (style # NIL) THEN Texts.WriteObj(w, style) END;
 Str(w, " Oberon file key:"); Tab(w); Int(w, key); Ln(w);
 Str(w, " long name: "); Tab(w); Str(w, de.long); Ln(w);
 Str(w, " short name: "); Tab(w); Str(w, de.short); Ln(w);
 Str(w, " attributes: "); Tab(w); 
  IF (OFSFATFiles.faReadOnly IN de.attr) THEN Str(w, "Read-only ") END;
  IF (OFSFATFiles.faHidden IN de.attr) THEN Str(w, "Hidden ") END;
  IF (OFSFATFiles.faSystem IN de.attr) THEN Str(w, "System ") END;
  IF (OFSFATFiles.faVolumeID IN de.attr) THEN Str(w, "VolumeID ") END;
  IF (OFSFATFiles.faDirectory IN de.attr) THEN Str(w, "Directory ") END;
  IF (OFSFATFiles.faArchive IN de.attr) THEN Str(w, "Archive") END;
  Ln(w);
 Str(w, " size: "); Tab(w); Int(w, de.size); Ln(w);
 Str(w, " first cluster: "); Tab(w); Int(w, de.cluster); Ln(w);
 Str(w, " directory entry: "); Ln(w);
 Str(w, "   directory:"); Tab(w); Int(w, de.dirInfo.dirCluster); Ln(w);
 Str(w, "   in cluster:"); Tab(w); Int(w, de.dirInfo.cluster); Ln(w);
 Str(w, "   at position:"); Tab(w); Int(w, de.dirInfo.pos); Ln(w);
 Str(w, "   physical entries:"); Tab(w); Int(w, de.dirInfo.num); Ln(w); 
 style := NewStyle(600, "");
 IF (style # NIL) THEN Texts.WriteObj(w, style) END
END PrintFileInfo;

PROCEDURE GetCacheStatistics(VAR w: Texts.Writer; fs: OFS.FileSystem);
VAR lw: BOOLEAN;
 vol: OFSFATVolumes.Volume;
 style: Objects.Object;
 FAThs, FATcs, Datahs, Datacs, gc, pc, ghc, phc, pwc: LONGINT; 
BEGIN
 vol := fs.vol(OFSFATVolumes.Volume);
 lw := OFSFATVolumes.GetCacheMode(vol);
 OFSFATVolumes.GetCacheSize(vol, OFSFATVolumes.FAT, FAThs, FATcs);
 OFSFATVolumes.GetCacheSize(vol, OFSFATVolumes.Data, Datahs, Datacs);
 OFSFATVolumes.GetCacheStatistics(vol, gc, ghc, pc, phc, pwc);
 style := NewStyle(400, "150");
 IF (style # NIL) THEN Texts.WriteObj(w, style) END;
 Str(w, " FAT Cache Statistics"); Ln(w);
 Str(w, "    lazy writing : "); Tab(w); IF lw THEN Str(w, "enabled") ELSE Str(w, "disabled") END; Ln(w);
 Str(w, "    FAT hash size:"); Tab(w); Texts.WriteInt(w, FAThs, 0); Str(w, " entries"); Ln(w);
 Str(w, "    FAT cache size:"); Tab(w); Texts.WriteInt(w, FATcs, 0); Str(w, "KB (");
  Texts.WriteInt(w, FATcs*vol.blockSize DIV 1024 , 0); Str(w, " sectors)"); Ln(w);
 Str(w, "    data hash size:"); Tab(w); Texts.WriteInt(w, Datahs, 0); Str(w, " entries"); Ln(w);
 Str(w, "    data cache size:"); Tab(w); Texts.WriteInt(w, Datacs, 0); Str(w, "KB (");
  Texts.WriteInt(w, Datacs*vol.bpb.BytesPerCluster DIV 1024 , 0); Str(w, " clusters)"); Ln(w);
 Ln(w);  
 Str(w, "    read hits: "); Tab(w); 
  IF (gc # 0) THEN Texts.WriteInt(w, ghc*100 DIV gc, 1) ELSE Texts.Write(w, "0") END; 
  Texts.WriteString(w, "% ("); Texts.WriteInt(w, ghc, 0); Texts.Write(w, "/"); Texts.WriteInt(w, gc, 0); Texts.Write(w, ")");
  Ln(w);
 Str(w, "    write hits: "); Tab(w); 
  IF (pc # 0) THEN Texts.WriteInt(w, phc*100 DIV pc, 1) ELSE Texts.Write(w, "0") END; 
  Texts.WriteString(w, "% ("); Texts.WriteInt(w, phc, 0); Texts.Write(w, "/"); Texts.WriteInt(w, pc, 0); Texts.Write(w, ")");
  Ln(w);
 Str(w, "    physical writes: "); Tab(w); 
  IF (pc # 0) THEN Texts.WriteInt(w, pwc*100 DIV pc, 1) ELSE Texts.Write(w, "0") END; 
  Texts.WriteString(w, "% ("); Texts.WriteInt(w, pwc, 0); Texts.Write(w, "/"); Texts.WriteInt(w, pc, 0); Texts.Write(w, ")");
  Ln(w);
 style := NewStyle(600, "");
 IF (style # NIL) THEN Texts.WriteObj(w, style) END
END GetCacheStatistics;

(* GetFileSystem - reads a prefix from the reader 'r' and returns the associated file system. The writer is used for error messages *)
PROCEDURE GetFileSystem(VAR r: Texts.Reader; VAR w: Texts.Writer; VAR prefix: OFS.Prefix): OFS.FileSystem;
VAR fs: OFS.FileSystem;
 i, pos: INTEGER;
 ch: CHAR;
 t: Texts.Text;
 beg, end, time: LONGINT;
BEGIN
 ch := " "; 
 WHILE ~r.eot & (ch = " ") DO 
  IF (ch = "^") THEN
   Oberon.GetSelection(t, beg, end, time);
   IF (time = -1) THEN RETURN NIL
   ELSE Texts.OpenReader(r, t, beg);
   END
  END;
  Texts.Read(r, ch)
 END;
 pos := 0; prefix := "";
 WHILE ~r.eot & (ch # ":") & (ch > " ") & (ch # "~") & (pos < LEN(prefix)-1) DO
  prefix[pos] := ch;
  Texts.Read(r, ch); 
  INC(pos)
 END;
 prefix[pos] := 0X;
  
 IF (prefix # "") THEN
  i := 0; WHILE (prefix[i] # 0X) & (prefix[i] # ":") DO INC(i) END; prefix[i] := 0X;
  fs := OFS.This(prefix);
  IF (fs # NIL) THEN
   IF (fs IS OFSFATFiles.FileSystem) THEN RETURN fs
   ELSE Str(w, prefix); Str(w, ": is not a FAT file system")
   END
  ELSE Str(w, prefix); Str(w, ": not found")
  END
 ELSE Str(w, "file system prefix expected")
 END;
 Ln(w);
 RETURN NIL
END GetFileSystem;

(* GetFilename - reads a filename from the reader 'r'. Syntax: '"'[prefix':']filename'"'. The filename must be quoted !!! *)
PROCEDURE GetFilename(VAR r: Texts.Reader; VAR w: Texts.Writer; VAR fs: OFS.FileSystem; VAR prefix, filename: ARRAY OF CHAR): BOOLEAN;
VAR ch: CHAR;
 t: Texts.Text;
 beg, end, time, pos, k: LONGINT;
BEGIN
 Texts.Read(r, ch); 
 WHILE (ch # 22X) & (ch # 0DX) & ~r.eot DO 
  IF (ch = "^") THEN
   Oberon.GetSelection(t, beg, end, time);
   IF (time = -1) THEN RETURN FALSE
   ELSE Texts.OpenReader(r, t, beg);
   END
  END;
  Texts.Read(r, ch) 
 END;
 IF (ch = 22X) & ~r.eot THEN
  fs := NIL; prefix[0] := 0X; filename[0] := 0X; pos := 0;
  Texts.Read(r, ch);
  REPEAT
   filename[pos] := ch;
   IF (ch = ":") & (prefix = "") THEN
    (* what we have seen so far is a file system prefix *)
    k := 0; WHILE (filename[k] # ":") DO prefix[k] := filename[k]; INC(k) END; prefix[k] := 0X;
    fs := OFS.This(prefix);
    IF (fs = NIL) THEN
     Str(w, prefix); Str(w, ": not found");
     RETURN FALSE
    END;
    pos := -1
   END;
   Texts.Read(r, ch);
   INC(pos)
  UNTIL r.eot OR (ch = 22X);
  IF (ch = 22X) THEN
   filename[pos] := 0X;
   IF (fs = NIL) THEN fs := OFS.First() END;
   RETURN TRUE
  ELSE
   fs := NIL;
   filename[0] :=0X
  END;
 END;
 RETURN FALSE
END GetFilename;

(** PrintInformation - prints information on a specific FAT file system such as the contents of the BPB and cache statistics *)
PROCEDURE PrintInformation*; (** prefix *)
VAR fs: OFS.FileSystem;
 prefix: OFS.Prefix;
 r: Texts.Reader;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 fs := GetFileSystem(r, w, prefix);
 IF (fs # NIL) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   WITH fs: OFSFATFiles.FileSystem DO
    Str(w, "Information on "); Str(w, prefix); Texts.Write(w, ":"); Ln(w);
    PrintInfo(w, fs.vol(OFSFATVolumes.Volume))
   END
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system"); Ln(w)
  END
 END;
 Texts.Append(Oberon.Log, w.buf)
END PrintInformation;

(** SetCacheSettings - sets the cache settings of a FAT file system *)
PROCEDURE SetCacheSettings*; (** prefix ("F"["AT"]|"D"["ata"]) hashSize cacheSize *) 
VAR fs: OFS.FileSystem;
 prefix: OFS.Prefix;
 r: Texts.Reader;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 fs := GetFileSystem(r, w, prefix);
 IF (fs # NIL) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   (*TODO*)
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system"); Ln(w)
  END
 END;
 Texts.Append(Oberon.Log, w.buf)
END SetCacheSettings;

(** GetCacheStatistics - prints information on the cache statistics of a FAT file system *)
PROCEDURE PrintCacheStatistics*; (** prefix *)
VAR fs: OFS.FileSystem;
 prefix: OFS.Prefix;
 r: Texts.Reader;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 fs := GetFileSystem(r, w, prefix);
 IF (fs # NIL) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   GetCacheStatistics(w, fs(OFSFATFiles.FileSystem))
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system"); Ln(w)
  END
 END;
 Texts.Append(Oberon.Log, w.buf)
END PrintCacheStatistics;

(** EnableLazyWriting - enables or disables the write-behind cache of a FAT file system *)
PROCEDURE EnableLazyWriting*; (** prefix ["E"|"D"]. E: enable, D: disable *)
VAR fs: OFS.FileSystem;
 prefix: OFS.Prefix;
 r: Texts.Reader;
 s: Texts.Scanner;
 dw: BOOLEAN;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 fs := GetFileSystem(r, w, prefix);
 IF (fs # NIL) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   WITH fs: OFSFATFiles.FileSystem DO
    Texts.OpenScanner(s, Oberon.Par.text, Texts.Pos(r));
    Texts.Scan(s); 
    IF (s.class = Texts.Name) & ((CAP(s.s[0]) = "E") OR (CAP(s.s[0]) = "D")) THEN 
     Str(w, prefix);
     dw := CAP(s.s[0]) = "E";
     IF dw THEN
      OFSFATVolumes.SetCacheMode(fs.vol(OFSFATVolumes.Volume), TRUE);
      Str(w, ": lazy writing enabled."); Ln(w)
     ELSE
      OFSFATVolumes.SetCacheMode(fs.vol(OFSFATVolumes.Volume), FALSE);
      Str(w, ": lazy writing disabled."); Ln(w)
     END
    ELSE Str(w, "Syntax error: e/d exptected"); Ln(w)
    END
   END
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system"); Ln(w)
  END
 END;
 Texts.Append(Oberon.Log, w.buf)
END EnableLazyWriting;

(** CreateDir - creates a directory on a FAT file systems. Relative path names are ok *)
PROCEDURE CreateDir*; (** '"' [prefix ':' ] directory '"' *)
VAR fs: OFS.FileSystem;
 r: Texts.Reader;
 newDir, utf8Dir: OFSFATFiles.Filename;
 prefix: OFS.Prefix;
 res: INTEGER;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 IF GetFilename(r, w, fs, prefix, newDir) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   Str(w, "Creating directory "); Str(w, prefix); Texts.Write(w, ":"); 
    Str(w, newDir); Str(w, "...");
   Unicode.ASCIItoUTF8(newDir, utf8Dir);
   OFSFATFiles.CreateDirectory(fs(OFSFATFiles.FileSystem), utf8Dir, res);
   IF (res = 0) THEN 
    Str(w, "ok"); Ln(w);
    Str(w, "OFSFATTools.ChangeDir "); Texts.Write(w, 022X); Str(w, prefix); Str(w, ":"); 
    Str(w, newDir); Texts.Write(w, 022X)
   ELSE Str(w, "error")
   END
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system")
  END;
  Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf)
END CreateDir;

(** ChangeDir - changes the current directory on a FAT file system. Relative path names are ok *)
PROCEDURE ChangeDir*; (** '"' [prefix ':'] directory '"' *)
VAR fs: OFS.FileSystem;
 r: Texts.Reader;
 newDir: OFSFATFiles.Filename;
 prefix: OFS.Prefix;
 res: INTEGER;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 IF GetFilename(r, w, fs, prefix, newDir) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   Str(w, "Changing directory "); Str(w, prefix); Texts.Write(w, ":"); 
    Str(w, newDir); Str(w, "...");
   Unicode.ASCIItoUTF8(newDir, newDir);
   OFSFATFiles.ChangeDirectory(fs(OFSFATFiles.FileSystem), newDir, res);
   IF (res = 0) THEN Str(w, "ok")
   ELSE Str(w, "not found")
   END
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system")
  END;
  Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf)
END ChangeDir;  

(** CurrentDir - prints the name of the current directory on a FAT file system. *)
PROCEDURE CurrentDir*; (** prefix *)
VAR fs: OFS.FileSystem;
 prefix: OFS.Prefix;
 r: Texts.Reader;
 currDir: OFSFATFiles.Filename;
 lossy: BOOLEAN;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 fs := GetFileSystem(r, w, prefix);
 IF (fs # NIL) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   OFSFATFiles.CurrentDirectory(fs(OFSFATFiles.FileSystem), currDir);
   IF Unicode.UTF8toASCII(currDir, currDir, lossy) THEN
    Str(w, "Current directory "); Str(w, prefix); Texts.Write(w, ":"); Str(w, currDir)
   ELSE Str(w, "Can not convert UTF-8 name to ASCII")
   END
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system")
  END;
  Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf)
END CurrentDir;

(** RemoveDir - deletes a directory on a FAT file system. Relative path names are ok.
 RemoveDir fails if the directory is not empty.
 If the switch "\r" is supplied, RemoveDir deletes recursively all contents of the directory and finally the directory itself. *)
PROCEDURE RemoveDir*; (** '"' [prefix ':'] directory '"' ["\r"].*)
VAR fs: OFS.FileSystem;
 r: Texts.Reader;
 dirName: OFSFATFiles.Filename;
 prefix: OFS.Prefix;
 ch: CHAR;
 l, recursive: BOOLEAN;
 res: INTEGER;
 msg: ARRAY 64 OF CHAR;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 IF GetFilename(r, w, fs, prefix, dirName) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   recursive := FALSE;
   IF ~r.eot THEN 
    REPEAT
     Texts.Read(r, ch);
     IF (ch = "\") THEN
      Texts.Read(r, ch);
      ch := Unicode.UpperCh(ch, l);
      IF (ch = "R") THEN recursive := TRUE
      ELSE Str(w, "Invalid parameter '\"); Texts.Write(w, ch); Texts.Write(w, "'"); Ln(w)
      END;
     END
    UNTIL r.eot OR (ch = "~")
   END;  
  
   Str(w, "Deleting directory "); Str(w, prefix); Texts.Write(w, ":"); 
    Str(w, dirName); Str(w, "...");
   Unicode.ASCIItoUTF8(dirName, dirName);
   OFSFATFiles.DeleteDirectory(fs(OFSFATFiles.FileSystem), dirName, recursive, res);
   OFSFATFiles.FormatErrorMsg(res, msg);
   Str(w, msg)
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system")
  END;   
  Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf)
END RemoveDir;

(** FileInfo - prints low-level information of a file handle on a FAT file system *)
PROCEDURE FileInfo*;
VAR fs: OFS.FileSystem;
 r: Texts.Reader;
 filename: OFSFATFiles.Filename;
 prefix: OFS.Prefix;
 f: OFS.File;
 de: OFSFATVolumes.DirEntry;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 IF GetFilename(r, w, fs, prefix, filename) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   OFS.JoinName(fs.prefix, filename, filename);
   f := Files.Old(filename);
   IF (f # NIL) & (f.fs IS OFSFATFiles.FileSystem) THEN
    OFSFATFiles.GetFileDescriptor(f(OFSFATFiles.File), de);
    Str(w, "File Handle of "); Str(w, filename); Ln(w);
    PrintFileInfo(w, f.key, de)
   ELSE Str(w, "Can not open "); Str(w, filename);
    IF (f # NIL) THEN Str(w, ": "); Str(w, f.fs.prefix); Str(w, " is not a FAT file system") END
   END
  ELSE Str(w, prefix); Str(w, ": is not a FAT file sytem")
  END;
  Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf) 
END FileInfo;

(** DirectoryInfo - prints low-level information of a directory on a FAT file system *)
PROCEDURE DirectoryInfo*;
VAR fs: OFS.FileSystem; r: Texts.Reader;
 filename: OFSFATFiles.Filename; prefix: OFS.Prefix;
 f: OFS.File; de: OFSFATVolumes.DirEntry; idx, res: INTEGER;
 FATType: SHORTINT; chksum: CHAR; dir, clus, index: LONGINT; 
 cluster: POINTER TO ARRAY OF CHAR;
 vol: OFSFATVolumes.Volume;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 IF GetFilename(r, w, fs, prefix, filename) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN
   OFS.JoinName(fs.prefix, filename, filename);
   f := Files.Old(filename);
   IF (f # NIL) & (f.fs IS OFSFATFiles.FileSystem) THEN
    OFSFATFiles.GetFileDescriptor(f(OFSFATFiles.File), de);
    Files.Close(f);
    Str(w, "File Handle of "); Str(w, filename); Ln(w);
    PrintFileInfo(w, f.key, de);
    IF (OFSFATFiles.faDirectory IN de.attr) THEN
     vol := fs.vol(OFSFATVolumes.Volume);
     FATType := vol.bpb.FATType;
     NEW(cluster, vol.bpb.BytesPerCluster);
     Str(w, "Directory Contents: "); Ln(w);
     dir := de.cluster; IF (dir = -1) THEN dir := 0 END; (* root *)
     clus := dir;
     clus := OFSFATVolumes.GetDirectoryCluster(vol, dir, clus, cluster^);
     res := 0; index := 0;
     WHILE (res # 1) DO
      res := OFSFATVolumes.GetDirectoryEntry(FATType, cluster^, index*32, de, chksum, idx);
      Texts.WriteInt(w, index+1, 4); Str(w, ": ");
      CASE res OF
      | 0: Str(w, "free")
      | 1: Str(w, "last valid entry")
      | 2: Str(w, "volume ID: "); Str(w, de.short)
      | 3: Str(w, "first part of long name: '"); Str(w, de.long); Str(w, "'; checksum: "); Hex(w, ORD(chksum), 2)
      | 4: Str(w, "part of long name: '"); Str(w, de.long); Str(w, "'; checksum: "); Hex(w, ORD(chksum), 2)
      | 5: Str(w, "short name: '"); Str(w, de.short); Str(w, "'; size: "); Int(w, de.size); Str(w, "; first cluster: ");
       Int(w, de.cluster); Str(w, "; attributes: ");
       IF (OFSFATFiles.faReadOnly IN de.attr) THEN Str(w, "R") END;
       IF (OFSFATFiles.faHidden IN de.attr) THEN Str(w, "H") END;
       IF (OFSFATFiles.faSystem IN de.attr) THEN Str(w, "S") END;
       IF (OFSFATFiles.faVolumeID IN de.attr) THEN Str(w, "V") END;
       IF (OFSFATFiles.faDirectory IN de.attr) THEN Str(w, "D") END;
       IF (OFSFATFiles.faArchive IN de.attr) THEN Str(w, "A") END
      ELSE Str(w, "invalid/unknown type")
      END;
      Ln(w);
      index := (index + 1) MOD (vol.bpb.BytesPerCluster DIV 32);
      IF (index = 0) THEN
       IF (clus # -1) THEN clus := OFSFATVolumes.GetDirectoryCluster(vol, dir, clus, cluster^)
       ELSE res := 1
       END
      END
     END
    ELSE Str(w, filename); Str(w, " is not a directory")
    END
   ELSE Str(w, "Can not open "); Str(w, filename);
    IF (f # NIL) THEN Str(w, ": "); Str(w, f.fs.prefix); Str(w, " is not a FAT file system") END
   END
  ELSE Str(w, prefix); Str(w, ": is not a FAT file sytem")
  END;
  Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf) 
END DirectoryInfo;

(** Unsafe - set unsafe mode *)
PROCEDURE Unsafe*; (** ~ *)
BEGIN
 safe := FALSE;
 Str(w, "Now in UNSAFE mode!"); Ln(w);
 Texts.Append(Oberon.Log, w.buf) 
END Unsafe;

(** Safe - set safe mode *)
PROCEDURE Safe*; (** ~ *)
BEGIN
 safe := TRUE;
 Str(w, "Now in safe mode"); Ln(w);
 Texts.Append(Oberon.Log, w.buf) 
END Safe;

(** QuickFormat - formats a FAT file system by clearing the contents of the FAT copies and of the root directory.
 The current directory is set to the root directory. *)
PROCEDURE QuickFormat*; (** prefix *)
VAR fs: OFS.FileSystem;
 r: Texts.Reader;
 prefix: OFS.Prefix;
 res: INTEGER;
BEGIN
 IF ~safe THEN
  safe := TRUE;
  Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
  fs := GetFileSystem(r, w, prefix);
  IF (fs # NIL) THEN
   IF (fs IS OFSFATFiles.FileSystem) THEN
    Str(w, "Formatting..."); 
    Texts.Append(Oberon.Log, w.buf);
    OFSFATFiles.QuickFormat(fs(OFSFATFiles.FileSystem), res);
    IF (res = OFSFATFiles.Ok) THEN Str(w, "Ok")
    ELSE Str(w, "open files ! Close all open files, run the Garbage Collector and try again.")
    END
   ELSE Str(w, prefix); Str(w, ": is not a FAT file system")
   END;
   Ln(w)
  END
 ELSE
  Str(w, "  To reformat this partition, execute"); Ln(w);
  Str(w, "  OFSFATTools.Unsafe and try again"); Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf)
END QuickFormat;

(** Scandisk - scans the disk for lost cluster chains and invalid directory entries as well as cross-linked files. 
 The directory structure is not checked.
 WARNING: Scandisk uses global variables and is thus not thread-safe ! *)
PROCEDURE ScandiskHandler(name: ARRAY OF CHAR; time, date, size: LONGINT; VAR flags: SET);
VAR fe: FileEntry;
BEGIN
 NEW(fe); COPY(name, fe.name);
 fe.next := sdfiles; sdfiles := fe
END ScandiskHandler;

PROCEDURE Scandisk*; (** prefix *)
VAR fs: OFS.FileSystem; r: Texts.Reader;
 prefix: OFS.Prefix; res: INTEGER; flags: SET;
 map: POINTER TO ARRAY OF RECORD
  type: SHORTINT; link: LONGINT;
  file: FileEntry;
 END; 
 vol: OFSFATVolumes.Volume;
 f: OFS.File;
 fe, fetmp: FileEntry; cluster, count, expected, i, freeCount, n, cnt: LONGINT;
 t: SHORTINT; handle: OFSFATVolumes.DirEntry; Error: BOOLEAN;
BEGIN
 Texts.OpenReader(r, Oberon.Par.text, Oberon.Par.pos);
 Ln(w); Str(w, "ScanDisk"); Ln(w);
 Str(w, "*******"); Ln(w);
 fs := GetFileSystem(r, w, prefix);
 IF (fs # NIL) THEN
  IF (fs IS OFSFATFiles.FileSystem) THEN   
   vol := fs.vol(OFSFATVolumes.Volume);
   (* run GC *)
   Str(w, "  Garbage collecting to remove unreferenced anonymous files...");Ln(w); Flush(w);
   Oberon.Collect;
   Str(w, "  Done"); Ln(w);
   (* check if there are open anonymous files *)
   IF (OFSFATFiles.HasAnonymousFiles(fs(OFSFATFiles.FileSystem))) THEN
    Str(w, "  There are open anonymous files on this volume. Scandisk cannot run.");
    Ln(w); Flush(w); RETURN
   END;
   (* get a list of all files *)
   Str(w, "  Reading directories..."); Ln(w); Flush(w);
   OFSFATFiles.ChangeDirectory(fs(OFSFATFiles.FileSystem), "/", res);
   sdfiles := NIL;
   flags := {}; INCL(flags, OFS.EnumRecursive);
   fs.Enumerate(fs, "*", flags, ScandiskHandler);
   Str(w, "  Done"); Ln(w);
   (* create a map of the FAT *)
   NEW(map, vol.bpb.CountOfClusters);
   FOR i := 0 TO vol.bpb.CountOfClusters-1 DO
    map[i].link := OFSFATVolumes.GetFATEntry(vol, i+2);
    IF (map[i].link = FREE) THEN t := FREE
    ELSIF (map[i].link = BAD) THEN t := BAD
    ELSE t := USED
    END;
    map[i].type := t;
    map[i].file := NIL
   END;
   IF (vol.bpb.FATType = OFSFATVolumes.FAT32) THEN
    NEW(fetmp); fetmp.name := "/";
    map[vol.bpb.RootClus-2].file := fetmp
   END;
   (* check cluster chains of every file *)
   Str(w, "  Checking files...."); Ln(w); Flush(w);
   fe := sdfiles;
   WHILE (fe # NIL) DO
    (* workaround for directories *)
    n := 0; WHILE (fe.name[n] # 0X) DO INC(n) END;
    IF (n > 0) & (fe.name[n-1] = "/") THEN fe.name[n-1] := 0X; DEC(n) END;
    f := Files.Old(fe.name);
    IF (f # NIL) THEN
     OFSFATFiles.GetFileDescriptor(f(OFSFATFiles.File), handle);
     IF ~((OFSFATFiles.faDirectory IN handle.attr) & ((handle.long = ".") OR (handle.long = ".."))) THEN (* skip "." and ".." *)
      cluster := handle.cluster; count := 0; 
      expected := (handle.size + vol.bpb.BytesPerCluster-1) DIV vol.bpb.BytesPerCluster;
      WHILE (cluster >= 2) & (cluster <= vol.bpb.CountOfClusters+1) & (count < expected+10) DO
       INC(count);
       NEW(fetmp); fetmp.name := fe.name; fetmp.next := map[cluster-2].file;
       map[cluster-2].file := fetmp; 
       cluster := OFSFATVolumes.GetFATEntry(vol, cluster)
      END;
      IF (count # expected) THEN
       Error := TRUE;
       Str(w, "    cluster chain does not match file size: "); Str(w, handle.long); Ln(w); Flush(w)
      END
     END
    END;
    fe := fe.next;
   END;
   Str(w, "  Done"); Ln(w);
   (* find cross-linked files  *)
   Str(w, "  Checking for cross-linkes files....");  Ln(w); Flush(w);
   FOR i := 0 TO vol.bpb.CountOfClusters-1 DO
    IF (map[i].type = USED) THEN
     IF (map[i].file # NIL) & (map[i].file.next # NIL) THEN
      Error := TRUE;
      Str(w, "    cross-linked cluster: "); Int(w, i+2); Str(w, " files: "); Ln(w);
      fetmp := map[i].file;
      WHILE (fetmp # NIL) DO
       Str(w, "      "); Str(w, fetmp.name); Ln(w);
       fetmp := fetmp.next
      END;
      Ln(w); Flush(w)
     END
    END
   END;
   Str(w, "  Done"); Ln(w);
   (* find lost cluster chains  & count number of free clusters *)
   Str(w, "  Checking for lost cluster-chains..."); Ln(w); Flush(w);
   Str(w, "   "); cnt := 0;
   FOR i := 0 TO vol.bpb.CountOfClusters-1 DO
    IF (map[i].type = USED) THEN
     IF (map[i].file = NIL) THEN
      Error := TRUE;
      Texts.WriteInt(w, i+2, 8); INC(cnt);
      IF (cnt MOD 8 = 0) THEN 
       Ln(w); Str(w, "   "); IF (cnt MOD 32 = 0) THEN Flush(w) END
      END
     END
    ELSIF (map[i].type = FREE) THEN INC(freeCount);
    END
   END;
   IF (cnt MOD 8 # 0) THEN Ln(w) END;
   Str(w, " Done"); Ln(w); Flush(w);
   Str(w, "  Checking free space..."); Ln(w);
   IF (vol.bpb.FATType = OFSFATVolumes.FAT32) THEN 
    IF (freeCount # vol.bpb.FSInfo.FreeCount) THEN
     Str(w, "    reported free count: "); Int(w, vol.bpb.FSInfo.FreeCount); Ln(w);
     Str(w, "    real free count: "); Int(w, freeCount); Ln(w);
     vol.bpb.FSInfo.FreeCount := freeCount;
     Str(w, "    Error fixed."); Ln(w)
    END
   END;   
   Str(w, "  Done"); Ln(w); Ln(w);
   IF Error THEN
    INCL(vol.flags, Disks.ReadOnly);
    Str(w, "This file systems has errors."); Ln(w);
    Str(w, "The volume has been write-protected."); Ln(w);
    Str(w, "Please run ScanDisk under MS-DOS"); Ln(w)
   ELSE Str(w, "No errors found");
    IF (Disks.ReadOnly IN vol.flags) & ~vol.MountedReadOnly THEN
     EXCL(vol.flags, Disks.ReadOnly);
     Ln(w); Str(w, "The file system's write-protection has been disabled.")
    END
   END;
   Ln(w)
  ELSE Str(w, prefix); Str(w, ": is not a FAT file system")
  END;
  Ln(w)
 END;
 Texts.Append(Oberon.Log, w.buf)
END Scandisk;


(* Initialization *)
PROCEDURE InitHexTab;
VAR i: INTEGER;
BEGIN
 FOR i := 0 TO 9 DO HexTab[i] := CHR(i + ORD("0")) END;
 FOR i := 0 TO 5 DO HexTab[10+i] := CHR(i + ORD("A")) END
END InitHexTab;

(*
PROCEDURE CreateFile*; (** name sizeMB *)
VAR f: Files.File; r: Files.Rider; size, x: LONGINT; s: Texts.Scanner; buf: ARRAY 16384 OF CHAR;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(s);
 IF s.class IN {Texts.Name, Texts.String} THEN
  COPY(s.s, buf); Texts.Scan(s);
  IF (s.class = Texts.Int) & (s.i >= 0) THEN
   size := s.i*1024*1024;
   Str(w, buf); Texts.Append(Oberon.Log, w.buf);
   f := Files.New(buf);
   IF f # NIL THEN
    FOR x := 0 TO LEN(buf)-1 DO buf[x] := 0X END;
    Files.Set(r, f, 0);
    WHILE size > 0 DO
     IF size > LEN(buf) THEN x := LEN(buf) ELSE x := size END;
     Files.WriteBytes(r, buf, x);
     ASSERT(r.res = 0);
     DEC(size, x)
    END;
    Files.Register(f);
    Str(w, " created")
   ELSE
    Str(w, " bad file name")
   END;
   Ln(w); Texts.Append(Oberon.Log, w.buf)
  END
 END
END CreateFile;
*)

BEGIN
 safe := TRUE; InitHexTab;
 Texts.OpenWriter(w)
END OFSFATTools.

 

System.Free OFSFATTools ~
Compiler.Compile \s OFSFATTools.Mod ~


OFSFATTools.QuickFormat FAT ~
OFSFATTools.PrintInformation FAT~
OFSFATTools.GetCacheStatistics FAT ~
OFSFATTools.SetCacheSettings FAT E ~
OFSFATTools.CreateDir  ^ "FAT:TEST"~ "FAT:COOL"~ "FAT:HUGA" "FAT:/Native"~
OFSFATTools.CurrentDir FAT:~
OFSFATTools.ChangeDir ^ "FAT:huga"~ "FAT:/"~
OFSFATTools.RemoveDir ^ "FAT:TEST" \r ~ "FAT:/COOL"  ~

OFSFATTools.CopyFiles [prefix":"]mask => ([prefix":"]directory | prefix[":"]) ["\r"] ~
OFSFATTools.DeleteFiles [prefix":"]mask ~


System.Directory FAT: \d \f \l

OFSFATTools.Scandisk FAT: ~

Oberon.Collect

OFSFATTools.ExtendFile FAT:/Temp.Dsk 2 new ~
OFSTools.Mount DST FileFS FAT:/Temp.Dsk ~
