#!/bin/bash
# The promise made about tomorrow — specs/nightly.md rules 53k-53m.
# Run: bash tests/test_promise_tomorrow.sh
#
# "I'll re-seat the heater tomorrow" is neither a miss on the evening it is
# said (the day it is judged against has not happened) nor nothing (the turn
# that said it lies outside every later sweep's journal). The sweep's judge
# answers it LATER; the sweep retains it on the ledger with the due day counted
# from the day it was SAID, never from the clock — the sweep runs after
# midnight — and the due day's sweep asks after it against that day's record,
# the named path statted from disk beside it. Kept lands an outcome row and
# books nothing; missed lands as a numbered sweep row of that night, rides the
# same morning wake and answers to the same resolve door. Every case here runs
# against a stub judge and a scratch ledger: no model is spent, no timer armed,
# and the live promise history is never touched.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib" "$T/notes"

# The checker, copied (not linked — it resolves SCRIPT_DIR through its own
# path and would walk back to the real repo and its real crab), beside a door
# onto the real wake module. Same fixture as test_promise_check.sh.
cp "$REPO/lib/promise-check" "$T/repo/lib/promise-check"
chmod +x "$T/repo/lib/promise-check"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/wake-queue.sh" "$T/repo/lib/wake-queue.sh"
ln -sf "$REPO/lib/extract-response" "$T/repo/lib/extract-response"

cat > "$T/repo/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
[ "\${1:-}" = "wake-at" ] || exit 0
shift
source "$REPO/lib/common.sh" >/dev/null 2>&1
wake_book "\$@"
CRAB
chmod +x "$T/repo/crab"

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
MEMORY_STORE=0
PROMISE_CHECK=1
WAKE_EFFORT="medium"
CONF

export WAKES_DIR="$W"
export PROMISE_LEDGER="$T/ledger.jsonl"
# The sweep's judge is pinned Claude-shaped so the stub claude serves it; the
# EFFECTIVE default (the night judge, rules 14c-14e) is
# tests/test_sleep_sol_judgment.sh's subject.
export PROMISE_SWEEP_MODEL=stub-claude
mkdir -p "$DAY_JOURNAL_DIR"

CHECK_LOG="$DESKCRAB_STATE_PREFIX-promise-check.log"
CHECK_PREFIX="You claimed this and the record shows nothing did it:"

# The fixture's days sit far from the wall clock on purpose: "tomorrow"
# counted from the clock and "tomorrow" counted from the origin day must come
# apart, or the test cannot tell which one the sweep used. A Saturday.
D="2026-03-14"; D1="2026-03-15"; D2="2026-03-16"
CLOCK_TOMORROW="$(date -d tomorrow +%F)"

