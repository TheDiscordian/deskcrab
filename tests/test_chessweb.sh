#!/bin/bash
# Tests for chessweb — the browser board onto a betty-chess game
# (specs/chessweb.md). Run: bash tests/test_chessweb.sh
#
# The bridge is started against a scratch store and a stub client directory;
# tests/lib/chessweb_scenario.py speaks to it exactly as the stock SpeedyChess
# page does — masked WebSocket frames, one-byte lengths out, uvarint in — so a
# pass here means the real page would have seen the same bytes. Wakes land in
# a log through $DESKCRAB_CHESSWEB_WAKE_CMD; the live queue is never touched.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
SCENARIO="$REPO/tests/lib/chessweb_scenario.py"

# Read-only use of a live path: an interpreter, not state — the same bargain
# the memory tests strike with their venv. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

# Any directory with an index.html serves; the serveraddr line matches the
# stock page's shape so the rewrite is tested for real.
CLIENT="$SANDBOX/client"
mkdir -p "$CLIENT"
printf '%s\n' '<html><input id="serveraddr" value="127.0.0.1:8181"></html>' \
    > "$CLIENT/index.html"
printf 'stub-wasm' > "$CLIENT/chess.wasm"
printf 'secret' > "$SANDBOX/secret"   # what traversal must never fetch
PORTRAITS="$SANDBOX/portraits"
mkdir -p "$PORTRAITS/living"
printf '\211PNG\r\n\032\nresting' > "$PORTRAITS/resting-2026-08-29.png"
printf '\211PNG\r\n\032\nattentive' > "$PORTRAITS/interrupted-pixel-stable-2026-08-30.png"
printf '\211PNG\r\n\032\nframe' > "$PORTRAITS/living/face-resting.png"
printf '\211PNG\r\n\032\nmask' > "$PORTRAITS/living/motion-test.png"
printf 'not-artwork' > "$SANDBOX/outside-drawer"   # what an escaping id must never fetch
cat > "$PORTRAITS/manifest.json" <<'JSON'
{"version": 1, "revision": "test0001", "size": [420, 420],
 "expressions": {"resting": {"asset": "expr-resting"}},
 "visemes": {},
 "mouth": {"anchor": [27, 16], "rest_extent": [17, 4]},
 "motion": {"root": {"pivot": [210, 420], "sway_deg": 0.55,
                     "sway_period": 7.6, "shift_px": 1.8,
                     "shift_period": 11.0, "breath_scale": 0.0045,
                     "breath_period": 4.2},
            "regions": [{"id": "test-region", "asset": "motion-test",
                         "mode": "pendulum", "pivot": [88, 130],
                         "stiffness": 26, "damping": 3.4,
                         "drive": {"sway": 1.0}, "max_deg": 1.2}]},
 "assets": {"expr-resting": {"file": "living/face-resting.png"},
            "motion-test": {"file": "living/motion-test.png"},
            "escape": {"file": "../outside-drawer"}}}
JSON

WAKE_STUB="$SANDBOX/wake-stub"
cat > "$WAKE_STUB" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CHESSWEB_WAKE_LOG"
SH
chmod +x "$WAKE_STUB"

# The mover's model call, stubbed (specs/chessweb.md rule 16f): the prompt
# arrives on stdin and is kept as evidence; the reply is looked up by
# substring in a per-scenario map, so which position was answered is always
# deterministic — a killed and restarted think can never replay a stale line.
MOVER_STUB="$SANDBOX/mover-stub"
cat > "$MOVER_STUB" <<'SH'
#!/bin/bash
[ -n "${CHESSWEB_MOVER_DELAY:-}" ] && sleep "$CHESSWEB_MOVER_DELAY"
prompt="$(cat)"
printf '%s\n----\n' "$prompt" >> "$CHESSWEB_MOVER_LOG"
[ -f "${CHESSWEB_MOVER_REPLIES:-}" ] || exit 0
while IFS=$'\t' read -r pat reply; do
    [ -n "$pat" ] || continue
    case "$prompt" in *"$pat"*) printf '%s\n' "$reply"; exit 0 ;; esac
done < "$CHESSWEB_MOVER_REPLIES"
exit 0
SH
chmod +x "$MOVER_STUB"

