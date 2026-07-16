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
  (* strip_text_header (oat's read path): tag=F1, off:4 LE = offset of the character
     run; anything short, untagged, or out of range passes through unchanged. *)
  eqs "text_header_stripped" (Convert.strip_text_header "\xF1\x05\x00\x00\x00hi") "hi";
  eqs "no_tag_passes_through" (Convert.strip_text_header "abc") "abc";
  (* off=42 is out of range — fall back to the whole buffer. *)
  eqs
    "garbled_header_intact"
    (Convert.strip_text_header "\xF1\x2A\x00\x00\x00x")
    "\xF1\x2A\x00\x00\x00x";
  (* negative off is out of range too *)
  eqs
    "negative_offset_intact"
    (Convert.strip_text_header "\xF1\xFF\xFF\xFF\xFFx")
    "\xF1\xFF\xFF\xFF\xFFx";
  (* tag byte present but fewer than 4 offset bytes follow *)
  eqs "truncated_header_intact" (Convert.strip_text_header "\xF1\x05") "\xF1\x05";
  eqs "lone_tag_intact" (Convert.strip_text_header "\xF1") "\xF1";
  (* the header may claim the whole file (empty character run) *)
  eqs "offset_at_end_ok" (Convert.strip_text_header "\xF1\x05\x00\x00\x00") "";
  summary "convert checks"
;;
