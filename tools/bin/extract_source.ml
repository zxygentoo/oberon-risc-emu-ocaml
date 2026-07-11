(** [extract-source] — extract a build-ready source tree from a Project Oberon [.dsk]
    image. All the work is {!Oberon_tools.Extract}; this binary is the CLI. Port of the
    Rust [extract-source] binary. *)

open Oberon_tools

let name = "extract-source"
let usage = "Usage: extract-source <DISK_IMAGE> <OUTPUT_DIR> [--keep-objects]"

let packonly_help =
  "The .packonly manifest:\n\
  \  extract-source also writes `.packonly` into OUTPUT_DIR: a source X.Mod is a\n\
  \  compile candidate when the image carries its X.rsc object; every other\n\
  \  extracted file is recorded as pack-only. One name per line; `#` comments and\n\
  \  blank lines are ignored; an empty list means the builders compile everything."
;;

let () =
  let keep_objects = ref false in
  match
    Tool_cli.parse
      ~name
      ~usage
      ~help:packonly_help
      ~flags:[ "--keep-objects", keep_objects ]
      (List.tl (Array.to_list Sys.argv))
  with
  | [ image_path; output ] ->
    Tool_cli.run_reporting ~name (fun () ->
      let (stats : Extract.stats) =
        Extract.extract_tree
          (Image.open_image image_path)
          ~output
          ~keep_objects:!keep_objects
      in
      let tail =
        if !keep_objects
        then Printf.sprintf "kept %d .rsc/.smb objects" stats.objects
        else Printf.sprintf "skipped %d compiled .rsc/.smb" stats.skipped
      in
      Printf.printf
        "extracted %d files to %s (%d pack-only; %s)\n"
        stats.extracted
        output
        (Packonly.StringSet.cardinal stats.packonly)
        tail)
  | _ ->
    Printf.eprintf "%s\n" usage;
    exit 2
;;
