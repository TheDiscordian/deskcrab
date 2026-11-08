#!/bin/bash
# The rotation seam: prompt-assembly.md rules 32 to 34. A rotation archives the
# transcript and deletes it, and before this the next prompt opened on an empty
# conversation layer that read exactly like nothing had ever been said. Now a
# rotation that succeeds leaves a marker, and the next assembled layer carries
# one line under its preamble saying the record restarted and when the previous
# one ended — a plain local stamp in the block headers' format, with the clock
# arithmetic left to her, plus one clause when the record had already been
# condensed before it was archived.
#
# The seam is a trace kept, not a judgement made, so most of what is asserted
# here is about it costing nothing:
#
#   1. a rotation without a summary leaves the marker, and the next layer says
#      the record ended — even with NOTHING new said, which is exactly when an
#      empty layer would lie
#   2. a rotation WITH a summary adds the condensed clause, once, on the same
#      line
#   3. a new conversation does not erase the seam, and the line sits under the
#      preamble, above the condensed summary and above the blocks
#   4. no marker at all — a first-ever conversation — means no line and the
#      layer exactly as it always was
#   5. a marker that cannot be parsed costs the line and nothing else
#   6. a rotation that FAILS writes no marker, and does not touch the one the
#      last successful rotation left
#   7. the next successful rotation replaces the marker
#
# Run: bash tests/test_convo_seam.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
ARCH="$T/archive"

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$T"
ARCHIVE_DIR="$ARCH"
JOBS_DIR="$T/jobs"
WAKES_DIR="$T/wakes"
DAY_JOURNAL_DIR="$T/journal"
NOTICE_STATE_DIR="$T/notice"
LAST_ORIGIN_FILE="$T/last-origin"
WANTS_FILE=""
WAKE_QUIET_HOURS=""
CONVO_TIMEOUT=300
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
EOF

CONVO="$DESKCRAB_STATE_PREFIX-convo.txt"
SUMMARY="$DESKCRAB_STATE_PREFIX-convo-summary.txt"
SEAM="$DESKCRAB_STATE_PREFIX-convo-seam.txt"

run() { DESKCRAB_NO_DISPATCH=1 sandbox_bash "$1" 2>/dev/null; }

write_convo() {
    printf 'User [2026-08-07 21:59]: name the next thing on your shelf\n' > "$CONVO"
    printf 'Assistant [2026-08-07 21:59]: Sheet music — obviously.\n\n' >> "$CONVO"
}

reset_all() {
    rm -rf "$ARCH"; mkdir -p "$ARCH"
    rm -f "$CONVO" "$SUMMARY" "$SEAM"
}

# The stamp the seam line must carry, from the same mtime the rotation reads.
IDLE_EPOCH=$(( $(date +%s) - 1000 ))
IDLE_STAMP="$(date -d "@$IDLE_EPOCH" '+%Y-%m-%d %H:%M')"

# --- 1: a rotation without a summary, and the empty record after it ---------

echo "seam — a successful rotation leaves the marker, and the empty layer says it:"
reset_all
write_convo
cp "$CONVO" "$T/expected-convo.txt"
touch -d "@$IDLE_EPOCH" "$CONVO"

run 'rotate_convo'

check "the marker exists" [ -f "$SEAM" ]
check_eq "and holds the archived record's end" \
    "$(sed -n 's/^ended=//p' "$SEAM" 2>/dev/null)" "$IDLE_EPOCH"
check_eq "and that no summary went with it" \
    "$(sed -n 's/^summary=//p' "$SEAM" 2>/dev/null)" "no"

archived="$(ls "$ARCH"/*.txt 2>/dev/null | head -n1)"
if [ -n "$archived" ] && cmp -s "$archived" "$T/expected-convo.txt"; then
    ok "the archive is still byte-identical to what was said"
else
    fail "the seam must not perturb the archive" "$(ls -A "$ARCH" 2>/dev/null)"
fi

# The critical edge: nothing new has been said, so the convo and summary are
# both gone — and this is exactly when the layer must still be built.
CTX="$(run 'build_convo_context')"
check "an empty record still builds the layer" [ -n "$CTX" ]
if printf '%s' "$CTX" | grep -qF "the previous conversation ended at $IDLE_STAMP"; then
    ok "and it says when the previous record ended, as a plain stamp"
else
    fail "the seam line carries the end stamp" "$(printf '%s' "$CTX" | tail -c 400)"
fi
check "with no condensed clause when no summary was archived" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'condensed before it was archived' /dev/stdin)" -eq 0 ]
check "and the preamble is over it" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'THE CONVERSATION SO FAR' /dev/stdin)" -eq 1 ]
check "one seam line, never two" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'the previous conversation ended at' /dev/stdin)" -eq 1 ]

# --- 2: a rotation with a summary carries the condensed clause --------------

echo ""
echo "seam — a summary archived alongside is said in the same line:"
reset_all
write_convo
printf 'Earlier: they talked about the backup.\n' > "$SUMMARY"
touch -d "@$IDLE_EPOCH" "$SUMMARY"
touch -d "@$IDLE_EPOCH" "$CONVO"

run 'rotate_convo'

