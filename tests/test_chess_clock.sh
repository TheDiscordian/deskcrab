#!/bin/bash
# The chess clock (specs/chessweb.md rule 22): a game created with a time
# control carries per-side remaining milliseconds and the turn stamp on its
# own record, every move-recording path charges it through the one
# implementation, a fallen flag is a finished game to every reader the moment
# the wall clock says so, and the bridge — never the client, never her — is
# what records the fall, tells every board, and books the end-of-game wake.
# Run: bash tests/test_chess_clock.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"

# Read-only use of a live path: an interpreter, not state — the same bargain
# test_chessweb.sh strikes. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

export DESKCRAB_CHESS_DIR="$SANDBOX/chess-games"
export DESKCRAB_CHESS_REFLEX_DB="$DESKCRAB_CHESS_DIR/reflex.db"
mkdir -p "$DESKCRAB_CHESS_DIR/games"

chess() { "$VENV_PY" -B "$REPO/lib/chess_cli.py" "$@" 2>&1; }
pyrun() { "$VENV_PY" -B - "$@"; }

# seed_timed <id> <my_side> <control> <white_ms> <black_ms> <started-ago-s> <moves...>
# started-ago-s of "none" leaves turn_started unset.
seed_timed() {
    local gid="$1" side="$2" name="$3" wms="$4" bms="$5" ago="$6"
    shift 6
    GID="$gid" SIDE="$side" TCNAME="$name" WMS="$wms" BMS="$bms" AGO="$ago" \
        MOVES="$*" pyrun <<'PY'
import json, os, time
controls = {"1+0": ("bullet", 60000, 0), "2+1": ("bullet", 120000, 1000),
            "3+2": ("blitz", 180000, 2000), "5+0": ("blitz", 300000, 0)}
speed, base, inc = controls[os.environ["TCNAME"]]
ago = os.environ["AGO"]
g = {"id": os.environ["GID"], "opponent": "guest",
     "my_side": os.environ["SIDE"],
     "moves": os.environ["MOVES"].split(),
     "resigned_by": None, "draw_agreed": False, "engine_level": None,
     "created": "2026-01-01T00:00:00+00:00",
     "updated": "2026-01-01T00:00:00+00:00",
     "time_control": {"name": os.environ["TCNAME"], "speed": speed,
                      "base_ms": base, "inc_ms": inc},
     "clock": {"white_ms": int(os.environ["WMS"]),
               "black_ms": int(os.environ["BMS"]),
               "turn_started": None if ago == "none"
               else time.time() - float(ago)},
     "flag_fell": None}
path = os.path.join(os.environ["DESKCRAB_CHESS_DIR"], "games",
                    g["id"] + ".json")
json.dump(g, open(path, "w"))
PY
}

field() { # <gid> <python expr over g>
    GID="$1" EXPR="$2" pyrun <<'PY'
import json, os
g = json.load(open(os.path.join(os.environ["DESKCRAB_CHESS_DIR"], "games",
                                os.environ["GID"] + ".json")))
print(eval(os.environ["EXPR"]))
PY
}

echo "creation: the control is chosen at new, untimed stays the default:"
out="$(chess new guest --time-control 3+2)"
contains "$out" "time control: 3+2 blitz" \
    && ok "new names the control it dealt" \
    || fail "new said: $out"
check_eq "the record carries the control" \
    "$(field guest-001 'g["time_control"]["name"]')" "3+2"
check_eq "both sides start on the base" \
    "$(field guest-001 '(g["clock"]["white_ms"], g["clock"]["black_ms"])')" \
    "(180000, 180000)"
out="$(chess status guest-001)"
contains "$out" "clock: 3+2 blitz" \
    && ok "status prints the clock line (rule 22f)" \
    || fail "status has no clock line: $out"

out="$(chess new plain)"
check_eq "an untimed game has no clock fields at all" \
    "$(field plain-001 '"time_control" in g or "clock" in g')" "False"
out="$(chess status plain-001)"
contains "$out" "clock:" \
    && fail "untimed status grew a clock line: $out" \
    || ok "untimed status is exactly the old behaviour"

