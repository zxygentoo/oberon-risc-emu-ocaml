(** Raw serial line over host file descriptors (port of the POSIX branch of
    [raw-serial.c] / [raw_serial.rs]), used by [--serial-in]/[--serial-out].

    Non-blocking fds with a zero-timeout [Unix.select] for the ready/writable
    status bits, as the C does.

    One deliberate divergence: rx-ready means a byte is actually there. [select]
    also reports end of input as readable — a FIFO whose writers have all closed,
    or a file read to its end — and the C, which then reads, hands the guest an
    endless run of rx-ready NULs. Those complete a frame cut short by its sender
    with zeros instead of letting the guest's receive time out. So the status
    poll reads the byte ahead and holds it for [read_data]; end of input reads as
    "nothing yet", as the line would be on hardware. *)

type t =
  { fd_in : Unix.file_descr
  ; fd_out : Unix.file_descr
  ; byte : Bytes.t (* one-byte read buffer *)
  ; mutable ahead : int (* the byte read ahead by the status poll; -1 when none *)
  ; mutable closed : bool
  }

(** Open the input (read-only) and output (read-write) files non-blocking. *)
let create filename_in filename_out =
  let fd_in =
    Unix.openfile filename_in [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0
  in
  let fd_out =
    try Unix.openfile filename_out [ Unix.O_RDWR; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 with
    | e ->
      Unix.close fd_in;
      raise e
  in
  { fd_in; fd_out; byte = Bytes.create 1; ahead = -1; closed = false }
;;

let close t =
  if not t.closed
  then (
    t.closed <- true;
    List.iter
      (fun fd ->
         try Unix.close fd with
         | Unix.Unix_error _ -> ())
      [ t.fd_in; t.fd_out ])
;;

(* One byte off the input, or -1 for none (no data yet, end of input, error). *)
let read_byte t =
  match Unix.read t.fd_in t.byte 0 1 with
  | 1 -> Char.code (Bytes.get t.byte 0)
  | _ -> -1
  | exception Unix.Unix_error _ -> -1
;;

(* Once closed, the line is idle and every call a no-op: the fd numbers may
   already belong to some other file. *)
let read_status t =
  (* Zero timeout: a pure readiness probe, as the C's [select].
     bit 0 = rx ready, bit 1 = tx ready. *)
  if t.closed
  then 0
  else (
    try
      let r, w, _ = Unix.select [ t.fd_in ] [ t.fd_out ] [] 0.0 in
      if t.ahead < 0 && r <> [] then t.ahead <- read_byte t;
      (if t.ahead >= 0 then 1 else 0) lor if w <> [] then 2 else 0
    with
    | Unix.Unix_error _ -> 0)
;;

(* The byte the status poll read ahead; else an unpolled read, where no data or
   end of input reads 0, as the C. *)
let read_data t =
  if t.ahead >= 0
  then (
    let b = t.ahead in
    t.ahead <- -1;
    b)
  else if t.closed
  then 0
  else max 0 (read_byte t)
;;

let write_data t value =
  if not t.closed
  then (
    let b = Bytes.make 1 (Char.chr (value land 0xFF)) in
    try ignore (Unix.single_write t.fd_out b 0 1) with
    | Unix.Unix_error _ -> ())
;;

(** The {!Io.serial} view of this raw line (closures over its fds). *)
let to_serial t : Io.serial =
  { Io.serial_read_status = (fun () -> read_status t)
  ; serial_read_data = (fun () -> read_data t)
  ; serial_write_data = (fun v -> write_data t v)
  }
;;
