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
#    8. the release is a RE-READ, never a timer (the review of 2026-11-08
#       reproduced the first shape delivering into a turn that began during
#       the settle): under the controlled clock, a turn that begins, a
#       recording that starts or a message that lands during the settle puts
#       the words back into the wait, and they go out only once it clears
#       again, within the one budget; so does a gate that closes during the
#       judge; a record that grows during the second wait is judged again
#       and a DROP retires the note; quiet hours arriving during the settle
#       or the judge end the wait by name with nothing delivered; a
#       reclosure past the budget or beside an urgent-lane claim ends it on
#       the spot; a release that finds the gates clear delivers whatever the
#       clock or the urgent lane says; then through `crab wake`, a judge
#       during which he speaks again holds the note until the conversation
#       cools once more, and one whose record grows across the second wait is
#       asked again and dropped
#
# On the tree before rule 27g existed, 1 fails (no wait to call) and 2
# through 4 fail (nothing delivered, one comeback booked five minutes out).
# On the first shape of rule 27g (f6b5a2c), 8 fails: the settle alone
# released the words. Everything is stubbed and confined to the sandbox.
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
        date +%s >> "$WORK/judge-at"
        MODE="\$(cat "$WORK/judge-mode" 2>/dev/null || echo say)"
        # A scenario's hand inside the judge: what happens WHILE it runs —
        # after this call's answer is fixed, so a hook can set the NEXT one.
        [ -f "$WORK/judge-hook" ] && . "$WORK/judge-hook"
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
    unset WAKE_HOT_DEADLINE WAKE_HOT_CUT WAKE_HOT_JUDGED
    rm -f "${LAST_ORIGIN_FILE:?}" "${WAKE_URGENT_CLAIM:?}"
    : > "$SPEECH_LOG"
    START=$FAKE_NOW
    yn() { "$@" && echo yes || echo no; }
    again() { local c; c="$(grep -c "closed again" "$SPEECH_LOG" 2>/dev/null)"; printf "%s\n" "${c:-0}"; }
    report() { printf "rc=%s elapsed=%s ticks=%s inflight=%s busy=%s hot=%s urgent=%s again=%s dry=[%s]\n" \
                   "$1" $(( FAKE_NOW - START )) "$TICKS" \
                   "$(yn interactive_turn_in_flight)" "$(yn user_busy)" "$(yn convo_hot)" "$(yn wake_urgent_waiting)" \
                   "$(again)" "$WAKE_HOT_DRY"; }
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
# 1b. The release is a RE-READ, never a timer. The review of the first shape
# of this wait (2026-11-08) reproduced the gap on the function itself: the
# gates clear at one instant, a turn in flight two seconds later, the words
# delivered into it — because the settle poll returned 0 on its own, and the
# judge ran after it with no gate read again. Every scenario below is the
# reviewer's fake clock: nothing real passes, the moment closes on an exact
# tick, and the report line carries the state of every gate AT RETURN.
JCOUNT="$WORK/clock-judged"
HOLD='
    JCOUNT="'"$JCOUNT"'"; rm -f "$JCOUNT" "'"$WORK"'/clock-grew" "'"$WORK"'/clock-night" "'"$WORK"'/clock-turn2"
    BOOKED=0
    wake_hold_for_heat() { BOOKED=$(( BOOKED + 1 )); return 0; }
    wake_turns_since() { printf "[00:00] he said: something, while it waited\n"; }
    judged() { [ -f "$JCOUNT" ] && wc -l < "$JCOUNT" || echo 0; }
    hold_report() { printf "%s" "$SESSION_OUTCOME" > "'"$WORK"'/clock-outcome"
                    printf "rc=%s elapsed=%s ticks=%s judged=%s booked=%s again=%s dry=[%s]\n" \
                        "$1" $(( FAKE_NOW - START )) "$TICKS" "$(judged)" "$BOOKED" \
                        "$(again)" "$WAKE_HOT_DRY"; }
'

echo
echo "the release is a re-read — the reviewer's shape: a turn begins during the settle:"
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -ge 1 ] && [ "$TICKS" -lt 6 ]; }
              wake_hot_moment 1; report $?')"
check_eq "the words still go out" "$(field "$R" rc)" "0"
check_eq "but never into the turn — at return nothing is in flight" "$(field "$R" inflight)" "no"
check_eq "they waited for it: released at 14 s, not off the 2 s settle" "$(field "$R" elapsed)" "14"
check_eq "and the speech log says the moment closed again during the settle" "$(field "$R" again)" "1"

echo
echo "a message that lands during the settle puts a note back into the wait:"
R="$(clocked 'he_spoke_ago 4; on_tick() { [ "$TICKS" -eq 59 ] && he_spoke; :; }
              wake_hot_moment 0; report $?')"
