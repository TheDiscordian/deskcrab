#!/bin/bash
# The dispute turn — specs/cocoon.md rules 6-10, prompt-assembly.md rule 36b.
# Run: bash tests/test_dispute.sh
#
# The detector is judged on the sentences that were actually said on
# 2026-08-10, on the benign kin the first cut tripped over, and — this is the
# part that regressed once — on a PRODUCTION-SHAPED transcript: both turn
# paths run convo_append_user before claude_generate, so when the detector
# looks, his message is the last block and her reply sits above it. The first
# cut guarded on her reply being the final block and therefore fired on no
# production turn, ever. The escalation is judged where it lands: in the argv
# the stub CLI was invoked with.
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
supersedes() {  # <desc> <message>
    run "dispute_detect \"\$(cat <<'MSG'
$2
MSG
)\" && [ -n \"\$DISPUTE_SUPERSEDES\" ]" >/dev/null 2>&1 && ok "$1" || fail "$1"
}
holds_fire() {  # <desc> <message> — fires the dispute but supersedes nothing
    run "dispute_detect \"\$(cat <<'MSG'
$2
MSG
)\" && [ -z \"\$DISPUTE_SUPERSEDES\" ]" >/dev/null 2>&1 && ok "$1" || fail "$1"
}

echo "before she has said anything there is nothing to dispute:"
rm -f "$CONVO"
passes "even 'you are wrong' opens no dispute on an empty record" "you are wrong"

# The PRODUCTION shape: her reply exists, and his newest message has already
# been appended below it, exactly as convo_append_user leaves the transcript
# by the time claude_generate runs the detector. Every case below is judged
# against this shape — a detector that needs her reply to be the last block
# scores zero from here on.
printf 'User [12:00]: how goes it\nAssistant [12:00]: an answer he may yet reject\nUser [12:01]: his newest message, already appended\n' > "$CONVO"

echo
echo "the guard is ordering-independent — her reply is NOT the last block here:"
detects "pushback fires on the production-shaped transcript" "you are wrong"

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
echo "the quiet corrections the first cut missed:"
detects "that's not the bug" "that's not the bug"
detects "that is not right" "that is not right"
detects "I didn't ask for a fix" "I didn't ask for a fix, I asked what happened"
detects "you didn't answer my question" "you didn't answer my question"
detects "I didn't say that" "I didn't say that"
detects "you misunderstood" "you misunderstood"
detects "you're not listening" "you're not listening"
detects "he locates the bug himself" \
    "it was in a quiet block. nothing to do with the speech gate"
detects "a bare no. plus a restatement" "no. the ticket was about the logs"
detects "a correction phrased as a question" \
    "why did you rewrite the config when I asked for a diagnosis?"

echo
echo "benign kin do not:"
passes "a plain question" "How's your chess setup going?"
passes "a no of agreement" "no worries, that sounds right"
passes "a repeat request" "play the opening again"
passes "a benign retelling" "I said yes to the meeting invite"
passes "praise with colour" "that was fucking great"
passes "a bare repeat is not an ultimatum" "one more time"
passes "run it one more time" "run it one more time"
passes "an invitation to listen" "listen to me play this"
passes "a report of success" "I'm reporting that it works"
passes "lone profanity" "fuck"

echo
echo "only STRONG closes a turn in flight (rule 6b):"
supersedes "a direct contradiction supersedes" "you are wrong. stop arguing with me."
supersedes "the misquotation supersedes" "I never said that"
holds_fire "a bare no. fires the frame but kills nothing" \
    "no. the ticket was about the logs"
holds_fire "two weak signals fire the frame but kill nothing" \
    "no way, that reads wrong to me"
# And the queue asks the detector through its own door.
check "the queue's pushback question requires STRONG" \
    run '_turn_order_is_pushback "you are wrong. stop arguing with me."'
refute "and a soft signal does not supersede through it" \
    run '_turn_order_is_pushback "no. the ticket was about the logs"'

echo
echo "the layer joins a flagged turn and no other:"
D="$XDG_DATA_HOME/deskcrab"; mkdir -p "$D"
printf '# Wants\n- **a want**\n' > "$D/wants.md"
TURN="$(run 'PROMPT_DISPUTE=1 build_system_prompt --profile turn')"
check "a flagged turn carries the dispute frame" \
    contains "$TURN" "HE IS PUSHING BACK"
check "and the frame kills the rejected theory" \
    contains "$TURN" "DEAD"
check "the frame names the observable register, not a mood" \
    contains "$TURN" "claudism list"
check "and points at the pre-speech mirror" \
    contains "$TURN" "pre-speech mirror"
refute "no regroup in the prompt, no reconciliation sentence (rule 8a)" \
    contains "$TURN" "The regroup block above"
state="$(run 'PROMPT_DISPUTE=1 build_system_prompt --profile turn --layers' \
         | awk -F'\t' '$1 == "dispute" { print $4 }')"
check_eq "the manifest carries it inside its budget" "$state" "full"
refute "an unflagged turn does not" \
    contains "$(run 'build_system_prompt --profile turn')" "HE IS PUSHING BACK"
refute "a wake never does — no message to be pushed back on" \
    contains "$(run 'PROMPT_DISPUTE=1 build_system_prompt --profile wake')" "HE IS PUSHING BACK"

echo
echo "when regroup fires too, dispute reconciles the two (rule 8a):"
BOTH="$(run 'REGROUP_CONTEXT="ANOTHER OF YOU IS SPEAKING RIGHT NOW - stub regroup block" PROMPT_DISPUTE=1 build_system_prompt --profile turn')"
check "the reconciliation sentence rides along" \
    contains "$BOTH" "The regroup block above told you to fold in"
check "and the dead theory stays dead across sessions" \
    contains "$BOTH" "dead theory is not carried forward"
state="$(run 'REGROUP_CONTEXT="ANOTHER OF YOU IS SPEAKING RIGHT NOW - stub regroup block" PROMPT_DISPUTE=1 build_system_prompt --profile turn --layers' \
         | awk -F'\t' '$1 == "dispute" { print $4 }')"
check_eq "and the larger frame still fits its budget" "$state" "full"

echo
echo "a dispute turn is bought at strength — in the argv the CLI actually got,"
echo "through the production pipeline (his message appended before generation):"
: > "$SANDBOX_CLAUDE_LOG"
run 'convo_append_user "you are wrong. stop arguing with me."; claude_generate "you are wrong. stop arguing with me." >/dev/null 2>&1' || true
ARGS="$(cat "$SANDBOX_CLAUDE_LOG" 2>/dev/null)"
check "the dispute model takes the turn" contains "$ARGS" "--model fable"
check "at dispute effort" contains "$ARGS" "--effort high"
check "and the frame rode along" contains "$ARGS" "HE IS PUSHING BACK"

: > "$SANDBOX_CLAUDE_LOG"
run 'convo_append_user "what is on the calendar tomorrow"; claude_generate "what is on the calendar tomorrow" >/dev/null 2>&1' || true
ARGS="$(cat "$SANDBOX_CLAUDE_LOG" 2>/dev/null)"
check "an ordinary turn keeps the loop model" contains "$ARGS" "--model opus"
check "at the loop effort" contains "$ARGS" "--effort low"
refute "and carries no frame" contains "$ARGS" "HE IS PUSHING BACK"
