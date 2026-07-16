(** High-level oat operations on the Oberon device (port of oat's [tools.rs]). *)

open Protocol

(* Device text via the shared ob2txt/txt2ob transforms ({!Oberon_tools.Convert}).
   Intentional divergence from the Rust oat, whose to_oberon sends raw UTF-8 bytes to
   the device: the Latin-1 fold makes non-ASCII writes round-trip on read. *)
let to_oberon = Oberon_tools.Convert.to_oberon
let from_oberon = Oberon_tools.Convert.from_oberon

type compile_result =
  { output : string
  ; failed : bool
  }

type call_result =
  { log : string
  ; status : Protocol.status
    (* Interpreted by {!call_outcome} alone — don't match on it elsewhere (the Rust
       original keeps this field private to tools.rs). *)
  }

let bad_status s = Error.fail (Error.Bad_status (status_byte s))
let check_ok r = if not (ok r) then bad_status r.status

let call_outcome r =
  match r.status with
  | Ok -> ()
  | Trapped -> Error.fail Error.Trapped
  | s -> bad_status s
;;

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

let call_log (send : Protocol.send) ~cmd ~args =
  let r = send (build_call ~cmd ~par:(to_oberon args)) in
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

let read_file (send : Protocol.send) path =
  let r = send (build_get ~name:path) in
  match r.status with
  | Ok ->
    (* Only a GET payload can carry the 0F1X header of a [Texts.Close]-written file,
       so the strip lives here alone; logs and edit fragments never have one. (The
       Rust oat strips inside every from_oberon — inert difference in practice.) *)
    from_oberon (Oberon_tools.Convert.strip_text_header r.payload)
  | Not_found -> Error.fail (Error.File_not_found path)
  | s -> bad_status s
;;

let write_file (send : Protocol.send) ~path ~content =
  check_ok (send (build_put ~name:path ~data:(to_oberon content)))
;;

(* Fallback for fragments EDIT cannot carry: full read-modify-write through GET and
   PUT. [old_dev] is the fragment already in device form; converting it back puts
   both paths' matching in the same (host) space. *)
let edit_file_via_rw (send : Protocol.send) ~path ~old_dev ~new_ =
  let old = from_oberon old_dev in
  let content = read_file send path in
  let count = count_occurrences ~sub:old content in
  if count = 0 then Error.fail Error.Edit_not_found;
  if count > 1 then Error.fail (Error.Edit_not_unique count);
  write_file send ~path ~content:(replace_first ~sub:old ~by:new_ content)
;;

let edit_file (send : Protocol.send) ~path ~old ~new_ =
  let old_dev = to_oberon old in
  if old_dev = "" || String.length old_dev > edit_old_limit
  then edit_file_via_rw send ~path ~old_dev ~new_
  else (
    let r = send (build_edit ~name:path ~old:old_dev ~new_:(to_oberon new_)) in
    match r.status with
    | Ok -> ()
    | Not_found -> Error.fail (Error.File_not_found path)
    | No_match -> Error.fail Error.Edit_not_found
    | Not_unique -> Error.fail (Error.Edit_not_unique (not_unique_count r))
    | Trapped -> Error.fail Error.Trapped
    | s -> bad_status s)
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
  check_ok r;
  let output = from_oberon r.payload in
  { output; failed = contains ~sub:"compilation FAILED" output }
;;

let run_command (send : Protocol.send) ~cmd ~args =
  let r = send (build_call ~cmd ~par:(to_oberon args)) in
  { log = from_oberon r.payload; status = r.status }
;;
