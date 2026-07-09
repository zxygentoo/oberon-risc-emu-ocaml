# Porting the host-tools to OCaml — plan

Status: **implemented and oracle-verified** (pending your review; nothing committed).
All five in-scope tools — `ob2txt`, `txt2ob`, `extract-source`, `build-po-image`,
`build-eo-image` — plus the shim runtime the packers need are built and tested. The
two dev tools (`eo-driver`, `eo-inner-run`) were left out of scope as agreed. The
sections below are the design that was followed; see **Implementation status** next
for what landed and how it was verified against the Rust oracle.

## Implementation status

Built (all under `tools/`, plus the shim in `lib/`), matching the layout in §2:

- **`lib/oberon_name.ml`** — the shared `name_char_ok` predicate.
- **`lib/io.ml`** — `type shim` callback record (the module-cycle fix from §4.1).
- **`lib/risc.ml`** — `shim` field, MMIO routing in `load_io`/`store_io` (device/
  wrapper split), and `For_shim` (`configure_shim`/`boot_inner_core`/`shim_run`).
- **`lib/shim.ml`** — the full Norebo runtime (all ~20 syscalls, file ABI, stdio,
  wall-clock, `Fun.protect` flush).
- **`tools/`** — `convert`, `packonly`, `image`, `resolve`, `pipeline`,
  `builder_cli`, `seed_po`, `seed_eo`; assets embedded via `ocaml-crunch`
  (`Assets_data`, a dune rule = the `include_bytes!` analogue).
- **`tools/bin/`** — `ob2txt`, `txt2ob`, `extract_source`, `build_po_image`,
  `build_eo_image`.
- **`assets/`** — the 44 vendored files, copied verbatim.
- **Tests** — `test_convert` (8), `test_packonly` (3), `test_image` (15),
  `test_resolve` (11), `test_pipeline` (10), `test_shim` (17), all ported from the
  Rust unit tests; plus `test_build_roundtrip` (opt-in via `OBERON_ROUNDTRIP=1`).
  The full existing emulator suite (cosim, boot golden, fp-vectors, …) still passes,
  so the core `shim` hooks don't regress CPU behaviour when the shim is inactive.

Oracle results (vs. the Rust `target/debug` binaries):

- `extract-source` → **byte-identical** output tree (60 files, incl. `.packonly`).
- `ob2txt`/`txt2ob` → **byte-identical** both directions on real Oberon sources.
- shim → compiling modules (incl. cross-module symbol files) produces
  **byte-identical** `.rsc`/`.smb` and matching exit codes, on both the PO and EO
  bootstrap cores.
- `build-po-image` → a full 38-module Project Oberon build yields a
  **byte-identical** `Oberon.dsk` (991232 bytes, `cmp` clean) to the Rust builder.
- `build-eo-image` shares the whole (proven) pipeline; its EO seed boots and compiles
  byte-identically. A full EO *image* diff needs an EO source tree, absent here.

Deviations from the plan below: none of substance. Assets use `ocaml-crunch`
(option 1 in §2); CLIs are hand-rolled (no `cmdliner`); the shim's `OBERON_TRACE`
zero-instruction early-dump is omitted (it only changes *when* a diagnostic prints
on an abnormal exit, not the exit code).

---

Status: **proposal for review.** This maps five of the
seven host-side tools in `oberon-risc-emu-rs/crates/host-tools` — the two text
converters, the source extractor, and the two image builders (the "dsk packer") —
onto this OCaml port. The two dev tools (`eo-driver`, `eo-inner-run`) are out of
scope. Covers module layout, dune wiring, and — the crux — the CPU-core change the
headless "shim" runtime the packer needs. Effort is relative (S/M/L/XL), not calendar
time.

---

## 1. Summary & recommendation

| Tool | Rust LOC | Tier | Needs | Effort |
| --- | --- | --- | --- | --- |
| `ob2txt` | 72 | A | nothing | S |
| `txt2ob` | 85 | A | nothing | S |
| `extract-source` | 159 + `image` 411 + `packonly` 64 | A | Oberon-FS reader | M |
| `shim` (Norebo runtime) | 723 + core hooks | B | **core change** | **XL** |
| `build-po-image` | 166 | C | shim + pipeline + assets | M |
| `build-eo-image` | 169 | C | shim + pipeline + assets | M |
| `resolve` + `pipeline` | 308 + 371 | C | shim | L |
| `eo-inner-run` | 43 | C | shim | S |
| `eo-driver` | 304 | C | full headless boot | M |

