#!/bin/bash
# The night's work — specs/nightly.md rules 54-61. The night's idle stretch
# dispatches builders at the LIVE open engineering records (rule 58c — the
# records drawer, state: open, never the frozen pre-records archive that
# bought finished work four nights over), through the job door,
# capped, until a wall-clock cutoff. The assertions here are about what the
# night's work itself owns: the daylight window guard, the cap counted from every
# running job, the validation that stands between the model's answer and a
# dispatched builder, the ledger that stops a thread being dispatched twice,
# the early end on a dry backlog, the hard stop on a blocked door and at the
# cutoff — and that a run which cannot even parse its own cutoff never
# unstamps the night. What the model judges is the model's; what reaches the
# door is ours. Run: bash tests/test_night_work.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
mkdir -p "$T/eng/records" "$T/jobs"

# The live shelf (rule 58c): stateful records under the records drawer. One
# genuinely actionable and newest-touched, one older and covered by a running
# job, and one SETTLED — the settled one must never enter the prompt at all.
# The MODEL is stubbed, so what these prove is that the right material
# reaches the prompt — the night-side skips are proven against the stub's
# own answers below.
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

The greenhouse latch sticks. Repo /tmp/greenhouse. Fix wants a builder.
EOF
cat > "$T/eng/records/resurface-the-path.md" <<'EOF'
---
id: resurface-the-path
title: resurface the path
opened: 2026-08-18 09:00:00
last_touched: 2026-08-19 09:00:00
state: open
summary: already running as job live-1
---

## 2026-08-19 09:00:00

A job is on it.
EOF
cat > "$T/eng/records/the-weather-decision.md" <<'EOF'
---
id: the-weather-decision
title: the weather decision
opened: 2026-08-17 08:00:00
last_touched: 2026-08-18 08:00:00
state: settled
settled_at: 2026-08-18 08:00:00
settled_by: it rained and that was that
summary: nothing left to do
---

## 2026-08-18 08:00:00

SETTLED-RECORD-MARK a settled record's text must never reach the selector.
EOF

# The frozen pre-records archive (rule 58c): CLOSED to the selector. Every
# marker planted here must be absent from the prompt — the drain bought
# finished work four nights over from exactly these files.
printf '## an old prose entry\nFROZEN-ARCHIVE-MARK the thread log is history.\n' > "$T/engineering.md"
printf '# Threads\nFROZEN-INDEX-MARK\n' > "$T/eng/INDEX.md"
printf '# Open\n- FROZEN-OPEN-MARK the archive open list\n' > "$T/eng/OPEN.md"

# The rest of the owed-work shelf (rule 58b): a promise ledger holding one
# sweep miss (owed) and one raw live catch (never material — the live
# checker runs heavily false), and one pending wake whose reason is
# builder-shaped work.
PLEDGER="$T/promise-ledger.jsonl"
cat > "$PLEDGER" <<EOF
{"time": "$(date +%Y-%m-%dT03:15:00)", "type": "sweep", "day": "$(date +%F)", "promise": "I'll oil the greenhouse door runners tonight", "said_at": "12:00", "why": "no later record touches the runners"}
{"time": "$(date +%Y-%m-%dT03:16:00)", "kind": "desktop", "promise": "a raw live catch that must never reach the selector", "wake": "booked 3m out"}
EOF
DWAKES="$T/dwakes"
mkdir -p "$DWAKES"
printf '%s\tevent\trewire the drip-line valve in /tmp/greenhouse — the builder-shaped chore parked on the queue\t%s\tself\n' \
    "$(( $(date +%s) + 7200 ))" "$(( $(date +%s) - 600 ))" > "$DWAKES/deskcrab-wake-owed.wake"

