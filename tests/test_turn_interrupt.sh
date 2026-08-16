#!/usr/bin/env bash
# Cut-and-consolidate: a new utterance arriving while a turn is in flight CUTS
# that turn — voice stopped mid-sentence, run aborted — and the new turn folds
# BOTH inputs into one reply. Never queueing.
#
# specs/turn-pipeline.md rule 15f. The design is his correction, recorded
# 2026-08-07 13:23: interrupt design is cut-and-consolidate, never queueing.
# The turn-serialisation build that preceded it was killed for queueing; the
# delivery queue (rules 15a-15e) survives as the BACKSTOP — the order of what
# does deliver, and the harder close for STRONG pushback — never as the answer
# to an interruption.
#
#    1. the in-flight turn's voice dies at the interrupt point: a sentence
#       already enqueued for the speakers is never voiced
#    2. exactly one model run produces the surviving reply — the cut turn's
#       run is aborted, not allowed to finish and speak
#    3. the surviving reply's prompt carries the cut turn's input, its
#       part-written reply, and the new utterance
#    4. nothing was queued: the cut turn delivers nothing anywhere, no third
#       run happens afterwards, and the queue is left empty
#    5. the knob: TURN_INTERRUPT=0 restores the pure delivery queue, and
#       STRONG pushback still supersedes (the harder close) rather than cuts
#
# Everything is stubbed and confined to the sandbox: no claude, no speakers,
# no notifications, no timers.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -uo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
SESSLOG="${DESKCRAB_STATE_PREFIX}-sessions.log"
ORDERDIR="${DESKCRAB_STATE_PREFIX}-turn-order"

# The stub claude. SLOW streams a two-sentence delta, hangs mid-run — the
# shape of a turn still generating when he speaks over it — and then, if the
# run is still alive, streams two MORE sentences. Those last two are the
# proof that matters: the catch-all's stop_tts has always pkilled the box's
# synthesiser at a new query, taking whatever was already handed over down
# with it, but the STREAMER survived that and reopened a fresh synthesiser
# for every sentence the un-aborted run kept generating — the superseded
# reply talking on after the interruption. Anything else answers at once.
# Every invocation records what it was asked; only a run that reached its own
# end records COMPLETED; the NEW turn's system prompt is kept so the
# consolidation can be read back.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
PROMPT=""; PREV=""; TEXT=""
for a in "$@"; do
    [ "$PREV" = "--append-system-prompt" ] && PROMPT="$a"
    PREV="$a"; TEXT="$a"
done
printf '%s\n' "$TEXT" >> "$SANDBOX_ASKED"
case "$TEXT" in
    NEW*) printf '%s' "$PROMPT" > "$SANDBOX_NEWPROMPT" ;;
esac
case "$TEXT" in
    *SLOW*)
        printf '{"type":"stream_event","event":{"type":"message_start"}}\n'
        printf '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}\n'
        printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sentence one of the doomed answer. Sentence two must never be heard."}}}\n'
        sleep 6
        printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Sentence three after the interrupt. Sentence four must never be heard either."}}}\n'
        printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Sentence one of the doomed answer. Sentence two must never be heard. Sentence three after the interrupt. Sentence four must never be heard either."}]}}\n'
        ;;
    *)
        printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"ANSWER-TO %s"}]}}\n' "$TEXT"
        ;;
esac
printf '{"type":"result"}\n'
printf 'COMPLETED %s\n' "$TEXT" >> "$SANDBOX_COMPLETED"
EOF

# A slow synthesiser: it logs each sentence as it takes it, then holds it for
# three seconds. That puts real daylight between "sentence one is being
# spoken" and "sentence two is waiting in the queue" — the window the cut has
# to land in, and the queue the cut has to clear.
sandbox_stub piper-tts <<'EOF'
#!/bin/bash
while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "${SANDBOX_SPOKEN_LOG:-/dev/null}"
    head -c 2048 /dev/zero
    sleep 3
done
exit 0
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
LAST_ORIGIN_FILE="$WORK/last-origin"
WAKE_QUIET_HOURS=""
PIPER_VOICE="$WORK/voice.onnx"
EOF

