(** Device callback records (port of [risc-io.h] / [io.rs]).

    The C uses [const*] callback structs plus mutable [static] globals; the idiomatic
    OCaml equivalent is a record of closures, each capturing its own device's mutable
    state. The core ([Risc.t]) holds each device as an [option] and invokes it
    synchronously from inside the CPU step ([load_io]/[store_io]). Every value passed or
    returned is a machine word in [u32] range. *)

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

(** The headless "shim" host backend (the Norebo runtime); see the interface. *)
type shim =
  { shim_load : int -> int
  ; shim_store : int -> int -> int array -> unit
  ; shim_exit_code : unit -> int option
  }
