#!/bin/bash
# An explicit inventory batch is initiated by its ordinary trigger once, then
# owns the all-items postcondition across later runner passes. Every member is
# one atomic client click and must be observed reducing the selected item.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

python3 - "$GP" <<'PY' \
    && ok "batch=all persists past its initiation threshold and observes every atomic item decrease" \
    || fail "the inventory batch must consume all matching items after one threshold match"
import importlib.util, json, os, sys, threading, time

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

state_dir = os.environ["DESKCRAB_GAME_STATE_DIR"]
game_dir = os.environ["DESKCRAB_GAME_DIR"]
open(os.path.join(game_dir, "objective"), "w").write("inventory-test\n")
open(os.path.join(game_dir, "activity"), "w").write("thieving\n")
open(os.path.join(game_dir, "food-heals.xml"), "w").write("<map/>\n")

rule = {
    "name": "clear-item-batch", "enabled": True,
    "priority": 850, "cooldown_ms": 0, "hold_ticks": 1,
    "trigger": {"objective_is": "inventory-test", "activity_is": "thieving",
                "inventory_has": 20, "inventory_slots_at_least": 28,
                "out_of_combat": True, "fatigue_below": 100},
    "action": {"type": "click-inventory", "item": 20,
               "button": 1, "batch": "all"},
}
table = {
    "v": 1,
    "defaults": {"stale_ms": 2000, "min_action_interval_ms": 0,
                 "max_actions_per_min": 0, "inflight_timeout_ms": 3000},
    "rules": [rule], "unfinished": [],
}
gp.validate_config(table)
json.dump(table, open(os.path.join(game_dir, "learned-rules.json"), "w"))

inventory = ([{"id": 20, "name": "Bones", "count": 1} for _ in range(3)]
             + [{"id": 1000 + i, "count": 1} for i in range(25)])
snapshot = {
    "v": 1, "ts": gp.now_ms(), "tick": 100, "logged_in": True,
    "walking": False, "in_combat": False, "x": 100, "z": 100,
    "hits": 20, "hits_max": 20, "fatigue": 90, "sleeping": False,
    "talking_to_npc": False, "inventory": inventory, "messages": [],
    "players": [], "npcs": [], "objects": [], "bounds": [],
    "ground_items": [], "skills": [],
}

def put_snapshot():
    snapshot["ts"] = gp.now_ms()
    json.dump(snapshot, open(os.path.join(state_dir, "state.json"), "w"))

def bridge_one():
    action_path = os.path.join(state_dir, "action.json")
    for _ in range(300):
        if os.path.exists(action_path):
            body = open(action_path).read()
            fields = dict(line.split("=", 1) for line in body.splitlines()
                          if "=" in line)
            assert fields["type"] == "click-inventory", fields
            assert fields["item"] == "20", fields
            assert "batch" not in fields, fields  # evaluator metadata only
            os.remove(action_path)
            bone = next(entry for entry in snapshot["inventory"]
                        if entry.get("id") == 20)
            snapshot["inventory"].remove(bone)
            snapshot["tick"] += 1
            put_snapshot()
            json.dump({"id": int(fields["id"]), "ts": gp.now_ms(),
                       "status": "done"},
                      open(os.path.join(state_dir, "receipt.json"), "w"))
            return
        time.sleep(0.01)
    raise AssertionError("no batch member was emitted")

put_snapshot()
for expected_before in (3, 2, 1):
    assert gp.inventory_quantity(snapshot, 20) == expected_before
    worker = threading.Thread(target=bridge_one)
    worker.start()
    verdict, code = gp.step_once(gp.load_config(), "inventory-test",
                                 "thieving", 3000)
    worker.join()
    assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
    assert gp.inventory_quantity(snapshot, 20) == expected_before - 1
    if expected_before > 1:
        batch = gp.load_player_state().get("action_batch")
        assert batch and batch["item"] == 20, batch
        # This proves continuation is no longer tied to the initiating 28-slot
        # threshold: it remains live at 27 and then 26 occupied slots.
        assert len(snapshot["inventory"]) < 28

assert gp.load_player_state().get("action_batch") is None
verdict, _code = gp.step_once(gp.load_config(), "inventory-test", "thieving", 3000)
assert verdict in ("no-rule-matched", "same-tick"), verdict
assert not os.path.exists(os.path.join(state_dir, "action.json"))
PY
