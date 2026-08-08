#!/bin/bash
# The since-last-reply delta — specs/self-awareness.md rules 12 to 15.
# Run: bash tests/test_state_delta.sh
#
# The block used to answer "what happened while you were away" with a fixed
# thirty-minute window, which during a fast exchange is filled entirely by desk
# turns: the wake that fired between them is pushed out of the list, and the
# afternoon reads as though nothing but conversation happened. So the delta is
# anchored to a MOMENT — the previous session's finish — and reports counts
# rather than a list, because a count cannot be pushed out by a busier one.
#
# The anchor is measured to when a session ENDED, not when it began. A plain
# cut on the start field drops a forty-minute wake that finished five minutes
# ago — the longest work of the half hour and the entry most worth having.
#
# And "her last reply" means a session that REACHED HIM. Anchored to the last
# session of any kind, the line could not report a wake at all: a wake is a
# session, so the wake set the anchor and was then measured against its own
# finishing time and counted as nothing. The one line written to say what
# happened while he was away was structurally incapable of saying it.
#
# And queue changes come from the durable ledger, which is the whole reason the
# ledger exists: a bulk restore means a cancellation was undone or the machine
# rebooted, and that used to go to /dev/null.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
W="$WAKES_DIR"
mkdir -p "$W"

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WANTS_FILE="$T/wants.md"
MEMORY_STORE=0
CONF
: > "$T/wants.md"

LOG="$DESKCRAB_STATE_PREFIX-sessions.log"
anchor() { sandbox_bash '_state_delta_anchor' 2>/dev/null; }
delta()  { sandbox_bash '_state_delta_line "$(_state_delta_anchor)"' 2>/dev/null; }
recent() { sandbox_bash 'session_history --recent' 2>/dev/null; }
has()    { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
# A session log line: start stamp, clock, duration, kind, text.
logline() { # <minutes ago> <duration secs> <kind> <text>
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -d "-$1 minutes" '+%Y-%m-%d %H:%M:%S')" \
        "$(date -d "-$1 minutes" '+%H:%M:%S')" "$2" "$3" "$4"
}
NOW="$(date +%s)"

echo "the anchor is the last reply's FINISH, not its start:"
# A forty-minute phone turn that began three quarters of an hour ago and ended
# five minutes ago, and a short desk turn that began and ended in between. The
# latest FINISH belongs to the phone turn; the latest START belongs to the desk
# turn. Both reached him, so the anchor is the later of the two finishes.
{
    logline 45 2400 "phone turn"    "forty minutes of work that ended five minutes ago"
    logline 20   60  "desktop turn" "a short exchange in the middle of it"
} > "$LOG"
LONG_START="$(date -d '-45 minutes' +%s)"
A="$(anchor)"
check_eq "the anchor is that turn's finish, to the second" "$A" "$(( LONG_START + 2400 ))"
check "and not its start — the entry would be forty minutes stale" \
    [ "$A" -gt "$(( LONG_START + 60 ))" ]
check "and not the finish of the turn that started later" \
    [ "$A" -gt "$(date -d '-19 minutes' +%s)" ]
out="$(delta)"
case "$out" in
    "Since your last reply ("*" min ago)"*) ok "the heading says the span it covers, and says it is past" ;;
    *) fail "the delta is headed as time since the last reply" "$out" ;;
esac
check "it is not headed as though it were live work" \
    bash -c '! printf "%s" "'"$out"'" | grep -qi "right now"'

echo
echo "...and that forty-minute session is IN the recently-finished list:"
# The cut is on the finish, so a session that started outside the window and
# ended inside it is kept. Cut on the start and it vanishes — and it is the
# longest work of the half hour.
out="$(recent)"
check "the session that ended five minutes ago is listed" \
    has "forty minutes of work that ended five minutes ago" "$out"
check "the turn that ended inside the window is listed too" \
    has "a short exchange in the middle of it" "$out"

echo
echo "a fast exchange does not push the older work out of the counts:"
# Six turns in the last quarter of an hour is a fast exchange, and the shown
# list is capped — which is exactly how a wake came to be invisible. The delta
# is counts, not a list, so nothing in it can be crowded out.
{
    logline 45 2400 "autonomous wake" "forty minutes of work that ended five minutes ago"
    for m in 14 12 10 8 6 4; do logline "$m" 20 "desktop turn" "turn at minus $m"; done
} > "$LOG"
shown="$(recent | grep -c '^  - ' || true)"
check "the shown list is capped, so it cannot carry everything" [ "$shown" -lt 7 ]
A2="$(anchor)"
check_eq "the anchor still lands on the newest finish, whatever the list shows" \
    "$A2" "$(( $(date -d '-4 minutes' +%s) + 20 ))"