check_eq "delivered in the end" "$(field "$R" rc)" "0"
check_eq "with the conversation cold at return" "$(field "$R" hot)" "no"
check_eq "a full window after he spoke again, plus the settle (240 s)" "$(field "$R" elapsed)" "240"
check_eq "one reclosure announced" "$(field "$R" again)" "1"

echo
echo "a recording that starts during the settle does the same:"
R="$(clocked 'he_spoke_ago 900
              user_busy() { [ "$TICKS" -ge 1 ] && [ "$TICKS" -lt 4 ]; }
              wake_hot_moment 0; report $?')"
check_eq "delivered once the recording ended" "$(field "$R" rc)" "0"
check_eq "not busy at return" "$(field "$R" busy)" "no"
check_eq "at 10 s: the recording's 8 s and the settle" "$(field "$R" elapsed)" "10"

echo
echo "a reclosure under the one budget is still bounded by it — the same deadline, not a new one:"
# A ticket clears at 4 s; he speaks at 6 s, during the settle, and keeps
# speaking: the second wait runs dry at 300 s from the FIRST call.
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 2 ]; }
              on_tick() { [ "$TICKS" -ge 3 ] && he_spoke; :; }
              wake_hot_moment 0; report $?')"
check_eq "the wait runs dry" "$(field "$R" rc)" "1"
check_eq "at 300 s from the first call" "$(field "$R" elapsed)" "300"
check_eq "naming the budget" "$(field "$R" dry)" "the moment outlasted the 300s wait"

echo
echo "a reclosure PAST the budget ends the wait on the spot, by name:"
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 149 ] || [ "$TICKS" -ge 150 ]; }
              wake_hot_moment 1; report $?')"
check_eq "the wait ends" "$(field "$R" rc)" "1"
check_eq "at the budget" "$(field "$R" elapsed)" "300"
check_eq "naming the budget" "$(field "$R" dry)" "the moment outlasted the 300s wait"
check_eq "without pretending to wait on" "$(field "$R" again)" "0"

echo
echo "a reclosure beside an urgent-lane claim yields on the spot, by name:"
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 2 ] || [ "$TICKS" -ge 3 ]; }
              on_tick() { [ "$TICKS" -eq 3 ] && printf "%s\n" $(( FAKE_NOW + 100 )) > "$WAKE_URGENT_CLAIM"; :; }
              wake_hot_moment 1; report $?')"
check_eq "the wait yields" "$(field "$R" rc)" "1"
check_eq "on the settle tick" "$(field "$R" elapsed)" "6"
check_eq "naming the waiter" "$(field "$R" dry)" "another event wake is waiting for the run lock"

echo
echo "but a release that finds the gates CLEAR delivers whatever the clock says — the budget bounds the waiting, never the delivery:"
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 149 ]; }
              wake_hot_moment 1; report $?')"
check_eq "delivered" "$(field "$R" rc)" "0"
check_eq "on a settle that ended exactly at the deadline" "$(field "$R" elapsed)" "300"
check_eq "nothing ended it" "$(field "$R" dry)" ""

echo
echo "...and whatever the urgent lane says:"
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 2 ]; }
              on_tick() { [ "$TICKS" -eq 3 ] && printf "%s\n" $(( FAKE_NOW + 100 )) > "$WAKE_URGENT_CLAIM"; :; }
              wake_hot_moment 1; report $?')"
check_eq "delivered" "$(field "$R" rc)" "0"
check_eq "with the claim standing at return" "$(field "$R" urgent)" "yes"
check_eq "at 6 s" "$(field "$R" elapsed)" "6"

echo
echo "quiet hours arriving during the settle end the wait with nothing delivered:"
R="$(clocked 'he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 2 ]; }
              in_quiet_hours() { [ "$TICKS" -ge 3 ]; }
              wake_hot_moment 1; report $?')"
check_eq "the wait ends" "$(field "$R" rc)" "1"
check_eq "on the settle tick, with every other gate clear" "$(field "$R" elapsed)" "6"
check_eq "naming the night" "$(field "$R" dry)" "quiet hours arrived mid-wait"

echo
echo "the judge takes time too — a message that lands while the note is judged puts it back into the wait:"
# The hold itself (wake_hold_words), the judge stubbed: he speaks again
# DURING the judge, which answers SAY. The note is not delivered into that;
# it waits a full window more and goes out once, and the judge — whose record
# did not grow — is not asked twice.
R="$(clocked "$HOLD"'
              he_spoke_ago 4
              wake_stale_judge() { echo x >> "$JCOUNT"; he_spoke; printf "SAY: still news\n"; }
              wake_hold_words "the conversation was hot, nothing shown" "the note" "the rider" 0; hold_report $?')"
