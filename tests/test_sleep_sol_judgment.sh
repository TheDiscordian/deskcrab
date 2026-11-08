#!/bin/bash
# The night's judge — specs/nightly.md rules 14c-14e, the sleep-orchestration
# correction of 2026-08-25 (the record
# sleep-should-be-orchestrated-and-judged-by-sol-h). Every sleep judgment —
# retention, deduplication, reconciliation, work selection — runs on ONE
# judge, gpt-5.6-sol at high reasoning effort by default, with no fallback
# model; the summariser tier only condenses FOR the judge and never decides
# what survives. What this suite proves is the EFFECTIVE call graph, at the
# shipped defaults, against a stub codex and a stub claude — never a name
# asserted from the source text, always the argv an engine was actually
# handed. Run: bash tests/test_sleep_sol_judgment.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

claude_n() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
codex_n()  { sandbox_count_in '^exec' "$SANDBOX_CODEX_LOG"; }
reset()    { rm -f "$SANDBOX_CLAUDE_LOG" "$SANDBOX_CODEX_LOG" \
                   "$T"/cx-state-* "$T/crab-calls" "$T/job-n"; }

# nightly_judge <env...> -- <args of nightly_judge_walk>, prompt on stdin.
# Sources common.sh and then the one shared walk, exactly as every judging
# phase does.
nightly_judge() {
    local -a envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    env ${envs[@]+"${envs[@]}"} bash -c '
        source "$1/lib/common.sh" >/dev/null 2>&1
        source "$1/lib/nightly-judge"
        shift
        nightly_judge_walk "$@"' _ "$REPO" "$@"
}

echo "the shared walk, codex road: the default judge reaches codex exec at"
echo "gpt-5.6-sol, effort high, and no claude call stands beside it:"
reset
out="$(printf 'judge this' | nightly_judge DESKCRAB_CODEX_STATE="$T/cx-state-a" -- \
    gpt-5.6-sol high 30 test-judge '^stub')"; rc=$?
check_eq "the walk answers" "$rc" "0"
check "with the codex stub's reply" contains "$out" "stub reply."
check "the codex argv names the model" grep -q -- "-m gpt-5.6-sol" "$SANDBOX_CODEX_LOG"
check "and the reasoning effort" grep -q -- "model_reasoning_effort=high" "$SANDBOX_CODEX_LOG"
check "on the exec road" grep -q "^exec" "$SANDBOX_CODEX_LOG"
check_eq "not one claude call" "$(claude_n)" "0"

echo
echo "a codex refusal ends the walk — cooldown recorded, NO fallback model"
echo "(rule 14e):"
reset
sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CODEX_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"error","message":"You have hit your usage limit. Try again later."}'
exit 1
STUB
out="$(printf 'judge this' | nightly_judge DESKCRAB_CODEX_STATE="$T/cx-state-b" -- \
    gpt-5.6-sol high 30 test-judge '^stub' 2>&1)"; rc=$?
check_eq "the walk returns failure" "$rc" "1"
check "and says no cheaper model may judge" \
    contains "$out" "no cheaper model may make it"
check "the cooldown is recorded in the scratch codex state" \
    grep -q "^blocked-until" "$T/cx-state-b"
check_eq "and NOT ONE claude call was made in the judge's place" "$(claude_n)" "0"

echo
echo "a cooling engine is not even booted — and still no fallback:"
out="$(printf 'judge this' | nightly_judge DESKCRAB_CODEX_STATE="$T/cx-state-b" -- \
    gpt-5.6-sol high 30 test-judge '^stub' 2>&1)"; rc=$?
check_eq "the walk returns failure" "$rc" "1"
check "naming the cooling engine" contains "$out" "unavailable"
check_eq "no claude call" "$(claude_n)" "0"
cp "$REPO/tests/lib/stubs/codex" "$SANDBOX_BIN/codex"; chmod +x "$SANDBOX_BIN/codex"

echo
echo "a Claude-named override still walks the flat list on its one model:"
reset
out="$(printf 'judge this' | nightly_judge DESKCRAB_CODEX_STATE="$T/cx-state-c" -- \
    stub-claude high 30 test-judge '^stub')"; rc=$?
check_eq "the walk answers" "$rc" "0"
check "the claude argv names the override model" \
    grep -q -- "--model stub-claude" "$SANDBOX_CLAUDE_LOG"
check_eq "and codex was never consulted" "$(codex_n)" "0"

