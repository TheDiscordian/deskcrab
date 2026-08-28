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
        "x": 120, "z": 648, "walking": False, "in_combat": False,
        "talking_to_npc": False, "opponent": None,
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
import json, os, re, sys, time
sd, status = sys.argv[1], sys.argv[2]
ap = os.path.join(sd, "action.json")
for _ in range(100):
    if os.path.exists(ap):
        body = open(ap).read()
        open(os.path.join(sd, "last-action"), "w").write(body)
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        os.remove(ap)
        delivered = status in ("done", "done-normalized")
        if delivered and fields.get("type") in ("chat-local", "chat-private"):
            state_path = os.path.join(sd, "state.json")
            state = json.load(open(state_path))
            messages = state.setdefault("messages", [])
            next_id = max([m.get("id", 0) for m in messages if isinstance(m, dict)] + [0]) + 1
            echo_text = fields["text"]
            if status == "done-normalized":
                echo_text = re.sub(r"[^A-Za-z0-9' ]+", "", echo_text).replace("PM", "Pm")
            messages.append({"id": next_id,
                "channel": "private" if fields["type"] == "chat-private" else "local",
                "incoming": False, "sender": fields.get("target", "Player"),
                "text": echo_text})
            state["ts"] = int(time.time() * 1000)
            json.dump(state, open(state_path, "w"))
        if delivered and fields.get("type") in (
                "equip-inventory", "unequip-inventory", "command-inventory"):
            state_path = os.path.join(sd, "state.json")
            state = json.load(open(state_path))
            item_id = int(fields["item"])
            if fields["type"] in ("equip-inventory", "unequip-inventory"):
                desired = fields["type"] == "equip-inventory"
                for item in state.get("inventory") or []:
                    if item.get("id") == item_id:
                        item["equipped"] = desired
                        break
                state["equipment"] = [
                    {"id": item["id"], "name": item.get("name", ""),
                     "count": item.get("count", 0)}
                    for item in state.get("inventory") or [] if item.get("equipped")]
            else:
                remaining = int(fields.get("amount", "1"))
                for item in list(state.get("inventory") or []):
                    if item.get("id") != item_id or remaining <= 0:
                        continue
                    taken = min(remaining, int(item.get("count", 0)))
                    item["count"] = int(item.get("count", 0)) - taken
                    remaining -= taken
                state["inventory"] = [item for item in state.get("inventory") or []
                                      if int(item.get("count", 0)) > 0]
            state["ts"] = int(time.time() * 1000)
            json.dump(state, open(state_path, "w"))
        tmp = os.path.join(sd, ".receipt.tmp")
        json.dump({"id": int(fields["id"]),
                   "status": "done" if delivered else status,
                   "ts": int(time.time() * 1000)}, open(tmp, "w"))
        os.replace(tmp, os.path.join(sd, "receipt.json"))
        break
    time.sleep(0.05)
PY
    FAKE_BRIDGE_PID=$!
}

# A route leg also updates the authoritative snapshot before answering. The
# destination can be the final tile or an intermediate regional settlement.
fake_route_bridge() {  # FINAL-X FINAL-Z [STATUS]
    python3 - "$DESKCRAB_GAME_STATE_DIR" "$1" "$2" "${3:-done}" <<'PY' &
import json, os, sys, time
sd, final_x, final_z, status = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
ap = os.path.join(sd, "action.json")
for _ in range(100):
    if os.path.exists(ap):
        body = open(ap).read()
        open(os.path.join(sd, "last-action"), "w").write(body)
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        os.remove(ap)
        if status == "done":
            state_path = os.path.join(sd, "state.json")
            state = json.load(open(state_path))
            state.update({"x": final_x, "z": final_z, "walking": False,
                          "tick": state.get("tick", 0) + 1,
                          "ts": int(time.time() * 1000)})
            tmp_state = os.path.join(sd, ".state.tmp")
            json.dump(state, open(tmp_state, "w"))
            os.replace(tmp_state, state_path)
        tmp = os.path.join(sd, ".receipt.tmp")
        json.dump({"id": int(fields["id"]), "status": status,
                   "ts": int(time.time() * 1000)}, open(tmp, "w"))
        os.replace(tmp, os.path.join(sd, "receipt.json"))
        break
    time.sleep(0.05)
PY
    FAKE_BRIDGE_PID=$!
}

# A retreat packet is only dispatch. The scripted server can keep combat
# locked (and publish its authoritative reason) or accept the retreat.
fake_retreat_bridge() {  # locked|done
    python3 - "$DESKCRAB_GAME_STATE_DIR" "$1" <<'PY' &
import json, os, sys, time
sd, outcome = sys.argv[1:3]
ap = os.path.join(sd, "action.json")
for _ in range(100):
    if os.path.exists(ap):
        body = open(ap).read()
        open(os.path.join(sd, "last-action"), "w").write(body)
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        os.remove(ap)
        state_path = os.path.join(sd, "state.json")
        state = json.load(open(state_path))
        state["tick"] = state.get("tick", 0) + 1
        state["ts"] = int(time.time() * 1000)
        if outcome == "done":
            state["in_combat"] = False
            state["walking"] = True
        else:
            state["in_combat"] = True
            state["walking"] = False
            state.setdefault("messages", []).append({
                "id": state["tick"] * 1000, "channel": "game", "incoming": False,
                "sender": "", "text": "You can't retreat during the first 3 rounds of combat"})
        tmp_state = os.path.join(sd, ".state.tmp")
        json.dump(state, open(tmp_state, "w"))
        os.replace(tmp_state, state_path)
        tmp = os.path.join(sd, ".receipt.tmp")
        json.dump({"id": int(fields["id"]), "status": "done",
                   "ts": int(time.time() * 1000)}, open(tmp, "w"))
        os.replace(tmp, os.path.join(sd, "receipt.json"))
        break
    time.sleep(0.05)
PY
    FAKE_BRIDGE_PID=$!
}

