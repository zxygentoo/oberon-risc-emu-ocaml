(** The SPI SD-card state machine (port of [disk.c] / [disk.rs]).

    Models just enough of the SD command protocol for Oberon: single-block read
    (CMD17 / 81) and write (CMD24 / 88), driven byte-by-byte through the {!Io.spi}
    interface. A [.dsk] image is backed by a host file opened read+write; a
    filesystem-only image (first word [0x9B1EA38D]) is detected and its sector
    numbers are rebased by the fixed [0x80002] offset. *)

type state =
  | Command
  | Read
  | Write
  | Writing

(** An SD card attached to the SPI bus, backed by a [.dsk] host file. *)
type t =
  { mutable state : state
  ; fd : Unix.file_descr option
  ; offset : int
  ; rx_buf : int array (* 128 *)
  ; mutable rx_idx : int
  ; tx_buf : int array (* 128 + 2 *)
  ; mutable tx_cnt : int
  ; mutable tx_idx : int
  }

(* The C computes [secnum * 512] in 32-bit unsigned arithmetic. *)
let seek_sector fd secnum = ignore (Unix.lseek fd (U32.wrap (secnum * 512)) Unix.SEEK_SET)

(* Read up to 512 bytes at the fd's current position into [buf.(off .. off+127)]
   as little-endian words. Short reads at EOF leave the rest zero, as the C's
   zero-initialised buffer + fread does. *)
let read_sector fd buf off =
  let bytes = Bytes.make 512 '\000' in
  (match fd with
   | Some fd ->
     (* Fill from the current position; stop short at EOF (read 0) or on error. *)
     let rec fill pos =
       if pos < 512
       then (
         match Unix.read fd bytes pos (512 - pos) with
         | 0 -> ()
         | n -> fill (pos + n)
         | exception Unix.Unix_error _ -> ())
     in
     fill 0
   | None -> ());
  for i = 0 to 127 do
    buf.(off + i) <- U32.of_int32 (Bytes.get_int32_le bytes (i * 4))
  done
;;

let write_sector fd buf =
  match fd with
  | None -> ()
  | Some fd ->
    let bytes = Bytes.make 512 '\000' in
    for i = 0 to 127 do
      U32.set_le bytes (i * 4) buf.(i)
    done;
    let rec flush pos =
      if pos < 512
      then (
        match Unix.write fd bytes pos (512 - pos) with
        | 0 -> ()
        | n -> flush (pos + n)
        | exception Unix.Unix_error _ -> ())
    in
    flush 0
;;

(** Open a disk image (or build a diskless card with [None], for
    [--boot-from-serial]). Port of [disk_new]. *)
let create filename =
  let tx_buf = Array.make 130 0 in
  let fd, offset =
    match filename with
    | None -> None, 0
    | Some path ->
      let fd = Unix.openfile path [ Unix.O_RDWR ] 0 in
      (* Detect a filesystem-only image, which starts directly at sector 1
         (DiskAdr 29): read sector 0 and check the magic word. *)
      read_sector (Some fd) tx_buf 0;
      Some fd, if tx_buf.(0) = 0x9B1E_A38D then 0x8_0002 else 0
  in
  { state = Command
  ; fd
  ; offset
  ; rx_buf = Array.make 128 0
  ; rx_idx = 0
  ; tx_buf
  ; tx_cnt = 0
  ; tx_idx = 0
  }
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
     let secnum = U32.sub arg t.offset in
     Option.iter (fun fd -> seek_sector fd secnum) t.fd;
     read_sector t.fd t.tx_buf 2;
     t.tx_cnt <- 2 + 128
   | 88 ->
     t.state <- Write;
     let secnum = U32.sub arg t.offset in
     Option.iter (fun fd -> seek_sector fd secnum) t.fd;
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
    if t.rx_idx = 128 then write_sector t.fd t.rx_buf;
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
