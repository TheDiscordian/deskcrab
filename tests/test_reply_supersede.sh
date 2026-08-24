#!/bin/bash
# Reply supersede and tail survival — the 2026-08-22 00:33/00:36/00:40 faults.
# Run: bash tests/test_reply_supersede.sh
#
# Three shapes, all sighted live between 00:33 and 00:41 on 2026-08-22 and
# written to the engineering record my-reply-came-out-twice-the-same-paragraph-dupli:
#
# 1. THE DUPLICATED BODY. A Stop hook (a user-level plugin outside this repo)
#    rejected a finished reply over a filler word; the CLI fed the rejection
#    back as a user event ("Stop hook feedback:\n...") and the model wrote a
#    corrected second message. extract-response kept EVERY assistant text
#    block, so the rejected draft and its correction were both delivered,
#    joined — the 00:33 phone reply and the 00:36 wake both went out doubled,
#    the second copy a rewrite (not a byte copy) missing the flagged word.
#    specs/speech-output.md rule 5a: the rejected draft is dropped when a real
#    block follows the feedback.
#
# 2. THE REWORDED DUPLICATE. Whatever the cause upstream, two consecutive
#    near-identical blocks (or paragraphs) must not both be delivered: drop
#    the earlier, keep the later. Threshold is the memory near-duplicate
#    convention, 0.92 (lib/memory.py NEAR_DUP_SIM), on the blended lexical
#    similarity in lib/sentence_stream.py — measured on the live corpus below:
#    both real duplicate pairs score >= 0.9256, every genuinely distinct
#    consecutive pair scores <= 0.34. specs/speech-output.md rule 5b.
#
# 3. THE LOST TAIL. The 00:40 phone reply's last two clips were synthesised
#    and delivered as events, the page died mid-playback, and nothing could
#    ever recover them: the re-attach replay dropped ALL backlog voice clips
#    by wall clock. specs/phone.md rule 39 (amended): the replay carries the
#    server's own playback truth per clip, so a re-attaching client can play
#    what never sounded and skip only what did.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

X() { DESKCRAB_DEBUGLOG="$1" "$REPO_DIR/lib/extract-response"; }

# --- the live corpus -------------------------------------------------------
# The 00:36 wake pair, verbatim from /tmp/deskcrab-debug-2934337.log.
DRAFT_0036="He castled. Actually castled, after weeks of me nagging him about it — so now I have to beat him honestly instead of just waiting for his king to wander into something."
REWRITE_0036="He castled. Actually castled, after weeks of me nagging him about it — so now I have to win this one properly instead of just waiting for his king to wander into something."
# The 00:33 phone pair, verbatim from the day journal (two-paragraph bodies).
DRAFT_0033="Candidly? Yes. I'm up a full bishop, his queen's about to get herself skewered if she goes hunting on b7, and it's his move with nothing good on it.

The part I'm watching is me, not him — I'm ahead, which is precisely the moment I historically start trading pieces off like that's safety and hand the game back. Not tonight, in fact."
REWRITE_0033="Yes. I'm up a full bishop, his queen gets herself collected if she goes hunting on b7, and it's his move with nothing good on it.

The part I'm watching is me, not him — I'm ahead, which is precisely the moment I historically start trading pieces off like that's safety and hand the game back. Not tonight, in fact."
# Genuinely distinct consecutive paragraphs from the same evening's replies —
# the suppressor must never fire across these.
DISTINCT_A1="Filed — the double reply's written down with the timestamp on it, and it goes to a builder tonight with the rest of the drain, not mid-game."
DISTINCT_A2="As for the other part — hmph. Yes, I'm pleased. I've stopped handing games back at move thirty, which is the thing I've been failing at for weeks, and that's worth something."
DISTINCT_B1="Mate on d1, back rank — he castled and then sent both rooks off to fetch things, in fact."
DISTINCT_B2="The bit I'm actually pleased about is move twenty-four: I traded queens while up a piece, and this time it was correct."

