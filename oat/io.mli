(** The wire codec and the exchange discipline: encode one typed REQUEST, move
    the bytes over a {!Device.t}, decode one RESPONSE — re-sending on a desync
    within the device's retry budget.

    Host is master: one REQUEST out, one RESPONSE back. All multi-byte integers
    are unsigned little-endian; names carry a 1-byte length prefix. Constants
    match [AgentProtocol.Mod]. The raw encoding never leaves this module:
    production code only encodes requests and decodes responses; test fakes that
    play the device go through {!For_tests}. *)

(** Encode a REQUEST frame.
    @raise Error.Error on a name outside 1..255 bytes. *)
val encode_request : Data.Wire.request -> string

(** [read_response recv] decodes one RESPONSE frame; [recv buf] must fill all of
    [buf]. @raise Error.Error on a bad sync byte (and whatever [recv] raises). *)
val read_response : (bytes -> unit) -> Data.Wire.response

(** [with_retries ~retries f] re-runs [f] on a transport desync, up to [retries]
    extra attempts (so [retries + 1] total); [retries = 0] is a transparent
    pass-through.

    A real UART desyncs a fraction of requests: the device's cooperative poll
    misses the request frame's first ([sync]) byte when an [Oberon.Loop] stall —
    GC, the other installed tasks — outlasts the inter-byte gap, so the frame is
    dropped and the host times out (or reads a misframed reply). The device
    self-recovers per frame — its bounded [Rec] clears [rxOk], the handler bails
    without committing or replying, and the next poll resyncs on a fresh [sync] —
    so simply re-sending the request succeeds.

    Re-sending is safe for every opcode because the lossy direction is device RX
    only: a desync drops a byte {i before} the device acts, so nothing was
    committed. Only the transport desync signatures ([Timeout], [Bad_sync]) are
    retried — tool-level statuses never raise here, and genuine line failures
    ([Eof], [Io], open errors) are not transient, so they fail fast. *)
val with_retries : retries:int -> (unit -> 'a) -> 'a

(** One full exchange: encode the request, drain stale bytes off the line, write
    the frame, decode the response — re-sent on a desync up to [retries] extra
    attempts ({!with_retries}; pass 0 for the lossless FIFO path).
    [send device ~retries] is the production {!Data.Wire.t}.
    @raise Error.Error on timeout, EOF, a bad sync byte, or an I/O error. *)
val send : Device.t -> retries:int -> Data.Wire.t

(** The device's half of the codec — for peers that play the device over a real
    byte stream and for tests inverting the production codec — {b not} used in
    production (oat never parses requests or encodes responses). *)
module For_tests : sig
  (** Parse a REQUEST frame. Raises on malformed input — test code. *)
  val parse_request : string -> Data.Wire.request

  (** Encode a RESPONSE frame exactly as the device would. *)
  val encode_response : Data.Wire.response -> string
end