BRIDGE_PID=""
PORT=""
MOVER_LOG=""
REPLIES=""
DELAY=""
# --human-side is pinned to white because the scenarios' colour assertions
# predate the per-game colour choice (the flip, now the alternation);
# a scenario's own args can still override it.
start_bridge() { # <chess dir> <wake log> [serve args...]
    local dir="$1" wakelog="$2"
    shift 2
    : > "$wakelog"
    : > "$SANDBOX/serve.log"
    [ -n "$MOVER_LOG" ] || MOVER_LOG="$SANDBOX/mover-quiet.log"
    [ -n "$REPLIES" ] || REPLIES="$SANDBOX/mover-replies-empty.tsv"
    : > "$MOVER_LOG"
    touch "$REPLIES"
    DESKCRAB_CHESS_DIR="$dir" CHESSWEB_WAKE_LOG="$wakelog" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
        CHESSWEB_MOVER_LOG="$MOVER_LOG" \
        CHESSWEB_MOVER_REPLIES="$REPLIES" \
        CHESSWEB_MOVER_DELAY="$DELAY" \
        DESKCRAB_PORTRAIT_DIR="$PORTRAITS" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$CLIENT" --poll 0.2 --human-side white "$@" \
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
    fail "the bridge never reported its port"
    return 1
}
stop_bridge() {
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null
    wait "$BRIDGE_PID" 2>/dev/null
    BRIDGE_PID=""
}

scn() { # <name> [args...] — one scenario, its own prints as the detail
    local name="$1"
    if timeout 60 "$VENV_PY" -B "$SCENARIO" "$@"; then
        ok "$name"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
        fail "$name"
    fi
}
seed() { "$VENV_PY" -B "$SCENARIO" seed "$@"; }

# The move path's metric stamps (specs/chessweb.md rule 17) land in the
# sandbox-pinned metrics dir; a stage counts when its detail opens as given.
MET="$DESKCRAB_METRICS_DIR/$(date +%F).log"
chess_stamp() { # <stage> <detail prefix>
    awk -F'\t' -v s="$1" -v d="$2" \
        '$3=="chess" && $4==s && index($5, d)==1 {n++} END {exit n?0:1}' \
        "$MET" 2>/dev/null
}

echo "a fresh game — seat, validation, the mover's reply, an observer:"
CH="$SANDBOX/chess-fresh"
MOVER_LOG="$SANDBOX/mover-fresh.log"
REPLIES="$SANDBOX/mover-replies-fresh.tsv"
printf '1. e4\te7e5\n' > "$REPLIES"
DELAY=2   # holds the stub long enough to prove turn enforcement mid-think
if start_bridge "$CH" "$SANDBOX/wake-fresh.log" --opponent guest; then
    scn http "$PORT"
    check_eq "fixed resting portrait route is served" \
        "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/portrait/resting.png")" "200"
    check_eq "unknown portrait names are refused" \
        "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/portrait/unknown.png")" "404"
    check "the manifest names assets by id, never by dated filename (face.md rule 7)" \
        bash -c 'curl -fsS "http://127.0.0.1:$1/face/manifest.json" \
            | grep -q "expr-resting"' _ "$PORT"
    check_eq "a manifest asset id is served" \
        "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/face/asset/expr-resting")" "200"
    check_eq "an id absent from the manifest is refused (face.md rule 12)" \
        "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/face/asset/nope")" "404"
    check_eq "an id whose file escapes the drawer is refused (face.md rule 12)" \
        "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/face/asset/escape")" "404"
    check "a dead broker answers unavailable, never an error (face.md rule 28)" \
        bash -c 'curl -fsS "http://127.0.0.1:$1/face/state" \
            | grep -q "\"available\": false"' _ "$PORT"
    scn fresh "$PORT" "$CH" "$SANDBOX/wake-fresh.log" "$MOVER_LOG"
    check "move-start stamped when e4 made the position hers (rule 17)" \
        chess_stamp move-start "guest-001 ply 1 after e4"
    check "reflex-miss stamped before the model on an unknown position" \
        chess_stamp reflex-miss "guest-001 ply 1"
    check "model-start stamped when the call began, at the quiet effort (low, rule 16b)" \
        chess_stamp model-start "guest-001 ply 1 effort low"
    check "model-end stamped when the call returned" \
        chess_stamp model-end "guest-001 ply 1 "
    check "her reply stamped move-played (model)" \
        chess_stamp move-played "guest-001 ply 1 e5 model"
    check "move-latency stamped: detection to store write, in seconds" \
        chess_stamp move-latency "guest-001 ply 1 "
fi
stop_bridge
MOVER_LOG="" REPLIES="" DELAY=""

