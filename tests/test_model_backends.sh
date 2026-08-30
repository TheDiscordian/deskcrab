#!/bin/bash
# The model backends — specs/model-backends.md. The engine follows the model
# name: Claude names take the walk they always took, codex names run the one
# ChatGPT login through the stream translator, and a codex limit falls back
# instead of walking accounts codex does not have.
# Run: bash tests/test_model_backends.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
CODEX_LOG="$SANDBOX/witness-codex.log"
CODEX_STATE="$SANDBOX/codex-state"
mkdir -p "$SANDBOX/codexhome"

# The spend gate, both engines: the Claude CLI is the sandbox's stub already,
# and codex gets one of its own before anything below may run.
[ -x "$SANDBOX_BIN/claude" ] || die "the stub claude is missing — nothing below may run"
cat > "$SANDBOX/codex-app-responder.py" <<'PYR'
import json, os, sys
def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    meth = m.get("method")
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
    elif meth == "thread/start":
        send({"jsonrpc": "2.0", "id": m["id"],
              "result": {"thread": {"id": "th-1"}}})
    elif meth == "turn/start":
        send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
        notify("turn/started", {"threadId": "th-1", "turnId": "tu-1"})
        if os.environ.get("CODEX_STUB_LIMIT"):
            notify("error", {"error": {"message":
                "You have hit your usage limit. Try again later."},
                "willRetry": False, "threadId": "th-1", "turnId": "tu-1"})
            notify("turn/completed", {"threadId": "th-1",
                "turn": {"id": "tu-1", "status": "failed",
                         "error": {"message":
                "You have hit your usage limit. Try again later."}}})
            sys.exit(0)
        capacity_once = os.environ.get("CODEX_STUB_CAPACITY_ONCE")
        if os.environ.get("CODEX_STUB_CAPACITY") and \
                (not capacity_once or not os.path.exists(capacity_once)):
            if capacity_once:
                open(capacity_once, "w").close()
            notify("item/completed", {"threadId": "th-1", "turnId": "tu-1",
                "item": {"type": "commandExecution", "id": "cmd_0",
                         "command": "printf tool-work", "status": "completed"}})
            notify("error", {"error": {
                "message": "Selected model is at capacity. Please try a different model.",
                "codexErrorInfo": "serverOverloaded", "additionalDetails": None},
                "willRetry": False, "threadId": "th-1", "turnId": "tu-1"})
            notify("turn/completed", {"threadId": "th-1",
                "turn": {"id": "tu-1", "status": "failed",
                         "error": {"message":
                "Selected model is at capacity. Please try a different model."}}})
            sys.exit(0)
        for d in ("codex ", "stub ", "reply."):
            notify("item/agentMessage/delta",
                   {"threadId": "th-1", "turnId": "tu-1",
                    "itemId": "item_0", "delta": d})
        notify("item/completed", {"threadId": "th-1", "turnId": "tu-1",
            "completedAtMs": 0,
            "item": {"type": "agentMessage", "id": "item_0",
                     "text": "codex stub reply."}})
        notify("thread/tokenUsage/updated", {"threadId": "th-1",
            "turnId": "tu-1", "tokenUsage": {"last": {
                "totalTokens": 107, "inputTokens": 100,
                "cachedInputTokens": 60, "cacheWriteInputTokens": 5,
                "outputTokens": 7, "reasoningOutputTokens": 0}}})
        notify("turn/completed", {"threadId": "th-1",
            "turn": {"id": "tu-1", "status": "completed", "error": None}})
        sys.exit(0)
PYR

sandbox_stub codex <<STUB
#!/bin/bash
# Two roads, like the real binary (specs/model-backends.md rules 11, 11a):
# \`app-server\` speaks just enough JSON-RPC for the driver; \`exec\` answers
# in the event shapes the exec translator parses. The INVOKED witness line
# is road-neutral — model and effort ride the argv on one road and the
# environment on the other, so assertions count and grep this line.
printf 'INVOKED %s model=%s effort=%s instr=%s\n' "\$1" \
    "\${CODEX_APP_MODEL:-argv}" "\${CODEX_APP_EFFORT:-argv}" \
    "\${CODEX_APP_INSTRUCTIONS:-}" >> "$CODEX_LOG"
