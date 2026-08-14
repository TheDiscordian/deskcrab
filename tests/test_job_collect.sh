#!/bin/bash
# Collection — specs/jobs.md rules 38-40. After a run, the sidecar gains the
# branch, the commits since dispatch, the unpushed and dirty counts, and the
# report's test tally; a finished job moves to `collected`; and the one gate
# of rule 39 holds: a run that exited clean whose report ENDS ON AN INTENTION
# — standing by, holding the commit until later — is FAILED, never finished,
# because a promise made by a process that stops existing is a task that did
# not happen. Two builders died exactly that way, one over an empty diff
# (2026-08-08 19:45), one over real uncommitted work (2026-08-11 01:18).
# Run: bash tests/test_job_collect.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JS="$REPO/lib/job-status"
JC="$REPO/lib/job-collect"
J="$T/jobs"
mkdir -p "$J"

# A fixture repository: one commit before dispatch, one after, one dirty file.
WD="$T/fixture-repo"
mkdir -p "$WD"
git -C "$WD" init -q -b builder-branch
git -C "$WD" config user.email test@sandbox
git -C "$WD" config user.name sandbox
echo seed > "$WD/seed.txt"
git -C "$WD" add -- seed.txt
git -C "$WD" commit -qm "the seed, before any job"
sleep 1

mkjob() { # <id> <state> [exit] — a sidecar dispatched NOW in the fixture repo
    "$JS" new "$J" "$1" "a build in the fixture repo" "" "$WD" dispatched
    "$JS" set "$J/$1.json" state=running
    "$JS" set "$J/$1.json" state="$2" ${3:+exit=$3} finished=now
}

echo "a working report collects — the facts land on the sidecar (rule 38):"
mkjob ok1 finished 0
sleep 1
echo built > "$WD/built.txt"
git -C "$WD" add -- built.txt
git -C "$WD" commit -qm "the builder's own commit"
echo scratch > "$WD/uncommitted.txt"
printf 'Built the widget.\nRan the suite: 12 passed, 0 failed.\nCommitted on builder-branch; done.\n' > "$J/ok1.log"
state="$("$JC" run "$J" ok1 2>"$T/verdict")"
check_eq "the final state is collected" "$state" "collected"
check_eq "and the sidecar agrees" "$("$JS" get "$J/ok1.json" state)" "collected"
check_eq "the branch is recorded" "$("$JS" get "$J/ok1.json" branch)" "builder-branch"
commits="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("commits",[])))' "$J/ok1.json")"
check "the builder's commit is on the record" contains "$commits" "the builder's own commit"
check "unpushed commits are counted" [ "$("$JS" get "$J/ok1.json" unpushed)" -ge 1 ]
check "the dirty file is counted" [ "$("$JS" get "$J/ok1.json" dirty)" -ge 1 ]
check_eq "the report's test tally is scraped" \
    "$("$JS" get "$J/ok1.json" tests)" "12 passed, 0 failed"
check "the verdict line says collected" \
    contains "$(cat "$T/verdict")" "collected:"

echo
echo "re-collection is idempotent — commits never double:"
"$JC" run "$J" ok1 >/dev/null 2>&1
n="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])).get("commits",[]); print(len(c))' "$J/ok1.json")"
first="$n"
"$JC" run "$J" ok1 >/dev/null 2>&1
n="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])).get("commits",[]); print(len(c))' "$J/ok1.json")"
check_eq "two runs, one list" "$n" "$first"

echo
echo "a clean exit that ends on an intention is FAILED (rule 39):"
mkjob w1 finished 0
printf 'Surveyed the tree. Another session holds the files.\nStanding by for the monitor to report the other jobs done.\n' > "$J/w1.log"
state="$("$JC" run "$J" w1 2>"$T/verdict")"
check_eq "died waiting is failed, never finished" "$state" "failed"
check_eq "on the sidecar too" "$("$JS" get "$J/w1.json" state)" "failed"
v="$("$JS" get "$J/w1.json" collection)"
check "the verdict names the waiting" contains "$v" "died waiting"
check "and quotes the intention" contains "$v" "Standing by for the monitor"

echo
echo "…including over real work — the work is recorded, the claim refused:"
mkjob w2 finished 0
sleep 1
echo more > "$WD/more.txt"
git -C "$WD" add -- more.txt
git -C "$WD" commit -qm "real work beside the wait"
printf 'All edits are on disk and the staged suite is green.\nHolding the commit until the 01:30 session reset, then I will push.\n' > "$J/w2.log"
state="$("$JC" run "$J" w2 2>/dev/null)"
check_eq "still failed — a promise outliving its process" "$state" "failed"
commits="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("commits",[])))' "$J/w2.json")"
check "the real work is still on the record" contains "$commits" "real work beside the wait"

echo
echo "a wait narrated mid-report is not a wait died on:"
mkjob mid1 finished 0
printf 'I waited for the compile to finish, then ran the suite.\n9 passed, 0 failed. Committed and verified; nothing is left open.\n' > "$J/mid1.log"
state="$("$JC" run "$J" mid1 2>/dev/null)"
check_eq "a conclusive report collects" "$state" "collected"