echo
echo "a bulk restore is a queue change, and the block reads it:"
# specs/self-awareness.md rule 14, specs/wake-queue.md rule 31. Five bookings
# whose timers died with a user manager, healed in one pass. Driven through the
# real wake_restore so the ledger lines are the shipped ones.
: > "$W/ledger.log"
for i in 1 2 3 4 5; do
    printf '%s\tscheduled\tpromise number %d\t%s\tpromise-audit\n' \
        $(( NOW + i * 1800 )) "$i" "$NOW" > "$W/deskcrab-wake-b$i.wake"
done
sandbox_bash 'wake_restore' >/dev/null 2>&1
check_eq "the restore wrote five ledger lines" \
    "$(awk -F'\t' '$2 == "restored" { n++ } END { print n + 0 }' "$W/ledger.log")" "5"
out="$(delta)"
check "and the delta says the queue changed, with the number" \
    has "queue changes: 5 restored" "$out"

echo
echo "bookings since the anchor are counted, and by whom:"
: > "$W/ledger.log"
sandbox_bash '
    wake_ledger booked deskcrab-wake-n1 scheduled "" promise-audit
    wake_ledger booked deskcrab-wake-n2 event     "a job ended" job-runner
    wake_ledger booked deskcrab-wake-n3 scheduled "" promise-audit' >/dev/null 2>&1
out="$(delta)"
check "three bookings, counted" has "3 wakes (" "$out"
check "the promise auditor's two are attributed to it" has "promise-audit 2" "$out"
check "and the job runner's one to it" has "job-runner 1" "$out"

echo
echo "a wake that fired between two turns is REPORTED, not swallowed:"
# The shape the line existed for and could not report. A wake is a session, so
# an anchor taken from the last session of any kind was the wake's OWN finish —
# and the wake, measured against the moment it stopped, counted as nothing.
# Every wake that worked while he was away was reported as an empty span.
{
    logline 20 60  "desktop turn"    "the last thing she actually said to him"
    logline 15 600 "autonomous wake" "(silent — wrote a dated note into a want)"
} > "$LOG"
A3="$(anchor)"
check_eq "the anchor stays on the turn that reached him" \
    "$A3" "$(( $(date -d '-20 minutes' +%s) + 60 ))"
check "and not on the wake, which said nothing to anybody" \
    [ "$A3" -lt "$(date -d '-6 minutes' +%s)" ]
out="$(delta)"
check "so the wake that fired since then is counted" has "1 wake fired" "$out"

echo
echo "a wake that DID reach him is a reply; a silent one is not:"
# Which wakes count as replies is readable from the log itself: a session that
# delivered nothing writes its outcome as a parenthesised note, where a session
# that spoke writes the words it said.
{
    logline 60 60  "desktop turn"    "an exchange an hour ago"
    logline 30 120 "autonomous wake" "The kettle in the east wing has finally been descaled."
    logline 10 120 "autonomous wake" "(silent — ran no tools, touched nothing)"
} > "$LOG"
check_eq "the spoken wake is the last reply, so the anchor is its finish" \
    "$(anchor)" "$(( $(date -d '-30 minutes' +%s) + 120 ))"

echo
echo "a wake that fired since the anchor is counted as one:"
# The reachable shape of rule 13's "wakes fired": a wake reaped without its own
# outcome line is journalled with an unknown duration, so its finish IS its
# start. Where a wake ran to completion the anchor lands on that wake's own
# finish, and it is the anchor rather than an event inside the span — see the
# note in the report accompanying this file.
{
    logline 20 60 "desktop turn" "an ordinary turn"
    logline 10 '?' "autonomous wake" "(killed — no summary)"
} > "$LOG"
out="$(delta)"
check "the wake shows up in the delta as one wake fired" has "1 wake fired" "$out"

echo
echo "with no finished session ever, the delta falls back to the fixed window:"
# A fresh machine, or a log that has just been rotated away. The anchor cannot
# be "the previous session's finish" when there has never been one, so it is
# the same half hour the recently-finished list uses — stated, not assumed.
# Compared as a number, not as a string: the assertion is "half an hour back",
# and a second of drift between two `date` calls is not a failure.
near_half_hour() { # <epoch>
    local d=$(( $1 - ( $(date +%s) - 1800 ) ))
    [ "${d#-}" -le 3 ]
}
rm -f "$LOG"
check "the anchor is half an hour ago, within a second or two" near_half_hour "$(anchor)"
: > "$LOG"
check "an empty log falls back the same way as a missing one" near_half_hour "$(anchor)"
# A night of wakes nobody heard is the same case: sessions ran, but not one of
# them was a reply, so there is no last reply to anchor to.
{
    logline 300 900 "autonomous wake" "(silent — read for an hour)"
    logline 180 600 "autonomous wake" "(silent — ran no tools, touched nothing)"
} > "$LOG"
check "a log with nothing but silent wakes in it falls back too" near_half_hour "$(anchor)"

echo
echo "nothing happening is stated as a measurement, not left blank:"
: > "$W/ledger.log"
rm -f "$W"/*.wake
out="$(delta)"
check "an empty span says so in words" \
    has "nothing fired, nothing was booked, no job was dispatched, and the queue did not change" "$out"
