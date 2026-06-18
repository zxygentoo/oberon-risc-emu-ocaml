(* Regression tests ported from the Rust `risc.rs` / `fp.rs` unit tests. The
   end-to-end bit-exactness is proven by the headless golden hashes (see the
   `validate` runner and the README); these guard the individual instruction
   paths. White-box access to the machine goes through {!Risc_core.Risc.For_tests}. *)

open Risc_core
module F = Risc.For_tests

(* Opcodes, in ISA order. *)
let mov = 0
and lsl_ = 1
and asr_ = 2
and ror_ = 3
and and_ = 4
and ann = 5
and ior = 6
and xor = 7
and add = 8
and sub = 9
and mul = 10
and div = 11
and fsb = 13

(* Flag bits, matching the [Z | N<<1 | C<<2 | V<<3] packing. *)
let flag_z = 1
and flag_n = 2
and flag_c = 4
and flag_v = 8

(* Instruction encoders (port of the Rust test helpers). *)
let reg q u v a b op ci =
  (q lsl 30)
  lor (u lsl 29)
  lor (v lsl 28)
  lor (a lsl 24)
  lor (b lsl 20)
  lor (op lsl 16)
  lor ci
;;

let mem u v a b off =
  0x8000_0000
  lor (u lsl 29)
  lor (v lsl 28)
  lor (a lsl 24)
  lor (b lsl 20)
  lor (off land 0x000F_FFFF)
;;

let br_imm negate cond link off =
  0xE000_0000
  lor (link lsl 28)
  lor (negate lsl 27)
  lor (cond lsl 24)
  lor (off land 0x00FF_FFFF)
;;

let br_reg negate cond link c =
  0xC000_0000 lor (link lsl 28) lor (negate lsl 27) lor (cond lsl 24) lor (c land 0xF)
;;

(* Fresh machine executing from RAM word 0. *)
let cpu () =
  let r = Risc.make () in
  F.set_pc r 0;
  r
;;

let ram = F.ram
let regs = F.regs
let z r = F.flags r land flag_z <> 0
let n r = F.flags r land flag_n <> 0
let c r = F.flags r land flag_c <> 0
let v r = F.flags r land flag_v <> 0
let failures = ref 0
let total = ref 0

let check name cond =
  incr total;
  if not cond
  then (
    incr failures;
    Printf.printf "FAIL: %s\n" name)
;;

let eqx name got want =
  incr total;
  if got <> want
  then (
    incr failures;
    Printf.printf "FAIL: %s: got 0x%08X, want 0x%08X\n" name got want)
;;

