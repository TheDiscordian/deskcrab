#!/usr/bin/env bash
# A held note's retry is seconds, in the process that holds it.
#
# specs/wake-queue.md rule 27g. A quiet thought that landed in a live
# conversation was held (rule 27a) and re-booked itself five minutes out, and
# that one booking was the whole of the retry: by the time the note came back
# the moment it belonged to had gone — in chess several plies can pass (the
# user, 2026-08-20 00:38). The words are already in hand, so the retry is now
# a poll in the holding process — every gate re-read every WAKE_HOT_POLL
# seconds, delivery the moment they clear, nothing booked — and the queue
# re-book is the fallback for a wait that ran dry.
#
#    1. the wait itself, under a CONTROLLED clock (date +%s and sleep are
#       shell functions over a fake epoch; no real second passes):
#       a hot conversation that goes cold is eligible again within one poll
#       of the window's end and never at the five-minute comeback; one that
#       keeps going holds the words to the deadline and not a second past
#       it; a turn in flight and a busy moment hold them too; a spoken reply
#       waits for neither heat; quiet hours and an event wake in the urgent
#       lane end the wait by name; the deadline is ONE budget across calls;
#       the staleness cut reaches back to a turn already in flight; and
#       WAKE_HOT_WAIT=0 is the flat re-book
#    2. through `crab wake`, with the poll sub-second: a quiet note held hot
#       is delivered exactly once, the moment the conversation cools and only
#       after it, nothing booked, the judge never called
#    3. a conversation that keeps going delivers nothing while it goes on,
#       and the note lands once, once it stops
#    4. a SPOKEN wake held in flight lands once when the ticket clears,
#       heat or no heat, never journalled as held
#    5. a wait that runs dry journals why and books the one comeback as
#       rule 27a does
#    6. a note whose substance the exchange covered while it waited is
#       dropped by rule 27b's judge — journalled, ledgered, traced — and a
#       SAY delivers it
#    7. WAKE_HOT_WAIT=0 restores the flat re-book exactly
#
# On the tree before rule 27g existed, 1 fails (no wait to call) and 2
# through 4 fail (nothing delivered, one comeback booked five minutes out).
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
JOURNAL="${DESKCRAB_STATE_PREFIX}-sessions.log"
SPEECH="${DESKCRAB_STATE_PREFIX}-speech.log"
STALELOG="${DESKCRAB_STATE_PREFIX}-stale-check.log"
ORDERDIR="${DESKCRAB_STATE_PREFIX}-turn-order"
LEDGER="$WAKES_DIR/ledger.log"
CALLS="$WORK/claude-calls.txt"
QUIET_NOTE="Lost browser-006 — mated by a promoted pawn while my knights admired themselves."
SPOKEN_NOTE="The disk you asked about filled up ten minutes ago and something has to go."
WIN_NOTE="We won browser-006 — the rook pair did it."

# One claude stub, two hands, told apart by the model on argv (the conf pins
# both names): the staleness judge records the prompt it was handed and
# answers from $WORK/judge-mode; the wake session answers with whatever
# $WORK/wake-reply.txt holds.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
case "\$*" in
    *claude-fable-5*)
        echo judge >> "$CALLS"
        cat > "$WORK/judge-prompt.txt"
        MODE="\$(cat "$WORK/judge-mode" 2>/dev/null || echo say)"
        case "\$MODE" in
            drop) TEXT="DROP: he was told about the win while this waited, in those words" ;;
            *)    TEXT="SAY: nothing since touches this — it is still news" ;;
        esac
        ;;
    *)
        echo wake >> "$CALLS"
        cat > /dev/null
        TEXT="\$(cat "$WORK/wake-reply.txt" 2>/dev/null || echo '(quiet) a stub thought')"
        ;;
esac
python3 - "\$TEXT" <<'PYEOF'
import json, sys
text = sys.argv[1]
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result", "result": text}))
PYEOF
EOF
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

