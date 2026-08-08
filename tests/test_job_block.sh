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
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# No case in this file wants a real builder, so the guard belongs on every case
# rather than on the two lines that happen to reach dispatch today — a preflight
# that regresses must fail the assertion, not start a session on my account.
run() { # <shell body>
    JOBS_DIR="$T/jobs" DESKCRAB_NO_DISPATCH=1 sandbox_bash "$*" 2>&1
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
    # JOBS_BLOCKED_FILE is named explicitly because the guard case below derives
    # it from whichever jobs directory it is handed, and a refusal recorded by a
    # stub builder must never stamp a block marker anyone else reads: on
    # 2026-08-07 a builder running this suite held every live dispatch for 30 min
    # with "out of usage credits" that no account had actually said. Everything
    # else — the config, the state prefix, the account default, the journal — is
    # the sandbox's, which is the point of there being one.
    JOBS_DIR="$1" WANTS_FILE="$T/wants.md" CLAUDE_BIN="$T/claude-stub" \
        JOBS_BLOCKED_FILE="$T/blocked-marker" \
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

# ...and the guard must not silence the instance's OWN jobs directory. Same
# runner, same fake crab, but JOBS_DIR is now the one this instance calls its
# own — the guard compares against ${XDG_DATA_HOME}/deskcrab/jobs — so the wake
# attempt has to happen. Until 2026-08-07 this case copied its sidecar into the
# REAL jobs directory and ran the stub builder against it, which is how a
# refusal no account had ever said came to stamp the live block marker.
LIVE="$XDG_DATA_HOME/deskcrab/jobs"
mkdir -p "$LIVE"
cp "$T/jobs2/jobtest.json" "$LIVE/deskcrab-selftest-jobtest.json"
rm -f "$T/wakes"
run_runner "$LIVE" deskcrab-selftest-jobtest
grep -q "^WAKE: wake-at --by job-runner 5s event" "$T/wakes" 2>/dev/null \
    && ok "the instance's own jobs directory still fires its wake" \
    || fail "the guard must not silence a real job" "$(cat "$T/wakes" 2>/dev/null)"
rm -f "$LIVE"/deskcrab-selftest-jobtest.*

echo
echo "detach_turn_child — the login goes with the child, but only when there is one:"
# The promise auditor and the memory judge invoke the CLI themselves, out of
# band, in a transient unit of their own. A user unit gets a BARE environment,
# so the one variable that says which account to use was the one variable not
# forwarded: both always fired at whatever login the manager happened to hold,
# and failed silently whenever that was the dry one.
#
# And it is forwarded ONLY when it is set. Passing it empty is not the same as
# not passing it: a unit running with CLAUDE_CONFIG_DIR defined-but-blank makes
# the CLI look for a login in "" and die in about a second — the mistake that
# killed every dispatched job for a day.
#
# The systemd-run stub records the argv and refuses the run (no --on-*), which
# is the shipped fallback path: the caller then takes its own setsid, so the
# child stays inside this sandbox. /bin/true is that child.
count_arg() { local n; n="$(grep -c -- "$1" "$SANDBOX_SYSTEMD_LOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }

: > "$SANDBOX_SYSTEMD_LOG"
run 'detach_turn_child probe /bin/true' >/dev/null 2>&1
check_eq "one unit was asked for" "$(count_arg 'deskcrab-probe-')" "1"
check_eq "with CLAUDE_CONFIG_DIR unset, the variable is not passed AT ALL" \
    "$(count_arg 'CLAUDE_CONFIG_DIR')" "0"
argv="$(grep -m1 'deskcrab-probe-' "$SANDBOX_SYSTEMD_LOG")"
case "$argv" in
    *"--collect"*) ok "the child's unit is collected on exit, like a job's" ;;
    *) fail "a detached child's unit carries --collect" "$argv" ;;
esac
for redirect in DESKCRAB_CONF DESKCRAB_STATE_PREFIX DESKCRAB_MEMORY_DIR CLAUDE_BIN; do
    case "$argv" in
        *"--setenv=$redirect="*) ok "$redirect travels into the child" ;;
        *) fail "every state redirect must reach a detached child" "$redirect: $argv" ;;
    esac
done

: > "$SANDBOX_SYSTEMD_LOG"
CLAUDE_CONFIG_DIR="$T/fallback-two" run 'detach_turn_child probe /bin/true' >/dev/null 2>&1
check_eq "with a login in hand, it is forwarded exactly once" \
    "$(count_arg "--setenv=CLAUDE_CONFIG_DIR=$T/fallback-two")" "1"

