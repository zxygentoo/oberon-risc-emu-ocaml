(** The typed oat operations on the Oberon device — the semantics layer. *)

module Wire = Data.Wire

(* Device text via the shared ob2txt/txt2ob transforms ({!Oberon_tools.Convert}).
   Intentional divergence from the Rust oat, whose to_oberon sends raw UTF-8 bytes to
   the device: the Latin-1 fold makes non-ASCII writes round-trip on read. *)
let to_oberon = Oberon_tools.Convert.to_oberon
let from_oberon = Oberon_tools.Convert.from_oberon

let bad_status s = Error.fail (Error.Bad_status (Wire.status_byte s))
let check_ok (r : Wire.response) = if r.status <> Wire.Ok then bad_status r.status

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

(* Non-overlapping occurrence count and first-match offset (0 when there is
   none), Rust's [s.matches(sub).count()] — which for an empty pattern matches
   at every char boundary (len + 1 occurrences, the first at 0). One scan
   serves both the uniqueness check and the splice in the edit fallback. *)
let occurrences ~sub s =
  if sub = ""
  then String.length s + 1, 0
  else (
    let rec go from count first =
      match find_sub ~sub ~from s with
      | None -> count, first
      | Some i -> go (i + String.length sub) (count + 1) (if count = 0 then i else first)
    in
    go 0 0 0)
;;

let contains ~sub s = sub = "" || find_sub ~sub ~from:0 s <> None

(* --- internals --- *)

let call_log (wire : Wire.t) ~cmd ~args =
  let r = wire (Wire.Call { cmd; par = to_oberon args }) in
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

let read_file (wire : Wire.t) path =
  let r = wire (Wire.Get { name = path }) in
  match r.status with
  | Wire.Ok ->
    (* Only a GET payload can carry the 0F1X header of a [Texts.Close]-written file,
       so the strip lives here alone; logs and edit fragments never have one. (The
       Rust oat strips inside every from_oberon — inert difference in practice.) *)
    from_oberon (Oberon_tools.Convert.strip_text_header r.payload)
  | Wire.Not_found -> Error.fail (Error.File_not_found path)
  | s -> bad_status s
;;

let write_file (wire : Wire.t) ~path ~content =
  let data = to_oberon content in
  if String.length data > Wire.put_limit
  then
    Error.fail
      (Error.Put_too_large { bytes = String.length data; limit = Wire.put_limit });
  check_ok (wire (Wire.Put { name = path; data }))
;;

(* Fallback for fragments EDIT cannot carry: full read-modify-write through GET and
   PUT. [old_dev] is the fragment already in device form; converting it back puts
   both paths' matching in the same (host) space. *)
let edit_file_via_rw (wire : Wire.t) ~path ~old_dev ~new_ =
  let old = from_oberon old_dev in
  let content = read_file wire path in
  let count, first = occurrences ~sub:old content in
  if count = 0 then Error.fail Error.Edit_not_found;
  if count > 1 then Error.fail (Error.Edit_not_unique count);
  let tail = first + String.length old in
  write_file
    wire
    ~path
    ~content:
      (String.sub content 0 first
       ^ new_
       ^ String.sub content tail (String.length content - tail))
;;

(* Normally one EDIT round-trip — the device matches OLD inside the file via its
   Texts piece list and splices NEW in atomically; fragments over edit_old_limit
   take the host-side fallback above. *)
let edit_file (wire : Wire.t) ~path ~old ~new_ =
  let old_dev = to_oberon old in
  if old_dev = "" || String.length old_dev > Wire.edit_old_limit
  then edit_file_via_rw wire ~path ~old_dev ~new_
  else (
    let r = wire (Wire.Edit { name = path; old = old_dev; new_ = to_oberon new_ }) in
    match r.status with
    | Wire.Ok -> ()
    | Wire.Not_found -> Error.fail (Error.File_not_found path)
    | Wire.No_match -> Error.fail Error.Edit_not_found
    | Wire.Not_unique -> Error.fail (Error.Edit_not_unique (Wire.not_unique_count r))
    | Wire.Trapped -> Error.fail Error.Trapped
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
     System.Free scanner discards — so the module is unloaded the unsafe way. Both
     variants log "unloading failed" on an in-use refusal (PO: Modules.res = 1
     when other modules still import the target) — but PO's refcnt only counts
     module imports, so a PO unload that "succeeds" can still leave live heap or
     viewer references dangling, which is why the skill insists on operator
     permission before any unload on PO. *)
  let log = call_log wire ~cmd:"System.Free" ~args:(name ^ " /f") in
  if contains ~sub:"unloading failed" log
  then Error.fail (Error.Unload_in_use log);
  log
;;

let execute (wire : Wire.t) (request : Data.request) : Data.response =
  match request with
  | Data.Check ->
    let start = Unix.gettimeofday () in
    let version = version wire in
    let rtt_ms = int_of_float ((Unix.gettimeofday () -. start) *. 1000.0) in
    Data.Checked { version; rtt_ms }
  | Data.Read path -> Data.Read (read_file wire path)
  | Data.Write { path; content } ->
    write_file wire ~path ~content;
    Data.Written { path; bytes = String.length content }
  | Data.Edit { path; old; new_ } ->
    edit_file wire ~path ~old ~new_;
    Data.Edited { path }
  | Data.Delete path ->
    delete_file wire path;
    Data.Deleted { path }
  | Data.List_files prefix -> Data.Listed_files (list_files wire ~prefix)
  | Data.List_modules -> Data.Listed_modules (list_modules wire)
  | Data.Compile { name; new_symbol } ->
    (* The compiler log always comes back; the FAILED phrase becomes the in-band
       failure flag, so the log can be printed before the process fails. *)
    let output =
      call_log wire ~cmd:"ORP.Compile" ~args:(if new_symbol then name ^ "/s" else name)
    in
    Data.Compiled { output; failed = contains ~sub:"compilation FAILED" output }
  | Data.Load name ->
    load_module wire name;
    Data.Loaded name
  | Data.Unload name -> Data.Unloaded { name; log = unload_module wire name }
  | Data.Call { cmd; args } ->
    (* The Oberon.Log delta written while the command ran, with the device status
       mapped to the command's error ([Trapped] or [Bad_status]) in-band, so the
       log can be printed first. *)
    let r = wire (Wire.Call { cmd; par = to_oberon args }) in
    let failure =
      match r.status with
      | Wire.Ok -> None
      | Wire.Trapped -> Some Error.Trapped
      | s -> Some (Error.Bad_status (Wire.status_byte s))
    in
    Data.Called { log = from_oberon r.payload; failure }
;;
