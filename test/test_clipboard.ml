(* Clipboard GET/PUT bridge tests, ported from the Rust clipboard.rs tests. They
   drive the bridge through its public {!Oberon_risc.Io.clipboard} interface, with a
   fake host backed by a mutable cell. *)

open Oberon_risc
open Test_harness

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
   eq "get_announced_len" (c.Io.clip_read_control ()) 8;
   let buf = Buffer.create 8 in
   for _ = 1 to 8 do
     Buffer.add_char buf (Char.chr (c.Io.clip_read_data ()))
   done;
   check "get_folded" (Buffer.contents buf = "ab\rcd\ref");
   eq "get_drained" (c.Io.clip_read_data ()) 0);
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
  (* A PUT longer than the initial buffer arrives whole through its growth. *)
  (let cell, host = make_host "" in
   let c = Clipboard.to_clipboard (Clipboard.create host) in
   let text = String.init 10_000 (fun i -> Char.chr (Char.code 'a' + (i mod 26))) in
   c.Io.clip_write_control (String.length text);
   String.iter (fun ch -> c.Io.clip_write_data (Char.code ch)) text;
   check "put_long" (!cell = text));
  (* The announced length is a guest store: announcing 4 GiB must not allocate
     it (it used to zero-fill all of it, an uncatchable out-of-memory). *)
  (let c = Clipboard.to_clipboard (Clipboard.create Clipboard.noop_host) in
   let before = Gc.allocated_bytes () in
   c.Io.clip_write_control 0xFFFF_FFFE;
   List.iter c.Io.clip_write_data [ Char.code 'h'; Char.code 'i' ];
   check "huge_announce_no_alloc" (Gc.allocated_bytes () -. before < 1_000_000.));
  (* Empty clipboard reads zero. *)
  (let _cell, host = make_host "" in
   let c = Clipboard.to_clipboard (Clipboard.create host) in
   eq "empty_control" (c.Io.clip_read_control ()) 0;
   eq "empty_data" (c.Io.clip_read_data ()) 0);
  (* The no-op host (headless runs, tests, the bench): nothing to read, and a PUT is
     accepted and dropped (reaching the last check is the assertion). *)
  (let c = Clipboard.to_clipboard (Clipboard.create Clipboard.noop_host) in
   eq "noop_control" (c.Io.clip_read_control ()) 0;
   eq "noop_data" (c.Io.clip_read_data ()) 0;
   c.Io.clip_write_control 2;
   List.iter c.Io.clip_write_data [ Char.code 'h'; Char.code 'i' ];
   check "noop_put_accepted" true);
  summary "clipboard checks"
;;
