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
# And then he heard the two-clause cousin (2026-08-10, recurring): "No message
# — the other session already said its piece." The single-clause gate let it
# through on the excuse. specs/wake-queue.md rule 29a now owns the shape: the
# no-op core with a silence-justification clause on either side, and the
# justification standing alone, all mute whole — while a justification-shaped
# opening followed by real content still speaks. The silent EXIT is covered
# here too: a wake that ends with no message text at all delivers nothing on
# any channel and is journalled as silence, because the empty reply is the
# documented default when another session already covered it.
#
# And then the FIRST person (2026-08-15, MAJ-36): five wakes on one
# browser-speed chess game fired inside ninety seconds, and the gate knew
# the announcement of silence only without a subject — "I've said my piece
# on that game twice already tonight", "I've nothing further on that game
# tonight" walked through it, two of them aloud. And at 01:07 the worst
# shape yet: a wake with genuinely EMPTY text arrived as the literal
# placeholder "*(no message text)*", and the desk read the absence out as
# words. Rule 29a now carries the first-person already-said core, the
# repeat-count justification, the topic phrase on speech-history cores
# only, and the bare absence placeholders.
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
# Everything is stubbed and confined to the sandbox: no claude, no speakers,
# no notifications, no timers, no memory, no network.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -euo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

# The stub claude: replies with whatever the case under test put in reply.txt,
# and records the argv it was handed — which is where the wake's AGENDA arrives,
# and the only place a test can read what the wake was actually told.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "\$*" > "$WORK/argv.txt"
python3 - "$WORK/reply.txt" <<'PYEOF'
import json, sys
text = open(sys.argv[1]).read()
print(json.dumps({"type": "assistant",
                  "message": {"model": "stub",
                              "content": [{"type": "text", "text": text}]}}))
print(json.dumps({"type": "result", "result": text}))
PYEOF
EOF

# piper-tts is the ONLY thing that turns text into sound on this machine, so
# its stdin is the honest answer to "was this spoken?" — not a log line
# claiming it was. These three witnesses are per-case (each run_wake clears
# them), which is why they are named here rather than read from the sandbox's
# own cumulative logs.
sandbox_stub piper-tts <<EOF
#!/usr/bin/env bash
cat >> "$WORK/spoken.txt"
EOF

sandbox_stub notify-send <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/notified.txt"
EOF

sandbox_stub render-md <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/displayed.txt"
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
LAST_ORIGIN_FILE="$WORK/last-origin"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
PIPER_VOICE="$WORK/voice.onnx"
EOF
printf '# Wants\n\n- **a want**, so the wake path is enabled at all\n' > "$WORK/wants.md"

