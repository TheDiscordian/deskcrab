#!/bin/bash
# Single flight for detached jobs — specs/jobs.md rules 42-45. Two hands must
# never run one brief at once: on the night of 2026-09-03 the 02:30 nightly
# tidy and a tidy queued behind an account limit since 22:21 dispatched at the
# same instant the moment the limit lifted, both against wants.md — a file
# with no git behind it — and only a vigilant hand stopping one of them kept
# it from the 2026-08-09 clobber shape. These cases prove: the key (an
# explicit slug, or a hash of the brief's own words, so identical briefs
# collide by substance rather than wording); the door's refusal while an
# incumbent is queued, dispatched or running; the worker's flock holding the
# key for the life of the run, so even two dispatches racing in the same
# instant leave exactly one writer on the work file; a queued daily brief
# superseded by its own next occurrence dropped before any work file is
# opened; and a stale lock whose owner is dead recovered rather than a
# permanent block. Run: bash tests/test_job_single_flight.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JS="$REPO/lib/job-status"
J="$T/jobs"
WD="$T/work"
DRAWER="$T/drawer"
mkdir -p "$J" "$WD" "$DRAWER"

run() { # <shell body> — the door, dispatch stopped at the preflight
    JOBS_DIR="$J" DESKCRAB_NO_DISPATCH=1 sandbox_bash "$*" 2>&1
}
runq() { # <shell body> — the REAL door (the sandbox's systemd-run stub
         # records the unit and arms nothing, so no builder can start)
    JOBS_DIR="$J" sandbox_bash "$*" 2>&1
}
st() { "$JS" get "$J/$1.json" "$2" 2>/dev/null; }
sidecars() { ls "$J"/*.json 2>/dev/null | wc -l | tr -d ' '; }

TIDY="NIGHTLY TIDY (twin test). Read wants.md line by line and keep only genuine wants on the shelf."

echo "flight-key — identical briefs collide by substance, not wording (rule 42):"
k1="$("$JS" flight-key "" "Tidy   THE shed")"
k2="$("$JS" flight-key "" "tidy the shed")"
check_eq "case and spacing do not make two keys of one brief" "$k1" "$k2"
k3="$("$JS" flight-key "" "sweep the yard instead")"
check "different substance, different key" [ -n "$k1" ]
check "and the two keys differ" [ "$k1" != "$k3" ]
check_eq "an explicit slug IS the key" \
    "$("$JS" flight-key nightly-tidy "$TIDY")" "nightly-tidy"

echo
echo "(a) two dispatches of one brief in the same instant — one writer (rule 44):"
# The work file the guard exists to protect: a stand-in for wants.md, no git
# behind it. The builder stub writes it once and then holds its run open, so
# the second hand arrives while the first still holds the pen — the exact
# 2026-09-03 shape.
sandbox_stub claude <<STUB
#!/bin/bash
printf 'tidy pass\n' >> "$DRAWER/wants.md"
sleep 6
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"tidied. VERDICT: tests=0/0 commit=none"}]}}'
printf '%s\n' '{"type":"result","result":"tidied."}'
exit 0
STUB
"$JS" new "$J" raceA "$TIDY" "" "$WD" dispatched
"$JS" set "$J/raceA.json" slug=race-tidy
"$JS" new "$J" raceB "$TIDY" "" "$WD" dispatched
"$JS" set "$J/raceB.json" slug=race-tidy
JOBS_DIR="$J" "$REPO/lib/job-runner" raceA "$WD" >/dev/null 2>&1 </dev/null &
PA=$!
JOBS_DIR="$J" "$REPO/lib/job-runner" raceB "$WD" >/dev/null 2>&1 </dev/null &
PB=$!
M1=""
for _ in $(seq 150); do
    [ -s "$DRAWER/wants.md" ] && { M1="$(stat -c %Y "$DRAWER/wants.md")"; break; }
    sleep 0.1
done
wait "$PA" 2>/dev/null
wait "$PB" 2>/dev/null
SA="$(st raceA state)"; SB="$(st raceB state)"
WIN=""; LOSE=""
case "$SA/$SB" in
    duplicate/*) WIN=raceB; LOSE=raceA ;;
    */duplicate) WIN=raceA; LOSE=raceB ;;
