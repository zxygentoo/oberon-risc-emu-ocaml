(** Extract a build-ready source tree from a Project Oberon disk image — the core of
    [extract-source] (port of the Rust binary's logic): every file except the compiled
    artifacts ([.rsc]/[.smb], kept with [keep_objects]), plus a regenerated [.packonly]
    manifest, so the tree builds as-is. *)

(** Per-run tallies for the extractor's closing report; [packonly] doubles as the
    manifest content. *)
type stats =
  { packonly : Packonly.StringSet.t (** the pack-only names written to [.packonly] *)
  ; extracted : int (** files written *)
  ; skipped : int (** compiled artifacts skipped (without [keep_objects]) *)
  ; objects : int (** compiled artifacts written (with [keep_objects]) *)
  }

(** [extract_tree img ~output ~keep_objects] writes the source tree into [output]
    (created if missing) and regenerates its [.packonly]. A file that fails to
    reconstruct is skipped with a warning on stderr. *)
val extract_tree : Image.t -> output:string -> keep_objects:bool -> stats
