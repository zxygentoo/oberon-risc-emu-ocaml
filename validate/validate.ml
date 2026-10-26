(* Standalone headless validator: boot a disk image (in memory, leaving it as it was)
   for N synthetic-clock frames and print FNV-1a hashes, mirroring the Rust
   `risc --headless --frames N`. Used to check the core is bit-exact against the
   Rust golden hashes without SDL. Not part of the shipped emulator.

   usage: validate <disk-image> <frames> *)

open Oberon_risc

let () =
  let src, frames =
    match Sys.argv with
    | [| _; src; frames |] ->
      (match int_of_string_opt frames with
       | Some n when n >= 1 -> src, n
       | _ ->
         prerr_endline "validate: <frames> must be a count, at least 1";
         exit 2)
    | _ ->
      prerr_endline "usage: validate <disk-image> <frames>";
      exit 2
  in
  let disk = Disk.of_string (In_channel.with_open_bin src In_channel.input_all) in
  let risc = Headless.standard_machine ~disk Clipboard.noop_host in
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
    words
;;
