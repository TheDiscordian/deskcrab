#!/bin/bash
# The selector's material stays valid UTF-8, whatever lands on a byte budget.
# Run: bash tests/test_night_work_utf8.sh
#
# The gap this was written for: the night's work bounded its selection
# material with a bare `head -c`, and a multibyte character straddling any
# budget went into the model's prompt as a lone lead byte. That is the wake
# ledger's defect in prompt form (2026-08-11 02:22: one split em-dash made
# grep read every ledger record as binary), landing this time in the
# selector's stdin and the night's stream log. specs/nightly.md rule 58a
# carries the guarantee; utf8_head in lib/common.sh — the document-shaped
# counterpart of the one shared trim (specs/wake-queue.md, DATA) — is the
# implementation. Since rule 58c the material is the LIVE open records
# (per-record budget 6000, total 24000) and the job list (6000), so the
# boundaries exercised here are those.
#
# Rule 58a's second half rides the same material: a section that actually
# outgrew its budget is named on the night log — which section, its true
# size in bytes, the budget it was cut to — while a night whose material
# fits its budgets announces nothing. And rule 58c's total budget clips
# oldest-touched first, announced, with the clipped record riding the
# overflow list rather than vanishing.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
R="$T/eng/records"
mkdir -p "$R" "$T/jobs" "$T/night-work"

blen() { printf '%s' "$1" | wc -c; }
pad()  { head -c "$1" /dev/zero | tr '\0' "$2"; }

# The newest-touched record gets an em-dash whose three bytes begin exactly
# one byte before the per-record budget's boundary (6000), so a byte cut
# takes exactly one of them — the live corruption's shape, reproduced to the
# byte. A marker sits just inside the boundary (it must survive) and just
# past it (it must not). The record also carries an em-dash and a line break
# well clear of the boundary: content, not casualties. No blank line
# anywhere in the surviving 5999 bytes, so the exact-extraction below can
# compare through `awk NF`.
FRONT='---
id: sheared-record
title: the latch thread
opened: 2026-08-22 05:00:00
last_touched: 2026-08-22 05:00:00
state: open
summary: sheared at the per-record boundary
---
## the latch thread — held open
A second line, because a document cut must keep the document its newlines.
'
TP="${FRONT}$(pad $(( 5999 - $(blen "$FRONT") - $(blen 'IN-RECORD-MARK') )) x)IN-RECORD-MARK"
printf '%s%s' "$TP" '—PAST-RECORD-MARK' > "$R/sheared-record.md"

# Three more open records of exactly 6000 bytes each spend the rest of the
# 24000-byte total, so the oldest-touched fifth record is clipped whole: its
# body must never reach the prompt, its list line must — the overflow
# section is what keeps the total budget from being a silent cut.
mkrec() {  # <id> <last_touched> <total bytes> <body>
    local HEAD="---
id: $1
title: $1
opened: 2026-08-21 01:00:00
last_touched: $2
state: open
summary: filler under the total budget
---
$4
"
    printf '%s%s' "$HEAD" "$(pad $(( $3 - $(blen "$HEAD") )) f)" > "$R/$1.md"
}
mkrec record-b '2026-08-22 04:00:00' 6000 'the b body'
mkrec record-c '2026-08-22 03:00:00' 6000 'the c body'
mkrec record-d '2026-08-22 02:00:00' 6000 'the d body'
mkrec record-e '2026-08-22 01:00:00' 300 'E-BODY-MARK the clipped record'

JP="$(pad $(( 5999 - $(blen 'IN-JOBS-MARK') )) j)IN-JOBS-MARK"
printf '%s%s' "$JP" '—PAST-JOBS-MARK' > "$T/jobs-text"

echo "the harness's own byte math, before anything runs:"
check_eq "the sheared record shears at byte 6000" "$(blen "$TP")" "5999"
check_eq "record-b is exactly its 6000" "$(wc -c < "$R/record-b.md")" "6000"
check_eq "the job list shears at 6000" "$(blen "$JP")" "5999"

# The door, stubbed: `jobs` answers the crafted list; nothing is dispatched
# tonight, so `job` never has to.
cat > "$T/crab" <<CRAB
#!/bin/bash
case "\$1" in
    jobs) cat "$T/jobs-text" ;;
esac
exit 0
CRAB
chmod +x "$T/crab"

# The selector, stubbed: its stdin — the assembled prompt, the thing under
# test — is kept, and its answer ends the night's work after one round.
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"NOTHING: this night is a harness, not a backlog"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB

NOW="$(date +%s)"
echo
echo "one round over material sheared at the per-record and job-list boundaries:"
out="$(env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
    NIGHT_WORK_THREADS_DIR="$T/eng" \
    NIGHT_WORK_LEDGER="$T/night-work/dispatched.tsv" \
    NIGHT_WORK_POLL=1 NIGHT_WORK_ROUNDS_MAX=1 \
    NIGHT_WORK_MODEL=stub-claude \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" \
    "$REPO/lib/night-work" run 2>&1)"; rc=$?
check_eq "the night's work exits clean" "$rc" "0"
check "the selector ran and its NOTHING ended the round" \
    contains "$out" "the backlog is dry"
[ -s "$T/model-stdin" ] || die "the selector never received a prompt" "$out"

