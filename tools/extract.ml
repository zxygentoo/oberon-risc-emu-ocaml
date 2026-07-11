(** Extract a build-ready source tree from a Project Oberon disk image — the core of
    [extract-source]. *)

(* A compiled artifact the image builders regenerate from source; keeping it would shadow
   the freshly built one, so it is skipped by default. *)
let is_compiled name =
  match Filename.extension name with
  | ".rsc" | ".smb" -> true
  | _ -> false
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
  Fsutil.write_file (Filename.concat dir name) data
;;

type stats =
  { packonly : Packonly.StringSet.t
  ; extracted : int
  ; skipped : int
  ; objects : int
  }

let extract_tree img ~output ~keep_objects =
  Fsutil.mkdir_p output;
  let entries = Image.entries img in
  (* Module names with a compiled object present: their .Mod source is a compile
     candidate; everything else extracted is packed verbatim. *)
  let compiled =
    Packonly.StringSet.of_list
      (List.filter_map
         (fun (e : Image.entry) -> Filename.chop_suffix_opt ~suffix:".rsc" e.name)
         entries)
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
          match Filename.chop_suffix_opt ~suffix:".Mod" e.name with
          | Some stem -> Packonly.StringSet.mem stem compiled
          | None -> false
        in
        (* Record pack-only only once written. Compiled objects (present only with
           [keep_objects]) are seed material, not pack-only data. *)
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
  Fsutil.write_file
    (Filename.concat output Packonly.file_name)
    (Packonly.render stats.packonly);
  stats
;;
