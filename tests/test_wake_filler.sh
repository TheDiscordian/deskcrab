#!/usr/bin/env bash
# Proof that a wake which announces its own silence is never heard.
#
# He heard "Nothing to say." spoken ALOUD, from an autonomous wake, more than
# once. Conduct forbids exactly that: a wake with nothing to say must produce
# no message text at all, never a sentence announcing that there is no
# sentence. The backstop that was supposed to catch it structurally could not —
# wake_says_nothing_new bails with `if len(mine) < 4: let it speak`, and the
# content words of "Nothing to say." after stopword removal are {nothing, say},
# two. The shortest, most contentless replies were the only ones it could never
# reach.
#
# So this holds the whole path to the promise, from both ends:
#
#   1. the corpus, at unit level — every filler shape mutes, and every real
#      reply that merely CONTAINS "nothing"/"quiet"/"silence" speaks
#   2. fillers through the REAL wake path — nothing synthesized, nothing
#      notified, no bubble in the conversation, and the words kept in the
#      journal where a wake nobody heard belongs
#   3. a genuine reply through the same path — spoken, notified, bubbled
#
# Part 3 is the half that matters most. He has been burned repeatedly by fixes
# that swallow real replies, so a green run here has to mean the gate removes
# filler and nothing else; a mute that ate "Nothing in the log explains the
# crash." would be a worse bug than the one being fixed.
#
# Everything is stubbed and confined to a mktemp dir: no claude, no speakers,
# no notifications, no timers, no memory, no network.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/deskcrab-wake-filler-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export DESKCRAB_STATE_PREFIX="$WORK/state"
export DESKCRAB_CONF="$WORK/conf"
export CLAUDE_BIN="$WORK/bin/claude"
# user_busy reads the recording pidfile, which otherwise defaults to a fixed
# /tmp path shared with the LIVE desk — without this the suite is muted at
# random by someone holding push-to-talk on the real machine, and the mute
# would read as this gate working when it had not run at all.
export DESKCRAB_PIDFILE="$WORK/whisper.pid"

mkdir -p "$WORK/bin"

# The stub claude: replies with whatever the case under test put in reply.txt.
cat > "$WORK/bin/claude" <<EOF
#!/usr/bin/env bash
cat > /dev/null
python3 - "$WORK/reply.txt" <<'PYEOF'
import json, sys
text = open(sys.argv[1]).read()
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result", "result": text}))
PYEOF
EOF
chmod +x "$WORK/bin/claude"

# piper-tts is the ONLY thing that turns text into sound on this machine, so
# its stdin is the honest answer to "was this spoken?" — not a log line
# claiming it was.
cat > "$WORK/bin/piper-tts" <<EOF
#!/usr/bin/env bash
cat >> "$WORK/spoken.txt"
EOF
chmod +x "$WORK/bin/piper-tts"

# Same for the notification: record the fact, produce nothing.
cat > "$WORK/bin/notify-send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/notified.txt"
EOF
chmod +x "$WORK/bin/notify-send"

cat > "$WORK/bin/render-md" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/displayed.txt"
EOF
chmod +x "$WORK/bin/render-md"

# A test must never reach the desktop, the speakers, or the user manager.
# pactl is stubbed on purpose: user_busy asks it whether anything holds the
# microphone, and a real app recording while the suite runs would mute the
# wake for a legitimate reason and make this read as a regression.
for tool in aplay hyprctl ffmpeg systemd-run systemctl pactl; do
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$tool"
    chmod +x "$WORK/bin/$tool"
done
export PATH="$WORK/bin:$PATH"

cat > "$WORK/conf" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$WORK/bin/claude"
PROJECT_DIR="$WORK"
ARCHIVE_DIR="$WORK/archive"
JOBS_DIR="$WORK/jobs"
WAKES_DIR="$WORK/wakes"
DAY_JOURNAL_DIR="$WORK/journal"
NOTICE_STATE_DIR="$WORK/notice"
LAST_ORIGIN_FILE="$WORK/last-origin"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
PIPER_VOICE="$WORK/voice.onnx"
EOF
printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"

fail() { echo "FAIL: $*"; exit 1; }

