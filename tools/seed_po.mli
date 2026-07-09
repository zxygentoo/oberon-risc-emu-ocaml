(** The embedded Project Oberon 2013 toolchain seed for [build-po-image]: shared host
    glue + PO-specific glue + the prebuilt bootstrap objects and inner core, vendored
    under [assets/] and embedded via ocaml-crunch. *)

val seed : Pipeline.seed