export SANDBOX_ASKED="$WORK/asked.txt"
export SANDBOX_COMPLETED="$WORK/completed.txt"
export SANDBOX_NEWPROMPT="$WORK/new-prompt.txt"
: > "$SANDBOX_ASKED"; : > "$SANDBOX_COMPLETED"

seed_convo() {
    printf 'User [12:00]: how did that go\nAssistant [12:01]: It went fine.\n\n' > "$CONVO"
}

# --- the interruption itself ----------------------------------------------
echo "he speaks over a turn mid-sentence:"
seed_convo
rm -rf "$ORDERDIR"; : > "$SESSLOG"; : > "$SANDBOX_SPOKEN_LOG"
"$REPO/crab" "SLOW tell me about the disk" >/dev/null 2>&1 &
FIRST=$!
# Wait until the doomed answer's first sentence is IN the synthesiser — so
# the second sentence is enqueued behind it and the run is still mid-flight.
for i in $(seq 80); do
    grep -qF "Sentence one of the doomed answer" "$SANDBOX_SPOKEN_LOG" 2>/dev/null && break
    sleep 0.1
done
grep -qF "Sentence one of the doomed answer" "$SANDBOX_SPOKEN_LOG" 2>/dev/null \
    || die "the first turn never started speaking — nothing to interrupt" \
           "$(cat "$SESSLOG" 2>/dev/null)"

"$REPO/crab" "NEW what about the weather then" >/dev/null 2>&1
wait "$FIRST" 2>/dev/null
# Let the cut turn's own trailing bookkeeping settle before reading records.
sleep 1

# 1 — the voice died at the interrupt point, and STAYED dead. The sentence
# already handed to the synthesiser dies with it (stop_tts at the catch-all
# has always taken that one), and — the half only the cut closes — the
# streamer does not reopen a fresh synthesiser for what the un-aborted run
# would have kept generating.
grep -qF "Sentence two must never be heard" "$SANDBOX_SPOKEN_LOG" \
    && { echo "--- spoken ---"; cat "$SANDBOX_SPOKEN_LOG"; \
         fail "a sentence enqueued for the superseded reply was voiced after the interrupt"; } \
    || ok "the enqueued sentence of the cut reply never reached the synthesiser"
grep -qF "must never be heard either" "$SANDBOX_SPOKEN_LOG" \
    && { echo "--- spoken ---"; cat "$SANDBOX_SPOKEN_LOG"; \
         fail "the superseded reply kept talking after the interrupt — the run was never aborted"; } \
    || ok "no later sentence of the cut reply was voiced — the run is dead, not just its synthesiser"
grep -qF "ANSWER-TO NEW" "$SANDBOX_SPOKEN_LOG" \
    && ok "the surviving reply is the one voice that speaks" \
    || fail "the surviving reply was never spoken" "$(cat "$SANDBOX_SPOKEN_LOG")"

# 2 — exactly one model run produced the surviving reply.
check_eq "two runs started — the cut turn's and the survivor's, no third" \
    "$(sandbox_count_in . "$SANDBOX_ASKED")" "2"
check_eq "exactly one run was allowed to finish" \
    "$(sandbox_count_in . "$SANDBOX_COMPLETED")" "1"
grep -q "^COMPLETED NEW" "$SANDBOX_COMPLETED" \
    && ok "and the one that finished is the survivor, not the cut run" \
    || fail "the cut run finished anyway" "$(cat "$SANDBOX_COMPLETED")"

# 3 — the surviving prompt is the consolidation.
if [ ! -s "$SANDBOX_NEWPROMPT" ]; then
    fail "the surviving turn's system prompt was never captured"
else
    grep -qF "SLOW tell me about the disk" "$SANDBOX_NEWPROMPT" \
        && ok "the surviving prompt carries the cut turn's original input" \
        || fail "the cut turn's input is not in the surviving prompt"
    grep -qF "Sentence two must never be heard" "$SANDBOX_NEWPROMPT" \
        && ok "…and the part-written reply, so it knows what was being said" \
        || fail "the part-written reply is not in the surviving prompt"
    grep -qF "HE SPOKE OVER YOU" "$SANDBOX_NEWPROMPT" \
        && ok "…under the interrupt frame that says fold, don't restate" \
        || fail "no interrupt frame in the surviving prompt"
