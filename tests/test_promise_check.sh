#!/bin/bash
# The promise checker — specs/turn-pipeline.md rules 32a-32d, wake-queue.md
# rule 43b, nightly.md rules 51-53. Run: bash tests/test_promise_check.sh
#
# Her replies claim first-person concrete actions and the turn ends with the
# action never taken. The checker holds each claim against the tool calls the
# turn's own stream log records: a cheap pattern pre-check gates the model so
# most turns cost a grep, an unkept commitment lands on the durable ledger
# and books an opus-low wake quoting the promise, and the nightly sweep
# reconciles the whole day. Every case here runs against stubs — no model is
# ever spent, no timer is ever armed.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib"

# The checker, copied (not linked — it resolves SCRIPT_DIR through its own
# path and would walk back to the real repo and its real crab), beside a door
# onto the real wake module. Same fixture as test_promise_deferred.sh.
cp "$REPO/lib/promise-check" "$T/repo/lib/promise-check"
chmod +x "$T/repo/lib/promise-check"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/wake-queue.sh" "$T/repo/lib/wake-queue.sh"
ln -sf "$REPO/lib/extract-response" "$T/repo/lib/extract-response"

cat > "$T/repo/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
[ "\${1:-}" = "wake-at" ] || exit 0
shift
source "$REPO/lib/common.sh" >/dev/null 2>&1
wake_book "\$@"
CRAB
chmod +x "$T/repo/crab"

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
MEMORY_STORE=0
PROMISE_CHECK=1
CONF

export WAKES_DIR="$W"
export PROMISE_LEDGER="$T/ledger.jsonl"

CHECK_LOG="$DESKCRAB_STATE_PREFIX-promise-check.log"
CHECK_PREFIX="You claimed this and the record shows nothing did it:"
DEF_PREFIX="You promised him and nothing was booked:"

