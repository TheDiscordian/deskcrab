#!/bin/bash
# Spec rule 7g's method binding and stop postcondition: a follow serves the
# method that chose it — objective, plan, AND activity — and ends when any of
# them changes, with the body observed stopped: the cancellation dispatches
# the game's own stop (one walk to the current tile) and completes only when
# a later snapshot reports walking false, so a stale Follow commitment can
# never keep walking the body away from revised play, and a cancelled record
# can never fire again. Run: bash tests/test_game_player_follow_cancel.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
GP="$REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
# Point the memory door at nothing so an activity change cannot stall on a
# recall subprocess; the door fails open by contract.
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

# snap <tick> [extra-json-pairs] — a fresh logged-in snapshot.
snap() {
    local extra='{}'
    [ $# -ge 2 ] && extra="$2"
    python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" "$1" "$extra" <<'PY'
import json, sys, time
path, tick, extra = sys.argv[1:4]
snap = {"v": 1, "ts": int(time.time() * 1000), "tick": int(tick),
        "logged_in": True, "hits": 10, "hits_max": 10, "fatigue": 0,
        "x": 120, "z": 648, "walking": False, "in_combat": False,
        "talking_to_npc": False, "opponent": None,
        "inventory": [], "messages": [{"text": "Welcome to the game"}],
        "npcs": []}
snap.update(json.loads(extra))
json.dump(snap, open(path, "w"))
PY
}

last_action() { sandbox_count_in "^$1" "$DESKCRAB_GAME_STATE_DIR/last-action"; }
decisions() { cat "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl" 2>/dev/null; }

# A one-shot stop bridge: consume the next action, keep a copy, answer done,
# and publish the stopped body — the same walking:false a real client shows
# once the server clears its native follow and walk queue.
stop_bridge() {
    python3 - "$DESKCRAB_GAME_STATE_DIR" <<'PY' &
import json, os, sys, time
sd = sys.argv[1]
ap = os.path.join(sd, "action.json")
for _ in range(200):
    if os.path.exists(ap):
        body = open(ap).read()
        open(os.path.join(sd, "last-action"), "w").write(body)
        fields = dict(line.split("=", 1) for line in body.splitlines() if "=" in line)
        os.remove(ap)
        tmp = os.path.join(sd, ".receipt.tmp")
        json.dump({"id": int(fields["id"]), "ts": int(time.time() * 1000),
                   "status": "done"}, open(tmp, "w"))
        os.replace(tmp, os.path.join(sd, "receipt.json"))
        state_path = os.path.join(sd, "state.json")
        state = json.load(open(state_path))
        state["walking"] = False
        state["tick"] = int(state.get("tick", 0)) + 1
        state["ts"] = int(time.time() * 1000)
        tmp = os.path.join(sd, ".state.tmp")
        json.dump(state, open(tmp, "w"))
        os.replace(tmp, state_path)
        break
    time.sleep(0.05)
PY
    STOP_BRIDGE_PID=$!
}

python3 "$GP" init >/dev/null

# --- the record binds the whole method at follow time ----------------------
snap 100 '{"players":[{"sidx":7,"name":"Guide","x":130,"z":648}]}'
python3 "$GP" objective guided-tour >/dev/null
python3 "$GP" plan "Walk with the guide to the mine" >/dev/null
python3 "$GP" activity travelling >/dev/null
check "a follow starts under a full method binding" \
    python3 "$GP" follow Guide --within 2
check "the record binds plan and activity beside the objective" \
    sh -c "jq -e '.plan == \"Walk with the guide to the mine\"
                  and .activity == \"travelling\"
                  and .objective == \"guided-tour\"' \
           '$DESKCRAB_GAME_DIR/follow.json' >/dev/null"

# --- an activity change cancels a standing follow --------------------------
python3 "$GP" activity questing >/dev/null
snap 101 '{"players":[{"sidx":7,"name":"Guide","x":130,"z":648}]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the cancelled follow leaves ordinary evaluation: exit 4" "$CODE" "4"
contains "$OUT" 'no-rule-matched' \
    && ok "a visible ex-guide alone cannot hold the commitment" \
    || fail "the pass must fall through to ordinary evaluation" "$OUT"
refute "no follow action fires after the activity changed" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
refute "the cancelled record is gone" test -f "$DESKCRAB_GAME_DIR/follow.json"
contains "$(decisions)" '"reason":"activity-changed"' \
    && ok "the cancellation names the changed binding" \
    || fail "follow-cancelled must name activity-changed" "$(decisions | tail -5)"
contains "$(python3 "$GP" follow)" '(none)' \
    && ok "the follow door reports no commitment" \
    || fail "follow must report (none) after cancellation" "$(python3 "$GP" follow)"

# --- a plan revision cancels a WALKING follow and stops the body -----------
snap 102 '{"players":[{"sidx":7,"name":"Guide","x":130,"z":648}]}'
check "a fresh follow starts under the current method" \
    python3 "$GP" follow Guide --within 2
snap 103 '{"x":124,"z":648,"walking":true,"players":[]}'
python3 "$GP" plan --revise "the guide finished their part" \
    "Resume the quest from the library" >/dev/null
stop_bridge
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
wait "$STOP_BRIDGE_PID"
check_eq "the cancelling stop is a completed pass: exit 0" "$CODE" "0"
contains "$OUT" 'follow-stopped' && contains "$OUT" 'walking=false' \
    && ok "the postcondition is observed, not assumed" \
    || fail "the verdict must report follow-stopped walking=false" "$OUT"
check_eq "the stop is the game's own walk to the current tile" \
    "$(last_action 'type=walk')" "1"
check_eq "the stop targets the body's own x" "$(last_action 'x=124')" "1"
check_eq "the stop targets the body's own z" "$(last_action 'z=648')" "1"
refute "the stopped record is gone" test -f "$DESKCRAB_GAME_DIR/follow.json"
contains "$(decisions)" '"reason":"plan-changed"' \
    && ok "the cancellation names the revised plan" \
    || fail "follow-cancelled must name plan-changed" "$(decisions | tail -5)"
contains "$(decisions)" '"kind":"follow-stopped"' \
    && ok "the stop's completion is durable evidence" \
    || fail "follow-stopped must enter the decision log" "$(decisions | tail -5)"

# --- a pre-binding record cancels on first sight ---------------------------
python3 - "$DESKCRAB_GAME_DIR/follow.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "player": "Guide", "within": 2,
           "objective": "guided-tour", "status": "active",
           "set_ts": int(time.time() * 1000),
           "last_seen_ts": int(time.time() * 1000),
           "last_x": 130, "last_z": 648}, open(sys.argv[1], "w"))
