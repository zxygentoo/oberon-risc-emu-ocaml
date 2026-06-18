(** The SDL-backed host clipboard, bridging the OS clipboard to the core's
    {!Risc_core.Clipboard} state machine (port of the SDL access in
    [sdl-clipboard.c]). *)

open Tsdl

(** A {!Risc_core.Clipboard.host} backed by SDL's clipboard. *)
let host : Risc_core.Clipboard.host =
  { get_text =
      (fun () ->
        match Sdl.get_clipboard_text () with
        | Ok s -> Some s
        | Error _ -> None)
  ; set_text = (fun s -> ignore (Sdl.set_clipboard_text s))
  }
;;
