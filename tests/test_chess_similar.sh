#!/bin/bash
# The similarity layer of the chess position memory (specs/chess-reflex.md
# rules 10-14). Run: bash tests/test_chess_similar.sh
#
# What must hold: the feature extractor is deterministic and its values are
# the ones a human can count on a board; vector rows ride the exact layer's
# ingestion, retraction, and backfill; retrieval hands back neighbours that a
# chess player would call neighbours; and the bridge only ever does similarity
# work after the exact layer has missed — a reflex hit plays before any of it.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
CHESS="$REPO/lib/betty-chess"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"

if [ ! -x "$PY" ]; then
  echo "SKIP: no chess venv at $VENV — run betty-chess once to bootstrap it"
  exit 0
fi
export PYTHONDONTWRITEBYTECODE=1

export DESKCRAB_CHESS_DIR="$SANDBOX/chess-games"
export DESKCRAB_CHESS_VENV="$VENV"
DB="$DESKCRAB_CHESS_DIR/reflex.db"

chess() { "$CHESS" "$@" 2>&1; }
vec_sql() { "$PY" -B - "$DB" "$1" <<'EOF'
import sqlite3, sys
print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])
EOF
}

# --- the extractor --------------------------------------------------------
# Determinism means the same bytes from another process, not just this one.
extract_hex() { "$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_similar
print(chess_similar.pack(chess_similar.extract(chess.Board("$1"))).hex())
EOF
}
START="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
one="$(extract_hex "$START")"; two="$(extract_hex "$START")"
[ -n "$one" ] && [ "$one" = "$two" ] \
  && ok "extraction is deterministic across processes, byte for byte" \
  || fail "two extractions of the start position differ: $one vs $two"

# Values a human can count: the start position, a lone passed a-pawn, and a
# doubled pair, checked against the arithmetic by hand.
out="$("$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_similar as cs
assert len(cs.FEATURES) == 64, f"FEATURES is {len(cs.FEATURES)} names"
f = dict(zip(cs.FEATURES, cs.extract(chess.Board())))
for name, want in {"us_pawns": 1.0, "them_pawns": 1.0, "material_balance": 0.5,
                   "phase": 1.0, "us_isolated": 0.0, "us_doubled": 0.0,
                   "us_passed": 0.0, "open_files": 0.0,
                   "us_king_shield": 0.5, "us_knight_mobility": 0.25,
                   "us_developed": 0.0, "check": 0.0, "us_castle_k": 1.0,
                   "stm_white": 1.0}.items():
    assert abs(f[name] - want) < 1e-9, f"start {name}: {f[name]} != {want}"
f = dict(zip(cs.FEATURES, cs.extract(chess.Board("8/8/8/8/8/8/P7/K1k5 w - - 0 1"))))
for name, want in {"us_pawns": 1/8, "us_isolated": 1/8, "us_passed": 1/8,
                   "them_pawns": 0.0, "phase": 0.0, "material_balance": 0.55,
                   "us_king_shield": 1/6, "us_castle_k": 0.0}.items():
    assert abs(f[name] - want) < 1e-9, f"pawn endgame {name}: {f[name]} != {want}"
f = dict(zip(cs.FEATURES, cs.extract(chess.Board("8/8/8/8/8/P7/P7/K1k5 w - - 0 1"))))
assert abs(f["us_doubled"] - 1/8) < 1e-9, f"doubled: {f['us_doubled']}"
assert abs(f["us_isolated"] - 2/8) < 1e-9, f"isolated: {f['us_isolated']}"
# The mover's perspective: after 1.e4 the centre pawn belongs to *them*.
b = chess.Board(); b.push_san("e4")
f = dict(zip(cs.FEATURES, cs.extract(b)))
assert f["stm_white"] == 0.0 and f["them_centre_pawns"] == 0.5, "perspective"
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "hand-counted feature values match on known positions" \
  || fail "feature hand-checks: $out"

# --- ingestion rides the exact layer --------------------------------------
chess new opponent >/dev/null
for m in f3 e5 g4 Qh4; do chess move "$m" >/dev/null; done

[ "$(vec_sql "SELECT COUNT(*) FROM vectors")" = 4 ] \
  && ok "a finished game's plies entered the vectors table by themselves" \
  || fail "vectors after fool's mate: $(vec_sql 'SELECT COUNT(*) FROM vectors')"
[ "$(vec_sql "SELECT COUNT(*) FROM vectors WHERE colour='white' AND outcome='loss'")" = 2 ] \
  && [ "$(vec_sql "SELECT COUNT(*) FROM vectors WHERE colour='black' AND outcome='win'")" = 2 ] \
  && ok "each row carries the mover's own outcome, not the game's headline" \
  || fail "outcomes per mover are wrong"

chess undo opponent >/dev/null
[ "$(vec_sql "SELECT COUNT(*) FROM vectors")" = 0 ] \
  && ok "reopening the game retracted its vectors with its moves" \
  || fail "vectors survived the undo"
