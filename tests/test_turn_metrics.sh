#!/bin/bash
# Turn metrics (specs/turn-pipeline.md rule 33): the stage stamps exist, land
# in the dated metrics log, cost nothing when disabled, and the streamer's two
# stamps — first tool call, first audio — fire exactly once per turn however
# many tools run or sentences are spoken. This is the wiring proof: a metric
# that is merely written about is indistinguishable from one that works, and
# the whole point of the log is that nobody has to re-instrument to ask where
# the time went.
# Run: bash tests/test_turn_metrics.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
MDIR="$SANDBOX/data/deskcrab/metrics"
TODAY_LOG="$MDIR/$(date +%F).log"

echo "the shell helper:"

sandbox_bash 'turn_metric test-stage "detail here"'
check "a stamp lands in the dated metrics log" test -s "$TODAY_LOG"
LINE="$(grep 'test-stage' "$TODAY_LOG" 2>/dev/null | head -1)"
check "the line carries stage and detail" contains "$LINE" "test-stage	detail here"
check "the line opens with a fractional epoch" \
    grep -qE $'^[0-9]+\\.[0-9]{3}\t' "$TODAY_LOG"

sandbox_bash 'TURN_METRICS=0 turn_metric muted-stage'
check_eq "TURN_METRICS=0 writes nothing" \
    "$(sandbox_count_in 'muted-stage' "$TODAY_LOG")" 0

sandbox_bash 'METRICS_DIR=/nonexistent-root/metrics turn_metric doomed-stage; echo rc=$?' \
    > "$T/doomed.out"
check "an unwritable metrics dir costs only the stamp (rc=0)" \
    contains "$(cat "$T/doomed.out")" "rc=0"

echo "generation stamps through claude_generate:"

sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
printf '{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"stub reply"}]}}\n'
printf '{"type":"result","result":"stub reply"}\n'
EOF
sandbox_bash "DEBUGLOG='$T/gen.log' claude_generate 'hello there' >/dev/null" 2>/dev/null \
    || true
check "prompt-built is stamped with a byte count" \
    grep -qE $'prompt-built\t[0-9]+ bytes' "$TODAY_LOG"
check "gen-start is stamped" grep -q 'gen-start' "$TODAY_LOG"
check "gen-end is stamped with the run status" \
    grep -qE $'gen-end\tstatus [0-9]' "$TODAY_LOG"

echo "the streamer's two stamps:"

sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
EOF
sandbox_stub aplay <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
EOF

SLOG="$T/stream.log"
SMETRICS="$T/streamer-metrics.log"
: > "$SLOG"
DESKCRAB_DEBUGLOG="$SLOG" DESKCRAB_PIPER_VOICE=/dev/null \
    DESKCRAB_SPEECHLOCK="$T/sp.lock" DESKCRAB_SPEECH_LOG="$T/sp.log" \
    DESKCRAB_SPEECH_RECEIPT="$T/sp.receipt" \
    DESKCRAB_METRICS_FILE="$SMETRICS" DESKCRAB_METRICS_PID=4242 \
    DESKCRAB_METRICS_KIND="desktop turn" \
    "$SANDBOX_REPO/lib/tts-streamer" 2>>"$T/sp.log" &
SPID=$!
sleep 0.3
{
    printf '{"type":"system","subtype":"init"}\n'
    printf '{"type":"assistant","message":{"model":"m","content":[{"type":"tool_use","name":"Bash","input":{}}]}}\n'
    printf '{"type":"assistant","message":{"model":"m","content":[{"type":"tool_use","name":"Read","input":{}}]}}\n'
    printf '{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"First sentence. Second sentence."}]}}\n'
    printf '{"type":"result","result":"x"}\n'
} >> "$SLOG"
for i in $(seq 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
kill -9 "$SPID" 2>/dev/null
wait "$SPID" 2>/dev/null

check_eq "first-tool fires once across two tool calls" \
    "$(sandbox_count_in 'first-tool' "$SMETRICS")" 1
check_eq "first-audio fires once across two sentences" \
    "$(sandbox_count_in 'first-audio' "$SMETRICS")" 1
check "the streamer stamps carry the launching turn's pid and kind" \
    grep -qE $'\t4242\tdesktop turn\tfirst-audio' "$SMETRICS"

echo
echo "$SANDBOX_NAME: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
