#!/usr/bin/env bash
# Proof that a second voice REGROUPS instead of being queued away or muted.
#
# The old answer to "another of me is already speaking" was a speech mutex plus
# a user_busy mute: the second session's words either waited behind a lock or
# were swallowed whole, and the second thing never got said. The design is the
# human one — stop, fold both things into ONE reply, say that. This test holds
# the new path to it:
#
#   1. no live speech            -> no block at all
#   2. another session speaking   -> the block, with its words VERBATIM
#   3. my own turn's voice        -> not another of me; no block
#   4. a speaker killed mid-word  -> stale record, no block
#   5. audio handed to the phone  -> no pid to watch, the estimate covers it
#   6. live_speech_end            -> clears only its OWN notice
#   7. build_system_prompt        -> the block actually reaches a real prompt
#   8. a whole wake beside a live voice -> the regrouped reply is SPOKEN, and
#      the nothing-new backstop does not eat it for overlapping by design
#
# Everything is stubbed and confined to the sandbox: no claude, no speakers,
# no notifications, no timers.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -euo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

# The stub claude: records the system prompt it was handed, then emits a reply
# that is a near-verbatim echo of what the other session is saying — the exact
# shape the nothing-new backstop would otherwise mute.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/claude-args.txt"
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"The backup finished and the archive verified clean, and the disk it landed on is nearly full."}]}}'
printf '%s\n' '{"type":"result"}'
EOF
# ffmpeg has to leave a non-empty file behind here: synth_opus only reports
# success when there is actually audio, and the phone path only publishes a
# voice that really exists.
sandbox_stub ffmpeg <<'EOF'
#!/bin/sh
cat > /dev/null
for a in "$@"; do out="$a"; done
printf 'opus' > "$out"
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
LAST_ORIGIN_FILE="$WORK/last-origin"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
PIPER_VOICE="$WORK/voice.onnx"
EOF
printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"

fail() { die "$*"; }

OTHER="Beatrice, the backup finished and the archive verified clean."

# --- 1-7: the record and the block, unit level ------------------------------
(
    # common.sh is not written for -u (optional config vars are read bare), so
    # drop it for the sourced half; the assertions below do their own checking.
    set +eu
    # shellcheck disable=SC1090
    source "$REPO/lib/common.sh"

    [ -z "$(regroup_context)" ] || fail "a block appeared with nobody speaking"

    # A stand-in for another session's voice: a live pid that is not us.
    sleep 60 & SPEAKER=$!

    live_speech_begin desk "$OTHER" "$SPEAKER"
    BLOCK="$(regroup_context)"
    printf '%s' "$BLOCK" | grep -q "ANOTHER OF YOU IS SPEAKING RIGHT NOW" \
        || fail "no regroup block while another session is speaking"
    printf '%s' "$BLOCK" | grep -qF "$OTHER" \
        || fail "the other reply did not reach the block verbatim"
    printf '%s' "$BLOCK" | grep -qi "REGROUP" \
        || fail "the block does not ask for a regrouped reply"
    printf '%s' "$BLOCK" | grep -qi "Do NOT queue your point for later" \
        || fail "the block does not forbid queueing the second thought away"

    # My own turn's voice is not another of me.
    live_speech_begin desk "$OTHER" "$$"
    [ -z "$(regroup_context)" ] || fail "regrouped against my own voice"
    _TTS_STREAMER_PID="$SPEAKER"
    live_speech_begin desk "$OTHER" "$SPEAKER"
    [ -z "$(regroup_context)" ] || fail "regrouped against my own turn's streamer"
    unset _TTS_STREAMER_PID

    # A speaker killed mid-word leaves its record behind; the dead pid catches it.
    kill "$SPEAKER" 2>/dev/null
    wait "$SPEAKER" 2>/dev/null
    live_speech_begin desk "$OTHER" "$SPEAKER"
    [ -z "$(regroup_context)" ] || fail "regrouped against a dead speaker's stale record"

    # Audio handed to the phone: no pid to watch, an estimated end time instead.
    live_speech_begin phone "$OTHER" "$SPEAKER" "$(( $(date +%s) + 30 ))"
    printf '%s' "$(regroup_context)" | grep -q "on the phone" \
        || fail "handed-off phone audio did not count as a live voice"

    # A notice belongs to whoever wrote it.
    sleep 60 & OTHERPID=$!
    live_speech_begin desk "$OTHER" "$OTHERPID"
    live_speech_end
    [ -f "$LIVE_SPEECH_FILE" ] || fail "live_speech_end deleted another session's notice"
    live_speech_end "$OTHERPID"
    [ -f "$LIVE_SPEECH_FILE" ] && fail "live_speech_end did not clear its own notice"
    kill "$OTHERPID" 2>/dev/null

    # And it reaches a real prompt.
    sleep 60 & SPEAKER2=$!
    live_speech_begin desk "$OTHER" "$SPEAKER2"
    build_system_prompt | grep -qF "$OTHER" \
        || fail "the regroup block never reached the built system prompt"
    kill "$SPEAKER2" 2>/dev/null
    rm -f "$LIVE_SPEECH_FILE"
    exit 0
) || exit 1