check_eq "the marker records the summary" \
    "$(sed -n 's/^summary=//p' "$SEAM" 2>/dev/null)" "yes"
CTX="$(run 'build_convo_context')"
if printf '%s' "$CTX" | grep -qF "ended at $IDLE_STAMP"; then
    ok "the end stamp is unchanged by the clause"
else
    fail "the end stamp survives beside the clause" "$(printf '%s' "$CTX" | tail -c 400)"
fi
check "the condensed clause is present" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'condensed before it was archived' /dev/stdin)" -eq 1 ]
check "and it shares the seam's one line" \
    [ "$(printf '%s' "$CTX" | grep -c "the previous conversation ended at $IDLE_STAMP.*condensed before it was archived")" -eq 1 ]

# --- 3: a new conversation does not erase the seam, and the order holds -----

echo ""
echo "seam — a new conversation starts and the seam stays, in its place:"
printf 'User [2026-08-08 09:12]: are you still there\n' > "$CONVO"
printf 'Assistant [2026-08-08 09:12]: Here.\n\n' >> "$CONVO"
printf 'Earlier: a new summary for the new record.\n' > "$SUMMARY"

CTX="$(run 'build_convo_context')"
check "the marker was not removed by the new record" [ -f "$SEAM" ]
seam_at="$(printf '%s\n' "$CTX" | grep -n 'the previous conversation ended at' | cut -d: -f1 | head -n1)"
sum_at="$(printf '%s\n' "$CTX" | grep -n 'Earlier turns, condensed:' | cut -d: -f1 | head -n1)"
blk_at="$(printf '%s\n' "$CTX" | grep -n '^User \[2026-08-08' | cut -d: -f1 | head -n1)"
if [ -n "$seam_at" ] && [ -n "$sum_at" ] && [ "$seam_at" -lt "$sum_at" ]; then
    ok "the seam sits above the condensed summary"
else
    fail "the seam must sit above the summary" "seam at [$seam_at], summary at [$sum_at]"
fi
if [ -n "$seam_at" ] && [ -n "$blk_at" ] && [ "$seam_at" -lt "$blk_at" ]; then
    ok "and above the blocks"
else
    fail "the seam must sit above the blocks" "seam at [$seam_at], blocks at [$blk_at]"
fi

# --- 4: no marker means the layer as it always was --------------------------

echo ""
echo "seam — a first-ever conversation has no seam and no layer change:"
reset_all
CTX="$(run 'build_convo_context')"
check "no marker, no record: the layer is absent, as before" [ -z "$CTX" ]

write_convo
CTX="$(run 'build_convo_context')"
check "no marker, a live record: no seam line appears" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'the previous conversation ended at' /dev/stdin)" -eq 0 ]
check "and the transcript is delivered as it always was" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'Sheet music' /dev/stdin)" -eq 1 ]

# --- 5: a marker that cannot be parsed costs the line and nothing else ------

echo ""
echo "seam — a malformed marker breaks nothing:"
printf 'ended=not-a-clock\nsummary=maybe\n' > "$SEAM"
CTX="$(run 'build_convo_context')"
check "the transcript still arrives" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'Sheet music' /dev/stdin)" -eq 1 ]
check "and no seam line is invented from garbage" \
    [ "$(printf '%s' "$CTX" | sandbox_count_in 'the previous conversation ended at' /dev/stdin)" -eq 0 ]

rm -f "$CONVO"
head -c 64 /dev/urandom > "$SEAM"
CTX="$(run 'build_convo_context')"
check "unreadable marker, empty record: the layer emits nothing" [ -z "$CTX" ]

# --- 6: a failed rotation writes no marker ----------------------------------

echo ""
echo "seam — a rotation that fails leaves the marker world untouched:"
reset_all
write_convo
touch -d "@$IDLE_EPOCH" "$CONVO"
chmod 500 "$ARCH"
run 'rotate_convo'
chmod 700 "$ARCH"
check "no marker after a failed rotation" [ ! -e "$SEAM" ]
check "and no half-written temporary beside it" \
    [ -z "$(ls "$SEAM".tmp.* 2>/dev/null)" ]

# And a failure must not clobber the marker a SUCCESSFUL rotation left.
printf 'ended=%s\nsummary=no\n' "$IDLE_EPOCH" > "$SEAM"
cp "$SEAM" "$T/expected-seam.txt"
touch -d "@$IDLE_EPOCH" "$CONVO"
chmod 500 "$ARCH"
run 'rotate_convo'
chmod 700 "$ARCH"
if cmp -s "$SEAM" "$T/expected-seam.txt"; then
    ok "the last successful rotation's marker survives a failed one"
else
    fail "a failed rotation must not touch the standing marker" "$(cat "$SEAM" 2>/dev/null)"
fi

# --- 7: the next successful rotation replaces the marker --------------------

echo ""
echo "seam — the next rotation moves the seam forward:"
LATER_EPOCH=$(( $(date +%s) - 400 ))
touch -d "@$LATER_EPOCH" "$CONVO"
run 'rotate_convo'
check_eq "the marker now carries the newer record's end" \
    "$(sed -n 's/^ended=//p' "$SEAM" 2>/dev/null)" "$LATER_EPOCH"