**The whole of Tier C rides on one thing: the shim.** It is the single hard rock.
Everything else is pure byte/logic porting that this repo's existing `unix`/`Stdlib`
surface already covers.

**Recommended sequence** (each phase is independently shippable):

1. **Phase 1 — Tier A.** `ob2txt`, `txt2ob`, `extract-source`. Pure, no emulator,
   ships with ported tests. Immediately useful (crack open any `.dsk`, author
   sources in Oberon's native CR/Latin-1 form). Zero risk.
2. **Phase 2 — the shim.** The Norebo headless runtime + the core hook it requires.
   This is where the schedule risk lives (getting a full Oberon compile to run
   headless and byte-match the golden inner core). De-risked by `eo-inner-run` as
   the first consumer and `OBERON_TRACE` tracing.
3. **Phase 3 — image builders.** `resolve`, `pipeline`, asset embedding, and the two
   `build-*-image` binaries. Comparatively mechanical once the shim boots.
4. **Phase 4 — dev tools.** `eo-inner-run` (trivial once the shim exists) and
   `eo-driver`. Most of `eo-driver`'s dependencies (`Pclink`, `Disk`, `Headless`)
   are already ported.

---

## 2. How it lands in the OCaml repo

### Current structure

- `lib/` → one library `risc_core` (`(libraries unix)`), `.ml` + `.mli` per module.
- `bin/` → library `oberon_frontend` (ps2/render/cli/sdl_clipboard) + executable `risc`.
- `test/` → `risc_core` tests, frontend tests, QCheck, cosim.
- CLI is **hand-rolled** (`bin/cli.mli`: "port of the `getopt_long` block"), no
  `cmdliner`; deps are only `tsdl`, `qcheck-core`, `unix`.

### Proposed layout

```
lib/                         (existing risc_core library — MODIFIED + 2 new modules)
  io.ml/.mli                 + type shim = { ... } callback record
  risc.ml/.mli               + mutable shim field; load_io/store_io shim branch;
                               For_shim submodule (configure_shim/boot_inner_core/shim_run)
  oberon_name.ml/.mli        NEW — name_char_ok + read_name/valid_name predicates
  shim.ml/.mli               NEW — Norebo host + syscall ABI (in risc_core)

assets/                      NEW — the 44 vendored files, copied verbatim from the rs repo
  README.md  common/  po/  eo/

tools/                       NEW library `oberon_tools` (depends on risc_core)
  image.ml/.mli              Oberon on-disk FS reader
  packonly.ml/.mli           .packonly manifest parse/render
  resolve.ml/.mli            compile-order resolution (topo sort)
  pipeline.ml/.mli           disk-image build pipeline
  seed_po.ml  seed_eo.ml     embedded toolchain tables (generated, see §5.3)
  packonly_help.ml           shared --help epilogue
  dune

tools/bin/                   NEW — the seven executables (thin)
  ob2txt.ml  txt2ob.ml  extract_source.ml
  build_po_image.ml  build_eo_image.ml
  eo_inner_run.ml  eo_driver.ml
  dune
```

Why the shim lives in `lib/` (risc_core), not `tools/`: it needs the CPU-internal
`single_step` and the RAM/register fields. Keeping `shim.ml` in the same library as
`risc.ml` lets `Risc.For_shim` reach internals directly, while `tools/` depends on
`risc_core` for `Shim.run`. `ob2txt`/`txt2ob` depend on neither and could be
standalone, but grouping all seven bins under `tools/bin` is simpler.

### Decision — CLI parsing

House style hand-rolls with the equivalent of `getopt_long`. The Tier-A tools and
`eo-inner-run` have trivial CLIs (1–2 positionals, one flag) — hand-roll with stdlib
`Arg` or a tiny matcher, zero new deps. `eo-driver` has **10 flags**; it is the only
one where `cmdliner` would earn its keep. **Recommendation:** hand-roll all of them
for dependency-parsimony and house-style consistency; revisit `cmdliner` only if
`eo-driver` feels unwieldy. (Flagged as an open decision in §8.)

### Decision — asset embedding

Rust uses `include_bytes!` (26 per builder) → assets compiled into `.rodata`, fully
self-contained binary. OCaml has no `include_bytes!`. Options, best-fit first:

1. **`ocaml-crunch`** (build-only dep `crunch`): a dune rule embeds the `assets/`
   tree as string constants; a hand-written `seed_po.ml`/`seed_eo.ml` assembles the
   flat `(name, bytes) array` mirroring the Rust `TOOLCHAIN` list line-for-line.
   Closest to `include_bytes!`, standard in the dune ecosystem. **Recommended.**
2. Custom dune `(rule ...)` running a small generator that emits the `(name, bytes)`
   table directly. More control, one more script to maintain.
3. Ship assets as installed data files, resolved at runtime. Simplest, but abandons
   the self-contained-binary property the rs `assets/README.md` explicitly calls out.

Total assets are ~379 KB / 44 files; string-literal embedding cost is modest.
Copy `assets/README.md` too (ISC provenance: project-norebo + Extended Oberon).

---

## 3. Phase 1 — Tier A: pure converters + extractor

No emulator dependency. Everything here maps to `Bytes`/`In_channel`/`Out_channel`.

### 3.1 `ob2txt` / `txt2ob`

Pure byte transforms between Oberon (Latin-1, CR separators) and host (UTF-8, LF):

- **ob2txt**: each byte → its Latin-1 code point; `"\r\n"`→`"\n"`, then `"\r"`→`"\n"`.
  Writes `<FILE>.txt`, leaves the original.
- **txt2ob**: `"\r\n"`→`"\n"`→`"\r"`; code points ≤ `0xFF` → one byte, else `'?'`.
  Input must end in `.txt`, dropped to form the output name.

Note: a Latin-1 byte `0xE4` maps to `ä` (two UTF-8 bytes) on the way out and back to
one byte on the way in — so the transform is not a straight byte identity; port the
`char::from(b)`/`c as u32 <= 0xFF` logic exactly. Carry over the four unit tests each
(cr→lf, crlf collapse, latin1 round-trip, beyond-latin1→`?`).

### 3.2 `image.ml` — the Oberon on-disk filesystem reader

Read-only reader for the Project Oberon FS, mirroring `assets/common/VFileDir.Mod`.
This is the substantive part of Phase 1.

**Format constants** (1024-byte sectors; on-disk pointers are `DiskAdr = sector*29`,
so `sector = adr / 29`, floored):

```
SECTOR_SIZE 1024   FN_LENGTH 32   SEC_TAB_SIZE 64   EX_TAB_SIZE 12
INDEX_SIZE 256     HEADER_SIZE 352  DIR_ROOT_ADR 29 (sector 1)
DIR_PG_SIZE 24     MAX_DIR_DEPTH 64 (defensive)     DIR_ENTRY_SIZE 40
DIR_MARK 0x9B1EA38D   HEADER_MARK 0x9BA71D86   SD_FS_OFFSET 0x10000400
```

**FileHeader** (first sector of a file): `mark@0`, `name@4[32]` (unused — names come
from the directory), `aleng@36` (i32, last-page index), `bleng@40` (i32, bytes in last
page), `date@44` (unused), `ext@48[12]` (index-sector DiskAdrs), `sec@96[64]` (direct
page DiskAdrs), file data from `@352`. **File size = `aleng*1024 + bleng - 352`.**

**Directory page** (B-tree node): `mark@0`, `m@4` (i32 entry count, clamp `0..24`),
`p0@8` (subtree < e[0]), `e@64[24]` where each entry is `name[32] + adr@32 + p@36`.

**Reconstruction** (`read_file header`): for `page` in `0..=aleng`, resolve to a data
sector — `page<64` → `sec[page]`; else `i=(page-64)/256, j=(page-64)%256`, error if
`i>=12`, read index sector `ext[i]`, take the DiskAdr at `j*4`. Page 0 contributes
bytes `352..end`, later pages `0..end`, `end = bleng` on the last page else `1024`.

**Traversal** (`entries`): in-order B-tree walk from `DIR_ROOT_ADR`, `p0` first then
each entry's `p`, yielding names in ascending order; cycle guard via a visited-sector
set, depth cap `MAX_DIR_DEPTH`.

**Base-offset probe** (`open`): read whole file, try base `0` (raw `.dsk`) then
`SD_FS_OFFSET` (full SD `RISC.img`), first with a valid `DIR_MARK` at sector 1 wins.

**OCaml notes:**
- LE reads via `String.get_int32_le`. Unsigned fields (marks, all DiskAdrs) →
  `Int32.to_int x land 0xFFFFFFFF`; signed fields (`aleng`/`bleng`, read signed *so
  corruption is rejected*) → plain `Int32.to_int`. Use `_le`, never `_ne`.
- Hold the image as one immutable `string` + `base:int`; index fields directly, skip
  Rust's per-sector 1024-byte copy. Keep the **upfront whole-sector bounds check** so
  errors are the clean "disk address points past the end" rather than a generic
  `Invalid_argument`.
- **Overflow ordering matters more here than in Rust:** OCaml `int` wraps silently
  with no debug-panic net. Preserve validate-then-compute order exactly (`s==0` before
  `s-1`; `aleng<0 || bleng<0` before using them as bounds).
- Preserve the exact validation error strings (they are the behavioral spec):
  `"not an Oberon filesystem image (no directory mark at sector 1)"`,
  `"file header has the wrong mark"`, `"file header has an invalid length"`,
  `"file is too large (extension table overflow)"`, `"invalid disk address 0"`,
  `"disk address points past the end of the image"`,
  `"directory page has the wrong mark"`,
  `"directory tree is too deep (corrupt image?)"`,
  `"file header length is inconsistent"`.
- Name decoding is *easier* than Rust: no UTF-8 validity to protect; collect accepted
  bytes into a `Buffer`. Depends on `name_char_ok` (see `oberon_name.ml`, §4.1).
- Port `image.rs`'s ~160 lines of unit tests — they pin the byte offsets (the `328`/
  `366`-byte tail figures, the `["A","M","Z"]` order, the depth-64 rejection).

