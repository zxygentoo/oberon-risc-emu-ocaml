(** PCLink file transfer over the serial line (port of [pclink.c] / [pclink.rs]).

    Watches for two job files ([PCLink.REC], naming a host file to send *to*
    Oberon, and [PCLink.SND], naming a host file to receive *from* Oberon),
    driving the framed byte protocol the Oberon PCLink tool speaks. The C resolves
    these names relative to the working directory; we keep that default but allow
    a base directory to be set, which makes the protocol testable. *)

let ack = 0x10
let rec_mode = 0x21
let snd_mode = 0x22

(* The open host file behind the current job: REC reads the payload, SND writes. *)
type job_file =
  | Rec of in_channel
  | Snd of out_channel

type t =
  { dir : string
  ; mutable mode : int (* 0 (idle), rec_mode, or snd_mode *)
  ; mutable file : job_file option
  ; mutable txcount : int
  ; mutable rxcount : int
  ; mutable fnlen : int
  ; mutable flen : int
  ; mutable filename : string
  ; buf : Bytes.t (* 257 *)
  }

(** Watch job files and resolve transferred filenames under [dir]. *)
let in_dir dir =
  { dir
  ; mode = 0
  ; file = None
  ; txcount = 0
  ; rxcount = 0
  ; fnlen = 0
  ; flen = 0
  ; filename = ""
  ; buf = Bytes.make 257 '\000'
  }
;;

(** Watch [./PCLink.REC] and [./PCLink.SND], as the C does. *)
let create () = in_dir "."

let rec_name t = Filename.concat t.dir "PCLink.REC"
let snd_name t = Filename.concat t.dir "PCLink.SND"
let target t = Filename.concat t.dir t.filename

let close_file t =
  (match t.file with
   | Some (Rec ic) -> close_in_noerr ic
   | Some (Snd oc) -> close_out_noerr oc
   | None -> ());
  t.file <- None
;;

let read_whole path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
;;

(* Best-effort removal of a job/target file. *)
let try_remove path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

(* First whitespace-delimited token, matching Rust's [split_whitespace().next()]
   on the ASCII filenames PCLink carries. *)
let first_token s =
  let is_ws c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\011' || c = '\012' in
  let n = String.length s in
  let rec skip i = if i < n && is_ws s.[i] then skip (i + 1) else i in
  let rec scan j = if j < n && not (is_ws s.[j]) then scan (j + 1) else j in
  let i = skip 0 in
  let j = scan i in
  if j > i then Some (String.sub s i (j - i)) else None
;;

(* Read the target filename from a job file (1..33 bytes), resetting the transfer
   counters; delete the job file if it is unusable. Port of [GetJob]. *)
let get_job t job_name =
  match Unix.stat job_name with
  | exception Unix.Unix_error _ -> false (* no job file *)
  | st ->
    let len = st.Unix.st_size in
    let loaded =
      if len > 0 && len <= 33
      then (
        match
          try first_token (read_whole job_name) with
          | Sys_error _ | End_of_file -> None
        with
        | Some tok ->
          t.filename <- (if String.length tok > 31 then String.sub tok 0 31 else tok);
          t.txcount <- 0;
          t.rxcount <- 0;
          t.fnlen <- String.length t.filename + 1;
          true
        | None -> false)
      else false
    in
    (* Delete a present-but-unusable job file. *)
    if not loaded then try_remove job_name;
    loaded
;;

let read_status t =
  if t.mode = 0
  then
    if get_job t (rec_name t)
    then (
      (* REC: send a host file to Oberon. *)
      (try
         let sz = (Unix.stat (target t)).Unix.st_size in
         if sz < 0x0100_0000
         then (
           try
             let ic = open_in_bin (target t) in
             t.flen <- sz;
             t.mode <- rec_mode;
             t.file <- Some (Rec ic);
             Printf.printf "PCLink REC Filename: %s size %d\n%!" t.filename t.flen
           with
           | Sys_error _ -> ())
       with
       | Unix.Unix_error _ -> ());
      if t.mode = 0 then try_remove (rec_name t))
    else if get_job t (snd_name t)
    then (
      (* SND: receive a file from Oberon into a host file. *)
      (try
         let oc = open_out_gen [ Open_creat; Open_trunc; Open_wronly ] 0o644 (target t) in
         t.flen <- -1;
         t.mode <- snd_mode;
         t.file <- Some (Snd oc);
         Printf.printf "PCLink SND Filename: %s\n%!" t.filename
       with
       | Sys_error _ -> ());
      if t.mode = 0 then try_remove (snd_name t));
  2 + if t.mode <> 0 then 1 else 0 (* bit1: xmit ready; bit0: active *)
;;

let read_data t =
  let ch =
    if t.mode = 0
    then 0
    else if t.rxcount = 0
    then t.mode
    else if t.rxcount < t.fnlen + 1
    then (
      (* Filename bytes followed by its NUL terminator. *)
      let idx = t.rxcount - 1 in
      if idx < String.length t.filename then Char.code t.filename.[idx] else 0)
    else if t.mode = snd_mode
    then (
      if t.flen = 0
      then (
        t.mode <- 0;
        close_file t;
        try_remove (snd_name t));
      ack)
    else (
      (* REC payload, framed as 255-byte blocks each prefixed by a length byte; a
         length < 255 (here 0) ends the transfer. *)
      let pos = (t.rxcount - t.fnlen - 1) mod 256 in
      if pos = 0 || t.flen = 0
      then
        if t.flen > 255
        then 255
        else (
          if t.flen = 0
          then (
            t.mode <- 0;
            close_file t;
            try_remove (rec_name t));
          t.flen)
      else (
        let b =
          match t.file with
          | Some (Rec ic) ->
            (try Char.code (input_char ic) with
             | End_of_file -> 0)
          | _ -> 0
        in
        t.flen <- t.flen - 1;
        b))
  in
  t.rxcount <- t.rxcount + 1;
  ch
;;

let write_data t value =
  if t.mode <> 0
  then
    if t.txcount = 0
    then (
      if
        (* The first byte must be ACK; anything else aborts the job. *)
        value <> ack
      then (
        close_file t;
        if t.mode = snd_mode
        then (
          try_remove (target t);
          try_remove (snd_name t))
        else try_remove (rec_name t);
        t.mode <- 0))
    else if t.mode = snd_mode
    then (
      let pos = (t.txcount - 1) mod 256 in
      Bytes.set t.buf pos (Char.chr (value land 0xFF));
      let lim = Char.code (Bytes.get t.buf 0) in
      if pos = lim
      then (
        (match t.file with
         | Some (Snd oc) -> output_string oc (Bytes.sub_string t.buf 1 lim)
         | _ -> ());
        if lim < 255
        then (
          t.flen <- 0;
          close_file t)));
  t.txcount <- t.txcount + 1
;;

(** The {!Io.serial} view of this PCLink (closures over its mutable state). *)
let to_serial t : Io.serial =
  { Io.serial_read_status = (fun () -> read_status t)
  ; serial_read_data = (fun () -> read_data t)
  ; serial_write_data = (fun v -> write_data t v)
  }
;;
