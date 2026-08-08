#!/bin/bash
# Argument arity, on write and on read — specs/wake-queue.md rules 14 to 17.
# Run: bash tests/test_wake_arity.sh
#
# `crab wake-at <when> [kind] [reason]` was positional with no validation, so a
# caller who passed an agenda where the kind goes wrote the agenda into the
# KIND column and left the reason empty. `crab wake` then blanked any kind it
# did not recognise — and with it the agenda. A record of exactly that shape was
# on disk on 2026-08-07: a whole "re-dispatch the builder" brief sitting in the
# kind field of a wake that would have fired with nothing to do.
#
# Such a record is worse than a lost sentence. It never coalesces (its kind
# matches nothing), it never satisfies the floor (the floor counts scheduled
# bookings), and until MIN-5 was fixed it was DESTROYED rather than deferred
# when it lost the wake lock — the record was cleared before the code decided
# whether to re-book.
#
# So: normalise on write, normalise on read, tolerate the three-field shape
# without shifting it, and never drop a kind-less wake.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W"

run() { WAKES_DIR="$W" WANTS_FILE="$T/wants.md" sandbox_bash "$*" 2>&1; }
crab() { WAKES_DIR="$W" "$REPO/crab" "$@" 2>&1; }
records() { ls "$W"/*.wake 2>/dev/null | wc -l; }
field() { [ -s "$W/$1.wake" ] || return 0; awk -F'\t' -v n="$2" 'NR == 1 { print $n }' "$W/$1.wake"; }
nfields() { [ -s "$W/$1.wake" ] || return 0; awk -F'\t' 'NR == 1 { print NF }' "$W/$1.wake"; }
led_count() { awk -F'\t' -v a="$1" '$2 == a { n++ } END { print n + 0 }' "$W/ledger.log" 2>/dev/null || echo 0; }
unit_of() { local f; f="$(ls -1 "$W"/*.wake 2>/dev/null | head -1)"; f="${f##*/}"; printf '%s' "${f%.wake}"; }

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WANTS_FILE="$T/wants.md"
CONF
printf '# Wants\n\n- one want, so the wake path is enabled at all\n' > "$T/wants.md"

AGENDA="re-dispatch the builder and read what it actually wrote"

