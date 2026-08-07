#!/bin/bash
# Tests that an INTERACTIVE turn is bounded and that an account swap is
# announced rather than silent.
# Run: bash tests/test_turn_watchdog.sh
#
# The gap these were written for, measured 2026-08-07: a desk turn hit a usage
# limit at 17:00:46, swapped accounts, and was still sitting in the second run
# at 17:12:06 — 680 s, nothing spoken, no error, a "Thinking..." notification
# stuck on screen the whole time. _wake_claude_run had a stall watchdog;
# _generate_claude_run, which serves BOTH the desk and the phone, was a plain
# foreground subshell, and claude_generate looped it over every account with no
# bound at all. The only limit on an interactive turn (TTS_WAIT_TIMEOUT) sat
# downstream of that unbounded loop and was never reached.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-watchdog.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — got [$2]"; }

mkdir -p "$T/bin" "$T/fb"
printf '#!/bin/bash\nprintf "NOTIFY:%%s\\n" "$*" >> "%s/notifies"\n' "$T" > "$T/bin/notify-send"
chmod +x "$T/bin/notify-send"

cat > "$T/conf" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$T"
ARCHIVE_DIR="$T/archive"
JOBS_DIR="$T/jobs"
WAKES_DIR="$T/wakes"
DAY_JOURNAL_DIR="$T/journal"
NOTICE_STATE_DIR="$T/notice"
LAST_ORIGIN_FILE="$T/last-origin"
WAKE_QUIET_HOURS=""
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
EOF

run() { # [ENV=val ...] <shell body> — sources common.sh in a scratch instance.
    local -a envs=()
    while [ $# -gt 1 ]; do envs+=("$1"); shift; done
    PATH="$T/bin:$PATH" DESKCRAB_CONF="$T/conf" DESKCRAB_STATE_PREFIX="$T/state" \
        DESKCRAB_STREAMLOG="$T/state-debug.log" \
        ACCOUNT_DEFAULT_FILE="$T/state-account-default" \
        NOTICE_STATE_DIR="$T/notice" WAKES_DIR="$T/wakes" \
        JOBS_DIR="$T/jobs" DAY_JOURNAL_DIR="$T/journal" DESKCRAB_NO_DISPATCH=1 \
        env ${envs[@]+"${envs[@]}"} \
        bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$REPO_DIR" "$1" 2>&1
}

REFUSAL="You're out of usage credits. Run /usage-credits to keep using Fable 5"
# Prewritten fixtures, not text embedded in a generated script: the refusal
# holds an apostrophe, which no quoting style survives being written into a
# stub. (The same reason tests/test_limit_fallback.sh does it this way.)
printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"'"$REFUSAL"'"}]}}' \
    '{"type":"result","is_error":true,"result":"'"$REFUSAL"'"}' > "$T/fixture-refusal"
printf '%s\n' \
    '{"type":"assistant","message":{"model":"claude","content":[{"type":"text","text":"CHAIN REPLY"}]}}' \
    '{"type":"result","result":"CHAIN REPLY"}' > "$T/fixture-reply"

# A stub that answers on the account named in STUB_OK_DIR (default: the first
# fallback) and refuses everywhere else, slowly enough that the chain's wall
# clock has something to measure.
cat > "$T/claude-stream" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-primary}" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "\${STUB_OK_DIR-$T/fb}" ]; then
    cat "$T/fixture-reply"
    exit 0
fi
sleep 2
cat "$T/fixture-refusal"
exit 1
EOF
chmod +x "$T/claude-stream"

# A stub that hangs: no output, no CPU, forever. Exactly the shape the desk
# turn sat in for eleven minutes.
cat > "$T/claude-hang" <<'EOF'
#!/bin/bash
exec sleep 600
EOF
chmod +x "$T/claude-hang"

echo "a hung interactive turn is reaped, not waited on forever:"

rm -f "$T/calls" "$T/state-account-default"
start=$(date +%s)
out="$(run TURN_STALL_TIMEOUT=1 CLAUDE_BIN="$T/claude-hang" 'claude_generate "hello" low')"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 60 ] && ok "claude_generate returns (${elapsed}s), it does not hang with the CLI" \
    || fail "an unwatched turn never returns" "${elapsed}s"
grep -q '"note":"reaped"' "$T/state-debug.log" 2>/dev/null \
    && ok "the reap is written into the stream log, so the silence is explicable" \
    || fail "a reaped run must say so in the log" "$(tr -d '\n' < "$T/state-debug.log" | head -c 200)"
pgrep -f "$T/claude-hang" >/dev/null 2>&1 \
    && fail "the reaped CLI is still running" "$(pgrep -f "$T/claude-hang" | tr '\n' ' ')" \
    || ok "the CLI process is actually gone"

echo
echo "a healthy turn pays nothing for the watchdog:"

