(** The shared disk-image build pipeline (port of [host_tools::pipeline]). *)

open Risc_core

type seed =
  { toolchain : (string * string) list
  ; golden_inner_core : string
  ; name : string
  }

(* Modules compiled to seed the host toolchain, then linked into a fresh inner core
   (project-norebo's build_norebo set). Identical for PO2013 and EO. *)
let norebo_modules =
  [ "Norebo.Mod"
  ; "Kernel.Mod"
  ; "FileDir.Mod"
  ; "Files.Mod"
  ; "Modules.Mod"
  ; "Fonts.Mod"
  ; "Texts.Mod"
  ; "RS232.Mod"
  ; "Oberon.Mod"
  ; "ORS.Mod"
  ; "ORB.Mod"
  ; "ORG.Mod"
  ; "ORP.Mod"
  ; "CoreLinker.Mod"
  ; "VDisk.Mod"
  ; "VFileDir.Mod"
  ; "VFiles.Mod"
  ; "VDiskUtil.Mod"
  ]
;;

let packonly_help =
  "The .packonly manifest:\n\
  \  Every file in SOURCES_DIR is compiled as Oberon source and packed into the\n\
  \  image, except those listed in `.packonly` (at the tree root), which are packed\n\
  \  verbatim: data such as fonts and tools, and reference modules that ship as\n\
  \  source but are not meant to compile.\n\n\
  \  The manifest is required; an empty one compiles everything. One file name per\n\
  \  line; blank lines and `#` comments are ignored.\n\n\
  \  extract-source generates .packonly."
;;

(* ---- Filesystem helpers --------------------------------------------------- *)

let read_file path = In_channel.with_open_bin path In_channel.input_all

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

let mksubdir parent name =
  let p = Filename.concat parent name in
  Unix.mkdir p 0o755;
  p
;;

let has_ext name ext = Filename.extension name = "." ^ ext

(* Rename every [*.old_ext] in [dir] to [*.new_ext]. *)
let bulk_rename dir old_ext new_ext =
  Array.iter
    (fun name ->
      if has_ext name old_ext
      then
        Sys.rename
          (Filename.concat dir name)
          (Filename.concat dir (Filename.remove_extension name ^ "." ^ new_ext)))
    (Sys.readdir dir)
;;

(* Delete every [*.ext] in [dir]. *)
let bulk_delete dir ext =
  Array.iter
    (fun name -> if has_ext name ext then Sys.remove (Filename.concat dir name))
    (Sys.readdir dir)
;;

(* Non-hidden entries of [dir], sorted (the install order). *)
let sorted_visible dir =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun n -> not (String.length n > 0 && n.[0] = '.'))
  |> List.sort String.compare
;;

(* File names in [dir] with extension [ext], sorted. *)
let files_with_ext dir ext =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun n -> has_ext n ext)
  |> List.sort String.compare
;;

(* Write a toolchain seed ([name -> bytes]) flat into [dir]. *)
let extract_toolchain toolchain dir =
  mkdir_p dir;
  List.iter (fun (name, bytes) -> write_file (Filename.concat dir name) bytes) toolchain
;;

(* ---- Driving the shim ----------------------------------------------------- *)

(* Run one Oberon command through the shim, failing on a non-zero exit. *)
let run_checked args cwd path =
  match Shim.run args ~cwd ~path with
  | Ok 0 -> ()
  | Ok code ->
    failwith
      (Printf.sprintf
         "%s exited with code %d"
         (match args with
          | a :: _ -> a
          | [] -> "?")
         code)
  | Error msg -> failwith msg
;;

(* Run one [ORP.Compile a/s b/s …] ([/s] selects strict Oberon-07). *)
let compile modules cwd path =
  run_checked ("ORP.Compile" :: List.map (fun m -> m ^ "/s") modules) cwd path
;;

(* ---- The pipeline --------------------------------------------------------- *)

