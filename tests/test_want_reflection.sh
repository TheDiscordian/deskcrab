#!/bin/bash
# The nightly want reflection — specs/nightly.md rules 53g-53j, the record
# let-wants-emerge-from-lived-experience-during-sl (2026-09-09). Sleep may
# let a new want rise from the day actually lived, and may not manufacture
# one: the lived day and the drawer's standing reach the night judge, a
# builder's row never does, NOTHING writes not one byte, and a WANT lands
# exactly one want through the wants tool alone — the drawer and the shelf
# exactly as specs/wants.md keeps them. Run: bash tests/test_want_reflection.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

DAY="2026-09-08"
codex_n() { sandbox_count_in '^exec' "$SANDBOX_CODEX_LOG"; }

# The judge, stubbed at the engine: the real walk (common.sh, nightly-judge,
# codex-stream, extract-response) runs whole, the stub records the exact
# prompt it was handed and answers whatever $T/reply.txt holds.
sandbox_stub codex <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${SANDBOX_CODEX_LOG:-/dev/null}"
if [ "\${1:-}" = "app-server" ]; then exit 75; fi
cat > "$T/prompt-last"
python3 - "$T/reply.txt" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
print(json.dumps({"type": "thread.started", "thread_id": "stub"}))
print(json.dumps({"type": "turn.started"}))
print(json.dumps({"type": "item.completed",
                  "item": {"id": "item_0", "type": "agent_message",
                           "text": text}}))
print(json.dumps({"type": "turn.completed",
                  "usage": {"input_tokens": 1, "cached_input_tokens": 0,
                            "cache_write_input_tokens": 0,
                            "output_tokens": 1}}))
PY
exit 0
STUB

# The day as lived: a desk turn, a wake's quiet hour, and a builder's log
# entry that is NOT her lived day and must never reach the reflection.
mkdir -p "$T/journal"
cat > "$T/journal/$DAY.jsonl" <<'EOF'
{"epoch": 1757304000, "time": "2026-09-08T00:00:00-0400", "kind": "desk", "duration": 30, "user": "I watched a heron by the reservoir today, longer than I meant to.", "reply": "You lingered on the heron longer than the errand wanted. That sounds like the best part of the day.", "pid": 101}
{"epoch": 1757311200, "time": "2026-09-08T02:00:00-0400", "kind": "wake", "duration": 60, "user": "", "reply": "Quiet hour. I read about tide clocks and let it stay idle reading.", "pid": 102}
{"epoch": 1757314800, "time": "2026-09-08T03:00:00-0400", "kind": "job", "duration": 500, "user": "builder brief", "reply": "BUILDERNOISE: 47 tests passed, branch pushed.", "pid": 103}
EOF

# The drawer: one live want, one dormant — the unfinished attraction the
# reflection must see and never re-invent.
mkdir -p "$T/wants"
printf '# The shelf\n' > "$T/wants.md"
wanttool() {
    env DESKCRAB_WANTS_DIR="$T/wants" DESKCRAB_WANTS_FILE="$T/wants.md" \
        python3 "$REPO/lib/eng" --kind want "$@"
}
wanttool new "night walks" --summary "walking at night" \
    --body "I like walking at night." >/dev/null
wanttool new "old maps" --summary "maps" --body "Old maps pull at me." >/dev/null
wanttool dormant old-maps "resting on purpose" >/dev/null

run_reflect() {
    env DAY_JOURNAL_DIR="$T/journal" \
        DESKCRAB_WANTS_DIR="$T/wants" \
        DESKCRAB_WANTS_FILE="$T/wants.md" \
        DESKCRAB_CODEX_STATE="$T/cx-state" \
        "$@" "$REPO/lib/want-reflect" run "$DAY" 2>&1
}
drawer_hash() {
    { find "$T/wants" -type f | LC_ALL=C sort | xargs cat 2>/dev/null
      cat "$T/wants.md"; } | md5sum | cut -d' ' -f1
}
docs_n() { find "$T/wants" -type f -name '*.md' | wc -l; }

