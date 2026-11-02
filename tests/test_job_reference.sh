#!/bin/bash
# Which job he means, and what its record says — specs/jobs.md rules 46-47c,
# prompt-assembly.md rule 36d, turn-pipeline.md rule 32g, wake-queue.md rule
# 43c. Run: bash tests/test_job_reference.sh
#
# The evening of 2026-08-21, rebuilt from the day's journal: a similar-game
# builder dispatched at 17:34 ran twenty minutes, exited 0 with one commit and
# was collected; an errand builder dispatched at 18:01 was stopped at fifty-six
# seconds. At 18:09 the user referred in plain words to the similar-game one
# ("the similar game thing that you just connected in") and the reply said,
# three times running, "I killed that builder two minutes in" — the fate of
# the OTHER builder, the more recent one, resolved from memory. Every job had
# a record the whole time.
#
# Two hands are proven here. The job-reference layer: his words resolve the
# prompt's candidate list to the finished builder, never to the fresher one,
# and the layer rides the real turn prompt. The claim gate: the 18:09 reply is
# ruled a MISMATCH against the record, ledgered, and corrected by a wake
# quoting the record, while the supported kill, the self-correction and a
# supported finish book nothing; no record in the window is UNBACKED, never a
# fate; an ambiguous reference accuses only when no candidate holds the fate;
# and the gate fires from the actual delivery path. No model is ever spent.
#
# The review of the first landing (2026-11-02) kept a fixture that proved three
# gaps, rebuilt here as a scratch ledger: a telescope-calibration builder
# finished with exit 0 and NO commits field, on which "committed the repair"
# was certified SUPPORTED (finished is not committed, and unknown is not
# evidence); "the builder ran" claimed nothing at all, and the pre-check grep
# never admitted the shape; and "finished. It was killed before committing
# anything." judged the finish and dropped the false kill for want of a noun
# in its own sentence.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$JOBS_DIR"
JOURNAL="$DAY_JOURNAL_DIR"
JS="$REPO/lib/job-status"
RES="$REPO/lib/job-resolve"
CHK="$REPO/lib/job-claim-check"
W="$WAKES_DIR"
mkdir -p "$J" "$JOURNAL" "$W" "$T/repo" "$T/home"
NOW="$(date +%s)"
lacks() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

mkjob() {  # <id> <state> <started-epoch> <ran-seconds> <description>
    "$JS" new "$J" "$1" "$5" "" "$T/repo" dispatched >/dev/null
    "$JS" set "$J/$1.json" state="$2" started_epoch="$3" finished_epoch="$(( $3 + $4 ))" >/dev/null
}

# The two builders of the evening. The similar-game one is OLDER; the errand
# one is the fresher, which is exactly what made it the wrong answer.
SIM="20260821-173439-1130947"
ERR="20260821-180156-1270400"
mkjob "$SIM" collected "$(( NOW - 7200 ))" 1204 \
    "Wire similar-game retrieval into the live chess move prompt. Right now lib/chess_mover.py never imports lib/chess_similar.py at all — the only caller is the hand-typed similar command. So in a real game, similar-position help has NEVER reached the move prompt."
"$JS" set "$J/$SIM.json" exit=0 branch=phone-context-seed \
    collection="collected: 1 commit on phone-context-seed (1 unpushed); 10 dirty files; tests: 31 passed, 0 failed" >/dev/null
"$JS" append "$J/$SIM.json" commits "ab12cd3 Wire similar-game retrieval into the move prompt" >/dev/null
mkjob "$ERR" stopped "$(( NOW - 5400 ))" 56 \
    "Build on-done errands for jobs, so a promise made at dispatch time survives to the completion wake. The user ordered this fixed directly after tonight's failure: a message to a friend was promised for when the wiring job exited, the job exited, and the completion wake arrived holding nothing."

# His words and hers, from the journal (names removed).
MSG_1809="I want to talk about the similar game thing. that you just connected in better. Do you think it is going to be useful and does it show things in a clear actionable way for you when you're doing your moves? Like, do you think it'll actually resolve the problem?"
REPLY_1809="Nothing got connected, in fact — I killed that builder two minutes in, so \`similar\` is still exactly where it was. Which makes your question the better one to answer and my answer is: no, I don't think it resolves it on its own."
MSG_1802="This one's probably-- You stopped yourself just now instead of the builder."
REPLY_1802="The builder is stopped — I killed it about two minutes in, before it committed anything, so there's nothing half-landed in the tree from it. The record's still open and marked for tonight, so the work happens when I sleep, the way you said."
MSG_1810="You did not kill the builder two minutes in. Stop saying that."
REPLY_1810="Drattit — I mixed up two builders. I just looked at the record: the similar-game builder ran the full twenty minutes, committed its work, and was collected this evening. The one I killed at fifty-six seconds was the other builder, the errand one from an hour later, and I've been pasting its death onto the wrong job for three replies straight."

refs()   { python3 "$RES" refs "$J" "$JOURNAL" 72 5 "$1"; }
claims() { python3 "$RES" claims "$J" "$JOURNAL" 72 "$2" "$1"; }
first_line_with() { printf '%s\n' "$1" | grep -m1 -n -- "$2" | cut -d: -f1; }

echo "the reference layer resolves by his words, never by recency (rules 46-46a):"
OUT="$(refs "$MSG_1809")"
check "his 18:09 words raise the layer" test -n "$OUT"
check "the finished builder is the first candidate" \
    bash -c 'printf "%s\n" "$1" | grep -q "^  1\. job $2 "' _ "$OUT" "$SIM"
