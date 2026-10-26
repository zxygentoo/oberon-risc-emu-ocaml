(** Shared harness for the hand-rolled test executables: counting asserts (a failing
    check prints FAIL and the run exits 1 at {!summary}, never masking later checks),
    plus scratch-file helpers. *)

let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let eq name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got %d, want %d\n" name got want)
;;

let eqx name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got 0x%08X, want 0x%08X\n" name got want)
;;

let eqx64 name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got 0x%016Lx, want 0x%016Lx\n" name got want)
;;

let eqs name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got %S, want %S\n" name got want)
;;

let summary label =
  if !failures = 0
  then Printf.printf "ok: %d %s passed\n" !total label
  else (
    Printf.printf "FAILED: %d/%d %s failed\n" !failures !total label;
    exit 1)
;;

(* ---- Scratch files --------------------------------------------------------- *)

let write_file path s = Out_channel.with_open_bin path (fun oc -> output_string oc s)
let read_file path = In_channel.with_open_bin path In_channel.input_all

(* lstat: a symlink is removed itself, never descended into. *)
let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun n -> rm_rf (Filename.concat path n)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_scratch ~prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;

let contains ~sub s =
  let n = String.length sub in
  let rec go i = i + n <= String.length s && (String.sub s i n = sub || go (i + 1)) in
  go 0
;;

let run_exe ~cwd exe args =
  let out = Filename.concat cwd "stdout"
  and err = Filename.concat cwd "stderr" in
  let fd path = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let o = fd out
  and e = fd err in
  let pid = Unix.create_process exe (Array.of_list (exe :: args)) Unix.stdin o e in
  Unix.close o;
  Unix.close e;
  let code =
    match Unix.waitpid [] pid with
    | _, Unix.WEXITED c -> c
    | _ -> -1
  in
  code, read_file out, read_file err
;;
