(** The SPI SD-card state machine (port of [disk.c]).

    Models single-block read (CMD17 / 81) and write (CMD24 / 88) of the SD command
    protocol, driven byte-by-byte through the {!Io.spi} interface. *)

(** An SD card attached to the SPI bus: a [.dsk] host file, an image in memory, or
    none. *)
type t

(** Open a disk image (read+write: the guest's writes go to the file, as on the
    board), or build a diskless card with [None] (for [--boot-from-serial]). A
    filesystem-only image (first word [0x9B1EA38D]) is detected and its sector
    numbers rebased. Port of [disk_new].
    @raise Unix.Unix_error if the image cannot be opened. *)
val create : string option -> t

(** A card holding [image] in memory: it reads as the image, and the guest's writes
    stay in memory (see {!contents}) — for a boot that must leave the image as it was
    (a golden, a lockstep run, a bench) without copying it to a temp file first.
    Rebased like {!create}. Writes are kept per 512-byte block, so a write to a far
    block costs one block. *)
val of_string : string -> t

(** The image of a card made by {!of_string}, with every write applied — longer than
    the original if the guest wrote past its end (as a file-backed card's file grows).
    @raise Invalid_argument for a file-backed or diskless card. *)
val contents : t -> string

(** The {!Io.spi} view of this disk (closures over its mutable state). *)
val to_spi : t -> Io.spi

(** Release the host file. Idempotent; from then on the card behaves as diskless
    (reads return zeros, writes are dropped), so a machine still holding it keeps
    running. Without it the file stays open until the process exits. *)
val close : t -> unit

(** Test-only access. *)
module For_tests : sig
  (** The sector rebasing offset (0, or [0x80002] for a filesystem-only image). *)
  val offset : t -> int
end
