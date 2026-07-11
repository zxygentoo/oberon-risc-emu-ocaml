(** [extract-source] — extract a build-ready source tree from a Project Oberon [.dsk]
    image: every file except the compiled artifacts ([.rsc]/[.smb]), plus a regenerated
    [.packonly] manifest. Reads the on-disk filesystem directly (no emulator). Port of the
    Rust [extract-source] binary. *)

open Oberon_tools

let usage = "Usage: extract-source <DISK_IMAGE> <OUTPUT_DIR> [--keep-objects]"

let packonly_help =
  "The .packonly manifest:\n\
  \  extract-source also writes `.packonly` into OUTPUT_DIR: a source X.Mod is a\n\
  \  compile candidate when the image carries its X.rsc object; every other\n\
  \  extracted file is recorded as pack-only. One name per line; `#` comments and\n\
  \  blank lines are ignored; an empty list means the builders compile everything."
;;

let strip_suffix s suf =
  if Filename.check_suffix s suf then Some (Filename.chop_suffix s suf) else None
;;

(* A compiled artifact the image builders regenerate from source; keeping it would shadow
   the freshly built one, so it is skipped by default. *)
let is_compiled name =
  match Filename.extension name with
  | ".rsc" | ".smb" -> true
  | _ -> false
;;

let rec mkdir_p dir =
  if dir = "" || dir = Filename.current_dir_name || Sys.file_exists dir
  then ()
  else (
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

(* Write one extracted file into [dir]; reject any name that isn't a direct child (defense
   in depth on top of the reader's name validation). *)
let write_file dir name data =
  if
    String.contains name '/'
    || name = ""
    || name = Filename.current_dir_name
    || name = Filename.parent_dir_name
  then failwith (Printf.sprintf "refusing suspicious file name '%s'" name);
  Out_channel.with_open_bin (Filename.concat dir name) (fun oc -> output_string oc data)
;;

(* Per-run tallies for the closing report; [packonly] doubles as the manifest. *)
type stats =
  { packonly : Packonly.StringSet.t
  ; extracted : int
  ; skipped : int
  ; objects : int
  }

let run ~image_path ~output ~keep_objects =
  let img = Image.open_image image_path in
  mkdir_p output;
  let entries = Image.entries img in
  (* Module names with a compiled object present: their .Mod source is a compile
     candidate; everything else extracted is packed verbatim. *)
  let compiled =
    Packonly.StringSet.of_list
      (List.filter_map (fun (e : Image.entry) -> strip_suffix e.name ".rsc") entries)
  in
  let extract stats (e : Image.entry) =
    if is_compiled e.name && not keep_objects
    then { stats with skipped = stats.skipped + 1 }
    else (
      match Image.read_file img e.header with
      | exception Image.Bad_image msg ->
        Printf.eprintf "extract-source: skipping '%s': %s\n" e.name msg;
        stats
      | data ->
        write_file output e.name data;
        let stats = { stats with extracted = stats.extracted + 1 } in
        let is_module_source =
          match strip_suffix e.name ".Mod" with
          | Some stem -> Packonly.StringSet.mem stem compiled
          | None -> false
        in
        (* Record pack-only only once written. Compiled objects (present only with
           --keep-objects) are seed material, not pack-only data. *)
        if is_compiled e.name
        then { stats with objects = stats.objects + 1 }
        else if not is_module_source
        then { stats with packonly = Packonly.StringSet.add e.name stats.packonly }
        else stats)
  in
  let stats =
    List.fold_left
      extract
      { packonly = Packonly.StringSet.empty; extracted = 0; skipped = 0; objects = 0 }
      entries
  in
  (* The manifest is required by the builders and always regenerated, so the tree is
     build-ready as-is (an empty list — compile everything — still writes). *)
  Out_channel.with_open_bin (Filename.concat output ".packonly") (fun oc ->
    output_string oc (Packonly.render stats.packonly));
  let tail =
    if keep_objects
    then Printf.sprintf "kept %d .rsc/.smb objects" stats.objects
    else Printf.sprintf "skipped %d compiled .rsc/.smb" stats.skipped
  in
  Printf.printf
    "extracted %d files to %s (%d pack-only; %s)\n"
    stats.extracted
    output
    (Packonly.StringSet.cardinal stats.packonly)
    tail
;;

let () =
  let rec parse keep_objects positional = function
    | [] -> keep_objects, List.rev positional
    | "--keep-objects" :: rest -> parse true positional rest
    | ("-h" | "--help") :: _ ->
      print_string (usage ^ "\n\n" ^ packonly_help ^ "\n");
      exit 0
    | "--version" :: _ ->
      print_endline "extract-source 0.1.0";
      exit 0
    | arg :: _ when String.length arg > 1 && arg.[0] = '-' ->
      Printf.eprintf "extract-source: unknown option '%s'\n%s\n" arg usage;
      exit 2
    | arg :: rest -> parse keep_objects (arg :: positional) rest
  in
  match parse false [] (List.tl (Array.to_list Sys.argv)) with
  | keep_objects, [ image_path; output ] ->
    (try run ~image_path ~output ~keep_objects with
     | Image.Bad_image msg | Failure msg ->
       Printf.eprintf "extract-source: %s\n" msg;
       exit 1
     | Sys_error msg ->
       Printf.eprintf "extract-source: %s\n" msg;
       exit 1
     | Unix.Unix_error (e, f, a) ->
       Printf.eprintf "extract-source: %s (%s %s)\n" (Unix.error_message e) f a;
       exit 1)
  | _ ->
    Printf.eprintf "%s\n" usage;
    exit 2
;;
