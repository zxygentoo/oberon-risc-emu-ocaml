(* Microbenchmarks for the OCaml port: boot throughput (a realistic mixed
   workload) and raw single-step rate (peak CPU throughput). Build with the
   release profile for representative numbers:

     dune exec --profile release bench/bench.exe

   Cross-port comparison against the Rust binary is in bench/compare.sh, which
   times the identical `--headless --frames` workload on both. *)

open Risc_core

let time_it f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  Unix.gettimeofday () -. t0, r
;;

let copy_to_temp src =
  let tmp = Filename.temp_file "oberon_bench_" ".dsk" in
  let ic = open_in_bin src
  and oc = open_out_bin tmp in
  output_string oc (really_input_string ic (in_channel_length ic));
  close_in ic;
  close_out oc;
  tmp
;;

(* One boot of the bundled image for [frames] synthetic-clock frames (a realistic
   mix of CPU, the SD-card disk protocol, MMIO, and framebuffer writes); returns
   the elapsed seconds. *)
let boot_once disk frames =
  let tmp = copy_to_temp disk in
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
       fst (time_it (fun () -> Headless.run_frames risc frames)))
;;

let bench_boot disk frames =
  ignore (boot_once disk frames : float) (* warm up *);
  let dt = boot_once disk frames in
  Printf.printf
    "boot   %4d frames  %7.1f ms  (%6.0f frames/s)\n"
    frames
    (dt *. 1000.)
    (float_of_int frames /. dt)
;;

(* Peak single-step rate: a tight 6-instruction loop (ALU + store + load +
   backward branch) executed [steps] times. *)
module F = Risc.For_tests

let reg q u v a b op ci =
  (q lsl 30)
  lor (u lsl 29)
  lor (v lsl 28)
  lor (a lsl 24)
  lor (b lsl 20)
  lor (op lsl 16)
  lor ci
;;

let mem u v a b off =
  0x8000_0000
  lor (u lsl 29)
  lor (v lsl 28)
  lor (a lsl 24)
  lor (b lsl 20)
  lor (off land 0x000F_FFFF)
;;

let br_imm cond off = 0xE000_0000 lor (cond lsl 24) lor (off land 0x00FF_FFFF)

let bench_cpu steps =
  let make () =
    let r = Risc.make () in
    F.set_pc r 0;
    (F.regs r).(2) <- 3;
    (F.regs r).(3) <- 5;
    (F.regs r).(5) <- 0x100;
    (* a RAM address for the store/load *)
    let body =
      [| reg 0 0 0 1 1 8 2 (* ADD R1 = R1 + R2 *)
       ; reg 0 0 0 2 2 9 3 (* SUB R2 = R2 - R3 *)
       ; reg 0 0 0 4 1 4 2 (* AND R4 = R1 & R2 *)
       ; mem 1 0 4 5 0 (* store R4 -> [R5] *)
       ; mem 0 0 6 5 0 (* load  [R5] -> R6 *)
       ; br_imm 7 (-6) (* branch always -> back to word 0 *)
      |]
    in
    Array.iteri (fun i w -> (F.ram r).(i) <- w) body;
    r
  in
  let warm = make () in
  for _ = 1 to 1_000_000 do
    F.single_step warm
  done;
  let r = make () in
  let dt, () =
    time_it (fun () ->
      for _ = 1 to steps do
        F.single_step r
      done)
  in
  Printf.printf
    "cpu  %4dM steps  %7.1f ms  (%6.1f Minstr/s)\n"
    (steps / 1_000_000)
    (dt *. 1000.)
    (float_of_int steps /. dt /. 1e6)
;;

let () =
  let disk =
    if Array.length Sys.argv > 1 then Sys.argv.(1) else "DiskImage/Oberon-2020-08-18.dsk"
  in
  bench_boot disk 2000;
  bench_cpu 200_000_000
;;
