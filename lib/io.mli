(** Device callback records (port of [risc-io.h]).

    Each device is a record of closures over its own mutable state, the OCaml
    analogue of the C's structs of function pointers. The core ([Risc.t]) holds
    each as an [option] and invokes it from inside the CPU step. Every value
    passed or returned is a machine word in [u32] range. *)

(** RS232 serial line: PCLink file transfer or a raw host serial port. *)
type serial =
  { serial_read_status : unit -> int
  ; serial_read_data : unit -> int
  ; serial_write_data : int -> unit
  }

(** An SPI slave (the SD-card disk lives here). *)
type spi =
  { spi_read_data : unit -> int
  ; spi_write_data : int -> unit
  }

(** The emulator-only clipboard bridge (host clipboard <-> Oberon). *)
type clipboard =
  { clip_read_control : unit -> int
  ; clip_write_control : int -> unit
  ; clip_read_data : unit -> int
  ; clip_write_data : int -> unit
  }

(** The board LEDs (optional logging device). *)
type led = { led_write : int -> unit }
