#!/bin/bash
# Tests for DOUBLE SPEECH — the same reply reaching the speakers twice.
# Run: bash tests/test_speech_dup.sh
#
# Both failures measured live on 2026-08-07 (~13:09–13:42), heard as one
# finished reply spoken twice, sometimes overlapping itself:
#
# 1. THE FALSE-TRUNCATION LOOP. On a detected truncation the streamer did
#    `f.seek(0)` but set its byte counter to the CURRENT file size instead of
#    zero, then counted every re-read byte on top — so at EOF the counter sat
#    at exactly 2x the file size, which reads as another truncation, forever.
#    /tmp/deskcrab-speech.log holds hundreds of "truncated under me
#    (130202 -> 65101)" lines — 2:1, the loop's signature — and every pass
#    re-spoke every streamed sentence: the same words back-to-back within one
#    utterance. The streaming half had no dedup at all; the message-id and
#    spoken-text guards added that day only covered the completed half.
#
# 2. THE CRASH REPLAY. The receipt saying how many chars reached piper was
#    written only at exit. A streamer that died mid-turn (13:42: a NameError
#    from a half-edited file) had already SPOKEN the reply, but left no
#    receipt — so tts_verify_spoken read "spoke nothing" and replayed the
#    whole reply over the still-draining piper/aplay orphans: spoken twice,
#    overlapping.
#
# The stub piper/aplay below count utterances from OUTSIDE the streamer — the
# assertions never trust the pipeline's own receipt or logs for the counts.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# --- stub voice: counts each utterance handed to piper ----------------------
# From OUTSIDE the streamer, deliberately: every count below is a count of what
# reached the synthesiser, never of what the pipeline said it sent.
sandbox_stub piper-tts <<'EOF'
#!/usr/bin/env bash
while IFS= read -r line || [ -n "$line" ]; do
    printf 'SAY\t%s\n' "$line" >> "$TRACE"
    head -c 2048 /dev/zero
done
EOF

start_streamer() { # <name>
    LOG="$T/$1.log"; TRACE="$T/$1.trace"; RECEIPT="$T/$1.receipt"
    SPEECHLOG="$T/$1.speechlog"
    : > "$LOG"; : > "$TRACE"; : > "$SPEECHLOG"; rm -f "$RECEIPT"
    TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
        DESKCRAB_SPEECHLOCK="$T/$1.speechlock" \
        DESKCRAB_SPEECH_LOG="$SPEECHLOG" DESKCRAB_SPEECH_RECEIPT="$RECEIPT" \
        DESKCRAB_VOICE_IDLE_CLOSE=30 \
        "$REPO_DIR/lib/tts-streamer" 2>/dev/null &
    SPID=$!
    sleep 0.2
}

