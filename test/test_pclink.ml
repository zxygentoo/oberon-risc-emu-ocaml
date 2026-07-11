(* PCLink protocol tests, ported from the Rust pclink.rs tests. They drive the
   device through its public {!Risc_core.Io.serial} interface ([to_serial]), so
   they exercise get_job/read_data/write_data exactly as the CPU would. *)

open Risc_core
open Test_harness

let ack = 0x10
let rec_mode = 0x21
let snd_mode = 0x22
let with_scratch f = Test_harness.with_scratch ~prefix:"oberon_pclink_" f

let write_file dir name content =
  Test_harness.write_file (Filename.concat dir name) content
;;

let read_file dir name = Test_harness.read_file (Filename.concat dir name)

let () =
  (* idle status is xmit ready, not active *)
  with_scratch (fun dir ->
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eq "idle_status" (s.Io.serial_read_status ()) 2);
  (* REC: send a host file to Oberon *)
  with_scratch (fun dir ->
    write_file dir "payload.txt" "Hello, Oberon!";
    write_file dir "PCLink.REC" "payload.txt";
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eq "rec_active" (s.Io.serial_read_status ()) 3;
    eq "rec_mode_byte" (s.Io.serial_read_data ()) rec_mode;
    s.Io.serial_write_data ack;
    String.iter
      (fun c -> eq "rec_name_byte" (s.Io.serial_read_data ()) (Char.code c))
      "payload.txt\000";
    eq "rec_block_len" (s.Io.serial_read_data ()) 14;
    let buf = Buffer.create 14 in
    for _ = 1 to 14 do
      Buffer.add_char buf (Char.chr (s.Io.serial_read_data ()))
    done;
    check "rec_payload" (Buffer.contents buf = "Hello, Oberon!");
    eq "rec_eof" (s.Io.serial_read_data ()) 0;
    eq "rec_idle_again" (s.Io.serial_read_status ()) 2);
  (* REC: multi-block file (600 bytes -> length-prefixed 255, 255, 90, then 0) *)
  with_scratch (fun dir ->
    let payload = String.init 600 (fun i -> Char.chr (i mod 251)) in
    write_file dir "big.bin" payload;
    write_file dir "PCLink.REC" "big.bin";
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eq "rec2_active" (s.Io.serial_read_status ()) 3;
    eq "rec2_mode" (s.Io.serial_read_data ()) rec_mode;
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
    eq "rec2_idle" (s.Io.serial_read_status ()) 2);
  (* SND: receive a file from Oberon into a host file *)
  with_scratch (fun dir ->
    write_file dir "PCLink.SND" "out.txt";
    let s = Pclink.to_serial (Pclink.in_dir dir) in
    eq "snd_active" (s.Io.serial_read_status ()) 3;
    eq "snd_mode_byte" (s.Io.serial_read_data ()) snd_mode;
    s.Io.serial_write_data ack;
    (* echoed filename ("out.txt") + NUL = 8 bytes *)
    for _ = 1 to 8 do
      ignore (s.Io.serial_read_data ())
    done;
    (* one block of "Hi": length byte then the two bytes *)
    s.Io.serial_write_data 2;
    s.Io.serial_write_data (Char.code 'H');
    s.Io.serial_write_data (Char.code 'i');
    eq "snd_completion_ack" (s.Io.serial_read_data ()) ack;
    eq "snd_idle" (s.Io.serial_read_status ()) 2;
    check "snd_file_contents" (read_file dir "out.txt" = "Hi"));
  summary "pclink checks"
;;
