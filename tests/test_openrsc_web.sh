#!/bin/bash
# The authenticated OpenRSC spectator (phone.md rules 53-55): one read-only
# frame producer is shared by requests, HUD state is allowlisted, and every
# route rides the existing phone server's auth boundary.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

T="$SANDBOX"
REPO_DIR="$SANDBOX_REPO"
SECRET="testsecret"
WATCH_SECRET="watchsecret"
PORT=18735
BASE="http://127.0.0.1:$PORT"
HEADLESS="$T/headless"
GSTATE="$T/game-state"
GDATA="$T/game-data"
SERVER_PID=""

sandbox_at_exit '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null'
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

echo "== share links use a durable spectator-only key =="
LINK1="$("$REPO_DIR/crab" openrsc-link https://watch.example)"
LINK2="$("$REPO_DIR/crab" openrsc-link https://watch.example/)"
check "the command prints an explicit spectator URL" \
    bash -c '[[ "$1" =~ ^https://watch\.example/openrsc\?g=[a-f0-9]{48}$ ]]' _ "$LINK1"
check_eq "the generated share key is durable" "$LINK2" "$LINK1"
check_eq "the generated key is owner-readable only" \
    "$(stat -c '%a' "$XDG_DATA_HOME/deskcrab/openrsc-secret")" "600"

mkdir -p "$HEADLESS/run" "$GSTATE" "$GDATA"
printf '77\n' > "$HEADLESS/run/display"
NOW_MS="$(($(date +%s%N) / 1000000))"
python3 - "$GSTATE/state.json" "$NOW_MS" <<'PY'
import json, sys
json.dump({
    "ts": int(sys.argv[2]), "logged_in": True, "x": 307, "z": 639,
    "hits": 19, "hits_max": 21, "fatigue": 12, "walking": False,
    "in_combat": False, "sleeping": False,
    "skills": [{"id": 14, "name": "Mining", "xp": 1250}],
    # These sensitive/noisy fields prove the endpoint is an allowlist.
    "inventory": [{"id": 10, "name": "Coins", "count": 999}],
    "messages": [{"text": "private words"}],
}, open(sys.argv[1], "w"))
PY
printf 'mining\n' > "$GDATA/activity"
printf 'mining-level-15\n' > "$GDATA/objective"
python3 - "$GDATA/activity-stats.json" "$NOW_MS" <<'PY'
import json, sys
json.dump({"activity": "mining", "started_ms": int(sys.argv[2]) - 3600000,
           "baseline_xp": {"14": 1000}}, open(sys.argv[1], "w"))
PY

# A deterministic image2pipe producer: each JPEG is deliberately tiny, but
# has the same SOI/EOI framing the real ffmpeg stream uses.
printf '%s\n' '#!/bin/bash' \
    "printf '%s\\n' \"\$\$\" > '$T/fake-ffmpeg.pid'" \
    'while :; do' \
    "    printf '\\377\\330OPENRSC-FRAME\\377\\331'" \
    '    sleep 0.05' \
    'done' > "$T/fake-ffmpeg"
chmod +x "$T/fake-ffmpeg"

DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_OPENRSC_SECRET="$WATCH_SECRET" \
DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_CRAB_BIN="$T/crab-absent" DESKCRAB_STATE_PREFIX="$T/deskcrab" \
DESKCRAB_OPENRSC_HEADLESS="$HEADLESS" \
DESKCRAB_OPENRSC_STATE_DIR="$GSTATE" DESKCRAB_OPENRSC_GAME_DIR="$GDATA" \
DESKCRAB_OPENRSC_SOURCE=10,20,512,346 \
DESKCRAB_OPENRSC_POINTER=133,65 \
DESKCRAB_OPENRSC_FFMPEG="$T/fake-ffmpeg" \
DESKCRAB_OPENRSC_IDLE_SECONDS=3 \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 100); do
    curl -fsS -m 2 "$BASE/health" >/dev/null 2>&1 && break
    sleep 0.1
done

echo "== every spectator route uses a scoped authentication boundary =="
check_eq "the page is hidden without the key" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/openrsc")" "404"
check_eq "HUD state is hidden without the key" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/openrsc/state")" "404"
check_eq "frames are hidden without the key" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/openrsc/frame.jpg")" "404"
check_eq "a wrong spectator key reveals nothing" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/openrsc?g=wrong")" "404"

PAGE="$(curl -fsS "$BASE/openrsc?k=$SECRET")"
check "the authenticated mobile spectator page is served" \
    contains "$PAGE" "Beatrice · OpenRSC"
check "the page identifies itself as read-only" contains "$PAGE" "Read-only spectator"
check "the page has a fullscreen affordance" contains "$PAGE" "Fullscreen"
check "the page overlays the private game pointer" \
    bash -c 'grep -q "id=\"game-pointer\"" <<<"$1" && grep -q "X-Pointer-X" <<<"$1"' _ "$PAGE"
check "the page consumes only the spectator frame and state routes" \
    bash -c '! grep -qE "fetch\\([^\n]*(walk|click|key|action|press|trade)" <<<"$1"' _ "$PAGE"
check "the page contains no external assets or fetches" \
    bash -c '! grep -qiE "https?://|cdn\\.|integrity=" <<<"$1"' _ "$PAGE"
check "the ordinary phone page links to the spectator" \
    grep -q 'href="/openrsc"' "$REPO_DIR/lib/webapp/index.html"

