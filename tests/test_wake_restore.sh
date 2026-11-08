#!/bin/bash
# The resurrection loop, which is the headline bug of 2026-08-07 seen from the
# other end. Run: bash tests/test_wake_restore.sh
#
# What happened: a backlog of wakes was called off with `systemctl stop`, which
# stops a timer and leaves the booking record exactly where it was. An hour
# later `ensure_next_wake` ran `wake_restore` — into /dev/null — and twenty-two
# cancelled reasons came back verbatim, event wakes never collapsing because
# the overdue merge only ever looked at kind=scheduled with an empty reason.
# Nothing anywhere said a word about it.
#
# So three things are asserted here and they are the same fact three times over:
#
#   1. a cancelled wake stays cancelled — the record is gone, and restore does
#      not bring it back;
#   2. an overdue queue COLLAPSES, event wakes included — two identical
#      promises are one promise however they were kinded;
#   3. every restoration, every overdue re-arming and every collapse lands in
#      the durable ledger with the actor that caused it, because a bulk restore
#      means a cancellation was undone or the machine rebooted and that is a
#      fact she has to be able to read.
#
# specs/wake-queue.md rules 30 to 34; specs/self-awareness.md rule 14.
#
# WAKES_DIR is deliberately NOT the sandbox's own data directory: the fourth
# gate compares it against ${XDG_DATA_HOME}/deskcrab/wakes, and a scratch
# directory plus DESKCRAB_ALLOW_SCRATCH_BOOKING (which the harness sets) is the
# combination that runs the booking path in full against the recording stub. So
# the argv every case asserts on is the argv systemd would have been handed.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W"

run() { # <shell body> — the queue module, against the scratch queue
    WAKES_DIR="$W" WANTS_FILE="$T/wants.md" sandbox_bash "$*" 2>&1
}
: > "$T/wants.md"