# --- 8: a whole wake beside a voice, end to end -----------------------------
# The conversation already holds that sentence as an assistant message, so a
# reply echoing it is exactly what wake_says_nothing_new mutes. Regrouping was
# ASKED for here, so the overlap is the point and the reply must survive.
mkdir -p "$(dirname "$DESKCRAB_STATE_PREFIX")"
printf 'User: how did the backup go\n\nAssistant: %s\n\n' "$OTHER" > "${DESKCRAB_STATE_PREFIX}-convo.txt"

sleep 60 & SPEAKER=$!
printf '%s\tdesk\t%s\t0\n%s\n' "$(date +%s)" "$SPEAKER" "$OTHER" > "${DESKCRAB_STATE_PREFIX}-live-speech"

# …and that voice holds the speech mutex, as a real one does. It must delay
# this reply and nothing more: the mute that used to live in user_busy is what
# made the second thing never get said at all.
( flock 7; sleep 6 ) 7>"${DESKCRAB_STATE_PREFIX}-speech.lock" &
HOLDER=$!
sleep 0.5

WAKE_REASON="the nightly backup finished" "$REPO/crab" wake event "the nightly backup finished" >/dev/null 2>&1 || true
kill "$SPEAKER" "$HOLDER" 2>/dev/null || true

[ -f "$WORK/claude-args.txt" ] || fail "the wake never invoked claude"
grep -q "ANOTHER OF YOU IS SPEAKING RIGHT NOW" "$WORK/claude-args.txt" \
    || fail "the regroup block never reached the wake's real --append-system-prompt"
grep -qF "$OTHER" "$WORK/claude-args.txt" \
    || fail "the other session's words never reached the wake verbatim"

LOG="${DESKCRAB_STATE_PREFIX}-sessions.log"
[ -f "$LOG" ] || fail "the wake journaled nothing"
grep -q "nearly full" "$LOG" \
    || { echo "--- sessions log ---"; cat "$LOG"; \
         fail "the regrouped reply was swallowed instead of spoken"; }
grep -q "muted — said nothing" "$LOG" \
    && fail "the nothing-new backstop ate a reply it was asked to regroup"
grep -q "muted — user was mid-interaction" "$LOG" \
    && fail "another of my own voices counted as the user being busy"

# --- 9: the desk streamer publishes as it speaks, and retracts when done ----
# The wake above was handed a record written by hand. This is the real writer:
# lib/tts-streamer, mid-stream, with the words it is putting on the speakers.
STREAMLOG="$WORK/stream.log"
: > "$STREAMLOG"
rm -f "${DESKCRAB_STATE_PREFIX}-live-speech"
DESKCRAB_DEBUGLOG="$STREAMLOG" DESKCRAB_PIPER_VOICE="$WORK/voice.onnx" \
    DESKCRAB_LIVE_SPEECH="${DESKCRAB_STATE_PREFIX}-live-speech" \
    "$REPO/lib/tts-streamer" &
STREAMER=$!
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Half of it is said already."}]}}' >> "$STREAMLOG"
for _ in $(seq 50); do
    [ -f "${DESKCRAB_STATE_PREFIX}-live-speech" ] && break
    sleep 0.1
done
[ -f "${DESKCRAB_STATE_PREFIX}-live-speech" ] || fail "the streamer spoke without publishing what it is saying"
grep -qF "Half of it is said already." "${DESKCRAB_STATE_PREFIX}-live-speech" \
    || fail "the streamer's notice does not hold the words it is speaking"
[ "$(head -n 1 "${DESKCRAB_STATE_PREFIX}-live-speech" | cut -f3)" = "$STREAMER" ] \
    || fail "the streamer's notice does not carry its own pid"

printf '%s\n' '{"type":"result"}' >> "$STREAMLOG"
wait "$STREAMER" 2>/dev/null || true
[ -f "${DESKCRAB_STATE_PREFIX}-live-speech" ] && fail "the streamer kept the floor after it finished speaking"

# --- 10: an interactive turn regroups too, not just a wake ------------------
# Driven through the phone turn, which shares claude_generate — and therefore
# build_system_prompt — with the desk turn. The desk turn is deliberately NOT
# driven here: start_tts_streamer pkills every tts-streamer on the machine by
# path, which would cut the LIVE desk off mid-word to run a test.
rm -f "$WORK/claude-args.txt"
sleep 60 & SPEAKER=$!
printf '%s\tphone\t%s\t0\n%s\n' "$(date +%s)" "$SPEAKER" "$OTHER" > "${DESKCRAB_STATE_PREFIX}-live-speech"
"$REPO/crab" remote "and what about the disk" >/dev/null 2>&1 || true
kill "$SPEAKER" 2>/dev/null || true

grep -q "ANOTHER OF YOU IS SPEAKING RIGHT NOW" "$WORK/claude-args.txt" \
    || fail "an interactive turn was not told another of me had the floor"
grep -qF "$OTHER" "$WORK/claude-args.txt" \
    || fail "the other voice's words never reached the interactive turn"
# And that turn publishes its own reply for whoever starts next.
grep -qF "nearly full" "${DESKCRAB_STATE_PREFIX}-live-speech" \
    || fail "the phone turn's reply was never published for the next session"
rm -f "${DESKCRAB_STATE_PREFIX}-live-speech"

ok "another voice -> regroup block -> one folded reply, nothing dropped"
