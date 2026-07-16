(* CLI-parsing tests for oat (port of the cli.rs tests plus coverage of the
   hand-rolled walker): the serial forms are exclusive and paired, defaults match
   the Rust CLI, and each subcommand arity-checks its positionals. *)

open Oat
open Test_harness

let parse = Cli.parse_argv
let invalid name args = check name (match parse args with Cli.Invalid _ -> true | _ -> false)

let config name args pred =
  match parse args with
  | Cli.Config cfg -> check name (pred cfg)
  | _ -> check name false
;;

let () =
  (* Serial forms: exclusive and paired (open_transport's Rust counterpart relied on
     clap for this; here the parser owns it). *)
  config "serial_alone" [ "--serial"; "p"; "check" ] (fun c ->
    c.Cli.serial = Some (Cli.Device "p"));
  config "fifo_pair" [ "--serial-in"; "a"; "--serial-out"; "b"; "check" ] (fun c ->
    c.Cli.serial = Some (Cli.Fifos { fifo_in = "a"; fifo_out = "b" }));
  (* No serial is accepted at parse time; No_serial is reported later, with context. *)
  config "no_serial_parses" [ "check" ] (fun c -> c.Cli.serial = None);
  invalid
    "serial_conflicts_with_fifos"
    [ "--serial"; "p"; "--serial-in"; "a"; "--serial-out"; "b"; "check" ];
  invalid "serial_in_requires_out" [ "--serial-in"; "a"; "check" ];
  invalid "serial_out_requires_in" [ "--serial-out"; "b"; "check" ];
  (* Defaults match the Rust CLI. *)
  config "defaults" [ "check" ] (fun c ->
    c.Cli.timeout = 15.0
    && c.Cli.baud = 115200
    && c.Cli.char_delay_us = 600
    && c.Cli.retries = 3);
  config "option_values" [ "--timeout"; "2.5"; "--baud"; "19200"; "check" ] (fun c ->
    c.Cli.timeout = 2.5 && c.Cli.baud = 19200);
  config "equals_form" [ "--timeout=2.5"; "check" ] (fun c -> c.Cli.timeout = 2.5);
  invalid "bad_timeout" [ "--timeout"; "abc"; "check" ];
  invalid "negative_retries" [ "--retries"; "-1"; "check" ];
  invalid "missing_value" [ "check"; "--timeout" ];
  (* Subcommands and arities. *)
  config "read" [ "read"; "F.Mod" ] (fun c -> c.Cli.command = Cli.Read "F.Mod");
  config "write" [ "write"; "F.Mod" ] (fun c -> c.Cli.command = Cli.Write "F.Mod");
  config "edit" [ "edit"; "F"; "old"; "new" ] (fun c ->
    c.Cli.command = Cli.Edit { path = "F"; old = "old"; new_ = "new" });
  invalid "edit_arity" [ "edit"; "F"; "old" ];
  config "delete" [ "delete"; "F" ] (fun c -> c.Cli.command = Cli.Delete "F");
  config "list_files_bare" [ "list-files" ] (fun c ->
    c.Cli.command = Cli.List_files "");
  config "list_files_prefix" [ "list-files"; "Sys" ] (fun c ->
    c.Cli.command = Cli.List_files "Sys");
  config "list_modules" [ "list-modules" ] (fun c ->
    c.Cli.command = Cli.List_modules);
  config "compile" [ "compile"; "M.Mod" ] (fun c ->
    c.Cli.command = Cli.Compile { name = "M.Mod"; new_symbol = false });
  config "compile_s" [ "compile"; "M.Mod"; "-s" ] (fun c ->
    c.Cli.command = Cli.Compile { name = "M.Mod"; new_symbol = true });
  config "compile_new_symbol" [ "--new-symbol"; "compile"; "M.Mod" ] (fun c ->
    c.Cli.command = Cli.Compile { name = "M.Mod"; new_symbol = true });
  invalid "new_symbol_outside_compile" [ "check"; "-s" ];
  config "load" [ "load"; "M" ] (fun c -> c.Cli.command = Cli.Load "M");
  config "unload" [ "unload"; "M" ] (fun c -> c.Cli.command = Cli.Unload "M");
  config "call_bare" [ "call"; "M.P" ] (fun c ->
    c.Cli.command = Cli.Call { cmd = "M.P"; args = "" });
  config "call_args" [ "call"; "M.P"; "a b" ] (fun c ->
    c.Cli.command = Cli.Call { cmd = "M.P"; args = "a b" });
  invalid "call_too_many" [ "call"; "M.P"; "a"; "b" ];
  invalid "unknown_command" [ "frobnicate" ];
  invalid "missing_command" [ "--serial"; "p" ];
  invalid "unknown_option" [ "--bogus"; "check" ];
  (* [--] ends option parsing, so EDIT fragments may start with a dash. *)
  config "dash_dash_positionals" [ "edit"; "F"; "--"; "-old"; "-new" ] (fun c ->
    c.Cli.command = Cli.Edit { path = "F"; old = "-old"; new_ = "-new" });
  (* Help / version win over everything else. *)
  check "help_long" (parse [ "--help" ] = Cli.Help);
  check "help_short_after_cmd" (parse [ "check"; "-h" ] = Cli.Help);
  check "version" (parse [ "--version" ] = Cli.Version);
  summary "oat cli checks"
;;
