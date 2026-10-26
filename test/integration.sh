#!/usr/bin/env bash
# Live integration test: boot IMAGE in the emulator (headless, no display
# needed) on a private FIFO pair and drive the full oat surface against the
# running system — write/read/edit (wire path, fallback path, error statuses),
# a write at the 64 KiB PUT limit, the wire's bounds (over-long names, invalid
# names, long payloads, a shrinking Log), compile, call, list, delete, and on
# Extended Oberon a full edit -> compile -> unload -> reload hot swap.
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

# --- write at the PUT limit -----------------------------------------------------
# 64 KiB of letters fills the device's whole receive buffer. A CALL right after
# must still answer: with a static buffer, PO's compiler put AgentProtocol's ""
# literal at a miscomputed address inside it, and a letter there made every
# later CALL trap before it could reply.

head -c 65536 /dev/zero | tr '\0' 'A' >"$T/full"
expect_ok "write: 64 KiB of letters (the PUT limit)" oat write Full.Txt <"$T/full"
expect_ok "CALL answers after a full-buffer write" oat check
if oat read Full.Txt 2>"$T/err" | cmp -s - "$T/full"; then
    ok "64 KiB round-trips byte-identical"
else
    bad "64 KiB round-trips byte-identical" "$(cat "$T/err")"
fi

# --- wire bounds ----------------------------------------------------------------
# A name longer than the device's 64-byte buffer used to trap it mid-frame, so the
# rest of the frame was parsed as fresh requests: a payload carrying a frame
# became a real PUT. oat refuses such names now, so this frame goes in raw. The
# device must consume it whole and refuse it — Evil1 must not appear.

{
    printf '\xA5\x01\x64'                          # PUT, a 100-byte name
    printf 'N%.0s' $(seq 100)
    printf '\x11\x00\x00\x00'                      # 17-byte payload: a PUT frame
    printf '\xA5\x01\x05Evil1\x05\x00\x00\x00hello'
} >"$T/p.in"
sleep 1                                            # let the refusal land; oat drains it
expect_err "over-long name: frame consumed whole, no phantom PUT" "file not found" \
    oat read Evil1
expect_ok "wire alive after the over-long name" oat check

# stdin via <<<, not a pipe: a pipe would run expect_err in a subshell and lose
# its pass/fail count.
expect_err "write to an invalid name is refused, exit 1" \
    "device refused to create" oat write bad-name.Txt <<<'x'

# Payloads now reach RAM before any file is touched; past 672 bytes a Texts
# writer would hit the disk mid-receive. (Lossless here, so this pins the path,
# not the overrun.) Echo.Par copies its parameter text to the Log; Echo.Shrink
# deletes the whole Log, which used to make the reply length negative.
oat write Echo.Mod <<'EOF' >/dev/null
MODULE Echo;
  IMPORT Texts, Oberon;
  VAR W: Texts.Writer;
  PROCEDURE Par*;
    VAR R: Texts.Reader; ch: CHAR;
  BEGIN Texts.OpenReader(R, Oberon.Par.text, Oberon.Par.pos); Texts.Read(R, ch);
    WHILE ~R.eot DO Texts.Write(W, ch); Texts.Read(R, ch) END;
    Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
  END Par;
  PROCEDURE Shrink*;
    VAR B: Texts.Buffer;
  BEGIN NEW(B); Texts.OpenBuf(B); Texts.Delete(Oberon.Log, 0, Oberon.Log.len, B);
    Texts.WriteString(W, "shrunk"); Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
  END Shrink;
BEGIN Texts.OpenWriter(W)
END Echo.
EOF
expect_ok "compile Echo.Mod" oat compile Echo.Mod

long=$(printf '%.0sabcdefghij' $(seq 200))         # 2000 bytes, one line
if out=$(oat call Echo.Par "$long" 2>&1) && grep -qF "$long" <<<"$out"; then
    ok "call: 2000-byte par arrives intact"
else
    bad "call: 2000-byte par arrives intact" "$(head -c 300 <<<"$out")"
fi

if out=$(oat call Echo.Shrink 2>&1) && grep -q "shrunk" <<<"$out"; then
    ok "call that empties the Log: reply carries the new Log"
else
    bad "call that empties the Log: reply carries the new Log" "$out"
fi
expect_ok "wire alive after the Log shrank" oat check

printf 'head\nMARK\ntail\n' | oat write Long.Txt >/dev/null
expect_ok "edit: 2000-byte NEW" oat edit Long.Txt MARK "$long"
expect_content "2000-byte NEW applied" Long.Txt <<EOF
head
$long
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
expect_ok "delete Full.Txt" oat delete Full.Txt
expect_ok "delete Crash.Mod" oat delete Crash.Mod
expect_ok "delete Echo.Mod" oat delete Echo.Mod
expect_ok "delete Long.Txt" oat delete Long.Txt
expect_err "read deleted file -> exit 1" "file not found" oat read Itest.Mod

# --- summary ---------------------------------------------------------------------

echo "integration($IMAGE): $pass passed, $fail failed"
[ "$fail" = 0 ]
