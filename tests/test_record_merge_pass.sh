#!/bin/bash
# The twin-merge pass — specs/nightly.md rules 53b-53e. Run: bash tests/test_record_merge_pass.sh
#
# The gap this was written for: the memory store has had a merge-identical-
# ideas discipline from the start (memory-recall.md rules 28, 39, 51), but
# NOTHING ever read two engineering records and noticed they are the same
# complaint written on different nights — the night's-work "dedupe" (rules
# 56a and 59) only stops one record being dispatched twice. lib/eng-merge is
# the pass that notices: embed and score every open pair, judge candidates on
# the phase-2 model, propose merges — dry-run without --apply, and under
# --apply, which the nightly path passes, folding ONLY what the judge is
# confident about at or above the ENG_MERGE_FOLD_CONFIDENCE gate (default
# certain); a MERGE LIKELY and a confidence-less MERGE stay proposals.
#
# The embedder cases run against the REAL local ollama daemon on purpose —
# a mocked embedder cannot prove semantic scoring (the sandbox's own rule).
# The scores asserted against below were measured 2026-08-24 on
# nomic-embed-text: the twin pair 0.8914, the same-area phone pair 0.8064,
# the second phone pair 0.7777, every chess pair at or under 0.6617. The
# case threshold of 0.75 sits clear of all of them on both sides.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u
sandbox_need_ollama

REPO="$SANDBOX_REPO"
T="$SANDBOX"
R="$T/eng/records"
mkdir -p "$R"

# The fixtures: one TRUE twin pair (the same phone-playback collapse written
# on two different nights, in different words), a NEGATIVE corpus of
# same-area-but-distinct records (a second phone-playback complaint that is
# its own defect, and two different chess complaints), and a settled decoy
# whose text is nearly the twin's — however similar, a settled record must
# never be scored or judged (rule 53b: open records only).
cat > "$R/phone-says-nothing-clip-on-disk.md" <<'EOF'
---
id: phone-says-nothing-clip-on-disk
title: the phone spoke nothing though the clip is on disk
opened: 2026-08-18 01:00:00
last_touched: 2026-08-18 01:00:00
state: open
summary: playback dies silently after synthesis
---

## 2026-08-18 01:00:00

The reply text showed on the handset, synthesis reported success and the
audio clip sits on disk, but no sound ever played and no error line anywhere
says why. The playback path dies silently somewhere after synthesis.
EOF
cat > "$R/handset-shows-words-voice-never-arrives.md" <<'EOF'
---
id: handset-shows-words-voice-never-arrives
title: the handset shows my words but the voice never arrives
opened: 2026-08-21 01:00:00
last_touched: 2026-08-21 01:00:00
state: open
summary: the same silence, written again
---

## 2026-08-21 01:00:00

Again tonight the phone displayed the reply but spoke nothing. The clip was
synthesised and written out whole, playback simply never started on the
handset, and nothing was logged about why the audio went unplayed.
EOF
cat > "$R/clips-play-at-double-speed.md" <<'EOF'
---
id: clips-play-at-double-speed
title: phone clips play at double speed
opened: 2026-08-19 01:00:00
last_touched: 2026-08-19 01:00:00
state: open
summary: same area, different defect
---

## 2026-08-19 01:00:00

Playback starts at once but every clip comes out at double speed and a high
chipmunk pitch, unlistenable. The audio is present and audible — the sample
rate the player assumes simply does not match the one the synthesiser wrote.
EOF
cat > "$R/the-mover-walks-into-the-same-opening-trap.md" <<'EOF'
---
id: the-mover-walks-into-the-same-opening-trap
title: the mover walks into the same opening trap
opened: 2026-08-17 01:00:00
last_touched: 2026-08-17 01:00:00
state: open
summary: a chess complaint
---

## 2026-08-17 01:00:00

Three games running as white the mover has walked into the identical knight
fork line by move eight. The opening book never learns the refutation and
the game is lost before the middlegame arrives.
EOF
cat > "$R/the-chess-wake-speaks-during-quiet-hours.md" <<'EOF'
---
id: the-chess-wake-speaks-during-quiet-hours
title: the chess wake speaks during quiet hours
opened: 2026-08-20 01:00:00
last_touched: 2026-08-20 01:00:00
state: open
summary: a different chess complaint
---

