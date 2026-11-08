#!/bin/bash
# The work gate — specs/wake-queue.md rule 10c: the queue carries moments,
# not workloads. A self-booked scheduled wake with a work-shaped reason is
# refused at the one door with both roads named; every sanctioned identity,
# every event wake, and the gate's own off switch pass untouched. The
# positive sentences below are the shapes the user found pending on
# 2026-08-25; the counter-shapes are the timed checks that must stay
# bookable. Run: bash tests/test_wake_work_gate.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

# shellcheck source=/dev/null
source "$SANDBOX_REPO/lib/common.sh"   # for WAKES_DIR and WAKE_LEDGER

# Bookings drive the whole door: scratch WAKES_DIR, stubbed systemd-run, and
# the harness's opt-in are all the sandbox's.
bk() { # [--by X] [--kind K] <reason>  -> wake_book's stdout; rc preserved
    local by="" kind="scheduled"
    while [ $# -gt 1 ]; do
        case "$1" in
            --by)   by="$2"; shift 2 ;;
            --kind) kind="$2"; shift 2 ;;
            *) break ;;
        esac
    done
    sandbox_bash "wake_book ${by:+--by '$by'} '2h' '$kind' \"\$(cat <<'R'
$1
R
)\"; echo rc=\$?"
}

echo "workloads are refused, with both roads named:"
OUT="$(bk "Build the two guards from this morning's failure: (1) a check on anything left on the status channel that refuses shell commands")"
check "a leading build verb is refused" contains "$OUT" "rc=1"
check "…naming the record road" contains "$OUT" "crab eng add"
check "…and the builder road" contains "$OUT" "crab job"
OUT="$(bk "The durability boast, read as a shape rather than a word: pull every journal sentence where I report something as written-down-and-therefore-safe and check the thing is actually on disk")"
check "a record sweep is refused" contains "$OUT" "rc=1"
OUT="$(bk "the conf-roots job: read its log, run the new suite and the claims test under my own hand, and check the deployed script resolves the roots")"
check "builder-verification under her own hand is refused" contains "$OUT" "rc=1"
OUT="$(bk "at a quiet moment — fix the transcript parser dropping stamps off older turns")"
check "a build verb opening a clause after the intro is refused" contains "$OUT" "rc=1"
check_eq "every refusal is on the durable ledger" \
    "$(sandbox_count_in 'refused-work' "$WAKE_LEDGER")" "4"
check_eq "nothing was booked" "$(find "$WAKES_DIR" -maxdepth 1 -name '*.wake' 2>/dev/null | wc -l | tr -d ' ')" "0"

echo
echo "moments stay bookable — the counter-shapes, by name:"
OUT="$(bk "restart the chessweb bridge if no board is in flight, then prove the clock picker actually works before anyone plays")"
check "a restart guarded by nothing-in-flight books" contains "$OUT" "rc=0"
OUT="$(bk "Kassandra bar 50 — read it sighted and score the sealed envelope after its overnight separation")"
check "a sealed envelope to score books" contains "$OUT" "rc=0"
OUT="$(bk "The tidy unit's first unattended run: overnight the 02:30 timer should have fired both checks by itself. Look for a report file")"
check "a timer's first run to look in on books" contains "$OUT" "rc=0"
OUT="$(bk "noticing-him-over-time, the watched condition: has the ratio in the observation records moved at all, are there any miss records yet")"
check "a watched condition books" contains "$OUT" "rc=0"
OUT="$(bk "tell him about the oven timer idea when he surfaces around six")"
check "a thing to say at six books" contains "$OUT" "rc=0"

echo
echo "only her own scheduled hand is gated:"
OUT="$(bk --by promise-audit "You said you would fix the transcript parser tonight and nothing was booked — this is the promise, kept in front of you")"
check "the deferred-promise flow passes whatever its wording" contains "$OUT" "rc=0"
OUT="$(bk --by job-runner --kind event "Detached job 20990101-000000-1 finished: fix landed, run the suite yourself when convenient")"
check "an event wake passes whatever its wording" contains "$OUT" "rc=0"
OUT="$(sandbox_bash "WAKE_WORK_GATE=0 wake_book '2h' scheduled 'Build the two guards again, gate down'; echo rc=\$?")"
check "WAKE_WORK_GATE=0 stands the gate down" contains "$OUT" "rc=0"