write_conf() {  # <WAKE_HOT_WAIT>
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
CONVO_HOT_WINDOW=120
WAKE_HOT_RETRY=300
WAKE_HOT_WAIT=$1
WAKE_HOT_POLL=0.2
WAKE_FLIGHT_HOLD=1
WAKE_MODEL="stub-wake"
WAKE_STALE_MODEL="claude-fable-5"
WAKE_STALE_TIMEOUT=30
EOF
}

# ---------------------------------------------------------------------------
# 1. The wait under a controlled clock. `date +%s` answers from FAKE_NOW and
# `sleep` never sleeps: it advances FAKE_NOW by its argument, counts the tick,
# and runs one hook — the hook is how a scenario makes him speak again, a
# ticket clear, or the night arrive at an exact moment on the fake clock.
# Every other date call stays real (the speech log's stamps).
CLOCK='
    FAKE_NOW=1700000000; TICKS=0
    date() { case "$1" in +%s) printf "%s\n" "$FAKE_NOW" ;; *) command date "$@" ;; esac; }
    sleep() { FAKE_NOW=$(( FAKE_NOW + ${1%.*} )); TICKS=$(( TICKS + 1 )); on_tick; }
    on_tick() { :; }
    LAST_ORIGIN_FILE="'"$WORK"'/clock-origin"
    TURN_ORDER_DIR="'"$WORK"'/clock-order"
    he_spoke() { printf "desk\t%s\n" "$FAKE_NOW" > "$LAST_ORIGIN_FILE"; }
    he_spoke_ago() { printf "desk\t%s\n" $(( FAKE_NOW - $1 )) > "$LAST_ORIGIN_FILE"; }
    SESSION_START=$FAKE_NOW
    WAKE_QUIET_HOURS=""
    CONVO_HOT_WINDOW=120
    WAKE_HOT_WAIT=300
    WAKE_HOT_POLL=2
    WAKE_FLIGHT_HOLD=1
    unset WAKE_HOT_DEADLINE WAKE_HOT_CUT
    rm -f "${LAST_ORIGIN_FILE:?}" "${WAKE_URGENT_CLAIM:?}"
    START=$FAKE_NOW
    report() { printf "rc=%s elapsed=%s ticks=%s dry=[%s]\n" "$1" $(( FAKE_NOW - START )) "$TICKS" "$WAKE_HOT_DRY"; }
'
clocked() {  # <scenario body>  -> the report line
    sandbox_bash "$CLOCK
                  $1" 2>/dev/null | tail -n1
}
field() {  # <report> <name>  — the dry reason is the bracketed tail, spaces and all
    case "$2" in
        dry) printf '%s\n' "$1" | sed -n 's/.*dry=\[\(.*\)\]$/\1/p' ;;
        *)   printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" ;;
    esac
}

echo "the wait under a controlled clock — a hot conversation that goes cold:"
R="$(clocked 'he_spoke_ago 4; wake_hot_moment 0; report $?')"
check_eq "the wait returns eligible" "$(field "$R" rc)" "0"
E="$(field "$R" elapsed)"
check "and not before the window has passed — the suppression is kept (${E}s)" \
    [ "$E" -ge 116 ]
check "within one poll of the window's end, plus the one-poll settle (${E}s)" \
    [ "$E" -le $(( 116 + 2 * 2 )) ]
check "and never the five-minute comeback" [ "$E" -lt 300 ]
check_eq "nothing ended the wait early" "$(field "$R" dry)" ""

echo
echo "a conversation that keeps going holds the words to the deadline:"
# He speaks again every minute — every thirtieth two-second tick.
R="$(clocked 'he_spoke; on_tick() { [ $(( TICKS % 30 )) -eq 0 ] && he_spoke; :; }
              wake_hot_moment 0; report $?')"
check_eq "the wait runs dry" "$(field "$R" rc)" "1"
check_eq "exactly at the budget, not a second past it" "$(field "$R" elapsed)" "300"
check_eq "and says why" "$(field "$R" dry)" "the moment outlasted the 300s wait"

echo
echo "a turn in flight and a busy moment hold the words too, cold or not:"
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 5 ]; }
              wake_hot_moment 1; report $?')"
