#!/bin/bash
# The nightly claudism review — specs/nightly.md rules 39 to 45 — and, at the
# end, the live mirror's flag-log and family shape, specs/speech-output.md
# rules 51-52, held here beside the nightly reading that consumes it, plus
# the error-only subcall discipline of rules 7a/42a. Run:
# bash tests/test_claudism_scan.sh
#
# Detection and review only, so the assertions are about what the scan READS
# (the spoken half of her own replies — never his words, never a job's log,
# never the display half), what it WRITES (a dated report with the sentence
# and its timestamp; counts that replace rather than double), and that it is
# never silent: a wake through the door on a caught night and on a clean one.
# The one silent skip allowed is a missing phrase list — an empty habit, not
# an error.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$T/journal"
OUT="$T/claudisms-out"
LIST="$T/claudisms.md"
mkdir -p "$J"

# The door, logged only. The real wake_book is exercised by
# tests/test_wake_bookers.sh; here the claims are about the scan itself.
cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
CRAB
chmod +x "$T/crab"

scan() {
    CRAB_BIN="$T/crab" DAY_JOURNAL_DIR="$J" CLAUDISM_LIST="$LIST" \
        CLAUDISM_DIR="$OUT" CLAUDISM_FLAGS_DIR="$T/flags" CLAUDISM_REWRITES=0 \
        "$REPO/lib/claudism-scan" run "$@"
}
calls() { cat "$T/crab-calls" 2>/dev/null; }

cat > "$LIST" <<'LIST'
# What I keep reaching for

## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway, so the word carries nothing.

## you're absolutely right
- pattern: `\babsolutely right\b`
- why: the reflex concession; agreement needs no superlative.

## a pattern that cannot compile
- pattern: `([`
- why: proves a broken entry lands in the report instead of vanishing.
LIST

cat > "$J/2026-01-15.jsonl" <<'DAY'
{"epoch": 1705330800, "time": "2026-01-15T10:00:00-0500", "kind": "desktop", "user": "did it land?", "reply": "Honestly, the timer is set.\n  ---DISPLAY---  \nAn honest table, honestly too wide to speak."}
{"epoch": 1705334400, "time": "2026-01-15T11:00:00-0500", "kind": "phone", "user": "you're absolutely right about the kettle", "reply": "The kettle is on."}
{"epoch": 1705338000, "time": "2026-01-15T12:00:00-0500", "kind": "job", "user": "a build task", "reply": "Honestly the builder says honest things, honestly."}
{"epoch": 1705341600, "time": "2026-01-15T13:00:00-0500", "kind": "wake", "user": "", "reply": "You are absolutely right, and I am absolutely right to say so."}
DAY

echo "a caught night: the spoken half of her replies, and nothing else:"
out="$(scan 2026-01-15 2>&1)"; rc=$?
check_eq "the scan exits clean" "$rc" "0"
R="$OUT/2026-01-15.md"
[ -f "$R" ] && ok "the dated report exists" || die "no report at $R" "$out"
case "$(cat "$R")" in
    *"Honestly, the timer is set."*) ok "the offending sentence is quoted" ;;
    *) fail "the caught sentence must be quoted in full" "$(cat "$R")" ;;
esac
case "$(cat "$R")" in
    *"10:00"*) ok "with its timestamp beside it" ;;
    *) fail "a hit carries the time it was said" "$(cat "$R")" ;;
esac
case "$(cat "$R")" in
    *"too wide to speak"*) fail "the display half was reviewed as speech" "$(cat "$R")" ;;
    *) ok "the display half below an indented delimiter was not read" ;;
esac
case "$(cat "$R")" in
    *"builder says"*) fail "a job's entry was reviewed as her voice" "$(cat "$R")" ;;
    *) ok "a job's entry is a builder's log, not her voice" ;;
esac
case "$(cat "$R")" in
    *"about the kettle"*) fail "his words were reviewed" "$(cat "$R")" ;;
    *) ok "his words are never reviewed" ;;
esac
case "$(cat "$R")" in
    *"cannot compile"*"would not compile"*|*"would not compile"*)
        ok "the broken list entry is named in the report" ;;
    *) fail "a broken entry must land in the report, not vanish" "$(cat "$R")" ;;
esac

echo
echo "the counts: one line per night and phrase, replaced and never doubled:"
C="$OUT/counts.tsv"
check_eq "the honesty family counted once — above the delimiter only" \
    "$(awk -F'\t' '$1 == "2026-01-15" && $2 == "the-honesty-family" { print $3 }' "$C")" "1"
check_eq "absolutely-right counted once, from the wake's reply" \
    "$(awk -F'\t' '$1 == "2026-01-15" && $2 == "you-re-absolutely-right" { print $3 }' "$C")" "1"
