---
name: oberon-agent
description: Drive a live Project Oberon 2013 or Extended Oberon system via the `oat` CLI — read/write/edit files, compile, load/unload modules, run commands. Use when the user asks you to act as the Oberon agent, write or modify Oberon code in a live Oberon system, or work on Oberon-side code that's running in an emulator or on a real board. Needs the `oat` binary and a known serial line (a serial device / PTY, or a FIFO pair) to a booted emulator or board with `AgentTool.Mod` installed.
---

# oberon-agent

You drive a LIVE Project Oberon 2013 (PO) or Extended Oberon (EO) system through one
CLI: `oat`. Each invocation opens the serial line, sends one PUT/GET/CALL/EDIT request
to `AgentTool.Mod` on the device, prints the result, and exits. The agent loop lives in
**you**; the device stays stateless across calls.

## Startup — once per session

Before doing anything else, do these three steps in order. Don't skip ahead.

### 1. Locate `oat`

Try in this order; stop at the first hit:

```bash
command -v oat              # on PATH
ls ./oat ./bin/oat ./tools/oat _build/default/oat/bin/oat.exe 2>/dev/null
```

(`_build/default/oat/bin/oat.exe` is where this repo's `dune build` puts it.)

If none of those resolve, ask the user where the `oat` binary is. Don't guess. Once
found, treat its path as `OAT_BIN` for the rest of the session.

### 2. Get the serial-line configuration from the user

There are no defaults. Ask the user which form they're using and what paths:

- A single PTY / serial device:  `--serial <PATH>`
- A FIFO pair:                   `--serial-in <PATH> --serial-out <PATH>`

Stash both pieces together so every later call is short. Example:

```bash
OAT="$OAT_BIN --serial-in /tmp/p.in --serial-out /tmp/p.out"
```

(Use whatever paths the user gave you — `/tmp/p.in` / `/tmp/p.out` is a common
convention but don't assume it.)

On real hardware (`--serial`), `oat` sets the line itself — raw 8N1 at `--baud`,
default 115200, which is what the Nexys 4 build runs — and reads the settings back
before it sends anything. Add `--baud <rate>` only if the user tells you the board
runs another rate. Transfers are slow there, about 10 bits per byte: a 50 KB `read`
takes ~4.3 s at 115200. `--timeout` bounds *silence* (no byte arriving), not the
whole transfer, so raise it only for commands the device is slow to answer (a big
compile); the default is 15 s, and 2 s for `check` on `--serial`.

### 3. Run `oat check` and read the result

```
$ $OAT check
ok: Extended Oberon System  AP 1.1.26 (round-trip 8ms)
```

`check` calls `AgentTool.Version`, which echoes `System.Version` back. Four shapes:

| `check` output starts with | meaning | what to do |
|---|---|---|
| `ok: Extended Oberon …` | EO image with the System.Version patch | safe path: EO has safe-unload (see "Unload") |
| `ok: Project Oberon 2013…` | PO image with the System.Version patch | **unload is unsafe on PO** — see "Unload on PO" |
| `ok: connected (… no version string …)` | wire is up but the image lacks the patch | unknown variant. Tell the user, assume PO-style risks, ask before any `unload` |
| any error | wire is broken or emulator isn't running | stop and report; don't try to recover yourself. On `--serial`, see "If `check` fails on a real serial line" first |

#### If `check` fails on a real serial line (`--serial`)

It fails within seconds (2 s per attempt, 4 attempts), and the error says which side
to look at. Read it, run only the read-only checks below, and report what you found —
don't try to repair the link.

| error starts with | meaning | what to check and report |
|---|---|---|
| `unsupported baud rate` | the host has no such standard rate | the message lists the supported ones — pick from it |
| `cannot open serial device` | wrong path, no permission, or not a serial device | `ls -l <PATH>`; the errno text in the message |
| `serial device … did not take the requested line settings` | the driver refused the rate or mode; the message shows asked vs got | report both lines verbatim |
| `no response on …` | the host line is set and verified (the `line:` row says so) — the device said nothing | device side: board powered and configured, Oberon booted, AgentTool running, the board's baud rate, the right port (`ls /dev/ttyUSB*`) |
| `bad response sync byte …` | bytes arrived but not a response frame | a baud mismatch, another program using the same port, or a device busy enough to garble the frame (see "Emulator vs real hardware"); wait a few seconds and run `check` once more |

Two read-only probes help the user:

- **Is the host really at that speed?** `stty -F <PATH> speed` (macOS: `stty -f`) right
  after an `oat` run prints the rate the kernel holds. It must equal `--baud`; `oat`
  already checked this itself, so a difference here is an `oat` bug worth reporting.
- **Is the board at another rate?** `$OAT_BIN --serial <PATH> --baud 19200 check`
  tries one. Each wrong guess costs about 8 s.

## Tools

Every command exits **0** on success, **1** on tool-level error (file not found,
compile failed, unload refused, trap), **2** on transport / protocol / argument error.
Run `oat <cmd> -h` for per-command help.

| command | use |
|---|---|
| `oat check` | Round-trip `AgentTool.Version` — smoke-test + identify variant. |
| `oat read PATH` | Read a file; content → stdout. |
| `oat write PATH < FILE` | Create or overwrite a file; content from stdin. |
| `oat edit PATH OLD NEW` | str_replace; OLD must occur exactly once. |
| `oat delete PATH` | Delete a file. |
| `oat list-files [PREFIX]` | List files (TSV: name, size, date). |
| `oat list-modules` | List loaded modules (TSV: name, refcnt, code addr). |
| `oat compile NAME [-s]` | Compile via `ORP.Compile`; log → stdout. `-s` rewrites the `.smb` when the exported interface changed. |
| `oat load NAME` | Load a compiled module. |
| `oat unload NAME` | Unload a module. **Behavior differs by variant — see below.** |
| `oat call CMD [ARGS]` | Run any `Mod.Proc` (escape hatch); Log delta → stdout. |

### Common patterns

**Create + run a new module:**

```bash
$OAT write Stars.Mod <<'EOF'
MODULE Stars;
  IMPORT Texts, Oberon;
  VAR W: Texts.Writer;
BEGIN Texts.OpenWriter(W);
END Stars.
EOF
$OAT compile Stars.Mod      # see compiler log
$OAT load Stars             # only if compile succeeded
$OAT call Stars.Show        # run it
```

**Edit + recompile + reload** (replace a *running* module):

```bash
$OAT edit Stars.Mod 'old fragment' 'new fragment'
$OAT compile Stars.Mod
$OAT unload Stars           # see "Unload" — PO needs operator permission first
$OAT load Stars
```

> If the module installs a repeating task or holds a viewer, this reload **leaks**
> the old copy and its task keeps running — see "Emulator vs real hardware". To
> *tune* a running module (e.g. animation speed), add a live parameter command and
> change it in place; reserve reload for real code changes.

**Multi-line edits** — `edit` handles them: OLD may span lines, and the device
matches and splices atomically in one round trip (OLD up to 1 KiB; longer falls
back transparently to a read-modify-write). Mind your shell quoting. For large
rewrites or many scattered changes in one file, `read` + `write` is simpler:

```bash
$OAT read Stars.Mod > /tmp/Stars.Mod
# modify /tmp/Stars.Mod locally
$OAT write Stars.Mod < /tmp/Stars.Mod
```

## Unload: behavior by variant

`oat unload NAME` invokes `System.Free NAME /f` on the device. What `/f` means and
what unload actually does depends entirely on which variant `check` reported.

### Extended Oberon: safe-unload

`/f` triggers EO's safe-unload semantics:

- If the module has no live references → fully removed.
- If references persist (open viewers, heap objects of its types) → HIDDEN: renamed
  to `*<name>`, memory kept valid, eventually reclaimed by `Modules.Collect`. A
  subsequent `load` allocates a fresh block — safe live reload.
- Fails only when other loaded modules still import this one. `oat unload` reports
  this as an in-use refusal.

EO unload is your normal hot-swap path. Use it freely.

### Project Oberon 2013: unsafe-unload — operator permission required

PO's `System.Free` does NOT have safe-unload. `/f` is silently discarded by the
scanner; PO calls `Modules.Free(NAME)` which:

- Refuses (silently, no log) if any importer still references the module.
- Removes the module from the list if `refcnt = 0`, but does NOTHING about live
  pointers: open viewers holding handles into the module's code, heap objects whose
  type tags live in the module's data block. Those references now point into
  freed/overwritten memory. The next message dispatch or GC trace through them
  hangs the system.

**Before any `unload` on PO, do this every time:**

1. Tell the user, in plain language, what you're about to unload and why.
2. Name the specific risk: any open viewer or live heap object from this module will
   point into invalid memory after the unload, and the next interaction with it
   hangs the system (no clean trap, requires emulator reboot).
3. Ask explicitly for permission to proceed. Wait for a clear yes.
4. If they say yes, run `oat unload NAME`.
5. If they say no, suggest alternatives: keep editing without unload, reboot the
   emulator + reload from disk, or run with an EO image instead.

Also: PO only refuses an unload (reported by `oat unload` as "unload refused")
when other loaded *modules* still import the target. Live heap objects and open
viewers don't count as imports, so that unload "succeeds" and leaves the dangling
references above. Verify the outcome with `oat list-modules` afterward.

### Unknown variant (no version reported)

Treat it as PO — assume unsafe-unload, ask the user before every `unload`. Tell the
user the image lacks the version-string patch and ask whether to proceed at their
own risk.

## Emulator vs real hardware

PO and EO are **single-threaded**: one cooperative `Oberon.Loop` runs everything —
your serial agent (`AgentProtocol`'s poll task), the garbage collector, mouse/cursor,
and any task a module installs (`Oberon.NewTask` + `Oberon.Install`). Nothing
preempts; tasks take turns. Two hazards follow, and a real UART makes the first one
fatal.

- **A busy installed task starves the agent.** A fast repeating task competes with the
  serial poll for loop time. On the **emulator** (lossless, back-pressured FIFO) that
  only makes `oat` laggy. On **real hardware** (single-byte UART register, no flow
  control) the poll starts missing the request frame's first byte → requests desync and
  time out, and `oat`'s auto-retry can't help because the poll never runs. Observed: a
  50 ms animation task swung round-trips from ~60 ms to 30–40 s and made the link
  unusable until reboot.
  - Keep installed-task periods slow while you need the wire (≥ ~500 ms is comfortable;
    sub-100 ms strangles it on hardware).
  - Give such a module a **live parameter command** (e.g. `SetSpeed <ms>` that reinstalls
    the task at a new period) and retune **in place** — never by reload. If the link goes
    from responsive to persistently dead right after you start an animation, suspect
    starvation, not transport.

- **Task-installing modules don't cleanly reload.** A module that installs a task (or
  holds a viewer) keeps a live self-reference — the task points into its own code. So EO
  `unload` can't fully free it: it **hides** it as `*<name>`, its `FINAL` never runs, and
  **the old task keeps firing**. Every reload leaks another hidden copy whose task is
  still installed, and those pile onto the loop — exactly what starves the wire. (PO is
  worse: no safe-unload at all — see Unload.)
  - Don't reload to tweak a running module — change parameters in place (above).
  - Before any `unload`, run the module's `Close`/stop command to remove its task and
    clear viewer refs. Expect a hidden `*<name>` to remain anyway; it's harmless only
    once idle (its frame/refs NIL). Reserve reload for genuine code changes, accept the
    leak.

This is the OS design, not something `oat` can fix from the host — keep durable demos
slow-ticking and tunable in place. (See also the transfer-speed/`--timeout` note in
Startup and the FINAL / `Close*` rules below.)

## Project Oberon 2013: keep a module's globals under 64 KiB

PO's compiler generates wrong addresses, **with no compile error**, once the
variables in a module's top-level `VAR` section add up to 64 KiB (65536 bytes) or
more. In such a module:

- **every string literal** is read from the wrong place — it comes out empty or as
  garbage, wherever in the module it is used;
- **any global declared past the 64 KiB mark** is wrong when passed as a parameter
  (`Texts.WriteString(W, s)`, a `VAR` argument, an array or record argument);
- plain reads and writes of scalars and array elements still work, which makes the
  module look fine until it isn't.

Typical symptoms: empty or garbage text, a `TRAP 1` inside `Files` or `Texts` when a
literal is passed as a name, or code that works until some large buffer gets filled
(the wrong address often lands inside the module's own big array). EO's compiler does
not have this bug, but write modules that are safe on both.

**Check it.** The compile success line is `compiling M <code> <data> <key>`; the
second number is the size of the module's globals in bytes:

```
$ $OAT compile Big.Mod
  compiling Big new symbol file    85 65596 C6D4F1B7     # 65596 >= 65536: broken on PO
```

On PO keep that number **under 60000** — string literals are stored right after the
globals and must stay below the 64 KiB mark too.

**Avoid it.** Put any large buffer on the heap instead of in the `VAR` section. The
pointer's base type must be a record on PO:

```oberon
TYPE Buf = POINTER TO BufDesc;
  BufDesc = RECORD d: ARRAY 10000H OF BYTE END;
VAR buf: Buf;                 (*module-level, so the GC keeps the block*)
...
BEGIN NEW(buf)                (*once, in the module body; then use buf.d[i]*)
END M.
```

- `NEW` returns `NIL` when the heap has no room — test `buf # NIL` before use.
- Allocate once and keep the pointer in a module-level variable; don't allocate per
  call.
- The heap is about 425 KB on a 1 MB machine and the compiler needs ~100 KB of it
  for a large module, so one 64 KiB block is fine; several hundred KB is not.
- Don't move the array into a procedure instead: the stack is only 32 KB on PO.

## Working rules

- **Source format.** Plain-ASCII Oberon source. Module `M` lives in `M.Mod`. Both
  variants accept Oberon-07. EO additionally supports type-bound procedures and
  FINAL blocks — use them on EO only.

- **Compile/load cycle.** `compile` produces a `.rsc`; `load` brings it into memory.
  To put new code into effect: `compile` (use `-s` when the exported interface
  changed), then `load`. To replace a *running* module, `unload` first then `load`
  (mind the variant — see above).

- **FINAL blocks for clean tear-down (EO only).** For any module with viewers or
  installed tasks, declare a FINAL block that closes them. The system runs FINAL
  when the module is actually unloaded from memory (after Hide → Collect). Hold
  references in module-level vars so FINAL can reach them:

  ```oberon
  BEGIN ... FINAL Viewers.Close(myV); Oberon.Remove(myT) END M.
  ```

  On PO there is no FINAL block. Modules wanting clean tear-down need an explicit
  `Close*` command the operator (or you) must invoke before `unload`.

- **Load-on-demand.** A module loads on demand: `call Mod.Proc` loads `Mod` from its
  `.rsc` and runs `Proc`. To run an already-compiled module, just `call` it — no
  `load` first, and don't `compile` unless you changed the source. Note:
  `Mod.Open`-style commands open a NEW viewer on every call, so invoke them once.

- **Viewers for human-facing output.** For modules that present output to the
  operator, open a viewer with a system menu (e.g.
  `MenuViewers.New(menuF, mainF, …)`) rather than writing to `Oberon.Log`. Reserve
  the log for non-interactive helpers — introspection you'll read back via `call`,
  automation.

- **Don't `call System.Close` to close a viewer headlessly** — it tests
  `Oberon.Par.vwr.dsc = Par.frame`, which the dummy frame in headless CALLs doesn't
  satisfy, so it no-ops. Implement your module's own `Close*` command that holds a
  saved viewer reference and calls `Viewers.Close` directly.

- **Compiler diagnostics.** `compile`'s log is the raw ORP output: error lines
  `pos <offset> <msg>` ending in `compilation FAILED`, or a success line. You hold
  the source — localize from the messages, don't parse the log.

- **Traps are survivable.** A `call` (or `edit`) that traps reports cleanly: exit 1,
  the Oberon `TRAP` line in the printed log, and the wire stays up — the device
  reinstalls its serial task and completes the exchange. No reboot needed; run
  `check` if in doubt. Residual: a trap landing exactly during a response
  transmission can still garble that one exchange — the next `oat` invocation
  starts clean.

- **Never `unload` AgentTool or AgentProtocol.** They are the wire you are talking
  through; unloading either kills the connection on the spot (and on PO leaves
  dangling references). If they need replacing, that's an image rebuild, not a
  live operation.

- **Prefer named tools.** Use `call` only as an escape hatch. The specific
  subcommands (`read`, `write`, `compile`, `load`, …) carry typed errors and
  consistent exit codes; `call` returns raw Log text you have to read.

- **Concision.** Verify by compiling and then running. Don't echo the compiler log
  back at the user — they see it. State what changed and what works.
