(** The serial byte channel to the device — an open PTY / serial device (raw
    mode) or emulator FIFO pair — plus the per-channel accommodations the line's
    physics dictate: inter-byte pacing, stale-byte draining, and the read
    timeout. Bytes only: the frame grammar lives in {!Io}.

    [Unix.select] provides the timed read-availability poll. The line setup is
    oat's own C stub ([serial_stubs.c]), compiled with the project, because the
    [Unix] library's baud table is frozen into the switch's static archive and
    goes stale across a glibc upgrade. *)

type t

(** A real serial line: the device path and the baud rate it was set to. *)
type line =
  { path : string
  ; baud : int
  }

(** The baud rates {!open_device} accepts on this platform, ascending — the
    standard rates the C library names. *)
val supported_bauds : int list

(** Open an existing PTY / serial device read-write and take over its line: raw
    8N1 at [baud], no flow control, modem-control lines ignored — every setting
    is set, none inherited — then read the settings back and compare, so a line
    that did not take them fails here and not as a timeout later. [char_delay]
    (seconds) paces every host->device byte out one at a time — required on a
    real UART, whose single-byte register a back-to-back frame overruns.
    @raise Error.Error
      [Unsupported_baud] (before anything is opened) for a [baud] outside
      {!supported_bauds}; [Open_serial] when the device cannot be opened or is
      not a terminal; [Line_mismatch] when the read-back differs. *)
val open_device : string -> timeout:float -> baud:int -> char_delay:float -> t

(** Open a FIFO pair: [in_path] is the FIFO the emulator reads (we write),
    [out_path] the one it writes (we read). Both are opened read-write, which
    never blocks on a FIFO regardless of the peer. The FIFO path is lossless and
    back-pressured, so no char-delay applies — and a timeout on it is a genuine
    hang, which is why {!Cli} gives {!Io.send} a zero retry budget for it.
    @raise Error.Error ([Open_fifo]) when a FIFO cannot be opened. *)
val open_fifos : in_path:string -> out_path:string -> timeout:float -> t

(** The line {!open_device} set up and verified; [None] for a FIFO pair. *)
val line : t -> line option

(** Read and discard whatever is already buffered, so a stale or partial response
    from a prior exchange can't desync the next one. Best effort — errors just
    stop the drain. *)
val drain : t -> unit

(** Write one frame, pacing bytes [char_delay] apart when nonzero. The channel
    does not inspect the bytes.
    @raise Error.Error ([Io]) on a write error. *)
val send : t -> string -> unit

(** Fill all of [buf], polling up to the channel timeout for each chunk.
    @raise Error.Error ([Timeout], [Eof], or [Io]). *)
val recv : t -> bytes -> unit

(** Direct construction over arbitrary fds — for tests that wire the channel to
    pipes. [writer = None] sends on [reader] (the PTY shape). The rest are the
    pieces of {!open_device}, for tests that drive them on a pseudo-terminal. *)
module For_tests : sig
  val make
    :  reader:Unix.file_descr
    -> writer:Unix.file_descr option
    -> timeout:float
    -> char_delay:float
    -> t

  (** The same channel, presented as a real serial line. *)
  val as_serial : t -> line -> t

  (** Put a terminal in raw 8N1 at a supported baud.
      @raise Unix.Unix_error when the fd is not a terminal. *)
  val configure : Unix.file_descr -> int -> unit

  (** What a terminal holds now: input baud, output baud (0 for "hang up" /
      "same as output", negative when unnameable), and whether its mode is the
      raw 8N1 {!configure} sets. *)
  val read_back : Unix.file_descr -> int * int * bool

  (** Compare {!read_back} against the line asked for.
      @raise Error.Error ([Line_mismatch]) when they differ. *)
  val verify : Unix.file_descr -> line -> unit
end
