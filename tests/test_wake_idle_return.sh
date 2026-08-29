#!/bin/bash
# The own-time return — specs/wake-queue.md rules 40a-40f.
# Run: bash tests/test_wake_idle_return.sh
#
# The origin (2026-08-26): a single 23:20 wake stood on the queue telling her
# to develop a want at that hour. The user's correction: an appointment to be
# spontaneous is still an appointment, and one firing cannot make wants
# develop — her own time has to arise from idleness. So the standing
# reason-less return became the mechanism: at fire time it measures genuine
# idleness, activity re-books it with conversation RESETTING the quiet window,
# a genuinely idle house runs the choosing session on sol at medium, and the
# floor's jittered delay keeps the opportunities recurring without a clock
# ritual.
#
# The contract under test:
#   - a fresh conversation origin defers the return by the REMAINDER of the
#     quiet window plus the pinned jitter — reset, not a flat postponement —
#     with no session started, the original booker and any overrides kept,
#     and the deferral on the ledger (rules 40a, 40b);
#   - a live delivery-queue ticket and a running detached builder each defer
#     at the recheck delay; the same firing with the ticket dead or the
#     builder finished runs (rule 40a's other three senses);
#   - a genuinely idle house runs the choosing session on sol at medium
#     through the codex engine, ledgered own-time (rules 40c, 40f);
#   - the choosing agenda is an open field: doing nothing named as a real
#     choice, no shelf title picked, the old work-order sentence gone, the
#     night's builders holding repairs and owed engineering, wake-at offered
#     for a pursuit's own continuation (rule 40d);
#   - a scheduled wake WITH a reason and an event wake each still run beside
#     a fresh origin — rule 20 stands for every wake with an agenda;
#   - after a choosing session the floor books the next opportunity at base
#     plus the pinned jitter, and a second idle firing chooses again — one
#     quiet result never ends the chain (rule 40e);
#   - IDLE_RETURN=0 restores the flat floor, the ordinary wake model and the
#     wants agenda exactly (rule 40e's stand-down).
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
ORDERDIR="${DESKCRAB_STATE_PREFIX}-turn-order"
ORIGIN="$SANDBOX/last-origin"
LEDGER="$WAKES_DIR/ledger.log"

# The knobs, pinned so every moment in this file is assertable: quiet window
# 600s, recheck 300s, floor base 1200s, jitter exactly 7 (the deterministic
# seam of rule 40e).
write_conf() {  # [extra lines...]
    cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
WANTS_FILE="$SANDBOX/wants.md"
LAST_ORIGIN_FILE="$ORIGIN"
WAKE_QUIET_HOURS=""
IDLE_RETURN_QUIET=600
IDLE_RETURN_RECHECK=300
IDLE_RETURN_BASE=1200
IDLE_RETURN_SPREAD=500
IDLE_RETURN_JITTER=7
EOF
    local line
    for line in "$@"; do printf '%s\n' "$line" >> "$DESKCRAB_CONF"; done
}
write_conf

# The shelf carries one distinctive title, so "no shelf item is preselected"
# is assertable: the title may sit in the system prompt's shelves layer, but
# the AGENDA the choosing session is handed must never name it.
printf '# Wants\n\n- **KLAXON_HORN_RESTORATION** — bring the old horn back\n' \
    > "$SANDBOX/wants.md"

