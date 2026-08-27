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
        if status == "done" and fields.get("type") in ("chat-local", "chat-private"):
            state_path = os.path.join(sd, "state.json")
            state = json.load(open(state_path))
            messages = state.setdefault("messages", [])
            next_id = max([m.get("id", 0) for m in messages if isinstance(m, dict)] + [0]) + 1
            messages.append({"id": next_id,
                "channel": "private" if fields["type"] == "chat-private" else "local",
                "incoming": False,
                "sender": fields.get("target", "Player"), "text": fields["text"]})
            state["ts"] = int(time.time() * 1000)
            json.dump(state, open(state_path, "w"))
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
check_eq "a receipted walk that never moved the body is exit 2 (rule 7a)" "$CODE" "2"
contains "$OUT" "status=walk-short" && ok "and named walk-short, not done" \
    || fail "and named walk-short, not done" "$OUT"
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
    --action walk --param x=121 --param z=649 >/dev/null
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
refute "click-entity refuses an unknown entity kind" \
    python3 "$GP" learn bad8 --priority 1 --trigger npc_visible=2 \
        --action click-entity --param kind=widget --param entity=2
refute "click-entity refuses a mouse button outside 1-3" \
    python3 "$GP" learn bad9 --priority 1 --trigger npc_visible=2 \
        --action click-entity --param kind=npc --param entity=2 --param button=4
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
echo "identity-based pointer actions compile without pixel coordinates (spec rule 5):"
python3 "$GP" objective shear-sheep >/dev/null
python3 "$GP" learn click-sheep --priority 80 --cooldown-ms 0 --once-per-objective \
    --trigger objective_is=shear-sheep --trigger npc_visible=2 \
    --action click-entity --param kind=npc --param entity=2 --param button=1 >/dev/null
snap 133 '[{"sidx":27,"id":2,"x":121,"z":648},{"sidx":39,"id":2,"x":130,"z":655}]'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the learned entity click receives a done receipt" "$CODE" "0"
contains "$OUT" "fired rule=click-sheep" && ok "the entity rule owned the play" \
    || fail "the entity rule owned the play" "$OUT"
check_eq "the action is click-entity" "$(last_action 'type=click-entity')" "1"
check_eq "its kind is NPC" "$(last_action 'kind=npc')" "1"
check_eq "it uses the nearest matching server index" "$(last_action 'sidx=27')" "1"
check_eq "it double-checks the NPC type" "$(last_action 'npc=2')" "1"
check_eq "the pointer button rides the action" "$(last_action 'button=1')" "1"
refute "no stale screen x coordinate enters the action" grep -q '^x=' "$DESKCRAB_GAME_STATE_DIR/last-action"
refute "no stale screen y coordinate enters the action" grep -q '^y=' "$DESKCRAB_GAME_STATE_DIR/last-action"
python3 "$GP" remove click-sheep >/dev/null
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
check_eq "the harness carries the identity-based entity door" \
    "$(sandbox_count_in '^    entity)' "$HEADLESS")" "1"
check_eq "the harness carries a play door" \
    "$(sandbox_count_in '^    play' "$HEADLESS")" "1"
check_eq "wired to game_player.py, not merely present in lib" \
    "$(grep -c 'game_player.py' "$HEADLESS")" "1"
check_eq "and the policy step is rules-first: play refuses reasoning until exit 4" \
    "$(grep -c 'no-rule-matched' "$HEADLESS")" "1"
snap 1170 '[]' '{"messages":[
    {"id":9010,"channel":"local","incoming":true,"sender":"Nearby Player","text":"Try the east door"}
]}'
python3 "$GP" step --local >/dev/null 2>&1 || true
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
CODE=0; OUT="$(BETTY_OPENRSC_AUTONOMOUS=1 bash "$HEADLESS" walk 130 650 2>&1)" || CODE=$?
check_eq "an unanswered player message blocks autonomous movement: exit 6" "$CODE" "6"
contains "$OUT" "reply before any further play" \
    && ok "the refusal points Sol to the shared reply ACTION" \
    || fail "the refusal points Sol to the shared reply ACTION" "$OUT"
