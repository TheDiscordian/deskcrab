#!/bin/bash
# A named maintenance command is a dispatch case, never speech — specs/
# turn-pipeline.md rule 6a beside specs/nightly.md rules 21a and 21b. At
# 23:43 on 2026-08-25 an autonomous hand ran `crab shelf-check` intending
# the nightly shelf-line check, and the catch-all treated the name as a
# message: a three-second desktop turn ran whose user text was
# "shelf-check". This file pins the door: `crab shelf-check` runs the real
# lib/shelf-check with no model call, no session, no conversation write, no
# live-turn record, nothing spoken and nothing notified — while a plain
# message still starts exactly the conversational turn it always did, and
# the usage paths exit without a turn instead of running an empty one
# behind the usage line (the `exit` welded onto the `echo` as one more
# argument, 2026-08-25).
# Run: bash tests/test_crab_dispatch.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/wants"
P="$DESKCRAB_STATE_PREFIX"
CONVO="$P-convo.txt"
SESSLOG="$P-sessions.log"
LIVETURN="$P-live-turn"
REC="$P-shelf-overruns.txt"

printf '# Wants\n\n- 🎼 **Learn to read a score** → score.md\n' > "$D/wants.md"

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

reset_witnesses() {
    : > "$SANDBOX_CLAUDE_LOG"; : > "$SANDBOX_SPOKEN_LOG"; : > "$SANDBOX_NOTIFY_LOG"
    : > "$SANDBOX_DISPLAY_LOG"
    rm -f "$CONVO" "$SESSLOG" "$LIVETURN"
}

# The whole claim, spelled out once: nothing of the conversational path moved.
no_turn_started() {  # <label>
    check_eq "$1: the model was never called" \
        "$(sandbox_count_in . "$SANDBOX_CLAUDE_LOG")" "0"
    check "$1: no conversation write" [ ! -e "$CONVO" ]
    check "$1: no session registered" [ ! -s "$SESSLOG" ]
    check "$1: no live-turn record" [ ! -e "$LIVETURN" ]
    check "$1: nothing spoken" [ ! -s "$SANDBOX_SPOKEN_LOG" ]
    check "$1: nothing notified" [ ! -s "$SANDBOX_NOTIFY_LOG" ]
}

echo "crab shelf-check runs the maintenance command, never a turn:"
reset_witnesses
out="$("$SANDBOX_REPO/crab" shelf-check 2>&1)"; rc=$?
check_eq "a clean shelf exits zero" "$rc" "0"
check "and answers in the check's own name" contains "$out" "shelf-check:"
refute "never as a spoken reply about it" contains "$out" "stub reply"
no_turn_started "shelf-check (clean)"

echo
echo "…and it is the real check, not a nod at one:"
TAIL="$(printf 'the history that belongs in the document %.0s' $(seq 1 16))"
printf -- '- 🔭 **Notice the weeks** — %s → noticing.md\n' "$TAIL" >> "$D/wants.md"
reset_witnesses
out="$("$SANDBOX_REPO/crab" shelf-check 2>&1)"; rc=$?
check "an over-budget shelf exits non-zero" [ "$rc" -ne 0 ]
check "names the flagged line" contains "$out" "Notice the weeks"
check "and writes the standing record" [ -s "$REC" ]
no_turn_started "shelf-check (over budget)"

echo
echo "the catch-all is still the spoken channel for a plain message:"
reset_witnesses
"$SANDBOX_REPO/crab" "is the kettle done" >/dev/null 2>&1 || true
check "the model ran" [ "$(sandbox_count_in . "$SANDBOX_CLAUDE_LOG")" -gt 0 ]
check "the message reached the conversation" grep -qF "is the kettle done" "$CONVO"

echo
echo "usage is printed, never spoken to:"
reset_witnesses
out="$("$SANDBOX_REPO/crab" 2>&1)"; rc=$?
check_eq "no arguments exits 1" "$rc" "1"
check "with the usage line" contains "$out" "Usage: crab"
check "which names shelf-check as a command" contains "$out" "shelf-check"
refute "and carries no welded exit token" grep -q 'exit [01]$' <<<"$out"
no_turn_started "bare crab"

reset_witnesses
out="$("$SANDBOX_REPO/crab" help 2>&1)"; rc=$?
check_eq "crab help exits 0" "$rc" "0"
check "prints the usage" contains "$out" "Usage: crab"
refute "with no welded exit token either" grep -q 'exit [01]$' <<<"$out"
no_turn_started "crab help"
