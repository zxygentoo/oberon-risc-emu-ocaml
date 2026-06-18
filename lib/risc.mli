(** The RISC5 CPU core, memory map, and public API (port of [risc.c]).

    The machine is bit-compatible with the FPGA system in the default
    configuration. Words are machine integers in [u32] range (see {!U32}). *)

(** Standard framebuffer width in pixels (overridable via {!configure_memory}). *)
val framebuffer_width : int

(** Standard framebuffer height in pixels. *)
val framebuffer_height : int

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
type t

(** Build a machine in the default (FPGA-compatible) configuration and reset it.
    Port of [risc_new]. *)
val make : unit -> t

(** [configure_memory t megabytes_ram screen_width screen_height] resizes RAM and
    the framebuffer, patching the boot ROM. RAM clamps to 1..32 MB, each screen
    axis to 32..4096 (width rounded down to a 32-pixel multiple). Port of
    [risc_configure_memory]. *)
val configure_memory : t -> int -> int -> int -> unit

(** Reset: jump to the boot ROM. Port of [risc_reset]. *)
val reset : t -> unit

(** Run up to [cycles] instructions, stopping early when the CPU is detected
    idle-spinning on the ms-counter or keyboard-ready bit. Port of [risc_run]. *)
val run : t -> int -> unit

(** {2 Device attachment}

    Each device is optional; an absent device reads as its idle default. *)

(** Attach the LED device (the [--leds] logger). *)
val set_leds : t -> Io.led -> unit

(** Attach the serial line (PCLink or a raw host serial port). *)
val set_serial : t -> Io.serial -> unit

(** Attach an SPI slave at index 1 or 2 (others ignored). Port of [risc_set_spi]. *)
val set_spi : t -> int -> Io.spi -> unit

(** Attach the host clipboard bridge. *)
val set_clipboard : t -> Io.clipboard -> unit

(** Set the switch register ([--boot-from-serial] sets bit 0). Port of
    [risc_set_switches]. *)
val set_switches : t -> int -> unit

(** {2 Input, time, framebuffer} *)

(** Set the synthetic millisecond clock. Port of [risc_set_time]. *)
val set_time : t -> int -> unit

(** Report a mouse move (coordinates in the Oberon frame). Port of
    [risc_mouse_moved]. *)
val mouse_moved : t -> int -> int -> unit

(** Report a mouse button (1=left, 2=middle, 3=right). Port of
    [risc_mouse_button]. *)
val mouse_button : t -> int -> bool -> unit

(** Enqueue PS/2 scancodes for the keyboard (dropped if the buffer is full). Port
    of [risc_keyboard_input]. *)
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

(** White-box access used by the test suite only — {b not} part of the stable
    API. These reach into machine internals the public interface deliberately
    hides (single-stepping, raw MMIO, the register/RAM/flag state). *)
module For_tests : sig
  val io_start : int
  val single_step : t -> unit
  val load_io : t -> int -> int
  val store_io : t -> int -> int -> unit
  val load_byte : t -> int -> int
  val store_byte : t -> int -> int -> unit
  val ram : t -> int array
  val regs : t -> int array
  val pc : t -> int
  val set_pc : t -> int -> unit
  val h : t -> int
  val set_h : t -> int -> unit
  val flags : t -> int
  val set_flags : t -> int -> unit
  val progress : t -> int
  val set_progress : t -> int -> unit
end
