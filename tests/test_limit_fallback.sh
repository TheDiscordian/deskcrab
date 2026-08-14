#!/bin/bash
# Tests for the flat numbered account list (specs/account-fallback.md): the
# list parsed from the configuration, the current index advancing one account
# per refusal, cooldown-skip, the wrap, every-account-cooling offering the
# soonest to expire, the numbered messages, the claude_limit_retry_due
# predicate, the wake-path walk, extract-response on a combined refusal+reply
# log, the TTS streamer riding through a refusal, the mid-flight limit CUT and
# its ride to the next account, and the job-runner's attempts along the list.
# Run: bash tests/test_limit_fallback.sh
#
# The gap the walk was written for: on 2026-08-07 one account ran out of usage
# credits mid-morning — every wake failed, two jobs were recorded "blocked",
# and a second, idle subscription sat on the same machine the whole time. The
# walk tries the next account before giving anything up.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-limitfb.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — got [$2]"; }

# Account 1 is $HOME/.claude by definition — the stub CLI never opens it, so
# the real path is safe to expect in call records.
A1="$HOME/.claude"

# A scratch conf so the live one's settings (including any real account list)
# never reach these cases; the accounts under test are passed per-case in
# the environment, which the config's ${VAR:-} defaults let through.
cat > "$T/conf" <<EOF
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
PROJECT_DIR="$T"
EOF

run() { # [ENV=val ...] <shell body> — sources common.sh in a scratch instance.
    # Every argument but the last is an env assignment; the last is the body.
    # CLAUDE_CONFIG_DIR is deliberately NOT stripped here. The walk addresses
    # every account explicitly (rule 3), so an inherited value must be inert —
    # and a harness that removed it would be testing an environment the
    # shipping code never runs in.
    local -a envs=()
    while [ $# -gt 1 ]; do envs+=("$1"); shift; done
    # Every session has its OWN stream log now (one shared file is how a wake
    # used to strand a desktop turn's TTS streamer past EOF); pin this one to
    # the file the cases write, or the predicates read a log that never exists.
    # ACCOUNT_STATE_FILE is pinned to the scratch dir: the real one is durable
    # in ~/.local/share, and a test that cooled the LIVE accounts would
    # silently re-route every real session's login.
    # NOTICE_STATE_DIR is pinned too: claude_generate ends in notice_own_writes,
    # which copies the stream into ~/.local/state/deskcrab/streams and PRUNES
    # that directory to NOTICE_STREAM_KEEP — a test run would delete real
    # forensic streams and append to her live declaration log.
    # COCOON_BWRAP is pinned to the pass-through wrap (test-harness rule 3a):
    # the wake-walk cases below launch the stub CLI through the real cocoon
    # otherwise, and from inside an already-cocooned session nested bwrap dies
    # before it can exec — the stub is never called and every walk case fails
    # for a reason that is the invoking environment's, not the accounts'.
    PATH="$T/bin:$PATH" \
        DESKCRAB_CONF="$T/conf" DESKCRAB_STATE_PREFIX="$T/state" \
        DESKCRAB_STREAMLOG="${DESKCRAB_STREAMLOG:-$T/state-debug.log}" \
        ACCOUNT_STATE_FILE="$T/account-state" \
        COCOON_BWRAP="$REPO_DIR/tests/lib/cocoon-passthru" \
        NOTICE_STATE_DIR="$T/notice" WAKES_DIR="$T/wakes" \
        JOBS_DIR="$T/jobs" DAY_JOURNAL_DIR="$T/journal" DESKCRAB_NO_DISPATCH=1 \
        env ${envs[@]+"${envs[@]}"} \
        bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$REPO_DIR" "$1" 2>&1
}

# Desktop tools are stubbed for EVERY sourced instance: this file runs outside
# the sandbox helper, and a swap announce reaching the real notify-send would
# pop a notification on a desk somebody is working at.
mkdir -p "$T/bin"
printf '#!/bin/bash\nprintf "NOTIFY:%%s\\n" "$*" >> "%s/notifies"\n' "$T" > "$T/bin/notify-send"
printf '#!/bin/bash\ncat >> "%s/spoken"\n' "$T" > "$T/bin/piper-tts"
printf '#!/bin/bash\ncat > /dev/null\n' > "$T/bin/aplay"
chmod +x "$T/bin/notify-send" "$T/bin/piper-tts" "$T/bin/aplay"

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

echo "claude_account_list — one flat list, account 1 first, however it is written:"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="/a:/b:/c" 'claude_account_list | tr "\n" ","')"
[ "$out" = "$A1,/a,/b,/c," ] && ok "colon-separated, account 1 leads" || fail "colons must split the list" "$out"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="/a  /b" 'claude_account_list | tr "\n" ","')"
[ "$out" = "$A1,/a,/b," ] && ok "space-separated, runs collapsed" || fail "whitespace must split the list" "$out"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="/a:/a:$A1" 'claude_account_list | tr "\n" ","')"
[ "$out" = "$A1,/a," ] && ok "duplicates are dropped, account 1's dir included" || fail "the list must dedupe" "$out"
out="$(run 'claude_account_list | tr "\n" ","; echo count=$(claude_account_count)')"
[ "$out" = "$A1,count=1" ] && ok "unset is one account, not none" || fail "the lone account must stand" "$out"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="/a:/b" 'claude_account_dir 2; claude_account_number /b')"
[ "$out" = "/a
3" ] && ok "numbers and dirs translate both ways" || fail "number/dir translation broke" "$out"

echo "claude_limit_retry_due — retry exactly when another account can help:"
# DEBUGLOG is per-pid, so each case copies its fixture into place from inside
# the sourced instance rather than guessing the name from outside.
refusal_stream > "$T/fix-refusal"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'cp "'"$T"'/fix-refusal" "$DEBUGLOG"; claude_limit_retry_due && echo DUE || echo no')"
[ "$out" = DUE ] && ok "limit refusal + a second account is due" || fail "should be due" "$out"

out="$(run 'cp "'"$T"'/fix-refusal" "$DEBUGLOG"; claude_limit_retry_due && echo DUE || echo no')"
[ "$out" = no ] && ok "one account, no retry" || fail "must not be due with one account" "$out"

printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Invalid API key"}]}}' \
    '{"type":"result","is_error":true,"result":"Invalid API key"}' > "$T/fix-auth"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'cp "'"$T"'/fix-auth" "$DEBUGLOG"; claude_limit_retry_due && echo DUE || echo no')"
[ "$out" = no ] && ok "an auth failure is not retried" || fail "auth failures must surface as themselves" "$out"

# 2026-08-07: four builder jobs in a row died on this single line while another
# login answered seconds later. It wears an auth failure's clothes, but a login
# belongs to ONE account, so it must move the walk along like any refusal.
printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Not logged in · Please run /login"}]}}' \
    '{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}' > "$T/fix-nologin"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'cp "'"$T"'/fix-nologin" "$DEBUGLOG"; claude_limit_retry_due && echo DUE || echo no')"
[ "$out" = DUE ] && ok "a not-logged-in login is walked past, not died on" \
    || fail "one dead login must not strand the whole list" "$out"

# 2026-08-11: two builder jobs died with exit 1 and this single line — a
# per-model limit, worded to match nothing then in the signature — so neither
# judgement moved the chain and both runs were reported as ordinary build
# failures with no work attempted. The exact observed wording, verbatim.
MODEL_LIMIT="You've reached your Fable 5 limit. Run /usage-credits to continue or switch models with /model."
printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"'"$MODEL_LIMIT"'"}]}}' \
    '{"type":"result","is_error":true,"result":"'"$MODEL_LIMIT"'"}' > "$T/fix-modellimit"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'cp "'"$T"'/fix-modellimit" "$DEBUGLOG"; claude_limit_retry_due && echo DUE || echo no')"
[ "$out" = DUE ] && ok "the model-limit wording is judged a refusal, and due" \
    || fail "the model-limit line must be walked past, not died on" "$out"

reply_stream "a genuine answer" > "$T/fix-reply"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'cp "'"$T"'/fix-reply" "$DEBUGLOG"; claude_limit_retry_due && echo DUE || echo no')"
[ "$out" = no ] && ok "a genuine reply is never retried" || fail "real output must not retry" "$out"

echo "the selection — current index, cooldown-skip, wrap, never empty:"
WALK='claude_accounts | tr "\n" ","'
rm -f "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" "$WALK")"
[ "$out" = "1,2,3," ] && ok "no state: account 1 answers, the whole list follows" \
    || fail "a clean state must lead with account 1" "$out"

# (b) of the contract: account 1 refuses, the state advances to account 2, and
# a NEW run starts at 2 — never back at 1, which is now cooling.
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'claude_limit_record 1 "Session limit reached - resets 3am"; '"$WALK")"
[ "$out" = "2,3," ] && ok "account 1 refused: account 2 answers and 1 is skipped" \
    || fail "a refusal must advance the current and cool the refuser" "$out"

# Written by one session, read by the next: the state is a file, not memory.
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'claude_account_pick')"
[ "$out" = "2" ] && ok "a NEW run picks account 2, durably" \
    || fail "the current must persist across sessions" "$out"

# The state file names the account by number AND dir, and says why it moved.
out="$(cat "$T/account-state")"
case "$out" in
    *"current	2	$T/two"*"account 1 is over its limit (session)"*) ok "the state file records current=2 and the numbered reason" ;;
    *) fail "the state file must carry number, dir, and reason" "$out" ;; esac
case "$out" in
    *"cooldown	1	$A1"*) ok "…and account 1's cooldown, by number and dir" ;;
    *) fail "the refused account must carry a cooldown record" "$out" ;; esac

# Cooldown lengths follow the refusal kind: a session limit cools ~5h, a
# credits-shaped stop ~24h, both knobs.
now=$(date +%s)
until1="$(awk -F'\t' '$1 == "cooldown" && $2 == 1 {print $4}' "$T/account-state")"
d=$(( until1 - now ))
[ "$d" -gt 17700 ] && [ "$d" -le 18000 ] && ok "a session refusal cools for ACCOUNT_COOLDOWN_SESSION (~5h: ${d}s)" \
    || fail "session cooldown must be ~18000s" "${d}s"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'claude_limit_record 2 "You are out of usage credits"; claude_account_pick')"
[ "$out" = "3" ] && ok "account 2 refused too: account 3 answers" || fail "the second refusal must advance again" "$out"
until2="$(awk -F'\t' '$1 == "cooldown" && $2 == 2 {print $4}' "$T/account-state")"
d=$(( until2 - now ))
[ "$d" -gt 86100 ] && [ "$d" -le 86400 ] && ok "a credits refusal cools for ACCOUNT_COOLDOWN_CREDITS (~24h: ${d}s)" \
    || fail "credits cooldown must be ~86400s" "${d}s"

# The shorter knob is a knob.
rm -f "$T/account-state"
run ACCOUNT_COOLDOWN_SESSION=60 CLAUDE_FALLBACK_CONFIG_DIR="$T/two" \
    'claude_limit_record 1 "Session limit reached"' >/dev/null
until1="$(awk -F'\t' '$1 == "cooldown" && $2 == 1 {print $4}' "$T/account-state")"
d=$(( until1 - $(date +%s) ))
[ "$d" -gt 0 ] && [ "$d" -le 60 ] && ok "the cooldown length is configurable (${d}s under a 60s knob)" \
    || fail "ACCOUNT_COOLDOWN_SESSION must be honoured" "${d}s"

# An EXPIRED cooldown makes the account selectable again — but the current
# does not switch back to it: it waits to be reached by a refusal walk.
rm -f "$T/account-state"
printf 'cooldown\t1\t%s\t%s\tsession\ncurrent\t2\t%s\t1\tx\n' \
    "$A1" "$(( $(date +%s) - 5 ))" "$T/two" > "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" "$WALK")"
[ "$out" = "2,3,1," ] && ok "an expired cooldown rejoins the walk, behind the current" \
    || fail "expiry must free the account without switching back" "$out"

# The wrap: the current is the LAST account and it refuses while earlier
# accounts are free — the advance wraps to the top of the list.
rm -f "$T/account-state"
printf 'current\t3\t%s\t1\tx\n' "$T/three" > "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'claude_limit_record 3 "Session limit reached"; claude_account_pick')"
[ "$out" = "1" ] && ok "the walk wraps past the end back to account 1" \
    || fail "the advance must wrap" "$out"

