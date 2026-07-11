(** Whole-file and directory-tree helpers shared across the host tools. *)

(** Read a whole file as bytes.
    @raise Sys_error if the file cannot be read. *)
val read_file : string -> string

(** [read_file], with an unreadable file as [None]. *)
val read_file_opt : string -> string option

(** Write [data] as the whole contents of the file at [path].
    @raise Sys_error if the file cannot be written. *)
val write_file : string -> string -> unit

(** Create a directory and any missing parents (the [mkdir -p] of [fs::create_dir_all]);
    an existing directory is fine. *)
val mkdir_p : string -> unit

(** Delete a file or directory tree if it exists ([fs::remove_dir_all]). *)
val rm_rf : string -> unit
