#!/bin/bash
# The declined exact hit reaches the reasoning prompt as a warning
# (specs/chess-reflex.md rule 14a, amended 2026-09-03; the engineering record
# "a known losing chess move disappears when exact memory declines to replay
# it"). Run: bash tests/test_chess_exact_decline.sh
#
# What must hold, pinned on the browser-044 FEN verbatim
# (r3r1k1/pp1b1ppp/1q1b1n2/2p3N1/3P3B/2PQ2P1/PP5P/5RK1 b - - 0 23), with the
# store stubbed to hold h6 at one game, zero wins, one loss, score 0.25:
#
#   DECLINED — the gate refuses the thin/losing precedent, the model is
#   called, and the prompt NAMES h6 as an exact losing precedent with its
#   game count, record and score, above the similar section, never endorsed,
#   never auto-played. Before the carve-out the blanket rule-14a filter hid
#   exactly this loss from the hand about to replay it.
#
#   CLEARED — a store where h7h6 genuinely clears the gate (two finished
#   wins) short-circuits: the move is played from memory, no model call is
#   made, no prompt exists, and with the auto-play switch off the prompt
#   still carries no exact row (decided 2026-08-21, unchanged).
#
# The switches keep their names: DESKCRAB_CHESS_SIMILAR=0 drops only the
# similar section (the warning is the exact layer's), and
# DESKCRAB_CHESS_MEMORY_PROMPT=0 sends the prompt bare of everything.
# No network and no real model anywhere: the mover command is a stub that
# logs its prompt and answers from a reply map.
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
export DESKCRAB_CHESS_VENV="$VENV"

# The browser-044 position, verbatim from the record, and the game that
# reached it: 45 plies in, black to move, 23...h6 next — the move whose loss
# the store knows and the prompt used to hide.
FEN="r3r1k1/pp1b1ppp/1q1b1n2/2p3N1/3P3B/2PQ2P1/PP5P/5RK1 b - - 0 23"
PREFIX='"d2d4", "g8f6", "c1f4", "e7e6", "e2e3", "d7d5", "f1d3", "f8d6",
 "f4g3", "e8g8", "c2c3", "b8d7", "b1d2", "e6e5", "f2f3", "f8e8", "g1h3",
 "c7c6", "e1g1", "d8e7", "f3f4", "e5e4", "d3e4", "d5e4", "d2e4", "f6e4",
 "f4f5", "d7f6", "g3h4", "e7d8", "g2g3", "d8b6", "a1b1", "c6c5", "d1a4",
 "c8d7", "a4c2", "f6g4", "f5f6", "e4f6", "h3g5", "g4e3", "c2d3", "e3f1",
 "b1f1"'

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
printf 'game b44-live\ta7a6\ngame b44-sim0\ta7a6\ngame b44-bare\ta7a6\ngame b44c-off\ta7a6\n' \
    > "$MOVER_REPLIES"
MET="$DESKCRAB_METRICS_DIR/$(date +%F).log"

# Fail messages must stay ONE line: the harness counts witness-file lines,
# so a multi-line prompt dump inflates the failure count past the assertion
# count. The whole log is still on disk for a hand that needs it.
mlog() { tr '\n' ' ' < "$MOVER_LOG" | head -c 400; }