reap_streamer() { # waits, sets HUNG
    local i; HUNG=no
    for i in $(seq 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$SPID" 2>/dev/null; then HUNG=yes; kill -9 "$SPID" 2>/dev/null; fi
    wait "$SPID" 2>/dev/null
}

said_count() { grep -cF "SAY	$1" "$TRACE"; }

j() { printf '%s\n' "$1" >> "$LOG"; }
MSTART='{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_A"}}}'
TBLOCK='{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
DELTA1='{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"One two three. "}}}'
DELTA2='{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Four five six."}}}'
CLOSED='{"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":"One two three. Four five six."}]}}'
RESULT='{"type":"result","result":"x"}'

echo "the false-truncation loop — a log that shrinks but stays non-empty:"

start_streamer shrink
j "$MSTART"; j "$TBLOCK"; j "$DELTA1"
sleep 0.6                      # first sentence consumed and spoken
# The log is truncated and rewritten with a PREFIX of itself in one motion —
# what the streamer actually observes when another hand claims the file and a
# rerun's bytes land between two of its 20 ms polls. Size is non-zero and
# smaller than what was already read.
printf '%s\n%s\n' "$MSTART" "$TBLOCK" > "$LOG"
sleep 1.5                      # the old code loops here, re-speaking forever
j "$DELTA1"; j "$DELTA2"; j "$CLOSED"; j "$RESULT"
reap_streamer
[ "$HUNG" = no ] && ok "the streamer exits (the old one false-detected truncation forever)" \
    || fail "streamer hung in the re-read loop" "hung; trace: $(sort "$TRACE" | uniq -c | tr '\n' ' ')"
N=$(said_count "One two three.")
[ "$N" = 1 ] && ok "the re-read sentence reached piper exactly once" \
    || fail "sentence re-spoken after re-read" "spoken $N times"
N=$(said_count "Four five six.")
[ "$N" = 1 ] && ok "the sentence after the re-read is still spoken, once" \
    || fail "post-re-read sentence" "spoken $N times"

echo
echo "a re-emitted stream message is not re-voiced (same id, deltas and all):"

start_streamer reemit
j "$MSTART"; j "$TBLOCK"; j "$DELTA1"; j "$DELTA2"
sleep 0.5
j "$MSTART"; j "$TBLOCK"; j "$DELTA1"; j "$DELTA2"   # the same message again
j "$CLOSED"; j "$RESULT"
reap_streamer
N=$(said_count "One two three.")
[ "$N" = 1 ] && ok "duplicate streamed message is spoken once" \
    || fail "duplicate streamed message" "spoken $N times"

echo
echo "a fresh message keeps its voice (suppression is by id, not by habit):"

start_streamer fresh
j "$MSTART"; j "$TBLOCK"; j "$DELTA1"
j '{"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":"One two three. "}]}}'
j '{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_B"}}}'
j "$TBLOCK"
j '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Seven eight nine."}}}'
j '{"type":"assistant","message":{"model":"m","id":"msg_B","content":[{"type":"text","text":"Seven eight nine."}]}}'
j "$RESULT"
reap_streamer
N=$(said_count "Seven eight nine.")
[ "$N" = 1 ] && ok "second message with a new id is spoken" \
    || fail "new message swallowed or repeated" "spoken $N times"

echo
echo "the crash replay — a dead streamer must still leave a receipt:"

start_streamer crash
j "$MSTART"; j "$TBLOCK"; j "$DELTA1"
# WAIT for the precondition rather than sleeping at it. The case is "a streamer
# that had already spoken was killed before it could write its receipt", and it
# only tests that if the sentence really did reach the stub piper first. A flat
# 0.8 s that elapses early on a loaded box left the receipt legitimately empty
# and failed the NEXT assertion instead — a receipt bug that does not exist,
# with an uncounted note above it as the only clue. A missed barrier is this
# case's own failure and says so.
for _ in $(seq 100); do
    [ "$(said_count "One two three.")" -ge 1 ] && break
    sleep 0.05
done
[ "$(said_count "One two three.")" = 1 ] \
    || fail "the sentence never reached the synthesiser, so there was nothing to kill mid-speech" \
            "said $(said_count "One two three.") times in 5s — this case proved nothing about the receipt"
kill -9 "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
CHARS=$(sed -n 's/^chars=//p' "$RECEIPT" 2>/dev/null | head -1)
[ "${CHARS:-0}" -gt 0 ] 2>/dev/null \
    && ok "receipt written as speech happens — a SIGKILLed streamer leaves chars=$CHARS" \
    || fail "no receipt after SIGKILL (tts_verify_spoken would replay the whole reply)" "$(cat "$RECEIPT" 2>/dev/null || echo missing)"

echo
echo "end to end: the verify guard does not replay a reply the dead streamer spoke:"
cat > "$DESKCRAB_CONF" <<EOF
PIPER_VOICE=/dev/null
WHISPER_MODEL=/nonexistent.bin
PROJECT_DIR="$T"
EOF
TRACE="$T/e2e.trace"; : > "$TRACE"
out=$(TRACE="$TRACE" DESKCRAB_NO_DISPATCH=1 \
    SPEECH_LOG="$T/st-speech.log" bash -c '
    source "$1/lib/common.sh" >/dev/null 2>&1
    start_tts_streamer >/dev/null 2>&1
    printf "%s\n%s\n%s\n" \
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\",\"message\":{\"id\":\"msg_A\"}}}" \
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}}" \
      "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Heard once is enough. \"}}}" >> "$DEBUGLOG"
    sleep 0.8
    kill -9 "$_TTS_STREAMER_PID" 2>/dev/null
    wait "$_TTS_STREAMER_PID" 2>/dev/null
    tts_verify_spoken "Heard once is enough."' _ "$REPO_DIR" 2>&1)
