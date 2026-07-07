(** The RISC5 CPU core, memory map, and public API (port of [risc.c] / [risc.rs]).

    The memory layout differs slightly from the reference FPGA: the FPGA uses a
    20-bit address bus and ignores the top 12 bits, while we use all 32 bits so
    the emulator can offer more RAM. The default machine carries 16 MiB with
    the boot ROM (and so the kernel's MemLim/stackOrg worldview) and the
    framebuffer window unchanged from the historical 1 MB configuration: stock
    disk images behave bit-identically, and the RAM above 1 MB is simply
    addressable — like a board whose memory chip is larger than the OS is
    configured to use. (The one observable divergence: an address above 1 MB
    reaches real RAM here, where the 20-bit FPGA would alias it into the low
    megabyte; no stock software emits such addresses.) {!configure_memory}
    remains the knob that makes {e Oberon itself} use more memory — it patches
    the boot ROM.

    Words are stored as native [int]s in [u32] range; see {!U32} for the exact
    32-bit arithmetic this relies on. *)

(** Standard framebuffer width in pixels (overridable via {!configure_memory}). *)
let framebuffer_width = 1024

(** Standard framebuffer height in pixels. *)
let framebuffer_height = 768

let default_mem_size = 0x0100_0000
let default_display_start = 0x000E_7F00

(* Top of the framebuffer's damage-tracked window. Historically RAM ended here
   (1 MB) with the framebuffer as its top slice; RAM now extends past it, so
   the window's end is its own bound rather than [mem_size]. *)
let default_display_end = 0x0010_0000
let rom_start = 0xFFFF_F800
let rom_words = 512
let io_start = 0xFFFF_FFC0

(* The four ALU status flags, packed [Z | N<<1 | C<<2 | V<<3] to match the
   [cpu_state] / cosim packing. *)
let flag_z = 1
let flag_n = 2
let flag_c = 4
let flag_v = 8

(** A damaged (dirty) rectangle of the framebuffer, in framebuffer-word columns
    and line rows. [y1 > y2] means "nothing damaged". *)
type damage =
  { mutable x1 : int
  ; mutable x2 : int
  ; mutable y1 : int
  ; mutable y2 : int
  }

(** A snapshot of the architectural CPU state, for inspection and differential
    testing (mirrors the C cosim [dump_state]). *)
type cpu_state =
  { pc : int
  ; r : int array
  ; h : int
  ; flags : int
  }

(** The RISC5 machine: CPU registers, RAM/ROM, and attached devices. *)
type t =
  { mutable pc : int
  ; r : int array (* 16 registers *)
  ; mutable h : int
  ; mutable flags : int
  ; mutable mem_size : int
  ; mutable display_start : int
  ; mutable display_end : int
  ; mutable progress : int
  ; mutable current_tick : int
  ; mutable mouse : int
  ; key_buf : Bytes.t (* 16 *)
  ; mutable key_cnt : int
  ; mutable switches : int
  ; mutable leds : Io.led option
  ; mutable serial : Io.serial option
  ; mutable spi_selected : int
  ; spi : Io.spi option array (* 4 *)
  ; mutable clipboard : Io.clipboard option
  ; mutable fb_width : int (* words *)
  ; mutable fb_height : int (* lines *)
  ; damage : damage
  ; mutable ram : int array
  ; rom : int array (* 512 *)
  }

let has t f = t.flags land f <> 0

let set_flag t f cond =
  if cond then t.flags <- t.flags lor f else t.flags <- t.flags land lnot f
;;

(** Reset: jump to the boot ROM. Port of [risc_reset]. *)
let reset t = t.pc <- rom_start / 4

(* ---- MMIO ---------------------------------------------------------------- *)

(* Keep each offset's logic in its own arm, mirroring the C's switch. *)
let load_io t address =
  match U32.sub address io_start with
  | 0 ->
    (* Millisecond counter. *)
    t.progress <- U32.sub t.progress 1;
    t.current_tick
  | 4 -> t.switches
  | 8 ->
    (match t.serial with
     | Some s -> s.serial_read_data ()
     | None -> 0)
  | 12 ->
    (match t.serial with
     | Some s -> s.serial_read_status ()
     | None -> 0)
  | 16 ->
    (match t.spi.(t.spi_selected) with
     | Some s -> s.spi_read_data ()
     | None -> 255)
  | 20 -> 1 (* SPI status: bit 0 = rx ready. *)
  | 24 ->
    (* Mouse input / keyboard status. *)
    if t.key_cnt > 0
    then t.mouse lor 0x1000_0000
    else (
      t.progress <- U32.sub t.progress 1;
      t.mouse)
  | 28 ->
    (* Keyboard input. *)
    if t.key_cnt > 0
    then (
      let scancode = Char.code (Bytes.get t.key_buf 0) in
      t.key_cnt <- t.key_cnt - 1;
      Bytes.blit t.key_buf 1 t.key_buf 0 t.key_cnt;
      scancode)
    else 0
  | 40 ->
    (match t.clipboard with
     | Some c -> c.clip_read_control ()
     | None -> 0)
  | 44 ->
    (match t.clipboard with
     | Some c -> c.clip_read_data ()
     | None -> 0)
  | _ -> 0
;;

let store_io t address value =
  match U32.sub address io_start with
  | 4 ->
    (match t.leds with
     | Some l -> l.led_write value
     | None -> ())
    (* LED control. *)
  | 8 ->
    (match t.serial with
     | Some s -> s.serial_write_data value
     | None -> ())
  | 16 ->
    (match t.spi.(t.spi_selected) with
     | Some s -> s.spi_write_data value
     | None -> ())
  | 20 -> t.spi_selected <- value land 3 (* bits 0-1 slave select. *)
  | 40 ->
    (match t.clipboard with
     | Some c -> c.clip_write_control value
     | None -> ())
  | 44 ->
    (match t.clipboard with
     | Some c -> c.clip_write_data value
     | None -> ())
  | _ -> ()
;;

(* ---- Memory -------------------------------------------------------------- *)

let load_word t addr = if addr < t.mem_size then t.ram.(addr / 4) else load_io t addr

let load_byte t addr =
  let w = load_word t addr in
  (w lsr (addr land 3 * 8)) land 0xFF
;;

let update_damage t w =
  let row = w / t.fb_width
  and col = w mod t.fb_width in
  if row < t.fb_height
  then (
    if col < t.damage.x1 then t.damage.x1 <- col;
    if col > t.damage.x2 then t.damage.x2 <- col;
    if row < t.damage.y1 then t.damage.y1 <- row;
    if row > t.damage.y2 then t.damage.y2 <- row)
;;

let store_word t addr value =
  if addr < t.display_start
  then t.ram.(addr / 4) <- value
  else if addr < t.display_end
  then (
    t.ram.(addr / 4) <- value;
    update_damage t ((addr / 4) - (t.display_start / 4)))
  else if addr < t.mem_size
  then t.ram.(addr / 4) <- value
  else store_io t addr value
;;

let store_byte t addr value =
  if addr < t.mem_size
  then (
    let shift = addr land 3 * 8 in
    let w = load_word t addr in
    let w = w land lnot (0xFF lsl shift) in
    store_word t addr (w lor ((value land 0xFF) lsl shift)))
  else store_io t addr (value land 0xFF)
;;

(* ---- CPU ----------------------------------------------------------------- *)

let set_register t reg value =
  t.r.(reg) <- value;
  set_flag t flag_z (value = 0);
  set_flag t flag_n (U32.to_i32 value < 0)
;;

(* Whether the (un-negated) condition [cc] holds for the current flags. *)
let cond_holds t cc =
  let open Risc5_isa in
  let n = has t flag_n
  and z = has t flag_z
  and c = has t flag_c
  and v = has t flag_v in
  match cc with
  | Mi -> n
  | Eq -> z
  | Cs -> c
  | Vs -> v
  | Ls -> c || z
  | Lt -> n <> v
  | Le -> n <> v || z
  | True -> true
;;

let single_step t =
  let in_ram = t.pc < t.mem_size / 4 in
  let in_rom =
    (not in_ram) && t.pc >= rom_start / 4 && t.pc < (rom_start / 4) + rom_words
  in
  if (not in_ram) && not in_rom
  then (
    Printf.eprintf "Branched into the void (PC=0x%08X), resetting...\n%!" t.pc;
    reset t)
  else (
    let ir = if in_ram then t.ram.(t.pc) else t.rom.(t.pc - (rom_start / 4)) in
    t.pc <- U32.wrap (t.pc + 1);
    (* Decode via the shared {!Risc5_isa} accessors ([@inline], allocation-free);
       the execute logic below is byte-for-byte the original. The [kind] match
       mirrors {!Risc5_isa.decode}; on a non-flambda build it costs a few % on the
       hot path versus a raw p/q branch tree — immaterial for the emulator, and
       free under flambda2. *)
    let open Risc5_isa in
    match kind ir with
    | Register ->
      let a = ra ir
      and b = rb ir in
      let b_val = t.r.(b) in
      let c_val = if q ir then imm_value ir else t.r.(rc ir) in
      let a_val =
        match op_of_word ir with
        | Mov ->
          if not (u ir)
          then c_val
          else if q ir
          then U32.shl c_val 16
          else if v ir
          then
            (* Reading the flags: the low byte is the hardware's CPU-id byte
               0x53. RISC5.v:113 reads {N, Z, C, OV, 20'b0, 8'h53}; the C
               reference emits 0xD0 instead. We follow the hardware and the
               Rust port; see
               https://github.com/zxygentoo/oberon-risc-emu-rs/blob/main/DIVERGENCES.md *)
            0x53
            lor (Bool.to_int (has t flag_n) lsl 31)
            lor (Bool.to_int (has t flag_z) lsl 30)
            lor (Bool.to_int (has t flag_c) lsl 29)
            lor (Bool.to_int (has t flag_v) lsl 28)
          else t.h
        | Lsl -> U32.shl b_val (c_val land 31)
        | Asr -> U32.sar b_val (c_val land 31)
        | Ror -> U32.ror b_val (c_val land 31)
        | And -> b_val land c_val
        | Ann -> b_val land lnot c_val
        | Ior -> b_val lor c_val
        | Xor -> b_val lxor c_val
        | Add ->
          let s = U32.add b_val c_val in
          let s = if u ir then U32.add s (Bool.to_int (has t flag_c)) else s in
          set_flag t flag_c (s < b_val);
          set_flag t flag_v ((s lxor c_val land (s lxor b_val)) lsr 31 <> 0);
          s
        | Sub ->
          let s = U32.sub b_val c_val in
          let s = if u ir then U32.sub s (Bool.to_int (has t flag_c)) else s in
          set_flag t flag_c (s > b_val);
          set_flag t flag_v ((b_val lxor c_val land (s lxor b_val)) lsr 31 <> 0);
          s
        | Mul ->
          let tmp =
            if not (u ir)
            then
              Int64.mul
                (Int64.of_int (U32.to_i32 b_val))
                (Int64.of_int (U32.to_i32 c_val))
            else Int64.mul (Int64.of_int b_val) (Int64.of_int c_val)
          in
          (* Int64 bitwise ops for the 64-bit product (see [Fp.idiv]). *)
          let ( lsr ) = Int64.shift_right_logical
          and ( land ) = Int64.logand in
          t.h <- Int64.to_int ((tmp lsr 32) land U32.mask64);
          Int64.to_int (tmp land U32.mask64)
        | Div ->
          if U32.to_i32 c_val > 0
          then
            if not (u ir)
            then (
              let bi = U32.to_i32 b_val
              and ci = U32.to_i32 c_val in
              let quot = U32.wrap (bi / ci)
              and r = U32.wrap (bi mod ci) in
              (* Floor toward negative infinity when the remainder is negative. *)
              if U32.to_i32 r < 0
              then (
                t.h <- U32.add r c_val;
                U32.sub quot 1)
              else (
                t.h <- r;
                quot))
            else (
              t.h <- b_val mod c_val;
              b_val / c_val)
          else (
            let { Fp.quot; rem } = Fp.idiv b_val c_val (u ir) in
            t.h <- rem;
            quot)
        | Fad -> Fp.fp_add b_val c_val (u ir) (v ir)
        | Fsb -> Fp.fp_add b_val (c_val lxor 0x8000_0000) (u ir) (v ir)
        | Fml -> Fp.fp_mul b_val c_val
        | Fdv -> Fp.fp_div b_val c_val
      in
      set_register t a a_val
    | Memory ->
      let a = ra ir
      and b = rb ir in
      let address = U32.add t.r.(b) (off20 ir) in
      if not (u ir)
      then (
        let a_val = if v ir then load_byte t address else load_word t address in
        set_register t a a_val)
      else if not (v ir)
      then store_word t address t.r.(a)
      else store_byte t address (t.r.(a) land 0xFF)
    | Branch ->
      (* Bit 27 negates the condition. *)
      let taken = cond_neg ir <> cond_holds t (cond_of_word ir) in
      if taken
      then (
        if v ir
        then
          (* The link register holds the return point as a byte address. *)
          set_register t 15 (U32.wrap (t.pc * 4));
        if not (u ir)
        then
          (* Register-indirect: the register holds a byte address. *)
          t.pc <- t.r.(rc ir) / 4
        else t.pc <- U32.add t.pc (off24 ir)))
;;

(** Run up to [cycles] instructions, stopping early when the CPU is detected
    idle-spinning on the ms-counter or keyboard-ready bit. Port of [risc_run]. *)
let run t cycles =
  (* [progress] lets us pause emulation until the next frame when the CPU is
     busy-waiting on the millisecond counter or keyboard ready bit. *)
  t.progress <- 20;
  let rec loop i =
    if i < cycles && t.progress <> 0
    then (
      single_step t;
      loop (i + 1))
  in
  loop 0
;;

(* ---- Construction / configuration ---------------------------------------- *)

(** Build a machine in the default (FPGA-compatible) configuration and reset it.
    Port of [risc_new]. *)
let make () =
  let fb_width = framebuffer_width / 32 in
  let fb_height = framebuffer_height in
  let t =
    { pc = 0
    ; r = Array.make 16 0
    ; h = 0
    ; flags = 0
    ; mem_size = default_mem_size
    ; display_start = default_display_start
    ; display_end = default_display_end
    ; progress = 0
    ; current_tick = 0
    ; mouse = 0
    ; key_buf = Bytes.make 16 '\000'
    ; key_cnt = 0
    ; switches = 0
    ; leds = None
    ; serial = None
    ; spi_selected = 0
    ; spi = Array.make 4 None
    ; clipboard = None
    ; fb_width
    ; fb_height
    ; damage = { x1 = 0; y1 = 0; x2 = fb_width - 1; y2 = fb_height - 1 }
    ; ram = Array.make (default_mem_size / 4) 0
    ; rom = Array.copy Boot_rom.bootloader
    }
  in
  reset t;
  t
;;

let clamp lo hi v = if v < lo then lo else if v > hi then hi else v

(** Resize RAM and the framebuffer, patching the boot ROM accordingly. Port of
    [risc_configure_memory]. RAM clamps to 1..32 MB, the screen to 32..4096 on
    each axis with the width rounded down to whole 32-pixel words. *)
let configure_memory t megabytes_ram screen_width screen_height =
  let megs = clamp 1 32 megabytes_ram in
  let screen_width = clamp 32 4096 screen_width land lnot 31 in
  let screen_height = clamp 32 4096 screen_height in
  t.display_start <- megs lsl 20;
  t.mem_size <- t.display_start + (screen_width * screen_height / 8);
  (* In this configuration the framebuffer is again RAM's top slice. *)
  t.display_end <- t.mem_size;
  t.fb_width <- screen_width / 32;
  t.fb_height <- screen_height;
  t.damage.x1 <- 0;
  t.damage.y1 <- 0;
  t.damage.x2 <- t.fb_width - 1;
  t.damage.y2 <- t.fb_height - 1;
  t.ram <- Array.make (t.mem_size / 4) 0;
  (* Patch the new constants into the bootloader. *)
  let mem_lim = t.display_start - 16 in
  t.rom.(372) <- 0x6100_0000 + (mem_lim lsr 16);
  t.rom.(373) <- 0x4116_0000 + (mem_lim land 0x0000_FFFF);
  let stack_org = t.display_start / 2 in
  t.rom.(376) <- 0x6100_0000 + (stack_org lsr 16);
  (* Inform the display driver of the framebuffer layout, at the default display
     start, so our disk images still boot on the standard FPGA. *)
  let d = default_display_start / 4 in
  t.ram.(d) <- 0x5369_7A67;
  t.ram.(d + 1) <- screen_width;
  t.ram.(d + 2) <- screen_height;
  t.ram.(d + 3) <- t.display_start;
  reset t
;;

(* ---- Device attachment --------------------------------------------------- *)

let set_leds t leds = t.leds <- Some leds
let set_serial t serial = t.serial <- Some serial

(** Attach an SPI slave at index 1 or 2 (others ignored). Port of [risc_set_spi]. *)
let set_spi t index spi = if index = 1 || index = 2 then t.spi.(index) <- Some spi

let set_clipboard t clipboard = t.clipboard <- Some clipboard
let set_switches t switches = t.switches <- switches

(* ---- Input / time / framebuffer ------------------------------------------ *)

(** Set the synthetic millisecond clock. Port of [risc_set_time]. *)
let set_time t tick = t.current_tick <- tick

(** Report a mouse move (coordinates in the Oberon frame). Port of
    [risc_mouse_moved]. *)
let mouse_moved t mouse_x mouse_y =
  if mouse_x >= 0 && mouse_x < 4096
  then t.mouse <- t.mouse land lnot 0x0000_0FFF lor mouse_x;
  if mouse_y >= 0 && mouse_y < 4096
  then t.mouse <- t.mouse land lnot 0x00FF_F000 lor (mouse_y lsl 12)
;;

(** Report a mouse button (1=left, 2=middle, 3=right). Port of
    [risc_mouse_button]. *)
let mouse_button t button down =
  if button >= 1 && button < 4
  then (
    let bit = 1 lsl (27 - button) in
    if down then t.mouse <- t.mouse lor bit else t.mouse <- t.mouse land lnot bit)
;;

(** Enqueue PS/2 scancodes for the keyboard (dropped if the buffer is full).
    Port of [risc_keyboard_input]. *)
let keyboard_input t codes =
  let len = Bytes.length codes in
  if Bytes.length t.key_buf - t.key_cnt >= len
  then (
    Bytes.blit codes 0 t.key_buf t.key_cnt len;
    t.key_cnt <- t.key_cnt + len)
;;

(** The framebuffer word at index [i] from [display_start]. Port of
    [risc_get_framebuffer_ptr] (indexed access). *)
let framebuffer_word t i = t.ram.((t.display_start / 4) + i)

(** Take the accumulated damage rectangle and reset it to empty. Port of
    [risc_get_framebuffer_damage]. *)
let framebuffer_damage t =
  let d = { x1 = t.damage.x1; x2 = t.damage.x2; y1 = t.damage.y1; y2 = t.damage.y2 } in
  t.damage.x1 <- t.fb_width;
  t.damage.x2 <- 0;
  t.damage.y1 <- t.fb_height;
  t.damage.y2 <- 0;
  d
;;

let fb_width t = t.fb_width
let fb_height t = t.fb_height

(** Snapshot the architectural CPU state (for inspection / differential testing). *)
let cpu_state t = { pc = t.pc; r = Array.copy t.r; h = t.h; flags = t.flags }

(* White-box access for the test suite; see the interface. *)
module For_tests = struct
  let io_start = io_start
  let single_step = single_step
  let load_io = load_io
  let store_io = store_io
  let load_byte = load_byte
  let store_byte = store_byte
  let ram t = t.ram
  let regs t = t.r
  let pc t = t.pc
  let set_pc t v = t.pc <- v
  let h t = t.h
  let set_h t v = t.h <- v
  let flags t = t.flags
  let set_flags t v = t.flags <- v
  let progress t = t.progress
  let set_progress t v = t.progress <- v
end
