(* Structural checks on the embedded toolchain seeds. A missing or renamed crunched
   asset otherwise fails only at builder runtime — and for the EO seed, nothing else in
   the default test run would notice at all. *)

open Oberon_tools
open Test_harness

let check_seed tag (seed : Pipeline.seed) =
  check (tag ^ "_toolchain_nonempty") (seed.toolchain <> []);
  let names = List.map fst seed.toolchain in
  check
    (tag ^ "_names_unique")
    (List.length (List.sort_uniq compare names) = List.length names);
  check (tag ^ "_has_innercore") (List.mem_assoc "InnerCore" seed.toolchain);
  check
    (tag ^ "_golden_is_the_toolchain_innercore")
    (List.assoc "InnerCore" seed.toolchain = seed.golden_inner_core);
  (* The inner core parses as a record image and sets up the boot registers. *)
  let r = Risc_core.Risc.make () in
  Risc_core.Risc.For_shim.configure_shim r (8 * 1024 * 1024);
  match Risc_core.Risc.For_shim.boot_inner_core r seed.golden_inner_core 0x8_0000 with
  | () -> check (tag ^ "_innercore_loads") true
  | exception Failure e -> check (Printf.sprintf "%s_innercore_loads (%s)" tag e) false
;;

let () =
  check_seed "po" Seed.po;
  check_seed "eo" Seed.eo;
  summary "seed checks"
;;
