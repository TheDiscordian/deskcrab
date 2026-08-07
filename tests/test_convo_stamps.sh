#!/usr/bin/env bash
# Proof that the conversation transcript carries a clock — and that adding one
# did not break the transcript that has none.
#
# A flat "User:" / "Assistant:" record reads identically whether a thing was
# said thirty seconds ago or six hours ago, so "you said that a minute ago"
# had nothing to check itself against. Every block header is now stamped with
# local time. The risk that comes with that is not the writing but the
# READING: half a dozen places match a block header, every conversation
# already on disk is unstamped, and a pattern that quietly stops matching
# them loses turns without ever erroring. So the assertions below are mostly
# about the old shape surviving:
#
#   1. the writers stamp, and stamp both speakers
#   2. no path appends a raw block behind their back
#   3. block counting sees stamped, unstamped, and mixed files alike
#   4. _compact_split splits a MIXED file, and its output stays an exact line
#      prefix of the conversation (what _compact_drop depends on)
#   5. convo_time_range: same day, across days, and unstamped
#   6. the summariser is told the span it is condensing
#   7. wake_says_nothing_new still recognises an assistant block, stamped or not
#   8. build_convo_context ships the stamps and says how to read them
#   9. serve.py's phone parser: stamp out of the text, into its own field
#
# Everything is stubbed and confined to a mktemp dir.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/deskcrab-stamp-test-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export DESKCRAB_STATE_PREFIX="$WORK/state"
export DESKCRAB_CONF="$WORK/conf"

mkdir -p "$WORK/bin"
for tool in notify-send piper-tts aplay hyprctl render-md ffmpeg systemd-run systemctl pactl claude; do
    printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$tool"
    chmod +x "$WORK/bin/$tool"
done
export PATH="$WORK/bin:$PATH"

cat > "$WORK/conf" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
CLAUDE_BIN="$WORK/bin/claude"
PROJECT_DIR="$WORK"
ARCHIVE_DIR="$WORK/archive"
JOBS_DIR="$WORK/jobs"
WAKES_DIR="$WORK/wakes"
DAY_JOURNAL_DIR="$WORK/journal"
NOTICE_STATE_DIR="$WORK/notice"
LAST_ORIGIN_FILE="$WORK/last-origin"
WANTS_FILE=""
PIPER_VOICE="$WORK/voice.onnx"
EOF

fail() { echo "FAIL: $*"; exit 1; }

# --- 2: no path writes a block header without a stamp -----------------------
# A source-level guard, deliberately: the two writers can only be the single
# place the stamp is applied if nothing appends around them.
if grep -n "convo_append '\(User\|Assistant\):" "$REPO/lib/common.sh"; then
    fail "a conversation block is appended without going through the stamped writers"
fi