out="$(chess new fast --time-control 7+7)"; rc=$?
[ "$rc" -ne 0 ] && contains "$out" "unknown time control" \
    && ok "a control outside the standard set is refused" \
    || fail "7+7 was accepted: rc=$rc $out"

echo "charging: both first moves free, then think time off and increment on:"
chess move guest-001 e4 >/dev/null
chess move guest-001 e5 >/dev/null
check_eq "neither side's first move was charged or credited (rule 22a)" \
    "$(field guest-001 '(g["clock"]["white_ms"], g["clock"]["black_ms"])')" \
    "(180000, 180000)"
check_eq "the turn stamp restarted all the same" \
    "$(field guest-001 'g["clock"]["turn_started"] is not None')" "True"

# White's SECOND move, three seconds into the turn: the think comes off,
# the 1s increment goes back on. The CLI takes a moment to start, so the
# bound is one-sided-generous: at least the seeded 3s were paid.
seed_timed charge-001 black 2+1 120000 120000 3 e2e4 e7e5
chess move charge-001 d4 >/dev/null
wms="$(field charge-001 'g["clock"]["white_ms"]')"
[ "$wms" -le 118000 ] && [ "$wms" -ge 100000 ] \
    && ok "the mover paid their think and earned the increment ($wms ms)" \
    || fail "white_ms after a 3s think on 2+1" "$wms"
check_eq "the opponent's clock did not move" \
    "$(field charge-001 'g["clock"]["black_ms"]')" "120000"

echo "the fall: a spent clock is a finished game to every reader, live:"
seed_timed flag-001 black 1+0 500 60000 10 e2e4 e7e5 g1f3 b8c6
out="$(chess status flag-001)"
contains "$out" "white lost on time — black wins" \
    && contains "$out" "[0-1]" \
    && ok "status derives the loss on time with no write (rule 22b)" \
    || fail "status on a fallen flag: $out"
out="$(chess move flag-001 d4)"; rc=$?
[ "$rc" -ne 0 ] && contains "$out" "is over" \
    && ok "a move after the fall is refused like any finished board" \
    || fail "move after the flag: rc=$rc $out"
check_eq "and nothing was written by the refusal" \
    "$(field flag-001 'g["flag_fell"]')" "None"
out="$(chess list)"
contains "$out" "1+0" && contains "$out" "untimed" \
    && ok "list splits the record by variant (rule 22e)" \
    || fail "list columns: $out"

echo "undo reopens a recorded flag exactly like a resignation (rule 22g):"
GID=flag-001 pyrun <<'PY'
import json, os
p = os.path.join(os.environ["DESKCRAB_CHESS_DIR"], "games", "flag-001.json")
g = json.load(open(p))
g["flag_fell"] = "white"
g["clock"]["white_ms"] = 30000   # reopened with what they had
json.dump(g, open(p, "w"))
PY
out="$(chess undo flag-001)"
contains "$out" "undid the game-ending agreement" \
    && ok "undo cleared the recorded fall without touching the moves" \
    || fail "undo on a recorded flag: $out"
out="$(chess status flag-001)"
contains "$out" "to move" \
    && ok "the reopened game is active again" \
    || fail "status after the undo: $out"

echo "the twins agree, and a winner who cannot mate gets a draw (rule 22d):"
REPO_LIB="$REPO/lib" pyrun <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["REPO_LIB"])
import chess, chess_cli, chess_reflex
g = {"id": "x", "moves": ["e2e4", "e7e5", "g1f3", "b8c6"], "my_side": "black",
     "resigned_by": None, "draw_agreed": False,
     "time_control": {"name": "1+0", "speed": "bullet",
                      "base_ms": 60000, "inc_ms": 0},
     "clock": {"white_ms": 500, "black_ms": 60000,
               "turn_started": time.time() - 10}}
b = chess_cli.build_board(g)
assert chess_cli.compute_state(g, b)[2] == "0-1", chess_cli.compute_state(g, b)
assert chess_reflex.game_result(g, b) == "0-1"
g2 = dict(g, id="y", moves=[], flag_fell="white",
          clock={"white_ms": 0, "black_ms": 60000,
                 "turn_started": time.time()})
