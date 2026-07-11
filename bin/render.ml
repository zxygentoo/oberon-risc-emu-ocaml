(** Framebuffer rendering for the tsdl frontend (port of [update_texture] and
    [scale_display] from [sdl-main.c]).

    Keeps a native-resolution ARGB streaming texture and refreshes only the
    damaged words into it each frame; SDL's renderer does the bilinear scale into
    the window (the [SDL_HINT_RENDER_SCALE_QUALITY = "best"] linear filter, far
    gentler on 1-bit text than nearest-neighbour). *)

open Tsdl
module Core = Risc_core.Risc

(* Solarized "off"/"on" colours used by the C frontend (ARGB, alpha ignored by
   the default BLENDMODE_NONE copy). *)
let black = 0x0065_7B83
let white = 0x00FD_F6E3

type t =
  { texture : Sdl.texture
  ; tex_h : int (* lines; the Y-flip pivot *)
  ; src : Sdl.rect (* whole texture, the render_copy source *)
  ; pixels : (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t
  }

(* The native texture size for the machine's framebuffer: 32 pixels per
   framebuffer word — the one home of the words -> pixels expansion. *)
let texture_size risc = Core.fb_width risc * 32, Core.fb_height risc

let create renderer risc =
  let tex_w, tex_h = texture_size risc in
  let texture =
    match
      Sdl.create_texture
        renderer
        Sdl.Pixel.format_argb8888
        Sdl.Texture.access_streaming
        ~w:tex_w
        ~h:tex_h
    with
    | Ok t -> t
    | Error (`Msg m) -> failwith ("could not create texture: " ^ m)
  in
  let pixels = Bigarray.Array1.create Bigarray.int32 Bigarray.c_layout (tex_w * tex_h) in
  { texture; tex_h; src = Sdl.Rect.create ~x:0 ~y:0 ~w:tex_w ~h:tex_h; pixels }
;;

(** Refresh the streaming texture from the framebuffer's damaged region,
    expanding each 1-bit word into 32 ARGB pixels (LSB = leftmost) and flipping
    Oberon's bottom-up framebuffer to top-down. Port of [update_texture]. *)
let update t risc =
  let { Core.x1; x2; y1; y2 } = Core.framebuffer_damage risc in
  if y1 <= y2
  then (
    let fbw = Core.fb_width risc in
    let out = ref 0 in
    for line = y2 downto y1 do
      let line_start = line * fbw in
      for col = x1 to x2 do
        let pixels = ref (Core.framebuffer_word risc (line_start + col)) in
        for _ = 0 to 31 do
          Bigarray.Array1.unsafe_set
            t.pixels
            !out
            (Int32.of_int (if !pixels land 1 <> 0 then white else black));
          pixels := !pixels lsr 1;
          incr out
        done
      done
    done;
    let w = (x2 - x1 + 1) * 32 in
    let rect = Sdl.Rect.create ~x:(x1 * 32) ~y:(t.tex_h - y2 - 1) ~w ~h:(y2 - y1 + 1) in
    (* tsdl's pitch is in bigarray elements, not bytes. *)
    ignore (Sdl.update_texture t.texture (Some rect) t.pixels w))
;;

(** Centered, aspect-preserving placement of an [tex_w] x [tex_h] framebuffer in
    a [win_w] x [win_h] window (the pure math behind [scale_display], port of
    [scale_display]); returns the scale factor and destination rect. *)
let scale_rect ~win_w ~win_h ~tex_w ~tex_h =
  let oberon_aspect = float_of_int tex_w /. float_of_int tex_h in
  let window_aspect = float_of_int win_w /. float_of_int win_h in
  let scale =
    if oberon_aspect > window_aspect
    then float_of_int win_w /. float_of_int tex_w
    else float_of_int win_h /. float_of_int tex_h
  in
  let w = int_of_float (ceil (float_of_int tex_w *. scale)) in
  let h = int_of_float (ceil (float_of_int tex_h *. scale)) in
  scale, Sdl.Rect.create ~x:((win_w - w) / 2) ~y:((win_h - h) / 2) ~w ~h
;;

(** [scale_rect] for the current size of [window]. *)
let scale_display window tex_w tex_h =
  let win_w, win_h = Sdl.get_window_size window in
  scale_rect ~win_w ~win_h ~tex_w ~tex_h
;;

(** Clear, copy the scaled texture into [dst], and present. *)
let present t renderer dst =
  ignore (Sdl.render_clear renderer);
  ignore (Sdl.render_copy ~src:t.src ~dst renderer t.texture);
  Sdl.render_present renderer
;;
