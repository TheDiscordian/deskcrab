#!/usr/bin/env bash
# Quiet hours: the night suppresses the speakers AND the screen.
# Run: bash tests/test_quiet_hours.sh
#
# specs/wake-queue.md rule 27, defect MIN-16. The code returned before both the
# voice and the window while the comment beside it said busyness suppressed
# "OUTPUT only", so the one thing nobody could answer from the source was
# whether a window at three in the morning was intended or an accident. It is
# intended: a window is quieter than a voice but it is not nothing — it takes
# focus, it lights a dark room, and a night of them is a desk covered in
# windows by morning. The wake is told as much on its way in ("speaking and
# windows are suppressed — work silently") and the knob has always been
# documented as fully silent. This file is where that stops being a comment.
#
# Every scratch configuration in this suite sets WAKE_QUIET_HOURS to empty, so
# until now nothing in the repo exercised the branch at all — specs/test-harness
# .md rule 22 lists quiet hours among the subsystems with no test.
#
# The control case is the half that matters: a wake with the same reply, the
# same display section and the same stubs, outside quiet hours, MUST be heard
# and MUST open a window. Without it, "nothing was displayed" would be equally
# true of a test that cannot see a display at all.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

SPEECH="The hallway lantern is rewired and the equinox lights work again."
SHOWN="## What the wiring looked like"

# The stub CLI: one reply, with a display section under it, so both delivery
# channels have something to carry. It also records the argv it was handed,
# which is where the wake's AGENDA arrives — the only place a test can read
# what the wake was actually told.
stub_reply() {  # <reply text, \n for newlines>
    sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "\$*" > "$WORK/argv.txt"
python3 - <<'PYEOF'
import json
text = "$1"
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result", "result": text}))
PYEOF
EOF
}
stub_reply "$SPEECH\n---DISPLAY---\n$SHOWN\n"

# The three witnesses, each at the boundary that matters: piper-tts stdin is
# the only thing on this machine that turns text into sound, render-md is the
# only thing that opens a window, and notify-send is the popup.
sandbox_stub piper-tts <<EOF
#!/usr/bin/env bash
cat >> "$WORK/spoken.txt"
EOF
sandbox_stub render-md <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/displayed.txt"
EOF
sandbox_stub notify-send <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/notified.txt"
EOF

CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
JOURNAL="${DESKCRAB_STATE_PREFIX}-sessions.log"

# A window that certainly contains the hour this test is running in, written
# the way the knob is written. The hour after it closes the window, and 24 is
# a legal end for an hour of 23 — start <= end is the non-wrapping branch.
HOUR="$(date +%-H)"
NOW_WINDOW="$HOUR-$(( HOUR + 1 ))"

write_conf() {  # <quiet hours value>
    cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
WANTS_FILE="$WORK/wants.md"
PIPER_VOICE="$WORK/voice.onnx"
WAKE_QUIET_HOURS="$1"
EOF
}
printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"

run_wake() {
    rm -f "$WORK/spoken.txt" "$WORK/displayed.txt" "$WORK/notified.txt" "$CONVO"
    WAKE_REASON="a scheduled look at the wants" \
        "$REPO/crab" wake event "a scheduled look at the wants" >/dev/null 2>&1 || true
}

echo "the window is read the way the knob is written:"
# Cheap and at unit level, because the branch has never been executed by a test
# and the wrapping case is the one that is actually configured.
quiet_at() {  # <hour> <window>
    sandbox_bash "date() { printf '%s' $1; }
                  WAKE_QUIET_HOURS='$2'
                  in_quiet_hours && printf yes || printf no"
}
check_eq "23-09 is quiet at three in the morning" "$(quiet_at 3 23-09)" "yes"
check_eq "and quiet at eleven at night, the hour it opens" "$(quiet_at 23 23-09)" "yes"
check_eq "and over at nine, the hour it closes" "$(quiet_at 9 23-09)" "no"
check_eq "and not quiet at noon" "$(quiet_at 12 23-09)" "no"
check_eq "a non-wrapping window works the same way" "$(quiet_at 14 13-15)" "yes"
check_eq "an empty setting means no quiet hours at all" "$(quiet_at 3 '')" "no"

