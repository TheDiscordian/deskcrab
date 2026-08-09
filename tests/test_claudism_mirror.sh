#!/bin/bash
# The pre-speech mirror — specs/speech-output.md rules 38-45.
# Run: bash tests/test_claudism_mirror.sh
#
# The one guarantee everything else hangs off: a CLEAN draft passes the armed
# gate BYTE-IDENTICAL. Measured the way the speech tests measure everything —
# from the stub synthesiser's side, never from the pipeline's own receipt —
# by running the same stream through an unarmed and an armed streamer and
# comparing the bytes that reached piper.
#
# Then the mirror itself: a fire holds the flagged sentence and what is queued
# behind it (the clean sentence before it has already spoken); her rewrite
# verdict is spoken in the sentence's place and the original never reaches the
# synthesiser; a verdict that never comes fails open to the original; a done
# marker means no hold at all. The fires file is the witness the caller reads,
# so its records are asserted too.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# --- stub voice: records each utterance handed to piper ---------------------
sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [ -n "$line" ]; do
    printf 'SAY\t%s\n' "$line" >> "$TRACE"
    head -c 2048 /dev/zero
done
EOF

# Her phrase list, in claudism-capture's format: the first backtick span is
# the trigger, the prose is the why.
LIST="$T/claudisms.md"
cat > "$LIST" <<'EOF'
# What is borrowed

- `to be honest` — honesty is assumed; the hedge is the habit.
- `you're absolutely right` — the brochure's reflex agreement.
EOF

start_streamer() { # <name> [armed]
    LOG="$T/$1.log"; TRACE="$T/$1.trace"; RECEIPT="$T/$1.receipt"
    SPEECHLOG="$T/$1.speechlog"; FIRES="$T/$1-fires.jsonl"
    : > "$LOG"; : > "$TRACE"; : > "$SPEECHLOG"; rm -f "$RECEIPT" "$FIRES" "$FIRES".verdict-* "$FIRES.done"
    local CLAUDISMS="" CFIRES=""
    if [ "${2:-}" = armed ]; then CLAUDISMS="$LIST"; CFIRES="$FIRES"; fi
    TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
        DESKCRAB_SPEECHLOCK="$T/$1.speechlock" \
        DESKCRAB_SPEECH_LOG="$SPEECHLOG" DESKCRAB_SPEECH_RECEIPT="$RECEIPT" \
        DESKCRAB_VOICE_IDLE_CLOSE=30 \
        DESKCRAB_CLAUDISMS="$CLAUDISMS" DESKCRAB_CLAUDISM_FIRES="$CFIRES" \
        DESKCRAB_CLAUDISM_MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-20}" \
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

said_count() { grep -cF "SAY	$1" "$TRACE"; }
wait_for() { # <predicate...> — up to 10 s
    local i; for i in $(seq 100); do "$@" && return 0; sleep 0.1; done; return 1
}

j() { printf '%s\n' "$1" >> "$LOG"; }
MSTART='{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_A"}}}'
TBLOCK='{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
RESULT='{"type":"result","result":"x"}'
delta() { printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}}}' "$1"; }

echo "a clean draft is byte-identical through the armed gate (rule 38):"

CLEAN1='This draft is clean and plain. '
CLEAN2='It has *emphasis*, a `code span`, and numbers like 3.5 in it. '
CLEAN3='Nothing here is borrowed.
---DISPLAY---
| a | table |'
CLEAN_FULL='This draft is clean and plain. It has *emphasis*, a `code span`, and numbers like 3.5 in it. Nothing here is borrowed.
---DISPLAY---
| a | table |'
CLEAN_CLOSED=$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "$CLEAN_FULL")

feed_clean() {
    j "$MSTART"; j "$TBLOCK"
    j "$(delta "$CLEAN1")"; sleep 0.3
    j "$(delta "$CLEAN2")"; sleep 0.3
    j "$(python3 -c 'import json,sys; print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":sys.argv[1]}}}))' "$CLEAN3")"
    j "$CLEAN_CLOSED"; j "$RESULT"
}

start_streamer plain
feed_clean
reap_streamer
[ "$HUNG" = no ] && ok "unarmed streamer exits" || fail "unarmed streamer hung" ""
PLAIN_TRACE="$TRACE"

start_streamer armedclean armed
feed_clean
reap_streamer
[ "$HUNG" = no ] && ok "armed streamer exits on a clean draft" || fail "armed streamer hung on a clean draft" ""
[ -s "$PLAIN_TRACE" ] || fail "unarmed run spoke nothing — the comparison is vacuous" ""
if cmp -s "$PLAIN_TRACE" "$TRACE"; then
    ok "bytes at the synthesiser are IDENTICAL armed vs unarmed ($(wc -c < "$TRACE") bytes)"
else
    fail "armed gate altered a clean draft" "$(diff "$PLAIN_TRACE" "$TRACE" | head -5)"