esac
if [ -n "$WIN" ]; then
    ok "exactly one hand stood down as a duplicate ($LOSE)"
else
    fail "exactly one of the racing pair must lose the key" "raceA=$SA raceB=$SB"
    WIN=raceA; LOSE=raceB   # keep the remaining assertions speaking
fi
case "$(st "$WIN" state)" in
    finished|collected) ok "the winner ran to completion ($(st "$WIN" state))" ;;
    *) fail "the winner should have run clean" "$(st "$WIN" state)" ;;
esac
check "the work file was written" [ -s "$DRAWER/wants.md" ]
check_eq "and holds exactly one writer's line" \
    "$(wc -l < "$DRAWER/wants.md" | tr -d ' ')" "1"
check_eq "its mtime never moved after the first hand wrote" \
    "$(stat -c %Y "$DRAWER/wants.md")" "$M1"
check "the loser's log names the refusal" \
    grep -q "single-flight" "$J/$LOSE.log"
check "and the key" grep -q "race-tidy" "$J/$LOSE.log"
check "and the incumbent job id" grep -q "$WIN" "$J/$LOSE.log"
check "the loser's sidecar carries the same record" \
    grep -q "$WIN" <<<"$(st "$LOSE" summary)"
loser_log="$(cat "$J/$LOSE.log" 2>/dev/null)"
case "$loser_log" in
    *"building as account"*) fail "the loser must exit before any build begins" "$loser_log" ;;
    *) ok "the loser never booted a builder" ;;
esac

# From here on, a builder that answers at once — nothing below runs a race.
sandbox_stub claude <<'STUB'
#!/bin/bash
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"done. VERDICT: tests=0/0 commit=none"}]}}'
printf '%s\n' '{"type":"result","result":"done."}'
exit 0
STUB

echo
echo "(b) the same brief is refused while an incumbent is merely queued (rule 43):"
"$JS" new "$J" qtidy "$TIDY" "" "$WD" queued
"$JS" set "$J/qtidy.json" slug=night-twin
N0="$(sidecars)"
out="$(run 'job_start -f --slug night-twin "'"$TIDY"'"')"
check "the door refuses on the key" contains "$out" "single-flight"
check "naming the key" contains "$out" "night-twin"
check "and the incumbent" contains "$out" "qtidy"
case "$out" in *"Would dispatch"*)
        fail "a refused brief must never reach dispatch" "$out" ;;
    *) ok "dispatch was never reached" ;; esac
check_eq "and no sidecar was created for the refused twin" "$(sidecars)" "$N0"
# No slug on either side: identical words still collide, by their hash.
"$JS" new "$J" qplain "sweep the drawer and file the letters" "" "$WD" queued
out="$(run 'job_start -f "Sweep   the DRAWER and file the letters"')"
check "an unslugged identical brief collides by substance" \
    contains "$out" "single-flight"
check "naming the queued incumbent" contains "$out" "qplain"
# The queued door too: a queued twin must not dispatch beside a running one.
"$JS" new "$J" runinc "polish the reflex tables end to end" "" "$WD" dispatched
"$JS" set "$J/runinc.json" slug=door-twin
"$JS" new "$J" qwait "polish the reflex tables end to end" "" "$WD" queued
"$JS" set "$J/qwait.json" slug=door-twin
out="$(run 'job_dispatch_queued qwait')"
check "crab job dispatch refuses beside a live incumbent" \
    contains "$out" "single-flight"
check "naming it" contains "$out" "runinc"
check_eq "and the brief stays queued for a later night" "$(st qwait state)" "queued"

echo
echo "(c) a differently-keyed brief dispatches alongside (rule 43):"
out="$(run 'job_start -f --slug other-work "audit the wake ledger for gaps"')"
check "a different slug passes the standing incumbents" \
    contains "$out" "Would dispatch"