printf '%s\n' "\$*" >> "$CODEX_LOG"
if [ "\$1" = "app-server" ]; then
    [ -n "\${CODEX_STUB_APP_FAIL:-}" ] && exit 2
    exec python3 "$SANDBOX/codex-app-responder.py"
fi
cat > /dev/null
if [ -n "\${CODEX_STUB_LIMIT:-}" ]; then
    printf '%s\n' '{"type":"error","message":"You have hit your usage limit. Try again later."}'
    exit 1
fi
printf '%s\n' '{"type":"thread.started","thread_id":"t-1"}'
printf '%s\n' '{"type":"turn.started"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"codex stub reply."}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":5,"output_tokens":7}}'
exit 0
STUB

cat > "$DESKCRAB_CONF" <<EOF
PROJECT_DIR="$SANDBOX/home"
PIPER_VOICE="$SANDBOX/voice.onnx"
WHISPER_MODEL="$SANDBOX/whisper.bin"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
CODEX_BIN="$SANDBOX_BIN/codex"
CLAUDE_MODEL="opus"
CLAUDE_EFFORT="low"
EOF

# Every sourced instance below needs a scratch codex cooldown file, because a
# stub's refusal must never bench the LIVE
# codex login for every real session (the same trap test_job_block.sh names
# for the jobs blocked-marker).
sb() {
    DESKCRAB_CODEX_STATE="$CODEX_STATE" sandbox_bash "$@"
}

echo "the router — the engine follows the model name (rules 1-2, 4):"
check_eq "opus is claude" "$(sb 'model_backend opus')" "claude"
check_eq "fable is claude" "$(sb 'model_backend fable')" "claude"
check_eq "claude-fable-5 is claude" "$(sb 'model_backend claude-fable-5')" "claude"
check_eq "an unknown name is claude — the pre-existing default" \
    "$(sb 'model_backend some-future-name')" "claude"
check_eq "gpt-5.6-sol is codex" "$(sb 'model_backend gpt-5.6-sol')" "codex"
check_eq "sol alone is codex" "$(sb 'model_backend sol')" "codex"
check_eq "o3 is codex" "$(sb 'model_backend o3')" "codex"
check_eq "the codex: prefix is codex" "$(sb 'model_backend codex:anything')" "codex"
check_eq "sol resolves to the default slug" \
    "$(sb 'codex_model_resolve sol')" "gpt-5.6-sol"
check_eq "CODEX_MODEL_SOL re-aims the alias" \
    "$(sb 'CODEX_MODEL_SOL=gpt-9-sol codex_model_resolve sol')" "gpt-9-sol"
check_eq "the codex: prefix is stripped" \
    "$(sb 'codex_model_resolve codex:gpt-x')" "gpt-x"
check_eq "ultra clamps to max for the Claude CLI" \
    "$(sb 'claude_effort_clamp ultra')" "max"
check_eq "every other effort passes through" \
    "$(sb 'claude_effort_clamp xhigh')" "xhigh"
check_eq "the fallback model defaults to the loop's own" \
    "$(sb 'codex_fallback_model')" "opus"
check_eq "a conf fallback is honoured" \
    "$(sb 'CODEX_FALLBACK_MODEL=sonnet codex_fallback_model')" "sonnet"
check_eq "a fallback pointing back at codex is refused — no tail-chasing" \
    "$(sb 'CODEX_FALLBACK_MODEL=sol codex_fallback_model')" "opus"

echo
echo "the translator — codex events in the established vocabulary (rule 11):"
TR="$SANDBOX/translated.out"
CODEX_STREAM_HEARTBEAT=0 CODEX_STREAM_MODEL="gpt-test" \
    "$REPO/lib/codex-stream" > "$TR" <<'EOF'
{"type":"thread.started","thread_id":"t-9"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":""}}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"echo hi","status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"echo hi","exit_code":0}}
{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"/tmp/a.txt","kind":"add"}]}}
{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"the answer."}}
not json at all
{"type":"some.future.event","x":1}
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":5,"output_tokens":7}}
EOF
check "the first line is the ledger's init marker" \
    contains "$(head -n1 "$TR")" '"type": "system"'
