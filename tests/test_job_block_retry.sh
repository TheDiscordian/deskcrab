#!/bin/bash
# Tests for the automatic retry of a blocked job — specs/jobs.md rules 18a-18f.
# Run: bash tests/test_job_block_retry.sh
#
# The gap these were written for: a job whose whole account chain refused
# landed blocked, booked a wake saying the task was still undone, held further
# dispatches for JOB_BLOCK_RETRY — and then nothing re-sent the brief. The
# hold expired on its own and the sidecar sat waiting on the user happening to
# notice. Now lib/job-runner arms one transient timer at block time and
# lib/job-block-retry fires the recorded brief once when the hold has expired.
# One retry per brief, never a loop; never for a job that merely failed; never
# from a scratch jobs directory; abandoned rather than re-fired when stale.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# What the guard calls "the instance's own" jobs directory. Inside the sandbox
# XDG_DATA_HOME is scratch, so this path is scratch too — the same trick
# test_job_block.sh uses to walk the live-or-not comparison's live branch
# without going anywhere near the real instance.
LIVE="$XDG_DATA_HOME/deskcrab/jobs"
mkdir -p "$LIVE" "$T/scratchjobs"

# Run the real fire side with dispatch stopped at the observable line: past
# job_start's DESKCRAB_NO_DISPATCH check is a real unit running a real claude
# on a real account, which no case in this file may ever reach. Extra k=v
# pairs land after the fixed ones, so a case can override any of them.
fire() { # <jobs-dir> <id> [k=v ...]
    local jd="$1" id="$2"; shift 2
    env JOBS_DIR="$jd" DESKCRAB_NO_DISPATCH=1 JOBS_BLOCKED_FILE="$T/no-marker" \
        "$@" "$REPO_DIR/lib/job-block-retry" "$id" 2>&1
}

mk() { # <dir> <id> <state> [job-status set pairs...]
    local dir="$1" id="$2" state="$3"; shift 3
    "$REPO_DIR/lib/job-status" new "$dir" "$id" "rebuild the widget" "" "/tmp/rproj"
    "$REPO_DIR/lib/job-status" set "$dir/$id.json" state="$state" exit=1 "$@"
    : > "$dir/$id.log"
}
getf() { "$REPO_DIR/lib/job-status" get "$1" "$2"; } # <sidecar> <field>

echo "the fire side — a scratch jobs directory never fires (rule 18e):"
mk "$T/scratchjobs" scr1 blocked
fire "$T/scratchjobs" scr1 >/dev/null
check "the refusal is on the job's own log" \
    grep -q "scratch jobs directory" "$T/scratchjobs/scr1.log"
check_eq "no dispatch was reached" \
    "$(sandbox_count_in "Would dispatch" "$T/scratchjobs/scr1.log")" "0"
check_eq "and the shot is not spent by a refusal to aim" \
    "$(getf "$T/scratchjobs/scr1.json" retry)" ""

echo "the fire side — a blocked brief re-dispatches from its sidecar (18a):"
mk "$LIVE" hap1 blocked
fire "$LIVE" hap1 >/dev/null
check "the recorded brief reaches dispatch, in the recorded workdir, naming its origin" \
    grep -q "Would dispatch (DESKCRAB_NO_DISPATCH set) in /tmp/rproj: rebuild the widget (retry of hap1)" \
    "$LIVE/hap1.log"
check_eq "the origin's sidecar records the spent shot" \
    "$(getf "$LIVE/hap1.json" retry)" "fired"

echo "the fire side — exactly once, never a loop (18b):"
fire "$LIVE" hap1 >/dev/null
check "a second firing refuses on the sidecar's own record" \
    grep -q "retry already spent" "$LIVE/hap1.log"
check_eq "the brief went out once and only once" \
    "$(sandbox_count_in "Would dispatch" "$LIVE/hap1.log")" "1"

mk "$LIVE" rt1 blocked retry_of=someorigin
fire "$LIVE" rt1 >/dev/null
check "a job that is itself the retry is never re-fired" \
    grep -q "itself the one retry of someorigin" "$LIVE/rt1.log"
check_eq "so a retry that blocks again ends the chain" \
    "$(sandbox_count_in "Would dispatch" "$LIVE/rt1.log")" "0"

echo "the fire side — a failed job is not a blocked one (18c):"
mk "$LIVE" fl1 failed
fire "$LIVE" fl1 >/dev/null
check "the refusal names the state it found" \
    grep -q "state is 'failed', not blocked" "$LIVE/fl1.log"
check_eq "a job that ran is never re-dispatched" \
    "$(sandbox_count_in "Would dispatch" "$LIVE/fl1.log")" "0"
check_eq "and its record is untouched" "$(getf "$LIVE/fl1.json" retry)" ""