# One booking record, written by hand in the five-field shape the module writes.
record() { # <unit> <fire-epoch> <kind> <reason> <booked-by>
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$(date +%s)" "$5" > "$W/$1.wake"
}
records() { ls "$W"/*.wake 2>/dev/null | wc -l; }
# Ledger line: epoch, action, unit, kind, reason, actor.
led_count() { awk -F'\t' -v a="$1" '$2 == a { n++ } END { print n + 0 }' "$W/ledger.log" 2>/dev/null || echo 0; }
led_actor() { awk -F'\t' -v a="$1" -v u="$2" '$2 == a && $3 == u { print $6; exit }' "$W/ledger.log" 2>/dev/null; }
# What the schedule gate saw, per unit. Counted, never grep -q: "it booked
# something" and "it booked exactly this one thing" are different claims. The
# counting itself is the harness's (sandbox_count_in) — this file wrote its own
# because the harness's own count was the two-line one.
armed() { sandbox_count_in "$1" "$SANDBOX_SYSTEMD_LOG"; }
attempts() { sandbox_systemd_count; }
clean() { rm -f "$W"/*.wake "$W/ledger.log"; : > "$SANDBOX_SYSTEMD_LOG"; }

NOW="$(date +%s)"

echo "a cancelled queue stays cancelled:"
clean
record deskcrab-wake-c1 $(( NOW + 3600 )) scheduled ""                 herself
record deskcrab-wake-c2 $(( NOW + 7200 )) event     "job 42 finished"  job-runner
record deskcrab-wake-c3 $(( NOW + 9000 )) event     "a want you said"  promise-audit

out="$(run 'wake_cancel --all')"
check_eq "cancelling the queue clears every record" "$(records)" "0"
check_eq "and every cancellation is in the ledger" "$(led_count cancelled)" "3"
check_eq "with the hand that did it named" "$(led_actor cancelled deskcrab-wake-c2)" "by hand (--all)"
case "$out" in
    *"Cancelled 3 pending wakes"*) ok "the count is said out loud" ;;
    *) fail "wake_cancel --all reports how many it cancelled" "$out" ;;
esac

: > "$SANDBOX_SYSTEMD_LOG"
out="$(run 'wake_restore')"
check_eq "restore re-arms nothing — there is nothing left to re-arm" \
    "$(attempts)" "0"
check_eq "and writes no restoration to the ledger" "$(led_count restored)" "0"
case "$out" in
    *"needs no restoring"*) ok "restore says so rather than saying nothing" ;;
    *) fail "an empty queue restores to a stated nothing" "$out" ;;
esac

echo
echo "one cancellation is one cancellation — its siblings still come back:"
clean
record deskcrab-wake-k1 $(( NOW + 3600 )) scheduled ""                herself
record deskcrab-wake-k2 $(( NOW + 5400 )) event     "the one called off" promise-audit
run 'wake_cancel deskcrab-wake-k2' > /dev/null
: > "$SANDBOX_SYSTEMD_LOG"
out="$(run 'wake_restore')"
check_eq "the surviving booking is re-armed exactly once" "$(armed deskcrab-wake-k1)" "1"
check_eq "the cancelled one is not re-armed at all" "$(armed deskcrab-wake-k2)" "0"
check_eq "one restoration, one ledger line" "$(led_count restored)" "1"
check_eq "and it carries the record's own provenance" \
    "$(led_actor restored deskcrab-wake-k1)" "herself"
case "$out" in
    *"the one called off"*) fail "a cancelled reason must never be spoken by restore" "$out" ;;
    *) ok "the cancelled reason does not reappear in restore's output" ;;
esac

echo
echo "an overdue queue collapses — event wakes included:"
# Two identical overdue event promises (this is the shape the twenty-two took:
# same wording, same kind, booked minutes apart), one different event, and two
# identical overdue scheduled ones. Five records in, three out.
clean
record deskcrab-wake-o1 $(( NOW - 4000 )) event     "the builder never began" job-runner
record deskcrab-wake-o2 $(( NOW - 3000 )) event     "the builder never began" job-runner
record deskcrab-wake-o3 $(( NOW - 2000 )) event     "something else entirely" notice-selfchange
record deskcrab-wake-o4 $(( NOW - 1500 )) scheduled ""                        herself
record deskcrab-wake-o5 $(( NOW - 1000 )) scheduled ""                        herself
out="$(run 'wake_restore')"

check_eq "five overdue bookings become three" "$(records)" "3"
check_eq "three are re-armed, promptly" "$(led_count overdue)" "3"
check_eq "two identical promises are collapsed" "$(led_count collapsed)" "2"
check_eq "the duplicate EVENT wake is one of them" \
    "$(led_actor collapsed deskcrab-wake-o2)" "restore (duplicate overdue)"
check_eq "and so is the duplicate scheduled one" \
    "$(led_actor collapsed deskcrab-wake-o5)" "restore (duplicate overdue)"
check "the collapsed event's record is gone" [ ! -e "$W/deskcrab-wake-o2.wake" ]
check "the surviving copy of that promise is still a booking" \
    [ -s "$W/deskcrab-wake-o1.wake" ]
check_eq "a DIFFERENT event is not collapsed into it" \
    "$(led_actor overdue deskcrab-wake-o3)" "notice-selfchange"
check_eq "the collapsed one was never armed" "$(armed deskcrab-wake-o2)" "0"
case "$out" in
    *"collapsed: deskcrab-wake-o2"*) ok "the collapse is reported, not silent" ;;
    *) fail "a collapse must say which booking it was" "$out" ;;
esac

# Staggered, not a crowd: 90s, then five minutes apart. A long-off machine that
# wakes three sessions in the same second is one session and two deferrals.
fires="$(cut -f1 "$W"/*.wake | sort -n | tr '\n' ' ')"
set -- $fires
check "the three overdue wakes are spread, not stacked" \
    [ "$(( $3 - $1 ))" -ge 300 ]
check_eq "the soonest is a minute and a half out, not now" \
    "$(( $1 - NOW < 60 ? 1 : 0 ))" "0"

echo
echo "every restoration reaches the ledger, and the ledger reaches her:"
# specs/wake-queue.md rule 31: restore's output used to go to /dev/null from
# ensure_next_wake, which is precisely how a bulk resurrection became invisible.
clean
record deskcrab-wake-e1 $(( NOW + 2700 )) scheduled "" herself
out="$(run 'ensure_next_wake')"
case "$out" in
    *"restored: deskcrab-wake-e1"*) ok "ensure_next_wake does not swallow restore's output" ;;
    *) fail "restore's output must reach the journal, not /dev/null" "$out" ;;
esac
check_eq "the restoration is durable as well as spoken" "$(led_count restored)" "1"
# A floor is a floor: a scheduled booking is already pending, so nothing new.
check_eq "no floor wake is booked on top of a pending scheduled one" \
    "$(led_count booked)" "0"
check_eq "exactly one booking reached the schedule gate" \
    "$(armed '--on-')" "1"

echo
echo "restore is idempotent when the timers are already there:"
# The everyday case: nothing died, so restore has nothing to do. It must not
# double-book the queue it was asked to heal.
clean
record deskcrab-wake-i1 $(( NOW + 3600 )) scheduled "" herself
out="$(run '
    systemctl() { case "$*" in *is-active*) return 0 ;; esac; return 0; }
    wake_restore')"
check_eq "a booking whose timer is alive is left alone" \
    "$(attempts)" "0"
check_eq "and nothing is written to the ledger about it" "$(led_count restored)" "0"
case "$out" in
    *"needs no restoring"*) ok "restore says the queue was already whole" ;;
    *) fail "an already-armed queue restores to a stated nothing" "$out" ;;
esac

echo
echo "a wake that is FIRING right now is not an overdue booking:"
# specs/wake-queue.md rule 31's sub-bullet. A one-shot timer goes inactive the
# instant it fires, and the fired wake clears its own record a few lines into
# `crab wake` — so between those two moments a restore that only asks about the
# TIMER sees an overdue record with nothing armed, and re-arms the wake
# underneath itself. tidy has skipped an active service since it was written;
# restore did not.
clean
record deskcrab-wake-firing $(( NOW - 600 )) scheduled "the one going off right now" herself
out="$(run '
    systemctl() {
        case "$*" in
            *"is-active"*".service"*) return 0 ;;
            *"is-active"*) return 1 ;;
        esac
        return 0
    }
    wake_restore')"
check_eq "the running wake is not re-armed" "$(attempts)" "0"
check_eq "and its record is left exactly where it was" \
    "$(awk -F'\t' '{ print $1 }' "$W/deskcrab-wake-firing.wake")" "$(( NOW - 600 ))"
check_eq "nothing about it reaches the ledger" "$(led_count overdue)" "0"

echo
echo "a re-arm that fails puts the record back and says so:"
# Rule 5 for the overdue branch: the new fire time was written to the durable
# record BEFORE the timer was asked for, and a refusal left it there. The
# booking then claimed a moment that will never come — still overdue, but dated
# from a restore that did not happen — and the pass ended on the sentence that
# says every booking has its timer.
clean
record deskcrab-wake-norearm $(( NOW - 900 )) event "a job that finished" job-runner
sandbox_systemd_rc 1
out="$(run 'wake_restore')"
sandbox_systemd_rc 0
check_eq "the record keeps the moment it had" \
    "$(awk -F'\t' '{ print $1 }' "$W/deskcrab-wake-norearm.wake")" "$(( NOW - 900 ))"
check_eq "and its agenda with it" \
    "$(awk -F'\t' '{ print $3 }' "$W/deskcrab-wake-norearm.wake")" "a job that finished"
check_eq "the failure is on the ledger" "$(led_count restore-failed)" "1"
case "$out" in
    *"needs no restoring"*) fail "a pass that armed nothing must not claim the queue is whole" "$out" ;;
    *"could not be re-armed"*) ok "and the pass says what it could not do" ;;
    *) fail "a failed re-arm must be reported" "$out" ;;
esac

echo
echo "cancel and restore write the queue under the booking lock:"
# specs/wake-queue.md rule 6's sub-bullet, and the race it is for: a
# `wake-cancel --all` walking the records, overtaken by a finishing wake's
# restore, which re-arms a record the cancel has not reached yet and then loses
# that record to the cancel — an armed timer with no booking record, which tidy
# will not purge because it has never fired, going off with a wake the user
# called off. Held here by another process, which is the only way to prove the
# operation waits for it rather than proceeding without it.
clean
record deskcrab-wake-locked $(( NOW + 3600 )) scheduled "" herself
LOCKFILE="${DESKCRAB_STATE_PREFIX}-wake-book.lock"
flock -x "$LOCKFILE" -c 'sleep 4' &
HOLDER=$!
sleep 0.4
out="$(WAKE_BOOK_LOCK_WAIT=1 run 'wake_cancel --all'; WAKE_BOOK_LOCK_WAIT=1 run 'wake_restore')"
wait "$HOLDER" 2>/dev/null
check_eq "the record survives an operation that could not take the lock" \
    "$(records)" "1"
case "$out" in
    *"booking lock is still held"*) ok "and both say the lock was not theirs to take" ;;
    *) fail "an operation that cannot lock must say so and change nothing" "$out" ;;
esac

# ---------------------------------------------------------------------------
# Rules 30a and 30b: a LIVE timer is checked against its record, never trusted.
#
# Until 2026-10-02 every timer was armed as a delay, the user manager started
# that delay again on each daemon-reload, and restore skipped any unit whose
# timer was merely active — so seven sittings stood armed for moments their
# records had never named, five of those records already in the past, and the
# one pass that could have healed them called the queue whole.
#
# The manager's answers are scripted here: which timers are alive, and where
# each one stands (an epoch for a dated timer, nothing for a delay timer —
# exactly what NextElapseUSecRealtime says of each). The same cases run against
# a real manager in tests/test_wake_reload_drift.sh.
MGR="$T/mgr.timers"
STOPPED="$T/mgr.stopped"
cat > "$T/mgr.sh" <<MGRSH
systemctl() {
    case "\$*" in
        *is-active*.service) return 1 ;;
        *is-active*.timer)
            local u; for u in "\$@"; do :; done
            awk -F'\t' -v u="\${u%.timer}" '\$1 == u { hit = 1 } END { exit !hit }' "$MGR" 2>/dev/null
            return \$? ;;
        *" show "*)
            awk -F'\t' '{ printf "Id=%s.timer\nNextElapseUSecRealtime=%s\n\n", \$1, (\$2 == "" ? "" : "@" \$2) }' "$MGR" 2>/dev/null
            return 0 ;;
        *" stop "*)
            local u; for u in "\$@"; do :; done
            printf '%s\n' "\$u" >> "$STOPPED"
            return 0 ;;
    esac
    return 0
}
MGRSH
alive() { # <unit> [<epoch the dated timer stands on> — empty for a delay timer]
    printf '%s\t%s\n' "$1" "${2:-}" >> "$MGR"
}
restore_against_manager() { run ". '$T/mgr.sh'; wake_restore"; }
mclean() { clean; rm -f "$MGR" "$STOPPED"; : > "$MGR"; }
stopped() { sandbox_count_in "$1" "$STOPPED"; }
fire_of() { awk -F'\t' '{ print $1; exit }' "$W/$1.wake" 2>/dev/null; }
utc() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S UTC'; }
clock() { date -d "@$1" '+%H:%M:%S'; }

echo
echo "a live timer that stands where its record says is left alone:"
mclean
record deskcrab-wake-agree $(( NOW + 3600 )) scheduled "an agreed moment" herself
alive deskcrab-wake-agree $(( NOW + 3600 ))
out="$(restore_against_manager)"
check_eq "nothing is stopped" "$(stopped .)" "0"
check_eq "and nothing is armed" "$(attempts)" "0"
check_eq "nothing about it reaches the ledger" "$(led_count reconciled)" "0"
case "$out" in
    *"needs no restoring"*) ok "restore says the queue was already whole" ;;
    *) fail "an agreeing queue restores to a stated nothing" "$out" ;;
esac

echo
echo "a delay timer left by the old arming is re-armed at the record's epoch:"
mclean
record deskcrab-wake-drift $(( NOW + 7200 )) scheduled "the sitting that drifted" herself
alive deskcrab-wake-drift ""
before="$(cksum < "$W/deskcrab-wake-drift.wake")"
out="$(restore_against_manager)"
check_eq "the drifted timer is stopped, once" "$(stopped 'deskcrab-wake-drift.timer')" "1"
check_eq "one timer is armed in its place" "$(attempts)" "1"
check_eq "at the record's own instant" \
    "$(armed "unit=deskcrab-wake-drift .*--on-calendar=$(utc $(( NOW + 7200 ))) ")" "1"
check_eq "and not as another delay" "$(armed 'on-active')" "0"
check_eq "the record is not rewritten to suit a timer" \
    "$(cksum < "$W/deskcrab-wake-drift.wake")" "$before"
check_eq "the ledger calls it what it was" "$(led_count reconciled)" "1"
check_eq "and says where the timer stood" \
    "$(led_actor reconciled deskcrab-wake-drift)" "restore (timer stood on a delay)"
check_eq "it is not counted as a plain restoration" "$(led_count restored)" "0"
case "$out" in
    *"reconciled: deskcrab-wake-drift"*) ok "and restore says it out loud" ;;
    *) fail "a reconciled timer must be reported" "$out" ;;
esac
case "$out" in
    *"needs no restoring"*) fail "a pass that re-armed a drifted timer must not call the queue whole" "$out" ;;
    *) ok "the pass does not end on the sentence that says nothing was needed" ;;
esac

echo
echo "a dated timer standing on another instant is moved back to its record:"
mclean
record deskcrab-wake-wrong $(( NOW + 7200 )) event "a job that will finish" job-runner
alive deskcrab-wake-wrong $(( NOW + 90000 ))
out="$(restore_against_manager)"
check_eq "it is stopped" "$(stopped 'deskcrab-wake-wrong.timer')" "1"
check_eq "and re-armed at the record's instant" \
    "$(armed "unit=deskcrab-wake-wrong .*--on-calendar=$(utc $(( NOW + 7200 ))) ")" "1"
check_eq "the record keeps its moment" "$(fire_of deskcrab-wake-wrong)" "$(( NOW + 7200 ))"
case "$(led_actor reconciled deskcrab-wake-wrong)" in
    "restore (timer stood at "*) ok "the ledger names the instant the timer had stood on" ;;
    *) fail "a reconciled dated timer says where it stood" "$(led_actor reconciled deskcrab-wake-wrong)" ;;
esac

echo
echo "a near-lane delay timer inside its own window is left to fire:"
# Rule 8's near lane arms a booking due within the margin as a delay, and such
# a timer has no dated elapse to compare. Inside the margin of its record's
# moment it is about to fire, or has just — stopping it there to re-arm it
# would be the repair interrupting the thing it is repairing.
mclean
record deskcrab-wake-soon $(( NOW + 60 )) event "a move is waiting" job-runner
record deskcrab-wake-just $(( NOW - 30 )) event "a file just landed" notice-newfiles
alive deskcrab-wake-soon ""
alive deskcrab-wake-just ""
out="$(restore_against_manager)"
check_eq "neither is stopped" "$(stopped .)" "0"
check_eq "neither is re-armed" "$(attempts)" "0"
check_eq "and both records stand as they were" \
    "$(fire_of deskcrab-wake-soon) $(fire_of deskcrab-wake-just)" "$(( NOW + 60 )) $(( NOW - 30 ))"

echo
echo "a missed personal sitting is re-seated at its own hour, never fired blind:"
# Rule 30b. Three days and five hours ago: the moment went by while the timer
# stood armed for some other one. The overdue path would release it ninety
# seconds from now, whatever the hour — and five of them did stand in exactly
# this state on 2026-10-02. It goes back to the clock time she booked.
mclean
MISSED=$(( NOW - 3 * 86400 - 5 * 3600 ))
printf '%s\tscheduled\t%s\t%s\therself\thigh\tsol\n' "$MISSED" \
    "an evening with the book" "$(( NOW - 9 * 86400 ))" > "$W/deskcrab-wake-sit.wake"
alive deskcrab-wake-sit ""
out="$(restore_against_manager)"
newfire="$(fire_of deskcrab-wake-sit)"
check_eq "the stale timer is stopped" "$(stopped 'deskcrab-wake-sit.timer')" "1"
check "the record now names a moment still to come" [ "$newfire" -gt "$NOW" ]
check "and no further off than the next day" [ "$newfire" -le "$(( NOW + 86400 + 600 ))" ]
check_eq "at the clock time she booked" "$(clock "$newfire")" "$(clock "$MISSED")"
check_eq "the timer is armed at exactly that instant" \
    "$(armed "unit=deskcrab-wake-sit .*--on-calendar=$(utc "$newfire") ")" "1"
check_eq "and nothing is armed for the prompt overdue slot" "$(armed 'on-active')" "0"
check_eq "one timer, not two" "$(attempts)" "1"
check_eq "the ledger says reseated" "$(led_count reseated)" "1"
check_eq "and does not say overdue" "$(led_count overdue)" "0"
case "$(led_actor reseated deskcrab-wake-sit)" in
    "restore (missed "*) ok "with the moment it missed" ;;
    *) fail "a re-seating names the missed moment" "$(led_actor reseated deskcrab-wake-sit)" ;;
esac
check_eq "its agenda, booked-at and booker are untouched" \
    "$(cut -f2-5 "$W/deskcrab-wake-sit.wake")" \
    "$(printf 'scheduled\tan evening with the book\t%s\therself' "$(( NOW - 9 * 86400 ))")"
check_eq "and so are its effort and model overrides" \
    "$(cut -f6-7 "$W/deskcrab-wake-sit.wake")" "$(printf 'high\tsol')"
check_eq "which ride the re-armed unit too" \
    "$(armed 'deskcrab-wake-sit herself high sol$')" "1"
case "$out" in
    *"reseated: deskcrab-wake-sit"*) ok "restore says it out loud" ;;
    *) fail "a re-seating must be reported" "$out" ;;
esac

echo
echo "two sittings missed at the same hour do not come back on one second:"
mclean
record deskcrab-wake-s1 $(( MISSED ))         scheduled "the table, two more rows" herself
record deskcrab-wake-s2 $(( MISSED - 86400 )) scheduled "the openers, re-scored"   herself
alive deskcrab-wake-s1 ""
alive deskcrab-wake-s2 ""
out="$(restore_against_manager)"
a="$(fire_of deskcrab-wake-s1)"; b="$(fire_of deskcrab-wake-s2)"
gap=$(( a - b )); [ "$gap" -lt 0 ] && gap=$(( -gap ))
check_eq "both are re-seated" "$(led_count reseated)" "2"
check "onto different moments, a slot apart" [ "$gap" -ge 180 ]
check "and both within minutes of the hour they were booked for" [ "$gap" -le 600 ]

echo
echo "identical missed sittings collapse before either is re-seated:"
mclean
record deskcrab-wake-d1 $(( MISSED ))        scheduled "the same promise" herself
record deskcrab-wake-d2 $(( MISSED + 600 ))  scheduled "the same promise" herself
alive deskcrab-wake-d1 ""
alive deskcrab-wake-d2 ""
out="$(restore_against_manager)"
check_eq "one booking is left" "$(records)" "1"
check_eq "one is re-seated" "$(led_count reseated)" "1"
check_eq "one is collapsed" "$(led_count collapsed)" "1"
check_eq "and BOTH stale timers were stopped — a collapsed booking leaves no timer behind" \
    "$(stopped .)" "2"

echo
echo "everything else that was missed takes the prompt path:"
# Something is waiting on the other end of an event wake; a reason-less return
# measures idleness when it fires; another booker's follow-up is not a sitting;
# and a sitting found inside the grace is still within its own hour.
mclean
record deskcrab-wake-m1 $(( NOW - 7200 )) event     "a job that finished"   job-runner
record deskcrab-wake-m2 $(( NOW - 7000 )) scheduled ""                      herself
record deskcrab-wake-m3 $(( NOW - 6800 )) scheduled "a want you said"       promise-audit
record deskcrab-wake-m4 $(( NOW - 600 ))  scheduled "the sitting, just now" herself
for u in m1 m2 m3 m4; do alive "deskcrab-wake-$u" ""; done
out="$(restore_against_manager)"
check_eq "all four stale timers are stopped" "$(stopped .)" "4"
check_eq "all four are re-armed as overdue" "$(led_count overdue)" "4"
check_eq "and none is re-seated" "$(led_count reseated)" "0"
soonest="$(cut -f1 "$W"/*.wake | sort -n | head -1)"
check "the first comes back within minutes, not tomorrow" [ "$(( soonest - NOW ))" -le 300 ]
check_eq "the sitting inside its grace is one of them" \
    "$(led_actor overdue deskcrab-wake-m4)" "herself"

echo
echo "a re-seat that cannot arm puts the record back and says so:"
mclean
record deskcrab-wake-fail "$MISSED" scheduled "the sitting that could not re-arm" herself
alive deskcrab-wake-fail ""
sandbox_systemd_rc 1
out="$(restore_against_manager)"
sandbox_systemd_rc 0
check_eq "the record keeps the moment it had" "$(fire_of deskcrab-wake-fail)" "$MISSED"
check_eq "the failure is on the ledger" "$(led_count restore-failed)" "1"
check_eq "and no re-seating is claimed" "$(led_count reseated)" "0"
case "$out" in
    *"needs no restoring"*) fail "a pass that armed nothing must not claim the queue is whole" "$out" ;;
    *"could not be re-armed"*) ok "and the pass says what it could not do" ;;
    *) fail "a failed re-seat must be reported" "$out" ;;
esac