PY
snap 110 '{"players":[{"sidx":7,"name":"Guide","x":130,"z":648}]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "a record without the method binding cannot keep firing: exit 4" "$CODE" "4"
refute "the legacy record is gone" test -f "$DESKCRAB_GAME_DIR/follow.json"
contains "$(decisions)" '"reason":"method-binding-missing"' \
    && ok "the legacy cancellation names its reason" \
    || fail "the legacy record must cancel as method-binding-missing" \
        "$(decisions | tail -5)"

# --- follow --clear proves the stop on a walking body ----------------------
snap 111 '{"players":[{"sidx":7,"name":"Guide","x":130,"z":648}]}'
check "a follow starts again for the clear test" \
    python3 "$GP" follow Guide --within 2
snap 112 '{"x":122,"z":650,"walking":true,"players":[]}'
stop_bridge
CODE=0; OUT="$(python3 "$GP" follow --clear)" || CODE=$?
wait "$STOP_BRIDGE_PID"
check_eq "the clear door completes the stop itself: exit 0" "$CODE" "0"
contains "$OUT" 'follow-stopped walking=false' \
    && ok "the door reports the observed postcondition" \
    || fail "follow --clear must report follow-stopped walking=false" "$OUT"
check_eq "the door's stop is also the walk to the current tile" \
    "$(last_action 'x=122')" "1"
refute "the cleared record is gone" test -f "$DESKCRAB_GAME_DIR/follow.json"

# --- and nothing refires -----------------------------------------------------
snap 113 '{"players":[{"sidx":7,"name":"Guide","x":140,"z":648}]}'
CODE=0; OUT="$(python3 "$GP" step --local)" || CODE=$?
check_eq "the next pass is ordinary play: exit 4" "$CODE" "4"
contains "$OUT" 'no-rule-matched' \
    && ok "no subsequent follow refire" \
    || fail "a cleared follow must stay cleared" "$OUT"
refute "no action rides the slot after the stop" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"

# --- lost-player navigation is bounded, portal-safe, and cycle-ending ------
python3 - "$GP" <<'PY' \
    && ok "lost-player movement uses local cache legs, exact portals, and abandons cycles" \
    || fail "follow recovery must be bounded and self-correcting"
import importlib.util, json, os, sys, threading, time

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

