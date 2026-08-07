#!/bin/bash
# Tests for the usage-limit fallback (CLAUDE_FALLBACK_CONFIG_DIR): the
# claude_limit_fallback_due predicate, the wake-path retry (_wake_claude_run),
# extract-response on a combined refusal+reply log, the TTS streamer riding
# through a refusal, and the job-runner's second attempt on the fallback login.
# Run: bash tests/test_limit_fallback.sh
#
# The gap these were written for: on 2026-08-07 the primary account ran out of
# usage credits mid-morning — every wake failed, two jobs were recorded
# "blocked", and a second, idle subscription sat on the same machine the whole
# time. The fallback tries that second login before giving anything up.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-limitfb.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — got [$2]"; }

# A scratch conf so the live one's settings (including any real fallback dir)
# never reach these cases; the fallback dir under test is passed per-case in
# the environment, which the config's ${VAR:-} defaults let through.
cat > "$T/conf" <<EOF
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
PROJECT_DIR="$T"
EOF

run() { # [ENV=val ...] <shell body> — sources common.sh in a scratch instance.
    # Every argument but the last is an env assignment; the last is the body.
    # CLAUDE_CONFIG_DIR is stripped: a claude session running these tests may
    # itself live under one, and an inherited value makes the stub's "primary
    # login" branch unreachable.
    local -a envs=()
    while [ $# -gt 1 ]; do envs+=("$1"); shift; done
    DESKCRAB_CONF="$T/conf" DESKCRAB_STATE_PREFIX="$T/state" \
        JOBS_DIR="$T/jobs" DAY_JOURNAL_DIR="$T/journal" DESKCRAB_NO_DISPATCH=1 \
        env -u CLAUDE_CONFIG_DIR ${envs[@]+"${envs[@]}"} \
        bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$REPO_DIR" "$1" 2>&1
}

# The CLI's refusal, as observed live on 2026-08-07, in stream-json shape: a
# synthetic assistant message whose text is the error, plus an is_error result.
REFUSAL="You're out of usage credits. Run /usage-credits to keep using Fable 5"
refusal_stream() {
    printf '%s\n' \
        '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"'"$REFUSAL"'"}]}}' \
        '{"type":"result","is_error":true,"result":"'"$REFUSAL"'"}'
}
reply_stream() { # <text>
    printf '%s\n' \
        '{"type":"assistant","message":{"model":"claude","content":[{"type":"text","text":"'"$1"'"}]}}' \
        '{"type":"result","result":"'"$1"'"}'
}

echo "claude_limit_fallback_due — retry exactly when a fallback can help:"
refusal_stream > "$T/state-debug.log"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = DUE ] && ok "limit refusal + configured fallback is due" || fail "should be due" "$out"

out="$(run 'claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = no ] && ok "no fallback configured, no retry" || fail "must not be due without a fallback" "$out"

printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Invalid API key"}]}}' \
    '{"type":"result","is_error":true,"result":"Invalid API key"}' > "$T/state-debug.log"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = no ] && ok "an auth failure is not retried" || fail "auth failures must surface as themselves" "$out"

reply_stream "a genuine answer" > "$T/state-debug.log"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = no ] && ok "a genuine reply is never retried" || fail "real output must not retry" "$out"

echo "the shared signature — session-limit wordings match, prose does not:"
for line in \
    "Session limit reached - resets 3am" \
    "You've hit your session limit for Fable 5" \
    "5-hour limit reached"
do
    printf '%s\n' "$line" > "$T/sig"
    out="$(run 'job_output_blocked "'"$T"'/sig" && echo BLOCKED || echo no')"
    [ "$out" = BLOCKED ] && ok "matches: ${line:0:40}" || fail "should match: ${line:0:40}" "$out"
done
printf '%s\n' "job-runner: primary login refused (limit) — retrying once via CLAUDE_CONFIG_DIR=/x" > "$T/sig"
out="$(run 'job_output_blocked "'"$T"'/sig" && echo BLOCKED || echo no')"
[ "$out" = no ] && ok "the runner's own retry marker never matches" || fail "marker must not match the signature" "$out"

