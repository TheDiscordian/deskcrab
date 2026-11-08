#!/bin/bash
# The Stop-hook acceptance boundary — specs/speech-output.md rule 12b.
# Run: bash tests/test_reply_stop_acceptance.sh
#
# EXPECTED RED until the acceptance hold is built. The assertions below are the
# contract as adopted, not a description of today's streamer; the spec's TESTS
# section says so in the same words. Nothing here is weakened or xfailed.
#
# The live fault, 2026-08-25 10:17:44-10:17:50 (/tmp/deskcrab-speech.log lines
# 467-476, quoted in the engineering record
# my-reply-came-out-twice-the-same-paragraph-dupli): a Stop hook decides only
# after a message is complete, but the desk streamer voices deltas the moment
# each sentence completes. The CLI rejected a finished four-sentence draft
# ("...one honest sentence...") and fed the rejection back as a synthetic user
# event opening "Stop hook feedback:"; the model streamed the corrected message
# ("...one straight sentence..."); and the speakers got BOTH — eight SAID rows
# at 10:17:50, draft then rewrite. extract-response rule 5a correctly dropped
# the draft from the stored reply; it cannot unsay what already reached piper.
#
# Rule 12b's boundary: on the desktop stream no assistant message crosses the
# external piper boundary until the stream has moved past it with anything
# other than Stop-hook feedback. Feedback discards the ENTIRE pending draft;
# only the corrected message reaches piper. Deliberately outranks early
# sentence streaming for an unaccepted message, because speech handed to piper
# cannot be unsaid.
#
# THE WITNESS IS THE EXTERNAL PIPER TRACE — the stub below records its own
# stdin from outside the streamer. No assertion reads the streamer's receipt
# or speech log for the counts (the spec's own discipline: "speech tests
# measure from the speaker side").
#
# The mirror is deliberately unarmed here: the live incident had a claudism
# hold delaying the draft's first sentence, but the doubling needs no mirror —
# deltas voiced before the Stop decision are the whole mechanism.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# --- stub voice: records every line handed to piper, from OUTSIDE -----------
sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [ -n "$line" ]; do
    printf 'SAY\t%s\n' "$line" >> "$TRACE"
    head -c 2048 /dev/zero
done
EOF

# --- the 2026-08-25 corpus: the honest/straight shape ------------------------
# Reconstructed from the speech log's 90-char SAID rows: sentences 1 and 3
# reworded by the correction (honest -> straight; "me asking, not" -> "me
# asking for something, not"), sentences 2 and 4 carried over verbatim — so a
# carried-over sentence sounding TWICE is part of the live defect's shape.
D1="Twenty minutes for one honest sentence is a terrible ratio, and I'm not going to argue you out of it."
S2="I don't think you've given up — you're still here, twenty minutes in, which is the opposite of giving up."
D3="What I said was that I don't want you to, which was me asking, not me describing you."
S4="If it came out as a claim about you, that's the same reach again, in fact."
C1="Twenty minutes for one straight sentence is a terrible ratio, and I'm not going to argue you out of it."
C3="What I said was that I don't want you to, which was me asking for something, not me describing you."

DRAFT="$D1 $S2 $D3 $S4"
CORRECTION="$C1 $S2 $C3 $S4"

LOG="$T/stream.log"; TRACE="$T/piper.trace"
RECEIPT="$T/receipt"; SPEECHLOG="$T/speech.log"
: > "$LOG"; : > "$TRACE"; : > "$SPEECHLOG"

TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
    DESKCRAB_SPEECHLOCK="$T/speech.lock" \
    DESKCRAB_SPEECH_LOG="$SPEECHLOG" DESKCRAB_SPEECH_RECEIPT="$RECEIPT" \
    DESKCRAB_VOICE_IDLE_CLOSE=30 \
    "$REPO_DIR/lib/tts-streamer" 2>/dev/null &
SPID=$!
sandbox_at_exit '[ -n "$SPID" ] && kill -9 "$SPID" 2>/dev/null'
sleep 0.2

