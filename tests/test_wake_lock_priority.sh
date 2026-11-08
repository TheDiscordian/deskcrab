#!/bin/bash
# The run lock's lanes — specs/wake-queue.md rules 21a and 21b.
# Run: bash tests/test_wake_lock_priority.sh
#
# On 2026-08-10 a chess move wake — an event wake, somebody sitting at the
# board behind it — lost the run lock to one long session and came back
# FIFTEEN MINUTES later. WAKE_EVENT_DEFER_DELAY had promised a seconds-scale
# retry since the day it was written; the re-book site read WAKE_DEFER_DELAY
# instead, so the variable that carried the promise was assigned and never
# used. This file pins the two rules that came out of that evening: a blocked
# event wake comes back on a short escalating backoff (30s, 60s, capped at
# 120s — reset the moment it takes the lock), and while it waits or is due
# back, the urgent lane keeps wakes nobody is waiting on from racing it for
# the next turn.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W"

# A one-second lock wait, so a blocked attempt costs the suite a second and
# not a minute and a half. The backoff knobs are pinned to their shipped
# defaults by name, so the assertions below read as the numbers in the spec.
crab() {
    WAKES_DIR="$W" WAKE_EVENT_LOCK_WAIT=1 \
    WAKE_EVENT_DEFER_DELAY=30 WAKE_EVENT_DEFER_MAX=120 \
        "$REPO/crab" "$@" 2>&1
}
run() { WAKES_DIR="$W" WANTS_FILE="$T/wants.md" sandbox_bash "$*" 2>&1; }
records() { ls "$W"/*.wake 2>/dev/null | wc -l; }
field() { [ -s "$W/$1.wake" ] || return 0; awk -F'\t' -v n="$2" 'NR == 1 { print $n }' "$W/$1.wake"; }
unit_of() { local f; f="$(ls -1 "$W"/*.wake 2>/dev/null | head -1)"; f="${f##*/}"; printf '%s' "${f%.wake}"; }
delta_of() { local f; f="$(field "$1" 1)"; echo $(( f - $(date +%s) )); }
claude_runs() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
CLAIM="$DESKCRAB_STATE_PREFIX-wake-urgent"
defer_counters() { ls "$DESKCRAB_STATE_PREFIX"-wake-defer-* 2>/dev/null | wc -l; }

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WANTS_FILE="$T/wants.md"
CONF
printf '# Wants\n\n- one want, so the wake path is enabled at all\n' > "$T/wants.md"

REASON="chessweb: your move as black in game test-001 — they played Bd3. Reply with --expect-ply 11"
seed_event() {  # <unit> — a fired event record with provenance and an effort override
    printf '%s\tevent\t%s\t%s\tchessweb\thigh\n' \
        "$(( $(date +%s) + 60 ))" "$REASON" "$(date +%s)" > "$W/$1.wake"
}

# The run lock, held by another hand for as long as each blocked case needs.
LOCKF="$DESKCRAB_STATE_PREFIX-wake.lock"
hold_lock() {
    ( exec 9>"$LOCKF"; flock -n 9 || exit 1; : > "$T/lock-held"; sleep 120 ) &
    LOCKPID=$!
    sandbox_at_exit "kill $LOCKPID"
    local held=0
    for _ in $(seq 1 200); do [ -e "$T/lock-held" ] && { held=1; break; }; sleep 0.05; done
    [ "$held" = 1 ] || die "the wake lock was never taken — every blocked branch below is unreachable"
    rm -f "$T/lock-held"
}
release_lock() {
    kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null
    local free=0
    for _ in $(seq 1 200); do
        if ( exec 9>"$LOCKF"; flock -n 9 ); then free=1; break; fi
        sleep 0.05
    done
    [ "$free" = 1 ] || die "the wake lock never came free again"
}

echo "a blocked event wake comes back in seconds, not in a quarter of an hour:"
hold_lock
seed_event deskcrab-wake-evt-1
crab wake event "$REASON" deskcrab-wake-evt-1 chessweb high > "$T/defer1.out" 2>&1
check "the fired booking retired its own record" [ ! -e "$W/deskcrab-wake-evt-1.wake" ]
check_eq "one deferral booking took its place" "$(records)" "1"
D="$(unit_of)"
check_eq "the deferral keeps its kind" "$(field "$D" 2)" "event"
check_eq "the deferral keeps its reason" "$(field "$D" 3)" "$REASON"
check_eq "the deferral keeps its provenance" "$(field "$D" 5)" "chessweb"
check_eq "the deferral keeps its effort override" "$(field "$D" 6)" "high"
d="$(delta_of "$D")"
check "the first re-book is the 30-second base, not the flat 900 ($d s)" \
    bash -c "[ $d -ge 20 ] && [ $d -le 31 ]"
check "the urgent lane's claim stands while the wake is due back" [ -s "$CLAIM" ]
check_eq "no model session was started by a deferred wake" "$(claude_runs)" "0"

