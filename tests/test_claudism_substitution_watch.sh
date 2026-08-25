#!/bin/bash
# The substitution watch's verdict is computed, never asserted — specs/nightly.md
# rule 48. Run: bash tests/test_claudism_substitution_watch.sh
#
# The fault this pins (the record the-substitution-watch-says-when-the-total-holds):
# the churn note ended in a fixed tail, "when the total holds, the move changed
# words, it did not die", printed whatever the totals did — false in four of the
# first eleven notes ever emitted, over families that had fallen by half or more.
# The assertions here are the amended rule's cases:
#   (a) a family whose total genuinely holds (within one occurrence or a quarter
#       of the prior average) draws the substitution sentence, numbers beside it;
#   (b) a family whose total fell draws the fall — direction and size — and
#       never the words "the total holds";
#   (c) a family whose total grew says it grew, by how much;
#   (d) a family totalling one tonight draws nothing: that is arithmetic, not
#       evidence of substitution;
#   (e) a member first counted tonight cannot be the risen side — its empty
#       history is absence of measurement, not absence of the habit;
#   (f) no code path prints the premise without computing it: every "holds"
#       line in the report is re-measured here against its own numbers, and the
#       old unconditional tail is gone from the generator.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$T/journal"
OUT="$T/claudisms-out"
LIST="$T/claudisms.md"
FLAGS="$T/flags"
mkdir -p "$J" "$OUT" "$FLAGS"

cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
CRAB
chmod +x "$T/crab"

scan() {
    CRAB_BIN="$T/crab" DAY_JOURNAL_DIR="$J" CLAUDISM_LIST="$LIST" \
        CLAUDISM_DIR="$OUT" CLAUDISM_FLAGS_DIR="$FLAGS" \
        CLAUDISM_REWRITES=0 \
        "$REPO/lib/claudism-scan" run "$@"
}
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# Six two-member families, one per case. Every function name and phrase is
# fixture-only; nothing here is on any live list. Titles carry the quoted
# short-name-then-em-dash shape of the real list: classify_use scores a
# sentence containing the bare title as a mention of the entry itself, so a
# bare `## frankly` heading would turn every fixture sentence into a mention
# and the watch would never see a use.
cat > "$LIST" <<'LIST'
## "honestly" — vouching decoration
- pattern: `\bhonestly\b`
- why: vouching decoration.
- function: vouching

## "frankly" — the neighbouring vouch
- pattern: `\bfrankly\b`
- why: the same vouch in a neighbouring word.
- function: vouching

## "to be fair" — concession decoration
- pattern: `\bto be fair\b`
- why: concession decoration.
- function: conceding

## "in fairness" — the same concession elsewhere
- pattern: `\bin fairness\b`
- why: the same concession elsewhere.
- function: conceding

## "i must say" — performance opener
- pattern: `\bi must say\b`
- why: performance opener.
- function: performing

## "if i may" — performance opener, sibling
- pattern: `\bif i may\b`
- why: performance opener, sibling.
- function: performing

## "one tick" — the floor family's quiet member
- pattern: `\bone tick\b`
- why: the floor family's quiet member.
- function: noise

## "two tick" — the floor family's single occurrence
- pattern: `\btwo tick\b`
- why: the floor family's single occurrence.
- function: noise

## "old friend" — the quiet sibling of an entry created tonight
- pattern: `\bold friend\b`
- why: the quiet sibling of an entry created tonight.
- function: fresh

## "new tonight" — created tonight, no history to have risen from
- pattern: `\bnew tonight\b`
- why: created tonight — no history to have risen from.
- function: fresh

## "steady one" — the precondition guard
- pattern: `\bsteady one\b`
- why: no member quiet, no note — the precondition guard.
- function: steady

## "steady two" — its equally steady sibling
- pattern: `\bsteady two\b`
- why: its equally steady sibling.
- function: steady
LIST

# Two prior nights of counts, seeded the way update_counts writes them: every
# entry a row every night from the night it exists, zeros included. "new
# tonight" has NO prior rows — it is created tonight (case e). Tonight's rows
# come from the journal below:
#   vouching   honestly 2,2 -> 0   frankly 0,0 -> 2   total 2 vs ~2.0  holds
#   conceding  to-be-fair 4,4 -> 0 in-fairness 0,0 -> 2  total 2 vs ~4.0 fell 50%
#   performing i-must-say 1,1 -> 0 if-i-may 0,0 -> 3  total 3 vs ~1.0  grew 3.0x
#   noise      one-tick 1,1 -> 0   two-tick 0,0 -> 1  total 1: floored
#   fresh      old-friend 2,2 -> 0 new-tonight (none) -> 2: no risen side
#   steady     steady-one 1,1 -> 1 steady-two 1,1 -> 1: nothing quiet
cat > "$OUT/counts.tsv" <<'COUNTS'
2026-03-01	honestly	2
2026-03-01	frankly	0
2026-03-01	to-be-fair	4
2026-03-01	in-fairness	0
2026-03-01	i-must-say	1
2026-03-01	if-i-may	0
2026-03-01	one-tick	1
2026-03-01	two-tick	0
2026-03-01	old-friend	2
2026-03-01	steady-one	1
2026-03-01	steady-two	1
2026-03-02	honestly	2
2026-03-02	frankly	0
2026-03-02	to-be-fair	4
2026-03-02	in-fairness	0
2026-03-02	i-must-say	1
2026-03-02	one-tick	1
2026-03-02	if-i-may	0
2026-03-02	two-tick	0
2026-03-02	old-friend	2
2026-03-02	steady-one	1
2026-03-02	steady-two	1
COUNTS

