#!/bin/bash
# Her face on the desk's own notices — specs/turn-pipeline.md rule 4a. The
# three capture notifications (the listening notice, its dismissal, the
# empty-capture notice) name the desktop icon by theme name, `-i beatrice`,
# never by a file path: the installed hicolor mark is deployed state, and a
# path burned into the call goes stale the moment the source tree moves.
# Before this the calls passed no icon at all and every notice drew blank.
# Run: bash tests/test_notify_icon.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

P="$DESKCRAB_STATE_PREFIX"
CONVO="$P-convo.txt"
SESSLOG="$P-sessions.log"

cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$SANDBOX/home"
WAKE_QUIET_HOURS=""
EOF

echo "crab start raises the listening notice wearing the mark:"
: > "$SANDBOX_NOTIFY_LOG"
"$SANDBOX_REPO/crab" start >/dev/null 2>&1
listen="$(grep -F 'Listening...' "$SANDBOX_NOTIFY_LOG")"
check "the listening notice was raised" [ -n "$listen" ]
check "and names the icon by theme name" contains "$listen" "-i beatrice"
refute "never by a file path" contains "$listen" "/"
check "the recorder pid was written" [ -s "$DESKCRAB_PIDFILE" ]

echo
echo "crab stop on an empty capture: the dismissal and the notice both wear it:"
: > "$SANDBOX_NOTIFY_LOG"
"$SANDBOX_REPO/crab" stop >/dev/null 2>&1; rc=$?
check_eq "an empty capture exits 1" "$rc" "1"
dismiss="$(grep -F -- '-t 1 ' "$SANDBOX_NOTIFY_LOG")"
check "the listening notice was dismissed" [ -n "$dismiss" ]
check "with the icon on the dismissal" contains "$dismiss" "-i beatrice"
nospeech="$(grep -F 'No speech detected' "$SANDBOX_NOTIFY_LOG")"
check "the empty-capture notice was raised" [ -n "$nospeech" ]
check "with the icon on it too" contains "$nospeech" "-i beatrice"
refute "and no path on either" grep -qF "$SANDBOX_REPO" "$SANDBOX_NOTIFY_LOG"

echo
echo "…and rule 4 still holds around it — an empty capture starts nothing:"
check_eq "the model was never called" \
    "$(sandbox_count_in . "$SANDBOX_CLAUDE_LOG")" "0"
check "no conversation write" [ ! -e "$CONVO" ]
check "no session registered" [ ! -s "$SESSLOG" ]
check "nothing spoken" [ ! -s "$SANDBOX_SPOKEN_LOG" ]
