(* Screenshot tests: the framebuffer -> image pixel geometry (bottom-up lines,
   LSB-leftmost words, set bit = white), a PNG round-trip through imagelib's own
   decoder, and the mpv-style naming scan. All in memory except the naming scan. *)

open Test_harness

let () =
  (* A 2-word x 3-line synthetic framebuffer. Framebuffer line 0 is the BOTTOM row
     of the image: word 0 = bit 0 (leftmost pixel), word 1 = bit 31 (rightmost). *)
  let words = [| 1; 0x80000000; 0; 0; 0xF; 0 |] in
  let img = Screenshot.image_of ~width_words:2 ~height:3 ~word:(Array.get words) in
  let grey x y = Image.read_grey img x y Fun.id in
  eq "width_px" img.Image.width 64;
  eq "height_px" img.Image.height 3;
  (* Top image row = framebuffer line 2: four leftmost pixels set (0xF). *)
  eq "top_left_white" (grey 0 0) 255;
  eq "top_4th_white" (grey 3 0) 255;
  eq "top_5th_black" (grey 4 0) 0;
  (* Middle row: all clear. *)
  eq "middle_black" (grey 10 1) 0;
  (* Bottom image row = framebuffer line 0. *)
  eq "bottom_lsb_leftmost_white" (grey 0 2) 255;
  eq "bottom_second_black" (grey 1 2) 0;
  eq "bottom_msb_rightmost_white" (grey 63 2) 255;
  eq "bottom_word_boundary_black" (grey 32 2) 0;
  (* PNG round-trip through imagelib's decoder — pixel-exact. *)
  let png = Screenshot.png_bytes img in
  check "png_magic" (String.length png > 8 && String.sub png 1 3 = "PNG");
  let back = ImageLib.PNG.parsefile (ImageUtil.chunk_reader_of_string png) in
  eq "decoded_width" back.Image.width 64;
  eq "decoded_height" back.Image.height 3;
  let mismatches = ref 0 in
  for y = 0 to 2 do
    for x = 0 to 63 do
      if Image.read_grey back x y Fun.id <> grey x y then incr mismatches
    done
  done;
  eq "roundtrip_pixels" !mismatches 0;
  (* Naming: the lowest unused number (mpv semantics), scanned per capture, so
     sessions never overwrite older shots. *)
  with_scratch ~prefix:"shots" (fun dir ->
    let cwd = Sys.getcwd () in
    Sys.chdir dir;
    Fun.protect
      ~finally:(fun () -> Sys.chdir cwd)
      (fun () ->
         eqs "first_name" (Screenshot.next_name ()) "risc-shot0001.png";
         write_file "risc-shot0001.png" "";
         write_file "risc-shot0002.png" "";
         eqs "skips_existing" (Screenshot.next_name ()) "risc-shot0003.png";
         (* A gap left by a deleted shot is filled first — lowest unused wins. *)
         rm_rf "risc-shot0001.png";
         eqs "gap_filled" (Screenshot.next_name ()) "risc-shot0001.png"));
  summary "screenshot checks"
;;
