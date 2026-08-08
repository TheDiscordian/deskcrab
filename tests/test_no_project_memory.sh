#!/bin/bash
# Tests that the assistant's own claude sessions do NOT load the auto-memory of
# the directory they run in, and that a detached job still does.
# Run: bash tests/test_no_project_memory.sh
#
# The gap these were written for: `claude` reads
# $HOME/.claude/projects/<cwd-slug>/memory/MEMORY.md straight into the system
# prompt of any session started in that directory. PROJECT_DIR is the user's
# own coding project, so on 2026-08-07 every desk turn, phone turn and wake was
# arriving with his CODING agent's topic-hub index in its head — a list of
# "read index_discoso.md before working in that area" instructions addressed to
# a different assistant entirely. Her memory is the vector store; that is his.
#
# The fix is an environment variable, and an environment variable is exactly
# the kind of thing a later edit drops without noticing, because nothing
# visibly breaks when it goes: the prompt just quietly grows a stranger's
# memory again. So each case runs the REAL invocation path with a stub in place
# of claude that records the environment it was handed.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

mkdir -p "$T/project"
cat > "$DESKCRAB_CONF" <<EOF
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
PROJECT_DIR="$T/project"
EOF

# The stub stands in for the CLI. It writes the one environment variable under
# test to a witness file (the answer for THIS run only — truncated, not
# appended), then emits a minimal well-formed stream so the caller's own
# plumbing completes rather than hanging on a log that never terminates.
cat > "$T/claude-stub" <<'STUB'
#!/bin/bash
printf '%s\n' "AUTOMEM=[${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-<unset>}]" > "$WITNESS"
printf '%s\n' \
    '{"type":"assistant","message":{"model":"claude","content":[{"type":"text","text":"ok"}]}}' \
    '{"type":"result","result":"ok"}'
STUB
chmod +x "$T/claude-stub"

run() { # <shell body> — sources common.sh in the sandbox instance with the stub.
    # CLAUDE_BIN is passed in the environment on purpose: common.sh snapshots
    # an inherited CLAUDE_BIN and hands it back after sourcing the config,
    # which is the only way a test can keep a real builder from being started.
    # The state directory the harvest prunes (notice_own_writes copies each
    # stream into it and trims it to NOTICE_STREAM_KEEP) is the sandbox's, so a
    # run of this file can no longer delete her real forensic streams or append
    # to her live declaration log. Nothing here unsets CLAUDE_CONFIG_DIR: the
    # sandbox starts from an empty environment, so there is nothing to unset.
    DESKCRAB_STREAMLOG="$T/state-debug.log" \
        CLAUDE_BIN="$T/claude-stub" WITNESS="$T/witness-file" \
        sandbox_bash "$1" > /dev/null 2>&1
}

witness() { cat "$T/witness-file" 2>/dev/null || echo "(stub never ran)"; }

echo "her own sessions run with auto-memory off:"

rm -f "$T/witness-file"
run 'claude_generate "hello" low'
out="$(witness)"
[ "$out" = "AUTOMEM=[1]" ] && ok "desk/phone turn (claude_generate)" \
    || fail "claude_generate must disable auto-memory" "$out"

# _wake_claude_run reads SYSTEM_PROMPT / PROMPT_TEXT / CLAUDE_BIN out of the
# caller's scope, so the body sets them exactly as run_claude_wake does.
rm -f "$T/witness-file"
run 'SYSTEM_PROMPT=p; PROMPT_TEXT=t; DEBUGLOG="'"$T"'/wake.log"; _wake_claude_run ""'
out="$(witness)"
[ "$out" = "AUTOMEM=[1]" ] && ok "autonomous wake (_wake_claude_run)" \
    || fail "the wake path must disable auto-memory" "$out"

# The fallback login is a second full session on the same prompt; it must be
# no more porous than the first. Drive it by leaving a limit refusal in the
# stream log, which is the condition claude_limit_fallback_due tests.
rm -f "$T/witness-file"
printf '%s\n' \
    '{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You have hit your usage limit reached"}]}}' \
    '{"type":"result","is_error":true,"result":"usage limit reached"}' > "$T/fb-seed"
run 'CLAUDE_FALLBACK_CONFIG_DIR="'"$T"'/fb"
     cp "'"$T"'/fb-seed" "$DEBUGLOG"
     if claude_limit_fallback_due; then
        cd "$PROJECT_DIR" && env "$CLAUDE_NO_AUTO_MEMORY" \
            CLAUDE_CONFIG_DIR="$CLAUDE_FALLBACK_CONFIG_DIR" "$CLAUDE_BIN" >/dev/null
     fi'
out="$(witness)"
[ "$out" = "AUTOMEM=[1]" ] && ok "usage-limit fallback retry" \
    || fail "the fallback retry must disable auto-memory too" "$out"

# compact_convo only reaches the CLI when the live conversation has grown past
# its threshold, which is a lot of fixture for one env prefix — assert on the
# source instead. There is now ONE invocation, inside the loop that walks the
# account chain, so every login it tries carries the prefix by construction: the
# check is that the loop still has exactly one CLI call in it, because a second
# one is how the primary and the fallback drifted apart the first time.
n_sum=$(grep -c 'NEWSUM=\$(cd "\$PROJECT_DIR" && env "\$CLAUDE_NO_AUTO_MEMORY"' "$REPO_DIR/lib/common.sh")
[ "$n_sum" -eq 1 ] && ok "conversation compaction, every login (compact_convo)" \
    || fail "compact_convo must run the CLI in one prefixed place" "$n_sum of 1 prefixed"

echo
echo "the knob is per-invocation, never machine-wide:"

# An export would reach lib/job-runner (it sources common.sh) and would also be
# inherited by anything else she launches. Sourcing must leave the process
# environment untouched.
out="$(sandbox_bash 'printf "%s\n" "env=[${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-<unset>}] var=[${CLAUDE_NO_AUTO_MEMORY:-<unset>}]"' 2>&1)"
[ "$out" = "env=[<unset>] var=[CLAUDE_CODE_DISABLE_AUTO_MEMORY=1]" ] \
    && ok "sourcing common.sh defines the prefix but exports nothing" \
    || fail "the knob must not be exported" "$out"

# Nothing may write it into a settings file either: that would switch
# auto-memory off for the user's own coding sessions in the same directory.
# The JSON key, not the word: the comments that explain the choice name it, and
# a test that cannot tell an explanation from an implementation is a test that
# gets deleted the first time someone writes a better comment.
hits="$(grep -rlF '"autoMemoryEnabled"' "$REPO_DIR" 2>/dev/null \
    | grep -vFx "$(readlink -f "$0")" | tr '\n' ' ')"
[ -z "$hits" ] && ok "no settings.json autoMemoryEnabled key is written anywhere" \
    || fail "no settings-file knob" "$hits"

echo
echo "a detached builder keeps the project's rules:"

# A job is a headless coding session working inside the user's project, and the
# project's memory index is precisely what it should arrive knowing. Assert the
# absence deliberately, so removing the comment that explains it fails here.
grep -n 'CLAUDE_NO_AUTO_MEMORY\|CLAUDE_CODE_DISABLE_AUTO_MEMORY' "$REPO_DIR/lib/job-runner" \
    | grep -qv '^[0-9]*:#' \
    && fail "job-runner must not disable auto-memory" "$(grep -n 'AUTO_MEMORY' "$REPO_DIR/lib/job-runner")" \
    || ok "lib/job-runner runs claude without the switch"
