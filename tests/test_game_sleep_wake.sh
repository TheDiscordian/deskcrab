#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
check "local and resident sleep verdicts preserve required input and reasoning permission" \
    env SANDBOX="$SANDBOX" python3 -B "$SANDBOX_REPO/tests/game_sleep_wake_cases.py" "${1:-$REAL_HOME/Games/OpenRSC/headless/betty-openrsc}"
