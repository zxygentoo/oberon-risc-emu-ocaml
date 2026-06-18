(** The SDL-backed host clipboard, bridging the OS clipboard to the core's
    {!Risc_core.Clipboard} state machine. *)

(** A {!Risc_core.Clipboard.host} backed by SDL's clipboard. *)
val host : Risc_core.Clipboard.host
