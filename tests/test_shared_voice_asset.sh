#!/bin/bash
# ONE shared voice queue, two servers, byte for byte — specs/phone.md rule
# 44c and specs/chessweb.md rule 24g. Proven here:
#   - the module's own mechanics, bare (tests/browser_voice_queue_test.js):
#     arrival-order exactly-once serial playback, the terminal dead state,
#     both orderings of a dead source's two signals, the refusal hold and
#     its gesture resume, the never-started bound with progress re-arm and
#     duck deferral, ended-without-start as a failure, drop-queued sparing
#     the sounding clip, and the silent stop
#   - BOTH pages load the identical asset path
#   - BOTH servers answer the file's exact bytes: the phone server behind
#     its auth (no key is 404 — the route discloses nothing), the chess
#     bridge through its own explicit route, and the bridge's served
#     index.html carries the script tag
#   - the walls stand (rule 24g): no serve.py import, no phone secret, no
#     proxy anywhere in the bridge; nothing phone-shaped in the module
# The bridge half needs the betty-chess venv (python-chess) and SKIPS that
# section loudly when absent, exactly as tests/test_chessweb.sh does; node
# is not a DeskCrab dependency, so a machine without it exits 77.
# Run: bash tests/test_shared_voice_asset.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
MODULE="$REPO/lib/browser_voice_queue.js"

NODE="${NODE:-$(command -v node 2>/dev/null)}"
[ -z "$NODE" ] && [ -x /usr/bin/node ] && NODE=/usr/bin/node
if [ -z "$NODE" ] || [ ! -x "$NODE" ]; then
    echo "  skip: no node found — the shared queue module was not exercised."
    echo "  (set NODE=/path/to/node to run it)"
    exit 77
fi

# --- the module, bare -------------------------------------------------------
echo "== the module: the shared mechanics, driven directly =="

[ -f "$MODULE" ] \
    && ok "lib/browser_voice_queue.js exists" \
    || fail "lib/browser_voice_queue.js exists" "missing"

if "$NODE" "$REPO/tests/browser_voice_queue_test.js" > "$T/module-node.out" 2>&1; then
    NODE_RC=0
else
    NODE_RC=1
fi
# The node harness's assertions are this suite's assertions, mirrored line by
# line; its own tally line is dropped — the summary below is the one that
# counts.
while IFS= read -r line; do
    case "$line" in
        "  ok: "*)   ok "${line#  ok: }" ;;
        "  FAIL: "*) fail "${line#  FAIL: }" ;;
        [0-9]*" passed, "*" failed") ;;
        *) [ -n "$line" ] && echo "$line" ;;
    esac
done < "$T/module-node.out"
[ "$NODE_RC" -eq 0 ] \
    && ok "the module harness verdict is green" \
    || fail "the module harness verdict is green" "$(tail -n3 "$T/module-node.out")"

# --- both pages, one asset --------------------------------------------------
echo "== the pages: both load the identical shared asset =="

grep -q 'src="browser_voice_queue.js"' "$REPO/lib/webapp/index.html" \
    && ok "the phone page loads browser_voice_queue.js" \
    || fail "the phone page loads browser_voice_queue.js" \
            "$(grep -n 'script src' "$REPO/lib/webapp/index.html")"
grep -q 'src="browser_voice_queue.js"' "$REPO/lib/chessweb_client/index.html" \
    && ok "the chess page loads the SAME path" \
    || fail "the chess page loads the SAME path" \
            "$(grep -n 'script src' "$REPO/lib/chessweb_client/index.html")"
grep -q 'BrowserVoiceQueue' "$REPO/lib/webapp/index.html" \
    && grep -q 'BrowserVoiceQueue' "$REPO/lib/chessweb_client/board.js" \
    && ok "both pages build their queue from the module's one global" \
    || fail "both pages build their queue from the module's one global" \
            "a page never references BrowserVoiceQueue"

# --- the walls, in the files themselves -------------------------------------
echo "== the walls: neutral module, no phone anywhere near the bridge =="

# Comments may NAME what stays on the pages (that is documentation of the
# split); the CODE must carry none of it — no secret, no route, no fetch.
sed 's|//.*$||' "$MODULE" | grep -qiE \
        'crabkey|X-Crab-Key|DESKCRAB_SERVE_SECRET|/played|/watch|/chat|fetch\(|XMLHttpRequest' \
    && fail "the module's code is neutral — no secret, no route, no request" \
            "$(sed 's|//.*$||' "$MODULE" | grep -niE 'crabkey|X-Crab-Key|DESKCRAB_SERVE_SECRET|/played|/watch|/chat|fetch\(|XMLHttpRequest' | head -3)" \
    || ok "the module's code is neutral — no secret, no route, no request"
grep -qE 'import serve|from serve import|serve\.py|DESKCRAB_SERVE_SECRET|crabkey|X-Crab-Key' \
        "$REPO/lib/chessweb.py" \
    && fail "the bridge holds no phone import, secret, or proxy" \
            "$(grep -nE 'import serve|serve\.py|DESKCRAB_SERVE_SECRET|crabkey' "$REPO/lib/chessweb.py")" \
    || ok "the bridge holds no phone import, secret, or proxy"