check "…with the codex engine named" contains "$(head -n1 "$TR")" '"engine": "codex"'
check "an agent message becomes an assistant text event" \
    contains "$(cat "$TR")" '"text": "the answer."'
check_eq "an EMPTY agent message is never emitted" \
    "$(grep -c '"item_0"' "$TR")" "0"
check "a command becomes a Bash tool_use" contains "$(cat "$TR")" '"name": "Bash"'
check "…carrying the command itself" contains "$(cat "$TR")" '"command": "echo hi"'
check "a file change becomes a Write tool_use" \
    contains "$(cat "$TR")" '"file_path": "/tmp/a.txt"'
check_eq "one Bash tool_use, not one per item state" \
    "$(grep -c '"name": "Bash"' "$TR")" "1"
check "a non-JSON line passes through verbatim" \
    contains "$(cat "$TR")" 'not json at all'
check "an unknown event passes through verbatim" \
    contains "$(cat "$TR")" '"some.future.event"'
RESULT_LINE="$(grep '"type": "result"' "$TR" | tail -n1)"
check "the turn end is a result event" contains "$RESULT_LINE" '"result": "the answer."'
check "cached input maps to cache_read" \
    contains "$RESULT_LINE" '"cache_read_input_tokens": 60'
check "cache writes map to cache_creation" \
    contains "$RESULT_LINE" '"cache_creation_input_tokens": 5'
check "input is net of cache" contains "$RESULT_LINE" '"input_tokens": 40'
check "output rides through" contains "$RESULT_LINE" '"output_tokens": 7'

# A failed turn: the raw codex line survives AND a shaped error result lands.
TRF="$SANDBOX/translated-fail.out"
CODEX_STREAM_HEARTBEAT=0 "$REPO/lib/codex-stream" > "$TRF" <<'EOF'
{"type":"error","message":"You have hit your usage limit. Try again later."}
EOF
check "codex's own error line passes through" \
    contains "$(cat "$TRF")" '"type":"error"'
check "…and a shaped is_error result follows for the extractor" \
    contains "$(cat "$TRF")" '"is_error": true'

echo
echo "the refusal detector — codex-owned words, no genuine output (rule 12):"
R1="$SANDBOX/slice-limit.log"
printf '%s\n' '{"type":"error","message":"You have hit your usage limit."}' > "$R1"
OUT="$(sb "codex_stream_refusal '$R1'")" \
    && ok "a limit error with no output is a refusal" \
    || fail "the limit slice must read as a refusal" "$(cat "$R1")"
check "…and the printed line is codex's own" contains "$OUT" "usage limit"
R2="$SANDBOX/slice-real.log"
{ printf '%s\n' '{"type":"assistant","message":{"id":"a","model":"gpt-test","content":[{"type":"text","text":"real work"}]}}'
  printf '%s\n' '{"type":"error","message":"You have hit your usage limit."}'; } > "$R2"
sb "codex_stream_refusal '$R2'" >/dev/null \
    && fail "genuine output must veto the refusal reading" "$(cat "$R2")" \
    || ok "a run that produced output HAPPENED — no refusal"
R3="$SANDBOX/slice-plain.log"
printf '%s\n' '{"type":"error","message":"connection reset by peer"}' > "$R3"
sb "codex_stream_refusal '$R3'" >/dev/null \
    && fail "an ordinary failure is not a limit" "$(cat "$R3")" \
    || ok "a network death never reads as a refusal"
R4="$SANDBOX/slice-offset.log"
printf '%s\n' '{"type":"error","message":"You have hit your usage limit."}' > "$R4"
OFF="$(wc -c < "$R4")"
printf '%s\n' '{"type":"assistant","message":{"id":"b","model":"gpt-test","content":[{"type":"text","text":"fine now"}]}}' >> "$R4"
sb "codex_stream_refusal '$R4' '$OFF'" >/dev/null \
    && fail "an earlier attempt's refusal leaked past the offset" "$OFF" \
    || ok "the offset confines the judgement to this attempt's slice"

