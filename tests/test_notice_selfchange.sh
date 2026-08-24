#!/bin/bash
# Tests for lib/notice-selfchange — the self-change watcher. Every path the
# emitter reads (data dir, conf, state, sessions, jobs, repo, extra dirs) is
# the sandbox's, and `crab` is a stub that records what wake it was asked to
# fire. Run: bash tests/test_notice_selfchange.sh
#
# The emitter is always invoked with attempt=99 — past MAX_DEFERRALS — so it
# judges immediately instead of booking systemd timers from inside a test.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# --- fixture ----------------------------------------------------------------
# A stub repo holding the real emitter and a crab stub that logs its argv.
mkdir -p "$T/repo/lib" "$T/data/deskcrab/wants" "$T/data/deskcrab/conduct" \
    "$T/data/deskcrab/engineering" "$T/data/deskcrab/journal" \
    "$T/data/deskcrab/memory" "$T/data/deskcrab/jobs" "$T/library"
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

: > "$DESKCRAB_CONF"
echo "SELF_WATCH_EXTRA=$T/library" >> "$DESKCRAB_CONF"

# A deferral must FAIL here: a real one would book a transient timer on the
# live user manager that re-runs the emitter without the sandbox environment.
# The emitter treats a failed deferral as "judge now" — which is also exactly
# what the attempt-0 case below wants to observe.
sandbox_systemd_rc 1

run() {  # [attempt]
    "$T/repo/lib/notice-selfchange" "${1:-99}"
}
wakes() { wc -l < "$T/wake-calls" 2>/dev/null || echo 0; }
last_wake() { tail -1 "$T/wake-calls" 2>/dev/null; }
STATE="$NOTICE_STATE_DIR"

echo "== seed run is silent =="
echo "keep me" > "$T/data/deskcrab/wants/first-want.md"
echo "conf" > "$DESKCRAB_CONF.aside"
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
check "wake is an event wake, booked in the emitter's own name" \
    contains "$(last_wake)" "wake-at --by notice-selfchange 5s event Files that are part of you"
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

echo "== a record that died BEFORE the last judgement no longer suppresses =="
printf '%s\t%s\n' "$(( NOW - 3600 ))" "$T/data/deskcrab/conduct" >> "$STATE/notice-self.suppress"
echo "rule" > "$T/data/deskcrab/conduct/new-rule.md"
run
check "expired record does not suppress" [ "$(wakes)" = 4 ]
check "expired record pruned from file" bash -c "! grep -q 'conduct' '$STATE/notice-self.suppress'"

echo "== a record that died DURING the gap since the last judgement still suppresses =="
# The real failure of 2026-08-07: she wrote two engineering notes at 05:05 and
# declared them for fifteen minutes, but nothing judged until 05:40 — so by the
# time anything looked, her own declaration had died of old age and her own
# hand was reported to her as an intruder's. The window a scan consults must
# cover the same interval its diff covers.
printf '%s\n' "$(( NOW - 1800 ))" > "$STATE/notice-self.judged"   # last judged 30 min ago
printf '%s\t%s\n' "$(( NOW - 900 ))" "$T/data/deskcrab/engineering" >> "$STATE/notice-self.suppress"
echo "a note of my own" > "$T/data/deskcrab/engineering/thread.md"
run
check "declaration alive during the gap still suppresses" [ "$(wakes)" = 4 ]
check "quiet logged for the gap-declared write" \
    grep -q "quiet: created.*thread.md (touching)" "$STATE/notice-self.log"

echo "== but the honoured window is bounded by the backstop =="
printf '%s\n' "$(( NOW - 999999 ))" > "$STATE/notice-self.judged"   # judgement long dead
printf '%s\t%s\n' "$(( NOW - 86400 ))" "$T/data/deskcrab/conduct" >> "$STATE/notice-self.suppress"
echo "another rule" > "$T/data/deskcrab/conduct/older-rule.md"
run
check "an ancient declaration cannot silence a stalled watcher" [ "$(wakes)" = 5 ]

echo "== a live session's claim suppresses modifications =="
mkdir -p "$DESKCRAB_STATE_PREFIX-sessions"
echo "live" > "${DESKCRAB_STATE_PREFIX}-sessions/$$"          # our own pid: live
echo "working on engineering/OPEN.md right now" > "${DESKCRAB_STATE_PREFIX}-sessions/$$.claim"
echo "open list" > "$T/data/deskcrab/engineering/OPEN.md"
run
check "claimed modification stays quiet" [ "$(wakes)" = 5 ]
check "claim suppression logged" grep -q "quiet: created.*OPEN.md (claimed" "$STATE/notice-self.log"

echo "== but a claim never excuses a deletion =="
rm "$T/data/deskcrab/engineering/OPEN.md"
run
check "claimed deletion still fires" [ "$(wakes)" = 6 ]
rm -f "${DESKCRAB_STATE_PREFIX}-sessions/$$" "${DESKCRAB_STATE_PREFIX}-sessions/$$.claim"

