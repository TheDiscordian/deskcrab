#!/bin/bash
# Tests for the usage-limit fallback (CLAUDE_FALLBACK_CONFIG_DIR): the
# claude_limit_fallback_due predicate, the moving account default (a refusal
# makes the NEXT login in the chain the default — immediately, durably,
# wrapping at the end, and never reverting on a timer), the wake-path retry,
# extract-response on a combined refusal+reply log, the TTS streamer riding
# through a refusal, and the job-runner's attempts along the chain.
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
    # CLAUDE_CONFIG_DIR is deliberately NOT stripped here any more. It used to
    # be, with the note "an inherited value makes the stub's 'primary login'
    # branch unreachable" — which was the bug, not the harness's problem: the
    # run helpers only ever SET the variable, so the primary slot inherited
    # whatever the environment held and a run dispatched from a fallback turn
    # re-ran the account that had just refused. The suite was green because
    # the harness removed the variable the shipping code failed to remove.
    # The code unsets it now, and the cases below preset it on purpose.
    local -a envs=()
    while [ $# -gt 1 ]; do envs+=("$1"); shift; done
    # Every session has its OWN stream log now (one shared file is how a wake
    # used to strand a desktop turn's TTS streamer past EOF); pin this one to
    # the file the cases write, or the predicates read a log that never exists.
    # ACCOUNT_DEFAULT_FILE is pinned to the scratch dir: the real one is
    # durable in ~/.local/share, and a test that moved the LIVE default would
    # silently re-route every real session's login.
    # NOTICE_STATE_DIR is pinned too: claude_generate ends in notice_own_writes,
    # which copies the stream into ~/.local/state/deskcrab/streams and PRUNES
    # that directory to NOTICE_STREAM_KEEP — a test run would delete real
    # forensic streams and append to her live declaration log.
    DESKCRAB_CONF="$T/conf" DESKCRAB_STATE_PREFIX="$T/state" \
        DESKCRAB_STREAMLOG="${DESKCRAB_STREAMLOG:-$T/state-debug.log}" \
        ACCOUNT_DEFAULT_FILE="$T/state-account-default" \
        NOTICE_STATE_DIR="$T/notice" WAKES_DIR="$T/wakes" \
        JOBS_DIR="$T/jobs" DAY_JOURNAL_DIR="$T/journal" DESKCRAB_NO_DISPATCH=1 \
        env ${envs[@]+"${envs[@]}"} \
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

echo "claude_fallback_dirs — the chain parses however it is written:"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="/a:/b:/c" 'claude_fallback_dirs | tr "\n" ","')"
[ "$out" = "/a,/b,/c," ] && ok "colon-separated" || fail "colons must split the chain" "$out"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="/a  /b" 'claude_fallback_dirs | tr "\n" ","')"
[ "$out" = "/a,/b," ] && ok "space-separated, runs collapsed" || fail "whitespace must split the chain" "$out"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="/only" 'claude_fallback_dirs | tr "\n" ","')"
[ "$out" = "/only," ] && ok "a single entry is still a single entry" || fail "one dir must survive unchanged" "$out"
out="$(run 'claude_fallback_dirs | wc -l')"
[ "$out" = 0 ] && ok "unset is an empty chain, not one empty dir" || fail "unset must yield nothing" "$out"

echo "claude_limit_fallback_due — retry exactly when a fallback can help:"
# DEBUGLOG is per-pid, so each case copies its fixture into place from inside
# the sourced instance rather than guessing the name from outside.
refusal_stream > "$T/fix-refusal"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'cp "'"$T"'/fix-refusal" "$DEBUGLOG"; claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = DUE ] && ok "limit refusal + configured fallback is due" || fail "should be due" "$out"

out="$(run 'cp "'"$T"'/fix-refusal" "$DEBUGLOG"; claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = no ] && ok "no fallback configured, no retry" || fail "must not be due without a fallback" "$out"

printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Invalid API key"}]}}' \
    '{"type":"result","is_error":true,"result":"Invalid API key"}' > "$T/fix-auth"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'cp "'"$T"'/fix-auth" "$DEBUGLOG"; claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = no ] && ok "an auth failure is not retried" || fail "auth failures must surface as themselves" "$out"

