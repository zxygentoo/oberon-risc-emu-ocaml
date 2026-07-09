(** Oberon file-name character rules, shared by the on-disk FS reader
    ({!Oberon_tools.Image}) and the headless shim. Port of the Rust
    [risc_core::name_char_ok]. *)

(** [name_char_ok i ch] holds when byte code [ch] is legal at position [i] of an Oberon
    file name: an ASCII letter anywhere, or a digit or ['.'] after the first character. So
    a name must start with a letter, then letters, digits, or dots — never a path
    separator, space, or leading digit/dot. *)
val name_char_ok : int -> int -> bool

(** [chars_ok s] holds when every character of [s] is legal at its position (an empty [s]
    holds vacuously — emptiness and length limits are the caller's rules). *)
val chars_ok : string -> bool
