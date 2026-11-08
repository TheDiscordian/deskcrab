#!/bin/bash
# Goal-directed recovery safeguards (specs/game-player.md rules 7f and 7h):
# the retrace door's squared-distance postcondition toward one chosen prior
# tile, coordinate-free movement-contradiction detection that stops a dragged
# backtrack from blind-retrying, goal invariants whose evaluation is computed
# from structured state, the shared-resource-is-not-destination verdict, and
# the rule that incidental benefit never converts a failed movement into
# success. Scenario coordinates below are regression FIXTURES (one reproduces
# the observed wrong-way drag); nothing in the runtime policy names them.
# Run: bash tests/test_game_player_recovery.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
GP="$REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
mkdir -p "$DESKCRAB_GAME_STATE_DIR"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# Any model CLI invoked anywhere in the player is a spec breach (rule 2).
MODELTRAP="$SANDBOX/modeltrap"
mkdir -p "$MODELTRAP"
for bin in claude codex; do
    printf '#!/bin/sh\ntouch "%s/model-called"\nexit 1\n' "$SANDBOX" > "$MODELTRAP/$bin"
    chmod +x "$MODELTRAP/$bin"
done
export PATH="$MODELTRAP:$PATH"

python3 "$GP" init >/dev/null

# snap X Z TICK [extra-json] — a fresh logged-in snapshot at that tile.
snap() {
    local extra='{}'
    [ $# -ge 4 ] && extra="$4"
    python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" "$1" "$2" "$3" "$extra" <<'PY'
import json, sys, time
path, x, z, tick, extra = sys.argv[1:6]
snap = {"v": 1, "ts": int(time.time() * 1000), "tick": int(tick),
        "logged_in": True, "hits": 10, "hits_max": 10, "fatigue": 0,
        "x": int(x), "z": int(z), "walking": False, "in_combat": False,
        "talking_to_npc": False, "opponent": None,
        "inventory": [], "messages": [], "npcs": [], "objects": [],
        "bounds": [], "ground_items": []}
snap.update(json.loads(extra))
json.dump(snap, open(path, "w"))
PY
}

# trail X1,Z1 X2,Z2 … — seed the observed movement trail, oldest first.
trail() {
    python3 - "$DESKCRAB_GAME_DIR/movement-trail.json" "$@" <<'PY'
import json, sys, time
path = sys.argv[1]
now = int(time.time() * 1000)
points = []
for index, pair in enumerate(sys.argv[2:]):
    x, z = pair.split(",")
    points.append({"x": int(x), "z": int(z), "ts": now - 60000 + index * 500,
                   "break": False})
json.dump({"v": 1, "points": points}, open(path, "w"))
PY
}

# move_bridge SETTLE_X SETTLE_Z — one-shot: consume action.json, keep a copy
# in last-action, answer the receipt, and settle the body at the given tile
# regardless of what the walk requested. This is the fixture for a body owned
# by something other than the request.
move_bridge() {
    python3 - "$DESKCRAB_GAME_STATE_DIR" "$1" "$2" <<'PY' &
import json, os, sys, time
sd, sx, sz = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ap = os.path.join(sd, "action.json")
for _ in range(200):
    if os.path.exists(ap):
        body = open(ap).read()
        open(os.path.join(sd, "last-action"), "w").write(body)
        os.remove(ap)
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        tmp = os.path.join(sd, ".receipt.tmp")
        json.dump({"id": int(fields["id"]), "status": "done",
                   "ts": int(time.time() * 1000)}, open(tmp, "w"))
        os.replace(tmp, os.path.join(sd, "receipt.json"))
        state_path = os.path.join(sd, "state.json")
        state = json.load(open(state_path))
        state["x"], state["z"] = sx, sz
        state["tick"] = int(state.get("tick", 0)) + 1
        state["ts"] = int(time.time() * 1000)
        tmp2 = state_path + ".settle.tmp"
        json.dump(state, open(tmp2, "w"))
        os.replace(tmp2, state_path)
        break
    time.sleep(0.05)
PY
    MOVE_BRIDGE_PID=$!
}

echo "— movement_agrees is coordinate-free displacement algebra —"
AGREES="$(python3 - "$REPO/lib" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import game_player as gp
cases = [
    # start        leg           settled       want
    ((0, 0),  (0, -8),  (0, -3),  True),    # moved with the request
    ((0, 0),  (0, -8),  (0,  3),  False),   # moved against it (the drag)
    ((0, 0),  (8,  0),  (0,  5),  False),   # purely sideways: no component
    ((0, 0),  (5,  5),  (2,  1),  True),    # diagonal agreement
    ((0, 0),  (0, -8),  (0,  0),  False),   # asked to move, body did not
]
bad = [c for c in cases
       if gp.movement_agrees(c[0][0], c[0][1], c[1][0], c[1][1],
                             c[2][0], c[2][1]) != c[3]]
print("ok" if not bad else f"bad:{bad}")
PY
)"
check_eq "requested-versus-observed displacement truth table" "$AGREES" "ok"

