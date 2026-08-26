#!/bin/bash
# Her whole voice at the table, the move exactly the move
# (specs/chessweb.md rule 24d, the "minimal in machinery, never in voice"
# sentence).
#
# The table chat first shipped wearing the MOVER's persona file — a sheet cut
# down for choosing a move in silence, ending "no narration" — and the
# conversation came out sounding like nobody (user report, 2026-08-26). The
# chat call must carry the whole conversational persona sheet instead, while
# the mover keeps its own terse sheet and its reply stays exactly the move.
# Proven here, in process against the real modules:
#   - with a persona sheet on $CUSTOM_PROMPT, the chat system prompt carries
#     the sheet, NOT the mover's chess persona, and still ends with the
#     boundary tail (not authenticated, PASS)
#   - the sheet rides the real argv: --system-prompt on the Claude spelling
#     (still disarmed, --tools ""), the instructions file on the codex
#     spelling (still --sandbox read-only)
#   - $DESKCRAB_CHESS_CHAT_PERSONA outranks $CUSTOM_PROMPT; an unexpanded
#     $HOME or ~ in either value expands (systemd hands the conf value raw)
#   - the fallbacks: no sheet -> the mover's chess persona; an unreadable,
#     empty or over-65536-byte sheet is absent; nothing at all -> the
#     boundary tail alone
#   - the mover is untouched: its system prompt keeps its own sheet, never
#     the conversational one, and still demands UCI and nothing else
# Run: bash tests/test_chess_chat_persona.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"

# Read-only use of a live path: an interpreter, not state — the same bargain
# tests/test_chess_chat.sh strikes. -B keeps it read-only in fact.
VENV_PY="$SANDBOX_LIVE_DATA/chess/venv/bin/python"
[ -x "$VENV_PY" ] || sandbox_skip "the betty-chess venv is not built (run betty-chess once)"
"$VENV_PY" -B -c 'import chess' 2>/dev/null \
    || sandbox_skip "python-chess is missing from the betty-chess venv"
export PYTHONDONTWRITEBYTECODE=1

# The sheets. Generic on purpose: the real persona sheet is the user's and
# never in this repo — sentinels are what the assertions read.
SHEET_FULL="$SANDBOX/full-sheet.md"
cat > "$SHEET_FULL" <<'MD'
## Persona

You are the assistant, four centuries proud, and you speak with your whole
conversational voice in every register. FULL-SHEET-VOICE.
MD
SHEET_OVERRIDE="$SANDBOX/override-sheet.md"
printf 'OVERRIDE-SHEET-VOICE: the chat-only sheet.\n' > "$SHEET_OVERRIDE"
SHEET_CHESS="$SANDBOX/chess-persona.md"
cat > "$SHEET_CHESS" <<'MD'
MOVER-CHESS-SHEET: play principled chess. No narration — the board is where
you speak here.
MD
SHEET_BIG="$SANDBOX/big-sheet.md"
{ printf 'TOO-BIG-SHEET '; head -c 70000 /dev/zero | tr '\0' 'x'; } > "$SHEET_BIG"
cp "$SHEET_FULL" "$HOME/home-sheet.md"

py() { # <desc> [env k=v...] -- <python body on stdin>
    local desc="$1"
    shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        envs+=("$1")
        shift
    done
    if env ${envs[@]+"${envs[@]}"} "$VENV_PY" -B - "$REPO/lib" 2> "$SANDBOX/py-err"; then
        ok "$desc"
    else
        sed 's/^/    py: /' "$SANDBOX/py-err"
        fail "$desc"
    fi
}

echo "the chat wears the whole sheet, the mover keeps its own:"
py "the conversational persona sheet, not the chess one, and the tail intact" \
    CUSTOM_PROMPT="$SHEET_FULL" CHESS_PERSONA_FILE="$SHEET_CHESS" -- <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import chess_chat, chess_mover

sp = chess_chat.system_prompt()
assert "FULL-SHEET-VOICE" in sp, sp[:300]
assert "MOVER-CHESS-SHEET" not in sp, sp[:300]
assert "No narration" not in sp, sp[:300]
# The boundary tail is untouched and still closes the prompt.
assert "not authenticated" in sp and sp.rstrip().endswith("or PASS."), sp[-300:]

