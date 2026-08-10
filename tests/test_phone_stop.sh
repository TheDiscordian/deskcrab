#!/bin/bash
# The brake, and the reach — specs/phone.md rules 47-50.
# Run: bash tests/test_phone_stop.sh
#
# Reported by the user 2026-08-10: with a turn in flight the phone could not
# send and could not stop — the server had no stop route at all, and a new
# message parked behind the remote lock's ten-minute wait. If she started a
# long or destructive task, he was stuck waiting with no way to intervene.
#
# So: a real serve.py, a real socket, and a stub `crab` that takes the REAL
# remote lock, exactly as run_claude_remote does. The slow arm writes its pid
# and sleeps for minutes holding the lock; its one text block sends the
# server's Speaker into a stub synth that does the same. The proof demanded
# here is observation, not status codes: the pids must actually be GONE after
# the stop, the stopped turn must end in exactly one done marked stopped, a
# message posted mid-turn must stream at once (accepted, wait notes flowing,
# reply withheld — genuinely parked behind the held lock), and after the stop
# that parked turn's reply must arrive in seconds, which can only happen if
# the kill released the lock.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; phone_live 18723, watch_rewrite 18724, wedge
# 18725, done_after_exit 18726, queue_wait/voice_fallback 18727, media 18728,
# stream 18730/18731.
PORT=18729

# --- the stub `crab` -------------------------------------------------------
# `remote` takes the real lock at ${DESKCRAB_STATE_PREFIX}-remote.lock on fd
# 8, the same shape as run_claude_remote, so two turns genuinely serialise
# and killing the holder genuinely releases it.
cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth)
    case "$3" in
      *SLOW-BLOCK*)
        echo $$ > "${DESKCRAB_STATE_PREFIX}-stub-synth.pid"
        sleep 300
        ;;
    esac
    : > "$2"; exit 1 ;;
  remote) ;;
  *) exit 1 ;;
esac
LOG="${DESKCRAB_REMOTE_LOG:?stub: no DESKCRAB_REMOTE_LOG}"
: > "$LOG"
exec 8>"${DESKCRAB_STATE_PREFIX}-remote.lock"
flock -w 600 8 || exit 1
case "$2" in
  slow*)
    echo $$ > "${DESKCRAB_STATE_PREFIX}-stub-remote.pid"
    python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"SLOW-BLOCK"}]}}))' >> "$LOG"
    sleep 300
    echo '{"spoken":"SLOW-REPLY","display":"","audio":"","error":""}'
    ;;
  *)
    echo '{"spoken":"FAST-REPLY","display":"","audio":"","error":""}'
    ;;
esac
exit 0
STUB
chmod +x "$T/crab"

# --- the server ------------------------------------------------------------
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_SERVE_TIMEOUT=120 \
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

echo "== a long turn takes the lock, and its synthesis hangs beside it =="

SLOW="$T/slow.sse"
curl -sS -N -m 90 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"slow and destructive","turn":"aaaa01"}' \
    "http://127.0.0.1:$PORT/say" > "$SLOW" 2>/dev/null &
CURL_SLOW=$!

REMOTE_PID=""
SYNTH_PID=""
for _ in $(seq 1 150); do
    [ -s "$T/deskcrab-stub-remote.pid" ] && [ -s "$T/deskcrab-stub-synth.pid" ] && break
    sleep 0.1
done
REMOTE_PID="$(cat "$T/deskcrab-stub-remote.pid" 2>/dev/null)"
SYNTH_PID="$(cat "$T/deskcrab-stub-synth.pid" 2>/dev/null)"
if [ -n "$REMOTE_PID" ] && kill -0 "$REMOTE_PID" 2>/dev/null; then
    ok "the remote run is live and holding the lock (pid $REMOTE_PID)"
else
    fail "the remote run is live and holding the lock" \
         "pid file: [${REMOTE_PID:-none}] — $(cat "$T/server.log")"
fi
if [ -n "$SYNTH_PID" ] && kill -0 "$SYNTH_PID" 2>/dev/null; then
    ok "and a synthesis child is running beside it (pid $SYNTH_PID)"
else
    fail "and a synthesis child is running beside it" \
         "pid file: [${SYNTH_PID:-none}] — $(cat "$T/server.log")"
fi

echo "== reach: a message sent mid-turn is accepted at once, not parked in silence =="