rm -f "$T/calls" "$T/state-account-default"
start=$(date +%s)
out="$(run STUB_OK_DIR= CLAUDE_BIN="$T/claude-stream" 'claude_generate "hello" low')"
elapsed=$(( $(date +%s) - start ))
[ "$out" = "CHAIN REPLY" ] && ok "the reply comes back unchanged" || fail "a watched run must still answer" "$out"
# The poll ticks every second precisely so the turn is not held for a whole
# poll interval after the CLI exits — a flat 10 s sleep would land here.
[ "$elapsed" -lt 5 ] && ok "no dead time on the end of a fast turn (${elapsed}s)" \
    || fail "the watchdog must not delay a finished turn" "${elapsed}s"

echo
echo "every account swap is announced:"

rm -f "$T/calls" "$T/notifies" "$T/state-account-default"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" CLAUDE_BIN="$T/claude-stream" \
    'claude_generate "hello" low')"
[ "$out" = "CHAIN REPLY" ] && ok "the fallback answers as before" || fail "the chain must still walk" "$out"
grep -q '"note":"account-swap"' "$T/state-debug.log" 2>/dev/null \
    && ok "the swap is marked in the stream log" \
    || fail "a swap must leave a marker" "$(grep -o '"note":"[a-z-]*"' "$T/state-debug.log" | tr '\n' ' ')"
grep -q "NOTIFY:.*trying" "$T/notifies" 2>/dev/null \
    && ok "the desk is told the login changed" \
    || fail "a swap on a waiting turn must notify" "$(cat "$T/notifies" 2>/dev/null || echo none)"
# The marker must not carry the refusal's words: claude_run_limited greps the
# WHOLE log for the limit signature, so a marker quoting it would make a later
# network error read as one more refusal.
grep '"type":"deskcrab_note"' "$T/state-debug.log" | grep -qi "usage credits" \
    && fail "the marker must not repeat the refusal text" "$(grep '"type":"deskcrab_note"' "$T/state-debug.log")" \
    || ok "the marker carries no limit wording of its own"

rm -f "$T/calls" "$T/notifies" "$T/state-account-default"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" CLAUDE_BIN="$T/claude-stream" '
    SESSION_KIND="autonomous wake" SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "CHAIN REPLY" ] && ok "the wake chain answers as before" || fail "the wake chain must still walk" "$out"
grep -q '"note":"account-swap"' "$T/state-debug.log" 2>/dev/null \
    && ok "a wake's swap is marked too" \
    || fail "the wake path must mark its swaps" "$(grep -o '"note":"[a-z-]*"' "$T/state-debug.log" | tr '\n' ' ')"
[ ! -s "$T/notifies" ] && ok "a wake never pops a notification for it (it may be 3am)" \
    || fail "a wake must not notify on a swap" "$(cat "$T/notifies")"

echo
echo "the whole chain has a wall clock, not just each run:"

rm -f "$T/calls" "$T/state-account-default"
run TURN_CHAIN_TIMEOUT=1 CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" STUB_OK_DIR=/never \
    CLAUDE_BIN="$T/claude-stream" 'claude_generate "hello" low' >/dev/null
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 1 ] && ok "the walk stops at the ceiling instead of booting another CLI" \
    || fail "the chain must be bounded as a whole" "$n calls"
grep -q '"note":"chain-abandoned"' "$T/state-debug.log" 2>/dev/null \
    && ok "and says so in the log" \
    || fail "an abandoned chain must say so" "$(grep -o '"note":"[a-z-]*"' "$T/state-debug.log" | tr '\n' ' ')"

# Unbounded is the default nobody wants twice: the ceiling must be a number,
# not an absence.
out="$(run 'echo "${TURN_STALL_TIMEOUT:-unset}/${TURN_CHAIN_TIMEOUT:-unset}"')"
[ "$out" = "120/900" ] && ok "both bounds ship with defaults" \
    || fail "the bounds must default to something" "$out"

echo
echo "the markers are invisible to every reader of the stream:"

# A marker line is a JSON line of an unknown type; every reader already skips
# those. If one ever stops doing so, the turn's own reply changes shape.
printf '%s\n' \
    '{"type":"deskcrab_note","note":"account-swap","detail":"primary -> fb","at":"12:00:00"}' \
    '{"type":"assistant","message":{"model":"claude","content":[{"type":"text","text":"A real reply."}]}}' \
    '{"type":"result","result":"A real reply."}' > "$T/marker.log"
out="$(DESKCRAB_DEBUGLOG="$T/marker.log" "$REPO_DIR/lib/extract-response")"
[ "$out" = "A real reply." ] && ok "extract-response ignores it" || fail "extract-response must skip the marker" "$out"
out="$(python3 -c '
import json, sys
bad = []
for n, line in enumerate(open(sys.argv[1]), 1):
    if not line.strip():
        continue
    try:
        json.loads(line)
    except ValueError:
        bad.append("line %d" % n)
print(", ".join(bad) if bad else "all parse")
' "$T/state-debug.log" 2>&1)"
[ "$out" = "all parse" ] && ok "a real turn's log, markers and all, parses line by line" \
    || fail "every line the turn wrote must be parseable JSON" "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
