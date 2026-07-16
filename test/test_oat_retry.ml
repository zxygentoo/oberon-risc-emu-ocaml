(* Retry-policy tests, ported from oat's retry.rs unit tests: only transport desyncs
   (Timeout, Bad_sync) are re-sent, within the attempt budget; everything else fails
   fast. The flaky fake counts calls so each test can assert the budget spent. *)

open Oat
open Test_harness

(* A send that fails (with a chosen error) its first [fail_then] calls, then
   succeeds; returns the call counter alongside. *)
let flaky fail_then err =
  let calls = ref 0 in
  let send _frame =
    incr calls;
    if !calls <= fail_then
    then Error.fail (err ())
    else { Protocol.status = Protocol.Ok; payload = "" }
  in
  send, calls
;;

let timeout () = Error.Timeout { secs = 1.0; got = 0; want = 1 }
let bad_sync () = Error.Bad_sync { got = 0; expected = 0x5A }

let expect_raise name pred f =
  match f () with
  | _ -> check name false
  | exception Error.Error e -> check name (pred e)
;;

let () =
  let send, calls = flaky 0 timeout in
  check "first_try_ok" (Protocol.ok (Retry.wrap ~retries:2 send "x"));
  eq "first_try_one_call" !calls 1;
  (* Two timeouts then success; 2 retries (3 attempts) covers it. *)
  let send, calls = flaky 2 timeout in
  check "recovers_within_budget" (Protocol.ok (Retry.wrap ~retries:2 send "x"));
  eq "recovers_three_calls" !calls 3;
  let send, calls = flaky 1 bad_sync in
  check "bad_sync_retried" (Protocol.ok (Retry.wrap ~retries:2 send "x"));
  eq "bad_sync_two_calls" !calls 2;
  (* Three failures but only 2 retries — the 3rd attempt also fails, so the error
     propagates after exactly 3 calls. *)
  let send, calls = flaky 3 timeout in
  expect_raise
    "gives_up_after_budget"
    (function
      | Error.Timeout _ -> true
      | _ -> false)
    (fun () -> Retry.wrap ~retries:2 send "x");
  eq "gives_up_three_calls" !calls 3;
  let send, calls = flaky 1 timeout in
  expect_raise
    "zero_retries_single_attempt"
    (function
      | Error.Timeout _ -> true
      | _ -> false)
    (fun () -> Retry.wrap ~retries:0 send "x");
  eq "zero_retries_one_call" !calls 1;
  (* Eof is a genuine line failure, not a desync — no retry. *)
  let send, calls = flaky 5 (fun () -> Error.Eof) in
  expect_raise
    "eof_fails_fast"
    (function
      | Error.Eof -> true
      | _ -> false)
    (fun () -> Retry.wrap ~retries:3 send "x");
  eq "eof_one_call" !calls 1;
  summary "oat retry checks"
;;
