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
echo "commit=none means the window's commits are another hand's (rule 38c):"
# The shape of job 20260902-224329: it stood down, touched nothing, and was
# credited with two commits a live session had landed in the same tree.
mkjob sd1 finished 0
sleep 1
echo other > "$WD/another-hand.txt"
git -C "$WD" add -- another-hand.txt
git -C "$WD" commit -qm "a live session's commit, not this job's"
printf 'I stood down: a duplicate of a live job. I committed nothing.\n\nVERDICT: tests=0/0 commit=none\n' > "$J/sd1.log"
"$JC" run "$J" sd1 >/dev/null 2>"$T/sdverdict"
sdc="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("commits",[])))' "$J/sd1.json")"
check_eq "no commit is attributed to a job that says it made none" "$sdc" "0"
check_eq "the window's count is kept separately" \
    "$("$JS" get "$J/sd1.json" tree_commits)" "1"
check "and the verdict says so in words" \
    contains "$(cat "$T/sdverdict")" "no commits of its own"
check "naming the other hands" \
    contains "$(cat "$T/sdverdict")" "from other hands"

echo
echo "the tally is the END STATE, never the deliberate red (rule 38a):"
# A well-behaved builder proves its tests red against the pre-change tree
# before writing the fix, and twice the collector quoted exactly that proof
# as the outcome — 20260820-011358 as "51 passed, 6 failed" over a suite
# that finished 57 and 0, 20260823-233936 as "16 passed, 9 failed" on a job
# that ended all green. These fixtures are those logs' shapes.
tally_of() { # <id> <log text> — collect a finished job over the given report
    mkjob "$1" finished 0
    printf '%b' "$2" > "$J/$1.log"
    "$JC" run "$J" "$1" >/dev/null 2>&1
    "$JS" get "$J/$1.json" tests
}
check_eq "a red before the commit line loses to the bare-number green after it" \
    "$(tally_of t38a1 'Proved the tests red against the tree: 3 passed, 4 failed.\nWrote the fix. Committed as abc1234 on the branch.\nAfter the fix: test_widget 7, all green. Done.\n')" \
    "7 passed, 0 failed"
check_eq "a pre-change-labelled red restated AFTER the commit is still never quoted" \
    "$(tally_of t38a2 'Committed as abc1234. Suite now: 9 passed, 0 failed. For the record, the pre-change red was 2 passed, 5 failed.\n')" \
    "9 passed, 0 failed"
check_eq "the 20260820 shape: the labelled red is the only 'passed' in the log, the green wins" \
    "$(tally_of t38a3 'Shown red against the pre-change tree first: 51 passed, 6 failed, and the red run reproduced the live bug. After the fix: test_claudism_scan 57, and the rest of the family green - mirror 43, table 51. Committed as bb2555c on the branch. Done.\n')" \
    "57 passed, 0 failed"
check_eq "the 20260823 shape: the with-the-fix number list is the tally, all of it" \
    "$(tally_of t38a4 'Committed as 99a9d1d on the branch. The suites against the pre-change tree from HEAD: test_night_work 55 passed 5 failed, test_night_work_utf8 16 passed 9 failed. With the fix: 60, 40 and 25, zero failures. Done.\n')" \
    "60+40+25 passed, 0 failed"
check_eq "a VERDICT line outranks every prose tally (rule 38b)" \
    "$(tally_of t38b1 'Mid-run the suite said 12 passed, 3 failed; the end was better.\nCommitted as feed1234. Done.\nVERDICT: tests=31/0 commit=feed1234\n')" \
    "31 passed, 0 failed"
check_eq "a VERDICT line is read even when no prose shape matches at all" \
    "$(tally_of t38b2 'Fixed and committed as abc1234; everything went well. Done.\nVERDICT: tests=44/0 commit=abc1234\n')" \
    "44 passed, 0 failed"
check_eq "the collector's own appended line is never material on a re-collect" \
    "$(tally_of t38a5 'Ran the suite: 8 passed, 0 failed. Done.\njob-collect: collected: 1 commit on some-branch; tests: 51 passed, 6 failed\n')" \
    "8 passed, 0 failed"
check_eq "a single tally and no commit line collect exactly as before" \
    "$(tally_of t38a6 'Ran the suite: 5 passed, 1 failed. Done.\n')" \
    "5 passed, 1 failed"
check_eq "no tally at all invents no count" \
    "$(tally_of t38a7 'Read the docs and wrote the summary. Done.\n')" ""
check_eq "a log whose ONLY tally is the labelled pre-change proof yields none" \
    "$(tally_of t38a8 'Shown red against the pre-change tree: 4 passed, 2 failed. The fix landed and everything went green. Done.\n')" ""

echo
echo "…and the VERDICT line is transparent to rule 39, both ways (rule 38b):"
mkjob vw1 finished 0
printf 'All edits are in.\nStanding by for the monitor to report the other jobs done.\nVERDICT: tests=5/0 commit=abc1234\n' > "$J/vw1.log"
state="$("$JC" run "$J" vw1 2>/dev/null)"
check_eq "a trailing verdict line does not hide a report that ends on a wait" \
    "$state" "failed"
check "and the verdict still quotes the waiting" \
    contains "$("$JS" get "$J/vw1.json" collection)" "Standing by for the monitor"
mkjob vw2 finished 0
printf 'Fixed, tested, committed as abc1234. Done.\nVERDICT: tests=6/0 commit=abc1234\n' > "$J/vw2.log"
state="$("$JC" run "$J" vw2 2>/dev/null)"
check_eq "and a verdict line closing a conclusive report is never read as a wait" \
    "$state" "collected"
check_eq "with its tally on the record" \
    "$("$JS" get "$J/vw2.json" tests)" "6 passed, 0 failed"

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
echo "a wait narrated mid-tail of a conclusive report is not a wait died on:"
mkjob mid1 finished 0
printf 'The client was stuck waiting on a dead socket; I removed that wait entirely.\nRan the suite: 9 passed, 0 failed. Committed and verified; nothing is left open. Done.\n' > "$J/mid1.log"
state="$("$JC" run "$J" mid1 2>/dev/null)"
check_eq "rule 39 judges the close, not a mention — the report collects" \
    "$state" "collected"

echo
echo "…while the same wait words CLOSING the report are died on:"
mkjob mid2 finished 0
printf 'Reproduced the hang and traced it to the socket layer.\nNow waiting on the upstream socket fix before anything can be verified.\n' > "$J/mid2.log"
state="$("$JC" run "$J" mid2 2>/dev/null)"
check_eq "a report ending on a wait is failed" "$state" "failed"
check "and the verdict quotes the closing wait" \
    contains "$("$JS" get "$J/mid2.json" collection)" "waiting on the upstream socket fix"

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
# The result event repeats the final text, exactly as the real CLI's does —
# job-log-stream drops the repeat, so the log ENDS on the wait. A synthetic
# "ok" result here would append a line after it, a shape no real stream has.
text = ("Surveyed the tree; another hand holds it. Standing by for "
        "the monitor to report the other jobs done.")
lines = [
    json.dumps({"type": "assistant", "message": {"model": "stub", "content": [
        {"type": "text", "text": text}]}}),
    json.dumps({"type": "result", "result": text}),
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