# 2026-08-07: four builder jobs in a row died on this single line while another
# login answered seconds later. It wears an auth failure's clothes, but a login
# belongs to ONE account, so it must move the chain along like any refusal.
printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]}}' \
    '{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}' > "$T/fix-nologin"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'cp "'"$T"'/fix-nologin" "$DEBUGLOG"; claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = DUE ] && ok "a not-logged-in login is walked past, not died on" \
    || fail "one dead login must not strand the whole chain" "$out"

reply_stream "a genuine answer" > "$T/fix-reply"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'cp "'"$T"'/fix-reply" "$DEBUGLOG"; claude_limit_fallback_due && echo DUE || echo no')"
[ "$out" = no ] && ok "a genuine reply is never retried" || fail "real output must not retry" "$out"

echo "claude_accounts — the default is a position that moves, never a timer:"
ACCTS='claude_accounts | tr "\n" ","'
rm -f "$T/state-account-default"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" "$ACCTS")"
[ "$out" = "-,$T/fb," ] && ok "no record: the primary leads" || fail "the primary must lead untouched" "$out"

out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'claude_limit_record "" "out of usage credits"; '"$ACCTS")"
[ "$out" = "$T/fb,-," ] && ok "primary refused: the fallback IS the default now" \
    || fail "a refusal must move the default" "$out"

# No timer anywhere: a default that moved long ago has not crept back, and the
# whole chain is still offered — rotated, with the primary last, so a run that
# exhausts the newer logins still wraps around rather than running nothing.
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'printf "%s\t1\tmoved long ago\n" "'"$T"'/fb" > "$ACCOUNT_DEFAULT_FILE"; '"$ACCTS")"
[ "$out" = "$T/fb,-," ] && ok "the default NEVER reverts on age" \
    || fail "no expiry may hand the chain back to the primary" "$out"

# Written by one session, read by the next: the pointer is a file, not memory.
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" "$ACCTS")"
[ "$out" = "$T/fb,-," ] && ok "the default is durable across sessions" \
    || fail "the pointer must persist" "$out"

# Refusing the LAST account wraps the default back to the primary.
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'claude_limit_record "'"$T"'/fb" x; '"$ACCTS")"
[ "$out" = "-,$T/fb," ] && ok "the end of the chain wraps to the primary" \
    || fail "the rotation must wrap" "$out"

# Three accounts, two refusals: the default advances one position per refusal.
rm -f "$T/state-account-default"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb:$T/fb2" 'claude_limit_record "" x; claude_limit_record "'"$T"'/fb" x; '"$ACCTS")"
[ "$out" = "$T/fb2,-,$T/fb," ] && ok "two refusals land the default on the third account" \
    || fail "each refusal must advance one position" "$out"

# A stored default the conf no longer names resets to the primary.
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" 'printf "%s\t1\tgone\n" /no-such-dir > "$ACCOUNT_DEFAULT_FILE"; '"$ACCTS")"
[ "$out" = "-,$T/fb," ] && ok "a default outside the chain resets to the primary" \
    || fail "a stale pointer must not wedge the chain" "$out"

out="$(run 'claude_limit_record "" x; '"$ACCTS")"
[ "$out" = "-," ] && ok "no fallback configured: the one account still runs" \
    || fail "a lone account must keep running" "$out"
rm -f "$T/state-account-default"

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
printf '%s\n' "job-runner: login refused (limit) — retrying via CLAUDE_CONFIG_DIR=/x" > "$T/sig"
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

echo "tts-streamer — a refusal never reaches the speakers, full stop:"
# The streamer is told nothing about the chain: it cannot know how many
# accounts this turn will really try. Every refusal is held off the speakers,
# every limit-error result is ridden through, and a chain that ends with no
# genuine speech ends SILENT from this process — the outage is the caller's
# to notify, never hers to say, and the speech log keeps the words for the
# record.
mkdir -p "$T/bin"
printf '#!/bin/bash\ncat >> "%s/spoken"\n' "$T" > "$T/bin/piper-tts"
printf '#!/bin/bash\ncat > /dev/null\n' > "$T/bin/aplay"
chmod +x "$T/bin/piper-tts" "$T/bin/aplay"
LIMIT_RE_DEFAULT="$(run 'printf %s "$CLAUDE_LIMIT_RE"')"
tts() { # <log> — run the streamer over a prewritten stream log
    PATH="$T/bin:$PATH" DESKCRAB_DEBUGLOG="$1" DESKCRAB_PIPER_VOICE=/x \
        DESKCRAB_CLAUDE_LIMIT_RE="$LIMIT_RE_DEFAULT" \
        DESKCRAB_SPEECH_LOG="$T/speechlog" \
        timeout 20 "$REPO_DIR/lib/tts-streamer" 2>/dev/null
}

