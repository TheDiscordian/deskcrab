#!/bin/bash
# The nightly shelf-line check — specs/nightly.md rules 21a and 21b. A shelf
# line is a line: an entry over the byte budget is named with its size and
# the wants/<slug>.md document its history belongs in; a genuinely one-line
# shelf is silent; the record stands in the state block until a clean check
# removes it; and the check never rewrites a byte of the shelf.
# Run: bash tests/test_shelf_check.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/wants" "$D/conduct"

CLEAN_SHELF='# Wants

<!-- a rebuilt header, carrying no numeric claim of its own -->

- 🎼 **Learn to read a score** → score.md
- 🌱 **Keep a window box** — the seedlings are up → window-box.md
- 📻 **Build the little radio** → radio.md'
printf '%s\n' "$CLEAN_SHELF" > "$D/wants.md"

cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS=""
EOF

REC="$DESKCRAB_STATE_PREFIX-shelf-overruns.txt"
run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

echo "a genuinely one-line shelf is silent:"
out="$("$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check_eq "the check exits zero" "$rc" "0"
check "and says so in one line, in its own name" contains "$out" "shelf-check:"
check_eq "one line exactly" "$(printf '%s\n' "$out" | grep -c .)" "1"
check "no record stands" [ ! -s "$REC" ]

echo
echo "an over-long entry is named with its size and its document:"
# ~640 bytes of history riding the line — the 2026-08-07 failure in miniature.
TAIL="$(printf 'the history that belongs in the document %.0s' $(seq 1 16))"
printf -- '- 🔭 **Notice the weeks** — %s → noticing.md\n' "$TAIL" >> "$D/wants.md"
SUM_BEFORE="$(md5sum < "$D/wants.md")"
out="$("$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check "the check exits non-zero" [ "$rc" -ne 0 ]
check "the flagged line is named by its title" contains "$out" "Notice the weeks"
check "with its measured size in bytes" grep -qE '[0-9]{3,} bytes' <<<"$out"
check "and the document its history belongs in" contains "$out" "wants/noticing.md"
check "the record stands" [ -s "$REC" ]
check "carrying the size and the slug" grep -qP '^[0-9]{3,}\tnoticing\.md\t' "$REC"
check "and the budget it was measured against" grep -q 'budget=500' "$REC"
SUM_AFTER="$(md5sum < "$D/wants.md")"
check_eq "the shelf is byte-identical — the check reports, never rewrites" \
    "$SUM_AFTER" "$SUM_BEFORE"

echo
echo "the record surfaces where she will see it:"
check "the state block renders it" \
    contains "$(run 'self_state_report')" "SHELF LINES OVER BUDGET"
check "naming the want's document" \
    contains "$(run 'self_state_report')" "wants/noticing.md"
check "and the assembled speaking prompt carries it" \
    contains "$(run 'build_system_prompt --profile turn')" "SHELF LINES OVER BUDGET"

echo
echo "a line that names no document is flagged as exactly that:"
printf -- '- **A drifting thought** — %s\n' "$TAIL" >> "$D/wants.md"
out="$("$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check "still non-zero" [ "$rc" -ne 0 ]
check "the documentless line is named" contains "$out" "A drifting thought"
check "and said to name no document" contains "$out" "names no document"

echo
echo "the budget is the config's to answer:"
out="$(WANTS_SHELF_LINE_BUDGET=100000 "$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check_eq "under a huge budget the same shelf is clean" "$rc" "0"
check "and the clean check removes the standing record" [ ! -s "$REC" ]
out="$("$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check "back at the default the overruns return" [ "$rc" -ne 0 ]
check "and so does the record" [ -s "$REC" ]

echo
echo "the shelf tidied by a person, the check goes quiet again:"
printf '%s\n' "$CLEAN_SHELF" > "$D/wants.md"
out="$("$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check_eq "clean again" "$rc" "0"
check "the record is removed" [ ! -s "$REC" ]
refute "and the state block carries nothing about the shelf" \
    contains "$(run 'self_state_report')" "SHELF LINES OVER BUDGET"

echo
echo "no shelf at all is a quiet nothing, not an error:"
rm -f "$D/wants.md"
out="$("$SANDBOX_REPO/lib/shelf-check")"; rc=$?
check_eq "a missing shelf exits zero" "$rc" "0"
check "and says so in the check's own name" contains "$out" "shelf-check:"
