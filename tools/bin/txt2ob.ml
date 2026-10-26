(** [txt2ob] — convert host text back to Oberon source/text format: [<NAME>.txt] is
    written to [<NAME>] (the input must end in [.txt]). Inverse of [ob2txt]; port of the
    Rust [txt2ob] binary. *)

open Oberon_tools

let name = "txt2ob"
let usage = "Usage: txt2ob <FILE.txt>   (writes <FILE>)"

let help =
  "Converts host text (UTF-8, LF or CRLF line ends) to Oberon text (Latin-1, CR line\n\
   ends). A leading byte-order mark is dropped; characters beyond Latin-1 become '?'\n\
   (with a warning); input that is not UTF-8 is refused. ob2txt is the inverse."
;;

let () =
  match Tool_cli.parse ~name ~usage ~help (List.tl (Array.to_list Sys.argv)) with
  | [ file ] when Filename.check_suffix file ".txt" ->
    Tool_cli.run_reporting ~name (fun () ->
      let out = Filename.chop_suffix file ".txt" in
      let text = Fsutil.read_file file in
      let data =
        try Convert.to_oberon text with
        | Convert.Invalid_utf8 at ->
          failwith (Printf.sprintf "%s: not UTF-8 text (malformed at byte %d)" file at)
      in
      Fsutil.write_file out data;
      (match Convert.beyond_latin1 text with
       | 0 -> ()
       | n ->
         Printf.eprintf
           "txt2ob: warning: %s: %d character%s beyond Latin-1 written as '?'\n"
           file
           n
           (if n = 1 then "" else "s"));
      Printf.eprintf "txt2ob: %s -> %s\n" file out)
  | [ file ] ->
    Tool_cli.usage_error ~name ~usage (Printf.sprintf "%s: expected a .txt file" file)
  | _ -> Tool_cli.usage_error ~name ~usage "expected one FILE.txt"
;;
