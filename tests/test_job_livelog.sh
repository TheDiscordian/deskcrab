#!/bin/bash
# specs/jobs.md rule 26 — the job log fills while the builder is still alive.
# Run: bash tests/test_job_livelog.sh
#
# The gap these were written for: the log was assembled from the stream only
# after each attempt ENDED, so `crab job log` on a running job printed nothing,
# a stopped job kept nothing, and both were read — repeatedly, by the person
# the log exists for — as "the job produced nothing" when the work was half
# done. The runner now pipes the builder through a live filter into the log;
# these cases prove the log has content while the worker is alive, that a
# stopped worker keeps its partial output, that the pipeline still hands the
# CLI's own exit code to the state machine, and that an empty-but-running job
# answers with words instead of a blank.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
JOBS="$JOBS_DIR"
mkdir -p "$JOBS" "$T/work"

echo "a running builder's words are in the log before the run ends:"
# A builder that says one thing, then sits inside a long command — the shape
# of every compile. The sleep's own stdout is pointed away from the pipe so an
# orphaned sleep cannot hold the log's pipeline open after the stub is killed.
cat > "$T/claude-slow" <<'STUB'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"First partial report line from the builder."}]}}'
sleep 20 >/dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Never reached."}]}}'
STUB
chmod +x "$T/claude-slow"

"$REPO_DIR/lib/job-status" new "$JOBS" livetest "stream words as they come" ""
CLAUDE_BIN="$T/claude-slow" WANTS_FILE="$T/wants.md" \
    "$REPO_DIR/lib/job-runner" livetest "$T/work" >/dev/null 2>&1 &
RUNNER=$!

# Poll, up to ten seconds, for the first line to land while the worker runs.
seen=""
for _ in $(seq 100); do
    grep -q "First partial report line" "$JOBS/livetest.log" 2>/dev/null && { seen=1; break; }
    kill -0 "$RUNNER" 2>/dev/null || break
    sleep 0.1
done
[ -n "$seen" ] && ok "partial output reached the log while the builder was alive" \
    || fail "the log must fill during the run" "$(cat "$JOBS/livetest.log" 2>/dev/null)"
check "and the worker was still running when it did" kill -0 "$RUNNER"
check_eq "the sidecar still says running" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/livetest.json" state)" "running"
# The tee keeps the raw stream byte-identical for the viewer and the refusal
# slices: the same event must sit in the stream log as JSON.
check "the raw stream still carries the event for the viewer" \
    grep -q '"type":"assistant"' "$DESKCRAB_STATE_PREFIX-debug-job-livetest.log"

echo
echo "a stopped builder keeps what it had said:"
# systemctl stop TERMs the whole unit: the worker and the CLI both. Here that
# is the runner by pid and the stub by its sandbox-unique path.
kill -TERM "$RUNNER" 2>/dev/null
pkill -TERM -f "$T/claude-slow" 2>/dev/null
wait "$RUNNER" 2>/dev/null
check "the partial line survives the stop" \
    grep -q "First partial report line" "$JOBS/livetest.log"
out="$(grep -c "Never reached" "$JOBS/livetest.log" 2>/dev/null)"
check_eq "and nothing the builder never said appears" "${out:-0}" "0"
check_eq "the trap recorded the stop" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/livetest.json" state)" "stopped"
out="$("$REPO_DIR/crab" job log livetest 2>&1)"
case "$out" in *"First partial report line"*) ok "crab job log shows the stopped job's partial output" ;;
    *) fail "crab job log must show partial output" "$out" ;; esac

echo
echo "the pipeline hands the CLI's own exit code to the state machine:"
# tee and the filter both exit 0 whatever ran in front of them; a regression
# to \$? here would call every failed build finished.
cat > "$T/claude-fail" <<'STUB'
#!/bin/bash
echo "stub wrote this to stderr" >&2
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"The build broke and this is the report."}]}}'
exit 7
STUB
chmod +x "$T/claude-fail"
"$REPO_DIR/lib/job-status" new "$JOBS" failtest "break on purpose" ""
CLAUDE_BIN="$T/claude-fail" WANTS_FILE="$T/wants.md" \
    "$REPO_DIR/lib/job-runner" failtest "$T/work" >/dev/null 2>&1
check_eq "a run that exited 7 is failed" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/failtest.json" state)" "failed"
check_eq "with the CLI's own code, through the pipe" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/failtest.json" exit)" "7"
check "the model's words are in the log" \
    grep -q "The build broke" "$JOBS/failtest.log"
check "and so is the line that was not JSON at all" \
    grep -q "stub wrote this to stderr" "$JOBS/failtest.log"

cat > "$T/claude-ok" <<'STUB'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"All done, verified."}]}}'
printf '%s\n' '{"type":"result","result":"All done, verified."}'
exit 0
STUB
chmod +x "$T/claude-ok"
"$REPO_DIR/lib/job-status" new "$JOBS" oktest "succeed on purpose" ""
CLAUDE_BIN="$T/claude-ok" WANTS_FILE="$T/wants.md" \
    "$REPO_DIR/lib/job-runner" oktest "$T/work" >/dev/null 2>&1
check_eq "a clean run is still finished" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/oktest.json" state)" "finished"
out="$(grep -c "All done, verified." "$JOBS/oktest.log" 2>/dev/null)"
check_eq "a result that repeats the last block is not written twice" "${out:-0}" "1"

echo
echo "an empty log answers with words, and a bad id is never a task:"
"$REPO_DIR/lib/job-status" new "$JOBS" quiettest "think silently" ""
out="$("$REPO_DIR/crab" job log quiettest 2>&1)"
case "$out" in *"still running"*"no output captured yet"*) ok "empty-but-running says so explicitly" ;;
    *) fail "an empty running job must announce itself" "$out" ;; esac

out="$(DESKCRAB_NO_DISPATCH=1 "$REPO_DIR/crab" job log no-such-id 2>&1)"; rc=$?
case "$out" in *"No such job"*) ok "an unknown id is refused with words" ;;
    *) fail "an unknown id must be refused" "$out" ;; esac
check_eq "and refused with a failure code" "$rc" "1"
case "$out" in *dispatch*) fail "log must never fall through to dispatch" "$out" ;;
    *) ok "nothing was dispatched on the way" ;; esac
