#!/bin/bash
# The opponent opens his own game and picks the clock from the page he
# actually loads (specs/chessweb.md rule 22h). The clock half of rule 22
# shipped green on paths nobody clicks — a per-serve flag and a per-CLI flag —
# and the user, sat at the real browser page on 2026-08-25, found no clock
# options on screen at all. This file pins the other half: the served markup
# carries a visible selector offering exactly the enabled live set, POST /new
# creates the game through the SAME path as every other door so the record,
# the reflex ledger and betty-chess list split by variant with no second
# implementation, the server refuses an out-of-set or forged control with
# nothing written, an omitted control is untimed — never the serve flag — a
# board still in flight refuses naming the way out, and the stock wire
# NewGame keeps dealing the serve's own default untouched.
# Run: bash tests/test_chess_new_game_ui.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"

# Read-only use of a live path: an interpreter, not state — the same bargain
# test_chess_clock.sh strikes. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

export DESKCRAB_CHESS_DIR="$SANDBOX/chess-games"
export DESKCRAB_CHESS_REFLEX_DB="$DESKCRAB_CHESS_DIR/reflex.db"
mkdir -p "$DESKCRAB_CHESS_DIR/games"

chess() { "$VENV_PY" -B "$REPO/lib/chess_cli.py" "$@" 2>&1; }
pyrun() { "$VENV_PY" -B - "$@"; }

field() { # <gid> <python expr over g>
    GID="$1" EXPR="$2" pyrun <<'PY'
import json, os
g = json.load(open(os.path.join(os.environ["DESKCRAB_CHESS_DIR"], "games",
                                os.environ["GID"] + ".json")))
print(eval(os.environ["EXPR"]))
PY
}

game_count() { ls "$DESKCRAB_CHESS_DIR/games" 2>/dev/null | grep -c '\.json$'; }

WAKE_STUB="$SANDBOX/wake-stub"
cat > "$WAKE_STUB" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CHESSWEB_WAKE_LOG"
SH
chmod +x "$WAKE_STUB"
MOVER_STUB="$SANDBOX/mover-stub"
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$MOVER_STUB"
chmod +x "$MOVER_STUB"

BRIDGE_PID=""
PORT=""
start_bridge() { # <wake log> [serve args...]
    local wakelog="$1"
    shift
    : > "$wakelog"
    : > "$SANDBOX/serve.log"
    DESKCRAB_CHESS_DIR="$DESKCRAB_CHESS_DIR" CHESSWEB_WAKE_LOG="$wakelog" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$REPO/lib/chessweb_client" --poll 0.2 "$@" \
        >> "$SANDBOX/serve.log" 2>&1 &
    BRIDGE_PID=$!
    PORT=""
    for _ in $(seq 1 100); do
        PORT="$(sed -n 's/.*on port \([0-9]*\)$/\1/p' "$SANDBOX/serve.log" | head -1)"
        [ -n "$PORT" ] && return 0
        kill -0 "$BRIDGE_PID" 2>/dev/null || break
        sleep 0.1
    done
    sed 's/^/    serve: /' "$SANDBOX/serve.log"
    fail "the bridge never reported its port"
    return 1
}
stop_bridge() {
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null
    wait "$BRIDGE_PID" 2>/dev/null
    BRIDGE_PID=""
}
sandbox_at_exit 'stop_bridge'

http_get() { # <path> -> the body
    PORT="$PORT" HPATH="$1" pyrun <<'PY'
import os, urllib.request
print(urllib.request.urlopen(
    f"http://127.0.0.1:{os.environ['PORT']}{os.environ['HPATH']}",
    timeout=10).read().decode())
PY
}

