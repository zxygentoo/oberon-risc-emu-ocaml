(** The wire codec and the exchange discipline: encode one typed REQUEST, move
    the bytes over a {!Device.t}, decode one RESPONSE — re-sending on a desync
    within the given retry budget.

    Host is master: one REQUEST out, one RESPONSE back. All multi-byte integers
    are unsigned little-endian; names carry a 1-byte length prefix, payloads a
    4-byte one. Constants and limits match [AgentProtocol.Mod]; a request past
    a limit is refused here, before any byte goes out. The raw encoding never leaves this module — the
    production surface is {!send} alone; the codec and retry internals are
    exposed only through {!For_tests}. *)

(** One full exchange: encode the request, drain stale bytes off the line, write
    the frame, decode the response — re-sending on a desync up to [retries]
    extra attempts (pass 0 for the lossless FIFO path). [send device ~retries]
    is the production {!Data.Wire.t}.

    Why re-sending works: a real UART desyncs a fraction of requests — the
    device's cooperative poll misses the request frame's first ([sync]) byte
    when an [Oberon.Loop] stall (GC, the other installed tasks) outlasts the
    inter-byte gap, so the frame is dropped and the host times out (or reads a
    misframed reply). The device self-recovers per frame — its bounded [Rec]
    clears [rxOk], the handler bails without committing or replying, and the
    next poll resyncs on a fresh [sync] — so simply re-sending the request
    succeeds. Only the desync signatures ([Timeout], [Bad_sync]) are retried —
    tool-level statuses never raise here, and genuine line failures ([Eof],
    [Io], open errors) are not transient, so they fail fast.

    A re-send is only as safe as the request, though. A desync drops a byte
    {i before} the device acts, but the same signatures also follow a device
    that {i did} act — a command slower than the timeout, a late reply, noise
    on the line — and then the request runs twice. So the caller passes a
    budget only for requests a second run can't change ({!Cli} decides per
    operation), and 0 for the rest.

    On a real serial line ({!Device.line}), a desync that outlives the budget is
    raised as [Serial_link] — the last [Timeout] / [Bad_sync] plus the line the
    host holds and the attempts made — since there it is a link to debug, not an
    emulator to restart.

    @raise Error.Error on timeout, EOF, a bad sync byte or response length, an
    I/O error, or (at encode time) a name outside 1..{!Data.Wire.name_limit}
    bytes or a payload over {!Data.Wire.put_limit}. *)
val send : Device.t -> retries:int -> Data.Wire.t

(** The codec and retry internals, exposed for the tests that pin frame bytes
    and the retry policy — production reaches them only through {!send} — plus
    the device's half of the codec, for peers that play the device over a real
    byte stream (that half is never used in production: oat neither parses
    requests nor encodes responses). *)
module For_tests : sig
  (** Encode a REQUEST frame.
      @raise Error.Error on a name or payload past its limit. *)
  val encode_request : Data.Wire.request -> string

  (** [read_response recv] decodes one RESPONSE frame; [recv buf] must fill all
      of [buf]. @raise Error.Error on a bad sync byte or a length over
      {!Data.Wire.response_limit} (and whatever [recv] raises). *)
  val read_response : (bytes -> unit) -> Data.Wire.response

  (** [with_retries ~retries f] re-runs [f] on a transport desync, up to
      [retries] extra attempts (so [retries + 1] total); [retries = 0] is a
      transparent pass-through. *)
  val with_retries : retries:int -> (unit -> 'a) -> 'a

  (** Parse a REQUEST frame. Raises on malformed input — test code. *)
  val parse_request : string -> Data.Wire.request

  (** Encode a RESPONSE frame exactly as the device would. *)
  val encode_response : Data.Wire.response -> string
end
