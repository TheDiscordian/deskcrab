#!/bin/bash
# Where he is — specs/phone.md rule 3a.
# Run: bash tests/test_phone_geolocation.sh
#
# Opened 2026-08-15: an evening was planned from the machine's own town while
# the user was actually a couple of streets away, because a phone turn carried
# no idea of where the phone was. The fix: each outgoing message may carry the
# phone's own coordinates, and the post that creates a turn with a fresh,
# well-formed fix puts exactly one line — `he is near <place>` — into that
# turn's context. Everything short of that injects nothing and says nothing.
#
# This file proves the path end to end short of a real model: a real serve.py
# over a real socket with a stub `crab` that records its environment shows the
# resolved place riding down to the runner; the REAL assembler (`crab context`)
# run by the stub shows the line, exactly once, in the assembled turn context;
# a bare post, a malformed fix, and a stale one hand the turn through with no
# line and no error text; a hanging geocoder is abandoned at its named bound
# and the line falls back to plain coordinates. The geocoder is a local stub
# in every case — this suite never asks a live service where anybody is. The
# client's fix helper is driven in node when node exists: denial, absence,
# staleness and a hung lookup all resolve to nothing inside the helper's own
# bound, and a denial is remembered so the permission is never re-begged.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

SERVER_PID="" SERVER2_PID="" GEO_PID="" HANG_PID=""
sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'
sandbox_at_exit '[ -n "$SERVER2_PID" ] && kill "$SERVER2_PID" 2>/dev/null'
sandbox_at_exit '[ -n "$GEO_PID" ] && kill "$GEO_PID" 2>/dev/null'
sandbox_at_exit '[ -n "$HANG_PID" ] && kill "$HANG_PID" 2>/dev/null'

SECRET="testsecret"
# Ports nobody else is on; phone_live 18723, watch_rewrite 18724, wedge 18725,
# done_after_exit 18726, queue_wait/voice_fallback 18727, media 18728, stop
# 18729, stream 18730/18731, midturn 18732. Here: two servers and two stub
# geocoders.
PORT=18733        # server A — working stub geocoder
GEO_PORT=18734    # the stub geocoder itself
PORT2=18735       # server B — geocoder that hangs
HANG_PORT=18736   # the hanging listener

# --- the stub geocoder -----------------------------------------------------
# Nominatim-shaped answers for a fictional street; anything else gets JSON
# with no usable address, so the unresolvable case can be driven too.
python3 - "$GEO_PORT" > "$T/geocoder.log" 2>&1 <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        lat = float((q.get("lat") or ["0"])[0])
        if 12.0 < lat < 13.0:
            doc = {"display_name": "irrelevant",
                   "address": {"road": "Sesame Street", "town": "Springfield"}}
        else:
            doc = {"error": "Unable to geocode"}
        body = json.dumps(doc).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
GEO_PID=$!

# A listener that accepts nothing: connects to it sit until the caller's own
# bound gives up, which is exactly what the bounded-lookup case measures.
python3 -c '
import socket, sys
s = socket.socket()
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(0)
import time
time.sleep(3600)
' "$HANG_PORT" > /dev/null 2>&1 &
HANG_PID=$!

# --- the stub `crab` -------------------------------------------------------
# `remote` records the environment the runner receives — DESKCRAB_TURN_PLACE
# is the thing under test — and runs the REAL assembler in the same
# environment, so the context assertion is against what a live turn would
# actually be handed, not against a copy of the injection logic.
cat > "$T/crab" <<STUB
#!/bin/bash
exec 2>> "$T/stub.err"
case "\$1" in
  synth) : > "\$2"; exit 1 ;;
  remote) ;;
  *) exit 1 ;;
esac
N="\$(cat "$T/n" 2>/dev/null || echo 0)"; N=\$(( N + 1 )); echo "\$N" > "$T/n"
printenv DESKCRAB_TURN_PLACE > "$T/place.\$N" 2>/dev/null || : > "$T/place.\$N"
"$REPO_DIR/crab" context --profile turn > "$T/context.\$N" 2> "$T/context-err.\$N"
echo '{"spoken":"E2E-REPLY","display":"","audio":"","error":""}'
exit 0
STUB
chmod +x "$T/crab"

