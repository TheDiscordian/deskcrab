#!/bin/bash
# The selector's material stays valid UTF-8, whatever lands on a byte budget.
# Run: bash tests/test_night_work_utf8.sh
#
# The gap this was written for: the night's work bounded all four pieces of its
# selection material with a bare `head -c` — the thread log at 24000 bytes,
# the open list at 12000, the index at 2000, the job list at 6000 — and a
# multibyte character straddling any of those budgets went into the model's
# prompt as a lone lead byte. That is the wake ledger's defect in prompt form
# (2026-08-11 02:22: one split em-dash made grep read every ledger record as
# binary), landing this time in the selector's stdin and the night's stream
# log. specs/nightly.md rule 58a carries the guarantee; utf8_head in
# lib/common.sh — the document-shaped counterpart of the one shared trim
# (specs/wake-queue.md, DATA) — is the implementation.
#
# Rule 58a's second half rides the same material: a section that actually
# outgrew its budget is named on the night log — which section, its true
# size in bytes, the budget it was cut to — while a night whose material
# fits its budgets announces nothing, and a missing file is an empty
# section, never an over-run.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
mkdir -p "$T/eng" "$T/jobs" "$T/night-work"

blen() { printf '%s' "$1" | wc -c; }
pad()  { head -c "$1" /dev/zero | tr '\0' "$2"; }

# Each of the four sources gets an em-dash whose three bytes begin exactly
# one byte before its budget's boundary, so a byte cut takes exactly one of
# them — the live corruption's shape, reproduced to the byte, at all four
# sites at once. A marker sits just inside each boundary (it must survive)
# and just past it (it must not). The thread log alone also carries an
# em-dash and a line break well clear of the boundary: content, not
# casualties.
LEAD='## the latch thread — held open
A second line, because a document cut must keep the document its newlines.
'
TP="${LEAD}$(pad $(( 23999 - $(blen "$LEAD") - $(blen 'IN-THREADS-MARK') )) x)IN-THREADS-MARK"
printf '%s%s' "$TP" '—PAST-THREADS-MARK' > "$T/engineering.md"

OP="$(pad $(( 11999 - $(blen 'IN-OPEN-MARK') )) o)IN-OPEN-MARK"
printf '%s%s' "$OP" '—PAST-OPEN-MARK' > "$T/eng/OPEN.md"

IP="$(pad $(( 1999 - $(blen 'IN-INDEX-MARK') )) i)IN-INDEX-MARK"
printf '%s%s' "$IP" '—PAST-INDEX-MARK' > "$T/eng/INDEX.md"

JP="$(pad $(( 5999 - $(blen 'IN-JOBS-MARK') )) j)IN-JOBS-MARK"
printf '%s%s' "$JP" '—PAST-JOBS-MARK' > "$T/jobs-text"

echo "the harness's own byte math, before anything runs:"
check_eq "the thread log shears at byte 24000" "$(blen "$TP")" "23999"
check_eq "the open list at 12000" "$(blen "$OP")" "11999"
check_eq "the index at 2000" "$(blen "$IP")" "1999"
check_eq "the job list at 6000" "$(blen "$JP")" "5999"

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
echo "one round over material sheared at every boundary:"
out="$(env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
    NIGHT_WORK_THREADS_FILE="$T/engineering.md" \
    NIGHT_WORK_THREADS_DIR="$T/eng" \
    NIGHT_WORK_LEDGER="$T/night-work/dispatched.tsv" \
    NIGHT_WORK_POLL=1 NIGHT_WORK_ROUNDS_MAX=1 \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" \
    "$REPO/lib/night-work" run 2>&1)"; rc=$?
check_eq "the night's work exits clean" "$rc" "0"
check "the selector ran and its NOTHING ended the round" \
    contains "$out" "the backlog is dry"
[ -s "$T/model-stdin" ] || die "the selector never received a prompt" "$out"

P="$T/model-stdin"
if iconv -f UTF-8 -t UTF-8 "$P" > /dev/null 2>&1; then
    ok "the whole prompt is valid UTF-8, all four boundaries sheared at once"
else
    fail "the whole prompt is valid UTF-8, all four boundaries sheared at once" \
        "$(iconv -f UTF-8 -t UTF-8 "$P" 2>&1 >/dev/null)"
