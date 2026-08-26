#!/bin/bash
# The engineering completion review (specs/engineering-records.md rules 16-16d,
# specs/jobs.md rules 29a-29b). Run: bash tests/test_eng_review.sh
#
# The originating failure (2026-08-26, record
# the-chess-table-maintains-a-second-conversation): the ask was the chess
# table as a thin client of the phone's VISIBLE conversation interface; the
# builder delivered shared audio plumbing — a clip-queue module both pages
# load — and the record was SETTLED on it as "shared-primitive parity".
# Narrowed work that settles its own ask reads as the ask delivered, and
# nobody is ever brought back to the gap.
#
# The contract under test:
#   - a builder (DESKCRAB_ENG_ROLE=builder) is refused settle, kill, accept
#     and reject; its one door is `crab eng review`, and a submission leaves
#     the record UNSETTLED — partial or narrowed work cannot settle the ask;
#   - the completion wake of a submitted job is the review brief, booked at
#     the JOB_REVIEW_EFFORT override, and a clean record build that never
#     submitted ends failed naming the submission owed;
#   - reject returns the record to open and PRESERVES the missing
#     requirements, verbatim, on the entry and on the redispatched brief;
#   - accept settles the record with the verdict on settled_by;
#   - a reject whose dispatch does not land keeps the rejection anyway.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JOBS="$JOBS_DIR"
ENG="$XDG_DATA_HOME/deskcrab/engineering/records"
mkdir -p "$JOBS" "$T/work"
E() { DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" "$@"; }
jobs_count() { ls "$JOBS" 2>/dev/null | grep -c '\.json$'; }
reset_jobs() { rm -f "$JOBS"/*.json "$JOBS"/*.lock "$JOBS"/*.log "$JOBS/blocked" 2>/dev/null; }

ASK="Make the chess table a thin client of the phone's visible conversation \
interface: a typed table message and its reply must appear through the SAME \
conversation log UI the phone renders. Acceptance: the table page loads the \
phone conversation interface and renders replies in it; shared plumbing \
alone does not satisfy this."

# ---------------------------------------------------------------------------
echo "a submission moves the record to review and settles nothing:"
RID="$(E new "The chess table must reuse the phone conversation interface" --body "$ASK")"
NOW0=$(date +%s)
sleep 1
OUT="$(E review "$RID" "extracted the clip queue into a shared module; both pages load it — playback parity")"
check "the tool says the record is not settled" contains "$OUT" "NOT settled"
check_eq "state is review" "$(E field "$RID" state)" "review"
check_eq "settled_by stays empty" "$(E field "$RID" settled_by)" ""
check "the claim is on the record" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "Submitted for review: extracted the clip queue"' \
    _ "$ENG" "$REPO" "$RID"
check "the submission bumped last_touched" E touched-since "$RID" "$NOW0"
check "the prompt renders it live and marked, never as resolved" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" prompt | grep -q "in review — completion claimed, NOT settled"' \
    _ "$ENG" "$REPO"
check "and among the OPEN threads, not the settled tail" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" prompt | sed -n "/OPEN/,/SETTLED/p" | grep -q "$3"' \
    _ "$ENG" "$REPO" "$RID"

echo
echo "the builder role is refused every verdict verb, and the state stands:"
OUT="$(DESKCRAB_ENG_ROLE=builder E settle "$RID" "shared plumbing landed, calling it parity" 2>&1)" && RC=0 || RC=$?
check "a builder settle is refused" test "$RC" -ne 0
check "the refusal names the review door" contains "$OUT" "crab eng review"
check_eq "and the record is still in review" "$(E field "$RID" state)" "review"
OUT="$(DESKCRAB_ENG_ROLE=builder E kill "$RID" "impossible after all" 2>&1)" && RC=0 || RC=$?
check "a builder kill is refused" test "$RC" -ne 0
check "that refusal names the door too" contains "$OUT" "crab eng review"
check_eq "state stands after the kill refusal" "$(E field "$RID" state)" "review"
OUT="$(DESKCRAB_ENG_ROLE=builder E accept "$RID" "my own work looks complete" 2>&1)" && RC=0 || RC=$?
check "a builder accepting its own submission is refused" test "$RC" -ne 0
OUT="$(DESKCRAB_ENG_ROLE=builder E reject "$RID" "nothing missing" 2>&1)" && RC=0 || RC=$?
check "a builder rejecting is refused" test "$RC" -ne 0
check_eq "still in review" "$(E field "$RID" state)" "review"

echo
echo "without the role marker the same hands keep every verb (rule 16d):"
RIDX="$(E new "A thread the user settles by hand" --body "an ask")"
OUT="$(E settle "$RIDX" "the user's own call")" && RC=0 || RC=$?
check "an ungated settle is not refused" test "$RC" -eq 0
check_eq "and lands" "$(E field "$RIDX" state)" "settled"

echo
echo "accept and reject judge only a submission:"
RID2="$(E new "A second thread, open, never submitted" --body "an ask")"
OUT="$(E accept "$RID2" verified 2>&1)" && RC=0 || RC=$?
check "accept on an open record is refused" test "$RC" -ne 0
check "naming the submission it expects" contains "$OUT" "not in review"
OUT="$(E reject "$RID2" missing 2>&1)" && RC=0 || RC=$?
check "reject on an open record is refused" test "$RC" -ne 0

echo
echo "reject reopens the record and preserves the missing requirements on the redispatch:"
reset_jobs
MISSING="the visible conversation interface was never reused: table messages still render in a parallel stack, and a shared audio clip queue is not the conversation log UI the ask names. Missing: the table page rendering the phone conversation interface"
OUT="$(E reject "$RID" "$MISSING")"
check_eq "the record is open again" "$(E field "$RID" state)" "open"
check "the missing requirements are preserved on the entry" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "Missing: the table page rendering the phone conversation interface"' \
    _ "$ENG" "$REPO" "$RID"
check_eq "exactly one job was redispatched" "$(jobs_count)" "1"
NEWID="$(printf '%s\n' "$OUT" | sed -n 's/^redispatched as job \([^ ]*\).*/\1/p')"
check "the tool names the redispatched job" test -n "$NEWID"
check "the job id landed on the reject entry" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "job $4 now carries the missing requirements"' \
    _ "$ENG" "$REPO" "$RID" "$NEWID"
check "the brief carries the missing requirements verbatim" \
    bash -c '"$1/lib/job-status" get "$2/$3.json" description | grep -q "the table page rendering the phone conversation interface"' \
    _ "$REPO" "$JOBS" "$NEWID"
check "and points at the record for the original ask" \
    bash -c '"$1/lib/job-status" get "$2/$3.json" description | grep -q "crab eng show $4"' \
    _ "$REPO" "$JOBS" "$NEWID"
check_eq "the sidecar carries the record" \
    "$("$REPO/lib/job-status" get "$JOBS/$NEWID.json" record)" "$RID"
check "the attach epoch is stamped, so the reopen cannot pass the runner floor" \
    bash -c 'test -n "$("$1/lib/job-status" get "$2/$3.json" record_attached_epoch)"' \
    _ "$REPO" "$JOBS" "$NEWID"
check "the reopened record renders live, never settled" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" prompt | sed -n "/OPEN/,/SETTLED/p" | grep -q "$3"' \
    _ "$ENG" "$REPO" "$RID"

echo
echo "a reject whose dispatch does not land keeps the rejection (fail open, named):"
RID3="$(E new "A thread whose reject meets a closed door" --body "an ask")"
E review "$RID3" "a claim" >/dev/null
reset_jobs
OUT="$(DESKCRAB_NO_DISPATCH=1 E reject "$RID3" "one missing piece, named")"
check_eq "the record is open again anyway" "$(E field "$RID3" state)" "open"
check "the un-landed dispatch is named on the entry" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "the redispatch did not land"' \
    _ "$ENG" "$REPO" "$RID3"
check "the missing requirement still stands on the entry" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "Missing: one missing piece, named"' \
    _ "$ENG" "$REPO" "$RID3"
check_eq "and nothing was dispatched" "$(jobs_count)" "0"

echo
echo "accept settles the record with the verdict on settled_by:"
E review "$RID3" "the missing piece was delivered and verified" >/dev/null
OUT="$(E accept "$RID3" "inspected the artefact against the opening ask; delivered whole")"
check_eq "settled" "$(E field "$RID3" state)" "settled"
check "settled_by carries the review verdict" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" field "$3" settled_by | grep -q "^review accepted: inspected the artefact"' \
    _ "$ENG" "$REPO" "$RID3"

# ---------------------------------------------------------------------------
echo
echo "the 2026-08-26 regression, end to end: substituted plumbing cannot settle the ask:"
reset_jobs
RID4="$(E new "The table chat must be a thin client of the phone conversation interface" --body "$ASK")"
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${SANDBOX_CLAUDE_LOG:-/dev/null}"
cat > /dev/null
sleep 1
printf '%s' "\${DESKCRAB_ENG_ROLE:-}" > "$T/witness-role.txt"
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" settle "$RID4" "shared audio plumbing landed; shared-primitive parity, settled" >/dev/null 2>&1
printf '%s' "\$?" > "$T/witness-settle.rc"
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" touch "$RID4" "extracted the clip queue into one module both pages load; suites green" >/dev/null 2>&1
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" review "$RID4" "delivered shared audio plumbing: one clip-queue module both pages load; playback parity proven" >/dev/null 2>&1
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"parity reached; submitted."}]}}'
printf '%s\n' '{"type":"result","result":"done"}'
exit 0
STUB
"$REPO/lib/job-status" new "$JOBS" rev1 "make the chess table reuse the phone conversation interface" ""
"$REPO/lib/job-status" set "$JOBS/rev1.json" record="$RID4"
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO/lib/job-runner" rev1 "$T/work" >/dev/null 2>&1
check_eq "the builder session carried the role marker" \
    "$(cat "$T/witness-role.txt" 2>/dev/null)" "builder"
