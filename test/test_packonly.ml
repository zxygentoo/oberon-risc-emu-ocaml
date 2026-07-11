(* .packonly parse/render tests, ported from packonly.rs. *)

open Oberon_tools
open Test_harness

let set names =
  List.fold_left (fun s n -> Packonly.StringSet.add n s) Packonly.StringSet.empty names
;;

let eq_set name got want =
  incr total;
  if not (Packonly.StringSet.equal got want)
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let () =
  eq_set
    "parse_ignores_comments_and_blank_lines"
    (Packonly.parse "# header\nDisplay.Orig.Mod\n\n  Oberon10.Scn.Fnt  # a font\n")
    (set [ "Display.Orig.Mod"; "Oberon10.Scn.Fnt" ]);
  eq_set
    "render_round_trips_through_parse"
    (Packonly.parse (Packonly.render (set [ "B.Fnt"; "A.Mod" ])))
    (set [ "B.Fnt"; "A.Mod" ]);
  eq_set
    "empty_list_renders_and_parses_empty"
    (Packonly.parse (Packonly.render Packonly.StringSet.empty))
    Packonly.StringSet.empty;
  summary "packonly checks"
;;
