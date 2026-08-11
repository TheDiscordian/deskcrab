#!/bin/bash
# The refusal a chess wake reads first — specs/chessweb.md rule 21.
# Run: bash tests/test_chess_wake_prompt.sh
#
# Rule 20 put the refusal in the move command; this is the other belt: the
# agenda of every wake BOOKED BY chessweb opens with a flat all-caps directive
# saying the resident mover plays the moves, not the wake. On 2026-08-10 a
# wake pointed at its own game played the reply the mover was mid-thinking,
# and the mover's answer was discarded as stale — the wake's prompt showed it
# the board and said nothing about its hands.
#
# Scope is the point, and both directions are asserted here: the directive is
# the LITERAL FIRST LINE of a chessweb-booked wake's agenda, and it appears
# nowhere in any other wake's — an order shouted over every wake is one every
# wake learns to read past. Asserted on what the CLI was actually HANDED
# (the stub captures the positional prompt), never on a grep of `crab`.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/wakes"
printf '# Wants\n\n- one want, so the wake path is enabled at all\n' > "$D/wants.md"

cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WANTS_FILE="$D/wants.md"
EOF

# The agenda is the CLI's last argument — the positional prompt — so the stub
# writes that argument, whole and alone (the pattern test_wake_voice.sh set).
sandbox_stub claude <<'STUB'
#!/bin/bash
printf '%s' "${@: -1}" > "$SANDBOX_AGENDA_FILE"
case "$*" in
    *--output-format*)
        cat > /dev/null
        printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"stub reply."}]}}'
        printf '%s\n' '{"type":"result","result":"stub reply."}'
        ;;
    *) cat > /dev/null; printf 'stub reply.\n' ;;
esac
exit 0
STUB
export SANDBOX_AGENDA_FILE="$SANDBOX/witness/agenda.txt"

agenda() {  # <kind> <reason> <booked-by>  -> the composed agenda on stdout
    : > "$SANDBOX_AGENDA_FILE"
    WAKES_DIR="$D/wakes" "$SANDBOX_REPO/crab" wake "$1" "$2" "" "${3:-}" \
        >/dev/null 2>&1 || true
    cat "$SANDBOX_AGENDA_FILE" 2>/dev/null
}

DIRECTIVE="DO NOT RUN THE betty-chess move COMMAND UNDER ANY CIRCUMSTANCES. LOOK AND THINK ONLY. THE RESIDENT CHESS MOVER PLAYS THE MOVES, NOT YOU."
CHESS_REASON="chessweb: you played a move in game browser-007 against browser; it is already on their board, and nothing waits on this wake. Board: betty-chess show browser-007"

echo "a chessweb-booked wake reads the refusal before anything else:"
A="$(agenda event "$CHESS_REASON" chessweb)"
[ -n "$A" ] || die "the wake never reached the CLI, so there is no agenda to judge"
check_eq "the directive is the literal first line, not merely present" \
    "$(printf '%s' "$A" | head -1)" "$DIRECTIVE"
check "the waking frame still follows it" \
    grep -qF -- "(Nobody is talking to you" <<<"$A"
check "and the game is still this wake's agenda — the reason survives" \
    grep -qF -- "browser-007" <<<"$A"

echo "no other wake is shouted at:"
B="$(agenda event "a file landed: report.pdf" notice-newfiles)"
[ -n "$B" ] || die "the non-chess event wake never reached the CLI"
if grep -qF -- "$DIRECTIVE" <<<"$B"; then
    fail "another booker's event wake carries the chess directive"
else
    ok "another booker's event wake does not carry the chess directive"
fi
check_eq "its first line is the waking frame, exactly as before" \
    "$(printf '%s' "$B" | head -1)" \
    "(Nobody is talking to you and the hours are your own. You woke up because something you asked to be told about happened on this machine."

C="$(agenda scheduled "" "")"
[ -n "$C" ] || die "the plain scheduled wake never reached the CLI"
if grep -qF -- "$DIRECTIVE" <<<"$C"; then
    fail "a plain scheduled wake carries the chess directive"
else
    ok "a plain scheduled wake does not carry the chess directive"
fi
