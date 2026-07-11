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

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path
;;