### 3.3 `packonly.ml`

Pure manifest logic, no I/O. One name per line; truncate at first `#`, trim, drop if
empty. Parsed into a **sorted set** (`Set.Make(String)` — the order is load-bearing
for reproducibility; `String.compare` is byte-wise, unambiguous for the ASCII
charset). `render` emits a fixed 3-line comment header then one name per line;
`parse(render x) = x`. Signatures: `parse : string -> StringSet.t`,
`render : StringSet.t -> string`.

### 3.4 `extract-source`

CLI: `<DISK_IMAGE> <OUTPUT_DIR> [--keep-objects]`. Algorithm:

1. `Image.open` + `mkdir -p OUTPUT_DIR` (does not clean stale files).
2. `compiled` = stems of every `.rsc` entry ("module X has an object present").
3. For each entry: skip `.rsc`/`.smb` unless `--keep-objects`; write every other file
   **byte-for-byte** (no charset conversion — that's `ob2txt`'s job); a `X.Mod` whose
   `X.rsc` exists is a compile candidate (not pack-only), everything else extracted is
   recorded pack-only; kept objects are never pack-only.
4. Always (re)write `.packonly` via `Packonly.render`.
5. Print a one-line summary.

Pack-only set formula: `extracted − {X.Mod : X.rsc present} − {kept objects}`.

