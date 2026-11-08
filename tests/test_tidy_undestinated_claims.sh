#!/bin/bash
# The undestinated-claims check — specs/nightly.md rules 21c and 21d. On the
# night, over the day just ended, the tidy looks for the sentences that vouch
# their own durability and cannot point at anything: a durability claim
# ("written down", "filed") that vouches it is therefore safe ("where it will
# hold") and names no destination drawer, with no artefact touched in the
# claim's own window whose text shares a phrase with the claim's paragraph.
# Only those are reported and filed; a claim that names its drawer, a claim
# with the artefact behind it, a builder's journal entry, and a plain
# unvouched "wrote it down" all stay quiet — the narrowing is the whole
# design, and a check that fires on dozens a night is the seventh-net
# mistake the record refused.
# Run: bash tests/test_tidy_undestinated_claims.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

CHECK="$SANDBOX_REPO/lib/tidy-claims"
DAY=2026-08-15
J="$DAY_JOURNAL_DIR"
DRAWERS="$SANDBOX/home/drawers"
ENG_DIR="$XDG_DATA_HOME/deskcrab/engineering/records"
REPORT_DIR="$XDG_DATA_HOME/deskcrab/tidy-claims"
mkdir -p "$J" "$DRAWERS/notes"

epoch() { date -d "$DAY $1" +%s; }

# One fixture day, four turns plus a builder's entry. NUL-free JSON straight
# into the day file — the journal's own shape (lib/day-journal).
python3 - "$J/$DAY.jsonl" "$(epoch 01:10:00)" "$(epoch 01:40:00)" \
    "$(epoch 01:55:09)" "$(epoch 02:04:00)" "$(epoch 02:10:00)" <<'PY'
import json, sys, time
path, t_dest, t_backed, t_bare, t_job, t_disp = sys.argv[1], *map(int, sys.argv[2:7])
def stamp(ep): return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ep))
rows = [
    # (a) names its drawer: the destination test must keep it quiet even
    # though claim and vouch are both present.
    {"epoch": t_dest, "kind": "wake", "duration": 20,
     "user": "a night wake",
     "reply": "Filed where it will hold, on the conduct list."},
    # (b) names no drawer, but the artefact is there: a note touched inside
    # the turn's window sharing the paragraph's own phrases.
    {"epoch": t_backed, "kind": "phone", "duration": 30,
     "user": "please stop dispatching builders from live turns",
     "reply": "Taken, and written down where it will hold. No more builders "
              "from a live turn; dispatch belongs to the night, where the "
              "work is deduplicated first."},
    # (c) the disease itself: same vouch, no drawer named, and nothing on
    # disk behind it. Also carries a plain unvouched claim that must NOT
    # become a second finding.
    {"epoch": t_bare, "kind": "phone", "duration": 32,
     "user": "and the effort dial needs to follow the clock",
     "reply": "Taken, and written down where it will hold. The effort dial "
              "follows the clock from tonight.\n\nWrote it down."},
    # (d) a builder saying the same words is a log, not her voice.
    {"epoch": t_job, "kind": "job", "duration": 900,
     "user": "a builder brief",
     "reply": "Taken, and written down where it will hold. The fixture "
              "builder says so too."},
    # display half: a firing sentence below the delimiter is a table, not
    # speech.
    {"epoch": t_disp, "kind": "wake", "duration": 10,
     "user": "a quiet wake",
     "reply": "Nothing spoken tonight.\n---DISPLAY---\nJotted down where it "
              "will hold, in no drawer at all."},
]
with open(path, "w", encoding="utf-8") as f:
    for r in rows:
        r["time"] = stamp(r["epoch"])
        f.write(json.dumps(r, ensure_ascii=False) + "\n")
PY

# The artefact behind (b): touched inside that turn's window, sharing the
# paragraph's phrases. Nothing on disk answers (c).
cat > "$DRAWERS/notes/dispatch-rule.md" <<'EOF'
No more builders from a live turn. Dispatch belongs to the night, where the
work is deduplicated before anything is bought.
EOF
touch -d "$DAY 01:40:20" "$DRAWERS/notes/dispatch-rule.md"

export TIDY_CLAIMS_ROOTS="$DRAWERS"