# --- 1, 3-8: the shell half -------------------------------------------------
(
    # common.sh is not written for -u (optional config vars are read bare).
    set +eu
    # shellcheck disable=SC1090
    source "$REPO/lib/common.sh"

    TODAY="$(date '+%Y-%m-%d')"

    # 1. Both writers stamp their header, and the text is untouched beside it.
    rm -f "$CONVOFILE"
    convo_append_user "how did the backup go"
    convo_append_assistant "It finished clean."
    grep -qE "^User \[$TODAY [0-9]{2}:[0-9]{2}\]: how did the backup go$" "$CONVOFILE" \
        || { cat "$CONVOFILE"; fail "the user block is not stamped"; }
    grep -qE "^Assistant \[$TODAY [0-9]{2}:[0-9]{2}\]: It finished clean\.$" "$CONVOFILE" \
        || { cat "$CONVOFILE"; fail "the assistant block is not stamped"; }
    # The blank line between turns must survive — it is what keeps the next
    # block from being welded onto this one.
    [ "$(tail -c2 "$CONVOFILE" | tr -d '\n' | wc -c)" -eq 0 ] \
        || fail "the assistant block lost its trailing blank line"

    # 3-4. Stamping must be INVISIBLE to compaction. Rather than assert a
    # particular block arithmetic — which is the sliding window's business, not
    # the clock's, and is being changed in its own right — assert the invariant
    # that belongs to this change: the same conversation, stamped and unstamped,
    # must fold away exactly the same thing. That covers the counter and the awk
    # split at once, and stays true whichever way the window decides to count.
    OLD="$WORK/old.txt"
    CONVO_MAX_TURNS=2 CONVO_SUMMARIZE_TURNS=1

    {
        printf 'User: q1\nAssistant: a1\n\n'
        printf 'User: q2\nAssistant: a2\n\n'
        printf 'User: q3\nAssistant: a3\n\n'
    } > "$CONVOFILE"
    BARE_LINES="$(_compact_split "$OLD")"
    [ -n "$BARE_LINES" ] \
        || fail "_compact_split folded nothing away from a full unstamped conversation"
    cp "$OLD" "$WORK/old-bare.txt"
    head -n "$BARE_LINES" "$CONVOFILE" | diff -q - "$OLD" >/dev/null \
        || fail "the folded excerpt is not an exact line prefix of the conversation"

    {
        printf 'User [%s 09:12]: q1\nAssistant [%s 09:13]: a1\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 10:00]: q2\nAssistant [%s 10:01]: a2\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 11:40]: q3\nAssistant [%s 11:41]: a3\n\n' "$TODAY" "$TODAY"
    } > "$CONVOFILE"
    LINES="$(_compact_split "$OLD")"
    [ "$LINES" = "$BARE_LINES" ] \
        || fail "stamped conversation folds $LINES lines, unstamped folds $BARE_LINES — the stamp is not invisible to compaction"
    head -n "$LINES" "$CONVOFILE" | diff -q - "$OLD" >/dev/null \
        || fail "the stamped excerpt is not an exact line prefix of the conversation"
    # Identical once the stamps are taken back off.
    sed -E "s/^(User|Assistant) \[[^]]*\]: /\1: /" "$OLD" | diff -q - "$WORK/old-bare.txt" >/dev/null \
        || fail "stamped and unstamped conversations did not fold away the same blocks"
    # A body line that merely looks like a header must not split a reply: only a
    # line-START match counts. Fold one block off a reply whose second line is a
    # quoted "User:" and the whole reply has to travel together.
    printf 'User [%s 09:12]: q\nAssistant [%s 09:13]: I ran it. Output was:\nUser: nobody\n\n' \
        "$TODAY" "$TODAY" > "$CONVOFILE"
    printf 'User [%s 10:00]: q2\nAssistant [%s 10:01]: a2\n\n' "$TODAY" "$TODAY" >> "$CONVOFILE"
    CONVO_SUMMARIZE_TURNS=2 _compact_split "$WORK/quoted.txt" >/dev/null
    grep -q '^User: nobody$' "$WORK/quoted.txt" \
        && fail "a quoted 'User:' line inside a reply was treated as a block header"

    # 5. The span of an excerpt: same day collapses to one date, across days
    # keeps both, and an unstamped excerpt claims nothing at all.
    printf 'User [%s 09:12]: q1\nAssistant [%s 10:01]: a1\n' "$TODAY" "$TODAY" > "$WORK/span.txt"
    RANGE="$(convo_time_range "$WORK/span.txt")"
    [ "$RANGE" = "$TODAY 09:12 to 10:01" ] \
        || fail "same-day range is '$RANGE', want '$TODAY 09:12 to 10:01'"
    printf 'User [2026-08-06 23:50]: q\nAssistant [2026-08-07 00:10]: a\n' > "$WORK/spanning.txt"
    [ "$(convo_time_range "$WORK/spanning.txt")" = "2026-08-06 23:50 to 2026-08-07 00:10" ] \
        || fail "a range crossing midnight lost its dates"
    printf 'User: q\nAssistant: a\n' > "$WORK/unstamped.txt"
    [ -z "$(convo_time_range "$WORK/unstamped.txt")" ] \
        || fail "an unstamped excerpt invented a time range"

    # 6. The summariser is told the span, so the condensed half keeps a clock.
    # The stub claude prints nothing, so compact_convo leaves history alone —
    # what is under test is the prompt, captured from the argument it is given.
    cat > "$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done > "$SUMPROMPT_OUT"
STUB
    chmod +x "$WORK/bin/claude"
    {
        printf 'User [%s 09:12]: q1\nAssistant [%s 09:13]: a1\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 10:00]: q2\nAssistant [%s 10:01]: a2\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 11:40]: q3\nAssistant [%s 11:41]: a3\n\n' "$TODAY" "$TODAY"
    } > "$CONVOFILE"
    CLAUDE_BIN="$WORK/bin/claude" SUMPROMPT_OUT="$WORK/sumprompt.txt" compact_convo
    grep -q "Keep time in the summary" "$WORK/sumprompt.txt" \
        || fail "the summariser was not asked to keep time"
    # However many blocks the window folds away, the excerpt starts at the
    # oldest one — so its span opens at that block's stamp.
    grep -qF "$TODAY 09:12" "$WORK/sumprompt.txt" \
        || { cat "$WORK/sumprompt.txt"; fail "the excerpt's span never reached the summariser"; }
    # And an unstamped excerpt must make the summariser say so, not guess.
    printf 'User: q1\nAssistant: a1\n\nUser: q2\nAssistant: a2\n\n' > "$CONVOFILE"
    CLAUDE_BIN="$WORK/bin/claude" SUMPROMPT_OUT="$WORK/sumprompt-bare.txt" compact_convo
    grep -q "the excerpt is unstamped" "$WORK/sumprompt-bare.txt" \
        || fail "an unstamped excerpt did not tell the summariser its span is unknown"

    # 7. (retired) The nothing-new overlap mute is gone — a wake's speech is
    # never judged after the fact. Nothing to test here.

    # 8. The prompt carries the stamps and says what they are for.
    printf 'User [%s 09:12]: how did it go\n' "$TODAY" > "$CONVOFILE"
    CTX="$(build_convo_context)"
    printf '%s' "$CTX" | grep -qF "User [$TODAY 09:12]: how did it go" \
        || fail "the stamped transcript did not reach the prompt"
    printf '%s' "$CTX" | grep -q "tell a minute ago from this morning" \
        || fail "the prompt does not explain how to read the stamps"
    exit 0
) || exit 1

