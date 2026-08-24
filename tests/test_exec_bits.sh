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
