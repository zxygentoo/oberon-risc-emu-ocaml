(** oat's error vocabulary, message rendering, and exit-code mapping. *)

type t =
  | No_serial
  | Bad_name of string
  | Put_too_large of
      { bytes : int
      ; limit : int
      }
  | Open_fifo of
      { path : string
      ; err : Unix.error
      }
  | Open_serial of
      { path : string
      ; err : Unix.error
      }
  | Io of string
  | Timeout of
      { secs : float
      ; got : int
      ; want : int
      }
  | Eof
  | Bad_sync of
      { got : int
      ; expected : int
      }
  | Bad_status of int
  | File_not_found of string
  | Edit_not_found
  | Edit_not_unique of int
  | Load_failed of
      { res : int option
      ; log : string
      }
  | Unload_in_use of string
  | Compile_failed
  | Trapped

exception Error of t

let fail e = raise (Error e)

let exit_code = function
  | File_not_found _
  | Edit_not_found
  | Edit_not_unique _
  | Load_failed _
  | Unload_in_use _
  | Compile_failed
  | Trapped -> 1
  | _ -> 2
;;

(* Modules.Load failure codes. 1-4 mean the same on PO 2013 and EO; "no module
   space" is res=7 on PO but res=5 on EO (which renumbered the codes above 4),
   and the host cannot tell the variants apart here, so both map to that hint. *)
let res_hint = function
  | 1 -> Some "name invalid or .rsc not found — has the module been compiled?"
  | 2 -> Some "bad symbol-file key — recompile importers or compile with --new-symbol"
  | 3 -> Some "import key conflict — recompile importers or unload them first"
  | 4 -> Some "corrupted object file"
  | 5 | 7 -> Some "no module space — unload unused modules"
  | _ -> None
;;

let indented_log log =
  match String.trim log with
  | "" -> ""
  | trimmed ->
    String.split_on_char '\n' trimmed
    |> List.map (fun line -> "\n  " ^ line)
    |> String.concat ""
;;

let open_fifo_message path err =
  match err with
  | Unix.ENOENT ->
    Printf.sprintf
      "FIFO does not exist: %s\n  hint: create with `mkfifo /tmp/p.in /tmp/p.out`"
      path
  | Unix.EACCES -> Printf.sprintf "permission denied opening FIFO %s" path
  | e -> Printf.sprintf "cannot open FIFO %s: %s" path (Unix.error_message e)
;;

let load_failed_message res log =
  let res_part =
    match res with
    | None -> ""
    | Some r ->
      let hint =
        match res_hint r with
        | None -> ""
        | Some h -> Printf.sprintf "\n  hint: %s" h
      in
      Printf.sprintf " (res=%d)%s" r hint
  in
  "load failed" ^ res_part ^ indented_log log
;;

let message = function
  | No_serial ->
    "no serial connection specified — pass --serial or --serial-in/--serial-out"
  | Bad_name name ->
    Printf.sprintf "name length %d out of range 1..255: %S" (String.length name) name
  | Put_too_large { bytes; limit } ->
    Printf.sprintf
      "content is %d bytes — over the device's %d-byte PUT buffer; split the file"
      bytes
      limit
  | Open_fifo { path; err } -> open_fifo_message path err
  | Open_serial { path; err } ->
    Printf.sprintf "cannot open serial device %s: %s" path (Unix.error_message err)
  | Io msg -> msg
  | Timeout { secs; got; want } ->
    Printf.sprintf
      "no response from emulator after %gs (%d/%d bytes received)\n\
      \  hint: is `risc --serial-in <p.in> --serial-out <p.out> <image>.dsk` running?"
      secs
      got
      want
  | Eof -> "serial line closed (EOF) — the emulator dropped the connection"
  | Bad_sync { got; expected } ->
    Printf.sprintf
      "bad response sync byte 0x%02X (expected 0x%02X) — device is out of frame; \
       restart the emulator"
      got
      expected
  | Bad_status status -> Printf.sprintf "device returned status=%d" status
  | File_not_found path -> Printf.sprintf "file not found: %s" path
  | Edit_not_found -> "OLD string not found in file"
  | Edit_not_unique count ->
    Printf.sprintf "OLD string occurs %d times in file (must be unique)" count
  | Load_failed { res; log } -> load_failed_message res log
  | Unload_in_use log ->
    "unload refused — other loaded modules still import this one" ^ indented_log log
  | Compile_failed -> "compilation FAILED (see log above)"
  | Trapped -> "trapped (see TRAP message in log above)"
;;
