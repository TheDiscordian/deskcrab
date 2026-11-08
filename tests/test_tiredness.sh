#!/bin/bash
# Tests for the tiredness scorer and the state block's closing line —
# specs/self-awareness.md rules 36-38. Run: bash tests/test_tiredness.sh
#
# The scorer is arithmetic on file facts: the same fabricated pile must always
# say the same number, a fresh marker must read rested, a measured-heavy day
# must land mid-range rather than pegged, and a missing marker must say that no
# sleep is on record instead of scoring the pile as fresh. The block must carry
# the line, and must survive the scorer having nothing to read.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
TIRED="$SANDBOX_REPO/lib/tiredness"
NOW="$(date +%s)"
TODAY="$(date +%F)"

mkpile() {  # <name> — a scratch pile, empty
    mkdir -p "$T/$1/journal" "$T/$1/jobs" "$T/$1/flags"
}
score() {  # <name> [--line]
    LAST_SLEPT_FILE="$T/$1/last-slept" DAY_JOURNAL_DIR="$T/$1/journal" \
    JOBS_DIR="$T/$1/jobs" CLAUDISM_FLAGS_DIR="$T/$1/flags" "$TIRED" "${2:-}" 2>&1
}

echo "a fresh marker over an empty pile reads rested, at zero:"
mkpile fresh
printf '%s\n%s\nadded=0\n' "$NOW" "$(date -Is)" > "$T/fresh/last-slept"
out="$(score fresh)"
check "score is 0" contains "$out" "Tiredness: 0/100 — rested"
out="$(score fresh --line)"
check "the line says rested too" contains "$out" "Tiredness: 0/100, rested"

echo "the calibration day lands mid-range, not pegged:"
# The observed 2026-08-08 pile, fabricated: ~110 turns of ~1.6 KB, 12 finished
# jobs, 16 flags, 20 hours awake. engineering/tiredness-score.md holds why
# these are the mid-range anchors.
mkpile mid
S=$(( NOW - 20 * 3600 ))
printf '%s\n' "$S" > "$T/mid/last-slept"
pad="$(printf 'x%.0s' $(seq 1 1550))"
for i in $(seq 1 110); do
    printf '{"epoch": %s, "kind": "turn", "reply": "%s"}\n' "$(( S + i * 60 ))" "$pad"
done > "$T/mid/journal/$TODAY.jsonl"
for i in $(seq 1 12); do
    printf '{\n "id": "j%s",\n "finished_epoch": %s\n}\n' "$i" "$(( S + i * 600 ))" > "$T/mid/jobs/j$i.json"
done
for i in $(seq 1 16); do printf '{"epoch": %s}\n' "$(( S + i * 60 ))"; done > "$T/mid/flags/$TODAY.jsonl"
n="$(score mid | sed -n 's/^Tiredness: \([0-9]*\)\/100.*/\1/p')"
check "mid-range: 40..65, got $n" test "${n:-0}" -ge 40 -a "${n:-0}" -le 65
check "and its word is heavy" contains "$(score mid)" "heavy"

echo "everything at its full mark pegs the score, and no further:"
mkpile full
S=$(( NOW - 40 * 3600 )); YDAY="$(date -d "@$S" +%F)"
printf '%s\n' "$S" > "$T/full/last-slept"
pad="$(printf 'x%.0s' $(seq 1 2400))"
for i in $(seq 1 300); do
    printf '{"epoch": %s, "reply": "%s"}\n' "$(( S + i * 300 ))" "$pad"
done > "$T/full/journal/$YDAY.jsonl"
for i in $(seq 1 20); do printf '{\n "finished_epoch": %s\n}\n' "$(( S + i * 60 ))" > "$T/full/jobs/j$i.json"; done
for i in $(seq 1 50); do printf '{"epoch": %s}\n' "$(( S + i * 60 ))"; done > "$T/full/flags/$YDAY.jsonl"
check "pegged at 100, overfull" contains "$(score full)" "Tiredness: 100/100 — overfull"

echo "a missing marker says so — it never scores the pile as fresh:"
mkpile never
printf '{"epoch": %s}\n' "$(( NOW - 3600 ))" > "$T/never/journal/$TODAY.jsonl"
out="$(score never --line)"
check "the line admits no sleep is on record" contains "$out" "no sleep on record"

echo "lines from before the marker in the same day's file do not count:"
mkpile edge
S=$(( NOW - 2 * 3600 ))
printf '%s\n' "$S" > "$T/edge/last-slept"
printf '{"epoch": %s}\n{"epoch": %s}\n{"epoch": %s}\n' \
    "$(( S - 999 ))" "$(( S + 10 ))" "$(( S + 20 ))" > "$T/edge/journal/$TODAY.jsonl"
check "two of three counted" contains "$(score edge)" "turns journaled: 2"

echo "the state block closes with the line, and an empty pile does not break it:"
# The sandbox's scratch instance has no last-slept marker and empty stores —
# exactly the state rule 37 says must cost nothing.
out="$(sandbox_bash 'self_state_report --prompt' 2>&1)"
check "the prompt block carries the tiredness line" contains "$out" "Tiredness: "
check "over an empty pile it reads the never-slept form" contains "$out" "no sleep on record"
out="$(sandbox_bash 'self_state_report' 2>&1)"
check "the dashboard carries it too" contains "$out" "Tiredness: "