http_post() { # <path> <raw body> -> "<status>|<body, one line>"
    PORT="$PORT" HPATH="$1" BODY="$2" pyrun <<'PY'
import os, urllib.error, urllib.request
req = urllib.request.Request(
    f"http://127.0.0.1:{os.environ['PORT']}{os.environ['HPATH']}",
    data=os.environ["BODY"].encode(),
    headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        status, out = r.status, r.read()
except urllib.error.HTTPError as e:
    status, out = e.code, e.read()
print(f"{status}|{out.decode(errors='replace')}".replace("\n", " "))
PY
}

# The serve carries its own default control on purpose: the page's choice —
# and the endpoint's untimed default — must be provably independent of it.
echo "the page the opponent loads offers the enabled clocks, nothing else:"
if ! start_bridge "$SANDBOX/wake.log" --opponent guest --human-side white \
        --time-control 5+0; then
    die "no bridge, nothing else can run"
fi
page="$(http_get /)"
contains "$page" 'id="timecontrol"' \
    && ok "the served markup carries the clock selector (rule 22h)" \
    || fail "no clock selector in the served page"
for c in untimed 3+2 5+0 10+0 15+10; do
    contains "$page" "value=\"$c\"" \
        && ok "the selector offers $c" \
        || fail "the selector does not offer $c"
done
for c in 1+0 2+1; do
    if contains "$page" "value=\"$c\""; then
        fail "the selector still offers disabled Bullet $c"
    else
        ok "the selector does not offer disabled Bullet $c"
    fi
done
n="$(PAGE="$page" pyrun <<'PY'
import os, re
m = re.search(r'<select id="timecontrol".*?</select>', os.environ["PAGE"], re.S)
print(len(re.findall(r"<option", m.group(0))) if m else -1)
PY
)"
check_eq "and exactly the enabled live set — no invented control" "$n" "5"

echo "POST /new creates through the one path and syncs the joined seat:"
PORT="$PORT" REPO="$REPO" pyrun <<'PY'
import json, os, sys, urllib.request
sys.path.insert(0, os.path.join(os.environ["REPO"], "tests", "lib"))
import chessweb_scenario as cs
port = int(os.environ["PORT"])
c = cs.Client(port)
c.join()
c.expect(cs.PLAYER)
c.expect(cs.OPPONENT_JOINED)
# No game is active, so no Team on join: the sync below can only be the
# creation's own doing.
req = urllib.request.Request(
    f"http://127.0.0.1:{port}/new",
    data=json.dumps({"control": "3+2"}).encode(),
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=10) as r:
    assert r.status == 200, r.status
    body = json.loads(r.read())
assert body.get("ok") and body.get("game") == "guest-001", body
assert body.get("control") == "3+2", body
print("  ok: POST /new answered the created game and its control")
c.expect(cs.TEAM, timeout=10)
print("  ok: the joined seat was synced onto the new game (Team)")
PY
if [ $? -eq 0 ]; then
    ok "the browser-opened game came back through rule 4's own sync"
else
    sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -10
    fail "POST /new with a chosen control did not create and sync"
fi
check_eq "the record carries the chosen control (one creation path)" \
    "$(field guest-001 'g["time_control"]["name"]')" "3+2"
check_eq "both sides start on the chosen base" \
    "$(field guest-001 '(g["clock"]["white_ms"], g["clock"]["black_ms"])')" \
    "(180000, 180000)"
out="$(chess list)"
contains "$out" "guest-001" && contains "$out" "3+2" \
    && ok "betty-chess list splits the browser-dealt game by variant" \
    || fail "list does not carry the chosen control: $out"

echo "a board in flight refuses, naming the way out, and nothing is created:"
res="$(http_post /new '{"control": "5+0"}')"
check_eq "the refusal is HTTP 409" "${res%%|*}" "409"
contains "$res" "Resign" \
    && ok "the refusal names the way out (rule 4's answer)" \
    || fail "refusal body: $res"
check_eq "the live game stayed, nothing was created" "$(game_count)" "1"