# ---------------------------------------------------------------------------
echo
echo "the night-work selector, at the shipped defaults: the judgment call is"
echo "codex exec at gpt-5.6-sol high, and the pick still reaches the door:"
reset
mkdir -p "$T/eng/records" "$T/jobs"
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
cat > "$T/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/crab-calls"
case "\$1" in
    jobs) echo "Detached jobs:" ;;
    job)
        n=\$(( \$(cat "$T/job-n" 2>/dev/null || echo 0) + 1 ))
        echo "\$n" > "$T/job-n"
        echo "Job stub-\$n dispatched (unit deskcrab-job-stub-\$n) — detached."
        ;;
esac
exit 0
CRAB
chmod +x "$T/crab"
sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CODEX_LOG}"
cat > "$T/selector-stdin"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"TASK: a-latch-that-sticks | - | Fix the sticking latch\nBRIEF:\nIn /tmp/greenhouse, from the thread a-latch-that-sticks: free the latch, oil the hinge, and run the latch test suite before reporting done. Verify by closing the door twice.\nEND"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2}}'
STUB
NOW="$(date +%s)"
night_work() {  # NO model pin — the shipped default is the subject
    env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
        NIGHT_WORK_THREADS_DIR="$T/eng" \
        NIGHT_WORK_LEDGER="$T/night-work/dispatched.tsv" \
        NIGHT_WORK_POLL=1 \
        "$@" \
        "$REPO/lib/night-work" run 2>&1
}
out="$(night_work DESKCRAB_CODEX_STATE="$T/cx-state-nw" \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "the night's work exits clean" "$rc" "0"
check_eq "one selection call went to the judge" "$(codex_n)" "1"
check "at the default gpt-5.6-sol" grep -q -- "-m gpt-5.6-sol" "$SANDBOX_CODEX_LOG"
check "at the default high effort" grep -q -- "model_reasoning_effort=high" "$SANDBOX_CODEX_LOG"
check "the selector's material reached the judge" \
    grep -q "a latch that sticks" "$T/selector-stdin"
check_eq "not one claude call selected in its place" "$(claude_n)" "0"
check "and the pick reached the door" grep -q "free the latch" "$T/crab-calls"

echo
echo "a refused judge selects NOTHING — the round ends with no Sonnet and no"
echo "Opus stepping in, and the cooldown stands recorded:"
reset
rm -f "$T/night-work/dispatched.tsv" "$T/selector-stdin"
sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CODEX_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"error","message":"You have hit your usage limit. Try again later."}'
exit 1
STUB
out="$(night_work DESKCRAB_CODEX_STATE="$T/cx-state-nw2" \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean — a dry judge never costs the night" "$rc" "0"
check "names the judge that could not answer" \
    contains "$out" "no selection from the night judge (gpt-5.6-sol)"
check "and that no cheaper model may pick the night's work" \
    contains "$out" "no cheaper model may pick"
check_eq "not one claude call stood in" "$(claude_n)" "0"
check "the codex cooldown is recorded" grep -q "^blocked-until" "$T/cx-state-nw2"
check_eq "and nothing reached the door" \
    "$(sandbox_count_in '^job ' "$T/crab-calls")" "0"
cp "$REPO/tests/lib/stubs/codex" "$SANDBOX_BIN/codex"; chmod +x "$SANDBOX_BIN/codex"

echo
echo "the routine's shape is unmoved under the model change: the default"
echo "cutoff still prints as 06:00, and the default cap still counts two:"
reset
out="$(night_work DESKCRAB_CODEX_STATE="$T/cx-state-nw3" NIGHT_WORK_WINDOW_MAX=0)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "the daylight guard names the default 06:00 cutoff (rule 56)" \
    contains "$out" "next cutoff (06:00)"
check_eq "and spends nothing" "$(codex_n)$(claude_n)" "00"
for i in 1 2; do
    printf '{"id": "busy-%s", "state": "running"}\n' "$i" > "$T/jobs/busy-$i.json"
done
out="$(night_work DESKCRAB_CODEX_STATE="$T/cx-state-nw4" \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1)"; rc=$?
check_eq "exits clean" "$rc" "0"
check "two running builders fill the default slate (rule 57)" \
    contains "$out" "cap full (2 running, cap 2)"
check_eq "and no judgment is spent against a full slate" "$(codex_n)" "0"
rm -f "$T"/jobs/busy-*.json

# ---------------------------------------------------------------------------
echo
echo "the promise sweep, at the shipped defaults: the reconciliation judgment"
echo "is the night judge's, never the live checker's sonnet/haiku pair:"
reset
DAY="$(date -d yesterday +%F 2>/dev/null || date +%F)"
mkdir -p "$DAY_JOURNAL_DIR"
cat > "$DAY_JOURNAL_DIR/$DAY.jsonl" <<EOF
{"epoch": 1786360800, "time": "${DAY}T12:00:00-0400", "kind": "desktop", "user": "temp?", "reply": "Nineteen and steady.", "pid": 100}
EOF
sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CODEX_LOG}"
cat > "$T/sweep-stdin"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"CLEAN"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2}}'
STUB
out="$(env DESKCRAB_CODEX_STATE="$T/cx-state-sw" \
    "$REPO/lib/promise-check" sweep "$DAY" 2>&1)"; rc=$?
