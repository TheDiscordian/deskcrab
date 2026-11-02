#!/usr/bin/env bash
# A silent wake that survived a capacity retry is a silent wake, never a
# failure inherited from the attempt before it (specs/wake-queue.md rule 23b,
# specs/model-backends.md rule 12a's last clause).
#
# The incident this holds the line against (2026-11-02, 01:24): a codex wake
# hit "Selected model is at capacity" five tool calls in. The chain judged
# that attempt's own slice, retried the same model, and the retry wrote its
# moment through five more tool calls and ended on an empty, non-error
# result — a silent wake, no text block. The journal row read "(wake failed
# before the model ran — claude exit 0: )": wake_stream_failed judged the
# WHOLE stream from byte 0, where the first attempt's is_error result still
# stood, and a silent retry produces no text block to clear it. The moment
# was on disk and invisible to everything that reads the outcome field.
#
# What the contract demands instead: every verdict on a wake — failed, cut,
# spoke, silent — is drawn from the FINAL attempt's slice, from the byte
# mark the walk recorded when that attempt began; a final attempt ending in
# a capacity error is still the failure it always was; an error in the final
# retry is not masked by tool work or text in an earlier one; and the work
# record still reads every attempt, because every attempt's tool calls ran.
#
# Three layers, each stubbed, silent and confined to the sandbox: the
# classifier on hand-written stream slices; wake_claude_run_chain leaving the
# mark where the retry began; and run_claude_wake end to end against a stub
# app-server, in its own process, exactly as tests/test_silent_wake.sh runs.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
CODEX_LOG="$WORK/witness-codex.log"
MARK="$WORK/capacity-once"
mkdir -p "$HOME/notes"

CAPACITY='Selected model is at capacity. Please try a different model.'
LIMIT_LINE="You've hit your session limit · resets 1:30am"

# The stream shapes below are the translator's own (lib/codex-app-stream):
# the archived 2026-11-02 stream, cut down to the lines that decide anything.
first_attempt() { # <file>  — tool work, then the capacity error, then the retry note
    cat > "$1" <<EOF
{"type":"deskcrab_note","note":"session","detail":"autonomous wake pid 1","at":"01:24:19"}
{"type": "system", "subtype": "init", "engine": "codex", "transport": "app-server", "model": "gpt-test"}
{"type": "assistant", "message": {"id": "exec-1", "model": "gpt-test", "content": [{"type": "tool_use", "id": "exec-1", "name": "Bash", "input": {"command": "ls ~/Library/wants"}}]}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "exec-1", "is_error": false, "content": "status=completed exit=0\n0-AT-THE-DOOR.txt"}]}}
{"method":"error","params":{"error":{"message":"$CAPACITY","codexErrorInfo":"serverOverloaded","additionalDetails":null},"willRetry":false}}
{"type": "result", "engine": "codex", "model": "gpt-test", "result": "$CAPACITY", "usage": {"input_tokens": 5166, "output_tokens": 66}, "is_error": true}
{"type":"deskcrab_note","note":"codex-capacity-retry","detail":"codex server capacity was unavailable — retrying the same model (1/2)","at":"01:25:11"}
EOF
}
silent_retry() { # <file>  — appended: tool work, a file written, an empty clean result
    cat >> "$1" <<'EOF'
{"type": "system", "subtype": "init", "engine": "codex", "transport": "app-server", "model": "gpt-test"}
{"type": "assistant", "message": {"id": "exec-2", "model": "gpt-test", "content": [{"type": "tool_use", "id": "exec-2", "name": "Bash", "input": {"command": "cat > ~/Library/moments/2026-11-02-the-second-glove.md <<'EOF'\n# The second glove\nEOF"}}]}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "exec-2", "is_error": false, "content": "status=completed exit=0\n"}]}}
{"type": "assistant", "message": {"id": "exec-3", "model": "gpt-test", "content": [{"type": "tool_use", "id": "exec-3", "name": "Bash", "input": {"command": "crab checkpoint 'Finished the invented scene The second glove'"}}]}}
{"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "exec-3", "is_error": false, "content": "status=completed exit=0\nCheckpointed.\n"}]}}
{"type": "result", "engine": "codex", "model": "gpt-test", "result": "", "usage": {"input_tokens": 240, "output_tokens": 4}}
{"type":"result"}
EOF
}
judge() { # <file> [offset]
    sandbox_bash "DEBUGLOG='$1'; wake_stream_judge ${2:-0}" 2>/dev/null </dev/null
}
failed() { # <file> [offset]  — exit 0 when the classifier calls the slice failed
    sandbox_bash "DEBUGLOG='$1'; wake_stream_failed ${2:-}" </dev/null
}

