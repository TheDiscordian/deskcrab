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
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-wakequeue.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — got [$2]"; }

# Every case runs in a scratch instance, and every case stubs the two calls that
# would reach outside it: systemd (no unit is ever created by this file) and the
# booker. A test that can start a real wake is not a test.
run() { # <shell body>
    WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" DESKCRAB_STATE_PREFIX="$T/state" \
        bash -c '
            source "$1/lib/common.sh" >/dev/null 2>&1
            shift
            systemctl() { return 1; }
            _wake_book() { printf "BOOKED %s %s %s\n" "$1" "$2" "$3" >> "'"$T"'/booked"; return 0; }
            eval "$1"
        ' _ "$REPO_DIR" "$*" 2>&1
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
mkdir -p "$T/bin"
cat > "$T/bin/systemd-run" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$T/bin/systemd-run"
book() {
    PATH="$T/bin:$PATH" WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" \
        DESKCRAB_STATE_PREFIX="$T/state" WANTS_FILE="$T/wants.md" \
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
    WAKES_DIR="$T/wakes" JOBS_DIR="$T/jobs" DESKCRAB_STATE_PREFIX="$T/state" \
        bash -c '
            source "$1/lib/common.sh" >/dev/null 2>&1
            shift
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
            eval "$1"
        ' _ "$REPO_DIR" "$*" 2>&1
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
printf '%s' $(( NOW - 600 )) > "$T/state-jobs-surfaced"

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
    "a turn from four hours ago nobody remembers" > "$T/state-sessions.log"
printf '%s\t%s\t20\tautonomous wake\t%s\n' \
    "$(date -d '-5 minutes' '+%Y-%m-%d %H:%M:%S')" "$(date -d '-5 minutes' '+%H:%M:%S')" \
    "$(head -c 400 /dev/zero | tr '\0' 'x') a wake five minutes ago" >> "$T/state-sessions.log"

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
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
