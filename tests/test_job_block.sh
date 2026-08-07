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
run() { # <shell body>
    JOBS_DIR="$T/jobs" DESKCRAB_STATE_PREFIX="$T/state" \
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

# -f must reach dispatch. It is allowed to fail there (no systemd in a test
# shell, stub claude) — what matters is that it got past the preflight.
out="$(run 'job_block_record "out of usage credits"; job_start -f "build a thing" 2>&1 | head -n1')"
case "$out" in *"never began"*) fail "-f must bypass the preflight" "$out" ;;
    *) ok "-f bypasses the preflight" ;; esac

# -C must still work, before and after -f, now that the flags are a loop.
out="$(run 'job_block_record "x"; job_start -C /tmp -f "w" 2>&1 | head -n1')"
case "$out" in *"never began"*) fail "-C -f should reach dispatch" "$out" ;;
    *) ok "-C composes with -f" ;; esac

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

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
