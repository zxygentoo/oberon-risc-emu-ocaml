(** Device callback records (port of [risc-io.h]).

    Each device is a record of closures over its own mutable state, the OCaml analogue of
    the C's structs of function pointers. The core ([Risc.t]) holds each as an [option]
    and invokes it from inside the CPU step. Every value passed or returned is a machine
    word in [u32] range. *)

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

(** The headless "shim" host backend (the Norebo runtime). When attached, the whole MMIO
    region routes here instead of to the FPGA device map above, and the machine boots an
    inner-core image rather than the boot ROM. A record of closures over the host's state,
    invoked from the CPU's IO dispatch. *)
type shim =
  { shim_load : int -> int
    (** Answer an MMIO load at the given offset ([address - IO base]); never reaches into
      guest memory. *)
  ; shim_store : int -> int -> int array -> unit
    (** Handle an MMIO store [offset value ram]; only the syscall trigger reaches into the
      guest [ram]. *)
  ; shim_exit_code : unit -> int option
    (** [Some code] once the guest has halted (a [Halt] syscall or a trap). *)
  }
