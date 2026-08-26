#!/usr/bin/env bash
# A wake that fires while a turn of HIS is in flight holds its whole output —
# the spoken half included — and hands the words back through the queue.
#
# specs/wake-queue.md rule 27c. The hot hold (rule 27a) reads the clock and
# holds only what she already chose not to speak; this reads the delivery
# queue's own tickets (turn-pipeline rule 15a) — a desk or phone reply owed
# and not yet delivered — and holds everything, because words landing in that
# window land in the answer's slot whatever they say. The gate reads tickets
# and pids, never the reply: it decides WHEN, not WHETHER, and the comeback
# meets the staleness gate in a quiet minute.
#
#    1. how "in flight" is read, at unit level: a live ticket, a dead one, a
#       recycled pid, the knob at zero
#    2. a SPOKEN wake beside a live ticket reaches no speaker, no notifier,
#       no window, no conversation — and the journal says a turn was in flight
#    3. the held words come back through the queue's one door, stamped
#    4. the same wake with the ticket's process dead is delivered in full —
#       the control that makes the hold mean something
#    5. WAKE_FLIGHT_HOLD=0 restores the old behaviour exactly
#
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
JOURNAL="${DESKCRAB_STATE_PREFIX}-sessions.log"
ORDERDIR="${DESKCRAB_STATE_PREFIX}-turn-order"
SPOKEN_NOTE="The disk you asked about filled up ten minutes ago and something has to go."

stub_reply() {  # <reply text>
    sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
python3 - <<'PYEOF'
import json
text = "$1"
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result"}))
PYEOF
EOF
}

printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"

write_conf() {  # <WAKE_FLIGHT_HOLD value>
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
CONVO_HOT_WINDOW=0
WAKE_HOT_RETRY=300
WAKE_FLIGHT_HOLD=$1
EOF
}

proc_start() {  # <pid> — the same read _proc_starttime makes
    awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[20] }' \
        "/proc/$1/stat" 2>/dev/null || echo 0
}

# A live interactive turn, as the delivery queue records one: a ticket whose
# pid and process start time belong to a process that is genuinely alive.
TICKET_KEEPER=""
plant_ticket() {
    mkdir -p "$ORDERDIR"
    sleep 300 &
    TICKET_KEEPER=$!
    printf '%s\t%s\t%s\tdesk\n' "$TICKET_KEEPER" "$(proc_start "$TICKET_KEEPER")" \
        "$(date +%s)" > "$ORDERDIR/000000001.ticket"
}
sandbox_at_exit '[ -n "$TICKET_KEEPER" ] && kill "$TICKET_KEEPER" 2>/dev/null'

run_wake() {
    : > "$SANDBOX_SPOKEN_LOG"; : > "$SANDBOX_NOTIFY_LOG"; : > "$SANDBOX_DISPLAY_LOG"
    : > "$CONVO"
    rm -f "$WAKES_DIR"/*.wake 2>/dev/null
    rm -f "${DESKCRAB_STATE_PREFIX}"-display-*.md 2>/dev/null
    "$REPO/crab" wake event "flight-hold test: the disk report" >/dev/null 2>&1 || true
}

held_records() {
    grep -lF "while he was mid-conversation" "$WAKES_DIR"/*.wake 2>/dev/null || true
}
held_count() { held_records | wc -l; }
held_field() {  # <field number>
    local f; f="$(held_records | head -n1)"
    [ -n "$f" ] && cut -f"$1" "$f" || true
}

echo "how in-flight is read, and by what:"
in_flight() {  # <extra setup shell>
    sandbox_bash "TURN_ORDER_DIR='$ORDERDIR'
                  $1
                  interactive_turn_in_flight && printf yes || printf no"
}
plant_ticket
check_eq "a ticket whose process is alive is a turn in flight" "$(in_flight ":")" "yes"
check_eq "the knob at zero switches the reading off" \
    "$(in_flight "WAKE_FLIGHT_HOLD=0")" "no"
printf '%s\t%s\t%s\tdesk\n' "$TICKET_KEEPER" "1" "$(date +%s)" \
    > "$ORDERDIR/000000002.ticket"
kill "$TICKET_KEEPER" 2>/dev/null; wait "$TICKET_KEEPER" 2>/dev/null
sleep 0.2
check_eq "a ticket whose process is gone is not a turn" "$(in_flight ":")" "no"
rm -rf "$ORDERDIR"
check_eq "and no queue at all is not a turn either" "$(in_flight ":")" "no"

echo
echo "a SPOKEN wake beside a live turn reaches nobody:"
write_conf 1
stub_reply "$SPOKEN_NOTE"
plant_ticket
run_wake
check "nothing was synthesised" [ ! -s "$SANDBOX_SPOKEN_LOG" ]
check "no notification was raised" [ ! -s "$SANDBOX_NOTIFY_LOG" ]
check "no display window was opened" \
    bash -c 'ls "${DESKCRAB_STATE_PREFIX}"-display-*.md >/dev/null 2>&1 && exit 1 || exit 0'
check "and NOTHING entered the conversation" bash -c '[ ! -s "$1" ]' _ "$CONVO"

echo
echo "...and the record says a turn was in flight, with the words kept:"
check "the journal names the turn in flight" grep -q "a turn was in flight" "$JOURNAL"
check "and keeps what the wake would have said" grep -qF "filled up ten minutes ago" "$JOURNAL"
check "and promises the comeback only because one stands" \
    bash -c 'tail -n1 "$1" | grep -q "coming back in 5min"' _ "$JOURNAL"

echo
echo "the held words come back through the queue, stamped:"
check_eq "exactly one comeback wake was booked" "$(held_count)" "1"
check_eq "under the hot-hold identity, so the queue reads as ever" \
    "$(held_field 5)" "hot-hold"
check_eq "as an EVENT wake" "$(held_field 2)" "event"
BOOKED="$(held_field 3)"
contains "$BOOKED" "filled up ten minutes ago" \
    && ok "it carries the spoken words it was holding" \
    || fail "the comeback lost the held words" "[$BOOKED]"
contains "$BOOKED" "held at" \
    && ok "and the held-at stamp, so the staleness gate can judge the comeback" \
    || fail "the comeback reason carries no stamp" "[$BOOKED]"

echo
echo "the same wake with the turn finished is delivered in full — the control:"
kill "$TICKET_KEEPER" 2>/dev/null; wait "$TICKET_KEEPER" 2>/dev/null
sleep 0.2
run_wake
check "it was synthesised" grep -qF "filled up ten minutes ago" "$SANDBOX_SPOKEN_LOG"
check "and it is in the conversation" grep -qF "filled up ten minutes ago" "$CONVO"
check_eq "and nothing was held" "$(held_count)" "0"

echo
echo "with the knob at zero, nothing changes from before the gate existed:"
write_conf 0
plant_ticket
run_wake
check "the wake is delivered exactly as it always was" \
    grep -qF "filled up ten minutes ago" "$CONVO"
check_eq "and nothing was held" "$(held_count)" "0"

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