echo
echo "the transient capacity detector — provider overload is not credits (rule 12a):"
R5="$SANDBOX/slice-capacity.log"
cat > "$R5" <<'EOF'
{"type":"assistant","message":{"id":"cmd","model":"gpt-test","content":[{"type":"tool_use","name":"Bash","input":{"command":"printf tool-work"}}]}}
{"method":"error","params":{"error":{"message":"Selected model is at capacity. Please try a different model.","codexErrorInfo":"serverOverloaded","additionalDetails":null},"willRetry":false}}
{"type":"result","engine":"codex","model":"gpt-test","result":"Selected model is at capacity. Please try a different model.","is_error":true}
EOF
OUT="$(sb "codex_stream_capacity '$R5'")" \
    && ok "serverOverloaded after tool work is retryable" \
    || fail "the captured capacity event must be retryable" "$(cat "$R5")"
check "the detector returns the provider message" contains "$OUT" "Selected model is at capacity"
R5_META="$SANDBOX/slice-capacity-metadata.log"
printf '%s\n' '{"method":"error","params":{"error":{"message":"Please retry this request.","codexErrorInfo":"serverOverloaded"}}}' > "$R5_META"
sb "codex_stream_capacity '$R5_META'" >/dev/null \
    && ok "structured serverOverloaded metadata is authoritative" \
    || fail "the structured code must not depend on one message spelling" "$(cat "$R5_META")"
sb "DEBUGLOG='$R5'; wake_stream_failed" \
    && ok "tool work cannot make an unanswered capacity error deliverable" \
    || fail "the wake guard must suppress a provider error after tool work" "$(cat "$R5")"
R6="$SANDBOX/slice-capacity-after-text.log"
{ printf '%s\n' '{"type":"assistant","message":{"id":"answer","model":"gpt-test","content":[{"type":"text","text":"A reply already began."}]}}'
  tail -n2 "$R5"; } > "$R6"
sb "codex_stream_capacity '$R6'" >/dev/null \
    && fail "capacity after reply text must not run a second model" "$(cat "$R6")" \
    || ok "genuine reply text prevents a duplicate answer"
R7="$SANDBOX/slice-network-after-tool.log"
cat > "$R7" <<'EOF'
{"type":"assistant","message":{"id":"cmd","model":"gpt-test","content":[{"type":"tool_use","name":"Bash","input":{"command":"printf tool-work"}}]}}
{"type":"result","engine":"codex","model":"gpt-test","result":"connection reset by peer","is_error":true}
EOF
sb "codex_stream_capacity '$R7'" >/dev/null \
    && fail "an ordinary failure must not masquerade as server capacity" "$(cat "$R7")" \
    || ok "ordinary failures remain distinct from server capacity"

echo
echo "the cooldown — recorded, visible, honoured (rule 13):"
rm -f "$CODEX_STATE"
check "with no cooldown codex is available" \
    sb "CODEX_BIN='$SANDBOX_BIN/codex' codex_available"
sb "codex_limit_record 'You have hit your usage limit.'"
[ -s "$CODEX_STATE" ] && ok "the refusal wrote the cooldown record" \
    || fail "codex_limit_record must write the state file" "$CODEX_STATE"
sb "CODEX_BIN='$SANDBOX_BIN/codex' codex_available" \
    && fail "a standing cooldown must bench codex" "$(cat "$CODEX_STATE")" \
    || ok "while the cooldown stands codex is unavailable"
check "the account line names the benched engine" \
    contains "$(sb 'account_state_line')" "Codex: over its limit"
rm -f "$CODEX_STATE"
check "lifting the cooldown restores the engine" \
    sb "CODEX_BIN='$SANDBOX_BIN/codex' codex_available"
check_eq "with no cooldown the account line stays as it was" \
    "$(sb 'account_state_line' | grep -c 'Codex:')" "0"

echo
echo "the wake chain — codex first, the Claude walk on a refusal (rule 12):"
wake_chain() { # <extra env assignments...>
    sb "DEBUGLOG='$SANDBOX/wake-debug.log'
        SYSTEM_PROMPT='sys' PROMPT_TEXT='the agenda'
        WAKE_MODEL='gpt-5.6-sol' WAKE_EFFORT='${WAKE_EFFORT_CASE:-low}'
        $* wake_claude_run_chain; echo \"attempts=\$WAKE_CHAIN_ATTEMPTS\""
}
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"
: > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain 'CODEX_STUB_LIMIT=1' 2>/dev/null)"
check_eq "the codex stub was tried exactly once" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "1"
check "…with the model slug" contains "$(cat "$CODEX_LOG")" "gpt-5.6-sol"
check "the refusal is announced in the stream" \
    contains "$(cat "$SANDBOX/wake-debug.log")" "codex-limit"
