(* End-to-end round-trip for the image builder: extract the committed golden image into a
   source tree, rebuild it with build-po-image's pipeline, and verify the result re-opens
   as a valid, populated Oberon filesystem.

   This boots the shim and compiles the whole system (~seconds), so it self-skips unless
   OBERON_ROUNDTRIP=1 — keeping `dune runtest` fast. Run it with:

     OBERON_ROUNDTRIP=1 dune exec test/test_build_roundtrip.exe DiskImage/Oberon-2020-08-18.dsk

   Byte-for-byte parity with the Rust build-po-image is checked out-of-band by diffing
   the two tools' output (see PORTING_HOST_TOOLS.md). *)

open Oberon_tools

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
  Fsutil.rm_rf tmp;
  Unix.mkdir tmp 0o755;
  let src = Filename.concat tmp "src"
  and out = Filename.concat tmp "out.dsk" in
  (* Extract the golden image into a build-ready source tree — the extract-source core
     (default behaviour: drop .rsc/.smb, regenerate .packonly). *)
  ignore (Extract.extract_tree (Image.open_image dsk) ~output:src ~keep_objects:false);
  Pipeline.build Seed.po ~sources:src ~output:out;
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
  Fsutil.rm_rf tmp;
  if missing = [] && not too_few
  then
    Printf.printf
      "ok: build round-trip produced a valid Oberon image (%d files)\n"
      (List.length names)
  else exit 1
;;