# A ground-take receipt is only dispatch. The collected case changes both
# sides of the grounded transfer; missed removes the pile without inventory
# gain, modelling despawn or another player taking it.
fake_take_bridge() {  # collected|missed
    python3 - "$DESKCRAB_GAME_STATE_DIR" "$1" <<'PY' &
import json, os, sys, time
sd, outcome = sys.argv[1:3]
ap = os.path.join(sd, "action.json")
for _ in range(100):
    if os.path.exists(ap):
        body = open(ap).read()
        open(os.path.join(sd, "last-action"), "w").write(body)
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        os.remove(ap)
        state_path = os.path.join(sd, "state.json")
        state = json.load(open(state_path))
        item_id, x, z = int(fields["item"]), int(fields["x"]), int(fields["z"])
        removed = False
        remaining = []
        for item in state.get("ground_items") or []:
            if not removed and item.get("id") == item_id \
                    and item.get("x") == x and item.get("z") == z:
                removed = True
            else:
                remaining.append(item)
        state["ground_items"] = remaining
        if outcome == "collected":
            stack = next((item for item in state.get("inventory") or []
                          if item.get("id") == item_id), None)
            if stack is None:
                state.setdefault("inventory", []).append({"id": item_id, "count": 1})
            else:
                stack["count"] = stack.get("count", stack.get("amount", 1)) + 1
        state.update({"x": x, "z": z, "walking": False,
                      "tick": state.get("tick", 0) + 1,
                      "ts": int(time.time() * 1000)})
        tmp_state = os.path.join(sd, ".state.tmp")
        json.dump(state, open(tmp_state, "w"))
        os.replace(tmp_state, state_path)
        tmp = os.path.join(sd, ".receipt.tmp")
        json.dump({"id": int(fields["id"]), "status": "done",
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
refute "interact-npc refuses a command outside the NPC definition verbs" \
    python3 "$GP" learn bad-npc-command --priority 1 --trigger npc_visible=11 \
        --action interact-npc --param npc=11 --param cmd=3
refute "interact-npc refuses a roaming cap beyond ten tiles" \
    python3 "$GP" learn bad-npc-range --priority 1 --trigger npc_visible=11 \
        --action interact-npc --param npc=11 --param within=11
refute "out_of_combat is a literal condition, not an arbitrary value" \
    python3 "$GP" learn bad-combat-trigger --priority 1 --trigger out_of_combat=false \
        --action walk --param x=1 --param z=1
refute "inventory capacity thresholds stop at the real 30-slot ceiling" \
    python3 "$GP" learn bad-inventory-cap --priority 1 --trigger inventory_slots_below=31 \
        --action walk --param x=1 --param z=1
refute "an impossible inventory capacity range is refused" \
    python3 "$GP" learn bad-inventory-range --priority 1 \
        --trigger inventory_slots_at_least=28 --trigger inventory_slots_below=28 \
        --action walk --param x=1 --param z=1
refute "an empty activity scope is refused" \
    python3 "$GP" learn bad-activity --priority 1 --trigger activity_is= \
        --action walk --param x=1 --param z=1
refute "retreat refuses a zero fallback direction" \
    python3 "$GP" learn bad-retreat --priority 1 --trigger in_combat=true \
        --action retreat --param dx=0 --param dz=0
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
# The two NPCs tie under Manhattan distance and arrive farther-first. A
# diagonal neighbour is one real walking step, so it must win over the NPC
# two cardinal steps away without trusting list order.
snap 100 '[{"sidx":88,"id":478,"x":122,"z":648},{"sidx":77,"id":478,"x":121,"z":649}]'
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
echo "the immediate activity scopes learned reflexes independently of objectives (spec rules 4, 7):"
check "the current activity can be selected durably" python3 "$GP" activity trading
check_eq "the selected activity can be read by a fresh process" \
    "$(python3 "$GP" activity)" "trading"
python3 "$GP" learn only-while-banking --priority 99 --cooldown-ms 0 \
    --trigger activity_is=banking --action walk --param x=121 --param z=648 >/dev/null
snap 1031 '[]'
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "a banking reflex stays quiet during trading" "$CODE" "4"
contains "$OUT" "activity=trading" \
    && ok "the fallback verdict exposes the active mode" \
    || fail "the fallback verdict exposes the active mode" "$OUT"
python3 "$GP" activity banking >/dev/null
snap 1032 '[]'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the same reflex fires after selecting banking" "$CODE" "0"
check_eq "the activity-scoped rule emitted its walk" "$(last_action 'type=walk')" "1"
python3 "$GP" remove only-while-banking >/dev/null
python3 "$GP" activity trading >/dev/null
python3 "$GP" learn activity-agnostic --priority 98 --cooldown-ms 0 \
    --trigger near_tile='{"x":120,"z":648,"radius":2}' \
    --action walk --param x=121 --param z=648 >/dev/null
snap 10321 '[]' '{"walking":true}'
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "ordinary reflexes cannot cancel a movement already in progress" "$CODE" "3"
contains "$OUT" "movement-in-progress" \
    && ok "the movement commitment is named instead of firing ambient work" \
    || fail "the movement commitment is named instead of firing ambient work" "$OUT"
refute "walking toward an NPC emits no competing learned action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 10322 '[]' '{"talking_to_npc":true,"dialogue_open":false,"dialogue_options":[]}'
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "ordinary reflexes cannot interrupt NPC speech" "$CODE" "3"
contains "$OUT" "npc-dialogue-in-progress" \
    && ok "an exchange between choices stays committed" \
    || fail "an exchange between choices stays committed" "$OUT"
refute "NPC speech emits no competing learned action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 10323 '[]' '{"talking_to_npc":true,"dialogue_open":true,"dialogue_options":["Ask about the quest","Goodbye"]}'
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "an NPC reply menu licenses only the grounded dialogue choice" "$CODE" "4"
contains "$OUT" "npc-dialogue-choice" && contains "$OUT" "Ask about the quest" \
    && ok "the exact semantic choices ride the dialogue verdict" \
    || fail "the exact semantic choices ride the dialogue verdict" "$OUT"
refute "an open NPC reply menu emits no ambient learned action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 1033 '[]'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a rule with no activity_is remains live during trading" "$CODE" "0"
python3 "$GP" activity banking >/dev/null
snap 1034 '[]'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the same activity-agnostic rule remains live during banking" "$CODE" "0"
python3 "$GP" remove activity-agnostic >/dev/null
check "the immediate activity can be cleared" python3 "$GP" activity --clear
check_eq "a cleared activity reads as none" "$(python3 "$GP" activity)" "(none)"

echo
echo "exact repetition becomes a self-review event, not a silent loop (spec rule 16):"
python3 "$GP" activity loop-review >/dev/null
python3 "$GP" learn loop-review-probe --priority 97 --cooldown-ms 0 \
    --trigger near_tile='{"x":120,"z":648,"radius":2}' \
    --action walk --param x=121 --param z=648 >/dev/null
for tick in 10331 10332 10333; do
    snap "$tick" '[]'
    fake_bridge done
    CODE=0; python3 "$GP" step >/dev/null || CODE=$?
    wait "$FAKE_BRIDGE_PID"
    check_eq "repetition probe $tick still executes normally" "$CODE" "0"
done
python3 - "$DESKCRAB_GAME_DIR/outcome-queue.jsonl" <<'PY' \
    && ok "the third exact play queues one self-contained loop candidate" \
    || fail "the third exact play queues one self-contained loop candidate"
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
matches = [e for e in events if e.get("kind") == "loop-candidate"
           and e.get("rule") == "loop-review-probe"]
assert len(matches) == 1, matches
assert matches[0]["count"] == 3 and len(matches[0]["recent"]) == 3, matches[0]
PY
python3 "$GP" remove loop-review-probe >/dev/null
python3 "$GP" activity --clear >/dev/null

echo
echo "an activity measures grounded action XP and elapsed rate (spec rules 1, 7):"
snap 1034 '[]' '{"skills":[{"id":17,"name":"Thieving","level":0,"xp":0}]}'
check "selecting during the zero-filled login frame does not invent a baseline" \
    python3 "$GP" activity farmer-thieving
refute "the placeholder skill table produces no activity stats" \
    test -e "$DESKCRAB_GAME_DIR/activity-stats.json"
snap 1035 '[]' '{"skills":[{"id":17,"name":"Thieving","level":24,"xp":1000}]}'
CODE=0; python3 "$GP" step --local >/dev/null || CODE=$?
check_eq "the first ready skill snapshot starts the cumulative-XP baseline" "$CODE" "4"
check "the activity measurement is durable" test -f "$DESKCRAB_GAME_DIR/activity-stats.json"
python3 - "$DESKCRAB_GAME_DIR/activity-stats.json" <<'PY'
import json, sys, time
p = sys.argv[1]
s = json.load(open(p))
s["started_ms"] = int(time.time() * 1000) - 3600000
json.dump(s, open(p, "w"))
PY
snap 1036 '[]' '{"skills":[{"id":17,"name":"Thieving","level":24,"xp":1012}]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "a pure measurement pass still leaves reasoning licensed" "$CODE" "4"
contains "$OUT" "activity_xp=Thieving:+12/action,+12_total,12/hr" \
    && ok "the verdict exposes XP per action, activity gain, and XP/hour" \
    || fail "the verdict exposes XP per action, activity gain, and XP/hour" "$OUT"
python3 - "$DESKCRAB_GAME_DIR/activity-stats.json" <<'PY' \
    && ok "the exact positive XP delta is recorded as the last XP-bearing action" \
    || fail "the exact positive XP delta is recorded as the last XP-bearing action"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["baseline_xp"] == {"17": 1000}, s
assert s["last_action_xp"] == [{"id": 17, "name": "Thieving", "xp": 12}], s
PY
python3 "$GP" activity farmer-thieving >/dev/null
python3 - "$DESKCRAB_GAME_DIR/activity-stats.json" <<'PY' \
    && ok "re-selecting the current activity does not erase its history" \
    || fail "re-selecting the current activity does not erase its history"
import json, sys
assert json.load(open(sys.argv[1]))["baseline_xp"] == {"17": 1000}
PY
python3 "$GP" activity farmer-thieving --restart >/dev/null
python3 - "$DESKCRAB_GAME_DIR/activity-stats.json" <<'PY' \
    && ok "an explicit restart resets the baseline to current XP" \
    || fail "an explicit restart resets the baseline to current XP"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["baseline_xp"] == {"17": 1012} and s["last_action_xp"] == [], s
PY
python3 "$GP" activity --clear >/dev/null
refute "clearing activity also clears its measurement" \
    test -e "$DESKCRAB_GAME_DIR/activity-stats.json"

echo
echo "state-based waits use the ACTIONS snapshot without polling (spec rule 7d):"
snap 1040 '[]' '{"walking":false,"talking_to_npc":false}'
python3 "$GP" wait-until talking-to-npc --timeout 1 > "$SANDBOX/wait-out" &
WAIT_PID=$!
sleep 0.05
snap 1041 '[]' '{"walking":false,"talking_to_npc":true}'
CODE=0; wait "$WAIT_PID" || CODE=$?
OUT="$(cat "$SANDBOX/wait-out")"
check_eq "a satisfied NPC-dialogue wait exits 0" "$CODE" "0"
contains "$OUT" "condition-met condition=talking_to_npc tick=1041" \
    && ok "the wait reports the grounded condition and snapshot tick" \
    || fail "the wait reports the grounded condition and snapshot tick" "$OUT"
snap 1042 '[]' '{"walking":false,"talking_to_npc":false}'
python3 "$GP" wait-until not-talking-to-npc --timeout 1 > "$SANDBOX/wait-end-out" &
WAIT_PID=$!
sleep 0.05
snap 1043 '[]' '{"walking":false,"talking_to_npc":false}'
sleep 0.05
check "a pre-dialogue false snapshot cannot finish the dialogue-end wait" kill -0 "$WAIT_PID"
snap 1044 '[]' '{"walking":false,"talking_to_npc":true}'
sleep 0.05
check "observing dialogue begin does not finish the dialogue-end wait" kill -0 "$WAIT_PID"
snap 1045 '[]' '{"walking":false,"talking_to_npc":false}'
CODE=0; wait "$WAIT_PID" || CODE=$?
OUT="$(cat "$SANDBOX/wait-end-out")"
check_eq "dialogue end succeeds only after dialogue was observed" "$CODE" "0"
contains "$OUT" "condition-met condition=not_talking_to_npc tick=1045" \
    && ok "the dialogue-end wait reports the grounded ending snapshot" \
    || fail "the dialogue-end wait reports the grounded ending snapshot" "$OUT"
snap 10451 '[]' '{"right_click_menu_open":false}'
python3 "$GP" wait-until right-click-menu-open --timeout 1 > "$SANDBOX/wait-menu-out" &
WAIT_PID=$!
sleep 0.05
snap 10452 '[]' '{"right_click_menu_open":true}'
CODE=0; wait "$WAIT_PID" || CODE=$?
OUT="$(cat "$SANDBOX/wait-menu-out")"
check_eq "a context-menu wait exits only after the bridge sees the menu" "$CODE" "0"
contains "$OUT" "condition-met condition=right_click_menu_open tick=10452" \
    && ok "the context-menu wait reports the grounded snapshot" \
    || fail "the context-menu wait reports the grounded snapshot" "$OUT"
snap 10453 '[]' '{"right_click_menu_open":false}'
OUT="$(python3 "$GP" wait-until right_click_menu_closed --timeout 1)"; CODE=$?
check_eq "an already closed context menu satisfies the closed condition" "$CODE" "0"
snap 10454 '[]' '{"trade_open":false}'
python3 "$GP" wait-until trade_open --timeout 1 > "$SANDBOX/wait-trade-out" &
WAIT_PID=$!
sleep 0.05
snap 10455 '[]' '{"trade_open":true}'
CODE=0; wait "$WAIT_PID" || CODE=$?
check_eq "a trade wait exits only after the bridge sees the trade UI" "$CODE" "0"
contains "$(cat "$SANDBOX/wait-trade-out")" "condition-met condition=trade_open" \
    && ok "the trade wait reports its grounded condition" \
    || fail "the trade wait reports its grounded condition" "$(cat "$SANDBOX/wait-trade-out")"
snap 10456 '[]' '{"trade_open":false}'
CODE=0; OUT="$(python3 "$GP" wait-until trade_closed --timeout 1)" || CODE=$?
check_eq "an already closed trade UI satisfies trade_closed" "$CODE" "0"
snap 104561 '[]' '{"sleeping":false,"fatigue":52}'
python3 "$GP" wait-until sleeping --timeout 1 > "$SANDBOX/wait-sleep-out" &
WAIT_PID=$!
sleep 0.05
snap 104562 '[]' '{"sleeping":true,"sleep_fatigue":52,"sleep_status":"Please wait...","fatigue":52}'
CODE=0; wait "$WAIT_PID" || CODE=$?
check_eq "a sleep wait exits only after semantic state sees the sleep screen" "$CODE" "0"
contains "$(cat "$SANDBOX/wait-sleep-out")" "condition-met condition=sleeping" \
    && ok "the sleep wait reports its grounded condition" \
    || fail "the sleep wait reports its grounded condition" "$(cat "$SANDBOX/wait-sleep-out")"
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "sleep blocks every stale objective and reflex until wake-up" "$CODE" "4"
contains "$OUT" "sleeping-needs-wake" && contains "$OUT" "next=solve-current-word" \
    && ok "the player verdict makes wake-up the sole prerequisite" \
    || fail "the player verdict makes wake-up the sole prerequisite" "$OUT"
refute "the sleeping prerequisite emits no game action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 104563 '[]' '{"sleeping":false,"fatigue":0}'
CODE=0; OUT="$(python3 "$GP" wait-until not_sleeping --timeout 1)" || CODE=$?
check_eq "an awake snapshot satisfies not_sleeping" "$CODE" "0"
CODE=0; OUT="$(python3 "$GP" wait-until fatigue_zero --timeout 1)" || CODE=$?
check_eq "zero fatigue is directly waitable" "$CODE" "0"
CODE=0; OUT="$(python3 "$GP" wait-until in_combat --timeout 0.05)" || CODE=$?
check_eq "a missing transition reaches its hard ceiling: exit 2" "$CODE" "2"
contains "$OUT" "condition-timeout condition=in_combat" \
    && ok "the timeout names the missing condition" \
    || fail "the timeout names the missing condition" "$OUT"
refute "a wait above the permanent-block ceiling is refused" \
    python3 "$GP" wait-until walking --timeout 61

echo
echo "retreat breaks the three-round causal deadlock and remembers it (spec rules 7, 7d):"
snap 10457 '[]' '{"in_combat":true,"messages":[{"id":10457000,"channel":"game","incoming":false,"sender":"","text":"You can\u0027t retreat during the first 3 rounds of combat"}]}'
CODE=0; OUT="$(python3 "$GP" wait-until out_of_combat --timeout 5)" || CODE=$?
check_eq "waiting cannot pretend it will cause a locked retreat: exit 2" "$CODE" "2"
contains "$OUT" "condition-needs-action condition=out_of_combat reason=retreat-locked next=retreat" \
    && ok "the deadlock names the action that must be retried" \
    || fail "the deadlock names the action that must be retried" "$OUT"
check_eq "the failed strategy entered the durable learning queue" \
    "$(sandbox_count_in '"status":"needs-retreat-action"' "$DESKCRAB_GAME_DIR/outcome-queue.jsonl")" "1"

python3 "$GP" activity farmer-thieving >/dev/null
check "an activity-scoped retreat rule can be learned" \
    python3 "$GP" learn retreat-from-farmer-test --priority 1000 --cooldown-ms 0 \
        --trigger activity_is=farmer-thieving --trigger in_combat=true \
        --action retreat --param distance=5 --param dx=0 --param dz=1
snap 10458 '[]' '{"in_combat":true,"messages":[{"id":10458000,"channel":"local","incoming":true,"sender":"Ryan","text":"Please do not kill him"}]}'
fake_retreat_bridge locked
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a server-locked first attempt is not called success" "$CODE" "2"
contains "$OUT" "status=retreat-locked" \
    && ok "the rejected escape is classified for the next pass" \
    || fail "the rejected escape is classified for the next pass" "$OUT"
check_eq "retreat used its own stable bridge action" "$(last_action 'type=retreat')" "1"
fake_retreat_bridge done
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the next eligible attempt ends only on observed safety" "$CODE" "0"
contains "$OUT" "type=retreat status=done" \
    && ok "the verified escape is reported as done" \
    || fail "the verified escape is reported as done" "$OUT"
check_eq "urgent activity retreat outranked the pending conversation" \
    "$(last_action 'type=retreat')" "1"
python3 "$GP" remove retreat-from-farmer-test >/dev/null
python3 "$GP" activity --clear >/dev/null
rm -f "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json"

echo
echo "durable routes advance through ACTIONS without model turns (spec rule 7e):"
python3 "$GP" objective cross-region >/dev/null
check "route records a destination" python3 "$GP" route 160 648 --arrive 1
contains "$(python3 "$GP" route)" "status=active target=(160,648) arrive=1" \
    && ok "route status exposes its target and tolerance" \
    || fail "route status exposes its target and tolerance" "$(python3 "$GP" route)"
snap 1046 '[]' '{"x":120,"z":648}'
fake_route_bridge 140 648
OUT="$(python3 "$GP" step --local)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "one regional settlement is successful progress: exit 0" "$CODE" "0"
contains "$OUT" "status=route-progress x=140 z=648" \
    && ok "the runner names verified progress rather than a failed walk" \
    || fail "the runner names verified progress rather than a failed walk" "$OUT"
check "the destination remains durable for the next runner pass" \
    test -f "$DESKCRAB_GAME_DIR/route.json"
check_eq "the synthetic route used the ordinary walk ACTION" \
    "$(last_action 'type=walk')" "1"
snap 1048 '[]' '{"x":140,"z":648}'
fake_route_bridge 160 648
OUT="$(python3 "$GP" step --local)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "arrival completes the route: exit 0" "$CODE" "0"
contains "$OUT" "status=route-complete" \
    && ok "completion is explicit" || fail "completion is explicit" "$OUT"
refute "the completed route cannot fire again" test -f "$DESKCRAB_GAME_DIR/route.json"

check "a second route can be set" python3 "$GP" route 900 900
snap 1050 '[]' '{"x":140,"z":648}'
fake_bridge refused-no-path
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a collision refusal licenses Sol to solve the obstacle: exit 4" "$CODE" "4"
contains "$OUT" "route-blocked" \
    && ok "the blocker is named" || fail "the blocker is named" "$OUT"
contains "$(python3 "$GP" route)" "status=blocked" \
    && ok "the blocked state persists" || fail "the blocked state persists"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 1051 '[]' '{"x":140,"z":648}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "an unchanged wall cannot cause a walking loop: exit 4" "$CODE" "4"
refute "and no repeated action was emitted" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 10511 '[]' '{"x":141,"z":648}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "a late settling tile cannot revive the same failed route: exit 4" "$CODE" "4"
refute "and the failed route still emits no repeated action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"

python3 "$GP" objective changed-goal >/dev/null
snap 1052 '[]' '{"x":140,"z":648}'
CODE=0; python3 "$GP" step --local >/dev/null || CODE=$?
refute "changing objective cancels the stale route" test -f "$DESKCRAB_GAME_DIR/route.json"
check "route clear is idempotent" python3 "$GP" route --clear
python3 "$GP" objective --clear >/dev/null

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

python3 "$GP" learn capacity-gated-walk --priority 2 --cooldown-ms 0 \
    --trigger inventory_slots_below=30 --trigger npc_visible=478 \
    --action talk-npc --param npc=478 >/dev/null
snap 126 '[{"sidx":77,"id":478,"x":121,"z":648}]' \
    '{"inventory":[{"id":20,"amount":1},{"id":20,"amount":1}]}'
fake_bridge done
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "capacity-gated action fires while slots remain" "$CODE" "0"
python3 "$GP" remove capacity-gated-walk >/dev/null

python3 "$GP" learn full-bag-walk --priority 2 --cooldown-ms 0 \
    --trigger inventory_slots_at_least=30 --trigger npc_visible=478 \
    --action talk-npc --param npc=478 >/dev/null
FULL_INV="$(python3 - <<'PY'
import json
print(json.dumps({"inventory": [{"id": 20, "amount": 1}] * 30}))
PY
)"
snap 127 '[{"sidx":77,"id":478,"x":121,"z":648}]' "$FULL_INV"
fake_bridge done
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a full-bag trigger sees all thirty occupied slots" "$CODE" "0"
python3 "$GP" remove full-bag-walk >/dev/null

echo
echo "visible ground items become identity-based learned actions (spec rules 4-5):"
refute "take-ground without an item id is refused" \
    python3 "$GP" learn bad-ground --priority 1 --trigger ground_item_visible=27 \
        --action take-ground
refute "take-ground refuses a roaming cap beyond ten tiles" \
    python3 "$GP" learn bad-ground-range --priority 1 --trigger ground_item_visible=27 \
        --action take-ground --param item=27 --param within=11
refute "a non-integer ground_item_visible is refused" \
    python3 "$GP" learn bad-ground2 --priority 1 --trigger ground_item_visible=skull \
        --action take-ground --param item=27
python3 "$GP" objective recover-ghost-skull >/dev/null
python3 "$GP" learn take-quest-skull --priority 90 --cooldown-ms 0 --once-per-objective \
    --trigger objective_is=recover-ghost-skull --trigger ground_item_visible=27 \
    --action take-ground --param item=27 >/dev/null
snap 129 '[]' '{"ground_items":[{"id":27,"x":218,"z":3527},{"id":27,"x":230,"z":3540}]}'
fake_take_bridge collected
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the visible quest item rule receives a done receipt" "$CODE" "0"
contains "$OUT" "fired rule=take-quest-skull" && ok "the skull rule owns the play" \
    || fail "the skull rule owns the play" "$OUT"
check_eq "the action is take-ground" "$(last_action 'type=take-ground')" "1"
check_eq "the item identity crosses ACTIONS" "$(last_action 'item=27')" "1"
check_eq "the nearest current tile crosses ACTIONS" "$(last_action 'x=218')" "1"
snap 1291 '[]' '{"ground_items":[{"id":27,"x":218,"z":3527}]}'
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "an unmatched fallback with a visible pickup exits 4" "$CODE" "4"
contains "$OUT" "ground_items=27" \
    && ok "the fallback verdict makes the visible pickup explicit" \
    || fail "the fallback verdict makes the visible pickup explicit" "$OUT"
python3 "$GP" remove take-quest-skull >/dev/null
python3 "$GP" learn take-nearby-skull --priority 90 --cooldown-ms 0 \
    --trigger ground_item_visible=27 --action take-ground --param item=27 --param within=2 >/dev/null
snap 1292 '[]' '{"x":120,"z":648,"ground_items":[{"id":27,"x":124,"z":648}]}'
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "a local loot reflex will not chase a distant visible pile" "$CODE" "4"
snap 1293 '[]' '{"x":120,"z":648,"ground_items":[{"id":27,"x":122,"z":649}]}'
fake_take_bridge collected
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the same loot reflex fires when the pile is genuinely nearby" "$CODE" "0"
check_eq "the nearby pile still compiles to its exact live tile" "$(last_action 'x=122')" "1"
python3 "$GP" remove take-nearby-skull >/dev/null
python3 "$GP" learn routine-farmer-pocket --priority 40 --cooldown-ms 0 \
    --trigger npc_visible=63 --trigger out_of_combat=true \
    --action interact-npc --param npc=63 --param cmd=1 >/dev/null
python3 "$GP" learn wanted-coins-before-routine --priority 900 --cooldown-ms 0 \
    --trigger ground_item_visible=10 --trigger out_of_combat=true \
    --action take-ground --param item=10 >/dev/null
snap 1294 '[{"sidx":63,"id":63,"x":121,"z":648}]' \
    '{"ground_items":[{"id":10,"x":128,"z":648}]}'
fake_take_bridge collected
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "wanted distant loot preempts routine activity and verifies collection" "$CODE" "0"
contains "$OUT" "rule=wanted-coins-before-routine" \
    && contains "$OUT" "status=done" \
    && ok "the pickup commitment survives its approach instead of falling back to the NPC" \
    || fail "the pickup commitment survives its approach instead of falling back to the NPC" "$OUT"
check_eq "the distant wanted pile is approached through take-ground" \
    "$(last_action 'type=take-ground')" "1"
python3 "$GP" remove routine-farmer-pocket >/dev/null
python3 "$GP" remove wanted-coins-before-routine >/dev/null
python3 "$GP" objective --clear >/dev/null

echo
echo "doors and scenery: interact-object / interact-bound (spec rules 4-5):"
refute "interact-object without its obj id is refused" \
    python3 "$GP" learn bad5 --priority 1 --trigger object_visible=493 --action interact-object
refute "a cmd outside 1-2 is refused" \
    python3 "$GP" learn bad6 --priority 1 --trigger object_visible=493 \
        --action interact-object --param obj=493 --param cmd=3
python3 "$GP" objective train-thieving >/dev/null
python3 "$GP" learn pickpocket-man --priority 75 --cooldown-ms 0 \
    --trigger objective_is=train-thieving --trigger npc_visible=11 \
    --trigger out_of_combat=true --action interact-npc --param npc=11 --param cmd=1 \
    --param within=2 >/dev/null
snap 1295 '[{"sidx":91,"id":11,"x":121,"z":648}]' '{"in_combat":true}'
CODE=0; python3 "$GP" step >/dev/null || CODE=$?
check_eq "an out-of-combat NPC rule stays quiet during a fight" "$CODE" "4"
snap 12951 '[{"sidx":91,"id":11,"x":140,"z":660}]' '{"in_combat":false}'
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "a repeating NPC reflex will not chase a distant visible target" "$CODE" "4"
check_eq "the range refusal is recorded for diagnosis" \
    "$(decided refused)" "3"
snap 1296 '[{"sidx":91,"id":11,"x":121,"z":648}]' '{"in_combat":false}'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the direct NPC command fires once combat is clear" "$CODE" "0"
check_eq "the action is interact-npc" "$(last_action 'type=interact-npc')" "1"
check_eq "it carries the stable server index" "$(last_action 'sidx=91')" "1"
check_eq "and the NPC definition command" "$(last_action 'cmd=1')" "1"
check_eq "the range cap crosses ACTIONS for a live dispatch recheck" \
    "$(last_action 'within=2')" "1"
python3 "$GP" remove pickpocket-man >/dev/null
python3 "$GP" objective --clear >/dev/null
refute "a non-integer bound_visible is refused" \
    python3 "$GP" learn bad7 --priority 1 --trigger bound_visible=door \
        --action interact-bound --param obj=1
refute "click-entity refuses an unknown entity kind" \
    python3 "$GP" learn bad8 --priority 1 --trigger npc_visible=2 \
        --action click-entity --param kind=widget --param entity=2
refute "click-entity refuses a mouse button outside 1-3" \
    python3 "$GP" learn bad9 --priority 1 --trigger npc_visible=2 \
        --action click-entity --param kind=npc --param entity=2 --param button=4
refute "click-inventory without an item id is refused" \
    python3 "$GP" learn bad10 --priority 1 --trigger inventory_has=145 \
        --action click-inventory
refute "click-inventory refuses a mouse button outside 1-3" \
    python3 "$GP" learn bad11 --priority 1 --trigger inventory_has=145 \
        --action click-inventory --param item=145 --param button=4
refute "click-shop without an item id is refused" \
    python3 "$GP" learn bad-shop --priority 1 --trigger shop_item_visible=42 \
        --action click-shop
refute "click-bank refuses a mouse button outside 1-3" \
    python3 "$GP" learn bad-bank --priority 1 --trigger bank_item_visible=145 \
        --action click-bank --param item=145 --param button=4
refute "a non-integer shop_item_visible is refused" \
    python3 "$GP" learn bad-shop-trigger --priority 1 --trigger shop_item_visible=bucket \
        --action click-shop --param item=42
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
check_eq "and the refusal is logged" "$(decided refused)" "4"
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
echo "identity-based inventory clicks compile without slots or pixels (spec rule 5):"
python3 "$GP" objective spin-wool >/dev/null
python3 "$GP" learn click-raw-wool --priority 80 --cooldown-ms 0 --once-per-objective \
    --trigger objective_is=spin-wool --trigger inventory_has=145 \
    --action click-inventory --param item=145 --param button=1 >/dev/null
snap 134 '[]' '{"inventory":[{"id":145,"count":3},{"id":207,"count":1}]}'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the learned inventory click receives a done receipt" "$CODE" "0"
contains "$OUT" "fired rule=click-raw-wool" && ok "the inventory rule owned the play" \
    || fail "the inventory rule owned the play" "$OUT"
check_eq "the action is click-inventory" "$(last_action 'type=click-inventory')" "1"
check_eq "the item id crosses ACTIONS" "$(last_action 'item=145')" "1"
check_eq "the pointer button rides the inventory action" "$(last_action 'button=1')" "1"
refute "no inventory slot crosses the action" grep -q '^slot=' "$DESKCRAB_GAME_STATE_DIR/last-action"
refute "no inventory x coordinate crosses the action" grep -q '^x=' "$DESKCRAB_GAME_STATE_DIR/last-action"
refute "no inventory y coordinate crosses the action" grep -q '^y=' "$DESKCRAB_GAME_STATE_DIR/last-action"
python3 "$GP" remove click-raw-wool >/dev/null
python3 "$GP" objective --clear >/dev/null

echo
echo "identity-based shop and bank clicks compile without pages, slots, or pixels (spec rule 5):"
python3 "$GP" objective buy-supplies >/dev/null
python3 "$GP" learn click-shop-bucket --priority 80 --cooldown-ms 0 --once-per-objective \
    --trigger objective_is=buy-supplies --trigger shop_item_visible=42 \
    --action click-shop --param item=42 --param button=1 >/dev/null
snap 1341 '[]' '{"shop_open":true,"shop_items":[{"slot":17,"id":42,"name":"Bucket","count":3,"noted":false}]}'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the learned shop click receives a done receipt" "$CODE" "0"
contains "$OUT" "fired rule=click-shop-bucket" && ok "the shop item rule owned the play" \
    || fail "the shop item rule owned the play" "$OUT"
check_eq "the action is click-shop" "$(last_action 'type=click-shop')" "1"
check_eq "only the shop item id crosses ACTIONS" "$(last_action 'item=42')" "1"
refute "no shop slot crosses the action" grep -q '^slot=' "$DESKCRAB_GAME_STATE_DIR/last-action"
refute "no shop pixel crosses the action" grep -Eq '^[xy]=' "$DESKCRAB_GAME_STATE_DIR/last-action"
python3 "$GP" remove click-shop-bucket >/dev/null

python3 "$GP" objective withdraw-supplies >/dev/null
python3 "$GP" learn click-bank-bucket --priority 80 --cooldown-ms 0 --once-per-objective \
    --trigger objective_is=withdraw-supplies --trigger bank_item_visible=145 \
    --action click-bank --param item=145 --param button=3 >/dev/null
snap 1342 '[]' '{"bank_open":true,"bank_items":[{"slot":117,"id":145,"name":"Bucket","count":1}]}'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the learned bank click receives a done receipt" "$CODE" "0"
contains "$OUT" "fired rule=click-bank-bucket" && ok "the bank item rule owned the play" \
    || fail "the bank item rule owned the play" "$OUT"
check_eq "the action is click-bank" "$(last_action 'type=click-bank')" "1"
check_eq "only the bank item id crosses ACTIONS" "$(last_action 'item=145')" "1"
check_eq "the requested bank pointer button crosses ACTIONS" "$(last_action 'button=3')" "1"
refute "no bank page or slot crosses the action" grep -Eq '^(page|slot)=' "$DESKCRAB_GAME_STATE_DIR/last-action"
refute "no bank pixel crosses the action" grep -Eq '^[xy]=' "$DESKCRAB_GAME_STATE_DIR/last-action"
python3 "$GP" remove click-bank-bucket >/dev/null
python3 "$GP" objective deposit-supplies >/dev/null
python3 "$GP" learn select-inventory-bones-in-bank --priority 80 --cooldown-ms 0 \
    --trigger objective_is=deposit-supplies --trigger inventory_has=20 \
    --action click-bank --param item=20 --param button=1 >/dev/null
snap 1343 '[]' '{"bank_open":true,"bank_items":[],"inventory":[{"id":20,"count":1}]}'
fake_bridge done
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "an inventory item with no bank stack is selectable for deposit" "$CODE" "0"
check_eq "that selection still crosses as click-bank identity" "$(last_action 'type=click-bank')" "1"
check_eq "and carries only the inventory item id" "$(last_action 'item=20')" "1"
python3 "$GP" remove select-inventory-bones-in-bank >/dev/null
python3 "$GP" objective --clear >/dev/null

echo
echo "the real playing entrypoint invokes this layer (spec rule 12):"
# The game tree is recovered the same way the bridge
# suite borrows it: the sandbox moved HOME, the live-data path remembers.
REAL_HOME="$(cd "$SANDBOX_LIVE_DATA/../../.." 2>/dev/null && pwd)"
GAME_TREE="${DESKCRAB_OPENRSC_TREE:-$REAL_HOME/Games/OpenRSC}"
HEADLESS="$GAME_TREE/headless/orsc-headless.sh"
if [ ! -f "$HEADLESS" ]; then
    sandbox_skip "no local OpenRSC headless harness at $HEADLESS"
fi
check_eq "the harness carries the identity-based entity door" \
    "$(sandbox_count_in '^    entity)' "$HEADLESS")" "1"
check_eq "the harness carries the definition-backed NPC command door" \
    "$(sandbox_count_in '^    npc)' "$HEADLESS")" "1"
check_eq "the harness carries the direct player-trade door" \
    "$(sandbox_count_in '^    trade)' "$HEADLESS")" "1"
check_eq "the harness carries the unambiguous menu-text door" \
    "$(sandbox_count_in '^    menu)' "$HEADLESS")" "1"
check_eq "the harness carries the semantic NPC-dialogue door" \
    "$(sandbox_count_in '^    dialogue)' "$HEADLESS")" "1"
check_eq "the harness carries the bounded visual aiming fallback" \
    "$(sandbox_count_in '^    aim)' "$HEADLESS")" "1"
check_eq "the harness carries the identity-based inventory door" \
    "$(sandbox_count_in '^    inventory)' "$HEADLESS")" "1"
check_eq "the harness carries the semantic equipment listing door" \
    "$(sandbox_count_in '^    equipment)' "$HEADLESS")" "1"
check_eq "the harness carries idempotent equip and unequip doors" \
    "$(sandbox_count_in '^    equip|unequip)' "$HEADLESS")" "1"
check_eq "the harness carries the named item-command door" \
    "$(sandbox_count_in '^    item)' "$HEADLESS")" "1"
check_eq "the harness carries the identity-based shop door" \
    "$(sandbox_count_in '^    shop)' "$HEADLESS")" "1"
check_eq "the harness carries the identity-based bank door" \
    "$(sandbox_count_in '^    bank)' "$HEADLESS")" "1"
check_eq "the harness carries the visible ground-item listing door" \
    "$(sandbox_count_in '^    items)' "$HEADLESS")" "1"
check_eq "the harness carries the identity-based ground-item take door" \
    "$(sandbox_count_in '^    take)' "$HEADLESS")" "1"
check_eq "the harness carries the event-driven state wait door" \
    "$(sandbox_count_in '^    wait-until|wait_until)' "$HEADLESS")" "1"
check_eq "the harness carries the bounded verified retreat door" \
    "$(sandbox_count_in '^    retreat)' "$HEADLESS")" "1"
check_eq "the harness carries a play door" \
    "$(sandbox_count_in '^    play' "$HEADLESS")" "1"
check_eq "wired to game_player.py, not merely present in lib" \
    "$(grep -c 'game_player.py' "$HEADLESS")" "1"
check_eq "and the policy step is rules-first: play refuses reasoning until exit 4" \
    "$(grep -c 'no-rule-matched' "$HEADLESS")" "1"

# The visual fallback is wired through the real harness, which supplies the
# private display and state path instead of asking Sol to remember either.
AIMHOME="$SANDBOX/aimhome"; mkdir -p "$AIMHOME/run"
printf '98\n' > "$AIMHOME/run/display"
printf '%s\n' "$$" > "$AIMHOME/run/xvfb.pid"
AIMFAKE="$SANDBOX/fake-aim.py"; AIMCAP="$SANDBOX/aim-capture"
cat > "$AIMFAKE" <<'PY'
#!/usr/bin/env python3
import os, sys
open(os.environ['AIM_CAPTURE'], 'w').write('\n'.join(sys.argv[1:]))
print('dry-run intent=red-cape gate=skipped')
PY
OUT="$(ORSC_HEADLESS_HOME="$AIMHOME" DESKCRAB_GAME_NPC_CLICK="$AIMFAKE" \
       AIM_CAPTURE="$AIMCAP" bash "$HEADLESS" aim red-cape --dry-run)"
contains "$OUT" "dry-run intent=red-cape" \
    && ok "the real harness delegates visual aiming to the one implementation" \
    || fail "the real harness delegates visual aiming to the one implementation" "$OUT"
contains "$(cat "$AIMCAP")" $'--display\n98' \
    && ok "the aiming door discovers the private display" \
    || fail "the aiming door discovers the private display" "$(cat "$AIMCAP")"
contains "$(cat "$AIMCAP")" $'--state-dir\n'"$DESKCRAB_GAME_STATE_DIR" \
    && ok "the aiming door supplies the shared guarded state" \
    || fail "the aiming door supplies the shared guarded state" "$(cat "$AIMCAP")"
contains "$(cat "$AIMCAP")" "red-cape" \
    && ok "the visual intent crosses the door unchanged" \
    || fail "the visual intent crosses the door unchanged" "$(cat "$AIMCAP")"
snap 1170 '[]' '{"messages":[
    {"id":9010,"channel":"local","incoming":true,"sender":"Nearby Player","text":"Try the east door"}
]}'
python3 "$GP" step --local >/dev/null 2>&1 || true
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
CODE=0; OUT="$(BETTY_OPENRSC_AUTONOMOUS=1 bash "$HEADLESS" walk 130 650 2>&1)" || CODE=$?
check_eq "an unanswered player message blocks autonomous movement: exit 6" "$CODE" "6"
refute "the settling gate does not tell Sol to reply before the burst closes" \
    contains "$OUT" "reply before any further play"
