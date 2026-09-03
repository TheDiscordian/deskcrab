#!/bin/bash
# The dispatch workdir — specs/nightly.md rule 60a. Every selection dispatch
# the night's work makes carries an explicit, verified -C: an empty or "-"
# workdir field used to fall through to a dispatch with no -C at all, so the
# builder inherited the nightly process's own cwd — not a git checkout; all
# four 2026-08-15 dispatches and 20260903-040620 again went out that way, and
# three of the four builders survived only by walking to the real repo by
# hand. The assertions here: the empty and "-" fields resolve to the deployed
# symlink's parent and the sidecar records that same path; a missing symlink,
# and one whose parent holds no .git, fall back to the script's own checkout;
# an explicit git workdir dispatches exactly as given; a workdir that exists
# but is no git tree, and one that does not exist, are REFUSED loudly — night
# log and stderr both, naming workdir, key and title — while the round
# continues to the next pick; the dry run resolves and verifies the same way;
# and no dispatch path without -C remains in the script at all.
# Run: bash tests/test_night_work_workdir.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
mkdir -p "$T/eng/records" "$T/jobs"

# One open record so selection is on at all; the picks below are the stub
# selector's answers, not this record's.
cat > "$T/eng/records/a-latch-that-sticks.md" <<'EOF'
---
id: a-latch-that-sticks
title: a latch that sticks
opened: 2026-08-20 01:00:00
last_touched: 2026-08-22 12:00:00
state: open
summary: the greenhouse latch sticks
---

## 2026-08-22 12:00:00

The greenhouse latch sticks and wants a builder on it.
EOF

# The deployed shape (nightly.md rule 6a): ~/.local/lib/deskcrab is a symlink
# into the checkout's lib/. FAKE stands in for the live checkout — a real git
# work tree, because rule 60a's final gate is `git rev-parse`, not a marker.
FAKE="$T/fakecheckout"
mkdir -p "$FAKE/lib"
git init -q "$FAKE"
EXPLICIT="$T/explicit"           # an explicit git workdir of its own
mkdir -p "$EXPLICIT"
git init -q "$EXPLICIT"
PLAIN="$T/plaindir"              # exists, but no git tree anywhere above it
mkdir -p "$PLAIN"
mkdir -p "$T/nogit/lib"          # a lib/ whose parent holds no .git

deploy_symlink() {  # <lib dir to point at>; no argument removes the symlink
    mkdir -p "$HOME/.local/lib"
    rm -f "$HOME/.local/lib/deskcrab"
    if [ -n "${1:-}" ]; then ln -s "$1" "$HOME/.local/lib/deskcrab"; fi
}

