#!/bin/bash
# The commits record — specs/turn-pipeline.md rule 32bb, specs/nightly.md rule
# 52a. A commit leaves the working tree exactly as it was, so the checker's
# named-files section cannot tell a committed change from one left lying
# about, and until this record existed a claim about committing was invisible
# to every section the judge holds: on 2026-09-02 at 22:55 "committing my
# three paths only" was ruled UNKEPT with the matching commit, carrying
# precisely those three paths, one minute old in the log.
#
# What is asserted: the helper reads the window and reports it; an empty
# window and an unreadable repository say so in words rather than printing
# nothing; and the judged prompt carries the section with the commit in it.
# Run: bash tests/test_promise_commits.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib"
HELPER="$REPO/lib/promise_commits.py"

# A repository of her own, in the sandbox, with one commit at a known time.
FIXTURE="$T/fixture-repo"
mkdir -p "$FIXTURE/lib" "$FIXTURE/specs" "$FIXTURE/tests"
git init -q -b main "$FIXTURE"
git -C "$FIXTURE" config user.email t@example.com
git -C "$FIXTURE" config user.name Tester
printf 'one\n' > "$FIXTURE/lib/job-collect"
printf 'two\n' > "$FIXTURE/specs/jobs.md"
printf 'three\n' > "$FIXTURE/tests/test_job_collect.sh"
git -C "$FIXTURE" add -- lib/job-collect specs/jobs.md tests/test_job_collect.sh
git -C "$FIXTURE" commit -qm "A job's own verdict decides whose commits those were"

NOW="$(date +%s)"
export DESKCRAB_COMMIT_REPOS="$FIXTURE"

echo "the helper finds the commit and names its files:"
OUT="$(python3 "$HELPER" $(( NOW - 1800 )) - "$FIXTURE" 2>&1)"
check "the subject is carried" contains "$OUT" "A job's own verdict"
check "the touched paths are carried" contains "$OUT" "lib/job-collect"
check "all three of them" contains "$OUT" "tests/test_job_collect.sh"
check "with the count" contains "$OUT" "3 file(s)"

echo
echo "a commit on a builder's own branch counts — --all, not the checked-out branch:"
git -C "$FIXTURE" checkout -q -b builder-branch
printf 'four\n' > "$FIXTURE/lib/side"
git -C "$FIXTURE" add -- lib/side
git -C "$FIXTURE" commit -qm "Work from another hand entirely"
git -C "$FIXTURE" checkout -q main
OUT="$(python3 "$HELPER" $(( NOW - 1800 )) - "$FIXTURE" 2>&1)"
check "the branch commit is in the record" contains "$OUT" "Work from another hand entirely"

echo
echo "an empty window says so in words — never a blank the judge could read as nothing:"
OUT="$(python3 "$HELPER" $(( NOW + 3600 )) - "$FIXTURE" 2>&1)"
check "the empty window is stated" contains "$OUT" "no commit landed"

echo
echo "a repository that cannot be read is NAMED, never silently dropped:"
BROKEN="$T/broken-repo"
mkdir -p "$BROKEN/.git"
printf 'not a repository at all\n' > "$BROKEN/.git/config"
DESKCRAB_COMMIT_REPOS="$BROKEN" \
    OUT="$(DESKCRAB_COMMIT_REPOS="$BROKEN" python3 "$HELPER" $(( NOW - 1800 )) - "$BROKEN" 2>&1)"
check "the unread repository is named" contains "$OUT" "could not be read"
check "by name" contains "$OUT" "broken-repo"

# ---------------------------------------------------------------------------
# And the section reaches the judge. Same fixture shape as the other checker
# tests: the checker copied, the wake module and library linked, a poison
# stub that convicts whatever it is asked about.
# ---------------------------------------------------------------------------
cp "$REPO/lib/promise-check" "$T/repo/lib/promise-check"
chmod +x "$T/repo/lib/promise-check"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/wake-queue.sh" "$T/repo/lib/wake-queue.sh"
ln -sf "$REPO/lib/extract-response" "$T/repo/lib/extract-response"

cat > "$T/repo/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
[ "\${1:-}" = "wake-at" ] || exit 0
shift
source "$REPO/lib/common.sh" >/dev/null 2>&1
wake_book "\$@"
CRAB
chmod +x "$T/repo/crab"

HOUSE="$T/home/house"
mkdir -p "$HOUSE"
cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$HOUSE"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
MEMORY_STORE=0
PROMISE_CHECK=1
CONF

export WAKES_DIR="$W"
export PROMISE_LEDGER="$T/ledger.jsonl"
export DESKCRAB_CHESS_DIR="$T/chess"
export DESKCRAB_COMMIT_REPOS="$FIXTURE"
mkdir -p "$T/chess/games"

sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"KEPT: the commit | the commits record holds it"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB

SNAP="$T/snap.jsonl"
cat > "$SNAP" <<'EOF'
{"type":"assistant","message":{"model":"real","content":[{"type":"text","text":"a reply whose turn ran no tools"}]}}
{"type":"result","result":"done"}
EOF

echo
echo "the judge is handed the commits as a labelled record:"
"$T/repo/lib/promise-check" turn wake "$NOW" 7001 "$SNAP" \
    "$T/ledger.jsonl" "I've committed my three paths only, since another hand has files in this tree." \
    >/dev/null 2>&1
check "the section is in the prompt" \
    grep -q "COMMITS THAT LANDED IN HER REPOSITORIES" "$T/model-stdin"
check "carrying the commit itself" \
    grep -qF "A job's own verdict decides whose commits those were" "$T/model-stdin"
check "and the three paths it touched" grep -qF "lib/job-collect" "$T/model-stdin"
check "the judge is told to count seven records" \
    grep -q "ALL SEVEN records" "$T/model-stdin"
check "the run trace counts the commits it gathered" \
    grep -q "commit(s)" "$DESKCRAB_STATE_PREFIX-promise-check.log"