# The frame reads the recorded origin; a phone turn records it inside crab
# remote, which the stub skips, so the sandbox seeds it the way a live phone
# turn would have.
mkdir -p "$T/data/deskcrab"
printf 'phone' > "$T/data/deskcrab/last-origin"

serve_env() { # <port> <geocode-url> <lookup-timeout>
    # exec, so the pid the caller backgrounds IS the python process: a
    # backgrounded function is a subshell, and killing the subshell at exit
    # orphans the server, which then answers the next run's ports with this
    # run's buffered turns.
    exec env DESKCRAB_SERVE_SECRET="$SECRET" \
        DESKCRAB_SERVE_PORT="$1" \
        DESKCRAB_SERVE_BIND=127.0.0.1 \
        DESKCRAB_SERVE_TIMEOUT=120 \
        DESKCRAB_CRAB_BIN="$T/crab" \
        DESKCRAB_STATE_PREFIX="$T/deskcrab" \
        DESKCRAB_GEOCODE_URL="$2" \
        DESKCRAB_GEO_LOOKUP_TIMEOUT_S="$3" \
        DESKCRAB_GEO_STALE_S=600 \
        python3 "$REPO_DIR/lib/serve.py"
}

serve_env "$PORT" "http://127.0.0.1:$GEO_PORT/reverse?lat={lat}&lon={lon}" 5 \
    > "$T/server.log" 2>&1 &
SERVER_PID=$!
serve_env "$PORT2" "http://127.0.0.1:$HANG_PORT/reverse?lat={lat}&lon={lon}" 1 \
    > "$T/server2.log" 2>&1 &
SERVER2_PID=$!

for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 \
        && curl -fsS -m 2 "http://127.0.0.1:$PORT2/health?k=$SECRET" >/dev/null 2>&1 \
        && break
    sleep 0.1
done
curl -fsS -m 2 "http://127.0.0.1:$PORT/health?k=$SECRET" >/dev/null 2>&1 \
    || die "server A never came up" "$(cat "$T/server.log")"
curl -fsS -m 2 "http://127.0.0.1:$PORT2/health?k=$SECRET" >/dev/null 2>&1 \
    || die "server B never came up" "$(cat "$T/server2.log")"

NOW_MS="$(( $(date +%s) * 1000 ))"

say() { # <port> <body>
    curl -sS -m 90 \
        -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "$2" "http://127.0.0.1:$1/say" 2>/dev/null
}

turn_of() { # nth stub run's files exist?
    [ -f "$T/place.$1" ] && [ -f "$T/context.$1" ]
}

echo "== a fresh fix on the creating post becomes the place, and one context line =="

OUT1="$(say "$PORT" '{"text":"where should we eat","turn":"aaaa01",
  "loc":{"lat":12.3456,"lon":65.4321,"acc":12,"ts":'"$NOW_MS"'}}')"
turn_of 1 || die "the stub runner never ran for turn 1" \
    "say: [$OUT1] ls: [$(ls "$T" | tr '\n' ' ')] stub.err: [$(tail -c 800 "$T/stub.err" 2>/dev/null)] server: [$(tail -c 500 "$T/server.log")]"
check_eq "the resolved place rides down to the runner" \
    "$(cat "$T/place.1")" "Sesame Street, Springfield"
check_eq "the assembled context carries the line exactly once" \
    "$(grep -c 'he is near ' "$T/context.1")" "1"
check "and it is the geocoded street and town, on its own line" \
    contains "$(grep 'he is near ' "$T/context.1")" "he is near Sesame Street, Springfield"
check "the reply is the reply — no error text reached it" \
    contains "$OUT1" '"error": ""'
check "and no geolocation word leaked into the completion" \
    bash -c '! printf "%s" "$1" | grep -qiE "geoloc|geocod|latitude|longitude"' _ "$OUT1"

echo "== a bare post goes through unchanged: no place, no line =="

