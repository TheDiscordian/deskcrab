#!/bin/bash
# The mirror-rewrite echo double — specs/speech-output.md rule 41a.
# Run: bash tests/test_mirror_echo.sh
#
# 2026-09-03 15:01:20, one streamer pid, the same second: the draft was
# 'Noted. Reading the clock instead of guessing.', the promising-family
# pattern held 'Noted.', and the mirror's rewrite came back as EXACTLY the
# draft's own next sentence — which was already chunked and queued behind the
# held slot. The gate spoke the rewrite and the draft's own copy spoke right
# after it: one flag row of outcome rewrite, two identical SAID lines, and
# the journal's reply doubled to match, because the caller's splice put the
# rewrite where 'Noted.' stood while the copy she wrote stayed put. The rule
# 12a supersede never saw it — it judges completed BLOCKS, and the second
# copy is a sibling CHUNK of the same block, queued before the verdict lands.
#
# So this file drives the RECORDED shape through the REAL caller path — a
# stub CLI under claude_generate, the armed streamer tailing the same stream
# log, claudism_mirror_desk answering the fire — and counts utterances at a
# stub synthesiser, from outside the pipeline. The rule 12a supersede is
# stood down in a harness-private COPY of the library so the count is the
# queue's own and the corpus fix of 7793aff cannot mask the double; a control
# case proves the stand-down took. near_duplicate itself stays real — the
# echo test under trial is built on it.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# --- a private copy of lib/ with ONLY the block supersede stood down --------
CP="$T/librepo"
mkdir -p "$CP"
cp -r "$REPO_DIR/lib" "$CP/lib"
rm -rf "$CP/lib/__pycache__"
cat >> "$CP/lib/sentence_stream.py" <<'EOF'

# HARNESS ONLY (tests/test_mirror_echo.sh): the rule 12a block supersede is
# stood down by emptying its corpus before every close, so a doubled queue
# cannot be masked downstream. near_duplicate itself stays real.
_HARNESS_ORIG_CLOSE_TEXT = BlockRegistry.close_text
def _harness_close_text(self, mid, idx, text):
    with self.voiced_lock:
        del self.voiced_texts[:]
    return _HARNESS_ORIG_CLOSE_TEXT(self, mid, idx, text)
BlockRegistry.close_text = _harness_close_text
EOF

# --- stub voice: counts each utterance handed to piper, from outside --------
sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [ -n "$line" ]; do
    printf 'SAY\t%s\n' "$line" >> "$TRACE"
    head -c 2048 /dev/zero
done
EOF

# Her phrase list: the clipped acknowledgement, the incident's own trigger
# shape. The rewrite sentence matches nothing here.
LIST="$T/claudisms.md"
cat > "$LIST" <<'EOF'
- `^\s*noted[.!]?\s*$` — the clipped acknowledgement announcing the move instead of making it.
EOF

# --- the CLI stub: the turn streams the draft; the mirror call answers ------
# A turn run carries --include-partial-messages and its prompt in argv; the
# mirror call is a classify-shaped run whose stdin carries the flagged line
# and the whole draft. The echo case answers with the draft's own next
# sentence — the recorded 2026-09-03 mirror behaviour; the fresh case with a
# sentence the draft does not carry.
sandbox_stub claude <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SANDBOX_CLAUDE_LOG:-/dev/null}"
case "$*" in
    *--include-partial-messages*)
        case "$*" in
            *fresh-case*) DRAFT='Noted. The lamp is dark tonight.' ;;
            *)            DRAFT='Noted. Reading the clock instead of guessing.' ;;
        esac
        printf '%s\n' '{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_A"}}}'
        printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
        python3 -c 'import json,sys; print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":sys.argv[1]}}}))' "$DRAFT"
        python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "$DRAFT"
        python3 -c 'import json,sys; print(json.dumps({"type":"result","result":sys.argv[1]}))' "$DRAFT"
        ;;
    *)
        IN="$(cat)"
        case "$IN" in
            *"The lamp is dark tonight."*) REPLY='I heard you.' ;;
            *) REPLY='Reading the clock instead of guessing.' ;;
        esac
        printf '{"type":"assistant","message":{"model":"m","content":[{"type":"text","text":"%s"}]}}\n' "$REPLY"
        printf '{"type":"result","result":"%s"}\n' "$REPLY"
        ;;
esac
exit 0
EOF

