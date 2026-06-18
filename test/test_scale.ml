(* Display-scaling tests, ported from the Rust render.rs scale_display tests.
   Exercises the pure {!Render.scale_rect} (no SDL window needed). *)

open Tsdl

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let eqx name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got %d, want %d\n" name got want)
;;

let () =
  (* 4:3 framebuffer in a 2:1 window -> fit to height, centered horizontally. *)
  let scale, r = Render.scale_rect ~win_w:2000 ~win_h:768 ~tex_w:1024 ~tex_h:768 in
  check "letterbox_scale" (scale = 1.0);
  eqx "letterbox_w" (Sdl.Rect.w r) 1024;
  eqx "letterbox_h" (Sdl.Rect.h r) 768;
  eqx "letterbox_x" (Sdl.Rect.x r) ((2000 - 1024) / 2);
  eqx "letterbox_y" (Sdl.Rect.y r) 0;
  (* Integer 2x zoom fills the window exactly. *)
  let scale, r = Render.scale_rect ~win_w:2048 ~win_h:1536 ~tex_w:1024 ~tex_h:768 in
  check "zoom_scale" (scale = 2.0);
  eqx "zoom_x" (Sdl.Rect.x r) 0;
  eqx "zoom_y" (Sdl.Rect.y r) 0;
  eqx "zoom_w" (Sdl.Rect.w r) 2048;
  eqx "zoom_h" (Sdl.Rect.h r) 1536;
  if !failures = 0
  then Printf.printf "ok: %d scale checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d scale checks failed\n" !failures !total;
    exit 1)
;;
