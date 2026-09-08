#!/bin/bash
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
check "timed selection and scheduling evidence contracts" \
    env SANDBOX="$SANDBOX" python3 -B "$SANDBOX_REPO/tests/chess_benchmark_cases.py"