echo
echo "...and each further miss doubles the backoff, to a cap:"
crab wake event "$REASON" "$D" chessweb high >/dev/null 2>&1
D="$(unit_of)"; d="$(delta_of "$D")"
check "the second miss re-books at 60 seconds ($d s)" \
    bash -c "[ $d -ge 50 ] && [ $d -le 61 ]"
crab wake event "$REASON" "$D" chessweb high >/dev/null 2>&1
D="$(unit_of)"; d="$(delta_of "$D")"
check "the third miss re-books at the 120-second cap ($d s)" \
    bash -c "[ $d -ge 100 ] && [ $d -le 121 ]"
crab wake event "$REASON" "$D" chessweb high >/dev/null 2>&1
D="$(unit_of)"; d="$(delta_of "$D")"
check "the fourth miss stays AT the cap — it never doubles past it ($d s)" \
    bash -c "[ $d -ge 100 ] && [ $d -le 121 ]"
check_eq "the effort override survives every round of the backoff" "$(field "$D" 6)" "high"

echo
echo "a taken lock resets the backoff and frees the lane:"
release_lock
before="$(claude_runs)"
crab wake event "$REASON" "$D" chessweb high > "$T/run1.out" 2>&1
check "with the lock free, the event wake runs its session" \
    [ "$(claude_runs)" -gt "$before" ]
check "the win clears the urgent lane's claim" [ ! -e "$CLAIM" ]
check_eq "the win clears the backoff counter" "$(defer_counters)" "0"
rm -f "$W"/*.wake  # the finished wake's own floor booking, cleared between cases
hold_lock
seed_event deskcrab-wake-evt-2
crab wake event "$REASON" deskcrab-wake-evt-2 chessweb high >/dev/null 2>&1
D="$(unit_of)"; d="$(delta_of "$D")"
check "the next miss starts over at the 30-second base ($d s)" \
    bash -c "[ $d -ge 20 ] && [ $d -le 31 ]"
release_lock
rm -f "$W"/*.wake
run 'wake_urgent_clear' >/dev/null
rm -f "$DESKCRAB_STATE_PREFIX"-wake-defer-*

echo
echo "the urgent lane: a wake nobody is waiting on yields to it, even at a free lock:"
AGENDA="come back to the wants"
run 'wake_urgent_mark 60' >/dev/null
before="$(claude_runs)"
printf '%s\t\t%s\n' "$(( $(date +%s) + 60 ))" "$AGENDA" > "$W/deskcrab-wake-timer-1.wake"
crab wake "" "$AGENDA" deskcrab-wake-timer-1 herself >/dev/null 2>&1
check_eq "no session was started while the claim stood" "$(claude_runs)" "$before"
check_eq "the yielding wake deferred itself instead — one booking" "$(records)" "1"
D="$(unit_of)"
check_eq "deferred as a scheduled wake, agenda intact" \
    "$(field "$D" 2)|$(field "$D" 3)" "scheduled|$AGENDA"
d="$(delta_of "$D")"
check "at its own flat spaced delay, which is unchanged ($d s)" \
    bash -c "[ $d -ge 895 ] && [ $d -le 905 ]"
check "and the claim it yielded to still stands" [ -s "$CLAIM" ]

echo
echo "...but an expired claim is ignored and removed, never obeyed:"
rm -f "$W"/*.wake
printf '%s\n' "$(( $(date +%s) - 5 ))" > "$CLAIM"
before="$(claude_runs)"
printf '%s\t\t%s\n' "$(( $(date +%s) + 60 ))" "$AGENDA" > "$W/deskcrab-wake-timer-2.wake"
crab wake "" "$AGENDA" deskcrab-wake-timer-2 herself > "$T/run2.out" 2>&1
check "the scheduled wake runs — a dead waiter parks nobody" \
    [ "$(claude_runs)" -gt "$before" ]
check "and the expired claim is gone" [ ! -e "$CLAIM" ]
rm -f "$W"/*.wake

echo
echo "...and an event wake never yields to its own lane:"
run 'wake_urgent_mark 60' >/dev/null
before="$(claude_runs)"
seed_event deskcrab-wake-evt-3
crab wake event "$REASON" deskcrab-wake-evt-3 chessweb high > "$T/run3.out" 2>&1
check "the event wake takes the free lock and runs" \
    [ "$(claude_runs)" -gt "$before" ]
check "and its win clears the claim on the fast path too" [ ! -e "$CLAIM" ]
rm -f "$W"/*.wake

echo
echo "a blocked scheduled wake still defers at the flat spaced delay:"
hold_lock
printf '%s\t\t%s\n' "$(( $(date +%s) + 60 ))" "$AGENDA" > "$W/deskcrab-wake-timer-3.wake"
crab wake "" "$AGENDA" deskcrab-wake-timer-3 herself >/dev/null 2>&1
D="$(unit_of)"; d="$(delta_of "$D")"
check "blocked with no claim standing: the 900-second slot, as before ($d s)" \
    bash -c "[ $d -ge 895 ] && [ $d -le 905 ]"
release_lock