check_eq "a spoken reply waits for the ticket" "$(field "$R" rc)" "0"
check_eq "and goes out the poll after it clears, plus the settle" \
    "$(field "$R" elapsed)" "12"
R="$(clocked 'he_spoke_ago 900
              user_busy() { [ "$TICKS" -lt 3 ]; }
              wake_hot_moment 0; report $?')"
check_eq "a quiet note waits for the recording to end" "$(field "$R" rc)" "0"
check_eq "and goes out the poll after, plus the settle" "$(field "$R" elapsed)" "8"

echo
echo "a spoken reply does not wait for heat — rule 27a's boundary:"
R="$(clocked 'he_spoke; wake_hot_moment 1; report $?')"
check_eq "eligible at once" "$(field "$R" rc)" "0"
check_eq "only the settle poll passed" "$(field "$R" ticks)" "1"

echo
echo "quiet hours arriving mid-wait end it, by name:"
R="$(clocked 'he_spoke; in_quiet_hours() { [ "$TICKS" -ge 4 ]; }
              wake_hot_moment 0; report $?')"
check_eq "the wait ends" "$(field "$R" rc)" "1"
check_eq "at the fourth tick" "$(field "$R" elapsed)" "8"
check_eq "naming the night" "$(field "$R" dry)" "quiet hours arrived mid-wait"

echo
echo "an event wake standing in the urgent lane ends the wait — the lock is promised to it:"
R="$(clocked 'he_spoke
              on_tick() { [ "$TICKS" -eq 3 ] && printf "%s\n" $(( FAKE_NOW + 100 )) > "$WAKE_URGENT_CLAIM"; :; }
              wake_hot_moment 0; report $?')"
check_eq "the wait yields" "$(field "$R" rc)" "1"
check_eq "on the tick the claim appeared" "$(field "$R" elapsed)" "6"
check_eq "naming the waiter" "$(field "$R" dry)" "another event wake is waiting for the run lock"
R="$(clocked 'he_spoke_ago 900
              printf "%s\n" $(( FAKE_NOW - 10 )) > "$WAKE_URGENT_CLAIM"
              interactive_turn_in_flight() { [ "$TICKS" -lt 2 ]; }
              wake_hot_moment 0; report $?')"
check_eq "an expired claim is ignored, never obeyed" "$(field "$R" rc)" "0"

echo
echo "the deadline is one budget across every call in the process:"
# A ticket holds a spoken reply for 100 s; the words then meet a conversation
# that never cools. The second wait runs dry at 300 s from the FIRST call.
R="$(clocked 'interactive_turn_in_flight() { [ "$TICKS" -lt 50 ]; }
              wake_hot_moment 1 || { report 9; exit; }
              he_spoke; on_tick() { he_spoke; }
              wake_hot_moment 0; report $?')"
check_eq "the second wait runs dry" "$(field "$R" rc)" "1"
check_eq "at 300 s from the first call, not 300 s from the second" \
    "$(field "$R" elapsed)" "300"

echo
echo "the staleness cut reaches back to a turn already in flight:"
R="$(clocked 'mkdir -p "$TURN_ORDER_DIR"
              printf "%s\t%s\t%s\tdesk\n" "$$" "$(_proc_starttime $$)" $(( FAKE_NOW - 50 )) \
                  > "$TURN_ORDER_DIR/000000001.ticket"
              interactive_turn_in_flight() { [ "$TICKS" -lt 2 ]; }
              wake_hot_moment 1 >/dev/null
              printf "cut=%s start=%s\n" "$WAKE_HOT_CUT" "$START"')"
check_eq "the cut is the ticket's own start, fifty seconds before this session" \
    "$(field "$R" cut)" "$(( $(field "$R" start) - 50 ))"
R="$(clocked 'rm -rf "${TURN_ORDER_DIR:?}"; he_spoke_ago 4; wake_hot_moment 0 >/dev/null
              printf "cut=%s start=%s\n" "$WAKE_HOT_CUT" "$START"')"
check_eq "and with no turn in flight it is this session's start" \
    "$(field "$R" cut)" "$(field "$R" start)"

