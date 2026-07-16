(** The frontend application behind the [risc] binary: machine wiring from a validated
    {!Cli.config}, the windowed SDL loop, and the [--headless] runner. Port of
    [sdl-main.c]'s main loop (the Rust port's [app.rs]). *)

(** Map a key event to a frontend action ([sdl-main.c]'s hotkey table: Alt+F4 quit,
    F12 / Ctrl+Shift+Del reset, F11 / Alt+Enter / Cmd+Shift+F fullscreen, F10
    screenshot, and left Alt as a fake middle mouse button on both press and
    release). Pure; exposed for testing. *)
val map_action
  :  down:bool
  -> keycode:int
  -> kmod:int
  -> [ `Quit | `Reset | `Toggle_fullscreen | `Screenshot | `Fake_mouse2 | `Oberon_input ]

(** Run the frontend on a validated config: the SDL window loop, or the headless
    runner with [cfg.headless]. Returns only when the session ends. *)
val run : Cli.config -> unit
