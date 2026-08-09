#!/bin/bash
# betty-chess: the disk record is the move list, and inference picks the game.
# Run: bash tests/test_chess.sh
#
# The two things that only bite after a game ends. A finished game used to be
# unreachable by the short forms — bare `status` answered "no active games"
# and made you name the game you had just been playing — while `move` must
# still refuse on a board that is over. Both are inference behaviour, so they
# are tested through the real CLI against a scratch games directory.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
CHESS="$REPO/lib/betty-chess"
# The sandbox moves HOME, and a venv is 100MB of install — so the live one is
# borrowed read-only rather than rebuilt per run. Skip if it was never made.
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "SKIP: no chess venv at $VENV — run betty-chess once to bootstrap it"
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

# --- the ply guard --------------------------------------------------------
# A wake carrying a position is a photograph, and the game can move on between
# the shutter and the move. --expect-ply is the caller saying which board it
# thought it was answering.
chess new stale >/dev/null
for m in e4 e5 Nf3; do chess move stale "$m" >/dev/null; done

chess status stale | grep -q "ply 3" \
  && ok "status names the ply, so the caller can quote it back" \
  || fail "status has no ply: $(chess status stale)"

out="$(chess move stale Nc6 --expect-ply 3)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "played Nc6" \
  && ok "a move with the right expectation is played as normal" \
  || fail "correct --expect-ply was refused: rc=$rc $out"

# Two more plies land while our imaginary caller is still thinking at ply 4.
chess move stale Bc4 >/dev/null; chess move stale Bc5 >/dev/null

out="$(chess move stale Nxe5 --expect-ply 4)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "the board has moved on" \
  && ok "a move answering a stale board is refused" \
  || fail "stale --expect-ply was played: rc=$rc $out"

echo "$out" | grep -q "Bc4 Bc5" \
  && ok "and the refusal names what was played since" \
  || fail "refusal did not list the moves since: $out"

chess status stale | grep -q "ply 6" \
  && ok "the refused move wrote nothing to the game" \
  || fail "the store moved despite the refusal: $(chess status stale)"

out="$(chess move stale Nxe5 --expect-ply 99)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "never happened" \
  && ok "a ply the game has never reached is refused too" \
  || fail "--expect-ply from the future: rc=$rc $out"

fen="$(chess status stale | sed -n 's/^fen: //p')"
out="$(chess move stale Nxe5 --expect-fen "$fen")"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "the matching FEN is accepted as an expectation" \
  || fail "correct --expect-fen was refused: rc=$rc $out"

out="$(chess move stale Nxe5 --expect-fen "$fen")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "the board has moved on" \
  && ok "and the same FEN one ply later is not" \
  || fail "stale --expect-fen was played: rc=$rc $out"

# The counters are not the position: a caller quoting a FEN with the wrong
# halfmove clock still means the board it can see.
fen="$(chess status stale | sed -n 's/^fen: //p')"
loose="$(echo "$fen" | awk '{print $1, $2, $3, $4, 41, 99}')"
out="$(chess move stale Nxe5 --expect-fen "$loose")"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "the move counters in an expected FEN are ignored" \
  || fail "counters made a matching position look stale: rc=$rc $out"

# --- reflex memory (specs/chess-reflex.md) --------------------------------
# The fool's mate at the top of this file finished a game through the normal
# move path; nothing since has mentioned reflex. If the memory works, that
# game is already in it.
START="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
DB="$DESKCRAB_CHESS_DIR/reflex.db"

out="$(chess reflex "$START")"
[ -f "$DB" ] && echo "$out" | grep -q "^f3 " \
  && ok "a game played to its end entered reflex memory by itself" \
  || fail "recording: db=$([ -f "$DB" ] && echo yes || echo no) out=$out"

# Backfill is the retroactive path: wipe the memory, re-ingest from the game
# files alone. opponent-001 is finished; other-001 and stale-001 are not.
rm -f "$DB"
out="$(chess reflex --backfill)"
echo "$out" | grep -q "ingested 1 finished" \
  && echo "$out" | grep -q "left 2 active" \
  && ok "backfill re-ingested the finished game and left the live ones alone" \
  || fail "backfill: $out"

# Hand-written game files (no save_game involved) are what backfill exists
# for: two more f3 losses and one e4 win, all from white's seat.
seed_game() { # <id> <result-line of ucis...>
  local id="$1"; shift
  cat > "$DESKCRAB_CHESS_DIR/games/$id.json" <<JSON
{"id": "$id", "opponent": "import", "my_side": "white",
 "moves": [$(printf '"%s",' "$@" | sed 's/,$//')],
 "resigned_by": null, "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
}
seed_game import-001 f2f3 e7e5 g2g4 d8h4                       # 0-1
seed_game import-002 f2f3 e7e5 g2g4 d8h4                       # 0-1
seed_game import-003 e2e4 e7e5 f1c4 b8c6 d1h5 g8f6 h5f7        # 1-0
out="$(chess reflex --backfill)"
echo "$out" | grep -q "ingested 4 finished" \
  && ok "backfill picked up game files written by another hand" \
  || fail "retroactive backfill: $out"

# Ranking: f3 has now been played three times and lost every game; e4 once,
# and won. Frequency alone would put f3 first; the results must not.
out="$(chess reflex "$START")"
echo "$out" | head -1 | grep -q "^e4 " \
  && ok "a move that kept losing ranks below one that won less often" \
  || fail "ranking ignored the results: $out"
echo "$out" | grep "^f3 " | grep -q "0-0-3" \
  && ok "and the losing move's W-D-L says why" \
  || fail "f3's tally wrong: $out"

# The gate: one winning game is memory, not confidence.
echo "$out" | grep -q "not confident enough" \
  && ok "one good game is not enough to play from memory" \
  || fail "gate opened on a single game: $out"
seed_game import-004 e2e4 e7e5 f1c4 b8c6 d1h5 g8f6 h5f7        # a second win
chess reflex --backfill >/dev/null
out="$(chess reflex "$START")"
echo "$out" | grep -q "would play e4" \
  && ok "two winning games open the gate: reflex would play e4" \
  || fail "gate stayed shut at two wins: $out"

# Unknown position: the caller must fall through to normal play.
out="$(chess reflex "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "no memory of this position" \
  && ok "an unknown position refuses loudly, so callers fall through" \
  || fail "unknown position: rc=$rc $out"

# An undo reopens a finished game, and its result is no longer true.
chess undo opponent >/dev/null
out="$(chess reflex "$START")"
echo "$out" | grep "^f3 " | grep -q "games   2" \
  && ok "undoing a finished game took its moves back out of memory" \
  || fail "retraction after undo: $out"
