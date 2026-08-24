#!/bin/bash
# Tests that an OAuth authentication death on one account never reaches any
# rendered reply — engineering record an-auth-failure-string-is-leaking-into-
# my-displa, and the summary-view sighting it stayed open for.
#
# The fault, observed live 2026-08-20 00:58-01:15: one account's token refresh
# died with "Failed to authenticate: OAuth session expired and could not be
# refreshed". claude_stream_refusal knows only the LIMIT wordings, so every
# account walk read the auth death as an outage that would follow the walk to
# the next login and broke without rotating — and extract-response's error-only
# fallback then stood the CLI's line in as the reply. The phone display and the
# journal got it as her words (the voice path skips synthetic blocks, which is
# why the audio was fine), and the summariser's walk, blind the same way,
# committed it as the conversation summary the phone renders. Auth is
# per-account — the OTHER logins were answering fine the whole time — the same
# argument that put "Not logged in" in the signature on 2026-08-07.
#
# What these cases pin:
#   (a) an auth failure mid-stream beside real reply text: the walk rides it to
#       the next account, the delivered reply (the one string every sink —
#       display, journal, conversation — is fed from) holds the reply and not
#       one byte of the auth line, and the failed attempt is on the account
#       record;
#   (b) an auth failure with nothing else: the run reads as a failed run
#       (claude_run_limited), which routes every caller — desk and phone alike —
#       into the branch that delivers NOTHING and reports the outage in its own
#       channel, never as her reply; the summariser folds nothing and commits
#       nothing, whatever the failure's wording (the DESKCRAB_DROP_SYNTHETIC
#       belt covers wordings the signature does not know);
#   (c) her OWN words quoting the auth sentence pass through untouched — the
#       refusal is structural (CLI-owned text, no genuine output), never a
#       pattern match over her reply (account-fallback.md rule 15).
#
# Run: bash tests/test_auth_leak_filter.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

mkdir -p "$T/two"

# The notifier the desk would see; the sandbox stub keeps it off the screen,
# this one is the witness.
sandbox_stub notify-send <<STUB
#!/bin/bash
printf 'NOTIFY:%s\n' "\$*" >> "$T/notifies"
STUB

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$T"
WAKE_QUIET_HOURS=""
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
EOF

run() { # [ENV=val ...] <shell body> — sources common.sh in the sandbox instance.
    local -a envs=()
    while [ $# -gt 1 ]; do envs+=("$1"); shift; done
    local body="$1"
    DESKCRAB_STREAMLOG="$T/state-debug.log" \
        DESKCRAB_NO_DISPATCH=1 \
        env ${envs[@]+"${envs[@]}"} \
        bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$SANDBOX_REPO" "$body" 2>&1
}

# The exact line observed live, verbatim.
AUTH='Failed to authenticate: OAuth session expired and could not be refreshed'
A1="$HOME/.claude"   # account 1 by definition (the sandbox's own HOME)

# Prewritten fixtures, as the neighbouring suites do it. The auth stream is the
# CLI's own shape from 2026-08-20: a synthetic assistant message plus an
# is_error result, and the process exits 0 — the summary WAS committed live,
# so the CLI does exit clean in this failure mode.
printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"'"$AUTH"'"}]}}' \
    '{"type":"result","is_error":true,"result":"'"$AUTH"'"}' > "$T/fixture-auth"
# An auth-shaped failure in a wording the signature has never heard of — the
# belt case: the summariser must fold nothing on this one too.
printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Credential verification imploded in a brand-new wording"}]}}' \
    '{"type":"result","is_error":true,"result":"Credential verification imploded in a brand-new wording"}' > "$T/fixture-odd"
printf '%s\n' \
    '{"type":"assistant","message":{"model":"claude","content":[{"type":"text","text":"REAL REPLY AFTER ROTATION"}]}}' \
    '{"type":"result","result":"REAL REPLY AFTER ROTATION"}' > "$T/fixture-reply"
# Her own words ABOUT the fault — the sentence as a quotation inside a genuine
# reply. Built through json.dumps because the text holds double quotes.
QUOTE="The phone kept showing \"$AUTH\" spliced into my replies — that line is the CLI's, not mine, and it should be logged as a failed run."
python3 - "$T/fixture-quote" "$QUOTE" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"model": "claude",
        "content": [{"type": "text", "text": text}]}}) + "\n")
    f.write(json.dumps({"type": "result", "result": text}) + "\n")
PY
# A faithful summary of an evening spent debugging exactly this fault.
SUMQUOTE="Evening of 2026-08-20: the phone kept rendering \"$AUTH\" inside her replies; the leak was traced and closed."
python3 - "$T/fixture-sumquote" "$SUMQUOTE" <<'PY'
import json, sys
path, text = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    f.write(json.dumps({"type": "assistant", "message": {"model": "claude",
        "content": [{"type": "text", "text": text}]}}) + "\n")
    f.write(json.dumps({"type": "result", "result": text}) + "\n")
PY

