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
  summary "oat error checks"
;;
