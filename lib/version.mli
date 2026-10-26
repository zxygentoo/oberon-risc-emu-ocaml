(** The release this code belongs to. Every executable reports it with [--version]; a
    vendored copy can read it to check which release it holds. *)

(** ["X.Y.Z"] for a release; ["X.Y.Z~dev"] between releases, ahead of the next one. *)
val version : string