seed_game() { # <chess dir> <id> <moves json> — an unfinished live game
  cat > "$1/games/$2.json" <<JSON
{"id": "$2", "opponent": "hub", "my_side": "black", "moves": [$3],
 "resigned_by": null, "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
}
seed_win() { # <chess dir> <id> — prefix + h6, then white resigns: black won
  cat > "$1/games/$2.json" <<JSON
{"id": "$2", "opponent": "hub", "my_side": "black",
 "moves": [$PREFIX, "h7h6"],
 "resigned_by": "white", "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
}

# --- the DECLINED store: h6 at one game, zero wins, one loss, score 0.25 ---
# The full browser-044 line ends in checkmate on its own — the "forced mate"
# the record names — so ingestion needs no resignation flag.
DECL="$SANDBOX/chess-declined"
mkdir -p "$DECL/games"
cat > "$DECL/games/b44-loss.json" <<JSON
{"id": "b44-loss", "opponent": "hub", "my_side": "black",
 "moves": [$PREFIX, "h7h6", "f1f6", "g7f6", "d3h7", "g8f8", "h7f7"],
 "resigned_by": null, "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
seed_game "$DECL" b44-live "$PREFIX"
seed_game "$DECL" b44-sim0 "$PREFIX"
seed_game "$DECL" b44-bare "$PREFIX"
DESKCRAB_CHESS_DIR="$DECL" "$CHESS" reflex --backfill >/dev/null 2>&1

# --- the CLEARED store: h7h6 with two finished wins clears the gate --------
CLR="$SANDBOX/chess-cleared"
mkdir -p "$CLR/games"
seed_win "$CLR" b44-win-a
seed_win "$CLR" b44-win-b
seed_game "$CLR" b44c-live "$PREFIX"
seed_game "$CLR" b44c-off "$PREFIX"
DESKCRAB_CHESS_DIR="$CLR" "$CHESS" reflex --backfill >/dev/null 2>&1

drive() { # <chess dir> <game id> — answer_position for that game's live board
  DESKCRAB_CHESS_DIR="$1" DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
      "$PY" -B - "$2" <<EOF
import sys
sys.path.insert(0, "$REPO/lib")
import chess_cli, chessweb
store = chessweb.Store("hub", "black", game_id=sys.argv[1])
hub = chessweb.Hub(store, ["$WAKE_STUB"])
g = store.load()
hub.answer_position(g, chess_cli.build_board(g))
hub.mover.wait_idle(60)
EOF
}

# --- DECLINED: the loss is told to the hand about to consider it -----------
: > "$MOVER_LOG"
drive "$DECL" b44-live >/dev/null
grep -q "game b44-live" "$MOVER_LOG" \
  && ok "a declined exact hit still goes to the model — no auto-play" \
  || fail "no model call on the declined store: $(mlog)"
grep "h6 (h7h6)" "$MOVER_LOG" | grep -q "an exact losing precedent" \
  && ok "h6 is named in the prompt as an exact losing precedent" \
  || fail "h6 not named as an exact losing precedent: $(mlog)"
grep "h6 (h7h6)" "$MOVER_LOG" | grep "in 1 finished game" \
  | grep "lost 1" | grep -q "score 0.25" \
  && ok "the line carries its game count, its record, and its score" \
  || fail "count/record/score missing from the h6 line: $(grep 'h6 (h7h6)' "$MOVER_LOG" | head -1)"
grep -q "DECLINED to replay it" "$MOVER_LOG" \
  && grep -q "never a recommendation" "$MOVER_LOG" \
  && ok "the section says the gate declined, a warning and no recommendation" \
  || fail "no declined header: $(mlog)"
warn_at="$(grep -n "an exact losing precedent" "$MOVER_LOG" | head -1 | cut -d: -f1)"
sim_at="$(grep -n "Positions like this one" "$MOVER_LOG" | head -1 | cut -d: -f1)"
legal_at="$(grep -n "do not lose material" "$MOVER_LOG" | head -1 | cut -d: -f1)"
[ -n "$warn_at" ] && [ -n "$sim_at" ] && [ -n "$legal_at" ] \
  && [ "$warn_at" -lt "$sim_at" ] && [ "$sim_at" -lt "$legal_at" ] \
  && ok "the warning sits above the similar section, both above the legal moves" \
  || fail "section order: warn at $warn_at, similar at $sim_at, legal at $legal_at"
grep -q "similarity 1\.00" "$MOVER_LOG" \
  && fail "the exact row was dressed up as a neighbour too: $(mlog)" \
  || ok "and the exact row is still excluded from the rendered neighbours"
"$PY" -B -c "
import json; g = json.load(open('$DECL/games/b44-live.json'))
raise SystemExit(0 if g['moves'][45] == 'a7a6' else 1)" \
  && ok "the losing precedent was not auto-played: the stub's answer went in" \
  || fail "b44-live ply 45: $(cat "$DECL/games/b44-live.json")"
awk -F'\t' '$3=="chess" && $4=="reflex-miss" && $5 ~ /^b44-live ply 45/' \
    "$MET" | grep -q . \
  && ! awk -F'\t' '$4=="reflex-hit" && $5 ~ /^b44-live /' "$MET" | grep -q . \
  && ok "the stamps agree: reflex-miss, never reflex-hit, on the declined store" \
  || fail "metric stamps for b44-live: $(grep b44-live "$MET")"

# memory_sections itself, driven straight over the FEN verbatim: the warning
# lines are there, and the declined move never enters the endorsed set.
out="$(DESKCRAB_CHESS_DIR="$DECL" "$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
lines, endorsed, stamp = chess_mover.memory_sections(
    chess.Board("$FEN"))
text = "\n".join(lines)
assert "h6 (h7h6)" in text and "an exact losing precedent" in text, text
assert "h7h6" not in endorsed, f"declined move endorsed: {endorsed}"
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "memory_sections warns on the verbatim FEN and endorses nothing declined" \
  || fail "memory_sections direct drive: $out"

# The switches keep their names: SIMILAR=0 drops only the neighbours — the
# warning is the exact layer's — and MEMORY_PROMPT=0 sends the prompt bare.
: > "$MOVER_LOG"
DESKCRAB_CHESS_SIMILAR=0 drive "$DECL" b44-sim0 >/dev/null
grep -q "game b44-sim0" "$MOVER_LOG" \
  && grep -q "an exact losing precedent" "$MOVER_LOG" \
  && ! grep -q "Positions like this one" "$MOVER_LOG" \
  && ok "DESKCRAB_CHESS_SIMILAR=0 keeps the exact warning, drops the neighbours" \
  || fail "the similar switch took the warning with it: $(mlog)"
: > "$MOVER_LOG"
DESKCRAB_CHESS_MEMORY_PROMPT=0 drive "$DECL" b44-bare >/dev/null
grep -q "game b44-bare" "$MOVER_LOG" \
  && ! grep -q "exact losing precedent" "$MOVER_LOG" \
  && ! grep -q "This very position" "$MOVER_LOG" \
  && ! grep -q "Positions like this one" "$MOVER_LOG" \
  && ok "DESKCRAB_CHESS_MEMORY_PROMPT=0 sends the prompt bare, warning included" \
  || fail "the memory switch left something behind: $(mlog)"

# --- CLEARED: the short-circuit is not regressed ---------------------------
: > "$MOVER_LOG"
drive "$CLR" b44c-live >/dev/null
[ ! -s "$MOVER_LOG" ] \
  && ok "a clearing exact hit makes no model call: no prompt was ever built" \
  || fail "the cleared store built a prompt: $(mlog)"
"$PY" -B -c "
import json; g = json.load(open('$CLR/games/b44c-live.json'))
raise SystemExit(0 if g['moves'][45] == 'h7h6' else 1)" \
  && ok "and the remembered move was played from memory into the store" \
  || fail "b44c-live ply 45: $(cat "$CLR/games/b44c-live.json")"
awk -F'\t' '$3=="chess" && $4=="reflex-hit" && $5 ~ /^b44c-live ply 45 h7h6/' \
    "$MET" | grep -q . \
  && ! awk -F'\t' '$4=="similar-context" && $5 ~ /^b44c-live /' "$MET" | grep -q . \
  && ok "the stamps prove it: reflex-hit, and no similar-context stamp exists" \
  || fail "metric stamps for b44c-live: $(grep b44c-live "$MET")"

# With the auto-play hand held off, the prompt still says nothing about the
# position itself (decided 2026-08-21): a clearing row never enters it.
: > "$MOVER_LOG"
DESKCRAB_CHESS_REFLEX=0 drive "$CLR" b44c-off >/dev/null
grep -q "game b44c-off" "$MOVER_LOG" \
  && ! grep -q "exact losing precedent" "$MOVER_LOG" \
  && ! grep -q "too thin to replay" "$MOVER_LOG" \
  && ! grep -q "This very position" "$MOVER_LOG" \
  && ! grep -q "similarity 1\.00" "$MOVER_LOG" \
  && ok "a clearing hit stays out of the prompt even with auto-play off" \
  || fail "an exact row reached the cleared-gate prompt: $(mlog)"
out="$(DESKCRAB_CHESS_DIR="$CLR" "$PY" -B - <<EOF
import sys; sys.path.insert(0, "$REPO/lib")
import chess, chess_mover
lines, endorsed, stamp = chess_mover.memory_sections(
    chess.Board("$FEN"))
text = "\n".join(lines)
assert "exact" not in text and "This very position" not in text, text
print("checked")
EOF
)"
[ "$out" = "checked" ] \
  && ok "memory_sections on the cleared store renders no exact row at all" \
  || fail "memory_sections cleared drive: $out"
