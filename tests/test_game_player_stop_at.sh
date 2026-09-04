#!/bin/bash
# Spec rule 11d: a stopping level named out loud is a mechanical, fail-closed
# stop. The declaration is structure in $DESKCRAB_GAME_DIR/stop-at.json — the
# skill, the ceiling, the governed activity, and what reaching it does — and
# the check is the trigger layer's, in the fatigue_below shape: with a stop at
# Woodcutting 30 armed, the chop rules do not fire at level 30 in a replay,
# `activity woodcutting` is refused with the ceiling named, `stop-at --clear`
# restores both, and a record that is malformed or cannot read its skill fails
# CLOSED (activity rules do not fire) rather than silently permitting the
# activity. The resident runner performs the declared consequence — clear the
# activity, switch, or halt — instead of chopping past the spoken number.
# Run: bash tests/test_game_player_stop_at.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
GP="$REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
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

STOP_FILE="$DESKCRAB_GAME_DIR/stop-at.json"

# live_state <woodcut-level|none> [firemaking-level] — the bridge snapshot the
# runner and the doors read, fresh and logged in.
live_state() {
    python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" "$1" "${2:-}" <<'PY'
import json, sys, time
path, wc, fm = sys.argv[1], sys.argv[2], sys.argv[3]
snap = {"v": 1, "ts": int(time.time() * 1000), "tick": int(time.time()),
        "logged_in": True, "hits": 10, "hits_max": 10, "fatigue": 0,
        "x": 120, "z": 648, "walking": False, "in_combat": False,
        "talking_to_npc": False, "opponent": None,
        "inventory": [{"id": 376, "count": 1}],
        "messages": [{"text": "Welcome to the game"}],
        "npcs": [], "players": [], "bounds": [], "ground_items": [],
        "objects": [{"id": 1, "x": 121, "z": 648}],
        "shop_open": False, "shop_items": [],
        "bank_open": False, "bank_items": [],
        "skills": []}
if wc != "none":
    snap["skills"].append({"id": 8, "name": "Woodcutting",
                           "level": int(wc), "xp": 1000 * int(wc)})
if fm:
    snap["skills"].append({"id": 11, "name": "Firemaking",
                           "level": int(fm), "xp": 500 * int(fm)})
json.dump(snap, open(path, "w"))
PY
}

# replay_snap <file> <woodcut-level|none> [in-combat] — a recorded snapshot
# for the rule-17 replay cases.
replay_snap() {
    python3 - "$1" "$2" "${3:-false}" <<'PY'
import json, sys
path, wc, combat = sys.argv[1], sys.argv[2], sys.argv[3]
snap = {"tick": 500, "x": 120, "z": 648, "walking": False,
        "in_combat": combat == "true",
        "inventory": [{"id": 376, "count": 1}], "messages": [],
        "npcs": [], "players": [], "bounds": [], "ground_items": [],
        "objects": [{"id": 1, "x": 121, "z": 648}],
        "shop_open": False, "shop_items": [],
        "bank_open": False, "bank_items": [], "skills": []}
if wc != "none":
    snap["skills"] = [{"id": 8, "name": "Woodcutting",
                       "level": int(wc), "xp": 1000 * int(wc)}]
json.dump(snap, open(path, "w"))
PY
}

decided() { sandbox_count_in "\"kind\":\"$1\"" "$DESKCRAB_GAME_STATE_DIR/player-decisions.jsonl"; }

python3 "$GP" init >/dev/null
live_state 29

echo "the declaration door (spec rule 11d):"
CODE=0; OUT="$(python3 "$GP" stop-at Woodcutting 30 someday 2>&1)" || CODE=$?
check_eq "a THEN outside clear|halt|switch is refused" "$CODE" "1"
CODE=0; OUT="$(python3 "$GP" stop-at Woodcutting 0 clear 2>&1)" || CODE=$?
check_eq "a ceiling below 1 is refused" "$CODE" "1"
CODE=0; OUT="$(python3 "$GP" stop-at Woodcutting 100 clear 2>&1)" || CODE=$?
check_eq "a ceiling above 99 is refused" "$CODE" "1"
CODE=0; OUT="$(python3 "$GP" stop-at Woodcutting 30 switch woodcutting 2>&1)" || CODE=$?
check_eq "switching back into the governed activity is refused" "$CODE" "1"
contains "$OUT" "cannot switch back into what it stops" \
    && ok "and the refusal says why" || fail "and the refusal says why" "$OUT"
CODE=0; OUT="$(python3 "$GP" stop-at Woodcuting 30 clear 2>&1)" || CODE=$?
check_eq "a skill the client does not publish is refused" "$CODE" "1"
contains "$OUT" "Woodcutting" \
    && ok "naming the published skills" || fail "naming the published skills" "$OUT"
check_eq "no refusal armed a record" "$(python3 "$GP" stop-at)" "(none)"

