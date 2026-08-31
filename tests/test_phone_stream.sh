#!/bin/bash
# The phone's completed-answer voice boundary, including the legacy sentence flag.
# Run: bash tests/test_phone_stream.sh
#
# specs/phone.md rule 17: thinking and tool progress stay live, while provider
# answer text and voice remain private until the completed reply payload.
# PHONE_SENTENCE_STREAM cannot weaken that boundary.
#
# Two real servers over two real sockets — one per mode — fed one synthetic
# delta stream by a stub `crab`, whose synth arm is also the speaker-side
# witness: every text it is asked to voice lands in a log this test reads.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

PID_ON="" PID_OFF=""
sandbox_at_exit '[ -n "$PID_ON" ] && kill "$PID_ON" 2>/dev/null'
sandbox_at_exit '[ -n "$PID_OFF" ] && kill "$PID_OFF" 2>/dev/null'

SECRET="testsecret"
# Ports nobody else is on; the other phone tests hold 18723-18728.
PORT_ON=18730
PORT_OFF=18731

# --- the config plumbing ---------------------------------------------------
#
# The flag travels config -> crab serve -> the server's environment. Proven by
# letting `crab serve` exec into a stub python3 that prints what arrived; the
# stub is removed again before the real servers below need the real python3.
echo "== PHONE_SENTENCE_STREAM reaches the server's environment =="

sandbox_stub python3 <<'STUB'
#!/bin/bash
echo "SENTENCE_STREAM=[${DESKCRAB_PHONE_SENTENCE_STREAM-unset}]"
STUB
cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
SERVE_SECRET="$SECRET"
PHONE_SENTENCE_STREAM=1
CONF
check_eq "the config's 1 arrives as DESKCRAB_PHONE_SENTENCE_STREAM=1" \
    "$("$REPO_DIR/crab" serve 2>/dev/null | grep SENTENCE_STREAM=)" \
    "SENTENCE_STREAM=[1]"
cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
SERVE_SECRET="$SECRET"
CONF
check_eq "an unset knob arrives as the default 0" \
    "$("$REPO_DIR/crab" serve 2>/dev/null | grep SENTENCE_STREAM=)" \
    "SENTENCE_STREAM=[0]"
rm -f "$SANDBOX_BIN/python3"
hash -r

# --- the stub `crab` -------------------------------------------------------
#
# `synth` records every text the Speaker asks for — the trace this test judges
# speech by, written outside the code under test — and hands back a non-empty
# clip. `remote` writes the synthetic delta stream, with real pauses so that
# a clip cut from a delta demonstrably lands before the block completes, then
# prints the reply JSON with a whole-reply clip attached.
cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth)
    printf '%s\n' "$3" >> "$SYNTH_LOG"
    printf 'CLIP-BYTES%.0s' $(seq 1 30) > "$2"
    exit 0 ;;
  remote) ;;
  *) exit 1 ;;
esac
python3 - <<'PY'
import json, os, time
log = os.environ["DESKCRAB_REMOTE_LOG"]
mode = open(os.environ["STREAMMODE"]).read().strip()
def w(o):
    with open(log, "a") as f:
        f.write(json.dumps(o) + "\n")
def se(ev):
    w({"type": "stream_event", "event": ev})
if mode == "plain":
    # A real turn's shape: a thinking block ahead of the text block (the
    # doubling shape of 2026-08-07), two sentences arriving in deltas that
    # split mid-sentence, an unpunctuated tail only the completed event can
    # voice, and a second message whose display half splits the delimiter
    # itself across two deltas.
    se({"type": "message_start", "message": {"id": "msg_a1"}})
    se({"type": "content_block_start", "index": 0,
        "content_block": {"type": "thinking"}})
    se({"type": "content_block_start", "index": 1,
        "content_block": {"type": "text"}})
    se({"type": "content_block_delta", "index": 1,
        "delta": {"type": "text_delta", "text": "One plus one is two. Two plus "}})
    time.sleep(0.6)
    se({"type": "content_block_delta", "index": 1,
        "delta": {"type": "text_delta",
                  "text": "two is four! And the tail rides the completed event"}})
    time.sleep(0.6)
    w({"type": "assistant", "message": {"id": "msg_a1", "content":
        [{"type": "thinking", "thinking": "pondering"}]}})
    w({"type": "assistant", "message": {"id": "msg_a1", "content":
        [{"type": "text", "text": "One plus one is two. Two plus two is four!"
          " And the tail rides the completed event"}]}})
    se({"type": "message_start", "message": {"id": "msg_a2"}})
    se({"type": "content_block_start", "index": 0,
        "content_block": {"type": "text"}})
    se({"type": "content_block_delta", "index": 0,
        "delta": {"type": "text_delta", "text": "Spoken half stays spoken.\n---DIS"}})
    se({"type": "content_block_delta", "index": 0,
        "delta": {"type": "text_delta", "text": "PLAY---\n## never voiced card"}})
    w({"type": "assistant", "message": {"id": "msg_a2", "content":
        [{"type": "text",
          "text": "Spoken half stays spoken.\n---DISPLAY---\n## never voiced card"}]}})
