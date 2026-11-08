#!/bin/bash
# The two gates that keep a chore off the user's plate (specs/turn-pipeline.md
# rule 16c, specs/engineering-records.md rules 15-15c, specs/jobs.md rule 27's
# floor). Run: bash tests/test_chore_gate.sh
#
# The originating failure (2026-08-25, thread
# my-output-can-end-in-a-chore-for-him-and-a-recor): a night session ended
# the stale-tidy-unit record with two command lines for the user to run — one
# of them, "Also unset: TIDY_CLAIMS_ROOTS", a statement phrased so it READ as
# an instruction — and he woke to a chore his own machine could have run.
#
# The contract under test:
#   - a displayed reply that assigns the user command-shaped work dispatches
#     EXACTLY ONE detached job carrying the chore lines, and the forbidden
#     instruction reaches no screen sink (display half, conversation form,
#     the desk turn's display file);
#   - benign command mentions pass byte-identical with nothing dispatched;
#   - a `crab eng touch` whose note ends at inability or at a user chore
#     dispatches one builder against the record and lands the job id on the
#     entry, durably, with `record_attached_epoch` on the sidecar;
#   - the gate's own attach write can never stand in for the builder's
#     entry (the runner's rule-27 floor);
#   - every failure fails OPEN: the reply and the record write survive.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JOBS="$JOBS_DIR"
ENG="$XDG_DATA_HOME/deskcrab/engineering/records"
GATELOG="${DESKCRAB_STATE_PREFIX}-chore-gate.log"
mkdir -p "$JOBS" "$T/work" "$T/out"
E() { DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" "$@"; }

# One invoker for the delivery split, sourcing lib/common.sh the same way
# sandbox_bash does — with the split's globals written out where the test
# can read them. Arguments, because the fixtures are multi-line files.
gate_split() {  # <response file> <out prefix> [extra env assignments...]
    local resp="$1" out="$2"; shift 2
    env "$@" bash -c '
        source "$1/lib/common.sh" >/dev/null 2>&1
        RESP="$(cat "$2")"
        reply_delivery_split "$RESP" || true
        printf "%s" "$REPLY_DISPLAY" > "$3.display"
        printf "%s" "$REPLY_TEXT"    > "$3.text"
        printf "%s" "$REPLY_SPOKEN"  > "$3.spoken"
    ' _ "$REPO" "$resp" "$out"
}

jobs_count() { ls "$JOBS" 2>/dev/null | grep -c '\.json$'; }
job_ids() { ls "$JOBS" 2>/dev/null | sed -n 's/\.json$//p'; }
reset_jobs() { rm -f "$JOBS"/*.json "$JOBS"/*.lock "$JOBS"/*.log "$JOBS/blocked" 2>/dev/null; : > "$GATELOG"; }

# ---------------------------------------------------------------------------
echo "a clear command presented as a user chore is converted to a dispatch:"
reset_jobs
cat > "$T/resp1.txt" <<'EOF'
The tidy timer went stale overnight; the fix is known.
---DISPLAY---
The unit lost its schedule when the session bounced.

You'll need to run this yourself:
```
systemctl --user restart deskcrab-tidy.timer
```
The rest of the queue is healthy.
EOF
gate_split "$T/resp1.txt" "$T/out/r1"
check_eq "exactly one job was dispatched" "$(jobs_count)" "1"
ID1="$(job_ids | head -1)"
check "the display half no longer carries the command" \
    bash -c '! grep -q "systemctl --user restart" "$1"' _ "$T/out/r1.display"
check "the display half no longer assigns the chore" \
    bash -c '! grep -qi "you.ll need to run" "$1"' _ "$T/out/r1.display"
check "the display names the job instead" grep -q "detached job $ID1" "$T/out/r1.display"
check "the conversation form is gated the same way" \
    bash -c '! grep -q "systemctl --user restart" "$1"' _ "$T/out/r1.text"
check "the benign display line survives" grep -q "queue is healthy" "$T/out/r1.display"
check "the spoken half is untouched" \
    grep -q "tidy timer went stale overnight" "$T/out/r1.spoken"
check "the job brief carries the chore lines" \
    bash -c '"$1/lib/job-status" get "$2/$3.json" description | grep -q "systemctl --user restart deskcrab-tidy.timer"' \
    _ "$REPO" "$JOBS" "$ID1"
check "the trace says fired" grep -q "fired: job $ID1" "$GATELOG"

echo
echo "the ambiguous 'Also unset: TIDY_CLAIMS_ROOTS' shape is a chore as it reads:"
reset_jobs
cat > "$T/resp2.txt" <<'EOF'
The tidy claims check is settled.
---DISPLAY---
The stale unit was the whole story.
Also unset: TIDY_CLAIMS_ROOTS
EOF
gate_split "$T/resp2.txt" "$T/out/r2"
check_eq "one job dispatched for the ambiguous line" "$(jobs_count)" "1"
ID2="$(job_ids | head -1)"
check "the instruction-reading line left the display" \
    bash -c '! grep -q "Also unset: TIDY_CLAIMS_ROOTS" "$1"' _ "$T/out/r2.display"
check "the job carries it instead" \
    bash -c '"$1/lib/job-status" get "$2/$3.json" description | grep -q "TIDY_CLAIMS_ROOTS"' \
    _ "$REPO" "$JOBS" "$ID2"
check "the settled statement above it survives" \
    grep -q "the whole story" "$T/out/r2.display"

echo
echo "benign command mentions pass byte-identical, nothing dispatched:"
reset_jobs
cat > "$T/resp3.txt" <<'EOF'
All green; nothing owed.
---DISPLAY---
I ran `git diff --check`; it was clean.
The suite runs via `bash tests/test_eng_records.sh`.
`crab eng list --state all` is the way in.
TIDY_CLAIMS_ROOTS is also unset.
EOF
gate_split "$T/resp3.txt" "$T/out/r3"
check_eq "no job was dispatched" "$(jobs_count)" "0"
check_eq "the display half is byte-identical" \
    "$(cat "$T/out/r3.display")" \
    "$(printf '%s\n' "$(sed -n '/^---DISPLAY---$/,$p' "$T/resp3.txt" | sed '1d')")"
check "the trace says clean" grep -q "clean" "$GATELOG"

echo
echo "two chore blocks in one reply are ONE job:"
reset_jobs
cat > "$T/resp4.txt" <<'EOF'
Two loose ends tonight.
---DISPLAY---
Run this when you're back:
    systemctl --user start deskcrab-tidy.timer
The journal itself is fine.
Also unset: TIDY_CLAIMS_ROOTS
EOF
gate_split "$T/resp4.txt" "$T/out/r4"
check_eq "exactly one job for both blocks" "$(jobs_count)" "1"
ID4="$(job_ids | head -1)"
check_eq "both blocks were replaced with the notice" \
    "$(grep -c "detached job $ID4" "$T/out/r4.display")" "2"
check "neither chore line remains" \
    bash -c '! grep -qE "systemctl --user start|Also unset" "$1"' _ "$T/out/r4.display"
check "the middle benign line survives" grep -q "journal itself is fine" "$T/out/r4.display"
check "the one brief carries both" \
    bash -c '"$1/lib/job-status" get "$2/$3.json" description | grep -q "deskcrab-tidy.timer.*TIDY_CLAIMS_ROOTS"' \
    _ "$REPO" "$JOBS" "$ID4"

echo
echo "the spoken half is out of the gate's reach (no display, no scan):"
reset_jobs
printf 'You will need to run `crab tidy` yourself, I think.\n' > "$T/resp5.txt"
gate_split "$T/resp5.txt" "$T/out/r5"
check_eq "nothing dispatched for a spoken-only reply" "$(jobs_count)" "0"
check "the spoken half is untouched" grep -q "crab tidy" "$T/out/r5.spoken"

echo
echo "CHORE_GATE=0 switches the gate off whole:"
reset_jobs
gate_split "$T/resp1.txt" "$T/out/r6" CHORE_GATE=0
check_eq "no job with the gate off" "$(jobs_count)" "0"
check "the display keeps the command with the gate off" \
    grep -q "systemctl --user restart" "$T/out/r6.display"

echo
echo "a refused dispatch fails open — the reply goes out as written:"
reset_jobs
printf '%s\t%s\n' "$(date +%s)" "test block: the last job never began" > "$JOBS/blocked"
gate_split "$T/resp1.txt" "$T/out/r7"
check_eq "no job through the block marker" "$(jobs_count)" "0"
check "the chore stayed on screen rather than vanishing" \
    grep -q "systemctl --user restart" "$T/out/r7.display"
check "the trace names the fail-open" grep -q "fail-open" "$GATELOG"
rm -f "$JOBS/blocked"

echo
echo "end to end: a desk turn's display file and conversation are gated:"
reset_jobs
cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$T/work"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
EOF
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
python3 - <<'PYEOF'
import json
text = ("The tidy timer went stale; I wrote up the fix.\n"
        "---DISPLAY---\n"
        "You'll need to run this yourself:\n"
        "```\n"
        "systemctl --user restart deskcrab-tidy.timer\n"
        "```\n")
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result"}))
PYEOF
EOF
"$REPO/crab" "what happened to the tidy timer" >/dev/null 2>&1 || true
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
check_eq "the desk turn dispatched exactly one job" "$(jobs_count)" "1"
ID8="$(job_ids | head -1)"
DISPFILE="$(ls "${DESKCRAB_STATE_PREFIX}"-display-*.md 2>/dev/null | head -1)"
check "a display file was written" test -n "$DISPFILE"
if [ -n "$DISPFILE" ]; then
    check "the display file carries no forbidden instruction" \
        bash -c '! grep -q "systemctl --user restart" "$1"' _ "$DISPFILE"
    check "the display file names the job" grep -q "detached job $ID8" "$DISPFILE"
fi
check "the conversation carries no forbidden instruction" \
    bash -c '! grep -q "systemctl --user restart" "$1"' _ "$CONVO"
check "the conversation names the job" grep -q "detached job $ID8" "$CONVO"
check "the spoken half still reached the speakers" \
    grep -q "tidy timer went stale" "$SANDBOX_SPOKEN_LOG"

# ---------------------------------------------------------------------------
echo
echo "a record touch ending at inability dispatches one builder and attaches the id:"
reset_jobs
RID="$(E new "The stale tidy unit after a session bounce")"
OUT="$(E touch "$RID" "Traced it: the timer died with the session and never rearmed. I cannot fix this from here.")"
check_eq "exactly one job dispatched" "$(jobs_count)" "1"
RJOB="$(job_ids | head -1)"
check "the sidecar stands against the record" \
    bash -c '[ "$("$1/lib/job-status" get "$2/$3.json" record)" = "$4" ]' \
    _ "$REPO" "$JOBS" "$RJOB" "$RID"
check "the job id is durably on the record entry" \
    bash -c 'E_OUT="$(DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3")"; printf "%s" "$E_OUT" | grep -q "job $4 now carries the work"' \
    _ "$ENG" "$REPO" "$RID" "$RJOB"
check "the tool said so on stdout" contains "$OUT" "job $RJOB now carries the work"
ATTACH="$("$REPO/lib/job-status" get "$JOBS/$RJOB.json" record_attached_epoch)"
check "record_attached_epoch is stamped on the sidecar" \
    bash -c 'printf "%s" "$1" | grep -qE "^[0-9]+$"' _ "$ATTACH"
check "the brief names the record and the work" \
    bash -c '"$1/lib/job-status" get "$2/$3.json" description | grep -q "never rearmed"' \
    _ "$REPO" "$JOBS" "$RJOB"

echo
echo "a second inability touch while that job lives names it and starts nothing:"
OUT="$(E touch "$RID" "Still stuck: the rearm path is owned by the login manager, and I can't reach it from here.")"
check_eq "still exactly one job" "$(jobs_count)" "1"
check "the entry names the existing job" contains "$OUT" "job $RJOB already stands against this record"

echo
echo "a record touch ending at the origin's chore shape dispatches too:"
reset_jobs
RID2="$(E new "Tidy claims roots after the bounce")"
E touch "$RID2" 'The claims list is stale. Run when you are back:
    systemctl --user start deskcrab-tidy.timer
Also unset: TIDY_CLAIMS_ROOTS' >/dev/null
check_eq "one job for the chore ending" "$(jobs_count)" "1"
CJOB="$(job_ids | head -1)"
check "the record entry carries the job id" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "job $4 now carries the work"' \
    _ "$ENG" "$REPO" "$RID2" "$CJOB"

echo
echo "benign, conclusive, mid-note-inability and id-carrying notes pass untouched:"
reset_jobs
E touch "$RID" "Fixed: shimmed the rearm, re-ran the suite, twelve passed and none failed." >/dev/null
check_eq "a conclusive note dispatches nothing" "$(jobs_count)" "0"
E touch "$RID" "Thought I couldn't fix it, but the shim landed and the suite is green." >/dev/null
check_eq "inability mid-note is history, not an ending" "$(jobs_count)" "0"
E touch "$RID" "Handed onward already: dispatched as job 20260826-010101-99999, waiting on its outcome. I can't do more here." >/dev/null
check_eq "a note already carrying a job id dispatches nothing" "$(jobs_count)" "0"

echo
echo "a refused dispatch is named on the record and the write survives:"
reset_jobs
printf '%s\t%s\n' "$(date +%s)" "test block" > "$JOBS/blocked"
E touch "$RID" "The rearm still will not hold; I cannot fix this from here." >/dev/null
check_eq "no job through the block marker" "$(jobs_count)" "0"
check "the entry itself names the failed dispatch" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "a job was owed here"' \
    _ "$ENG" "$REPO" "$RID"
check "the note itself still landed" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "will not hold"' \
    _ "$ENG" "$REPO" "$RID"
rm -f "$JOBS/blocked"

# ---------------------------------------------------------------------------
echo
echo "the runner floor: the gate's attach write cannot stand in for the builder's:"
reset_jobs
NOW="$(date +%s)"
# A benign touch stands in for the gate's attach write: last_touched = now.
E touch "$RID" "the attach write itself, benign wording, nothing owed" >/dev/null
"$REPO/lib/job-status" new "$JOBS" recf1 "carry the stale-unit ending" ""
"$REPO/lib/job-status" set "$JOBS/recf1.json" record="$RID" \
    started_epoch=$((NOW - 60)) record_attached_epoch=$((NOW + 5))
sandbox_stub claude <<'EOF'
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"looked around; wrote nothing back."}]}}'
printf '%s\n' '{"type":"result","result":"done"}'
exit 0
EOF
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO/lib/job-runner" recf1 "$T/work" >/dev/null 2>&1
check_eq "a builder that never wrote back still ends failed" \
    "$("$REPO/lib/job-status" get "$JOBS/recf1.json" state)" "failed"
check "the log names the untouched record" \
    grep -q "engineering record '$RID' was never updated" "$JOBS/recf1.log"

echo
echo "and a builder that really writes back and submits still finishes past the floor:"
# Touch alone no longer finishes a record job: the completion review
# (engineering-records.md rule 16, jobs.md rule 29a) wants the claim
# SUBMITTED, so the well-behaved stub ends with `crab eng review`.
NOW="$(date +%s)"
"$REPO/lib/job-status" new "$JOBS" recf2 "carry the ending, properly" ""
"$REPO/lib/job-status" set "$JOBS/recf2.json" record="$RID" \
    started_epoch=$((NOW - 60)) record_attached_epoch=$((NOW))
sandbox_stub claude <<STUB
#!/bin/bash
cat > /dev/null
sleep 3
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" touch "$RID" "rearmed the timer and watched it fire; suite green" >/dev/null 2>&1
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" review "$RID" "rearmed the timer, watched it fire, suite green — submitting" >/dev/null 2>&1
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"rearmed and verified."}]}}'
printf '%s\n' '{"type":"result","result":"done"}'
exit 0
STUB
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO/lib/job-runner" recf2 "$T/work" >/dev/null 2>&1
check_eq "the builder's own entry and submission satisfy the hook" \
    "$("$REPO/lib/job-status" get "$JOBS/recf2.json" state)" "collected"

echo
echo "summary: $PASS passed, $FAIL failed"
