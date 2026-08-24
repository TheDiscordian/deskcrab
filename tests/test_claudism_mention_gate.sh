#!/bin/bash
# The live mention gate — specs/speech-output.md rule 50 as amended, and
# nightly.md rule 47's test run at fire time. A sentence that merely QUOTES
# a flagged entry is never held and never mirror-called, on the desk and the
# whole-draft paths alike — but its flag record still lands, use=mention, so
# the night still counts it. The same words said plainly hold, route, and
# log exactly as they always did, with use=use on the record. The classifier
# is the ONE mention test in lib/claudism-mirror (the capture's, the
# corpus's and the scan's); when it cannot answer, or its record cannot be
# written, the fire falls back to today's behaviour — never a lost flag.
# Run: bash tests/test_claudism_mention_gate.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# The fixture list, declared shape, invented phrases: the live list is
# personal state and never enters this repository. No replace lines on
# purpose — a fire that is not skipped must HOLD, so the hold is observable.
LIST="$T/claudisms.md"
cat > "$LIST" <<'EOF'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed anyway; no replace lines, so an unskipped fire holds.
- function: vouching
- fix: delete

## the seal of candour
- pattern: `\bto be candid\b`
- why: the second entry, for the sentence that quotes one and uses another.
- function: vouching
- fix: delete
EOF

MENTION_S='He told me to drop "honestly" from the line.'
USE_S='Honestly, the kettle is on.'
MIXED_S='He told me to drop "honestly", and to be candid I kept it.'
export MENTION_S USE_S

echo "the shared scan says which it was — the record's exact shape:"

OUT="$(printf '%s' "$MENTION_S" | "$REPO_DIR/lib/claudism-mirror" scan "$LIST")"
check "the quoting sentence is still a record — never dropped" \
    contains "$OUT" '"pattern"'
check "and the record says mention" contains "$OUT" '"use": "mention"'
OUT="$(printf '%s' "$USE_S" | "$REPO_DIR/lib/claudism-mirror" scan "$LIST")"
check "the same words said plainly are a use" contains "$OUT" '"use": "use"'
OUT="$(printf '%s' "$MIXED_S" | "$REPO_DIR/lib/claudism-mirror" scan "$LIST")"
check "a use beside a mention still fires as a use" contains "$OUT" '"use": "use"'
check "and on the entry actually used, not the one quoted" \
    contains "$OUT" '"pattern": "\\bto be candid\\b"'

echo
echo "the desk: a quoting sentence speaks unheld, flagged use=mention:"

sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [ -n "$line" ]; do
    printf 'SAY\t%s\n' "$line" >> "$TRACE"
    head -c 2048 /dev/zero
done
EOF

FLAGSDIR="$T/flags"
start_streamer() { # <name> <flags-dir>
    LOG="$T/$1.log"; TRACE="$T/$1.trace"; RECEIPT="$T/$1.receipt"
    SPEECHLOG="$T/$1.speechlog"; FIRES="$T/$1-fires.jsonl"
    : > "$LOG"; : > "$TRACE"; : > "$SPEECHLOG"
    rm -f "$RECEIPT" "$FIRES" "$FIRES".verdict-* "$FIRES.done"
    TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
        DESKCRAB_SPEECHLOCK="$T/$1.speechlock" \
        DESKCRAB_SPEECH_LOG="$SPEECHLOG" DESKCRAB_SPEECH_RECEIPT="$RECEIPT" \
        DESKCRAB_VOICE_IDLE_CLOSE=30 \
        DESKCRAB_CLAUDISMS="$LIST" DESKCRAB_CLAUDISM_FIRES="$FIRES" \
        DESKCRAB_CLAUDISM_FLAGS="$2" \
        DESKCRAB_CLAUDISM_MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-2}" \
        "$REPO_DIR/lib/tts-streamer" 2>/dev/null &
    SPID=$!
    sleep 0.2
}
reap_streamer() { # waits, sets HUNG
    local i; HUNG=no
    for i in $(seq 150); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$SPID" 2>/dev/null; then HUNG=yes; kill -9 "$SPID" 2>/dev/null; fi
    wait "$SPID" 2>/dev/null
}

j() { printf '%s\n' "$1" >> "$LOG"; }
MSTART='{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_A"}}}'
TBLOCK='{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
RESULT='{"type":"result","result":"x"}'
closed() { python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "$1"; }
delta() { python3 -c 'import json,sys; print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":sys.argv[1]}}}))' "$1"; }

start_streamer mention "$FLAGSDIR"
j "$MSTART"; j "$TBLOCK"
j "$(delta "$MENTION_S")"
j "$(closed "$MENTION_S")"; j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "the streamer exits" || fail "streamer hung on a mention" ""
check "the quoted words were spoken" contains "$(cat "$TRACE")" 'from the line'
refute "and never held for a rewrite" \
    contains "$(cat "$SPEECHLOG")" 'held for her rewrite'
refute "no fire record — the caller is never asked to answer one" \
    [ -e "$FIRES" ]
