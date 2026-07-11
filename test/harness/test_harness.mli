(** Shared harness for the hand-rolled test executables: counting asserts (a failing
    check prints FAIL and the run exits 1 at {!summary}, never masking later checks),
    plus scratch-file helpers. *)

(** The counters, exposed so a test can define its own specialty asserts on top. *)
val failures : int ref

val total : int ref

(** [check name cond] — one pass/fail check. *)
val check : string -> bool -> unit

(** [eq name got want] — equality with decimal diagnostics. *)
val eq : string -> int -> int -> unit

(** [eqx name got want] — equality with hex ([0x%08X]) diagnostics. *)
val eqx : string -> int -> int -> unit

(** [eqx64 name got want] — 64-bit equality with hex ([0x%016Lx]) diagnostics. *)
val eqx64 : string -> int64 -> int64 -> unit

(** [eqs name got want] — string equality with quoted diagnostics. *)
val eqs : string -> string -> string -> unit

(** Print the closing line for [label] (e.g. ["cli checks"]) and exit 1 on any
    failure. *)
val summary : string -> unit

(** Write [s] as the whole contents of a file. *)
val write_file : string -> string -> unit

(** Read a whole file. *)
val read_file : string -> string

(** Delete a file or directory tree if it exists. *)
val rm_rf : string -> unit

(** [with_scratch ~prefix f] runs [f dir] in a fresh scratch directory, removed
    afterwards (also on exceptions). *)
val with_scratch : prefix:string -> (string -> 'a) -> 'a
