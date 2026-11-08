#!/bin/bash
# Every tracked test script is committed with its executable bit, and carries
# it on disk. Run: bash tests/test_exec_bits.sh
#
# specs/test-harness.md rule 19. The fault this pins: 43 of the suite's
# tests/test_*.sh were committed mode 100644, accumulating for weeks with two
# more arriving the same night two were fixed — because the runner invokes
# every test as `bash "$f"` and never needs the bit itself, so only
# `run.sh --list`'s executability check cared, and that check exiting 1 on
# the unfiltered roll call had become the permanent weather nobody read. The
# record resolved the fork in favour of the bit: every tracked test carries
# it, and --list means something again. This file is what makes the ordinary
# full run say so loudly — a builder that commits a test without the bit now
# fails its own suite run, at creation, not weeks later.
#
# Scope is the TRACKED roll call, from the index. An untracked draft in
# tests/ belongs to whoever is writing it and is --list's business, not ours;
# a fault here is one a commit created, and the offender is named so the fix
# is one chmod away.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

# Read-only reads of the repository under test, which the harness contract
# allows. `git ls-files` reads the index and writes nothing.
git -C "$SANDBOX_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || sandbox_skip "the repo under test is not a git checkout"

ROLL="$(git -C "$SANDBOX_REPO" ls-files -s -- 'tests/test_*.sh')"

echo "the roll call is real, not vacuously green:"
check "the index lists tracked test scripts" [ -n "$ROLL" ]
check "this file is itself on the roll call" \
    contains "$ROLL" "tests/test_exec_bits.sh"

echo
echo "every tracked test script is committed with its executable bit:"
BAD_INDEX="$(printf '%s\n' "$ROLL" | awk '$1 == "100644" { print $4 }')"
if [ -z "$BAD_INDEX" ]; then
    ok "no tracked tests/test_*.sh is committed mode 100644"
else
    while IFS= read -r f; do
        fail "committed without its executable bit: $f  (chmod +x '$f' and commit the mode change)"
    done <<EOF
$BAD_INDEX
EOF
fi

echo
echo "and carries the bit on disk, where run.sh --list checks it:"
BAD_DISK=""
while IFS= read -r f; do
    [ -x "$SANDBOX_REPO/$f" ] || BAD_DISK="$BAD_DISK$f"$'\n'
done <<EOF
$(git -C "$SANDBOX_REPO" ls-files -- 'tests/test_*.sh')
EOF
if [ -z "$BAD_DISK" ]; then
    ok "every tracked tests/test_*.sh is executable in the working tree"
else
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        fail "tracked but not executable on disk: $f  (chmod +x '$f')"
    done <<EOF
$BAD_DISK
EOF
fi

# ---------------------------------------------------------------------------
# The door. Everything above names a fault a commit already created — and
# three days after this file landed, tests/test_wake_idle_return.sh landed
# 100644 anyway, because a report is not a gate. The gate lives where every
# new test must walk (rule 18: red before the fix, so its author RUNS it):
# the sandbox's phase 1 refuses a test file that is missing the bit, before
# it builds anything. Driven the way test_sandbox_live_clips.sh drives its
# child — a scratch test through the real sandbox, phase 1 fresh.

echo
echo "the sandbox door refuses a test that is missing the bit on disk:"
FIXTURE="$SANDBOX/tmp/test_gate_fixture.sh"
cat > "$FIXTURE" <<FIXTURE
#!/bin/bash
. "$SANDBOX_REPO/tests/lib/sandbox.sh"
ok "the gate let an executable test run"
FIXTURE
# Deliberately no chmod: mode 644 is exactly the shape a fresh Write lands.
OUT="$(env -u DESKCRAB_SANDBOX_ROOT -u DESKCRAB_SANDBOX_REPO \
        -u DESKCRAB_SANDBOX_LIB -u DESKCRAB_SANDBOX_NAME \
        bash "$FIXTURE" 2>&1)" && RC=0 || RC=$?
check "the run is refused, not passed" [ "$RC" -ne 0 ]
check "the refusal names the one-chmod fix" contains "$OUT" "chmod +x"
check "the refusal is at the door — the test body never ran" \
    bash -c 'case "$1" in *"the gate let an executable test run"*) exit 1;; *) exit 0;; esac' _ "$OUT"

echo
echo "and refuses one staged 100644 even when the disk carries the bit:"
MODEREPO="$SANDBOX/tmp/modes-repo"
mkdir -p "$MODEREPO/tests"
git -C "$MODEREPO" -c init.defaultBranch=main init -q 2>/dev/null
FIXTURE2="$MODEREPO/tests/test_gate_fixture2.sh"
cat > "$FIXTURE2" <<FIXTURE
#!/bin/bash
. "$SANDBOX_REPO/tests/lib/sandbox.sh"
ok "the gate let an executable test run"
FIXTURE
git -C "$MODEREPO" add -- tests/test_gate_fixture2.sh   # stages 100644
chmod +x "$FIXTURE2"                                    # the bit arrives late
OUT2="$(env -u DESKCRAB_SANDBOX_ROOT -u DESKCRAB_SANDBOX_REPO \
        -u DESKCRAB_SANDBOX_LIB -u DESKCRAB_SANDBOX_NAME \
        bash "$FIXTURE2" 2>&1)" && RC2=0 || RC2=$?
check "the chmod-after-add run is refused" [ "$RC2" -ne 0 ]
check "the refusal names the staged mode" contains "$OUT2" "100644"

echo
echo "and the same fixture with the bit walks through:"
chmod +x "$FIXTURE"
OUT3="$(env -u DESKCRAB_SANDBOX_ROOT -u DESKCRAB_SANDBOX_REPO \
        -u DESKCRAB_SANDBOX_LIB -u DESKCRAB_SANDBOX_NAME \
        bash "$FIXTURE" 2>&1)" || true
check "the gate let the executable fixture into its run" \
    contains "$OUT3" "the gate let an executable test run"
check "no refusal printed for a file that carries the bit" \
    bash -c 'case "$1" in *"chmod +x"*) exit 1;; *) exit 0;; esac' _ "$OUT3"
