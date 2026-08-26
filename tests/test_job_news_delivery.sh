#!/usr/bin/env bash
# A detached job's completion news survives the busy and in-flight gates.
#
# specs/wake-queue.md rule 27d, specs/jobs.md rule 7c. The completion wake is
# a job's only channel back to him, and both busy-moment exits were measured
# losing it on 2026-08-25: a turn in flight sent the clock build's spoken
# result to the five-minute hot-hold and he asked before it fired, and a busy
# moment muted the install build's result with no re-booking at all — the
# verified news existed in the journal alone. A busy moment may DELAY job
# news, never consume it.
#
#    1. who the discipline recognises: the job-runner booking identity, and
#       nobody else; the knob switches it off
#    2. a spoken job return beside a live turn ticket WAITS the gate out and
#       reaches the phone — pointer, conversation and synthesiser all carrying
#       the words, exactly once, only after the ticket cleared, nothing booked
#    3. the same through a recording in progress (the busy gate)
#    4. an utterance that outlasts the wait delivers nothing and re-books the
#       ORIGINAL reason under the job-runner identity, stamped for rule 27b —
#       and the comeback, fired in a quiet moment, delivers in full, once
#    5. a second re-book of the same news folds into the pending one, and an
#       already-stamped reason is never re-stamped
#    6. a non-job wake keeps the ordinary busy mute exactly, and
#       WAKE_JOB_NEWS_HOLD=0 restores the old exits for a job's return
#
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
JOURNAL="${DESKCRAB_STATE_PREFIX}-sessions.log"
ORDERDIR="${DESKCRAB_STATE_PREFIX}-turn-order"
SPEECH="${DESKCRAB_STATE_PREFIX}-speech.log"
PHONE_SEEN="${DESKCRAB_STATE_PREFIX}-phone-seen"
PHONE_PTR="${DESKCRAB_STATE_PREFIX}-wake-audio"
TTSPID="${DESKCRAB_STATE_PREFIX}-tts.pid"

NEWS="The clock-mender build finished green and the clock keeps time."
JOB_REASON="Detached job clock-mender finished (collected, exit 0). Task was: mend the clock — full output in the job log. Read it and verify its claims yourself before repeating them."

# The synthesiser's whole phone pipeline, made to succeed: ffmpeg writes a
# plausible clip to its last argument and ffprobe answers the exact probe
# synth_opus demands, so a delivered wake reaches the PHONE hand-off — the
# pointer file the /watch loop serves — and not only the desk fallback.
sandbox_stub ffmpeg <<'EOF'
#!/bin/bash
cat > /dev/null 2>/dev/null
out=""
for a in "$@"; do out="$a"; done
[ -n "$out" ] && head -c 4096 /dev/zero > "$out"
exit 0
EOF
sandbox_stub ffprobe <<'EOF'
#!/bin/bash
cat > /dev/null 2>/dev/null
printf 'codec_name=opus\ncodec_type=audio\nformat_name=ogg\nduration=1.20\n'
exit 0
EOF

sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
python3 - <<'PYEOF'
import json
text = "$NEWS"
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result"}))
PYEOF
EOF

printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"
# He last spoke from the phone, so a delivered wake goes there.
printf 'phone\t%s\n' "$(date +%s)" > "$WORK/last-origin"

write_conf() {  # <WAKE_JOB_NEWS_WAIT> [WAKE_JOB_NEWS_HOLD]
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
WAKE_FLIGHT_HOLD=1
WAKE_JOB_NEWS_WAIT=$1
WAKE_JOB_NEWS_POLL=0.2
WAKE_JOB_NEWS_RETRY=300
WAKE_JOB_NEWS_HOLD=${2:-1}
EOF
}

proc_start() {  # <pid> — the same read _proc_starttime makes
    awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[20] }' \
        "/proc/$1/stat" 2>/dev/null || echo 0
}

TICKET_KEEPER=""
plant_ticket() {
    mkdir -p "$ORDERDIR"
    sleep 300 &
    TICKET_KEEPER=$!
    printf '%s\t%s\t%s\tdesk\n' "$TICKET_KEEPER" "$(proc_start "$TICKET_KEEPER")" \
        "$(date +%s)" > "$ORDERDIR/000000001.ticket"
}
sandbox_at_exit '[ -n "$TICKET_KEEPER" ] && kill "$TICKET_KEEPER" 2>/dev/null'

