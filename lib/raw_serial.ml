(** Raw serial line over host file descriptors (port of the POSIX branch of
    [raw-serial.c] / [raw_serial.rs]), used by [--serial-in]/[--serial-out].

    Non-blocking fds with [Unix.select] for the ready/writable status bits, in
    place of the C's [poll(2)]. *)

type t =
  { fd_in : Unix.file_descr
  ; fd_out : Unix.file_descr
  }

(** Open the input (read-only) and output (read-write) files non-blocking. *)
let create filename_in filename_out =
  let fd_in = Unix.openfile filename_in [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
  let fd_out = Unix.openfile filename_out [ Unix.O_RDWR; Unix.O_NONBLOCK ] 0 in
  { fd_in; fd_out }
;;

let read_status t =
  (* Zero timeout: a pure readiness probe, as the C's [poll(fds, 2, 0)].
     bit 0 = rx ready, bit 1 = tx ready. *)
  try
    let r, w, _ = Unix.select [ t.fd_in ] [ t.fd_out ] [] 0.0 in
    (if r <> [] then 1 else 0) lor if w <> [] then 2 else 0
  with
  | Unix.Unix_error _ -> 0
;;

let read_data t =
  let b = Bytes.create 1 in
  try if Unix.read t.fd_in b 0 1 = 1 then Char.code (Bytes.get b 0) else 0 with
  | Unix.Unix_error _ -> 0 (* non-blocking: no data/EOF -> 0 *)
;;

let write_data t value =
  let b = Bytes.make 1 (Char.chr (value land 0xFF)) in
  try ignore (Unix.single_write t.fd_out b 0 1) with
  | Unix.Unix_error _ -> ()
;;

(** The {!Io.serial} view of this raw line (closures over its fds). *)
let to_serial t : Io.serial =
  { Io.serial_read_status = (fun () -> read_status t)
  ; serial_read_data = (fun () -> read_data t)
  ; serial_write_data = (fun v -> write_data t v)
  }
;;