contains "$OUT" "five-second chat chain" \
    && ok "the gate blocks play while ACTIONS collects the message burst" \
    || fail "the gate explains the ACTIONS message-settle window" "$OUT"
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
snap 11701 '[{"sidx":55,"id":11,"x":121,"z":648}]'
fake_bridge done
OUT="$(bash "$HEADLESS" npc 11 1)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the NPC command door completes through ACTIONS" "$CODE" "0"
contains "$OUT" "npc(11 sidx=55 cmd=1)" \
    && ok "and reports the stable NPC identity and command" \
    || fail "and reports the stable NPC identity and command" "$OUT"
check_eq "the door wrote interact-npc" "$(last_action 'type=interact-npc')" "1"
refute "the NPC command door did not move the pointer" \
    grep -Eq '^(x|y|button)=' "$DESKCRAB_GAME_STATE_DIR/last-action"
snap 11702 '[]' '{"players":[{"sidx":55,"name":"Discordian","x":121,"z":648}]}'
fake_bridge done
OUT="$(bash "$HEADLESS" trade Discordian)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the direct trade door completes through ACTIONS" "$CODE" "0"
contains "$OUT" "trade(Discordian sidx=55)" \
    && ok "and reports the player identity it targeted" \
    || fail "and reports the player identity it targeted" "$OUT"
