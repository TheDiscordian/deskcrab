#!/bin/bash
# Tests for lib/notice-selfchange — the self-change watcher — in a sandbox:
# every path the emitter reads (data dir, conf, state, sessions, jobs, repo,
# extra dirs) is redirected into a temp tree, and `crab` is a stub that
# records what wake it was asked to fire. Run: bash tests/test_notice_selfchange.sh
#
# The emitter is always invoked with attempt=99 — past MAX_DEFERRALS — so it
# judges immediately instead of booking systemd timers from inside a test.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-selftest.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1"; }
check() { # <desc> <cmd...>
    local desc="$1"; shift
    if "$@"; then ok "$desc"; else fail "$desc"; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# --- sandbox ----------------------------------------------------------------
# A stub repo holding the real emitter and a crab stub that logs its argv.
mkdir -p "$T/repo/lib" "$T/data/deskcrab/wants" "$T/data/deskcrab/conduct" \
    "$T/data/deskcrab/engineering" "$T/data/deskcrab/journal" \
    "$T/data/deskcrab/memory" "$T/data/deskcrab/jobs" \
    "$T/conf" "$T/state" "$T/library" "$T/sessions-prefix"
cp "$REPO_DIR/lib/notice-selfchange" "$T/repo/lib/"
cat > "$T/repo/crab" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
STUB
chmod +x "$T/repo/crab" "$T/repo/lib/notice-selfchange"
echo "a tracked file" > "$T/repo/tracked.txt"
echo "ignored-stuff" > "$T/repo/.gitignore"
git -C "$T/repo" init -q -b test
git -C "$T/repo" -c user.email=t@t -c user.name=t add -- crab lib .gitignore tracked.txt
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm seed

: > "$T/conf/deskcrab.conf"
echo "SELF_WATCH_EXTRA=$T/library" >> "$T/conf/deskcrab.conf"

# systemd-run must FAIL in the sandbox: a real deferral would book a transient
# timer on the live user manager that re-runs the emitter without the sandbox
# environment. The emitter treats a failed deferral as "judge now" — which is
# also exactly what the attempt-0 test wants to observe.
mkdir -p "$T/bin"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/systemd-run"
chmod +x "$T/bin/systemd-run"

run() {  # [attempt]
    env -i HOME="$T" PATH="$T/bin:$PATH" \
        XDG_DATA_HOME="$T/data" XDG_STATE_HOME="$T/state" \
        DESKCRAB_CONF="$T/conf/deskcrab.conf" \
        DESKCRAB_STATE_PREFIX="$T/sessions-prefix/deskcrab" \
        JOBS_DIR="$T/data/deskcrab/jobs" \
        "$T/repo/lib/notice-selfchange" "${1:-99}"
}
wakes() { wc -l < "$T/wake-calls" 2>/dev/null || echo 0; }
last_wake() { tail -1 "$T/wake-calls" 2>/dev/null; }
STATE="$T/state/deskcrab"

echo "== seed run is silent =="
echo "keep me" > "$T/data/deskcrab/wants/first-want.md"
echo "conf" > "$T/conf/deskcrab.conf.aside"
run
check "snapshot created" test -f "$STATE/notice-self.snap"
check "no wake on seed" test ! -f "$T/wake-calls"
check "seeded logged" grep -q "seeded" "$STATE/notice-self.log"

echo "== quiet when nothing changed =="
run
check "still no wake" test ! -f "$T/wake-calls"

echo "== an external burst fires ONE wake, deletions first =="
echo "outside hand" > "$T/data/deskcrab/wants/new-want.md"       # created
echo "changed" >> "$T/data/deskcrab/wants/first-want.md"         # modified
echo "a change" >> "$T/repo/tracked.txt"                         # modified, git-tracked
echo "in the library" > "$T/library/new-thing.md"                # created (extra dir)
run
check "exactly one wake for the burst" [ "$(wakes)" = 1 ]
check "wake is an event wake" contains "$(last_wake)" "wake event Files that are part of you"
check "wake names the created want" contains "$(last_wake)" "new-want.md"
check "wake does not prescribe" contains "$(last_wake)" "not a task"
REPORT="$(ls -1t "$STATE"/notice-self-report-*.md | head -1)"
check "report exists" test -n "$REPORT"
check "report has git diff for tracked file" grep -q '```diff' "$REPORT"
check "report lists the library file" grep -q "new-thing.md" "$REPORT"

echo "== a deletion always surfaces, and leads the summary =="
rm "$T/data/deskcrab/wants/new-want.md"
run
check "wake fired for deletion" [ "$(wakes)" = 2 ]
check "deleted named first" contains "$(last_wake)" "own hand — deleted: new-want.md"

echo "== crab touching suppresses her own writes =="
NOW=$(date +%s)
printf '%s\t%s\n' "$(( NOW + 600 ))" "$T/data/deskcrab/wants" >> "$STATE/notice-self.suppress"
echo "my own edit" >> "$T/data/deskcrab/wants/first-want.md"
run
check "no wake for a declared write" [ "$(wakes)" = 2 ]
check "quiet logged with reason" grep -q "quiet: modified.*first-want.md (touching)" "$STATE/notice-self.log"

echo "== touching covers deletions too (her own tidy) =="
echo "doomed" > "$T/library/doomed.md"
run   # consume the creation as its own burst (fires; wake 3)
check "undeclared creation fired" [ "$(wakes)" = 3 ]
printf '%s\t%s\n' "$(( NOW + 600 ))" "$T/library/doomed.md" >> "$STATE/notice-self.suppress"
rm "$T/library/doomed.md"
run
check "her own declared deletion stays quiet" [ "$(wakes)" = 3 ]

echo "== an expired touching record no longer suppresses =="
printf '%s\t%s\n' "$(( NOW - 5 ))" "$T/data/deskcrab/conduct" >> "$STATE/notice-self.suppress"
echo "rule" > "$T/data/deskcrab/conduct/new-rule.md"
run
check "expired record does not suppress" [ "$(wakes)" = 4 ]
check "expired record pruned from file" bash -c "! grep -q 'conduct' '$STATE/notice-self.suppress'"

echo "== a live session's claim suppresses modifications =="
mkdir -p "$T/sessions-prefix/deskcrab-sessions"
echo "live" > "$T/sessions-prefix/deskcrab-sessions/$$"          # our own pid: live
echo "working on engineering/OPEN.md right now" > "$T/sessions-prefix/deskcrab-sessions/$$.claim"
echo "open list" > "$T/data/deskcrab/engineering/OPEN.md"
run
check "claimed modification stays quiet" [ "$(wakes)" = 4 ]
check "claim suppression logged" grep -q "quiet: created.*OPEN.md (claimed" "$STATE/notice-self.log"

echo "== but a claim never excuses a deletion =="
rm "$T/data/deskcrab/engineering/OPEN.md"
run
check "claimed deletion still fires" [ "$(wakes)" = 5 ]
rm -f "$T/sessions-prefix/deskcrab-sessions/$$" "$T/sessions-prefix/deskcrab-sessions/$$.claim"

echo "== memory.db churn beside a recent session is her own plumbing =="
echo "sqlite bytes" > "$T/data/deskcrab/memory/memory.db"
run   # consume the creation as a burst of its own (fires; wake 6)
touch "$T/sessions-prefix/deskcrab-sessions.log"                 # fresh activity
echo "more sqlite bytes" >> "$T/data/deskcrab/memory/memory.db"
run
check "memory.db + recent session stays quiet" [ "$(wakes)" = 6 ]
touch -d '30 min ago' "$T/sessions-prefix/deskcrab-sessions.log"
echo "even more bytes" >> "$T/data/deskcrab/memory/memory.db"
run
check "memory.db with no recent session fires" [ "$(wakes)" = 7 ]

echo "== attempt 0 defers instead of judging (systemd absent → judges now) =="
# The sandbox stubs systemd-run to fail, so the emitter must fall through to
# judging rather than dropping the event. (The change goes to conduct/ — the
# wants/ touching record from earlier is still active.)
echo "late change" >> "$T/data/deskcrab/conduct/new-rule.md"
run 0
check "falls through to a wake when it cannot defer" [ "$(wakes)" = 8 ]

echo "== a weak record excuses a modification but never a deletion =="
# Weak records carry a third column; the two-column records used everywhere
# above are strong, which is how every pre-existing record on disk still reads.
NOW=$(date +%s)
echo "weak subject" > "$T/library/weak.md"
run   # the creation is undeclared and fires (wake 9)
check "undeclared creation fired" [ "$(wakes)" = 9 ]
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library/weak.md" >> "$STATE/notice-self.suppress"
echo "changed" >> "$T/library/weak.md"
run
check "weak record suppresses a modification" [ "$(wakes)" = 9 ]
check "weak suppression is logged as weak" \
    grep -q "quiet: modified.*weak.md (touching (weak" "$STATE/notice-self.log"
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library/weak.md" >> "$STATE/notice-self.suppress"
rm "$T/library/weak.md"
run
check "weak record does NOT excuse a deletion" [ "$(wakes)" = 10 ]

echo "== a weak record for a directory covers creations beneath it, nothing else =="
# This is how a tool that derives its own output name stays quiet: I name the
# directory (or a file in it), the tool writes siblings I never spelled out.
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library" >> "$STATE/notice-self.suppress"
echo "inside" > "$T/library/under-a-weak-dir.md"
run
check "weak directory record excuses a creation beneath it" [ "$(wakes)" = 10 ]
check "the creation is logged as a weak-directory suppression" \
    grep -q "quiet: created.*under-a-weak-dir.md (touching (weak — created under" \
        "$STATE/notice-self.log"
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library" >> "$STATE/notice-self.suppress"
echo "edited" >> "$T/library/under-a-weak-dir.md"
run
check "weak directory record does NOT excuse a modification beneath it" [ "$(wakes)" = 11 ]
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library" >> "$STATE/notice-self.suppress"
rm "$T/library/under-a-weak-dir.md"
run
check "weak directory record does NOT excuse a deletion beneath it" [ "$(wakes)" = 12 ]

echo "== .gitignored repo files are invisible =="
mkdir -p "$T/repo/ignored-stuff"
echo "scratch" > "$T/repo/ignored-stuff/scratch.txt"
run
check "ignored file fires nothing" [ "$(wakes)" = 12 ]

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
