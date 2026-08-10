#!/usr/bin/env bash
# A wake that is not delivered leaves NOTHING behind — and a wake can never
# again wipe a desktop turn's stream log.
#
# Both halves of this are the bug of 2026-08-07, when he spent an afternoon
# watching replies arrive empty and a wake's monologue about a conduct rule
# land in the middle of a conversation he was having:
#
#   1. run_claude_wake appended its reply to the conversation the moment the
#      reply existed, BEFORE a single suppression gate had run. The phone
#      follows the conversation file (serve.py /watch), so "suppressed" meant
#      suppressed on the speakers and published on his screen.
#   2. The wake wrote its stream to the ONE shared $DEBUGLOG that a desktop
#      turn truncates on the way in. A wake starting mid-turn wiped the desk
#      reply before extract_response could read it — dead air for a question
#      he had asked out loud — and whichever session read the file second read
#      both streams and spoke the other one's words.
#
# Everything here is stubbed, silent, and confined to the sandbox.
# run_claude_wake is called directly rather than through `crab wake` so the
# test books no systemd timers; PIDFILE is therefore set by hand, exactly as
# the `crab` script sets it, since that is what user_busy consults.
# No `set -u`: lib/common.sh is sourced here rather than run through `crab`,
# and it reads plenty of optional config (TTS_FIXES, PIPER_SPEAKER…) that
# nounset turns into a silent mid-function exit. Failures here are explicit.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

REPLY="The lantern in the hallway needs rewiring before the equinox festival begins."

# The stub claude: one assistant text block, then the result event. This is a
# wake that HAS something to say — the whole question is who gets to hear it.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"$REPLY"}]}}'
printf '%s\n' '{"type":"result"}'
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf '# Wants\n\n- a want, so the wake path is enabled at all\n' > "$WORK/wants.md"

# Each wake runs as its OWN PROCESS, exactly as `crab wake` runs it — not as a
# function call in this shell. That is the whole point of case 3: the stream
# logs are separated by pid ($DEBUGLOG is per-session), so an in-process call
# would share this script's log and prove nothing. run_claude_wake is invoked
# directly rather than through `crab wake` so the test books no systemd timers.
# PIDFILE is set by hand because `crab` sets it, not lib/common.sh, and
# user_busy is what reads it.
wake() { # <reason>
    bash -c '
        . "$1/lib/common.sh"
        PIDFILE="$2"
        WAKE_REASON="$3"
        run_claude_wake "(Autonomous wake — test)"
    ' _ "$REPO" "$PIDFILE" "$1" >/dev/null 2>&1
}

# shellcheck source=/dev/null
source "$REPO/lib/common.sh"          # for CONVOFILE, DEBUGLOG, SESSIONS_LOG
PIDFILE="$WORK/rec.pid"

# No fail(){ die ...; } shim here: shadowing the harness's fail() put die()
# into mutual recursion and turned every failing assertion into a silent
# segfault. The assertions call die directly — fail-fast is what they want.

# --- 1. suppressed wake: the user is mid-recording -------------------------
touch "$PIDFILE"
: > "$CONVOFILE"
wake "a test wake beside a live turn"

grep -q "Assistant" "$CONVOFILE" \
    && die "a muted wake still wrote its reply into the conversation"
grep -q "Autonomous wake" "$CONVOFILE" \
    && die "a muted wake still wrote its marker into the conversation"
[ -s "$CONVOFILE" ] \
    && die "a muted wake left something in the conversation: $(cat "$CONVOFILE")"
grep -q "muted — user was mid-interaction" "$SESSIONS_LOG" \
    || die "the muted wake was not journalled (its words would be lost entirely)"
grep -q "$REPLY" "$SESSIONS_LOG" \
    || die "the journal did not keep what the muted wake would have said"

# --- 2. delivered wake: nobody is busy, so it IS the conversation ----------
rm -f "$PIDFILE"
: > "$CONVOFILE"
wake "a test wake with the room to itself"

grep -q "^Assistant" "$CONVOFILE" \
    || die "a delivered wake did not reach the conversation: $(cat "$CONVOFILE")"
grep -q "$REPLY" "$CONVOFILE" \
    || die "the delivered wake's reply is not the one in the conversation"
grep -q "Autonomous wake" "$CONVOFILE" \
    || die "a delivered wake left no marker, so it reads as an unprompted turn"

