(** The serial byte channel over a PTY (raw mode) or a FIFO pair. *)

type line =
  { path : string
  ; baud : int
  }

type t =
  { reader : Unix.file_descr
  ; writer : Unix.file_descr option
    (* [None] when reader and writer share an fd (PTY mode); writes go to [reader].
       [Some] for FIFO mode, where the two directions are distinct. *)
  ; timeout : float
  ; char_delay : float
    (* Inter-byte send delay ("character delay"), seconds. Zero = send the frame in
       one write (the FIFO/emulator path, lossless). Nonzero = pace the bytes out one
       at a time, so the real UART peer — a single-byte register with no flow control
       (the OberonStation RS232R), read by a cooperative poll — can grab each byte
       before the next overruns it. See the oat CLI's [--char-delay-us]. *)
  ; line : line option
    (* [Some] for a real serial line [open_device] set up and read back; [None]
       for FIFOs. *)
  }

let line t = t.line

let rec poll_readable fd timeout =
  match Unix.select [ fd ] [] [] timeout with
  | r, _, _ -> r <> []
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> poll_readable fd timeout
;;

let drain t =
  let scratch = Bytes.create 256 in
  let rec go () =
    if (try poll_readable t.reader 0.0 with Unix.Unix_error _ -> false)
    then (
      match Unix.read t.reader scratch 0 256 with
      | n when n > 0 -> go ()
      | _ -> ()
      | exception Unix.Unix_error _ -> ())
  in
  go ()
;;

let recv t buf =
  let want = Bytes.length buf in
  let rec go filled =
    if filled < want
    then
      if not (poll_readable t.reader t.timeout)
      then Error.fail (Error.Timeout { secs = t.timeout; got = filled; want })
      else (
        match Unix.read t.reader buf filled (want - filled) with
        | 0 -> Error.fail Error.Eof
        | n -> go (filled + n)
        (* EINTR: fall through and retry. *)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> go filled
        | exception Unix.Unix_error (e, _, _) ->
          Error.fail (Error.Io (Unix.error_message e)))
  in
  go 0
;;

(* Write s[pos .. pos+len-1] in full, straight from the string (no copy). *)
let write_all fd s ~pos ~len =
  let rec go written =
    if written < len
    then (
      match Unix.write_substring fd s (pos + written) (len - written) with
      | w -> go (written + w)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> go written
      | exception Unix.Unix_error (e, _, _) ->
        Error.fail (Error.Io (Unix.error_message e)))
  in
  go 0
;;

let send t frame =
  let w = Option.value t.writer ~default:t.reader in
  if t.char_delay = 0.0
  then write_all w frame ~pos:0 ~len:(String.length frame)
  else
    (* One byte at a time, idling the wire between them so the device's cooperative
       poll can grab each byte. Slow but lossless on a raw UART. *)
    String.iteri
      (fun i _ ->
         write_all w frame ~pos:i ~len:1;
         Unix.sleepf t.char_delay)
      frame
;;

(* O_RDWR avoids the open-blocking dance: a FIFO opened read-only blocks until a
   writer attaches, and vice versa. We just want a non-blocking open of either end. *)
let open_fifo path =
  try Unix.openfile path [ Unix.O_RDWR ] 0 with
  | Unix.Unix_error (err, _, _) -> Error.fail (Error.Open_fifo { path; err })
;;

let open_fifos ~in_path ~out_path ~timeout =
  let writer = open_fifo in_path in
  let reader = open_fifo out_path in
  { reader; writer = Some writer; timeout; char_delay = 0.0; line = None }
;;

(* The line setup lives in serial_stubs.c, not Unix.tcsetattr: the Unix stubs'
   baud table is frozen into the switch's static archive and goes stale across a
   glibc upgrade (115200 silently becomes 4098 baud). FIFO channels skip all of
   this. *)
external stub_bauds : unit -> int array = "oat_serial_bauds"
external stub_configure : Unix.file_descr -> int -> unit = "oat_serial_configure"
external stub_read_back : Unix.file_descr -> int * int * bool = "oat_serial_read_back"

let supported_bauds = Array.to_list (stub_bauds ())

(* The driver may accept the settings and still not apply them all, so compare
   what the line now holds against what was asked. An input speed of 0 is
   termios for "same as the output speed". *)
let verify fd { path; baud } =
  let in_baud, out_baud, raw = stub_read_back fd in
  let in_baud = if in_baud = 0 then out_baud else in_baud in
  if not (in_baud = baud && out_baud = baud && raw)
  then Error.fail (Error.Line_mismatch { path; baud; in_baud; out_baud; raw })
;;

let open_device path ~timeout ~baud ~char_delay =
  if not (List.mem baud supported_bauds)
  then Error.fail (Error.Unsupported_baud { baud; supported = supported_bauds });
  let open_err err = Error.fail (Error.Open_serial { path; err }) in
  (* O_NONBLOCK only for the open itself: a port whose CLOCAL is off would
     otherwise block here waiting for a carrier, before we get to set CLOCAL. *)
  let fd =
    try Unix.openfile path [ Unix.O_RDWR; Unix.O_NOCTTY; Unix.O_NONBLOCK ] 0 with
    | Unix.Unix_error (err, _, _) -> open_err err
  in
  let line = { path; baud } in
  (try
     Unix.clear_nonblock fd;
     stub_configure fd baud;
     verify fd line
   with
   | e ->
     Unix.close fd;
     (match e with
      | Unix.Unix_error (err, _, _) -> open_err err
      | e -> raise e));
  { reader = fd; writer = None; timeout; char_delay; line = Some line }
;;

module For_tests = struct
  let make ~reader ~writer ~timeout ~char_delay =
    { reader; writer; timeout; char_delay; line = None }
  ;;

  let as_serial t line = { t with line = Some line }
  let configure = stub_configure
  let read_back = stub_read_back
  let verify = verify
end
