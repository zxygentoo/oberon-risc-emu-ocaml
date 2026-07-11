(** The clipboard GET/PUT state machine bridging the host clipboard to Oberon
    (port of [sdl-clipboard.c]'s state machine).

    GET folds the host's CRLF/LF to Oberon's CR; PUT folds CR back to LF and
    re-encodes Oberon's Latin-1 bytes as UTF-8 for the host. The host clipboard is
    supplied as a {!host} record so the bridge stays independent of any GUI
    toolkit. *)

(** Abstraction over the host system clipboard. *)
type host =
  { get_text : unit -> string option
  ; set_text : string -> unit
  }

(** The host to wire when there is no clipboard: headless runs, tests, the bench. *)
val noop_host : host

(** The clipboard device exposed to the CPU over the {!Io.clipboard} MMIO ports. *)
type t

(** A fresh bridge over the given host clipboard. *)
val create : host -> t

(** The {!Io.clipboard} view of this bridge (closures over its mutable state). *)
val to_clipboard : t -> Io.clipboard
