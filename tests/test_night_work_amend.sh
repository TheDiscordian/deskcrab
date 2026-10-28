#!/bin/bash
# The night composes from a record's CURRENT instructions and holds every
# brief against the record's newest state at the door — specs/nightly.md
# rules 58c and 60b over specs/engineering-records.md rules 7a and 9a. The
# origin (2026-08-21 18:22): the store brief was rewritten to drop the exact
# block from the move prompt, and the builder dispatched thirty seconds later
# still carried the old plan. Four fixtures: an explicit removal, one
# requirement amended while others remain active, an unchanged record, and an
# amendment landing between composition and dispatch. The MODEL is stubbed:
# what these prove is what reaches the selector and what reaches the door.
# Run: bash tests/test_night_work_amend.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
export TEST_RECORDS="$T/records" TEST_CALLS="$T/door.jsonl" TEST_PROMPTS="$T/prompts" SANDBOX_REPO
mkdir -p "$TEST_RECORDS" "$T/jobs" "$TEST_PROMPTS"
E() { DESKCRAB_ENG_DIR="$TEST_RECORDS" python3 "$REPO/lib/eng" "$@"; }
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

# The door, stubbed: every `job` call recorded as its argv, one line each.
cat > "$T/crab" <<'DOOR'
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1] == 'job':
    with open(os.environ['TEST_CALLS'], 'a') as f:
        f.write(json.dumps(sys.argv[1:]) + '\n')
    n = sum(1 for _ in open(os.environ['TEST_CALLS']))
    print('Job stub-%d dispatched (unit deskcrab-job-stub-%d) — detached.' % (n, n))
elif sys.argv[1] == 'jobs':
    print('Detached jobs: (none)')
DOOR
chmod +x "$T/crab"

# The selector, stubbed as a judge that composes from what it is handed:
# each call keeps its prompt; the brief for TEST_PICK carries the sentence
# TEST_SENTENCE exactly when that sentence is in the prompt (TEST_FORCE=1
# carries it regardless — the judge that read a stale copy). TEST_AMEND /
# TEST_TOUCH make the FIRST call amend or touch the record mid-call, after
# the night composed its view and before it reaches the door.
sandbox_stub claude <<'MODEL'
#!/usr/bin/env python3
import os, pathlib, subprocess, sys, json
prompt = sys.stdin.read()
d = pathlib.Path(os.environ['TEST_PROMPTS'])
n = len(list(d.glob('call-*'))) + 1
(d / ('call-%d' % n)).write_text(prompt)
pick = os.environ['TEST_PICK']
sentence = os.environ.get('TEST_SENTENCE', '')
env = dict(os.environ, DESKCRAB_ENG_DIR=os.environ['TEST_RECORDS'])
eng = [sys.executable, os.environ['SANDBOX_REPO'] + '/lib/eng']
if n == 1 and os.environ.get('TEST_AMEND'):
    subprocess.run(eng + ['amend', pick, '--supersedes', os.environ['TEST_AMEND'],
                   'Decided mid-call: that requirement is dropped; build the rest only.'],
                   env=env, stdout=subprocess.DEVNULL, check=True)
if n == 1 and os.environ.get('TEST_TOUCH'):
    subprocess.run(eng + ['touch', pick, os.environ['TEST_TOUCH']],
                   env=env, stdout=subprocess.DEVNULL, check=True)
carry = sentence and (os.environ.get('TEST_FORCE') or sentence in prompt)
brief = ('In ' + os.environ['TEST_WD'] + ', from the record ' + pick + ': '
         + (sentence + ' ' if carry else '')
         + 'Build what the record currently asks, run the suite, and write the outcome on the record.')
answer = 'TASK: %s | %s | %s\nBRIEF:\n%s\nEND' % (pick, os.environ['TEST_WD'],
         os.environ.get('TEST_TITLE', 'The night pick'), brief)
print(json.dumps({'type': 'assistant', 'message': {'model': 'stub',
      'content': [{'type': 'text', 'text': answer}]}}))
print(json.dumps({'type': 'result', 'result': 'ok'}))
MODEL

# A git work tree for the pick's workdir (rule 60a is not the subject here).
export TEST_WD="$T/repo"
mkdir -p "$TEST_WD" && git -C "$TEST_WD" init -q

