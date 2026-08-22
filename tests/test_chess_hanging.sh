#!/bin/bash
# The standing sweep (specs/chess-mover-amendment.md, "Hanging pieces are
# counted by the machine"): pieces of the mover's own that the opponent can
# win where they stand, computed once per position and rendered on its own
# line ABOVE the legal-move dump. Run: bash tests/test_chess_hanging.sh
#
# What must hold: the sweep prices each of her occupied squares by the same
# _swap_off the destination-square test uses, opponent capturing first,
# biggest loss first, king excepted; the browser-021 rook — the measured
# incident, engineering record i-throw-won-games-at-the-end-and-nobody-has-
# look, 2026-08-22 — lands in the bucket on the board it actually hung on;
# the prompt line always prints ("none" included), never says "material",
# and sits above the legal-move dump; and the whole sweep stays under 20 ms
# per position.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"

if [ ! -x "$PY" ]; then
  echo "SKIP: no chess venv at $VENV — run betty-chess once to bootstrap it"
  exit 0
fi
export PYTHONDONTWRITEBYTECODE=1
export DESKCRAB_CHESS_DIR="$SANDBOX/chess-games"
mkdir -p "$DESKCRAB_CHESS_DIR"

# The two boards of the incident, browser-021 around white's move 56 (the
# game file replayed by hand; FENs pinned here so the suite never reads the
# live games directory):
#
#   PRE  — before white's 56th move (ply 56, white to move). The rook on a3
#          is attacked once (Qb4) but still defended once (Nc4): the
#          exchange there loses for BLACK, so a3 is honestly not in the
#          bucket yet. What IS standing loose at this prompt is the c4
#          knight itself (b5xc4 wins 220) and the d4 pawn (100).
#   POST — after white's 56th move, Na5: the defender walked away. This is
#          the board the incident measure counted ("his attackers 1, my
#          defenders 0") and the board the rook fell on at ply 57, b4a3.
#          Ra3 must be in white's bucket here, at 500, first.
#
# The gap between the two boards is the per-move question ("which of MY
# candidate moves abandons a piece") and is deliberately outside the
# position-level design the spec pins — the sweep speaks of the board as it
# stands, never of a candidate move's consequences.
PRE="3r1rk1/2p2p1p/2Q1pbp1/pp6/1qNP1P2/R2BB2P/6P1/5RK1 w - - 0 29"
POST="3r1rk1/2p2p1p/2Q1pbp1/Np6/1q1P1P2/R2BB2P/6P1/5RK1 b - - 0 29"

# --- the bucket itself ----------------------------------------------------
out="$("$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
got = chess_mover.standing_losses(chess.Board("$POST"), chess.WHITE)
named = [(chess.square_name(sq), p.symbol().upper(), loss)
         for sq, p, loss in got]
assert ("a3", "R", 500) in named, f"Ra3 missing: {named}"
assert named[0] == ("a3", "R", 500), f"biggest loss not first: {named}"
assert all(p != "K" for _, p, _ in named), f"the king priced: {named}"
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "the browser-021 rook is in the bucket on the board it hung on, 500, first" \
  || fail "standing_losses on the incident board: $out"

out="$("$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
got = chess_mover.standing_losses(chess.Board("$PRE"))
named = [(chess.square_name(sq), p.symbol().upper(), loss)
         for sq, p, loss in got]
assert ("c4", "N", 220) in named, f"the loose knight missing: {named}"
assert not any(sq == "a3" for sq, _, _ in named), \
    f"a3 flagged while still defended: {named}"
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "at prompt time the sweep names what stands loose NOW, not what a move may abandon" \
  || fail "standing_losses on the pre-move board: $out"

# --- the line in the prompt -----------------------------------------------
prompt_for() { # <fen> — Mover._prompt over that board, memory switched off
  DESKCRAB_CHESS_MEMORY_PROMPT=0 "$PY" -B - "$1" <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
board = chess.Board(sys.argv[1])
mover = chess_mover.Mover(play=lambda job, mv: True, log=lambda *a: None)
job = {"side": "white" if board.turn else "black", "opponent": "fixture",
       "gid": "fixture-001", "ply": board.ply(), "fen": sys.argv[1],
       "history": "(fixture)", "key": "fixture"}
sys.stdout.write(mover._prompt(job, board))
EOF
}

P="$(prompt_for "$PRE")"
line="$(printf '%s\n' "$P" | grep "can win where they stand")"
[ -n "$line" ] \
  && ok "the prompt carries the standing line" \
  || fail "no standing line in the prompt: $P"
printf '%s\n' "$line" | grep -q "Nc4 (loses 220)" \
  && printf '%s\n' "$line" | grep -q "Pd4 (loses 100)" \
  && ok "and it names the loose pieces with their loss in centipawns" \
  || fail "the standing line misnames the pieces: $line"
printf '%s\n' "$line" | grep -q "A move that does not address these leaves them there" \
  && ok "a non-empty line says a move elsewhere leaves them standing" \
  || fail "no leaves-them-there sentence: $line"
printf '%s\n' "$line" | grep -qi "material" \
  && fail "the standing line uses the word 'material': $line" \
  || ok "and never says 'material' — that word belongs to the destination-square line"

stand_at="$(printf '%s\n' "$P" | grep -n "can win where they stand" | head -1 | cut -d: -f1)"
legal_at="$(printf '%s\n' "$P" | grep -n "do not lose material" | head -1 | cut -d: -f1)"
[ -n "$stand_at" ] && [ -n "$legal_at" ] && [ "$stand_at" -lt "$legal_at" ] \
  && ok "the standing line sits above the legal-move dump" \
  || fail "line order: standing at $stand_at, legal at $legal_at"

# A clean board still prints the line — "none" is the pinned choice: an
# absent line would be indistinguishable from the sweep having failed.
P="$(prompt_for "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")"
printf '%s\n' "$P" | grep -q "can win where they stand: none" \
  && ok "a clean board affirms the all-clear: the line prints, ending 'none'" \
  || fail "no 'none' line on the start position: $P"

# --- timing ---------------------------------------------------------------
out="$("$PY" -B - <<EOF
import sys, time; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
boards = [chess.Board("$PRE"),
          chess.Board("$POST"),
          chess.Board()]
reps = 30
start = time.perf_counter()
for _ in range(reps):
    for b in boards:
        chess_mover.standing_losses(b, chess.WHITE)
per = (time.perf_counter() - start) / (reps * len(boards))
assert per < 0.020, f"sweep at {per*1000:.1f}ms per position"
print(f"checked {per*1000:.2f}ms")
EOF
)"
case "$out" in
  checked*) ok "the sweep stays under 20ms per position (${out#checked })" ;;
  *) fail "sweep timing: $out" ;;
esac