# The door, stubbed: every call recorded, `jobs` answers a canned list,
# `job` answers the dispatch line with a counted id. A file switches it to
# the block refusal.
cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
case "\$1" in
    jobs)
        echo "Detached jobs (logs in $T/jobs):"
        echo "  - running (5m so far)  live-1 — resurface the path"
        ;;
    job)
        if [ -e "$T/door-blocked" ]; then
            echo "Not dispatched — the last job never began: every login refused"
            exit 1
        fi
        n=\$(( \$(cat "$T/job-n" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$T/job-n"
        echo "Job stub-\$n dispatched (unit deskcrab-job-stub-\$n) — detached."
        ;;
esac
exit 0
CRAB
chmod +x "$T/crab"

NOW="$(date +%s)"
LEDGER="$T/night-work/dispatched.tsv"

night_work() {  # [env overrides...] — runs the night's work with the harness's paths pinned;
           # the overrides come LAST, so a test may repoint any pinned path
    env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
        PROMISE_LEDGER="$PLEDGER" WAKES_DIR="$DWAKES" \
        NIGHT_WORK_THREADS_DIR="$T/eng" \
        NIGHT_WORK_LEDGER="$LEDGER" \
        NIGHT_WORK_POLL=1 \
        "$@" \
        "$REPO/lib/night-work" run 2>&1
}
calls()     { cat "$T/crab-calls" 2>/dev/null; }
job_calls() { sandbox_count_in '^job ' "$T/crab-calls"; }
claude_n()  { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
reset()     { rm -f "$T/crab-calls" "$T/job-n" "$SANDBOX_CLAUDE_LOG" \
                    "$T/model-stdin" "$LEDGER" "$T/door-blocked"; }

# The selector, stubbed: one good pick, one null-shaped brief, one brief too
# thin to act on, and one whose thread is already on the ledger. Only the
# first may reach the door.
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"TASK: a-latch-that-sticks | - | Fix the sticking latch\nBRIEF:\nIn /tmp/greenhouse, from the thread a-latch-that-sticks: free the latch, oil the hinge, and run the latch test suite before reporting done. Verify by closing the door twice.\nEND\nTASK: null-brief-thread | - | A broken substitution\nBRIEF:\nnull\nEND\nTASK: thin-brief-thread | - | Too thin to act on\nBRIEF:\nfix it\nEND\nTASK: already-ledgered | - | Dispatched last night\nBRIEF:\nThis thread was already dispatched by an earlier round and its ledger line below must keep it from going out twice tonight, however plausible this text reads.\nEND"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB

echo "the daylight window guard: a catch-up run far from the cutoff takes up nothing:"
reset
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 90000 ))")"; rc=$?
check_eq "exits clean" "$rc" "0"
check "says it is outside the window" \
    contains "$out" "outside the"
check_eq "the model was never consulted" "$(claude_n)" "0"
check_eq "nothing reached the door" "$(job_calls)" "0"

echo
echo "a selection round: validation stands between the model and the door:"
reset
mkdir -p "$T/night-work"
printf '2026-01-01\talready-ledgered\told-1\tDispatched last night\n' > "$LEDGER"
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check_eq "the selector ran once" "$(claude_n)" "1"
check "the prompt carried the open record, title and all (rule 58c)" \
    grep -q "a latch that sticks" "$T/model-stdin"
check "with its body" \
    grep -q "The greenhouse latch sticks" "$T/model-stdin"
check "and its state readable in its own front matter" \
    grep -q "state: open" "$T/model-stdin"
LATCH_AT="$(grep -n -- '--- a-latch-that-sticks ---' "$T/model-stdin" | head -1 | cut -d: -f1)"
PATH_AT="$(grep -n -- '--- resurface-the-path ---' "$T/model-stdin" | head -1 | cut -d: -f1)"
if [ -n "$LATCH_AT" ] && [ -n "$PATH_AT" ] && [ "$LATCH_AT" -lt "$PATH_AT" ]; then
    ok "open records ride newest-touched first"
else
    fail "open records must ride newest-touched first" "latch=$LATCH_AT path=$PATH_AT"
fi
check_eq "the settled record never enters the prompt (rule 58c)" \
    "$(sandbox_count_in 'SETTLED-RECORD-MARK\|the weather decision' "$T/model-stdin")" "0"
check_eq "the frozen archive never enters the prompt (rule 58c)" \
    "$(sandbox_count_in 'FROZEN-ARCHIVE-MARK\|FROZEN-OPEN-MARK\|FROZEN-INDEX-MARK' "$T/model-stdin")" "0"
check "the prompt carried the job list as duplicate evidence" \
    grep -q "resurface the path" "$T/model-stdin"
check "the prompt carried the ledger of already-dispatched threads" \
    grep -q "already-ledgered" "$T/model-stdin"
check "the prompt carried the sweep's missed promises (rule 58b)" \
    grep -q "PROMISES THE NIGHT SWEEP FOUND MISSED" "$T/model-stdin"
check "with the miss quoted" \
    grep -q "oil the greenhouse door runners" "$T/model-stdin"
check_eq "and the live checker's raw catch kept OUT of the material" \
    "$(sandbox_count_in 'raw live catch' "$T/model-stdin")" "0"
check "the prompt carried the pending wakes (rule 58b)" \
    grep -q "WAKES ALREADY ON THE BOOKS" "$T/model-stdin"
check "with the parked builder-shaped reason" \
    grep -q "rewire the drip-line valve" "$T/model-stdin"
check_eq "exactly ONE pick reached the door" "$(job_calls)" "1"
check "and it was the actionable one, brief intact" \
    grep -q "free the latch, oil the hinge" "$T/crab-calls"
check "the brief names its source item for the builder" \
    grep -q "from the open item 'a-latch-that-sticks'" "$T/crab-calls"
check "the null-shaped brief was skipped and said so" \
    contains "$out" "null-shaped brief — skipped"
check "the thin brief was skipped and said so" \
    contains "$out" "too thin to act on"
check "the ledgered thread was skipped and said so" \
    contains "$out" "already on the ledger — skipped"
check_eq "the ledger gained exactly one line" "$(wc -l < "$LEDGER")" "2"
check "recording the thread key beside the job id" \
    grep -q "a-latch-that-sticks	stub-1	Fix the sticking latch" "$LEDGER"

echo
echo "the cap counts EVERY running job, not only the night's own — and defaults"
echo "to the user's overnight ceiling of two:"
reset
for i in 1 2 3 4; do
    printf '{"id": "busy-%s", "state": "running"}\n' "$i" > "$T/jobs/busy-$i.json"
done
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "a full slate is waited out, everyone's jobs counted, at the default cap of 2" \
    contains "$out" "cap full (4 running, cap 2)"
check_eq "no selection was even asked for" "$(claude_n)" "0"
check_eq "nothing reached the door" "$(job_calls)" "0"
rm -f "$T"/jobs/busy-*.json

echo
echo "a dry backlog ends the night's work early — no polling an empty list to the cutoff:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"NOTHING: every thread is a note or already covered"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))")"; rc=$?
check_eq "exits clean" "$rc" "0"
check "names the dry backlog as its stop" contains "$out" "the backlog is dry"
check_eq "one selection call, not a poll loop" "$(claude_n)" "1"

echo
echo "a blocked job door ends dispatch for the night:"
reset
: > "$T/door-blocked"
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"TASK: a-latch-that-sticks | - | Fix the sticking latch\nBRIEF:\nIn /tmp/greenhouse, from the thread a-latch-that-sticks: free the latch, oil the hinge, and run the latch test suite before reporting done. Verify by closing the door twice.\nEND"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
out="$(night_work NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))")"; rc=$?
check_eq "exits clean — a wall is not the night's failure" "$rc" "0"
check "names the block" contains "$out" "the job door is blocked"
check "and stops for the night" contains "$out" "no builder can begin"
check_eq "no second dispatch was attempted" "$(job_calls)" "1"
[ -f "$LEDGER" ] && fail "a refused dispatch must not land on the ledger" \
    || ok "a refused dispatch never lands on the ledger"

