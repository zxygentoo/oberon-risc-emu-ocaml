(** Framebuffer screenshots: 8-bit grayscale PNGs (via imagelib), named
    [risc-shot0001.png] onward in the working directory — mpv's naming scheme, so
    agents and humans can predict the next file. Capture is a pure read of the
    framebuffer; the golden hashes are unaffected. *)

(** The framebuffer as a top-down grayscale image. [word i] is the 1-bit
    framebuffer word at index [i] (as {!Risc_core.Risc.framebuffer_word}): 32
    LSB-leftmost pixels per word, line 0 at the bottom; set bits render white. *)
val image_of : width_words:int -> height:int -> word:(int -> int) -> Image.image

(** The PNG encoding of an image. *)
val png_bytes : Image.image -> string

(** The lowest-numbered [risc-shot%04d.png] not present in the working directory
    (mpv's numbering: sessions never overwrite older shots). *)
val next_name : unit -> string

(** Capture the machine's native framebuffer to the next free shot name, written
    atomically (temp file + rename, so the file appearing means it is complete);
    returns the file name. *)
val save : Risc_core.Risc.t -> string
