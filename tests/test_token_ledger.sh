#!/bin/bash
# The token ledger (specs/metrics.md): the parser against captured stream
# shapes, per-attempt records, the fail-safe contract, the aggregation
# arithmetic, and backfill's idempotence. Run: bash tests/test_token_ledger.sh
#
# Entirely offline: every stream here is a fixture written by this file, in
# the shapes the live CLI has actually been observed to emit (the result
# event with modelUsage, the synthetic refusal, the mid-run cut ending in a
# type-less is_error line — account-fallback.md rule 12d), and the recorder is
# invoked directly, exactly as the run hooks invoke it.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
LEDGER="$SANDBOX_REPO/lib/token_ledger.py"
MDIR="$T/data/deskcrab/metrics"
TODAY="$(date +%F)"
DAYFILE="$MDIR/tokens-$TODAY.jsonl"

# One place to read a field back out of the newest record.
last_field() {  # <field> [file]
    python3 - "$1" "${2:-$DAYFILE}" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
v = recs[-1].get(sys.argv[1])
print("" if v is None else v)
PY
}

count_records() { sandbox_count_in . "${1:-$DAYFILE}"; }

# --- a clean run: the result event's totals win ----------------------------
echo "== a clean stream records the result event's totals =="

cat > "$T/stream-clean" <<'EOF'
{"type":"deskcrab_note","note":"session","detail":"autonomous wake pid 1234","at":"11:40:34"}
{"type":"system","subtype":"init","session_id":"aaaa-1111","model":"claude-opus-5"}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-5","content":[{"type":"text","text":"working"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":3}}}
{"type":"assistant","message":{"id":"msg_1","model":"claude-opus-5","content":[{"type":"text","text":"working"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"output_tokens":3}}}
{"type":"result","subtype":"success","is_error":false,"session_id":"aaaa-1111","duration_ms":34660,"total_cost_usd":0.38,"usage":{"input_tokens":12,"cache_creation_input_tokens":28310,"cache_read_input_tokens":132341,"output_tokens":1345},"modelUsage":{"claude-opus-5":{"inputTokens":12,"outputTokens":1345,"cacheReadInputTokens":132341,"cacheCreationInputTokens":28310,"costUSD":0.38}}}
{"type":"result"}
EOF
python3 "$LEDGER" record "$T/stream-clean" --kind wake --model opus \
    --effort medium --account - --dir "$MDIR" --pid 1234
check "the day file exists" test -s "$DAYFILE"
check_eq "one attempt, one record" "$(count_records)" "1"
check_eq "input from the result totals" "$(last_field input)" "12"
check_eq "output from the result totals, not the deltas" \
    "$(last_field output)" "1345"
check_eq "cache_create" "$(last_field cache_create)" "28310"
check_eq "cache_read" "$(last_field cache_read)" "132341"
check_eq "the model comes from modelUsage" "$(last_field model)" "claude-opus-5"
check_eq "kind" "$(last_field kind)" "wake"
check_eq "status ok" "$(last_field status)" "ok"
check_eq "the bare token hint names account 1" "$(last_field account)" "account-1"
check_eq "duration from the result event" "$(last_field duration)" "34.66"
check_eq "the session id is kept" "$(last_field sid)" "aaaa-1111"
check_eq "the terminator result line is not an attempt" \
    "$(last_field attempts)" "1"

# --- a pure refusal: recorded, tagged, no usage ----------------------------
echo "== a synthetic refusal is recorded as refused =="

cat > "$T/stream-refused" <<'EOF'
{"type":"system","subtype":"init","session_id":"bbbb-2222","model":"claude-opus-5"}
{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 1:30am"}]}}
{"type":"result","is_error":true,"result":"You've hit your session limit · resets 1:30am"}
EOF
: > "$DAYFILE"
python3 "$LEDGER" record "$T/stream-refused" --kind turn --model opus \
    --account "$HOME/.claude-alt" --dir "$MDIR"
check_eq "one record for the refusal" "$(count_records)" "1"
check_eq "status refused" "$(last_field status)" "refused"
check_eq "no usage invented" "$(last_field input)" "0"
check_eq "the account hint's short name" "$(last_field account)" ".claude-alt"

# --- the mid-run cut, ending in the type-less is_error line ----------------
echo "== a cut falls back to deduped assistant sums (rule 12d line included) =="

cat > "$T/stream-cut" <<'EOF'
{"type":"system","subtype":"init","session_id":"cccc-3333","model":"claude-opus-5"}
{"type":"assistant","message":{"id":"msg_a","model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"true"}}],"usage":{"input_tokens":4,"cache_creation_input_tokens":50,"cache_read_input_tokens":1000,"output_tokens":10}}}
{"type":"assistant","message":{"id":"msg_a","model":"claude-opus-5","content":[{"type":"tool_use","name":"Bash","input":{"command":"true"}}],"usage":{"input_tokens":4,"cache_creation_input_tokens":50,"cache_read_input_tokens":1000,"output_tokens":10}}}
{"type":"assistant","message":{"id":"msg_b","model":"claude-opus-5","content":[{"type":"text","text":"nine tool calls in"}],"usage":{"input_tokens":4,"cache_creation_input_tokens":25,"cache_read_input_tokens":1050,"output_tokens":7}}}
{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 1:30am"}]}}
{"is_error":true,"duration_api_ms":31572,"num_turns":9}
EOF
: > "$DAYFILE"
python3 "$LEDGER" record "$T/stream-cut" --kind wake --model opus --dir "$MDIR"
check_eq "one record for the cut attempt" "$(count_records)" "1"
check_eq "status cut" "$(last_field status)" "cut"
check_eq "deduped input: msg_a counted once plus msg_b" \
    "$(last_field input)" "8"
check_eq "deduped cache_read" "$(last_field cache_read)" "2050"
check_eq "the deduped-sum route marks itself approximate" "$(last_field approx)" "True"
check_eq "duration from the type-less error line" \
    "$(last_field duration)" "31.572"

# --- the caller's terminator alone is not an attempt ------------------------
echo "== a terminator-only stream records nothing (spec rules 8, 12) =="

cat > "$T/stream-terminator" <<'EOF'
{"type":"deskcrab_note","note":"session","detail":"autonomous wake pid 77","at":"03:00:00"}
{"type":"result"}
EOF
: > "$DAYFILE"
python3 "$LEDGER" record "$T/stream-terminator" --kind wake --dir "$MDIR"
check_eq "a run that never booted leaves no status-ok zero-usage row" \
    "$(count_records)" "0"

# --- a plain error is an error, not a refusal ------------------------------
echo "== a non-limit error stays an error =="

cat > "$T/stream-err" <<'EOF'
{"type":"system","subtype":"init","session_id":"dddd-4444","model":"claude-opus-5"}
{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"Invalid API key"}]}}
{"type":"result","is_error":true,"result":"Invalid API key"}
EOF
: > "$DAYFILE"
python3 "$LEDGER" record "$T/stream-err" --kind turn --dir "$MDIR"
check_eq "status error" "$(last_field status)" "error"

# --- a multi-attempt walk: init boundaries plus swap markers ---------------
echo "== a walk's attempts split on init events, accounts off the markers =="

# The swap marker below is VERBATIM what the deployed writer emits — its
# spelling for account 1 is the wire's, and the parser must map it to the
# numbered name real streams get attributed under.
cat > "$T/stream-walk" <<EOF
{"type":"deskcrab_note","note":"session","detail":"desktop turn pid 99","at":"10:00:00"}
{"type":"system","subtype":"init","session_id":"e-1","model":"claude-opus-5"}
{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit"}]}}
{"type":"result","is_error":true,"result":"You've hit your session limit"}
{"type":"deskcrab_note","note":"account-swap","detail":"primary -> .claude-alt (limit refusal)","at":"10:00:05"}
{"type":"system","subtype":"init","session_id":"e-2","model":"claude-opus-5"}
{"type":"assistant","message":{"id":"msg_z","model":"claude-opus-5","content":[{"type":"text","text":"the answer"}],"usage":{"input_tokens":3,"cache_creation_input_tokens":9,"cache_read_input_tokens":90,"output_tokens":20}}}
{"type":"result","subtype":"success","is_error":false,"session_id":"e-2","duration_ms":8000,"usage":{"input_tokens":3,"cache_creation_input_tokens":9,"cache_read_input_tokens":90,"output_tokens":25}}
{"type":"result"}
EOF
: > "$DAYFILE"
python3 "$LEDGER" record "$T/stream-walk" --kind turn --model opus \
    --chain "$HOME/.claude-alt" --dir "$MDIR"
check_eq "two attempts, two records" "$(count_records)" "2"
WALK="$(python3 - "$DAYFILE" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(";".join("%s/%s/%s/%s/%s" % (r["attempt"], r["attempts"], r["status"],
                                   r["account"], r["account_n"])
      for r in recs))