echo "the classifier on the final attempt's slice (rule 23b):"
F="$WORK/retry.log"
first_attempt "$F"
OFF="$(wc -c < "$F")"
silent_retry "$F"
failed "$F" "$OFF" \
    && fail "the silent retry is read as the first attempt's capacity failure" "$(tail -n3 "$F")" \
    || ok "a clean tool-only retry past the mark is not a failed wake"
check_eq "…its verdict is silence" "$(judge "$F" "$OFF")" "silent"
failed "$F" \
    && ok "the same log from byte 0 still reads as the error the first attempt left — the mark is the fix" \
    || fail "the whole-log reading changed under this test" "$(head -n7 "$F")"
check_eq "…and byte 0 says failed" "$(judge "$F" 0)" "failed"
TRACE="$(sandbox_bash "DEBUGLOG='$F'; wake_work_trace" 2>/dev/null </dev/null)"
check "the work record names the moment the retry wrote" \
    contains "$TRACE" "wrote ~/Library/moments/2026-11-02-the-second-glove.md"
check "…and counts every attempt's commands, because every one of them ran" \
    contains "$TRACE" "ran 3 commands"

echo
echo "a lone capacity attempt is still the failure it was:"
F1="$WORK/capacity-only.log"
first_attempt "$F1"
printf '%s\n' '{"type":"deskcrab_note","note":"codex-capacity-exhausted","detail":"codex server capacity stayed unavailable after 1 attempts","at":"01:25:12"}' >> "$F1"
printf '%s\n' '{"type":"result"}' >> "$F1"
failed "$F1" 0 \
    && ok "capacity with no retry behind it is a failed wake" \
    || fail "a lone capacity error must still fail the wake" "$(cat "$F1")"
check_eq "…verdict failed" "$(judge "$F1" 0)" "failed"

echo
echo "an error in the final retry is not masked by what came before it:"
F2="$WORK/retry-netdead.log"
first_attempt "$F2"
OFF2="$(wc -c < "$F2")"
cat >> "$F2" <<'EOF'
{"type": "assistant", "message": {"id": "exec-2", "model": "gpt-test", "content": [{"type": "tool_use", "id": "exec-2", "name": "Bash", "input": {"command": "cat ~/Library/reading.md"}}]}}
{"type": "result", "engine": "codex", "model": "gpt-test", "result": "connection reset by peer", "is_error": true}
{"type":"result"}
EOF
failed "$F2" "$OFF2" \
    && ok "tool work before a network death on the retry does not make it a run that answered" \
    || fail "the retry's own error must fail the wake" "$(tail -n3 "$F2")"
# Genuine TEXT in the earlier attempt — a cut after it began to speak, then
# the next login dying with an error alone. Read whole, the text masks the
# error (an error AND genuine text is not the failure shape); read from the
# mark, the final attempt is exactly an error with nothing genuine.
F3="$WORK/cut-then-error.log"
cat > "$F3" <<EOF
{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"Let me look at the drawer first."}]}}
{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}
{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"$LIMIT_LINE"}]}}
{"is_error":true,"duration_api_ms":31572,"num_turns":9}
{"type":"deskcrab_note","note":"account-swap","detail":"account 1 -> account 2 (limit refusal)","at":"00:17:40"}
EOF
OFF3="$(wc -c < "$F3")"
cat >> "$F3" <<'EOF'
{"type":"result","subtype":"error","is_error":true,"result":"connection reset by peer"}
{"type":"result"}
EOF
failed "$F3" \
    && fail "the whole-log reading changed under this test" "$(cat "$F3")" \
    || ok "read whole, the first attempt's words mask the final attempt's error (the old reading)"