fail() { die "$*"; }

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
        # Not a sentence but the CLI's own stringified nothing. Measured on
        # 2026-08-07: two of three real wakes that meant to end with no message
        # text arrived as an assistant text block holding the literal word
        # "undefined", and it was spoken aloud through the desk.
        "undefined" "Undefined."
        # The two-clause shape (rule 29a): the no-op core wearing a reason.
        # The first is the exact sentence he heard spoken aloud, 2026-08-10.
        "No message — the other session already said its piece."
        "Nothing to say — the other session covered it."
        "Nothing to add; nothing has changed since the last wake."
        "Nothing new — he already heard it."
        "Staying quiet — the desk session is answering him right now."
        "No message; everything was already said."
        "Nothing to say, that was already covered by the other session."
        "Nothing from me — the other session said it all."
        "Quiet — the other session beat me to it."
        "Well, nothing to add — the other session got there first."
        # …and the reason standing alone as the whole reply.
        "The other session already said its piece."
        "The other session already covered it."
        "Nothing changed."
        "Nothing has changed since then."
        # The first-person shapes and the topic phrase (2026-08-15, rule
        # 29a): five wakes on one browser-speed chess game inside ninety
        # seconds, two of them aloud. The first four are the exact
        # sentences the night produced.
        "I've said my piece on that game twice already tonight."
        "I've said everything I have about that game tonight."
        "I've nothing further on that game tonight."
        "Fifth time round on the same game tonight — nothing further from me on it."
        "I've said my piece."
        "Said my piece already."
        "I've said enough."
        "Nothing further on it."
        "Nothing more about that game."
        "Nothing new on that board tonight."
        # The stringified absence (2026-08-15, 01:07): a wake with genuinely
        # EMPTY text arrived as this literal placeholder, and the desk read
        # the absence out as the words "no message text".
        "*(no message text)*"
        "(no message text)"
        "no message text"
        "Empty."
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
        "The config value is undefined."
        "Undefined is what the recall block returned."
        # Justification-shaped openings with real content behind them. The
        # two-clause gate must break on the content and speak every one.
        "The other session answered him, but the job it mentioned has since failed."
        "The other session missed the point — the disk is still full."
        "The other session said the tests were green, but they are not."
        "Nothing to say about the merge — the rebase broke two tests."
        "Nothing has changed his mind."
        "Nothing changed the outcome."
        "It was already said to be flaky before tonight."
        "Everything was covered in dust after the build."
        "He already heard back from the recruiter."
        # Contentless-looking but ambiguous: could be a real report of real
        # work, and ambiguity falls to speech.
        "Already done."
        "It was handled."
        "Done."
        # First-person said-shapes with the world behind them, and ordinals
        # that are about the world rather than her own rounds — the topic
        # phrase (2026-08-15) must never widen the gate to any of these.
        "I said everything I have to the recruiter."
        "He said it all in the meeting."
        "Said my piece to him about the tests, and he agreed to fix them."
        "The fifth time round the loop crashed."
        "Third time through the suite, two failures."
        "Nothing further happened after the crash."
        "Nothing new about the crash — the log rotated."
        "The reply text is empty because the stream died."
    )
    for t in "${FILLER[@]}"; do
        wake_reply_is_filler "$t" || fail "filler would be spoken aloud: $t"
    done
    for t in "${REAL[@]}"; do
        wake_reply_is_filler "$t" && fail "real speech would be swallowed: $t"
    done
    ok "${#FILLER[@]} filler shapes mute, ${#REAL[@]} real replies speak"
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

CONVO="${DESKCRAB_STATE_PREFIX}-convo.txt"
JOURNAL="${DESKCRAB_STATE_PREFIX}-sessions.log"

for t in "Nothing to say." "Nothing to report." "No update." "Quiet here." \
         "Nothing new." "No message." "Silence." "Nothing." \
         "No message — the other session already said its piece." \
         "The other session already covered it." \
         "I've nothing further on that game tonight." \
         "I've said my piece on that game twice already tonight." \
         "*(no message text)*" ; do
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
ok "13 fillers through the real wake path — nothing spoken, no bubble"

# The words are muted, not lost: the journal is where a wake nobody heard has
# always belonged, and losing the trace would make the mute unauditable.
[ -f "$JOURNAL" ] || fail "the muted wakes journaled nothing at all"
grep -q "filler" "$JOURNAL" \
    || { echo "--- journal ---"; cat "$JOURNAL"; \
         fail "the journal does not record what the mute swallowed"; }
grep -qF "Nothing to say." "$JOURNAL" \
    || fail "the swallowed words themselves are not in the journal"
grep -qF "already said its piece" "$JOURNAL" \
    || fail "the suppressed meta-narration is not in the journal — the mute lost the note"
grep -qF "*(no message text)*" "$JOURNAL" \
    || fail "the suppressed absence placeholder is not in the journal — the mute lost the note"
ok "the muted words survive in the session journal"

# --- 2a: the silent EXIT — no message text at all ---------------------------
# The documented default when another session already covered it: the wake
# ends with an EMPTY reply. Nothing may reach any channel, and the journal
# must record it as silence — the wake's own choice, not a crash.
run_wake ""
[ -f "$WORK/spoken.txt" ] && fail "a silent exit still reached the speakers"
[ -f "$WORK/notified.txt" ] && fail "a silent exit still raised a notification"
[ -f "$WORK/displayed.txt" ] && fail "a silent exit still opened a window"
grep -q "Assistant" "$CONVO" 2>/dev/null \
    && { echo "--- conversation ---"; cat "$CONVO"; \
         fail "a silent exit still left a bubble in the conversation"; }
