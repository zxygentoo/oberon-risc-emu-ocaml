(* The 16 MiB default memory map: RAM above the framebuffer window ("himem",
   0x100000 and up) behaves as plain memory — load, store, and execute — while
   the kernel-visible low megabyte, the framebuffer damage window, and the
   sign-extended MMIO top are unchanged. White-box access goes through
   {!Risc_core.Risc.For_tests}, programs execute through the real dispatch. *)

open Risc_core
open Test_harness
module F = Risc.For_tests

(* Instructions assemble through the shared {!Risc5_isa} codec. *)
let stw a base = Risc5_isa.(encode (Store { size = W; a; base; off = 0 }))
let ldw a base = Risc5_isa.(encode (Load { size = W; a; base; off = 0 }))

let add a b c =
  Risc5_isa.(encode (Alu { op = Add; u = false; v = false; a; b; operand = Reg c }))
;;

let cpu () =
  let r = Risc.make () in
  F.set_pc r 0;
  r
;;

let ram = F.ram
let regs = F.regs

(* STW then LDW through the executed dispatch at [addr]. *)
let store_load_word name addr value =
  let r = cpu () in
  (ram r).(0) <- stw 1 0 (* STW R1, [R0] *);
  (ram r).(1) <- ldw 2 0 (* LDW R2, [R0] *);
  (regs r).(0) <- addr;
  (regs r).(1) <- value;
  F.single_step r;
  F.single_step r;
  eqx (name ^ "_ram") (ram r).(addr / 4) value;
  eqx (name ^ "_reg") (regs r).(2) value
;;

let () =
  (* Word store/load across the widened decode: the first himem word (1 MB), a
     mid-himem word (just under 14 MB), and the last RAM word. *)
  store_load_word "stw_ldw_blob_base" 0x0010_0000 0xDEAD_BEEF;
  store_load_word "stw_ldw_14mb_top" 0x00DF_FFFC 0x1234_5678;
  store_load_word "stw_ldw_ram_top" 0x00FF_FFFC 0xCAFE_F00D;
  (* Sub-word access in himem: byte read-back and little-endian placement. *)
  let r = cpu () in
  F.store_byte r 0x0012_3401 0xAB;
  eqx "ldb_himem" (F.load_byte r 0x0012_3401) 0xAB;
  eqx "stb_himem_le_word" (ram r).(0x0012_3400 / 4) (0xAB lsl 8);
  (* Execute from himem: PC above 1 MB fetches from RAM, not the void. *)
  let r = cpu () in
  (ram r).(0x0010_0000 / 4) <- add 2 0 1 (* ADD R2, R0, R1 *);
  (regs r).(0) <- 40;
  (regs r).(1) <- 2;
  F.set_pc r (0x0010_0000 / 4);
  F.single_step r;
  eqx "execute_from_himem" (regs r).(2) 42;
  eqx "execute_from_himem_pc" (F.pc r) ((0x0010_0000 / 4) + 1);
  (* Damage isolation: a himem store must not touch the framebuffer window's
     damage tracking; a display store still must. *)
  let r = cpu () in
  ignore (Risc.framebuffer_damage r) (* drop the constructor's full-screen mark *);
  F.store_byte r 0x0010_0000 0xFF;
  let d = Risc.framebuffer_damage r in
  check "himem_store_no_damage" (d.y1 > d.y2);
  F.store_byte r 0x000E_7F00 0xFF;
  let d = Risc.framebuffer_damage r in
  check "display_store_damages" (d.y1 = 0 && d.y2 = 0 && d.x1 = 0 && d.x2 = 0);
  (* The sign-extended MMIO top still dispatches to I/O, not RAM: an LDW from
     io_start reads the ms counter (a wrong RAM classification would be an
     out-of-bounds crash here, not a wrong value). *)
  let r = cpu () in
  Risc.set_time r 12345;
  (ram r).(0) <- ldw 2 0 (* LDW R2, [R0] *);
  (regs r).(0) <- F.io_start;
  F.single_step r;
  eqx "mmio_above_ram" (regs r).(2) 12345;
  (* The first word past RAM is I/O space (unmapped reads 0), not RAM. *)
  let r = cpu () in
  (ram r).(0) <- ldw 2 0;
  (regs r).(0) <- 0x0100_0000;
  (regs r).(1) <- 0;
  F.single_step r;
  eqx "past_ram_is_io" (regs r).(2) 0;
  summary "checks"
;;
