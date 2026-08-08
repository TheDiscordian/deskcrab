#!/bin/bash
# The subsystems that book wakes in her name — specs/wake-queue.md rules 41 to
# 44, specs/self-awareness.md rules 8 to 11. Run: bash tests/test_wake_bookers.sh
#
# Six things besides her own hand put wakes on the queue: the promise auditor,
# the job runner, the self-change watcher, the new-file watcher, the watcher's
# canary, and the chain floor inside the module itself (which the wake-queue
# tests cover). Before they each stamped an identity, a booking record
# carried no provenance at all — so "nothing scheduled by me" was literally
# unanswerable, and on 2026-08-07 it was said out loud with twenty-five
# bookings on disk.
#
# Two claims per booker, and the second is the one that matters:
#
#   * it goes through the module's one door, `wake_book`, rather than firing a
#     wake or minting a unit name of its own;
#   * the identity it passes reaches the RECORD, which is what the state block
#     and `crab status` read.
#
# So the `crab` these bookers call is not a logging stub. It logs, and then it
# forwards `wake-at` into the real wake_book — the same door `crab` itself
# uses — so every assertion below is made against the record the module wrote.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib" "$T/watched"

# --- the fixture ------------------------------------------------------------
# A repo of her own: the real bookers, copied (not linked — each resolves
# SCRIPT_DIR through readlink -f and would walk back to the real repo and its
# real crab), beside a door onto the real module.
for b in promise-audit job-runner notice-selfchange notice-newfiles canary-selfchange; do
    cp "$REPO/lib/$b" "$T/repo/lib/$b"
    chmod +x "$T/repo/lib/$b"
done
ln -sf "$REPO/lib/common.sh"  "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/job-status" "$T/repo/lib/job-status"

cat > "$T/repo/crab" <<CRAB
#!/bin/bash
# The door, logged. Everything a booker asks for is recorded here AND carried
# through to the real wake_book, so a test can assert on the record rather than
# on the sentence that asked for it.
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
SELF_WATCH_EXTRA="$T/watched"
MEMORY_STORE=0
PROMISE_AUDIT=1
CONF
printf '# Wants\n\n- a want already on the shelf\n' > "$T/wants.md"

export WAKES_DIR="$W"