check_eq "the builder's settle of its own narrowed work was REFUSED" \
    "$(cat "$T/witness-settle.rc" 2>/dev/null)" "2"
check_eq "the job itself collected — submission is success" \
    "$("$REPO/lib/job-status" get "$JOBS/rev1.json" state)" "collected"
check_eq "but the record is in review, NOT settled" "$(E field "$RID4" state)" "review"
check_eq "settled_by is still empty" "$(E field "$RID4" settled_by)" ""
check "the builder was told to submit, in its prompt" \
    grep -q "crab eng review $RID4" "$SANDBOX_CLAUDE_LOG"
check "and told it cannot settle" \
    grep -q "You CANNOT settle the record" "$SANDBOX_CLAUDE_LOG"
REVWAKE="$(grep -rl "THIS WAKE IS THE REVIEW" "$WAKES_DIR" 2>/dev/null | head -1)"
check "the completion wake is the review brief" test -n "$REVWAKE"
if [ -n "$REVWAKE" ]; then
    check "it says to recover the original ask and acceptance criteria" \
        grep -q "ORIGINAL ask and its acceptance criteria" "$REVWAKE"
    check "it says to inspect the artefact, never the report" \
        grep -q "inspect the actual artefact or the visible behaviour yourself" "$REVWAKE"
    check "it names both verdicts against this record" \
        bash -c 'grep -q "crab eng accept $2" "$1" && grep -q "crab eng reject $2" "$1"' _ "$REVWAKE" "$RID4"
    check "it names substitution as the failure to catch" \
        grep -q "narrowed, or substituted" "$REVWAKE"
    check_eq "booked at the review effort override (medium)" \
        "$(awk -F'\t' '{print $6; exit}' "$REVWAKE")" "medium"
    check_eq "and PINNED to the review model (sol) — a Sol review, never the wake default" \
        "$(awk -F'\t' '{print $7; exit}' "$REVWAKE")" "sol"
