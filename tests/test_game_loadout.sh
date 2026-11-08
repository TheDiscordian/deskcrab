#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
check "activity preparation, durable choices, and action/reply integration" \
    env SANDBOX="$SANDBOX" python3 -B "$SANDBOX_REPO/tests/game_loadout_cases.py"
