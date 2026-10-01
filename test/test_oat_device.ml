(* Byte-channel tests for Oat.Device, wired to host pipes via For_tests.make
   (reader = the "device -> host" pipe, writer = the "host -> device" pipe);
   forked children play the device end. The channel moves opaque bytes — the
   frame grammar over it is Io's, tested in test_oat_io. The line setup of
   open_device runs against real pseudo-terminals (pty_stubs.c). *)

open Oat
open Test_harness

(* A fresh pseudo-terminal: the master fd and the slave's path. *)
external openpt : unit -> Unix.file_descr * string = "oat_test_openpt"

let open_tty path = Unix.openfile path [ Unix.O_RDWR; Unix.O_NOCTTY ] 0

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
         Device.open_fifos ~in_path:(Filename.concat dir "nope.in") ~out_path ~timeout:0.1));
  (* The baud table: the standard rates are there; 0 (hang up) and a non-standard
     rate are not, and asking for one fails before anything is opened. *)
  List.iter
    (fun b ->
       check (Printf.sprintf "baud_%d_supported" b) (List.mem b Device.supported_bauds))
    [ 9600; 19200; 38400; 115200 ];
  List.iter
    (fun b ->
       expect_error
         (Printf.sprintf "baud_%d_unsupported" b)
         (function
           | Error.Unsupported_baud { baud; supported } ->
             baud = b && supported = Device.supported_bauds
           | _ -> false)
         (fun () ->
            Device.open_device "/nonexistent/tty" ~timeout:1.0 ~baud:b ~char_delay:0.0))
    [ 0; 12345 ];
  (* A fresh pseudo-terminal is in cooked mode — the read-back sees that. *)
  let master, slave = openpt () in
  let fd = open_tty slave in
  let _, _, raw = Device.For_tests.read_back fd in
  check "fresh_pty_not_raw" (not raw);
  (* open_device takes the line over: the speed asked for, read back through
     oat's own stub. (Against Unix.tcsetattr on a switch built before a glibc
     >= 2.42 upgrade, this reads 4098.) *)
  List.iter
    (fun baud ->
       let _d = Device.open_device slave ~timeout:1.0 ~baud ~char_delay:0.0 in
       let i, o, raw = Device.For_tests.read_back fd in
       eq (Printf.sprintf "pty_%d_in" baud) i baud;
       eq (Printf.sprintf "pty_%d_out" baud) o baud;
       check (Printf.sprintf "pty_%d_raw" baud) raw)
    [ 115200; 19200 ];
  (* Every rate in the table round-trips through the line. *)
  let bad_rates =
    List.filter
      (fun baud ->
         Device.For_tests.configure fd baud;
         match Device.For_tests.verify fd { Device.path = slave; baud } with
         | () -> false
         | exception Error.Error _ -> true)
      Device.supported_bauds
  in
  check "every_rate_round_trips" (bad_rates = []);
  (* A line that holds another speed than the one asked for is a mismatch naming
     both — the failure that used to surface only as a timeout. *)
  Device.For_tests.configure fd 9600;
  expect_error
    "speed_mismatch_reported"
    (function
      | Error.Line_mismatch
          { path; baud = 115200; in_baud = 9600; out_baud = 9600; raw = true } ->
        path = slave
      | _ -> false)
    (fun () -> Device.For_tests.verify fd { Device.path = slave; baud = 115200 });
  (* Raw means raw: the bytes a terminal would act on cross verbatim, both ways —
     flow control (0x11, 0x13), the BSD literal-next / discard pair (0x16, 0x0F),
     signals (0x03), EOF (0x04), CR / NL, NUL, 0x7F, 0xFF. *)
  let binary = "\x16\x0F\x11\x13\x03\x04\r\n\x00\x7F\xFF\x1A" in
  let n = String.length binary in
  let d = Device.open_device slave ~timeout:1.0 ~baud:115200 ~char_delay:0.0 in
  ignore (Unix.write_substring master binary 0 n);
  let buf = Bytes.create n in
  Device.recv d buf;
  eqs "pty_device_to_host_verbatim" (Bytes.to_string buf) binary;
  Device.send d binary;
  let buf = Bytes.create 64 in
  let got = Unix.read master buf 0 64 in
  eqs "pty_host_to_device_verbatim" (Bytes.sub_string buf 0 got) binary;
  check
    "pty_is_a_serial_line"
    (Device.line d = Some { Device.path = slave; baud = 115200 });
  (* Open failures name the device: a missing path, and a path that is not a
     terminal (the line setup refuses it). *)
  let open_serial_error name path want =
    expect_error
      name
      (function
        | Error.Open_serial { path = p; err } -> p = path && err = want
        | _ -> false)
      (fun () -> Device.open_device path ~timeout:1.0 ~baud:115200 ~char_delay:0.0)
  in
  open_serial_error "serial_missing_is_open_serial" "/nonexistent/tty" Unix.ENOENT;
  with_scratch ~prefix:"oat_device_tty" (fun dir ->
    let plain = Filename.concat dir "plain" in
    write_file plain "";
    open_serial_error "serial_non_tty_is_open_serial" plain Unix.ENOTTY);
  summary "oat device checks"
;;