fi

# grep's binary heuristic only fires in a multibyte locale — under plain C
# every byte is text and the defect hides — so the greps here pin the locale
# the live stream log is read under.
count_plain() { local n; n="$(LC_ALL=C.UTF-8 grep -c  -- "$1" "$P" 2>/dev/null)"; printf '%s' "${n:-0}"; }
count_a()     { local n; n="$(LC_ALL=C.UTF-8 grep -ac -- "$1" "$P" 2>/dev/null)"; printf '%s' "${n:-0}"; }

echo
echo "each site's content inside its boundary, found by a plain grep:"
for MARK in IN-THREADS-MARK IN-OPEN-MARK IN-INDEX-MARK IN-JOBS-MARK; do
    check_eq "plain grep finds $MARK" "$(count_plain "$MARK")" "1"
    check_eq "plain grep and grep -a agree on $MARK, so the prompt is not binary to grep" \
        "$(count_plain "$MARK")" "$(count_a "$MARK")"
done

echo
echo "and nothing past any boundary — the budgets themselves still hold:"
for MARK in PAST-THREADS-MARK PAST-OPEN-MARK PAST-INDEX-MARK PAST-JOBS-MARK; do
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
GOT_INDEX="$(awk '/^=== THE INDEX ===$/ { f = 1; next }
                  /^=== THE THREAD DIRECTORY ===$/ { f = 0 }
                  f && NF' "$P")"
check_eq "the index section is exactly the 1999 bytes that fit — no stray lead byte" \
    "$GOT_INDEX" "$IP"
check_eq "and its byte count says the same" "$(blen "$GOT_INDEX")" "1999"

# ---------------------------------------------------------------------------
# Rule 58a's second half: every section above outgrew its budget, so every
# one of the four cuts must be announced on the night log — the section by
# name, its true size in bytes, and the budget it was cut to.
echo
echo "each actual cut is announced on the night log, size and budget named:"
TB="$(wc -c < "$T/engineering.md")"
OB="$(wc -c < "$T/eng/OPEN.md")"
IB="$(wc -c < "$T/eng/INDEX.md")"
JB="$(wc -c < "$T/jobs-text")"
check "the thread log's cut is announced" contains "$out" \
    "the thread log outgrew its budget — $TB bytes against 24000, cut to the budget on a character boundary"
check "the open list's cut is announced" contains "$out" \
    "the open list outgrew its budget — $OB bytes against 12000, cut to the budget on a character boundary"
check "the index's cut is announced" contains "$out" \
    "the index outgrew its budget — $IB bytes against 2000, cut to the budget on a character boundary"
check "the job list's cut is announced" contains "$out" \
    "the job list outgrew its budget — $JB bytes against 6000, cut to the budget on a character boundary"

# And the other direction: material inside every budget — with the index
# file missing outright — runs the same round and announces nothing. A
# section inside its budget passes without a word; a missing file is an
# empty section, not an over-run.
echo
echo "a night whose material fits its budgets announces nothing:"
printf '## a small thread — open\nstill owed, still small.\n' > "$T/engineering.md"
printf -- '- the one open thread\n' > "$T/eng/OPEN.md"
rm -f "$T/eng/INDEX.md"
printf 'no jobs are running\n' > "$T/jobs-text"
out2="$(env CRAB_BIN="$T/crab" JOBS_DIR="$T/jobs" \
    NIGHT_WORK_THREADS_FILE="$T/engineering.md" \
    NIGHT_WORK_THREADS_DIR="$T/eng" \
    NIGHT_WORK_LEDGER="$T/night-work/dispatched.tsv" \
    NIGHT_WORK_POLL=1 NIGHT_WORK_ROUNDS_MAX=1 \
    NIGHT_WORK_CUTOFF="@$(( NOW + 3600 ))" \
    "$REPO/lib/night-work" run 2>&1)"; rc2=$?
check_eq "the night's work exits clean again" "$rc2" "0"
check "the selector still ran over the small material" \
    contains "$out2" "the backlog is dry"
check_eq "no section is announced as outgrown — the missing index included" \
    "$(printf '%s' "$out2" | grep -c 'outgrew its budget')" "0"
