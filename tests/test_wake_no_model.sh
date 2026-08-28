#!/bin/bash
# A wake either reaches a model or reports the failure and keeps its agenda —
# specs/wake-queue.md rules 23, 24 and 24a beside specs/account-fallback.md
# rule 4a. Run: bash tests/test_wake_no_model.sh
#
# The 2026-08-11 shape this pins: a wake whose CLI died before the model wrote
# anything (for example, a loader crash) left a stream with
# no error event, so the outage branch never fired — the journal kept a bare
# "claude exit 1" and the agenda was silently lost. And the pathological end of
# the same road, a walk that makes NO attempt at all, exits 0 with an empty
# stream that nothing downstream reads as failure.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"

# The spend gate first, as the harness owes: the CLI these wakes run is the
# stub, before anything is dispatched.
[ -x "$SANDBOX_BIN/claude" ] || die "the stub CLI is missing — nothing below may run"

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
WANTS_FILE="$SANDBOX/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf '# Wants\n\n- a want, so the wake path is enabled at all\n' > "$SANDBOX/wants.md"

# Each wake runs as its own process, the way `crab wake` runs it, so DEBUGLOG
# is its own per-pid stream. run_claude_wake is called directly so no timer is
# booked for the SESSION itself; the re-book under test goes through `crab
# wake-at`, which the scratch WAKES_DIR and the stubbed systemd-run keep as a
# record and never a unit.
wake() { # <reason>
    bash -c '
        . "$1/lib/common.sh"
        PIDFILE="$2"
        WAKE_REASON="$3"
        run_claude_wake "(Autonomous wake — test)"
    ' _ "$REPO" "$SANDBOX/rec.pid" "$1" >/dev/null 2>&1
}

# shellcheck source=/dev/null
source "$REPO/lib/common.sh"   # for SESSIONS_LOG and WAKES_DIR

echo "with no account variable set anywhere, a wake still reaches the CLI — once:"
# The sandbox sets no CLAUDE_FALLBACK_CONFIG_DIR and no default record, which
# is exactly the configuration the 2026-08-11 note suspected of yielding zero
# attempts. The flags line appears once per CLI invocation in the stub's argv
# log, so the count IS the attempt count.
: > "$SANDBOX_CLAUDE_LOG"
wake "an ordinary agenda about the greenhouse shelf"
check_eq "the stub CLI was invoked exactly once" \
    "$(sandbox_count_in '--output-format' "$SANDBOX_CLAUDE_LOG")" "1"
LINE="$(tail -n1 "$SESSIONS_LOG")"
if contains "$LINE" "produced no output"; then
    fail "an answered wake must not be journalled as a failure" "$LINE"
else
    ok "and the wake was not journalled as a failure"
fi

echo
echo "a CLI that dies writing nothing is a reported failure with a surviving agenda:"
AGENDA="the agenda that must survive the crash"
sandbox_stub claude <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SANDBOX_CLAUDE_LOG:-/dev/null}"
cat > /dev/null
exit 7
EOF
: > "$SANDBOX_CLAUDE_LOG"
wake "$AGENDA"
LINE="$(grep "produced no output" "$SESSIONS_LOG" | tail -n1)"
check "the journal names the death" contains "$LINE" "produced no output"
check "with the exit code" contains "$LINE" "exit 7"
check "and the agenda is re-booked, not lost" \
    grep -rq "$AGENDA" "$WAKES_DIR"

echo
echo "the launcher's last words reach the journal line (rule 24a):"
AGENDA2="the agenda behind the launcher death"
sandbox_stub claude <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SANDBOX_CLAUDE_LOG:-/dev/null}"
cat > /dev/null
echo "launcher: could not load the model runtime"
exit 1
EOF
wake "$AGENDA2"
LINE="$(grep "produced no output" "$SESSIONS_LOG" | tail -n1)"
check "the journal carries the launcher's own complaint" \
    contains "$LINE" "launcher: could not load"
check "this agenda survives too" grep -rq "$AGENDA2" "$WAKES_DIR"

echo
echo "a clean silent wake is silence, never a failure retry (rule 24 stands):"
AGENDA3="the agenda of a wake with nothing to say"
sandbox_stub claude <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SANDBOX_CLAUDE_LOG:-/dev/null}"
cat > /dev/null
printf '%s\n' '{"type":"result"}'
exit 0
EOF
wake "$AGENDA3"
LINE="$(tail -n1 "$SESSIONS_LOG")"
check "journalled as silence" contains "$LINE" "silent"
if grep -rq "$AGENDA3" "$WAKES_DIR" 2>/dev/null; then
    fail "a clean silent wake must not book itself a failure retry"
else
    ok "and no retry was booked for it"
fi
