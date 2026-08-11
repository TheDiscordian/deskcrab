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

# Her side's CLI moves stamp the move path's metrics (chessweb.md rule 17,
# sandbox-pinned DESKCRAB_METRICS_DIR); the opponent's moves do not. In the
# mate above she was white, so f3 and g4 are hers, e5 and Qh4 are not.
MET="$DESKCRAB_METRICS_DIR/$(date +%F).log"
grep -q "opponent-001 ply 0 f3 cli" "$MET" 2>/dev/null \
  && grep -q "opponent-001 ply 2 g4 cli" "$MET" \
  && ok "her moves stamped move-played with game, ply, and san" \
  || fail "move-played stamps missing from $MET"
stamped=$(awk -F'\t' '$3=="chess" && $4=="move-played" && $5 ~ /^opponent-001 /' \
  "$MET" 2>/dev/null | wc -l)
[ "$stamped" -eq 2 ] \
  && ok "the opponent's moves left no stamp" \
  || fail "wanted 2 move-played stamps for opponent-001, found $stamped"

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

# --- the turn conflict (specs/chessweb.md rule 15) ------------------------
# Two of her sessions answered the same photograph with the same move on
# 2026-08-10; the first landed, the turn passed, and the loser was told
# "illegal move: Nf3" as if she could not read a board. A move that fails
# while the side to move is not hers is a turn conflict, reported as one,
# naming whose move it actually is.
chess move stale Nc3 >/dev/null   # her move lands; black to move now

out="$(chess move stale Nc3)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "turn conflict" \
  && ok "the double-fired move is refused as a turn conflict" \
  || fail "replayed move: rc=$rc $out"
echo "$out" | grep -q "it is black's move (stale)" \
  && ok "and the refusal names whose move it actually is" \
  || fail "no side named in: $out"
echo "$out" | grep -q "another hand played it at ply 8" \
  && ok "and says the move is already on the board, and when it landed" \
  || fail "no already-played note in: $out"
! echo "$out" | grep -q "illegal move" \
  && ok "the words 'illegal move' are gone from the conflict" \
  || fail "still says illegal move: $out"

# A DIFFERENT failing move off her turn is still a turn conflict — just not
# an already-played one.
out="$(chess move stale Qe2)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "turn conflict" \
  && ! echo "$out" | grep -q "another hand" \
  && ok "an unrelated failing move off her turn is a plain turn conflict" \
  || fail "off-turn Qe2: rc=$rc $out"

# Gibberish keeps its own error even off her turn: 'turn conflict' over a
# typo would send her hunting a race that never was.
out="$(chess move stale xyzzy)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "cannot read" \
  && ! echo "$out" | grep -q "turn conflict" \
  && ok "text that is not chess-shaped is still a reading error" \
  || fail "gibberish off-turn: rc=$rc $out"

# And on her own turn a bad move is what it always was.
chess move stale Nf6 >/dev/null   # the opponent replies; her turn again
out="$(chess move stale Ke7)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "illegal move: Ke7" \
  && ! echo "$out" | grep -q "turn conflict" \
  && ok "a bad move on her own turn still reads illegal move" \
  || fail "her-turn Ke7: rc=$rc $out"

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

# --- the opening book (specs/chess-reflex.md rule 9) ----------------------
# Theory she has never played. It must open the gate where she is ignorant
# and shut up entirely where her own games have already spoken.
NAJDORF="rnbqkb1r/1p2pppp/p2p1n2/8/3NP3/2N5/PPP2PPP/R1BQKB1R w KQkq - 0 7"

out="$(chess reflex --seed-book)"
echo "$out" | grep -qE "book seeded — [0-9]+ lines" \
  && ok "the book seeds into the same store as her games" \
  || fail "seeding: $out"

out="$(chess reflex "$NAJDORF")"
echo "$out" | grep -q "would play" && echo "$out" | grep -q "book," \
  && ok "a position only theory knows is played from the book, unplayed" \
  || fail "book gate stayed shut: $out"

