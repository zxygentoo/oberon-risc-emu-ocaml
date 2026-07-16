(** Wire framing for the PUT/GET/CALL/EDIT protocol oat speaks to [AgentTool.Mod] on
    the device (port of oat's [protocol.rs]). Host is master; ints are u32 LE. *)

(* The raw wire encoding never leaves this module: production code only encodes
   requests (the builders) and decodes responses (read_response); test fakes that
   play the device go through For_tests. Constants match AgentProtocol.Mod. *)
let sync_req = 0xA5
let sync_resp = 0x5A
let op_put = 1
let op_get = 2
let op_call = 3
let op_edit = 4
let edit_old_limit = 1024

type status =
  | Ok
  | Not_found
  | Trapped
  | Error
  | No_match
  | Not_unique
  | Other of int

let status_of_byte = function
  | 0 -> Ok
  | 1 -> Not_found
  | 2 -> Trapped
  | 3 -> Error
  | 4 -> No_match
  | 5 -> Not_unique
  | b -> Other b
;;

let status_byte = function
  | Ok -> 0
  | Not_found -> 1
  | Trapped -> 2
  | Error -> 3
  | No_match -> 4
  | Not_unique -> 5
  | Other b -> b
;;

type response =
  { status : status
  ; payload : string
  }

let ok r = r.status = Ok

type send = string -> response

let byte n = String.make 1 (Char.chr n)
let le32 n = String.init 4 (fun i -> Char.chr ((n lsr (8 * i)) land 0xFF))

(* 1-byte length prefix, then the chars; 1..255 bytes. *)
let name_field name =
  let len = String.length name in
  if len = 0 || len > 255 then Error.fail (Error.Bad_name { name; len });
  byte len ^ name
;;

let build_put ~name ~data =
  String.concat
    ""
    [ byte sync_req; byte op_put; name_field name; le32 (String.length data); data ]
;;

let build_get ~name = String.concat "" [ byte sync_req; byte op_get; name_field name ]

let build_call ~cmd ~par =
  String.concat
    ""
    [ byte sync_req; byte op_call; name_field cmd; le32 (String.length par); par ]
;;

let build_edit ~name ~old ~new_ =
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
  let length = Int32.to_int (Bytes.get_int32_le len 0) land 0xFFFFFFFF in
  let payload = Bytes.create length in
  if length > 0 then recv payload;
  { status = status_of_byte status; payload = Bytes.unsafe_to_string payload }
;;

module For_tests = struct
  type parsed =
    | Put of
        { name : string
        ; data : string
        }
    | Get of { name : string }
    | Call of
        { cmd : string
        ; par : string
        }
    | Edit of
        { name : string
        ; old : string
        ; new_ : string
        }

  let parse_request frame =
    if Char.code frame.[0] <> sync_req then failwith "bad request sync";
    let op = Char.code frame.[1] in
    let nlen = Char.code frame.[2] in
    let name = String.sub frame 3 nlen in
    let pos = ref (3 + nlen) in
    let blob () =
      let len = Int32.to_int (String.get_int32_le frame !pos) land 0xFFFFFFFF in
      pos := !pos + 4;
      let b = String.sub frame !pos len in
      pos := !pos + len;
      b
    in
    if op = op_put
    then Put { name; data = blob () }
    else if op = op_get
    then Get { name }
    else if op = op_call
    then Call { cmd = name; par = blob () }
    else if op = op_edit
    then (
      let old = blob () in
      Edit { name; old; new_ = blob () })
    else failwith (Printf.sprintf "bad op %d" op)
  ;;

  let encode_response status payload =
    String.concat
      ""
      [ byte sync_resp; byte (status_byte status); le32 (String.length payload); payload ]
  ;;
end