echo "the fire side — a stale brief is abandoned, on the record (18d):"
mk "$LIVE" old1 blocked started_epoch=$(( $(date +%s) - 3600 ))
fire "$LIVE" old1 JOB_RETRY_MAX_AGE=600 >/dev/null
check "the abandonment is in the job's log" grep -q "abandoned:" "$LIVE/old1.log"
check_eq "and on the sidecar, so nothing re-arms it" \
    "$(getf "$LIVE/old1.json" retry)" "abandoned"
check_eq "nothing was dispatched" \
    "$(sandbox_count_in "Would dispatch" "$LIVE/old1.log")" "0"

echo "the fire side — the sidecar is the authority, like requeue (7a):"
"$REPO_DIR/lib/job-status" new "$LIVE" nul1 "null" "" "/tmp/rproj"
"$REPO_DIR/lib/job-status" set "$LIVE/nul1.json" state=blocked exit=1
: > "$LIVE/nul1.log"
fire "$LIVE" nul1 >/dev/null
check "a substitution artifact is refused, never dispatched" \
    grep -q "not a brief" "$LIVE/nul1.log"
check_eq "no dispatch for 'null'" \
    "$(sandbox_count_in "Would dispatch" "$LIVE/nul1.log")" "0"

"$REPO_DIR/lib/job-status" new "$LIVE" now1 "a real brief" ""
"$REPO_DIR/lib/job-status" set "$LIVE/now1.json" state=blocked exit=1
: > "$LIVE/now1.log"
fire "$LIVE" now1 >/dev/null
check "a sidecar with no workdir refuses to guess one" \
    grep -q "no workdir on record" "$LIVE/now1.log"
check_eq "no dispatch without a directory" \
    "$(sandbox_count_in "Would dispatch" "$LIVE/now1.log")" "0"

echo "the fire side — a fresh block from another job forfeits the shot (18b):"
mk "$LIVE" held1 blocked
printf '%s\tout of usage credits\n' "$(date +%s)" > "$T/fresh-marker"
fire "$LIVE" held1 JOBS_BLOCKED_FILE="$T/fresh-marker" >/dev/null
check "the held preflight's refusal lands in the log" \
    grep -q "Not dispatched — the last job never began" "$LIVE/held1.log"
check_eq "the shot is spent, so nothing volleys into the same wall" \
    "$(getf "$LIVE/held1.json" retry)" "fired"
fire "$LIVE" held1 >/dev/null
check "and a later firing stays refused" \
    grep -q "retry already spent" "$LIVE/held1.log"

echo
echo "the arming side — job-runner books the one timer at block time (18a):"
# The same end-to-end shape as test_job_block.sh's wake cases: the runner is
# copied (readlink -f on a symlink would walk back to the real repo and its
# real crab), common.sh is linked, claude is a stub, and JOBS_BLOCKED_FILE is
# named explicitly so a stub's refusal never stamps a marker anyone else reads.
mkdir -p "$T/repo/lib"
cp "$REPO_DIR/lib/job-runner" "$T/repo/lib/job-runner"
ln -sf "$REPO_DIR/lib/common.sh" "$T/repo/lib/common.sh"
chmod +x "$T/repo/lib/job-runner"
printf '#!/bin/bash\necho "WAKE: $*" >> "%s/wakes"\n' "$T" > "$T/repo/crab"
chmod +x "$T/repo/crab"
printf '#!/bin/bash\necho "You'"'"'re out of usage credits."\nexit 1\n' > "$T/claude-refuse"
chmod +x "$T/claude-refuse"
cat > "$T/claude-fail" <<'EOF'
#!/bin/bash
echo '{"type":"assistant","message":{"model":"fable","content":[{"type":"text","text":"the build broke"}]}}'
exit 1
EOF
chmod +x "$T/claude-fail"

run_runner() { # <jobs-dir> <id> <claude-stub>
    JOBS_DIR="$1" WANTS_FILE="$T/wants.md" CLAUDE_BIN="$3" \
        JOBS_BLOCKED_FILE="$T/blocked-marker" \
        "$T/repo/lib/job-runner" "$2" "$T" >/dev/null 2>&1
    rm -f "$T/blocked-marker"
}

"$REPO_DIR/lib/job-status" new "$LIVE" arm1 "do a thing" "" "/tmp/rproj"
: > "$SANDBOX_SYSTEMD_LOG"
run_runner "$LIVE" arm1 "$T/claude-refuse"
check_eq "the run landed blocked (the premise)" \
    "$(getf "$LIVE/arm1.json" state)" "blocked"
