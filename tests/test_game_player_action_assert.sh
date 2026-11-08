#!/bin/bash
# Spec rule 17's action assertions: a replay case pins the winning action's
# SEMANTICS — type and parameters, with null asserting absence — so a
# movement's meaning (a full-distance acquisition seek versus a bounded
# combat break) is tested directly instead of inferred from displacement.
# The gate must therefore refuse a mutation that caps a seek's range, or
# that widens a break's own bound, even when the rule still wins its slot —
# and the add door must refuse an assertion the live table does not compile,
# so a seek can never be recorded as if it were an escape.
# Run: bash tests/test_game_player_action_assert.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
GP="$REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

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

# One acquisition seek and one bounded combat break, in the same objective.
check "an uncapped seek rule can be learned" \
    python3 "$GP" learn seek-target --priority 40 --cooldown-ms 0 \
        --trigger objective_is=assert-test --trigger out_of_combat=true \
        --trigger npc_visible=63 \
        --action interact-npc --param npc=63 --param cmd=1
check "a one-tile combat-break rule can be learned" \
    python3 "$GP" learn break-fight --priority 1000 --cooldown-ms 0 \
        --trigger objective_is=assert-test --trigger in_combat=true \
        --trigger npc_visible=63 \
        --action retreat --param distance=1 --param dx=0 --param dz=1

SEEK_SNAP="$SANDBOX/seek.json"
cat > "$SEEK_SNAP" <<'JSON'
{"tick": 100, "x": 100, "z": 100, "walking": false, "in_combat": false,
 "inventory": [{"id": 9, "count": 1}], "messages": [], "players": [],
 "npcs": [{"sidx": 5, "id": 63, "x": 105, "z": 100}],
 "objects": [], "bounds": [], "ground_items": [],
 "shop_open": false, "shop_items": [], "bank_open": false, "bank_items": []}
JSON
FIGHT_SNAP="$SANDBOX/fight.json"
cat > "$FIGHT_SNAP" <<'JSON'
{"tick": 101, "x": 100, "z": 100, "walking": false, "in_combat": true,
 "inventory": [{"id": 9, "count": 1}], "messages": [], "players": [],
 "npcs": [{"sidx": 5, "id": 63, "x": 101, "z": 100}],
 "objects": [], "bounds": [], "ground_items": [],
 "shop_open": false, "shop_items": [], "bank_open": false, "bank_items": []}
JSON

# The seek case pins full-distance acquisition with no range cap anywhere on
# the compiled action: target_distance is the real multi-tile walk, and
# within/max_path are asserted ABSENT.
check "a seek case pins its full distance and the absence of any cap" \
    python3 "$GP" test add seek-distant-target --objective assert-test \
        --expect seek-target --snapshot "$SEEK_SNAP" \
        --expect-action '{"type":"interact-npc","npc":63,"cmd":1,"target_distance":5,"within":null,"max_path":null}'

# The break case pins the one-tile bound onto the break action itself.
check "a combat-break case pins its own one-tile bound" \
    python3 "$GP" test add fight-breaks-one-tile --objective assert-test \
        --expect break-fight --snapshot "$FIGHT_SNAP" \
        --expect-action '{"type":"retreat","distance":1}'

check "the suite holds both assertions green" python3 "$GP" test

# The live confusion this door exists for: a cap wide enough that the rule
# STILL WINS its slot would pass a name-only case; the absence assertion is
# what refuses it.
CODE=0; OUT="$(python3 "$GP" set seek-target action.within 10 2>&1)" || CODE=$?
check_eq "a wide range cap on the seek is refused by the gate" "$CODE" "1"
contains "$OUT" "action.within must stay absent" \
    && ok "the refusal names the asserted-absent parameter" \
    || fail "the refusal names the asserted-absent parameter" "$OUT"

CODE=0; OUT="$(python3 "$GP" set seek-target action.within 3 2>&1)" || CODE=$?
check_eq "a narrow cap that idles the seek is refused too" "$CODE" "1"

check_eq "the seek rule still carries no cap" \
    "$(python3 - <<PY
import json, os
cfg = json.load(open(os.environ["DESKCRAB_GAME_DIR"] + "/learned-rules.json"))
rule = next(r for r in cfg["rules"] if r["name"] == "seek-target")
print("within" in rule["action"])
PY
)" "False"