# (e): EVERY account cooling — the selection is never empty; the account
# whose cooldown ends soonest answers, alone.
rm -f "$T/account-state"
now=$(date +%s)
printf 'cooldown\t1\t%s\t%s\tcredits\ncooldown\t2\t%s\t%s\tsession\ncooldown\t3\t%s\t%s\tcredits\ncurrent\t2\t%s\t1\tx\n' \
    "$A1" "$(( now + 80000 ))" "$T/two" "$(( now + 3000 ))" \
    "$T/three" "$(( now + 50000 ))" "$T/two" > "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" "$WALK")"
[ "$out" = "2," ] && ok "all cooling: the soonest to expire (account 2) is offered alone" \
    || fail "the selection must never be empty" "$out"

# ...and a refusal landing when everything is cooling still leaves a current.
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'claude_limit_record 2 "Session limit reached"; claude_account_pick')"
[ -n "$out" ] && ok "a refusal with everything cooling still selects (account $out)" \
    || fail "the selection went empty" "(nothing)"

# A stored current the configuration no longer names resets to account 1.
rm -f "$T/account-state"
printf 'current\t9\t/no-such-dir\t1\tgone\n' > "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'claude_account_pick')"
[ "$out" = "1" ] && ok "a current outside the list resets to account 1" \
    || fail "a stale record must not wedge the selection" "$out"

# One account, refused: it cools, and it still answers — there is nowhere
# else to go and the selection is never empty.
rm -f "$T/account-state"
out="$(run 'claude_limit_record 1 x; claude_account_pick')"
[ "$out" = "1" ] && ok "a lone account keeps answering through its own cooldown" \
    || fail "one account must keep running" "$out"
rm -f "$T/account-state"

# Rule 4a, in one line: claude_accounts is NEVER empty, whatever the state.
out="$(run "$WALK")"
[ "$out" = "1," ] && ok "nothing configured at all: the selection still holds account 1" \
    || fail "an unconfigured list must still hold account 1 (rule 4a)" "$out"

echo "the move log and the status line speak in numbers:"
rm -f "$T/account-state" "$T/account-log"
run ACCOUNT_LOG="$T/account-log" CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" \
    'claude_limit_record 1 "Session limit reached"' >/dev/null
out="$(cut -f2,3 "$T/account-log")"
[ "$out" = "1	2" ] && ok "the move log records from 1 to 2, as numbers" \
    || fail "the log must carry the numbers" "$out"
out="$(run ACCOUNT_LOG="$T/account-log" CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'account_state_line')"
case "$out" in
    "Account: account 2 answers next"*) ok "the status line says which number answers next" ;;
    *) fail "the status line must lead with the number" "$out" ;; esac
case "$out" in
    *"account 1 is over its limit"*) ok "…and why the state moved, by number" ;;
    *) fail "the reason must name the refused account by number" "$out" ;; esac
case "$out" in
    *"1 of 3 accounts cooling"*) ok "…and how much of the list is benched" ;;
    *) fail "the cooling count must be on the line" "$out" ;; esac
rm -f "$T/account-state" "$T/account-log"

echo "the shared signature — session-limit wordings match, prose does not:"
for line in \
    "Session limit reached - resets 3am" \
    "You've hit your session limit for Fable 5" \
    "5-hour limit reached" \
    "$MODEL_LIMIT"
do
    printf '%s\n' "$line" > "$T/sig"
    out="$(run 'job_output_blocked "'"$T"'/sig" && echo BLOCKED || echo no')"
    [ "$out" = BLOCKED ] && ok "matches: ${line:0:40}" || fail "should match: ${line:0:40}" "$out"
done
printf '%s\n' "job-runner: account 1 is over its limit — retrying as account 2 (CLAUDE_CONFIG_DIR=/x)" > "$T/sig"
out="$(run 'job_output_blocked "'"$T"'/sig" && echo BLOCKED || echo no')"
[ "$out" = no ] && ok "the runner's own retry marker never matches" || fail "marker must not match the signature" "$out"

echo "extract-response — the refusal never prefixes a real reply:"
{ refusal_stream; reply_stream "RETRY REPLY"; printf '{"type":"result"}\n'; } > "$T/combined.log"
out="$(DESKCRAB_DEBUGLOG="$T/combined.log" "$REPO_DIR/lib/extract-response")"
[ "$out" = "RETRY REPLY" ] && ok "combined log extracts only the reply" || fail "refusal leaked into the reply" "$out"

{ refusal_stream; printf '{"type":"result"}\n'; } > "$T/refonly.log"
out="$(DESKCRAB_DEBUGLOG="$T/refonly.log" "$REPO_DIR/lib/extract-response")"
case "$out" in *"out of usage credits"*) ok "an error-only stream still reports itself" ;;
    *) fail "error-only stream must keep the refusal text" "$out" ;; esac

echo "tts-streamer — a refusal never reaches the speakers, full stop:"
# The streamer is told nothing about the walk: it cannot know how many
# accounts this turn will really try. Every refusal is held off the speakers,
# every limit-error result is ridden through, and a walk that ends with no
# genuine speech ends SILENT from this process — the outage is the caller's
# to notify, never hers to say, and the speech log keeps the words for the
# record.
LIMIT_RE_DEFAULT="$(run 'printf %s "$CLAUDE_LIMIT_RE"')"
tts() { # <log> — run the streamer over a prewritten stream log
    PATH="$T/bin:$PATH" DESKCRAB_DEBUGLOG="$1" DESKCRAB_PIPER_VOICE=/x \
        DESKCRAB_CLAUDE_LIMIT_RE="$LIMIT_RE_DEFAULT" \
        DESKCRAB_SPEECH_LOG="$T/speechlog" \
        timeout 20 "$REPO_DIR/lib/tts-streamer" 2>/dev/null
}

rm -f "$T/spoken"
{ refusal_stream; reply_stream "HELLO FROM THE SECOND"; printf '{"type":"result"}\n'; } > "$T/tts.log"
tts "$T/tts.log"
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"HELLO FROM THE SECOND"*) ok "the retried reply is spoken" ;;
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
[ "${n:-0}" = 0 ] && ok "both accounts refusing is still not voiced" \
    || fail "no number of refusals may be spoken" "spoken $n times"
