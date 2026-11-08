#!/bin/bash
# Engineering records (specs/engineering-records.md, prompt-assembly rule 21a).
# Run: bash tests/test_eng_records.sh
#
# The failure this system exists to end: an engineering note was appended
# prose with no state, so a worry written BEFORE a question was settled kept
# reading as present-tense fact — and twice on 2026-08-10 it was announced as
# a live code flaw that did not exist. These cases prove the record
# round-trips, that every state transition bumps last_touched through the one
# tool, that a settled record renders as history rather than as quotable
# present-tense prose, and that migration preserves dates without guessing at
# state.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
D="$XDG_DATA_HOME/deskcrab"
ENG="$D/engineering/records"
E() { DESKCRAB_ENG_DIR="$ENG" python3 "$REPO_DIR/lib/eng" "$@"; }

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

echo "a record round-trips:"
ID="$(E new "The frobnicator loses its state" \
        --summary "state drops between turns" \
        --body "The frobnicator is broken and drops its state every turn.")"
check_eq "new prints the slug id" "$ID" "the-frobnicator-loses-its-state"
check "the record file exists" test -s "$ENG/$ID.md"
check_eq "state opens open"        "$(E field "$ID" state)" "open"
check_eq "title survives"          "$(E field "$ID" title)" "The frobnicator loses its state"
check_eq "summary survives"        "$(E field "$ID" summary)" "state drops between turns"
OPENED="$(E field "$ID" opened)"
check "opened is a datetime" \
    bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]' _ "$OPENED"
check_eq "last_touched starts as opened" "$(E field "$ID" last_touched)" "$OPENED"
check "show prints the body" bash -c 'E() { DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" "$@"; }; E show "$1" | grep -q "drops its state every turn"' _ "$ID"
check "an unknown id is an error, not a fresh file" \
    bash -c '! DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" show no-such-thing 2>/dev/null'
refute "and no file appeared for it" test -e "$ENG/no-such-thing.md"

echo
echo "touch appends a dated entry AND bumps last_touched in one motion:"
T0="$(E field "$ID" last_touched)"
sleep 1
E touch "$ID" "poked the frobnicator; nothing fell out" >/dev/null
T1="$(E field "$ID" last_touched)"
check "last_touched moved" test "$T1" != "$T0"
check "the note is in the body" grep -q "nothing fell out" "$ENG/$ID.md"
# Newest first: the fresh entry's heading is the first heading in the body.
FIRST_ENTRY="$(grep -m1 '^## ' "$ENG/$ID.md")"
check_eq "the newest entry heads the body, dated with the bump" \
    "$FIRST_ENTRY" "## $T1"
check "touched-since sees a touch after an old epoch" \
    E touched-since "$ID" 1000000
refute "and refuses one before a future epoch" \
    E touched-since "$ID" 9999999999

echo
echo "settle and kill are transitions with a paper trail:"
sleep 1
E settle "$ID" "the state was never lost — commit abc123" >/dev/null
check_eq "state is settled"      "$(E field "$ID" state)" "settled"
check "settled_at is stamped"    test -n "$(E field "$ID" settled_at)"
check_eq "settled_by holds what settled it" \
    "$(E field "$ID" settled_by)" "the state was never lost — commit abc123"
T2="$(E field "$ID" last_touched)"
check "settling bumped last_touched too" test "$T2" != "$T1"
ID2="$(E new "A dead end")"
E kill "$ID2" "overtaken by events" >/dev/null
check_eq "kill lands state dead"  "$(E field "$ID2" state)" "dead"
check_eq "with its reason on record" "$(E field "$ID2" settled_by)" "overtaken by events"

echo
echo "list and search:"
ID3="$(E new "A live worry about the doohickey")"
LIST="$(E list)"
check "list carries the open record"    contains "$LIST" "$ID3"
check "list carries the settled record" contains "$LIST" "settled 20"
check_eq "list --state open filters"    "$(E list --state open | grep -c open)" "1"
check "search finds by word across records" bash -c 'DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" search frobnicator | grep -q frobnicator'
check "search misses honestly (exit 1)" \
    bash -c '! DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" search zanzibar-xylophone >/dev/null'