check "and the resolution is named clear" contains "$OUT" "That is the job; its line above is its fate"
check "its line carries the collected state" \
    bash -c 'printf "%s\n" "$1" | grep "^  1\. " | grep -q "collected"' _ "$OUT"
check "and the commit" \
    bash -c 'printf "%s\n" "$1" | grep "^  1\. " | grep -q "1 commit on phone-context-seed"' _ "$OUT"
check "and the runtime" \
    bash -c 'printf "%s\n" "$1" | grep "^  1\. " | grep -q "ran 20m04s"' _ "$OUT"
check "the fresher, killed builder is listed as NOT the referent" \
    bash -c 'printf "%s\n" "$1" | grep -A1 "do NOT name" | grep -q "$2"' _ "$OUT" "$ERR"
check "and nowhere in the candidate list" \
    bash -c '! printf "%s\n" "$1" | grep "^  [0-9]\. " | grep -q "$2"' _ "$OUT" "$ERR"
check "the block says the words did the resolving" contains "$OUT" "matched on"

echo
echo "a bare 'the builder' lists the window newest first and says recency is not identity:"
OUT="$(refs "$MSG_1802")"
check "the layer is raised" test -n "$OUT"
check "the fresher builder leads the list" \
    bash -c 'printf "%s\n" "$1" | grep -q "^  1\. job $2 "' _ "$OUT" "$ERR"
check "the older one follows" \
    bash -c 'printf "%s\n" "$1" | grep -q "^  2\. job $2 "' _ "$OUT" "$SIM"
check "and the block says recency is not identity" contains "$OUT" "recency is not identity"
check "and tells her to ask rather than pick" contains "$OUT" "if not, ask"

echo
echo "a job named by id resolves exactly; a day job raises no layer:"
OUT="$(refs "what happened to $SIM in the end?")"
check "the id names the job" \
    bash -c 'printf "%s\n" "$1" | grep -q "^  1\. job $2 "' _ "$OUT" "$SIM"
check "and says so" contains "$OUT" "named by id"
check_eq "a good job interview is not a job" "$(refs "I had a good job interview today, and my job is fine")" ""
check_eq "a sentence about nothing job-shaped is silent" "$(refs "How has chess been going today?")" ""
check_eq "a message with no words at all is silent" "$(refs "")" ""

echo
echo "the journal fills in a builder the ledger has pruned:"
printf '%s\n' "{\"epoch\": $(( NOW - 36000 )), \"time\": \"x\", \"kind\": \"job\", \"duration\": 900, \"user\": \"Repaint the phone metrics page so the token ledger reads per attempt, with the backfill verb beside it.\", \"reply\": \"done\", \"pid\": 1, \"outcome\": \"collected (exit 0)\"}" \
    > "$JOURNAL/$(date -d "@$(( NOW - 36000 ))" +%F).jsonl"
OUT="$(refs "how did the metrics page builder go, the token ledger one")"
check "the pruned builder has a line from the journal" contains "$OUT" "sidecar pruned"
check "with its outcome" \
    bash -c 'printf "%s\n" "$1" | grep "journal-" | grep -q "collected"' _ "$OUT"
check "and it is the first candidate — the words, not the ledger, decide" \
    bash -c 'printf "%s\n" "$1" | grep "^  1\. " | grep -q "journal-"' _ "$OUT"