echo "a newer position abandons the think in flight — no queue, no stale move:"
CH="$SANDBOX/chess-super"
MOVER_LOG="$SANDBOX/mover-super.log"
REPLIES="$SANDBOX/mover-replies-super.tsv"
printf '1. d4\td7d5\n' > "$REPLIES"
DELAY=4   # long enough for the undo to land while the e4 think is in flight
if start_bridge "$CH" "$SANDBOX/wake-super.log" --opponent guest; then
    scn supersede "$PORT" "$CH" "$MOVER_LOG"
fi
stop_bridge
MOVER_LOG="" REPLIES="" DELAY=""

echo "the overnight property — restart, replay on join, undo resync:"
CH="$SANDBOX/chess-fresh"
if start_bridge "$CH" "$SANDBOX/wake-resume.log" --opponent guest; then
    scn resume "$PORT" "$CH"
fi
stop_bridge

echo "a peer reset is never fatal — mid-request, mid-upgrade, under a broadcast:"
CH="$SANDBOX/chess-reset"
if start_bridge "$CH" "$SANDBOX/wake-reset.log" --opponent guest; then
    scn reset "$PORT" "$CH"
    if kill -0 "$BRIDGE_PID" 2>/dev/null; then
        ok "the bridge outlived every reset"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
        fail "a peer reset killed the bridge"
    fi
    if grep -q "Traceback" "$SANDBOX/serve.log"; then
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
        fail "a roaming peer left tracebacks in the serve log"
    else
        ok "resets logged one line each, no tracebacks"
    fi
    check "a reply through betty-chess still stamps move-played (cli)" \
        chess_stamp move-played "guest-001 ply 1 e5 cli"
fi
stop_bridge

echo "the seat drops and rejoins onto the live game; SIGKILL loses nothing:"
CH="$SANDBOX/chess-rejoin"
if start_bridge "$CH" "$SANDBOX/wake-rejoin.log" --opponent guest; then
    scn rejoin "$PORT" "$CH"
    kill -9 "$BRIDGE_PID" 2>/dev/null      # not even a chance to flush
    wait "$BRIDGE_PID" 2>/dev/null
    BRIDGE_PID=""
    if start_bridge "$CH" "$SANDBOX/wake-postkill.log" --opponent guest; then
        scn postkill "$PORT" "$CH"
    fi
fi
stop_bridge

echo "the wire's special moves, replayed from a seeded history:"
CH="$SANDBOX/chess-special"
seed "$CH" spec-001 guest white \
    e2e4 g7g6 g1f3 f8g7 f1e2 g8f6 e1g1 c7c5 e4e5 d7d5 e5d6
if start_bridge "$CH" "$SANDBOX/wake-special.log" --opponent guest; then
    scn special "$PORT" "$CH"
fi
stop_bridge

echo "promotion — the two-phase pick, refusals, the recorded move:"
CH="$SANDBOX/chess-promo"
seed "$CH" promo-001 guest black \
    b2b4 a7a5 b4a5 b7b6 a5b6 c7c5 b6b7 c5c4
if start_bridge "$CH" "$SANDBOX/wake-promo.log" --opponent guest; then
    scn promote "$PORT" "$CH"
fi
stop_bridge

echo "game end by the user's move:"
CH="$SANDBOX/chess-mate"
seed "$CH" mate-001 guest black \
    e2e4 e7e5 f1c4 b8c6 d1h5 g8f6
if start_bridge "$CH" "$SANDBOX/wake-mate.log" --opponent guest; then
    scn mate "$PORT" "$CH" "$SANDBOX/wake-mate.log"
fi
stop_bridge

echo "resign from the browser; New Game deals the next, colours swapped:"
CH="$SANDBOX/chess-resign"
seed "$CH" resign-001 guest black e2e4 e7e5
if start_bridge "$CH" "$SANDBOX/wake-resign.log" --opponent guest \
        --human-side random; then
    scn resign "$PORT" "$CH" "$SANDBOX/wake-resign.log"
fi
stop_bridge

echo "New Game on a live game creates nothing, and is never silent:"
CH="$SANDBOX/chess-nglive"
seed "$CH" live-001 guest black e2e4
if start_bridge "$CH" "$SANDBOX/wake-nglive.log" --opponent guest; then
    scn newgame_active "$PORT" "$CH"
fi
stop_bridge

