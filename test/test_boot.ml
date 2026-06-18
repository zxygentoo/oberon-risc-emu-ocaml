(* Boot-golden test: the deterministic 60 Hz boot of the bundled Oberon image
   hashes to fixed values. Asserting the framebuffer + CPU-state FNV-1a against
   the frozen goldens (identical to the Rust reference's --headless --frames
   output) exercises the whole machine end-to-end — CPU, software FP, the SD-card
   disk protocol, MMIO, and framebuffer damage tracking — in one check. *)

open Risc_core

let disk_image = "../DiskImage/Oberon-2020-08-18.dsk"

(* frames, framebuffer_fnv1a, state_fnv1a (from the Rust golden) *)
let goldens =
  [ 1, 0xf5edab31b6802325L, 0x03869b4b0b926433L
  ; 60, 0xb9bdbf56ba51298dL, 0x66a3e6fd77a6b491L
  ]
;;

let copy_to_temp src =
  let tmp = Filename.temp_file "oberon_boot_" ".dsk" in
  let ic = open_in_bin src
  and oc = open_out_bin tmp in
  output_string oc (really_input_string ic (in_channel_length ic));
  close_in ic;
  close_out oc;
  tmp
;;

let boot frames =
  (* Boot writes to the disk, so run against a throwaway copy. Devices are wired
     exactly as the frontend does (PCLink serial + a no-op clipboard + the disk),
     since the golden was produced with that configuration. *)
  let tmp = copy_to_temp disk_image in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove tmp with
      | Sys_error _ -> ())
    (fun () ->
       let risc = Risc.make () in
       Risc.set_serial risc (Pclink.to_serial (Pclink.create ()));
       Risc.set_clipboard
         risc
         (Clipboard.to_clipboard
            (Clipboard.create
               { Clipboard.get_text = (fun () -> None); set_text = (fun _ -> ()) }));
       Risc.set_spi risc 1 (Disk.to_spi (Disk.create (Some tmp)));
       Headless.run_frames risc frames;
       Headless.framebuffer_hash risc, Headless.state_hash risc)
;;

let failures = ref 0

let () =
  List.iter
    (fun (frames, want_fb, want_state) ->
       let fb, state = boot frames in
       if fb <> want_fb
       then (
         incr failures;
         Printf.printf
           "FAIL: frames=%d framebuffer_fnv1a=0x%016Lx, want 0x%016Lx\n"
           frames
           fb
           want_fb);
       if state <> want_state
       then (
         incr failures;
         Printf.printf
           "FAIL: frames=%d state_fnv1a=0x%016Lx, want 0x%016Lx\n"
           frames
           state
           want_state))
    goldens;
  if !failures = 0
  then
    Printf.printf "ok: boot golden hashes match (%d frame counts)\n" (List.length goldens)
  else (
    Printf.printf "FAILED: %d boot golden mismatch(es)\n" !failures;
    exit 1)
;;
