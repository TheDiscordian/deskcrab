#!/bin/bash
# The per-wake model pin (specs/wake-queue.md rule 13b, jobs.md rule 29b).
# Run: bash tests/test_wake_model_pin.sh
#
# The origin (2026-08-26): the job runner's completion review was specified as
# a Sol review at medium effort, and the booking carried only the effort — the
# review fired on whichever ordinary wake model happened to be configured,
# which is not a Sol review. The pin is the record's seventh field and the
# fired unit's seventh argument, and it must survive everything the record
# survives.
#
# The contract under test:
#   - `crab wake-at --model <name>` writes the seventh field; with no effort
#     the sixth field is EMPTY, never the model sliding into it;
#   - a name the record cannot carry (whitespace) is refused at booking time;
#   - the fired unit's argv carries the model as the seventh argument;
#   - restore re-arms with the pin intact;
#   - the blocked-lock deferral re-books with the pin intact;
#   - a fired wake whose seventh argument is `sol` at `medium` reaches the
#     codex engine as gpt-5.6-sol with model_reasoning_effort=medium — the
#     Sol review, end to end;
#   - a seventh argument failing the structural filter is ignored on fire,
#     never allowed to refuse the whole wake.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
WANTS_FILE="$SANDBOX/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf '# Wants\n\n- a want, so the wake path is enabled at all\n' > "$SANDBOX/wants.md"

record_of() {  # <grep for reason> -> the record path (the ledger also lives
               # in WAKES_DIR and carries every reason — only *.wake counts)
    grep -l -- "$1" "$WAKES_DIR"/*.wake 2>/dev/null | head -1
}
field() {  # <file> <n>
    awk -F'\t' -v n="$2" '{print $n; exit}' "$1"
}

# ---------------------------------------------------------------------------
echo "the booking writes the pin as the seventh field:"
OUT="$("$REPO/crab" wake-at --by pin-tester --effort medium --model sol 2h event "a pinned review sitting")"
contains "$OUT" "Wake scheduled" && ok "booked" || fail "booked" "$OUT"
REC="$(record_of "a pinned review sitting")"
check "the record exists" test -n "$REC"
check_eq "sixth field: the effort" "$(field "$REC" 6)" "medium"
check_eq "seventh field: the model" "$(field "$REC" 7)" "sol"

echo
echo "a model with no effort leaves the sixth field empty — position is meaning:"
"$REPO/crab" wake-at --by pin-tester --model opus 3h event "a pinned sitting with no effort" >/dev/null
REC2="$(record_of "a pinned sitting with no effort")"
check "the record exists" test -n "$REC2"
check_eq "the sixth field is EMPTY, not the model" "$(field "$REC2" 6)" ""
check_eq "the model sits seventh" "$(field "$REC2" 7)" "opus"

echo
echo "a name the record cannot carry is refused at booking time:"
OUT="$("$REPO/crab" wake-at --by pin-tester --model "two words" 4h event "a booking that must not land" 2>&1)" && RC=0 || RC=$?
check "the booking is refused" test "$RC" -ne 0
check "naming the shape it wants" contains "$OUT" "not a name the record can carry"
check_eq "and nothing was recorded" "$(record_of "a booking that must not land")" ""

echo
echo "the fired unit's argv carries the pin as the seventh argument:"
ARGV="$(grep -- "a pinned review sitting" "$SANDBOX_SYSTEMD_LOG" | tail -1)"
check "the booking reached the (stubbed) manager" test -n "$ARGV"
contains "$ARGV" "wake event a pinned review sitting" && ok "the wake argv is whole" || fail "the wake argv is whole" "$ARGV"
case "$ARGV" in
    *"pin-tester medium sol") ok "…and ends by pin-tester medium sol" ;;
    *) fail "…and ends by pin-tester medium sol" "$ARGV" ;;
esac
ARGV2="$(grep -- "a pinned sitting with no effort" "$SANDBOX_SYSTEMD_LOG" | tail -1)"
case "$ARGV2" in
    *"pin-tester  opus") ok "with no effort the sixth slot rides empty, the model still seventh" ;;
    *) fail "with no effort the sixth slot rides empty, the model still seventh" "$ARGV2" ;;
esac

echo
echo "restore re-arms with the pin intact:"
: > "$SANDBOX_SYSTEMD_LOG"
"$REPO/crab" wake-restore >/dev/null 2>&1
REC="$(record_of "a pinned review sitting")"
check "the record survived restore" test -n "$REC"
check_eq "still pinned" "$(field "$REC" 7)" "sol"
ARGV="$(grep -- "a pinned review sitting" "$SANDBOX_SYSTEMD_LOG" | tail -1)"
if [ -n "$ARGV" ]; then
    case "$ARGV" in
        *"pin-tester medium sol") ok "the re-armed argv still carries medium sol" ;;
        *) fail "the re-armed argv still carries medium sol" "$ARGV" ;;
    esac
else
    ok "nothing needed re-arming (record already armed) — the record's pin above is the proof"
fi

echo
echo "the blocked-lock deferral re-books with the pin intact:"
rm -f "$WAKES_DIR"/*.wake
LOCKFILE="${DESKCRAB_STATE_PREFIX}-wake.lock"
mkdir -p "$(dirname "$LOCKFILE")"
(
    exec 9>"$LOCKFILE"
    flock -n 9 || exit 1
    "$REPO/crab" wake scheduled "the deferred pinned agenda" "" pin-tester medium sol >/dev/null 2>&1
)
REC3="$(record_of "the deferred pinned agenda")"
check "the deferred wake re-booked itself" test -n "$REC3"
if [ -n "$REC3" ]; then
    check_eq "keeping the effort" "$(field "$REC3" 6)" "medium"
    check_eq "and the pin" "$(field "$REC3" 7)" "sol"
fi

echo
echo "a fired wake pinned to sol at medium IS the Sol review, end to end:"
: > "$SANDBOX_CODEX_LOG"
: > "$SANDBOX_CLAUDE_LOG"
"$REPO/crab" wake event "review the finished job against its record" "" job-runner medium sol >/dev/null 2>&1 || true
check "the codex engine took the wake" \
    grep -q -- "-m gpt-5.6-sol" "$SANDBOX_CODEX_LOG"
check "at medium reasoning effort" \
    grep -q -- "model_reasoning_effort=medium" "$SANDBOX_CODEX_LOG"
check_eq "and the claude walk was never booted for it" \
    "$(sandbox_count_in '--output-format' "$SANDBOX_CLAUDE_LOG")" "0"

echo
echo "a seventh argument failing the filter is ignored, never fatal:"
: > "$SANDBOX_CODEX_LOG"
: > "$SANDBOX_CLAUDE_LOG"
"$REPO/crab" wake event "an agenda whose pin went bad" "" pin-tester medium 'bad/na@me' >/dev/null 2>&1 || true
check_eq "the codex engine was not asked" "$(sandbox_count_in . "$SANDBOX_CODEX_LOG")" "0"
check "the wake still ran, on the configured model" \
    grep -q -- "--output-format" "$SANDBOX_CLAUDE_LOG"

echo
echo "summary: $PASS passed, $FAIL failed"
