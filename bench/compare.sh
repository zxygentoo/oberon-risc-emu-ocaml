#!/usr/bin/env bash
# Boot wall-time comparison: this OCaml port vs the Rust port, on the identical
# deterministic workload. Both execute the same instruction stream (they are
# bit-exact), so the wall-time ratio is the speed ratio.
#
#   dune build --profile release           # build the optimized OCaml binary
#   (cd ../oberon-risc-emu-rs && cargo build --release)
#   bench/compare.sh [frames] [disk]
set -u
frames=${1:-2000}
disk=${2:-DiskImage/Oberon-2020-08-18.dsk}
runs=5

ocaml=_build/default/bin/risc.exe
rust=../oberon-risc-emu-rs/target/release/risc

# Print the minimum real time (seconds) over $runs of "$2 --headless --frames ...".
best() {
  local name=$1 exe=$2 best= t
  for _ in $(seq "$runs"); do
    t=$( { TIMEFORMAT=%R; time "$exe" --headless --frames "$frames" "$disk" >/dev/null 2>&1; } 2>&1 )
    if [ -z "$best" ] || awk "BEGIN{exit !($t < $best)}"; then best=$t; fi
  done
  printf "  %-7s %6ss  (best of %d)\n" "$name" "$best" "$runs"
}

echo "boot --headless --frames $frames ($disk)"
if [ -x "$ocaml" ]; then best "OCaml" "$ocaml"; else echo "  OCaml binary missing — run: dune build --profile release"; fi
if [ -x "$rust" ]; then best "Rust" "$rust"; else echo "  Rust binary missing — build it under $rust"; fi
