#!/bin/bash
# Night-selected engineering work must enter the record lifecycle, rather
# than finish as an unassociated job (specs/jobs.md rule 27a).
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

export SANDBOX_REPO
export TEST_RECORDS="$SANDBOX/records"
export TEST_CALLS="$SANDBOX/door.jsonl"
mkdir -p "$TEST_RECORDS" "$SANDBOX/jobs"
E() { DESKCRAB_ENG_DIR="$TEST_RECORDS" python3 "$SANDBOX_REPO/lib/eng" "$@"; }
RID="$(E new 'Repair the greenhouse latch' --body 'The latch sticks. Repair it and verify the door closes freely.')"

cat > "$SANDBOX/crab" <<'DOOR'
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1] == 'job':
    with open(os.environ['TEST_CALLS'], 'a') as f:
        f.write(json.dumps(sys.argv[1:]) + '\n')
    print('Job record-test dispatched (unit deskcrab-job-record-test) — detached.')
DOOR
chmod +x "$SANDBOX/crab"

sandbox_stub claude <<'MODEL'
#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
sys.stdin.read()
change = os.environ.get('TEST_STATE_CHANGE', '')
if change:
    env = dict(os.environ, DESKCRAB_ENG_DIR=os.environ['TEST_RECORDS'])
    subprocess.run([sys.executable, os.environ['SANDBOX_REPO'] + '/lib/eng',
                    change, os.environ['TEST_PICK'], 'Changed during selection'],
                   env=env, stdout=subprocess.DEVNULL, check=True)
if os.environ.get('TEST_ACTIVE_JOB'):
    sidecar = pathlib.Path(os.environ['JOBS_DIR']) / 'concurrent-job.json'
    sidecar.write_text(json.dumps({'id': 'concurrent-job', 'state': 'dispatched',
                                  'record': os.environ['TEST_PICK']}))
answer = ('TASK: ' + os.environ['TEST_PICK'] + ' | - | Repair the latch\nBRIEF:\n'
          'Read the original ask and current record, repair the sticking greenhouse latch, '
          'verify it closes freely twice, and record the actual outcome and verification.\nEND')
if os.environ.get('TEST_DUPLICATE'):
    answer += '\n' + answer
print(json.dumps({'type': 'assistant', 'message': {'model': 'stub',
      'content': [{'type': 'text', 'text': answer}]}}))
print(json.dumps({'type': 'result', 'result': 'ok'}))
MODEL

run_night() {
    rm -f "$TEST_CALLS" "$SANDBOX/ledger.tsv"
    env CRAB_BIN="$SANDBOX/crab" JOBS_DIR="$SANDBOX/jobs" \
        NIGHT_WORK_RECORDS_DIR="$TEST_RECORDS" \
        NIGHT_WORK_LEDGER="$SANDBOX/ledger.tsv" NIGHT_WORK_MODEL=stub-claude \
        NIGHT_WORK_CUTOFF="@$(( $(date +%s) + 3600 ))" \
        NIGHT_WORK_POLL=1 NIGHT_WORK_ROUNDS_MAX=1 \
        "$@" "$SANDBOX_REPO/lib/night-work" run 2>&1
}

export TEST_PICK="$RID"
out="$(run_night)"
check "the open record reaches the job door" test -s "$TEST_CALLS"
check "its exact id is attached through --record" python3 - "$TEST_CALLS" "$RID" <<'PY'
import json, sys
args = json.loads(open(sys.argv[1]).readline())
assert args[args.index('--record') + 1] == sys.argv[2], args
assert args[args.index('-C') + 1], args
PY

export TEST_PICK=promise-without-a-record
out="$(run_night)"
check "a promise pick still reaches the job door" test -s "$TEST_CALLS"
check "a promise gets no invented record hook" python3 - "$TEST_CALLS" <<'PY'
import json, sys
args = json.loads(open(sys.argv[1]).readline())
assert '--record' not in args, args
PY

export TEST_PICK="$RID"
out="$(run_night TEST_STATE_CHANGE=review)"
check_eq "a concurrent submission stands" "$(E field "$RID" state)" review
check "a submitted record cannot start another builder" test ! -s "$TEST_CALLS"
check "the skip names its current review state" contains "$out" 'no longer open (review)'

RID2="$(E new 'Repair the shed hinge' --body 'Repair the shed hinge and test it.')"
export TEST_PICK="$RID2"
out="$(run_night TEST_STATE_CHANGE=settle)"
check_eq "a concurrent closure stands" "$(E field "$RID2" state)" settled
check "a settled record cannot start another builder" test ! -s "$TEST_CALLS"

RID3="$(E new 'Repair the window catch' --body 'Repair the window catch and test it.')"
export TEST_PICK="$RID3"
out="$(run_night DESKCRAB_NO_DISPATCH=1 TEST_STATE_CHANGE=kill)"
check "dry selection also honours a concurrent closure" test ! -s "$TEST_CALLS"
check "a closed dry pick is skipped before would-dispatch" contains "$out" 'no longer open (dead)'
check "dry selection never writes a dispatch ledger" test ! -e "$SANDBOX/ledger.tsv"

RID4="$(E new 'Repair the garden gate' --body 'Repair and verify the garden gate.')"
export TEST_PICK="$RID4"
out="$(run_night TEST_DUPLICATE=1)"
check_eq "a repeated record in one answer starts only one builder" \
    "$(sandbox_count_in . "$TEST_CALLS")" 1

RID5="$(E new 'Repair the cold frame' --body 'Repair and verify the cold frame.')"
export TEST_PICK="$RID5"
out="$(run_night TEST_ACTIVE_JOB=1)"
check "a concurrent job against the record prevents a duplicate dispatch" test ! -s "$TEST_CALLS"
