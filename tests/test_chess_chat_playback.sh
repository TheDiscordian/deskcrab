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
# stubs — the phone client tests' own technique, inside the one sandbox the
# way test_phone_dead_clip.sh runs its node half. node is not a dependency of
# DeskCrab, so this SKIPS (77) rather than fails when node is absent. This
# file shipped without the sandbox line and run.sh's roll call rightly
# stopped the whole suite on it; the conversion is the fix the roll call
# demands, not an exception added to UNSANDBOXED.
# Run: bash tests/test_chess_chat_playback.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

NODE="${NODE:-$(command -v node 2>/dev/null)}"
[ -z "$NODE" ] && [ -x /usr/bin/node ] && NODE=/usr/bin/node
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    sandbox_skip "no node found — the chat clip queue was not exercised (set NODE=/path/to/node)"
fi

if "$NODE" "$REPO_DIR/tests/chess_client_chat_test.js" \
        > "$T/chat-node.out" 2>&1; then
    NODE_RC=0
else
    NODE_RC=1
fi
# The node harness's assertions are this suite's assertions: mirrored through
# ok/fail line by line rather than collapsed to one verdict, so a red inside
# it is a red out here, visibly and arithmetically. Its own tally line is
# dropped — the summary at the bottom is the one that counts.
while IFS= read -r line; do
    case "$line" in
        "  ok: "*)   ok "${line#  ok: }" ;;
        "  FAIL: "*) fail "${line#  FAIL: }" ;;
        "chess client chat: "*" passed, "*" failed") ;;
        *) [ -n "$line" ] && echo "$line" ;;
    esac
done < "$T/chat-node.out"
[ "$NODE_RC" -eq 0 ] \
    && ok "the client harness verdict is green" \
    || fail "the client harness verdict is green" "$(tail -n3 "$T/chat-node.out")"
