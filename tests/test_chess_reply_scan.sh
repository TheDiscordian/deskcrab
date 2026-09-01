#!/bin/bash
# The reply scan, the trade guard, and the passed-pawn line
# (specs/chess-mover-amendment.md, "The reply scan", "Trades while ahead",
# "Passed pawns are named"). Run: bash tests/test_chess_reply_scan.sh
#
# What must hold: a candidate that survives the destination-square test is
# pushed and the opponent's replies scanned one ply deep — captures priced by
# _swap_off over every mover piece, mate above every number, forks by
# knight/queen/pawn priced by the exchange and never by face value, and a
# capture the move first allows tagged as such. The three measured losses
# (engineering record i-throw-won-games-at-the-end-and-nobody-has-look) are
# the pinned regressions: browser-031's 23.Qc3 (23...Rxd6) and 36.Qf2
# (36...Nxf4), and browser-030's self-block Bg6 (Qxc5) — each must be flagged
# with its concrete refutation, and a prompt-obedient chooser must no longer
# pick it. FENs are pinned here, replayed by hand from the game store, so the
# suite never reads the live games directory.
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
export DESKCRAB_CHESS_MEMORY_PROMPT=0
mkdir -p "$DESKCRAB_CHESS_DIR"

# The three boards of the record, replayed from the stored games:
#   QC3  — browser-031 before white's 23rd. Qc3 walks the queen off the d6
#          knight's defence; 23...Rxd6 took it, +2 became -1.
#   QF2  — browser-031 before white's 36th. Qf2 walks the queen off the f4
#          pawn's defence; 36...Nxf4 began the -2 to -11 collapse.
#   BG6  — browser-030 before black's 24th (ply 47; the record's "48" counted
#          plies). Bg6 walks the bishop off the fifth rank and hands the h5
#          queen a capture on c5 that was illegal the move before.
QC3="3r1rk1/p1Q2ppp/3Np3/1p1q3n/5P2/3p1PB1/PP1R2PP/5RK1 w - - 2 23"
QF2="8/p5pp/5p1k/7n/1p3P1Q/5P2/6PP/2q1B1K1 w - - 2 36"
BG6="2k1r3/npp2pp1/7p/pPq2b1Q/P3pP2/2P1r3/2K2NPP/RN5R b - - 7 24"
# browser-032 before black's 29th: the white f-pawn already passed on f3 that
# walked to f8=Q at move 49 with the prompt saying nothing.
PP32="1k1r3r/bp4Q1/2p2n1p/3pn3/6P1/2P2P2/PP5P/5R1K b - - 0 29"
# Constructed: white up a rook and a piece-trade on offer (Qxd8 Rxd8).
AHEAD="3q1rk1/pp6/8/8/8/8/PP6/R2Q1RK1 w - - 0 1"
# Constructed: after Qd4 the c3 knight lands Ne2+, forking king and queen
# from a square nothing white covers.
FORK="6k1/5ppp/8/8/8/2n5/5PPP/3Q2K1 w - - 0 1"
# selfplay-benchmatrix-20260828-554 before black's 34th: Sonnet answered
# h6h3 and h8h8 by combining squares it saw in SAN-labelled analysis. Neither
# token is legal. The final prompt boundary must expose only exact legal UCI
# tokens, after every analytical label and after the retry explanation.
WHITELIST="4r3/Nbrnq1k1/1p1b1p1p/1B1p2pP/3PPnP1/1PN2P2/1B1Q4/2R1R1K1 b - - 0 34"

# --- worst_reply itself ----------------------------------------------------
out="$("$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
def worst(fen, uci):
    b = chess.Board(fen)
    return chess_mover.worst_reply(b, chess.Move.from_uci(uci))

loss, san, why = worst("$QC3", "c7c3")
assert san == "Rxd6" and loss == 320, f"Qc3: {loss} {san} {why}"
assert "knight on d6" in why, f"Qc3 why: {why}"

loss, san, why = worst("$QF2", "h4f2")
assert san == "Nxf4" and loss == 100, f"Qf2: {loss} {san} {why}"

