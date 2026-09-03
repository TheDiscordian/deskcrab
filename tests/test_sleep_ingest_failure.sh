#!/bin/bash
# A failed ingest cancels the stamp and the night's exit — nothing else:
# specs/nightly.md rule 10a. Run: bash tests/test_sleep_ingest_failure.sh
#
# The gap this was written for: cmd_run returned the moment the ingest exited
# non-zero, so the claudism review, the promise sweep, the twin-merge pass and
# the night's work — the phase that takes up the queued builder backlog — were
# all unreachable, though none of them reads the ingest's output. Measured
# 2026-09-02 22:22: one codex usage-limit refusal at the top of sleep, refused
# until Sep 6 by its own text, and with it four consecutive nights of promise
# sweeps, claudism reviews and builder work cancelled by an unrelated account.
# Not stamping was right — the night did not happen as a night of memory — and
# the exit staying the ingest's was right; skipping every other phase was not.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

# Two crab stubs: an ingest that dies the way tonight's did, with a
# distinctive rc so the exit assertion cannot pass by accident, and a healthy
# one for the unchanged-good-night half.
cat > "$T/crab-refused" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest")
        echo "ingest: model refused — usage limit reached" >&2
        exit 3 ;;
esac
exit 0
CRAB
chmod +x "$T/crab-refused"

cat > "$T/crab-ok" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest") echo "ingest: 2 added, 0 superseded, 0 duplicates, 0 rejected" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-ok"

# One stub set per case. Each phase speaks one line in its own name — rule
# 14b's obligation — and leaves a marker file, so "the phase ran" is asserted
# on the phase's own witness rather than on a log line alone.
stub_phases() {  # <lib dir> <marker dir>
    local n
    mkdir -p "$1" "$2"
    for n in claudism-scan eng-merge night-work promise-check; do
        printf '#!/bin/bash\necho "%s: stub — ran"\ntouch "%s/%s.ran"\nexit 0\n' \
            "$n" "$2" "$n" > "$1/$n"
        chmod +x "$1/$n"
    done
}

# run_night <crab stub> <stub lib dir> <data home> — sleep-nightly's
# functions, sourced, with LIB_DIR pointed at the stub set, exactly as the
# phase-silence test runs its nights.
run_night() {
    env CRAB_BIN="$1" XDG_DATA_HOME="$3" \
        bash -c 'source "$1" || exit 9; LIB_DIR="$2"; cmd_run' \
        _ "$REPO/lib/sleep-nightly" "$2" 2>&1
}
night_log() { ls "$1/deskcrab/sleep/"*.log 2>/dev/null | head -1; }

echo "a failed ingest: no stamp, the ingest's exit, and every phase still runs:"
stub_phases "$T/lib-bad" "$T/ran-bad"
out="$(run_night "$T/crab-refused" "$T/lib-bad" "$T/data-bad")"; rc=$?
check_eq "the night's exit is the ingest's own rc" "$rc" "3"
if [ ! -f "$T/data-bad/deskcrab/last-slept" ]; then
    ok "no stamp: a failed night never reads as slept"
else
    fail "a failed ingest must not stamp" "$(cat "$T/data-bad/deskcrab/last-slept")"
fi
for n in claudism-scan promise-check eng-merge night-work; do
    if [ -f "$T/ran-bad/$n.ran" ]; then
        ok "the $n phase still ran"
    else
        fail "the $n phase must still run on a failed ingest" "$out"
    fi
done
LOG="$(night_log "$T/data-bad")"
[ -n "$LOG" ] || die "no night log written" "$out"
check "the night log says plainly it runs on a FAILED ingest" \
    grep -q "FAILED ingest" "$LOG"
notice_ln="$(grep -n 'FAILED ingest' "$LOG" | head -1 | cut -d: -f1)"
phase_ln="$(grep -n '^claudism-scan:' "$LOG" | head -1 | cut -d: -f1)"
if [ -n "$notice_ln" ] && [ -n "$phase_ln" ] && [ "$notice_ln" -lt "$phase_ln" ]; then
    ok "and says so BEFORE the first phase, so no reader mistakes the night for whole"
else
    fail "the failed-ingest notice must precede the first phase's lines" \
        "notice@${notice_ln:-none} first-phase@${phase_ln:-none}"
fi

echo
echo "a failed ingest and a failed phase: the exit is still the ingest's, not the phase's:"
stub_phases "$T/lib-worse" "$T/ran-worse"
printf '#!/bin/bash\necho "night-work: stub — dying"\nexit 7\n' > "$T/lib-worse/night-work"
chmod +x "$T/lib-worse/night-work"
out="$(run_night "$T/crab-refused" "$T/lib-worse" "$T/data-worse")"; rc=$?
check_eq "the last phase's rc=7 does not replace the ingest's rc=3" "$rc" "3"
LOG="$(night_log "$T/data-worse")"
[ -n "$LOG" ] || die "no night log written" "$out"
check "the phase's own failure still lands in the log" \
    grep -q "the night's work did not finish" "$LOG"

echo
echo "a healthy ingest: exactly as before — stamp, exit zero, phases, no accusation:"
stub_phases "$T/lib-ok" "$T/ran-ok"
out="$(run_night "$T/crab-ok" "$T/lib-ok" "$T/data-ok")"; rc=$?
check_eq "the night exits with the ingest's zero" "$rc" "0"
if [ -f "$T/data-ok/deskcrab/last-slept" ]; then
    ok "the night stamped"
    check_eq "and the stamp's third line carries the yield" \
        "$(sed -n 3p "$T/data-ok/deskcrab/last-slept")" "added=2"
else
    fail "a good night must stamp" "$out"
fi
for n in claudism-scan promise-check eng-merge night-work; do
    if [ -f "$T/ran-ok/$n.ran" ]; then
        ok "the $n phase ran"
    else
        fail "the $n phase must run on a good night" "$out"
    fi
done
LOG="$(night_log "$T/data-ok")"
[ -n "$LOG" ] || die "no night log written" "$out"
check_eq "no FAILED-ingest notice on a good night" \
    "$(sandbox_count_in 'FAILED ingest' "$LOG")" "0"
check_eq "no PHASE SILENT in the log" "$(sandbox_count_in 'PHASE SILENT' "$LOG")" "0"
check_eq "no did-not-finish in the log" "$(sandbox_count_in 'did not finish' "$LOG")" "0"