check_eq "the Claude walk then took the wake at the fallback model" \
    "$(sandbox_count_in '--model opus' "$SANDBOX_CLAUDE_LOG")" "1"
[ -s "$CODEX_STATE" ] && ok "the refusal recorded the codex cooldown" \
    || fail "a wake refusal must cool the engine" "no state file"
rm -f "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"; : > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain 2>/dev/null)"
check_eq "while cooling, the doomed codex boot is never paid" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "0"
check "…and the stream says why" \
    contains "$(cat "$SANDBOX/wake-debug.log")" "codex-cooling"
check_eq "the Claude walk still answers the wake" \
    "$(sandbox_count_in '--model opus' "$SANDBOX_CLAUDE_LOG")" "1"
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"; : > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain 2>/dev/null)"
check_eq "an answering codex ends the chain — one attempt" "${OUT##*attempts=}" "1"
check_eq "…and no Claude account is walked" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"
check "the translated answer is in the stream" \
    contains "$(cat "$SANDBOX/wake-debug.log")" "codex stub reply."
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"; : > "$SANDBOX/wake-debug.log"
OUT="$(WAKE_EFFORT_CASE=ultra wake_chain 'CODEX_STUB_LIMIT=1' 2>/dev/null)"
check "codex was asked for ultra" contains "$(cat "$CODEX_LOG")" "effort=ultra"
check_eq "the fallback walk clamps ultra to max — the Claude CLI refuses the word" \
    "$(sandbox_count_in '--effort max' "$SANDBOX_CLAUDE_LOG")" "1"

CAPACITY_ONCE="$SANDBOX/capacity-once"
rm -f "$CODEX_STATE" "$CODEX_LOG" "$CAPACITY_ONCE"; : > "$SANDBOX_CLAUDE_LOG"; : > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain "CODEX_STUB_CAPACITY=1 CODEX_STUB_CAPACITY_ONCE='$CAPACITY_ONCE' CODEX_CAPACITY_RETRY_DELAY=0" 2>/dev/null)"
check_eq "a server-capacity wake retries Sol once" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "2"
check_eq "…and both attempts use the same Sol model" \
    "$(sandbox_count_in 'model=gpt-5.6-sol' "$CODEX_LOG")" "2"
check_eq "…without entering the Claude account walk" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"
check "the same-model retry is named as capacity, never credits" \
    contains "$(cat "$SANDBOX/wake-debug.log")" "codex-capacity-retry"
[ ! -e "$CODEX_STATE" ] && ok "transient capacity writes no Codex limit cooldown" \
    || fail "server capacity must not bench the next independent Sol run" "$(cat "$CODEX_STATE" 2>/dev/null)"
OUT="$(DESKCRAB_DEBUGLOG="$SANDBOX/wake-debug.log" "$REPO/lib/extract-response")"
check_eq "only Sol's successful retry extracts from the combined stream" "$OUT" "codex stub reply."

rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"; : > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain 'CODEX_STUB_CAPACITY=1 CODEX_CAPACITY_RETRIES=1 CODEX_CAPACITY_RETRY_DELAY=0' 2>/dev/null)"
check_eq "persistent capacity stops after the configured Sol attempts" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "2"
check_eq "persistent capacity still never enters the Claude walk" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"
OUT="$(DESKCRAB_DEBUGLOG="$SANDBOX/wake-debug.log" "$REPO/lib/extract-response")"
check_eq "exhausted capacity exposes no provider error as a reply" "$OUT" ""
sb "DEBUGLOG='$SANDBOX/wake-debug.log'; wake_stream_failed" \
    && ok "exhausted capacity remains a failed wake for ordinary re-booking" \
    || fail "the exhausted wake must not become a successful silent reply" "$(cat "$SANDBOX/wake-debug.log")"

