(** [txt2ob] — convert host text back to Oberon source/text format: [<NAME>.txt] is
    written to [<NAME>] (the input must end in [.txt]). Inverse of [ob2txt]; port of the
    Rust [txt2ob] binary. *)

open Oberon_tools

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ file ] when Filename.check_suffix file ".txt" ->
    (try
       let out = Filename.chop_suffix file ".txt" in
       let text = Fsutil.read_file file in
       Fsutil.write_file out (Convert.to_oberon text);
       (match Convert.beyond_latin1 text with
        | 0 -> ()
        | n ->
          Printf.eprintf
            "txt2ob: warning: %s: %d character%s beyond Latin-1 written as '?'\n"
            file
            n
            (if n = 1 then "" else "s"));
       Printf.eprintf "txt2ob: %s -> %s\n" file out
     with
     | Sys_error msg ->
       Printf.eprintf "txt2ob: %s\n" msg;
       exit 1
     | Convert.Invalid_utf8 at ->
       Printf.eprintf "txt2ob: %s: not UTF-8 text (malformed at byte %d)\n" file at;
       exit 1)
  | [ _ ] ->
    Printf.eprintf "txt2ob: expected a `.txt` file\n";
    exit 1
  | _ ->
    Printf.eprintf "Usage: txt2ob <FILE.txt>   (writes <FILE>)\n";
    exit 2
;;
