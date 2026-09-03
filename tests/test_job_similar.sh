#!/bin/bash
# Naming the live work a brief resembles — specs/jobs.md rule 7i. Four
# builders went out in eight minutes against one Firemaking sequence on
# 2026-09-02, two of them spending an account each only to discover the
# others mid-implementation in the same shared checkouts, because nothing
# in the dispatch path ever looked at what was already running.
# Run: bash tests/test_job_similar.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JS="$REPO/lib/job-status"
SIM="$REPO/lib/job-similar"
J="$T/jobs"
mkdir -p "$J"

lacks() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

mkjob() { # <id> <state> <description>
    "$JS" new "$J" "$1" "$3" "" "$T" dispatched
    "$JS" set "$J/$1.json" state="$2"
}

GAP="Close this OpenRSC semantic capability gap:"
mkjob live1 running \
    "$GAP Firemaking: after 'I think you should put the logs down before you light them!', the sequence needs a drop door and a use-on-ground door for tinderbox 166 on Logs 14"
mkjob live2 running \
    "$GAP Light a fire: use tinderbox item 166 on Logs item 14 in the inventory (item-on-item); observed no door exists for using one held item on another"
mkjob done1 collected \
    "$GAP Collect an unheld local corpse drop by identity; Fishing Bait 380 is reachable at distance 2 and take-ground has no door for it"
mkjob queued1 queued \
    "Stop a failed ingest from cancelling every other phase of the night; the refused model call at the top of sleep silently ends the whole run"

echo "a twin of live work is named, and the job still goes out (rule 7i):"
out="$("$SIM" "$J" "$GAP INTENT: light dropped Logs for Firemaking; observed state: the server message about putting the logs down when tinderbox 166 is used on Logs 14 in the inventory")"
rc=$?
check_eq "the exit is always clean — this warns, never refuses" "$rc" "0"
check "the live twin is named" contains "$out" "live1"
check "and so is its sibling" contains "$out" "live2"
check "with the word that says the dispatch proceeds" contains "$out" "dispatching anyway"

echo
echo "state decides what can be named at all:"
check "a collected job is never named — it is not in flight" \
    lacks "$out" "done1"
check "an unrelated queued brief is not named either" \
    lacks "$out" "queued1"

echo
echo "unrelated work is silent — a warning on every dispatch is no warning:"
out2="$("$SIM" "$J" "Rewrite the weather cache so alerts are parsed separately from conditions and the display half keeps its own copy")"
check_eq "nothing is printed" "$out2" ""

echo
echo "a queued brief IS in flight, and is named when it matches:"
out3="$("$SIM" "$J" "Stop a failed ingest from cancelling every other phase of the night; one refused model call at the top of sleep ends the run")"
check "the queued sibling is named" contains "$out3" "queued1"

echo
echo "the door survives what it is handed:"
check_eq "an empty brief prints nothing" "$("$SIM" "$J" "")" ""
check_eq "a jobs directory that does not exist prints nothing" \
    "$("$SIM" "$T/no-such-dir" "$GAP Firemaking tinderbox logs")" ""
printf 'not json at all\n' > "$J/broken.json"
out4="$("$SIM" "$J" "$GAP INTENT: light dropped Logs for Firemaking with tinderbox 166 on Logs 14")"
check "an unreadable sidecar costs nothing but itself" contains "$out4" "live1"

