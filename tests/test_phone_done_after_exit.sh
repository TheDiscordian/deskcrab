#!/bin/bash
# The done event must follow the TURN'S EXIT, never the pipe's EOF.
# Run: bash tests/test_phone_done_after_exit.sh
#
# The sibling test (test_phone_wedge.sh) proves a turn that never returns is
# killed whole and reported at the timeout. This one proves the other half of
# specs/phone.md rule 6, the half that loses a GOOD reply: `crab remote` exits
# zero with its JSON already printed, but some descendant it forked still holds
# the stdout write end — the shape a single unredirected `child &` anywhere in
# the turn produces. A runner that waits for EOF on the pipe (communicate does;
# it cannot help it) sits out the whole turn timeout on a turn that has already
# succeeded, and then hands the client "timed out" IN PLACE OF the reply that
# has been sitting in the buffer the entire wait. From the phone that is:
# Beatrice audibly finishes speaking (the voice events streamed fine), then
# "thinking…" until the timeout, then an error bubble for a turn that worked.
#
# So: a real serve.py, a real socket, and a stub `crab` that answers instantly
# and leaves one stdout-holding straggler behind. The done event must arrive on
# the turn's own exit — promptly, once, carrying the reply and no error.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; phone_live 18723, watch_rewrite 18724, wedge 18725.
PORT=18726

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
python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"thinking","thinking":"EXIT-THINKING-CANARY"}]}}))' >> "$LOG"
# The reply, printed and complete before the straggler is even forked.
echo '{"spoken":"HELLO-FROM-THE-TURN","display":"","audio":"","error":""}'
# One leaked descendant holding stdout — unredirected, as every leak is —
# outliving both the turn and the server's timeout. The turn still exits 0
# on the next line; only the PIPE stays open.
sleep 300 &
exit 0
STUB
chmod +x "$T/crab"

# --- the server, with a 6-second turn timeout ------------------------------
#
# Long enough that "the done arrived promptly" and "the done arrived at the
# timeout" are different numbers; short enough that the pre-fix behaviour is
# seen inside the curl bound rather than guessed at.
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_SERVE_TIMEOUT=6 \
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

echo "== a turn that exited leaves its done event, whoever still holds the pipe =="

SSE="$T/sse.txt"
START=$(date +%s)
curl -sS -N -m 30 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"hello","turn":"cafeface"}' \
    "http://127.0.0.1:$PORT/say" > "$SSE" 2>"$T/curl.err"
TOOK=$(( $(date +%s) - START ))

grep -qF 'EXIT-THINKING-CANARY' "$SSE" \
    && ok "the turn demonstrably started (progress reached the stream)" \
    || fail "the turn demonstrably started (progress reached the stream)" \
            "no thinking event in the SSE stream"

grep -q '"kind": *"done"' "$SSE" \
    && ok "a done event arrived" \
    || fail "a done event arrived" \
            "no done in ${TOOK}s of stream — the client would sit at thinking… forever"

DONE_LINE=$(grep '"kind": *"done"' "$SSE" | head -n1)
case "$DONE_LINE" in
  *HELLO-FROM-THE-TURN*)
    ok "and it carries the reply the turn actually produced" ;;
  *)
    fail "and it carries the reply the turn actually produced" \
         "done event: ${DONE_LINE:-none}" ;;
esac
case "$DONE_LINE" in
  *'"error": ""'*)
    ok "with no error — a turn that succeeded is not reported as anything else" ;;
  *)
    fail "with no error — a turn that succeeded is not reported as anything else" \
         "done event: ${DONE_LINE:-none}" ;;
esac

# The turn answered in well under a second; 4 s is generosity for a loaded
# box. AT the 6 s timeout means the runner sat out the wait on the orphan's
# pipe and only the timeout freed it — the ten-minute stall, miniaturised.
if [ "$TOOK" -lt 4 ]; then
    ok "and it arrived on the turn's exit (${TOOK}s), not at the timeout"
else
    fail "and it arrived on the turn's exit (${TOOK}s), not at the timeout" \
         "took ${TOOK}s of a 6s timeout; the wait is on the pipe again, and a real turn pays the full ten minutes"
fi

COUNT=$(grep -c '"kind": *"done"' "$SSE")
check_eq "exactly one completion event" "$COUNT" "1"
