(** High-level oat operations on the Oberon device (port of oat's [tools.rs]). *)

open Protocol

(* Device text via the shared ob2txt/txt2ob transforms ({!Oberon_tools.Convert}); reads
   additionally strip the 0F1X Texts header of files written by [Texts.Close].
   Intentional divergence from the Rust oat, whose to_oberon sends raw UTF-8 bytes to
   the device: the Latin-1 fold makes non-ASCII writes round-trip on read. *)
let to_oberon = Oberon_tools.Convert.to_oberon
let from_oberon data = Oberon_tools.Convert.from_oberon (Oberon_tools.Convert.strip_text_header data)

type compile_result =
  { output : string
  ; failed : bool
  }

type call_result =
  { log : string
  ; status : Protocol.status
  }

let call_outcome r =
  match r.status with
  | Ok -> ()
  | Trapped -> Error.fail Error.Trapped
  | s -> Error.fail (Error.Bad_status (status_byte s))
;;

(* --- string helpers (Rust's str::matches / replacen / contains) --- *)

(* Does [sub] occur at [i]? Callers keep [i + String.length sub] in range. *)
let matches_at s ~sub i =
  let n = String.length sub in
  let rec eq k = k = n || (s.[i + k] = sub.[k] && eq (k + 1)) in
  eq 0
;;

(* Non-overlapping occurrence count, Rust's [s.matches(sub).count()] — which for an
   empty pattern matches at every char boundary (len + 1). *)
let count_occurrences ~sub s =
  let n = String.length sub in
  if n = 0
  then String.length s + 1
  else (
    let rec go i count =
      if i + n > String.length s
      then count
      else if matches_at s ~sub i
      then go (i + n) (count + 1)
      else go (i + 1) count
    in
    go 0 0)
;;

(* Rust's [s.replacen(sub, by, 1)]; an empty pattern matches at position 0. *)
let replace_first ~sub ~by s =
  let n = String.length sub in
  let rec find i =
    if i + n > String.length s
    then None
    else if matches_at s ~sub i
    then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> s
  | Some at -> String.sub s 0 at ^ by ^ String.sub s (at + n) (String.length s - at - n)
;;

let contains ~sub s = count_occurrences ~sub s > 0

(* --- internals --- *)

(* Occurrence count from a [Not_unique] payload (u32 LE); 0 if absent. *)
let le_count payload =
  if String.length payload < 4
  then 0
  else Int32.to_int (String.get_int32_le payload 0) land 0xFFFFFFFF
;;

let call_log (send : Protocol.send) ~cmd ~args =
  let r = send (build_call ~cmd ~par:(to_oberon args)) in
  if not (ok r) then Error.fail (Error.Bad_status (status_byte r.status));
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

let read_file (send : Protocol.send) path =
  let r = send (build_get ~name:path) in
  match r.status with
  | Ok -> from_oberon r.payload
  | Not_found -> Error.fail (Error.File_not_found path)
  | s -> Error.fail (Error.Bad_status (status_byte s))
;;

let write_file (send : Protocol.send) ~path ~content =
  let r = send (build_put ~name:path ~data:(to_oberon content)) in
  if not (ok r) then Error.fail (Error.Bad_status (status_byte r.status))
;;

(* Fallback for fragments EDIT cannot carry: full read-modify-write through GET and
   PUT. Fragments are normalized through the same LF/CR conversion the wire path
   applies, so both paths match in the same space. *)
let edit_file_via_rw (send : Protocol.send) ~path ~old ~new_ =
  let old = from_oberon (to_oberon old) in
  let content = read_file send path in
  let count = count_occurrences ~sub:old content in
  if count = 0 then Error.fail Error.Edit_not_found;
  if count > 1 then Error.fail (Error.Edit_not_unique count);
  write_file send ~path ~content:(replace_first ~sub:old ~by:new_ content)
;;

let edit_file (send : Protocol.send) ~path ~old ~new_ =
  let old_dev = to_oberon old in
  if old_dev = "" || String.length old_dev > edit_old_limit
  then edit_file_via_rw send ~path ~old ~new_
  else (
    let r = send (build_edit ~name:path ~old:old_dev ~new_:(to_oberon new_)) in
    match r.status with
    | Ok -> ()
    | Not_found -> Error.fail (Error.File_not_found path)
    | No_match -> Error.fail Error.Edit_not_found
    | Not_unique -> Error.fail (Error.Edit_not_unique (le_count r.payload))
    | Trapped -> Error.fail Error.Trapped
    | s -> Error.fail (Error.Bad_status (status_byte s)))
;;

let delete_file send path =
  let log = call_log send ~cmd:"System.DeleteFiles" ~args:path in
  (* System.Mod writes "<name> deleting" on success, "<name> deleting failed" on
     res # 0. Match the full phrase so a filename containing "failed" doesn't trip
     the check. *)
  if contains ~sub:"deleting failed" log
  then Error.fail (Error.File_not_found path)
;;

let list_files send ~prefix = call_log send ~cmd:"AgentTool.ListFiles" ~args:prefix
let list_modules send = call_log send ~cmd:"AgentTool.ListModules" ~args:""
let version send = String.trim (call_log send ~cmd:"AgentTool.Version" ~args:"")

let load_module send name =
  let log = call_log send ~cmd:"AgentTool.Load" ~args:name in
  if not (String.starts_with ~prefix:"loaded" (String.trim log))
  then Error.fail (Error.Load_failed { res = parse_res log; log })
;;

let unload_module send name =
  (* We always pass /f. On EO that triggers safe-unload (hide-and-rename when live
     refs persist, full removal otherwise). On PO, /f tokenizes as junk that the
     System.Free scanner discards — so the module is unloaded the unsafe way. The
     "unloading failed" phrase is EO-only; on PO an in-use refusal goes undetected
     here, which is why the skill insists on operator permission before any unload
     on PO. *)
  let log = call_log send ~cmd:"System.Free" ~args:(name ^ " /f") in
  if contains ~sub:"unloading failed" log
  then Error.fail (Error.Unload_in_use log);
  log
;;

let compile_module (send : Protocol.send) ~name ~new_symbol =
  let par = if new_symbol then name ^ "/s" else name in
  let r = send (build_call ~cmd:"ORP.Compile" ~par:(to_oberon par)) in
  if not (ok r) then Error.fail (Error.Bad_status (status_byte r.status));
  let output = from_oberon r.payload in
  { output; failed = contains ~sub:"compilation FAILED" output }
;;

let run_command (send : Protocol.send) ~cmd ~args =
  let r = send (build_call ~cmd ~par:(to_oberon args)) in
  { log = from_oberon r.payload; status = r.status }
;;
