(* Text-conversion tests, ported from the ob2txt/txt2ob Rust unit tests. *)

open Oberon_tools
open Test_harness

let () =
  (* from_oberon: Oberon (Latin-1/CR) -> host (UTF-8/LF) *)
  eqs "cr_becomes_lf" (Convert.from_oberon "MODULE A;\rEND A.\r") "MODULE A;\nEND A.\n";
  eqs "crlf_collapses_to_lf" (Convert.from_oberon "a\r\nb") "a\nb";
  (* 0xE4 = 'ä' in Latin-1 -> UTF-8 0xC3 0xA4 *)
  eqs "latin1_byte_becomes_utf8" (Convert.from_oberon "\xE4") "\xC3\xA4";
  (* to_oberon: host (UTF-8/LF) -> Oberon (Latin-1/CR) *)
  eqs "lf_becomes_cr" (Convert.to_oberon "MODULE A;\nEND A.\n") "MODULE A;\rEND A.\r";
  eqs "crlf_normalizes_to_cr" (Convert.to_oberon "a\r\nb") "a\rb";
  eqs "latin1_char_becomes_one_byte" (Convert.to_oberon "\xC3\xA4") "\xE4";
  (* U+2192 '→' is beyond Latin-1 -> '?' *)
  eqs "beyond_latin1_is_replaced" (Convert.to_oberon "a\xE2\x86\x92b") "a?b";
  (* CR-terminated Oberon text round-trips *)
  eqs "round_trip_cr" (Convert.to_oberon (Convert.from_oberon "A\rB\r")) "A\rB\r";
  summary "convert checks"
;;