# A dead incumbent holds no key: a sidecar orphaned in running by a crashed
# runner must not become the permanent block the flock design retired.
"$JS" new "$J" deadinc "shine the doorknobs" "" "$WD" dispatched
"$JS" set "$J/deadinc.json" state=running pid=99999999 pidstart=1
out="$(run 'job_start -f "Shine the doorknobs"')"
check "a dead incumbent's stale sidecar does not block the brief" \
    contains "$out" "Would dispatch"

echo
echo "(d) a queued daily brief superseded by its own next occurrence (rule 45):"
"$JS" new "$J" staletidy "$TIDY" "" "$WD" queued
"$JS" set "$J/staletidy.json" slug=nightly-tidy daily=02:30 \
    queued_epoch=$(( $(date +%s) - 172800 ))
UNITS0="$(sandbox_systemd_count)"
out="$(runq 'job_dispatch_queued staletidy')"
check "the door drops it rather than running it late" \
    contains "$out" "superseded"
check_eq "the record leaves the queue as superseded" \
    "$(st staletidy state)" "superseded"
check "with the one-line reason in the job's own log" \
    grep -q "superseded" "$J/staletidy.log"
check_eq "no unit started — no work file was ever opened" \
    "$(sandbox_systemd_count)" "$UNITS0"
# The dry run reports and writes nothing (jobs.md rule 32's discipline).
"$JS" new "$J" staletidy2 "$TIDY again" "" "$WD" queued
"$JS" set "$J/staletidy2.json" slug=nightly-tidy daily=02:30 \
    queued_epoch=$(( $(date +%s) - 172800 ))
out="$(run 'job_dispatch_queued staletidy2')"
check "DESKCRAB_NO_DISPATCH says would drop" contains "$out" "Would drop"
check_eq "and leaves the record queued" "$(st staletidy2 state)" "queued"
# A tidy queued AFTER the current occurrence is the occurrence: it dispatches.
"$JS" new "$J" freshtidy "the fresh occurrence's own brief" "" "$WD" queued
"$JS" set "$J/freshtidy.json" slug=fresh-tidy daily=02:30
out="$(runq 'job_dispatch_queued freshtidy')"
check "a fresh queued daily brief still dispatches" \
    contains "$out" "Job freshtidy dispatched"
check_eq "and is dispatched, not dropped" "$(st freshtidy state)" "dispatched"

echo
echo "(e) a stale lock from a dead pid is recovered, never a permanent block (rule 44):"
mkdir -p "$J/flight"
printf '99999999 ghostjob\n' > "$J/flight/solo-run.lock"
"$JS" new "$J" solojob "a lone brief behind a stale lock" "" "$WD" dispatched
"$JS" set "$J/solojob.json" slug=solo-run
JOBS_DIR="$J" "$REPO/lib/job-runner" solojob "$WD" >/dev/null 2>&1 </dev/null
case "$(st solojob state)" in
    finished|collected) ok "the run went through the dead pid's lockfile" ;;
    *) fail "a stale lock must be recovered, not a permanent block" \
        "$(st solojob state)" ;;
esac
check "and the lockfile now names the live claim" \
    grep -q "solojob" "$J/flight/solo-run.lock"

echo
echo "the recorded flight identity rides queue, dispatch and requeue (rule 42):"
WANTS="$T/wants-shelf.md"
printf '# Wants\n\n- **A thing I want** → a-thing.md\n' > "$WANTS"
out="$(JOBS_DIR="$J" WANTS_FILE="$WANTS" DESKCRAB_NO_DISPATCH=1 sandbox_bash \
    'job_start --slug carry-tidy --daily 02:30 "a recurring brief that queues"' 2>&1)"
check "awake and unlinked, the slugged brief queues" \
    contains "$out" "QUEUED for the night"
QID="$(ls "$J"/*.json | xargs -n1 basename | sed 's/\.json$//' \
    | while read -r i; do [ "$("$JS" get "$J/$i.json" slug 2>/dev/null)" = carry-tidy ] && echo "$i"; done | head -1)"
check "and a sidecar carries the slug" [ -n "$QID" ]
check_eq "and the daily occurrence" "$(st "$QID" daily)" "02:30"
