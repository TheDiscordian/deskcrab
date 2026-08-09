#!/bin/bash
# Her replacement table — specs/speech-output.md rules 47-49. The fast path
# of the pre-speech mirror: an entry in the phrase list may carry replace
# lines, and a fired sentence those lines fully repair is spoken repaired
# with NO hold and NO mirror call. Partial coverage holds and routes as
# ever; the repairs are only what deleting a span breaks; and a swap that
# cannot be logged is never applied.
# Run: bash tests/test_claudism_table.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# The fixture list, in the declared shape. Invented phrases: the live list is
# personal state and never enters this repository.
LIST="$T/claudisms.md"
cat > "$LIST" <<'EOF'
# What is borrowed, and what the table already settles

## the frank opener
- pattern: `\bfrank(?:ly)?\b`
- why: decoration on a plain statement.
- replace: `\b[Ff]rankly,\s+` -> ``
- replace: `,\s+frankly\b` -> ``

## the seal of candour
- pattern: `\bcandidly\b`
- why: same family, one word.
- replace: `\b[Cc]andidly\b` -> ``

## the long now
- pattern: `\bat this point in time\b`
- why: five words doing the work of one.
- replace: `\bat this point in time\b` -> `now`

## the padded agreement
- pattern: `\bcertainly correct\b`
- why: no replace line on purpose — only she can write this one.
EOF

# The library, imported the way the streamer imports it.
swap() {  # <sentence> -> repaired sentence, or HOLD, or CLEAN
python3 - "$REPO_DIR/lib/claudism-mirror" "$LIST" "$1" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
pats, _bad = m.load_patterns(sys.argv[2])
f = m.first_flag(sys.argv[3], pats)
if not f:
    print("CLEAN")
else:
    out = m.table_swap(sys.argv[3], f["rx"], f["replaces"])
    print("HOLD" if out is None else out)
PY
}

echo "the parser: replace lines belong to their entry and are never triggers:"

COUNTS="$(python3 - "$REPO_DIR/lib/claudism-mirror" "$LIST" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
pats, bad = m.load_patterns(sys.argv[2])
print("%d %d %s" % (len(pats), bad, ",".join(str(len(p[3])) for p in pats)))
PY
)"
check_eq "four entries, none broken, replaces where written" "$COUNTS" "4 0 2,1,1,0"
check_eq "and both copies of the parser agree" \
    "$(python3 - "$REPO_DIR" <<'PY'
import ast, os, sys
def body(path):
    src = open(path).read()
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, ast.FunctionDef) and node.name == "load_patterns":
            start = node.body[0].lineno - 1
            if (isinstance(node.body[0], ast.Expr)
                    and isinstance(node.body[0].value, ast.Constant)):
                start = node.body[1].lineno - 1
            return "\n".join(src.splitlines()[start:node.end_lineno])
a = body(os.path.join(sys.argv[1], "lib/claudism-capture"))
b = body(os.path.join(sys.argv[1], "lib/claudism-mirror"))
print("identical" if a and a == b else "drifted")
PY
)" "identical"

cat > "$T/liberal.md" <<'EOF'
- `plainly wrong` — the bulleted shape still reads.
- replace: `\b[Pp]lainly\s+` -> ``
EOF
LIBERAL="$(python3 - "$REPO_DIR/lib/claudism-mirror" "$T/liberal.md" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
pats, bad = m.load_patterns(sys.argv[2])
f = m.first_flag("That is plainly wrong.", pats)
out = m.table_swap("That is plainly wrong.", f["rx"], f["replaces"]) if f else None
print("%d %d %s" % (len(pats), bad, out))
PY
)"
check_eq "the liberal shape carries a table too, and the replace line is no trigger" \
    "$LIBERAL" "1 0 That is wrong."

cat > "$T/broken.md" <<'EOF'
## the frank opener
- pattern: `\bfrankly\b`
- replace: `[broken(` -> `x`
EOF
BROKEN="$(python3 - "$REPO_DIR/lib/claudism-mirror" "$T/broken.md" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("cm", sys.argv[1])
spec = importlib.util.spec_from_loader("cm", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
pats, bad = m.load_patterns(sys.argv[2])
f = m.first_flag("Frankly broken.", pats)
print("%d %d %s" % (len(pats), bad, "fires" if f else "silent"))
PY
)"
check_eq "a broken replace regex is counted and skipped; the entry still fires" \
    "$BROKEN" "1 1 fires"

echo
echo "the swap: full coverage repairs, partial coverage holds (rules 47-48):"

check_eq "a deleted opener restores the capital" \
    "$(swap 'Frankly, the fan is loud.')" "The fan is loud."
check_eq "a deleted tail needs no repair" \
    "$(swap 'The fan is loud, frankly.')" "The fan is loud."
check_eq "an orphaned leading comma is dropped" \
    "$(swap 'Candidly, that failed.')" "That failed."
check_eq "a doubled space is collapsed" \
    "$(swap 'It candidly  failed.')" "It failed."
check_eq "a replacement with text of hers lands as written" \
    "$(swap 'We are at this point in time ready.')" "We are now ready."
