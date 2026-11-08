#!/bin/bash
# The table chat's quiet bias after recent speech — specs/chessweb.md rule
# 24d.
# Run: bash tests/test_chess_chat_pacing.sh
#
# The contract under test, fully stubbed (no model call anywhere). The
# decision is HERS on every trigger — nothing is ever dropped — and the
# bias lives in the prompt:
#
#   1. A move trigger landing within the window of her last POSTED message
#      carries the recent-speech line; the trigger still runs.
#   2. A player message inside the window carries no line — an answer owed
#      is not a quip — and neither does a move trigger outside the window
#      or in a game where she has not spoken.
#   3. DESKCRAB_CHESS_CHAT_MOVE_COOLDOWN=0 disables the line entirely.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
    echo "SKIP: no chess venv at $VENV — the chat rides the mover's machinery"
    exit 0
fi

STUB="$T/bin/chat-stub"
cat > "$STUB" <<'STUB'
#!/bin/bash
cat > "$CHAT_PROMPT_WITNESS"
echo "A word about that."
STUB
chmod +x "$STUB"

PYOUT="$(env DESKCRAB_CHESS_CHAT_CMD="$STUB" \
    CHAT_PROMPT_WITNESS="$T/witness-prompt" \
    DESKCRAB_CHESS_DIR="$T/chess-games" \
    "$PY" -B - <<PYEOF
import os, sys
sys.path.insert(0, "$REPO/lib")
import chess, chess_chat

LINE = "the bar for another unprompted quip"

def job(why, ply, spoke_ago=None):
    j = {"gid": "pace-1", "ply": ply, "player": "Visitor",
         "side": "white", "event": "Visitor played d4.", "why": why,
         "fen": chess.STARTING_FEN, "history": "1. d4",
         "record_line": "", "chat_tail": [], "prev_tail": []}
    if spoke_ago is not None:
        j["spoke_ago"] = spoke_ago
    return j

# -- the prompt line itself --------------------------------------------------
print("line-on-recent-move:",
      LINE in chess_chat.build_prompt(job("her-move", 4, spoke_ago=42)))
print("names-the-seconds:",
      "only 42 seconds ago" in chess_chat.build_prompt(
          job("their-move", 4, spoke_ago=42)))
print("no-line-on-said:",
      LINE not in chess_chat.build_prompt(job("said", 4, spoke_ago=42)))
print("no-line-when-quiet:",
      LINE not in chess_chat.build_prompt(job("her-move", 4)))
print("no-line-outside-window:",
      LINE not in chess_chat.build_prompt(
          job("her-move", 4, spoke_ago=9999)))
os.environ["DESKCRAB_CHESS_CHAT_MOVE_COOLDOWN"] = "0"
print("knob-zero-disables:",
      LINE not in chess_chat.build_prompt(job("her-move", 4, spoke_ago=1)))
del os.environ["DESKCRAB_CHESS_CHAT_MOVE_COOLDOWN"]

# -- through the worker: she still runs, the line rides, nothing drops -------
posted, metrics = [], []
c = chess_chat.ChessChat(lambda job, text: posted.append(text) or True,
                         log=lambda *a, **k: None,
                         metric=lambda stage, detail="": metrics.append(stage))
c.trigger(job("their-move", 1)); c.wait_idle()
first = open("$T/witness-prompt").read()
print("first-runs-bare:", len(posted) == 1 and LINE not in first)
c.trigger(job("her-move", 2)); c.wait_idle()
second = open("$T/witness-prompt").read()
print("second-still-runs:", len(posted) == 2)
print("second-carries-line:", LINE in second)
print("nothing-throttled:", "chat-throttled" not in metrics)
PYEOF
)"
echo "$PYOUT" | sed 's/^/    /'

contains "$PYOUT" "line-on-recent-move: True" \
    && ok "a move trigger after recent speech carries the recent-speech line" \
    || fail "recent line" "$(printf '%s\n' "$PYOUT" | grep line-on-recent)"
contains "$PYOUT" "names-the-seconds: True" \
    && ok "and the line names how recently she spoke" \
    || fail "seconds" "$(printf '%s\n' "$PYOUT" | grep names-the-seconds)"
contains "$PYOUT" "no-line-on-said: True" \
    && ok "a player message never carries it — an answer owed is not a quip" \
    || fail "said line" "$(printf '%s\n' "$PYOUT" | grep no-line-on-said)"
contains "$PYOUT" "no-line-when-quiet: True" \
    && ok "no line in a game where she has not spoken" \
    || fail "quiet" "$(printf '%s\n' "$PYOUT" | grep no-line-when-quiet)"
contains "$PYOUT" "no-line-outside-window: True" \
    && ok "no line once the window has lapsed" \
    || fail "window" "$(printf '%s\n' "$PYOUT" | grep no-line-outside)"
contains "$PYOUT" "knob-zero-disables: True" \
    && ok "cooldown 0 disables the line entirely" \
    || fail "knob zero" "$(printf '%s\n' "$PYOUT" | grep knob-zero)"
contains "$PYOUT" "first-runs-bare: True" \
    && ok "through the worker: the first quip runs with no line" \
    || fail "first run" "$(printf '%s\n' "$PYOUT" | grep first-runs-bare)"
contains "$PYOUT" "second-still-runs: True" \
    && ok "the next move trigger still runs — the decision is hers" \
    || fail "second run" "$(printf '%s\n' "$PYOUT" | grep second-still-runs)"
contains "$PYOUT" "second-carries-line: True" \
    && ok "and its prompt carries the recent-speech line" \
    || fail "second line" "$(printf '%s\n' "$PYOUT" | grep second-carries-line)"
contains "$PYOUT" "nothing-throttled: True" \
    && ok "nothing was ever dropped" \
    || fail "throttle" "$(printf '%s\n' "$PYOUT" | grep nothing-throttled)"
