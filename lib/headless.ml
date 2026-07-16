(** Deterministic headless driver and state hashing (port of [headless.rs]).

    The synthetic 60 Hz clock (not wall time) makes a boot byte-for-byte
    reproducible, which is exactly what the C-derived goldens rely on. *)

(** The FPGA system clock the emulator models. *)
let cpu_hz = 25_000_000

(** Frames per second the frontend (and these helpers) pace the clock at. *)
let fps = 60

(** The standard machine wiring shared by the frontend, the golden boot test, and the
    bench: PCLink serial, a clipboard bridge over [host], and the disk as SPI slave 1.
    The golden hashes were produced with exactly this configuration. *)
let standard_machine ?disk host =
  let risc = Risc.make () in
  Risc.set_serial risc (Pclink.to_serial (Pclink.create ()));
  Risc.set_clipboard risc (Clipboard.to_clipboard (Clipboard.create host));
  Risc.set_spi risc 1 (Disk.to_spi (Disk.create disk));
  risc
;;

(** Advance [risc] by [frames], driving the fixed 60 Hz synthetic clock the
    frontend uses but independent of wall time, so the run is reproducible.
    [on_frame] observes the machine after each frame (1-based; used by
    [--shot-frames]); it must not perturb the state if determinism matters. *)
let run_frames ?(on_frame = fun _ -> ()) risc frames =
  let frame_ms = 1000 / fps in
  for frame = 0 to frames - 1 do
    Risc.set_time risc (U32.wrap (frame * frame_ms));
    Risc.run risc (cpu_hz / fps);
    on_frame (frame + 1)
  done
;;

let fnv_offset = 0xcbf2_9ce4_8422_2325L
let fnv_prime = 0x0000_0100_0000_01b3L

(* Fold one word (as little-endian bytes) into an FNV-1a accumulator. *)
let fnv1a_word h w =
  let step h k =
    Int64.mul (Int64.logxor h (Int64.of_int ((w lsr (k * 8)) land 0xFF))) fnv_prime
  in
  step (step (step (step h 0) 1) 2) 3
;;

(** FNV-1a of the active framebuffer (the visible [fb_width * fb_height] words). *)
let framebuffer_hash risc =
  let words = Risc.fb_width risc * Risc.fb_height risc in
  let rec loop i h =
    if i = words then h else loop (i + 1) (fnv1a_word h (Risc.framebuffer_word risc i))
  in
  loop 0 fnv_offset
;;

(** FNV-1a of the architectural CPU state (PC, R0..R15, H, flags). *)
let state_hash risc =
  let s = Risc.cpu_state risc in
  let words = (s.Risc.pc :: Array.to_list s.Risc.r) @ [ s.Risc.h; s.Risc.flags ] in
  List.fold_left fnv1a_word fnv_offset words
;;
