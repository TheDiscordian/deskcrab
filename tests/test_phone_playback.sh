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

refute() {
    local desc="$1"
    shift
    if "$@"; then fail "$desc"; else ok "$desc"; fi
}

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

PID_A="" PID_B="" FACE_PID=""
sandbox_at_exit '[ -n "$PID_A" ] && kill "$PID_A" 2>/dev/null'
sandbox_at_exit '[ -n "$PID_B" ] && kill "$PID_B" 2>/dev/null'
sandbox_at_exit '[ -n "$FACE_PID" ] && kill "$FACE_PID" 2>/dev/null'

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
    printf '%s\n' '{"version":1,"duration":2.0,"phoneme_records":[{"phonemes":"həlˈoʊ","duration":1.8}],"cues":[[0.0,"slight"],[0.5,"open"],[1.8,"rest"]]}' > "$2.face.json"
    exit 0 ;;
  notify)
    shift
    printf '%s\n' "$*" >> "$NOTIFY_LOG"
    exit 0 ;;
  remote)
    STUB_REMOTE_AUDIO="$(mktemp "${TMPDIR:?}/deskcrab-remote-playback.XXXXXX.opus")"
    printf 'CLIP-BYTES%.0s' $(seq 1 30) > "$STUB_REMOTE_AUDIO"
    printf '%s\n' '{"version":1,"duration":2.0,"phoneme_records":[{"phonemes":"həlˈoʊ","duration":1.8}],"cues":[[0.0,"slight"],[0.5,"open"],[1.8,"rest"]]}' > "$STUB_REMOTE_AUDIO.face.json"
    export STUB_REMOTE_AUDIO ;;
  *) exit 1 ;;
esac
python3 - <<'PY'
import json, os
with open(os.environ["DESKCRAB_REMOTE_LOG"], "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"id": "m1",
        "content": [{"type": "text", "text": "the reply"}]}}) + "\n")
PY
python3 -c 'import json,os;print(json.dumps({"spoken":"the reply","display":"","audio":os.environ.get("STUB_REMOTE_AUDIO", ""),"error":""}))'
exit 0
STUB
chmod +x "$T/crab"

# --- the two servers -------------------------------------------------------
mkdir -p "$T/metrics-a" "$T/metrics-b"
: > "$T/notify-a.log"
: > "$T/notify-b.log"

DESKCRAB_STATE_PREFIX="$T/deskcrab-a" \
DESKCRAB_FACE_SOCKET="$T/face-a.sock" \
DESKCRAB_FACE_STATE="$T/face-a-state.json" \
    python3 "$REPO_DIR/lib/face_state.py" serve > "$T/face-a.log" 2>&1 &
FACE_PID=$!

DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT_A" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_SERVE_PLAY_ALARM="$ALARM" \
DESKCRAB_CRAB_BIN="$T/crab" DESKCRAB_STATE_PREFIX="$T/deskcrab-a" \
DESKCRAB_FACE_SOCKET="$T/face-a.sock" \
DESKCRAB_FACE_STATE="$T/face-a-state.json" \
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

played() {  # <port> <turn id> <clip> <event> [detail] [face cue]
    curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"turn\":\"$2\",\"clip\":\"$3\",\"event\":\"$4\",\"detail\":\"${5-}\",\"face_cue\":\"${6-}\"}" \
        "http://127.0.0.1:$1/played"
}

face_status() {
    DESKCRAB_STATE_PREFIX="$T/deskcrab-a" \
    DESKCRAB_FACE_SOCKET="$T/face-a.sock" \
    DESKCRAB_FACE_STATE="$T/face-a-state.json" \
        python3 "$REPO_DIR/lib/face-broker" status
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
FACE_CUE="$(python3 - "$T/$T1.sse" <<'PY'
import json
import sys

for line in open(sys.argv[1]):
    if line.startswith("data: "):
        event = json.loads(line[6:])
        if event.get("kind") in ("voice", "done") and event.get("face_cue"):
            print(event["face_cue"])
            break
PY
)"
[ -n "$FACE_CUE" ] && ok "the generated voice payload carries an opaque face cue id" \
    || fail "the generated voice payload carries an opaque face cue id" "$(cat "$T/$T1.sse")"
refute "the private phoneme record never crosses into the voice payload" \
    grep -q 'həlˈoʊ\|phoneme_records\|face.json' "$T/$T1.sse"
played "$PORT_A" "$T1" 0 requested "" "$FACE_CUE" >/dev/null
refute "requesting a clip does not move the mouth" \
    grep -q "phone-$FACE_CUE" < <(face_status)
played "$PORT_A" "$T1" 0 started "" "$FACE_CUE" >/dev/null
FACE_STARTED="$(face_status)"
contains "$FACE_STARTED" "phone-$FACE_CUE" \
    && contains "$FACE_STARTED" '"open"' \
    && ok "the real playback start publishes the retained cue track" \
    || fail "the real playback start publishes the retained cue track" "$FACE_STARTED"
played "$PORT_A" "$T1" 0 completed "" "$FACE_CUE" >/dev/null
refute "completion removes only that phone mouth track" \
    grep -q "phone-$FACE_CUE" < <(face_status)

sleep $((ALARM + 2))
check_eq "no notification for a turn whose clip reported playing" \
    "$(sandbox_count_in "${T1:0:8}" "$T/notify-a.log")" "0"
for EV in play-requested play-started play-completed; do
    check_eq "the metrics log carries $EV for the turn" \
        "$(sandbox_count_in "$EV	turn ${T1:0:8} clip 0" "$METRICS_A")" "1"
done

# --- phone-routed wake speech uses the same playback truth ----------------
echo "== a phone-routed wake carries private cues through the same route =="

printf '%s\n' '{"id":"wake-test","audio":"/audio/deskcrab-remote-wake-test.opus","spoken":"wake reply","face_cue":"wake-test","_face":{"version":1,"duration":1.5,"phoneme_records":[{"phonemes":"wˈeɪk","duration":1.3}],"cues":[[0.0,"wide"],[1.3,"rest"]]}}' \
    > "$T/deskcrab-a-wake-audio"
WATCH="$(curl -sS -m 5 -H "X-Crab-Key: $SECRET" \
    "http://127.0.0.1:$PORT_A/watch?wait=0&wakeseen=none")"
WAKE_CUE="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["wake"]["face_cue"])' \
    <<< "$WATCH")"
check_eq "the wake exposes only its opaque cue id" "$WAKE_CUE" "wake-test"
refute "the wake response keeps phonemes and cues private" \
    grep -q 'phoneme_records\|_face\|wˈeɪk' <<< "$WATCH"
played "$PORT_A" "" "" started "" "$WAKE_CUE" >/dev/null
contains "$(face_status)" "phone-$WAKE_CUE" \
    && ok "a wake begins mouth motion only when its audio starts" \
    || fail "a wake begins mouth motion only when its audio starts"
played "$PORT_A" "" "" completed "" "$WAKE_CUE" >/dev/null
refute "a completed wake closes its own mouth track" \
    grep -q "phone-$WAKE_CUE" < <(face_status)

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
