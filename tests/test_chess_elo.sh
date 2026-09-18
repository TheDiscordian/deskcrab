#!/bin/bash
# Elo per player and per game type — specs/chessweb.md rule 23e.
# Run: bash tests/test_chess_elo.sh
#
# The contract under test, over hand-seeded stored games (no bridge, no
# model, nothing live):
#
#   1. One rating pool per speed: a blitz result never moves a rapid or
#      untimed rating.
#   2. Ratings move the right way and stay zero-sum within a game: from
#      1200/1200, her mate win prices 1216/1184; the return loss prices
#      1199/1201 (the favourite lost, so the swing is bigger than 16).
#   3. A draw between equals moves nothing.
#   4. Self-play games never enter any pool; an unlabeled browser game
#      keeps its own visible bucket, exactly the record's identity.
#   5. The walk is deterministic: two calls answer the same figures.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
    echo "SKIP: no chess venv at $VENV — the tally needs python-chess"
    exit 0
fi

PYOUT="$(env DESKCRAB_CHESS_DIR="$T/chess-games" "$PY" -B - <<PYEOF
import json, os, sys
sys.path.insert(0, "$REPO/lib")
import chess_cli

os.makedirs(os.path.join("$T/chess-games", "games"), exist_ok=True)

def seed(gid, opponent, my_side, moves, updated, player=None, control=None,
         resigned_by=None, draw_agreed=False):
    g = {"id": gid, "opponent": opponent, "my_side": my_side,
         "moves": moves, "resigned_by": resigned_by,
         "draw_agreed": draw_agreed, "engine_level": None,
         "created": updated, "updated": updated}
    if player:
        g["player"] = player
    if control:
        tc, clock = chess_cli.make_time_control(control)
        g["time_control"], g["clock"] = tc, clock
    with open(os.path.join("$T/chess-games", "games", gid + ".json"),
              "w") as f:
        json.dump(g, f)

FOOLS = ["f2f3", "e7e5", "g2g4", "d8h4"]  # black mates
# Blitz vs Mitch: her mate win first, her resignation second.
seed("g-001", "browser", "black", FOOLS, "2026-01-01T00:00:00+00:00",
     player="Mitch", control="3+2")
seed("g-002", "browser", "black", ["e2e4", "e7e5"],
     "2026-01-02T00:00:00+00:00", player="Mitch", control="3+2",
     resigned_by="black")
# Rapid vs Visitor: an agreed draw between equals.
seed("g-003", "browser", "white", ["e2e4", "e7e5"],
     "2026-01-03T00:00:00+00:00", player="Visitor", control="15+10",
     draw_agreed=True)
# Untimed, unlabeled browser sitter: her mate win.
seed("g-004", "browser", "black", FOOLS, "2026-01-04T00:00:00+00:00")
# Self-play: finished, and never rated.
seed("selfplay-x-001", "selfplay", "black", FOOLS,
     "2026-01-05T00:00:00+00:00", control="3+2")
# Active game: no result yet, rated nowhere.
seed("g-005", "browser", "white", ["e2e4"], "2026-01-06T00:00:00+00:00",
     player="Mitch", control="3+2")

pools = chess_cli.elo_tally()
print("pool-speeds:", " ".join(sorted(pools)))
blitz = pools["blitz"]
mitch = next(b for b in blitz["players"] if b["player"] == "Mitch")
print("blitz-her:", blitz["her"]["rating"], blitz["her"]["games"])
print("blitz-mitch:", mitch["rating"], mitch["games"],
      f"{mitch['wins']}-{mitch['draws']}-{mitch['losses']}")
rapid = pools["rapid"]
print("rapid-draw:", rapid["her"]["rating"],
      rapid["players"][0]["rating"], rapid["players"][0]["player"])
unt = pools["untimed"]
print("untimed-bucket:", unt["players"][0]["player"],
      unt["players"][0]["labeled"], unt["her"]["rating"])
print("selfplay-rated:", any("selfplay" in (b["player"] or "").lower()
                             for p in pools.values()
                             for b in p["players"]))
print("deterministic:", pools == chess_cli.elo_tally())
PYEOF
)"
echo "$PYOUT" | sed 's/^/    /'

contains "$PYOUT" "pool-speeds: blitz rapid untimed" \
    && ok "one pool per speed, and only speeds with finished games" \
    || fail "pools" "$(printf '%s\n' "$PYOUT" | grep pool-speeds)"
contains "$PYOUT" "blitz-her: 1199 2" \
    && ok "her blitz rating priced the win then the favoured loss (1199)" \
    || fail "her blitz" "$(printf '%s\n' "$PYOUT" | grep blitz-her)"
contains "$PYOUT" "blitz-mitch: 1201 2 1-0-1" \
    && ok "the opponent's rating mirrors it zero-sum, record from her side" \
    || fail "mitch blitz" "$(printf '%s\n' "$PYOUT" | grep blitz-mitch)"
contains "$PYOUT" "rapid-draw: 1200 1200 Visitor" \
    && ok "a draw between equals moves nothing, in its own pool" \
    || fail "rapid draw" "$(printf '%s\n' "$PYOUT" | grep rapid-draw)"
contains "$PYOUT" "untimed-bucket: browser False 1216" \
    && ok "an unlabeled browser sitter keeps its own visible bucket" \
    || fail "untimed" "$(printf '%s\n' "$PYOUT" | grep untimed-bucket)"
contains "$PYOUT" "selfplay-rated: False" \
    && ok "self-play never enters a pool" \
    || fail "selfplay" "$(printf '%s\n' "$PYOUT" | grep selfplay-rated)"
contains "$PYOUT" "deterministic: True" \
    && ok "two walks answer the same figures — counted, never stored" \
    || fail "determinism" "$(printf '%s\n' "$PYOUT" | grep deterministic)"
