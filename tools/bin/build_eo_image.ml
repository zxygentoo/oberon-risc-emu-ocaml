(** [build-eo-image] — assemble a bootable Extended Oberon disk image, the EO counterpart
    of [build-po-image] (same pipeline, EO seed). Port of the Rust [build-eo-image]
    binary. *)

let () = Oberon_tools.Tool_cli.run Oberon_tools.Seed.eo
