#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
check "activity selection, rule scopes, and memories before decisions" \
    env SANDBOX="$SANDBOX" python3 -B "$SANDBOX_REPO/tests/game_activity_selection_cases.py"