OUT2="$(say "$PORT" '{"text":"and a bare one","turn":"aaaa02"}')"
turn_of 2 || die "the stub runner never ran for turn 2" "$(cat "$T/server.log")"
check_eq "no place reaches the runner" "$(cat "$T/place.2")" ""
check_eq "and the context carries no location line at all" \
    "$(grep -c 'he is near ' "$T/context.2")" "0"
check "the turn still answered" contains "$OUT2" '"error": ""'

echo "== malformed and stale fixes degrade silently (rule 3a) =="

OUT3="$(say "$PORT" '{"text":"malformed","turn":"aaaa03",
  "loc":{"lat":"not-a-number","lon":65.4321,"ts":'"$NOW_MS"'}}')"
turn_of 3 || die "the stub runner never ran for turn 3" "$(cat "$T/server.log")"
check_eq "a malformed fix injects nothing" "$(cat "$T/place.3")" ""
check_eq "— context clean" "$(grep -c 'he is near ' "$T/context.3")" "0"
check "— and no error text in the reply" contains "$OUT3" '"error": ""'

OUT4="$(say "$PORT" '{"text":"out of range","turn":"aaaa04",
  "loc":{"lat":123.0,"lon":65.4321,"ts":'"$NOW_MS"'}}')"
turn_of 4 || die "the stub runner never ran for turn 4" "$(cat "$T/server.log")"
check_eq "coordinates off the planet inject nothing" "$(cat "$T/place.4")" ""

STALE_MS="$(( NOW_MS - 3600 * 1000 ))"
OUT5="$(say "$PORT" '{"text":"stale","turn":"aaaa05",
  "loc":{"lat":12.3456,"lon":65.4321,"ts":'"$STALE_MS"'}}')"
turn_of 5 || die "the stub runner never ran for turn 5" "$(cat "$T/server.log")"
check_eq "a fix older than GEO_STALE_S injects nothing" "$(cat "$T/place.5")" ""
check_eq "— context clean" "$(grep -c 'he is near ' "$T/context.5")" "0"
check "— and the turn answered" contains "$OUT5" '"error": ""'

OUT6="$(say "$PORT" '{"text":"no timestamp","turn":"aaaa06",
  "loc":{"lat":12.3456,"lon":65.4321}}')"
turn_of 6 || die "the stub runner never ran for turn 6" "$(cat "$T/server.log")"
check_eq "a fix with no timestamp is not trusted to be fresh" \
    "$(cat "$T/place.6")" ""

echo "== an unresolvable place falls back to coordinates, never a guess =="

OUT7="$(say "$PORT" '{"text":"open sea","turn":"aaaa07",
  "loc":{"lat":45.6789,"lon":65.4321,"ts":'"$NOW_MS"'}}')"
turn_of 7 || die "the stub runner never ran for turn 7" "$(cat "$T/server.log")"
check_eq "the geocoder answered nothing usable, so the place is the coordinates" \
    "$(cat "$T/place.7")" "latitude 45.6789, longitude 65.4321"
check_eq "and the context still carries exactly one line" \
    "$(grep -c 'he is near ' "$T/context.7")" "1"

echo "== a geocoder that hangs is abandoned at its bound (server B) =="

T0="$(date +%s)"
OUT8="$(say "$PORT2" '{"text":"hung lookup","turn":"bbbb01",
  "loc":{"lat":12.3456,"lon":65.4321,"acc":5,"ts":'"$NOW_MS"'}}')"
T1="$(date +%s)"
[ -f "$T/place.8" ] || die "the stub runner never ran for turn 8" "$(cat "$T/server2.log")"
check_eq "the line fell back to plain coordinates" \
    "$(cat "$T/place.8")" "latitude 12.3456, longitude 65.4321"
check "the turn was not held hostage by the lookup ($(( T1 - T0 ))s)" \
    [ "$(( T1 - T0 ))" -lt 15 ]
check "and the reply carries no error" contains "$OUT8" '"error": ""'

echo "== the attach never re-injects (rule 1) =="

