#!/bin/bash
# The one-tile combat break (specs/game-player.md rules 4, 5, 7a, 7b): a
# provoked, non-aggressive thieving retaliation is broken by exactly one
# adjacent collision-reachable walk through the ACTUAL runtime path, with the
# observed displacement verified; approach distance to a pickpocket target is
# never capped; the far clearance retreat remains only for unprovoked combat;
# a discarded lock dispatch retries without pausing; only the two grounded
# anomalies pause, and the pause door re-arms.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

python3 - "$GP" <<'PY' \
    && ok "provoked thieving combat breaks by exactly one observed tile; approach stays uncapped; far retreat stays for aggression" \
    || fail "the one-tile break must bind only the combat disengage, verified by observed displacement"
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
        {"name": "test-retreat-from-farmer-fights", "enabled": True,
         "priority": 1000, "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"objective_is": "leaderboard-test", "in_combat": True,
                     "npc_visible": 63},
         "action": {"type": "retreat", "distance": 5, "dx": 0, "dz": 1}},
    ],
    "unfinished": [],
}
json.dump(TABLE, open(os.path.join(game_dir, "learned-rules.json"), "w"))
gp.validate_config(TABLE)   # the generic-retreat table stays valid as authored

TICK = [100]
def snapshot(in_combat, px, pz, farmer_x, farmer_z, opponent=None,
             messages=None, no_npcs=False, opponent_rounds=0):
    TICK[0] += 6
    return {"v": 1, "ts": gp.now_ms(), "tick": TICK[0], "logged_in": True,
            "walking": False, "in_combat": in_combat,
            "opponent_rounds": opponent_rounds, "x": px, "z": pz,
            "hits": 20, "hits_max": 23, "fatigue": 10,
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
def bridge(next_snap):
    """Consume one action, receipt done, publish the given next snapshot."""
    action_path = os.path.join(state_dir, "action.json")
    for _ in range(300):
        if os.path.exists(action_path):
            body = open(action_path).read()
            captured.append(body)
            fields = dict(line.split("=", 1) for line in body.splitlines()
                          if "=" in line)
            if fields.get("type") == "interact-npc":
                next_snap["messages"] = [{
                    "id": gp.now_ms() * 1000, "channel": "game",
                    "incoming": False, "sender": "",
                    "text": ("You fail to pick the farmer's pocket"
                             if next_snap.get("in_combat") else
                             "You pick the farmer's pocket"),
                }]
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

# --- 1. Seek/approach stays UNCAPPED: a farmer five tiles away is approached
# and pickpocketed through the ordinary rule; nothing reinterprets the walk.
put_snapshot(snapshot(False, 100, 100, 105, 100))
worker = threading.Thread(target=bridge,
                          args=(snapshot(True, 100, 100, 100, 101,
                                         opponent={"x": 100, "z": 101}),))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "type=interact-npc" in captured[-1], captured[-1]
assert "npc=63" in captured[-1], captured[-1]
assert "within" not in captured[-1], captured[-1]
est = gp.load_player_state()
assert (est.get("last_npc_action") or {}).get("npc") == 63, est.get("last_npc_action")
assert est["last_npc_action"].get("awaiting_combat") is True, est

# --- 2. Provoked retaliation: pre-threshold combat holds EVERYTHING still -
# no probe dispatch, no route leg, no pickpocket.
put_snapshot(snapshot(True, 100, 100, 100, 101,
                      opponent={"x": 100, "z": 101}, opponent_rounds=2))
verdict, code = step()
assert verdict in ("no-rule-matched", "same-tick"), (verdict, code)
assert not os.path.exists(os.path.join(state_dir, "action.json"))
est = gp.load_player_state()
assert est.get("combat_provoked") is True, est
assert est.get("combat_opponent_npc") == 63, est

# --- 3. At the third observed combat round the generic retreat rule compiles to
# ONE adjacent walk (max_path 1), and the OBSERVED displacement is exactly
# one tile from the pre-retreat origin.
put_snapshot(snapshot(True, 100, 100, 100, 101,
                      opponent={"x": 100, "z": 101}, opponent_rounds=3))
after = snapshot(False, 100, 99, 100, 101)     # settled on the chosen tile
worker = threading.Thread(target=bridge, args=(after,))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "type=walk" in captured[-1] and "type=retreat" not in captured[-1], captured[-1]
assert "max_path=1" in captured[-1] and "arrive=0" in captured[-1], captured[-1]
assert "x=100" in captured[-1] and "z=99" in captured[-1], captured[-1]
live = json.load(open(os.path.join(state_dir, "state.json")))
moved = max(abs(live["x"] - 100), abs(live["z"] - 100))
assert moved == 1, (live["x"], live["z"])
log = open(os.path.join(state_dir, "player-decisions.jsonl")).read()
assert '"kind":"sidestep-clear"' in log, "verified one-tile break not recorded"

# --- 4. Thieving resumes immediately: no pause was written, the pickpocket
# rule fires on the next out-of-combat pass.
assert not os.path.exists(os.path.join(game_dir, "sidestep-pause.json"))
put_snapshot(snapshot(False, 100, 99, 103, 99))
worker = threading.Thread(target=bridge,
                          args=(snapshot(True, 100, 99, 100, 100,
                                         opponent={"x": 100, "z": 100}),))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "type=interact-npc" in captured[-1], captured[-1]

# --- 5. A lock-discarded dispatch provably moved nothing: no pause, the rule
# stays eligible and retries the same one-tile break.
put_snapshot(snapshot(True, 100, 99, 100, 100,
                      opponent={"x": 100, "z": 100}))
verdict, code = step()          # transition pass: combat episode starts
orig_verify = gp.verify_sidestep
gp.verify_sidestep = lambda action: orig_verify(action, timeout_s=0.4)
put_snapshot(snapshot(True, 100, 99, 100, 100,
                      opponent={"x": 100, "z": 100}, opponent_rounds=3))
locked = snapshot(True, 100, 99, 100, 100, opponent={"x": 100, "z": 100},
                  messages=[{"id": 1, "channel": "game", "incoming": False,
                             "sender": "",
                             "text": "You can't retreat during the first 3 rounds of combat"}],
                  opponent_rounds=3)
worker = threading.Thread(target=bridge, args=(locked,))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_NOT_DONE), (verdict, code)
log = open(os.path.join(state_dir, "player-decisions.jsonl")).read()
assert '"kind":"sidestep-locked"' in log, "lock outcome not recorded"
assert not os.path.exists(os.path.join(game_dir, "sidestep-pause.json")), \
    "a discarded lock dispatch must not pause thieving"
