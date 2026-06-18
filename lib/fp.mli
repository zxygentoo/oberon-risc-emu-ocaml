(** Software floating-point and integer division (port of [risc-fp.c]).

    Bit-exact software models of the RISC5 FPGA arithmetic units. There is no
    separate FLT/FLOOR opcode: they are FAD with modifier bits (see {!fp_add}). *)

(** Result of an integer division: quotient and remainder (mirrors the C
    [struct idiv]). *)
type idiv_result =
  { quot : int
  ; rem : int
  }

(** [fp_add x y u v] — floating-point add (FAD/FSB/FLT/FLOOR). [u] selects FLT
    (integer -> float), [v] selects FLOOR (float -> integer); plain FAD passes
    both [false]. FSB is FAD with operand 2's sign flipped by the caller. *)
val fp_add : int -> int -> bool -> bool -> int

(** Floating-point multiply (FML). *)
val fp_mul : int -> int -> int

(** Floating-point divide (FDV). *)
val fp_div : int -> int -> int

(** [idiv x y signed_div] — 32-step restoring integer division with the signed
    fixup (models [Divider.v]). *)
val idiv : int -> int -> bool -> idiv_result
