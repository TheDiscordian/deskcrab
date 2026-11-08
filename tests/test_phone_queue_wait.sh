#!/bin/bash
# A queued turn is never dead air — specs/phone.md rule 43.
# Run: bash tests/test_phone_queue_wait.sh
#
# The stall of 2026-08-09: a message posted at 00:19:55 waited 203 s behind a
# four-minute turn, and for all of it NOTHING reached the turn buffer — the
# tail carried keepalives, the phone sat frozen on "picking the turn back
# up…", and the page was hand reloaded four times. The fix is the queue
# watcher: until the run shows its first real sign of life, the server emits
# wait events saying what the wait is.
#
# So: a real serve.py, a real socket, and a stub `crab` whose slow arm holds
# its tongue for a few seconds before producing anything — exactly the shape
# of a runner parked on the remote lock. The wait notes must arrive while it
# is parked, name the kind of wait, stop once real output flows, and never
# follow the done. A fast turn must never see one.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; phone_live 18723, watch_rewrite 18724, wedge
# 18725, done_after_exit 18726.
PORT=18727

# --- the stub `crab` -------------------------------------------------------
cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth) : > "$2"; exit 1 ;;   # non-zero: voice events are not the subject
  remote) ;;
  *) exit 1 ;;
esac
LOG="${DESKCRAB_REMOTE_LOG:?stub: no DESKCRAB_REMOTE_LOG}"
: > "$LOG"
case "$2" in
  fast*)
    # Answers at once: the queue watcher must never get a word in.
    echo '{"spoken":"FAST-REPLY","display":"","audio":"","error":""}'
    ;;
  *)
    # Parked: four silent seconds before the first sign of life, as a runner
    # waiting on the remote lock is silent.
    sleep 4
    python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"thinking","thinking":"QUEUE-THINKING-CANARY"}]}}))' >> "$LOG"
    sleep 1
    echo '{"spoken":"SLOW-REPLY","display":"","audio":"","error":""}'
    ;;
esac
exit 0
STUB
chmod +x "$T/crab"

# --- the server, wait notes on a one-second cadence ------------------------
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_SERVE_QUEUE_NOTE_AFTER=1 \
DESKCRAB_SERVE_QUEUE_NOTE_EVERY=1 \
DESKCRAB_CRAB_BIN="$T/crab" \
DESKCRAB_STATE_PREFIX="$T/deskcrab" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 \
    || die "the server never came up" "$(cat "$T/server.log")"

echo "== a fast turn never hears from the queue watcher =="

FAST="$T/fast.txt"
curl -sS -N -m 15 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"fast hello","turn":"beef01"}' \
    "http://127.0.0.1:$PORT/say" > "$FAST" 2>/dev/null

grep -q '"kind": *"done"' "$FAST" \
    && ok "the fast turn completed" \
    || fail "the fast turn completed" "$(cat "$FAST")"
grep -q '"kind": *"wait"' "$FAST" \
    && fail "a turn that starts promptly carries no wait notes" \
            "$(grep '"kind": *"wait"' "$FAST")" \
    || ok "a turn that starts promptly carries no wait notes"

echo "== a parked turn says it is in line, until real output flows =="

SLOW1="$T/slow1.txt"
SLOW2="$T/slow2.txt"
curl -sS -N -m 20 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"slow one","turn":"beef02"}' \
    "http://127.0.0.1:$PORT/say" > "$SLOW1" 2>/dev/null &
CURL1=$!
sleep 1
# A second message posted while the first is still undone: its wait must name
# the previous message, not a vague something.
curl -sS -N -m 20 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"slow two","turn":"beef03"}' \
    "http://127.0.0.1:$PORT/say" > "$SLOW2" 2>/dev/null &
CURL2=$!
wait "$CURL1" "$CURL2"

WAITS=$(grep -c '"kind": *"wait"' "$SLOW1" || true)
[ "${WAITS:-0}" -ge 2 ] \
    && ok "the parked turn's stream carried wait notes ($WAITS of them)" \
    || fail "the parked turn's stream carried wait notes" \
            "$WAITS wait event(s) in $(wc -l < "$SLOW1") lines"

grep -q '"kind": *"wait".*in line' "$SLOW1" \
    && ok "and they say what the wait is" \
    || fail "and they say what the wait is" "$(grep '"kind": *"wait"' "$SLOW1" | head -n1)"

FIRST_WAIT=$(grep -n '"kind": *"wait"' "$SLOW1" | head -n1 | cut -d: -f1)
CANARY=$(grep -n 'QUEUE-THINKING-CANARY' "$SLOW1" | head -n1 | cut -d: -f1)
if [ -n "$FIRST_WAIT" ] && [ -n "$CANARY" ] && [ "$FIRST_WAIT" -lt "$CANARY" ]; then
    ok "the notes arrived while the turn was parked, before its first thought"
else
    fail "the notes arrived while the turn was parked, before its first thought" \
         "first wait at line ${FIRST_WAIT:-none}, thinking at line ${CANARY:-none}"
fi

DONE_LINE=$(grep -n '"kind": *"done"' "$SLOW1" | head -n1 | cut -d: -f1)
LAST_WAIT=$(grep -n '"kind": *"wait"' "$SLOW1" | tail -n1 | cut -d: -f1)
if [ -n "$DONE_LINE" ] && [ "${LAST_WAIT:-0}" -lt "$DONE_LINE" ]; then
    ok "no wait note follows the done event"
else
    fail "no wait note follows the done event" \
         "done at line ${DONE_LINE:-none}, last wait at line ${LAST_WAIT:-none}"
fi

grep -q '"kind": *"wait".*previous message' "$SLOW2" \
    && ok "a turn behind another message says so, by name" \
    || fail "a turn behind another message says so, by name" \
            "$(grep '"kind": *"wait"' "$SLOW2" | head -n2)"

grep -q 'SLOW-REPLY' "$SLOW1" && grep -q 'SLOW-REPLY' "$SLOW2" \
    && ok "and both replies still arrived intact" \
    || fail "and both replies still arrived intact" \
            "slow1: $(tail -c 200 "$SLOW1") slow2: $(tail -c 200 "$SLOW2")"