b2 = chess.Board("4k3/8/8/8/8/8/8/QQQ1K3 w - - 0 1")  # winner is a bare king
assert chess_cli.compute_state(g2, b2)[2] == "1/2-1/2", \
    chess_cli.compute_state(g2, b2)
assert "insufficient material" in chess_cli.compute_state(g2, b2)[1]
assert chess_reflex.game_result(g2, b2) == "1/2-1/2"
# an already-mated board never flags, however stale the stamp
g3 = dict(g, id="z", moves=["f2f3", "e7e5", "g2g4", "d8h4"],
          clock={"white_ms": 500, "black_ms": 60000,
                 "turn_started": time.time() - 99})
b3 = chess_cli.build_board(g3)
assert chess_cli.compute_state(g3, b3)[0] == "checkmate"
assert chess_cli.flag_fallen(g3, b3) is None
print("twins agree; mate outranks a stale stamp")
PY
[ $? -eq 0 ] && ok "compute_state and game_result read the same fall" \
    || fail "the flag twins disagree"

echo "the bridge records the fall, tells the board, and books the wake:"
CLIENT="$SANDBOX/client"
mkdir -p "$CLIENT"
printf '%s\n' '<html><input id="serveraddr" value="127.0.0.1:8181"></html>' \
    > "$CLIENT/index.html"
WAKE_STUB="$SANDBOX/wake-stub"
cat > "$WAKE_STUB" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CHESSWEB_WAKE_LOG"
SH
chmod +x "$WAKE_STUB"
MOVER_STUB="$SANDBOX/mover-stub"
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$MOVER_STUB"
chmod +x "$MOVER_STUB"

