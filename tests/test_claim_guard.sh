#!/bin/bash
# Pre-delivery action claims — specs/turn-pipeline.md rules 32a-32aa.
# Run: bash tests/test_claim_guard.sh
#
# The candidate reply is never a delivery. Unsupported action claims return
# to a tool-capable pass, which performs or dispatches the authorised work and
# writes a replacement. The replacement is checked against the combined tool
# record. These tests stub both model roles and never synthesize audio.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
CHECKER="$T/claim-checker"

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAIM_GUARD=1
CLAIM_GUARD_REPAIRS=2
CONF

# Exit 3 is an unsupported claim, exit 0 is a supported one. A repair that
# dispatched work is supported only when the stream snapshot proves the call.
cat > "$CHECKER" <<'STUB'
#!/bin/bash
printf '%s\n' "$7" >> "$CHECK_CALLS"
printf '%s\n' "${8:-}" >> "$REQUEST_CALLS"
response="${7:-}"
snapshot="${5:-}"
if printf '%s' "$response" | grep -q 'job 123 is running' \
        && grep -q 'TOOL-CALL-CANARY' "$snapshot" 2>/dev/null; then
    echo 'KEPT: dispatched the builder | Bash: crab job'
    exit 0
fi
if printf '%s' "$response" | grep -q 'No builder was dispatched'; then
    echo NONE
    exit 0
fi
echo 'UNKEPT: "I took you up on it immediately" | the turn ran no tools'
exit 3
STUB
chmod +x "$CHECKER"

ORIGINAL="Yes—I took you up on it immediately. I’m wiring responsive portraits and expression states into both the chess and RuneScape viewers; I’m testing the rendered pages now."

echo "== an authorised claim is made true before delivery =="
: > "$T/debug.jsonl"
: > "$T/check-calls"
: > "$T/request-calls"
: > "$T/repair-calls"
: > "$T/repair-prompt"
printf '%s' "$ORIGINAL" > "$T/candidate"
export CHECK_CALLS="$T/check-calls" CLAIM_TEST_ROOT="$T" \
    REQUEST_CALLS="$T/request-calls" PROMISE_CHECK_BIN="$CHECKER"
OUT="$(sandbox_bash '
        DEBUGLOG="$CLAIM_TEST_ROOT/debug.jsonl"
        CLAIM_GUARD_REPAIRS=2
        claude_generate() {
            printf "%s\n" repair >> "$CLAIM_TEST_ROOT/repair-calls"
            printf "%s" "$1" > "$CLAIM_TEST_ROOT/repair-prompt"
            : > "$DEBUGLOG"
            printf "%s\n" "{\"type\":\"assistant\",\"message\":{\"model\":\"sol\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"crab job TOOL-CALL-CANARY\"}}]}}" >> "$DEBUGLOG"
            printf "%s\n" "I dispatched a Fable builder for both viewers; job 123 is running."
        }
        claim_guard_response phone "put portraits into both viewers" "$(cat "$CLAIM_TEST_ROOT/candidate")" sol low
    ')"
check_eq "the unsupported draft was replaced" \
    "$OUT" "I dispatched a Fable builder for both viewers; job 123 is running."
check_eq "the tool-capable pass ran once" \
    "$(wc -l < "$T/repair-calls")" "1"
check_eq "the replacement was inspected after the draft" \
    "$(wc -l < "$T/check-calls")" "2"
check_eq "the user's request reaches both inspections" \
    "$(sort -u "$T/request-calls")" "put portraits into both viewers"
check "the repair pass names the immediate wake handoff" \
    grep -qF 'crab wake-now "<specific agenda>"' "$T/repair-prompt"
check "the repair pass forbids an invented later clock" \
    grep -qF 'never invent a later clock time' "$T/repair-prompt"
check "the combined turn record proves the dispatch" \
    grep -q TOOL-CALL-CANARY "$T/debug.jsonl"
if printf '%s' "$OUT" | grep -q 'I took you up on it immediately'; then
    fail "the fabricated draft reached the result" "$OUT"
else
    ok "the fabricated draft never reached the result"
fi

echo
echo "== an honest rewrite needs no invented action =="
: > "$T/debug.jsonl"
: > "$T/check-calls"
: > "$T/repair-calls"
export CHECK_CALLS="$T/check-calls"
OUT="$(sandbox_bash '
        DEBUGLOG="$CLAIM_TEST_ROOT/debug.jsonl"
        claude_generate() {
            printf "%s\n" repair >> "$CLAIM_TEST_ROOT/repair-calls"
            : > "$DEBUGLOG"
            printf "%s\n" "No builder was dispatched, and no viewer work is running."
        }
        claim_guard_response desktop "what did you do" "$(cat "$CLAIM_TEST_ROOT/candidate")" sol low
    ')"
check_eq "the false claim becomes the plain truth" \
    "$OUT" "No builder was dispatched, and no viewer work is running."
check_eq "a claim-free truthful replacement needs one repair" \
    "$(wc -l < "$T/repair-calls")" "1"

echo
echo "== repeated unsupported wording fails closed =="
: > "$T/debug.jsonl"
: > "$T/check-calls"
: > "$T/repair-calls"
export CHECK_CALLS="$T/check-calls"
OUT="$(sandbox_bash '
        DEBUGLOG="$CLAIM_TEST_ROOT/debug.jsonl"
        CLAIM_GUARD_REPAIRS=2
        claude_generate() {
            printf "%s\n" repair >> "$CLAIM_TEST_ROOT/repair-calls"
            : > "$DEBUGLOG"
            printf "%s\n" "$(cat "$CLAIM_TEST_ROOT/candidate")"
        }
        claim_guard_response wake "put portraits into both viewers" "$(cat "$CLAIM_TEST_ROOT/candidate")" sol low
    ')"
check_eq "no unsupported second draft passes" \
    "$OUT" "That action has not been verified, so I cannot truthfully say it happened."
check_eq "the repair loop is bounded" "$(wc -l < "$T/repair-calls")" "2"
if printf '%s' "$OUT" | grep -q 'I took you up on it immediately'; then
    fail "the persistent lie reached the result" "$OUT"
else
    ok "the persistent lie never reached the result"
fi
