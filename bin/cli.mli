(** Command-line parsing (port of the [getopt_long] block in [sdl-main.c], with
    the [--headless]/[--frames] additions from the Rust port). *)

(** Validated configuration handed to the frontend. *)
type config =
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

(** Parse a raw argument list (an argv tail) into a {!config}, or [Error msg] on
    bad usage. Prints usage and exits on [--help]/[-h]. Exposed for testing. *)
val parse_argv : string list -> (config, string) result

(** [parse_argv] of [Sys.argv]'s tail. *)
val parse : unit -> (config, string) result
