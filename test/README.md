# Test suite

```sh
dune test
```

runs everything portable: ~20,000 enumerated assertions plus thousands of
randomized QCheck cases, in a few seconds. Each test is a plain executable —
a failing check prints `FAIL: ...` and the run exits non-zero; the shared
assert/summary helpers live in [`harness/`](harness/test_harness.mli).

What's in the default run:

- **boot golden** (`test_boot`) — one continuous deterministic 60 Hz boot of the
  bundled image, with the framebuffer + CPU-state FNV-1a hashes checked against
  the frozen C/Rust values at 7 checkpoints (frames 1–250).
- **FP vectors** (`test_fp_vectors`) — all 19,760 C-derived vectors replayed
  through the software FP/idiv for bit-identical output.
- **per-module unit tests** — CPU and memory map (`test_risc`, `test_himem`),
  devices (`test_disk`, `test_pclink`, `test_clipboard`, `test_raw_serial`),
  the shim ABI (`test_shim`), frontend (`test_ps2`, `test_cli`, `test_scale`,
  `test_hotkeys`, `test_screenshot` — the last decodes captures back through
  imagelib's own PNG reader), the host tools (`test_convert`, `test_packonly`,
  `test_image`, `test_resolve`, `test_pipeline`, `test_tool_cli`,
  `test_fsutil`, `test_seed`), and oat, the live-system serial client
  (`test_oat_io` — golden wire frames, the retry policy, and full exchanges
  over host pipes, `test_oat_device` — the byte channel over host pipes with
  forked children playing the device, `test_oat_tool_call` — the typed operations
  over an in-memory wire-typed fake, `test_oat_cli` — parsing and response
  rendering, `test_oat_error`).
- **property tests** (QCheck) — `test_prop` (oracle-free laws: U32 algebra,
  memory round-trips, the Z/N flag invariant, device round-trips) and
  `test_risc5_isa` (codec round-trips, differential encode vs hand-rolled
  golden encoders).

## Differential lockstep against the C reference (`@cosim`)

```sh
dune build @cosim          # needs a C toolchain
dune build @cosim --force  # re-run for a fresh random sample
```

Runs *live* against Peter De Wachter's C emulator, vendored verbatim under
[`cosim/`](cosim/) and reached via `#include`: the FP routines on 400,000
random inputs, 200,000 single random instructions over random state, and 5,000
bursts of 64 instructions compared after every step. Gated behind the alias
(not `dune test`) because it needs a C compiler. Note that dune caches success:
without `--force` a second run is a no-op, not new random coverage.

The lockstep machine runs with the C reference's 1 MiB memory map; the widened
16 MiB default is covered by `test_himem`.

## The image-builder round-trip (opt-in)

```sh
OBERON_ROUNDTRIP=1 dune runtest
```

extracts the committed golden image into a source tree, rebuilds it with
`build-po-image` — compiling the whole system headless through the shim — and
verifies the result re-opens as a valid, populated Oberon filesystem. It takes
a few seconds, so it self-skips unless `OBERON_ROUNDTRIP=1`. The variable is a
declared dune dependency: setting it re-runs the test even after a cached skip.

Byte-for-byte parity with the Rust tools is checked out-of-band by diffing both
ports' output over the same input (`extract-source` trees compare equal with
`diff -r`; `build-po-image` images hash identically).

## The live oat battery (opt-in)

```sh
make test-po        # Project Oberon image
make test-eo        # Extended Oberon image (downloads its stock source once)
```

builds the agent-ready disk image (see the root `Makefile`), boots it headless
on a private FIFO pair with the display environment scrubbed, and drives the
full `oat` surface against the running system from
[`integration.sh`](integration.sh): write/read round-trips, every edit path
(the wire OP_EDIT, the >1 KiB host-side fallback, and the error statuses),
compile/load/call, listings, trap survival (a trapping call reports cleanly
and the wire stays up), and deletes — plus, on Extended Oberon, a full
edit → compile → unload → reload hot swap. Kept out of `dune test` because it
boots a complete Oberon and needs the built image.

## Reproducing a QCheck failure

The QCheck runners print `random seed: N` on every run. To replay a failure:

```sh
QCHECK_SEED=N dune runtest --force
```

(`QCHECK_SEED` is also a declared dune dependency, so setting it invalidates a
cached success.)
