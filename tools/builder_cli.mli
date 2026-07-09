(** Shared CLI for the two image builders ([build-po-image]/[build-eo-image]): parse
    [<SOURCES_DIR> <OUTPUT>], run the pipeline with the given seed, and report [Done] or
    the error. *)

val run : Pipeline.seed -> name:string -> version:string -> unit
