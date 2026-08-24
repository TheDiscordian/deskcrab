#!/bin/bash
# Tests for lib/notice-selfchange — the detached-job window (spec rule 25c)
# and the plumbing never-report list (rule 25d), from the engineering record
# the-watcher-reports-my-own-music-back-to-me-as-a: a builder job she
# dispatched is her own hand at one remove, so from dispatch until collection
# everything under that job's workdir is the job's claimed tree, and the day
# journal drawer and the wakes ledger are machinery-only paths that never
# report a write at all. Fabricated ledger sidecars, scratch tree, the same
# hermetic sandbox as test_notice_selfchange.sh.
# Run: bash tests/test_notice_jobclaim.sh
#
# Invoked with attempt=99 — past MAX_DEFERRALS — so it judges immediately
# instead of booking systemd timers from inside a test.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# --- fixture ----------------------------------------------------------------
# A stub repo holding the real emitter, a crab stub that records wakes, the
# watched drawers, and an extra watch directory to serve as a second workdir.
mkdir -p "$T/repo/lib" "$T/data/deskcrab/wants" "$T/data/deskcrab/journal" \
    "$T/data/deskcrab/wakes" "$T/data/deskcrab/jobs" "$T/library"
cp "$REPO_DIR/lib/notice-selfchange" "$T/repo/lib/"
cat > "$T/repo/crab" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
STUB
chmod +x "$T/repo/crab" "$T/repo/lib/notice-selfchange"
echo "a tracked file" > "$T/repo/tracked.txt"
git -C "$T/repo" init -q -b test
git -C "$T/repo" -c user.email=t@t -c user.name=t add -- crab lib tracked.txt
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm seed

: > "$DESKCRAB_CONF"
echo "SELF_WATCH_EXTRA=$T/library" >> "$DESKCRAB_CONF"
sandbox_systemd_rc 1

run() { "$T/repo/lib/notice-selfchange" "${1:-99}"; }
wakes() { if [ -f "$T/wake-calls" ]; then wc -l < "$T/wake-calls"; else echo 0; fi; }
last_wake() { tail -1 "$T/wake-calls" 2>/dev/null; }
STATE="$NOTICE_STATE_DIR"
JOBS="$T/data/deskcrab/jobs"

# A sidecar in the ledger's own shape — json indent=1, top-level keys at one
# space — including a history array whose nested "state" lines and a brief
# whose prose bait an unanchored parse into misreading the live field.
sidecar() {  # <id> <state> <workdir> <started_epoch> [collected_at_epoch]
    local extra=""
    [ -n "${5:-}" ] && extra="
 \"collected_at_epoch\": $5,"
    cat > "$JOBS/$1.json" <<EOF
{
 "id": "$1",
 "description": "a fabricated brief whose prose says \\"state\\": \\"running\\" to bait an unanchored parse",
 "started": "fabricated",
 "started_epoch": $4,
 "unit": "deskcrab-job-$1",
 "state": "$2",
 "workdir": "$3",
 "history": [
  {
   "at": "fabricated",
   "state": "dispatched"
  },
  {
   "at": "fabricated",
   "state": "running"
  }
 ],${extra}
 "pid": 1
}
EOF
}

echo "== seed run is silent =="
run
check "snapshot created" test -f "$STATE/notice-self.snap"
check "no wake on seed" test ! -f "$T/wake-calls"

echo "== (a) a modification under a running job's workdir stays quiet =="
NOW=$(date +%s)
sidecar j-alpha running "$T/repo" "$(( NOW - 60 ))"
echo "the builder saves" >> "$T/repo/tracked.txt"
run
check "no wake for the builder's save" [ "$(wakes)" = 0 ]
check "the quiet line names the claiming job" \
    grep -q "quiet: modified.*tracked.txt.*job j-alpha" "$STATE/notice-self.log"

echo "== (b) three successive saves are one job window, not one alarm per mtime =="
echo "save two" >> "$T/repo/tracked.txt"
run
echo "save three" >> "$T/repo/tracked.txt"
run
check "still no wake after three saves" [ "$(wakes)" = 0 ]
check "each save was judged quiet, none skipped" \
    [ "$(grep -c "quiet: modified.*tracked.txt.*job j-alpha" "$STATE/notice-self.log")" -ge 3 ]

