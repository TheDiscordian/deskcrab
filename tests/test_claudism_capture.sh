#!/bin/bash
# The claudism capture: the listening half of the nightly review. A turn that
# delivered a reply appends its spoken claudisms to the day's flag log —
# detached, silent, detection only, never a gate on the tongue.
# specs/turn-pipeline.md rules 30-32.
# Run: bash tests/test_claudism_capture.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D"
LIST="$D/claudisms.md"
FLAGS="$D/claudism-flags"

cat > "$LIST" <<'EOF'
# Claudisms — phrases that are not mine

Prose above the entries, which the parser must read past, even when it
quotes a `code span` of its own.

## the honesty family
- pattern: `\bhonest(ly)?\b`
- why: a why line quoting `a code span` must never become a pattern.

## the throat-clear
- pattern: `to be clear`
- why: the brochure clears its throat before it says anything.

## broken on purpose
- pattern: `[broken(regex`
- why: an unparseable entry is skipped, never fatal.
EOF

REPLY='Honestly, the fan curve was the problem. This sentence is clean.
To be clear, nothing else moved.
---DISPLAY---
Honestly this decoy lives in the display half and must never be flagged.'

echo "the scanner, run the way the turn runs it:"
"$SANDBOX_REPO/lib/claudism-capture" "$LIST" "$FLAGS" desktop 1786230000 4242 "$REPLY"
check_eq "exit status is quiet" "$?" "0"
DAY=$(date -d @1786230000 +%F)
FLAGFILE="$FLAGS/$DAY.jsonl"
check "the day's flag file exists" [ -s "$FLAGFILE" ]
check_eq "two sentences flagged, no more" "$(sandbox_count_in . "$FLAGFILE")" "2"
check "the honest opener is flagged" contains "$(cat "$FLAGFILE")" "Honestly, the fan curve"
check "the throat-clear is flagged" contains "$(cat "$FLAGFILE")" "To be clear, nothing else moved."
check "a flag carries the journal identity" contains "$(cat "$FLAGFILE")" '"epoch": 1786230000'
check "and the heading that names the claudism" contains "$(cat "$FLAGFILE")" '"note": "the honesty family"'
refute "the display half is never scanned" contains "$(cat "$FLAGFILE")" "decoy"
refute "a clean sentence is not flagged" contains "$(cat "$FLAGFILE")" "This sentence is clean"
refute "a why line's code span is not a pattern" contains "$(cat "$FLAGFILE")" "a code span"

echo
echo "a list in the older shape — first span per entry — still reads:"
cat > "$D/plain.md" <<'EOF'
- `to be clear` — the brochure's throat-clear, bulleted plainly.
EOF
"$SANDBOX_REPO/lib/claudism-capture" "$D/plain.md" "$D/plain-flags" desktop 1786230000 4242 "$REPLY"
check "the fallback shape flags too" contains "$(cat "$D/plain-flags/$(date -d @1786230000 +%F).jsonl")" "To be clear, nothing else moved."

echo
echo "rule 32 — failure is quiet and flagless:"
"$SANDBOX_REPO/lib/claudism-capture" "$D/absent.md" "$FLAGS" desktop 1786230000 4242 "$REPLY"
check_eq "a missing list exits 0" "$?" "0"
check_eq "and adds no flags" "$(sandbox_count_in . "$FLAGFILE")" "2"
"$SANDBOX_REPO/lib/claudism-capture" "$LIST" "$FLAGS" desktop 1786230000 4242 '---DISPLAY---
honestly: all display, no voice'
check_eq "a voiceless reply adds no flags" "$(sandbox_count_in . "$FLAGFILE")" "2"

echo
echo "rule 30 — the turn hands the reply over, detached:"
sandbox_bash 'SESSION_START=1786230000 fire_claudism_capture desktop "honestly a wired test"'
check "the detach asked the user manager for a unit" contains "$(sandbox_systemd_calls)" "claudism-capture"
check "and handed it the phrase list" contains "$(sandbox_systemd_calls)" "$LIST"
check_eq "the stubbed unit ran nothing, so no flag moved" "$(sandbox_count_in . "$FLAGFILE")" "2"

echo
echo "and with no user manager, the setsid fallback still captures:"
sandbox_systemd_rc 1
sandbox_bash 'SESSION_START=1786230000 fire_claudism_capture desktop "honestly, through the fallback"'
for _ in 1 2 3 4 5 6 7 8 9 10; do
    contains "$(cat "$FLAGFILE" 2>/dev/null)" "through the fallback" && break
    sleep 0.5
done
check "the fallback wrote a real flag" contains "$(cat "$FLAGFILE")" "through the fallback"

echo
echo "functions, fixes, and the mention class (turn-pipeline rule 31):"
cat > "$D/tagged.md" <<'LIST'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- why: assumed anyway.
- function: vouching
- fix: delete

## the wider net
- pattern: `\bI made sure\b`
- why: the urge, one construction further out.
- function: proof-of-work
- live: no
LIST
TAGREPLY='Honestly, the kettle is on. He told me to stop writing "honestly" at the desk. I made sure the door was shut.'
"$SANDBOX_REPO/lib/claudism-capture" "$D/tagged.md" "$D/tag-flags" desktop 1786230000 4242 "$TAGREPLY"
TAGFILE="$D/tag-flags/$DAY.jsonl"
check "the tag day's flag file exists" [ -s "$TAGFILE" ]
check "a use record carries its function" \
    contains "$(grep 'kettle' "$TAGFILE")" '"function": "vouching"'
check "and says it was a use" contains "$(grep 'kettle' "$TAGFILE")" '"use": "use"'
check "a quoted occurrence is recorded — the capture drops nothing" \
    contains "$(cat "$TAGFILE")" "stop writing"
check "and classed a mention, never a use" \
    contains "$(grep 'stop writing' "$TAGFILE")" '"use": "mention"'
check "a live: no entry still reaches the capture" \
    contains "$(cat "$TAGFILE")" "I made sure the door was shut."
