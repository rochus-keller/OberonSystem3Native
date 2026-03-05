(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE FTPBackup; (** portable *) (** PRK   **)

(*
 08.05.01 prk Use zip instead of Arc

 06.01.98
  more flexible message handling
  ShowInc, shows which files will be backed up
 
 14.10.96
  Suppress inserted. Files with given suffixes are not backed up
*)

IMPORT
 Attributes, Strings, Dates, Texts, Oberon, Files, FileDir, NetTools, FTP := FTPDocs, Zip, NetSystem;

CONST
 IncFileName = "Incremental";
 StripPrefix = TRUE;

TYPE
 Name = ARRAY 32 OF CHAR;
 
VAR
 Server, ZipFileName: Name;
 ZipFile: Zip.Archive;
 User, Dir: Name;
 InLogFile, OutLogFile: Files.File;
 InLogR, OutLogR: Files.Rider;
 cname: Name;
 cdate, ctime: LONGINT;
 send: BOOLEAN;
 SupCnt: LONGINT;
 SupSuf: ARRAY 48 OF Name;
 msg: ARRAY 256 OF CHAR;
 w: Texts.Writer;
 
PROCEDURE Msg(str: ARRAY OF CHAR);
BEGIN
 Texts.WriteString(w, msg); Texts.WriteString(w, str); Texts.WriteLn(w);
 Texts.Append(Oberon.Log, w.buf)
END Msg;

PROCEDURE Error(str: ARRAY OF CHAR);
BEGIN
 Texts.WriteString(w, "Backup error: "); Texts.WriteString(w, str); Texts.WriteLn(w);
 Texts.Append(Oberon.Log, w.buf)
END Error;

(* ---------------------------------------------------------------------- *)
(* Log File Handling *)

PROCEDURE OpenLog;
 VAR res: INTEGER; new: ARRAY 32 OF CHAR;
BEGIN
 COPY (IncFileName, new); Strings.Append (new, ".Old");
 Files.Rename (IncFileName, new, res);
 InLogFile := Files.Old (new);
 IF InLogFile # NIL THEN Files.Set (InLogR, InLogFile, 0); END;
 OutLogFile := Files.New (IncFileName); Files.Set (OutLogR, OutLogFile, 0) 
END OpenLog;

PROCEDURE GetNextLog;
BEGIN
 IF (InLogFile # NIL) & ~InLogR.eof THEN
  Files.ReadString (InLogR, cname);
  Files.ReadLInt (InLogR, cdate);
  Files.ReadLInt (InLogR, ctime)
 ELSE
  cname := "zzzzzzzzzz"
 END
END GetNextLog;

PROCEDURE WriteLog (name: ARRAY OF CHAR; time, date: LONGINT);
BEGIN
 Files.WriteString (OutLogR, name);
 Files.WriteLInt (OutLogR, date);
 Files.WriteLInt (OutLogR, time)
END WriteLog;

PROCEDURE CloseLog;
BEGIN
 Files.Register (OutLogFile); Files.Close (OutLogFile);
 Files.Close (InLogFile)
END CloseLog;

(* ---------------------------------------------------------------------- *)

PROCEDURE SuppressFile (VAR suf: ARRAY OF CHAR): BOOLEAN;
 VAR i: LONGINT;
BEGIN
 i := 0;
 WHILE i < SupCnt DO
  IF SupSuf [i] = suf THEN RETURN TRUE END;
  INC (i)
 END;
 RETURN FALSE
END SuppressFile;

PROCEDURE CheckDate(VAR str: ARRAY OF CHAR):BOOLEAN;
 VAR tmp: Name; t, d: LONGINT;
BEGIN
 IF str = "always" THEN RETURN(TRUE) END;
 Oberon.GetClock(t, d);
 Strings.DayToStr(Dates.DayOfWeek(d), tmp, FALSE);
 str[0] := CAP(str[0]); (* Dates.DayToString generates a name with first char uppercase *)
 RETURN(tmp = str);
END CheckDate;

PROCEDURE GetFileName(VAR S: Attributes.Scanner; VAR str: Name);
 VAR int: Name;
BEGIN
 str := "";
 LOOP
  IF S.eot THEN EXIT
  ELSIF S.class = Attributes.Char THEN
   IF S.c = "~" THEN EXIT
   ELSE Strings.AppendCh(str, S.c)
   END
  ELSIF S.class = Attributes.Name THEN 
   Strings.Append(str, S.s)
  ELSIF S.class = Attributes.Int THEN
   Strings.IntToStr(S.i, int); Strings.Append(str, int)
  ELSE Error("file name parsing problem")
  END;
  IF S.nextCh = " " THEN Attributes.Scan(S); EXIT END;
  Attributes.Scan(S)
 END;
END GetFileName;

PROCEDURE AddFile(name: ARRAY OF CHAR; time, date, size: LONGINT; VAR continue: BOOLEAN);
 VAR f: Files.File; r: Files.Rider; i, j, res: LONGINT; suf: ARRAY 32 OF CHAR;
BEGIN
 IF StripPrefix THEN
  i := 0;  WHILE (name[i] # 0X) & (name[i] # ":") DO INC(i) END;
  IF name[i] = ":" THEN
   j := 0;  REPEAT INC(i); name[j] := name[i]; INC(j) UNTIL name[i] = 0X
  END
 END;
 continue := TRUE;
 Strings.GetSuffix (name, suf);
 IF SuppressFile(suf) THEN RETURN END;
 Msg(name);
 f := Files.Old(name); Files.Set(r, f, 0);
 Zip.AddEntry(ZipFile, name, r, Files.Length(f), Zip.DefaultCompression, Zip.DefaultStrategy, res);
 IF res # Zip.Ok THEN Error("error adding file") END
END AddFile;

PROCEDURE IncBackup(name: ARRAY OF CHAR; time, date, size: LONGINT; VAR continue: BOOLEAN);
 VAR f: Files.File; r: Files.Rider; res: LONGINT; suf: ARRAY 32 OF CHAR;
BEGIN
 continue := TRUE;
 Strings.GetSuffix (name, suf);
 IF (name = ZipFileName) OR SuppressFile(suf) OR (size = 0) THEN RETURN END;
 WriteLog (name, time, date);
 WHILE (name > cname) DO GetNextLog END;
 IF (name = cname) & (time = ctime) & (date = cdate) THEN RETURN END;
 Msg(name);
 f := Files.Old(name); Files.Set(r, f, 0);
 IF send THEN Zip.AddEntry(ZipFile, name, r, Files.Length(f), Zip.DefaultCompression, Zip.DefaultStrategy, res) END;
 IF res # Zip.Ok THEN Error("error adding file") END
END IncBackup;

PROCEDURE SendFile;
 VAR s: FTP.Session; Pass: Name;
BEGIN
 IF ~send THEN RETURN END;
 Msg("Opening connection to the backup server");
 NetSystem.GetPassword ("ftp", Server, User, Pass);
 FTP.Open(Server, User, Pass, FTP.DefConPort, Oberon.Log, s);
 IF (s = NIL) OR (s.res # NetTools.Done) THEN Error("cannot start FTP"); RETURN END;
 FTP.ChangeDir(s, Dir);
 FTP.PutFile(s, ZipFileName, ZipFileName);
 FTP.Close(s)
END SendFile;

PROCEDURE GetDate(VAR str: Name);
 VAR d: ARRAY 3 OF INTEGER; i: INTEGER; t, dd: LONGINT;
BEGIN
 str := "";
 Oberon.GetClock (t, dd);
 Dates.ToYMD(dd, d[2], d[1], d[0]);
 FOR i:= 0 TO 2 DO
  Strings.AppendCh(str, CHR(ORD("0") + (d[i] DIV 10) MOD 10)); Strings.AppendCh(str, CHR(ORD("0") + d[i] MOD 10))
 END;
 Strings.AppendCh(str, ".");
 Dates.ToHMS(t, d[0], d[1], d[2]);
 FOR i:= 0 TO 2 DO
  Strings.AppendCh(str, CHR(ORD("0") + (d[i] DIV 10) MOD 10)); Strings.AppendCh(str, CHR(ORD("0") + d[i] MOD 10))
 END;
END GetDate;

(** Backup.Do ("always"|"monday"...) Package [File] ~ 
 The backup file is called Package.Date.zip
*)

PROCEDURE Do*;
 VAR S: Attributes.Scanner; freq, date, Pattern: Name; ires: INTEGER; res: LONGINT;
BEGIN
 msg := "";
 
 Attributes.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Attributes.Scan(S);
(* get the frequence *)
 IF (S.class # Attributes.Name) & (S.class # Attributes.String) THEN
  Error("Frequence not found"); RETURN
 END;
 COPY(S.s, freq);
 Attributes.Scan(S);
 
(* Get the package name *)
 IF (S.class # Attributes.Name) & (S.class # Attributes.String) THEN
  Error("Package name not found"); RETURN
 END;
 COPY(S.s, ZipFileName); Strings.AppendCh(ZipFileName, ".");

(* Compose the file name *)
 GetDate(date);
 Strings.Append(ZipFileName, date); Strings.Append(ZipFileName, ".zip");
 Msg(ZipFileName);
 
(* Check frequence *)
 IF ~CheckDate(freq) THEN Msg("no backup today"); RETURN END; 

(* delete the local arc file *)
 Files.Delete(ZipFileName, ires);
 ZipFile := Zip.CreateArchive(ZipFileName, res);
 IF res # Zip.Ok THEN Error("cannot create archive"); RETURN END;
 
 Attributes.Scan(S);
(* compress the files *)
 COPY(ZipFileName, msg); Strings.Append(msg, ": ");
 GetFileName(S, Pattern);
 WHILE Pattern # "" DO
  FileDir.Enumerate(Pattern, FALSE, AddFile);
  GetFileName(S, Pattern)
 END;

(* send the file *)
 SendFile;
 
(* delete the local arc file *)
 IF send THEN Files.Delete(ZipFileName, ires) END
END Do;

(** FTPBackup.Incremental mask ~ *)

PROCEDURE Incremental*;
 VAR
  date: Name; ires: INTEGER; res: LONGINT;
  S: Attributes.Scanner;  mask: ARRAY 32 OF CHAR;
BEGIN
 Attributes.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Attributes.Scan(S);
 IF ~(S.class IN {Attributes.Name, Attributes.String}) THEN
  HALT(99)
 END;
 COPY(S.s, mask);
 
 msg := "";

(* Get the package name *)
 COPY(IncFileName, ZipFileName); Strings.AppendCh(ZipFileName, ".");

(* Compose the file name *)
 GetDate(date);
 Strings.Append(ZipFileName, date); Strings.Append(ZipFileName, ".zip");
 Msg(ZipFileName);

(* delete the local arc file *)
 Files.Delete(ZipFileName, ires);
 ZipFile := Zip.CreateArchive(ZipFileName, res);
 IF res # Zip.Ok THEN Error("cannot create archive"); RETURN END;
 
(* Find the files to be compressed *)
 COPY(ZipFileName, msg); Strings.Append(msg, ": ");
 OpenLog; GetNextLog;
 FileDir.Enumerate(mask, TRUE, IncBackup);
 CloseLog;
 
(* send the file *)
 SendFile;
 
(* delete the local arc file *)
 IF send THEN Files.Delete(ZipFileName, ires) END;
END Incremental;

PROCEDURE ShowInc*;  (** Show which files would be backed up by Inc*)
VAR oldsend: BOOLEAN;
BEGIN
 msg := "";

 oldsend := send;  send := FALSE;
 OpenLog; GetNextLog;
 FileDir.Enumerate("", TRUE, IncBackup);
 Files.Close (OutLogFile); Files.Close (InLogFile);  (*don't save the new log file!*)
 send := oldsend;
END ShowInc;

(** Backup.Suppress {Suffix} ~   Don't save the files with suffix *)
PROCEDURE Suppress*;
 VAR S: Attributes.Scanner;
BEGIN
 Attributes.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Attributes.Scan(S);
 Texts.WriteString(w, "Suppress backup of: ");
 SupCnt := 0;
(* get the suffixes *)
 WHILE S.class IN {Attributes.String, Attributes.Name} DO
  Texts.WriteString(w, S.s); Texts.WriteString(w, "  ");
  COPY (S.s, SupSuf [SupCnt]); INC (SupCnt); Attributes.Scan (S)
 END;
 Texts.WriteLn(w);
 Texts.Append(Oberon.Log, w.buf)
END Suppress;


(** Backup.SetServer user [server [directory] ] ~ *)
PROCEDURE SetServer*;
 VAR S: Attributes.Scanner; ip: NetSystem.IPAdr; Pass: Name;
BEGIN
 Attributes.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Attributes.Scan(S);
(* get the UserName *)
 IF (S.class # Attributes.Name) & (S.class # Attributes.String) THEN
  Error("UserName not found"); RETURN
 END;
 COPY(S.s, User);
 NetSystem.GetPassword ("ftp", Server, User, Pass);
 IF Pass = "" THEN
  Error("No password found for you!!"); RETURN
 END;
 Attributes.Scan(S);

(* get the server name *)
 IF (S.class = Attributes.Name) OR (S.class = Attributes.String) THEN
  COPY(S.s, Server); Attributes.Scan(S);
  NetSystem.GetIP(Server, ip);
  IF ip = NetSystem.anyIP THEN Error("Server doesn't exists"); RETURN END;
  (* get the Directory *)
   IF (S.class = Attributes.Name) OR (S.class = Attributes.String) THEN
    COPY(S.s, Dir);
   END;
 END;
 
 Texts.WriteString(w, "New backup configuration: "); Texts.WriteString(w, User);
 Texts.WriteString(w, "@"); Texts.WriteString(w, Server); Texts.WriteString(w, "/"); Texts.WriteString(w, Dir);
 Texts.WriteLn(w);
 Texts.Append(Oberon.Log, w.buf)
END SetServer;

PROCEDURE SendOn*;
BEGIN
 send := TRUE
END SendOn;

PROCEDURE SendOff*;
BEGIN
 send := FALSE
END SendOff;

BEGIN
 Server := "lillian"; Dir := "BACKUP"; send := TRUE;
 Texts.OpenWriter(w)
END FTPBackup.


FTPBackup.SetServer reali lillian "/tmp" ~

FTPBackup.SendOn
FTPBackup.SendOff
FTPBackup.Incremental

Hex.Open Incremental ~