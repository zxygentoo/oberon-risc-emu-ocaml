(* Compile-order resolution tests, ported from resolve.rs. *)

open Oberon_tools
module R = Resolve.For_tests

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let raises f =
  try
    ignore (f ());
    false
  with
  | Failure _ -> true
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
  if !failures = 0
  then Printf.printf "ok: %d resolve checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d resolve checks failed\n" !failures !total;
    exit 1)
;;
