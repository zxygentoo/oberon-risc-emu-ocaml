(* Shim ABI unit tests, ported from shim.rs: byte-addressed guest memory, name
   validation, and the host file ABI driven directly (no CPU, no disk). The boot path is
   exercised end-to-end by the image-builder round-trip test. *)

open Risc_core
open Test_harness
module M = Shim.For_tests

let () =
  (* ShimMem: byte addressing over the guest's word array *)
  (let ram = Array.make 1 0 in
   M.mem_write_byte ram 0 0x00;
   M.mem_write_byte ram 1 0x11;
   M.mem_write_byte ram 2 0x22;
   M.mem_write_byte ram 3 0x33;
   eqx "shimmem_le" ram.(0) 0x33221100);
  (let ram = [| 0xFFFFFFFF |] in
   M.mem_write_byte ram 2 0x00;
   eqx "preserve_read2" (M.mem_read_byte ram 2) 0x00;
   eqx "preserve_read3" (M.mem_read_byte ram 3) 0xFF;
   eqx "preserve_word" ram.(0) 0xFF00FFFF);
  (let ram = Array.make 4 0 in
   let src = Bytes.of_string "\x01\x02\x03\x04\x05\x06" in
   M.mem_write_bytes ram 2 src;
   let got = Bytes.create 6 in
   M.mem_read_bytes ram 2 got;
   check "bytes_roundtrip_across_word" (Bytes.equal got src));
  (* wild pointer: reads yield 0, writes vanish *)
  (let ram = Array.make 16 0 in
   eqx "wild_read_zero" (M.mem_read_byte ram (1 lsl 20)) 0;
   M.mem_write_byte ram (1 lsl 20) 0xAB;
   check "wild_write_dropped" (Array.for_all (fun w -> w = 0) ram));
  (* read_name reads guest memory, validating *)
  let name_at bytes =
    let ram = Array.make 32 0 in
    M.mem_write_bytes ram 0 (Bytes.of_string bytes);
    M.read_name ram 0
  in
  check "read_name_stops_at_nul" (name_at "Kernel.Mod\x00junk" = Some "Kernel.Mod");
  check "read_name_empty_ok" (name_at "\x00" = Some "");
  check "read_name_unterminated" (M.read_name (Array.make 32 0x41414141) 0 = None);
  check "read_name_path_sep" (name_at "a/b\x00" = None);
  check "read_name_leading_digit" (name_at "9bad\x00" = None);
  (let ram = Array.make 16 0 in
   check "read_name_wild_ptr_is_empty" (M.read_name ram (1 lsl 20) = Some ""));
  (* valid_name is pure *)
  check "valid_name_ok" (M.valid_name "Oberon10.Scn.Fnt");
  check "valid_name_empty" (not (M.valid_name ""));
  check "valid_name_too_long" (not (M.valid_name (String.make 32 'A')));
  check "valid_name_space" (not (M.valid_name "bad name"));
  (* Host file ABI, driven directly (ported from shim.rs). *)
  let max_u32 = 0xFFFF_FFFF in
  (* files_new + write/seek/read round-trips in memory *)
  (let ram = Array.make 64 0 in
   M.mem_write_bytes ram 0 (Bytes.of_string "Scratch\x00");
   let h = M.make_host () in
   let fd = M.files_new h 0 ram in
   check "files_new_ok" (fd <> max_u32);
   let payload = "hello oberon" in
   let len = String.length payload in
   M.mem_write_bytes ram 64 (Bytes.of_string payload);
   eqx "files_write_n" (M.files_write h fd 64 len ram) len;
   ignore (M.files_seek h fd 0 0 : int) (* whence 0 = SET *);
   eqx "files_read_n" (M.files_read h fd 128 len ram) len;
   let got = Bytes.create len in
   M.mem_read_bytes ram 128 got;
   check "files_read_back" (Bytes.to_string got = payload));
  (* a read past EOF returns what is available and zero-fills the tail *)
  (let ram = Array.make 64 0 in
   M.mem_write_bytes ram 0 (Bytes.of_string "Scratch\x00");
   let h = M.make_host () in
   let fd = M.files_new h 0 ram in
   M.mem_write_bytes ram 64 (Bytes.of_string "\xAA\xBB");
   ignore (M.files_write h fd 64 2 ram : int);
   ignore (M.files_seek h fd 0 0 : int);
   M.mem_write_bytes ram 128 (Bytes.of_string "\xFF\xFF\xFF\xFF") (* dirty the dest *);
   eqx "eof_read_n" (M.files_read h fd 128 4 ram) 2;
   let got = Bytes.create 4 in
   M.mem_read_bytes ram 128 got;
   check "eof_zero_fills" (Bytes.to_string got = "\xAA\xBB\x00\x00"));
  (* an illegal name / a missing file yield the error sentinel *)
  (let ram = Array.make 16 0 in
   M.mem_write_bytes ram 0 (Bytes.of_string "a/b\x00");
   eqx "files_new_illegal_name" (M.files_new (M.make_host ()) 0 ram) max_u32);
  (let ram = Array.make 16 0 in
   M.mem_write_bytes ram 0 (Bytes.of_string "Nope.Mod\x00");
   eqx "files_old_missing" (M.files_old (M.make_host ()) 0 ram) max_u32);
  (* a wild transfer length clamps to guest RAM (the file is empty: 0 bytes read) *)
  (let ram = Array.make 16 0 in
   let h = M.make_host () in
   M.mem_write_bytes ram 0 (Bytes.of_string "Scratch\x00");
   let fd = M.files_new h 0 ram in
   check "wild_len_new_ok" (fd <> max_u32);
   eqx "wild_len_read_clamps" (M.files_read h fd 0 max_u32 ram) 0);
  (* a write past the file-size cap is refused outright, not zero-filled to size *)
  (let ram = Array.make 64 0 in
   let h = M.make_host () in
   M.mem_write_bytes ram 0 (Bytes.of_string "Scratch\x00");
   let fd = M.files_new h 0 ram in
   ignore (M.files_seek h fd 0x7FFF_FFFF 0 : int) (* seek to ~2 GiB *);
   eqx "cap_write_refused" (M.files_write h fd 0 4 ram) 0;
   eqx "cap_file_not_grown" (M.file_capacity h fd) 0);
  summary "shim checks"
;;
