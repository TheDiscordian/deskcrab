#!/bin/bash
# The state block, driven to a known state and read back whole.
# Run: bash tests/test_self_state.sh
#
# specs/self-awareness.md. The failure this file exists for is one sentence:
# "nothing running, nothing scheduled", said out loud on 2026-08-07 with
# twenty-five bookings sitting on disk. It was not a wording problem and it was
# not a lie — the block she was reading enumerated systemd timers, found none,
# and printed "(none scheduled)". The fix is not a filter that catches the
# sentence afterwards (conduct forbids that, and rightly). The fix is putting
# the counts in front of her so the sentence cannot be written.
#
# So every assertion here is about a NUMBER being present and correct:
#
#   * every capped list leads with its total (rules 5 to 7);
#   * the total comes from the RECORDS, so twenty-five records and zero timers
#     reports twenty-five (rules 1 and 5);
#   * a record with no timer and a timer with no record each get their own line
#     (rules 2 and 3);
#   * provenance is rendered, so "scheduled by me" is answerable (rule 11);
#   * the account line is there (rule 16), and a chain walk says so (rule 17);
#   * the arithmetic rule sits beside the counts, in the block, phrased as a
#     comparison and never as an errand (rules 19 and 20);
#   * every heading the prompt names is emitted verbatim (rule 26).
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$WAKES_DIR"
J="$JOBS_DIR"
mkdir -p "$W" "$J"

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WANTS_FILE="$T/wants.md"
MEMORY_STORE=0
CLAUDE_FALLBACK_CONFIG_DIR="$T/fallback-one:$T/fallback-two"
CONF
: > "$T/wants.md"
mkdir -p "$T/fallback-one" "$T/fallback-two"

