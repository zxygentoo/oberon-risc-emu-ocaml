(** The SDL-backed host clipboard, bridging the OS clipboard to the core's
    {!Oberon_risc.Clipboard} state machine (port of the SDL access in
    [sdl-clipboard.c]). *)

open Tsdl

(** A {!Oberon_risc.Clipboard.host} backed by SDL's clipboard. *)
let host : Oberon_risc.Clipboard.host =
  { get_text =
      (fun () ->
        match Sdl.get_clipboard_text () with
        | Ok s -> Some s
        | Error _ -> None)
  ; set_text = (fun s -> ignore (Sdl.set_clipboard_text s))
  }
;;
