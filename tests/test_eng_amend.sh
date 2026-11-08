#!/bin/bash
# Supersession on the record spine — specs/engineering-records.md rules 7a
# and 9a. An amendment that retires an earlier instruction marks the named
# paragraph where it stands (words kept, under a dated marker), `current`
# renders the record with that paragraph as its stub, and
# `quotes-superseded` finds a retired sentence quoted in a brief. Nothing is
# inferred from position: only the door, naming the paragraph, retires
# anything. Run: bash tests/test_eng_amend.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
ENG="$SANDBOX/records"
mkdir -p "$ENG"
E() { DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" "$@"; }
W() { DESKCRAB_WANTS_DIR="$SANDBOX/wants" python3 "$REPO/lib/eng" --kind want "$@"; }
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

echo "the fixture: one opening entry of three requirements, then a plain touch:"
ID="$(E new 'The move prompt prints both memory blocks' --summary 'two blocks, one prompt' --body 'Add the exact block to the move prompt: when exact_lines is non-empty, return before the similar section so the two never print together.

Keep the similar block as the fallback, with its win and loss counts attached.

Reword the exact header: the position was seen, by whichever side, and the result is what matters.')"
E touch "$ID" 'Verified by reading memory_sections myself: both blocks are emitted with no guard.' >/dev/null
OPENED="$(E field "$ID" opened)"
T0="$(E field "$ID" last_touched)"
cp "$ENG/$ID.md" "$SANDBOX/before.md"
check "current on a record with nothing superseded is byte-identical to its file" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" current "$3" | cmp -s - "$1/$3.md"' _ "$ENG" "$REPO" "$ID"
refute "quotes-superseded has nothing to find on such a record" \
    bash -c 'printf "%s" "return before the similar section so the two never print together" | DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" quotes-superseded "$3"' _ "$ENG" "$REPO" "$ID"

echo
echo "the refusals write nothing (rule 7a):"
out="$(E amend "$ID" 'A note that retires nothing' 2>&1)"; rc=$?
check_eq "an amendment naming no paragraph is refused" "$rc" "2"
check "and names touch as the door for a plain note" contains "$out" "eng touch"
out="$(E amend "$ID" --supersedes 'the greenhouse latch' 'No such words' 2>&1)"; rc=$?
check_eq "no match is refused" "$rc" "2"
check "in plain words" contains "$out" "no live paragraph"
out="$(E amend "$ID" --supersedes 'block' 'Too little to tell them apart' 2>&1)"; rc=$?
check_eq "an ambiguous match is refused" "$rc" "2"
check "naming the count" contains "$out" "ambiguous: 3 live paragraphs"
out="$(E amend "$ID" --supersedes "$OPENED" 'A heading is not a paragraph' 2>&1)"; rc=$?
check_eq "an entry heading is never a candidate" "$rc" "2"
out="$(E amend "$ID" --supersedes 'exact block' --supersedes 'return before the similar' 'Twice the same' 2>&1)"; rc=$?
check_eq "two texts naming one paragraph are refused" "$rc" "2"
check "and say so" contains "$out" "name the same paragraph"
check "every refusal left the file unchanged" cmp -s "$ENG/$ID.md" "$SANDBOX/before.md"
check_eq "and last_touched unmoved" "$(E field "$ID" last_touched)" "$T0"
mkdir -p "$SANDBOX/wants"
WID="$(W new 'A want to keep playing' --body 'Keep playing chess at night.')"
out="$(W amend "$WID" --supersedes 'chess' 'Wants are journals' 2>&1)"; rc=$?
check "the wants drawer has no amend door" test "$rc" -ne 0

echo
echo "an amendment retires exactly the named paragraph (rule 7a):"
sleep 1
out="$(E amend "$ID" --supersedes 'return before the similar section' 'Decided: the exact block leaves the move prompt entirely. The similar block alone is the memory; no guard-return is built.')"; rc=$?
check_eq "amend exits clean" "$rc" "0"
check "and reports one paragraph superseded" contains "$out" "1 paragraph superseded"
T1="$(E field "$ID" last_touched)"
check "last_touched moved" test "$T1" != "$T0"
check_eq "the id is preserved" "$(E field "$ID" id)" "$ID"
check_eq "the title is preserved" "$(E field "$ID" title)" "The move prompt prints both memory blocks"
check_eq "opened is preserved" "$(E field "$ID" opened)" "$OPENED"
check_eq "the state stands" "$(E field "$ID" state)" "open"
FILE="$(cat "$ENG/$ID.md")"
check "the retired paragraph stands under the dated marker" \
    contains "$FILE" "> SUPERSEDED $T1 (history, not an instruction):
> Add the exact block to the move prompt: when exact_lines is non-empty, return before the similar section so the two never print together."
check "its neighbour before it is untouched" \
    contains "$FILE" "
Keep the similar block as the fallback, with its win and loss counts attached.
"
check "and its neighbour after it" \
    grep -qxF "Reword the exact header: the position was seen, by whichever side, and the result is what matters." "$ENG/$ID.md"
check "the plain touch is untouched" contains "$FILE" "both blocks are emitted with no guard"
check "the amendment heads the body" \
    bash -c 'sed -n "/^---$/,/^---$/!p" "$1" | grep -m1 "^## " | grep -q "^## $2$"' _ "$ENG/$ID.md" "$T1"
check "carrying its note" contains "$FILE" "the exact block leaves the move prompt entirely"
check "and naming the place it retired, not the words" \
    contains "$FILE" "Supersedes paragraph 1 of the $OPENED entry"
check "show keeps the whole history, marker and words" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "^> Add the exact block to the move prompt"' _ "$ENG" "$REPO" "$ID"
check_eq "the marker appears exactly once" "$(grep -c '^> SUPERSEDED' "$ENG/$ID.md")" "1"

echo
echo "current renders the stub in its place and none of the retired words (rule 9a):"
CUR="$(E current "$ID")"
check "the stub stands where the paragraph was" \
    contains "$CUR" "(a paragraph here was superseded by the amendment of $T1 — history, not an instruction; crab eng show $ID keeps it)"
refute "the retired words are gone from the view" contains "$CUR" "return before the similar section"
refute "no marker line rides the view" contains "$CUR" "SUPERSEDED"
check "the live neighbours ride" contains "$CUR" "Keep the similar block as the fallback"
check "so does the amendment" contains "$CUR" "The similar block alone is the memory"
check "the frontmatter rides whole" contains "$CUR" "id: $ID"
check "with its state" contains "$CUR" "state: open"
check "the view is one stub shorter than the file, nothing else moved" \
    bash -c 'diff <(printf "%s\n" "$1") "$2" | grep -c "^[<>]" | grep -qx 3' _ "$CUR" "$ENG/$ID.md"

echo
echo "quotes-superseded finds a retired sentence through case and whitespace (rule 9a):"
printf 'In the repo, from the record: make memory_sections return before the\n  similar section SO the two never print together, then verify.\n' > "$SANDBOX/brief-stale"
out="$(E quotes-superseded "$ID" "$SANDBOX/brief-stale")"; rc=$?
check_eq "a brief quoting the retired sentence is found (exit 0)" "$rc" "0"
check "and the sentence is named" contains "$out" "return before the similar section"
printf 'Keep the similar block as the fallback with counts; reword the exact header; verify with the chess suites.\n' > "$SANDBOX/brief-clean"
out="$(E quotes-superseded "$ID" "$SANDBOX/brief-clean")"; rc=$?
check_eq "a brief built from the live paragraphs is clean (exit 1)" "$rc" "1"
check_eq "and names nothing" "$out" ""
check "stdin is the default source" \
    bash -c 'printf "%s" "*When exact_lines is non-empty, return before the similar section* so the two never print together" | DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" quotes-superseded "$3" >/dev/null' _ "$ENG" "$REPO" "$ID"
refute "five words are the floor: a short coincidence is not a quotation" \
    bash -c 'printf "the exact block" | DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" quotes-superseded "$3" >/dev/null' _ "$ENG" "$REPO" "$ID"

echo
echo "a second amendment, two paragraphs in one write, and the retired one refused again:"
out="$(E amend "$ID" --supersedes 'return before the similar section' 'Again' 2>&1)"; rc=$?
check_eq "a paragraph already retired is refused" "$rc" "2"
check "naming the amendment that retired it" contains "$out" "already superseded (by the amendment of $T1)"
cp "$ENG/$ID.md" "$SANDBOX/before2.md"
sleep 1
out="$(E amend "$ID" --supersedes 'Reword the exact header' --supersedes 'both blocks are emitted' 'The header dies with the block, and the reading note is history.')"; rc=$?
check_eq "two paragraphs retire in one write" "$rc" "0"
check "and the report counts them" contains "$out" "2 paragraphs superseded"
T2="$(E field "$ID" last_touched)"
check "last_touched moved once more" test "$T2" != "$T1"
check_eq "three markers now stand" "$(grep -c '^> SUPERSEDED' "$ENG/$ID.md")" "3"
check_eq "two of them from this amendment" "$(grep -c "^> SUPERSEDED $T2 " "$ENG/$ID.md")" "2"
check "the note names both places — the reading note's first paragraph" \
    bash -c 'grep -q "Supersedes paragraph 1 of the $2 entry, paragraph 3 of the $3 entry" "$1"' _ "$ENG/$ID.md" "$T0" "$OPENED"
check_eq "the one amendment added exactly one entry" \
    "$(( $(grep -c '^## ' "$ENG/$ID.md") - $(grep -c '^## ' "$SANDBOX/before2.md") ))" "1"
CUR="$(E current "$ID")"
check_eq "current shows three stubs" "$(printf '%s\n' "$CUR" | grep -c 'a paragraph here was superseded')" "3"
check "and still the one live requirement" contains "$CUR" "Keep the similar block as the fallback"
refute "and none of the retired words" contains "$CUR" "Reword the exact header"
printf 'Reword the exact header: the position was seen, by whichever side, and the result is what matters.\n' > "$SANDBOX/brief-stale2"
check "a newly retired sentence is found in a brief" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" quotes-superseded "$3" "$4" >/dev/null' _ "$ENG" "$REPO" "$ID" "$SANDBOX/brief-stale2"
