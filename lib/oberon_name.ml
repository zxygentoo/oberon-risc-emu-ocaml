(** Oberon file-name character rules (port of [risc_core::name_char_ok]). *)

let name_char_ok i ch =
  let is_alpha =
    (ch >= Char.code 'A' && ch <= Char.code 'Z')
    || (ch >= Char.code 'a' && ch <= Char.code 'z')
  in
  let is_digit = ch >= Char.code '0' && ch <= Char.code '9' in
  is_alpha || (i > 0 && (ch = Char.code '.' || is_digit))
;;

let chars_ok s =
  String.to_seqi s |> Seq.for_all (fun (i, c) -> name_char_ok i (Char.code c))
;;

let max_length = 31 (* FileDir.FnLength - 1: names are 0X-terminated in 32 bytes *)

let file_name_ok s =
  let n = String.length s in
  n > 0 && n <= max_length && chars_ok s
;;
