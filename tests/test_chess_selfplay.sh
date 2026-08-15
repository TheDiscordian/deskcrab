#!/bin/bash
# Chess self-play economics (specs/chess-selfplay.md). The 2026-08-15 night:
# a grind driver inherited the real-game model knob and made ~1,590 calls on
# the dearest model in the house, cooling every account by morning. These
# cases prove the two guards that make that night unrepeatable — self-play
# builds its own model invocation and never reads the real-game knob, and the
# nightly move budget binds both in the driver's loop (a clean stop) and at
# the mover's choke point (the backstop no driver can skip) — and that a real
# game feels none of it.
# Run: bash tests/test_chess_selfplay.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
# The sandbox moves HOME, and a venv is 100MB of install — so the live one is
# borrowed read-only rather than rebuilt per run. Skip if it was never made.
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "SKIP: no chess venv at $VENV — run betty-chess once to bootstrap it"
  exit 0
fi
PY="$VENV/bin/python"

export DESKCRAB_CHESS_DIR="$SANDBOX/chess"
mkdir -p "$DESKCRAB_CHESS_DIR/selfplay" "$DESKCRAB_CHESS_DIR/games"
# The counter is keyed by NIGHT — the date of (now - 12 h) — not by the
# calendar day (specs/chess-selfplay.md rule 4).
COUNTER="$DESKCRAB_CHESS_DIR/selfplay/model-calls-$(date -d '12 hours ago' +%Y%m%d).log"
# A wall a couple of hours ahead keeps every driver run below on the night
# path whatever hour the suite runs at, so the daytime guard never trips
# where it is not the case under test.
NEAR_WALL="$(date -d '+2 hours' +%H:%M)"

# The stub mover: records the call, then answers with the prompt itself —
# the prompt lists every legal move in UCI, and the parser keeps the last
# LEGAL token, so the reply is always a legal move without a model anywhere.
STUB="$SANDBOX/stub-mover"
CALLS="$SANDBOX/stub-calls"
cat > "$STUB" <<EOF
#!/bin/bash
echo called >> "$CALLS"
cat
EOF
chmod +x "$STUB"
export DESKCRAB_CHESS_MOVER_CMD="$STUB"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

echo "the model knob — self-play has its own, and never the user's:"
knob() {  # <selfplay flag> [env pairs...] -> the --model value of the built cmd
  local sp="$1"; shift
  env "$@" "$PY" - "$REPO/lib" "$sp" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
import chess_mover
cmd = chess_mover.Mover._claude_cmd("low", selfplay=(sys.argv[2] == "yes"))
print(cmd[cmd.index("--model") + 1])
PYEOF
}
check_eq "a self-play invocation defaults to sonnet" "$(knob yes)" "sonnet"
check_eq "DESKCRAB_CHESS_SELFPLAY_MODEL is honoured" \
    "$(knob yes DESKCRAB_CHESS_SELFPLAY_MODEL=haiku)" "haiku"
check_eq "the real-game knob does NOT reach a self-play invocation" \
    "$(knob yes DESKCRAB_CHESS_MOVER_MODEL=fable CLAUDE_MODEL=fable)" "sonnet"
check_eq "a real game still follows the mover knob" \
    "$(knob no DESKCRAB_CHESS_MOVER_MODEL=fable)" "fable"

check_eq "a selfplay- game id is self-play" "$("$PY" - "$REPO/lib" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1])
import chess_mover
print(chess_mover.is_selfplay({"gid": "selfplay-007", "opponent": "selfplay"}))
PYEOF
)" "True"
check_eq "a game against a person is not" "$("$PY" - "$REPO/lib" <<'PYEOF'
import sys; sys.path.insert(0, sys.argv[1])
import chess_mover
print(chess_mover.is_selfplay({"gid": "browser-014", "opponent": "a friend"}))
PYEOF
)" "False"

echo
echo "the driver stops cleanly at the nightly move budget:"
OUT="$(DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=5 \
       "$PY" "$REPO/lib/chess_selfplay.py" --budget 120 --games 4 \
       --deadline "$NEAR_WALL" 2>&1)"
STATUS_LINE="$(grep '^STATUS ' <<<"$OUT" | tail -n1)"
contains "$STATUS_LINE" '"status": "budget-spent"' \
    && ok "the chunk ends on budget-spent" \
    || fail "STATUS line: $STATUS_LINE"
