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
#   9. serve.py's phone parser: stamp and mark out of the text, each into its
#      own field — the stamp so the bubble carries a clock, the mark
#      (phone rule 42) so the client's own-turn release never takes a wake's
#      reply for the answer it is waiting on. An unstamped line is LEGITIMATE:
#      the turn prompt itself says a block with no stamp is older than the
#      record kept one, so it parses with an empty time, never an invented one.
#
# Every assertion is counted — ok or fail, one summary line at the end — so a
# red run reports how much of the ground it covered instead of dying at the
# first miss with "0 passed, 0 failed", which is how this file's own fault
# hid its real verdict (engineering record
# the-conversation-parser-drops-the-stamp-off-olde).
#
# Everything is stubbed and confined to the sandbox.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -euo pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

# The stub summariser answers nothing at all: what these cases read is the
# prompt it was handed, not a reply.
sandbox_stub claude <<'STUB'
#!/bin/sh
exit 0
STUB

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
PROJECT_DIR="$WORK"
LAST_ORIGIN_FILE="$WORK/last-origin"
WANTS_FILE=""
PIPER_VOICE="$WORK/voice.onnx"
EOF

# --- 2: no path writes a block header without a stamp -----------------------
# A source-level guard, deliberately: the two writers can only be the single
# place the stamp is applied if nothing appends around them.
if grep -n "convo_append '\(User\|Assistant\):" "$REPO/lib/common.sh"; then
    fail "a conversation block is appended without going through the stamped writers"
else
    ok "no path appends a raw block behind the stamped writers"
fi