echo "game end by her move, noticed in the poll:"
CH="$SANDBOX/chess-fools"
seed "$CH" fools-001 guest black f2f3 e7e5 g2g4
if start_bridge "$CH" "$SANDBOX/wake-fools.log" --opponent guest; then
    scn poller_end "$PORT" "$CH"
fi
stop_bridge

echo "the shipped client page — rewrite, native banner, no injection:"
CH="$SANDBOX/chess-shipped"
if start_bridge "$CH" "$SANDBOX/wake-shipped.log" --opponent guest \
        --client "$REPO/lib/chessweb_client"; then
    scn shipped "$PORT"
    SHIPPED_PAGE="$(curl -fsS "http://127.0.0.1:$PORT/")"
    check "the native page carries her portrait and semantic state" \
        bash -c 'grep -q "/portrait/resting.png" <<<"$1" \
            && grep -q "/portrait/attentive.png" <<<"$1" \
            && grep -q "portrait-state" <<<"$1"' _ "$SHIPPED_PAGE"
    check "the table carries the remembered three-step size control (face.md rule 46)" \
        bash -c 'grep -q "id=\"face-size\"" <<<"$1" \
            && grep -q "face_card.js" <<<"$1"' _ "$SHIPPED_PAGE"
    check "the shared renderer is served with its size persistence" \
        bash -c 'curl -fsS "http://127.0.0.1:$1/face_card.js" \
            | grep -q "FaceCard" \
            && curl -fsS "http://127.0.0.1:$1/face_card.js" \
            | grep -q "localStorage"' _ "$PORT"
    check "thinking state drives the local face hint (face.md rule 31)" \
        bash -c 'grep -q "faceHint(" "$1/lib/chessweb_client/board.js" \
            && grep -q "deskcrab-face-size-chess" "$1/lib/chessweb_client/board.js" \
            && grep -q "classList.toggle(\"expressive\"" "$1/lib/face_card.js"' \
        _ "$REPO"
    check "a long-poll ask against a dead broker still answers at once (rule 50)" \
        bash -c 'timeout 5 curl -fsS "http://127.0.0.1:$1/face/state?after=4" \
            | grep -q "\"available\": false"' _ "$PORT"
    check_eq "a motion-region mask asset is served by its manifest id (face.md rule 52)" \
        "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/face/asset/motion-test")" "200"
    check "the shared renderer carries the motion engine and its channels (face.md rules 51-54)" \
        bash -c 'grep -q "faceRegion" "$1/lib/face_card.js" \
            && grep -q "setMotion" "$1/lib/face_card.js" \
            && grep -q "fireGesture" "$1/lib/face_card.js"' _ "$REPO"
    check "the renderer morphs mouth contours by measured extent (face.md rules 24, 55)" \
        bash -c 'grep -q "extent" "$1/lib/face_card.js" \
            && grep -q "morphScale" "$1/lib/face_card.js"' _ "$REPO"
fi
stop_bridge

echo "a known position is answered from reflex memory, no model call:"
CH="$SANDBOX/chess-reflex"
seed "$CH" rival-001 rival black f2f3 e7e5 g2g4 d8h4
seed "$CH" rival-002 rival black f2f3 e7e5 g2g4 d8h4
DESKCRAB_CHESS_DIR="$CH" PYTHONDONTWRITEBYTECODE=1 \
    "$VENV_PY" -B "$REPO/lib/chess_cli.py" reflex --backfill >/dev/null
MOVER_LOG="$SANDBOX/mover-reflex.log"
if start_bridge "$CH" "$SANDBOX/wake-reflex.log" --opponent guest; then
    scn reflex "$PORT" "$CH" "$SANDBOX/wake-reflex.log" "$MOVER_LOG"
    if grep -q "reflex played" "$SANDBOX/serve.log"; then
        ok "the serve log says the moves came from memory, not thought"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
        fail "no 'reflex played' line in the serve log"
    fi
    check "reflex-hit stamped with the remembered move (rule 17)" \
        chess_stamp reflex-hit "guest-001 ply 1 e7e5"
    check "the memory's answer stamped move-played (reflex)" \
        chess_stamp move-played "guest-001 ply 1 e5 reflex"
    awk -F'\t' '$3=="chess" && $4=="move-latency" \
        && $5 ~ /^guest-001 ply 1 .*reflex$/' "$MET" | grep -q . \
      && ok "move-latency stamped for the reflex answer too" \
      || fail "no reflex-sourced move-latency stamp" \
              "$(grep move-latency "$MET" 2>/dev/null | tail -3)"
fi
stop_bridge
MOVER_LOG=""