let run_pipeline seed sources scratch visible plan =
  mkdir_p scratch;
  let toolchain = mksubdir scratch "toolchain" in
  extract_toolchain seed.toolchain toolchain;
  let norebo_dir = mksubdir scratch "norebo" in
  let compiler_dir = mksubdir scratch "compiler" in
  let oberon_dir = mksubdir scratch "oberon" in
  Printf.eprintf "Building the host toolchain\n%!";
  compile norebo_modules norebo_dir [ toolchain; sources ];
  (* The offline CoreLinker reads .rsx, so the objects to be linked are renamed out of the
     way of the live .rsc the shim loads to *run* the linker. *)
  bulk_rename norebo_dir "rsc" "rsx";
  run_checked [ "CoreLinker.LinkSerial"; "Modules"; "InnerCore" ] norebo_dir [ toolchain ];
  bulk_rename norebo_dir "rsx" "rsc";
  if read_file (Filename.concat norebo_dir "InnerCore") = seed.golden_inner_core
  then Printf.eprintf "  inner core reproduces the golden bootstrap\n%!"
  else
    Printf.eprintf
      "  warning: rebuilt inner core differs from the embedded golden seed\n%!";
  Printf.eprintf "Building a cross-compiler\n%!";
  let std_path = [ sources; compiler_dir; norebo_dir ] in
  compile [ "ORS.Mod"; "ORB.Mod"; "ORG.Mod"; "ORP.Mod" ] compiler_dir std_path;
  (* Drop symbol files so the full build links against the source-tree modules rather than
     the host-side (glue) core. *)
  bulk_delete norebo_dir "smb";
  bulk_delete compiler_dir "smb";
  Printf.eprintf "Compiling %d module(s) from the source tree\n%!" (List.length plan);
  let order = List.map (fun (c : Resolve.candidate) -> c.file) plan in
  compile order oberon_dir std_path;
  (* Fail loudly on a module that produced no object. Objects are named by module. *)
  List.iter
    (fun (c : Resolve.candidate) ->
      let rsc = Filename.concat oberon_dir (c.module_ ^ ".rsc") in
      if not (Sys.file_exists rsc)
      then
        failwith
          (Printf.sprintf "%s (MODULE %s) did not compile (no %s)" c.file c.module_ rsc))
    plan;
  Printf.eprintf "Linking the inner core onto the disk\n%!";
  bulk_rename oberon_dir "rsc" "rsx";
  run_checked
    [ "CoreLinker.LinkDisk"; "Modules"; "Oberon.dsk" ]
    scratch
    [ oberon_dir; norebo_dir ];
  Printf.eprintf "Installing files\n%!";
  let install =
    [ "VDiskUtil.InstallFiles"; "Oberon.dsk" ]
    @ List.map (fun name -> name ^ "=>" ^ name) visible
    @ List.map
        (fun rsx -> rsx ^ "=>" ^ Filename.remove_extension rsx ^ ".rsc")
        (files_with_ext oberon_dir "rsx")
    @ List.map (fun smb -> smb ^ "=>" ^ smb) (files_with_ext oberon_dir "smb")
  in
  run_checked install scratch [ oberon_dir; sources; norebo_dir ];
  Filename.concat scratch "Oberon.dsk"
;;

let build seed ~sources ~output =
  (* Settle what to compile before touching the toolchain, so a bad source tree fails fast
     with no half-built scratch dir to explain. *)
  let visible = sorted_visible sources in
  let plan = Resolve.resolve sources visible in
  let scratch =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s-%d" seed.name (Unix.getpid ()))
  in
  (try rm_rf scratch with
   | _ -> ());
  match run_pipeline seed sources scratch visible plan with
  | dsk ->
    (match Filename.dirname output with
     | "" | "." -> ()
     | parent -> mkdir_p parent);
    write_file output (read_file dsk);
    (try rm_rf scratch with
     | _ -> ())
  | exception e ->
    Printf.eprintf "%s: build failed; intermediates left in %s\n%!" seed.name scratch;
    raise e
;;

module For_tests = struct
  let bulk_rename = bulk_rename
  let bulk_delete = bulk_delete
  let sorted_visible = sorted_visible
  let extract_toolchain = extract_toolchain
end