failed "$F3" "$OFF3" \
    && ok "read from the mark, the final attempt's error is the verdict" \
    || fail "an earlier attempt's text must not acquit the final attempt" "$(tail -n2 "$F3")"
check_eq "…verdict failed" "$(judge "$F3" "$OFF3")" "failed"

echo
echo "the other verdicts, so a reply is never wiped as silence:"
F4="$WORK/spoke.log"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"The lantern needs rewiring."}]}}' '{"type":"result","result":"The lantern needs rewiring."}' > "$F4"
check_eq "a text block is spoke" "$(judge "$F4" 0)" "spoke"
printf '%s\n' '{"type":"result","result":"the words, in the result alone"}' > "$F4"
check_eq "a non-error result carrying text is spoke — the extractor's result-only shape" \
    "$(judge "$F4" 0)" "spoke"
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"half a "}}}' > "$F4"
check_eq "a text delta is spoke" "$(judge "$F4" 0)" "spoke"
check_eq "a mark at the end of the log is silence, not failure" \
    "$(judge "$F" "$(wc -c < "$F")")" "silent"
check_eq "a log that cannot be read is unjudged" "$(judge "$WORK/no-such.log" 0)" "unjudged"
failed "$WORK/no-such.log" 0 \
    && fail "an unreadable log must not read as a failure" "" \
    || ok "…and unjudged is not failed"

# --- the stub codex: an app-server that is at capacity once ----------------
# Modes: capacity-once (the incident: tool work and the error, then on the
# retry tool work, a file written, and no words), capacity-always, and
# capacity-then-netdead (the retry dies with an ordinary error).
cat > "$WORK/codex-app-responder.py" <<'PYR'
import json, os, sys
def send(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})
CAP = "Selected model is at capacity. Please try a different model."
NET = "connection reset by peer"
mode = os.environ.get("CODEX_STUB_MODE", "capacity-once")
mark = os.environ.get("CODEX_STUB_MARK", "")
home = os.environ.get("HOME", "/nonexistent")
def command(cid, cmd):
    notify("item/completed", {"threadId": "th-1", "turnId": "tu-1",
        "item": {"type": "commandExecution", "id": cid, "command": cmd,
                 "status": "completed", "exitCode": 0,
                 "aggregatedOutput": "status=completed\n"}})
def fail_turn(message, info):
    notify("error", {"error": {"message": message, "codexErrorInfo": info,
                               "additionalDetails": None},
                     "willRetry": False, "threadId": "th-1", "turnId": "tu-1"})
    notify("turn/completed", {"threadId": "th-1",
        "turn": {"id": "tu-1", "status": "failed", "error": {"message": message}}})
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
        first = not (mark and os.path.exists(mark))
        if mark and first:
            open(mark, "w").close()
        if mode == "capacity-always" or first:
            command("cmd_0", "ls %s/Library/wants" % home)
            fail_turn(CAP, "serverOverloaded")
            sys.exit(0)
        if mode == "capacity-then-netdead":
            command("cmd_1", "cat %s/Library/reading.md" % home)
            fail_turn(NET, None)
            sys.exit(0)
        command("cmd_1", "cat > %s/notes/the-second-glove.md <<'EOF'\n# The second glove\nEOF" % home)
        command("cmd_2", "crab checkpoint 'Finished the invented scene The second glove'")
        notify("turn/completed", {"threadId": "th-1",
            "turn": {"id": "tu-1", "status": "completed", "error": None}})
        sys.exit(0)