chess move Qh4 >/dev/null   # finish it again for the sections below

rm -f "$DB"
chess reflex --backfill >/dev/null
[ "$(vec_sql "SELECT COUNT(*) FROM vectors")" = 4 ] \
  && ok "backfill fills the vectors table from the game files alone" \
  || fail "vectors after backfill: $(vec_sql 'SELECT COUNT(*) FROM vectors')"

before="$(vec_sql "SELECT COUNT(*) FROM vectors")"
chess reflex --seed-book >/dev/null
[ "$(vec_sql "SELECT COUNT(*) FROM vectors")" = "$before" ] \
  && ok "the opening book stays out of the vectors: theory has no result" \
  || fail "book seeding changed the vectors table"

# --- retrieval ------------------------------------------------------------
# A scholar's-mate win alongside the fool's-mate loss. A query one small step
# off the scholar game must find the scholar game, not the fool one.
cat > "$DESKCRAB_CHESS_DIR/games/import-scholar.json" <<'JSON'
{"id": "import-scholar", "opponent": "import", "my_side": "white",
 "moves": ["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"],
 "resigned_by": null, "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
chess reflex --backfill >/dev/null

NEAR="r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/8/PPPP1PPP/RNBQK1NR w KQkq - 2 3"
QUERY="rnbqkbnr/ppp2ppp/3p4/4p3/2B1P3/8/PPPP1PPP/RNBQK1NR w KQkq - 0 3"

out="$(chess similar "$QUERY")"; rc=$?
[ "$rc" -eq 0 ] || fail "similar refused a fair query: $out"
echo "$out" | head -1 | grep -q "import-scholar" \
  && ok "the nearest neighbour of a near-scholar position is the scholar game" \
  || fail "sane-neighbour ranking: $out"
echo "$out" | head -1 | grep -vq "opponent-001" \
  && ok "and the fool's-mate game did not outrank it" \
  || fail "fool's mate ranked first: $out"

out="$(chess similar "$NEAR")"
echo "$out" | head -1 | grep -q "^exact" \
  && ok "a position that is in the store ranks itself first, flagged exact" \
  || fail "exact self-match: $out"

# An empty store refuses loudly, so callers fall through.
EMPTY="$SANDBOX/chess-empty"
mkdir -p "$EMPTY"
out="$(DESKCRAB_CHESS_DIR="$EMPTY" chess similar "$START")"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "no stored positions" \
  && ok "an empty store says so and exits non-zero" \
  || fail "empty store: rc=$rc $out"

# --- the bridge: exact first, similarity only on a miss -------------------
# Hub.answer_position is driven directly; the model call is a stub that logs
# its prompt and answers from a reply map, so what the model was TOLD is the
# evidence. The metric stamps are the rest of it (chessweb.md rule 17): a
# similar-context stamp is written whenever the note is computed, empty or
# not, so its absence on the hit path proves the short-circuit.
HUBDIR="$SANDBOX/chess-hub"
mkdir -p "$HUBDIR/games"
WAKE_LOG="$SANDBOX/wake.log"
WAKE_STUB="$SANDBOX/wake-stub"
cat > "$WAKE_STUB" <<SH
#!/bin/bash
printf '%s\n' "\$1" >> "$WAKE_LOG"
SH
chmod +x "$WAKE_STUB"
MOVER_LOG="$SANDBOX/mover.log"
MOVER_REPLIES="$SANDBOX/mover-replies.tsv"
MOVER_STUB="$SANDBOX/mover-stub"
cat > "$MOVER_STUB" <<SH
#!/bin/bash
prompt="\$(cat)"
printf '%s\n----\n' "\$prompt" >> "$MOVER_LOG"
while IFS=\$'\t' read -r pat reply; do
    [ -n "\$pat" ] || continue
    case "\$prompt" in *"\$pat"*) printf '%s\n' "\$reply"; exit 0 ;; esac
done < "$MOVER_REPLIES"
exit 0
SH
chmod +x "$MOVER_STUB"
printf 'game miss-001\tg1f3\ngame miss-002\tg1f3\ngame miss-003\tg1f3\n' \
    > "$MOVER_REPLIES"
MET="$DESKCRAB_METRICS_DIR/$(date +%F).log"

