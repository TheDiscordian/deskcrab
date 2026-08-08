#!/bin/bash
# The nightly claudism review — specs/nightly.md rules 39 to 45. Run: bash
# tests/test_claudism_scan.sh
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
        CLAUDISM_DIR="$OUT" CLAUDISM_REWRITES=0 \
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