BRIDGE_PID=""
PORT=""
start_bridge() { # <wake log> [serve args...]
    local wakelog="$1"
    shift
    : > "$wakelog"
    : > "$SANDBOX/serve.log"
    DESKCRAB_CHESS_DIR="$DESKCRAB_CHESS_DIR" CHESSWEB_WAKE_LOG="$wakelog" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$CLIENT" --poll 0.2 "$@" \
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
sandbox_at_exit 'stop_bridge'

# An untimed game answers /state with null clock fields: the old page and
# the old wire, byte for byte.
seed_timed still-001 black 1+0 60000 60000 none e2e4
GID=still-001 pyrun <<'PY'
import json, os
p = os.path.join(os.environ["DESKCRAB_CHESS_DIR"], "games", "still-001.json")
g = json.load(open(p))
del g["time_control"], g["clock"], g["flag_fell"]
json.dump(g, open(p, "w"))
PY
if start_bridge "$SANDBOX/wake-untimed.log" --game still-001; then
    PORT="$PORT" pyrun <<'PY'
import json, os, urllib.request
port = os.environ["PORT"]
st = json.loads(urllib.request.urlopen(
    f"http://127.0.0.1:{port}/state", timeout=10).read())
assert st["time_control"] is None and st["clock"] is None, st
print("  ok: /state answers null control and clock for an untimed game")
PY
    [ $? -eq 0 ] && ok "untimed /state carries no clock" \
        || fail "untimed /state grew clock fields"
fi
stop_bridge

# The timed game: the user (white) is to move with eight seconds, nobody
# presses anything, and the SERVER calls the flag — records it, broadcasts
# GameComplete, books the end-of-game wake. Her reflex and mover are never
# consulted: it is not her move.
seed_timed fall-001 black 1+0 8000 60000 0 e2e4 e7e5 g1f3 b8c6
if start_bridge "$SANDBOX/wake-fall.log" --game fall-001; then
    PORT="$PORT" REPO="$REPO" pyrun <<'PY'
import json, os, sys, urllib.request
sys.path.insert(0, os.path.join(os.environ["REPO"], "tests", "lib"))
import chessweb_scenario as cs
port = int(os.environ["PORT"])
c = cs.Client(port)
c.join()
c.expect(cs.PLAYER)
c.expect(cs.OPPONENT_JOINED)
c.expect(cs.TEAM)
for _ in range(4):
    t, _p = c.recv()
    assert t == cs.MOVE, t
print("  ok: the seat joined onto the live timed game")
st = json.loads(urllib.request.urlopen(
    f"http://127.0.0.1:{port}/state", timeout=10).read())
assert st["time_control"]["name"] == "1+0", st["time_control"]
ck = st["clock"]
assert ck and ck["running"] == "white" and 0 < ck["white_ms"] <= 8000, ck
assert ck["black_ms"] == 60000, ck
print("  ok: /state carries the live clock, the running side deducted")
f = c.expect(cs.GAME_COMPLETE, timeout=20)
assert f.get(1, 0) == 1, f  # white flagged: BlackWin
print("  ok: GameComplete arrived with the loss on time, unprompted")
st = json.loads(urllib.request.urlopen(
    f"http://127.0.0.1:{port}/state", timeout=10).read())
assert st["state"] == "flag" and "lost on time" in st["desc"], st
assert st["clock"]["white_ms"] == 0 and st["clock"]["running"] is None, \
    st["clock"]
print("  ok: /state shows the flagged side at zero, nothing running")
PY
    if [ $? -eq 0 ]; then
        ok "the browser was told about the fall by the server alone"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
        fail "the bridge scenario failed"
    fi
    check_eq "the fall was recorded onto the game file (rule 22c)" \
        "$(field fall-001 'g["flag_fell"]')" "white"
    grep -q "flag fell" "$SANDBOX/wake-fall.log" \
        && ok "the end-of-game wake names the fall" \
        || fail "no flag wake booked: $(cat "$SANDBOX/wake-fall.log")"
    n="$(sandbox_count_in 'flag fell' "$SANDBOX/wake-fall.log")"
    check_eq "and it was booked exactly once" "$n" "1"
fi
stop_bridge

echo "the ledger reads the variant: the flagged game lands as a timed win:"
pyrun <<'PY'
import os, sqlite3
db = os.environ["DESKCRAB_CHESS_REFLEX_DB"]
rows = list(sqlite3.connect(db).execute(
    "SELECT result, my_outcome, control FROM games WHERE game_id='fall-001'"))
assert rows == [("0-1", "win", "1+0")], rows
print("  ok: games row:", rows[0])
PY
[ $? -eq 0 ] \
    && ok "reflex ingested the timed result with its control (rule 22e)" \
    || fail "the reflex games table has no timed fall-001 row"

echo "the bridge stamps a NEW game with the serve's control:"
pyrun <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["DESKCRAB_SANDBOX_REPO"], "lib"))
import chessweb
s = chessweb.Store("fresh", "white", time_control="5+0")
g = s.create()
assert g["time_control"]["name"] == "5+0", g
assert g["clock"] == {"white_ms": 300000, "black_ms": 300000,
                      "turn_started": None}, g["clock"]
p = os.path.join(os.environ["DESKCRAB_CHESS_DIR"], "games",
                 g["id"] + ".json")
assert json.load(open(p))["time_control"]["name"] == "5+0"
print("  ok:", g["id"], "created timed by the store")
PY
[ $? -eq 0 ] && ok "Store.create deals the configured clock" \
    || fail "the bridge's created game carries no control"

echo
echo "the clock bounds the call (rule 16g): budget arithmetic:"
pyrun <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["DESKCRAB_SANDBOX_REPO"], "lib"))
import chess_mover as cm
assert cm.call_budget(None) is None            # no clock: fixed ceiling stands
# the browser-047 board: 98.5s left, fixed 90 — the budget halves the usable
assert abs(cm.call_budget(98.5) - 46.75) < 1e-9, cm.call_budget(98.5)
assert abs(cm.call_budget(30) - 12.5) < 1e-9   # fraction rules a mid clock
assert abs(cm.call_budget(12) - 7.0) < 1e-9    # usable caps below the floor
assert cm.call_budget(4) == 0.0                # inside the reserve: nothing
assert cm.call_budget(-3) == 0.0               # a fallen flag never negative
assert abs(cm.call_budget(300) - 90.0) < 1e-9  # a fat clock: fixed ceiling
os.environ["DESKCRAB_CHESS_MOVER_CLOCK_RESERVE"] = "10"
os.environ["DESKCRAB_CHESS_MOVER_CLOCK_FRACTION"] = "0.25"
os.environ["DESKCRAB_CHESS_MOVER_CLOCK_FLOOR"] = "3"
assert abs(cm.call_budget(50) - 10.0) < 1e-9, cm.call_budget(50)
for k in ("DESKCRAB_CHESS_MOVER_CLOCK_RESERVE",
          "DESKCRAB_CHESS_MOVER_CLOCK_FRACTION",
          "DESKCRAB_CHESS_MOVER_CLOCK_FLOOR"):
    del os.environ[k]
