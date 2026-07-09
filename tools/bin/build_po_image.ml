(** [build-po-image] — assemble a bootable Project Oberon 2013 disk image from a source
    tree. All the work is the shared {!Oberon_tools.Pipeline}; this binary supplies only
    the embedded PO2013 seed and the CLI. Port of the Rust [build-po-image] binary. *)

let () =
  Oberon_tools.Builder_cli.run
    Oberon_tools.Seed_po.seed
    ~name:"build-po-image"
    ~version:"0.1.0"
;;
