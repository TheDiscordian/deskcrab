#!/bin/bash
# The named player and the table chat (specs/chessweb.md rules 23 and 24).
#
# The bridge runs against a scratch store with every model call stubbed: the
# mover through $DESKCRAB_CHESS_MOVER_CMD as ever, and her chat through
# $DESKCRAB_CHESS_CHAT_CMD — the prompt lands in a log as evidence, the reply
# comes off a substring map, and PASS is the stub's default answer. Proven
# here, end to end from the wire and the HTTP endpoints:
#   - /new stores a validated player name; /state and the record carry it;
#     forged and over-long names are refused with nothing written
#   - after a landed exchange she may post at the table; her message rides
#     the game record (never any conversation store), and the prompt that
#     produced it names the sitter, the venue, and the COUNTED record
#   - POST /chat appends the sitter's message, ?since pages the thread, and
#     she answers a message that was not a move
#   - a PASS posts nothing; DESKCRAB_CHESS_CHAT=0 stops the calls wholesale
#     while the sitter's messages still record; a legacy game IS an empty chat
#   - GET /record and `betty-chess record` split the score per player off one
#     tally, mated games counted (the 2026-08-20 naive-tally trap), unlabeled
#     games in their own visible pile; `betty-chess label` is the migration
# Run: bash tests/test_chess_chat.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
SCENARIO="$REPO/tests/lib/chessweb_scenario.py"

# Read-only use of a live path: an interpreter, not state — the same bargain
# tests/test_chessweb.sh strikes. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

CLIENT="$SANDBOX/client"
mkdir -p "$CLIENT"
printf '%s\n' '<html><input id="serveraddr" value="127.0.0.1:8181"></html>' \
    > "$CLIENT/index.html"

WAKE_STUB="$SANDBOX/wake-stub"
cat > "$WAKE_STUB" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CHESSWEB_WAKE_LOG"
SH
chmod +x "$WAKE_STUB"

# The mover's model call, stubbed (chessweb.md rule 16f).
MOVER_STUB="$SANDBOX/mover-stub"
cat > "$MOVER_STUB" <<'SH'
#!/bin/bash
prompt="$(cat)"
printf '%s\n----\n' "$prompt" >> "$CHESSWEB_MOVER_LOG"
[ -f "${CHESSWEB_MOVER_REPLIES:-}" ] || exit 0
while IFS=$'\t' read -r pat reply; do
    [ -n "$pat" ] || continue
    case "$prompt" in *"$pat"*) printf '%s\n' "$reply"; exit 0 ;; esac
done < "$CHESSWEB_MOVER_REPLIES"
exit 0
SH
chmod +x "$MOVER_STUB"

# Her chat call, stubbed (chessweb.md rule 24d): the prompt is kept as
# evidence, the reply is looked up by substring, and silence — the literal
# PASS — is the default, exactly the protocol the real model is held to.
CHAT_STUB="$SANDBOX/chat-stub"
cat > "$CHAT_STUB" <<'SH'
#!/bin/bash
prompt="$(cat)"
printf '%s\n----\n' "$prompt" >> "$CHESSWEB_CHAT_LOG"
[ -f "${CHESSWEB_CHAT_REPLIES:-}" ] || { echo PASS; exit 0; }
while IFS=$'\t' read -r pat reply; do
    [ -n "$pat" ] || continue
    case "$prompt" in *"$pat"*) printf '%s\n' "$reply"; exit 0 ;; esac
done < "$CHESSWEB_CHAT_REPLIES"
echo PASS
SH
chmod +x "$CHAT_STUB"

REPLIES="$SANDBOX/mover-replies.tsv"
printf 'ply 1\te7e5\n' > "$REPLIES"
CHAT_REPLIES="$SANDBOX/chat-replies.tsv"
printf 'Just now: You played\tHappy to dance, e4 e5 it is.\n' > "$CHAT_REPLIES"
printf 'Just now: Visitor says\tHello yourself! Good luck today.\n' >> "$CHAT_REPLIES"