j() { printf '%s\n' "$1" >> "$LOG"; }
delta() {  # <text> — a text_delta on block 0
    python3 - "$1" <<'PY' >> "$LOG"
import json, sys
print(json.dumps({"type": "stream_event", "event": {"type": "content_block_delta",
    "index": 0, "delta": {"type": "text_delta", "text": sys.argv[1]}}}))
PY
}
closed() {  # <msgid> <text> — the completed assistant event
    python3 - "$1" "$2" <<'PY' >> "$LOG"
import json, sys
print(json.dumps({"type": "assistant", "message": {"id": sys.argv[1],
    "model": "claude-opus-5",
    "content": [{"type": "text", "text": sys.argv[2]}]}}))
PY
}
mstart() { j "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\",\"message\":{\"id\":\"$1\"}}}"; }
bstart() { j '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'; }
feedback() {  # the CLI's Stop-hook rejection, the live shape
    python3 - <<'PY' >> "$LOG"
import json
t = ("Stop hook feedback:\nSTOP. Your message uses filler you were told "
     "explicitly never to write.\n\nRewrite the entire message clean.")
print(json.dumps({"type": "user", "isSynthetic": True, "message": {
    "role": "user", "content": [{"type": "text", "text": t}]}}))
PY
    j '{"type":"system","subtype":"notification","key":"stop-hook-error","text":"Stop hook error occurred","priority":"immediate"}'
}
result() {
    python3 - "$1" <<'PY' >> "$LOG"
import json, sys
print(json.dumps({"type": "result", "result": sys.argv[1]}))
PY
}

# The stream, in the live order. The draft is FULLY streamed — every sentence
# complete as deltas — before its completed event, exactly as at 10:17. The
# pause where the Stop hook deliberated is fidelity, not a precondition:
# today's streamer has the draft queued for piper the moment each sentence
# closes, pause or no pause, and nothing ever unqueues it.
mstart msg_draft; bstart
delta "$D1 "; delta "$S2 "; delta "$D3 "; delta "$S4"
sleep 1.0
closed msg_draft "$DRAFT"
feedback
mstart msg_fix; bstart
delta "$C1 "; delta "$S2 "; delta "$C3 "; delta "$S4"
closed msg_fix "$CORRECTION"
result "$CORRECTION"

# Reap: the streamer ends its own tail at the result.
HUNG=no
for _ in $(seq 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$SPID" 2>/dev/null; then HUNG=yes; kill -9 "$SPID" 2>/dev/null; fi
wait "$SPID" 2>/dev/null

[ "$HUNG" = no ] \
    && ok "the streamer ends its tail at the result event" \
    || fail "streamer hung on this stream shape" "$(cat "$TRACE")"

# Everything piper was handed, as one normalised text — the whole witness.
# Joined rather than counted by line so the assertions pin WORDS, not the
# hold's chunking: a hold that releases the correction as one write and one
# that releases it sentence by sentence read identically here.
JOINED="$(sed 's/^SAY\t//' "$TRACE" | tr '\n' ' ' | tr -s ' ' | sed 's/ $//')"

count() { grep -oF -- "$1" <<< "$JOINED" | wc -l; }

echo "== no draft words cross the piper boundary =="
N="$(count "one honest sentence")"
[ "$N" = 0 ] \
    && ok "the rejected draft's first sentence never reached piper" \
    || fail "draft words reached piper: 'one honest sentence'" "seen $N time(s); trace: $JOINED"
N="$(count "me asking, not me describing")"
[ "$N" = 0 ] \
    && ok "the rejected draft's third sentence never reached piper" \
    || fail "draft words reached piper: 'me asking, not me describing'" "seen $N time(s)"

echo
echo "== the correction reaches piper, whole and once =="
N="$(count "one straight sentence")"
[ "$N" = 1 ] \
    && ok "the corrected first sentence is spoken, once" \
    || fail "corrected first sentence must reach piper exactly once" "seen $N time(s)"
N="$(count "asking for something")"
[ "$N" = 1 ] \
    && ok "the corrected third sentence is spoken, once" \
    || fail "corrected third sentence must reach piper exactly once" "seen $N time(s)"
N="$(count "the opposite of giving up")"
[ "$N" = 1 ] \
    && ok "the carried-over second sentence sounds once, not draft-then-correction" \
    || fail "second sentence doubled across draft and correction" "seen $N time(s)"
N="$(count "the same reach again")"
[ "$N" = 1 ] \
    && ok "the carried-over fourth sentence sounds once" \
    || fail "fourth sentence doubled across draft and correction" "seen $N time(s)"

echo
echo "== the trace is exactly the correction =="
check_eq "piper's stdin is the corrected message and nothing else" \
    "$JOINED" "$CORRECTION"
