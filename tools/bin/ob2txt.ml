(** [ob2txt] — convert an Oberon source/text file to host text ([<FILE>.txt]), leaving the
    original untouched. Port of the Rust [ob2txt] binary. *)

open Oberon_tools

let () =
  match List.tl (Array.to_list Sys.argv) with
  | [ file ] when file <> "-h" && file <> "--help" ->
    (try
       let bytes = In_channel.with_open_bin file In_channel.input_all in
       let out = file ^ ".txt" in
       Out_channel.with_open_bin out (fun oc ->
         output_string oc (Convert.from_oberon bytes));
       Printf.eprintf "ob2txt: %s -> %s\n" file out
     with
     | Sys_error msg ->
       Printf.eprintf "ob2txt: %s\n" msg;
       exit 1)
  | _ ->
    Printf.eprintf "Usage: ob2txt <FILE>   (writes <FILE>.txt)\n";
    exit 2
;;