# --- the real caller path, end to end ---------------------------------------
run_turn() { # <name> <prompt> — leaves $T/<name>.{trace,speechlog,final,fires}
    local NAME="$1" PROMPT="$2"
    TRACE="$T/$NAME.trace"; : > "$TRACE"
    SPEECHLOG="$T/$NAME.speechlog"; : > "$SPEECHLOG"
    rm -f "$T/$NAME.fires"
    TRACE="$TRACE" SPEECH_LOG="$SPEECHLOG" CLAUDISMS_FILE="$LIST" \
        DESKCRAB_NO_DISPATCH=1 bash -c '
        source "$1/lib/common.sh" >/dev/null 2>&1
        SESSION_KIND="desktop turn"
        _CLAUDISM_ARM=1
        start_tts_streamer 2>/dev/null
        RESPONSE="$(claude_generate "$2")"
        RESPONSE="$(claudism_mirror_desk "$RESPONSE")"
        wait_tts_streamer
        cp -f "$_CLAUDISM_FIRES_FILE" "$3" 2>/dev/null
        printf "%s" "$RESPONSE"' _ "$CP" "$PROMPT" "$T/$NAME.fires" \
        > "$T/$NAME.final" 2>"$T/$NAME.err"
}

said_count() { sandbox_count_in "SAY	$1" "$TRACE"; }
final_count() { # <name> <sentence> — occurrences in the committed reply
    python3 -c 'import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))' \
        "$T/$1.final" "$2" 2>/dev/null
}
WDAY="$SANDBOX/data/deskcrab/claudism-flags/$(date +%F).jsonl"

echo "the recorded shape: a rewrite that echoes the draft's own next sentence:"

run_turn echo "echo-case: that is too many words"
TRACE="$T/echo.trace"
check_eq "the rewrite reached the synthesiser exactly once (two on 2026-09-03)" \
    "$(said_count 'Reading the clock instead of guessing.')" "1"
check_eq "the held draft sentence itself never sounded" \
    "$(said_count 'Noted.')" "0"
check_eq "the committed reply carries the words exactly once (the journal doubled on 2026-09-03)" \
    "$(final_count echo 'Reading the clock instead of guessing.')" "1"
check_eq "and not the held sentence" "$(final_count echo 'Noted.')" "0"
check_eq "one fire, exactly, reached the fires file" \
    "$(sandbox_count_in '"pattern"' "$T/echo.fires")" "1"
check_eq "and its outcome says the held slot was absorbed (rule 41a)" \
    "$(sandbox_count_in 'rewrite-absorbed' "$T/echo.fires")" "1"
check_eq "one rewrite row, exactly, in the day's flag log" \
    "$(sandbox_count_in '"outcome": "rewrite"' "$WDAY")" "1"

echo
echo "a fresh rewrite still speaks in the held slot (rule 41 unchanged):"

run_turn fresh "fresh-case: status please"
TRACE="$T/fresh.trace"
check_eq "the fresh rewrite sounded, once, in the held sentence's place" \
    "$(said_count 'I heard you.')" "1"
check_eq "the sentence after it kept its own voice" \
    "$(said_count 'The lamp is dark tonight.')" "1"
check_eq "the held draft sentence never sounded" "$(said_count 'Noted.')" "0"
check_eq "the committed reply carries the rewrite once" \
    "$(final_count fresh 'I heard you.')" "1"
check_eq "and the neighbour once" \
    "$(final_count fresh 'The lamp is dark tonight.')" "1"
check_eq "that fire's outcome says the rewrite was spoken" \
    "$(sandbox_count_in 'rewrite-spoken' "$T/fresh.fires")" "1"

echo
echo "the stand-down took: a block-level duplicate sounds twice in this harness:"
# The same rewrite delivered for a held draft, then the rewrite's text again
# as its own completed block — the shape the corpus fix of 7793aff suppresses
# in the shipped library. Here it MUST sound twice, or every count above was
# the suppressor's work and this file proves nothing about the queue.
LOG="$T/control.log"; TRACE="$T/control.trace"; FIRES="$T/control-fires.jsonl"
SPEECHLOG="$T/control.speechlog"
: > "$LOG"; : > "$TRACE"; : > "$SPEECHLOG"; rm -f "$FIRES" "$FIRES".verdict-* "$FIRES.done"
TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
    DESKCRAB_SPEECHLOCK="$T/control.speechlock" \
    DESKCRAB_SPEECH_LOG="$SPEECHLOG" DESKCRAB_SPEECH_RECEIPT="$T/control.receipt" \
    DESKCRAB_VOICE_IDLE_CLOSE=30 \
    DESKCRAB_CLAUDISMS="$LIST" DESKCRAB_CLAUDISM_FIRES="$FIRES" \
    DESKCRAB_CLAUDISM_MIRROR_TIMEOUT=20 \
    "$CP/lib/tts-streamer" 2>/dev/null &
