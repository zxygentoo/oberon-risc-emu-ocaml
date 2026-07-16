(** The oat command-line surface (port of oat's [cli.rs] + [main.rs]). *)

type serial =
  | Device of string
  | Fifos of
      { fifo_in : string
      ; fifo_out : string
      }

type command =
  | Check
  | Read of string
  | Write of string
  | Edit of
      { path : string
      ; old : string
      ; new_ : string
      }
  | Delete of string
  | List_files of string
  | List_modules
  | Compile of
      { name : string
      ; new_symbol : bool
      }
  | Load of string
  | Unload of string
  | Call of
      { cmd : string
      ; args : string
      }

type config =
  { timeout : float
  ; baud : int
  ; char_delay_us : int
  ; retries : int
  ; serial : serial option
  ; command : command
  }

type parsed =
  | Config of config
  | Help
  | Version
  | Invalid of string

let usage =
  "drive AgentTool.Mod on a live Project Oberon or Extended Oberon system over a \
   serial link\n\n\
   A stateless CLI: each invocation opens the serial line, runs one command, prints\n\
   its result, and exits. The wire protocol is PUT/GET/CALL/EDIT — four opcodes\n\
   between the host and AgentTool.Mod on the device.\n\n\
   Usage: oat [OPTIONS] <COMMAND> [ARGS]\n\n\
   Commands:\n\
  \  check          Check that the wire is up and report the OS variant + version\n\
  \  read PATH      Read a file from the device; content -> stdout\n\
  \  write PATH     Create or overwrite a file with content from stdin\n\
  \  edit PATH OLD NEW\n\
  \                 Replace a unique occurrence of OLD with NEW in PATH \
   (str_replace)\n\
  \  delete PATH    Delete a file\n\
  \  list-files [PREFIX]\n\
  \                 List files (TSV: name, size, date); optional name prefix\n\
  \  list-modules   List loaded modules (TSV: name, refcnt, code addr)\n\
  \  compile NAME   Compile a module via ORP.Compile; compiler log -> stdout\n\
  \                 (-s / --new-symbol rewrites the .smb file — use when the\n\
  \                 module's exported interface changed)\n\
  \  load NAME      Load a compiled module\n\
  \  unload NAME    Unload a module (EO: safe-unload via System.Free /f;\n\
  \                 PO: System.Free — dangling refs possible)\n\
  \  call CMD [ARGS]\n\
  \                 Run any Oberon command 'Mod.Proc'; Log delta -> stdout\n\n\
   Options:\n\
  \  --timeout SECS       Serial read timeout per request, in seconds [default: 15]\n\
  \  --baud RATE          Baud rate for a real serial device (--serial); ignored\n\
  \                       for FIFO pairs [default: 115200]\n\
  \  --char-delay-us US   Inter-byte delay for a real serial device (--serial), in\n\
  \                       microseconds; ignored for FIFOs [default: 600]\n\
  \  --retries N          Re-send a request this many times if it desyncs on a real\n\
  \                       serial device (--serial); ignored for FIFOs [default: 3]\n\
  \  -h, --help           Print help\n\
  \  --version            Print version\n\n\
   Serial connection (one form required):\n\
  \  --serial PATH        Existing PTY / serial device (raw mode set on open)\n\
  \  --serial-in PATH     FIFO the emulator reads (we write); pair with --serial-out\n\
  \  --serial-out PATH    FIFO the emulator writes (we read); pair with --serial-in\n\n\
   Exit codes:\n\
  \  0  Success.\n\
  \  1  Tool-level error (file not found, compile failed, unload refused, trap).\n\
  \  2  Transport / protocol error (no connection, timeout, bad frame, bad args).\n\n\
   Example:\n\
  \  mkfifo /tmp/p.in /tmp/p.out                                              # once\n\
  \  risc --serial-in /tmp/p.in --serial-out /tmp/p.out DiskImage/ProjectOberon.dsk &\n\
  \  oat --serial-in /tmp/p.in --serial-out /tmp/p.out check\n"
;;

(* Split [--opt=value] into [--opt; value] so the parser only handles [--opt value]. *)
let split_eq arg =
  if String.starts_with ~prefix:"--" arg
  then (
    match String.index_opt arg '=' with
    | Some i -> [ String.sub arg 0 i; String.sub arg (i + 1) (String.length arg - i - 1) ]
    | None -> [ arg ])
  else [ arg ]
;;

(* The subcommand and its positional arguments; arity-checked here. [new_symbol] is
   compile's flag, parsed anywhere but valid only there (as in the Rust CLI, where
   -s lives on the compile subcommand alone). *)
let command_of ~new_symbol positionals =
  let arity_err name = Result.Error (Printf.sprintf "wrong number of arguments for '%s'" name) in
  let cmd =
    match positionals with
    | [] -> Result.Error "missing command"
    | name :: args ->
      (match name, args with
       | "check", [] -> Result.Ok Check
       | "read", [ path ] -> Result.Ok (Read path)
       | "write", [ path ] -> Result.Ok (Write path)
       | "edit", [ path; old; new_ ] -> Result.Ok (Edit { path; old; new_ })
       | "delete", [ path ] -> Result.Ok (Delete path)
       | "list-files", [] -> Result.Ok (List_files "")
       | "list-files", [ prefix ] -> Result.Ok (List_files prefix)
       | "list-modules", [] -> Result.Ok List_modules
       | "compile", [ name ] -> Result.Ok (Compile { name; new_symbol })
       | "load", [ name ] -> Result.Ok (Load name)
       | "unload", [ name ] -> Result.Ok (Unload name)
       | "call", [ cmd ] -> Result.Ok (Call { cmd; args = "" })
       | "call", [ cmd; args ] -> Result.Ok (Call { cmd; args })
       | ( ( "check" | "read" | "write" | "edit" | "delete" | "list-files"
           | "list-modules" | "compile" | "load" | "unload" | "call" )
         , _ ) -> arity_err name
       | _ -> Result.Error (Printf.sprintf "unrecognized command %S" name))
  in
  match cmd with
  | Result.Ok (Compile _) | Result.Error _ -> cmd
  | Result.Ok _ when new_symbol -> Result.Error "unexpected argument '--new-symbol'"
  | ok -> ok
;;

let parse_argv raw_args =
  let timeout = ref 15.0
  and baud = ref 115200
  and char_delay_us = ref 600
  and retries = ref 3
  and serial = ref None
  and serial_in = ref None
  and serial_out = ref None
  and new_symbol = ref false
  and positionals = ref []
  and help = ref false
  and version = ref false
  and err = ref None in
  let fail msg = if !err = None then err := Some msg in
  let float_opt name r v =
    match float_of_string_opt v with
    | Some x -> r := x
    | None -> fail (Printf.sprintf "invalid %s %S" name v)
  in
  let uint_opt name r v =
    match int_of_string_opt v with
    | Some n when n >= 0 -> r := n
    | _ -> fail (Printf.sprintf "invalid %s %S" name v)
  in
  let rec loop = function
    | [] -> ()
    | _ when !err <> None -> ()
    | "--" :: rest -> positionals := List.rev_append rest !positionals
    | "--timeout" :: v :: rest ->
      float_opt "--timeout" timeout v;
      loop rest
    | "--baud" :: v :: rest ->
      uint_opt "--baud" baud v;
      loop rest
    | "--char-delay-us" :: v :: rest ->
      uint_opt "--char-delay-us" char_delay_us v;
      loop rest
    | "--retries" :: v :: rest ->
      uint_opt "--retries" retries v;
      loop rest
    | "--serial" :: v :: rest ->
      serial := Some v;
      loop rest
    | "--serial-in" :: v :: rest ->
      serial_in := Some v;
      loop rest
    | "--serial-out" :: v :: rest ->
      serial_out := Some v;
      loop rest
    | ("-s" | "--new-symbol") :: rest ->
      new_symbol := true;
      loop rest
    | ("--help" | "-h") :: _ -> help := true
    | "--version" :: _ -> version := true
    | (( "--timeout" | "--baud" | "--char-delay-us" | "--retries" | "--serial"
       | "--serial-in" | "--serial-out" ) as o)
      :: [] -> fail (Printf.sprintf "option %s requires a value" o)
    | opt :: _ when String.length opt > 1 && opt.[0] = '-' ->
      fail (Printf.sprintf "unknown option %s" opt)
    | arg :: rest ->
      positionals := arg :: !positionals;
      loop rest
  in
  loop (List.concat_map split_eq raw_args);
  if !help
  then Help
  else if !version
  then Version
  else (
    (* The serial forms are exclusive and paired, as clap enforced in the Rust CLI. *)
    let serial_form =
      match !serial, !serial_in, !serial_out with
      | Some _, None, None -> Result.Ok (Option.map (fun p -> Device p) !serial)
      | None, Some fifo_in, Some fifo_out -> Result.Ok (Some (Fifos { fifo_in; fifo_out }))
      | None, None, None -> Result.Ok None
      | Some _, _, _ ->
        Result.Error "--serial cannot be combined with --serial-in/--serial-out"
      | None, Some _, None -> Result.Error "--serial-in requires --serial-out"
      | None, None, Some _ -> Result.Error "--serial-out requires --serial-in"
    in
    match !err, serial_form with
    | Some e, _ | None, Result.Error e -> Invalid e
    | None, Result.Ok serial ->
      (match command_of ~new_symbol:!new_symbol (List.rev !positionals) with
       | Result.Error e -> Invalid e
       | Result.Ok command ->
         Config
           { timeout = !timeout
           ; baud = !baud
           ; char_delay_us = !char_delay_us
           ; retries = !retries
           ; serial
           ; command
           }))
;;

(* --- subcommand handlers --- *)

(* Print a tool log to stdout, ensuring a trailing newline when non-empty (so the
   next stderr line doesn't get glued onto the last log line). *)
let print_log log =
  if log <> ""
  then (
    print_string log;
    if not (String.ends_with ~suffix:"\n" log) then print_newline ())
;;

let cmd_check send =
  let start = Unix.gettimeofday () in
  let version = Tools.version send in
  let rtt_ms = int_of_float ((Unix.gettimeofday () -. start) *. 1000.0) in
  if version = ""
  then (
    Printf.printf "ok: connected (round-trip %dms)\n" rtt_ms;
    print_string
      "    warning: device reported no version string — image may lack the\n\
      \    System.Version patch. Variant detection is unavailable; proceed at\n\
      \    your own risk (PO-style unsafe unload may apply).\n")
  else Printf.printf "ok: %s (round-trip %dms)\n" version rtt_ms
;;

let dispatch send = function
  | Check -> cmd_check send
  | Read path -> print_string (Tools.read_file send path)
  | Write path ->
    let content = In_channel.input_all In_channel.stdin in
    Tools.write_file send ~path ~content;
    Printf.printf "ok wrote %s (%d bytes)\n" path (String.length content)
  | Edit { path; old; new_ } ->
    Tools.edit_file send ~path ~old ~new_;
    Printf.printf "ok edited %s\n" path
  | Delete path ->
    Tools.delete_file send path;
    Printf.printf "ok deleted %s\n" path
  | List_files prefix -> print_string (Tools.list_files send ~prefix)
  | List_modules -> print_string (Tools.list_modules send)
  | Compile { name; new_symbol } ->
    let r = Tools.compile_module send ~name ~new_symbol in
    print_log r.output;
    if r.failed then Error.fail Error.Compile_failed
  | Load name ->
    Tools.load_module send name;
    Printf.printf "ok loaded %s\n" name
  | Unload name ->
    let log = Tools.unload_module send name in
    Printf.printf "ok unloaded %s\n" name;
    (match String.trim log with
     | "" -> ()
     | trimmed ->
       List.iter (Printf.printf "  %s\n") (String.split_on_char '\n' trimmed))
  | Call { cmd; args } ->
    let r = Tools.run_command send ~cmd ~args in
    print_log r.log;
    Tools.call_outcome r
;;

let run cfg =
  let timeout = Float.max cfg.timeout 0.001 in
  (* Retry only the lossy real-serial path. The FIFO/emulator transport is lossless
     and back-pressured, so a timeout there is a genuine hang — pass it straight
     through rather than waiting out N more timeouts. *)
  let transport, retries =
    match cfg.serial with
    | None -> Error.fail Error.No_serial
    | Some (Device path) ->
      ( Transport.open_path
          path
          ~timeout
          ~baud:cfg.baud
          ~char_delay:(float_of_int cfg.char_delay_us /. 1_000_000.0)
      , cfg.retries )
    | Some (Fifos { fifo_in; fifo_out }) ->
      Transport.open_fifos ~in_path:fifo_in ~out_path:fifo_out ~timeout, 0
  in
  dispatch (Retry.wrap ~retries (Transport.send transport)) cfg.command
;;

let main () =
  match parse_argv (List.tl (Array.to_list Sys.argv)) with
  | Help ->
    print_string usage;
    exit 0
  | Version ->
    Printf.printf "oat %s\n" Oberon_tools.Tool_cli.version;
    exit 0
  | Invalid msg ->
    Printf.eprintf "oat: error: %s\nFor more information, try '--help'.\n" msg;
    exit 2
  | Config cfg ->
    (try run cfg with
     | Error.Error e ->
       Printf.eprintf "oat: error: %s\n" (Error.message e);
       exit (Error.exit_code e)
     | Sys_error m ->
       Printf.eprintf "oat: error: %s\n" m;
       exit 2
     | Unix.Unix_error (e, fn, arg) ->
       Printf.eprintf "oat: error: %s (%s %s)\n" (Unix.error_message e) fn arg;
       exit 2)
;;
