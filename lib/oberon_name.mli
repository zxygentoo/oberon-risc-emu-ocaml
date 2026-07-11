(** Oberon file-name character rules, shared by the on-disk FS reader
    ({!Oberon_tools.Image}) and the headless shim. Port of the Rust
    [risc_core::name_char_ok]. *)

(** [chars_ok s] holds when every character of [s] is legal at its position: an ASCII
    letter anywhere, or a digit or ['.'] after the first character — so a name must start
    with a letter, then letters, digits, or dots; never a path separator, space, or
    leading digit/dot. An empty [s] holds vacuously — emptiness and length limits are the
    caller's rules. *)
val chars_ok : string -> bool