PY
)"
check_eq "attempt 1 refused on account 1, attempt 2 ok on the second login" \
    "$WALK" "1/2/refused/account-1/1;2/2/ok/.claude-alt/2"

# --- garbage in, exit 0, nothing broken ------------------------------------
echo "== the recorder is failure-safe (spec rule 6) =="

printf 'not json at all\n{"half": \n' > "$T/stream-garbage"
python3 "$LEDGER" record "$T/stream-garbage" --kind turn --dir "$MDIR"
check_eq "garbage exits 0" "$?" "0"
python3 "$LEDGER" record "$T/does-not-exist" --kind turn --dir "$MDIR"
check_eq "a missing stream exits 0" "$?" "0"
cat > "$T/stream-mixed" <<'EOF'
this line is the CLI's own stderr, not JSON
{"type":"system","subtype":"init","session_id":"f-1","model":"claude-opus-5"}
{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}
EOF
: > "$DAYFILE"
python3 "$LEDGER" record "$T/stream-mixed" --kind summariser --dir "$MDIR"
check_eq "junk lines are skipped, the record still lands" "$(count_records)" "1"
check_eq "and carries the usage" "$(last_field output)" "4"

# --- the shell hook: silent, harmless, and actually writing ----------------
echo "== token_ledger_record through lib/common.sh =="

