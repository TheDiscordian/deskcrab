#!/usr/bin/env bash
# Proof that a second voice REGROUPS instead of being queued away or muted —
# and that a voice he has ALREADY ANSWERED is not a second voice at all.
#
# The old answer to "another of me is already speaking" was a speech mutex plus
# a user_busy mute: the second session's words either waited behind a lock or
# were swallowed whole, and the second thing never got said. The design is the
# human one — stop, fold both things into ONE reply, say that. The other half
# of the design is knowing when there is no second voice: a record left behind
# by a reply that has been delivered, read and answered is a record about the
# past, and regrouping against it is an instruction to say it all again. This
# test holds both halves:
#
#    1. no live speech             -> no block at all
#    2. another session speaking    -> the block, with its words VERBATIM
#    3. my own turn's voice         -> not another of me; no block
#    4. a speaker killed mid-word   -> stale record, no block
#    5. audio handed to the phone   -> no pid to watch, the estimate covers it
#    6. a pidless record past its estimate -> NOT a voice. `kill -0 0` is not a
#       liveness test: it signals the whole process group and always succeeds,
#       so every pidless record read as a living speaker for the full window
#    7. the end time a hand-off publishes is the CLIP's own length
#    8. words already standing as her last transcript block -> no block: the
#       transcript delivers them once, and a second copy carrying "fold it in
#       and carry it forward" is an instruction to restate what he has read
#    9. a message from a device retires THAT device's notice, and only that one
#   10. a desk turn retires the desk notice before its prompt is built
#   11. live_speech_end             -> clears only its OWN notice
#   12. build_system_prompt         -> the block actually reaches a real prompt
#   13. a whole wake beside a live voice -> the regrouped reply is SPOKEN, and
#       the nothing-new backstop does not eat it for overlapping by design
#   14. the desk streamer publishes as it speaks, and retracts when done
#   15. an interactive turn regroups against the OTHER device's voice
#   16. the live regression, end to end: two phone messages in a row, and the
#       second turn is never handed her own delivered reply to fold in
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
# ffmpeg has to leave a plausible clip behind here: synth_opus only reports
# success when there is actually audio — anything under 256 bytes is the
# header-only husk a dead synthesiser leaves — and the phone path only
# publishes a voice that really exists.
sandbox_stub ffmpeg <<'EOF'
#!/bin/sh
cat > /dev/null
for a in "$@"; do out="$a"; done
head -c 4096 /dev/zero > "$out"
EOF
# ffprobe answers the only question the hand-off has: how long does this clip
# play for. 12.4 seconds of audio, whatever the stub ffmpeg actually wrote.
sandbox_stub ffprobe <<'EOF'
#!/bin/sh
for a in "$@"; do f="$a"; done
[ -s "$f" ] || exit 1
printf '12.400000\n'
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
CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
mkdir -p "$(dirname "$DESKCRAB_STATE_PREFIX")"