run_wake() {  # <booked-by> [unit-id]
    : > "$SANDBOX_SPOKEN_LOG"; : > "$SANDBOX_NOTIFY_LOG"
    : > "$CONVO"
    rm -f "$PHONE_PTR"
    touch "$PHONE_SEEN"
    "$REPO/crab" wake event "$JOB_REASON" "${2:-}" "$1" >/dev/null 2>&1 || true
}

news_records() {
    grep -lF "Detached job clock-mender" "$WAKES_DIR"/*.wake 2>/dev/null || true
}
news_count() { news_records | wc -l; }

delivered_checks() {  # <label> <gate-cleared-epoch-file>
    check_eq "$1: the news was synthesised exactly once" \
        "$(sandbox_count_in 'clock keeps time' "$SANDBOX_SPOKEN_LOG")" "1"
    check "$1: the phone hand-off pointer carries the words" \
        grep -qF "clock keeps time" "$PHONE_PTR"
    check_eq "$1: the conversation holds the news exactly once" \
        "$(sandbox_count_in 'clock keeps time' "$CONVO")" "1"
    check "$1: under the wake marker, so /watch shows it as hers" \
        grep -qF "[Autonomous wake" "$CONVO"
    check_eq "$1: and NOTHING was re-booked — delivered news books no comeback" \
        "$(news_count)" "0"
    if [ -n "${2:-}" ] && [ -s "$2" ]; then
        local CLEARED PTR_AT
        CLEARED="$(cat "$2")"
        PTR_AT="$(stat -c %Y "$PHONE_PTR" 2>/dev/null || echo 0)"
        check "$1: delivery happened only after the gate cleared" \
            [ "$PTR_AT" -ge "$CLEARED" ]
    fi
}

echo "who the discipline recognises — provenance, never the reply:"
booked_as() {  # <extra setup shell>
    sandbox_bash "$1
                  wake_carries_job_news && printf yes || printf no"
}
check_eq "a wake booked by job-runner is job news" \
    "$(booked_as "WAKE_BOOKED_BY=job-runner")" "yes"
check_eq "a wake booked by herself is not" \
    "$(booked_as "WAKE_BOOKED_BY=herself")" "no"
check_eq "an anonymous wake is not" "$(booked_as ":")" "no"
check_eq "and the knob at zero switches the reading off" \
    "$(booked_as "WAKE_JOB_NEWS_HOLD=0 WAKE_BOOKED_BY=job-runner")" "no"

# Clear the gate only once the wake is PROVABLY inside the rule-27d wait —
# the wait announces itself on the speech log the moment it begins. So on the
# pre-change tree these scenarios meet a STANDING gate (hold and mute, the
# old exits), and only the in-process wait turns them into deliveries. The
# extra beat puts the wake a poll or two into its loop before the gate
# clears; the bounded fallback keeps a tree with no wait from wedging the
# test, and the caller waits for this subshell so a late clear can never
# bleed into the next scenario.
KILLER_PID=""
clear_when_gated() {  # <clear command> <witness file>
    local BEFORE
    BEFORE="$(sandbox_count_in 'job news: delivery is waiting' "$SPEECH")"
    (
        n=0
        while [ "$(sandbox_count_in 'job news: delivery is waiting' "$SPEECH")" -le "$BEFORE" ]; do
            sleep 0.1
            n=$(( n + 1 )); [ "$n" -gt 100 ] && break
        done
        sleep 0.5
        eval "$1"
        date +%s > "$2"
        touch "$PHONE_SEEN"
    ) &
    KILLER_PID=$!
}

echo
echo "a spoken job return beside a live turn waits the ticket out, then lands:"
write_conf 20
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
plant_ticket
CLEARED_AT="$SANDBOX/witness/flight-cleared"
rm -f "$CLEARED_AT"
clear_when_gated 'kill "$TICKET_KEEPER" 2>/dev/null' "$CLEARED_AT"
run_wake job-runner
wait "$KILLER_PID" 2>/dev/null
delivered_checks "flight" "$CLEARED_AT"
check "the journal never called it held" \
    bash -c '! grep -q "job news met a moment" "$1" && ! grep -q "a turn was in flight" "$1"' _ "$JOURNAL"
rm -rf "$ORDERDIR"

echo
echo "the same news through a recording in progress:"
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
touch "$DESKCRAB_PIDFILE"
CLEARED_AT="$SANDBOX/witness/busy-cleared"
rm -f "$CLEARED_AT"
clear_when_gated 'rm -f "$DESKCRAB_PIDFILE"' "$CLEARED_AT"
run_wake job-runner
wait "$KILLER_PID" 2>/dev/null
delivered_checks "busy" "$CLEARED_AT"
check "and it was never muted" \
    bash -c '! grep -q "muted — user was mid-interaction" "$1"' _ "$JOURNAL"
rm -f "$DESKCRAB_PIDFILE"

echo
echo "an utterance that outlasts the wait re-books the news whole:"
write_conf 1
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
touch "$TTSPID"
run_wake job-runner
check "nothing was synthesised" [ ! -s "$SANDBOX_SPOKEN_LOG" ]
check "no phone hand-off was made" bash -c '[ ! -e "$1" ]' _ "$PHONE_PTR"
check "and NOTHING entered the conversation" bash -c '[ ! -s "$1" ]' _ "$CONVO"
check "the journal says the news was re-booked whole" \
    grep -q "re-booked whole under the job-runner identity" "$JOURNAL"
check "and promises the comeback's moment" \
    bash -c 'grep -q "coming back in 5min" "$1"' _ "$JOURNAL"
check_eq "exactly one comeback wake stands" "$(news_count)" "1"
REC="$(news_records | head -n1)"
check_eq "under the job-runner identity — never hot-hold" \
    "$(cut -f5 "$REC")" "job-runner"
check_eq "as an EVENT wake" "$(cut -f2 "$REC")" "event"
BOOKED="$(cut -f3 "$REC")"
contains "$BOOKED" "Detached job clock-mender finished" \
    && ok "its reason is the ORIGINAL — job id, log, verify-first intact" \
    || fail "the comeback lost the original reason" "[$BOOKED]"
contains "$BOOKED" "held at" \
    && ok "with the held-at stamp, so rule 27b can judge the comeback" \
    || fail "the comeback reason carries no stamp" "[$BOOKED]"
contains "$BOOKED" "You had this to say" \
    && fail "the comeback wears the hot-hold prefix" "[$BOOKED]" \
    || ok "and never the hot-hold prefix"

echo
echo "...and the comeback, in a quiet moment, delivers the news — once:"
rm -f "$TTSPID"
UNIT="$(basename "$REC" .wake)"
SAVED_REASON="$BOOKED"
write_conf 20
: > "$SANDBOX_SPOKEN_LOG"; : > "$CONVO"; rm -f "$PHONE_PTR"; touch "$PHONE_SEEN"
"$REPO/crab" wake event "$SAVED_REASON" "$UNIT" job-runner >/dev/null 2>&1 || true
delivered_checks "comeback" ""

echo
echo "a second re-book of the same news folds into the pending one:"
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
FOLD="$(sandbox_bash "WAKE_REASON='$JOB_REASON' WAKE_BOOKED_BY=job-runner \
                      WAKE_KIND=event SESSION_START=$(date +%s)
                      wake_job_news_rebook && wake_job_news_rebook && printf folded")"
check_eq "both bookings answered that a comeback stands" "$FOLD" "folded"
check_eq "and exactly one record exists" "$(news_count)" "1"
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
sandbox_bash "WAKE_REASON='$JOB_REASON — held at 2026-08-25 02:06' \
              WAKE_BOOKED_BY=job-runner WAKE_KIND=event
              wake_job_news_rebook" >/dev/null
REC2="$(news_records | head -n1)"
[ -n "$REC2" ] || die "the stamped re-book booked nothing"
check_eq "an already-stamped reason is never re-stamped" \
    "$(grep -oF 'held at' "$REC2" | wc -l)" "1"
check "and the original stamp survives verbatim" \
    grep -qF "held at 2026-08-25 02:06" "$REC2"
rm -f "$WAKES_DIR"/*.wake 2>/dev/null

echo
echo "the ordinary wakes keep the ordinary exits:"
touch "$DESKCRAB_PIDFILE"
run_wake herself
check "a non-job wake beside a busy moment is muted as ever" \
    bash -c 'tail -n1 "$1" | grep -q "muted — user was mid-interaction"' _ "$JOURNAL"
check "nothing was synthesised" [ ! -s "$SANDBOX_SPOKEN_LOG" ]
check_eq "and nothing was re-booked for it" "$(news_count)" "0"
write_conf 20 0
run_wake job-runner
check "with the knob at zero a job return takes the old mute" \
    bash -c 'tail -n1 "$1" | grep -q "muted — user was mid-interaction"' _ "$JOURNAL"
check_eq "and books no comeback" "$(news_count)" "0"
rm -f "$DESKCRAB_PIDFILE"

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
