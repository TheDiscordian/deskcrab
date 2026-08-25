#!/bin/bash
# The effort dial's two arms, interleaved per game — specs/chessweb.md rules
# 16b and 17, the arm half.
# Run: bash tests/test_chess_effort_arms.sh
#
# The 2026-08-15 low/medium cut ran nine days as ONE undifferentiated block
# and proved unadjudicatable (36% before, 38% after, with retrieval and two
# prompt changes inside the same window — that measures the fortnight, not
# the dial): chess_effort read its env knobs at import, and chessweb is a
# resident daemon, so whichever pair was live at daemon start froze for
# every game until restart. So what must hold now is: classify resolves the
# pair PER CALL — the sharp pre-cut pair (medium/high) on odd game numbers,
# the lowered pair (low/medium) on even, an explicit env knob winning
# outright and READ AT CALL TIME, a game id with no parsable number falling
# back to today's defaults without crashing — and the bridge stamps the
# resolved arm onto the effort metrics row so a later adjudication splits
# the games by arm instead of by date window, while rows from before the
# field still parse and read as unknown.
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
T="$SANDBOX"

chess() { "$CHESS" "$@" 2>&1; }
line() { printf '%s\n' "$1" | sed -n "$2p"; }

# --- classify resolves the pair per call, from the game id's parity -------
# Every print below happens in ONE python process: the import-time freeze
# this suite exists to kill would answer the same pair to all of them.
echo "one process, both arms, and the env knobs read at call time:"
out="$("$PY" -B - <<EOF
import sys, os; sys.path.insert(0, "$REPO/lib")
import chess, chess_effort
quiet = chess.Board()                                # quiet manoeuvring
sharp = chess.Board("7k/8/8/8/8/8/8/K7 w - - 0 1")   # forced:3 rings
print(chess_effort.classify(quiet, game_id="browser-039")[0])
print(chess_effort.classify(quiet, game_id="browser-038")[0])
print(chess_effort.classify(sharp, game_id="browser-039")[0])
print(chess_effort.classify(sharp, game_id="browser-038")[0])
os.environ["DESKCRAB_CHESS_EFFORT_QUIET"] = "high"
print(chess_effort.classify(quiet, game_id="browser-039")[0])
del os.environ["DESKCRAB_CHESS_EFFORT_QUIET"]
print(chess_effort.classify(quiet, game_id="browser-039")[0])
print(chess_effort.classify(quiet, game_id="rematch-with-no-number")[0])
print(chess_effort.classify(quiet)[0])
EOF
)"
check_eq "odd game, quiet board: the sharp arm's quiet level" \
    "$(line "$out" 1)" "medium"
check_eq "even game, quiet board: the lowered arm's quiet level" \
    "$(line "$out" 2)" "low"
check_eq "odd game, alarmed board: the sharp arm's sharp level" \
    "$(line "$out" 3)" "high"
check_eq "even game, alarmed board: the lowered arm's sharp level" \
    "$(line "$out" 4)" "medium"
check_eq "an env knob set BETWEEN two calls in the same process is honoured \
— the import-time read is gone" "$(line "$out" 5)" "high"
check_eq "and unset again, the same process is back on the parity" \
    "$(line "$out" 6)" "medium"
check_eq "a game id with no parsable number neither crashes nor picks an \
arm: today's defaults" "$(line "$out" 7)" "low"
check_eq "no game id at all is the same fallback" "$(line "$out" 8)" "low"

echo
echo "resolve names the arm the pair came from:"
out="$("$PY" -B - <<EOF
import sys, os; sys.path.insert(0, "$REPO/lib")
import chess_effort
print(chess_effort.resolve("browser-039")[2])
print(chess_effort.resolve("browser-038")[2])
print(chess_effort.resolve("game-12-rematch-3")[2])
print(chess_effort.resolve("no-number")[2] or "-")
print(chess_effort.resolve(None)[2] or "-")
os.environ["DESKCRAB_CHESS_EFFORT_SHARP"] = "high"
print(chess_effort.resolve("browser-038")[2])
print(" ".join(chess_effort.resolve("browser-038")[:2]))
EOF
)"
check_eq "odd is the sharp arm" "$(line "$out" 1)" "sharp"
check_eq "even is the lowered arm" "$(line "$out" 2)" "lowered"
check_eq "the TRAILING integer decides: game-12-rematch-3 is game 3, odd" \
    "$(line "$out" 3)" "sharp"
