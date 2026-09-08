#!/bin/bash
# The held pair is answerable from the learned table (specs/game-player.md
# rule 5's use-item-item). A knife against logs is the first half of a
# fletching loop whose second half (the make menu) is already a reflex, so
# leaving the pair to the hand cost a model turn per batch. The pair compiles
# only from live held identities — never a slot, never a pointer — and a rule
# whose inventory cannot satisfy it stands aside for ordinary play.
# Run: bash tests/test_game_player_held_pair.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# snap <tick> <inventory-json> — a logged-in fletcher beside one reachable pile.
snap() {
    python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" "$1" "$2" <<'PY'
import json, sys, time
path, tick, inventory = sys.argv[1:4]
snap = {"v": 1, "ts": int(time.time() * 1000), "tick": int(tick),
        "logged_in": True, "hits": 10, "hits_max": 10, "fatigue": 0,
        "x": 127, "z": 669, "walking": False, "in_combat": False,
        "talking_to_npc": False, "dialogue_open": False, "dialogue_options": [],
        "opponent": None,
        "inventory": json.loads(inventory),
        "messages": [{"id": 1, "channel": "game", "text": "Welcome to the game"}],
        "npcs": [],
        "ground_items": [{"id": 35, "x": 127, "z": 670, "reachable": True,
                          "path_distance": 1}]}
json.dump(snap, open(path, "w"))
PY
}

KNIFE_AND_LOGS='[{"id": 13, "count": 1}, {"id": 14, "count": 6}]'
KNIFE_ONLY='[{"id": 13, "count": 1}]'
ONE_LOG='[{"id": 14, "count": 1}]'
TWO_LOG_SLOTS='[{"id": 14, "count": 1}, {"id": 14, "count": 1}]'

python3 "$GP" init >/dev/null 2>&1 || true
python3 "$GP" objective "Leaderboard competition" >/dev/null
python3 "$GP" activity fletching >/dev/null

echo
echo "the action is a closed-vocabulary member with two held identities:"
refute "use-item-item refuses a missing target" \
    python3 "$GP" learn bad-pair-no-target --priority 10 \
        --trigger activity_is=fletching --action use-item-item --param item=13
refute "use-item-item refuses a distance cap it cannot honour" \
    python3 "$GP" learn bad-pair-capped --priority 10 \
        --trigger activity_is=fletching --action use-item-item \
        --param item=13 --param target=14 --param within=3
refute "use-item-item refuses a slot instead of an identity" \
    python3 "$GP" learn bad-pair-slot --priority 10 \
        --trigger activity_is=fletching --action use-item-item \
        --param item=13 --param slot=2
check "the fletching pair rule is learnable" \
    python3 "$GP" learn fletching-cut-logs-test --priority 844 \
        --trigger activity_is=fletching --trigger inventory_has=13 \
        --trigger inventory_has=14 --trigger out_of_combat=true \
        --action use-item-item --param item=13 --param target=14 \
        --note "Knife 13 on Logs 14 opens the make menu."
check "a quieter ordinary loot rule shares the table" \
    python3 "$GP" learn loot-mind-rune-test --priority 100 \
        --trigger ground_item_visible=35 --action take-ground --param item=35

echo
echo "the pair dispatches two item identities and nothing else (spec rules 5, 7):"
snap 300 "$KNIFE_AND_LOGS"
OUT="$(python3 "$GP" step --max 1 2>&1)"; CODE=$?
contains "$OUT" "fletching-cut-logs-test" \
    && ok "the pair rule wins the slot" \
    || fail "the pair rule wins the slot" "$OUT"
check "the dispatched action carries item and target alone" \
    sh -c "grep -q '^type=use-item-item$' '$DESKCRAB_GAME_STATE_DIR/action.json' \
        && grep -q '^item=13$' '$DESKCRAB_GAME_STATE_DIR/action.json' \
        && grep -q '^target=14$' '$DESKCRAB_GAME_STATE_DIR/action.json'"
refute "no slot, pane, or pointer coordinate rides the file" \
    sh -c "grep -qE '^(slot|button|x|z)=' '$DESKCRAB_GAME_STATE_DIR/action.json'"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"

echo
echo "an unheld half stands aside for ordinary play:"
snap 301 "$KNIFE_ONLY"
OUT="$(python3 "$GP" step --max 1 2>&1)"; CODE=$?
refute "the empty-handed pair never dispatches" \
    sh -c "grep -q 'type=use-item-item' '$DESKCRAB_GAME_STATE_DIR/action.json'"
contains "$OUT" "loot-mind-rune-test" \
    && ok "and the quieter loot rule owns the pass" \
    || fail "and the quieter loot rule owns the pass" "$OUT"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"