records()  { ls "$W"/*.wake 2>/dev/null | wc -l; }
field()    { awk -F'\t' -v n="$1" 'FNR == 1 { print $n }' "$W"/*.wake 2>/dev/null; }
fire_in()  { awk -F'\t' -v now="$(date +%s)" 'FNR == 1 { print $1 - now }' "$W"/*.wake 2>/dev/null; }
calls()    { cat "$T/wake-calls" 2>/dev/null; }
ledger_n() { sandbox_count_in . "$T/ledger.jsonl"; }
claude_n() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
reset()    { rm -f "$W"/*.wake "$W/ledger.log" "$T/wake-calls" "$T/ledger.jsonl" \
                   "$CHECK_LOG" "$SANDBOX_CLAUDE_LOG" "$T/model-stdin"; }

# A stream log holding one genuine tool call, and one holding none. The
# no-tools log still holds real assistant text — a record that exists and is
# empty of tools IS evidence, not absence.
SNAP_TOOLS="$T/snap-tools.jsonl"
cat > "$SNAP_TOOLS" <<'EOF'
{"type":"assistant","message":{"model":"real","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/home/nobody/.config/greenhouse/fan.conf","content":"on"}}]}}
{"type":"assistant","message":{"model":"real","content":[{"type":"text","text":"I've wired the greenhouse fan into the config now."}]}}
EOF
SNAP_EMPTY="$T/snap-empty.jsonl"
cat > "$SNAP_EMPTY" <<'EOF'
{"type":"assistant","message":{"model":"real","content":[{"type":"text","text":"I'll wire the greenhouse fan into the config now."}]}}
{"type":"result","result":"done"}
EOF
# fire_promise_check consumes (removes) its snapshot through the checker, so
# tests hand it throwaway copies.
snap() { cp "$1" "$T/snap-live.jsonl"; printf '%s' "$T/snap-live.jsonl"; }

echo "the pre-check knows the commitment shape (a pattern, never a model):"
pc() { sandbox_bash "promise_precheck \"\$(cat '$T/pc-in')\" && echo hit || echo miss"; }
try_pc() { printf '%s' "$2" > "$T/pc-in"; check_eq "$1" "$(pc)" "$3"; }
try_pc "the immediate future ('I'll wire it now')" \
    "I'll wire it into the config now." "hit"
try_pc "the present act ('I am restarting it')" \
    "I am restarting the phone server as we speak." "hit"
try_pc "the completed claim ('I've written it to the log')" \
    "I've written it to the log." "hit"
try_pc "the bare past doing verb ('I booked the wake')" \
    "I booked the wake for nine." "hit"
try_pc "'let me' reaching for the work" \
    "Let me fix that for you." "hit"
try_pc "a plain answer has no commitment shape" \
    "The greenhouse sits at nineteen degrees and the fan is off." "miss"
try_pc "talk ABOUT her without first-person commitment" \
    "That config would need a fan entry to work." "miss"

echo
echo "a reply with no commitment never reaches the model (the gate, from the firing site):"
reset
DBG="$T/fake-debug.log"; cp "$SNAP_EMPTY" "$DBG"
sandbox_bash "DEBUGLOG='$DBG'; SESSION_START=123; fire_promise_check desktop \
    'The greenhouse sits at nineteen degrees and the fan is off.'"
check_eq "no model call was made" "$(claude_n)" "0"
check_eq "no detached checker was spawned" \
    "$(sandbox_count_in promise-check "$SANDBOX_SYSTEMD_LOG")" "0"
check "and the run trace says the pre-check declined, so 'never judged' is legible" \
    grep -q "no commitment shape — the model was never called" "$CHECK_LOG"
check_eq "no evidence snapshot was taken" \
    "$(ls "$T"/state/deskcrab-promise-evidence-* 2>/dev/null | wc -l)" "0"

echo
echo "a reply WITH the shape is handed on, evidence snapshotted at fire time:"
reset
sandbox_bash "DEBUGLOG='$DBG'; SESSION_START=123; fire_promise_check desktop \
    \"I'll wire the greenhouse fan into the config now.\""
check_eq "one detached checker unit was asked for" \
    "$(sandbox_count_in promise-check "$SANDBOX_SYSTEMD_LOG")" "1"
check_eq "and the stream log was snapshotted for it" \
    "$(ls "$T"/state/deskcrab-promise-evidence-* 2>/dev/null | wc -l)" "1"
rm -f "$T"/state/deskcrab-promise-evidence-*

echo
echo "an unkept commitment: ledger line, and the opus-low wake with the promise quoted:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"UNKEPT: \"I am wiring the greenhouse fan into the config now\" | no tool call touched any config"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$T/repo/lib/promise-check" turn desktop 1786400000 4242 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "I am wiring the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "the model was consulted (once, sonnet answered)" "$(claude_n)" "1"
check "the model was asked at the configured sonnet default" \
    grep -q -- "--model sonnet" "$SANDBOX_CLAUDE_LOG"
check "the model was handed the tool record as evidence" \
    grep -q "THIS TURN'S OWN TOOL RECORD" "$T/model-stdin"
check "and the other-sessions section, present and empty — a bare window is still strict" \
    grep -q "(no other session ran in the window)" "$T/model-stdin"
check "and the jobs section, present and empty" \
    grep -q "(no job was dispatched or finished in the window)" "$T/model-stdin"
check_eq "one ledger line landed" "$(ledger_n)" "1"
check "quoting the promise exactly" \
    grep -q '"promise": "I am wiring the greenhouse fan into the config now"' "$T/ledger.jsonl"
check "with the journal identity on it" \
    grep -q '"epoch": 1786400000' "$T/ledger.jsonl"
check_eq "one wake record was booked" "$(records)" "1"
check_eq "in the checker's own name" "$(field 5)" "promise-check"
check_eq "as an event wake" "$(field 2)" "event"
check_eq "at effort low on the record itself, so the fired session runs opus low" \
    "$(field 6)" "low"
case "$(field 3)" in
    "$CHECK_PREFIX"*) ok "the reason opens with the unkept-commitment prefix the audit skips" ;;
    *) fail "the reason must open with the class prefix" "$(field 3)" ;;
esac
case "$(field 3)" in
    *'"I am wiring the greenhouse fan into the config now"'*)
        ok "and quotes the promise verbatim" ;;
    *) fail "the wake must carry the promise in her own words" "$(field 3)" ;;
esac
F="$(fire_in)"
check "the alarm fires minutes out, never hours" test "$F" -ge 60 -a "$F" -le 600
case "$(calls)" in
    *"--effort low"*) ok "the booking asked for the low-effort override" ;;
    *) fail "the wake must be booked at effort low" "$(calls)" ;;
esac
case "$(calls)" in
    *"--cap 3 --cap-prefix $CHECK_PREFIX"*)
        ok "under its own scoped cap, so it neither fills nor drains the audit's" ;;
    *) fail "the class carries its own scoped cap" "$(calls)" ;;
esac
check "the snapshot was consumed by the checker" test ! -e "$T/snap-live.jsonl"

echo
echo "a commitment the tool record shows performed books nothing:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"KEPT: wired the greenhouse fan into the config | Write: /home/nobody/.config/greenhouse/fan.conf"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$T/repo/lib/promise-check" turn desktop 1786400001 4243 "$(snap "$SNAP_TOOLS")" \
    "$T/ledger.jsonl" "I've wired the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "the model ran — this case is judged, not skipped" "$(claude_n)" "1"
check "and was shown the Write call that did the work" \
    grep -q "Write: /home/nobody/.config/greenhouse/fan.conf" "$T/model-stdin"
check_eq "no ledger line" "$(ledger_n)" "0"
check_eq "no wake booked" "$(records)" "0"
check "the trace records a kept verdict" grep -q "1 kept, 0 unkept" "$CHECK_LOG"

echo
echo "a job dispatched in the turn's window backs every action-claim — no model, no wake:"
reset
NOW_E="$(date +%s)"
cat > "$JOBS_DIR/20990101-000000-1.json" <<EOF
{"id": "20990101-000000-1", "description": "wire the greenhouse fan into the config", "started_epoch": $(( NOW_E - 60 )), "state": "running", "unit": "x"}
EOF
"$T/repo/lib/promise-check" turn desktop "$NOW_E" 4249 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "I'll wire the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "the trace names the backing job" \
    grep -q "backed: job 20990101-000000-1" "$CHECK_LOG"
rm -f "$JOBS_DIR"/*.json

echo
echo "a chess-move announcement the mover's record shows played books nothing:"
reset
mkdir -p "$DESKCRAB_METRICS_DIR"
MDAY="$DESKCRAB_METRICS_DIR/$(date +%F).log"
printf '%s.000\t4321\tchess\tmove-played\tbrowser-042 ply 31 Rd3 model\n' \
    "$(date +%s)" > "$MDAY"
"$T/repo/lib/promise-check" turn wake "$(date +%s)" 4250 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "Rd3 — I'm answering the rook lift on the d-file." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "the trace credits the mover's record" \
    grep -q "backed: the mover's record shows Rd3 played" "$CHECK_LOG"

echo
echo "but a reply that ALSO promises other work is still judged in full:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"UNKEPT: \"I'"'"'ll restart the phone server now\" | no record touches the server"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$T/repo/lib/promise-check" turn wake "$(date +%s)" 4251 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "Rd3 is my answer. And I'll restart the phone server now." >/dev/null 2>&1
check_eq "the mover's record did not silence the judge — the model ran" "$(claude_n)" "1"
check_eq "and the unfulfilled half was still caught: one ledger line, one wake" \
    "$(ledger_n)$(records)" "11"
rm -f "$MDAY"

echo
echo "another session's record and the jobs ledger reach the judge as labelled evidence:"
reset
OTHER_LOG="$DESKCRAB_STATE_PREFIX-debug-99999.log"
cat > "$OTHER_LOG" <<'EOF'
{"type":"assistant","message":{"model":"real","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/home/nobody/.config/greenhouse/fan.conf","content":"on"}}]}}
EOF
NOW_E="$(date +%s)"
cat > "$JOBS_DIR/20990101-000000-2.json" <<EOF
{"id": "20990101-000000-2", "description": "sort the drip-line valve wiring", "started_epoch": $(( NOW_E - 1200 )), "state": "running", "unit": "x"}
EOF
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"KEPT: wired the greenhouse fan | session 99999 wrote fan.conf"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$T/repo/lib/promise-check" turn desktop "$NOW_E" 4252 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "I've wired the greenhouse fan into the config." >/dev/null 2>&1
check_eq "the model was consulted — a 20-minute-old job is evidence, not a short-circuit" \
    "$(claude_n)" "1"
check "the other session's section reached the judge" \
    grep -q "OTHER SESSIONS IN THE LAST 30 MINUTES" "$T/model-stdin"
check "labelled with its session id" grep -q -- "--- session 99999" "$T/model-stdin"
check "carrying the Write that did the work" \
    grep -q "Write: /home/nobody/.config/greenhouse/fan.conf" "$T/model-stdin"
check "the jobs section reached the judge" \
    grep -q "JOBS DISPATCHED OR FINISHED RECENTLY" "$T/model-stdin"
check "carrying the builder's brief" \
    grep -q "sort the drip-line valve wiring" "$T/model-stdin"
check_eq "and the kept verdict books nothing" "$(ledger_n)$(records)" "00"
check "the trace counts what was gathered" \
    grep -q "evidence: own record, 1 other session(s), 1 job(s)" "$CHECK_LOG"
rm -f "$OTHER_LOG" "$JOBS_DIR"/*.json

echo
echo "gathering that fails falls back to the own-record judgement, and says so:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"UNKEPT: \"I am wiring the greenhouse fan into the config now\" | no tool call touched any config"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
PROMISE_CHECK_EVIDENCE_WINDOW=bogus \
    "$T/repo/lib/promise-check" turn desktop "$(date +%s)" 4253 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "I am wiring the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "the model still ran" "$(claude_n)" "1"
check "on the narrow prompt — the pre-widening header" \
    grep -q "=== THE TURN'S TOOL RECORD ===" "$T/model-stdin"
check_eq "with no widened section offered" \
    "$(sandbox_count_in 'OTHER SESSIONS' "$T/model-stdin")" "0"
check_eq "and the flag still lands: one ledger line, one wake" \
    "$(ledger_n)$(records)" "11"
check "the failure is on the trace, not swallowed" \
    grep -q "evidence gathering failed" "$CHECK_LOG"

echo
echo "the side door holds the same gate — no commitment shape, no model:"
reset
"$T/repo/lib/promise-check" turn desktop 1786400002 4244 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "The greenhouse sits at nineteen degrees." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"

echo
echo "no readable stream log means no verdict — an accusation needs the record:"
reset
"$T/repo/lib/promise-check" turn desktop 1786400003 4245 "" \
    "$T/ledger.jsonl" "I'll wire the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "and the trace says why nothing was judged" \
    grep -q "no readable stream log" "$CHECK_LOG"

echo
echo "a verifier that answers unparseably falls to haiku on the same login:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
case "\$*" in
    *"--model sonnet"*)
        printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Well, considering the evidence at hand, one might say..."}]}}'
        printf '%s\n' '{"type":"result","result":"prose"}' ;;
    *)
        printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"UNKEPT: \"I am wiring the greenhouse fan into the config now\" | nothing in the record"}]}}'
        printf '%s\n' '{"type":"result","result":"ok"}' ;;
esac
STUB
"$T/repo/lib/promise-check" turn desktop 1786400006 4248 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "I am wiring the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "two model calls: sonnet, then the fallback" "$(claude_n)" "2"
check "the second at haiku" grep -q -- "--model haiku" "$SANDBOX_CLAUDE_LOG"
check "the fall is on the trace" grep -q "falling to haiku" "$CHECK_LOG"
check_eq "and haiku's verdict still lands: one ledger line, one wake" \
    "$(ledger_n)$(records)" "11"

echo
echo "one verbatim promise is chased at most twice a day, then the night takes it:"
reset
NOW_ISO="$(date +%Y-%m-%dT%H:%M:%S%z)"
printf '{"time":"%s","kind":"desktop","promise":"I am wiring the greenhouse fan into the config now","wake":"booked 3m out at effort low"}\n' "$NOW_ISO" >> "$T/ledger.jsonl"
printf '{"time":"%s","kind":"desktop","promise":"I am wiring the greenhouse fan into the config now","wake":"booked 3m out at effort low"}\n' "$NOW_ISO" >> "$T/ledger.jsonl"
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"UNKEPT: \"I am wiring the greenhouse fan into the config now\" | still nothing in the record"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$T/repo/lib/promise-check" turn desktop 1786400004 4246 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "I am wiring the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "no third wake was booked" "$(records)" "0"
check_eq "but the ledger still holds the third catch" "$(ledger_n)" "3"
check "marked as handed to the night" \
    grep -q "already chased 2 times today" "$T/ledger.jsonl"

echo
echo "the auditor's deferred wake from the same turn covers the promise — no double alarm:"
reset
NOW="$(date +%s)"
printf '%s\tevent\t%s send the builder for it\t%s\tpromise-audit\n' \
    $(( NOW + 1200 )) "$DEF_PREFIX" $(( NOW - 30 )) > "$W/deskcrab-wake-def.wake"
"$T/repo/lib/promise-check" turn desktop 1786400005 4247 "$(snap "$SNAP_EMPTY")" \
    "$T/ledger.jsonl" "I am wiring the greenhouse fan into the config now." >/dev/null 2>&1
check_eq "the auditor's booking is still the only record" "$(records)" "1"
check_eq "the catch is ledgered all the same" "$(ledger_n)" "1"
check "as covered by the auditor's wake" \
    grep -q "covered by the auditor" "$T/ledger.jsonl"

echo
echo "the wake path treats the checker's prefix as exempt from the AUDIT only:"
check_eq "the unkept-commitment prefix is exempt from re-audit" \
    "$(sandbox_bash "promise_audit_own_reason '$CHECK_PREFIX x' && echo exempt")" "exempt"
check_eq "an ordinary reason is not" \
    "$(sandbox_bash "promise_audit_own_reason 'check the greenhouse' || echo audited")" "audited"

echo
echo "the sweep: an end-of-day miss surfaces, a later-fulfilled promise is dropped,"
echo "and the desk rows' own tool traces (rule 32e) refute or fulfil a completed claim:"
reset
DAY="$(date -d yesterday +%F)"
mkdir -p "$DAY_JOURNAL_DIR"
cat > "$DAY_JOURNAL_DIR/$DAY.jsonl" <<EOF
{"epoch": 1786360800, "time": "${DAY}T12:00:00-0400", "kind": "desktop", "user": "sort the fan out?", "reply": "I'll wire the greenhouse fan into the config now.", "pid": 100, "outcome": "asked: sort the fan out? | did: ran no tools, touched nothing | replied: I'll wire the greenhouse fan into the config now."}
{"epoch": 1786361100, "time": "${DAY}T12:05:00-0400", "kind": "desktop", "user": "and the drip line?", "reply": "I'll write the drip-line notes up this afternoon.", "pid": 101, "outcome": "asked: and the drip line? | did: ran no tools, touched nothing | replied: I'll write the drip-line notes up this afternoon."}
{"epoch": 1786364400, "time": "${DAY}T13:00:00-0400", "kind": "desktop", "user": "flip the pump relay?", "reply": "Done — I've switched the pump relay over.", "pid": 103, "outcome": "asked: flip the pump relay? | did: ran no tools, touched nothing | replied: Done — I've switched the pump relay over."}
{"epoch": 1786368000, "time": "${DAY}T14:00:00-0400", "kind": "desktop", "user": "frost notes?", "reply": "Done — I've written the frost notes to ~/notes/frost.md.", "pid": 104, "outcome": "asked: frost notes? | did: wrote ~/notes/frost.md; ran 1 command | replied: Done — I've written the frost notes."}
{"epoch": 1786371600, "time": "${DAY}T15:00:00-0400", "kind": "wake", "user": "", "reply": "", "pid": 102, "outcome": "(silent — wrote ~/notes/drip-line.md, ran 2 commands)"}
EOF
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"MISS: \"I'"'"'ll wire the greenhouse fan into the config now\" @ 12:00 | no later record wires any config"}]}}'
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"MISS: \"I'"'"'ve switched the pump relay over\" @ 13:00 | its own outcome trace says the turn ran no tools"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$T/repo/lib/promise-check" sweep "$DAY" >/dev/null 2>&1
check_eq "one model call swept the day" "$(claude_n)" "1"
check "the model was handed the noon promise" \
    grep -q "wire the greenhouse fan into the config" "$T/model-stdin"
check "AND the 15:00 work trace that reconciles the drip-line promise" \
    grep -q "wrote ~/notes/drip-line.md" "$T/model-stdin"
check "the refuting desk trace reached the judge (rule 32e)" \
    grep -q "did: ran no tools, touched nothing" "$T/model-stdin"
check "and the fulfilling desk trace beside it" \
    grep -q "did: wrote ~/notes/frost.md" "$T/model-stdin"
check_eq "two sweep records landed on the ledger" \
    "$(sandbox_count_in '"type": "sweep"' "$T/ledger.jsonl")" "2"
check "naming the fan promise" \
    grep -q "wire the greenhouse fan" "$T/ledger.jsonl"
check "and the completed claim whose day carried no matching trace" \
    grep -q "switched the pump relay" "$T/ledger.jsonl"
check_eq "and not the fulfilled drip-line one" \
    "$(sandbox_count_in "drip-line" "$T/ledger.jsonl")" "0"
check_eq "nor the frost claim its own trace shows done" \
    "$(sandbox_count_in "frost" "$T/ledger.jsonl")" "0"
check_eq "one morning wake was booked" "$(records)" "1"
check_eq "by the checker's own hand" "$(field 5)" "promise-check"
case "$(field 3)" in
    "$CHECK_PREFIX"*"wire the greenhouse fan"*"switched the pump relay"*)
        ok "carrying the prefix and both missed promises" ;;
    *) fail "the morning wake must quote the misses" "$(field 3)" ;;
esac

echo
echo "a clean day books nothing — the sweep is a debt collector, not an exercise:"
reset
cat > "$DAY_JOURNAL_DIR/$DAY.jsonl" <<EOF
{"epoch": 1786360800, "time": "${DAY}T12:00:00-0400", "kind": "desktop", "user": "temp?", "reply": "Nineteen degrees and steady.", "pid": 100}
EOF
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"CLEAN"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$T/repo/lib/promise-check" sweep "$DAY" >/dev/null 2>&1
check_eq "no wake, no ledger line" "$(records)$(ledger_n)" "00"
check "and the trace calls the day clean" grep -q "clean — every commitment reconciled" "$CHECK_LOG"

echo
echo "a day with no journal is a quiet no-op:"
reset
rm -f "$DAY_JOURNAL_DIR/$DAY.jsonl"
"$T/repo/lib/promise-check" sweep "$DAY" >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check "and the trace says there was nothing to sweep" \
    grep -q "no journal — nothing to sweep" "$CHECK_LOG"

echo
echo "the desk and phone paths journal the trace the sweep just judged (rule 32e),"
echo "proven from real turns through the production pipeline:"
reset
cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
WAKE_QUIET_HOURS=""
CONF
JOURNAL_TODAY="$DAY_JOURNAL_DIR/$(date +%F).jsonl"
: > "$JOURNAL_TODAY"
# A claude whose stream holds one genuine tool call: the trace must name it.
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/home/nobody/notes/frost.md","content":"x"}}]}}'
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Done - the frost notes are written."}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$REPO/crab" "write the frost notes" >/dev/null 2>&1
check "a desk turn's outcome names what its hands did" \
    grep -qE '"kind": "desktop".*did: wrote /home/nobody/notes/frost\.md' "$JOURNAL_TODAY"
"$REPO/crab" remote "and the phone half" >/dev/null 2>&1
check "and a phone turn's outcome carries the same trace" \
    grep -qE '"kind": "phone".*did: wrote /home/nobody/notes/frost\.md' "$JOURNAL_TODAY"
# And a turn that ran no tools says so — a record, not an absence (rule 32d's
# zero-calls principle carried onto the journal row).
sandbox_stub claude <<'STUB'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Nineteen degrees and steady."}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
"$REPO/crab" "just the temperature" >/dev/null 2>&1
check "a turn that ran no tools says so on its row" \
    grep -qE '"user": "just the temperature".*did: ran no tools, touched nothing' "$JOURNAL_TODAY"