# --- 1, 3-8: the shell half -------------------------------------------------
# The ok/fail counters survive this subshell: the sandbox counts on disk, in
# the witness files, for exactly this shape.
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
        && ok "the user writer stamps its block" \
        || { cat "$CONVOFILE"; fail "the user block is not stamped"; }
    grep -qE "^Assistant \[$TODAY [0-9]{2}:[0-9]{2}\]: It finished clean\.$" "$CONVOFILE" \
        && ok "the assistant writer stamps its block" \
        || { cat "$CONVOFILE"; fail "the assistant block is not stamped"; }
    # The blank line between turns must survive — it is what keeps the next
    # block from being welded onto this one.
    [ "$(tail -c2 "$CONVOFILE" | tr -d '\n' | wc -c)" -eq 0 ] \
        && ok "the assistant block keeps its trailing blank line" \
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
        && ok "_compact_split folds something from a full unstamped conversation" \
        || fail "_compact_split folded nothing away from a full unstamped conversation"
    cp "$OLD" "$WORK/old-bare.txt" 2>/dev/null
    head -n "${BARE_LINES:-0}" "$CONVOFILE" | diff -q - "$OLD" >/dev/null \
        && ok "the folded excerpt is an exact line prefix of the conversation" \
        || fail "the folded excerpt is not an exact line prefix of the conversation"

    {
        printf 'User [%s 09:12]: q1\nAssistant [%s 09:13]: a1\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 10:00]: q2\nAssistant [%s 10:01]: a2\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 11:40]: q3\nAssistant [%s 11:41]: a3\n\n' "$TODAY" "$TODAY"
    } > "$CONVOFILE"
    LINES="$(_compact_split "$OLD")"
    [ "$LINES" = "$BARE_LINES" ] \
        && ok "the stamp is invisible to compaction's block counting" \
        || fail "stamped conversation folds ${LINES:-nothing}, unstamped folds ${BARE_LINES:-nothing} — the stamp is not invisible to compaction"
    head -n "${LINES:-0}" "$CONVOFILE" | diff -q - "$OLD" >/dev/null \
        && ok "the stamped excerpt is an exact line prefix of the conversation" \
        || fail "the stamped excerpt is not an exact line prefix of the conversation"
    # Identical once the stamps are taken back off.
    sed -E "s/^(User|Assistant) \[[^]]*\]: /\1: /" "$OLD" 2>/dev/null \
            | diff -q - "$WORK/old-bare.txt" >/dev/null \
        && ok "stamped and unstamped conversations fold away the same blocks" \
        || fail "stamped and unstamped conversations did not fold away the same blocks"
    # A body line that merely looks like a header must not split a reply: only a
    # line-START match counts. Fold one block off a reply whose second line is a
    # quoted "User:" and the whole reply has to travel together.
    printf 'User [%s 09:12]: q\nAssistant [%s 09:13]: I ran it. Output was:\nUser: nobody\n\n' \
        "$TODAY" "$TODAY" > "$CONVOFILE"
    printf 'User [%s 10:00]: q2\nAssistant [%s 10:01]: a2\n\n' "$TODAY" "$TODAY" >> "$CONVOFILE"
    CONVO_SUMMARIZE_TURNS=2 _compact_split "$WORK/quoted.txt" >/dev/null
    if [ -f "$WORK/quoted.txt" ] && ! grep -q '^User: nobody$' "$WORK/quoted.txt"; then
        ok "a quoted 'User:' line inside a reply travels with its block"
    else
        fail "a quoted 'User:' line inside a reply was treated as a block header"
    fi

    # 5. The span of an excerpt: same day collapses to one date, across days
    # keeps both, and an unstamped excerpt claims nothing at all.
    printf 'User [%s 09:12]: q1\nAssistant [%s 10:01]: a1\n' "$TODAY" "$TODAY" > "$WORK/span.txt"
    RANGE="$(convo_time_range "$WORK/span.txt")"
    [ "$RANGE" = "$TODAY 09:12 to 10:01" ] \
        && ok "a same-day range collapses to one date" \
        || fail "same-day range" "got [$RANGE] want [$TODAY 09:12 to 10:01]"
    printf 'User [2026-08-06 23:50]: q\nAssistant [2026-08-07 00:10]: a\n' > "$WORK/spanning.txt"
    [ "$(convo_time_range "$WORK/spanning.txt")" = "2026-08-06 23:50 to 2026-08-07 00:10" ] \
        && ok "a range crossing midnight keeps both dates" \
        || fail "a range crossing midnight lost its dates" "$(convo_time_range "$WORK/spanning.txt")"
    printf 'User: q\nAssistant: a\n' > "$WORK/unstamped.txt"
    [ -z "$(convo_time_range "$WORK/unstamped.txt")" ] \
        && ok "an unstamped excerpt claims no time range" \
        || fail "an unstamped excerpt invented a time range" "$(convo_time_range "$WORK/unstamped.txt")"

    # 6. The summariser is told the span, so the condensed half keeps a clock.
    # The stub claude prints nothing, so compact_convo leaves history alone —
    # what is under test is the prompt, captured from the argument it is given.
    sandbox_stub claude <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done > "$SUMPROMPT_OUT"
STUB
    {
        printf 'User [%s 09:12]: q1\nAssistant [%s 09:13]: a1\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 10:00]: q2\nAssistant [%s 10:01]: a2\n\n' "$TODAY" "$TODAY"
        printf 'User [%s 11:40]: q3\nAssistant [%s 11:41]: a3\n\n' "$TODAY" "$TODAY"
    } > "$CONVOFILE"
    CLAUDE_BIN="$SANDBOX_BIN/claude" SUMPROMPT_OUT="$WORK/sumprompt.txt" compact_convo
    grep -q "Keep time in the summary" "$WORK/sumprompt.txt" \
        && ok "the summariser is asked to keep time" \
        || fail "the summariser was not asked to keep time"
    # However many blocks the window folds away, the excerpt starts at the
    # oldest one — so its span opens at that block's stamp.
    grep -qF "$TODAY 09:12" "$WORK/sumprompt.txt" \
        && ok "the excerpt's span reaches the summariser" \
        || { cat "$WORK/sumprompt.txt"; fail "the excerpt's span never reached the summariser"; }
    # And an unstamped excerpt must make the summariser say so, not guess.
    printf 'User: q1\nAssistant: a1\n\nUser: q2\nAssistant: a2\n\n' > "$CONVOFILE"
    CLAUDE_BIN="$SANDBOX_BIN/claude" SUMPROMPT_OUT="$WORK/sumprompt-bare.txt" compact_convo
    grep -q "the excerpt is unstamped" "$WORK/sumprompt-bare.txt" \
        && ok "an unstamped excerpt tells the summariser its span is unknown" \
        || fail "an unstamped excerpt did not tell the summariser its span is unknown"

    # 7. (retired) The nothing-new overlap mute is gone — a wake's speech is
    # never judged after the fact. Nothing to test here.

    # 8. The prompt carries the stamps and says what they are for.
    printf 'User [%s 09:12]: how did it go\n' "$TODAY" > "$CONVOFILE"
    CTX="$(build_convo_context)"
    printf '%s' "$CTX" | grep -qF "User [$TODAY 09:12]: how did it go" \
        && ok "the stamped transcript reaches the prompt" \
        || fail "the stamped transcript did not reach the prompt"
    printf '%s' "$CTX" | grep -q "tell a minute ago from this morning" \
        && ok "the prompt explains how to read the stamps" \
        || fail "the prompt does not explain how to read the stamps"
    exit 0
) || fail "the shell half aborted before its assertions finished (exit $?)"

