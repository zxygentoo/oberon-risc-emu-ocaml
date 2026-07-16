(* Wire-framing tests, ported from oat's protocol.rs unit tests: byte-exact request
   builders, response decoding, and the device-side test codec inverting both. *)

open Oat
open Test_harness

(* Feed [read_response] from a byte string, as the transport would. *)
let read_with bytes =
  let cur = ref 0 in
  Protocol.read_response (fun buf ->
    let n = Bytes.length buf in
    Bytes.blit_string bytes !cur buf 0 n;
    cur := !cur + n)
;;

let expect_bad_name name f =
  match f () with
  | _ -> check name false
  | exception Error.Error (Error.Bad_name _) -> check name true
  | exception _ -> check name false
;;

let () =
  (* Request builders shape frames byte-exactly. *)
  eqs "build_get" (Protocol.build_get ~name:"M.Mod") "\xA5\x02\x05M.Mod";
  eqs "build_put" (Protocol.build_put ~name:"X" ~data:"hi") "\xA5\x01\x01X\x02\x00\x00\x00hi";
  eqs "build_call" (Protocol.build_call ~cmd:"A.B" ~par:"p") "\xA5\x03\x03A.B\x01\x00\x00\x00p";
  eqs
    "build_edit"
    (Protocol.build_edit ~name:"X" ~old:"ab" ~new_:"c")
    "\xA5\x04\x01X\x02\x00\x00\x00ab\x01\x00\x00\x00c";
  eqs
    "build_edit_empty_new"
    (Protocol.build_edit ~name:"X" ~old:"a" ~new_:"")
    "\xA5\x04\x01X\x01\x00\x00\x00a\x00\x00\x00\x00";
  (* Names carry a 1-byte length prefix: 1..255 bytes only. *)
  expect_bad_name "empty_name_rejected" (fun () -> Protocol.build_get ~name:"");
  expect_bad_name "long_name_rejected" (fun () ->
    Protocol.build_get ~name:(String.make 256 'x'));
  check
    "name_at_255_accepted"
    (String.length (Protocol.build_get ~name:(String.make 255 'x')) = 2 + 1 + 255);
  (* Response decoding. *)
  let r = read_with "\x5A\x00\x03\x00\x00\x00abc" in
  check "ok_with_payload_status" (r.Protocol.status = Protocol.Ok);
  eqs "ok_with_payload_bytes" r.Protocol.payload "abc";
  check "ok_with_payload_ok" (Protocol.ok r);
  let r = read_with "\x5A\x00\x00\x00\x00\x00" in
  eqs "empty_payload" r.Protocol.payload "";
  (match read_with "\x42\x00\x00\x00\x00\x00" with
   | _ -> check "bad_sync_rejected" false
   | exception Error.Error (Error.Bad_sync { got = 0x42; expected = 0x5A }) ->
     check "bad_sync_rejected" true
   | exception _ -> check "bad_sync_rejected" false);
  (* Every status byte round-trips through decode -> status_byte; unknown bytes are
     preserved as Other, not collapsed. *)
  let roundtrip_failures = ref 0 in
  for b = 0 to 255 do
    let r = read_with ("\x5A" ^ String.make 1 (Char.chr b) ^ "\x00\x00\x00\x00") in
    if Protocol.status_byte r.Protocol.status <> b then incr roundtrip_failures
  done;
  eq "status_byte_roundtrips_0_255" !roundtrip_failures 0;
  let r = read_with "\x5A\x2A\x00\x00\x00\x00" in
  check "unknown_status_preserved" (r.Protocol.status = Protocol.Other 0x2A);
  (* The device-side test codec inverts the builders. *)
  let open Protocol.For_tests in
  check
    "parse_inverts_get"
    (parse_request (Protocol.build_get ~name:"M.Mod") = Get { name = "M.Mod" });
  check
    "parse_inverts_put"
    (parse_request (Protocol.build_put ~name:"X" ~data:"hi")
     = Put { name = "X"; data = "hi" });
  check
    "parse_inverts_call"
    (parse_request (Protocol.build_call ~cmd:"A.B" ~par:"p")
     = Call { cmd = "A.B"; par = "p" });
  check
    "parse_inverts_edit"
    (parse_request (Protocol.build_edit ~name:"X" ~old:"ab" ~new_:"")
     = Edit { name = "X"; old = "ab"; new_ = "" });
  (* ... and read_response inverts encode_response. *)
  let r = read_with (encode_response Protocol.Not_unique "\x02\x00\x00\x00") in
  check "decode_inverts_encode_status" (r.Protocol.status = Protocol.Not_unique);
  eqs "decode_inverts_encode_payload" r.Protocol.payload "\x02\x00\x00\x00";
  summary "oat protocol checks"
;;
