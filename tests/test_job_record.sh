#!/bin/bash
# The engineering-record hook on detached jobs (specs/jobs.md rules 7b and
# 27-29, specs/engineering-records.md rule 13).
# Run: bash tests/test_job_record.sh
#
# The contract under test: a job dispatched against an engineering record may
# not be marked successful unless the builder updated that record — its
# last_touched must be newer than the job's dispatch time. A clean build that
# never wrote back ends failed with a reason naming the record, because "done"
# with nothing written to the thread it came from is exactly the unproven
# claim the whole record system exists to end.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
JOBS="$JOBS_DIR"
ENG="$XDG_DATA_HOME/deskcrab/engineering/records"
mkdir -p "$JOBS" "$T/work"
E() { DESKCRAB_ENG_DIR="$ENG" python3 "$REPO_DIR/lib/eng" "$@"; }

RID="$(E new "The widget wobbles under load")"

run() { # <shell body> — dispatch-side calls, never a real builder
    JOBS_DIR="$JOBS" sandbox_bash "$*" 2>&1
}

echo "dispatch refuses a record the drawer does not know:"
OUT="$(run 'DESKCRAB_NO_DISPATCH=1 job_start --record no-such-thing "fix the widget"')"
check "refused, naming the problem" contains "$OUT" "no engineering record 'no-such-thing'"
check "and nothing was dispatched"  contains "$OUT" "Not dispatched"

echo
echo "dispatch records a known record on the sidecar:"
OUT="$(run 'job_start --record "'"$RID"'" "fix the widget"')"
check "the dispatch went out" contains "$OUT" "dispatched"
DISPATCHED_ID="$(ls "$JOBS" | sed -n 's/\.json$//p' | head -1)"
check "a sidecar exists" test -n "$DISPATCHED_ID"
check_eq "the sidecar carries the record" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/$DISPATCHED_ID.json" record)" "$RID"
rm -f "$JOBS/$DISPATCHED_ID".*

echo
echo "a clean build whose record was never touched ends failed, naming it:"
"$REPO_DIR/lib/job-status" new "$JOBS" rec1 "a build against the widget record" ""
"$REPO_DIR/lib/job-status" set "$JOBS/rec1.json" record="$RID"
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO_DIR/lib/job-runner" rec1 "$T/work" >/dev/null 2>&1
RC=$?
check_eq "the sidecar says failed" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/rec1.json" state)" "failed"
check "the runner exited non-zero" test "$RC" -ne 0
check "the log names the record" \
    grep -q "engineering record '$RID' was never updated" "$JOBS/rec1.log"
check "the completion wake's reason names it too" \
    grep -rq "FAILED because engineering record '$RID'" "$WAKES_DIR"
check "the builder was told about its record in the prompt" \
    grep -q "dispatched against engineering record '$RID'" "$SANDBOX_CLAUDE_LOG"

echo
echo "a builder that touches its record finishes:"
# The stub builder does what a real one is told to: writes its outcome into
# the record before its final message. One second of sleep keeps the touch
# strictly newer than the dispatch second.
sandbox_stub claude <<STUB
#!/bin/bash
cat > /dev/null
sleep 1
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO_DIR/lib/eng" touch "$RID" "measured the wobble at 3mm; shimmed and re-ran the load test clean" >/dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"shimmed the widget; load test clean."}]}}'
printf '%s\n' '{"type":"result","result":"done"}'
exit 0
STUB
"$REPO_DIR/lib/job-status" new "$JOBS" rec2 "a build that writes back" ""
"$REPO_DIR/lib/job-status" set "$JOBS/rec2.json" record="$RID"
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO_DIR/lib/job-runner" rec2 "$T/work" >/dev/null 2>&1
check_eq "the sidecar says finished" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/rec2.json" state)" "finished"
check "the record carries the builder's entry" \
    grep -q "shimmed and re-ran the load test" "$ENG/$RID.md"

echo
echo "a job with no record is untouched by the hook:"
cp "$DESKCRAB_SANDBOX_LIB/stubs/claude" "$SANDBOX_BIN/claude"; chmod +x "$SANDBOX_BIN/claude"
"$REPO_DIR/lib/job-status" new "$JOBS" rec3 "a plain build, no record" ""
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO_DIR/lib/job-runner" rec3 "$T/work" >/dev/null 2>&1
check_eq "finished as ever" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/rec3.json" state)" "finished"
check "and no record complaint anywhere in its log" \
    bash -c '! grep -q "engineering record" "$1"' _ "$JOBS/rec3.log"

echo
echo "a build that failed on its own keeps its own reason:"
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"the build broke."}]}}'
exit 1
STUB
"$REPO_DIR/lib/job-status" new "$JOBS" rec4 "a build that breaks" ""
"$REPO_DIR/lib/job-status" set "$JOBS/rec4.json" record="$RID"
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO_DIR/lib/job-runner" rec4 "$T/work" >/dev/null 2>&1
check_eq "failed" "$("$REPO_DIR/lib/job-status" get "$JOBS/rec4.json" state)" "failed"
check "without the untouched-record complaint — the hook gates success only" \
    bash -c '! grep -q "was never updated" "$1"' _ "$JOBS/rec4.log"

echo
echo "requeue carries the record (rule 7b):"
cp "$DESKCRAB_SANDBOX_LIB/stubs/claude" "$SANDBOX_BIN/claude"; chmod +x "$SANDBOX_BIN/claude"
"$REPO_DIR/lib/job-status" new "$JOBS" rec5 "the widget brief to requeue" "" "$T/work"
"$REPO_DIR/lib/job-status" set "$JOBS/rec5.json" record="$RID"
OUT="$(run 'job_requeue rec5')"
check "requeue dispatched" contains "$OUT" "dispatched"
NEW_ID="$(ls "$JOBS" | sed -n 's/\.json$//p' | grep -v '^rec[0-9]$' | head -1)"
check "a new sidecar exists" test -n "$NEW_ID"
check_eq "and it carries the record forward" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/$NEW_ID.json" record)" "$RID"
