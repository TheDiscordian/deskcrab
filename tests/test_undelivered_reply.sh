#!/usr/bin/env bash
# Proof that a reply which existed cannot vanish without the journal saying so.
#
# specs/turn-pipeline.md rule 16a. 2026-08-10, the turn at 12:33:04: it found
# the right answer to the bug he had been reporting all morning and committed
# the fix. Its shell was killed at 12:35:35; the CLI ran on and finished
# writing that answer into the stream log ten seconds later, with nothing left
# alive to read it. The journal row for that turn reads "reply": "" and carries
# no outcome at all — the same row a turn whose model produced nothing writes.
# Three different failures wearing one record, and no way to tell afterwards
# that an answer had gone missing.
#
#    1. killed mid-generation with a finished reply in the stream log ->
#       the journal carries that reply AND says it was never delivered
#    2. killed with nothing in the log -> the journal says interrupted, and
#       never leaves an empty reply with no explanation
#    3. an ordinary delivered turn is untouched by any of it
#    4. the shape of the 2026-08-10 row — empty reply, no outcome — is
#       unreachable from a registered session
#
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -uo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

# A claude that writes its whole answer into the stream log and then hangs, so
# the test can kill the turn at exactly the moment 12:33:04 was killed at:
# the reply exists on disk, the shell has not read it yet.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do TEXT="$a"; done
case "$TEXT" in
    *NOTHING*) sleep 20; exit 0 ;;
esac
printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Your report was right and it was not the speech gate at all."}]}}\n'
sleep 20
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
LAST_ORIGIN_FILE="$WORK/last-origin"
WAKE_QUIET_HOURS=""
PIPER_VOICE="$WORK/voice.onnx"
EOF

JOURNAL="$DAY_JOURNAL_DIR/$(date +%F).jsonl"

# The day journal's rows, as questions a test can ask of them.
rows() { [ -f "$JOURNAL" ] && cat "$JOURNAL" || true; }
row_field() {  # <needle in user text> <field>
    rows | python3 -c '
import json, sys
needle, field = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if needle in (obj.get("user") or ""):
        v = obj.get(field)
        print("" if v is None else v)
        break
' "$1" "$2"
}
row_has_key() {  # <needle> <key>
    rows | python3 -c '
import json, sys
needle, key = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if needle in (obj.get("user") or ""):
        print("yes" if key in obj else "no")
        break
' "$1" "$2"
}

# --- 1: the reply existed, the turn was killed before it could be read -----
: > "$JOURNAL" 2>/dev/null || true
"$REPO/crab" "I am reporting a genuine bug and it is not the speech gate" >/dev/null 2>&1 &
TURN=$!
# Wait until the answer is in the stream log — the exact state of 12:35:35.
for _ in $(seq 100); do
    grep -q 'not the speech gate at all' "${DESKCRAB_STATE_PREFIX}"-debug-*.log 2>/dev/null && break
    sleep 0.1
done
kill -TERM "$TURN" 2>/dev/null
wait "$TURN" 2>/dev/null

REPLY="$(row_field 'reporting a genuine bug' reply)"
case "$REPLY" in
    *"not the speech gate at all"*)
        ok "the killed turn's journal row carries the reply that existed on disk" ;;
    "")
        fail "the journal row is the 2026-08-10 row: an answer existed and the record is blank" ;;
    *)
        fail "the journal row holds something other than the reply" "[$REPLY]" ;;
esac
OUT="$(row_field 'reporting a genuine bug' outcome)"
case "$OUT" in
    *undelivered*) ok "and it says plainly that it was never delivered" ;;
    *) fail "the row does not say the reply went undelivered" "[$OUT]" ;;
esac
contains "$OUT" "recovered from its own stream log" \
    && ok "the outcome names where the words came from, so the claim can be checked" \
    || fail "the outcome does not say the reply was recovered rather than heard"
# The words must not have been DELIVERED: recovering a reply is a record, never
# a late delivery, so nothing may appear in the conversation on the strength of
# it.
grep -q 'not the speech gate at all' "${DESKCRAB_STATE_PREFIX}-convo.txt" 2>/dev/null \
    && fail "the recovered reply was posted into the conversation as if delivered" \
    || ok "the recovered reply stayed a record — nothing was delivered late"
contains "$OUT" "nothing was shown or added to the conversation" \
    && ok "and the outcome claims exactly that and no more" \
    || fail "the outcome does not say what was and was not delivered"
# The speakers are a SEPARATE question, and the record must not answer it by
# guessing. The streamer speaks while the model is still writing, so a turn
# killed at the end may genuinely have said most of its reply aloud — a record
# that flatly claims otherwise is the overclaim this rule exists to prevent.
if grep -q 'not the speech gate at all' "$SANDBOX_SPOKEN_LOG" 2>/dev/null; then
    contains "$OUT" "on the speakers before the end" \
        && ok "words that DID reach the speakers are admitted in the record" \
        || fail "the record denies speech the streamer actually produced" "[$OUT]"
else
    case "$OUT" in
        *"none of it reached the speakers"*|*"not known"*)
            ok "with nothing spoken, the record says so without overclaiming" ;;
        *) fail "the record makes no honest statement about the speakers" "[$OUT]" ;;
    esac
fi

# --- 2: killed with nothing to recover -------------------------------------
"$REPO/crab" "NOTHING had time to happen here" >/dev/null 2>&1 &
TURN=$!
sleep 2
kill -TERM "$TURN" 2>/dev/null
wait "$TURN" 2>/dev/null

OUT="$(row_field 'NOTHING had time' outcome)"
case "$OUT" in
    *interrupted*) ok "a turn killed before any reply existed says interrupted, not nothing" ;;
    *) fail "a turn killed with an empty log left no explanation" "[$OUT]" ;;
esac
check_eq "and its row still carries an outcome key at all" \
    "$(row_has_key 'NOTHING had time' outcome)" "yes"

# --- 3: an ordinary turn is untouched --------------------------------------
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do TEXT="$a"; done
printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"An ordinary answer."}]}}\n'
printf '{"type":"result"}\n'
EOF
"$REPO/crab" "an ordinary question about the disk" >/dev/null 2>&1

OUT="$(row_field 'ordinary question about the disk' outcome)"
contains "$OUT" "asked:" \
    && ok "a turn that delivered normally keeps its ordinary outcome" \
    || fail "the rescue rewrote a healthy turn's outcome" "[$OUT]"
contains "$OUT" "undelivered" \
    && fail "a delivered turn was labelled undelivered" \
    || ok "and is never labelled undelivered"
check_eq "its reply is in the journal as it always was" \
    "$(row_field 'ordinary question about the disk' reply)" "An ordinary answer."

# --- 4: the 2026-08-10 row shape is unreachable ----------------------------
BAD="$(rows | python3 -c '
import json, sys
bad = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if obj.get("kind") == "job":
        continue
    if not (obj.get("reply") or "").strip() and not (obj.get("outcome") or "").strip():
        bad += 1
print(bad)
')"
check_eq "no row anywhere in the day is an empty reply with no explanation" "$BAD" "0"

PASSED=0; [ -f "$SANDBOX/witness/passes" ] && PASSED=$(wc -l < "$SANDBOX/witness/passes")
FAILED=0; [ -f "$SANDBOX/witness/failures" ] && FAILED=$(wc -l < "$SANDBOX/witness/failures")
echo "== $SANDBOX_NAME: $PASSED passed, $FAILED failed"
[ ! -s "$SANDBOX/witness/failures" ]
