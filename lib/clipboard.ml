(** The clipboard GET/PUT state machine bridging the host clipboard to Oberon
    (port of [sdl-clipboard.c]'s state machine / [clipboard.rs]).

    Oberon uses bare CR line endings; the host uses LF (or CRLF). On GET (host ->
    Oberon) CRLF/LF are folded to CR; on PUT (Oberon -> host) CR becomes LF.
    Oberon text is Latin-1: PUT decodes each byte as its Latin-1 code point and
    re-encodes as UTF-8 for the host, while GET passes the host's UTF-8 bytes to
    Oberon unchanged. The host clipboard is supplied as a {!host} record so the
    bridge is testable and the core stays independent of any GUI toolkit. *)

(** Abstraction over the host system clipboard. *)
type host =
  { get_text : unit -> string option
  ; set_text : string -> unit
  }

type state =
  | Idle
  | Get
  | Put

(** The clipboard device exposed to the CPU over the {!Io.clipboard} MMIO ports. *)
type t =
  { host : host
  ; mutable state : state
  ; mutable data : Bytes.t
  ; mutable ptr : int
  ; mutable len : int
  }

let create host = { host; state = Idle; data = Bytes.empty; ptr = 0; len = 0 }

let reset t =
  t.state <- Idle;
  t.data <- Bytes.empty;
  t.len <- 0;
  t.ptr <- 0
;;

let read_control t =
  reset t;
  match t.host.get_text () with
  | None -> 0
  | Some text ->
    let data = Bytes.of_string text in
    let data_len = Bytes.length data in
    if data_len = 0
    then 0
    else (
      (* Announce the length Oberon will receive: each CRLF collapses to one CR. *)
      let rec count_crlf i n =
        if i >= data_len - 1
        then n
        else
          count_crlf
            (i + 1)
            (if Bytes.get data i = '\r' && Bytes.get data (i + 1) = '\n' then n + 1 else n)
      in
      t.data <- data;
      t.len <- data_len;
      t.ptr <- 0;
      t.state <- Get;
      data_len - count_crlf 0 0)
;;

let write_control t len =
  reset t;
  if len < U32.mask
  then (
    t.data <- Bytes.make len '\000';
    t.len <- len;
    t.state <- Put)
;;

let read_data t =
  if t.state <> Get || t.ptr >= t.len
  then 0
  else (
    let c = Char.code (Bytes.get t.data t.ptr) in
    t.ptr <- t.ptr + 1;
    let result =
      if c = Char.code '\r' && t.ptr < t.len && Bytes.get t.data t.ptr = '\n'
      then (
        t.ptr <- t.ptr + 1;
        c (* CRLF -> CR: skip the LF *))
      else if c = Char.code '\n'
      then Char.code '\r' (* lone LF -> CR *)
      else c
    in
    if t.ptr = t.len then reset t;
    result)
;;

let write_data t c =
  if t.state = Put && t.ptr < t.len
  then (
    let byte = if c = Char.code '\r' then '\n' else Char.chr (c land 0xFF) in
    (* CR -> LF *)
    Bytes.set t.data t.ptr byte;
    t.ptr <- t.ptr + 1;
    if t.ptr = t.len
    then (
      (* Oberon text is Latin-1, where every byte is a code point; encode each as
         UTF-8 (a lossy UTF-8 decode would mangle every byte >= 0x80). *)
      let buf = Buffer.create (t.len * 2) in
      Bytes.iter
        (fun b ->
           let code = Char.code b in
           if code < 0x80
           then Buffer.add_char buf (Char.chr code)
           else (
             Buffer.add_char buf (Char.chr (0xC0 lor (code lsr 6)));
             Buffer.add_char buf (Char.chr (0x80 lor (code land 0x3F)))))
        t.data;
      t.host.set_text (Buffer.contents buf);
      reset t))
;;

(** The {!Io.clipboard} view of this bridge (closures over its mutable state). *)
let to_clipboard t : Io.clipboard =
  { Io.clip_read_control = (fun () -> read_control t)
  ; clip_write_control = (fun v -> write_control t v)
  ; clip_read_data = (fun () -> read_data t)
  ; clip_write_data = (fun v -> write_data t v)
  }
;;