else:
    # The re-emit shapes: the same completed event twice, and the whole
    # message streamed again — a truncation re-read or a CLI re-emit. One
    # clip may come of all of it.
    full = "Spoken half stays spoken.\n---DISPLAY---\n## never voiced card"
    se({"type": "message_start", "message": {"id": "msg_b1"}})
    se({"type": "content_block_start", "index": 0,
        "content_block": {"type": "text"}})
    se({"type": "content_block_delta", "index": 0,
        "delta": {"type": "text_delta", "text": "Spoken half stays spoken.\n---DIS"}})
    se({"type": "content_block_delta", "index": 0,
        "delta": {"type": "text_delta", "text": "PLAY---\n## never voiced card"}})
    w({"type": "assistant", "message": {"id": "msg_b1", "content":
        [{"type": "text", "text": full}]}})
    w({"type": "assistant", "message": {"id": "msg_b1", "content":
        [{"type": "text", "text": full}]}})
    se({"type": "message_start", "message": {"id": "msg_b1"}})
    se({"type": "content_block_delta", "index": 0,
        "delta": {"type": "text_delta", "text": "Spoken half stays spoken.\n---DIS"}})
    se({"type": "content_block_delta", "index": 0,
        "delta": {"type": "text_delta", "text": "PLAY---\n## never voiced card"}})
    w({"type": "assistant", "message": {"id": "msg_b1", "content":
        [{"type": "text", "text": full}]}})
PY
CLIP="$TMPDIR/deskcrab-remote-$RANDOM$RANDOM.opus"
printf 'WHOLE-REPLY-CLIP%.0s' $(seq 1 20) > "$CLIP"
python3 -c 'import json,sys;print(json.dumps({"spoken":"the reply","display":"## A card","audio":sys.argv[1],"error":""}))' "$CLIP"
exit 0
STUB
chmod +x "$T/crab"

echo "plain" > "$T/streammode"

# --- the two servers -------------------------------------------------------
DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT_ON" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_CRAB_BIN="$T/crab" DESKCRAB_STATE_PREFIX="$T/deskcrab-on" \
DESKCRAB_PHONE_SENTENCE_STREAM=1 \
STREAMMODE="$T/streammode" SYNTH_LOG="$T/synth-on.log" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server-on.log" 2>&1 &
PID_ON=$!

DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT_OFF" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_CRAB_BIN="$T/crab" DESKCRAB_STATE_PREFIX="$T/deskcrab-off" \
STREAMMODE="$T/streammode" SYNTH_LOG="$T/synth-off.log" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server-off.log" 2>&1 &
PID_OFF=$!

for PORT in "$PORT_ON" "$PORT_OFF"; do
    for _ in $(seq 1 100); do
        curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
        sleep 0.1
    done
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 \
        || die "the server on :$PORT never came up" \
               "$(cat "$T/server-on.log" "$T/server-off.log")"
done

turn() {  # <port> <turn id> <sse file>
    curl -sS -N -m 40 \
        -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"text\":\"hello\",\"turn\":\"$2\"}" \
        "http://127.0.0.1:$1/say" > "$3" 2>"$T/curl.err"
}

# The texts of one event kind, in arrival order — what the phone would hear.
sse_texts() {  # <sse file> <kind>
    python3 - "$1" "$2" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("data: "):
        continue
    ev = json.loads(line[6:])
    if ev.get("kind") == sys.argv[2]:
        print(ev.get("text", ""))
PY
}

# --- both modes: raw answer text and voice stay held -----------------------
echo "== answer drafts stay behind the phone completion boundary =="

: > "$T/synth-on.log"
: > "$T/synth-off.log"
turn "$PORT_ON" aaa111 "$T/on.sse"
turn "$PORT_OFF" bbb222 "$T/off.sse"

for MODE in on off; do
    check_eq "$MODE mode emits no raw draft text" \
        "$(sandbox_count_in '\"kind\": *\"text\"' "$T/$MODE.sse")" "0"
    check_eq "$MODE mode emits no raw draft voice" \
        "$(sandbox_count_in '\"kind\": *\"voice\"' "$T/$MODE.sse")" "0"
    check_eq "$MODE mode never asks synth to voice a provider draft" \
        "$(wc -l < "$T/synth-$MODE.log" 2>/dev/null || echo 0)" "0"
    DONE_LINE=$(grep '"kind": *"done"' "$T/$MODE.sse" | head -n1)
    contains "$DONE_LINE" '"spoken": "the reply"' \
        && ok "$MODE mode delivers the completed reply in done" \
        || fail "$MODE mode delivers the completed reply in done" "$DONE_LINE"
    contains "$DONE_LINE" '"audio": "/audio/' \
        && ok "$MODE mode carries the completed whole-reply clip once" \
        || fail "$MODE mode carries the completed whole-reply clip once" "$DONE_LINE"
    contains "$DONE_LINE" "A card" \
        && ok "$MODE mode carries the completed display card" \
        || fail "$MODE mode carries the completed display card" "$DONE_LINE"
done

echo
echo "== re-emitted drafts still add nothing =="
echo "replay" > "$T/streammode"
: > "$T/synth-on.log"
turn "$PORT_ON" ccc333 "$T/replay.sse"
check_eq "a message streamed twice and completed thrice emits no draft text" \
    "$(sandbox_count_in '\"kind\": *\"text\"' "$T/replay.sse")" "0"
check_eq "and no draft voice" \
    "$(sandbox_count_in '\"kind\": *\"voice\"' "$T/replay.sse")" "0"
check_eq "and no draft synthesis" "$(wc -l < "$T/synth-on.log")" "0"
