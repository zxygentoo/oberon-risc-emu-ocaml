(* Tools-layer tests, ported from oat's tools.rs unit tests: each typed operation
   exercised against an in-memory fake of the Oberon side, wired through the real
   request codec (Protocol.For_tests), so the frames on the "wire" are the real
   ones. *)

open Oat
open Test_harness

(* --- the fake device (port of tools.rs FakeDevice) --- *)

type fake =
  { files : (string, string) Hashtbl.t
  ; mutable modules : string list
  ; mutable call : (string -> string -> (Protocol.status * string) option) option
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
         Protocol.Ok, Printf.sprintf "System.DeleteFiles\n%s deleting\n" arg)
       else Protocol.Ok, Printf.sprintf "System.DeleteFiles\n%s deleting failed\n" arg
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
          Protocol.Ok, Printf.sprintf "System.Free\n%s %s\n" first action
        | [] -> Protocol.Ok, "System.Free\n")
     | "AgentTool.Load" ->
       fake.modules <- arg :: fake.modules;
       Protocol.Ok, Printf.sprintf "loaded %s\n" arg
     | "AgentTool.Version" -> Protocol.Ok, "Extended Oberon System  AP 1.1.26\n"
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
       Protocol.Ok, String.concat "\n" lines ^ "\n"
     | "AgentTool.ListModules" ->
       let lines =
         List.sort compare fake.modules
         |> List.map (fun m -> Printf.sprintf "%s\t0\t 00001000" m)
       in
       Protocol.Ok, String.concat "\n" lines ^ "\n"
     | _ -> Protocol.Ok, "")
;;

(* Mirrors AgentProtocol's DoEdit: non-overlapping count, splice at the first match,
   occurrence count in the not-unique payload. *)
let dispatch_edit fake name old new_ =
  let empty status = { Protocol.status; payload = "" } in
  if old = "" || String.length old > Protocol.edit_old_limit
  then empty Protocol.Error
  else (
    match Hashtbl.find_opt fake.files name with
    | None -> empty Protocol.Not_found
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
       | 0, _ -> empty Protocol.No_match
       | 1, at ->
         Hashtbl.replace
           fake.files
           name
           (String.sub content 0 at
            ^ new_
            ^ String.sub content (at + n) (String.length content - at - n));
         empty Protocol.Ok
       | count, _ -> { Protocol.status = Protocol.Not_unique; payload = le32 count }))
;;

let send_of fake frame =
  let open Protocol.For_tests in
  match parse_request frame with
  | Get { name } ->
    (match Hashtbl.find_opt fake.files name with
     | Some data -> { Protocol.status = Protocol.Ok; payload = data }
     | None -> { Protocol.status = Protocol.Not_found; payload = "" })
  | Put { name; data } ->
    Hashtbl.replace fake.files name data;
    { Protocol.status = Protocol.Ok; payload = "" }
  | Call { cmd; par } ->
    let status, payload = dispatch_call fake cmd par in
    { Protocol.status; payload }
  | Edit { name; old; new_ } -> dispatch_edit fake name old new_
;;

let expect_error name pred f =
  match f () with
  | _ -> check name false
  | exception Error.Error e -> check name (pred e)
;;

