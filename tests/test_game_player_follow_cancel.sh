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
refute "no model call leaked from any pass" test -f "$SANDBOX/model-called"
