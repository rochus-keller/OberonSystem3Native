(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE VNCViewerDocs; (** Jörg Kreienbühl   *)
(** based on TeXViewerDocs.Mod (based on DocumentSkeleton.Mod) *)

 IMPORT Objects, Display, Documents, Gadgets, BasicGadgets, Desktops, Panels, 
    NamePlates, Attributes, Links, VNC, VNCViewers;
 
 CONST
  NamePlateW = 110;
  MenuButtonW = 39;
  menuColor = 13;
 VAR 
  ResizeFlag: BOOLEAN;   (* Is set TRUE when a Display.ModifyMsg is received *)
 
 (* From TeXViewerDocs: Produces the menu *)
 PROCEDURE GenMenu(desktop: BOOLEAN): Objects.Object;
  VAR root: Objects.Object;  p, f: Gadgets.Frame;  x: INTEGER;  cm: Display.ConsumeMsg;
  
  PROCEDURE Button(caption, command: ARRAY OF CHAR);
  BEGIN
   BasicGadgets.NewButton;  f := Objects.NewObj(Gadgets.Frame);
   f.X := x;  f.Y := 1;  f.H := Desktops.menuH - 2;  f.W := MenuButtonW;
   INC(x, f.W);  f.slink := root;  root := f;
   Attributes.SetString(f, "Caption", caption);
   Attributes.SetString(f, "Cmd", command)
  END Button;
   
 BEGIN
  x := 0;  root := NIL;
   (* panel *)
  Panels.NewPanel;  p := Objects.NewObj(Gadgets.Frame);
  p.W := Display.Width;  p.H := Desktops.menuH;
   (* nameplate *)
  NamePlates.NewNamePlate;  f := Objects.NewObj(Gadgets.Frame);
  f.X := x;  f.Y := 0;  f.H := Desktops.menuH;  f.W := NamePlateW;
  INC(x, f.W);  f.slink := root;  root := f;
   (* standard buttons *)
  Button("Close", "VNCViewerDocs.CloseDoc");
  Button("Hide", "Finder.Minimize");
  IF ~desktop THEN Button("Grow", "VNCViewerDocs.Grow") END;
  Button("Copy", "VNCViewerDocs.Copy");
   (* add components to panel *)
  cm.id := Display.drop;  cm.x := 0;  cm.y := 0;  cm.obj := root;  cm.F := p;
  cm.u := 0;  cm.v := -p.H + 1;  cm.res := -1;  cm.dlink := NIL;
  p.handle(p, cm);
   (* set panel attributes *)
  Attributes.SetBool(p, "Locked", TRUE);
  Attributes.SetInt(p, "Color", menuColor);
  Attributes.SetInt(p, "Border", 0);
  RETURN p
 END GenMenu; 
 
  
 PROCEDURE Load(D: Documents.Document);
 VAR canvas, view: Objects.Object;
 BEGIN
  VNC.Open(D.name);  
  IF Objects.NewObj = NIL THEN RETURN END;
  canvas := Objects.NewObj;
  Attributes.SetString(canvas, "Name", "Canvas");
  view := Gadgets.CreateObject("ScrollView");
  Attributes.SetBool(view, "Locked", TRUE);
  Links.SetLink(view, "Model", canvas);
  Documents.Init(D, view(Gadgets.Frame))
 END Load;
 
 PROCEDURE Store(D: Documents.Document);
 BEGIN
  (* storing not possible *)
 END Store;
 
 (** MenuItem "Close" *)
 PROCEDURE CloseDoc*;
  VAR f: Objects.Object;
 BEGIN
  f := Gadgets.FindObj(Desktops.CurDoc(Gadgets.context), "Canvas");
  VNCViewers.CloseRef(f(VNCViewers.Frame));
  Desktops.CloseDoc
 END CloseDoc;
 
 (** MenuItem "Grow" *)
 PROCEDURE Grow*;
  VAR f: Objects.Object;
 BEGIN
  ResizeFlag := FALSE;
  Desktops.Grow;
  IF ResizeFlag = TRUE THEN (* Hack: see wether Frow was successful by chatching the ModifyMsg in the Handler *)
   f := Gadgets.FindObj(Desktops.CurDoc(Gadgets.context), "Canvas");
   VNCViewers.NewRef(f(VNCViewers.Frame))
  END
 END Grow;

 (** MenuItem "Copy" *)
 PROCEDURE Copy*;
  VAR f: Objects.Object;
 BEGIN
  f := Gadgets.FindObj(Desktops.CurDoc(Gadgets.context), "Canvas");
  VNCViewers.NewRef(f(VNCViewers.Frame));
  Desktops.Copy
 END Copy;

 PROCEDURE Handler (D: Objects.Object; VAR M: Objects.ObjMsg);
 BEGIN
  WITH D: Documents.Document DO
   IF M IS Objects.AttrMsg THEN
    WITH M: Objects.AttrMsg DO
     IF M.id = Objects.get THEN
      IF M.name = "Gen" THEN
       M.class := Objects.String; M.s := "VNCViewerDocs.NewDoc"; M.res := 0
      ELSIF M.name = "Adaptive" THEN
       M.class := Objects.Bool; M.b := TRUE; M.res := 0
      ELSIF M.name = "Icon" THEN
       M.class := Objects.String; M.s := "Icons.Tool"; M.res := 0
      ELSE Documents.Handler(D, M)
      END
     ELSE Documents.Handler(D, M)
     END
    END
   ELSIF M IS Display.DisplayMsg THEN
    WITH M: Display.DisplayMsg DO
     IF (M.device = Display.printer) & (M.id = Display.contents) & (D.dsc # NIL) THEN
      (* print *)
     ELSE Documents.Handler(D, M)
     END
    END
   ELSIF M IS Objects.LinkMsg THEN
    WITH M: Objects.LinkMsg DO
     IF (M.id = Objects.get) & 
      ((M.name = "DeskMenu") OR (M.name = "SystemMenu") OR (M.name = "UserMenu")) THEN
      M.obj := GenMenu(M.name = "DeskMenu");
      M.res := 0
     ELSE Documents.Handler(D, M)
     END
    END
   ELSIF M IS Display.ModifyMsg THEN
    ResizeFlag := TRUE; Documents.Handler(D, M)
   ELSE Documents.Handler(D, M)
   END
  END
 END Handler;
 
 (** Generator *)
 PROCEDURE NewDoc*;
 VAR D: Documents.Document;
 BEGIN
  NEW(D); D.Load := Load; D.Store := Store; D.handle := Handler;
  D.W := Display.Width DIV 8 * 5; D.H := 200; Objects.NewObj := D
 END NewDoc;

END VNCViewerDocs.
