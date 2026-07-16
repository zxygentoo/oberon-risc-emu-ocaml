(** High-level oat operations on the Oberon device (port of oat's [tools.rs]).

    Each function turns one wire round-trip (or two for the edit fallback) into a
    typed result over a {!Protocol.send} seam, so tests can plug in an in-memory
    fake. Errors raise {!Error.Error}. *)

(** Output of {!compile_module}. The compiler log is always returned; [failed] tells
    the CLI to exit 1 after printing it. *)
type compile_result =
  { output : string
  ; failed : bool
  }

(** Output of {!run_command}. The Log delta is always returned; {!call_outcome} maps
    the device status to the command result once the log is printed. *)
type call_result =
  { log : string
  ; status : Protocol.status
  }

(** @raise Error.Error ([Trapped] or [Bad_status]) on a non-Ok status. *)
val call_outcome : call_result -> unit

(** Read a device file as host LF text. *)
val read_file : Protocol.send -> string -> string

(** Create or overwrite a device file with host LF text. *)
val write_file : Protocol.send -> path:string -> content:string -> unit

(** Replace a unique occurrence of [old] by [new_] in a device file.

    Normally one EDIT round-trip: the device matches OLD inside the file via its
    Texts piece list and splices NEW in atomically. OLD fragments larger than the
    device's fixed match buffer ({!Protocol.edit_old_limit}) take a host-side
    GET+PUT fallback instead. *)
val edit_file : Protocol.send -> path:string -> old:string -> new_:string -> unit

(** Delete a device file (via [System.DeleteFiles]). *)
val delete_file : Protocol.send -> string -> unit

(** List device files matching a name prefix (TSV: name, size, date). *)
val list_files : Protocol.send -> prefix:string -> string

(** List loaded modules (TSV: name, refcnt, code address). *)
val list_modules : Protocol.send -> string

(** Read [System.Version] via [AgentTool.Version] (the trimmed log line). Empty when
    the image lacks the System.Version patch. *)
val version : Protocol.send -> string

(** Load a compiled module (via [AgentTool.Load]). *)
val load_module : Protocol.send -> string -> unit

(** Unload a module (via [System.Free NAME /f]) and return the log. On EO, [/f]
    triggers safe-unload; on PO it tokenizes as junk the scanner discards, so the
    unload is the unsafe kind (the skill warns about this). *)
val unload_module : Protocol.send -> string -> string

(** Compile a source file via [ORP.Compile]; [new_symbol] appends [/s]. *)
val compile_module : Protocol.send -> name:string -> new_symbol:bool -> compile_result

(** Run any Oberon command [Mod.Proc]; the response payload is the Oberon.Log delta
    written while it ran. *)
val run_command : Protocol.send -> cmd:string -> args:string -> call_result
