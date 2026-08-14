#!/bin/bash
# The metrics routes on the phone server (specs/metrics.md rules 21-23): the
# page and the data ride the EXISTING server behind the same auth as every
# other route, and the hour buckets re-sum to the seeded ledger's totals.
# Run: bash tests/test_metrics_serve.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
REPO_DIR="$SANDBOX_REPO"
MDIR="$T/data/deskcrab/metrics"
SECRET="testsecret"
# Ports nobody else is on; the other phone tests hold 18723-18731.
PORT=18734

PID=""
sandbox_at_exit '[ -n "$PID" ] && kill "$PID" 2>/dev/null'

# --- a seeded ledger: two days, several kinds ------------------------------
TODAY="$(date +%F)"
YESTERDAY="$(date -d yesterday +%F)"
mkdir -p "$MDIR"
NOW="$(date +%s)"
cat > "$MDIR/tokens-$TODAY.jsonl" <<EOF
{"ts":$NOW,"kind":"wake","model":"claude-opus-5","effort":"medium","account":"primary","account_n":1,"attempt":1,"attempts":1,"status":"ok","src":"live","input":12,"output":1345,"cache_create":28310,"cache_read":132341,"cost":0.38}
{"ts":$NOW,"kind":"turn","model":"claude-opus-5","effort":"low","account":"primary","account_n":1,"attempt":1,"attempts":2,"status":"refused","src":"live","input":0,"output":0,"cache_create":0,"cache_read":0}
{"ts":$NOW,"kind":"turn","model":"claude-opus-5","effort":"low","account":".claude-alt","account_n":2,"attempt":2,"attempts":2,"status":"ok","src":"live","input":3,"output":25,"cache_create":9,"cache_read":90}
EOF
cat > "$MDIR/tokens-$YESTERDAY.jsonl" <<EOF
{"ts":$((NOW - 86400)),"kind":"summariser","model":"claude-haiku","effort":"","account":"primary","account_n":1,"attempt":1,"attempts":1,"status":"ok","src":"live","input":7,"output":100,"cache_create":0,"cache_read":0}
EOF

# --- the server, exactly as the other phone tests start it -----------------
DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_CRAB_BIN="$T/crab-absent" DESKCRAB_STATE_PREFIX="$T/deskcrab" \
DESKCRAB_METRICS_DIR="$MDIR" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
PID=$!
for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done

echo "== auth: the metrics routes hide from an unauthenticated caller =="

check_eq "no key: /metrics is 404" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/metrics")" \
    "404"
check_eq "no key: /metrics/data is 404" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/metrics/data")" \
    "404"
check_eq "a wrong key is still 404" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/metrics?k=wrong")" \
    "404"

echo "== the page and the data, authenticated =="

PAGE="$(curl -fsS "http://127.0.0.1:$PORT/metrics?k=$SECRET")"
check "the page is served" contains "$PAGE" "Token metrics"
check "the page fetches only its own data route" \
    contains "$PAGE" "/metrics/data?days="
check "no external fetch anywhere in the page" \
    bash -c '! grep -qiE "https?://|cdn\.|integrity=" <<<"$1"' _ "$PAGE"

DATA="$(curl -fsS "http://127.0.0.1:$PORT/metrics/data?days=7&k=$SECRET")"
SUMS="$(printf '%s' "$DATA" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
b = doc["buckets"]
print(sum(x["in"] for x in b), sum(x["out"] for x in b),
      sum(x["n"] for x in b), len(doc["days"]))
')"
check_eq "the buckets re-sum to the seeded ledger (in out attempts days)" \
    "$SUMS" "22 1470 4 2"
KINDS="$(printf '%s' "$DATA" | python3 -c '
import json, sys
print(",".join(sorted({b["kind"] for b in json.load(sys.stdin)["buckets"]})))
')"
check_eq "every seeded kind survives aggregation" \
    "$KINDS" "summariser,turn,wake"
STATUS="$(printf '%s' "$DATA" | python3 -c '
import json, sys
b = json.load(sys.stdin)["buckets"]
print(sum(x["n"] for x in b if x["status"] == "refused"))
')"
check_eq "the refused attempt keeps its status dimension" "$STATUS" "1"

DATA1="$(curl -fsS "http://127.0.0.1:$PORT/metrics/data?days=1&k=$SECRET")"
DAYS1="$(printf '%s' "$DATA1" | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["days"]))
')"
check_eq "days=1 narrows to the newest ledger day" "$DAYS1" "1"

check_eq "a nonsense days value falls back rather than erroring" \
    "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/metrics/data?days=banana&k=$SECRET")" \
    "200"
