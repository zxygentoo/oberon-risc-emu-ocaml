(** oat's error vocabulary, message rendering, and exit-code mapping (port of oat's
    [error.rs]).

    Each case carries enough context for a useful one-line message with a hint where
    appropriate; {!message} renders that body and the binary adds the "oat: error: "
    prefix. {!exit_code} follows the contract documented in [--help] and SKILL.md:
    tool-level errors -> 1, transport / protocol / argument errors -> 2. *)

type t =
  | No_serial
  | Bad_name of
      { name : string
      ; len : int
      }
  | Open_fifo of
      { path : string
      ; err : Unix.error
      }
  | Open_serial of
      { path : string
      ; err : Unix.error
      }
  | Io of string
  | Timeout of
      { secs : float
      ; got : int
      ; want : int
      }
  | Eof
  | Bad_sync of
      { got : int
      ; expected : int
      }
  | Bad_status of int
  | File_not_found of string
  | Edit_not_found
  | Edit_not_unique of int
  | Load_failed of
      { res : int option
      ; log : string
      }
  | Unload_in_use of string
  | Compile_failed
  | Trapped

exception Error of t

(** Raise {!Error}. *)
val fail : t -> 'a

(** The documented process exit code: 1 for tool-level errors, 2 for transport /
    protocol / argument errors. *)
val exit_code : t -> int

(** The one-line (occasionally multi-line, hint- or log-carrying) message body. *)
val message : t -> string