# The bound is action-local: widening the break's own distance is refused by
# ITS assertion, while the seek's stays untouched.
CODE=0; OUT="$(python3 "$GP" set break-fight action.distance 5 2>&1)" || CODE=$?
check_eq "widening the one-tile break is refused" "$CODE" "1"
contains "$OUT" "action.distance is 5" \
    && ok "the refusal shows the widened compiled value" \
    || fail "the refusal shows the widened compiled value" "$OUT"

# No global movement cap hides in the door: a FAR retreat in another context
# stays learnable and assertable at its full distance.
MONSTER_SNAP="$SANDBOX/monster.json"
cat > "$MONSTER_SNAP" <<'JSON'
{"tick": 102, "x": 200, "z": 200, "walking": false, "in_combat": true,
 "inventory": [{"id": 9, "count": 1}], "messages": [], "players": [],
 "npcs": [{"sidx": 8, "id": 89, "x": 200, "z": 200}],
 "objects": [], "bounds": [], "ground_items": [],
 "shop_open": false, "shop_items": [], "bank_open": false, "bank_items": []}
JSON
check "a far monster retreat stays learnable" \
    python3 "$GP" learn flee-monster --priority 1000 --cooldown-ms 0 \
        --trigger objective_is=monster-test --trigger in_combat=true \
        --action retreat --param distance=5 --param dx=0 --param dz=1
check "and its full distance is assertable" \
    python3 "$GP" test add monster-far-retreat --objective monster-test \
        --expect flee-monster --snapshot "$MONSTER_SNAP" \
        --expect-action '{"type":"retreat","distance":5}'

# Misclassification is refused at the door: recording a seek as if it were
# an escape must die before the case lands.
CODE=0; OUT="$(python3 "$GP" test add seek-recorded-as-escape --objective assert-test \
    --expect seek-target --snapshot "$SEEK_SNAP" \
    --expect-action '{"type":"retreat"}' 2>&1)" || CODE=$?
check_eq "an assertion contradicting the compiled action is refused" "$CODE" "1"
contains "$OUT" "action.type is" \
    && ok "the refusal names the mismatched type" \
    || fail "the refusal names the mismatched type" "$OUT"

# An assertion with no winner is meaningless, at the door and at load.
CODE=0; OUT="$(python3 "$GP" test add no-winner-no-action --objective assert-test \
    --expect none --snapshot "$SEEK_SNAP" \
    --expect-action '{"type":"walk"}' 2>&1)" || CODE=$?
check_eq "expect none beside an action assertion is refused" "$CODE" "1"

CODE=0; OUT="$(python3 "$GP" test add malformed --objective assert-test \
    --expect seek-target --snapshot "$SEEK_SNAP" \
    --expect-action '[1,2]' 2>&1)" || CODE=$?
check_eq "a non-object assertion is refused" "$CODE" "1"

python3 - <<PY
import json, os
path = os.environ["DESKCRAB_GAME_DIR"] + "/learned-rule-tests.json"
tests = json.load(open(path))
tests["cases"].append({"name": "hand-written-orphan", "objective": "assert-test",
                       "expect": None, "snapshot": {"tick": 1},
                       "expect_action": {"type": "walk"}})
json.dump(tests, open(path, "w"))
PY
CODE=0; OUT="$(python3 "$GP" test 2>&1)" || CODE=$?
check_eq "a hand-written orphan assertion dies loudly at load" "$CODE" "1"
contains "$OUT" "no winner, no action to inspect" \
    && ok "the load refusal explains the orphan" \
    || fail "the load refusal explains the orphan" "$OUT"
python3 - <<PY
import json, os
path = os.environ["DESKCRAB_GAME_DIR"] + "/learned-rule-tests.json"
tests = json.load(open(path))
tests["cases"] = [c for c in tests["cases"] if c["name"] != "hand-written-orphan"]
json.dump(tests, open(path, "w"))
PY

contains "$(python3 "$GP" test list)" 'action={"type":"interact-npc"' \
    && ok "test list shows the assertion beside the expectation" \
    || fail "test list shows the assertion beside the expectation" \
       "$(python3 "$GP" test list)"

check "the suite ends green" python3 "$GP" test
refute "no model CLI was ever invoked" test -f "$SANDBOX/model-called"
