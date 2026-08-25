#!/bin/bash
# The undestinated-claims check's knobs resolve environment first, conf
# second, defaults last — specs/nightly.md rule 21e. The nightly unit sources
# nothing on the check's execution path, so an environment-only read left the
# conf's TIDY_CLAIMS_ROOTS invisible to the one run that matters and the
# personal drawers went unscanned every night the setting stood. The conf
# read lives in the script: when a knob is absent from the environment,
# tidy-claims asks a bash that sources common.sh — and through it the conf,
# $HOME expansion and all — from its own realpath-resolved directory (rule
# 6a: deployment is by symlink). An explicit environment variable still wins,
# and a missing or broken conf degrades silently to the shipped defaults.
# Run: bash tests/test_tidy_claims_conf_roots.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

CHECK="$SANDBOX_REPO/lib/tidy-claims"
DEFAULT_ROOTS="$XDG_DATA_HOME/deskcrab:$SANDBOX_REPO"

# Resolve the knobs exactly as the script resolves them at load, through
# whatever path it is reached by — the module's own top level is the code
# under test, so this loads it rather than re-deriving anything. Prints one
# key=value line per knob; a load that raises prints nothing and exits 1,
# which is what the degrade cases assert against.
knobs() {  # <path-to-tidy-claims>
    python3 - "$1" <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("tidy_claims_under_test", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
print("roots=" + ":".join(mod.ROOTS))
print("journal=" + mod.JOURNAL_DIR)
print("out=" + mod.OUT_DIR)
print("lead=%d" % mod.LEAD)
print("slack=%d" % mod.SLACK)
PY
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# The scratch conf: the sandbox's own honest minimum, plus the knobs under
# test. TIDY_CLAIMS_ROOTS is written with a literal $HOME on purpose — the
# whole reason the conf read goes through the shell is that the conf's
# conventions include expansion, which systemd's EnvironmentFile parser and
# the python side both refuse to do. DAY_JOURNAL_DIR is set to a decoy: the
# sandbox pins the real one in the environment, and the environment must win.
GOOD_CONF="$(cat "$DESKCRAB_CONF")"
cat > "$DESKCRAB_CONF" <<CONF
$GOOD_CONF
TIDY_CLAIMS_ROOTS="\$HOME/houseA:$SANDBOX/home/houseB"
TIDY_CLAIMS_DIR="\$HOME/claims-out"
TIDY_CLAIMS_LEAD="333"
TIDY_CLAIMS_SLACK="44"
DAY_JOURNAL_DIR="$SANDBOX/home/conf-journal"
CONF

echo "an empty environment takes the conf's answers:"
out="$( (unset TIDY_CLAIMS_ROOTS TIDY_CLAIMS_DIR TIDY_CLAIMS_LEAD TIDY_CLAIMS_SLACK; knobs "$CHECK") )"; rc=$?
check_eq "the load itself is clean" "$rc" "0"
check_eq "the roots are the conf's, \$HOME expanded" \
    "$(field "$out" roots)" "$HOME/houseA:$SANDBOX/home/houseB"
check_eq "the report dir is the conf's, \$HOME expanded" \
    "$(field "$out" out)" "$HOME/claims-out"
check_eq "the lead is the conf's" "$(field "$out" lead)" "333"
check_eq "the slack is the conf's" "$(field "$out" slack)" "44"
check_eq "the pinned DAY_JOURNAL_DIR still beats the conf's decoy" \
    "$(field "$out" journal)" "$DAY_JOURNAL_DIR"

echo
echo "an explicit environment variable wins over the conf:"
out="$( (export TIDY_CLAIMS_ROOTS="$SANDBOX/home/envroot"; \
         unset TIDY_CLAIMS_DIR TIDY_CLAIMS_LEAD TIDY_CLAIMS_SLACK DAY_JOURNAL_DIR; \
         knobs "$CHECK") )"; rc=$?
check_eq "the load itself is clean" "$rc" "0"
check_eq "the roots are the environment's, the conf's never consulted" \
    "$(field "$out" roots)" "$SANDBOX/home/envroot"
check_eq "and with DAY_JOURNAL_DIR unset the journal is the conf's" \
    "$(field "$out" journal)" "$SANDBOX/home/conf-journal"

echo
echo "a missing conf degrades to the defaults without an exception:"
out="$( (unset TIDY_CLAIMS_ROOTS TIDY_CLAIMS_DIR TIDY_CLAIMS_LEAD TIDY_CLAIMS_SLACK; \
         export DESKCRAB_CONF="$SANDBOX/home/no-such-conf"; knobs "$CHECK") )"; rc=$?
check_eq "no exception" "$rc" "0"
check_eq "the roots are the shipped defaults" \
    "$(field "$out" roots)" "$DEFAULT_ROOTS"
check_eq "the lead is the shipped default" "$(field "$out" lead)" "600"
check_eq "the slack is the shipped default" "$(field "$out" slack)" "120"

echo
echo "a conf that cannot be parsed degrades the same way:"
BROKEN="$SANDBOX/home/broken.conf"
printf 'if then fi ((((\n' > "$BROKEN"
out="$( (unset TIDY_CLAIMS_ROOTS TIDY_CLAIMS_DIR TIDY_CLAIMS_LEAD TIDY_CLAIMS_SLACK; \
         export DESKCRAB_CONF="$BROKEN"; knobs "$CHECK") )"; rc=$?
check_eq "no exception" "$rc" "0"
check_eq "the roots are the shipped defaults" \
    "$(field "$out" roots)" "$DEFAULT_ROOTS"

echo
echo "a conf whose lead is not a number keeps the default, quietly:"
GARBLED="$SANDBOX/home/garbled.conf"
cat > "$GARBLED" <<CONF
$GOOD_CONF
TIDY_CLAIMS_LEAD="not-a-number"
CONF
out="$( (unset TIDY_CLAIMS_ROOTS TIDY_CLAIMS_DIR TIDY_CLAIMS_LEAD TIDY_CLAIMS_SLACK; \
         export DESKCRAB_CONF="$GARBLED"; knobs "$CHECK") )"; rc=$?
check_eq "no exception" "$rc" "0"
check_eq "the lead is the shipped default" "$(field "$out" lead)" "600"

echo
echo "the conf survives the deployed shape — a symlink from a bare directory:"
# The deployed lib is a symlink into the checkout (rule 6a). The sharpest
# form: a FILE symlink from a directory holding no common.sh at all, so an
# unresolved dirname finds no library, the shell fallback fails, and the conf
# is silently lost — only the realpath step can find common.sh from here.
DEPLOY="$SANDBOX/home/deploy-bin"
mkdir -p "$DEPLOY"
ln -s "$CHECK" "$DEPLOY/tidy-claims"
out="$( (unset TIDY_CLAIMS_ROOTS TIDY_CLAIMS_DIR TIDY_CLAIMS_LEAD TIDY_CLAIMS_SLACK; \
         knobs "$DEPLOY/tidy-claims") )"; rc=$?
check_eq "the load itself is clean" "$rc" "0"
check_eq "the roots are still the conf's, through the symlink" \
    "$(field "$out" roots)" "$HOME/houseA:$SANDBOX/home/houseB"
