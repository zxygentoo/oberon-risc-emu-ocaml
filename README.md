# oberon-risc-emu-ocaml

An OCaml port of [Peter De Wachter's `oberon-risc-emu`][c], an emulator for the
RISC5 machine that runs Niklaus Wirth's [Project Oberon][po] (2013). It follows
the Rust port [`oberon-risc-emu-rs`][rs] and uses [`tsdl`][tsdl] (SDL2) for the
window, rendering, and input.

The whole machine — CPU, software floating point, MMIO, SD-card disk, serial, and
clipboard — is a **bit-exact** port, verified against the C reference down to
individual instructions (see [Verifying correctness](#verifying-correctness)).

## Requirements

OCaml ≥ 5.1, dune ≥ 3, a C compiler, and the SDL2 system library. SDL2 comes
from your OS package manager (e.g. `apt install libsdl2-dev`,
`brew install sdl2`); the OCaml dependencies come from opam:

```sh
opam install . --deps-only --with-test
```

This reads `oberon-risc-emu.opam` (generated from `dune-project`) and pulls in
`tsdl` — which binds SDL2 — plus `imagelib`, which encodes screenshots as PNG,
`crunch`, which embeds the host tools' toolchain assets at build time, and
`qcheck-core`, which drives the property tests. The C compiler (already needed
by `tsdl`) also builds the vendored C reference for the `@cosim` tests.

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
| `--shot-frames N,N,..` | Save the framebuffer as `risc-shotNNNN.png` after each listed frame (with `--frames`) |

### Controls

Three-button mouse (Oberon needs all three). On a trackpad, **Left Alt** acts as
the middle button. Keyboard shortcuts:

| Key | Action |
| --- | --- |
| `Alt`+`F4` | Quit |
| `F12`, or `Ctrl`+`Shift`+`Del` | Reset the machine |
| `F11`, or `Alt`+`Enter` | Toggle full-screen |
| `F10` | Save a screenshot (`risc-shotNNNN.png` in the working directory) |

## Host tools

The disk-image toolchain from the Rust workspace's `host-tools`, ported under
`tools/`:

```sh
# unpack a build-ready source tree from an image (writes .packonly too):
dune exec tools/bin/extract_source.exe -- DiskImage/Oberon-2020-08-18.dsk src/

# compile the whole tree back into a bootable image:
dune exec tools/bin/build_po_image.exe -- src/ Oberon.dsk

# convert one file between Oberon (Latin-1/CR) and host (UTF-8/LF) text:
dune exec tools/bin/ob2txt.exe -- src/Kernel.Mod    # -> src/Kernel.Mod.txt
dune exec tools/bin/txt2ob.exe -- src/Kernel.Mod.txt
```

`build-po-image` (and `build-eo-image`, its Extended Oberon counterpart) drive
the Oberon compiler headless through a port of project-norebo's shim runtime,
with the bootstrap toolchain embedded in the binary. Both directions are
verified byte-identical against the Rust tools: extracted trees compare equal,
and built images hash identically.

## Driving a live system (oat)

`oat` — ported from [oberon-agent][oa] — drives a *running* Oberon over the
serial line: read/write/edit files, compile, load/unload modules, run any
command. It is a stateless CLI: each invocation opens the line (an emulator
FIFO pair, or a real FPGA's UART via `--serial`), performs one request against
`AgentTool.Mod` on the device, prints the result, and exits. Everything lives
under [`oat/`](oat/): the client, the on-system modules (`oat/Mod/`), and the
agent-facing rules for driving it from a coding agent
([`oat/skill/`](oat/skill/oberon-agent/SKILL.md)).

The stock images don't carry the agent modules; the root `Makefile` builds
agent-ready images with this repo's own toolchain (build-time system deps:
`make`, `patch`, and `curl`/`wget` for the EO download):

```sh
make po-image                        # DiskImage/ProjectOberon.dsk, fully offline
make eo-image                        # DiskImage/ExtendedOberon.dsk (pinned download)

mkfifo /tmp/p.in /tmp/p.out          # once
make po-emu                          # boot the image on the FIFO pair, windowed
```

then, from another shell:

```sh
OAT="_build/default/oat/bin/oat.exe --serial-in /tmp/p.in --serial-out /tmp/p.out"
$OAT check                           # ok: Project Oberon 2013 (round-trip 1ms)
$OAT write Stars.Mod < Stars.Mod     # push source
$OAT compile Stars.Mod               # ORP.Compile; compiler log -> stdout
$OAT call Stars.Show                 # run it; the Oberon.Log delta -> stdout
```

Swap `make po-emu` for `risc --headless --serial-in ... --serial-out ...` and
the same loop runs without a window; re-run deterministically with
`--shot-frames` to see the screen. `make test-po` / `make test-eo` run a live
battery of the full oat surface against a booted image (see
[`test/README.md`](test/README.md)).

## Verifying correctness

```sh
dune test
```

runs the full suite — ~20,000 enumerated assertions (mostly FP vectors) plus
thousands of randomized QCheck cases:

- **boot golden** — one continuous deterministic 60 Hz boot of the bundled image,
  with the framebuffer and CPU-state FNV-1a hashes checked against the frozen
  C/Rust values at 7 checkpoints (frames 1–250).
- **FP vectors** — replays all 19,760 C-derived vectors through the software
  FP/idiv for bit-identical output.
- **devices** — disk (SD/SPI), PCLink, clipboard, raw serial, the shim file ABI.
- **CPU & frontend** — instruction-level checks, MMIO, `configure_memory`, reset;
  PS/2 encoding, CLI parsing, hotkeys, display scaling.
- **host tools** — converters, `.packonly`, the FS reader/extractor, compile-order
  resolution, the embedded seeds.
- **property-based** (QCheck) — oracle-free laws: `U32` algebra, memory
  round-trips, the Z/N flag invariant, device round-trips, FP commutativity/sign.

See [`test/README.md`](test/README.md) for the full tour, including the opt-in
image-builder round-trip (`OBERON_ROUNDTRIP=1 dune runtest`) and how to
reproduce a QCheck failure from its printed seed.

### Differential lockstep against the C reference

```sh
dune build @cosim
```

runs *live* tests against Peter De Wachter's C (vendored under `test/cosim/`,
reached via `#include`) — the strongest oracle for a bit-exact port. Three layers:
the FP routines on 400,000 random inputs; 200,000 single random instructions over
random state; and 5,000 bursts of 64 instructions compared after every step.
Together they cover the whole decode/ALU/flag/branch space, including paths the
boot never reaches. They need a C toolchain, so they are gated behind the `cosim`
alias and kept out of `dune test` (see [`test/README.md`](test/README.md)).

The boot is deterministic, so you can also reproduce the golden hashes by hand —
matching the Rust reference's `--headless --frames` output exactly:

```sh
dune exec bin/risc.exe -- --headless --frames 60 DiskImage/Oberon-2020-08-18.dsk
# frames=60 framebuffer_fnv1a=0xb9bdbf56ba51298d state_fnv1a=0x66a3e6fd77a6b491 blank_words=21929/24576
```

`validate/validate.exe` runs the same check without SDL, exercising only
`risc_core`.

## Implementation notes

- **32-bit arithmetic** uses OCaml's native `int` reduced modulo 2^32
  (`lib/u32.ml`); `Int64` appears only for the `MUL` product and the division
  remainder. Assumes a 64-bit runtime.
- **Devices** are records of closures over each device's state (`io.ml`) — the
  OCaml analogue of the C's function-pointer structs / Rust's traits.
- **Rendering** follows the C frontend: a streaming ARGB texture refreshed only
  over the damaged region, scaled by SDL's renderer (not the Rust port's manual
  scaler).
- **One intentional divergence** (from the Rust port): reading the CPU flags via
  `MOV` returns the hardware's `0x53` id byte where the C emits `0xD0` — inert to
  Oberon, which never reads it. See the Rust port's `DIVERGENCES.md`.

## Scope

This port covers the emulator — the `risc_core` machine and the tsdl frontend —
the differential-lockstep harness, the Rust workspace's host tools (the text
converters, the source extractor, and the two image builders with the headless
shim runtime they drive; see [Host tools](#host-tools)), and the oberon-agent
workspace's `oat` client with its on-system modules and image pipeline (see
[Driving a live system](#driving-a-live-system-oat)). Out of scope: the Rust
dev tools (`eo-driver`, `eo-inner-run`), and full-boot lockstep (the 7-checkpoint
boot golden already pins that path against the C-derived hashes).

## Credits

- Original C emulator: Peter De Wachter — <https://github.com/pdewacht/oberon-risc-emu>
- Project Oberon: Niklaus Wirth and Jürg Gutknecht — <https://www.projectoberon.com>
- Rust port (the direct source for this port): `oberon-risc-emu-rs` — <https://github.com/zxygentoo/oberon-risc-emu-rs>

## License

ISC, matching upstream — see [`LICENSE`](LICENSE). The emulator derives from Peter
De Wachter's `oberon-risc-emu` (© 2014, ISC); the bundled disk image and the
vendored C reference are used under the same terms.

[c]: https://github.com/pdewacht/oberon-risc-emu
[rs]: https://github.com/zxygentoo/oberon-risc-emu-rs
[po]: https://www.projectoberon.com
[tsdl]: https://erratique.ch/software/tsdl
[oa]: https://github.com/zxygentoo/oberon-agent
