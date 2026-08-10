#!/bin/bash
# The deferred-promise catcher — specs/wake-queue.md rules 43a and 44's scoped
# cap. Run: bash tests/test_promise_deferred.sh
#
# On 2026-08-09 she told the user a builder would be sent "just before one",
# booked nothing, and the promise died with the turn; it took half a day for
# anybody to notice it never happened. The conduct rule — schedule the wake in
# the same turn — already existed, so the missing piece was a hand, not another
# sentence: the audit now reads a reply that commits to later work, and when
# nothing was booked it sets the alarm itself, at the stated moment, with a
# brief on what was promised.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib"

# The auditor, copied (not linked — it resolves SCRIPT_DIR through readlink -f
# and would walk back to the real repo and its real crab), beside a door onto
# the real wake module. Same fixture as test_wake_bookers.sh.
cp "$REPO/lib/promise-audit" "$T/repo/lib/promise-audit"
chmod +x "$T/repo/lib/promise-audit"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"

cat > "$T/repo/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
[ "\${1:-}" = "wake-at" ] || exit 0
shift
source "$REPO/lib/common.sh" >/dev/null 2>&1
wake_book "\$@"
CRAB
chmod +x "$T/repo/crab"

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WANTS_FILE="$T/wants.md"
MEMORY_STORE=0
PROMISE_AUDIT=1
CONF
printf '# Wants\n\n- a want already on the shelf\n' > "$T/wants.md"

export WAKES_DIR="$W"

AUDIT_LOG="$DESKCRAB_STATE_PREFIX-promise-audit.log"
WANT_PREFIX="You said this and did not write it down:"
DEF_PREFIX="You promised him and nothing was booked:"