check_eq "the firing pattern outrunning the replaces holds" \
    "$(swap 'The plan is frank about costs.')" "HOLD"
check_eq "an entry with no replace lines holds" \
    "$(swap 'You are certainly correct.')" "HOLD"
check_eq "a clean sentence never reaches the table" \
    "$(swap 'Nothing here is borrowed.')" "CLEAN"

echo
echo "the streamer: a covered fire speaks repaired with no hold (rules 47, 49):"

sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [ -n "$line" ]; do
    printf 'SAY\t%s\n' "$line" >> "$TRACE"
    head -c 2048 /dev/zero
done
EOF

FLAGSDIR="$T/flags"
start_streamer() { # <name> <flags-dir>
    LOG="$T/$1.log"; TRACE="$T/$1.trace"; RECEIPT="$T/$1.receipt"
    SPEECHLOG="$T/$1.speechlog"; FIRES="$T/$1-fires.jsonl"
    : > "$LOG"; : > "$TRACE"; : > "$SPEECHLOG"
    rm -f "$RECEIPT" "$FIRES" "$FIRES".verdict-* "$FIRES.done"
    TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
        DESKCRAB_SPEECHLOCK="$T/$1.speechlock" \
        DESKCRAB_SPEECH_LOG="$SPEECHLOG" DESKCRAB_SPEECH_RECEIPT="$RECEIPT" \
        DESKCRAB_VOICE_IDLE_CLOSE=30 \
        DESKCRAB_CLAUDISMS="$LIST" DESKCRAB_CLAUDISM_FIRES="$FIRES" \
        DESKCRAB_CLAUDISM_FLAGS="$2" \
        DESKCRAB_CLAUDISM_MIRROR_TIMEOUT="${MIRROR_TIMEOUT:-20}" \
        "$REPO_DIR/lib/tts-streamer" 2>/dev/null &
    SPID=$!
    sleep 0.2
}
reap_streamer() { # waits, sets HUNG
    local i; HUNG=no
    for i in $(seq 150); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$SPID" 2>/dev/null; then HUNG=yes; kill -9 "$SPID" 2>/dev/null; fi
    wait "$SPID" 2>/dev/null
}
said_count() { grep -cF "SAY	$1" "$TRACE"; }

j() { printf '%s\n' "$1" >> "$LOG"; }
MSTART='{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_A"}}}'
TBLOCK='{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
RESULT='{"type":"result","result":"x"}'
delta() { printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}}}' "$1"; }

SWAP_FULL='The first sentence is clean. Frankly, the beacon is green. The last sentence follows.'
SWAP_CLOSED=$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "$SWAP_FULL")

start_streamer tswap "$FLAGSDIR"
j "$MSTART"; j "$TBLOCK"
j "$(delta 'The first sentence is clean. ')"; sleep 0.3
j "$(delta 'Frankly, the beacon is green. ')"; sleep 0.3
j "$(delta 'The last sentence follows.')"
j "$SWAP_CLOSED"; j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "the streamer exits with no verdict ever written — nothing held" \
    || fail "the streamer held a covered fire" "$(cat "$FIRES" 2>/dev/null)"
check_eq "the repaired sentence is what was spoken" \
    "$(said_count 'The beacon is green.')" "1"
check_eq "the original never reached the synthesiser" \
    "$(said_count 'Frankly, the beacon is green.')" "0"
check_eq "the sentence behind the swap was not delayed away" \
    "$(said_count 'The last sentence follows.')" "1"
check "the fire record carries the before text" \
    contains "$(cat "$FIRES")" '"before": " Frankly, the beacon is green."'
check "and the after text" contains "$(cat "$FIRES")" '"after": " The beacon is green."'
check "and the outcome says table-swap" contains "$(cat "$FIRES")" '"outcome": "table-swap"'
DAYFILE="$FLAGSDIR/$(date +%F).jsonl"
check "the day's flag log has the swap" [ -s "$DAYFILE" ]
check "with the before text" contains "$(cat "$DAYFILE")" '"before": " Frankly, the beacon is green."'
check "the after text" contains "$(cat "$DAYFILE")" '"after": " The beacon is green."'
check "the entry that did it" contains "$(cat "$DAYFILE")" '"note": "the frank opener"'
check "and the same outcome" contains "$(cat "$DAYFILE")" '"outcome": "table-swap"'

echo
echo "a swap that cannot be logged is not applied — the fire holds (rule 49):"

: > "$T/notadir"   # a file where the flags directory should be: no log can land
MIRROR_TIMEOUT=1 start_streamer tunlogged "$T/notadir"
j "$MSTART"; j "$TBLOCK"
j "$(delta 'Frankly, the beacon is green. ')"
j "$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "Frankly, the beacon is green.")"
j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "the streamer exits (held, then failed open)" || fail "streamer hung" ""
check_eq "the repaired words were never spoken" "$(said_count 'The beacon is green.')" "0"
check_eq "the original spoke after the hold failed open" \
    "$(said_count 'Frankly, the beacon is green.')" "1"
