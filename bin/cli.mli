(** Command-line parsing (port of the [getopt_long] block in [sdl-main.c], with
    the [--headless]/[--frames] additions from the Rust port). *)

(** Outcome of CLI parsing; the caller owns printing and exiting ([Help] means
    "print {!usage} and exit 0"). *)
type parsed =
  | Config of config
  | Help
  | Invalid of string

(** Validated configuration handed to the frontend. *)
and config =
  { width : int
  ; height : int
  ; mem : int
  ; configure : bool
  ; zoom : float
  ; fullscreen : bool
  ; leds : bool
  ; serial_in : string option
  ; serial_out : string option
  ; boot_from_serial : bool
  ; headless : bool
  ; frames : int option
  ; disk_image : string option
  }

(** The usage/help text ([--help]'s output). *)
val usage : string

(** [clamp lo hi v] (the [sdl-main.c] clamp, shared across the frontend). *)
val clamp : int -> int -> int -> int

(** Parse a raw argument list (an argv tail). Exposed for testing. *)
val parse_argv : string list -> parsed

(** [parse_argv] of [Sys.argv]'s tail. *)
val parse : unit -> parsed
