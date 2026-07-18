(** The typed oat operations on the Oberon device — the semantics layer. *)

open Data.Wire

(* Device text via the shared ob2txt/txt2ob transforms ({!Oberon_tools.Convert}).
   Intentional divergence from the Rust oat, whose to_oberon sends raw UTF-8 bytes to
   the device: the Latin-1 fold makes non-ASCII writes round-trip on read. *)
let to_oberon = Oberon_tools.Convert.to_oberon
let from_oberon = Oberon_tools.Convert.from_oberon

(* Output of compile_module: the compiler log always comes back; [failed] becomes
   Data.Compiled's in-band failure flag. *)
type compile_result =
  { output : string
  ; failed : bool
  }

(* Output of run_command: the Oberon.Log delta written while the command ran,
   plus the device status mapped to the command's error ([Trapped] or
   [Bad_status]) — in-band, so the log can be printed first. *)
type call_result =
  { log : string
  ; failure : Error.t option
  }

let bad_status s = Error.fail (Error.Bad_status (status_byte s))
let check_ok r = if not (ok r) then bad_status r.status

(* --- string helpers (Rust's str::matches / replacen / contains) --- *)

(* First occurrence of non-empty [sub] at or after [from]: hop to each first-byte
   candidate (String.index_from_opt is memchr), then compare in place. *)
let find_sub ~sub ~from s =
  let n = String.length sub in
  let limit = String.length s - n in
  let rec eq j k = k = n || (s.[j + k] = sub.[k] && eq j (k + 1)) in
  let rec go i =
    if i > limit
    then None
    else (
      match String.index_from_opt s i sub.[0] with
      | Some j when j <= limit -> if eq j 1 then Some j else go (j + 1)
      | _ -> None)
  in
  go from
;;

(* Non-overlapping occurrence count, Rust's [s.matches(sub).count()] — which for an
   empty pattern matches at every char boundary (len + 1). *)
let count_occurrences ~sub s =
  if sub = ""
  then String.length s + 1
  else (
    let rec go from count =
      match find_sub ~sub ~from s with
      | None -> count
      | Some i -> go (i + String.length sub) (count + 1)
    in
    go 0 0)
;;

(* Rust's [s.replacen (sub, by, 1)]; an empty pattern matches at position 0. *)
let replace_first ~sub ~by s =
  if sub = ""
  then by ^ s
  else (
    match find_sub ~sub ~from:0 s with
    | None -> s
    | Some at ->
      let n = String.length sub in
      String.sub s 0 at ^ by ^ String.sub s (at + n) (String.length s - at - n))
;;

let contains ~sub s = sub = "" || find_sub ~sub ~from:0 s <> None

(* --- internals --- *)

let call_log (wire : Data.Wire.t) ~cmd ~args =
  let r = wire (Call { cmd; par = to_oberon args }) in
  check_ok r;
  from_oberon r.payload
;;

let parse_res log =
  String.split_on_char '\n' log
  |> List.concat_map (String.split_on_char ' ')
  |> List.concat_map (String.split_on_char '\t')
  |> List.find_map (fun tok ->
    if String.starts_with ~prefix:"res=" tok
    then int_of_string_opt (String.sub tok 4 (String.length tok - 4))
    else None)
;;

(* --- the operations --- *)

let read_file (wire : Data.Wire.t) path =
  let r = wire (Get { name = path }) in
  match r.status with
  | Ok ->
    (* Only a GET payload can carry the 0F1X header of a [Texts.Close]-written file,
       so the strip lives here alone; logs and edit fragments never have one. (The
       Rust oat strips inside every from_oberon — inert difference in practice.) *)
    from_oberon (Oberon_tools.Convert.strip_text_header r.payload)
  | Not_found -> Error.fail (Error.File_not_found path)
  | s -> bad_status s
;;

let write_file (wire : Data.Wire.t) ~path ~content =
  check_ok (wire (Put { name = path; data = to_oberon content }))
;;

(* Fallback for fragments EDIT cannot carry: full read-modify-write through GET and
   PUT. [old_dev] is the fragment already in device form; converting it back puts
   both paths' matching in the same (host) space. *)
let edit_file_via_rw (wire : Data.Wire.t) ~path ~old_dev ~new_ =
  let old = from_oberon old_dev in
  let content = read_file wire path in
  let count = count_occurrences ~sub:old content in
  if count = 0 then Error.fail Error.Edit_not_found;
  if count > 1 then Error.fail (Error.Edit_not_unique count);
  write_file wire ~path ~content:(replace_first ~sub:old ~by:new_ content)
;;

(* Normally one EDIT round-trip — the device matches OLD inside the file via its
   Texts piece list and splices NEW in atomically; fragments over edit_old_limit
   take the host-side fallback above. *)
let edit_file (wire : Data.Wire.t) ~path ~old ~new_ =
  let old_dev = to_oberon old in
  if old_dev = "" || String.length old_dev > edit_old_limit
  then edit_file_via_rw wire ~path ~old_dev ~new_
  else (
    let r = wire (Edit { name = path; old = old_dev; new_ = to_oberon new_ }) in
    match r.status with
    | Ok -> ()
    | Not_found -> Error.fail (Error.File_not_found path)
    | No_match -> Error.fail Error.Edit_not_found
    | Not_unique -> Error.fail (Error.Edit_not_unique (not_unique_count r))
    | Trapped -> Error.fail Error.Trapped
    | s -> bad_status s)
;;

let delete_file wire path =
  let log = call_log wire ~cmd:"System.DeleteFiles" ~args:path in
  (* System.Mod writes "<name> deleting" on success, "<name> deleting failed" on
     res # 0. Match the full phrase so a filename containing "failed" doesn't trip
     the check. *)
  if contains ~sub:"deleting failed" log
  then Error.fail (Error.File_not_found path)
;;

let list_files wire ~prefix = call_log wire ~cmd:"AgentTool.ListFiles" ~args:prefix
let list_modules wire = call_log wire ~cmd:"AgentTool.ListModules" ~args:""

(* The trimmed System.Version log line; "" when the image lacks the patch. *)
let version wire = String.trim (call_log wire ~cmd:"AgentTool.Version" ~args:"")

let load_module wire name =
  let log = call_log wire ~cmd:"AgentTool.Load" ~args:name in
  if not (String.starts_with ~prefix:"loaded" (String.trim log))
  then Error.fail (Error.Load_failed { res = parse_res log; log })
;;

let unload_module wire name =
  (* We always pass /f. On EO that triggers safe-unload (hide-and-rename when live
     refs persist, full removal otherwise). On PO, /f tokenizes as junk that the
     System.Free scanner discards — so the module is unloaded the unsafe way. The
     "unloading failed" phrase is EO-only; on PO an in-use refusal goes undetected
     here, which is why the skill insists on operator permission before any unload
     on PO. *)
  let log = call_log wire ~cmd:"System.Free" ~args:(name ^ " /f") in
  if contains ~sub:"unloading failed" log
  then Error.fail (Error.Unload_in_use log);
  log
;;

let compile_module (wire : Data.Wire.t) ~name ~new_symbol =
  let par = if new_symbol then name ^ "/s" else name in
  let r = wire (Call { cmd = "ORP.Compile"; par = to_oberon par }) in
  check_ok r;
  let output = from_oberon r.payload in
  { output; failed = contains ~sub:"compilation FAILED" output }
;;

let run_command (wire : Data.Wire.t) ~cmd ~args =
  let r = wire (Call { cmd; par = to_oberon args }) in
  let failure =
    match r.status with
    | Ok -> None
    | Trapped -> Some Error.Trapped
    | s -> Some (Error.Bad_status (status_byte s))
  in
  { log = from_oberon r.payload; failure }
;;

let execute (wire : Data.Wire.t) (request : Data.request) : Data.response =
  match request with
  | Data.Check ->
    let start = Unix.gettimeofday () in
    let version = version wire in
    let rtt_ms = int_of_float ((Unix.gettimeofday () -. start) *. 1000.0) in
    Data.Checked { version; rtt_ms }
  | Data.Read path -> Data.File_read (read_file wire path)
  | Data.Write { path; content } ->
    write_file wire ~path ~content;
    Data.File_written { path; bytes = String.length content }
  | Data.Edit { path; old; new_ } ->
    edit_file wire ~path ~old ~new_;
    Data.File_edited { path }
  | Data.Delete path ->
    delete_file wire path;
    Data.File_deleted { path }
  | Data.List_files prefix -> Data.Files_listed (list_files wire ~prefix)
  | Data.List_modules -> Data.Modules_listed (list_modules wire)
  | Data.Compile { name; new_symbol } ->
    let { output; failed } = compile_module wire ~name ~new_symbol in
    Data.Compiled { output; failed }
  | Data.Load name ->
    load_module wire name;
    Data.Module_loaded name
  | Data.Unload name -> Data.Module_unloaded { name; log = unload_module wire name }
  | Data.Call { cmd; args } ->
    let { log; failure } = run_command wire ~cmd ~args in
    Data.Called { log; failure }
;;