SPID=$!
sleep 0.2
j() { printf '%s\n' "$1" >> "$LOG"; }
j '{"type":"assistant","message":{"model":"m","id":"msg_N","content":[{"type":"text","text":"Noted. "}]}}'
j '{"type":"user","message":{"content":[{"type":"text","text":"a tool result moved the stream on"}]}}'
for _ in $(seq 100); do
    [ "$(sandbox_count_in '"pattern"' "$FIRES")" -ge 1 ] && break
    sleep 0.1
done
printf '{"action":"rewrite","text":"Reading the clock instead of guessing."}\n' > "$FIRES.vtmp"
mv -f "$FIRES.vtmp" "$FIRES.verdict-1"
for _ in $(seq 100); do
    grep -qF "SAID: Reading the clock" "$SPEECHLOG" 2>/dev/null && break
    sleep 0.1
done
j '{"type":"assistant","message":{"model":"m","id":"msg_R","content":[{"type":"text","text":"Reading the clock instead of guessing."}]}}'
j '{"type":"result","result":"x"}'
for _ in $(seq 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
kill -9 "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
check_eq "with the supersede stood down, the later identical BLOCK sounds too (2 utterances)" \
    "$(said_count 'Reading the clock instead of guessing.')" "2"

echo
echo "the whole-draft pass folds an echoing rewrite as a deletion (rules 41a/44):"
D="$T/directdata"; mkdir -p "$D"
cp "$LIST" "$D/claudisms.md"
OUT="$(CLAUDISMS_FILE="$D/claudisms.md" sandbox_bash \
    'claudism_mirror_direct wake "Noted. Reading the clock instead of guessing."')"
check_eq "the delivered wake reply says the words exactly once" \
    "$(printf '%s' "$OUT" | grep -oF 'Reading the clock instead of guessing.' | wc -l)" "1"
refute() { local d="$1"; shift; if "$@"; then fail "$d"; else ok "$d"; fi; }
refute "and the held sentence is gone" contains "$OUT" "Noted."

echo
echo "the splice's echo guard is opt-in, so the table-swap fold is untouched:"
R='Reading the clock instead of guessing.'
OUT="$(python3 -c \
    'import json,sys; print(json.dumps({"response": sys.argv[1], "sentence": "Noted.", "rewrite": sys.argv[2]}))' \
    "Noted. $R" "$R" | "$REPO_DIR/lib/claudism-mirror" splice)"
check_eq "a guardless splice keeps its old byte-for-byte behaviour" \
    "$OUT" "$R $R"

echo
echo "the shared echo test itself:"
if python3 - "$REPO_DIR/lib" <<'PY'
import importlib.machinery, importlib.util, os, sys
lib = sys.argv[1]
sys.path.insert(0, lib)
loader = importlib.machinery.SourceFileLoader("cm", os.path.join(lib, "claudism-mirror"))
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("cm", loader))
loader.exec_module(m)
R = "Reading the clock instead of guessing."
# the recorded shape: the rewrite is the draft's own next sentence
assert m.echo_sentence(R, "Noted. " + R, "Noted.") == R
# a reworded near-copy is still the same substance
assert m.echo_sentence("Reading the clock instead of guessing tonight.",
                       "Noted. " + R, "Noted.") == R
# a quiet line never sounds, so it is no basis for absorbing
assert m.echo_sentence(R, "(quiet) " + R, "Noted.") is None
# the flagged sentence itself is the slot under repair, never an echo
assert m.echo_sentence("Noted.", "Noted.", "Noted.") is None
# a genuinely fresh rewrite matches nothing
assert m.echo_sentence("I heard you.", "Noted. The lamp is dark tonight.",
                       "Noted.") is None
# the guarded splice deletes; the unguarded one splices as ever
assert m.splice("Noted. " + R, "Noted.", R, True).strip() == R
assert m.splice("Noted. " + R, "Noted.", R) == R + " " + R
# an echo in the display half never absorbs — that half never sounds
kept = m.splice("Noted. All is well.\n---DISPLAY---\n" + R, "Noted.", R, True)
assert kept.startswith(R), kept
PY
then ok "echo_sentence and the guarded splice hold every boundary above"
else fail "the shared echo test broke" "see the python traceback above"
fi
