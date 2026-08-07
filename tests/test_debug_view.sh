#!/bin/bash
# Tests for the live debug view (crab-debug): every reply she produces must
# appear in it, in full, at the time it is produced.
# Run: bash tests/test_debug_view.sh
#
# The gap these were written for: on 2026-08-07 he heard a reply, saw it on the
# phone, and never saw it in the debug view. Three separate ways a reply went
# missing, one per case below —
#   1. a phone turn writes to a PRIVATE per-turn log, and the view followed only
#      the shared one, so phone replies were never in it at all;
#   2. the shared log is truncated in place at the start of every turn, which
#      strands a reader's cursor past EOF — turn one showed, every turn after it
#      was silence;
#   3. a line still being written was read as two halves, neither of which is
#      JSON, so a long assistant block (the reply itself) parsed as nothing.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-dbgview.XXXXXX)"
trap 'rm -rf "$T"; kill %1 2>/dev/null' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — $2"; }

PREFIX="$T/deskcrab"
SHARED="$PREFIX-debug.log"
OUT="$T/view.txt"

# One stream-json assistant text event, exactly the shape the CLI emits.
say() { # <file> <text> [append|truncate]
    local mode="${3:-append}"
    local line
    line="$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$2")"
    if [ "$mode" = truncate ]; then printf '%s\n' "$line" > "$1"
    else printf '%s\n' "$line" >> "$1"; fi
}

# Wait (up to ~10 s) for text to show up in the view rather than sleeping a
# fixed amount: a slow machine must not turn a pass into a flake, and a real
# miss still fails in bounded time.
awaits() { # <text>
    local i=0
    while [ $i -lt 200 ]; do
        grep -qF -- "$1" "$OUT" && return 0
        sleep 0.05
        i=$(( i + 1 ))
    done
    return 1
}

: > "$SHARED"
DESKCRAB_STATE_PREFIX="$PREFIX" "$REPO_DIR/crab-debug" > "$OUT" 2>&1 &
VIEWER=$!
trap 'rm -rf "$T"; kill '"$VIEWER"' 2>/dev/null' EXIT
sleep 0.5

echo "== the shared stream (desk turn / wake) =="
say "$SHARED" "DESK-REPLY-ONE"
awaits DESK-REPLY-ONE && ok "a desk reply reaches the view" \
    || fail "desk reply missing" "not in $OUT"

echo
echo "== a second turn truncates the shared log in place =="
say "$SHARED" "$(printf 'padding %.0s' $(seq 1 200))"   # push the cursor well past
awaits "padding padding" || true
say "$SHARED" "DESK-REPLY-TWO" truncate                  # new turn, from byte 0
awaits DESK-REPLY-TWO && ok "the turn after a truncation still reaches the view" \
    || fail "cursor stranded past EOF by truncation" "DESK-REPLY-TWO not in $OUT"

echo
echo "== a phone turn's private per-turn log =="
PHONE="$PREFIX-turn-$(python3 -c 'import uuid;print(uuid.uuid4().hex)').log"
say "$PHONE" "PHONE-REPLY-THREE"
awaits PHONE-REPLY-THREE && ok "a phone reply reaches the view" \
    || fail "phone turn followed nowhere" "PHONE-REPLY-THREE not in $OUT"
grep -q "── phone ──" "$OUT" && ok "the phone stream is labelled as such" \
    || fail "no phone label" "expected a '── phone ──' header"

echo
echo "== the same for a serverless \`crab remote\` turn =="
REMOTE="$PREFIX-remote-$$.log"
say "$REMOTE" "REMOTE-REPLY-FOUR"
awaits REMOTE-REPLY-FOUR && ok "a \`crab remote\` reply reaches the view" \
    || fail "remote turn followed nowhere" "REMOTE-REPLY-FOUR not in $OUT"

echo
echo "== the private log is drained even after it is deleted =="
say "$PHONE" "PHONE-REPLY-FIVE"
rm -f "$PHONE"
awaits PHONE-REPLY-FIVE && ok "words written just before the turn's log is unlinked survive" \
    || fail "drain-on-unlink" "PHONE-REPLY-FIVE not in $OUT"

echo
echo "== a line still being written is not read as two halves =="
# Exactly what a slow writer does: half the JSON object, a pause, the rest.
LINE="$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"SPLIT-REPLY-SIX is one whole sentence"}]}}))')"
printf '%s' "${LINE:0:40}" >> "$SHARED"
sleep 0.4
printf '%s\n' "${LINE:40}" >> "$SHARED"
awaits "SPLIT-REPLY-SIX is one whole sentence" \
    && ok "a split write is reassembled and shown in full" \
    || fail "partial line dropped the reply" "SPLIT-REPLY-SIX not in $OUT"

echo
echo "== nothing is dropped when both streams write at once =="
say "$SHARED" "CONCURRENT-DESK-SEVEN"
say "$PHONE" "CONCURRENT-PHONE-SEVEN"
awaits CONCURRENT-DESK-SEVEN && awaits CONCURRENT-PHONE-SEVEN \
    && ok "interleaved desk and phone replies both appear" \
    || fail "interleaved streams" "one of the two is missing"

kill $VIEWER 2>/dev/null
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
