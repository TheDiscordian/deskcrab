#!/bin/bash
# A live resident routine owns semantic actions across the temporary states
# between its triggers. Direct hands may act only when no enabled in-scope
# routine reserves the same action identity.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

python3 - "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR" "$$" <<'PY'
import json, os, sys, time
state_dir, game_dir, owner_pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
open(os.path.join(game_dir, "objective"), "w").write("one-goal\n")
open(os.path.join(game_dir, "activity"), "w").write("one-method\n")
table = {
    "v": 1,
    "defaults": {"stale_ms": 2000, "min_action_interval_ms": 0,
                 "max_actions_per_min": 0, "inflight_timeout_ms": 3000},
    "rules": [
        {"name": "repeat-one-npc-method", "enabled": True,
         "priority": 40, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"objective_is": "one-goal", "activity_is": "one-method",
                     "npc_visible": [63, 86], "out_of_combat": True},
         "action": {"type": "interact-npc", "npc": [63, 86], "cmd": 1}},
        {"name": "break-provoked-combat", "enabled": True,
         "priority": 1000, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"objective_is": "one-goal", "activity_is": "one-method",
                     "in_combat": True, "opponent_rounds_at_least": 3},
         "action": {"type": "sidestep", "dx": 0, "dz": 1}},
        {"name": "different-method", "enabled": True,
         "priority": 40, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"objective_is": "one-goal", "activity_is": "elsewhere",
                     "npc_visible": 99},
         "action": {"type": "interact-npc", "npc": 99, "cmd": 1}},
    ],
    "unfinished": [],
}
json.dump(table, open(os.path.join(game_dir, "learned-rules.json"), "w"))
json.dump({"pid": owner_pid, "ts": int(time.time() * 1000),
           "verdict": "fired"},
          open(os.path.join(state_dir, "player-runner.json"), "w"))
PY

check "the routine reserves a retargeted NPC action while its transient guard is false" \
    sh -c "python3 '$GP' direct-owner interact-npc --param npc=86 --param cmd=1 | grep -q 'routine-owned.*next=play'"
refute "an unrelated target is not captured by a target-specific routine" \
    python3 "$GP" direct-owner interact-npc --param npc=87 --param cmd=1
check "the public retreat intent is owned by either learned escape executor" \
    sh -c "python3 '$GP' direct-owner retreat | grep -q 'rules=break-provoked-combat'"
refute "an enabled rule in a different activity does not reserve the direct hand" \
    python3 "$GP" direct-owner interact-npc --param npc=99 --param cmd=1

python3 - "$DESKCRAB_GAME_STATE_DIR/player-runner.json" <<'PY'
import json, sys, time
json.dump({"pid": 999999999, "ts": int(time.time() * 1000),
           "verdict": "fired"}, open(sys.argv[1], "w"))
PY
refute "a dead resident runner never blocks direct control" \
    python3 "$GP" direct-owner interact-npc --param npc=86 --param cmd=1

# Spec rule 12's scope proofs: a fresh snapshot proving a take-ground request
# outside a rule's own declared scope releases that rule alone; everything
# unprovable keeps the capture.
write_take_fixture() { # INVENTORY-JSON PILE-X SNAP-AGE-MS
    python3 - "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR" "$$" "$1" "$2" "$3" <<'PY'
import json, os, sys, time
state_dir, game_dir, owner_pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
inventory, pile_x, age_ms = json.loads(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
now = int(time.time() * 1000)
table = {
    "v": 1,
    "defaults": {"stale_ms": 2000, "min_action_interval_ms": 0,
                 "max_actions_per_min": 0, "inflight_timeout_ms": 3000},
    "rules": [
        {"name": "stack-only-loot", "enabled": True,
         "priority": 40, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"ground_item_visible": 500, "out_of_combat": True,
                     "inventory_has": 500},
         "action": {"type": "take-ground", "item": 500}},
        {"name": "local-initial-loot", "enabled": True,
         "priority": 40, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"ground_item_visible": 500, "out_of_combat": True,
                     "inventory_lacks": 500},
         "action": {"type": "take-ground", "item": 500, "within": 1}},
        {"name": "prerequisite-tool-loot", "enabled": True,
         "priority": 40, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"ground_item_visible": 600, "inventory_has": 42},
         "action": {"type": "take-ground", "item": 600}},
    ],
    "unfinished": [],
}
json.dump(table, open(os.path.join(game_dir, "learned-rules.json"), "w"))
json.dump({"pid": owner_pid, "ts": now, "verdict": "fired"},
          open(os.path.join(state_dir, "player-runner.json"), "w"))
