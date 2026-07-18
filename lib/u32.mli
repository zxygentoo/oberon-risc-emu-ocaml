(** Exact 32-bit unsigned arithmetic on OCaml's native [int].

    Machine words are stored as [int] in the range [0, 0xFFFF_FFFF]; these helpers
    provide the wrapping and sign-sensitive operations the CPU and FP units rely
    on. This assumes a 64-bit OCaml runtime (native [int] wide enough for the
    intermediate [0x1_0000_0000]). *)

(** [0xFFFF_FFFF]: the low-32-bit mask. *)
val mask : int

(** The 32-bit mask as an [int64], for operations with a 64-bit intermediate. *)
val mask64 : int64

(** Reduce to the low 32 bits (the C/Rust [u32] cast / wrapping result). *)
val wrap : int -> int

(** Reinterpret a [u32]-range value as a signed 32-bit integer in [-2^31, 2^31). *)
val to_i32 : int -> int

(** Wrapping 32-bit addition. *)
val add : int -> int -> int

(** Wrapping 32-bit subtraction. *)
val sub : int -> int -> int

(** Wrapping 32-bit negation. *)
val neg : int -> int

(** Logical left shift, reduced to 32 bits ([n] in [0, 31]). *)
val shl : int -> int -> int

(** Logical right shift ([n] in [0, 31]). *)
val shr : int -> int -> int

(** Arithmetic (sign-propagating) right shift, reduced to 32 bits ([n] in [0, 31]). *)
val sar : int -> int -> int

(** Rotate right by [n] in [0, 31]. *)
val ror : int -> int -> int

(** The [u32] whose bits are [x] (undoes [Int32]'s sign extension). *)
val of_int32 : int32 -> int

(** The [u32] at byte offset [pos] of [s], little-endian. *)
val get_le : string -> int -> int

(** Write [v]'s low 32 bits at byte offset [pos] of [b], little-endian. *)
val set_le : bytes -> int -> int -> unit
