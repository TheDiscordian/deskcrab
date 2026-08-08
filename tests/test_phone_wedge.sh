#!/bin/bash
# The permanent "thinking…" wedge (C10's surviving half), server side.
# Run: bash tests/test_phone_wedge.sh
#
# What the phone showed: after a long turn the talk button stayed dimmed and
# the status read "thinking…" until a hand reload. The client was blameless by
# then — it was tailing a healthy socket that carried keepalive pings forever,
# because the turn it was tailing was never going to emit its done event.
#
# How the server got there: run() used subprocess.run(timeout=...), which at
# the timeout kills only the DIRECT child. `crab` is a shell script; the CLI
# it spawns inherits its stdout, and the post-kill communicate() then blocks
# until that grandchild closes the pipe. ask() never returns, run_turn never
# reaches its done emit — not even the except path, because nothing raised —
# and _stream_turn pings the tail for good. specs/phone.md rule 6: every turn
# MUST end in exactly one completion event.
#
# So this drives a REAL serve.py over a REAL socket with a stub `crab` built
# to wedge the old runner: it backgrounds a child that holds stdout open long
# past the 3-second turn timeout, and never returns itself. The test asserts
# the done event still arrives, promptly, carrying the timeout as an error.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; phone_live sits on 18723, watch_rewrite on 18724.
PORT=18725

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
# One progress event, so the test can tell the turn really started.
python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"thinking","thinking":"WEDGE-THINKING-CANARY"}]}}))' >> "$LOG"
# The exact shape that wedged the live server: a child inheriting stdout that
# outlives the turn timeout. Killing only this script leaves that pipe open,
# and a runner that then waits for EOF on it waits forever.
sleep 300 &
sleep 300
STUB
chmod +x "$T/crab"

# --- the server, with a 3-second turn timeout ------------------------------
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_SERVE_TIMEOUT=3 \
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

echo "== a turn that outlives its timeout still ends in a done event =="

SSE="$T/sse.txt"
START=$(date +%s)
# Bounded at 30 s: the pre-fix server never sends done, pings until curl dies,
# and the assertions below then say exactly that.
curl -sS -N -m 30 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"hello","turn":"feedbee"}' \
    "http://127.0.0.1:$PORT/say" > "$SSE" 2>"$T/curl.err"
TOOK=$(( $(date +%s) - START ))

grep -qF 'WEDGE-THINKING-CANARY' "$SSE" \
    && ok "the turn demonstrably started (progress reached the stream)" \
    || fail "the turn demonstrably started (progress reached the stream)" \
            "no thinking event in the SSE stream"

if grep -q '"kind": *"done"' "$SSE"; then
    ok "the done event arrived although the turn wedged past its timeout"
else
    fail "the done event arrived although the turn wedged past its timeout" \
         "no done in ${TOOK}s of stream — the client would sit at thinking… forever"
fi

DONE_LINE=$(grep '"kind": *"done"' "$SSE" | head -n1)
case "$DONE_LINE" in
  *'"error"'*'timed out'*|*'timed out'*'"error"'*)
    ok "and it carries the timeout as an error, not a silent empty reply" ;;
  *)
    fail "and it carries the timeout as an error, not a silent empty reply" \
         "done event: ${DONE_LINE:-none}" ;;
esac

# 3 s timeout plus margins; anywhere near curl's 30 s ceiling means the wait
# on the orphan's pipe is back.
if [ "$TOOK" -lt 20 ]; then
    ok "and it arrived promptly (${TOOK}s) — the process group died with the turn"
else
    fail "and it arrived promptly (${TOOK}s) — the process group died with the turn" \
         "took ${TOOK}s; communicate() is waiting on a grandchild's pipe again"
fi

COUNT=$(grep -c '"kind": *"done"' "$SSE")
check_eq "exactly one completion event" "$COUNT" "1"

# --- the second belt: an overdue doneless turn is given up on, not pinged ---
#
# run_turn always emits done now, even on the timeout path — so a doneless
# buffer can only mean a turn thread that hung or died without reporting.
# _stream_turn must answer such a tail with a failed done instead of
# keepalives forever. Driven directly: a Turn back-dated past every bound, a
# handler writing into memory.
echo "== an overdue turn with no done is answered with a failed done =="

python3 - "$REPO_DIR" > "$T/unit.out" 2>&1 <<'PY'
import importlib.util, io, os, sys, time

repo = sys.argv[1]
os.environ.setdefault("DESKCRAB_SERVE_SECRET", "unit")
spec = importlib.util.spec_from_file_location(
    "serve_unit", os.path.join(repo, "lib", "serve.py"))
serve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(serve)

# give_up is at-most-once…
t = serve.Turn("aa")
t.give_up("wedged")
t.give_up("wedged twice")
assert t.done and len(t.events) == 1 and t.events[0]["error"] == "wedged", t.events

# …and never writes over a real completion.
t2 = serve.Turn("bb")
t2.emit("done", {"spoken": "real", "display_html": "", "audio": "", "error": ""})
t2.give_up("late")
assert len(t2.events) == 1 and t2.events[0]["spoken"] == "real", t2.events

# The stream path itself: an overdue doneless turn ends the tail with a
# failed done rather than pinging it.
class H:
    def __init__(self):
        self.wfile = io.BytesIO()
    def send_response(self, *a): pass
    def send_header(self, *a): pass
    def end_headers(self): pass

w = serve.Turn("cc")
w.created = time.time() - (serve.TURN_TIMEOUT + 181)
h = H()
serve.Handler._stream_turn(h, w, 0)
body = h.wfile.getvalue().decode()
assert '"done"' in body and "given up" in body, body
print("UNIT-OK")
PY
UNIT_RC=$?

if [ "$UNIT_RC" = 0 ] && grep -qF 'UNIT-OK' "$T/unit.out"; then
    ok "give_up is once-only, never over a real reply, and wired into the tail"
else
    fail "give_up is once-only, never over a real reply, and wired into the tail" \
         "$(cat "$T/unit.out")"
fi
