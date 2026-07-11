(** Command-line parsing (port of the [getopt_long] block in [sdl-main.c], with
    the [--headless]/[--frames] additions from the Rust port). *)

let max_dim = 2048

let usage =
  "Usage: risc [OPTIONS...] DISK-IMAGE\n\n\
   Options:\n\
  \  --fullscreen          Start the emulator in full screen mode\n\
  \  --zoom REAL           Scale the display in windowed mode\n\
  \  --leds                Log LED state on stdout\n\
  \  --mem MEGS            Set memory size\n\
  \  --size WIDTHxHEIGHT   Set framebuffer size\n\
  \  --boot-from-serial    Boot from serial line (disk image not required)\n\
  \  --serial-in FILE      Read serial input from FILE\n\
  \  --serial-out FILE     Write serial output to FILE\n\
  \  --headless            Run without a window; exits after --frames, else runs until \
   killed\n\
  \  --frames N            Run N deterministic frames, print FNV-1a hashes, then exit \
   (headless only)\n"
;;

(** Outcome of CLI parsing; the caller owns printing and exiting. *)
type parsed =
  | Config of config
  | Help
  | Invalid of string

(** Validated configuration handed to the frontend. *)
and config =
  { width : int
  ; height : int
  ; mem : int
  ; configure : bool
  ; zoom : float
  ; fullscreen : bool
  ; leds : bool
  ; serial_in : string option
  ; serial_out : string option
  ; boot_from_serial : bool
  ; headless : bool
  ; frames : int option
  ; disk_image : string option
  }

let clamp lo hi v = if v < lo then lo else if v > hi then hi else v

let parse_size s =
  let sep =
    match String.index_opt s 'x' with
    | Some _ as i -> i
    | None -> String.index_opt s 'X'
  in
  match sep with
  | None -> Error (Printf.sprintf "invalid --size %S, expected WIDTHxHEIGHT" s)
  | Some i ->
    let w = String.sub s 0 i
    and h = String.sub s (i + 1) (String.length s - i - 1) in
    (match int_of_string_opt (String.trim w), int_of_string_opt (String.trim h) with
     | Some w, Some h -> Ok (w, h)
     | None, _ -> Error (Printf.sprintf "invalid width in --size %S" s)
     | _, None -> Error (Printf.sprintf "invalid height in --size %S" s))
;;

(* Split [--opt=value] into [--opt; value] so the parser only handles [--opt value]. *)
let split_eq arg =
  if String.starts_with ~prefix:"--" arg
  then (
    match String.index_opt arg '=' with
    | Some i -> [ String.sub arg 0 i; String.sub arg (i + 1) (String.length arg - i - 1) ]
    | None -> [ arg ])
  else [ arg ]
;;

(* Parse a raw argument list (the argv tail), so it is testable without Sys.argv. *)
let parse_argv raw_args =
  let zoom = ref 0.0
  and fullscreen = ref false
  and leds = ref false
  and mem = ref 0
  and size = ref None
  and serial_in = ref None
  and serial_out = ref None
  and boot_from_serial = ref false
  and headless = ref false
  and frames = ref None
  and disk = ref None
  and help = ref false
  and err = ref None in
  let fail msg = if !err = None then err := Some msg in
  let rec loop = function
    | [] -> ()
    | _ when !err <> None -> ()
    | "--zoom" :: v :: rest ->
      (match float_of_string_opt v with
       | Some x when x > 0.0 -> zoom := x
       | Some _ -> zoom := 0.0
       | None -> fail (Printf.sprintf "invalid --zoom %S" v));
      loop rest
    | "--mem" :: v :: rest ->
      (match int_of_string_opt v with
       | Some m -> mem := m
       | None -> fail (Printf.sprintf "invalid --mem %S" v));
      loop rest
    | "--size" :: v :: rest ->
      size := Some v;
      loop rest
    | "--serial-in" :: v :: rest ->
      serial_in := Some v;
      loop rest
    | "--serial-out" :: v :: rest ->
      serial_out := Some v;
      loop rest
    | "--frames" :: v :: rest ->
      (match int_of_string_opt v with
       | Some n -> frames := Some n
       | None -> fail (Printf.sprintf "invalid --frames %S" v));
      loop rest
    | "--fullscreen" :: rest ->
      fullscreen := true;
      loop rest
    | "--leds" :: rest ->
      leds := true;
      loop rest
    | "--boot-from-serial" :: rest ->
      boot_from_serial := true;
      loop rest
    | "--headless" :: rest ->
      headless := true;
      loop rest
    | ("--help" | "-h") :: _ -> help := true
    | (("--zoom" | "--mem" | "--size" | "--serial-in" | "--serial-out" | "--frames") as o)
      :: [] -> fail (Printf.sprintf "option %s requires a value" o)
    | opt :: _ when String.starts_with ~prefix:"-" opt ->
      fail (Printf.sprintf "unknown option %s" opt)
    | file :: rest ->
      disk := Some file;
      loop rest
  in
  loop (List.concat_map split_eq raw_args);
  let width = ref Risc_core.Risc.framebuffer_width in
  let height = ref Risc_core.Risc.framebuffer_height in
  (match !size with
   | Some s ->
     (match parse_size s with
      | Ok (w, h) ->
        width := clamp 32 max_dim w land lnot 31;
        (* round down to a multiple of 32 *)
        height := clamp 32 max_dim h
      | Error e -> fail e)
   | None -> ());
  if !help
  then Help
  else (
    match !err with
    | Some e -> Invalid e
    | None ->
      if !disk = None && not !boot_from_serial
      then
        Invalid
          "a DISK-IMAGE is required (or pass --boot-from-serial).\n\
           For more information, try '--help'."
      else if !frames <> None && not !headless
      then Invalid "--frames requires --headless"
      else
        Config
          { width = !width
          ; height = !height
          ; mem = !mem
          ; configure = !mem <> 0 || !size <> None
          ; zoom = !zoom
          ; fullscreen = !fullscreen
          ; leds = !leds
          ; serial_in = !serial_in
          ; serial_out = !serial_out
          ; boot_from_serial = !boot_from_serial
          ; headless = !headless
          ; frames = !frames
          ; disk_image = !disk
          })
;;

let parse () = parse_argv (List.tl (Array.to_list Sys.argv))
