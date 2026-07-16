(** oat — oberon-agent-tool — stateless CLI driver for [AgentTool.Mod] on a live
    Project Oberon or Extended Oberon system, over an emulator FIFO pair or a real
    serial device. See [oat/skill/] for the agent-side rules.

    This file is only the process contract (as [main.rs] is in the Rust oat): parse
    the CLI, run, and map failures to the documented exit codes — 0 success, 1
    tool-level, 2 transport/protocol/argument — under the "oat: error: " prefix.
    Everything else lives in {!Oat.Cli}. *)

let fail_with code msg =
  Printf.eprintf "oat: error: %s\n" msg;
  exit code
;;

let () =
  match Oat.Cli.parse_argv (List.tl (Array.to_list Sys.argv)) with
  | Oat.Cli.Help -> print_string Oat.Cli.usage
  | Oat.Cli.Version -> Printf.printf "oat %s\n" Oberon_tools.Tool_cli.version
  | Oat.Cli.Invalid msg -> fail_with 2 (msg ^ "\nFor more information, try '--help'.")
  | Oat.Cli.Config cfg ->
    (try Oat.Cli.run cfg with
     | Oat.Error.Error e -> fail_with (Oat.Error.exit_code e) (Oat.Error.message e)
     | Sys_error m -> fail_with 2 m
     | Unix.Unix_error (e, fn, arg) ->
       fail_with 2 (Printf.sprintf "%s (%s %s)" (Unix.error_message e) fn arg))
;;