RUNS_BEFORE="$(cat "$T/n")"
say "$PORT" '{"text":"where should we eat","turn":"aaaa01",
  "loc":{"lat":45.0,"lon":45.0,"ts":'"$NOW_MS"'}}' > /dev/null
check_eq "a re-posted id attached instead of running again" \
    "$(cat "$T/n")" "$RUNS_BEFORE"

echo "== the assembler's own belt: phone origin only, one flattened line =="

FRAME_PHONE="$(sandbox_bash 'mkdir -p "$(dirname "$LAST_ORIGIN_FILE")";
    printf phone > "$LAST_ORIGIN_FILE";
    DESKCRAB_TURN_PLACE="Sesame Street, Springfield" build_system_prompt --profile turn')"
check_eq "the line, once, in a phone turn's assembled prompt" \
    "$(printf '%s' "$FRAME_PHONE" | grep -c 'he is near ')" "1"

FRAME_BARE="$(sandbox_bash 'mkdir -p "$(dirname "$LAST_ORIGIN_FILE")";
    printf phone > "$LAST_ORIGIN_FILE";
    build_system_prompt --profile turn')"
check_eq "no place, no line" \
    "$(printf '%s' "$FRAME_BARE" | grep -c 'he is near ')" "0"

FRAME_DESK="$(sandbox_bash 'mkdir -p "$(dirname "$LAST_ORIGIN_FILE")";
    printf desk > "$LAST_ORIGIN_FILE";
    DESKCRAB_TURN_PLACE="Sesame Street, Springfield" build_system_prompt --profile turn')"
check_eq "a desk turn never carries the phone's line, whatever the environment says" \
    "$(printf '%s' "$FRAME_DESK" | grep -c 'he is near ')" "0"

FRAME_FLAT="$(sandbox_bash 'mkdir -p "$(dirname "$LAST_ORIGIN_FILE")";
    printf phone > "$LAST_ORIGIN_FILE";
    DESKCRAB_TURN_PLACE="Sesame Street,
Springfield" build_system_prompt --profile turn')"
check_eq "a place carrying a newline is flattened to the one line the rule allows" \
    "$(printf '%s' "$FRAME_FLAT" | grep -c 'he is near Sesame Street, Springfield')" "1"

echo "== the client's fix helper: quiet on every failure, a fix on success =="

