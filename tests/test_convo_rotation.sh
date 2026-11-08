#!/bin/bash
# Rotation must never lose a byte of the transcript, and must never lose one
# quietly.
# Run: bash tests/test_convo_rotation.sh
#
# What sent someone looking, 2026-08-07: the live conversation began fresh at
# 23:40 holding two exchanges, and ~/.local/share/deskcrab/archive was empty
# with an mtime from the day before. It read exactly like every rotation since
# had eaten the transcript.
#
# It had not. ARCHIVE_DIR is set in the live config, the archives were all
# where it points, and the empty directory is the unused DEFAULT — made by the
# mkdir at the top of common.sh whether or not it is the configured path. The
# thing actually lost at 23:40 was the phone page's visible scrollback, which
# is tests/phone_client_test.js's business.
#
# But the hour that went into ruling it out found a real hole underneath, and
# these are about that hole. The conversation lives on tmpfs and the archive
# lives on disk, so the `mv` this used to be was a copy plus an unlink, not a
# rename. A copy that runs short — no room, a full disk, an interrupted write —
# left a TRUNCATED archive and unlinked the original anyway, and said nothing:
# the next turn simply started a fresh file. There is no alarm for that and no
# way back from it. So:
#
#   1. a rotation archives the transcript byte for byte, and the summary with it
#   2. a rotation that cannot write the archive keeps the transcript AND says so
#   3. a copy that comes out short is caught before the original is removed
#   4. the idle boundary is a boundary — just under it, nothing moves
#   5. two conversations idle in the same second do not overwrite each other
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
SPEECH="$DESKCRAB_STATE_PREFIX-speech.log"
NOTIFY="$T/witness/notify.log"

run() { DESKCRAB_NO_DISPATCH=1 sandbox_bash "$1" 2>/dev/null; }

# An evening's conversation, with the awkward bytes a transcript really carries:
# an em dash, a stamped wake block, and a trailing blank line.
write_convo() {
    printf 'User [2026-08-07 21:59]: name the next thing on your shelf\n' > "$CONVO"
    printf 'Assistant [2026-08-07 21:59]: Sheet music — obviously.\n\n' >> "$CONVO"
    printf '[Autonomous wake — 2026-08-07 22:04]\n' >> "$CONVO"
    printf 'Assistant [2026-08-07 22:04] (autonomous wake): Bar 13 is read.\n\n' >> "$CONVO"
}

reset_all() {
    rm -rf "$ARCH"; mkdir -p "$ARCH"
    rm -f "$CONVO" "$SUMMARY" "$SPEECH" "$NOTIFY"
    mkdir -p "$(dirname "$NOTIFY")"
    : > "$NOTIFY"
}

# --- 1: the whole transcript lands, and the summary lands beside it ---------

echo "rotation — an idle conversation is archived whole:"
reset_all
write_convo
cp "$CONVO" "$T/expected-convo.txt"
printf 'Earlier: they talked about the backup.\n' > "$SUMMARY"
cp "$SUMMARY" "$T/expected-summary.txt"
touch -d "@$(( $(date +%s) - 1000 ))" "$SUMMARY"
touch -d "@$(( $(date +%s) - 1000 ))" "$CONVO"

run 'rotate_convo'

archived="$(ls "$ARCH"/*.txt 2>/dev/null | grep -v -- '-summary\.txt$' | head -n1)"
if [ -n "$archived" ]; then ok "the transcript reached the archive"
else fail "the transcript reached the archive" "$(ls -A "$ARCH" 2>/dev/null)"; fi

if [ -n "$archived" ] && cmp -s "$archived" "$T/expected-convo.txt"; then
    ok "and it is byte-identical to what was said"
else
    fail "the archived transcript is byte-identical" \
         "$(cmp "$archived" "$T/expected-convo.txt" 2>&1)"
fi

sumfile="${archived%.txt}-summary.txt"
if [ -f "$sumfile" ] && cmp -s "$sumfile" "$T/expected-summary.txt"; then
    ok "the summary is archived beside it, under the same stamp"
else
    fail "the summary is archived beside the transcript" "$(ls -A "$ARCH")"
fi

check "the live conversation is gone, so the next turn starts fresh" [ ! -e "$CONVO" ]
check "and its summary with it" [ ! -e "$SUMMARY" ]
check "no part file is left in the archive" \
    [ -z "$(ls -A "$ARCH" 2>/dev/null | grep '\.part\.' || true)" ]

# --- 2: an archive that cannot be written costs nothing, and is loud --------

echo ""
echo "rotation — an archive it cannot write leaves the transcript in place:"
reset_all
write_convo
printf 'Earlier: they talked about the backup.\n' > "$SUMMARY"
touch -d "@$(( $(date +%s) - 1000 ))" "$CONVO"
chmod 500 "$ARCH"