FEEDBACK_TEXT="Stop hook feedback:\nSTOP. Your message uses filler you were told explicitly never to write.\n\nRewrite the entire message clean, without any of the above."

# jq-free JSON line builders (python handles the embedded newlines/quotes).
aline() { # <msgid> <text...>  -> one assistant event line
    python3 - "$1" "$2" <<'PY'
import json, sys
print(json.dumps({"type": "assistant", "message": {"id": sys.argv[1],
    "model": "claude-opus-5",
    "content": [{"type": "text", "text": sys.argv[2]}]}}))
PY
}
fbline() { # the CLI's stop-hook rejection, shaped as in the live log
    python3 - <<'PY'
import json
t = ("Stop hook feedback:\nSTOP. Your message uses filler you were told "
     "explicitly never to write.\n\nRewrite the entire message clean.")
print(json.dumps({"type": "user", "isSynthetic": True, "message": {
    "role": "user", "content": [{"type": "text", "text": t}]}}))
PY
}
rline() { # <text> -> result event
    python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"type": "result", "result": sys.argv[1]}))
PY
}
notifline() {
    printf '%s\n' '{"type":"system","subtype":"notification","key":"stop-hook-error","text":"Stop hook error occurred","priority":"immediate"}'
}

echo "== shape 1: the stop-hook rejected draft is dropped =="

# The 00:36 stream, faithfully: draft, rejection, CLI notification, rewrite,
# result carrying the rewrite.
L="$T/rejected.log"
{ aline msg_A "$DRAFT_0036"; fbline; notifline; aline msg_B "$REWRITE_0036"; rline "$REWRITE_0036"; } > "$L"
GOT="$(X "$L")"
[ "$GOT" = "$REWRITE_0036" ] \
    && ok "the rejected draft is dropped; only the rewrite is the reply" \
    || fail "rejected draft still delivered" "$GOT"

# Narration before the draft is NOT the draft: only the rejected message goes.
L="$T/narrated.log"
{ aline msg_N "Let me look at the board first."
  printf '%s\n' '{"type":"assistant","message":{"id":"msg_N","model":"m","content":[{"type":"tool_use","name":"Bash","input":{"command":"true"}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'
  aline msg_A "$DRAFT_0036"; fbline; aline msg_B "$REWRITE_0036"; rline "$REWRITE_0036"; } > "$L"
GOT="$(X "$L")"
WANT="Let me look at the board first.

$REWRITE_0036"
[ "$GOT" = "$WANT" ] \
    && ok "narration survives; only the rejected message is dropped" \
    || fail "narration lost or draft kept" "$GOT"

# A rejection with NOTHING after it keeps the draft — never-silent wins.
L="$T/nothing-after.log"
{ aline msg_A "$DRAFT_0036"; fbline; } > "$L"
GOT="$(X "$L")"
[ "$GOT" = "$DRAFT_0036" ] \
    && ok "a rejection followed by nothing keeps the draft (never silent)" \
    || fail "rejection with no rewrite lost the reply" "$GOT"

# Two rounds of rejection: only the last message stands.
L="$T/two-rounds.log"
{ aline msg_A "First try, honestly."; fbline
  aline msg_B "Second try, to be honest."; fbline
  aline msg_C "Third try, plain."; rline "Third try, plain."; } > "$L"
GOT="$(X "$L")"
[ "$GOT" = "Third try, plain." ] \
    && ok "two rejection rounds leave only the final message" \
    || fail "earlier rejected drafts survived two rounds" "$GOT"

# Control: an ordinary multi-block turn without any rejection keeps every
# block, in order — rule 5 is untouched.
L="$T/plain.log"
{ aline msg_A "$DISTINCT_A1"; aline msg_B "$DISTINCT_A2"; rline "$DISTINCT_A2"; } > "$L"
GOT="$(X "$L")"
WANT="$DISTINCT_A1