# Book membership must not be smuggled into the played tallies (rule 6): e4
# runs through thirteen book lines and has still only been played twice.
out="$(chess reflex "$START")"
echo "$out" | grep "^e4 " | grep -q "games   2  2-0-0" \
  && ok "the book left the played W-D-L alone" \
  || fail "book leaked into the results: $out"
echo "$out" | grep "^e4 " | grep -q "book " \
  && ok "and a move theory also knows says so separately" \
  || fail "book count missing: $out"

# Experience outranks theory: three lost games with the Najdorf's 6.Be3 must
# shut the book's mouth in the very position it was seeded for.
seed_lost() { # <id> <ucis...> — white plays them, then resigns
  local id="$1"; shift
  cat > "$DESKCRAB_CHESS_DIR/games/$id.json" <<JSON
{"id": "$id", "opponent": "import", "my_side": "white",
 "moves": [$(printf '"%s",' "$@" | sed 's/,$//')],
 "resigned_by": "white", "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
}
NAJDORF_LINE="e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6 b1c3 a7a6 c1e3"
for i in 1 2 3; do seed_lost "book-veto-$i" $NAJDORF_LINE; done
chess reflex --backfill >/dev/null
out="$(chess reflex "$NAJDORF")"
echo "$out" | grep -q "not confident enough" \
  && ok "her own losses veto the book: she thinks instead of playing theory" \
  || fail "book overrode experience: $out"

# Reseeding replaces the book rather than doubling it, and never eats a game.
before="$(chess reflex "$START")"
chess reflex --seed-book >/dev/null
[ "$(chess reflex "$START")" = "$before" ] \
  && ok "reseeding the book is idempotent and leaves played games standing" \
  || fail "reseed changed the memory: $(chess reflex "$START")"

# --- a game id where a FEN goes (specs/chess-reflex.md rule 5) -------------
# Every other subcommand takes a game id; reflex and similar erroring on one
# is how a pre-move lookup quietly stops being run at all.
chess new bookworm >/dev/null
for m in e4 c5 Nf3; do chess move bookworm "$m" >/dev/null; done
SICILIAN="rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"
[ "$(chess status bookworm | sed -n 's/^fen: //p')" = "$SICILIAN" ] \
  && ok "the seeded game is where the test thinks it is" \
  || fail "seeded game is elsewhere: $(chess status bookworm | sed -n 's/^fen: //p')"
by_id="$(chess reflex bookworm)"
[ -n "$by_id" ] && [ "$by_id" = "$(chess reflex "$SICILIAN")" ] \
  && ok "reflex reads a game id as that game's current position" \
  || fail "reflex by id disagreed with reflex by fen: $by_id"

out="$(chess similar bookworm)"; rc=$?
[ $rc -eq 0 ] && ok "similar takes a game id too" || fail "similar by id: $out"

out="$(chess reflex not-a-fen-nor-a-game)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "no game matches" \
  && echo "$out" | grep -q "FEN" \
  && ok "a word that is neither names both failures" \
  || fail "unhelpful error for a bad argument: $out"

# --- the resident-mover guard (specs/chessweb.md rule 15b) ----------------
# Her side of a browser game is played in-process by the resident mover, and
# a CLI move there is a second mover racing the first: whichever answer lands
# second is discarded as stale. Twice in one night a wake-driven move did
# exactly that mid-think and the game played worse for it, so the command
# line refuses her side of a browser game unless --force says the mover is
# known to be down.
chess new browser >/dev/null            # opponent 'browser', she is white
out="$(chess move browser e4)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "resident mover" \
  && echo "$out" | grep -q -- "--force" \
  && ok "her side of a browser game is refused, naming the mover and the flag" \
  || fail "browser-game move: rc=$rc $out"
chess status browser | grep -q "ply 0" \
  && ok "the refusal wrote nothing to the game" \
  || fail "store changed despite the guard: $(chess status browser)"

out="$(chess move browser e4 --force)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "played e4" \
  && ok "--force plays her side when the mover is known to be down" \
  || fail "forced browser-game move: rc=$rc $out"

# The opponent's mirrored move is not hers, and passes with no flag at all.
out="$(chess move browser e5)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "played e5" \
  && ok "a mirrored opponent move on a browser game needs no force" \
  || fail "opponent move on browser game: rc=$rc $out"