check "the counter holds exactly the budget's worth of calls" \
    [ "$(grep -c . "$COUNTER" 2>/dev/null)" -eq 5 ]
check "the stub was called exactly that many times" \
    [ "$(grep -c . "$CALLS" 2>/dev/null)" -eq 5 ]
check "the game the grind played is a selfplay- game" \
    bash -c 'ls "$1"/games/selfplay-*.json >/dev/null 2>&1' _ "$DESKCRAB_CHESS_DIR"

echo
echo "the mover backstop binds whatever is driving, and spares a real game:"
: > "$CALLS"
# The counter already sits at the cap from the run above (5/5 with the same
# budget). A self-play position must be refused without the stub being
# called; a real-game position on the same mover must still answer.
BACK="$(DESKCRAB_CHESS_SELFPLAY_NIGHTLY_MOVES=5 "$PY" - "$REPO/lib" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1])
import chess
import chess_mover

posted = []
def play(job, move):
    posted.append((job["gid"], move.uci()))
    return True

m = chess_mover.Mover(play, log=lambda *a: None, alert=lambda *a: None)
fen = chess.Board().fen()
def job(gid, opp):
    return {"key": gid, "gid": gid, "ply": 0, "fen": fen, "side": "white",
            "opponent": opp, "history": "", "note": "", "effort": "",
            "t0": time.time()}
m.submit(job("selfplay-001", "selfplay"))
m.wait_idle(timeout=30)
n, stalled, why = m.failure_state("selfplay-001")
print("selfplay-why:", why)
m.submit(job("opponent-001", "a friend"))
m.wait_idle(timeout=30)
print("posted:", posted)
PYEOF
)"
contains "$BACK" "selfplay-why: selfplay nightly move budget spent (5/5)" \
    && ok "the self-play position is refused with the budget named" \
    || fail "backstop output: $BACK"
contains "$BACK" "posted: [('opponent-001'" \
    && ok "the real game's position was answered on the same mover" \
    || fail "real game went unanswered: $BACK"
check_eq "the refused self-play position never reached the stub" \
    "$(grep -c . "$CALLS")" "1"
check "and the counter did not move for it" \
    [ "$(grep -c . "$COUNTER")" -eq 5 ]

echo
echo "the games cap creates nothing once the night is full:"
GAMES2="$SANDBOX/chess2"
mkdir -p "$GAMES2"
OUT2="$(DESKCRAB_CHESS_DIR="$GAMES2" \
        "$PY" "$REPO/lib/chess_selfplay.py" --budget 60 --games 0 \
        --deadline "$NEAR_WALL" 2>&1)"
contains "$(grep '^STATUS ' <<<"$OUT2" | tail -n1)" '"status": "games-cap"' \
    && ok "the chunk ends on games-cap" \
    || fail "STATUS line: $(grep '^STATUS ' <<<"$OUT2" | tail -n1)"
refute "no game was created" \
    bash -c 'ls "$1"/games/selfplay-*.json >/dev/null 2>&1' _ "$GAMES2"

echo
echo "the budget window is the night, not the calendar day:"
NK="$("$PY" - "$REPO/lib" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1])
import chess_mover as cm

def at(y, mo, d, h, mi):
    return time.mktime((y, mo, d, h, mi, 0, 0, 1, -1))

print("pre-midnight:", cm.night_key(at(2026, 8, 14, 23, 30)))
print("post-midnight:", cm.night_key(at(2026, 8, 15, 0, 30)))
print("small-hours:", cm.night_key(at(2026, 8, 15, 4, 0)))
print("next-afternoon:", cm.night_key(at(2026, 8, 15, 13, 0)))
PYEOF
)"
contains "$NK" "pre-midnight: 20260814" \
    && contains "$NK" "post-midnight: 20260814" \
    && contains "$NK" "small-hours: 20260814" \
    && ok "23:30, 00:30 and 04:00 across one midnight share the night key" \
    || fail "night keys: $NK"
contains "$NK" "next-afternoon: 20260815" \
    && ok "the next afternoon opens the next night's key" \
    || fail "night keys: $NK"

GT="$("$PY" - "$REPO/lib" <<'PYEOF'
import sys
from datetime import datetime
sys.path.insert(0, sys.argv[1])
import chess_selfplay as sp

