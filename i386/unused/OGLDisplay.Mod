(* ETH Oberon, Copyright 1990-2003 Computer Systems Institute, ETH Zurich, CH-8092 Zurich.
Refer to the license.txt file provided with this distribution. *)

MODULE OGLDisplay; (** AUTHOR "fkuhn"; PURPOSE "Oberon Graphics Library display base"; *)

TYPE
 State* = POINTER TO StateDesc;
 StateDesc* = RECORD
  activate*: PROCEDURE(state, oldState: State);
  deactivate*: PROCEDURE(state, newState: State)
 END;

VAR
 cardBase, linBase: LONGINT;
 cardSet, linSet: BOOLEAN;
 currentState* : State;

(** 
 sets the address of the Graphic Registers
 this has to be done exactly once by the Display module
 **)
 PROCEDURE SetCardBase*(adr: LONGINT);
 BEGIN
  cardBase := adr; cardSet := TRUE
 END SetCardBase;
 
(** 
 sets the address of the framebuffer:
 this has to be done exactly once by the Display module
 **)
 PROCEDURE SetLinearBase*(adr: LONGINT);
 BEGIN
  linBase := adr; linSet := TRUE
 END SetLinearBase;
 
(** returns the address of the Graphic Card Registers **) 
PROCEDURE CardBase*(): LONGINT;
BEGIN
 IF cardSet THEN
  RETURN cardBase
 ELSE 
  HALT(1000)
 END
END CardBase;

(** returns the address of the framebuffer **)
PROCEDURE LinearBase*(): LONGINT;
BEGIN
 IF linSet THEN
  RETURN linBase
 ELSE 
  HALT(1000)
 END
END LinearBase;

(** a default for the activate method of state, does nothing **)
PROCEDURE ActivateState*(state, oldState: State);
BEGIN
END ActivateState;

(** a default for the deactivate method of state, does nothing **)
PROCEDURE DeactivateState*(state, newState: State);
BEGIN
END DeactivateState;

(** ensures that the given state is active **)
PROCEDURE SwitchState*(state: State);
VAR
 current: State;
BEGIN
 current := currentState; currentState := state;
 current.deactivate(current, state);
 state.activate(state, current)
END SwitchState;

(*
(** ensures that the given state is active **)
PROCEDURE SwitchState*(state: State);
BEGIN
 currentState.deactivate(currentState, state);
 state.activate(state, currentState)
END SwitchState;
*)

BEGIN
 cardSet := FALSE; linSet := FALSE;
 NEW(currentState);
 currentState.activate := ActivateState; currentState.deactivate := DeactivateState
END OGLDisplay.
 