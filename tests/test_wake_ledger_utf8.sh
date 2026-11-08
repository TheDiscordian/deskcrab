#!/bin/bash
# The wake ledger stays valid UTF-8, whatever lands on the trim boundary.
# Run: bash tests/test_wake_ledger_utf8.sh
#
# The gap this was written for: wake_ledger() bounded the reason column with a
# bare `head -c 200`, which cuts on BYTES. A multibyte character straddling
# byte 200 was split, and its leading byte went into the ledger alone. One
# such byte — the first third of an em-dash, on a hot-hold booking,
# 2026-08-11 02:22 — made grep classify the ENTIRE live ledger as binary:
# `grep -n <unit>` answered nothing and exited 0 for every record in the
# file, while the records sat there the whole time. The file she reads to
# prove what the queue did was silently unreadable, and nothing said so.
# specs/wake-queue.md, DATA, carries the guarantee.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
mkdir -p "$T/wakes"
LEDGER="$T/wakes/ledger.log"

run() { # <shell body>
    WAKES_DIR="$T/wakes" sandbox_bash "$*" 2>&1
}

# grep's binary heuristic only fires in a multibyte locale — under plain C
# every byte is text and the defect hides — so the greps here pin the locale
# the live instance reads the ledger under.
count_plain() { local n; n="$(LC_ALL=C.UTF-8 grep -c  -- "$1" "$LEDGER" 2>/dev/null)"; printf '%s' "${n:-0}"; }
count_a()     { local n; n="$(LC_ALL=C.UTF-8 grep -ac -- "$1" "$LEDGER" 2>/dev/null)"; printf '%s' "${n:-0}"; }

echo "an em-dash exactly on the truncation boundary:"
# 199 ASCII characters, then an em-dash: its three bytes straddle byte 200,
# so a byte-boundary cut takes exactly one byte of it — the live corruption,
# reproduced to the byte.
PAD="$(head -c 199 /dev/zero | tr '\0' 'x')"
rm -f "$LEDGER"
run 'wake_ledger booked deskcrab-wake-777-1 event "'"$PAD"'— and the tail past the limit" hot-hold' > /dev/null

[ -s "$LEDGER" ] || die "the ledger line was written at all"

if iconv -f UTF-8 -t UTF-8 "$LEDGER" > /dev/null 2>&1; then
    ok "the ledger is valid UTF-8"
else
    fail "the ledger is valid UTF-8" "$(iconv -f UTF-8 -t UTF-8 "$LEDGER" 2>&1 >/dev/null)"
fi

# The whole point: plain grep — no -a — still sees the record.
check_eq "plain grep finds the booking" "$(count_plain deskcrab-wake-777-1)" "1"
check_eq "plain grep and grep -a agree, so the file is not binary to grep" \
    "$(count_plain deskcrab-wake-777-1)" "$(count_a deskcrab-wake-777-1)"

# The partial character is dropped WHOLE: the stored reason is the 199
# characters that fit, with no stray lead byte where the em-dash was cut.
check_eq "the split character's lead byte is not in the record" \
    "$(awk -F'\t' 'NR == 1 { print $5 }' "$LEDGER")" "$PAD"

echo
echo "the limit and the characters that are not on the boundary:"
# An em-dash short of the boundary is content, not a casualty: the repair
# must drop only a character the cut split, never a whole one it did not.
run 'wake_ledger booked deskcrab-wake-777-2 event "before — after" herself' > /dev/null
check_eq "an em-dash clear of the boundary survives intact" \
    "$(count_plain 'before — after')" "1"

# And the bound itself still holds: 300 characters in, 200 in the record.
LONG="$(head -c 300 /dev/zero | tr '\0' 'y')"
run 'wake_ledger booked deskcrab-wake-777-3 event "'"$LONG"'" herself' > /dev/null
check_eq "the 200-character limit is still enforced" \
    "$(awk -F'\t' 'NR == 3 { print length($5) }' "$LEDGER")" "200"

if iconv -f UTF-8 -t UTF-8 "$LEDGER" > /dev/null 2>&1; then
    ok "and the ledger is still valid UTF-8 with all three records on it"
else
    fail "and the ledger is still valid UTF-8 with all three records on it"
fi
