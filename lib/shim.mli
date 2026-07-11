(** Headless "shim" runtime: run one Oberon command by booting an inner-core image on the
    {!Risc} CPU with the whole MMIO region mapped onto the host filesystem (Oberon
    [Kernel]/[Files]/[FileDir] syscalls -> host files). A port of project-norebo's
    [Runtime/norebo.c] / the Rust [shim.rs].

    The image-build pipeline drives {!run} repeatedly — one Oberon command per call, each
    a cold boot — to compile a whole system and assemble a disk. *)

(** [run args ~cwd ~path] runs the Oberon command [args] (e.g.
    [["ORP.Compile"; "Foo.Mod/s"]]) to completion. Files resolve relative to [cwd]
    (read-write), then each [path] directory (read-only); the [InnerCore] image is located
    the same way. Returns [Ok code] with the guest's process exit code, or [Error msg] if
    the inner core can't be found/read or is malformed. Files the guest left open are
    flushed before returning. *)
val run : string list -> cwd:string -> path:string list -> (int, string) result

(** Helpers exposed for the test suite (no CPU, no disk). *)
module For_tests : sig
  val mem_read_byte : int array -> int -> int
  val mem_write_byte : int array -> int -> int -> unit
  val mem_read_bytes : int array -> int -> bytes -> unit
  val mem_write_bytes : int array -> int -> bytes -> unit
  val read_name : int array -> int -> string option
  val valid_name : string -> bool

  (** The syscall host, for driving the file ABI directly. *)
  type host

  (** A host over a nonexistent cwd: files never persist, and a [files_old] host-side
      read simply fails. *)
  val make_host : unit -> host

  (** The Files syscalls (Norebo ABI): handles are ints with [0xFFFF_FFFF] as the error
      sentinel; names and buffers live in the guest's [int array] RAM. *)
  val files_new : host -> int -> int array -> int

  val files_old : host -> int -> int array -> int
  val files_seek : host -> int -> int -> int -> int
  val files_read : host -> int -> int -> int -> int array -> int
  val files_write : host -> int -> int -> int -> int array -> int

  (** Capacity of handle [h]'s in-memory buffer (0 for an invalid handle). *)
  val file_capacity : host -> int -> int
end