fi
[ -e "$FIRES" ] && fail "a clean draft left a fires file" "$(cat "$FIRES")" \
    || ok "a clean draft writes no fire record"

echo
echo "a fire holds the sentence, and her rewrite is spoken in its place (rules 40-41):"

FLAGGED='To be honest, the beacon is green. '
FIRE_FULL='The first sentence is clean. To be honest, the beacon is green. The last sentence follows.'
FIRE_CLOSED=$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "$FIRE_FULL")

start_streamer fire armed
j "$MSTART"; j "$TBLOCK"
j "$(delta 'The first sentence is clean. ')"; sleep 0.3
j "$(delta "$FLAGGED")"; sleep 0.3
j "$(delta 'The last sentence follows.')"
j "$FIRE_CLOSED"; j "$RESULT"

fire_recorded() { grep -qF '"pattern": "to be honest"' "$FIRES" 2>/dev/null; }
wait_for fire_recorded && ok "the fire record lands before anything is held" \
    || fail "no fire record" "$(cat "$FIRES" 2>/dev/null)"
first_spoken() { [ "$(said_count 'The first sentence is clean.')" -ge 1 ]; }
wait_for first_spoken
sleep 0.3
N=$(said_count "To be honest, the beacon is green.")
[ "$N" = 0 ] && ok "the flagged sentence is held off the synthesiser" \
    || fail "flagged sentence spoken while held" "spoken $N times"
N=$(said_count "The last sentence follows.")
[ "$N" = 0 ] && ok "the sentence behind the fire waits its turn" \
    || fail "queued sentence jumped the hold" "spoken $N times"

# Her verdict, written whole and renamed into place like the caller does.
printf '{"action":"rewrite","text":"Plainly: the beacon is green."}\n' > "$FIRES.vtmp"
mv -f "$FIRES.vtmp" "$FIRES.verdict-1"
reap_streamer
[ "$HUNG" = no ] && ok "streamer exits after the verdict" || fail "streamer hung after verdict" ""
N=$(said_count "Plainly: the beacon is green.")
[ "$N" = 1 ] && ok "her rewrite is what was spoken" || fail "rewrite not spoken" "spoken $N times"
N=$(said_count "To be honest, the beacon is green.")
[ "$N" = 0 ] && ok "the original flagged sentence never reached the synthesiser" \
    || fail "original spoken despite rewrite" "spoken $N times"
N=$(said_count "The last sentence follows.")
[ "$N" = 1 ] && ok "the held tail speaks after the rewrite" || fail "held tail lost" "spoken $N times"
grep -qF '"outcome": "rewrite-spoken"' "$FIRES" && ok "outcome record says rewrite-spoken" \
    || fail "no rewrite-spoken outcome" "$(cat "$FIRES")"

echo
echo "a verdict that never comes fails open to the original (rule 42):"

MIRROR_TIMEOUT=1 start_streamer failopen armed
j "$MSTART"; j "$TBLOCK"
j "$(delta "$FLAGGED")"
j "$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "To be honest, the beacon is green.")"
j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "streamer exits without a verdict" || fail "streamer hung waiting forever" ""
N=$(said_count "To be honest, the beacon is green.")
[ "$N" = 1 ] && ok "the original was spoken untouched (fail open)" \
    || fail "fail-open lost the sentence" "spoken $N times; trace: $(cat "$TRACE")"
grep -qF '"outcome": "failopen"' "$FIRES" && ok "outcome record says failopen" \
    || fail "no failopen outcome" "$(cat "$FIRES")"

echo
echo "a done marker means the turn moved on — no hold at all (rule 41):"

start_streamer postcommit armed
printf 'done\n' > "$FIRES.done"
j "$MSTART"; j "$TBLOCK"
j "$(delta "$FLAGGED")"
j "$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "To be honest, the beacon is green.")"
j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "streamer exits promptly past the done marker" || fail "streamer held despite done marker" ""
N=$(said_count "To be honest, the beacon is green.")
[ "$N" = 1 ] && ok "the sentence spoke unheld" || fail "done marker ate the sentence" "spoken $N times"
grep -qF '"outcome": "post-commit"' "$FIRES" && ok "the late fire is still on the record" \
    || fail "post-commit fire unrecorded" "$(cat "$FIRES" 2>/dev/null)"

echo
echo "the helper: scan finds the line, splice touches only the spoken half:"

FLAGS=$(printf 'Clean one. To be honest, flagged two.\n---DISPLAY---\nto be honest in a table\n' \
    | sed -e '/^---DISPLAY---$/,$d' | "$REPO_DIR/lib/claudism-mirror" scan "$LIST")
echo "$FLAGS" | grep -qF '"to be honest"' && ok "scan flags the sentence" || fail "scan missed" "$FLAGS"
SPLICED=$(python3 -c 'import json,sys; print(json.dumps({"response": "Clean one. To be honest, flagged two.\n---DISPLAY---\nto be honest stays here", "sentence": "To be honest, flagged two.", "rewrite": "Flagged two, plainly."}))' \
    | "$REPO_DIR/lib/claudism-mirror" splice)