fi

# 4 — nothing was queued and nothing else delivered.
grep -qE '^Assistant \[[^]]*\]: .*Sentence one of the doomed answer' "$CONVO" \
    && fail "the cut turn's reply was delivered into the conversation" \
    || ok "the cut turn delivered nothing into the conversation"
grep -q "held — not spoken" "$CONVO" \
    && fail "the cut turn was recorded as a held reply — that is the supersede path, not the cut" \
    || ok "…and left no held block either: the fold is the record"
check_eq "exactly one reply entered the conversation this exchange" \
    "$(sandbox_count_in '^Assistant \[' "$CONVO")" "2"
grep -qF "ANSWER-TO NEW what about the weather then" "$CONVO" \
    && ok "and it is the consolidated one" \
    || { echo "--- convo ---"; cat "$CONVO"; fail "the surviving reply is not in the conversation"; }
grep -q "cut — he spoke over this" "$SESSLOG" \
    && ok "the cut turn's journal names what happened to it" \
    || { echo "--- sessions ---"; cat "$SESSLOG"; fail "no cut outcome in the session journal"; }
grep -q "part-written: Sentence one of the doomed answer" "$SESSLOG" \
    && ok "…and keeps the part-written words — nothing is lost by the cut" \
    || fail "the part-written reply is not in the cut turn's outcome"
check_eq "no ticket is left for anything to queue behind" \
    "$(ls "$ORDERDIR"/*.ticket 2>/dev/null | wc -l)" "0"
check_eq "no cut marker outlives the exchange" \
    "$(ls "$ORDERDIR"/*.cut 2>/dev/null | wc -l)" "0"