let () =
  (* ---- MOV ---- *)
  let r = cpu () in
  (ram r).(0) <- reg 1 0 0 1 0 mov 0x1234;
  F.single_step r;
  eqx "mov_immediate" (regs r).(1) 0x1234;
  check "mov_immediate flags" ((not (z r)) && not (n r));
  eqx "mov_immediate pc" (F.pc r) 1;
  let r = cpu () in
  (ram r).(0) <- reg 1 0 1 1 0 mov 0x8000;
  F.single_step r;
  eqx "mov_sign_extended" (regs r).(1) 0xFFFF_8000;
  check "mov_sign_extended n" (n r && not (z r));
  let r = cpu () in
  (ram r).(0) <- reg 1 1 0 1 0 mov 0x1234;
  F.single_step r;
  eqx "mov_high_shifts_16" (regs r).(1) 0x1234_0000;
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 0 mov 3;
  (regs r).(3) <- 0xCAFE;
  F.single_step r;
  eqx "mov_register" (regs r).(1) 0xCAFE;
  (* MOV flags read: hardware 0x50 low byte + N/Z/C/V in the top nibble. *)
  let r = cpu () in
  (ram r).(0) <- reg 0 1 1 1 0 mov 0;
  F.set_flags r (F.flags r lor flag_n lor flag_c);
  F.single_step r;
  eqx "mov_flags_read_0x50" (regs r).(1) (0x50 lor 0x8000_0000 lor 0x2000_0000);
  (* ---- shifts / logical ---- *)
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 lsl_ 3;
  (regs r).(2) <- 1;
  (regs r).(3) <- 4;
  F.single_step r;
  eqx "lsl" (regs r).(1) 0x10;
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 asr_ 3;
  (regs r).(2) <- 0x8000_0000;
  (regs r).(3) <- 4;
  F.single_step r;
  eqx "asr_sign_fill" (regs r).(1) 0xF800_0000;
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 ror_ 3;
  (regs r).(2) <- 0x0000_000F;
  (regs r).(3) <- 4;
  F.single_step r;
  eqx "ror_wraps" (regs r).(1) 0xF000_0000;
  List.iter
    (fun (op, want, name) ->
       let r = cpu () in
       (ram r).(0) <- reg 0 0 0 1 2 op 3;
       (regs r).(2) <- 0x0F00;
       (regs r).(3) <- 0x00F0;
       F.single_step r;
       eqx name (regs r).(1) want)
    [ and_, 0x0F00 land 0x00F0, "and"
    ; ann, 0x0F00 land lnot 0x00F0, "ann"
    ; ior, 0x0F00 lor 0x00F0, "ior"
    ; xor, 0x0F00 lxor 0x00F0, "xor"
    ];
  (* ---- ADD / SUB flags ---- *)
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 add 3;
  (regs r).(2) <- 0x7FFF_FFFF;
  (regs r).(3) <- 1;
  F.single_step r;
  eqx "add_overflow" (regs r).(1) 0x8000_0000;
  check "add_overflow flags" (v r && (not (c r)) && n r && not (z r));
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 add 3;
  (regs r).(2) <- 0xFFFF_FFFF;
  (regs r).(3) <- 1;
  F.single_step r;
  eqx "add_carry" (regs r).(1) 0;
  check "add_carry flags" (c r && (not (v r)) && z r && not (n r));
  let r = cpu () in
  (ram r).(0) <- reg 0 1 0 1 2 add 3;
  (regs r).(2) <- 1;
  (regs r).(3) <- 1;
  F.set_flags r (F.flags r lor flag_c);
  F.single_step r;
  eqx "add_with_carry_in" (regs r).(1) 3;
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 sub 3;
  (regs r).(2) <- 0x8000_0000;
  (regs r).(3) <- 1;
  F.single_step r;
  eqx "sub_overflow" (regs r).(1) 0x7FFF_FFFF;
  check "sub_overflow flags" (v r && not (c r));
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 sub 3;
  (regs r).(2) <- 0;
  (regs r).(3) <- 1;
  F.single_step r;
  eqx "sub_borrow" (regs r).(1) 0xFFFF_FFFF;
  check "sub_borrow carry" (c r);
  (* ---- MUL / DIV ---- *)
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 mul 3;
  (regs r).(2) <- U32.wrap (-2);
  (regs r).(3) <- 3;
  F.single_step r;
  eqx "mul_signed" (regs r).(1) (U32.wrap (-6));
  eqx "mul_signed_high" (F.h r) 0xFFFF_FFFF;
  let r = cpu () in
  (ram r).(0) <- reg 0 1 0 1 2 mul 3;
  (regs r).(2) <- 0x1_0000;
  (regs r).(3) <- 0x1_0000;
  F.single_step r;
  eqx "mul_unsigned" (regs r).(1) 0;
  eqx "mul_unsigned_high" (F.h r) 1;
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 div 3;
  (regs r).(2) <- U32.wrap (-7);
  (regs r).(3) <- 2;
  F.single_step r;
  eqx "div_signed_floor" (regs r).(1) (U32.wrap (-4));
  eqx "div_signed_rem" (F.h r) 1;
  let r = cpu () in
  (ram r).(0) <- reg 0 1 0 1 2 div 3;
  (regs r).(2) <- 17;
  (regs r).(3) <- 5;
  F.single_step r;
  eqx "div_unsigned" (regs r).(1) 3;
  eqx "div_unsigned_rem" (F.h r) 2;
  (* ---- FP dispatch (FSB sign flip): 2.0 - 1.0 = 1.0 ---- *)
  let r = cpu () in
  (ram r).(0) <- reg 0 0 0 1 2 fsb 3;
  (regs r).(2) <- 0x4000_0000;
  (regs r).(3) <- 0x3F80_0000;
  F.single_step r;
  eqx "fsb" (regs r).(1) 0x3F80_0000;
  (* ---- Memory ---- *)
  let r = cpu () in
  (ram r).(0) <- mem 1 0 1 2 0;
  (ram r).(1) <- mem 0 0 3 2 0;
  (regs r).(1) <- 0xDEAD_BEEF;
  (regs r).(2) <- 0x100;
  F.single_step r;
  F.single_step r;
  eqx "store_then_load_word" (regs r).(3) 0xDEAD_BEEF;
  let r = cpu () in
  (ram r).(0) <- mem 0 0 1 2 0xFFFFC;
  (regs r).(2) <- 0x200;
  (ram r).(0x1FC / 4) <- 0x1234_5678;
  F.single_step r;
  eqx "mem_offset_sign_extends" (regs r).(1) 0x1234_5678;
  let r = cpu () in
  (ram r).(0x40) <- 0x1122_3344;
  F.store_byte r 0x100 0xAB;
  eqx "store_byte_rmw_lo" (ram r).(0x40) 0x1122_33AB;
  F.store_byte r 0x102 0xEE;
  eqx "store_byte_rmw_b2" (ram r).(0x40) 0x11EE_33AB;
  eqx "load_byte_le_0" (F.load_byte r 0x100) 0xAB;
  eqx "load_byte_le_3" (F.load_byte r 0x103) 0x11;
  (* ---- Branches ---- *)
  let r = cpu () in
  (ram r).(0) <- br_imm 0 7 0 5;
  F.single_step r;
  eqx "branch_forward" (F.pc r) 6;
  let r = cpu () in
  F.set_pc r 10;
  (ram r).(10) <- br_imm 0 7 0 0xFFFFFB;
  F.single_step r;
  eqx "branch_backward" (F.pc r) 6;
  let r = cpu () in
  (ram r).(0) <- br_imm 0 1 0 5;
  F.set_flags r (F.flags r land lnot flag_z);
  F.single_step r;
  eqx "branch_not_taken" (F.pc r) 1;
  let r = cpu () in
  (ram r).(0) <- br_reg 0 7 0 3;
  (regs r).(3) <- 0x40;
  F.single_step r;
  eqx "branch_reg_indirect" (F.pc r) 0x10;
  let r = cpu () in
  (ram r).(0) <- br_imm 0 7 1 5;
  F.single_step r;
  eqx "branch_link_lr" (regs r).(15) 4;
  eqx "branch_link_pc" (F.pc r) 6;
  (* ---- MMIO ---- *)
  let r = cpu () in
  Risc.set_time r 0x0001_2345;
  F.set_progress r 20;
  eqx "mmio_ms_counter" (F.load_io r F.io_start) 0x0001_2345;
  eqx "mmio_ms_progress" (F.progress r) 19;
  let r = cpu () in
  Risc.set_switches r 1;
  eqx "mmio_switches" (F.load_io r (F.io_start + 4)) 1;
  let r = cpu () in
  eqx "mmio_spi_default" (F.load_io r (F.io_start + 16)) 255;
  eqx "mmio_spi_status" (F.load_io r (F.io_start + 20)) 1;
  let r = cpu () in
  Risc.keyboard_input r (Bytes.of_string "\x1C\x32");
  eqx "mmio_kbd_ready" (F.load_io r (F.io_start + 24) land 0x1000_0000) 0x1000_0000;
  eqx "mmio_kbd_b0" (F.load_io r (F.io_start + 28)) 0x1C;
  eqx "mmio_kbd_b1" (F.load_io r (F.io_start + 28)) 0x32;
  eqx "mmio_kbd_drained" (F.load_io r (F.io_start + 28)) 0;
  let r = cpu () in
  Risc.mouse_moved r 0x123 0x456;
  eqx
    "mouse_pack"
    (F.load_io r (F.io_start + 24) land 0x00FF_FFFF)
    ((0x456 lsl 12) lor 0x123);
  Risc.mouse_button r 1 true;
  check "mouse_btn1" (F.load_io r (F.io_start + 24) land (1 lsl 26) <> 0);
  Risc.mouse_button r 1 false;
  check "mouse_btn1_up" (F.load_io r (F.io_start + 24) land (1 lsl 26) = 0);
  (* ---- FP known values ---- *)
  eqx "fp_add 1+1=2" (Fp.fp_add 0x3F80_0000 0x3F80_0000 false false) 0x4000_0000;
  eqx "fp_mul 2*3=6" (Fp.fp_mul 0x4000_0000 0x4040_0000) 0x40C0_0000;
  eqx "fp_div 6/2=3" (Fp.fp_div 0x40C0_0000 0x4000_0000) 0x4040_0000;
  let q = Fp.idiv 17 5 false in
  check "idiv 17/5" (q.Fp.quot = 3 && q.Fp.rem = 2);
  let q = Fp.idiv (U32.wrap (-7)) 2 true in
  check "idiv -7/2 floors" (q.Fp.quot = U32.wrap (-4) && q.Fp.rem = 1);
  (* ---- configure_memory (RAM resize + ROM patch + clamps) ---- *)
  let d = 0x000E_7F00 / 4 in
  (* The display-driver magic block lands at the default display start. *)
  let r = Risc.make () in
  Risc.configure_memory r 2 800 600;
  eqx "cfg_fb_width" (Risc.fb_width r) (800 / 32);
  eqx "cfg_fb_height" (Risc.fb_height r) 600;
  eqx "cfg_magic" (ram r).(d) 0x5369_7A67;
  eqx "cfg_magic_w" (ram r).(d + 1) 800;
  eqx "cfg_magic_h" (ram r).(d + 2) 600;
  eqx "cfg_magic_display_start" (ram r).(d + 3) (2 lsl 20);
  (* RAM megabytes clamp to [1, 32] (read back via the display_start magic word). *)
  Risc.configure_memory r 0 1024 768;
  eqx "cfg_megs_clamp_lo" (ram r).(d + 3) (1 lsl 20);
  Risc.configure_memory r 99 1024 768;
  eqx "cfg_megs_clamp_hi" (ram r).(d + 3) (32 lsl 20);
  (* Screen dims clamp to [32, 4096]; width rounds down to a multiple of 32. *)
  Risc.configure_memory r 1 100_000 7;
  eqx "cfg_w_clamp" (Risc.fb_width r) (4096 / 32);
  eqx "cfg_h_clamp" (Risc.fb_height r) 32;
  Risc.configure_memory r 1 1000 768;
  eqx "cfg_w_round" (Risc.fb_width r) (992 / 32);
  (* ---- Branched-into-the-void resets to the boot ROM ---- *)
  let r = cpu () in
  F.set_pc r 0x8_0000;
  (* past RAM, below ROM *)
  F.single_step r;
  eqx "void_reset" (F.pc r) (0xFFFF_F800 / 4);
  (* ---- Store to the display marks framebuffer damage ---- *)
  let r = cpu () in
  ignore (Risc.framebuffer_damage r : Risc.damage);
  (* clear the initial full-screen damage *)
  F.store_byte r 0x000E_7F00 0xFF;
  let dmg = Risc.framebuffer_damage r in
  check "damage_rect" (dmg.Risc.x1 = 0 && dmg.x2 = 0 && dmg.y1 = 0 && dmg.y2 = 0);
  eqx "damage_fb_word" (Risc.framebuffer_word r 0) 0xFF;
  (* ---- MMIO dispatches to the right device by offset ---- *)
  let log = ref [] in
  let push c v = log := (c, v) :: !log in
  let r = cpu () in
  Risc.set_serial
    r
    { Io.serial_read_status =
        (fun () ->
          push 'S' 0;
          0xAB)
    ; serial_read_data =
        (fun () ->
          push 's' 0;
          0xAB)
    ; serial_write_data = (fun v -> push 'w' v)
    };
  Risc.set_leds r { Io.led_write = (fun v -> push 'l' v) };
  Risc.set_clipboard
    r
    { Io.clip_read_control =
        (fun () ->
          push 'C' 0;
          10)
    ; clip_write_control = (fun v -> push 'c' v)
    ; clip_read_data =
        (fun () ->
          push 'D' 0;
          20)
    ; clip_write_data = (fun v -> push 'd' v)
    };
  eqx "mmio_serial_data" (F.load_io r (F.io_start + 8)) 0xAB;
  eqx "mmio_serial_status" (F.load_io r (F.io_start + 12)) 0xAB;
  F.store_io r (F.io_start + 8) 0x55;
  F.store_io r (F.io_start + 20) 1 (* select SPI slave 1 *);
  Risc.set_spi
    r
    1
    { Io.spi_read_data =
        (fun () ->
          push 'r' 0;
          0xCD)
    ; spi_write_data = (fun v -> push 'x' v)
    };
  eqx "mmio_spi_data" (F.load_io r (F.io_start + 16)) 0xCD;
  F.store_io r (F.io_start + 16) 0x99;
  F.store_io r (F.io_start + 4) 0xF0 (* LEDs *);
  eqx "mmio_clip_control" (F.load_io r (F.io_start + 40)) 10;
  eqx "mmio_clip_data" (F.load_io r (F.io_start + 44)) 20;
  F.store_io r (F.io_start + 40) 7;
  F.store_io r (F.io_start + 44) 0x41;
  check
    "mmio_dispatch_log"
    (List.rev !log
     = [ 's', 0
       ; 'S', 0
       ; 'w', 0x55
       ; 'r', 0
       ; 'x', 0x99
       ; 'l', 0xF0
       ; 'C', 0
       ; 'D', 0
       ; 'c', 7
       ; 'd', 0x41
       ]);
  if !failures = 0
  then Printf.printf "ok: %d checks passed\n" !total
  else (
    Printf.printf "FAILED: %d/%d checks failed\n" !failures !total;
    exit 1)
;;