N=$(grep -cF 'SAY	Heard once is enough.' "$TRACE")
[ "$N" = 1 ] && ok "the reply reached piper exactly once across streamer + verify" \
    || fail "verify replayed a spoken reply" "piper saw it $N times"

echo
echo "a thinking block shifts the stream's index space — the reply speaks once:"
# The CLI emits the finished text block ALONE, at position 0 of its own
# assistant event — NOT at its stream index, which a preceding thinking block
# pushed to 1. Looked up by position, the closer found a fresh block with
# nothing consumed and spoke the whole reply a second time. Measured live at
# 15:31 on 2026-08-07: one canary turn, two SAIDs from one streamer pid —
# every reply with a thinking block doubled, which was every reply.
start_streamer thinkshift
j '{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_T"}}}'
j '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}'
j '{"type":"stream_event","event":{"type":"content_block_stop","index":0}}'
j '{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}'
j '{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Canary test seventeen. "}}}'
sleep 0.6
j '{"type":"assistant","message":{"model":"m","id":"msg_T","content":[{"type":"text","text":"Canary test seventeen. "}]}}'
j "$RESULT"
reap_streamer
n=$(said_count "Canary test seventeen.")
[ "$n" = 1 ] && ok "streamed behind a thinking block, spoken exactly once" \
    || fail "the completed event must find the streamed block by content" "said $n times"

echo
echo "a thinking block AND a re-read — the two cases together, which is the live one:"
# Each half passed on its own and the reply still doubled, because the bug was
# in the seam. The CLI emits a completed assistant event PER CONTENT BLOCK, so
# the thinking block's event arrives before the reply's text block has even
# been opened — and that branch used to end `blocks = {}`, orphaning the dict
# `messages` holds. The re-read replays only what it can reach through
# `messages`, so the reply's block was rebuilt from scratch with nothing
# consumed and the whole finished sentence was spoken again.
start_streamer thinkread
TMS='{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_TR"}}}'
TTH='{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}'
TTHS='{"type":"stream_event","event":{"type":"content_block_stop","index":0}}'
TATH='{"type":"assistant","message":{"model":"m","id":"msg_TR","content":[{"type":"thinking","thinking":"mm"}]}}'
TTB='{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}'
TD='{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Behind a thought. "}}}'
j "$TMS"; j "$TTH"; j "$TTHS"; j "$TATH"; j "$TTB"; j "$TD"
sleep 0.8                      # the sentence reaches the stub piper once
printf '%s\n%s\n%s\n' "$TMS" "$TTH" "$TTHS" > "$LOG"   # claimed and rewritten
sleep 0.6
j "$TATH"; j "$TTB"; j "$TD"
j '{"type":"assistant","message":{"model":"m","id":"msg_TR","content":[{"type":"text","text":"Behind a thought. "}]}}'
j "$RESULT"
reap_streamer
N=$(said_count "Behind a thought.")
[ "$N" = 1 ] && ok "streamed behind a thinking block and then re-read: spoken once" \
    || fail "the message's block map must survive its own completed events" "spoken $N times"

echo
echo "a log that only GROWS is never read as a truncation:"
# The false-truncation loop's other half: the byte counter was assigned the
# STAT SIZE at EOF, which includes bytes written between readline() returning
# '' and the stat a moment later — then counted them again when the next
# readline delivered them. The counter drifted permanently above the file and
# every EOF after that read as a shrink. 143,766 of those lines in
# /tmp/deskcrab-speech.log, every one false. The counter now only ever counts
# bytes actually read, so a growing file cannot produce one at all.
start_streamer grow
j "$MSTART"; j "$TBLOCK"
for i in $(seq 40); do
    printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Filler %d. "}}}\n' "$i" >> "$LOG"
done
sleep 1.2
for i in $(seq 41 80); do
    printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Filler %d. "}}}\n' "$i" >> "$LOG"
done
j "$RESULT"
reap_streamer
N=$(grep -c "truncated under me" "$SPEECHLOG" 2>/dev/null)
[ "${N:-0}" = 0 ] && ok "no truncation is reported for a file that only ever grew" \
    || fail "the read counter must not be set from the file's size" "$N truncation lines"
N=$(said_count "Filler 1.")
[ "$N" = 1 ] && ok "and nothing in it is spoken twice" || fail "a growing log must speak once" "spoken $N times"
