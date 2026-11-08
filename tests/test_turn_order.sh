#!/usr/bin/env bash
# Proof that replies leave in the order he said things — and that a reply he
# has already rejected does not leave at all.
#
# specs/turn-pipeline.md rules 15a-15e. The measurement these are written from,
# 2026-08-10, is in the spec: two desk turns thirty-one seconds apart, the
# second answered first because it was cheaper, and the first arriving a minute
# later carrying a theory he had spent that minute rejecting. He read it as her
# answering what he had just said. It was not.
#
#    1. two turns, the slow one first -> the transcript reads in arrival order
#    2. the fast turn does not deliver before the slow one it queued behind
#    3. pushback supersedes the turn in flight behind it: its reply is written
#       to the transcript MARKED unsaid, journalled in full with the message
#       that closed it, and never spoken
#    4. nothing waits on a superseded ticket — the release valve, without which
#       ordering delays a live answer behind a dead theory
#    5. a ticket whose process is gone is swept, not waited on
#    6. the bound expires and the reply goes out saying it went out of order
#    7. session_finish gives the place back however the turn ends
#    8. TURN_ORDER_WAIT=0 is the old behaviour, exactly
#
# The whole file runs with TURN_INTERRUPT=0: it pins the BACKSTOP. Under the
# shipped default an ordinary second utterance CUTS the turn in flight
# instead of queueing behind it (specs/turn-pipeline.md rule 15f), which is
# tests/test_turn_interrupt.sh's subject; what is proven here is the queue
# that catches everything the cut does not — the order of what delivers, the
# supersede close for pushback, the sweep, the bound, and the knob.
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

# The stub claude: the user's message is the last argument. It carries its own
# pacing — SLOW sleeps, FAST does not — so a test can put a long turn and a
# short one in flight together and know which would finish first.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do TEXT="$a"; done
case "$TEXT" in
    *SLOW*) sleep 4 ;;
    *MEDIUM*) sleep 2 ;;
esac
printf '%s\n' "$TEXT" >> "$SANDBOX_ASKED"
printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"ANSWER-TO %s"}]}}\n' "$TEXT"
printf '{"type":"result"}\n'
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
TURN_INTERRUPT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
LAST_ORIGIN_FILE="$WORK/last-origin"
WAKE_QUIET_HOURS=""
PIPER_VOICE="$WORK/voice.onnx"
EOF

export SANDBOX_ASKED="$WORK/asked.txt"
: > "$SANDBOX_ASKED"

# Something of hers already in the transcript: dispute_detect refuses to call
# anything pushback before she has said a word, which is correct and which
# every case here depends on.
seed_convo() {
    printf 'User [12:00]: how did that go\nAssistant [12:01]: It went fine.\n\n' > "$CONVO"
}

# Where a block sits in the transcript, by line number. -1 when it is absent.
block_line() {  # <needle>
    grep -n -- "$1" "$CONVO" 2>/dev/null | head -n1 | cut -d: -f1 || true
}

# --- 1 & 2: two turns, arrival order kept --------------------------------
seed_convo
rm -rf "$ORDERDIR"; : > "$SESSLOG"
"$REPO/crab" "SLOW tell me about the disk" >/dev/null 2>&1 &
FIRST=$!
sleep 1
"$REPO/crab" "FAST and what about the weather" >/dev/null 2>&1 &
SECOND=$!
wait "$FIRST" "$SECOND" 2>/dev/null

A="$(block_line 'ANSWER-TO SLOW')"
B="$(block_line 'ANSWER-TO FAST')"
if [ -n "$A" ] && [ -n "$B" ]; then
    check "the slow first message's reply is in the transcript above the fast second one's" \
        [ "$A" -lt "$B" ]
else
    fail "one of the two replies never reached the transcript" "slow=[$A] fast=[$B]"
fi
# And in the session journal, which is written at delivery order too.
SLOWLINE="$(grep -n 'replied: ANSWER-TO SLOW' "$SESSLOG" | head -n1 | cut -d: -f1)"
FASTLINE="$(grep -n 'replied: ANSWER-TO FAST' "$SESSLOG" | head -n1 | cut -d: -f1)"
if [ -n "$SLOWLINE" ] && [ -n "$FASTLINE" ]; then
    check "the session journal records them in arrival order, not finish order" \
        [ "$SLOWLINE" -lt "$FASTLINE" ]