echo
echo "WAKE_HOT_WAIT=0 is the flat re-book, with no wait at all:"
R="$(clocked 'he_spoke; WAKE_HOT_WAIT=0; wake_hot_moment 0; report $?')"
check_eq "the wait declines" "$(field "$R" rc)" "1"
check_eq "without a single poll" "$(field "$R" ticks)" "0"
check_eq "and says the wait is off" "$(field "$R" dry)" "the in-process wait is off"

# ---------------------------------------------------------------------------
# 2–7. Through `crab wake` for real, the poll sub-second so a scenario takes
# a second or two of wall clock. The moment is controlled by hand: his last
# message is an epoch the test writes, a turn in flight is a ticket the test
# plants, and the release happens only once the wake is PROVABLY inside the
# wait — the wait announces itself on the speech log the moment it begins.
he_spoke_at() {  # <seconds ago>
    printf 'desk\t%s\n' "$(( $(date +%s) - $1 ))" > "$WORK/last-origin"
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

N=0
run_wake() {  # <reply text>  — one wake, its own day-journal fixture
    N=$(( N + 1 ))
    printf '%s' "$1" > "$WORK/wake-reply.txt"
    rm -f "$WORK/spoken.txt" "$WORK/displayed.txt" "$WORK/notified.txt" \
        "$WORK/judge-prompt.txt" "$CALLS" "$CONVO"
    rm -f "${WAKES_DIR:?}"/*.wake 2>/dev/null
    DAY_JOURNAL_DIR="$WORK/journal-$N" \
        "$REPO/crab" wake event "chessweb: a move landed in game browser-006" "" chessweb \
        >/dev/null 2>&1 </dev/null || true
}
held_records() {
    grep -lF "while he was mid-conversation" "$WAKES_DIR"/*.wake 2>/dev/null || true
}
held_count() { held_records | wc -l; }
held_field() {  # <field number>
    local f; f="$(held_records | head -n1)"
    [ -n "$f" ] && cut -f"$1" "$f" || true
}
calls_of() { sandbox_count_in "^$1\$" "$CALLS"; }
journal_entry() {  # <dir> <epoch> <kind> <user> <reply>
    mkdir -p "$1"
    python3 - "$@" <<'PYEOF'
import json, os, sys, time
d, epoch, kind, user, reply = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
obj = {"epoch": epoch,
       "time": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(epoch)),
       "kind": kind, "duration": 5, "user": user, "reply": reply, "pid": 1}
path = os.path.join(d, time.strftime("%Y-%m-%d", time.localtime(epoch)) + ".jsonl")
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(obj, ensure_ascii=False) + "\n")
PYEOF
}

# Run <command> only once the wake is provably inside the rule-27g wait, a
# beat later, recording the moment and whether the conversation was still
# empty just before — the witness that nothing went out while the wait held.
# The bounded fallback keeps a tree with no wait from wedging the test; the
# caller waits for this subshell so a late release never bleeds onward.
RELEASER_PID=""
release_when_waiting() {  # <command> <witness file>
    local BEFORE
    BEFORE="$(sandbox_count_in 'held note: delivery is waiting' "$SPEECH")"
    (
        n=0
        while [ "$(sandbox_count_in 'held note: delivery is waiting' "$SPEECH")" -le "$BEFORE" ]; do
            sleep 0.1
            n=$(( n + 1 )); [ "$n" -gt 100 ] && break
        done
        sleep 0.5
        [ -s "$CONVO" ] && touch "$2.leaked"
        eval "$1"
        date +%s > "$2"
    ) &
    RELEASER_PID=$!
}
delivered_once() {  # <label> <words> <released-at file>
    check_eq "$1: the conversation holds the words exactly once" \
        "$(sandbox_count_in "$2" "$CONVO")" "1"
    check "$1: under the wake marker" grep -qF "[Autonomous wake" "$CONVO"
    check_eq "$1: and NOTHING was booked — a delivery books no comeback" "$(held_count)" "0"
    check "$1: nothing went out while the wait held" [ ! -e "$3.leaked" ]
    if [ -s "$3" ]; then
        local AT REL
        REL="$(cat "$3")"; AT="$(stat -c %Y "$CONVO" 2>/dev/null || echo 0)"
        check "$1: delivered only after the release" [ "$AT" -ge "$REL" ]
        check "$1: and within seconds of it, not minutes (${AT}-${REL})" \
            [ $(( AT - REL )) -le 5 ]
    fi
    check "$1: the wait announced itself and its clearing" \
        bash -c 'grep -q "held note: delivery is waiting" "$1" && grep -q "the moment passed — delivering now" "$1"' _ "$SPEECH"
}

echo
echo "a quiet note held hot is delivered once, the moment the conversation cools:"
write_conf 20
: > "$SPEECH"
he_spoke_at 0
REL="$WORK/witness-cooled"; rm -f "$REL" "$REL.leaked"
release_when_waiting 'he_spoke_at 600' "$REL"
run_wake "(quiet) $QUIET_NOTE"
wait "$RELEASER_PID" 2>/dev/null
delivered_once "cooled" "browser-006" "$REL"
check "it was a bubble, not a voice" [ ! -f "$WORK/spoken.txt" ]
check "the journal records it as shown, never as held" \
    bash -c 'tail -n1 "$1" | grep -q "shown without speech" && ! grep -q "coming back" "$1"' _ "$JOURNAL"
check_eq "nothing was said while it waited, so the judge was never called" "$(calls_of judge)" "0"
check "and the trace says so" grep -q "nothing said while the note waited" "$STALELOG"

echo
echo "a conversation that keeps going delivers nothing while it goes on:"
# He keeps talking for two seconds once the wait has begun — a message every
# fifth of a second — and the witness is taken at each one; then he stops.
: > "$SPEECH"
he_spoke_at 0
REL="$WORK/witness-kept-going"; rm -f "$REL" "$REL.leaked" "$REL.talked-over"
release_when_waiting 'for _ in $(seq 10); do
                          he_spoke_at 0
                          [ -s "$CONVO" ] && touch "$REL.talked-over"
                          sleep 0.2
                      done
                      he_spoke_at 600' "$REL"
run_wake "(quiet) $QUIET_NOTE"
wait "$RELEASER_PID" 2>/dev/null
check "nothing went out while he was still talking" [ ! -e "$REL.talked-over" ]
delivered_once "kept going" "browser-006" "$REL"

echo
echo "a SPOKEN wake held in flight lands once when the ticket clears, heat or no heat:"
: > "$SPEECH"
he_spoke_at 0
plant_ticket
REL="$WORK/witness-flight"; rm -f "$REL" "$REL.leaked"
release_when_waiting 'kill "$TICKET_KEEPER" 2>/dev/null' "$REL"
run_wake "$SPOKEN_NOTE"
wait "$RELEASER_PID" 2>/dev/null
delivered_once "flight" "filled up ten minutes ago" "$REL"
check "it was synthesised" grep -qF "filled up ten minutes ago" "$WORK/spoken.txt"
check_eq "once" "$(sandbox_count_in 'filled up ten minutes ago' "$WORK/spoken.txt")" "1"
check "and the journal never called it held" \
    bash -c '! grep -q "a turn was in flight" "$1" && ! grep -q "coming back" "$1"' _ "$JOURNAL"
rm -rf "${ORDERDIR:?}"

echo
echo "a wait that runs dry journals why and books the one comeback:"
write_conf 1
: > "$SPEECH"
he_spoke_at 0
run_wake "(quiet) $QUIET_NOTE"
check "nothing entered the conversation" bash -c '[ ! -s "$1" ]' _ "$CONVO"
check "the wait ran and ran dry" \
    bash -c 'grep -q "held note: delivery is waiting" "$1" && grep -q "handing the words back to the queue" "$1"' _ "$SPEECH"
check "the journal names the heat and the dry wait, then promises the comeback" \
    bash -c 'tail -n1 "$1" | grep -q "the conversation was hot" && tail -n1 "$1" | grep -q "the moment outlasted the 1s wait" && tail -n1 "$1" | grep -q "coming back in 5min"' _ "$JOURNAL"
check_eq "exactly one comeback stands" "$(held_count)" "1"
check_eq "under the hot-hold identity" "$(held_field 5)" "hot-hold"
BOOKED="$(held_field 3)"
contains "$BOOKED" "browser-006" && contains "$BOOKED" "held at" \
    && ok "carrying the words and the stamp, as rule 27a books it" \
    || fail "the comeback lost the words or the stamp" "[$BOOKED]"

echo
echo "a note the exchange covered while it waited is dropped by rule 27b's judge:"
write_conf 20
: > "$SPEECH"
printf '%s' drop > "$WORK/judge-mode"
he_spoke_at 0
REL="$WORK/witness-stale"; rm -f "$REL" "$REL.leaked"
N_NEXT=$(( N + 1 ))
release_when_waiting 'journal_entry "$WORK/journal-'"$N_NEXT"'" "$(date +%s)" desk \
                          "did we actually win that one?" \
                          "We did — finished it a few minutes ago, the rook pair did it."
                      he_spoke_at 600' "$REL"
run_wake "(quiet) $WIN_NOTE"
wait "$RELEASER_PID" 2>/dev/null
check_eq "the judge was asked exactly once" "$(calls_of judge)" "1"
check "with the note's own words" grep -qF "rook pair did it" "$WORK/judge-prompt.txt"
check "and his side of the exchange that landed meanwhile" \
    grep -qF "did we actually win" "$WORK/judge-prompt.txt"
check "nothing entered the conversation" bash -c '[ ! -s "$1" ]' _ "$CONVO"
check "no bubble, no voice, no window, no notification" \
    bash -c '[ ! -f "$1/spoken.txt" ] && [ ! -f "$1/displayed.txt" ] && [ ! -f "$1/notified.txt" ]' _ "$WORK"
check_eq "and nothing was booked either" "$(held_count)" "0"
check "the journal says it was dropped after it waited, with the judge's reason" \
    bash -c 'tail -n1 "$1" | grep -q "stale — held note dropped unspoken; judged against what was said while it waited: he was told"' _ "$JOURNAL"
check "the wake ledger carries the drop under its own action" \
    bash -c 'grep "dropped-stale" "$1" | grep -q "stale-judge"' _ "$LEDGER"
check "and the trace names the in-process wait" grep -q "DROP, after the in-process wait" "$STALELOG"

echo
echo "...and a SAY delivers it:"
: > "$SPEECH"
printf '%s' say > "$WORK/judge-mode"
he_spoke_at 0
REL="$WORK/witness-say"; rm -f "$REL" "$REL.leaked"
N_NEXT=$(( N + 1 ))
release_when_waiting 'journal_entry "$WORK/journal-'"$N_NEXT"'" "$(date +%s)" desk \
                          "how is the weather looking" "Clear and cold for the rest of the day."
                      he_spoke_at 600' "$REL"
run_wake "(quiet) $WIN_NOTE"
wait "$RELEASER_PID" 2>/dev/null
check_eq "the judge was asked" "$(calls_of judge)" "1"
delivered_once "say" "rook pair did it" "$REL"

echo
echo "WAKE_HOT_WAIT=0 restores the flat re-book exactly:"
write_conf 0
: > "$SPEECH"
he_spoke_at 0
run_wake "(quiet) $QUIET_NOTE"
check "no wait was entered" bash -c '! grep -q "held note: delivery is waiting" "$1"' _ "$SPEECH"
check "nothing entered the conversation" bash -c '[ ! -s "$1" ]' _ "$CONVO"
check_eq "one comeback stands" "$(held_count)" "1"
FIRE="$(held_field 1)"
check "booked the flat five minutes out" [ "$(( FIRE - $(date +%s) ))" -gt 120 ]
check "and the journal says the wait is off before it promises the comeback" \
    bash -c 'tail -n1 "$1" | grep -q "the in-process wait is off" && tail -n1 "$1" | grep -q "coming back in 5min"' _ "$JOURNAL"

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
