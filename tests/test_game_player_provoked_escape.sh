#!/bin/bash
# Provocation is causal action identity, and it survives the conclusion of the
# action that caused it (specs/game-player.md rules 5, 5a, 7a): a pickpocket
# that concludes OUT of combat still classifies the delayed retaliation as
# provoked, so the injected low-health-retreat-to-eat transition compiles the
# same one-tile combat break as the escape reflex — out_of_combat exactly one
# tile from the combat origin, healing owning the next pass — while a fight
# with no standing provocation evidence keeps the far clearance retreat.
# Grounded in the 2026-09-01 leaderboard incident: three retaliation fights
# (Warrior 86) each classified unprovoked because the marker was only armed
# when combat was already visible at the pickpocket's conclusion, so
# low-health-retreat-to-eat fired the bridge retreat distance=5 and displaced
# the body five tiles instead of one.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

python3 - "$GP" <<'PY' \
    && ok "delayed retaliation stays provoked: the low-health transition breaks combat by one tile and healing owns the next pass; unprovoked fights keep the far retreat" \
    || fail "provocation evidence must survive the provoking action's out-of-combat conclusion, and the low-health escape must ride the same selection"
import importlib.util, json, os, sys, threading, time

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

state_dir = os.environ["DESKCRAB_GAME_STATE_DIR"]
game_dir = os.environ["DESKCRAB_GAME_DIR"]
open(os.path.join(game_dir, "objective"), "w").write("leaderboard-test\n")
open(os.path.join(game_dir, "activity"), "w").write("thieving\n")
open(os.path.join(game_dir, "food-heals.xml"), "w").write(
    "<map><entry><int>10</int><int>3</int></entry></map>\n")
# The armed eat the healing prerequisite reads (rule 7i), shaped like the
# live table.
json.dump({
    "v": 1,
    "defaults": {"stale_ms": 2000, "poll_ms": 150,
                 "min_action_interval_ms": 0, "max_actions_per_min": 0,
                 "inflight_timeout_ms": 2000, "eat_pick": "min"},
    "rules": [
        {"name": "eat-low-health", "enabled": True, "channel": "game",
         "priority": 10, "cooldown_ms": 0, "hold_ticks": 2,
         "trigger": {"hp_below": 0.5, "requires_food": True,
                     "in_combat": False},
         "action": {"type": "eat"}},
    ],
}, open(os.path.join(game_dir, "reflex-rules.json"), "w"))

TABLE = {
    "v": 1,
    "defaults": {"stale_ms": 2000, "min_action_interval_ms": 0,
                 "max_actions_per_min": 0, "inflight_timeout_ms": 3000},
    "rules": [
        {"name": "test-pickpocket-visible-farmer", "enabled": True,
         "priority": 40, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"objective_is": "leaderboard-test",
                     "activity_is": "thieving", "npc_visible": 63,
                     "out_of_combat": True, "inventory_slots_below": 28},
         "action": {"type": "interact-npc", "npc": 63, "cmd": 1}},
        {"name": "test-travel-hub-leg", "enabled": True,
         "priority": 10, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"objective_is": "leaderboard-test",
                     "out_of_combat": True,
                     "near_tile": {"x": 200, "z": 200, "radius": 2}},
         "action": {"type": "walk", "x": 202, "z": 200, "arrive": 0}},
    ],
    "unfinished": [],
}
json.dump(TABLE, open(os.path.join(game_dir, "learned-rules.json"), "w"))
gp.validate_config(TABLE)

TICK = [100]
def snapshot(in_combat, px, pz, farmer_x, farmer_z, opponent=None,
             messages=None, no_npcs=False, opponent_rounds=0,
             hits=12):
    TICK[0] += 6
    return {"v": 1, "ts": gp.now_ms(), "tick": TICK[0], "logged_in": True,
            "walking": False, "in_combat": in_combat,
            "opponent_rounds": opponent_rounds, "x": px, "z": pz,
            "hits": hits, "hits_max": 24, "fatigue": 10,
            "talking_to_npc": False,
            "opponent": opponent, "inventory": [{"id": 10, "count": 1}],
            "messages": messages or [], "players": [],
            "npcs": [] if no_npcs else [
                {"sidx": 900, "id": 63, "x": farmer_x, "z": farmer_z,
                 "attackable": True}],
            "objects": [], "bounds": [], "ground_items": [],
            "terrain": {"radius": 6, "blocked_cells": [], "barriers": []}}

def put_snapshot(snap):
    json.dump(snap, open(os.path.join(state_dir, "state.json"), "w"))

captured = []
def bridge(next_snap, fail_message=None):
    """Consume one action, receipt done, publish the given next snapshot."""
    action_path = os.path.join(state_dir, "action.json")
    for _ in range(300):
        if os.path.exists(action_path):
            body = open(action_path).read()
            captured.append(body)
            fields = dict(line.split("=", 1) for line in body.splitlines()
                          if "=" in line)
            if fail_message is not None:
                next_snap["messages"] = [{
                    "id": gp.now_ms() * 1000, "channel": "game",
                    "incoming": False, "sender": "", "text": fail_message}]
            os.remove(action_path)
            json.dump({"id": int(fields["id"]), "ts": gp.now_ms(),
                       "status": "done"},
                      open(os.path.join(state_dir, "receipt.json"), "w"))
            put_snapshot(next_snap)
            return
        time.sleep(0.02)
    raise AssertionError("no action was emitted: " + repr(captured))

def step():
    return gp.step_once(gp.load_config(), "leaderboard-test", "thieving", 3000)