check "a spoken ceiling becomes one structured command" \
    python3 "$GP" stop-at Woodcutting 30 clear
check "the record lives beside the plan in the game dir" test -f "$STOP_FILE"
OUT="$(python3 "$GP" stop-at)"
contains "$OUT" "Woodcutting 30" && ok "bare stop-at reads the ceiling back" \
    || fail "bare stop-at reads the ceiling back" "$OUT"
contains "$OUT" "level: 29 (below ceiling)" \
    && ok "beside the live level" || fail "beside the live level" "$OUT"
check_eq "the declaration is a decision event" "$(decided stop-declared)" "1"

echo
echo "the ceiling closes the chop trigger in replay (acceptance 1):"
check "the chop rule can be learned" \
    python3 "$GP" learn woodcut-chop-visible-tree --priority 40 \
        --trigger activity_is=woodcutting --trigger object_visible=1 \
        --action interact-object --param obj=1 --param cmd=1
replay_snap "$SANDBOX/wc29.json" 29
replay_snap "$SANDBOX/wc30.json" 30
replay_snap "$SANDBOX/wc-none.json" none
check "below the ceiling the chop rule still fires in replay" \
    python3 "$GP" test add chop-fires-below-ceiling --activity woodcutting \
        --expect woodcut-chop-visible-tree --snapshot "$SANDBOX/wc29.json"
check "at level 30 the chop rule does not fire in replay" \
    python3 "$GP" test add chop-stops-at-ceiling --activity woodcutting \
        --expect none --snapshot "$SANDBOX/wc30.json"
check "a snapshot that cannot read the skill fails closed in replay" \
    python3 "$GP" test add chop-stops-unread --activity woodcutting \
        --expect none --snapshot "$SANDBOX/wc-none.json"
check "the replay suite holds all three" python3 "$GP" test

check "an unscoped safety rule can be learned beside the ceiling" \
    python3 "$GP" learn flee-fight --priority 1000 \
        --trigger in_combat=true \
        --action retreat --param distance=1 --param dx=0 --param dz=1
replay_snap "$SANDBOX/fight30.json" 30 true
check "safety without an activity scope stays armed at the ceiling" \
    python3 "$GP" test add flee-still-armed-at-ceiling --activity woodcutting \
        --expect flee-fight --snapshot "$SANDBOX/fight30.json"

echo
echo "the switch back in is refused with the ceiling named (acceptance 2):"
live_state 30
CODE=0; OUT="$(python3 "$GP" activity woodcutting 2>&1)" || CODE=$?
check_eq "activity woodcutting is refused at the ceiling" "$CODE" "1"
contains "$OUT" "Woodcutting 30" \
    && ok "the refusal names the ceiling" || fail "the refusal names the ceiling" "$OUT"
contains "$OUT" "level 30" \
    && ok "and the level that reached it" || fail "and the level that reached it" "$OUT"
refute "the refused selection wrote no activity" \
    test -f "$DESKCRAB_GAME_DIR/activity"
check "an activity the ceiling does not govern stays selectable" \
    python3 "$GP" activity banking
python3 "$GP" activity --clear >/dev/null
live_state none
CODE=0; OUT="$(python3 "$GP" activity woodcutting 2>&1)" || CODE=$?
check_eq "an unreadable live level fails closed at the door" "$CODE" "1"
contains "$OUT" "cannot be read" \
    && ok "saying the level is unread, not the ceiling reached" \
    || fail "saying the level is unread, not the ceiling reached" "$OUT"

echo
echo "clearing the stop restores both behaviours (acceptance 3):"
live_state 30
check "stop-at --clear retires the ceiling" python3 "$GP" stop-at --clear
check "to an explicit cleared record, never a deleted file" test -f "$STOP_FILE"
contains "$(cat "$STOP_FILE")" '"cleared": true' \
    && ok "the tombstone says cleared" || fail "the tombstone says cleared"
check_eq "bare stop-at reads none again" "$(python3 "$GP" stop-at)" "(none)"
CODE=0; OUT="$(python3 "$GP" test 2>&1)" || CODE=$?
check_eq "the at-ceiling replay case flips: the chop rule fires again" "$CODE" "1"
contains "$OUT" "chop-stops-at-ceiling" \
    && ok "and the flipped case is the ceiling one" \
    || fail "and the flipped case is the ceiling one" "$OUT"
python3 "$GP" test remove chop-stops-at-ceiling >/dev/null
python3 "$GP" test remove chop-stops-unread >/dev/null
check "with the ceiling cases retired the suite is green again" python3 "$GP" test
check "activity woodcutting is selectable again at level 30" \
    python3 "$GP" activity woodcutting
python3 "$GP" activity --clear >/dev/null

