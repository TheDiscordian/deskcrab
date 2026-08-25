#!/bin/bash
# The promise checker's two newest artefact sources — the chess game record,
# and the path-shaped claim resolved against the obvious roots.
# specs/turn-pipeline.md rule 32b, wake-queue.md rule 43b. From the
# engineering record: eight flags of this family fired between 2026-08-15 and
# 2026-08-25 and every one was false. A claim about a chess game's board
# state owes truth, not work — its witness is the game's own move list, never
# the announcing turn's tool stream, which is empty by construction when the
# mover played the move. And a bare relative path in prose is resolved
# against the turn's roots and statted before anyone is accused. Neither
# source may loosen the checker: a move absent from every move list and a
# path nowhere fresh on disk still flag exactly as before.
# Run: bash tests/test_promise_check_game_artefact.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib"

# The checker, copied (not linked — it resolves SCRIPT_DIR through its own
# path and would walk back to the real repo and its real crab), beside a door
# onto the real wake module. Same fixture as test_promise_check.sh.
cp "$REPO/lib/promise-check" "$T/repo/lib/promise-check"
chmod +x "$T/repo/lib/promise-check"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/wake-queue.sh" "$T/repo/lib/wake-queue.sh"
ln -sf "$REPO/lib/extract-response" "$T/repo/lib/extract-response"

cat > "$T/repo/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
[ "\${1:-}" = "wake-at" ] || exit 0
shift
source "$REPO/lib/common.sh" >/dev/null 2>&1
wake_book "\$@"
CRAB
chmod +x "$T/repo/crab"

# PROJECT_DIR is the turn's own workdir — the root a bare relative path in
# prose resolves against (the stand-in for the user's records directory).
HOUSE="$T/home/house"
mkdir -p "$HOUSE/Library"
cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$HOUSE"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
MEMORY_STORE=0
PROMISE_CHECK=1
CONF

export WAKES_DIR="$W"
export PROMISE_LEDGER="$T/ledger.jsonl"
# The game records live in an isolated fixture root — never the live dir.
export DESKCRAB_CHESS_DIR="$T/chess"
GAMES="$T/chess/games"
mkdir -p "$GAMES"

