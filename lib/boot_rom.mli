(** The 512-word boot ROM (port of [risc-boot.inc]). *)

(** The 512-word PROM image (383 real words zero-filled to 512), copied into each
    machine's ROM at construction. *)
val bootloader : int array
