(** Framebuffer rendering for the tsdl frontend (port of [update_texture] and
    [scale_display] from [sdl-main.c]).

    A native-resolution ARGB streaming texture is refreshed only over the damaged
    framebuffer region; SDL's renderer does the bilinear scale into the window. *)

open Tsdl

(** A streaming-texture renderer bound to a window's renderer and the machine's
    framebuffer geometry. *)
type t

(** Create the streaming ARGB texture sized to the machine's framebuffer. *)
val create : Sdl.renderer -> Risc_core.Risc.t -> t

(** Refresh the texture from the framebuffer's damaged region. *)
val update : t -> Risc_core.Risc.t -> unit

(** [scale_rect ~win_w ~win_h ~tex_w ~tex_h] — centered, aspect-preserving
    placement (pure; no SDL window needed); returns the scale factor and the
    destination rectangle. *)
val scale_rect : win_w:int -> win_h:int -> tex_w:int -> tex_h:int -> float * Sdl.rect

(** [scale_rect] for the current size of [window]. *)
val scale_display : Sdl.window -> int -> int -> float * Sdl.rect

(** Clear, copy the scaled texture into the destination rect, and present. *)
val present : t -> Sdl.renderer -> Sdl.rect -> unit
