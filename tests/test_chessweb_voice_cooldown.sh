#!/bin/bash
# The post-move wake's per-game VOICE COOLDOWN (specs/chessweb.md rule 7).
#
# The cap bounds only what pends, and 2026-08-15 (00:48-01:11) measured the
# hole: a game at browser speed put a move on the board every ten to thirty
# seconds, every post-move booking found the previous wake already fired —
# nothing pending, cap satisfied — and five wakes on one game fired inside
# ninety seconds, each announcing it had nothing left to say, two of them
# aloud. The fix: the first voice after a quiet spell books at 1s as ever,
# and inside $DESKCRAB_CHESSWEB_VOICE_COOLDOWN (default 180s) the fuse is
# stretched to the cooldown's remaining span, parking the booking PENDING
# where the cap and the byte-identical reason can finally hold it.
#
# Proven here, off the full argv a recording wake stub wrote down:
#   1. cooldown on: the first booking's fuse is 1s, and the later bookings'
#      fuses are stretched into the cooldown window — never 1s again
#   2. a queue refusal ("Not booked") does not advance the cooldown clock:
#      the booking after a refusal still aims at the SAME fire moment, so
#      its fuse is no longer than the refused one's
#   3. cooldown 0: every booking is back to the literal 1s — the knob
#      genuinely disables the pacing
# Run: bash tests/test_chessweb_voice_cooldown.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
SCENARIO="$REPO/tests/lib/chessweb_scenario.py"
COOLDOWN=300

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

# The recording wake stub: full argv, one booking per line, tab-separated.
WAKE_STUB="$SANDBOX/wake-argv-stub"
cat > "$WAKE_STUB" <<'SH'
#!/bin/bash
{ printf '%s\t' "$@"; printf '\n'; } >> "$CHESSWEB_WAKE_LOG"
SH
chmod +x "$WAKE_STUB"

# The refusing wake stub: same record, but every booking after the first
# answers with the queue's own cap-refusal sentence — the shape the bridge
# must read as "do not advance the cooldown clock".
REFUSE_STUB="$SANDBOX/wake-refuse-stub"
cat > "$REFUSE_STUB" <<'SH'
#!/bin/bash
{ printf '%s\t' "$@"; printf '\n'; } >> "$CHESSWEB_WAKE_LOG"
n="$(grep -c 'a move landed' "$CHESSWEB_WAKE_LOG" 2>/dev/null)" || n=0
[ "${n:-0}" -gt 1 ] \
    && echo "Not booked — chessweb already holds 1 pending wakes (cap 1)."
exit 0
SH
chmod +x "$REFUSE_STUB"

# The mover's model call, stubbed (specs/chessweb.md rule 16f), replies keyed
# by ply so three quick exchanges each get their own deterministic answer.
MOVER_STUB="$SANDBOX/mover-stub"
cat > "$MOVER_STUB" <<'SH'
#!/bin/bash
prompt="$(cat)"
while IFS=$'\t' read -r pat reply; do
    [ -n "$pat" ] || continue
    case "$prompt" in *"$pat"*) printf '%s\n' "$reply"; exit 0 ;; esac
done < "$CHESSWEB_MOVER_REPLIES"
exit 0
SH
chmod +x "$MOVER_STUB"
REPLIES="$SANDBOX/replies.tsv"
printf 'ply 1\te7e5\nply 3\tb8c6\nply 5\tg8f6\n' > "$REPLIES"

