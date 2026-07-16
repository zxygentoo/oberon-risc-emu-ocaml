(** Serial transport over a PTY (raw mode) or a FIFO pair (port of oat's
    [transport.rs]).

    [Unix.select] provides the timed read-availability poll and [Unix.tcsetattr] the
    raw mode + line speed (the two syscalls Rust reached rustix for). The transport is
    the real {!Protocol.send}: it moves the bytes; the frame grammar itself lives
    in {!Protocol}. *)

type t

(** Open an existing PTY / serial device read-write and put it in raw 8N1 mode at
    [baud]. [char_delay] (seconds) paces every host->device byte out one at a time —
    required on a real UART, whose single-byte register a back-to-back frame overruns.
    @raise Error.Error ([Open_serial]) when the device cannot be opened or
    configured. *)
val open_path : string -> timeout:float -> baud:int -> char_delay:float -> t

(** Open a FIFO pair: [in_path] is the FIFO the emulator reads (we write), [out_path]
    the one it writes (we read). Both are opened read-write, which never blocks on a
    FIFO regardless of the peer. The FIFO path is lossless, so no char-delay applies.
    @raise Error.Error ([Open_fifo]) when a FIFO cannot be opened. *)
val open_fifos : in_path:string -> out_path:string -> timeout:float -> t

(** [send t frame] drains any stale bytes off the line, writes one REQUEST frame, and
    reads one RESPONSE ([send t] is this transport's {!Protocol.send}).
    @raise Error.Error on timeout, EOF, a bad sync byte, or an I/O error. *)
val send : t -> string -> Protocol.response

(** Direct construction over arbitrary fds — for tests that wire the transport to
    pipes. [writer = None] sends on [reader] (the PTY shape). *)
module For_tests : sig
  val make
    :  reader:Unix.file_descr
    -> writer:Unix.file_descr option
    -> timeout:float
    -> char_delay:float
    -> t
end