PYR
sandbox_stub codex <<STUB
#!/bin/bash
printf 'INVOKED %s\n' "\$1" >> "$CODEX_LOG"
if [ "\$1" = "app-server" ]; then
    exec python3 "$WORK/codex-app-responder.py"
fi
cat > /dev/null
printf '%s\n' '{"type":"error","message":"the exec road is not under test here"}'
exit 1
STUB

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
CODEX_BIN="$SANDBOX_BIN/codex"
PROJECT_DIR="$HOME"
WAKE_MODEL="gpt-5.6-sol"
CODEX_CAPACITY_RETRY_DELAY=0
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf '# Wants\n\n- a want, so the wake path is enabled at all\n' > "$WORK/wants.md"

echo
echo "the walk leaves the mark where the final attempt began:"
rm -f "$MARK" "$CODEX_LOG"; : > "$WORK/chain.log"
OUT="$(sandbox_bash "DEBUGLOG='$WORK/chain.log'
    SYSTEM_PROMPT='sys' PROMPT_TEXT='the agenda'
    WAKE_MODEL='gpt-5.6-sol' WAKE_EFFORT='low'
    CODEX_STUB_MODE=capacity-once CODEX_STUB_MARK='$MARK' CODEX_CAPACITY_RETRY_DELAY=0 wake_claude_run_chain
    echo \"attempts=\$WAKE_CHAIN_ATTEMPTS offset=\$WAKE_CHAIN_LAST_OFFSET\"" 2>/dev/null </dev/null)"
check_eq "the capacity wake retried once" "${OUT##*attempts=}" "2 offset=${OUT##*offset=}"
MARKED="${OUT##*offset=}"
case "$MARKED" in
    ''|*[!0-9]*) fail "the walk left no byte mark for its final attempt" "$OUT" ;;
    *) [ "$MARKED" -gt 0 ] && ok "the mark is a byte offset into the stream ($MARKED)" \
        || fail "the mark must sit past the first attempt" "$OUT" ;;
esac
case "$MARKED" in ''|*[!0-9]*) MARKED=0 ;; esac
check "before the mark: the first attempt's error result" \
    contains "$(head -c "$MARKED" "$WORK/chain.log")" '"is_error": true'
check "before the mark: the retry note" \
    contains "$(head -c "$MARKED" "$WORK/chain.log")" "codex-capacity-retry"
check_eq "after the mark: no error result at all" \
    "$(tail -c "+$((MARKED + 1))" "$WORK/chain.log" | grep -c '"is_error": true')" "0"
check "after the mark: the retry's tool work" \
    contains "$(tail -c "+$((MARKED + 1))" "$WORK/chain.log")" "the-second-glove.md"
check_eq "the mark falls on a line boundary" \
    "$(tail -c "+$((MARKED + 1))" "$WORK/chain.log" | head -c 1)" "{"
check_eq "…and the final attempt judged from it is silence" \
    "$(judge "$WORK/chain.log" "$MARKED")" "silent"

