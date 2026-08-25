#!/bin/bash
# The report may not call a night clean while a list entry never compiled —
# specs/nightly.md rule 40a. A pattern that fails to compile is skipped by the
# scan, so the night's silence says nothing about it: a no-catch headline must
# say what ran and count what did not, the broken fact must stand in or before
# the headline rather than as a correction after it, and only an all-compiling
# list may earn "a clean night". Run:
# bash tests/test_claudism_report_broken.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$T/journal"
OUT="$T/claudisms-out"
LIST="$T/claudisms.md"
mkdir -p "$J"

# The door, logged only — the scan's wake booking is not under test here.
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

echo "one entry that will not compile, a night that catches nothing:"
cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway.

## a pattern that cannot compile
- pattern: `([`
- why: this entry never ran, so the night is not clean.
LIST
cat > "$J/2026-02-01.jsonl" <<'DAY'
{"epoch": 1769958000, "time": "2026-02-01T10:00:00-0500", "kind": "desktop", "user": "morning", "reply": "Tea first."}
DAY
out="$(scan 2026-02-01 2>&1)"; rc=$?
check_eq "the scan exits clean" "$rc" "0"
[ -f "$OUT/2026-02-01.md" ] || die "no report at $OUT/2026-02-01.md" "$out"
R="$(cat "$OUT/2026-02-01.md")"
case "$R" in
    *"a clean night"*) fail "a broken entry forbids the clean-night verdict (rule 40a)" "$R" ;;
    *) ok "the report never says a clean night while an entry did not run" ;;
esac
check "the headline says nothing was caught among the entries that ran, and counts the one that did not" \
    contains "$R" "Nothing caught among the entries that ran — 1 list entry would not compile."
check "the detailed warning still names the entry and why" \
    contains "$R" "would not compile and was skipped: a pattern that cannot compile"

echo
echo "a caught night with the same broken entry: the fact stands before the verdict:"
cat > "$J/2026-02-02.jsonl" <<'DAY'
{"epoch": 1770044400, "time": "2026-02-02T10:00:00-0500", "kind": "desktop", "user": "did it land?", "reply": "Honestly, the timer is set."}
DAY
scan 2026-02-02 >/dev/null 2>&1
R2="$OUT/2026-02-02.md"
check "the caught night still reports its use-hit" \
    contains "$(cat "$R2")" "use-hit"
b_line="$(grep -n "would not compile" "$R2" | head -1 | cut -d: -f1)"
h_line="$(grep -n "use-hit" "$R2" | head -1 | cut -d: -f1)"
if [ -n "$b_line" ] && [ -n "$h_line" ] && [ "$b_line" -lt "$h_line" ]; then
    ok "the broken-entry fact comes before the headline, never as a correction after"
else
    fail "the reader must learn the scan ran short before any verdict (rule 40a)" \
        "broken at line [$b_line], headline at line [$h_line]"
fi
check "and says the counts cover only the entries that ran" \
    contains "$(cat "$R2")" "did not run — the counts below cover only the entries that did"

echo
echo "two broken entries: the count is plural:"
cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway.

## a pattern that cannot compile
- pattern: `([`
- why: this entry never ran.

## another that cannot compile
- pattern: `(?P<`
- why: nor did this one.
LIST
cat > "$J/2026-02-03.jsonl" <<'DAY'
{"epoch": 1770130800, "time": "2026-02-03T10:00:00-0500", "kind": "desktop", "user": "morning", "reply": "Tea first."}
DAY
scan 2026-02-03 >/dev/null 2>&1
check "the headline counts both, plural" \
    contains "$(cat "$OUT/2026-02-03.md")" "Nothing caught among the entries that ran — 2 list entries would not compile."

echo
echo "the control: an all-compiling list and no catches is still a clean night:"
cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway.
LIST
cat > "$J/2026-02-04.jsonl" <<'DAY'
{"epoch": 1770217200, "time": "2026-02-04T10:00:00-0500", "kind": "desktop", "user": "morning", "reply": "Tea first."}
DAY
scan 2026-02-04 >/dev/null 2>&1
R4="$(cat "$OUT/2026-02-04.md")"
check "the clean-night headline is exactly as it was" \
    contains "$R4" "Nothing caught — a clean night."
case "$R4" in
    *"would not compile"*) fail "no broken entries, no broken warning" "$R4" ;;
    *) ok "and no broken warning appears" ;;
esac
