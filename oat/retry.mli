(** Retry decorator for the {!Protocol.send} seam (port of oat's [retry.rs]).

    A real UART desyncs a fraction of requests: the device's cooperative poll misses
    the request frame's first ([sync]) byte when an [Oberon.Loop] stall — GC, the
    other installed tasks — outlasts the inter-byte gap, so the frame is dropped and
    the host times out (or reads a misframed reply). The device self-recovers per
    frame — its bounded [Rec] clears [rxOk], the handler bails without committing or
    replying, and the next poll resyncs on a fresh [sync] — so simply re-sending the
    request succeeds.

    Re-sending is safe for every opcode because the lossy direction is device RX only:
    a desync drops a byte {i before} the device acts, so nothing was committed. Only
    the transport desync signatures ([Timeout], [Bad_sync]) are retried — tool-level
    statuses never raise here, and genuine line failures ([Eof], [Io], open errors)
    are not transient, so they fail fast. *)

(** [wrap ~retries send] re-sends on a transport desync up to [retries] extra attempts
    (so [retries + 1] total). [retries = 0] is a transparent pass-through — used for
    the lossless FIFO/emulator path. *)
val wrap : retries:int -> Protocol.send -> Protocol.send