# Counting to zero proves nothing on its own: a streamer that never started
# says nothing either, and ${n:-0} turns a missing file into the same 0. The
# speech log is the positive half — the words were seen and held.
grep -q "out of usage credits" "$T/speechlog" 2>/dev/null \
    && ok "…and the streamer really ran: both are in the speech log" \
    || fail "the streamer produced nothing at all — silence proves nothing here" \
            "$(cat "$T/speechlog" 2>/dev/null || echo empty)"

# However long the walk runs, refusals mid-file are never voiced and the
# reply that finally arrives is.
rm -f "$T/spoken"
{ refusal_stream; refusal_stream; reply_stream "HELLO FROM THE THIRD"; printf '{"type":"result"}\n'; } > "$T/tts3.log"
tts "$T/tts3.log"
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"HELLO FROM THE THIRD"*) ok "two refusals ridden through, the third account is heard" ;;
    *) fail "a three-account walk must reach the reply" "$(cat "$T/spoken" 2>/dev/null)" ;; esac
case "$(cat "$T/spoken" 2>/dev/null)" in
    *"out of usage credits"*) fail "no refusal may be voiced once an account answered" "$(cat "$T/spoken")" ;;
    *) ok "neither refusal is voiced mid-walk" ;; esac

# …and a wholly spent walk ends silent from the streamer too — the caller's
# notification is the announcement, never her speakers.
rm -f "$T/spoken" "$T/speechlog"
{ refusal_stream; refusal_stream; refusal_stream; printf '{"type":"result"}\n'; } > "$T/tts4.log"
tts "$T/tts4.log"
n="$(grep -c "out of usage credits" "$T/spoken" 2>/dev/null)"
[ "${n:-0}" = 0 ] && ok "a spent walk is never voiced" \
    || fail "a spent walk must stay out of her voice" "spoken $n times"
grep -q "out of usage credits" "$T/speechlog" 2>/dev/null \
    && ok "…and the whole spent walk is in the speech log" \
    || fail "the streamer produced nothing at all — silence proves nothing here" \
            "$(cat "$T/speechlog" 2>/dev/null || echo empty)"

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