# retry: still eligible, same one-tile shape, and this time it clears
time.sleep(0.05)
put_snapshot(snapshot(True, 100, 99, 100, 100,
                      opponent={"x": 100, "z": 100}, opponent_rounds=4))
cleared = snapshot(False, 100, 98, 100, 100)   # the away-from-opponent tile
worker = threading.Thread(target=bridge, args=(cleared,))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "max_path=1" in captured[-1], captured[-1]
gp.verify_sidestep = orig_verify

# reset the archived episode with a quiet out-of-combat pass (no farmer
# visible, so nothing fires and nothing waits on a receipt)
put_snapshot(snapshot(False, 99, 99, 0, 0, no_npcs=True))
verdict, code = step()
assert verdict == "no-rule-matched", (verdict, code)

# --- 6. The displaced anomaly pauses ONLY the provoking activity, the
# no-rule-matched verdict names it, and the deliberate door re-arms.
est = gp.load_player_state()
est["last_npc_action"] = {"id": 998, "type": "interact-npc", "npc": 63,
                          "awaiting_combat": True}
est["combat_id"] = None
gp.save_player_state(est)
put_snapshot(snapshot(True, 99, 99, 99, 100, opponent={"x": 99, "z": 100}))
verdict, code = step()
put_snapshot(snapshot(True, 99, 99, 99, 100,
                      opponent={"x": 99, "z": 100}, opponent_rounds=3))
