#!/bin/bash
# A clean night must carry its own power — specs/nightly.md rule 48a. The
# fault was measured on 2026-09-16: the de-duplicated catch rate held flat at
# about 0.60 uses per 1000 spoken words across every window, while the nightly
# volume fell from tens of thousands of words to a few hundred, so three
# "clean night" headlines in a row described the word count and were read as
# the habit. Where the record holds a baseline, the report AND the morning
# agenda state the catches those words should have carried and the odds an
# honest night that size comes up empty anyway. With no baseline, both read
# exactly as they did before. Run:
# bash tests/test_claudism_clean_power.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$T/journal"
OUT="$T/claudisms-out"
LIST="$T/claudisms.md"
mkdir -p "$J" "$OUT"

cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
CRAB
chmod +x "$T/crab"

cat > "$LIST" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- function: vouching
- why: assumed of her anyway.
LIST

scan() {
    CRAB_BIN="$T/crab" DAY_JOURNAL_DIR="$J" CLAUDISM_LIST="$LIST" \
        CLAUDISM_DIR="$OUT" CLAUDISM_FLAGS_DIR="$T/flags" CLAUDISM_REWRITES=0 \
        "$REPO/lib/claudism-scan" run "$@"
}
agenda() { grep '^wake-at ' "$T/crab-calls" 2>/dev/null | tail -1; }

# A quiet, catchless day of roughly N spoken words.
day_of_words() {  # day, words
    local n=$2 text=""
    local i=0
    while [ "$i" -lt "$n" ]; do text="$text tea "; i=$((i + 1)); done
    printf '{"epoch": 1772377200, "time": "%sT10:00:00-0500", "kind": "desktop", "user": "morning", "reply": "%s"}\n' \
        "$1" "$text" > "$J/$1.jsonl"
}

echo "no baseline yet — the headline reads exactly as it always did:"
day_of_words 2026-03-01 40
scan 2026-03-01 >/dev/null 2>&1
R1="$OUT/2026-03-01.md"
check "the clean headline stands alone" \
    contains "$(cat "$R1")" "Nothing caught — a clean night."
case "$(cat "$R1")" in
    *"standing rate"*) fail "four nights and no history is not a baseline" "$(cat "$R1")" ;;
    *) ok "and claims no power it has not earned" ;;
esac

echo
echo "a baseline in the record: six prior nights, 24000 words, 14 uses:"
cat > "$OUT/functions.tsv" <<'TSV'
2026-02-20	vouching	3	0	4000
2026-02-21	vouching	2	0	4000
2026-02-22	vouching	3	0	4000
2026-02-23	vouching	2	0	4000
2026-02-24	vouching	2	0	4000
2026-02-25	vouching	2	0	4000
TSV

echo
echo "a 200-word clean night: the likeliest outcome on volume alone:"
rm -f "$T/crab-calls"
day_of_words 2026-03-02 200
scan 2026-03-02 >/dev/null 2>&1
R2="$(cat "$OUT/2026-03-02.md")"
check "the headline still says clean" contains "$R2" "Nothing caught — a clean night."
check "the standing rate is stated per 1000 words" contains "$R2" "At the standing rate of 0.58 per 1000 words"
check "with the catches those words should have carried" contains "$R2" "should have carried about 0.1 catches"
check "and what a clean night that size actually means" \
    contains "$R2" "news about how little was said, not about the habit"
check "the morning agenda takes the same branch" \
    contains "$(agenda)" "a clean night. At the standing rate of 0.58 per 1000 words"

echo
echo "a 9000-word clean night at the same rate: that one is worth something:"
rm -f "$T/crab-calls"
day_of_words 2026-03-03 9000
scan 2026-03-03 >/dev/null 2>&1
R3="$(cat "$OUT/2026-03-03.md")"
check "the same arithmetic, the other verdict" \
    contains "$R3" "should have carried about 5.2 catches — a clean night this size comes up empty on volume alone"
check "and that verdict is that an empty night this long means something" \
    contains "$R3" "so it is worth something."
case "$R3" in
    *"news about how little was said"*) fail "9000 words is not a short day" "$R3" ;;
    *) ok "and it is never called news about the word count" ;;
esac
check "the agenda carries the earned verdict too" \
    contains "$(agenda)" "so it is worth something"

echo
echo "a night that caught something says nothing about power at all:"
rm -f "$T/crab-calls"
cat > "$J/2026-03-04.jsonl" <<'DAY'
{"epoch": 1772636400, "time": "2026-03-04T10:00:00-0500", "kind": "desktop", "user": "did it land?", "reply": "Honestly, the timer is set."}
DAY
scan 2026-03-04 >/dev/null 2>&1
R4="$(cat "$OUT/2026-03-04.md")"
case "$R4" in
    *"standing rate"*) fail "the power line belongs to a clean night only" "$R4" ;;
    *) ok "a caught night keeps its catch and its rewrite, and nothing else" ;;
esac
