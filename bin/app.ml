(** The frontend application behind the [risc] binary: machine wiring from a validated
    {!Cli.config}, the windowed 60 fps SDL loop, and the [--headless] runner
    (deterministic bounded mode for CI, or an unbounded windowless session). Port of
    [sdl-main.c]'s main loop (the Rust port's [app.rs]); the pure machine lives in
    {!Risc_core}. *)

open Tsdl
module RC = Risc_core
module Core = Risc_core.Risc

let cpu_hz = RC.Headless.cpu_hz
let fps = RC.Headless.fps

(* The LED device for --leds: logs the 8-bit state to stdout (port of show_leds).
   Bit 7 prints first: "LEDs: 7--4--1-" for 0x92. *)
let led_logger : RC.Io.led =
  { led_write =
      (fun value ->
        let led i =
          let bit = 7 - i in
          if value land (1 lsl bit) <> 0 then Char.chr (Char.code '0' + bit) else '-'
        in
        print_endline ("LEDs: " ^ String.init 8 led))
  }
;;

(* Wire the standard machine plus the config's extras, with [disk_path] as the SPI
   disk. Shared by the windowed and headless paths. Port of build_machine. *)
let build_machine (cfg : Cli.config) disk_path clipboard_host =
  let risc = RC.Headless.standard_machine ?disk:disk_path clipboard_host in
  if cfg.configure then Core.configure_memory risc cfg.mem cfg.width cfg.height;
  if cfg.boot_from_serial then Core.set_switches risc 1;
  if cfg.leds then Core.set_leds risc led_logger;
  (* --serial-in/--serial-out replace PCLink with a raw host serial line. *)
  if cfg.serial_in <> None || cfg.serial_out <> None
  then (
    let i = Option.value cfg.serial_in ~default:"/dev/null" in
    let o = Option.value cfg.serial_out ~default:"/dev/null" in
    Core.set_serial risc (RC.Raw_serial.to_serial (RC.Raw_serial.create i o)));
  risc
;;

let copy_file src dst =
  Out_channel.with_open_bin dst (fun oc ->
    output_string oc (In_channel.with_open_bin src In_channel.input_all))
;;

(* Map a key event to a frontend action, mirroring sdl-main.c's key_map. *)
let map_action ~down ~keycode ~kmod =
  let has m = kmod land m <> 0 in
  let open Sdl in
  if down && keycode = K.f4 && has Kmod.alt
  then `Quit
  else if down && keycode = K.f12
  then `Reset
  else if down && keycode = K.delete && has Kmod.ctrl && has Kmod.shift
  then `Reset
  else if down && keycode = K.f11
  then `Toggle_fullscreen
  else if down && keycode = K.return && has Kmod.alt
  then `Toggle_fullscreen
  else if down && keycode = K.f && has Kmod.gui && has Kmod.shift
  then `Toggle_fullscreen
  else if keycode = K.lalt
  then `Fake_mouse2 (* both press and release *)
  else `Oberon_input
;;

(* Run without a window. With --frames it's a deterministic experiment (boot a
   throwaway copy for N synthetic-clock frames, print FNV-1a hashes). Without, a
   headless session paced by wall time until killed. Port of run_headless. *)
let run_headless (cfg : Cli.config) =
  match cfg.frames with
  | None ->
    let risc = build_machine cfg cfg.disk_image RC.Clipboard.noop_host in
    let period = 1.0 /. float_of_int fps in
    let start = Unix.gettimeofday () in
    let rec loop next =
      let now = Unix.gettimeofday () in
      if now < next then Unix.sleepf (next -. now);
      let ms = int_of_float ((Unix.gettimeofday () -. start) *. 1000.0) in
      Core.set_time risc (RC.U32.wrap ms);
      Core.run risc (cpu_hz / fps);
      let next = next +. period in
      let now = Unix.gettimeofday () in
      (* If we fell behind (e.g. after a stall), resync rather than spiral. *)
      loop (if next < now then now +. period else next)
    in
    loop start
  | Some frames ->
    (* Boot writes to the disk, so run against a throwaway copy. *)
    let scratch =
      match cfg.disk_image with
      | Some src ->
        let tmp = Filename.temp_file "oberon_headless_" ".dsk" in
        copy_file src tmp;
        Some tmp
      | None -> None
    in
    Fun.protect
      ~finally:(fun () ->
        match scratch with
        | Some t ->
          (try Sys.remove t with
           | Sys_error _ -> ())
        | None -> ())
      (fun () ->
         let risc = build_machine cfg scratch RC.Clipboard.noop_host in
         RC.Headless.run_frames risc frames;
         let words = Core.fb_width risc * Core.fb_height risc in
         let rec count_blank i n =
           if i = words
           then n
           else
             count_blank (i + 1) (if Core.framebuffer_word risc i = 0 then n + 1 else n)
         in
         Printf.printf
           "frames=%d framebuffer_fnv1a=0x%016Lx state_fnv1a=0x%016Lx blank_words=%d/%d\n"
           frames
           (RC.Headless.framebuffer_hash risc)
           (RC.Headless.state_hash risc)
           (count_blank 0 0)
           words)
;;

