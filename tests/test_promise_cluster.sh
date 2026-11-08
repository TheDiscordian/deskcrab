#!/bin/bash
# The turn-cluster fold — specs/wake-queue.md rule 10b, and rule 43a's use of
# it by the promise auditor. Run: bash tests/test_promise_cluster.sh
#
# On 2026-08-07 12:12 three timers stood pending for the same second with
# sequential ids, and it was never a loop: three turns finished inside one
# minute (a desk turn overlapping two wakes), each fired its own promise
# audit, each audit caught its own sentence, and each booked its own event
# wake nagging her to check the same shelf. Defect (a) of that entry — the
# deterministic deferral slot — was fixed by the slot search; this file holds
# defect (b): the audits themselves must coalesce per turn-cluster, three
# sentences caught in one window becoming ONE wake carrying three items,
# folded under the booking lock so three concurrent audits cannot race their
# way back to three wakes.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib"

# The auditor, copied (not linked — it resolves SCRIPT_DIR through readlink -f
# and would walk back to the real repo and its real crab), beside a door onto
# the real wake module. Same fixture as test_promise_deferred.sh.
cp "$REPO/lib/promise-audit" "$T/repo/lib/promise-audit"
chmod +x "$T/repo/lib/promise-audit"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"

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
WANTS_FILE="$T/wants.md"
MEMORY_STORE=0
PROMISE_AUDIT=1
CONF
printf '# Wants\n\n- a want already on the shelf\n' > "$T/wants.md"

export WAKES_DIR="$W"

AUDIT_LOG="$DESKCRAB_STATE_PREFIX-promise-audit.log"
WANT_PREFIX="You said this and did not write it down:"
DEF_PREFIX="You promised him and nothing was booked:"