echo
echo "the cutoff stops dispatch before anything else happens:"
reset
out="$(night_work NIGHT_WORK_CUTOFF="@$NOW")"; rc=$?
check_eq "exits clean" "$rc" "0"
check "names the cutoff" contains "$out" "stopped at the cutoff"
check_eq "no selection past the cutoff" "$(claude_n)" "0"
check_eq "no dispatch past the cutoff" "$(job_calls)" "0"

echo
echo "dry-run (rule 61): real selection, nothing started, no ledger:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"TASK: a-latch-that-sticks | - | Fix the sticking latch\nBRIEF:\nIn /tmp/greenhouse, from the thread a-latch-that-sticks: free the latch, oil the hinge, and run the latch test suite before reporting done. Verify by closing the door twice.\nEND"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
out="$(night_work DESKCRAB_NO_DISPATCH=1 NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "announces the dry-run" contains "$out" "dry-run"
check "says what it would have dispatched" contains "$out" "would dispatch 'a-latch-that-sticks'"
check_eq "the selector genuinely ran" "$(claude_n)" "1"
[ -f "$LEDGER" ] && fail "a dry-run must not write the ledger" \
    || ok "the ledger was not written"

echo
echo "the phase is wired into sleep, and its death never unstamps the night:"
reset
cat > "$T/crab-sleep" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
case "\$*" in
    "memory ingest") echo "ingest: 0 added" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-sleep"