else
    fail "the session journal is missing one of the two turns" "slow=[$SLOWLINE] fast=[$FASTLINE]"
fi
check "neither turn was journalled as delivered out of order" \
    [ "$(grep -c 'delivered out of order' "$SESSLOG")" = 0 ]
# Nothing is left behind: both tickets went back.
check "both turns gave their place in the queue back" \
    [ "$(ls "$ORDERDIR"/*.ticket 2>/dev/null | wc -l)" = 0 ]

# --- 3 & 4: pushback supersedes the turn behind it -------------------------
# The shape of 12:31. A slow turn is in flight; his next message rejects what
# it is about to say. The slow reply must be written down and not spoken, and
# the pushback's own reply must NOT wait for it.
seed_convo
rm -rf "$ORDERDIR"; : > "$SESSLOG"; : > "$SANDBOX_SPOKEN_LOG"
"$REPO/crab" "SLOW it was the quotation marks" >/dev/null 2>&1 &
FIRST=$!
sleep 1
START=$(date +%s)
"$REPO/crab" "You didn't have it in fucking quotations. Stop assuming I'm wrong you are wrong not me" >/dev/null 2>&1
WAITED=$(( $(date +%s) - START ))
check "the pushback reply did not queue behind the theory it had just rejected" \
    [ "$WAITED" -lt 3 ]
wait "$FIRST" 2>/dev/null

grep -q "Assistant .*(held — not spoken).*ANSWER-TO SLOW" "$CONVO" \
    && ok "the superseded reply is in the transcript, marked as words she did not say" \
    || { echo "--- convo ---"; cat "$CONVO"; \
         fail "the superseded reply is not in the transcript under the held marker"; }
grep -q '^Assistant \[[^]]*\]: ANSWER-TO SLOW' "$CONVO" \
    && fail "the superseded reply was committed as an ordinary delivered reply" \
    || ok "it was never committed as a delivered reply"
grep -q 'held — he had already moved past this' "$SESSLOG" \
    && ok "the session journal says it was held, and what closed it" \
    || { echo "--- sessions ---"; cat "$SESSLOG"; \
         fail "the journal does not record the hold"; }
grep -q 'unspoken reply: ANSWER-TO SLOW' "$SESSLOG" \
    && ok "the journal keeps the held words in full — nothing is lost by holding it" \
    || fail "the held reply's own words are not in the journal"
grep -q 'ANSWER-TO SLOW' "$SANDBOX_SPOKEN_LOG" 2>/dev/null \
    && { echo "--- spoken ---"; cat "$SANDBOX_SPOKEN_LOG"; \
         fail "the superseded reply reached the speakers"; } \
    || ok "the superseded reply never reached the speakers"
# The pushback's own answer is delivered normally.
grep -q "^Assistant \[[^]]*\]: ANSWER-TO You didn't have it" "$CONVO" \
    && ok "the reply to the message he actually sent last was delivered" \
    || fail "the pushback turn's own reply never landed"

# --- the phone takes its seat BEFORE the remote lock -----------------------
# specs/turn-pipeline.md rule 15a, phone.md rule 2. The ticket used to be
# taken inside the lock, so a phone pushback queued behind the very turn it
# was closing: it could not supersede until that turn had fully delivered,
# which is the 12:31 shape again with a lock in the middle. The seat is the
# moment the message arrived; a message parked at the lock has still arrived.
echo
echo "a phone pushback supersedes the phone turn it arrived behind:"
seed_convo
rm -rf "$ORDERDIR"; : > "$SESSLOG"
"$REPO/crab" remote "SLOW it was the quotation marks" > "$WORK/phone-first.json" 2>/dev/null &
FIRST=$!
sleep 1
"$REPO/crab" remote "Stop assuming I'm wrong you are wrong not me" \
    > "$WORK/phone-push.json" 2>/dev/null