let fail_with m =
  Printf.eprintf "risc: %s\n%!" m;
  exit 1
;;

let run_gui (cfg : Cli.config) =
  let risc = build_machine cfg cfg.disk_image Sdl_clipboard.host in
  (match Sdl.init Sdl.Init.video with
   | Ok () -> ()
   | Error (`Msg m) -> fail_with ("unable to initialize SDL: " ^ m));
  at_exit Sdl.quit;
  Sdl.enable_screen_saver ();
  ignore (Sdl.show_cursor false);
  ignore (Sdl.set_hint Sdl.Hint.render_scale_quality "best");
  let tex_w, tex_h = Render.texture_size risc in
  let zoom =
    if cfg.zoom > 0.0
    then cfg.zoom
    else (
      match Sdl.get_display_bounds 0 with
      | Ok r when Sdl.Rect.h r >= tex_h * 2 && Sdl.Rect.w r >= tex_w * 2 -> 2.0
      | _ -> 1.0)
  in
  let win_flags =
    if cfg.fullscreen then Sdl.Window.(hidden + fullscreen_desktop) else Sdl.Window.hidden
  in
  let w = int_of_float (float_of_int tex_w *. zoom)
  and h = int_of_float (float_of_int tex_h *. zoom) in
  let window =
    match Sdl.create_window "Project Oberon" ~w ~h win_flags with
    | Ok win -> win
    | Error (`Msg m) -> fail_with ("could not create window: " ^ m)
  in
  let renderer =
    match Sdl.create_renderer window with
    | Ok r -> r
    | Error (`Msg m) -> fail_with ("could not create renderer: " ^ m)
  in
  let rend = Render.create renderer risc in
  let scale = ref 1.0
  and dst = ref (Sdl.Rect.create ~x:0 ~y:0 ~w ~h) in
  let recompute () =
    let s, d = Render.scale_display window tex_w tex_h in
    scale := s;
    dst := d
  in
  recompute ();
  Render.update rend risc;
  Sdl.show_window window;
  Render.present rend renderer !dst;
  let e = Sdl.Event.create () in
  let fullscreen = ref cfg.fullscreen in
  let mouse_was_offscreen = ref false in
  let done_ = ref false in
  while not !done_ do
    let frame_start = Int32.to_int (Sdl.get_ticks ()) in
    while Sdl.poll_event (Some e) do
      let typ = Sdl.Event.(enum (get e typ)) in
      match typ with
      | `Quit -> done_ := true
      | `Window_event ->
        let id = Sdl.Event.(get e window_event_id) in
        if id = Sdl.Event.window_event_resized || id = Sdl.Event.window_event_size_changed
        then recompute ()
      | `Mouse_motion ->
        let mx = Sdl.Event.(get e mouse_motion_x)
        and my = Sdl.Event.(get e mouse_motion_y) in
        let scaled_x =
          int_of_float (Float.round (float_of_int (mx - Sdl.Rect.x !dst) /. !scale))
        in
        let scaled_y =
          int_of_float (Float.round (float_of_int (my - Sdl.Rect.y !dst) /. !scale))
        in
        let x = Cli.clamp 0 (tex_w - 1) scaled_x
        and y = Cli.clamp 0 (tex_h - 1) scaled_y in
        let offscreen = x <> scaled_x || y <> scaled_y in
        if offscreen <> !mouse_was_offscreen
        then (
          ignore (Sdl.show_cursor offscreen);
          mouse_was_offscreen := offscreen);
        Core.mouse_moved risc x (tex_h - y - 1)
      | `Mouse_button_down | `Mouse_button_up ->
        let down = typ = `Mouse_button_down in
        Core.mouse_button risc Sdl.Event.(get e mouse_button_button) down
      | `Key_down | `Key_up ->
        let down = typ = `Key_down in
        let keycode = Sdl.Event.(get e keyboard_keycode) in
        let kmod = Sdl.Event.(get e keyboard_keymod) in
        let scancode = Sdl.Event.(get e keyboard_scancode) in
        (match map_action ~down ~keycode ~kmod with
         | `Quit -> done_ := true
         | `Reset -> Core.reset risc
         | `Toggle_fullscreen ->
           fullscreen := not !fullscreen;
           ignore
             (Sdl.set_window_fullscreen
                window
                (if !fullscreen
                 then Sdl.Window.fullscreen_desktop
                 else Sdl.Window.windowed))
         | `Fake_mouse2 -> Core.mouse_button risc 2 down
         | `Oberon_input ->
           let bytes = Ps2.encode ~scancode ~make:down ~kmod in
           if Bytes.length bytes > 0 then Core.keyboard_input risc bytes)
      | _ -> ()
    done;
    Core.set_time risc (RC.U32.wrap frame_start);
    Core.run risc (cpu_hz / fps);
    Render.update rend risc;
    Render.present rend renderer !dst;
    let frame_end = Int32.to_int (Sdl.get_ticks ()) in
    let delay = frame_start + (1000 / fps) - frame_end in
    if delay > 0 then Sdl.delay (Int32.of_int delay)
  done
;;

let run (cfg : Cli.config) = if cfg.headless then run_headless cfg else run_gui cfg