check_eq "the trade door wrote trade-player" "$(last_action 'type=trade-player')" "1"
refute "the trade door did not move the pointer" \
    grep -Eq '^(x|y|button)=' "$DESKCRAB_GAME_STATE_DIR/last-action"
snap 117021 '[]' '{"trade_open":true,"trade":{"stage":"offer","partner":"Discordian","my_accepted":false,"their_accepted":true,"my_offer":[],"their_offer":[{"id":145,"name":"Tinderbox","count":1}]}}'
OUT="$(bash "$HEADLESS" trade status)"; CODE=$?
check_eq "trade status reads the structured trade screen" "$CODE" "0"
contains "$OUT" "stage=offer partner=Discordian" \
    && contains "$OUT" "receive: id=145 Tinderbox x1" \
    && ok "trade status exposes partner, acceptance, and offers" \
    || fail "trade status exposes partner, acceptance, and offers" "$OUT"
fake_bridge done
OUT="$(bash "$HEADLESS" trade accept)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "trade accept completes through ACTIONS" "$CODE" "0"
check_eq "the accept door wrote trade-accept" "$(last_action 'type=trade-accept')" "1"
check_eq "the accept door grounds the stage it saw" "$(last_action 'stage=offer')" "1"
snap 11703 '[]' '{"right_click_menu_open":true,"menu_options":["Trade with Discordian","Follow Discordian"]}'
fake_bridge done
OUT="$(bash "$HEADLESS" menu 'Trade with Discordian')"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the menu-text door completes through ACTIONS" "$CODE" "0"
contains "$OUT" "menu(Trade with Discordian)" \
    && ok "and preserves the whole text fragment" \
    || fail "and preserves the whole text fragment" "$OUT"
check_eq "the menu door wrote choose-menu" "$(last_action 'type=choose-menu')" "1"
check_eq "the action carries one intact text field" \
    "$(last_action 'text=Trade with Discordian')" "1"
snap 117031 '[]' '{"talking_to_npc":true,"dialogue_open":true,"dialogue_options":["Ask about the quest","Goodbye"]}'
OUT="$(bash "$HEADLESS" dialogue)"; CODE=$?
check_eq "the dialogue door lists semantic NPC replies" "$CODE" "0"
contains "$OUT" "1: Ask about the quest" && contains "$OUT" "2: Goodbye" \
    && ok "the reply list exposes exact live text" \
    || fail "the reply list exposes exact live text" "$OUT"
fake_bridge done
OUT="$(bash "$HEADLESS" dialogue 'Ask about')"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the dialogue-text door completes through ACTIONS" "$CODE" "0"
contains "$OUT" "dialogue(Ask about)" \
    && ok "the dialogue door preserves the text fragment" \
    || fail "the dialogue door preserves the text fragment" "$OUT"
check_eq "the dialogue door wrote choose-dialogue" \
    "$(last_action 'type=choose-dialogue')" "1"
check_eq "the dialogue action carries one intact text field" \
    "$(last_action 'text=Ask about')" "1"
snap 1172 '[]' '{"inventory":[{"id":145,"count":2}]}'
fake_bridge done
OUT="$(bash "$HEADLESS" inventory 145 3)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the inventory door completes through the shared ACTIONS receipt" "$CODE" "0"
contains "$OUT" "inventory(item=145 button=3)" \
    && ok "and reports the item identity it targeted" \
    || fail "and reports the item identity it targeted" "$OUT"
check_eq "the door wrote click-inventory" "$(last_action 'type=click-inventory')" "1"
check_eq "the door wrote only the item id" "$(last_action 'item=145')" "1"
refute "the inventory door did not write a slot" \
    grep -q '^slot=' "$DESKCRAB_GAME_STATE_DIR/last-action"
snap 11720 '[]' '{"inventory":[{"id":71,"name":"Iron Long Sword","count":1,"equipped":true,"commands":["Remove"]},{"id":104,"name":"Medium Bronze Helmet","count":1,"equipped":false,"commands":["Wear"]},{"id":20,"name":"Bones","count":3,"equipped":false,"commands":["Bury"]}],"equipment":[{"id":71,"name":"Iron Long Sword","count":1}],"equipment_stats":{"Armour":0,"WeaponAim":8}}'
OUT="$(bash "$HEADLESS" inventory)"; CODE=$?
check_eq "the inventory listing reads semantic state" "$CODE" "0"
contains "$OUT" "Medium Bronze Helmet" && contains "$OUT" "commands=[Bury]" \
    && ok "the inventory listing exposes names, equipped state, and commands" \
    || fail "the inventory listing exposes names, equipped state, and commands" "$OUT"
OUT="$(bash "$HEADLESS" inventory 104 2>&1)"; CODE=$?
check_eq "a wearable cannot be toggled through the ambiguous inventory door" "$CODE" "2"
contains "$OUT" "use '" && contains "$OUT" "equip 104" \
    && ok "the refusal points to the idempotent final-state doors" \
    || fail "the refusal points to the idempotent final-state doors" "$OUT"
refute "the refused wearable toggle emits no ACTIONS packet" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
OUT="$(bash "$HEADLESS" equipment)"; CODE=$?
check_eq "the equipment listing reads semantic state" "$CODE" "0"
contains "$OUT" "Iron Long Sword" && contains "$OUT" "WeaponAim=8" \
    && ok "the equipment listing exposes the final set and bonuses" \
    || fail "the equipment listing exposes the final set and bonuses" "$OUT"
fake_bridge done
OUT="$(bash "$HEADLESS" equip 104)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "equip waits for the requested final state" "$CODE" "0"
contains "$OUT" "equipment-verified item=104 equipped=true" \
    && ok "equip reports grounded completion" \
    || fail "equip reports grounded completion" "$OUT"
check_eq "equip uses the idempotent bridge action" \
    "$(last_action 'type=equip-inventory')" "1"
fake_bridge done
OUT="$(bash "$HEADLESS" unequip 71)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "unequip waits for the requested final state" "$CODE" "0"
check_eq "unequip uses the idempotent bridge action" \
    "$(last_action 'type=unequip-inventory')" "1"