$DISTINCT_A2"
[ "$GOT" = "$WANT" ] \
    && ok "an ordinary narrating turn still keeps every block" \
    || fail "rule 5 regressed — a plain multi-block turn lost a block" "$GOT"

echo
echo "== shape 2: the reworded duplicate is superseded at composition =="

# No stop-hook event at all — the belt must catch the doubled body on its own.
L="$T/dup-0036.log"
{ aline msg_A "$DRAFT_0036"; aline msg_B "$REWRITE_0036"; rline "$REWRITE_0036"; } > "$L"
GOT="$(X "$L")"
[ "$GOT" = "$REWRITE_0036" ] \
    && ok "00:36 pair: the earlier near-duplicate block is dropped, later kept" \
    || fail "00:36 reworded duplicate delivered twice" "$GOT"

L="$T/dup-0033.log"
{ aline msg_A "$DRAFT_0033"; aline msg_B "$REWRITE_0033"; rline "$REWRITE_0033"; } > "$L"
GOT="$(X "$L")"
[ "$GOT" = "$REWRITE_0033" ] \
    && ok "00:33 pair: the two-paragraph near-duplicate body collapses to the later copy" \
    || fail "00:33 doubled body delivered" "$GOT"

# Distinct consecutive blocks are untouched — both corpora.
L="$T/distinct-blocks.log"
{ aline msg_A "$DISTINCT_B1"; aline msg_B "$DISTINCT_B2"; rline "$DISTINCT_B2"; } > "$L"
GOT="$(X "$L")"
WANT="$DISTINCT_B1

$DISTINCT_B2"
[ "$GOT" = "$WANT" ] \
    && ok "genuinely distinct consecutive blocks both survive" \
    || fail "suppressor fired across distinct blocks" "$GOT"

# Paragraph level, inside one block: a draft paragraph and its rewrite. The
# result event repeats the final block verbatim, as the CLI does.
L="$T/dup-paras.log"
{ aline msg_A "$DRAFT_0036

$REWRITE_0036"; rline "$DRAFT_0036

$REWRITE_0036"; } > "$L"
GOT="$(X "$L")"
case "$GOT" in
    *"win this one properly"*) case "$GOT" in
        *"beat him honestly"*) fail "in-block reworded paragraph pair delivered twice" "$GOT" ;;
        *) ok "consecutive near-duplicate paragraphs inside one block collapse to the later" ;;
    esac ;;
    *) fail "paragraph collapse lost the surviving copy" "$GOT" ;;
esac