echo
echo "a malformed or field-missing record fails CLOSED (acceptance 4):"
printf '{not json' > "$STOP_FILE"
CODE=0; OUT="$(python3 "$GP" test 2>&1)" || CODE=$?
check_eq "unparseable record: activity rules do not fire in replay" "$CODE" "1"
contains "$OUT" "chop-fires-below-ceiling" \
    && ok "even below the ceiling — the record cannot be trusted" \
    || fail "even below the ceiling — the record cannot be trusted" "$OUT"
live_state 29
CODE=0; OUT="$(python3 "$GP" activity woodcutting 2>&1)" || CODE=$?
check_eq "unparseable record: activity selection is refused" "$CODE" "1"
contains "$OUT" "fails closed" \
    && ok "the refusal says it fails closed" \
    || fail "the refusal says it fails closed" "$OUT"
contains "$OUT" "stop-at --clear" \
    && ok "and names the clearing door" || fail "and names the clearing door" "$OUT"
printf '{"v": 1, "skill": "Woodcutting"}' > "$STOP_FILE"
CODE=0; OUT="$(python3 "$GP" test 2>&1)" || CODE=$?
check_eq "a record missing its fields is just as closed in replay" "$CODE" "1"
CODE=0; OUT="$(python3 "$GP" activity woodcutting 2>&1)" || CODE=$?
check_eq "and at the activity door" "$CODE" "1"
CODE=0; OUT="$(python3 "$GP" stop-at 2>&1)" || CODE=$?
check_eq "bare stop-at reports the invalid record loudly" "$CODE" "1"
check "stop-at --clear recovers from the broken record" python3 "$GP" stop-at --clear
check "and the replay suite is green again" python3 "$GP" test
check "and the activity door opens again" python3 "$GP" activity woodcutting

echo
echo "the resident runner performs the declared consequence:"
# THEN clear: reaching the ceiling clears the activity instead of chopping on.
check "the ceiling re-arms over a below-ceiling activity" \
    python3 "$GP" stop-at Woodcutting 30 clear
live_state 30
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "the step verdict is stop-reached" "$(echo "$OUT" | grep -c '^stop-reached')" "1"
check_eq "mapped to the model-may-reason exit" "$CODE" "4"
contains "$OUT" "skill=Woodcutting" && contains "$OUT" "ceiling=30" \
    && ok "the verdict names the ceiling" || fail "the verdict names the ceiling" "$OUT"
refute "the activity was cleared, not chopped past" \
    test -f "$DESKCRAB_GAME_DIR/activity"
refute "no action was dispatched" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
contains "$(cat "$STOP_FILE")" '"reached_ts"' \
    && ok "the record carries reached_ts" || fail "the record carries reached_ts"
check_eq "the reach is one decision event" "$(decided stop-reached)" "1"
check_eq "the cleared activity closed its iteration honestly" \
    "$(sandbox_count_in 'stop-reached:Woodcutting-30' "$DESKCRAB_GAME_DIR/activity-history.jsonl")" "1"
contains "$(cat "$DESKCRAB_GAME_DIR/outcome-queue.jsonl")" '"kind":"stop-reached"' \
    && ok "and the outcome queue tells the deliberate hand" \
    || fail "and the outcome queue tells the deliberate hand"

# THEN switch: the declared next activity is selected through the ordinary
# iteration bookkeeping.
python3 "$GP" stop-at --clear >/dev/null
live_state 29 1
python3 "$GP" activity woodcutting >/dev/null
check "a switch consequence can be declared" \
    python3 "$GP" stop-at Woodcutting 30 switch firemaking
live_state 30 1
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "reaching the ceiling switches instead of chopping on" "$CODE" "4"
contains "$OUT" "then=switch:firemaking" \
    && ok "the verdict says where play went" || fail "the verdict says where play went" "$OUT"
check_eq "the activity file now reads the declared target" \
    "$(cat "$DESKCRAB_GAME_DIR/activity")" "firemaking"
CODE=0; OUT="$(python3 "$GP" activity woodcutting 2>&1)" || CODE=$?
check_eq "and the switch back into woodcutting stays refused" "$CODE" "1"

# THEN halt: ordinary evaluation stops entirely, pass after pass, while the
# activity itself is left standing as evidence of where play halted.
check "a halt ceiling can replace the switch one" \
    python3 "$GP" stop-at Firemaking 5 halt --activity firemaking
live_state 30 5
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "reaching a halt ceiling stops evaluation" "$CODE" "4"
contains "$OUT" "then=halt" && ok "saying it halts" || fail "saying it halts" "$OUT"
check_eq "the halted activity is left standing" \
    "$(cat "$DESKCRAB_GAME_DIR/activity")" "firemaking"
CODE=0; OUT="$(python3 "$GP" step)" || CODE=$?
check_eq "and the next pass halts again" "$CODE" "4"

refute "no model CLI was ever invoked" test -f "$SANDBOX/model-called"
