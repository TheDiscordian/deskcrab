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

WAKE_STUB="$SANDBOX/wake-stub"
cat > "$WAKE_STUB" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CHESSWEB_WAKE_LOG"
SH
chmod +x "$WAKE_STUB"

BRIDGE_PID=""
PORT=""
start_bridge() { # <chess dir> <wake log> [serve args...]
    local dir="$1" wakelog="$2"
    shift 2
    : > "$wakelog"
    : > "$SANDBOX/serve.log"
    DESKCRAB_CHESS_DIR="$dir" CHESSWEB_WAKE_LOG="$wakelog" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$CLIENT" --poll 0.2 "$@" >> "$SANDBOX/serve.log" 2>&1 &
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

echo "a fresh game — seat, validation, the wake, her reply, an observer:"
CH="$SANDBOX/chess-fresh"
if start_bridge "$CH" "$SANDBOX/wake-fresh.log" --opponent guest; then
    scn http "$PORT"
    scn fresh "$PORT" "$CH" "$SANDBOX/wake-fresh.log"
fi
stop_bridge

echo "the overnight property — restart, replay on join, undo resync:"
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

echo "game end by her move, noticed in the poll:"
CH="$SANDBOX/chess-fools"
seed "$CH" fools-001 guest black f2f3 e7e5 g2g4
if start_bridge "$CH" "$SANDBOX/wake-fools.log" --opponent guest; then
    scn poller_end "$PORT" "$CH"
fi
stop_bridge

echo "a known position is answered from reflex memory, not a wake:"
CH="$SANDBOX/chess-reflex"
seed "$CH" rival-001 rival black f2f3 e7e5 g2g4 d8h4
seed "$CH" rival-002 rival black f2f3 e7e5 g2g4 d8h4
DESKCRAB_CHESS_DIR="$CH" PYTHONDONTWRITEBYTECODE=1 \
    "$VENV_PY" -B "$REPO/lib/chess_cli.py" reflex --backfill >/dev/null
if start_bridge "$CH" "$SANDBOX/wake-reflex.log" --opponent guest; then
    scn reflex "$PORT" "$CH" "$SANDBOX/wake-reflex.log"
    if grep -q "reflex played" "$SANDBOX/serve.log"; then
        ok "the serve log says the moves came from memory, not thought"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
        fail "no 'reflex played' line in the serve log"
    fi
fi
stop_bridge
