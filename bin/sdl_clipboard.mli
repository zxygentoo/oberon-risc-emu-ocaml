(** The SDL-backed host clipboard, bridging the OS clipboard to the core's
    {!Oberon_risc.Clipboard} state machine. *)

(** A {!Oberon_risc.Clipboard.host} backed by SDL's clipboard. *)
val host : Oberon_risc.Clipboard.host