# --- 1-12: the record and the block, unit level -----------------------------
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
    live_speech_begin phone "$OTHER" 0 "$(( $(date +%s) + 30 ))"
    printf '%s' "$(regroup_context)" | grep -q "on the phone" \
        || fail "handed-off phone audio did not count as a live voice"

    # …and the same record once that end time has passed is NOT a voice. This
    # is the hole the whole regression came through: the pid is 0, `kill -0 0`
    # signals the caller's own process group and always succeeds, so the record
    # read as a living speaker for the full LIVE_SPEECH_WINDOW no matter how
    # long ago the audio actually stopped.
    live_speech_begin phone "$OTHER" 0 "$(( $(date +%s) - 5 ))"
    [ -z "$(regroup_context)" ] \
        || fail "a pidless record whose estimate has run out still counted as a voice"
    live_speech_begin phone "$OTHER" 1 "$(( $(date +%s) - 5 ))"
    [ -z "$(regroup_context)" ] || fail "pid 1 counted as a living speaker"

    # The end time a hand-off publishes comes from the clip, not from a guess
    # about how fast piper talks.
    printf 'opus' > "$WORK/clip.opus"
    LEFT=$(( $(_speech_until "$WORK/clip.opus" "$OTHER") - $(date +%s) ))
    [ "$LEFT" -ge 12 ] && [ "$LEFT" -le 14 ] \
        || fail "the handed-off end time is not the clip's own length (got ${LEFT}s)"
    # No clip to measure: an estimate, and it is documented as one.
    LEFT=$(( $(_speech_until "$WORK/nothing-here.opus" "$OTHER") - $(date +%s) ))
    [ "$LEFT" -gt 0 ] || fail "an unmeasurable clip published no end time at all"

    # Words that are already the last thing she said in the transcript are not
    # news to fold in — the prompt carries them one layer up, and a second copy
    # under "fold it in and carry it forward" is how a reply gets restated at
    # somebody who has read it. That holds for a HANDED-OFF reply: the bubble is
    # delivery, and the end time on the record is only an estimate about a clip
    # on his phone.
    printf 'User [12:00]: how did the backup go\nAssistant [12:01]: %s\n\n' "$OTHER" > "$CONVO"
    live_speech_begin phone "$OTHER" 0 "$(( $(date +%s) + 120 ))"
    [ -z "$(regroup_context)" ] || fail "regrouped against her own last transcript block"
    # A voice saying something the transcript does NOT hold still regroups.
    live_speech_begin phone "and the disk it landed on is nearly full" 0 "$(( $(date +%s) + 120 ))"
    [ -n "$(regroup_context)" ] \
        || fail "a voice saying something new was silenced by the transcript check"

    # ...but a voice this machine can WATCH is a different thing entirely. A
    # desk reply lands in the transcript while the streamer is still saying it,
    # so the test above matched on every ordinary desk turn and stood the
    # regroup down against a sentence that was audibly still coming out of the
    # speakers. A live pid is a process making sound right now, and it keeps its
    # regroup whatever the transcript already holds.
    sleep 60 & SPEAKER3=$!
    live_speech_begin desk "$OTHER" "$SPEAKER3"
    [ -n "$(regroup_context)" ] \
        || fail "a live desk voice was silenced by its own words landing in the transcript"
    kill "$SPEAKER3" 2>/dev/null; wait "$SPEAKER3" 2>/dev/null || true
    # And once that process is gone — REAPED, not merely signalled; `kill -0`
    # answers yes for a zombie — the words are delivered like any others.
    live_speech_begin desk "$OTHER" "$SPEAKER3" "$(( $(date +%s) + 120 ))"
    [ -z "$(regroup_context)" ] \
        || fail "a finished desk voice still regrouped against its own transcript block"
    rm -f "$CONVO"

    # A message from him is a receipt: it retires THAT device's notice, and
    # leaves the other device's alone.
    live_speech_begin phone "$OTHER" 0 "$(( $(date +%s) + 30 ))"
    live_speech_retire desk
    [ -f "$LIVE_SPEECH_FILE" ] || fail "a desk message retired the phone's notice"
    live_speech_retire phone
    [ ! -f "$LIVE_SPEECH_FILE" ] || fail "a phone message did not retire the phone's notice"

    # A receipt is not a receipt for words still coming out of the speakers. He
    # typed at the desk while the desk was mid-sentence: that is talking OVER
    # her, and retiring the notice hands the new turn a prompt saying nothing
    # else of her is speaking — so she answers straight over the top of her own
    # sentence, with no regroup and no idea it was happening.
    sleep 60 & MIDWORD=$!
    live_speech_begin desk "$OTHER" "$MIDWORD"
    live_speech_retire desk
    [ -f "$LIVE_SPEECH_FILE" ] \
        || fail "a message arriving mid-utterance retired a voice that was still speaking"
    kill "$MIDWORD" 2>/dev/null; wait "$MIDWORD" 2>/dev/null || true
    # The moment that process is gone, the ordinary receipt applies again.
    live_speech_retire desk
    [ ! -f "$LIVE_SPEECH_FILE" ] \
        || fail "a finished desk voice was never retired by his next message"

    # And the desk turn does the retiring where it counts: before its prompt is
    # built. The record here is pidless with time still on the clock, which is
    # exactly what a reply just delivered to this desk leaves behind.
    rm -f "$WORK/claude-args.txt"
    live_speech_begin desk "$OTHER" 0 "$(( $(date +%s) + 120 ))"
    run_claude_and_respond "how did that go" >/dev/null 2>&1
    grep -q "ANOTHER OF YOU IS SPEAKING RIGHT NOW" "$WORK/claude-args.txt" \
        && fail "the desk turn regrouped against a notice the user had just answered"
    rm -f "$CONVO" "$LIVE_SPEECH_FILE"

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

