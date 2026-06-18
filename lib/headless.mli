(** Deterministic headless driver and state hashing.

    The synthetic 60 Hz clock (not wall time) makes a boot byte-for-byte
    reproducible, which is what the C-derived golden hashes rely on. *)

(** The FPGA system clock the emulator models (25 MHz). *)
val cpu_hz : int

(** Frames per second the clock is paced at (60). *)
val fps : int

(** Advance the machine by [frames], driving the fixed 60 Hz synthetic clock but
    independent of wall time, so the run is reproducible. *)
val run_frames : Risc.t -> int -> unit

(** FNV-1a of the active framebuffer (the visible [fb_width * fb_height] words). *)
val framebuffer_hash : Risc.t -> int64

(** FNV-1a of the architectural CPU state (PC, R0..R15, H, flags). *)
val state_hash : Risc.t -> int64
