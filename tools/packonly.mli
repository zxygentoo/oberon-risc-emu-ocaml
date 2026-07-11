(** The [.packonly] manifest: the files a source tree packs into the image verbatim rather
    than compiling. Everything not listed is compiled as Oberon source. Port of
    [host_tools::packonly]. *)

module StringSet : Set.S with type elt = string

(** [".packonly"]: the manifest's file name at the root of a source tree — the one home
    for the convention shared by the writer (extract-source) and the reader (the
    builders). *)
val file_name : string

(** Parse [.packonly] text into the set of pack-only names. One name per line; text from
    the first ['#'] onward, and surrounding blanks, are ignored. *)
val parse : string -> StringSet.t

(** Render a [.packonly] file: a fixed 3-line header, then the names sorted, one per line.
    [parse] ignores the header, so [parse (render s) = s]. *)
val render : StringSet.t -> string