fi

echo
echo "the review rejects the substitution; the missing interface rides the next brief:"
reset_jobs
OUT="$(E reject "$RID4" "$MISSING")"
check_eq "the ask is OPEN again — narrowed work settled nothing" \
    "$(E field "$RID4" state)" "open"
NEWID4="$(printf '%s\n' "$OUT" | sed -n 's/^redispatched as job \([^ ]*\).*/\1/p')"
check "the remaining work was redispatched" test -n "$NEWID4"
check "the new brief demands the visible interface, verbatim" \
    bash -c '"$1/lib/job-status" get "$2/$3.json" description | grep -q "the table page rendering the phone conversation interface"' \
    _ "$REPO" "$JOBS" "$NEWID4"
check_eq "against the same record" \
    "$("$REPO/lib/job-status" get "$JOBS/$NEWID4.json" record)" "$RID4"

echo
echo "full delivery, submitted and accepted, settles it:"
E review "$RID4" "the table page now loads the phone conversation interface; a typed message and its reply render in the same log" >/dev/null
E accept "$RID4" "opened the table beside the phone: one conversation log, both messages render in it" >/dev/null
check_eq "settled at last" "$(E field "$RID4" state)" "settled"
check "by the review's verdict" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" field "$3" settled_by | grep -q "^review accepted:"' \
    _ "$ENG" "$REPO" "$RID4"