# Distinct paragraphs inside one block are untouched.
L="$T/distinct-paras.log"
{ aline msg_A "$DISTINCT_A1

$DISTINCT_A2"; rline "$DISTINCT_A1

$DISTINCT_A2"; } > "$L"
GOT="$(X "$L")"
WANT="$DISTINCT_A1

$DISTINCT_A2"
[ "$GOT" = "$WANT" ] \
    && ok "distinct paragraphs inside one block both survive" \
    || fail "suppressor fired across distinct paragraphs" "$GOT"

# The display halves ride above the collapse: a duplicate spoken half with a
# display section keeps exactly one display channel and the later spoken copy.
L="$T/dup-display.log"
{ aline msg_A "$DRAFT_0036"; aline msg_B "$REWRITE_0036
---DISPLAY---
| a | b |"; rline "$REWRITE_0036
---DISPLAY---
| a | b |"; } > "$L"
GOT="$(X "$L")"
WANT="$REWRITE_0036

---DISPLAY---
| a | b |"
[ "$GOT" = "$WANT" ] \
    && ok "the display half survives the collapse untouched" \
    || fail "display half mangled by the collapse" "$GOT"

echo
echo "== shape 2, live voices: a never-voiced near-duplicate block is not spoken =="

REG="$T/reg-out.txt"
regdrive() { # feed python driver on stdin; SAID lines land in $REG
    : > "$REG"
    PYTHONPATH="$REPO_DIR/lib" python3 - "$REG" <<PY
import sys
from sentence_stream import BlockRegistry
out = open(sys.argv[1], "a")
reg = BlockRegistry(lambda c: (out.write("SAID\t" + " ".join(c.split()) + "\n"), out.flush()))
DRAFT = """$DRAFT_0036"""
REWRITE = """$REWRITE_0036"""
DISTINCT = """$DISTINCT_B2"""
$PYBODY
PY
}

# Close-only blocks (a wake, block mode): the draft is voiced, the reworded
# duplicate that never streamed is held off the speakers.
PYBODY='
reg.close_text("msg_A", 0, DRAFT)
reg.close_text("msg_B", 0, REWRITE)
'
regdrive
N_DRAFT="$(grep -c "beat him honestly" "$REG" || true)"
N_REWRITE="$(grep -c "win this one properly" "$REG" || true)"
[ "$N_DRAFT" = 1 ] && [ "$N_REWRITE" = 0 ] \
    && ok "close-only reworded duplicate block is not voiced a second time" \
    || fail "live voice spoke the reworded duplicate" "draft=$N_DRAFT rewrite=$N_REWRITE"

# A distinct second block keeps its voice.
PYBODY='
reg.close_text("msg_A", 0, DRAFT)
reg.close_text("msg_B", 0, DISTINCT)
'
regdrive
N1="$(grep -c "beat him honestly" "$REG" || true)"
N2="$(grep -c "traded queens" "$REG" || true)"
[ "$N1" = 1 ] && [ "$N2" = 1 ] \
    && ok "a genuinely distinct second block is still voiced" \
    || fail "suppression silenced a distinct block" "first=$N1 second=$N2"

# A block that already started sounding is never cut by the suppressor: its
# own remainder still flushes at close (the final sentence survives).
PYBODY='
reg.stream_event({"type": "message_start", "message": {"id": "msg_A"}})
reg.stream_event({"type": "content_block_start", "index": 0, "content_block": {"type": "text"}})
reg.stream_event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": DRAFT[:40]}})
reg.close_text("msg_A", 0, DRAFT)
'
regdrive
JOINED="$(sed 's/^SAID\t//' "$REG" | tr '\n' ' ')"
case "$JOINED" in
    *"wander into something."*) ok "a partly-streamed block still flushes its own tail at close" ;;
    *) fail "the streamed block's tail was lost at close" "$JOINED" ;;
esac

echo
echo "== shape 3: the stream's tail survives to delivery =="

# The chunker's end-of-stream flush: a final sentence that only ever arrived
# as deltas, never inside a completed event's own text, is still voiced.
PYBODY='
reg.stream_event({"type": "message_start", "message": {"id": "msg_A"}})
reg.stream_event({"type": "content_block_start", "index": 0, "content_block": {"type": "text"}})
reg.stream_event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "First thing said. People do exactly that"}})
reg.close_text("msg_A", 0, "First thing said. People do exactly that")
'
regdrive
JOINED="$(sed 's/^SAID\t//' "$REG" | tr '\n' ' ')"
case "$JOINED" in
    *"People do exactly that"*) ok "an unterminated final sentence is flushed at close" ;;
    *) fail "the unterminated tail never reached the voice" "$JOINED" ;;
esac

# The replay carries playback truth (specs/phone.md rule 39): a re-attaching
# client is told, per replayed clip, whether that clip was ever reported
# playing — so the tail that never sounded can sound, and only what was heard
# is skipped. Real server, real sockets, as test_phone_playback drives it.
SERVE_PID=""
sandbox_at_exit '[ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null'
SECRET="testsecret"
PORT=18741

