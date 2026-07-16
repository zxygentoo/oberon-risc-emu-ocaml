# Plan: oat port + emulator screenshots

> **Status (2026-07-16, branch `feat/oat`)** — Part 1 is implemented and
> verified: oat ported (root `oat/` library + `oat/bin/oat.ml`), `Mod/` +
> `skill/` copied (now under `oat/`) (path pass done), Makefile + `test/integration.sh` +
> `.gitignore` in place; `make po-image` builds, `make test-po` passes 29/29,
> `dune test` green, parity vs Rust oat spot-checked (one known divergence:
> duplicate CLI options are last-wins here, clap rejects them; the 0F1X header
> strip applies only to GET payloads, where Rust strips in every from_oberon;
> plus the intentional text-fold divergence below). Unit tests are in:
> `test/test_oat_{protocol,retry,tools,transport,cli,error}.ml` (124 checks)
> plus `strip_text_header` coverage in `test_convert.ml` — all green.
> **Part 1 is complete.** Deferred to the final docs pass: README /
> test/README updates. Part 2 (screenshots) not started. Nothing committed.

Goal: make this emulator a self-contained debug/test target for coding agents.
Two-part job, agreed 2026-07-16. This file is the working plan so a fresh
session can pick up mid-implementation; retire it when done (repo habit — see
commit "retire the porting plan").

Background: `../oberon-agent` (same author) drives a *live* Oberon over the
serial line: `oat` (stateless Rust CLI, one request per invocation) talks a
4-opcode wire protocol to `AgentTool.Mod`/`AgentProtocol.Mod` running inside
Oberon. The Rust `oat` already works against this emulator today
(`--serial-in/--serial-out` FIFOs compose with `--headless`, bin/app.ml:74).
We are porting it in and making this repo self-contained, plus adding
screenshots so an agent's loop closes: spawn headless emu → oat write/compile/
call → screenshot → iterate.

## Part 1 — port oat as-is

"As-is" = exact same functionality, subcommands, flags, defaults, output
formats, and exit codes, so `oat/skill/oberon-agent/SKILL.md` and agent muscle
memory work identically against either binary. Idiomatic OCaml, reuse what the
repo has, no new deps expected (Unix only).

### Source of truth (read these when implementing)

- `../oberon-agent/oat/src/` — 8 files, ~2.1k lines:
  `main.rs` (entry), `cli.rs` (clap surface + dispatch + output formatting),
  `protocol.rs` (frame grammar), `transport.rs` (FIFO pair + PTY raw mode),
  `retry.rs` (desync re-send), `text.rs` (host↔device text), `tools.rs`
  (semantics per subcommand, incl. EDIT fallback and compile-log parsing),
  `error.rs` (error→exit-code mapping).
- `../oberon-agent/Mod/` — the device side (copied verbatim, see below).
- `../oberon-agent/Makefile` — image-build pipeline (ported, see below).
- `../oberon-agent/test/integration.sh` — live battery (ported, see below).

### Wire protocol (host is master; all ints u32 LE; names are 1-byte len + chars)

- Request: `0xA5` sync, opcode `PUT=1 GET=2 CALL=3 EDIT=4`, op-specific body.
- Response: `0x5A` sync, status byte, u32 payload length, payload.
- Status: `0 Ok, 1 NotFound, 2 Trapped, 3 Error, 4 NoMatch, 5 NotUnique`
  (NotUnique payload = u32 occurrence count); unknown bytes kept as `Other`.
- PUT name,len,bytes (device cap 64 KiB `maxPut`); GET name → file bytes;
  CALL cmd,parlen,par → payload is the **Oberon.Log delta** written while the
  command ran (Trapped delta carries the trap line);
  EDIT name,oldLen,OLD,newLen,NEW — OLD ≤ 1024 (`editLim`/`EDIT_OLD_LIMIT`,
  keep in sync), client falls back to GET+local replace+PUT beyond.
- A lost byte device-side aborts the frame with **no reply** → client timeout.

### CLI surface (parity required)

- Transport: `--serial PATH` (real PTY/UART) xor `--serial-in FIFO --serial-out
  FIFO` (paired; named from the **emulator's** perspective: `--serial-in` is
  the FIFO the emulator reads, oat writes). Mixed/half-paired forms rejected.
- Globals: `--timeout 15.0` (secs), `--baud 115200`, `--char-delay-us 600`,
  `--retries 3`. Retries and char-delay apply **only** to `--serial` (real
  line, lossy); the FIFO path is lossless → retries forced to 0, no pacing.
- Subcommands: `check`, `read PATH`, `write PATH` (stdin), `edit PATH OLD NEW`,
  `delete PATH`, `list-files [PREFIX]`, `list-modules`,
  `compile NAME [--new-symbol|/s equivalent]`, `load NAME`, `unload NAME`,
  `call CMD [ARGS]`.
- Exit codes: `0` ok; `1` tool-level (not found, compile failed, unload
  refused, trap); `2` transport/protocol (no connection, timeout, bad frame,
  bad args). Match cli.rs output strings (e.g. `ok: <version> (round-trip
  Nms)`, the no-version warning in `check`, `print_log` trailing-newline rule).

