#!/bin/bash
# The bridge<->engine protocol of specs/game-reflex.md, proven cross-language:
# the REAL orsc.ReflexBridge is compiled directly out of the local game
# checkout (the same file the client jar carries) and driven against a
# scripted fake host, while the real Python engine reads the snapshots it
# writes and writes the actions it consumes. No game, no display, no login —
# and skipped honestly where there is no local game tree to borrow.
# Run: bash tests/test_game_reflex_bridge.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
BG="$REPO/lib/betty-game"

# The sandbox moved HOME, so recover the game tree from the live-data path
# recorded before that move.
REAL_HOME="$(cd "$SANDBOX_LIVE_DATA/../../.." 2>/dev/null && pwd)"
GAME_TREE="${DESKCRAB_OPENRSC_TREE:-$REAL_HOME/Games/OpenRSC}"
BRIDGE_SRC="$GAME_TREE/Core-Framework/Client_Base/src/orsc/ReflexBridge.java"
JAVAC="$GAME_TREE/tools/jdk17/bin/javac"
JAVA="$GAME_TREE/tools/jdk17/bin/java"
if [ ! -f "$BRIDGE_SRC" ] || [ ! -x "$JAVAC" ] || [ ! -x "$JAVA" ]; then
    sandbox_skip "no local OpenRSC tree with the reflex bridge at $GAME_TREE"
fi

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

JOUT="$SANDBOX/jout"
mkdir -p "$JOUT"
# A compile failure is DRIFT between the two repos and must fail, not skip.
"$JAVAC" -d "$JOUT" "$BRIDGE_SRC" "$REPO/tests/data/ReflexBridgeHarness.java" \
    2> "$SANDBOX/javac.err" \
    || die "the bridge no longer compiles against the harness: $(cat "$SANDBOX/javac.err")"
ok "the game tree's ReflexBridge compiles against this repo's harness"

