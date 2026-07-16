(** Retry decorator for the {!Protocol.send} seam (port of oat's [retry.rs]). *)

let retriable = function
  | Error.Timeout _ | Error.Bad_sync _ -> true
  | _ -> false
;;

let wrap ~retries send frame =
  let rec go attempt =
    match send frame with
    | response -> response
    | exception Error.Error e when retriable e && attempt < retries ->
      go (attempt + 1)
  in
  go 0
;;
