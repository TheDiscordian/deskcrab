#!/bin/bash
# specs/jobs.md rule 22a — the tool-call stream outlives the state prefix.
# Run: bash tests/test_job_stream_archive.sh
#
# The gap this was written for: the stream — the job's falsifiable trace, the
# only record of which tools the builder actually ran — lived solely under
# /tmp, where the runner's own reap, or the next boot, erased it as soon as
# the job ended. Every claim in a morning report was checkable only while the
# machine happened to stay up and the sweep happened not to have passed. These
# cases prove the durable twin lands beside the job's log with the same bytes
# the viewer saw, that the evidence door (`crab job activity`) still answers
# after the /tmp copy is gone, that failed and stopped runs keep whatever
# trace they produced, and that the archive dies with the record on report's
# keep-days sweep — never before it.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
JOBS="$JOBS_DIR"
mkdir -p "$JOBS" "$T/work"

echo "a run with tool activity leaves a durable trace beside its log:"
cat > "$T/claude-tools" <<'STUB'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","id":"tu1","name":"Write","input":{"file_path":"/work/target.txt","content":"hello"}}]}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]}}'
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Wrote the file, verified."}]}}'
printf '%s\n' '{"type":"result","result":"Wrote the file, verified."}'
exit 0
STUB
chmod +x "$T/claude-tools"
"$REPO_DIR/lib/job-status" new "$JOBS" archtest "leave a durable trace" ""
CLAUDE_BIN="$T/claude-tools" WANTS_FILE="$T/wants.md" \
    "$REPO_DIR/lib/job-runner" archtest "$T/work" >/dev/null 2>&1
LIVE_STREAM="$DESKCRAB_STATE_PREFIX-debug-job-archtest.log"
check "the archive exists beside the job log" [ -f "$JOBS/archtest.stream.log" ]
check "and the job log is still where it always was" [ -f "$JOBS/archtest.log" ]
check "the archive is byte-identical to the live stream" \
    cmp -s "$LIVE_STREAM" "$JOBS/archtest.stream.log"
check "and it carries the tool-call event" \
    grep -q '"type":"tool_use"' "$JOBS/archtest.stream.log"
check_eq "the sidecar names the archive" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/archtest.json" stream_archive)" \
    "$JOBS/archtest.stream.log"

echo
echo "with the /tmp copy gone, the evidence door answers from the archive:"
rm -f "$LIVE_STREAM"
out="$("$REPO_DIR/crab" job activity archtest 2>&1)"
case "$out" in *"Write — /work/target.txt"*) ok "crab job activity reads the archived trace" ;;
    *) fail "activity must answer from the archive once /tmp is gone" "$out" ;; esac
check "and the archived trace is still readable JSON events" \
    grep -q '"name":"Write"' "$JOBS/archtest.stream.log"

echo
echo "a failed run retains the trace it produced:"
cat > "$T/claude-toolfail" <<'STUB'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"make test","description":"run the suite"}}]}}'
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"The build broke."}]}}'
exit 7
STUB
chmod +x "$T/claude-toolfail"
"$REPO_DIR/lib/job-status" new "$JOBS" failarch "break with a trace" ""
CLAUDE_BIN="$T/claude-toolfail" WANTS_FILE="$T/wants.md" \
    "$REPO_DIR/lib/job-runner" failarch "$T/work" >/dev/null 2>&1
check_eq "the run is failed" \
    "$("$REPO_DIR/lib/job-status" get "$JOBS/failarch.json" state)" "failed"
rm -f "$DESKCRAB_STATE_PREFIX-debug-job-failarch.log"
check "its archive holds the tool call that ran before the break" \
    grep -q '"command":"make test"' "$JOBS/failarch.stream.log"

echo
echo "a stopped run keeps whatever trace it had produced by then:"
# The archive is fed live by the same tee as the viewer's copy, never copied
# at exit — a worker killed mid-build must still leave its opening acts.
# The stub writes its own pid: the sandbox's pkill is a deliberate no-op (a
# pattern kill escapes onto live audio), so the unit-wide TERM that systemctl
# stop would deliver is played here as two direct kills — the runner, whose
# trap defers until its foreground pipeline ends, and the stub by pid, which
# ends that pipeline. A pattern kill here would leave the stub sleeping and
# the trap waiting on it.
cat > "$T/claude-toolslow" <<STUB
#!/bin/bash
echo \$\$ > "$T/claude-toolslow.pid"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"/etc/hostname"}}]}}'
sleep 20 >/dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Never reached."}]}}'
STUB
chmod +x "$T/claude-toolslow"
"$REPO_DIR/lib/job-status" new "$JOBS" stoparch "die mid-build with a trace" ""
CLAUDE_BIN="$T/claude-toolslow" WANTS_FILE="$T/wants.md" \
    "$REPO_DIR/lib/job-runner" stoparch "$T/work" >/dev/null 2>&1 &
RUNNER=$!
seen=""
for _ in $(seq 100); do
    grep -q '"type":"tool_use"' "$JOBS/stoparch.stream.log" 2>/dev/null && { seen=1; break; }
    kill -0 "$RUNNER" 2>/dev/null || break
    sleep 0.1
done
[ -n "$seen" ] && ok "the tool event reached the archive while the builder was alive" \
    || fail "the archive must fill during the run, not at exit" \
        "$(cat "$JOBS/stoparch.stream.log" 2>/dev/null)"
kill -TERM "$RUNNER" 2>/dev/null
kill -TERM "$(cat "$T/claude-toolslow.pid" 2>/dev/null)" 2>/dev/null
wait "$RUNNER" 2>/dev/null
rm -f "$DESKCRAB_STATE_PREFIX-debug-job-stoparch.log"
check "the partial trace survives the stop and the /tmp reap" \
    grep -q '"type":"tool_use"' "$JOBS/stoparch.stream.log"
out="$(sandbox_count_in "Never reached" "$JOBS/stoparch.stream.log")"
check_eq "and nothing the builder never did appears in it" "${out:-0}" "0"

echo
echo "a sidecar written before the field still finds its archive:"
# The computed-path fallback: stream and stream_archive both absent, the file
# itself standing beside the log under the id's own name.
"$REPO_DIR/lib/job-status" new "$JOBS" oldarch "an elder sidecar" ""
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","id":"tu1","name":"Edit","input":{"file_path":"/some/old/file"}}]}}' \
    > "$JOBS/oldarch.stream.log"
out="$("$REPO_DIR/crab" job activity oldarch 2>&1)"
case "$out" in *"Edit — /some/old/file"*) ok "activity falls back to the archive's own name" ;;
    *) fail "an elder sidecar must still reach the archive beside it" "$out" ;; esac

echo
echo "the archive dies with the record, on report's keep-days sweep:"
"$REPO_DIR/lib/job-status" set "$JOBS/failarch.json" finished_epoch=1000
"$REPO_DIR/lib/job-status" report "$JOBS" 6 0 >/dev/null 2>&1
check "the swept record's sidecar is gone" [ ! -e "$JOBS/failarch.json" ]
check "its log is gone with it" [ ! -e "$JOBS/failarch.log" ]
check "and so is its archived trace — with the record, never before it" \
    [ ! -e "$JOBS/failarch.stream.log" ]
