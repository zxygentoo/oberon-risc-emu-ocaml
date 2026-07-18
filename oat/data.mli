(** The two oat vocabularies — pure data, shared by every layer.

    Operation level: one {!request} per oat subcommand and one {!response} per
    typed result. {!Cli} parses argv into a request and renders the response;
    {!Tool_call.execute} maps one onto the other.

    Wire level ({!Wire}): the four-opcode REQUEST/RESPONSE grammar oat speaks to
    [AgentTool.Mod] on the device. {!Tool_call} exchanges typed wire values over the
    {!Wire.t} seam; only {!Io} (and the device itself) sees their byte encoding. *)

module Wire : sig
  (** Device status of a RESPONSE. The wire byte is an encoding detail private to
      {!Io} — upper layers match on constructors. [Other] carries status bytes
      this build doesn't know (newer device), kept for diagnostics. *)
  type status =
    | Ok
    | Not_found
    | Trapped
    | Error
    | No_match (** EDIT: OLD does not occur in the file. *)
    | Not_unique (** EDIT: OLD occurs more than once; payload = count (u32 LE). *)
    | Other of int

  (** The status <-> wire-byte (u8) mapping — {!Io}'s decoder, error messages,
      and tests that speak raw frames. *)

  val status_byte : status -> int
  val status_of_byte : int -> status

  (** A REQUEST — host is master: one REQUEST out, one RESPONSE back. *)
  type request =
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

  type response =
    { status : status
    ; payload : string
    }

  (** The occurrence count carried by a [Not_unique] response (u32 LE payload);
      0 when the payload is absent or short. Kept beside the type so the payload
      encoding never leaves this module. *)
  val not_unique_count : response -> int

  (** Longest OLD fragment (in device bytes, after LF -> CR conversion) that an
      EDIT request may carry — the device matches inside a fixed buffer. Keep in
      sync with [editLim] in [oat/Mod/Common/AgentProtocol.Mod].
      {!Tool_call}'s edit falls back to the GET+PUT path for anything longer. *)
  val edit_old_limit : int

  (** The wire itself: one REQUEST in, one RESPONSE back. [Io.send device] is
      the production implementation; the tool_call tests plug in an in-memory
      fake device. The seam between {!Tool_call} and {!Io}. *)
  type t = request -> response
end

(** One constructor per subcommand. [Write] is parsed with [content = ""] —
    {!Cli.run} fills it from stdin just before executing, so the parser stays
    pure. *)
type request =
  | Check
  | Read of string
  | Write of
      { path : string
      ; content : string
      }
  | Edit of
      { path : string
      ; old : string
      ; new_ : string
      }
  | Delete of string
  | List_files of string (** Name prefix; "" lists all files. *)
  | List_modules
  | Compile of
      { name : string
      ; new_symbol : bool
      }
  | Load of string
  | Unload of string
  | Call of
      { cmd : string
      ; args : string (** Parameter text scanned via Oberon.Par; "" for none. *)
      }

(** The typed result of each request — one constructor per request above, named
    as its past tense (so [Read] appears in both types; use sites disambiguate
    by expected type) — self-contained for {!Cli.render}. Failures raise
    {!Error.Error} — except in the two log-carrying cases ([Compiled],
    [Called]), which report failure in-band so the log can be printed before
    the process fails. *)
type response =
  | Checked of
      { version : string (** "" when the image lacks the System.Version patch. *)
      ; rtt_ms : int
      }
  | Read of string
  | Written of
      { path : string
      ; bytes : int
      }
  | Edited of { path : string }
  | Deleted of { path : string }
  | Listed_files of string (** TSV: name, size, date. *)
  | Listed_modules of string (** TSV: name, refcnt, code address. *)
  | Compiled of
      { output : string
      ; failed : bool
      }
  | Loaded of string
  | Unloaded of
      { name : string
      ; log : string
      }
  | Called of
      { log : string
      ; failure : Error.t option
      }
