(* Fsutil tests: the documented contracts the builders' scratch-dir lifecycle
   leans on (mkdir_p on existing dirs, rm_rf on missing paths). *)

open Oberon_tools
open Test_harness

let () =
  with_scratch ~prefix:"oberon_fsutil_" (fun dir ->
    (* mkdir_p creates missing parents; an existing directory is fine. *)
    let nested = Filename.concat (Filename.concat dir "a") "b" in
    Fsutil.mkdir_p nested;
    check "mkdir_p_nested" (Sys.is_directory nested);
    Fsutil.mkdir_p nested;
    check "mkdir_p_existing_ok" (Sys.is_directory nested);
    (* Whole-file write/read round-trip, and the option-returning reader. *)
    let f = Filename.concat nested "f.txt" in
    Fsutil.write_file f "hello";
    eqs "write_read_roundtrip" (Fsutil.read_file f) "hello";
    check "read_file_opt_some" (Fsutil.read_file_opt f = Some "hello");
    check "read_file_opt_none" (Fsutil.read_file_opt (Filename.concat dir "nope") = None);
    (* rm_rf removes a populated tree; a missing path is a no-op. *)
    Fsutil.rm_rf (Filename.concat dir "a");
    check "rm_rf_tree" (not (Sys.file_exists (Filename.concat dir "a")));
    Fsutil.rm_rf (Filename.concat dir "a");
    check "rm_rf_missing_ok" (not (Sys.file_exists (Filename.concat dir "a"))));
  summary "fsutil checks"
;;