mkdir -p "$T/data-sleep"
out="$(env CRAB_BIN="$T/crab-sleep" XDG_DATA_HOME="$T/data-sleep-home" \
    JOBS_DIR="$T/jobs" DAY_JOURNAL_DIR="$T/journal" \
    NIGHT_WORK_THREADS_DIR="$T/eng" \
    NIGHT_WORK_CUTOFF="not-a-time" \
    "$REPO/lib/sleep-nightly" run 2>&1)"; rc=$?
check_eq "sleep exits with the ingest's own zero" "$rc" "0"
STAMP="$T/data-sleep-home/deskcrab/last-slept"
[ -f "$STAMP" ] && ok "the night stamped" || fail "the night must stamp" "$out"
check "the night's work ran inside the sleep pipeline" \
    contains "$out" "night-work:"
check "an unparseable cutoff is loud" \
    contains "$out" "cannot parse NIGHT_WORK_CUTOFF"
check "and the night still counts" \
    contains "$out" "the night's work did not finish — the night still counts"
NIGHTLOG="$(ls "$T/data-sleep-home/deskcrab/sleep/"*.log 2>/dev/null | head -1)"
if [ -n "$NIGHTLOG" ]; then
    scan_line="$(grep -n "claudism" "$NIGHTLOG" | head -1 | cut -d: -f1)"
    sweep_line="$(grep -n "promise-check:" "$NIGHTLOG" | head -1 | cut -d: -f1)"
    night_line="$(grep -n "night-work:" "$NIGHTLOG" | head -1 | cut -d: -f1)"
    if [ -n "$scan_line" ] && [ -n "$sweep_line" ] && [ -n "$night_line" ] \
            && [ "$sweep_line" -gt "$scan_line" ] && [ "$night_line" -gt "$sweep_line" ]; then
        ok "the sweep runs after the review, and the night's work last — its misses are the night's material"
    else
        fail "the order must be review, sweep, night's work (rule 54)" \
            "scan=$scan_line sweep=$sweep_line night=$night_line"
    fi
else
    fail "no night log written" "$out"
fi

echo
echo "an unreadable promise ledger is presented as unreadable, never silently omitted:"
reset
mkdir -p "$T/ledger-as-dir"
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"NOTHING: judging from less than the whole shelf"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
out="$(night_work PROMISE_LEDGER="$T/ledger-as-dir" \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "the selector was told the shelf is short" \
    grep -q "the promise ledger could not be read tonight" "$T/model-stdin"
check "and the night log names it" \
    contains "$out" "the promise ledger could not be read — the selector is told so"

echo
echo "the off switch:"
reset
out="$(night_work NIGHT_WORK=0 NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))")"; rc=$?
check_eq "exits clean" "$rc" "0"
check "says it is off" contains "$out" "off (NIGHT_WORK=0)"
check_eq "and does nothing" "$(claude_n)$(job_calls)" "00"
