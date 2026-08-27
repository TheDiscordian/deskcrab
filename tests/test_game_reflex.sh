#!/bin/bash
# The visible-state reflex engine (specs/game-reflex.md): the rule table and
# its validation gate, debounce, cooldowns, the one game-action slot and its
# conflict logging, stale-state and logged-out protection, the hold override,
# eat slot selection off the food table, flee/walk arithmetic and clamping,
# replay's side-effect-freedom, and the CLI that views and tunes it all.
# Run: bash tests/test_game_reflex.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
BG="$REPO/lib/betty-game"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# A small food table of our own: id 132 heals 3, id 373 heals 5.
FOOD_XML="$SANDBOX/food.xml"
cat > "$FOOD_XML" <<'EOF'
<map>
  <entry><int>132</int><int>3</int></entry>
  <entry><int>373</int><int>5</int></entry>
</map>
EOF

# snap <tick> <hits> [inv-json] [extra-json-pairs] — write a fresh snapshot.
# The JSON defaults are assigned, never ${3:-...}-defaulted: a brace inside a
# parameter-expansion default is where bash stops reading the default.
snap() {
    local inv='[{"id":132,"count":1},{"id":10,"count":5}]' extra='{}'
    [ $# -ge 3 ] && inv="$3"
    [ $# -ge 4 ] && extra="$4"
    python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" "$1" "$2" "$inv" "$extra" <<'PY'
import json, sys, time
path, tick, hits, inv, extra = sys.argv[1:6]
snap = {"v": 1, "ts": int(time.time() * 1000), "tick": int(tick),
        "logged_in": True, "hits": int(hits), "hits_max": 10, "fatigue": 10,
        "x": 120, "z": 650, "in_combat": False, "opponent": None,
        "inventory": json.loads(inv), "messages": []}
snap.update(json.loads(extra))
json.dump(snap, open(path, "w"))
PY
}

action_field() { sandbox_count_in "^$1" "$DESKCRAB_GAME_STATE_DIR/action.json"; }
decided() { sandbox_count_in "\"kind\":\"$1\"" "$DESKCRAB_GAME_STATE_DIR/decisions.jsonl"; }

echo "init and the rule table:"
check "init writes the default table" "$BG" init
check "the table file exists" test -f "$DESKCRAB_GAME_DIR/reflex-rules.json"
RULES_OUT="$("$BG" rules)"
check "warn ships enabled" contains "$RULES_OUT" "[on ] warn-low-health"
check "eat ships disabled" contains "$RULES_OUT" "[OFF] eat-low-health"
check "flee ships disabled" contains "$RULES_OUT" "[OFF] flee-starved"
"$BG" set warn-low-health priority 99 >/dev/null
check "a second init never overwrites edits" "$BG" init
check_eq "the edit survived" \
    "$(sandbox_count_in '"priority": 99' "$DESKCRAB_GAME_DIR/reflex-rules.json")" "1"
"$BG" set warn-low-health priority 5 >/dev/null
check "init --food-xml installs the food table" "$BG" init --food-xml "$FOOD_XML"
check "the food table landed" test -f "$DESKCRAB_GAME_DIR/food-heals.xml"

echo
echo "the validation gate (rule 9):"
refute "an unknown trigger key is refused" \
    "$BG" add bad1 --channel game --priority 1 --trigger hp_under=0.5 --action eat
refute "an out-of-range threshold is refused" \
    "$BG" set warn-low-health trigger.hp_below 1.5
refute "warn on the game channel is refused" \
    "$BG" add bad2 --channel game --priority 1 --trigger hp_below=0.5 --action warn --param text=x
refute "eat on the notice channel is refused" \
    "$BG" add bad3 --channel notice --priority 1 --trigger hp_below=0.5 --action eat
refute "requires_food and no_food together are refused" \
    "$BG" add bad4 --channel game --priority 1 --trigger requires_food=true --trigger no_food=true --action eat
refute "an unknown rule name is refused" "$BG" enable no-such-rule
refute "a second rule with a taken name is refused" \
    "$BG" add warn-low-health --channel notice --priority 1 --trigger hp_below=0.5 --action warn --param text=x
check "enable flips a rule on" "$BG" enable eat-low-health
contains "$("$BG" rules)" "[on ] eat-low-health" && ok "rules shows eat armed" || fail "rules shows eat armed"

echo
echo "the food-table refusal (rule 12):"
rm "$DESKCRAB_GAME_DIR/food-heals.xml"
snap 1 4
OUT="$("$BG" run --once 2>&1)" && fail "run must refuse without a food table" \
    || ok "run refuses while an enabled rule needs the missing food table"
contains "$OUT" "food" && ok "the refusal names the food table" || fail "the refusal names the food table" "$OUT"
"$BG" init --food-xml "$FOOD_XML" >/dev/null

echo
echo "firing, debounce, and the slot (rules 10, 12):"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/decisions.jsonl"
snap 1 4
"$BG" run --once
refute "hold_ticks 2: one low snapshot does not fire" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 2 4
"$BG" run --once
check "the second consecutive low snapshot fires" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
check_eq "the action is an eat" "$(action_field 'type=eat')" "1"
check_eq "of slot 0" "$(action_field 'slot=0')" "1"
check_eq "carrying the item id the engine saw" "$(action_field 'item=132')" "1"
check_eq "a fired event was logged" "$(decided fired)" "2"  # warn (hold 1) + eat
check_eq "warn fired independently on the notice channel" \
    "$(sandbox_count_in 'type=warn' "$DESKCRAB_GAME_STATE_DIR/notice.json")" "1"
check_eq "warn text interpolated the snapshot" \
    "$(sandbox_count_in 'text=health low: 4/10' "$DESKCRAB_GAME_STATE_DIR/notice.json")" "1"

echo
echo "eat_pick chooses among foods:"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["defaults"]["eat_pick"] = "max"
for r in cfg["rules"]:
    if r["name"] == "eat-low-health":
        r["hold_ticks"] = 1
json.dump(cfg, open(sys.argv[1], "w"))
PY
snap 3 4 '[{"id":132,"count":1},{"id":373,"count":1}]'
"$BG" run --once
check_eq "eat_pick max takes the bigger heal (slot 1, id 373)" "$(action_field 'slot=1')" "1"
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["defaults"]["eat_pick"] = "min"
json.dump(cfg, open(sys.argv[1], "w"))
PY
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 4 4 '[{"id":132,"count":1},{"id":373,"count":1}]'
"$BG" run --once
check_eq "eat_pick min wastes the least (slot 0, id 132)" "$(action_field 'slot=0')" "1"

echo
echo "a healthy player fires nothing:"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/action.json" \
      "$DESKCRAB_GAME_STATE_DIR/notice.json"
snap 5 9
"$BG" run --once
refute "no game action at 9/10" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
refute "no warn at 9/10" test -f "$DESKCRAB_GAME_STATE_DIR/notice.json"

echo
echo "cooldown and the in-flight gate (rule 10):"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/decisions.jsonl" \
      "$DESKCRAB_GAME_STATE_DIR/action.json"
# A cooldown far longer than any scheduler pause, so a slow box cannot let it
# lapse between the two snapshots and turn the assertion flaky.
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for r in cfg["rules"]:
    if r["name"] == "eat-low-health":
        r["cooldown_ms"] = 60000
json.dump(cfg, open(sys.argv[1], "w"))
PY
snap 6 4
"$BG" run --once
check "fired once" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 7 4
"$BG" run --once
check_eq "a second try inside the cooldown is logged, once" "$(decided cooldown-hold)" "2"  # eat + warn
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["defaults"]["min_action_interval_ms"] = 0
for r in cfg["rules"]:
    if r["name"] == "eat-low-health":
        r["cooldown_ms"] = 0
json.dump(cfg, open(sys.argv[1], "w"))
PY
snap 8 4
"$BG" run --once
check_eq "cooldown 0 but no receipt yet: the in-flight gate holds" "$(decided inflight-hold)" "1"
LAST_ID="$(python3 -c "import json;print(json.load(open('$DESKCRAB_GAME_STATE_DIR/engine-state.json'))['inflight']['id'])")"
python3 -c "import json,time;json.dump({'id':$LAST_ID,'status':'done','ts':int(time.time()*1000)},open('$DESKCRAB_GAME_STATE_DIR/receipt.json','w'))"
snap 9 4
"$BG" run --once
check_eq "the receipt was consumed and logged" "$(decided receipt)" "1"
check_eq "and the slot freed: it fired again" "$(decided fired)" "3"  # warn once + eat twice

echo
echo "the per-minute cap (rule 10):"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/decisions.jsonl" \
      "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["defaults"]["max_actions_per_min"] = 2
json.dump(cfg, open(sys.argv[1], "w"))
PY
for t in 10 11 12; do
    snap "$t" 4
    "$BG" run --once
    ID="$(python3 -c "
import json
try: print(json.load(open('$DESKCRAB_GAME_STATE_DIR/engine-state.json'))['inflight']['id'])
except Exception: print(0)")"
    [ "$ID" != 0 ] && python3 -c "import json,time;json.dump({'id':$ID,'status':'done','ts':int(time.time()*1000)},open('$DESKCRAB_GAME_STATE_DIR/receipt.json','w'))"
done
check_eq "two fired, the third hit the cap" "$(decided cap)" "1"
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["defaults"]["max_actions_per_min"] = 20
json.dump(cfg, open(sys.argv[1], "w"))
PY

echo
echo "stale state and logged-out protection (rule 11):"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/decisions.jsonl" \
      "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" <<'PY'
import json, sys, time
snap = {"v": 1, "ts": int(time.time() * 1000) - 5000, "tick": 20,
        "logged_in": True, "hits": 4, "hits_max": 10, "fatigue": 10,
        "x": 120, "z": 650, "in_combat": False, "opponent": None,
        "inventory": [{"id": 132, "count": 1}], "messages": []}
json.dump(snap, open(sys.argv[1], "w"))
PY
"$BG" run --once
check_eq "a 5s-old snapshot is stale, logged" "$(decided stale)" "1"
refute "and fires nothing" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" <<'PY'
import json, sys, time
json.dump({"v": 1, "ts": int(time.time() * 1000), "tick": 21, "logged_in": False},
          open(sys.argv[1], "w"))
PY
"$BG" run --once
check_eq "a logged-out snapshot is logged" "$(decided logged-out)" "1"
refute "and fires nothing" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for r in cfg["rules"]:
    if r["name"] == "eat-low-health":
        r["hold_ticks"] = 2
json.dump(cfg, open(sys.argv[1], "w"))
PY
snap 22 4
"$BG" run --once
refute "logged-out reset the debounce streak: one low snapshot after it does not fire" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"

echo
echo "the same tick never acts twice (rule 11):"
snap 23 4
"$BG" run --once
check "tick 23 fired (streak 2)" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for r in cfg["rules"]:
    if r["name"] == "eat-low-health":
        r["cooldown_ms"] = 0
json.dump(cfg, open(sys.argv[1], "w"))
PY
"$BG" run --once
refute "the same tick re-evaluated fires nothing" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"

echo
echo "the hold override (rule 15):"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/decisions.jsonl" \
      "$DESKCRAB_GAME_STATE_DIR/action.json"
"$BG" hold >/dev/null
snap 30 4
"$BG" run --once
refute "held: nothing is emitted" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
check_eq "the hold transition was logged" "$(decided hold)" "1"
"$BG" resume >/dev/null
snap 31 4
"$BG" run --once
check_eq "the resume transition was logged" "$(decided resume)" "1"

echo
echo "conflict: one game slot, priority wins (rule 10):"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/decisions.jsonl" \
      "$DESKCRAB_GAME_STATE_DIR/action.json"
"$BG" add panic-walk --channel game --priority 1 --cooldown-ms 0 --hold-ticks 1 \
    --trigger hp_below=0.5 --action walk --param x=125 --param z=650 >/dev/null
"$BG" enable panic-walk >/dev/null
python3 - "$DESKCRAB_GAME_DIR/reflex-rules.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for r in cfg["rules"]:
    if r["name"] == "eat-low-health":
        r["hold_ticks"] = 1
json.dump(cfg, open(sys.argv[1], "w"))
PY
snap 40 4
"$BG" run --once
check_eq "the higher-priority eat took the slot" "$(action_field 'type=eat')" "1"
check_eq "the loser was logged as a conflict loss" "$(decided conflict-loss)" "1"
"$BG" disable panic-walk >/dev/null

echo
echo "flee and walk arithmetic (rule 13):"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/action.json"
"$BG" disable eat-low-health >/dev/null
"$BG" enable flee-starved >/dev/null
"$BG" set flee-starved hold_ticks 1 >/dev/null
snap 50 3 '[]' '{"opponent":{"x":123,"z":650}}'
"$BG" run --once
check_eq "flee walked directly away from the opponent" "$(action_field 'x=115')" "1"
check_eq "on the unchanged axis it stayed" "$(action_field 'z=650')" "1"
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 51 3 '[]'
"$BG" run --once
check_eq "with no opponent flee takes the configured direction (south, z+5)" \
    "$(action_field 'z=655')" "1"
"$BG" disable flee-starved >/dev/null
"$BG" enable panic-walk >/dev/null
"$BG" set panic-walk action.x 200 >/dev/null
rm -f "$DESKCRAB_GAME_STATE_DIR/engine-state.json" "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 52 4
"$BG" run --once
check_eq "a far walk target is clamped to 15 tiles (120 -> 135)" "$(action_field 'x=135')" "1"
"$BG" disable panic-walk >/dev/null
"$BG" enable eat-low-health >/dev/null

echo
echo "replay is side-effect-free (rule 16):"
RECORDING="$SANDBOX/recording.jsonl"
python3 - "$RECORDING" <<'PY'
import json, sys
t = 1700000000000
rows = []
for i, tick in enumerate((1, 2)):
    rows.append({"v": 1, "ts": t + i * 700, "tick": tick, "logged_in": True,
                 "hits": 4, "hits_max": 10, "fatigue": 10, "x": 120, "z": 650,
                 "in_combat": False, "opponent": None,
                 "inventory": [{"id": 132, "count": 1}], "messages": []})
open(sys.argv[1], "w").write("\n".join(json.dumps(r) for r in rows) + "\n")
PY
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json" "$DESKCRAB_GAME_STATE_DIR/notice.json"
REPLAY_OUT="$("$BG" replay "$RECORDING")"
contains "$REPLAY_OUT" '"kind":"fired"' && ok "replay reports what would have fired" \
    || fail "replay reports what would have fired" "$REPLAY_OUT"
refute "replay wrote no action file" test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
refute "replay wrote no notice file" test -f "$DESKCRAB_GAME_STATE_DIR/notice.json"

echo
echo "the viewing CLI:"
snap 60 4
STATE_OUT="$("$BG" state)"
contains "$STATE_OUT" "hits: 4/10" && ok "state shows the health" || fail "state shows the health" "$STATE_OUT"
contains "$STATE_OUT" "(food, heals 3)" && ok "state marks food off the table" \
    || fail "state marks food off the table" "$STATE_OUT"
ACTIONS_OUT="$("$BG" actions)"
contains "$ACTIONS_OUT" "eat" && ok "actions lists the vocabulary" || fail "actions lists the vocabulary"
LOG_OUT="$("$BG" log -n 5)"
contains "$LOG_OUT" '"kind"' && ok "log tails the decisions" || fail "log tails the decisions" "$LOG_OUT"
check "remove takes a rule out" "$BG" remove panic-walk
refute "and it is gone" grep -q panic-walk "$DESKCRAB_GAME_DIR/reflex-rules.json"