# --- 1: the corpus, at unit level -------------------------------------------
# Sourced rather than driven, so every shape is covered cheaply. common.sh is
# not written for -u (optional config vars are read bare), so drop it here.
(
    set +eu
    # shellcheck disable=SC1090
    source "$REPO/lib/common.sh"

    # Filler: the whole utterance is the announcement. Every one of these has
    # to die before it reaches a speaker.
    FILLER=(
        "Nothing to say." "Nothing to report." "No update." "Nothing new."
        "Quiet here." "Nothing worth saying." "No message." "Nothing."
        "All quiet." "Nothing here." "No news." "Silence."
        "Nothing to add right now." "Nothing new to report." "*Nothing to say.*"
        "nothing to say" "Nothing much to add." "No comment."
        "Nothing to say for now." "Nothing further." "No changes to report."
        "I have nothing to add." "Nothing to report on my end." "Still quiet."
        "No news to report." "Nothing yet." "Okay, nothing to say."
        "Standing by." "I'm quiet." "No updates." "Nothing else."
        "Nothing of note." "Nothing new here." "No response."
        "Nothing to say, really." "All quiet here."
    )
    # Real speech that merely CONTAINS the words. Muting any of these is the
    # failure this gate must never become — several are shorter than the
    # fillers above, so no length rule can separate them. Only "is the whole
    # utterance the announcement" can.
    REAL=(
        "Nothing in the log explains the crash."
        "Nothing new in the repo, but the tests pass."
        "Quiet hours start at ten."
        "There is nothing wrong with the disk."
        "No update has landed on the memory branch yet."
        "Nothing to say about the backup."
        "I have nothing but the stream log."
        "The silence from the watcher is the bug."
        "Nothing to report except your disk is full."
        "No news is bad news."
        "Report is quiet."
        "Nothing changed the outcome."
        "The job finished."
        "Your backup failed."
        "Nothing works."
        "Quiet mode is on."
        "No update yet on job 128679."
        "Nothing to say to him."
        "Silence broke the watcher."
        "All quiet on the canary, but the embedder is down."
        "Nothing new, the disk is full."
        "No message reached the phone."
        "Nothing to add to the wants file."
        "Standing by the claim."
        "I have nothing to add to what you said."
        "Nothing of note in the log except the crash."
        "Still quiet on the disk, but the build broke."
        "I am quiet about it because the test failed."
    )
    for t in "${FILLER[@]}"; do
        wake_reply_is_filler "$t" || fail "filler would be spoken aloud: $t"
    done
    for t in "${REAL[@]}"; do
        wake_reply_is_filler "$t" && fail "real speech would be swallowed: $t"
    done
    echo "  ok: ${#FILLER[@]} filler shapes mute, ${#REAL[@]} real replies speak"
) || exit 1

# --- 2 & 3: the real wake path ----------------------------------------------
# Drive `crab wake` for real and read the machine's own evidence: piper-tts
# stdin for speech, notify-send for the popup, the conversation file for the
# bubble the phone would render.
run_wake() {  # <reply-text>
    printf '%s' "$1" > "$WORK/reply.txt"
    rm -f "$WORK/spoken.txt" "$WORK/notified.txt" "$WORK/displayed.txt"
    WAKE_REASON="a scheduled look at the wants" \
        "$REPO/crab" wake event "a scheduled look at the wants" >/dev/null 2>&1 || true
}

CONVO="$WORK/state-convo.txt"
JOURNAL="$WORK/state-sessions.log"

for t in "Nothing to say." "Nothing to report." "No update." "Quiet here." \
         "Nothing new." "No message." "Silence." "Nothing." ; do
    run_wake "$t"
    [ -f "$WORK/spoken.txt" ] \
        && { echo "--- synthesized ---"; cat "$WORK/spoken.txt"; \
             fail "filler reached the speakers: $t"; }
    [ -f "$WORK/notified.txt" ] \
        && { echo "--- notified ---"; cat "$WORK/notified.txt"; \
             fail "filler reached the notification popup: $t"; }
    [ -f "$WORK/displayed.txt" ] && fail "filler opened a window: $t"
    if [ -f "$CONVO" ] && grep -qF "$t" "$CONVO"; then
        echo "--- conversation ---"; cat "$CONVO"
        fail "filler was appended to the conversation as a bubble: $t"
    fi
done
echo "  ok: 8 fillers through the real wake path — nothing spoken, no bubble"

# The words are muted, not lost: the journal is where a wake nobody heard has
# always belonged, and losing the trace would make the mute unauditable.
[ -f "$JOURNAL" ] || fail "the muted wakes journaled nothing at all"
grep -q "filler" "$JOURNAL" \
    || { echo "--- journal ---"; cat "$JOURNAL"; \
         fail "the journal does not record what the mute swallowed"; }
grep -qF "Nothing to say." "$JOURNAL" \
    || fail "the swallowed words themselves are not in the journal"
echo "  ok: the muted words survive in the session journal"

# --- 3: a genuine reply must still be spoken, bubbled and shown -------------
# The word "nothing" is in it on purpose. This is the case he has been burned
# by, and a gate that cannot pass it is not worth having.
REAL_REPLY="Nothing in the log explains the crash, so I read the archived stream instead and the write came from your own hand at 07:44."
run_wake "$REAL_REPLY"
[ -f "$WORK/spoken.txt" ] \
    || fail "a genuine reply containing 'nothing' was never spoken"
grep -qF "Nothing in the log explains the crash" "$WORK/spoken.txt" \
    || { echo "--- synthesized ---"; cat "$WORK/spoken.txt"; \
         fail "the spoken text is not the reply"; }
[ -f "$WORK/notified.txt" ] || fail "a genuine reply raised no notification"
[ -f "$CONVO" ] && grep -qF "Nothing in the log explains the crash" "$CONVO" \
    || { echo "--- conversation ---"; cat "$CONVO" 2>/dev/null; \
         fail "a genuine reply left no bubble in the conversation"; }
echo "  ok: a genuine reply containing 'nothing' is spoken and bubbled"

# And one more, whose entire content is a short sentence about quiet — the
# shape closest to the filler corpus that is still real speech.
REAL_TWO="Quiet hours start at ten, so the canary will not wake you."
run_wake "$REAL_TWO"
[ -f "$WORK/spoken.txt" ] || fail "a genuine reply about quiet was swallowed"
grep -qF "Quiet hours start at ten" "$WORK/spoken.txt" \
    || fail "the second genuine reply was not the text spoken"
echo "  ok: a genuine short reply about 'quiet' is spoken"

echo "OK: silence is silent — filler muted whole, real speech untouched"