check_eq "the hold says deliver" "$(field "$R" rc)" "0"
check_eq "at 240 s — a full window after he spoke during the judge, plus the settle" "$(field "$R" elapsed)" "240"
check_eq "the judge was asked once; the record did not grow" "$(field "$R" judged)" "1"
check_eq "the reclosure was announced" "$(field "$R" again)" "1"
check_eq "and nothing was booked" "$(field "$R" booked)" "0"

echo
echo "a spoken note held in flight: a new turn that begins during the judge is waited out:"
R="$(clocked "$HOLD"'
              he_spoke_ago 900
              interactive_turn_in_flight() { [ "$TICKS" -lt 2 ] || { [ -f "'"$WORK"'/clock-turn2" ] && [ "$TICKS" -lt 8 ]; }; }
              wake_stale_judge() { echo x >> "$JCOUNT"; touch "'"$WORK"'/clock-turn2"; printf "SAY: still news\n"; }
              wake_hold_words "a turn was in flight, nothing spoken and nothing shown" "the note" "the rider" 1; hold_report $?')"
check_eq "delivered" "$(field "$R" rc)" "0"
check_eq "after the second turn's 10 s and the settle: 18 s" "$(field "$R" elapsed)" "18"
check_eq "the judge was asked once" "$(field "$R" judged)" "1"
check_eq "the reclosure was announced" "$(field "$R" again)" "1"

echo
echo "a record that grows during the second wait is judged again, and a DROP then retires the note:"
R="$(clocked "$HOLD"'
              he_spoke_ago 4
              wake_turns_since() { printf "[00:00] he said: something, while it waited\n"
                                   [ -f "'"$WORK"'/clock-grew" ] && printf "[00:02] he said: did we win that one\n[00:02] she said: we did, a few minutes ago\n"; :; }
              wake_stale_judge() { echo x >> "$JCOUNT"
                                   if [ -f "'"$WORK"'/clock-grew" ]; then printf "DROP: he was told while it waited\n"
                                   else he_spoke; touch "'"$WORK"'/clock-grew"; printf "SAY: still news\n"; fi; }
              wake_hold_words "the conversation was hot, nothing shown" "the note" "the rider" 0; hold_report $?')"
check_eq "the hold ends the wake" "$(field "$R" rc)" "1"
check_eq "the judge was asked twice — once per record" "$(field "$R" judged)" "2"
check_eq "nothing was booked: a dropped note has no comeback" "$(field "$R" booked)" "0"
check "the journal line says dropped after it waited, with the second judge's reason" \
    grep -q "stale — held note dropped unspoken; judged against what was said while it waited: he was told while it waited" "$WORK/clock-outcome"

echo
echo "quiet hours arriving during the judge end the wait by name — the words go to the queue, nothing is delivered:"
R="$(clocked "$HOLD"'
              he_spoke_ago 4
              in_quiet_hours() { [ -f "'"$WORK"'/clock-night" ]; }
              wake_stale_judge() { echo x >> "$JCOUNT"; touch "'"$WORK"'/clock-night"; printf "SAY: still news\n"; }
              wake_hold_words "the conversation was hot, nothing shown" "the note" "the rider" 0; hold_report $?')"
check_eq "the hold ends the wake" "$(field "$R" rc)" "1"
check_eq "naming the night" "$(field "$R" dry)" "quiet hours arrived mid-wait"
check_eq "one comeback booked" "$(field "$R" booked)" "1"
check "the journal line names the heat, the night and the comeback" \
    bash -c 'grep -q "held — the conversation was hot, nothing shown; quiet hours arrived mid-wait; coming back in 5min" "$1"' _ "$WORK/clock-outcome"

echo
echo "a reclosure during the judge past the budget ends the wait on the spot:"
R="$(clocked "$HOLD"'
              WAKE_HOT_WAIT=118; he_spoke_ago 4
              wake_stale_judge() { echo x >> "$JCOUNT"; he_spoke; printf "SAY: still news\n"; }
              wake_hold_words "the conversation was hot, nothing shown" "the note" "the rider" 0; hold_report $?')"
check_eq "the hold ends the wake" "$(field "$R" rc)" "1"
check_eq "at the budget, which the settle had reached with the gates clear" "$(field "$R" elapsed)" "118"
check_eq "naming the budget" "$(field "$R" dry)" "the moment outlasted the 118s wait"
check_eq "without pretending to wait on" "$(field "$R" again)" "0"
check_eq "one comeback booked" "$(field "$R" booked)" "1"

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
        "$WORK/judge-prompt.txt" "$WORK/judge-at" "$CALLS" "$CONVO"
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
    "$WORK/journal-entry.sh" "$@"
}
cat > "$WORK/journal-entry.sh" <<'JEOF'
#!/usr/bin/env bash
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
JEOF
chmod +x "$WORK/journal-entry.sh"

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

