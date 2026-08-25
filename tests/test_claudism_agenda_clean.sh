#!/bin/bash
# The morning agenda may not call a night clean while a list entry never
# compiled — specs/nightly.md rule 40a, its morning half. bc840c0 fixed the
# report's headline; the sentence actually READ at half nine is the wake's
# agenda, composed in cmd_run, and it must take the same branch from the same
# signal: with any entry broken the agenda never says "a clean night" and
# names what never ran, and only an all-compiling no-catch night keeps the
# clean wording. Run:
# bash tests/test_claudism_agenda_clean.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$T/journal"
OUT="$T/claudisms-out"
LIST="$T/claudisms.md"
mkdir -p "$J"

# The door, logged only — the booking itself is test_wake_bookers.sh's claim;
# here the claims are about the agenda's words.
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
agenda() { grep '^wake-at ' "$T/crab-calls" 2>/dev/null | tail -1; }

echo "one entry that will not compile, a night that catches nothing:"
cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway.

## a pattern that cannot compile
- pattern: `([`
- why: this entry never ran, so the night is not clean.
LIST
cat > "$J/2026-03-01.jsonl" <<'DAY'
{"epoch": 1772377200, "time": "2026-03-01T10:00:00-0500", "kind": "desktop", "user": "morning", "reply": "Tea first."}
DAY
out="$(scan 2026-03-01 2>&1)"; rc=$?
check_eq "the scan exits clean" "$rc" "0"
A="$(agenda)"
[ -n "$A" ] || die "no wake-at call was booked" "$(cat "$T/crab-calls" 2>/dev/null)"
case "$A" in
    *"a clean night"*) fail "a broken entry forbids the clean-night agenda (rule 40a)" "$A" ;;
    *) ok "the agenda never says a clean night while an entry did not run" ;;
esac
check "the agenda says plainly that an entry never compiled" \
    contains "$A" "caught nothing among the entries that ran — 1 list entry would not compile and did not run"
check "and names the entry that never ran" \
    contains "$A" "did not run: a pattern that cannot compile"
check "still booked through the door, in the review's name, at its hour" \
    contains "$A" "wake-at --by claudism-review 09:30 event Your nightly claudism review of 2026-03-01 caught nothing"

echo
echo "a caught night with the same broken entry: the agenda carries the fact too:"
rm -f "$T/crab-calls"
cat > "$J/2026-03-02.jsonl" <<'DAY'
{"epoch": 1772463600, "time": "2026-03-02T10:00:00-0500", "kind": "desktop", "user": "did it land?", "reply": "Honestly, the timer is set."}
DAY
scan 2026-03-02 >/dev/null 2>&1
A2="$(agenda)"
check "the caught night's agenda still opens as it always did" \
    contains "$A2" "Your nightly claudism review of 2026-03-02 is written"
check "and carries the broken fact beside the report's path" \
    contains "$A2" "1 list entry would not compile and did not run"
case "$A2" in
    *"a clean night"*) fail "a caught night's agenda has no business saying clean" "$A2" ;;
    *) ok "and never says a clean night" ;;
esac

echo
echo "the control: an all-compiling list and no catches keeps the clean agenda:"
rm -f "$T/crab-calls"
cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed of her anyway.
LIST
cat > "$J/2026-03-03.jsonl" <<'DAY'
{"epoch": 1772550000, "time": "2026-03-03T10:00:00-0500", "kind": "desktop", "user": "morning", "reply": "Tea first."}
DAY
scan 2026-03-03 >/dev/null 2>&1
A3="$(agenda)"
check "the genuinely clean night keeps its clean wording, word for word" \
    contains "$A3" "Your nightly claudism review of 2026-03-03 caught nothing — a clean night. The report and the running counts:"
case "$A3" in
    *"would not compile"*) fail "no broken entries, no broken sentence" "$A3" ;;
    *) ok "and no broken sentence appears" ;;
esac