argv="$(grep -m1 'deskcrab-job-retry-arm1' "$SANDBOX_SYSTEMD_LOG" 2>/dev/null)"
case "$argv" in
    *"--on-active="*) ok "one transient timer is armed for the retry" ;;
    *) fail "a blocked live run must arm the retry timer" "$argv" ;;
esac
case "$argv" in
    *job-block-retry*arm1*) ok "and it fires the fire side with the job's id" ;;
    *) fail "the timer must run job-block-retry <id>" "$argv" ;;
esac
case "$argv" in
    *CLAUDE_CONFIG_DIR*) fail "the refused login must NOT ride into the timer" "$argv" ;;
    *) ok "no login is pinned — the fire side asks the chain at fire time" ;;
esac
check "the arming is on the job's own log" \
    grep -q "re-dispatches itself once" "$LIVE/arm1.log"

echo "the arming side — a failed build arms nothing (18c):"
"$REPO_DIR/lib/job-status" new "$LIVE" fl2 "do a thing" "" "/tmp/rproj"
: > "$SANDBOX_SYSTEMD_LOG"
run_runner "$LIVE" fl2 "$T/claude-fail"
check_eq "the run landed failed (the premise)" \
    "$(getf "$LIVE/fl2.json" state)" "failed"
check_eq "no retry timer for a build that ran" \
    "$(sandbox_count_in "deskcrab-job-retry-fl2" "$SANDBOX_SYSTEMD_LOG")" "0"

echo "the arming side — a scratch run arms nothing (18e):"
"$REPO_DIR/lib/job-status" new "$T/scratchjobs" arm3 "do a thing" "" "/tmp/rproj"
: > "$SANDBOX_SYSTEMD_LOG"
run_runner "$T/scratchjobs" arm3 "$T/claude-refuse"
check_eq "no timer from a scratch jobs directory" \
    "$(sandbox_count_in "deskcrab-job-retry-arm3" "$SANDBOX_SYSTEMD_LOG")" "0"
check "and the suppression leaves a trace" \
    grep -q "block retry not armed" "$T/scratchjobs/arm3.log"

echo "the arming side — a retry that blocks is announced and left (18b):"
"$REPO_DIR/lib/job-status" new "$LIVE" arm4 "do a thing" "" "/tmp/rproj"
"$REPO_DIR/lib/job-status" set "$LIVE/arm4.json" retry_of=arm1
: > "$SANDBOX_SYSTEMD_LOG"
run_runner "$LIVE" arm4 "$T/claude-refuse"
check_eq "the retry itself landed blocked (the premise)" \
    "$(getf "$LIVE/arm4.json" state)" "blocked"
check_eq "no second timer — the chain ends here" \
    "$(sandbox_count_in "deskcrab-job-retry-arm4" "$SANDBOX_SYSTEMD_LOG")" "0"
check "and the log says why" grep -q "not arming another" "$LIVE/arm4.log"

echo
echo "the stamps — job_start -O writes both halves of the lineage (18b, 18f):"
# The one stanza that goes PAST the preflight: the stamps are written between
# the sidecar's creation and the unit's start, so DESKCRAB_NO_DISPATCH would
# stop short of them. The shipped systemd-run stub REFUSES a plain run, which
# makes job_start setsid a real runner as its fallback — so for this stanza it
# is swapped for one that records and ACCEPTS: job_start believes the unit
# started, writes its stamps, and nothing is ever executed.
sandbox_stub systemd-run <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SANDBOX_SYSTEMD_LOG:-/dev/null}"
exit 0
EOF
mk "$T/jobs-stamp" orig9 blocked
out="$(JOBS_DIR="$T/jobs-stamp" JOBS_BLOCKED_FILE="$T/no-marker" \
    sandbox_bash 'job_start -C /tmp/rproj -O orig9 "second attempt at the widget"' 2>&1)"
newid="$(getf "$T/jobs-stamp/orig9.json" retry)"
case "$newid" in
    ''|fired|abandoned) fail "the origin must record the new job's id" "$newid ($out)" ;;
    *) ok "the origin's sidecar records the id that spent its retry" ;;
esac
if [ -e "$T/jobs-stamp/$newid.json" ]; then
    check_eq "the new sidecar names the job it came from" \
        "$(getf "$T/jobs-stamp/$newid.json" retry_of)" "orig9"
else
    fail "the new job's sidecar must exist" "$newid"
fi

echo "the report — a retry is its own entry naming its origin (18f):"
"$REPO_DIR/lib/job-status" set "$T/jobs-stamp/$newid.json" \
    state=finished exit=0 finished=now
out="$("$REPO_DIR/lib/job-status" report "$T/jobs-stamp" 6 14 2>&1)"
case "$out" in
    *"$newid (retry of orig9)"*) ok "crab jobs names the lineage" ;;
    *) fail "the report must say 'retry of orig9'" "$out" ;;
esac