BRIDGE_PID=""
PORT=""
start_bridge() { # <chess dir> <wake log> <chat log> <chat replies> [env k=v...] -- [serve args...]
    local dir="$1" wakelog="$2" chatlog="$3" chatreplies="$4"
    shift 4
    local extra_env=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        extra_env+=("$1")
        shift
    done
    [ "${1:-}" = "--" ] && shift
    : > "$wakelog"
    : > "$chatlog"
    : > "$SANDBOX/serve.log"
    : > "$SANDBOX/mover.log"
    env DESKCRAB_CHESS_DIR="$dir" CHESSWEB_WAKE_LOG="$wakelog" \
        DESKCRAB_CHESSWEB_WAKE_CMD="$WAKE_STUB" \
        DESKCRAB_CHESS_MOVER_CMD="$MOVER_STUB" \
        CHESSWEB_MOVER_LOG="$SANDBOX/mover.log" \
        CHESSWEB_MOVER_REPLIES="$REPLIES" \
        DESKCRAB_CHESS_CHAT_CMD="$CHAT_STUB" \
        CHESSWEB_CHAT_LOG="$chatlog" \
        CHESSWEB_CHAT_REPLIES="$chatreplies" \
        "${extra_env[@]}" \
        "$VENV_PY" -B "$REPO/lib/chessweb.py" serve --port 0 \
        --client "$CLIENT" --poll 0.2 --human-side white "$@" \
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
scn() { # <name> [args...]
    local name="$1"
    if timeout 90 "$VENV_PY" -B "$SCENARIO" "$@"; then
        ok "$name"
    else
        sed 's/^/    serve: /' "$SANDBOX/serve.log" | tail -20
        fail "$name"
    fi
}
cli() { # betty-chess against a scratch store
    local dir="$1"
    shift
    DESKCRAB_CHESS_DIR="$dir" "$VENV_PY" -B "$REPO/lib/chess_cli.py" "$@"
}

FOOLS="f2f3 e7e5 g2g4 d8h4"

echo "the named player and the table chat, end to end:"
CH="$SANDBOX/chess-chat"
"$VENV_PY" -B "$SCENARIO" seed "$CH" guest-000 guest black $FOOLS
cli "$CH" label guest-000 Visitor >/dev/null || fail "label guest-000 failed"
WAKELOG="$SANDBOX/wake-chat.log"
CHATLOG="$SANDBOX/chat-chat.log"
if start_bridge "$CH" "$WAKELOG" "$CHATLOG" "$CHAT_REPLIES" -- --opponent guest; then
    scn chat "$PORT" "$CH" "$WAKELOG" "$CHATLOG" "$SANDBOX/mover.log"
fi
stop_bridge

echo "a PASS is silence, and an unlabeled game is honestly unnamed:"
CH2="$SANDBOX/chess-pass"
EMPTY_REPLIES="$SANDBOX/chat-replies-empty.tsv"
: > "$EMPTY_REPLIES"
CHATLOG2="$SANDBOX/chat-pass.log"
if start_bridge "$CH2" "$SANDBOX/wake-pass.log" "$CHATLOG2" "$EMPTY_REPLIES" \
        -- --opponent guest; then
    scn chat_pass "$PORT" "$CH2" "$CHATLOG2"
fi
stop_bridge

echo "chat off, legacy record: messages still land, no model call is made:"
CH3="$SANDBOX/chess-off"
"$VENV_PY" -B "$SCENARIO" seed "$CH3" guest-001 guest black e2e4 e7e5
CHATLOG3="$SANDBOX/chat-off.log"
if start_bridge "$CH3" "$SANDBOX/wake-off.log" "$CHATLOG3" "$CHAT_REPLIES" \
        DESKCRAB_CHESS_CHAT=0 -- --opponent guest; then
    scn chat_off "$PORT" "$CH3" "$CHATLOG3"
fi
stop_bridge

echo "no game yet: /chat answers empty and refuses a post:"
CH4="$SANDBOX/chess-nogame"
if start_bridge "$CH4" "$SANDBOX/wake-ng.log" "$SANDBOX/chat-ng.log" \
        "$EMPTY_REPLIES" -- --opponent guest; then
    scn chat_nogame "$PORT"
fi
stop_bridge

echo "GET /record: the counted per-player tally over mated games:"
CH5="$SANDBOX/chess-record"
"$VENV_PY" -B "$SCENARIO" seed "$CH5" guest-000 guest black $FOOLS
"$VENV_PY" -B "$SCENARIO" seed "$CH5" fools-001 fools white $FOOLS
cli "$CH5" label guest-000 Visitor >/dev/null || fail "label failed"
if start_bridge "$CH5" "$SANDBOX/wake-rec.log" "$SANDBOX/chat-rec.log" \
        "$EMPTY_REPLIES" -- --opponent guest; then
    scn record_http "$PORT" "$CH5"
fi
stop_bridge

echo "the CLI half: new --player, list labels, record counts from disk:"
CH6="$SANDBOX/chess-cli"
"$VENV_PY" -B "$SCENARIO" seed "$CH6" guest-000 guest black $FOOLS
"$VENV_PY" -B "$SCENARIO" seed "$CH6" fools-001 fools white $FOOLS
cli "$CH6" label guest-000 Visitor >/dev/null \
    && ok "betty-chess label writes the sitter by hand" \
    || fail "betty-chess label failed"
grep -q '"player": "Visitor"' "$CH6/games/guest-000.json" \
    && ok "the label landed on the record" \
    || fail "no player field on guest-000 after label"

OUT="$(cli "$CH6" new somebody --player 'The Visitor' --as white 2>&1)" \
    || fail "new --player failed: $OUT"
grep -q '"player": "The Visitor"' "$CH6/games/somebody-001.json" \
    && ok "new --player stamps the sitter at creation" \
    || fail "no player field from new --player"

LIST="$(cli "$CH6" list)"
# guest-000: her side black, so the sitter is white — "Visitor v you".
printf '%s\n' "$LIST" | grep -q 'Visitor v you' \
    && ok "list shows the game by its player, not the chair" \
    || { printf '    list: %s\n' "$LIST"; fail "list does not label guest-000 by player"; }
printf '%s\n' "$LIST" | grep -q 'you v The Visitor' \
    && ok "and the freshly dealt game by its typed name" \
    || { printf '    list: %s\n' "$LIST"; fail "list does not label somebody-001"; }

REC="$(cli "$CH6" record)"
printf '%s\n' "$REC" | grep -q 'Visitor.*1 game(s): you 1-0-0' \
    && ok "record counts her mate as a WIN (the naive-tally trap)" \
    || { printf '    record: %s\n' "$REC"; fail "the Visitor line is wrong"; }
printf '%s\n' "$REC" | grep -q 'fools (unlabeled).*you 0-0-1' \
    && ok "the unlabeled pile is its own visible line, a loss counted" \
    || { printf '    record: %s\n' "$REC"; fail "the unlabeled line is wrong"; }

RECJ="$(cli "$CH6" record --json)"
printf '%s\n' "$RECJ" | "$VENV_PY" -B -c '
import json, sys
rows = json.load(sys.stdin)
by = {r["player"]: r for r in rows}
assert by["Visitor"]["wins"] == 1 and by["Visitor"]["labeled"], rows
assert by["fools"]["losses"] == 1 and not by["fools"]["labeled"], rows
' && ok "record --json is the same tally GET /record serves" \
  || fail "record --json broke"

REC1="$(cli "$CH6" record visitor)"
printf '%s\n' "$REC1" | grep -q 'Visitor' \
    && ok "record <name> filters to one player, slug-folded" \
    || fail "record visitor found nothing"
cli "$CH6" record nobody-here >/dev/null 2>&1 \
    && fail "record for an unknown player should refuse" \
    || ok "record for an unknown player refuses out loud"