**OCaml notes:** `read_file` errors are best-effort (log to stderr, continue); write
errors abort. Reproduce the `write_file` traversal guard as a content check (reject a
name containing `Filename.dir_sep`) rather than hunting a `Path::parent` equivalent —
names already passed the charset filter so it never fires, it's defense-in-depth.
Test against the repo's `DiskImage/*.dsk` (the rs golden yields 60 sources, 22
pack-only).

---

## 4. Phase 2 — the shim (Norebo headless runtime)

A port of `risc_core::shim` (a port of project-norebo's `norebo.c`): boot an
`InnerCore` image, route the **whole** MMIO region to a host that maps Oberon
Kernel/Files/FileDir syscalls onto the host filesystem, run one Oberon command
(e.g. `ORP.Compile Foo.Mod/s`) to completion, return its exit code.

### 4.1 Core changes — the integration seam (the one non-mechanical decision)

Today `lib/risc.ml` hard-wires MMIO: `load_word`/`store_word` fall through to
`load_io`/`store_io` (risc.ml:100–172), which `match` on the FPGA device options.
There is no way to reroute all of MMIO, and `reset` always jumps to the boot ROM.
The shim needs four seams the core does not expose. In Rust these are `pub(crate)`
hooks on `Risc` (`configure_shim`, `set_shim`, `boot_inner_core`, `shim_run`) plus a
`shim: Option<Box<Host>>` field consulted at the top of `load_io`/`store_io`.

**The OCaml wrinkle: no mutual recursion between modules.** Rust's `risc.rs ↔ shim.rs`
cycle is illegal in OCaml. Resolve it with a **shared callback record in `io.ml`** (no
cycle: `Io` depends on nothing, `Risc` depends on `Io`, `Shim` depends on both):

```ocaml
(* io.mli *)
type shim =
  { shim_load  : int -> int              (* offset (addr - io_start) -> value    *)
  ; shim_store : int -> int array -> unit (* offset -> guest RAM -> unit (writes) *)
  ; shim_exit  : unit -> int option      (* Some code once the guest has halted   *)
  }
```

Then in `risc.ml`:

- Add `mutable shim : Io.shim option` to `type t` (default `None`).
- **`load_io`**: if `t.shim = Some s`, `return s.shim_load (U32.sub address io_start)`
  before the device `match`. **`store_io`**: if `Some s`,
  `s.shim_store (U32.sub address io_start) t.ram; return` before the device `match`.
  (The Rust disjoint-borrow dance is a non-issue — just hand over `t.ram`.)
- **`For_shim` submodule** (mirroring the existing `For_tests` pattern in risc.mli),
  exposing three functions that touch internals directly:
  - `configure_shim t mem_bytes` — `mem_size = display_start = display_end = mem_bytes`
    (flat RAM: neither the framebuffer-damage branch in `store_word` nor the io
    fallthrough fires within RAM), reallocate `ram`. No ROM patch, no framebuffer.
    **Note** this repo now has a separate `display_end` field — it must also equal
    `mem_bytes`.
  - `boot_inner_core t image stack_org` — parse the image as LE records
    `(len:u32, addr:u32, bytes[len])` terminated by `len=0`, bounds-check
    `addr+len <= mem_size`, poke into `ram`; then seed `ram.(3)=mem_size`,
    `ram.(6)=stack_org`, `pc=0`, `r=[|0..|]`, `r.(12)=0x20`, `r.(14)=stack_org`,
    `h=0`, `flags=0`. (Contrast normal boot: `pc = rom_start/4`, fetch from ROM.)
  - `shim_run t : int` — the shim's **own** loop (not `run`, which idle-yields on
    `progress`): each iteration, if `t.shim`'s `shim_exit ()` is `Some code` return it;
    if `pc >= mem_size/4` print "PC left RAM" and return 1; decrement an instruction
    budget (start `64_000_000_000`), return 1 on exhaustion; else `single_step t`.
    Optional `OBERON_TRACE` 256-entry `(pc,ir)` ring + register dump on abnormal exit.