P="$T/model-stdin"
if iconv -f UTF-8 -t UTF-8 "$P" > /dev/null 2>&1; then
    ok "the whole prompt is valid UTF-8, both boundaries sheared at once"
else
    fail "the whole prompt is valid UTF-8, both boundaries sheared at once" \
        "$(iconv -f UTF-8 -t UTF-8 "$P" 2>&1 >/dev/null)"
fi

# grep's binary heuristic only fires in a multibyte locale — under plain C
# every byte is text and the defect hides — so the greps here pin the locale
# the live stream log is read under.
count_plain() { local n; n="$(LC_ALL=C.UTF-8 grep -c  -- "$1" "$P" 2>/dev/null)"; printf '%s' "${n:-0}"; }
count_a()     { local n; n="$(LC_ALL=C.UTF-8 grep -ac -- "$1" "$P" 2>/dev/null)"; printf '%s' "${n:-0}"; }

echo
echo "each site's content inside its boundary, found by a plain grep:"
for MARK in IN-RECORD-MARK IN-JOBS-MARK; do
    check_eq "plain grep finds $MARK" "$(count_plain "$MARK")" "1"
    check_eq "plain grep and grep -a agree on $MARK, so the prompt is not binary to grep" \
        "$(count_plain "$MARK")" "$(count_a "$MARK")"
done

echo
echo "and nothing past any boundary — the budgets themselves still hold:"
for MARK in PAST-RECORD-MARK PAST-JOBS-MARK; do
    check_eq "nothing past the cut at $MARK's site" "$(count_a "$MARK")" "0"
done

echo
echo "what the cut must not touch:"
check "an em-dash clear of the boundary survives intact" \
    grep -qF -- 'the latch thread — held open' "$P"
check "the document keeps its newlines — this is a document cut, not a field flatten" \
    grep -qxF -- '## the latch thread — held open' "$P"

echo
echo "the split character is dropped whole:"
GOT_REC="$(awk '/^--- sheared-record ---$/ { f = 1; next }
                /^--- record-b ---$/ { f = 0 }
                f && NF' "$P")"
check_eq "the sheared record's section is exactly the 5999 bytes that fit — no stray lead byte" \
    "$GOT_REC" "$TP"
check_eq "and its byte count says the same" "$(blen "$GOT_REC")" "5999"

echo
echo "the records ride newest-touched first:"
A_AT="$(grep -n -- '--- sheared-record ---' "$P" | head -1 | cut -d: -f1)"
B_AT="$(grep -n -- '--- record-b ---' "$P" | head -1 | cut -d: -f1)"
D_AT="$(grep -n -- '--- record-d ---' "$P" | head -1 | cut -d: -f1)"
if [ -n "$A_AT" ] && [ -n "$B_AT" ] && [ -n "$D_AT" ] \
        && [ "$A_AT" -lt "$B_AT" ] && [ "$B_AT" -lt "$D_AT" ]; then
    ok "newest-touched first, oldest last"
else
    fail "the order must be newest-touched first" "a=$A_AT b=$B_AT d=$D_AT"
fi

echo
echo "the total budget clips the oldest record whole — and never silently (rule 58c):"
check_eq "the clipped record's body never reaches the prompt" \
    "$(count_a 'E-BODY-MARK')" "0"
check "its eng list one-liner rides the overflow section instead" \
    grep -q '\[record-e\]' "$P"
check "and the clip is announced on the night log" \
    contains "$out" "the open records outgrew the 24000-byte total"

# ---------------------------------------------------------------------------
# Rule 58a's second half: the sheared record and the job list outgrew their
# budgets, so both cuts must be announced on the night log — the section by
# name, its true size in bytes, and the budget it was cut to.
echo
echo "each actual cut is announced on the night log, size and budget named:"
RB="$(wc -c < "$R/sheared-record.md")"
JB="$(wc -c < "$T/jobs-text")"
check "the sheared record's cut is announced" contains "$out" \
    "the open record 'sheared-record' outgrew its budget — $RB bytes against 6000, cut to the budget on a character boundary"
check "the job list's cut is announced" contains "$out" \
    "the job list outgrew its budget — $JB bytes against 6000, cut to the budget on a character boundary"

# And the other direction: material inside every budget runs the same round
# and announces nothing. A section inside its budget passes without a word.
echo
echo "a night whose material fits its budgets announces nothing:"
rm -f "$R"/*.md
cat > "$R/a-small-thread.md" <<'EOF'
---
id: a-small-thread
title: a small thread
opened: 2026-08-22 01:00:00
last_touched: 2026-08-22 01:00:00
state: open
summary: still owed, still small
---

## 2026-08-22 01:00:00

Still owed, still small.
EOF
printf 'no jobs are running\n' > "$T/jobs-text"
out2="$(env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
    NIGHT_WORK_THREADS_DIR="$T/eng" \
    NIGHT_WORK_LEDGER="$T/night-work/dispatched.tsv" \
    NIGHT_WORK_POLL=1 NIGHT_WORK_ROUNDS_MAX=1 \
    NIGHT_WORK_MODEL=stub-claude \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" \
    "$REPO/lib/night-work" run 2>&1)"; rc2=$?
check_eq "the night's work exits clean again" "$rc2" "0"
check "the selector still ran over the small material" \
    contains "$out2" "the backlog is dry"
check_eq "no section is announced as outgrown" \
    "$(printf '%s' "$out2" | grep -c 'outgrew')" "0"