CHECK_LOG="$DESKCRAB_STATE_PREFIX-promise-check.log"
records()  { ls "$W"/*.wake 2>/dev/null | wc -l; }
ledger_n() { sandbox_count_in . "$T/ledger.jsonl"; }
claude_n() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
reset()    { rm -f "$W"/*.wake "$W/ledger.log" "$T/wake-calls" "$T/ledger.jsonl" \
                   "$CHECK_LOG" "$SANDBOX_CLAUDE_LOG" "$T/model-stdin" \
                   "$GAMES"/*.json "$HOUSE/Library"/*.md; }

# A stream log with no tool calls at all: the announcing turn's own record is
# empty by construction — exactly the shape every false flag fired on.
SNAP_EMPTY="$T/snap-empty.jsonl"
cat > "$SNAP_EMPTY" <<'EOF'
{"type":"assistant","message":{"model":"real","content":[{"type":"text","text":"a reply whose turn ran no tools"}]}}
{"type":"result","result":"done"}
EOF
snap() { cp "$SNAP_EMPTY" "$T/snap-live.jsonl"; printf '%s' "$T/snap-live.jsonl"; }

# One fixture game on disk: id, her side, updated stamp, then the UCI moves.
mkgame() {
    local id="$1" side="$2" upd="$3"; shift 3
    python3 - "$GAMES/$id.json" "$id" "$side" "$upd" "$@" <<'PY'
import json, sys, time
path, gid, side, upd = sys.argv[1:5]
stamp = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(int(upd)))
with open(path, "w", encoding="utf-8") as f:
    json.dump({"id": gid, "opponent": "browser", "my_side": side,
               "moves": list(sys.argv[5:]), "resigned_by": None,
               "created": stamp, "updated": stamp}, f)
PY
}

# The judge stub is POISON on purpose: if the checker consults the model for
# a claim the artefact already backs, the stub convicts, and the ledger and
# wake assertions below then catch the false flag exactly as the live nights
# did.
poison() {
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"UNKEPT: \"whatever was claimed\" | the turn record shows nothing"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
}

NOW="$(date +%s)"

echo "browser-011's shape: an announced turn the mover embodied a minute later is game-backed:"
reset; poison
mkgame browser-011 white $(( NOW - 60 )) e2e4 e7e5 g1f3
"$T/repo/lib/promise-check" turn phone $(( NOW - 120 )) 5011 "$(snap)" \
    "$T/ledger.jsonl" "It's my move — so I'll take my turn there." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "the trace names the game as the witness" \
    grep -q "backed: the game record browser-011" "$CHECK_LOG"

echo
echo "browser-026's shape: counted captures the move list holds — bishop and knight:"
reset; poison
mkgame browser-026 black $(( NOW - 600 )) \
    e2e3 d7d5 f1e2 d8d6 b1c3 g8f6 c3b5 d6e6 a2a3 e6e2 a3a4 e2b5
"$T/repo/lib/promise-check" turn wake "$NOW" 5026 "$(snap)" \
    "$T/ledger.jsonl" "I've taken a bishop and a knight off him in the last few moves." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "the trace names the game" grep -q "backed: the game record browser-026" "$CHECK_LOG"

echo
echo "browser-034's shape: board-state talk beside a game her side just moved in:"
reset; poison
mkgame browser-034 black $(( NOW - 60 )) e2e3 d7d5
"$T/repo/lib/promise-check" turn wake "$NOW" 5034 "$(snap)" \
    "$T/ledger.jsonl" "I've met it head-on in the centre." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "the trace names the game" grep -q "backed: the game record browser-034" "$CHECK_LOG"

echo
echo "a bare relative path in prose, fresh on disk under the workdir, is its own witness:"
reset; poison
printf '## the post-mortem\nthirty lines of write-up\n' > "$HOUSE/Library/chess-notes.md"
touch -d "@$(( NOW - 60 ))" "$HOUSE/Library/chess-notes.md"
"$T/repo/lib/promise-check" turn phone "$NOW" 5018 "$(snap)" \
    "$T/ledger.jsonl" "I've written the post-mortem up in \`Library/chess-notes.md\`." >/dev/null 2>&1
check_eq "the model was never called" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "the trace names the resolved artefact" \
    grep -qF "backed: the artefact $HOUSE/Library/chess-notes.md" "$CHECK_LOG"

echo
echo "a claimed move that is NOT in the move list still flags — no new blindness:"
reset; poison
mkgame browser-034 black $(( NOW - 60 )) e2e3 d7d5
"$T/repo/lib/promise-check" turn wake "$NOW" 5035 "$(snap)" \
    "$T/ledger.jsonl" "I've played Qh5 to pin his knight." >/dev/null 2>&1
check_eq "the model WAS consulted" "$(claude_n)" "1"
check_eq "and the flag lands: one ledger line, one wake" "$(ledger_n)$(records)" "11"
check "the judge was handed the game records as labelled evidence" \
    grep -q "THE GAME RECORDS" "$T/model-stdin"
check "carrying the move list itself" grep -q "1. e3 d5" "$T/model-stdin"

echo
echo "a claimed path nowhere on disk still flags:"
reset; poison
"$T/repo/lib/promise-check" turn phone "$NOW" 5019 "$(snap)" \
    "$T/ledger.jsonl" "I've written the frost post-mortem up in \`Library/frost-notes.md\`." >/dev/null 2>&1
check_eq "the model WAS consulted" "$(claude_n)" "1"
check_eq "and the flag lands: one ledger line, one wake" "$(ledger_n)$(records)" "11"

echo
echo "a named file HOURS older than the claim is judge evidence, never a short-circuit:"
reset; poison
printf 'old notes\n' > "$HOUSE/Library/chess-notes.md"
touch -d "@$(( NOW - 7200 ))" "$HOUSE/Library/chess-notes.md"
"$T/repo/lib/promise-check" turn phone "$NOW" 5020 "$(snap)" \
    "$T/ledger.jsonl" "I've written tonight's post-mortem up in \`Library/chess-notes.md\`." >/dev/null 2>&1
check_eq "the model WAS consulted — the mtime sits hours before the claim" "$(claude_n)" "1"
check_eq "and the stub's conviction lands" "$(ledger_n)$(records)" "11"

echo
echo "a reply that ALSO promises other work is still judged in full:"
reset; poison
mkgame browser-026 black $(( NOW - 600 )) \
    e2e3 d7d5 f1e2 d8d6 b1c3 g8f6 c3b5 d6e6 a2a3 e6e2 a3a4 e2b5
"$T/repo/lib/promise-check" turn wake "$NOW" 5027 "$(snap)" \
    "$T/ledger.jsonl" "I've taken a bishop and a knight off him. And I'll restart the phone server now." >/dev/null 2>&1
check_eq "the game record did not silence the judge — the model ran" "$(claude_n)" "1"
check_eq "and the unfulfilled half was still caught" "$(ledger_n)$(records)" "11"

echo
echo "an unreadable game degrades to today's judgement — never a crash, never an acquittal:"
reset; poison
printf 'not json at all' > "$GAMES/browser-099.json"
"$T/repo/lib/promise-check" turn wake "$NOW" 5099 "$(snap)" \
    "$T/ledger.jsonl" "I've met it head-on in the centre." >/dev/null 2>&1
check_eq "the model WAS consulted — no readable game backs the claim" "$(claude_n)" "1"
check_eq "and the flag lands exactly as before" "$(ledger_n)$(records)" "11"
