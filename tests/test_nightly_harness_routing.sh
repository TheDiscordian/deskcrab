#!/bin/bash
# The three out-of-band export sites route her harness and the flat account
# selection — the dedicated regression specs/account-fallback.md's TESTS
# section owed for the 2026-08-11 audit (H3 / RC-6). `crab memory` exec'd
# lib/memory.py carrying only the MEMORY_* knobs, so the nightly ingest ran
# stock `claude` with the walk collapsed to one login; lib/sleep-nightly
# sourced nothing, so its direct claudism-scan rewrite pass did the same; and
# detach_turn_child's setsid fallback dropped CLAUDE_BIN and the selected
# login. All three now export the harness, the configured list, the one
# shared limit signature, and the shared state file path, and seed
# CLAUDE_CONFIG_DIR to the account the selection answers with — explicitly,
# account 1 included (rules 3, 28, 29). Offline: every child that would call
# the CLI is a stub that photographs its environment instead.
# Run: bash tests/test_nightly_harness_routing.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

mkdir -p "$T/two" "$T/stale"

# The scratch account state, in the shape lib/common.sh owns: account 2
# ($T/two) answers now. Written where the sandbox pinned ACCOUNT_STATE_FILE.
seed_state() {
    printf 'current\t2\t%s\t%s\tlimit refusal\n' "$T/two" "$(date +%s)" \
        > "$ACCOUNT_STATE_FILE"
}

# make_dumper <script> <dump file> — a stand-in child that writes the five
# routing facts it arrived holding, one KEY=value line each, and exits 0.
make_dumper() {
    cat > "$1" <<DUMP
#!/bin/bash
{ echo "CLAUDE_BIN=\${CLAUDE_BIN:-}"
  echo "CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR:-}"
  echo "CLAUDE_FALLBACK_CONFIG_DIR=\${CLAUDE_FALLBACK_CONFIG_DIR:-}"
  echo "DESKCRAB_CLAUDE_LIMIT_RE=\${DESKCRAB_CLAUDE_LIMIT_RE:-}"
  echo "ACCOUNT_STATE_FILE=\${ACCOUNT_STATE_FILE:-}"
} > "$2"
DUMP
    chmod +x "$1"
}

envfact() { sed -n "s|^$2=||p" "$1"; }

# The signature must not merely be present — it must be the working one, or a
# refusal sails past the walk. Judged the way the readers judge: does the
# observed live wording match it?
check_signature() {  # <desc> <regex>
    if [ -n "$2" ] && printf '%s' "usage limit reached" | grep -qiE "$2"; then
        ok "$1"
    else
        fail "$1" "$2"
    fi
}

echo "crab memory — the python side arrives holding the harness and the selection's login:"
# A scratch checkout: crab is a real copy (SCRIPT_DIR resolves through
# readlink -f, so a symlinked crab would point back at the repo), the library
# is symlinked, and lib/memory.py is the dumper. Same scaffold as the
# job-runner cases in test_limit_fallback.sh.
mkdir -p "$T/repo/lib"
cp "$REPO/crab" "$T/repo/crab"
chmod +x "$T/repo/crab"
for f in "$REPO/lib/"*; do
    ln -s "$f" "$T/repo/lib/$(basename "$f")"
done
rm -f "$T/repo/lib/memory.py"
make_dumper "$T/repo/lib/memory.py" "$T/memory-env"
seed_state
# The stale CLAUDE_CONFIG_DIR is the regression's shape: the environment
# still holds the account a walk moved off, and the child must get the
# account the shared state answers with instead.
env CLAUDE_CONFIG_DIR="$T/stale" CLAUDE_FALLBACK_CONFIG_DIR="$T/two" \
    "$T/repo/crab" memory list >/dev/null 2>&1
[ -s "$T/memory-env" ] || die "crab memory never reached lib/memory.py"
check_eq "the harness goes with it: CLAUDE_BIN is the stub CLI" \
    "$(envfact "$T/memory-env" CLAUDE_BIN)" "$SANDBOX_BIN/claude"
check_eq "the login is re-seeded to the account the selection answers with, not the leftover" \
    "$(envfact "$T/memory-env" CLAUDE_CONFIG_DIR)" "$T/two"
check_eq "the configured list goes with it" \
    "$(envfact "$T/memory-env" CLAUDE_FALLBACK_CONFIG_DIR)" "$T/two"
check_signature "the one shared limit signature goes with it, and it matches a real refusal" \
    "$(envfact "$T/memory-env" DESKCRAB_CLAUDE_LIMIT_RE)"
check_eq "the shared state file path goes with it" \
    "$(envfact "$T/memory-env" ACCOUNT_STATE_FILE)" "$ACCOUNT_STATE_FILE"

