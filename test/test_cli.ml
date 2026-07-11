(* CLI parsing tests, ported from the Rust cli.rs tests. Exercises
   {!Cli.parse_argv} on raw argument lists (no Sys.argv needed). *)

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let eqx name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got %d, want %d\n" name got want)
;;

let ok args =
  match Cli.parse_argv args with
  | Cli.Config c -> c
  | Cli.Help ->
    failwith (Printf.sprintf "unexpected help for %s" (String.concat " " args))
  | Cli.Invalid e ->
    failwith (Printf.sprintf "unexpected error for %s: %s" (String.concat " " args) e)
;;

let is_err args =
  match Cli.parse_argv args with
  | Cli.Invalid _ -> true
  | Cli.Config _ | Cli.Help -> false
;;

let () =
  (* A disk image is required unless --boot-from-serial. *)
  check "requires_disk" (is_err []);
  check "boot_from_serial_ok" (not (is_err [ "--boot-from-serial" ]));
  let c = ok [ "disk.dsk" ] in
  eqx "default_width" c.Cli.width 1024;
  eqx "default_height" c.Cli.height 768;
  check "default_no_configure" (not c.Cli.configure);
  check "default_disk_image" (c.Cli.disk_image = Some "disk.dsk");
  check "default_not_headless" (not c.Cli.headless);
  (* --size: width rounds down to a multiple of 32; setting it implies configure. *)
  let c = ok [ "--size"; "1000x700"; "disk.dsk" ] in
  eqx "size_width_rounded" c.Cli.width (1000 land lnot 31);
  eqx "size_height" c.Cli.height 700;
  check "size_configure" c.Cli.configure;
  (* The --opt=value form is accepted too. *)
  let c = ok [ "--size=800x600"; "disk.dsk" ] in
  eqx "size_eq_width" c.Cli.width 800;
  eqx "size_eq_height" c.Cli.height 600;
  (* --mem also implies configure. *)
  check "mem_configure" (ok [ "--mem"; "2"; "disk.dsk" ]).Cli.configure;
  (* Headless flags. *)
  let c = ok [ "--headless"; "--frames"; "42"; "disk.dsk" ] in
  check "headless" c.Cli.headless;
  check "frames" (c.Cli.frames = Some 42);
  check "headless_disk" (c.Cli.disk_image = Some "disk.dsk");
  check "headless_unbounded" ((ok [ "--headless"; "disk.dsk" ]).Cli.frames = None);
  (* Error cases. *)
  check "frames_requires_headless" (is_err [ "--frames"; "1"; "d.dsk" ]);
  check "unknown_option" (is_err [ "--bogus"; "d.dsk" ]);
  check "invalid_size" (is_err [ "--size"; "nonsense"; "d.dsk" ]);
  (* --help wins over a missing disk image; an earlier bad option wins over --help. *)
  check "help" (Cli.parse_argv [ "--help" ] = Cli.Help);
  check "help_short" (Cli.parse_argv [ "-h" ] = Cli.Help);
  check "err_before_help" (is_err [ "--bogus"; "--help" ]);
  if !failures = 0
  then Printf.printf "ok: %d cli checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d cli checks failed\n" !failures !total;
    exit 1)
;;
