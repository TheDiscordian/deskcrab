#!/bin/bash
# After-delivery action claims — specs/turn-pipeline.md rules 32a-32aa.
# Run: bash tests/test_claim_guard.sh
#
# The provider stream is Beatrice's voice. The action checker receives a
# snapshot after delivery and may start urgent corrective work, but it never
# holds, rewrites, or impersonates the reply. These tests are source-level and
# pattern-level only; they never synthesize audio or contact a model.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
COMMON="$REPO/lib/common.sh"

echo "the action checker is an audit, not a speech gate:"
check_eq "the synchronous claim rewrite function is gone" \
    "$(grep -c '^claim_guard_response()' "$COMMON" || true)" "0"
check_eq "the private verified-only TTS path is gone" \
    "$(grep -c '^start_verified_tts_streamer()' "$COMMON" || true)" "0"
check_eq "the robotic verification refusal cannot become Beatrice's reply" \
    "$(grep -R -cF 'That action has not been verified, so I cannot truthfully say it happened.' \
        "$REPO/lib" | awk -F: '{n += $NF} END {print n + 0}')" "0"

DESK_FN="$(sed -n '/^run_claude_and_respond()/,/^}/p' "$COMMON")"
START_LINE="$(grep -n '^[[:space:]]*start_tts_streamer$' <<< "$DESK_FN" | head -1 | cut -d: -f1)"
GENERATE_LINE="$(grep -n 'RESPONSE=$(claude_generate ' <<< "$DESK_FN" | head -1 | cut -d: -f1)"
if [ -n "$START_LINE" ] && [ -n "$GENERATE_LINE" ] \
        && [ "$START_LINE" -lt "$GENERATE_LINE" ]; then
    ok "the desktop streamer starts before Sol generation"
else
    fail "speech must be listening before the first provider delta" \
        "start=${START_LINE:-missing} generate=${GENERATE_LINE:-missing}"
fi

DELIVERY_LINE="$(grep -n 'convo_append_assistant "\$RESPONSE"' <<< "$DESK_FN" | head -1 | cut -d: -f1)"
CHECK_LINE="$(grep -n 'fire_promise_check desktop "\$RESPONSE"' <<< "$DESK_FN" | head -1 | cut -d: -f1)"
if [ -n "$DELIVERY_LINE" ] && [ -n "$CHECK_LINE" ] \
        && [ "$DELIVERY_LINE" -lt "$CHECK_LINE" ]; then
    ok "the action checker runs only after the reply is delivered"
else
    fail "the checker crossed back into delivery" \
        "delivery=${DELIVERY_LINE:-missing} checker=${CHECK_LINE:-missing}"
fi

echo
echo "the cheap candidate scan still catches the short action claims:"
sandbox_bash 'promise_precheck "Ignored. Go on."' \
    && ok "bare Ignored reaches the after-delivery audit" \
    || fail "bare Ignored must still be audited" "promise_precheck returned false"
sandbox_bash 'promise_precheck "Cancelled."' \
    && ok "bare Cancelled reaches the after-delivery audit" \
    || fail "bare Cancelled must still be audited" "promise_precheck returned false"
sandbox_bash 'promise_precheck "The viewer is lovely."' \
    && fail "ordinary conversation should not pay for an action audit" "unexpected match" \
    || ok "a claim-free reply costs no checker model call"
