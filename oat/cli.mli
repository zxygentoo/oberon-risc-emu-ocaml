(** The oat command-line surface: argument parsing into a {!Data.request},
    response rendering, and the wiring from a parsed config through {!Io.send}
    into {!Tools.execute}. The process contract — exit codes, the "oat: error: "
    prefix — lives in the executable ([oat/bin/oat.ml]). *)

(** The serial connection, one form required (reported at open time, not parse
    time, so the error carries its context). *)
type serial =
  | Device of string (** [--serial]: existing PTY / serial device. *)
  | Fifos of
      { fifo_in : string (** FIFO the emulator reads (we write). *)
      ; fifo_out : string (** FIFO the emulator writes (we read). *)
      }

type config =
  { timeout : float (** Serial read timeout per request, seconds. *)
  ; baud : int (** Real serial device only; ignored for FIFO pairs. *)
  ; char_delay_us : int (** Real serial device only; ignored for FIFO pairs. *)
  ; retries : int (** Real serial device only; the FIFO path never retries. *)
  ; serial : serial option
  ; command : Data.request
    (** For [Write], parsed with [content = ""]; {!run} fills it from stdin. *)
  }

(** Outcome of CLI parsing; the caller owns printing and exiting. *)
type parsed =
  | Config of config
  | Help
  | Version
  | Invalid of string

(** Parse a raw argument list (the argv tail), so it is testable without
    [Sys.argv]. Options may precede or follow the subcommand; [--] ends option
    parsing. *)
val parse_argv : string list -> parsed

val usage : string

(** Print one response to stdout — the sole owner of oat's success output. For
    the log-carrying results ([Compiled], [Called]) the log is printed first,
    then any in-band failure is raised, so it lands above the error line.
    @raise Error.Error on such an in-band failure. *)
val render : Data.response -> unit

(** Open the device, fill a [Write] request from stdin, execute, render.
    @raise Error.Error on any tool- or transport-level failure. *)
val run : config -> unit