echo
echo "the interactive turn — same seam, extract_response still answers (rule 12):"
turn() { # <extra env...>
    sb "DEBUGLOG='$SANDBOX/turn-debug.log' TURN_INTERRUPT=0
        $* claude_generate 'hello there' low"
}
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"
OUT="$(turn "CLAUDE_MODEL=sol" 2>/dev/null)"
check "a codex turn's reply comes back through extract_response" \
    contains "$OUT" "codex stub reply."
check_eq "…with no Claude account walked" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"
OUT="$(turn "CLAUDE_MODEL=sol CODEX_STUB_LIMIT=1" 2>/dev/null)"
check "a codex limit turn still answers — on the Claude walk" \
    contains "$OUT" "stub reply."
check_eq "…which ran at the fallback model" \
    "$(sandbox_count_in '--model opus' "$SANDBOX_CLAUDE_LOG")" "1"
check "the swap is on the record" \
    contains "$(cat "$SANDBOX/turn-debug.log")" "codex-limit"
rm -f "$CODEX_STATE" "$CODEX_LOG" "$CAPACITY_ONCE"; : > "$SANDBOX_CLAUDE_LOG"
OUT="$(turn "CLAUDE_MODEL=sol CODEX_STUB_CAPACITY=1 CODEX_STUB_CAPACITY_ONCE='$CAPACITY_ONCE' CODEX_CAPACITY_RETRY_DELAY=0" 2>/dev/null)"
check "a server-capacity turn still answers on the Sol retry" \
    contains "$OUT" "stub reply."
check_eq "…with exactly two Sol attempts" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "2"
check_eq "…and no Claude fallback attempt" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"
check "the capacity event is recorded without calling it a limit" \
    contains "$(cat "$SANDBOX/turn-debug.log")" "codex-capacity-retry"
[ ! -e "$CODEX_STATE" ] && ok "the turn also leaves Sol available next time" \
    || fail "the turn wrote a false limit cooldown" "$(cat "$CODEX_STATE" 2>/dev/null)"

rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"
OUT="$(turn "CLAUDE_MODEL=sol CODEX_STUB_CAPACITY=1 CODEX_CAPACITY_RETRIES=1 CODEX_CAPACITY_RETRY_DELAY=0" 2>/dev/null)"
check_eq "an exhausted capacity turn exposes no provider error as a reply" "$OUT" ""
check_eq "…after exactly the configured Sol attempts" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "2"
check_eq "…and still no Claude fallback attempt" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"

echo
echo "the instructions file — the assembled prompt reaches codex WHOLE (rule 7):"
rm -f "$CODEX_STATE" "$CODEX_LOG"
sb "DEBUGLOG='$SANDBOX/instr-debug.log' CODEX_STREAM_MODE=exec SYSTEM_PROMPT=\"\$(printf 'line one\nline two of the prompt')\" \
    _codex_stream_run wake sol low 'the text'" 2>/dev/null
check "the run names an instructions file" \
    contains "$(cat "$CODEX_LOG")" "model_instructions_file="
# The run function removes the per-run file afterwards; the stub logged its
# path, so the writing is proven by the argv and the cleanup by its absence.
INSTR_PATH="$(grep -o 'model_instructions_file=[^ ]*' "$CODEX_LOG" | head -n1 | cut -d= -f2)"
[ -n "$INSTR_PATH" ] && [ ! -e "$INSTR_PATH" ] \
    && ok "the per-run instructions file is cleaned up" \
    || fail "the instructions file should be gone after the run" "$INSTR_PATH"
check "preface mode carries the prompt in the text instead" \
    contains "$(sb "DEBUGLOG='$SANDBOX/instr2.log' CODEX_STREAM_MODE=exec CODEX_PROMPT_MODE=preface SYSTEM_PROMPT='the standing prompt' \
        _codex_stream_run wake sol low 'the text' 2>/dev/null; grep -o 'the standing prompt' '$CODEX_LOG' | head -n1")" \
    "the standing prompt"

echo
echo "the streaming road — deltas first, exec only as the fallback (rule 11a):"
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"
: > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain 2>/dev/null)"
check "the partial-message vocabulary is in the stream" \
    contains "$(cat "$SANDBOX/wake-debug.log")" '"content_block_delta"'
