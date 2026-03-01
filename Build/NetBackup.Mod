(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE NetBackup; (** portable *) (* muller 15.12.95 *)

IMPORT NetSystem, Texts, Oberon, FileDir, Files, Input;

CONST
 Port = 5007;
 CollectFreq = 10;
 StripPrefix = FALSE;

TYPE
 List = POINTER TO ListNode;
 ListNode = RECORD
  next: List;
  name1, name2: ARRAY 64 OF CHAR;
  time, date, size: LONGINT
 END;
 
VAR
 W: Texts.Writer;
 log, list, last: List;
 logtext: Texts.Text;
 
PROCEDURE WriteString(c: NetSystem.Connection;  s: ARRAY OF CHAR);
VAR res, i: LONGINT;
BEGIN
 i := 0;  WHILE s[i] # 0X DO INC(i) END;
 NetSystem.WriteBytes(c, 0, i+1, s);
 IF c.res # NetSystem.done THEN res := c.res;  HALT(99) END
END WriteString;

PROCEDURE OpenScanner(VAR S: Texts.Scanner);
VAR
 beg, end, time: LONGINT;
 text: Texts.Text;
BEGIN
 Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(S);
 IF (S.class = Texts.Char) & (S.c = "^") THEN
  time := -1;
  text := NIL;
  Oberon.GetSelection(text, beg, end, time);
  IF (text # NIL) & (time >= 0) THEN
   Texts.OpenScanner(S, text, beg);
   Texts.Scan(S)
  END
 END
END OpenScanner;

PROCEDURE ScanPair(VAR S: Texts.Scanner; VAR name1, name2: ARRAY OF CHAR): BOOLEAN;
BEGIN
 WHILE ~(S.class IN {Texts.Name, Texts.String}) & ((S.class # Texts.Char) OR (S.c # "~")) & ~S.eot DO
  Texts.Scan(S)
 END;
 IF S.class IN {Texts.Name, Texts.String} THEN
  COPY(S.s, name1);
  Texts.Scan(S);
  IF (S.class = Texts.Char) & (S.c = "=") THEN
   Texts.Scan(S);
   IF (S.class = Texts.Char) & (S.c = ">") THEN
    Texts.Scan(S);
    IF S.class IN {Texts.Name, Texts.String} THEN
     COPY(S.s, name2);
     Texts.Scan(S);
     RETURN TRUE
    END
   END
  ELSE
   COPY(name1, name2);
   RETURN TRUE
  END
 END;
 RETURN FALSE
END ScanPair;

PROCEDURE Send(server: ARRAY OF CHAR;  root: List): BOOLEAN;
CONST BufSize = 1024;
VAR
 res: INTEGER;  f: Files.File;  r: Files.Rider;  len, num, tres: LONGINT;
 c: NetSystem.Connection;  name1, name2: ARRAY 64 OF CHAR;  ip: NetSystem.IPAdr;
 buf: ARRAY BufSize OF CHAR;  tnum, tlen, time: LONGINT;
 S: Texts.Scanner;  ok: BOOLEAN;
BEGIN
 ok := FALSE;
 Texts.WriteString(W, "Looking up ");  Texts.WriteString(W, server);  Texts.WriteLn(W);
 Texts.Append(Oberon.Log, W.buf);
 NetSystem.GetIP(server, ip);
 NetSystem.OpenConnection(c, NetSystem.anyport, ip, Port, res);
 IF res = NetSystem.done THEN
  tnum := 0;  tlen := 0;  time := Input.Time();
  WHILE root # NIL DO
   IF tnum MOD CollectFreq = 0 THEN Oberon.Collect END;
   Texts.WriteString(W, root.name1);
   IF root.name1 # root.name2 THEN
    Texts.WriteString(W, " => ");  Texts.WriteString(W, root.name2)
   END;
   Texts.WriteLn(W);  Texts.Append(Oberon.Log, W.buf);
   f := Files.Old(root.name1);  IF f = NIL THEN HALT(99) END;
   Files.Set(r, f, 0);  WriteString(c, root.name2);
   len := Files.Length(f);  NetSystem.WriteLInt(c, len);
   LOOP
    IF len > BufSize THEN num := BufSize ELSE num := len END;
    Files.ReadBytes(r, buf, num);  DEC(num, r.res);  DEC(len, num);
    IF num = 0 THEN
     EXIT
    ELSE
     NetSystem.WriteBytes(c, 0, num, buf);
     IF c.res # NetSystem.done THEN res := c.res;  HALT(99) END;
     INC(tlen, num)
    END
   END;
   NetSystem.ReadLInt(c, tres);
   IF tres # 0 THEN HALT(99) END; (* no acknowledge *)
   INC(tnum);
   root := root.next
  END;
  WriteString(c, "");
  NetSystem.CloseConnection(c);
  time := Input.Time() - time;
  Texts.WriteString(W, "Files sent: ");  Texts.WriteInt(W, tnum, 1);  Texts.WriteLn(W);
  Texts.WriteString(W, "Bytes sent: ");  Texts.WriteInt(W, tlen, 1);  Texts.WriteLn(W);
  IF time DIV Input.TimeUnit # 0 THEN
   Texts.WriteInt(W, time DIV Input.TimeUnit, 1);
   Texts.WriteString(W, " seconds.");  Texts.WriteLn(W);
   IF tlen > MAX(LONGINT) DIV Input.TimeUnit THEN
    Texts.WriteInt(W, tlen DIV (time DIV Input.TimeUnit), 1)
   ELSE
    Texts.WriteInt(W, tlen*Input.TimeUnit DIV time, 1)
   END;
   Texts.WriteString(W, " bytes per second.");  Texts.WriteLn(W)
  END;
  ok := TRUE
 ELSE
  Texts.WriteString(W, "Can not open connection");  Texts.WriteLn(W)
 END;
 Texts.Append(Oberon.Log, W.buf);
 RETURN ok
END Send;

PROCEDURE SendFiles*; (** server { file [=> file] } ~ *)
VAR root, last, new: List;  server: ARRAY 64 OF CHAR;  S: Texts.Scanner;
BEGIN
 OpenScanner(S);
 IF S.class IN {Texts.Name, Texts.String} THEN
  COPY(S.s, server);  Texts.Scan(S);
  NEW(root);  root.next := NIL;  last := root;
  LOOP
   NEW(new);  new.next := NIL;
   IF ~ScanPair(S, new.name1, new.name2) THEN EXIT END;
   last.next := new;  last := new
  END;
  IF Send(server, root.next) THEN END
 END
END SendFiles;

PROCEDURE ReceiveFiles*; (** server { file [=> file] } ~ *)
CONST BufSize = 1024;
VAR
 res: INTEGER;  f: Files.File;  r: Files.Rider;  len, num: LONGINT;
 c: NetSystem.Connection;  name1, name2: ARRAY 64 OF CHAR;  ip: NetSystem.IPAdr;
 buf: ARRAY BufSize OF CHAR;  tnum, tlen, time: LONGINT;
 S: Texts.Scanner;
BEGIN
 OpenScanner(S);
 IF S.class IN {Texts.Name, Texts.String} THEN
  Texts.WriteString(W, "Looking up ");  Texts.WriteString(W, S.s);  Texts.WriteLn(W);
  Texts.Append(Oberon.Log, W.buf);
  NetSystem.GetIP(S.s, ip);  Texts.Scan(S);
  NetSystem.OpenConnection(c, NetSystem.anyport, ip, Port, res);
  IF res # NetSystem.done THEN HALT(99) END;
  tnum := 0;  tlen := 0;  time := Input.Time();
  LOOP
   IF tnum MOD CollectFreq = 0 THEN Oberon.Collect END;
   IF ~ScanPair(S, name1, name2) THEN EXIT END;
   Texts.WriteString(W, name1);
   IF name2 # name1 THEN
    Texts.WriteString(W, " => ");  Texts.WriteString(W, name2)
   END;
   Texts.Append(Oberon.Log, W.buf);
   WriteString(c, name1);  NetSystem.WriteLInt(c, -1);
   NetSystem.ReadLInt(c, len);
   IF (c.res # NetSystem.done) OR (len < 0) THEN res := c.res;  HALT(99) END;
   Texts.Write(W, " ");  Texts.WriteInt(W, len, 1);
   Texts.WriteLn(W);  Texts.Append(Oberon.Log, W.buf);
   f := Files.New(name2);  IF f = NIL THEN HALT(99) END;
   Files.Set(r, f, 0);
   LOOP
    IF len > BufSize THEN num := BufSize ELSE num := len END;
    IF num = 0 THEN
     EXIT
    ELSE
     NetSystem.ReadBytes(c, 0, num, buf);
     IF c.res # NetSystem.done THEN res := c.res;  HALT(99) END;
     Files.WriteBytes(r, buf, num);
     IF r.res # 0 THEN res := SHORT(r.res);  HALT(99) END;
     DEC(len, num);
     INC(tlen, num)
    END
   END;
   Files.Register(f);
   NetSystem.WriteLInt(c, 0); (* result *)
   INC(tnum)
  END;
  WriteString(c, "");
  NetSystem.CloseConnection(c);
  time := Input.Time() - time;
  Texts.WriteString(W, "Files received: ");  Texts.WriteInt(W, tnum, 1);  Texts.WriteLn(W);
  Texts.WriteString(W, "Bytes received: ");  Texts.WriteInt(W, tlen, 1);  Texts.WriteLn(W);
  IF time DIV Input.TimeUnit > 1 THEN
   Texts.WriteInt(W, time DIV Input.TimeUnit, 1);
   Texts.WriteString(W, " seconds.");  Texts.WriteLn(W);
   IF tlen > MAX(LONGINT) DIV Input.TimeUnit THEN
    Texts.WriteInt(W, tlen DIV (time DIV Input.TimeUnit), 1)
   ELSE
    Texts.WriteInt(W, tlen*Input.TimeUnit DIV time, 1)
   END;
   Texts.WriteString(W, " bytes per second.");  Texts.WriteLn(W)
  END;
  Texts.Append(Oberon.Log, W.buf)
 END
END ReceiveFiles;

(* ReadLog - Read the log: { name [time date size] } *)

PROCEDURE ReadLog(name: ARRAY OF CHAR;  VAR root: List);
VAR s: Texts.Scanner;  t: Texts.Text;  new: List;
BEGIN
 root := NIL;
 NEW(t);  Texts.Open(t, name);
 IF t.len # 0 THEN
  Texts.OpenScanner(s, t, 0);  Texts.Scan(s);
  WHILE s.class = Texts.Name DO
   NEW(new);
   COPY(s.s, new.name1);
   Texts.Scan(s);
   IF s.class = Texts.Int THEN
    new.time := s.i;
    Texts.Scan(s);  ASSERT(s.class = Texts.Int);
    new.date := s.i;
    Texts.Scan(s);  ASSERT(s.class = Texts.Int);
    new.size := s.i;
    Texts.Scan(s)
   ELSE
    new.time := 0;  new.date := 0;  new.size := -1
   END;
   new.next := root;  root := new
  END
 END
END ReadLog;

PROCEDURE AddFile(name: ARRAY OF CHAR;  time, date, size: LONGINT;  VAR continue: BOOLEAN);
VAR p, n: List;  add: BOOLEAN;  i, j: LONGINT;
BEGIN
 IF StripPrefix THEN
  i := 0;  WHILE (name[i] # 0X) & (name[i] # ":") DO INC(i) END;
  IF name[i] = ":" THEN
   j := 0;  REPEAT INC(i); name[j] := name[i]; INC(j) UNTIL name[i] = 0X
  END
 END;
 p := NIL;  n := log;  WHILE (n # NIL) & (name # n.name1) DO p := n;  n := n.next END;
 IF n = NIL THEN (* not found in old log *)
  NEW(n);  COPY(name, n.name1); (* new file *)
  add := TRUE
 ELSE (* found in old log *)
  IF p = NIL THEN log := log.next ELSE p.next := n.next END; (* delete n from log *)
  add := (n.time # time) OR (n.date # date) OR (n.size # size)
 END;
 COPY(n.name1, n.name2); (* from/to same *)
 n.time := time;  n.date := date;  n.size := size; (* update stamp *)
 Texts.WriteString(W, n.name1);  Texts.Write(W, 9X);
 Texts.WriteInt(W, n.time, 1);  Texts.Write(W, 9X);
 Texts.WriteInt(W, n.date, 1);  Texts.Write(W, 9X);
 Texts.WriteInt(W, n.size, 1);  Texts.WriteLn(W);
 Texts.Append(logtext, W.buf);
 IF add THEN
  last.next := n;  n.next := NIL;  last := n
 END
END AddFile;

PROCEDURE Inc(send: BOOLEAN);
VAR server: ARRAY 64 OF CHAR;  s: Texts.Scanner;
BEGIN
 Texts.OpenScanner(s, Oberon.Par.text, Oberon.Par.pos);
 Texts.Scan(s);
 IF ~send OR (s.class IN {Texts.Name, Texts.String}) THEN
  IF send THEN COPY(s.s, server);  Texts.Scan(s) END;
  IF s.class = Texts.Name THEN
   ReadLog(s.s, log);
   NEW(logtext);  Texts.Open(logtext, "");
   NEW(list);  list.next := NIL;  last := list;
   FileDir.Enumerate("", TRUE, AddFile);
   IF ~send OR Send(server, list.next) THEN
    Oberon.OpenText(s.s, logtext, 400, 400)
   END
  END
 END;
 log := NIL;  list := NIL;  last := NIL;  logtext := NIL
END Inc;

PROCEDURE Incremental*; (** server logtext *)
BEGIN
 Inc(TRUE)
END Incremental;

PROCEDURE LogSnapshot*; (** logtext *)
BEGIN
 Inc(FALSE)
END LogSnapshot;

BEGIN
 Texts.OpenWriter(W)
END NetBackup.

NetBackup.SendFiles huxley t1 t2 ~
NetBackup.ReceiveFiles huxley t1=>t2 ~

System.DeleteFiles test.Log ~
NetBackup.Incremental huxley test.Log ~

NetBackup.LogSnapshot HomeZip.Log

