#!/bin/bash
# The post-move wake's per-game cap (specs/chessweb.md rule 7, wake-queue.md
# rule 44). Coalescing folds only into a booking still PENDING, and the
# post-move wake fires one second after it is booked — so a game played at
# browser speed booked one wake per move, and on 2026-08-10 the ledger held
# 314 chessweb bookings out of 774 lines. The fix: the booking carries the
# queue's scoped cap, `--cap 1 --cap-prefix <per-game reason head>`, inserted
# immediately after the wake command's own `wake-at` element. Proven here:
# the flags are present and correctly placed on every post-move booking, the
# prefix is per-game distinct, and a wake command WITHOUT `wake-at` — the
# other tests' stub — is handed the reason alone, untouched.
# Run: bash tests/test_chessweb_wake_cap.sh
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

# The wake stub records its FULL argv — one booking per line, tab-separated —
# because the assertions here are about flag placement, not just the reason.
WAKE_STUB="$SANDBOX/wake-argv-stub"
cat > "$WAKE_STUB" <<'SH'
#!/bin/bash
{ printf '%s\t' "$@"; printf '\n'; } >> "$CHESSWEB_WAKE_LOG"
SH
chmod +x "$WAKE_STUB"

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
start_bridge() { # <chess dir> <wake log> <wake cmd> [serve args...]
    local dir="$1" wakelog="$2" wakecmd="$3"
    shift 3
    : > "$wakelog"
    : > "$SANDBOX/serve.log"
    # The voice cooldown is OFF here on purpose: this file's assertions are
    # about the cap flags' placement on every booking, and the cooldown
    # (chessweb.md rule 7, its own test file) would stretch the second and
    # third bookings' fuses away from the literal 1s these awks pin.
    DESKCRAB_CHESS_DIR="$dir" CHESSWEB_WAKE_LOG="$wakelog" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$wakecmd" \
        DESKCRAB_CHESSWEB_VOICE_COOLDOWN=0 \
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
        n="$(grep -c 'you played a move' "$log" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge "$want" ] && return 0
        sleep 0.1
    done
    return 1
}

# The recorded argv mirrors the live shape, `crab wake-at --by chessweb 1s
# event <reason>`, so correct placement means: after `wake-at`, before the
# `--by` flag and the when/kind positionals — where wake_book parses flags.
CAPPED_CMD="$WAKE_STUB wake-at --by chessweb 1s event"

echo "three fast exchanges in one game — every post-move booking is capped:"
CH="$SANDBOX/chess-guest"
WAKELOG="$SANDBOX/wake-guest.log"
if start_bridge "$CH" "$WAKELOG" "$CAPPED_CMD" --opponent guest; then
    scn wakecap "$PORT" "$CH" guest-001 3
    check "three post-move wakes were booked" wait_wakes "$WAKELOG" 3
    if awk -F'\t' -v p="chessweb: you played a move in game guest-001" '
        index($0, "you played a move") == 0 { next }
        $1=="wake-at" && $2=="--cap" && $3=="1" && $4=="--cap-prefix" \
            && $5==p && $6=="--by" && $7=="chessweb" && $8=="1s" \
            && $9=="event" && index($10, p)==1 { good++; next }
        { bad++ }
        END { exit (good==3 && !bad) ? 0 : 1 }' "$WAKELOG"; then
        ok "--cap 1 --cap-prefix <per-game head> sit right after wake-at, ahead of the positionals, on all three"
    else
        sed 's/^/    wake: /' "$WAKELOG"
        fail "the cap flags are missing or misplaced on a post-move booking"
    fi
fi
stop_bridge

echo "a second game caps under its own prefix, not the first game's:"
CH2="$SANDBOX/chess-rival"
WAKELOG2="$SANDBOX/wake-rival.log"
if start_bridge "$CH2" "$WAKELOG2" "$CAPPED_CMD" --opponent rival; then
    scn wakecap "$PORT" "$CH2" rival-001 1
    check "the rival game's post-move wake was booked" wait_wakes "$WAKELOG2" 1
    if awk -F'\t' -v p="chessweb: you played a move in game rival-001" '
        index($0, "you played a move") == 0 { next }
        $2=="--cap" && $4=="--cap-prefix" && $5==p \
            && index($10, p)==1 { good++; next }
        { bad++ }
        END { exit (good==1 && !bad) ? 0 : 1 }' "$WAKELOG2"; then
        ok "the cap prefix names rival-001 — the per-game head of its own reason"
    else
        sed 's/^/    wake: /' "$WAKELOG2"
        fail "the rival game's cap prefix is wrong"
    fi
    GP="$(awk -F'\t' '$2=="--cap" { print $5; exit }' "$WAKELOG")"
    RP="$(awk -F'\t' '$2=="--cap" { print $5; exit }' "$WAKELOG2")"
    if [ -n "$GP" ] && [ -n "$RP" ] && [ "$GP" != "$RP" ]; then
        ok "the two games' cap prefixes are distinct: one game's cap never drains another's"
    else
        fail "the cap prefixes are not per-game distinct" "guest='$GP' rival='$RP'"
    fi
fi
stop_bridge

echo "a wake command WITHOUT wake-at is passed the reason alone, untouched:"
CH3="$SANDBOX/chess-plain"
WAKELOG3="$SANDBOX/wake-plain.log"
if start_bridge "$CH3" "$WAKELOG3" "$WAKE_STUB" --opponent guest; then
    scn wakecap "$PORT" "$CH3" guest-001 1
    check "the post-move wake was still booked" wait_wakes "$WAKELOG3" 1
    if awk -F'\t' '
        index($0, "you played a move") == 0 { next }
        index($1, "chessweb: you played a move in game guest-001 against guest;") == 1 \
            && NF==2 && $0 !~ /--cap/ { good++; next }
        { bad++ }
        END { exit (good==1 && !bad) ? 0 : 1 }' "$WAKELOG3"; then
        ok "no flags were inserted: the reason arrived as the one argument"
    else
        sed 's/^/    wake: /' "$WAKELOG3"
        fail "an overridden wake command without wake-at was modified"
    fi
fi
stop_bridge
