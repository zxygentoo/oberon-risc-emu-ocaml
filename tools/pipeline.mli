(** The shared disk-image build pipeline behind [build-po-image] and [build-eo-image]
    (port of [host_tools::pipeline]). Compiles a whole Oberon source tree against an
    embedded host toolchain, links a fresh inner core, and assembles a bootable
    [Oberon.dsk] — driving {!Risc_core.Shim} one Oberon command at a time. Each builder
    supplies only its {!seed} and a name. *)

(** What sets one builder apart: the embedded toolchain seed and a name. *)
type seed =
  { toolchain : (string * string) list
  (** Host-glue [.Mod] sources plus the prebuilt bootstrap [.rsc]/[InnerCore] that seed
      the first compile, as [(filename, bytes)] written flat into a scratch directory.
      Flat names never collide ([.Mod] vs [.rsc]). *)
  ; golden_inner_core : string
  (** The committed golden inner core; the one freshly linked during the build must
      reproduce it byte-for-byte (a self-consistency check). *)
  ; name : string (** Tool name, used in messages and the scratch-dir name. *)
  }

(** The [.packonly] manifest section appended to each builder's [--help]. *)
val packonly_help : string

(** [build seed ~sources ~output] compiles the tree at [sources] and writes a bootable
    disk image to [output]. Work happens in a temp scratch dir; on success only the
    finished [Oberon.dsk] is copied out and the scratch dir is removed, on failure it is
    left behind for inspection. Raises [Failure] (and [Sys_error]/[Unix.Unix_error]) on
    failure. *)
val build : seed -> sources:string -> output:string -> unit

(** Exposed for the test suite. *)
module For_tests : sig
  val bulk_rename : string -> string -> string -> unit
  val bulk_delete : string -> string -> unit
  val sorted_visible : string -> string list
  val extract_toolchain : (string * string) list -> string -> unit
end
