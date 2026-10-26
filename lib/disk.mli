(** The SPI SD-card state machine (port of [disk.c]).

    Models single-block read (CMD17 / 81) and write (CMD24 / 88) of the SD command
    protocol, driven byte-by-byte through the {!Io.spi} interface. *)

(** An SD card attached to the SPI bus, backed by a [.dsk] host file. *)
type t

(** Open a disk image (read+write), or build a diskless card with [None] (for
    [--boot-from-serial]). A filesystem-only image (first word [0x9B1EA38D]) is
    detected and its sector numbers rebased. Port of [disk_new].
    @raise Unix.Unix_error if the image cannot be opened. *)
val create : string option -> t

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