echo
echo "any other state keeps itself and gains the facts (rule 40):"
mkjob f1 failed 1
printf 'The build broke: 3 passed, 2 failed.\n' > "$J/f1.log"
state="$("$JC" run "$J" f1 2>/dev/null)"
check_eq "failed stays failed" "$state" "failed"
check_eq "but the tally is recorded" "$("$JS" get "$J/f1.json" tests)" "3 passed, 2 failed"
check "and the branch too" [ -n "$("$JS" get "$J/f1.json" branch)" ]
mkjob d1 died
printf 'partial output before the kill\n' > "$J/d1.log"
state="$("$JC" run "$J" d1 2>/dev/null)"
check_eq "died stays died — a death is not re-judged" "$state" "died"
check "with its facts recorded for the hand that collects it" \
    [ -n "$("$JS" get "$J/d1.json" collection)" ]

echo
echo "a collector that cannot run costs the line, never the outcome (rule 38):"
"$JS" new "$J" ng1 "a build outside any repository" "" "$T/no-repo-here" dispatched
mkdir -p "$T/no-repo-here"
"$JS" set "$J/ng1.json" state=finished exit=0 finished=now
printf 'Read the docs and wrote the summary. Done.\n' > "$J/ng1.log"
state="$("$JC" run "$J" ng1 2>/dev/null)"
check_eq "a non-git workdir still collects — reporting is real work" "$state" "collected"
check "and says the tree could not be read as one" \
    contains "$("$JS" get "$J/ng1.json" collection)" "not a git tree"
out="$("$JC" run "$J" no-such-job 2>&1)"; rc=$?
check "a missing sidecar is an error on stderr" contains "$out" "cannot read"

echo
echo "the runner end to end — a clean builder lands collected (rule 38):"
# The test_job_block harness shape: the runner copied beside a symlinked
# common.sh, a fake crab, a stub claude, everything pinned to scratch.
mkdir -p "$T/repo/lib" "$T/jobs2"
cp "$REPO/lib/job-runner" "$T/repo/lib/job-runner"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/job-status" "$T/repo/lib/job-status"
ln -sf "$REPO/lib/job-collect" "$T/repo/lib/job-collect"
ln -sf "$REPO/lib/job-log-stream" "$T/repo/lib/job-log-stream"
chmod +x "$T/repo/lib/job-runner"
printf '#!/bin/bash\necho "WAKE: $*" >> "%s/wakes"\n' "$T" > "$T/repo/crab"
chmod +x "$T/repo/crab"
python3 - "$T/claude-ok" <<'PY'
import json, sys
lines = [
    json.dumps({"type": "assistant", "message": {"model": "stub", "content": [
        {"type": "text",
         "text": "Fixed the latch and ran the suite: 4 passed, 0 failed. Done."}]}}),
    json.dumps({"type": "result", "result": "ok"}),
]
body = "#!/bin/bash\ncat > /dev/null\n"
for l in lines:
    body += "echo " + "'" + l.replace("'", "'\\''") + "'" + "\n"
body += "exit 0\n"
open(sys.argv[1], "w").write(body)
PY
chmod +x "$T/claude-ok"
run_runner() { # <jobs-dir> <id> <claude-stub>
    JOBS_DIR="$1" WANTS_FILE="$T/wants.md" CLAUDE_BIN="$3" \
        JOBS_BLOCKED_FILE="$T/blocked-marker" \
        "$T/repo/lib/job-runner" "$2" "$WD" >/dev/null 2>&1
}
"$JS" new "$T/jobs2" e2eok "fix the latch in the fixture repo" "" "$WD" dispatched
run_runner "$T/jobs2" e2eok "$T/claude-ok"
check_eq "the runner's clean build ends collected" \
    "$("$JS" get "$T/jobs2/e2eok.json" state)" "collected"
check "the account walk is on the record" \
    contains "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("attempts",[])))' "$T/jobs2/e2eok.json")" "ran clean"
check "the verdict line landed in the job log" \
    contains "$(cat "$T/jobs2/e2eok.log")" "job-collect:"
check_eq "the tally rode along" \
    "$("$JS" get "$T/jobs2/e2eok.json" tests)" "4 passed, 0 failed"

echo
echo "…and a builder that dies waiting is FAILED by the runner (rule 39):"
python3 - "$T/claude-wait" <<'PY'
import json, sys
lines = [
    json.dumps({"type": "assistant", "message": {"model": "stub", "content": [
        {"type": "text",
         "text": "Surveyed the tree; another hand holds it. Standing by for "
                 "the monitor to report the other jobs done."}]}}),
    json.dumps({"type": "result", "result": "ok"}),
]
body = "#!/bin/bash\ncat > /dev/null\n"
for l in lines:
    body += "echo " + "'" + l.replace("'", "'\\''") + "'" + "\n"
body += "exit 0\n"
open(sys.argv[1], "w").write(body)
PY
chmod +x "$T/claude-wait"
"$JS" new "$T/jobs2" e2ewait "a brief that will be parked on" "" "$WD" dispatched
rm -f "$T/wakes"
run_runner "$T/jobs2" e2ewait "$T/claude-wait"
check_eq "exit 0 plus a waiting tail is failed" \
    "$("$JS" get "$T/jobs2/e2ewait.json" state)" "failed"
check "the suppressed wake reason says it died on a wait" \
    contains "$(cat "$T/jobs2/e2ewait.log")" "FAILED by dying on a wait"
check "and quotes rule 39's why" \
    contains "$(cat "$T/jobs2/e2ewait.log")" "a promise made by a process that stops existing"
[ ! -s "$T/wakes" ] && ok "scratch run reached no live wake" \
    || fail "a scratch runner must never wake the live assistant" "$(cat "$T/wakes")"
