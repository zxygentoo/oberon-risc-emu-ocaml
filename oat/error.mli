(** oat's error vocabulary, message rendering, and exit-code mapping.

    Each case carries enough context for a useful one-line message with a hint where
    appropriate; {!message} renders that body and the binary adds the "oat: error: "
    prefix. {!exit_code} follows the contract documented in [--help] and SKILL.md:
    tool-level errors -> 1, transport / protocol / argument errors -> 2. *)

type t =
  | No_serial
  | Bad_name of string (** A wire name whose length is outside 1..255 bytes. *)
  | Put_too_large of
      { bytes : int
      ; limit : int (** {!Data.Wire.put_limit}, the device's PUT buffer size. *)
      }
  | Open_fifo of
      { path : string
      ; err : Unix.error
      }
  | Open_serial of
      { path : string
      ; err : Unix.error (** From opening the device or from setting up its line. *)
      }
  | Unsupported_baud of
      { baud : int
      ; supported : int list (** {!Device.supported_bauds}, ascending. *)
      }
  | Line_mismatch of
      { path : string
      ; baud : int (** The rate asked for. *)
      ; in_baud : int
      ; out_baud : int
        (** What the line holds after setup; negative when the platform cannot
            name the speed. *)
      ; raw : bool (** Whether the raw 8N1 mode took. *)
      } (** The driver accepted the line settings but the read-back differs. *)
  | Serial_link of
      { path : string
      ; baud : int (** Set and read back on [path] before the exchange. *)
      ; attempts : int
      ; cause : t (** The last attempt's [Timeout] or [Bad_sync]. *)
      }
  (** A real serial line that is set up correctly on the host and still got no
      usable response — what a device-side mismatch looks like from here. *)
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

(** A device log rendered for display under a message or status line: trimmed,
    then each line prefixed with a newline and two spaces; [""] when the log
    trims to nothing. *)
val indented_log : string -> string