rm -f "$T/spoken"
{ refusal_stream; reply_stream "HELLO FROM FALLBACK"; printf '{"type":"result"}\n'; } > "$T/tts.log"
tts "$T/tts.log"
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"HELLO FROM FALLBACK"*) ok "the retried reply is spoken" ;;
    *) fail "the retry's words must reach the voice" "$(cat "$T/spoken" 2>/dev/null)" ;; esac
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"out of usage credits"*) fail "the refusal must not be voiced when a retry answered" "$(cat "$T/spoken")" ;;
    *) ok "the refusal stays unspoken" ;; esac

# A lone refusal with no retry behind it is still NOT spoken: the caller
# recognises the limit-shaped stream and notifies, and the streamer's job is
# only to keep the outage out of her voice while leaving a written trace.
rm -f "$T/spoken" "$T/speechlog"
{ refusal_stream; printf '{"type":"result"}\n'; } > "$T/tts1.log"
tts "$T/tts1.log"
n="$(grep -c "out of usage credits" "$T/spoken" 2>/dev/null)"
[ "${n:-0}" = 0 ] && ok "a lone refusal is never voiced" \
    || fail "the outage must not be in her voice" "spoken ${n:-0} times"
grep -q "out of usage credits" "$T/speechlog" 2>/dev/null \
    && ok "…and the speech log keeps the words" \
    || fail "the held refusal must be recorded" "$(cat "$T/speechlog" 2>/dev/null || echo empty)"

rm -f "$T/spoken" "$T/speechlog"
{ refusal_stream; refusal_stream; printf '{"type":"result"}\n'; } > "$T/tts2.log"
tts "$T/tts2.log"
n="$(grep -c "out of usage credits" "$T/spoken" 2>/dev/null)"
[ "${n:-0}" = 0 ] && ok "both logins refusing is still not voiced" \
    || fail "no number of refusals may be spoken" "spoken $n times"

# However long the chain runs, refusals mid-file are never voiced and the
# reply that finally arrives is.
rm -f "$T/spoken"
{ refusal_stream; refusal_stream; reply_stream "HELLO FROM THE THIRD"; printf '{"type":"result"}\n'; } > "$T/tts3.log"
tts "$T/tts3.log"
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"HELLO FROM THE THIRD"*) ok "two refusals ridden through, the third account is heard" ;;
    *) fail "a two-account chain must reach the reply" "$(cat "$T/spoken" 2>/dev/null)" ;; esac
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"out of usage credits"*) fail "no refusal may be voiced once an account answered" "$(cat "$T/spoken")" ;;
    *) ok "neither refusal is voiced mid-chain" ;; esac

# …and a wholly spent chain ends silent from the streamer too — the caller's
# notification is the announcement, never her speakers.
rm -f "$T/spoken" "$T/speechlog"
{ refusal_stream; refusal_stream; refusal_stream; printf '{"type":"result"}\n'; } > "$T/tts4.log"
tts "$T/tts4.log"
n="$(grep -c "out of usage credits" "$T/spoken" 2>/dev/null)"
[ "${n:-0}" = 0 ] && ok "a spent chain is never voiced" \
    || fail "a spent chain must stay out of her voice" "spoken $n times"

# Her OWN words are never pattern-matched against the limit signature: a
# genuine reply that QUOTES a limit phrase is not a refusal, and gagging it
# mid-sentence is exactly the tongue-cutting the speech path forbids. Only
# the CLI's synthetic marker names a refusal.
rm -f "$T/spoken"
{ reply_stream "He asked why. You are out of usage credits, the CLI said, and I told him so."; printf '{"type":"result"}\n'; } > "$T/tts5.log"
tts "$T/tts5.log"
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"I told him so"*) ok "a reply quoting the limit phrase is spoken in full" ;;
    *) fail "quoting an outage must not be gagged as one" "$(cat "$T/spoken" 2>/dev/null)" ;; esac

