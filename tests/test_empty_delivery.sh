#!/usr/bin/env bash
# An empty turn never reaches him on any device — and the quiet marker is
# honoured by every path, the live voices included.
#
# specs/turn-pipeline.md rule 16b and specs/speech-output.md rule 57. Until
# these rules existed the wake path was the only one that knew either: a desk
# reply opening "(quiet)" was streamed to the speakers marker-first, a phone
# turn synthesised the held thought into a clip, and a marker-only reply
# reached his chat as a bare "(quiet)" bubble.
#
#    1. a plain desk reply delivers — the control every mute case leans on
#    2. a genuinely empty desk reply reaches no sink and is journalled as the
#       failure it is
#    3. a marker-only desk reply is the same empty: no bubble, no voice, no
#       window, the no-reply journal line
#    4. a "(quiet) thought" desk reply is a bubble: in the conversation,
#       never on the speakers, and the never-silent guarantee stays quiet
#    5. the square-bracket spelling reaches the conversation normalised
#    6. a marker-only phone reply is answered through the error field, and
#       nothing of it enters the conversation
#    7. a "(quiet) thought" phone reply completes with the bubble form as its
#       spoken text, no clip, no error — and the thought is never synthesised
#    8. a plain phone reply still completes exactly as before
#
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
SESSLOG="${DESKCRAB_STATE_PREFIX}-sessions.log"

