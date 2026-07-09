(** Decide which files of a source tree the image builders compile, and in what order
    (topological sort of their IMPORT lists). Port of [host_tools::resolve].

    Every file is compiled as Oberon source except those in the tree's [.packonly]
    manifest; the manifest is required, so the choice is the source provider's and a data
    file left off it fails loudly rather than being fed to the compiler. *)

(** A source file to compile, paired with the module it declares. Objects are named by the
    module, not the file ([Display.Orig.Mod] emits [Display.rsc]), so both are kept:
    [file] to hand the compiler, [module_] to locate the output. *)
type candidate =
  { file : string
  ; module_ : string
  }

(** [resolve sources visible] returns the compile candidates in dependency order, given
    [sources]'s already-listed visible (non-dot) file names. Raises [Failure] with a clear
    message when there is no [.packonly], it names a missing file, a candidate isn't
    Oberon source, two files declare the same module, or the imports form a cycle. *)
val resolve : string -> string list -> candidate list

(** Exposed for the test suite. Both raise [Failure] on malformed input. *)
module For_tests : sig
  val parse_header : string -> string * string list
  val topo_sort : (string * string list) list -> string list
end