echo "a NOTHING night: the lived day reaches the judge, and not one byte is written:"
printf 'NOTHING — a full day, and nothing new pulls at me.\n' > "$T/reply.txt"
BEFORE="$(drawer_hash)"
out="$(run_reflect)"; rc=$?
check_eq "the phase exits zero" "$rc" "0"
check "and says no new want in its own name" \
    contains "$out" "want-reflect: no new want tonight"
check_eq "one judge call was spent" "$(codex_n)" "1"
[ -f "$T/prompt-last" ] || die "the judge saw no prompt" "$out"
check "her lived day reached the judge" \
    grep -q "heron by the reservoir" "$T/prompt-last"
check "the wake's quiet hour reached it too" \
    grep -q "tide clocks" "$T/prompt-last"
check "and the user's words beside hers" \
    grep -q "the user:" "$T/prompt-last"
check "the live want's title stands in the drawer section" \
    grep -q "night walks" "$T/prompt-last"
check "and the dormant one beside it" grep -q "old maps" "$T/prompt-last"
check "the honest default is stated in the prompt's own words" \
    grep -q "MOST NIGHTS FORM NO NEW WANT" "$T/prompt-last"
check_eq "a builder's row never enters the reflection" \
    "$(sandbox_count_in 'BUILDERNOISE' "$T/prompt-last")" "0"
check_eq "the drawer and the shelf are byte-identical" "$(drawer_hash)" "$BEFORE"
check_eq "still two documents" "$(docs_n)" "2"

echo
echo "a WANT verdict: exactly one want, through the wants tool alone:"
cat > "$T/reply.txt" <<'EOF'
WANT — small hours reading
The day kept circling back to the old radio manuals, and I stayed past the
point the errand needed. I would choose an hour with them for its own sake,
not to fix anything.
EOF
out="$(run_reflect)"; rc=$?
check_eq "the phase exits zero" "$rc" "0"
check "and names the want it formed" contains "$out" "formed one want tonight"
check_eq "a second judge call, not a re-ask" "$(codex_n)" "2"
DOC="$T/wants/small-hours-reading.md"
[ -f "$DOC" ] && ok "the document exists under the tool's own slug" \
    || fail "no want document at $DOC" "$out"
check_eq "state is live" "$(wanttool field small-hours-reading state)" "live"
check_eq "the title is the judge's" \
    "$(wanttool field small-hours-reading title)" "small hours reading"
check "the summary names the day it rose from" \
    contains "$(wanttool field small-hours-reading summary)" "$DAY"
check "her first-person sentences are the opening body" \
    grep -q "for its own sake" "$DOC"
check "with the reflection's provenance named in it" \
    grep -q "nightly want reflection" "$DOC"
check "opened is stamped" test -n "$(wanttool field small-hours-reading opened)"
check_eq "the shelf line landed in the one shape the shelf reader matches" \
    "$(tail -1 "$T/wants.md")" "- **small hours reading** → small-hours-reading.md"
check_eq "and exactly one document was added" "$(docs_n)" "3"

echo
echo "a title the drawer already carries, differently cased, is not re-recorded:"
AFTER_WANT="$(drawer_hash)"
printf 'WANT — Night Walks\nI want to walk at night again.\n' > "$T/reply.txt"
out="$(run_reflect)"; rc=$?
check_eq "the phase exits zero" "$rc" "0"
check "the standing want is named" contains "$out" "already carries"
check_eq "nothing was written" "$(drawer_hash)" "$AFTER_WANT"
check_eq "still three documents" "$(docs_n)" "3"

echo
echo "an ambiguous verdict — both tokens on one line — forms nothing:"
printf 'WANT — no, wait: NOTHING really pulls tonight.\n' > "$T/reply.txt"
out="$(run_reflect)"; rc=$?
check_eq "the phase exits zero" "$rc" "0"
check "the ambiguity is named" contains "$out" "ambiguous"
check_eq "and nothing was written" "$(drawer_hash)" "$AFTER_WANT"

echo
echo "a day that was not lived spends no judge at all:"
N="$(codex_n)"
out="$(env DAY_JOURNAL_DIR="$T/journal" DESKCRAB_WANTS_DIR="$T/wants" \
    DESKCRAB_WANTS_FILE="$T/wants.md" DESKCRAB_CODEX_STATE="$T/cx-state" \
    "$REPO/lib/want-reflect" run 2020-01-01 2>&1)"; rc=$?
