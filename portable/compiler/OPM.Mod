(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OPM; (** non-portable *)

(* Machine dependent constants needed before code generation *)
(* Host interface *)
(* RC, NM, pjm, prk *)

 IMPORT
  Fonts, Texts, Oberon, Files, SYSTEM;

 CONST (* i386 *)

  (* basic type sizes *)
  ByteSize* = 1; (* SYSTEM.BYTE *)
  CharSize* = 1; (* CHAR *)
  BoolSize* = 1; (* BOOLEAN *)
  SetSize* = 4; (* SET *)
  SIntSize* = 1; (* SHORTINT *)
  IntSize* = 2; (* INTEGER *)
  LIntSize* = 4; (* LONGINT *)
  HIntSize* = 8; (* HUGEINT *)
  RealSize* = 4; (* REAL *)
  LRealSize* = 8; (* LONGREAL *)
  ProcSize* = 4; (* PROCEDURE type *)
  PointerSize* = 4; (* POINTER type *)

  (* value of constant NIL *)
  nilval* = 0;
  
  (* target machine minimum values of basic types expressed in host machine format: *)
  MinSInt* = -80H;
  MinInt* = -8000H;
  MinLInt* =  80000000H; (* i386: -2147483648*)
  MinRealPat = 0FF7FFFFFH; (* most  negative, 32-bit pattern *)
  MinLRealPatL = 0FFFFFFFFH; (* most  negative, lower 32-bit pattern *)
  MinLRealPatH = 0FFEFFFFFH; (* most  negative, higher 32-bit pattern *)
  
  (* target machine maximum values of basic types expressed in host machine format: *)
  MaxSInt* = 7FH;
  MaxInt* = 7FFFH;
  MaxLInt* = 7FFFFFFFH; (* i386: 2147483647*)
  MaxSet* = 31; (* must be >= 15, else the bootstraped compiler cannot run (IN-tests) *)
  MaxRealPat = 7F7FFFFFH; (* most positive, 32-bit pattern *)
  MaxLRealPatL = 0FFFFFFFFH; (* most positive, lower 32-bit pattern *)
  MaxLRealPatH = 7FEFFFFFH;  (* most positive, higher 32-bit pattern *)
  
  (* maximal index value for array declaration: *)
  MaxIndex* = MaxLInt;

  (* parametrization of numeric scanner: *)
  MaxHDig* = 8; (* maximal hexadecimal longint length *)
  MaxRExp* = 38; (* maximal real exponent *)
  MaxLExp* = 308; (* maximal longreal exponent *)
  
  (* inclusive range of parameter of standard procedure HALT: *)
  MinHaltNr* = 20;
  MaxHaltNr* = MAX(LONGINT);

  (* inclusive range of register number of procedures SYSTEM.GETREG and SYSTEM.PUTREG: *)
  (* MinRegNr and MaxRegNr moved to OPTR (target module) *)
  
  (* maximal value of flag used to mark interface structures: *)
  MaxSysFlag* = 0; (* i386: only 0 is valid, not used *)
  
  (* maximal condition value of parameter of SYSTEM.CC: *)
  MaxCC* = -1; (* not implemented interpretation is left to the back-end *)
  
  (* initialization of linkadr field in ObjDesc, must be different from any valid link address: *)
  LANotAlloc* = -1;
  
  (* initialization of constant address, must be different from any valid constant address: *)
  ConstNotAlloc* = -1; (* i386: only strings are allocated *)
  
  (* initialization of tdadr field in StrDesc, must be different from any valid address: *)
  TDAdrUndef* = -1;
  
  (* maximal number of cases in a case statement: *)
  MaxCases* = 128;
  
  (* maximal range of a case statement (higher label - lower label ~ jump table size): *)
  MaxCaseRange* = 512;

  (* whether field leaf of pointer variable p has to be set to FALSE, when NEW(p) or SYSTEM.NEW(p, n) is used: *)

  NEWusingAdr* = FALSE;

  (* mask for the TD associated with an object instance: mask away GC information *)
  TDMask* = 0 (*0FFFFFFF8H*); (* set to 0 to disable masking *)

  (*Configuration -- temp *)
  OptimizeSelf* = TRUE; (* if possible, make self pointer-based in methods *)
  WarnUnsafe* = FALSE; (* generate warnings for "unsafe" language features *)

  (* special character (< " ") returned by procedure Get, if end of text reached *)
  Eot* = 0X;
  SetLen = MAX(SET)+1;
  NumErrors = (912+SetLen) DIV SetLen * SetLen;

  PathChar = "/";
  
  (** Code Generator Options *)
  inxchk* = 0; (** index check *)
  ovflchk* = 1; (** overflow check *)
  typchk* = 3; (** type checking *)
  ptrinit* = 5; (** pointer initialization *)
  assert* = 6; (** assert evaluation *)
  fullstackinit* = 20; (** zero all the stack (only if ptrinit)*)
  trace* = 22; (** trace procedure usage *)
  
  exportDefinitions* = 30;
  useDefinitions* = 31;
  
  (** Parser Compiler Options *)
  findpc* = 7; (** find text position of breakpc *)
  systemchk* = 8; (** prevent compilation of modules that import SYSTEM *) (* jm *)
  nofiles* = 9; (** don't create any files (dVdW) *)
  newsf* = 10; (** generation of new symbol file allowed *)
  extsf* = 11; (** generation of extended symbol file allowed *)
  warning* = 12; (** display warnings *)
  prefix* = 18; (** X - retain filename prefix on .Sym & .Obj file (Native) *)
  oberon2* = 19;  (** 2 - compile oberon-2 programs *)
  oberon1* = 21; (** compile oberon-1 programs *)
  traceprocs* = 24; (** trace procedure calls *) (* temp *)
  aosMode* = 25; (** compile for Active Object System (AOS/Bluebottle) *)
  
  DefaultCodeOpt* = {inxchk, typchk, ptrinit, fullstackinit, assert};
  DefaultParserOpt* = {};
  
  NewFileFormat* = FALSE;
  
  (* Targets: *)
  i386* = 0; arm32* = 1; rv32* = 2;

  
 VAR
  MinReal*, MaxReal*: REAL;
  MinLReal*, MaxLReal*: LONGREAL;
  noerr*: BOOLEAN; (* no error found until now *)
  curpos*, errpos*: LONGINT; (* character and error position in source file *)
  breakpos*: LONGINT; (* set by Mark *)
  breakpc*: LONGINT; (*set by OPV.Init*)
  errors: ARRAY NumErrors DIV SetLen OF SET;
  outputPath*: ARRAY 32 OF CHAR; (* for reading and writing obj files. must include any trailing "/" or ":" *)
  outputPrefix*: ARRAY 32 OF CHAR; (* for writing obj files (in addition to outputPath). *)
  codeOptions*, parserOptions*: SET;
  errName*: ARRAY 32 OF CHAR;
  first: BOOLEAN;
  extension*: ARRAY 8 OF CHAR; (** object file extension *)
  aosFlag*: BOOLEAN; (** TRUE when compiling for AOS *)

 CONST
  OFtag = 0BBX; (* object file tag *)
  OFnative* = 0AFX; (* exported to make Builder, Browser and Watson0 portable on Unix ports *)
  OFnew = 0B0X;
  OFportable = 088X;

 VAR
  LRealPat: RECORD L, H: LONGINT END ;
  lastpos, pat: LONGINT; (* last position error in source file *)
  refpatch: LONGINT; (* OM: last position error in source file *)
  inR: Texts.Reader;
  Log: Texts.Text;
  W: Texts.Writer;
  oldSymF, newSymF, ObjF, RefF, ModF: Files.Rider;
  RefFile, ObjFile, ModFile, oldSymFile, newSymFile: Files.File;
  
 PROCEDURE Init*(codeOpt, parserOpt: SET; source: Texts.Reader; log: Texts.Text);
  VAR i: SHORTINT;
 BEGIN inR := source; Log := log; codeOptions := codeOpt; parserOptions := parserOpt;
  noerr := TRUE; curpos := Texts.Pos(inR); errpos := curpos; lastpos := curpos-10;
  FOR i := 0 TO NumErrors DIV SetLen - 1 DO errors[i] := {} END;
  Oberon.Collect
 END Init;
 
 PROCEDURE Close*;
 BEGIN
  Files.Set(oldSymF, NIL, 0); Files.Set(newSymF, NIL, 0); Files.Set(ObjF, NIL, 0); Files.Set(RefF, NIL, 0);
  oldSymFile := NIL; newSymFile := NIL; ObjFile := NIL;  RefFile := NIL;
 END Close;
 
 PROCEDURE Get*(VAR ch: CHAR); (* read next character from source text, Eot if no more *)
 BEGIN
  (* System3 get: skip embedded objects *)
  REPEAT
   Texts.Read(inR, ch); INC(curpos)
  UNTIL inR.eot OR ((inR.lib # NIL) & (inR.lib IS Fonts.Font))
 END Get;
 
 PROCEDURE MakeFileName(VAR path, prefix, modName, fileName: ARRAY OF CHAR; ext: ARRAY OF CHAR);
  VAR i, j: INTEGER; ch: CHAR;
 BEGIN i:=0; ch:=path[0];
  WHILE ch#0X DO fileName[i]:=ch; INC(i); ch:=path[i] END;
(*
  IF (i # 0) & (path[i-1] # PathChar) & (path[i-1] # ":") THEN fileName[i] := PathChar; INC(i) END;
*)
  j := 0;  ch := prefix[0];
  WHILE ch # 0X DO fileName[i] := ch;  INC(i);  INC(j);  ch := prefix[j] END;
  j:=0; ch:=modName[0];
  WHILE ch#0X DO fileName[i]:=ch; INC(i); INC(j); ch:=modName[j] END;
  j := -1; REPEAT INC(j); fileName[i] := ext[j]; INC(i) UNTIL ext[j] = 0X
 END MakeFileName;

 (* ----- Fingerprint calculation ----- *)

 PROCEDURE FPrint*(VAR fp: LONGINT; val: LONGINT);
 BEGIN fp:=SYSTEM.VAL(LONGINT, SYSTEM.VAL(SET, SYSTEM.ROT(fp, 7)) / SYSTEM.VAL(SET, val))
 END FPrint;

 PROCEDURE FPrintSet*(VAR fp: LONGINT; set: SET);
 BEGIN FPrint(fp, SYSTEM.VAL(LONGINT, set))
 END FPrintSet;

 PROCEDURE FPrintReal*(VAR fp: LONGINT; real: REAL);
 BEGIN FPrint(fp, SYSTEM.VAL(LONGINT, real))
 END FPrintReal;

 PROCEDURE FPrintLReal*(VAR fp: LONGINT; lr: LONGREAL);
  VAR l, h: LONGINT;
 BEGIN
  SYSTEM.GET(SYSTEM.ADR(lr)+4, l); SYSTEM.GET(SYSTEM.ADR(lr), h);
  FPrint(fp, l); FPrint(fp, h);
 END FPrintLReal;
 
 (* ----- auxiliaries ----- *)

 PROCEDURE WString(VAR R: Files.Rider; VAR s: ARRAY OF CHAR);
  VAR i: INTEGER; ch: CHAR;
 BEGIN i:=0; ch:=s[i];
  IF ch=0X THEN Files.Write(R, 0X); RETURN END;
  WHILE (ch#0X) & (ch<7FX) DO INC(i); ch:=s[i] END;
  IF i>1 THEN Files.WriteBytes(R, s, i-1) END;
  IF ch=0X THEN Files.Write(R, CHR(ORD(s[i-1])+80H))
  ELSE 
   IF i>0 THEN Files.Write(R, s[i-1]) END;
   Files.Write(R, 7FX); REPEAT Files.Write(R, ch); INC(i); ch:=s[i] UNTIL ch=0X;
   Files.Write(R, 0X)
  END
 END WString;

 (* ------------------------- Log Output ------------------------- *)
 
 PROCEDURE LogW*(ch: CHAR);
 BEGIN
  Texts.Write(W, ch); Texts.Append(Log, W.buf)
 END LogW;
 
 PROCEDURE LogWStr*(s: ARRAY OF CHAR);
 BEGIN
  Texts.WriteString(W, s); Texts.Append(Log, W.buf)
 END LogWStr;
 
 PROCEDURE LogWNum*(i, len: LONGINT);
 BEGIN
  Texts.WriteInt(W, i, len); Texts.Append(Log, W.buf)
 END LogWNum;

 PROCEDURE LogWHex*(i: LONGINT);
 BEGIN Texts.WriteHex(W, i); Texts.Write(W, "H"); Texts.Append(Log, W.buf)
 END LogWHex;

 PROCEDURE LogWLn*;
 BEGIN
  Texts.WriteLn(W); Texts.Append(Log, W.buf)
 END LogWLn;
 
 PROCEDURE ErrorText(n: INTEGER; VAR msg: ARRAY OF CHAR);
 BEGIN
  (* this is the code/text table originally in OP2.Errors, which I found in Oberon.Text on v2.3.7 *)
  IF n < 150 THEN
    CASE n OF
      0: COPY("undeclared identifier", msg)
    | 1: COPY("multiply defined identifier", msg)
    | 2: COPY("illegal character in number", msg)
    | 3: COPY("illegal character in string", msg)
    | 4: COPY("identifier does not match procedure name", msg)
    | 5: COPY("comment not closed", msg)
    | 9: COPY("'=' expected", msg)
    | 12: COPY("type definition starts with incorrect symbol", msg)
    | 13: COPY("value starts with incorrect symbol", msg)
    | 14: COPY("statement starts with incorrect symbol", msg)
    | 15: COPY("declaration followed by incorrect symbol", msg)
    | 16: COPY("MODULE expected", msg)
    | 18: COPY("'.' missing", msg)
    | 19: COPY("',' missing", msg)
    | 20: COPY("':' missing", msg)
    | 22: COPY("')' missing", msg)
    | 23: COPY("']' missing", msg)
    | 24: COPY("'}' missing", msg)
    | 25: COPY("OF missing", msg)
    | 26: COPY("THEN missing", msg)
    | 27: COPY("DO missing", msg)
    | 28: COPY("TO missing", msg)
    | 30: COPY("'(' missing", msg)
    | 34: COPY("':=' missing", msg)
    | 35: COPY("',' or OF expected", msg)
    | 38: COPY("EXIT not within loop statement", msg)
    | 40: COPY("identifier expected", msg)
    | 41: COPY("';' missing", msg)
    | 43: COPY("END missing", msg)
    | 46: COPY("UNTIL missing", msg)
    | 47: COPY("illegally marked identifier", msg)
    | 50: COPY("expression should be constant", msg)
    | 51: COPY("constant not an integer", msg)
    | 52: COPY("identifier does not denote a type", msg)
    | 53: COPY("identifier does not denote a record type", msg)
    | 54: COPY("result type of procedure is not a basic type", msg)
    | 55: COPY("procedure call of a function", msg)
    | 56: COPY("assignment to non-variable", msg)
    | 57: COPY("pointer not bound to record or array type", msg)
    | 58: COPY("recursive type definition", msg)
    | 59: COPY("illegal open array parameter", msg)
    | 60: COPY("wrong type of case label", msg)
    | 61: COPY("inadmissible type of case label", msg)
    | 62: COPY("case label defined more than once", msg)
    | 63: COPY("illegal value of constant", msg)
    | 64: COPY("more actual than formal parameters", msg)
    | 65: COPY("fewer actual than formal parameters", msg)
    | 66: COPY("element types of actual array and formal open array differ", msg)
    | 67: COPY("actual parameter corresponding to open array is not an array", msg)
    | 68: COPY("control variable must be integer", msg)
    | 69: COPY("parameter must be an integer constant", msg)
    | 70: COPY("pointer or VAR record required as formal receiver", msg)
    | 71: COPY("pointer expected as actual receiver", msg)
    | 72: COPY("procedure must be bound to a record of the same scope", msg)
    | 73: COPY("procedure must be of level 0", msg)
    | 74: COPY("procedure unknown in base type", msg)
    | 75: COPY("invalid call of base procedure", msg)
    | 76: COPY("this variable (field) is read only", msg)
    | 77: COPY("object is not a record", msg)
    | 78: COPY("dereferenced object is not a variable", msg)
    | 79: COPY("indexed object is not a variable", msg)
    | 80: COPY("index expression is not an integer", msg)
    | 81: COPY("index out of specified bounds", msg)
    | 82: COPY("indexed variable is not an array", msg)
    | 83: COPY("undefined record field", msg)
    | 84: COPY("dereferenced variable is not a pointer", msg)
    | 85: COPY("guard or test type is not an extension of variable type", msg)
    | 86: COPY("guard or test type is not a pointer", msg)
    | 87: COPY("guarded or tested variable is neither a pointer nor a VAR-parameter record", msg)
    | 88: COPY("open array not allowed as variable, record field or array element", msg)
    | 89: COPY("open lower bound not bound to procedure parameter", msg)
    | 90: COPY("semi-dynamic array not allowed in a record", msg)
    | 92: COPY("operand of IN not an integer, or not a set", msg)
    | 93: COPY("set element type is not an integer", msg)
    | 94: COPY("operand of & is not of type BOOLEAN", msg)
    | 95: COPY("operand of OR is not of type BOOLEAN", msg)
    | 96: COPY("operand not applicable to (unary) +", msg)
    | 97: COPY("operand not applicable to (unary) -", msg)
    | 98: COPY("operand of ~ is not of type BOOLEAN", msg)
    | 99: COPY("ASSERT fault", msg)
    | 100: COPY("incompatible operands of dyadic operator", msg)
    | 101: COPY("operand type inapplicable to *", msg)
    | 102: COPY("operand type inapplicable to /", msg)
    | 103: COPY("operand type inapplicable to DIV", msg)
    | 104: COPY("operand type inapplicable to MOD", msg)
    | 105: COPY("operand type inapplicable to +", msg)
    | 106: COPY("operand type inapplicable to -", msg)
    | 107: COPY("operand type inapplicable to = or #", msg)
    | 108: COPY("operand type inapplicable to relation", msg)
    | 109: COPY("overriding method must be exported", msg)
    | 110: COPY("operand is not a type", msg)
    | 111: COPY("operand inapplicable to (this) function", msg)
    | 112: COPY("operand is not a variable", msg)
    | 113: COPY("incompatible assignment", msg)
    | 114: COPY("string too long to be assigned", msg)
    | 115: COPY("parameter does not match", msg)
    | 116: COPY("number of parameters do not match", msg)
    | 117: COPY("result type does not match", msg)
    | 118: COPY("export mark does not match with forward declaration", msg)
    | 119: COPY("redefinition textually precedes procedure bound to base type", msg)
    | 120: COPY("type of expression following IF, WHILE, UNTIL or ASSERT is not BOOLEAN", msg)
    | 121: COPY("called object is not a procedure (or is an interrupt procedure)", msg)
    | 122: COPY("actual VAR-parameter is not a variable", msg)
    | 123: COPY("type of actual parameter is not identical with that of formal VAR-parameter", msg)
    | 124: COPY("type of result expression differs from that of procedure", msg)
    | 125: COPY("type of case expression is neither INTEGER nor CHAR", msg)
    | 126: COPY("this expression must not be a type or a procedure", msg)
    | 127: COPY("illegal use of object", msg)
    | 128: COPY("unsatisfied forward reference", msg)
    | 129: COPY("unsatisfied forward procedure", msg)
    | 130: COPY("WITH clause does not specify a variable", msg)
    | 131: COPY("LEN not applied to array", msg)
    | 132: COPY("dimension in LEN too large or negative", msg)
    | 134: COPY("initialiser can not return a value", msg)
    | 135: COPY("SYSTEM not imported", msg)
    | 136: COPY("recursive call of operator", msg)
    | 137: COPY("operator not defined", msg)
    | 138: COPY("VAR-parameter not allowed", msg)
    | 139: COPY("multiply-defined operator", msg)
    | 140: COPY("operator not allowed in record scope", msg)
    | 141: COPY("operator type missing", msg)
    | 142: COPY("name does not denote an operator", msg)
    | 143: COPY("invalid number of formal parameters", msg)
    | 144: COPY("only one initializer allowed in a record", msg)
    | 145: COPY("forward declaration not allowed", msg)
    | 146: COPY("operator must use one locally declared argument type", msg)
    | 147: COPY(":= operator: cannot be a function", msg)
    | 148: COPY(":= operator: first parameter must be VAR", msg)
    END;
  ELSIF n < 500 THEN
    CASE n OF
    | 150: COPY("key inconsistency of imported module", msg)
    | 151: COPY("incorrect symbol file", msg)
    | 152: COPY("symbol file of imported module not found", msg)
    | 153: COPY("object or symbol file not opened (disk full?)", msg)
    | 154: COPY("recursive import not allowed", msg)
    | 155: COPY("generation of new symbol file not allowed", msg)
    | 170: COPY("incompatible assignment (declare the record as POINTER TO RECORD)", msg)
    | 200: COPY("not yet implemented", msg)
    | 201: COPY("lower bound of set range greater than higher bound", msg)
    | 202: COPY("set element greater than MAX(SET) or less than 0", msg)
    | 203: COPY("number too large", msg)
    | 204: COPY("product too large", msg)
    | 205: COPY("division by zero", msg)
    | 206: COPY("sum too large", msg)
    | 207: COPY("difference too large", msg)
    | 208: COPY("overflow in arithmetic shift", msg)
    | 209: COPY("case range too large", msg)
    | 210: COPY("code too long (> 64 KB)", msg)
    | 211: COPY("procedure too large (reduce procedure size)", msg)
    | 212: COPY("operator should precede procedure declaration", msg)
    | 213: COPY("too many cases in case statement", msg)
    | 215: COPY("not enough registers: simplify expression", msg)
    | 216: COPY("not enough floating-point registers: simplify expression", msg)
    | 218: COPY("illegal value of parameter (20 <= p < 256)", msg)
    | 219: COPY("illegal value of parameter (0 <= p < 16)", msg)
    | 220: COPY("illegal value of parameter", msg)
    | 221: COPY("too many pointers in a record", msg)
    | 222: COPY("too many global pointers", msg)
    | 223: COPY("too many record types", msg)
    | 224: COPY("too many pointer types", msg)
    | 225: COPY("address of pointer variable too large (move forward in text)", msg)
    | 226: COPY("too many exported and/or type-bound procedures", msg)
    | 227: COPY("too many imported modules", msg)
    | 228: COPY("too many exported structures", msg)
    | 229: COPY("too many nested records for import", msg)
    | 230: COPY("too many constants (strings) in module", msg)
    | 231: COPY("too many external and/or type-bound procedures", msg)
    | 232: COPY("too many commands in module", msg)
    | 233: COPY("record extension hierarchy too high", msg)
    | 234: COPY("export of recursive type not allowed", msg)
    | 235: COPY("too many accesses to global variables or constants", msg)
    | 236: COPY("too many exported variables", msg)
    | 240: COPY("identifier too long", msg)
    | 241: COPY("string too long", msg)
    | 242: COPY("address overflow", msg)
    | 243: COPY("too many imported variables", msg)
    | 246: COPY("already inside an exclusive statement block", msg)
    | 247: COPY("local variables not allowed in inlined assembler procedure", msg)
    | 248: COPY("PASSIVATE with global condition", msg)
    | 249: COPY("only allowed for POINTER TO RECORDs", msg)
    | 250: COPY("inlined oberon procedures can not be exported", msg)
    | 251: COPY("too many nested function calls", msg)
    | 252: COPY("pointer to this record required", msg)
    | 253: COPY("initialiser must belong to a record", msg)
    | 254: COPY("can not define a static instance of an active object", msg)
    | 260: COPY("Active Oberon forward reference", msg)
    | 261: COPY("Active Oberon method", msg)
    | 262: COPY("Active Oberon relaxed declaration order", msg)
    | 270: COPY("Oberon X structured return type", msg)
    | 271: COPY("Oberon X array", msg)
    | 272: COPY("allowed only in active objects", msg)
    | 280: COPY("duplicate fingerprint", msg)
    | 301: COPY("implicit type cast", msg)
    | 302: COPY("guarded variable can be side-effected", msg)
    | 303: COPY("SYSTEM.PTR var parameter output-only", msg)
    | 304: COPY("SYSTEM.VAL size mismatch", msg)
    | 305: COPY("only open arrays and named types can be used", msg)
    | 306: COPY("possible size mismatch", msg)
    | 310: COPY("ambiguous operator", msg)
    | 311: COPY("dynamic array deep copy", msg)
    | 312: COPY("implicit reference to heap object via VAR", msg)
    END;
  ELSE
    CASE n OF
    | 500: COPY("undeclared identifier", msg)
    | 501: COPY("addressing mode not allowed", msg)
    | 502: COPY("undefined instruction", msg)
    | 503: COPY("number too large", msg)
    | 504: COPY("invalid operand combination", msg)
    | 505: COPY("register expected", msg)
    | 506: COPY("register expected", msg)
    | 507: COPY("'[' expected", msg)
    | 508: COPY("invalid shift amount", msg)
    | 509: COPY("operand already defined", msg)
    | 510: COPY("end of line expected", msg)
    | 511: COPY("operand missing", msg)
    | 512: COPY("undefined operand size", msg)
    | 513: COPY("string expected", msg)
    | 514: COPY("object type not supported", msg)
    | 515: COPY("instruction not supported on target", msg)
    | 516: COPY("no target specified", msg)
    | 517: COPY("access to non-local variables not allowed in exported inlined procedure", msg)
    | 518: COPY("inlined procedure: procedure activation frame does not exist", msg)
    | 900: COPY("never used", msg)
    | 901: COPY("never set", msg)
    | 902: COPY("used before set", msg)
    | 903: COPY("set but never used", msg)
    | 904: COPY("used as varpar, possibly not set", msg)
    | 905: COPY("also declared in outer scope", msg)
    | 906: COPY("access/assignment to intermediate", msg)
    | 907: COPY("redefinition", msg)
    | 908: COPY("new definition", msg)
    | 909: COPY("statement after RETURN/EXIT", msg)
    | 910: COPY("for loop variable set", msg)
    | 911: COPY("implied type guard in record assignment", msg)
    | 912: COPY("call might depend on evaluation sequence of params", msg)
    | 913: COPY("parameter never used", msg)
    ELSE msg[0] := 0X
    END; 
  END
 END ErrorText;

 PROCEDURE ErrorMsg(n: INTEGER);
 VAR e: ARRAY 127 OF CHAR;
 BEGIN
  IF (n >= NumErrors) OR ~((n MOD SetLen) IN errors[n DIV SetLen]) THEN
   IF (n < NumErrors) THEN INCL(errors[n DIV SetLen], n MOD SetLen) END;
   ErrorText(n, e);
   IF e[0] # 0X THEN
    Texts.Write(W, 9X); LogWStr(e)
   END
  END
 END ErrorMsg;
  
 PROCEDURE Mark*(n: INTEGER; pos: LONGINT);
 BEGIN
  IF n >= 0 THEN
   noerr := FALSE;
   IF (pos < lastpos) OR (lastpos + 9 < pos) OR (n>=450) & (n<=460) OR (n=155) THEN lastpos := pos;
    LogWLn; LogW(9X); LogW(9X);
    IF (n<450) OR (n>460) THEN
     LogWStr("pos"); LogWNum(pos, 7);
     IF n = 255 THEN LogWStr("  pc "); LogWHex(breakpc); breakpos := pos
     ELSIF n = 254 THEN LogWStr("  pc not found")
     ELSE LogWStr("  err"); LogWNum(n, 4); ErrorMsg(n)
     END
    ELSE LogWStr(errName);
     IF n=450 THEN LogWStr(" is no longer visible")
     ELSIF n=451 THEN LogWStr(" is new")
     ELSIF n=452 THEN LogWStr(" is redefined")
     END
    END
   END
  ELSIF warning IN parserOptions THEN
   LogWLn; LogW(9X); LogW(9X); LogWStr("pos"); LogWNum(pos, 7); LogWStr("  warning"); LogWNum(-n, 4);
   ErrorMsg(-n)
  END
 END Mark;
 
 PROCEDURE err*(n: INTEGER);
 BEGIN Mark(n, errpos)
 END err;

 (* ------------------------- Write Symbol File ------------------------- *)
 
 PROCEDURE SymW*(b: CHAR);
 BEGIN Files.Write(newSymF, b)
 END SymW;

 PROCEDURE SymWCh*(ch: CHAR);
 BEGIN Files.Write(newSymF, ch)
 END SymWCh;

 PROCEDURE SymWTag*(k: INTEGER);
 BEGIN Files.Write(newSymF, CHR(k))
 END SymWTag;

 PROCEDURE SymWInt*(k: LONGINT);
 BEGIN Files.WriteInt(newSymF, SHORT(k))
 END SymWInt;

 PROCEDURE SymWLInt*(k: LONGINT);
 BEGIN Files.WriteLInt(newSymF, k)
 END SymWLInt;

 PROCEDURE SymWNum*(i: LONGINT);
 BEGIN Files.WriteNum(newSymF, i)
 END SymWNum;

 PROCEDURE SymWPos*():LONGINT;
 BEGIN RETURN Files.Pos(newSymF)+Files.Pos(ModF);
 END SymWPos;

 PROCEDURE SymWMod*(VAR name: ARRAY OF CHAR);
 BEGIN  WString(ModF, name)
 END SymWMod;

 PROCEDURE SymWSet*(s: SET);
 BEGIN Files.WriteNum(newSymF, SYSTEM.VAL(LONGINT, s))
 END SymWSet;

 PROCEDURE SymWReal*(r: REAL);
 BEGIN Files.WriteReal(newSymF, r)
 END SymWReal;
 
 PROCEDURE SymWLReal*(lr: LONGREAL);
 BEGIN Files.WriteLReal(newSymF, lr)
 END SymWLReal;
 
 PROCEDURE SymWString*(VAR s: ARRAY OF CHAR);
 BEGIN WString(newSymF, s)
 END SymWString;

 (* ------------------------- Write Reference & Object Files ------------------------- *)

 PROCEDURE RefW*(ch: CHAR);
 BEGIN Files.Write(RefF, ch)
 END RefW;

 PROCEDURE RefWNum* (i: LONGINT);
 BEGIN
  Files.WriteNum (RefF, i)
 END RefWNum;

 PROCEDURE ObjW*(ch: CHAR);
 BEGIN Files.Write(ObjF, ch)
 END ObjW;

 PROCEDURE ObjWInt*(i: INTEGER);
 BEGIN Files.WriteInt(ObjF, i)
 END ObjWInt;

 PROCEDURE ObjWLInt*(i: LONGINT);
 BEGIN Files.WriteLInt(ObjF, i)
 END ObjWLInt;

 PROCEDURE ObjWBytes*(VAR bytes: ARRAY OF SYSTEM.BYTE; n: LONGINT);
 BEGIN Files.WriteBytes(ObjF, bytes, n)
 END ObjWBytes;

 PROCEDURE ObjWNum*(i: LONGINT);
 BEGIN Files.WriteNum(ObjF, i)
 END ObjWNum;

 PROCEDURE ObjWString*(VAR s: ARRAY OF CHAR);
 BEGIN WString(ObjF, s)
 END ObjWString;

 PROCEDURE ObjAllocInt*(): LONGINT;
  VAR pos: LONGINT;
 BEGIN pos:=Files.Pos(ObjF); Files.WriteInt(ObjF, SYSTEM.VAL(INTEGER, 0));
  RETURN pos;
 END ObjAllocInt;

 PROCEDURE ObjFillInt*(pos: LONGINT; int: INTEGER);
  VAR savepos: LONGINT;
 BEGIN savepos:=Files.Pos(ObjF);
  Files.Set(ObjF, ObjFile, pos); Files.WriteBytes(ObjF, int, 2);
  Files.Set(ObjF, ObjFile, savepos);
 END ObjFillInt;

 (* ----- files ----- *)

 PROCEDURE OpenSym*(VAR R: Files.Rider; VAR name: ARRAY OF CHAR; self: BOOLEAN; VAR done: BOOLEAN);
  VAR  fileName: ARRAY 512 OF CHAR; ch, ch1: CHAR; symSize: LONGINT; F: Files.File; empty: ARRAY 1 OF CHAR; flags: SET;
 BEGIN
  empty[0] := 0X;
  MakeFileName(outputPath, empty, name, fileName, extension); 
  done := FALSE;
  F := Files.Old(fileName);
  IF F # NIL THEN done := TRUE; Files.Set(R, F, 0);
   Files.Read(R, ch);
   IF ch=OFtag THEN Files.Read(R, ch1); Files.ReadNum(R, symSize);
    IF ch1 = OFnew THEN
     Files.ReadSet(R, flags);
     IF exportDefinitions IN flags THEN err(151); done := FALSE END
    ELSIF ch1 # OFnative THEN
     err(151); done := FALSE
    END
   ELSE (* eb, 30.11.95 err(511); *) done := FALSE
   END
  END
 END OpenSym;
 
 PROCEDURE Begin*(VAR modName: ARRAY OF CHAR);
  VAR ObjFName: ARRAY 512 OF CHAR;
 BEGIN
  MakeFileName(outputPath, outputPrefix, modName, ObjFName, extension);
  ObjFile:=Files.New(ObjFName);
  IF ObjFile = NIL THEN  err(153);  RETURN  END;
  Files.Set(ObjF, ObjFile, 0); Files.Write(ObjF, OFtag);
  ModFile:=Files.New(""); Files.Set(ModF, ModFile, 0); 
  newSymFile:=Files.New(""); Files.Set(newSymF, newSymFile, 0);
  RefFile := Files.New(""); Files.Set(RefF, RefFile, 0);
  IF NewFileFormat THEN
   Files.Write(ObjF, OFnew)
  ELSE
   Files.Write(ObjF, OFnative);
  END;
 END Begin;

 PROCEDURE Commit(F: Files.File);
  VAR ch: CHAR; R: Files.Rider;
 BEGIN Files.Set(R, F, 0); Files.Read(R, ch);
  WHILE ~R.eof DO Files.Write(ObjF, ch); Files.Read(R, ch) END
 END Commit;

 PROCEDURE EndSym*;
  VAR sfsize: LONGINT;  
 BEGIN Files.Write(ModF, 0X); 
  IF NewFileFormat THEN
   sfsize := 4 + Files.Length(newSymFile) + Files.Length(ModFile);
   Files.WriteNum(ObjF, sfsize);
   Files.WriteSet(ObjF, codeOptions)
  ELSE
   sfsize:=Files.Length(newSymFile)+Files.Length(ModFile); Files.WriteNum(ObjF, sfsize)
  END;
  Commit(ModFile); Commit(newSymFile);
  refpatch:=Files.Pos(ObjF); ObjWInt(0); ObjWInt(0)
 END EndSym;

 PROCEDURE EndObj*;
  VAR refsize: LONGINT;
 BEGIN
  refsize:=Files.Length(RefFile); ObjW(8DX); Commit(RefFile); 
  Files.Set(ObjF, ObjFile, refpatch); ObjWBytes(refsize, 4); 
  Files.Register(ObjFile); 
 END EndObj;
 
 PROCEDURE CloseObj*;
  VAR refsize: LONGINT; ch: CHAR; ref: Files.Rider;
 BEGIN (*ref block*)
  refsize:=Files.Length(RefFile);
  Files.Set(ref, RefFile, 0); Files.Read(ref, ch); WHILE ~ref.eof DO ObjW(ch); Files.Read(ref, ch) END;
  Files.Set(ObjF, ObjFile, refpatch); ObjWBytes(refsize, 4);
  Files.Register(ObjFile)
 END CloseObj;

BEGIN
 pat := MinRealPat; SYSTEM.MOVE(SYSTEM.ADR(pat), SYSTEM.ADR(MinReal), 4); (*i386: -3.40282346E38*)
 pat := MaxRealPat; SYSTEM.MOVE(SYSTEM.ADR(pat), SYSTEM.ADR(MaxReal), 4); (*i386: 3.40282346E38*)
 LRealPat.L := MinLRealPatL; LRealPat.H := MinLRealPatH;
 SYSTEM.MOVE(SYSTEM.ADR(LRealPat), SYSTEM.ADR(MinLReal), 8); (*i386: -1.7976931348623157D308*)
 LRealPat.L := MaxLRealPatL; LRealPat.H := MaxLRealPatH;
 SYSTEM.MOVE(SYSTEM.ADR(LRealPat), SYSTEM.ADR(MaxLReal), 8); (*i386: 1.7976931348623157D308*)
 Texts.OpenWriter(W); Log := Oberon.Log;
 outputPath := ""; outputPrefix := ""; (* extension is initialized in Compiler *)
 first := TRUE
END OPM.
