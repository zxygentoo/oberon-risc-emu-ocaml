(* Layer 1 of the differential lockstep: the software FP / idiv routines run live
   against the C reference (the vendored risc-fp.c, called over FFI) on random
   inputs — extending the frozen fp_vectors to the unbounded u32 space.

   Gated behind the `cosim` dune alias (needs a C toolchain + the vendored C), so
   it is not part of the default `dune test`. Run with: dune build @cosim *)

open Risc_core
module Q = QCheck2
module G = QCheck2.Gen

external c_fp_add : int -> int -> bool -> bool -> int = "ml_c_fp_add"
external c_fp_mul : int -> int -> int = "ml_c_fp_mul"
external c_fp_div : int -> int -> int = "ml_c_fp_div"
external c_idiv : int -> int -> bool -> int * int = "ml_c_idiv"

let u32 = G.int_range 0 0xFFFF_FFFF
let count = 100_000
let h x = Printf.sprintf "0x%08X" x

let props =
  [ Q.Test.make
      ~name:"fp_add matches C"
      ~count
      ~print:(fun (x, y, u, v) -> Printf.sprintf "x=%s y=%s u=%b v=%b" (h x) (h y) u v)
      (G.tup4 u32 u32 G.bool G.bool)
      (fun (x, y, u, v) -> Fp.fp_add x y u v = c_fp_add x y u v)
  ; Q.Test.make
      ~name:"fp_mul matches C"
      ~count
      ~print:(fun (x, y) -> Printf.sprintf "x=%s y=%s" (h x) (h y))
      (G.pair u32 u32)
      (fun (x, y) -> Fp.fp_mul x y = c_fp_mul x y)
  ; Q.Test.make
      ~name:"fp_div matches C"
      ~count
      ~print:(fun (x, y) -> Printf.sprintf "x=%s y=%s" (h x) (h y))
      (G.pair u32 u32)
      (fun (x, y) -> Fp.fp_div x y = c_fp_div x y)
  ; Q.Test.make
      ~name:"idiv matches C"
      ~count
      ~print:(fun (x, y, s) -> Printf.sprintf "x=%s y=%s signed=%b" (h x) (h y) s)
      (G.triple u32 u32 G.bool)
      (fun (x, y, s) ->
         let d = Fp.idiv x y s in
         (d.Fp.quot, d.Fp.rem) = c_idiv x y s)
  ]
;;

let () = QCheck_base_runner.run_tests_main props
