(** The SPI SD-card state machine (port of [disk.c] / [disk.rs]).

    Models just enough of the SD command protocol for Oberon: single-block read
    (CMD17 / 81) and write (CMD24 / 88), driven byte-by-byte through the {!Io.spi}
    interface. A [.dsk] image is backed by a host file opened read+write, or held in
    memory ({!of_string}); a filesystem-only image (first word [0x9B1EA38D]) is
    detected and its sector numbers are rebased by the fixed [0x80002] offset. *)

type state =
  | Command
  | Read
  | Write
  | Writing

(* Where the card's blocks live. A memory card is sparse: the image it was made
   from, overlaid with the blocks written since — so a guest write to a far block
   costs one block, not a dense buffer up to it. *)
type backing =
  | No_card (* diskless, or closed *)
  | File of Unix.file_descr
  | Memory of
      { image : string
      ; written : (int, Bytes.t) Hashtbl.t (* block number -> its 512 bytes *)
      }

(** An SD card attached to the SPI bus. *)
type t =
  { mutable state : state
  ; mutable backing : backing
  ; offset : int
  ; mutable pos : int (* byte position of the block the last command addressed *)
  ; rx_buf : int array (* 128 *)
  ; mutable rx_idx : int
  ; tx_buf : int array (* 128 + 2 *)
  ; mutable tx_cnt : int
  ; mutable tx_idx : int
  }

(* The C computes [secnum * 512] in 32-bit unsigned arithmetic. *)
let block_pos secnum = U32.wrap (secnum * 512)

(* The 512 bytes at [pos]. Short reads at EOF (or a failed seek or read — the card
   has no error path to report one) leave the rest zero, as the C's
   zero-initialised buffer + fread does. *)
let read_block backing pos =
  let bytes = Bytes.make 512 '\000' in
  (match backing with
   | No_card -> ()
   | File fd ->
     let rec fill off =
       if off < 512
       then (
         match Unix.read fd bytes off (512 - off) with
         | 0 -> ()
         | n -> fill (off + n)
         | exception Unix.Unix_error _ -> ())
     in
     (match Unix.lseek fd pos Unix.SEEK_SET with
      | _ -> fill 0
      | exception Unix.Unix_error _ -> ())
   | Memory { image; written } ->
     (match Hashtbl.find_opt written (pos / 512) with
      | Some block -> Bytes.blit block 0 bytes 0 512
      | None ->
        let n = min 512 (String.length image - pos) in
        if n > 0 then Bytes.blit_string image pos bytes 0 n));
  bytes
;;

let write_block backing pos bytes =
  match backing with
  | No_card -> ()
  | File fd ->
    let rec flush off =
      if off < 512
      then (
        match Unix.write fd bytes off (512 - off) with
        | 0 -> ()
        | n -> flush (off + n)
        | exception Unix.Unix_error _ -> ())
    in
    (match Unix.lseek fd pos Unix.SEEK_SET with
     | _ -> flush 0
     | exception Unix.Unix_error _ -> ())
  | Memory { written; _ } -> Hashtbl.replace written (pos / 512) (Bytes.copy bytes)
;;

(* Read the block at [pos] into [buf.(off .. off+127)] as little-endian words. *)
let read_sector backing pos buf off =
  let bytes = read_block backing pos in
  for i = 0 to 127 do
    buf.(off + i) <- U32.of_int32 (Bytes.get_int32_le bytes (i * 4))
  done
;;

let write_sector backing pos buf =
  let bytes = Bytes.make 512 '\000' in
  for i = 0 to 127 do
    U32.set_le bytes (i * 4) buf.(i)
  done;
  write_block backing pos bytes
;;

