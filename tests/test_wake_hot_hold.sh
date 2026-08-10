#!/usr/bin/env bash
# A hot conversation is not a quiet room, and a note is not an answer.
#
# specs/wake-queue.md rule 27a. 2026-08-10, 12:32:12: a quiet chess note —
# "Lost browser-006 — mated by a promoted pawn while my knights admired
# themselves" — landed in the conversation between "stop assuming I'm wrong"
# at 12:31:46 and "I'm reporting a genuine bug" at 12:33:04. Every gate was
# working and every gate said the room was quiet, because for four seconds it
# was: nothing was recording, nothing was on the speakers. user_busy asks the
# sound card a question; this asks him one.
#
#    1. how hot is measured, at unit level, including the knob at zero
#    2. a (quiet) bubble into a hot conversation reaches NO bubble, no
#       notifier, no renderer, no conversation — and says so in the journal
#    3. the held words come back through the queue's one door, in the reason
#    4. the same wake into a COLD conversation is delivered, which is what
#       makes the hold mean something
#    5. a wake that chose to SPEAK is delivered hot — rule 29's boundary: this
#       gate reads the clock, never the words
#    6. a display-only wake is held too — a window over an argument is an
#       interruption as well
#    7. CONVO_HOT_WINDOW=0 is the old behaviour, exactly
#
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
JOURNAL="${DESKCRAB_STATE_PREFIX}-sessions.log"
QUIET_NOTE="Lost browser-006 — mated by a promoted pawn while my knights admired themselves."
SPOKEN_NOTE="The disk you asked about filled up ten minutes ago and something has to go."

stub_reply() {  # <reply text, \n for newlines>
    sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "\$*" > "$WORK/argv.txt"
python3 - <<'PYEOF'
import json
text = "$1"
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result", "result": text}))
PYEOF
EOF
}

sandbox_stub piper-tts <<EOF
#!/usr/bin/env bash
cat >> "$WORK/spoken.txt"
EOF
sandbox_stub render-md <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/displayed.txt"
EOF
sandbox_stub notify-send <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/notified.txt"
EOF

printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"

write_conf() {  # <hot window seconds>
    cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
WANTS_FILE="$WORK/wants.md"
PIPER_VOICE="$WORK/voice.onnx"
LAST_ORIGIN_FILE="$WORK/last-origin"
WAKE_QUIET_HOURS=""
CONVO_HOT_WINDOW=$1
WAKE_HOT_RETRY=300
EOF
}

# He said something <n> seconds ago. record_origin's own file, written the way
# a turn writes it — device and the epoch the message arrived at.
he_spoke_at() {  # <seconds ago>
    printf 'desk\t%s\n' "$(( $(date +%s) - $1 ))" > "$WORK/last-origin"
}