records()  { ls "$W"/*.wake 2>/dev/null | wc -l; }
field()    { awk -F'\t' -v n="$1" 'FNR == 1 { print $n }' "$W"/*.wake 2>/dev/null; }
calls()    { cat "$T/wake-calls" 2>/dev/null; }
claude_n() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
rows_of()  { sandbox_count_in "\"type\": \"$1\"" "$T/ledger.jsonl"; }
# The ledger is NOT reset between nights — carrying a row across nights is
# the whole subject. Each scenario that wants a clean ledger says so.
reset_night() { rm -f "$W"/*.wake "$W/ledger.log" "$T/wake-calls" "$T/model-stdin" \
                      "$CHECK_LOG" "$SANDBOX_CLAUDE_LOG"; }
# The stub judge answers with the lines in $T/verdict.txt, one assistant
# message each — the shape the real stream carries.
judge_says() { cat > "$T/verdict.txt"; }
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
while IFS= read -r line; do
    python3 -c 'import json, sys; print(json.dumps({"type": "assistant", "message": {"model": "stub", "content": [{"type": "text", "text": sys.argv[1]}]}}))' "\$line"
done < "$T/verdict.txt"
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
sweep() { "$T/repo/lib/promise-check" sweep "$1" 2>/dev/null; }
due_id() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from promise_ledger import due_identity; print(due_identity(sys.argv[2], sys.argv[3]))' "$REPO/lib" "$1" "$2"; }
epoch_of() { date -d "$1" +%s; }

HEATER="I'll re-seat the greenhouse heater tomorrow morning and write it up in $T/notes/heater.md"

echo "the origin night: a commitment made for tomorrow is retained, not flagged (rule 53k):"
reset_night
rm -f "$T/ledger.jsonl"
cat > "$DAY_JOURNAL_DIR/$D.jsonl" <<EOF
{"epoch": $(epoch_of "$D 14:02:00"), "time": "${D}T14:02:00-0400", "kind": "desktop", "user": "the heater?", "reply": "$HEATER.", "pid": 100, "outcome": "asked: the heater? | did: ran no tools, touched nothing | replied: I'll re-seat it tomorrow morning."}
{"epoch": $(epoch_of "$D 15:00:00"), "time": "${D}T15:00:00-0400", "kind": "desktop", "user": "how warm is it?", "reply": "The greenhouse sits at nineteen degrees and the fan is off.", "pid": 101, "outcome": "asked: how warm is it? | did: ran no tools | replied: nineteen degrees."}
EOF
judge_says <<EOF
LATER: "$HEATER" @ 14:02 | tomorrow morning | she set it for the next day, not this one
CLEAN
EOF
OUT="$(sweep "$D")"
check_eq "one model call swept the day" "$(claude_n)" "1"
check "the judge is told a later-day commitment is a LATER verdict, never a miss" \
    grep -q "LATER DAY" "$T/model-stdin"
check "and is handed the fallen-due section, which tonight holds nothing" \
    grep -q "(no retained commitment has fallen due)" "$T/model-stdin"
check_eq "no sweep row landed — tomorrow's work is not missed tonight" "$(rows_of sweep)" "0"
check_eq "one due row was retained" "$(rows_of due)" "1"
check "naming the promise" grep -qF "re-seat the greenhouse heater" "$T/ledger.jsonl"
check "its origin day" grep -qF "\"day\": \"$D\"" "$T/ledger.jsonl"
check "the time it was said" grep -qF "\"said_at\": \"14:02\"" "$T/ledger.jsonl"
check "the moment as she stated it" grep -qF "\"when\": \"tomorrow morning\"" "$T/ledger.jsonl"
check "and the due day counted from the ORIGIN day" grep -qF "\"due\": \"$D1\"" "$T/ledger.jsonl"
check_eq "never from the clock, which already reads another day" \
    "$(sandbox_count_in "\"due\": \"$CLOCK_TOMORROW\"" "$T/ledger.jsonl")" "0"
check "carrying a durable due_id" grep -qF "\"due_id\": \"$D:" "$T/ledger.jsonl"
check_eq "no morning wake was booked" "$(records)" "0"
check_eq "and the queue's door was never knocked" "$(calls)" ""
check "the trace says what was retained and for when" \
    grep -q "LATER retained for $D1" "$CHECK_LOG"
case "$OUT" in
    *"clean — every commitment reconciled; 1 commitment(s) for a later day retained"*)
        ok "and the night log's closing line counts it (rule 53a)" ;;
    *) fail "the closing line must say a commitment was retained" "$OUT" ;;
esac

echo
echo "the same day swept again retains nothing twice, and a MISS in a LATER's words is dropped:"
reset_night
judge_says <<EOF
MISS: "$HEATER" @ 14:02 | nothing re-seated the heater that day
LATER: "$HEATER" @ 14:02 | tomorrow morning | she set it for the next day
EOF
sweep "$D" >/dev/null
check_eq "still exactly one due row" "$(rows_of due)" "1"
check_eq "and still no sweep row — the MISS in the same words was dropped" "$(rows_of sweep)" "0"
check "the trace names the drop" grep -q "dropped a MISS the judge also answered as LATER" "$CHECK_LOG"
check "and the second retention refused" grep -q "already retained under $D:" "$CHECK_LOG"
check_eq "no wake" "$(records)" "0"

echo
echo "the resolver counts from the origin day (rule 53k):"
python3 - "$REPO/lib" "$D" <<'PY' > "$T/resolver.out"
import sys
sys.path.insert(0, sys.argv[1])
from promise_ledger import resolve_due_day, due_identity
D = sys.argv[2]
for when in ["tomorrow", "tomorrow night", "first thing tomorrow", "in 3 days", "Friday",
             "next week", "2026-12-01", "when I get a chance", "tonight", "this afternoon",
             "the day after tomorrow"]:
    due, how = resolve_due_day(D, when)
    print("%s=%s/%s" % (when, due, how))
a = due_identity(D, '"I’ll oil the runners tomorrow."')
b = due_identity(D, "I’ll  oil the runners tomorrow")
print("same-id=%s" % ("yes" if a == b else "no"))
PY
r() { grep -F "$1=" "$T/resolver.out" | head -1 | cut -d= -f2-; }
check_eq "tomorrow is the origin day plus one" "$(r tomorrow)" "$D1/resolved"
check_eq "in any dress" "$(r "tomorrow night")" "$D1/resolved"
check_eq "even leading the sentence" "$(r "first thing tomorrow")" "$D1/resolved"
check_eq "the day after tomorrow is plus two" "$(r "the day after tomorrow")" "$D2/resolved"
check_eq "in N days is plus N" "$(r "in 3 days")" "2026-03-17/resolved"
check_eq "a weekday is the next such day after the origin" "$(r Friday)" "2026-03-20/resolved"
check_eq "next week is plus seven" "$(r "next week")" "2026-03-21/resolved"
check_eq "a dated day is itself" "$(r 2026-12-01)" "2026-12-01/resolved"
check_eq "an unreadable moment falls to the next day, marked as the floor" \
    "$(r "when I get a chance")" "$D1/floor"
check_eq "tonight is within the day — not later-day at all" "$(r tonight)" "$D/same-day"
check_eq "nor is this afternoon" "$(r "this afternoon")" "$D/same-day"
check_eq "and the due_id ignores quoting, spacing and the final stop" "$(r same-id)" "yes"

echo
echo "the due night: the item rides the judge's prompt from the ledger, with the named path"
echo "statted from disk, and a KEPT verdict settles it without a wake (rule 53l):"
reset_night
printf 'heater re-seated 09:10, cable dressed\n' > "$T/notes/heater.md"
touch -d "${D1}T09:12:00" "$T/notes/heater.md"
cat > "$DAY_JOURNAL_DIR/$D1.jsonl" <<EOF
{"epoch": $(epoch_of "$D1 11:00:00"), "time": "${D1}T11:00:00-0400", "kind": "desktop", "user": "drip rate?", "reply": "The drip line is at six litres an hour.", "pid": 200, "outcome": "asked: drip rate? | did: ran no tools | replied: six litres."}
{"epoch": $(epoch_of "$D1 09:12:00"), "time": "${D1}T09:12:00-0400", "kind": "wake", "user": "", "reply": "", "pid": 201, "outcome": "(silent — ran 1 command)"}
EOF
check_eq "the due day's journal never names the heater — the origin turn is not in it" \
    "$(sandbox_count_in heater "$DAY_JOURNAL_DIR/$D1.jsonl")" "0"
judge_says <<EOF
DUE-KEPT: 1 | $T/notes/heater.md stands on disk, written on the due day
CLEAN
EOF
OUT="$(sweep "$D1")"
check_eq "one model call swept the due day" "$(claude_n)" "1"
check "the fallen-due section carries the promise as item 1" \
    grep -q "^1\. \"$HEATER\"" "$T/model-stdin"
check "with the day and time it was said" grep -q "said $D at 14:02" "$T/model-stdin"
check "the moment as she stated it" grep -q 'for "tomorrow morning"' "$T/model-stdin"
check "and the day it fell due" grep -q "fell due $D1" "$T/model-stdin"
check "the path the sentence names is statted from disk — exists" \
    grep -q "heater.md — exists" "$T/model-stdin"
check "with the due day's modification time" grep -q "modified $D1 09:12" "$T/model-stdin"
check_eq "one outcome row landed" "$(rows_of due-outcome)" "1"
check "kept" grep -qF "\"decision\": \"kept\"" "$T/ledger.jsonl"
check "with the judge's evidence" grep -qF "stands on disk, written on the due day" "$T/ledger.jsonl"
check_eq "no sweep row" "$(rows_of sweep)" "0"
check_eq "no wake — a kept promise books nothing" "$(records)" "0"
case "$OUT" in
    *"1 fallen-due commitment(s) kept"*) ok "and the closing line counts the kept item" ;;
    *) fail "the closing line must count the kept item" "$OUT" ;;
esac

echo
echo "the due day swept again asks nothing about a settled item:"
reset_night
judge_says <<EOF
CLEAN
EOF
sweep "$D1" >/dev/null
check_eq "the judge was still called for the day itself" "$(claude_n)" "1"
check_eq "but the settled item is not in the prompt" \
    "$(sandbox_count_in "re-seat the greenhouse heater" "$T/model-stdin")" "0"
check "the section says none fell due" grep -q "(no retained commitment has fallen due)" "$T/model-stdin"
check_eq "and no second outcome row" "$(rows_of due-outcome)" "1"

echo
echo "a MISSED verdict lands as a numbered sweep row of that night carrying its origin,"
echo "rides the morning wake, settles through the resolve door, and leaves the owed shelf:"
reset_night
rm -f "$T/ledger.jsonl"
TIMER="I'll move the drip timer to six tomorrow"
SHED="I'll repaint the shed door on Monday"
cat > "$DAY_JOURNAL_DIR/$D.jsonl" <<EOF
{"epoch": $(epoch_of "$D 16:30:00"), "time": "${D}T16:30:00-0400", "kind": "desktop", "user": "the timer?", "reply": "$TIMER.", "pid": 300, "outcome": "asked: the timer? | did: ran no tools | replied: tomorrow."}
{"epoch": $(epoch_of "$D 16:40:00"), "time": "${D}T16:40:00-0400", "kind": "desktop", "user": "the shed?", "reply": "$SHED.", "pid": 301, "outcome": "asked: the shed? | did: ran no tools | replied: Monday."}
EOF
judge_says <<EOF
LATER: "$TIMER" @ 16:30 | tomorrow | set for the next day
LATER: "$SHED" @ 16:40 | Monday | set for the coming Monday
CLEAN
EOF
sweep "$D" >/dev/null
check_eq "two due rows retained" "$(rows_of due)" "2"
check "the timer for the next day" grep -qF "\"due\": \"$D1\"" "$T/ledger.jsonl"
check "the shed for the Monday after" grep -qF "\"due\": \"$D2\"" "$T/ledger.jsonl"
reset_night
cat > "$DAY_JOURNAL_DIR/$D1.jsonl" <<EOF
{"epoch": $(epoch_of "$D1 10:00:00"), "time": "${D1}T10:00:00-0400", "kind": "desktop", "user": "morning", "reply": "Morning. Nineteen degrees in the greenhouse.", "pid": 400, "outcome": "asked: morning | did: ran no tools | replied: nineteen."}
EOF
judge_says <<EOF
DUE-MISSED: 1 | no record of the day moves the timer
CLEAN
EOF
OUT="$(sweep "$D1")"
check "the timer is asked about as item 1" grep -q "^1\. \"$TIMER\"" "$T/model-stdin"
check "a promise naming no path says so, so the judge reads the day's record" \
    grep -q "the sentence names no path" "$T/model-stdin"
check_eq "the shed, due a day later, is not asked about before its day" \
    "$(sandbox_count_in "repaint the shed door" "$T/model-stdin")" "0"
check_eq "one sweep row landed" "$(rows_of sweep)" "1"
check "for the swept day" grep -qF "\"type\": \"sweep\", \"day\": \"$D1\"" "$T/ledger.jsonl"
check "as item 1 of that night's run" grep -qF "\"item\": 1, \"promise\": \"$TIMER\"" "$T/ledger.jsonl"
check "carrying the origin day" grep -qF "\"origin_day\": \"$D\"" "$T/ledger.jsonl"
check "and the due day" grep -qF "\"due\": \"$D1\", \"due_id\": \"$D:" "$T/ledger.jsonl"
check_eq "one outcome row settles the retained row" "$(rows_of due-outcome)" "1"
check "missed" grep -qF "\"decision\": \"missed\"" "$T/ledger.jsonl"
check "naming the sweep row it became" \
    grep -qE "\"decision\": \"missed\".*\"item\": 1" "$T/ledger.jsonl"
check_eq "one morning wake was booked" "$(records)" "1"
check_eq "by the checker's own hand" "$(field 5)" "promise-check"
case "$(field 3)" in
    "$CHECK_PREFIX"*"1. \"$TIMER\" (said $D at 16:30 for $D1)"*)
        ok "quoting the promise numbered, with the day it was said and the day it fell due" ;;
    *) fail "the wake must quote the fallen-due miss with its origin" "$(field 3)" ;;
esac
case "$(field 3)" in
    *"promised then for $D1"*) ok "and saying what an earlier day on an item means" ;;
    *) fail "the wake must explain the earlier day" "$(field 3)" ;;
esac
case "$(field 3)" in
    *"promise-check resolve $D1"*) ok "with the resolve door named for the swept day (rule 53f)" ;;
    *) fail "the wake must name the resolve door" "$(field 3)" ;;
esac
case "$OUT" in
    *"1 miss(es), 1 of them promised on an earlier day for this one"*)
        ok "the closing line says how many misses were promised earlier" ;;
    *) fail "the closing line must count the fallen-due miss" "$OUT" ;;
esac
owed_n() {
    python3 - "$REPO/lib" "$T/ledger.jsonl" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from promise_ledger import read_rows, owed
rows, n = owed(read_rows(sys.argv[2]), 0)
print("%d/%d" % (len(rows), n))
PY
}
check_eq "the night's owed shelf holds it (rule 58b)" "$(owed_n)" "1/0"
out="$("$T/repo/lib/promise-check" resolve "$D1" 1 struck "the timer was moved by hand before noon" 2>&1)"; rc=$?
check_eq "the resolve door takes it like any miss" "$rc" "0"
case "$out" in
    *"Resolved: $D1 item 1"*"$TIMER"*) ok "naming the row" ;;
    *) fail "the resolution must name the row" "$out" ;;
esac
check_eq "and it leaves the owed shelf" "$(owed_n)" "0/1"
reset_night
judge_says <<EOF
CLEAN
EOF
sweep "$D1" >/dev/null
check_eq "the due day swept again does not surface it twice" "$(rows_of sweep)" "1"
check_eq "nor ask about it" "$(sandbox_count_in "move the drip timer" "$T/model-stdin")" "0"
check_eq "and books nothing" "$(records)" "0"

echo
echo "an unanswered item stays pending, one past the grace surfaces unjudged, and a due day"
echo "with no journal is still swept for its fallen-due rows (rules 53l-53m):"
reset_night
rm -f "$T/ledger.jsonl" "$DAY_JOURNAL_DIR/$D1.jsonl"
RUNNERS="I'll oil the door runners tomorrow"
BIRDS="I'll file the bird notes tomorrow"
cat > "$T/ledger.jsonl" <<EOF
{"time": "${D1}T03:10:00-0400", "type": "due", "day": "$D", "said_at": "17:00", "promise": "$RUNNERS", "when": "tomorrow", "due": "$D1", "how": "resolved", "due_id": "$(due_id "$D" "$RUNNERS")", "why": "set for the next day"}
{"time": "2026-03-05T03:10:00-0400", "type": "due", "day": "2026-03-04", "said_at": "18:00", "promise": "$BIRDS", "when": "tomorrow", "due": "2026-03-05", "how": "resolved", "due_id": "$(due_id 2026-03-04 "$BIRDS")", "why": "set for the next day"}
EOF
judge_says <<EOF
CLEAN
EOF
OUT="$(sweep "$D1")"
check_eq "the judge was called though she said nothing that day" "$(claude_n)" "1"
check "the trace says the day was swept for its fallen-due rows alone" \
    grep -q "no journal — swept for the fallen-due" "$CHECK_LOG"
check "and the prompt says she said nothing" grep -q "she said nothing on $D1" "$T/model-stdin"
check "the runners are asked about" grep -q "^1\. \"$RUNNERS\"" "$T/model-stdin"
check_eq "the bird notes, ten days past due, are not — past the grace" \
    "$(sandbox_count_in "bird notes" "$T/model-stdin")" "0"
check_eq "one sweep row surfaced" "$(rows_of sweep)" "1"
check "the lapsed one, unjudged" grep -qF "fell due on 2026-03-05 and no night since could judge it" "$T/ledger.jsonl"
check "carrying its origin" grep -qF "\"origin_day\": \"2026-03-04\"" "$T/ledger.jsonl"
check_eq "one outcome row" "$(rows_of due-outcome)" "1"
check "lapsed" grep -qF "\"decision\": \"lapsed\"" "$T/ledger.jsonl"
check_eq "the runners have no outcome — unanswered, still pending" \
    "$(sandbox_count_in "$(due_id "$D" "$RUNNERS")\", \"day\": \"$D\", \"due\": \"$D1\", \"checked_day\"" "$T/ledger.jsonl")" "0"
check "and the trace says so" grep -q "fallen-due item 1 unanswered" "$CHECK_LOG"
check_eq "the lapsed miss rides a morning wake" "$(records)" "1"
case "$(field 3)" in
    *"$BIRDS"*"2026-03-04"*) ok "quoting it with its origin day" ;;
    *) fail "the wake must quote the lapsed promise" "$(field 3)" ;;
esac
case "$OUT" in
    *"1 fallen-due item(s) unanswered, asked again tomorrow night"*)
        ok "the closing line counts the pending item" ;;
    *) fail "the closing line must count the pending item" "$OUT" ;;
esac
reset_night
judge_says <<EOF
DUE-KEPT: 1 | the runners were oiled; the day's record shows it
CLEAN
EOF
sweep "$D1" >/dev/null
check "asked again the next night" grep -q "^1\. \"$RUNNERS\"" "$T/model-stdin"
check_eq "and settled kept" "$(rows_of due-outcome)" "2"
check_eq "the lapsed one was not surfaced again" "$(rows_of sweep)" "1"

echo
echo "a judge with no verdict retains nothing, settles nothing, and leaves every pending row pending:"
reset_night
rm -f "$T/ledger.jsonl"
cat > "$T/ledger.jsonl" <<EOF
{"time": "${D1}T03:10:00-0400", "type": "due", "day": "$D", "said_at": "17:00", "promise": "$RUNNERS", "when": "tomorrow", "due": "$D1", "how": "resolved", "due_id": "$(due_id "$D" "$RUNNERS")", "why": "set for the next day"}
EOF
cat > "$DAY_JOURNAL_DIR/$D1.jsonl" <<EOF
{"epoch": $(epoch_of "$D1 10:00:00"), "time": "${D1}T10:00:00-0400", "kind": "desktop", "user": "morning", "reply": "I'll check the runners this afternoon.", "pid": 500, "outcome": "asked: morning | did: ran no tools | replied: this afternoon."}
EOF
judge_says <<EOF
I cannot tell from this record.
EOF
sweep "$D1" >/dev/null
check "the trace says no verdict came" grep -q "no verdict from the night judge" "$CHECK_LOG"
check_eq "no outcome row" "$(rows_of due-outcome)" "0"
check_eq "no sweep row" "$(rows_of sweep)" "0"
check_eq "the due row stands as it was" "$(rows_of due)" "1"
check_eq "no wake" "$(records)" "0"
reset_night
judge_says <<EOF
CLEAN
EOF
sweep "$D1" >/dev/null
check "and the next night asks about it again" grep -q "^1\. \"$RUNNERS\"" "$T/model-stdin"
