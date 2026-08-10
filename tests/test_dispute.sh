#!/bin/bash
# The dispute turn — specs/cocoon.md rules 6-10, prompt-assembly.md rule 36b.
# Run: bash tests/test_dispute.sh
#
# The detector is judged on the sentences that were actually said on
# 2026-08-10, and the escalation is judged where it lands: in the argv the
# stub CLI was invoked with.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

CONVO="$DESKCRAB_STATE_PREFIX-convo.txt"
cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WAKE_QUIET_HOURS=""
CLAUDE_MODEL="opus"
CLAUDE_EFFORT="low"
DISPUTE_MODEL="fable"
DISPUTE_EFFORT="high"
EOF

run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

detects() {  # <desc> <message>
    run "dispute_detect \"\$(cat <<'MSG'
$2
MSG
)\"" >/dev/null 2>&1 && ok "$1" || fail "$1"
}
passes() {  # <desc> <message>
    run "dispute_detect \"\$(cat <<'MSG'
$2
MSG
)\"" >/dev/null 2>&1 && fail "$1" || ok "$1"
}

echo "before she has said anything there is nothing to dispute:"
rm -f "$CONVO"
passes "even 'you are wrong' opens no dispute on an empty record" "you are wrong"

printf 'User [12:00]: how goes it\nAssistant [12:00]: an answer he may yet reject\n' > "$CONVO"

echo
echo "the day's real sentences fire the detector:"
detects "the path fixation complaint" \
    "No, you're hyper-fixated on the fucking path thing, B."
detects "the report with the gaslight charge" \
    "You just told me I never heard honest from you. but I did hear honest from you. I'm reporting. a fucking bug. Do not gaslight or lie."
detects "the double you-are-wrong" \
    "stop assuming I'm wrong you are wrong you are wrong not me I am not wrong"
detects "the quiet-block report" \
    "I'm reporting a genuine bug to you. where it said Quiet. And the word honest was in it"
detects "the one-more-time ultimatum" \
    "if you say quotation marks to me one more fucking time, I'm turning you offline"
detects "the goodbye" \
    "Okay, I'm taking you offline. It has nothing to do with quotation marks and you want- fucking listen to me."
detects "the chess-vs-chest correction" \
    "No, I said chess. What is wrong with you?"

echo
echo "benign kin do not:"
passes "a plain question" "How's your chess setup going?"
passes "a no of agreement" "no worries, that sounds right"
passes "a repeat request" "play the opening again"
passes "a benign retelling" "I said yes to the meeting invite"
passes "praise with colour" "that was fucking great"

echo
echo "the layer joins a flagged turn and no other:"
D="$XDG_DATA_HOME/deskcrab"; mkdir -p "$D"
printf '# Wants\n- **a want**\n' > "$D/wants.md"
TURN="$(run 'PROMPT_DISPUTE=1 build_system_prompt --profile turn')"
check "a flagged turn carries the dispute frame" \
    contains "$TURN" "HE IS PUSHING BACK"
check "and the frame kills the rejected theory" \
    contains "$TURN" "DEAD"
state="$(run 'PROMPT_DISPUTE=1 build_system_prompt --profile turn --layers' \
         | awk -F'\t' '$1 == "dispute" { print $4 }')"
check_eq "the manifest carries it inside its budget" "$state" "full"
refute "an unflagged turn does not" \
    contains "$(run 'build_system_prompt --profile turn')" "HE IS PUSHING BACK"
refute "a wake never does — no message to be pushed back on" \
    contains "$(run 'PROMPT_DISPUTE=1 build_system_prompt --profile wake')" "HE IS PUSHING BACK"

echo
echo "a dispute turn is bought at strength — in the argv the CLI actually got:"
: > "$SANDBOX_CLAUDE_LOG"
run 'claude_generate "you are wrong. stop arguing with me." >/dev/null 2>&1' || true
ARGS="$(cat "$SANDBOX_CLAUDE_LOG" 2>/dev/null)"
check "the dispute model takes the turn" contains "$ARGS" "--model fable"
check "at dispute effort" contains "$ARGS" "--effort high"
check "and the frame rode along" contains "$ARGS" "HE IS PUSHING BACK"

: > "$SANDBOX_CLAUDE_LOG"
run 'claude_generate "what is on the calendar tomorrow" >/dev/null 2>&1' || true
ARGS="$(cat "$SANDBOX_CLAUDE_LOG" 2>/dev/null)"
check "an ordinary turn keeps the loop model" contains "$ARGS" "--model opus"
check "at the loop effort" contains "$ARGS" "--effort low"
refute "and carries no frame" contains "$ARGS" "HE IS PUSHING BACK"
