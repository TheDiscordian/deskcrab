#!/bin/bash
# Tests for the audio path: lib/tts-streamer, the per-session stream log, and
# the never-silent guarantee in lib/common.sh.
# Run: bash tests/test_speech_path.sh
#
# The two failures these were written for, both measured on 2026-08-07:
#
# 1. SILENCE. $DEBUGLOG was ONE shared file. A wake firing beside a desktop
#    turn ran `: > "$DEBUGLOG"` on the very file that turn's TTS streamer was
#    tailing; the streamer's read cursor was left past EOF, so it read nothing
#    more, spoke nothing, and never saw a result event — the reply appeared on
#    screen, was never heard, and the unbounded `wait` behind it hung the turn.
#    Reproduced here as `truncated mid-turn`: on the old code that case is
#    silent AND never exits.
#
# 2. LATENCY. A plain stream-json run only emits a completed `assistant` event
#    once a WHOLE text block is generated, so the first word was spoken when
#    the answer finished, not when it started. With --include-partial-messages
#    the streamer speaks each sentence as it completes.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-speech.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — got [$2]"; }

# --- stub voice: records each utterance with the moment it was handed over --
mkdir -p "$T/bin"
cat > "$T/bin/piper-tts" <<'EOF'
#!/usr/bin/env bash
printf '%s\tSTART\n' "$(date +%s.%N)" >> "$TRACE"
while IFS= read -r line || [ -n "$line" ]; do   # last line may be unterminated
    printf '%s\tSAY\t%s\n' "$(date +%s.%N)" "$line" >> "$TRACE"
    head -c 2048 /dev/zero
done
EOF
cat > "$T/bin/aplay" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\tPLAYED\n' "$(date +%s.%N)" >> "$TRACE"
EOF
# notify-send too: tts_verify_spoken announces a failed speech path, and an
# unstubbed notify-send pops that announcement on the LIVE desktop every time
# this suite runs — a test that cries wolf on his screen.
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/notify-send"
chmod +x "$T/bin/piper-tts" "$T/bin/aplay" "$T/bin/notify-send"
export PATH="$T/bin:$PATH"

# --- run the streamer against a feeder, return the trace -------------------
# stream <case> <feeder-body>. Sets START/TRACE/LOG for the case.
stream() {
    local NAME="$1" BODY="$2"
    LOG="$T/$NAME.log"; TRACE="$T/$NAME.trace"; RECEIPT="$T/$NAME.receipt"
    SPEECHLOG="$T/$NAME.speechlog"
    : > "$LOG"; : > "$TRACE"; : > "$SPEECHLOG"; rm -f "$RECEIPT"
    START=$(date +%s.%N)
    TRACE="$TRACE" DESKCRAB_DEBUGLOG="$LOG" DESKCRAB_PIPER_VOICE=/dev/null \
        DESKCRAB_SPEECHLOCK="$T/$NAME.speechlock" \
        DESKCRAB_SPEECH_LOG="$SPEECHLOG" DESKCRAB_SPEECH_RECEIPT="$RECEIPT" \
        DESKCRAB_VOICE_IDLE_CLOSE=30 \
        "$REPO_DIR/lib/tts-streamer" 2>/dev/null &
    SPID=$!
    sleep 0.2
    ( LOG="$LOG"; eval "$BODY" )
    local i
    HUNG=no
    for i in $(seq 100); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$SPID" 2>/dev/null; then HUNG=yes; kill -9 "$SPID" 2>/dev/null; fi
    wait "$SPID" 2>/dev/null
    SAID=$(sed -n 's/^[0-9.]*\tSAY\t//p' "$TRACE")
}

# When (seconds after the streamer started) was the Nth utterance handed over?
at() { # <n>
    sed -n 's/^\([0-9.]*\)\tSAY\t.*/\1/p' "$TRACE" | sed -n "$1p" \
        | { read -r t || return 1; python3 -c "import sys;print('%.2f'%(float(sys.argv[1])-float(sys.argv[2])))" "$t" "$START"; }
}

a() { printf '%s\n' "$1" >> "$LOG"; }          # one raw stream line
delta() { python3 -c 'import json,sys;print(json.dumps({"type":"stream_event","event":{"type":"content_block_delta","index":int(sys.argv[2]),"delta":{"type":"text_delta","text":sys.argv[1]}}}))' "$1" "${2:-0}" >> "$LOG"; }
tblock() { a "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":${1:-0},\"content_block\":{\"type\":\"text\",\"text\":\"\"}}}"; }
say_json() { python3 -c 'import json,sys;print(json.dumps({"type":"assistant","message":{"model":"m","content":[{"type":"text","text":sys.argv[1]}]}}))' "$1" >> "$LOG"; }
done_json() { a '{"type":"result","result":"x"}'; }

echo "the completed-block path (a run with no --include-partial-messages):"