## 2026-08-20 01:00:00

A game-reminder wake booked by the chess watcher fired at seven in the
morning inside quiet hours and spoke over a meeting. The wake gate should
hold chess chatter until the quiet window ends.
EOF
cat > "$R/the-phone-went-silent-settled-decoy.md" <<'EOF'
---
id: the-phone-went-silent-settled-decoy
title: the phone went silent (a settled decoy)
opened: 2026-08-16 01:00:00
last_touched: 2026-08-22 01:00:00
state: settled
settled_at: 2026-08-22 01:00:00
settled_by: the mixer was muted; unmuted and verified
summary: near-twin text, but settled
---

## 2026-08-16 01:00:00

The reply text showed on the handset, the clip was synthesised and sits on
disk, and no sound ever played. SETTLED-DECOY-MARK.
EOF

records_sha() { sha256sum "$1"/*.md | sha256sum | cut -d' ' -f1; }

# The judge, stubbed: every call recorded — argv to the claude log, stdin to
# its own numbered file — answering for the one true twin pair with the
# verdict line given (default MERGE CERTAIN, the confident form rule 53c
# asks for) and DISTINCT for everything else. The verdict must carry no
# single quote: it lands inside one below.
judge_stub() {  # [twin verdict line]
    local V_TWIN="${1:-MERGE CERTAIN — one complaint written twice: the phone shows the reply and plays nothing}"
    sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
IN="\$(cat)"
n=\$(( \$(cat "$T/judge-n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$T/judge-n"
printf '%s\n' "\$IN" > "$T/judge-stdin-\$n"
# Matched on the prompt's own record HEADERS, not on ids anywhere in the
# stdin: after a fold the winner's file legitimately carries the loser's id
# in its fold entry, and a substring match would call every later pair
# involving the winner a twin.
case "\$IN" in
    *"RECORD 1: phone-says-nothing-clip-on-disk"*"RECORD 2: handset-shows-words-voice-never-arrives"*|*"RECORD 1: handset-shows-words-voice-never-arrives"*"RECORD 2: phone-says-nothing-clip-on-disk"*)
        V='$V_TWIN' ;;
    *)  V='DISTINCT — the same area, two different defects' ;;
esac
printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"%s"}]}}\n' "\$V"
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
}
claude_n() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
reset()    { rm -f "$SANDBOX_CLAUDE_LOG" "$T/judge-n" "$T"/judge-stdin-*; }
judged_stdin() { cat "$T"/judge-stdin-* 2>/dev/null; }

run_merge() {  # [env overrides...] <mode args...>
    local -a envs=()
    while [ $# -gt 0 ] && contains "$1" "="; do envs+=("$1"); shift; done
    env DESKCRAB_ENG_DIR="$R" ${envs[@]+"${envs[@]}"} "$REPO/lib/eng-merge" "$@" 2>&1
}

echo "score mode, against the real embedder — the semantics the threshold rests on:"
out="$(run_merge score)"; rc=$?
check_eq "score exits 0" "$rc" "0"
check "and counts the open records — the settled decoy is not among them" \
    contains "$out" "5 open records"
tsv="$(printf '%s\n' "$out" | grep -v '^eng-merge:')"
top="$(printf '%s\n' "$tsv" | head -1)"
if contains "$top" phone-says-nothing-clip-on-disk \
        && contains "$top" handset-shows-words-voice-never-arrives; then
    ok "the true twin pair outscores every other pair"
else
    fail "the true twin pair must outscore every other pair" "$top"
fi
TWIN_S="$(printf '%s\n' "$top" | cut -f1)"
check "and clears the candidate gate with margin (measured 0.8914)" \
    awk -v s="$TWIN_S" 'BEGIN { exit !(s >= 0.84) }'
CHESS_S="$(printf '%s\n' "$tsv" | awk -F'\t' '$2 ~ /opening-trap/ && $3 ~ /quiet-hours/ || $2 ~ /quiet-hours/ && $3 ~ /opening-trap/ { print $1 }')"
check "the two distinct chess complaints score under every case threshold (measured 0.6617)" \
    awk -v s="$CHESS_S" 'BEGIN { exit !(s != "" && s < 0.75) }'
check_eq "the settled decoy is never scored, however twin-shaped its text" \
    "$(printf '%s\n' "$out" | sandbox_count_in 'settled-decoy' /dev/stdin)" "0"

echo
echo "a dry run: the judge is the deciding gate, and nothing is written:"
reset; judge_stub
SHA_BEFORE="$(records_sha "$R")"
out="$(run_merge ENG_MERGE_THRESHOLD=0.75 run)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "the threshold bounds the candidates — three pairs reach the judge" \
    contains "$out" "3 candidate pair"
check_eq "one judgement call per candidate, no more" "$(claude_n)" "3"
check "the judge runs on the phase-2 model — opus, in the argv" \
    grep -q -- "--model opus" "$SANDBOX_CLAUDE_LOG"
check "the judgement prompt carries the conservative rule" \
    bash -c 'cat "$1"/judge-stdin-* 2>/dev/null | grep -q "same-COMPLAINT merges only, never same-AREA"' _ "$T"
check "down to its chess example" \
    bash -c 'cat "$1"/judge-stdin-* 2>/dev/null | grep -q "Two records about chess are not a merge"' _ "$T"
check "the prompt asks for the judge's confidence in the verdict's own tokens" \
    bash -c 'cat "$1"/judge-stdin-* 2>/dev/null | grep -q "MERGE CERTAIN"' _ "$T"
check "and carries the person's-ruling-outranks-yours line — the recovery path's teeth" \
    bash -c 'cat "$1"/judge-stdin-* 2>/dev/null | grep -q "a previous fold between them was wrong"' _ "$T"
check "and both records ride it whole — body prose included" \
    bash -c 'cat "$1"/judge-stdin-* 2>/dev/null | grep -q "no sound ever played"' _ "$T"
check "the twin fold is proposed, the earlier-opened record the winner" \
    contains "$out" "propose fold 'handset-shows-words-voice-never-arrives' -> 'phone-says-nothing-clip-on-disk'"
check "with its score on the proposal line" \
    bash -c 'printf "%s\n" "$1" | grep "propose fold" | grep -qE "score 0\.[0-9]+"' _ "$out"
check "and the judge's confidence beside it" \
    bash -c 'printf "%s\n" "$1" | grep "propose fold" | grep -q "judge certain"' _ "$out"
check_eq "the same-area phone pair, judged and answered DISTINCT, is not proposed" \
    "$(printf '%s\n' "$out" | sandbox_count_in "propose fold.*clips-play-at-double-speed" /dev/stdin)" "0"
check_eq "no chess pair was ever judged — both sat under the gate" \
    "$(judged_stdin | sandbox_count_in 'RECORD [12]:.*opening-trap' /dev/stdin)" "0"
check_eq "the settled decoy reached no judgement either" \
    "$(judged_stdin | sandbox_count_in 'settled-decoy' /dev/stdin)" "0"
check "dry-run says plainly that nothing was folded" \
    contains "$out" "nothing folded"
check_eq "and the records directory is byte-identical" "$(records_sha "$R")" "$SHA_BEFORE"

echo
echo "the default candidate gate is the measured 0.80:"
reset; judge_stub
out="$(run_merge run)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "and names it" contains "$out" "threshold 0.80"

echo
echo "the judged bound announces what it drops — never a silent cap:"
reset; judge_stub
out="$(run_merge ENG_MERGE_THRESHOLD=0.75 ENG_MERGE_MAX_JUDGED=1 run)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "the dropped candidates are counted out loud" \
    contains "$out" "drops 2 candidate pair"
check_eq "and exactly one call went to the judge" "$(claude_n)" "1"
check "the top-scoring pair was the one judged, and still proposes" \
    contains "$out" "propose fold 'handset-shows-words-voice-never-arrives'"

echo
echo "a judge that answers nothing parseable merges nothing — conservative:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"perhaps they are related, hard to say"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
SHA_BEFORE="$(records_sha "$R")"
out="$(run_merge ENG_MERGE_THRESHOLD=0.75 run)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "says the pair stands" contains "$out" "the pair stands"
check_eq "proposes nothing" \
    "$(printf '%s\n' "$out" | sandbox_count_in 'propose fold' /dev/stdin)" "0"
check_eq "writes nothing" "$(records_sha "$R")" "$SHA_BEFORE"

echo
echo "a judge that changes its mind mid-line merges nothing — the live shape"
echo "of 2026-08-24, 'MERGE — no, wait: DISTINCT — …', proposed two folds its"
echo "own sentence retracts:"
reset
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"MERGE — no, wait: DISTINCT — two different defects after all"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
SHA_BEFORE="$(records_sha "$R")"
out="$(run_merge ENG_MERGE_THRESHOLD=0.75 run)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "names the ambiguity and lets the pair stand" \
    contains "$out" "ambiguous verdict"
check_eq "proposes nothing on a retracted MERGE" \
    "$(printf '%s\n' "$out" | sandbox_count_in 'propose fold' /dev/stdin)" "0"
check_eq "writes nothing" "$(records_sha "$R")" "$SHA_BEFORE"

echo
echo "an embedder that does not answer scores nothing and merges nothing:"
reset; judge_stub
SHA_BEFORE="$(records_sha "$R")"
out="$(run_merge MEMORY_EMBED_URL=http://127.0.0.1:9/api/embed run)"; rc=$?
check_eq "exits 0 — a dead embedder never costs the night" "$rc" "0"
check "and says so in its own name" contains "$out" "is not answering"
check_eq "no judgement was attempted" "$(claude_n)" "0"
check_eq "and nothing moved" "$(records_sha "$R")" "$SHA_BEFORE"

echo
echo "--apply, on a fixture copy: the fold itself, through crab eng alone:"
reset; judge_stub
R2="$T/eng2/records"
mkdir -p "$R2"; cp "$R"/*.md "$R2"/
out="$(env DESKCRAB_ENG_DIR="$R2" ENG_MERGE_THRESHOLD=0.75 "$REPO/lib/eng-merge" run --apply 2>&1)"; rc=$?
check_eq "apply exits 0" "$rc" "0"
check "and says it folded" contains "$out" "folded 'handset-shows-words-voice-never-arrives' -> 'phone-says-nothing-clip-on-disk'"
W="$R2/phone-says-nothing-clip-on-disk.md"
L="$R2/handset-shows-words-voice-never-arrives.md"
eng2() { DESKCRAB_ENG_DIR="$R2" "$REPO/lib/eng" "$@"; }
check_eq "the winner keeps its earlier opened date" \
    "$(eng2 field phone-says-nothing-clip-on-disk opened)" "2026-08-18 01:00:00"
check_eq "and stays open" "$(eng2 field phone-says-nothing-clip-on-disk state)" "open"
check "its last_touched moved with the fold — the tool's write, not a hand's" \
    bash -c '[ "$(DESKCRAB_ENG_DIR='"$R2"' '"$REPO"'/lib/eng field phone-says-nothing-clip-on-disk last_touched)" != "2026-08-18 01:00:00" ]'
check "the winner's own body is still there, whole" \
    grep -q "no sound ever played and no error line anywhere" "$W"
check "and the loser's body now rides beside it — appended, nothing lost" \
    grep -q "synthesised and written out whole" "$W"
check "the fold left a note naming the merge — the loser, in the note's own words" \
    grep -q "Folded twin record 'handset-shows-words-voice-never-arrives'" "$W"
check "with the tool, the score and the judge's confidence on it" \
    bash -c 'grep "Folded twin record" "$1" | grep -qE "eng-merge --apply, score 0\.[0-9]+, judge certain"' _ "$W"
LT="$(eng2 field phone-says-nothing-clip-on-disk last_touched)"
check "and the note rides the tool's own dated heading — eng touch's write, heading and last_touched one instant" \
    grep -q "^## $LT" "$W"
check_eq "the loser is dead" \
    "$(eng2 field handset-shows-words-voice-never-arrives state)" "dead"
check "killed pointing at the winner's id" \
    bash -c 'DESKCRAB_ENG_DIR='"$R2"' '"$REPO"'/lib/eng field handset-shows-words-voice-never-arrives settled_by | grep -q "phone-says-nothing-clip-on-disk"'
check "and keeps its own body whole in the grave" \
    grep -q "playback simply never started" "$L"
check_eq "the negative corpus stands untouched — no same-area fold" \
    "$(eng2 field clips-play-at-double-speed state)" "open"

echo
echo "a second --apply finds nothing left — the loser is no longer open:"
reset; judge_stub
out="$(env DESKCRAB_ENG_DIR="$R2" ENG_MERGE_THRESHOLD=0.75 "$REPO/lib/eng-merge" run --apply 2>&1)"; rc=$?
check_eq "exits 0" "$rc" "0"
check_eq "and folds nothing twice" \
    "$(printf '%s\n' "$out" | sandbox_count_in "folded '" /dev/stdin)" "0"

echo
echo "--apply folds only at or above the fold gate — MERGE LIKELY stays a"
echo "proposal on the log, exactly as the dry run leaves it:"
reset; judge_stub 'MERGE LIKELY — probably the same silence, but a reading separates them'
R3="$T/eng3/records"
mkdir -p "$R3"; cp "$R"/*.md "$R3"/
SHA_BEFORE="$(records_sha "$R3")"
out="$(env DESKCRAB_ENG_DIR="$R3" ENG_MERGE_THRESHOLD=0.75 "$REPO/lib/eng-merge" run --apply 2>&1)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "the pair is still proposed, its confidence named" \
    bash -c 'printf "%s\n" "$1" | grep "propose fold .handset-shows-words-voice-never-arrives" | grep -q "judge likely"' _ "$out"
check "and named as standing below the gate, a hand's to fold" \
    contains "$out" "stays a proposal — the judge said likely, the fold gate wants certain"
check_eq "nothing folded" \
    "$(printf '%s\n' "$out" | sandbox_count_in "folded '" /dev/stdin)" "0"
check_eq "and the records are byte-identical" "$(records_sha "$R3")" "$SHA_BEFORE"

echo
echo "an unrecognised gate value reads as certain, never wider:"
out="$(env DESKCRAB_ENG_DIR="$R3" ENG_MERGE_THRESHOLD=0.75 ENG_MERGE_FOLD_CONFIDENCE=always "$REPO/lib/eng-merge" run --apply 2>&1)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "and says what it read" \
    contains "$out" "unrecognised ENG_MERGE_FOLD_CONFIDENCE 'always' — reading it as certain"
check_eq "the likely pair still does not fold" \
    "$(printf '%s\n' "$out" | sandbox_count_in "folded '" /dev/stdin)" "0"
check_eq "records byte-identical still" "$(records_sha "$R3")" "$SHA_BEFORE"

echo
echo "a bare MERGE that states no confidence — the old form, a judge that"
echo "ignored the asked-for tokens — never folds either:"
reset; judge_stub 'MERGE — one complaint written twice: the phone shows the reply and plays nothing'
R4="$T/eng4/records"
mkdir -p "$R4"; cp "$R"/*.md "$R4"/
SHA_BEFORE="$(records_sha "$R4")"
out="$(env DESKCRAB_ENG_DIR="$R4" ENG_MERGE_THRESHOLD=0.75 "$REPO/lib/eng-merge" run --apply 2>&1)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "the proposal names the unstated confidence" \
    bash -c 'printf "%s\n" "$1" | grep "propose fold" | grep -q "judge unstated"' _ "$out"
check "and stands below the gate" contains "$out" "stays a proposal"
check_eq "nothing folded" \
    "$(printf '%s\n' "$out" | sandbox_count_in "folded '" /dev/stdin)" "0"
check_eq "records byte-identical" "$(records_sha "$R4")" "$SHA_BEFORE"

echo
echo "the gate is ENG_MERGE_FOLD_CONFIDENCE — widened to likely by hand, a"
echo "MERGE LIKELY folds; that knob is where the threshold lives:"
reset; judge_stub 'MERGE LIKELY — probably the same silence after all'
R5="$T/eng5/records"
mkdir -p "$R5"; cp "$R"/*.md "$R5"/
out="$(env DESKCRAB_ENG_DIR="$R5" ENG_MERGE_THRESHOLD=0.75 ENG_MERGE_FOLD_CONFIDENCE=likely "$REPO/lib/eng-merge" run --apply 2>&1)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "and folds the likely pair" \
    contains "$out" "folded 'handset-shows-words-voice-never-arrives' -> 'phone-says-nothing-clip-on-disk'"
check "its fold note carrying judge likely" \
    bash -c 'grep "Folded twin record" "$1" | grep -q "judge likely"' _ "$R5/phone-says-nothing-clip-on-disk.md"
check_eq "the loser is dead" \
    "$(DESKCRAB_ENG_DIR="$R5" "$REPO/lib/eng" field handset-shows-words-voice-never-arrives state)" "dead"

echo
echo "the wiring: sleep runs the pass after the sweep, before the night's work,"
echo "and WITH --apply — the fold gate, not the flag, is what stays conservative:"
SEQ="$T/phase-seq"
mkdir -p "$T/stub-lib"
for n in claudism-scan promise-check eng-merge night-work; do
    cat > "$T/stub-lib/$n" <<STUB
#!/bin/bash
printf '%s %s\n' "$n" "\$*" >> "$SEQ"
echo "$n: stub — nothing tonight"
exit 0
STUB
    chmod +x "$T/stub-lib/$n"
done
cat > "$T/crab-ok" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest") echo "ingest: 1 added, 0 superseded, 0 duplicates, 0 rejected" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-ok"
out="$(env CRAB_BIN="$T/crab-ok" XDG_DATA_HOME="$T/night-data" \
    bash -c 'source "$1" || exit 9; LIB_DIR="$2"; cmd_run' \
    _ "$REPO/lib/sleep-nightly" "$T/stub-lib" 2>&1)"; rc=$?
check_eq "the night exits with the ingest's zero" "$rc" "0"
MERGE_AT="$(grep -n '^eng-merge ' "$SEQ" | head -1 | cut -d: -f1)"
SWEEP_AT="$(grep -n '^promise-check ' "$SEQ" | head -1 | cut -d: -f1)"
WORK_AT="$(grep -n '^night-work ' "$SEQ" | head -1 | cut -d: -f1)"
if [ -n "$MERGE_AT" ] && [ -n "$SWEEP_AT" ] && [ -n "$WORK_AT" ] \
        && [ "$SWEEP_AT" -lt "$MERGE_AT" ] && [ "$MERGE_AT" -lt "$WORK_AT" ]; then
    ok "the pass runs after the promise sweep and before the night's work"
else
    fail "the pass must run between the sweep and the night's work" \
        "sweep=$SWEEP_AT merge=$MERGE_AT work=$WORK_AT"
fi
check_eq "and the nightly path passes --apply — the confident folds land, the rest stay proposals" \
    "$(grep '^eng-merge ' "$SEQ" | head -1)" "eng-merge run --apply"

echo
echo "through the deployed symlink (rule 6a), with no records drawer at all:"
DEPLOY="$T/deploy"
ln -s "$REPO/lib" "$DEPLOY"
out="$(env DESKCRAB_ENG_DIR="$T/no-such-drawer" "$DEPLOY/eng-merge" run 2>&1)"; rc=$?
check_eq "exits 0" "$rc" "0"
check "speaks in its own name — no drawer is not a crash" \
    contains "$out" "eng-merge:"
if ! contains "$out" "No such file or directory" && ! contains "$out" "unbound variable"; then
    ok "no corpse voice: common.sh sourced, nothing unbound"
else
    fail "no corpse voice: common.sh sourced, nothing unbound" "$out"
fi
