#!/bin/bash
# The night takes up the queued backlog — specs/nightly.md rules 56 and
# 56a, specs/jobs.md rules 30-34. Queued briefs are already-written work, so
# each round they go out first, oldest first, through `crab job dispatch`,
# under the same cap and the same hard cutoff (default 06:00, re-checked
# before every dispatch), with DESKCRAB_JOB_NIGHT set so the door knows the
# window is open. A refusal that is not the block marker skips the brief for
# the rest of the night; the block marker ends the night; the dry run starts
# nothing. A builder still standing `dispatched` holds its cap slot (rule
# 57), and a night with no engineering threads at all still takes up the queue
# — the queue is the night's FIRST material, and missing selection material
# switches off the selector, never the queue.
# Run: bash tests/test_night_work_queue.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JS="$REPO/lib/job-status"
mkdir -p "$T/eng/records" "$T/jobs"

# Enough thread material that the night's work has something to select from when a
# case lets it get that far — one live open record (rule 58c); the model stub
# answers NOTHING so the queued phase stays the only dispatcher.
cat > "$T/eng/records/a-live-thread.md" <<'EOF'
---
id: a-live-thread
title: a live thread
opened: 2026-08-20 01:00:00
last_touched: 2026-08-22 12:00:00
state: open
summary: something for the selector to read
---

## 2026-08-22 12:00:00

Still owed, still small.
EOF

# The door, stubbed: every call recorded WITH the night flag's value, so the
# assertions can see both what was asked and under which window. `job
# dispatch` flips the real sidecar to dispatched — the night's work reads states
# back through the real job-status — and a refusal file switches the answer.
cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s NIGHT=%s\n' "\$*" "\${DESKCRAB_JOB_NIGHT:-}" >> "$T/crab-calls"
case "\$1" in
    jobs)
        echo "Detached jobs (logs in $T/jobs):"
        echo "  (none)"
        ;;
    job)
        if [ "\$2" = dispatch ]; then
            if [ -e "$T/door-blocked" ]; then
                echo "Not dispatched — the last job never began: every login refused"
                exit 1
            fi
            if [ -e "$T/refuse-\$3" ]; then
                echo "Not dispatched — job \$3's recorded description ('null') looks like a broken command substitution, not a brief."
                exit 1
            fi
            [ -e "$T/dispatch-sleep" ] && sleep 1
            "$JS" set "$T/jobs/\$3.json" state=dispatched
            echo "Job \$3 dispatched (unit deskcrab-job-\$3) — detached."
            exit 0
        fi
        echo "Job stub-x dispatched (unit deskcrab-job-stub-x) — detached."
        ;;
esac
exit 0
CRAB
chmod +x "$T/crab"

sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"NOTHING: the queue is the night'"'"'s work"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB

