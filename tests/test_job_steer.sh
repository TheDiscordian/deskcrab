#!/bin/bash
# A correction reaches one running builder, and no wake or second job.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"
J="$T/jobs"
ID="steerable-job"
mkdir -p "$J"

make_job() {  # <id> <state> <model> <steerable>
    python3 - "$J/$1.json" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
path, jid, state, model, steerable = sys.argv[1:]
json.dump({"id": jid, "description": "build the portrait", "state": state,
           "model": model, "steerable": int(steerable)}, open(path, "w"))
PY
}
make_job "$ID" running fable 1

echo "== the command targets the existing builder's durable inbox =="
OUT="$(JOBS_DIR="$J" sandbox_bash 'job_steer steerable-job "move EE and AI mouths slightly left"')"
check "the command says queued, not delivered or applied" contains "$OUT" \
    "Correction queued directly for active job steerable-job"
check_eq "one pending correction exists" \
    "$(find "$J/$ID.steer" -maxdepth 1 -name '*.pending' | wc -l)" "1"
check_eq "no second job sidecar was created" \
    "$(find "$J" -maxdepth 1 -name '*.json' | wc -l)" "1"
check_eq "no wake record was created" \
    "$(find "$WAKES_DIR" -maxdepth 1 -name '*.wake' 2>/dev/null | wc -l)" "0"

OUT2="$(JOBS_DIR="$J" sandbox_bash 'job_steer steerable-job "move EE and AI mouths slightly left"')"
check "an identical pending correction coalesces" contains "$OUT2" "already queued"
check_eq "coalescing leaves one pending correction" \
    "$(find "$J/$ID.steer" -maxdepth 1 -name '*.pending' | wc -l)" "1"

echo "== the named builder's hook receives it once and records delivery =="
mkdir -p "${DESKCRAB_STATE_PREFIX}-midturn"
printf 'UNRELATED PHONE MESSAGE' > "${DESKCRAB_STATE_PREFIX}-midturn/1.other.msg"
HOOK_OUT="$(DESKCRAB_JOB_ID="$ID" JOBS_DIR="$J" "$REPO_DIR/lib/job-steer-mail")"
check "the hook names an active builder correction" contains "$HOOK_OUT" \
    "ACTIVE BUILDER CORRECTION"
check "the exact correction is injected" contains "$HOOK_OUT" \
    "move EE and AI mouths slightly left"
PARSED="$(printf '%s' "$HOOK_OUT" | python3 -c '
import json,sys
o=json.load(sys.stdin)["hookSpecificOutput"]
print(o["hookEventName"])
print("supersedes" in o["additionalContext"])
')"
check_eq "the hook payload is valid PostToolUse context" "$PARSED" "PostToolUse
True"
check_eq "pending becomes a delivered receipt" \
    "$(find "$J/$ID.steer" -maxdepth 1 -name '*.delivered' | wc -l)" "1"
check_eq "and no pending copy remains" \
    "$(find "$J/$ID.steer" -maxdepth 1 -name '*.pending' | wc -l)" "0"
check "the sidecar records delivered separately from queued" contains \
    "$("$REPO_DIR/lib/job-status" show "$J/$ID.json")" "delivered"
check_eq "the builder hook never drains interactive mid-turn mail" \
    "$(find "${DESKCRAB_STATE_PREFIX}-midturn" -name '*.msg' | wc -l)" "1"
check_eq "a second hook call is silent" \
    "$(DESKCRAB_JOB_ID="$ID" JOBS_DIR="$J" "$REPO_DIR/lib/job-steer-mail")" ""

echo "== unsupported targets are refused instead of pretending =="
make_job old-job running fable 0
OLD="$(JOBS_DIR="$J" sandbox_bash 'job_steer old-job "change course"' 2>&1)"; OLD_RC=$?
[ "$OLD_RC" -ne 0 ] && ok "a pre-hook running job is refused" \
    || fail "a pre-hook running job must be refused" "$OLD"
check "the refusal says no correction was queued" contains "$OLD" "cannot accept a correction safely"

make_job codex-job running sol 0
CODEX="$(JOBS_DIR="$J" sandbox_bash 'job_steer codex-job "change course"' 2>&1)"; CODEX_RC=$?
[ "$CODEX_RC" -ne 0 ] && ok "a Codex builder is refused" \
    || fail "a Codex builder must be refused" "$CODEX"
check "the backend limitation is explicit" contains "$CODEX" "Codex backend"

make_job ended-job finished fable 1
ENDED="$(JOBS_DIR="$J" sandbox_bash 'job_steer ended-job "change course"' 2>&1)"; ENDED_RC=$?
[ "$ENDED_RC" -ne 0 ] && ok "an ended builder is refused" \
    || fail "an ended builder must be refused" "$ENDED"
check "the ended state is explicit" contains "$ENDED" "not active"

echo "== job profile wiring carries the private hook =="
HOOKS_OUT="$(JOBS_DIR="$J" sandbox_bash 'export DESKCRAB_JOB_ID=steerable-job; claude_profile_flags job; cat "${STATE_PREFIX}-hooks-job-steerable-job.json"')"
check "the job settings carry PostToolUse" contains "$HOOKS_OUT" '"PostToolUse"'
check "the job settings point at the private reader" contains "$HOOKS_OUT" "lib/job-steer-mail"
printf '%s' "$HOOKS_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
    && ok "the generated job hook settings are valid JSON" \
    || fail "the generated job hook settings must be valid JSON" "$HOOKS_OUT"

echo "== current-activity answers read the newest tool actions =="
STREAM="$T/job-stream.jsonl"
python3 - "$STREAM" <<'PY'
import json, sys
events = [
    ("2026-08-30T20:40:00Z", "Read", {"file_path": "/tmp/original-brief.md"}),
    ("2026-08-30T20:51:00Z", "Bash", {"description": "Recenter both viseme mouths slightly left"}),
]
with open(sys.argv[1], "w") as fh:
    for timestamp, name, args in events:
        json.dump({"timestamp": timestamp, "message": {"content": [
            {"type": "tool_use", "name": name, "input": args}]}}, fh)
        fh.write("\n")
PY
"$REPO_DIR/lib/job-status" set "$J/$ID.json" stream="$STREAM"
ACTIVITY="$("$REPO_DIR/lib/job-activity" "$J/$ID.json" 1)"
check "the activity door reports the newest action" contains "$ACTIVITY" \
    "Recenter both viseme mouths slightly left"
if grep -q 'original-brief' <<<"$ACTIVITY"; then
    fail "a one-action view must not substitute the original brief for current work" "$ACTIVITY"
else
    ok "the one-action view excludes the stale original brief"
fi