grep -q "(silent — " "$JOURNAL" \
    || { echo "--- journal ---"; cat "$JOURNAL"; \
         fail "the silent exit was not journalled as silence"; }
ok "the silent exit: an empty reply delivers nothing and journals as silence"

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
ok "a genuine reply containing 'nothing' is spoken and bubbled"

# And one more, whose entire content is a short sentence about quiet — the
# shape closest to the filler corpus that is still real speech.
REAL_TWO="Quiet hours start at ten, so the canary will not wake you."
run_wake "$REAL_TWO"
[ -f "$WORK/spoken.txt" ] || fail "a genuine reply about quiet was swallowed"
grep -qF "Quiet hours start at ten" "$WORK/spoken.txt" \
    || fail "the second genuine reply was not the text spoken"
ok "a genuine short reply about 'quiet' is spoken"

# --- 4: the prompt says it too ----------------------------------------------
# The gate is the backstop, not the instruction. The wake prompt has to ask for
# real silence in words — no message text at all — and name the filler sentence
# it keeps producing, or the code spends every wake swallowing something the
# prompt never told her not to write.
# Read off the agenda the LAST wake was actually handed, not off the source of
# `crab`. A grep of the shipping file passes just as well when the sentence
# survives only in the comment beside the code that stopped emitting it — and it
# would not notice the wording moving to a file the grep does not read.
grep -q "ZERO message text" "$WORK/argv.txt" \
    || fail "the wake prompt no longer asks for zero message text"
grep -q "Nothing to say" "$WORK/argv.txt" \
    || fail "the wake prompt no longer forbids the filler sentence by name"
grep -q "already said its piece" "$WORK/argv.txt" \
    || fail "the wake prompt no longer names the reason-bearing filler shape"
grep -q "DEFAULT" "$WORK/argv.txt" \
    || fail "the wake prompt no longer states the empty reply as the default"
ok "the wake prompt asks for silence in words, not just in code"

# --- 5: the concurrent-session blocks say it too ----------------------------
# The regroup layer is where the meta-narration was born: a wake shown another
# session's exchange answered it with a sentence ABOUT the exchange. Both
# branches of the concurrent-turn block, and the mid-utterance regroup block,
# must name the silent exit as the default when the other reply covers it and
# forbid announcing it — rule 29a's last clause.
(
    set +eu
    # shellcheck disable=SC1090
    source "$REPO/lib/common.sh"
    LIVE_TURN_FILE="$WORK/live-turn"

    printf '%s\tdesk\tanswering\nUser: is the build green?\n' "$(date +%s)" \
        > "$LIVE_TURN_FILE"
    B1="$(wake_concurrent_turn_context)"
    printf '%s' "$B1" | grep -q "no message text at all" \
        || fail "the answering-branch block no longer offers the silent exit"
    printf '%s' "$B1" | grep -q "already said its piece" \
        || fail "the answering-branch block no longer names the announcement shape as the failure"
    printf '%s' "$B1" | grep -q "DEFAULT" \
        || fail "the answering-branch block no longer states silence as the default when covered"

    printf '%s\tdesk\tanswered\nUser: is the build green?\nAssistant: it is.\n' "$(date +%s)" \
        > "$LIVE_TURN_FILE"
    B2="$(wake_concurrent_turn_context)"
    printf '%s' "$B2" | grep -q "no message text at all" \
        || fail "the answered-branch block no longer offers the silent exit"
    printf '%s' "$B2" | grep -q "already said its piece" \
        || fail "the answered-branch block no longer forbids the announcement by name"
    printf '%s' "$B2" | grep -q "DEFAULT" \
        || fail "the answered-branch block no longer states silence as the default when covered"

    B3="$(_regroup_block desk "the words being spoken right now")"
    printf '%s' "$B3" | grep -q "already said its piece" \
        || fail "the regroup block no longer forbids the announcement by name"
    printf '%s' "$B3" | grep -q "DEFAULT" \
        || fail "the regroup block no longer states silence as the default when covered"

    ok "all three concurrent-session blocks name the silent exit as the default and forbid announcing it"
) || exit 1

ok "silence is silent — filler muted whole, real speech untouched"