check "…opened by a message_start" \
    contains "$(cat "$SANDBOX/wake-debug.log")" '"message_start"'
check_eq "three deltas — one per stub chunk" \
    "$(sandbox_count_in 'text_delta' "$SANDBOX/wake-debug.log")" "3"
check "the completed assistant event stands behind them" \
    contains "$(cat "$SANDBOX/wake-debug.log")" '"codex stub reply."'
check "the result carries the mapped usage" \
    contains "$(grep '"type": "result"' "$SANDBOX/wake-debug.log" | tail -n1)" '"cache_read_input_tokens": 60'
check "…and names the transport" \
    contains "$(cat "$SANDBOX/wake-debug.log")" '"transport": "app-server"'
check "the driver passed the instructions file through" \
    contains "$(cat "$CODEX_LOG")" "instr=/"
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX_CLAUDE_LOG"
: > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain 'CODEX_STUB_APP_FAIL=1' 2>/dev/null)"
check "a dead app-server falls through with the note on the record" \
    contains "$(cat "$SANDBOX/wake-debug.log")" "codex-app-unavailable"
check "…and the exec pipeline still answers" \
    contains "$(cat "$SANDBOX/wake-debug.log")" "codex stub reply."
check_eq "…with no Claude account walked" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"
rm -f "$CODEX_STATE" "$CODEX_LOG"; : > "$SANDBOX/wake-debug.log"
OUT="$(wake_chain 'CODEX_STREAM_MODE=exec' 2>/dev/null)"
check_eq "CODEX_STREAM_MODE=exec pins the old road — no app-server boot" \
    "$(sandbox_count_in 'INVOKED app-server' "$CODEX_LOG")" "0"
check "…which still answers" \
    contains "$(cat "$SANDBOX/wake-debug.log")" "codex stub reply."

echo
echo "the classifier routes by the same rule (rule 16):"
rm -f "$CODEX_STATE"
OUT="$(printf 'the question' | sb "CODEX_BIN='$SANDBOX_BIN/codex' claude_classify sol 'sys'" 2>/dev/null)"
check_eq "a codex classify answers with the bare text" "$OUT" "codex stub reply."
rm -f "$CODEX_STATE"
printf 'the question' | sb "CODEX_BIN='$SANDBOX_BIN/codex' CODEX_STUB_LIMIT=1 \
    claude_classify sol 'sys'" >/dev/null 2>&1 || true
check "a classifier capacity refusal cools the one codex login" \
    test -s "$CODEX_STATE"

echo
echo "a builder on codex is BLOCKED when refused, never downgraded (rule 14):"
T="$SANDBOX/jobtest"
mkdir -p "$T/repo/lib" "$T/jobs" "$T/wd"
cp "$REPO/lib/job-runner" "$T/repo/lib/job-runner"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/job-status" "$T/repo/lib/job-status"
ln -sf "$REPO/lib/job-log-stream" "$T/repo/lib/job-log-stream"
ln -sf "$REPO/lib/job-collect" "$T/repo/lib/job-collect"
ln -sf "$REPO/lib/codex-stream" "$T/repo/lib/codex-stream"
ln -sf "$REPO/lib/eng" "$T/repo/lib/eng"
printf '#!/bin/bash\nexit 0\n' > "$T/repo/crab"; chmod +x "$T/repo/crab"
chmod +x "$T/repo/lib/job-runner"
"$REPO/lib/job-status" new "$T/jobs" cjob "try a codex build" "" "$T/wd" >/dev/null 2>&1 || \
    python3 - "$T/jobs/cjob.json" <<'PY'
import json, sys, time
json.dump({"id": "cjob", "description": "try a codex build",
           "started_epoch": int(time.time()), "state": "running", "unit": "",
           "workdir": ""}, open(sys.argv[1], "w"))
PY
rm -f "$CODEX_STATE"; : > "$SANDBOX_CLAUDE_LOG"; rm -f "$CODEX_LOG"
JOBS_DIR="$T/jobs" JOB_MODEL="gpt-5.6-sol" JOB_EFFORT="high" \
    CODEX_BIN="$SANDBOX_BIN/codex" CODEX_STUB_LIMIT=1 \
    CLAUDE_BIN="$SANDBOX_BIN/claude" \
    DESKCRAB_CODEX_STATE="$CODEX_STATE" \
    JOBS_BLOCKED_FILE="$T/blocked-marker" WANTS_FILE="$T/wants.md" \
    "$T/repo/lib/job-runner" cjob "$T/wd" >/dev/null 2>&1
