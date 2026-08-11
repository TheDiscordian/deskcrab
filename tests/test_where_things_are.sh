#!/bin/bash
# The index layer: every path it names exists, and every drawer she owns is
# named. Run: bash tests/test_where_things_are.sh
#
# specs/prompt-assembly.md §22-23. The failure this closes is the engineering
# threads: 34 KB written to nightly, reachable from no prompt path at all — a
# one-way sink. The rule cuts both ways, so this file checks both: a drawer
# that exists must be named, and a path that is named must exist. A prompt that
# points at something that is not there teaches her the block is unreliable.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/conduct" "$D/wants" "$D/engineering/records" "$D/memory" \
         "$ARCHIVE_DIR" "$DAY_JOURNAL_DIR" "$WAKES_DIR" "$SANDBOX/home/Library"
printf '# Wants\n\n- 🎼 **Learn to read a score**\n' > "$D/wants.md"
printf 'a want body\n' > "$D/wants/score.md"
printf '# Conduct\n\n- 🎯 **A rule** → `a-rule.md`\n' > "$D/conduct/CONDUCT.md"
printf 'a rule body\n' > "$D/conduct/a-rule.md"
printf '# Threads\n' > "$D/engineering/INDEX.md"
printf '# Open threads\n' > "$D/engineering.md"
printf '' > "$D/memory/memory.db"
printf 'booked\n' > "$WAKES_DIR/ledger.log"
printf '{}\n' > "$DAY_JOURNAL_DIR/2026-08-07.jsonl"
printf 'a line she wrote\n' > "$SANDBOX/home/Library/README.md"

cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS=""
EOF

run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

INDEX="$(run '_prompt_layer_index')"
printf '%s\n' "$INDEX" | sed 's/^/  | /'
echo

echo "every path the index names is really there:"
missing=0
while read -r path _; do
    case "$path" in /*) ;; *) continue ;; esac
    [ -e "$path" ] || { missing=1; fail "the index names a path that does not exist" "$path"; }
done < <(printf '%s\n' "$INDEX" | sed -n 's/^  \([^ ]*\) —.*/\1/p')
[ "$missing" = 0 ] && ok "every absolute path in the index exists"

echo
echo "every drawer she owns is named:"
# The minimum list is rule 22's: the shelf and its bodies, conduct and its
# index, the engineering threads and their index, the day journal, the memory
# store, the library, the archive, and the repo.
for drawer in "$D/wants.md" "$D/conduct" "$D/engineering/records" \
              "$D/engineering/INDEX.md" \
              "$D/engineering.md" "$DAY_JOURNAL_DIR" "$D/memory/memory.db" \
              "$ARCHIVE_DIR" "$SANDBOX/home/Library" "$SANDBOX_REPO"; do
    check "$(basename "$drawer") is in the index" contains "$INDEX" "$drawer"
done
check "the wake ledger is named — the nightly tidy writes it" \
    contains "$INDEX" "$WAKES_DIR/ledger.log"
check "the commands that hold the full lists are named" \
    contains "$INDEX" "crab status"

echo
echo "a drawer that is not there is not named:"
rm -rf "$D/engineering"
INDEX2="$(run '_prompt_layer_index')"
refute "a missing engineering index is not claimed" \
    contains "$INDEX2" "$D/engineering/INDEX.md"
check "and the rest of the index survives it" contains "$INDEX2" "$D/wants.md"

echo
echo "the index reaches the prompt on every profile that can open a drawer:"
for p in turn wake job; do
    check "$p carries WHERE THINGS ARE" \
        contains "$(run "build_system_prompt --profile $p")" "WHERE THINGS ARE"
done
refute "a classifier does not — it has nothing to open" \
    contains "$(run 'build_system_prompt --profile classify')" "WHERE THINGS ARE"
