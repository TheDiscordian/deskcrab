#!/bin/bash
# A phone turn is never silent, and never says itself twice.
# Run: bash tests/test_phone_voice_fallback.sh
#
# On 2026-08-08 two phone replies were composed, logged and displayed, and
# nothing came out of the speakers: the per-block synthesis failed and the
# completion event hard-coded an empty audio field, so the reply clip `crab
# remote` had already made sat on disk unplayed. Every failure path on that
# route was silent as well, so afterwards there was nothing to read.
#
# specs/phone.md rules 6 and 17 are the contract this holds:
#
#   the failing turn   no streaming clip was voiced, so the completion event
#                      MUST carry the turn's own reply clip, and the failed
#                      synthesis MUST leave a line in the server log.
#   the working turn   clips were voiced, so the completion audio MUST be
#                      empty — a client that heard the blocks is not made to
#                      sit through the whole reply a second time.
#
# One real serve.py, one real socket, and a stub `crab` whose synth arm is
# switched between the two turns by a mode file.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'

SECRET="testsecret"
# A port nobody else is on; phone_live 18723, watch_rewrite 18724,
# wedge 18725, done_after_exit 18726.
PORT=18727

echo "broken" > "$T/synthmode"

# --- the stub `crab` -------------------------------------------------------
#
# `synth` is the per-block synthesiser the Speaker thread calls; `remote` is
# the turn itself, which streams one text block and then prints its reply with
# the whole-reply clip attached — the clip that is the fallback. The clip is
# written into TMPDIR under the served name shape, because that is where the
# /audio route reads from and the sandbox has moved TMPDIR into its own root.
cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth)
    if [ "$(cat "$SYNTHMODE")" = "broken" ]; then
        : > "$2"                       # the husk a dead pipeline leaves
        echo "piper: no such voice" >&2
        exit 1
    fi
    printf 'STREAMED-CLIP-BYTES%.0s' $(seq 1 20) > "$2"
    exit 0 ;;
  remote) ;;
  *) exit 1 ;;
esac
LOG="${DESKCRAB_REMOTE_LOG:?stub: no DESKCRAB_REMOTE_LOG}"
: > "$LOG"
python3 -c 'import json;print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"A REPLY THAT WANTS SAYING"}]}}))' >> "$LOG"
CLIP="$TMPDIR/deskcrab-remote-$RANDOM$RANDOM.opus"
printf 'WHOLE-REPLY-CLIP-BYTES%.0s' $(seq 1 20) > "$CLIP"
python3 -c 'import json,sys;print(json.dumps({"spoken":"A REPLY THAT WANTS SAYING","display":"","audio":sys.argv[1],"error":""}))' "$CLIP"
exit 0
STUB
chmod +x "$T/crab"

# --- the server ------------------------------------------------------------
DESKCRAB_SERVE_SECRET="$SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 \
DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_CRAB_BIN="$T/crab" \
DESKCRAB_STATE_PREFIX="$T/deskcrab" \
SYNTHMODE="$T/synthmode" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 \
    || die "the server never came up" "$(cat "$T/server.log")"

turn() {  # <turn id> <sse file>
    curl -sS -N -m 40 \
        -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"text\":\"hello\",\"turn\":\"$1\"}" \
        "http://127.0.0.1:$PORT/say" > "$2" 2>"$T/curl.err"
}

# --- the turn whose streaming synthesis died -------------------------------
echo "== a turn that could not voice its blocks still hands over a clip =="

turn deadbeef01 "$T/broken.sse"
DONE_LINE=$(grep '"kind": *"done"' "$T/broken.sse" | head -n1)

[ -n "$DONE_LINE" ] \
    && ok "a completion event arrived" \
    || die "a completion event arrived" "$(cat "$T/broken.sse")"

check_eq "no voice event was emitted (synthesis failed)" \
    "$(sandbox_count_in '"kind": *"voice"' "$T/broken.sse")" "0"

case "$DONE_LINE" in
  *'"audio": "/audio/deskcrab-remote-'*)
    ok "and it carries the turn's own reply clip instead of silence" ;;
  *)
    fail "and it carries the turn's own reply clip instead of silence" \
         "done event: $DONE_LINE" ;;
esac

# The pointer has to be fetchable, not merely well-shaped: a 404 here is the
# same silence with a hopeful URL in front of it.
CLIP_URL=$(printf '%s' "$DONE_LINE" \
    | python3 -c 'import json,sys;print(json.loads(sys.stdin.read().split("data: ",1)[1])["audio"])')
#
# The emptiness check is not redundant with the assertion above: an empty
# pointer makes the URL the server's ROOT, which answers 200 with the page
# and would have read as a fetched clip.
if [ -n "$CLIP_URL" ] && curl -fsS -m 5 -H "X-Crab-Key: $SECRET" \
        "http://127.0.0.1:$PORT$CLIP_URL" > "$T/fetched.opus" 2>/dev/null \
        && [ -s "$T/fetched.opus" ]; then
    ok "and the clip actually comes back down the audio route"
else
    fail "and the clip actually comes back down the audio route" \
         "GET $CLIP_URL returned nothing"
fi

grep -q "synthesis produced nothing" "$T/server.log" \
    && ok "and the failed synthesis named itself in the log" \
    || fail "and the failed synthesis named itself in the log" \
            "$(tail -5 "$T/server.log")"

grep -q "no such voice" "$T/server.log" \
    && ok "with the synthesiser's own complaint carried through" \
    || fail "with the synthesiser's own complaint carried through" \
            "$(tail -5 "$T/server.log")"

# --- the turn that voiced its blocks normally ------------------------------
echo "== a turn that spoke as it went is not made to speak again =="

echo "working" > "$T/synthmode"
turn deadbeef02 "$T/working.sse"
DONE_LINE=$(grep '"kind": *"done"' "$T/working.sse" | head -n1)

check_eq "the block was voiced as it streamed" \
    "$(sandbox_count_in '"kind": *"voice"' "$T/working.sse")" "1"

case "$DONE_LINE" in
  *'"audio": ""'*)
    ok "and the completion event offers no second copy of it" ;;
  *)
    fail "and the completion event offers no second copy of it" \
         "done event: ${DONE_LINE:-none}" ;;
esac

check_eq "no synthesis failure was logged for the working turn" \
    "$(sandbox_count_in 'synthesis produced nothing' "$T/server.log")" "1"