# The mover is untouched: its own sheet, never the conversational one, and
# the reply is still exactly the move.
mp = chess_mover.SYSTEM_PROMPT
assert "MOVER-CHESS-SHEET" in mp, mp[:300]
assert "FULL-SHEET-VOICE" not in mp, mp[:300]
assert "UCI notation" in mp and "nothing else" in mp, mp
PY

py "the sheet rides both argv spellings, still disarmed" \
    CUSTOM_PROMPT="$SHEET_FULL" CHESS_PERSONA_FILE="$SHEET_CHESS" -- <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import chess_chat

cmd = chess_chat.ChessChat._claude_cmd("sonnet", "low")
sp = cmd[cmd.index("--system-prompt") + 1]
assert "FULL-SHEET-VOICE" in sp, sp[:300]
assert cmd[cmd.index("--tools") + 1] == "", cmd

cmd = chess_chat.ChessChat._codex_cmd("sol", "low")
assert not any("dangerously-bypass" in a for a in cmd), cmd
assert cmd[cmd.index("--sandbox") + 1] == "read-only", cmd
instr = next(a.split("=", 1)[1] for a in cmd
             if a.startswith("model_instructions_file="))
text = open(instr).read()
assert "FULL-SHEET-VOICE" in text, text[:300]
assert "not authenticated" in text, text[:300]
PY

echo "the knobs: the chat-only override, and the raw conf value expanding:"
py "DESKCRAB_CHESS_CHAT_PERSONA outranks CUSTOM_PROMPT" \
    DESKCRAB_CHESS_CHAT_PERSONA="$SHEET_OVERRIDE" CUSTOM_PROMPT="$SHEET_FULL" \
    CHESS_PERSONA_FILE="$SHEET_CHESS" -- <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import chess_chat
sp = chess_chat.system_prompt()
assert "OVERRIDE-SHEET-VOICE" in sp, sp[:300]
assert "FULL-SHEET-VOICE" not in sp, sp[:300]
PY

py 'an unexpanded $HOME and a ~ both reach the sheet' \
    CUSTOM_PROMPT='$HOME/home-sheet.md' CHESS_PERSONA_FILE="$SHEET_CHESS" -- <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import chess_chat
assert "FULL-SHEET-VOICE" in chess_chat.system_prompt()
os.environ["CUSTOM_PROMPT"] = "~/home-sheet.md"
assert "FULL-SHEET-VOICE" in chess_chat.system_prompt()
PY

echo "the fallbacks: absent, unreadable, empty, oversized:"
py "no sheet falls back to the mover's chess persona" \
    CHESS_PERSONA_FILE="$SHEET_CHESS" -- <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import chess_chat
os.environ.pop("CUSTOM_PROMPT", None)
os.environ.pop("DESKCRAB_CHESS_CHAT_PERSONA", None)
sp = chess_chat.system_prompt()
assert "MOVER-CHESS-SHEET" in sp, sp[:300]
assert "not authenticated" in sp
PY

py "an unreadable, empty or over-65536-byte sheet is treated as absent" \
    CHESS_PERSONA_FILE="$SHEET_CHESS" SHEET_BIG="$SHEET_BIG" -- <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import chess_chat
for bad in (os.environ["HOME"] + "/no-such-sheet.md",
            "/dev/null",
            os.environ["SHEET_BIG"]):
    os.environ["CUSTOM_PROMPT"] = bad
    sp = chess_chat.system_prompt()
    assert "MOVER-CHESS-SHEET" in sp, (bad, sp[:300])
    assert "TOO-BIG-SHEET" not in sp, bad
PY

py "with nothing at all, the boundary tail alone" \
    CHESS_PERSONA_FILE="$SANDBOX/no-such-persona.md" -- <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import chess_chat
os.environ.pop("CUSTOM_PROMPT", None)
sp = chess_chat.system_prompt()
assert sp == chess_chat.SYSTEM_PROMPT_TAIL, sp[:300]
PY