let () =
  (* write / read round-trip; the device stores CR line separators. *)
  let w = new_fake () in
  Tools.write_file (send_of w) ~path:"M.Mod" ~content:"MODULE M;\nEND M.\n";
  eqs "stored_with_cr" (Hashtbl.find w.files "M.Mod") "MODULE M;\rEND M.\r";
  eqs "read_roundtrip" (Tools.read_file (send_of w) "M.Mod") "MODULE M;\nEND M.\n";
  (* Latin-1 fold (intentional divergence from Rust oat): non-ASCII round-trips. *)
  let w = new_fake () in
  Tools.write_file (send_of w) ~path:"Acc.Txt" ~content:"caf\xC3\xA9\n";
  eqs "latin1_fold_on_device" (Hashtbl.find w.files "Acc.Txt") "caf\xE9\r";
  eqs "latin1_fold_roundtrip" (Tools.read_file (send_of w) "Acc.Txt") "caf\xC3\xA9\n";
  expect_error
    "read_missing_not_found"
    (function
      | Error.File_not_found _ -> true
      | _ -> false)
    (fun () -> Tools.read_file (send_of (new_fake ())) "X.Mod");
  (* EDIT: wire path. *)
  let w = with_file (new_fake ()) "M.Mod" "a := 1;\r" in
  Tools.edit_file (send_of w) ~path:"M.Mod" ~old:"a := 1" ~new_:"a := 2";
  eqs "edit_unique_replaces" (Hashtbl.find w.files "M.Mod") "a := 2;\r";
  expect_error
    "edit_old_not_found"
    (function
      | Error.Edit_not_found -> true
      | _ -> false)
    (fun () ->
       let w = with_file (new_fake ()) "M.Mod" "x\r" in
       Tools.edit_file (send_of w) ~path:"M.Mod" ~old:"zzz" ~new_:"q");
  expect_error
    "edit_old_not_unique_carries_count"
    (function
      | Error.Edit_not_unique 2 -> true
      | _ -> false)
    (fun () ->
       let w = with_file (new_fake ()) "M.Mod" "a a\r" in
       Tools.edit_file (send_of w) ~path:"M.Mod" ~old:"a" ~new_:"b");
  expect_error
    "edit_missing_file_not_found"
    (function
      | Error.File_not_found _ -> true
      | _ -> false)
    (fun () -> Tools.edit_file (send_of (new_fake ())) ~path:"Gone.Mod" ~old:"a" ~new_:"b");
  let w = with_file (new_fake ()) "M.Mod" "keep drop keep\r" in
  Tools.edit_file (send_of w) ~path:"M.Mod" ~old:" drop" ~new_:"";
  eqs "edit_empty_new_deletes" (Hashtbl.find w.files "M.Mod") "keep keep\r";
  (* OLD spanning a line break: LF in the argument must match the CR stored on the
     device. *)
  let w = with_file (new_fake ()) "M.Mod" "a;\rb;\rc;\r" in
  Tools.edit_file (send_of w) ~path:"M.Mod" ~old:"a;\nb;" ~new_:"d;";
  eqs "edit_multiline_matches_cr" (Hashtbl.find w.files "M.Mod") "d;\rc;\r";
  (* OLD beyond the device buffer takes the host-side GET+PUT path; a line break
     inside OLD still matches (both paths normalize). *)
  let long = String.make 600 'x' ^ "\n" ^ String.make 600 'y' in
  let w = new_fake () in
  Tools.write_file (send_of w) ~path:"Big.Txt" ~content:("head\n" ^ long ^ "\ntail\n");
  Tools.edit_file (send_of w) ~path:"Big.Txt" ~old:long ~new_:"z";
  eqs "edit_long_old_falls_back" (Tools.read_file (send_of w) "Big.Txt") "head\nz\ntail\n";
  (* Exactly edit_old_limit device bytes still fits the device buffer. *)
  let old = String.make Protocol.edit_old_limit 'x' in
  let w = new_fake () in
  Tools.write_file (send_of w) ~path:"Lim.Txt" ~content:("a" ^ old ^ "b");
  Tools.edit_file (send_of w) ~path:"Lim.Txt" ~old ~new_:"-";
  eqs "edit_old_at_limit_wire_path" (Tools.read_file (send_of w) "Lim.Txt") "a-b";
  (* The device's trap recovery answers EDIT with stTrapped. *)
  expect_error
    "edit_trapped_maps_to_trapped"
    (function
      | Error.Trapped -> true
      | _ -> false)
    (fun () ->
       let always_trapped _ = { Protocol.status = Protocol.Trapped; payload = "" } in
       Tools.edit_file always_trapped ~path:"M.Mod" ~old:"a" ~new_:"b");
  (* delete. *)
  let w = with_file (new_fake ()) "M.Mod" "x\r" in
  Tools.delete_file (send_of w) "M.Mod";
  check "delete_removes" (not (Hashtbl.mem w.files "M.Mod"));
  expect_error
    "delete_absent_not_found"
    (function
      | Error.File_not_found _ -> true
      | _ -> false)
    (fun () -> Tools.delete_file (send_of w) "Gone.Mod");
  (* Guards the full-phrase match: a file *named* "failed" must not be misread as a
     deletion failure. *)
  let w = with_file (new_fake ()) "failed.Mod" "x" in
  Tools.delete_file (send_of w) "failed.Mod";
  check "delete_failed_name_not_misread" (not (Hashtbl.mem w.files "failed.Mod"));
  (* listings. *)
  let w = with_file (with_file (new_fake ()) "A.Mod" "xx") "B.Mod" "yyy" in
  let out = Tools.list_files (send_of w) ~prefix:"" in
  check "list_files_tsv_a" (contains ~sub:"A.Mod\t2" out);
  check "list_files_tsv_b" (contains ~sub:"B.Mod\t3" out);
  let out = Tools.list_modules (send_of (new_fake ())) in
  check "list_modules_seeded" (contains ~sub:"AgentTool\t" out);
  (* version. *)
  check
    "version_string"
    (contains ~sub:"Extended Oberon" (Tools.version (send_of (new_fake ()))));
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "AgentTool.Version" then Some (Protocol.Ok, "") else None);
  eqs "version_empty_payload" (Tools.version (send_of w)) "";
  (* load. *)
  Tools.load_module (send_of (new_fake ())) "Foo";
  check "load_ok" true;
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "AgentTool.Load"
          then Some (Protocol.Ok, "AgentTool.Load\n  res=2\n")
          else None);
  expect_error
    "load_failure_parses_res"
    (function
      | Error.Load_failed { res = Some 2; _ } -> true
      | _ -> false)
    (fun () -> Tools.load_module (send_of w) "Bad");
  (* unload. *)
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "System.Free"
          then Some (Protocol.Ok, "System.Free\n  X unloading failed, try /f option\n")
          else None);
  expect_error
    "unload_in_use_detected"
    (function
      | Error.Unload_in_use _ -> true
      | _ -> false)
    (fun () -> ignore (Tools.unload_module (send_of w) "X"));
  (* compile. *)
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "ORP.Compile"
          then Some (Protocol.Ok, "  compiling M\n  pos 5 undef\ncompilation FAILED\n")
          else None);
  let r = Tools.compile_module (send_of w) ~name:"M.Mod" ~new_symbol:false in
  check "compile_failed_flag" r.Tools.failed;
  check "compile_raw_log" (contains ~sub:"undef" r.Tools.output);
  let w = new_fake () in
  let saw_slash_s = ref false in
  w.call
  <- Some
       (fun cmd par ->
          if cmd = "ORP.Compile"
          then (
            saw_slash_s := contains ~sub:"M.Mod/s" par;
            Some (Protocol.Ok, "  compiling M new symbol file  10 4 ABCD\n"))
          else None);
  let r = Tools.compile_module (send_of w) ~name:"M.Mod" ~new_symbol:true in
  check "compile_new_symbol_ok" (not r.Tools.failed);
  check "compile_new_symbol_slash_s" !saw_slash_s;
  let w = new_fake () in
  w.call
  <- Some
       (fun cmd _ ->
          if cmd = "ORP.Compile" then Some (Protocol.Error, "") else None);
  expect_error
    "compile_non_ok_is_bad_status"
    (function
      | Error.Bad_status 3 -> true
      | _ -> false)
    (fun () -> ignore (Tools.compile_module (send_of w) ~name:"M.Mod" ~new_symbol:false));
  (* call. *)
  let w = new_fake () in
  w.call <- Some (fun _ _ -> Some (Protocol.Trapped, "trap log\n"));
  let r = Tools.run_command (send_of w) ~cmd:"Bad.Cmd" ~args:"" in
  eqs "run_command_trap_log" r.Tools.log "trap log\n";
  expect_error
    "run_command_trapped_outcome"
    (function
      | Error.Trapped -> true
      | _ -> false)
    (fun () -> Tools.call_outcome r);
  let r = Tools.run_command (send_of (new_fake ())) ~cmd:"Any.Cmd" ~args:"" in
  Tools.call_outcome r;
  check "run_command_ok_outcome" true;
  summary "oat tools checks"
;;
