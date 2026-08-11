#!/bin/bash
# The eng tool's own writes must never read as an intruder's
# (specs/engineering-records.md rule 10a, specs/nightly.md rule 25).
#
# The incident this holds shut: on 2026-08-11 at 11:22 a `crab eng touch` was
# made from a live wake, and at 11:23 lib/notice-selfchange reported that very
# record as an OUTSIDE change to her own files and booked a wake about it. The
# fix is not a watcher special case for the engineering directory — it is the
# writing hand declaring its own write through `crab touching` (touch_suppress
# in lib/common.sh), so a genuinely external edit to the SAME file still
# surfaces. Both halves are asserted here: a real `crab eng touch` stays
# quiet, an undeclared out-of-band edit to the same record fires.
#
# Same fixture shape as tests/test_notice_selfchange.sh: the real emitter is
# copied into a stub repo whose `crab` records the wake argv, and the emitter
# runs with attempt=99 — past MAX_DEFERRALS — so it judges immediately instead
# of booking timers. The eng writes themselves go through the REAL crab.
# Run: bash tests/test_eng_selfchange.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# --- fixture ----------------------------------------------------------------
mkdir -p "$T/repo/lib" "$T/data/deskcrab/engineering/records"
cp "$REPO_DIR/lib/notice-selfchange" "$T/repo/lib/"
cat > "$T/repo/crab" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
STUB
chmod +x "$T/repo/crab" "$T/repo/lib/notice-selfchange"

# A deferral must FAIL here: a real one would book a transient timer on the
# live user manager that re-runs the emitter without the sandbox environment.
sandbox_systemd_rc 1

run() { "$T/repo/lib/notice-selfchange" "${1:-99}"; }
wakes() { wc -l < "$T/wake-calls" 2>/dev/null || echo 0; }
last_wake() { tail -1 "$T/wake-calls" 2>/dev/null; }
STATE="$NOTICE_STATE_DIR"
CRAB="$REPO_DIR/crab"   # the real dispatcher; the stub above only sinks wakes

echo "== fixture: a scratch record exists before the watcher first looks =="
ID="$("$CRAB" eng new "A scratch worry for the watcher" \
        --summary "regression fixture" --body "Opened by the test.")"
REC="$XDG_DATA_HOME/deskcrab/engineering/records/$ID.md"
check "eng new created the record" test -s "$REC"
run
check "seed run is silent" test ! -f "$T/wake-calls"
check "seeded logged" grep -q "seeded" "$STATE/notice-self.log"

echo "== a real 'crab eng touch' declares its own write =="
"$CRAB" eng touch "$ID" "poked from the regression test" >/dev/null
check "the note landed in the record" grep -q "poked from the regression test" "$REC"
check "the tool declared the record path before writing" \
    grep -q "records/$ID.md" "$STATE/notice-self.suppress"

echo "== and the watcher raises no notice for it =="
run
check "no wake for the tool's own write" test ! -f "$T/wake-calls"
check "the change was judged quiet as a declared touch" \
    grep -q "quiet: modified.*$ID.md (touching)" "$STATE/notice-self.log"

echo "== an undeclared out-of-band edit to the SAME file still raises one =="
# The declarations above are honoured for as long as they were alive at any
# point since judgement last ran (nightly.md rule 27), so age them below the
# floor first — the production shape of an outside edit landing when no eng
# write has run for a while. The expiry column is rewritten; nothing else is.
NOW="$(date +%s)"
awk -F'\t' -v OFS='\t' -v old="$(( NOW - 3600 ))" '{ $1 = old; print }' \
    "$STATE/notice-self.suppress" > "$STATE/notice-self.suppress.aged" \
    && mv "$STATE/notice-self.suppress.aged" "$STATE/notice-self.suppress"
echo "an outside hand, no declaration" >> "$REC"
run
check "the undeclared edit fired a wake" [ "$(wakes)" = 1 ]
check "the wake names the record" contains "$(last_wake)" "$ID.md"
check "the wake is the watcher's own booking" \
    contains "$(last_wake)" "wake-at --by notice-selfchange"

echo "== eng settle declares too — state transitions are writes like any other =="
"$CRAB" eng settle "$ID" "settled by the regression test" >/dev/null
run
check "no wake for the tool's own settle" [ "$(wakes)" = 1 ]
check "the settle was judged quiet as a declared touch" \
    [ "$(sandbox_count_in "quiet: modified.*$ID.md (touching)" "$STATE/notice-self.log")" -ge 2 ]
