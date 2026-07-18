(** The two oat vocabularies (see data.mli). Pure data: the only code here is the
    status <-> byte mapping and the Not_unique payload decode, kept beside the
    types so their encodings never leak past {!Io}. *)

module Wire = struct
  type status =
    | Ok
    | Not_found
    | Trapped
    | Error
    | No_match
    | Not_unique
    | Other of int

  (* Constants match AgentProtocol.Mod. *)
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

  let ok r = r.status = Ok

  (* u32 LE at [pos] as a non-negative int (the land masks Int32's sign extension). *)
  let u32 s pos = Int32.to_int (String.get_int32_le s pos) land 0xFFFFFFFF
  let not_unique_count r = if String.length r.payload < 4 then 0 else u32 r.payload 0
  let edit_old_limit = 1024

  type t = request -> response
end

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
  | List_files of string
  | List_modules
  | Compile of
      { name : string
      ; new_symbol : bool
      }
  | Load of string
  | Unload of string
  | Call of
      { cmd : string
      ; args : string
      }

type response =
  | Checked of
      { version : string
      ; rtt_ms : int
      }
  | File_read of string
  | File_written of
      { path : string
      ; bytes : int
      }
  | File_edited of { path : string }
  | File_deleted of { path : string }
  | Files_listed of string
  | Modules_listed of string
  | Compiled of
      { output : string
      ; failed : bool
      }
  | Module_loaded of string
  | Module_unloaded of
      { name : string
      ; log : string
      }
  | Called of
      { log : string
      ; failure : Error.t option
      }