records() { ls "$WAKES_DIR"/*.wake 2>/dev/null | wc -l; }
field() {  # <record file> <n>
    awk -F'\t' -v n="$2" '{print $n; exit}' "$1"
}
one_record() { ls -1 "$WAKES_DIR"/*.wake 2>/dev/null | head -1; }
led_count() { awk -F'\t' -v a="$1" '$2 == a { n++ } END { print n + 0 }' "$LEDGER" 2>/dev/null; }
clean_queue() { rm -f "$WAKES_DIR"/*.wake; }
origin_ago() {  # <seconds ago>
    printf 'desk\t%s\n' "$(( $(date +%s) - $1 ))" > "$ORIGIN"
}
fire() {  # <kind> <reason> [booked-by] [effort] [model] — one wake, whole path
    "$REPO/crab" wake "$1" "$2" "deskcrab-wake-idle-$RANDOM" \
        "${3:-wake-chain-floor}" "${4:-}" "${5:-}" >/dev/null 2>&1 || true
}
clear_logs() { : > "$SANDBOX_CLAUDE_LOG"; : > "$SANDBOX_CODEX_LOG"; }
claude_ran() { sandbox_count_in '--output-format' "$SANDBOX_CLAUDE_LOG"; }
sol_ran() { sandbox_count_in '-m gpt-5.6-sol' "$SANDBOX_CODEX_LOG"; }

proc_start() {  # <pid> — the same read _proc_starttime makes
    awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[20] }' \
        "/proc/$1/stat" 2>/dev/null || echo 0
}
KEEPER=""
sandbox_at_exit '[ -n "$KEEPER" ] && kill "$KEEPER" 2>/dev/null'

# ---------------------------------------------------------------------------
echo "the jitter's deterministic seam, at unit level:"
run() { sandbox_bash "$*"; }
check_eq "a pinned jitter is used verbatim" \
    "$(run 'IDLE_RETURN_JITTER=42 idle_return_jitter')" "42"
J="$(run 'IDLE_RETURN_JITTER= IDLE_RETURN_SPREAD=500 idle_return_jitter')"
check "an unpinned jitter stays inside the spread" \
    bash -c '[ "$1" -ge 0 ] && [ "$1" -le 500 ]' _ "$J"

echo
echo "a fresh conversation origin defers the return — reset, not postponement:"
clean_queue; clear_logs; rm -f "$LEDGER"
origin_ago 100
BEFORE=$(date +%s)
fire scheduled ""
check_eq "no session was started on either engine" \
    "$(( $(claude_ran) + $(sol_ran) ))" "0"
check_eq "exactly one booking took the fired wake's place" "$(records)" "1"
REC="$(one_record)"
check_eq "re-booked scheduled" "$(field "$REC" 2)" "scheduled"
check_eq "with the reason still empty — no agenda was invented" \
    "$(field "$REC" 3)" ""
check_eq "by the original booker, so the return stays recognisable" \
    "$(field "$REC" 5)" "wake-chain-floor"
DELAY=$(( $(field "$REC" 1) - BEFORE ))
# 600s quiet minus ~100s since his word, plus the pinned 7 — the window is
# measured from HIS LAST MESSAGE, so the return lands a full quiet window
# after it, never a flat push-back from now.
check "the delay is the remainder of the quiet window plus jitter (got ${DELAY}s, want ~507)" \
    bash -c '[ "$1" -ge 500 ] && [ "$1" -le 512 ]' _ "$DELAY"
check_eq "the deferral is on the ledger under its own action" "$(led_count idle-defer)" "1"
check "naming the conversation as what it found" \
    grep -q "he spoke .*quiet starts over" "$LEDGER"

echo
echo "...and a deferral keeps a booking's own effort and model pins:"
clean_queue
origin_ago 100
fire scheduled "" herself high opus
REC="$(one_record)"
check "the deferred booking exists" test -n "$REC"
check_eq "keeping the effort override" "$(field "$REC" 6)" "high"
check_eq "and the model pin — rule 13a/13b survive this deferral too" \
    "$(field "$REC" 7)" "opus"
check_eq "under the booker it arrived with" "$(field "$REC" 5)" "herself"

echo
echo "a live interactive turn defers at the recheck delay:"
clean_queue; clear_logs
rm -f "$ORIGIN"
mkdir -p "$ORDERDIR"
sleep 300 & KEEPER=$!
printf '%s\t%s\t%s\tdesk\n' "$KEEPER" "$(proc_start "$KEEPER")" "$(date +%s)" \
    > "$ORDERDIR/000000001.ticket"
BEFORE=$(date +%s)
fire scheduled ""
check_eq "no session beside a turn in flight" \
    "$(( $(claude_ran) + $(sol_ran) ))" "0"
REC="$(one_record)"
check "the return re-booked itself" test -n "$REC"
DELAY=$(( $(field "$REC" 1) - BEFORE ))
check "at the recheck delay plus jitter (got ${DELAY}s, want ~307)" \
    bash -c '[ "$1" -ge 305 ] && [ "$1" -le 312 ]' _ "$DELAY"
check "the ledger names the turn in flight" \
    grep -q "interactive turn is in flight" "$LEDGER"

echo
echo "...and the same firing with the ticket's process dead runs:"
clean_queue; clear_logs
kill "$KEEPER" 2>/dev/null; wait "$KEEPER" 2>/dev/null; KEEPER=""
sleep 0.2
fire scheduled ""
check_eq "the choosing session ran once the turn was gone" "$(sol_ran)" "1"
rm -rf "$ORDERDIR"

echo
echo "a running detached builder defers the return:"
clean_queue; clear_logs
sleep 300 & KEEPER=$!
"$SANDBOX_REPO/lib/job-status" new "$JOBS_DIR" idle-test-job \
    "a build mid-flight" "" "$SANDBOX/home" >/dev/null 2>&1
"$SANDBOX_REPO/lib/job-status" set "$JOBS_DIR/idle-test-job.json" \
    state=running pid="$KEEPER" pidstart="$(proc_start "$KEEPER")" \
    started=now >/dev/null 2>&1
BEFORE=$(date +%s)
fire scheduled ""
check_eq "no session beside a running builder" \
    "$(( $(claude_ran) + $(sol_ran) ))" "0"
REC="$(one_record)"
check "the return re-booked itself" test -n "$REC"
DELAY=$(( $(field "$REC" 1) - BEFORE ))
check "at the recheck delay plus jitter (got ${DELAY}s, want ~307)" \
    bash -c '[ "$1" -ge 305 ] && [ "$1" -le 312 ]' _ "$DELAY"
check "the ledger names the builder" grep -q "builder is running" "$LEDGER"

echo
echo "...and with the builder finished the hour is hers:"
clean_queue; clear_logs
kill "$KEEPER" 2>/dev/null; wait "$KEEPER" 2>/dev/null; KEEPER=""
"$SANDBOX_REPO/lib/job-status" set "$JOBS_DIR/idle-test-job.json" \
    state=finished finished=now >/dev/null 2>&1
fire scheduled ""
check_eq "the choosing session ran" "$(sol_ran)" "1"

echo
echo "a genuinely idle house chooses on sol at medium, and it is ledgered:"
check "the codex engine took it as the sol slug" \
    grep -q -- "-m gpt-5.6-sol" "$SANDBOX_CODEX_LOG"
check "at medium reasoning effort" \
    grep -q -- "model_reasoning_effort=medium" "$SANDBOX_CODEX_LOG"
check_eq "and the claude walk was never booted for it" "$(claude_ran)" "0"
check "the choosing session is on the ledger as own-time" \
    grep -q "own-time" "$LEDGER"

echo
echo "the choosing agenda is an open field, prescribing nothing:"
AGENDA="$(cat "$SANDBOX_CODEX_LOG")"
has() { grep -qiE -- "$2" <<<"$1"; }
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }
check "doing nothing is named as a real choice" \
    has "$AGENDA" 'doing nothing.*real a choice|real choice'
check "an empty hour is told it has not failed" \
    has "$AGENDA" 'has not failed'
check "the field is open — practise, make, observe" \
    has "$AGENDA" 'practise'
check "talking to him is one of the choices, behind the delivery gates" \
    has "$AGENDA" 'talk to him'
check "repairs and owed engineering belong to the night's builders" \
    has "$AGENDA" "night's builders"
check "a pursuit may book its own continuation" has "$AGENDA" 'crab wake-at'
check "dated progress still has its home" has "$AGENDA" 'wants/<slug>\.md'
check "and a dated thought its own" has "$AGENDA" 'moments/'
check "the silence contract rides along — zero message text" \
    has "$AGENDA" 'ZERO message text'
check "with the filler sentences still forbidden" has "$AGENDA" 'FORBIDDEN'
refute "no shelf item is preselected" has "$AGENDA" 'KLAXON_HORN_RESTORATION'
refute "the old work order is gone: take ONE down" has "$AGENDA" 'Take ONE down'
refute "no agenda is invented for it" has "$AGENDA" "That is this session's agenda"
refute "and it does not model the banned word" has "$AGENDA" '\bhonest(ly|y)?\b'

echo
echo "the day journal's user slot carries the own-time marker:"
JOURNAL="$DAY_JOURNAL_DIR/$(date +%F).md"
check "the marker is in the journal, so a month of these can be read back" \
    grep -rq "own time — a quiet hour" "$DAY_JOURNAL_DIR"

echo
echo "rule 20 stands: a wake WITH an agenda runs whatever the room is doing:"
clean_queue; clear_logs
origin_ago 30
fire scheduled "polish the horn section notes" herself
check_eq "a reasoned scheduled wake ran beside a fresh origin" "$(claude_ran)" "1"
check_eq "on the ordinary wake model, not sol" "$(sol_ran)" "0"
clean_queue; clear_logs
origin_ago 30
fire event "a file landed in the watched directory" notice-newfiles
check_eq "an event wake ran beside the same fresh origin" "$(claude_ran)" "1"

echo
echo "one quiet sitting never ends the chain — the floor books the next hour:"
clean_queue; clear_logs
rm -f "$ORIGIN"
BEFORE=$(date +%s)
fire scheduled ""
check_eq "the choosing session ran" "$(sol_ran)" "1"
check_eq "and left the next opportunity pending" "$(records)" "1"
REC="$(one_record)"
check_eq "booked by the chain floor" "$(field "$REC" 5)" "wake-chain-floor"
DELAY=$(( $(field "$REC" 1) - BEFORE ))
check "at the jittered base, never the flat historic floor (got ${DELAY}s, want ~1207)" \
    bash -c '[ "$1" -ge 1200 ] && [ "$1" -le 1220 ]' _ "$DELAY"
# The second opportunity, still idle: fire the pending unit itself. The chain
# choosing twice in a row is what "recurring" means.
UNIT="$(basename "$REC" .wake)"
clear_logs
"$REPO/crab" wake scheduled "" "$UNIT" wake-chain-floor >/dev/null 2>&1 || true
check_eq "a later idle hour is offered and chosen again" "$(sol_ran)" "1"

echo
echo "IDLE_RETURN=0 stands the discipline down exactly:"
write_conf "IDLE_RETURN=0"
clean_queue; clear_logs
DEFERS_BEFORE="$(led_count idle-defer)"
origin_ago 30
fire scheduled ""
check_eq "the reason-less return runs at once, activity or not" "$(claude_ran)" "1"
check_eq "on the ordinary wake model, not sol" "$(sol_ran)" "0"
OLD="$(cat "$SANDBOX_CLAUDE_LOG")"
check "with the wants agenda of old" \
    bash -c 'grep -qF -- "Take ONE down" <<<"$1"' _ "$OLD"
check_eq "and no idle deferral was minted" \
    "$(led_count idle-defer)" "$DEFERS_BEFORE"
clean_queue
run 'IDLE_RETURN=0 ensure_next_wake' >/dev/null 2>&1
REC="$(one_record)"
check "the floor still books" test -n "$REC"
DELAY=$(( $(field "$REC" 1) - $(field "$REC" 4) ))
check_eq "at the flat historic delay, no jitter (got ${DELAY}s)" "$DELAY" "2700"

echo
echo "summary: $PASS passed, $FAIL failed"
