(* Raw serial line test (POSIX), ported from raw_serial.rs. /dev/null is always
   writable, and reads hit EOF -> 0. Driven through the {!Risc_core.Io.serial}
   interface. *)

open Risc_core
open Test_harness

let rx_ready (s : Io.serial) = s.serial_read_status () land 1 <> 0

let () =
  let s = Raw_serial.to_serial (Raw_serial.create "/dev/null" "/dev/null") in
  check "tx_ready" (s.Io.serial_read_status () land 2 <> 0);
  (* /dev/null is at end of input from the start: nothing is ready. *)
  check "eof_not_rx_ready" (not (rx_ready s));
  eq "reads_zero" (s.Io.serial_read_data ()) 0;
  (* Writing to /dev/null is accepted without error. *)
  s.Io.serial_write_data (Char.code 'x');
  (* A FIFO whose writer sent a short frame and closed: the bytes come through,
     then end of input is "no byte ready" — not the endless rx-ready NULs the C
     reports, which would complete the frame with zeros. *)
  with_scratch ~prefix:"raw_serial" (fun dir ->
    let fifo = Filename.concat dir "in" in
    Unix.mkfifo fifo 0o600;
    let s = Raw_serial.to_serial (Raw_serial.create fifo "/dev/null") in
    check "no_writer_yet_not_ready" (not (rx_ready s));
    let w = Unix.openfile fifo [ Unix.O_WRONLY; Unix.O_NONBLOCK ] 0 in
    ignore (Unix.write_substring w "\xA5\x01" 0 2);
    Unix.close w;
    check "byte_ready" (rx_ready s);
    check "ready_is_stable" (rx_ready s);
    eq "first_byte" (s.Io.serial_read_data ()) 0xA5;
    check "second_byte_ready" (rx_ready s);
    eq "second_byte" (s.Io.serial_read_data ()) 0x01;
    check "writer_gone_not_ready" (not (rx_ready s));
    check "still_not_ready" (not (rx_ready s));
    (* A new writer is heard again. *)
    let w = Unix.openfile fifo [ Unix.O_WRONLY; Unix.O_NONBLOCK ] 0 in
    ignore (Unix.write_substring w "z" 0 1);
    check "new_writer_ready" (rx_ready s);
    eq "new_writer_byte" (s.Io.serial_read_data ()) (Char.code 'z');
    Unix.close w);
  summary "raw_serial checks"
;;
