(* Clipboard GET/PUT bridge tests, ported from the Rust clipboard.rs tests. They
   drive the bridge through its public {!Risc_core.Io.clipboard} interface, with a
   fake host backed by a mutable cell. *)

open Risc_core

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let eqx name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got %d, want %d\n" name got want)
;;

(* A fake host clipboard backed by a mutable cell, returned alongside it. *)
let make_host initial =
  let cell = ref initial in
  cell, { Clipboard.get_text = (fun () -> Some !cell); set_text = (fun s -> cell := s) }
;;

let () =
  (* GET folds CRLF and a lone LF to CR. "ab\r\ncd\nef" is 9 bytes; one CRLF
     collapses, so 8 are announced. *)
  (let _cell, host = make_host "ab\r\ncd\nef" in
   let c = Clipboard.to_clipboard (Clipboard.create host) in
   eqx "get_announced_len" (c.Io.clip_read_control ()) 8;
   let buf = Buffer.create 8 in
   for _ = 1 to 8 do
     Buffer.add_char buf (Char.chr (c.Io.clip_read_data ()))
   done;
   check "get_folded" (Buffer.contents buf = "ab\rcd\ref");
   eqx "get_drained" (c.Io.clip_read_data ()) 0);
  (* PUT converts Oberon's CR to LF for the host. *)
  (let cell, host = make_host "" in
   let c = Clipboard.to_clipboard (Clipboard.create host) in
   c.Io.clip_write_control 3;
   List.iter (fun ch -> c.Io.clip_write_data (Char.code ch)) [ 'x'; '\r'; 'y' ];
   check "put_cr_to_lf" (!cell = "x\ny"));
  (* PUT decodes Latin-1 bytes as code points (re-encoded UTF-8). 0xE4 = 'ä'. *)
  (let cell, host = make_host "" in
   let c = Clipboard.to_clipboard (Clipboard.create host) in
   c.Io.clip_write_control 3;
   List.iter c.Io.clip_write_data [ Char.code 'a'; 0xE4; Char.code 'b' ];
   check "put_latin1" (!cell = "a\xC3\xA4b"));
  (* Empty clipboard reads zero. *)
  (let _cell, host = make_host "" in
   let c = Clipboard.to_clipboard (Clipboard.create host) in
   eqx "empty_control" (c.Io.clip_read_control ()) 0;
   eqx "empty_data" (c.Io.clip_read_data ()) 0);
  if !failures = 0
  then Printf.printf "ok: %d clipboard checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d clipboard checks failed\n" !failures !total;
    exit 1)
;;