# --- 3. the wake's stream log is its own -----------------------------------
# Another session's log, with another session's content in it — the desktop
# turn whose TTS streamer is mid-tail on it. A wake must not be able to
# truncate it, append to it, or read it back as its own words.
SENTINEL='{"type":"assistant","message":{"model":"desk","content":[{"type":"text","text":"a desk turn was mid-sentence here"}]}}'
printf '%s\n' "$SENTINEL" > "$DEBUGLOG"
DESK_BEFORE="$(cat "$DEBUGLOG")"
: > "$CONVOFILE"
wake "a test wake beside a desk turn's stream"

[ "$(cat "$DEBUGLOG")" = "$DESK_BEFORE" ] \
    || die "the wake wrote to another session's stream log: $(cat "$DEBUGLOG")"
grep -q "$REPLY" "$CONVOFILE" \
    || die "the wake lost its own reply when given a private log"
grep -q "desk turn was mid-sentence" "$CONVOFILE" \
    && die "the wake read the desktop turn's stream back as its own words"

# --- 4. a (quiet) reply is a bubble, never invisible and never voiced ------
# His standing instruction: a wake with a thought worth leaving but not
# voicing writes "(quiet) <thought>", and that ALWAYS shows as a bubble —
# even with no display section. The bug this pins: SPOKEN is emptied for the
# marker, so the nothing-to-deliver gate saw an empty reply and returned
# before the bubble was appended.
THOUGHT="the east shelf wants re-ordering before the next delivery"
sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"(quiet) $THOUGHT"}]}}'
printf '%s\n' '{"type":"result"}'
EOF
rm -f "$PIDFILE"
: > "$CONVOFILE"
wake "a test wake with a held thought"

grep -q "(quiet) $THOUGHT" "$CONVOFILE" \
    || die "a quiet reply with no display section vanished instead of showing as a bubble: $(cat "$CONVOFILE")"
grep -q "Autonomous wake" "$CONVOFILE" \
    || die "the quiet bubble arrived without its wake marker"

# ...and a delivered bubble is a session that REACHED HIM, so its journal line
# must not wear the not-delivered spelling. specs/self-awareness.md rule 12
# reads delivery off this log by one convention: a parenthesised outcome means
# it reached nobody. A quiet bubble was journalled "(silent — …)" up in the
# work-record section, before any gate had run, and the since-your-last-reply
# anchor therefore stepped straight over a wake that was sitting in his chat —
# and re-reported work he had already been shown.
tail -n1 "$SESSIONS_LOG" | cut -f5 | grep -q '^(' \
    && die "the delivered quiet bubble is journalled as a session that reached nobody: $(tail -n1 "$SESSIONS_LOG")"
tail -n1 "$SESSIONS_LOG" | grep -q "$THOUGHT" \
    || die "the delivered bubble's journal line lost the thought it delivered"

# A bare marker with no thought is plain silence — no bubble.
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"(quiet)"}]}}'
printf '%s\n' '{"type":"result"}'
EOF
: > "$CONVOFILE"
wake "a test wake with nothing behind the marker"

[ -s "$CONVOFILE" ] \
    && die "a bare (quiet) marker earned a bubble it should not have: $(cat "$CONVOFILE")"

# Rule 54: the bubble goes through her replace table. It is never spoken, so
# the streamer's gate never sees it, and the whole-draft mirror fails open —
# the user read a banned word in a quiet bubble that had passed both.
cat > "$SANDBOX/claudisms.md" <<'EOF'
## the honesty family
- pattern: `\bhonest(?:y|ly)?\b`
- replace: `\b[Tt]o be honest,\s+` -> ``
EOF
export CLAUDISMS_FILE="$SANDBOX/claudisms.md"
sandbox_stub claude <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"(quiet) To be honest, I lost the game."}]}}'
printf '%s\n' '{"type":"result"}'
EOF
: > "$CONVOFILE"
wake "a test wake whose quiet thought trips the table"

grep -qi 'honest' "$CONVOFILE" \
    && die "a banned word reached the quiet bubble ungated: $(cat "$CONVOFILE")"
grep -q 'I lost the game' "$CONVOFILE" \
    || die "the table pass ate the bubble instead of repairing it: $(cat "$CONVOFILE")"

ok "suppressed wake leaves nothing, delivered wake lands, stream logs are private, a quiet thought is a bubble, and the bubble is gated"
