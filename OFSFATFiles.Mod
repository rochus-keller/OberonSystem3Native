(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSFATFiles; (* be *)

(** IMPORTANT: all ARRAY OF CHARs passed to OFSFATFiles must be in UTF-8 format, and
 all filenames obtained from OFSFATFiles are in UTF-8 format *)

IMPORT 
 SYSTEM, Kernel, Disks, OFS, OFSFATVolumes, Unicode;
 
CONST
 moduleName = "OFSFATFiles: ";
 Trace = FALSE;
 Detail = Trace & FALSE;

 (** Result codes *)
 Ok* = OFSFATVolumes.Ok;
 Error* = OFSFATVolumes.Error;
 EInvalidFilename* = OFSFATVolumes.EInvalidFilename;
 ERootDirectoryFull* = OFSFATVolumes.ERootFull;
 EFileNotFound* = -4;
 EFileProtected* = -5;
 EOpenFiles* = -10;
 ENotADirectory* = -11;
 EDirectoryNotFound* = -12;
 EDirectoryNotEmpty* = -13;
 ECannotDeleteRootDirectory* = -14;
 ECannotDeleteDirectory* = -15;
 
 (** File Attributes *)
 faReadOnly* = OFSFATVolumes.faReadOnly; 
 faHidden* = OFSFATVolumes.faHidden; 
 faSystem* = OFSFATVolumes.faSystem; 
 faVolumeID* = OFSFATVolumes.faVolumeID;
 faDirectory* = OFSFATVolumes.faDirectory; 
 faArchive* = OFSFATVolumes.faArchive;
 
 (** Files with any of these attributes set are considered to be read-only *)
 FileProtection* = { faReadOnly, faSystem };

TYPE
 Filename* = OFSFATVolumes.LongName;
 Address = OFS.Address;

 (** a FAT file. Do not instantiate directly, use OFS.New() or OFS.Old() instead *)
 File * = POINTER TO RECORD(OFS.File)
  direntry: OFSFATVolumes.DirEntry;
  registered: BOOLEAN;
 END;
 
 Rider  = OFS.Rider;
 
 FileList = POINTER TO RECORD
  file[UNTRACED]: File; (* the file list must not be traced by the garbage collector *)
  next: FileList;
 END;
  
 (* a Hint points to the sector of the file the associated rider's apos points to *)
 (* the sector number itself is not necessary, but the cluster number is needed to
  make FAT lookups. 
 *)
 Hint = POINTER TO RECORD(OFS.Hint) (* this hint is used by the rider to avoid many FAT lookups *)
  cluster: LONGINT; (* cluster number *)
  start, end: LONGINT; (* positions between start and end belong to this cluster *)
 END; 
 
 (* FileSystem - the FAT file system *)
 FileSystem* = POINTER TO RECORD(OFS.FileSystem)
  currentDirCluster: LONGINT; (* first cluster of current directory, 0 = root *)
  filekeyIdx: LONGINT; (* for files that have no clusters assigned *)
  lnCaseSensitive: BOOLEAN; (* if TRUE long names are case sensitive *)
  fopen,                          (* list of all registered open files that have no cluster assigned *)
  fanonymous: FileList; (* list of all anonymous files (created with 'New' but not registered) *)
  BytesPerCluster: LONGINT;
 END;
 
 (* DirList - caches the contents of a directory *)
 DirList = POINTER TO RECORD
  name: Filename;
  cluster: LONGINT;
  next: DirList
 END;
 
 DirParam = POINTER TO RECORD(OFSFATVolumes.ParamDesc)
  fs: FileSystem;
  flags: SET;
  mask: Filename;
  handler: OFS.EntryHandler;
  dirlist: DirList;
  default: BOOLEAN;
 END;

 FindParam = POINTER TO RECORD(OFSFATVolumes.ParamDesc)
  name: Filename;
  flags: SET;
  file: File;
  casesensitive, matched: BOOLEAN;
 END;
 
 CountParam = POINTER TO RECORD(OFSFATVolumes.ParamDesc)
  count: LONGINT;
 END;
 
 DelDirParam = POINTER TO RECORD(OFSFATVolumes.ParamDesc)
  fs: FileSystem;
  res: INTEGER;
  recursive: BOOLEAN;
 END;
 
VAR showHiddenFiles: BOOLEAN;
 
(** File handling *)
  
(** FileKey - returns an unique id for file registered in the file system, or 0 if it does not exist. *)
PROCEDURE  FileKey(fs: OFS.FileSystem; name: ARRAY OF CHAR): LONGINT;
VAR f: File;
BEGIN 
 IF Trace THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("FileKey ('"); Kernel.WriteString(name); 
  Kernel.WriteString("')"); Kernel.WriteLn 
 END;
 f := FindFile(fs, name);
 IF (f # NIL) THEN RETURN f.key
 ELSE RETURN 0
 END
END FileKey;

(** New - creates a new file with the specified name. *)
PROCEDURE New(fs: OFS.FileSystem; name: ARRAY OF CHAR): OFS.File;
VAR path, filename: Filename; dir, f: File; dircluster, t, d: LONGINT; res: INTEGER;
BEGIN
 IF Trace THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("New ('"); Kernel.WriteString(name); 
  Kernel.WriteString("') "); Kernel.WriteLn
 END;
 WITH fs: FileSystem DO
  IF Split(name, path, filename) THEN
   IF (path = "") THEN dircluster := fs.currentDirCluster
   ELSE
    dir := FindFile(fs, path);
    IF (dir = NIL) THEN
     CreateDirectory(fs, path, res);
     IF (res = 0) THEN dir := FindFile(fs, path) END;
     IF (dir = NIL) THEN RETURN NIL END
    END;
    dircluster := dir.direntry.cluster
   END;
   IF ~ValidName(filename) THEN
    IF Detail THEN WriteErrorMsg("New", EInvalidFilename) END;
    RETURN NIL
   END;
   NEW(f); f.fs := fs; f.key := 0;
   f.direntry.long := filename; f.direntry.namechanged := TRUE;
   f.direntry.attr := {}; f.direntry.NTRes := 0X; f.direntry.size := 0;
   f.direntry.cluster := OFSFATVolumes.NONE;
   Kernel.GetClock(t, d); f.direntry.creationDate := d; f.direntry.creationTime := t;
   f.direntry.accessDate := d; f.direntry.dirInfo.dirCluster := dircluster; f.direntry.dirInfo.cluster := -1;
   f.direntry.modified := TRUE; f.registered := FALSE;
   AddAnonymousFile(f);
   Kernel.RegisterObject(f, FileCleanup, FALSE)
  ELSE f := NIL; IF Detail THEN WriteErrorMsg("New", EInvalidFilename) END
  END;
  RETURN f
 END
END New;

(** Old - opens an existing file. *)
PROCEDURE Old(fs: OFS.FileSystem; name: ARRAY OF CHAR): OFS.File;
VAR f: File; t,d: LONGINT;
BEGIN
 IF Trace THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("Old ('"); Kernel.WriteString(name); 
  Kernel.WriteString("')"); Kernel.WriteLn; 
 END;
 WITH fs: FileSystem DO  
  f := FindFile(fs, name);
  IF (f # NIL) THEN
   IF Detail THEN Kernel.WriteString("  filekey = "); Kernel.WriteInt(f.key, 0); Kernel.WriteLn END;
   f.registered := TRUE;
   IF (faDirectory IN f.direntry.attr) THEN
    f.direntry.size := OFSFATVolumes.GetDirectorySize(fs.vol(OFSFATVolumes.Volume), f.direntry.cluster);
    INCL(f.direntry.attr, faReadOnly)
   ELSIF (f.direntry.cluster = 0) THEN 
    f.direntry.cluster := OFSFATVolumes.NONE;
    AddOpenFile(f)
   END;
   (* adjust access time only if volume is not write-protected *)
   IF ~(OFS.ReadOnly IN fs.vol.flags) & (f.direntry.attr * FileProtection = {}) THEN
    Kernel.GetClock(t, d);
    f.direntry.accessDate := d;
    f.direntry.modified := TRUE;
   END;
   Kernel.RegisterObject(f, FileCleanup, FALSE)
  END;
  RETURN f
 END
END Old;

(** Delete -  deletes a file. res = 0 indicates success. *)
PROCEDURE DeleteHandler(p: OFSFATVolumes.Param; VAR continue: BOOLEAN);
BEGIN
 WITH p: CountParam DO
  INC(p.count);
  continue := (p.count <= 2)
 END
END DeleteHandler;

PROCEDURE DeleteFile(f: File; VAR res: INTEGER);
VAR cp: CountParam; del: OFS.File; msg: ARRAY 64 OF CHAR;
BEGIN
 IF Detail THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("DeleteFile: "); 
  Kernel.WriteString(f.direntry.long); Kernel.WriteChar(" ")
 END;
 res := Ok;
 IF (faDirectory IN f.direntry.attr) THEN
  IF (f.direntry.cluster # 0) THEN
   NEW(cp); cp.count := 0;
   OFSFATVolumes.EnumerateDirectory(f.fs.vol(OFSFATVolumes.Volume), f.direntry.cluster, DeleteHandler, cp);
   IF (cp.count > 2) THEN res := EDirectoryNotEmpty END
  ELSE res := ECannotDeleteRootDirectory
  END 
 END;
 IF (res = Ok) & (f.direntry.attr * FileProtection = {}) THEN
  del := OFS.FindOpenFile(f.fs, f.key);
  IF (del = NIL) THEN
   IF Detail THEN Kernel.WriteString("deleting ") END;
   OFSFATVolumes.DeleteClusterChain(f.fs.vol(OFSFATVolumes.Volume), f.direntry.cluster);
   OFSFATVolumes.RemoveDirectoryEntry(f.fs.vol(OFSFATVolumes.Volume), f.direntry, res);
  ELSIF ~(faDirectory IN del(File).direntry.attr) THEN
   WITH del: File DO
    IF Detail THEN Kernel.WriteString("unregistering ") END;
    OFSFATVolumes.RemoveDirectoryEntry(del.fs(FileSystem).vol(OFSFATVolumes.Volume), del.direntry, res);
    del.registered := FALSE;
    RemoveOpenFile(del);
    AddAnonymousFile(del)
   END
  ELSE res := ECannotDeleteDirectory
  END;
 ELSE res := EFileProtected
 END;
 IF Detail THEN FormatErrorMsg(res, msg); Kernel.WriteString(msg); Kernel.WriteLn END
END DeleteFile;

PROCEDURE Delete(fs: OFS.FileSystem; name: ARRAY OF CHAR; VAR key: LONGINT; VAR res: INTEGER);
VAR f: File;
BEGIN
 IF Trace THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("Deleting '");
  Kernel.WriteString(name); Kernel.WriteChar("'"); Kernel.WriteLn;
 END;
 key := 0; res := Ok;
 WITH fs: FileSystem DO
  f := FindFile(fs, name);
  IF (f # NIL) THEN 
   key := f.key; 
   DeleteFile(f, res); 
   IF (res # Ok) THEN key := 0 END
  ELSE res := EFileNotFound
  END
 END
END Delete;

(** Rename - renames a file. res = 0 indicates success. 
 An existing file with the same name as the new name will be overwritten. *)
PROCEDURE Rename(fs: OFS.FileSystem; old, new: ARRAY OF CHAR; VAR res: INTEGER);
VAR f, newf: File; i, t, d: LONGINT; rep: OFS.File; oldpath, newpath, fn: Filename;
BEGIN
 IF Trace THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("Rename '"); Kernel.WriteString(old); 
  Kernel.WriteString("' => '"); Kernel.WriteString(new); Kernel.WriteChar("'"); Kernel.WriteLn
 END;
 WITH fs: FileSystem DO
  IF ~(Split(old, oldpath, fn) & Split(new, newpath, fn) & (oldpath = newpath) & ValidName(fn)) THEN
   res := EInvalidFilename; 
   IF Detail THEN WriteErrorMsg("Rename", res) END;
   RETURN 
  END;
  f := FindFile(fs, old);
  IF (f # NIL) THEN
   IF (f.direntry.attr * FileProtection = {}) THEN
    newf := FindFile(fs, new);
    IF (newf # NIL) THEN 
     DeleteFile(newf, res);
     IF (res # Ok) THEN RETURN END
    END;
    WITH f: File DO
     i := 0;
     WHILE (i < OFSFATVolumes.MaxUTFNameLen) & (i < LEN(new)) & (new[i] # 0X) DO
      f.direntry.long[i] := new[i];
      INC(i)
     END;
     f.direntry.long[i] := 0X;
     f.direntry.namechanged := TRUE;
     Kernel.GetClock(t, d);
     f.direntry.accessDate := d;
     f.direntry.modified := TRUE;
     OFSFATVolumes.WriteDirectoryEntry(fs.vol(OFSFATVolumes.Volume), f.direntry, res)
    END
   ELSE res := EFileProtected;
    IF Detail THEN WriteErrorMsg("Rename", res) END
   END
  ELSE res := EFileNotFound;
   IF Detail THEN WriteErrorMsg("Rename", res) END
  END
 END
END Rename;

(** Enumerate - enumerates the contents of a directory *)
PROCEDURE Split(VAR name, directory, file: ARRAY OF CHAR): BOOLEAN;
VAR l, np, dp, fp, i: LONGINT;
 wild: BOOLEAN;
BEGIN
 l := 0; WHILE (l < LEN(name)) & (name[l] # 0X) DO INC(l) END;
 np := 0; dp := 0; fp := 0;
 WHILE (np < l) DO
  file[fp] := name[np]; INC(fp);
  CASE name[np] OF
  | "*", "?" : wild := TRUE
  | "/", "\" : IF wild THEN RETURN FALSE END;
       FOR i := 0 TO fp-1 DO directory[dp+i] := file[i] END;
       INC(dp, fp);
       fp := 0
  ELSE (* nothing *)
  END;
  INC(np)
 END;
 file[fp] := 0X; directory[dp] := 0X;
 RETURN TRUE
END Split;

PROCEDURE Match(VAR mask, name: ARRAY OF CHAR): BOOLEAN;
VAR m,n, om, on: LONGINT;
 f: BOOLEAN;
BEGIN
 m := 0; n := 0; om := -1;
 f := TRUE;
 LOOP
  IF (mask[m] = "*") THEN
   om := m; INC(m);
   WHILE (name[n] # 0X) & (name[n] # mask[m]) DO INC(n) END;
   on := n
  ELSIF (mask[m] = "?") THEN
   INC(m); INC(n)
  ELSE
   IF (mask[m] # name[n]) THEN
    IF (om = -1) THEN f := FALSE; EXIT
    ELSE (* try the next position *)
     m := om; n := on + 1;
     IF (name[n] = 0X) THEN f := FALSE; EXIT END
    END
   ELSE INC(m); INC(n)
   END
  END;
  IF (mask[m] = 0X) & ((name[n] = 0X) OR (om=-1)) THEN EXIT END
 END;
 RETURN f & (name[n] = 0X)
END Match;
 
PROCEDURE EnumHandler(p: OFSFATVolumes.Param; VAR continue: BOOLEAN);
VAR name: OFS.FileName; de, c, prev: DirList;
BEGIN
 WITH p: DirParam DO
  IF showHiddenFiles OR ~(faHidden IN p.direntry.attr) THEN
   COPY(p.direntry.long, name);
   IF (faDirectory IN p.direntry.attr) THEN 
    Unicode.Append(name, "/");
    IF (OFS.EnumRecursive IN p.flags) & (p.direntry.long # ".") & (p.direntry.long # "..") THEN
     NEW(de);  de.cluster := p.direntry.cluster; 
     prev := NIL; c := p.dirlist;
     WHILE (c # NIL) DO prev := c; c := c.next END;
     IF (prev = NIL) THEN p.dirlist := de
     ELSE prev.next := de
     END
    END
   END;
   IF Match(p.mask, name) THEN
    IF (p.direntry.dirInfo.dirCluster # p.fs.currentDirCluster) THEN Unicode.Prepend(name, p.dirlist.name) END;
    IF ~p.default THEN OFS.JoinName(p.fs.prefix, name, name) END;
    p.handler(name, p.direntry.creationTime, p.direntry.creationDate, p.direntry.size, p.flags);
    continue := ~(OFS.EnumStop IN p.flags);
   END
  ELSE continue := TRUE
  END
 END
END EnumHandler;

PROCEDURE Enumerate(fs: OFS.FileSystem; mask: ARRAY OF CHAR; VAR flags: SET; handler: OFS.EntryHandler);
VAR dp: DirParam; directory, filename: Filename; dir: OFS.File; cluster: LONGINT;
BEGIN
 NEW(dp);
 dp.fs := fs(FileSystem);
 dp.default := (OFS.First() = fs);
 dp.flags := flags;
 dp.handler := handler;
 IF Split(mask, directory, filename) THEN
  NEW(dp.dirlist); 
  IF (directory # "") THEN
   dir := FindFile(fs, directory);
   IF (dir # NIL) THEN cluster := dir(File).direntry.cluster; dp.dirlist.name := directory
   ELSE RETURN (* directory not found *)
   END
  ELSE cluster := fs(FileSystem).currentDirCluster
  END;
  IF (filename[0] # 0X) THEN dp.mask := filename
  ELSE dp.mask[0] := "*"; dp.mask[1] := 0X
  END;
  dp.dirlist.cluster := cluster; 
  WHILE (dp.dirlist # NIL) DO
   IF (OFS.EnumRecursive IN flags) THEN
    OFSFATVolumes.GetDirectoryName(dp.fs.vol(OFSFATVolumes.Volume), dp.dirlist.cluster, dp.dirlist.name)
   END;
   OFSFATVolumes.EnumerateDirectory(fs.vol(OFSFATVolumes.Volume), dp.dirlist.cluster, EnumHandler, dp);
   dp.dirlist := dp.dirlist.next
  END
 ELSE 
  Kernel.WriteString(moduleName); Kernel.WriteString("Invalid mask: "); Kernel.WriteString(mask); 
  Kernel.WriteLn
 END
END Enumerate;

(* FindFile - finds a file *)
PROCEDURE Upper(s: ARRAY OF CHAR): Filename;
VAR res: Filename;
 p, l: LONGINT;
 dummy: BOOLEAN;
BEGIN
 p := 0; l := LEN(s);
 IF (l > LEN(res)-1) THEN l := LEN(res)-1 END;
 WHILE (p < l) & (s[p] # 0X) DO
  res[p] := Unicode.UpperCh(s[p], dummy);
  INC(p);
 END;
 res[p] := 0X;
 RETURN res
END Upper;

PROCEDURE ToUpper(VAR s: ARRAY OF CHAR);
VAR p, l: LONGINT; dummy: BOOLEAN;
BEGIN
 p := 0; l := LEN(s);
 WHILE (p < l) & (s[p] # 0X) DO
  s[p] := Unicode.UpperCh(s[p], dummy);
  INC(p);
 END
END ToUpper;

PROCEDURE FindFileHandler(p: OFSFATVolumes.Param; VAR continue: BOOLEAN);
VAR cmpName, cmpLong: Filename; (* compiler traps if the use of 'cmpXXX' is replaced by its definition *)
BEGIN
 WITH p: FindParam DO
   cmpName := Upper(p.name);
   IF p.casesensitive THEN cmpLong := p.direntry.long
   ELSE cmpLong := Upper(p.direntry.long) 
  END;
  IF ((p.casesensitive & (p.name = cmpLong)) OR (~p.casesensitive & (cmpName = cmpLong)) OR (cmpName = p.direntry.short)) &
   (p.flags * p.direntry.attr = p.flags)
  THEN
   NEW(p.file);
   p.file.direntry := p.direntry;
   p.matched := TRUE;
   continue := FALSE
  END
 END
END FindFileHandler;

PROCEDURE NextPart(VAR n: ARRAY OF CHAR; VAR flags: SET): Filename;
VAR res: Filename;
 p, k: LONGINT;
BEGIN
 p := 0;
 IF (n[p] = "/") OR (n[p] = "\") THEN
  res[p] := n[p]
 ELSE
  WHILE (p < LEN(n)) & (n[p] # 0X) & (n[p] # "/") & (n[p] # "\") DO 
   res[p] := n[p]; INC(p) 
  END
 END;
 
 flags := {};
 IF (p < LEN(n)-1) THEN
  IF ((n[p] = "/") OR (n[p] = "\") OR (res = "/") OR (res = "\")) THEN
   res[p+1] := 0X; INC(p);
   flags := { OFSFATVolumes.faDirectory } (* we are looking for a directory *)
  END;
  
  k := 0;
  WHILE (p < LEN(n)) DO
   n[k] := n[p];
   IF (n[k] = 0X) THEN p := LEN(n) END;
   INC(k); INC(p)
  END    
 ELSIF (p = LEN(n)) THEN 
  res[p-1] := 0X; (* force 0X at the end of the string *)
  n[0] := 0X
 END;
 RETURN res
END NextPart;

PROCEDURE FindFile(fs: OFS.FileSystem; name: ARRAY OF CHAR): File;
VAR fp: FindParam; f: File; path, filename: Filename;
BEGIN
 f := NIL;
 WITH fs: FileSystem DO
  IF ~fs.lnCaseSensitive THEN ToUpper(name) END;
  IF Split(name, path, filename) THEN
   NEW(fp);
   fp.casesensitive := fs(FileSystem).lnCaseSensitive;
   NEW(fp.file);
   
   (* find directory *)
   fp.matched := TRUE;
   IF (path # "") THEN
    fp.name := NextPart(path, fp.flags);
    IF (fp.name = "/") OR (fp.name = "\") THEN 
     fp.file.direntry.cluster := 0; 
     fp.name := NextPart(path, fp.flags)
    ELSE fp.file.direntry.cluster := fs(FileSystem).currentDirCluster
    END;
    fp.file.direntry.attr := { faDirectory };
    WHILE (fp.name # "") DO
     fp.matched := FALSE;
     OFSFATVolumes.EnumerateDirectory(fs.vol(OFSFATVolumes.Volume), fp.file.direntry.cluster, FindFileHandler, fp);
     IF fp.matched THEN fp.name := NextPart(path, fp.flags)
     ELSE fp.name := "" (* no need to look any further *)
     END
    END
   ELSE fp.file.direntry.cluster := fs(FileSystem).currentDirCluster
   END;
   
   (* find file *)
   IF fp.matched & (filename # "") THEN
    (* check if the file is in the 'fopen'-list *)
    f := GetOpenFile(fs, filename, fp.file.direntry.cluster, ~fs.lnCaseSensitive);
    IF (f # NIL) THEN 
     RETURN f 
    END;
     
    (* file is not in 'froot'-list, search in directory *)
    fp.name := filename;
    fp.matched := FALSE;
    OFSFATVolumes.EnumerateDirectory(fs.vol(OFSFATVolumes.Volume), fp.file.direntry.cluster, FindFileHandler, fp);
   END;
   
   IF fp.matched & (fp.name[0] # ".") THEN (* the "." and ".." entries cannot be opened *)
    f := fp.file;
    f.fs := fs;
    IF (f.direntry.cluster >= 2) & (f.direntry.cluster <= fs.vol(OFSFATVolumes.Volume).bpb.CountOfClusters+1) OR
     ((faDirectory IN f.direntry.attr) & (f.direntry.cluster = 0))
    THEN (* valid cluster *)
     IF (faDirectory IN fp.file.direntry.attr) &
      (fp.file.direntry.cluster = 0) OR ((fp.file.direntry.long = "..") & (fp.file.direntry.cluster = 0)) 
     THEN
      (* it's the root directory or a ".." entry pointing to the root  *)
      f.key := -1
     ELSE
      f.key := fp.file.direntry.cluster
     END
    ELSIF (fp.file.direntry.cluster = OFSFATVolumes.NONE) THEN
     (* file has no cluster assigned => use filekeyIdx as file key *)
     DEC(fs(FileSystem).filekeyIdx);
     f.key := fs(FileSystem).filekeyIdx     
    ELSE
     (* invalid cluster *)
     INCL(fs.vol(OFSFATVolumes.Volume).flags, Disks.ReadOnly);
     Kernel.WriteString(moduleName); Kernel.WriteString(f.direntry.long); Kernel.WriteString(" has an invalid first cluster: ");
     Kernel.WriteInt(f.direntry.cluster, 0); Kernel.WriteLn; 
     Kernel.WriteString("  The volume has been write-protected. Please run Scandisk under MS-DOS."); Kernel.WriteLn;
     f := NIL
    END
   ELSE f := NIL 
   END
  END;  
  RETURN f
 END
END FindFile;

(** Close - closes a file *)
PROCEDURE Close(f: OFS.File);
VAR res: INTEGER;
BEGIN
 WITH f: File DO
  IF Trace THEN
   Kernel.WriteString(moduleName); Kernel.WriteString("Close ('"); Kernel.WriteString(f.direntry.long); 
   Kernel.WriteString("); key = "); Kernel.WriteInt(f.key, 0); Kernel.WriteLn
  END;
  IF f.direntry.modified & f.registered THEN
   OFSFATVolumes.WriteDirectoryEntry(f.fs.vol(OFSFATVolumes.Volume), f.direntry, res);
   IF (res # Ok) THEN WriteErrorMsg("Close", res) END
  END
 END
END Close;

(** Register - registers a file in the file system. res = 0 indicates success. 
 An existing file with the same name will be overwritten. *)
PROCEDURE Register (f: OFS.File; VAR res: INTEGER);
VAR old: File; rep: OFS.File; fs: FileSystem; savedDir: LONGINT;
BEGIN
 WITH f: File DO
  fs := f.fs(FileSystem);
  IF Trace THEN
   Kernel.WriteString(moduleName); Kernel.WriteString("Register ('"); Kernel.WriteString(f.direntry.long); 
   Kernel.WriteString("); key = "); Kernel.WriteInt(f.key, 0); Kernel.WriteLn
  END;
  IF ~f.registered  & (f.direntry.long # "") THEN
   fs := f.fs(FileSystem);
   savedDir := fs.currentDirCluster;
   fs.currentDirCluster := f.direntry.dirInfo.dirCluster; (* we have to look in the same directory *) 
   old := FindFile(f.fs, f.direntry.long);
   fs.currentDirCluster := savedDir;
   IF (old # NIL) THEN
    DeleteFile(old, res);
    IF (res # Ok) THEN RETURN END
   END;
   OFSFATVolumes.WriteDirectoryEntry(fs.vol(OFSFATVolumes.Volume), f.direntry, res);
   IF (res # Ok) THEN RETURN END;
   f.registered := TRUE;
   IF (f.direntry.cluster = OFSFATVolumes.NONE) THEN
    DEC(f.fs(FileSystem).filekeyIdx);
    f.key := f.fs(FileSystem).filekeyIdx; 
    AddOpenFile(f)
   ELSE
    f.key := f.direntry.cluster
   END;
   RemoveAnonymousFile(f);
   res := Ok
  END
 END
END Register;

(** Length - returns the length of a file *)
PROCEDURE Length(f: OFS.File): LONGINT;
BEGIN
 RETURN f(File).direntry.size
END Length;

(** GetDate - returns the write-timestamp of a file *)
PROCEDURE GetDate(f: OFS.File; VAR t,d: LONGINT);
BEGIN
 t := f(File).direntry.writeTime; d := f(File).direntry.writeDate
END GetDate;

(** SetDate - sets the write-timestamp of a file *)
PROCEDURE SetDate(f: OFS.File; t,d: LONGINT);
BEGIN
 WITH f: File DO
  IF (f.direntry.attr * FileProtection = {}) THEN
   f.direntry.creationTime := t; f.direntry.creationDate := d;
   Kernel.GetClock(t, d);
   f.direntry.accessDate := d;
   f.direntry.modified := TRUE
  END
 END
END SetDate;

(* GetName - returns the name of a file *)
PROCEDURE GetName(f: OFS.File; VAR name: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
 WITH f: File DO
  i := 0;
  (* wp: f.direntry.long/short are 0X terminated *)
  IF (f.direntry.long # "") THEN
   WHILE (i < LEN(name)) & (f.direntry.long[i] # 0X) DO
    name[i] := f.direntry.long[i]; INC(i)
   END
  ELSE
   WHILE (i < LEN(name)) & (f.direntry.short[i] # 0X) DO
    name[i] := f.direntry.short[i]; INC(i)
   END
  END;
  name[i] := 0X
 END
END GetName;

(** Set - positions a rider on a file at a given position. Riders cannot be positioned past the end of a file *)
PROCEDURE Set(VAR r: OFS.Rider; f: OFS.File; pos: LONGINT);
VAR hint: Hint;
BEGIN
 WITH f: File DO
  r.fs := f.fs;
  r.file := f;
  IF (pos < 0) THEN pos := 0 END;
  IF (pos > f.direntry.size) THEN pos := f.direntry.size END;
  r.eof := pos = f.direntry.size;
  r.apos := pos;
  r.res := 0;
  IF (r.hint = NIL) OR ~(r.hint IS Hint) OR (pos = 0) THEN
   NEW(hint); 
   hint.cluster := f.direntry.cluster; hint.start := 0; hint.end := f.fs(FileSystem).BytesPerCluster-1;
   r.hint := hint
  END
 END;  
END Set;

(** Pos - returns the current position of a rider *)
PROCEDURE Pos(VAR r: OFS.Rider): LONGINT;
BEGIN
 RETURN r.apos;
END Pos;

(** Read - reads one byte from a file *)
PROCEDURE Read(VAR r: OFS.Rider; VAR x: SYSTEM.BYTE);
BEGIN
 ReadBytes(r, x, 1)
END Read;

(** Write - writes one byte into a file *)
PROCEDURE Write(VAR r: OFS.Rider; x: SYSTEM.BYTE);
BEGIN
 WriteBytes(r, x, 1)
END Write;

(* GetBlockAddress - returns the address of the block on the disk containing the current position of the rider *)
PROCEDURE GetBlockAddress(VAR r: Rider; CanAlloc: BOOLEAN): LONGINT;
VAR vol: OFSFATVolumes.Volume; f: File; h: Hint; newCluster: LONGINT;

 PROCEDURE IsValidCluster(c: LONGINT; AllowEOC: BOOLEAN): BOOLEAN;
 BEGIN RETURN (c >= 2) OR (AllowEOC & (c = OFSFATVolumes.EOC))
 END IsValidCluster;

BEGIN
 vol := r.fs.vol(OFSFATVolumes.Volume); f := r.file(File); h := r.hint(Hint);

 IF (f.direntry.cluster = OFSFATVolumes.NONE) & CanAlloc THEN (* new file, no cluster assigned *)
  f.direntry.cluster := OFSFATVolumes.AllocateCluster(vol, OFSFATVolumes.NONE);
  h.cluster := f.direntry.cluster
 END;
 
 IF (h.cluster = OFSFATVolumes.NONE) THEN h.cluster := f.direntry.cluster; h.start := 0 END;
 
 IF (r.apos < h.start) OR (h.start + vol.bpb.BytesPerCluster-1 < r.apos) THEN
  IF (r.apos < h.start) THEN h.cluster := f.direntry.cluster; h.start := 0 END;
  
  WHILE (h.start + vol.bpb.BytesPerCluster-1 < r.apos) & IsValidCluster(h.cluster, CanAlloc) DO
   newCluster := OFSFATVolumes.GetFATEntry(vol, h.cluster);
   IF (newCluster = OFSFATVolumes.EOC) & CanAlloc THEN
    h.cluster := OFSFATVolumes.AllocateCluster(vol, h.cluster)
   ELSE
    h.cluster := newCluster
   END;
   h.start := h.start + vol.bpb.BytesPerCluster
  END
 END;
  
 IF IsValidCluster(h.cluster, FALSE) & (h.start <= r.apos) & (r.apos < h.start + vol.bpb.BytesPerCluster) THEN RETURN h.cluster
 ELSE RETURN -1
 END
END GetBlockAddress;

(** ReadBytes - read n bytes from a file. r.res indicates the number of bytes that could not be read *)
PROCEDURE ReadBytes(VAR r: OFS.Rider; VAR x: ARRAY OF SYSTEM.BYTE; n: LONGINT);
VAR adr, src, dst, m: LONGINT;
 data: ARRAY r.fs.vol(OFSFATVolumes.Volume).bpb.BytesPerCluster OF CHAR;
BEGIN
 IF Detail THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("reading "); Kernel.WriteInt(n, 0); 
  Kernel.WriteString(" bytes from "); Kernel.WriteString(r.file(File).direntry.long); Kernel.WriteLn
 END;
 IF (n > LEN(x)) THEN r.res := -1; RETURN END;
 IF (n <= 0) THEN r.res := 0; RETURN END;
 
 r.res := n; 
 IF (r.apos + n > r.file(File).direntry.size) THEN n := r.file(File).direntry.size - r.apos END;
 dst := SYSTEM.ADR(x[0]);
 r.eof := r.apos >= r.file(File).direntry.size; (* maybe a writer changed the file size *)
 
 WHILE (n > 0) & ~r.eof DO
  adr := GetBlockAddress(r, FALSE);
  IF Detail THEN 
   Kernel.WriteString("  block: "); Kernel.WriteInt(adr, 0); Kernel.WriteString("; pos: ");
   Kernel.WriteInt(r.apos - r.hint(Hint).start, 0); Kernel.WriteLn
  END;
  IF (adr < 0) THEN RETURN END;
  r.fs.vol.GetBlock(r.fs.vol, adr, data);
  src := SYSTEM.ADR(data[r.apos - r.hint(Hint).start]);
  m := r.hint(Hint).start + r.fs(FileSystem).BytesPerCluster - r.apos;
  IF (m > n) THEN m := n END;
  ASSERT(dst-SYSTEM.ADR(x[0])+m <= LEN(x)); (* index check *)
  SYSTEM.MOVE(src, dst, m);
  DEC(n, m); INC(dst, m);  DEC(r.res, m);
  INC(r.apos, m); IF (r.apos >= r.file(File).direntry.size) THEN r.eof := TRUE END
 END
END ReadBytes;

(** WriteBytes - write n bytes into a file. r.res indicates the number of bytes that could not be written *)
PROCEDURE WriteBytes(VAR r: OFS.Rider; VAR x: ARRAY OF SYSTEM.BYTE; n: LONGINT);
VAR res, src, dst, adr, len: LONGINT;
 f: File;
 data: ARRAY r.fs.vol(OFSFATVolumes.Volume).bpb.BytesPerCluster OF CHAR;
BEGIN
 IF Detail THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("writing "); Kernel.WriteInt(n, 0); 
  Kernel.WriteString(" bytes to "); Kernel.WriteString(r.file(File).direntry.long); Kernel.WriteLn
 END;
 r.res := n; res := 0; f := r.file(File);
 IF (f.direntry.attr * FileProtection # {}) THEN RETURN END;
 src := SYSTEM.ADR(x[0]);
 
 WHILE (n > 0) & (res = 0) DO
  adr := GetBlockAddress(r, TRUE);
  IF Detail THEN 
   Kernel.WriteString("  block: "); Kernel.WriteInt(adr, 0); Kernel.WriteString("; pos: ");
   Kernel.WriteInt(r.apos - r.hint(Hint).start, 0); Kernel.WriteLn
  END;
  IF (adr = -1) THEN RETURN END;
  dst := SYSTEM.ADR(data[r.apos - r.hint(Hint).start]);
  len := r.hint(Hint).start+ r.fs(FileSystem).BytesPerCluster - r.apos;
  IF (len > n) THEN len := n END;
  IF (r.apos # r.hint(Hint).start) OR (n < r.fs(FileSystem).BytesPerCluster) THEN
   (* read block only if necessary *)
   r.fs.vol.GetBlock(r.fs.vol, adr, data)
  END;
  ASSERT(dst-SYSTEM.ADR(data[0])+len<=LEN(data)); (* index check *)
  SYSTEM.MOVE(src, dst, len);
  r.fs.vol.PutBlock(r.fs.vol, adr, data);
  DEC(n, len); INC(src, len); DEC(r.res, len);
  INC(r.apos, len); 
  IF (r.apos >= f.direntry.size) THEN
   r.eof := TRUE;
   f.direntry.size := r.apos;
   f.direntry.modified := TRUE
  END
 END
END WriteBytes;

(* Purge - purges a file. This method is called by the garbage collector. *) 
PROCEDURE Purge(fs: OFS.FileSystem; f: OFS.File);
VAR file: File;
BEGIN (* f is in OFS's open file list *)
 IF Trace THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("Purge: '"); Kernel.WriteString((f(File).direntry.long)); 
  Kernel.WriteString("', key = ");  Kernel.WriteInt(f.key, 0)
 END;
 WITH fs: FileSystem DO
  file := f(File);
  RemoveOpenFile(file);
  RemoveAnonymousFile(file);
  IF ~file.registered & (file.direntry.cluster # OFSFATVolumes.FREE) THEN
   IF Trace THEN Kernel.WriteString(": deleted"); Kernel.WriteLn END;
   OFSFATVolumes.DeleteClusterChain(fs.vol(OFSFATVolumes.Volume), file.direntry.cluster)
  ELSIF Trace THEN
   Kernel.WriteString(": ignored because: ");
   IF file.registered THEN Kernel.WriteString("- file is registered ") END;
   IF (file.direntry.cluster = OFSFATVolumes.FREE) THEN Kernel.WriteString("- file has no clusters ") END;
   Kernel.WriteLn
  END
 END
END Purge;

(** Registered - returns TRUE if the file is registered in the file system *)
PROCEDURE Registered(fs: OFS.FileSystem; f: OFS.File): BOOLEAN;
BEGIN
 RETURN f(File).registered
END Registered;

(** Auxiliary File Handling *)

(** GetFileDescriptor - returns the descriptor of a file *)
PROCEDURE GetFileDescriptor*(f: File): OFSFATVolumes.DirEntry;
BEGIN
 RETURN f.direntry;
END GetFileDescriptor;

(** GetFileAttr - returns the attributes of a file *)
PROCEDURE GetFileAttr*(f: File): SET;
BEGIN
 RETURN f.direntry.attr
END GetFileAttr;

(** SetFileAttr - set the attributes of a file *)
PROCEDURE SetFileAttr*(f: File; attr: SET);
BEGIN
 ASSERT(~(faVolumeID IN attr));
 f.direntry.attr := attr;
 f.direntry.modified := TRUE
END SetFileAttr;

(** ShowHiddenFiles - lists hidden files in a directory listing *)
PROCEDURE ShowHiddenFiles*;
BEGIN showHiddenFiles := TRUE
END ShowHiddenFiles;

(** HideHiddenFiles - does not list hidden files in a directory listing *)
PROCEDURE HideHiddenFiles*;
BEGIN showHiddenFiles := FALSE
END HideHiddenFiles;

(* ValidName - returns TRUE if a long filename is valid *)
PROCEDURE ValidName(fn: ARRAY OF CHAR): BOOLEAN;
VAR invalid: BOOLEAN;
 p, len: LONGINT;
 c: CHAR;
BEGIN
 invalid := FALSE;
 IF Unicode.UTF8toASCII(fn, fn, invalid) THEN
  p := 0; len := LEN(fn);
  WHILE (p < len) & (fn[p] # 0X) DO
   c := fn[p];
   (* invalid characters (in order of appearance): 0X, """, "*", "/", ":", "<", ">", "?", "\", "|" *)
   invalid := (c = 0X) OR (c = 22X) OR (c = 2AX) OR (c = 2FX) OR (c = 3AX) OR (c = 3CX) OR (c = 3EX) OR
    (c = 3FX) OR (c = 5CX) OR (c = 7CX);
   IF invalid THEN p := len END;
   INC(p)
  END
 END;
 RETURN ~invalid
END ValidName;

(* AddOpenFile - adds a file to the list of known open & registered files that have a negative key *)
PROCEDURE AddOpenFile(f: File);
VAR c: FileList;
BEGIN
 ASSERT(f.direntry.long # "");
 c := f.fs(FileSystem).fopen;
 WHILE (c # NIL) & (c.file # f) DO c := c.next END;
 IF (c = NIL) THEN
  NEW(c); c.file := f; c.next := f.fs(FileSystem).fopen;
  f.fs(FileSystem).fopen := c
 END
END AddOpenFile;

(* GetOpenFile - searches the open file-list for a file with the given name & directory *)
PROCEDURE GetOpenFile(fs: FileSystem; name: Filename; dircluster: Address; ignoreCase: BOOLEAN): File;
VAR c: FileList; file: File;hack : Filename;
BEGIN
 file := NIL;
 IF (fs.fopen # NIL) THEN
  c := fs.fopen;
  IF ignoreCase THEN 
   name := Upper(name);
   hack := Upper(c.file.direntry.long);
  ELSE hack := c.file.direntry.long
  END;
  
  WHILE (c # NIL) & ((hack # name) OR (c.file.direntry.dirInfo.dirCluster # dircluster)) DO
   c := c.next;
   IF (c # NIL) THEN 
    IF ignoreCase THEN hack := Upper(c.file.direntry.long)
    ELSE hack := c.file.direntry.long 
    END
   END
  END;
  IF (c # NIL) THEN file := c.file END
 END;
 RETURN file
END GetOpenFile; 
 
(* RemoveOpenFile - removes a file from the list of known open & registered files that have a negative key *)
PROCEDURE RemoveOpenFile(f: File);
VAR p, c: FileList;
BEGIN
 IF (f.direntry.cluster = OFSFATVolumes.NONE) THEN
  p := NIL; c := f.fs(FileSystem).fopen;
  WHILE (c # NIL) & (c.file # f) DO p := c; c := c.next END; 
  IF (p = NIL) THEN 
   IF (c = NIL) THEN f.fs(FileSystem).fopen := NIL
   ELSE f.fs(FileSystem).fopen := c.next
   END
  ELSE 
   IF (c = NIL) THEN p.next := NIL
   ELSE p.next := c.next
   END
  END
 END
END RemoveOpenFile;

(* AddAnonymousFile - adds a file to the file system's anonymous list *)
PROCEDURE AddAnonymousFile(file: File);
VAR c: FileList;
BEGIN
 NEW(c); c.file := file; c.next := file.fs(FileSystem).fanonymous;
 file.fs(FileSystem).fanonymous := c
END AddAnonymousFile;

(* RemoveAnonymousFile - removes a file  from the file system's anonymous list *)
PROCEDURE RemoveAnonymousFile(file: File);
VAR p,c: FileList;
BEGIN
 p := NIL; c := file.fs(FileSystem).fanonymous;
 WHILE (c # NIL) & (c.file # file) DO p := c; c := c.next END;
 IF (p = NIL) THEN 
  IF (c # NIL) THEN file.fs(FileSystem).fanonymous := c.next
  ELSE file.fs(FileSystem).fanonymous := NIL
  END
 ELSE 
  IF (c # NIL) THEN p.next := c.next
  ELSE p.next := NIL
  END
 END
END RemoveAnonymousFile;

(** HasAnonymousFiles - returns TRUE if there are open anonymous files on this file system *)
PROCEDURE HasAnonymousFiles*(fs: FileSystem): BOOLEAN;
BEGIN RETURN fs.fanonymous # NIL
END HasAnonymousFiles;

(* FileCleanup - called by the Garbage Collector when a file is collected *)
PROCEDURE FileCleanup(f: PTR);
BEGIN
 WITH f: File DO
  IF Detail THEN 
   Kernel.WriteString(moduleName); Kernel.WriteString("FileCleanup:"); Kernel.WriteString(f.direntry.long); 
   Kernel.WriteString(", key= "); Kernel.WriteInt(f.key, 0); 
   Kernel.WriteString(", cluster= "); Kernel.WriteInt(f.direntry.cluster, 0); 
   Kernel.WriteString(", "); IF ~f.registered THEN Kernel.WriteString("not ") END; Kernel.WriteString("registered");
   Kernel.WriteLn
  END;
  IF (f.fs # NIL) & (f.fs.vol # NIL) THEN
   IF f.registered THEN RemoveOpenFile(f)  
   ELSE 
    RemoveAnonymousFile(f);
    IF (f.direntry.cluster # OFSFATVolumes.NONE) THEN
     OFSFATVolumes.DeleteClusterChain(f.fs.vol(OFSFATVolumes.Volume), f.direntry.cluster)
    END    
   END 
  END
 END
END FileCleanup;

(** Directory handling *)

(** CreateDirectory - creates a new directory 'path'. res=0 indicates success *)
PROCEDURE CreateDirectory*(fs: FileSystem; path: ARRAY OF CHAR; VAR res: INTEGER);
VAR fp: FindParam; parentDir: Address;
BEGIN
 WITH fs: FileSystem DO
  NEW(fp);
  fp.casesensitive := fs(FileSystem).lnCaseSensitive;
  NEW(fp.file);
  
  (* find existing part of directory path *)
  fp.name := NextPart(path, fp.flags);
  fp.matched := TRUE;
  IF (fp.name = "/") OR (fp.name = "\") THEN 
   fp.file.direntry.cluster := 0; (*fs.vol(OFSFATVolumes.Volume).bpb.RootClus;*)
   fp.name := NextPart(path, fp.flags)
  ELSE fp.file.direntry.cluster := fs.currentDirCluster
  END;
  fp.matched := TRUE;
  parentDir := fp.file.direntry.cluster;
  WHILE fp.matched & (fp.name # "") DO
   fp.matched := FALSE;
   OFSFATVolumes.EnumerateDirectory(fs.vol(OFSFATVolumes.Volume), fp.file.direntry.cluster, FindFileHandler, fp);
   IF fp.matched THEN fp.name := NextPart(path, fp.flags); parentDir := fp.direntry.cluster
   END
  END;
  
  (* create directories *)
  IF ~fp.matched & (fp.name # "") THEN
   WHILE (fp.name # "") & ValidName(fp.name) DO
    (* create directory *)
    parentDir := OFSFATVolumes.CreateDirectory(fs.vol(OFSFATVolumes.Volume), parentDir, fp.name);
    IF (parentDir # OFSFATVolumes.BAD) THEN fp.name := NextPart(path, fp.flags)
    ELSE fp.name := ""
    END
   END
  END
 END;
 res := Ok 
END CreateDirectory;

(** ChangeDirectory - changes the current directory. res=0 indicates success *)
PROCEDURE ChangeDirectory*(fs: FileSystem; path: ARRAY OF CHAR; VAR res: INTEGER);
VAR f: File; i: INTEGER;
BEGIN
 res := EInvalidFilename;
 IF (path # "") THEN
  i := 0; WHILE (path[i] # 0X) DO INC(i) END;
  IF (i > 0) & (i+1 < LEN(path)) & (path[i-1] # "/") THEN path[i] := "/"; path[i+1] := 0X; INC(i) END;
  IF (path[i-1] = "/") THEN
   i := 0; WHILE (path[i] # 0X) DO INC(i) END;
   f := FindFile(fs, path);
   IF (f # NIL) THEN
    IF (faDirectory IN f.direntry.attr) THEN
     fs.currentDirCluster := f.direntry.cluster;
     res := Ok
    ELSE res := ENotADirectory
    END
   ELSE res := EDirectoryNotFound
   END
  END
 END
END ChangeDirectory;

(** CurrentDirectory - returns the name of the current directory *)
PROCEDURE CurrentDirectory*(fs: FileSystem; VAR path: Filename);
BEGIN
 OFSFATVolumes.GetDirectoryName(fs.vol(OFSFATVolumes.Volume), fs.currentDirCluster, path);
END CurrentDirectory;

(** DeleteDirectory - deletes a directory. res=0 indicates success *)
PROCEDURE DelDirHandler(p: OFSFATVolumes.Param; VAR continue: BOOLEAN);
BEGIN
 WITH p: DelDirParam DO
  IF (p.direntry.long # ".") & (p.direntry.long # "..") THEN
   IF p.recursive THEN
    IF (faDirectory IN p.direntry.attr) THEN RemoveDirectory(p.fs, p.direntry, p.recursive, p.res)
    ELSE
     IF ((p.direntry.cluster # 0) & (OFS.FindOpenFile(p.fs, p.direntry.cluster) # NIL)) OR 
      (GetOpenFile(p.fs, p.direntry.long, p.direntry.dirInfo.dirCluster, ~p.fs.lnCaseSensitive) # NIL)
     THEN
      (* the file is still open -> abort *)
      p.res := EOpenFiles
     ELSIF (p.direntry.attr * FileProtection # {}) THEN
      (* protected file -> abort *)
      p.res := EFileProtected
     ELSE
      IF (p.direntry.cluster # 0) THEN 
       OFSFATVolumes.DeleteClusterChain(p.fs.vol(OFSFATVolumes.Volume), p.direntry.cluster) 
      END;
      OFSFATVolumes.RemoveDirectoryEntry(p.fs.vol(OFSFATVolumes.Volume), p.direntry, p.res)
     END
    END;
    continue := (p.res = Ok)
   ELSE continue := FALSE; p.res := EDirectoryNotEmpty
   END     
  END
 END
END DelDirHandler;

PROCEDURE RemoveDirectory(fs: FileSystem; dirEntry: OFSFATVolumes.DirEntry; recursive: BOOLEAN; VAR res: INTEGER);
VAR dp: DelDirParam;
BEGIN
 NEW(dp);
 dp.fs := fs;
 dp.res := Ok;
 dp.recursive := recursive;
 OFSFATVolumes.EnumerateDirectory(fs.vol(OFSFATVolumes.Volume), dirEntry.cluster, DelDirHandler, dp);
 IF (dp.res = 0) THEN
  IF (OFS.FindOpenFile(fs, dirEntry.cluster) = NIL) THEN
   IF (fs.currentDirCluster = dirEntry.cluster) THEN (* fix current directory *)
    fs.currentDirCluster := dirEntry.dirInfo.dirCluster;
   END;
   OFSFATVolumes.DeleteClusterChain(fs.vol(OFSFATVolumes.Volume), dirEntry.cluster);
   OFSFATVolumes.RemoveDirectoryEntry(fs.vol(OFSFATVolumes.Volume), dirEntry, dp.res)
  ELSE dp.res := EOpenFiles
  END
 END;
 res := dp.res
END RemoveDirectory;

PROCEDURE DeleteDirectory*(fs: FileSystem; dirName: Filename; recursive: BOOLEAN; VAR res: INTEGER);
VAR dir: File;
BEGIN
 dir := FindFile(fs, dirName);
 IF (dir # NIL) THEN
  IF (faDirectory IN dir.direntry.attr) THEN
   RemoveDirectory(fs, dir.direntry, recursive, res)
  ELSE res := ENotADirectory
  END 
 ELSE res := EDirectoryNotFound
 END
END DeleteDirectory;

(** File system handling *)

(* Finalize - finalizes a FAT file system *)
PROCEDURE Finalize(fs: OFS.FileSystem);
VAR a: FileList;
BEGIN
 Kernel.WriteString(moduleName); Kernel.WriteString("Finalize"); Kernel.WriteLn;
 WITH fs: FileSystem DO
  (* purge all open anonymous files *)
  a := fs.fanonymous;
  WHILE (a # NIL) DO
   IF Trace THEN Kernel.WriteString(" anonymous file '"); Kernel.WriteString(a.file.direntry.long) END;
   ASSERT(~a.file.registered);
   IF (a.file.direntry.cluster # OFSFATVolumes.NONE) THEN
    IF Trace THEN Kernel.WriteString("' purged"); Kernel.WriteLn END;
    OFSFATVolumes.DeleteClusterChain(fs.vol(OFSFATVolumes.Volume), a.file.direntry.cluster)
   ELSIF Trace THEN Kernel.WriteString("' is empty"); Kernel.WriteLn
   END;
   a := a.next
  END; 
  fs.vol.Finalize(fs.vol);
  fs.vol := NIL
 END
END Finalize;

(* Handle - message handler *)
PROCEDURE Handle(fs: OFS.FileSystem; VAR msg: OFS.Message; VAR res: LONGINT);
BEGIN
 WITH fs: FileSystem DO
 END
END Handle;

(** Generate a new file system object.  OFS.NewVol has volume parameter, OFS.Par has mount prefix. *)
PROCEDURE NewFS* ;
VAR fs: FileSystem; ch: CHAR; prefix: OFS.Prefix; i: LONGINT;
BEGIN
 Kernel.SetLogMark; Kernel.WriteString("OFSFATFiles: ");
 IF (OFS.NewVol = NIL) THEN 
  Kernel.WriteString(moduleName); Kernel.WriteString("no volume"); Kernel.WriteLn; 
  RETURN 
 END;
 IF ~(OFS.NewVol IS OFSFATVolumes.Volume) THEN
  Kernel.WriteString(moduleName); Kernel.WriteString("wrong volume type (must be OFSFATVolumes.Volume)");
  Kernel.WriteLn; RETURN
 END;
 
 (* read prefix *)
 REPEAT OFS.ReadPar(ch) UNTIL (ch # " ");
 i := 0;
 REPEAT
  prefix[i] := ch; INC(i);
  OFS.ReadPar(ch)
 UNTIL (ch <= " ");
 prefix[i] := 0X;
 
 IF (OFS.This(prefix) # NIL) THEN 
  Kernel.WriteString(prefix); Kernel.WriteString(" already in use"); Kernel.WriteLn; 
  RETURN 
 END;

 NEW(fs);
 fs.vol := OFS.NewVol;
 
 fs.currentDirCluster := 0; (* root directory *)
 fs.lnCaseSensitive := FALSE;
 fs.filekeyIdx := -1; (* -1 is reserved for the root directory *)
 fs.BytesPerCluster := fs.vol(OFSFATVolumes.Volume).bpb.BytesPerCluster;
 
 fs.desc[0] := 0X;  OFS.AppendStr("GCFatFS", fs.desc);
 fs.FileKey := FileKey; fs.New := New; fs.Old := Old; fs.Delete := Delete; fs.Rename := Rename; fs.Enumerate := Enumerate;
 fs.Close := Close; fs.Register := Register;fs.Length := Length; fs.GetDate := GetDate; fs.SetDate := SetDate; fs.GetName := GetName;
 fs.Set := Set; fs.Pos := Pos; fs.Read := Read; fs.Write := Write; fs.ReadBytes := ReadBytes; fs.WriteBytes := WriteBytes;
 fs.Finalize := Finalize; fs.Handle := Handle; fs.Purge := Purge; fs.Registered := Registered;
 OFS.Add(fs, prefix);
 Kernel.WriteString(prefix); Kernel.WriteString(" added"); Kernel.WriteLn
END NewFS;

(** SetCaseSensitiveness - if TRUE the file system allows long names with different case. 
 WARNING: Windows is NOT case sensitive ! *)
PROCEDURE SetCaseSensitiveness*(fs: FileSystem; CaseSensitive: BOOLEAN);
BEGIN
 fs.lnCaseSensitive := CaseSensitive
END SetCaseSensitiveness;

(** IsCaseSensitive - returns TRUE if the file system is in case-sensitive mode, FALSE otherwise *)
PROCEDURE IsCaseSensitive*(fs: FileSystem): BOOLEAN;
BEGIN
 RETURN fs.lnCaseSensitive
END IsCaseSensitive;

(** QuickFormat - formats a FAT volume. res=0 indicates success *)
PROCEDURE QuickFormat*(fs: FileSystem; VAR res: INTEGER);
BEGIN
 IF ~OFS.HasOpenFiles(fs) & (fs.fopen = NIL) & (fs.fanonymous = NIL) THEN
  OFSFATVolumes.QuickFormat(fs.vol(OFSFATVolumes.Volume));
  fs.currentDirCluster := 0;
  res := Ok
 ELSE res := EOpenFiles
 END 
END QuickFormat;

(* WriteErrorMsg - writes an error to the kernel log *)
PROCEDURE WriteErrorMsg(proc: ARRAY OF CHAR; code: INTEGER);
VAR errMsg: ARRAY 64 OF CHAR;
BEGIN
 Kernel.WriteString(moduleName); Kernel.WriteString("Error in "); Kernel.WriteString(proc); Kernel.WriteString(": ");
 FormatErrorMsg(code, errMsg); Kernel.WriteString(errMsg); Kernel.WriteLn
END WriteErrorMsg;
  
(** FormatErrorMsg - returns a descriptive string to an error code *)
PROCEDURE FormatErrorMsg*(code: INTEGER; VAR msg: ARRAY OF CHAR);
VAR s: ARRAY 64 OF CHAR;
 k: INTEGER;
BEGIN
 CASE code OF
 | Ok: s := "ok"
 | Error: s := "general error"
 | EInvalidFilename: s := "invalid filename"
 | ERootDirectoryFull: s := "root directory full"
 | EFileNotFound: s := "file not found"
 | EFileProtected: s := "file is protected"
 | EOpenFiles: s := "open files"
 | ENotADirectory: s := "not a directory"
 | EDirectoryNotFound: s := "directory not found"
 | EDirectoryNotEmpty: s := "directory not empty"
 | ECannotDeleteRootDirectory: s := "root directory can't be deleted"
 | ECannotDeleteDirectory: s := "directory can't be deleted implicitly"
 ELSE s := "unknown error"
 END;
 k := 0; 
 WHILE (s[k] # 0X) & (k < LEN(msg)-1) DO msg[k] := s[k]; INC(k) END;
 msg[k] := 0X
END FormatErrorMsg;

(* FATCleanup - called when the module is unloaded. Unmounts all FAT volumes *)
PROCEDURE FATCleanup;
VAR fs, next: OFS.FileSystem;
BEGIN
 IF Kernel.shutdown = 0 THEN
  fs := OFS.First();
  WHILE (fs # NIL) DO
   next := OFS.Next(fs);
   IF (fs IS FileSystem) THEN OFS.Remove(fs) END;
   fs := next
  END
 END
END FATCleanup;

BEGIN Kernel.InstallTermHandler(FATCleanup)
END OFSFATFiles.
 

