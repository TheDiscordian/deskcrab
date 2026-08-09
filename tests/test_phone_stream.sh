#!/bin/bash
# Sentence-level streaming voice on the phone, and the flag that gates it.
# Run: bash tests/test_phone_stream.sh
#
# specs/phone.md rule 17: with PHONE_SENTENCE_STREAM=1 the turn's text deltas
# are chunked into sentences by the desk streamer's own chunker and each
# sentence becomes a clip the moment it completes, the completed block voicing
# only the tail the deltas had not spoken; with the flag off (the default) the
# path is byte-for-byte the one-clip-per-completed-block behaviour it always
# was. Either way a sentence is never voiced twice, never dropped, and the
# display half never reaches the synthesiser.
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

# --- the flag on: sentences stream ----------------------------------------
echo "== flag on: a clip per sentence, the tail from the completed event =="

turn "$PORT_ON" aaa111 "$T/on.sse"

sse_texts "$T/on.sse" voice > "$T/on.voice"
cat > "$T/on.expected" <<'WANT'
One plus one is two.
Two plus two is four!
And the tail rides the completed event
Spoken half stays spoken.
WANT
diff -q "$T/on.voice" "$T/on.expected" >/dev/null \
    && ok "every sentence voiced exactly once, in order, tail included" \
    || fail "every sentence voiced exactly once, in order, tail included" \
            "$(cat "$T/on.voice")"

diff -q "$T/synth-on.log" "$T/on.expected" >/dev/null \
    && ok "the synthesiser's own trace agrees, in the same order" \
    || fail "the synthesiser's own trace agrees, in the same order" \
            "$(cat "$T/synth-on.log")"

check_eq "no sentence was voiced twice" \
    "$(sort "$T/on.voice" | uniq -d | wc -l)" "0"

check_eq "the display half never reached the synthesiser" \
    "$(sandbox_count_in 'never voiced\|DISPLAY' "$T/synth-on.log")" "0"

# Streaming means the first clip cannot be waiting for the block: the stub
# holds the stream open 1.2s after the first sentence's delta, so a clip cut
# from the delta lands in the buffer before the completed block's text event.
FIRST_VOICE=$(grep -n '"kind": *"voice"' "$T/on.sse" | head -n1 | cut -d: -f1)
FIRST_TEXT=$(grep -n '"kind": *"text"' "$T/on.sse" | head -n1 | cut -d: -f1)
if [ -n "$FIRST_VOICE" ] && [ -n "$FIRST_TEXT" ] \
        && [ "$FIRST_VOICE" -lt "$FIRST_TEXT" ]; then
    ok "the first clip was emitted before the block completed"
else
    fail "the first clip was emitted before the block completed" \
         "first voice at line ${FIRST_VOICE:-none}, first text at ${FIRST_TEXT:-none}"
fi

# The reply text the page draws is untouched by the flag: still one text
# event per completed block, the whole spoken half in each.
sse_texts "$T/on.sse" text > "$T/on.text"
cat > "$T/on.text.expected" <<'WANT'
One plus one is two. Two plus two is four! And the tail rides the completed event
Spoken half stays spoken.
WANT
diff -q "$T/on.text" "$T/on.text.expected" >/dev/null \
    && ok "the text events stay per block, exactly as without the flag" \
    || fail "the text events stay per block, exactly as without the flag" \
            "$(cat "$T/on.text")"

DONE_LINE=$(grep '"kind": *"done"' "$T/on.sse" | head -n1)
case "$DONE_LINE" in
  *'"audio": ""'*)
    ok "clips were voiced, so the completion event offers no second copy" ;;
  *)
    fail "clips were voiced, so the completion event offers no second copy" \
         "done event: ${DONE_LINE:-none}" ;;
esac
contains "$DONE_LINE" "A card" \
    && ok "and the display card still rides the completion event" \
    || fail "and the display card still rides the completion event" \
            "done event: ${DONE_LINE:-none}"

# --- the flag off: byte-for-byte the block behaviour -----------------------
echo "== flag off: one clip per completed block, nothing streams early =="

turn "$PORT_OFF" bbb222 "$T/off.sse"

sse_texts "$T/off.sse" voice > "$T/off.voice"
cat > "$T/off.expected" <<'WANT'
One plus one is two. Two plus two is four! And the tail rides the completed event
Spoken half stays spoken.
WANT
diff -q "$T/off.voice" "$T/off.expected" >/dev/null \
    && ok "exactly one clip per completed block, the whole spoken half each" \
    || fail "exactly one clip per completed block, the whole spoken half each" \
            "$(cat "$T/off.voice")"

check_eq "no sentence-sized clip was cut" \
    "$(sandbox_count_in '^One plus one is two.$' "$T/synth-off.log")" "0"

FIRST_VOICE=$(grep -n '"kind": *"voice"' "$T/off.sse" | head -n1 | cut -d: -f1)
FIRST_TEXT=$(grep -n '"kind": *"text"' "$T/off.sse" | head -n1 | cut -d: -f1)
if [ -n "$FIRST_VOICE" ] && [ -n "$FIRST_TEXT" ] \
        && [ "$FIRST_TEXT" -lt "$FIRST_VOICE" ]; then
    ok "and no clip preceded its block's completion"
else
    fail "and no clip preceded its block's completion" \
         "first voice at line ${FIRST_VOICE:-none}, first text at ${FIRST_TEXT:-none}"
fi

check_eq "the display half never reached the synthesiser here either" \
    "$(sandbox_count_in 'never voiced\|DISPLAY' "$T/synth-off.log")" "0"

DONE_LINE=$(grep '"kind": *"done"' "$T/off.sse" | head -n1)
case "$DONE_LINE" in
  *'"audio": ""'*)
    ok "the completion audio is empty, exactly as today" ;;
  *)
    fail "the completion audio is empty, exactly as today" \
         "done event: ${DONE_LINE:-none}" ;;
esac

# --- the flag on, against the re-emit shapes -------------------------------
echo "== flag on: a re-emitted message and a duplicated event add nothing =="

echo "replay" > "$T/streammode"
: > "$T/synth-on.log"
turn "$PORT_ON" ccc333 "$T/replay.sse"

sse_texts "$T/replay.sse" voice > "$T/replay.voice"
check_eq "one clip, though the message streamed twice and completed thrice" \
    "$(cat "$T/replay.voice")" "Spoken half stays spoken."
