#!/bin/bash
# Spec rules 11 and 11c: the plan is ONE method for the current leg. The door
# refuses standing-instruction language in every observed disguise — bare
# prohibitions, gerund ban lists, reworded work-status lists ("X is PAUSED"),
# and queued future plans ("resume Y next sitting") — and, while the
# objective declares a measure, refuses any new plan decision on a stale
# progress record. Milestones close on evidence only, and the cap doctrine
# refuses within on take-ground and attack-npc at the learn door.
# Run: bash tests/test_game_player_plan_hygiene.sh
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
python3 "$GP" objective hygiene-test >/dev/null

echo "the plan is one method for the current leg (spec rule 11):"
refute "a bare prohibition is refused" \
    python3 "$GP" plan "Fight warriors. Never go back to woodcutting."
refute "a gerund ban list is refused" \
    python3 "$GP" plan "Fight warriors. No woodcutting, no thieving."
refute "a reworded work-status list is refused" \
    python3 "$GP" plan "Kill cows for hides; melee, woodcutting and thieving are PAUSED."
refute "a queued future plan is refused" \
    python3 "$GP" plan "Fight warriors by the bank. Resume the crafting run next sitting."
refute "a how-to lesson is refused" \
    python3 "$GP" plan "How to loot: read ground items after each kill and take everything."
check "a clean single method passes" \
    python3 "$GP" plan "Fight the warriors by the bank in melee, banking loot as the bag fills"
refute "the same disguises are refused on revision too" \
    python3 "$GP" plan --revise "adding a pause list" \
        "Fight the warriors by the bank; prayer and thieving are on hold."

echo
echo "the freshness gate holds plan decisions to the measure (spec rule 11c):"
python3 "$GP" objective hygiene-test --measure "read the standings table" >/dev/null
refute "a plan revision refuses while the measure was never read" \
    python3 "$GP" plan --revise "switching legs" "Chop trees by the bank and burn the logs"
python3 "$GP" progress "standings read: second overall, first in three skills" >/dev/null
check "the same revision passes once progress is fresh" \
    python3 "$GP" plan --revise "switching legs" "Chop trees by the bank and burn the logs"

echo
echo "milestones close on evidence, never on feeling (spec rule 11c):"
check "a milestone opens" python3 "$GP" milestone add first-in-thieving
refute "closing without evidence is refused" \
    python3 "$GP" milestone done first-in-thieving
check "closing on evidence passes" \
    python3 "$GP" milestone done first-in-thieving --evidence "standings: rank 1 thieving"
refute "reopening without live-data reason is refused" \
    python3 "$GP" milestone reopen first-in-thieving

echo
echo "the cap doctrine refuses distance caps on wanting (spec rule 5):"
refute "take-ground with within is refused" \
    python3 "$GP" learn capped-take --priority 40 --trigger objective_is=hygiene-test \
        --trigger out_of_combat=true --trigger ground_item_visible=20 \
        --action take-ground --param item=20 --param within=1
refute "attack-npc with within is refused" \
    python3 "$GP" learn capped-attack --priority 40 --trigger objective_is=hygiene-test \
        --trigger out_of_combat=true --trigger npc_visible=86 \
        --action attack-npc --param npc=86 --param within=10
check "the uncapped forms still learn" \
    python3 "$GP" learn clean-take --priority 40 --trigger objective_is=hygiene-test \
        --trigger out_of_combat=true --trigger ground_item_visible=20 \
        --action take-ground --param item=20

refute "no model CLI was ever invoked" test -f "$SANDBOX/model-called"