stub_reply() {  # <reply text; empty = a result event and nothing else>
    sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
python3 - <<'PYEOF'
import json
text = """$1"""
if text:
    print(json.dumps({"type": "assistant",
                      "message": {"model": "stub",
                                  "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result"}))
PYEOF
EOF
}

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
LAST_ORIGIN_FILE="$WORK/last-origin"
WAKE_QUIET_HOURS=""
PIPER_VOICE="$WORK/voice.onnx"
EOF

seed_convo() {
    printf 'User [12:00]: how did that go\nAssistant [12:01]: It went fine.\n\n' > "$CONVO"
}

reset_witnesses() {
    : > "$SANDBOX_SPOKEN_LOG"; : > "$SANDBOX_NOTIFY_LOG"; : > "$SANDBOX_DISPLAY_LOG"
    : > "$SESSLOG"
    rm -f "${DESKCRAB_STATE_PREFIX}"-display-*.md 2>/dev/null
    seed_convo
}

desk() { "$REPO/crab" "$1" >/dev/null 2>&1 || true; }

echo "a plain desk reply delivers — the control:"
reset_witnesses
stub_reply "The kettle has finished boiling."
desk "is the kettle done"
check "the reply is in the conversation" grep -qF "kettle has finished boiling" "$CONVO"
check "and it reached the speakers" grep -qF "kettle has finished boiling" "$SANDBOX_SPOKEN_LOG"
check "and the journal calls it a delivery" grep -q "replied: The kettle has finished boiling" "$SESSLOG"

echo
echo "a genuinely empty desk reply reaches no sink:"
reset_witnesses
stub_reply ""
desk "say nothing then"
check "no assistant block joined the conversation" \
    bash -c '! grep -qE "^Assistant \[.*\]: .*say" "$1" && [ "$(grep -c "^Assistant" "$1")" = 1 ]' _ "$CONVO"
check "nothing reached the speakers" [ ! -s "$SANDBOX_SPOKEN_LOG" ]
check "the journal reports the failure" grep -q "no reply — the model produced nothing to deliver" "$SESSLOG"
check "and a notification carried it" grep -q "nothing to deliver" "$SANDBOX_NOTIFY_LOG"

echo
echo "a marker-only desk reply is the same empty — no bubble, no voice, no window:"
reset_witnesses
stub_reply "(quiet)"
desk "anything on your mind"
check "no bare (quiet) bubble entered the conversation" \
    bash -c '! grep -qi "quiet" "$1"' _ "$CONVO"
check "the marker never reached the speakers" \
    bash -c '! grep -qi "quiet" "$1"' _ "$SANDBOX_SPOKEN_LOG"
check "no display window was opened" \
    bash -c 'ls "${DESKCRAB_STATE_PREFIX}"-display-*.md >/dev/null 2>&1 && exit 1 || exit 0'
check "and the journal reports it as the no-reply failure" \
    grep -q "no reply — the model produced nothing to deliver" "$SESSLOG"

echo
echo "a (quiet) thought at the desk is a bubble, never a voice:"
reset_witnesses
stub_reply "(quiet) the east shelf wants re-ordering"
desk "anything on your mind"
check "the bubble is in the conversation" grep -qF "(quiet) the east shelf wants re-ordering" "$CONVO"
check "the thought never reached the speakers — rule 57's live hold" \
    bash -c '! grep -qF "east shelf" "$1"' _ "$SANDBOX_SPOKEN_LOG"
check "the marker never reached the speakers either" \
    bash -c '! grep -qi "quiet" "$1"' _ "$SANDBOX_SPOKEN_LOG"
check "and the never-silent guarantee stayed quiet — a held thought is not a broken speech path" \
    bash -c '! grep -q "speech path failed" "$1"' _ "$SANDBOX_NOTIFY_LOG"
check "the journal shows the bubble as what he received" \
    grep -qF "replied: (quiet) the east shelf wants re-ordering" "$SESSLOG"

echo
echo "the square-bracket spelling is normalised on its way to the chat:"
reset_witnesses
stub_reply "[quiet] the ledger needs a fresh page"
desk "anything else"
check "the bubble arrives in the parenthesis spelling" \
    grep -qF "(quiet) the ledger needs a fresh page" "$CONVO"
check "and the bracket spelling reaches him nowhere" \
    bash -c '! grep -qF "[quiet]" "$1"' _ "$CONVO"

echo
echo "a marker-only phone reply is an error, not a bubble:"
reset_witnesses
stub_reply "(quiet)"
OUT="$("$REPO/crab" remote "anything on your mind" 2>/dev/null)" || true
check "the payload answers through the error field" \
    bash -c 'printf "%s" "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"error\"] else 1)"' _ "$OUT"
check "with the no-reply wording" contains "$OUT" "nothing to deliver"
check "and nothing of it entered the conversation" \
    bash -c '! grep -qi "quiet" "$1"' _ "$CONVO"

echo
echo "a (quiet) thought on the phone is the bubble form, unsynthesised:"
reset_witnesses
stub_reply "(quiet) the backup finished while you were out"
OUT="$("$REPO/crab" remote "anything to report" 2>/dev/null)" || true
PAYLOAD_SPOKEN="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["spoken"])' 2>/dev/null)"
PAYLOAD_ERROR="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"])' 2>/dev/null)"
PAYLOAD_AUDIO="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["audio"])' 2>/dev/null)"
check_eq "the completion's spoken text is the bubble form" \
    "$PAYLOAD_SPOKEN" "(quiet) the backup finished while you were out"
check_eq "with no error — the missing clip is the choice working" "$PAYLOAD_ERROR" ""
check_eq "and no audio pointer" "$PAYLOAD_AUDIO" ""
check "the thought was never synthesised" \
    bash -c '! grep -qF "backup finished" "$1"' _ "$SANDBOX_SPOKEN_LOG"
check "and the bubble is in the conversation" \
    grep -qF "(quiet) the backup finished while you were out" "$CONVO"

echo
echo "a plain phone reply still completes exactly as before:"
reset_witnesses
stub_reply "The disk has plenty of room left."
OUT="$("$REPO/crab" remote "how is the disk" 2>/dev/null)" || true
PAYLOAD_SPOKEN="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["spoken"])' 2>/dev/null)"
PAYLOAD_ERROR="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"])' 2>/dev/null)"
check_eq "the payload carries the spoken text" "$PAYLOAD_SPOKEN" "The disk has plenty of room left."
check_eq "with no error" "$PAYLOAD_ERROR" ""
check "and the reply is in the conversation" grep -qF "plenty of room left" "$CONVO"
check "and the synthesiser was handed the words" grep -qF "plenty of room left" "$SANDBOX_SPOKEN_LOG"

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
