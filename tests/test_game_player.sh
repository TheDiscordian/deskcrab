#!/bin/bash
# The learned deliberate-play rules layer (specs/game-player.md): durable
# creation and loading of trigger+action rules, rules-first evaluation against
# the bridge snapshot with NO model call, execution through the bridge's one
# action slot, the reflex engine's shared discipline (priority, cooldown,
# debounce, conflict logging, hold override), the fallback contract (exit 4 is
# the only licence for model reasoning), persistence across player restarts,
# and the real playing entrypoint (orsc-headless.sh play) invoking all of it.
# Run: bash tests/test_game_player.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
GP="$REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# Any model CLI invoked anywhere in the player is a spec breach (rule 2).
# These traps sit at the HEAD of PATH and leave a marker if ever executed.
MODELTRAP="$SANDBOX/modeltrap"
mkdir -p "$MODELTRAP"
for bin in claude codex; do
    printf '#!/bin/sh\ntouch "%s/model-called"\nexit 1\n' "$SANDBOX" > "$MODELTRAP/$bin"
    chmod +x "$MODELTRAP/$bin"
done
export PATH="$MODELTRAP:$PATH"

# snap <tick> [npcs-json] [extra-json-pairs] — a fresh logged-in snapshot.
snap() {
    local npcs='[]' extra='{}'
    [ $# -ge 2 ] && npcs="$2"
    [ $# -ge 3 ] && extra="$3"
    python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" "$1" "$npcs" "$extra" <<'PY'
import json, sys, time
path, tick, npcs, extra = sys.argv[1:5]
snap = {"v": 1, "ts": int(time.time() * 1000), "tick": int(tick),
        "logged_in": True, "hits": 10, "hits_max": 10, "fatigue": 0,
        "x": 120, "z": 648, "in_combat": False, "opponent": None,
        "inventory": [{"id": 376, "count": 1}, {"id": 349, "count": 1}],
        "messages": [{"text": "Welcome to the game"}],
        "npcs": json.loads(npcs)}
snap.update(json.loads(extra))
json.dump(snap, open(path, "w"))
PY
}

# A one-shot fake bridge: consume action.json, keep a copy in last-action,
# answer receipt.json with the given status. Runs in the background so step
# can await the receipt like the real loop does.
fake_bridge() {
    python3 - "$DESKCRAB_GAME_STATE_DIR" "${1:-done}" <<'PY' &
import json, os, sys, time
sd, status = sys.argv[1], sys.argv[2]
ap = os.path.join(sd, "action.json")
for _ in range(100):
    if os.path.exists(ap):
        body = open(ap).read()
        open(os.path.join(sd, "last-action"), "w").write(body)
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        os.remove(ap)
        tmp = os.path.join(sd, ".receipt.tmp")
        json.dump({"id": int(fields["id"]), "status": status,
                   "ts": int(time.time() * 1000)}, open(tmp, "w"))
        os.replace(tmp, os.path.join(sd, "receipt.json"))
        break
    time.sleep(0.05)
PY
    FAKE_BRIDGE_PID=$!
}

last_action() { sandbox_count_in "^$1" "$DESKCRAB_GAME_STATE_DIR/last-action"; }
decided() { sandbox_count_in "\"kind\":\"$1\"" "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl"; }
loosen() {  # pacing must not couple unrelated cases: interval 0, wide cap
    python3 - "$DESKCRAB_GAME_DIR/learned-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg.setdefault("defaults", {})["min_action_interval_ms"] = 0
cfg["defaults"]["max_actions_per_min"] = 100
json.dump(cfg, open(sys.argv[1], "w"))
PY
}

echo "init and the validation gate (spec rules 3-6, 11):"
check "init writes an empty learned table" python3 "$GP" init
check "the table file exists" test -f "$DESKCRAB_GAME_DIR/learned-rules.json"
check "a second init leaves it untouched" python3 "$GP" init
loosen
refute "an unknown trigger key is refused" \
    python3 "$GP" learn bad1 --priority 1 --trigger hp_below=0.5 --action walk --param x=1 --param z=1
refute "a reflex-channel action (warn) is refused" \
    python3 "$GP" learn bad2 --priority 1 --trigger npc_visible=478 --action warn --param text=x
refute "talk-npc without its npc id is refused" \
    python3 "$GP" learn bad3 --priority 1 --trigger npc_visible=478 --action talk-npc
refute "a near_tile radius beyond 50 is refused" \
    python3 "$GP" learn bad4 --priority 1 --trigger 'near_tile={"x":1,"z":1,"radius":99}' --action walk --param x=1 --param z=1
check "learn persists a valid rule" \
    python3 "$GP" learn talk-cook --priority 50 --cooldown-ms 0 --once-per-objective \
        --note "verified today: receipt done, dialogue advanced" \
        --trigger objective_is=tut-cooking --trigger npc_visible=478 \
        --action talk-npc --param npc=478
refute "a second rule with a taken name is refused" \
    python3 "$GP" learn talk-cook --priority 1 --trigger npc_visible=478 --action talk-npc --param npc=478
RULES_OUT="$(python3 "$GP" rules)"
contains "$RULES_OUT" "[on ] talk-cook" && ok "a learned rule arrives enabled" \
    || fail "a learned rule arrives enabled" "$RULES_OUT"
contains "$RULES_OUT" "note: verified today" && ok "the provenance note rides the rule" \
    || fail "the provenance note rides the rule" "$RULES_OUT"
check "unfinished records an ungroundable play" \
    python3 "$GP" unfinished open-advisor-door camera-dependent screen press: bridge has no door action
contains "$(python3 "$GP" rules)" "[UNFINISHED] open-advisor-door" \
    && ok "rules lists the unfinished ledger" || fail "rules lists the unfinished ledger"

echo
echo "matching bridge input fires with no model call (spec rules 2, 5, 7):"
python3 "$GP" objective tut-cooking >/dev/null
# Two NPCs of the wanted type, nearest first: the emitted sidx must be the near one.
snap 100 '[{"sidx":77,"id":478,"x":121,"z":648},{"sidx":88,"id":478,"x":140,"z":660}]'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "step exits 0 on a done receipt" "$CODE" "0"
contains "$OUT" "fired rule=talk-cook" && ok "the verdict names the rule" \
    || fail "the verdict names the rule" "$OUT"
contains "$OUT" "status=done" && ok "and carries the receipt status" \
    || fail "and carries the receipt status" "$OUT"
check_eq "the action was a talk-npc" "$(last_action 'type=talk-npc')" "1"
check_eq "aimed at the NEAREST matching server index" "$(last_action 'sidx=77')" "1"
check_eq "double-checked by type id in the npc field" "$(last_action 'npc=478')" "1"
refute "the slot was consumed" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
refute "no model CLI was ever invoked" test -f "$SANDBOX/model-called"
check_eq "the firing is in the decision log" "$(decided fired)" "1"
check_eq "so is the receipt" "$(decided receipt)" "1"

echo
echo "a learned rule persists across player restarts (spec rules 1, 9, 11):"
contains "$(python3 "$GP" rules)" "[on ] talk-cook" \
    && ok "a fresh process loads the durable table" \
    || fail "a fresh process loads the durable table"
snap 101 '[{"sidx":77,"id":478,"x":121,"z":648}]'
OUT="$(python3 "$GP" step)"; CODE=$?
check_eq "the once-per-objective mark survived the restart: no refire" "$CODE" "4"
contains "$OUT" "no-rule-matched" && ok "and the verdict says why nothing fired" \
    || fail "and the verdict says why nothing fired" "$OUT"
python3 "$GP" objective tut-cooking-two >/dev/null
python3 "$GP" set talk-cook trigger.objective_is tut-cooking-two >/dev/null
snap 102 '[{"sidx":77,"id":478,"x":121,"z":648}]'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a new objective clears the mark: it fires again" "$CODE" "0"

echo
echo "nonmatching input does not fire (spec rules 4, 7):"
snap 103 '[{"sidx":99,"id":11,"x":124,"z":650}]'
OUT="$(python3 "$GP" step)"; CODE=$?
check_eq "wrong NPC on screen: exit 4, the fallback signal" "$CODE" "4"
refute "and no action was written" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 "$GP" objective --clear >/dev/null
snap 104 '[{"sidx":77,"id":478,"x":121,"z":648}]'
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
check_eq "right NPC but no objective set: objective_is can never hold" "$CODE" "4"
refute "still no action" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"

echo
echo "priority and conflict logging (spec rule 8):"
python3 "$GP" learn walk-low --priority 10 --cooldown-ms 0 \
    --trigger message_contains=welcome --action walk --param x=125 --param z=650 >/dev/null
python3 "$GP" learn walk-high --priority 90 --cooldown-ms 0 \
    --trigger message_contains=welcome --action walk --param x=200 --param z=700 >/dev/null
snap 105
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
contains "$OUT" "fired rule=walk-high" && ok "the higher priority took the one slot" \
    || fail "the higher priority took the one slot" "$OUT"
check_eq "message_contains matched case-insensitively" "$CODE" "0"
check_eq "the walk is unclamped deliberate travel (x=200 from 120)" "$(last_action 'x=200')" "1"
check_eq "the loser is logged as a conflict loss" "$(decided conflict-loss)" "1"

echo
echo "a refused compilation falls through to the next rule (spec rule 10):"
python3 "$GP" learn talk-ghost --priority 95 --cooldown-ms 0 \
    --trigger message_contains=welcome --action talk-npc --param npc=999 >/dev/null
snap 106
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the invisible NPC's rule was refused, logged" "$(decided refused)" "1"
contains "$OUT" "fired rule=walk-high" && ok "and the next rule got the slot" \
    || fail "and the next rule got the slot" "$OUT"
python3 "$GP" remove talk-ghost >/dev/null

echo
echo "cooldown (spec rule 8):"
python3 "$GP" set walk-high cooldown_ms 60000 >/dev/null
python3 "$GP" disable walk-low >/dev/null
snap 107
OUT="$(python3 "$GP" step)"; CODE=$?
check_eq "inside the cooldown nothing fires: fallback signalled" "$CODE" "4"
contains "$OUT" "cooldown_holds=1" && ok "and the hold is visible on the verdict line" \
    || fail "and the hold is visible on the verdict line" "$OUT"
check_eq "the suppression is logged once" "$(decided cooldown-hold)" "1"

echo
echo "hold_ticks debounce (spec rule 8):"
python3 "$GP" learn walk-debounce --priority 96 --cooldown-ms 0 --hold-ticks 2 \
    --trigger message_contains=welcome --action walk --param x=130 --param z=650 >/dev/null
snap 108
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
check_eq "one matching snapshot is not enough at hold_ticks 2" "$CODE" "4"
snap 109
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
contains "$OUT" "fired rule=walk-debounce" && ok "the second consecutive one fires" \
    || fail "the second consecutive one fires" "$OUT"
python3 "$GP" remove walk-debounce >/dev/null

echo
echo "not-ready verdicts fire nothing (spec rules 7-8):"
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
check_eq "the same tick never acts twice: exit 3" "$CODE" "3"
python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "ts": int(time.time() * 1000) - 9000, "tick": 110,
           "logged_in": True, "hits": 10, "hits_max": 10, "x": 120, "z": 648,
           "inventory": [], "messages": [{"text": "Welcome to the game"}],
           "npcs": []}, open(sys.argv[1], "w"))