echo "== memory.db churn beside a recent session is her own plumbing =="
echo "sqlite bytes" > "$T/data/deskcrab/memory/memory.db"
run   # consume the creation as a burst of its own (fires; wake 6)
touch "$DESKCRAB_STATE_PREFIX-sessions.log"                 # fresh activity
echo "more sqlite bytes" >> "$T/data/deskcrab/memory/memory.db"
run
check "memory.db + recent session stays quiet" [ "$(wakes)" = 7 ]
touch -d '30 min ago' "$DESKCRAB_STATE_PREFIX-sessions.log"
echo "even more bytes" >> "$T/data/deskcrab/memory/memory.db"
run
check "memory.db with no recent session fires" [ "$(wakes)" = 8 ]

echo "== attempt 0 defers instead of judging (systemd absent → judges now) =="
# The sandbox stubs systemd-run to fail, so the emitter must fall through to
# judging rather than dropping the event. (The change goes to conduct/ — the
# wants/ touching record from earlier is still active.)
echo "late change" >> "$T/data/deskcrab/conduct/new-rule.md"
run 0
check "falls through to a wake when it cannot defer" [ "$(wakes)" = 9 ]

echo "== a weak record excuses a modification but never a deletion =="
# Weak records carry a third column; the two-column records used everywhere
# above are strong, which is how every pre-existing record on disk still reads.
NOW=$(date +%s)
echo "weak subject" > "$T/library/weak.md"
run   # the creation is undeclared and fires (wake 9)
check "undeclared creation fired" [ "$(wakes)" = 10 ]
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library/weak.md" >> "$STATE/notice-self.suppress"
echo "changed" >> "$T/library/weak.md"
run
check "weak record suppresses a modification" [ "$(wakes)" = 10 ]
check "weak suppression is logged as weak" \
    grep -q "quiet: modified.*weak.md (touching (weak" "$STATE/notice-self.log"
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library/weak.md" >> "$STATE/notice-self.suppress"
rm "$T/library/weak.md"
run
check "weak record does NOT excuse a deletion" [ "$(wakes)" = 11 ]

echo "== a weak record for a directory covers creations beneath it, nothing else =="
# This is how a tool that derives its own output name stays quiet: I name the
# directory (or a file in it), the tool writes siblings I never spelled out.
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library" >> "$STATE/notice-self.suppress"
echo "inside" > "$T/library/under-a-weak-dir.md"
run
check "weak directory record excuses a creation beneath it" [ "$(wakes)" = 11 ]
check "the creation is logged as a weak-directory suppression" \
    grep -q "quiet: created.*under-a-weak-dir.md (touching (weak — created under" \
        "$STATE/notice-self.log"
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library" >> "$STATE/notice-self.suppress"
echo "edited" >> "$T/library/under-a-weak-dir.md"
run
check "weak directory record does NOT excuse a modification beneath it" [ "$(wakes)" = 12 ]
printf '%s\t%s\tweak\n' "$(( NOW + 600 ))" "$T/library" >> "$STATE/notice-self.suppress"
rm "$T/library/under-a-weak-dir.md"
run
check "weak directory record does NOT excuse a deletion beneath it" [ "$(wakes)" = 13 ]

echo "== .gitignored repo files are invisible =="
mkdir -p "$T/repo/ignored-stuff"
echo "scratch" > "$T/repo/ignored-stuff/scratch.txt"
run
check "ignored file fires nothing" [ "$(wakes)" = 13 ]

echo "== .git internals under a watched drawer are invisible (the drawer is a repo of its own) =="
# The incident of 2026-08-11: conduct is a git repository, and a commit made
# there by her own hand woke her thirteen minutes later about refs/heads,
# logs/HEAD, COMMIT_EDITMSG and the index. The commits are the record; the
# plumbing is noise (spec rule 25a).
git -C "$T/data/deskcrab/conduct" init -q -b main
run
check "a drawer growing its own .git fires nothing" [ "$(wakes)" = 13 ]
git -C "$T/data/deskcrab/conduct" -c user.email=t@t -c user.name=t add -- new-rule.md older-rule.md
git -C "$T/data/deskcrab/conduct" -c user.email=t@t -c user.name=t commit -qm "rules committed"
run
check "a commit's .git plumbing fires nothing" [ "$(wakes)" = 13 ]
# The extra watch set gets the same treatment. A creation under the library
# could hide behind a lingering weak-directory record, so the teeth are in the
# MODIFICATION: weak records never excuse those, only the prune keeps it quiet.
mkdir -p "$T/library/.git"
echo "index bytes" > "$T/library/.git/index"
run
echo "more index bytes" >> "$T/library/.git/index"
run
check "extra-dir .git internals fire nothing either" [ "$(wakes)" = 13 ]


