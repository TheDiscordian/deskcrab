#!/bin/bash
# Her voice at the table (specs/chessweb.md rule 24e): the speak toggle's
# clips come from GET /chat/audio — the bridge synthesizes HER recorded
# message through the crab-synth pipeline (stubbed here via
# $DESKCRAB_CHESSWEB_SYNTH_CMD) and answers audio/ogg — and the browser's
# own speechSynthesis narrator is gone from the shipped client entirely.
# Proven here:
#   - an assistant message synthesizes: 200, audio/ogg, the stub's bytes,
#     the text handed to the synth argv, the temp clip cleaned up after
#   - the sitter's keyboard can never borrow her voice: a player-role
#     index is 403, an unknown index 404, a malformed or missing n 400,
#     a mismatched or missing game 409 — nothing synthesized for any
#   - a synthesis failure is 503 with a served log line, never silence
#     without a witness — and never a browser narrator
#   - the shipped client carries no speechSynthesis at all and fetches
#     /chat/audio instead: the regression (2026-08-25, a generic narrator
#     wearing her words) cannot come back silently
# Run: bash tests/test_chess_chat_voice.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"

# Read-only use of a live path: an interpreter, not state — the same bargain
# tests/test_chessweb.sh strikes. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

CLIENT="$SANDBOX/client"
mkdir -p "$CLIENT"
printf '%s\n' '<html><input id="serveraddr" value="127.0.0.1:8181"></html>' \
    > "$CLIENT/index.html"

WAKE_STUB="$SANDBOX/wake-stub"
printf '#!/bin/bash\n:\n' > "$WAKE_STUB"
chmod +x "$WAKE_STUB"

# The synth pipeline, stubbed (chessweb.md rule 24e): argv is the output
# path then the text — exactly the shape `crab synth` is called in. The
# stub records both, writes recognizable bytes, and fails on demand via a
# flag file (the env is the bridge's, frozen at start).
SYNTH_STUB="$SANDBOX/synth-stub"
cat > "$SYNTH_STUB" <<'SH'
#!/bin/bash
out="$1"; shift
printf 'out=%s\ntext=%s\n' "$out" "$*" >> "$CHESSWEB_SYNTH_LOG"
[ -f "$CHESSWEB_SYNTH_FAIL_FLAG" ] && exit 1
printf 'OggSfake-clip:%s' "$*" > "$out"
SH
chmod +x "$SYNTH_STUB"
SYNTH_LOG="$SANDBOX/synth.log"
FAIL_FLAG="$SANDBOX/synth-fail"

# A seeded game with a recorded thread: hers at index 1 and 3, the
# sitter's at 0, an empty-text husk (hand-edited shape) at 2.
CH="$SANDBOX/chess-voice"
"$VENV_PY" -B - "$CH" <<'PY'
import json, os, sys
d = os.path.join(sys.argv[1], "games")
os.makedirs(d, exist_ok=True)
stamp = "2026-01-01T00:00:00+00:00"
game = {"id": "guest-001", "opponent": "guest", "my_side": "black",
        "moves": ["e2e4", "e7e5"], "resigned_by": None,
        "draw_agreed": False, "engine_level": None, "player": "Visitor",
        "created": stamp, "updated": stamp,
        "chat": [
            {"who": "player", "text": "say something rude", "at": stamp,
             "ply": 2},
            {"who": "assistant", "text": "Good luck today.", "at": stamp,
             "ply": 2},
            {"who": "assistant", "text": "   ", "at": stamp, "ply": 2},
            {"who": "assistant", "text": "A fine open game.", "at": stamp,
             "ply": 2}]}
with open(os.path.join(d, "guest-001.json"), "w") as f:
    json.dump(game, f)
PY

BRIDGE_PID=""
PORT=""
start_bridge() { # <chess dir>
    : > "$SANDBOX/serve.log"
    : > "$SYNTH_LOG"
    env DESKCRAB_CHESS_DIR="$1" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        DESKCRAB_CHESS_CHAT=0 DESKCRAB_CHESS_REFLEX=0 \
        DESKCRAB_CHESSWEB_SYNTH_CMD="$SYNTH_STUB" \
        CHESSWEB_SYNTH_LOG="$SYNTH_LOG" \
        CHESSWEB_SYNTH_FAIL_FLAG="$FAIL_FLAG" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$CLIENT" --poll 0.2 --human-side white --opponent guest \
        >> "$SANDBOX/serve.log" 2>&1 &
    BRIDGE_PID=$!
    PORT=""
    for _ in $(seq 1 100); do
        PORT="$(sed -n 's/.*on port \([0-9]*\)$/\1/p' "$SANDBOX/serve.log" | head -1)"
        [ -n "$PORT" ] && return 0
        kill -0 "$BRIDGE_PID" 2>/dev/null || break
        sleep 0.1
    done
    sed 's/^/    serve: /' "$SANDBOX/serve.log"
    die "the bridge never reported its port"
}
stop_bridge() {
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null
    wait "$BRIDGE_PID" 2>/dev/null
    BRIDGE_PID=""
}

