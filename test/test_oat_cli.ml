(* CLI tests for oat: parsing (the serial forms are exclusive and paired,
   defaults match the Rust CLI, each subcommand arity-checks its positionals)
   and rendering (each response's stdout shape; the log-carrying failures print
   the log first, then raise). *)

open Oat
open Test_harness

let parse = Cli.parse_argv
let invalid name args = check name (match parse args with Cli.Invalid _ -> true | _ -> false)

let config name args pred =
  match parse args with
  | Cli.Config cfg -> check name (pred cfg)
  | _ -> check name false
;;

(* Run [f] with stdout captured to a scratch file; returns [f]'s outcome and
   what it printed. Restores stdout even when [f] raises. *)
let with_captured_stdout f =
  flush Stdlib.stdout;
  let saved = Unix.dup Unix.stdout in
  let tmp = Filename.temp_file "oat_cli_render" ".out" in
  let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 fd Unix.stdout;
  Unix.close fd;
  let result =
    match f () with
    | v -> Ok v
    | exception e -> Error e
  in
  flush Stdlib.stdout;
  Unix.dup2 saved Unix.stdout;
  Unix.close saved;
  let out = read_file tmp in
  Sys.remove tmp;
  result, out
;;

let render name response ~want =
  let result, out = with_captured_stdout (fun () -> Cli.render response) in
  check name (result = Ok ());
  eqs (name ^ "_out") out want
;;

let render_fails name response ~failure ~want =
  let result, out = with_captured_stdout (fun () -> Cli.render response) in
  check name (result = Error (Error.Error failure));
  eqs (name ^ "_log_first") out want
;;

let () =
  (* Serial forms: exclusive and paired (the Rust counterpart relied on clap for
     this; here the parser owns it). *)
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
  (* Subcommands and arities; write parses with an empty content placeholder
     (Cli.run fills it from stdin). *)
  config "read" [ "read"; "F.Mod" ] (fun c -> c.Cli.command = Data.Read "F.Mod");
  config "write" [ "write"; "F.Mod" ] (fun c ->
    c.Cli.command = Data.Write { path = "F.Mod"; content = "" });
  config "edit" [ "edit"; "F"; "old"; "new" ] (fun c ->
    c.Cli.command = Data.Edit { path = "F"; old = "old"; new_ = "new" });
  invalid "edit_arity" [ "edit"; "F"; "old" ];
  config "delete" [ "delete"; "F" ] (fun c -> c.Cli.command = Data.Delete "F");
  config "list_files_bare" [ "list-files" ] (fun c ->
    c.Cli.command = Data.List_files "");
  config "list_files_prefix" [ "list-files"; "Sys" ] (fun c ->
    c.Cli.command = Data.List_files "Sys");
  config "list_modules" [ "list-modules" ] (fun c ->
    c.Cli.command = Data.List_modules);
  config "compile" [ "compile"; "M.Mod" ] (fun c ->
    c.Cli.command = Data.Compile { name = "M.Mod"; new_symbol = false });
  config "compile_s" [ "compile"; "M.Mod"; "-s" ] (fun c ->
    c.Cli.command = Data.Compile { name = "M.Mod"; new_symbol = true });
  config "compile_new_symbol" [ "--new-symbol"; "compile"; "M.Mod" ] (fun c ->
    c.Cli.command = Data.Compile { name = "M.Mod"; new_symbol = true });
  invalid "new_symbol_outside_compile" [ "check"; "-s" ];
  config "load" [ "load"; "M" ] (fun c -> c.Cli.command = Data.Load "M");
  config "unload" [ "unload"; "M" ] (fun c -> c.Cli.command = Data.Unload "M");
  config "call_bare" [ "call"; "M.P" ] (fun c ->
    c.Cli.command = Data.Call { cmd = "M.P"; args = "" });
  config "call_args" [ "call"; "M.P"; "a b" ] (fun c ->
    c.Cli.command = Data.Call { cmd = "M.P"; args = "a b" });
  invalid "call_too_many" [ "call"; "M.P"; "a"; "b" ];
  invalid "unknown_command" [ "frobnicate" ];
  invalid "missing_command" [ "--serial"; "p" ];
  invalid "unknown_option" [ "--bogus"; "check" ];
  (* [--] ends option parsing, so EDIT fragments may start with a dash. *)
  config "dash_dash_positionals" [ "edit"; "F"; "--"; "-old"; "-new" ] (fun c ->
    c.Cli.command = Data.Edit { path = "F"; old = "-old"; new_ = "-new" });
  (* Help / version win over everything else. *)
  check "help_long" (parse [ "--help" ] = Cli.Help);
  check "help_short_after_cmd" (parse [ "check"; "-h" ] = Cli.Help);
  check "version" (parse [ "--version" ] = Cli.Version);
  (* Rendering: each response's stdout shape. *)
  render
    "render_checked"
    (Data.Checked { version = "Extended Oberon System  AP 1.1.26"; rtt_ms = 3 })
    ~want:"ok: Extended Oberon System  AP 1.1.26 (round-trip 3ms)\n";
  (let result, out =
     with_captured_stdout (fun () ->
       Cli.render (Data.Checked { version = ""; rtt_ms = 3 }))
   in
   check "render_checked_no_version" (result = Ok ());
   check
     "render_checked_no_version_warns"
     (String.starts_with ~prefix:"ok: connected (round-trip 3ms)\n    warning:" out));
  (* File content passes through untouched — no added newline. *)
  render "render_read" (Data.Read "raw") ~want:"raw";
  render
    "render_written"
    (Data.Written { path = "F.Mod"; bytes = 2 })
    ~want:"ok wrote F.Mod (2 bytes)\n";
  render
    "render_edited"
    (Data.Edited { path = "F.Mod" })
    ~want:"ok edited F.Mod\n";
  render
    "render_deleted"
    (Data.Deleted { path = "F.Mod" })
    ~want:"ok deleted F.Mod\n";
  render "render_listed_files" (Data.Listed_files "A\t1\nB\t2\n") ~want:"A\t1\nB\t2\n";
  render "render_loaded" (Data.Loaded "M") ~want:"ok loaded M\n";
  (* The unload log is indented under the ok line. *)
  render
    "render_unloaded"
    (Data.Unloaded { name = "X"; log = "System.Free\nX removing\n" })
    ~want:"ok unloaded X\n  System.Free\n  X removing\n";
  (* The log-carrying failures print the log (newline ensured) before raising, so
     it lands above the binary's error line. *)
  render
    "render_compiled_ok"
    (Data.Compiled { output = "  compiling M\n"; failed = false })
    ~want:"  compiling M\n";
  render_fails
    "render_compiled_failed"
    (Data.Compiled { output = "compilation FAILED"; failed = true })
    ~failure:Error.Compile_failed
    ~want:"compilation FAILED\n";
  render
    "render_called_ok"
    (Data.Called { log = "log line\n"; failure = None })
    ~want:"log line\n";
  render_fails
    "render_called_trapped"
    (Data.Called { log = "TRAP 2\n"; failure = Some Error.Trapped })
    ~failure:Error.Trapped
    ~want:"TRAP 2\n";
  render "render_called_empty_log" (Data.Called { log = ""; failure = None }) ~want:"";
  summary "oat cli checks"
;;