echo "claude_stream_limit_cut — a limit that stops a run MID-FLIGHT is a cut:"
# The observed shape (CLI 2.1.219, the wake of 2026-08-11 00:17): genuine tool
# calls, then a synthetic assistant message carrying the limit text, then a
# final result line with is_error and NO type field at all. Heredoc-quoted:
# the refusal text holds an apostrophe.
cat > "$T/fix-cut" <<'FIX'
{"type":"assistant","message":{"model":"claude","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}
{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 1:30am"}]}}
{"is_error":true,"duration_api_ms":31572,"num_turns":9}
FIX
out="$(run 'claude_stream_limit_cut "'"$T"'/fix-cut" || echo NOCUT')"
case "$out" in
    *"hit your session limit"*) ok "the observed 00:17 shape is a cut, and the matched text comes back" ;;
    *) fail "the mid-flight limit must read as a cut" "$out" ;; esac

# Disjoint from the plain refusal, both ways: a cut has genuine output, so it
# is never rule 12's refusal — and a run that never began is never a cut.
out="$(run 'claude_stream_refusal "'"$T"'/fix-cut" >/dev/null && echo REFUSAL || echo no')"
[ "$out" = no ] && ok "a cut is not a refusal — the no-genuine-output rule stands" \
    || fail "genuine output must keep the cut out of claude_stream_refusal" "$out"
out="$(run 'claude_stream_limit_cut "'"$T"'/fix-refusal" && echo CUT || echo no')"
[ "$out" = no ] && ok "a run that never began is a refusal, not a cut" \
    || fail "no genuine output means no cut" "$out"

# A later account answering clears the cut: the stream reads as that answer.
{ cat "$T/fix-cut"; reply_stream "SECOND ACCOUNT CARRIED IT"; } > "$T/fix-cut-reply"
out="$(run 'claude_stream_limit_cut "'"$T"'/fix-cut-reply" && echo CUT || echo no')"
[ "$out" = no ] && ok "a genuine reply after the cut clears it" \
    || fail "an answered stream must never read as a cut" "$out"

# An auth failure mid-run is not a cut: the signature decides, and an invalid
# key would fail every other login too.
cat > "$T/fix-cut-auth" <<'FIX'
{"type":"assistant","message":{"model":"claude","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}
{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Invalid API key"}]}}
{"is_error":true}
FIX
out="$(run 'claude_stream_limit_cut "'"$T"'/fix-cut-auth" && echo CUT || echo no')"
[ "$out" = no ] && ok "a mid-run auth failure is not a cut and surfaces as itself" \
    || fail "only the limit signature may move the walk" "$out"

# Rule 12b, the echo trap: the SUCCESS result event repeats her final text
# block verbatim, so a genuine reply that quotes a limit phrase must not read
# as a cut off the back of its own echo.
cat > "$T/fix-cut-quote" <<'FIX'
{"type":"assistant","message":{"model":"claude","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}
{"type":"assistant","message":{"model":"claude","content":[{"type":"text","text":"The CLI said you have hit your session limit, and I told him so."}]}}
{"type":"result","result":"The CLI said you have hit your session limit, and I told him so."}
FIX
out="$(run 'claude_stream_limit_cut "'"$T"'/fix-cut-quote" && echo CUT || echo no')"
[ "$out" = no ] && ok "a reply quoting the limit phrase is not gagged by its result echo" \
    || fail "the success result's text must never be read for the cut" "$out"

# Rule 14 still holds: each attempt is judged on its own bytes. A cut left by
# attempt one must not condemn attempt two's silent network death.
cat "$T/fix-cut" > "$T/fix-cut-hist"
off="$(wc -c < "$T/fix-cut-hist")"
printf '%s\n' 'curl: (6) could not resolve host' >> "$T/fix-cut-hist"
out="$(run 'claude_stream_limit_cut "'"$T"'/fix-cut-hist" '"$off"' && echo CUT || echo no')"
[ "$out" = no ] && ok "an earlier attempt's cut never marks a later network death" \
    || fail "the offset must scope the judgement" "$out"

# Rule 12d: the type-less is_error line alone reads as the error it is.
printf '%s\n' '{"is_error":true,"duration_api_ms":5}' > "$T/fix-onlyerr"
out="$(run 'DEBUGLOG="'"$T"'/fix-onlyerr"; wake_stream_failed && echo FAILED || echo no')"
[ "$out" = FAILED ] && ok "wake_stream_failed reads the type-less error result" \
    || fail "an error result without its type field must still count" "$out"

echo "wake_claude_run_chain — the wake walks the accounts in order:"
# A stream-mode stub: every account refuses except the one whose config dir
# is named in STUB_OK_DIR (default: account 2's). The streams are prewritten
# fixtures — the refusal text holds an apostrophe, which no quoting style
# survives being embedded in a generated script.
refusal_stream > "$T/fixture-refusal"
reply_stream "WAKE RETRY REPLY" > "$T/fixture-reply"
cat > "$T/claude-stream" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none}" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "\${STUB_OK_DIR:-$T/two}" ]; then
    cat "$T/fixture-reply"
    exit 0
fi
cat "$T/fixture-refusal"
exit 1
EOF
chmod +x "$T/claude-stream"
rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "wake run retries and extracts the real reply" \
    || fail "wake retry should yield account 2's reply" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1
CALL:$T/two" ] && ok "exactly two calls: account 1's dir explicitly, then account 2's" \
    || fail "call order must be account 1 then account 2, both explicit" "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"
[ "$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'claude_account_pick')" = "2" ] \
    && ok "the refusal makes account 2 the current" \
    || fail "detection must advance the current" "$(cat "$T/account-state" 2>/dev/null || echo "no record")"

# Same sequence again with the current moved: no probe, one call, straight
# to the account that answers.
rm -f "$T/calls"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "moved current: the reply still arrives" \
    || fail "the rotated walk should reply" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$T/two" ] && ok "moved current: one call, no doomed probe of a cooling account" \
    || fail "the current must lead the walk and the cooled account be skipped" "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"
rm -f "$T/account-state"

# The whole point of the list: the third account is reached when the first
# two are out, and the accounts are tried in numbered order.
rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" STUB_OK_DIR="$T/three" \
    CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "a third subscription answers when the first two are out" \
    || fail "the walk must reach the last account" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1
CALL:$T/two
CALL:$T/three" ] && ok "three calls, in numbered order" \
    || fail "the list must be walked in order" "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"

# A wholly refused walk stops. Nothing here may loop back to an account
# already tried in this run.
rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" STUB_OK_DIR=/never \
    CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    wake_stream_failed && echo FAILED')"
[ "$out" = FAILED ] && ok "every account out still reports a failed wake" \
    || fail "a wholly refused wake must read as failed" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 3 ] && ok "each account is tried exactly once" || fail "must try each account once" "$n calls"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'claude_account_pick')"
[ -n "$out" ] && ok "a fully spent list still selects an account ($out — soonest to expire)" \
    || fail "the selection must never be empty" "(nothing)"

# Rule 4a's walk half: a walk handed a forcibly emptied account list still
# makes exactly one attempt, on the current account, and names the fall-through
# in its own stream. claude_accounts cannot actually go empty — the cases above
# pin that — so the list is emptied the only way it can be: by overriding the
# function, which is precisely the future edit this guard exists to survive.
# Zero calls here is the 2026-08-11 silent no-op shape: no model, no error,
# exit 0.
rm -f "$T/calls" "$T/account-state"
out="$(run STUB_OK_DIR=/never CLAUDE_BIN="$T/claude-stream" '
    claude_accounts() { :; }
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    echo "attempts=$WAKE_CHAIN_ATTEMPTS"
    grep -c "empty-account-list" "$DEBUGLOG"')"
# The fall-through reads the current straight off the state file — which cannot
# go blank — never the walk's own pick. With no state that is account 1's dir.
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1" ] \
    && ok "an empty list still makes exactly one attempt, on the current account" \
    || fail "an empty list must fall through to one attempt, never zero" \
            "$(cat "$T/calls" 2>/dev/null | tr '\n' ' ')"
case "$out" in
    *"attempts=1"*) ok "and the walk counts it as the one attempt it was" ;;
    *) fail "the fall-through must be counted as an attempt" "$out" ;;
esac
case "$out" in
    *1) ok "and the stream names the fall-through, once" ;;
    *) fail "the empty list must be legible in the stream, not inferred" "$out" ;;
esac

echo "the model-limit wording moves the walk — 2026-08-11's two dead builders:"
# A stub that refuses with the exact observed line on every account but
# account 2: the walk must ride it to the account that answers, and the
# refused account must cool with the current advancing — neither happened
# live.
cat > "$T/claude-modellimit" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none}" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "$T/two" ]; then
    cat "$T/fixture-reply"
    exit 0
fi
cat "$T/fix-modellimit"
exit 1
EOF
chmod +x "$T/claude-modellimit"
rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" CLAUDE_BIN="$T/claude-modellimit" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "the model-limit refusal is ridden to account 2's reply" \
    || fail "the walk must ride the model-limit wording to the next account" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1
CALL:$T/two" ] && ok "model limit: account 1 refused, account 2 tried at once" \
    || fail "the walk must move on the model-limit line" "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"
[ "$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'claude_account_pick')" = "2" ] \
    && ok "the model-limit refusal cools account 1 and moves the current" \
    || fail "the current must move off the account the model limit dried up" \
            "$(cat "$T/account-state" 2>/dev/null || echo "no record")"
rm -f "$T/account-state"

echo "the wake and turn walks ride a cut to the next account:"
# A stream-mode stub that CUTS instead of refusing: every account is cut off
# mid-run except the one named in STUB_OK_DIR (default: account 2).
reply_stream "WAKE RETRY REPLY" > "$T/fixture-cut-reply"
cat > "$T/claude-cutstream" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none}" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "\${STUB_OK_DIR:-$T/two}" ]; then
    cat "$T/fixture-cut-reply"
    exit 0
fi
cat "$T/fix-cut"
exit 1
EOF
chmod +x "$T/claude-cutstream"

rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" CLAUDE_BIN="$T/claude-cutstream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "a cut wake re-runs on the next account and the thought gets said" \
    || fail "the wake walk must ride a cut to the next account" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1