echo "— retrace refuses a target that is not observed prior evidence —"
trail 76,660 76,662 76,665
snap 76 665 100
OUT="$(python3 "$GP" retrace 10 10 2>&1)"; RC=$?
check_eq "an arbitrary coordinate is refused (exit 2)" "$RC" "2"
check "the refusal names the missing evidence" contains "$OUT" "retrace-not-prior-tile"
check "the refusal offers recent trail tiles instead" contains "$OUT" "(76,665)"
refute "no action was dispatched for a refused retrace" test -e "$DESKCRAB_GAME_STATE_DIR/last-action"

echo "— retrace proves squared-distance progress toward the chosen tile —"
trail 76,646 76,649 76,652 76,655 76,658 76,660 76,662 76,665
snap 76 665 110
move_bridge 76 657
OUT="$(python3 "$GP" retrace 76 649 2>&1)"; RC=$?
wait "$MOVE_BRIDGE_PID"
check_eq "a settle strictly closer is retrace-progress (exit 0)" "$RC" "0"
check "the postcondition names both squared distances" contains "$OUT" "d2=256->64"
check "the movement request was one bounded leg" contains "$OUT" "retrace-progress"
LAST="$(cat "$DESKCRAB_GAME_STATE_DIR/last-action")"
check "the dispatched action is an ordinary receipted walk" contains "$LAST" "type=walk"
refute "the in-progress movement record is cleaned up" \
    test -e "$DESKCRAB_GAME_STATE_DIR/movement-in-progress.json"

echo "— the observed wrong-way drag becomes retrace-regressed, never progress —"
# Fixture from the live episode: at (76,665) a walk toward (76,649) receipted
# done while the body settled farther south at (76,670).
rm -f "$DESKCRAB_GAME_STATE_DIR/last-action"
snap 76 665 120
move_bridge 76 670
OUT="$(python3 "$GP" retrace 76 649 2>&1)"; RC=$?
wait "$MOVE_BRIDGE_PID"
check_eq "a settle no closer is retrace-regressed (exit 2)" "$RC" "2"
check "the verdict carries the disagreeing displacements" contains "$OUT" "observed=(0,5)"
check "the regression is not a useful substitute" contains "$OUT" "useful_substitute=false"
check "repeating the identical request is explicitly unlicensed" \
    contains "$OUT" "repeating-the-identical-request-is-not-licensed"
TAIL="$(tail -1 "$DESKCRAB_GAME_DIR/outcome-queue.jsonl")"
check "the outcome queue carries the failure for the author" \
    contains "$TAIL" '"useful_substitute":false'
check "the outcome names the retrace and both distances" contains "$TAIL" '"d2_after":441'

echo "— retrace arrival is measured at the chosen tile —"
trail 76,646 76,649 76,652
snap 76 650 130
move_bridge 76 649
OUT="$(python3 "$GP" retrace 76 649 2>&1)"; RC=$?
wait "$MOVE_BRIDGE_PID"
check_eq "settling on the chosen prior tile is done (exit 0)" "$RC" "0"
check "arrival reports the closed distance" contains "$OUT" "d2=1->0"

echo "— retrace yields to the binding movement commitments —"
python3 - "$DESKCRAB_GAME_DIR/route.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "x": 200, "z": 200, "arrive": 1, "objective": "",
           "status": "active", "set_ts": int(time.time() * 1000)},
          open(sys.argv[1], "w"))
PY
snap 76 650 140
OUT="$(python3 "$GP" retrace 76 649 2>&1)"; RC=$?
check_eq "an explicit route refuses retrace (exit 2)" "$RC" "2"
check "the route conflict names the commitment" contains "$OUT" "retrace-conflicts-route"
rm -f "$DESKCRAB_GAME_DIR/route.json"
python3 - "$DESKCRAB_GAME_DIR/backtrack.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "objective": "", "status": "active", "index": 0,
           "points": [[76, 646]], "set_ts": int(time.time() * 1000)},
          open(sys.argv[1], "w"))
PY
OUT="$(python3 "$GP" retrace 76 649 2>&1)"; RC=$?
check_eq "an active backtrack refuses retrace (exit 2)" "$RC" "2"
check "the backtrack conflict is named" contains "$OUT" "retrace-conflicts-backtrack"