# The walk stub: auth-dies on every account except STUB_OK_DIR, where it plays
# STUB_REPLY. Never reads stdin — the turn path passes the prompt as an
# argument, and a stub that cats an inherited stdin can hang the suite.
cat > "$T/claude-auth" <<EOF
#!/bin/bash
echo "CALL:\${CLAUDE_CONFIG_DIR:-none}" >> "$T/calls"
if [ "\${CLAUDE_CONFIG_DIR:-}" = "\${STUB_OK_DIR-$T/two}" ]; then
    cat "\${STUB_REPLY:-$T/fixture-reply}"
    exit 0
fi
cat "$T/fixture-auth"
exit 0
EOF
chmod +x "$T/claude-auth"

# The summariser stub: classify shape, so it MUST drain stdin (the material
# arrives on it). Plays STUB_SUM_REPLY on STUB_SUM_OK, STUB_SUM_FIXTURE
# everywhere else.
cat > "$T/claude-sum" <<EOF
#!/bin/bash
cat > /dev/null
echo "CALL:\${CLAUDE_CONFIG_DIR:-none}" >> "$T/sumcalls"
if [ -n "\${STUB_SUM_REPLY:-}" ] && [ "\${CLAUDE_CONFIG_DIR:-}" = "\${STUB_SUM_OK:-none}" ]; then
    cat "\$STUB_SUM_REPLY"
    exit 0
fi
cat "\${STUB_SUM_FIXTURE:-$T/fixture-auth}"
exit 0
EOF
chmod +x "$T/claude-sum"

CONVOFILE="$SANDBOX/state/deskcrab-convo.txt"
SUMFILE="$SANDBOX/state/deskcrab-convo-summary.txt"
build_convo() { # <n exchanges> — enough blocks to trip a threshold of 10
    local i
    : > "$CONVOFILE"
    for (( i = 1; i <= $1; i++ )); do
        printf 'User: question %d\n' "$i" >> "$CONVOFILE"
        printf 'Assistant: answer %d\n\n' "$i" >> "$CONVOFILE"
    done
}

# --- the detection itself ----------------------------------------------------

echo "claude_stream_refusal — an auth death is one login's corpse, not an outage:"
out="$(run 'claude_stream_refusal "'"$T"'/fixture-auth" || echo UNRECOGNISED')"
contains "$out" "Failed to authenticate" \
    && ok "the OAuth auth-failure line is recognised, whole line printed" \
    || fail "the auth death must be a refusal the walk can ride" "$out"

out="$(run 'claude_refusal_kind "'"$AUTH"'"')"
check_eq "it takes the SHORT cooldown — a refreshed token comes back at the next walk-on" \
    "$out" "session"
out="$(run 'claude_refusal_scope "'"$AUTH"'"')"
check_eq "no model named, so the dead login is benched for every model" "$out" "all"

# Rule 15, the anti-gag pin: her genuine reply QUOTING the sentence is model
# output, so the structural test must never read it as a refusal.
out="$(run 'claude_stream_refusal "'"$T"'/fixture-quote" && echo GAGGED || echo her-words')"
check_eq "a genuine reply quoting the auth sentence is never read as a refusal" \
    "$out" "her-words"

echo "job_output_blocked — a builder facing a dead login never began:"
printf '%s\n' "$AUTH" > "$T/joblog"
out="$(run 'job_output_blocked "'"$T"'/joblog" && echo BLOCKED || echo no')"
check_eq "the auth line reads as blocked, so the job is re-dispatched, not buried as failed" \
    "$out" "BLOCKED"

# --- (a) auth failure beside real reply text: the walk rotates -----------------

echo "the turn walk rides an auth death to the next account:"
rm -f "$T/calls" "$ACCOUNT_STATE_FILE"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" CLAUDE_BIN="$T/claude-auth" \
    'claude_generate "hello" low')"
# claude_generate's return is the ONE string every sink is fed from — the
# display split, the conversation write, and the journal all read this.
check_eq "the delivered reply is the rotated account's, whole" \
    "$out" "REAL REPLY AFTER ROTATION"
contains "$out" "Failed to authenticate" \
    && fail "the CLI's error is spliced into her reply" "$out" \
    || ok "not one byte of the auth line in the delivered reply"
check_eq "account 1 died, account 2 was tried at once" \
    "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)" "CALL:$A1 CALL:$T/two "
grep -q "^cooldown	1	" "$ACCOUNT_STATE_FILE" 2>/dev/null \
    && ok "the failed attempt is on the account record — a cooldown for account 1" \
    || fail "an auth death must be recorded like any refused attempt" \
        "$(cat "$ACCOUNT_STATE_FILE" 2>/dev/null || echo none)"
grep -q "account-swap" "$T/state-debug.log" 2>/dev/null \
    && ok "the swap marker is in the stream log — the failed run is legible there" \
    || fail "the walk must announce the swap in the stream" \
        "$(head -c 200 "$T/state-debug.log" 2>/dev/null)"

# --- (b) nothing but the auth failure: a failed run, no sink fed ---------------