echo
echo "the same identity twice needs two distinct slots:"
check "a same-id pair is learnable" \
    python3 "$GP" learn same-id-pair-test --priority 843 \
        --trigger activity_is=fletching --trigger inventory_has=14 \
        --action use-item-item --param item=14 --param target=14
python3 "$GP" disable fletching-cut-logs-test >/dev/null
snap 302 "$ONE_LOG"
OUT="$(python3 "$GP" step --max 1 2>&1)"; CODE=$?
refute "one slot cannot be used on itself" \
    sh -c "grep -q 'type=use-item-item' '$DESKCRAB_GAME_STATE_DIR/action.json'"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
snap 303 "$TWO_LOG_SLOTS"
python3 "$GP" step --max 1 >/dev/null 2>&1
check "two slots of the same identity compile" \
    sh -c "grep -q '^type=use-item-item$' '$DESKCRAB_GAME_STATE_DIR/action.json' \
        && grep -q '^target=14$' '$DESKCRAB_GAME_STATE_DIR/action.json'"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 "$GP" remove same-id-pair-test >/dev/null
python3 "$GP" enable fletching-cut-logs-test >/dev/null

echo
echo "replays pin the compiled semantics (spec rule 17):"
case_snapshot() { snap "$1" "$2"; cp "$DESKCRAB_GAME_STATE_DIR/state.json" "$SANDBOX/case.json"; }
add_case() { # NAME EXPECT [EXPECT-ACTION-JSON]
    local name="$1" expect="$2"
    if [ $# -ge 3 ]; then
        python3 "$GP" test add "$name" --expect "$expect" \
            --objective "Leaderboard competition" --activity fletching \
            --snapshot "$SANDBOX/case.json" --expect-action "$3"
    else
        python3 "$GP" test add "$name" --expect "$expect" \
            --objective "Leaderboard competition" --activity fletching \
            --snapshot "$SANDBOX/case.json"
    fi
}
case_snapshot 304 "$KNIFE_AND_LOGS"
check "the held pair compiles to exactly item 13 on target 14" \
    add_case held-pair-cuts fletching-cut-logs-test \
        '{"type":"use-item-item","item":13,"target":14,"within":null,"x":null,"z":null}'
case_snapshot 305 "$KNIFE_ONLY"
check "no logs, no pair: ordinary play owns the pass" \
    add_case no-logs-loot-runs loot-mind-rune-test
check "the suite the mutation gate replays is green" \
    sh -c "python3 '$GP' test run | grep -q '0 failure'"

echo
echo "a server make-menu hands control to its answer without a timeout:"
python3 - "$SANDBOX_REPO/lib" <<'PY' && ok "server menu completes the pair, never the unfinished product" \
    || fail "server menu completes the pair, never the unfinished product"
import copy,sys,time
sys.path.insert(0,sys.argv[1])
import game_player as gp
now=int(time.time()*1000)
base=dict(ts=now,tick=1,logged_in=True,dialogue_open=False,dialogue_options=[],
          inventory=[{'id':13,'count':1},{'id':14,'count':6}],messages=[])
obs=gp.make_action_observation(1,'use-item-item',['item=13','target=14'],base)
def after(**kw):
    s=copy.deepcopy(base);s.update(ts=now+1,tick=2);s.update(kw);return s
menu=after(dialogue_open=True,dialogue_options=['Make arrow shafts','Make shortbow','Make longbow'])
result=gp.action_completion(obs,menu)
assert result['result']=='done' and result['xp'] is None and result['inventory'] is None
assert 'dialogue-menu-opened:true' in result['state']
assert gp.action_completion(obs,after(right_click_menu_open=True)) is None
assert gp.action_completion(obs,after(selected_inventory_item=13)) is None
assert gp.action_completion(obs,after(ui_panel_open=True)) is None
assert gp.action_completion(obs,after(dialogue_open=True)) is None
assert gp.action_completion(obs,after(messages=[{'id':1,'channel':'game','text':'What would you like to make?'}])) is None
old_menu=gp.make_action_observation(2,'use-item-item',['item=13','target=14'],menu)
menu.update(tick=3,ts=now+2)
assert gp.action_completion(old_menu,menu) is None
# The follow-up answer cannot be reported complete just because this menu closes.
choice=gp.make_action_observation(3,'choose-dialogue',['text=Make longbow'],menu)
closed=after();closed.update(tick=4,ts=now+3)
assert gp.action_completion(choice,closed) is None
closed['inventory']=[{'id':13,'count':1},{'id':14,'count':5},{'id':276,'count':1}]
assert gp.action_completion(choice,closed)['result']=='done'
PY
