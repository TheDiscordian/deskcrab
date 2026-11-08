#!/bin/bash
# The move-triggered wake, both sides' moves (specs/chessweb.md rule 7, the
# 2026-08-26 change). Until then only HER moves booked the post-move wake, so
# the whole of her chance to notice a game hung off her own replies: the
# sitter played, the board changed, and nothing anywhere gave her a turn to
# look at it or decide to speak — a whole silent game (the engineering record
# of 2026-08-17, re-diagnosed 2026-08-20: "there is NO wake on the opponent's
# move at all").
#
# Proven here, with the mover's stub held on a deliberate delay so the two
# triggers cannot be confused:
#   1. the SITTER'S move alone books the post-move wake, while the store
#      provably holds only their move — the opportunity to speak between
#      turns exists before, and independent of, her own reply
#   2. the reason leaves silence open in so many words ("say nothing at
#      all"), points at the live game read at speak-time (betty-chess
#      status), carries no san, and never asks her to play — the resident
#      mover alone plays moves, and the reply that lands is its
#   3. her own reply books too, on the SAME per-game pacing clock: the
#      sitter's booking goes at the literal 1s, hers is stretched into the
#      cooldown window where it parks pending — throttled is not absent
#   4. both bookings carry the per-game cap under the shared reason head
# Run: bash tests/test_chessweb_move_wake.sh
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

# The mover's model call, stubbed (specs/chessweb.md rule 16f) and HELD: the
# sleep keeps her reply seconds away, so a booking seen while the store holds
# one move can only be the sitter's move's own.
MOVER_STUB="$SANDBOX/mover-stub"
cat > "$MOVER_STUB" <<'SH'
#!/bin/bash
sleep 8
prompt="$(cat)"
case "$prompt" in *"ply 1"*) printf 'e7e5\n' ;; esac
exit 0
SH
chmod +x "$MOVER_STUB"

CAPPED_CMD="$WAKE_STUB wake-at --by chessweb 1s event"
CH="$SANDBOX/chess-movewake"
WAKELOG="$SANDBOX/wake-movewake.log"
: > "$WAKELOG"
: > "$SANDBOX/serve.log"

DESKCRAB_CHESS_DIR="$CH" CHESSWEB_WAKE_LOG="$WAKELOG" \
    DESKCRAB_CHESSWEB_WAKE_CMD="$CAPPED_CMD" \
    DESKCRAB_CHESSWEB_VOICE_COOLDOWN="$COOLDOWN" \
    DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
    "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
    --client "$CLIENT" --poll 0.2 --human-side white --opponent guest \
    >> "$SANDBOX/serve.log" 2>&1 &
BRIDGE_PID=$!
PORT=""
for _ in $(seq 1 100); do
    PORT="$(sed -n 's/.*on port \([0-9]*\)$/\1/p' "$SANDBOX/serve.log" | head -1)"
    [ -n "$PORT" ] && break
    kill -0 "$BRIDGE_PID" 2>/dev/null || break
    sleep 0.1
done
[ -n "$PORT" ] || { sed 's/^/    serve: /' "$SANDBOX/serve.log"; \
                    die "the bridge never reported its port"; }

echo "a sitter's move is the opportunity to wake; her reply is the mover's:"
if timeout 60 "$VENV_PY" -B "$SCENARIO" movewake "$PORT" "$CH" "$WAKELOG"; then
    ok "movewake: the sitter's move booked, the reason leaves silence open, the mover alone replied"
else
    sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -15
    sed 's/^/    wake:  /' "$WAKELOG"
    fail "movewake scenario failed"
fi

# The fuse ("299s") of the Nth booking as a bare number: in the recorded argv
# the when positional sits after the cap flags and --by chessweb.
fuse_of() { # <n>
    awk -F'\t' -v n="$1" '
        index($0, "a move landed") == 0 { next }
        ++i == n { sub(/s$/, "", $8); print $8; exit }' "$WAKELOG"
}

F1="$(fuse_of 1)"; F2="$(fuse_of 2)"
check_eq "the sitter's booking goes at the literal 1s — the first voice of a quiet spell" \
    "$F1" "1"
case "$F2" in ''|*[!0-9]*) fail "her reply's booking carries no numeric fuse: '$F2'" ;; esac
if [ "$F2" -gt 200 ] && [ "$F2" -le $((COOLDOWN + 1)) ]; then
    ok "her reply's booking shares the pacing clock: stretched into the cooldown window (${F2}s), parked pending — throttled, never absent"
else
    sed 's/^/    wake: /' "$WAKELOG"
    fail "her reply's booking (${F2}s) is not paced by the shared per-game clock"
fi

if awk -F'\t' -v p="chessweb: a move landed in game guest-001" '
    index($0, "a move landed") == 0 { next }
    $1=="wake-at" && $2=="--cap" && $3=="1" && $4=="--cap-prefix" \
        && $5==p && index($10, p)==1 { good++; next }
    { bad++ }
    END { exit (good==2 && !bad) ? 0 : 1 }' "$WAKELOG"; then
    ok "both triggers book under one per-game cap and one reason head"
else
    sed 's/^/    wake: /' "$WAKELOG"
    fail "the two triggers do not share the per-game cap and reason head"
fi

kill "$BRIDGE_PID" 2>/dev/null
wait "$BRIDGE_PID" 2>/dev/null
BRIDGE_PID=""   # wait reports the SIGTERM (143); the script's own exit is clean