echo "an auth failure with nothing else is a FAILED run, never a reply:"
rm -f "$T/calls" "$ACCOUNT_STATE_FILE"
out="$(run CLAUDE_FALLBACK_CONFIG_DIR="$T/two" CLAUDE_BIN="$T/claude-auth" \
    STUB_OK_DIR="$T/nowhere" '
    claude_generate "hello" low >/dev/null
    claude_run_limited && echo FAILED-RUN || echo delivered-as-reply')"
# claude_run_limited answering yes is what routes BOTH the desk and the phone
# caller into their existing all-refused branch: nothing enters the
# conversation, nothing is journalled as her reply, the outage rides the
# error/notification channel (account-fallback.md rule 12c).
check_eq "the whole-log judgement reads the run as failed" "$out" "FAILED-RUN"
check_eq "every login was offered before the run failed" \
    "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)" "CALL:$A1 CALL:$T/two "
grep -q "^cooldown	1	" "$ACCOUNT_STATE_FILE" 2>/dev/null \
    && grep -q "^cooldown	2	" "$ACCOUNT_STATE_FILE" 2>/dev/null \
    && ok "both dead logins are on the record" \
    || fail "every auth-dead attempt must be recorded" \
        "$(cat "$ACCOUNT_STATE_FILE" 2>/dev/null || echo none)"

echo "the summariser commits nothing on an auth death (the 01:15 summary-view road):"
rm -f "$T/sumcalls" "$ACCOUNT_STATE_FILE" "$SUMFILE"
build_convo 8
BEFORE="$(md5sum < "$CONVOFILE")"
run CONVO_MAX_TURNS=10 CONVO_SUMMARIZE_TURNS=5 CLAUDE_BIN="$T/claude-sum" \
    'compact_convo' >/dev/null
check_eq "no summary was committed" "$([ -f "$SUMFILE" ] && echo written || echo none)" "none"
grep -qF "$AUTH" "$SUMFILE" 2>/dev/null \
    && fail "the auth line IS the committed summary" "$(cat "$SUMFILE")" \
    || ok "the auth line reached no summary the phone could render"
check_eq "the conversation is whole — nothing folded away on a failure" \
    "$(md5sum < "$CONVOFILE")" "$BEFORE"
check "the dead login was cooled by the summariser's walk too" \
    test -s "$ACCOUNT_STATE_FILE"

echo "the belt: a wording the signature does not know still commits nothing:"
rm -f "$T/sumcalls" "$ACCOUNT_STATE_FILE" "$SUMFILE"
build_convo 8
BEFORE="$(md5sum < "$CONVOFILE")"
run CONVO_MAX_TURNS=10 CONVO_SUMMARIZE_TURNS=5 CLAUDE_BIN="$T/claude-sum" \
    STUB_SUM_FIXTURE="$T/fixture-odd" 'compact_convo' >/dev/null
check_eq "an error-only stream in ANY wording folds nothing" \
    "$([ -f "$SUMFILE" ] && cat "$SUMFILE" || echo none)" "none"
check_eq "the conversation survived that too" "$(md5sum < "$CONVOFILE")" "$BEFORE"

# --- (c) her own words about the fault pass through untouched ------------------

echo "no gate on her tongue — the sentence as her own quoted words:"
rm -f "$T/calls" "$ACCOUNT_STATE_FILE"
out="$(run CLAUDE_BIN="$T/claude-auth" STUB_OK_DIR="$A1" \
    STUB_REPLY="$T/fixture-quote" '
    RESP="$(claude_generate "what was that error on the phone" low)"
    claude_run_limited && echo "GAGGED" || printf "%s" "$RESP"')"
check_eq "the reply that quotes the auth sentence is delivered unchanged" \
    "$out" "$QUOTE"
check_eq "one call, no rotation off the back of her own words" \
    "$(tr '\n' ' ' < "$T/calls" 2>/dev/null)" "CALL:$A1 "
check_eq "no account was cooled over a quotation" \
    "$([ -s "$ACCOUNT_STATE_FILE" ] && cat "$ACCOUNT_STATE_FILE" || echo unmoved)" \
    "unmoved"

echo "and a faithful summary MENTIONING the auth line still commits:"
rm -f "$T/sumcalls" "$ACCOUNT_STATE_FILE" "$SUMFILE"
build_convo 8
run CONVO_MAX_TURNS=10 CONVO_SUMMARIZE_TURNS=5 CLAUDE_BIN="$T/claude-sum" \
    STUB_SUM_OK="$A1" STUB_SUM_REPLY="$T/fixture-sumquote" 'compact_convo' >/dev/null
check_eq "the summary that reached disk is the model's words, quotation and all" \
    "$(cat "$SUMFILE" 2>/dev/null)" "$SUMQUOTE"
check_eq "no account was stamped dry over the summary's words" \
    "$([ -s "$ACCOUNT_STATE_FILE" ] && cat "$ACCOUNT_STATE_FILE" || echo unmoved)" \
    "unmoved"
