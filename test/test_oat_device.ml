(* Byte-channel tests for Oat.Device, wired to host pipes via For_tests.make
   (reader = the "device -> host" pipe, writer = the "host -> device" pipe);
   forked children play the device end. The channel moves opaque bytes — the
   frame grammar over it is Io's, tested in test_oat_io. *)

open Oat
open Test_harness

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

let expect_error name pred f =
  match f () with
  | _ -> check name false
  | exception Error.Error e -> check name (pred e)
;;

let () =
  (* Frames leave verbatim — the channel doesn't inspect the bytes. *)
  let d, _resp, sent_read = harness 1.0 in
  Device.send d "frame";
  let buf = Bytes.create 8 in
  let n = Unix.read sent_read buf 0 8 in
  eqs "frame_out_verbatim" (Bytes.sub_string buf 0 n) "frame";
  (* recv reassembles a fill split across writes. *)
  let d, resp_write, _sent = harness 1.0 in
  let pid = delayed_writer resp_write [ "abc"; "defg" ] 0.02 in
  let buf = Bytes.create 7 in
  Device.recv d buf;
  eqs "split_reads_reassembled" (Bytes.to_string buf) "abcdefg";
  reap pid;
  (* A silent line times out, reporting progress... *)
  let d, _resp_write_keepalive, _sent = harness 0.03 in
  expect_error
    "silent_line_times_out"
    (function
      | Error.Timeout { got = 0; want = 4; _ } -> true
      | _ -> false)
    (fun () -> Device.recv d (Bytes.create 4));
  (* ... including partial progress. *)
  let d, resp_write, _sent = harness 0.05 in
  ignore (Unix.write_substring resp_write "a" 0 1);
  expect_error
    "partial_fill_times_out"
    (function
      | Error.Timeout { got = 1; want = 3; _ } -> true
      | _ -> false)
    (fun () -> Device.recv d (Bytes.create 3));
  (* A closed line is EOF, not a timeout. *)
  let d, resp_write, _sent = harness 1.0 in
  Unix.close resp_write;
  expect_error
    "closed_line_is_eof"
    (function
      | Error.Eof -> true
      | _ -> false)
    (fun () -> Device.recv d (Bytes.create 1));
  (* drain discards buffered leftovers; bytes arriving after it get
     through untouched. *)
  let d, resp_write, _sent = harness 1.0 in
  ignore (Unix.write_substring resp_write "\x99stale" 0 6);
  Unix.sleepf 0.01;
  Device.drain d;
  let pid = delayed_writer resp_write [ "fresh" ] 0.02 in
  let buf = Bytes.create 5 in
  Device.recv d buf;
  eqs "stale_drained_fresh_read" (Bytes.to_string buf) "fresh";
  reap pid;
  (* open_fifos: read-write opens that never block; a missing path reports
     Open_fifo (with the mkfifo hint downstream). *)
  with_scratch ~prefix:"oat_device" (fun dir ->
    let in_path = Filename.concat dir "p.in"
    and out_path = Filename.concat dir "p.out" in
    Unix.mkfifo in_path 0o600;
    Unix.mkfifo out_path 0o600;
    let _d = Device.open_fifos ~in_path ~out_path ~timeout:0.1 in
    check "fifo_pair_opens" true;
    expect_error
      "fifo_missing_is_open_fifo"
      (function
        | Error.Open_fifo { err = Unix.ENOENT; _ } -> true
        | _ -> false)
      (fun () ->
         Device.open_fifos
           ~in_path:(Filename.concat dir "nope.in")
           ~out_path
           ~timeout:0.1));
  summary "oat device checks"
;;
