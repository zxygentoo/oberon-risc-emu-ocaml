(** Shared CLI plumbing for the host-tool executables (the layer clap provides in the
    Rust port): the argv walker with the common conventions and the tool-level error
    reporter. [run] is the whole main of the two image builders. *)

let version = "0.1.0"

let parse ~name ~usage ~help ?(flags = []) args =
  let rec go positional = function
    | [] -> List.rev positional
    | ("-h" | "--help") :: _ ->
      print_string (usage ^ "\n\n" ^ help ^ "\n");
      exit 0
    | "--version" :: _ ->
      Printf.printf "%s %s\n" name version;
      exit 0
    | arg :: rest when List.mem_assoc arg flags ->
      List.assoc arg flags := true;
      go positional rest
    | arg :: _ when String.length arg > 1 && arg.[0] = '-' ->
      Printf.eprintf "%s: unknown option '%s'\n%s\n" name arg usage;
      exit 2
    | arg :: rest -> go (arg :: positional) rest
  in
  go [] args
;;

let run_reporting ~name f =
  try f () with
  | Image.Bad_image msg | Failure msg | Sys_error msg ->
    Printf.eprintf "%s: %s\n" name msg;
    exit 1
  | Unix.Unix_error (e, fn, arg) ->
    Printf.eprintf "%s: %s (%s %s)\n" name (Unix.error_message e) fn arg;
    exit 1
;;

let run seed =
  let name = seed.Pipeline.name in
  let usage = Printf.sprintf "Usage: %s <SOURCES_DIR> <OUTPUT>" name in
  match
    parse ~name ~usage ~help:Pipeline.packonly_help (List.tl (Array.to_list Sys.argv))
  with
  | [ sources; output ] ->
    run_reporting ~name (fun () ->
      Pipeline.build seed ~sources ~output;
      Printf.printf "Done: %s\n" output)
  | _ ->
    Printf.eprintf "%s\n" usage;
    exit 2
;;