- `set_shim t s` (a plain setter) installs the `Io.shim`.

`oberon_name.ml` (new, in risc_core so both `Shim` and `tools/image` can use it):
```ocaml
let name_char_ok i ch =
  (* leading letter, then letter/digit/'.' *)
  is_ascii_alpha ch || (i > 0 && (ch = '.' || is_ascii_digit ch))
```
plus `read_name mem adr` (32-byte field, NUL-terminated, empty is valid, illegal char
or no NUL → `None`) and `valid_name bytes` (for directory entries: non-empty,
`len < 32`, every byte ok).

### 4.2 `shim.ml` — the host + syscall ABI

`Shim.run : string list -> cwd:string -> path:string list -> (int, string) result`
(mirrors `run(args, cwd, path) -> io::Result<i32>`). Body: locate `InnerCore` (cwd
first, then each `path` dir), build the `Host` state and the `Io.shim` record closing
over it, `Risc.make ()`, `configure_shim MEM_BYTES` (8 MiB), `set_shim`,
`boot_inner_core image STACK_ORG` (`0x00080000`), then run under `Fun.protect` so files
+ stdout flush on every exit path (OCaml has no `Drop`).

**Constants:** `MEM_BYTES = 8*1024*1024`, `STACK_ORG = 0x00080000`, `MAX_FILES = 500`,
`MAX_FILE_BYTES = 1 lsl 30`, `NAME_LEN = 32`, `OBERON_DATE = (24<<26)|(5<<22)|(27<<17)|(12<<12)`.

**MMIO offsets** (relative to `io_start = 0xFFFFFFC0`), via the `Io.shim` callbacks:

- *load*: `0` → wall-clock ms (`Unix.gettimeofday`, **not** the synthetic clock);
  `8` → one stdin byte or `0xFFFFFFFF` at EOF; `12` → `3` (status const); `48/52/56`
  → `sysarg[2/1/0]`; `60` → `sysres`; else `0`.
- *store*: `8` → putchar to buffered stdout; `48/52/56` → `sysarg[2/1/0]`; `60` →
  **fire syscall** `sysres := sysreq value ram`; else ignore.
- **Keep the reversed arg mapping:** guest writes args to 56/52/48 (→ arg0/1/2) then
  the syscall number to 60.

**Syscall table** (`sysreq n`; `0xFFFFFFFF` is the universal error sentinel):