echo "— a diverged backtrack is replaced by an explicit retrace —"
python3 - "$DESKCRAB_GAME_DIR/backtrack.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "objective": "", "status": "diverged", "index": 0,
           "points": [[76, 633]], "contradictions": 3,
           "set_ts": int(time.time() * 1000)}, open(sys.argv[1], "w"))
PY
snap 76 650 150
move_bridge 76 649
OUT="$(python3 "$GP" retrace 76 649 2>&1)"; RC=$?
wait "$MOVE_BRIDGE_PID"
check_eq "retrace proceeds over a diverged request (exit 0)" "$RC" "0"
refute "the diverged request is consumed" test -e "$DESKCRAB_GAME_DIR/backtrack.json"
check "the replacement is recorded" \
    contains "$(tail -5 "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl")" \
    "backtrack-replaced-by-retrace"

echo "— three contradictory settles diverge a backtrack instead of retrying —"
# The runner's blind loop from the live episode: each leg asked for north,
# the body settled farther south, and a changed obstacle signature re-armed
# the same failing approach. Scenery changes each round keep the signature
# moving exactly as a dragged body sees it.
trail 76,633 76,638 76,641 76,646
python3 - "$DESKCRAB_GAME_DIR/backtrack.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "objective": "", "status": "active", "index": 0,
           "points": [[76, 633]], "set_ts": int(time.time() * 1000)},
          open(sys.argv[1], "w"))
PY
snap 76 646 200 '{"objects": [{"id": 5, "x": 70, "z": 640, "dir": 0}]}'
move_bridge 76 649
python3 "$GP" step >/dev/null 2>&1
wait "$MOVE_BRIDGE_PID"
BT="$(cat "$DESKCRAB_GAME_DIR/backtrack.json")"
check "the first contradictory settle blocks and counts" \
    contains "$BT" '"contradictions": 1'
check "one contradiction is not yet divergence" contains "$BT" '"status": "blocked"'

snap 76 654 210 '{"objects": [{"id": 5, "x": 70, "z": 648, "dir": 0}]}'
move_bridge 76 657
python3 "$GP" step >/dev/null 2>&1
wait "$MOVE_BRIDGE_PID"
check "the second contradictory settle keeps counting" \
    contains "$(cat "$DESKCRAB_GAME_DIR/backtrack.json")" '"contradictions": 2'

snap 76 662 220 '{"objects": [{"id": 5, "x": 70, "z": 656, "dir": 0}]}'
move_bridge 76 665
python3 "$GP" step >/dev/null 2>&1
wait "$MOVE_BRIDGE_PID"
BT="$(cat "$DESKCRAB_GAME_DIR/backtrack.json")"
check "the third contradiction diverges the recovery" \
    contains "$BT" '"status": "diverged"'
check "the divergence names its evidence" \
    contains "$BT" '"diverged_reason": "movement-opposed-request"'
check "the contradiction outcome is queued, marked useless as a substitute" \
    contains "$(grep movement-contradiction "$DESKCRAB_GAME_DIR/outcome-queue.jsonl" | tail -1)" \
    '"useful_substitute":false'

rm -f "$DESKCRAB_GAME_STATE_DIR/last-action"
snap 76 670 230 '{"objects": [{"id": 5, "x": 70, "z": 664, "dir": 0}]}'
OUT="$(python3 "$GP" step 2>&1)"; RC=$?
check "a diverged backtrack emits nothing despite a changed signature" \
    contains "$OUT" "backtrack-diverged"
check_eq "divergence licenses reasoning (exit 4)" "$RC" "4"
refute "no walk was re-dispatched into the drag" \
    test -e "$DESKCRAB_GAME_STATE_DIR/last-action"
check "the diverged verdict points at the recovery doors" \
    contains "$OUT" "retrace-a-chosen-prior-tile"
rm -f "$DESKCRAB_GAME_DIR/backtrack.json"

echo "— goal invariants: destination success is computed, never composed —"
OUT="$(python3 "$GP" goal 2>&1)"
check "no goal declared reports goal-none and gates nothing" \
    contains "$OUT" "goal-none"
refute "an unknown requirement kind is refused" \
    python3 "$GP" goal set "impossible" --require "teleport=1" 2>/dev/null
refute "an unknown entity collection is refused" \
    python3 "$GP" goal set "impossible" --require "entity=walls:name:door" 2>/dev/null
refute "a goal without requirements is refused" \
    python3 "$GP" goal set "vague intention" 2>/dev/null

# The regression the correction demands: the declared goal is one SPECIFIC
# bank; a different bank's open interface plus a same-name teller must never
# read as success merely because the items were accessible.
python3 "$GP" goal set "bank at the declared west-city branch" \
    --require "arrive=150,504,3" --require "interface=bank" \
    --require "entity=npcs:name:Banker:8" >/dev/null