PY
OUT="$(python3 "$GP" step)"; CODE=$?
check_eq "a stale snapshot is exit 3" "$CODE" "3"
contains "$OUT" "stale" && ok "and says so" || fail "and says so" "$OUT"
python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "ts": int(time.time() * 1000), "tick": 111,
           "logged_in": False}, open(sys.argv[1], "w"))
PY
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "a logged-out snapshot is exit 3" "$CODE" "3"
snap 112
printf 'ts=1\nid=1\ntype=walk\nx=1\nz=1\n' > "$DESKCRAB_GAME_STATE_DIR/action.json"
OUT="$(python3 "$GP" step)"; CODE=$?
check_eq "an unconsumed action slot is never overwritten: exit 3" "$CODE" "3"
contains "$OUT" "slot-busy" && ok "named slot-busy" || fail "named slot-busy" "$OUT"
check_eq "the foreign action file is untouched" \
    "$(sandbox_count_in '^id=1' "$DESKCRAB_GAME_STATE_DIR/action.json")" "1"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"

echo
echo "the manual override (spec rule 8; game-reflex rule 15):"
touch "$DESKCRAB_GAME_STATE_DIR/hold"
snap 113
OUT="$(python3 "$GP" step)"; CODE=$?
check_eq "held: exit 5 — not even the fallback is licensed" "$CODE" "5"
contains "$OUT" "held" && ok "and the verdict says held" || fail "and the verdict says held" "$OUT"
refute "nothing was emitted" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
rm -f "$DESKCRAB_GAME_STATE_DIR/hold"

