(** [ob2txt] — convert an Oberon source/text file to host text ([<FILE>.txt]), leaving the
    original untouched. Port of the Rust [ob2txt] binary. *)

open Oberon_tools

let name = "ob2txt"
let usage = "Usage: ob2txt <FILE>   (writes <FILE>.txt)"

let help =
  "Converts Oberon text (Latin-1, CR line ends) to host text (UTF-8, LF line ends).\n\
   txt2ob is the inverse."
;;

let () =
  match Tool_cli.parse ~name ~usage ~help (List.tl (Array.to_list Sys.argv)) with
  | [ file ] ->
    Tool_cli.run_reporting ~name (fun () ->
      let out = file ^ ".txt" in
      Fsutil.write_file out (Convert.from_oberon (Fsutil.read_file file));
      Printf.eprintf "ob2txt: %s -> %s\n" file out)
  | _ -> Tool_cli.usage_error ~name ~usage "expected one FILE"
;;