echo "on write — prose in the kind slot is the reason, and the record is five fields:"
rm -f "$W"/*.wake "$W/ledger.log"
out="$(crab wake-at 3600s "$AGENDA")"
check_eq "the booking is made, not refused" "$(records)" "1"
U="$(unit_of)"
check_eq "the record is written in the five-field shape" "$(nfields "$U")" "5"
check_eq "the kind slot holds a KIND" "$(field "$U" 2)" "scheduled"
check_eq "and the prose landed in the reason, whole" "$(field "$U" 3)" "$AGENDA"
check "the booked-at field is an epoch, not the reason" \
    bash -c '[ -n "'"$(field "$U" 4)"'" ] && case "'"$(field "$U" 4)"'" in *[!0-9]*) exit 1 ;; esac'
check_eq "and the provenance defaults to her own hand" "$(field "$U" 5)" "herself"
case "$out" in
    *"Wake scheduled"*) ok "the booking says it happened" ;;
    *) fail "a normalised booking still reports itself" "$out" ;;
esac

echo
echo "on read — a record whose agenda is in the kind column gets it back:"
# The shape actually found on disk: three fields, the brief in the kind column,
# an empty reason. Nothing has rewritten it; the reader has to recover it.
rm -f "$W"/*.wake
printf '%s\t%s\t\n' "$(( $(date +%s) + 3600 ))" "$AGENDA" > "$W/deskcrab-wake-legacy-agenda.wake"
out="$(run 'wake_record_read "$WAKES_DIR/deskcrab-wake-legacy-agenda.wake"
    printf "%s|%s|%s|%s\n" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_AT" "$WK_BOOKED_BY"')"
check_eq "the agenda is recovered as the reason, with the default kind" \
    "$out" "scheduled|$AGENDA|unknown|unknown"

# ...and it is recovered everywhere the queue is READ, not only in the reader:
# a record whose agenda cannot be seen in the state block is a record she has
# no way to know about.
out="$(run 'wake_list')"
case "$out" in
    *"$AGENDA"*) ok "the state block's own enumeration shows the recovered agenda" ;;
    *) fail "wake_list must render the recovered agenda" "$out" ;;
esac

echo
echo "on read — a three-field legacy record fills the gaps, it does not shift:"
rm -f "$W"/*.wake
FIRE=$(( $(date +%s) + 5400 ))
printf '%s\tevent\tjob 42 finished\n' "$FIRE" > "$W/deskcrab-wake-legacy-3.wake"
out="$(run 'wake_record_read "$WAKES_DIR/deskcrab-wake-legacy-3.wake"
    printf "%s|%s|%s|%s|%s\n" "$WK_FIRE" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_AT" "$WK_BOOKED_BY"')"
check_eq "fire, kind and reason stay exactly where they were" \
    "$out" "$FIRE|event|job 42 finished|unknown|unknown"

# The empty-reason case is the one that broke silently: a tab is IFS
# whitespace, so `read -r a b c d e` collapses the run and the booked-at ends
# up in the reason column. Every "come back to the wants" booking has an empty
# reason, which is to say: most of the queue.
rm -f "$W"/*.wake
printf '%s\tscheduled\t\t%s\tpromise-audit\n' "$FIRE" "$(date +%s)" > "$W/deskcrab-wake-empty-reason.wake"
out="$(run 'wake_record_read "$WAKES_DIR/deskcrab-wake-empty-reason.wake"
    printf "%s|%s|%s|%s\n" "$WK_KIND" "$WK_REASON" "$WK_BOOKED_AT" "$WK_BOOKED_BY"')"
check_eq "an empty reason does not shift the provenance into it" \
    "$out" "scheduled||$(date +%s)|promise-audit"

echo
echo "a kind-less wake that loses the lock is DEFERRED, never dropped:"
# The wake lock, held by another process for the life of this case. `crab wake`
# opens the same path fresh, so its flock -n has to fail — which is the whole
# point: the deferral branch is the one being tested, and if the barrier below
# never trips the case would instead start a (stubbed) session and prove
# nothing about deferral at all.
rm -f "$W"/*.wake "$W/ledger.log"
LOCKF="$DESKCRAB_STATE_PREFIX-wake.lock"
( exec 9>"$LOCKF"; flock -n 9 || exit 1; : > "$T/lock-held"; sleep 60 ) &
LOCKPID=$!
sandbox_at_exit "kill $LOCKPID"
held=0
for _ in $(seq 1 200); do [ -e "$T/lock-held" ] && { held=1; break; }; sleep 0.05; done
[ "$held" = 1 ] || die "the wake lock was never taken — the deferral branch is unreachable"
ok "the wake lock is held by another hand"

# A fired wake with NO kind and a real agenda, exactly as the background timer
# fires one. Its own record exists and must be retired; the deferral must
# re-book the agenda rather than let it die with the record.
printf '%s\t\t%s\n' "$(( $(date +%s) + 60 ))" "$AGENDA" > "$W/deskcrab-wake-kindless.wake"
crab wake "" "$AGENDA" deskcrab-wake-kindless promise-audit > "$T/deferral.out" 2>&1
check "the fired booking retired its own record" \
    [ ! -e "$W/deskcrab-wake-kindless.wake" ]
check_eq "and one new booking took its place — the wake was not dropped" \
    "$(records)" "1"
D="$(unit_of)"
check_eq "the agenda survives the deferral intact" "$(field "$D" 3)" "$AGENDA"
check_eq "a kind-less wake defers as a scheduled one, not as nothing" \
    "$(field "$D" 2)" "scheduled"
check_eq "and the deferral keeps the provenance it arrived with" \
    "$(field "$D" 5)" "promise-audit"
check_eq "the deferral is on the ledger like any other booking" \
    "$(led_count booked)" "1"
check_eq "no model session was started by a deferred wake" \
    "$(sandbox_count_in . "$SANDBOX_CLAUDE_LOG")" "0"

echo
echo "...and the deferred wake satisfies the floor, so nothing books on top of it:"
# The point of normalising the kind rather than blanking it: the floor counts
# SCHEDULED bookings from the records. A wake deferred with a blank kind would
# have left the floor unsatisfied, and ensure_next_wake would have booked a
# second wake beside it every time.
before="$(led_count booked)"
out="$(run 'ensure_next_wake')"
check_eq "ensure_next_wake books nothing — the deferral already covers the floor" \
    "$(led_count booked)" "$before"
check_eq "and the queue still holds exactly the one deferred booking" \
    "$(records)" "1"

# The control: with that booking gone, the floor DOES book. An assertion that
# nothing was booked is worth nothing unless something would have been.
rm -f "$W"/*.wake
out="$(run 'ensure_next_wake')"
check_eq "an empty queue gets its floor wake" "$(led_count booked)" "$(( before + 1 ))"
check_eq "booked in the floor's own name" \
    "$(awk -F'\t' '$2 == "booked" { last = $6 } END { print last }' "$W/ledger.log")" \
    "wake-chain-floor"
