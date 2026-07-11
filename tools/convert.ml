(** Text conversion between Oberon (Latin-1/CR) and host (UTF-8/LF) — ports of the
    [ob2txt]/[txt2ob] transforms. *)

(* Latin-1 -> UTF-8: each byte becomes its code point U+00XX. *)
let latin1_to_utf8 bytes =
  let buf = Buffer.create (String.length bytes) in
  String.iter
    (fun c ->
      let b = Char.code c in
      if b < 0x80
      then Buffer.add_char buf c
      else (
        Buffer.add_char buf (Char.chr (0xC0 lor (b lsr 6)));
        Buffer.add_char buf (Char.chr (0x80 lor (b land 0x3F)))))
    bytes;
  Buffer.contents buf
;;

(* UTF-8 -> Latin-1: code points beyond U+00FF become '?' (malformed bytes decode to
   U+FFFD and land there too). *)
let utf8_to_latin1 s =
  let buf = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s
    then (
      let dec = String.get_utf_8_uchar s i in
      let cp = Uchar.to_int (Uchar.utf_decode_uchar dec) in
      Buffer.add_char buf (if cp <= 0xFF then Char.chr cp else '?');
      go (i + Uchar.utf_decode_length dec))
  in
  go 0;
  Buffer.contents buf
;;

(* Replace every occurrence of non-empty [sub] with [by]. *)
let replace_all ~sub ~by s =
  let buf = Buffer.create (String.length s) in
  let n = String.length sub in
  let rec go i =
    if i + n > String.length s
    then Buffer.add_substring buf s i (String.length s - i)
    else if String.sub s i n = sub
    then (
      Buffer.add_string buf by;
      go (i + n))
    else (
      Buffer.add_char buf s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf
;;

(* Both directions handle line endings at the byte level on UTF-8 text; that is exact
   because CR and LF are ASCII and never occur inside a multi-byte sequence. *)

let from_oberon bytes =
  latin1_to_utf8 bytes
  |> replace_all ~sub:"\r\n" ~by:"\n"
  |> String.map (fun c -> if c = '\r' then '\n' else c)
;;

let to_oberon text =
  text
  |> replace_all ~sub:"\r\n" ~by:"\n"
  |> String.map (fun c -> if c = '\n' then '\r' else c)
  |> utf8_to_latin1
;;