# --- the knob, and the pushback boundary, at unit level --------------------
echo
echo "the knob and the pushback boundary:"
(
    set +eu
    source "$REPO/lib/common.sh" >/dev/null 2>&1
    rm -rf "$ORDERDIR"
    printf 'User [12:00]: how did that go\nAssistant [12:01]: It went fine.\n\n' > "$CONVOFILE"

    # An ordinary follow-up cuts the turn in flight (the default).
    sleep 30 & INFLIGHT=$!
    TURN_ORDER_WAIT=180
    turn_order_take desk "the first ordinary question"
    FIRSTSEQ="$TURN_SEQ"
    printf '%s\t%s\t%s\tdesk\t%s\t%s\n' "$INFLIGHT" "$(_proc_starttime "$INFLIGHT")" \
        "$(date +%s)" "/nonexistent.log" "the first ordinary question" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" "$FIRSTSEQ")"
    turn_order_take desk "and what about the weather"
    [ -s "$(printf '%s/%09d.cut' "$TURN_ORDER_DIR" "$FIRSTSEQ")" ] \
        && ok "an ordinary follow-up cuts the turn in flight" \
        || fail "no cut marker was written for the in-flight turn"
    [ -s "$(printf '%s/%09d.superseded' "$TURN_ORDER_DIR" "$FIRSTSEQ")" ] \
        && fail "an ordinary follow-up wrote a supersede marker — that close belongs to pushback alone" \
        || ok "…and it is a cut, not a supersede: both inputs are still wanted, in one reply"
    grep -qF "and what about the weather" \
        "$(printf '%s/%09d.cut' "$TURN_ORDER_DIR" "$FIRSTSEQ")" \
        && ok "the cut marker carries the message that cut it" \
        || fail "the cut marker does not carry the cutting message"
    # The interrupt context is armed for the cutter's own prompt build.
    case "$(_interrupt_context)" in
        *"HE SPOKE OVER YOU"*"the first ordinary question"*) \
            ok "the cutter's prompt block quotes the cut turn's input" ;;
        *) fail "the interrupt context is missing or empty" "$(_interrupt_context)" ;;
    esac
    kill "$INFLIGHT" 2>/dev/null; wait "$INFLIGHT" 2>/dev/null

    # STRONG pushback still takes the harder close: supersede, never cut.
    rm -rf "$ORDERDIR"; TURN_INTERRUPT_NOTE=""
    sleep 30 & INFLIGHT=$!
    turn_order_take desk "the first ordinary question"
    FIRSTSEQ="$TURN_SEQ"
    printf '%s\t%s\t%s\tdesk\t%s\t%s\n' "$INFLIGHT" "$(_proc_starttime "$INFLIGHT")" \
        "$(date +%s)" "/nonexistent.log" "the first ordinary question" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" "$FIRSTSEQ")"
    turn_order_take desk "No, you are wrong, stop assuming I'm wrong"
    [ -s "$(printf '%s/%09d.superseded' "$TURN_ORDER_DIR" "$FIRSTSEQ")" ] \
        && ok "STRONG pushback still supersedes" \
        || fail "pushback no longer supersedes the turn in flight"
    [ -s "$(printf '%s/%09d.cut' "$TURN_ORDER_DIR" "$FIRSTSEQ")" ] \
        && fail "pushback also wrote a cut marker — one close per turn" \
        || ok "…and does not also cut: the dead theory is not folded forward"
    kill "$INFLIGHT" 2>/dev/null; wait "$INFLIGHT" 2>/dev/null

    # TURN_INTERRUPT=0 restores the pure delivery queue.
    rm -rf "$ORDERDIR"; TURN_INTERRUPT_NOTE=""
    sleep 30 & INFLIGHT=$!
    TURN_INTERRUPT=0
    turn_order_take desk "the first ordinary question"
    FIRSTSEQ="$TURN_SEQ"
    printf '%s\t%s\t%s\tdesk\t%s\t%s\n' "$INFLIGHT" "$(_proc_starttime "$INFLIGHT")" \
        "$(date +%s)" "/nonexistent.log" "the first ordinary question" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" "$FIRSTSEQ")"
    turn_order_take desk "and what about the weather"
    [ -s "$(printf '%s/%09d.cut' "$TURN_ORDER_DIR" "$FIRSTSEQ")" ] \
        && fail "TURN_INTERRUPT=0 still cut the turn in flight" \
        || ok "TURN_INTERRUPT=0 takes the seat and cuts nothing — the queue is the backstop"
    kill "$INFLIGHT" 2>/dev/null; wait "$INFLIGHT" 2>/dev/null

    # A turn that has been cut stops waiting on the queue at once.
    rm -rf "$ORDERDIR"; TURN_INTERRUPT=1
    sleep 30 & LIVE=$!
    printf '%s\t%s\t%s\tdesk\n' "$LIVE" "$(_proc_starttime "$LIVE")" "$(date +%s)" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" 1)"
    printf '2\n' > "$TURN_ORDER_DIR/next"
    TURN_SEQ=2
    printf '%s\t%s\t%s\tdesk\n' "$$" "$(_proc_starttime $$)" "$(date +%s)" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" 2)"
    printf '3\this newer message\n' > "$(printf '%s/%09d.cut' "$TURN_ORDER_DIR" 2)"
    TURN_ORDER_WAIT=30
    S=$(date +%s)
    turn_order_wait
    W=$(( $(date +%s) - S ))
    [ "$W" -lt 2 ] && ok "a cut turn does not wait on earlier tickets — nothing it holds is going out" \
        || fail "a cut turn sat in the delivery queue" "waited ${W}s"
    # …and nothing waits on a CUT earlier ticket either (the 15d discipline).
    rm -f "$(printf '%s/%09d.cut' "$TURN_ORDER_DIR" 2)"
    printf '9\the spoke again\n' > "$(printf '%s/%09d.cut' "$TURN_ORDER_DIR" 1)"
    S=$(date +%s)
    turn_order_wait
    W=$(( $(date +%s) - S ))
    [ "$W" -lt 2 ] && ok "nothing waits on a cut earlier ticket" \
        || fail "a live answer queued behind a reply that will never be spoken" "waited ${W}s"
    kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
    exit 0
) || true

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
