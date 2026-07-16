(* Transport tests, ported from oat's transport.rs unit tests: the transport is
   wired to host pipes via For_tests.make (reader = the "device -> host" pipe,
   writer = the "host -> device" pipe). Where the Rust tests used a delayed writer
   thread — send() drains stale bytes first, so a reply pre-loaded before the
   request would be (correctly) discarded — a forked child plays the device. *)

open Oat
open Test_harness

let harness timeout =
  let resp_read, resp_write = Unix.pipe () in
  let sent_read, sent_write = Unix.pipe () in
  let t =
    Transport.For_tests.make
      ~reader:resp_read
      ~writer:(Some sent_write)
      ~timeout
      ~char_delay:0.0
  in
  t, resp_write, sent_read
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

let expect_error name pred f =
  match f () with
  | _ -> check name false
  | exception Error.Error e -> check name (pred e)
;;

let () =
  (* The frame goes out verbatim (transport doesn't inspect it) and the delayed
     response is decoded. *)
  let t, resp_write, sent_read = harness 1.0 in
  let pid =
    delayed_writer resp_write [ Protocol.For_tests.encode_response Protocol.Ok "hi" ] 0.02
  in
  let r = Transport.send t "frame" in
  check "send_decodes_status" (r.Protocol.status = Protocol.Ok);
  eqs "send_decodes_payload" r.Protocol.payload "hi";
  let buf = Bytes.create 5 in
  let n = Unix.read sent_read buf 0 5 in
  eqs "frame_sent_verbatim" (Bytes.sub_string buf 0 n) "frame";
  reap pid;
  (* A silent line times out, reporting progress (0 of the 1-byte sync read). *)
  let t, _resp_write_keepalive, _sent = harness 0.03 in
  expect_error
    "silent_line_times_out"
    (function
      | Error.Timeout { got = 0; want = 1; _ } -> true
      | _ -> false)
    (fun () -> Transport.send t "x");
  (* A closed line is EOF, not a timeout. *)
  let t, resp_write, _sent = harness 1.0 in
  Unix.close resp_write;
  expect_error
    "closed_line_is_eof"
    (function
      | Error.Eof -> true
      | _ -> false)
    (fun () -> Transport.send t "x");
  (* A response split across writes is reassembled — split mid-length-field so
     recv_exact has to loop within one buffer. *)
  let t, resp_write, _sent = harness 1.0 in
  let frame = Protocol.For_tests.encode_response Protocol.Ok "abc" in
  let pid =
    delayed_writer
      resp_write
      [ String.sub frame 0 4; String.sub frame 4 (String.length frame - 4) ]
      0.02
  in
  let r = Transport.send t "x" in
  eqs "split_response_reassembled" r.Protocol.payload "abc";
  reap pid;
  (* Stale bytes left over from a prior exchange are drained before the request, so
     they can't shift this exchange's reply out of frame. *)
  let t, resp_write, _sent = harness 1.0 in
  ignore (Unix.write_substring resp_write "\x99garbage" 0 8);
  Unix.sleepf 0.01;
  let pid =
    delayed_writer resp_write [ Protocol.For_tests.encode_response Protocol.Ok "ok" ] 0.02
  in
  let r = Transport.send t "x" in
  eqs "stale_bytes_drained" r.Protocol.payload "ok";
  reap pid;
  summary "oat transport checks"
;;
