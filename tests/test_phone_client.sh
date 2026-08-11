#!/bin/bash
# Runs tests/phone_client_test.js, which drives the phone client's two loops
# (streamTurn, startWatch) against stubs.
# Run: bash tests/test_phone_client.sh
#
# node is not a dependency of DeskCrab — serve.py is stdlib python on purpose
# and the client is one HTML file — so this SKIPS rather than fails when node
# is absent. A skip is reported loudly; a suite that quietly runs nothing is
# the thing this repo keeps having to relearn.
#
# The skip exits 77, which the runner reports as a skip. It exited 0 until
# 2026-08-08, and the runner reads 0 as a pass — so on a box where node is off
# the non-interactive PATH (a systemd unit, any nvm setup) the only coverage
# the phone client's two loops have did not run, and the summary said one more
# test passed rather than one more test skipped.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

NODE="${NODE:-$(command -v node 2>/dev/null)}"
if [ -z "$NODE" ]; then
    # nvm keeps it off a non-interactive PATH; look where it actually lives.
    NODE="$(ls -1d "$HOME"/.config/nvm/versions/node/*/bin/node \
             "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | tail -n1)"
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    echo "  skip: no node found — the phone client's loops were not exercised."
    echo "  (set NODE=/path/to/node to run them)"
    exit 77
fi

# Two files, one verdict: the second carries the mid-turn recording cases
# (specs/phone.md rules 5 and 49 as amended, and the queue feeding rule 51),
# and a failure in either fails this test.
RC=0
"$NODE" "$REPO_DIR/tests/phone_client_test.js" || RC=1
"$NODE" "$REPO_DIR/tests/phone_client_midturn_test.js" || RC=1
exit "$RC"
