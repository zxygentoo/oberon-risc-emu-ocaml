(** Shared CLI for build-po-image / build-eo-image. *)

let run seed ~name ~version =
  let usage = Printf.sprintf "Usage: %s <SOURCES_DIR> <OUTPUT>" name in
  let rec parse positional = function
    | [] -> List.rev positional
    | ("-h" | "--help") :: _ ->
      print_string (usage ^ "\n\n" ^ Pipeline.packonly_help ^ "\n");
      exit 0
    | "--version" :: _ ->
      Printf.printf "%s %s\n" name version;
      exit 0
    | arg :: _ when String.length arg > 1 && arg.[0] = '-' ->
      Printf.eprintf "%s: unknown option '%s'\n%s\n" name arg usage;
      exit 2
    | arg :: rest -> parse (arg :: positional) rest
  in
  match parse [] (List.tl (Array.to_list Sys.argv)) with
  | [ sources; output ] ->
    (try
       Pipeline.build seed ~sources ~output;
       Printf.printf "Done: %s\n" output
     with
     | Failure msg | Sys_error msg ->
       Printf.eprintf "%s: %s\n" name msg;
       exit 1
     | Unix.Unix_error (e, f, a) ->
       Printf.eprintf "%s: %s (%s %s)\n" name (Unix.error_message e) f a;
       exit 1)
  | _ ->
    Printf.eprintf "%s\n" usage;
    exit 2
;;