check_eq "the sweep exits clean" "$rc" "0"
check "and calls the day clean" contains "$out" "clean — every commitment reconciled"
check_eq "one judgment call went to the judge" "$(codex_n)" "1"
check "at the default gpt-5.6-sol" grep -q -- "-m gpt-5.6-sol" "$SANDBOX_CODEX_LOG"
check "at the default high effort" grep -q -- "model_reasoning_effort=high" "$SANDBOX_CODEX_LOG"
check "the day's digest reached the judge" grep -q "Nineteen and steady" "$T/sweep-stdin"
check_eq "and not one claude call swept in its place" "$(claude_n)" "0"
rm -f "$DAY_JOURNAL_DIR/$DAY.jsonl"

# ---------------------------------------------------------------------------
echo
echo "the twin-merge judge, at the shipped defaults, over a scratch HTTP"
echo "embedder — the deduplication judgment is the night judge's:"
reset
cat > "$T/embed-server.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        inputs = body.get("input") or []
        if isinstance(inputs, str):
            inputs = [inputs]
        out = json.dumps({"embeddings": [[1.0, 0.0, 0.0] for _ in inputs]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$T/embed-server.py" "$T/embed-port" &
EMB_PID=$!
sandbox_at_exit "kill $EMB_PID"
for i in $(seq 50); do [ -s "$T/embed-port" ] && break; sleep 0.1; done
[ -s "$T/embed-port" ] || die "the scratch embedder never came up"
EMB_URL="http://127.0.0.1:$(cat "$T/embed-port")/api/embed"
R="$T/merge/records"
mkdir -p "$R"
cat > "$R/first-complaint.md" <<'EOF'
---
id: first-complaint
title: the same complaint, first writing
opened: 2026-08-18 01:00:00
last_touched: 2026-08-18 01:00:00
state: open
summary: written once
---

## 2026-08-18 01:00:00

The greenhouse door alarm fires while the door is shut.
EOF
cat > "$R/second-complaint.md" <<'EOF'
---
id: second-complaint
title: the same complaint, second writing
opened: 2026-08-21 01:00:00
last_touched: 2026-08-21 01:00:00
state: open
summary: written twice
---

## 2026-08-21 01:00:00

Again the shut door's alarm fired with nothing open anywhere.
EOF
sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CODEX_LOG}"
cat > "$T/merge-stdin"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"MERGE CERTAIN — one complaint written twice: the shut door alarms"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2}}'
STUB
out="$(env DESKCRAB_ENG_DIR="$R" MEMORY_EMBED_URL="$EMB_URL" \
    DESKCRAB_CODEX_STATE="$T/cx-state-em" \
    "$REPO/lib/eng-merge" run 2>&1)"; rc=$?
check_eq "the pass exits clean" "$rc" "0"
check_eq "one judgment call went to the judge" "$(codex_n)" "1"
check "at the default gpt-5.6-sol (rule 53c)" grep -q -- "-m gpt-5.6-sol" "$SANDBOX_CODEX_LOG"
check "at the default high effort" grep -q -- "model_reasoning_effort=high" "$SANDBOX_CODEX_LOG"
check "both records reached the judge" grep -q "RECORD 2: second-complaint" "$T/merge-stdin"
check "and the certain twin is proposed" contains "$out" "propose fold 'second-complaint' -> 'first-complaint'"
check_eq "not one claude call judged in its place" "$(claude_n)" "0"

# ---------------------------------------------------------------------------
echo
echo "the ingest's two-stage boundary (rule 14d), end to end through"
echo "crab memory ingest --dry-run at the shipped defaults: the summariser"
echo "reads the raw day, the judge reads ONLY the summaries, and the"
echo "candidates that would land are the JUDGE's answer alone:"
if [ -x "${MEMORY_PYTHON:-}" ]; then
    reset
    JDIR="$T/ingest-journal"
    mkdir -p "$JDIR"
    cat > "$JDIR/2026-08-25.jsonl" <<'EOF'
{"time": "2026-08-25T12:00:00-0400", "kind": "desktop", "user": "RAW-MARKER always water the ferns at dusk", "reply": "noted"}
EOF
    sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/sum-stdin"
