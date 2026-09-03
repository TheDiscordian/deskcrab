#!/bin/bash
# Rule 7b's settled chat verdict is time-grounded. Words are read long after
# they are said: the settle window closes, the chosen activity keeps running,
# and the reply is written at the end of whatever the player was doing. The
# verdict therefore states the current clock, and every message carries the
# time it arrived and how long ago that was, so the gap between what someone
# said and the answer is a fact in front of the player rather than a guess.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

echo "a settled burst carries the clock and each message's age (rule 7b):"

python3 - "$GP" <<'PY' \
    && ok "the settled player-message verdict states now, received and age, per message" \
    || fail "the settled verdict must carry the clock and every message's age"
import contextlib, importlib.util, io, json, os, re, sys

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

state_dir = os.environ["DESKCRAB_GAME_STATE_DIR"]
game_dir = os.environ["DESKCRAB_GAME_DIR"]
open(os.path.join(game_dir, "objective"), "w").write("fletching-test\n")
open(os.path.join(game_dir, "food-heals.xml"), "w").write("<map/>\n")

table = {"v": 1,
         "defaults": {"stale_ms": 60000, "min_action_interval_ms": 0,
                      "max_actions_per_min": 0, "inflight_timeout_ms": 1000},
         "rules": [], "unfinished": []}
gp.validate_config(table)
json.dump(table, open(os.path.join(game_dir, "learned-rules.json"), "w"))

# The spoken ages this fixture stands for: one line said over four minutes
# ago, its follow-up said one minute ago, both still unanswered.
now = gp.now_ms()
older, newer = now - 263000, now - 60000
json.dump({"v": 1, "ts": now, "tick": 42, "logged_in": True,
           "walking": False, "in_combat": False, "x": 121, "z": 648,
           "hits": 31, "hits_max": 31, "fatigue": 12, "sleeping": False,
           "talking_to_npc": False, "inventory": [], "messages": [],
           "players": [{"sidx": 11, "name": "Nearby Friend", "x": 121, "z": 648}],
           "npcs": [], "objects": [], "bounds": [], "ground_items": [],
           "skills": []},
          open(os.path.join(state_dir, "state.json"), "w"))
json.dump({"pending_messages": [
               {"id": 9001, "channel": "local", "sender": "Nearby Friend",
                "text": "how is the fletching going", "captured_ts": older},
               {"id": 9002, "channel": "local", "sender": "Nearby Friend",
                "text": "wow you are slow", "captured_ts": newer}],
           "seen_message_ids": [9001, 9002],
           "message_settle_until": 0},
          open(os.path.join(state_dir, "player-engine-state.json"), "w"))

out = io.StringIO()
with contextlib.redirect_stdout(out):
    verdict, code = gp.step_once(gp.load_config(), "fletching-test", "", 1000)
assert (verdict, code) == ("player-message", gp.EXIT_PLAYER_MESSAGE), (verdict, code)
line = next(l for l in out.getvalue().splitlines() if l.startswith("player-message "))
print(line, file=sys.stderr)

# The verdict names the newest message, so its own age is the answer to
# "how long ago did they last speak" — one minute, not zero.
assert " id=9002 " in line, line
assert re.search(r" now=\d\d:\d\d:\d\d ", line), line
assert re.search(r" received=\d\d:\d\d:\d\d ", line), line
assert " age=1m00s " in line, line

burst = json.loads(line.split("burst=", 1)[1].split(" session_renewed=")[0])
assert [item["id"] for item in burst] == [9001, 9002], burst
assert burst[0]["age"] == "4m23s", burst
assert burst[1]["age"] == "1m00s", burst
assert all(re.fullmatch(r"\d\d:\d\d:\d\d", item["received"]) for item in burst), burst

# The age is measured from the arrival stamp, not from the moment the engine
# happened to look: the same pending chain read later reads older.
with gp.player_state_lock():
    est = gp.load_player_state()
    for message in est["pending_messages"]:
        message["captured_ts"] -= 3600000
    gp.save_player_state(est)
out = io.StringIO()
with contextlib.redirect_stdout(out):
    gp.step_once(gp.load_config(), "fletching-test", "", 1000)
later = next(l for l in out.getvalue().splitlines() if l.startswith("player-message "))
print(later, file=sys.stderr)
assert " age=1h01m " in later, later
PY

python3 - "$GP" <<'PY' \
    && ok "an age reads the way a person says it, at every scale" \
    || fail "human_age must render seconds, minutes and hours"
import importlib.util, os, sys

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

assert gp.human_age(0) == "0s"
assert gp.human_age(-5000) == "0s"          # a clock that stepped backwards
assert gp.human_age(11500) == "11s"
assert gp.human_age(59999) == "59s"
assert gp.human_age(60000) == "1m00s"
assert gp.human_age(263000) == "4m23s"
assert gp.human_age(3723000) == "1h02m"
assert gp.clock_hms(0)                       # a stamp always renders a clock
PY

python3 - "$GP" <<'PY' \
    && ok "a message with no arrival stamp still reports the current clock" \
    || fail "an unstamped message must not cost the verdict its clock"
import importlib.util, json, os, sys

spec = importlib.util.spec_from_file_location("game_player_under_test", sys.argv[1])
gp = importlib.util.module_from_spec(spec)
sys.path.insert(0, os.path.dirname(sys.argv[1]))
spec.loader.exec_module(gp)

# A runner from an older code generation could have captured a message before
# arrival stamps existed. The clock is still knowable; the age is not, and is
# left out rather than invented.
stale = {"id": 7, "channel": "private", "sender": "Someone", "text": "hello"}
fields = gp.message_time_fields(stale)
assert set(fields) == {"now"}, fields
assert json.loads(gp.pending_message_burst([stale])) == [{"id": 7, "text": "hello"}]
PY
