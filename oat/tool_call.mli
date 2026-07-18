(** The typed oat operations on the Oberon device — the semantics layer.

    {!execute} is the whole surface: it dispatches one operation-level request
    into wire round-trips over the {!Data.Wire.t} seam (one per operation; two
    for the oversized-edit fallback, plus the round-trip timing for [Check]) and
    returns the typed response. Tests plug an in-memory fake device into the
    seam. Errors raise {!Error.Error}; the log-carrying results ([Compiled],
    [Called]) report failure in-band so {!Cli.render} can print the log before
    failing. *)

val execute : Data.Wire.t -> Data.request -> Data.response
