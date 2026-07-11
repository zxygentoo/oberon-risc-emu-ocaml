(* Standalone headless validator: boot a throwaway copy of a disk image for N
   synthetic-clock frames and print FNV-1a hashes, mirroring the Rust
   `risc --headless --frames N`. Used to check the core is bit-exact against the
   Rust golden hashes. Not part of the shipped emulator.

   usage: validate <disk-image> <frames> *)

open Risc_core

let copy_to_temp src =
  let tmp = Filename.temp_file "oberon_validate_" ".dsk" in
  let ic = open_in_bin src
  and oc = open_out_bin tmp in
  let len = in_channel_length ic in
  let buf = really_input_string ic len in
  output_string oc buf;
  close_in ic;
  close_out oc;
  tmp
;;

let () =
  let src = Sys.argv.(1) in
  let frames = int_of_string Sys.argv.(2) in
  let tmp = copy_to_temp src in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove tmp with
      | Sys_error _ -> ())
    (fun () ->
       let risc = Headless.standard_machine ~disk:tmp Clipboard.noop_host in
       Headless.run_frames risc frames;
       let words = Risc.fb_width risc * Risc.fb_height risc in
       let rec count_blank i n =
         if i = words
         then n
         else count_blank (i + 1) (if Risc.framebuffer_word risc i = 0 then n + 1 else n)
       in
       Printf.printf
         "frames=%d framebuffer_fnv1a=0x%016Lx state_fnv1a=0x%016Lx blank_words=%d/%d\n"
         frames
         (Headless.framebuffer_hash risc)
         (Headless.state_hash risc)
         (count_blank 0 0)
         words)
;;
