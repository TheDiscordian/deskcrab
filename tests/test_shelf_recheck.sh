#!/bin/bash
# The shelf re-check rides the tidy's own tail — specs/nightly.md rules 21a
# and 21b. At 03:25 on 2026-09-06 the state block led with SHELF LINES OVER
# BUDGET naming a line at 530 bytes while the line on disk measured 114: the
# only measurement was the unit's ExecStartPre, taken BEFORE the tidy job
# that cured the finding was dispatched, so a cured line kept shouting from
# every speaking prompt for a day, indistinguishable from a live finding.
# This file holds the cure cycle: the pre-check writes the record and the
# state block shouts it; the line trimmed, the re-check the brief's last
# step names — `crab shelf-check`, the by-hand door of rule 21b — exits
# zero, REMOVES the record, and the state block goes quiet the same night;
# and the tidy brief ends on that step, asserted against the brief the
# shipped unit's ExecStart actually dispatches, never a copy held here.
# Run: bash tests/test_shelf_recheck.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/wants"

cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$SANDBOX/home"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS=""
EOF

REC="$DESKCRAB_STATE_PREFIX-shelf-overruns.txt"
run() { sandbox_bash "$1"; }

# ~640 bytes of history riding the line — the cured-line night in miniature.
TAIL="$(printf 'the history that belongs in the document %.0s' $(seq 1 16))"

echo "the pre-check finds the over-budget line and puts the record up:"
printf '# Wants\n\n- 🎼 **Learn the whole score** — %s → score.md\n' "$TAIL" > "$D/wants.md"
out="$("$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check "the check exits non-zero" [ "$rc" -ne 0 ]
check "the record stands" [ -s "$REC" ]
check "naming the line's document" grep -q 'score\.md' "$REC"
check "and the state block shouts it" \
    contains "$(run 'self_state_report')" "SHELF LINES OVER BUDGET"

echo
echo "the tidy trims the line; the brief's closing re-check clears the shout tonight:"
printf '# Wants\n\n- 🎼 **Learn the whole score** → score.md\n' > "$D/wants.md"
out="$("$SANDBOX_REPO/crab" shelf-check 2>&1)"; rc=$?
check_eq "the re-check exits zero" "$rc" "0"
check "and says the shelf is clean, in the check's own name" \
    contains "$out" "inside the"
check "the record is REMOVED, not left to tomorrow's check" [ ! -e "$REC" ]
refute "and the state block renders no over-budget finding" \
    contains "$(run 'self_state_report')" "SHELF LINES OVER BUDGET"

echo
echo "the brief the dispatcher emits ends on the shelf-check step:"
UNIT="$SANDBOX_REPO/systemd/deskcrab-tidy.service"
brief="$(sed -n 's/^ExecStart=.*crab job .* "\(.*\)"[[:space:]]*$/\1/p' "$UNIT")"
check "the shipped unit's ExecStart carries the tidy brief" [ -n "$brief" ]
last_step="${brief##*\\n}"
check "the brief's last step is a numbered step of its list" \
    grep -qE '^[0-9]+[a-z]?\.' <<<"$last_step"
check "and that closing step runs the re-check by the by-hand door" \
    contains "$last_step" "crab shelf-check"