echo "extract-response — the refusal never prefixes a real reply:"
{ refusal_stream; reply_stream "FALLBACK REPLY"; printf '{"type":"result"}\n'; } > "$T/combined.log"
out="$(DESKCRAB_DEBUGLOG="$T/combined.log" "$REPO_DIR/lib/extract-response")"
[ "$out" = "FALLBACK REPLY" ] && ok "combined log extracts only the reply" || fail "refusal leaked into the reply" "$out"

{ refusal_stream; printf '{"type":"result"}\n'; } > "$T/refonly.log"
out="$(DESKCRAB_DEBUGLOG="$T/refonly.log" "$REPO_DIR/lib/extract-response")"
case "$out" in *"out of usage credits"*) ok "an error-only stream still reports itself" ;;
    *) fail "error-only stream must keep the refusal text" "$out" ;; esac

echo "tts-streamer — rides through one refusal when a retry is coming:"
mkdir -p "$T/bin"
printf '#!/bin/bash\ncat >> "%s/spoken"\n' "$T" > "$T/bin/piper-tts"
printf '#!/bin/bash\ncat > /dev/null\n' > "$T/bin/aplay"
chmod +x "$T/bin/piper-tts" "$T/bin/aplay"
LIMIT_RE_DEFAULT="$(run 'printf %s "$CLAUDE_LIMIT_RE"')"

rm -f "$T/spoken"
{ refusal_stream; reply_stream "HELLO FROM FALLBACK"; printf '{"type":"result"}\n'; } > "$T/tts.log"
PATH="$T/bin:$PATH" DESKCRAB_DEBUGLOG="$T/tts.log" DESKCRAB_PIPER_VOICE=/x \
    DESKCRAB_CLAUDE_LIMIT_RE="$LIMIT_RE_DEFAULT" DESKCRAB_CLAUDE_FALLBACK="$T/fb" \
    timeout 20 "$REPO_DIR/lib/tts-streamer"
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"HELLO FROM FALLBACK"*) ok "the retried reply is spoken" ;;
    *) fail "the retry's words must reach the voice" "$(cat "$T/spoken" 2>/dev/null)" ;; esac
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"out of usage credits"*) fail "the refusal must not be voiced when a retry is coming" "$(cat "$T/spoken")" ;;
    *) ok "the refusal stays unspoken" ;; esac

rm -f "$T/spoken"
PATH="$T/bin:$PATH" DESKCRAB_DEBUGLOG="$T/tts.log" DESKCRAB_PIPER_VOICE=/x \
    timeout 20 "$REPO_DIR/lib/tts-streamer"
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"out of usage credits"*) ok "no fallback: the refusal keeps its voice" ;;
    *) fail "without a fallback the refusal must still be spoken" "$(cat "$T/spoken" 2>/dev/null)" ;; esac
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"HELLO FROM FALLBACK"*) fail "no fallback: must stop at the first result" "$(cat "$T/spoken")" ;;
    *) ok "no fallback: the tail stops at the error result" ;; esac

rm -f "$T/spoken"
{ refusal_stream; refusal_stream; printf '{"type":"result"}\n'; } > "$T/tts2.log"
PATH="$T/bin:$PATH" DESKCRAB_DEBUGLOG="$T/tts2.log" DESKCRAB_PIPER_VOICE=/x \
    DESKCRAB_CLAUDE_LIMIT_RE="$LIMIT_RE_DEFAULT" DESKCRAB_CLAUDE_FALLBACK="$T/fb" \
    timeout 20 "$REPO_DIR/lib/tts-streamer"
n="$(grep -c "out of usage credits" "$T/spoken" 2>/dev/null)"
[ "${n:-0}" = 1 ] && ok "both logins refusing is spoken once, not twice or never" \
    || fail "a second refusal is real news, exactly once" "spoken $n times"

echo "_wake_claude_run — the wake retry lands on the fallback login:"
# A stream-mode stub: refuses on the primary login, answers on the fallback.
# The streams are prewritten fixtures — the refusal text holds an apostrophe,
# which no quoting style survives being embedded in a generated script.
refusal_stream > "$T/fixture-refusal"
reply_stream "WAKE FALLBACK REPLY" > "$T/fixture-reply"
cat > "$T/claude-stream" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-primary}" >> "$T/calls"
if [ -z "\${CLAUDE_CONFIG_DIR:-}" ]; then
    cat "$T/fixture-refusal"
    exit 1
