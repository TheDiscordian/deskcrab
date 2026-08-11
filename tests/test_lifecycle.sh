#!/bin/bash
# crab seal / crab revive — specs/lifecycle.md. Run: bash tests/test_lifecycle.sh
#
# Seal and revive drive systemd and kill processes, so this does not exercise
# the live effect; it pins the parts that are easy to get wrong by hand and
# that the spec names: the unit lists cover every shipped unit seal must stop,
# seal cancels the booking RECORDS (rule 4, the step a by-hand seal forgets),
# and revive never restores stale wakes (rule 9, the stampede).
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
LIFE="$REPO/lib/lifecycle"

UNITS="$(bash -c "source '$LIFE'; echo \$_LC_GATES \$_LC_SERVICES \$_LC_TIMERS \$_LC_PATHS")"

echo "the unit lists name every shipped unit seal must handle directly:"
# Every unit seal stops by name. Excluded on purpose: the transient per-wake
# units (globbed, rule 3), wake-restore (revive omits it, rule 9), and the
# oneshot .service siblings a timer/path starts rather than seal.
for u in deskcrab-serve.service deskcrab-wake.timer deskcrab-chessweb.service \
         deskcrab-canary-selfchange.timer deskcrab-sleep.timer deskcrab-tidy.timer \
         deskcrab-notice-selfchange.path deskcrab-notice-transcriptions.path; do
    case " $UNITS " in
        *" $u "*) ok "seal handles $u" ;;
        *) fail "seal handles $u" "not in the unit lists: $UNITS" ;;
    esac
done

echo
echo "seal cancels the booking records, not just the timers (rule 4):"
grep -q "wake-cancel --all" "$LIFE" \
    && ok "crab_seal calls wake-cancel --all" \
    || fail "crab_seal calls wake-cancel --all"

echo
echo "revive never restores stale wakes (rule 9):"
# Strip comment lines: crab_revive NAMES wake-restore in a comment explaining
# why it does not run it — the test is that it never invokes it.
REVIVE_BODY="$(awk '/^crab_revive\(\)/,/^}/' "$LIFE" | grep -vE '^[[:space:]]*#')"
printf '%s' "$REVIVE_BODY" | grep -q "wake-restore" \
    && fail "crab_revive must not run wake-restore" \
    || ok "crab_revive does not run wake-restore"

echo
echo "the two gates are the only enable/disable, both directions (rule 1, 8):"
grep -q 'disable --now $_LC_GATES' "$LIFE" \
    && ok "seal disables the gates" || fail "seal disables the gates"
grep -q 'enable --now $_LC_GATES' "$LIFE" \
    && ok "revive enables the gates" || fail "revive enables the gates"

echo
echo "the seal report succeeds only when live/timers/bookings all read zero:"
# Drive crab_seal_report with the three counts stubbed to controllable values.
report_rc() {  # <procs> <timers> <bookings>
    bash -c "
        source '$LIFE'
        pgrep() { seq 1 $1 2>/dev/null; }
        systemctl() { case \"\$*\" in *list-timers*) for i in \$(seq 1 $2 2>/dev/null); do echo deskcrab-wake-\$i.timer; done;; *is-enabled*) echo disabled; echo disabled;; esac; }
        find() { seq 1 $3 2>/dev/null; }
        crab_seal_report >/dev/null 2>&1
    "; echo $?
}
[ "$(report_rc 0 0 0)" = 0 ] && ok "all-zero reports sealed (success)" || fail "all-zero reports sealed"
[ "$(report_rc 1 0 0)" != 0 ] && ok "a live process fails the report" || fail "a live process fails the report"
[ "$(report_rc 0 1 0)" != 0 ] && ok "a loaded wake timer fails the report" || fail "a loaded wake timer fails the report"
[ "$(report_rc 0 0 1)" != 0 ] && ok "a booking record fails the report" || fail "a booking record fails the report"

echo
echo "crab dispatches seal/revive and their aliases and sources the module:"
grep -qE 'seal\|offline\)' "$REPO/crab" && ok "crab has a seal|offline arm" || fail "crab has a seal|offline arm"
grep -qE 'revive\|online\)' "$REPO/crab" && ok "crab has a revive|online arm" || fail "crab has a revive|online arm"
grep -qF 'source "$SCRIPT_DIR/lib/lifecycle"' "$REPO/crab" && ok "crab sources lib/lifecycle" || fail "crab sources lib/lifecycle"