: > "$DAYFILE"
OUT="$(sandbox_bash "token_ledger_record '$T/stream-clean' wake opus medium - 12" 2>&1)"
check_eq "the hook prints nothing" "$OUT" ""
check_eq "and appends the record" "$(count_records)" "1"
: > "$DAYFILE"
OUT="$(sandbox_bash "TOKEN_LEDGER=0 token_ledger_record '$T/stream-clean' wake opus medium -" 2>&1)"
check_eq "TOKEN_LEDGER=0 switches it off" "$(count_records)" "0"

# The status judgement rides the ONE shared signature (account-fallback.md
# rule 13): a refusal wording only CLAUDE_LIMIT_RE knows must reach the child
# through the hook's environment — falling to lib/token_ledger.py's
# last-resort spelling would judge it a plain error.
cat > "$T/stream-bespoke" <<'EOF'
{"type":"system","subtype":"init","session_id":"g-1","model":"claude-opus-5"}
{"type":"assistant","is_api_error_message":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"the model is having a lie-down"}]}}
{"type":"result","is_error":true,"result":"the model is having a lie-down"}
EOF
: > "$DAYFILE"
OUT="$(sandbox_bash "CLAUDE_LIMIT_RE='having a lie-down' token_ledger_record '$T/stream-bespoke' wake opus '' -" 2>&1)"
check_eq "the shared signature reaches the child: bespoke wording judged refused" \
    "$(last_field status)" "refused"

# --- the aggregation arithmetic --------------------------------------------
echo "== report and aggregate sum what was written =="

: > "$DAYFILE"
python3 "$LEDGER" record "$T/stream-clean" --kind wake --model opus --dir "$MDIR"
python3 "$LEDGER" record "$T/stream-walk" --kind turn --model opus --dir "$MDIR"
REPORT="$(python3 "$LEDGER" report "$TODAY" --dir "$MDIR")"
check "the report names the day's totals" \
    contains "$REPORT" "3 attempts"
check "the report breaks down by kind" contains "$REPORT" "wake"
check "the report counts the limited attempts" contains "$REPORT" "(1 limited)"
AGG="$(python3 "$LEDGER" aggregate --days 7 --dir "$MDIR")"
AGG_SUM="$(printf '%s' "$AGG" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
b = doc["buckets"]
print(sum(x["in"] for x in b), sum(x["out"] for x in b),
      sum(x["n"] for x in b))
')"
check_eq "the hour buckets re-sum to the ledger (in, out, attempts)" \
    "$AGG_SUM" "15 1370 3"
KINDS="$(printf '%s' "$AGG" | python3 -c '
import json, sys
print(",".join(sorted({b["kind"] for b in json.load(sys.stdin)["buckets"]})))
')"
check_eq "buckets keep the kind dimension" "$KINDS" "turn,wake"

# --- backfill: archived streams and transcripts, idempotent ----------------
echo "== backfill ingests once, and only once (spec rules 17-19) =="

rm -f "$MDIR"/tokens-*.jsonl "$MDIR/backfill-state.json"
STREAMS="$T/xdgstate/deskcrab/streams"
mkdir -p "$STREAMS"
cp "$T/stream-clean" "$STREAMS/1700000000-1234.jsonl"
cp "$T/stream-cut"   "$STREAMS/1700000100-5678.jsonl"

# A transcript in the CLI's own format, under a config dir whose projects
# slug is her project dir — and a decoy in a workdir slug that must be left
# alone (rule 18).
CDIR="$T/home/.claude"
SLUG="$(python3 -c "import re,sys; print(re.sub(r'[^A-Za-z0-9-]','-',sys.argv[1]))" "$T/home/assistant-home")"
mkdir -p "$CDIR/projects/$SLUG" "$CDIR/projects/-somewhere-else"
cat > "$CDIR/projects/$SLUG/s1.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-08-10T10:00:00.000Z","sessionId":"t-1"}
{"type":"assistant","requestId":"req_1","sessionId":"t-1","timestamp":"2026-08-10T10:00:05.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":30}}}
{"type":"assistant","requestId":"req_1","sessionId":"t-1","timestamp":"2026-08-10T10:00:05.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":30}}}
{"type":"assistant","requestId":"req_2","sessionId":"t-1","timestamp":"2026-08-10T10:00:09.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":40,"output_tokens":11}}}
EOF
cp "$CDIR/projects/$SLUG/s1.jsonl" "$CDIR/projects/-somewhere-else/decoy.jsonl"