# ---------------------------------------------------------------------------
echo
echo "a clean record build that never submits ends failed, naming the submission owed:"
reset_jobs
RID5="$(E new "A thread whose builder narrates and never submits" --body "an ask")"
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${SANDBOX_CLAUDE_LOG:-/dev/null}"
cat > /dev/null
sleep 1
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" touch "$RID5" "did the work, ran the suite, all green" >/dev/null 2>&1
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"done."}]}}'
printf '%s\n' '{"type":"result","result":"done"}'
exit 0
STUB
"$REPO/lib/job-status" new "$JOBS" rev2 "a build that touches and never submits" ""
"$REPO/lib/job-status" set "$JOBS/rev2.json" record="$RID5"
WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" "$REPO/lib/job-runner" rev2 "$T/work" >/dev/null 2>&1
RC=$?
check_eq "the sidecar says failed" \
    "$("$REPO/lib/job-status" get "$JOBS/rev2.json" state)" "failed"
check "the runner exited non-zero" test "$RC" -ne 0
check "the log names the missing submission" \
    grep -q "never SUBMITTED it for review" "$JOBS/rev2.log"
check "the completion wake says so too" \
    grep -rq "never SUBMITTED for review" "$WAKES_DIR"
check_eq "and the record is still open" "$(E field "$RID5" state)" "open"
FAILWAKE="$(grep -rl "never SUBMITTED for review" "$WAKES_DIR" 2>/dev/null | head -1)"
if [ -n "$FAILWAKE" ]; then
    check_eq "a non-review completion wake carries no effort override" \
        "$(awk -F'\t' '{print $6; exit}' "$FAILWAKE")" ""
    check_eq "and no model pin either — a review is owed only to a claim" \
        "$(awk -F'\t' '{print $7; exit}' "$FAILWAKE")" ""
fi

# ---------------------------------------------------------------------------
echo
echo "a review-model name the record could not carry clamps back to sol:"
reset_jobs
rm -f "$WAKES_DIR"/*.wake
RID6="$(E new "A thread whose review model knob went bad" --body "an ask")"
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${SANDBOX_CLAUDE_LOG:-/dev/null}"
cat > /dev/null
sleep 1
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" touch "$RID6" "did the work" >/dev/null 2>&1
DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" review "$RID6" "a claim to judge" >/dev/null 2>&1
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"submitted."}]}}'
printf '%s\n' '{"type":"result","result":"done"}'
exit 0
STUB
"$REPO/lib/job-status" new "$JOBS" rev3 "a build whose review model knob is broken" ""
"$REPO/lib/job-status" set "$JOBS/rev3.json" record="$RID6"
JOB_REVIEW_MODEL="two words" WANTS_FILE="$XDG_DATA_HOME/deskcrab/wants.md" \
    "$REPO/lib/job-runner" rev3 "$T/work" >/dev/null 2>&1
REVWAKE6="$(grep -rl "THIS WAKE IS THE REVIEW" "$WAKES_DIR" 2>/dev/null | head -1)"
check "the review wake still booked" test -n "$REVWAKE6"
if [ -n "$REVWAKE6" ]; then
    check_eq "pinned to sol, never to a name the record cannot hold" \
        "$(awk -F'\t' '{print $7; exit}' "$REVWAKE6")" "sol"
fi

# ---------------------------------------------------------------------------
echo
echo "the reject race: the rejection is on disk before the redispatched builder runs,"
echo "and a FAST builder's writes during the dispatch window survive the annotation:"
reset_jobs
rm -f "$WAKES_DIR"/*.wake
RID7="$(E new "A thread whose reject races its own fast builder" --body "$ASK")"
E review "$RID7" "narrowed work, submitted" >/dev/null
# The fast builder IS the dispatch: job dispatch reaches systemd-run with
# lib/job-runner on the argv, synchronously inside cmd_reject's window — the
# stub photographs what the record says at that instant, then writes onto the
# thread as the redispatched builder would (role exported, touch, submission),
# all BEFORE cmd_reject gets to annotate the job id. Exit 0 so no setsid
# fallback doubles the builder. Timer shapes keep the shipped stub's answer.
sandbox_stub systemd-run <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${SANDBOX_SYSTEMD_LOG:-/dev/null}"
case " \$* " in
    *" --on-active="*|*" --on-calendar="*) exit 0 ;;
esac
case " \$* " in
    *"job-runner"*)
        DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" field "$RID7" state > "$T/race-state-at-dispatch.txt" 2>&1
        DESKCRAB_ENG_DIR="$ENG" python3 "$REPO/lib/eng" show "$RID7" > "$T/race-show-at-dispatch.txt" 2>&1
        DESKCRAB_ENG_DIR="$ENG" DESKCRAB_ENG_ROLE=builder python3 "$REPO/lib/eng" \
            touch "$RID7" "fast builder: delivered the visible interface, suites green" >/dev/null 2>&1
        DESKCRAB_ENG_DIR="$ENG" DESKCRAB_ENG_ROLE=builder python3 "$REPO/lib/eng" \
            review "$RID7" "fast builder: the table page now renders the phone conversation log" >/dev/null 2>&1
        exit 0
        ;;
esac
exit 1
STUB
MISSING7="the table page rendering the phone conversation interface is still owed"
OUT="$(E reject "$RID7" "$MISSING7")"
check_eq "at the moment the dispatch ran, the record was already OPEN" \
    "$(cat "$T/race-state-at-dispatch.txt" 2>/dev/null)" "open"
check "and already carried the missing requirements" \
    grep -q "Missing: the table page rendering the phone conversation interface is still owed" \
    "$T/race-show-at-dispatch.txt"
NEWID7="$(printf '%s\n' "$OUT" | sed -n 's/^redispatched as job \([^ ]*\).*/\1/p')"
check "the redispatch landed" test -n "$NEWID7"
check "the fast builder's touch SURVIVES the job-id annotation" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "fast builder: delivered the visible interface"' \
    _ "$ENG" "$REPO" "$RID7"
