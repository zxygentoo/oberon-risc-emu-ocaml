(** Serial transport over a PTY (raw mode) or a FIFO pair (port of oat's
    [transport.rs]). *)

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
  }

let poll_readable fd timeout =
  let rec go () =
    match Unix.select [ fd ] [] [] timeout with
    | r, _, _ -> r <> []
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> go ()
  in
  go ()
;;

(* Non-blocking: read and discard whatever is already buffered, so a stale or partial
   response from a prior exchange can't desync this one. Best effort — errors just
   stop the drain. *)
let drain_stale t =
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

let recv_exact t buf =
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

let write_all fd bytes =
  let n = Bytes.length bytes in
  let rec go written =
    if written < n
    then (
      match Unix.write fd bytes written (n - written) with
      | w -> go (written + w)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> go written
      | exception Unix.Unix_error (e, _, _) ->
        Error.fail (Error.Io (Unix.error_message e)))
  in
  go 0
;;

let send t frame =
  drain_stale t;
  let w = Option.value t.writer ~default:t.reader in
  if t.char_delay = 0.0
  then write_all w (Bytes.of_string frame)
  else
    (* One byte at a time, idling the wire between them so the device's cooperative
       poll can grab each byte. Slow but lossless on a raw UART. *)
    String.iter
      (fun c ->
         write_all w (Bytes.make 1 c);
         Unix.sleepf t.char_delay)
      frame;
  Protocol.read_response (recv_exact t)
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
  { reader; writer = Some writer; timeout; char_delay = 0.0 }
;;

(* Raw 8N1 at [baud] — cfmakeraw restated on [Unix.terminal_io] (IEXTEN is not
   exposed there; inert for this byte protocol), plus the line speed. cfmakeraw
   leaves the speed untouched — on a real UART that means whatever the port last had
   (often not ours), so pin it. FIFO transports skip this path entirely. *)
let set_raw_mode fd baud =
  let tio = Unix.tcgetattr fd in
  Unix.tcsetattr
    fd
    Unix.TCSANOW
    { tio with
      c_ignbrk = false
    ; c_brkint = false
    ; c_parmrk = false
    ; c_istrip = false
    ; c_inlcr = false
    ; c_igncr = false
    ; c_icrnl = false
    ; c_ixon = false
    ; c_opost = false
    ; c_echo = false
    ; c_echonl = false
    ; c_icanon = false
    ; c_isig = false
    ; c_csize = 8
    ; c_parenb = false
    ; c_vmin = 1
    ; c_vtime = 0
    ; c_ibaud = baud
    ; c_obaud = baud
    }
;;

let open_path path ~timeout ~baud ~char_delay =
  let open_err err = Error.fail (Error.Open_serial { path; err }) in
  let fd =
    try Unix.openfile path [ Unix.O_RDWR; Unix.O_NOCTTY ] 0 with
    | Unix.Unix_error (err, _, _) -> open_err err
  in
  (try set_raw_mode fd baud with
   | Unix.Unix_error (err, _, _) -> open_err err);
  { reader = fd; writer = None; timeout; char_delay }
;;

module For_tests = struct
  let make ~reader ~writer ~timeout ~char_delay = { reader; writer; timeout; char_delay }
end
