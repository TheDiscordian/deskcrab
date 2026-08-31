#!/bin/bash
# Tests for the phone's LIVE view of a turn in progress (lib/serve.py).
# Run: bash tests/test_phone_live.sh
#
# What he saw on 2026-08-07: the phone showed a spinner for the whole turn and
# then the finished reply in one lump — no thinking, no tool lines, no text as
# it was written. The server was healthy the entire time (NRestarts=0), so
# nothing had crashed; the live path had simply stopped carrying anything.
#
# The cause is the same one that ate replies in the debug view (see
# tests/test_debug_view.sh case 3), still living in serve.py's own tailer:
# `readline()` at EOF hands back a HALF-WRITTEN line, and the rest of that line
# arrives on the next call. Neither half is JSON, so both are dropped — and the
# lines that get split are the big ones, which are exactly the assistant blocks
# worth showing. Real stream logs on this machine carry lines up to 52 KB; a
# write that large is never one atomic thing a reader can only see whole.
#
# So these tests drive a REAL serve.py over a REAL socket with `crab` stubbed:
# the stub writes its stream-json log the way the CLI does — in pieces, with a
# line still half-written when the reader reaches it — and the test asserts the
# thinking and tool progress arrive BEFORE the done event, while assistant
# answer text remains held until the completed reply payload.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
# The exit trap belongs to the sandbox — it is what proves the run left the live
# instance alone — so the server is stopped through its hook rather than by
# installing a second one over the top.
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; the live instance sits on 8723.
PORT=18723

# --- the stub `crab` -------------------------------------------------------
#
# Stands in for `crab remote` and `crab synth`. The remote path writes a
# stream-json log exactly as claude_generate does — into $DESKCRAB_REMOTE_LOG —
# but deliberately in the shape that breaks a naive tailer: a long assistant
# line delivered in two writes with a pause between them and no newline until
# the end. HOLD_FILE lets the test hold the turn open so "before the end" is a
# claim it can actually check.
cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth) : > "$2"; exit 1 ;;   # non-zero: no voice events, they are not the subject
  remote) ;;
  *) exit 1 ;;
esac
LOG="${DESKCRAB_REMOTE_LOG:?stub: no DESKCRAB_REMOTE_LOG}"
: > "$LOG"

# A usage-limit refusal run FIRST, exactly as the fallback path leaves it: a
# synthetic assistant message holding the refusal, then that run's result —
# and the real run appended after. serve.py's tailer used to RETURN at the
# first result line, so everything below streamed to nobody: the phone showed
# a spinner for the whole real turn and then the reply in one lump. The
# refusal text itself must never reach the phone — the fallback answers for
# real right after it.
python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"LIMIT-REFUSAL-CANARY: You have hit your session limit"}]}}))' >> "$LOG"
python3 -c 'import json;print(json.dumps({"type":"result","is_error":True,"result":"session limit reached"}))' >> "$LOG"

# A thinking block, written whole — the cheap case.
python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"thinking","thinking":"LIVE-THINKING-CANARY"}]}}))' >> "$LOG"

# A tool call, whole.
python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"LIVE-TOOL-CANARY"}}]}}))' >> "$LOG"

# A long assistant text block, written in TWO pieces with the line still open
# in between — what the kernel hands a reader mid-write of a 52 KB line.
python3 - "$LOG" <<'PY'
import json, sys, time
line = json.dumps({"type": "assistant", "message": {"content": [
    {"type": "text", "text": "LIVE-TEXT-CANARY " + "padding " * 4000}]}})
cut = len(line) // 2
with open(sys.argv[1], "a") as f:
    f.write(line[:cut]); f.flush()
    time.sleep(0.6)          # the reader reaches EOF mid-line right here
    f.write(line[cut:] + "\n"); f.flush()
PY

# Hold the turn open until the test releases it: everything above must have
# reached the client already, while the turn is demonstrably still running.
while [ -e "$HOLD_FILE" ]; do sleep 0.05; done

printf '{"type":"result"}\n' >> "$LOG"
python3 -c 'import json;print(json.dumps({"spoken":"FINAL-REPLY","display":"","audio":"","error":""}))'
STUB
chmod +x "$T/crab"

# --- the server ------------------------------------------------------------
HOLD_FILE="$T/hold"
export HOLD_FILE
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_CRAB_BIN="$T/crab" \
DESKCRAB_STATE_PREFIX="$T/deskcrab" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1; then
    die "the server never came up" "$(cat "$T/server.log")"
