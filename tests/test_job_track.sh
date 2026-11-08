#!/bin/bash
# The job record lifecycle — specs/jobs.md rules 8, 9, 11, 33, 34, 36. The
# sidecar is now the durable record of a job's whole life: every transition
# lands on `history`, written by the one writer under the job's own lock; the
# stop path writes the one field name (the MAJ-11 regression — it wrote
# `status=stopped` once, and a deliberately stopped job kept "running" until
# the reaper called it died); a queued brief is neither reaped nor pruned
# while a dead `dispatched` one dies properly; and `show`, `since`, and the
# report answer without anyone opening a log.
# Run: bash tests/test_job_track.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JS="$REPO/lib/job-status"
J="$T/jobs"
mkdir -p "$J"

hist_count() { # <sidecar> — how many entries history holds
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("history",[])))' "$1"
}
hist_states() { # <sidecar> — the transition states, space-joined
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join(h["state"] for h in d.get("history",[])))' "$1"
}

echo "history — every transition lands, written by the one writer:"
"$JS" new "$J" h1 "a tracked brief" "" /tmp queued
check_eq "a new queued record seeds its history" "$(hist_states "$J/h1.json")" "queued"
"$JS" set "$J/h1.json" state=dispatched started=now
"$JS" set "$J/h1.json" state=running
"$JS" set "$J/h1.json" state=finished finished=now
check_eq "each transition appends" "$(hist_states "$J/h1.json")" "queued dispatched running finished"
# A repeat of the current state is not a transition: the stop path and the
# worker's trap both write `stopped`, and the lock serialises them into ONE
# history line, not two.
"$JS" set "$J/h1.json" state=finished
check_eq "a repeated state is not a second transition" "$(hist_count "$J/h1.json")" "4"

echo
echo "the lock lives in the writer — racing appends all survive:"
"$JS" new "$J" lk "a contested record" "" /tmp dispatched
for i in $(seq 1 12); do
    "$JS" append "$J/lk.json" attempts "entry-$i" &
done
wait
got="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("attempts",[])))' "$J/lk.json")"
check_eq "twelve parallel appends, twelve entries — no lost update" "$got" "12"

echo
echo "the stop path writes STATE, not a second field name (MAJ-11):"
# No unit and no live pid, so job_stop's kill paths are skipped and only the
# sidecar write is under test — which is exactly the write MAJ-11 got wrong.
"$JS" new "$J" st1 "a job to stop" "" /tmp dispatched
"$JS" set "$J/st1.json" state=running
JOBS_DIR="$J" sandbox_bash 'job_stop st1' >/dev/null 2>&1
check_eq "the sidecar says stopped" "$("$JS" get "$J/st1.json" state)" "stopped"
check_eq "and no stray status field exists" \
    "$(python3 -c 'import json,sys; print("status" in json.load(open(sys.argv[1])))' "$J/st1.json")" "False"
out="$("$JS" report "$J" 6 14)"
check "the report renders the deliberate stop" contains "$out" "stopped"
check_eq "and never reaps it as died" "$("$JS" get "$J/st1.json" state)" "stopped"

echo
echo "a queued record is neither reaped nor pruned (rule 33):"
"$JS" new "$J" q-old "an old queued brief" "" /tmp queued
# Age it far past both the 60-second liveness grace and the 14-day prune.
python3 - "$J/q-old.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["queued_epoch"] = d["started_epoch"] = int(time.time()) - 100 * 86400
json.dump(d, open(p, "w"))
PY
out="$("$JS" report "$J" 6 14)"
check "a hundred-day-old queued brief is still listed" contains "$out" "q-old"
check "as queued, with its wait" contains "$out" "queued ("
check "its sidecar survives the prune" [ -e "$J/q-old.json" ]
check_eq "and it was not reaped" "$("$JS" get "$J/q-old.json" state)" "queued"

echo
echo "a dead dispatched record is reaped exactly as a running one (rule 9):"
"$JS" new "$J" d1 "a dispatch whose worker never appeared" "" /tmp dispatched
python3 - "$J/d1.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["started_epoch"] = int(time.time()) - 600   # past the launch grace
d["pid"] = 999999999                          # no such process
d["pidstart"] = 12345
json.dump(d, open(p, "w"))
PY
"$JS" report "$J" 6 14 >/dev/null
check_eq "the worker that never appeared is died" "$("$JS" get "$J/d1.json" state)" "died"
check "and the reap is on its history" \
    contains "$(hist_states "$J/d1.json")" "died"

echo
echo "since — queued work counts apart from dispatched (rule 34):"
S="$T/since-jobs"
mkdir -p "$S"
"$JS" new "$S" s1 "dispatched work" "" /tmp dispatched
"$JS" new "$S" s2 "shelved work" "" /tmp queued
out="$("$JS" since "$S" 0)"
check "one dispatched" contains "$out" "1 job dispatched"
check "one queued, named apart" contains "$out" "1 queued for the night"
case "$out" in *"2 job"*) fail "a queued brief must not count as a dispatch" "$out" ;;
    *) ok "the queued brief is not a dispatch" ;; esac

echo
echo "show — the whole record, no log-reading required (rule 40):"
"$JS" set "$J/h1.json" model=fable effort=high want="A want title" branch=fix-branch
"$JS" append "$J/h1.json" commits "abc1234 the commit subject"
"$JS" append "$J/h1.json" attempts "2026-08-14 03:00:00 primary: ran clean"
out="$("$JS" show "$J/h1.json")"
for want_line in "state:" "a tracked brief" "fable" "A want title" \
    "fix-branch" "abc1234 the commit subject" "primary: ran clean" \
    "queued" "dispatched" "running"; do
    check "show carries: $want_line" contains "$out" "$want_line"
done

echo
echo "the report and its filters (rules 34, 40):"
"$JS" new "$J" c1 "a collected build" "" /tmp dispatched
"$JS" set "$J/c1.json" state=running
"$JS" set "$J/c1.json" state=finished finished=now
"$JS" set "$J/c1.json" state=collected branch=main
"$JS" append "$J/c1.json" commits "beef001 one real commit"
out="$("$JS" report "$J" 12 14)"
check "a collected job names its commits and branch" \
    contains "$out" "collected (1 commit on main)"
out="$("$JS" report "$J" 12 14 --state queued)"
check "--state queued lists the queued brief" contains "$out" "q-old"
case "$out" in *"c1"*) fail "--state queued must not list a collected job" "$out" ;;
    *) ok "--state filters to the one state" ;; esac
out="$("$JS" report "$J" 12 14 --live)"
check "the live copy counts the queue without carrying it" \
    contains "$out" "1 brief queued for the night"
case "$out" in *"an old queued brief"*) fail "the prompt copy must not carry the briefs" "$out" ;;
    *) ok "the briefs themselves stay out of the prompt copy" ;; esac
