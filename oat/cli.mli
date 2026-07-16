(** The oat command-line surface (port of oat's [cli.rs] + [main.rs]): argument
    parsing, the per-subcommand handlers, and the dispatch from parsed arguments into
    {!Tools} calls. *)

(** The serial connection, one form required (reported at open time, not parse time,
    matching the Rust CLI). *)
type serial =
  | Device of string (** [--serial]: existing PTY / serial device. *)
  | Fifos of
      { fifo_in : string (** FIFO the emulator reads (we write). *)
      ; fifo_out : string (** FIFO the emulator writes (we read). *)
      }

type command =
  | Check
  | Read of string
  | Write of string
  | Edit of
      { path : string
      ; old : string
      ; new_ : string
      }
  | Delete of string
  | List_files of string (** Name prefix; "" lists all files. *)
  | List_modules
  | Compile of
      { name : string
      ; new_symbol : bool
      }
  | Load of string
  | Unload of string
  | Call of
      { cmd : string
      ; args : string (** Parameter text scanned via Oberon.Par; "" for none. *)
      }

type config =
  { timeout : float (** Serial read timeout per request, seconds. *)
  ; baud : int (** Real serial device only; ignored for FIFO pairs. *)
  ; char_delay_us : int (** Real serial device only; ignored for FIFO pairs. *)
  ; retries : int (** Real serial device only; the FIFO path never retries. *)
  ; serial : serial option
  ; command : command
  }

(** Outcome of CLI parsing; the caller owns printing and exiting. *)
type parsed =
  | Config of config
  | Help
  | Version
  | Invalid of string

(** Parse a raw argument list (the argv tail), so it is testable without [Sys.argv].
    Options may precede or follow the subcommand; [--] ends option parsing. *)
val parse_argv : string list -> parsed

val usage : string

(** Open the transport, wrap it in the retry policy, run the subcommand.
    @raise Error.Error on any tool- or transport-level failure. *)
val run : config -> unit

(** The whole main: parse [Sys.argv], run, report errors with the "oat: error: "
    prefix, and exit with the documented code (0 / 1 / 2). *)
val main : unit -> unit
