(* Wire-codec and exchange tests for Oat.Io: byte-exact request encoding,
   response decoding, the device-side test codec inverting both, the retry
   policy (only transport desyncs are re-sent, within the budget), and full
   exchanges over host pipes with a forked child playing the device. *)

open Oat
open Test_harness
module Wire = Data.Wire

(* Feed [read_response] from a byte string, as the device channel would. *)
let read_with bytes =
  let cur = ref 0 in
  Io.For_tests.read_response (fun buf ->
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

let expect_error name pred f =
  match f () with
  | _ -> check name false
  | exception Error.Error e -> check name (pred e)
;;

(* A thunk that fails (with a chosen error) its first [fail_then] calls, then
   succeeds; returns the call counter alongside. *)
let flaky fail_then err =
  let calls = ref 0 in
  let f () =
    incr calls;
    if !calls <= fail_then
    then Error.fail (err ())
    else { Wire.status = Wire.Ok; payload = "" }
  in
  f, calls
;;

let timeout () = Error.Timeout { secs = 1.0; got = 0; want = 1 }
let bad_sync () = Error.Bad_sync { got = 0; expected = 0x5A }

(* Pipe-backed device for the exchange tests (reader = the "device -> host"
   pipe, writer = the "host -> device" pipe). *)
let harness timeout =
  let resp_read, resp_write = Unix.pipe () in
  let sent_read, sent_write = Unix.pipe () in
  let d =
    Device.For_tests.make
      ~reader:resp_read
      ~writer:(Some sent_write)
      ~timeout
      ~char_delay:0.0
  in
  d, resp_write, sent_read
;;

(* Fork a child that writes [chunks] to [fd], sleeping [delay] before each. *)
let delayed_writer fd chunks delay =
  match Unix.fork () with
  | 0 ->
    List.iter
      (fun c ->
         Unix.sleepf delay;
         ignore (Unix.write_substring fd c 0 (String.length c)))
      chunks;
    Unix._exit 0
  | pid -> pid
;;

let reap pid = ignore (Unix.waitpid [] pid)

let () =
  (* Requests encode byte-exactly. *)
  eqs
    "encode_get"
    (Io.For_tests.encode_request (Wire.Get { name = "M.Mod" }))
    "\xA5\x02\x05M.Mod";
  eqs
    "encode_put"
    (Io.For_tests.encode_request (Wire.Put { name = "X"; data = "hi" }))
    "\xA5\x01\x01X\x02\x00\x00\x00hi";
  eqs
    "encode_call"
    (Io.For_tests.encode_request (Wire.Call { cmd = "A.B"; par = "p" }))
    "\xA5\x03\x03A.B\x01\x00\x00\x00p";
  eqs
    "encode_edit"
    (Io.For_tests.encode_request (Wire.Edit { name = "X"; old = "ab"; new_ = "c" }))
    "\xA5\x04\x01X\x02\x00\x00\x00ab\x01\x00\x00\x00c";
  eqs
    "encode_edit_empty_new"
    (Io.For_tests.encode_request (Wire.Edit { name = "X"; old = "a"; new_ = "" }))
    "\xA5\x04\x01X\x01\x00\x00\x00a\x00\x00\x00\x00";
  (* Names carry a 1-byte length prefix: 1..255 bytes only. *)
  expect_bad_name "empty_name_rejected" (fun () ->
    Io.For_tests.encode_request (Wire.Get { name = "" }));
  expect_bad_name "long_name_rejected" (fun () ->
    Io.For_tests.encode_request (Wire.Get { name = String.make 256 'x' }));
  check
    "name_at_255_accepted"
    (String.length (Io.For_tests.encode_request (Wire.Get { name = String.make 255 'x' }))
     = 2 + 1 + 255);
  (* Response decoding. *)
  let r = read_with "\x5A\x00\x03\x00\x00\x00abc" in
  check "ok_with_payload_status" (r.status = Wire.Ok);
  eqs "ok_with_payload_bytes" r.payload "abc";
  let r = read_with "\x5A\x00\x00\x00\x00\x00" in
  eqs "empty_payload" r.payload "";
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
    if Wire.status_byte r.status <> b then incr roundtrip_failures
  done;
  eq "status_byte_roundtrips_0_255" !roundtrip_failures 0;
  let r = read_with "\x5A\x2A\x00\x00\x00\x00" in
  check "unknown_status_preserved" (r.status = Wire.Other 0x2A);
  (* The device-side test codec inverts the production one. *)
  check
    "parse_inverts_get"
    (Io.For_tests.parse_request (Io.For_tests.encode_request (Wire.Get { name = "M.Mod" }))
     = Wire.Get { name = "M.Mod" });
  check
    "parse_inverts_put"
    (Io.For_tests.parse_request
       (Io.For_tests.encode_request (Wire.Put { name = "X"; data = "hi" }))
     = Wire.Put { name = "X"; data = "hi" });
  check
    "parse_inverts_call"
    (Io.For_tests.parse_request
       (Io.For_tests.encode_request (Wire.Call { cmd = "A.B"; par = "p" }))
     = Wire.Call { cmd = "A.B"; par = "p" });
  check
    "parse_inverts_edit"
    (Io.For_tests.parse_request
       (Io.For_tests.encode_request (Wire.Edit { name = "X"; old = "ab"; new_ = "" }))
     = Wire.Edit { name = "X"; old = "ab"; new_ = "" });
  (* ... and read_response inverts encode_response. *)
  let r =
    read_with
      (Io.For_tests.encode_response
         { Wire.status = Wire.Not_unique; payload = "\x02\x00\x00\x00" })
  in
  check "decode_inverts_encode_status" (r.status = Wire.Not_unique);
  eqs "decode_inverts_encode_payload" r.payload "\x02\x00\x00\x00";
  eq "not_unique_count" (Wire.not_unique_count r) 2;
  eq
    "not_unique_count_short_payload"
    (Wire.not_unique_count { Wire.status = Wire.Not_unique; payload = "" })
    0;
  (* Retry policy: only transport desyncs are re-sent, within the budget;
     everything else fails fast. *)
  let f, calls = flaky 0 timeout in
  check "first_try_ok" ((Io.For_tests.with_retries ~retries:2 f).status = Wire.Ok);
  eq "first_try_one_call" !calls 1;
  (* Two timeouts then success; 2 retries (3 attempts) covers it. *)
  let f, calls = flaky 2 timeout in
  check "recovers_within_budget" ((Io.For_tests.with_retries ~retries:2 f).status = Wire.Ok);
  eq "recovers_three_calls" !calls 3;
  let f, calls = flaky 1 bad_sync in
  check "bad_sync_retried" ((Io.For_tests.with_retries ~retries:2 f).status = Wire.Ok);
  eq "bad_sync_two_calls" !calls 2;
  (* Three failures but only 2 retries — the 3rd attempt also fails, so the error
     propagates after exactly 3 calls. *)
  let f, calls = flaky 3 timeout in
  expect_error
    "gives_up_after_budget"
    (function
      | Error.Timeout _ -> true
      | _ -> false)
    (fun () -> Io.For_tests.with_retries ~retries:2 f);
  eq "gives_up_three_calls" !calls 3;
  let f, calls = flaky 1 timeout in
  expect_error
    "zero_retries_single_attempt"
    (function
      | Error.Timeout _ -> true
      | _ -> false)
    (fun () -> Io.For_tests.with_retries ~retries:0 f);
  eq "zero_retries_one_call" !calls 1;
  (* Eof is a genuine line failure, not a desync — no retry. *)
  let f, calls = flaky 5 (fun () -> Error.Eof) in
  expect_error
    "eof_fails_fast"
    (function
      | Error.Eof -> true
      | _ -> false)
    (fun () -> Io.For_tests.with_retries ~retries:3 f);
  eq "eof_one_call" !calls 1;
  (* One full exchange over pipes: the encoded request leaves verbatim and the
     delayed response is decoded. *)
  let d, resp_write, sent_read = harness 1.0 in
  let pid =
    delayed_writer
      resp_write
      [ Io.For_tests.encode_response { Wire.status = Wire.Ok; payload = "hi" } ]
      0.02
  in
  let r = Io.send d ~retries:0 (Wire.Get { name = "X" }) in
  check "send_decodes_status" (r.status = Wire.Ok);
  eqs "send_decodes_payload" r.payload "hi";
  let expected_frame = Io.For_tests.encode_request (Wire.Get { name = "X" }) in
  let buf = Bytes.create 64 in
  let n = Unix.read sent_read buf 0 64 in
  eqs "frame_sent_verbatim" (Bytes.sub_string buf 0 n) expected_frame;
  reap pid;
  (* A silent line times out, reporting progress (0 of the 1-byte sync read). *)
  let d, _resp_write_keepalive, _sent = harness 0.03 in
  expect_error
    "silent_line_times_out"
    (function
      | Error.Timeout { got = 0; want = 1; _ } -> true
      | _ -> false)
    (fun () -> Io.send d ~retries:0 (Wire.Get { name = "X" }));
  (* Stale bytes left over from a prior exchange are drained before the request,
     so they can't shift this exchange's reply out of frame. *)
  let d, resp_write, _sent = harness 1.0 in
  ignore (Unix.write_substring resp_write "\x99garbage" 0 8);
  Unix.sleepf 0.01;
  let pid =
    delayed_writer
      resp_write
      [ Io.For_tests.encode_response { Wire.status = Wire.Ok; payload = "ok" } ]
      0.02
  in
  let r = Io.send d ~retries:0 (Wire.Get { name = "X" }) in
  eqs "stale_bytes_drained" r.payload "ok";
  reap pid;
  (* A garbage sync byte desyncs the first attempt; the retry budget covers the
     re-send, which finds a clean line. *)
  let d, resp_write, _sent = harness 1.0 in
  let pid =
    delayed_writer
      resp_write
      [ "\x42"; Io.For_tests.encode_response { Wire.status = Wire.Ok; payload = "again" } ]
      0.03
  in
  let r = Io.send d ~retries:1 (Wire.Get { name = "X" }) in
  eqs "desync_resend_recovers" r.payload "again";
  reap pid;
  summary "oat io checks"
;;