check_eq "the phase exits zero" "$rc" "0"
check "and says so in its own name" contains "$out" "no journal for 2020-01-01"
check_eq "no judge call was spent" "$(codex_n)" "$N"

echo
echo "a day of only builder rows is a day with no turn of her own:"
DAY3="2026-09-07"
printf '%s\n' '{"epoch": 1757217600, "time": "2026-09-07T00:00:00-0400", "kind": "job", "user": "brief", "reply": "BUILDERNOISE only.", "pid": 104}' \
    > "$T/journal/$DAY3.jsonl"
out="$(env DAY_JOURNAL_DIR="$T/journal" DESKCRAB_WANTS_DIR="$T/wants" \
    DESKCRAB_WANTS_FILE="$T/wants.md" DESKCRAB_CODEX_STATE="$T/cx-state" \
    "$REPO/lib/want-reflect" run "$DAY3" 2>&1)"; rc=$?
check_eq "the phase exits zero" "$rc" "0"
check "and says nothing was lived" contains "$out" "no turn of her own"
check_eq "no judge call was spent" "$(codex_n)" "$N"

echo
echo "switched off, it says so and spends nothing:"
out="$(run_reflect WANT_REFLECT_ENABLED=0)"; rc=$?
check_eq "the phase exits zero" "$rc" "0"
check "and says it is off" contains "$out" "switched off"
check_eq "no judge call was spent" "$(codex_n)" "$N"
check_eq "and nothing was written" "$(drawer_hash)" "$AFTER_WANT"

echo
echo "the wiring: sleep runs the reflection after the merge pass, before the"
echo "night's work:"
cat > "$T/crab-ok" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest") echo "ingest: 1 added, 0 superseded, 0 duplicates, 0 rejected" ;;
    "memory backfill-keys") echo "backfill-keys: stub — nothing to key" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-ok"
mkdir -p "$T/lib-order"
for n in claudism-scan promise-check eng-merge want-reflect night-work; do
    printf '#!/bin/bash\necho "%s: stub — nothing to do"\nexit 0\n' "$n" \
        > "$T/lib-order/$n"
    chmod +x "$T/lib-order/$n"
done
out="$(env CRAB_BIN="$T/crab-ok" XDG_DATA_HOME="$T/data-order" \
    bash -c 'source "$1" || exit 9; LIB_DIR="$2"; cmd_run' \
    _ "$REPO/lib/sleep-nightly" "$T/lib-order" 2>&1)"; rc=$?
check_eq "the night exits with the ingest's zero" "$rc" "0"
LOG="$(ls "$T/data-order/deskcrab/sleep/"*.log 2>/dev/null | head -1)"
[ -n "$LOG" ] || die "no night log written" "$out"
check_eq "no phase drew the PHASE SILENT complaint" \
    "$(sandbox_count_in 'PHASE SILENT' "$LOG")" "0"
MERGE_AT="$(grep -n '^eng-merge:' "$LOG" | head -1 | cut -d: -f1)"
REFLECT_AT="$(grep -n '^want-reflect:' "$LOG" | head -1 | cut -d: -f1)"
WORK_AT="$(grep -n '^night-work:' "$LOG" | head -1 | cut -d: -f1)"
[ -n "$MERGE_AT" ] && [ -n "$REFLECT_AT" ] && [ -n "$WORK_AT" ] \
    || die "a phase left no line: merge=$MERGE_AT reflect=$REFLECT_AT work=$WORK_AT" "$out"
[ "$MERGE_AT" -lt "$REFLECT_AT" ] \
    && ok "the reflection speaks after the merge pass" \
    || fail "the reflection must follow the merge pass (merge at $MERGE_AT, reflect at $REFLECT_AT)"
[ "$REFLECT_AT" -lt "$WORK_AT" ] \
    && ok "and before the night's work" \
    || fail "the reflection must precede the night's work (reflect at $REFLECT_AT, work at $WORK_AT)"
