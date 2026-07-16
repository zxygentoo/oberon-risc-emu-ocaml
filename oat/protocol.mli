(** Wire framing for the PUT/GET/CALL/EDIT protocol oat speaks to [AgentTool.Mod] on
    the device (port of oat's [protocol.rs]).

    Host is master: build a REQUEST, send it, then read one RESPONSE. All multi-byte
    integers are unsigned little-endian; names carry a 1-byte length prefix.

    This module is the shared vocabulary of the oat layering: {!Tools} (semantics)
    and {!Transport} (I/O) both depend on it and on nothing else of each other —
    {!type:send} is the seam between them. *)

(** Device status of a RESPONSE. The wire byte is an encoding detail private to this
    module — upper layers match on constructors. [Other] carries status bytes this
    build doesn't know (newer device), kept for diagnostics. *)
type status =
  | Ok
  | Not_found
  | Trapped
  | Error
  | No_match (** EDIT: OLD does not occur in the file. *)
  | Not_unique (** EDIT: OLD occurs more than once; payload = count (u32 LE). *)
  | Other of int

(** The wire byte — for error messages and tests that craft raw frames. *)
val status_byte : status -> int

type response =
  { status : status
  ; payload : string
  }

val ok : response -> bool

(** The occurrence count carried by a [Not_unique] response (u32 LE payload); 0 when
    the payload is absent or short. Kept here so the wire encoding never leaves this
    module. *)
val not_unique_count : response -> int

(** The seam between the typed world and the fd world: send one encoded REQUEST frame,
    get back the decoded RESPONSE. {!Transport.send} is the real implementation;
    {!Retry.wrap} decorates it; Tools tests plug in an in-memory fake. *)
type send = string -> response

(** Longest OLD fragment (in device bytes, after LF -> CR conversion) that an EDIT
    frame may carry — the device matches inside a fixed buffer. Keep in sync with
    [editLim] in [oat/Mod/Common/AgentProtocol.Mod]. {!Tools.edit_file} falls back to
    the GET+PUT path for anything longer. *)
val edit_old_limit : int

(** The REQUEST builders.
    @raise Error.Error on a name outside 1..255 bytes. *)

val build_put : name:string -> data:string -> string
val build_get : name:string -> string
val build_call : cmd:string -> par:string -> string
val build_edit : name:string -> old:string -> new_:string -> string

(** [read_response recv] reads one RESPONSE frame; [recv buf] must fill all of [buf].
    @raise Error.Error on a bad sync byte (and whatever [recv] raises). *)
val read_response : (bytes -> unit) -> response

(** The device's half of the codec, for test fakes that play the device and for
    transport tests that feed raw frames through the real decoder — {b not} used in
    production (oat never parses requests). *)
module For_tests : sig
  (** A REQUEST frame as the device sees it after parsing. *)
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

  (** Parse a REQUEST frame. Raises on malformed input — test code. *)
  val parse_request : string -> parsed

  (** Encode a RESPONSE frame exactly as the device would. *)
  val encode_response : status -> string -> string
end
