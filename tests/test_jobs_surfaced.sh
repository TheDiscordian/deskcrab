#!/bin/bash
# A failed job's one-time news must not be eaten by a wake nobody heard.
# Run: bash tests/test_jobs_surfaced.sh
#
# specs/self-awareness.md rule 31, specs/jobs.md rule 24, defect MAJ-12.
#
# A job that ended badly is news exactly once: it is surfaced, capped, and
# stamped, and after that it is history — history under a "right now" heading
# is how a build that died at 02:06 came to sit in the block all day beside
# four running jobs. But the stamp was written every time the block was
# RENDERED, and a block is rendered for every session including the ones that
# end in silence. So a wake that fired at three in the morning, said nothing to
# anybody, and exited took the news with it. The next session that could
# actually have told him never saw it.
#
# The stamp is now written at DELIVERY: the render leaves a pending stamp keyed
# to its own process, and only the three delivery points — a desk turn, a phone
# turn, and a wake that got past every gate — spend it. A session that ends
# without delivering drops its own pending stamp on the way out.
#
# Both wakes below are real wakes, run as their own processes exactly as
# `crab wake` runs them, against a stubbed CLI. The difference between them is
# only whether anybody was listening.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
T="$SANDBOX"
J="$JOBS_DIR"
mkdir -p "$J"

REPLY="The kettle in the east wing has finally been descaled."
sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"$REPLY"}]}}'
printf '%s\n' '{"type":"result"}'
EOF

cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$T/home"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
WANTS_FILE="$T/wants.md"
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
WAKE_QUIET_HOURS=""
CLAUDE_BIN="$SANDBOX_BIN/claude"
CONF
printf '# Wants\n\n- a want, so the wake path is enabled at all\n' > "$T/wants.md"

NOW="$(date +%s)"
MARKER="$DESKCRAB_STATE_PREFIX-jobs-surfaced"
PIDFILE="$T/rec.pid"

# A build that died half a minute ago, and a marker saying the last turn was
# ten minutes before that — so the failure IS news.
cat > "$J/broken.json" <<EOF
{"id":"broken","description":"a build that died since the last turn","state":"failed",
 "exit":1,"started_epoch":$(( NOW - 300 )),"finished_epoch":$(( NOW - 30 )),
 "finished":"2026-08-07 12:00:00"}
EOF
printf '%s' "$(( NOW - 600 ))" > "$MARKER"

block() { sandbox_bash 'self_state_report --prompt' 2>/dev/null; }
has()   { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
stamp() { cat "$MARKER" 2>/dev/null; }
# Pending stamps are keyed to the pid that rendered the block, so a count is
# only meaningful against a known starting point: cleared before each session,
# counted after it. `block` below is a bare render, not a registered session —
# nothing sweeps its stamp, which is why the count is taken per session rather
# than over the directory's whole history.
pendings() { ls "$MARKER".pending-* 2>/dev/null | wc -l; }
clear_pendings() { rm -f "$MARKER".pending-*; }

# A wake, as its own process, exactly as `crab wake` runs one. PIDFILE is set
# by hand because `crab` sets it, not lib/common.sh, and user_busy is what
# reads it — holding push-to-talk is what makes a wake silent.
wake() { # <reason>
    bash -c '
        . "$1/lib/common.sh"
        PIDFILE="$2"
        WAKE_REASON="$3"
        run_claude_wake "(Autonomous wake — test)"
    ' _ "$REPO" "$PIDFILE" "$1" >/dev/null 2>&1
}

echo "the news is there to begin with, and rendering it does not spend it:"
OUT="$(block)"
check "the failed build is surfaced as news" has "ENDED SINCE YOUR LAST TURN" "$OUT"
check "and it is named" has "a build that died since the last turn" "$OUT"
check_eq "the durable stamp has not moved — rendering is not delivering" \
    "$(stamp)" "$(( NOW - 600 ))"
check_eq "what it left instead is a PENDING stamp, unspent" "$(pendings)" "1"

echo
echo "a wake that nobody hears does NOT spend the news:"
# The user is mid-recording, so every output is suppressed. The wake still
# runs — busyness is a reason to hold the tongue, not the mind — and it still
# builds a prompt, which renders this block. What it must not do is consume a
# piece of news it never told anyone.
touch "$PIDFILE"
clear_pendings
wake "a wake beside a live turn"
check_eq "the wake was silent — nothing reached the conversation" \
    "$(grep -c 'Assistant' "$DESKCRAB_STATE_PREFIX-convo.txt" 2>/dev/null || echo 0)" "0"
check_eq "the stamp is exactly where it was" "$(stamp)" "$(( NOW - 600 ))"
check_eq "and the silent session dropped its own pending stamp on the way out" \
    "$(pendings)" "0"

OUT="$(block)"
check "so the next session still sees the news" has "ENDED SINCE YOUR LAST TURN" "$OUT"
check "with the build still named" has "a build that died since the last turn" "$OUT"

echo
echo "a wake that IS heard spends it, once:"
rm -f "$PIDFILE"
clear_pendings
: > "$DESKCRAB_STATE_PREFIX-convo.txt"
wake "a wake with the room to itself"
check "the wake was delivered — its words reached the conversation" \
    grep -q "$REPLY" "$DESKCRAB_STATE_PREFIX-convo.txt"
check "the stamp moved forward, so the news has been told" \
    [ "$(stamp)" -gt "$(( NOW - 600 ))" ]
check_eq "and nothing is left pending" "$(pendings)" "0"

OUT="$(block)"
check "the next block does not repeat it" \
    bash -c '! printf "%s" "'"$(printf '%s' "$OUT" | tr '\n' ' ')"'" | grep -q "ENDED SINCE YOUR LAST TURN"'
check "the job itself is still one command away, not erased" \
    bash -c '"'"$REPO"'/lib/job-status" report "'"$J"'" 6 14 | grep -q "a build that died since the last turn"'

echo
echo "the stamp is keyed to the session that rendered it, not shared:"
# Two sessions rendering at once must not spend each other's news. The pending
# stamp carries the rendering process's own pid for exactly that reason.
printf '%s' "$(( NOW - 600 ))" > "$MARKER"
sandbox_bash 'jobs_report --live --defer >/dev/null; ls "$STATE_PREFIX-jobs-surfaced".pending-$$ >/dev/null 2>&1 && echo KEYED' \
    2>/dev/null > "$T/keyed.out"
clear_pendings
check "the deferred stamp is written under the renderer's own pid" \
    grep -q KEYED "$T/keyed.out"
check_eq "and the durable stamp still has not moved" "$(stamp)" "$(( NOW - 600 ))"

# ...and delivering, in that same process, is what promotes it.
out="$(sandbox_bash 'jobs_report --live --defer >/dev/null; jobs_news_delivered; cat "$STATE_PREFIX-jobs-surfaced"' 2>/dev/null)"
check "delivery promotes the pending stamp to the durable one" \
    [ "${out:-0}" -gt "$(( NOW - 600 ))" ]