CALL:$T/two" ] && ok "cut wake: account 1 was cut, account 2 was tried at once" \
    || fail "a cut must move the walk exactly as a refusal" "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"
[ "$(awk -F'\t' '$1 == "current" {print $3; exit}' "$T/account-state" 2>/dev/null)" = "$T/two" ] \
    && ok "the cut moves the current like a refusal" \
    || fail "a cut account must be cooled and the current advanced" "$(cat "$T/account-state" 2>/dev/null || echo "no record")"

rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" CLAUDE_BIN="$T/claude-cutstream" \
    'claude_generate "hello" low')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "a cut turn re-runs on the next account and the answer arrives" \
    || fail "the turn walk must ride a cut to the next account" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1
CALL:$T/two" ] && ok "cut turn: account 1 was cut, account 2 was tried at once" \
    || fail "a cut must move the turn walk exactly as a refusal" "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"
rm -f "$T/account-state"

echo "the swap messages carry numbers, and nothing else names an account:"
rm -f "$T/calls" "$T/notifies" "$T/account-state"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" \
    STUB_OK_DIR="$T/three" CLAUDE_BIN="$T/claude-stream" 'claude_generate "hello" low')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "the desk turn rides two refusals to account 3" \
    || fail "the turn must reach the account that answers" "$out"
grep -qF "account 1 is over its limit — switching to account 2" "$T/notifies" \
    && ok 'the notification says "account 1 is over its limit — switching to account 2"' \
    || fail "the swap notification must name both numbers" "$(cat "$T/notifies" 2>/dev/null)"
grep -qF '"detail":"account 1 -> account 2 (limit refusal)"' "$T/state-debug.log" \
    && ok "the stream marker names the numbers too" \
    || fail "the marker must carry the numbers" "$(grep account-swap "$T/state-debug.log")"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" 'account_state_line')"
case "$out" in
    "Account: account 3 answers next"*) ok 'the status line says "account 3 answers next"' ;;
    *) fail "the status line must say the number" "$out" ;; esac
# The concept sweep: nothing this run emitted anywhere a human or she reads —
# notifications, markers, the state file, the move log, the status line —
# names a "primary" or an "fb". The concept is gone, not renamed.
if cat "$T/notifies" "$T/state-debug.log" "$T/account-state" 2>/dev/null \
        | grep -qiwE 'primary|fb'; then
    fail "an emitted string still says primary/fb" \
        "$(cat "$T/notifies" "$T/state-debug.log" "$T/account-state" 2>/dev/null | grep -iwE 'primary|fb')"
else
    ok "no emitted string names a primary or an fb"
fi
if grep -qE 'CLAUDE_PRIMARY_TOKEN|claude_preferred_login|claude_account_confdir|claude_fallback_dirs|ACCOUNT_DEFAULT_FILE' \
    "$REPO_DIR/lib/common.sh" "$REPO_DIR/lib/job-runner" "$REPO_DIR/lib/promise-check" \
    "$REPO_DIR/lib/promise-audit" "$REPO_DIR/lib/backlog-drain" \
    "$REPO_DIR/lib/memory.py" "$REPO_DIR/lib/chess_mover.py"; then
    fail "the old machinery still exists somewhere" \
        "$(grep -lE 'CLAUDE_PRIMARY_TOKEN|claude_preferred_login|ACCOUNT_DEFAULT_FILE' "$REPO_DIR"/lib/* )"
else
    ok "the old token, preferred-login, and default-file machinery is gone"
fi

echo "job-runner — a limited account is retried, not recorded blocked:"
# Same scaffold as test_job_block.sh: copied runner, symlinked common.sh, fake
# crab, isolated journal — nothing here may reach the live instance.
mkdir -p "$T/repo/lib" "$T/jobs"
cp "$REPO_DIR/lib/job-runner" "$T/repo/lib/job-runner"
ln -sf "$REPO_DIR/lib/common.sh" "$T/repo/lib/common.sh"
chmod +x "$T/repo/lib/job-runner"
printf '#!/bin/bash\necho "WAKE: $*" >> "%s/wakes"\n' "$T" > "$T/repo/crab"
chmod +x "$T/repo/crab"
# A plain-mode stub: refuses on account 1 ($A1); on any other account it builds
# — unless STUB_LATER_FAILS says every other account is out too, or STUB_OK_DIR
# names the one login in the list that still has credit.
cat > "$T/claude-plain" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none}" >> "$T/calls"
if [ -n "\${STUB_OK_DIR:-}" ]; then
    if [ "\${CLAUDE_CONFIG_DIR:-}" = "\$STUB_OK_DIR" ]; then echo "BUILT OK"; exit 0; fi
    echo "$REFUSAL"
    exit 1
fi
if [ "\${CLAUDE_CONFIG_DIR:-}" = "$A1" ] || [ -n "\${STUB_LATER_FAILS:-}" ]; then
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
        ACCOUNT_STATE_FILE="$T/account-state" \
        NOTICE_STATE_DIR="$T/notice" WAKES_DIR="$T/wakes" \
        DAY_JOURNAL_DIR="$T/journal" CLAUDE_BIN="$T/claude-plain" \
        env "$@" "$T/repo/lib/job-runner" "$id" "$T" >/dev/null 2>&1
}

rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner retryworks CLAUDE_FALLBACK_CONFIG_DIR="$T/two"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/retryworks.json" state)"
[ "$out" = finished ] && ok "account 2 succeeds: the job is finished, not blocked" || fail "should finish on account 2" "$out"
case "$(cat "$T/jobs/retryworks.log" 2>/dev/null)" in
    *"account 1 is over its limit — retrying as account 2"*) ok "the retry is recorded in the job log, by number" ;;
    *) fail "the log must say a numbered retry happened" "$(cat "$T/jobs/retryworks.log" 2>/dev/null | head -n2)" ;; esac
[ ! -e "$T/jobs/blocked" ] && ok "no block marker when a later account carried the job" \
    || fail "a completed job must not hold future dispatches" "$(cat "$T/jobs/blocked")"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'claude_account_pick')"
[ "$out" = "2" ] && ok "the job's refusal makes account 2 the current" \
    || fail "job detection must advance the current" "$(cat "$T/account-state" 2>/dev/null || echo "no record")"