| n | name | effect |
| --- | --- | --- |
| 1 | Norebo.Halt | `exit := Some a0`; 0 |
| 2 | Norebo.Argc | `List.length args` |
| 3 | Norebo.Argv(i,adr,siz) | copy `args[i]` (≤`siz-1` bytes, NUL-fill) to `adr`; ret full len; bad i→err |
| 4 | Norebo.Trap(t,name,pos) | map 1–7 to a message, print to stderr, `exit := Some (100+t)` |
| 11 | Files.New(adr) | anonymous in-memory file; ret handle or err |
| 12 | Files.Old(adr) | `cwd/name` (rw, persist) → each `path/name` (ro); ret handle or err |
| 13 | Files.Register(h) | write `data` to `cwd/name` now; mark registered |
| 14 | Files.Close(h) | remove slot, flush if dirty & persist |
| 15 | Files.Seek(h,pos,whence) | whence 1=CUR,2=END,else SET; signed pos; clamp ≥0 |
| 16 | Files.Tell(h) | `pos` |
| 17 | Files.Read(h,adr,siz) | clamp siz to RAM; read min(siz,avail), zero-fill tail; ret read |
| 18 | Files.Write(h,adr,siz) | clamp; refuse if end>1 GiB; grow+copy; dirty; ret siz |
| 19 | Files.Length(h) | `len data` |
| 20 | Files.Date(h) | `OBERON_DATE` |
| 21 | Files.Delete(adr) | `Sys.remove (cwd/name)` |
| 22 | Files.Purge | no-op, 0 |
| 23 | Files.Rename(old,new) | `Sys.rename` in cwd |
| 31 | enumerate_begin | `Sys.readdir cwd` filtered by `valid_name`, store iterator |
| 32 | enumerate_next(adr) | write next name (32-byte buf) or NUL + err |
| 33 | enumerate_end | reset iterator |
| _ | — | print "unimplemented syscall n", `exit := Some 1` |

`OpenFile` = `{ mutable data; mutable pos; name; mutable persist:string option;
mutable registered; mutable dirty }`; table = `OpenFile option array` of 500. Byte
RMW over the `int array` RAM reuses the existing `store_byte`/`load_byte` pattern
(risc.ml:178–214); OOB reads → 0, OOB writes dropped, transfers clamp to RAM size.

**Host FS mapping:** flat names → `Filename.concat cwd name` for writes/rw opens;
inputs fall back to `path[i]` read-only (`persist=None` → never written back).
`Unix`/`Sys` cover read/write/remove/rename/readdir. **Explicit flush** on `Close`
and, via `Fun.protect ~finally`, for all still-open dirty files + stdout at the end of
`run` — the established idiom in `bin/risc.ml`'s `run_headless`.

### 4.3 Risks & how to de-risk

- The shim is where the schedule risk concentrates: a full Oberon compile must run
  headless and the relinked `InnerCore` must byte-match the committed golden. Bugs hide
  in the ABI (offset order, sentinels, clamps) and in `boot_inner_core`'s register seed.
- De-risk bottom-up: **`eo-inner-run` is the first consumer** — a 2-line wrapper that
  boots a committed bootstrap seed and runs one command. Get that green before touching
  the pipeline. `OBERON_TRACE` gives a ring buffer + register dump on abnormal exit.
- Wall-clock ms (offset 0) is intentionally non-deterministic; that's fine — build
  determinism comes from the pipeline diffing the relinked core against the golden, not
  from clock reproducibility.
- Add `shim` unit tests: a tiny hand-built InnerCore that writes a file / echoes argv /
  halts with a code, asserting the host FS side effects and exit code.

---

## 5. Phase 3 — image builders

### 5.1 `resolve.ml`

Pure logic, near 1:1. `Candidate = { file:string; module_:string }` (objects are named
by MODULE, not filename). `resolve sources visible`:

1. Read `sources/.packonly` (required; empty = compile everything) via `Packonly.parse`.
2. Validate every manifest entry exists in `visible`.
3. For each non-pack-only file, `parse_header` → `(module, imports)`; detect duplicate
   MODULE declarations.
4. `topo_sort` (Kahn), **tie-break on lexicographically smallest ready name** — this is
   a reproducibility guarantee, so use an ordered set (`Set.Make(String)`), never
   `Hashtbl`. Imports outside the node set (`SYSTEM`, toolchain modules, pack-only) are
   dropped; a real missing module surfaces later as a compile error. Leftover → cycle
   error.

`parse_header` is a small recursive-descent cursor over `bytes` (Latin-1, CR endings,
nesting `(* *)` comments): `MODULE [*] ident ;`, then if `IMPORT`, loop
`ident [":=" ident] [,]`, resolve `B := A` to depend on `A`, drop `SYSTEM`, stop at
the first non-`IMPORT` token.