echo
echo "sleep-nightly — the claudism-scan child arrives holding the same set:"
# The night scaffold of test_sleep_phase_silence.sh: sleep-nightly's functions
# sourced with LIB_DIR pointed at a stub phase set, the ingest a healthy fake.
# The exports under test run at source time, before cmd_run fires a phase.
cat > "$T/crab-ok" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest") echo "ingest: 0 added, 0 superseded, 0 duplicates, 0 rejected" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-ok"
mkdir -p "$T/night-lib"
make_dumper "$T/night-lib/claudism-scan" "$T/scan-env"
for n in promise-check night-work; do
    printf '#!/bin/bash\necho "%s: stub — nothing to do"\nexit 0\n' "$n" > "$T/night-lib/$n"
    chmod +x "$T/night-lib/$n"
done
seed_state
env CLAUDE_CONFIG_DIR="$T/stale" CLAUDE_FALLBACK_CONFIG_DIR="$T/two" \
    CRAB_BIN="$T/crab-ok" XDG_DATA_HOME="$T/night-data" \
    bash -c 'source "$1" || exit 9; LIB_DIR="$2"; cmd_run' \
    _ "$REPO/lib/sleep-nightly" "$T/night-lib" >/dev/null 2>&1
[ -s "$T/scan-env" ] || die "the night never reached its claudism-scan child"
check_eq "the harness reaches the nightly child" \
    "$(envfact "$T/scan-env" CLAUDE_BIN)" "$SANDBOX_BIN/claude"
check_eq "the nightly child starts where the selection stands now, not on the leftover" \
    "$(envfact "$T/scan-env" CLAUDE_CONFIG_DIR)" "$T/two"
check_eq "the configured list reaches it" \
    "$(envfact "$T/scan-env" CLAUDE_FALLBACK_CONFIG_DIR)" "$T/two"
check_signature "the shared signature reaches it, and it matches a real refusal" \
    "$(envfact "$T/scan-env" DESKCRAB_CLAUDE_LIMIT_RE)"
check_eq "the shared state file path reaches it" \
    "$(envfact "$T/scan-env" ACCOUNT_STATE_FILE)" "$ACCOUNT_STATE_FILE"

echo
echo "detach_turn_child — the setsid fallback forwards the set, and both branches name the login:"
# The sandbox's systemd-run stub refuses every run (no --on-*), so the
# function records its systemd-run argv in the witness log and then takes the
# setsid fallback for real — one call exercises both branches.
run_detach() {  # [ENV=val ...] — call detach_turn_child on the dumper
    env "$@" bash -c \
        'source "$1/lib/common.sh" >/dev/null 2>&1; shift; detach_turn_child envdump "$1"' \
        _ "$REPO" "$T/dumper"
}
await() {  # <file> — a detached child writes when it lands; bounded
    local i
    for i in $(seq 50); do [ -s "$1" ] && return 0; sleep 0.1; done
    return 1
}
make_dumper "$T/dumper" "$T/detach-env"
seed_state
: > "$SANDBOX_SYSTEMD_LOG"
run_detach CLAUDE_CONFIG_DIR="$T/stale" CLAUDE_FALLBACK_CONFIG_DIR="$T/two"
await "$T/detach-env" || die "the setsid fallback never ran the child"
check "the systemd-run branch set the selection's login explicitly in its argv" \
    grep -qF -- "--setenv=CLAUDE_CONFIG_DIR=$T/two" "$SANDBOX_SYSTEMD_LOG"
check_eq "the setsid fallback hands the child the selection's login, not the leftover" \
    "$(envfact "$T/detach-env" CLAUDE_CONFIG_DIR)" "$T/two"
check_eq "and the harness" \
    "$(envfact "$T/detach-env" CLAUDE_BIN)" "$SANDBOX_BIN/claude"
check_eq "and the configured list" \
    "$(envfact "$T/detach-env" CLAUDE_FALLBACK_CONFIG_DIR)" "$T/two"
check_signature "and the shared signature, matching a real refusal" \
    "$(envfact "$T/detach-env" DESKCRAB_CLAUDE_LIMIT_RE)"
check_eq "and the shared state file path" \
    "$(envfact "$T/detach-env" ACCOUNT_STATE_FILE)" "$ACCOUNT_STATE_FILE"

echo
echo "account 1 is addressed explicitly too — no configuration, no state on disk:"
# Rule 3: "no override" is not an account name. With nothing configured and
# no state record the selection answers account 1, and both branches must
# still say so out loud rather than leaving the variable to the environment.
rm -f "$ACCOUNT_STATE_FILE" "$T/detach-env"
: > "$SANDBOX_SYSTEMD_LOG"
run_detach
await "$T/detach-env" || die "the setsid fallback never ran the account-1 child"
check "the systemd-run branch names account 1's directory explicitly" \
    grep -qF -- "--setenv=CLAUDE_CONFIG_DIR=$HOME/.claude" "$SANDBOX_SYSTEMD_LOG"
check_eq "the setsid fallback hands account 1's directory explicitly" \
    "$(envfact "$T/detach-env" CLAUDE_CONFIG_DIR)" "$HOME/.claude"
