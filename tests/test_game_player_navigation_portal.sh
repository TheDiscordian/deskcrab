#!/bin/bash
# A client-cache route consumes its exact observed door/gate as a semantic
# action, proves the opening, and never retries an unchanged refusal.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

python3 - "$GP" <<'PY' \
    && ok "a route opens the exact planned portal and bounds a failed opening" \
    || fail "route portal handling must be semantic, verified, and non-repeating"
import importlib.util, json, os, sys, threading, time

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

state_dir = os.environ["DESKCRAB_GAME_STATE_DIR"]
game_dir = os.environ["DESKCRAB_GAME_DIR"]
open(os.path.join(game_dir, "objective"), "w").write("travel\n")
open(os.path.join(game_dir, "plan"), "w").write("Reach the named place\n")
open(os.path.join(game_dir, "activity"), "w").write("questing\n")
json.dump(gp.EMPTY_TABLE, open(os.path.join(game_dir, "learned-rules.json"), "w"))

portal = {"kind": "object", "id": 60, "x": 121, "z": 648, "dir": 0,
          "from": [120, 648], "to": [121, 648]}
decoy = {"id": 60, "name": "gate", "x": 119, "z": 648,
         "blocks_movement": True}
chosen = {"id": 60, "name": "gate", "x": 121, "z": 648,
          "blocks_movement": True}

def snapshot(tick, objects):
    return {"v": 1, "ts": gp.now_ms(), "tick": tick,
            "logged_in": True, "walking": False, "in_combat": False,
            "x": 120, "z": 648, "hits": 10, "hits_max": 10,
            "fatigue": 0, "talking_to_npc": False, "opponent": None,
            "inventory": [], "messages": [], "players": [], "npcs": [],
            "objects": objects, "bounds": [], "ground_items": []}

gp.client_cache_route_plan = lambda *args: {
    "status": "ok", "waypoints": [[121, 648]], "steps": 1,
    "expanded": 2, "portals": [portal]}

def arm_route():
    gp.save_route({"v": 1, "x": 140, "z": 648, "arrive": 1,
                   "objective": "travel", "status": "active",
                   "set_ts": gp.now_ms(), "visited": [[120, 648]],
                   "nonclosing_legs": 0,
                   "landmark": {"kind": "npc", "id": 1,
                                "name": "Destination"}})

captured = []
def bridge(open_gate, next_tick):
    action_path = os.path.join(state_dir, "action.json")
    for _ in range(200):
        if os.path.exists(action_path):
            body = open(action_path).read()
            captured.append(body)
            fields = dict(line.split("=", 1) for line in body.splitlines()
                          if "=" in line)
            os.remove(action_path)
            json.dump({"id": int(fields["id"]), "ts": gp.now_ms(),
                       "status": "done"},
                      open(os.path.join(state_dir, "receipt.json"), "w"))
            objects = [decoy] if open_gate else [decoy, chosen]
            json.dump(snapshot(next_tick, objects),
                      open(os.path.join(state_dir, "state.json"), "w"))
            return
        time.sleep(0.02)
    raise AssertionError("no portal action was emitted")

arm_route()
json.dump(snapshot(10, [decoy, chosen]),
          open(os.path.join(state_dir, "state.json"), "w"))
worker = threading.Thread(target=bridge, args=(True, 11))
worker.start()
verdict, code = gp.step_once(gp.load_config(), "travel", "questing", 3000)
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "type=interact-object" in captured[-1], captured[-1]
assert "x=121" in captured[-1] and "z=648" in captured[-1], captured[-1]
assert "x=119" not in captured[-1], captured[-1]
route = gp.load_route()
assert route["status"] == "active", route
assert "next_portal" not in route, route

# A receipt without the observed opening blocks once and never re-fires.
time.sleep(0.7)
arm_route()
json.dump(snapshot(20, [decoy, chosen]),
          open(os.path.join(state_dir, "state.json"), "w"))
gp.verify_semantic_portal_open = lambda portal: (
    "portal-open-unverified", snapshot(21, [decoy, chosen]))
worker = threading.Thread(target=bridge, args=(False, 21))
worker.start()
verdict, code = gp.step_once(gp.load_config(), "travel", "questing", 3000)
worker.join()
assert (verdict, code) == ("route-needs-local-interaction", gp.EXIT_NO_RULE), \
       (verdict, code)
assert gp.load_route()["status"] == "blocked", gp.load_route()
before = len(captured)
verdict, code = gp.step_once(gp.load_config(), "travel", "questing", 3000)
assert (verdict, code) == ("route-needs-local-interaction", gp.EXIT_NO_RULE), \
       (verdict, code)
assert len(captured) == before
assert not os.path.exists(os.path.join(state_dir, "action.json"))
PY
