(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OFSISO9660Files;

 IMPORT SYSTEM, OFS, Kernel;

 CONST
  debug = FALSE; nameDebug = FALSE;
  
  SS = 2048;
  MaxBufs = 4;
  
  Directory = 1;
 
  eFileDoesNotExist = 8903;
  eCannotOpenSubDir = 8916;
  eInvalidFirstCluster = 8917;
  eNameIsWild = 8927;
  eInvalidFileName = 8941;
  eInvalidVolume = 9000;
  
 TYPE
  Filename = ARRAY 256 OF CHAR;
  
  VolDesc = POINTER TO RECORD
   root, rootDirSize: LONGINT (* sector number of root directory and root directory size *)
  END;
  
  Buffer = POINTER TO BufferRecord;
  BufferRecord = RECORD (OFS.HintDesc)
   pos, lim: LONGINT;
   next: Buffer;
   data: POINTER TO ARRAY OF CHAR
  END ;

  File = POINTER TO RECORD (OFS.File)
   len,
   time, date,
   filecl: LONGINT; (* first cluster *)
   attr: SET ; (* ISO file attributes *)
   (* directory info *)
   name: Filename;
   dircl, (* start cluster of dir. that contains entry for file *)
   dirpos: LONGINT;  (* position in cluster of dir. in which entry lies *)
   nofbufs: INTEGER;
   firstbuf: Buffer;
  END;
  
  FileSystem = POINTER TO RECORD (OFS.FileSystem)
   pri, sup, cur: VolDesc;
   jolietLevel: LONGINT;
  END; (* our file system type *)
  
 VAR (* svr *)
  ExtractNameProc: PROCEDURE(VAR dir, name: ARRAY OF CHAR);
  
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
 
 (* help procedures *)
 
 (* Get712 - 8 bit, signed *)
 PROCEDURE Get712(VAR s: ARRAY OF CHAR; first: LONGINT; VAR d: LONGINT);
 BEGIN
  d := SYSTEM.VAL(SHORTINT, s[first])
 END Get712;
 
 (* Get723 - 16 bit, both byte orders *)
 PROCEDURE Get723(VAR s: ARRAY OF CHAR; first: LONGINT; VAR d: LONGINT);
 BEGIN
  d := LONG(ORD(s[first]));
  d := d + LONG(ORD(s[first+1]))*100H;
 END Get723;
 
 (* Get731: 32 bit, least significant byte first *)
 PROCEDURE Get731(VAR s: ARRAY OF CHAR; first: LONGINT; VAR d: LONGINT);
 BEGIN
  d := LONG(ORD(s[first]));
  d := d + LONG(ORD(s[first+1]))*100H;
  d := d + LONG(ORD(s[first+2]))*10000H;
  d := d + LONG(ORD(s[first+3]))*1000000H
 END Get731;
 
 (* Get732: 32 bit, most significant byte first *)
 PROCEDURE Get732(VAR s: ARRAY OF CHAR; first: LONGINT; VAR d: LONGINT);
 BEGIN
  d := LONG(ORD(s[first]))*1000000H;
  d := d + LONG(ORD(s[first+1]))*10000H;
  d := d + LONG(ORD(s[first+2]))*100H;
  d := d + LONG(ORD(s[first+3]))
 END Get732;
 
 (* Get733 - 32 bit, both byte orders *)
 PROCEDURE Get733(VAR s: ARRAY OF CHAR; first: LONGINT; VAR d: LONGINT);
 BEGIN
  d := LONG(ORD(s[first]));
  d := d + LONG(ORD(s[first+1]))*100H;
  d := d + LONG(ORD(s[first+2]))*10000H;
  d := d + LONG(ORD(s[first+3]))*1000000H
 END Get733;
 
 (* Cap - Capitalise a character *)
 PROCEDURE Cap(ch: CHAR): CHAR;
 BEGIN
  IF (ch >= "a") & (ch <= "z") THEN RETURN CAP(ch)
  ELSE RETURN ch
  END
 END Cap;

 (* Check - check filename.  Return correct name, or empty name if incorrect. *)
 PROCEDURE Check(s: ARRAY OF CHAR;  VAR name: Filename; VAR res: INTEGER);
 VAR i, j: LONGINT;  ch: CHAR;
 BEGIN
  IF nameDebug THEN LogString("Check: "); LogString(s) END;
  res := 0; i := 0;
  IF (s[0] = "/") OR (s[0] = "\") THEN j := 1 ELSE j := 0 END;  (* remove leading / or \ *)
  LOOP
   ch := s[j];
   IF ch = 0X THEN EXIT END;
   IF ch = "\" THEN ch := "/" END;
   IF (ch < " ") OR (ch >= 07FX) THEN res := eInvalidFileName; i := 0; EXIT END;
   IF (ch = "?") OR (ch = "*") THEN res := eNameIsWild END;
   name[i] := ch;
   INC(i); INC(j)
  END;
  name[i] := 0X;
  IF nameDebug THEN LogString(" => "); LogString(name); LogLn END;
 END Check;
 
 PROCEDURE GetVolumeDescriptors(fs: FileSystem; res: INTEGER);
 VAR b: ARRAY SS OF CHAR; i: LONGINT; vol: OFS.Volume;
 BEGIN
  vol := fs.vol;
  i := 16; fs.pri := NIL; fs.sup := NIL; fs.cur := NIL; fs.jolietLevel := 0;
  REPEAT
   vol.GetBlock(vol, i, b); (* read boot sector *)
   CASE b[0] OF
    1X: (* Primary volume descriptor *)
     ASSERT(fs.pri = NIL, 102); (* exactly one primary volume desc *)
     NEW(fs.pri);
     Get733(b, 158, fs.pri.root); (* location of root directory *)
     Get733(b, 166, fs.pri.rootDirSize) (* size of root directory in bytes *)
   | 2X: (* Supplementary volume descriptor  *)
     ASSERT(fs.sup = NIL, 103); (* 0 or 1 supplementary volume descriptor *)
     ASSERT((b[88] = 25X) & (b[89] = 2FX) & ((b[90] = 40X) OR (b[90] = 43X) OR (b[90] = 45X)), 104);
     IF b[90] = 40X THEN fs.jolietLevel := 1
     ELSIF b[90] = 43X THEN fs.jolietLevel := 2
     ELSIF b[90] = 45X THEN fs.jolietLevel := 3
     END;
     NEW(fs.sup);
     Get733(b, 158, fs.sup.root); (* location of root directory *)
     Get733(b, 166, fs.sup.rootDirSize) (* size of root directory in bytes *)
   ELSE ASSERT((b[0] = 0X) OR (b[0] = 2X) OR (b[0] = 0FFX), 100) (* boot or end *)
   END;
   INC(i)
  UNTIL (res # 0) OR (b[0] = 0FFX);
  IF res = 0 THEN
   IF fs.pri = NIL THEN res := eInvalidVolume
   ELSIF fs.sup # NIL THEN fs.cur := fs.sup; ExtractNameProc := ExtractLongName 
   ELSE fs.cur := fs.pri; ExtractNameProc := ExtractShortName
   END
  END;
 END GetVolumeDescriptors;
 
 (* GetDir - Get information from a directory entry *)
 PROCEDURE GetDir(VAR dir, fname: ARRAY OF CHAR; VAR time, date, cl, len: LONGINT; VAR attr: SET);
 VAR t: LONGINT;
 BEGIN
  ExtractName(dir, fname);
  t (*attr*) := ORD(dir[24]); attr := SYSTEM.VAL(SET, t);
  time := LONG(ORD(dir[20]))*64*64 + LONG(ORD(dir[21]))*64 + LONG(ORD(dir[22]));
  date := LONG(ORD(dir[17]))*32*16 + LONG(ORD(dir[18]))*16 + LONG(ORD(dir[19]));
  Get733(dir, 1, cl);
  Get733(dir, 9, len)
 END GetDir;
 
 PROCEDURE SplitName(str: ARRAY OF CHAR; VAR prefix, name: ARRAY OF CHAR);
 VAR i, j: LONGINT;
 BEGIN
  IF nameDebug THEN LogString("SplitName: "); LogString(str) END;
  i := -1; j := -1;
  REPEAT INC(i); INC(j); prefix[j] := str[i] UNTIL (str[i] = 0X) OR (str[i] = "/");
  IF str[i] = "/" THEN
   prefix[j] := 0X; j := -1;
   REPEAT INC(i); INC(j); name[j] := str[i] UNTIL name[j] = 0X
  ELSE name[0] := 0X
  END;
  IF nameDebug THEN LogString(" => "); LogString(prefix); LogString(", "); LogString(name); LogLn END
 END SplitName;

 (* SeparateName - separate str into a prefix and a name. *)
 PROCEDURE SeparateName(str: ARRAY OF CHAR; VAR prefix: ARRAY OF CHAR; VAR name: Filename);
 VAR i, j : LONGINT;
 BEGIN
 (* Pre: str is result of a Check operation; all "\"s have been changed to "/" *)
  i := 0;  j := -1;
  WHILE str[i] # 0X DO
   IF str[i] = "/" THEN j := i END;
   INC(i)
  END;
  IF j >= 0 THEN
   COPY(str, prefix); prefix[j] := 0X;
   i := -1;
   REPEAT INC(i); INC(j); name[i] := str[j] UNTIL name[i] = 0X
  ELSE COPY(str, name); prefix[0] := 0X
  END
 END SeparateName;
 
 PROCEDURE ExtractShortName(VAR dir, name: ARRAY OF CHAR);
 VAR i, j, len: LONGINT;
 BEGIN
  len := ORD(dir[31]);
  i := 0;  j := 32;
  WHILE (i < len) & (dir[j] # ";") DO name[i] := dir[j];  INC(i); INC(j) END;
  name[i] := 0X;
 END ExtractShortName;
 
 PROCEDURE ExtractLongName(VAR dir, name: ARRAY OF CHAR);
 VAR i, j, end: LONGINT;
 BEGIN
  end := 33+ORD(dir[31]);
  i := 0;  j := 33;
  WHILE (j < end) & (dir[j] # ";") DO name[i] := dir[j];  INC(i); INC(j, 2) END;
  name[i] := 0X;
 END ExtractLongName;
 
 PROCEDURE ExtractName(VAR dir, name: ARRAY OF CHAR);
 VAR len: LONGINT;
 BEGIN
  len := ORD(dir[31]);
  IF len = 1 THEN
   IF dir[33] = 0X THEN COPY(".", name)
   ELSIF dir[33] = 1X THEN COPY("..", name)
   END
  ELSE ExtractNameProc(dir, name)
  END
 END ExtractName;

(* Match - Compare two file names while respecting wildcards
 name is a dir entry
 pattern is a file name with or without wildcards
*)
 PROCEDURE Match(name, pattern: ARRAY OF CHAR): BOOLEAN;
 VAR npos, nlen, ppos, plen, pstar, poldstar: LONGINT; ok: BOOLEAN;
 
  PROCEDURE is(npos, nlen, ppos, plen: LONGINT; VAR nextpos: LONGINT): BOOLEAN;
  VAR found: BOOLEAN;
  BEGIN
   found := FALSE;
   IF (nlen - npos = plen - ppos) & (npos >= 0) THEN
    WHILE (npos < nlen) & ((pattern[ppos] = "?") OR (Cap(name[npos]) = Cap(pattern[ppos]))) DO
     INC(npos); INC(ppos)
    END;
    found := npos = nlen
   END;
   nextpos := npos;
   RETURN found
  END is;
  
  PROCEDURE contains(npos, nlen, ppos, plen: LONGINT; VAR nextpos: LONGINT): BOOLEAN;
  VAR found: BOOLEAN; patlen: LONGINT;
  BEGIN
   patlen := plen-ppos; found := FALSE;
   WHILE ~found & (npos + patlen < nlen) DO
    found := is(npos, npos+patlen, ppos, plen, nextpos);
    INC(npos)
   END;
   RETURN found
  END contains;
  
 BEGIN
  nlen := 0; WHILE name[nlen] # 0X DO INC(nlen) END;
  plen := 0; pstar := -1; poldstar := -1;
  WHILE pattern[plen] # 0X DO
   IF (pstar < 0) & (pattern[plen] = "*") THEN pstar := plen END;
   INC(plen)
  END;
  ok := TRUE;
  IF pstar < 0 THEN ok := is(0, nlen, 0, plen, npos) (* no * wildcard *)
  ELSE
   npos := 0; ppos := 0;
   IF pstar > 0 THEN ok := is(0, pstar, 0, pstar, npos) END;
(*   Log.Bool(ok); Log.Int(npos); Log.Int(nlen); Log.Int(ppos); Log.Int(plen); Log.Ln; *)
   WHILE ok & (pstar < plen) DO
    poldstar := pstar+1;
    REPEAT INC(pstar) UNTIL (pstar = plen) OR (pattern[pstar] = "*");
    IF pstar < plen THEN ok := ok & contains(npos, nlen, poldstar, pstar, npos) END;
(*    Log.Bool(ok); Log.Int(npos); Log.Int(nlen); Log.Int(ppos); Log.Int(plen); Log.Ln; *)
   END;
   IF ok & (pstar # poldstar) THEN ok := ok & is(nlen-(plen - poldstar), nlen, poldstar, plen, npos) END
  END;
  RETURN ok
 END Match;

 PROCEDURE MatchFile(VAR R: OFS.Rider; name: ARRAY OF CHAR; VAR fname: ARRAY OF CHAR;
  VAR pos, cl, time, date, len: LONGINT; VAR attr: SET; VAR res: INTEGER);
 VAR found: BOOLEAN; f: File; fs: FileSystem; buf: ARRAY 256 OF CHAR; entryLen: LONGINT;
 BEGIN
  f := R.file(File); fs := R.fs(FileSystem);
  found := FALSE;
  LOOP
   pos := fs.Pos(R);
   IF debug THEN LogString("MatchFile; pos: "); LogInt(pos); LogLn END;
   fs.Read(R, buf[0]); entryLen := ORD(buf[0]);
   IF debug & R.eof THEN LogString("MatchFile; eof"); LogLn END;
   IF debug THEN LogString("MatchFile; entryLen: "); LogInt(entryLen); LogLn END;
   IF R.eof OR (entryLen = 0) THEN EXIT END;
   fs.ReadBytes(R, buf, entryLen-1);
   GetDir(buf, fname, time, date, cl, len, attr);
   found := Match(fname, name);
   IF found THEN EXIT END;
  END;
  IF found THEN res := 0 ELSE res := eInvalidFileName END;
 END MatchFile;
 
 PROCEDURE FindFile(fs: FileSystem; name: ARRAY OF CHAR; dircl, dirlen: LONGINT;
  VAR dirpos, time, date, filecl, len: LONGINT; VAR attr: SET; VAR res: INTEGER);
 VAR f: File; R: OFS.Rider; fname: Filename;
 BEGIN
  ASSERT(name # "", 100);
  f := OpenFile("", fs, -1, -1, -1, -1, dircl, dirlen, {});
  fs.Set(R, f, 0);
  MatchFile(R, name, fname, dirpos, filecl, time, date, len, attr, res);
  fs.Close(f)
 END FindFile;
 
 PROCEDURE LocateFile(name: ARRAY OF CHAR; fs: FileSystem;
  VAR dircl, dirpos, time, date, filecl, len: LONGINT; VAR attr: SET; VAR res: INTEGER);
 VAR cur: Filename; dirlen: LONGINT;
 BEGIN
  res := 0;
  dircl := fs.cur.root; dirlen := fs.cur.rootDirSize; (* start in root directory *)
  IF name[0] = 0X THEN (* root dir *)
   filecl := dircl; attr := {Directory};
   len := dirlen; dirpos := -1;
  ELSE
   LOOP
    SplitName(name, cur, name);
    FindFile(fs, cur, dircl, dirlen, dirpos, time, date, filecl, len, attr, res);
(*     IF debug THEN LogString("LocateFile; res: "); LogInt(res); LogLn END; *)
    IF (res = 0) & (name # "") & ~(Directory IN attr) THEN res := eInvalidFileName END;
    IF (res # 0) OR (name = "") THEN EXIT END;
    dircl := filecl; dirlen := len
   END
  END
 END LocateFile;
 
 (* ReadBuf - Read data into a buffer *)
 PROCEDURE ReadBuf(f: File; buf: Buffer; pos: LONGINT);
 VAR vol: OFS.Volume;
 BEGIN
  ASSERT(pos <= f.len, 100);
  vol := f.fs.vol; buf.pos := pos - pos MOD vol.blockSize;
  pos := pos DIV vol.blockSize;
  IF pos = f.len DIV vol.blockSize THEN buf.lim := f.len MOD vol.blockSize
  ELSE buf.lim := vol.blockSize
  END;
  IF debug THEN LogString("ReadBuf; block: "); LogInt(f.filecl+pos); LogLn END;
  vol.GetBlock(vol, f.filecl+pos, buf.data^)
 END ReadBuf;
 
 (* Buf - Return a buffer containing the specified position, if already present *)
 PROCEDURE Buf(pos: LONGINT; hint: Buffer): Buffer;
 VAR buf: Buffer;
 BEGIN
  buf := hint;
  LOOP
   IF (pos >= buf.pos) & (pos < buf.pos+buf.lim) THEN EXIT END;
   buf := buf.next;
   IF buf = hint THEN buf := NIL;  EXIT END
  END;
  RETURN buf
 END Buf;

 (* GetBuf - Return a buffer containing the specified position, loading it if necessary. *)
 PROCEDURE GetBuf(f: File;  pos: LONGINT; hint: Buffer): Buffer;
 VAR buf: Buffer;
 BEGIN
  buf := Buf(pos, hint);
  IF buf = NIL THEN
   IF f.nofbufs < MaxBufs THEN (*allocate new buffer*)
    NEW(buf);  NEW(buf.data, f.fs.vol.blockSize);
    buf.next := f.firstbuf.next;  f.firstbuf.next := buf;
    INC(f.nofbufs)
   ELSE (*reuse one of the buffers; round robin *)
    buf := f.firstbuf; f.firstbuf := buf.next;
   END;
   ReadBuf(f, buf, pos);
  END;
  RETURN buf
 END GetBuf;

 (* GetDate - Returns the time (t) and date (d) of a file. *)
 PROCEDURE GetDate(f: OFS.File; VAR t, d: LONGINT);
 BEGIN
  WITH f: File DO
   t := f.time;  d := f.date
  END
 END GetDate;
 

 (** Set - Positions a Rider at a certain position in a file. Multiple Riders can be positioned at different locations 
 in a file. A Rider cannot be positioned beyond the end of a file. *)
 PROCEDURE Set(VAR r: OFS.Rider; f: OFS.File; pos: LONGINT);
 BEGIN
  WITH f: File DO
   r.eof := FALSE; r.res := 0; r.file := f; r.fs := f.fs;
   IF pos < 0 THEN r.apos := 0
   ELSIF pos < f.len THEN r.apos := pos
   ELSE r.apos := f.len
   END;
   r.hint := f.firstbuf
  END
 END Set;
 
 (** Pos - Returns the offset of a Rider positioned on a file. *)
 PROCEDURE Pos(VAR r: OFS.Rider): LONGINT;
 BEGIN
  RETURN r.apos
 END Pos;

 (** Close - flushes the changes made to a file to disk, and updates directory entry if registerevol. 
  Does NOT Register a new file automatically. *)
 PROCEDURE Close(f: OFS.File);
 BEGIN
 END Close;
 
 PROCEDURE OpenFile(name: ARRAY OF CHAR; fs: FileSystem; dircl, dirpos, time, date, filecl, len: LONGINT; attr: SET): File;
 VAR f: File; buf: Buffer;
 BEGIN
  NEW(f); COPY(name, f.name); f.fs := fs; f.key := filecl;
  f.dircl := dircl; f.dirpos := dirpos; f.time := time; f.date := date;
  f.filecl := filecl; f.len := len; f.attr := attr;
  NEW(buf); buf.next := buf; 
  NEW(buf.data, fs.vol.blockSize);
  IF f.len = 0 THEN buf.pos := 0; buf.lim := 0
  ELSE ReadBuf(f, buf, 0) (* file is not empty *)
  END;
  f.firstbuf := buf;  f.nofbufs := 1;
  RETURN f
 END OpenFile;
 
 (** Old - Open an existing file. The same file descriptor is returned if a file is opened multiple times. *)
 PROCEDURE Old(fs: OFS.FileSystem; name: ARRAY OF CHAR): OFS.File;
 VAR f: File; namebuf: Filename; dircl, dirpos, time, date, filecl, len: LONGINT; attr: SET; res: INTEGER;
 BEGIN
  res := 0; f := NIL;
  Check(name, namebuf, res);
  IF res = 0 THEN
   LocateFile(namebuf, fs(FileSystem), dircl, dirpos, time, date, filecl, len, attr, res);
   IF debug THEN LogString("Old; filecl: "); LogInt(filecl); LogLn END;
   IF res = 0 THEN
    IF Directory IN attr THEN res := eCannotOpenSubDir
    ELSIF filecl < 16 THEN res := eInvalidFirstCluster
    ELSE f := OpenFile(namebuf, fs(FileSystem), dircl, dirpos, time, date, filecl, len, attr)
    END
   END
  END;
  RETURN f
 END Old;
 
 PROCEDURE OldDir(fs: OFS.FileSystem; name: ARRAY OF CHAR): OFS.File;
 VAR f: File; dircl, dirpos, time, date, filecl, len: LONGINT; attr: SET; res: INTEGER;
 BEGIN
  res := 0; f := NIL;
  LocateFile(name, fs(FileSystem), dircl, dirpos, time, date, filecl, len, attr, res);
  IF res = 0 THEN
   IF ~(Directory IN attr) THEN res := eCannotOpenSubDir
   ELSIF filecl < 16 THEN res := eInvalidFirstCluster
   ELSE f := OpenFile(name, fs(FileSystem), dircl, dirpos, time, date, filecl, len, attr)
   END
  END;
  RETURN f
 END OldDir;

 (** Length - Returns the current length of a file. *)
 PROCEDURE Length(f: OFS.File): LONGINT;
 BEGIN
  WITH f: File DO
   RETURN f.len
  END
 END Length;

 (** Returns the full name of a file. *)
 PROCEDURE GetName(f: OFS.File;  VAR name: ARRAY OF CHAR);
 BEGIN
  WITH f: File DO
   COPY(f.name, name)
  END
 END GetName;

 (** Enumerate a directory.  path must be a full path specification with a 8.3-style wildcard. *)
 PROCEDURE Enumerate(fs: OFS.FileSystem; path: ARRAY OF CHAR; VAR flags: SET; handler: OFS.EntryHandler);
 VAR
  fname, name, mask, pname, fullname: Filename;
  f: OFS.File; R: OFS.Rider;
  attr: SET;
  pos, time, date, len, cl: LONGINT; res: INTEGER;
 BEGIN
 (* Log.Str(path); Log.Ln; *)
  Check(path, name, res);
 (* Log.Str(path); Log.Str(name); Log.Int(res); Log.Ln; *)
  IF (res = 0) OR (res = eNameIsWild) THEN
   SeparateName(name, name, mask);
   OFS.JoinName(fs.prefix, name, pname);
   IF nameDebug THEN LogString("Enumerate; dir name: "); LogString(pname); LogLn END;
   f := OldDir(fs, name);
   IF f # NIL THEN
    fs.Set(R, f, 0); pos := 0;
    LOOP
     MatchFile(R, mask, fname, pos, cl, time, date, len, attr, res);
     IF res # 0 THEN EXIT END;
     COPY(pname, fullname);
     IF name[0] # 0X THEN OFS.AppendStr("/", fullname) END;
     OFS.AppendStr(fname, fullname);
     IF Directory IN attr THEN OFS.AppendStr(" [DIR]", fullname) END;
     handler(fullname, time, date, len, flags);
     IF OFS.EnumStop IN flags THEN EXIT END
    END;
    fs.Close(f)
   ELSE res := eFileDoesNotExist
   END
  END
 END Enumerate;

 (** ReadBytes - Reads a sequence of length n bytes into the buffer x, advancing the Rider. Less bytes will 
  be read when reading over the length of the file. r.res indicates the number of unread bytes. *)
 PROCEDURE ReadBytes(VAR r: OFS.Rider; VAR x: ARRAY OF SYSTEM.BYTE; n: LONGINT);
 VAR src, dst, m, pos: LONGINT;  buf: Buffer; f: File;
 BEGIN
  IF LEN(x) < n THEN SYSTEM.HALT(19) END;
  IF n <= 0 THEN RETURN END;
  dst := SYSTEM.ADR(x[0]);
  buf := r.hint(Buffer); f := r.file(File);
  m := f.len - r.apos;
  IF n <= m THEN r.res := 0 ELSE r.eof := TRUE; r.res := n-m; n := m END;
  WHILE n > 0 DO
   buf := GetBuf(f, r.apos, buf);
   pos := r.apos - buf.pos;
   src := SYSTEM.ADR(buf.data[pos]);  m := buf.lim-pos;
   IF m > n THEN m := n END;
   SYSTEM.MOVE(src, dst, m);
   DEC(n, m); INC(dst, m); INC(r.apos, m);
  END;
  r.hint := buf
 END ReadBytes;

 PROCEDURE Read(VAR r: OFS.Rider; VAR x: SYSTEM.BYTE);
 BEGIN
  ReadBytes(r, x, 1)
 END Read;
 
 (* Return unique id for file, or 0 if it does not exist. *)
 PROCEDURE FileKey(fs: OFS.FileSystem; name: ARRAY OF CHAR): LONGINT;
 VAR res: INTEGER; namebuf: Filename; t, key, filecl: LONGINT; attr: SET;
 BEGIN
  IF nameDebug THEN LogString("OFSFATFiles.FileKey: "); LogString(name); LogLn END;
  key := 0;
  Check(name, namebuf, res);
  IF res = 0 THEN
   LocateFile(namebuf, fs(FileSystem), t, t, t, t, filecl, t, attr, res);
   IF res = 0 THEN key := filecl END
  END;
  RETURN key
 END FileKey;

 (* File system initialization and finalization *)
 PROCEDURE Finalize(fs: OFS.FileSystem);
 BEGIN
  WITH fs: FileSystem DO
   fs.vol.Finalize(fs.vol);
   fs.vol := NIL (* prevent access in case user still has file handles *)
  END
 END Finalize;
 
 PROCEDURE FetchString(VAR name: ARRAY OF CHAR; VAR ch: CHAR);
 VAR i: LONGINT;
 BEGIN
  WHILE ch = " " DO OFS.ReadPar(ch) END;
  i := 0;
  WHILE (ch # 0X) & (ch # " ") & (ch # ",") DO name[i] := ch;  INC(i);  OFS.ReadPar(ch) END;
  name[i] := 0X
 END FetchString;
 
 (** Generate a new file system object.  OFS.NewVol has volume parameter, OFS.Par has mount prefix. *)
 PROCEDURE NewFS*;
 VAR vol: OFS.Volume;  fs: FileSystem;  ch: CHAR;  prefix: OFS.Prefix; res: INTEGER;
 BEGIN
  vol := OFS.NewVol;
  OFS.ReadPar(ch); FetchString(prefix, ch);
  IF OFS.This(prefix) = NIL THEN
   IF vol # NIL THEN
    NEW(fs);  fs.vol := vol;
    GetVolumeDescriptors(fs, res);
    IF res = 0 THEN
     IF debug THEN
      LogString("  primary root: "); LogInt(fs.pri.root); LogLn;
      LogString("  primary root dir size: "); LogInt(fs.pri.rootDirSize); LogLn
     END;
     fs.desc[0] := 0X;  OFS.AppendStr(vol.name, fs.desc);  OFS.AppendStr(" / ISO9660FS", fs.desc);
     fs.FileKey := FileKey; fs.New := NIL; fs.Old := Old;
     fs.Delete := NIL;  fs.Rename := NIL;  fs.Enumerate := Enumerate;
     fs.Close := Close;  fs.Register := NIL;  fs.Length := Length;
     fs.GetDate := GetDate;  fs.SetDate := NIL;  fs.GetName := GetName;
     fs.Set := Set;  fs.Pos := Pos;
     fs.Read := Read;  fs.Write := NIL;
     fs.ReadBytes := ReadBytes; fs.WriteBytes := NIL;
     fs.Finalize := Finalize;
     OFS.Add(fs, prefix)
    ELSE LogString("OFSISO9660Files: FS not found on "); LogString(vol.name);  LogLn
    END
   ELSE LogString("OFSISO9660Files: no volume"); LogLn
   END
  ELSE
   LogString("OFSFATFiles: ");  LogString(prefix);
   LogString(" already in use");  LogLn
  END
 END NewFS;

(* Clean up when module freed. *)
PROCEDURE Cleanup;
VAR fs: OFS.FileSystem;
BEGIN
 IF Kernel.shutdown = 0 THEN
  REPEAT (* unmount all AosFSs *)
   fs := OFS.First(); (* look for fs to unmount *)
   WHILE (fs # NIL) & ~(fs IS FileSystem) DO
    fs := OFS.Next(fs)
   END;
   IF fs # NIL THEN OFS.Remove(fs) END
  UNTIL fs = NIL
 END
END Cleanup;

BEGIN
 Kernel.InstallTermHandler(Cleanup)
END OFSISO9660Files.

OFSTools.Mount CD0 "IDE1.0" OFSISO9660Volumes.New OFSISO9660Files.NewFS
OFSTools.Unmount CD0 ~

System.Free OFSISO9660Files  OFSISO9660Volumes ~

CD0:GRAPHICS/*

