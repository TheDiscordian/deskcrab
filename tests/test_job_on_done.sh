#!/bin/bash
# The errand owed at a job's completion — specs/jobs.md rules 7j-7k — and the
# builder prompt's foreground gate (rule 39a).
# Run: bash tests/test_job_on_done.sh
#
# The defect under test (2026-08-21): "when this job exits, send the message"
# lived only in the conversation; the completion wake arrived holding the log
# and nothing else, and the message was never sent. Now the errand rides the
# sidecar — `crab job --on-done` at dispatch, `crab job on-done <id>` for a
# job already in flight — and every completion wake's reason ends with it,
# verbatim, as an OWED action the waking session performs or reports undone.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
JOBS="$JOBS_DIR"
JS="$REPO_DIR/lib/job-status"
WANTS="$XDG_DATA_HOME/deskcrab/wants.md"
mkdir -p "$JOBS" "$T/work"
printf -- '- mend the clock\n' > "$WANTS"

# Every runner this file starts by hand reads stdin from /dev/null, exactly as
# systemd and the setsid fallback hand it in production: the stub CLI drains
# its stdin, and a runner inheriting a harness's open socket there blocks on
# the drain forever.
run() { JOBS_DIR="$JOBS" sandbox_bash "$*" 2>&1 </dev/null; }
dry() { JOBS_DIR="$JOBS" DESKCRAB_NO_DISPATCH=1 sandbox_bash "$*" 2>&1 </dev/null; }
errands() { "$JS" list "$JOBS/$1.json" on_done; }
clear_wakes() { rm -f "${WAKES_DIR:?}"/*.wake; }
wait_ended() { # <id> — until the setsid-fallback runner's own pid is gone.
    # The state alone is not the signal: `finished` lands BEFORE collection
    # and the wake booking, and a poll that stopped there read a run still
    # on its feet as one that had ended.
    local i pid=""
    for i in $(seq 300); do
        [ -n "$pid" ] || pid="$("$JS" get "$JOBS/$1.json" pid 2>/dev/null)"
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    return 1
}

E1="Send the user one Signal line: the clock build landed, the chime is back"
E2="Restart the chess bridge so it picks up the new clock"

echo "the door — the dry run names the errand, and a bad one is refused (rule 7j):"
OUT="$(dry 'job_start --on-done "'"$E1"'" "mend the clock"')"
check "the brief would dispatch" contains "$OUT" "Would dispatch"
check "and the line names the errand" contains "$OUT" "(on-done: $E1)"
OUT="$(dry 'job_start --on-done "   " "mend the clock"')"
check "an empty errand is refused" contains "$OUT" "Not dispatched"
check "naming the emptiness" contains "$OUT" "errand is empty"
LONG="$(printf 'x%.0s' $(seq 1001))"
OUT="$(dry 'job_start --on-done "'"$LONG"'" "mend the clock"')"
check "an over-long errand is refused" contains "$OUT" "1000 at most"
check_eq "and nothing was recorded" \
    "$(ls "$JOBS"/*.json 2>/dev/null | wc -l | tr -d ' ')" "0"

echo
echo "dispatch — the errands land on the sidecar and the wake carries them (rules 7j-7k):"
OUT="$(run 'export WANTS_FILE="'"$WANTS"'"; job_start -f --on-done "'"$E1"'" --on-done "'"$E2"'" "mend the clock"; echo "ID=$JOB_START_ID"')"
ID="$(printf '%s\n' "$OUT" | sed -n 's/^ID=//p' | tail -1)"
check "the brief dispatched" contains "$OUT" "dispatched"
check "and the door said what is owed" contains "$OUT" "on-done errand owed at completion: $E1"
check "a sidecar exists" test -n "$ID"
check_eq "both errands are on the record, in order" "$(errands "$ID")" "$E1
$E2"
check "crab job show prints them" \
    contains "$("$JS" show "$JOBS/$ID.json")" "owed at completion:"
check "the job log names the errand before the builder writes a word" \
    grep -q "on-done errand owed at completion — $E1" "$JOBS/$ID.log"
check "the detached runner ended" wait_ended "$ID"
check_eq "a clean run collected" "$("$JS" get "$JOBS/$ID.json" state)" "collected"
check "the runner logged what it owed at boot" \
    grep -q "job-runner: on-done errand owed at completion" "$JOBS/$ID.log"
WAKE="$(grep -l "OWED ERRANDS (2)" "$WAKES_DIR"/*.wake 2>/dev/null | head -1)"
check "the completion wake was booked carrying the OWED block" test -n "$WAKE"
REASON=""
if [ -n "$WAKE" ]; then
    REASON="$(cut -f3 "$WAKE")"
    check_eq "as an event wake" "$(cut -f2 "$WAKE")" "event"
    check "the reason opens on the job's outcome" \
        contains "$REASON" "Detached job $ID finished"
    check "and ends with the first errand verbatim" contains "$REASON" "1) «$E1»"
    check "and the second" contains "$REASON" "2) «$E2»"
    check "told to do it now or report it undone" \
        contains "$REASON" "say plainly in your reply that it was NOT done and why"
fi
check "the builder was told the foreground gate (rule 39a)" \
    grep -q "last tool call was a background dispatch" "$SANDBOX_CLAUDE_LOG"

echo
echo "...and the fired wake's prompt holds the errand as its agenda (rule 7k):"
if [ -n "$WAKE" ]; then
    : > "$SANDBOX_CLAUDE_LOG"
    # The wake door needs a shelf to exist at all (crab: "WANTS_FILE is not
    # configured — autonomous wakes are disabled"); the sandbox conf names none.
    WANTS_FILE="$WANTS" "$REPO_DIR/crab" wake event "$REASON" \
        "$(basename "$WAKE" .wake)" job-runner >/dev/null 2>&1 </dev/null || true
    check "the wake reached the CLI" test -s "$SANDBOX_CLAUDE_LOG"
    check "with the reason as its agenda" \
        grep -q "This is what happened: Detached job $ID" "$SANDBOX_CLAUDE_LOG"
    check "the OWED block in the prompt" grep -q "OWED ERRANDS (2)" "$SANDBOX_CLAUDE_LOG"
    check "and the errand verbatim" grep -qF "«$E1»" "$SANDBOX_CLAUDE_LOG"
else
    fail "no wake record to fire — the prompt cases cannot run"
fi

echo
echo "a queued brief keeps its errand, and more can be attached while it waits (rule 7j):"
OUT="$(run 'export WANTS_FILE="'"$WANTS"'"; job_start --on-done "'"$E1"'" "shelve the clock brief for the night"; echo "ID=$JOB_START_ID"')"
QID="$(printf '%s\n' "$OUT" | sed -n 's/^ID=//p' | tail -1)"
check "the brief queued" contains "$OUT" "QUEUED"
check_eq "with the errand on its sidecar" "$(errands "$QID")" "$E1"
OUT="$(JOBS_DIR="$JOBS" "$REPO_DIR/crab" job on-done "$QID" "$E2" 2>&1)"
check "crab job on-done attaches to the queued record" \
    contains "$OUT" "Errand attached to job $QID (queued)"
check_eq "both are on the list" "$(errands "$QID")" "$E1
$E2"
OUT="$(JOBS_DIR="$JOBS" "$REPO_DIR/crab" job on-done "$QID" "$E2" 2>&1)"
check "an identical errand coalesces" contains "$OUT" "already attached"
check_eq "and the list did not grow" "$(errands "$QID" | wc -l | tr -d ' ')" "2"
OUT="$(JOBS_DIR="$JOBS" "$REPO_DIR/crab" job on-done "$QID" "   " 2>&1)"; RC=$?
check "an empty errand is refused" test "$RC" -ne 0
check "in plain words" contains "$OUT" "errand is empty"

echo
echo "a running job takes an errand; an ended one refuses it (rule 7j):"
"$JS" new "$JOBS" run1 "a build still in flight" "" "$T/work"
OUT="$(run 'job_on_done run1 "'"$E2"'"')"
check "attached while running" contains "$OUT" "Errand attached to job run1 (running)"
check "and the caller is told how it is carried" \
    contains "$OUT" "rides the completion wake as an OWED action"
check_eq "on the sidecar" "$(errands run1)" "$E2"
check "and in the job's log" \
    grep -q "crab job on-done: errand attached, owed at completion — $E2" "$JOBS/run1.log"
"$JS" new "$JOBS" done1 "a build that already ended" "" "$T/work" finished
OUT="$(run 'job_on_done done1 "'"$E1"'"')"; RC=$?
check "an ended job refuses" test "$RC" -ne 0
check "naming its state" contains "$OUT" "Not attached — job done1 is 'finished'"
check "with the why" contains "$OUT" "would never be carried"
check_eq "nothing written to the sidecar" "$(errands done1)" ""
check "and no log line" test ! -e "$JOBS/done1.log"
OUT="$(run 'job_on_done no-such "'"$E1"'"')"
check "an unknown id is an error" contains "$OUT" "No such job"

echo
echo "the errand rides a FAILED run's wake too — owed whatever the build did (rule 7k):"
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"the build broke."}]}}'
exit 1
STUB
"$JS" new "$JOBS" odf "a build that breaks with an errand owed" "" "$T/work" dispatched
"$JS" errand "$JOBS/odf.json" "$E1" >/dev/null
clear_wakes
WANTS_FILE="$WANTS" "$REPO_DIR/lib/job-runner" odf "$T/work" >/dev/null 2>&1 </dev/null
check_eq "the run failed" "$("$JS" get "$JOBS/odf.json" state)" "failed"
WAKE="$(grep -l "OWED ERRAND" "$WAKES_DIR"/*.wake 2>/dev/null | head -1)"
check "its wake carries the OWED block" test -n "$WAKE"
if [ -n "$WAKE" ]; then
    R="$(cut -f3 "$WAKE")"
    check "over the failure" contains "$R" "finished (failed"
    check "with the errand verbatim" contains "$R" "1) «$E1»"
fi

echo
echo "...and a died-waiting run's wake (rules 39, 7k):"
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Edits are in. Standing by for the monitor to report the other jobs done."}]}}'
printf '%s\n' '{"type":"result","result":"Edits are in. Standing by for the monitor to report the other jobs done."}'
exit 0
STUB
"$JS" new "$JOBS" odw "a build that parks on a wait with an errand owed" "" "$T/work" dispatched
"$JS" errand "$JOBS/odw.json" "$E2" >/dev/null
clear_wakes
WANTS_FILE="$WANTS" "$REPO_DIR/lib/job-runner" odw "$T/work" >/dev/null 2>&1 </dev/null
check_eq "failed by dying on a wait" "$("$JS" get "$JOBS/odw.json" state)" "failed"
WAKE="$(grep -l "FAILED by dying on a wait" "$WAKES_DIR"/*.wake 2>/dev/null | head -1)"
check "the wait wake was booked" test -n "$WAKE"
[ -n "$WAKE" ] && check "and still ends on the errand" contains "$(cut -f3 "$WAKE")" \
    "OWED ERRAND — attached to this job by the hand that dispatched it, to be done when the job exits: 1) «$E2»"

echo
echo "a job with no errand books exactly the wake it always did (rule 7k):"
cp "$DESKCRAB_SANDBOX_LIB/stubs/claude" "$SANDBOX_BIN/claude"; chmod +x "$SANDBOX_BIN/claude"
"$JS" new "$JOBS" plain "a plain build, nothing owed" "" "$T/work" dispatched
clear_wakes
WANTS_FILE="$WANTS" "$REPO_DIR/lib/job-runner" plain "$T/work" >/dev/null 2>&1 </dev/null
check_eq "collected" "$("$JS" get "$JOBS/plain.json" state)" "collected"
WAKE="$(ls "$WAKES_DIR"/*.wake 2>/dev/null | head -1)"
check "a wake was booked" test -n "$WAKE"
[ -n "$WAKE" ] && check_eq "with no OWED block" "$(sandbox_count_in "OWED ERRAND" "$WAKE")" "0"
check_eq "no errand line in its log" "$(sandbox_count_in "on-done errand" "$JOBS/plain.log")" "0"
check_eq "and show prints no such label" \
    "$("$JS" show "$JOBS/plain.json" | grep -c "owed at completion")" "0"

echo
echo "an instance with no wants file says the errand cannot be carried (rule 7k):"
"$JS" new "$JOBS" nowants "a build on an instance that books no wake" "" "$T/work" dispatched
"$JS" errand "$JOBS/nowants.json" "$E1" >/dev/null
clear_wakes
WANTS_FILE= "$REPO_DIR/lib/job-runner" nowants "$T/work" >/dev/null 2>&1 </dev/null
check_eq "no wake was booked" "$(ls "$WAKES_DIR"/*.wake 2>/dev/null | wc -l | tr -d ' ')" "0"
check "and the log says so, naming the errand" \
    grep -q "no completion wake is booked and the owed errand(s) cannot be carried.*$E1" "$JOBS/nowants.log"

echo
echo "requeue and the automatic block retry carry the errand (rule 7j):"
"$JS" new "$JOBS" rq1 "the clock brief to run again" "" "$T/work"
"$JS" errand "$JOBS/rq1.json" "$E1" >/dev/null
"$JS" set "$JOBS/rq1.json" state=failed exit=1 finished=now
OUT="$(dry 'job_requeue rq1')"
check "requeue reaches dispatch" contains "$OUT" "Would dispatch"
check "carrying the errand" contains "$OUT" "(on-done: $E1)"
"$JS" new "$JOBS" bl1 "the brief that was refused at the door" "" "$T/work"
"$JS" errand "$JOBS/bl1.json" "$E2" >/dev/null
"$JS" set "$JOBS/bl1.json" state=blocked exit=1 finished=now
OUT="$(dry 'job_start -O bl1 -C "'"$T/work"'" "the brief that was refused at the door"')"
check "the retry reaches dispatch naming its origin" contains "$OUT" "(retry of bl1)"
check "carrying the origin's errand" contains "$OUT" "(on-done: $E2)"