DAYFILE="$FLAGSDIR/$(date +%F).jsonl"
check "the day's flag log still counts it" [ -s "$DAYFILE" ]
check "as a live record" contains "$(cat "$DAYFILE")" '"stage": "live"'
check "carrying use=mention" contains "$(cat "$DAYFILE")" '"use": "mention"'
check "with outcome mention" contains "$(cat "$DAYFILE")" '"outcome": "mention"'

echo
echo "the desk: the same words said plainly hold and log use=use as ever:"

MIRROR_TIMEOUT=20 start_streamer use "$FLAGSDIR"
j "$MSTART"; j "$TBLOCK"
j "$(delta "$USE_S")"
j "$(closed "$USE_S")"; j "$RESULT"
fire_recorded() { grep -qF '"pattern"' "$FIRES" 2>/dev/null; }
wait_for() { local i; for i in $(seq 100); do "$@" && return 0; sleep 0.1; done; return 1; }
wait_for fire_recorded && ok "a plain use still writes its fire record" \
    || fail "no fire record for a plain use" "$(cat "$FIRES" 2>/dev/null)"
check "and the record says use" contains "$(cat "$FIRES")" '"use": "use"'
printf '{"action":"rewrite","text":"The kettle is on, plainly."}\n' > "$FIRES.vtmp"
mv -f "$FIRES.vtmp" "$FIRES.verdict-1"
reap_streamer
[ "$HUNG" = no ] && ok "the streamer exits after the verdict" || fail "streamer hung" ""
check "her rewrite is what was spoken" \
    contains "$(cat "$TRACE")" 'The kettle is on, plainly.'
refute "and the original never reached the synthesiser" \
    contains "$(cat "$TRACE")" 'Honestly, the kettle is on.'
check "outcome rewrite-spoken, exactly as before" \
    contains "$(cat "$FIRES")" '"outcome": "rewrite-spoken"'

echo
echo "a mention row that cannot be written falls back to the hold — never a lost flag:"

: > "$T/notadir"   # a file where the flags directory should be
MIRROR_TIMEOUT=1 start_streamer fallback "$T/notadir"
j "$MSTART"; j "$TBLOCK"
j "$(delta "$MENTION_S")"
j "$(closed "$MENTION_S")"; j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "the streamer exits" || fail "streamer hung in the fallback" ""
check "the fallback says so and holds as usual" \
    contains "$(cat "$SPEECHLOG")" 'holding as usual'
check "the fire record was written after all" contains "$(cat "$FIRES")" '"pattern"'
check "and failed open like any unanswered hold" \
    contains "$(cat "$FIRES")" '"outcome": "failopen"'
check "the words still went out" contains "$(cat "$TRACE")" 'from the line'

echo
echo "the desk caller counts only holds that can come — an all-mention draft waits for nothing:"

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D"
cp "$LIST" "$D/claudisms.md"
DESKFIRES="$T/desk-fires.jsonl"
BEFORE=$(date +%s)
OUT="$(MS="$MENTION_S" sandbox_bash '_CLAUDISM_FIRES_FILE="'"$DESKFIRES"'" _TTS_STREAMER_PID=$$ CLAUDISM_DESK_WAIT=6 claudism_mirror_desk "$MS"')"
ELAPSED=$(( $(date +%s) - BEFORE ))
check "the committed reply is the draft untouched" contains "$OUT" 'from the line'
[ "$ELAPSED" -le 3 ] && ok "no idle wait for a hold that cannot come ($ELAPSED s)" \
    || fail "the caller sat out the deadline on a mention" "${ELAPSED}s"
check "the done marker went down" [ -f "$DESKFIRES.done" ]

echo
echo "the whole-draft pass: a quoting draft skips the mirror call, still counted:"

WDAY="$D/claudism-flags/$(date +%F).jsonl"
OUT="$(MS="$MENTION_S" sandbox_bash 'claudism_mirror_direct wake "$MS"')"
check_eq "the delivered reply is byte-for-byte the draft" "$OUT" "$MENTION_S"
[ -s "$SANDBOX_CLAUDE_LOG" ] && fail "a quoting draft still paid for a mirror call" \
    "$(cat "$SANDBOX_CLAUDE_LOG")" || ok "no model call for a quoting draft"
check "the flag row still landed" [ -s "$WDAY" ]
check "as a live record" contains "$(cat "$WDAY")" '"stage": "live"'
check "carrying use=mention" contains "$(cat "$WDAY")" '"use": "mention"'
check "with outcome mention" contains "$(cat "$WDAY")" '"outcome": "mention"'
check "under the caller's kind" contains "$(cat "$WDAY")" '"kind": "wake"'

OUT="$(US="$USE_S" sandbox_bash 'claudism_mirror_direct wake "$US"')"
check "a plain use still routes to the mirror" [ -s "$SANDBOX_CLAUDE_LOG" ]
check "and her answer is what is delivered" contains "$OUT" 'stub reply.'
check "its row carries use=use" contains "$(cat "$WDAY")" '"use": "use"'
check "with outcome rewrite, exactly as before" \
    contains "$(cat "$WDAY")" '"outcome": "rewrite"'