# --- 1. The delayed-retaliation shape from the live incident: the pickpocket
# CONCLUDES with the body still out of combat (the failure message lands
# before the NPC's first swing), and the provocation marker must still be
# standing evidence for the fight that follows.
put_snapshot(snapshot(False, 100, 100, 100, 101))
concluded = snapshot(False, 100, 100, 100, 101)   # still out of combat
worker = threading.Thread(target=bridge, args=(
    concluded,), kwargs={"fail_message": "You fail to pick the farmer's pocket"})
worker.start()
verdict, code = step()
worker.join()
assert verdict == "fired", (verdict, code)
assert "type=interact-npc" in captured[-1], captured[-1]
est = gp.load_player_state()
marker = est.get("last_npc_action")
assert isinstance(marker, dict) and marker.get("npc") == 63, \
    ("provocation evidence must survive an out-of-combat conclusion", marker)
assert marker.get("awaiting_combat") is True, marker

# --- 2. The retaliation arrives on the server's own timer, seconds later:
# the new combat episode classifies PROVOKED from that standing evidence.
put_snapshot(snapshot(True, 100, 100, 100, 101,
                      opponent={"x": 100, "z": 101}, opponent_rounds=1,
                      hits=11))
verdict, code = step()
est = gp.load_player_state()
assert est.get("combat_provoked") is True, \
    ("delayed retaliation misclassified as unprovoked", est.get("combat_provoked"))
assert est.get("combat_opponent_npc") == 63, est.get("combat_opponent_npc")
assert est.get("last_npc_action") is None, "the episode consumes the marker"
origin = est.get("combat_origin")
assert origin == {"x": 100, "z": 100}, origin

# --- 3. At three observed rounds and low health, low-health-retreat-to-eat
# rides the SAME provocation-aware escape selection: one adjacent walk
# (max_path 1), never the bridge's distance-5 retreat, and the observed
# postcondition is out_of_combat exactly ONE tile from the combat origin.
put_snapshot(snapshot(True, 100, 100, 100, 101,
                      opponent={"x": 100, "z": 101}, opponent_rounds=3,
                      hits=11))
after = snapshot(False, 100, 99, 100, 101, hits=11)  # settled on the chosen tile
worker = threading.Thread(target=bridge, args=(after,))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "type=walk" in captured[-1] and "type=retreat" not in captured[-1], \
    ("the provoked low-health escape must be the one-tile break", captured[-1])
assert "max_path=1" in captured[-1] and "arrive=0" in captured[-1], captured[-1]
assert "distance=5" not in captured[-1], captured[-1]
log = open(os.path.join(state_dir, "player-decisions.jsonl")).read()
fired = [json.loads(line) for line in log.splitlines()
         if '"kind":"fired"' in line and '"rule":"low-health-retreat-to-eat"' in line]
assert fired and fired[-1]["action"].get("retreat_suppressed") == 1, \
    (fired[-1]["action"] if fired else "low-health-retreat-to-eat never fired")
assert '"kind":"sidestep-clear"' in log, "verified one-tile break not recorded"
live = json.load(open(os.path.join(state_dir, "state.json")))
assert live["in_combat"] is False, live
moved = max(abs(live["x"] - origin["x"]), abs(live["z"] - origin["z"]))
assert moved == 1, ("postcondition is one tile from the combat origin",
                    live["x"], live["z"])

# --- 4. Safe healing owns the next action: the first out-of-combat pass at
# low health with held food and an armed eat emits NOTHING learned.
verdict, code = step()
assert (verdict, code) == ("healing-prerequisite", gp.EXIT_NOT_READY), \
    (verdict, code)
assert not os.path.exists(os.path.join(state_dir, "action.json")), \
    "the healing prerequisite must leave the action slot to the eat reflex"

# --- 5. The marker is causal identity, never a freshness window: the NEXT
# concluded game action supersedes it, so a later fight with no standing
# provocation evidence keeps the far clearance retreat.
healed = snapshot(False, 200, 205, 200, 206)     # farmer beside the hub
put_snapshot(healed)
concluded = snapshot(False, 200, 205, 200, 206)
worker = threading.Thread(target=bridge, args=(
    concluded,), kwargs={"fail_message": "You fail to pick the farmer's pocket"})
worker.start()
verdict, code = step()
worker.join()
assert "type=interact-npc" in captured[-1], captured[-1]
assert (gp.load_player_state().get("last_npc_action") or {}).get("npc") == 63

put_snapshot(snapshot(False, 200, 200, 0, 0, no_npcs=True))   # at the hub
walked = snapshot(False, 202, 200, 0, 0, no_npcs=True)
worker = threading.Thread(target=bridge, args=(walked,))
worker.start()
verdict, code = step()
worker.join()
assert "type=walk" in captured[-1], captured[-1]
assert gp.load_player_state().get("last_npc_action") is None, \
    "any later concluded action supersedes the provocation marker"

try:
    os.remove(os.path.join(state_dir, "last-action-observation.json"))
except FileNotFoundError:
    pass
put_snapshot(snapshot(True, 202, 200, 202, 201,
                      opponent={"x": 202, "z": 201}, opponent_rounds=3,
                      hits=11))
worker = threading.Thread(target=bridge,
                          args=(snapshot(True, 202, 200, 202, 201,
                                         opponent={"x": 202, "z": 201},
                                         opponent_rounds=3, hits=11),))
worker.start()
orig_retreat = gp.verify_retreat
gp.verify_retreat = lambda: ("retreat-locked", 202, 200)
verdict, code = step()
gp.verify_retreat = orig_retreat
worker.join()
assert "type=retreat" in captured[-1], \
    ("unprovoked combat must keep the far clearance retreat", captured[-1])
assert "distance=5" in captured[-1], captured[-1]
assert gp.load_player_state().get("combat_provoked") is False
PY
