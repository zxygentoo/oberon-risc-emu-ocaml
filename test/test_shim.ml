(* Shim ABI unit tests, ported from the pure-function tests in shim.rs (byte-addressed
   guest memory + name validation; no CPU, no disk). The full file ABI and boot path are
   exercised end-to-end by the image-builder round-trip test. *)

open Risc_core
module M = Shim.For_tests

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
    Printf.printf "FAIL: %s (got 0x%X want 0x%X)\n" name got want)
;;

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
  if !failures = 0
  then Printf.printf "ok: %d shim checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d shim checks failed\n" !failures !total;
    exit 1)
;;
