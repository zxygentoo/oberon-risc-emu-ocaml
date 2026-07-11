(* Pipeline filesystem-helper tests, ported from pipeline.rs. *)

open Oberon_tools
open Test_harness
module P = Pipeline.For_tests

let fresh tag =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "ml-image-test-%d-%s" (Unix.getpid ()) tag)
  in
  Fsutil.rm_rf dir;
  Unix.mkdir dir 0o755;
  dir
;;

let exists dir name = Sys.file_exists (Filename.concat dir name)

let () =
  (* bulk_rename only touches matching extensions *)
  (let dir = fresh "rename" in
   Fsutil.write_file (Filename.concat dir "A.rsc") "a";
   Fsutil.write_file (Filename.concat dir "B.rsc") "b";
   Fsutil.write_file (Filename.concat dir "keep.smb") "k";
   P.bulk_rename dir "rsc" "rsx";
   check "rename_A" (exists dir "A.rsx");
   check "rename_B" (exists dir "B.rsx");
   check "rename_no_old" (not (exists dir "A.rsc"));
   check "rename_keep_smb" (exists dir "keep.smb");
   rm_rf dir);
  (* bulk_delete only removes matching extensions *)
  (let dir = fresh "delete" in
   Fsutil.write_file (Filename.concat dir "A.smb") "a";
   Fsutil.write_file (Filename.concat dir "B.rsc") "b";
   P.bulk_delete dir "smb";
   check "delete_removed" (not (exists dir "A.smb"));
   check "delete_kept" (exists dir "B.rsc");
   rm_rf dir);
  (* sorted_visible skips dotfiles and sorts *)
  (let dir = fresh "visible" in
   Fsutil.write_file (Filename.concat dir "b.txt") "";
   Fsutil.write_file (Filename.concat dir "a.txt") "";
   Fsutil.write_file (Filename.concat dir ".hidden") "";
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
  summary "pipeline checks"
;;
