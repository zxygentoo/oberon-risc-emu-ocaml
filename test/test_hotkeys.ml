(* Hotkey-table tests for {!App.map_action} (the port of sdl-main.c's key_map).
   Pure over ints — no SDL init needed. *)

open Tsdl
open Test_harness

let act = App.map_action

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
  summary "hotkey checks"
;;