http_get() { # <path> -> STATUS<tab>CTYPE<tab>BODY (body base64)
    "$VENV_PY" -B - "$PORT" "$1" <<'PY'
import base64, sys, urllib.request, urllib.error
port, path = sys.argv[1], sys.argv[2]
try:
    r = urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10)
    status, ctype, body = r.status, r.headers.get("Content-Type", ""), r.read()
except urllib.error.HTTPError as e:
    status, ctype, body = e.code, e.headers.get("Content-Type", ""), e.read()
print("%s\t%s\t%s" % (status, ctype, base64.b64encode(body).decode()))
PY
}
field() { printf '%s' "$1" | cut -f"$2"; }
body_of() { field "$1" 3 | base64 -d; }

echo "her recorded message comes back as a clip of her own voice:"
start_bridge "$CH"

R="$(http_get '/chat/audio?game=guest-001&n=1')"
check_eq "an assistant message answers 200" "$(field "$R" 1)" 200
check_eq "and is served as audio/ogg" "$(field "$R" 2)" "audio/ogg"
check_eq "and the body is the synthesized clip, byte for byte" \
    "$(body_of "$R")" "OggSfake-clip:Good luck today."
grep -q '^text=Good luck today\.$' "$SYNTH_LOG" \
    && ok "the synth argv carried her recorded text" \
    || fail "the synth argv text is wrong: $(cat "$SYNTH_LOG")"
CLIP_PATH="$(sed -n 's/^out=//p' "$SYNTH_LOG" | head -1)"
[ -n "$CLIP_PATH" ] && [ ! -e "$CLIP_PATH" ] \
    && ok "the temp clip was removed after serving" \
    || fail "the temp clip lingers: ${CLIP_PATH:-no path logged}"

R="$(http_get '/chat/audio?n=3')"
check_eq "the game guard is optional: a bare n synthesizes too" \
    "$(field "$R" 1)" 200

echo "nothing but her own words is ever voiced:"
CALLS_BEFORE="$(grep -c '^out=' "$SYNTH_LOG")"
R="$(http_get '/chat/audio?game=guest-001&n=0')"
check_eq "a player-role message is refused 403" "$(field "$R" 1)" 403
R="$(http_get '/chat/audio?game=guest-001&n=2')"
check_eq "an empty-text record is refused 404, not synthesized" \
    "$(field "$R" 1)" 404
R="$(http_get '/chat/audio?game=guest-001&n=99')"
check_eq "an unknown index is refused 404" "$(field "$R" 1)" 404
R="$(http_get '/chat/audio?game=guest-001&n=-1')"
check_eq "a negative index is refused 404" "$(field "$R" 1)" 404
R="$(http_get '/chat/audio?game=guest-001&n=abc')"
check_eq "a malformed index is refused 400" "$(field "$R" 1)" 400
R="$(http_get '/chat/audio?game=guest-001')"
check_eq "a missing index is refused 400" "$(field "$R" 1)" 400
R="$(http_get '/chat/audio?game=other-999&n=1')"
check_eq "a mismatched game id is refused 409" "$(field "$R" 1)" 409
check_eq "and none of the refusals reached the synthesizer" \
    "$(grep -c '^out=' "$SYNTH_LOG")" "$CALLS_BEFORE"

echo "a synthesis failure answers out loud, never a narrator:"
touch "$FAIL_FLAG"
R="$(http_get '/chat/audio?game=guest-001&n=1')"
check_eq "a failed synth answers 503" "$(field "$R" 1)" 503
body_of "$R" | grep -q 'could not be synthesized' \
    && ok "and says so in the body" \
    || fail "503 body: $(body_of "$R")"
grep -q 'chat clip guest-001#1 failed' "$SANDBOX/serve.log" \
    && ok "and the bridge logged the failure as witness" \
    || fail "no failure line in serve.log"
rm -f "$FAIL_FLAG"
stop_bridge

echo "no game loaded: there is nothing to voice:"
start_bridge "$SANDBOX/chess-empty"
R="$(http_get '/chat/audio?n=0')"
check_eq "an empty store is refused 409" "$(field "$R" 1)" 409
stop_bridge

echo "the shipped client never falls back to a browser narrator:"
BOARD_JS="$REPO/lib/chessweb_client/board.js"
grep -qi 'speechSynthesis\|SpeechSynthesisUtterance' "$BOARD_JS" \
    && fail "board.js still reaches for the browser narrator" \
    || ok "speechSynthesis is gone from board.js"
grep -q '/chat/audio' "$BOARD_JS" \
    && ok "board.js fetches her clip from /chat/audio" \
    || fail "board.js never asks the bridge for her voice"
grep -q "Her voice is unavailable" "$BOARD_JS" \
    && ok "a lost clip says so in the page console instead of speaking" \
    || fail "no out-loud failure line in board.js"
grep -q 'speak toggle' "$REPO/specs/chessweb.md" \
    && grep -q 'never used, not even as a fallback' "$REPO/specs/chessweb.md" \
    && ok "the spec names the no-narrator rule" \
    || fail "specs/chessweb.md does not forbid the narrator fallback"