# ...and an EMPTY one is not a login. This is the case that killed the day: the
# variable present and blank is worse than absent.
: > "$SANDBOX_SYSTEMD_LOG"
CLAUDE_CONFIG_DIR="" run 'detach_turn_child probe /bin/true' >/dev/null 2>&1
check_eq "an empty login is passed no more than a missing one" \
    "$(count_arg 'CLAUDE_CONFIG_DIR')" "0"

echo
echo "a refusal is judged from the CLI's own events, never from the stream's bytes:"
# specs/jobs.md rule 15's sub-bullets. A stream log carries every byte of every
# tool result, so a signature match over the raw file says "blocked" for a
# builder that merely READ a file containing the wording — and lib/common.sh,
# which holds the signature's own patterns, is exactly such a file. The cost of
# the false positive is not local: it rotates the durable account default and
# holds every further dispatch for the retry window.
S="$T/stream.jsonl"
refusal() { run 'claude_stream_refusal "'"$S"'" "'"${2:-0}"'" || echo NONE'; }

# The builder opened a file whose text contains the wording, then died without
# ever producing a reply. Nothing the CLI said refused anything.
python3 - "$S" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "user", "message": {"content": [
        {"type": "tool_result",
         "content": "CLAUDE_LIMIT_RE=\"out of usage credits|usage limit reached\""}]}}) + "\n")
    f.write(json.dumps({"type": "result", "is_error": True, "result": "exit 1"}) + "\n")
PYEOF
check "the raw bytes DO carry the wording — that is the trap" \
    grep -qi "out of usage credits" "$S"
check_eq "reading a file that contains the wording is not a refusal" "$(refusal)" "NONE"

# The CLI's own result event. No model output anywhere: nothing was attempted.
python3 - "$S" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "result", "is_error": True,
                        "result": "You're out of usage credits. Run /usage-credits"}) + "\n")
PYEOF
check_eq "the CLI's own result event is" "$(refusal)" "out of usage credits"

# A synthetic assistant message is the CLI speaking, not the model.
python3 - "$S" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "assistant", "is_api_error_message": True,
                        "message": {"model": "<synthetic>", "content": [
                            {"type": "text", "text": "session limit reached for this account"}]}}) + "\n")
PYEOF
check_eq "and so is a synthetic api-error message" "$(refusal)" "session limit reached"

# A run that PRODUCED something is a run that happened, whatever words went
# through it. Rule 15: a real failure must never wear the blocked signature.
python3 - "$S" <<'PYEOF'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"model": "fable", "content": [
        {"type": "text", "text": "I hit a usage limit in the docs I was reading."}]}}) + "\n")
    f.write(json.dumps({"type": "result", "is_error": True,
                        "result": "usage limit reached"}) + "\n")
PYEOF
check_eq "a run with genuine model output is never a refusal" "$(refusal)" "NONE"

# The offset is what makes an attempt answerable on its own bytes (rule 14).
python3 - "$S" <<'PYEOF'
import json, sys
first = json.dumps({"type": "result", "is_error": True,
                    "result": "usage limit reached"}) + "\n"
with open(sys.argv[1], "w") as f:
    f.write(first)
    f.write(json.dumps({"type": "result", "is_error": True,
                        "result": "getaddrinfo ENOTFOUND api.anthropic.com"}) + "\n")
with open(sys.argv[1] + ".off", "w") as f:
    f.write(str(len(first.encode())))
PYEOF
OFF="$(cat "$S.off")"
check_eq "an earlier attempt's refusal is not the later attempt's outcome" \
    "$(run 'claude_stream_refusal "'"$S"'" "'"$OFF"'" || echo NONE')" "NONE"
check_eq "and read from the top, the chain has still refused" \
    "$(run 'claude_stream_refusal "'"$S"'" 0 || echo NONE')" "usage limit reached"

echo
echo "a running builder's stream survives the turn-side sweep:"
# specs/jobs.md rule 22's sub-bullet. claim_debuglog reaps session logs that
# have been quiet for three hours, which is true of a turn and false of a
# builder: a job can sit inside one compile for longer than that without
# writing a byte. Unlinking its live stream empties the attempt slice, blinds
# the judgement above, and leaves a blocked run with nothing to record.
P="$DESKCRAB_STATE_PREFIX"
: > "$P-debug-job-lives.log"
: > "$P-debug-someturn.log"
touch -d '5 hours ago' "$P-debug-job-lives.log" "$P-debug-someturn.log"
run 'claim_debuglog' >/dev/null 2>&1
check "a quiet job stream is left alone" [ -f "$P-debug-job-lives.log" ]
check "a quiet turn stream is still reaped" [ ! -f "$P-debug-someturn.log" ]
