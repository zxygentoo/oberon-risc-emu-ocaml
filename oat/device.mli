(** The serial byte channel to the device — an open PTY (raw mode) or emulator
    FIFO pair — plus the per-channel policies the line's physics dictate:
    inter-byte pacing, stale-byte draining, the read timeout, and the retry
    budget {!Io.send} honors. Bytes only: the frame grammar lives in {!Io}.

    [Unix.select] provides the timed read-availability poll and [Unix.tcsetattr]
    the raw mode + line speed. *)

type t

(** Open an existing PTY / serial device read-write and put it in raw 8N1 mode at
    [baud]. [char_delay] (seconds) paces every host->device byte out one at a
    time — required on a real UART, whose single-byte register a back-to-back
    frame overruns. [retries] is the re-send budget for a desynced request — the
    real-serial path is lossy (see {!Io.with_retries}).
    @raise Error.Error ([Open_serial]) when the device cannot be opened or
    configured. *)
val open_device
  :  string
  -> timeout:float
  -> baud:int
  -> char_delay:float
  -> retries:int
  -> t

(** Open a FIFO pair: [in_path] is the FIFO the emulator reads (we write),
    [out_path] the one it writes (we read). Both are opened read-write, which
    never blocks on a FIFO regardless of the peer. The FIFO path is lossless and
    back-pressured, so no char-delay applies and the retry budget is 0 — a
    timeout there is a genuine hang, reported as such rather than waited out N
    more times.
    @raise Error.Error ([Open_fifo]) when a FIFO cannot be opened. *)
val open_fifos : in_path:string -> out_path:string -> timeout:float -> t

(** The re-send budget carried by the channel (0 for FIFO pairs). *)
val retries : t -> int

(** Read and discard whatever is already buffered, so a stale or partial response
    from a prior exchange can't desync the next one. Best effort — errors just
    stop the drain. *)
val drain_stale : t -> unit

(** Write one frame, pacing bytes [char_delay] apart when nonzero. The channel
    does not inspect the bytes.
    @raise Error.Error ([Io]) on a write error. *)
val write_frame : t -> string -> unit

(** Fill all of [buf], polling up to the channel timeout for each chunk.
    @raise Error.Error ([Timeout], [Eof], or [Io]). *)
val recv_exact : t -> bytes -> unit

(** Direct construction over arbitrary fds — for tests that wire the channel to
    pipes. [writer = None] sends on [reader] (the PTY shape). *)
module For_tests : sig
  val make
    :  reader:Unix.file_descr
    -> writer:Unix.file_descr option
    -> timeout:float
    -> char_delay:float
    -> retries:int
    -> t
end
