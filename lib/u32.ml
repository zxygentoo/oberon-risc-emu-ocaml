(** Exact 32-bit unsigned arithmetic on OCaml's native [int].

    The RISC5 is a 32-bit machine, but OCaml's native [int] is 63-bit on a
    64-bit host, so we store every machine word as an [int] in the range
    [0, 0xFFFF_FFFF] and reduce modulo 2^32 ([wrap]) wherever C/Rust would rely
    on [u32] wraparound. Signed operations go through [to_i32], which reinterprets
    the low 32 bits as a two's-complement [i32] (a small native [int], never
    boxed). This assumes a 64-bit host (native [int] >= 32 bits + sign + room for
    the intermediate [0x1_0000_0000]); it is not valid on a 32-bit OCaml runtime. *)

let mask = 0xFFFF_FFFF

(** The 32-bit mask as an [int64], for the few operations that need a genuine
    64-bit intermediate (the [MUL] product and the division RQ register). *)
let mask64 = 0xFFFF_FFFFL

(** Reduce to the low 32 bits (the C/Rust [u32] cast / wrapping result). *)
let wrap x = x land mask

(** Reinterpret a [u32]-range value as a signed 32-bit integer in [-2^31, 2^31). *)
let to_i32 x = if x >= 0x8000_0000 then x - 0x1_0000_0000 else x

(** Wrapping 32-bit add / subtract / negate. *)
let add a b = (a + b) land mask

let sub a b = (a - b) land mask
let neg a = -a land mask

(** Logical left shift, reduced to 32 bits. [n] in [0, 31]. *)
let shl a n = (a lsl n) land mask

(** Logical right shift. [a] is in [u32] range so no high bits leak in. *)
let shr a n = a lsr n

(** Arithmetic (sign-propagating) right shift, then reduced to 32 bits. *)
let sar a n = (to_i32 a asr n) land mask

(** Rotate right by [n] in [0, 31]. *)
let ror a n = if n = 0 then a else (a lsr n) lor (a lsl (32 - n)) land mask
