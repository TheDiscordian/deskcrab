#!/bin/bash
# crab-chess: the disk record is the move list, and inference picks the game.
# Run: bash tests/test_chess.sh
#
# The two things that only bite after a game ends. A finished game used to be
# unreachable by the short forms — bare `status` answered "no active games"
# and made you name the game you had just been playing — while `move` must
# still refuse on a board that is over. Both are inference behaviour, so they
# are tested through the real CLI against a scratch games directory.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
CHESS="$REPO/lib/crab-chess"
# The sandbox moves HOME, and a venv is 100MB of install — so the live one is
# borrowed read-only rather than rebuilt per run. Skip if it was never made.
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "SKIP: no chess venv at $VENV — run crab-chess once to bootstrap it"
  exit 0
fi

export DESKCRAB_CHESS_DIR="$SANDBOX/chess-games"
export DESKCRAB_CHESS_VENV="$VENV"

chess() { "$CHESS" "$@" 2>&1; }

# Fool's mate: three plies to a finished game.
chess new opponent >/dev/null
for m in f3 e5 g4 Qh4; do chess move "$m" >/dev/null; done

out="$(chess status)"
echo "$out" | grep -q "checkmate" \
  && ok "a finished game is still inferred by the short forms" \
  || fail "bare status after checkmate: $out"

echo "$out" | grep -q "1. f3 e5 2. g4 Qh4#" \
  && ok "the movetext survives the replay from disk" \
  || fail "history wrong: $out"

out="$(chess move e4)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -qi "is over" \
  && ok "a move onto a finished board is refused" \
  || fail "move after checkmate: rc=$rc $out"

# A live game outranks a finished one when neither is named.
chess new other >/dev/null
chess status | grep -q "other-001" \
  && ok "the active game wins inference over the finished one" \
  || fail "inference picked the finished game while one was live"

# The engine command needs no engine to report that it has none.
out="$(CRAB_CHESS_ENGINE=nosuchengine chess engine other)"
echo "$out" | grep -q "nosuchengine is not on PATH" \
  && ok "a named engine that is absent says so by name" \
  || fail "engine with a bogus CRAB_CHESS_ENGINE: $out"

# And with one present it plays for real. The stub speaks UCI and picks at
# random, so this proves the protocol and the write-back, not the chess.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/stubfish" <<SHIM
#!/bin/sh
exec "$VENV/bin/python" "$REPO/tests/lib/stub-uci-engine.py" "\$@"
SHIM
chmod +x "$SANDBOX/bin/stubfish"
export PATH="$SANDBOX/bin:$PATH"

before="$(chess status other | grep '^fen:')"
out="$(CRAB_CHESS_ENGINE=stubfish chess engine other --level 3)"
echo "$out" | grep -q "engine (skill 3) plays" \
  && ok "a UCI engine named by CRAB_CHESS_ENGINE plays the side to move" \
  || fail "stub engine did not move: $out"

after="$(chess status other | grep '^fen:')"
[ "$before" != "$after" ] \
  && ok "and its move is written to the game on disk" \
  || fail "the board did not change after the engine moved"

chess status other | grep -q "engine level: 3" \
  && ok "the skill level given once is remembered" \
  || fail "engine level was not persisted"