S="$SANDBOX/gstate"
mkdir -p "$S"
harness() { "$JAVA" -cp "$JOUT" ReflexBridgeHarness "$S" "$@"; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
rstatus() { python3 -c "import json; print(json.load(open('$S/receipt.json'))['status'])"; }
# wact <id> <ts> <lines...> — write an action file by hand.
wact() {
    local id="$1" ts="$2"; shift 2
    { echo "ts=$ts"; echo "id=$id"; for l in "$@"; do echo "$l"; done; } > "$S/action.json"
}

echo "the snapshot (rules 2-3):"
OUT="$(harness state-out)"
check "a logged-out tick writes a snapshot" test -f "$S/state.json"
python3 - "$S/state.json" <<'PY' && ok "it says logged_in false and carries no player fields" \
    || fail "it says logged_in false and carries no player fields"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["v"] == 1 and s["logged_in"] is False and "hits" not in s, s
PY
OUT="$(harness state-chat)"
python3 - "$S/state.json" <<'PY' && ok "a logged-in snapshot carries the visible state, JSON-escaped" \
    || fail "a logged-in snapshot carries the visible state, JSON-escaped"
import json, sys, time
s = json.load(open(sys.argv[1]))
assert s["v"] == 1 and s["logged_in"] is True
assert s["hits"] == 4 and s["hits_max"] == 10 and s["fatigue"] == 12
assert s["sleeping"] is False and s["sleep_fatigue"] == 0
assert s["sleep_status"] == ""
assert s["skills"] == [
    {"id": 0, "name": "Attack", "level": 12, "xp": 1540},
    {"id": 1, "name": "Defense", "level": 10, "xp": 1000},
    {"id": 2, "name": "Thieving", "level": 24, "xp": 8421},
], s.get("skills")
assert s["quest_points"] == 7
assert s["quests"] == [
    {"id": 0, "name": "Cook's Assistant", "stage": -1, "status": "completed"},
    {"id": 1, "name": "Demon Slayer", "stage": 3, "status": "started"},
    {"id": 3, "name": "Dragon Quest", "stage": 0, "status": "not_started"},
], s.get("quests")
assert s["magic_level"] == 3 and s["selected_spell"] == 0
assert s["spells"] == [
    {"id": 0, "name": "Wind Strike", "description": "A strength 1 missile attack",
     "level": 1, "target": "npc/player", "runes": [
         {"id": 33, "name": "Air-Rune", "held": 12, "required": 1, "available": True},
         {"id": 35, "name": "Mind-Rune", "held": 12, "required": 1, "available": True},
     ], "ready": True},
    {"id": 1, "name": "Confuse", "description": "Reduces your opponent's attack",
     "level": 3, "target": "npc/player", "runes": [
         {"id": 33, "name": "Air-Rune", "held": 12, "required": 3, "available": True},
         {"id": 36, "name": "Body-Rune", "held": 0, "required": 1, "available": False},
     ], "ready": False},
    {"id": 2, "name": "Low level alchemy", "description": "Converts an item into gold",
     "level": 1, "target": "inventory", "runes": [
         {"id": 31, "name": "Fire-Rune", "held": 0, "required": 3, "available": True},
         {"id": 40, "name": "Nature-Rune", "held": 1, "required": 1, "available": True},
     ], "ready": True},
    {"id": 3, "name": "Water Strike", "description": "A strength 2 missile attack",
     "level": 5, "target": "npc/player", "runes": [
         {"id": 32, "name": "Water-Rune", "held": 5, "required": 1, "available": True},
         {"id": 33, "name": "Air-Rune", "held": 12, "required": 1, "available": True},
         {"id": 35, "name": "Mind-Rune", "held": 12, "required": 1, "available": True},
     ], "ready": False},
], s.get("spells")
assert s["x"] == 120 and s["z"] == 650
assert s["walking"] is False and s["in_combat"] is False
assert s["hover_text"] == "Farmer: Pickpocket / 1 more option"
assert s["talking_to_npc"] is False
assert s["dialogue_open"] is False and s["dialogue_options"] == []
assert s["trade_open"] is False
assert s["trade"] is None
assert s["opponent"] is None
assert s["inventory"] == [
    {"id": 132, "name": "Trout", "count": 1, "equipped": False, "wearable": False,
     "commands": ["Eat"]},
    {"id": 81, "name": 'Test "helm"', "count": 3, "equipped": True, "wearable": True,
     "commands": ["Polish", "Inspect"]},
]
assert s["selected_inventory_item"] == 81
assert s["equipment"] == [
    {"id": 81, "name": 'Test "helm"', "count": 3},
]
assert s["equipment_stats"] == {"Armour": 7, "WeaponAim": 0}
assert s["shop_open"] is True and s["shop_items"] == [
    {"slot": 0, "id": 10, "name": "Coins", "count": 50, "noted": False},
    {"slot": 1, "id": 42, "name": 'Test "parcel"', "count": 3, "noted": True},
    {"slot": 2, "id": 81, "name": 'Test "parcel"', "count": 0, "noted": False},
], s.get("shop_items")
assert s["bank_open"] is True and s["bank_items"] == [
    {"slot": 0, "id": 81, "name": "Lobster", "count": 12},
    {"slot": 1, "id": 145, "name": "Bucket", "count": 1},
], s.get("bank_items")
assert s["players"] == [
    {"sidx": 11, "name": "Nearby Friend", "x": 121, "z": 650},
    {"sidx": 22, "name": "Distant Player", "x": 130, "z": 660},
], s.get("players")
assert s["npc_count"] == 2 and s["npcs_truncated"] is False
assert s["ground_items"] == [
    {"id": 27, "name": "Skull", "description": "A scary skull",
     "x": 121, "z": 650, "reachable": True, "path_distance": 1},
    {"id": 10, "name": "Coins", "description": "Lovely money",
     "x": 130, "z": 650, "reachable": True, "path_distance": 10},
], s["ground_items"]
messages = s["messages"]
assert [(m["channel"], m["incoming"], m["sender"], m["text"]) for m in messages] == [
    ("game", False, "", 'Welcome to the "quoted" world'),
    ("local", True, "Nearby Friend", "Try the east door"),
    ("private", True, "Far Friend", "I can help from here"),
], messages
assert all(isinstance(m["id"], int) for m in messages)
assert messages[0]["id"] < messages[1]["id"] < messages[2]["id"]
assert abs(time.time() * 1000 - s["ts"]) < 60000 and s["tick"] >= 1, s
PY
OUT="$(harness state-active)"
python3 - "$S/state.json" <<'PY' && ok "walking, combat, and open NPC dialogue are direct snapshot state" \
    || fail "walking, combat, and open NPC dialogue are direct snapshot state"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["walking"] is True and s["in_combat"] is True
assert s["right_click_menu_open"] is True
assert s["ui_panel_open"] is True and s["ui_panel"] == "inventory"
assert s["hover_text"] == ""
assert s["menu_options"] == [
    "Trade with Nearby Friend",
    "Follow Nearby Friend",
    "Trade with Distant Player",
]
assert s["trade_open"] is True
assert s["trade"] == {
    "stage": "offer", "partner": "Nearby Friend",
    "my_accepted": False, "their_accepted": True,
    "my_offer": [{"id": 81, "name": "Lobster", "count": 2}],
    "their_offer": [
        {"id": 145, "name": "Bucket", "count": 1},
        {"id": 10, "name": "Coins", "count": 50},
    ],
}, s["trade"]
assert s["talking_to_npc"] is True
assert s["dialogue_open"] is True
assert s["dialogue_options"] == [
    "I'm looking for a quest",
    "Can you tell me about this place?",
    "Goodbye",
]
PY
OUT="$(harness state-sleeping)"
python3 - "$S/state.json" <<'PY' && ok "sleep state is semantic, not screenshot-only" \
    || fail "sleep state is semantic, not screenshot-only"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["sleeping"] is True
assert s["sleep_fatigue"] == 12
assert s["sleep_status"] == "Please wait..."
PY
OUT="$(harness state-dialogue)"
python3 - "$S/state.json" <<'PY' && ok "NPC-spoken quest dialogue lingers long enough for a waiter" \
    || fail "NPC-spoken quest dialogue lingers long enough for a waiter"
import json, sys
assert json.load(open(sys.argv[1]))["talking_to_npc"] is True
PY
OUT="$(harness state-player-dialogue)"
python3 - "$S/state.json" <<'PY' && ok "the player's own quest reply is not misclassified as NPC speech" \
    || fail "the player's own quest reply is not misclassified as NPC speech"
import json, sys
assert json.load(open(sys.argv[1]))["talking_to_npc"] is False
PY

echo
echo "the engine against a real bridge snapshot (rules 6, 10, 12):"
export DESKCRAB_GAME_STATE_DIR="$S"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata"
cat > "$SANDBOX/food.xml" <<'EOF'
<map><entry><int>132</int><int>3</int></entry></map>
EOF
"$BG" init --food-xml "$SANDBOX/food.xml" >/dev/null
"$BG" enable eat-low-health >/dev/null
"$BG" set eat-low-health hold_ticks 1 >/dev/null
check "the engine evaluates the bridge's own snapshot" "$BG" run --once
check "and fires an eat" test -f "$S/action.json"
check_eq "slot 0" "$(sandbox_count_in '^slot=0' "$S/action.json")" "1"
check_eq "item 132" "$(sandbox_count_in '^item=132' "$S/action.json")" "1"

echo
echo "execution and the receipt (rule 7):"
OUT="$(harness exec)"
contains "$OUT" "eat slot=0" && ok "the bridge executed the engine's eat" \
    || fail "the bridge executed the engine's eat" "$OUT"
refute "the action file was consumed" test -f "$S/action.json"
check_eq "the receipt says done" "$(rstatus)" "done"
"$BG" run --once
check_eq "the engine consumed the receipt" \
    "$(sandbox_count_in '"kind":"receipt"' "$S/decisions.jsonl")" "1"
python3 - "$S/engine-state.json" <<'PY' && ok "and cleared the in-flight slot" \
    || fail "and cleared the in-flight slot"
import json, sys
assert json.load(open(sys.argv[1]))["inflight"] is None
PY

echo
echo "the refusal ladder (rule 7):"
wact 50 "$(now_ms)" "type=eat" "slot=0" "item=132"
touch "$S/hold"
OUT="$(harness exec)"
refute "held: not executed" contains "$OUT" "eat slot"
refute "held: the file is still consumed" test -f "$S/action.json"
check_eq "held: the receipt says so" "$(rstatus)" "held"
rm "$S/hold"

wact 51 "$(( $(now_ms) - 5000 ))" "type=eat" "slot=0" "item=132"
OUT="$(harness exec)"
refute "stale: not executed" contains "$OUT" "eat slot"
check_eq "stale: the receipt says so" "$(rstatus)" "stale"

wact 52 "$(now_ms)" "type=eat" "slot=0" "item=999"
OUT="$(harness exec)"
refute "a shifted bag is never eaten blind" contains "$OUT" "eat slot"
check_eq "item mismatch is named" "$(rstatus)" "refused-item-mismatch"

wact 53 "$(now_ms)" "type=eat" "slot=1" "item=81"
OUT="$(harness exec)"
refute "a non-food item is never consumed" contains "$OUT" "eat slot"
check_eq "not-food is named" "$(rstatus)" "refused-not-food"

wact 54 "$(now_ms)" "type=eat" "slot=9" "item=1"
harness exec >/dev/null
check_eq "a slot outside the bag is named" "$(rstatus)" "refused-no-such-slot"

wact 55 "$(now_ms)" "type=dance"
harness exec >/dev/null
check_eq "an unknown type is refused, never guessed" "$(rstatus)" "refused-unknown-type"

wact 56 "$(now_ms)" "type=eat" "slot=0" "item=132"
harness exec-out >/dev/null
check_eq "logged out: nothing executes" "$(rstatus)" "refused-logged-out"

echo
echo "walk and warn (rules 5-7):"
wact 57 "$(now_ms)" "type=walk" "x=125" "z=655"
OUT="$(harness exec)"
contains "$OUT" "walk x=125 z=655" && ok "walk reaches the host with its coordinates" \
    || fail "walk reaches the host with its coordinates" "$OUT"
check_eq "and is receipted done" "$(rstatus)" "done"
wact 5701 "$(now_ms)" "type=walk" "x=125" "z=655" "arrive=2"
OUT="$(harness exec)"
contains "$OUT" "walk x=125 z=655 arrive=2" \
    && ok "a route's grounded arrival area reaches collision pathfinding" \
    || fail "the walk arrival tolerance must reach the host" "$OUT"
check_eq "the arrival-area walk is receipted done" "$(rstatus)" "done"
wact 5702 "$(now_ms)" "type=walk" "x=125" "z=655" "arrive=11"
harness exec >/dev/null
check_eq "a walk arrival area is bounded" "$(rstatus)" "refused-bad-coordinates"
wact 5703 "$(now_ms)" "type=walk" "x=125" "z=655" "arrive=1" "max_path=16"
OUT="$(harness exec-long-detour)"
refute "a nearby waypoint whose real path is a huge loop sends no walk" \
    contains "$OUT" "walk x="
check_eq "the collision detour is named distinctly from an unreachable tile" \
    "$(rstatus)" "refused-waypoint-detour"
wact 5704 "$(now_ms)" "type=walk" "x=90" "z=660" "arrive=2" "max_path=16" "route_step=8"
OUT="$(harness exec-long-detour)"
contains "$OUT" "route-step x=90 z=660 arrive=2 max=8" \
    && ok "a route step follows a bounded prefix toward the real destination" \
    || fail "the bridge must ground the route prefix itself" "$OUT"
check_eq "a route prefix supersedes the old full-path compatibility ceiling" \
    "$(rstatus)" "done"
wact 5705 "$(now_ms)" "type=walk" "x=90" "z=660" "route_step=33"
harness exec >/dev/null
check_eq "a route prefix length is bounded" "$(rstatus)" "refused-bad-coordinates"
wact 571 "$(now_ms)" "type=walk" "x=900" "z=900"
OUT="$(harness exec-no-route)"
refute "a destination with no progressive collision path sends no walk" \
    contains "$OUT" "walk x="
check_eq "and is refused truthfully instead of receipted done" \
    "$(rstatus)" "refused-no-path"
wact 572 "$(now_ms)" "type=retreat" "distance=5" "dx=0" "dz=1"
OUT="$(harness exec-combat)"
contains "$OUT" "walk x=120 z=655" \
    && ok "retreat chooses a reachable tile in its grounded fallback direction" \
    || fail "retreat chooses a reachable tile in its grounded fallback direction" "$OUT"
check_eq "the retreat request is receipted as dispatch, not as escape" "$(rstatus)" "done"
wact 573 "$(now_ms)" "type=retreat" "distance=5" "dx=0" "dz=1"
OUT="$(harness exec-combat-no-route)"
refute "retreat never sends a guessed path when every candidate is blocked" \
    contains "$OUT" "walk x="
check_eq "a combat area with no reachable escape tile is named" \
    "$(rstatus)" "refused-no-retreat-path"
wact 574 "$(now_ms)" "type=retreat" "distance=5" "dx=0" "dz=1"
OUT="$(harness exec)"
refute "retreat is an honest no-op once combat is already over" contains "$OUT" "walk x="
check_eq "an already-safe retreat is successful" "$(rstatus)" "done"
wact 570 "$(now_ms)" "type=walk" "x=126" "z=655"
OUT="$(harness exec 13)"
python3 - "$S/state.json" <<'PY' && ok "a dispatched walk remains walking until its server path can appear" \
    || fail "a dispatched walk remains walking until its server path can appear"
import json, sys
assert json.load(open(sys.argv[1]))["walking"] is True
PY
RECEIPT_BEFORE="$(cat "$S/receipt.json")"
{ echo "ts=$(now_ms)"; echo "id=58"; echo "type=warn"; echo "text=danger: health low"; } > "$S/notice-58.json"
OUT="$(harness exec)"
contains "$OUT" "shown danger: health low" && ok "warn shows a local message" \
    || fail "warn shows a local message" "$OUT"
refute "the notice file was consumed" test -f "$S/notice-58.json"
check_eq "and a notice writes NO receipt" "$(cat "$S/receipt.json")" "$RECEIPT_BEFORE"

echo
echo "local and private player chat use the shared action slot (rules 5-7):"
wact 59 "$(now_ms)" "type=chat-local" "text=Thanks, I will try that"
OUT="$(harness exec)"
contains "$OUT" "chat-local text=Thanks, I will try that" \
    && ok "nearby chat reaches the client's public-chat path" \
    || fail "nearby chat reaches the client's public-chat path" "$OUT"
check_eq "local chat is receipted done" "$(rstatus)" "done"
wact 590 "$(now_ms)" "type=chat-private" "target=Far Friend" "text=Thanks for the private message"
OUT="$(harness exec)"
contains "$OUT" "chat-private target=Far Friend text=Thanks for the private message" \
    && ok "private chat retains the target and reaches the private-message path" \
    || fail "private chat retains the target and reaches the private-message path" "$OUT"
check_eq "private chat is receipted done" "$(rstatus)" "done"
wact 591 "$(now_ms)" "type=chat-private" "target=" "text=hello"
harness exec >/dev/null
check_eq "an empty private target is refused" "$(rstatus)" "refused-empty-target"
LONG_TEXT="$(printf 'x%.0s' $(seq 1 81))"
wact 592 "$(now_ms)" "type=chat-local" "text=$LONG_TEXT"
harness exec >/dev/null
check_eq "chat beyond the client limit is refused, not truncated" "$(rstatus)" "refused-bad-text"

echo
echo "talk-npc and the npcs snapshot field (rules 3, 5-7):"
python3 - "$S/state.json" <<'PY' && ok "the snapshot lists NPCs by walking steps, nearest first" \
    || fail "the snapshot lists visible NPCs nearest first"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["npcs"] == [
    {"sidx": 7, "id": 474, "name": "Farmer", "description": "A local farmer",
     "attackable": True, "stats": {"attack": 2, "strength": 2, "defense": 2, "hits": 8},
     "x": 121, "z": 651, "distance": 1,
     "clear_shot": True, "terrain_melee_reachable": False},
    {"sidx": 9, "id": 485, "name": "Guard", "description": "A watchful guard",
     "attackable": True, "stats": {"attack": 8, "strength": 7, "defense": 9, "hits": 15},
     "x": 122, "z": 650, "distance": 2,
     "clear_shot": False, "terrain_melee_reachable": True},
], s["npcs"]
PY
wact 60 "$(now_ms)" "type=talk-npc" "sidx=7" "npc=474"
OUT="$(harness exec)"
contains "$OUT" "talk sidx=7" && ok "talk-npc reaches the host with the server index" \
    || fail "talk-npc reaches the host with the server index" "$OUT"
check_eq "and is receipted done" "$(rstatus)" "done"
contains "$(cat "$S/receipt.json")" '"id":60' \
    && ok "the receipt carries the ACTION id, not the npc type id" \
    || fail "the receipt carries the ACTION id, not the npc type id" "$(cat "$S/receipt.json")"
wact 61 "$(now_ms)" "type=talk-npc" "sidx=7" "npc=999"
OUT="$(harness exec)"
refute "a swapped NPC is not talked to" contains "$OUT" "talk sidx"
check_eq "the type mismatch is named" "$(rstatus)" "refused-npc-mismatch"
wact 62 "$(now_ms)" "type=talk-npc" "sidx=42" "npc=474"
OUT="$(harness exec)"
refute "a despawned NPC is not talked to" contains "$OUT" "talk sidx"
check_eq "the missing NPC is named" "$(rstatus)" "refused-no-such-npc"
wact 621 "$(now_ms)" "type=talk-npc" "sidx=7" "npc=474"
OUT="$(harness exec-nearer-npc)"
refute "a stale farther target is not talked to when an equivalent is nearer" \
    contains "$OUT" "talk sidx"
check_eq "the nearer-equivalent refusal is explicit" "$(rstatus)" \
    "refused-nearer-equivalent"

echo
echo "interact-npc executes a definition-backed NPC command (rules 5-7):"
wact 63 "$(now_ms)" "type=interact-npc" "sidx=7" "npc=474" "cmd=1"
OUT="$(harness exec)"
contains "$OUT" "npc sidx=7 cmd=1" \
    && ok "the NPC's first definition command reached the host" \
    || fail "the NPC's first definition command reached the host" "$OUT"
check_eq "and is receipted done" "$(rstatus)" "done"
wact 64 "$(now_ms)" "type=interact-npc" "sidx=7" "npc=474" "cmd=3"
harness exec >/dev/null
check_eq "an unknown NPC command is refused" "$(rstatus)" "refused-bad-command"
wact 65 "$(now_ms)" "type=interact-npc" "sidx=7" "npc=999" "cmd=1"
OUT="$(harness exec)"
refute "a swapped NPC is not commanded" contains "$OUT" "npc sidx="
check_eq "the NPC command type mismatch is named" "$(rstatus)" "refused-npc-mismatch"
wact 66 "$(now_ms)" "type=interact-npc" "sidx=9" "npc=485" "cmd=1" "within=1"
OUT="$(harness exec)"
refute "an NPC that roamed beyond the compiled range is not chased" \
    contains "$OUT" "npc sidx="
check_eq "the live range refusal is explicit" "$(rstatus)" \
    "refused-npc-out-of-range"

echo
echo "cast-npc validates spell readiness and dispatches one semantic cast (rules 3, 5-7):"
wact 6601 "$(now_ms)" "type=cast-npc" "spell=0" "sidx=7" "npc=474"
OUT="$(harness exec)"
contains "$OUT" "cast spell=0 sidx=7" \
    && ok "a ready NPC spell reaches the ordinary cast path" \
    || fail "a ready NPC spell reaches the ordinary cast path" "$OUT"
check_eq "the semantic cast is receipted done" "$(rstatus)" "done"
wact 6602 "$(now_ms)" "type=cast-npc" "spell=99" "sidx=7" "npc=474"
harness exec >/dev/null
check_eq "an unknown spell is refused" "$(rstatus)" "refused-no-such-spell"
wact 6603 "$(now_ms)" "type=cast-npc" "spell=2" "sidx=7" "npc=474"
harness exec >/dev/null
check_eq "an inventory spell cannot be aimed at an NPC" "$(rstatus)" \
    "refused-wrong-spell-target"
wact 6604 "$(now_ms)" "type=cast-npc" "spell=3" "sidx=7" "npc=474"
harness exec >/dev/null
check_eq "a spell above the live Magic level is refused" "$(rstatus)" \
    "refused-magic-level"
wact 6605 "$(now_ms)" "type=cast-npc" "spell=1" "sidx=7" "npc=474"
harness exec >/dev/null
check_eq "a spell with missing live runes is refused" "$(rstatus)" \
    "refused-missing-runes"
wact 6606 "$(now_ms)" "type=cast-npc" "spell=0" "sidx=7" "npc=999"
OUT="$(harness exec)"
refute "a spell is not sent to an NPC whose identity changed" contains "$OUT" "cast spell="
check_eq "the spell target mismatch is named" "$(rstatus)" "refused-npc-mismatch"
wact 6607 "$(now_ms)" "type=cast-npc" "spell=0" "sidx=9" "npc=485" "within=1"
OUT="$(harness exec)"
refute "a local Magic reflex does not chase a target beyond its range" \
    contains "$OUT" "cast spell="
check_eq "the cast locality refusal is explicit" "$(rstatus)" \
    "refused-npc-out-of-range"
wact 6608 "$(now_ms)" "type=cast-npc" "spell=0" "sidx=7" "npc=474" \
    "stationary=1" "require_clear_shot=1" "require_melee_unreachable=1"
OUT="$(harness exec)"
contains "$OUT" "cast spell=0 sidx=7 stationary=true" \
    && ok "a terrain-guarded cast omits approach movement" \
    || fail "a terrain-guarded cast must remain stationary" "$OUT"
check_eq "the guarded stationary cast is receipted done" "$(rstatus)" "done"
wact 6609 "$(now_ms)" "type=cast-npc" "spell=0" "sidx=9" "npc=485" \
    "require_clear_shot=1"
harness exec >/dev/null
check_eq "a changed projectile line invalidates the learned guard" "$(rstatus)" \
    "refused-no-clear-shot"

echo
echo "player trade and right-click menu selection use live identities (rules 3, 5-7):"
wact 651 "$(now_ms)" "type=trade-player" "sidx=11"
OUT="$(harness exec)"
contains "$OUT" "trade-player sidx=11" \
    && ok "a visible player's server identity reaches the ordinary trade request" \
    || fail "a visible player's server identity reaches the ordinary trade request" "$OUT"
check_eq "the trade request is receipted done" "$(rstatus)" "done"
wact 652 "$(now_ms)" "type=trade-player" "sidx=99"
harness exec >/dev/null
check_eq "a player who is no longer visible is refused" "$(rstatus)" "refused-no-such-player"
wact 653 "$(now_ms)" "type=follow-player" "sidx=11"
OUT="$(harness exec)"
contains "$OUT" "follow-player sidx=11" \
    && ok "semantic follow uses the native visible-player action" \
    || fail "semantic follow must reach the native player packet" "$OUT"
check_eq "the native follow is receipted done" "$(rstatus)" "done"
wact 654 "$(now_ms)" "type=follow-player" "sidx=99"
harness exec >/dev/null
check_eq "a player who is no longer visible cannot be followed" "$(rstatus)" "refused-no-such-player"
wact 65201 "$(now_ms)" "type=trade-offer" "item=132" "amount=1"
OUT="$(harness exec-trade-offer)"
contains "$OUT" "trade-offer slot=0 amount=1 item=132" \
    && ok "a trade offer selects the requested live inventory identity" \
    || fail "a trade offer selects the requested live inventory identity" "$OUT"
check_eq "the identity-backed offer is receipted done" "$(rstatus)" "done"
wact 65202 "$(now_ms)" "type=trade-remove" "item=81" "amount=1"
OUT="$(harness exec-trade-offer)"
contains "$OUT" "trade-remove slot=0 amount=1 item=81" \
    && ok "a trade removal selects the requested live offer identity" \
    || fail "a trade removal selects the requested live offer identity" "$OUT"
check_eq "the identity-backed removal is receipted done" "$(rstatus)" "done"
wact 65203 "$(now_ms)" "type=trade-offer" "item=132" "amount=1"
harness exec-trade-confirm >/dev/null
check_eq "an offer cannot mutate the confirmation stage" "$(rstatus)" \
    "refused-trade-stage-changed"
wact 65204 "$(now_ms)" "type=trade-remove" "item=999" "amount=1"
harness exec-trade-offer >/dev/null
check_eq "removing an absent offer identity is refused" "$(rstatus)" \
    "refused-no-such-item"
wact 6521 "$(now_ms)" "type=trade-accept" "stage=offer"
OUT="$(harness exec-trade-offer)"
contains "$OUT" "trade-accept stage=offer" \
    && ok "the first trade screen accepts through the ordinary packet path" \
    || fail "the first trade screen accepts through the ordinary packet path" "$OUT"
check_eq "the first acceptance is receipted done" "$(rstatus)" "done"
wact 6522 "$(now_ms)" "type=trade-accept" "stage=confirm"
OUT="$(harness exec-trade-confirm)"
contains "$OUT" "trade-accept stage=confirm" \
    && ok "the confirmation screen accepts through its own ordinary packet path" \
    || fail "the confirmation screen accepts through its own ordinary packet path" "$OUT"
check_eq "the final acceptance is receipted done" "$(rstatus)" "done"
wact 6523 "$(now_ms)" "type=trade-accept" "stage=offer"
harness exec-trade-confirm >/dev/null
check_eq "a stage transition is refused instead of accepting a stale screen" \
    "$(rstatus)" "refused-trade-stage-changed"
wact 6524 "$(now_ms)" "type=trade-accept" "stage=offer"
harness exec >/dev/null
check_eq "accepting with no trade open is refused" "$(rstatus)" "refused-trade-closed"
wact 653 "$(now_ms)" "type=choose-menu" "text=follow"
OUT="$(harness exec-menu)"
contains "$OUT" "menu index=1 text=Follow @whi@Nearby Friend" \
    && ok "a unique text fragment chooses its live menu entry" \
    || fail "a unique text fragment chooses its live menu entry" "$OUT"
check_eq "the menu choice is receipted done" "$(rstatus)" "done"
wact 654 "$(now_ms)" "type=choose-menu" "text=Trade with Nearby Friend"
OUT="$(harness exec-menu)"
contains "$OUT" "menu index=0" \
    && ok "a full label wins exactly even when another Trade option exists" \
    || fail "a full label wins exactly even when another Trade option exists" "$OUT"
wact 655 "$(now_ms)" "type=choose-menu" "text=trade"
harness exec-menu >/dev/null
check_eq "an ambiguous fragment is refused, never guessed" \
    "$(rstatus)" "refused-ambiguous-menu-option"
wact 656 "$(now_ms)" "type=choose-menu" "text=duel"
harness exec-menu >/dev/null
check_eq "a missing menu option is named" "$(rstatus)" "refused-no-such-menu-option"
wact 657 "$(now_ms)" "type=choose-menu" "text=follow"
harness exec >/dev/null
check_eq "a closed context menu is named" "$(rstatus)" "refused-menu-closed"
wact 658 "$(now_ms)" "type=choose-dialogue" "text=looking for"
OUT="$(harness exec-dialogue)"
contains "$OUT" "dialogue index=0 text=I'm looking for a quest" \
    && ok "a unique text fragment chooses its live NPC reply" \
    || fail "a unique text fragment chooses its live NPC reply" "$OUT"
check_eq "the NPC reply is receipted done" "$(rstatus)" "done"
wact 659 "$(now_ms)" "type=choose-dialogue" "text=can"
OUT="$(harness exec-dialogue)"
contains "$OUT" "dialogue index=1" \
    && ok "NPC replies are selected semantically, not by screen row" \
    || fail "NPC replies are selected semantically, not by screen row" "$OUT"
wact 660 "$(now_ms)" "type=choose-dialogue" "text=o"
harness exec-dialogue >/dev/null
check_eq "an ambiguous NPC reply fragment is refused" \
    "$(rstatus)" "refused-ambiguous-dialogue-option"
wact 661 "$(now_ms)" "type=choose-dialogue" "text=quest"
harness exec >/dev/null
check_eq "a closed NPC reply menu is named" "$(rstatus)" "refused-dialogue-closed"

echo
echo "two simultaneous warnings both reach the player (rules 6-7, 10):"
rm -f "$S"/notice-*.json "$S/engine-state.json"
"$BG" disable eat-low-health >/dev/null
"$BG" add warn-second --channel notice --priority 1 --cooldown-ms 0 --hold-ticks 1 \
    --trigger hp_below=0.6 --action warn --param "text=second warning" >/dev/null
"$BG" enable warn-second >/dev/null
harness state >/dev/null   # a fresh snapshot from the real bridge
"$BG" run --once
check_eq "the engine left one notice file per firing" \
    "$(ls "$S"/notice-*.json 2>/dev/null | wc -l)" "2"
RECEIPT_BEFORE="$(cat "$S/receipt.json")"
OUT="$(harness exec)"
check_eq "the bridge showed BOTH warnings in one tick" \
    "$(printf '%s\n' "$OUT" | grep -c '^shown')" "2"
contains "$OUT" "shown health low: 4/10" && ok "the first kept its text" \
    || fail "the first kept its text" "$OUT"
contains "$OUT" "shown second warning" && ok "the second kept its text" \
    || fail "the second kept its text" "$OUT"
check_eq "delivered in engine-id order" \
    "$(printf '%s\n' "$OUT" | grep '^shown' | head -1)" "shown health low: 4/10"
check_eq "both files were consumed" "$(ls "$S"/notice-*.json 2>/dev/null | wc -l)" "0"
check_eq "and notices still write no receipt" "$(cat "$S/receipt.json")" "$RECEIPT_BEFORE"
"$BG" remove warn-second >/dev/null

echo
echo "the queue drains oldest id first, bounded per tick (rule 7):"
TS="$(now_ms)"
for i in 2 3 4 5 6 7 8 9 10; do
    { echo "ts=$TS"; echo "id=$i"; echo "type=warn"; echo "text=w$i"; } > "$S/notice-$i.json"
done
OUT="$(harness exec)"
check_eq "one tick executes at most 8 notices" \
    "$(printf '%s\n' "$OUT" | grep -c '^shown')" "8"
check_eq "the lowest id went first" \
    "$(printf '%s\n' "$OUT" | grep '^shown' | head -1)" "shown w2"
check "id 10 waits its turn — numeric order, not lexical" test -f "$S/notice-10.json"
refute "while id 2 is gone" test -f "$S/notice-2.json"
# Re-stamp the survivor before the second tick: this case pins order and the
# cap, and must not flake on the 1500 ms freshness clock pinned above.
{ echo "ts=$(now_ms)"; echo "id=10"; echo "type=warn"; echo "text=w10"; } > "$S/notice-10.json"
OUT="$(harness exec)"
contains "$OUT" "shown w10" && ok "the next tick delivers the remainder" \
    || fail "the next tick delivers the remainder" "$OUT"

echo
echo "the bridge may never break the game (rule 8):"
OUT="$(harness fail5)"
contains "$OUT" "disabled=true" && ok "five failing ticks disable the bridge" \
    || fail "five failing ticks disable the bridge" "$OUT"
check_eq "the disablement was announced exactly once" \
    "$(printf '%s\n' "$OUT" | grep -c 'shown reflex bridge disabled')" "1"

echo
echo "the opt-in launcher is versioned, and only it opens the bridge (rule 4):"
CF="$GAME_TREE/Core-Framework"
check_eq "launch-client-reflex.sh is committed in the game checkout" \
    "$(git -C "$CF" ls-files -- launch-client-reflex.sh)" "launch-client-reflex.sh"
check_eq "the callable door beside the stock launcher is that committed copy" \
    "$(readlink -f "$GAME_TREE/launch-client-reflex.sh" 2>/dev/null)" \
    "$CF/launch-client-reflex.sh"
check_eq "the stock launcher stays bridge-less — it never names the switch" \
    "$(grep -c 'DESKCRAB_GAME_STATE_DIR' "$GAME_TREE/launch-client.sh")" "0"
# Execute the committed bytes against a stub stock launcher: the reflex door
# must export the exchange directory, and hand over to the launcher it finds
# beside the checkout.
mkdir -p "$SANDBOX/cf"
cp "$CF/launch-client-reflex.sh" "$SANDBOX/cf/launch-client-reflex.sh" 2>/dev/null || true
cat > "$SANDBOX/launch-client.sh" <<'EOF'
#!/usr/bin/env bash
echo "stock-launcher saw [${DESKCRAB_GAME_STATE_DIR:-unset}]"
EOF
chmod +x "$SANDBOX/launch-client.sh" "$SANDBOX/cf/launch-client-reflex.sh" 2>/dev/null
OUT="$(env -u DESKCRAB_GAME_STATE_DIR "$SANDBOX/cf/launch-client-reflex.sh" 2>&1)"
check_eq "the reflex launcher sets the exchange directory, then hands over" \
    "$OUT" "stock-launcher saw [/tmp/deskcrab-game]"
OUT="$(DESKCRAB_GAME_STATE_DIR=/tmp/elsewhere "$SANDBOX/cf/launch-client-reflex.sh" 2>&1)"
check_eq "an exchange path already set is respected, never clobbered" \
    "$OUT" "stock-launcher saw [/tmp/elsewhere]"

echo
echo "objects and bounds in the snapshot (rules 2-3):"
harness state >/dev/null
python3 - "$S/state.json" <<'PY' && ok "the snapshot lists loaded objects nearest first, with facing" \
    || fail "the snapshot lists loaded objects nearest first, with facing"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["objects"] == [
    {"id": 57, "name": "Gate", "description": "A wooden gate",
     "commands": ["Open", "Examine"], "x": 121, "z": 649, "dir": 2,
     "blocks_movement": True, "projectiles_pass": True},
    {"id": 493, "name": "Fishing spot", "description": "Fish are swimming here",
     "commands": ["Net", "Bait"], "x": 196, "z": 726, "dir": 0,
     "blocks_movement": False, "projectiles_pass": False},
], s.get("objects")
PY
python3 - "$S/state.json" <<'PY' && ok "and the wall objects (doors) nearest first, with wall direction" \
    || fail "and the wall objects (doors) nearest first, with wall direction"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["bounds"] == [
    {"id": 1, "name": "Door", "description": "The door is shut",
     "commands": ["Open", "Examine"], "x": 121, "z": 650, "dir": 0,
     "blocks_movement": True, "projectiles_pass": False,
     "reachable": True, "path_distance": 1, "open_command": 1},
    {"id": 2, "name": "Stone wall", "description": "A solid wall",
     "commands": ["WalkTo", "Examine"], "x": 140, "z": 660, "dir": 1,
     "blocks_movement": True, "projectiles_pass": False,
     "reachable": True, "path_distance": 20, "open_command": 0},
], s.get("bounds")
PY
python3 - "$S/state.json" <<'PY' && ok "terrain separates walking topology from projectile permeability" \
    || fail "terrain must expose its two independent channels"
import json, sys
s = json.load(open(sys.argv[1]))
t = s["terrain"]
assert t["radius"] == 6
assert t["blocked_cells"] == [{"x": 121, "z": 650, "projectiles_pass": True}]
assert t["barriers"] and all(edge["projectiles_pass"] is True for edge in t["barriers"])
PY

echo
echo "interact-object executes the object's own menu command (rules 5-7):"
wact 70 "$(now_ms)" "type=interact-object" "x=121" "z=649" "obj=57" "cmd=1"
OUT="$(harness exec)"
contains "$OUT" "object x=121 z=649 id=57 cmd=1" && ok "the gate's first command reached the host" \
    || fail "the gate's first command reached the host" "$OUT"
check_eq "and is receipted done" "$(rstatus)" "done"
wact 71 "$(now_ms)" "type=interact-object" "x=196" "z=726" "obj=493" "cmd=2"
OUT="$(harness exec)"
contains "$OUT" "object x=196 z=726 id=493 cmd=2" \
    && ok "the fishing spot's SECOND menu verb rides cmd=2" \
    || fail "the fishing spot's SECOND menu verb rides cmd=2" "$OUT"
check_eq "receipted done" "$(rstatus)" "done"
wact 72 "$(now_ms)" "type=interact-object" "x=121" "z=649" "obj=999" "cmd=1"
OUT="$(harness exec)"
refute "a swapped object is never acted on" contains "$OUT" "object x="
check_eq "the mismatch is named" "$(rstatus)" "refused-object-mismatch"
wact 73 "$(now_ms)" "type=interact-object" "x=5" "z=5" "obj=57" "cmd=1"
harness exec >/dev/null
check_eq "an empty tile is named" "$(rstatus)" "refused-no-such-object"
wact 74 "$(now_ms)" "type=interact-object" "x=121" "z=649" "obj=57" "cmd=3"
harness exec >/dev/null
check_eq "a command outside the menu is refused, never guessed" "$(rstatus)" "refused-bad-command"

echo
echo "use-item-object resolves both identities and bypasses pointer timing (rules 5-7):"
wact 741 "$(now_ms)" "type=use-item-object" "item=81" "x=121" "z=649" "obj=57"
OUT="$(harness exec)"
contains "$OUT" "use-item-object slot=1 item=81 x=121 z=649 obj=57" \
    && ok "one semantic action carries the current item slot and loaded object" \
    || fail "one semantic action carries the current item slot and loaded object" "$OUT"
check_eq "the item-on-object action is receipted done" "$(rstatus)" "done"
wact 742 "$(now_ms)" "type=use-item-object" "item=999" "x=121" "z=649" "obj=57"
harness exec >/dev/null
check_eq "an item no longer held is refused before object use" "$(rstatus)" "refused-no-such-item"
wact 743 "$(now_ms)" "type=use-item-object" "item=81" "x=121" "z=649" "obj=999"
harness exec >/dev/null
check_eq "a changed object identity is refused before item use" "$(rstatus)" "refused-object-mismatch"

echo
echo "use-item-npc resolves held item and visible NPC identities atomically (rules 5-7):"
wact 744 "$(now_ms)" "type=use-item-npc" "item=81" "sidx=7" "npc=474"
OUT="$(harness exec)"
contains "$OUT" "use-item-npc slot=1 item=81 sidx=7" \
    && ok "one semantic action carries the current item slot and NPC server identity" \
    || fail "item-on-NPC should bypass inventory selection and pointer timing" "$OUT"
check_eq "the item-on-NPC action is receipted done" "$(rstatus)" "done"
wact 745 "$(now_ms)" "type=use-item-npc" "item=999" "sidx=7" "npc=474"
harness exec >/dev/null
check_eq "an item no longer held is refused before NPC use" "$(rstatus)" "refused-no-such-item"
wact 746 "$(now_ms)" "type=use-item-npc" "item=81" "sidx=7" "npc=485"
harness exec >/dev/null
check_eq "a changed NPC type is refused before item use" "$(rstatus)" "refused-npc-mismatch"
wact 747 "$(now_ms)" "type=use-item-npc" "item=81" "sidx=7" "npc=474" "within=0"
harness exec >/dev/null
check_eq "an optional locality cap is rechecked against the live NPC" "$(rstatus)" \
    "refused-npc-out-of-range"

echo
echo "interact-bound opens the door, matched on tile AND wall (rules 5-7):"
wact 75 "$(now_ms)" "type=interact-bound" "x=121" "z=650" "dir=0" "obj=1" "cmd=1"
OUT="$(harness exec)"
contains "$OUT" "bound x=121 z=650 dir=0 cmd=1" && ok "the door's Open reached the host" \
    || fail "the door's Open reached the host" "$OUT"
check_eq "and is receipted done" "$(rstatus)" "done"
wact 76 "$(now_ms)" "type=interact-bound" "x=121" "z=650" "dir=0" "obj=99" "cmd=1"
OUT="$(harness exec)"
refute "a swapped boundary is never acted on" contains "$OUT" "bound x="
check_eq "the mismatch is named" "$(rstatus)" "refused-bound-mismatch"
wact 77 "$(now_ms)" "type=interact-bound" "x=121" "z=650" "dir=1" "obj=1" "cmd=1"
harness exec >/dev/null
check_eq "the same tile on the WRONG wall is no such bound" "$(rstatus)" "refused-no-such-bound"
wact 771 "$(now_ms)" "type=interact-bound" "x=121" "z=650" "dir=0" "obj=1" "cmd=1"
OUT="$(harness exec-unreachable-bound)"
refute "an unreachable closed door never receives a fabricated walk-and-open" \
    contains "$OUT" "bound x="
check_eq "the unreachable door is refused before dispatch" "$(rstatus)" \
    "refused-bound-unreachable"

echo
echo "click-entity resolves stable identities at execution time (rules 5-7):"
wact 78 "$(now_ms)" "type=click-entity" "kind=npc" "sidx=7" "npc=474" "button=1"
OUT="$(harness exec)"
contains "$OUT" "click x=411 y=211 button=1" \
    && ok "an NPC identity resolves to its latest rendered point" \
    || fail "an NPC identity resolves to its latest rendered point" "$OUT"
check_eq "the NPC click is receipted done" "$(rstatus)" "done"
wact 79 "$(now_ms)" "type=click-entity" "kind=object" "x=121" "z=649" "obj=57" "button=3"
OUT="$(harness exec)"
contains "$OUT" "click x=311 y=161 button=3" \
    && ok "an object identity resolves after the action is written" \
    || fail "an object identity resolves after the action is written" "$OUT"
wact 80 "$(now_ms)" "type=click-entity" "kind=bound" "x=121" "z=650" \
    "dir=0" "obj=1" "button=2"
OUT="$(harness exec)"
contains "$OUT" "click x=261 y=131 button=2" \
    && ok "a boundary identity includes its wall direction" \
    || fail "a boundary identity includes its wall direction" "$OUT"
wact 81 "$(now_ms)" "type=click-entity" "kind=npc" "sidx=7" "npc=999" "button=1"
harness exec >/dev/null
check_eq "a changed NPC type is refused" "$(rstatus)" "refused-npc-mismatch"
wact 82 "$(now_ms)" "type=click-entity" "kind=npc" "sidx=7" "npc=474" "button=4"
harness exec >/dev/null
check_eq "an unsupported pointer button is refused" "$(rstatus)" "refused-bad-button"
wact 83 "$(now_ms)" "type=click-entity" "kind=npc" "sidx=7" "npc=474" "button=1"
harness exec-offscreen >/dev/null
check_eq "an entity no longer on-screen is refused" "$(rstatus)" "refused-not-on-screen"
wact 84 "$(now_ms)" "type=click-entity" "kind=widget" "x=1" "z=1" "obj=1" "button=1"
harness exec >/dev/null
check_eq "an unknown entity kind is refused" "$(rstatus)" "refused-bad-entity-kind"
wact 841 "$(now_ms)" "type=click-entity" "kind=npc" "sidx=7" "npc=474" "button=1"
OUT="$(harness exec-ui-panel)"
refute "an open hover panel never receives a hidden world click" contains "$OUT" "click x="
check_eq "the refusal names the visible obstruction" "$(rstatus)" "refused-ui-panel-open"
wact 842 "$(now_ms)" "type=click-inventory" "item=81" "button=1"
OUT="$(harness exec-ui-panel)"
contains "$OUT" "click x=611 y=311 button=1" \
    && ok "the hover-panel guard does not block an intentional interface click" \
    || fail "the hover-panel guard does not block an intentional interface click" "$OUT"

echo
echo "click-inventory resolves an item id to its current slot (rules 5-7):"
wact 85 "$(now_ms)" "type=click-inventory" "item=81" "button=3"
OUT="$(harness exec)"
contains "$OUT" "click x=611 y=311 button=3" \
    && ok "an item id resolves to its current inventory slot centre" \
    || fail "an item id resolves to its current inventory slot centre" "$OUT"
check_eq "the inventory click is receipted done" "$(rstatus)" "done"
wact 86 "$(now_ms)" "type=click-inventory" "item=999" "button=1"
harness exec >/dev/null
check_eq "an item no longer held is refused" "$(rstatus)" "refused-no-such-item"
wact 87 "$(now_ms)" "type=click-inventory" "item=81" "button=4"
harness exec >/dev/null
check_eq "an unsupported inventory button is refused" "$(rstatus)" "refused-bad-button"
wact 88 "$(now_ms)" "type=click-inventory" "item=81" "button=1"
harness exec-offscreen >/dev/null
check_eq "an inventory point that cannot be rendered is refused" "$(rstatus)" "refused-not-on-screen"

echo
echo "equipment and item commands are semantic and idempotent (rules 3, 5-7):"
wact 89 "$(now_ms)" "type=equip-inventory" "item=81"
OUT="$(harness exec)"
check_eq "equipping an already-equipped item is harmless" "$(rstatus)" "already-equipped"
refute "an idempotent equip sends no second toggle" contains "$OUT" "equip slot="
wact 90 "$(now_ms)" "type=unequip-inventory" "item=81"
OUT="$(harness exec)"
contains "$OUT" "unequip slot=1 item=81" \
    && ok "unequip resolves item identity to the equipped slot" \
    || fail "unequip resolves item identity to the equipped slot" "$OUT"
check_eq "unequip is receipted done" "$(rstatus)" "done"
wact 91 "$(now_ms)" "type=equip-inventory" "item=132"
harness exec >/dev/null
check_eq "a non-wearable item cannot be equipped" "$(rstatus)" "refused-not-wearable"
wact 92 "$(now_ms)" "type=unequip-inventory" "item=999"
harness exec >/dev/null
check_eq "equipment actions refuse an absent item" "$(rstatus)" "refused-no-such-item"
wact 93 "$(now_ms)" "type=command-inventory" "item=81" "cmd=1" "amount=2"
OUT="$(harness exec)"
contains "$OUT" 'item-command slot=1 item=81 command=Polish amount=2' \
    && ok "a definition-backed item command resolves by identity" \
    || fail "a definition-backed item command resolves by identity" "$OUT"
check_eq "the item command is receipted done" "$(rstatus)" "done"
wact 94 "$(now_ms)" "type=command-inventory" "item=81" "cmd=3" "amount=1"
harness exec >/dev/null
check_eq "an unavailable item command is refused" "$(rstatus)" "refused-bad-command"
wact 95 "$(now_ms)" "type=command-inventory" "item=81" "cmd=1" "amount=0"
harness exec >/dev/null
check_eq "an item command refuses a non-positive amount" "$(rstatus)" "refused-bad-amount"

echo
echo "click-shop and click-bank resolve interface items by identity (rules 3, 5-7):"
wact 881 "$(now_ms)" "type=click-shop" "item=42" "button=2"
OUT="$(harness exec)"
contains "$OUT" "click x=711 y=411 button=2" \
    && ok "a shop item id resolves to its current live slot" \
    || fail "a shop item id resolves to its current live slot" "$OUT"
check_eq "the shop click is receipted done" "$(rstatus)" "done"
wact 882 "$(now_ms)" "type=click-bank" "item=145" "button=3"
OUT="$(harness exec)"
contains "$OUT" "click x=811 y=511 button=3" \
    && ok "a bank item id resolves to its exposed live slot" \
    || fail "a bank item id resolves to its exposed live slot" "$OUT"
check_eq "the bank click is receipted done" "$(rstatus)" "done"
wact 883 "$(now_ms)" "type=click-bank" "item=999" "button=1"
harness exec >/dev/null
check_eq "a missing bank item is refused" "$(rstatus)" "refused-no-such-item"
wact 8831 "$(now_ms)" "type=click-bank" "item=132" "button=1"
OUT="$(harness exec)"
contains "$OUT" "click x=812 y=512 button=1" \
    && ok "an inventory item with no bank stack is selectable for deposit" \
    || fail "an inventory item with no bank stack is selectable for deposit" "$OUT"
check_eq "the inventory item selection is receipted done" "$(rstatus)" "done"
wact 884 "$(now_ms)" "type=click-shop" "item=10" "button=4"
harness exec >/dev/null
check_eq "an unsupported shop button is refused" "$(rstatus)" "refused-bad-button"
wact 885 "$(now_ms)" "type=click-shop" "item=10" "button=1"
harness exec-closed >/dev/null
check_eq "a closed shop is refused before resolving a slot" "$(rstatus)" "refused-shop-closed"
wact 886 "$(now_ms)" "type=click-bank" "item=81" "button=1"
harness exec-closed >/dev/null
check_eq "a closed bank is refused before resolving a slot" "$(rstatus)" "refused-bank-closed"
wact 887 "$(now_ms)" "type=click-bank" "item=81" "button=1"
harness exec-offscreen >/dev/null
check_eq "an unavailable bank point is refused" "$(rstatus)" "refused-not-on-screen"

echo
echo "bank and shop transactions bypass amount-button coordinates (rules 5-7):"
wact 888 "$(now_ms)" "type=bank-deposit" "item=81" "amount=99"
OUT="$(harness exec)"
contains "$OUT" "bank-deposit item=81 amount=3" \
    && ok "deposit is clamped to the live inventory quantity" \
    || fail "deposit is clamped to the live inventory quantity" "$OUT"
check_eq "deposit is receipted done" "$(rstatus)" "done"
wact 889 "$(now_ms)" "type=bank-withdraw" "item=81" "amount=5"
OUT="$(harness exec)"
contains "$OUT" "bank-withdraw item=81 amount=5" \
    && ok "withdraw uses item identity and an explicit amount" \
    || fail "withdraw uses item identity and an explicit amount" "$OUT"
wact 890 "$(now_ms)" "type=shop-buy" "item=42" "amount=99"
OUT="$(harness exec)"
contains "$OUT" "shop-buy item=42 amount=3" \
    && ok "buy is clamped to the live shop stock" \
    || fail "buy is clamped to the live shop stock" "$OUT"
wact 891 "$(now_ms)" "type=shop-sell" "item=999" "amount=2"
OUT="$(harness exec)"
refute "an item the shop does not trade is never sold" contains "$OUT" "shop-sell"
check_eq "the unavailable shop item is named" "$(rstatus)" "refused-no-such-item"
wact 8911 "$(now_ms)" "type=shop-sell" "item=81" "amount=2"
OUT="$(harness exec)"
contains "$OUT" "shop-sell item=81 amount=2" \
    && ok "an item at zero shop stock can still be sold back" \
    || fail "an item at zero shop stock can still be sold back" "$OUT"
check_eq "zero stock is not mistaken for an untraded item" "$(rstatus)" "done"
wact 892 "$(now_ms)" "type=shop-sell" "item=42" "amount=0"
harness exec >/dev/null
check_eq "a zero transaction amount is refused" "$(rstatus)" "refused-bad-amount"
wact 893 "$(now_ms)" "type=bank-deposit" "item=81" "amount=1"
harness exec-closed >/dev/null
check_eq "a closed bank refuses transactions" "$(rstatus)" "refused-bank-closed"

echo
echo "take-ground resolves a visible item identity at execution time (rules 3, 5-7):"
wact 89 "$(now_ms)" "type=take-ground" "x=121" "z=650" "item=27"
OUT="$(harness exec)"
contains "$OUT" "take x=121 z=650 id=27" \
    && ok "the visible skull reaches the game's walk-and-take path" \
    || fail "the visible skull reaches the game's walk-and-take path" "$OUT"
check_eq "the ground-item take is receipted done" "$(rstatus)" "done"
wact 90 "$(now_ms)" "type=take-ground" "x=121" "z=650" "item=999"
harness exec >/dev/null
check_eq "a changed ground item is refused" "$(rstatus)" "refused-ground-item-mismatch"
wact 91 "$(now_ms)" "type=take-ground" "x=5" "z=5" "item=27"
harness exec >/dev/null
check_eq "an empty ground-item tile is refused" "$(rstatus)" "refused-no-such-ground-item"
wact 92 "$(now_ms)" "type=take-ground" "x=121" "z=650" "item=27"
OUT="$(harness exec-unreachable-ground)"
refute "an unreachable ground item never reaches the game's take path" contains "$OUT" "take x="
check_eq "unreachable terrain is reported before dispatch" "$(rstatus)" \
    "refused-ground-item-unreachable"
wact 93 "$(now_ms)" "type=take-ground" "x=121" "z=650" "item=27"
OUT="$(harness exec-ground-needs-door)"
refute "a door-blocked ground item is not clicked through the wall" contains "$OUT" "take x="
check_eq "a proven closed door is distinguished from generic unreachability" "$(rstatus)" \
    "refused-ground-item-needs-door"

echo
echo "the learned player opens a door through the real bridge (game-player rules 5, 7):"
GP="$REPO/lib/game_player.py"
rm -f "$S/receipt.json" "$S/action.json"
python3 "$GP" init >/dev/null
python3 "$GP" objective enter-the-farmhouse >/dev/null
python3 "$GP" learn open-the-door --priority 70 --cooldown-ms 0 --once-per-objective \
    --trigger bound_visible=1 --action interact-bound --param obj=1 >/dev/null
harness state >/dev/null      # a fresh real snapshot listing the door
( sleep 0.4; harness exec > "$SANDBOX/door-exec.out" 2>&1 ) &
BRIDGE_JOB=$!
OUT="$(python3 "$GP" step)"; CODE=$?
wait "$BRIDGE_JOB"
check_eq "step fired and the REAL bridge's receipt came back done: exit 0" "$CODE" "0"
contains "$OUT" "fired rule=open-the-door" && ok "the learned rule owned the play" \
    || fail "the learned rule owned the play" "$OUT"
contains "$(cat "$SANDBOX/door-exec.out")" "bound x=121 z=650 dir=0 cmd=1" \
    && ok "and the door's Open executed in the client half" \
    || fail "and the door's Open executed in the client half" "$(cat "$SANDBOX/door-exec.out")"

echo
echo "the shipped eat rule, armed as shipped, fires through the real bridge (rules 12, 14):"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata-eat"
"$BG" init --food-xml "$SANDBOX/food.xml" >/dev/null
"$BG" enable eat-low-health >/dev/null
rm -f "$S/engine-state.json" "$S/decisions.jsonl" "$S/receipt.json" "$S/action.json" "$S"/notice-*.json
harness state >/dev/null            # hits 4/10 with food in the bag: streak 1
"$BG" run --once
refute "hold_ticks 2 as shipped: one snapshot does not fire" test -f "$S/action.json"
harness state 13 >/dev/null         # the bridge's next writing tick: a NEW tick to act on
"$BG" run --once
check "the second consecutive snapshot fires the eat" test -f "$S/action.json"
check_eq "slot 0, the food" "$(sandbox_count_in '^slot=0' "$S/action.json")" "1"
OUT="$(harness exec)"
contains "$OUT" "eat slot=0" && ok "the real bridge ate the food" \
    || fail "the real bridge ate the food" "$OUT"
check_eq "receipted done" "$(rstatus)" "done"

echo
echo "the shipped flee rule, armed as shipped, fires through the real bridge (rules 13-14):"
export DESKCRAB_GAME_DIR="$SANDBOX/gdata-flee"
cat > "$SANDBOX/food-elsewhere.xml" <<'EOF'
<map><entry><int>999</int><int>3</int></entry></map>
EOF
"$BG" init --food-xml "$SANDBOX/food-elsewhere.xml" >/dev/null
"$BG" enable flee-starved >/dev/null
rm -f "$S/engine-state.json" "$S/decisions.jsonl" "$S/receipt.json" "$S/action.json" "$S"/notice-*.json
harness hurt >/dev/null             # hits 3/10, nothing edible in the bag: streak 1
"$BG" run --once
refute "hold_ticks 2 as shipped: one snapshot does not fire" test -f "$S/action.json"
harness hurt 13 >/dev/null
"$BG" run --once
check "the second consecutive snapshot fires the flee" test -f "$S/action.json"
check_eq "compiled to a walk 5 tiles along the shipped direction (south)" \
    "$(sandbox_count_in '^z=655' "$S/action.json")" "1"
OUT="$(harness exec)"
contains "$OUT" "walk x=120 z=655" && ok "the real bridge walked the flee" \
    || fail "the real bridge walked the flee" "$OUT"
check_eq "receipted done" "$(rstatus)" "done"