# --- 13: a whole wake beside a voice, end to end ----------------------------
# The other session is still MID-UTTERANCE: its reply is on the speakers and has
# not landed in the transcript yet, so this is a genuinely concurrent voice and
# the block is owed. (Once those words ARE her last transcript block the rule is
# the opposite one, held by case 8 above.) The stub reply echoes them almost
# whole, which is what a regrouped reply looks like — the overlap is the point
# and nothing downstream may swallow the reply for it.
printf 'User [%s]: how did the backup go\n\n' "$(date '+%Y-%m-%d %H:%M')" > "$CONVO"

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

# --- 14: the desk streamer publishes as it speaks, and retracts when done ---
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

# --- 15: an interactive turn regroups too, not just a wake ------------------
# Driven through the phone turn, which shares claude_generate — and therefore
# build_system_prompt — with the desk turn. The voice it regroups against is on
# the DESK: a message from the phone retires the phone's own notice (case 16),
# and the other device's voice is one he has not answered.
rm -f "$WORK/claude-args.txt" "$CONVO"
sleep 60 & SPEAKER=$!
printf '%s\tdesk\t%s\t0\n%s\n' "$(date +%s)" "$SPEAKER" "$OTHER" > "${DESKCRAB_STATE_PREFIX}-live-speech"
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

# --- 16: the live regression, end to end ------------------------------------
# Two phone messages in a row, which is all it took: her first reply was handed
# to the phone and published with no pid, the pidless record read as a living
# voice, and the second turn was told to fold in — "carry it forward", "do not
# restate" — a reply he had already read and answered. It came back as the
# first reply again, near verbatim, with one clause added. The second turn's
# prompt must carry those words exactly once: in the transcript, where they are
# something she said, not in a block telling her they are still being said.
rm -f "$WORK/claude-args.txt" "$CONVO" "${DESKCRAB_STATE_PREFIX}-live-speech"
"$REPO/crab" remote "how did the backup go" >/dev/null 2>&1 || true

[ -f "${DESKCRAB_STATE_PREFIX}-live-speech" ] \
    || fail "the first phone turn published nothing for the next session"
UNTIL="$(head -n 1 "${DESKCRAB_STATE_PREFIX}-live-speech" | cut -f4)"
LEFT=$(( UNTIL - $(date +%s) ))
[ "$LEFT" -ge 11 ] && [ "$LEFT" -le 14 ] \
    || fail "the phone turn's end time is not the clip's own length (got ${LEFT}s)"

"$REPO/crab" remote "and what about the disk" >/dev/null 2>&1 || true
grep -q "ANOTHER OF YOU IS SPEAKING RIGHT NOW" "$WORK/claude-args.txt" \
    && fail "his own answer left her being told she was still speaking to him"
grep -qi "fold it in" "$WORK/claude-args.txt" \
    && fail "the next turn was told to fold in a reply he had already answered"
grep -qF "nearly full" "$WORK/claude-args.txt" \
    || fail "the transcript stopped carrying the reply it is supposed to deliver"
rm -f "${DESKCRAB_STATE_PREFIX}-live-speech"

ok "another voice -> regroup block -> one folded reply, nothing dropped"
ok "a voice he has answered is not another voice — no restatement pressure"