print("  ok: call_budget derives every documented case")
PY
[ $? -eq 0 ] && ok "call_budget: fraction, floor, reserve, fixed ceiling (rule 16g)" \
    || fail "call_budget arithmetic"

echo "a slow call is killed at the budget and a fallback move plays before the flag:"
pyrun <<'PY'
import os, sys, time
sys.path.insert(0, os.path.join(os.environ["DESKCRAB_SANDBOX_REPO"], "lib"))
import chess
import chess_mover as cm
os.environ["DESKCRAB_CHESS_MOVER_CMD"] = "sleep 30"
os.environ["DESKCRAB_CHESS_MOVER_CLOCK_RESERVE"] = "1"
os.environ["DESKCRAB_CHESS_MOVER_CLOCK_FLOOR"] = "1"
played = []
alerts = []
m = cm.Mover(lambda j, mv: played.append((j, mv)) or True,
             log=lambda *a: None, alert=lambda s: alerts.append(s))
board = chess.Board()
t0 = time.time()
m.submit({"key": "t1", "gid": "t-001", "ply": 0, "fen": board.fen(),
          "side": "white", "opponent": "guest", "history": "",
          "clock": {"white_ms": 8000, "black_ms": 8000, "running": "white"},
          "effort": "low", "t0": t0})
assert m.wait_idle(timeout=20), "mover never went idle"
took = time.time() - t0
# budget: usable 7 -> max(1, 3.5) = 3.5s attempt, killed; the retry is not
# affordable, so the fallback plays with clock still in hand.
assert played, "no fallback was played: " + repr(alerts)
job, mv = played[0]
assert mv in board.legal_moves, mv
assert job.get("fallback"), "the job was not marked as a fallback"
assert took < 8, "the answer took the whole clock: %.1fs" % took
assert any("clock-budget" in a for a in alerts), alerts
assert any("fallback" in a for a in alerts), alerts
print("  ok: fallback %s after %.1fs, marked and loud" % (mv.uci(), took))
PY
[ $? -eq 0 ] && ok "the budget kills the call and the fallback lands before the flag" \
    || fail "clock-budget fallback"

echo "no attempt affordable inside the reserve: fallback at once, no call at all:"
pyrun <<'PY'
import os, sys, time
sys.path.insert(0, os.path.join(os.environ["DESKCRAB_SANDBOX_REPO"], "lib"))
import chess
import chess_mover as cm
marker = os.path.join(os.environ["DESKCRAB_CHESS_DIR"], "stub-ran")
os.environ["DESKCRAB_CHESS_MOVER_CMD"] = "touch " + marker
os.environ["DESKCRAB_CHESS_MOVER_CLOCK_RESERVE"] = "2"
played = []
m = cm.Mover(lambda j, mv: played.append((j, mv)) or True,
             log=lambda *a: None, alert=lambda *a: None)
board = chess.Board()
t0 = time.time()
m.submit({"key": "t2", "gid": "t-002", "ply": 0, "fen": board.fen(),
          "side": "white", "opponent": "guest", "history": "",
          "clock": {"white_ms": 2500, "black_ms": 9000, "running": "white"},
          "effort": "low", "t0": t0})
assert m.wait_idle(timeout=15)
assert played and played[0][1] in board.legal_moves
assert played[0][0].get("fallback")
assert not os.path.exists(marker), "a call ran inside the reserve"
print("  ok: no call spawned, fallback", played[0][1].uci())
PY
[ $? -eq 0 ] && ok "inside the reserve no call is made — straight to the fallback" \
    || fail "reserve short-circuit"

