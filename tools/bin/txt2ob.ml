(** [txt2ob] — convert host text back to Oberon source/text format: [<NAME>.txt] is
    written to [<NAME>] (the input must end in [.txt]). Inverse of [ob2txt]; port of the
    Rust [txt2ob] binary. *)

open Oberon_tools

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ file ] when Filename.check_suffix file ".txt" ->
    (try
       let text = In_channel.with_open_bin file In_channel.input_all in
       let out = Filename.chop_suffix file ".txt" in
       Out_channel.with_open_bin out (fun oc -> output_string oc (Convert.to_oberon text));
       Printf.eprintf "txt2ob: %s -> %s\n" file out
     with
     | Sys_error msg ->
       Printf.eprintf "txt2ob: %s\n" msg;
       exit 1)
  | [ _ ] ->
    Printf.eprintf "txt2ob: expected a `.txt` file\n";
    exit 1
  | _ ->
    Printf.eprintf "Usage: txt2ob <FILE.txt>   (writes <FILE>)\n";
    exit 2
;;
