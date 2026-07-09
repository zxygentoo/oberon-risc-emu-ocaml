(** Text conversion between Oberon (Latin-1/CR) and host (UTF-8/LF) — ports of the
    [ob2txt]/[txt2ob] transforms. *)

(* Append the UTF-8 encoding of Latin-1 byte [b] (i.e. code point U+00XX). *)
let add_latin1_as_utf8 buf b =
  if b < 0x80
  then Buffer.add_char buf (Char.chr b)
  else (
    Buffer.add_char buf (Char.chr (0xC0 lor (b lsr 6)));
    Buffer.add_char buf (Char.chr (0x80 lor (b land 0x3F))))
;;

(* Whether [s.[i]] exists and is [c]. *)
let char_at s i c = i < String.length s && s.[i] = c

let from_oberon bytes =
  (* Latin-1 -> UTF-8, then CRLF/CR -> LF. CR and LF are ASCII and untouched by the
     Latin-1 expansion, so one normalizing pass over the result matches Rust's
     [.replace("\r\n","\n").replace('\r',"\n")]. *)
  let expanded = Buffer.create (String.length bytes) in
  String.iter (fun c -> add_latin1_as_utf8 expanded (Char.code c)) bytes;
  let s = Buffer.contents expanded in
  let out = Buffer.create (String.length s) in
  let rec normalize i =
    if i < String.length s
    then
      if s.[i] = '\r'
      then (
        Buffer.add_char out '\n';
        normalize (if char_at s (i + 1) '\n' then i + 2 else i + 1))
      else (
        Buffer.add_char out s.[i];
        normalize (i + 1))
  in
  normalize 0;
  Buffer.contents out
;;

let to_oberon text =
  (* CRLF/LF -> CR (lone CR stays CR), then each code point -> a Latin-1 byte or '?'.
     UTF-8 continuation/lead bytes are all >= 0x80, never 0x0D/0x0A, so normalizing line
     endings at the byte level is exact. *)
  let cr = Buffer.create (String.length text) in
  let rec normalize i =
    if i < String.length text
    then (
      match text.[i] with
      | '\r' ->
        Buffer.add_char cr '\r';
        normalize (if char_at text (i + 1) '\n' then i + 2 else i + 1)
      | '\n' ->
        Buffer.add_char cr '\r';
        normalize (i + 1)
      | c ->
        Buffer.add_char cr c;
        normalize (i + 1))
  in
  normalize 0;
  let s = Buffer.contents cr in
  let out = Buffer.create (String.length s) in
  let rec latin1 i =
    if i < String.length s
    then (
      let dec = String.get_utf_8_uchar s i in
      let cp = Uchar.to_int (Uchar.utf_decode_uchar dec) in
      Buffer.add_char out (if cp <= 0xFF then Char.chr cp else '?');
      latin1 (i + Uchar.utf_decode_length dec))
  in
  latin1 0;
  Buffer.contents out
;;