curl -fsS -D "$T/watch.hdr" -c "$T/watch.cookies" \
    "$BASE/openrsc?g=$WATCH_SECRET" -o "$T/watch.html"
grep -qi '^set-cookie: openrsckey=.*Path=/openrsc;.*HttpOnly' "$T/watch.hdr" \
    && ! grep -qi '^set-cookie:.*; Secure' "$T/watch.hdr" \
    && ok "plain LAN HTTP gets a usable path-scoped HttpOnly cookie" \
    || fail "plain LAN HTTP gets a usable path-scoped HttpOnly cookie" "$(grep -i '^set-cookie' "$T/watch.hdr")"
curl -fsS -H 'X-Forwarded-Proto: https' -D "$T/watch-https.hdr" \
    "$BASE/openrsc?g=$WATCH_SECRET" -o /dev/null
grep -qi '^set-cookie: openrsckey=.*Path=/openrsc;.*HttpOnly; Secure' "$T/watch-https.hdr" \
    && ok "proxied HTTPS marks the spectator cookie Secure" \
    || fail "proxied HTTPS marks the spectator cookie Secure" "$(grep -i '^set-cookie' "$T/watch-https.hdr")"
check "the page removes the share key from its visible URL" \
    grep -q 'history.replaceState' "$T/watch.html"
check_eq "the spectator cookie can reopen the game page" \
    "$(curl -s -b "$T/watch.cookies" -o /dev/null -w '%{http_code}' "$BASE/openrsc")" "200"
check_eq "the spectator cookie cannot read assistant context" \
    "$(curl -s -b "$T/watch.cookies" -o /dev/null -w '%{http_code}' "$BASE/context")" "404"

echo "== the HUD is useful but narrowly allowlisted =="
STATE="$(curl -fsS -b "$T/watch.cookies" "$BASE/openrsc/state")"
check_eq "activity reaches the HUD" \
    "$(printf '%s' "$STATE" | jq -r .activity)" "mining"
check_eq "HP reaches the HUD" \
    "$(printf '%s' "$STATE" | jq -r '.hp | "\(.current)/\(.maximum)"')" "19/21"
check_eq "positive XP/hour is calculated from the activity baseline" \
    "$(printf '%s' "$STATE" | jq -r '.xp_rates[0] | "\(.skill):\(.per_hour)"')" \
    "Mining:250"
refute "inventory never leaves the game machine" grep -q 'Coins\|inventory' <<<"$STATE"
refute "chat never leaves the game machine" grep -q 'private words\|messages' <<<"$STATE"
refute "capture internals never leave the game machine" \
    grep -q 'display\|source\|generation\|streaming' <<<"$STATE"

echo "== one on-demand producer serves fresh JPEG frames =="
curl -fsS -D "$T/frame1.hdr" -o "$T/frame1.jpg" \
    -b "$T/watch.cookies" "$BASE/openrsc/frame.jpg?after=0"
grep -qi '^content-type: image/jpeg' "$T/frame1.hdr" \
    && ok "the frame has the browser's native JPEG content type" \
    || fail "the frame has the browser's native JPEG content type" \
            "$(grep -i '^content-type' "$T/frame1.hdr")"
grep -qi '^cache-control: no-store' "$T/frame1.hdr" \
    && ok "live pixels are never cached" \
    || fail "live pixels are never cached" "$(cat "$T/frame1.hdr")"
check_eq "the frame carries the crop-local virtual pointer x" \
    "$(sed -n 's/^X-Pointer-X: *//Ip' "$T/frame1.hdr" | tr -d '\r')" "123"
check_eq "the frame carries the crop-local virtual pointer y" \
    "$(sed -n 's/^X-Pointer-Y: *//Ip' "$T/frame1.hdr" | tr -d '\r')" "45"
python3 - "$T/frame1.jpg" <<'PY' \
    && ok "the complete JPEG frame crosses the route" \
    || fail "the complete JPEG frame crosses the route" "bad JPEG framing"
import sys
b = open(sys.argv[1], "rb").read()
raise SystemExit(0 if b.startswith(b"\xff\xd8") and b.endswith(b"\xff\xd9") else 1)
PY
GEN="$(sed -n 's/^X-Frame-Generation: *//Ip' "$T/frame1.hdr" | tr -d '\r')"
FFMPEG_PID="$(cat "$T/fake-ffmpeg.pid")"
curl -fsS -D "$T/frame2.hdr" -o "$T/frame2.jpg" \
    -b "$T/watch.cookies" "$BASE/openrsc/frame.jpg?after=$GEN"
GEN2="$(sed -n 's/^X-Frame-Generation: *//Ip' "$T/frame2.hdr" | tr -d '\r')"
[ "$GEN2" -gt "$GEN" ] \
    && ok "after=N waits for a genuinely newer frame" \
    || fail "after=N waits for a genuinely newer frame" "$GEN -> $GEN2"
check_eq "subsequent viewers share the same ffmpeg producer" \
    "$(cat "$T/fake-ffmpeg.pid")" "$FFMPEG_PID"

sleep 4
if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    fail "the producer stops after the last viewer goes idle" "pid $FFMPEG_PID alive"
else
    ok "the producer stops after the last viewer goes idle"
fi

refute "neither phone nor spectator credentials enter the access log" \
    grep -q "$SECRET\|$WATCH_SECRET" "$T/server.log"