echo "== a write inside her own LIVE session's run window stays quiet (rule 25b) =="
# The incident of 2026-08-14: a wake wrote a want document at 20:31:16 and the
# watcher reported her own hand back to her as an intruder at 20:31:17 — four
# times in one evening across the wants shelf and the library — because a
# session writing right up to its final second leaves fresh mtimes with no
# touching record and no claim. The ledger never records which paths a
# session's tools touched, only when it ran, so the run window IS the rule.
# (conduct/ and engineering/ carry no lingering suppression records by this
# point; wants/ still sits under the strong touching record from earlier and
# the library under the weak-directory ones, so neither can prove anything.)
NOW=$(date +%s)
mkdir -p "$DESKCRAB_STATE_PREFIX-sessions"
# A registration in the real five-field shape: kind, pid, started, epoch, starttime.
printf 'autonomous wake\t%s\t%s\t%s\t%s\n' "$$" \
    "$(date -d "@$(( NOW - 60 ))" '+%Y-%m-%d %H:%M:%S')" "$(( NOW - 60 ))" "0" \
    > "${DESKCRAB_STATE_PREFIX}-sessions/$$"
echo "written by my own live wake" >> "$T/data/deskcrab/conduct/new-rule.md"
echo "a rule filed as I ran" > "$T/data/deskcrab/conduct/late-rule.md"
run
check "own-session write stays quiet" [ "$(wakes)" = 13 ]
check "own-session creation stays quiet too" \
    bash -c "! grep -q 'late-rule.md' '$T/wake-calls'"
check "run-window suppression logged with its reason" \
    grep -q "quiet: modified.*new-rule.md (own run window" "$STATE/notice-self.log"

echo "== but a deletion during her own run window still surfaces =="
rm "$T/library/new-thing.md"
run
check "deletion inside a live window still fires" [ "$(wakes)" = 14 ]
check "the deletion is named" contains "$(last_wake)" "deleted: new-thing.md"
rm -f "${DESKCRAB_STATE_PREFIX}-sessions/$$"

echo "== a FINISHED session's window from the log covers a write made while it ran =="
# The window comes from the sessions log line common.sh writes at finish:
# start datetime, end clock, duration, kind, outcome. The write's mtime is set
# back inside the window, the way a wake's late write looks by the time a
# deferred judgement finally runs.
NOW=$(date +%s)
printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -d "@$(( NOW - 300 ))" '+%Y-%m-%d %H:%M:%S')" \
    "$(date -d "@$(( NOW - 120 ))" '+%H:%M:%S')" "180" \
    "autonomous wake" "(wrote in my own drawers)" \
    >> "$DESKCRAB_STATE_PREFIX-sessions.log"
echo "landed mid-session" > "$T/data/deskcrab/engineering/mid-session-note.md"
touch -d "@$(( NOW - 200 ))" "$T/data/deskcrab/engineering/mid-session-note.md"
run
check "write inside a finished session's window stays quiet" [ "$(wakes)" = 14 ]

echo "== the grace forgives a write seconds past the session's end =="
echo "final-second flush" > "$T/data/deskcrab/engineering/final-second.md"
touch -d "@$(( NOW - 60 ))" "$T/data/deskcrab/engineering/final-second.md"  # 60s past end, inside the 90s grace
run
check "write inside the grace stays quiet" [ "$(wakes)" = 14 ]

echo "== a reaped line ('?' duration) still yields its window =="
# session_reap writes '?' for the duration and only the reaper's clock in
# field 2. The end resolves against the start's date, rolling a day forward
# when it reads earlier; a parse that failed here would either crash the
# judgement or open a window that swallows everything.
printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -d "@$(( NOW - 7200 ))" '+%Y-%m-%d %H:%M:%S')" \
    "$(date -d "@$(( NOW - 7000 ))" '+%H:%M:%S')" "?" \
    "autonomous wake" "(killed — no summary)" \
    >> "$DESKCRAB_STATE_PREFIX-sessions.log"
# (This write went to journal/ until rule 25d made that drawer plumbing —
# quiet regardless of windows, which would have left this assertion proving
# nothing. engineering/ carries no lingering record by this point, so the
# reaped window alone must do the excusing.)
echo "written under a reaped session" > "$T/data/deskcrab/engineering/reaped-era.md"
touch -d "@$(( NOW - 7100 ))" "$T/data/deskcrab/engineering/reaped-era.md"
run
check "write inside a reaped session's window stays quiet" [ "$(wakes)" = 14 ]

echo "== an outside hand while NO session runs still raises exactly one notice =="
# The other direction, and the one this feature must never weaken: no live
# registration, every logged window ended at least two minutes ago, the grace
# is 90 seconds — a fresh mtime belongs to nobody and must fire.
echo "an outside hand entirely" >> "$T/data/deskcrab/conduct/new-rule.md"
run
check "outside write with no session running fires exactly one wake" [ "$(wakes)" = 15 ]
check "the outside write is named" contains "$(last_wake)" "modified: new-rule.md"
