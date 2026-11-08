#!/bin/bash
# The table chat against the mobile standard, server half (specs/chessweb.md
# rules 24c and 24e): a typed message and BOTH colours' landed moves reliably
# yield a displayed reply and an own-voice clip, moves are never gated on any
# of it, and a burst of triggers coalesces to ONE message composed from the
# thread as it stands NOW. Proven end to end with every model call stubbed:
#   - the SITTER's move alone triggers her table reply — asserted while the
#     store provably holds only their move (the mover's stub is held on a
#     delay), so her table voice does not hang off her own replies
#   - her own landed move triggers the same: reply on the record, displayed
#     via GET /chat, synthesized via GET /chat/audio as audio/ogg
#   - a rapid pair of typed messages supersedes the in-flight call: exactly
#     one reply posts, and its prompt carries both messages — current state
#     wins, the stale flight's words are discarded with it
# Run: bash tests/test_chess_chat_flow.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
SCENARIO="$REPO/tests/lib/chessweb_scenario.py"

# Read-only use of a live path: an interpreter, not state — the same bargain
# tests/test_chessweb.sh strikes. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

CLIENT="$SANDBOX/client"
mkdir -p "$CLIENT"
printf '%s\n' '<html><input id="serveraddr" value="127.0.0.1:8181"></html>' \
    > "$CLIENT/index.html"

WAKE_STUB="$SANDBOX/wake-stub"
printf '#!/bin/bash\n:\n' > "$WAKE_STUB"
chmod +x "$WAKE_STUB"

# The mover, stubbed and HELD (rule 16f): the sleep keeps her move seconds
# away, so a chat message seen while the store holds one move can only be
# the sitter's move's own trigger.
SLOW_MOVER="$SANDBOX/slow-mover"
cat > "$SLOW_MOVER" <<'SH'
#!/bin/bash
prompt="$(cat)"
sleep 6
case "$prompt" in *"ply 1"*) printf 'e7e5\n' ;; esac
exit 0
SH
chmod +x "$SLOW_MOVER"

# Her chat call, stubbed fast (rule 24d): prompt kept as evidence, reply off
# a substring map, PASS the default.
CHAT_STUB="$SANDBOX/chat-stub"
cat > "$CHAT_STUB" <<'SH'
#!/bin/bash
prompt="$(cat)"
printf '%s\n----\n' "$prompt" >> "$CHESSWEB_CHAT_LOG"
[ -f "${CHESSWEB_CHAT_REPLIES:-}" ] || { echo PASS; exit 0; }
while IFS=$'\t' read -r pat reply; do
    [ -n "$pat" ] || continue
    case "$prompt" in *"$pat"*) printf '%s\n' "$reply"; exit 0 ;; esac
done < "$CHESSWEB_CHAT_REPLIES"
echo PASS
SH
chmod +x "$CHAT_STUB"

# The same chat stub held SLOW, for the burst: the sleep keeps the first
# call provably in flight when the second trigger lands to supersede it.
SLOW_CHAT_STUB="$SANDBOX/slow-chat-stub"
cat > "$SLOW_CHAT_STUB" <<'SH'
#!/bin/bash
prompt="$(cat)"
printf '%s\n----\n' "$prompt" >> "$CHESSWEB_CHAT_LOG"
sleep 2
[ -f "${CHESSWEB_CHAT_REPLIES:-}" ] || { echo PASS; exit 0; }
while IFS=$'\t' read -r pat reply; do
    [ -n "$pat" ] || continue
    case "$prompt" in *"$pat"*) printf '%s\n' "$reply"; exit 0 ;; esac
done < "$CHESSWEB_CHAT_REPLIES"
echo PASS
SH
chmod +x "$SLOW_CHAT_STUB"

# The synth pipeline, stubbed (rule 24e): argv is the output path then the
# text, recognizable bytes out, exactly the crab-synth shape.
SYNTH_STUB="$SANDBOX/synth-stub"
cat > "$SYNTH_STUB" <<'SH'
#!/bin/bash
out="$1"; shift
printf 'OggSfake-clip:%s' "$*" > "$out"
SH
chmod +x "$SYNTH_STUB"

BRIDGE_PID=""
PORT=""
start_bridge() { # <chess dir> <chat stub> <chat log> <chat replies> <mover>
    local dir="$1" chatstub="$2" chatlog="$3" replies="$4" mover="$5"
    : > "$chatlog"
    : > "$SANDBOX/serve.log"
    env DESKCRAB_CHESS_DIR="$dir" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        DESKCRAB_CHESS_MOVER_CMD="$mover" \
        DESKCRAB_CHESS_REFLEX=0 \
        DESKCRAB_CHESS_CHAT_CMD="$chatstub" \
        CHESSWEB_CHAT_LOG="$chatlog" \
        CHESSWEB_CHAT_REPLIES="$replies" \
        DESKCRAB_CHESSWEB_SYNTH_CMD="$SYNTH_STUB" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$CLIENT" --poll 0.2 --human-side white --opponent guest \
        >> "$SANDBOX/serve.log" 2>&1 &
    BRIDGE_PID=$!
    PORT=""
    for _ in $(seq 1 100); do
        PORT="$(sed -n 's/.*on port \([0-9]*\)$/\1/p' "$SANDBOX/serve.log" | head -1)"
        [ -n "$PORT" ] && return 0
        kill -0 "$BRIDGE_PID" 2>/dev/null || break
        sleep 0.1
    done
    sed 's/^/    serve: /' "$SANDBOX/serve.log"
    fail "the bridge never reported its port"
    return 1
}
stop_bridge() {
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null
    wait "$BRIDGE_PID" 2>/dev/null
    BRIDGE_PID=""
}
scn() { # <name> [args...]
    local name="$1"
    if timeout 90 "$VENV_PY" -B "$SCENARIO" "$@"; then
        ok "$name"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -20
        fail "$name"
    fi
}

echo "reply and her own voice after both colours' landed moves:"
CH="$SANDBOX/chess-bothvoices"
REPLIES="$SANDBOX/replies-moves.tsv"
printf 'Just now: Visitor played\tA bold start.\n' > "$REPLIES"
printf 'Just now: You played\te5 keeps it classical.\n' >> "$REPLIES"
if start_bridge "$CH" "$CHAT_STUB" "$SANDBOX/chat-both.log" "$REPLIES" \
        "$SLOW_MOVER"; then
    scn chat_bothvoices "$PORT" "$CH" "$SANDBOX/chat-both.log"
fi
stop_bridge

echo "a burst of typed messages coalesces to one reply, current state wins:"
CH2="$SANDBOX/chess-burst"
BURST_REPLIES="$SANDBOX/replies-burst.tsv"
printf 'Just now: Visitor says: second message now\tOne at a time!\n' \
    > "$BURST_REPLIES"
printf 'first message here\tAnswer one.\n' >> "$BURST_REPLIES"
if start_bridge "$CH2" "$SLOW_CHAT_STUB" "$SANDBOX/chat-burst.log" \
        "$BURST_REPLIES" "$SLOW_MOVER"; then
    scn chat_burst "$PORT" "$CH2" "$SANDBOX/chat-burst.log"
fi
stop_bridge