STATE_NOW="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state",""))' "$T/jobs/cjob.json" 2>/dev/null)"
check_eq "the refused codex build is blocked" "$STATE_NOW" "blocked"
check_eq "no Claude account was walked — never a downgrade" \
    "$(sandbox_count_in '--model' "$SANDBOX_CLAUDE_LOG")" "0"
check_eq "the codex login was tried exactly once" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "1"
[ -s "$CODEX_STATE" ] && ok "the builder's refusal cooled the engine too" \
    || fail "a job refusal must record the codex cooldown" "no state file"

echo
echo "the chess mover — the python side of the same router (rule 15):"
rm -f "$CODEX_STATE"
VENV="${DESKCRAB_CHESS_VENV:-$SANDBOX_LIVE_DATA/chess/venv}"
PY="$VENV/bin/python"
if [ ! -x "$PY" ]; then
    echo "  skip: no chess venv at $VENV — the mover cases need python-chess"
else
    OUT="$(cd "$REPO/lib" && DESKCRAB_CODEX_STATE="$CODEX_STATE" \
        CODEX_BIN="$SANDBOX_BIN/codex" XDG_RUNTIME_DIR="$SANDBOX/run" "$PY" - <<'PYEOF'
import json, os, sys
sys.path.insert(0, ".")
import chess_mover as cm

print("backend-sol", cm._codex_backend("sol"))
print("backend-gpt", cm._codex_backend("gpt-5.6-sol"))
print("backend-opus", cm._codex_backend("opus"))
print("resolve", cm._codex_resolve("sol"))
text, usage = cm._codex_jsonl_answer(
    '{"type":"turn.started"}\n'
    '{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"e2e4"}}\n'
    '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":4,'
    '"cache_write_input_tokens":1,"output_tokens":2}}')
print("answer", text, usage["input_tokens"], usage["cache_read_input_tokens"])
print("raw-passthrough", cm._codex_jsonl_answer("a plain answer")[0])
os.environ["DESKCRAB_CHESS_MOVER_MODEL"] = "sol"
cmd = cm.Mover._codex_cmd("low")
print("cmd-model", cmd[cmd.index("-m") + 1])
print("cmd-effort", "model_reasoning_effort=low" in cmd)
instr = [a.split("=", 1)[1] for a in cmd if a.startswith("model_instructions_file=")]
print("cmd-instr", bool(instr) and os.path.getsize(instr[0]) > 0)
os.environ["DESKCRAB_CHESS_MOVER_MODEL"] = "sol"
m = cm.Mover.__new__(cm.Mover)
labels = []
for label, c, env in m._attempts("low"):
    labels.append(label)
    if label == "codex":
        print("codex-first", c[0].endswith("codex"), "OPENAI_API_KEY" not in env)
    else:
        print("fallback-model", c[c.index("--model") + 1])
        break
print("order", labels[:1])
PYEOF
)"
    check "sol and gpt names route codex, opus does not" \
        contains "$OUT" "backend-sol True"
    check "" contains "$OUT" "backend-gpt True"
    check "" contains "$OUT" "backend-opus False"
    check "the python resolve matches the shell's" contains "$OUT" "resolve gpt-5.6-sol"
    check "the JSONL answer is lifted with mapped usage" contains "$OUT" "answer e2e4 6 4"
    check "a non-codex stdout is not claimed by the extractor" contains "$OUT" "raw-passthrough None"
    check "the codex cmd names the slug" contains "$OUT" "cmd-model gpt-5.6-sol"
    check "…and the effort" contains "$OUT" "cmd-effort True"
    check "…and a written instructions file" contains "$OUT" "cmd-instr True"
    check "codex is tried first, without a stray API key" \
        contains "$OUT" "codex-first True True"
    check "the fallback accounts run a Claude model" contains "$OUT" "fallback-model sonnet"
    check "the first attempt is the codex one" contains "$OUT" "order ['codex']"
fi
