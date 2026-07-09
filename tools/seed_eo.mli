(** The embedded Extended Oberon toolchain seed for [build-eo-image]: shared host glue +
    EO-specific glue + the prebuilt bootstrap objects and [Modules]-topped inner core,
    vendored under [assets/] and embedded via ocaml-crunch. *)

val seed : Pipeline.seed