echo
echo "a non-done receipt is a visible exit 2 (spec rule 7):"
python3 "$GP" set walk-high cooldown_ms 0 >/dev/null
snap 114
fake_bridge refused-no-such-npc
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the action emitted but did not execute: exit 2" "$CODE" "2"
contains "$OUT" "status=refused-no-such-npc" && ok "the refusal rides the verdict" \
    || fail "the refusal rides the verdict" "$OUT"

echo
echo "the trigger vocabulary grounds in the snapshot (spec rule 4):"
python3 "$GP" disable walk-high >/dev/null
python3 "$GP" learn walk-near --priority 20 --cooldown-ms 0 \
    --trigger 'near_tile={"x":122,"z":648,"radius":3}' --trigger inventory_has=376 \
    --action walk --param x=126 --param z=648 >/dev/null
snap 115
fake_bridge done
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "near_tile + inventory_has both hold: fired" "$CODE" "0"
snap 116 '[]' '{"x":300}'
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
check_eq "out of radius: no fire" "$CODE" "4"
python3 "$GP" set walk-near trigger.inventory_lacks 349 >/dev/null
python3 "$GP" set walk-near trigger.inventory_has null >/dev/null
snap 117
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
check_eq "inventory_lacks refuses while the item is held" "$CODE" "4"
python3 "$GP" remove walk-near >/dev/null

