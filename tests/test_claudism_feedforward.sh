#!/bin/bash
# The recent-catches block: her freshest flags named by their own list
# headings and quoted as she said them, stale flags aged out, one line per
# pattern however often it fired, and a broken log costing the block and
# nothing else — never the prompt.
# Run: bash tests/test_claudism_feedforward.sh
#
# specs/prompt-assembly.md rule 35. Feed-forward only: this reader must never
# be able to break an assembly, so every failure path here asserts on empty
# stdout and a zero exit, not on an error.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

FF="$SANDBOX_REPO/lib/claudism-feedforward"
D="$XDG_DATA_HOME/deskcrab"
FLAGS="$D/claudism-flags"
LIST="$D/claudisms.md"
mkdir -p "$FLAGS"

NOW=$(date +%s)
TODAY=$(date +%Y-%m-%d)

cat > "$LIST" <<'EOF'
# Claudisms

## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: he assumes it, so the word carries nothing.

## the reflex concession
- pattern: `\b(?:absolutely|completely) right\b`
- why: caving dressed as agreement.
EOF

flag() {  # <epoch> <sentence> <pattern-as-json-escaped>
    printf '{"epoch": %s, "time": "%s", "kind": "desktop", "pid": 1234, "sentence": "%s", "pattern": "%s"}\n' \
        "$1" "$(date -d "@$1" +%Y-%m-%dT%H:%M:%S%z)" "$2" "$3"
}
HONEST='\\bhonest(?:y|ly)?\\b'
CONCEDE='\\b(?:absolutely|completely) right\\b'

echo "fresh flags: named by heading, quoted, deduped, newest first:"
{
    flag $((NOW - 7200)) "Honestly, the wake fired twice." "$HONEST"
    flag $((NOW - 3600)) "You are absolutely right about the config." "$CONCEDE"
    flag $((NOW - 600))  "To be honest the test was green." "$HONEST"
} > "$FLAGS/$TODAY.jsonl"

OUT="$("$FF")"; RC=$?
check "reader exits 0 on a good log" [ "$RC" -eq 0 ]
check "block opens with its own header" contains "$OUT" "RECENT CLAUDISM CATCHES"
check "a flag is named by its list heading, not its regex" contains "$OUT" "the honesty family"
check "the line is quoted as she said it" contains "$OUT" "To be honest the test was green."
check "where the rest is, by path" contains "$OUT" "$FLAGS"
refute "a pattern appears once however often it fired" \
    contains "$OUT" "Honestly, the wake fired twice"
check "newest first: the honesty catch sits above the concession" \
    [ "$(grep -n 'the honesty family' <<< "$OUT" | head -1 | cut -d: -f1)" -lt \
      "$(grep -n 'the reflex concession' <<< "$OUT" | head -1 | cut -d: -f1)" ]

echo
echo "a stale flag is aged out:"
flag $((NOW - 60)) "Honestly, again." "$HONEST" > "$FLAGS/$TODAY.jsonl"
OUT="$(CLAUDISM_FEEDFORWARD_HOURS=0.001 "$FF")"
check "flags past the freshness window produce nothing" [ -z "$OUT" ]

echo
echo "no flags, no dir, unreadable records: empty and quiet:"
rm -f "$FLAGS/$TODAY.jsonl"
OUT="$("$FF")"; check "an empty flag dir produces nothing" [ -z "$OUT" ]
rm -rf "$FLAGS"
OUT="$("$FF")"; RC=$?
check "a missing flag dir produces nothing" [ -z "$OUT" ]
check "and still exits 0" [ "$RC" -eq 0 ]
mkdir -p "$FLAGS"
printf 'not json at all\n{"epoch": "also-bad"}\n' > "$FLAGS/$TODAY.jsonl"
OUT="$("$FF")"; RC=$?
check "a log of unparseable lines produces nothing" [ -z "$OUT" ]
check "and exits 0 rather than failing the assembly" [ "$RC" -eq 0 ]

echo
echo "a missing phrase list only costs the naming:"
flag $((NOW - 60)) "Honestly, once more." "$HONEST" > "$FLAGS/$TODAY.jsonl"
rm -f "$LIST"
OUT="$("$FF")"
check "with no list the flag still shows, quoted as said" \
    contains "$OUT" "Honestly, once more."

echo
echo "the assembled layer carries the block (prompt-assembly rule 35):"
run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }
cat > "$LIST" <<'EOF'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: he assumes it.
EOF
TURN="$(run 'build_system_prompt --profile turn')"
check "a turn's L4 closes with the catches" contains "$TURN" "RECENT CLAUDISM CATCHES"
check "named by the list heading" contains "$TURN" "the honesty family"
JOBP="$(run 'build_system_prompt --profile job')"
refute "a job profile carries no catches" contains "$JOBP" "RECENT CLAUDISM CATCHES"
rm -rf "$FLAGS"
TURN="$(run 'build_system_prompt --profile turn')"
refute "no flags, no block — the layer just assembles without it" \
    contains "$TURN" "RECENT CLAUDISM CATCHES"

echo
echo "a mention is not shown, and a function names the move (rule 35):"
mkdir -p "$FLAGS"
STAMP="$(date -d "@$NOW" +%Y-%m-%dT%H:%M:%S%z)"
printf '{"epoch": %s, "time": "%s", "kind": "desktop", "pid": 9, "sentence": "He told me to drop the hedge from the line.", "pattern": "%s", "use": "mention", "function": "vouching"}\n' \
    "$NOW" "$STAMP" "$HONEST" > "$FLAGS/$TODAY.jsonl"
OUT="$("$FF")"; RC=$?
check "a log of only mentions produces nothing" [ -z "$OUT" ]
check "and exits 0" [ "$RC" -eq 0 ]
printf '{"epoch": %s, "time": "%s", "kind": "desktop", "pid": 9, "sentence": "Honestly, the fan is fine.", "pattern": "%s", "use": "use", "function": "vouching"}\n' \
    "$NOW" "$STAMP" "$HONEST" >> "$FLAGS/$TODAY.jsonl"
OUT="$("$FF")"
check "the use beside it is shown" contains "$OUT" "Honestly, the fan is fine."
check "and filed under its function" contains "$OUT" "(the vouching move)"
refute "the mention stayed out of the block" contains "$OUT" "drop the hedge"
