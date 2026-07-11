(* Boot-golden test: the deterministic 60 Hz boot of the bundled Oberon image
   hashes to fixed values. Asserting the framebuffer + CPU-state FNV-1a against
   the frozen goldens exercises the whole machine end-to-end — CPU, software FP,
   the SD-card disk protocol, MMIO, and framebuffer damage tracking — in one
   check. One continuous boot is checked at every checkpoint, exactly like the
   Rust suite's BOOT_GOLDEN (whose values were produced against the live C
   reference at each frame). *)

open Risc_core
open Test_harness

let disk_image = "../DiskImage/Oberon-2020-08-18.dsk"

(* frames, framebuffer_fnv1a, state_fnv1a (the Rust/C BOOT_GOLDEN checkpoints) *)
let goldens =
  [ 1, 0xf5edab31b6802325L, 0x03869b4b0b926433L
  ; 2, 0xf5edab31b6802325L, 0x2926f3cc7568ea25L
  ; 5, 0xf5edab31b6802325L, 0xdba6e0006e93fd52L
  ; 15, 0xf5edab31b6802325L, 0x1f7a42198e5e3891L
  ; 45, 0xb9bdbf56ba51298dL, 0x66a3e6fd77a6b491L
  ; 120, 0xb9bdbf56ba51298dL, 0x66a3e6fd77a6b491L
  ; 250, 0xb9bdbf56ba51298dL, 0x7531e8819ea3aac1L
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

(* Boot writes to the disk, so run against a throwaway copy. Devices are wired exactly as
   the frontend does ({!Headless.standard_machine}), since the goldens were produced with
   that configuration. *)
let with_boot_machine f =
  let tmp = copy_to_temp disk_image in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove tmp with
      | Sys_error _ -> ())
    (fun () -> f (Headless.standard_machine ~disk:tmp Clipboard.noop_host))
;;

let check_hashes frames risc (want_fb, want_state) =
  eqx64
    (Printf.sprintf "frames=%d framebuffer_fnv1a" frames)
    (Headless.framebuffer_hash risc)
    want_fb;
  eqx64
    (Printf.sprintf "frames=%d state_fnv1a" frames)
    (Headless.state_hash risc)
    want_state
;;

let () =
  (* One continuous boot, checked at every checkpoint (the Rust loop's schedule:
     set_time frame*16ms, then one frame of cycles). *)
  with_boot_machine (fun risc ->
    let frame_ms = 1000 / Headless.fps in
    let last_frame, _, _ = List.nth goldens (List.length goldens - 1) in
    let remaining = ref goldens in
    for frame = 0 to last_frame - 1 do
      Risc.set_time risc (U32.wrap (frame * frame_ms));
      Risc.run risc (Headless.cpu_hz / Headless.fps);
      match !remaining with
      | (f, want_fb, want_state) :: rest when f = frame + 1 ->
        check_hashes f risc (want_fb, want_state);
        remaining := rest
      | _ -> ()
    done);
  (* Pin {!Headless.run_frames}' schedule too, by re-checking the first checkpoint
     through it on a fresh boot. *)
  (match goldens with
   | (f, want_fb, want_state) :: _ ->
     with_boot_machine (fun risc ->
       Headless.run_frames risc f;
       check_hashes f risc (want_fb, want_state))
   | [] -> ());
  summary "boot golden checks"
;;