before="$(wc -l < "$C")"
scan 2026-01-15 >/dev/null 2>&1
check_eq "a re-run of the same night leaves the same number of lines" \
    "$(wc -l < "$C")" "$before"

echo
echo "the surfacing: a wake through the door, caught nights and clean ones:"
case "$(calls)" in
    *"touching $OUT"*) ok "the writes were declared before they were made" ;;
    *) fail "undeclared writes wake her about her own hand" "$(calls)" ;;
esac
case "$(calls)" in
    *"wake-at --by claudism-review 09:30 event Your nightly claudism review of 2026-01-15 is written"*)
        ok "the caught night books a morning wake in the review's own name" ;;
    *) fail "a review she never hears about is surveillance" "$(calls)" ;;
esac
rm -f "$T/crab-calls"
cat > "$J/2026-01-16.jsonl" <<'DAY'
{"epoch": 1705417200, "time": "2026-01-16T10:00:00-0500", "kind": "desktop", "user": "morning", "reply": "Tea first."}
DAY
scan 2026-01-16 >/dev/null 2>&1
case "$(cat "$OUT/2026-01-16.md")" in
    *"clean night"*) ok "a clean night still writes its report" ;;
    *) fail "a clean night is a point on the curve" "$(cat "$OUT/2026-01-16.md")" ;;
esac
case "$(calls)" in
    *"wake-at --by claudism-review 09:30 event Your nightly claudism review of 2026-01-16 caught nothing"*)
        ok "and still books the wake — the review is never silent" ;;
    *) fail "a clean night must surface too" "$(calls)" ;;
esac

echo
echo "the two allowed skips, and both say so on stdout:"
rm -f "$T/crab-calls"
out="$(scan 2026-01-17 2>&1)"; rc=$?
check_eq "a day with no journal exits clean" "$rc" "0"
case "$out" in
    *"no journal for 2026-01-17"*) ok "and says there was nothing to review" ;;
    *) fail "a skipped day must say so" "$out" ;;
esac
mv "$LIST" "$LIST.away"
out="$(scan 2026-01-15 2>&1)"; rc=$?
mv "$LIST.away" "$LIST"
check_eq "a missing phrase list exits clean" "$rc" "0"
case "$out" in
    *"no phrase list"*) ok "and names the list it did not find" ;;
    *) fail "an empty habit is not an error, but it is a line" "$out" ;;
esac
check_eq "and neither skip booked a wake" "$(calls | grep -c wake-at)" "0"

echo
echo "the move, not the wording — functions, mentions, deletion, corroboration (rules 46-49):"
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }
cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway.
- function: vouching
- replace: `\b[Hh]onestly,\s+` -> ``

## decoration
- pattern: `\bgenuinely\b`
- why: the same move as honest, one word over.
- function: vouching
- fix: delete
LIST
cat > "$J/2026-01-20.jsonl" <<'DAY'
{"epoch": 1705762800, "time": "2026-01-20T10:00:00-0500", "kind": "desktop", "pid": 7001, "user": "?", "reply": "Honestly, the timer is set."}
{"epoch": 1705766400, "time": "2026-01-20T11:00:00-0500", "kind": "wake", "pid": 7002, "user": "", "reply": "He asked me to stop writing \"genuinely\" in my notes. I genuinely forgot the kettle."}
DAY
mkdir -p "$T/flags"
cat > "$T/flags/2026-01-20.jsonl" <<'FLAGS'
{"epoch": 1705766300, "time": "2026-01-20T10:58:20-0500", "kind": "wake", "pid": 7002, "sentence": "Honestly, I forgot the kettle.", "pattern": "\\bhonest(?:y|ly)?\\b", "stage": "live", "outcome": "rewrite", "function": "vouching"}
FLAGS
scan 2026-01-20 >/dev/null 2>&1
R="$OUT/2026-01-20.md"
check "the report scores by function, per 1000 words" \
    contains "$(cat "$R")" "By function, per 1000 spoken words"
check "two vouching uses aggregate across both entries" \
    contains "$(cat "$R")" "| vouching | 2 |"
check "the quoted sentence is set aside as a mention" \
    contains "$(cat "$R")" "Talking about the list"
check "and quoted there, visibly" contains "$(cat "$R")" "stop writing"
check_eq "the mention never reaches the counts" \
    "$(awk -F'\t' '$1 == "2026-01-20" && $2 == "decoration" { print $3 }' "$C")" "1"
check "functions.tsv carries uses, mentions, and the night's words" \
    contains "$(cat "$OUT/functions.tsv")" "2026-01-20	vouching	2	1"
