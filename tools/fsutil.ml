(** Whole-file and directory-tree helpers shared across the host tools. *)

let read_file path = In_channel.with_open_bin path In_channel.input_all

let read_file_opt path =
  try Some (read_file path) with
  | Sys_error _ -> None
;;

let write_file path data =
  Out_channel.with_open_bin path (fun oc -> output_string oc data)
;;

let rec mkdir_p dir =
  if dir = "" || dir = Filename.current_dir_name || Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

(* lstat, not Sys.is_directory: a symlink to a directory is removed as a link,
   never descended into — that would empty whatever it points at. *)
let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;