# Current still moved from the last case: the next job leads with the account
# that answered and never probes the one still cooling.
rm -f "$T/calls" "$T/jobs/blocked"
run_runner curmoved CLAUDE_FALLBACK_CONFIG_DIR="$T/two"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/curmoved.json" state)"
[ "$out" = finished ] && ok "moved current: the job finishes on account 2" || fail "moved-current job should finish" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 1 ] && ok "moved current: one call, no probe of the cooling account" || fail "the current must lead" "$n calls"
case "$(cat "$T/jobs/curmoved.log" 2>/dev/null)" in
    *"building as account 2"*) ok "the leading account is recorded in the job log, by number" ;;
    *) fail "the log must name the account that led" "$(head -n1 "$T/jobs/curmoved.log" 2>/dev/null)" ;; esac

rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner bothout CLAUDE_FALLBACK_CONFIG_DIR="$T/two" STUB_LATER_FAILS=1
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/bothout.json" state)"
[ "$out" = blocked ] && ok "both accounts refusing is blocked, as before" || fail "should block when account 2 is out too" "$out"
[ -e "$T/jobs/blocked" ] && ok "the block marker is written for a double refusal" \
    || fail "double refusal must hold dispatches" "no marker"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 2 ] && ok "exactly one retry — never a third attempt" || fail "must try each account once" "$n calls"

rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner walkall CLAUDE_FALLBACK_CONFIG_DIR="$T/two:$T/three" STUB_OK_DIR="$T/three"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/walkall.json" state)"
[ "$out" = finished ] && ok "a job carried by the third subscription finishes" \
    || fail "the runner must walk the whole list" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 3 ] && ok "three attempts: each account in numbered order" \
    || fail "every configured account must get one attempt" "$n calls"
[ ! -e "$T/jobs/blocked" ] && ok "no block marker when a later account carried the job" \
    || fail "a completed job must not hold future dispatches" "$(cat "$T/jobs/blocked")"

rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner lonely STUB_LATER_FAILS=1
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/lonely.json" state)"
[ "$out" = blocked ] && ok "one account configured: blocked exactly as before" || fail "a lone account must keep old behaviour" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 1 ] && ok "one account: a single attempt" || fail "must not retry with nowhere to go" "$n calls"

echo "job-runner — the model is the dispatch's own, on every attempt (jobs.md rule 5a):"
# The builder's argv is recorded whole: the model must be JOB_MODEL on the
# first attempt AND on the retry after a refusal — the refusal changes the
# account, never the model.
cat > "$T/claude-argv" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none} ARGS:\$*" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "$A1" ]; then
    echo "$REFUSAL"
    exit 1
fi
echo "BUILT OK"
EOF
chmod +x "$T/claude-argv"
rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner modelstays CLAUDE_BIN="$T/claude-argv" CLAUDE_FALLBACK_CONFIG_DIR="$T/two" JOB_MODEL=fable
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/modelstays.json" state)"
[ "$out" = finished ] && ok "the walk finishes on account 2" || fail "the model case must still finish" "$out"
n="$(grep -c "ARGS:.*--model fable" "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 2 ] && ok "both attempts ran --model fable" \
    || fail "every attempt must carry the dispatched model" "$(cat "$T/calls" 2>/dev/null)"
grep "ARGS:" "$T/calls" 2>/dev/null | grep -v -- "--model fable" | grep -q . \
    && fail "an attempt ran on a model the dispatch never named" "$(cat "$T/calls")" \
    || ok "no attempt substituted another model"

# The 2026-08-11 wording on the JOB path: a model-limit refusal is an ACCOUNT
# that ran dry. It rotates the walk exactly like any limit refusal, and the
# model itself is never swapped for a lesser one (jobs.md rule 5a).
cat > "$T/claude-modelplain" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none} ARGS:\$*" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "$A1" ]; then
    echo "$MODEL_LIMIT"
    exit 1
fi
echo "BUILT OK"
EOF
chmod +x "$T/claude-modelplain"
rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner modellimitjob CLAUDE_BIN="$T/claude-modelplain" CLAUDE_FALLBACK_CONFIG_DIR="$T/two" JOB_MODEL=fable
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/modellimitjob.json" state)"
[ "$out" = finished ] && ok "a builder refused with the model-limit line finishes on account 2" \
    || fail "the model-limit wording must rotate the job's account" "$out"
n="$(grep -c "ARGS:.*--model fable" "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 2 ] && ok "…still on --model fable both times: accounts rotate, models never do" \
    || fail "the model-limit refusal must not change the model" "$(cat "$T/calls" 2>/dev/null)"
[ "$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" 'claude_account_pick')" = "2" ] \
    && ok "…and account 1 cools with the current moved, like any refusal" \
    || fail "the model limit must cool the account it dried up" "$(cat "$T/account-state" 2>/dev/null || echo none)"
rm -f "$T/account-state"

echo "job-runner — a build the limit cut off finishes on the next account:"
# Four builders died this way on the night of 2026-08-11: each one journalled
# "failed (exit 1)" with the session-limit line standing as its closing words,
# and no account was ever retried (specs/jobs.md rule 15a). The cut stub reuses
# the stream-mode cut fixture; the runner's judgement reads it the same way.
cat > "$T/claude-cutplain" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none}" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "\${STUB_OK_DIR:-$T/two}" ]; then
    cat "$T/fixture-cut-reply"
    exit 0
fi
cat "$T/fix-cut"
exit 1
EOF
chmod +x "$T/claude-cutplain"

rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner cutjob CLAUDE_BIN="$T/claude-cutplain" CLAUDE_FALLBACK_CONFIG_DIR="$T/two"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/cutjob.json" state)"
[ "$out" = finished ] && ok "a cut build is carried to completion by account 2" \
    || fail "the job walk must ride a cut to the next account" "$out"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 2 ] && ok "cut build: account 1 was cut, account 2 was tried at once" \
    || fail "a cut must move the job walk exactly as a refusal" "$n calls"
[ "$(awk -F'\t' '$1 == "current" {print $3; exit}' "$T/account-state" 2>/dev/null)" = "$T/two" ] \
    && ok "the cut build moves the current" \
    || fail "a cut account must be cooled for the next dispatch" \
            "$(cat "$T/account-state" 2>/dev/null || echo "no record")"