echo
echo "doors and scenery: interact-object / interact-bound (spec rules 4-5):"
refute "interact-object without its obj id is refused" \
    python3 "$GP" learn bad5 --priority 1 --trigger object_visible=493 --action interact-object
refute "a cmd outside 1-2 is refused" \
    python3 "$GP" learn bad6 --priority 1 --trigger object_visible=493 \
        --action interact-object --param obj=493 --param cmd=3
refute "a non-integer bound_visible is refused" \
    python3 "$GP" learn bad7 --priority 1 --trigger bound_visible=door \
        --action interact-bound --param obj=1
python3 "$GP" objective seek-fred >/dev/null
python3 "$GP" learn open-farm-door --priority 70 --cooldown-ms 0 --once-per-objective \
    --trigger objective_is=seek-fred --trigger bound_visible=1 \
    --action interact-bound --param obj=1 >/dev/null
python3 "$GP" learn net-fishing-spot --priority 60 --cooldown-ms 0 \
    --trigger objective_is=seek-fred --trigger object_visible=493 \
    --action interact-object --param obj=493 --param cmd=2 >/dev/null
# Two doors of the wanted id, nearest first: the emitted tile must be the near one.
snap 130 '[]' '{"bounds":[{"id":1,"x":159,"z":617,"dir":0},{"id":1,"x":170,"z":640,"dir":2}],"objects":[{"id":493,"x":196,"z":726,"dir":6}]}'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the door rule wins the slot and a done receipt exits 0" "$CODE" "0"
contains "$OUT" "fired rule=open-farm-door" && ok "the verdict names the door rule" \
    || fail "the verdict names the door rule" "$OUT"