check "the fast builder's submission survives too" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "Submitted for review: fast builder: the table page"' \
    _ "$ENG" "$REPO" "$RID7"
check_eq "the state is the builder's review, not the stale pre-dispatch open" \
    "$(E field "$RID7" state)" "review"
check "the rejection entry still stands, missing requirements verbatim" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "Missing: $4"' \
    _ "$ENG" "$REPO" "$RID7" "$MISSING7"
check "with the job id landed on it" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "job $4 now carries the missing requirements"' \
    _ "$ENG" "$REPO" "$RID7" "$NEWID7"
check "the builder last_touched stands — the annotation bumped nothing" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -A2 "^## $(DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" field "$3" last_touched)$" | grep -q "Submitted for review: fast builder"' \
    _ "$ENG" "$REPO" "$RID7"

echo
echo "the same race with a builder that only touches: the reopen stands, the touch survives:"
reset_jobs
RID8="$(E new "A thread whose fast builder writes progress only" --body "an ask")"
E review "$RID8" "a claim" >/dev/null
sandbox_stub systemd-run <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${SANDBOX_SYSTEMD_LOG:-/dev/null}"
case " \$* " in
    *" --on-active="*|*" --on-calendar="*) exit 0 ;;
esac
case " \$* " in
    *"job-runner"*)
        DESKCRAB_ENG_DIR="$ENG" DESKCRAB_ENG_ROLE=builder python3 "$REPO/lib/eng" \
            touch "$RID8" "fast builder: started, first findings on the thread" >/dev/null 2>&1
        exit 0
        ;;
esac
exit 1
STUB
OUT="$(E reject "$RID8" "one named gap")"
check_eq "the record stands open" "$(E field "$RID8" state)" "open"
check "the concurrent touch survives" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "fast builder: started, first findings"' \
    _ "$ENG" "$REPO" "$RID8"
check "the rejection and its annotation stand whole" \
    bash -c 'DESKCRAB_ENG_DIR="$1" python3 "$2/lib/eng" show "$3" | grep -q "Missing: one named gap"' \
    _ "$ENG" "$REPO" "$RID8"
cp "$DESKCRAB_SANDBOX_LIB/stubs/systemd-run" "$SANDBOX_BIN/systemd-run"
chmod +x "$SANDBOX_BIN/systemd-run"

echo
echo "summary: $PASS passed, $FAIL failed"
