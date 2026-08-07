#!/bin/bash
# Tests for the "a job that never began" path — job_output_blocked,
# job_block_record/job_block_active, the job_start preflight, and the report
# rendering. Run: bash tests/test_job_block.sh
#
# The gap these were written for: on 2026-08-07 four builders in twenty-five
# minutes each exited in under ten seconds having written nothing but "You're
# out of usage credits". Every one was recorded as "failed (exit 1)" and every
# one fired a wake saying "read the log and verify its claims" — for a log with
# no claims in it. A build that never started is its own outcome, and it must
# hold off the next dispatch instead of inviting it.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-jobblock.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — got [$2]"; }

# Every case runs in a scratch instance: its own JOBS_DIR and state prefix, so
# nothing here can touch the live jobs directory or the live block marker.
# No case in this file wants a real builder, so the guard belongs here rather
# than on the two lines that happen to reach dispatch today — a preflight that
# regresses must fail the assertion, not start a session on my account.
run() { # <shell body>
    JOBS_DIR="$T/jobs" DESKCRAB_STATE_PREFIX="$T/state" DESKCRAB_NO_DISPATCH=1 \
        bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$REPO_DIR" "$*" 2>&1
}

echo "job_output_blocked — the CLI's own refusals, and nothing else:"
for line in \
    "You're out of usage credits. Run /usage-credits to keep using Fable 5" \
    "Error: usage limit reached for this account" \
    "your credit balance is too low to proceed" \
    "insufficient credits remaining"
do
    printf '%s\n' "$line" > "$T/log"
    out="$(run 'job_output_blocked "'"$T"'/log" && echo BLOCKED || echo no')"
    [ "$out" = BLOCKED ] && ok "matches: ${line:0:40}" || fail "should match: ${line:0:40}" "$out"
done

# A real build failure must stay a failure — misreading one as "never ran"
# would hide a broken builder behind a cheerful "nothing was attempted".
for line in \
    "FAIL: 3 tests failed" \
    "fatal: not a git repository" \
    "I could not verify the change; the credits for this design go to the earlier session"
do
    printf '%s\n' "$line" > "$T/log"
    out="$(run 'job_output_blocked "'"$T"'/log" && echo BLOCKED || echo no')"
    [ "$out" = no ] && ok "not a block: ${line:0:40}" || fail "must NOT match: ${line:0:40}" "$out"
done

echo "job_block_active — fresh blocks hold, stale ones expire on their own:"
out="$(run 'job_block_record "out of usage credits"; job_block_active | cut -f2')"
[ "$out" = "out of usage credits" ] && ok "a just-written block is active" || fail "fresh block should be active" "$out"

out="$(run 'job_block_record "out of usage credits"; JOB_BLOCK_RETRY=0 job_block_active && echo ACTIVE || echo expired')"
[ "$out" = expired ] && ok "block older than the retry window is gone" || fail "stale block should expire" "$out"

out="$(run 'rm -f "$JOBS_BLOCKED_FILE"; job_block_active && echo ACTIVE || echo none')"
[ "$out" = none ] && ok "no marker, no block" || fail "absent marker should not block" "$out"

# Garbage in the marker must not wedge dispatch shut forever.
out="$(run 'mkdir -p "$JOBS_DIR"; printf "not-a-number\tjunk\n" > "$JOBS_BLOCKED_FILE"; job_block_active && echo ACTIVE || echo none')"
[ "$out" = none ] && ok "unparseable marker does not block" || fail "junk marker should not block" "$out"

echo "job_start preflight — held while blocked, forceable, free once clear:"
out="$(run 'job_block_record "out of usage credits"; job_start "build a thing" >/dev/null 2>&1 && echo DISPATCHED || echo held')"
[ "$out" = held ] && ok "dispatch is refused while a block is fresh" || fail "should refuse" "$out"

out="$(run 'job_block_record "out of usage credits"; job_start "build a thing" 2>&1 | head -n1')"
case "$out" in *"never began"*) ok "refusal says the last job never began" ;;
    *) fail "refusal must explain itself" "$out" ;; esac

# -f must reach dispatch — and reaching dispatch is ALL these two may prove.
# The first version of them let job_start run to the end, and on a box that has
# a systemd user manager and a real claude (which is to say: this one) that
# started two live builders on my own account. DESKCRAB_NO_DISPATCH stops at
# the line the assertion is actually about.
out="$(run 'job_block_record "out of usage credits"; job_start -f "build a thing" 2>&1 | head -n1')"
case "$out" in *"Would dispatch"*) ok "-f bypasses the preflight" ;;
    *) fail "-f must bypass the preflight" "$out" ;; esac

# -C must still work, before and after -f, now that the flags are a loop.
out="$(run 'job_block_record "x"; job_start -C /tmp -f "w" 2>&1 | head -n1')"
case "$out" in *"Would dispatch (DESKCRAB_NO_DISPATCH set) in /tmp:"*) ok "-C composes with -f" ;;
    *) fail "-C -f should reach dispatch, in the given workdir" "$out" ;; esac