records()  { ls "$W"/*.wake 2>/dev/null | wc -l; }
booked_by() { awk -F'\t' 'FNR == 1 { print $5 }' "$W"/*.wake 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'; }
kind_of()   { awk -F'\t' 'FNR == 1 { print $2 }' "$W"/*.wake 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'; }
unit_of()   { local f; f="$(ls -1 "$W"/*.wake 2>/dev/null | head -1)"; f="${f##*/}"; printf '%s' "${f%.wake}"; }
calls()     { cat "$T/wake-calls" 2>/dev/null; }
led_count() { awk -F'\t' -v a="$1" '$2 == a { n++ } END { print n + 0 }' "$W/ledger.log" 2>/dev/null || echo 0; }
reset()     { rm -f "$W"/*.wake "$W/ledger.log" "$T/wake-calls"; }

# Every booker is checked the same way: one record, the module's own unit name
# on it, and the booker's identity in the provenance column.
booked_one() { # <identity> <expected kind>
    check_eq "$1: exactly one booking record" "$(records)" "1"
    check_eq "$1: the provenance column names it" "$(booked_by)" "$1"
    check_eq "$1: booked as a $2 wake" "$(kind_of)" "$2"
    case "$(unit_of)" in
        deskcrab-wake-[0-9]*-[0-9]*)
            ok "$1: the unit name came from the module's namer, not from the caller" ;;
        *) fail "$1: no caller may mint a unit name inline" "$(unit_of)" ;;
    esac
    check_eq "$1: and the booking is on the ledger" "$(led_count booked)" "1"
}

echo "the promise auditor books its follow-up in its own name:"
reset
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf 'UNSAVED: fix the thing she said was broken and never wrote down\n'
STUB
"$T/repo/lib/promise-audit" "what is broken?" "That is broken and I should fix it." >/dev/null 2>&1
booked_one promise-audit event
case "$(calls)" in
    *"wake-at --by promise-audit --cap"*) ok "promise-audit: through wake-at, with its cap declared" ;;
    *) fail "promise-audit routes through the module's door" "$(calls)" ;;
esac
case "$(awk -F'\t' 'FNR == 1 { print $3 }' "$W"/*.wake 2>/dev/null)" in
    "You said this and did not write it down:"*)
        ok "promise-audit: the reason opens with the prefix the wake path recognises" ;;
    *) fail "promise-audit's follow-up must be identifiable, or it audits itself forever" \
            "$(awk -F'\t' 'FNR == 1 { print $3 }' "$W"/*.wake 2>/dev/null)" ;;
esac

echo
echo "the job runner books the completion wake in its own name:"
reset
# The runner refuses to reach the live her from a scratch jobs directory, so
# the jobs directory here is this instance's own — which is the sandbox's, not
# the real one. The builder is the stub; nothing is spent and nothing is built.
LIVE_JOBS="$XDG_DATA_HOME/deskcrab/jobs"
mkdir -p "$LIVE_JOBS"
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"built the thing."}]}}'
printf '%s\n' '{"type":"result","result":"built the thing."}'
STUB
python3 - "$LIVE_JOBS/bookertest.json" <<'PY'
import json, sys, time
json.dump({"id": "bookertest", "description": "a job whose ending she should hear about",
           "started_epoch": int(time.time()), "state": "running", "unit": ""},
          open(sys.argv[1], "w"))
PY
# The workdir is its own directory, not the sandbox root: the runner declares
# its workdir to the self-change watcher for four hours, and declaring $T would
# excuse every later case's writes as her own hand.
mkdir -p "$T/jobwork"
JOBS_DIR="$LIVE_JOBS" JOBS_BLOCKED_FILE="$T/blocked-marker" \
    "$T/repo/lib/job-runner" bookertest "$T/jobwork" >/dev/null 2>&1
booked_one job-runner event
case "$(calls)" in
    *"wake-at --by job-runner 5s event"*) ok "job-runner: through wake-at, promptly, as an event" ;;
    *) fail "job-runner routes through the module's door" "$(calls)" ;;
esac
rm -f "$LIVE_JOBS"/bookertest.*

echo
echo "the self-change watcher books in its own name:"
reset
mkdir -p "$XDG_DATA_HOME/deskcrab/wants"
git -C "$T/repo" init -q -b test 2>/dev/null
git -C "$T/repo" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "$T/repo" -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
"$T/repo/lib/notice-selfchange" 99 >/dev/null 2>&1          # seed: silent
check_eq "the seed run books nothing" "$(records)" "0"
echo "a hand that is not hers" > "$T/watched/changed-by-another-hand.md"
"$T/repo/lib/notice-selfchange" 99 >/dev/null 2>&1
booked_one notice-selfchange event
case "$(calls)" in
    *"wake-at --by notice-selfchange 5s event Files that are part of you"*)
        ok "notice-selfchange: through wake-at, as an event, saying what changed" ;;
    *) fail "notice-selfchange routes through the module's door" "$(calls)" ;;
esac

echo
echo "the new-file watcher books in its own name:"
reset
mkdir -p "$T/inbox"
"$T/repo/lib/notice-newfiles" testinbox "$T/inbox" "Transcripts arrived" >/dev/null 2>&1
check_eq "the seed run books nothing" "$(records)" "0"
echo "a transcript" > "$T/inbox/a-meeting.txt"
"$T/repo/lib/notice-newfiles" testinbox "$T/inbox" "Transcripts arrived" >/dev/null 2>&1
booked_one notice-newfiles event
case "$(calls)" in
    *"wake-at --by notice-newfiles 5s event Transcripts arrived: a-meeting.txt"*)
        ok "notice-newfiles: through wake-at, naming the file that arrived" ;;
    *) fail "notice-newfiles routes through the module's door" "$(calls)" ;;
esac

echo
echo "the canary books in its own name:"
reset
# The stubbed user manager answers "not active" to everything, which is exactly
# the shape of a watcher that has stopped — the canary's alarm case, reached
# without waiting out its poke timeout.
"$T/repo/lib/canary-selfchange" --quiet >/dev/null 2>&1
booked_one canary event
case "$(calls)" in
    *"wake-at --by canary 5s event The watcher over your own files is not answering"*)
        ok "canary: through wake-at, saying which watcher and what it means" ;;
    *) fail "canary routes through the module's door" "$(calls)" ;;
esac

echo
echo "the cap counts from the records, under the lock, and drains as well as gates:"
# MAJ-15. A day of firefighting produces a stream of differently-worded UNSAVED
# verdicts about the same crisis; the coalescing window only merges identical
# wording, so the queue becomes a token furnace — measured at five to six times
# the cap, standing for hours, while every audit dutifully logged "capped". A
# cap that only refuses new bookings cannot come back down.
reset
NOW="$(date +%s)"
for i in 1 2 3 4 5; do
    printf '%s\tevent\tpromise number %d\t%s\tpromise-audit\n' \
        $(( NOW + i * 3600 )) "$i" "$NOW" > "$W/deskcrab-wake-cap$i.wake"
done
# One wake from another booker, at the same moment as one of them: the cap
# belongs to the booker, not to the queue, and draining must not touch it.
printf '%s\tevent\tsomething else entirely\t%s\tjob-runner\n' \
    $(( NOW + 3600 )) "$NOW" > "$W/deskcrab-wake-other.wake"

out="$(WAKES_DIR="$W" sandbox_bash 'wake_book --by promise-audit --cap 3 6h event "one promise too many"' 2>&1)"
case "$out" in
    *"Not booked"*"cap 3"*) ok "the sixth booking is refused, and says why" ;;
    *) fail "a booker over its cap is refused" "$out" ;;
esac
check_eq "the excess was drained, not merely gated" \
    "$(awk -F'\t' 'FNR == 1 && $5 == "promise-audit"' "$W"/*.wake 2>/dev/null | wc -l)" "3"
# WHICH three, and it is the whole point of draining. The ones to let go are
# the ones that would have come back LAST: a queue over its cap loses its far
# end, never its near end. Drained the other way round, the cap cancels the
# work about to happen and keeps five hours of stale promises — the exact
# inversion of what a cap is for.
survivors() {
    awk -F'\t' 'FNR == 1 && $5 == "promise-audit" { print $3 }' "$W"/*.wake 2>/dev/null \
        | sort | tr '\n' ' ' | sed 's/ $//'
}
check_eq "the three that survive are the NEAREST, at one, two and three hours" \
    "$(survivors)" "promise number 1 promise number 2 promise number 3"
check_eq "another booker's wake is untouched by that cap" \
    "$(ls "$W/deskcrab-wake-other.wake" 2>/dev/null | wc -l)" "1"
check_eq "every drained booking is on the ledger" "$(led_count cancelled)" "2"
check_eq "with the cap named as the hand that did it" \
    "$(awk -F'\t' '$2 == "cancelled" { print $6 }' "$W/ledger.log" | sort -u)" \
    "promise-audit cap drain"
check_eq "and nothing new was booked" "$(led_count booked)" "0"

# Under the cap, the same call books normally. An assertion that a booking was
# refused proves nothing unless the same booking succeeds when it should.
reset
printf '%s\tevent\tthe only one\t%s\tpromise-audit\n' $(( NOW + 3600 )) "$NOW" \
    > "$W/deskcrab-wake-cap1.wake"
out="$(WAKES_DIR="$W" sandbox_bash 'wake_book --by promise-audit --cap 3 6h event "room for this one"' 2>&1)"
case "$out" in
    *"Wake scheduled"*) ok "under the cap, the booking goes through" ;;
    *) fail "the cap must gate, not block" "$out" ;;
esac
check_eq "and nothing was drained to make room for it" "$(led_count cancelled)" "0"
check_eq "two pending wakes for this booker now" "$(records)" "2"