check "a delete-fix catch gets its deletion with no model in the loop" \
    contains "$(cat "$R")" "instead (deletion): “The timer is set.”"
check "the deletion strikes the decoration and keeps the sentence" \
    contains "$(cat "$R")" "instead (deletion): “I forgot the kettle.”"
check "a live rewrite whose turn still fires the same move is named (rule 49)" \
    contains "$(cat "$R")" "still fires vouching"
refute "the corroboration names the reply's own sentence, not the held one" \
    contains "$(grep 'still fires vouching' "$R")" "Honestly, I forgot"

# Rule 50: the bare span comes away only when it is a free-standing adverb.
cat > "$J/2026-01-21.jsonl" <<'DAY'
{"epoch": 1705849200, "time": "2026-01-21T10:00:00-0500", "kind": "wake", "pid": 7101, "user": "", "reply": "Intermittent is the honest kind of hard. I put the kettle on honestly late."}
DAY
scan 2026-01-21 >/dev/null 2>&1
R="$OUT/2026-01-21.md"
refute "an adjective its noun sits on gets no mechanical deletion (rule 50)" \
    contains "$(cat "$R")" "is the kind of hard"
check "and the caught sentence is still quoted for the resay" \
    contains "$(cat "$R")" "the honest kind of hard"
check "an -ly adverb in the same sentence still comes away clean" \
    contains "$(cat "$R")" "instead (deletion): “I put the kettle on late.”"

echo
echo "the live mirror's log and call (speech-output rules 51-52):"
# The nightly reads what the mirror wrote, so the writer's shape is held
# here beside its reader: a rewrite row carries the words that went out,
# and the mirror call sees the fired entry's whole family — context for
# the resay, never a gate on it.
MLIST="$T/mirror-list.md"
cat > "$MLIST" <<'LIST'
## the honesty family
- pattern: `\bhonestly\b`
- why: assumed of her anyway.
- function: vouching

## decoration
- pattern: `\bgenuinely\b`
- why: the same move, one word over.
- function: vouching
- live: no

## flat apology
- pattern: `\bI apologize\b`
- why: another family entirely.
- function: apologising

## bare habit
- pattern: `\bneedless to say\b`
- why: an entry with no function at all.
LIST
MIRROR="$REPO/lib/claudism-mirror"

FAM="$("$MIRROR" family "$MLIST" vouching)"; rc=$?
check_eq "family exits clean" "$rc" "0"
check "the fired pattern is in its own family" contains "$FAM" 'honestly'
check "a live: no sibling is shown too — the wide net is visible at resay time" \
    contains "$FAM" 'genuinely'
refute "another function's entry stays out" contains "$FAM" 'apologize'
check_eq "an unknown function prints nothing and exits clean" \
    "$("$MIRROR" family "$MLIST" nosuch; echo "rc=$?")" "rc=0"
check_eq "a missing list prints nothing and exits clean — context, never a gate" \
    "$("$MIRROR" family "$T/absent.md" vouching; echo "rc=$?")" "rc=0"

FL="$T/flags-live"
printf '%s' '{"sentence": "Honestly, the kettle is on.", "pattern": "\\bhonestly\\b", "note": "the honesty family", "function": "vouching"}' \
    | "$MIRROR" logflag "$FL" wake 7002 rewrite "The kettle is on."
ROW="$(cat "$FL"/*.jsonl)"
check "a rewrite row carries the held sentence as before" \
    contains "$ROW" '"before": "Honestly, the kettle is on."'
check "and the words that replaced it as after (rule 51)" \
    contains "$ROW" '"after": "The kettle is on."'
printf '%s' '{"sentence": "Honestly, twice.", "pattern": "\\bhonestly\\b"}' \
    | "$MIRROR" logflag "$FL" wake 7003 original-mirror-failed
refute "a failed mirror logs no after — nothing replaced the line" \
    contains "$(tail -1 "$FL"/*.jsonl)" '"after"'

echo
echo "and both are wired through the whole-draft pass in lib/common.sh:"
cat > "$T/claude-stub" <<STUB
#!/bin/bash
cat > "$T/mirror-prompt.txt"
printf '%s\n' '{"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":"The kettle is on."}]}}'
printf '%s\n' '{"type":"result","result":"The kettle is on."}'
STUB
chmod +x "$T/claude-stub"
FL2="$T/flags-direct"
DIRECT="$(CLAUDE_BIN="$T/claude-stub" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL2" \
    sandbox_bash 'claudism_mirror_direct wake "Honestly, the kettle is on."')"
check_eq "the fired line was resaid in her stubbed voice" \
    "$DIRECT" "The kettle is on."