FAST="$T/fast.sse"
curl -sS -N -m 60 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"a second message","turn":"aaaa02"}' \
    "http://127.0.0.1:$PORT/say" > "$FAST" 2>/dev/null &
CURL_FAST=$!

ACCEPTED=""
for _ in $(seq 1 80); do
    grep -q '"kind": *"wait"' "$FAST" 2>/dev/null && { ACCEPTED=1; break; }
    sleep 0.1
done
if [ -n "$ACCEPTED" ]; then
    ok "the second turn's stream is live with wait notes while the first still runs"
else
    fail "the second turn's stream is live with wait notes while the first still runs" \
         "$(cat "$FAST" 2>/dev/null | tail -c 300)"
fi
grep -q 'FAST-REPLY' "$FAST" 2>/dev/null \
    && fail "and its reply is genuinely held behind the lock" "reply arrived with the lock held" \
    || ok "and its reply is genuinely held behind the lock"

echo "== the brake: /stop kills the turn's processes and its synthesis =="

STOP_RES="$(curl -fsS -m 15 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"turn":"aaaa01"}' \
    "http://127.0.0.1:$PORT/stop" 2>/dev/null)"
echo "$STOP_RES" | grep -q '"stopped": *true' \
    && ok "/stop answers that the stop is in motion" \
    || fail "/stop answers that the stop is in motion" "$STOP_RES"

DEAD=""
for _ in $(seq 1 100); do
    if ! kill -0 "$REMOTE_PID" 2>/dev/null && ! kill -0 "$SYNTH_PID" 2>/dev/null; then
        DEAD=1; break
    fi
    sleep 0.1
done
if [ -n "$DEAD" ]; then
    ok "the remote run (pid $REMOTE_PID) and the synthesis (pid $SYNTH_PID) are GONE — observed, not inferred"
else
    fail "the remote run and the synthesis are gone" \
         "remote alive: $(kill -0 "$REMOTE_PID" 2>/dev/null && echo yes || echo no), synth alive: $(kill -0 "$SYNTH_PID" 2>/dev/null && echo yes || echo no)"
fi

wait "$CURL_SLOW" 2>/dev/null
grep -q '"kind": *"done"' "$SLOW" \
    && ok "the stopped turn still ends in a completion event" \
    || fail "the stopped turn still ends in a completion event" "$(tail -c 300 "$SLOW")"
grep -q '"stopped": *true' "$SLOW" \
    && ok "and it is marked stopped, a chosen end rather than a failure" \
    || fail "and it is marked stopped" "$(grep '"kind": *"done"' "$SLOW")"
DONES=$(grep -c '"kind": *"done"' "$SLOW" || true)
[ "${DONES:-0}" -eq 1 ] \
    && ok "exactly one completion event, as rule 6 demands" \
    || fail "exactly one completion event" "$DONES done events"

echo "== the lock is released: the parked turn runs at once =="

wait "$CURL_FAST" 2>/dev/null
grep -q 'FAST-REPLY' "$FAST" \
    && ok "the second turn's reply arrived — in seconds, not at the lock's ten-minute bound" \
    || fail "the second turn's reply arrived after the stop" "$(tail -c 300 "$FAST")"

echo "== edges: unknown turns, missing keys, and a turn already done =="

CODE="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"turn":"ffff99"}' "http://127.0.0.1:$PORT/stop" 2>/dev/null)"
[ "$CODE" = "404" ] \
    && ok "an unknown turn is a 404, not a guess" \
    || fail "an unknown turn is a 404" "HTTP $CODE"

CODE="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
    -H "Content-Type: application/json" \
    --data '{"turn":"aaaa02"}' "http://127.0.0.1:$PORT/stop" 2>/dev/null)"
[ "$CODE" = "404" ] \
    && ok "no key, no stop — the route is authenticated like every other" \
    || fail "no key, no stop" "HTTP $CODE"

DONE_RES="$(curl -fsS -m 10 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"turn":"aaaa02"}' "http://127.0.0.1:$PORT/stop" 2>/dev/null)"
echo "$DONE_RES" | grep -q '"done": *true' \
    && ok "stopping a turn already done is a truthful no-op" \
    || fail "stopping a turn already done is a truthful no-op" "$DONE_RES"

curl -fsS -m 5 "http://127.0.0.1:$PORT/health?k=$SECRET" | grep -q '"ok": *true' \
    && ok "and the server is still standing" \
    || fail "and the server is still standing" "$(tail -c 300 "$T/server.log")"
