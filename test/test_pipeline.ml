(* Pipeline filesystem-helper tests, ported from pipeline.rs. *)

open Oberon_tools
module P = Pipeline.For_tests

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun n -> rm_rf (Filename.concat path n)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path
;;

let fresh tag =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "ml-image-test-%d-%s" (Unix.getpid ()) tag)
  in
  rm_rf dir;
  Unix.mkdir dir 0o755;
  dir
;;

let write path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)
let exists dir name = Sys.file_exists (Filename.concat dir name)

let () =
  (* bulk_rename only touches matching extensions *)
  (let dir = fresh "rename" in
   write (Filename.concat dir "A.rsc") "a";
   write (Filename.concat dir "B.rsc") "b";
   write (Filename.concat dir "keep.smb") "k";
   P.bulk_rename dir "rsc" "rsx";
   check "rename_A" (exists dir "A.rsx");
   check "rename_B" (exists dir "B.rsx");
   check "rename_no_old" (not (exists dir "A.rsc"));
   check "rename_keep_smb" (exists dir "keep.smb");
   rm_rf dir);
  (* bulk_delete only removes matching extensions *)
  (let dir = fresh "delete" in
   write (Filename.concat dir "A.smb") "a";
   write (Filename.concat dir "B.rsc") "b";
   P.bulk_delete dir "smb";
   check "delete_removed" (not (exists dir "A.smb"));
   check "delete_kept" (exists dir "B.rsc");
   rm_rf dir);
  (* sorted_visible skips dotfiles and sorts *)
  (let dir = fresh "visible" in
   write (Filename.concat dir "b.txt") "";
   write (Filename.concat dir "a.txt") "";
   write (Filename.concat dir ".hidden") "";
   check "sorted_visible" (P.sorted_visible dir = [ "a.txt"; "b.txt" ]);
   rm_rf dir);
  (* extract_toolchain writes every entry *)
  (let dir = fresh "toolchain" in
   P.extract_toolchain
     [ "InnerCore", "core"; "Kernel.Mod", "glue"; "ORP.rsc", "object" ]
     dir;
   check "tc_innercore" (exists dir "InnerCore");
   check "tc_kernel" (exists dir "Kernel.Mod");
   check "tc_orp" (exists dir "ORP.rsc");
   rm_rf dir);
  if !failures = 0
  then Printf.printf "ok: %d pipeline checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d pipeline checks failed\n" !failures !total;
    exit 1)
;;
