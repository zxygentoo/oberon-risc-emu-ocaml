(** Shared CLI plumbing for the host-tool executables (the layer clap provides in the
    Rust port). *)

(** The version every host tool reports via [--version]. *)
val version : string

(** [parse ~name ~usage ~help ?flags args] walks argv-style [args] with the shared
    conventions: [-h]/[--help] prints [usage] plus [help] and exits 0; [--version]
    prints "[name] [version]" and exits 0; an argument matching a name in [flags] sets
    its ref; any other option is a usage error (exit 2). Returns the positional
    arguments in order (a lone ["-"] counts as positional). *)
val parse
  :  name:string
  -> usage:string
  -> help:string
  -> ?flags:(string * bool ref) list
  -> string list
  -> string list

(** [run_reporting ~name f] runs [f ()], printing any tool-level error ([Failure],
    [Sys_error], {!Image.Bad_image}, [Unix.Unix_error]) as "[name]: msg" to stderr and
    exiting 1. *)
val run_reporting : name:string -> (unit -> 'a) -> 'a

(** The whole main of an image builder: parse the CLI, build, report. The tool name is
    [seed.name]. *)
val run : Pipeline.seed -> unit
