#!/bin/bash
# The bridge<->engine protocol of specs/game-reflex.md, proven cross-language:
# the REAL orsc.ReflexBridge is compiled read-only out of the local game
# checkout (the same file the client jar carries) and driven against a
# scripted fake host, while the real Python engine reads the snapshots it
# writes and writes the actions it consumes. No game, no display, no login —
# and skipped honestly where there is no local game tree to borrow.
# Run: bash tests/test_game_reflex_bridge.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
BG="$REPO/lib/betty-game"

# The game tree is borrowed READ-ONLY, like the chess venv: the sandbox moved
# HOME, so the real one is recovered from the live-data path the sandbox
# recorded before the move.
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
assert s["x"] == 120 and s["z"] == 650
assert s["walking"] is False and s["in_combat"] is False
assert s["talking_to_npc"] is False
assert s["opponent"] is None
assert s["inventory"] == [{"id": 132, "count": 1}, {"id": 81, "count": 3}]
assert s["ground_items"] == [
    {"id": 27, "x": 121, "z": 650},
    {"id": 10, "x": 130, "z": 650},
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
assert s["talking_to_npc"] is True
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
python3 - "$S/state.json" <<'PY' && ok "the snapshot lists visible NPCs nearest first" \
    || fail "the snapshot lists visible NPCs nearest first"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["npcs"] == [
    {"sidx": 7, "id": 474, "x": 121, "z": 651},
    {"sidx": 9, "id": 485, "x": 125, "z": 650},
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
    {"id": 57, "x": 121, "z": 649, "dir": 2},
    {"id": 493, "x": 196, "z": 726, "dir": 0},
], s.get("objects")
PY
python3 - "$S/state.json" <<'PY' && ok "and the wall objects (doors) nearest first, with wall direction" \
    || fail "and the wall objects (doors) nearest first, with wall direction"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["bounds"] == [
    {"id": 1, "x": 121, "z": 650, "dir": 0},
    {"id": 2, "x": 140, "z": 660, "dir": 1},
], s.get("bounds")
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
