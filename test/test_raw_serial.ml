(* Raw serial line test (POSIX), ported from raw_serial.rs. /dev/null is always
   writable, and reads hit EOF -> 0. Driven through the {!Risc_core.Io.serial}
   interface. *)

open Risc_core
open Test_harness

let () =
  let s = Raw_serial.to_serial (Raw_serial.create "/dev/null" "/dev/null") in
  check "tx_ready" (s.Io.serial_read_status () land 2 <> 0);
  eq "reads_zero" (s.Io.serial_read_data ()) 0;
  (* Writing to /dev/null is accepted without error. *)
  s.Io.serial_write_data (Char.code 'x');
  summary "raw_serial checks"
;;
