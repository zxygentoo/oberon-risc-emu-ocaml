(** Translate SDL scancodes to PS/2 code-set-2 scancodes (port of [sdl-ps2.c]). *)

(** Encode a key make ([true]) / break ([false]) into PS/2 set-2 bytes. [scancode]
    is an [Sdl.Scancode]; [kmod] supplies the live shift state for the keypad-[/]
    "shift hack". Returns the emitted bytes (possibly empty). *)
val encode : scancode:int -> make:bool -> kmod:int -> bytes
