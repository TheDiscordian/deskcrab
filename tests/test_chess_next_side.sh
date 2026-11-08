#!/bin/bash
# The called colour (specs/chessweb.md rule 26). Until this rule the colour
# of the next browser game was decided by the serve's launch flag and nothing
# else — she could not call her own colour at her own table. Now
# `betty-chess next-side <white|black|random>` writes a one-shot call naming
# HER colour for the next new game; the next creation that carries no colour
# of its own spends it, on any door, and the file is gone before the record
# is saved; `random` withdraws it; every new record says whether her colour
# was called or dealt. This file pins: the CLI door (write, show, replace,
# withdraw, refuse with nothing written, a garbled file named and discarded);
# a bare `betty-chess new` spending the call while `--as` leaves it; a serve
# already running honouring a call made after it started, over its own fixed
# --human-side, for exactly one game; a refused creation spending nothing;
# the call outranking the alternation under --human-side random and the deal
# resuming after it; the call surviving a serve restart unspent; a load, a
# seat's join, an observer and /state leaving it standing; the wire NewGame
# spending it; and the provenance on the record, in `status`, in /state and
# in POST /new's answer — null on a record from before the rule.
# Run: bash tests/test_chess_next_side.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"

# Read-only use of a live path: an interpreter, not state — the same bargain
# test_chessweb.sh strikes. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

CALL=""
use_store() { # <dir> — the store every helper below reads from here on
    export DESKCRAB_CHESS_DIR="$1"
    export DESKCRAB_CHESS_REFLEX_DB="$1/reflex.db"
    mkdir -p "$1/games"
    CALL="$1/next-side"
}

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
call_side() { # the colour the standing call names, or "none"
    if [ -e "$CALL" ]; then
        CALL="$CALL" pyrun <<'PY'
import json, os
print(json.load(open(os.environ["CALL"])).get("side"))
PY
    else
        echo none
    fi
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
serve_says() { grep -q -- "$1" "$SANDBOX/serve.log"; }

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

# ---------------------------------------------------------------- the CLI
use_store "$SANDBOX/chess-cli"

echo "the call itself — written, shown, replaced, withdrawn, refused:"
out="$(chess next-side)"
contains "$out" "the coin" && [ ! -e "$CALL" ] \
    && ok "a fresh store has no call standing, and says so" \
    || fail "fresh next-side: $out"
out="$(chess next-side black)"
contains "$out" "you are black" && contains "$out" "one game only" \
    && ok "next-side black says what it did and that it is one shot" \
    || fail "next-side black: $out"
check_eq "the call file names her colour" "$(call_side)" "black"
check_eq "and records when it was called" \
    "$(CALL="$CALL" pyrun <<'PY'
import json, os
print(bool(json.load(open(os.environ["CALL"])).get("called")))
PY
)" "True"
out="$(chess next-side)"
contains "$out" "you are black" \
    && ok "next-side with no argument says what stands" \
    || fail "next-side show: $out"
chess next-side white >/dev/null
check_eq "a second call replaces the first" "$(call_side)" "white"
out="$(chess next-side random)"
contains "$out" "withdrawn" && [ ! -e "$CALL" ] \
    && ok "random withdraws the call: the file is gone" \
    || fail "next-side random: $out"
out="$(chess next-side random)"
contains "$out" "the coin" && [ ! -e "$CALL" ] \
    && ok "random with nothing standing is a quiet no-op" \
    || fail "second random: $out"
out="$(chess next-side green)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$CALL" ] \
    && ok "an argument outside the three words is refused with nothing written (rc=$rc)" \
    || fail "next-side green: rc=$rc $out"
out="$(chess next-side white black)"; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$CALL" ] \
    && ok "two colours at once are refused with nothing written" \
    || fail "next-side white black: rc=$rc $out"

echo "betty-chess new: a bare creation spends the call, --as carries its own:"
chess next-side black >/dev/null
out="$(chess new bob)"
contains "$out" "bob-001: you are black (called), bob is white" \
    && ok "new without --as deals her the called colour and says so" \
    || fail "new bob: $(echo "$out" | head -1)"
check_eq "the record carries her called colour" \
    "$(field bob-001 'g["my_side"]')" "black"
check_eq "and says it was called (rule 26c)" \
    "$(field bob-001 'g["side_by"]')" "called"
check_eq "the call is spent: the file is gone" "$(call_side)" "none"
out="$(chess status bob-001)"
contains "$out" "colour: called" \
    && ok "status prints the provenance" \
    || fail "status bob-001: $out"
out="$(chess new carl)"
contains "$out" "carl-001: you are white (dealt), carl is black" \
    && ok "the next bare creation is the CLI's default again — one shot" \
    || fail "new carl: $(echo "$out" | head -1)"
check_eq "and is recorded as dealt" "$(field carl-001 'g["side_by"]')" "dealt"
out="$(chess status carl-001)"
contains "$out" "colour: dealt" \
    && ok "status prints dealt for a dealt game" \
    || fail "status carl-001: $out"