### 5.2 `pipeline.ml`

`Seed = { toolchain : (string * string) array; golden_inner_core : string;
name : string }`. `build seed ~sources ~output : (unit, string) result` — compute the
compile set first (fail fast), build in a scratch dir `$TMPDIR/{name}-{pid}` with four
subdirs, copy only the final `Oberon.dsk` out on success, **leave the scratch dir on
failure** for inspection.

**Six shim boots, independent of source-tree size** (each batches an arbitrary module
list into one Oberon command line; each is a cold `Risc.make ()`):

1. `extract_toolchain` (write the seed flat) → compile the 18 `NOREBO_MODULES`
   (`Norebo Kernel FileDir Files Modules Fonts Texts RS232 Oberon ORS ORB ORG ORP
   CoreLinker VDisk VFileDir VFiles VDiskUtil`) with `/s`, `cwd=norebo`,
   `path=[toolchain, sources]`. **[shim 1]**
2. `bulk_rename norebo rsc→rsx`; `CoreLinker.LinkSerial Modules InnerCore`
   (`path=[toolchain]`) → `norebo/InnerCore`. **[shim 2]** Rename back.
3. Self-check `norebo/InnerCore == seed.golden_inner_core` — **warn only, never fail**
   (easy to accidentally "fix" into a hard error; keep it a warning).
4. Compile the 4 cross-compiler modules `ORS ORB ORG ORP`
   (`path=[sources, compiler, norebo]`). **[shim 3]**
5. `bulk_delete smb` in norebo + compiler.
6. Compile the full dependency-ordered source-tree `order` in one command. **[shim 4]**
   Then fail loudly if any expected `Module.rsc` is missing.
7. `bulk_rename oberon rsc→rsx`; `CoreLinker.LinkDisk Modules Oberon.dsk`
   (`path=[oberon, norebo]`) → `scratch/Oberon.dsk`. **[shim 5]**
8. `VDiskUtil.InstallFiles Oberon.dsk name=>name ...` — every visible source, every
   `Foo.rsx=>Foo.rsc`, every `Foo.smb=>Foo.smb`. **[shim 6]**

**The `.rsc`↔`.rsx` rename dance is load-bearing:** the *offline* `CoreLinker` reads
`.rsx` while the *live* shim module loader reads `.rsc`; both coexist in one dir.
Replicate the rename timing exactly. `find_file` search order (`cwd` first, then
`path` in order) is meaningful — use an explicit ordered list + first match.

Bootable layout (built by the embedded glue, not the pipeline): `CoreLinker.LinkDisk`
writes sector 0 as the leading word `9B1EA38DH` + zero-fill + the raw linked module
image (the Inner Core); `VDisk.InitSecMap` reserves the low sectors; `VDiskUtil`
copies files through the nested virtual disk, building the B-tree the `image.ml` reader
parses.

### 5.3 Assets + seeds

Copy the 44 files verbatim into `assets/`. Embed via `ocaml-crunch` (§2). `seed_po.ml`
and `seed_eo.ml` assemble the flat `(name, bytes) array` mirroring each Rust binary's
`include_bytes!` list line-for-line:

- **PO** (`assets/common` + `assets/po/{glue,bootstrap}`): glue `Norebo FileDir Files
  Kernel Oberon CoreLinker VDisk VFileDir VFiles VDiskUtil` (`.Mod`) + bootstrap
  `InnerCore` + 14 `.rsc` (`Kernel FileDir Files Modules Norebo Oberon CoreLinker Fonts
  Texts RS232 ORS ORB ORG ORP`); `golden_inner_core = po/bootstrap/InnerCore`.
- **EO**: same shape from `assets/eo/*`; note `eo/glue/Disk.Mod` exists but is **not**
  embedded (offline seed-regen only). Inner-core top module is `Modules` for both.

Keep the flat-namespace invariant (`.Mod` vs `.rsc` never collide). Keep
`packonly_help.ml` as one shared `--help` epilogue used by both builders + extract.

### 5.4 `build-po-image` / `build-eo-image`

Each is a thin `main`: parse `<SOURCES_DIR> <OUTPUT>`, call
`Pipeline.build SEED ~sources ~output`, print `Done: <output>` or the error + exit 1.
Identical but for the seed and the `name`.

---

## 6. Phase 4 — dev tools

### 6.1 `eo-inner-run`

Thin: `<DIR> <Module.Proc> [param...]` → `Shim.run command ~cwd:dir ~path:[dir]`; print
`guest exit code N` to stderr; process exit = guest code (host error → 1). ~1 hr once
the shim exists — and the ideal first shim consumer (§4.3).