fake_bridge done
OUT="$(bash "$HEADLESS" item 20 bury all)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a named consumptive item command verifies inventory change" "$CODE" "0"
contains "$OUT" "item-command-verified command=Bury item=20 before=3 after=0" \
    && ok "bury all cannot confuse a hover with progress" \
    || fail "bury all cannot confuse a hover with progress" "$OUT"
check_eq "the item door uses the definition-backed bridge action" \
    "$(last_action 'type=command-inventory')" "1"
check_eq "bury all resolves the held quantity" "$(last_action 'amount=3')" "1"
snap 117201 '[]' '{"fatigue":0,"sleeping":false,"inventory":[{"id":1263,"name":"Sleeping Bag","count":1,"equipped":false,"wearable":false,"commands":["Sleep"]}]}'
OUT="$(bash "$HEADLESS" item 1263 sleep)"; CODE=$?
check_eq "sleep at zero fatigue is an idempotent success" "$CODE" "0"
contains "$OUT" "already-satisfied" && contains "$OUT" "no sleep action emitted" \
    && ok "the rested result explains why no retry was sent" \
    || fail "the rested result explains why no retry was sent" "$OUT"
refute "zero-fatigue sleep emits no ACTIONS packet" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 117202 '[]' '{"fatigue":52,"sleeping":true,"sleep_fatigue":52,"inventory":[{"id":1263,"name":"Sleeping Bag","count":1,"equipped":false,"wearable":false,"commands":["Sleep"]}]}'
CODE=0; OUT="$(bash "$HEADLESS" item 1263 sleep)" || CODE=$?
check_eq "retrying the bag while already asleep is blocked" "$CODE" "2"
contains "$OUT" "already-sleeping" && contains "$OUT" "wake-and-verify" \
    && ok "the blocked retry preserves the wake-up prerequisite" \
    || fail "the blocked retry preserves the wake-up prerequisite" "$OUT"
refute "already-sleeping retry emits no ACTIONS packet" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 11721 '[]' '{"shop_open":true,"shop_items":[{"slot":17,"id":42,"name":"Bucket","count":3,"noted":false}]}'
OUT="$(bash "$HEADLESS" shop)"; CODE=$?
check_eq "the shop listing reads ACTIONS state without a model call" "$CODE" "0"
contains "$OUT" "Bucket" && ok "the shop listing names the located item" \
    || fail "the shop listing names the located item" "$OUT"
fake_bridge done
OUT="$(bash "$HEADLESS" shop 42 2)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the shop door completes through the shared ACTIONS receipt" "$CODE" "0"
check_eq "the shop door wrote click-shop" "$(last_action 'type=click-shop')" "1"
refute "the shop door did not write a slot" \
    grep -q '^slot=' "$DESKCRAB_GAME_STATE_DIR/last-action"
snap 117211 '[]' '{"shop_open":true,"shop_items":[{"slot":17,"id":42,"name":"Bucket","count":3,"noted":false}],"inventory":[{"id":42,"count":2}]}'
fake_bridge done
OUT="$(bash "$HEADLESS" shop buy 42 all)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "shop buy bypasses the amount buttons" "$CODE" "0"
check_eq "shop buy writes the direct transaction" "$(last_action 'type=shop-buy')" "1"
check_eq "buy all resolves the visible stock" "$(last_action 'amount=3')" "1"
fake_bridge done
OUT="$(bash "$HEADLESS" shop sell 42 all)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "shop sell bypasses the amount buttons" "$CODE" "0"
check_eq "sell all resolves the inventory quantity" "$(last_action 'amount=2')" "1"
snap 11722 '[]' '{"bank_open":true,"bank_items":[{"slot":117,"id":145,"name":"Bucket","count":1}]}'
OUT="$(bash "$HEADLESS" bank)"; CODE=$?
check_eq "the bank listing reads ACTIONS state without a model call" "$CODE" "0"
contains "$OUT" "slot=117" && ok "the bank listing locates an item beyond the first page" \
    || fail "the bank listing locates an item beyond the first page" "$OUT"
fake_bridge done
OUT="$(bash "$HEADLESS" bank 145 3)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the bank door completes through the shared ACTIONS receipt" "$CODE" "0"
check_eq "the bank door wrote click-bank" "$(last_action 'type=click-bank')" "1"
refute "the bank door did not write a page or slot" \
    grep -Eq '^(page|slot)=' "$DESKCRAB_GAME_STATE_DIR/last-action"
snap 11723 '[]' '{"bank_open":true,"bank_items":[],"inventory":[{"id":20,"count":1}]}'
fake_bridge done
OUT="$(bash "$HEADLESS" bank 20 1)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the bank door accepts an inventory item available for deposit" "$CODE" "0"
check_eq "the inventory item still crosses only as bank identity" "$(last_action 'item=20')" "1"
fake_bridge done
OUT="$(bash "$HEADLESS" bank deposit 20 all)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "bank deposit bypasses the amount buttons" "$CODE" "0"
check_eq "bank deposit writes the direct transaction" "$(last_action 'type=bank-deposit')" "1"
check_eq "deposit all resolves the inventory quantity" "$(last_action 'amount=1')" "1"
snap 11724 '[]' '{"bank_open":true,"bank_items":[{"slot":117,"id":145,"name":"Bucket","count":7}],"inventory":[]}'
fake_bridge done
OUT="$(bash "$HEADLESS" bank withdraw 145 all)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "bank withdraw bypasses the amount buttons" "$CODE" "0"
check_eq "withdraw all resolves the bank quantity" "$(last_action 'amount=7')" "1"
snap 1173 '[]' '{"ground_items":[{"id":27,"x":121,"z":649}]}'
fake_take_bridge collected
OUT="$(DESKCRAB_GAME_PLAYER="$GP" bash "$HEADLESS" take 27)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the ground-item door completes only after grounded transfer" "$CODE" "0"
contains "$OUT" "taken" && contains "$OUT" "item=27" && contains "$OUT" "gained=1" \
    && ok "and reports the verified item and inventory gain" \
    || fail "and reports the verified item and inventory gain" "$OUT"
check_eq "the door wrote take-ground" "$(last_action 'type=take-ground')" "1"
check_eq "the door wrote the current item tile" "$(last_action 'x=121')" "1"
snap 11731 '[]' '{"in_combat":true,"ground_items":[{"id":27,"x":121,"z":649}]}'
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
CODE=0; OUT="$(DESKCRAB_GAME_PLAYER="$GP" bash "$HEADLESS" take 27)" || CODE=$?
check_eq "a direct pickup during combat requires the causal escape first" "$CODE" "2"
contains "$OUT" "take-needs-retreat item=27" && contains "$OUT" "next=retreat" \
    && ok "the pickup door points to retreat instead of sending a doomed take" \
    || fail "the pickup door points to retreat instead of sending a doomed take" "$OUT"
refute "the combat-blocked pickup emits no ACTIONS packet" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
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
snap 1191 '[]' '{"walking":true}'
DESKCRAB_GAME_PLAYER="$GP" bash "$HEADLESS" wait_until not_walking 1 \
    > "$SANDBOX/headless-wait-out" &
WAIT_PID=$!
sleep 0.05
snap 1192 '[]' '{"walking":false}'
CODE=0; wait "$WAIT_PID" || CODE=$?
OUT="$(cat "$SANDBOX/headless-wait-out")"
check_eq "the direct harness wait delegates to the ACTIONS player" "$CODE" "0"
contains "$OUT" "condition-met condition=not_walking" \
    && ok "and accepts the underscore spelling used in play commands" \
    || fail "and accepts the underscore spelling used in play commands" "$OUT"
snap 1193 '[]' '{"in_combat":true,"opponent":{"x":120,"z":648}}'
fake_retreat_bridge done
CODE=0; OUT="$(DESKCRAB_GAME_PLAYER="$GP" bash "$HEADLESS" retreat 2)" || CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the direct retreat door exits only after observed safety" "$CODE" "0"
contains "$OUT" "retreated status=done" \
    && ok "and reports the verified combat transition" \
    || fail "and reports the verified combat transition" "$OUT"
check_eq "the direct retreat door still uses the shared ACTIONS slot" \
    "$(last_action 'type=retreat')" "1"
refute "the bounded request is cleared after safety" \
    test -f "$DESKCRAB_GAME_STATE_DIR/retreat-request.json"

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
check_eq "xvfb, client, engine, runner and viewer always start through one durable detach door" \
    "$(grep -cE '\$\(detach (xvfb|client|engine|runner|viewer) ' "$HEADLESS")" "6"
check_eq "which is a transient systemd --user unit, not a child of the caller" \
    "$(grep -c 'systemd-run --user' "$HEADLESS")" "1"
check_eq "bare setsid survives only as the explicit no-user-manager fallback" \
    "$(grep -c 'setsid nohup' "$HEADLESS")" "1"
contains "$(sed -n '/^cmd_client()/,/^}/p' "$HEADLESS")" \
    'client restarted but did not publish bridge state' \
    && ok "client-only restart waits through the replacement bridge boot gap" \
    || fail "client-only restart waits through the replacement bridge boot gap"
BOC_REAL="$(readlink -f "$GAME_TREE/headless/betty-openrsc")"
contains "$(sed -n '/^stack_up()/,/^}/p' "$BOC_REAL")" 'for i in $(seq 1 40)' \
    && ok "player resume grants a live client first-snapshot grace" \
    || fail "player resume grants a live client first-snapshot grace"

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
    *MainPID*orsc-engine.service*) cat "$dir/systemd-run-pid" 2>/dev/null || echo 0 ;;
    *MainPID*) echo 0 ;;
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
# Reproduce the live failure: systemd owns a healthy service, but the launcher
# was interrupted before its pid redirection landed. Status must trust the
# manager, and start must repair the record without launching a second unit.
RUN_CALLS="$(wc -l < "$SDFAKE/systemd-run-args")"
rm -f "$SANDBOX/orschome/run/engine.pid"
contains "$(env "${ENGENV[@]}" bash "$HEADLESS" engine status 2>&1)" "pid $EPID (alive)" \
    && ok "engine status recovers a live unit with no process file" \
    || fail "engine status recovers a live unit with no process file"
CODE=0; OUT="$(env "${ENGENV[@]}" bash "$HEADLESS" engine start 2>&1)" || CODE=$?
check_eq "engine start repairs an interrupted process file" "$CODE" "0"
contains "$OUT" "restored its process file" \
    && ok "and names the recovery" || fail "and names the recovery" "$OUT"
check_eq "the recovered pid is recorded" \
    "$(cat "$SANDBOX/orschome/run/engine.pid")" "$EPID"
check_eq "and no duplicate systemd unit was launched" \
    "$(wc -l < "$SDFAKE/systemd-run-args")" "$RUN_CALLS"
contains "$(env "${ENGENV[@]}" bash "$HEADLESS" runner status 2>&1)" "runner  : stopped" \
    && ok "a missing unit's MainPID=0 is never mistaken for a live runner" \
    || fail "a missing unit's MainPID=0 is never mistaken for a live runner"
CODE=0; OUT="$(env "${ENGENV[@]}" bash "$HEADLESS" engine stop 2>&1)" || CODE=$?
check_eq "engine stop tears it down" "$CODE" "0"
refute "and the engine process is gone" sh -c "kill -0 $EPID 2>/dev/null"

echo
echo "the sitting's clock (spec rule 21):"
gp() { python3 "$GP" "$@"; }
# Play is a sitting, not a condition: it runs a bounded time, ordinary
# evaluation stops at the limit so she can wind down by her own hand, and the
# clock is durable so a player restart is not a new sitting.
rm -f "$DESKCRAB_GAME_DIR/session.json"
snap 700 '[{"sidx":9,"id":11,"x":120,"z":648}]'
OUT="$(gp session 2>&1)"; contains "$OUT" "none open" \
    && ok "no session is open until one is opened" \
    || fail "no session is open until one is opened" "$OUT"
# Rule 21: with no session at all the limit binds nothing — it bounds a
# sitting that was opened, never the act of playing.
CODE=0; OUT="$(gp step --max 1 2>&1)" || CODE=$?
refute "with no session open, play is not suppressed" test "$CODE" = 8
gp session open --limit-ms 7200000 --grace-ms 600000 >/dev/null 2>&1
OUT="$(gp session 2>&1)"; contains "$OUT" "120m" \
    && ok "opening a sitting records its limit" \
    || fail "opening a sitting records its limit" "$OUT"
OUT="$(gp session open --limit-ms 60000 2>&1)"
contains "$OUT" "already open" \
    && ok "opening again never restarts a running clock" \
    || fail "opening again never restarts a running clock" "$OUT"
contains "$(gp session 2>&1)" "120m" \
    && ok "so the resume door cannot extend a sitting" \
    || fail "so the resume door cannot extend a sitting"
# Rule 21a: past the limit, ordinary evaluation stops on both hands.
python3 - "$DESKCRAB_GAME_DIR/session.json" <<'PY'
import json, sys, time
p = sys.argv[1]
b = json.load(open(p))
b["started"] = int(time.time() * 1000) - (7200000 + 60000)
json.dump(b, open(p, "w"))
PY
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 701 '[{"sidx":9,"id":11,"x":120,"z":648}]'
CODE=0; OUT="$(gp step --max 1 2>&1)" || CODE=$?
check_eq "past the limit, step reports session-over" "$CODE" "8"
contains "$OUT" "session-over" && ok "naming the verdict" \
    || fail "naming the verdict" "$OUT"
