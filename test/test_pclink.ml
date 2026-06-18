(* PCLink protocol tests, ported from the Rust pclink.rs tests. They drive the
   device through its public {!Risc_core.Io.serial} interface ([to_serial]), so
   they exercise get_job/read_data/write_data exactly as the CPU would. *)

open Risc_core

let ack = 0x10
let rec_mode = 0x21
let snd_mode = 0x22
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

let counter = ref 0

let scratch () =
  incr counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "oberon_pclink_%d_%d" (Unix.getpid ()) !counter)
  in
  Unix.mkdir dir 0o755;
  dir
;;

let rmrf dir =
  (try
     Array.iter
       (fun f ->
          try Sys.remove (Filename.concat dir f) with
          | Sys_error _ -> ())
       (Sys.readdir dir)
   with
   | Sys_error _ -> ());
  try Unix.rmdir dir with
  | Unix.Unix_error _ -> ()
;;

let write_file dir name content =
  let oc = open_out_bin (Filename.concat dir name) in
  output_string oc content;
  close_out oc
;;

let read_file dir name =
  let ic = open_in_bin (Filename.concat dir name) in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let with_scratch f =
  let dir = scratch () in
  Fun.protect ~finally:(fun () -> rmrf dir) (fun () -> f dir)
;;

let () =
  (* idle status is xmit ready, not active *)
  with_scratch (fun dir ->
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eqx "idle_status" (s.Io.serial_read_status ()) 2);
  (* REC: send a host file to Oberon *)
  with_scratch (fun dir ->
    write_file dir "payload.txt" "Hello, Oberon!";
    write_file dir "PCLink.REC" "payload.txt";
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eqx "rec_active" (s.Io.serial_read_status ()) 3;
    eqx "rec_mode_byte" (s.Io.serial_read_data ()) rec_mode;
    s.Io.serial_write_data ack;
    String.iter
      (fun c -> eqx "rec_name_byte" (s.Io.serial_read_data ()) (Char.code c))
      "payload.txt\000";
    eqx "rec_block_len" (s.Io.serial_read_data ()) 14;
    let buf = Buffer.create 14 in
    for _ = 1 to 14 do
      Buffer.add_char buf (Char.chr (s.Io.serial_read_data ()))
    done;
    check "rec_payload" (Buffer.contents buf = "Hello, Oberon!");
    eqx "rec_eof" (s.Io.serial_read_data ()) 0;
    eqx "rec_idle_again" (s.Io.serial_read_status ()) 2);
  (* REC: multi-block file (600 bytes -> length-prefixed 255, 255, 90, then 0) *)
  with_scratch (fun dir ->
    let payload = String.init 600 (fun i -> Char.chr (i mod 251)) in
    write_file dir "big.bin" payload;
    write_file dir "PCLink.REC" "big.bin";
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eqx "rec2_active" (s.Io.serial_read_status ()) 3;
    eqx "rec2_mode" (s.Io.serial_read_data ()) rec_mode;
    s.Io.serial_write_data ack;
    (* filename ("big.bin") + NUL = 8 bytes *)
    for _ = 0 to String.length "big.bin" do
      ignore (s.Io.serial_read_data ())
    done;
    let got = Buffer.create 600 in
    let rec blocks acc =
      let len = s.Io.serial_read_data () in
      if len = 0
      then List.rev (0 :: acc)
      else (
        for _ = 1 to len do
          Buffer.add_char got (Char.chr (s.Io.serial_read_data ()))
        done;
        blocks (len :: acc))
    in
    check "rec2_lengths" (blocks [] = [ 255; 255; 90; 0 ]);
    check "rec2_payload" (Buffer.contents got = payload);
    eqx "rec2_idle" (s.Io.serial_read_status ()) 2);
  (* SND: receive a file from Oberon into a host file *)
  with_scratch (fun dir ->
    write_file dir "PCLink.SND" "out.txt";
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eqx "snd_active" (s.Io.serial_read_status ()) 3;
    eqx "snd_mode_byte" (s.Io.serial_read_data ()) snd_mode;
    s.Io.serial_write_data ack;
    (* echoed filename ("out.txt") + NUL = 8 bytes *)
    for _ = 1 to 8 do
      ignore (s.Io.serial_read_data ())
    done;
    (* one block of "Hi": length byte then the two bytes *)
    s.Io.serial_write_data 2;
    s.Io.serial_write_data (Char.code 'H');
    s.Io.serial_write_data (Char.code 'i');
    eqx "snd_completion_ack" (s.Io.serial_read_data ()) ack;
    eqx "snd_idle" (s.Io.serial_read_status ()) 2;
    check "snd_file_contents" (read_file dir "out.txt" = "Hi"));
  if !failures = 0
  then Printf.printf "ok: %d pclink checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d pclink checks failed\n" !failures !total;
    exit 1)
;;