echo "$SPLICED" | grep -qF "Flagged two, plainly." && ok "splice swapped her line in" || fail "splice failed" "$SPLICED"
echo "$SPLICED" | grep -qF "to be honest stays here" && ok "the display half is untouched" \
    || fail "splice reached past the delimiter" "$SPLICED"
printf '{"response":"abc","sentence":"not there","rewrite":"x"}' \
    | "$REPO_DIR/lib/claudism-mirror" splice >/dev/null 2>&1
[ "$?" = 3 ] && ok "a sentence that cannot be found is exit 3 — the caller keeps the original" \
    || fail "missing-sentence splice did not say so" "exit $?"

# The list's DECLARED shape (the live list's format, held by
# tests/test_claudism_capture.sh for the capture): the heading is the note,
# only pattern: lines are triggers.
DECL="$T/claudisms-declared.md"
cat > "$DECL" <<'EOF'
## the honesty family
- pattern: `\bto be honest\b`
- why: honesty is assumed; a `code word` here must never become a trigger.
EOF
FLAGS=$(printf 'To be honest, declared shape.' | "$REPO_DIR/lib/claudism-mirror" scan "$DECL")
echo "$FLAGS" | grep -qF '"note": "the honesty family"' \
    && ok "the declared shape parses: heading as the note, pattern line as the trigger" \
    || fail "declared shape misread" "$FLAGS"
FLAGS=$(printf 'A code word on its own must not fire.' | "$REPO_DIR/lib/claudism-mirror" scan "$DECL")
[ "$FLAGS" = "[]" ] && ok "a why line quoting code is never a trigger" \
    || fail "why line became a trigger" "$FLAGS"

# --- rule 46: the hold is budgeted for a listener, not a model --------------
# The two deadlines are read straight out of the sources that define them, so
# a later hand raising one without the other shows up here rather than as
# dead air at his desk.
HOLD=$(grep -o 'CLAUDISM_MIRROR_TIMEOUT:-[0-9]*' "$REPO_DIR/lib/common.sh" | head -1 | grep -o '[0-9]*$')
CALL=$(grep -o 'CLAUDISM_MIRROR_DESK_CALL_TIMEOUT:-[0-9]*' "$REPO_DIR/lib/common.sh" | head -1 | grep -o '[0-9]*$')
STREAM=$(grep -o 'DESKCRAB_CLAUDISM_MIRROR_TIMEOUT", "[0-9]*' "$REPO_DIR/lib/tts-streamer" | grep -o '[0-9]*$')
[ -n "$HOLD" ] && [ -n "$CALL" ] && [ -n "$STREAM" ] \
    && ok "both deadlines have defaults where the spec says they live" \
    || fail "a deadline default went missing" "hold=$HOLD call=$CALL streamer=$STREAM"
[ "${HOLD:-0}" -gt "${CALL:-0}" ] \
    && ok "the hold sits above the call, so the call's deadline is the one that fires" \
    || fail "the streamer would break the hold before the call gives up" "hold=$HOLD call=$CALL"
[ "${STREAM:-0}" = "${HOLD:-x}" ] \
    && ok "the streamer's own default matches the caller's" \
    || fail "an unset caller and the streamer disagree on the hold" "streamer=$STREAM caller=$HOLD"
[ "${CALL:-999}" -le 30 ] \
    && ok "the desk hold stays inside what a listener will sit through" \
    || fail "the desk would go silent mid-reply for too long" "call=$CALL"

# --- rule 50: a mention is not a fire; the wide net stays off this path -----
echo
echo "a mention is not a fire, and a review-only entry never arms (rule 50):"
TLIST="$T/tagged-list.md"
cat > "$TLIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed anyway.
- function: vouching

## the wider net
- pattern: `\bI made sure\b`
- why: urge-shaped, review only.
- function: proof-of-work
- live: no
LIST
OUT="$(printf 'Honestly, the kettle is on.' | "$REPO_DIR/lib/claudism-mirror" scan "$TLIST")"
check "a plain use still fires the scan" contains "$OUT" "the kettle is on"
check "and the record carries its function" contains "$OUT" '"function": "vouching"'
OUT="$(printf 'He told me to drop "honestly" from the line.' | "$REPO_DIR/lib/claudism-mirror" scan "$TLIST")"
check_eq "a quoted word is a mention, never a fire" "$OUT" "[]"
OUT="$(printf 'The honesty family fired twice at his desk yesterday.' | "$REPO_DIR/lib/claudism-mirror" scan "$TLIST")"
check_eq "naming the entry is a mention, never a fire" "$OUT" "[]"
OUT="$(printf 'I made sure the door was shut.' | "$REPO_DIR/lib/claudism-mirror" scan "$TLIST")"
check_eq "a live: no entry never reaches the speech path" "$OUT" "[]"