contains "$OUT" "grace_ms_left" && ok "and how much grace is left to wind down in" \
    || fail "and how much grace is left to wind down in" "$OUT"
refute "and no rule took the action slot" test -e "$DESKCRAB_GAME_STATE_DIR/action.json"
# Rule 21b: her hands are not what stops — only the table. And her own
# declaration closes the sitting.
OUT="$(gp session end 2>&1)"; contains "$OUT" "ended" \
    && ok "she can declare the wind-down finished" \
    || fail "she can declare the wind-down finished" "$OUT"
# Rule 21c-i: a CLOSED sitting suppresses exactly as an over-run one does.
# Without this the stop had a hole — the resident runner can outlive it under
# the player's supervisor, and a closed sitting that suppressed nothing left
# the character playing herself unattended.
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 702 '[{"sidx":9,"id":11,"x":120,"z":648}]'
CODE=0; OUT="$(gp step --max 1 2>&1)" || CODE=$?
check_eq "a closed sitting keeps play suppressed, not released" "$CODE" "8"
contains "$OUT" "phase=ended" && ok "naming the closed phase" \
    || fail "naming the closed phase" "$OUT"
refute "so a surviving runner takes no action slot" \
    test -e "$DESKCRAB_GAME_STATE_DIR/action.json"
# Only opening the next sitting lifts it — and a LIVE one refuses to reopen.
gp session open --limit-ms 7200000 --grace-ms 600000 >/dev/null 2>&1
snap 703 '[{"sidx":9,"id":11,"x":120,"z":648}]'
CODE=0; OUT="$(gp step --max 1 2>&1)" || CODE=$?
refute "opening the next sitting lifts the suppression" test "$CODE" = 8
contains "$(gp session open --limit-ms 60000 2>&1)" "already open" \
    && ok "while a live sitting still refuses to be reopened" \
    || fail "while a live sitting still refuses to be reopened"
gp session end >/dev/null 2>&1
# A damaged session file is no session: the clock never invents a deadline.
printf 'not json at all\n' > "$DESKCRAB_GAME_DIR/session.json"
CODE=0; OUT="$(gp step --max 1 2>&1)" || CODE=$?
refute "an unreadable session file suppresses nothing" test "$CODE" = 8
rm -f "$DESKCRAB_GAME_DIR/session.json"

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
check "the player reasoning effort is pinned medium" grep -q 'EFFORT=.*medium' "$BOC"
# Rule 20: the knob's default is the model NAME and the router resolves it, so
# the shipped default is still a real GPT Sol — named once, in committed bytes.
check "the shipped default model is the codex Sol name" \
    grep -qE 'BETTY_OPENRSC_MODEL:-.*OPENRSC_MODEL.*sol' "$BOC"
check "which resolves to a real GPT Sol slug" \
    grep -q 'CODEX_MODEL_SOL:-gpt-5.6-sol' "$BOC"
check "the background author follows the player's model by default" \
    grep -q 'AUTHOR_MODEL="${BETTY_OPENRSC_AUTHOR_MODEL:-$MODEL}"' "$BOC"
check "the background author reasoning effort is pinned medium" \
    grep -q 'AUTHOR_EFFORT=.*medium' "$BOC"
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
check "the author does not turn incidental activity into reflex scope" \
    grep -q 'Treat the outcome.*activity as context, not an automatic scope' "$BOC"
check "the author keeps generic loot activity-agnostic" \
    grep -q 'Generic loot, survival, and idle-movement rules remain activity-agnostic' "$BOC"
check "the game author excludes unrelated Notion and task machinery" \
    grep -q 'Do not query Notion or task' "$BOC"
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
BLOCKED_SHOTS="$(python3 -c 'import json; print(json.dumps({"tool_input":{"command":"/bin/bash -lc '\''./orsc-headless.sh play; rc=$?; ./orsc-headless.sh screenshot >/dev/null; ./orsc-headless.sh screenshot; exit $rc'\''"}}))' \
    | python3 "$SLEEP_HOOK")"
contains "$BLOCKED_SHOTS" '"permissionDecision":"deny"' \
    && ok "the hook denies repeated screenshots used as a fake wait" \
    || fail "the hook denies repeated screenshots used as a fake wait" "$BLOCKED_SHOTS"
contains "$BLOCKED_SHOTS" 'wait-until CONDITION' \
    && ok "the refusal points Sol to the state-based replacement" \
    || fail "the refusal points Sol to the state-based replacement" "$BLOCKED_SHOTS"
ALLOWED_SHOT="$(printf '%s\n' '{"tool_input":{"command":"./orsc-headless.sh screenshot"}}' \
    | python3 "$SLEEP_HOOK")"
check_eq "the hook permits one screenshot for real visual inspection" "$ALLOWED_SHOT" ""
ALLOWED_STATE="$(printf '%s\n' '{"tool_input":{"command":"./orsc-headless.sh play"}}' \
    | python3 "$SLEEP_HOOK")"
check_eq "the hook leaves ACTIONS state commands untouched" "$ALLOWED_STATE" ""
snap 15000 '[]' '{"logged_in":true}'
python3 - "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json" <<'PY'
import json, sys
json.dump({"pending_messages":[{"id":1}],
           "pending_system_messages":[{"id":2,"x":120,"z":648}]},
          open(sys.argv[1], "w"))
PY
BLOCKED_IDLE="$(printf '%s\n' '{"tool_input":{"command":"betty-openrsc recall Discordian"}}' \
    | python3 "$SLEEP_HOOK")"
contains "$BLOCKED_IDLE" 'five-minute standing warning is pending' \
    && ok "the hook makes one-tile movement outrank conversation" \
    || fail "the hook makes one-tile movement outrank conversation" "$BLOCKED_IDLE"
ALLOWED_IDLE_MOVE="$(printf '%s\n' '{"tool_input":{"command":"./orsc-headless.sh walk 121 648"}}' \
    | python3 "$SLEEP_HOOK")"
check_eq "the urgent gate permits the required one-tile move" "$ALLOWED_IDLE_MOVE" ""
ALLOWED_MOVE_WAIT="$(printf '%s\n' '{"tool_input":{"command":"./orsc-headless.sh wait-until not_walking"}}' \
    | python3 "$SLEEP_HOOK")"
check_eq "the urgent gate permits verification of that move" "$ALLOWED_MOVE_WAIT" ""
snap 15001 '[]' '{"logged_in":false}'
BLOCKED_LOGOUT_REPLY="$(printf '%s\n' '{"tool_input":{"command":"./orsc-headless.sh play reply 1 hello"}}' \
    | python3 "$SLEEP_HOOK")"
contains "$BLOCKED_LOGOUT_REPLY" 'Run betty-openrsc login first' \
    && ok "logged out with queued work makes login the prerequisite" \
    || fail "logged out with queued work makes login the prerequisite" "$BLOCKED_LOGOUT_REPLY"
ALLOWED_LOGIN="$(printf '%s\n' '{"tool_input":{"command":"betty-openrsc login"}}' \
    | python3 "$SLEEP_HOOK")"
check_eq "mechanical login is never blocked by its queued reply" "$ALLOWED_LOGIN" ""
rm -f "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json"
check "the player unit carries Restart=always" grep -q 'Restart=always' "$BOC"
check "the player unit refuses accidental manual stops" grep -q 'RefuseManualStop=yes' "$BOC"
check "the explicit operator stop uses a protected control dependency" \
    grep -q 'PartOf=.*CONTROL_UNIT' "$BOC"
check "self-steering is an ordinary command" grep -q '^cmd_steer()' "$BOC"
STEER_FN="$(sed -n '/^cmd_steer()/,/^}/p' "$BOC")"
RESUME_FN="$(sed -n '/^compose_resume_prompt()/,/^}/p' "$BOC")"
check "steering changes only the Sol player process" \
    contains "$STEER_FN" 'systemctl --user kill --kill-whom=all --signal=TERM "$UNIT"'
check "steering is stored beside the writable ACTIONS state" \
    contains "$STEER_FN" '$GDATA/steering.md'
check "the newest self-direction rides every continuation" \
    contains "$RESUME_FN" 'steering_block'
check "phone turns identify themselves to local control doors" \
    grep -q 'DESKCRAB_TURN_ORIGIN=phone' "$REPO/lib/common.sh"
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
check_eq "every mechanical login input bypasses the autonomous conversation gate" \
    "$(sed -n '/^ensure_login()/,/^}/p' "$BOC" | grep -c 'BETTY_OPENRSC_AUTONOMOUS=0.*"\$ORSC"')" "5"
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
# Rules 18-19: her voice comes from a sheet, and what she knows about the
# people standing there comes from her own store. Both are shimmed so the
# suite reads a fixture instead of the installed user's files, and so no real
# embedder is ever asked anything.
SHEET="$SANDBOX/openrsc-persona.md"
printf '## Persona: PERSONA-SHEET-MARKER\n\nShe sounds like herself.\n' > "$SHEET"
MEMFAKE="$SANDBOX/memfake"; mkdir -p "$MEMFAKE"
cat > "$MEMFAKE/memory.py" <<'SH'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf 'CALL' >> "$dir/recall-capture"
for arg in "$@"; do printf '\t%s' "$arg" >> "$dir/recall-capture"; done
printf '\n' >> "$dir/recall-capture"
query=""; scoped=0; prev=""
for arg in "$@"; do
    [ "$prev" = "--query" ] && query="$arg"
    [ "$arg" = "--scope" ] && scoped=1
    prev="$arg"
done
case "$query" in
    *"play knowledge"*)
        printf 'PLAY-QUEST-MEMORY-MARKER\n'
        [ "$scoped" -eq 1 ] || printf 'IRRELEVANT-DESK-LIFE-MARKER\n'
        ;;
    *"nearby players"*) printf 'NEARBY-RELATIONSHIP-MEMORY-MARKER\n' ;;
    *) printf 'REPLY-RECALL-MARKER\n' ;;
esac
SH
chmod +x "$MEMFAKE/memory.py"
# Nearby players ride the composed recall query: the people standing there are
# the people she is about to have to answer.
snap 140 '[{"sidx":9,"id":11,"x":121,"z":649}]' \
     '{"players":[{"name":"Neighbour One"},{"name":"Neighbour Two"}]}'