# --- 9: the phone's parser --------------------------------------------------
TODAY="$(date '+%Y-%m-%d')"
{
    printf 'User: an old question\nAssistant: an old answer\n\n'
    printf 'User [%s 12:01]: a new question\n' "$TODAY"
    printf 'Assistant [%s 12:03]: a new answer\ncontinued on a second line\n\n' "$TODAY"
} > "$WORK/state-convo.txt"

# serve.py refuses to load unauthenticated; it is being imported for its parser,
# not served, and it binds nothing at import.
export DESKCRAB_SERVE_SECRET="test-only"
python3 - "$REPO" "$TODAY" <<'PY' || exit 1
import sys, importlib.util
repo, today = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("serve", repo + "/lib/serve.py")
serve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(serve)
t = serve.read_turns()
def fail(m):
    print("FAIL:", m, "->", t); sys.exit(1)
if len(t) != 4:
    fail("want 4 turns")
if t[0] != {"role": "user", "text": "an old question", "time": ""}:
    fail("an unstamped user line stopped parsing")
if t[1]["role"] != "assistant" or t[1]["text"] != "an old answer":
    fail("an unstamped assistant line stopped parsing")
if t[2] != {"role": "user", "text": "a new question", "time": today + " 12:01"}:
    fail("the stamp did not come out of the text and into its own field")
if t[3]["text"] != "a new answer\ncontinued on a second line":
    fail("a stamped multi-line reply lost its continuation")
PY

echo "PASS: conversation stamps"
