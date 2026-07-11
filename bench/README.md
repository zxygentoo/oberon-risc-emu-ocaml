# Benchmarks

```sh
dune exec --profile release bench/bench.exe
```

measures two things (build with the release profile for representative numbers):

- **boot throughput** — 2000 deterministic frames of the bundled image, a
  realistic mix of CPU, the SD-card disk protocol, MMIO, and framebuffer writes;
- **peak single-step rate** — a tight 6-instruction loop (ALU + store + load +
  backward branch) through the real dispatch.

For a cross-port comparison, time the identical deterministic workload on both
emulators — they execute the same instruction stream bit-exactly, so the
wall-time ratio is the speed ratio:

```sh
dune build --profile release
time _build/default/bin/risc.exe --headless --frames 2000 DiskImage/Oberon-2020-08-18.dsk
time <oberon-risc-emu-rs>/target/release/risc --headless --frames 2000 <disk image>
```