BOCENV=(BETTY_OPENRSC_HOME="$PH" BETTY_OPENRSC_HEADLESS="$OH2" \
        BETTY_OPENRSC_PERSONA_SHEET="$SHEET" \
        BETTY_OPENRSC_MEMORY="$MEMFAKE/memory.py" \
        CUSTOM_PROMPT="" DESKCRAB_CONF="$SANDBOX/no-such.conf" \
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
contains "$OUT" "unresolved handoff statement" \
    && ok "the continuation makes acknowledged unfinished actions outrank routine play" \
    || fail "the continuation makes acknowledged unfinished actions outrank routine play" "$OUT"
contains "$OUT" "pos=(120,648)" && ok "and a fresh snapshot summary" \
    || fail "and a fresh snapshot summary" "$OUT"

# Rule 18: the player is her, playing. A prompt of pure game mechanics makes a
# stranger wearing her name, which is what shipped before this.
contains "$OUT" "PERSONA-SHEET-MARKER" \
    && ok "her voice rides the composition from the game persona sheet" \
    || fail "her voice rides the composition from the game persona sheet" "$OUT"
# Rule 19: play knowledge is recalled independently of whoever happens to be
# nearby, and relationships ride a separate, smaller section.
contains "$OUT" "PLAY-QUEST-MEMORY-MARKER" \
    && ok "durable play and quest knowledge rides the composed prompt" \
    || fail "durable play and quest knowledge rides the composed prompt" "$OUT"
contains "$OUT" "NEARBY-RELATIONSHIP-MEMORY-MARKER" \
    && ok "nearby-player relationship memory rides separately" \
    || fail "nearby-player relationship memory rides separately" "$OUT"
contains "$OUT" "## OpenRSC play knowledge" \
    && ok "play recall has an explicit prompt section" \
    || fail "play recall has an explicit prompt section" "$OUT"
contains "$OUT" "## People nearby in OpenRSC" \
    && ok "social recall has an explicit prompt section" \
    || fail "social recall has an explicit prompt section" "$OUT"
contains "$OUT" "## Writing what you learn about playing" \
    && ok "the player is explicitly taught that play memories are writable" \
    || fail "the player is explicitly taught that play memories are writable" "$OUT"
contains "$OUT" "betty-openrsc remember" \
    && ok "the composed prompt names the sanctioned memory-write door" \
    || fail "the composed prompt names the sanctioned memory-write door" "$OUT"
refute "irrelevant desk-life recall is not carried into a play prompt" \
    grep -q 'IRRELEVANT-DESK-LIFE-MARKER' <<<"$OUT"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" "recall-block" \
    && ok "composed through the store's own fail-safe recall door" \
    || fail "composed through the store's own fail-safe recall door" \
            "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" "Neighbour One, Neighbour Two" \
    && ok "and asked about the players actually standing nearby" \
    || fail "and asked about the players actually standing nearby" \
            "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" "cooks-two" \
    && ok "and about the goal she is actually pursuing" \
    || fail "and about the goal she is actually pursuing"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" $'--scope\tOpenRSC' \
    && ok "play recall is lexically scoped to OpenRSC" \
    || fail "play recall is lexically scoped to OpenRSC"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" $'--scope\tRuneScape' \
    && ok "play recall also finds RuneScape-tagged memories" \
    || fail "play recall also finds RuneScape-tagged memories"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" $'--max-chars\t6000' \
    && ok "the play-memory section has an explicit character bound" \
    || fail "the play-memory section has an explicit character bound"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" $'--max-chars\t3000' \
    && ok "nearby-player memory has its own smaller bound" \
    || fail "nearby-player memory has its own smaller bound"
# What recall hands back is hers to read, never a script: the world hears
# whatever reaches local chat.
contains "$OUT" "not something to recite" \
    && ok "the composition marks recalled knowledge as read-only, not a script" \
    || fail "the composition marks recalled knowledge as read-only, not a script" "$OUT"

# The reply-time door (rule 19): a query in, her own memory out. It touches no
# action slot and speaks to nobody.
rm -f "$MEMFAKE/recall-capture"
OUT="$(env "${BOCENV[@]}" bash "$BOC" recall "Neighbour One said hello" 2>&1)"
contains "$OUT" "REPLY-RECALL-MARKER" && ok "the recall door answers with her store" \
    || fail "the recall door answers with her store" "$OUT"
contains "$(cat "$MEMFAKE/recall-capture" 2>/dev/null)" "Neighbour One said hello" \
    && ok "asking exactly what the player was told" \
    || fail "asking exactly what the player was told"
refute "and it emits no action into the shared slot" \
    test -e "$DESKCRAB_GAME_STATE_DIR/action.json"

# The narrow write door creates a tagged, deduplicated game note through the
# store's own command. It never writes the game action slot.
rm -f "$MEMFAKE/recall-capture"
OUT="$(env "${BOCENV[@]}" bash "$BOC" remember \
    "Captain Rovin is upstairs in Varrock Castle for Demon Slayer." 2>&1)"
CAPTURED="$(cat "$MEMFAKE/recall-capture" 2>/dev/null)"
contains "$CAPTURED" $'CALL\tadd\t--kind\tnote' \
    && ok "the remember door writes a note through memory.py" \
    || fail "the remember door writes a note through memory.py" "$CAPTURED"
contains "$CAPTURED" $'--source\topenrsc-player' \
    && ok "the durable lesson carries its OpenRSC player source" \
    || fail "the durable lesson carries its OpenRSC player source" "$CAPTURED"
contains "$CAPTURED" $'--topics\tRuneScape, OpenRSC, cooks-two' \
    && ok "the durable lesson is tagged to play and the current objective" \
    || fail "the durable lesson is tagged to play and the current objective" "$CAPTURED"
contains "$CAPTURED" "Captain Rovin is upstairs" \
    && ok "the verified lesson crosses the write door whole" \
    || fail "the verified lesson crosses the write door whole" "$CAPTURED"
refute "remembering consumes no game action slot" \
    test -e "$DESKCRAB_GAME_STATE_DIR/action.json"
CODE=0; env "${BOCENV[@]}" bash "$BOC" remember >/dev/null 2>&1 || CODE=$?
check_eq "an empty play memory is refused" "$CODE" "1"

# An empty room still recalls play knowledge; it simply does not spend a
# second retrieval on absent relationships.
rm -f "$MEMFAKE/recall-capture"
snap 141 '[{"sidx":9,"id":11,"x":121,"z":649}]' '{"players":[]}'
OUT="$(env "${BOCENV[@]}" bash "$BOC" prompt 2>&1)"
contains "$OUT" "PLAY-QUEST-MEMORY-MARKER" \
    && ok "play knowledge is recalled even with nobody nearby" \
    || fail "play knowledge is recalled even with nobody nearby" "$OUT"
refute "an empty room does not invent a nearby-people memory section" \
    grep -q 'People nearby in OpenRSC' <<<"$OUT"
check_eq "an empty room performs only the play-scoped retrieval" \
    "$(grep -c '^CALL' "$MEMFAKE/recall-capture" 2>/dev/null || true)" "1"

# Fail-safe by memory-recall.md's contract, and rule 18's bound: a missing
# store or an oversized sheet degrades the prompt, never breaks it.
OUT="$(env "${BOCENV[@]}" BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory.py" \
       bash "$BOC" prompt 2>&1)"
contains "$OUT" "BASE-PROMPT-MARKER" \
    && ok "an unreachable store still composes a whole prompt" \
    || fail "an unreachable store still composes a whole prompt" "$OUT"
refute "with no recall block invented in its place" \
    grep -q 'PLAY-QUEST-MEMORY-MARKER' <<<"$OUT"
BIGSHEET="$SANDBOX/oversized-persona.md"
head -c 70000 /dev/zero | tr '\0' 'x' > "$BIGSHEET"
OUT="$(env "${BOCENV[@]}" BETTY_OPENRSC_PERSONA_SHEET="$BIGSHEET" \
       bash "$BOC" prompt 2>&1)"
contains "$OUT" "BASE-PROMPT-MARKER" \
    && ok "an oversized sheet is treated as absent rather than failing the start" \
    || fail "an oversized sheet is treated as absent rather than failing the start" "$OUT"
refute "and none of its bytes reach the prompt" grep -q 'xxxxxxxxxx' <<<"$OUT"

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
grep -q 'RefuseManualStop=yes' "$PSD/systemd-run-args" 2>/dev/null \
    && ok "and accidental manual stops refused" || fail "and accidental manual stops refused"
for i in $(seq 1 50); do [ -s "$PH/player-thread" ] && break; sleep 0.1; done
contains "$(cat "$PSD/codex-capture" 2>/dev/null)" "step 7 of 9" \
    && ok "the first player received the composed prompt, handoff included" \
    || fail "the first player received the composed prompt, handoff included"
contains "$(cat "$PSD/codex-capture" 2>/dev/null)" "gpt-5.6-sol" \
    && ok "and was invoked pinned to GPT Sol" \
    || fail "and was invoked pinned to GPT Sol"
contains "$(cat "$PSD/codex-capture" 2>/dev/null)" "model_reasoning_effort=medium" \
    && ok "at the pinned medium reasoning effort" \
    || fail "at the pinned medium reasoning effort"
printf 'goal: NEW-GOAL; step 8 of 9; next: buy the pot\n' > "$PH/handoff.md"
printf 'resume-target\n' > "$DESKCRAB_GAME_DIR/objective"
printf 'Stop circling the village; continue south to the tower.\n' > "$DESKCRAB_GAME_DIR/steering.md"
env "${POCENV[@]}" bash "$BOC" run-player </dev/null >/dev/null 2>&1 || true
check_eq "the first run captured its durable Codex thread id" \
    "$(cat "$PH/player-thread" 2>/dev/null)" "11111111-2222-3333-4444-555555555555"
check_eq "the restarted process used Codex resume exactly once" \
    "$(grep -c '^resume$' "$PSD/codex-capture" 2>/dev/null)" "1"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "resume-target" \
    && ok "the resumed thread receives current objective and snapshot facts" \
    || fail "the resumed thread receives current objective and snapshot facts"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" \
    "Stop circling the village; continue south to the tower." \
    && ok "the resumed thread receives the assistant's newest self-steering direction" \
    || fail "the resumed thread receives the assistant's newest self-steering direction"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "entity KIND TYPE-ID" \
    && ok "the resumed thread receives the identity-targeting ability" \
    || fail "the resumed thread receives the identity-targeting ability"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "inventory ITEM-ID" \
    && ok "the resumed thread receives inventory identity targeting" \
    || fail "the resumed thread receives inventory identity targeting"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "system-message with action=move-required" \
    && ok "the resumed thread receives the urgent idle-warning action" \
    || fail "the resumed thread receives the urgent idle-warning action"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "wait-until with exactly one named state" \
    && ok "the resumed thread receives the state-based wait replacement" \
    || fail "the resumed thread receives the state-based wait replacement"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "wait for not_walking directly" \
    && ok "the resumed thread avoids a redundant walking transition wait" \
    || fail "the resumed thread avoids a redundant walking transition wait"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "orsc-headless.sh retreat once" \
    && ok "the resumed thread receives the verified retreat loop" \
    || fail "the resumed thread receives the verified retreat loop"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "failed command sequence is evidence" \
    && ok "the resumed thread must resolve and retain failed strategies" \
    || fail "the resumed thread must resolve and retain failed strategies"
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

# Rule 18a: the sheet is versioned into the thread. A conversation opened
# before the current voice existed is the wrong one to continue, so an edited
# sheet composes fresh instead of resuming a player who never heard it.
contains "$(cat "$PH/player-persona-id" 2>/dev/null)" "codex/" \
    && ok "the thread records the voice, engine and model it was opened with" \
    || fail "the thread records the voice, engine and model it was opened with" \
            "$(cat "$PH/player-persona-id" 2>/dev/null)"
printf '## Persona: EDITED-SHEET-MARKER\n\nShe sounds like herself, revised.\n' > "$SHEET"
env "${POCENV[@]}" bash "$BOC" run-player </dev/null >/dev/null 2>&1 || true
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "EDITED-SHEET-MARKER" \
    && ok "an edited sheet composes a fresh player carrying the new voice" \
    || fail "an edited sheet composes a fresh player carrying the new voice" \
            "$(cat "$PH/run-prompt.txt" 2>/dev/null)"
contains "$(cat "$PH/run-prompt.txt" 2>/dev/null)" "BASE-PROMPT-MARKER" \
    && ok "which is a whole new thread, standing prompt included" \
    || fail "which is a whole new thread, standing prompt included"
check_eq "and no second resume was attempted against the stale thread" \
    "$(grep -c '^resume$' "$PSD/codex-capture" 2>/dev/null)" "1"
# An unchanged sheet must NOT churn the thread — only a real edit does.
env "${POCENV[@]}" bash "$BOC" run-player </dev/null >/dev/null 2>&1 || true
check_eq "an unchanged sheet resumes the same conversation as before" \
    "$(grep -c '^resume$' "$PSD/codex-capture" 2>/dev/null)" "2"

# Rule 21b: LOGGING OUT IS HERS AND COMES FIRST. Ending a sitting takes the
# reflex guards down, so the door refuses while the snapshot still says she is
# in the world — a character left standing there without them dies idle. This
# refusal is the whole teaching; documentation once implied the stop handled
# the logout and a sitting ended with her still logged in.
snap 800 '[]'   # snap() writes a logged_in snapshot
CODE=0; OUT="$(env "${BOCENV[@]}" bash "$BOC" session-end 2>&1)" || CODE=$?
[ "$CODE" -ne 0 ] && ok "session-end refuses while she is still logged in" \
    || fail "session-end must refuse while she is still logged in" "$OUT"
contains "$OUT" "STILL LOGGED IN" \
    && ok "and says so in as many words" || fail "and says so in as many words" "$OUT"
contains "$OUT" "does not log you out" \
    && ok "naming plainly that nothing here logs her out" \
    || fail "naming plainly that nothing here logs her out" "$OUT"
refute "and the refusal closes no sitting" \
    grep -q '"ended"' "$DESKCRAB_GAME_DIR/session.json"
# The grace timer has nobody to tell, so its path proceeds — and the arming
# call must actually use it.
contains "$(sed -n '/^session_open()/,/^}/p' "$BOC")" 'session-end --force' \
    && ok "the grace timer is armed on the forced path" \
    || fail "the grace timer is armed on the forced path"
contains "$(sed -n '/^cmd_session_end()/,/^}/p' "$BOC")" 'stop orsc-client.service' \
    && ok "which disconnects her rather than leaving her unguarded" \
    || fail "which disconnects her rather than leaving her unguarded"
# Rule 21c: the player goes down FIRST and is confirmed down, because its
# supervisor block raises the engine and runner on every start.
SEBODY="$(sed -n '/^cmd_session_end()/,/^}/p' "$BOC")"
PLAYER_AT="$(printf '%s\n' "$SEBODY" | grep -n 'stop "$CONTROL_UNIT"' | head -1 | cut -d: -f1)"
RUNNER_AT="$(printf '%s\n' "$SEBODY" | grep -n 'runner stop' | head -1 | cut -d: -f1)"
ENGINE_AT="$(printf '%s\n' "$SEBODY" | grep -n 'engine stop' | head -1 | cut -d: -f1)"
[ -n "$PLAYER_AT" ] && [ -n "$RUNNER_AT" ] && [ "$PLAYER_AT" -lt "$RUNNER_AT" ] \
    && ok "the player is stopped before the runner it would otherwise re-raise" \
    || fail "the player is stopped before the runner it would otherwise re-raise"
[ -n "$ENGINE_AT" ] && [ "$RUNNER_AT" -lt "$ENGINE_AT" ] \
    && ok "and the reflex guards come down last of all" \
    || fail "and the reflex guards come down last of all"

# Rule 20: the engine follows the model name, so moving the player between
# engines is one word — and the same word moves it back. A fake Claude CLI
# records its invocation the way the fake codex does.
# Rule 20c makes the guard a start condition on BOTH engines, so the sandbox
# harness dir must carry it exactly as the real one does.
cp "$GAME_TREE/headless/no-sleep-hook.py" "$OH2/no-sleep-hook.py"
CODEX_RUNS_BEFORE="$(grep -c -- '----8<----' "$PSD/codex-capture" 2>/dev/null || echo 0)"
cat > "$PSD/fakeclaude" <<'SH'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$@" >> "$dir/claude-capture"
printf -- '----8<----\n' >> "$dir/claude-capture"
cat > "$dir/claude-stdin"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}'
exit 0
SH
chmod +x "$PSD/fakeclaude"
CLENV=("${POCENV[@]}" BETTY_OPENRSC_MODEL=opus BETTY_OPENRSC_CLAUDE="$PSD/fakeclaude" \
       BETTY_OPENRSC_DESKCRAB_LIB="$REPO/lib" BETTY_OPENRSC_DESKCRAB_DATA="$SANDBOX/dcdata")
