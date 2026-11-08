#!/bin/bash
# A later clock time booked while he is in the conversation is named back to
# her on the receipt — specs/wake-queue.md rule 13d. Run:
# bash tests/test_wake_live_note.sh
#
# 2026-10-20 19:44:14: the Art World expansion sitting booked itself a 21:20
# return to continue its own study, between two phone turns about that very
# work. The frame's rule against inventing a later time was in its prompt and
# did not hold; the 19:46 turn read the booking back as "returning to it at
# nine twenty tonight", and at 19:49 the user named it the recurring bug. So
# the booking door says it at the moment of the act — a note, never a
# refusal: the record stands, autonomous bookers and event wakes never see
# it, and with nobody talking the receipt is exactly what it was.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W"
LT="$DESKCRAB_STATE_PREFIX-live-turn"
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# The booking, with the timer arm stubbed — the record and the receipt are
# what this file is about, and the sandbox forbids a real timer anyway.
book() {  # <wake_book args...>
    WAKES_DIR="$W" sandbox_bash '
        systemctl() { return 1; }
        _wake_book() { return 0; }
        wake_book '"$*"' 2>&1; echo "rc=$?"'
}
live() {  # <seconds ago> [device]
    printf '%s\t%s\tanswered\nUser: are you still on it?\nAssistant: yes\n' \
        "$(( $(date +%s) - $1 ))" "${2:-phone}" > "$LT"
}
records() { ls "$W"/*.wake 2>/dev/null | wc -l; }
NOTE='He is in the conversation now'

echo "a later time booked by her own hand mid-conversation carries the note:"
rm -f "$W"/*.wake; live 90 phone
OUT="$(book 2h scheduled '"continue the lantern study"')"
check "the receipt still opens with the booking" contains "$OUT" 'Wake scheduled'
check "and carries the note" contains "$OUT" "$NOTE"
check "naming how long ago he last spoke, and from where" contains "$OUT" '2 min ago, from the phone'
check "naming the cancel by unit" contains "$OUT" "crab wake-cancel deskcrab-wake-"
check "and the road back to now" contains "$OUT" "crab wake-now"
check "the booking's own exit status" contains "$OUT" 'rc=0'
check_eq "the record stands exactly as booked — a note, never a refusal" "$(records)" 1

echo
echo "and never otherwise:"
rm -f "$W"/*.wake
OUT="$(book --by canary-selfchange 2h scheduled '"the canary"')"
refute "an autonomous booker's wake carries no note" contains "$OUT" "$NOTE"
check "and books as ever" contains "$OUT" 'Wake scheduled'
rm -f "$W"/*.wake
OUT="$(book 2h event '"a moment that is later by nature"')"
refute "an event wake carries no note — it is a moment, not a parked continuation" contains "$OUT" "$NOTE"
rm -f "$W"/*.wake
OUT="$(book 60s scheduled '"a breath from now"')"
refute "a booking inside the lead window is now, near enough" contains "$OUT" "$NOTE"
rm -f "$W"/*.wake; live 3600 desk
OUT="$(book 2h scheduled '"continue the lantern study"')"
refute "a stale conversation — an hour quiet — is nobody talking" contains "$OUT" "$NOTE"
rm -f "$W"/*.wake; rm -f "$LT"
OUT="$(book 2h scheduled '"continue the lantern study"')"
refute "no live-turn record at all: the receipt exactly as before" contains "$OUT" "$NOTE"
check "and the booking is unaffected" contains "$OUT" 'Wake scheduled'
rm -f "$W"/*.wake; printf 'garbage\n' > "$LT"
OUT="$(book 2h scheduled '"continue the lantern study"')"
refute "an unreadable record is no record" contains "$OUT" "$NOTE"
check "and still books" contains "$OUT" 'rc=0'

echo
echo "the window and the lead are knobs:"
rm -f "$W"/*.wake; live 600 phone
OUT="$(WAKE_LIVE_NOTE_WINDOW=300 book 2h scheduled '"x"')"
refute "a narrower window ages him out" contains "$OUT" "$NOTE"
check "and the booking still landed, so the absence was the window's doing" contains "$OUT" 'Wake scheduled'
rm -f "$W"/*.wake
OUT="$(WAKE_LIVE_NOTE_WINDOW=1200 book 2h scheduled '"x"')"
check "a wider one keeps him in" contains "$OUT" "$NOTE"
