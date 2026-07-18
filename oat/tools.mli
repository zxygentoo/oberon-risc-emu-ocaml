(** The typed oat operations on the Oberon device — the semantics layer.

    Each function turns one wire round-trip (or two for the edit fallback) into a
    typed result over the {!Data.Wire.t} seam, so tests can plug in an in-memory
    fake device; {!execute} dispatches a whole {!Data.request} through them.
    Errors raise {!Error.Error}. *)

(** Output of {!compile_module}. The compiler log is always returned; [failed]
    tells {!Cli.render} to exit 1 after printing it. *)
type compile_result =
  { output : string
  ; failed : bool
  }

(** Output of {!run_command}. The Log delta is always returned; [failure] is the
    device status mapped to the command's error ([Trapped] or [Bad_status]),
    reported in-band so the log can be printed first. *)
type call_result =
  { log : string
  ; failure : Error.t option
  }

(** Read a device file as host LF text. *)
val read_file : Data.Wire.t -> string -> string

(** Create or overwrite a device file with host LF text. *)
val write_file : Data.Wire.t -> path:string -> content:string -> unit

(** Replace a unique occurrence of [old] by [new_] in a device file.

    Normally one EDIT round-trip: the device matches OLD inside the file via its
    Texts piece list and splices NEW in atomically. OLD fragments larger than the
    device's fixed match buffer ({!Data.Wire.edit_old_limit}) take a host-side
    GET+PUT fallback instead. *)
val edit_file : Data.Wire.t -> path:string -> old:string -> new_:string -> unit

(** Delete a device file (via [System.DeleteFiles]). *)
val delete_file : Data.Wire.t -> string -> unit

(** List device files matching a name prefix (TSV: name, size, date). *)
val list_files : Data.Wire.t -> prefix:string -> string

(** List loaded modules (TSV: name, refcnt, code address). *)
val list_modules : Data.Wire.t -> string

(** Read [System.Version] via [AgentTool.Version] (the trimmed log line). Empty
    when the image lacks the System.Version patch. *)
val version : Data.Wire.t -> string

(** Load a compiled module (via [AgentTool.Load]). *)
val load_module : Data.Wire.t -> string -> unit

(** Unload a module (via [System.Free NAME /f]) and return the log. On EO, [/f]
    triggers safe-unload; on PO it tokenizes as junk the scanner discards, so the
    unload is the unsafe kind (the skill warns about this). *)
val unload_module : Data.Wire.t -> string -> string

(** Compile a source file via [ORP.Compile]; [new_symbol] appends [/s]. *)
val compile_module : Data.Wire.t -> name:string -> new_symbol:bool -> compile_result

(** Run any Oberon command [Mod.Proc]; the response payload is the Oberon.Log
    delta written while it ran. *)
val run_command : Data.Wire.t -> cmd:string -> args:string -> call_result

(** Dispatch one operation-level request through the functions above (plus the
    round-trip timing for [Check]). The response is pure data — printing it, and
    failing on an in-band [Compiled]/[Called] failure, is {!Cli.render}'s job. *)
val execute : Data.Wire.t -> Data.request -> Data.response