echo "== (d) a change the running job already committed is still the job's =="
echo "committed work" >> "$T/repo/tracked.txt"
echo "built by the job" > "$T/repo/built-by-job.txt"
git -C "$T/repo" -c user.email=t@t -c user.name=t add -- tracked.txt built-by-job.txt
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm "the job commits its work"
run
check "a committed change under the job is not an outside hand" [ "$(wakes)" = 0 ]
check "the file the commit created is quiet too" \
    grep -q "quiet: created.*built-by-job.txt.*job j-alpha" "$STATE/notice-self.log"

echo "== (c) two concurrent jobs, different workdirs, both suppressed independently =="
ALPHA_QUIET=$(grep -c "tracked.txt.*job j-alpha" "$STATE/notice-self.log")
sidecar j-beta running "$T/library" "$(( NOW - 30 ))"
echo "second builder's output" > "$T/library/j2-output.md"
echo "first builder still at it" >> "$T/repo/tracked.txt"
run
check "one burst under two jobs, no wake" [ "$(wakes)" = 0 ]
check "the library write is j-beta's" \
    grep -q "quiet: created.*j2-output.md.*job j-beta" "$STATE/notice-self.log"
check "the repo write is j-alpha's, judged again" \
    [ "$(grep -c "tracked.txt.*job j-alpha" "$STATE/notice-self.log")" -gt "$ALPHA_QUIET" ]

echo "== a deletion under a live job's workdir still surfaces, with the job named =="
rm "$T/library/j2-output.md"
run
check "the deletion fires" [ "$(wakes)" = 1 ]
check "the wake names the deletion" contains "$(last_wake)" "deleted: j2-output.md"
REPORT="$(ls -1t "$STATE"/notice-self-report-*.md 2>/dev/null | head -1)"
check "the report names the claiming job so the claim is traceable" \
    grep -q "j-beta" "$REPORT"

echo "== (e) collection closes the window at once =="
C=$(date +%s)
sidecar j-alpha collected "$T/repo" "$(( C - 120 ))" "$(( C - 2 ))"
echo "a hand after collection" >> "$T/repo/tracked.txt"
run
check "a modification after the job collected fires" [ "$(wakes)" = 2 ]
check "the wake names it" contains "$(last_wake)" "modified: tracked.txt"

echo "== (f) a path under no live job's workdir still fires =="
echo "outside every claim" > "$T/data/deskcrab/wants/stray.md"
run
check "an unclaimed path fires exactly as before" [ "$(wakes)" = 3 ]
check "the stray is named" contains "$(last_wake)" "stray.md"

echo "== a byte under a job's workdir from BEFORE its dispatch is not the job's =="
# j-beta is still running over the library, dispatched about now-30. A file
# whose mtime predates the dispatch landed under nobody's window: the claim
# is the job's LIFE, never a blanket over the path.
echo "landed long before the job" > "$T/library/pre-dispatch.md"
touch -d "@$(( $(date +%s) - 600 ))" "$T/library/pre-dispatch.md"
run
check "a pre-dispatch mtime under the workdir still fires" [ "$(wakes)" = 4 ]

echo "== (g) journal writes are plumbing, jobs or no jobs =="
echo '{"entry":"night"}' >> "$T/data/deskcrab/journal/2026-08-24.jsonl"
run
check "a journal write with a job running stays quiet" [ "$(wakes)" = 4 ]
check "logged as plumbing, not as the job's" \
    grep -q "quiet: created.*2026-08-24.jsonl (own plumbing" "$STATE/notice-self.log"
C2=$(date +%s)
sidecar j-beta collected "$T/library" "$(( C2 - 300 ))" "$(( C2 - 2 ))"
echo '{"entry":"later"}' >> "$T/data/deskcrab/journal/2026-08-24.jsonl"
run
check "a journal write with every job collected stays quiet too" [ "$(wakes)" = 4 ]

echo "== the wakes ledger is plumbing too =="
echo '{"wake":"w-1"}' > "$T/data/deskcrab/wakes/w-1.json"
run
check "a wakes-ledger write stays quiet" [ "$(wakes)" = 4 ]

echo "== but a deleted journal day still surfaces =="
rm "$T/data/deskcrab/journal/2026-08-24.jsonl"
run
check "a journal deletion fires — plumbing never excuses a deletion" [ "$(wakes)" = 5 ]
check "the deletion is named" contains "$(last_wake)" "deleted: 2026-08-24.jsonl"
