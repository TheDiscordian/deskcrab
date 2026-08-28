#!/bin/bash
# Tests for jobs.md rule 1a (a substitution artifact is not a brief) and rule
# 7a (requeue reads the sidecar's own .description) as one closed loop. Run:
# bash tests/test_job_guard.sh
#
# The pair was built by the 00:25 builder of 2026-08-11 — the night a
# re-dispatch loop asked jq for `.task` in sidecars whose field is
# `.description`, jq answered the only way it can, and three real builders
# woke on the literal word "null" — but the thread that dispatched it says its
# claims were never checked. This file is the check. It holds the brief's own
# words against the code: each artifact string must exit NON-ZERO (a message
# piped through `head` loses the status it rode in on, so the existing
# test_job_block.sh cases never proved that half), must name the value it
# refused, and must leave the jobs directory byte-for-byte alone; and a
# requeue must reproduce the recorded description verbatim, or refuse loudly
# when the sidecar has nothing usable — including the field being ABSENT
# entirely, the exact shape the .task misread produces.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# Same guard on every case as test_job_block.sh: no case in this file wants a
# real builder, so DESKCRAB_NO_DISPATCH rides every call rather than the few
# that would reach dispatch today. Unlike that file's run(), the exit status
# travels back — rule 1a's refusal is an exit code as much as a sentence.
JG_OUT="" JG_RC=0
run_rc() { # <shell body> — fills JG_OUT (stdout+stderr) and JG_RC
    JG_OUT="$(JOBS_DIR="$T/jobs" DESKCRAB_NO_DISPATCH=1 sandbox_bash "$*" 2>&1)"
    JG_RC=$?
}

mkdir -p "$T/jobs"
jobs_snapshot() { ls -A "$T/jobs" 2>/dev/null | sort | tr '\n' ' '; }

echo "rule 1a — the five artifact strings, at the one guard every dispatch walks:"
BEFORE="$(jobs_snapshot)"
for bad in "" "   " null None undefined; do
    run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_start "'"$bad"'"'
    [ "$JG_RC" -ne 0 ] && ok "exits non-zero: '$bad'" \
        || fail "'$bad' must exit non-zero" "rc=$JG_RC: $JG_OUT"
    case "$JG_OUT" in *"Would dispatch"*)
            fail "'$bad' must never reach dispatch" "$JG_OUT" ;;
        *) ok "the refusal comes before dispatch: '$bad'" ;; esac
    # The message names what it refused. The empty string has no letters to
    # name, and its refusal has always been the usage line — that is the name.
    if [ -z "$bad" ]; then
        case "$JG_OUT" in *"Usage: crab job"*) ok "the empty brief gets the usage line" ;;
            *) fail "an empty brief must say how to call this" "$JG_OUT" ;; esac
    else
        case "$JG_OUT" in *"'$bad'"*"broken command substitution"*|*"broken command substitution"*"'$bad'"*)
                ok "the refusal names the value: '$bad'" ;;
            *) fail "the refusal must name '$bad' and call it a substitution artifact" "$JG_OUT" ;; esac
    fi
done
check_eq "five refusals wrote nothing into the jobs directory" \
    "$(jobs_snapshot)" "$BEFORE"

echo "an immediate OpenRSC steering control never becomes builder work:"
run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_start "Run ~/.local/bin/betty-openrsc steer Stop circling and continue the quest"'
[ "$JG_RC" -ne 0 ] && ok "steering dispatch is refused, non-zero" \
    || fail "steering must stay in the requesting turn" "rc=$JG_RC: $JG_OUT"
case "$JG_OUT" in *"immediate local control"*) ok "the refusal explains the direct control path" ;;
    *) fail "the steering refusal must explain why" "$JG_OUT" ;; esac
case "$JG_OUT" in *"Would dispatch"*) fail "steering must never reach dispatch" "$JG_OUT" ;;
    *) ok "the steering refusal comes before dispatch" ;; esac
check_eq "the refused steering control wrote no job" "$(jobs_snapshot)" "$BEFORE"

echo "…and a real brief still walks through:"
run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_start "refit the letterbox flap"'
[ "$JG_RC" -eq 0 ] && ok "a real brief exits zero" || fail "a real brief must not be refused" "rc=$JG_RC: $JG_OUT"
case "$JG_OUT" in *"Would dispatch"*) ok "a real brief reaches dispatch (stubbed)" ;;
    *) fail "a real brief must reach dispatch" "$JG_OUT" ;; esac
