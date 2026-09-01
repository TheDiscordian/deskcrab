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
