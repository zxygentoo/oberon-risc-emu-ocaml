(** The embedded toolchain seeds (mirrors the TOOLCHAIN tables of build-po-image.rs /
    build-eo-image.rs): one authoritative table, instantiated per variant from the
    crunched assets. *)

(** The Project Oberon 2013 seed ([build-po-image]). *)
val po : Pipeline.seed

(** The Extended Oberon seed ([build-eo-image]). *)
val eo : Pipeline.seed
