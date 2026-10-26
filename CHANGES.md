# Changes

## 1.0.0 (unreleased)

The first stable release: the emulator core and the host tools take on the
compatibility promise in the README's [Stability](README.md#stability) section. Changes
since `v0.1.0`:

### Packaging

- Three opam packages, released together at one version:
  - `oberon-risc` — the core library (public name `oberon-risc`, module
    `Oberon_risc`), needing nothing beyond the OCaml distribution;
  - `oberon-risc-emu` — the `risc` command (SDL2 via tsdl);
  - `oberon-risc-tools` — `ob2txt`, `txt2ob`, `extract-source`, `build-po-image`,
    `build-eo-image`, and the experimental `oat`.
- The library module is `Oberon_risc` (it was `Risc_core`, a private library).
- `Oberon_risc.Version.version` is the one version string; every executable prints
  it with `--version`.
- The crunch rule uses `%{project_root}`, so the tools build when this repository is
  vendored inside another dune workspace.

### Breaking changes in `Oberon_risc`, and what to do

- `Boot_rom.bootloader` is `unit -> int array` (a fresh copy per call) — add `()`.
- `Risc.configure_memory` takes `~megabytes ~width ~height`.
- `Risc.framebuffer_width` / `framebuffer_height` are `default_screen_width` /
  `default_screen_height`.
- `Risc.damage` is immutable.
- `Risc.set_spi` raises `Invalid_argument` for a slot other than 1 or 2.
- `Risc5_isa`: the field accessors (`p q u v ra rb rc kind imm16 …`) moved to
  `Risc5_isa.Word`; `encode` raises `Invalid_argument` for a field that does not fit
  its bits; `op_of_int` / `cond_of_int` raise outside 0..15 / 0..7.
- `Headless.standard_machine` takes `?disk:Disk.t` (was a path): `Disk.create (Some
  path)` boots the file in place, `Disk.of_string` boots it in memory.
- PCLink's transfer notes go to stderr (they went to stdout).

Downstream, verified against scratch copies: oberon-risc-hardcaml needs only the
`Boot_rom.bootloader ()` change (two call sites); DOOM-on-Oberon needs none (its
differential suite passes and its blob is byte-identical).

### New in `Oberon_risc`

- `Risc.Cpu`, the documented stepping surface: `single_step`, `pc`/`set_pc`, `regs`,
  `h`/`set_h`, `flags`/`set_flags` and the flag masks, `ram`. `Risc.For_tests` still
  re-exports it; move to `Risc.Cpu` by renaming the module.
- `Disk.of_string` (a card held in memory, writes kept per block) and
  `Disk.contents`; `Disk.close`, `Raw_serial.close`.
- `Headless.fnv1a_words`; `Oberon_name.file_name_ok` / `max_length`; `Version`.

### Fixes

- Core: `encode` silently corrupted out-of-range fields; one guest store to the
  clipboard control register allocated 4 GiB; the shim crashed reading past a seek
  beyond the end of a file; device values past 32 bits reached registers; disk and
  raw-serial files could never be closed; a raw serial line at end of input
  reported endless rx-ready NULs, completing a cut-short frame with zeros (a
  deliberate divergence from the C).
- Image builders: a file name Oberon can't hold, or a file over 3 210 912 bytes, now
  fails the build up front — it used to produce an unbootable image with exit 0;
  the scratch directory is private and always removed after a successful build;
  `rm_rf` never follows symlinks.
- `txt2ob` refuses text that is not UTF-8 (as the Rust tool did), drops a BOM, and
  counts the characters it folds to `?`.
- `risc`: one command-line contract with the tools (`--help`, `--version`, exit 0 / 1
  / 2); a failed F10 screenshot no longer ends the session; held hotkeys act once;
  a second disk image, a value on a flag, and out-of-range `--frames` / `--zoom` /
  `--mem` are refused instead of silently mis-taken; `--frames` boots in memory and
  needs no temp file.
- Makefile: `clean` removes only what it built (it was `rm -rf build`), `distclean`
  the download too; a failing patch fails the build; images rebuild when the
  toolchain changes; the live battery boots a copy of the image.
- oat (experimental): over-long names, a CALL that empties the Log, writes to an
  invalid name, CALL and EDIT payloads arriving through the disk, a blocking write
  past `--timeout`, and retries that could run a command twice.

### Tests

- The whole suite runs in about a second (a QCheck property built a 16 MiB machine
  per case); tests are attached to their packages, so `oberon-risc`'s run needs no
  SDL; a new end-to-end test pins every executable's command-line contract.

## 0.1.0 (2026-10-26)

The pre-tidy-up baseline, tagged so downstream projects could pin it. No stability
promise.
