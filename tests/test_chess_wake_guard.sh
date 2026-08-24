#!/bin/bash
# betty-chess: an autonomous wake may look at the board but never play on it
# (specs/chessweb.md rule 20). On 2026-08-10 a wake mirrored a move into a
# live game and raced the resident mover: the mover's own answer for that ply
# came back, was discarded as stale, and a knight was lost for nothing — two
# minutes after a written conduct rule said the mover plays, not the wake.
# Prose did not hold, so the refusal lives in cmd_move, keyed on the session
# registry every claude invocation writes ($DESKCRAB_STATE_PREFIX-sessions/
# <pid>, first field the kind) and found by walking the /proc parent chain.
# Run: bash tests/test_chess_wake_guard.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
CHESS="$REPO/lib/betty-chess"
# The sandbox moves HOME, and a venv is 100MB of install — so the live one is
# borrowed read-only rather than rebuilt per run. Skip if it was never made.
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "SKIP: no chess venv at $VENV — run betty-chess once to bootstrap it"
  exit 0
fi

export DESKCRAB_CHESS_DIR="$SANDBOX/chess-games"
export DESKCRAB_CHESS_VENV="$VENV"

chess() { "$CHESS" "$@" 2>&1; }

# Register THIS shell as a live claude session of the given kind, the same
# shape session_register writes in lib/common.sh. The CLI runs levels below
# us (a command substitution, the wrapper, the venv python), which is the
# point: the guard has to find the registration by walking upward.
SESSIONS="$DESKCRAB_STATE_PREFIX-sessions"
register() {
  mkdir -p "$SESSIONS"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$$" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" 0 > "$SESSIONS/$$"
}

chess new opponent >/dev/null   # she is white: ply 0 is her move

# --- the refusal ----------------------------------------------------------
register "autonomous wake"

out="$(chess move e4)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "the resident mover owns the move" \
  && ok "a wake session is refused the move, naming the mover as owner" \
  || fail "wake move: rc=$rc $out"

echo "$out" | grep -q "DESKCRAB_CHESS_ALLOW_WAKE_MOVE" \
  && ok "and the refusal names the escape hatch" \
  || fail "no override named in: $out"

chess status | grep -q "ply 0" \
  && ok "the refused move wrote nothing to the game" \
  || fail "the store moved despite the refusal: $(chess status)"

# Looking is how a wake briefs itself: everything but move keeps working.
out="$(chess show)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "white to move" \
  && ok "show still works from a wake" \
  || fail "wake show: rc=$rc $out"

out="$(chess status)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "^fen:" \
  && ok "status still works from a wake" \
  || fail "wake status: rc=$rc $out"

# --- the escape hatch -----------------------------------------------------
out="$(DESKCRAB_CHESS_ALLOW_WAKE_MOVE=1 chess move e4)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "played e4" \
  && ok "DESKCRAB_CHESS_ALLOW_WAKE_MOVE=1 lets a wake play after all" \
  || fail "override move: rc=$rc $out"

# --- other session kinds, and no session at all ---------------------------
register "phone turn"
out="$(chess move e5)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "played e5" \
  && ok "a phone turn plays unguarded" \
  || fail "phone-turn move: rc=$rc $out"

rm -f "$SESSIONS/$$"
out="$(chess move Nf3)"; rc=$?
[ "$rc" -eq 0 ] && echo "$out" | grep -q "played Nf3" \
  && ok "no registration in the ancestry means no refusal" \
  || fail "unregistered move: rc=$rc $out"
