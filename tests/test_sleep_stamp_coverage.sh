#!/bin/bash
# The nightly stamp records coverage, not just yield — specs/nightly.md rule
# 14a. Run: bash tests/test_sleep_stamp_coverage.sh
#
# The gap this was written for: the stamp's third line said "added=N" and
# nothing else, so `sleep-nightly status` could report eight records added and
# still not tell a whole night from one whose ingest died after its first
# pass. The night log already states its own size — "ingest: 461 new chunks,
# 499751 chars -> sonnet for judgement in 4 passes..." — so the stamp now
# carries that claim beside the yield, on the SAME line, and a field the log
# never states is omitted rather than invented. The stamp must never be
# stricter than the night: a log with no header at all still stamps and still
# counts as slept.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"

# The parser, called on a fixture log without running a real ingest: the
# script is sourceable — its dispatch runs only when executed — so
# coverage_fields is a plain function here.
cov() { # <log> -> the coverage half of the stamp's third line
    bash -c 'source "$1" || exit 9; shift; coverage_fields "$1"' \
        _ "$REPO/lib/sleep-nightly" "$1"
}

echo "the real night-log shape, header carrying the pass count:"
# Verbatim from the live 2026-08-11 night log, added-lines elided.
cat > "$T/full.log" <<'EOF'
=== sleep 2026-08-11 03:10:40 ===
ingest: 461 new chunks, 499751 chars -> sonnet for judgement in 4 passes...
  pass 1/4: 149663 chars
  pass 2/4: 149831 chars
  pass 3/4: 149676 chars
  pass 4/4: 50581 chars
  added #101 [directive] (2026-08-10) a record
ingest: 49 added, 0 superseded, 0 duplicates, 0 rejected
exit: 0
EOF
check_eq "chunks, chars and passes all come from the header" \
    "$(cov "$T/full.log")" "chunks=461 chars=499751 passes=4"

# The header's claim is preferred over counting: a night that planned four
# passes and died after two is exactly the truncation the stamp exists to
# show, so the count recorded is the header's, not the survivor tally.
cat > "$T/died.log" <<'EOF'
ingest: 461 new chunks, 499751 chars -> sonnet for judgement in 4 passes...
  pass 1/4: 149663 chars
  pass 2/4: 149831 chars
EOF
check_eq "the header pass count wins over counting the pass lines" \
    "$(cov "$T/died.log")" "chunks=461 chars=499751 passes=4"

echo
echo "the older header, no pass count stated:"
# The 2026-08-08 shape: chunks and chars, no "in N passes", no pass lines.
cat > "$T/old.log" <<'EOF'
=== sleep 2026-08-08 03:10:42 ===
ingest: 42 new chunks, 36922 chars -> sonnet for judgement...
  added #25 [note] a record
ingest: 3 added, 0 superseded, 0 duplicates, 0 rejected
exit: 0
EOF
check_eq "a pass count the log never states is omitted, not invented" \
    "$(cov "$T/old.log")" "chunks=42 chars=36922"

# The fallback: a header that predates stating the count, beside per-pass
# lines that show it — the count comes from counting them.
cat > "$T/fallback.log" <<'EOF'
ingest: 100 new chunks, 200000 chars -> sonnet for judgement...
  pass 1/2: 150000 chars
  pass 2/2: 50000 chars
ingest: 7 added, 0 superseded, 0 duplicates, 0 rejected
EOF
check_eq "no count in the header falls back to counting the pass lines" \
    "$(cov "$T/fallback.log")" "chunks=100 chars=200000 passes=2"

echo
echo "no ingest header at all:"
cat > "$T/bare.log" <<'EOF'
=== sleep 2026-08-09 03:10:41 ===
exit: 0
EOF
out="$(cov "$T/bare.log")"; rc=$?
check_eq "the parser exits zero on a header-less log" "$rc" "0"
check_eq "and prints nothing rather than inventing fields" "$out" ""

echo
echo "the stamp itself, through a full sleep-nightly run:"
# The ingest is a stub that replays the real night's output; everything else
# sleep runs afterwards (the review, the drain, the sweep) runs against
# sandbox paths and may fail loudly — the night still counts.
cat > "$T/ingest-full" <<'BODY'
ingest: 461 new chunks, 499751 chars -> sonnet for judgement in 4 passes...
  pass 1/4: 149663 chars
  pass 2/4: 149831 chars
  pass 3/4: 149676 chars
  pass 4/4: 50581 chars
  added #101 [directive] (2026-08-10) a record
ingest: 49 added, 0 superseded, 0 duplicates, 0 rejected
BODY
cat > "$T/crab-full" <<CRAB
#!/bin/bash
case "\$*" in
    "memory ingest") cat "$T/ingest-full" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-full"
out="$(env CRAB_BIN="$T/crab-full" XDG_DATA_HOME="$T/data-full" \
    "$REPO/lib/sleep-nightly" run 2>&1)"; rc=$?
STAMP="$T/data-full/deskcrab/last-slept"
check_eq "the run exits with the ingest's own zero" "$rc" "0"
[ -f "$STAMP" ] || die "the night stamped at all" "$out"
check_eq "yield and coverage share the stamp's third line" \
    "$(sed -n 3p "$STAMP")" "added=49 chunks=461 chars=499751 passes=4"
check "and the run says what it stamped" \
    contains "$out" "(added=49 chunks=461 chars=499751 passes=4)"
status_out="$(env XDG_DATA_HOME="$T/data-full" \
    "$REPO/lib/sleep-nightly" status 2>&1)"; rc=$?
check_eq "status exits zero on the fresh stamp" "$rc" "0"
check "status renders the whole line in its parenthetical" \
    contains "$status_out" ", added=49 chunks=461 chars=499751 passes=4)"

echo
echo "a night whose log has no ingest header still stamps:"
cat > "$T/crab-bare" <<'CRAB'
#!/bin/bash
case "$*" in
    "memory ingest") echo "ingest: 3 added, 0 superseded, 0 duplicates, 0 rejected" ;;
esac
exit 0
CRAB
chmod +x "$T/crab-bare"
out="$(env CRAB_BIN="$T/crab-bare" XDG_DATA_HOME="$T/data-bare" \
    "$REPO/lib/sleep-nightly" run 2>&1)"; rc=$?
STAMP="$T/data-bare/deskcrab/last-slept"
check_eq "the run still exits zero" "$rc" "0"
[ -f "$STAMP" ] || die "the header-less night stamped at all" "$out"
check_eq "the third line is the yield alone, no trailing space, no zeros" \
    "$(sed -n 3p "$STAMP")" "added=3"

echo
echo "status on a legacy added-only stamp:"
mkdir -p "$T/data-legacy/deskcrab"
printf '%s\n%s\n%s\n' "$(date +%s)" "$(date -Iseconds)" "added=5" \
    > "$T/data-legacy/deskcrab/last-slept"
status_out="$(env XDG_DATA_HOME="$T/data-legacy" \
    "$REPO/lib/sleep-nightly" status 2>&1)"; rc=$?
check_eq "a stamp from before the widening still reads" "$rc" "0"
check "and its yield still shows" contains "$status_out" ", added=5)"