run 'rotate_convo'
rc_dir="$(ls -A "$ARCH" 2>/dev/null | wc -l)"
chmod 700 "$ARCH"

check "nothing was written to the unwritable archive" [ "$rc_dir" -eq 0 ]
if [ -f "$CONVO" ] && cmp -s "$CONVO" "$T/expected-convo.txt"; then
    ok "the conversation is still here, unharmed"
else
    fail "an unwritable archive must not cost the transcript" "$(ls -l "$CONVO" 2>&1)"
fi
check "and so is the summary" [ -f "$SUMMARY" ]
check "the failure is in the speech log" \
    [ "$(sandbox_count_in 'rotation FAILED' "$SPEECH")" -ge 1 ]
check "and on the desktop, where he will actually see it" \
    [ "$(sandbox_count_in 'rotation failed' "$NOTIFY")" -ge 1 ]

# --- 3: THE HOLE. A short copy must never cost the original -----------------

echo ""
echo "rotation — a copy that comes out short is caught before the unlink:"
reset_all
write_convo
touch -d "@$(( $(date +%s) - 1000 ))" "$CONVO"

# A full disk as the kernel actually presents it to a copy that has already
# begun: some of the bytes land, and there is no way to ask for the rest.
# `mv` across a filesystem boundary is this copy, and it unlinks afterwards
# regardless — which is the whole reason the archive is now measured.
sandbox_stub cp <<'STUB'
#!/bin/bash
# argv: <src> <dest>
head -c 20 "$1" > "$2"
exit 0
STUB

run 'rotate_convo'
rm -f "$SANDBOX_BIN/cp"

if [ -f "$CONVO" ] && cmp -s "$CONVO" "$T/expected-convo.txt"; then
    ok "the transcript survived a copy that lost most of it"
else
    fail "a short copy must never cost the transcript" "$(cat "$CONVO" 2>&1)"
fi
check "and the short copy was not given the archive's name" \
    [ -z "$(ls "$ARCH"/*.txt 2>/dev/null)" ]
check "nor left lying about under a part name" \
    [ -z "$(ls -A "$ARCH" 2>/dev/null)" ]
check "the truncation is reported, with the byte counts that did not match" \
    [ "$(sandbox_count_in 'came out 20 bytes, not ' "$SPEECH")" -ge 1 ]

# --- 4: the idle boundary -------------------------------------------------

echo ""
echo "rotation — the idle timeout is a boundary, not a suggestion:"
reset_all
write_convo
touch -d "@$(( $(date +%s) - 290 ))" "$CONVO"     # CONVO_TIMEOUT is 300
run 'rotate_convo'
check "ten seconds short of the timeout, nothing moves" [ -f "$CONVO" ]
check "and nothing is archived" [ -z "$(ls -A "$ARCH" 2>/dev/null)" ]

touch -d "@$(( $(date +%s) - 301 ))" "$CONVO"
run 'rotate_convo'
check "one second past it, the conversation rotates" [ ! -e "$CONVO" ]
check "and the archive has it" [ -n "$(ls -A "$ARCH" 2>/dev/null)" ]

# --- 5: same-second collisions ---------------------------------------------

echo ""
echo "rotation — two conversations idle in the same second keep both:"
reset_all
write_convo
STAMP_EPOCH=$(( $(date +%s) - 1000 ))
touch -d "@$STAMP_EPOCH" "$CONVO"
FIRST="$ARCH/$(date -d "@$STAMP_EPOCH" '+%Y%m%d-%H%M%S').txt"
printf 'an older conversation that happens to share the second\n' > "$FIRST"
cp "$FIRST" "$T/expected-first.txt"

run 'rotate_convo'

if cmp -s "$FIRST" "$T/expected-first.txt"; then
    ok "the conversation already holding that name is untouched"
else
    fail "a same-second rotation must not overwrite" "$(cat "$FIRST")"
fi
second="$(ls "$ARCH"/*-2.txt 2>/dev/null | head -n1)"
if [ -n "$second" ] && cmp -s "$second" "$T/expected-convo.txt"; then
    ok "and the new one is archived under the next name along"
else
    fail "the second conversation of the second is archived too" "$(ls -A "$ARCH")"
fi

# --- 6: the callers all go through the lock --------------------------------

echo ""
echo "rotation — nothing archives the conversation behind the lock's back:"
# A source-level guard. The verification only holds if every rotation goes
# through _rotate_convo_locked; a caller that moves the file itself would be
# the same hole in a different function.
stray="$(grep -an "mv .*CONVOFILE" "$SANDBOX_REPO/lib/common.sh" \
         | grep -v '_archive_verified' | grep -v 'NEWFILE' || true)"
check "no path moves the conversation file on its own" [ -z "$stray" ]
