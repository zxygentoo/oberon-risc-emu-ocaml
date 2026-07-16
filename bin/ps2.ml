(** Translate SDL scancodes to PS/2 code-set-2 scancodes (port of [sdl-ps2.c]).

    Keyed directly by [Sdl.Scancode] — the same SDL scancodes the C reference
    uses — so every output byte and emission style is preserved verbatim,
    including the left/right-shift distinction in the keypad-`/` "shift hack". *)

open Tsdl

type ktype =
  | Normal
  | Extended
  | Numlock_hack
  | Shift_hack

(* The C's [keymap[SDL_NUM_SCANCODES]], as a scancode -> (code, type) table. *)
let keymap : (int, int * ktype) Hashtbl.t = Hashtbl.create 128

let () =
  let s =
    Sdl.Scancode.
      [ a, 0x1C, Normal
      ; b, 0x32, Normal
      ; c, 0x21, Normal
      ; d, 0x23, Normal
      ; e, 0x24, Normal
      ; f, 0x2B, Normal
      ; g, 0x34, Normal
      ; h, 0x33, Normal
      ; i, 0x43, Normal
      ; j, 0x3B, Normal
      ; k, 0x42, Normal
      ; l, 0x4B, Normal
      ; m, 0x3A, Normal
      ; n, 0x31, Normal
      ; o, 0x44, Normal
      ; p, 0x4D, Normal
      ; q, 0x15, Normal
      ; r, 0x2D, Normal
      ; s, 0x1B, Normal
      ; t, 0x2C, Normal
      ; u, 0x3C, Normal
      ; v, 0x2A, Normal
      ; w, 0x1D, Normal
      ; x, 0x22, Normal
      ; y, 0x35, Normal
      ; z, 0x1A, Normal
      ; k1, 0x16, Normal
      ; k2, 0x1E, Normal
      ; k3, 0x26, Normal
      ; k4, 0x25, Normal
      ; k5, 0x2E, Normal
      ; k6, 0x36, Normal
      ; k7, 0x3D, Normal
      ; k8, 0x3E, Normal
      ; k9, 0x46, Normal
      ; k0, 0x45, Normal
      ; return, 0x5A, Normal
      ; escape, 0x76, Normal
      ; backspace, 0x66, Normal
      ; tab, 0x0D, Normal
      ; space, 0x29, Normal
      ; minus, 0x4E, Normal
      ; equals, 0x55, Normal
      ; leftbracket, 0x54, Normal
      ; rightbracket, 0x5B, Normal
      ; backslash, 0x5D, Normal
      ; nonushash, 0x5D, Normal
      ; semicolon, 0x4C, Normal
      ; apostrophe, 0x52, Normal
      ; grave, 0x0E, Normal
      ; comma, 0x41, Normal
      ; period, 0x49, Normal
      ; slash, 0x4A, Normal
      ; f1, 0x05, Normal
      ; f2, 0x06, Normal
      ; f3, 0x04, Normal
      ; f4, 0x0C, Normal
      ; f5, 0x03, Normal
      ; f6, 0x0B, Normal
      ; f7, 0x83, Normal
      ; f8, 0x0A, Normal
      ; f9, 0x01, Normal
      ; f10, 0x09, Normal
      ; f11, 0x78, Normal
      ; f12, 0x07, Normal
      ; (* Most of the keys below are not used by Oberon. *)
        insert, 0x70, Numlock_hack
      ; home, 0x6C, Numlock_hack
      ; pageup, 0x7D, Numlock_hack
      ; delete, 0x71, Numlock_hack
      ; kend, 0x69, Numlock_hack
      ; pagedown, 0x7A, Numlock_hack
      ; right, 0x74, Numlock_hack
      ; left, 0x6B, Numlock_hack
      ; down, 0x72, Numlock_hack
      ; up, 0x75, Numlock_hack
      ; kp_divide, 0x4A, Shift_hack
      ; kp_multiply, 0x7C, Normal
      ; kp_minus, 0x7B, Normal
      ; kp_plus, 0x79, Normal
      ; kp_enter, 0x5A, Extended
      ; kp_1, 0x69, Normal
      ; kp_2, 0x72, Normal
      ; kp_3, 0x7A, Normal
      ; kp_4, 0x6B, Normal
      ; kp_5, 0x73, Normal
      ; kp_6, 0x74, Normal
      ; kp_7, 0x6C, Normal
      ; kp_8, 0x75, Normal
      ; kp_9, 0x7D, Normal
      ; kp_0, 0x70, Normal
      ; kp_period, 0x71, Normal
      ; nonusbackslash, 0x61, Normal
      ; application, 0x2F, Extended
      ; lctrl, 0x14, Normal
      ; lshift, 0x12, Normal
      ; lalt, 0x11, Normal
      ; lgui, 0x1F, Extended
      ; rctrl, 0x14, Extended
      ; rshift, 0x59, Normal
      ; ralt, 0x11, Extended
      ; rgui, 0x27, Extended
      ]
  in
  List.iter (fun (sc, code, ty) -> Hashtbl.replace keymap sc (code, ty)) s
;;

(** Encode a key make ([true]) / break ([false]) into PS/2 set-2 bytes (port of
    [ps2_encode]). [kmod] supplies the live shift state for the keypad-`/` hack.
    Returns the emitted bytes (possibly empty). *)
let encode ~scancode ~make ~kmod =
  let codes =
    match Hashtbl.find_opt keymap scancode with
    | None -> []
    | Some (code, ty) ->
      (match ty with
       | Normal -> if make then [ code ] else [ 0xF0; code ]
       | Extended -> if make then [ 0xE0; code ] else [ 0xE0; 0xF0; code ]
       | Numlock_hack ->
         (* This assumes Num Lock is always active. *)
         if make
         then [ 0xE0; 0x12; 0xE0; code ] (* fake shift press, then the key *)
         else [ 0xE0; 0xF0; code; 0xE0; 0xF0; 0x12 ] (* key break, fake shift release *)
       | Shift_hack ->
         let lshift = kmod land Sdl.Kmod.lshift <> 0 in
         let rshift = kmod land Sdl.Kmod.rshift <> 0 in
         if make
         then
           (* fake shift releases, then the key *)
           (if lshift then [ 0xE0; 0xF0; 0x12 ] else [])
           @ (if rshift then [ 0xE0; 0xF0; 0x59 ] else [])
           @ [ 0xE0; code ]
         else
           (* key break, then fake shift presses *)
           [ 0xE0; 0xF0; code ]
           @ (if rshift then [ 0xE0; 0x59 ] else [])
           @ if lshift then [ 0xE0; 0x12 ] else [])
  in
  Bytes.of_seq (Seq.map Char.chr (List.to_seq codes))
;;
