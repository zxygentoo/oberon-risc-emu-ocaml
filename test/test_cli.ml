(* CLI parsing tests, ported from the Rust cli.rs tests. Exercises
   {!Cli.parse_argv} on raw argument lists (no Sys.argv needed). *)

open Test_harness

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
  eq "default_width" c.Cli.width 1024;
  eq "default_height" c.Cli.height 768;
  check "default_no_configure" (not c.Cli.configure);
  check "default_disk_image" (c.Cli.disk_image = Some "disk.dsk");
  check "default_not_headless" (not c.Cli.headless);
  (* --size: width rounds down to a multiple of 32; setting it implies configure. *)
  let c = ok [ "--size"; "1000x700"; "disk.dsk" ] in
  eq "size_width_rounded" c.Cli.width (1000 land lnot 31);
  eq "size_height" c.Cli.height 700;
  check "size_configure" c.Cli.configure;
  (* The --opt=value form is accepted too. *)
  let c = ok [ "--size=800x600"; "disk.dsk" ] in
  eq "size_eq_width" c.Cli.width 800;
  eq "size_eq_height" c.Cli.height 600;
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
  (* --zoom: an unparsable value errors; a non-positive one folds to 0 (auto). *)
  check "zoom_invalid" (is_err [ "--zoom"; "abc"; "d.dsk" ]);
  check "zoom_nonpositive_auto" ((ok [ "--zoom"; "-1"; "d.dsk" ]).Cli.zoom = 0.0);
  check "zoom_value" ((ok [ "--zoom"; "1.5"; "d.dsk" ]).Cli.zoom = 1.5);
  (* A value-taking option at the end of argv is an error. *)
  check "missing_value" (is_err [ "d.dsk"; "--mem" ]);
  (* Pass-through flags land in the config. *)
  let c =
    ok [ "--fullscreen"; "--leds"; "--serial-in"; "in"; "--serial-out"; "out"; "d.dsk" ]
  in
  check "fullscreen_flag" c.Cli.fullscreen;
  check "leds_flag" c.Cli.leds;
  check "serial_in" (c.Cli.serial_in = Some "in");
  check "serial_out" (c.Cli.serial_out = Some "out");
  (* --size clamps to [32, 2048] on each axis (the width also floors to 32). *)
  let c = ok [ "--size"; "9999x9999"; "d.dsk" ] in
  eq "size_clamp_w" c.Cli.width 2048;
  eq "size_clamp_h" c.Cli.height 2048;
  let c = ok [ "--size"; "8x8"; "d.dsk" ] in
  eq "size_min_w" c.Cli.width 32;
  eq "size_min_h" c.Cli.height 32;
  (* The shared frontend clamp. *)
  eq "clamp_below" (Cli.clamp 0 10 (-5)) 0;
  eq "clamp_inside" (Cli.clamp 0 10 7) 7;
  eq "clamp_above" (Cli.clamp 0 10 99) 10;
  (* The usage text names every option it parses. *)
  let mentions needle =
    let hay = Cli.usage in
    let nh = String.length hay
    and nn = String.length needle in
    let rec go i = i + nn <= nh && (String.sub hay i nn = needle || go (i + 1)) in
    go 0
  in
  List.iter
    (fun opt -> check ("usage_mentions_" ^ opt) (mentions opt))
    [ "--fullscreen"
    ; "--zoom"
    ; "--leds"
    ; "--mem"
    ; "--size"
    ; "--boot-from-serial"
    ; "--serial-in"
    ; "--serial-out"
    ; "--headless"
    ; "--frames"
    ];
  summary "cli checks"
;;