fi

# --- one turn, tailed live -------------------------------------------------
: > "$HOLD_FILE"
SSE="$T/sse.txt"
: > "$SSE"
curl -sS -N -m 60 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"hello","turn":"abc123"}' \
    "http://127.0.0.1:$PORT/say" > "$SSE" 2>"$T/curl.err" &
CURL_PID=$!

# Wait for the progress events while the turn is STILL RUNNING. The hold file
# is the proof: it is removed only after this loop, so anything seen here was
# seen before the turn could possibly have ended.
awaits() { # <text>
    local i=0
    while [ $i -lt 300 ]; do
        grep -qF -- "$1" "$SSE" && return 0
        sleep 0.05
        i=$(( i + 1 ))
    done
    return 1
}

echo "== progress arrives while the turn is still running =="

# Everything below sits AFTER a refusal run's result line in the log; a tailer
# that stops at the first result (the pre-fix serve.py) delivers none of it.
awaits LIVE-THINKING-CANARY \
    && ok "thinking reaches the phone mid-turn" \
    || fail "thinking reaches the phone mid-turn" "never arrived before the turn ended"

awaits LIVE-TOOL-CANARY \
    && ok "tool use reaches the phone mid-turn" \
    || fail "tool use reaches the phone mid-turn" "never arrived before the turn ended"

# The answer is still only a draft. Even a complete parseable block remains
# private until crab remote returns the completed reply.
if grep -qF LIVE-TEXT-CANARY "$SSE"; then
    fail "draft answer text stays off the phone" \
         "the raw provider draft crossed the phone completion boundary"
else
    ok "draft answer text stays off the phone"
fi

# Still running? If the turn already finished, "before the end" proves nothing.
if [ -e "$HOLD_FILE" ]; then
    ok "the turn was still in flight when all of that arrived"
else
    fail "the turn was still in flight when all of that arrived" \
         "the hold file went away on its own — test is not proving liveness"
fi

if grep -q '"kind": *"done"' "$SSE"; then
    fail "no done event yet" "the turn ended before the progress assertions"
else
    ok "the done event had not been sent yet"
fi

# The turn log must live under THIS instance's STATE_PREFIX. serve.py used to
# hardcode /tmp/deskcrab-turn-<uuid>.log — the exact glob the LIVE crab-debug
# follows for phone turns — so every run of this test painted its canaries
# (thousands of "padding", a fake limit refusal) into the live debug view as
# a phone turn. Seen live 2026-08-07 16:0x. One logpath per turn: under the
# scratch prefix proves it is not under the live one.
if ls "$T"/deskcrab-turn-*.log >/dev/null 2>&1; then
    ok "the open turn's log lives under the scratch prefix, not the live viewer's glob"
else
    fail "the open turn's log lives under the scratch prefix, not the live viewer's glob" \
         "no $T/deskcrab-turn-*.log while the turn is held open"
fi

# Release the turn and let it finish.
rm -f "$HOLD_FILE"
wait "$CURL_PID" 2>/dev/null

grep -q 'FINAL-REPLY' "$SSE" \
    && ok "the finished reply still arrives" \
    || fail "the finished reply still arrives" "no done event with the reply"

# The refusal run's synthetic message must never have been relayed: the
# fallback answered for real, so the outage is not the phone's business.
if grep -q 'LIMIT-REFUSAL-CANARY' "$SSE"; then
    fail "the limit refusal is never shown to the phone" "the synthetic refusal leaked into the SSE stream"
else
    ok "the limit refusal is never shown to the phone"
fi

# The split draft block must never arrive — neither whole nor as fragments.
COUNT=$(grep -c 'LIVE-TEXT-CANARY' "$SSE")
[ "$COUNT" = 0 ] \
    && ok "the raw draft never arrived after completion either" \
    || fail "the raw draft never arrived after completion either" "saw it $COUNT times"

python3 - "$SSE" <<'PY' && ok "every SSE frame is valid JSON" \
    || fail "every SSE frame is valid JSON" "a frame did not parse"
import json, sys
bad = 0
for line in open(sys.argv[1], errors="replace"):
    if not line.startswith("data:"):
        continue
    try:
        json.loads(line[5:])
    except Exception:
        bad += 1
sys.exit(1 if bad else 0)
PY
