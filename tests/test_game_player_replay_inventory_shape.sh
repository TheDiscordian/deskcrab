#!/bin/bash
# A replay case is built from a RECORDED snapshot, and the recorded brief form
# carries inventory as plain item ids while the live bridge carries objects.
# make_trigger_fn already read both shapes; the compile side did not, so every
# held-item action — click-inventory, drop-inventory, use-item-ground, and the
# bank grid's deposit fallback — raised AttributeError the moment a recorded
# snapshot reached it, and an inventory reflex could not be pinned by a case
# at all. Both shapes must compile identically.
# Run: bash tests/test_game_player_replay_inventory_shape.sh
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

python3 "$GP" init >/dev/null

check "an inventory-click recovery rule can be learned" \
    python3 "$GP" learn sleep-in-bag --priority 80 --cooldown-ms 0 \
        --trigger objective_is=shape-test --trigger fatigue_at_least=100 \
        --trigger inventory_has=1263 --trigger out_of_combat=true \
        --action click-inventory --param item=1263 --param button=1
check "a held-item drop rule can be learned" \
    python3 "$GP" learn drop-one-log --priority 70 --cooldown-ms 0 \
        --trigger objective_is=shape-test --trigger inventory_has=14 \
        --trigger out_of_combat=true \
        --action drop-inventory --param item=14

# The live shape: inventory entries are objects.
LIVE_SNAP="$SANDBOX/live.json"
cat > "$LIVE_SNAP" <<'JSON'
{"tick": 100, "x": 100, "z": 100, "walking": false, "in_combat": false,
 "fatigue": 100,
 "inventory": [{"id": 1263, "name": "Sleeping Bag", "count": 1}],
 "messages": [], "players": [], "npcs": [], "objects": [], "bounds": [],
 "ground_items": [], "shop_open": false, "shop_items": [],
 "bank_open": false, "bank_items": []}
JSON
# The recorded brief shape: the SAME inventory, as plain item ids.
BRIEF_SNAP="$SANDBOX/brief.json"
cat > "$BRIEF_SNAP" <<'JSON'
{"tick": 101, "x": 100, "z": 100, "walking": false, "in_combat": false,
 "fatigue": 100, "inventory": [1263],
 "messages": [], "players": [], "npcs": [], "objects": [], "bounds": [],
 "ground_items": [], "shop_open": false, "shop_items": [],
 "bank_open": false, "bank_items": []}
JSON
DROP_SNAP="$SANDBOX/drop.json"
cat > "$DROP_SNAP" <<'JSON'
{"tick": 102, "x": 100, "z": 100, "walking": false, "in_combat": false,
 "fatigue": 20, "inventory": [14, 14],
 "messages": [], "players": [], "npcs": [], "objects": [], "bounds": [],
 "ground_items": [], "shop_open": false, "shop_items": [],
 "bank_open": false, "bank_items": []}
JSON

check "the live object shape compiles the inventory click" \
    python3 "$GP" test add live-shape-sleeps --objective shape-test \
        --expect sleep-in-bag --snapshot "$LIVE_SNAP" \
        --expect-action '{"type":"click-inventory","item":1263,"button":1}'
check "the recorded id shape compiles the same inventory click" \
    python3 "$GP" test add brief-shape-sleeps --objective shape-test \
        --expect sleep-in-bag --snapshot "$BRIEF_SNAP" \
        --expect-action '{"type":"click-inventory","item":1263,"button":1}'
check "the recorded id shape compiles a held-item drop" \
    python3 "$GP" test add brief-shape-drops --objective shape-test \
        --expect drop-one-log --snapshot "$DROP_SNAP" \
        --expect-action '{"type":"drop-inventory","item":14}'
check "the suite holds every shape green" python3 "$GP" test

# An item the recorded snapshot does not hold is still refused, so tolerance
# of the brief shape never becomes a blanket yes.
EMPTY_SNAP="$SANDBOX/empty.json"
cat > "$EMPTY_SNAP" <<'JSON'
{"tick": 103, "x": 100, "z": 100, "walking": false, "in_combat": false,
 "fatigue": 100, "inventory": [87, 166],
 "messages": [], "players": [], "npcs": [], "objects": [], "bounds": [],
 "ground_items": [], "shop_open": false, "shop_items": [],
 "bank_open": false, "bank_items": []}
JSON
check "a recorded snapshot without the bag stays a gap" \
    python3 "$GP" test add brief-shape-no-bag --objective shape-test \
        --expect none --snapshot "$EMPTY_SNAP"
check "the suite still holds green with the negative case" python3 "$GP" test

refute "no model CLI was ever invoked" test -f "$SANDBOX/model-called"
