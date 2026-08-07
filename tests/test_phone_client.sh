#!/bin/bash
# Runs tests/phone_client_test.js, which drives the phone client's two loops
# (streamTurn, startWatch) against stubs.
# Run: bash tests/test_phone_client.sh
#
# node is not a dependency of DeskCrab — serve.py is stdlib python on purpose
# and the client is one HTML file — so this SKIPS rather than fails when node
# is absent. A skip is reported loudly; a suite that quietly runs nothing is
# the thing this repo keeps having to relearn.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

NODE="${NODE:-$(command -v node 2>/dev/null)}"
if [ -z "$NODE" ]; then
    # nvm keeps it off a non-interactive PATH; look where it actually lives.
    NODE="$(ls -1d "$HOME"/.config/nvm/versions/node/*/bin/node \
             "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | tail -n1)"
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    echo "SKIPPED: no node found — the phone client's loops were not exercised."
    echo "(set NODE=/path/to/node to run them)"
    exit 0
fi

exec "$NODE" "$REPO_DIR/tests/phone_client_test.js"
