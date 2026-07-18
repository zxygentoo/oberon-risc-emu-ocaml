(** The oat command-line surface: parse argv, render responses, wire the layers. *)

type serial =
  | Device of string
  | Fifos of
      { fifo_in : string
      ; fifo_out : string
      }

type config =
  { timeout : float
  ; baud : int
  ; char_delay_us : int
  ; retries : int
  ; serial : serial option
  ; command : Data.request
  }

type parsed =
  | Config of config
  | Help
  | Version
  | Invalid of string

let default_timeout = 15.0
let default_baud = 115200
let default_char_delay_us = 600
let default_retries = 3

let usage =
  Printf.sprintf
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
  \  --timeout SECS       Serial read timeout per request, in seconds [default: %g]\n\
  \  --baud RATE          Baud rate for a real serial device (--serial); ignored\n\
  \                       for FIFO pairs [default: %d]\n\
  \  --char-delay-us US   Inter-byte delay for a real serial device (--serial), in\n\
  \                       microseconds; ignored for FIFOs [default: %d]\n\
  \  --retries N          Re-send a request this many times if it desyncs on a real\n\
  \                       serial device (--serial); ignored for FIFOs [default: %d]\n\
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
    default_timeout
    default_baud
    default_char_delay_us
    default_retries
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

(* Parse failures unwind to [Invalid] through this local exception; the first raise
   wins, as the Rust CLI's clap error did. *)
exception Fail of string

let fail msg = raise (Fail msg)

(* The subcommand and its positional arguments, arity-checked. [new_symbol] carries
   the spelling of a parsed [-s]/[--new-symbol] — compile's flag, accepted anywhere
   on the line but valid only with compile (the Rust CLI scoped it via clap). *)
let command_of ~new_symbol positionals =
  let arity_err name = fail (Printf.sprintf "wrong number of arguments for '%s'" name) in
  (* The annotation disambiguates the constructors requests share with responses
     (Read; the past-tense scheme keeps the rest apart). *)
  let command : Data.request =
    match positionals with
    | [] -> fail "missing command"
    | [ "check" ] -> Data.Check
    | [ "read"; path ] -> Data.Read path
    | [ "write"; path ] -> Data.Write { path; content = "" }
    | [ "edit"; path; old; new_ ] -> Data.Edit { path; old; new_ }
    | [ "delete"; path ] -> Data.Delete path
    | [ "list-files" ] -> Data.List_files ""
    | [ "list-files"; prefix ] -> Data.List_files prefix
    | [ "list-modules" ] -> Data.List_modules
    | [ "compile"; name ] -> Data.Compile { name; new_symbol = new_symbol <> None }
    | [ "load"; name ] -> Data.Load name
    | [ "unload"; name ] -> Data.Unload name
    | [ "call"; cmd ] -> Data.Call { cmd; args = "" }
    | [ "call"; cmd; args ] -> Data.Call { cmd; args }
    | (( "check" | "read" | "write" | "edit" | "delete" | "list-files" | "list-modules"
       | "compile" | "load" | "unload" | "call" ) as name)
      :: _ -> arity_err name
    | name :: _ -> fail (Printf.sprintf "unrecognized command %S" name)
  in
  match command, new_symbol with
  | Data.Compile _, _ | _, None -> command
  | _, Some spelling -> fail (Printf.sprintf "unexpected argument '%s'" spelling)
;;

let parse_argv raw_args =
  let timeout = ref default_timeout
  and baud = ref default_baud
  and char_delay_us = ref default_char_delay_us
  and retries = ref default_retries
  and serial = ref None
  and serial_in = ref None
  and serial_out = ref None
  and new_symbol = ref None
  and positionals = ref []
  and help = ref false
  and version = ref false in
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
  (* One entry per value-taking option; a single arm below both consumes the
     value and reports it missing. *)
  let value_opts =
    [ "--timeout", float_opt "--timeout" timeout
    ; "--baud", uint_opt "--baud" baud
    ; "--char-delay-us", uint_opt "--char-delay-us" char_delay_us
    ; "--retries", uint_opt "--retries" retries
    ; "--serial", (fun v -> serial := Some v)
    ; "--serial-in", (fun v -> serial_in := Some v)
    ; "--serial-out", (fun v -> serial_out := Some v)
    ]
  in
  let rec loop = function
    | [] -> ()
    | "--" :: rest -> positionals := List.rev_append rest !positionals
    | o :: rest when List.mem_assoc o value_opts ->
      (match rest with
       | v :: rest ->
         (List.assoc o value_opts) v;
         loop rest
       | [] -> fail (Printf.sprintf "option %s requires a value" o))
    | (("-s" | "--new-symbol") as spelling) :: rest ->
      new_symbol := Some spelling;
      loop rest
    | ("--help" | "-h") :: _ -> help := true
    | "--version" :: _ -> version := true
    | opt :: _ when String.length opt > 1 && opt.[0] = '-' ->
      fail (Printf.sprintf "unknown option %s" opt)
    | arg :: rest ->
      positionals := arg :: !positionals;
      loop rest
  in
  try
    loop (List.concat_map split_eq raw_args);
    if !help
    then Help
    else if !version
    then Version
    else (
      (* The serial forms are exclusive and paired, as clap enforced in the Rust CLI. *)
      let serial =
        match !serial, !serial_in, !serial_out with
        | Some p, None, None -> Some (Device p)
        | None, Some fifo_in, Some fifo_out -> Some (Fifos { fifo_in; fifo_out })
        | None, None, None -> None
        | Some _, _, _ -> fail "--serial cannot be combined with --serial-in/--serial-out"
        | None, Some _, None -> fail "--serial-in requires --serial-out"
        | None, None, Some _ -> fail "--serial-out requires --serial-in"
      in
      Config
        { timeout = !timeout
        ; baud = !baud
        ; char_delay_us = !char_delay_us
        ; retries = !retries
        ; serial
        ; command = command_of ~new_symbol:!new_symbol (List.rev !positionals)
        })
  with
  | Fail e -> Invalid e
;;

(* --- rendering --- *)

(* Print a tool log to stdout, ensuring a trailing newline when non-empty (so the
   next stderr line doesn't get glued onto the last log line). *)
let print_log log =
  if log <> ""
  then (
    print_string log;
    if not (String.ends_with ~suffix:"\n" log) then print_newline ())
;;

let render = function
  | Data.Checked { version; rtt_ms } ->
    if version = ""
    then (
      Printf.printf "ok: connected (round-trip %dms)\n" rtt_ms;
      print_string
        "    warning: device reported no version string — image may lack the\n\
        \    System.Version patch. Variant detection is unavailable; proceed at\n\
        \    your own risk (PO-style unsafe unload may apply).\n")
    else Printf.printf "ok: %s (round-trip %dms)\n" version rtt_ms
  | Data.Read content -> print_string content
  | Data.Written { path; bytes } -> Printf.printf "ok wrote %s (%d bytes)\n" path bytes
  | Data.Edited { path } -> Printf.printf "ok edited %s\n" path
  | Data.Deleted { path } -> Printf.printf "ok deleted %s\n" path
  | Data.Listed_files listing | Data.Listed_modules listing -> print_string listing
  | Data.Compiled { output; failed } ->
    print_log output;
    if failed then Error.fail Error.Compile_failed
  | Data.Loaded name -> Printf.printf "ok loaded %s\n" name
  | Data.Unloaded { name; log } ->
    Printf.printf "ok unloaded %s%s\n" name (Error.indented_log log)
  | Data.Called { log; failure } ->
    print_log log;
    Option.iter Error.fail failure
;;

(* --- wiring --- *)

let run cfg =
  let timeout = Float.max cfg.timeout 0.001 in
  (* Retry only the lossy real-serial path. The FIFO/emulator channel is lossless
     and back-pressured, so a timeout there is a genuine hang — pass it straight
     through rather than waiting out N more timeouts. *)
  let device, retries =
    match cfg.serial with
    | None -> Error.fail Error.No_serial
    | Some (Device path) ->
      ( Device.open_device
          path
          ~timeout
          ~baud:cfg.baud
          ~char_delay:(float_of_int cfg.char_delay_us /. 1_000_000.0)
      , cfg.retries )
    | Some (Fifos { fifo_in; fifo_out }) ->
      Device.open_fifos ~in_path:fifo_in ~out_path:fifo_out ~timeout, 0
  in
  let request =
    match cfg.command with
    | Data.Write { path; content = _ } ->
      (* stdin is read at the process edge, once the device is open. Host I/O
         failures become Error.Io at the raise site, so Error.exit_code stays the
         sole owner of the exit-code partition. *)
      let content =
        try In_channel.input_all In_channel.stdin with
        | Sys_error m -> Error.fail (Error.Io m)
      in
      Data.Write { path; content }
    | request -> request
  in
  render (Tool_call.execute (Io.send device ~retries) request)
;;

module For_tests = struct
  let render = render
end
