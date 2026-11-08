#!/bin/bash
# The kept wire (specs/chessweb.md rule 25): a shipped-client page whose
# socket drops redials by itself — exponential backoff from ~1s doubling to
# the ~30s cap, jittered, indefinitely; a hidden page holds its hand and a
# return to visibility (or the network coming back) redials at once with the
# backoff reset; a redial that lands resumes the old role uninvited so rule
# 3's join sync (Team + replay) repaints the board from the store — a move
# recorded during the outage appears, never missed; and the status word /
# greyed board say the truth while the wire is down. Until 2026-09-03 a
# dropped connection left a live-looking board silently frozen mid-game.
#
# The client logic runs through tests/chess_client_reconnect_test.js, which
# lifts the functions out of lib/chessweb_client/board.js and drives them
# against stubs — a fake WebSocket, fake timers, pinned Math.random — the
# chat harness's own technique: no network, no server, no model anywhere.
# node is not a dependency of DeskCrab, so this SKIPS (77) rather than
# fails when node is absent.
# Run: bash tests/test_chessweb_reconnect.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

BOARD="$REPO_DIR/lib/chessweb_client/board.js"
PAGE="$REPO_DIR/lib/chessweb_client/index.html"
SHEET="$REPO_DIR/lib/chessweb_client/style.css"

# --- the wiring the node harness cannot see: the page-level listeners ------
# reconnectNow is what the node cases drive; these pins hold that the real
# page actually calls it on the browser's own signals.
grep -q "addEventListener('online', reconnectNow)" "$BOARD" \
    && ok "the online event is wired to the immediate redial" \
    || fail "the online event is wired to the immediate redial"
grep -q "visibilitychange" "$BOARD" \
    && ok "a return to visibility is wired to redial" \
    || fail "a return to visibility is wired to redial"
grep -q "addEventListener('offline', paintLink)" "$BOARD" \
    && ok "going offline repaints the status word" \
    || fail "going offline repaints the status word"
grep -q 'id="connword"' "$PAGE" \
    && ok "the page carries the status word element" \
    || fail "the page carries the status word element"
grep -q '\.connword' "$SHEET" \
    && ok "the sheet styles the status word" \
    || fail "the sheet styles the status word"
grep -q '#boardwrap\.stale' "$SHEET" \
    && ok "the sheet greys a stale board" \
    || fail "the sheet greys a stale board"

# --- the behaviour, over the lifted client ---------------------------------
NODE="${NODE:-$(command -v node 2>/dev/null)}"
[ -z "$NODE" ] && [ -x /usr/bin/node ] && NODE=/usr/bin/node
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    sandbox_skip "no node found — the reconnect loop was not exercised (set NODE=/path/to/node)"
fi

if "$NODE" "$REPO_DIR/tests/chess_client_reconnect_test.js" \
        > "$T/reconnect-node.out" 2>&1; then
    NODE_RC=0
else
    NODE_RC=1
fi
# The node harness's assertions are this suite's assertions: mirrored
# through ok/fail line by line rather than collapsed to one verdict, so a
# red inside it is a red out here, visibly and arithmetically. Its own
# tally line is dropped — the summary at the bottom is the one that counts.
while IFS= read -r line; do
    case "$line" in
        "  ok: "*)   ok "${line#  ok: }" ;;
        "  FAIL: "*) fail "${line#  FAIL: }" ;;
        "chess client reconnect: "*" passed, "*" failed") ;;
        *) [ -n "$line" ] && echo "$line" ;;
    esac
done < "$T/reconnect-node.out"
[ "$NODE_RC" -eq 0 ] \
    && ok "the client harness verdict is green" \
    || fail "the client harness verdict is green" "$(tail -n3 "$T/reconnect-node.out")"
