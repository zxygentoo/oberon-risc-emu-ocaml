(** Read-only reader for the Project Oberon on-disk filesystem (port of
    [host_tools::image]). Parses the directory B-tree and reconstructs file contents
    straight from the image bytes — no emulator, no boot. See [assets/common/VFileDir.Mod]
    for the format. *)

(** A file found in the directory: its name and the disk address of its header. *)
type entry =
  { name : string
  ; header : int
  }

(** An Oberon filesystem image held in memory, read only. *)
type t

(** Raised when the bytes aren't a valid Oberon filesystem image: a bad directory or
    header mark, an out-of-range disk address, an inconsistent length, or an implausibly
    deep directory tree. *)
exception Bad_image of string

(** Parse and validate raw image bytes. Probes a raw [.dsk] (filesystem at byte 0) and a
    full SD-card image (behind a fixed prefix); whichever puts the directory mark at
    sector 1 wins. *)
val from_bytes : string -> t

(** [open_image path] loads and validates the image file at [path]. *)
val open_image : string -> t

(** Every file in the directory, in name order. *)
val entries : t -> entry list

(** Reconstruct the full byte contents of the file whose header sector is at the given
    disk address ([entry.header]). *)
val read_file : t -> int -> string

(** Low-level helpers exposed only for the test suite. *)
module For_tests : sig
  val has_dir_mark : string -> int -> bool
  val read_name : string -> int -> string option
end
