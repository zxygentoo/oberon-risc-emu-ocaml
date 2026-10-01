(* Error-contract tests for oat: the exit-code partition documented in --help
   and SKILL.md, and the message bodies that carry hints and indented logs. *)

open Oat
open Test_harness

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  n = 0 || go 0
;;

let () =
  (* Tool-level errors -> 1 (the contract in --help and SKILL.md). *)
  eq "compile_failed_is_1" (Error.exit_code Error.Compile_failed) 1;
  eq "not_found_is_1" (Error.exit_code (Error.File_not_found "X")) 1;
  eq "trapped_is_1" (Error.exit_code Error.Trapped) 1;
  eq "edit_not_unique_is_1" (Error.exit_code (Error.Edit_not_unique 2)) 1;
  eq
    "unload_in_use_is_1"
    (Error.exit_code (Error.Unload_in_use "System.Free\nX unloading failed\n"))
    1;
  (* Transport / protocol / argument errors -> 2. *)
  eq "no_serial_is_2" (Error.exit_code Error.No_serial) 2;
  eq "eof_is_2" (Error.exit_code Error.Eof) 2;
  eq "bad_name_is_2" (Error.exit_code (Error.Bad_name "")) 2;
  eq
    "timeout_is_2"
    (Error.exit_code (Error.Timeout { secs = 1.0; got = 0; want = 1 }))
    2;
  (* load-failed carries the res code, its hint, and the log indented under it. *)
  let msg =
    Error.message
      (Error.Load_failed { res = Some 2; log = "AgentTool.Load\nres=2\n" })
  in
  check "load_failed_res" (contains ~sub:"res=2" msg);
  check "load_failed_hint" (contains ~sub:"hint: bad symbol-file key" msg);
  check "load_failed_indented_log" (contains ~sub:"\n  AgentTool.Load" msg);
  (* ... and an empty log adds nothing. *)
  let msg = Error.message (Error.Load_failed { res = None; log = "" }) in
  eqs "load_failed_bare" msg "load failed";
  (* The FIFO open error carries the mkfifo hint only for a missing path. *)
  check
    "fifo_missing_hints_mkfifo"
    (contains
       ~sub:"mkfifo"
       (Error.message (Error.Open_fifo { path = "/tmp/p.in"; err = Unix.ENOENT })));
  check
    "fifo_other_error_no_hint"
    (not
       (contains
          ~sub:"mkfifo"
          (Error.message (Error.Open_fifo { path = "/tmp/p.in"; err = Unix.EBUSY }))));
  (* The serial-line errors are all transport-level, and each says enough to tell
     which side to look at. An unsupported rate names it and lists the others. *)
  let unsupported =
    Error.Unsupported_baud { baud = 12345; supported = [ 9600; 19200; 115200 ] }
  in
  eq "unsupported_baud_is_2" (Error.exit_code unsupported) 2;
  eqs
    "unsupported_baud_message"
    (Error.message unsupported)
    "unsupported baud rate 12345\n  supported: 9600 19200 115200";
  (* A read-back mismatch shows asked versus got — the 4098 a stale baud table
     produces is reported as the number it is. *)
  let mismatch in_baud out_baud raw =
    Error.Line_mismatch { path = "/dev/ttyUSB1"; baud = 115200; in_baud; out_baud; raw }
  in
  eq "line_mismatch_is_2" (Error.exit_code (mismatch 4098 4098 true)) 2;
  let msg = Error.message (mismatch 4098 4098 true) in
  check "line_mismatch_path" (contains ~sub:"/dev/ttyUSB1" msg);
  check "line_mismatch_asked" (contains ~sub:"asked: 115200 baud, raw 8N1" msg);
  check "line_mismatch_got" (contains ~sub:"got:   4098 baud, raw 8N1\n" msg);
  check
    "line_mismatch_split_speeds"
    (contains
       ~sub:"got:   9600 baud in / 115200 baud out"
       (Error.message (mismatch 9600 115200 true)));
  check
    "line_mismatch_unnameable_speed"
    (contains
       ~sub:"got:   an unrecognized speed"
       (Error.message (mismatch (-1) (-1) true)));
  check
    "line_mismatch_mode"
    (contains
       ~sub:"115200 baud, raw 8N1 not applied"
       (Error.message (mismatch 115200 115200 false)));
  (* A link failure on a verified line: the path, the attempts, the line the host
     holds, and what is left to check — never the emulator hint. *)
  let link attempts cause =
    Error.Serial_link { path = "/dev/ttyUSB1"; baud = 115200; attempts; cause }
  in
  let silence = link 4 (Error.Timeout { secs = 2.0; got = 0; want = 1 }) in
  eq "serial_link_is_2" (Error.exit_code silence) 2;
  eqs
    "serial_silence_message"
    (Error.message silence)
    "no response on /dev/ttyUSB1 after 4 attempts (2s each, 0/1 bytes received)\n\
    \  line: 115200 baud 8N1, set and read back OK\n\
    \  check: device powered, booted and running AgentTool; the device's baud rate \
     (--baud); the port";
  check
    "serial_silence_single_attempt"
    (contains
       ~sub:"after 1 attempt (1s, 0/1 bytes received)"
       (Error.message (link 1 (Error.Timeout { secs = 1.0; got = 0; want = 1 }))));
  let msg = Error.message (link 1 (Error.Timeout { secs = 15.0; got = 3; want = 100 })) in
  check
    "serial_stall_message"
    (contains ~sub:"stopped mid-frame after 1 attempt (15s of silence, 3/100 bytes" msg);
  check "serial_stall_line" (contains ~sub:"line: 115200 baud 8N1" msg);
  let msg = Error.message (link 4 (Error.Bad_sync { got = 0; expected = 0x5A })) in
  check
    "serial_garbage_message"
    (contains
       ~sub:"bad response sync byte 0x00 (expected 0x5A) on /dev/ttyUSB1 after 4 attempts"
       msg);
  check "serial_garbage_hints_baud" (contains ~sub:"--baud" msg);
  check
    "serial_link_never_says_emulator"
    (not (contains ~sub:"emulator" (Error.message silence ^ msg)));
  (* The FIFO path keeps its own wording. *)
  check
    "fifo_timeout_names_emulator"
    (contains
       ~sub:"no response from emulator"
       (Error.message (Error.Timeout { secs = 1.0; got = 0; want = 1 })));
  summary "oat error checks"
;;