# --- the phone server: exact bytes, behind the auth -------------------------
echo "== the phone server: the file's exact bytes, behind the auth =="

SECRET="testsecret"
PORT_A=18737   # the other phone tests hold 18723-18736
PID_A=""
BRIDGE_PID=""
sandbox_at_exit '[ -n "$PID_A" ] && kill "$PID_A" 2>/dev/null;
                 [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null'

DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT_A" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_STATE_PREFIX="$T/deskcrab-a" \
    python3 "$REPO/lib/serve.py" > "$T/server-a.log" 2>&1 &
PID_A=$!
for _ in $(seq 1 100); do
    curl -fsS -m 2 "http://127.0.0.1:$PORT_A/health?k=$SECRET" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS -m 2 "http://127.0.0.1:$PORT_A/health?k=$SECRET" >/dev/null 2>&1 \
    || die "the phone server on :$PORT_A never came up" "$(cat "$T/server-a.log")"

curl -fsS -m 5 -o "$T/phone-asset.js" \
    "http://127.0.0.1:$PORT_A/browser_voice_queue.js?k=$SECRET" \
    || fail "the authenticated route answers" "curl failed"
cmp -s "$T/phone-asset.js" "$MODULE" \
    && ok "the phone server serves the file's exact bytes" \
    || fail "the phone server serves the file's exact bytes" \
            "$(cmp "$T/phone-asset.js" "$MODULE" 2>&1 | head -1)"
NOKEY="$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$PORT_A/browser_voice_queue.js")"
check_eq "and without the key it is 404 — the route discloses nothing" \
    "$NOKEY" "404"

# --- the chess bridge: the same bytes, its own route ------------------------
echo "== the chess bridge: the SAME bytes, through its own route =="

VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
if [ ! -x "$VENV_PY" ] || ! "$VENV_PY" -B -c 'import chess' 2>/dev/null; then
    echo "  skip: the betty-chess venv is not built — the bridge half was not exercised."
else
    export PYTHONDONTWRITEBYTECODE=1
    WAKE_STUB="$T/wake-stub"
    printf '#!/bin/bash\n:\n' > "$WAKE_STUB"
    chmod +x "$WAKE_STUB"
    CH="$T/chess-asset"
    mkdir -p "$CH/games"
    : > "$T/bridge.log"
    env DESKCRAB_CHESS_DIR="$CH" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        DESKCRAB_CHESS_CHAT=0 DESKCRAB_CHESS_REFLEX=0 \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$REPO/lib/chessweb_client" --poll 0.2 \
        --human-side white --opponent guest \
        >> "$T/bridge.log" 2>&1 &
    BRIDGE_PID=$!
    PORT_B=""
    for _ in $(seq 1 100); do
        PORT_B="$(sed -n 's/.*on port \([0-9]*\)$/\1/p' "$T/bridge.log" | head -1)"
        [ -n "$PORT_B" ] && break
        kill -0 "$BRIDGE_PID" 2>/dev/null || break
        sleep 0.1
    done
    if [ -z "$PORT_B" ]; then
        sed 's/^/    bridge: /' "$T/bridge.log"
        die "the bridge never reported its port"
    fi

    curl -fsS -m 5 -o "$T/chess-asset.js" \
        "http://127.0.0.1:$PORT_B/browser_voice_queue.js" \
        || fail "the bridge route answers" "curl failed"
    cmp -s "$T/chess-asset.js" "$MODULE" \
        && ok "the bridge serves the file's exact bytes" \
        || fail "the bridge serves the file's exact bytes" \
                "$(cmp "$T/chess-asset.js" "$MODULE" 2>&1 | head -1)"
    cmp -s "$T/chess-asset.js" "$T/phone-asset.js" \
        && ok "so both servers answer the identical asset, byte for byte" \
        || fail "so both servers answer the identical asset, byte for byte" \
                "the two responses differ"
    CTYPE="$(curl -s -m 5 -o /dev/null -w '%{content_type}' \
        "http://127.0.0.1:$PORT_B/browser_voice_queue.js")"
    contains "$CTYPE" "application/javascript" \
        && ok "served as javascript" \
        || fail "served as javascript" "$CTYPE"
    curl -fsS -m 5 "http://127.0.0.1:$PORT_B/" > "$T/bridge-index.html" 2>/dev/null
    grep -q 'src="browser_voice_queue.js"' "$T/bridge-index.html" \
        && ok "the bridge's served page carries the script tag" \
        || fail "the bridge's served page carries the script tag" \
                "$(grep -c script "$T/bridge-index.html") script tags"
    # The walls, probed on the wire: a phone route on the bridge is nothing.
    PW="$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$PORT_B/watch?since=0")"
    check_eq "a phone route asked of the bridge is 404 — nothing is proxied" \
        "$PW" "404"
fi