# Every account cut: a build that RAN and was killed is failed, never blocked —
# work was attempted and the log holds it (specs/jobs.md rules 15 and 15a).
rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner allcut CLAUDE_BIN="$T/claude-cutplain" CLAUDE_FALLBACK_CONFIG_DIR="$T/two" STUB_OK_DIR=/never
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/allcut.json" state)"
[ "$out" = failed ] && ok "a list cut everywhere is failed, not blocked" \
    || fail "a cut build attempted work, so blocked would hide it" "$out"
[ ! -e "$T/jobs/blocked" ] && ok "no block marker for a cut build" \
    || fail "a cut must not hold future dispatches as a block" "$(cat "$T/jobs/blocked")"
n="$(grep -c CALL "$T/calls" 2>/dev/null)"
[ "${n:-0}" = 2 ] && ok "each account was still tried exactly once" \
    || fail "the walk must ride every cut to the end of the list" "$n calls"
rm -f "$T/account-state"

echo "a wholly-refused desk turn is notified — never spoken, never conversed:"
# The measured failure: with every account out, extract_response reports the
# refusal as the reply, it landed in the conversation as her words, and the
# never-silent guard read the streamer's empty receipt as a broken speech
# path and spoke the refusal aloud. Now the turn recognises the limit-shaped
# stream, keeps the refusal out of the conversation and off the speakers,
# and the notification carries the outage.
rm -f "$T/spoken" "$T/notifies" "$T/account-state" "$T/state-convo.txt"
run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" STUB_OK_DIR=/never \
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

echo "a desk turn cut off mid-run on every account fails the same way:"
# The 00:17 class at the desk: genuine tool calls, then the limit — on every
# account the list could offer. The CLI's complaint must not become her reply
# in the conversation or on the speakers; the journal and the notification
# carry the failure (specs/account-fallback.md rule 12c).
rm -f "$T/spoken" "$T/notifies" "$T/account-state" "$T/state-convo.txt"
run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" STUB_OK_DIR=/never \
    CLAUDE_BIN="$T/claude-cutstream" LAST_ORIGIN_FILE="$T/state-last-origin" \
    'run_claude_and_respond "still there" >/dev/null' >/dev/null 2>&1
grep -qi "session limit" "$T/state-convo.txt" 2>/dev/null \
    && fail "the cut's refusal entered the conversation as her reply" "$(grep -i "session limit" "$T/state-convo.txt")" \
    || ok "the cut never enters the conversation"
grep -qi "session limit" "$T/spoken" 2>/dev/null \
    && fail "the cut's refusal reached the speakers" "$(cat "$T/spoken")" \
    || ok "the cut never reaches the speakers"
grep -qi "limit" "$T/notifies" 2>/dev/null \
    && ok "the cut is notified as the outage it is" \
    || fail "the cut must be notified" "$(cat "$T/notifies" 2>/dev/null || echo "no notification")"

echo
echo "an inherited CLAUDE_CONFIG_DIR does not steer the walk:"
# Every account is addressed explicitly (rule 3), so a leftover override in
# the environment — exported into a Claude Code session's Bash-tool
# environment, forwarded by job_start on purpose — must be inert: the walk's
# first attempt is account 1's own directory, not whatever arrived pinned.
mkdir -p "$T/dry"

rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_CONFIG_DIR="$T/dry" CLAUDE_FALLBACK_CONFIG_DIR="$T/two" \
    CLAUDE_BIN="$T/claude-stream" 'claude_generate "hello" low')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "desk/phone turn: account 2 still answers" \
    || fail "the turn must reach the account that answers" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1
CALL:$T/two" ] && ok "desk/phone turn (_generate_claude_run): account 1's dir is used, not the pin" \
    || fail "an inherited login must not displace account 1" \
            "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"

rm -f "$T/calls" "$T/account-state"
out="$(run CLAUDE_CONFIG_DIR="$T/dry" CLAUDE_FALLBACK_CONFIG_DIR="$T/two" \
    CLAUDE_BIN="$T/claude-stream" '
    SYSTEM_PROMPT=sys PROMPT_TEXT=hello WAKE_EFFORT=low
    : > "$DEBUGLOG"
    wake_claude_run_chain
    printf "{\"type\":\"result\"}\n" >> "$DEBUGLOG"
    extract_response')"
[ "$out" = "WAKE RETRY REPLY" ] && ok "wake: account 2 still answers" \
    || fail "the wake must reach the account that answers" "$out"
[ "$(cat "$T/calls" 2>/dev/null)" = "CALL:$A1
CALL:$T/two" ] && ok "wake (_wake_claude_run): account 1's dir is used, not the pin" \
    || fail "an inherited login must not displace account 1" \
            "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"

# The job path is where this bites hardest: a builder dispatched mid-turn
# inherits the turn's login by design, so without the explicit address its
# "first attempt" ran on the account the turn was already using — and the
# plain stub below builds happily there, so nothing looked wrong at all.
rm -f "$T/calls" "$T/jobs/blocked" "$T/account-state"
run_runner inherited CLAUDE_CONFIG_DIR="$T/dry" CLAUDE_FALLBACK_CONFIG_DIR="$T/two"
out="$("$REPO_DIR/lib/job-status" get "$T/jobs/inherited.json" state)"
[ "$out" = finished ] && ok "job: account 2 still carries it" \
    || fail "the job must finish on account 2" "$out"
[ "$(head -n1 "$T/calls" 2>/dev/null)" = "CALL:$A1" ] \
    && ok "job (lib/job-runner): the first attempt is account 1's dir, not the inherited login" \
    || fail "an inherited login must not displace account 1" \
            "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)"

# And the harness may not paper over it again: a test that strips the variable
# is testing an environment the shipping code never runs in. The pattern is
# assembled rather than written, so this assertion is not its own hit.
strip="env -u CLAUDE_CONFIG""_DIR"
hits="$(grep -cF "$strip" "$(readlink -f "$0")")"
[ "$hits" = 0 ] && ok "the harness does not strip the variable the code must ignore itself" \
    || fail "the suite must not remove CLAUDE_CONFIG_DIR on the code's behalf" "$hits uses"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
