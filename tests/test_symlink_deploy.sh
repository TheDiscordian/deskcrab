#!/bin/bash
# Deployment is by symlink, and every script must survive being invoked
# through it — specs/nightly.md rule 6a. Run: bash tests/test_symlink_deploy.sh
#
# The gap this was written for: `~/.local/lib/deskcrab` is a directory symlink
# into the checkout's `lib/`, so a script computing SCRIPT_DIR as
# `cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd` walked the LOGICAL path's
# `..` into `~/.local/lib` and sourced a `lib/common.sh` that does not exist.
# Both post-stamp nightly phases ran exactly that way in production — dead,
# unbound variables all the way down, and the night stamping green over them
# (the 2026-08-11 night log, lines 59 and 63). No test invoked anything
# through a symlinked directory, which is why it survived. This one does.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

# The deployed shape, rebuilt exactly: a directory-level symlink whose target
# is the checkout's lib/. Every invocation below goes through it, the way the
# systemd units and sleep-nightly's children do in production.
DEPLOY="$T/deploy"
ln -s "$REPO/lib" "$DEPLOY"

# No source failure, no unbound variable — the two voices of the production
# corpse. Asserted on every invocation.
clean_of_corpse() {  # <output>
    ! contains "$1" "No such file or directory" && ! contains "$1" "unbound variable"
}

echo "promise-check through the symlink:"
out="$("$DEPLOY/promise-check" 2>&1)"; rc=$?
check_eq "no mode answers with usage, exit 2 — it lived past the source" "$rc" "2"
check "and the usage line is its own" contains "$out" "Usage: promise-check"
check "no corpse voice: common.sh sourced, nothing unbound" clean_of_corpse "$out"

out="$("$DEPLOY/promise-check" sweep 2099-01-01 2>&1)"; rc=$?
check_eq "a sweep of a day with no journal exits 0" "$rc" "0"
check "and runs through to its own closing line (rule 53a)" \
    contains "$out" "promise-check: sweep 2099-01-01: no journal — nothing to sweep"
check "with no corpse voice" clean_of_corpse "$out"

echo
echo "backlog-drain through the symlink:"
out="$("$DEPLOY/backlog-drain" 2>&1)"; rc=$?
check_eq "no mode answers with usage, exit 2" "$rc" "2"
check "no corpse voice on the way there" clean_of_corpse "$out"

out="$(env BACKLOG_DRAIN=0 "$DEPLOY/backlog-drain" run 2>&1)"; rc=$?
check_eq "a switched-off run exits 0" "$rc" "0"
check "and says so in its own name" contains "$out" "backlog-drain: off"
check "with no corpse voice" clean_of_corpse "$out"

echo
echo "promise-audit through the symlink:"
out="$("$DEPLOY/promise-audit" "user text" "" 2>&1)"; rc=$?
check_eq "an empty reply exits 0" "$rc" "0"
check_eq "and says nothing at all — the source failure used to speak here" "$out" ""

echo
echo "sleep-nightly through the symlink, status first:"
out="$(env XDG_DATA_HOME="$T/sn-status" "$DEPLOY/sleep-nightly" status 2>&1)"; rc=$?
check_eq "never-slept is exit 1" "$rc" "1"
check "and says so" contains "$out" "never slept"

echo
echo "the whole night through the symlink — the production shape end to end:"
cat > "$T/crab-stub" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest") echo "ingest: 3 added, 0 superseded, 0 duplicates, 0 rejected" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-stub"
mkdir -p "$T/night-journal"
out="$(env CRAB_BIN="$T/crab-stub" XDG_DATA_HOME="$T/night-data" \
    DAY_JOURNAL_DIR="$T/night-journal" BACKLOG_DRAIN=0 \
    "$DEPLOY/sleep-nightly" run 2>&1)"; rc=$?
check_eq "the night exits with the ingest's own zero" "$rc" "0"
STAMP="$T/night-data/deskcrab/last-slept"
[ -f "$STAMP" ] && ok "the night stamped" || fail "the night must stamp" "$out"
check "no corpse voice anywhere in the night" clean_of_corpse "$out"
check "the drain spoke for itself" contains "$out" "backlog-drain:"
check "the sweep spoke for itself" contains "$out" "promise-check: sweep"
NIGHTLOG="$(ls "$T/night-data/deskcrab/sleep/"*.log 2>/dev/null | head -1)"
if [ -n "$NIGHTLOG" ]; then
    check_eq "and no phase drew the PHASE SILENT complaint" \
        "$(sandbox_count_in 'PHASE SILENT' "$NIGHTLOG")" "0"
else
    fail "no night log written" "$out"
fi
