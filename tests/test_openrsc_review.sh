#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
check "hourly reviewer routing, evidence, concurrency, and failure contracts" \
    env SANDBOX="$SANDBOX" python3 -B "$SANDBOX_REPO/tests/openrsc_review_cases.py"
