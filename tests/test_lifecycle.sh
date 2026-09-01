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
# Derived from systemd/ rather than typed out, because a hand-typed list is
# exactly how the portrait services came to be shipped for months without seal
# ever stopping them. Excluded on purpose: all transient units (swept by
# prefix, rule 3), wake-restore (revive omits it, rule 9), and the oneshot
# .service siblings a timer or path starts rather than seal.
for f in "$REPO"/systemd/*.service "$REPO"/systemd/*.timer "$REPO"/systemd/*.path; do
    [ -e "$f" ] || continue
    u="$(basename "$f")"
    [ "$u" = deskcrab-wake-restore.service ] && continue
    case "$u" in
        *.service)
            stem="${u%.service}"
            { [ -e "$REPO/systemd/$stem.timer" ] || [ -e "$REPO/systemd/$stem.path" ]; } && continue
            ;;
    esac
    case " $UNITS " in
        *" $u "*) ok "seal handles $u" ;;
        *) fail "seal handles $u" "not in the unit lists: $UNITS" ;;
    esac
done

echo
echo "the transient sweep goes by prefix, not by the wake suffix (rule 3):"
SEAL_BODY="$(awk '/^crab_seal\(\)/,/^}/' "$LIFE" | grep -vE '^[[:space:]]*#')"
printf '%s' "$SEAL_BODY" | grep -q "deskcrab-\*.timer" \
    && ok "seal stops every transient deskcrab timer" \
    || fail "seal stops every transient deskcrab timer" "no deskcrab-*.timer glob"
printf '%s' "$SEAL_BODY" | grep -q "deskcrab-wake-\*" \
    && fail "the wake-only glob is gone" "seal still sweeps by the wake suffix alone" \
    || ok "the wake-only glob is gone"

echo
echo "seal takes the playing arm down through its own door (rule 5):"
printf '%s' "$SEAL_BODY" | grep -q '_lc_play_bin' \
    && ok "seal calls the playing arm's door" \
    || fail "seal calls the playing arm's door"
printf '%s' "$SEAL_BODY" | grep -qE 'pkill.*(orsc|run-player)' \
    && fail "seal never kills the player" "the unit carries Restart=always: a kill is a restart" \
    || ok "seal never kills the player"
printf '%s' "$SEAL_BODY" | grep -q 'DESKCRAB_TURN_ORIGIN=phone' \
    && fail "seal does not claim a phone origin" "the phone origin is refused by that door" \
    || ok "seal does not claim a phone origin"

echo
echo "seal records the portrait window so revive puts back only what it closed (rule 8, 11):"
printf '%s' "$SEAL_BODY" | grep -q '_lc_facewin_mark' \
    && ok "seal records the portrait window" || fail "seal records the portrait window"
printf '%s' "$SEAL_BODY" | grep -q 'pkill -f "lib/face-window"' \
    && ok "seal closes the portrait window" || fail "seal closes the portrait window"

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
echo "revive never starts the playing arm, and reopens only the window seal closed (rule 11, 13):"
printf '%s' "$REVIVE_BODY" | grep -qE '_lc_play_bin|_LC_PLAY_UNITS' \
    && fail "crab_revive must not start the playing arm" "a sitting begins deliberately" \
    || ok "crab_revive does not start the playing arm"
printf '%s' "$REVIVE_BODY" | grep -q '_lc_facewin_mark' \
    && ok "crab_revive reopens the window behind the marker" \
    || fail "crab_revive reopens the window behind the marker"

echo
echo "the two gates are the only enable/disable, both directions (rule 1, 8):"
grep -q 'disable --now $_LC_GATES' "$LIFE" \
    && ok "seal disables the gates" || fail "seal disables the gates"
grep -q 'enable --now $_LC_GATES' "$LIFE" \
    && ok "revive enables the gates" || fail "revive enables the gates"

echo
echo "the seal report succeeds only when live/timers/bookings/playing arm all read zero:"
# Drive crab_seal_report with the four counts stubbed to controllable values.
report_rc() {  # <procs> <timers> <bookings> [play]
    bash -c "
        source '$LIFE'
        pgrep() { seq 1 $1 2>/dev/null; }
        systemctl() { case \"\$*\" in *list-timers*) for i in \$(seq 1 $2 2>/dev/null); do echo deskcrab-wake-\$i.timer; done;; *is-active*) for i in \$(seq 1 ${4:-0} 2>/dev/null); do echo active; done;; *is-enabled*) echo disabled; echo disabled;; esac; }
        find() { seq 1 $3 2>/dev/null; }
        crab_seal_report >/dev/null 2>&1
    "; echo $?
}
[ "$(report_rc 0 0 0)" = 0 ] && ok "all-zero reports sealed (success)" || fail "all-zero reports sealed"
[ "$(report_rc 1 0 0)" != 0 ] && ok "a live process fails the report" || fail "a live process fails the report"
[ "$(report_rc 0 1 0)" != 0 ] && ok "a loaded wake timer fails the report" || fail "a loaded wake timer fails the report"
[ "$(report_rc 0 0 1)" != 0 ] && ok "a booking record fails the report" || fail "a booking record fails the report"
# The one the old report was blind to: nothing of hers greps as live, and the
# player is still spending the game account.
[ "$(report_rc 0 0 0 1)" != 0 ] && ok "a live playing arm fails the report" || fail "a live playing arm fails the report"

echo
echo "crab dispatches seal/revive and their aliases and sources the module:"
grep -qE 'seal\|offline\)' "$REPO/crab" && ok "crab has a seal|offline arm" || fail "crab has a seal|offline arm"
grep -qE 'revive\|online\)' "$REPO/crab" && ok "crab has a revive|online arm" || fail "crab has a revive|online arm"
grep -qF 'source "$SCRIPT_DIR/lib/lifecycle"' "$REPO/crab" && ok "crab sources lib/lifecycle" || fail "crab sources lib/lifecycle"