snap = {"ts": now - age_ms, "tick": 7000, "logged_in": True, "x": 10, "z": 10,
        "in_combat": False, "inventory": inventory,
        "ground_items": [{"id": 500, "x": pile_x, "z": 10, "reachable": True},
                         {"id": 600, "x": 11, "z": 10, "reachable": True}]}
json.dump(snap, open(os.path.join(state_dir, "state.json"), "w"))
PY
}

write_take_fixture '[]' 12 0
refute "an unheld stack guard and an out-of-cap pile release the direct take" \
    python3 "$GP" direct-owner take-ground --param item=500
check "the release is one recorded direct-scope-release decision event" \
    sh -c "grep -q '\"kind\":\"direct-scope-release\"' '$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl' \
        && grep -q 'stack-only-guard-item-unheld' '$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl' \
        && grep -q 'all-visible-piles-beyond-within' '$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl'"
check "a guard on a different item than the take acquires keeps the capture" \
    sh -c "python3 '$GP' direct-owner take-ground --param item=600 | grep -q 'rules=prerequisite-tool-loot'"

write_take_fixture '[]' 11 0
check "a matching pile inside the locality cap keeps the capture" \
    sh -c "python3 '$GP' direct-owner take-ground --param item=500 | grep -q 'rules=local-initial-loot'"

write_take_fixture '[{"id": 500, "count": 3}]' 12 0
check "a held stack returns the distant take to the stock-extension routine" \
    sh -c "python3 '$GP' direct-owner take-ground --param item=500 | grep -q 'rules=stack-only-loot'"

write_take_fixture '[]' 12 10000
check "a stale snapshot proves nothing and the whole capture stands" \
    sh -c "python3 '$GP' direct-owner take-ground --param item=500 | grep -q 'rules=local-initial-loot,stack-only-loot'"

# Spec rule 15: the reservation belongs to the table the runner is ENFORCING.
# A refused reload keeps an older table, so a rule the live runner never
# loaded owns nothing — citing it would reserve an action nobody can perform.
write_enforced_fixture() { # ENFORCED-RULES-JSON TABLE-ERROR
    python3 - "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR" "$$" "$1" "$2" <<'PY'
import json, os, sys, time
state_dir, game_dir, owner_pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
enforced, table_error = json.loads(sys.argv[4]), sys.argv[5]
table = {
    "v": 1,
    "defaults": {"stale_ms": 2000, "min_action_interval_ms": 0,
                 "max_actions_per_min": 0, "inflight_timeout_ms": 3000},
    "rules": [
        {"name": "chop-visible-tree", "enabled": True,
         "priority": 40, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"object_visible": 1, "out_of_combat": True},
         "action": {"type": "interact-object", "obj": 1, "cmd": 1}},
    ],
    "unfinished": [],
}
json.dump(table, open(os.path.join(game_dir, "learned-rules.json"), "w"))
open(os.path.join(game_dir, "objective"), "w").write("\n")
open(os.path.join(game_dir, "activity"), "w").write("\n")
heartbeat = {"pid": owner_pid, "ts": int(time.time() * 1000),
             "verdict": "no-rule-matched",
             "table_error": table_error or None}
if enforced is not None:
    heartbeat["enforced_rules"] = enforced
json.dump(heartbeat, open(os.path.join(state_dir, "player-runner.json"), "w"))
PY
}

write_enforced_fixture '["chop-visible-tree"]' ''
check "a rule the live runner is enforcing still reserves its action" \
    sh -c "python3 '$GP' direct-owner interact-object --param obj=1 --param cmd=1 \
        | grep -q 'rules=chop-visible-tree'"

write_enforced_fixture '["some-older-rule"]' "rule 'chop-visible-tree': unknown trigger 'fatigue_at_least'"
refute "a rule the runner never loaded cannot reserve the direct hand" \
    python3 "$GP" direct-owner interact-object --param obj=1 --param cmd=1
check "that release is one recorded direct-unenforced-release naming the rule" \
    sh -c "grep -q '\"kind\":\"direct-unenforced-release\"' '$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl' \
        && grep -q 'chop-visible-tree' '$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl'"
check "the refused table is named above the rules listing" \
    sh -c "python3 '$GP' rules | grep -q \"REFUSED this table\""
check "the rules listing names what the live runner is not enforcing" \
    sh -c "python3 '$GP' rules | grep -q 'not enforced by the live runner: chop-visible-tree'"

write_enforced_fixture 'null' ''
check "an older heartbeat without enforced_rules keeps the capture" \
    sh -c "python3 '$GP' direct-owner interact-object --param obj=1 --param cmd=1 \
        | grep -q 'rules=chop-visible-tree'"