echo "an untimed job keeps the fixed ceiling and fails without a fallback:"
pyrun <<'PY'
import os, sys, time
sys.path.insert(0, os.path.join(os.environ["DESKCRAB_SANDBOX_REPO"], "lib"))
import chess
import chess_mover as cm
os.environ["DESKCRAB_CHESS_MOVER_CMD"] = "sleep 30"
os.environ["DESKCRAB_CHESS_MOVER_TIMEOUT"] = "1"
os.environ["DESKCRAB_CHESS_MOVER_RETRY"] = "600"
played = []
m = cm.Mover(lambda j, mv: played.append(mv) or True,
             log=lambda *a: None, alert=lambda *a: None)
board = chess.Board()
m.submit({"key": "t3", "gid": "t-003", "ply": 0, "fen": board.fen(),
          "side": "white", "opponent": "guest", "history": "",
          "effort": "low", "t0": time.time()})
assert m.wait_idle(timeout=15)
n, stalled, why = m.failure_state("t3")
assert not played, "an untimed job played a fallback: %r" % played
assert n == 1 and "timeout-1s" in why, (n, why)
del os.environ["DESKCRAB_CHESS_MOVER_TIMEOUT"]
del os.environ["DESKCRAB_CHESS_MOVER_RETRY"]
print("  ok: failed round, cause", why)
PY
[ $? -eq 0 ] && ok "no clock, no budget: the fixed ceiling and the retry rounds stand" \
    || fail "untimed unaffected"

echo "DESKCRAB_CHESS_MOVER_CLOCK_BUDGET=0 restores the fixed ceiling wholesale:"
pyrun <<'PY'
import os, sys, time
sys.path.insert(0, os.path.join(os.environ["DESKCRAB_SANDBOX_REPO"], "lib"))
import chess
import chess_mover as cm
os.environ["DESKCRAB_CHESS_MOVER_CMD"] = "sleep 30"
os.environ["DESKCRAB_CHESS_MOVER_TIMEOUT"] = "1"
os.environ["DESKCRAB_CHESS_MOVER_CLOCK_BUDGET"] = "0"
os.environ["DESKCRAB_CHESS_MOVER_RETRY"] = "600"
played = []
m = cm.Mover(lambda j, mv: played.append(mv) or True,
             log=lambda *a: None, alert=lambda *a: None)
board = chess.Board()
m.submit({"key": "t4", "gid": "t-004", "ply": 0, "fen": board.fen(),
          "side": "white", "opponent": "guest", "history": "",
          "clock": {"white_ms": 8000, "black_ms": 8000, "running": "white"},
          "effort": "low", "t0": time.time()})
assert m.wait_idle(timeout=15)
n, stalled, why = m.failure_state("t4")
assert not played and n == 1 and "timeout-1s" in why, (played, n, why)
for k in ("DESKCRAB_CHESS_MOVER_TIMEOUT", "DESKCRAB_CHESS_MOVER_CLOCK_BUDGET",
          "DESKCRAB_CHESS_MOVER_RETRY"):
    del os.environ[k]
print("  ok: knob off, old behaviour exactly")
PY
[ $? -eq 0 ] && ok "the budget knob off means the old fixed-ceiling world" \
    || fail "budget knob"

echo "the fallback chooser never hangs a piece the arithmetic can see:"
pyrun <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["DESKCRAB_SANDBOX_REPO"], "lib"))
import chess
import chess_mover as cm
# White to move; Qd5 is attacked by the c6 pawn: taking nothing and standing
# still both exist, and every move the chooser picks must survive the count.
b = chess.Board("r1bqkbnr/pp1ppppp/2p5/3Q4/8/8/PPPP1PPP/RNB1KBNR w KQkq - 0 3")
mv = cm.fallback_move(b)
assert mv in b.legal_moves
assert cm.material_loss(b, mv) == 0, (mv, cm.material_loss(b, mv))
assert cm.worst_reply(b, mv)[0] < 300, (mv, cm.worst_reply(b, mv))
empty = chess.Board("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")  # stalemate: no moves
assert not list(empty.legal_moves) and cm.fallback_move(empty) is None
print("  ok: fallback", mv.uci(), "loses nothing by the count")
PY
[ $? -eq 0 ] && ok "the fallback move survives the exchange count; no-move boards say None" \
    || fail "fallback chooser"
