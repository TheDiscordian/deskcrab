#!/bin/bash
# The reflex-fire ledger (specs/game-player.md rules 10, 10a): every concluded
# rule firing appends one self-describing reflex-outcome record with before and
# after coordinates; a deliberation's step/play door presents firings recorded
# since the previous presentation EXACTLY ONCE, advances the durable cursor
# without replaying old entries, includes the game-reflex engine's own log, and
# makes a displacement that contradicts intent obvious from the record alone.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

python3 - "$GP" <<'PY' \
    && ok "reflex firings reach the next deliberation exactly once, with before/after coordinates" \
    || fail "the reflex-fire ledger must present each firing once and make displacement obvious"
import contextlib, importlib.util, io, json, os, subprocess, sys, threading, time

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

state_dir = os.environ["DESKCRAB_GAME_STATE_DIR"]
game_dir = os.environ["DESKCRAB_GAME_DIR"]
open(os.path.join(game_dir, "objective"), "w").write("ledger-test\n")
open(os.path.join(game_dir, "activity"), "w").write("traveling\n")

TABLE = {
    "v": 1,
    "defaults": {"stale_ms": 2000, "min_action_interval_ms": 0,
                 "max_actions_per_min": 0, "inflight_timeout_ms": 3000},
    "rules": [
        {"name": "ledger-test-walk", "enabled": True, "priority": 50,
         "cooldown_ms": 0, "hold_ticks": 1,
         "trigger": {"objective_is": "ledger-test",
                     "near_tile": {"x": 200, "z": 200, "radius": 5}},
         "action": {"type": "walk", "x": 202, "z": 200, "arrive": 0}},
    ],
    "unfinished": [],
}
json.dump(TABLE, open(os.path.join(game_dir, "learned-rules.json"), "w"))

TICK = [10]
def snapshot(px, pz):
    TICK[0] += 6
    return {"v": 1, "ts": gp.now_ms(), "tick": TICK[0], "logged_in": True,
            "walking": False, "in_combat": False, "x": px, "z": pz,
            "hits": 20, "hits_max": 20, "fatigue": 0, "talking_to_npc": False,
            "opponent": None, "inventory": [], "messages": [], "players": [],
            "npcs": [], "objects": [], "bounds": [], "ground_items": [],
            "terrain": {"radius": 6, "blocked_cells": [], "barriers": []}}

def put_snapshot(snap):
    json.dump(snap, open(os.path.join(state_dir, "state.json"), "w"))

def bridge(next_snap):
    action_path = os.path.join(state_dir, "action.json")
    for _ in range(300):
        if os.path.exists(action_path):
            fields = dict(line.split("=", 1)
                          for line in open(action_path).read().splitlines()
                          if "=" in line)
            os.remove(action_path)
            json.dump({"id": int(fields["id"]), "ts": gp.now_ms(),
                       "status": "done"},
                      open(os.path.join(state_dir, "receipt.json"), "w"))
            put_snapshot(next_snap)
            return
        time.sleep(0.02)
    raise AssertionError("no action was emitted")

# --- 1. A real firing through the runtime path writes ONE reflex-outcome
# record carrying rule, trigger, action, and before/after coordinates.
put_snapshot(snapshot(200, 200))
worker = threading.Thread(target=bridge, args=(snapshot(202, 200),))
worker.start()
verdict, code = gp.step_once(gp.load_config(), "ledger-test", "traveling", 3000)
worker.join()
assert (verdict, code) == ("fired", gp.EXIT_FIRED), (verdict, code)
outcomes = [json.loads(line) for line in
            open(os.path.join(state_dir, "player-decisions.jsonl"))
            if '"reflex-outcome"' in line]
assert len(outcomes) == 1, outcomes
record = outcomes[0]
assert record["rule"] == "ledger-test-walk", record
assert record["trigger"]["near_tile"]["x"] == 200, record
assert record["start"] == {"x": 200, "z": 200}, record
assert record["end"] == {"x": 202, "z": 200}, record
assert record["moved"] == 2, record

# --- 2. The reflex ENGINE's own log rides the same ledger, tagged.
with open(os.path.join(state_dir, "decisions.jsonl"), "a") as fh:
    fh.write(json.dumps({"ts": gp.now_ms(), "kind": "fired",
                         "rule": "eat-low-health", "id": 7,
                         "action": {"type": "eat", "slot": 3, "item": 132},
                         "snap": {"x": 202, "z": 200}}) + "\n")
    fh.write(json.dumps({"ts": gp.now_ms(), "kind": "receipt", "id": 7,
                         "status": "done"}) + "\n")

# --- 3. First presentation carries both firings; the cursor then advances so
# a second presentation replays NOTHING.
def present():
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        gp.present_reflex_fires()
    return out.getvalue()

first = present()
assert first.count("ledger-test-walk") == 1, first
assert '"moved":2' in first, first
assert "eat-low-health" in first and '"engine":"reflex"' in first, first
second = present()
assert "reflex-fire" not in second, second
cursor = json.load(open(os.path.join(game_dir, "reflex-fire-cursor.json")))
assert cursor["player"]["offset"] > 0 and cursor["reflex"]["offset"] > 0, cursor

# --- 4. A firing recorded BETWEEN two deliberations appears in exactly the
# next one - including through the actual model-facing step door - and a
# distance mismatch is obvious from the record alone.
with open(os.path.join(state_dir, "player-decisions.jsonl"), "a") as fh:
    fh.write(json.dumps({
        "ts": gp.now_ms(), "kind": "reflex-outcome", "id": 991,
        "rule": "test-retreat-from-farmer-fights",
        "status": "sidestep-displaced",
        "trigger": {"in_combat": True, "npc_visible": 63},
        "action": {"type": "walk", "x": 267, "z": 605, "sidestep": 1,
                   "origin_x": 267, "origin_z": 604},
        "start": {"x": 267, "z": 604}, "end": {"x": 267, "z": 609},
        "moved": 5}) + "\n")
put_snapshot(snapshot(250, 250))
env = dict(os.environ)
door = subprocess.run([sys.executable, sys.argv[1], "step", "--local",
                       "--max", "1"],
                      capture_output=True, text=True, env=env)
assert door.stdout.count("test-retreat-from-farmer-fights") == 1, door.stdout
assert '"moved":5' in door.stdout, door.stdout
assert '"start":{"x":267,"z":604}' in door.stdout, door.stdout
assert '"end":{"x":267,"z":609}' in door.stdout, door.stdout
door2 = subprocess.run([sys.executable, sys.argv[1], "step", "--local",
                        "--max", "1"],
                       capture_output=True, text=True, env=env)
assert "reflex-fire " not in door2.stdout, door2.stdout

# --- 5. A rotated/replaced log falls back to the last presented timestamp:
# nothing old replays, the fresh event still arrives.
os.remove(os.path.join(state_dir, "player-decisions.jsonl"))
time.sleep(0.01)
with open(os.path.join(state_dir, "player-decisions.jsonl"), "w") as fh:
    fh.write(json.dumps({
        "ts": gp.now_ms(), "kind": "reflex-outcome", "id": 992,
        "rule": "after-rotation", "status": "done",
        "trigger": {}, "action": {"type": "walk", "x": 1, "z": 1},
        "start": {"x": 0, "z": 0}, "end": {"x": 1, "z": 1},
        "moved": 1}) + "\n")
third = present()
assert third.count("after-rotation") == 1, third
assert "ledger-test-walk" not in third, third
fourth = present()
assert "reflex-fire" not in fourth, fourth
PY
