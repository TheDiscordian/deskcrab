#!/bin/bash
# In-flight delivery — specs/phone.md rules 51-52.
# Run: bash tests/test_phone_midturn.sh
#
# Reported by the user 2026-08-11: a message sent while a turn ran tool calls
# was queued but unheard until the turn ended, so a course correction sent
# mid-task arrived after the course had been run. The fix is a mid-turn spool
# the server writes the moment a message is accepted behind a running turn,
# and a PostToolUse hook (lib/midturn-mail) the running turn reads at its very
# next tool-call boundary.
#
# This file proves the plumbing end to end short of a real model: a real
# serve.py over a real socket with a stub `crab` holding the REAL remote lock
# writes the spool entry the moment a mid-turn message is accepted and sweeps
# it on /stop; the reader drains a populated spool oldest-first into one
# marked delivery and leaves it empty, skips its own turn's entry, expires an
# aged one unread, and says nothing at all for an empty spool; and the per-run
# settings file really carries the hook. The model half — the injected mail
# actually steering a live turn — was verified against the real CLI
# (claude 2.1.226) before the rule was written, and cannot run in a sandbox
# that stubs claude by design.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; phone_live 18723, watch_rewrite 18724, wedge
# 18725, done_after_exit 18726, queue_wait/voice_fallback 18727, media 18728,
# stop 18729, stream 18730/18731.
PORT=18732

MAIL="$REPO_DIR/lib/midturn-mail"
SPOOL="$T/deskcrab-midturn"

# --- the stub `crab` -------------------------------------------------------
# `remote` takes the real lock at ${DESKCRAB_STATE_PREFIX}-remote.lock on fd
# 8, the same shape as run_claude_remote, so a second turn genuinely parks
# behind the first and the spool write happens with the lock truly held.
cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth) : > "$2"; exit 1 ;;
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

echo "== a message accepted behind a running turn lands in the spool at once =="

curl -sS -N -m 90 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"slow and long","turn":"aaaa01"}' \
    "http://127.0.0.1:$PORT/say" > "$T/slow.sse" 2>/dev/null &
CURL_SLOW=$!

for _ in $(seq 1 150); do
    [ -s "$T/deskcrab-stub-remote.pid" ] && break
    sleep 0.1
done
[ -s "$T/deskcrab-stub-remote.pid" ] \
    || die "the slow turn never took the lock" "$(cat "$T/server.log")"

curl -sS -N -m 60 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"THE-MIDTURN-CORRECTION","turn":"bbbb02"}' \
    "http://127.0.0.1:$PORT/say" > "$T/parked.sse" 2>/dev/null &
CURL_PARKED=$!

ENTRY=""
for _ in $(seq 1 80); do
    ENTRY="$(ls "$SPOOL"/*.bbbb02.msg 2>/dev/null | head -1)"
    [ -n "$ENTRY" ] && break
    sleep 0.1
done
if [ -n "$ENTRY" ]; then
    ok "the spool entry exists, named by the queued turn's own id"
else
    fail "the spool entry exists, named by the queued turn's own id" \
         "spool: [$(ls "$SPOOL" 2>/dev/null)] — $(cat "$T/server.log")"
fi
check "and it carries the message verbatim" \
    contains "$(cat "$ENTRY" 2>/dev/null)" "THE-MIDTURN-CORRECTION"

echo "== a stop sweeps the queued turn's entry away (rules 50, 52) =="

curl -fsS -m 15 -o /dev/null \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"turn":"bbbb02"}' "http://127.0.0.1:$PORT/stop" 2>/dev/null
GONE=""
for _ in $(seq 1 50); do
    [ -z "$(ls "$SPOOL"/*.bbbb02.msg 2>/dev/null)" ] && { GONE=1; break; }
    sleep 0.1
done
[ -n "$GONE" ] \
    && ok "the stopped turn's entry left the spool with it" \
    || fail "the stopped turn's entry left the spool with it" \
            "still there: $(ls "$SPOOL" 2>/dev/null)"

echo "== the reader: drained once, oldest first, marked, spool left empty =="

NOW_NS="$(date +%s%N)"
printf 'FIRST-MESSAGE'  > "$SPOOL/$(( NOW_NS - 1000 )).cccc03.msg"
printf 'SECOND-MESSAGE' > "$SPOOL/$NOW_NS.dddd04.msg"
OUT="$(DESKCRAB_STATE_PREFIX="$T/deskcrab" DESKCRAB_TURN_ID=aaaa01 "$MAIL")"
check "the delivery is marked as the user's message arriving mid-turn" \
    contains "$OUT" "MID-TURN MESSAGE FROM THE USER"
