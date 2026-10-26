(** The RISC5 CPU core, memory map, and public API (port of [risc.c]).

    The default machine ({!make}) is the reference FPGA system with 16 MiB of RAM: the
    boot ROM, and so the kernel's MemLim and stack origin, are unchanged from the 1 MB
    board, as is the 1024x768 framebuffer window at 0xE7F00; RAM simply continues above
    1 MB for software that knows (no stock image does). Stock disk images therefore run
    bit-identically. The one observable divergence from the board: an address above 1 MB
    reaches real RAM, where the board's 20-bit bus would alias it into the low megabyte.
    {!configure_memory} switches to the C emulator's configurable layout instead.

    Words are machine integers in [u32] range (see {!U32}). Values handed in — device
    results, the clock — are taken modulo 2^32. *)

(** The default machine's framebuffer width in pixels (1024). *)
val default_screen_width : int

(** The default machine's framebuffer height in pixels (768). *)
val default_screen_height : int

(** A damaged (dirty) rectangle of the framebuffer, in framebuffer-word columns and line
    rows. [y1 > y2] means "nothing damaged". *)
type damage =
  { x1 : int
  ; x2 : int
  ; y1 : int
  ; y2 : int
  }

(** A snapshot of the architectural CPU state, for inspection and differential testing
    (mirrors the C cosim [dump_state]). [pc] is a word address (byte address / 4), [r] a
    copy of R0..R15, [flags] packed as in {!Cpu.flags}. *)
type cpu_state =
  { pc : int
  ; r : int array
  ; h : int
  ; flags : int
  }

(** The RISC5 machine: CPU registers, RAM/ROM, and attached devices. *)
type t

(** Build a machine in the default (FPGA-compatible) configuration and reset it. Port of
    [risc_new]. *)
val make : unit -> t

(** Switch to the C emulator's configurable layout: [megabytes] of RAM with a
    [width]x[height] framebuffer right above it, the boot ROM patched to match. RAM
    clamps to 1..32 MB, each screen axis to 32..4096 (width rounded down to a 32-pixel
    multiple). It replaces RAM — see {!Cpu.ram} — and with [megabytes] under 16 leaves
    less RAM than the default machine. Port of [risc_configure_memory]. *)
val configure_memory : t -> megabytes:int -> width:int -> height:int -> unit

(** Reset: jump to the boot ROM. Port of [risc_reset]. *)
val reset : t -> unit

(** Run up to [cycles] instructions, stopping early when the CPU is detected idle-spinning
    on the ms-counter or keyboard-ready bit. Port of [risc_run]. *)
val run : t -> int -> unit

(** {2 Device attachment}

    Each device is optional; an absent device reads as its idle default. *)

(** Attach the LED device (the [--leds] logger). *)
val set_leds : t -> Io.led -> unit

(** Attach the serial line (PCLink or a raw host serial port). *)
val set_serial : t -> Io.serial -> unit

(** Attach an SPI slave at index 1 (the SD card) or 2. Port of [risc_set_spi].
    @raise Invalid_argument for any other index (the C ignores it). *)
val set_spi : t -> int -> Io.spi -> unit

(** Attach the host clipboard bridge. *)
val set_clipboard : t -> Io.clipboard -> unit

(** Set the switch register ([--boot-from-serial] sets bit 0). Port of
    [risc_set_switches]. *)
val set_switches : t -> int -> unit

(** {2 Input, time, framebuffer} *)

(** Set the synthetic millisecond clock. Port of [risc_set_time]. The guest reads it
    modulo 2^32, as it reads every device value. *)
val set_time : t -> int -> unit

(** Report a mouse move (coordinates in the Oberon frame). Port of [risc_mouse_moved]. *)
val mouse_moved : t -> int -> int -> unit

(** Report a mouse button (1=left, 2=middle, 3=right). Port of [risc_mouse_button]. *)
val mouse_button : t -> int -> bool -> unit

(** Enqueue PS/2 scancodes for the keyboard (dropped if the buffer is full). Port of
    [risc_keyboard_input]. *)
val keyboard_input : t -> bytes -> unit

(** The framebuffer word at index [i] from the display start. *)
val framebuffer_word : t -> int -> int

(** Take the accumulated damage rectangle and reset it to empty. Port of
    [risc_get_framebuffer_damage]. *)
val framebuffer_damage : t -> damage

(** Framebuffer width in 32-pixel words. *)
val fb_width : t -> int

(** Framebuffer height in lines. *)
val fb_height : t -> int

(** Snapshot the architectural CPU state (for inspection / differential testing). *)
val cpu_state : t -> cpu_state

(** {2 Stepping and architectural state}

    The CPU opened up for lockstep harnesses, loaders and debuggers: one instruction at
    a time, and direct access to registers, flags and RAM. The arrays are the machine's
    own, live and mutable (no copies on the hot path): writes land in the machine. *)
module Cpu : sig
  (** Execute exactly one instruction — no clock, no idle detection (compare {!run}).
      A PC outside RAM and ROM resets the machine, as the C does. *)
  val single_step : t -> unit

  (** The program counter, as a word address (byte address / 4). *)
  val pc : t -> int

  val set_pc : t -> int -> unit

  (** R0..R15, live: the machine's own 16-element array. *)
  val regs : t -> int array

  (** The H register (high word of MUL, remainder of DIV). *)
  val h : t -> int

  val set_h : t -> int -> unit

  (** The ALU flags, packed [Z | N<<1 | C<<2 | V<<3] — test or build them with the
      masks below. *)
  val flags : t -> int

  val set_flags : t -> int -> unit
  val flag_z : int
  val flag_n : int
  val flag_c : int
  val flag_v : int

  (** RAM as words, live: word [i] is the 32-bit word at byte address [4 * i]. The
      array is replaced, so a reference held from before goes stale, by
      {!configure_memory} and [For_shim.configure_shim]; fetch it again after either. *)
  val ram : t -> int array
end

(** Headless "shim" execution mode: the CPU's second mode, in which the whole MMIO region
    routes to a host backend ({!Io.shim}) and the machine boots an inner-core image
    instead of the boot ROM. Drives the image-build toolchain (see {!Shim}). {b Not} part
    of the stable API. *)
module For_shim : sig
  (** Reconfigure as a flat [mem_bytes]-RAM machine with no framebuffer window (every
      below-[mem_bytes] access is plain RAM; MMIO stays at the top). Call before
      {!boot_inner_core}. Port of [configure_shim]. *)
  val configure_shim : t -> int -> unit

  (** Attach the shim host backend; while set, the MMIO region routes to it. *)
  val set_shim : t -> Io.shim -> unit

  (** Load an inner-core image (little-endian [(len, addr, bytes)] records terminated by
      [len = 0]) into RAM and set up the boot registers. Raises [Failure] on a truncated
      image or a record that falls outside RAM. *)
  val boot_inner_core : t -> string -> int -> unit

  (** Run in shim mode until the host halts, returning the guest exit code. Requires
      {!set_shim} and {!boot_inner_core}. Set [OBERON_TRACE] in the environment to dump a
      trace on an abnormal exit. *)
  val shim_run : t -> int
end

(** White-box access for this repo's test suite — {b not} part of the stable API (raw
    MMIO, byte access, the idle-detection counter). It also re-exports {!Cpu}, which it
    held before {!Cpu} existed; code outside the test suite should use {!Cpu}, as this
    re-export goes in a future major release. *)
module For_tests : sig
  include module type of Cpu

  val io_start : int
  val load_io : t -> int -> int
  val store_io : t -> int -> int -> unit
  val load_byte : t -> int -> int
  val store_byte : t -> int -> int -> unit
  val progress : t -> int
  val set_progress : t -> int -> unit
end
