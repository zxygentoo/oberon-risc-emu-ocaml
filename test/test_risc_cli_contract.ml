(* risc's command-line contract, end to end against the built binary — the same
   conventions as the host tools (test_cli_contract): -h/--help and --version exit
   0; a usage error exits 2 with a pointer to --help; a run that fails exits 1. *)

open Test_harness

let risc = Filename.concat (Sys.getcwd ()) "../bin/risc.exe"

let () =
  with_scratch ~prefix:"risc_cli_contract" (fun dir ->
    let run = run_exe ~cwd:dir risc in
    let code, out, _ = run [ "--help" ] in
    check "help_exit_0" (code = 0);
    check "help_usage" (contains ~sub:"Usage:" out);
    let code, out, _ = run [ "--version" ] in
    check "version_exit_0" (code = 0);
    eqs "version_line" out ("risc " ^ Oberon_risc.Version.version ^ "\n");
    let code, _, err = run [ "--bogus" ] in
    check "unknown_option_exit_2" (code = 2);
    check "unknown_option_points_at_help" (contains ~sub:"--help" err);
    let code, _, _ = run [] in
    check "no_args_exit_2" (code = 2);
    let code, _, _ = run [ "a.dsk"; "b.dsk" ] in
    check "two_disks_exit_2" (code = 2);
    let code, _, _ = run [ "--headless=1"; "a.dsk" ] in
    check "flag_value_exit_2" (code = 2);
    let missing = Filename.concat dir "nope.dsk" in
    let code, _, err = run [ "--headless"; "--frames"; "1"; missing ] in
    check "missing_image_exit_1" (code = 1);
    check "missing_image_named" (contains ~sub:"nope.dsk" err);
    let code, _, err = run [ "--headless"; "--frames"; "1"; dir ] in
    check "directory_image_exit_1" (code = 1);
    check "directory_image_named" (contains ~sub:dir err));
  summary "risc cli contract checks"
;;