refute "the blocked movement emitted no game action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
rm -f "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json"
snap 1171 '[{"sidx":55,"id":2,"x":121,"z":648},{"sidx":66,"id":2,"x":130,"z":655}]'
fake_bridge done
OUT="$(bash "$HEADLESS" entity npc 2 3)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the entity door completes through the shared ACTIONS receipt" "$CODE" "0"
contains "$OUT" "entity(npc type=2 button=3)" \
    && ok "and reports the identity it targeted" \
    || fail "and reports the identity it targeted" "$OUT"
check_eq "the door wrote click-entity" "$(last_action 'type=click-entity')" "1"
check_eq "the door selected the nearest stable server index" "$(last_action 'sidx=55')" "1"
refute "the entity door did not write a screen x coordinate" \
    grep -q '^x=' "$DESKCRAB_GAME_STATE_DIR/last-action"
refute "the entity door did not write a screen y coordinate" \
    grep -q '^y=' "$DESKCRAB_GAME_STATE_DIR/last-action"
python3 "$GP" enable walk-high >/dev/null
python3 "$GP" set walk-high action.x 120 >/dev/null
python3 "$GP" set walk-high action.z 649 >/dev/null
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

echo
echo "the entrypoint is versioned bytes, deployed, and durable (spec rule 13):"
# A setsid child still dies with the launching service's cgroup. The door must
# be committed bytes deployed by symlink, and every long-lived process must
# start as its own transient systemd user unit.
CF="$GAME_TREE/Core-Framework"
RESOLVED="$(readlink -f "$HEADLESS")"
case "$RESOLVED" in
    "$CF"/*) ok "the deployed play door resolves into the game repo" ;;
    *)       fail "the deployed play door resolves into the game repo" "$RESOLVED" ;;
esac
git -C "$CF" ls-files --error-unmatch headless/orsc-headless.sh >/dev/null 2>&1 \
    && ok "and is committed there, not untracked" \
    || fail "and is committed there, not untracked"
check_eq "deployed bytes are the committed bytes (clean git status on the harness)" \
    "$(git -C "$CF" status --porcelain -- headless/orsc-headless.sh 2>/dev/null | grep -c '')" "0"
check_eq "the helpers it invokes are versioned beside it" \
    "$(git -C "$CF" ls-files headless/ 2>/dev/null | grep -cE 'orsc-view\.py|find-blob\.py')" "2"
check_eq "xvfb, client, engine, runner and viewer all start through one durable detach door" \
    "$(grep -cE '\$\(detach (xvfb|client|engine|runner|viewer) ' "$HEADLESS")" "5"
check_eq "which is a transient systemd --user unit, not a child of the caller" \
    "$(grep -c 'systemd-run --user' "$HEADLESS")" "1"
check_eq "bare setsid survives only as the explicit no-user-manager fallback" \
    "$(grep -c 'setsid nohup' "$HEADLESS")" "1"

# Functional: drive the real engine door with the systemd doors shimmed at
# the head of PATH, and watch the engine start as the orsc-engine unit.
SDFAKE="$SANDBOX/sdfake"
mkdir -p "$SDFAKE" "$SANDBOX/orschome"
cat > "$SDFAKE/systemd-run" <<'SH'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$@" >> "$dir/systemd-run-args"
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        -p)  i=$((i+2)) ;;
        --*) i=$((i+1)) ;;
        *)   break ;;
    esac
done
setsid "${args[@]:$i}" >/dev/null 2>&1 &
echo $! > "$dir/systemd-run-pid"
SH
cat > "$SDFAKE/systemctl" <<'SH'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
case "$*" in
    *MainPID*) cat "$dir/systemd-run-pid" 2>/dev/null || echo 0 ;;
    *stop*)    echo "$*" >> "$dir/systemctl-stops" ;;
esac
exit 0
SH
cat > "$SDFAKE/betty-game" <<'SH'
#!/bin/bash
case "${1:-}" in
    run)   exec sleep 60 ;;
    rules) printf '[on ] fake-eat\n[on ] fake-flee\n' ;;
esac
SH
chmod +x "$SDFAKE/systemd-run" "$SDFAKE/systemctl" "$SDFAKE/betty-game"
ENGENV=(PATH="$SDFAKE:$PATH" ORSC_HEADLESS_HOME="$SANDBOX/orschome" DESKCRAB_BETTY_GAME="$SDFAKE/betty-game")
CODE=0; OUT="$(env "${ENGENV[@]}" bash "$HEADLESS" engine start 2>&1)" || CODE=$?
check_eq "engine start through the shimmed doors answers cleanly" "$CODE" "0"
contains "$OUT" "engine running" && ok "and says so" || fail "and says so" "$OUT"
EPID="$(cat "$SANDBOX/orschome/run/engine.pid" 2>/dev/null)"
[ -n "$EPID" ] && kill -0 "$EPID" 2>/dev/null \
    && ok "the engine process is alive and its pid recorded" \
    || fail "the engine process is alive and its pid recorded" "pid [$EPID]"
grep -q -- '--user' "$SDFAKE/systemd-run-args" 2>/dev/null \
    && grep -q -- '--unit=orsc-engine.service' "$SDFAKE/systemd-run-args" 2>/dev/null \
    && ok "and it was started as the transient orsc-engine user unit" \
    || fail "and it was started as the transient orsc-engine user unit" \
            "$(cat "$SDFAKE/systemd-run-args" 2>/dev/null)"
contains "$(env "${ENGENV[@]}" bash "$HEADLESS" engine status 2>&1)" "alive" \
    && ok "engine status sees it" || fail "engine status sees it"
CODE=0; OUT="$(env "${ENGENV[@]}" bash "$HEADLESS" engine stop 2>&1)" || CODE=$?
check_eq "engine stop tears it down" "$CODE" "0"
refute "and the engine process is gone" sh -c "kill -0 $EPID 2>/dev/null"

echo
echo "the ordinary player command (spec rule 14):"
# The ordinary command must be committed bytes, installed on PATH, pinned to
# the real model, supervised (Restart=always), and every start must recompose
# its first prompt from ground truth as it is now, then resume the same Sol
# thread across routine process boundaries.
BOC="$GAME_TREE/headless/betty-openrsc"
check "the command is deployed beside the harness" test -f "$BOC"
BOCR="$(readlink -f "$BOC")"
case "$BOCR" in
    "$CF"/*) ok "and resolves into the game repo" ;;
    *)       fail "and resolves into the game repo" "$BOCR" ;;
esac
git -C "$CF" ls-files --error-unmatch headless/betty-openrsc >/dev/null 2>&1 \
    && ok "and is committed there, not untracked" \
    || fail "and is committed there, not untracked"
check_eq "deployed bytes are the committed bytes (clean git status)" \
    "$(git -C "$CF" status --porcelain -- headless/betty-openrsc 2>/dev/null | grep -c '')" "0"
PATHDOOR="$REAL_HOME/.local/bin/betty-openrsc"
check "the command is installed on PATH (.local/bin)" test -x "$PATHDOOR"
check_eq "and the installed door is the same committed bytes" \
    "$(readlink -f "$PATHDOOR" 2>/dev/null)" "$BOCR"
check "the player model is pinned to a real GPT Sol" grep -q 'gpt-5.6-sol' "$BOC"
check "the player reasoning effort is pinned low" grep -q 'model_reasoning_effort=.*EFFORT' "$BOC"
check "the background author is pinned to GPT Sol" \
    grep -q 'AUTHOR_MODEL:-gpt-5.6-sol' "$BOC"
check "the author runs Sol through Codex" \
    grep -q '"$CODEX" exec --json.*--ephemeral' "$BOC"
check "the Sol author carries the same no-sleep command guard" \
    grep -A4 '"$CODEX" exec --json.*--ephemeral' "$BOC" | \
        grep -q -- '--profile.*CODEX_PROFILE.*--dangerously-bypass-hook-trust'
check "the author streams its prompt on stdin instead of risking ARG_MAX" \
    grep -q -- '-C "$OHOME" - < "$prompt"' "$BOC"
check "the author is event-driven by the outcome queue, with no sleep loop" \
    grep -q 'path-property=.*PathModified' "$BOC"
check "the author is forbidden from touching the game action slot" \
    grep -q 'NEVER play the game, touch action.json' "$BOC"
contains "$(sed -n '/cmd_run_player.*what systemd execs/,/compose_prompt/p' "$BOC")" 'stack_up' \
    && ok "every replacement player repairs the stack before Sol starts" \
    || fail "every replacement player repairs the stack before Sol starts"
check "dead-stack recovery clears abandoned ACTIONS state" \
    grep -q 'rm -f.*action.json' "$BOC"
SLEEP_HOOK="$CF/headless/no-sleep-hook.py"
SLEEP_PROFILE="$CF/headless/openrsc-player.config.toml"
check "the no-sleep command guard is committed beside the player" test -f "$SLEEP_HOOK"
check "the player uses the isolated no-sleep Codex profile" \
    grep -q -- '--profile.*CODEX_PROFILE.*--dangerously-bypass-hook-trust' "$BOC"
check "play installs the isolated profile before starting Sol" \
    grep -q 'ensure_player_policy' "$BOC"
check_eq "the installed no-sleep profile resolves to committed bytes" \
    "$(readlink -f "$REAL_HOME/.codex/openrsc-player.config.toml" 2>/dev/null)" \
    "$(readlink -f "$SLEEP_PROFILE")"
BLOCKED_SLEEP="$(printf '%s\n' '{"tool_input":{"command":"for n in 1 2; do sleep 1; done"}}' \
    | python3 "$SLEEP_HOOK")"
contains "$BLOCKED_SLEEP" '"permissionDecision":"deny"' \
    && ok "the hook denies a nested shell sleep before execution" \
    || fail "the hook denies a nested shell sleep before execution" "$BLOCKED_SLEEP"
ALLOWED_STATE="$(printf '%s\n' '{"tool_input":{"command":"./orsc-headless.sh play"}}' \
    | python3 "$SLEEP_HOOK")"
check_eq "the hook leaves ACTIONS state commands untouched" "$ALLOWED_STATE" ""
check "the player unit carries Restart=always" grep -q 'Restart=always' "$BOC"
check "routine player process boundaries resume the saved Codex thread" \
    grep -q '"$CODEX" --profile.*CODEX_PROFILE.*exec resume' "$BOC"
check "the autonomous player exports the pending-message action gate" \
    grep -q 'export BETTY_OPENRSC_AUTONOMOUS=1' "$BOC"
check "resumed play keeps the no-sleep command guard" \
    grep -A4 '"$CODEX" --profile.*CODEX_PROFILE.*exec resume' "$BOC" | \
        grep -q -- '--dangerously-bypass-hook-trust'
check "the restart delay is one second, not five seconds of dead time" \
    grep -q 'RestartSec=1' "$BOC"
check "and restarts are never rate-limited away" grep -q 'StartLimitIntervalSec=0' "$BOC"
check "as its own transient user unit" grep -q 'orsc-player.service' "$BOC"
check "the live display is read from the harness run state" grep -q 'run/display' "$BOC"
refute "and never hard-coded (no :97 anywhere in the door)" grep -q ':97' "$BOC"
refute "nothing of the player lives under /tmp" \
    grep -qE '/tmp/[a-z.-]*(player|prompt|handoff)' "$BOC"
check "login reads the stored credentials file, not an inline secret" \
    grep -q 'credentials' "$BOC"
check_eq "play walks the whole stack in order: client, login, engine, runner, author, player" \
    "$(sed -n '/^cmd_play()/,/^}/p' "$BOC" | grep -c 'stack_up\|ensure_login\|engine_up\|runner_up\|author_up\|player_start')" "6"

if [ -f "$BOC" ]; then
# Functional: composition. A fake player home and harness run dir; the
# prompt door must discover the display, objective, snapshot and CURRENT
# handoff at the moment it is asked.
PH="$SANDBOX/phome"; OH2="$SANDBOX/ohome2"
mkdir -p "$PH" "$OH2/run"
echo 55 > "$OH2/run/display"
printf 'BASE-PROMPT-MARKER\n' > "$PH/prompt.md"
printf 'goal: fetch flour; step 7 of 9; next: walk to the mill\n' > "$PH/handoff.md"
printf 'cooks-two\n' > "$DESKCRAB_GAME_DIR/objective"
snap 140 '[{"sidx":9,"id":11,"x":121,"z":649}]'
BOCENV=(BETTY_OPENRSC_HOME="$PH" BETTY_OPENRSC_HEADLESS="$OH2" \
        DESKCRAB_GAME_STATE_DIR="$DESKCRAB_GAME_STATE_DIR" \
        DESKCRAB_GAME_DIR="$DESKCRAB_GAME_DIR")
OUT="$(env "${BOCENV[@]}" bash "$BOC" prompt 2>&1)"
contains "$OUT" "BASE-PROMPT-MARKER" && ok "prompt opens with the durable base prompt" \
    || fail "prompt opens with the durable base prompt" "$OUT"
contains "$OUT" ":55" && ok "the display is discovered from run/display, not remembered" \
    || fail "the display is discovered from run/display, not remembered" "$OUT"
contains "$OUT" "cooks-two" && ok "the durable objective rides the composition" \
    || fail "the durable objective rides the composition" "$OUT"
contains "$OUT" "step 7 of 9" && ok "so does the handoff's exact state" \
    || fail "so does the handoff's exact state" "$OUT"
contains "$OUT" "pos=(120,648)" && ok "and a fresh snapshot summary" \
    || fail "and a fresh snapshot summary" "$OUT"

# Functional: the unit contract and same-thread continuation, through the
# same shimmed systemd doors as the engine test above. The fake codex
# records the exact invocation and emits a stable thread id. Driving
# run-player again is the routine process-boundary path: it must resume that
# conversation with current state instead of recomposing the standing prompt.
PSD="$SANDBOX/psdfake"; mkdir -p "$PSD"
cp "$SDFAKE/systemd-run" "$SDFAKE/systemctl" "$PSD/"
cat > "$PSD/fakecodex" <<'SH'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$@" >> "$dir/codex-capture"
printf -- '----8<----\n' >> "$dir/codex-capture"
printf '%s\n' '{"type":"thread.started","thread_id":"11111111-2222-3333-4444-555555555555"}'
exit 0
SH
chmod +x "$PSD/fakecodex"
POCENV=(PATH="$PSD:$PATH" "${BOCENV[@]}" BETTY_OPENRSC_CODEX="$PSD/fakecodex" \
        BETTY_OPENRSC_CODEX_STREAM="$REPO/lib/codex-stream" \
        BETTY_OPENRSC_TEST_SKIP_RECOVERY=1)
CODE=0; OUT="$(env "${POCENV[@]}" bash "$BOC" player-start 2>&1)" || CODE=$?
check_eq "player-start through the shimmed doors answers cleanly" "$CODE" "0"
grep -q -- '--user' "$PSD/systemd-run-args" 2>/dev/null \
    && grep -q -- '--unit=orsc-player.service' "$PSD/systemd-run-args" 2>/dev/null \
    && ok "the player was started as the transient orsc-player user unit" \
    || fail "the player was started as the transient orsc-player user unit" \
            "$(cat "$PSD/systemd-run-args" 2>/dev/null)"
grep -q 'Restart=always' "$PSD/systemd-run-args" 2>/dev/null \
    && ok "with Restart=always riding the unit" \
    || fail "with Restart=always riding the unit"
grep -q 'StartLimitIntervalSec=0' "$PSD/systemd-run-args" 2>/dev/null \
    && ok "and the start limit disarmed" || fail "and the start limit disarmed"
for i in $(seq 1 50); do [ -s "$PH/player-thread" ] && break; sleep 0.1; done
contains "$(cat "$PSD/codex-capture" 2>/dev/null)" "step 7 of 9" \
    && ok "the first player received the composed prompt, handoff included" \
    || fail "the first player received the composed prompt, handoff included"
contains "$(cat "$PSD/codex-capture" 2>/dev/null)" "gpt-5.6-sol" \
    && ok "and was invoked pinned to GPT Sol" \
    || fail "and was invoked pinned to GPT Sol"
contains "$(cat "$PSD/codex-capture" 2>/dev/null)" "model_reasoning_effort=low" \
    && ok "at the pinned low reasoning effort" \
    || fail "at the pinned low reasoning effort"
printf 'goal: NEW-GOAL; step 8 of 9; next: buy the pot\n' > "$PH/handoff.md"
printf 'resume-target\n' > "$DESKCRAB_GAME_DIR/objective"
env "${POCENV[@]}" bash "$BOC" run-player </dev/null >/dev/null 2>&1 || true
check_eq "the first run captured its durable Codex thread id" \
    "$(cat "$PH/player-thread" 2>/dev/null)" "11111111-2222-3333-4444-555555555555"
check_eq "the restarted process used Codex resume exactly once" \
    "$(grep -c '^resume$' "$PSD/codex-capture" 2>/dev/null)" "1"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "resume-target" \
    && ok "the resumed thread receives current objective and snapshot facts" \
    || fail "the resumed thread receives current objective and snapshot facts"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "entity KIND TYPE-ID" \
    && ok "the resumed thread receives the identity-targeting ability" \
    || fail "the resumed thread receives the identity-targeting ability"
refute "the resumed thread is not handed the full standing prompt again" \
    grep -q 'BASE-PROMPT-MARKER' "$PH/run-prompt.txt"
refute "nor is the emergency handoff re-read for a routine process boundary" \
    grep -q 'NEW-GOAL' "$PH/run-prompt.txt"
check_eq "both player runs were captured" \
    "$(grep -c -- '----8<----' "$PSD/codex-capture" 2>/dev/null)" "2"
check "every start leaves the exact composed prompt on file" \
    test -s "$PH/run-prompt.txt"
check_eq "and stamps the durable player log" \
    "$(grep -c 'player start' "$PH/player.log" 2>/dev/null)" "2"
env "${POCENV[@]}" bash "$BOC" stop player >/dev/null 2>&1 || true
grep -q 'stop orsc-player.service' "$PSD/systemctl-stops" 2>/dev/null \
    && ok "stop player goes through the unit door" \
    || fail "stop player goes through the unit door" \
            "$(cat "$PSD/systemctl-stops" 2>/dev/null)"
fi

echo
echo "incoming local and private messages interrupt play and reply through its action slot (rule 7b):"
snap 145 '[]' '{"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east door"},
    {"id":9002,"channel":"private","incoming":true,"sender":"Far Friend","text":"I can help from here"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the oldest incoming player message is the priority verdict: exit 6" "$CODE" "6"
contains "$OUT" "channel=local sender=Nearby Friend text=Try the east door" \
    && ok "the verdict retains the local channel, sender, and text" \
    || fail "the verdict retains the local channel, sender, and text" "$OUT"
refute "observing a message emits no action before Sol writes the reply" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the pending message survives a repeated snapshot and remains urgent" "$CODE" "6"
fake_bridge done
OUT="$(python3 "$GP" reply 9001 Thanks, I will try that)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a receipted local reply exits 0" "$CODE" "0"
check_eq "the reply used the shared chat-local action" "$(last_action 'type=chat-local')" "1"
check_eq "and preserved Sol's text" "$(last_action 'text=Thanks, I will try that')" "1"
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the private message is next, still before ordinary rules" "$CODE" "6"
contains "$OUT" "channel=private sender=Far Friend" \
    && ok "the private sender and channel remain structured" \
    || fail "the private sender and channel remain structured" "$OUT"
fake_bridge done
OUT="$(python3 "$GP" reply 9002 I got your private message)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a receipted private reply exits 0" "$CODE" "0"
check_eq "the reply used chat-private" "$(last_action 'type=chat-private')" "1"
check_eq "and addressed the original sender at any distance" "$(last_action 'target=Far Friend')" "1"
snap 146 '[]' '{"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east door"},
    {"id":9002,"channel":"private","incoming":true,"sender":"Far Friend","text":"I can help from here"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "handled ids are not re-added from later snapshots" "$CODE" "4"
grep -q '"kind":"player-message-received"' "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl" \
    && grep -q '"kind":"player-message-reply"' "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl" \
    && ok "observation and replies stay in the existing player decision log" \
    || fail "observation and replies stay in the existing player decision log"

echo
echo "a walk verifies against the TARGET, never the receipt (spec rule 7a):"
WS0="$(decided walk-short)"
python3 "$GP" learn walk-verify --priority 97 --cooldown-ms 0 \
    --trigger message_contains=welcome --action walk --param x=500 --param z=500 >/dev/null
snap 150
fake_bridge done
OUT="$(python3 "$GP" step --local)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a done receipt that never arrived is exit 2" "$CODE" "2"
contains "$OUT" "status=walk-short" && ok "and named walk-short, with the settled tile" \
    || fail "and named walk-short, with the settled tile" "$OUT"
check_eq "the shortfall is one decision-log event" "$((  $(decided walk-short) - WS0 ))" "1"
grep -q '"intended":{"x":500,"z":500}' "$DESKCRAB_GAME_DIR/outcome-queue.jsonl" 2>/dev/null \
    && ok "the outcome queue carries intended versus settled for the author" \
    || fail "the outcome queue carries intended versus settled for the author"
python3 "$GP" set walk-verify action.x 121 >/dev/null
python3 "$GP" set walk-verify action.z 649 >/dev/null
snap 151
fake_bridge done
OUT="$(python3 "$GP" step --local)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a walk that settles within the arrive tolerance is done: exit 0" "$CODE" "0"
contains "$OUT" "status=done" && ok "and says done" || fail "and says done" "$OUT"

echo
echo "a once-per-objective mark is spent only on a VERIFIED done (spec rule 7a):"
python3 "$GP" objective verify-marks >/dev/null
python3 "$GP" set walk-verify once_per_objective true >/dev/null
python3 "$GP" set walk-verify action.x 500 >/dev/null
python3 "$GP" set walk-verify action.z 500 >/dev/null
snap 152
fake_bridge done
CODE=0; python3 "$GP" step --local >/dev/null || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the walk fell short: exit 2" "$CODE" "2"
snap 153
fake_bridge done
OUT="$(python3 "$GP" step --local)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
contains "$OUT" "fired rule=walk-verify" \
    && ok "the unarrived rule is still live for the objective — no spent mark" \
    || fail "the unarrived rule is still live for the objective — no spent mark" "$OUT"
python3 "$GP" set walk-verify action.x 121 >/dev/null
python3 "$GP" set walk-verify action.z 649 >/dev/null
snap 154
fake_bridge done
CODE=0; python3 "$GP" step --local >/dev/null || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "then it arrives: exit 0" "$CODE" "0"
snap 155
CODE=0; python3 "$GP" step --local >/dev/null || CODE=$?
check_eq "and only the verified done spent the mark: no refire" "$CODE" "4"
python3 "$GP" remove walk-verify >/dev/null
python3 "$GP" objective --clear >/dev/null

echo
echo "the near_tile radius floor (spec rules 4 and 17):"
refute "authoring an exact-tile radius is refused by the lint gate" \
    python3 "$GP" learn walk-pin --priority 5 --cooldown-ms 0 \
        --trigger 'near_tile={"x":120,"z":648,"radius":1}' \
        --action walk --param x=121 --param z=648
python3 - "$DESKCRAB_GAME_DIR/learned-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["rules"].append({"name": "walk-legacy-pin", "enabled": True, "priority": 5,
    "cooldown_ms": 0, "hold_ticks": 1,
    "trigger": {"near_tile": {"x": 122, "z": 648, "radius": 0}},
    "action": {"type": "walk", "x": 121, "z": 649}})
json.dump(cfg, open(sys.argv[1], "w"))
PY
snap 156
fake_bridge done
OUT="$(python3 "$GP" step --local)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
contains "$OUT" "fired rule=walk-legacy-pin" \
    && ok "a legacy exact-tile rule still fires from two tiles away: the floor holds" \
    || fail "a legacy exact-tile rule still fires from two tiles away: the floor holds" "$OUT"
python3 "$GP" remove walk-legacy-pin >/dev/null

echo
echo "the resident runner, step's deferral, the queue and the note door (spec rules 15-16):"
snap 160
python3 "$GP" run --poll-ms 100 > "$SANDBOX/runner-out" 2>&1 &
RUNNER_PID=$!
for i in $(seq 1 50); do
    [ -f "$DESKCRAB_GAME_STATE_DIR/player-runner.json" ] && break; sleep 0.1
done
check "the runner writes its heartbeat" \
    test -f "$DESKCRAB_GAME_STATE_DIR/player-runner.json"
sleep 0.9
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
contains "$OUT" "runner-" && ok "step defers to the live runner instead of evaluating" \
    || fail "step defers to the live runner instead of evaluating" "$OUT"
check_eq "and hands back the runner's own fallback licence: exit 4" "$CODE" "4"
grep -q '"kind":"gap"' "$DESKCRAB_GAME_DIR/outcome-queue.jsonl" 2>/dev/null \
    && ok "the runner queued the gap for the background author" \
    || fail "the runner queued the gap for the background author"
check_eq "an unchanged game gap queues once, not on a timer" \
    "$(grep -c '"kind":"gap"' "$DESKCRAB_GAME_DIR/outcome-queue.jsonl")" "1"
check "gap deduplication waits for stable actionable state instead of waking Sol per tile" \
    grep -q 'GAP_STABLE_MS = 750' "$GP"
check "and preserves the candidate across same-tick polls while it settles" \
    grep -q 'gap_candidate_signature is not None' "$GP"
kill "$RUNNER_PID" 2>/dev/null; wait "$RUNNER_PID" 2>/dev/null
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
case "$OUT" in
    runner-*) fail "a dead runner defers nothing: step evaluates locally again" "$OUT" ;;
    *)        ok   "a dead runner defers nothing: step evaluates locally again" ;;
esac
OUT="$(python3 "$GP" note "the mill door sticks; approach from the south")"
contains "$OUT" "noted" && ok "the note door answers" || fail "the note door answers" "$OUT"
grep -q '"kind":"lesson"' "$DESKCRAB_GAME_DIR/outcome-queue.jsonl" 2>/dev/null \
    && ok "and the lesson landed in the queue, stamped with live context" \
    || fail "and the lesson landed in the queue, stamped with live context"

echo
echo "the test gate catches a broken rule before it is armed (spec rule 17):"
python3 "$GP" learn walk-keeper --priority 30 --cooldown-ms 0 \
    --trigger 'near_tile={"x":140,"z":640,"radius":4}' \
    --action walk --param x=141 --param z=641 >/dev/null
python3 - > "$SANDBOX/case-snap.json" <<'PY'
import json, time
print(json.dumps({"v": 1, "ts": int(time.time() * 1000), "tick": 170,
    "logged_in": True, "hits": 10, "hits_max": 10, "x": 141, "z": 640,
    "inventory": [], "messages": [], "npcs": []}))
PY
check "a replay case is added, pinned to the current winner" \
    python3 "$GP" test add keeper-wins --expect walk-keeper \
        --snapshot "$SANDBOX/case-snap.json"
check "the suite door reports green" python3 "$GP" test
refute "a hijacking higher-priority rule is refused before it is armed" \
    python3 "$GP" learn walk-hijack --priority 95 --cooldown-ms 0 \
        --trigger 'near_tile={"x":140,"z":640,"radius":10}' \
        --action walk --param x=1 --param z=1
contains "$(python3 "$GP" rules)" "walk-hijack" \
    && fail "the refused rule never landed in the table" \
    || ok "the refused rule never landed in the table"
python3 "$GP" test remove keeper-wins >/dev/null
python3 "$GP" remove walk-keeper >/dev/null

echo
refute "and still: no model CLI was invoked anywhere in the suite" \
    test -f "$SANDBOX/model-called"
