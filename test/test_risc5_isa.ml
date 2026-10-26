(* Property + differential tests for the shared {!Risc5_isa} instruction codec.

   Layer 1 (the accessors) is already proven by the whole suite: {!Risc.Cpu.single_step}
   now decodes through [p]/[q]/[ra]/[op_of_word]/… so every instruction, cosim, and
   boot-golden check *is* an accessor check. These tests cover Layer 2 — [encode] /
   [decode], which the emulator's hot loop does NOT use — via:

   - the codec round-trip [decode (encode i) = i] and its canonical converse;
   - a *differential* check of [encode] against the hand-rolled encoders that
     test_risc / test_prop already trust (so the ADT is tied to the golden bit
     patterns, not just to itself);
   - that [decode]'s fields agree field-for-field with the individual accessors;
   - that [encode] rejects a field outside its bits instead of masking it into a
     different instruction, and accepts every boundary value. *)

open Oberon_risc
open Risc5_isa
module Q = QCheck2
module G = QCheck2.Gen

let reg = G.int_range 0 15
let g_bool = G.bool

let g_op =
  G.oneof_list
    [ Mov; Lsl; Asr; Ror; And; Ann; Ior; Xor; Add; Sub; Mul; Div; Fad; Fsb; Fml; Fdv ]
;;

let g_cond = G.oneof_list [ Mi; Eq; Cs; Vs; Ls; Lt; Le; True ]
let g_size = G.oneof_list [ W; B ]

let g_operand =
  G.oneof [ G.map (fun r -> Reg r) reg; G.map (fun i -> Imm i) (G.int_range 0 0xFFFF) ]
;;

(* Offsets confined to their signed field width, where the round-trip holds. *)
let g_off20 = G.int_range (-0x0008_0000) 0x0007_FFFF
let g_off24 = G.int_range (-0x0080_0000) 0x007F_FFFF

let g_target =
  G.oneof [ G.map (fun r -> To_reg r) reg; G.map (fun o -> To_off o) g_off24 ]
;;

let g_instr =
  G.oneof
    [ G.map
        (fun (op, (u, v), (a, b), operand) -> Alu { op; u; v; a; b; operand })
        (G.tup4 g_op (G.pair g_bool g_bool) (G.pair reg reg) g_operand)
    ; G.map
        (fun (size, (a, base), off) -> Load { size; a; base; off })
        (G.triple g_size (G.pair reg reg) g_off20)
    ; G.map
        (fun (size, (a, base), off) -> Store { size; a; base; off })
        (G.triple g_size (G.pair reg reg) g_off20)
    ; G.map
        (fun ((cond, neg), (link, target)) -> Branch { cond; neg; link; target })
        (G.pair (G.pair g_cond g_bool) (G.pair g_bool g_target))
    ]
;;

let u32 = G.int_range 0 0xFFFF_FFFF
let bit b = if b then 1 else 0

(* A value just past either end of [lo..hi], or far beyond. *)
let g_outside lo hi =
  G.oneof
    [ G.int_range (lo - 0x1000_0000) (lo - 1); G.int_range (hi + 1) (hi + 0x1000_0000) ]
;;

(* Instructions with exactly one field out of range. *)
let g_bad_instr =
  let bad_reg = g_outside 0 15
  and bad_off20 = g_outside (-0x0008_0000) 0x0007_FFFF
  and alu ?(op = Add) ?(a = 0) ?(b = 0) operand =
    Alu { op; u = false; v = false; a; b; operand }
  and br target = Branch { cond = True; neg = false; link = false; target } in
  G.oneof
    [ G.map (fun a -> alu ~a (Reg 0)) bad_reg
    ; G.map (fun b -> alu ~b (Reg 0)) bad_reg
    ; G.map (fun c -> alu (Reg c)) bad_reg
    ; G.map (fun i -> alu ~op:Mov (Imm i)) (g_outside 0 0xFFFF)
    ; G.map (fun a -> Load { size = W; a; base = 0; off = 0 }) bad_reg
    ; G.map (fun base -> Store { size = B; a = 0; base; off = 0 }) bad_reg
    ; G.map (fun off -> Load { size = B; a = 0; base = 0; off }) bad_off20
    ; G.map (fun off -> Store { size = W; a = 0; base = 0; off }) bad_off20
    ; G.map (fun c -> br (To_reg c)) bad_reg
    ; G.map (fun o -> br (To_off o)) (g_outside (-0x0080_0000) 0x007F_FFFF)
    ]
;;

(* Building an instruction under a local open with punned fields: this used to fail to
   compile, the accessors [u]/[v] capturing the puns. Compiling is the test; the
   property below checks the word. *)
let punned ~u ~v = Risc5_isa.(Alu { op = Add; u; v; a = 1; b = 2; operand = Reg 3 })

(* Every field at both ends of its range. *)
let boundary_instrs =
  let alu a b operand = Alu { op = Ior; u = true; v = true; a; b; operand } in
  [ alu 0 0 (Reg 0)
  ; alu 15 15 (Reg 15)
  ; alu 0 0 (Imm 0)
  ; alu 15 15 (Imm 0xFFFF)
  ; Load { size = W; a = 15; base = 15; off = -0x0008_0000 }
  ; Store { size = B; a = 0; base = 0; off = 0x0007_FFFF }
  ; Branch { cond = Le; neg = true; link = true; target = To_reg 15 }
  ; Branch { cond = Mi; neg = false; link = false; target = To_off (-0x0080_0000) }
  ; Branch { cond = True; neg = false; link = true; target = To_off 0x007F_FFFF }
  ]
;;

(* Hand-rolled encoders — verbatim from test_risc.ml / test_prop.ml (the ones the
   golden tests already trust). [encode] must reproduce them bit-for-bit. *)
