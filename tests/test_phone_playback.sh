#!/bin/bash
# Playback truth: the phone reports what its audio element actually did, and
# the server notices a reply nobody ever heard.
# Run: bash tests/test_phone_playback.sh
#
# specs/phone.md rules 44-46: the client posts per-clip outcomes (requested,
# started, completed, error) to /played with the turn id and clip index; the
# server records them in the per-day metrics log beside the synth stamps; and
# a turn whose spoken text was delivered with no started report inside the
# alarm window raises exactly one `crab notify` — unless the silence was
# chosen (a stop), or no client has ever reported at all (a page from before
# the rule must not page the house on every turn).
#
# Two real servers over real sockets: one that has seen a reporting client,
# one that never does.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

PID_A="" PID_B=""
sandbox_at_exit '[ -n "$PID_A" ] && kill "$PID_A" 2>/dev/null'
sandbox_at_exit '[ -n "$PID_B" ] && kill "$PID_B" 2>/dev/null'

SECRET="testsecret"
# Ports nobody else is on; the other phone tests hold 18723-18731.
PORT_A=18733
PORT_B=18734
ALARM=3

# --- the stub `crab` -------------------------------------------------------
#
# `synth` hands back a non-empty clip, so every turn offers exactly one voice
# clip. `remote` streams one text block and returns a spoken reply. `notify`
# is the witness this test judges the alarm by: every text it is handed lands
# in a log written outside the code under test.
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

# --- the two servers -------------------------------------------------------
mkdir -p "$T/metrics-a" "$T/metrics-b"
: > "$T/notify-a.log"
: > "$T/notify-b.log"

DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT_A" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_SERVE_PLAY_ALARM="$ALARM" \
DESKCRAB_CRAB_BIN="$T/crab" DESKCRAB_STATE_PREFIX="$T/deskcrab-a" \
DESKCRAB_METRICS_DIR="$T/metrics-a" NOTIFY_LOG="$T/notify-a.log" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server-a.log" 2>&1 &
PID_A=$!

DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT_B" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_SERVE_PLAY_ALARM="$ALARM" \
DESKCRAB_CRAB_BIN="$T/crab" DESKCRAB_STATE_PREFIX="$T/deskcrab-b" \
DESKCRAB_METRICS_DIR="$T/metrics-b" NOTIFY_LOG="$T/notify-b.log" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server-b.log" 2>&1 &
PID_B=$!

for PORT in "$PORT_A" "$PORT_B"; do
    for _ in $(seq 1 100); do
        curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
        sleep 0.1
    done
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 \
        || die "the server on :$PORT never came up" \
               "$(cat "$T/server-a.log" "$T/server-b.log")"
done

turn() {  # <port> <turn id>
    curl -sS -N -m 40 \
        -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"text\":\"hello\",\"turn\":\"$2\"}" \
        "http://127.0.0.1:$1/say" > "$T/$2.sse" 2>"$T/curl.err"
}

played() {  # <port> <turn id> <clip> <event> [detail]
    curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"turn\":\"$2\",\"clip\":\"$3\",\"event\":\"$4\",\"detail\":\"${5-}\"}" \
        "http://127.0.0.1:$1/played"
}

METRICS_A="$T/metrics-a/$(date +%Y-%m-%d).log"
METRICS_B="$T/metrics-b/$(date +%Y-%m-%d).log"

# --- the route's own hygiene ----------------------------------------------
echo "== the report route refuses what it must =="

check_eq "an unauthenticated report is a 404, disclosing nothing" \
    "$(curl -sS -o /dev/null -w '%{http_code}' -m 5 \
        -H 'Content-Type: application/json' \
        --data '{"turn":"abc123","clip":"0","event":"started"}' \
        "http://127.0.0.1:$PORT_A/played")" "404"

contains "$(played "$PORT_A" abc123 0 exploded)" '"error"' \
    && ok "an unknown event kind is refused" \
    || fail "an unknown event kind is refused"

# --- a turn that was heard raises nothing ----------------------------------
echo "== a heard turn: reports recorded, no notification =="

T1=a1a1a1a1b2b2b2b2c3c3c3c3d4d4d4d4
turn "$PORT_A" "$T1"
contains "$(cat "$T/$T1.sse")" '"kind": "done"' \
    || die "turn one never completed" "$(cat "$T/server-a.log")"
played "$PORT_A" "$T1" 0 requested >/dev/null
played "$PORT_A" "$T1" 0 started   >/dev/null
played "$PORT_A" "$T1" 0 completed >/dev/null

sleep $((ALARM + 2))
check_eq "no notification for a turn whose clip reported playing" \
    "$(sandbox_count_in "${T1:0:8}" "$T/notify-a.log")" "0"
for EV in play-requested play-started play-completed; do
    check_eq "the metrics log carries $EV for the turn" \
        "$(sandbox_count_in "$EV	turn ${T1:0:8} clip 0" "$METRICS_A")" "1"
done

# --- a silent turn notifies, exactly once ----------------------------------
echo "== a silent turn: one notification, never a second =="

T2=b2b2b2b2c3c3c3c3d4d4d4d4e5e5e5e5
turn "$PORT_A" "$T2"
sleep $((ALARM + 2))
check_eq "exactly one notification for the silent turn" \
    "$(sandbox_count_in "${T2:0:8}" "$T/notify-a.log")" "1"
check_eq "and the metrics log records the silent turn" \
    "$(sandbox_count_in "silent-turn	turn ${T2:0:8}" "$METRICS_A")" "1"

# --- an autoplay refusal is named ------------------------------------------
echo "== an autoplay refusal nobody answered is named in the notification =="

T3=c3c3c3c3d4d4d4d4e5e5e5e5f6f6f6f6
turn "$PORT_A" "$T3"
played "$PORT_A" "$T3" 0 requested >/dev/null
played "$PORT_A" "$T3" 0 error "autoplay refused" >/dev/null
sleep $((ALARM + 2))
check_eq "the silent turn was notified" \
    "$(sandbox_count_in "${T3:0:8}" "$T/notify-a.log")" "1"
contains "$(grep "${T3:0:8}" "$T/notify-a.log")" "autoplay refused" \
    && ok "and the notification names the refusal" \
    || fail "and the notification names the refusal" \
            "$(cat "$T/notify-a.log")"

# --- a chosen stop counts as heard -----------------------------------------
echo "== a stop by hand is chosen silence, not a lost voice =="

T4=d4d4d4d4e5e5e5e5f6f6f6f6a1a1a1a1
turn "$PORT_A" "$T4"
played "$PORT_A" "$T4" 0 requested >/dev/null
played "$PORT_A" "$T4" 0 error "stopped by hand" >/dev/null
sleep $((ALARM + 2))
check_eq "no notification for a turn stopped on purpose" \
    "$(sandbox_count_in "${T4:0:8}" "$T/notify-a.log")" "0"

# --- a client from before the rule never pages the house -------------------
echo "== a server that has never seen a report records, but never notifies =="

T5=e5e5e5e5f6f6f6f6a1a1a1a1b2b2b2b2
turn "$PORT_B" "$T5"
sleep $((ALARM + 2))
check_eq "the silent turn is in the metrics" \
    "$(sandbox_count_in "silent-turn	turn ${T5:0:8}" "$METRICS_B")" "1"
check_eq "but an old client's every turn is not a nightly page" \
    "$(sandbox_count_in . "$T/notify-b.log")" "0"
