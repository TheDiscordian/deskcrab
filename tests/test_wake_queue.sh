#!/bin/bash
# Tests for the wake queue's spacing and for what the CURRENT STATE OF YOURSELF
# block is allowed to say. Run: bash tests/test_wake_queue.sh
#
# The gap these were written for: on 2026-08-07 `crab status` listed three wake
# timers for the exact same second — 12:09:15, ids 132082/132083/132084. It was
# never a loop and never a double booking. Only one wake session runs at a time,
# and a wake that finds the lock held pushed itself back by a FLAT fifteen
# minutes; three wakes blocked inside the same minute therefore re-armed to the
# same second, one took the lock, and the other two were blocked again and
# marched on together. A convoy, not a duplicate.
#
# The same status block also called four-hour-old failed jobs "live" and spent
# more prompt on sessions that had finished twelve hours ago than on everything
# actually running. Both halves are asserted here.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# Every case stubs the two calls that would reach outside the sandbox: systemd
# (no unit is ever created by this file) and the booker. A test that can start a
# real wake is not a test — the sandbox holds that gate for every file now, and
# these overrides let the cases watch what WOULD have been booked.
run() { # <shell body>
    WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" sandbox_bash '
        systemctl() { return 1; }
        _wake_book() { printf "BOOKED %s %s %s\n" "$1" "$2" "$3" >> "'"$T"'/booked"; return 0; }
        '"$*" 2>&1
}

NOW="$(date +%s)"
mkdir -p "$T/wakes" "$T/jobs"

