---
name: oberon-agent
description: Drive a live Project Oberon 2013 or Extended Oberon system via the `oat` CLI — read/write/edit files, compile, load/unload modules, run commands. Use when the user asks you to act as the Oberon agent, write or modify Oberon code in a live Oberon system, or work on Oberon-side code that's running in an emulator. Needs the `oat` binary and a known serial line (PTY or FIFO pair) to a booted emulator with `AgentTool.Mod` installed.
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

On real RS232 hardware, transfers are slow — a 50 KB `read` takes ~26 s at
19200 baud. Add `--timeout <secs>` to every call accordingly; the 15 s default
assumes the emulator.

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
| any error | wire is broken or emulator isn't running | stop and report; don't try to recover yourself |

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
slow-ticking and tunable in place. (See also the slow-transfer/`--timeout` note in
Startup and the FINAL / `Close*` rules below.)

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