loss, san, why = worst("$BG6", "f5g6")
assert san == "Qxc5" and loss >= 900, f"Bg6: {loss} {san} {why}"
assert "queen on c5" in why, f"Bg6 why: {why}"
assert "first allows" in why, f"Bg6 not tagged as newly allowed: {why}"
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "the three recorded blunders are each priced with their refutation" \
  || fail "worst_reply on the incident boards: $out"

out="$("$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
def worst(fen, uci):
    b = chess.Board(fen)
    return chess_mover.worst_reply(b, chess.Move.from_uci(uci))

# A knight landing where nothing covers it, hitting king and queen: a fork.
loss, san, why = worst("$FORK", "d1d4")
assert san == "Ne2+" and loss >= 900, f"fork missed: {loss} {san} {why}"
assert "fork" in why and "king" in why and "queen" in why, f"fork why: {why}"

# Forked targets are priced by the exchange, not face value: on the Qc3
# board, Ne4 keeps the knight defended by the f3 pawn — Qd4+ "forking" it
# wins nothing, so the scan must price Ne4 by the a2 pawn alone.
loss, san, why = worst("$QC3", "d6e4")
assert loss == 100, f"Ne4 face-value fork returned: {loss} {san} {why}"

# A reply that is checkmate outranks every material number: on the Bg6
# board, f6 opens e8 and Qxe8 is mate.
loss, san, why = worst("$BG6", "f7f6")
assert san == "Qxe8#" and loss > 20000, f"mate not maximal: {loss} {san} {why}"
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "forks are exchange-priced, safe-square forks flagged, mate above all" \
  || fail "worst_reply pricing: $out"

