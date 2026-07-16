(** Framebuffer screenshots: 8-bit grayscale PNGs (via imagelib), mpv-style
    [risc-shot%04d.png] naming in the working directory. *)

module Core = Risc_core.Risc

let image_of ~width_words ~height ~word =
  let img = Image.create_grey ~max_val:255 (width_words * 32) height in
  for line = 0 to height - 1 do
    (* Oberon's framebuffer is bottom-up; image rows are top-down. *)
    let y = height - 1 - line in
    for col = 0 to width_words - 1 do
      let w = ref (word ((line * width_words) + col)) in
      for k = 0 to 31 do
        (* LSB = leftmost pixel, as render.ml expands words; set = white. *)
        Image.write_grey img ((col * 32) + k) y (if !w land 1 <> 0 then 255 else 0);
        w := !w lsr 1
      done
    done
  done;
  img
;;

let png_bytes img =
  let buf = Buffer.create 65536 in
  ImageLib.PNG.write (ImageUtil.chunk_writer_of_buffer buf) img;
  Buffer.contents buf
;;

let next_name () =
  let rec go i =
    let name = Printf.sprintf "risc-shot%04d.png" i in
    if Sys.file_exists name then go (i + 1) else name
  in
  go 1
;;

let save risc =
  let img =
    image_of
      ~width_words:(Core.fb_width risc)
      ~height:(Core.fb_height risc)
      ~word:(Core.framebuffer_word risc)
  in
  let name = next_name () in
  (* Temp file in the same directory, so the rename is atomic: the shot appearing
     under its final name means it is complete. *)
  let tmp = name ^ ".tmp" in
  Out_channel.with_open_bin tmp (fun oc -> Out_channel.output_string oc (png_bytes img));
  Sys.rename tmp name;
  name
;;
