(* Microbenchmarks for the OCaml port: boot throughput (a realistic mixed
   workload) and raw single-step rate (peak CPU throughput). Build with the
   release profile for representative numbers:

     dune exec --profile release bench/bench.exe

   See bench/README.md, including how to compare against the Rust port by timing
   the identical `--headless --frames` workload on both. *)

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
       let risc = Headless.standard_machine ~disk:tmp Clipboard.noop_host in
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
   backward branch) executed [steps] times. Instructions assemble through the
   shared {!Risc5_isa} codec. *)
module F = Risc.For_tests

let alu op a b c =
  Risc5_isa.(encode (Alu { op; u = false; v = false; a; b; operand = Reg c }))
;;

let stw a base = Risc5_isa.(encode (Store { size = W; a; base; off = 0 }))
let ldw a base = Risc5_isa.(encode (Load { size = W; a; base; off = 0 }))

let b_always off =
  Risc5_isa.(
    encode (Branch { cond = True; neg = false; link = false; target = To_off off }))
;;

let bench_cpu steps =
  let make () =
    let r = Risc.make () in
    F.set_pc r 0;
    (F.regs r).(2) <- 3;
    (F.regs r).(3) <- 5;
    (F.regs r).(5) <- 0x100;
    (* a RAM address for the store/load *)
    let body =
      let open Risc5_isa in
      [| alu Add 1 1 2 (* ADD R1 = R1 + R2 *)
       ; alu Sub 2 2 3 (* SUB R2 = R2 - R3 *)
       ; alu And 4 1 2 (* AND R4 = R1 & R2 *)
       ; stw 4 5 (* store R4 -> [R5] *)
       ; ldw 6 5 (* load  [R5] -> R6 *)
       ; b_always (-6) (* branch always -> back to word 0 *)
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
