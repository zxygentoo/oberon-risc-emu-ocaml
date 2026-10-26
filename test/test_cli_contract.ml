(* The executables' command-line contract, end to end against the built binaries —
   what scripts downstream (DOOM-on-Oberon's mkdsk.sh, the root Makefile) rely on:
   -h/--help and --version exit 0; a usage error (unknown option, wrong arguments)
   exits 2 with a pointer to --help; work that fails exits 1. *)

open Test_harness

(* Run [exe args] in [dir]; exit code, stdout, stderr. *)
let run dir exe args =
  let out = Filename.concat dir "stdout"
  and err = Filename.concat dir "stderr" in
  let fd path = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let o = fd out
  and e = fd err in
  let pid = Unix.create_process exe (Array.of_list (exe :: args)) Unix.stdin o e in
  Unix.close o;
  Unix.close e;
  let code =
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED c -> c
    | _ -> -1
  in
  code, read_file out, read_file err
;;

let contains ~sub s =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0
;;

(* Paths are relative to this test's directory in _build; made absolute so [run] can
   start them from a scratch dir. *)
let exe path = Filename.concat (Sys.getcwd ()) path

let tools =
  [ "risc", exe "../bin/risc.exe"
  ; "ob2txt", exe "../tools/bin/ob2txt.exe"
  ; "txt2ob", exe "../tools/bin/txt2ob.exe"
  ; "extract-source", exe "../tools/bin/extract_source.exe"
  ; "build-po-image", exe "../tools/bin/build_po_image.exe"
  ; "build-eo-image", exe "../tools/bin/build_eo_image.exe"
  ]
;;

let () =
  with_scratch ~prefix:"cli_contract" (fun dir ->
    let run = run dir in
    List.iter
      (fun (name, exe) ->
         let t what = name ^ "_" ^ what in
         let code, out, _ = run exe [ "--help" ] in
         check (t "help_exit_0") (code = 0);
         check (t "help_usage") (contains ~sub:"Usage:" out);
         let code, out, _ = run exe [ "--version" ] in
         check (t "version_exit_0") (code = 0);
         eqs (t "version_line") out (name ^ " " ^ Risc_core.Version.version ^ "\n");
         let code, _, err = run exe [ "--bogus" ] in
         check (t "unknown_option_exit_2") (code = 2);
         check (t "unknown_option_points_at_help") (contains ~sub:"--help" err);
         let code, _, _ = run exe [] in
         check (t "no_args_exit_2") (code = 2))
      tools;
    let tool name = List.assoc name tools in
    let path name = Filename.concat dir name in
    (* risc: usage errors are 2, a failed run 1. *)
    let code, _, _ = run (tool "risc") [ "a.dsk"; "b.dsk" ] in
    check "risc_two_disks_exit_2" (code = 2);
    let code, _, _ = run (tool "risc") [ "--headless=1"; "a.dsk" ] in
    check "risc_flag_value_exit_2" (code = 2);
    let code, _, err =
      run (tool "risc") [ "--headless"; "--frames"; "1"; path "nope.dsk" ]
    in
    check "risc_missing_image_exit_1" (code = 1);
    check "risc_missing_image_named" (contains ~sub:"nope.dsk" err);
    let code, _, err = run (tool "risc") [ "--headless"; "--frames"; "1"; dir ] in
    check "risc_directory_image_exit_1" (code = 1);
    check "risc_directory_image_named" (contains ~sub:dir err);
    (* The converters: a round trip; a refused input writes nothing. *)
    write_file (path "M.Mod.txt") "MODULE M;\nEND M.\n";
    let code, _, _ = run (tool "txt2ob") [ path "M.Mod.txt" ] in
    check "txt2ob_exit_0" (code = 0);
    eqs "txt2ob_output" (read_file (path "M.Mod")) "MODULE M;\rEND M.\r";
    let code, _, _ = run (tool "ob2txt") [ path "M.Mod" ] in
    check "ob2txt_exit_0" (code = 0);
    eqs "ob2txt_round_trip" (read_file (path "M.Mod.txt")) "MODULE M;\nEND M.\n";
    write_file (path "L.txt") "caf\xE9\n";
    let code, _, err = run (tool "txt2ob") [ path "L.txt" ] in
    check "txt2ob_not_utf8_exit_1" (code = 1);
    check "txt2ob_not_utf8_says_so" (contains ~sub:"not UTF-8" err);
    check "txt2ob_not_utf8_writes_nothing" (not (Sys.file_exists (path "L")));
    let code, _, _ = run (tool "txt2ob") [ path "M.Mod" ] in
    check "txt2ob_needs_txt_exit_2" (code = 2);
    let code, _, _ = run (tool "ob2txt") [ path "missing.Mod" ] in
    check "ob2txt_missing_exit_1" (code = 1);
    (* extract-source and the builders fail their work with 1. *)
    let code, _, _ = run (tool "extract-source") [ path "missing.dsk"; path "out" ] in
    check "extract_missing_image_exit_1" (code = 1);
    Unix.mkdir (path "src") 0o700;
    let code, _, err = run (tool "build-po-image") [ path "src"; path "o.dsk" ] in
    check "build_no_packonly_exit_1" (code = 1);
    check "build_no_packonly_says_so" (contains ~sub:".packonly" err);
    check "build_no_packonly_no_image" (not (Sys.file_exists (path "o.dsk"))));
  summary "cli contract checks"
;;
