(** oat — oberon-agent-tool — stateless CLI driver for [AgentTool.Mod] on a live
    Project Oberon or Extended Oberon system, over an emulator FIFO pair or a real
    serial device. See [oat/skill/] for the agent-side rules.

    This file is only the process contract: parse the CLI, run, and map failures
    to the documented exit codes — 0 success, 1 tool-level, 2
    transport/protocol/argument — under the "oat: error: " prefix. Everything
    else lives in {!Oat.Cli}. *)

module Cli = Oat.Cli
module Error = Oat.Error

let fail_with code msg =
  Printf.eprintf "oat: error: %s\n" msg;
  exit code
;;

let () =
  match Cli.parse_argv (List.tl (Array.to_list Sys.argv)) with
  | Cli.Help -> print_string Cli.usage
  | Cli.Version -> Printf.printf "oat %s\n" Oberon_tools.Tool_cli.version
  | Cli.Invalid msg -> fail_with 2 (msg ^ "\nFor more information, try '--help'.")
  | Cli.Config cfg ->
    (try Cli.run cfg with
     | Error.Error e -> fail_with (Error.exit_code e) (Error.message e)
     | Sys_error m -> fail_with 2 m
     | Unix.Unix_error (e, fn, arg) ->
       fail_with 2 (Printf.sprintf "%s (%s %s)" (Unix.error_message e) fn arg))
;;