check_eq "the action is interact-bound" "$(last_action 'type=interact-bound')" "1"
check_eq "aimed at the NEAREST matching door tile" "$(last_action 'x=159')" "1"
check_eq "with the wall direction riding the file" "$(last_action 'dir=0')" "1"
check_eq "the type id rides as obj, never id" "$(last_action 'obj=1')" "1"
check_eq "and the default command is 1" "$(last_action 'cmd=1')" "1"
# The door rule is spent (once per objective): the fishing spot gets the next step.
snap 131 '[]' '{"objects":[{"id":493,"x":196,"z":726,"dir":6}],"bounds":[]}'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
contains "$OUT" "fired rule=net-fishing-spot" && ok "the fishing rule fires when the spot is loaded" \
    || fail "the fishing rule fires when the spot is loaded" "$OUT"
check_eq "as an interact-object" "$(last_action 'type=interact-object')" "1"
check_eq "on the spot's tile" "$(last_action 'x=196')" "1"
check_eq "with its chosen verb riding (cmd 2, the second menu command)" "$(last_action 'cmd=2')" "1"
python3 "$GP" learn open-gate --priority 40 --cooldown-ms 0 \
    --trigger objective_is=seek-fred --action interact-object --param obj=60 >/dev/null
snap 132 '[]' '{"objects":[],"bounds":[]}'
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
check_eq "a rule whose object is not loaded refuses at compile: exit 4" "$CODE" "4"
check_eq "and the refusal is logged" "$(decided refused)" "2"
python3 "$GP" remove open-farm-door >/dev/null
python3 "$GP" remove net-fishing-spot >/dev/null
python3 "$GP" remove open-gate >/dev/null
python3 "$GP" objective --clear >/dev/null

echo
echo "the real playing entrypoint invokes this layer (spec rule 12):"
# The game tree is borrowed READ-ONLY, recovered the same way the bridge
# suite borrows it: the sandbox moved HOME, the live-data path remembers.
REAL_HOME="$(cd "$SANDBOX_LIVE_DATA/../../.." 2>/dev/null && pwd)"
GAME_TREE="${DESKCRAB_OPENRSC_TREE:-$REAL_HOME/Games/OpenRSC}"
HEADLESS="$GAME_TREE/headless/orsc-headless.sh"
if [ ! -f "$HEADLESS" ]; then
    sandbox_skip "no local OpenRSC headless harness at $HEADLESS"
fi
check_eq "the harness carries a play door" \
    "$(sandbox_count_in '^    play' "$HEADLESS")" "1"
check_eq "wired to game_player.py, not merely present in lib" \
    "$(grep -c 'game_player.py' "$HEADLESS")" "1"
check_eq "and the policy step is rules-first: play refuses reasoning until exit 4" \
    "$(grep -c 'no-rule-matched' "$HEADLESS")" "1"
python3 "$GP" enable walk-high >/dev/null
snap 118
fake_bridge done
OUT="$(DESKCRAB_GAME_PLAYER="$GP" bash "$HEADLESS" play)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "orsc-headless.sh play fires the learned rule end to end" "$CODE" "0"
contains "$OUT" "fired rule=walk-high" && ok "through the real entrypoint" \
    || fail "through the real entrypoint" "$OUT"
python3 "$GP" disable walk-high >/dev/null
snap 119
CODE=0; OUT="$(DESKCRAB_GAME_PLAYER="$GP" bash "$HEADLESS" play)" || CODE=$?
check_eq "with no rule applicable the entrypoint hands back exit 4 — only then may a model reason" "$CODE" "4"
contains "$(DESKCRAB_GAME_PLAYER="$GP" bash "$HEADLESS" play rules)" "walk-high" \
    && ok "play passes subcommands through (rules)" \
    || fail "play passes subcommands through (rules)"
refute "and still: no model CLI was invoked anywhere in the suite" \
    test -f "$SANDBOX/model-called"