PROMPT="$(cat "$T/mirror-prompt.txt" 2>/dev/null)"
check "the call's prompt carries the family banner (rule 52)" \
    contains "$PROMPT" 'Its whole family (vouching)'
check "with the sibling visible at the moment of resaying" \
    contains "$PROMPT" 'genuinely'
ROW="$(cat "$FL2"/*.jsonl 2>/dev/null)"
check "the pass logged the rewrite with its words (rule 51)" \
    contains "$ROW" '"after": "The kettle is on."'
check "as a rewrite outcome, before/after like a table swap" \
    contains "$ROW" '"outcome": "rewrite"'
rm -f "$T/mirror-prompt.txt"
DIRECT="$(CLAUDE_BIN="$T/claude-stub" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL2" \
    sandbox_bash 'claudism_mirror_direct wake "Needless to say, tea is up."')"
refute "an entry with no function prompts exactly as before" \
    contains "$(cat "$T/mirror-prompt.txt" 2>/dev/null)" 'Its whole family'
cat > "$T/claude-stub2" <<STUB
#!/bin/bash
cat > "$T/mirror-prompt2.txt"
printf '%s\n' '{"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":"Genuinely: the kettle is on."}]}}'
printf '%s\n' '{"type":"result","result":"Genuinely: the kettle is on."}'
STUB
chmod +x "$T/claude-stub2"
DIRECT="$(CLAUDE_BIN="$T/claude-stub2" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL2" \
    sandbox_bash 'claudism_mirror_direct wake "Honestly, the kettle is on."')"
check_eq "a resay that lands on the sibling anyway still goes out — informed, never gated (rule 41)" \
    "$DIRECT" "Genuinely: the kettle is on."

echo
echo "an error-only stream: a main turn's report, a subcall's nothing (rules 7a/42a):"
# The live failure of 2026-08-20, 01:06 and 01:10: the mirror's resay hit an
# OAuth failure, extract-response stood the CLI's error text in as the reply
# (right for a main turn, its rule-7 shape), and the caller spliced it into
# the written reply in place of her sentence, logging outcome=rewrite. The
# stream below is that failure's shape verbatim.
AUTHERR="Failed to authenticate: OAuth session expired and could not be refreshed"
AUTHLOG="$T/auth-only.log"
cat > "$AUTHLOG" <<'LOG'
{"type":"assistant","message":{"model":"<synthetic>","id":"msg_err","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"is_api_error_message":true}
{"type":"result","result":"Failed to authenticate: OAuth session expired and could not be refreshed","is_error":true}
LOG
check_eq "without the flag, an error-only stream reports itself exactly as before (rule 7)" \
    "$(DESKCRAB_DEBUGLOG="$AUTHLOG" "$REPO/lib/extract-response")" "$AUTHERR"
check_eq "with the flag, the same stream prints nothing at all (rule 7a)" \
    "$(DESKCRAB_DROP_SYNTHETIC=1 DESKCRAB_DEBUGLOG="$AUTHLOG" "$REPO/lib/extract-response")" ""
cat > "$T/good.log" <<'LOG'
{"type":"assistant","message":{"model":"m","id":"msg_g","content":[{"type":"text","text":"The kettle is on."}]}}
{"type":"result","result":"The kettle is on."}
LOG
check_eq "a genuine reply extracts identically under the flag" \
    "$(DESKCRAB_DROP_SYNTHETIC=1 DESKCRAB_DEBUGLOG="$T/good.log" "$REPO/lib/extract-response")" \
    "The kettle is on."

echo
echo "and through the mirror: the draft stands, the row says the mirror failed (rule 42a):"
cat > "$T/claude-auth-stub" <<STUB
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","id":"msg_err","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"is_api_error_message":true}'
printf '%s\n' '{"type":"result","result":"Failed to authenticate: OAuth session expired and could not be refreshed","is_error":true}'
STUB
chmod +x "$T/claude-auth-stub"
FL3="$T/flags-auth"
DIRECT="$(CLAUDE_BIN="$T/claude-auth-stub" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL3" \
    sandbox_bash 'claudism_mirror_direct wake "Honestly, the kettle is on."')"
check_eq "an auth-failed mirror call leaves the draft exactly as written" \
    "$DIRECT" "Honestly, the kettle is on."
refute "the CLI's error text reaches the reply nowhere" \
    contains "$DIRECT" "Failed to authenticate"
ROW="$(cat "$FL3"/*.jsonl 2>/dev/null)"
check "the flag row reads original-mirror-failed" \
    contains "$ROW" '"outcome": "original-mirror-failed"'
refute "never rewrite — the receipt may not claim a catch that did not happen" \
    contains "$ROW" '"outcome": "rewrite"'
refute "and carries no after — nothing replaced the line" contains "$ROW" '"after"'