let e_reg q u v a b op ci =
  (q lsl 30)
  lor (u lsl 29)
  lor (v lsl 28)
  lor (a lsl 24)
  lor (b lsl 20)
  lor (op lsl 16)
  lor ci
;;

let e_mem u v a b off =
  0x8000_0000
  lor (u lsl 29)
  lor (v lsl 28)
  lor (a lsl 24)
  lor (b lsl 20)
  lor (off land 0x000F_FFFF)
;;

let e_br_imm negate cond link off =
  0xE000_0000
  lor (link lsl 28)
  lor (negate lsl 27)
  lor (cond lsl 24)
  lor (off land 0x00FF_FFFF)
;;

let e_br_reg negate cond link c =
  0xC000_0000 lor (link lsl 28) lor (negate lsl 27) lor (cond lsl 24) lor (c land 0xF)
;;

let tests =
  [ Q.Test.make ~name:"codec: decode (encode i) = i" ~count:5000 g_instr (fun i ->
      decode (encode i) = i)
  ; (* For any 32-bit word, decoding is stable through a re-encode: this is the
       canonical [encode (decode w) = w] modulo the don't-care bits a
       register-target branch ignores (bits 23..4), exactly as the hardware does. *)
    Q.Test.make
      ~name:"codec: decode (encode (decode w)) = decode w"
      ~count:5000
      u32
      (fun w -> decode (encode (decode w)) = decode w)
  ; Q.Test.make ~name:"enum: op_of_int (int_of_op op) = op" ~count:16 g_op (fun op ->
      op_of_int (int_of_op op) = op)
  ; Q.Test.make ~name:"enum: cond_of_int (int_of_cond c) = c" ~count:8 g_cond (fun c ->
      cond_of_int (int_of_cond c) = c)
  ; Q.Test.make
      ~name:"differential: encode Alu = hand-rolled reg encoder"
      ~count:3000
      (G.tup4 (G.pair g_bool g_bool) (G.pair reg reg) g_op g_operand)
      (fun ((u, v), (a, b), op, operand) ->
         let q, ci =
           match operand with
           | Reg c -> 0, c
           | Imm i -> 1, i land 0xFFFF
         in
         encode (Alu { op; u; v; a; b; operand })
         = e_reg q (bit u) (bit v) a b (int_of_op op) ci)
  ; Q.Test.make
      ~name:"differential: encode Load/Store = hand-rolled mem encoder"
      ~count:3000
      (G.tup4 g_size (G.pair reg reg) g_off20 g_bool)
      (fun (size, (a, base), off, is_store) ->
         let v =
           match size with
           | W -> 0
           | B -> 1
         in
         if is_store
         then encode (Store { size; a; base; off }) = e_mem 1 v a base off
         else encode (Load { size; a; base; off }) = e_mem 0 v a base off)
  ; Q.Test.make
      ~name:"differential: encode Branch = hand-rolled branch encoders"
      ~count:3000
      (G.pair (G.pair g_cond g_bool) (G.pair g_bool g_target))
      (fun ((cond, neg), (link, target)) ->
         let w = encode (Branch { cond; neg; link; target }) in
         match target with
         | To_reg c -> w = e_br_reg (bit neg) (int_of_cond cond) (bit link) c
         | To_off off -> w = e_br_imm (bit neg) (int_of_cond cond) (bit link) off)
  ; (* [decode]'s fields are exactly what the individual accessors read. *)
    Q.Test.make ~name:"decode fields agree with the accessors" ~count:5000 u32 (fun w ->
      let open Word in
      match decode w with
      | Alu { op; u = uu; v = vv; a; b = bb; operand } ->
        kind w = Register
        && a = ra w
        && bb = rb w
        && op = op_of_word w
        && uu = u w
        && vv = v w
        &&
          (match operand with
          | Reg c -> (not (q w)) && c = rc w
          | Imm i -> q w && i = imm16 w)
      | Load { size; a; base; off } ->
        kind w = Memory
        && (not (u w))
        && a = ra w
        && base = rb w
        && off = off20 w
        &&
          (match size with
          | W -> not (v w)
          | B -> v w)
      | Store { size; a; base; off } ->
        kind w = Memory
        && u w
        && a = ra w
        && base = rb w
        && off = off20 w
        &&
          (match size with
          | W -> not (v w)
          | B -> v w)
      | Branch { cond; neg; link; target } ->
        kind w = Branch
        && cond = cond_of_word w
        && neg = cond_neg w
        && link = v w
        &&
          (match target with
          | To_reg c -> (not (u w)) && c = rc w
          | To_off o -> u w && o = off24 w))
  ; Q.Test.make
      ~name:"encode rejects a field outside its bits"
      ~count:3000
      g_bad_instr
      (fun i ->
         match encode i with
         | _ -> false
         | exception Invalid_argument _ -> true)
  ; Q.Test.make ~name:"punned local open builds the right word" ~count:1 G.unit (fun () ->
      encode (punned ~u:true ~v:false) = e_reg 0 1 0 1 2 8 3)
  ; Q.Test.make
      ~name:"op_of_int / cond_of_int reject out-of-range"
      ~count:1
      G.unit
      (fun () ->
         let raises f =
           match f () with
           | _ -> false
           | exception Invalid_argument _ -> true
         in
         raises (fun () -> op_of_int 16)
         && raises (fun () -> op_of_int (-1))
         && raises (fun () -> cond_of_int 8)
         && op_of_int 15 = Fdv
         && cond_of_int 7 = True)
  ; Q.Test.make ~name:"encode accepts every boundary value" ~count:1 G.unit (fun () ->
      List.for_all (fun i -> decode (encode i) = i) boundary_instrs)
  ]
;;

let () = QCheck_base_runner.run_tests_main tests