# The guard is for a bare artifact, never for briefs about null pointers.
run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_start "chase the null pointer crash in serve.py"'
case "$JG_OUT" in *"Would dispatch"*) ok "'null' inside a sentence still dispatches" ;;
    *) fail "a brief mentioning null must pass" "$JG_OUT" ;; esac

echo "the queued door holds the same line (rule 32's preflight):"
# A queued corpse predating the guard — or minted by a future misread — must
# not wake a builder just because its sidecar already exists. This door cannot
# route through job_start (same id, same sidecar, dispatched in place), so the
# artifact check stands here too, judged on the recorded field.
python3 - "$T/jobs/jg-qnull.json" <<'PY'
import json, sys
json.dump({"id": "jg-qnull", "description": "null", "workdir": "/tmp/jg-rqdir",
           "state": "queued"}, open(sys.argv[1], "w"))
PY
run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_dispatch_queued jg-qnull'
[ "$JG_RC" -ne 0 ] && ok "a queued 'null' corpse is refused, non-zero" \
    || fail "a queued artifact must not dispatch" "rc=$JG_RC: $JG_OUT"
case "$JG_OUT" in *"broken command substitution"*) ok "…and the refusal says why" ;;
    *) fail "the queued refusal must name the artifact" "$JG_OUT" ;; esac
rm -f "$T/jobs/jg-qnull.json"

echo "rule 7a — requeue reads .description off the sidecar, verbatim:"
# The sidecar is written raw here, field names spelled by hand, because the
# field name IS the subject: the record's brief lives in .description, there
# is no .task, and requeue must find the words without any caller typing
# either name again.
python3 - "$T/jobs/jg-rqverb.json" <<'PY'
import json, sys
json.dump({"id": "jg-rqverb", "state": "failed", "workdir": "/tmp/jg-rqdir",
           "description": "refit the letterbox flap, and mind the null note"},
          open(sys.argv[1], "w"))
PY
run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_requeue jg-rqverb'
[ "$JG_RC" -eq 0 ] && ok "a usable record requeues, exit zero" \
    || fail "requeue of a good record must succeed" "rc=$JG_RC: $JG_OUT"
check_eq "the recorded description reaches dispatch verbatim, in the recorded dir" \
    "$(printf '%s\n' "$JG_OUT" | head -n1)" \
    "Would dispatch (DESKCRAB_NO_DISPATCH set) in /tmp/jg-rqdir: refit the letterbox flap, and mind the null note"

echo "…and a sidecar with nothing usable refuses, loudly:"
# The field entirely absent — what reading .task out of a real sidecar leaves
# you holding. job-status renders a missing key as the empty string.
python3 - "$T/jobs/jg-rqmiss.json" <<'PY'
import json, sys
json.dump({"id": "jg-rqmiss", "state": "failed", "workdir": "/tmp/jg-rqdir"},
          open(sys.argv[1], "w"))
PY
run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_requeue jg-rqmiss'
[ "$JG_RC" -ne 0 ] && ok "a missing description field exits non-zero" \
    || fail "requeue of a description-less sidecar must refuse" "rc=$JG_RC: $JG_OUT"
case "$JG_OUT" in *"no usable description"*) ok "…saying there is nothing to requeue" ;;
    *) fail "the refusal must say the description is unusable" "$JG_OUT" ;; esac
case "$JG_OUT" in *"Would dispatch"*) fail "a refused requeue must never reach dispatch" "$JG_OUT" ;;
    *) ok "the refusal comes before dispatch" ;; esac
# The field present but typed null — job-status (python) renders it "None",
# jq renders it "null"; the guard's case names both spellings on purpose.
python3 - "$T/jobs/jg-rqnull.json" <<'PY'
import json, sys
json.dump({"id": "jg-rqnull", "state": "failed", "workdir": "/tmp/jg-rqdir",
           "description": None}, open(sys.argv[1], "w"))
PY
run_rc 'rm -f "$JOBS_BLOCKED_FILE"; job_requeue jg-rqnull'
[ "$JG_RC" -ne 0 ] && ok "a null-typed description exits non-zero" \
    || fail "requeue of a null description must refuse" "rc=$JG_RC: $JG_OUT"
case "$JG_OUT" in *"no usable description"*) ok "…and says so" ;;
    *) fail "the null-typed refusal must say the description is unusable" "$JG_OUT" ;; esac
rm -f "$T/jobs/jg-rqverb.json" "$T/jobs/jg-rqmiss.json" "$T/jobs/jg-rqnull.json"

check_eq "nothing in this file ever minted a job" "$(jobs_snapshot)" "$BEFORE"