run_wake() {
    rm -f "$WORK/spoken.txt" "$WORK/displayed.txt" "$WORK/notified.txt" "$CONVO"
    rm -f "$WAKES_DIR"/*.wake 2>/dev/null
    : > "$SANDBOX_SYSTEMD_LOG"
    WAKE_REASON="chessweb: you played Rh4 in game browser-006" \
        "$REPO/crab" wake event "chessweb: you played Rh4 in game browser-006" >/dev/null 2>&1 || true
}

# The HELD bookings, from the durable records — never from the timer, which is
# stubbed. Named apart from every other record in the directory on purpose:
# ensure_next_wake books the chain floor at the end of every wake, so "is
# anything pending" is always yes and would prove nothing either way.
held_records() {
    grep -lF "while he was mid-conversation" "$WAKES_DIR"/*.wake 2>/dev/null || true
}
held_count() { held_records | wc -l; }
held_field() {  # <field number>
    local f; f="$(held_records | head -n1)"
    [ -n "$f" ] && cut -f"$1" "$f" || true
}

echo "how hot is measured, and by what:"
hot_at() {  # <seconds since his last message> <window>
    sandbox_bash "LAST_ORIGIN_FILE='$WORK/last-origin'
                  printf 'desk\t%s\n' \$(( \$(date +%s) - $1 )) > \"\$LAST_ORIGIN_FILE\"
                  CONVO_HOT_WINDOW=$2
                  convo_hot && printf yes || printf no"
}
check_eq "four seconds after his last message the conversation is hot" "$(hot_at 4 120)" "yes"
check_eq "the four-second lull of 12:32:12 is hot, and it is the whole point" \
    "$(hot_at 4 120)" "yes"
check_eq "two minutes and one second later it is not" "$(hot_at 121 120)" "no"
check_eq "the window is a knob, not a constant" "$(hot_at 60 30)" "no"
check_eq "zero switches the reading off entirely" "$(hot_at 1 0)" "no"
check_eq "and a conversation he has never spoken into is not hot" \
    "$(sandbox_bash "LAST_ORIGIN_FILE='$WORK/nothing-here'
                     CONVO_HOT_WINDOW=120
                     convo_hot && printf yes || printf no")" "no"

echo
echo "a quiet note into a hot conversation reaches nobody:"
write_conf 120
stub_reply "(quiet) $QUIET_NOTE"
he_spoke_at 4
run_wake
check "nothing was synthesized" [ ! -f "$WORK/spoken.txt" ]
check "no window was opened" [ ! -f "$WORK/displayed.txt" ]
check "no notification was raised" [ ! -f "$WORK/notified.txt" ]
check "and NOTHING was appended to the conversation — the bubble he could not answer" \
    bash -c '[ ! -s "$1" ]' _ "$CONVO"

echo
echo "...and the record says the heat held it, not that she had nothing:"
check "the journal names the hot conversation as the reason" \
    grep -q "the conversation was hot" "$JOURNAL"
check "and keeps the words that were held" grep -qF "browser-006" "$JOURNAL"

echo
echo "the held words come back through the queue, not into the bin:"
check_eq "exactly one wake was booked to bring the note back" "$(held_count)" "1"
check_eq "booked by the hand that held it, so the queue can be read" \
    "$(held_field 5)" "hot-hold"
check_eq "as an EVENT wake — something is waiting on the other end of it" \
    "$(held_field 2)" "event"
BOOKED="$(held_field 3)"
contains "$BOOKED" "browser-006" \
    && ok "and it carries the words it was holding, so she meets them again" \
    || fail "the re-booked wake lost the note it was holding" "[$BOOKED]"
contains "$BOOKED" "held" \
    && ok "and says why it is coming back" \
    || fail "the re-booked reason does not say it was held"
# Past the heat, never back into it.
FIRE="$(held_field 1)"
check "it fires past the hot window rather than straight back into it" \
    [ "$(( FIRE - $(date +%s) ))" -gt 120 ]

echo
echo "the same note into a COLD conversation is delivered:"
# The control. Without it every assertion above is equally true of a wake that
# could not reach a speaker or a bubble in the first place.
he_spoke_at 600
run_wake
check "the bubble is in the conversation" grep -qF "browser-006" "$CONVO"
check_eq "and nothing was held for later — it arrived" "$(held_count)" "0"
check "and the journal records it as shown, not held" \
    bash -c 'tail -n1 "$1" | grep -q "shown without speech"' _ "$JOURNAL"

echo
echo "a wake that chose to SPEAK is delivered hot — the gate reads the clock, never the words:"
# specs/wake-queue.md rule 29 is untouched by this mechanism, and this is where
# that is proved rather than asserted. She decided, while writing, that these
# words were worth opening her mouth for; nothing downstream of the writing
# gets to overrule that.
stub_reply "$SPOKEN_NOTE"
he_spoke_at 4
run_wake
check "it was synthesized" [ -f "$WORK/spoken.txt" ]
check "with the words it meant to say" grep -qF "filled up ten minutes ago" "$WORK/spoken.txt"
check "and it is in the conversation" grep -qF "filled up ten minutes ago" "$CONVO"
check_eq "and nothing was held or re-booked" "$(held_count)" "0"

echo
echo "a display-only wake is held too — a window over an argument is an interruption:"
stub_reply "---DISPLAY---\n## the board, move by move\n"
he_spoke_at 4
run_wake
check "no window was opened" [ ! -f "$WORK/displayed.txt" ]
check "and its journal line names the heat, not silence" \
    bash -c 'tail -n1 "$1" | grep -q "the conversation was hot"' _ "$JOURNAL"

echo
echo "with the window at zero, nothing changes from before it existed:"
write_conf 0
stub_reply "(quiet) $QUIET_NOTE"
he_spoke_at 1
run_wake
check "the bubble is delivered exactly as it always was" grep -qF "browser-006" "$CONVO"
check_eq "and nothing was held" "$(held_count)" "0"

echo
echo "the held queue is bounded:"
# A stack of held asides all landing on the first quiet minute is the same
# storm, one delay later. The cap is scoped to the held-reason prefix, so it
# neither counts nor drains anybody else's bookings.
write_conf 120
he_spoke_at 4
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
for n in 1 2 3 4 5 6; do
    stub_reply "(quiet) held note number $n about the board"
    WAKE_REASON="chessweb: move $n" "$REPO/crab" wake event "chessweb: move $n" >/dev/null 2>&1 || true
done
HELD_COUNT="$(held_count)"
check "no more than the cap of held notes stands at once" [ "$HELD_COUNT" -le 3 ]
check "and at least one is still there — the cap bounds, it does not empty" \
    [ "$HELD_COUNT" -ge 1 ]

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
