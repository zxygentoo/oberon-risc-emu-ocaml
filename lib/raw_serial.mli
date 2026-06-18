(** Raw serial line over host file descriptors (port of the POSIX branch of
    [raw-serial.c]), used by [--serial-in]/[--serial-out]. *)

(** A raw serial line over a pair of host file descriptors. *)
type t

(** [create in_file out_file] opens the input (read-only) and output (read-write)
    files non-blocking.
    @raise Unix.Unix_error if a file cannot be opened. *)
val create : string -> string -> t

(** The {!Io.serial} view of this raw line (closures over its fds). *)
val to_serial : t -> Io.serial
