(** The [risc] binary: parse the CLI and hand the validated config to {!App}. The
    window/event loop, machine wiring, and headless runner live in the frontend
    library ({!App}, {!Cli}, {!Ps2}, {!Render}); the pure machine — CPU, software FP,
    MMIO, disk, serial, clipboard bridge — lives in {!Oberon_risc}. *)

(* Exit codes as the host tools: 1 when the run fails, 2 for a usage error. *)
let fail_with m =
  Printf.eprintf "risc: %s\n%!" m;
  exit 1
;;

let () =
  match Cli.parse () with
  | Cli.Help ->
    print_string Cli.usage;
    exit 0
  | Cli.Version ->
    Printf.printf "risc %s\n" Oberon_risc.Version.version;
    exit 0
  | Cli.Invalid msg ->
    Printf.eprintf "risc: %s\nTry 'risc --help'.\n%!" msg;
    exit 2
  | Cli.Config cfg ->
    (try App.run cfg with
     | Sys_error m | Failure m -> fail_with m
     | Unix.Unix_error (e, f, a) ->
       fail_with (Printf.sprintf "%s (%s %s)" (Unix.error_message e) f a))
;;
