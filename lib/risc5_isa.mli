(** The single definition of the RISC5 instruction encoding: one [instr] ADT,
    one [encode]/[decode], and the inlinable field accessors underneath both.

    Stock OCaml, zero dependencies. Shared (in the DOOM arc) by the compiler
    backend, the instr-level linker, the core tests, and — here — the emulator's
    own decode. See SEAM.md §6 for the design companion.

    Two layers, one truth:

    - accessors (Layer 1): [word -> int/bool], allocation-free, [@inline] in the
      [.ml]. The emulator's hot loop ({!Risc.single_step}) and [decode] are both
      built on these; they {e are} the bit-layout truth.
    - ADT + codec (Layer 2): the faithful, encodable instruction, for the
      compiler, disassembler, and tests. Never materialized in the emulator loop
      (that is what keeps the loop non-allocating).

    Encoding (Wirth RISC5), field-for-field against {!Risc.single_step}:
    {v
      p = bit 31   q = bit 30   u = bit 29   v = bit 28
      ra = 27..24  rb = 23..20  op = 19..16  rc = 3..0   imm16 = 15..0

      register : p=0        q=0 register operand R[c] / q=1 immediate (F1)
      memory   : p=1 q=0    off = 19..0 (signed); u = load/store, v = word/byte
      branch   : p=1 q=1    neg = 27, cond = 26..24, link = v;
                            u=0 register target R[c], u=1 PC-relative off 23..0
    v}

    Invariants (property-tested):
    - [decode (encode i) = i] for every constructible [i] whose offset/immediate
      fields are in range;
    - [encode (decode w) = w] for canonical [w] (don't-care bits zero — a
      register-target branch ignores bits 23..4, exactly as the hardware does). *)

type word = int
(* An unsigned 32-bit value held in an OCaml [int]. Requires a 64-bit host
   ([Sys.int_size > 32], asserted at module load); the emulator's {!U32}
   convention. *)

type reg = int (* 0..15 *)

(* The 4-bit [op] field (19..16), in opcode order. Nullary ⇒ immediate ⇒
   zero-allocation. *)
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

val int_of_op : op -> int
val op_of_int : int -> op (* total: all 16 values map *)

(* The 3-bit branch condition (26..24), under its ISA mnemonic. *)
type cond =
  | Mi (* N        — negative *)
  | Eq (* Z        — zero *)
  | Cs (* C        — carry set *)
  | Vs (* V        — overflow *)
  | Ls (* C|Z      — lower or same *)
  | Lt (* N<>V     — less than *)
  | Le (* (N<>V)|Z — less or equal *)
  | True (* always *)

val int_of_cond : cond -> int
val cond_of_int : int -> cond (* total: all 8 values map *)

(** {2 Layer 1: accessors — the emulator's fast path}

    All [@inline] in the [.ml], no allocation. These are the bit-layout truth;
    everything else builds on them. *)

type kind =
  | Register
  | Memory
  | Branch

val kind : word -> kind (* p, then q *)
val p : word -> bool (* bit 31 *)
val q : word -> bool (* bit 30 *)
val u : word -> bool (* bit 29 *)
val v : word -> bool (* bit 28 *)
val ra : word -> reg (* 27..24 : dest (register/memory); unused by branch *)
val rb : word -> reg (* 23..20 : source / memory base *)
val rc : word -> reg (* 3..0 : 2nd source / branch register target *)
val op_of_word : word -> op (* 19..16 *)
val imm16 : word -> int (* 15..0, zero-extended (raw field) *)
val imm_value : word -> int (* 15..0, one-extended iff v — the F1 operand *)
val off20 : word -> int (* 19..0, sign-extended (memory offset) *)
val off24 : word -> int (* 23..0, sign-extended (branch word offset) *)
val cond_of_word : word -> cond (* 26..24 *)
val cond_neg : word -> bool (* bit 27 : negate the condition *)

(** {2 Layer 2: the faithful, concrete ADT — legal states only}

    The operand/size/target constructors {e imply} the q/u/v bits, so an illegal
    encoding cannot be built; offsets are resolved ints (labels live above this
    module, in the DOOM-repo linker). *)

type operand =
  | Reg of reg (* q = 0 : register operand R[c] *)
  | Imm of int (* q = 1 : raw 16-bit field; sign-extension is a v/exec concern *)

type size =
  | W (* v = 0 : word *)
  | B (* v = 1 : byte *)

type target =
  | To_reg of reg (* u = 0 : R[c] holds a byte address *)
  | To_off of int (* u = 1 : 24-bit signed offset in words, PC-relative *)

type instr =
  | Alu of
      { op : op
      ; u : bool (* op-specific: carry (Add/Sub), unsigned (Mul/Div), high/flags (Mov) *)
      ; v : bool (* F1: sign-extend the immediate; Mov F0: flags vs H select *)
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
    (* u = 0 *)
  | Store of
      { size : size
      ; a : reg
      ; base : reg
      ; off : int
      }
    (* u = 1 *)
  | Branch of
      { cond : cond
      ; neg : bool
      ; link : bool
      ; target : target
      }

val encode : instr -> word
val decode : word -> instr