records()  { ls "$W"/*.wake 2>/dev/null | wc -l; }
reasons()  { awk -F'\t' 'FNR == 1 { print $3 }' "$W"/*.wake 2>/dev/null; }
fires()    { awk -F'\t' 'FNR == 1 { print $1 }' "$W"/*.wake 2>/dev/null | sort -n; }
bookedats(){ awk -F'\t' 'FNR == 1 { print $4 }' "$W"/*.wake 2>/dev/null; }
reset()    { rm -f "$W"/*.wake "$W/ledger.log" "$T/wake-calls" "$AUDIT_LOG"; }

# One stub answers every audit: the verdict is picked off the exchange text
# that arrives on stdin, so three different replies get three different
# sentences — from one stub file, which is the sandbox's rule. The trigger
# phrases must appear NOWHERE in the audit's own prompt boilerplate: the
# prompt's worked examples ("sheet music", "drattit", "send the builder")
# arrive on the same stdin, and a phrase they contain would match every
# audit alike.
sandbox_stub claude <<'STUB'
#!/bin/bash
IN="$(cat)"
case "$IN" in
    *"the accordion"*)     printf 'UNSAVED: learn the accordion properly\n' ;;
    *"petrichor"*)         printf 'UNSAVED: fix the TTS mangling of petrichor\n' ;;
    *"first line"*)        printf 'UNSAVED: the debug viewer drops the first line\n' ;;
    *"bounce the server"*) printf 'DEFERRED: restart the phone server @ in 2 hours\n' ;;
    *"rotate the logs"*)   printf 'DEFERRED: rotate the logs @ UNKNOWN\n' ;;
    *"warm the cache"*)    printf 'DEFERRED: warm the cache first @ in 2 hours\n' ;;
    *) printf 'NONE\n' ;;
esac
STUB

audit() { "$T/repo/lib/promise-audit" "$1" "$2" >/dev/null 2>&1; }

echo "three sentences caught in one cluster are ONE wake carrying three items:"
reset
audit "q1" "I keep meaning to learn the accordion one day."
FIRST_FIRE="$(fires)"
FIRST_AT="$(bookedats)"
audit "q2" "My TTS mangles the word petrichor and that wants fixing."
audit "q3" "The debug viewer drops the first line of every stream."
check_eq "exactly one pending wake for the whole cluster" "$(records)" "1"
R="$(reasons)"
case "$R" in
    "$WANT_PREFIX"*) ok "the folded reason still opens with the want prefix" ;;
    *) fail "the fold must not break the class prefix" "$R" ;;
esac
check "the first caught sentence is on it" contains "$R" "learn the accordion properly"
check "the second caught sentence is on it" contains "$R" "fix the TTS mangling of petrichor"
check "the third caught sentence is on it" contains "$R" "the debug viewer drops the first line"
check_eq "the wake still fires at the first booking's moment" "$(fires)" "$FIRST_FIRE"
check_eq "and the cluster's anchor — the first booked-at — is preserved" "$(bookedats)" "$FIRST_AT"
check_eq "the fold is on the durable ledger, once per folded item" \
    "$(awk -F'\t' '$2 == "folded"' "$W/ledger.log" 2>/dev/null | wc -l)" "2"
check_eq "booked by the auditor, in its own name" \
    "$(awk -F'\t' 'FNR == 1 { print $5 }' "$W"/*.wake 2>/dev/null)" "promise-audit"

echo
echo "three concurrent audits in the same second still make exactly one wake:"
reset
audit "q1" "I keep meaning to learn the accordion one day." &
audit "q2" "My TTS mangles the word petrichor and that wants fixing." &
audit "q3" "The debug viewer drops the first line of every stream." &
wait
check_eq "one pending wake, not three — the fold ran under the booking lock" "$(records)" "1"
R="$(reasons)"
N=0
contains "$R" "learn the accordion properly" && N=$(( N + 1 ))
contains "$R" "fix the TTS mangling of petrichor" && N=$(( N + 1 ))
contains "$R" "the debug viewer drops the first line" && N=$(( N + 1 ))
check_eq "and all three sentences are on it, whatever order the lock dealt" "$N" "3"

echo
echo "three sentences spread past the window are three wakes, as they were:"
reset
export PROMISE_CLUSTER_WINDOW=1
audit "q1" "I keep meaning to learn the accordion one day."
sleep 2
audit "q2" "My TTS mangles the word petrichor and that wants fixing."
sleep 2
audit "q3" "The debug viewer drops the first line of every stream."
unset PROMISE_CLUSTER_WINDOW
check_eq "three separate wakes when the cluster has dispersed" "$(records)" "3"

echo
echo "a deferred promise folds only with one due in the same window — and never moves:"
reset
audit "d1" "Sure, I can bounce the server in a couple of hours."
TWO_HOURS_FIRE="$(fires)"
audit "d2" "I will rotate the logs at some point."
check_eq "a promise due on the twenty-minute floor books its own wake" "$(records)" "2"
audit "d3" "And I will warm the cache first, also in about two hours."
check_eq "a promise due beside the first folds instead of booking a third" "$(records)" "2"
case "$(fires)" in
    "$TWO_HOURS_FIRE"$'\n'*|*$'\n'"$TWO_HOURS_FIRE") ok "the promised fire moment was never moved by the fold" ;;
    *) fail "a fold must not trade a promised moment for tidiness" "$(fires)" ;;
esac
DR="$(reasons | grep "restart the phone server")"
check "the folded promise rides the pending wake's reason" contains "$DR" "warm the cache first"
case "$(reasons | grep "rotate the logs")" in
    *"warm the cache"*) fail "the floor wake must not have taken the fold" "$(reasons)" ;;
    *) ok "and the floor wake was left out of it" ;;
esac

echo
echo "the queue's own guards on the fold:"
reset
out="$(WAKES_DIR="$W" sandbox_bash "wake_book --by tester --cluster 300 --cluster-item 'an item' 1h event 'unprefixed thing'" 2>&1)"
case "$out" in
    *"needs its class named"*) ok "a cluster with no class prefix is refused at booking time" ;;
    *) fail "an unclassed fold would fold across every reason its booker wrote" "$out" ;;
esac
check_eq "and nothing was booked" "$(records)" "0"

# A folded item whose multibyte character straddles the item bound must land
# whole: the byte cut falls inside the em-dash and utf8_trim drops the
# fragment, so the record stays text to grep and valid UTF-8 throughout.
reset
LONG="$(printf 'x%.0s' $(seq 1 199))—tail"
WAKES_DIR="$W" sandbox_bash "wake_book --by tester --cap-prefix 'CL:' --cluster 300 --cluster-item 'first' 1h event 'CL: the first catch'" >/dev/null 2>&1
WAKES_DIR="$W" sandbox_bash "wake_book --by tester --cap-prefix 'CL:' --cluster 300 --cluster-item '$LONG' 1h event 'CL: the second catch'" >/dev/null 2>&1
check_eq "the second booking folded into the first" "$(records)" "1"
check "the folded record is still text as far as grep is concerned" \
    grep -q "Also caught" "$W"/*.wake
check "and the reason is whole UTF-8 — the straddled character was dropped, not split" \
    bash -c 'iconv -f UTF-8 -t UTF-8 "$0"/*.wake > /dev/null 2>&1' "$W"