check "the hold's outcome is failopen" contains "$(cat "$FIRES")" '"outcome": "failopen"'
refute "and no table-swap outcome was recorded" contains "$(cat "$FIRES")" '"outcome": "table-swap"'

echo
echo "partial coverage holds and routes exactly as before (rule 48):"

MIRROR_TIMEOUT=1 start_streamer tpartial "$FLAGSDIR"
j "$MSTART"; j "$TBLOCK"
j "$(delta 'The plan is frank about costs. ')"
j "$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":sys.argv[1]}]}}))' "The plan is frank about costs.")"
j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "the streamer exits" || fail "streamer hung" ""
check_eq "the uncovered sentence spoke untouched after failing open" \
    "$(said_count 'The plan is frank about costs.')" "1"
check "its outcome is failopen, not table-swap" contains "$(cat "$FIRES")" '"outcome": "failopen"'

echo
echo "the whole-draft pass (rule 44): tableswap, at string cost:"

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D"
cp "$LIST" "$D/claudisms.md"
WFLAGS="$D/claudism-flags"

DRAFT='The check ran twice. Frankly, the beacon is green. We are at this point in time ready.
---DISPLAY---
Frankly, this decoy stays exactly as written.'
OUT="$(printf '%s' "$DRAFT" | "$REPO_DIR/lib/claudism-mirror" tableswap \
    "$D/claudisms.md" "$WFLAGS" wake 4242)"
check "both covered sentences were swapped" contains "$OUT" "The beacon is green."
check "including the one with replacement text" contains "$OUT" "We are now ready."
refute "no firing decoration survives in the spoken half" \
    contains "${OUT%%---DISPLAY---*}" "Frankly"
check "the display half is untouched" contains "$OUT" "Frankly, this decoy stays exactly as written."
WDAY="$WFLAGS/$(date +%F).jsonl"
check_eq "two swaps, two flag rows" "$(sandbox_count_in table-swap "$WDAY")" "2"
check "logged under the caller's kind" contains "$(cat "$WDAY")" '"kind": "wake"'

OUT="$(printf '%s' 'The plan is frank about costs.' | "$REPO_DIR/lib/claudism-mirror" tableswap \
    "$D/claudisms.md" "$WFLAGS" wake 4242)"
check_eq "partial coverage passes through untouched for the mirror to hold" \
    "$OUT" "The plan is frank about costs."
check_eq "and adds no flag row" "$(sandbox_count_in table-swap "$WDAY")" "2"

OUT="$(printf '%s' 'Frankly, the beacon is green.' | "$REPO_DIR/lib/claudism-mirror" tableswap \
    "$D/claudisms.md" "$T/notadir" wake 4242)"
check_eq "an unloggable swap is not applied here either" \
    "$OUT" "Frankly, the beacon is green."

echo
echo "claudism_mirror_direct takes the swap without a mirror call:"

OUT="$(sandbox_bash 'claudism_mirror_direct wake "Frankly, the beacon is green. The rest is clean."')"
check "the delivered reply carries the repaired sentence" contains "$OUT" "The beacon is green."
refute "and not the decoration" contains "$OUT" "Frankly,"
[ -s "$SANDBOX_CLAUDE_LOG" ] && fail "a fully covered draft still paid for a model call" \
    "$(cat "$SANDBOX_CLAUDE_LOG")" || ok "no model was called for a fully covered draft"
check_eq "the swap reached the flag log" "$(sandbox_count_in table-swap "$WDAY")" "3"

OUT="$(sandbox_bash 'claudism_mirror_direct wake "You are certainly correct."')"
check "an uncovered draft still routes to the mirror" [ -s "$SANDBOX_CLAUDE_LOG" ]
check "and her answer is what is delivered" contains "$OUT" "stub reply."

echo
echo "the desk caller counts the streamer's swaps and folds them in (rule 43):"

DESKFIRES="$T/desk-fires.jsonl"
python3 - "$DESKFIRES" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"seq": 1,
                        "sentence": "Frankly, the beacon is green.",
                        "spoken": "Frankly, the beacon is green.",
                        "pattern": r"\bfrank(?:ly)?\b",
                        "note": "the frank opener",
                        "before": "Frankly, the beacon is green.",
                        "after": "The beacon is green."}) + "\n")
    f.write(json.dumps({"seq": 1, "outcome": "table-swap"}) + "\n")
PY
BEFORE=$(date +%s)
OUT="$(sandbox_bash '_CLAUDISM_FIRES_FILE="'"$DESKFIRES"'" _TTS_STREAMER_PID=$$ CLAUDISM_DESK_WAIT=6 claudism_mirror_desk "The check ran twice. Frankly, the beacon is green."')"
ELAPSED=$(( $(date +%s) - BEFORE ))
check "the committed reply carries what the speakers said" contains "$OUT" "The beacon is green."
refute "and not what they did not" contains "$OUT" "Frankly, the beacon is green."
[ "$ELAPSED" -le 3 ] && ok "the swap counted towards the predicted fires — no idle wait ($ELAPSED s)" \
    || fail "the caller sat out the deadline waiting for a hold that never comes" "${ELAPSED}s"
check "the done marker went down" [ -f "$DESKFIRES.done" ]