chess next-side black >/dev/null
out="$(chess new dan --as white)"
contains "$out" "dan-001: you are white (called), dan is black" \
    && ok "--as sets the colour it names and is her call for that game" \
    || fail "new dan --as white: $(echo "$out" | head -1)"
check_eq "the standing call is left where it was" "$(call_side)" "black"
out="$(chess new erin --as black)"
contains "$out" "erin-001: you are black (called)" \
    && ok "--as black likewise" \
    || fail "new erin --as black: $(echo "$out" | head -1)"
check_eq "and still leaves the call standing" "$(call_side)" "black"
chess next-side random >/dev/null

echo "a garbled call file is named, discarded, never guessed from (rule 26d):"
printf 'garbage\n' > "$CALL"
out="$(chess next-side)"
contains "$out" "ignoring unreadable" && contains "$out" "the coin" \
    && ok "next-side names the unreadable file and reads it as no call" \
    || fail "garbled show: $out"
[ -e "$CALL" ] && ok "showing does not remove it" || fail "show removed the file"
out="$(chess new fay)"
contains "$out" "ignoring unreadable" \
    && contains "$out" "fay-001: you are white (dealt)" \
    && ok "a creation names it once, deals the default, and records dealt" \
    || fail "new fay over garbage: $(echo "$out" | head -2)"
check_eq "and discards it, so it is not named at every deal" "$(call_side)" "none"
printf '{"side": "green"}\n' > "$CALL"
out="$(chess new gus)"
contains "$out" "is not a colour" \
    && contains "$out" "gus-001: you are white (dealt)" \
    && ok "a colour that is not one is named and never dealt" \
    || fail "new gus over green: $(echo "$out" | head -2)"
check_eq "and is discarded too" "$(call_side)" "none"

# --------------------------------------------------- the serve, fixed flag
use_store "$SANDBOX/chess-flag"

echo "a running serve honours a call made after it started, over its own flag, once:"
if start_bridge "$SANDBOX/wake-flag.log" --opponent guest --human-side white; then
    # The flag deals the user white, her black. The call is made NOW, with
    # the serve already up — no flag changed, nothing restarted.
    chess next-side white >/dev/null
    check_eq "the call stands while the serve runs" "$(call_side)" "white"
    res="$(http_post /new '{}')"
    check_eq "POST /new answers 200" "${res%%|*}" "200"
    contains "$res" '"your_side": "black"' \
        && ok "the user is told black: her call of white, translated to the human side" \
        || fail "/new body: $res"
    contains "$res" '"side_by": "called"' \
        && ok "and the answer says the colour was called" \
        || fail "/new body lacks side_by called: $res"
    check_eq "the record: she is white, against the flag" \
        "$(field guest-001 'g["my_side"]')" "white"
    check_eq "and it says called" "$(field guest-001 'g["side_by"]')" "called"
    check_eq "the call is spent at creation" "$(call_side)" "none"
    serve_says "guest-001: the user is black (her white called, the call spent)" \
        && ok "the serve log names the spent call" \
        || fail "serve log: $(grep created "$SANDBOX/serve.log")"
    st="$(http_get /state)"
    contains "$st" '"side_by": "called"' && contains "$st" '"human_side": "black"' \
        && ok "/state carries the provenance beside the human side" \
        || fail "/state: $st"
    res="$(http_post /resign '{}')"
    check_eq "the user resigns the called game" "${res%%|*}" "200"
    res="$(http_post /new '{}')"
    check_eq "the next game is dealt again" "${res%%|*}" "200"
    check_eq "the game after a called one takes the flag's own colour, never the call carried on" \
        "$(field guest-002 'g["my_side"]')" "black"
    check_eq "and is recorded as dealt" "$(field guest-002 'g["side_by"]')" "dealt"
    contains "$res" '"side_by": "dealt"' \
        && ok "POST /new's answer says dealt" \
        || fail "/new second body: $res"

    echo "a refused creation spends nothing; a withdrawn call leaves no trace:"
    chess next-side black >/dev/null
    res="$(http_post /new '{}')"
    check_eq "New Game on a live board is refused (409)" "${res%%|*}" "409"
    check_eq "and the call still stands" "$(call_side)" "black"
    check_eq "nothing was created" "$(game_count)" "2"
    http_post /resign '{}' >/dev/null
    chess next-side random >/dev/null
    res="$(http_post /new '{}')"
    check_eq "after the withdrawal the flag deals" \
        "$(field guest-003 'g["my_side"]')" "black"
    check_eq "and says dealt" "$(field guest-003 'g["side_by"]')" "dealt"
fi
stop_bridge

# ------------------------------------------- the serve, random: the alternation
use_store "$SANDBOX/chess-random"

echo "random: the call survives a restart unspent, no load or join spends it, the wire NewGame does:"
# Seeded: guest-001, her white, e4 played — the user is black with the move.
# Rule 4's alternation would deal her BLACK next; the call says white, so a
# white next game is the call and nothing else.
REPO="$REPO" pyrun <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "tests", "lib"))
import chessweb_scenario as cs
cs.seed(os.environ["DESKCRAB_CHESS_DIR"], "guest-001", "guest", "white",
        ["e2e4"])