tz = datetime.now().astimezone().tzinfo
g = {"created": datetime(2026, 8, 14, 23, 0, tzinfo=tz).isoformat()}
print("same-night:", sp.created_tonight(
    g, now=datetime(2026, 8, 15, 1, 0, tzinfo=tz)))
print("next-night:", sp.created_tonight(
    g, now=datetime(2026, 8, 15, 13, 0, tzinfo=tz)))
PYEOF
)"
contains "$GT" "same-night: True" \
    && contains "$GT" "next-night: False" \
    && ok "a game created before midnight still counts against the same night's games cap" \
    || fail "created_tonight: $GT"

echo
echo "a daytime start is refused, and the night path keeps its walls:"
DL="$("$PY" - "$REPO/lib" <<'PYEOF'
import sys, time
sys.path.insert(0, sys.argv[1])
import chess_selfplay as sp

def at(y, mo, d, h, mi):
    return time.mktime((y, mo, d, h, mi, 0, 0, 1, -1))

wall = "07:00"
print("daytime:", sp.resolve_deadline(at(2026, 8, 14, 14, 0), wall, False))
print("daytime--day:",
      sp.resolve_deadline(at(2026, 8, 14, 14, 0), wall, True)
      == at(2026, 8, 15, 7, 0))
print("evening:",
      sp.resolve_deadline(at(2026, 8, 14, 22, 0), wall, False)
      == at(2026, 8, 15, 7, 0))
print("small-hours:",
      sp.resolve_deadline(at(2026, 8, 15, 2, 0), wall, False)
      == at(2026, 8, 15, 7, 0))
print("just-past:",
      sp.resolve_deadline(at(2026, 8, 15, 7, 30), wall, False)
      == at(2026, 8, 15, 7, 0))
PYEOF
)"
contains "$DL" "daytime: None" \
    && ok "a 14:00 start against a 07:00 wall is refused (not aimed at tomorrow)" \
    || fail "resolve_deadline: $DL"
contains "$DL" "daytime--day: True" \
    && ok "--day makes the same start a deliberate chunk with tomorrow's wall" \
    || fail "resolve_deadline: $DL"
contains "$DL" "evening: True" && contains "$DL" "small-hours: True" \
    && contains "$DL" "just-past: True" \
    && ok "evening, small-hours and just-past-the-wall starts keep their old walls" \
    || fail "resolve_deadline: $DL"

# End to end when the clock allows it: a wall 2 h behind us makes the start
# daytime everywhere except the first two hours after midnight, where no
# HH:MM can sit 1-12 h in the past (the unit cases above still cover it).
if [ "$(date +%H)" -ge 2 ] 2>/dev/null; then
  GAMES3="$SANDBOX/chess3"
  mkdir -p "$GAMES3"
  PAST_WALL="$(date -d '2 hours ago' +%H:%M)"
  OUT3="$(DESKCRAB_CHESS_DIR="$GAMES3" \
          "$PY" "$REPO/lib/chess_selfplay.py" --budget 60 --games 0 \
          --deadline "$PAST_WALL" 2>&1)"; RC3=$?
  contains "$(grep '^STATUS ' <<<"$OUT3" | tail -n1)" '"status": "daytime"' \
      && ok "the driver refuses the daytime start with status daytime" \
      || fail "STATUS line: $(grep '^STATUS ' <<<"$OUT3" | tail -n1)"
  check "and exits non-zero" [ "$RC3" -ne 0 ]
  contains "$OUT3" "Pass --day" \
      && ok "the refusal names the --day flag" \
      || fail "refusal output: $OUT3"
  OUT4="$(DESKCRAB_CHESS_DIR="$GAMES3" \
          "$PY" "$REPO/lib/chess_selfplay.py" --budget 60 --games 0 \
          --deadline "$PAST_WALL" --day 2>&1)"
  contains "$(grep '^STATUS ' <<<"$OUT4" | tail -n1)" '"status": "games-cap"' \
      && ok "with --day the same invocation runs (and stops on its games cap)" \
      || fail "STATUS line: $(grep '^STATUS ' <<<"$OUT4" | tail -n1)"
else
  echo "note: before 02:00 no HH:MM wall sits 1-12 h in the past —" \
       "end-to-end daytime case skipped, unit cases above cover it"
fi