seed_hub_game() { # <id> <moves json array>
  cat > "$HUBDIR/games/$1.json" <<JSON
{"id": "$1", "opponent": "hub", "my_side": "white", "moves": $2,
 "resigned_by": null, "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
}
# Two finished e4 wins open the reflex gate at the start position; the miss
# games stand four plies down a road the store has never walked exactly —
# one per drive, because a drive now PLAYS the answer into its game.
seed_hub_game won-001 '["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]'
seed_hub_game won-002 '["e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7"]'
seed_hub_game miss-001 '["e2e4", "e7e5", "f1c4", "d7d6"]'
seed_hub_game miss-002 '["e2e4", "e7e5", "f1c4", "d7d6"]'
seed_hub_game miss-003 '["e2e4", "e7e5", "f1c4", "d7d6"]'
seed_hub_game hit-001 '[]'
DESKCRAB_CHESS_DIR="$HUBDIR" chess reflex --backfill >/dev/null

drive() { # <game id> — answer_position for that game's live board
  DESKCRAB_CHESS_DIR="$HUBDIR" DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
      "$PY" -B - "$1" <<EOF
import sys
sys.path.insert(0, "$REPO/lib")
import chess_cli, chessweb
store = chessweb.Store("hub", "white", game_id=sys.argv[1])
hub = chessweb.Hub(store, ["$WAKE_STUB"])
g = store.load()
hub.answer_position(g, chess_cli.build_board(g))
hub.mover.wait_idle(60)
EOF
}

: > "$MOVER_LOG"
drive miss-001 >/dev/null
grep -q "game miss-001" "$MOVER_LOG" \
  && ok "an unknown position still goes to the model" \
  || fail "no model call for the miss game: $(cat "$MOVER_LOG")"
grep -q "Exact memory has nothing here" "$MOVER_LOG" \
  && ok "and the model prompt carries the similar-positions note" \
  || fail "prompt has no similarity note: $(cat "$MOVER_LOG")"
grep -q "never a move to copy" "$MOVER_LOG" \
  && ok "which names itself context, not a command" \
  || fail "the note does not disclaim itself: $(cat "$MOVER_LOG")"
awk -F'\t' '$3=="chess" && $4=="reflex-miss" && $5 ~ /^miss-001 /' "$MET" \
    | grep -q . \
  && awk -F'\t' '$3=="chess" && $4=="similar-context" && $5 ~ /^miss-001 ply 4 attached/' "$MET" \
    | grep -q . \
  && ok "the stamps say what happened: reflex-miss, then the note attached" \
  || fail "metric stamps for the miss path are wrong: $(grep miss-001 "$MET")"
awk -F'\t' '$4=="similar-context" && $5 ~ /^miss-001 ply 4 attached top [^ ]+ [01]\.[0-9][0-9]$/' \
    "$MET" | grep -q . \
  && ok "and the nearest neighbour is named in the stamp with its similarity" \
  || fail "no top field on the miss stamp: $(grep similar-context "$MET")"
"$PY" -B -c "
import json; g = json.load(open('$HUBDIR/games/miss-001.json'))
raise SystemExit(0 if g['moves'][-1] == 'g1f3' else 1)" \
  && ok "and the stub's answer was validated and played into the store" \
  || fail "miss game's moves: $(cat "$HUBDIR/games/miss-001.json")"

# The floor silences the note, never the stamp: a neighbour too far to be
# quoted into the prompt is the one case the floor has to be judged on.
: > "$MOVER_LOG"
DESKCRAB_CHESS_SIMILAR_MIN=0.99 drive miss-002 >/dev/null
grep -q "Exact memory has nothing here" "$MOVER_LOG" \
  && fail "the floor let a distant neighbour into the prompt: $(cat "$MOVER_LOG")" \
  || ok "a neighbour under the floor is kept out of the model prompt"
awk -F'\t' '$4=="similar-context" && $5 ~ /^miss-002 ply 4 empty top [^ ]+ [01]\.[0-9][0-9]$/' \
    "$MET" | grep -q . \
  && ok "but the stamp still records what memory would have said" \
  || fail "below-floor stamp lost its top field: $(grep similar-context "$MET")"

: > "$MOVER_LOG"
: > "$WAKE_LOG"
drive hit-001 >/dev/null
[ ! -s "$MOVER_LOG" ] && ! grep -q "your move" "$WAKE_LOG" \
  && grep -q "you played" "$WAKE_LOG" \
  && ok "a position reflex knows costs no model call; only her post-move voice wakes" \
  || fail "reflex hit path: $(cat "$MOVER_LOG" "$WAKE_LOG")"
"$PY" -B -c "
import json; g = json.load(open('$HUBDIR/games/hit-001.json'))
raise SystemExit(0 if g['moves'] == ['e2e4'] else 1)" \
  && ok "the remembered move was played into the store instead" \
  || fail "hit game's moves: $(cat "$HUBDIR/games/hit-001.json")"
awk -F'\t' '$3=="chess" && $4=="similar-context" && $5 ~ /^hit-001 /' "$MET" \
    | grep -q . \
  && fail "similarity work ran on the exact-hit path" \
  || ok "and no similar-context stamp exists: the hit short-circuited first"

# The switch: DESKCRAB_CHESS_SIMILAR=0 sends the prompt bare.
: > "$MOVER_LOG"
DESKCRAB_CHESS_SIMILAR=0 drive miss-003 >/dev/null
grep -q "game miss-003" "$MOVER_LOG" \
  && ! grep -q "Exact memory has nothing here" "$MOVER_LOG" \
  && ok "DESKCRAB_CHESS_SIMILAR=0 leaves the model prompt bare" \
  || fail "the off switch: $(cat "$MOVER_LOG")"