fi
cat "$T/fixture-reply"
EOF
chmod +x "$T/claude-stream"
rm -f "$T/calls"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    _wake_claude_run ""
    claude_limit_fallback_due && _wake_claude_run "$CLAUDE_FALLBACK_CONFIG_DIR"
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE FALLBACK REPLY" ] && ok "wake run retries and extracts the real reply" \
    || fail "wake retry should yield the fallback's reply" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:primary
CALL:$T/fb" ] && ok "exactly two calls: primary then fallback" \
    || fail "call order must be primary, then fallback" "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"

echo "job-runner — a limited primary is retried, not recorded blocked:"
# Same scaffold as test_job_block.sh: copied runner, symlinked common.sh, fake
# crab, isolated journal — nothing here may reach the live instance.
mkdir -p "$T/repo/lib" "$T/jobs"
cp "$REPO_DIR/lib/job-runner" "$T/repo/lib/job-runner"
ln -sf "$REPO_DIR/lib/common.sh" "$T/repo/lib/common.sh"
chmod +x "$T/repo/lib/job-runner"
printf '#!/bin/bash\necho "WAKE: $*" >> "%s/wakes"\n' "$T" > "$T/repo/crab"
chmod +x "$T/repo/crab"
# A plain-mode stub: refuses on the primary login; on the fallback it builds —
# unless STUB_FALLBACK_FAILS says that account is out too.
cat > "$T/claude-plain" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-primary}" >> "$T/calls"
if [ -z "\${CLAUDE_CONFIG_DIR:-}" ] || [ -n "\${STUB_FALLBACK_FAILS:-}" ]; then
    echo "$REFUSAL"
    exit 1
fi
echo "BUILT OK"
EOF
chmod +x "$T/claude-plain"

run_runner() { # <id> [ENV=val ...]
    local id="$1"; shift
    "$REPO_DIR/lib/job-status" new "$T/jobs" "$id" "do a thing" "" >/dev/null 2>&1 || \
        python3 -c 'import json,sys,time; json.dump({"id":sys.argv[2],"description":"do a thing","started_epoch":int(time.time()),"state":"running","unit":""},open(sys.argv[1]+"/"+sys.argv[2]+".json","w"))' "$T/jobs" "$id"
    JOBS_DIR="$T/jobs" DESKCRAB_CONF="$T/conf" DESKCRAB_STATE_PREFIX="$T/state" \
        DAY_JOURNAL_DIR="$T/journal" CLAUDE_BIN="$T/claude-plain" \
        env -u CLAUDE_CONFIG_DIR "$@" "$T/repo/lib/job-runner" "$id" "$T" >/dev/null 2>&1
}

rm -f "$T/calls" "$T/jobs/blocked"
run_runner fbworks CLAUDE_FALLBACK_CONFIG_DIR="$T/fb"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/fbworks.json" state)"
[ "$out" = finished ] && ok "fallback succeeds: the job is finished, not blocked" || fail "should finish via the fallback" "$out"
case "$(cat "$T/jobs/fbworks.log" 2>/dev/null)" in
    *"retrying once via CLAUDE_CONFIG_DIR="*) ok "the retry is recorded in the job log" ;;
    *) fail "the log must say a retry happened" "$(cat "$T/jobs/fbworks.log" 2>/dev/null | head -n2)" ;; esac
[ ! -e "$T/jobs/blocked" ] && ok "no block marker when the fallback carried the job" \
    || fail "a completed job must not hold future dispatches" "$(cat "$T/jobs/blocked")"

rm -f "$T/calls" "$T/jobs/blocked"
run_runner bothout CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" STUB_FALLBACK_FAILS=1
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/bothout.json" state)"
[ "$out" = blocked ] && ok "both logins refusing is blocked, as before" || fail "should block when the fallback is out too" "$out"
[ -e "$T/jobs/blocked" ] && ok "the block marker is written for a double refusal" \
    || fail "double refusal must hold dispatches" "no marker"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 2 ] && ok "exactly one retry — never a third attempt" || fail "must try each login once" "$n calls"

rm -f "$T/calls" "$T/jobs/blocked"
run_runner nofb
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/nofb.json" state)"
[ "$out" = blocked ] && ok "no fallback configured: blocked exactly as before" || fail "unconfigured must keep old behaviour" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 1 ] && ok "no fallback: a single attempt" || fail "must not retry without a fallback" "$n calls"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
