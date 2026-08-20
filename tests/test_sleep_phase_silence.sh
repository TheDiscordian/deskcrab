#!/bin/bash
# A phase that cannot start must not look like a phase with nothing to do —
# specs/nightly.md rule 14b. Run: bash tests/test_sleep_phase_silence.sh
#
# The gap this was written for: both post-stamp nightly phases were dead in
# production — sourcing a lib/common.sh that does not exist — and the night
# stamped green over them, because a phase's own silence looked exactly like
# a phase with nothing to say, and its complaints went to stderr where the
# night log never carried them. Sleep now watches each phase's stretch of the
# log for a line in the phase's own name and shouts PHASE SILENT into the log
# itself when there is none; a phase's non-zero exit lands in the log too.
# Never a gate: every night below still stamps and still exits zero.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

# The ingest, always healthy: this test is about the phases after the stamp.
cat > "$T/crab-ok" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest") echo "ingest: 1 added, 0 superseded, 0 duplicates, 0 rejected" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-ok"

# One stub phase set per case. stub <dir> <name> writes the stub named <name>
# reading its body on stdin; chatty_except fills the other two with phases
# that speak one line in their own name and exit 0.
stub() {  # <dir> <name>  (body on stdin)
    mkdir -p "$1"
    cat > "$1/$2"
    chmod +x "$1/$2"
}
chatty_except() {  # <dir> <name to leave out>
    local n
    for n in claudism-scan night-work promise-check; do
        [ "$n" = "$2" ] && continue
        printf '#!/bin/bash\necho "%s: stub — nothing to do"\nexit 0\n' "$n" | stub "$1" "$n"
    done
}

# run_night <stub lib dir> <data home> — sleep-nightly's functions, sourced,
# with LIB_DIR pointed at the stub set. The script's dispatch runs only when
# executed, so cmd_run is a plain function here, exactly as the coverage test
# uses coverage_fields.
run_night() {
    env CRAB_BIN="$T/crab-ok" XDG_DATA_HOME="$2" \
        bash -c 'source "$1" || exit 9; LIB_DIR="$2"; cmd_run' \
        _ "$REPO/lib/sleep-nightly" "$1" 2>&1
}
night_log() { ls "$1/deskcrab/sleep/"*.log 2>/dev/null | head -1; }

echo "a chatty night: every phase speaks, nobody is accused:"
chatty_except "$T/lib-ok" none
out="$(run_night "$T/lib-ok" "$T/data-ok")"; rc=$?
check_eq "the night exits with the ingest's zero" "$rc" "0"
[ -f "$T/data-ok/deskcrab/last-slept" ] && ok "the night stamped" \
    || fail "the night must stamp" "$out"
LOG="$(night_log "$T/data-ok")"
[ -n "$LOG" ] || die "no night log written" "$out"
check_eq "no PHASE SILENT in the log" "$(sandbox_count_in 'PHASE SILENT' "$LOG")" "0"
check_eq "no did-not-finish in the log" "$(sandbox_count_in 'did not finish' "$LOG")" "0"

echo
echo "a phase that exits zero saying nothing — the silent-corpse shape:"
chatty_except "$T/lib-mute" night-work
printf '#!/bin/bash\nexit 0\n' | stub "$T/lib-mute" night-work
out="$(run_night "$T/lib-mute" "$T/data-mute")"; rc=$?
check_eq "the night still exits zero" "$rc" "0"
[ -f "$T/data-mute/deskcrab/last-slept" ] && ok "and still stamped" \
    || fail "the night must stamp" "$out"
LOG="$(night_log "$T/data-mute")"
[ -n "$LOG" ] || die "no night log written" "$out"
check "PHASE SILENT lands in the night log itself, naming the phase" \
    grep -q "PHASE SILENT.*night-work" "$LOG"
check "and on stderr with it" contains "$out" "PHASE SILENT"
check_eq "the phases that spoke are not accused" \
    "$(sandbox_count_in 'PHASE SILENT' "$LOG")" "1"

echo
echo "a phase that dies leaving only noise in another voice — tonight's exact shape:"
chatty_except "$T/lib-noise" promise-check
stub "$T/lib-noise" promise-check <<'STUB'
#!/bin/bash
echo "/nowhere/promise-check: line 31: /nowhere/lib/common.sh: No such file or directory" >&2
echo "/nowhere/promise-check: line 38: STATE_PREFIX: unbound variable" >&2
exit 1
STUB
out="$(run_night "$T/lib-noise" "$T/data-noise")"; rc=$?
check_eq "the night still exits zero" "$rc" "0"
[ -f "$T/data-noise/deskcrab/last-slept" ] && ok "and still stamped" \
    || fail "the night must stamp" "$out"
LOG="$(night_log "$T/data-noise")"
[ -n "$LOG" ] || die "no night log written" "$out"
check "the noise is not mistaken for the phase's own line" \
    grep -q "PHASE SILENT.*promise-check" "$LOG"
check "and the non-zero exit lands in the log file, not stderr alone" \
    grep -q "the promise sweep did not finish — the night still counts" "$LOG"

echo
echo "a phase that fails after speaking draws did-not-finish alone:"
chatty_except "$T/lib-loud" claudism-scan
printf '#!/bin/bash\necho "claudism-scan: died halfway"\nexit 1\n' \
    | stub "$T/lib-loud" claudism-scan
out="$(run_night "$T/lib-loud" "$T/data-loud")"; rc=$?
check_eq "the night still exits zero" "$rc" "0"
LOG="$(night_log "$T/data-loud")"
[ -n "$LOG" ] || die "no night log written" "$out"
check "did-not-finish is in the log" \
    grep -q "the claudism review did not finish — the night still counts" "$LOG"
check_eq "and PHASE SILENT is not — it spoke" \
    "$(sandbox_count_in 'PHASE SILENT' "$LOG")" "0"