### OCaml layout

- **DECIDED (supersedes earlier flat-`tools/` idea): a dedicated root `oat/`
  directory** holding a wrapped dune library `(name oat)` — modules
  `Oat.{Error,Protocol,Transport,Retry,Tools,Cli}` (short names internally,
  no `oat_` prefixes) — with the executable at `oat/bin/oat.ml` →
  `_build/default/oat/bin/oat.exe`. CLI parsing stays in the library
  (`Oat.Cli`) so it is unit-testable, per the `bin/cli.ml` precedent; it is
  hand-rolled in `tool_cli.ml`/`bin/cli.ml` style — no cmdliner.
- **Text conversion — DECIDED (supersedes earlier note): reuse `Convert`.**
  `Convert.strip_text_header` was added (exposed, not folded into
  `Convert.from_oberon`, so ob2txt semantics are untouched); `oat_tools` maps
  device text via `Convert.to_oberon`/`from_oberon` + the strip. Intentional
  divergence from Rust oat: `to_oberon` folds UTF-8→Latin-1 instead of
  passing raw UTF-8 bytes, so non-ASCII writes round-trip on read. There is
  no `oat_text` module.
- Transport notes: Rust uses rustix `poll` (timed reads) + termios raw mode.
  OCaml: `Unix.select` for the read timeout, `Unix.tcsetattr` raw mode with
  `c_ibaud/c_obaud` from `--baud`; `Unix.sleepf` for the per-byte char delay;
  port `drain_stale` (flush leftover response bytes before each request).
  FIFO non-blocking open prior art: `lib/raw_serial.ml`.

### Copy verbatim (make repo self-contained)

- `Mod/Common/AgentProtocol.Mod`, `Mod/ProjectOberon/{AgentTool.Mod,
  Oberon.Mod.patch}`, `Mod/ExtendedOberon/{AgentTool.Mod, Oberon.Mod.patch}`
  → `oat/Mod/` mirroring oberon-agent’s `Mod/`. The patches modify the stock
  `Oberon.Mod` (related to version reporting — `oat check` parses it).
- `skill/oberon-agent/SKILL.md` → `oat/skill/oberon-agent/SKILL.md`,
  **with a path pass**: oat discovery locations, emulator invocation
  (`dune`-built binaries), image names/targets must be true in this repo.
  Content otherwise verbatim.

### Image-build Makefile (port of ../oberon-agent/Makefile)

Root `Makefile`; tools come from `dune build` (reference
`_build/default/...` paths). Per variant V ∈ {po, eo}:

1. extract stock source (`extract_source.exe`) →
   - PO stock: `DiskImage/Oberon-2020-08-18.dsk` (already vendored here);
   - EO stock: download `S3RISCinstall.tar.gz`, pinned:
     commit `bf51d8087e04838a1c474ec750004e80055337a6`,
     sha256 `3354a7d449377f7defe8df7d3d27b5972a35bb48ebfeb8e3e73762b28c810d12`,
     URL `https://github.com/andreaspirklbauer/Oberon-extended/raw/<commit>/Documentation/S3RISCinstall.tar.gz`,
     extract member `S3RISCinstall/RISC.img` → eo stock dsk;
2. copy to `build/<v>-src/`; for each `Mod/<Variant>/*.patch`:
   `ob2txt` the stock module → `patch(1)` → `txt2ob`;
3. for each `oat/Mod/Common/*.Mod` + `oat/Mod/<Variant>/*.Mod`: copy as `.txt`,
   `txt2ob` into the tree;
4. `build_po_image.exe` / `build_eo_image.exe` → `DiskImage/ProjectOberon.dsk`
   / `DiskImage/ExtendedOberon.dsk`.

Targets: `image` (default, both), `po-image`, `eo-image`, `po-emu`/`eo-emu`
(boot on FIFO pair, `check-fifos` guard), `test-po`/`test-eo` (live battery),
`clean`. **Divergence from upstream**: `clean` must NOT `rm -rf DiskImage`
(the stock image is vendored here) — remove only `build/` and the two built
images. `.gitignore`: `build/`, `DiskImage/ProjectOberon.dsk`,
`DiskImage/ExtendedOberon.dsk`. System deps `patch`/`curl|wget` are
build-time-only, as upstream.

### Tests

- Unit (in `dune test`, matching this repo's test layout/style — see
  `test/README.md`; strict 1:1 porting of Rust tests not required, cover what
  matters): frame encode/decode against golden byte sequences (device-role
  parse/encode helpers like protocol.rs has, so tests can fake the device);
  text conversion (CRLF collapse, 0xF1 header strip); CLI parsing (serial
  forms exclusive-and-paired — port that exact test); status→exit-code
  mapping; EDIT >1024 fallback path via an in-memory fake `Request` (the
  tools.rs test seam).