echo "wake_claude_run_chain — the wake walks the logins in order:"
# A stream-mode stub: every login refuses except the one named in STUB_OK_DIR
# (unset = only the first fallback works). The streams are prewritten fixtures
# — the refusal text holds an apostrophe, which no quoting style survives being
# embedded in a generated script.
refusal_stream > "$T/fixture-refusal"
reply_stream "WAKE FALLBACK REPLY" > "$T/fixture-reply"
cat > "$T/claude-stream" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-primary}" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "\${STUB_OK_DIR:-$T/fb}" ]; then
    cat "$T/fixture-reply"
    exit 0
fi
cat "$T/fixture-refusal"
exit 1
EOF
chmod +x "$T/claude-stream"
rm -f "$T/calls" "$T/state-account-default"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE FALLBACK REPLY" ] && ok "wake run retries and extracts the real reply" \
    || fail "wake retry should yield the fallback's reply" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:primary
CALL:$T/fb" ] && ok "exactly two calls: primary then fallback" \
    || fail "call order must be primary, then fallback" "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"
[ "$(cut -f1 "$T/state-account-default" 2>/dev/null)" = "$T/fb" ] \
    && ok "the refusal makes the fallback the default" \
    || fail "detection must move the default" "$(cat "$T/state-account-default" 2>/dev/null || echo "no record")"

# Same sequence again with the default moved: no probe, one call, straight
# to the account that answers.
rm -f "$T/calls"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE FALLBACK REPLY" ] && ok "moved default: the reply still arrives" \
    || fail "the rotated chain should reply" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$T/fb" ] && ok "moved default: one call, no doomed probe" \
    || fail "the default must lead the walk" "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"
rm -f "$T/state-account-default"

# The whole point of a chain: the second fallback is reached when the first is
# out too, and the accounts are tried left to right.
rm -f "$T/calls" "$T/state-account-default"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb:$T/fb2" STUB_OK_DIR="$T/fb2" \
    CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE FALLBACK REPLY" ] && ok "a third subscription answers when the first two are out" \
    || fail "the chain must reach the last account" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:primary
CALL:$T/fb
CALL:$T/fb2" ] && ok "three calls, in the configured order" \
    || fail "the chain must be walked left to right" "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"

# A spent chain stops. Nothing here may loop back to an account already tried.
rm -f "$T/calls" "$T/state-account-default"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/fb:$T/fb2" STUB_OK_DIR=/never \
    CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    wake_stream_failed && echo FAILED')"
[ "$out" = FAILED ] && ok "every account out still reports a failed wake" \
    || fail "a wholly refused wake must read as failed" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 3 ] && ok "each login is tried exactly once" || fail "must try each login once" "$n calls"
[ "$(cut -f1 "$T/state-account-default" 2>/dev/null)" = "-" ] \
    && ok "a fully spent chain wraps the default back to the primary" \
    || fail "the rotation must wrap at the end" "$(cut -f1 "$T/state-account-default" 2>/dev/null)"

echo "job-runner — a limited primary is retried, not recorded blocked:"
# Same scaffold as test_job_block.sh: copied runner, symlinked common.sh, fake
# crab, isolated journal — nothing here may reach the live instance.
mkdir -p "$T/repo/lib" "$T/jobs"
cp "$REPO_DIR/lib/job-runner" "$T/repo/lib/job-runner"
ln -sf "$REPO_DIR/lib/common.sh" "$T/repo/lib/common.sh"
chmod +x "$T/repo/lib/job-runner"
printf '#!/bin/bash\necho "WAKE: $*" >> "%s/wakes"\n' "$T" > "$T/repo/crab"
chmod +x "$T/repo/crab"
# A plain-mode stub: refuses on the primary login; on a fallback it builds —
# unless STUB_FALLBACK_FAILS says every other account is out too, or STUB_OK_DIR
# names the one login in the chain that still has credit.
cat > "$T/claude-plain" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-primary}" >> "$T/calls"
if [ -n "\${STUB_OK_DIR:-}" ]; then
    if [ "\${CLAUDE_CONFIG_DIR:-}" = "\$STUB_OK_DIR" ]; then echo "BUILT OK"; exit 0; fi
    echo "$REFUSAL"
    exit 1
fi
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
        ACCOUNT_DEFAULT_FILE="$T/state-account-default" \
        NOTICE_STATE_DIR="$T/notice" WAKES_DIR="$T/wakes" \
        DAY_JOURNAL_DIR="$T/journal" CLAUDE_BIN="$T/claude-plain" \
        env "$@" "$T/repo/lib/job-runner" "$id" "$T" >/dev/null 2>&1
}

