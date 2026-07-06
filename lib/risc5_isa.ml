(* The single definition of the RISC5 instruction encoding. See risc5_isa.mli
   for the layout, the two-layer design, and the invariants. Stock OCaml, zero
   dependencies; the accessors are [@inline] and allocation-free so the
   emulator's hot loop stays non-allocating. *)

(* Words are unsigned 32-bit values held in a native [int]; that needs a 64-bit
   host (0xFFFF_FFFF must stay non-negative). Fail loud on a 32-bit build. *)
let () = assert (Sys.int_size > 32)

type word = int
type reg = int

(* Instruction-class selector bits (top nibble). *)
let pbit = 0x8000_0000
let qbit = 0x4000_0000
let ubit = 0x2000_0000
let vbit = 0x1000_0000

type op =
  | Mov
  | Lsl
  | Asr
  | Ror
  | And
  | Ann
  | Ior
  | Xor
  | Add
  | Sub
  | Mul
  | Div
  | Fad
  | Fsb
  | Fml
  | Fdv

let int_of_op = function
  | Mov -> 0
  | Lsl -> 1
  | Asr -> 2
  | Ror -> 3
  | And -> 4
  | Ann -> 5
  | Ior -> 6
  | Xor -> 7
  | Add -> 8
  | Sub -> 9
  | Mul -> 10
  | Div -> 11
  | Fad -> 12
  | Fsb -> 13
  | Fml -> 14
  | Fdv -> 15
;;

(* Decode the 4-bit opcode field; all 16 values map. *)
let op_of_int = function
  | 0 -> Mov
  | 1 -> Lsl
  | 2 -> Asr
  | 3 -> Ror
  | 4 -> And
  | 5 -> Ann
  | 6 -> Ior
  | 7 -> Xor
  | 8 -> Add
  | 9 -> Sub
  | 10 -> Mul
  | 11 -> Div
  | 12 -> Fad
  | 13 -> Fsb
  | 14 -> Fml
  | _ -> Fdv
;;

type cond =
  | Mi
  | Eq
  | Cs
  | Vs
  | Ls
  | Lt
  | Le
  | True

let int_of_cond = function
  | Mi -> 0
  | Eq -> 1
  | Cs -> 2
  | Vs -> 3
  | Ls -> 4
  | Lt -> 5
  | Le -> 6
  | True -> 7
;;

(* Decode the 3-bit condition field; all 8 values map. *)
let cond_of_int = function
  | 0 -> Mi
  | 1 -> Eq
  | 2 -> Cs
  | 3 -> Vs
  | 4 -> Ls
  | 5 -> Lt
  | 6 -> Le
  | _ -> True
;;

(* ── Layer 1: accessors. All [@inline], allocation-free — the bit-layout truth
   the hot loop and [decode] share. ── *)

type kind =
  | Register
  | Memory
  | Branch

let[@inline] p w = w land pbit <> 0
let[@inline] q w = w land qbit <> 0
let[@inline] u w = w land ubit <> 0
let[@inline] v w = w land vbit <> 0
let[@inline] kind w = if not (p w) then Register else if not (q w) then Memory else Branch
let[@inline] ra w = (w lsr 24) land 0xF
let[@inline] rb w = (w lsr 20) land 0xF
let[@inline] rc w = w land 0xF
let[@inline] op_of_word w = op_of_int ((w lsr 16) land 0xF)
let[@inline] imm16 w = w land 0xFFFF

(* The F1 operand: one-fill the top 16 bits when v is set (Wirth RISC5's
   immediate "sign" modifier), else zero-extend. *)
let[@inline] imm_value w = if v w then 0xFFFF_0000 lor (w land 0xFFFF) else w land 0xFFFF

(* Sign-extend the 20-bit memory offset. *)
let[@inline] off20 w =
  let o = w land 0x000F_FFFF in
  (o lxor 0x0008_0000) - 0x0008_0000
;;

(* Sign-extend the 24-bit branch word offset. *)
let[@inline] off24 w =
  let o = w land 0x00FF_FFFF in
  (o lxor 0x0080_0000) - 0x0080_0000
;;

let[@inline] cond_of_word w = cond_of_int ((w lsr 24) land 7)
let[@inline] cond_neg w = (w lsr 27) land 1 <> 0

(* ── Layer 2: the faithful ADT + codec — never materialized in the hot loop. ── *)

type operand =
  | Reg of reg
  | Imm of int

type size =
  | W
  | B

type target =
  | To_reg of reg
  | To_off of int

type instr =
  | Alu of
      { op : op
      ; u : bool
      ; v : bool
      ; a : reg
      ; b : reg
      ; operand : operand
      }
  | Load of
      { size : size
      ; a : reg
      ; base : reg
      ; off : int
      }
  | Store of
      { size : size
      ; a : reg
      ; base : reg
      ; off : int
      }
  | Branch of
      { cond : cond
      ; neg : bool
      ; link : bool
      ; target : target
      }

let encode = function
  | Alu { op; u; v; a; b; operand } ->
    let w = (a lsl 24) lor (b lsl 20) lor (int_of_op op lsl 16) in
    let w = if u then w lor ubit else w in
    let w = if v then w lor vbit else w in
    (match operand with
     | Reg c -> w lor (c land 0xF)
     | Imm i -> w lor qbit lor (i land 0xFFFF))
  | Load { size; a; base; off } ->
    let w = pbit lor (a lsl 24) lor (base lsl 20) lor (off land 0x000F_FFFF) in
    if size = B then w lor vbit else w
  | Store { size; a; base; off } ->
    let w = pbit lor ubit lor (a lsl 24) lor (base lsl 20) lor (off land 0x000F_FFFF) in
    if size = B then w lor vbit else w
  | Branch { cond; neg; link; target } ->
    let w = pbit lor qbit lor (int_of_cond cond lsl 24) in
    let w = if neg then w lor (1 lsl 27) else w in
    let w = if link then w lor vbit else w in
    (match target with
     | To_reg c -> w lor (c land 0xF)
     | To_off o -> w lor ubit lor (o land 0x00FF_FFFF))
;;

let decode w =
  match kind w with
  | Register ->
    let operand = if q w then Imm (imm16 w) else Reg (rc w) in
    Alu { op = op_of_word w; u = u w; v = v w; a = ra w; b = rb w; operand }
  | Memory ->
    let size = if v w then B else W in
    let a = ra w
    and base = rb w
    and off = off20 w in
    if u w then Store { size; a; base; off } else Load { size; a; base; off }
  | Branch ->
    let target = if u w then To_off (off24 w) else To_reg (rc w) in
    Branch { cond = cond_of_word w; neg = cond_neg w; link = v w; target }
;;