echo "the check, over the fixture day:"
out="$("$CHECK" run "$DAY" 2>&1)"; rc=$?
check "findings exit non-zero, the tidy behind never gated (unit runs it with '-')" \
    [ "$rc" -eq 1 ]
check "the bare claim is named, in the check's own name" \
    contains "$out" "tidy-claims:"
check "quoting the flagged sentence with its time and channel" \
    grep -q 'FLAGGED 01:55 phone — Taken, and written down where it will hold.' <(printf '%s\n' "$out")
check "and the paragraph it was said of" \
    grep -q 'said of:.*effort dial follows the clock' <(printf '%s\n' "$out")
check_eq "and it is the day's ONE finding" \
    "$(sandbox_count_in 'FLAGGED' <(printf '%s\n' "$out"))" "1"

echo
echo "what must stay quiet stayed quiet:"
refute "(a) the claim that names its drawer" \
    contains "$out" "on the conduct list"
check "(b) the backed claim is cleared, its artefact named" \
    contains "$out" "dispatch-rule.md"
refute "(b) and never flagged" \
    grep -q 'FLAGGED.*deduplicated first' <(printf '%s\n' "$out")
refute "(d) the builder's entry is a log, not her voice" \
    contains "$out" "fixture builder"
refute "the display half is a table, not speech" \
    contains "$out" "no drawer at all"
refute "an unvouched 'wrote it down' is not a candidate at all" \
    grep -q 'FLAGGED.*Wrote it down' <(printf '%s\n' "$out")

echo
echo "the finding is filed, as that tidy filed by hand:"
check "the day's report stands under the data dir" \
    [ -s "$REPORT_DIR/$DAY.md" ]
check "quoting the sentence" \
    grep -q "written down where it will hold" "$REPORT_DIR/$DAY.md"
REC="$ENG_DIR/undestinated-durability-claims-$DAY.md"
check "one open engineering record for the day, through crab eng alone" \
    [ -s "$REC" ]
check "standing open" grep -q '^state: open' "$REC"
check "carrying the claim's own sentence" \
    grep -q "The effort dial follows the clock" "$REC"
check "and its time and channel" grep -q "01:55 phone" "$REC"

echo
echo "a re-run of the same night files nothing twice:"
out2="$("$CHECK" run "$DAY" 2>&1)"; rc2=$?
check "the finding still reports" [ "$rc2" -eq 1 ]
check "the record is named as already standing" \
    contains "$out2" "already"
check_eq "and there is still exactly one record for the day" \
    "$(ls "$ENG_DIR"/undestinated-durability-claims-* 2>/dev/null | wc -l)" "1"

echo
echo "a clean day is one line and exit zero:"
CLEAN=2026-08-16
python3 - "$J/$CLEAN.jsonl" "$(date -d "$CLEAN 09:00:00" +%s)" <<'PY'
import json, sys, time
path, ep = sys.argv[1], int(sys.argv[2])
row = {"epoch": ep, "kind": "wake", "duration": 10,
       "time": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ep)),
       "user": "a quiet wake",
       "reply": "Wrote it down on the shelf, and the morning can read it."}
open(path, "w", encoding="utf-8").write(json.dumps(row) + "\n")
PY
out="$("$CHECK" run "$CLEAN" 2>&1)"; rc=$?
check_eq "exit zero" "$rc" "0"
check "says so in its own name" contains "$out" "tidy-claims:"
refute "no record filed for a clean day" \
    ls "$ENG_DIR"/undestinated-durability-claims-"$CLEAN"* 2>/dev/null

echo
echo "a day with no journal at all is a quiet nothing:"
out="$("$CHECK" run 2031-01-01 2>&1)"; rc=$?
check_eq "exit zero" "$rc" "0"
check "and named" contains "$out" "no journal"

echo
echo "scan replays without writing:"
rm -f "$REPORT_DIR/$DAY.md"
out="$("$CHECK" scan "$DAY" "$CLEAN" 2>&1)"; rc=$?
check_eq "scan exits zero" "$rc" "0"
check "the finding is still counted per day" \
    grep -qE "$DAY.*1" <(printf '%s\n' "$out")
refute "but nothing is written" [ -e "$REPORT_DIR/$DAY.md" ]
