(** Text conversion between Oberon's native encoding (Latin-1 with CR line separators) and
    host text (UTF-8 with LF). Ports of the [ob2txt]/[txt2ob] transforms in the Rust
    host-tools. *)

(** Oberon bytes (Latin-1, CR separators) -> host text (UTF-8, LF). Each byte becomes its
    Latin-1 code point; then CRLF and lone CR become LF. *)
val from_oberon : string -> string

(** Raised by {!to_oberon} on text that is not UTF-8, with the byte offset of the
    first malformed sequence. *)
exception Invalid_utf8 of int

(** Host text (UTF-8, LF) -> Oberon bytes (Latin-1, CR separators). A leading
    byte-order mark is dropped; CRLF and LF become CR (a lone CR stays CR); code
    points beyond Latin-1 (> U+00FF) become ['?'] (see {!beyond_latin1}).
    @raise Invalid_utf8 rather than guess at text that is not UTF-8 — a Latin-1
    file passed by mistake, say, whose every accented letter would become ['?']. *)
val to_oberon : string -> string

(** How many code points of a UTF-8 text {!to_oberon} would write as ['?']. *)
val beyond_latin1 : string -> int

(** Drop the 0F1X-tagged formatted header that files written by Oberon's editor
    ([Texts.Close]) carry, recovering the plain character run; bytes without the tag
    (or with a short/out-of-range header) pass through unchanged. Used by oat's read
    path before {!from_oberon}; the converters themselves never strip. *)
val strip_text_header : string -> string