- Live battery: port `integration.sh` — boot `risc.exe --headless` on a
  private FIFO pair with DISPLAY/WAYLAND_DISPLAY scrubbed, drive the full oat
  surface (write/read/edit wire+fallback+error statuses, compile, call, list,
  delete; EO adds edit→compile→unload→reload hot swap). Opt-in like
  `@cosim`/`OBERON_ROUNDTRIP` (needs a built agent image): reachable via
  `make test-po`/`test-eo`, not `dune test`.

## Part 2 — screenshots

Decisions (all settled):

- **Naming**: mpv semantics — scan cwd for the lowest unused
  `risc-shot%04d.png` at each capture (never overwrites across sessions).
  Atomic: write to a temp name in the same dir, rename into place, so the
  file appearing means it's complete.
- **Triggers**: (a) `--shot-frames=N1,N2,...` valid only with `--frames`
  (error otherwise); sorted/deduped; N > `--frames` ignored; shot taken after
  frame N (1-based, same counting as the golden checkpoints). (b) Windowed
  mode: **F10** hotkey (F12=reset, F11=fullscreen are taken). No trigger for
  live headless sessions — rejected on purpose (see decisions log); agents
  re-run deterministically with adjusted `--shot-frames`.
- **Format**: PNG grayscale via **`imagelib`** (+ `decompress` transitively) —
  the one new dependency of this whole plan. Pure OCaml, no system libs, so
  capture works headless and in tests. Note: `ImageLib_unix.writefile`
  dispatches on file extension, which fights temp+rename — call the PNG
  writer directly with a chunk_writer instead.
- **Placement**: capture module lives with the frontend (`bin/`), not
  `lib/risc_core` — both triggers are frontend concerns and this keeps
  `imagelib` out of the core lib (validate/bench stay dep-free). Build the
  image from `Core` accessors: `fb_width`/`fb_height`/`framebuffer_word`.
- **Pixel geometry** (verify against `bin/render.ml` when implementing):
  framebuffer rows are bottom-up; each word is 32 pixels, LSB-first order as
  render.ml decodes; set bit = white. Always capture the native framebuffer
  (honors `--size`), never the scaled SDL window.
- Determinism: capture is a pure read — golden FNV hashes unaffected.
- Tests: encoder round-trip (synthetic framebuffer → PNG → decode back via
  imagelib and compare pixels; avoid PNG-byte goldens, encoder output may
  change across imagelib versions); naming-scan logic; CLI parsing of
  `--shot-frames` incl. the requires-`--frames` error.
- `dune-project` gains the `imagelib` dep; regenerate the `.opam` file.

## Decisions log (don't re-litigate)

- **SIGUSR1 / job-file / control-socket shot trigger: rejected.** Keep it
  simple; deterministic re-run with `--shot-frames` covers headless.
- **Glyph-decoding screen text: parked.** Graphics output makes it low-value;
  screenshots + vision cover it.
- **System.Log reading: cut for now, rethink later.** Discovery to remember:
  `AgentProtocol.DoCall` already returns the Oberon.Log delta written during
  each command (`ReplyLog`), so the compile/debug loop's log arrives via oat.
  Only *async* log (boot messages, background tasks) is uncovered; the parked
  idea is a `LOG` opcode in AgentProtocol ("send Oberon.Log from pos N") +
  `oat log` — OS-side, works on real FPGA too. No emulator-side log
  machinery ever (heap introspection and extra MMIO ports both rejected).
- **Hand-rolled PNG encoder: rejected** in favor of `imagelib` (dep OK, keep
  minimal).
- **`oat screenshot` subcommand: not now** (screenshot is emulator-side; oat
  stays pure serial client).
- **Image pipeline as OCaml tool: not now** — port the Makefile as-is.

## Order of work

1. oat port: `oat_text` → `oat_protocol` → `oat_transport` → `oat_retry` →
   `oat_tools` → `tools/bin/oat.ml`, with unit tests per module as we go.
2. Self-containment: copy `Mod/` + skill (path pass), root Makefile,
   `.gitignore` entries, live battery script, `make test-po`/`test-eo`.
3. Screenshots: `imagelib` dep, capture module + naming scan, `--shot-frames`
   in `bin/cli.ml` + headless loop, F10 in the hotkey handler + SDL loop.
4. Docs pass: README (host-tools section for oat, agent images + Makefile,
   options table `--shot-frames`, hotkey table F10, skill pointer),
   `test/README.md` (new tests + live battery), then **delete this plan.md**.

## Verification checklist

- `dune build` clean; `dune test` green (new unit tests included).
- Golden boot hashes unchanged (screenshot is read-only; no core changes).
- `dune build @cosim` untouched/green.
- `make po-image` builds; `make test-po` battery passes against the OCaml
  emulator + OCaml oat end to end. (`eo-image`/`test-eo` need network once.)
- Behavior parity spot-check: run Rust oat and OCaml oat against the same
  booted image; same outputs and exit codes on the full subcommand sweep.
- The Life.Mod loop works: headless boot on FIFOs → `oat write/compile/call`
  → re-run with `--shot-frames` → `risc-shot0001.png` readable.