WRONG='{"v":1,"ts":0,"tick":1,"logged_in":true,"x":89,"z":694,"bank_open":true,
"inventory":[{"id":10,"count":1}],"messages":[{"text":"You deposit the item"}],
"npcs":[{"id":95,"name":"Banker","x":90,"z":695}],"objects":[],"bounds":[]}'
OUT="$(printf '%s' "$WRONG" | python3 "$GP" goal check --snapshot - 2>&1)"; RC=$?
check_eq "a wrong-bank arrival is a failure even with banking done (exit 2)" "$RC" "2"
check "the verdict is the shared-resource distinction" \
    contains "$OUT" "goal-unmet-shared-resource"
check "the computed assessment bans the post-hoc useful-trip story" \
    contains "$OUT" "assessment=shared-resource-access-not-destination-success"
check "useful_substitute is false in the verdict" \
    contains "$OUT" "useful_substitute=false"
check "only the place requirement is unmet — banking itself worked" \
    contains "$OUT" "unmet=arrive=(150,504)"
TAIL="$(grep unintended-outcome "$DESKCRAB_GAME_DIR/outcome-queue.jsonl" | tail -1)"
check "the navigation failure reaches the author's queue" \
    contains "$TAIL" '"useful_substitute":false'

RIGHT='{"v":1,"ts":0,"tick":1,"logged_in":true,"x":151,"z":505,"bank_open":true,
"inventory":[],"messages":[],
"npcs":[{"id":95,"name":"Banker","x":150,"z":504}],"objects":[],"bounds":[]}'
OUT="$(printf '%s' "$RIGHT" | python3 "$GP" goal check --snapshot - 2>&1)"; RC=$?
check_eq "the declared branch itself is goal-met (exit 0)" "$RC" "0"
check "normal banking at the right place is untouched" contains "$OUT" "goal-met"
python3 "$GP" goal clear --reason "banking scenario finished" >/dev/null

echo "— the same invariants cover quest and interaction targets —"
python3 "$GP" goal set "weaken the summoned demon with the named spell" \
    --require "entity=npcs:name:Delrith:10" --require "message=spell weakens" \
    >/dev/null
EMPTY='{"v":1,"ts":0,"tick":1,"logged_in":true,"x":120,"z":648,
"inventory":[],"messages":[],"npcs":[],"objects":[],"bounds":[]}'
OUT="$(printf '%s' "$EMPTY" | python3 "$GP" goal check --snapshot - 2>&1)"; RC=$?
check_eq "an empty room satisfies nothing (exit 2)" "$RC" "2"
check "both unmet requirements are named" contains "$OUT" "entity=npcs:name:Delrith"
QUEST='{"v":1,"ts":0,"tick":1,"logged_in":true,"x":120,"z":648,
"inventory":[],"messages":[{"text":"The spell weakens the demon"}],
"npcs":[{"id":100,"name":"Delrith","x":122,"z":650}],"objects":[],"bounds":[]}'
OUT="$(printf '%s' "$QUEST" | python3 "$GP" goal check --snapshot - 2>&1)"; RC=$?
check_eq "the present target and grounded feedback meet it (exit 0)" "$RC" "0"
python3 "$GP" goal clear --reason "quest scenario finished" >/dev/null

echo "— a goal binds to the objective that declared it —"
python3 "$GP" goal set "held-over goal" --require "inventory_has=42" >/dev/null
python3 - "$DESKCRAB_GAME_DIR/goal-invariants.json" <<'PY'
import json, sys
goal = json.load(open(sys.argv[1]))
goal["objective"] = "some-earlier-objective"
json.dump(goal, open(sys.argv[1], "w"))
PY
OUT="$(printf '%s' "$EMPTY" | python3 "$GP" goal check --snapshot - 2>&1)"; RC=$?
check_eq "a goal from another objective is stale (exit 2)" "$RC" "2"
check "staleness is named, not silently evaluated" contains "$OUT" "goal-stale"
python3 - "$DESKCRAB_GAME_DIR/goal-invariants.json" <<'PY'
import json, sys
goal = json.load(open(sys.argv[1]))
goal["objective"] = None
json.dump(goal, open(sys.argv[1], "w"))
PY
python3 "$GP" objective "tutorial-progress" >/dev/null 2>&1
refute "an objective change clears the goal with the plan" \
    test -e "$DESKCRAB_GAME_DIR/goal-invariants.json"

echo
refute "and still: no model CLI was invoked anywhere in the suite" \
    test -f "$SANDBOX/model-called"
