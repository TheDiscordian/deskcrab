#!/bin/bash
# Tests that the wants shelf has exactly ONE reading of its bullet list, and
# that both readers get the same titles.
# Run: bash tests/test_wants_titles.sh
#
# The gap these were written for: the shelf's titles were grepped in two
# places. build_system_prompt's copy was made emoji-tolerant on 2026-08-07;
# lib/promise-audit's (`grep -E '^- \*\*'`) was never updated. Every want on
# the live shelf is written `- 🎼 **Title**`, so the auditor's list matched
# ZERO of eleven — and the auditor is handed that list under the words "this
# list is complete", with instructions to err on the side of flagging. So
# everything she had already written down read as unrecorded: 172 UNSAVED
# verdicts in 309 audits, an event wake booked for each. That is the wake
# storm, and it is one grep.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# The shelf in the shape it actually has on disk: an emoji between the bullet
# and the bold title, a trailing sentence, a pointer to the want's document.
# A plain `- **Title**` line rides along, because the reading that only
# handles the emoji form would be the same bug facing the other way.
mkdir -p "$T/wants"
cat > "$T/wants.md" <<'EOF'
# What I want

- 🎼 **PIPEORGAN_TITLE** — a standing sitting at 21:20, daily. → `wants/pipeorgan.md`
- 🎹 **SEMAPHORE_TITLE** — small and mine. → `wants/semaphore.md`
- **PLAIN_TITLE** — no emoji, the older shape.

Some prose that is not a bullet at all.
- a bullet with no title, which is not a want headline
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$T"
ARCHIVE_DIR="$T/archive"
JOBS_DIR="$T/jobs"
WAKES_DIR="$T/wakes"
DAY_JOURNAL_DIR="$T/journal"
NOTICE_STATE_DIR="$T/notice"
LAST_ORIGIN_FILE="$T/last-origin"
WANTS_FILE="$T/wants.md"
WAKE_QUIET_HOURS=""
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
EOF

run() { # <shell body> — sources common.sh in the sandbox instance.
    DESKCRAB_NO_DISPATCH=1 sandbox_bash "$1" 2>/dev/null
}

echo "wants_titles — one reading of the shelf:"

out="$(run 'wants_titles | tr "\n" "|"')"
[ "$out" = "- 🎼 **PIPEORGAN_TITLE**|- 🎹 **SEMAPHORE_TITLE**|- **PLAIN_TITLE**|" ] \
    && ok "every headline, both shapes, nothing else" \
    || fail "the titles must come back whole and in order" "$out"

out="$(run 'wants_titles "/nonexistent/wants.md"; echo "rc=$?"')"
[ "$out" = "rc=0" ] && ok "a missing shelf is empty, not an error" \
    || fail "a missing file must yield nothing and succeed" "$out"

echo
echo "the injected prompt lists them:"

out="$(run 'build_system_prompt')"
miss=""
for want in PIPEORGAN_TITLE SEMAPHORE_TITLE PLAIN_TITLE; do
    printf '%s' "$out" | grep -qF "$want" || miss="$miss $want"
done
[ -z "$miss" ] && ok "build_system_prompt carries every title" \
    || fail "titles missing from the prompt" "$miss"

echo
echo "the promise auditor is handed the SAME list:"

# A scratch checkout: the auditor books an event wake through its own
# repo's crab, and nothing here may reach the live queue.
mkdir -p "$T/repo/lib"
cp "$REPO_DIR/lib/promise-audit" "$T/repo/lib/promise-audit"
ln -sf "$REPO_DIR/lib/common.sh" "$T/repo/lib/common.sh"
chmod +x "$T/repo/lib/promise-audit"
printf '#!/bin/bash\necho "WAKE: $*" >> "%s/wakes-booked"\n' "$T" > "$T/repo/crab"
chmod +x "$T/repo/crab"

# The stub CLI keeps the prompt it was handed and answers NONE, so the audit
# ends at its log and never reaches a booking.
cat > "$T/claude-stub" <<EOF
#!/bin/bash
cat > "$T/audit-prompt"
echo NONE
EOF
chmod +x "$T/claude-stub"

CLAUDE_BIN="$T/claude-stub" \
    "$T/repo/lib/promise-audit" "how is the shelf" "All quiet." >/dev/null 2>&1

listed="$(sed -n '/EVERY WANT CURRENTLY IN HER FILE/,/=== THE EXCHANGE ===/p' \
    "$T/audit-prompt" 2>/dev/null | grep -c '^- ')"
[ "${listed:-0}" = 3 ] && ok "all three headlines reach the auditor" \
    || fail "the auditor was handed an incomplete shelf (it is told the list is complete)" \
            "${listed:-0} of 3 listed"

[ ! -s "$T/wakes-booked" ] && ok "a NONE verdict books no wake" \
    || fail "nothing here may book a wake" "$(cat "$T/wakes-booked")"

echo
echo "the two readings cannot drift apart again:"

# The old pattern, by its bytes. Two copies of one grep is what this whole
# file is about; a third would be the same defect wearing a new date.
hits="$(grep -rn "grep -E '\^- \\\\\*\\\\\*'" "$REPO_DIR/lib" "$REPO_DIR/crab" 2>/dev/null)"
[ -z "$hits" ] && ok "no second copy of the shelf grep survives" \
    || fail "the shelf must be read in exactly one place" "$hits"

n="$(grep -c "grep -oP '\^- " "$REPO_DIR/lib/common.sh")"
[ "$n" = 1 ] && ok "wants_titles is the only implementation" \
    || fail "one implementation, one function" "$n copies in common.sh"
