(** The [risc] binary: parse the CLI and hand the validated config to {!App}. The
    window/event loop, machine wiring, and headless runner live in the frontend
    library ({!App}, {!Cli}, {!Ps2}, {!Render}); the pure machine — CPU, software FP,
    MMIO, disk, serial, clipboard bridge — lives in {!Risc_core}. *)

let fail_with m =
  Printf.eprintf "risc: %s\n%!" m;
  exit 1
;;

let () =
  match Cli.parse () with
  | Cli.Help ->
    print_string Cli.usage;
    exit 0
  | Cli.Invalid msg -> fail_with msg
  | Cli.Config cfg ->
    (try App.run cfg with
     | Sys_error m -> fail_with m
     | Unix.Unix_error (e, f, a) ->
       fail_with (Printf.sprintf "%s (%s %s)" (Unix.error_message e) f a))
;;