# --- the whole wake, in its own process -------------------------------------
# run_claude_wake is called directly rather than through `crab wake`, so the
# test books no timers; PIDFILE is set by hand because `crab` sets it.
wake() { # <reason> <stub mode> [extra env assignments...]
    local REASON="$1" MODE="$2"
    shift 2
    rm -f "$MARK"
    env CODEX_STUB_MODE="$MODE" CODEX_STUB_MARK="$MARK" "$@" bash -c '
        . "$1/lib/common.sh"
        PIDFILE="$2"
        WAKE_REASON="$3"
        run_claude_wake "(Autonomous wake — test)"
    ' _ "$REPO" "$PIDFILE" "$REASON" >/dev/null 2>&1 </dev/null
}
# shellcheck source=/dev/null
source "$REPO/lib/common.sh" >/dev/null 2>&1   # for CONVOFILE, SESSIONS_LOG, WAKES_DIR
PIDFILE="$WORK/rec.pid"
rm -f "$PIDFILE"
clear_wakes() { rm -f "${WAKES_DIR:?}"/*.wake 2>/dev/null; return 0; }

echo
echo "the incident, end to end — capacity once, then a silent retry that writes:"
: > "$CONVOFILE"; clear_wakes; rm -f "$CODEX_LOG"
wake "own time — a quiet hour, hers to choose" capacity-once
LINE="$(tail -n1 "$SESSIONS_LOG" 2>/dev/null)"
check_eq "codex ran twice: the capacity attempt and its retry" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "2"
check "the journal reads the wake as silent, with the moment it wrote" \
    contains "$LINE" "(silent — wrote ~/notes/the-second-glove.md"
check "…and counts every attempt's commands" contains "$LINE" "ran 3 commands"
case "$LINE" in
    *"wake failed"*) fail "the silent retry is journalled as the capacity failure before it" "$LINE" ;;
    *) ok "no failure line for a wake whose last attempt ran clean" ;;
esac
case "$LINE" in
    *"at capacity"*) fail "the provider's capacity message reached the journal as her words" "$LINE" ;;
    *) ok "the capacity message stays out of the outcome" ;;
esac
ls "$WAKES_DIR"/*.wake >/dev/null 2>&1 \
    && grep -q "outage-retry" "$WAKES_DIR"/*.wake 2>/dev/null \
    && fail "a wake that did its work still re-booked itself as an outage" "$(cat "$WAKES_DIR"/*.wake)" \
    || ok "nothing re-booked — the wake was not an outage"
[ -s "$CONVOFILE" ] \
    && fail "a silent wake left something in the conversation" "$(cat "$CONVOFILE")" \
    || ok "the conversation is untouched by a silent wake"

echo
echo "persistent capacity is still the failure it was, and re-books:"
: > "$CONVOFILE"; clear_wakes; rm -f "$CODEX_LOG"
wake "a thought the server had no room for" capacity-always CODEX_CAPACITY_RETRIES=1
LINE="$(tail -n1 "$SESSIONS_LOG" 2>/dev/null)"
check_eq "codex was tried the configured number of times" \
    "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "2"
check "the journal records the failed run" contains "$LINE" "wake failed before the model ran"
REBOOK="$(grep -l "outage-retry" "$WAKES_DIR"/*.wake 2>/dev/null | head -n1)"
[ -n "$REBOOK" ] && ok "the agenda was re-booked through outage-retry" \
    || fail "an exhausted capacity wake must re-book" "$(ls "$WAKES_DIR" 2>/dev/null)"
[ -n "$REBOOK" ] && { grep -q "no room for" "$REBOOK" && ok "…carrying its agenda" \
    || fail "the re-book lost the agenda" "$(cat "$REBOOK")"; }
[ -s "$CONVOFILE" ] \
    && fail "the capacity failure left something in the conversation" "$(cat "$CONVOFILE")" \
    || ok "nothing entered the conversation"

echo
echo "a retry that dies on the network is a failed wake, named by its own error:"
: > "$CONVOFILE"; clear_wakes; rm -f "$CODEX_LOG"
wake "a thought the network dropped" capacity-then-netdead
LINE="$(tail -n1 "$SESSIONS_LOG" 2>/dev/null)"
check_eq "codex ran twice" "$(sandbox_count_in '^INVOKED' "$CODEX_LOG")" "2"
check "the journal records the failed run" contains "$LINE" "wake failed before the model ran"
check "…naming the retry's own error, not the capacity before it" \
    contains "$LINE" "connection reset by peer"
REBOOK="$(grep -l "outage-retry" "$WAKES_DIR"/*.wake 2>/dev/null | head -n1)"
[ -n "$REBOOK" ] && ok "the agenda was re-booked through outage-retry" \
    || fail "a wake whose retry died must re-book" "$(ls "$WAKES_DIR" 2>/dev/null)"