check "it says the message still runs as its own turn (rule 51)" \
    contains "$OUT" "as its own turn"
PARSED="$(printf '%s' "$OUT" | python3 -c '
import json, sys
o = json.load(sys.stdin)["hookSpecificOutput"]
ctx = o["additionalContext"]
print(o["hookEventName"])
print(ctx.find("FIRST-MESSAGE") < ctx.find("SECOND-MESSAGE")
      and ctx.find("FIRST-MESSAGE") >= 0)
' 2>/dev/null)"
check_eq "the output is a valid PostToolUse hook payload, oldest message first" \
    "$PARSED" "PostToolUse
True"
check_eq "and the spool is empty afterwards — delivered exactly once" \
    "$(ls "$SPOOL"/*.msg 2>/dev/null | wc -l)" "0"

OUT2="$(DESKCRAB_STATE_PREFIX="$T/deskcrab" "$MAIL")"
check_eq "an empty spool produces no output at all" "$OUT2" ""

echo "== the reader's own-turn skip, and expiry by age (rule 52) =="

printf 'MY-OWN-QUESTION' > "$SPOOL/$(date +%s%N).eeee05.msg"
OUT3="$(DESKCRAB_STATE_PREFIX="$T/deskcrab" DESKCRAB_TURN_ID=eeee05 "$MAIL")"
check_eq "a run is never handed its own message as mail" "$OUT3" ""
check_eq "and the skipped entry is left for its own runner to delete" \
    "$(ls "$SPOOL"/*.eeee05.msg 2>/dev/null | wc -l)" "1"
rm -f "$SPOOL"/*.eeee05.msg

printf 'FROM-ANOTHER-AGE' > "$SPOOL/1000000000.ffff06.msg"
OUT4="$(DESKCRAB_STATE_PREFIX="$T/deskcrab" DESKCRAB_TURN_ID=aaaa01 "$MAIL")"
check_eq "an aged entry expires unread rather than mis-delivering late" "$OUT4" ""
check_eq "and expiry consumes it" \
    "$(ls "$SPOOL"/*.ffff06.msg 2>/dev/null | wc -l)" "0"

echo "== a message with nothing running spools nothing =="

curl -fsS -m 15 -o /dev/null \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"turn":"aaaa01"}' "http://127.0.0.1:$PORT/stop" 2>/dev/null
wait "$CURL_SLOW" 2>/dev/null
wait "$CURL_PARKED" 2>/dev/null

curl -sS -N -m 60 \
    -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data '{"text":"a quiet ask","turn":"9999aa"}' \
    "http://127.0.0.1:$PORT/say" > "$T/idle.sse" 2>/dev/null
grep -q 'FAST-REPLY' "$T/idle.sse" \
    || fail "the idle turn answered" "$(tail -c 300 "$T/idle.sse")"
check_eq "an idle send writes no spool entry — there is nobody to surface it to" \
    "$(ls "$SPOOL"/*.9999aa.msg 2>/dev/null | wc -l)" "0"

echo "== the wiring: the per-run settings carry the hook, id and all =="

COCOON_OUT="$(sandbox_bash 'export DESKCRAB_TURN_ID=tid42; claude_profile_flags turn; cat "${STATE_PREFIX}-cocoon.json"')"
check "the generated settings file carries a PostToolUse hook" \
    contains "$COCOON_OUT" '"PostToolUse"'
check "pointed at the mail reader" contains "$COCOON_OUT" "lib/midturn-mail"
check "with the run's own turn id baked in for the never-echo skip" \
    contains "$COCOON_OUT" "DESKCRAB_TURN_ID=tid42"
printf '%s' "$COCOON_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    && ok "and the whole settings file is still valid JSON" \
    || fail "and the whole settings file is still valid JSON" "$COCOON_OUT"

# The runner's own-entry delete is a live-path behaviour (crab remote under a
# real lock); pinned here by the exact line so a refactor cannot drop it
# silently, the same way test_claudism_mirror pins its call sites.
grep -q 'midturn/"\*"\.\${DESKCRAB_TURN_ID}\.msg' "$REPO_DIR/lib/common.sh" \
    && ok "the runner deletes its own spool entry once it holds the lock (pinned)" \
    || fail "the runner deletes its own spool entry once it holds the lock (pinned)" \
            "the rm line is gone from _run_claude_remote_locked"

curl -fsS -m 5 "http://127.0.0.1:$PORT/health?k=$SECRET" | grep -q '"ok": *true' \
    && ok "and the server is still standing" \
    || fail "and the server is still standing" "$(tail -c 300 "$T/server.log")"
