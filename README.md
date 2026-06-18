# oberon-risc-emu-ml

An OCaml port of [Peter De Wachter's `oberon-risc-emu`][c] — an emulator for the
RISC5 machine that runs Niklaus Wirth's [Project Oberon][po] (2013). It is ported
from the Rust port [`oberon-risc-emu-rs`][rs] (itself a bit-exact port of the C),
and uses [`tsdl`][tsdl] (SDL2) for the window, rendering, and input.

The emulated machine — CPU, software floating point, MMIO, SD-card disk, serial
(PCLink / raw), and the clipboard bridge — is a faithful, **bit-exact** port: a
booted screen and the full CPU state hash identically to the C reference, and the
CPU is checked against the C instruction-by-instruction (see
[Verifying correctness](#verifying-correctness)).

## Layout

```
lib/         risc_core: the pure machine (no SDL), one module per C/Rust source
  u32.ml         exact 32-bit arithmetic on OCaml's native int
  fp.ml          software FP + integer division   (risc-fp.c)
  boot_rom.ml    the 512-word boot PROM            (risc-boot.inc)
  io.ml          device-callback record types      (risc-io.h)
  risc.ml        CPU core, memory map, MMIO        (risc.c)
  disk.ml        SPI SD-card state machine         (disk.c)
  pclink.ml      PCLink file transfer over serial  (pclink.c)
  raw_serial.ml  raw host serial line (Unix)       (raw-serial.c)
  clipboard.ml   host<->Oberon clipboard bridge    (sdl-clipboard.c)
  headless.ml    deterministic driver + FNV hashing
bin/         risc: the windowed frontend (tsdl). ps2/render/cli/sdl_clipboard
             are a small library (oberon_frontend) the tests link against;
             risc.ml is just the entry point.
  ps2.ml         SDL scancode -> PS/2 set-2        (sdl-ps2.c)
  sdl_clipboard.ml  SDL clipboard host
  render.ml      framebuffer -> ARGB texture + scaling (sdl-main.c)
  cli.ml         command-line parsing
  risc.ml        window, 60 fps clock loop, event dispatch, headless runner
test/        the test suite (see Verifying correctness)
  data/          the frozen FP vectors
  cosim/         vendored C reference for the differential lockstep
validate/    SDL-free golden-hash checker (boots a disk image headless)
DiskImage/   Oberon-2020-08-18.dsk (a bootable Project Oberon image)
```

## Requirements

- OCaml >= 4.08, dune >= 3
- `tsdl` (`opam install tsdl`) and the SDL2 system library
- Unix (the disk, PCLink, and raw-serial devices use the `unix` library)
- `qcheck-core` (`opam install qcheck-core`) — for the property tests
- A C compiler — already needed for OCaml/`tsdl`; also compiles the vendored C
  reference used by the `@cosim` differential tests

## Build & run

```sh
dune build

# windowed (the disk image is modified in place, as on real hardware):
dune exec bin/risc.exe -- DiskImage/Oberon-2020-08-18.dsk

# scale up, or go fullscreen:
dune exec bin/risc.exe -- --zoom 2 DiskImage/Oberon-2020-08-18.dsk
dune exec bin/risc.exe -- --fullscreen DiskImage/Oberon-2020-08-18.dsk
```

### Options

Ported from the C frontend, plus `--headless`/`--frames` from the Rust port:

| Option | Meaning |
| --- | --- |
| `--zoom REAL` | Scale the display in windowed mode |
| `--fullscreen` | Start in full-screen mode |
| `--leds` | Log the LED state to stdout |
| `--mem MEGS` | Set RAM size (1..32 MB) |
| `--size WIDTHxHEIGHT` | Set framebuffer size |
| `--boot-from-serial` | Boot from the serial line (no disk image required) |
| `--serial-in FILE` / `--serial-out FILE` | Use a raw host serial line instead of PCLink |
| `--headless` | Run without a window (until killed, or `--frames` frames) |
| `--frames N` | Run N deterministic frames, print FNV-1a hashes, then exit (headless only) |

### Controls

Three-button mouse (Oberon needs all three). On a trackpad, **Left Alt** acts as
the middle button. Keyboard shortcuts:

| Key | Action |
| --- | --- |
| `Alt`+`F4` | Quit |
| `F12`, or `Ctrl`+`Shift`+`Del` | Reset the machine |
| `F11`, or `Alt`+`Enter` | Toggle full-screen |

## Verifying correctness

```sh
dune test
```

runs the whole suite — ~20,000 enumerated assertions (dominated by the FP
vectors) plus thousands of randomized QCheck cases:

- **boot golden** — boots the bundled image under the deterministic 60 Hz clock
  and asserts the framebuffer + CPU-state FNV-1a hashes match the frozen values
  (identical to the Rust reference); one check exercising CPU + FP + disk + MMIO
  + damage end-to-end.
- **FP vectors** — replays all 19,760 C-derived vectors (`test/data/fp_vectors.txt`)
  through the software FP/idiv, asserting bit-identical output.
- **device protocols** — disk (SD/SPI), PCLink (REC/SND), clipboard (GET/PUT),
  raw serial.
- **CPU** — instruction-level checks, MMIO dispatch, `configure_memory`, reset.
- **frontend** — PS/2 scancode encoding, CLI parsing, display scaling.
- **property-based** (QCheck) — randomized, oracle-free laws: `U32` algebra,
  memory round-trips, the Z/N flag invariant over all register ops, disk and
  PCLink round-trips, `scale_rect` placement, and FP commutativity/sign.

### Differential lockstep against the C reference

```sh
dune build @cosim
```

runs *live* differential tests against Peter De Wachter's C — the strongest
oracle for a bit-exact port:

- **Layer 1 — FP/idiv**: the software FP routines on 400,000 random inputs
  against the C `fp_*`/`idiv` over FFI (extending the frozen vectors to the
  unbounded `u32` space).
- **Layer 2 — single-instruction CPU lockstep**: 200,000 random instructions
  over random architectural state, stepped once in both the OCaml port and the C
  (`risc_single_step`, reached by `#include`-ing `risc.c`), comparing the full
  state + an 8-word RAM window. Covers the whole decode/ALU/shifter/flag/branch
  space, including paths the boot never reaches. The one intentional divergence
  (MOV-flags-read, `0x50` vs C's `0xD0`) is filtered; QCheck shrinks any failure
  to a minimal instruction word.
- **Layer 3 — burst lockstep**: 5,000 streams of 64 random non-branch
  instructions over random state, run instruction-by-instruction with the full
  state + region compared after *every* step. Reaches what the single-instruction
  sampler can't — back-to-back PC progression, store-then-load memory chains, and
  values/flags flowing between ops.

The C reference is vendored under `test/cosim/` and these need a C toolchain, so
they are gated behind the `cosim` alias and kept out of the default `dune test`.

The boot is deterministic, so you can also reproduce the golden hashes by hand —
matching the Rust reference's `--headless --frames` output exactly:

```sh
dune exec bin/risc.exe -- --headless --frames 60 DiskImage/Oberon-2020-08-18.dsk
# frames=60 framebuffer_fnv1a=0xb9bdbf56ba51298d state_fnv1a=0x66a3e6fd77a6b491 blank_words=21929/24576
```

`validate/` does the same check without linking SDL, exercising only `risc_core`:

```sh
dune exec validate/validate.exe -- DiskImage/Oberon-2020-08-18.dsk 60
```

## Implementation notes

- **32-bit arithmetic.** Machine words are stored as OCaml's native `int` (63-bit
  on a 64-bit host) reduced modulo 2^32; see `lib/u32.ml`. `Int64` is used only
  where a genuine 64-bit intermediate is needed (the `MUL` product and the
  integer-division RQ register). This assumes a 64-bit OCaml runtime.
- **Devices** are records of closures over each device's mutable state (`io.ml`),
  the OCaml analogue of the C's structs of function pointers / the Rust traits.
- **Rendering** follows the C SDL frontend rather than the Rust winit/softbuffer
  one: a streaming ARGB texture is refreshed only over the damaged framebuffer
  region, and SDL's renderer does the bilinear scale into the window
  (`SDL_HINT_RENDER_SCALE_QUALITY = "best"`).
- **One intentional divergence**, inherited from the Rust port: reading the CPU
  flags via `MOV` returns the hardware's `0x50` CPU-id byte in the low byte
  (RISC5.v), where the C reference emits `0xD0`. This is inert to booting Oberon,
  which never reads that byte. See the Rust port's `DIVERGENCES.md`.

## Scope

This port covers the **emulator** — the `risc_core` machine and the windowed
frontend — plus the differential-lockstep harness that checks it against the C
live (`dune build @cosim`, above).

**Out of scope** is the Rust workspace's `host-tools` crate: the
`norebo`/inner-core toolchain for building disk images from Oberon source, a host
build tool rather than part of running Oberon. One slice of the cosim is also
left for later — full-boot lockstep (booting both emulators from a disk image and
comparing) — since the deterministic boot-golden hash already pins that path.

## Credits

- Original C emulator: Peter De Wachter — <https://github.com/pdewacht/oberon-risc-emu>
- Project Oberon: Niklaus Wirth and Jürg Gutknecht — <https://www.projectoberon.com>
- Rust port (the direct source for this port): `oberon-risc-emu-rs` — <https://github.com/zxygentoo/oberon-risc-emu-rs>

[c]: https://github.com/pdewacht/oberon-risc-emu
[rs]: https://github.com/zxygentoo/oberon-risc-emu-rs
[po]: https://www.projectoberon.com
[tsdl]: https://erratique.ch/software/tsdl