run_backfill() {
    python3 "$LEDGER" backfill --dir "$MDIR" --streams "$STREAMS" \
        --claude-dirs "$CDIR" --her-cwds "$T/home/assistant-home" --chain ""
}
OUT1="$(run_backfill)"
TOTAL1="$(cat "$MDIR"/tokens-*.jsonl 2>/dev/null | wc -l)"
check "the first pass reports additions" contains "$OUT1" "records added"
check_eq "streams and the transcript landed (2 stream + 1 transcript)" \
    "$TOTAL1" "3"
TRANS_SUM="$(cat "$MDIR"/tokens-*.jsonl | python3 -c '
import json, sys
for l in sys.stdin:
    r = json.loads(l)
    if r.get("src") == "transcript":
        print(r["input"], r["output"], r["cache_read"], r["approx"])
')"
check_eq "the transcript deduped req_1 and summed both requests" \
    "$TRANS_SUM" "12 41 60 True"
TRANS_N="$(cat "$MDIR"/tokens-*.jsonl | python3 -c '
import json, sys
print(sum(1 for l in sys.stdin
          if json.loads(l).get("src") == "transcript"))
')"
check_eq "exactly one transcript record — the decoy workdir was not touched" \
    "$TRANS_N" "1"

OUT2="$(run_backfill)"
TOTAL2="$(cat "$MDIR"/tokens-*.jsonl | wc -l)"
check_eq "a second pass adds nothing" "$TOTAL2" "$TOTAL1"
check "and says every source was already ingested" \
    contains "$OUT2" "0 records added"

# A stream whose session id already has live records is skipped (rule 19).
rm -f "$MDIR/backfill-state.json"
OUT3="$(run_backfill)"
TOTAL3="$(cat "$MDIR"/tokens-*.jsonl | wc -l)"
check_eq "sid dedupe holds even with the state file gone" "$TOTAL3" "$TOTAL1"

# --- the crab arm: the child is handed what only the parent shell knows ----
echo "== crab metrics backfill passes her cwds, the config dirs and the chain =="

# PROJECT_DIR and CLAUDE_FALLBACK_CONFIG_DIR are unexported shell variables:
# the exec'd child sees neither, so they only arrive on the argv. Driven
# through crab itself — a transcript under a second login's projects slug for
# her project dir, and one under the sterile classify cwd's slug, must both be
# found, attributed to that login, and NUMBERED, which fails whenever any of
# --her-cwds, --claude-dirs, or --chain goes missing from the exec.
MDIR2="$T/data/deskcrab/metrics-crab"
CDIR2="$T/home/.claude-two"
slug() { python3 -c "import re,sys; print(re.sub(r'[^A-Za-z0-9-]','-',sys.argv[1]))" "$1"; }
mk_transcript() {  # <path> <sid>
    cat > "$1" <<EOF
{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-08-10T10:00:00.000Z","sessionId":"$2"}
{"type":"assistant","requestId":"req_9","sessionId":"$2","timestamp":"2026-08-10T10:00:05.000Z","message":{"id":"m9","model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":30}}}
EOF
}
mkdir -p "$CDIR2/projects/$(slug "$T/home")" \
    "$CDIR2/projects/$(slug "$SANDBOX/run/deskcrab-classify")"
mk_transcript "$CDIR2/projects/$(slug "$T/home")/s2.jsonl" "crab-a"
mk_transcript "$CDIR2/projects/$(slug "$SANDBOX/run/deskcrab-classify")/s3.jsonl" "crab-b"

DESKCRAB_METRICS_DIR="$MDIR2" CLAUDE_FALLBACK_CONFIG_DIR="$CDIR2" \
    "$SANDBOX_REPO/crab" metrics backfill > "$T/crab-backfill.out" 2>&1
check "the crab arm ran the ingest" \
    contains "$(cat "$T/crab-backfill.out")" "records added"
CRAB_ROWS="$(cat "$MDIR2"/tokens-*.jsonl 2>/dev/null | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
tr = [r for r in rows if r.get("src") == "transcript"]
print(";".join(sorted("%s/%s/%s" % (r["kind"], r["account"], r["account_n"])
                      for r in tr)))
')"
check_eq "her project-dir and classify transcripts arrive, numbered on the second login" \
    "$CRAB_ROWS" "classify/.claude-two/2;turn/.claude-two/2"
