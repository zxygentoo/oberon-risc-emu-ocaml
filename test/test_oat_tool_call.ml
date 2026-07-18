(* Tool_call tests: every operation exercised through Tool_call.execute — the
   module's whole surface — against an in-memory fake of the Oberon side
   speaking typed wire values over the Data.Wire.t seam (the byte codec around
   that seam is Io's, tested in test_oat_io). *)

open Oat
open Test_harness
module Wire = Data.Wire

(* --- the fake device --- *)

type fake =
  { files : (string, string) Hashtbl.t
  ; mutable modules : string list
  ; mutable call : (string -> string -> (Wire.status * string) option) option
    (* Ad-hoc CALL override: [Some (status, log)] short-circuits the default
       dispatch; [None] falls through to the built-in behavior. *)
  }

let new_fake () =
  { files = Hashtbl.create 8
  ; modules = [ "System"; "Oberon"; "AgentTool" ]
  ; call = None
  }
;;

let with_file fake name body =
  Hashtbl.replace fake.files name body;
  fake
;;

let le32 n =
  let b = Bytes.create 4 in
  Bytes.set_int32_le b 0 (Int32.of_int n);
  Bytes.to_string b
;;

let contains ~sub s =
  let n = String.length sub in
  let rec go i =
    i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
  in
  n = 0 || go 0
;;

let dispatch_call fake cmd par =
  match
    match fake.call with
    | Some f -> f cmd par
    | None -> None
  with
  | Some out -> out
  | None ->
    let arg = String.trim (String.map (fun c -> if c = '\r' then '\n' else c) par) in
    (match cmd with
     | "System.DeleteFiles" ->
       if Hashtbl.mem fake.files arg
       then (
         Hashtbl.remove fake.files arg;
         Wire.Ok, Printf.sprintf "System.DeleteFiles\n%s deleting\n" arg)
       else Wire.Ok, Printf.sprintf "System.DeleteFiles\n%s deleting failed\n" arg
     | "System.Free" ->
       (* EO syntax: one or more module names then optional /f. *)
       let parts =
         String.split_on_char ' ' arg |> List.filter (fun p -> p <> "" && p <> "/f")
       in
       (match parts with
        | first :: _ ->
          fake.modules <- List.filter (fun m -> m <> first) fake.modules;
          let action =
            if contains ~sub:"/f" arg then "removing from module list" else "unloading"
          in
          Wire.Ok, Printf.sprintf "System.Free\n%s %s\n" first action
        | [] -> Wire.Ok, "System.Free\n")
     | "AgentTool.Load" ->
       fake.modules <- arg :: fake.modules;
       Wire.Ok, Printf.sprintf "loaded %s\n" arg
     | "AgentTool.Version" -> Wire.Ok, "Extended Oberon System  AP 1.1.26\n"
     | "AgentTool.ListFiles" ->
       let names = Hashtbl.fold (fun k _ acc -> k :: acc) fake.files [] in
       let lines =
         List.sort compare names
         |> List.map (fun n ->
           Printf.sprintf
             "%s\t%d\t01.01.24 00:00:00"
             n
             (String.length (Hashtbl.find fake.files n)))
       in
       Wire.Ok, String.concat "\n" lines ^ "\n"
     | "AgentTool.ListModules" ->
       let lines =
         List.sort compare fake.modules
         |> List.map (fun m -> Printf.sprintf "%s\t0\t 00001000" m)
       in
       Wire.Ok, String.concat "\n" lines ^ "\n"
     | _ -> Wire.Ok, "")
;;

(* Mirrors AgentProtocol's DoEdit: non-overlapping count, splice at the first match,
   occurrence count in the not-unique payload. *)
let dispatch_edit fake name old new_ =
  let empty status = { Wire.status; payload = "" } in
  if old = "" || String.length old > Wire.edit_old_limit
  then empty Wire.Error
  else (
    match Hashtbl.find_opt fake.files name with
    | None -> empty Wire.Not_found
    | Some content ->
      let n = String.length old in
      let rec scan i count first =
        if i + n > String.length content
        then count, first
        else if String.sub content i n = old
        then scan (i + n) (count + 1) (if first < 0 then i else first)
        else scan (i + 1) count first
      in
      (match scan 0 0 (-1) with
       | 0, _ -> empty Wire.No_match
       | 1, at ->
         Hashtbl.replace
           fake.files
           name
           (String.sub content 0 at
            ^ new_
            ^ String.sub content (at + n) (String.length content - at - n));
         empty Wire.Ok
       | count, _ -> { Wire.status = Wire.Not_unique; payload = le32 count }))
;;

let wire_of fake : Wire.t = function
  | Wire.Get { name } ->
    (match Hashtbl.find_opt fake.files name with
     | Some data -> { Wire.status = Wire.Ok; payload = data }
     | None -> { Wire.status = Wire.Not_found; payload = "" })
  | Wire.Put { name; data } ->
    Hashtbl.replace fake.files name data;
    { Wire.status = Wire.Ok; payload = "" }
  | Wire.Call { cmd; par } ->
    let status, payload = dispatch_call fake cmd par in
    { Wire.status; payload }
  | Wire.Edit { name; old; new_ } -> dispatch_edit fake name old new_
;;

let expect_error name pred f =
  match f () with
  | _ -> check name false
  | exception Error.Error e -> check name (pred e)
;;

(* --- shorthands over the one surface --- *)

let exec w req = Tool_call.execute (wire_of w) req

let read w path =
  match exec w (Data.Read path) with
  | Data.Read content -> content
  | _ -> failwith "expected Data.Read"
;;

let write w path content = ignore (exec w (Data.Write { path; content }))
let edit w path old new_ = ignore (exec w (Data.Edit { path; old; new_ }))

let () =
  (* write / read round-trip; the device stores CR line separators, and the
     response reports the host-side byte count. *)
  let w = new_fake () in
  (match exec w (Data.Write { path = "M.Mod"; content = "MODULE M;\nEND M.\n" }) with
   | Data.Written { path = "M.Mod"; bytes = 17 } -> check "write_response" true
   | _ -> check "write_response" false);
  eqs "stored_with_cr" (Hashtbl.find w.files "M.Mod") "MODULE M;\rEND M.\r";
  eqs "read_roundtrip" (read w "M.Mod") "MODULE M;\nEND M.\n";
  (* Latin-1 fold (intentional divergence from Rust oat): non-ASCII round-trips. *)
  let w = new_fake () in
  write w "Acc.Txt" "caf\xC3\xA9\n";
  eqs "latin1_fold_on_device" (Hashtbl.find w.files "Acc.Txt") "caf\xE9\r";
  eqs "latin1_fold_roundtrip" (read w "Acc.Txt") "caf\xC3\xA9\n";
  expect_error
    "read_missing_not_found"
    (function
      | Error.File_not_found _ -> true
      | _ -> false)
    (fun () -> read (new_fake ()) "X.Mod");
  (* EDIT: wire path. *)
  let w = with_file (new_fake ()) "M.Mod" "a := 1;\r" in
  (match exec w (Data.Edit { path = "M.Mod"; old = "a := 1"; new_ = "a := 2" }) with
   | Data.Edited { path = "M.Mod" } -> check "edit_response" true
   | _ -> check "edit_response" false);
  eqs "edit_unique_replaces" (Hashtbl.find w.files "M.Mod") "a := 2;\r";
  expect_error
    "edit_old_not_found"
    (function
      | Error.Edit_not_found -> true
      | _ -> false)
    (fun () -> edit (with_file (new_fake ()) "M.Mod" "x\r") "M.Mod" "zzz" "q");
  expect_error
    "edit_old_not_unique_carries_count"
    (function
      | Error.Edit_not_unique 2 -> true
      | _ -> false)
    (fun () -> edit (with_file (new_fake ()) "M.Mod" "a a\r") "M.Mod" "a" "b");
  expect_error
    "edit_missing_file_not_found"
    (function
      | Error.File_not_found _ -> true
      | _ -> false)
    (fun () -> edit (new_fake ()) "Gone.Mod" "a" "b");
  let w = with_file (new_fake ()) "M.Mod" "keep drop keep\r" in
  edit w "M.Mod" " drop" "";
  eqs "edit_empty_new_deletes" (Hashtbl.find w.files "M.Mod") "keep keep\r";
  (* OLD spanning a line break: LF in the argument must match the CR stored on the
     device. *)
  let w = with_file (new_fake ()) "M.Mod" "a;\rb;\rc;\r" in
  edit w "M.Mod" "a;\nb;" "d;";
  eqs "edit_multiline_matches_cr" (Hashtbl.find w.files "M.Mod") "d;\rc;\r";
  (* OLD beyond the device buffer takes the host-side GET+PUT path; a line break
     inside OLD still matches (both paths normalize). *)
  let long = String.make 600 'x' ^ "\n" ^ String.make 600 'y' in
  let w = new_fake () in
  write w "Big.Txt" ("head\n" ^ long ^ "\ntail\n");
  edit w "Big.Txt" long "z";
  eqs "edit_long_old_falls_back" (read w "Big.Txt") "head\nz\ntail\n";
  (* Exactly edit_old_limit device bytes still fits the device buffer. *)
  let old = String.make Wire.edit_old_limit 'x' in
  let w = new_fake () in
  write w "Lim.Txt" ("a" ^ old ^ "b");
  edit w "Lim.Txt" old "-";
  eqs "edit_old_at_limit_wire_path" (read w "Lim.Txt") "a-b";
  (* The device's trap recovery answers EDIT with stTrapped. *)
  expect_error
    "edit_trapped_maps_to_trapped"
    (function
      | Error.Trapped -> true
      | _ -> false)
    (fun () ->
       let always_trapped _ = { Wire.status = Wire.Trapped; payload = "" } in
       Tool_call.execute always_trapped (Data.Edit { path = "M.Mod"; old = "a"; new_ = "b" }));
  (* delete. *)
  let w = with_file (new_fake ()) "M.Mod" "x\r" in
  (match exec w (Data.Delete "M.Mod") with
   | Data.Deleted { path = "M.Mod" } -> check "delete_response" true
   | _ -> check "delete_response" false);
  check "delete_removes" (not (Hashtbl.mem w.files "M.Mod"));
  expect_error
    "delete_absent_not_found"
    (function
      | Error.File_not_found _ -> true
      | _ -> false)
    (fun () -> ignore (exec w (Data.Delete "Gone.Mod")));
  (* Guards the full-phrase match: a file *named* "failed" must not be misread as a
     deletion failure. *)
  let w = with_file (new_fake ()) "failed.Mod" "x" in
  ignore (exec w (Data.Delete "failed.Mod"));
  check "delete_failed_name_not_misread" (not (Hashtbl.mem w.files "failed.Mod"));
  (* listings. *)
  let w = with_file (with_file (new_fake ()) "A.Mod" "xx") "B.Mod" "yyy" in
  (match exec w (Data.List_files "") with
   | Data.Listed_files out ->
     check "list_files_tsv_a" (contains ~sub:"A.Mod\t2" out);
     check "list_files_tsv_b" (contains ~sub:"B.Mod\t3" out)
   | _ -> check "list_files_tsv_a" false);
  (match exec (new_fake ()) Data.List_modules with
   | Data.Listed_modules out ->
     check "list_modules_seeded" (contains ~sub:"AgentTool\t" out)
   | _ -> check "list_modules_seeded" false);
  (* check: trimmed version line plus the host-side round-trip timing. *)
  (match exec (new_fake ()) Data.Check with
   | Data.Checked { version; rtt_ms } ->
     eqs "check_version_trimmed" version "Extended Oberon System  AP 1.1.26";
     check "check_rtt_nonneg" (rtt_ms >= 0)
   | _ -> check "check_version_trimmed" false);
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ -> if cmd = "AgentTool.Version" then Some (Wire.Ok, "") else None);
  (match exec w Data.Check with
   | Data.Checked { version = ""; _ } -> check "check_version_empty" true
   | _ -> check "check_version_empty" false);
  (* load. *)
  (match exec (new_fake ()) (Data.Load "Foo") with
   | Data.Loaded "Foo" -> check "load_ok" true
   | _ -> check "load_ok" false);
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "AgentTool.Load"
          then Some (Wire.Ok, "AgentTool.Load\n  res=2\n")
          else None);
  expect_error
    "load_failure_parses_res"
    (function
      | Error.Load_failed { res = Some 2; _ } -> true
      | _ -> false)
    (fun () -> ignore (exec w (Data.Load "Bad")));
  (* unload. *)
  (match exec (new_fake ()) (Data.Unload "Foo") with
   | Data.Unloaded { name = "Foo"; log } ->
     check "unload_response_log" (contains ~sub:"removing from module list" log)
   | _ -> check "unload_response_log" false);
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "System.Free"
          then Some (Wire.Ok, "System.Free\n  X unloading failed, try /f option\n")
          else None);
  expect_error
    "unload_in_use_detected"
    (function
      | Error.Unload_in_use _ -> true
      | _ -> false)
    (fun () -> ignore (exec w (Data.Unload "X")));
  (* compile: the log always comes back; FAILED becomes the in-band flag. *)
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "ORP.Compile"
          then Some (Wire.Ok, "  compiling M\n  pos 5 undef\ncompilation FAILED\n")
          else None);
  (match exec w (Data.Compile { name = "M.Mod"; new_symbol = false }) with
   | Data.Compiled { output; failed } ->
     check "compile_failed_flag" failed;
     check "compile_raw_log" (contains ~sub:"undef" output)
   | _ -> check "compile_failed_flag" false);
  let w = new_fake () in
  let saw_slash_s = ref false in
  w.call
  <- Some
       (fun cmd par ->
          if cmd = "ORP.Compile"
          then (
            saw_slash_s := contains ~sub:"M.Mod/s" par;
            Some (Wire.Ok, "  compiling M new symbol file  10 4 ABCD\n"))
          else None);
  (match exec w (Data.Compile { name = "M.Mod"; new_symbol = true }) with
   | Data.Compiled { failed; _ } ->
     check "compile_new_symbol_ok" (not failed);
     check "compile_new_symbol_slash_s" !saw_slash_s
   | _ -> check "compile_new_symbol_ok" false);
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ -> if cmd = "ORP.Compile" then Some (Wire.Error, "") else None);
  expect_error
    "compile_non_ok_is_bad_status"
    (function
      | Error.Bad_status 3 -> true
      | _ -> false)
    (fun () -> ignore (exec w (Data.Compile { name = "M.Mod"; new_symbol = false })));
  (* call: the log always comes back; the status maps to an in-band failure. *)
  let w = new_fake () in
  w.call <- Some (fun _ _ -> Some (Wire.Trapped, "trap log\n"));
  (match exec w (Data.Call { cmd = "Bad.Cmd"; args = "" }) with
   | Data.Called { log; failure } ->
     eqs "call_trap_log" log "trap log\n";
     check "call_trapped_failure" (failure = Some Error.Trapped)
   | _ -> check "call_trapped_failure" false);
  let w = new_fake () in
  w.call <- Some (fun _ _ -> Some (Wire.Error, ""));
  (match exec w (Data.Call { cmd = "Bad.Cmd"; args = "" }) with
   | Data.Called { failure; _ } ->
     check "call_bad_status_failure" (failure = Some (Error.Bad_status 3))
   | _ -> check "call_bad_status_failure" false);
  (match exec (new_fake ()) (Data.Call { cmd = "Any.Cmd"; args = "" }) with
   | Data.Called { failure = None; _ } -> check "call_ok_no_failure" true
   | _ -> check "call_ok_no_failure" false);
  summary "oat tool_call checks"
;;