wait "$FIRST" 2>/dev/null
# The JSON escapes the em dash (—), so the match stays on plain words.
grep -q "you had already moved past what this answered" "$WORK/phone-first.json" \
    && ok "the in-flight phone turn was told its moment had passed" \
    || fail "the earlier phone turn delivered as if nothing had closed it" \
            "$(cat "$WORK/phone-first.json" 2>/dev/null)"
grep -q "Assistant .*(held — not spoken).*ANSWER-TO SLOW" "$CONVO" \
    && ok "its reply is in the transcript, marked as words she did not say" \
    || fail "the superseded phone reply is not marked held in the transcript"
grep -q 'held — he had already moved past this' "$SESSLOG" \
    && ok "and the journal names the message that closed it" \
    || fail "the journal does not record the phone hold"
grep -q "ANSWER-TO Stop assuming" "$WORK/phone-push.json" \
    && ok "the pushback's own reply was delivered to the phone" \
    || fail "the pushback turn's reply never landed" \
            "$(cat "$WORK/phone-push.json" 2>/dev/null)"

# --- a remote lock wait that expires refuses the turn ----------------------
# phone.md rule 2: it used to fall through and run the turn UNLOCKED beside
# whatever had wedged the lock for ten minutes — two claude processes racing
# one conversation, the exact corruption the lock exists to prevent.
echo
echo "a remote lock wait that expires refuses the turn — it never runs unlocked:"
rm -rf "$ORDERDIR"
: > "$SANDBOX_ASKED"
flock "${DESKCRAB_STATE_PREFIX}-remote.lock" sleep 15 &
HOLDER=$!
sleep 1
OUT="$(REMOTE_LOCK_WAIT=1 "$REPO/crab" remote "hello are you in there" 2>/dev/null)"; RC=$?
contains "$OUT" "refused" && contains "$OUT" "nothing was run" \
    && ok "the client is told plainly that the turn was refused, and why" \
    || fail "no clear refusal reached the client" "[$OUT]"
grep -q "hello are you in there" "$SANDBOX_ASKED" \
    && fail "the refused turn still ran the model — unlocked, beside the wedge" \
    || ok "the model was never run"
check "the refusal reports failure, not success" [ "$RC" -ne 0 ]
check_eq "and no ticket was left for the next reply to queue behind" \
    "$(ls "$ORDERDIR"/*.ticket 2>/dev/null | wc -l)" "0"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# --- 5, 6, 7, 8: the queue's own arithmetic, at unit level -----------------