printf '%s\n' '{"type":"result","result":"SUMMARY-MARKER the user set a watering rule at noon. [{\"text\": \"DECOY-RECORD from the summariser\", \"kind\": \"note\"}]"}'
STUB
    sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CODEX_LOG}"
cat > "$T/judge-stdin"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"[{\"text\": \"JUDGED-RECORD the user waters the ferns at dusk\", \"kind\": \"directive\"}]"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2}}'
STUB
    out="$(env DESKCRAB_CODEX_STATE="$T/cx-state-in" \
        "$REPO/crab" memory ingest --dry-run --journal-dir "$JDIR" \
        --transcripts-dir "$T/no-transcripts" 2>&1)"; rc=$?
    check_eq "the dry run exits clean" "$rc" "0"
    check "the header names both stages and both defaults" \
        contains "$out" "sonnet for summaries, gpt-5.6-sol (high) for judgement"
    check "the summariser was asked on the default sonnet" \
        grep -q -- "--model sonnet" "$SANDBOX_CLAUDE_LOG"
    check "and received the raw day" grep -q "RAW-MARKER" "$T/sum-stdin"
    check "the judge ran on the default gpt-5.6-sol" \
        grep -q -- "-m gpt-5.6-sol" "$SANDBOX_CODEX_LOG"
    check "at the default high effort" \
        grep -q -- "model_reasoning_effort=high" "$SANDBOX_CODEX_LOG"
    check "the judge received the summariser's summary" \
        grep -q "SUMMARY-MARKER" "$T/judge-stdin"
    check_eq "and NOT ONE byte of the raw day (rule 14d's boundary)" \
        "$(sandbox_count_in 'RAW-MARKER' "$T/judge-stdin")" "0"
    check "what would land is the judge's candidate" \
        contains "$out" "would add [directive] JUDGED-RECORD"
    check_eq "and the summariser's smuggled candidate never lands" \
        "$(printf '%s\n' "$out" | sandbox_count_in 'would add.*DECOY-RECORD' /dev/stdin)" "0"
else
    echo "  skip: no memory venv python on this box — the ingest boundary"
    echo "        cases need sqlite-vec; the walk, selector, sweep and merge"
    echo "        cases above still ran in full"
fi

# ---------------------------------------------------------------------------
echo
echo "ONE judge is ONE knob (rule 14c-i): the shared pair alone moves a role's"
echo "engine and effort, and the role's own knob still overrides it:"
reset
# Both roads answer the selector, so the only thing under test is which one was
# asked and with what.
sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CODEX_LOG}"
cat > "$T/shared-stdin"
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"TASK: a-latch-that-sticks | - | Fix the sticking latch\nBRIEF:\nIn /tmp/greenhouse, from the thread a-latch-that-sticks: free the latch.\nEND"}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2}}'
STUB
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/shared-stdin"
printf '%s\n' 'TASK: a-latch-that-sticks | - | Fix the sticking latch'
printf '%s\n' 'BRIEF:'
printf '%s\n' 'In /tmp/greenhouse, from the thread a-latch-that-sticks: free the latch.'
printf '%s\n' 'END'
STUB

# The shared knob alone, named for the other engine: the role follows it.
night_work DESKCRAB_CODEX_STATE="$T/cx-state-sh1" \
    NIGHT_JUDGE_MODEL=stub-claude \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1 >/dev/null 2>&1
check "the selector followed the shared knob" \
    grep -q -- "--model stub-claude" "$SANDBOX_CLAUDE_LOG"
check_eq "and the engine it names is the only one consulted" "$(codex_n)" "0"

# The role's own knob still wins over the shared one.
reset
night_work DESKCRAB_CODEX_STATE="$T/cx-state-sh2" \
    NIGHT_JUDGE_MODEL=stub-claude NIGHT_WORK_MODEL=stub-claude-role \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1 >/dev/null 2>&1
check "the role's own knob overrides the shared one" \
    grep -q -- "--model stub-claude-role" "$SANDBOX_CLAUDE_LOG"
check_eq "the shared model was not used beside it" \
    "$(sandbox_count_in -- "--model stub-claude " "$SANDBOX_CLAUDE_LOG")" "0"

# The effort half of the pair rides the same way, visible on the codex road.
reset
night_work DESKCRAB_CODEX_STATE="$T/cx-state-sh3" \
    NIGHT_JUDGE_MODEL=gpt-5.6-sol NIGHT_JUDGE_EFFORT=low \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" NIGHT_WORK_ROUNDS_MAX=1 >/dev/null 2>&1
check "the shared effort reached the engine" \
    grep -q -- "model_reasoning_effort=low" "$SANDBOX_CODEX_LOG"
check_eq "and no claude stood beside the codex-named shared judge" "$(claude_n)" "0"