echo
echo "the prompt block — a pointer with counts and doors, never record lines:"
BLOCK="$(E prompt)"
check "the block counts the live and closed threads" \
    contains "$BLOCK" "1 live thread and 2 closed"
refute "no open record's title rides the prompt" \
    contains "$BLOCK" "doohickey"
refute "no record dates ride the prompt" \
    contains "$BLOCK" "opened 20"
refute "no outcome line rides the prompt" \
    contains "$BLOCK" "overtaken by events"
refute "the settled record's present-tense body prose is NOT in the prompt" \
    contains "$BLOCK" "is broken and drops its state"
check "the block orders the record read first, every time" \
    contains "$BLOCK" "read the record first, every single time"
check "and names every retrieval door" \
    contains "$BLOCK" "crab eng list --state all"
check "a closed record is named history" \
    contains "$BLOCK" "history, never a present-tense fact"
check "the block names the tool as the only writer" \
    contains "$BLOCK" "never a hand edit"

echo
echo "the block reaches the assembled prompt, and its absence costs nothing:"
cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf '# Wants\n\n- 🎼 **Learn to read a score**\n' > "$D/wants.md"
PROMPT="$(sandbox_bash 'build_system_prompt --profile turn')"
check "the turn prompt carries the records block" \
    contains "$PROMPT" "YOUR ENGINEERING RECORDS"
refute "the outcome essays stay in the drawer" \
    contains "$PROMPT" "the state was never lost — commit abc123"
refute "and the settled record's body prose too" \
    contains "$PROMPT" "is broken and drops its state"
PROMPT_WAKE="$(sandbox_bash 'build_system_prompt --profile wake')"
check "the wake prompt carries the same pointer" \
    contains "$PROMPT_WAKE" "YOUR ENGINEERING RECORDS"
refute "with no record lines on it either" \
    contains "$PROMPT_WAKE" "the state was never lost — commit abc123"
rm -rf "$ENG"
PROMPT2="$(sandbox_bash 'build_system_prompt --profile turn')"
refute "an empty drawer costs the block" \
    contains "$PROMPT2" "YOUR ENGINEERING RECORDS"
check "and never the prompt" contains "$PROMPT2" "THIS TURN IS ABOUT"

echo
echo "migration — dates preserved, state open where unknown, never guessed:"
cat > "$SANDBOX/prose.md" <<'PROSE'
## 2026-08-09 22:20 — a hundred bytes took my voice off the desk

The persona budget stood stale and the fitter dropped Continuity.

## 2026-08-11 — a dated entry with no clock

Body of the undated-time entry.

## 2026-08-11 09:56 — SETTLED: the drain cap is 2, not 4

Confirmed against the unit file.
PROSE
OUT="$(E migrate "$SANDBOX/prose.md")"
check "migrate reports its counts" contains "$OUT" "3 records created"
check_eq "a dated heading becomes opened" \
    "$(E field a-hundred-bytes-took-my-voice-off-the-desk opened)" "2026-08-09 22:20:00"
check_eq "and last_touched matches it" \
    "$(E field a-hundred-bytes-took-my-voice-off-the-desk last_touched)" "2026-08-09 22:20:00"
check_eq "an entry with no settlement marker stays open" \
    "$(E field a-hundred-bytes-took-my-voice-off-the-desk state)" "open"
check_eq "a date-only heading keeps its date" \
    "$(E field a-dated-entry-with-no-clock opened)" "2026-08-11 00:00:00"
check_eq "a heading that marks itself SETTLED migrates settled" \
    "$(E field settled-the-drain-cap-is-2-not-4 state)" "settled"
check "the body prose survives in the record" \
    grep -q "fitter dropped Continuity" "$ENG/a-hundred-bytes-took-my-voice-off-the-desk.md"
OUT2="$(E migrate "$SANDBOX/prose.md")"
check "migration is idempotent" contains "$OUT2" "0 records created, 3 already existed"
check "the source file is untouched" grep -q "SETTLED: the drain cap" "$SANDBOX/prose.md"

