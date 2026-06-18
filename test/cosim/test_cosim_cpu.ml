(* Layers 2 & 3 of the differential lockstep, against the C reference.

   L2 (single-instruction): one random instruction over random architectural
   state, stepped once in both and compared (full state + 8-word RAM window).
   Covers the whole decode / ALU / shifter / flag / branch space.

   L3 (burst): a region of random non-branch instructions plus random state, run
   as a stream, comparing the full state + region after every step. Reaches what
   the single-instruction sampler can't — instruction *streams* the boot never
   emits: back-to-back fetch/PC progression, store-then-load memory chains, and
   values/flags flowing between ops. Branches are excluded so PC marches through
   the region; we stop the moment PC leaves it (e.g. a self-modified branch), so
   we never fetch from the void.

   Both run with PC = 0 (the region origin). The one intentional divergence
   (MOV-flags-read, 0x53 vs C's 0xD0) is filtered, dynamically too (a store can
   forge one). Gated behind the `cosim` alias. Run with: dune build @cosim *)

open Risc_core
module Q = QCheck2
module G = QCheck2.Gen
module F = Risc.For_tests
module BA = Bigarray.Array1

external cpu_load
  :  (int32, Bigarray.int32_elt, Bigarray.c_layout) BA.t
  -> unit
  = "ml_cpu_load"

external cpu_step : unit -> unit = "ml_cpu_step"

external cpu_dump
  :  (int32, Bigarray.int32_elt, Bigarray.c_layout) BA.t
  -> unit
  = "ml_cpu_dump"

let u32 = G.int_range 0 0xFFFF_FFFF

let is_mov_flags_read ir =
  ir land 0x8000_0000 = 0
  && (ir lsr 16) land 0xF = 0
  && ir land 0x4000_0000 = 0
  && ir land 0x2000_0000 <> 0
  && ir land 0x1000_0000 <> 0
;;

let is_branch ir = ir land 0xC000_0000 = 0xC000_0000

(* Persistent machine + buffers, reused across cases (mirrors the C global). *)
let oc = Risc.make ()
let set32 ba i v = BA.set ba i (Int32.of_int v)
let get32 ba i = Int32.to_int (BA.get ba i) land 0xFFFF_FFFF

let state_of regs_h flags =
  let st = Array.make 19 0 in
  (* PC stays 0; st.[1..17] = R0..R15, H *)
  List.iteri (fun i v -> st.(1 + i) <- v) regs_h;
  st.(18) <- flags;
  st
;;

(* Load [st] (19 words) + [region] (into RAM[0..]) into both machines via [ba]. *)
let load ba st region =
  Array.iteri (fun i v -> set32 ba i v) st;
  Array.iteri (fun i v -> set32 ba (19 + i) v) region;
  cpu_load ba;
  F.set_pc oc st.(0);
  for i = 0 to 15 do
    (F.regs oc).(i) <- st.(1 + i)
  done;
  F.set_h oc st.(17);
  F.set_flags oc st.(18);
  Array.iteri (fun i v -> (F.ram oc).(i) <- v) region
;;

(* Dump C into [ba] and check it equals OCaml's state + RAM[0..region_size-1]. *)
let agree ba region_size =
  cpu_dump ba;
  let ok =
    ref (get32 ba 0 = F.pc oc && get32 ba 17 = F.h oc && get32 ba 18 = F.flags oc)
  in
  for i = 0 to 15 do
    if get32 ba (1 + i) <> (F.regs oc).(i) then ok := false
  done;
  for i = 0 to region_size - 1 do
    if get32 ba (19 + i) <> (F.ram oc).(i) then ok := false
  done;
  !ok
;;

(* ---- L2: single instruction ---------------------------------------------- *)

let ba_single = BA.create Bigarray.int32 Bigarray.c_layout (19 + 8)

let single ir regs_h flags win =
  is_mov_flags_read ir
  ||
  (* RAM[0] = instruction under test, RAM[1..7] = data *)
  let region = Array.of_list (ir :: win) in
  load ba_single (state_of regs_h flags) region;
  F.single_step oc;
  cpu_step ();
  agree ba_single 8
;;

(* ---- L3: burst ----------------------------------------------------------- *)

let region_size = 64
let ba_burst = BA.create Bigarray.int32 Bigarray.c_layout (19 + region_size)

(* Planted code must not branch (would leave the region) or read flags. *)
let sanitize w = if is_branch w || is_mov_flags_read w then 0 else w

let burst code regs_h flags =
  load ba_burst (state_of regs_h flags) (Array.of_list (List.map sanitize code));
  let rec run n =
    if n = 0
    then true
    else (
      let pc = F.pc oc in
      if pc >= region_size
      then true (* PC left the region (e.g. a self-modified branch) — stop *)
      else if is_mov_flags_read (F.ram oc).(pc)
      then true (* a store forged a flags-read at PC — stop before the divergence *)
      else (
        F.single_step oc;
        cpu_step ();
        if agree ba_burst region_size then run (n - 1) else false))
  in
  run region_size
;;

let props =
  [ Q.Test.make
      ~name:"single-instruction lockstep vs C"
      ~count:200_000
      ~print:(fun (ir, _, _, _) -> Printf.sprintf "ir=0x%08X" ir)
      (G.tup4
         u32
         (G.list_size (G.return 17) u32)
         (G.int_range 0 15)
         (G.list_size (G.return 7) u32))
      (fun (ir, regs_h, flags, win) -> single ir regs_h flags win)
  ; Q.Test.make
      ~name:"burst lockstep vs C"
      ~count:5_000
      (G.triple
         (G.list_size (G.return region_size) u32)
         (G.list_size (G.return 17) u32)
         (G.int_range 0 15))
      (fun (code, regs_h, flags) -> burst code regs_h flags)
  ]
;;

let () = QCheck_base_runner.run_tests_main props
