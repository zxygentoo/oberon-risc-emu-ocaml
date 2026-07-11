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

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun n -> rm_rf (Filename.concat path n)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path
;;

(* pid keeps parallel dune runs apart; the counter keeps one process's dirs apart. *)
let scratch_counter = ref 0

let with_scratch ~prefix f =
  incr scratch_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s%d-%d" prefix (Unix.getpid ()) !scratch_counter)
  in
  rm_rf dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)
;;