NOW="$(date +%s)"
night_work() {
    env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
        PROMISE_LEDGER="$T/promise-ledger.jsonl" WAKES_DIR="$T/dwakes" \
        NIGHT_WORK_THREADS_DIR="$T/eng" \
        NIGHT_WORK_LEDGER="$T/night-work/dispatched.tsv" \
        NIGHT_WORK_POLL=1 \
        "$@" \
        "$REPO/lib/night-work" run 2>&1
}
calls() { cat "$T/crab-calls" 2>/dev/null; }
dispatch_calls() { sandbox_count_in '^job dispatch ' "$T/crab-calls"; }
claude_n() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
reset() {
    rm -f "$T/crab-calls" "$SANDBOX_CLAUDE_LOG" "$T/door-blocked" \
        "$T/dispatch-sleep" "$T"/refuse-* "$T"/jobs/*.json
}
mkqueued() { # <id> <age-seconds> — a queued sidecar shelved AGE seconds ago
    "$JS" new "$T/jobs" "$1" "queued brief $1: do the $1 work in /tmp" "" /tmp queued
    python3 - "$T/jobs/$1.json" "$2" <<'PY'
import json, sys, time
p, age = sys.argv[1], int(sys.argv[2])
d = json.load(open(p))
d["queued_epoch"] = d["started_epoch"] = int(time.time()) - age
json.dump(d, open(p, "w"))
PY
}

echo "the queue goes first, oldest first, under the cap (rule 56a):"
reset
mkqueued q-old 7200
mkqueued q-mid 3600
mkqueued q-new 60
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "two dispatches — the cap of two, filled from the queue" "$(dispatch_calls)" "2"
check "the oldest went out" contains "$(calls)" "job dispatch q-old"
check "then the middle one" contains "$(calls)" "job dispatch q-mid"
case "$(calls)" in *"job dispatch q-new"*)
        fail "the newest must wait its turn behind the cap" "$(calls)" ;;
    *) ok "the newest waited its turn" ;; esac
first="$(grep -n 'job dispatch q-old' "$T/crab-calls" | cut -d: -f1)"
second="$(grep -n 'job dispatch q-mid' "$T/crab-calls" | cut -d: -f1)"
check "and oldest strictly before the rest" [ "$first" -lt "$second" ]
check_eq "the slate was full, so no selection call was spent" "$(claude_n)" "0"
check "the night log names each dispatch" contains "$out" "dispatched queued job 'q-old'"

echo
echo "every door call carries the night window (jobs.md rule 31):"
# The `crab jobs` listing is a read, not a door call; only `job …` dispatches
# owe the flag.
check_eq "no door call went out without DESKCRAB_JOB_NIGHT=1" \
    "$(sandbox_count_in '^job .*NIGHT=1$' "$T/crab-calls")" \
    "$(sandbox_count_in '^job ' "$T/crab-calls")"

echo
echo "a queued dispatch counts against the same cap the selector gets:"
reset
mkqueued q-solo 600
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "one queued dispatch" "$(dispatch_calls)" "1"
check_eq "the selector ran with the remaining slot" "$(claude_n)" "1"
check "and was offered AT MOST the one slot left" \
    grep -q "Pick AT MOST 1 items" "$T/model-stdin"

echo
echo "a builder still standing dispatched holds its cap slot (rule 57):"
reset
"$JS" new "$T/jobs" pre-flight "a builder between the dispatch call and its worker's first write" "" /tmp dispatched
mkqueued q-one 900
mkqueued q-two 600
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "only the one free slot was spent" "$(dispatch_calls)" "1"
check "on the older brief" contains "$(calls)" "job dispatch q-one"
case "$(calls)" in *"job dispatch q-two"*)
        fail "the in-flight builder must hold its slot against the cap" "$(calls)" ;;
    *) ok "the newer brief waited behind the in-flight builder" ;; esac
check_eq "the slate was full, so no selection call was spent" "$(claude_n)" "0"

echo
echo "no engineering threads: the night still takes up the queue (rule 56a):"
reset
mkqueued q-lone 900
out="$(night_work NIGHT_WORK_THREADS_DIR="$T/no-eng-dir" \
             NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))")"; rc=$?
check_eq "exits clean" "$rc" "0"
check "says selection is off, not that there is nothing to take up" \
    contains "$out" "the night still takes up the queued backlog"
check "the shelved brief went out" contains "$out" "dispatched queued job 'q-lone'"
check_eq "through the door" "$(sandbox_count_in 'job dispatch q-lone' "$T/crab-calls")" "1"
check_eq "and no selection call was ever spent" "$(claude_n)" "0"
check "the night ends when the queue is dry" \
    contains "$out" "the queue is dry and there are no engineering threads"

echo
echo "the hard cutoff stands in front of every dispatch (rule 56):"
reset
for i in 1 2 3 4 5; do mkqueued "q-c$i" $(( 1000 - i )); done
: > "$T/dispatch-sleep"   # each door call takes a second
out="$(night_work NIGHT_WORK_CAP=9 NIGHT_WORK_CUTOFF="@$(( $(date +%s) + 2 ))")"; rc=$?
check_eq "exits clean" "$rc" "0"
check "stops naming the cutoff" contains "$out" "stopped at the cutoff"
n="$(dispatch_calls)"
check "some briefs went out before the line" [ "$n" -ge 1 ]
check "and the line cut the rest off mid-queue" [ "$n" -lt 5 ]

echo
echo "a refused brief is skipped for the night, never retried in a loop:"
reset
mkqueued q-bad 900
mkqueued q-good 600
: > "$T/refuse-q-bad"
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=2)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "the refusal is named and skipped" contains "$out" "skipped for the night"
check_eq "the bad brief was asked exactly once across both rounds" \
    "$(sandbox_count_in 'job dispatch q-bad' "$T/crab-calls")" "1"
check_eq "the good one went out" \
    "$(sandbox_count_in 'job dispatch q-good' "$T/crab-calls")" "1"

echo
echo "the block marker ends the night for everyone (rule 60):"
reset
mkqueued q-walled 900
: > "$T/door-blocked"
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))")"; rc=$?
check_eq "exits clean — a wall is not the night's failure" "$rc" "0"
check "names the block" contains "$out" "the job door is blocked"
check_eq "exactly one attempt, then the night ends" "$(dispatch_calls)" "1"
check_eq "and no selection was spent against the wall" "$(claude_n)" "0"

echo
echo "the dry run names its would-dispatches and starts nothing (rule 61):"
reset
mkqueued q-dry 900
out="$(night_work DESKCRAB_NO_DISPATCH=1 NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "says what it would have dispatched" contains "$out" "would dispatch queued job 'q-dry'"
check_eq "the door was never called" "$(dispatch_calls)" "0"
check_eq "and the record stays queued" "$("$JS" get "$T/jobs/q-dry.json" state)" "queued"

echo
echo "the knob's default is the user's hard line:"
check "NIGHT_WORK_CUTOFF defaults to 06:00" \
    grep -q 'NIGHT_WORK_CUTOFF:-06:00' "$REPO/lib/night-work"