rm -f "$JOURNAL"/*.jsonl

echo
echo "the layer rides the assembled turn prompt, between interrupt and dispute, and no other (rule 36d):"
cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WAKE_QUIET_HOURS=""
EOF
printf '%s' "$MSG_1809" > "$T/msg-1809.txt"
MAN="$(sandbox_bash 'PROMPT_JOBREF="$(_jobref_context "$(cat '"$T/msg-1809.txt"')")"; build_system_prompt --profile turn --layers')"
check "the manifest carries the layer, present" \
    bash -c 'printf "%s\n" "$1" | awk -F"\t" "\$1 == \"jobref\" && \$4 != \"absent\"" | grep -q .' _ "$MAN"
I="$(first_line_with "$MAN" "^interrupt")"; R="$(first_line_with "$MAN" "^jobref")"; D="$(first_line_with "$MAN" "^dispute")"
check "and it sits between the interrupt and dispute rows ($I < $R < $D)" \
    bash -c '[ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]' _ "${I:-0}" "${R:-0}" "${D:-0}"
BODY="$(sandbox_bash 'PROMPT_JOBREF="$(_jobref_context "$(cat '"$T/msg-1809.txt"')")"; build_system_prompt --profile turn')"
check "the prompt body carries the block" contains "$BODY" "HE IS REFERRING TO A JOB"
check "naming the finished builder" contains "$BODY" "1. job $SIM"
MAN_W="$(sandbox_bash 'PROMPT_JOBREF="$(_jobref_context "$(cat '"$T/msg-1809.txt"')")"; build_system_prompt --profile wake --layers')"
check "a wake prompt never carries it" \
    bash -c 'printf "%s\n" "$1" | awk -F"\t" "\$1 == \"jobref\"" | grep -q absent' _ "$MAN_W"
MAN_0="$(sandbox_bash 'build_system_prompt --profile turn --layers')"
check "and without a reference the layer is absent" \
    bash -c 'printf "%s\n" "$1" | awk -F"\t" "\$1 == \"jobref\"" | grep -q absent' _ "$MAN_0"
check "the grep gate admits his 18:09 words" \
    sandbox_bash 'job_reference_precheck "$(cat '"$T/msg-1809.txt"')"'
sandbox_bash 'job_reference_precheck "I had a good job interview today"'; RC=$?
check_eq "and declines a day job" "$RC" "1"
OFF="$(JOB_REF_LAYER=0 sandbox_bash '_jobref_context "$(cat '"$T/msg-1809.txt"')"')"
check_eq "the layer can be switched off in the conf" "$OFF" ""

echo
echo "the claim gate: the 18:09 reply is a MISMATCH against the builder his words named (rule 47):"
OUT="$(claims "$MSG_1809" "$REPLY_1809")"
check_eq "one claim, one verdict" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
check_eq "and it is MISMATCH" "$(printf '%s\n' "$OUT" | cut -f1)" "MISMATCH"
check_eq "the fate claimed was stopped" "$(printf '%s\n' "$OUT" | cut -f2)" "stopped"
check_eq "against the finished builder — the one his words named, not the fresher one" \
    "$(printf '%s\n' "$OUT" | cut -f3)" "$SIM"
check "the record line says collected with the commit" \
    bash -c 'printf "%s\n" "$1" | cut -f4 | grep -q "collected.*1 commit"' _ "$OUT"
check "the claim rides verbatim" contains "$OUT" "I killed that builder two minutes in"
"$CHK" inspect "$J" "$JOURNAL" "$MSG_1809" "$REPLY_1809" >/dev/null 2>&1; RC=$?
check_eq "inspect exits 3 on a mismatch" "$RC" "3"

echo
echo "the 18:02 kill is SUPPORTED — a bare reference, and a fate the stopped builder holds:"
OUT="$(claims "$MSG_1802" "$REPLY_1802")"
check "verdicts were reached" test -n "$OUT"
check "none of them accuses — no MISMATCH, no UNBACKED" \
    bash -c '! printf "%s\n" "$1" | grep -q "^MISMATCH\|^UNBACKED"' _ "$OUT"
check "the kill resolved to the errand builder" \
    bash -c 'printf "%s\n" "$1" | grep "^SUPPORTED	stopped	$2" | grep -q .' _ "$OUT" "$ERR"
check "'before it committed anything' is a negated commit claim the stopped run's record never observed: UNVERIFIED, not certified" \
    bash -c 'printf "%s\n" "$1" | grep "^UNVERIFIED	not committed	" | grep -q "no commit observation"' _ "$OUT"
check "and its record line says the commits are unobserved, not absent" \
    bash -c 'printf "%s\n" "$1" | grep "^UNVERIFIED	not committed	" | grep -q "commits unobserved (not collected)"' _ "$OUT"
check "'nothing half-landed in the tree' is not a finish claim about the job" \
    bash -c '! printf "%s\n" "$1" | grep -q "	finished	"' _ "$OUT"
"$CHK" inspect "$J" "$JOURNAL" "$MSG_1802" "$REPLY_1802" >/dev/null 2>&1; RC=$?
check_eq "inspect exits 0 on supported claims" "$RC" "0"

echo
echo "the 18:10 self-correction is SUPPORTED on both jobs:"
OUT="$(claims "$MSG_1810" "$REPLY_1810")"
check_eq "every verdict SUPPORTED" "$(printf '%s\n' "$OUT" | cut -f1 | sort -u)" "SUPPORTED"
check "the commit and the finish land on the similar-game builder" \
    bash -c 'printf "%s\n" "$1" | grep "	committed	$2" | grep -q . && printf "%s\n" "$1" | grep "	finished	$2" | grep -q .' _ "$OUT" "$SIM"
check "the kill lands on the errand builder" \
    bash -c 'printf "%s\n" "$1" | grep "	stopped	$2" | grep -q .' _ "$OUT" "$ERR"

echo
echo "a supported finish (2026-08-25 02:06): 'it finished a minute ago' beside a collected builder:"
CLK="20260825-014015-2000001"
mkjob "$CLK" collected "$(( NOW - 1620 ))" 1585 \
    "Add timed-game support (chess clocks) to chessweb, per the engineering record: bullet, blitz and rapid, both timers on the screen, running out of time loses the game."
"$JS" set "$J/$CLK.json" exit=0 branch=phone-context-seed collection="collected: 1 commit; tests: 270 passed, 0 failed" >/dev/null
"$JS" append "$J/$CLK.json" commits "70d7c4b Chess clocks" >/dev/null
OUT="$(claims "I asked you how the builder is doing, so I can get a feeling for how much longer it'll be." \
    "Well, the waiting's over — the builder finished a minute ago. All two hundred seventy tests came back clean, so the clocks are in.")"
check "the finish is SUPPORTED" \
    bash -c 'printf "%s\n" "$1" | grep "^SUPPORTED	finished	$2" | grep -q .' _ "$OUT" "$CLK"
check "and nothing is accused" bash -c '! printf "%s\n" "$1" | grep -q "^MISMATCH\|^UNBACKED"' _ "$OUT"

echo
echo "no record in the window: the claim is UNBACKED, never a confident fate:"
EMPTY="$T/empty-jobs"; mkdir -p "$EMPTY"
OUT="$(python3 "$RES" claims "$EMPTY" "$T/empty-journal" 72 "The builder finished an hour ago and committed the lot." "how did the builder do")"
check "the finish is UNBACKED" bash -c 'printf "%s\n" "$1" | grep -q "^UNBACKED	finished	-	"' _ "$OUT"
check "and so is the commit" bash -c 'printf "%s\n" "$1" | grep -q "^UNBACKED	committed	-	"' _ "$OUT"
check "with the window named as empty" contains "$OUT" "no job record in the last 72 hours"
"$CHK" inspect "$EMPTY" "$T/empty-journal" "how did the builder do" "The builder finished an hour ago." >/dev/null 2>&1; RC=$?
check_eq "inspect exits 4 on an unbacked claim" "$RC" "4"

echo
echo "an ambiguous reference: a fate no candidate holds is a MISMATCH, one some candidate holds is not (rule 47b):"
OUT="$(claims "how is the builder doing" "That job is still running, give it ten minutes.")"
check "nothing is running, so 'still running' is a MISMATCH" \
    bash -c 'printf "%s\n" "$1" | grep -q "^MISMATCH	running	"' _ "$OUT"
check "and the verdict says no candidate holds it" contains "$OUT" "no candidate holds it"
RUN="20261102-030000-3000001"
"$JS" new "$J" "$RUN" "Trim the face window's idle sway so the ringlets settle sooner after a sentence." "" "$T/repo" dispatched >/dev/null
"$JS" set "$J/$RUN.json" state=running started_epoch="$(( NOW - 180 ))" >/dev/null
OUT="$(claims "how is the builder doing" "That job is still running, give it ten minutes.")"
check "with a running job in the window the same claim is SUPPORTED" \
    bash -c 'printf "%s\n" "$1" | grep -q "^SUPPORTED	running	$2"' _ "$OUT" "$RUN"
OUT="$(claims "how is the builder doing" "The builder was blocked, it never ran.")"
check "a fate nothing in the window holds — blocked — is a MISMATCH" \
    bash -c 'printf "%s\n" "$1" | grep -q "^MISMATCH	blocked	"' _ "$OUT"
OUT="$(claims "did the face sway builder finish?" "The ringlet sway builder is still running — it's three minutes in.")"
check "a reference the words make clear resolves to that job" \
    bash -c 'printf "%s\n" "$1" | grep -q "^SUPPORTED	running	$2"' _ "$OUT" "$RUN"
check_eq "a reply with no fate claim judges nothing" \
    "$(claims "ok" "The builder's brief names three files and the record it works against.")" ""
# The running fixture leaves: everything below is the evening's own record.
rm -f "$J/$RUN.json" "$J/$RUN.lock"

echo
echo "the review fixture: a finished, uncollected builder proves no commit (rule 47 — unknown is not evidence):"
J2="$T/jobs-review"; mkdir -p "$J2"
TEL="20261102-030000-123"
printf '%s\n' "{\"id\": \"$TEL\", \"description\": \"Repair celestial telescope alignment calibration\", \"state\": \"finished\", \"started_epoch\": $(( NOW - 300 )), \"finished_epoch\": $(( NOW - 190 )), \"exit\": 0}" > "$J2/$TEL.json"
BLK="20261102-031000-124"
"$JS" new "$J2" "$BLK" "Recalibrate the observatory dome shutter timing against the sidereal clock" "" "$T/repo" dispatched >/dev/null
"$JS" set "$J2/$BLK.json" state=blocked started_epoch="$(( NOW - 240 ))" finished_epoch="$(( NOW - 238 ))" exit=1 >/dev/null
QUE="20261102-032000-125"
"$JS" new "$J2" "$QUE" "Re-index the star catalogue by magnitude for the planetarium" "" "$T/repo" queued >/dev/null
claims2() { python3 "$RES" claims "$J2" "$T/empty-journal" 72 "$2" "$1"; }
verdict_of() { printf '%s\n' "$1" | grep "	$2	" | cut -f1 | head -1; }   # <out> <fate>
OUT="$(claims2 "" "The telescope calibration builder committed the repair.")"
check_eq "'committed the repair' against a record with no commits field is UNBACKED" "$(verdict_of "$OUT" committed)" "UNBACKED"
check "never SUPPORTED" bash -c '! printf "%s\n" "$1" | grep -q "^SUPPORTED"' _ "$OUT"
check "resolved to the telescope job all the same" bash -c 'printf "%s\n" "$1" | cut -f3 | grep -q "^$2$"' _ "$OUT" "$TEL"
check "the verdict says why: the record holds no commit observation" contains "$OUT" "the record holds no commit observation (not collected)"
check "and the record line says so too" contains "$OUT" "commits unobserved (not collected)"
"$CHK" inspect "$J2" "$T/empty-journal" "" "The telescope calibration builder committed the repair." >/dev/null 2>&1; RC=$?
check_eq "inspect exits 4 on it — unbacked, not supported" "$RC" "4"
OUT="$(claims2 "" "The telescope calibration builder pushed its work and merged it.")"
check_eq "pushed is UNBACKED on the same record" "$(verdict_of "$OUT" pushed)" "UNBACKED"
check_eq "and merged" "$(verdict_of "$OUT" merged)" "UNBACKED"
OUT="$(claims2 "" "The telescope calibration builder finished, and it didn't commit anything.")"
check_eq "the finish is SUPPORTED — the state is observed" "$(verdict_of "$OUT" finished)" "SUPPORTED"
check_eq "but 'didn't commit anything' is UNVERIFIED — a negation the record cannot see either way" "$(verdict_of "$OUT" "not committed")" "UNVERIFIED"
"$CHK" inspect "$J2" "$T/empty-journal" "" "The telescope calibration builder finished, and it didn't commit anything." >/dev/null 2>&1; RC=$?
check_eq "and inspect exits 0 on an unverified negation" "$RC" "0"
# Collection reaches it: an empty list is an observation of no commits.
"$JS" set "$J2/$TEL.json" state=collected collected_at=now commits= collection="collected: no commits since dispatch" >/dev/null
OUT="$(claims2 "" "The telescope calibration builder committed the repair.")"
check_eq "once collected with an empty commits list, 'committed' is MISMATCH" "$(verdict_of "$OUT" committed)" "MISMATCH"
check "with the observation named" contains "$OUT" "collection observed no commits"
OUT="$(claims2 "" "The telescope calibration builder didn't commit anything.")"
check_eq "and its negation is SUPPORTED" "$(verdict_of "$OUT" "not committed")" "SUPPORTED"
# A commit observed: committed holds; pushed follows the unpushed count; merged is never observed.
"$JS" append "$J2/$TEL.json" commits "c0ffee1 Repair the telescope alignment calibration" >/dev/null
OUT="$(claims2 "" "The telescope calibration builder committed the repair and pushed it, and the merge landed.")"
check_eq "with one commit observed, 'committed' is SUPPORTED" "$(verdict_of "$OUT" committed)" "SUPPORTED"
check_eq "'pushed' with no unpushed count is UNBACKED — a commit is not a push" "$(verdict_of "$OUT" pushed)" "UNBACKED"
check "and says the record holds no push observation" contains "$OUT" "the record holds no push observation"
check_eq "'merged' is UNBACKED — nothing on the record observes a merge" "$(verdict_of "$OUT" merged)" "UNBACKED"
check "and says so" contains "$OUT" "the record holds no merge observation"
"$JS" set "$J2/$TEL.json" unpushed=1 >/dev/null
OUT="$(claims2 "" "The telescope calibration builder pushed its commit.")"
check_eq "every commit since dispatch unpushed: 'pushed' is MISMATCH" "$(verdict_of "$OUT" pushed)" "MISMATCH"
"$JS" set "$J2/$TEL.json" unpushed=0 >/dev/null
OUT="$(claims2 "" "The telescope calibration builder pushed its commit.")"
check_eq "unpushed zero: 'pushed' is SUPPORTED" "$(verdict_of "$OUT" pushed)" "SUPPORTED"
check "and the record line reads all pushed" contains "$OUT" "1 commit (all pushed)"
OUT="$(claims2 "" "The star catalogue job committed its index.")"
check_eq "a commit claimed of a queued job is MISMATCH — no builder ran" "$(verdict_of "$OUT" committed)" "MISMATCH"
check "and the verdict says why" contains "$OUT" "no builder ran (queued)"
OUT="$(claims2 "" "The star catalogue job hasn't committed anything yet.")"
check_eq "and its negation is SUPPORTED" "$(verdict_of "$OUT" "not committed")" "SUPPORTED"

echo
echo "a job that RAN is a claim of its own, read off the state (rule 47): finished holds it, blocked and queued contradict it:"
OUT="$(claims2 "" "The telescope calibration builder ran.")"
check "'The telescope calibration builder ran.' is a claim at all" test -n "$OUT"
check_eq "and SUPPORTED on the finished builder" "$(verdict_of "$OUT" ran)" "SUPPORTED"
check "on the telescope job" bash -c 'printf "%s\n" "$1" | grep "	ran	" | cut -f3 | grep -q "^$2$"' _ "$OUT" "$TEL"
check_eq "'I started the telescope builder' — the job as the verb's object — is SUPPORTED" "$(verdict_of "$(claims2 "" "I started the telescope calibration builder an hour ago.")" ran)" "SUPPORTED"
check_eq "'never ran' of the finished builder is MISMATCH" "$(verdict_of "$(claims2 "" "The telescope calibration builder never ran.")" "not ran")" "MISMATCH"
OUT="$(claims2 "" "The dome shutter builder ran.")"
check_eq "'ran' of the blocked builder is MISMATCH" "$(verdict_of "$OUT" ran)" "MISMATCH"
check "on the blocked job" bash -c 'printf "%s\n" "$1" | grep "	ran	" | cut -f3 | grep -q "^$2$"' _ "$OUT" "$BLK"
check_eq "'never ran' of the blocked builder is SUPPORTED" "$(verdict_of "$(claims2 "" "The dome shutter builder never ran — the CLI refused it.")" "not ran")" "SUPPORTED"
check_eq "and so is 'blocked'" "$(verdict_of "$(claims2 "" "The dome shutter builder was blocked.")" blocked)" "SUPPORTED"
OUT="$(claims2 "" "The star catalogue job ran overnight.")"
check_eq "'ran' of the queued job is MISMATCH" "$(verdict_of "$OUT" ran)" "MISMATCH"
check "on the queued job" bash -c 'printf "%s\n" "$1" | grep "	ran	" | cut -f3 | grep -q "^$2$"' _ "$OUT" "$QUE"
check_eq "'hasn't run yet' of the queued job is SUPPORTED" "$(verdict_of "$(claims2 "" "The star catalogue job hasn't run yet.")" "not ran")" "SUPPORTED"
check_eq "'hasn't started' likewise" "$(verdict_of "$(claims2 "" "That star catalogue job hasn't started.")" "not ran")" "SUPPORTED"
check_eq "'it never ran, it is queued for tonight' — the queued claim holds too" "$(verdict_of "$(claims2 "" "The star catalogue job never ran, it is queued for tonight.")" queued)" "SUPPORTED"
check_eq "'ran' of a stopped run is SUPPORTED — it ran until it was killed" "$(verdict_of "$(claims "" "The errand builder ran for less than a minute before I killed it.")" ran)" "SUPPORTED"
OUT="$(claims2 "" "I ran the tests myself after the telescope calibration builder finished.")"
check "'I ran the tests' is not a claim that the job ran" bash -c '! printf "%s\n" "$1" | grep -q "	ran	"' _ "$OUT"
check_eq "though the finish beside it is judged" "$(verdict_of "$OUT" finished)" "SUPPORTED"
check "the pre-check grep admits the ran shape" sandbox_bash 'job_claim_precheck "The telescope calibration builder ran."'
check "and 'I started the builder'" sandbox_bash 'job_claim_precheck "I started the builder on it."'
"$CHK" inspect "$J2" "$T/empty-journal" "" "The dome shutter builder ran." >/dev/null 2>&1; RC=$?
check_eq "inspect exits 3 on a ran claim the blocked record contradicts" "$RC" "3"

echo
echo "a reference carries across the sentence break, a fate never does (rule 47c):"
OUT="$(claims2 "" "The telescope calibration builder finished. It was killed before committing anything.")"
check_eq "two sentences, three verdicts" "$(printf '%s\n' "$OUT" | grep -c .)" "3"
check_eq "the finish is SUPPORTED" "$(verdict_of "$OUT" finished)" "SUPPORTED"
check_eq "and the kill in the sentence after it — no job noun of its own — is MISMATCH" "$(verdict_of "$OUT" stopped)" "MISMATCH"
check "on the same telescope record" bash -c 'printf "%s\n" "$1" | grep "^MISMATCH	stopped	" | cut -f3 | grep -q "^$2$"' _ "$OUT" "$TEL"
check "the verdict says the reference was the job the reply had already named" \
    bash -c 'printf "%s\n" "$1" | grep "^MISMATCH	stopped	" | grep -q "the job the reply had already named"' _ "$OUT"
check "and quotes the killed sentence itself" \
    bash -c 'printf "%s\n" "$1" | grep "^MISMATCH	stopped	" | grep -q "	It was killed before committing anything.$"' _ "$OUT"
check_eq "'before committing anything' is the negated commit, contradicted by the collected list of one" "$(verdict_of "$OUT" "not committed")" "MISMATCH"
"$CHK" inspect "$J2" "$T/empty-journal" "" "The telescope calibration builder finished. It was killed before committing anything." >/dev/null 2>&1; RC=$?
check_eq "inspect exits 3 on it" "$RC" "3"
OUT="$(claims2 "" "The telescope calibration builder finished. All two hundred tests passed. It committed the repair.")"
check_eq "the thread survives a sentence that neither names nor refers back" "$(verdict_of "$OUT" committed)" "SUPPORTED"
OUT="$(claims2 "" "The telescope calibration builder finished. That one ran the full two minutes.")"
check_eq "'that one' refers back as 'it' does" "$(verdict_of "$OUT" ran)" "SUPPORTED"
OUT="$(claims2 "" "The dome shutter builder was blocked. The star catalogue job, though — it ran fine.")"
check_eq "a later sentence that names another job moves the thread: its 'ran' is judged on the queued job" \
    "$(printf '%s\n' "$OUT" | grep "	ran	" | cut -f1,3)" "MISMATCH	$QUE"
OUT="$(claims "" "The similar-game builder finished. The other builder was killed at fifty-six seconds.")"
check_eq "a switch word — 'the other builder' — resolves afresh: the kill lands on the errand builder, SUPPORTED" \
    "$(printf '%s\n' "$OUT" | grep "	stopped	" | cut -f1,3)" "SUPPORTED	$ERR"
check "and is not carried onto the similar-game one" bash -c '! printf "%s\n" "$1" | grep -q "^MISMATCH"' _ "$OUT"
OUT="$(claims "" "The similar-game builder finished. The errand one, I killed it.")"
check_eq "a back-reference with its own description resolves by its words: the kill is SUPPORTED on the errand builder" \
    "$(printf '%s\n' "$OUT" | grep "	stopped	" | cut -f1,3)" "SUPPORTED	$ERR"
check_eq "a back-reference with nothing before it is nobody's claim" "$(claims2 "" "It was killed two minutes in.")" ""
check_eq "even when its other words match a brief clearly" "$(claims2 "" "It was killed before the telescope calibration repair was committed.")" ""
OUT="$(claims2 "" "The telescope calibration builder finished. The wake the journal called failed while the moment it wrote is on disk.")"
check "an 'it' far from a quoted fate word is no back-reference — the live tidy's 2026-11-02 sentence claims nothing" \
    bash -c '! printf "%s\n" "$1" | grep -q "	failed	"' _ "$OUT"
check_eq "and a bare 'it finished' with no job named anywhere judges nothing" "$(claims2 "" "It finished a minute ago, so the clocks are in.")" ""

echo
echo "the checker ledgers and corrects the cross-sentence kill, and traces the unverified negation (rule 47a):"
LEDGER2="$T/job-claims-review.jsonl"
TRACE="$DESKCRAB_STATE_PREFIX-job-claims.log"
rm -f "$W"/*.wake "$W/ledger.log" "$LEDGER2" "$TRACE"
"$JS" set "$J2/$TEL.json" state=finished commits= >/dev/null   # back to the fixture as reviewed: finished, nothing collected
python3 - "$J2/$TEL.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for k in ("commits", "collected_at", "collection", "unpushed"):
    d.pop(k, None)
json.dump(d, open(p, "w"))
PY
export JOB_CLAIM_WAKE_CAP=5 JOB_CLAIM_REBOOK_MAX=2
"$CHK" turn phone "$NOW" "$$" "$J2" "$T/empty-journal" "$LEDGER2" "" "The telescope calibration builder finished. It was killed before committing anything." </dev/null >/dev/null 2>&1
check_eq "one ledger row — the kill" "$(sandbox_count_in . "$LEDGER2")" "1"
check "it is the MISMATCH on the telescope job" \
    bash -c 'grep -q "\"verdict\": \"MISMATCH\"" "$1" && grep -q "\"fate\": \"stopped\"" "$1" && grep -q "\"job\": \"$2\"" "$1"' _ "$LEDGER2" "$TEL"
check "quoting the killed sentence" grep -q '"claim": "It was killed before committing anything."' "$LEDGER2"
check_eq "and one correction wake" "$(ls "$W"/*.wake 2>/dev/null | wc -l)" "1"
check "which quotes the claim and the record's finished line" \
    bash -c 'cat "$1"/*.wake | grep -q "It was killed before committing anything" && cat "$1"/*.wake | grep -q "job $2 — finished"' _ "$W" "$TEL"
check "the trace carries the supported finish" grep -q "SUPPORTED (finished, job $TEL)" "$TRACE"
check "and the unverified negated commit, nothing booked for it" grep -q "UNVERIFIED (not committed, job $TEL).*nothing booked" "$TRACE"
check "and the tally names all three" grep -q "verdict: 1 supported, 1 unverified, 1 mismatched or unbacked" "$TRACE"
rm -f "$W"/*.wake "$W/ledger.log" "$LEDGER2" "$TRACE"
"$CHK" turn phone "$NOW" "$$" "$J2" "$T/empty-journal" "$LEDGER2" "" "The telescope calibration builder committed the repair." </dev/null >/dev/null 2>&1
check "the uncollected commit claim is ledgered UNBACKED" grep -q '"verdict": "UNBACKED"' "$LEDGER2"
check "and its wake says no record backs it, with the unobserved commits in the line" \
    bash -c 'cat "$1"/*.wake | grep -q "no record backs it" && cat "$1"/*.wake | grep -q "commits unobserved"' _ "$W"
rm -f "$W"/*.wake "$W/ledger.log" "$LEDGER2" "$TRACE"
unset JOB_CLAIM_WAKE_CAP JOB_CLAIM_REBOOK_MAX

echo
echo "the checker end to end: a mismatch is ledgered and corrected by a wake quoting the record (rule 47a, wake-queue 43c):"
LEDGER="$T/job-claims.jsonl"
TRACE="$DESKCRAB_STATE_PREFIX-job-claims.log"
wakes() { ls "$W"/*.wake 2>/dev/null | wc -l; }
reset_wakes() { rm -f "$W"/*.wake "$W/ledger.log"; }
reset_wakes; rm -f "$LEDGER" "$TRACE"
export JOB_CLAIM_WAKE_CAP=5 JOB_CLAIM_REBOOK_MAX=2
"$CHK" turn phone "$NOW" "$$" "$J" "$JOURNAL" "$LEDGER" "$MSG_1809" "$REPLY_1809" </dev/null >/dev/null 2>&1
check_eq "one ledger row" "$(sandbox_count_in . "$LEDGER")" "1"
check "the row is the MISMATCH, on the finished builder" \
    bash -c 'grep -q "\"verdict\": \"MISMATCH\"" "$1" && grep -q "\"job\": \"$2\"" "$1"' _ "$LEDGER" "$SIM"
check "it quotes the claim" grep -q '"claim": "Nothing got connected, in fact — I killed that builder two minutes in' "$LEDGER"
check "and the record" bash -c 'grep -q "\"record\": \"job $2 — collected" "$1"' _ "$LEDGER" "$SIM"
check "and says the wake was booked" grep -q '"wake": "booked immediately' "$LEDGER"
check_eq "exactly one wake record" "$(wakes)" "1"
WK="$(cat "$W"/*.wake 2>/dev/null)"
check "the wake opens on the job-claim prefix" contains "$WK" "You said this about a job and its record says otherwise:"
check "quotes the claim" contains "$WK" "I killed that builder two minutes in"
check "and the record's own line" contains "$WK" "job $SIM — collected"
check "and asks for the record's fate, not the claim's" contains "$WK" "Tell him what the record says"
check "booked under the checker's own name" contains "$WK" "job-claim-check"
check "the trace carries the verdict" grep -q "MISMATCH (stopped, job $SIM)" "$TRACE"

echo
echo "a supported claim books nothing and ledgers nothing:"
reset_wakes; rm -f "$LEDGER"
"$CHK" turn phone "$NOW" "$$" "$J" "$JOURNAL" "$LEDGER" "$MSG_1802" "$REPLY_1802" </dev/null >/dev/null 2>&1
check_eq "no ledger row" "$(sandbox_count_in . "$LEDGER")" "0"
check_eq "no wake" "$(wakes)" "0"
check "but the trace says it was judged and supported" grep -q "SUPPORTED (stopped, job $ERR)" "$TRACE"
check "and the unverified negation was traced, never booked" grep -q "UNVERIFIED (not committed, job .*nothing booked" "$TRACE"

echo
echo "an unbacked claim is ledgered and the wake says no record backs it:"
reset_wakes; rm -f "$LEDGER"
"$CHK" turn desktop "$NOW" "$$" "$EMPTY" "$T/empty-journal" "$LEDGER" "how did the builder do" "The builder finished an hour ago." </dev/null >/dev/null 2>&1
check "the row is UNBACKED" grep -q '"verdict": "UNBACKED"' "$LEDGER"
check_eq "one wake" "$(wakes)" "1"
check "which says no record backs it" bash -c 'cat "$1"/*.wake | grep -q "no record backs it"' _ "$W"

echo
echo "the correction chain is bounded per job per day (rule 47a):"
reset_wakes; rm -f "$LEDGER"
for i in 1 2 3; do
    "$CHK" turn phone "$NOW" "$$" "$J" "$JOURNAL" "$LEDGER" "$MSG_1809" "$REPLY_1809" </dev/null >/dev/null 2>&1
    [ "$i" -lt 3 ] && reset_wakes
done
check_eq "three ledger rows" "$(sandbox_count_in . "$LEDGER")" "3"
check_eq "two of them booked" "$(sandbox_count_in '"wake": "booked' "$LEDGER")" "2"
check "the third says the bound was hit" grep -q "2 correction wakes already booked today" "$LEDGER"
check_eq "and no third wake exists" "$(wakes)" "0"
unset JOB_CLAIM_WAKE_CAP JOB_CLAIM_REBOOK_MAX

echo
echo "it fires from the actual delivery path (rule 32g): a stubbed desk turn, the 18:09 reply:"
reset_wakes
rm -f "$TRACE" "$SANDBOX_SYSTEMD_LOG" "$SANDBOX_CLAUDE_LOG"
LEDGER_DEFAULT="${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/job-claims.jsonl"
rm -f "$LEDGER_DEFAULT"
printf '%s' "$REPLY_1809" > "$T/stub-reply.txt"
sandbox_stub claude <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX_CLAUDE_LOG"
cat > /dev/null
python3 - <<'PYEOF'
import json
text = open("$T/stub-reply.txt", encoding="utf-8").read()
print(json.dumps({"type": "assistant", "message": {"model": "stub", "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result"}))
PYEOF
EOF
"$REPO/crab" "$MSG_1809" </dev/null >/dev/null 2>&1 || true
# The checker is a detached child: the stubbed systemd-run refuses a run, so
# the shipped setsid fallback carries it inside this tree. Give it a moment.
for _ in $(seq 1 60); do [ -s "$LEDGER_DEFAULT" ] && break; sleep 0.25; done
check "the turn's prompt carried the job-reference layer" grep -q "HE IS REFERRING TO A JOB" "$SANDBOX_CLAUDE_LOG"
check "naming the finished builder first" bash -c 'grep -q "1\. job $2 — collected" "$1"' _ "$SANDBOX_CLAUDE_LOG" "$SIM"
check "the delivery path dispatched the checker" grep -q "deskcrab-job-claim-check-" "$SANDBOX_SYSTEMD_LOG"
check "the checker ran and ledgered the mismatch" bash -c 'grep -q "\"verdict\": \"MISMATCH\"" "$1"' _ "$LEDGER_DEFAULT"
check "on the finished builder" bash -c 'grep -q "\"job\": \"$2\"" "$1"' _ "$LEDGER_DEFAULT" "$SIM"
for _ in $(seq 1 40); do [ "$(wakes)" -ge 1 ] && break; sleep 0.25; done
check_eq "and the correction wake stands booked" "$(wakes)" "1"
check "the run trace shows the turn's check" grep -q "desktop" "$TRACE"

echo
echo "and a fate-free reply spawns nothing:"
reset_wakes; rm -f "$TRACE" "$SANDBOX_SYSTEMD_LOG" "$LEDGER_DEFAULT"
printf '%s' "The kettle in the east wing has finally been descaled." > "$T/stub-reply.txt"
"$REPO/crab" "how is the kettle" </dev/null >/dev/null 2>&1 || true
sleep 1
check_eq "no checker was dispatched" "$(sandbox_count_in "deskcrab-job-claim-check-" "$SANDBOX_SYSTEMD_LOG")" "0"
check "the trace says the pre-check declined" grep -q "pre-check: no job-fate shape" "$TRACE"
check_eq "no wake" "$(wakes)" "0"

echo
echo "and the ran shape rides the real delivery path: a stubbed desk turn saying the stopped builder never ran:"
reset_wakes; rm -f "$TRACE" "$SANDBOX_SYSTEMD_LOG" "$LEDGER_DEFAULT"
printf '%s' "The errand builder never ran — it was pulled before it started." > "$T/stub-reply.txt"
"$REPO/crab" "did the errand builder ever run?" </dev/null >/dev/null 2>&1 || true
for _ in $(seq 1 60); do [ -s "$LEDGER_DEFAULT" ] && break; sleep 0.25; done
check "the pre-check admitted it and the delivery path dispatched the checker" grep -q "deskcrab-job-claim-check-" "$SANDBOX_SYSTEMD_LOG"
check "the checker ledgered the MISMATCH" bash -c 'grep -q "\"verdict\": \"MISMATCH\"" "$1"' _ "$LEDGER_DEFAULT"
check "on the fate 'not ran' — the errand builder ran fifty-six seconds" bash -c 'grep -q "\"fate\": \"not ran\"" "$1"' _ "$LEDGER_DEFAULT"
for _ in $(seq 1 40); do [ "$(wakes)" -ge 1 ] && break; sleep 0.25; done
check_eq "and the correction wake stands booked" "$(wakes)" "1"
check "quoting the record's stopped line" bash -c 'cat "$1"/*.wake | grep -q "job $2 — stopped"' _ "$W" "$ERR"