echo "report — a blocked job does not read as a failed build:"
mkdir -p "$T/rep"
python3 - "$T/rep/j.json" <<'PY'
import json, sys, time
now = int(time.time())
json.dump({"id": "20260807-000000-1", "description": "widen attribution",
           "started": "2026-08-07 00:00", "started_epoch": now - 10, "unit": "",
           "state": "blocked", "exit": 1, "finished": "2026-08-07 00:00",
           "finished_epoch": now}, open(sys.argv[1], "w"))
PY
out="$("$REPO_DIR/lib/job-status" report "$T/rep" 6 14 2>&1)"
case "$out" in *"blocked (never ran)"*) ok "report renders 'blocked (never ran)'" ;;
    *) fail "report should mark it blocked" "$out" ;; esac
case "$out" in *"failed"*) fail "report must not call it failed" "$out" ;;
    *) ok "report never says failed for a blocked job" ;; esac

echo "the event wake — a scratch runner must not reach the live me:"
# 2026-08-07: a runner called "testid", task "do a thing", fired a real event
# wake at me and left no log, no sidecar, nothing anywhere to trace it by. Its
# JOBS_DIR was scratch, so the isolation held for everything EXCEPT the one
# channel that interrupts a person. This runs job-runner end to end against a
# fake claude and a fake crab, in a scratch tree, so the wake attempt is
# observable without anything actually being woken.
mkdir -p "$T/repo/lib" "$T/jobs2"
cp "$REPO_DIR/lib/job-runner" "$T/repo/lib/job-runner"   # copied, not linked:
ln -sf "$REPO_DIR/lib/common.sh" "$T/repo/lib/common.sh" # readlink -f would
chmod +x "$T/repo/lib/job-runner"                        # walk back to the real
printf '#!/bin/bash\necho "WAKE: $*" >> "%s/wakes"\n' "$T" > "$T/repo/crab"
chmod +x "$T/repo/crab"                                  # repo and its real crab
printf '#!/bin/bash\necho DESKCRAB_STUB_BUILDER\necho "You'"'"'re out of usage credits."\nexit 1\n' > "$T/claude-stub"
chmod +x "$T/claude-stub"

# DAY_JOURNAL_DIR is isolated too: the first version of this test wrote two
# "do a thing" job entries straight into my real day journal, where sleep would
# have read them at 03:10 as work I had actually done.
run_runner() { # <jobs-dir> <id>  -> emits nothing; side effects land in $T/wakes
    JOBS_DIR="$1" DESKCRAB_STATE_PREFIX="$T/state" WANTS_FILE="$T/wants.md" \
        DAY_JOURNAL_DIR="$T/journal" CLAUDE_BIN="$T/claude-stub" \
        "$T/repo/lib/job-runner" "$2" "$T" >/dev/null 2>&1
}
"$REPO_DIR/lib/job-status" new "$T/jobs2/jobtest.json" jobtest "do a thing" >/dev/null 2>&1 || \
    python3 - "$T/jobs2/jobtest.json" <<'PY'
import json, sys, time
json.dump({"id": "jobtest", "description": "do a thing", "started_epoch": int(time.time()),
           "state": "running", "unit": ""}, open(sys.argv[1], "w"))
PY
rm -f "$T/wakes"
run_runner "$T/jobs2" jobtest
# First, and most important: prove no real builder ran. The config sets
# CLAUDE_BIN unconditionally, so before 2026-08-07 sourcing it silently ate the
# stub and every run of this file started a live session on my own account.
case "$(cat "$T/jobs2/jobtest.log" 2>/dev/null)" in
    *DESKCRAB_STUB_BUILDER*) ok "the stub builder ran — CLAUDE_BIN survives the config" ;;
    *) fail "a test must never start a real builder" "$(head -n1 "$T/jobs2/jobtest.log" 2>/dev/null)" ;;
esac
[ ! -s "$T/wakes" ] && ok "scratch JOBS_DIR fires no event wake" \
    || fail "scratch run must not wake the live assistant" "$(cat "$T/wakes")"
case "$(cat "$T/jobs2/jobtest.log" 2>/dev/null)" in
    *"event wake suppressed"*) ok "the suppression is recorded in the job log" ;;
    *) fail "suppressing a wake must leave a trace" "$(tail -n1 "$T/jobs2/jobtest.log" 2>/dev/null)" ;;
esac

# ...and the guard must not silence the live path. Same runner, same fake crab,
# but JOBS_DIR is the real one — so the wake attempt has to happen. Nothing is
# written to the live directory: only the sidecar this test made is read.
LIVE="${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/jobs"
if [ -d "$LIVE" ]; then
    cp "$T/jobs2/jobtest.json" "$LIVE/deskcrab-selftest-jobtest.json"
    rm -f "$T/wakes"
    run_runner "$LIVE" deskcrab-selftest-jobtest
    grep -q "^WAKE: wake-at 5s event" "$T/wakes" 2>/dev/null \
        && ok "the live jobs directory still fires its wake" \
        || fail "the guard must not silence a real job" "$(cat "$T/wakes" 2>/dev/null)"
    rm -f "$LIVE"/deskcrab-selftest-jobtest.*
else
    echo "  skip: no live jobs directory on this box"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
