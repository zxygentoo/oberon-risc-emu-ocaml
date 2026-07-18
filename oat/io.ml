(** The wire codec and the exchange discipline (see io.mli). *)

module Wire = Data.Wire

let sync_req = 0xA5
let sync_resp = 0x5A
let op_put = 1
let op_get = 2
let op_call = 3
let op_edit = 4
let byte n = String.make 1 (Char.chr n)
let le32 n = String.init 4 (fun i -> Char.chr ((n lsr (8 * i)) land 0xFF))

(* u32 LE at [pos] as a non-negative int (the land masks Int32's sign extension). *)
let u32 s pos = Int32.to_int (String.get_int32_le s pos) land 0xFFFFFFFF

(* 1-byte length prefix, then the chars; 1..255 bytes. *)
let name_field name =
  let len = String.length name in
  if len = 0 || len > 255 then Error.fail (Error.Bad_name { name; len });
  byte len ^ name
;;

let encode_request = function
  | Wire.Put { name; data } ->
    String.concat
      ""
      [ byte sync_req; byte op_put; name_field name; le32 (String.length data); data ]
  | Wire.Get { name } -> String.concat "" [ byte sync_req; byte op_get; name_field name ]
  | Wire.Call { cmd; par } ->
    String.concat
      ""
      [ byte sync_req; byte op_call; name_field cmd; le32 (String.length par); par ]
  | Wire.Edit { name; old; new_ } ->
    String.concat
      ""
      [ byte sync_req
      ; byte op_edit
      ; name_field name
      ; le32 (String.length old)
      ; old
      ; le32 (String.length new_)
      ; new_
      ]
;;

let read_response recv =
  let read_byte () =
    let b = Bytes.create 1 in
    recv b;
    Char.code (Bytes.get b 0)
  in
  let sync = read_byte () in
  if sync <> sync_resp
  then Error.fail (Error.Bad_sync { got = sync; expected = sync_resp });
  let status = read_byte () in
  let len = Bytes.create 4 in
  recv len;
  let length = u32 (Bytes.unsafe_to_string len) 0 in
  let payload = Bytes.create length in
  if length > 0 then recv payload;
  { Wire.status = Wire.status_of_byte status; payload = Bytes.unsafe_to_string payload }
;;

let retriable = function
  | Error.Timeout _ | Error.Bad_sync _ -> true
  | _ -> false
;;

let with_retries ~retries f =
  let rec go attempt =
    match f () with
    | v -> v
    | exception Error.Error e when retriable e && attempt < retries ->
      go (attempt + 1)
  in
  go 0
;;

let send device ~retries request =
  let frame = encode_request request in
  with_retries ~retries (fun () ->
    Device.drain device;
    Device.send device frame;
    read_response (Device.recv device))
;;

module For_tests = struct
  let encode_request = encode_request
  let read_response = read_response
  let with_retries = with_retries

  let parse_request frame =
    if Char.code frame.[0] <> sync_req then failwith "bad request sync";
    let op = Char.code frame.[1] in
    let nlen = Char.code frame.[2] in
    let name = String.sub frame 3 nlen in
    let pos = ref (3 + nlen) in
    let blob () =
      let len = u32 frame !pos in
      pos := !pos + 4;
      let b = String.sub frame !pos len in
      pos := !pos + len;
      b
    in
    if op = op_put
    then Wire.Put { name; data = blob () }
    else if op = op_get
    then Wire.Get { name }
    else if op = op_call
    then Wire.Call { cmd = name; par = blob () }
    else if op = op_edit
    then (
      let old = blob () in
      Wire.Edit { name; old; new_ = blob () })
    else failwith (Printf.sprintf "bad op %d" op)
  ;;

  let encode_response ({ status; payload } : Wire.response) =
    String.concat
      ""
      [ byte sync_resp
      ; byte (Wire.status_byte status)
      ; le32 (String.length payload)
      ; payload
      ]
  ;;
end
