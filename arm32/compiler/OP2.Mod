(* minimized, stand-alone compiler driver, independent of Oberon System *)

MODULE OP2;
 IMPORT
  OPP, OPB, OPV, OPT, OPS, OPC, OPL, OPO, OPM, OPTR, Out, Texts, Oberon;
 
 CONST
  NoBreakPC = -1;
  
  module = OPS.module; ident = OPS.ident; period = OPS.period; (* symbols *)
   
 PROCEDURE SignOn;
 BEGIN
  Out.String("Oberon Portable Compiler / nw, rc, nm, tk, prk / "); 
  Out.String(OPTR.Target); Out.String(" target"); Out.Ln; 
  Out.String("C99 version and ARMv7 backend by me@rochus-keller.ch"); Out.Ln;
 END SignOn;
 
 PROCEDURE ParseOptions(VAR name, options, path, pref, extension: ARRAY OF CHAR;  VAR codeOpt, parserOpt: SET);
 VAR i, j, k: LONGINT;  ch: CHAR;
 BEGIN
  codeOpt := OPM.DefaultCodeOpt; parserOpt := OPM.DefaultParserOpt;
  i := 0; path[0] := 0X; pref[0] := 0X;
  COPY(".Mod", extension);
  LOOP
   ch := options[i]; INC(i);
   IF ch = 0X THEN EXIT
   ELSIF ch = "x" THEN codeOpt := codeOpt / {OPM.inxchk}
   ELSIF ch = "v" THEN codeOpt := codeOpt / {OPM.ovflchk}
   ELSIF ch = "t" THEN codeOpt := codeOpt / {OPM.typchk}
   ELSIF ch = "p" THEN codeOpt := codeOpt / {OPM.ptrinit}
   ELSIF ch = "a" THEN codeOpt := codeOpt / {OPM.assert}
   ELSIF ch = "z" THEN codeOpt := codeOpt / {OPM.fullstackinit}
   ELSIF ch = "q" THEN codeOpt := codeOpt / {OPM.trace}

   ELSIF ch = "s" THEN parserOpt := parserOpt / {OPM.newsf}
   ELSIF ch = "S" THEN parserOpt := parserOpt / {OPM.systemchk}
   ELSIF ch = "n" THEN parserOpt := parserOpt / {OPM.nofiles}
   ELSIF ch = "e" THEN parserOpt := parserOpt / {OPM.extsf}
   ELSIF ch = "f" THEN parserOpt := parserOpt / {OPM.findpc}
   ELSIF ch = "w" THEN parserOpt := parserOpt / {OPM.warning}
   ELSIF ch = "X" THEN parserOpt := parserOpt + {OPM.prefix}
   ELSIF ch = "2" THEN parserOpt := parserOpt / {OPM.oberon2}
   ELSIF ch = "1" THEN parserOpt := parserOpt / {OPM.oberon1}
   ELSIF ch = "T" THEN parserOpt := parserOpt / {OPM.traceprocs} (* temp *)
   ELSIF ch = "." THEN
    j := 0;
    WHILE (ch # 0X) & (ch # " ") DO
     extension[j] := ch; ch := options[i];
     INC(j); INC(i)
    END;
    extension[j] := 0X
   ELSIF ch = "P" THEN
    ch := options[i];  INC(i);
    k := 0;
    WHILE (ch # 0X) & (ch # " ") DO
     path[k] := ch;  INC(k);
     ch := options[i];  INC(i)
    END;
    path[k] := 0X
   ELSIF ch = "O" THEN (* mutually exclusive with "X" *)
    ch := options[i];  INC(i);
    k := 0;
    WHILE (ch # 0X) & (ch # " ") DO
     pref[k] := ch;  INC(k);
     ch := options[i];  INC(i)
    END;
    pref[k] := 0X
   END
  END;
  IF OPM.prefix IN parserOpt THEN
   i := -1; REPEAT INC(i); pref[i] := name[i] UNTIL (name[i] = 0X) OR (name[i] = ".");
   IF name[i] # "." THEN i := 0 ELSE INC(i) END;
   pref[i] := 0X
  END
 END ParseOptions;
 
 PROCEDURE WriteMsg(source: Texts.Reader);
 VAR sym: SHORTINT;
 BEGIN
  Out.String(" compiling ");
  OPM.Init({}, {}, source, Oberon.Log); OPS.Get(sym);
  IF sym = module THEN
   OPS.Get(sym);
   IF sym = ident THEN
    Out.String(OPM.outputPath);
    Out.String(OPM.outputPrefix);
    OPS.Get(sym); Out.String(OPS.name);
    WHILE sym = period DO
     Out.String(".");
     OPS.Get(sym);
     IF sym = ident THEN Out.String(OPS.name); OPS.Get(sym) END;
    END;
    Out.String(OPM.extension)
   END
  END;
 END WriteMsg;
 
 PROCEDURE Module(source: Texts.Reader; name, options: ARRAY OF CHAR; breakpc: LONGINT; VAR error: BOOLEAN);
  VAR codeOpt, parserOpt: SET; extSF, newSF: BOOLEAN; p: OPT.Node; modName: OPS.Name;
 BEGIN
  ParseOptions(name, options, OPM.outputPath, OPM.outputPrefix, OPM.extension, codeOpt, parserOpt);
  WriteMsg(source);
  OPM.Init(codeOpt, parserOpt, source, Oberon.Log); OPS.ch := " ";
  OPB.typSize := OPV.TypSize; OPV.Init(breakpc);
  newSF := OPM.newsf IN parserOpt; extSF := OPM.extsf IN parserOpt;
  OPP.Module(p, modName);
  IF OPM.noerr THEN
   OPL.Init;
   OPM.errpos := 0;
   OPM.Begin(modName);
   IF OPM.noerr THEN
    OPT.Export(modName, newSF, extSF);
    OPV.AdrAndSize(OPT.topScope);
    IF newSF THEN OPM.LogWStr(" new symbol file")
    ELSIF extSF THEN OPM.LogWStr(" extended symbol file")
    END;
    IF OPM.noerr THEN
     OPM.errpos := 0;
     OPC.Init;
     OPV.Module(p);
     IF OPM.noerr THEN
      OPL.OutCode(modName);
      IF OPM.noerr THEN
       OPM.LogWStr ("   "); OPM.LogWNum(OPO.pc, 1)
      END
     END
    END;
    OPL.Close
   END
  END;
  OPT.CloseScope; OPT.Close;
  OPM.LogWLn; error := ~OPM.noerr;
  OPM.outputPath := "!"; OPM.outputPrefix := "!" (* invalid filename *)
 END Module;

 PROCEDURE CompileFile*(name, opt: ARRAY OF CHAR; VAR error: BOOLEAN);
  VAR r: Texts.Reader; pc: LONGINT;
 BEGIN
  IF Texts.OpenReader(r, name) THEN
   Out.String(name);
   OPS.Init;
   Module(r, name, opt, pc, error)
  ELSE
   Out.String(name); Out.String(" not found");
   Out.Ln; 
   error := TRUE
  END
 END CompileFile;
 
BEGIN
 SignOn
END OP2.