echo "wake_free_slot — a retry never lands on a moment already taken:"
rm -f "$T"/wakes/*.wake
out="$(run 'wake_free_slot 900')"
[ "$out" = "900" ] && ok "empty queue: the base delay is returned unchanged" \
                   || fail "empty queue returns base" "$out"

printf '%s\tevent\tone\n' $(( NOW + 900 )) > "$T/wakes/deskcrab-wake-a.wake"
out="$(run 'wake_free_slot 900')"
[ "$out" -ge 1080 ] 2>/dev/null && ok "taken moment: pushed a full spread past it ($out s)" \
                                || fail "taken moment is stepped over" "$out"

# The convoy itself: three wakes blocked in the same instant must get three
# different moments, not one.
printf '%s\tevent\ttwo\n'   $(( NOW + 900 )) > "$T/wakes/deskcrab-wake-b.wake"
printf '%s\tevent\tthree\n' $(( NOW + 900 )) > "$T/wakes/deskcrab-wake-c.wake"
out="$(run 'wake_free_slot 900')"
[ "$out" -ge 1080 ] 2>/dev/null && ok "three on one second: the fourth retry is spaced off them" \
                                || fail "spacing away from a crowded moment" "$out"

echo
echo "wake_pending_equivalent — the same promise twice is one promise:"
rm -f "$T"/wakes/*.wake
printf '%s\tevent\tjob 42 finished\n' $(( NOW + 900 )) > "$T/wakes/deskcrab-wake-e.wake"
printf '%s\tscheduled\t\n' $(( NOW + 1200 )) > "$T/wakes/deskcrab-wake-s.wake"

out="$(run 'wake_pending_equivalent '"$(( NOW + 960 ))"' event "job 42 finished" || echo NOMATCH')"
[ "$out" = "deskcrab-wake-e" ] && ok "an identical event reason coalesces (this is the deferral retry)" \
                               || fail "identical event reason coalesces" "$out"

out="$(run 'wake_pending_equivalent '"$(( NOW + 960 ))"' event "job 43 finished" || echo NOMATCH')"
[ "$out" = "NOMATCH" ] && ok "a DIFFERENT event reason still books its own wake" \
                       || fail "different event reasons stay separate" "$out"

out="$(run 'wake_pending_equivalent '"$(( NOW + 960 ))"' event "" || echo NOMATCH')"
[ "$out" = "NOMATCH" ] && ok "an event with no reason never coalesces (nothing to compare)" \
                       || fail "reasonless event does not coalesce" "$out"

out="$(run 'wake_pending_equivalent '"$(( NOW + 1260 ))"' scheduled "" || echo NOMATCH')"
[ "$out" = "deskcrab-wake-s" ] && ok "the wants wake still coalesces as it always did" \
                               || fail "scheduled coalescing unchanged" "$out"

echo
echo "wake_tidy — collapse the repeats, spread the collisions, purge the ghosts:"
rm -f "$T"/wakes/*.wake "$T/booked"
printf '%s\tevent\tsame promise\n' $(( NOW + 900 )) > "$T/wakes/deskcrab-wake-1.wake"
printf '%s\tevent\tsame promise\n' $(( NOW + 900 )) > "$T/wakes/deskcrab-wake-2.wake"
printf '%s\tevent\tother promise\n' $(( NOW + 900 )) > "$T/wakes/deskcrab-wake-3.wake"
out="$(run 'wake_tidy')"
left="$(ls "$T"/wakes/*.wake 2>/dev/null | wc -l)"
case "$out" in
    *collapsed*) ok "the duplicate promise is collapsed" ;;
    *) fail "duplicate collapsed" "$out" ;;
esac
case "$out" in
    *spread*) ok "the survivor sharing that second is moved off it" ;;
    *) fail "collision spread" "$out" ;;
esac
[ "$left" = "2" ] && ok "three bookings become two, and both are still bookings" \
                  || fail "two records survive" "$left"
# The spread one was re-booked under a new unit at a different moment.
moments="$(cut -f1 "$T"/wakes/*.wake | sort -u | wc -l)"
[ "$moments" = "2" ] && ok "the two survivors hold two different moments" \
                     || fail "survivors are spaced apart" "$moments"

echo
echo "crab wake-at — a NEW booking is spaced too, not only a retry:"
# Spacing the retries alone was measurably not enough: two concurrent sessions
# booking two different wakes for the same instant rebuild the collision from
# the front. This runs the real `crab wake-at` twice, with systemd-run stubbed
# so no unit is ever created.
rm -f "$T"/wakes/*.wake
book() {
    WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" WANTS_FILE="$T/wants.md" \
        "$REPO_DIR/crab" wake-at "$@" 2>&1
}
: > "$T/wants.md"
book 3600s event "first thing" >/dev/null
out="$(book 3600s event "second thing")"
case "$out" in
    *"Moved off a moment another wake already holds"*) ok "the second booking is moved off the taken second" ;;
    *) fail "new bookings are spaced" "$out" ;;
esac
moments="$(cut -f1 "$T"/wakes/*.wake | sort -u | wc -l)"
[ "$moments" = "2" ] && ok "two bookings for one instant hold two moments" \
                     || fail "two distinct moments" "$moments"
# ...but the same promise twice is still one promise, spacing or no spacing.
out="$(book 3600s event "first thing")"
case "$out" in
    *"already pending"*) ok "an identical promise is still refused, not spaced" ;;
    *) fail "identical promise refused" "$out" ;;
esac

echo
echo "wake_tidy — a timer that never fired is not a ghost:"
# Two record-less transient timers. One has already gone off (LastTriggerUSec
# set) — that one is finished business and gets purged. The other has never
# fired: its record was lost by some other hand, but the wake itself is still
# coming, and cancelling it would call off a wake nobody asked to call off.
rm -f "$T"/wakes/*.wake "$T/stopped"
run_sysd() {
    WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" sandbox_bash '
            systemctl() {
                case "$*" in
                    *list-units*) echo "  deskcrab-wake-111-1.timer loaded active waiting"
                                  echo "  deskcrab-wake-222-2.timer loaded active waiting"; return 0 ;;
                    *is-active*)  return 1 ;;
                    *LastTriggerUSec*)
                        case "$*" in *deskcrab-wake-111-1.timer*) echo "Fri 2026-08-07 09:45:00 EDT" ;; esac
                        return 0 ;;
                    *stop*) printf "%s\n" "$*" >> "'"$T"'/stopped"; return 0 ;;
                esac
                return 0
            }
            _wake_book() { return 0; }
            '"$*" 2>&1
}
out="$(run_sysd 'wake_tidy')"
case "$out" in
    *"purged: deskcrab-wake-111-1"*) ok "the fired, record-less timer is purged" ;;
    *) fail "fired ghost purged" "$out" ;;
esac
case "$out" in
    *"deskcrab-wake-222-2"*) fail "a never-fired timer is left alone" "$out" ;;
    *) ok "the never-fired timer is left alone (its wake still happens)" ;;
esac

echo
echo "the prompt block — live only, history one command away:"
# A job that failed hours ago, one that failed a moment ago, one running.
cat > "$T/jobs/old.json" <<EOF
{"id":"old","description":"a build that died at two in the morning","state":"failed",
 "exit":1,"started_epoch":$(( NOW - 40000 )),"finished_epoch":$(( NOW - 39000 )),
 "finished":"2026-08-07 02:06:00"}
EOF
cat > "$T/jobs/fresh.json" <<EOF
{"id":"fresh","description":"a build that died since the last turn","state":"failed",
 "exit":1,"started_epoch":$(( NOW - 300 )),"finished_epoch":$(( NOW - 30 )),
 "finished":"2026-08-07 12:00:00"}
EOF
cat > "$T/jobs/live.json" <<EOF
{"id":"live","description":"work happening right now","state":"running",
 "started_epoch":$(( NOW - 120 )),"pid":$$,"pidstart":$(awk '{print $22}' "/proc/$$/stat")}
EOF
printf '%s' $(( NOW - 600 )) > "$DESKCRAB_STATE_PREFIX-jobs-surfaced"

out="$(run 'jobs_report --live')"
case "$out" in
    *"a build that died at two in the morning"*) fail "old failure is kept out of the live list" "$out" ;;
    *) ok "the four-hour-old failure is NOT in the live list" ;;
esac
case "$out" in
    *"ENDED SINCE YOUR LAST TURN"*"died since the last turn"*) ok "a failure since the last turn is surfaced once" ;;
    *) fail "fresh failure surfaced" "$out" ;;
esac
case "$out" in
    *"work happening right now"*) ok "running work is listed" ;;
    *) fail "running work listed" "$out" ;;
esac
# ...and only once. The second render is a later turn: the news is old news.
out="$(run 'jobs_report --live')"
case "$out" in
    *"ENDED SINCE YOUR LAST TURN"*) fail "the same failure is not reported twice" "$out" ;;
    *) ok "the second turn does not repeat it" ;;
esac

# Finished sessions stay in the block, but as memory of the last half hour —
# not as twelve hours of full turn text. The user's amendment, 2026-08-07 12:09:
# "cut it to the last thirty minutes ... so it matches what I actually remember".
printf '%s\t%s\t20\tdesktop turn\t%s\n' \
    "$(date -d '-4 hours' '+%Y-%m-%d %H:%M:%S')" "$(date -d '-4 hours' '+%H:%M:%S')" \
    "a turn from four hours ago nobody remembers" > "$DESKCRAB_STATE_PREFIX-sessions.log"
printf '%s\t%s\t20\tautonomous wake\t%s\n' \
    "$(date -d '-5 minutes' '+%Y-%m-%d %H:%M:%S')" "$(date -d '-5 minutes' '+%H:%M:%S')" \
    "$(head -c 400 /dev/zero | tr '\0' 'x') a wake five minutes ago" >> "$DESKCRAB_STATE_PREFIX-sessions.log"

out="$(run 'session_history --recent')"
case "$out" in
    *"four hours ago"*) fail "the prompt copy reaches back only half an hour" "$out" ;;
    *) ok "a four-hour-old session is out of the prompt copy" ;;
esac
case "$out" in
    *"a wake five minutes ago"*) fail "a long entry is cut to one line" "$out" ;;
    *xxx*) ok "the last half hour is kept, trimmed to a line" ;;
    *) fail "recent session kept" "$out" ;;
esac

out="$(run 'self_state_report --prompt')"
case "$out" in
    *"Recently finished (last 30 min"*) ok "the prompt block reaches back thirty minutes, not twelve hours" ;;
    *) fail "prompt block keeps a 30-minute memory" "$out" ;;
esac
case "$out" in
    *"Recently finished (last 12h)"*) fail "the twelve-hour heading is out of the prompt block" "$out" ;;
    *) ok "the twelve-hour section is not in the prompt block" ;;
esac
case "$out" in
    *"Pending wakes (next"*) ok "pending wakes are stated as a horizon, not a dump" ;;
    *) fail "wakes are horizon-limited" "$out" ;;
esac
case "$out" in
    *"Interrupted mid-work"*) fail "an empty interrupted section is omitted" "$out" ;;
    *) ok "the empty 'Interrupted mid-work' heading is omitted" ;;
esac

out="$(run 'self_state_report')"
case "$out" in
    *"Recently finished"*) ok "crab status still shows finished sessions" ;;
    *) fail "crab status keeps the history" "$out" ;;
esac
case "$out" in
    *"died at two in the morning"*) ok "crab status still shows old failures" ;;
    *) fail "crab status keeps failed jobs" "$out" ;;
esac

echo
echo "the record and the timer disagree — and the block says which way:"
# specs/self-awareness.md rules 1 to 4. The whole headline failure of
# 2026-08-07 lives in this gap: the report enumerated `systemctl list-timers`
# and consulted the records only to decorate a row it had already found, so
# twenty-five records with no timers rendered as "(none scheduled)". Records
# are the authority; timers are joined onto them; and each of the three ways
# they can disagree gets its own line.
rm -f "$T"/wakes/*.wake
NOW="$(date +%s)"
printf '%s\tscheduled\t\t%s\therself\n'                 $(( NOW + 1800 )) "$NOW" > "$T/wakes/deskcrab-wake-armed.wake"
printf '%s\tevent\ta booking whose timer died\t%s\tjob-runner\n' $(( NOW + 2400 )) "$NOW" > "$T/wakes/deskcrab-wake-unarmed.wake"
printf '%s\tscheduled\ta wake firing right now\t%s\therself\n'   $(( NOW + 3000 )) "$NOW" > "$T/wakes/deskcrab-wake-firing.wake"

# One user manager, three units: an armed timer for the first record, nothing
# at all for the second, an ACTIVE SERVICE for the third (a wake that is
# running, which cleared its own record first thing), and one transient timer
# that no record remembers.
run_units() { # <shell body>
    WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" sandbox_bash '
        systemctl() {
            case "$*" in
                *list-units*)
                    echo "deskcrab-wake-armed.timer loaded active waiting"
                    echo "deskcrab-wake-firing.service loaded active running"
                    echo "deskcrab-wake-990-1.timer loaded active waiting"
                    return 0 ;;
                *list-timers*) return 0 ;;
                *is-active*) return 1 ;;
            esac
            return 0
        }
        '"$*" 2>&1
}

rows="$(run_units 'wake_list')"
state_of() { printf '%s\n' "$rows" | awk -F'\t' -v u="$1" '$2 == u { print $7; exit }'; }
check_eq "a record with a live timer reads armed" "$(state_of deskcrab-wake-armed)" "armed"
check_eq "a record with NO live timer reads unarmed" "$(state_of deskcrab-wake-unarmed)" "unarmed"
check_eq "a record whose service is running reads firing" "$(state_of deskcrab-wake-firing)" "firing"
check_eq "a timer no record remembers reads orphan" "$(state_of deskcrab-wake-990-1)" "orphan"
check_eq "four rows, and the records led all three of theirs" \
    "$(printf '%s\n' "$rows" | grep -c '^')" "4"

out="$(run_units 'wakes_report --brief')"
case "$out" in
    *"a booking whose timer died"*"RECORDED BUT NOT ARMED"*) ok "the unarmed booking says so on its own line" ;;
    *) fail "an unarmed record renders as RECORDED BUT NOT ARMED" "$out" ;;
esac
case "$out" in
    *"a timer with no booking record"*) ok "the orphan timer gets its own line" ;;
    *) fail "a record-less timer renders as an orphan" "$out" ;;
esac
case "$out" in
    *"! 1 of these is RECORDED WITH NO LIVE TIMER"*) ok "and the divergence is counted, not just decorated" ;;
    *) fail "the unarmed count is stated" "$out" ;;
esac
case "$out" in
    *"! 1 live timer has no booking record"*) ok "so is the orphan count" ;;
    *) fail "the orphan count is stated" "$out" ;;
esac
case "$out" in
    *"firing now"*) ok "the wake running right now is marked as running, not as pending work" ;;
    *) fail "a firing wake is marked firing" "$out" ;;
esac
# The count is the whole point: three records exist, one timer is armed, and
# the number that leads the list is three.
case "$out" in
    *"4 total"*) ok "the total counts records first — three records and one orphan, not one timer" ;;
    *) fail "the total is built from the records" "$out" ;;
esac

echo
echo "the permanent timers are fixtures, never an orphan:"
# specs/self-awareness.md rule 3. deskcrab-wake.timer is the standing
# random-interval timer and deskcrab-wake-restore is the login reconciler:
# neither has ever had a booking record and neither is missing one. Reported as
# "a timer with no booking record" they become a wake she never booked, sitting
# in the block beside the real ones — which is what she saw, and reported, as a
# phantom third timer.
# This stub HONOURS the unit pattern it is given, unlike the one above, because
# the pattern is half of what is under test: `deskcrab-wake-*` does not match
# `deskcrab-wake.timer` — there is no hyphen before the dot — so the narrower
# glob never saw the standing timer at all and the background row it renders
# could not be built.
run_fixtures() { # <shell body>
    WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" sandbox_bash '
        systemctl() {
            local pat u
            case "$*" in
                *list-units*)
                    pat="${!#}"
                    for u in deskcrab-wake-armed.timer deskcrab-wake.timer \
                             deskcrab-wake.service deskcrab-wake-restore.service; do
                        case "$u" in $pat) echo "$u loaded active waiting" ;; esac
                    done
                    return 0 ;;
                *list-timers*) return 0 ;;
                *is-active*) return 1 ;;
            esac
            return 0
        }
        '"$*" 2>&1
}
rm -f "$T"/wakes/*.wake
printf '%s\tscheduled\t\t%s\therself\n' $(( NOW + 1800 )) "$NOW" > "$T/wakes/deskcrab-wake-armed.wake"
rows="$(run_fixtures 'wake_list')"
check_eq "the standing background timer is not an orphan" \
    "$(printf '%s\n' "$rows" | awk -F'\t' '$7 == "orphan"' | grep -c '^')" "0"
check_eq "it renders as the background timer it is" \
    "$(printf '%s\n' "$rows" | awk -F'\t' '$7 == "background" { print $2 }')" "deskcrab-wake"
out="$(run_fixtures 'wakes_report --brief')"
case "$out" in
    *"no booking record"*) fail "a permanent timer was reported as a lost booking" "$out" ;;
    *) ok "and the report raises no missing-record warning about it" ;;
esac

echo
echo "a reason with a newline in it coalesces with itself:"
# The record squashes newlines and tabs on the way in, and the coalescing test
# compared the caller's RAW reason against the stored copy — so a multi-line
# reason (every builder's task description is one) could never equal itself,
# and an event re-booked by its own deferral stacked a fresh wake every time.
rm -f "$T"/wakes/*.wake
MULTI="Detached job 42 finished.
Task was: rebuild the index
and verify it."
run_multi() { WAKES_DIR="$T/wakes" WANTS_FILE="$T/wants.md" sandbox_bash "$*" 2>&1; }
run_multi 'wake_book --by job-runner 2h event "'"$MULTI"'"' > /dev/null
first="$(ls "$T"/wakes/*.wake 2>/dev/null | wc -l)"
out="$(run_multi 'wake_book --by job-runner 2h event "'"$MULTI"'"')"
check_eq "the same multi-line event does not stack a second booking" \
    "$(ls "$T"/wakes/*.wake 2>/dev/null | wc -l)" "$first"
case "$out" in
    *"already pending"*) ok "and it says which booking already covers it" ;;
    *) fail "the second booking should coalesce" "$out" ;;
esac

echo
echo "a record is written by rename, never by truncating in place:"
# Readers hold no lock and wake_record_read rejects a zero-length file, so an
# in-place write makes the booking invisible to the state block, the spacing
# scan and the coalescing test for as long as the write takes.
rm -f "$T"/wakes/*.wake
run_multi 'wake_state_write deskcrab-wake-atomic 99999999 scheduled "a reason"' > /dev/null
check_eq "the record is complete" \
    "$(awk -F'\t' 'NR == 1 { print NF }' "$T/wakes/deskcrab-wake-atomic.wake")" "5"
check_eq "and no temp file is left where a reader could glob it" \
    "$(ls "$T"/wakes/*.wake 2>/dev/null | wc -l)" "1"
check_eq "the temp name is hidden from every reader's glob" \
    "$(ls -a "$T"/wakes/ | grep -c 'wtmp')" "0"

echo
echo "a pending wake reads reason first and machinery after:"
# specs/self-awareness.md rule 35. The row used to open with the kind —
# "scheduled: <reason>" — putting a piece of queue vocabulary that answers
# nothing in front of the only part of the line she can actually say.
rm -f "$T"/wakes/*.wake
printf '%s\tscheduled\tKassandra bar 14: write the blind prediction\t%s\therself\n' \
    $(( NOW + 1800 )) "$NOW" > "$T/wakes/deskcrab-wake-reason.wake"
out="$(run 'wakes_report --brief')"
case "$out" in
    *"— Kassandra bar 14: write the blind prediction (booked by you"*)
        ok "the reason leads and the provenance trails it" ;;
    *) fail "the row should read '<time> — <reason> (booked by you)'" "$out" ;;
esac
case "$out" in
    *"scheduled: Kassandra"*) fail "the kind is still leading the row" "$out" ;;
    *) ok "and the kind is no longer in front of it" ;;
esac

echo
echo "provenance survives the round trip — booked by X, read back as X:"
rm -f "$T"/wakes/*.wake
book_by() { WAKES_DIR="$T/wakes" WANTS_FILE="$T/wants.md" "$REPO_DIR/crab" wake-at "$@" 2>&1; }
book_by --by promise-audit 2h event "a want you said and did not write down" > /dev/null
rows="$(run 'wake_list')"
check_eq "the record names the subsystem that booked it" \
    "$(printf '%s\n' "$rows" | awk -F'\t' 'NR == 1 { print $6 }')" "promise-audit"
out="$(run 'wakes_report')"
case "$out" in
    *"(booked by promise-audit"*) ok "and the block renders it, so 'scheduled by me' is answerable" ;;
    *) fail "the block renders provenance" "$out" ;;
esac
check_eq "booked-at is recorded too, as an epoch" \
    "$(printf '%s\n' "$rows" | awk -F'\t' 'NR == 1 { print ($5 ~ /^[0-9]+$/) }')" "1"

echo
echo "the unit a booking asks for carries --collect and a runtime ceiling:"
# MAJ-13 and MAJ-14. A wake unit without --collect leaks into the user manager
# when it fails (two were sitting failed when this was written, one of them
# pointing at a checkout that had been deleted), and a wake with no unit-level
# ceiling has only the in-process stall watchdog — which by construction cannot
# reap a session that keeps emitting output. TimeoutStartSec, not RuntimeMaxSec:
# a transient systemd-run service is Type=oneshot and the journal has been
# saying RuntimeMaxSec has no effect on one for as long as it has been set.
rm -f "$T"/wakes/*.wake
: > "$SANDBOX_SYSTEMD_LOG"
book_by --by wake-chain-floor 90min scheduled "" > /dev/null
argv="$(grep -m1 'on-active' "$SANDBOX_SYSTEMD_LOG" 2>/dev/null)"
count_arg() { local n; n="$(grep -c -- "$1" "$SANDBOX_SYSTEMD_LOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }
check_eq "exactly one unit was asked for" "$(count_arg 'on-active')" "1"
case "$argv" in
    *"--collect"*) ok "it is booked with --collect, so a failed unit does not leak" ;;
    *) fail "every wake unit carries --collect" "$argv" ;;
esac
case "$argv" in
    *"-p TimeoutStartSec="*) ok "and with a start timeout, which is the ceiling that applies to a oneshot" ;;
    *) fail "every wake unit carries a runtime ceiling" "$argv" ;;
esac
check_eq "no RuntimeMaxSec, which systemd ignores on a oneshot" "$(count_arg 'RuntimeMaxSec')" "0"
# Background CPU priority, rule 12a: nobody is waiting on a wake, so the unit
# yields the processor to a turn somebody IS waiting on. Priority only.
case "$argv" in
    *"-p CPUWeight="*) ok "the unit is booked at a background CPU weight" ;;
    *) fail "every wake unit carries the background CPU weight (rule 12a)" "$argv" ;;
esac
case "$argv" in
    *"-p Nice="*) ok "and at a background niceness" ;;
    *) fail "every wake unit carries the background niceness (rule 12a)" "$argv" ;;
esac
case "$argv" in
    *"--on-active="*) ok "booked as a delay, never as a calendar spec that would repeat daily" ;;
    *) fail "a booking is a delay" "$argv" ;;
esac
case "$argv" in
    *"--setenv=DESKCRAB_CONF=$DESKCRAB_CONF"*) ok "the instance's config travels into the unit" ;;
    *) fail "a scratch instance's wakes must fire back into the scratch instance" "$argv" ;;
esac
case "$argv" in
    *"--setenv=DESKCRAB_STATE_PREFIX=$DESKCRAB_STATE_PREFIX"*) ok "and so does its state prefix" ;;
    *) fail "the state prefix travels into the unit" "$argv" ;;
esac

echo
echo "the fourth gate — a scratch queue records a booking and arms nothing:"
# MAJ-34. Isolating what a test may TOUCH says nothing about what it may ARM:
# a /tmp checkout once held a live armed timer in the real user manager. The
# module refuses to create a unit when WAKES_DIR is not the live one, and
# DESKCRAB_ALLOW_SCRATCH_BOOKING is the documented opt-in for a harness that
# HAS stubbed systemd-run — which is why every case above could assert on argv
# at all. With the opt-in withdrawn, the record must still be written (a
# scratch instance with records and no timers is a state the queue is supposed
# to be able to describe) and NOTHING may reach systemd-run.
rm -f "$T"/wakes/*.wake "$T/wakes/ledger.log"
: > "$SANDBOX_SYSTEMD_LOG"
out="$(env -u DESKCRAB_ALLOW_SCRATCH_BOOKING \
    WAKES_DIR="$T/wakes" WANTS_FILE="$T/wants.md" \
    "$REPO_DIR/crab" wake-at 3h scheduled "" 2>&1)"
check_eq "the booking record is still written" "$(ls "$T"/wakes/*.wake 2>/dev/null | wc -l)" "1"
check_eq "and not one line reached systemd-run" \
    "$(count_arg .)" "0"
case "$out" in
    *"scratch instance"*"no timer armed"*) ok "the refusal says what it did and why" ;;
    *) fail "a scratch booking explains itself" "$out" ;;
esac
check_eq "the booking is still on the ledger — a record is a promise either way" \
    "$(awk -F'\t' '$2 == "booked" { n++ } END { print n + 0 }' "$T/wakes/ledger.log" 2>/dev/null || echo 0)" "1"

# The control. Without it, "zero units" proves only that the code path is dead.
rm -f "$T"/wakes/*.wake "$T/wakes/ledger.log"
: > "$SANDBOX_SYSTEMD_LOG"
book_by 3h scheduled "" > /dev/null
check_eq "with the opt-in back, the same booking does reach the stub" \
    "$(count_arg 'on-active')" "1"