cat > "$T/crab" <<'STUB'
#!/bin/bash
case "$1" in
  synth)
    printf 'CLIP-BYTES%.0s' $(seq 1 30) > "$2"
    exit 0 ;;
  notify)
    shift
    printf '%s\n' "$*" >> "$NOTIFY_LOG"
    exit 0 ;;
  remote) ;;
  *) exit 1 ;;
esac
python3 - <<'PY'
import json, os
with open(os.environ["DESKCRAB_REMOTE_LOG"], "a") as f:
    f.write(json.dumps({"type": "assistant", "message": {"id": "m1",
        "content": [{"type": "text", "text": "The first block of the reply, about the opening."}]}}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"id": "m2",
        "content": [{"type": "text", "text": "A completely different closing thought on the endgame."}]}}) + "\n")
PY
python3 -c 'import json;print(json.dumps({"spoken":"the reply","display":"","audio":"","error":""}))'
exit 0
STUB
chmod +x "$T/crab"

mkdir -p "$T/metrics"
: > "$T/notify.log"
DESKCRAB_SERVE_SECRET="$SECRET" DESKCRAB_SERVE_PORT="$PORT" \
DESKCRAB_SERVE_BIND=127.0.0.1 DESKCRAB_SERVE_TIMEOUT=30 \
DESKCRAB_SERVE_PLAY_ALARM=3 \
DESKCRAB_CRAB_BIN="$T/crab" DESKCRAB_STATE_PREFIX="$T/deskcrab-x" \
DESKCRAB_METRICS_DIR="$T/metrics" NOTIFY_LOG="$T/notify.log" \
    python3 "$REPO_DIR/lib/serve.py" > "$T/server.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 100); do
    curl -sS -m 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.1
done

TID="aabbccdd00112233aabbccdd00112233"
FIRST="$(curl -sS -m 20 -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
    --data "{\"text\":\"hello\",\"turn\":\"$TID\"}" "http://127.0.0.1:$PORT/say")"
N_VOICE="$(printf '%s' "$FIRST" | grep -c '"voice"')"
[ "$N_VOICE" = 2 ] \
    && ok "the live stream carried both voice clips" \
    || fail "expected two live voice events" "$N_VOICE — $FIRST"

# The phone heard clip 0 and died mid-queue: only clip 0 reports.
played() { # <clip> <event>
    curl -sS -m 5 -H "X-Crab-Key: $SECRET" -H "Content-Type: application/json" \
        --data "{\"turn\":\"$TID\",\"clip\":\"$1\",\"event\":\"$2\"}" \
        "http://127.0.0.1:$PORT/played" > /dev/null
}
played 0 requested; played 0 started; played 0 completed
played 1 requested

REPLAY="$(curl -sS -m 20 -H "X-Crab-Key: $SECRET" "http://127.0.0.1:$PORT/turn/$TID?from=0")"
P0="$(printf '%s\n' "$REPLAY" | grep '"voice"' | sed -n 1p)"
P1="$(printf '%s\n' "$REPLAY" | grep '"voice"' | sed -n 2p)"
case "$P0" in
    *'"played": true'*|*'"played":true'*) ok "the replay marks the heard clip as played" ;;
    *) fail "replayed clip 0 not marked played" "$P0" ;;
esac
case "$P1" in
    *'"played": false'*|*'"played":false'*) ok "the replay marks the never-started clip as unplayed — the tail can sound" ;;
    *) fail "replayed clip 1 not marked unplayed" "$P1" ;;
esac

# The dead tail leaves a witness: one notification names the clip that never
# started while an earlier one did (specs/phone.md rule 46).
for _ in $(seq 80); do
    grep -q "never played" "$T/notify.log" 2>/dev/null && break
    sleep 0.1
done
N_NOTE="$(grep -c "never played" "$T/notify.log" || true)"
[ "$N_NOTE" = 1 ] \
    && ok "a died-mid-queue turn raises exactly one dead-tail notification" \
    || fail "dead tail left no witness (or too many)" "count=$N_NOTE $(cat "$T/notify.log")"