check_eq "no number, no arm" "$(line "$out" 4)" "-"
check_eq "no id, no arm" "$(line "$out" 5)" "-"
check_eq "an explicit knob is an operator's decision, arm 'env', not a \
parity claim the ledger would miscount" "$(line "$out" 6)" "env"
check_eq "and the unset knob beside it falls to the lowered default, \
exactly today's behaviour" "$(line "$out" 7)" "low high"

# --- the bridge stamps the arm onto the effort metrics row ----------------
# The same hub harness as test_chess_effort.sh: answer_position driven
# directly, the model call a stub answering from a reply map.
HUBDIR="$T/chess-hub"
mkdir -p "$HUBDIR/games"
WAKE_LOG="$T/wake.log"
WAKE_STUB="$T/wake-stub"
cat > "$WAKE_STUB" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WAKE_LOG"
SH
chmod +x "$WAKE_STUB"
MOVER_LOG="$T/mover.log"
MOVER_REPLIES="$T/mover-replies.tsv"
MOVER_STUB="$T/mover-stub"
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
printf 'game arm-001\tc2c4\ngame arm-002\tc2c4\n' > "$MOVER_REPLIES"
MET="$DESKCRAB_METRICS_DIR/$(date +%F).log"

seed_hub_game() { # <id> <moves json array>
  cat > "$HUBDIR/games/$1.json" <<JSON
{"id": "$1", "opponent": "hub", "my_side": "white", "moves": $2,
 "resigned_by": null, "draw_agreed": false, "engine_level": null,
 "created": "2026-01-01T00:00:00+00:00", "updated": "2026-01-01T00:00:00+00:00"}
JSON
}
# Twin games, one either side of the parity, standing on the same quiet
# ground — the very interleave the nine-day block never had.
seed_hub_game arm-001 '["d2d4", "d7d5"]'
seed_hub_game arm-002 '["d2d4", "d7d5"]'
DESKCRAB_CHESS_DIR="$HUBDIR" chess reflex --backfill >/dev/null

drive() { # <game id> — answer_position for that game's live board
  DESKCRAB_CHESS_DIR="$HUBDIR" DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
  DESKCRAB_CHESS_ALWAYS_LOW=0 \
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

echo
echo "the metrics row carries the arm, matching the parity:"
drive arm-001 >/dev/null
awk -F'\t' '$3=="chess" && $4=="effort" && $5 == "arm-001 ply 2 medium quiet arm=sharp"' "$MET" \
    | grep -q . \
  && ok "the odd game's effort row: the sharp arm's quiet level, arm=sharp" \
  || fail "odd arm stamp" "$(grep arm-001 "$MET")"
awk -F'\t' '$3=="chess" && $4=="model-start" && $5 ~ /^arm-001 ply 2 effort medium /' "$MET" \
    | grep -q . \
  && ok "and its model call went out at medium" \
  || fail "odd model-start" "$(grep model-start "$MET" | tail -3)"

drive arm-002 >/dev/null
awk -F'\t' '$3=="chess" && $4=="effort" && $5 == "arm-002 ply 2 low quiet arm=lowered"' "$MET" \
    | grep -q . \
  && ok "the even game's effort row: the lowered arm's quiet level, arm=lowered" \
  || fail "even arm stamp" "$(grep arm-002 "$MET")"
awk -F'\t' '$3=="chess" && $4=="model-start" && $5 ~ /^arm-002 ply 2 effort low /' "$MET" \
    | grep -q . \
  && ok "and its model call went out at low" \
  || fail "even model-start" "$(grep model-start "$MET" | tail -3)"

# --- rows from before the field still parse, and read as unknown ----------
echo
echo "a legacy row beside the new ones splits as unknown, never breaks:"
printf '1756000000.000\t12345\tchess\teffort\tlegacy-007 ply 4 low quiet\n' >> "$MET"
arms="$(awk -F'\t' '$3=="chess" && $4=="effort" {
    arm = "unknown"
    n = split($5, t, " ")
    for (i = 1; i <= n; i++)
        if (t[i] ~ /^arm=/) { sub(/^arm=/, "", t[i]); arm = t[i] }
    print t[1], arm
}' "$MET")"
echo "$arms" | grep -qx "arm-001 sharp" \
  && echo "$arms" | grep -qx "arm-002 lowered" \
  && ok "the ledger splits the new rows by their stamped arm" \
  || fail "ledger split" "$arms"
echo "$arms" | grep -qx "legacy-007 unknown" \
  && ok "and a row written before the field reads as unknown" \
  || fail "legacy row" "$arms"