# --- the prompt buckets ----------------------------------------------------
prompt_for() { # <fen> — Mover._prompt over that board, memory off
  "$PY" -B - "$1" <<EOF
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

P="$(prompt_for "$QC3")"
safe_line="$(printf '%s\n' "$P" | grep "do not lose material")"
printf '%s\n' "$safe_line" | grep -q "c7c3" \
  && fail "Qc3 still reads safe: $safe_line" \
  || ok "Qc3 is out of the safe list"
pun_line="$(printf '%s\n' "$P" | grep "reply punishes")"
printf '%s\n' "$pun_line" | grep -q "c7c3.*Rxd6" \
  && ok "and the punished bucket names Rxd6 as its refutation" \
  || fail "no Rxd6 entry for Qc3: $pun_line"

P="$(prompt_for "$QF2")"
printf '%s\n' "$P" | grep "do not lose material" | grep -q "h4f2" \
  && fail "Qf2 still reads safe" \
  || ok "Qf2 is out of the safe list"
printf '%s\n' "$P" | grep "reply punishes" | grep -q "h4f2.*Nxf4" \
  && ok "and the punished bucket names Nxf4 as its refutation" \
  || fail "no Nxf4 entry for Qf2: $(printf '%s\n' "$P" | grep 'reply punishes')"

P="$(prompt_for "$BG6")"
printf '%s\n' "$P" | grep "do not lose material" | grep -q "f5g6" \
  && fail "Bg6 still reads safe" \
  || ok "Bg6 is out of the safe list"
pun_line="$(printf '%s\n' "$P" | grep "reply punishes")"
printf '%s\n' "$pun_line" | grep -q "f5g6.*Qxc5" \
  && ok "and the punished bucket names Qxc5 as its refutation" \
  || fail "no Qxc5 entry for Bg6: $pun_line"
printf '%s\n' "$pun_line" | grep -q "f7f6.*checkmate" \
  && ok "the f6 self-mate is named as checkmate, not priced as a pawn count" \
  || fail "f6 mate entry missing: $pun_line"

# --- the final UCI-only boundary ------------------------------------------
out="$("$PY" -B - <<EOF
import json, sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
board = chess.Board("$WHITELIST")
mover = chess_mover.Mover(play=lambda job, mv: True, log=lambda *a: None)
job = {"side": "black", "opponent": "fixture", "gid": "fixture-554",
       "ply": board.ply(), "fen": board.fen(), "history": "(fixture)",
       "key": "fixture"}
legal = [move.uci() for move in board.legal_moves]
prompt = mover._prompt(job, board)
lines = prompt.rstrip("\n").splitlines()
assert lines[-2] == ("Answer with exactly one token from this UCI whitelist, "
                     "nothing else:"), lines[-2:]
assert lines[-1].split() == legal, (lines[-1], legal)
assert len(legal) == len(set(legal)), legal
assert "h6h3" not in legal and "h8h8" not in legal, legal

schema = chess_mover._move_schema(legal)
assert schema["properties"]["move"]["enum"] == legal, schema
assert schema["additionalProperties"] is False, schema
claude_cmd = mover._claude_cmd("low", model="sonnet", legal_uci=legal)
assert "--json-schema" in claude_cmd, claude_cmd
assert json.loads(claude_cmd[claude_cmd.index("--json-schema") + 1]) == schema
codex_cmd = mover._codex_cmd("low", model="sol", legal_uci=legal)
assert "--output-schema" in codex_cmd, codex_cmd
with open(codex_cmd[codex_cmd.index("--output-schema") + 1]) as fh:
    assert json.load(fh) == schema
assert chess_mover._structured_move(
    {"structured_output": {"move": legal[0]}}) == legal[0]
assert chess_mover._structured_move({"result": legal[0]}) is None

# The normal attempt stays fast; changing the shared retry state before the
# generator advances makes the very next account schema-constrained.
mover._accounts = lambda model: [(1, "/tmp/fixture-a"),
                                 (2, "/tmp/fixture-b")]
state = {"legal_uci": None}
attempts = mover._attempts("low", job_model="sonnet", schema_state=state)
_, first_cmd, _ = next(attempts)
assert "--json-schema" not in first_cmd, first_cmd
state["legal_uci"] = legal
_, retry_cmd, _ = next(attempts)
assert "--json-schema" in retry_cmd, retry_cmd
assert json.loads(retry_cmd[retry_cmd.index("--json-schema") + 1]) == schema

retry = mover._prompt(job, board, "h8h8")
retry_lines = retry.rstrip("\n").splitlines()
assert retry_lines[-3] == ("Your previous answer 'h8h8' was rejected because "
                           "it is not one of the allowed tokens below."), retry_lines[-3:]
assert retry_lines[-2:] == lines[-2:], retry_lines[-3:]
assert mover._reply_label("h8h8") == "h8h8"
assert mover._reply_label("I think Rh8 is best here.") == "non-move-text"
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "the Game 554 prompt ends at an exact legal UCI-only whitelist" \
  || fail "Game 554 UCI whitelist boundary: $out"

# --- the chooser no longer picks the blunder -------------------------------
# The stub is the obedient model of the incidents: it plays the recorded
# blunder whenever the prompt lists it safe (that is exactly what happened),
# and otherwise takes the first safe move, or the least-losing punished one.
STUB="$SANDBOX/obedient-stub.py"
cat > "$STUB" <<'PYEOF'
import os, re, sys
text = sys.stdin.read()
target = os.environ.get("BT_TARGET", "")
def ucis(line):
    return re.findall(r"\(([a-h][1-8][a-h][1-8][qrbn]?)\)", line)
safe = next((l for l in text.splitlines() if "do not lose material" in l), "")
if target in ucis(safe):
    print(target); sys.exit(0)
if ucis(safe):
    print(ucis(safe)[0]); sys.exit(0)
pun = next((l for l in text.splitlines() if "reply punishes" in l), "")
print(ucis(pun)[0] if ucis(pun) else "0000")
PYEOF

chosen_for() { # <fen> <target-uci> — what the mover plays end to end
  BT_TARGET="$2" DESKCRAB_CHESS_MOVER_CMD="$PY -B $STUB" \
      "$PY" -B - "$1" <<EOF
import sys, threading; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
fen = sys.argv[1]
got = []
mover = chess_mover.Mover(play=lambda job, mv: got.append(mv) or True,
                          log=lambda *a: None)
board = chess.Board(fen)
job = {"key": "t", "gid": "fixture-001", "ply": board.ply(), "fen": fen,
       "side": "white" if board.turn else "black", "opponent": "fixture",
       "history": "(fixture)", "note": "", "effort": "low", "t0": 0}
mover.submit(job)
mover.wait_idle(60)
print(got[0].uci() if got else "none")
EOF
}

got="$(chosen_for "$QC3" c7c3)"
[ -n "$got" ] && [ "$got" != "none" ] && [ "$got" != "c7c3" ] \
  && ok "an obedient chooser no longer plays Qc3 (played $got)" \
  || fail "Qc3 board: chooser played" "$got"
got="$(chosen_for "$QF2" h4f2)"
[ -n "$got" ] && [ "$got" != "none" ] && [ "$got" != "h4f2" ] \
  && ok "an obedient chooser no longer plays Qf2 (played $got)" \
  || fail "Qf2 board: chooser played" "$got"
got="$(chosen_for "$BG6" f5g6)"
[ -n "$got" ] && [ "$got" != "none" ] && [ "$got" != "f5g6" ] \
  && ok "an obedient chooser no longer plays Bg6 (played $got)" \
  || fail "Bg6 board: chooser played" "$got"

# --- the trade guard -------------------------------------------------------
P="$(prompt_for "$AHEAD")"
tl="$(printf '%s\n' "$P" | grep "You are ahead")"
[ -n "$tl" ] \
  && ok "ahead by five pawns, the prompt says so" \
  || fail "no trade-guard line while +5: $P"
printf '%s\n' "$tl" | grep -q "Qxd8" \
  && printf '%s\n' "$tl" | grep -q "+5\.0" \
  && ok "and the queen trade is named with the balance it leaves" \
  || fail "trade entry wrong: $tl"
P="$(prompt_for "$QF2")"
printf '%s\n' "$P" | grep -q "You are ahead" \
  && fail "trade-guard line printed for the side that is behind" \
  || ok "no trade-guard line when behind"
P="$(prompt_for "$PP32")"
printf '%s\n' "$P" | grep -q "You are ahead" \
  && fail "trade-guard line printed with only pawn grabs on offer" \
  || ok "pawn captures alone do not raise the trade-guard line"

# --- passed pawns ----------------------------------------------------------
P="$(prompt_for "$PP32")"
ppl="$(printf '%s\n' "$P" | grep "Passed pawns")"
printf '%s\n' "$ppl" | grep -q "theirs: f3, 5 from promoting" \
  && ok "the browser-032 f-pawn is named with its distance to promotion" \
  || fail "f3 passer missing: $ppl"
printf '%s\n' "$ppl" | grep -q "guards f8" \
  && ok "and the one guarded square on its path is named" \
  || fail "no f8 guard note: $ppl"
printf '%s\n' "$ppl" | grep -q "yours: none" \
  && ok "the mover's own side reads none — no false passers" \
  || fail "own-side passers invented: $ppl"
P="$(prompt_for "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")"
printf '%s\n' "$P" | grep -q "Passed pawns — yours: none; theirs: none" \
  && ok "a clean board still prints the line, none and none" \
  || fail "no all-clear passed-pawn line: $(printf '%s\n' "$P" | grep -i passed)"

# --- order and timing ------------------------------------------------------
P="$(prompt_for "$PP32")"
stand_at="$(printf '%s\n' "$P" | grep -n "can win where they stand" | head -1 | cut -d: -f1)"
pp_at="$(printf '%s\n' "$P" | grep -n "Passed pawns" | head -1 | cut -d: -f1)"
legal_at="$(printf '%s\n' "$P" | grep -n "do not lose material" | head -1 | cut -d: -f1)"
[ -n "$stand_at" ] && [ -n "$pp_at" ] && [ -n "$legal_at" ] \
  && [ "$stand_at" -lt "$pp_at" ] && [ "$pp_at" -lt "$legal_at" ] \
  && ok "standing, then passed pawns, then the legal-move dump" \
  || fail "line order: standing $stand_at, passed $pp_at, legal $legal_at"

out="$("$PY" -B - <<EOF
import sys, time; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
boards = [chess.Board("$QC3"), chess.Board("$QF2"), chess.Board("$BG6")]
start = time.perf_counter()
reps = 5
for _ in range(reps):
    for b in boards:
        for m in b.legal_moves:
            if chess_mover.material_loss(b, m) <= 0:
                chess_mover.worst_reply(b, m)
per = (time.perf_counter() - start) / (reps * len(boards))
assert per < 0.150, f"scan at {per*1000:.0f}ms per position"
print(f"checked {per*1000:.1f}ms")
EOF
)"
case "$out" in
  checked*) ok "the whole scan stays under 150ms per position (${out#checked })" ;;
  *) fail "scan timing: $out" ;;
esac
