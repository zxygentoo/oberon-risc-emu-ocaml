(* End-to-end round-trip for the image builder: extract the committed golden image into a
   source tree, rebuild it with build-po-image's pipeline, and verify the result re-opens
   as a valid, populated Oberon filesystem.

   This boots the shim and compiles the whole system (~seconds), so it self-skips unless
   OBERON_ROUNDTRIP=1 — keeping `dune runtest` fast. Run it with:

     OBERON_ROUNDTRIP=1 dune exec test/test_build_roundtrip.exe DiskImage/Oberon-2020-08-18.dsk

   Byte-for-byte parity with the Rust build-po-image is checked out-of-band by diffing
   the two tools' output (see PORTING_HOST_TOOLS.md). *)

open Oberon_tools

let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun n -> rm_rf (Filename.concat path n)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path
;;

let strip_suffix s suf =
  if Filename.check_suffix s suf then Some (Filename.chop_suffix s suf) else None
;;

let is_compiled name =
  match Filename.extension name with
  | ".rsc" | ".smb" -> true
  | _ -> false
;;

(* Extract a build-ready source tree from [image_path] (mirrors extract-source's default
   behaviour: drop .rsc/.smb, regenerate .packonly). *)
let extract_tree image_path out =
  Unix.mkdir out 0o755;
  let img = Image.open_image image_path in
  let entries = Image.entries img in
  let compiled =
    Packonly.StringSet.of_list
      (List.filter_map (fun (e : Image.entry) -> strip_suffix e.name ".rsc") entries)
  in
  let pack =
    List.fold_left
      (fun pack (e : Image.entry) ->
         if is_compiled e.name
         then pack
         else (
           write_file (Filename.concat out e.name) (Image.read_file img e.header);
           let is_module_source =
             match strip_suffix e.name ".Mod" with
             | Some stem -> Packonly.StringSet.mem stem compiled
             | None -> false
           in
           if is_module_source then pack else Packonly.StringSet.add e.name pack))
      Packonly.StringSet.empty
      entries
  in
  write_file (Filename.concat out ".packonly") (Packonly.render pack)
;;

let () =
  if Sys.getenv_opt "OBERON_ROUNDTRIP" = None
  then (
    print_endline "test_build_roundtrip: skipped (set OBERON_ROUNDTRIP=1 to run)";
    exit 0);
  (* The golden image comes in as argv — `dune runtest` supplies its dep path (see
     test/dune); manual runs pass it explicitly. *)
  let dsk =
    match Sys.argv with
    | [| _; path |] -> path
    | _ ->
      prerr_endline "usage: test_build_roundtrip <golden-image.dsk>";
      exit 2
  in
  let tmp =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "ml-roundtrip-%d" (Unix.getpid ()))
  in
  rm_rf tmp;
  Unix.mkdir tmp 0o755;
  let src = Filename.concat tmp "src"
  and out = Filename.concat tmp "out.dsk" in
  extract_tree dsk src;
  Pipeline.build Seed_po.seed ~sources:src ~output:out;
  (* The built image must re-open as a valid Oberon FS carrying the expected files. *)
  let names =
    List.map (fun (e : Image.entry) -> e.name) (Image.entries (Image.open_image out))
  in
  let missing =
    List.filter
      (fun n -> not (List.mem n names))
      [ "System.rsc"; "Oberon.rsc"; "Kernel.rsc"; "Modules.Mod"; "System.Tool" ]
  in
  List.iter (Printf.printf "FAIL: built image missing %s\n") missing;
  let too_few = List.length names < 100 in
  if too_few
  then Printf.printf "FAIL: built image has only %d files\n" (List.length names);
  rm_rf tmp;
  if missing = [] && not too_few
  then
    Printf.printf
      "ok: build round-trip produced a valid Oberon image (%d files)\n"
      (List.length names)
  else exit 1
;;
