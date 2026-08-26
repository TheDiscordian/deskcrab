#!/bin/bash
# The table chat's clip queue (specs/chessweb.md rule 24e, the queue
# discipline): every message of hers that arrives while the speak toggle is
# on is voiced exactly once, in order, one clip at a time; a dead or
# never-starting clip is witnessed in the console and the queue advances; a
# sounding clip is never cut by the give-up bound; history, resets, the
# toggle, and other roles' lines are never voiced. The first shipped shape
# spoke at most one clip per poll batch ("one clip per batch is plenty") and
# lost the rest with no witness — the node cases were red against it.
#
# The client logic runs through tests/chess_client_chat_test.js, which lifts
# the functions out of lib/chessweb_client/board.js and drives them against
# stubs — the phone client tests' own technique. node is not a dependency of
# DeskCrab, so this SKIPS (77) rather than fails when node is absent.
# Run: bash tests/test_chess_chat_playback.sh
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

NODE="${NODE:-$(command -v node 2>/dev/null)}"
if [ -z "$NODE" ]; then
    # nvm keeps it off a non-interactive PATH; look where it actually lives.
    NODE="$(ls -1d "$HOME"/.config/nvm/versions/node/*/bin/node \
             "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | tail -n1)"
fi
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    echo "  skip: no node found — the chat clip queue was not exercised."
    echo "  (set NODE=/path/to/node to run it)"
    exit 77
fi

"$NODE" "$REPO_DIR/tests/chess_client_chat_test.js"