records()  { ls "$W"/*.wake 2>/dev/null | wc -l; }
field()    { awk -F'\t' -v n="$1" 'FNR == 1 { print $n }' "$W"/*.wake 2>/dev/null; }
fire_in()  { awk -F'\t' -v now="$(date +%s)" 'FNR == 1 { print $1 - now }' "$W"/*.wake 2>/dev/null; }
calls()    { cat "$T/wake-calls" 2>/dev/null; }
reset()    { rm -f "$W"/*.wake "$W/ledger.log" "$T/wake-calls" "$AUDIT_LOG"; }

echo "a reply that commits to later work books the alarm at the stated time:"
reset
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf 'DEFERRED: restart the phone server once the stream is quiet @ in 2 hours\n'
STUB
"$T/repo/lib/promise-audit" "can you bounce the server later?" \
    "I will restart it in a couple of hours, once the stream is quiet." >/dev/null 2>&1
check_eq "exactly one booking record" "$(records)" "1"
check_eq "booked by the auditor, in its own name" "$(field 5)" "promise-audit"
check_eq "as an event wake" "$(field 2)" "event"
case "$(field 3)" in
    "$DEF_PREFIX"*) ok "the reason opens with the deferred prefix the wake path recognises" ;;
    *) fail "a deferred wake must be identifiable, or it audits itself forever" "$(field 3)" ;;
esac
case "$(field 3)" in
    *"wants shelf"*|*"did not write it down"*)
        fail "the brief must not wear the wants wording" "$(field 3)" ;;
    *) ok "and it is a brief about the promise, not the shelf" ;;
esac
F="$(fire_in)"
check "the alarm is set for the stated two hours out" test "$F" -ge 7000 -a "$F" -le 7400
case "$(calls)" in
    *"--cap 5 --cap-prefix $DEF_PREFIX"*)
        ok "under its own cap of five, scoped to its own class" ;;
    *) fail "the deferred wake carries its own scoped cap, not the want cap" "$(calls)" ;;
esac
check "the verdict is on the audit log as a DEFERRED line" \
    grep -q "DEFERRED: restart the phone server" "$AUDIT_LOG"

echo
echo "work the reply reports as already done books nothing:"
reset
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf 'NONE\n'
STUB
"$T/repo/lib/promise-audit" "did you send it?" \
    "Dispatched — the builder is already running; I will hear when it lands." >/dev/null 2>&1
check_eq "no booking record" "$(records)" "0"
check_eq "no call on the queue's door" "$(calls)" ""
check "and the audit log says NONE, so it demonstrably ran" grep -q "NONE" "$AUDIT_LOG"

echo
echo "a promise with no time lands on the twenty-minute floor:"
reset
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf 'DEFERRED: write up the drift notes @ UNKNOWN\n'
STUB
"$T/repo/lib/promise-audit" "will you write that up?" \
    "I will write the drift notes up at some point." >/dev/null 2>&1
check_eq "one booking record" "$(records)" "1"
F="$(fire_in)"
check "the alarm falls on the twenty-minute floor" test "$F" -ge 1100 -a "$F" -le 1400
case "$(field 3)" in
    *"gave no time"*) ok "and the brief says she gave no time" ;;
    *) fail "the brief must say what the audit knew about the moment" "$(field 3)" ;;
esac

echo
echo "a promise she DID book in the same turn is left alone:"
reset
NOW="$(date +%s)"
printf '%s\tevent\tcome back and send the builder\t%s\therself\n' \
    $(( NOW + 5400 )) $(( NOW - 30 )) > "$W/deskcrab-wake-kept.wake"
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf 'DEFERRED: send the builder for it @ in 90 minutes\n'
STUB
"$T/repo/lib/promise-audit" "send the builder later?" \
    "Booked — the builder goes out in ninety minutes." >/dev/null 2>&1
check_eq "her own booking is still the only record" "$(records)" "1"
check_eq "no call on the queue's door" "$(calls)" ""
check "and the log says the promise was kept" grep -q "DEFERRED kept" "$AUDIT_LOG"

echo
echo "the wake path treats both prefixes as the audit's own:"
check_eq "the want prefix is exempt from re-audit" \
    "$(sandbox_bash "promise_audit_own_reason '$WANT_PREFIX x' && echo exempt")" "exempt"
check_eq "the deferred prefix is exempt from re-audit" \
    "$(sandbox_bash "promise_audit_own_reason '$DEF_PREFIX x' && echo exempt")" "exempt"
check_eq "an ordinary reason is not" \
    "$(sandbox_bash "promise_audit_own_reason 'check the greenhouse' || echo audited")" "audited"

echo
echo "want-flags cannot starve a caught promise (the cap counts its own class only):"
reset
NOW="$(date +%s)"
for i in 1 2 3 4 5; do
    printf '%s\tevent\t%s want %d\t%s\tpromise-audit\n' \
        $(( NOW + i * 3600 )) "$WANT_PREFIX" "$i" "$NOW" > "$W/deskcrab-wake-want$i.wake"
done
out="$(WAKES_DIR="$W" sandbox_bash "wake_book --by promise-audit --cap 5 --cap-prefix '$DEF_PREFIX' 2h event '$DEF_PREFIX the caught one'" 2>&1)"
case "$out" in
    *"Wake scheduled"*) ok "five pending want-flags do not fill the deferred cap" ;;
    *) fail "the deferred cap must not count the want class" "$out" ;;
esac
check_eq "and no want wake was drained to make room" "$(records)" "6"

echo
echo "over ITS cap, only its own class drains:"
reset
NOW="$(date +%s)"
printf '%s\tevent\t%s the standing want\t%s\tpromise-audit\n' \
    $(( NOW + 1800 )) "$WANT_PREFIX" "$NOW" > "$W/deskcrab-wake-want.wake"
for i in 1 2 3 4 5 6; do
    printf '%s\tevent\t%s promise number %d\t%s\tpromise-audit\n' \
        $(( NOW + i * 3600 )) "$DEF_PREFIX" "$i" "$NOW" > "$W/deskcrab-wake-def$i.wake"
done
out="$(WAKES_DIR="$W" sandbox_bash "wake_book --by promise-audit --cap 5 --cap-prefix '$DEF_PREFIX' 12h event '$DEF_PREFIX one too many'" 2>&1)"
case "$out" in
    *"Not booked"*"cap 5"*) ok "the seventh deferred booking is refused, and says why" ;;
    *) fail "a class over its cap is refused" "$out" ;;
esac
check_eq "the excess deferred wake was drained, from the far end" \
    "$(awk -F'\t' -v p="$DEF_PREFIX" 'FNR == 1 && index($3, p) == 1' "$W"/*.wake 2>/dev/null | wc -l)" "5"
check_eq "the nearest five survive" \
    "$(awk -F'\t' -v p="$DEF_PREFIX" 'FNR == 1 && index($3, p) == 1 { print $1 - '"$NOW"' }' "$W"/*.wake 2>/dev/null | sort -n | tail -1)" "18000"
check_eq "and the want wake was untouched by that drain" \
    "$(ls "$W/deskcrab-wake-want.wake" 2>/dev/null | wc -l)" "1"
