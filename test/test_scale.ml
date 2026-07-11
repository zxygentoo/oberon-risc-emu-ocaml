(* Display-scaling tests, ported from the Rust render.rs scale_display tests.
   Exercises the pure {!Render.scale_rect} (no SDL window needed). *)

open Tsdl
open Test_harness

let () =
  (* 4:3 framebuffer in a 2:1 window -> fit to height, centered horizontally. *)
  let scale, r = Render.scale_rect ~win_w:2000 ~win_h:768 ~tex_w:1024 ~tex_h:768 in
  check "letterbox_scale" (scale = 1.0);
  eq "letterbox_w" (Sdl.Rect.w r) 1024;
  eq "letterbox_h" (Sdl.Rect.h r) 768;
  eq "letterbox_x" (Sdl.Rect.x r) ((2000 - 1024) / 2);
  eq "letterbox_y" (Sdl.Rect.y r) 0;
  (* Integer 2x zoom fills the window exactly. *)
  let scale, r = Render.scale_rect ~win_w:2048 ~win_h:1536 ~tex_w:1024 ~tex_h:768 in
  check "zoom_scale" (scale = 2.0);
  eq "zoom_x" (Sdl.Rect.x r) 0;
  eq "zoom_y" (Sdl.Rect.y r) 0;
  eq "zoom_w" (Sdl.Rect.w r) 2048;
  eq "zoom_h" (Sdl.Rect.h r) 1536;
  (* texture_size: 32 pixels per framebuffer word, tracking configure_memory. *)
  let risc = Risc_core.Risc.make () in
  check "texture_size_default" (Render.texture_size risc = (1024, 768));
  Risc_core.Risc.configure_memory risc 1 800 600;
  check "texture_size_configured" (Render.texture_size risc = (800, 600));
  summary "scale checks"
;;
