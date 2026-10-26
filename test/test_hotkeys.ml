(* Hotkey-table tests for {!App.map_action} (the port of sdl-main.c's key_map).
   Pure over ints — no SDL init needed. *)

open Tsdl
open Test_harness

let act = App.map_action ~repeat:false

let () =
  let none = Sdl.Kmod.none in
  check "alt_f4_quits" (act ~down:true ~keycode:Sdl.K.f4 ~kmod:Sdl.Kmod.lalt = `Quit);
  check "plain_f4_is_input" (act ~down:true ~keycode:Sdl.K.f4 ~kmod:none = `Oberon_input);
  check "f12_resets" (act ~down:true ~keycode:Sdl.K.f12 ~kmod:none = `Reset);
  check
    "ctrl_shift_del_resets"
    (act ~down:true ~keycode:Sdl.K.delete ~kmod:(Sdl.Kmod.lctrl lor Sdl.Kmod.lshift)
     = `Reset);
  check
    "plain_del_is_input"
    (act ~down:true ~keycode:Sdl.K.delete ~kmod:none = `Oberon_input);
  check
    "f11_fullscreen"
    (act ~down:true ~keycode:Sdl.K.f11 ~kmod:none = `Toggle_fullscreen);
  check
    "alt_enter_fullscreen"
    (act ~down:true ~keycode:Sdl.K.return ~kmod:Sdl.Kmod.ralt = `Toggle_fullscreen);
  check
    "cmd_shift_f_fullscreen"
    (act ~down:true ~keycode:Sdl.K.f ~kmod:(Sdl.Kmod.lgui lor Sdl.Kmod.lshift)
     = `Toggle_fullscreen);
  check "plain_f_is_input" (act ~down:true ~keycode:Sdl.K.f ~kmod:none = `Oberon_input);
  check "f10_screenshot" (act ~down:true ~keycode:Sdl.K.f10 ~kmod:none = `Screenshot);
  check
    "f10_release_is_input"
    (act ~down:false ~keycode:Sdl.K.f10 ~kmod:none = `Oberon_input);
  (* Left Alt is the fake middle button on both press and release; releases of
     anything else fall through to Oberon input. *)
  check
    "lalt_press_fake_mouse"
    (act ~down:true ~keycode:Sdl.K.lalt ~kmod:Sdl.Kmod.lalt = `Fake_mouse2);
  check
    "lalt_release_fake_mouse"
    (act ~down:false ~keycode:Sdl.K.lalt ~kmod:none = `Fake_mouse2);
  check
    "f12_release_is_input"
    (act ~down:false ~keycode:Sdl.K.f12 ~kmod:none = `Oberon_input);
  check "letter_is_input" (act ~down:true ~keycode:Sdl.K.a ~kmod:none = `Oberon_input);
  (* A held key auto-repeats: hotkeys act once per press, Oberon input repeats. *)
  let held = App.map_action ~repeat:true in
  check "held_f12_ignored" (held ~down:true ~keycode:Sdl.K.f12 ~kmod:none = `Ignore);
  check "held_f10_ignored" (held ~down:true ~keycode:Sdl.K.f10 ~kmod:none = `Ignore);
  check "held_f11_ignored" (held ~down:true ~keycode:Sdl.K.f11 ~kmod:none = `Ignore);
  check
    "held_alt_f4_ignored"
    (held ~down:true ~keycode:Sdl.K.f4 ~kmod:Sdl.Kmod.lalt = `Ignore);
  check "held_letter_repeats" (held ~down:true ~keycode:Sdl.K.a ~kmod:none = `Oberon_input);
  check
    "held_lalt_still_mouse"
    (held ~down:true ~keycode:Sdl.K.lalt ~kmod:none = `Fake_mouse2);
  summary "hotkey checks"
;;