let make backing =
  let tx_buf = Array.make 130 0 in
  (* Detect a filesystem-only image, which starts directly at sector 1 (DiskAdr 29):
     read sector 0 and check the magic word. *)
  read_sector backing 0 tx_buf 0;
  { state = Command
  ; backing
  ; offset = (if tx_buf.(0) = 0x9B1E_A38D then 0x8_0002 else 0)
  ; pos = 0
  ; rx_buf = Array.make 128 0
  ; rx_idx = 0
  ; tx_buf
  ; tx_cnt = 0
  ; tx_idx = 0
  }
;;

(** Open a disk image (or build a diskless card with [None], for
    [--boot-from-serial]). Port of [disk_new]. *)
let create = function
  | None -> make No_card
  | Some path -> make (File (Unix.openfile path [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0))
;;

let of_string image = make (Memory { image; written = Hashtbl.create 64 })

let contents t =
  match t.backing with
  | Memory { image; written } ->
    let size =
      Hashtbl.fold
        (fun block _ n -> max n ((block + 1) * 512))
        written
        (String.length image)
    in
    let out = Bytes.make size '\000' in
    Bytes.blit_string image 0 out 0 (String.length image);
    Hashtbl.iter (fun block data -> Bytes.blit data 0 out (block * 512) 512) written;
    Bytes.unsafe_to_string out
  | No_card | File _ ->
    invalid_arg "Disk.contents: not an in-memory card (Disk.of_string)"
;;

let close t =
  (match t.backing with
   | File fd ->
     (try Unix.close fd with
      | Unix.Unix_error _ -> ())
   | No_card | Memory _ -> ());
  t.backing <- No_card
;;

let run_command t =
  let cmd = t.rx_buf.(0) in
  let arg =
    (t.rx_buf.(1) lsl 24)
    lor (t.rx_buf.(2) lsl 16)
    lor (t.rx_buf.(3) lsl 8)
    lor t.rx_buf.(4)
  in
  (match cmd with
   | 81 ->
     t.state <- Read;
     t.tx_buf.(0) <- 0;
     t.tx_buf.(1) <- 254;
     t.pos <- block_pos (U32.sub arg t.offset);
     read_sector t.backing t.pos t.tx_buf 2;
     t.tx_cnt <- 2 + 128
   | 88 ->
     t.state <- Write;
     t.pos <- block_pos (U32.sub arg t.offset);
     t.tx_buf.(0) <- 0;
     t.tx_cnt <- 1
   | _ ->
     t.tx_buf.(0) <- 0;
     t.tx_cnt <- 1);
  t.tx_idx <- -1
;;

let read_data t =
  if t.tx_idx >= 0 && t.tx_idx < t.tx_cnt then t.tx_buf.(t.tx_idx) else 255
;;

let write_data t value =
  t.tx_idx <- t.tx_idx + 1;
  match t.state with
  | Command ->
    if value land 0xFF <> 0xFF || t.rx_idx <> 0
    then (
      t.rx_buf.(t.rx_idx) <- value;
      t.rx_idx <- t.rx_idx + 1;
      if t.rx_idx = 6
      then (
        run_command t;
        t.rx_idx <- 0))
  | Read ->
    if t.tx_idx = t.tx_cnt
    then (
      t.state <- Command;
      t.tx_cnt <- 0;
      t.tx_idx <- 0)
  | Write -> if value = 254 then t.state <- Writing
  | Writing ->
    if t.rx_idx < 128 then t.rx_buf.(t.rx_idx) <- value;
    t.rx_idx <- t.rx_idx + 1;
    if t.rx_idx = 128 then write_sector t.backing t.pos t.rx_buf;
    if t.rx_idx = 130
    then (
      t.tx_buf.(0) <- 5;
      t.tx_cnt <- 1;
      t.tx_idx <- -1;
      t.rx_idx <- 0;
      t.state <- Command)
;;

(** The {!Io.spi} view of this disk (closures over its mutable state). *)
let to_spi t : Io.spi =
  { Io.spi_read_data = (fun () -> read_data t)
  ; spi_write_data = (fun v -> write_data t v)
  }
;;

module For_tests = struct
  let offset t = t.offset
end
