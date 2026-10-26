(** The 512-word boot ROM (port of [risc-boot.inc]). *)

(** The 512-word PROM image (383 real words zero-filled to 512) — a fresh copy on every
    call, so nothing a caller does to it reaches any machine's ROM. *)
val bootloader : unit -> int array
