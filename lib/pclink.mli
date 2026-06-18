(** PCLink file transfer over the serial line (port of [pclink.c]).

    Watches for two job files: [PCLink.REC] names a host file to send to Oberon,
    and [PCLink.SND] names a host file to receive from Oberon. It then drives the
    framed byte protocol the Oberon PCLink tool speaks. *)

(** A PCLink serial device watching a directory for job files. *)
type t

(** Watch [./PCLink.REC] and [./PCLink.SND], as the C does. *)
val create : unit -> t

(** Watch job files and resolve transferred filenames under [dir]. *)
val in_dir : string -> t

(** The {!Io.serial} view of this PCLink (closures over its mutable state). *)
val to_serial : t -> Io.serial
