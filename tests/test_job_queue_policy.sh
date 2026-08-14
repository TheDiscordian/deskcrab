#!/bin/bash
# The dispatch policy — specs/jobs.md rules 30-35. While she is awake the job
# door dispatches only want-linked work; everything else QUEUES for the night.
# Three hands pass without a want — a deliberate -f, a retry inheriting its
# origin's standing, and the drain's night window — and the queue has exactly
# two exits: `crab job dispatch <id>` through the full preflight, and a
# deliberate `crab job drop <id>`. Run: bash tests/test_job_queue_policy.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
JS="$REPO/lib/job-status"
J="$T/jobs"
mkdir -p "$J"

# A shelf in the live shape: emoji-decorated bold titles, document pointers,
# and a comment above the list that must never validate a linkage.
WANTS="$T/wants.md"
cat > "$WANTS" <<'EOF'
# Wants

<!-- rebuild note: the latch project is mentioned here but this is not a want -->

- **A face of my own** → a-face-of-my-own.md
- 🔊 **A voice that isn't flat** → my-speaking-voice.md
- **Learn to read sheet music properly** → sheet-music.md
EOF

run() { # <shell body> — the door with the shelf standing and dispatch stopped
    JOBS_DIR="$J" WANTS_FILE="$WANTS" DESKCRAB_NO_DISPATCH=1 sandbox_bash "$*" 2>&1
}
runq() { # <shell body> — the shelf standing, REAL dispatch path (the sandbox's
         # systemd-run stub records the unit and arms nothing, so no builder
         # can start; what this proves is what lands on the sidecar)
    JOBS_DIR="$J" WANTS_FILE="$WANTS" sandbox_bash "$*" 2>&1
}
sidecars() { ls "$J"/*.json 2>/dev/null | wc -l | tr -d ' '; }

echo "wants_match — the shelf's one reading of a ref (rule 30):"
out="$(run 'wants_match "sheet music"')"
check_eq "a title fragment matches, and the title comes back" \
    "$out" "Learn to read sheet music properly"
out="$(run 'wants_match "my-speaking-voice.md"')"
check_eq "the document name a shelf line points at matches too" \
    "$out" "A voice that isn't flat"
out="$(run 'wants_match "latch" && echo MATCHED || echo no')"
check_eq "a comment above the list can never validate a linkage" "$out" "no"
out="$(run 'wants_match "no such want anywhere" && echo MATCHED || echo no')"
check_eq "an unknown ref does not match" "$out" "no"
out="$(run 'wants_match "e" && echo MATCHED || echo no')"
check_eq "a one-character ref cannot launder a linkage — it is inside every title" \
    "$out" "no"
out="$(run 'wants_match "of" && echo MATCHED || echo no')"
check_eq "two characters are still too short to name a want" "$out" "no"

echo
echo "awake and unlinked, a brief QUEUES instead of dispatching (rule 30):"
rm -f "$J"/*.json
out="$(run 'job_start "tidy the widget shed"')"
check "the door says queued, not dispatched" contains "$out" "QUEUED for the night"
case "$out" in *"Would dispatch"*) fail "a queued brief must never reach dispatch" "$out" ;;
    *) ok "dispatch was never reached" ;; esac
check_eq "one sidecar exists" "$(sidecars)" "1"
QID="$(basename "$(ls "$J"/*.json)" .json)"
check_eq "in state queued" "$("$JS" get "$J/$QID.json" state)" "queued"
check "with the shelving on record" \
    [ -n "$("$JS" get "$J/$QID.json" queued_epoch)" ]
check "and the message names both exits" contains "$out" "crab job dispatch $QID"

echo
echo "a matched want dispatches, and an unmatched one is refused outright:"
out="$(run 'job_start --want "sheet music" "practise the clef drills"')"
check "a want-linked brief reaches dispatch" contains "$out" "Would dispatch"
check "naming the matched title" contains "$out" "(want: Learn to read sheet music properly)"
out="$(run 'job_start --want "a want nobody has" "do a thing"')"
check "an unmatched want is refused" contains "$out" "nothing on the wants shelf matches"
case "$out" in *"QUEUED"*|*"Would dispatch"*)
        fail "an unverifiable linkage must be neither dispatched nor queued" "$out" ;;
    *) ok "neither dispatched nor queued" ;; esac

echo
echo "the three hands that pass without a want (rule 31):"
out="$(run 'job_start -f "a deliberately forced brief"')"
check "-f dispatches" contains "$out" "Would dispatch"
out="$(run 'job_start -O someorigin "a retry keeps its origin'"'"'s standing"')"
check "-O dispatches" contains "$out" "Would dispatch"
out="$(run 'DESKCRAB_JOB_NIGHT=1 job_start "the drain'"'"'s own pick"')"
check "the night window dispatches" contains "$out" "Would dispatch"

echo
echo "no shelf, no gate — an unconfigured instance dispatches as it always did:"
out="$(JOBS_DIR="$J" DESKCRAB_NO_DISPATCH=1 sandbox_bash 'job_start "an ungated brief"' 2>&1)"
check "with WANTS_FILE unset the brief dispatches" contains "$out" "Would dispatch"

echo
echo "the sidecar records the linkage and the run parameters (rules 30, 35):"
rm -f "$J"/*.json
out="$(runq 'JOB_MODEL=fable JOB_EFFORT=high job_start --want "sheet music" "practise the clef drills"')"
check "the dispatch happened" contains "$out" "dispatched"
DID="$(basename "$(ls "$J"/*.json)" .json)"
check_eq "state is dispatched — the worker has not spoken yet" \
    "$("$JS" get "$J/$DID.json" state)" "dispatched"
check_eq "the want rides the sidecar as the matched title" \
    "$("$JS" get "$J/$DID.json" want)" "Learn to read sheet music properly"
check_eq "the model is stamped at dispatch" "$("$JS" get "$J/$DID.json" model)" "fable"
check_eq "and the effort" "$("$JS" get "$J/$DID.json" effort)" "high"

echo
echo "crab job dispatch — a queued record dispatched in place (rule 32):"
rm -f "$J"/*.json
run 'job_start "a brief for the night"' >/dev/null
QID="$(basename "$(ls "$J"/*.json)" .json)"
sleep 1
out="$(run 'job_dispatch_queued '"$QID")"
check "the dry run says what it would do" contains "$out" "Would dispatch queued job $QID"
check_eq "and leaves the record queued" "$("$JS" get "$J/$QID.json" state)" "queued"
out="$(runq 'job_dispatch_queued '"$QID")"
check "the real path dispatches" contains "$out" "Job $QID dispatched"
check_eq "same id, state moved to dispatched" \
    "$("$JS" get "$J/$QID.json" state)" "dispatched"
QE="$("$JS" get "$J/$QID.json" queued_epoch)"
SE="$("$JS" get "$J/$QID.json" started_epoch)"
check "started is re-stamped to the dispatch, the wait kept beside it" \
    [ "$SE" -gt "$QE" ]
hist="$(python3 -c 'import json,sys; print(" ".join(h["state"] for h in json.load(open(sys.argv[1])).get("history",[])))' "$J/$QID.json")"
check_eq "history holds the whole path" "$hist" "queued dispatched"

echo
echo "dispatch refuses everything that is not a clean queued brief (rule 32):"
out="$(runq 'job_dispatch_queued '"$QID")"
check "a second dispatch of the same record is refused" contains "$out" "not queued"
out="$(runq 'job_dispatch_queued no-such-id')"
check "an unknown id is an error" contains "$out" "No such job"
"$JS" new "$J" nullq "null" "" /tmp queued
out="$(runq 'job_dispatch_queued nullq')"
check "an artifact-shaped queued corpse never wakes a builder" \
    contains "$out" "broken command substitution"
check_eq "and stays queued for a hand to drop" "$("$JS" get "$J/nullq.json" state)" "queued"
"$JS" new "$J" heldq "a real brief behind a wall" "" /tmp queued
out="$(runq 'job_block_record "out of usage credits"; job_dispatch_queued heldq')"
check "the block marker holds a queued dispatch too" contains "$out" "never began"
check_eq "the brief stays queued" "$("$JS" get "$J/heldq.json" state)" "queued"
runq 'rm -f "$JOBS_BLOCKED_FILE"' >/dev/null

echo
echo "crab job drop — the one way off the queue undispatched (rule 33):"
out="$(runq 'job_drop nullq')"
check "a queued corpse can be dropped" contains "$out" "dropped, undispatched"
check "and its record is gone" [ ! -e "$J/nullq.json" ]
out="$(runq 'job_drop '"$QID")"
check "a job that ran cannot be dropped" contains "$out" "not queued"
check "its record survives" [ -e "$J/$QID.json" ]
out="$(runq 'job_drop no-such-id')"
check "an unknown id is an error, not a shrug" contains "$out" "No such job"

echo
echo "drop waits on the record writer's lock and re-judges inside it (rule 33):"
# The dispatch side of the race, played by hand: a holder takes the record's
# lock — exactly as the status writer's stamp does — and flips the state to
# dispatched before releasing. A drop arriving mid-stamp must block on the
# lock and then refuse on the winner's state; the pre-fix drop read the state
# without the lock, saw queued, and deleted the record of a builder that was
# in the middle of being dispatched.
"$JS" new "$J" raceq "a brief being stamped as the drop arrives" "" /tmp queued
(
    exec 9>>"$J/raceq.lock"
    flock 9
    sleep 2
    python3 - "$J/raceq.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["state"] = "dispatched"
json.dump(d, open(p, "w"))
PY
) &
HOLDER=$!
out="$(runq 'job_drop raceq')"
wait "$HOLDER"
check "the drop waited out the lock and refused on the winner's state" \
    contains "$out" "not queued"
check "the stamped record survives" [ -e "$J/raceq.json" ]
check_eq "still dispatched" "$("$JS" get "$J/raceq.json" state)" "dispatched"

echo
echo "a dispatch whose record vanished mid-flight aborts (rule 32):"
out="$(runq 'job_dispatch_sidecar ghost-job /tmp')"
check "the stamp's failure is the drop's answer" contains "$out" "No builder started"
case "$(sandbox_systemd_calls)" in *deskcrab-job-ghost-job*)
        fail "no unit may start for a record that is gone" "$(sandbox_systemd_calls)" ;;
    *) ok "no unit was asked for" ;; esac
check "and the writer's recreated lock file is swept back out" \
    [ ! -e "$J/ghost-job.lock" ]
