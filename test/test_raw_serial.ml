(* Raw serial line test (POSIX), ported from raw_serial.rs. /dev/null is always
   writable, and reads hit EOF -> 0. Driven through the {!Risc_core.Io.serial}
   interface. *)

open Risc_core

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
    Printf.printf "FAIL: %s: got %d, want %d\n" name got want)
;;

let () =
  let s = Raw_serial.to_serial (Raw_serial.create "/dev/null" "/dev/null") in
  check "tx_ready" (s.Io.serial_read_status () land 2 <> 0);
  eqx "reads_zero" (s.Io.serial_read_data ()) 0;
  (* Writing to /dev/null is accepted without error. *)
  s.Io.serial_write_data (Char.code 'x');
  if !failures = 0
  then Printf.printf "ok: %d raw_serial checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d raw_serial checks failed\n" !failures !total;
    exit 1)
;;
