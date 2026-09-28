#!/bin/bash
# Sleep's claudism review — specs/nightly.md rules 39-44. Run:
# bash tests/test_claudism_review.sh
#
# What the judge is shown (spoken halves, never a job's entry or the display
# half; the flags; the persona sheet; the conduct drawer; the recalled records
# with their ids), and what the review may change: a record reworded or
# retired through `crab memory`, an exact-once text replacement in the persona
# sheet or a conduct file, a `- replace:` line in the phrase list, and nothing
# else — with every edited file copied aside first, the cap held, and no wake.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
DAY="2026-09-20"
H="$T/home"
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

sandbox_stub codex <<STUB
if [ "\${1:-}" = "app-server" ]; then exit 75; fi
cat > "$T/prompt-last"
python3 - "$T/reply.txt" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
print(json.dumps({"type": "thread.started", "thread_id": "stub"}))
print(json.dumps({"type": "turn.started"}))
print(json.dumps({"type": "item.completed",
                  "item": {"id": "item_0", "type": "agent_message", "text": text}}))
print(json.dumps({"type": "turn.completed",
                  "usage": {"input_tokens": 1, "cached_input_tokens": 0,
                            "cache_write_input_tokens": 0, "output_tokens": 1}}))
PY
exit 0
STUB

# The door: recall answers with three records; rewrite and forget are logged.
cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
if [ "\$1 \$2" = "memory recall-block" ]; then
    while [ \$# -gt 0 ]; do
        [ "\$1" = "--ids-out" ] && out="\$2"
        shift
    done
    printf '%s' '[{"id": 11, "kind": "directive", "text": "He wants the assistant to stop narrating her bookkeeping."}, {"id": 12, "kind": "note", "text": "Status reports go in a list with counts."}, {"id": 13, "kind": "episodic", "text": "We watched the rain."}]' > "\$out"
    exit 0
fi
[ "\$2" = "rewrite" ] && echo "#99 rewrites #\$3 [directive]"
[ "\$2" = "forget" ] && echo "retired #\$3"
exit 0
CRAB
chmod +x "$T/crab"

mkdir -p "$T/journal" "$T/flags" "$H/conduct"
cat > "$T/journal/$DAY.jsonl" <<'EOF'
{"epoch": 1758340000, "time": "2026-09-20T10:00:00-0400", "kind": "desktop", "pid": 201, "user": "how are you?", "reply": "Status: three wakes booked, two jobs running.\n---DISPLAY---\nDISPLAYNOISE table"}
{"epoch": 1758343600, "time": "2026-09-20T11:00:00-0400", "kind": "job", "pid": 202, "user": "builder brief", "reply": "BUILDERNOISE: 47 passed"}
EOF
printf '%s\n' '{"epoch": 1758340000, "pid": 201, "time": "2026-09-20T10:00:00-0400", "kind": "desktop", "sentence": "Status: three wakes booked, two jobs running.", "note": "status-report cadence", "use": "use", "outcome": "table-swap", "after": "Right now, three wakes booked, two jobs running."}' \
    > "$T/flags/$DAY.jsonl"
cat > "$T/persona.md" <<'EOF'
## Persona
Report your state as a status list when asked how you are.
Be haughty.
EOF
cat > "$H/conduct/CONDUCT.md" <<'EOF'
- Say less -> say-less.md
EOF
cat > "$H/conduct/say-less.md" <<'EOF'
Policy 4.2: the assistant shall minimise verbosity.
EOF
cat > "$T/claudisms.md" <<'EOF'
## status-report cadence
- pattern: `\bstatus:`
- replace: `\bStatus:\s*` -> `Right now, `
EOF

review() {
    env CRAB_BIN="$T/crab" DAY_JOURNAL_DIR="$T/journal" \
        CLAUDISM_FLAGS_DIR="$T/flags" CLAUDISMS_FILE="$T/claudisms.md" \
        CUSTOM_PROMPT="$T/persona.md" WANTS_FILE="$H/wants.md" \
        NIGHT_JUDGE_MODEL=gpt-5.6-sol DESKCRAB_CODEX_STATE="$T/cx-state" \
        "$@" "$REPO/lib/claudism-review" run "$DAY" 2>&1
}
snap() { cat "$T/persona.md" "$H/conduct/"*.md "$T/claudisms.md" | md5sum; }

echo "what the judge is shown:"
echo "NOTHING — a quiet day" > "$T/reply.txt"
BEFORE="$(snap)"
OUT="$(review)"
P="$(cat "$T/prompt-last" 2>/dev/null)"
check "her spoken half reaches the judge" contains "$P" "Status: three wakes booked"
refute "the display half does not" contains "$P" "DISPLAYNOISE"
refute "a job's entry does not" contains "$P" "BUILDERNOISE"
check "the flag reaches the judge" contains "$P" "status-report cadence"
check "the persona sheet reaches the judge" contains "$P" "Report your state as a status list"
check "the conduct drawer reaches the judge" contains "$P" "Policy 4.2"
check "the recalled records reach the judge with their ids" contains "$P" "#11 [directive]"
check "recall is asked to peek, so no record's standing moves" \
    contains "$(cat "$T/crab-calls")" "--peek"
check "the entry whose replacement fired is shown" contains "$P" 'replace: `\bStatus:'
check "NOTHING is said on the night log" contains "$OUT" "claudism-review: nothing to change"
check_eq "and changes nothing" "$(snap)" "$BEFORE"
refute "no rewrite or forget was asked" contains "$(cat "$T/crab-calls")" "memory rewrite"

echo
echo "the edits it may make:"
: > "$T/crab-calls"
cat > "$T/reply.txt" <<'EOF'
EDITS
[
 {"route": "memory-rewrite", "id": 11, "text": "I keep my bookkeeping to myself unless he asks.", "why": "third person procedure"},
 {"route": "memory-retire", "id": 12, "why": "only the assistant's voice"},
 {"route": "file-edit", "file": "persona", "old": "Report your state as a status list when asked how you are.", "new": "When he asks how I am, I say how I feel.", "why": "invites the status report"},
 {"route": "file-edit", "file": "conduct/say-less.md", "old": "Policy 4.2: the assistant shall minimise verbosity.", "new": "I say less.", "why": "policy voice"},
 {"route": "file-edit", "file": "phrase-list", "old": "- replace: `\\bStatus:\\s*` -> `Right now, `\n", "new": "", "why": "the swap read badly"}
]
EOF
OUT="$(review)"
check "a record is reworded through crab memory rewrite" \
    contains "$(cat "$T/crab-calls")" "memory rewrite 11 I keep my bookkeeping to myself unless he asks."
check "a record is retired through crab memory forget" \
    contains "$(cat "$T/crab-calls")" "memory forget 12"
check "the persona line is replaced" contains "$(cat "$T/persona.md")" "When he asks how I am, I say how I feel."
check "the rest of the persona sheet stands" contains "$(cat "$T/persona.md")" "Be haughty."
check_eq "the conduct body is replaced" "$(cat "$H/conduct/say-less.md")" "I say less."
refute "the replacement line is revoked" contains "$(cat "$T/claudisms.md")" "replace:"
check "the entry itself stands" contains "$(cat "$T/claudisms.md")" "## status-report cadence"
B="$H/sleep/claudism-review/$DAY"
check "the persona sheet was copied aside first" contains "$(cat "$B/persona.md" 2>/dev/null)" "Report your state as a status list"
check "and the conduct file" contains "$(cat "$B/say-less.md" 2>/dev/null)" "Policy 4.2"
check "every edit is a line on the log" contains "$OUT" "claudism-review: 5 edit(s) made"
refute "no wake is booked" contains "$(cat "$T/crab-calls")" "wake-at"

echo
echo "the guards:"
cp "$B/persona.md" "$T/persona.md"
cp "$B/say-less.md" "$H/conduct/say-less.md"
cp "$B/claudisms.md" "$T/claudisms.md"
rm -rf "$H/sleep"
: > "$T/crab-calls"
cat > "$T/reply.txt" <<'EOF'
EDITS
[
 {"route": "memory-rewrite", "id": 77, "text": "x", "why": "never shown"},
 {"route": "memory-rewrite", "id": 13, "text": "x", "why": "an episodic record"},
 {"route": "file-edit", "file": "../../etc/passwd", "old": "root", "new": "x", "why": "outside"},
 {"route": "file-edit", "file": "persona", "old": "absent text", "new": "x", "why": "not there"},
 {"route": "file-edit", "file": "phrase-list", "old": "## status-report cadence", "new": "## new entry", "why": "not a replace line"}
]
EOF
BEFORE="$(snap)"
OUT="$(review)"
check "a record never shown is refused" contains "$OUT" "record #77 was not shown tonight"
check "an episodic record is refused" contains "$OUT" "only directives and notes are edited"
check "a file outside the drawer is refused" contains "$OUT" "is not a file the review may edit"
check "old text that is not there exactly once is refused" contains "$OUT" "occurs 0 times"
check "the phrase list takes only replace lines" contains "$OUT" "only \`- replace:\` line changes"
check_eq "nothing changed" "$(snap)" "$BEFORE"
refute "nothing reached crab memory" contains "$(cat "$T/crab-calls")" "memory rewrite"

echo
echo "the cap:"
: > "$T/crab-calls"
cat > "$T/reply.txt" <<'EOF'
EDITS
[
 {"route": "memory-retire", "id": 11, "why": "a"},
 {"route": "memory-retire", "id": 12, "why": "b"}
]
EOF
OUT="$(review CLAUDISM_REVIEW_MAX_EDITS=1)"
check "edits past the cap are named" contains "$OUT" "over the cap of 1"
check_eq "and only the capped number is made" "$(grep -c 'memory forget' "$T/crab-calls")" "1"

echo
echo "the dry run:"
: > "$T/crab-calls"
BEFORE="$(snap)"
OUT="$(review CLAUDISM_REVIEW_DRY_RUN=1)"
check "prints what it would do" contains "$OUT" 'claudism-review: would {"route": "memory-retire"'
check_eq "and changes nothing" "$(snap)" "$BEFORE"
refute "and asks crab memory for nothing but recall" contains "$(cat "$T/crab-calls")" "memory forget"
