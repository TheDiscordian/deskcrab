#!/bin/bash
# The open option menu is answerable from the learned table (specs/game-player.md
# rule 5's choose-dialogue). A skill that re-asks "What would you like to make?"
# after every batch is a reflex loop, not a model turn per log — but only the
# rules that answer the question may act while the game waits on it, and a menu
# no rule answers still falls back to the hand.
# Run: bash tests/test_game_player_dialogue_answer.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

GP="$SANDBOX_REPO/lib/game_player.py"
export DESKCRAB_GAME_STATE_DIR="$SANDBOX/gstate"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
export BETTY_OPENRSC_MEMORY="$SANDBOX/no-such-memory"
mkdir -p "$DESKCRAB_GAME_STATE_DIR" "$DESKCRAB_GAME_DIR"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# snap <tick> <extra-json> — a logged-in fletcher beside one reachable pile.
snap() {
    python3 - "$DESKCRAB_GAME_STATE_DIR/state.json" "$1" "$2" <<'PY'
import json, sys, time
path, tick, extra = sys.argv[1:4]
snap = {"v": 1, "ts": int(time.time() * 1000), "tick": int(tick),
        "logged_in": True, "hits": 10, "hits_max": 10, "fatigue": 0,
        "x": 127, "z": 669, "walking": False, "in_combat": False,
        "talking_to_npc": False, "dialogue_open": False, "dialogue_options": [],
        "opponent": None,
        "inventory": [{"id": 14, "count": 11}, {"id": 13, "count": 1}],
        "messages": [{"id": 1, "channel": "game", "text": "Welcome to the game"}],
        "npcs": [],
        "ground_items": [{"id": 35, "x": 127, "z": 670, "reachable": True,
                          "path_distance": 1}]}
snap.update(json.loads(extra))
json.dump(snap, open(path, "w"))
PY
}

MENU='{"talking_to_npc": true, "dialogue_open": true,
       "dialogue_options": ["Arrow shafts", "Shortbow", "Longbow"]}'

python3 "$GP" init >/dev/null 2>&1 || true
python3 "$GP" objective "Leaderboard competition" >/dev/null
python3 "$GP" activity fletching >/dev/null

echo
echo "the action is a closed-vocabulary member with one honest parameter:"
refute "choose-dialogue refuses an empty option text" \
    python3 "$GP" learn bad-empty-dialogue --priority 10 \
        --trigger activity_is=fletching --action choose-dialogue --param text=
refute "choose-dialogue refuses a distance cap it cannot honour" \
    python3 "$GP" learn bad-capped-dialogue --priority 10 \
        --trigger activity_is=fletching --action choose-dialogue \
        --param text="Arrow shafts" --param within=3
check "a fletching answer rule is learnable" \
    python3 "$GP" learn fletching-answer-make-menu --priority 845 \
        --trigger activity_is=fletching --action choose-dialogue \
        --param text="arrow shafts" \
        --note "The make menu re-asks after every batch."
check "a louder ordinary loot rule shares the table" \
    python3 "$GP" learn loot-mind-rune-test --priority 900 \
        --trigger ground_item_visible=35 --action take-ground --param item=35

echo
echo "an open question owns the body until it is answered (spec rules 5, 7):"
snap 200 "$MENU"
OUT="$(python3 "$GP" step --max 1 2>&1)"; CODE=$?
contains "$OUT" "fletching-answer-make-menu" \
    && ok "the answering rule wins the slot" \
    || fail "the answering rule wins the slot" "$OUT"
refute "the higher-priority loot rule cannot walk out of the question" \
    sh -c "grep -q 'type=take-ground' '$DESKCRAB_GAME_STATE_DIR/action.json'"
check "the dispatched action is the option's own text, no index or coordinate" \
    sh -c "grep -q '^text=Arrow shafts$' '$DESKCRAB_GAME_STATE_DIR/action.json' \
        && grep -q '^type=choose-dialogue$' '$DESKCRAB_GAME_STATE_DIR/action.json'"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"

python3 "$GP" disable fletching-answer-make-menu >/dev/null
snap 201 "$MENU"
CODE=0; OUT="$(python3 "$GP" step --max 1 2>&1)" || CODE=$?
check_eq "with no answering rule the menu is still the hand's business" "$CODE" "4"
contains "$OUT" "npc-dialogue-choice" \
    && ok "and the fallback verdict names the open choice" \
    || fail "and the fallback verdict names the open choice" "$OUT"
refute "nothing else acted past the open question" \
    test -f "$DESKCRAB_GAME_STATE_DIR/action.json"
python3 "$GP" enable fletching-answer-make-menu >/dev/null

echo
echo "an exchange between speech states is still nobody's turn:"
snap 202 '{"talking_to_npc": true, "dialogue_open": false, "dialogue_options": []}'
CODE=0; OUT="$(python3 "$GP" step --max 1 2>&1)" || CODE=$?
check_eq "a speech stage waits" "$CODE" "3"
contains "$OUT" "npc-dialogue-in-progress" \
    && ok "and says so" || fail "and says so" "$OUT"
rm -f "$DESKCRAB_GAME_STATE_DIR/action.json"

echo
echo "the live menu is the rule's eligibility, and replays read it (spec rule 17):"
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

case_snapshot 203 '{}'
check "no menu, no answer: ordinary play owns the pass" \
    add_case no-menu-loot-runs loot-mind-rune-test
case_snapshot 204 "$MENU"
check "the open menu is answered with the option's own current text" \
    add_case open-menu-answered fletching-answer-make-menu \
        '{"type":"choose-dialogue","text":"Arrow shafts","within":null,"item":null}'
case_snapshot 205 '{"talking_to_npc": true, "dialogue_open": true,
                    "dialogue_options": ["Shortbow", "Longbow"]}'
check "an option this menu does not offer never compiles" \
    add_case absent-option-refuses loot-mind-rune-test
case_snapshot 206 '{"talking_to_npc": true, "dialogue_open": true,
                    "dialogue_options": ["Bronze arrow shafts", "Oak arrow shafts"]}'
check "an ambiguous fragment refuses instead of guessing a row" \
    add_case ambiguous-option-refuses loot-mind-rune-test
check "the suite the mutation gate replays is green" \
    sh -c "python3 '$GP' test run | grep -q '0 failure'"