echo "enforcement is server-side only: out-of-set and forged controls refuse:"
chess resign guest-001 >/dev/null 2>&1 || true
res="$(http_post /new '{"control": "1+0"}')"
check_eq "disabled Bullet is HTTP 400" "${res%%|*}" "400"
contains "$res" "not yet fast enough for Bullet" \
    && ok "the Bullet refusal explains why the mode is disabled" \
    || fail "Bullet refusal body: $res"
check_eq "and nothing was created for disabled Bullet" "$(game_count)" "1"
if out="$(chess new cli-bullet --time-control 2+1 2>&1)"; then
    fail "the CLI created disabled Bullet: $out"
else
    contains "$out" "not yet fast enough for Bullet" \
        && ok "the CLI enforces the same Bullet gate" \
        || fail "CLI Bullet refusal: $out"
fi
res="$(http_post /new '{"control": "7+7"}')"
check_eq "an out-of-set name is HTTP 400" "${res%%|*}" "400"
contains "$res" "unknown time control" \
    && ok "the refusal names the standard set's judgement" \
    || fail "7+7 refusal body: $res"
check_eq "and nothing was created for it" "$(game_count)" "1"
res="$(http_post /new '{"control": {"name": "1+0", "base_ms": 999999}}')"
check_eq "a forged non-name control object is HTTP 400" "${res%%|*}" "400"
check_eq "and nothing was created for the forgery" "$(game_count)" "1"
res="$(http_post /new 'not json at all')"
check_eq "an unreadable body is HTTP 400" "${res%%|*}" "400"
check_eq "and nothing was created for it either" "$(game_count)" "1"

echo "an omitted control is untimed — the CLI's default, never the serve flag:"
res="$(http_post /new '{}')"
check_eq "POST /new with no control answers 200" "${res%%|*}" "200"
contains "$res" '"untimed"' \
    && ok "and names untimed, though the serve itself carries 5+0" \
    || fail "omitted-control body: $res"
check_eq "the record has no clock fields at all — exactly an old untimed game" \
    "$(field guest-002 '"time_control" in g or "clock" in g')" "False"
out="$(chess list)"
contains "$out" "guest-002" && contains "$out" "untimed" \
    && ok "list reads the omitted-control game as untimed" \
    || fail "list on the untimed game: $out"

echo "the page's own default, explicit untimed, is honoured as a choice:"
chess resign guest-002 >/dev/null 2>&1 || true
res="$(http_post /new '{"control": "untimed"}')"
check_eq "an explicit untimed answers 200" "${res%%|*}" "200"
check_eq "and deals no clock" \
    "$(field guest-003 '"time_control" in g or "clock" in g')" "False"

echo "the stock wire NewGame is untouched: it still deals the serve's default:"
chess resign guest-003 >/dev/null 2>&1 || true
PORT="$PORT" REPO="$REPO" pyrun <<'PY'
import glob, json, os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "tests", "lib"))
import chessweb_scenario as cs
port = int(os.environ["PORT"])
c = cs.Client(port)
c.join()
c.expect(cs.PLAYER)
c.expect(cs.OPPONENT_JOINED)
c.send(cs.NEWGAME, b"")
# The poll can announce the preceding CLI resignation just after this fresh
# connection joins. That settled game's GameComplete may arrive before the
# new game's Team; it is not the NewGame response and may be skipped here.
while True:
    mtype, fields = c.recv(timeout=10)
    if mtype == cs.TEAM:
        break
    assert mtype == cs.GAME_COMPLETE, (mtype, fields)
gs = [json.load(open(p)) for p in glob.glob(os.path.join(
    os.environ["DESKCRAB_CHESS_DIR"], "games", "*.json"))]
g = max(gs, key=lambda x: x["id"])
tc = g.get("time_control")
assert tc and tc["name"] == "5+0", (g["id"], tc)
print(f"  ok: wire NewGame dealt {g['id']} at the serve's own 5+0")
PY
[ $? -eq 0 ] \
    && ok "a stock client loses nothing (compatibility guard, green both sides)" \
    || fail "the wire NewGame no longer deals the serve default"
stop_bridge