echo
echo "through crab wake: he speaks again DURING the judge, and the note waits for the conversation to cool once more:"
# The judge stub, asked once the first wait clears, itself makes him speak
# (a message 119 s old — hot for one more second under the 120 s window) and
# answers SAY. The note must not go out into that: the speech log carries the
# reclosure, the words land once, at least a second after the judge ran, and
# the judge is not asked again because the record did not grow.
write_conf 20
: > "$SPEECH"
printf '%s' say > "$WORK/judge-mode"
printf 'printf "desk\\t%%s\\n" "$(( $(date +%%s) - 119 ))" > "%s/last-origin"\n' "$WORK" > "$WORK/judge-hook"
he_spoke_at 0
REL="$WORK/witness-judge-reclose"; rm -f "$REL" "$REL.leaked"
N_NEXT=$(( N + 1 ))
release_when_waiting 'journal_entry "$WORK/journal-'"$N_NEXT"'" "$(date +%s)" desk \
                          "how is the weather looking" "Clear and cold for the rest of the day."
                      he_spoke_at 600' "$REL"
run_wake "(quiet) $WIN_NOTE"
wait "$RELEASER_PID" 2>/dev/null
check_eq "the judge was asked exactly once" "$(calls_of judge)" "1"
check "the speech log says the moment closed again while the note was judged" \
    grep -q "closed again while the note was judged" "$SPEECH"
delivered_once "judge reclosure" "rook pair did it" "$REL"
JUDGE_AT="$(head -n1 "$WORK/judge-at" 2>/dev/null || echo 0)"
AT="$(stat -c %Y "$CONVO" 2>/dev/null || echo 0)"
check "delivered only after his message had cooled — a second or more after the judge (${AT}-${JUDGE_AT})" \
    [ $(( AT - JUDGE_AT )) -ge 1 ]
check "and the journal records it as shown, never as held" \
    bash -c 'tail -n1 "$1" | grep -q "shown without speech" && ! tail -n1 "$1" | grep -q "coming back"' _ "$JOURNAL"

echo
echo "...and a record that grows across the second wait is judged again, and dropped:"
# The first judge makes him speak AND lands the exchange that covers the
# note in the day journal, then switches the stub to DROP; the second wait
# clears, the record has grown, the judge is asked again and retires it.
: > "$SPEECH"
printf '%s' say > "$WORK/judge-mode"
N_NEXT=$(( N + 1 ))
cat > "$WORK/judge-hook" <<EOF
printf 'desk\t%s\n' "\$(( \$(date +%s) - 119 ))" > "$WORK/last-origin"
"$WORK/journal-entry.sh" "$WORK/journal-$N_NEXT" "\$(date +%s)" desk "did we actually win that one?" "We did — finished it a few minutes ago, the rook pair did it."
printf '%s' drop > "$WORK/judge-mode"
rm -f "$WORK/judge-hook"
EOF
he_spoke_at 0
REL="$WORK/witness-judge-grew"; rm -f "$REL" "$REL.leaked"
release_when_waiting 'journal_entry "$WORK/journal-'"$N_NEXT"'" "$(date +%s)" desk \
                          "how is the weather looking" "Clear and cold for the rest of the day."
                      he_spoke_at 600' "$REL"
run_wake "(quiet) $WIN_NOTE"
wait "$RELEASER_PID" 2>/dev/null
check_eq "the judge was asked twice" "$(calls_of judge)" "2"
check "the second time with the exchange that landed during the first judge" \
    grep -qF "did we actually win" "$WORK/judge-prompt.txt"
check "the speech log says the moment closed again while the note was judged" \
    grep -q "closed again while the note was judged" "$SPEECH"
check "nothing entered the conversation" bash -c '[ ! -s "$1" ]' _ "$CONVO"
check "no bubble, no voice, no window, no notification" \
    bash -c '[ ! -f "$1/spoken.txt" ] && [ ! -f "$1/displayed.txt" ] && [ ! -f "$1/notified.txt" ]' _ "$WORK"
check_eq "and nothing was booked" "$(held_count)" "0"
check "the journal says it was dropped after it waited" \
    bash -c 'tail -n1 "$1" | grep -q "stale — held note dropped unspoken; judged against what was said while it waited"' _ "$JOURNAL"
check "the trace names the in-process wait" grep -q "DROP, after the in-process wait" "$STALELOG"
rm -f "$WORK/judge-hook"

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