stream plain '
    a "{\"type\":\"system\",\"subtype\":\"init\"}"
    say_json "The answer is yes."
    done_json'
[ "$SAID" = "The answer is yes." ] && ok "a plain reply is spoken" || fail "plain reply" "$SAID"

stream leadws 'say_json "

   Hello there.
"; done_json'
[ "$SAID" = "Hello there." ] && ok "leading whitespace and newlines are trimmed, not swallowed" || fail "leading whitespace" "$SAID"

stream thinking '
    a "{\"type\":\"assistant\",\"message\":{\"model\":\"m\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private reasoning\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"ls\"}}]}}"
    a "{\"type\":\"assistant\",\"message\":{\"model\":\"m\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"more\"},{\"type\":\"text\",\"text\":\"The answer after the tool call.\"}]}}"
    done_json'
[ "$SAID" = "The answer after the tool call." ] \
    && ok "thinking and tool_use are never spoken, text after them is" || fail "thinking blocks" "$SAID"

stream displaysplit 'say_json "Spoken half here.

---DISPLAY---
# A report that must never be read aloud"; done_json'
[ "$SAID" = "Spoken half here." ] && ok "only the half above ---DISPLAY--- is spoken" || fail "display split" "$SAID"

stream displayonly 'say_json "---DISPLAY---
# report only"; done_json'
[ -z "$SAID" ] && ok "a display-only reply is silent" || fail "display-only must be silent" "$SAID"
grep -q "spoke nothing" "$SPEECHLOG" \
    && ok "…and the silence is written down, not swallowed" || fail "silence must be logged" "$(cat "$SPEECHLOG")"

echo
echo "the streaming path (--include-partial-messages): first sentence, not last:"

stream partials '
    a "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}"
    tblock 0
    sleep 0.3; delta "First sentence, which"
    sleep 0.2; delta " could have been spoken much earlier."
    sleep 0.2; delta " Second sentence."
    sleep 2.0; delta " Third and last."
    say_json "First sentence, which could have been spoken much earlier. Second sentence. Third and last."
    done_json'
FIRST=$(at 1); LAST=$(at 3)
[ "$(printf '%s\n' "$SAID" | wc -l)" = 3 ] \
    && ok "three sentences, spoken one at a time" || fail "sentence chunking" "$SAID"
python3 -c "import sys;sys.exit(0 if float(sys.argv[1])<1.2 else 1)" "$FIRST" \
    && ok "first speech at ${FIRST}s — before the block was finished (${LAST}s)" \
    || fail "first speech must not wait for the block" "$FIRST"
[ "$(printf '%s' "$SAID" | grep -c "First sentence")" = 1 ] \
    && ok "the completed assistant event does not repeat what was already said" \
    || fail "double speech" "$SAID"
[ "$(grep -c 'START' "$TRACE")" = 1 ] \
    && ok "one piper process for the whole burst (the voice model loads once)" \
    || fail "piper restarted per sentence" "$(grep -c START "$TRACE")"

stream partial_delim '
    a "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}"
    tblock 0
    delta "Here is the spoken half."
    sleep 0.3; delta "

---DIS"
    sleep 0.3; delta "PLAY---
# Report title that must never be spoken."
    say_json "Here is the spoken half.

---DISPLAY---
# Report title that must never be spoken."
    done_json'
[ "$SAID" = "Here is the spoken half." ] \
    && ok "a ---DISPLAY--- delimiter split across deltas is never voiced" || fail "split delimiter" "$SAID"

stream partial_late_text '
    a "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"}}"
    a "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}}"
    tblock 1
    delta "The text block that arrives after a tool call." 1
    a "{\"type\":\"assistant\",\"message\":{\"model\":\"m\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"x\"},{\"type\":\"text\",\"text\":\"The text block that arrives after a tool call.\"}]}}"
    done_json'
[ "$SAID" = "The text block that arrives after a tool call." ] \
    && ok "a text block at index 1 (behind thinking) is spoken exactly once" || fail "indexed block" "$SAID"

echo
echo "the regression itself — another session truncating the log mid-turn:"

stream truncated '
    a "{\"type\":\"assistant\",\"message\":{\"model\":\"m\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}}"
    sleep 0.6
    : > "$LOG"        # a wake claiming the shared log, as run_claude_wake used to
    sleep 0.4
    say_json "This reply exists in the log and must be heard."
    done_json'
[ "$SAID" = "This reply exists in the log and must be heard." ] \
    && ok "a truncated log does not cost the reply its voice" || fail "truncation is silence" "$SAID"
[ "$HUNG" = no ] && ok "…and the streamer still exits (the old one tailed forever)" \
    || fail "streamer hung after truncation" "hung"
grep -q "truncated under me" "$SPEECHLOG" \
    && ok "…and says so in the speech log" || fail "truncation must be logged" "$(cat "$SPEECHLOG")"

