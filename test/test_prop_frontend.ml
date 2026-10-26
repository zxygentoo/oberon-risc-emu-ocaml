(* Property-based (QCheck) tests for the frontend: the display-scaling law. The
   core's properties are in test_prop. *)

open Tsdl
module Q = QCheck2
module G = QCheck2.Gen

let dim = G.int_range 64 4096

let scale_props =
  [ Q.Test.make
      ~name:"scale_rect: fits, fills a dimension, centered"
      ~count:1000
      (G.tup4 dim dim dim dim)
      (fun (ww, wh, tw, th) ->
         let scale, r = Render.scale_rect ~win_w:ww ~win_h:wh ~tex_w:tw ~tex_h:th in
         let rw = Sdl.Rect.w r
         and rh = Sdl.Rect.h r in
         scale > 0.0
         && rw > 0
         && rh > 0
         && rw <= ww + 1
         && rh <= wh + 1 (* fits in the window *)
         && (rw >= ww - 1 || rh >= wh - 1) (* fills the limiting dimension *)
         && abs ((2 * Sdl.Rect.x r) + rw - ww) <= 1 (* centered horizontally *)
         && abs ((2 * Sdl.Rect.y r) + rh - wh) <= 1 (* centered vertically *))
  ]
;;

let () = QCheck_base_runner.run_tests_main scale_props