printf '{"epoch": 1772550000, "time": "2026-03-03T10:00:00-0500", "kind": "desktop", "user": "?", "reply": "Frankly the kettle is on. Frankly the toast is done. In fairness the tray went up. In fairness the jam is out. If I may the pot is empty. If I may the lid is cracked. If I may the spoon is bent. Two tick the cup is chipped. New tonight the milk is cold. New tonight the butter is soft. Steady one the plate is warm. Steady two the bowl is dry."}\n' \
    > "$J/2026-03-03.jsonl"

echo "the scan runs and the watch section exists:"
out="$(scan 2026-03-03 2>&1)"; rc=$?
check_eq "the scan exits clean" "$rc" "0"
R="$OUT/2026-03-03.md"
[ -f "$R" ] && ok "the dated report exists" || die "no report at $R" "$out"
WATCH="$(awk '/## The substitution watch/{f=1;next} /^## /{f=0} f' "$R")"
[ -n "$WATCH" ] && ok "the substitution-watch section is present" \
    || die "no substitution-watch section at all" "$(cat "$R")"

echo
echo "(a) a total that genuinely holds says so, numbers beside the claim:"
VOUCH="$(printf '%s\n' "$WATCH" | grep -F 'inside **vouching**' | head -1)"
[ -n "$VOUCH" ] && ok "the vouching family draws its churn note" \
    || fail "no vouching note" "$WATCH"
check "the quiet and risen members are named" \
    contains "$VOUCH" "honestly went quiet while frankly rose"
check "the measured totals are printed" \
    contains "$VOUCH" "family total 2 tonight, ~2.0 a night before"
check "and the substitution claim is made" contains "$VOUCH" "the total holds"
check "in rule 48's words" contains "$VOUCH" "changed words"

echo
echo "(b) a total that fell says the fall, never the premise:"
CONC="$(printf '%s\n' "$WATCH" | grep -F 'inside **conceding**' | head -1)"
[ -n "$CONC" ] && ok "the conceding family still draws a note" \
    || fail "no conceding note" "$WATCH"
refute "but never the words 'the total holds'" contains "$CONC" "the total holds"
check "it says the total did not hold" contains "$CONC" "did not hold"
check "with the direction and the size" contains "$CONC" "fell by 50%"
check "and the weaker claim names where the weight went" \
    contains "$CONC" "moved to in-fairness"

echo
echo "(c) a total that grew says it grew, by how much:"
PERF="$(printf '%s\n' "$WATCH" | grep -F 'inside **performing**' | head -1)"
[ -n "$PERF" ] && ok "the performing family still draws a note" \
    || fail "no performing note" "$WATCH"
refute "never 'the total holds' here either" contains "$PERF" "the total holds"
check "the growth is measured" contains "$PERF" "grew 3.0x"

echo
echo "(d) a family total of one is arithmetic, not substitution:"
refute "no note at family total 1" contains "$WATCH" 'inside **noise**'

echo
echo "(e) a member first counted tonight is not a risen side:"
refute "the fresh family draws no note" contains "$WATCH" 'inside **fresh**'
refute "and the new entry is named nowhere in the watch" \
    contains "$WATCH" "new-tonight"

echo
echo "the precondition is unchanged — churn still needs a quiet member:"
refute "a steady family draws no note" contains "$WATCH" 'inside **steady**'

echo
echo "(f) the premise is computed, never asserted:"
refute "the old unconditional tail is gone from the generator" \
    grep -q "when the total holds" "$REPO/lib/claudism-scan"
HOLDS_LINES="$(printf '%s\n' "$WATCH" | grep "the total holds")"
[ -n "$HOLDS_LINES" ] && ok "there is a holds line to re-measure" \
    || fail "no holds line to re-measure (expected the vouching one)"
bad=0
while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    t="$(printf '%s' "$ln" | sed -n 's/.*family total \([0-9]*\) tonight.*/\1/p')"
    b="$(printf '%s' "$ln" | sed -n 's/.*~\([0-9.]*\) a night before.*/\1/p')"
    { [ -n "$t" ] && [ -n "$b" ]; } || { bad=1; continue; }
    awk -v t="$t" -v b="$b" 'BEGIN {
        d = t - b; if (d < 0) d = -d
        tol = b / 4; if (tol < 1) tol = 1
        exit !(d <= tol) }' || bad=1
done <<< "$HOLDS_LINES"
check_eq "every line claiming the total holds carries numbers that agree within rule 48's band" \
    "$bad" "0"