rm -f "$T/calls" "$T/jobs/blocked" "$T/state-account-default"
run_runner fbworks CLAUDE_FALLBACK_CONFIG_DIR="$T/fb"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/fbworks.json" state)"
[ "$out" = finished ] && ok "fallback succeeds: the job is finished, not blocked" || fail "should finish via the fallback" "$out"
case "$(cat "$T/jobs/fbworks.log" 2>/dev/null)" in
    *"retrying via CLAUDE_CONFIG_DIR="*) ok "the retry is recorded in the job log" ;;
    *) fail "the log must say a retry happened" "$(cat "$T/jobs/fbworks.log" 2>/dev/null | head -n2)" ;; esac
[ ! -e "$T/jobs/blocked" ] && ok "no block marker when the fallback carried the job" \
    || fail "a completed job must not hold future dispatches" "$(cat "$T/jobs/blocked")"
[ "$(cut -f1 "$T/state-account-default" 2>/dev/null)" = "$T/fb" ] \
    && ok "the job's refusal makes the fallback the default" \
    || fail "job detection must move the default" "$(cat "$T/state-account-default" 2>/dev/null || echo "no record")"

# Default still moved from the last case: the next job leads with the account
# that answered and never probes the one that refused.
rm -f "$T/calls" "$T/jobs/blocked"
run_runner defmoved CLAUDE_FALLBACK_CONFIG_DIR="$T/fb"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/defmoved.json" state)"
[ "$out" = finished ] && ok "moved default: the job finishes on the fallback" || fail "moved-default job should finish" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 1 ] && ok "moved default: one call, no primary probe" || fail "the default must lead" "$n calls"
case "$(cat "$T/jobs/defmoved.log" 2>/dev/null)" in
    *"default login is"*) ok "the leading login is recorded in the job log" ;;
    *) fail "the log must name the login that led" "$(head -n1 "$T/jobs/defmoved.log" 2>/dev/null)" ;; esac

rm -f "$T/calls" "$T/jobs/blocked" "$T/state-account-default"
run_runner bothout CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" STUB_FALLBACK_FAILS=1
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/bothout.json" state)"
[ "$out" = blocked ] && ok "both logins refusing is blocked, as before" || fail "should block when the fallback is out too" "$out"
[ -e "$T/jobs/blocked" ] && ok "the block marker is written for a double refusal" \
    || fail "double refusal must hold dispatches" "no marker"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 2 ] && ok "exactly one retry — never a third attempt" || fail "must try each login once" "$n calls"

rm -f "$T/calls" "$T/jobs/blocked" "$T/state-account-default"
run_runner chain CLAUDE_FALLBACK_CONFIG_DIR="$T/fb:$T/fb2" STUB_OK_DIR="$T/fb2"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/chain.json" state)"
[ "$out" = finished ] && ok "a job carried by the third subscription finishes" \
    || fail "the runner must walk the whole chain" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 3 ] && ok "three attempts: primary, then each fallback in turn" \
    || fail "every configured login must get one attempt" "$n calls"
[ ! -e "$T/jobs/blocked" ] && ok "no block marker when a later account carried the job" \
    || fail "a completed job must not hold future dispatches" "$(cat "$T/jobs/blocked")"

rm -f "$T/calls" "$T/jobs/blocked" "$T/state-account-default"
run_runner nofb
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/nofb.json" state)"
[ "$out" = blocked ] && ok "no fallback configured: blocked exactly as before" || fail "unconfigured must keep old behaviour" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 1 ] && ok "no fallback: a single attempt" || fail "must not retry without a fallback" "$n calls"

echo "a wholly-refused desk turn is notified — never spoken, never conversed:"
# The measured failure: with every login out, extract_response reports the
# refusal as the reply, it landed in the conversation as her words, and the
# never-silent guard read the streamer's empty receipt as a broken speech
# path and spoke the refusal aloud. Now the turn recognises the limit-shaped
# stream, keeps the refusal out of the conversation and off the speakers,
# and the notification carries the outage.
printf '#!/bin/bash\nprintf "NOTIFY:%%s\\n" "$*" >> "%s/notifies"\n' "$T" > "$T/bin/notify-send"
chmod +x "$T/bin/notify-send"
rm -f "$T/spoken" "$T/notifies" "$T/state-account-default" "$T/state-convo.txt"
run PATH="$T/bin:$PATH" CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" STUB_OK_DIR=/never \
    CLAUDE_BIN="$T/claude-stream" LAST_ORIGIN_FILE="$T/state-last-origin" \
    'run_claude_and_respond "hello there" >/dev/null' >/dev/null 2>&1
