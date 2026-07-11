(* Tool_cli argv-walker tests — the in-process paths. The -h/--version/unknown-option
   arms print and exit by design; they are exercised only end-to-end. *)

open Oberon_tools
open Test_harness

let parse ?flags args = Tool_cli.parse ~name:"t" ~usage:"u" ~help:"h" ?flags args

let () =
  check "positionals_in_order" (parse [ "a"; "b" ] = [ "a"; "b" ]);
  check "no_args" (parse [] = []);
  (* A flag sets its ref and is consumed, wherever it sits in argv. *)
  (let keep = ref false in
   let pos = parse ~flags:[ "--keep", keep ] [ "a"; "--keep"; "b" ] in
   check "flag_set" !keep;
   check "flag_consumed" (pos = [ "a"; "b" ]));
  (* A lone "-" is positional; only "-x..." counts as an option. *)
  check "lone_dash_positional" (parse [ "-" ] = [ "-" ]);
  (* run_reporting passes through f's value on success. *)
  eq "run_reporting_value" (Tool_cli.run_reporting ~name:"t" (fun () -> 42)) 42;
  check "version_nonempty" (Tool_cli.version <> "");
  summary "tool_cli checks"
;;