gp.verify_sidestep = lambda action: orig_verify(action, timeout_s=0.4)
displaced = snapshot(False, 95, 99, 99, 100)   # four tiles: something else moved us
worker = threading.Thread(target=bridge, args=(displaced,))
worker.start()
verdict, code = step()
worker.join()
gp.verify_sidestep = orig_verify
assert (verdict, code) == ("fired", gp.EXIT_NOT_DONE), (verdict, code)
pause = json.load(open(os.path.join(game_dir, "sidestep-pause.json")))
assert pause["status"] == "sidestep-displaced", pause
assert pause["npc"] == 63, pause
outq = open(os.path.join(game_dir, "outcome-queue.jsonl")).read()
assert '"kind":"sidestep-diagnostic"' in outq, "grounded diagnostic not queued"
put_snapshot(snapshot(False, 95, 99, 96, 99))
verdict, code = step()
assert verdict == "no-rule-matched", (verdict, code)
assert not os.path.exists(os.path.join(state_dir, "action.json")), \
    "pickpocket must be held while the anomaly pause stands"
log = open(os.path.join(state_dir, "player-decisions.jsonl")).read()
assert '"kind":"sidestep-pause-hold"' in log
class Args: clear = True
gp.cmd_sidestep_pause(Args())
assert not os.path.exists(os.path.join(game_dir, "sidestep-pause.json"))
put_snapshot(snapshot(False, 95, 99, 96, 99))
worker = threading.Thread(target=bridge,
                          args=(snapshot(False, 95, 99, 96, 99),))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "type=interact-npc" in captured[-1], captured[-1]

# --- 7. UNPROVOKED combat is aggression evidence: the far clearance retreat
# is selected, immediately, exactly as before.
est = gp.load_player_state()
est["last_npc_action"] = None
est["combat_id"] = None
gp.save_player_state(est)
try:
    os.remove(os.path.join(state_dir, "last-action-observation.json"))
except FileNotFoundError:
    pass
put_snapshot(snapshot(True, 95, 99, 95, 100, opponent={"x": 95, "z": 100}))
worker = threading.Thread(target=bridge,
                          args=(snapshot(True, 95, 99, 95, 100,
                                         opponent={"x": 95, "z": 100}),))
worker.start()
orig_retreat = gp.verify_retreat
gp.verify_retreat = lambda: ("retreat-locked", 95, 99)
verdict, code = step()
gp.verify_retreat = orig_retreat
worker.join()
assert "type=retreat" in captured[-1], captured[-1]
assert "distance=5" in captured[-1], captured[-1]
est = gp.load_player_state()
assert est.get("combat_provoked") is False, est

# --- 8. Low health with food is a RETREAT-THEN-EAT transition. The player
# engine owns combat and emits the same one-tile break for a provoked target;
# the eat reflex is structurally ineligible until the resulting out-of-combat
# snapshot.
put_snapshot(snapshot(False, 95, 99, 0, 0, no_npcs=True))
verdict, code = step()
est = gp.load_player_state()
est["last_npc_action"] = {"id": 999, "type": "interact-npc", "npc": 63,
                          "awaiting_combat": True}
est["combat_id"] = None
gp.save_player_state(est)
low = snapshot(True, 95, 99, 95, 100, opponent={"x": 95, "z": 100},
               opponent_rounds=3)
low["hits"] = 5
low["hits_max"] = 23
put_snapshot(low)
safe = snapshot(False, 95, 98, 95, 100)
safe["hits"] = 5
safe["hits_max"] = 23
worker = threading.Thread(target=bridge, args=(safe,))
worker.start()
verdict, code = step()
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
assert "max_path=1" in captured[-1], captured[-1]
log = open(os.path.join(state_dir, "player-decisions.jsonl")).read()
assert '"rule":"low-health-retreat-to-eat"' in log, log[-1000:]
PY