grep -q "hello there" "$T/state-convo.txt" 2>/dev/null \
    && ok "the user's words still enter the conversation" \
    || fail "the user turn must be recorded" "$(cat "$T/state-convo.txt" 2>/dev/null || echo missing)"
grep -q "usage credits" "$T/state-convo.txt" 2>/dev/null \
    && fail "the refusal entered the conversation as her reply" "$(grep "usage credits" "$T/state-convo.txt")" \
    || ok "the refusal never enters the conversation"
grep -q "usage credits" "$T/spoken" 2>/dev/null \
    && fail "the refusal reached the speakers" "$(cat "$T/spoken")" \
    || ok "the refusal never reaches the speakers"
grep -qi "limit" "$T/notifies" 2>/dev/null \
    && ok "the notification carries the outage instead" \
    || fail "the outage must be notified" "$(cat "$T/notifies" 2>/dev/null || echo "no notification")"

echo
echo "an inherited CLAUDE_CONFIG_DIR is not the primary login:"
# The chain's first slot is "no override" — which only means the primary if
# the variable is ABSENT. It is exported into a Claude Code session's Bash-tool
# environment, and job_start forwards it deliberately, so a run dispatched from
# a turn already on a fallback used to walk the chain with its first attempt
# pointed straight back at the login that had just refused: three accounts
# behaving as two, and the true primary never tried at all. Every case here
# presets CLAUDE_CONFIG_DIR to a dry account and demands a CALL:primary.
mkdir -p "$T/dry"

rm -f "$T/calls" "$T/state-account-default"
out="$(run CLAUDE_CONFIG_DIR="$T/dry" CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" \
    CLAUDE_BIN="$T/claude-stream" 'claude_generate "hello" low')"
[ "$out" = "WAKE FALLBACK REPLY" ] && ok "desk/phone turn: the fallback still answers" \
    || fail "the turn must reach the account that answers" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:primary
CALL:$T/fb" ] && ok "desk/phone turn (_generate_claude_run): the primary is actually called" \
    || fail "an inherited login must be unset for the primary slot" \
            "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"

rm -f "$T/calls" "$T/state-account-default"
out="$(run CLAUDE_CONFIG_DIR="$T/dry" CLAUDE_FALLBACK_CONFIG_DIR="$T/fb" \
    CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE FALLBACK REPLY" ] && ok "wake: the fallback still answers" \
    || fail "the wake must reach the account that answers" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:primary
CALL:$T/fb" ] && ok "wake (_wake_claude_run): the primary is actually called" \
    || fail "an inherited login must be unset for the primary slot" \
            "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"

# The job path is where this bites hardest: a builder dispatched mid-turn
# inherits the turn's login by design, so without the unset its "first
# attempt" runs on the account the turn was already using — and the plain
# stub below builds happily there, so nothing looks wrong at all.
rm -f "$T/calls" "$T/jobs/blocked" "$T/state-account-default"
run_runner inherited CLAUDE_CONFIG_DIR="$T/dry" CLAUDE_FALLBACK_CONFIG_DIR="$T/fb"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/inherited.json" state)"
[ "$out" = finished ] && ok "job: the fallback still carries it" \
    || fail "the job must finish on the fallback" "$out"
[ "$(head -n1 "$T/calls" 2>/dev/null)" = "CALL:primary" ] \
    && ok "job (lib/job-runner): the first attempt is the primary, not the inherited login" \
    || fail "an inherited login must be unset for the primary slot" \
            "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"

# And the harness may not paper over it again: a test that strips the variable
# is testing an environment the shipping code never runs in. The pattern is
# assembled rather than written, so this assertion is not its own hit.
strip="env -u CLAUDE_CONFIG""_DIR"
hits="$(grep -cF "$strip" "$(readlink -f "$0")")"
[ "$hits" = 0 ] && ok "the harness no longer strips the variable the code must strip itself" \
    || fail "the suite must not remove CLAUDE_CONFIG_DIR on the code's behalf" "$hits uses"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
