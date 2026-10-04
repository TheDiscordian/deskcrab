#!/bin/bash
# Sleep's claudism review — specs/nightly.md rules 39-44. Run:
# bash tests/test_claudism_review.sh
#
# What the judge is shown (spoken halves, never a job's entry or the display
# half; the tidy's prose under its own housekeeping heading, never as speech;
# the score, speech and housekeeping apart and each over its own words; the
# flags; the persona sheet; the conduct drawer; the recalled records with
# their ids), and what the review may change: a record reworded or
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
{"epoch": 1758315600, "time": "2026-09-20T03:20:00-0400", "kind": "tidy", "user": "", "reply": "Nightly tidy 2026-09-20: TIDYNOTE two shelf lines refreshed."}
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
# Rule 40: the tidy's note is hers, so it is shown — under its own heading,
# labelled as housekeeping, never as something she said aloud.
SPEECH="${P#*=== THE DAY (}"; SPEECH="${SPEECH%%=== THE DAY\'S HOUSEKEEPING*}"
HOUSE="${P#*=== THE DAY\'S HOUSEKEEPING}"; HOUSE="${HOUSE%%=== THE SCORE*}"
check "the tidy's prose is kept, under the housekeeping heading" \
    contains "$HOUSE" "her, in a housekeeping note no one hears: Nightly tidy 2026-09-20: TIDYNOTE"
refute "and is not in her speech" contains "$SPEECH" "TIDYNOTE"
refute "nor labelled as said aloud anywhere" contains "$P" "her, aloud: Nightly tidy"
check "her speech stays under its own heading" contains "$SPEECH" "her, aloud: Status: three wakes booked"
refute "and is not in the housekeeping" contains "$HOUSE" "three wakes booked"
check "the judge is told what housekeeping is" \
    contains "$P" "never change what governs her speech on housekeeping evidence alone"
check "the score reaches the judge" \
    contains "$P" "$DAY, spoken: 7 words — status-report-cadence 1 use, 142.86 per 1,000."
check "and the night log, in the review's name" \
    contains "$OUT" "claudism-review: $DAY, spoken: 7 words — status-report-cadence 1 use, 142.86 per 1,000."
check "housekeeping scored over its own words" \
    contains "$OUT" "claudism-review: $DAY, housekeeping: 8 words — status-report-cadence 0 uses, 0.00 per 1,000."
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

# --- Rule 40a: the score --------------------------------------------------
# The fixture holds 2026-08-18's own counts: eleven wake replies of 546 spoken
# words with no proof-of-work use, the tidy's note of 178 words with two, and
# a builder's 492-word log. Pooled, that day read 2.76 per 1,000 — wrong about
# both registers. Every place a count could leak in from carries bait: the
# job's entry, every display half, a fenced block, and a quoted mention.
python3 - "$T" <<'FIXTURE'
import json, os, sys
T = sys.argv[1]
HIT = "The shelf check ran and 33 passed."            # 7 words, one use
MENTION = 'The phrase list still carries "33 passed" as an entry.'
DISPLAY = "\n---DISPLAY---\n47 passed, 0 failed in the table"

def filler(n):
    """n words in short sentences, none of them a listed move."""
    return " ".join(" ".join(["rain"] * (min(i + 12, n) - i)) + "."
                    for i in range(0, n, 12))

def spoken(n, lead=""):
    return (lead + " " + filler(n - len(lead.split()))).strip() if n else ""