PY
chess next-side white >/dev/null
if start_bridge "$SANDBOX/wake-random.log" --opponent guest --human-side random; then
    serve_says "resuming guest-001" \
        && ok "the serve loads the active game at start" \
        || fail "serve log: $(head -5 "$SANDBOX/serve.log")"
    check_eq "loading it did not spend the call" "$(call_side)" "white"
    PORT="$PORT" REPO="$REPO" pyrun <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "tests", "lib"))
import chessweb_scenario as cs
port = int(os.environ["PORT"])
c = cs.Client(port)
c.join()
c.expect(cs.PLAYER)
c.expect(cs.OPPONENT_JOINED)
f = c.expect(cs.TEAM)
assert f.get(1, 0) == 1, f"the user should be black on the seeded game: {f}"
c.expect_move("e2", "e4")
print("  ok: the seat joined and was synced onto the seeded game")
obs = cs.Client(port)
obs.join(player=False)
obs.expect(cs.TEAM)
obs.expect_move("e2", "e4")
print("  ok: an observer was synced too")
st = cs.state_json(port)
assert st["game"] == "guest-001" and st["side_by"] is None, st
print("  ok: /state reads a record from before the rule as absence (null)")
PY
    if [ $? -eq 0 ]; then
        ok "join, observer and /state all read the store"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -10
        fail "the join scenario on the seeded game"
    fi
    check_eq "none of them spent the call" "$(call_side)" "white"
fi
stop_bridge
check_eq "the call survives the serve stopping" "$(call_side)" "white"

if start_bridge "$SANDBOX/wake-random2.log" --opponent guest --human-side random; then
    check_eq "and a restart before the next game finds it" "$(call_side)" "white"
    PORT="$PORT" REPO="$REPO" pyrun <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "tests", "lib"))
import chessweb_scenario as cs
port = int(os.environ["PORT"])
c = cs.Client(port)
c.join()
c.expect(cs.PLAYER)
c.expect(cs.OPPONENT_JOINED)
f = c.expect(cs.TEAM)
assert f.get(1, 0) == 1, f
c.expect_move("e2", "e4")
print("  ok: rejoined after the restart onto the same game")
status, j = cs.post_json(port, "/resign", {"game": "guest-001"})
assert status == 200 and j.get("ok"), (status, j)
f = c.expect(cs.GAME_COMPLETE)
print("  ok: the user resigned the seeded game")
c.send(cs.NEWGAME)
f = c.expect(cs.TEAM)
assert f.get(1, 0) == 1, \
    f"the user should be black again — her white was called: {f}"
print("  ok: the wire NewGame dealt her the called white, where the "
      "alternation would have made her black")
st = cs.state_json(port)
assert st["game"] == "guest-002" and st["human_side"] == "black", st
assert st["side_by"] == "called", st
print("  ok: /state says guest-002, the user black, the colour called")
PY
    if [ $? -eq 0 ]; then
        ok "the wire NewGame spends the call over the alternation"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -10
        fail "the wire NewGame scenario"
    fi
    check_eq "the record: she is white" "$(field guest-002 'g["my_side"]')" "white"
    check_eq "and it says called" "$(field guest-002 'g["side_by"]')" "called"
    check_eq "the call is spent" "$(call_side)" "none"
    http_post /resign '{}' >/dev/null
    res="$(http_post /new '{}')"
    check_eq "the next game is dealt" "${res%%|*}" "200"
    check_eq "and the alternation resumes from the called game: she is black" \
        "$(field guest-003 'g["my_side"]')" "black"
    check_eq "recorded as dealt" "$(field guest-003 'g["side_by"]')" "dealt"
    http_post /resign '{}' >/dev/null
    chess next-side black >/dev/null
    res="$(http_post /new '{}')"
    check_eq "a call for black where the alternation also says... white: the call wins" \
        "$(field guest-004 'g["my_side"]')" "black"
    check_eq "called" "$(field guest-004 'g["side_by"]')" "called"
fi
stop_bridge

# ------------------------------------------------- the first game: the coin
use_store "$SANDBOX/chess-coin"

echo "the first game against anyone: the call outranks the coin:"
chess next-side black >/dev/null
if start_bridge "$SANDBOX/wake-coin.log" --opponent guest --human-side random; then
    serve_says "no active game against guest yet" \
        && ok "an empty store: the first game would be the coin's" \
        || fail "serve log: $(head -5 "$SANDBOX/serve.log")"
    res="$(http_post /new '{"player": "The Visitor"}')"
    check_eq "POST /new with a named sitter answers 200" "${res%%|*}" "200"
    check_eq "her colour is the called black, not a coin's" \
        "$(field guest-001 'g["my_side"]')" "black"
    check_eq "called" "$(field guest-001 'g["side_by"]')" "called"
    check_eq "the sitter's name still rides the record (rule 23)" \
        "$(field guest-001 'g.get("player")')" "The Visitor"
    check_eq "the call is spent" "$(call_side)" "none"
fi
stop_bridge