echo
echo "inside quiet hours a wake speaks to nobody and shows nobody anything:"
write_conf "$NOW_WINDOW"
run_wake
check "nothing was synthesized" [ ! -f "$WORK/spoken.txt" ]
check "NO WINDOW WAS OPENED — the renderer was never called" \
    [ ! -f "$WORK/displayed.txt" ]
check "no notification was raised" [ ! -f "$WORK/notified.txt" ]
check "and nothing was appended to the conversation, so the phone stays quiet too" \
    bash -c '[ ! -s "$1" ]' _ "$CONVO"

echo
echo "...and the record says the night held it, not that she had nothing:"
# The difference is load-bearing. A wake suppressed by quiet hours journalled
# as though it had chosen silence is a wake whose held words read as an empty
# hour to the next session — and to the delta, which reads this same journal to
# decide what her last reply was.
check "the journal names quiet hours as the reason" \
    grep -q "quiet hours" "$JOURNAL"
check "and keeps the words that were held" grep -qF "$SPEECH" "$JOURNAL"

echo
echo "outside quiet hours the same wake is heard AND shown:"
# The control. Without it every assertion above is equally true of a test that
# cannot see a window in the first place.
write_conf ""
run_wake
check "it was synthesized" [ -f "$WORK/spoken.txt" ]
check "with the words it meant to say" grep -qF "The hallway lantern" "$WORK/spoken.txt"
check "the renderer WAS called, so the window is reachable from here" \
    [ -f "$WORK/displayed.txt" ]
check "a notification was raised" [ -f "$WORK/notified.txt" ]
check "and the reply is in the conversation" grep -qF "$SPEECH" "$CONVO"

echo
echo "a wake the night held says so even when it had no words to hold:"
# specs/wake-queue.md rule 27's sub-bullet, and the half that was missing: the
# line was written only when there were SPOKEN words, so a wake that built a
# chart and a wake that left a (quiet) thought both journalled as ordinary
# silence — "(silent — ran no tools, touched nothing)" — which reads to the
# next session, and to the delta anchored on this same journal, as an hour in
# which she had nothing to say. It was the night, and the record has to say so.
write_conf "$NOW_WINDOW"
stub_reply "---DISPLAY---\n$SHOWN\n"
run_wake
check "the display-only wake reached no renderer" [ ! -f "$WORK/displayed.txt" ]
check "and its journal line names the night, not silence" \
    bash -c 'tail -n1 "$1" | grep -q "quiet hours"' _ "$JOURNAL"

stub_reply "(quiet) I sat with the second movement for a while.\n"
run_wake
check "a held (quiet) bubble is journalled as the night too" \
    bash -c 'tail -n1 "$1" | grep -q "quiet hours"' _ "$JOURNAL"
check "and the thought it was holding survives into the record" \
    bash -c 'tail -n1 "$1" | grep -q "second movement"' _ "$JOURNAL"
stub_reply "$SPEECH\n---DISPLAY---\n$SHOWN\n"

echo
echo "the wake is told, in words, what quiet hours will do to it:"
# The suppression is silent by design, so the only way she can account for a
# night that produced no windows is to have been told on the way in.
#
# Asserted on what the wake was HANDED, not on the source of `crab`. A grep of
# the shipping file passes just as well when the sentence survives only in the
# comment beside the code that no longer emits it — and it would not notice the
# line moving to a file the grep does not read.
write_conf "$NOW_WINDOW"
run_wake
check "the agenda the wake actually received says speaking and windows are both suppressed" \
    grep -q "speaking and windows are suppressed" "$WORK/argv.txt"