(
    set +eu
    source "$REPO/lib/common.sh" >/dev/null 2>&1
    rm -rf "$ORDERDIR"

    # A ticket whose process is gone is swept, never waited on. Left behind by
    # a turn killed without its trap, which is exactly what a stale ticket is.
    mkdir -p "$TURN_ORDER_DIR"
    printf '1\n' > "$TURN_ORDER_DIR/next"
    sleep 30 & DEAD=$!
    kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
    printf '%s\t%s\t%s\tdesk\n' "$DEAD" "999999" "$(date +%s)" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" 1)"
    printf '2\n' > "$TURN_ORDER_DIR/next"
    TURN_SEQ=3
    printf '%s\t%s\t%s\tdesk\n' "$$" "$(_proc_starttime $$)" "$(date +%s)" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" 3)"
    S=$(date +%s)
    turn_order_wait && W=$(( $(date +%s) - S )) || W=999
    [ "$W" -lt 2 ] && ok "a ticket whose process is gone is swept, not waited on" \
        || fail "a dead turn's ticket wedged the queue" "waited ${W}s"
    [ -e "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" 1)" ] \
        && fail "the dead ticket was left in the queue" \
        || ok "the dead ticket was removed"
    turn_order_release

    # The bound. A live earlier ticket that never delivers must not hold a
    # reply forever: past TURN_ORDER_WAIT the answer goes out and says so.
    sleep 30 & LIVE=$!
    printf '%s\t%s\t%s\tdesk\n' "$LIVE" "$(_proc_starttime "$LIVE")" "$(date +%s)" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" 4)"
    TURN_SEQ=5
    TURN_ORDER_WAIT=1
    S=$(date +%s)
    turn_order_wait && RC=0 || RC=1
    W=$(( $(date +%s) - S ))
    [ "$RC" = 1 ] && ok "the wait is bounded — it reports giving up rather than hanging" \
        || fail "an earlier turn that never finished held the reply past the bound"
    [ "$W" -le 3 ] || fail "the bound was not honoured" "waited ${W}s for a 1s bound"
    # …and a superseded earlier ticket is not waited on at all (rule 15d).
    printf '9\the has moved on\n' \
        > "$(printf '%s/%09d.superseded' "$TURN_ORDER_DIR" 4)"
    TURN_ORDER_WAIT=30
    S=$(date +%s)
    turn_order_wait && RC=0 || RC=1
    W=$(( $(date +%s) - S ))
    [ "$RC" = 0 ] && [ "$W" -lt 2 ] \
        && ok "a superseded earlier ticket is stepped over, not waited on" \
        || fail "a live answer queued behind a reply that will never be spoken" "rc=$RC waited=${W}s"
    kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

    # The place goes back however the turn ends: session_finish releases it.
    rm -rf "$TURN_ORDER_DIR"
    TURN_ORDER_WAIT=180
    turn_order_take desk "an ordinary question"
    [ -n "$TURN_SEQ" ] || fail "turn_order_take handed out no place at all"
    session_register "desktop turn"
    TURN_SEQ_KEPT="$TURN_SEQ"
    session_finish
    [ -e "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" "$TURN_SEQ_KEPT")" ] \
        && fail "session_finish left the turn's place in the queue" \
        || ok "session_finish gives the place back, so a killed turn cannot wedge the next one"

    # And the knob really is a knob.
    rm -rf "$TURN_ORDER_DIR"
    TURN_ORDER_WAIT=0
    turn_order_take desk "an ordinary question"
    [ -z "$TURN_SEQ" ] && [ ! -d "$TURN_ORDER_DIR" ] \
        && ok "TURN_ORDER_WAIT=0 takes no place and writes nothing" \
        || fail "the ordering knob does not switch the mechanism off"

    # Pushback marks what is in flight, and only what is in flight and earlier.
    rm -rf "$TURN_ORDER_DIR"
    TURN_ORDER_WAIT=180
    printf 'User [12:00]: how did that go\nAssistant [12:01]: It went fine.\n\n' > "$CONVOFILE"
    sleep 30 & INFLIGHT=$!
    turn_order_take desk "the first ordinary question"
    FIRSTSEQ="$TURN_SEQ"
    # Hand that ticket to a living process that is not us, so it reads as a
    # turn still generating rather than one that has gone.
    printf '%s\t%s\t%s\tdesk\n' "$INFLIGHT" "$(_proc_starttime "$INFLIGHT")" "$(date +%s)" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" "$FIRSTSEQ")"
    turn_order_take desk "No, you are wrong, stop assuming I'm wrong"
    [ -s "$(printf '%s/%09d.superseded' "$TURN_ORDER_DIR" "$FIRSTSEQ")" ] \
        && ok "pushback supersedes the turn still in flight behind it" \
        || fail "pushback left an in-flight turn free to answer a closed question"
    turn_order_superseded >/dev/null \
        && fail "the pushback turn superseded itself" \
        || ok "the message doing the superseding is not itself superseded"
    kill "$INFLIGHT" 2>/dev/null; wait "$INFLIGHT" 2>/dev/null

    # An ordinary follow-up is not pushback and closes nothing.
    rm -rf "$TURN_ORDER_DIR"
    sleep 30 & INFLIGHT=$!
    turn_order_take desk "the first ordinary question"
    FIRSTSEQ="$TURN_SEQ"
    printf '%s\t%s\t%s\tdesk\n' "$INFLIGHT" "$(_proc_starttime "$INFLIGHT")" "$(date +%s)" \
        > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" "$FIRSTSEQ")"
    turn_order_take desk "and while you are there, what is the weather doing"
    [ -s "$(printf '%s/%09d.superseded' "$TURN_ORDER_DIR" "$FIRSTSEQ")" ] \
        && fail "an ordinary second question silenced the answer to the first" \
        || ok "an ordinary follow-up closes nothing — both answers are still wanted"
    kill "$INFLIGHT" 2>/dev/null; wait "$INFLIGHT" 2>/dev/null
    exit 0
) || true

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
