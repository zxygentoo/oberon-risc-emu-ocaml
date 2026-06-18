(** Software floating-point and integer division (port of [risc-fp.c] / [fp.rs]).

    Bit-exact software models of the RISC5 FPGA arithmetic units. Every operation
    is ported verbatim from the C/Rust: unsigned wraparound becomes {!U32.wrap},
    C's arithmetic right shift becomes [(to_i32 x) asr n], and the C idiom
    [n > 31 ? sign : x >> n] guards against an out-of-range shift.

    There is no separate FLT/FLOOR opcode: they are FAD (op 12) with modifier
    bits, so [fp_add]'s [u] selects FLT (integer -> float) and [v] selects FLOOR
    (float -> integer); plain FAD passes [u = v = false]. FSB is FAD with operand
    2's sign flipped by the caller. *)

(** Result of an integer division: quotient and remainder (mirrors the C
    [struct idiv]). *)
type idiv_result =
  { quot : int
  ; rem : int
  }

(** Floating-point add (FAD/FSB/FLT/FLOOR). [u] = FLT, [v] = FLOOR.
    Port of [fp_add] ([risc-fp.c:3]). *)
let fp_add x y u v =
  (* Unpack x into sign, biased exponent, and a signed-magnitude mantissa. The
     25-bit mantissa carries the hidden leading 1 (bit 24) and a low guard bit
     (the [lsl 1]). For FLT (u) x is instead a 24-bit signed integer at the fixed
     exponent 150 (= 127 + 23), so its value sits in the mantissa field. *)
  let x_sign = x land 0x8000_0000 <> 0 in
  let x_exp, x_signed =
    if not u
    then (
      let x_mant = ((x land 0x7F_FFFF) lsl 1) lor 0x100_0000 in
      (x lsr 23) land 0xFF, if x_sign then -x_mant else x_mant)
    else 150, U32.to_i32 (U32.wrap ((x land 0x00FF_FFFF) lsl 8)) asr 7
  in
  (* Unpack y the same way; the hidden bit is suppressed for FLT/FLOOR, where y
     carries no float mantissa. *)
  let y_sign = y land 0x8000_0000 <> 0 in
  let y_exp = (y lsr 23) land 0xFF in
  let y_mant =
    let m = (y land 0x7F_FFFF) lsl 1 in
    if (not u) && not v then m lor 0x100_0000 else m
  in
  let y_signed = if y_sign then -y_mant else y_mant in
  (* Align to the larger exponent by arithmetic-right-shifting the smaller
     operand's mantissa (sign-preserving). Shifts of 32+ clamp to a full sign
     fill (the C's [n > 31 ? sign : x >> n]). *)
  let exp, x_aligned, y_aligned =
    if y_exp > x_exp
    then (
      let shift = y_exp - x_exp in
      y_exp, (if shift > 31 then x_signed asr 31 else x_signed asr shift), y_signed)
    else (
      let shift = x_exp - y_exp in
      x_exp, x_signed, if shift > 31 then y_signed asr 31 else y_signed asr shift)
  in
  (* Add the aligned mantissas in a 27-bit field, each sign-extended into the two
     guard bits (26, 25) so a carry out of bit 24 keeps its sign. *)
  let xs = Bool.to_int x_sign
  and ys = Bool.to_int y_sign in
  let opx = (xs lsl 26) lor (xs lsl 25) lor (x_aligned land 0x01FF_FFFF) in
  let opy = (ys lsl 26) lor (ys lsl 25) lor (y_aligned land 0x01FF_FFFF) in
  let sum = U32.wrap (opx + opy) in
  (* Magnitude of the signed sum, plus 1 as the rounding bias. *)
  let mag =
    let m = if sum land (1 lsl 26) <> 0 then U32.neg sum else sum in
    U32.wrap (m + 1) land 0x07FF_FFFF
  in
  (* Post-normalize: shift the mantissa left until its leading 1 reaches bit 24,
     decrementing the exponent each step. A sum with nothing above the guard
     region takes the hardware's fixed 24-place shift instead. *)
  let out_mant, out_exp =
    let m = mag lsr 1
    and e = U32.wrap (exp + 1) in
    if mag land 0x3FF_FFFC <> 0
    then (
      let rec normalize m e =
        if m land (1 lsl 24) = 0
        then normalize (U32.wrap (m lsl 1)) (U32.wrap (e - 1))
        else m, e
      in
      normalize m e)
    else U32.wrap (m lsl 24), U32.wrap (e - 24)
  in
  let x_is_zero = x land 0x7FFF_FFFF = 0 in
  let y_is_zero = y land 0x7FFF_FFFF = 0 in
  if v
  then
    (* FLOOR: reinterpret the raw sum as the signed integer result. *)
    U32.wrap (U32.to_i32 (U32.wrap (sum lsl 5)) asr 6)
  else if x_is_zero
  then
    (* x == 0: result is y, but FLT(0) and 0 + 0 give +0. *)
    if u || y_is_zero then 0 else y
  else if y_is_zero
  then x
  else if out_mant land 0x01FF_FFFF = 0 || out_exp land 0x100 <> 0
  then
    (* Mantissa cancelled to zero, or the exponent ran out of range. *)
    0
  else
    (* Reassemble: sign (from the sum's guard bit), exponent, 23-bit mantissa. *)
    U32.wrap
      (((sum land 0x0400_0000) lsl 5)
       lor (out_exp lsl 23)
       lor ((out_mant lsr 1) land 0x7F_FFFF))
;;

(** Floating-point multiply (FML). Port of [fp_mul] ([risc-fp.c:69]). *)
let fp_mul x y =
  let sign = x lxor y land 0x8000_0000 in
  let xe = (x lsr 23) land 0xFF in
  let ye = (y lsr 23) land 0xFF in
  (* 24-bit mantissas with the hidden leading 1; their product is up to 48 bits
     (fits in a 63-bit native int). *)
  let xm = x land 0x7F_FFFF lor 0x80_0000 in
  let ym = y land 0x7F_FFFF lor 0x80_0000 in
  let m = xm * ym in
  (* Add the exponents (removing one bias). A product that reached bit 47 is
     >= 2.0: bump the exponent and round from bit 23, otherwise round from 22. *)
  let e1, z0 =
    let e = U32.sub (xe + ye) 127 in
    if m land (1 lsl 47) <> 0
    then U32.add e 1, ((m lsr 23) + 1) land 0xFF_FFFF
    else e, ((m lsr 22) + 1) land 0xFF_FFFF
  in
  (* Zero operand -> 0; in-range exponent -> assemble; overflow -> infinity;
     underflow -> 0. *)
  if xe = 0 || ye = 0
  then 0
  else if e1 land 0x100 = 0
  then U32.wrap (sign lor ((e1 land 0xFF) lsl 23) lor (z0 lsr 1))
  else if e1 land 0x80 = 0
  then U32.wrap (sign lor (0xFF lsl 23) lor (z0 lsr 1))
  else 0
;;

(** Floating-point divide (FDV). Port of [fp_div] ([risc-fp.c:98]). *)
let fp_div x y =
  let sign = x lxor y land 0x8000_0000 in
  let xe = (x lsr 23) land 0xFF in
  let ye = (y lsr 23) land 0xFF in
  (* Divide the 24-bit mantissas, pre-scaling the dividend by 2^25 for precision
     ([xm lsl 25] is up to 49 bits, within a 63-bit native int). *)
  let xm = x land 0x7F_FFFF lor 0x80_0000 in
  let ym = y land 0x7F_FFFF lor 0x80_0000 in
  let q1 = (xm lsl 25) / ym in
  (* Subtract the exponents (re-adding the bias). A quotient that reached bit 25
     needs the exponent bumped and a bit dropped; q3 is the rounded mantissa. *)
  let e1, q2 =
    let e = U32.add (U32.sub xe ye) 126 in
    if q1 land (1 lsl 25) <> 0
    then U32.add e 1, (q1 lsr 1) land 0xFF_FFFF
    else e, q1 land 0xFF_FFFF
  in
  let q3 = U32.add q2 1 in
  (* x == 0 -> 0; y == 0 -> infinity; in range -> assemble (rounded q3);
     overflow -> infinity (unrounded q2); underflow -> 0. *)
  if xe = 0
  then 0
  else if ye = 0
  then U32.wrap (sign lor (0xFF lsl 23))
  else if e1 land 0x100 = 0
  then U32.wrap (sign lor ((e1 land 0xFF) lsl 23) lor (q3 lsr 1))
  else if e1 land 0x80 = 0
  then U32.wrap (sign lor (0xFF lsl 23) lor (q2 lsr 1))
  else 0
;;

(** 32-iteration restoring integer division on a 64-bit RQ register, with the
    signed fixup. Port of [idiv] ([risc-fp.c:130], modelling [Divider.v]). *)
let idiv x y signed_div =
  (* The RQ register is 64-bit; bind the bitwise operators to their Int64 forms
     for this scope so the shift/mask chains read like ordinary bit code (the
     names keep their usual high precedence, as Core's [Int64.O] does). *)
  let ( lsl ) = Int64.shift_left
  and ( lsr ) = Int64.shift_right_logical
  and ( land ) = Int64.logand
  and ( lor ) = Int64.logor in
  let sign = U32.to_i32 x < 0 && signed_div in
  let x0 = if sign then U32.neg x else x in
  (* One restoring-division step on the 64-bit RQ register. *)
  let step rq =
    let w0 = Int64.to_int ((rq lsr 31) land U32.mask64) in
    let w1 = U32.sub w0 y in
    let low = (rq land 0x7FFF_FFFFL) lsl 1 in
    if U32.to_i32 w1 < 0
    then (Int64.of_int w0 lsl 32) lor low
    else (Int64.of_int w1 lsl 32) lor low lor 1L
  in
  let rec divide n rq = if n = 0 then rq else divide (n - 1) (step rq) in
  let rq = divide 32 (Int64.of_int x0) in
  let quot = Int64.to_int (rq land U32.mask64) in
  let rem = Int64.to_int ((rq lsr 32) land U32.mask64) in
  (* Signed fixup: make the remainder share the dividend's sign. *)
  if not sign
  then { quot; rem }
  else (
    let quot = U32.neg quot in
    if rem = 0 then { quot; rem } else { quot = U32.sub quot 1; rem = U32.sub y rem })
;;
