#!/bin/bash
# Dead clips stay dead — the engineering record
# phone-playback-dies-mid-reply-leaves-a-dead-play, pinned against its own
# recorded evidence.
# Run: bash tests/test_phone_dead_clip.sh
#
# specs/phone.md rules 44a-44b. Three measured shapes:
#
# 1. THE REJECTION-FIRST ORDERING (2026-08-11, turns db935524 and e913a586):
#    a dead source's play() rejection landed BEFORE the element's error
#    event, read as NotAllowedError, and the client reported "autoplay
#    refused", offered the ▶ button on the very source that cannot load, and
#    then reported "media error 4" for the same clip — two reports for one
#    failure, and a control that did nothing. Both orderings must now end the
#    same way: one error report, no button, the dead state terminal.
# 2. THE 23:39 WEDGE (2026-08-23, turn 58d64fe9): seven clips offered, seven
#    `requested` POSTs, zero /audio fetches, no terminal report of any kind —
#    the queue believed itself playing for good. A clip that never starts
#    must yield its own distinct failure report, never a play claim, and the
#    server must record those failures beside its silent-turn line instead of
#    seven bare requested rows.
# 3. THE DOUBLED ERROR (8 of one day's 38 play-errors): a clip already
#    recorded failed must not land a second play-error line in the metrics —
#    while a stop said twice still stands the silence alarm down.
#
# The client shapes run in tests/phone_client_deadclip_test.js (node, skipped
# loudly as 77 when node is absent, exactly as tests/test_phone_client.sh
# skips); the wedge's reports are then fed VERBATIM to a real server over a
# real socket, so the server half is proven against what the client actually
# emits rather than against hand-typed bodies.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

NODE="${NODE:-$(command -v node 2>/dev/null)}"
[ -z "$NODE" ] && [ -x /usr/bin/node ] && NODE=/usr/bin/node
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    echo "  skip: no node found — the dead-clip client shapes were not exercised."
    echo "  (set NODE=/path/to/node to run them)"
    exit 77
fi

PID_A=""
sandbox_at_exit '[ -n "$PID_A" ] && kill "$PID_A" 2>/dev/null'

SECRET="testsecret"
# Ports nobody else is on; the other phone tests hold 18723-18734.
PORT_A=18736
ALARM=3

# --- the client shapes, against the real page ------------------------------
echo "== the client: both orderings, the give-up, the wedge, the dedup =="

DUMP="$T/wedge-reports.jsonl"
if REPORT_DUMP="$DUMP" "$NODE" "$REPO_DIR/tests/phone_client_deadclip_test.js" \
        > "$T/deadclip-node.out" 2>&1; then
    NODE_RC=0
else
    NODE_RC=1
fi
# The node harness's assertions are this suite's assertions: mirrored through
# ok/fail line by line rather than collapsed to one verdict, so a red inside
# it is a red out here, visibly and arithmetically. Its own tally line is
# dropped — the summary at the bottom is the one that counts.
while IFS= read -r line; do
    case "$line" in
        "  ok: "*)   ok "${line#  ok: }" ;;
        "  FAIL: "*) fail "${line#  FAIL: }" ;;
        [0-9]*" passed, "*" failed") ;;
        *) [ -n "$line" ] && echo "$line" ;;
    esac
done < "$T/deadclip-node.out"
[ "$NODE_RC" -eq 0 ] \
    && ok "the client harness verdict is green" \
    || fail "the client harness verdict is green" "$(tail -n3 "$T/deadclip-node.out")"

# --- the wedge's reports through the real server ---------------------------
echo "== the server: the 58d64fe9 shape carries per-clip failures now =="

cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth)
    printf 'CLIP-BYTES%.0s' $(seq 1 30) > "$2"
    exit 0 ;;
  notify)
    shift
    printf '%s\n' "$*" >> "$NOTIFY_LOG"
    exit 0 ;;
  remote) ;;
  *) exit 1 ;;
esac
python3 - <<'PY'
import json, os
with open(os.environ["DESKCRAB_REMOTE_LOG"], "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"id": "m1",
        "content": [{"type": "text", "text": "the reply"}]}}) + "\n")
PY
python3 -c 'import json;print(json.dumps({"spoken":"the reply","display":"","audio":"","error":""}))'
exit 0
STUB
chmod +x "$T/crab"

mkdir -p "$T/metrics-a"
: > "$T/notify-a.log"

DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT_A" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_SERVE_PLAY_ALARM="$ALARM" \
DESKCRAB_CRAB_BIN="$T/crab" DESKCRAB_STATE_PREFIX="$T/deskcrab-a" \
DESKCRAB_METRICS_DIR="$T/metrics-a" NOTIFY_LOG="$T/notify-a.log" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server-a.log" 2>&1 &
PID_A=$!

for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT_A/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS -m 2 "http://127.0.0.1:$PORT_A/health?k=$SECRET" >/dev/null 2>&1 \
    || die "the server on :$PORT_A never came up" "$(cat "$T/server-a.log")"

turn() {  # <turn id>
    curl -sS -N -m 40 \
        -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"text\":\"hello\",\"turn\":\"$1\"}" \
        "http://127.0.0.1:$PORT_A/say" > "$T/$1.sse" 2>"$T/curl.err"
}

played() {  # <turn id> <clip> <event> [detail]
    curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"turn\":\"$1\",\"clip\":\"$2\",\"event\":\"$3\",\"detail\":\"${4-}\"}" \
        "http://127.0.0.1:$PORT_A/played"
}

METRICS_A="$T/metrics-a/$(date +%Y-%m-%d).log"

# The wedge turn, under the same identifier the client harness reported
# against; its dumped bodies are replayed verbatim.
T6=58d64fe9abababababababababababab
turn "$T6"
contains "$(cat "$T/$T6.sse")" '"kind": "done"' \
    || die "the wedge turn never completed" "$(cat "$T/server-a.log")"

[ -s "$DUMP" ] \
    && ok "the client harness left the wedge's own report bodies to replay" \
    || fail "the client harness left the wedge's own report bodies to replay" \
            "no dump at $DUMP"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "$line" "http://127.0.0.1:$PORT_A/played" >/dev/null
done < "$DUMP"

sleep $((ALARM + 2))

check_eq "every one of the seven clips lands an explicit play-error row" \
    "$(sandbox_count_in "play-error	turn ${T6:0:8} clip" "$METRICS_A")" "7"
check_eq "and not one claims to have started" \
    "$(sandbox_count_in "play-started	turn ${T6:0:8}" "$METRICS_A")" "0"
check_eq "the turn nobody heard still writes its silent-turn row beside them" \
    "$(sandbox_count_in "silent-turn	turn ${T6:0:8}" "$METRICS_A")" "1"
contains "$(grep "silent-turn	turn ${T6:0:8}" "$METRICS_A")" "never started" \
    && ok "and the row now names the per-clip give-up instead of a bare count" \
    || fail "and the row now names the per-clip give-up instead of a bare count" \
            "$(grep "silent-turn" "$METRICS_A")"
check_eq "one notification for the lost turn, never a second" \
    "$(sandbox_count_in "${T6:0:8}" "$T/notify-a.log")" "1"

# --- the doubled error: one failure, one metrics line ----------------------
echo "== the metrics: a clip already recorded failed never lands twice =="

T7=c3c3c3c3d4d4d4d4e5e5e5e5f6f6f6f6
turn "$T7"
contains "$(played "$T7" 0 error "autoplay refused")" '"ok"' \
    && ok "the first error report is taken" \
    || fail "the first error report is taken"
contains "$(played "$T7" 0 error "media error 4")" '"ok"' \
    && ok "the duplicate is still answered 200 — fire-and-forget stays cheap" \
    || fail "the duplicate is still answered 200 — fire-and-forget stays cheap"
played "$T7" 1 error "media error 4" >/dev/null

check_eq "clip 0's doubled failure is one play-error row, not two" \
    "$(sandbox_count_in "play-error	turn ${T7:0:8} clip 0" "$METRICS_A")" "1"
check_eq "while a different clip's failure still lands" \
    "$(sandbox_count_in "play-error	turn ${T7:0:8} clip 1" "$METRICS_A")" "1"

# The dropped line must be the LINE only: a stop reported for a clip that
# already errored still updates the state, and the alarm stays stood down.
T8=d4d4d4d4e5e5e5e5f6f6f6f6a1a1a1a1
turn "$T8"
played "$T8" 0 error "media error 4" >/dev/null
played "$T8" 0 error "stopped by hand" >/dev/null
sleep $((ALARM + 2))
check_eq "the duplicate stop wrote no second metrics row" \
    "$(sandbox_count_in "play-error	turn ${T8:0:8} clip 0" "$METRICS_A")" "1"
check_eq "but still stood the alarm down: chosen silence, no notification" \
    "$(sandbox_count_in "${T8:0:8}" "$T/notify-a.log")" "0"