### 6.2 `eo-driver`

Boots a full disk image headless, drives + observes it. Most dependencies already
exist in this port: `Risc` (`make/set_spi/set_serial/set_time/run/fb_width/fb_height/
mouse_moved/mouse_button/framebuffer_word`), `Disk.create`, `Pclink.in_dir`,
`Headless.{cpu_hz,fps,framebuffer_hash}`, `Io.serial`.

CLI (10 flags): `<IMAGE>`, `--frames 2000`, `--sample 30`, `--fb-out FILE.pgm`,
`--serial-out FILE`, `--move-to X,Y`, `--mid-click`, `--pclink-dir DIR`, `--after 180`,
`--push HOSTFILE` (repeatable). New but low-risk pieces:

- A local `CaptureSerial` returning an `Io.serial` closed over a `Queue`/`Buffer`
  (simpler than Rust's `Rc<RefCell<_>>`).
- **`advance`** threading a persistent `frame` ref through boot → click → each push →
  final settle. Do **not** call `Headless.run_frames` per phase — it resets its frame
  counter to 0, walking the synthetic ms clock backward. This divergence is
  load-bearing (present in the rs port for the same reason).
- `ink_density` (popcount / total bits) and `write_pgm` (P5, rows bottom-up since
  Oberon stores the screen bottom-up, each bit → one 0/255 byte) — pure pixel math via
  `framebuffer_word`. The one missing primitive is 32-bit popcount; promote the
  `popcount` already in `test/test_prop.ml` into `U32` (or `Oberon_name`/a util).
- PCLink push is host-side: copy the file into the pclink dir, write `PCLink.REC`, run
  frames so the already-installed `Pclink` device notices the job.
- Keep `1000/fps` and `cpu_hz/fps` as **integer** division (OCaml `/` truncates like
  Rust for positive operands) — don't "fix" to float or you break hash parity.

**Known rs quirk to decide on:** in `--pclink-dir` mode the serial-capture report is
always empty (the capture backend was replaced by `Pclink`), so `--serial-out` writes
an empty file. Preserve as-is or fix — flag it, don't silently change (§8).

---

## 7. Testing strategy

- **Port the Rust unit tests** alongside each module — `image.rs` (~160 test lines,
  the format's executable spec), `ob2txt`/`txt2ob` (4 each), `packonly`
  (round-trip), `resolve` (topo order, duplicate-module, cycle).
- **CLI integration tests** per binary: arg handling, exit codes, fail-clear paths.
  `extract-source` against the repo's `DiskImage/*.dsk`.
- **Shim smoke tests**: hand-built InnerCore exercising argv/file-write/halt.
- **Heavy round-trip** (`ignore`d, run explicitly): `build-po-image` rebuilds a source
  tree and the result boots identically to the golden. This exercises the shim end to
  end and is the real acceptance test for Phases 2–3. Fits this repo's existing golden/
  cosim testing culture.

---

## 8. Open decisions (for you)

1. **CLI library** — hand-roll all (recommended, zero new deps, house style) vs.
   `cmdliner` for `eo-driver`'s 10 flags.
2. **Asset embedding** — `ocaml-crunch` (recommended) vs. a custom dune generator vs.
   installed data files.
3. **Scope** — stop after Phase 1 (Tier A), or commit to the shim (Phases 2–4)?
4. **Dev tools** — port `eo-driver`/`eo-inner-run` at all? They're for hacking on the
   EO bootstrap; a pure user of the emulator doesn't need them.
5. **`eo-driver` serial-capture-in-pclink-mode quirk** — preserve the rs behavior or
   fix it.
6. **Where this plan lives** — this file is untracked at the repo root; keep it, move
   it under a `docs/`, or turn it into issues.

---

## 9. Milestones

| Milestone | Deliverable | Gates |
| --- | --- | --- |
| M1 | `ob2txt`, `txt2ob` + tests | — |
| M2 | `image`/`packonly`/`extract-source` + tests | — |
| M3 | Core hook (`Io.shim`, `For_shim`) + `shim.ml` + `eo-inner-run` green on the seed | M‑crux |
| M4 | `resolve`/`pipeline`/assets/`build-po-image`; golden round-trip passes | M3 |
| M5 | `build-eo-image` (needs an EO source tree) | M4 |
| M6 | `eo-driver` | M3 |

M1–M2 are Phase 1 (ship independently). M3 is the crux. M4 proves the whole stack.