now = gp.now_ms()
request = {"v": 1, "player": "Guide", "within": 2,
           "objective": gp.read_objective(), "plan": gp.read_plan(),
           "activity": gp.read_activity(), "status": "active",
           "set_ts": now, "last_seen_ts": now,
           "last_x": 200, "last_z": 648,
           "visited": [[120, 648], [128, 648]],
           "nonclosing_legs": 0, "best_distance_sq": 80 * 80}
gp.save_follow(request)
gp.client_cache_route_plan = lambda *args: {
    "status": "ok", "waypoints": [[128, 648], [136, 648]],
    "steps": 80, "expanded": 20, "portals": []}
snap = json.load(open(os.path.join(os.environ["DESKCRAB_GAME_STATE_DIR"],
                                   "state.json")))
snap.update({"tick": 200, "ts": gp.now_ms(), "x": 120, "z": 648,
             "walking": False, "players": []})
json.dump(snap, open(os.path.join(os.environ["DESKCRAB_GAME_STATE_DIR"],
                                  "state.json"), "w"))
planned, action, reason = gp.prepare_follow_navigation(request, None, snap)
assert reason is None, reason
assert (action["x"], action["z"]) == (128, 648), action
assert (action["x"], action["z"]) != (200, 648), action

portal = {"kind": "object", "id": 60, "x": 121, "z": 648, "dir": 0,
          "from": [120, 648], "to": [121, 648]}
gp.client_cache_route_plan = lambda *args: {
    "status": "ok", "waypoints": [[121, 648]], "steps": 1,
    "expanded": 2, "portals": [portal]}
portal_snap = dict(snap, objects=[
    {"id": 60, "x": 119, "z": 648, "blocks_movement": True},
    {"id": 60, "x": 121, "z": 648, "blocks_movement": True}])
current = gp.load_follow()
planned, action, reason = gp.prepare_follow_navigation(current, None, portal_snap)
assert reason is None, reason
assert action == {"type": "interact-object", "obj": 60, "cmd": 1,
                  "x": 121, "z": 648}, action
compiled, refusal = gp.compile_player_action(
    {"action": action}, portal_snap, None, None)
assert refusal is None, refusal
assert (compiled["x"], compiled["z"]) == (121, 648), compiled

# Re-arm the repeated endpoint and let the real settlement path observe it.
request["set_ts"] = gp.now_ms() + 1
gp.save_follow(request)
gp.client_cache_route_plan = lambda *args: {
    "status": "ok", "waypoints": [[128, 648]], "steps": 8,
    "expanded": 10, "portals": []}
json.dump(snap, open(os.path.join(os.environ["DESKCRAB_GAME_STATE_DIR"],
                                  "state.json"), "w"))

def bridge():
    state_dir = os.environ["DESKCRAB_GAME_STATE_DIR"]
    action_path = os.path.join(state_dir, "action.json")
    for _ in range(200):
        if os.path.exists(action_path):
            fields = dict(line.split("=", 1) for line in
                          open(action_path).read().splitlines() if "=" in line)
            os.remove(action_path)
            json.dump({"id": int(fields["id"]), "ts": gp.now_ms(),
                       "status": "done"},
                      open(os.path.join(state_dir, "receipt.json"), "w"))
            settled = dict(snap, tick=201, ts=gp.now_ms(), x=128, z=648,
                           walking=False, players=[])
            json.dump(settled, open(os.path.join(state_dir, "state.json"), "w"))
            return
        time.sleep(0.02)
    raise AssertionError("no follow action was emitted")

worker = threading.Thread(target=bridge)
worker.start()
verdict, code = gp.step_once(gp.load_config(), gp.read_objective(),
                             gp.read_activity(), 3000)
worker.join()
assert (verdict, code) == ("follow-abandoned", gp.EXIT_NO_RULE), (verdict, code)
assert gp.load_follow() is None
events = open(os.path.join(os.environ["DESKCRAB_GAME_STATE_DIR"],
                           "player-decisions.jsonl")).read()
assert '"reason":"follow-cycle"' in events, events[-2000:]
assert '"controller":"self"' in events, events[-2000:]

# A late old settlement cannot overwrite a newer generation.
gp.save_follow(dict(request, set_ts=request["set_ts"] + 10))
assert not gp.replace_follow_if_current(request, dict(request, status="blocked"))
assert gp.load_follow()["set_ts"] == request["set_ts"] + 10
gp.clear_follow()
PY

refute "no model call leaked from any pass" test -f "$SANDBOX/model-called"