echo
echo "the speech mutex delays, it never drops:"

stream lockheld '
    flock -x "'"$T"'/lockheld.speechlock" -c "sleep 3" &
    sleep 0.3
    say_json "Late is fine. Silent is not."
    done_json
    wait'
[ -n "$SAID" ] && ok "a reply behind another voice is still spoken ($(at 1)s late)" \
    || fail "the lock swallowed the reply" "silence"

echo
echo "the receipt — what actually reached the speakers:"
stream receipt 'say_json "Something was said."; done_json'
grep -q '^chars=1[0-9]' "$RECEIPT" && ok "the receipt counts the spoken characters" \
    || fail "receipt" "$(cat "$RECEIPT" 2>/dev/null)"
stream receipt_silent 'say_json "---DISPLAY---
x"; done_json'
grep -q '^chars=0' "$RECEIPT" && ok "a silent turn leaves chars=0, not a missing receipt" \
    || fail "silent receipt" "$(cat "$RECEIPT" 2>/dev/null)"

echo
echo "one stream log per session — nobody can truncate anybody:"
cat > "$T/conf" <<EOF
PIPER_VOICE=/dev/null
WHISPER_MODEL=/nonexistent.bin
PROJECT_DIR="$T"
EOF
run() { DESKCRAB_CONF="$T/conf" DESKCRAB_STATE_PREFIX="$T/st" JOBS_DIR="$T/jobs" \
        DAY_JOURNAL_DIR="$T/journal" DESKCRAB_NO_DISPATCH=1 SPEECH_LOG="$T/st-speech.log" \
        bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$REPO_DIR" "$1" 2>&1; }
L1=$(run 'echo "$DEBUGLOG"'); L2=$(run 'echo "$DEBUGLOG"')
[ "$L1" != "$L2" ] && ok "two sessions get two different stream logs" \
    || fail "the stream log is still shared" "$L1"
run 'claim_debuglog; echo written > "$DEBUGLOG"; readlink "$DEBUGLOG_LATEST"' > "$T/link" 2>&1
[ -n "$(cat "$T/link")" ] && ok "the well-known name points at the newest (crab-debug still works)" \
    || fail "no pointer for crab-debug" "$(cat "$T/link")"

echo
echo "the guarantee — a reply with nothing on the receipt is spoken anyway:"
TRACE="$T/verify.trace"; : > "$TRACE"
out=$(TRACE="$TRACE" run '
    _TTS_RECEIPT="'"$T"'/none.receipt"
    printf "pid=1\nchars=0\nlines=0\nerror=cannot start the voice\n" > "$_TTS_RECEIPT"
    tts_verify_spoken "The answer he never heard."')
grep -q "The answer he never heard." "$TRACE" \
    && ok "an empty receipt makes the caller speak the reply itself" || fail "no fallback speech" "$out"
grep -q "SPOKE NOTHING" "$T/st-speech.log" \
    && ok "…loudly, in the speech log" || fail "the failure must be logged" "$(cat "$T/st-speech.log" 2>/dev/null)"

: > "$TRACE"
out=$(TRACE="$TRACE" run '
    _TTS_RECEIPT="'"$T"'/some.receipt"
    printf "pid=1\nchars=42\nlines=2\nerror=\n" > "$_TTS_RECEIPT"
    tts_verify_spoken "Already said out loud."')
grep -q "Already said out loud." "$TRACE" \
    && fail "a reply already spoken must not be repeated" "$(cat "$TRACE")" \
    || ok "a reply that WAS spoken is not said twice"

: > "$TRACE"
out=$(TRACE="$TRACE" run '_TTS_RECEIPT="'"$T"'/none.receipt"; tts_verify_spoken "   "')
[ -z "$(cat "$TRACE")" ] && ok "an empty reply asks for no speech at all" || fail "spoke an empty reply" "$(cat "$TRACE")"

# `crab shutup` mid-reply is asked-for silence, and the guarantee must not
# undo it by cheerfully repeating the whole answer.
: > "$TRACE"
out=$(TRACE="$TRACE" run '
    _TTS_RECEIPT="'"$T"'/none.receipt"
    printf "pid=1\nchars=0\nlines=0\nerror=\n" > "$_TTS_RECEIPT"
    : > "$SHUTUP_MARKER"
    tts_verify_spoken "He asked me to stop talking."')
[ -z "$(cat "$TRACE")" ] && ok "after crab shutup the reply is NOT replayed" \
    || fail "shutup was overruled" "$(cat "$TRACE")"
out=$(run 'start_tts_streamer >/dev/null 2>&1; kill "$_TTS_STREAMER_PID" 2>/dev/null; [ -f "$SHUTUP_MARKER" ] && echo STALE || echo CLEARED')
[ "$out" = CLEARED ] && ok "a new turn clears the shutup marker" || fail "stale shutup marker" "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