NODE="${NODE:-$(command -v node 2>/dev/null)}"
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    echo "  skip: no node — the client helper cases were not exercised here"
else
    "$NODE" - "$REPO_DIR/lib/webapp/index.html" > "$T/geofix.out" 2>&1 <<'JS'
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
let PASS = 0, FAIL = 0;
const ok = m => { PASS++; console.log("  ok: " + m); };
const bad = (m, got) => { FAIL++; console.log("  FAIL: " + m + " — got [" + got + "]"); };
function lift(name) {
  const start = src.indexOf(name);
  if (start < 0) throw new Error("not found in index.html: " + name);
  const end = src.indexOf("\n}\n", start);
  if (end < 0) throw new Error("no closing brace for: " + name);
  return src.slice(start, end + 3);
}
function api(geo, denied) {
  const ctx = {
    GEO_FIX_TIMEOUT_MS: 120, GEO_MAX_AGE_MS: 1000, GEO_STALE_MS: 600000,
    geoDenied: !!denied,
    navigator: { geolocation: geo },
  };
  const built = new Function("ctx", "with (ctx) {\n" + lift("function geoFix") +
                             "\nreturn {geoFix};\n}")(ctx);
  built._ctx = ctx;
  return built;
}
(async () => {
  // No geolocation at all: nothing, at once, no throw.
  let r = await api(undefined).geoFix();
  r === null ? ok("no geolocation API resolves to nothing")
             : bad("no geolocation API resolves to nothing", JSON.stringify(r));

  // A good fix comes back shaped for the wire.
  const fix = { coords: { latitude: 12.3456, longitude: 65.4321, accuracy: 9 },
                timestamp: Date.now() };
  r = await api({ getCurrentPosition: (okc) => okc(fix) }).geoFix();
  r && r.lat === 12.3456 && r.lon === 65.4321 && r.acc === 9 && r.ts === fix.timestamp
    ? ok("a granted fix carries lat, lon, accuracy and the fix's own timestamp")
    : bad("a granted fix carries lat, lon, accuracy and the fix's own timestamp",
          JSON.stringify(r));

  // A stale fix is not where he is.
  const stale = { coords: { latitude: 1, longitude: 2 },
                  timestamp: Date.now() - 7200000 };
  r = await api({ getCurrentPosition: (okc) => okc(stale) }).geoFix();
  r === null ? ok("a stale fix resolves to nothing")
             : bad("a stale fix resolves to nothing", JSON.stringify(r));

  // Denied: nothing now, and the denial is remembered — the API is never
  // asked again, so the permission prompt cannot be re-begged per message.
  let asks = 0;
  const denier = { getCurrentPosition: (okc, errc) => { asks++; errc({ code: 1 }); } };
  const a = api(denier);
  r = await a.geoFix();
  r === null && a._ctx.geoDenied === true
    ? ok("a denial resolves to nothing and is remembered")
    : bad("a denial resolves to nothing and is remembered",
          JSON.stringify([r, a._ctx.geoDenied]));
  await a.geoFix();
  asks === 1 ? ok("the remembered denial never asks the API again")
             : bad("the remembered denial never asks the API again", asks + " asks");

  // A lookup that never answers: the helper's own belt resolves it inside
  // the bound, so a send can never hang on where he is.
  const t0 = Date.now();
  r = await api({ getCurrentPosition: () => {} }).geoFix();
  const took = Date.now() - t0;
  r === null && took < 2000
    ? ok("a hung lookup resolves to nothing inside the bound (" + took + "ms)")
    : bad("a hung lookup resolves to nothing inside the bound",
          JSON.stringify(r) + " after " + took + "ms");

  // An errored lookup that is not a denial degrades without marking denial.
  const b = api({ getCurrentPosition: (okc, errc) => errc({ code: 2 }) });
  r = await b.geoFix();
  r === null && b._ctx.geoDenied === false
    ? ok("an unavailable position degrades without inventing a denial")
    : bad("an unavailable position degrades without inventing a denial",
          JSON.stringify([r, b._ctx.geoDenied]));

  console.log("geofix: " + PASS + " passed " + FAIL + " failed");
  process.exit(FAIL ? 1 : 0);
})().catch(e => { console.log("  FAIL: harness threw — " + e.message);
                  console.log("geofix: 0 passed 1 failed"); process.exit(1); });
JS
    NODE_RC=$?
    cat "$T/geofix.out"
    NP="$(sed -n 's/^geofix: \([0-9]*\) passed \([0-9]*\) failed$/\1 \2/p' "$T/geofix.out")"
    if [ -n "$NP" ]; then
        PASS=$(( PASS + ${NP% *} )); FAIL=$(( FAIL + ${NP#* } ))
        for _ in $(seq 1 ${NP% *}); do printf 'geofix\n' >> "$SANDBOX/witness/passes"; done
        for _ in $(seq 1 ${NP#* }); do printf 'geofix\n' >> "$SANDBOX/witness/failures"; done
    else
        fail "the client helper cases ran" "no summary from node (rc $NODE_RC)"
    fi
    # The wire shape: the say body the client builds carries the fix beside
    # the text, and a bare one carries exactly what it always carried.
    grep -q 'loc ? { text, turn: tid, loc } : { text, turn: tid }' \
        "$REPO_DIR/lib/webapp/index.html" \
        && ok "the say body carries the fix only when there is one (pinned)" \
        || fail "the say body carries the fix only when there is one (pinned)" \
                "the loc-bearing body line is not in index.html"
fi

curl -fsS -m 5 "http://127.0.0.1:$PORT/health?k=$SECRET" | grep -q '"ok": *true' \
    && ok "and server A is still standing" \
    || fail "and server A is still standing" "$(tail -c 300 "$T/server.log")"