ROUNDS=1
run_night() {  # [env overrides...] — $ROUNDS rounds, polling fast, cutoff an hour out
    rm -f "$TEST_CALLS" "$T/ledger.tsv"; rm -f "$TEST_PROMPTS"/call-*
    env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
        NIGHT_WORK_RECORDS_DIR="$TEST_RECORDS" \
        NIGHT_WORK_LEDGER="$T/ledger.tsv" NIGHT_WORK_MODEL=stub-claude \
        NIGHT_WORK_CUTOFF="@$(( $(date +%s) + 3600 ))" \
        NIGHT_WORK_POLL=1 NIGHT_WORK_ROUNDS_MAX="$ROUNDS" \
        "$@" "$REPO/lib/night-work" run 2>"$T/stderr"
}
door_calls() { sandbox_count_in . "$TEST_CALLS"; }
door_brief() { python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())[-1])' "$TEST_CALLS" 2>/dev/null; }
prompt_n() { ls "$TEST_PROMPTS"/call-* 2>/dev/null | wc -l; }
retire() {  # <id> — every open record but this one leaves the shelf, so one batch judges one record
    local f; for f in "$TEST_RECORDS"/*.md; do
        [ "$(basename "$f" .md)" = "$1" ] && continue
        E kill "$(basename "$f" .md)" 'out of this fixture' >/dev/null
    done
}

echo "an explicit removal: the retired paragraph never reaches the selector, and a brief"
echo "quoting it never reaches the door (rules 58c, 60b):"
EXACT='Add the exact block to the move prompt: when exact_lines is non-empty, return before the similar section.'
R1="$(E new 'The move prompt prints both memory blocks' --body "$EXACT

Keep the similar block as the fallback, with its win and loss counts attached.")"
E amend "$R1" --supersedes 'return before the similar section' 'Decided: the exact block leaves the move prompt entirely; the similar block alone is the memory.' >/dev/null
export TEST_PICK="$R1" TEST_SENTENCE="$EXACT" TEST_TITLE='Drop the exact block'
sleep 1
out="$(run_night)"
check_eq "the selector was asked once" "$(prompt_n)" "1"
refute "the retired instruction is absent from the prompt" grep -qF "return before the similar section" "$TEST_PROMPTS/call-1"
check "its stub rides in its place" grep -qF "a paragraph here was superseded by the amendment of" "$TEST_PROMPTS/call-1"
check "the live neighbour rides" grep -qF "Keep the similar block as the fallback" "$TEST_PROMPTS/call-1"
check "and so does the amendment" grep -qF "the exact block leaves the move prompt entirely" "$TEST_PROMPTS/call-1"
check "the selector is told to compose from the current instructions" \
    grep -qF "never from its" "$TEST_PROMPTS/call-1"
check_eq "a judge that saw no retired words dispatches" "$(door_calls)" "1"
B="$(door_brief)"
refute "and the dispatched brief carries none of them" contains "$B" "return before the similar section"
check "the brief carries the live work" contains "$B" "Build what the record currently asks"
refute "neither check spoke" contains "$out" "rule 60b"

out="$(run_night TEST_FORCE=1)"
check_eq "a judge that quotes the retired sentence anyway: nothing reaches the door" "$(door_calls)" "0"
check "the refusal is loud on the night log, naming the record" \
    contains "$out" "dispatch REFUSED for '$R1' — the brief quotes an instruction the record has superseded"
check "and the quoted sentence, whole" contains "$out" "\"$EXACT\""
check "and the title" contains "$out" "Drop the exact block"
check "and on stderr" grep -qF "dispatch REFUSED for '$R1'" "$T/stderr"
check "no ledger line was written" test ! -e "$T/ledger.tsv"

echo
echo "one requirement amended while two remain active:"
retire "$R1"
R2="$(E new 'The table shows three things' --body 'Show the clock on the table, top right, in the room font.

Show the move list under the board, newest move last.

Show the engine evaluation bar beside the board, updated every move.')"
E amend "$R2" --supersedes 'engine evaluation bar' 'Decided: no evaluation bar on the table; the clock and the move list stand.' >/dev/null
export TEST_PICK="$R2" TEST_SENTENCE='Show the engine evaluation bar beside the board, updated every move.' TEST_TITLE='Three things on the table'
sleep 1
out="$(run_night)"
check "the two live requirements ride the prompt — the clock" grep -qF "Show the clock on the table" "$TEST_PROMPTS/call-1"
check "and the move list" grep -qF "Show the move list under the board" "$TEST_PROMPTS/call-1"
refute "the retired one does not" grep -qF "evaluation bar beside the board" "$TEST_PROMPTS/call-1"
check "the amendment rides" grep -qF "no evaluation bar on the table" "$TEST_PROMPTS/call-1"
check_eq "and the brief composed from the live two dispatches" "$(door_calls)" "1"
check "with the record attached" bash -c 'grep -qF "\"--record\", \"$1\"" "$2"' _ "$R2" "$TEST_CALLS"
out="$(run_night TEST_FORCE=1)"
check_eq "a brief still asking for the retired bar is refused" "$(door_calls)" "0"
check "naming the bar" contains "$out" "evaluation bar beside the board"

echo
echo "an unchanged record rides byte-identical to its file and dispatches with neither check speaking:"
retire "$R2"
R3="$(E new 'The greenhouse latch sticks' --body 'Free the latch, oil the hinge, and close the door twice to verify.')"
export TEST_PICK="$R3" TEST_SENTENCE='' TEST_TITLE='Free the latch'
sleep 1
out="$(run_night)"
check "the record's whole file is in the prompt" \
    bash -c 'python3 - "$1" "$2" <<'"'"'PY'"'"'
import sys
rec = open(sys.argv[1]).read()
prompt = open(sys.argv[2]).read()
sys.exit(0 if rec.rstrip("\n") in prompt else 1)
PY' _ "$TEST_RECORDS/$R3.md" "$TEST_PROMPTS/call-1"
check_eq "it dispatches" "$(door_calls)" "1"
refute "nothing was called stale" contains "$out" "STALE"
refute "nothing was refused" contains "$out" "REFUSED"
check "the ledger carries it" grep -qF "$R3" "$T/ledger.tsv"

echo
echo "an amendment between composition and dispatch: the stale brief never reaches the"
echo "door, the record is judged again at once, and the regenerated brief dispatches without"
echo "the dropped sentence (rule 60b):"
retire "$R3"
DROP='Also rewrite the store brief to request the exact block from the move prompt.'
R4="$(E new 'The store brief and the move prompt' --body "Teach the store to key on FEN regardless of colour.

$DROP")"
export TEST_PICK="$R4" TEST_SENTENCE="$DROP" TEST_TITLE='The store brief'
sleep 1
ROUNDS=2
out="$(run_night TEST_AMEND='request the exact block')"
check "the first prompt carried the sentence the judge would quote" grep -qF "$DROP" "$TEST_PROMPTS/call-1"
check "the night saw the record move and called the brief stale" \
    contains "$out" "round 1: '$R4' moved since its brief was composed"
check "naming when it was last touched" contains "$out" "last touched $(E field "$R4" last_touched)"
check "and that it is judged again" contains "$out" "judged again from its current instructions (rule 60b)"
check_eq "the record was judged again at once — a second selection call" "$(prompt_n)" "2"
refute "the second prompt carries the dropped sentence no more" grep -qF "$DROP" "$TEST_PROMPTS/call-2"
check "but its stub" grep -qF "a paragraph here was superseded" "$TEST_PROMPTS/call-2"
check "and the amendment" grep -qF "that requirement is dropped" "$TEST_PROMPTS/call-2"
check_eq "exactly one builder went out" "$(door_calls)" "1"
B="$(door_brief)"
refute "and its brief carries no word of the dropped instruction" contains "$B" "request the exact block"
check "it carries the live instruction's work" contains "$B" "Build what the record currently asks"
check_eq "one ledger line" "$(wc -l < "$T/ledger.tsv")" "1"
check "the record on disk keeps the dropped words under the marker (history, rule 7a)" \
    grep -qF "> $DROP" "$TEST_RECORDS/$R4.md"

echo
echo "a plain touch in the same window is a moved record too:"
R5="$(E new 'The chess clock drifts' --body 'Resync the clock from the server every move and verify against a stopwatch.')"
retire "$R5"
export TEST_PICK="$R5" TEST_SENTENCE='' TEST_TITLE='The clock'
sleep 1
out="$(run_night TEST_TOUCH='A correction: verify against the server clock, not a stopwatch.')"
check "the touched record was called stale" contains "$out" "round 1: '$R5' moved since its brief was composed"
check_eq "and judged again" "$(prompt_n)" "2"
check "the second prompt carries the correction" grep -qF "verify against the server clock" "$TEST_PROMPTS/call-2"
check_eq "one builder went out, from the second composition" "$(door_calls)" "1"

echo
echo "the dry run holds both checks before its would-dispatch line and writes no ledger (rule 61):"
R6="$(E new 'The dry pick' --body 'Paint the fence white, two coats, before the rain.

Paint the gate black, with two coats and a primer.')"
retire "$R6"
E amend "$R6" --supersedes 'gate black' 'The gate stays unpainted.' >/dev/null
export TEST_PICK="$R6" TEST_SENTENCE='Paint the gate black, with two coats and a primer.' TEST_TITLE='The dry pick'
sleep 1
out="$(run_night DESKCRAB_NO_DISPATCH=1 TEST_FORCE=1)"
check "the dry run refuses the quoting brief" contains "$out" "dispatch REFUSED for '$R6'"
refute "and never says it would dispatch" contains "$out" "would dispatch '$R6'"
check_eq "nothing reached the door" "$(door_calls)" "0"
check "no ledger" test ! -e "$T/ledger.tsv"
out="$(run_night DESKCRAB_NO_DISPATCH=1 TEST_AMEND='fence white')"
check "a dry pick gone stale is named stale" contains "$out" "'$R6' moved since its brief was composed"
check "and would dispatch from the second composition" contains "$out" "round 2: would dispatch '$R6'"
check_eq "nothing reached the door" "$(door_calls)" "0"
check "no ledger" test ! -e "$T/ledger.tsv"
