(* SD-card / SPI disk tests, ported from the Rust disk.rs tests. They drive the
   disk through its public {!Risc_core.Io.spi} interface ([to_spi]). *)

open Risc_core
open Test_harness

(* A throwaway image file containing [bytes]; caller removes it. *)
let temp_with bytes =
  let path = Filename.temp_file "oberon_disk_" ".img" in
  let oc = open_out_bin path in
  output_bytes oc bytes;
  close_out oc;
  path
;;

(* A 512-byte sector from up to 128 little-endian words. *)
let sector_bytes words =
  let b = Bytes.make 512 '\000' in
  Array.iteri
    (fun i w ->
       Bytes.set b (i * 4) (Char.chr (w land 0xFF));
       Bytes.set b ((i * 4) + 1) (Char.chr ((w lsr 8) land 0xFF));
       Bytes.set b ((i * 4) + 2) (Char.chr ((w lsr 16) land 0xFF));
       Bytes.set b ((i * 4) + 3) (Char.chr ((w lsr 24) land 0xFF)))
    words;
  b
;;

let send_command (s : Io.spi) cmd arg =
  s.spi_write_data cmd;
  s.spi_write_data ((arg lsr 24) land 0xFF);
  s.spi_write_data ((arg lsr 16) land 0xFF);
  s.spi_write_data ((arg lsr 8) land 0xFF);
  s.spi_write_data (arg land 0xFF);
  s.spi_write_data 0xFF (* CRC byte, ignored *)
;;

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

let () =
  (* A filesystem-only image (first word 0x9B1EA38D) is detected and rebased. *)
  (let img = Bytes.make 1024 '\000' in
   Bytes.set img 0 '\x8D';
   Bytes.set img 1 '\xA3';
   Bytes.set img 2 '\x1E';
   Bytes.set img 3 '\x9B';
   let path = temp_with img in
   eq "fs_only_offset" (Disk.For_tests.offset (Disk.create (Some path))) 0x8_0002;
   Sys.remove path;
   let plain = temp_with (Bytes.make 1024 '\000') in
   eq "plain_offset" (Disk.For_tests.offset (Disk.create (Some plain))) 0;
   Sys.remove plain);
  (* CMD17 (81): R1 response, data token, then the 128-word sector. *)
  (let img = Bytes.make (512 * 4) '\000' in
   let s1 = Array.init 128 (fun i -> 0x1000_0000 + i) in
   Bytes.blit (sector_bytes s1) 0 img 512 512;
   let path = temp_with img in
   let s = Disk.to_spi (Disk.create (Some path)) in
   send_command s 81 1;
   let resp = Array.make 130 0 in
   for i = 0 to 129 do
     s.spi_write_data 0xFF;
     resp.(i) <- s.spi_read_data ()
   done;
   eq "read_r1" resp.(0) 0;
   eq "read_data_token" resp.(1) 254;
   let payload_ok = ref true in
   Array.iteri (fun i w -> if resp.(2 + i) <> w then payload_ok := false) s1;
   check "read_sector_payload" !payload_ok;
   s.spi_write_data 0xFF;
   eq "read_idle_after_payload" (s.spi_read_data ()) 255;
   Sys.remove path);
  (* CMD24 (88): a written sector reaches the backing file. *)
  (let path = temp_with (Bytes.make (512 * 4) '\000') in
   let s2 = Array.init 128 (fun i -> 0xABCD_0000 + i) in
   let s = Disk.to_spi (Disk.create (Some path)) in
   send_command s 88 2;
   s.spi_write_data 0xFF;
   eq "write_r1" (s.spi_read_data ()) 0;
   s.spi_write_data 254;
   Array.iter (fun w -> s.spi_write_data w) s2;
   s.spi_write_data 0xFF;
   s.spi_write_data 0xFF;
   s.spi_write_data 0xFF;
   eq "write_accepted_token" (s.spi_read_data ()) 5;
   check
     "write_persisted"
     (String.sub (read_file path) 1024 512 = Bytes.to_string (sector_bytes s2));
   Sys.remove path);
  (* A diskless card reads idle (255). *)
  (let s = Disk.to_spi (Disk.create None) in
   s.spi_write_data 0xFF;
   eq "diskless_idle" (s.spi_read_data ()) 255);
  (* An unmodelled command (CMD0) returns a single status byte. *)
  (let path = temp_with (Bytes.make 512 '\000') in
   let s = Disk.to_spi (Disk.create (Some path)) in
   send_command s 0 0;
   s.spi_write_data 0xFF;
   eq "unknown_command" (s.spi_read_data ()) 0;
   Sys.remove path);
  summary "disk checks"
;;
