#!/bin/bash
# The one string cut stays valid UTF-8, whatever lands on the byte boundary.
# Run: bash tests/test_utf8_trim.sh
#
# utf8_trim (lib/common.sh) is the single implementation behind every bounded
# one-line field: the wake ledger reason, the sessions log outcome, the
# checkpoint line, the account log reason, the held-note words, the stream
# last-words tail, the notification body. Before it existed each site carried
# its own bare `head -c`, which cuts on BYTES — and one of them (the wake
# ledger, 2026-08-11 02:22) wrote the lone lead byte of a split em-dash into
# a live file grep then classified as binary: every query on every record
# answered nothing and exited 0. specs/wake-queue.md, DATA, requires the one
# shared trim; tests/test_wake_ledger_utf8.sh holds the ledger's use of it,
# and this file holds the helper itself.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

run() { # <shell body>
    sandbox_bash "$*" 2>&1
}

echo "a character straddling the byte budget:"
# 99 ASCII characters, then an em-dash: its three bytes sit at 100-102, so a
# byte cut at 100 takes exactly one of them — the live corruption's shape,
# reproduced to the byte.
PAD="$(head -c 99 /dev/zero | tr '\0' 'x')"
GOT="$(run 'utf8_trim "'"$PAD"'— and the tail past the limit" 100')"

check_eq "the split character is dropped whole, and nothing else with it" \
    "$GOT" "$PAD"
if printf '%s' "$GOT" | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1; then
    ok "the trimmed string is valid UTF-8"
else
    fail "the trimmed string is valid UTF-8" \
        "$(printf '%s' "$GOT" | iconv -f UTF-8 -t UTF-8 2>&1 >/dev/null)"
fi

echo
echo "a file built from such trims is still text to grep:"
# grep's binary heuristic only fires in a multibyte locale — under plain C
# every byte is text and the defect hides — so the greps here pin the locale
# the live instance reads its records under.
LOG="$SANDBOX/tmp/trims.log"
run 'utf8_trim "'"$PAD"'— sheared on the boundary" 100 >> "'"$LOG"'"; echo >> "'"$LOG"'"
    utf8_trim "a later record wanted-999 well short of any boundary" 100 >> "'"$LOG"'"; echo >> "'"$LOG"'"' \
    > /dev/null
[ -s "$LOG" ] || die "the trimmed lines were written at all"

count_plain="$(LC_ALL=C.UTF-8 grep -c  -- wanted-999 "$LOG" 2>/dev/null)"
count_a="$(LC_ALL=C.UTF-8 grep -ac -- wanted-999 "$LOG" 2>/dev/null)"
check_eq "plain grep — no -a — finds the later line" "${count_plain:-0}" "1"
check_eq "plain grep and grep -a agree, so the file is not binary to grep" \
    "${count_plain:-0}" "${count_a:-0}"
if iconv -f UTF-8 -t UTF-8 "$LOG" > /dev/null 2>&1; then
    ok "the whole file is valid UTF-8"
else
    fail "the whole file is valid UTF-8"
fi

echo
echo "what the trim must not touch:"
# A multibyte character clear of the boundary is content, not a casualty: the
# repair must drop only what the cut split, never a character it did not.
check_eq "an em-dash clear of the boundary survives intact" \
    "$(run 'utf8_trim "before — after" 100')" "before — after"
# Every caller is bounding a one-line field, so the helper owns the flatten
# the call sites each used to do for themselves.
check_eq "newlines and tabs flatten to single spaces" \
    "$(run 'utf8_trim "$(printf "a\nb\tc")" 100')" "a b c"

echo
echo "and the budget itself still holds:"
LONG="$(head -c 300 /dev/zero | tr '\0' 'y')"
check_eq "300 bytes in, 200 bytes out" \
    "$(run 'utf8_trim "'"$LONG"'" 200' | wc -c)" "200"