block()  { sandbox_bash 'self_state_report --prompt' 2>/dev/null; }
board()  { sandbox_bash 'self_state_report' 2>/dev/null; }
prompt() { sandbox_bash 'build_system_prompt' 2>/dev/null; }
has()    { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lines_matching() { printf '%s\n' "$2" | grep -c -- "$1" || true; }
NOW="$(date +%s)"

# --- the fixture ------------------------------------------------------------
# Something of her really is running: a live process, registered the way
# session_register registers one, with the process start time that keeps a
# recycled pid from making a dead session look alive.
sleep 120 &
LIVE_PID=$!
sandbox_at_exit "kill $LIVE_PID"
STARTT="$(awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[20] }' "/proc/$LIVE_PID/stat")"
mkdir -p "$DESKCRAB_STATE_PREFIX-sessions"
printf 'autonomous wake\t%s\t%s\t%s\t%s\n' "$LIVE_PID" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$NOW" "$STARTT" \
    > "$DESKCRAB_STATE_PREFIX-sessions/$LIVE_PID"

# One job running, one that died four hours ago.
cat > "$J/live.json" <<EOF
{"id":"live","description":"a build happening right now","state":"running",
 "started_epoch":$(( NOW - 120 )),"pid":$LIVE_PID,"pidstart":$STARTT}
EOF
cat > "$J/old.json" <<EOF
{"id":"old","description":"a build that died at two in the morning","state":"failed",
 "exit":1,"started_epoch":$(( NOW - 40000 )),"finished_epoch":$(( NOW - 39000 )),
 "finished":"2026-08-07 02:06:00"}
EOF
printf '%s' "$NOW" > "$DESKCRAB_STATE_PREFIX-jobs-surfaced"

# An earlier session that was killed mid-task and left its checkpoints behind.
mkdir -p "$DESKCRAB_STATE_PREFIX-interrupted"
printf '%s\thalf way through rewriting the wants shelf\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
    > "$DESKCRAB_STATE_PREFIX-interrupted/$(( NOW - 900 ))-4242-desktop turn.ckpt"

# A session that finished five minutes ago.
printf '%s\t%s\t120\tdesktop turn\ta turn that finished five minutes ago\n' \
    "$(date -d '-5 minutes' '+%Y-%m-%d %H:%M:%S')" "$(date -d '-5 minutes' '+%H:%M:%S')" \
    > "$DESKCRAB_STATE_PREFIX-sessions.log"

# The chain walked during this turn — written by the real writer, so the shape
# of both files is the shipped one and not this test's idea of it.
sandbox_bash 'claude_limit_record "$CLAUDE_PRIMARY_TOKEN" "out of usage credits"' >/dev/null 2>&1

# Twenty-five bookings and not one live timer. This is the state of the queue
# on the afternoon of the failure, to the number.
for i in $(seq 1 25); do
    printf '%s\tscheduled\tpromise number %d\t%s\tpromise-audit\n' \
        $(( NOW + i * 600 )) "$i" "$NOW" > "$W/deskcrab-wake-r$i.wake"
done

echo "every list leads with its total:"
OUT="$(block)"
for want in \
    "Live sessions: 1 total" \
    "Detached jobs running now: 1 total" \
    "Pending wakes (next 12h): 25 total, 5 shown" \
    "Interrupted mid-work: 1 total" \
    "Recently finished (last 30 min"
do
    check "the block states: $want" has "$want" "$OUT"
done
check "and the recently-finished list states its own count" \
    has "min — older: crab status, crab journal): 1 total" "$OUT"

echo
echo "twenty-five records, zero timers, and the number it reports is twenty-five:"
# C4, and the whole of H2. The list is built by enumerating the RECORDS and
# joining timers onto them; built the other way round it reads systemd, finds
# nothing, and says "(none scheduled)" over a full queue.
check "the total is 25, not the number of armed timers" has "25 total" "$OUT"
check "none of them is claimed to be armed" \
    has "! 25 of these are RECORDED WITH NO LIVE TIMER" "$OUT"
check "and the fix for that is named, not merely diagnosed" \
    has "crab wake-restore" "$OUT"
check_eq "five are shown, and the rest are counted rather than dropped" \
    "$(lines_matching '^  - .*booked by promise-audit' "$OUT")" "5"
check "the twenty not shown are stated as a number" has "+20 further out" "$OUT"
check "provenance is rendered on every wake shown" has "[booked by promise-audit" "$OUT"
check "an empty queue would be a measurement, not a claim about the world" \
    bash -c '! printf "%s" "'"$(printf '%s' "$OUT" | tr '\n' ' ')"'" | grep -q "none scheduled"'

echo
echo "a record with no timer and a timer with no record each get their own line:"
rm -f "$W"/*.wake
printf '%s\tevent\ta booking whose timer died with a user manager\t%s\tjob-runner\n' \
    $(( NOW + 1800 )) "$NOW" > "$W/deskcrab-wake-unarmed.wake"
OUT2="$(sandbox_bash '
    systemctl() {
        case "$*" in
            *list-units*) echo "deskcrab-wake-777-1.timer loaded active waiting"; return 0 ;;
            *is-active*)  return 1 ;;
        esac
        return 0
    }
    self_state_report --prompt' 2>/dev/null)"
check "the unarmed booking says it is recorded and not armed" \
    has "RECORDED BUT NOT ARMED" "$OUT2"
check "the orphan timer says it has no booking record" \
    has "a timer with no booking record" "$OUT2"
check "both are counted separately" has "! 1 live timer has no booking record" "$OUT2"
check_eq "and the total counts both — two rows, two things worth seeing" \
    "$(printf '%s\n' "$OUT2" | grep -c 'Pending wakes (next 12h): 2 total')" "1"

echo
echo "the account line says which login answers next, and why it moved:"
check "the block carries an account line at all" has "Account: " "$OUT"
check "it names the login that answers next" has "Account: fallback-one answers next" "$OUT"
check "and why the default last moved, from the default file" \
    has "moved off -: out of usage credits" "$OUT"
check "a chain walk during the turn is reported in the delta, with both ends" \
    has "account chain walked 1 (last: primary -> fallback-one)" "$OUT"

echo
echo "every heading the prompt names is emitted verbatim by the block:"
# MIN-3: the prompt pointed at a heading the block did not emit. Each string
# below is quoted in build_system_prompt's own words; if the block stops
# emitting one, the prompt is pointing at nothing.
for heading in "Recently finished" "Interrupted mid-work" "Since your last reply"; do
    check "the prompt names '$heading', and the block emits it" has "$heading" "$OUT"
done
check "and what the near view omits is named as one command away" \
    has "(all of them: crab status)" "$OUT"
check "the finished and failed jobs, likewise" \
    has "(finished and failed ones: crab jobs)" "$OUT"

echo
echo "the arithmetic rule sits beside the counts, in the block:"
P="$(prompt)"
RULE="THE COUNTS ABOVE ARE THE ANSWER. You may not say nothing is running, or that nothing is scheduled, unless both counts read zero. If they do not, say the number."
check "the rule is in the prompt, in full" has "$RULE" "$P"
check "phrased as a comparison, not as an errand" \
    has "This is arithmetic, not an errand" "$P"
check "and it says explicitly that no command is needed" \
    has "no command is needed and nothing has to be checked" "$P"
# Beside the counts means BESIDE them: the line after the block's last line.
RULE_LINE="$(printf '%s\n' "$P" | grep -n "^THE COUNTS ABOVE ARE THE ANSWER" | head -1 | cut -d: -f1)"
ACCT_LINE="$(printf '%s\n' "$P" | grep -n "^Account: " | head -1 | cut -d: -f1)"
check_eq "it follows the counts immediately, with nothing between" \
    "$(( RULE_LINE - ACCT_LINE ))" "1"
HEAD_LINE="$(printf '%s\n' "$P" | grep -n "^CURRENT STATE OF YOURSELF" | head -1 | cut -d: -f1)"
check "the whole block sits under the heading the prompt announces" \
    bash -c "[ '$HEAD_LINE' -gt 0 ] && [ '$HEAD_LINE' -lt '$ACCT_LINE' ]"

echo
echo "every identity the queue can stamp on a record is named in the prompt:"
# Rules 9 and 10, enumerated instead of recited. A provenance value the prompt
# does not carry is a record she reads as somebody else's work, and that is
# what made "nothing scheduled by me" defensible under her own model of
# authorship. The prompt said "four things besides you" and listed four while
# the queue was already stamping six other names on records: the new-file
# watcher and the chain floor were booking wakes nothing in the prompt
# mentioned. So the list is taken from the shipping source rather than from
# this file's memory — a booker added tomorrow turns this red instead of
# quietly going unnamed.
booked_by_values() {
    {
        grep -rhE -- '--by ' "$REPO/lib" "$REPO/crab" | grep -v '^[[:space:]]*#' \
            | grep -oE -- '--by [a-z][a-z0-9-]*' | awk '{ print $2 }'
        # `--by "${WAKE_BOOKED_BY:-outage-retry}"`: the default is the identity
        # when the wake being re-booked cannot name its own booker.
        grep -rhE -- '--by ' "$REPO/lib" "$REPO/crab" | grep -v '^[[:space:]]*#' \
            | grep -oE -- '--by "\$\{[A-Z_]+:-[a-z0-9-]+\}"' \
            | sed -E 's/.*:-([a-z0-9-]+)\}"/\1/'
        # ...and what the module writes when nobody says at all.
        sed -nE 's/.*by="\$\{DESKCRAB_WAKE_ORIGIN:-([a-z]+)\}".*/\1/p' "$REPO/lib/wake-queue.sh"
    } | sort -u
}
VALUES="$(booked_by_values)"
# The roster sentence itself, not the whole prompt: the state block is IN the
# prompt, so a fixture record that happens to carry an identity would answer
# for the sentence that is supposed to explain it.
ROSTER="$(printf '%s\n' "$P" | grep -F 'Wakes are booked in your name')"
check "the source stamps more identities than the four the prompt used to list" \
    [ "$(printf '%s\n' "$VALUES" | grep -c .)" -ge 8 ]
check "the prompt has a roster sentence at all" [ -n "$ROSTER" ]
while read -r who; do
    [ -n "$who" ] || continue
    check "the roster names the booker the record will say: $who" has "$who" "$ROSTER"
done <<< "$VALUES"
check "and each one still has a plain-language gloss beside its record name" \
    has "the promise auditor" "$ROSTER"

echo
echo "the near view is the near view, and the dashboard is not:"
check "the prompt copy keeps history out of the running-work heading" \
    bash -c '! printf "%s" "'"$(printf '%s' "$OUT" | tr '\n' ' ')"'" | grep -q "died at two in the morning"'
BOARD="$(board)"
check "crab status still lists the job that failed hours ago" \
    has "died at two in the morning" "$BOARD"
check "and states its own totals" has "Detached background jobs: 2 listed" "$BOARD"
check "the dashboard's wake list is uncapped and says so with a plain total" \
    has "Pending wakes: 1 total" "$BOARD"
