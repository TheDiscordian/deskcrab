#!/bin/bash
# The rule-54 ratchet watch, with a denominator — specs/speech-output.md
# rule 54's nightly-watch paragraph. Run: bash tests/test_claudism_ratchet.sh
#
# The fault this pins (the record rule-54-s-ratchet-has-no-denominator-so-it-has-b):
# the watch counted phrasings inside the repaired lines only, so any phrase she
# habitually uses looked "added and never removed" simply because repairs are
# sentences she wrote — eight lines fired ever, all false or worthless. The
# assertions here are the amended rule's four cases:
#   (a) a phrase FLAT across nights at ~1.1 per 1000 spoken words draws no
#       ratchet line, whatever its share of the repaired lines;
#   (b) a phrase whose rate across ALL spoken words genuinely climbs night
#       over night draws one;
#   (c) a persona signature — "in fact", "I suppose", from the named
#       suppression list — never draws one, whatever its share;
#   (d) a gram a loaded pattern already covers never prints "on no list
#       here"; the clause is computed, and the covering entry is named.
# Plus the 2026-08-20 noise shape: a flagged sub-gram of an equally-counted
# flagged gram is one tic, not two lines.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$T/journal"
OUT="$T/claudisms-out"
LIST="$T/claudisms.md"
SIGS="$T/persona-signatures.md"
FLAGS="$T/flags"
mkdir -p "$J" "$FLAGS"

cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
CRAB
chmod +x "$T/crab"

scan() {
    CRAB_BIN="$T/crab" DAY_JOURNAL_DIR="$J" CLAUDISM_LIST="$LIST" \
        CLAUDISM_DIR="$OUT" CLAUDISM_FLAGS_DIR="$FLAGS" \
        CLAUDISM_SIGNATURES="$SIGS" CLAUDISM_REWRITES=0 \
        "$REPO/lib/claudism-scan" run "$@"
}
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

cat > "$LIST" <<'LIST'
## you're absolutely right
- pattern: `\babsolutely right\b`
- why: the reflex concession; agreement needs no superlative.
- function: capitulation
LIST

# The persona-signature list — the single named place the suppression reads.
cat > "$SIGS" <<'SIGS'
# Phrases that are genuinely mine — never a ratchet, whatever the numbers say
- `in fact` — named as hers outright, 2026-08-10.
- `I suppose`
SIGS

# Four journal nights, ~900 filler tokens each, phrase counts controlled:
#   "for the record"    1,1,1,1  — flat at ~1.1 per 1000 spoken words (case a)
#   "as it happens"     1,2,4,8  — genuinely climbing, on no list (case b)
#   "in fact"           1,2,4,8  — climbing AND a signature (case c)
#   "I suppose"         1,2,4,8  — climbing AND a signature (case c)
#   "absolutely right"  1,2,4,8  — climbing AND on the loaded list (case d)
# Night three also carries a job row and a display half stuffed with the
# climbing phrase: if either leaked into the denominator's population, the
# third prior rate would tower over tonight's and case (b) could not fire —
# so (b) firing proves the population is spoken halves only, jobs excluded.
FILLER="$(printf 'kettle tea toast jam spoon cup pot lid tray crumb %.0s' $(seq 1 90))"
night() { # night <date> <epoch> <aih-count>  (other phrases ride along)
    local d="$1" ep="$2" k="$3" body="$FILLER for the record kettle tea"
    local i
    for i in $(seq 1 "$k"); do
        body="$body as it happens spoon cup in fact pot lid I suppose tray crumb absolutely right kettle tea"
    done
    printf '{"epoch": %s, "time": "%sT10:00:00-0500", "kind": "desktop", "user": "?", "reply": "%s"}\n' \
        "$ep" "$d" "$body" > "$J/$d.jsonl"
}
night 2026-03-01 1772377200 1
night 2026-03-02 1772463600 2
night 2026-03-03 1772550000 4
# the two would-be leaks into night three's population:
printf '{"epoch": 1772550100, "time": "2026-03-03T11:00:00-0500", "kind": "job", "user": "build", "reply": "%s"}\n' \
    "$(printf 'as it happens %.0s' $(seq 1 30))" >> "$J/2026-03-03.jsonl"
printf '{"epoch": 1772550200, "time": "2026-03-03T12:00:00-0500", "kind": "desktop", "user": "?", "reply": "Tea is up.\\n---DISPLAY---\\n%s"}\n' \
    "$(printf 'as it happens %.0s' $(seq 1 20))" >> "$J/2026-03-03.jsonl"
night 2026-03-04 1772636400 8