def day(name, date, wakes, tidy, job=True):
    os.makedirs(os.path.join(T, name), exist_ok=True)
    rows, epoch = [], 1787040000
    if tidy is not None:
        rows.append({"epoch": epoch, "time": date + "T03:22:00-0400",
                     "kind": "tidy", "user": "", "reply": tidy})
    if job:
        rows.append({"epoch": epoch + 1, "time": date + "T03:17:03-0400",
                     "kind": "job", "pid": 9, "user": "builder brief",
                     "reply": "33 passed. " + filler(490)})
    for i, text in enumerate(wakes):
        rows.append({"epoch": epoch + 100 + i,
                     "time": "%sT%02d:00:00-0400" % (date, 4 + i),
                     "kind": "wake", "pid": 100 + i, "user": "a wake",
                     "reply": text + DISPLAY})
    with open(os.path.join(T, name, date + ".jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

def tidy(n):
    return HIT + " The drawer check ran and 12 passed. " + filler(n - 14)

SIZES = [86, 61, 43, 57, 60, 102, 0, 0, 85, 49, 3]    # the real day's replies
def wakes(scale=1, hit=False):
    out = []
    for i, n in enumerate(SIZES):
        if i == 0 and hit:
            out.append(spoken(n * scale, HIT))
        elif i == 1:
            out.append(spoken(n * scale, MENTION))
        elif i == 2:
            out.append(spoken(n * scale) + "\n```\n47 passed in a fence\n```")
        else:
            out.append(spoken(n * scale))
    return out

# The curve's earlier nights: one without a tidy note, one with.
for name in ("j818", "j818-loud", "j818-hit", "j818-hit-long"):
    day(name, "2026-08-16", [spoken(500)], None)
    day(name, "2026-08-17", [spoken(1000, HIT)], HIT + " " + filler(193))
day("j818", "2026-08-18", wakes(), tidy(178))
day("j818-loud", "2026-08-18", wakes(scale=10), tidy(178))
day("j818-hit", "2026-08-18", wakes(hit=True), tidy(178))
day("j818-hit-long", "2026-08-18", wakes(hit=True), tidy(1780))
day("j-house", "2026-08-18", [], "Nightly tidy 2026-08-18: HOUSEONLY note.", job=False)
FIXTURE
cat > "$T/list818.md" <<'EOF'
## reciting counts as proof — "33 passed, 0 failed"
- pattern: `\b\d+ passed\b`
- function: proof-of-work
- fix: delete
- live: no
EOF

score() {   # <journal dir> [VAR=value ...]
    local dir="$1"; shift
    env DAY_JOURNAL_DIR="$T/$dir" CLAUDISMS_FILE="$T/list818.md" \
        "$@" "$REPO/lib/claudism-review" score 2026-08-18 2>&1
}
run818() {  # <journal dir>
    env CRAB_BIN="$T/crab" DAY_JOURNAL_DIR="$T/$1" CLAUDISM_FLAGS_DIR="$T/flags" \
        CLAUDISMS_FILE="$T/list818.md" CUSTOM_PROMPT="$T/persona.md" \
        WANTS_FILE="$H/wants.md" NIGHT_JUDGE_MODEL=gpt-5.6-sol \
        DESKCRAB_CODEX_STATE="$T/cx-state" \
        "$REPO/lib/claudism-review" run 2026-08-18 2>&1
}
photo() { find "$T/j818" "$H" -type f -exec md5sum {} + | sort | md5sum; }

echo
echo "the score — speech and housekeeping apart (rule 40a):"
BEFORE="$(photo)"
S="$(score j818)"
check "546 spoken words with no proof-of-work use read 0.00 per 1,000" \
    contains "$S" "2026-08-18, spoken: 546 words — proof-of-work 0 uses, 0.00 per 1,000."
check "178 tidy words with two read 11.24 per 1,000" \
    contains "$S" "2026-08-18, housekeeping: 178 words — proof-of-work 2 uses, 11.24 per 1,000."
refute "the pooled 2.76 is printed nowhere" contains "$S" "2.76"
refute "nor the pooled 724 words" contains "$S" "724"
check "the spoken denominator is printed under its own rates" \
    contains "$S" "| spoken words | 500 | 1000 | 546 |"
check "with the rate one use prints there" contains "$S" "| one use reads as | 2.00 | 1.00 | 1.83 |"
check "the spoken curve, night over night" contains "$S" "| proof-of-work | 0.00 | 1.00 | 0.00 |"
check "the housekeeping denominator is its own; a night with no note is a gap" \
    contains "$S" "| housekeeping words |  | 200 | 178 |"
check "the housekeeping curve, the gap not a zero" \
    contains "$S" "| proof-of-work |  | 5.00 | 11.24 |"
check "and its own resolution row" contains "$S" "| one use reads as |  | 5.00 | 5.62 |"
check_eq "the score door writes nothing" "$(photo)" "$BEFORE"

echo
echo "neither rate moves with the other series' words:"
S="$(score j818-loud)"
check "ten times the speech: the spoken denominator grows" \
    contains "$S" "2026-08-18, spoken: 5460 words — proof-of-work 0 uses, 0.00 per 1,000."
check "and the housekeeping rate holds still" \
    contains "$S" "2026-08-18, housekeeping: 178 words — proof-of-work 2 uses, 11.24 per 1,000."
S="$(score j818-hit)"
check "one spoken use in 546 words reads 1.83" \
    contains "$S" "2026-08-18, spoken: 546 words — proof-of-work 1 use, 1.83 per 1,000."
S="$(score j818-hit-long)"
check "ten times the housekeeping: its own rate falls" \
    contains "$S" "2026-08-18, housekeeping: 1780 words — proof-of-work 2 uses, 1.12 per 1,000."
check "and the spoken rate holds still" \
    contains "$S" "2026-08-18, spoken: 546 words — proof-of-work 1 use, 1.83 per 1,000."

echo
echo "the curve's length, and a list that cannot be read:"
S="$(score j818 CLAUDISM_REVIEW_TREND_NIGHTS=2)"
check "the knob shortens the curve" contains "$S" "| spoken words | 1000 | 546 |"
refute "and the night before it is gone" contains "$S" "2026-08-16"
{ cat "$T/list818.md"; printf '%s\n' '## a broken entry' '- pattern: `(unclosed`'; } > "$T/list-broken.md"
S="$(score j818 CLAUDISMS_FILE="$T/list-broken.md")"
check "an entry that will not compile is counted on the score's own line" \
    contains "$S" "1 line(s) of the phrase list could not be read and scored nothing"
check "and the entries that ran still score" \
    contains "$S" "2026-08-18, housekeeping: 178 words — proof-of-work 2 uses, 11.24 per 1,000."
S="$(score j818 CLAUDISMS_FILE="$T/no-such-list.md")"
check "no phrase list: said plainly" contains "$S" "No phrase list was found"
check "and the words are still counted" \
    contains "$S" "2026-08-18, housekeeping: 178 words — nothing caught."
S="$(env DAY_JOURNAL_DIR="$T/j818" CLAUDISMS_FILE="$T/list818.md" \
        "$REPO/lib/claudism-review" score 2026-08-01 2>&1)"
check "a day with no journal has nothing to score" contains "$S" "no journal for 2026-08-01"

echo
echo "the same score reaches the judge and the night log:"
echo "NOTHING — a quiet day" > "$T/reply.txt"
rm -f "$T/prompt-last"
OUT="$(run818 j818)"
P="$(cat "$T/prompt-last" 2>/dev/null)"
for line in \
    "2026-08-18, spoken: 546 words — proof-of-work 0 uses, 0.00 per 1,000." \
    "2026-08-18, housekeeping: 178 words — proof-of-work 2 uses, 11.24 per 1,000." \
    "| proof-of-work |  | 5.00 | 11.24 |"; do
    check "the judge reads: $line" contains "$P" "$line"
    check "the night log carries it" contains "$OUT" "claudism-review: $line"
done
HOUSE="${P#*=== THE DAY\'S HOUSEKEEPING}"; HOUSE="${HOUSE%%=== THE SCORE*}"
check "the tidy's caught sentences are in front of the judge, as housekeeping" \
    contains "$HOUSE" "The drawer check ran and 12 passed."
refute "every night-log line of the score opens with the review's name" \
    contains "$(printf '%s\n' "$OUT" | grep -v '^claudism-review: ')" "per 1,000"

echo
echo "a day of housekeeping alone is still reviewed:"
rm -f "$T/prompt-last"
OUT="$(run818 j-house)"
P="$(cat "$T/prompt-last" 2>/dev/null)"
check "the judge is asked" contains "$OUT" "claudism-review: reviewing the day of 2026-08-18"
check "the note is shown" \
    contains "$P" "her, in a housekeeping note no one hears: Nightly tidy 2026-08-18: HOUSEONLY note."
check "and her speech is said to be empty" contains "$P" "(she said nothing aloud today)"
check "the spoken series has no point on its curve" \
    contains "$OUT" "claudism-review: 2026-08-18, spoken: no words — no point on this curve."
