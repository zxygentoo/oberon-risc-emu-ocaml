(* Compile-order resolution tests, ported from resolve.rs. *)

open Oberon_tools
open Test_harness
module R = Resolve.For_tests

let raises f =
  try
    ignore (f ());
    false
  with
  | Failure _ -> true
;;

(* [f]'s Failure message contains [sub]. *)
let fails_with ~sub f =
  match f () with
  | _ -> false
  | exception Failure msg ->
    let n = String.length sub in
    let rec go i =
      i + n <= String.length msg && (String.sub msg i n = sub || go (i + 1))
    in
    go 0
;;

(* A source tree in a scratch dir: [files] as (name, contents), plus .packonly. *)
let with_tree ~packonly files f =
  with_scratch ~prefix:"resolve" (fun dir ->
    List.iter
      (fun (name, body) ->
         Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
           output_string oc body))
      ((".packonly", packonly) :: files);
    f dir (List.sort compare (List.map fst files)))
;;

let () =
  (* SYSTEM dropped; alias Q := Baz resolves to its target Baz *)
  (let m, imp =
     R.parse_header "MODULE Foo;\r IMPORT SYSTEM, Bar, Q := Baz;\r CONST x = 1;"
   in
   check "hdr_module" (m = "Foo");
   check "hdr_imports" (imp = [ "Bar"; "Baz" ]));
  (* export marker, no imports *)
  (let m, imp = R.parse_header "MODULE* Foo;\r END Foo." in
   check "hdr_export_module" (m = "Foo");
   check "hdr_no_imports" (imp = []));
  (* leading + nested comments skipped *)
  (let m, imp = R.parse_header "(* a (* nested *) c *) MODULE Foo; IMPORT Bar;" in
   check "hdr_comment_module" (m = "Foo");
   check "hdr_comment_imports" (imp = [ "Bar" ]));
  (* non-source rejected *)
  check "hdr_rejects_binary" (raises (fun () -> R.parse_header "\x00\x01\x02\x03"));
  check "hdr_rejects_text" (raises (fun () -> R.parse_header "not a module"));
  (* topo: A imports B, B imports C => C, B, A *)
  check
    "topo_deps_first"
    (R.topo_sort [ "A", [ "B" ]; "B", [ "C" ]; "C", [] ] = [ "C"; "B"; "A" ]);
  (* Z isn't a node -> ignored; no in-set edges -> ties break by name *)
  check "topo_deterministic" (R.topo_sort [ "B", [ "Z" ]; "A", [] ] = [ "A"; "B" ]);
  (* cycle detected *)
  check "topo_cycle" (raises (fun () -> R.topo_sort [ "A", [ "B" ]; "B", [ "A" ] ]));
  (* resolve on a tree: sources in import order, pack-only files skipped *)
  let a = "MODULE A; IMPORT B; END A.\r"
  and b = "MODULE B; END B.\r" in
  with_tree
    ~packonly:"data.bin\n"
    [ "A.Mod", a; "B.Mod", b; "data.bin", "\x00\x01" ]
    (fun dir visible ->
       check
         "resolve_order"
         (List.map (fun (c : Resolve.candidate) -> c.file) (Resolve.resolve dir visible)
          = [ "B.Mod"; "A.Mod" ]));
  (* Every file goes onto the disk under its own name, so a name Oberon can't hold
     fails the build up front, naming each offender — it used to make the install
     stage drop every later file and still report success. *)
  with_tree
    ~packonly:"my-data.bin\n2fast.txt\n"
    [ "A.Mod", b; "my-data.bin", "x"; "2fast.txt", "y" ]
    (fun dir visible ->
       check
         "bad_names_rejected"
         (fails_with ~sub:"2fast.txt, my-data.bin" (fun () -> Resolve.resolve dir visible)));
  with_tree
    ~packonly:(String.make 32 'L' ^ "\n")
    [ "B.Mod", b; String.make 32 'L', "x" ]
    (fun dir visible ->
       check
         "name_over_31_rejected"
         (fails_with ~sub:"at most 31 bytes" (fun () -> Resolve.resolve dir visible)));
  with_tree
    ~packonly:(String.make 31 'L' ^ "\n")
    [ "B.Mod", b; String.make 31 'L', "x" ]
    (fun dir visible -> check "name_of_31_accepted" (Resolve.resolve dir visible <> []));
  (* ... and a file the disk can't hold fails up front too (it used to trap the
     install stage with an index error). *)
  with_tree
    ~packonly:"Big.bin\n"
    [ "B.Mod", b; "Big.bin", String.make (Resolve.max_file_bytes + 1) 'x' ]
    (fun dir visible ->
       check
         "oversized_file_rejected"
         (fails_with ~sub:"Big.bin is 3210913 bytes" (fun () ->
            Resolve.resolve dir visible)));
  summary "resolve checks"
;;