echo
echo "migration reads the archive index's bullet shape too:"
cat > "$SANDBOX/index.md" <<'IDX'
# Threads

- [wobbly-axle.md](wobbly-axle.md) — 2026-08-11 survey: the axle wobbles, and
  the description wraps onto a second line.
- [old-victory.md](old-victory.md) — a fight that ended well (settled)
IDX
OUT3="$(E migrate "$SANDBOX/index.md")"
check "both bullets became records" contains "$OUT3" "2 records created"
check_eq "the record keeps the thread file's name as id" \
    "$(E field wobbly-axle title)" "wobbly-axle"
check_eq "the description's date becomes opened" \
    "$(E field wobbly-axle opened)" "2026-08-11 00:00:00"
check_eq "no settlement marker means open" \
    "$(E field wobbly-axle state)" "open"
check "the wrapped description is unwrapped whole into the summary" \
    bash -c 'DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" field wobbly-axle summary | grep -q "wobbles, and the description wraps"'
check "the record points back at the archive file" \
    grep -q "wobbly-axle.md, beside the index" "$ENG/wobbly-axle.md"
check_eq "a bullet marking itself settled migrates settled" \
    "$(E field old-victory state)" "settled"
OUT4="$(E migrate "$SANDBOX/index.md")"
check "the index migration is idempotent too" contains "$OUT4" "0 records created, 2 already existed"

echo
echo "the pointer scales by counting, never by listing:"
# A controlled drawer, written directly: the cases need dates the tool
# would always stamp as now. The tool still reads them through the one
# parser, so the shape is the record shape.
rm -rf "$ENG"; mkdir -p "$ENG"
mkrec() {  # <id> <state> <settled_at> [last_touched]
    local id="$1" state="$2" sat="$3" touched="${4:-${3:-2026-01-01 00:00:00}}"
    cat > "$ENG/$id.md" <<REC
---
id: $id
title: $id
opened: 2026-01-01 00:00:00
last_touched: $touched
state: $state
settled_at: $sat
settled_by: fixture outcome
summary: $id
---

## 2026-01-01 00:00:00

Body prose of $id.
REC
}
ts() { date -d "$1" '+%Y-%m-%d %H:%M:%S'; }  # fixed 19-byte datetimes
mkrec stale-open open "" "$(ts '-400 days')"
mkrec fresh-a settled "$(ts '-1 day')"
mkrec fresh-b settled "$(ts '-2 days')"
for i in 0 1 2 3 4 5 6 7; do
    mkrec "old-$i" settled "$(ts "-$((40 + i)) days")"
done
BLOCK="$(E prompt)"
check "an open record never ages out of the live count, however old" \
    contains "$BLOCK" "1 live thread and 10 closed"
refute "but its id never rides the block" \
    contains "$BLOCK" "stale-open"
refute "and no closure rides either" \
    contains "$BLOCK" "fresh-a"
check "an unlisted record is reachable through list --state all" \
    bash -c 'DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" list --state all | grep -q old-7'
check "and through show" \
    bash -c 'DESKCRAB_ENG_DIR="'"$ENG"'" python3 "'"$REPO_DIR"'/lib/eng" show old-7 | grep -q "Body prose of old-7"'
for i in $(seq 0 29); do
    mkrec "rc-$i" settled "$(ts "-$((i + 100)) seconds")"
done
check "thirty more closures move the count alone" \
    contains "$(E prompt)" "1 live thread and 40 closed"
check_eq "the block stays one paragraph however full the drawer" \
    "$(E prompt | wc -l)" "1"

echo
echo "a review claim is live and named, never listed:"
mkrec old-review review "" "$(ts '-500 days')"
BLOCK_R="$(E prompt)"
check "the review is counted among the live threads, marked unsettled" \
    contains "$BLOCK_R" "2 live threads (1 of them in review — completion claimed, NOT settled"
refute "but its id stays in the drawer" \
    contains "$BLOCK_R" "old-review"
