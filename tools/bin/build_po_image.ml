(** [build-po-image] — assemble a bootable Project Oberon 2013 disk image from a source
    tree. All the work is the shared {!Oberon_tools.Pipeline}; this binary supplies only
    the embedded PO2013 seed. Port of the Rust [build-po-image] binary. *)

let () = Oberon_tools.Tool_cli.run Oberon_tools.Seed.po