# Tonight's flag log: six repaired pairs. The flat phrase and both signatures
# are added by EVERY repair — the maximal share, the exact shape the old watch
# convicted on. The climbing phrases are added by three. No before carries any
# of them, so nothing is ever "removed".
cat > "$FLAGS/2026-03-04.jsonl" <<'FLAGS'
{"epoch": 1772636401, "time": "2026-03-04T10:00:01-0500", "kind": "desktop", "stage": "live", "outcome": "rewrite", "before": "The kettle is on now.", "after": "The kettle is on, for the record, and warm in fact, so tea soon I suppose, as it happens beside the absolutely right cup."}
{"epoch": 1772636402, "time": "2026-03-04T10:00:02-0500", "kind": "desktop", "stage": "live", "outcome": "rewrite", "before": "Toast is done here.", "after": "Toast is done, for the record, browned in fact, with jam I suppose, as it happens on the absolutely right plate."}
{"epoch": 1772636403, "time": "2026-03-04T10:00:03-0500", "kind": "desktop", "stage": "live", "outcome": "rewrite", "before": "The tray went up.", "after": "The tray went up, for the record, early in fact, still warm I suppose, as it happens by the absolutely right window."}
{"epoch": 1772636404, "time": "2026-03-04T10:00:04-0500", "kind": "desktop", "stage": "live", "outcome": "rewrite", "before": "The pot is empty.", "after": "The pot is empty, for the record, rinsed in fact, drying I suppose."}
{"epoch": 1772636405, "time": "2026-03-04T10:00:05-0500", "kind": "desktop", "stage": "live", "outcome": "rewrite", "before": "The lid is cracked.", "after": "The lid is cracked, for the record, glued in fact, holding I suppose."}
{"epoch": 1772636406, "time": "2026-03-04T10:00:06-0500", "kind": "desktop", "stage": "live", "outcome": "rewrite", "before": "The spoon is bent.", "after": "The spoon is bent, for the record, old in fact, kept I suppose."}
FLAGS

echo "the ratchet watch, with a denominator:"
out="$(scan 2026-03-04 2>&1)"; rc=$?
check_eq "the scan exits clean" "$rc" "0"
R="$OUT/2026-03-04.md"
[ -f "$R" ] && ok "the dated report exists" || die "no report at $R" "$out"
CURE="$(awk '/## The cure shaping the voice/{f=1;next} /^## /{f=0} f' "$R")"
[ -n "$CURE" ] && ok "the rule-54 section is present — something genuinely fired" \
    || die "no rule-54 section at all" "$(cat "$R")"

echo
echo "(b) a rate climbing across ALL spoken words is named, with its trail:"
check "the climbing phrase draws the ratchet line" \
    contains "$CURE" 'the rewrites added “as it happens” to 3 of 6 repaired lines'
check "and the line carries the night-over-night rates, not the share alone" \
    contains "$CURE" "climbing night over night"
check "and (b) firing proves jobs and display halves stayed out of the denominator" \
    contains "$CURE" "as it happens"

echo
echo "(a) a flat phrase never fires, whatever its share of the repaired lines:"
refute "six of six repaired lines convict nothing when the day's rate is flat" \
    contains "$CURE" "for the record"
refute "nor do its sub-grams" contains "$CURE" "the record"

echo
echo "(c) persona signatures are suppressed unconditionally:"
refute "“in fact” never draws a line — maximal share, climbing rate and all" \
    contains "$CURE" "in fact"
refute "“I suppose” never draws a line either" contains "$CURE" "i suppose"

echo
echo "(d) the closing clause is computed, never asserted:"
AR="$(printf '%s\n' "$CURE" | grep 'absolutely right' | head -1)"
[ -n "$AR" ] && ok "a climbing gram a loaded pattern covers still draws its line" \
    || fail "the listed climbing gram drew no line" "$CURE"
refute "but never the words “on no list here”" contains "$AR" "on no list here"
check "the covering entry is named instead" contains "$AR" "already on the list"
check "by its own title" contains "$AR" "you're absolutely right"
check "while the unlisted gram's clause genuinely comes back empty" \
    contains "$(printf '%s\n' "$CURE" | grep 'as it happens' | head -1)" "on no list here"

echo
echo "the 2026-08-20 noise shape: one tic, one line:"
refute "an equally-counted sub-gram of a flagged gram is not its own line" \
    contains "$CURE" '“as it”'
refute "on either side" contains "$CURE" '“it happens”'

echo
echo "and a rise needs nights to stand on:"
rm -f "$J/2026-03-01.jsonl" "$J/2026-03-02.jsonl" "$J/2026-03-03.jsonl"
scan 2026-03-04 >/dev/null 2>&1
CURE2="$(awk '/## The cure shaping the voice/{f=1;next} /^## /{f=0} f' "$OUT/2026-03-04.md")"
refute "with no prior night in the population, nothing is a ratchet" \
    contains "$CURE2" "one-way ratchet"
