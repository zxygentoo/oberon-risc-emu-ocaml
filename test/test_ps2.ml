(* SDL-scancode -> PS/2 encoding tests, ported from the Rust ps2.rs tests
   (re-keyed to SDL scancodes). Covers each emission style: normal, extended, the
   numlock hack, the keypad-`/` shift hack, and unmapped keys. *)

open Tsdl

let failures = ref 0
let total = ref 0
let bytes_to_list b = List.init (Bytes.length b) (fun i -> Char.code (Bytes.get b i))
let enc scancode make kmod = bytes_to_list (Ps2.encode ~scancode ~make ~kmod)

let eqlist name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    let show l = "[" ^ String.concat "; " (List.map (Printf.sprintf "0x%02X") l) ^ "]" in
    Printf.printf "FAIL: %s: got %s, want %s\n" name (show got) (show want))
;;

let () =
  let none = Sdl.Kmod.none in
  (* Normal key (A = 0x1C): make is the code; break prefixes 0xF0. *)
  eqlist "normal_make" (enc Sdl.Scancode.a true none) [ 0x1C ];
  eqlist "normal_break" (enc Sdl.Scancode.a false none) [ 0xF0; 0x1C ];
  (* Extended key (keypad Enter = 0x5A): prefixed 0xE0. *)
  eqlist "extended_make" (enc Sdl.Scancode.kp_enter true none) [ 0xE0; 0x5A ];
  eqlist "extended_break" (enc Sdl.Scancode.kp_enter false none) [ 0xE0; 0xF0; 0x5A ];
  (* Numlock hack (Up = 0x75): fake shift press/release around the code. *)
  eqlist "numlock_make" (enc Sdl.Scancode.up true none) [ 0xE0; 0x12; 0xE0; 0x75 ];
  eqlist
    "numlock_break"
    (enc Sdl.Scancode.up false none)
    [ 0xE0; 0xF0; 0x75; 0xE0; 0xF0; 0x12 ];
  (* Shift hack (keypad / = 0x4A): depends on held shift. *)
  eqlist "shifthack_noshift_make" (enc Sdl.Scancode.kp_divide true none) [ 0xE0; 0x4A ];
  eqlist
    "shifthack_lshift_make"
    (enc Sdl.Scancode.kp_divide true Sdl.Kmod.lshift)
    [ 0xE0; 0xF0; 0x12; 0xE0; 0x4A ];
  eqlist
    "shifthack_lshift_break"
    (enc Sdl.Scancode.kp_divide false Sdl.Kmod.lshift)
    [ 0xE0; 0xF0; 0x4A; 0xE0; 0x12 ];
  (* Unmapped key (Pause) emits nothing. *)
  eqlist "unmapped" (enc Sdl.Scancode.pause true none) [];
  if !failures = 0
  then Printf.printf "ok: %d ps2 checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d ps2 checks failed\n" !failures !total;
    exit 1)
;;