# --- 9: the phone's parser --------------------------------------------------
# Five block shapes on disk: the pre-stamp pair (older than the record kept
# one — parses with time empty, by design), a stamped pair with a multi-line
# continuation, and a wake's marked reply exactly as convo_append_assistant
# --wake writes it. Each parsed field is pinned on its own — role, text, time,
# mark — rather than by whole-dict equality, which is what broke here last
# time: the mark field arrived (683f196, phone rule 42) and every exact-dict
# comparison went red without a single field being wrong.
TODAY="$(date '+%Y-%m-%d')"
{
    printf 'User: an old question\nAssistant: an old answer\n\n'
    printf 'User [%s 12:01]: a new question\n' "$TODAY"
    printf 'Assistant [%s 12:03]: a new answer\ncontinued on a second line\n\n' "$TODAY"
    printf 'Assistant [%s 12:05] (autonomous wake): the kettle is on\n\n' "$TODAY"
} > "$DESKCRAB_STATE_PREFIX-convo.txt"

# serve.py refuses to load unauthenticated; it is being imported for its parser,
# not served, and it binds nothing at import. Assertion failures come back as
# FAIL lines and are counted below; a nonzero exit is the check itself dying.
export DESKCRAB_SERVE_SECRET="test-only"
python3 - "$REPO" "$TODAY" > "$WORK/parser-verdicts.txt" 2>&1 <<'PY' \
    || fail "the phone parser check aborted (exit $?)"
import sys, importlib.util
repo, today = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("serve", repo + "/lib/serve.py")
serve = importlib.util.module_from_spec(spec)
serve.__spec__ = spec
spec.loader.exec_module(serve)
t = serve.read_turns()

def note(okay, msg, got=None):
    print(("PASS " if okay else "FAIL ") + msg)
    if not okay and got is not None:
        print("got:", got)

def pin(i, msg, role, text, time, mark):
    if i >= len(t):
        note(False, msg, "turn %d missing from %r" % (i, t))
        return
    x = t[i]
    note(x.get("role") == role and x.get("text") == text
         and x.get("time") == time and x.get("mark") == mark, msg, x)

note(len(t) == 5, "five blocks on disk parse as five turns, none lost", t)
pin(0, "an unstamped user line keeps its text, with an empty time, not an invented one",
    "user", "an old question", "", "")
pin(1, "an unstamped assistant line parses the same way",
    "assistant", "an old answer", "", "")
pin(2, "a stamped line's clock comes out of the text and into its own field",
    "user", "a new question", today + " 12:01", "")
pin(3, "a stamped multi-line reply keeps its continuation",
    "assistant", "a new answer\ncontinued on a second line", today + " 12:03", "")
pin(4, "a wake's mark rides beside the bubble — never in its text, never dropped",
    "assistant", "the kettle is on", today + " 12:05", "autonomous wake")
PY
while IFS= read -r line; do
    case "$line" in
        "PASS "*) ok "${line#PASS }" ;;
        "FAIL "*) fail "${line#FAIL }" ;;
        *) printf '  %s\n' "$line" ;;
    esac
done < "$WORK/parser-verdicts.txt"

ok "conversation stamps: written, counted, split, ranged, prompted and parsed"
