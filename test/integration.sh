#!/usr/bin/env bash
# Live integration test: boot IMAGE in the emulator (headless, no display
# needed) on a private FIFO pair and drive the full oat surface against the
# running system — write/read/edit (wire path, fallback path, error statuses),
# compile, call, list, delete, and on Extended Oberon a full edit -> compile
# -> unload -> reload hot swap.
#
# Usage: test/integration.sh IMAGE [RISC [OAT]]

set -u

IMAGE=${1:?usage: integration.sh IMAGE [RISC [OAT]]}
RISC=${2:-_build/default/bin/risc.exe}
OAT_BIN=${3:-_build/default/oat/bin/oat.exe}

T=$(mktemp -d)
EMU_PID=
cleanup() {
    [ -n "$EMU_PID" ] && kill "$EMU_PID" 2>/dev/null
    [ -n "$EMU_PID" ] && wait "$EMU_PID" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT

mkfifo "$T/p.in" "$T/p.out"
# Display env deliberately scrubbed: headless must never need (or open) a
# window, and this keeps a regression to windowed mode from passing silently.
env -u DISPLAY -u WAYLAND_DISPLAY \
    "$RISC" --headless --serial-in "$T/p.in" --serial-out "$T/p.out" "$IMAGE" \
    >"$T/risc.log" 2>&1 &
EMU_PID=$!

oat() { "$OAT_BIN" --serial-in "$T/p.in" --serial-out "$T/p.out" "$@"; }

# --- assertion helpers --------------------------------------------------------

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

# assert the command succeeds (exit 0); stdout -> $out
expect_ok() {
    local desc=$1; shift
    if out=$("$@" 2>&1); then ok "$desc"; else bad "$desc" "$out"; fi
}

# assert the command exits 1 (tool-level error) with $2 on stderr
expect_err() {
    local desc=$1 needle=$2; shift 2
    local rc=0
    out=$("$@" 2>&1) || rc=$?
    if [ "$rc" != 1 ]; then
        bad "$desc" "expected exit 1, got $rc: $out"
    elif ! grep -qF "$needle" <<<"$out"; then
        bad "$desc" "stderr missing '$needle': $out"
    else
        ok "$desc"
    fi
}

# assert file content on the device equals stdin (after oat's CR->LF view)
expect_content() {
    local desc=$1 file=$2
    cat >"$T/exp"
    if oat read "$file" >"$T/got" 2>"$T/err" && diff -u "$T/exp" "$T/got" >"$T/diff"; then
        ok "$desc"
    else
        bad "$desc" "$(cat "$T/err" "$T/diff" 2>/dev/null)"
    fi
}

# --- boot ---------------------------------------------------------------------

booted=
for _ in $(seq 1 30); do
    if check_out=$(oat --timeout 2 check 2>&1); then booted=1; break; fi
    sleep 0.5
done
if [ -z "$booted" ]; then
    echo "FAIL emulator did not come up: $check_out" >&2
    sed -n '1,20p' "$T/risc.log" >&2
    exit 1
fi
ok "boot + check: $check_out"

if grep -qE "Project Oberon|Extended Oberon" <<<"$check_out"; then
    ok "check reports the variant"
else
    bad "check reports the variant" "$check_out"
fi

# --- write / read roundtrip ----------------------------------------------------

oat write Itest.Mod <<'EOF' >/dev/null
MODULE Itest;
  IMPORT Texts, Oberon;
  VAR W: Texts.Writer;
  PROCEDURE Run*;
  BEGIN Texts.WriteString(W, "itest-marker-A"); Texts.WriteLn(W);
    Texts.Append(Oberon.Log, W.buf)
  END Run;
BEGIN Texts.OpenWriter(W)
END Itest.
EOF

expect_content "write/read roundtrip (LF view)" Itest.Mod <<'EOF'
MODULE Itest;
  IMPORT Texts, Oberon;
  VAR W: Texts.Writer;
  PROCEDURE Run*;
  BEGIN Texts.WriteString(W, "itest-marker-A"); Texts.WriteLn(W);
    Texts.Append(Oberon.Log, W.buf)
  END Run;
BEGIN Texts.OpenWriter(W)
END Itest.
EOF

# --- edit: device-side wire path ------------------------------------------------

expect_ok "edit: unique match (OP_EDIT)" oat edit Itest.Mod itest-marker-A itest-marker-B
expect_content "edit applied; Texts header stripped on read" Itest.Mod <<'EOF'
MODULE Itest;
  IMPORT Texts, Oberon;
  VAR W: Texts.Writer;
  PROCEDURE Run*;
  BEGIN Texts.WriteString(W, "itest-marker-B"); Texts.WriteLn(W);
    Texts.Append(Oberon.Log, W.buf)
  END Run;
BEGIN Texts.OpenWriter(W)
END Itest.
EOF

expect_ok "edit: multi-line OLD spanning a line break" \
    oat edit Itest.Mod 'VAR W: Texts.Writer;
  PROCEDURE Run*;' 'VAR W: Texts.Writer;  (*itest*)
  PROCEDURE Run*;'

expect_err "edit: OLD not in file -> exit 1" "OLD string not found" \
    oat edit Itest.Mod no-such-string x

printf 'tok tok\n' | oat write Dup.Txt >/dev/null
expect_err "edit: ambiguous OLD -> exit 1 with count" "occurs 2 times" \
    oat edit Dup.Txt tok X

expect_err "edit: missing file -> exit 1" "file not found" \
    oat edit Nope.Txt a b

# --- edit: host-side fallback for OLD > 1 KiB -----------------------------------

bigx=$(printf 'x%.0s' $(seq 600)); bigy=$(printf 'y%.0s' $(seq 600))
big="$bigx"$'\n'"$bigy"
printf 'head\n%s\ntail\n' "$big" | oat write Big.Txt >/dev/null
expect_ok "edit: >1 KiB OLD takes GET+PUT fallback" oat edit Big.Txt "$big" z
expect_content "fallback edit applied" Big.Txt <<'EOF'
head
z
tail
EOF

# --- compile / call / list ------------------------------------------------------

expect_ok "compile Itest.Mod" oat compile Itest.Mod
expect_ok "load Itest (AgentTool.Load)" oat load Itest
if out=$(oat call Itest.Run 2>&1) && grep -q "itest-marker-B" <<<"$out"; then
    ok "call Itest.Run loads + runs (marker-B)"
else
    bad "call Itest.Run loads + runs (marker-B)" "$out"
fi
if out=$(oat list-files Itest 2>&1) && grep -q "^Itest\.Mod\b" <<<"$out"; then
    ok "list-files shows Itest.Mod"
else
    bad "list-files shows Itest.Mod" "$out"
fi
if out=$(oat list-modules 2>&1) && grep -q "^Itest\b" <<<"$out"; then
    ok "list-modules shows loaded Itest"
else
    bad "list-modules shows loaded Itest" "$out"
fi
if grep -q "^AgentProtocol\b" <<<"$out" && grep -q "^AgentTool\b" <<<"$out"; then
    ok "protocol split: AgentTool + AgentProtocol both loaded"
else
    bad "protocol split: AgentTool + AgentProtocol both loaded" "$out"
fi

# --- trap survival ---------------------------------------------------------------
# A command that traps used to kill the wire task for good (Oberon.Reset removes
# the active task). Now the watchdog reinstalls it and the in-flight recovery
# completes the exchange with stTrapped + the TRAP line from the Log.

oat write Crash.Mod <<'EOF' >/dev/null
MODULE Crash;
  VAR a: ARRAY 4 OF INTEGER; n: INTEGER;
  PROCEDURE Go*;
  BEGIN a[n + 7] := 0
  END Go;
BEGIN n := 0
END Crash.
EOF
expect_ok "trap survival: compile Crash.Mod" oat compile Crash.Mod

trap_call() { # desc — call Crash.Go, expect exit 1 + TRAP line + trapped error
    local desc=$1 rc=0
    out=$(oat call Crash.Go 2>&1) || rc=$?
    if [ "$rc" = 1 ] && grep -q "TRAP" <<<"$out" && grep -q "trapped" <<<"$out"; then
        ok "$desc"
    else
        bad "$desc" "rc=$rc: $out"
    fi
}
trap_call "trap survival: trapping call reports TRAP, exit 1"
expect_ok "trap survival: wire alive after trap" oat check
trap_call "trap survival: second trap also reported"
expect_ok "trap survival: wire alive after second trap" oat check
printf 'post-trap\n' | oat write Post.Txt >/dev/null
expect_content "trap survival: write/read roundtrip after traps" Post.Txt <<'EOF'
post-trap
EOF
expect_ok "trap survival: delete Post.Txt" oat delete Post.Txt

# --- Extended Oberon only: full hot-swap loop -----------------------------------

if grep -q "Extended Oberon" <<<"$check_out"; then
    expect_ok "EO hot swap: edit marker-B -> marker-C" \
        oat edit Itest.Mod itest-marker-B itest-marker-C
    expect_ok "EO hot swap: recompile" oat compile Itest.Mod
    expect_ok "EO hot swap: safe unload" oat unload Itest
    if out=$(oat call Itest.Run 2>&1) && grep -q "itest-marker-C" <<<"$out"; then
        ok "EO hot swap: reloaded module runs marker-C"
    else
        bad "EO hot swap: reloaded module runs marker-C" "$out"
    fi
fi

# --- delete ----------------------------------------------------------------------

expect_ok "delete Itest.Mod" oat delete Itest.Mod
expect_ok "delete Dup.Txt" oat delete Dup.Txt
expect_ok "delete Big.Txt" oat delete Big.Txt
expect_ok "delete Crash.Mod" oat delete Crash.Mod
expect_err "read deleted file -> exit 1" "file not found" oat read Itest.Mod

# --- summary ---------------------------------------------------------------------

echo "integration($IMAGE): $pass passed, $fail failed"
[ "$fail" = 0 ]