mkdir -p "$SANDBOX/dcdata"
env "${CLENV[@]}" bash "$BOC" run-player </dev/null >/dev/null 2>&1 || true
CLCAP="$(cat "$PSD/claude-capture" 2>/dev/null)"
contains "$CLCAP" "--model" && contains "$CLCAP" "opus" \
    && ok "a Claude model name routes the player to the Claude CLI" \
    || fail "a Claude model name routes the player to the Claude CLI" "$CLCAP"
refute "and never hands that name to the codex door" \
    grep -q '^opus$' "$PSD/codex-capture"
# Rule 20a: a codex thread id means nothing here, so the engine change opens a
# fresh conversation instead of offering an id the CLI cannot answer for.
refute "an engine change does not try to resume the other engine's thread" \
    grep -q -- '--resume' <<<"$CLCAP"
contains "$(cat "$PSD/claude-stdin" 2>/dev/null)" "BASE-PROMPT-MARKER" \
    && ok "the engine change composes a whole fresh prompt" \
    || fail "the engine change composes a whole fresh prompt"
check_eq "and the new engine's own session id becomes the durable thread" \
    "$(cat "$PH/player-thread" 2>/dev/null)" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
# Rule 20c: none of the user's own Claude configuration, and rule 14's guard
# carried as a settings document rather than dropped on the way across.
contains "$CLCAP" "--setting-sources" \
    && ok "her session loads none of the user's own Claude settings sources" \
    || fail "her session loads none of the user's own Claude settings sources" "$CLCAP"
contains "$CLCAP" "--strict-mcp-config" \
    && ok "and no MCP servers beyond the empty config" \
    || fail "and no MCP servers beyond the empty config"
contains "$CLCAP" "no-sleep-hook.py" \
    && ok "rule 14's no-sleep guard rides the Claude engine too" \
    || fail "rule 14's no-sleep guard rides the Claude engine too" "$CLCAP"
# And back again: the same word returns her to the engine she came from.
env "${POCENV[@]}" bash "$BOC" run-player </dev/null >/dev/null 2>&1 || true
check_eq "naming the codex model again returns the player to that engine" \
    "$(grep -c -- '----8<----' "$PSD/codex-capture" 2>/dev/null)" \
    "$((CODEX_RUNS_BEFORE + 1))"
refute "without resuming the Claude session id it cannot answer for" \
    grep -q 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' "$PH/run-prompt.txt"
rm -f "$PSD/systemctl-stops"
CODE=0; OUT="$(env "${POCENV[@]}" DESKCRAB_TURN_ORIGIN=phone bash "$BOC" stop player 2>&1)" || CODE=$?
[ "$CODE" -ne 0 ] && ok "a phone turn cannot stop the playing arm" \
    || fail "a phone turn must not be allowed to stop the playing arm" "$OUT"
refute "the refused phone stop never reaches systemd" test -e "$PSD/systemctl-stops"
env "${POCENV[@]}" bash "$BOC" stop player >/dev/null 2>&1 || true
grep -q 'stop orsc-player-control.service' "$PSD/systemctl-stops" 2>/dev/null \
    && ok "stop player goes through the unit door" \
    || fail "stop player goes through the unit door" \
            "$(cat "$PSD/systemctl-stops" 2>/dev/null)"
fi

echo
echo "incoming messages settle into bursts and choose the live reply channel (rule 7b):"
snap 145 '[]' '{"players":[{"sidx":11,"name":"Nearby Friend","x":121,"z":648}],"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the first message opens the settle window: exit 3" "$CODE" "3"
contains "$OUT" "player-message-settling count=1" \
    && ok "ACTIONS blocks play without waking Sol on a partial chain" \
    || fail "the partial chain is reported as settling" "$OUT"
python3 - "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s['message_settle_until'] = 1
json.dump(s, open(sys.argv[1], 'w'))
PY
DEADLINE1=1
snap 1451 '[]' '{"players":[{"sidx":11,"name":"Nearby Friend","x":121,"z":648}],"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east"},
    {"id":9002,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"door by the mill"},
    {"id":9003,"channel":"private","incoming":true,"sender":"Far Friend","text":"I can help from here"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "additional messages remain model-free while the burst settles" "$CODE" "3"
DEADLINE2="$(python3 -c "import json; print(json.load(open('$DESKCRAB_GAME_STATE_DIR/player-engine-state.json'))['message_settle_until'])")"
[ "$DEADLINE2" -gt "$DEADLINE1" ] \
    && ok "a later message extends the five-second deadline" \
    || fail "a later message must extend the five-second deadline" "$DEADLINE1 -> $DEADLINE2"
python3 - "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s['message_settle_until'] = 0
json.dump(s, open(sys.argv[1], 'w'))
PY
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the settled oldest conversation becomes the priority verdict: exit 6" "$CODE" "6"
contains "$OUT" "id=9002 channel=local sender=Nearby Friend count=2" \
    && contains "$OUT" 'Try the east' && contains "$OUT" 'door by the mill' \
    && ok "Sol receives the whole local message chain under its newest id" \
    || fail "the settled verdict must carry the whole local chain" "$OUT"
refute "observing a message burst emits no action before Sol writes the reply" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 1452 '[]' '{"logged_in":false}'
CODE=0; OUT="$(python3 "$GP" reply 9002 premature)" || CODE=$?
check_eq "a logged-out reply names login as its prerequisite: exit 3" "$CODE" "3"
contains "$OUT" "reply-needs-login message_id=9002 next=betty-openrsc-login pending=preserved" \
    && ok "logout cannot consume or obscure the queued reply" \
    || fail "logout cannot consume or obscure the queued reply" "$OUT"
check_eq "the pending conversation survives logout" \
    "$(sandbox_count_in '"id":[[:space:]]*9002' "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json")" "1"
snap 1453 '[]' '{"players":[{"sidx":11,"name":"Nearby Friend","x":121,"z":648}],"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east"},
    {"id":9002,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"door by the mill"},
    {"id":9100,"channel":"game","incoming":false,"sender":"","text":"You have been standing here for 5 mins! Please move to a new area"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the idle warning outranks the already-pending conversation" "$CODE" "7"
CODE=0; OUT="$(python3 "$GP" reply 9002 premature)" || CODE=$?
check_eq "a direct reply cannot race past the one-tile interrupt: exit 7" "$CODE" "7"
contains "$OUT" "reply-needs-movement message_id=9002" \
    && ok "the reply door preserves the message and orders the move" \
    || fail "the reply door preserves the message and orders the move" "$OUT"
refute "the blocked reply emits no chat action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 1454 '[]' '{"x":121,"z":648,"players":[{"sidx":11,"name":"Nearby Friend","x":121,"z":648}],"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east"},
    {"id":9002,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"door by the mill"},
    {"id":9100,"channel":"game","incoming":false,"sender":"","text":"You have been standing here for 5 mins! Please move to a new area"}
]}'
fake_bridge done
OUT="$(python3 "$GP" reply 9002 Thanks, I will try that)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a receipted nearby reply exits 0" "$CODE" "0"
check_eq "a still-visible local sender is answered locally" "$(last_action 'type=chat-local')" "1"
check_eq "and preserved Sol's text" "$(last_action 'text=Thanks, I will try that')" "1"
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the private conversation is next, still before ordinary rules" "$CODE" "6"
contains "$OUT" "id=9003 channel=private sender=Far Friend count=1" \
    && ok "the private sender and channel remain structured" \
    || fail "the private sender and channel remain structured" "$OUT"
fake_bridge done
OUT="$(python3 "$GP" reply 9003 I got your private message)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a receipted private reply exits 0" "$CODE" "0"
check_eq "the reply used chat-private" "$(last_action 'type=chat-private')" "1"
check_eq "and addressed the original sender at any distance" "$(last_action 'target=Far Friend')" "1"

snap 14515 '[]' '{"players":[],"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east"},
    {"id":9002,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"door by the mill"},
    {"id":9003,"channel":"private","incoming":true,"sender":"Far Friend","text":"I can help from here"},
    {"id":90035,"channel":"private","incoming":true,"sender":"Far Friend","text":"When?"}
]}'
python3 "$GP" step --local >/dev/null 2>&1 || true
python3 - "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s['message_settle_until'] = 0
json.dump(s, open(sys.argv[1], 'w'))
PY
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the punctuation-normalized private message becomes actionable" "$CODE" "6"
fake_bridge done-normalized
OUT="$(python3 "$GP" reply 90035 'Two minutes ago, by PM.')"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "a Classic-normalized outgoing echo confirms without a retry" "$CODE" "0"
contains "$OUT" "status=done" \
    && ok "punctuation and capitalization normalization is still grounded in the echo" \
    || fail "the normalized echo should prove delivery" "$OUT"

snap 1452 '[]' '{"players":[],"messages":[
    {"id":9004,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Are you still there?"}
]}'
python3 "$GP" step --local >/dev/null 2>&1 || true
python3 - "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s['message_settle_until'] = 0
json.dump(s, open(sys.argv[1], 'w'))
PY
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the departed local sender still receives a reply verdict" "$CODE" "6"
fake_bridge done
OUT="$(python3 "$GP" reply 9004 Yes, by private message now)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the fallback private reply exits 0" "$CODE" "0"
check_eq "a local sender no longer visible is answered privately" "$(last_action 'type=chat-private')" "1"
check_eq "the private fallback retains the original sender" "$(last_action 'target=Nearby Friend')" "1"
contains "$OUT" "reply_channel=private" \
    && ok "the reply verdict makes the channel switch explicit" \
    || fail "the reply verdict should name the private fallback" "$OUT"

snap 146 '[]' '{"messages":[
    {"id":9001,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Try the east"},
    {"id":9002,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"door by the mill"},
    {"id":9003,"channel":"private","incoming":true,"sender":"Far Friend","text":"I can help from here"},
    {"id":9004,"channel":"local","incoming":true,"sender":"Nearby Friend","text":"Are you still there?"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "handled ids are not re-added from later snapshots" "$CODE" "4"
grep -q '"kind":"player-message-received"' "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl" \
    && grep -q '"kind":"player-message-reply"' "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl" \
    && ok "observation and replies stay in the existing player decision log" \
    || fail "observation and replies stay in the existing player decision log"

echo
echo "the standing-still system warning blocks everything except movement (rule 7c):"
SYSTEM0="$(decided system-message-received)"
snap 147 '[]' '{"messages":[
    {"id":9200,"channel":"game","incoming":false,"sender":"","text":"You have been standing here for 5 mins! Please move to a new area"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the blue idle warning is the priority verdict: exit 7" "$CODE" "7"
contains "$OUT" "action=move-required" \
    && ok "the verdict gives Sol one immediate job" \
    || fail "the verdict gives Sol one immediate job" "$OUT"
check_eq "the system warning is captured once in ACTIONS state" \
    "$(( $(decided system-message-received) - SYSTEM0 ))" "1"
python3 - "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["pending_messages"] = [{"id": 9201, "channel": "private", "sender": "Friend",
                          "text": "Are you there?", "captured_ts": 1}]
json.dump(s, open(p, "w"))
PY
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
CODE=0; OUT="$(BETTY_OPENRSC_AUTONOMOUS=1 bash "$HEADLESS" inventory 376 2 2>&1)" || CODE=$?
check_eq "a non-walk action is refused while movement is urgent" "$CODE" "7"
contains "$OUT" "move before any other play" \
    && ok "the refusal points to the receipted walk door" \
    || fail "the refusal points to the receipted walk door" "$OUT"
refute "the refused inventory click emitted no action" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
fake_bridge done
OUT="$(BETTY_OPENRSC_AUTONOMOUS=1 bash "$HEADLESS" walk 121 648)"; CODE=$?
wait "$FAKE_BRIDGE_PID"
check_eq "the urgent gate permits a receipted walk" "$CODE" "0"
check_eq "and the shared action is a walk" "$(last_action 'type=walk')" "1"
python3 - "$DESKCRAB_GAME_STATE_DIR/player-engine-state.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p))
s["pending_messages"] = []
json.dump(s, open(p, "w"))
PY
snap 148 '[]' '{"x":121,"z":648,"messages":[
    {"id":9200,"channel":"game","incoming":false,"sender":"","text":"You have been standing here for 5 mins! Please move to a new area"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "a changed snapshot tile clears the warning and resumes play" "$CODE" "4"
check_eq "the old warning is not duplicated from the still-visible message" \
    "$(( $(decided system-message-received) - SYSTEM0 ))" "1"
grep -q '"kind":"system-message-handled"' "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl" \
    && ok "the movement proof is recorded in the existing decision log" \
    || fail "the movement proof is recorded in the existing decision log"
snap 149 '[]' '{"messages":[
    {"id":9202,"channel":"game","incoming":false,"sender":"","text":"You do not have enough coins"}
]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "ordinary system feedback does not create a second interrupt" "$CODE" "4"
contains "$OUT" "feedback=You do not have enough coins" \
    && ok "but the ACTIONS verdict carries it into Sol's next decision" \
    || fail "but the ACTIONS verdict carries it into Sol's next decision" "$OUT"

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
snap 160 '[]' '{"ground_items":[{"id":27,"x":121,"z":649}]}'
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
contains "$OUT" "ground_items=27" \
    && ok "the deferred fallback still exposes visible pickups" \
    || fail "the deferred fallback still exposes visible pickups" "$OUT"
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