# The door, stubbed: every call recorded, and the sidecar written through the
# REAL writer with exactly what rode -C — the same call shape the real door
# makes (lib/common.sh job_start) — so "the sidecar records the resolved
# workdir" is proven against the true record format.
cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
case "\$1" in
    jobs)
        echo "Detached jobs (logs in $T/jobs):"
        echo "  (none)"
        ;;
    job)
        shift
        wd=""
        if [ "\${1:-}" = "-C" ]; then wd="\$2"; shift 2; fi
        n=\$(( \$(cat "$T/job-n" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$T/job-n"
        "$REPO/lib/job-status" new "$T/jobs" "stub-\$n" "\$*" "" "\$wd" dispatched >/dev/null 2>&1
        echo "Job stub-\$n dispatched (unit deskcrab-job-stub-\$n) — detached."
        ;;
esac
exit 0
CRAB
chmod +x "$T/crab"

NOW="$(date +%s)"
LEDGER="$T/night-work/dispatched.tsv"
ERR="$T/night-stderr"

night_work() {  # [env overrides...] — stderr lands in $ERR so the loud
                # refusal can be proven on both channels separately
    env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
        NIGHT_WORK_THREADS_DIR="$T/eng" \
        NIGHT_WORK_LEDGER="$LEDGER" \
        NIGHT_WORK_POLL=1 \
        NIGHT_WORK_MODEL=stub-claude \
        NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" \
        NIGHT_WORK_ROUNDS_MAX=1 \
        "$@" \
        "$REPO/lib/night-work" run 2>"$ERR"
}
job_calls() { sandbox_count_in '^job ' "$T/crab-calls"; }
sidecar_wd() { "$REPO/lib/job-status" get "$T/jobs/stub-$1.json" workdir 2>/dev/null; }
reset() { rm -f "$T/crab-calls" "$T/job-n" "$T"/jobs/stub-*.json "$T"/jobs/stub-*.lock \
                "$SANDBOX_CLAUDE_LOG" "$T/model-stdin" "$LEDGER" "$ERR"; }

BRIEFTEXT='Free the latch, oil the hinge, run the latch suite before reporting done, and commit the work in this same run so nothing is left dangling on the bench overnight.'
selector() {  # <key> <wd-field> [<key2> <wd2>] — the stub selector answers
              # one or two TASK picks with the given workdir fields
    local answer="TASK: $1 | $2 | Fix the sticking latch\nBRIEF:\n$BRIEFTEXT\nEND"
    if [ -n "${3:-}" ]; then
        answer="$answer\nTASK: $3 | ${4:-} | Oil the second hinge\nBRIEF:\n$BRIEFTEXT\nEND"
    fi
    sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"$answer"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
}

echo "an empty workdir field resolves to the deployed symlink's parent (rule 60a):"
reset
deploy_symlink "$FAKE/lib"
selector empty-wd-pick ""
out="$(night_work)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "exactly one pick reached the door" "$(job_calls)" "1"
check "the dispatch carried -C with the resolved checkout" \
    grep -q -- "^job -C $FAKE The night's work" "$T/crab-calls"
check_eq "and the sidecar records that same path — one source of truth" \
    "$(sidecar_wd 1)" "$FAKE"
check "the ledger carries the pick" grep -q "empty-wd-pick" "$LEDGER"

echo
echo "the literal '-' resolves identically:"
reset
selector dash-wd-pick "-"
out="$(night_work)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "exactly one pick reached the door" "$(job_calls)" "1"
check "the dispatch carried -C with the resolved checkout" \
    grep -q -- "^job -C $FAKE The night's work" "$T/crab-calls"
check_eq "and the sidecar records that same path" "$(sidecar_wd 1)" "$FAKE"

echo
echo "no deployed symlink: the fallback is the script's own checkout:"
reset
deploy_symlink
selector no-symlink-pick "-"
out="$(night_work)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "exactly one pick reached the door" "$(job_calls)" "1"
check "the dispatch carried -C with the script's own repo root" \
    grep -q -- "^job -C $REPO The night's work" "$T/crab-calls"
check_eq "and the sidecar records that same path" "$(sidecar_wd 1)" "$REPO"

echo
echo "a symlink whose parent holds no .git falls back the same way:"
reset
deploy_symlink "$T/nogit/lib"
selector nogit-symlink-pick ""
out="$(night_work)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "exactly one pick reached the door" "$(job_calls)" "1"
check "the dispatch fell back to the script's own repo root" \
    grep -q -- "^job -C $REPO The night's work" "$T/crab-calls"
check_eq "and the sidecar records that same path" "$(sidecar_wd 1)" "$REPO"

echo
echo "an explicit git workdir dispatches exactly as given — the resolver never touches it:"
reset
deploy_symlink "$FAKE/lib"
selector explicit-wd-pick "$EXPLICIT"
out="$(night_work)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "exactly one pick reached the door" "$(job_calls)" "1"
check "the dispatch carried the supplied workdir untouched" \
    grep -q -- "^job -C $EXPLICIT The night's work" "$T/crab-calls"
check_eq "and the sidecar records the supplied path" "$(sidecar_wd 1)" "$EXPLICIT"
check_eq "the deployed checkout was never substituted" \
    "$(sandbox_count_in "$FAKE" "$T/crab-calls")" "0"

echo
echo "a workdir that exists but is no git tree is REFUSED — and the round continues:"
reset
selector bad-wd-pick "$PLAIN" good-wd-pick "$EXPLICIT"
out="$(night_work)"; rc=$?
check_eq "exits clean — a refused pick never aborts the run" "$rc" "0"
check "the refusal is loud on the night log" \
    contains "$out" "dispatch REFUSED for 'bad-wd-pick'"
check "naming the rejected workdir" contains "$out" "workdir '$PLAIN' is not a git work tree"
check "and the pick's title" contains "$out" "Fix the sticking latch"
check "the refusal reaches stderr too — unmistakable, never only the log" \
    grep -q "dispatch REFUSED for 'bad-wd-pick'" "$ERR"
check "with the workdir named there as well" grep -q -- "$PLAIN" "$ERR"
check_eq "the refused pick never reached the door, the next pick still did" \
    "$(job_calls)" "1"
check "and the dispatched one is the valid neighbour" \
    grep -q -- "^job -C $EXPLICIT The night's work, from the open item 'good-wd-pick'" "$T/crab-calls"
check_eq "the refused pick never lands on the ledger" \
    "$(sandbox_count_in 'bad-wd-pick' "$LEDGER")" "0"
check "while the valid neighbour does" grep -q "good-wd-pick" "$LEDGER"

echo
echo "a workdir that does not exist at all is refused the same way:"
reset
selector ghost-wd-pick "$T/never-was"
out="$(night_work)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "the refusal names the missing workdir" \
    contains "$out" "workdir '$T/never-was' is not a git work tree"
check "and the key" contains "$out" "dispatch REFUSED for 'ghost-wd-pick'"
check "on stderr too" grep -q "ghost-wd-pick" "$ERR"
check_eq "nothing reached the door" "$(job_calls)" "0"
check "no ledger was written" test ! -s "$LEDGER"

echo
echo "the dry run resolves and verifies exactly as a live round (rule 61):"
reset
selector dry-wd-pick "-" dry-bad-pick "$PLAIN"
out="$(night_work DESKCRAB_NO_DISPATCH=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "the would-dispatch line names the resolved workdir" \
    contains "$out" "would dispatch 'dry-wd-pick' in $FAKE"
check "the bad workdir is refused even dry — never counted a would-dispatch" \
    contains "$out" "dispatch REFUSED for 'dry-bad-pick'"
check_eq "and is not among the would-dispatches" \
    "$(printf '%s\n' "$out" | grep -c "would dispatch 'dry-bad-pick'")" "0"
check_eq "nothing reached the door" "$(job_calls)" "0"
check "no ledger was written" test ! -s "$LEDGER"

echo
echo "no dispatch path without -C remains in the script:"
check_eq "the bare '\"\$CRAB\" job \"\$BRIEF\"' branch is gone" \
    "$(sandbox_count_in '"\$CRAB" job "\$BRIEF"' "$REPO/lib/night-work")" "0"
check_eq "the one selection dispatch carries -C" \
    "$(sandbox_count_in '"\$CRAB" job -C "\$WD" "\$BRIEF"' "$REPO/lib/night-work")" "1"