BRIDGE_PID=""
PORT=""
start_bridge() { # <chess dir> <wake log> <wake cmd> <cooldown> [serve args...]
    local dir="$1" wakelog="$2" wakecmd="$3" cooldown="$4"
    shift 4
    : > "$wakelog"
    : > "$SANDBOX/serve.log"
    DESKCRAB_CHESS_DIR="$dir" CHESSWEB_WAKE_LOG="$wakelog" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$wakecmd" \
        DESKCRAB_CHESSWEB_VOICE_COOLDOWN="$cooldown" \
        DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
        CHESSWEB_MOVER_REPLIES="$REPLIES" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$CLIENT" --poll 0.2 --human-side white "$@" \
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
scn() { # <name> [args...] — one scenario, its own prints as the detail
    local name="$1"
    if timeout 60 "$VENV_PY" -B "$SCENARIO" "$@"; then
        ok "$name"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
        fail "$name"
    fi
}
wait_wakes() { # <log> <count> — the booking trails the echo by a beat
    local log="$1" want="$2" n
    for _ in $(seq 1 50); do
        n="$(grep -c 'a move landed' "$log" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge "$want" ] && return 0
        sleep 0.1
    done
    return 1
}
# The fuse ("179s") of the Nth post-move booking, as a bare number. In the
# recorded argv the when positional sits right after the cap flags and
# `--by chessweb`: wake-at --cap 1 --cap-prefix <p> --by chessweb <when> event.
fuse_of() { # <log> <n>
    awk -F'\t' -v n="$2" '
        index($0, "a move landed") == 0 { next }
        ++i == n { sub(/s$/, "", $8); print $8; exit }' "$1"
}

CAPPED_CMD="$WAKE_STUB wake-at --by chessweb 1s event"
REFUSED_CMD="$REFUSE_STUB wake-at --by chessweb 1s event"

echo "cooldown on: the first voice is immediate, the next is paced into the window:"
CH="$SANDBOX/chess-paced"
WAKELOG="$SANDBOX/wake-paced.log"
if start_bridge "$CH" "$WAKELOG" "$CAPPED_CMD" "$COOLDOWN" --opponent guest; then
    scn wakecap "$PORT" "$CH" guest-001 2
    check "two post-move wakes were booked" wait_wakes "$WAKELOG" 2
    F1="$(fuse_of "$WAKELOG" 1)"; F2="$(fuse_of "$WAKELOG" 2)"
    [ "$F1" = "1" ] \
        || { sed 's/^/    wake: /' "$WAKELOG"; \
             fail "the first voice should book at 1s, not ${F1}s"; }
    ok "the first booking's fuse is the literal 1s"
    # The exchange runs in seconds, so the stretched fuse is the cooldown
    # minus that handful — anywhere past 200s proves the stretch without
    # racing the clock, and past the cooldown+1 would mean drift. Since rule
    # 7's 2026-08-26 change both sides' moves book, so booking 1 is the
    # sitter's move and booking 2 her reply seconds later — one shared
    # pacing clock across both triggers. (Only the first two bookings are
    # judged: this stub answers every booking as taken, so later ones
    # legitimately aim whole cooldowns further out — the refusal scenario
    # below is where their truth lives.)
    case "$F2" in ''|*[!0-9]*) fail "booking 2 carries no numeric fuse: '$F2'" ;; esac
    [ "$F2" -gt 200 ] && [ "$F2" -le $((COOLDOWN + 1)) ] \
        || { sed 's/^/    wake: /' "$WAKELOG"; \
             fail "booking 2's fuse (${F2}s) is not stretched into the ${COOLDOWN}s window"; }
    ok "the second booking's fuse is stretched into the cooldown window (${F2}s)"
fi
stop_bridge

echo "a refusal does not advance the clock — the next booking aims at the same moment:"
CH2="$SANDBOX/chess-refused"
WAKELOG2="$SANDBOX/wake-refused.log"
if start_bridge "$CH2" "$WAKELOG2" "$REFUSED_CMD" "$COOLDOWN" --opponent guest; then
    scn wakecap "$PORT" "$CH2" guest-001 3
    check "three post-move bookings were attempted" wait_wakes "$WAKELOG2" 3
    R2="$(fuse_of "$WAKELOG2" 2)"; R3="$(fuse_of "$WAKELOG2" 3)"
    case "$R2$R3" in *[!0-9]*|'') fail "refused bookings carry no numeric fuses: '$R2' '$R3'" ;; esac
    # Booking 2 was refused. Had the clock advanced on it anyway, booking 3
    # would aim a whole cooldown later (fuse near 2x). Aiming at the SAME
    # fire moment means its fuse can only have shrunk with the clock.
    [ "$R3" -le "$R2" ] \
        || { sed 's/^/    wake: /' "$WAKELOG2"; \
             fail "after a refusal the next fuse grew (${R2}s -> ${R3}s): the clock advanced on a booking the queue never took"; }
    [ "$R3" -le $((COOLDOWN + 1)) ] \
        || fail "the fuse after a refusal (${R3}s) is past the cooldown window entirely"
    ok "after a refusal the next booking still aims at the same fire moment (${R2}s -> ${R3}s)"
fi
stop_bridge

echo "cooldown 0: the knob disables the pacing and every fuse is 1s again:"
CH3="$SANDBOX/chess-off"
WAKELOG3="$SANDBOX/wake-off.log"
if start_bridge "$CH3" "$WAKELOG3" "$CAPPED_CMD" 0 --opponent guest; then
    scn wakecap "$PORT" "$CH3" guest-001 2
    check "two post-move wakes were booked" wait_wakes "$WAKELOG3" 2
    O1="$(fuse_of "$WAKELOG3" 1)"; O2="$(fuse_of "$WAKELOG3" 2)"
    { [ "$O1" = "1" ] && [ "$O2" = "1" ]; } \
        || { sed 's/^/    wake: /' "$WAKELOG3"; \
             fail "with the cooldown off the fuses should both be 1s (got ${O1}s, ${O2}s)"; }
    ok "cooldown 0 books every voice at the literal 1s"
fi
stop_bridge
