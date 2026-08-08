#!/bin/bash
# Tests for the live debug view (crab-debug): everything said in a turn — his
# words as well as hers — must appear in it, once, at the time it happens.
# Run: bash tests/test_debug_view.sh
#
# The gaps these were written for. On 2026-08-07 he heard a reply, saw it on the
# phone, and never saw it in the debug view; the window meanwhile was three
# thousand lines of turns that had finished hours earlier.
#   1. a phone turn writes to a PRIVATE per-turn log, and the view followed only
#      the shared one, so phone replies were never in it at all;
#   2. the shared log is truncated in place at the start of a turn, which
#      strands a reader's cursor past EOF — turn one showed, every turn after it
#      was silence;
#   3. a line still being written was read as two halves, neither of which is
#      JSON, so a long assistant block (the reply itself) parsed as nothing;
#   4. every log already on disk at launch was replayed from byte zero — 101
#      dead sessions, 3250 lines, into a 2000-line scrollback;
#   5. keyed by PATH, the moment a new turn repointed the well-known symlink the
#      previous session's file was reopened at zero and its whole turn printed
#      a second time;
#   6. nothing has ever rendered what HE said. The prompt goes to the CLI as
#      argv and comes back in no event; the conversation file is the only
#      record, and it is rewritten under the reader by compaction and rotation.
#
# Isolation: every path this drives hangs off DESKCRAB_STATE_PREFIX inside a
# scratch directory, and the viewer runs under `env -i` with nothing but PATH,
# HOME and that prefix — it must not be able to see the live instance's logs,
# conversation or sessions, and it starts no claude, touches no systemd.
# DESKCRAB_DEBUG_BIN points the whole suite at another copy of the viewer, which
# is how each case below was shown red against the version before it.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
VIEWER="${DESKCRAB_DEBUG_BIN:-$REPO_DIR/crab-debug}"
# NOT /tmp/deskcrab-*: that is the live instance's prefix, which the sandbox
# leak check photographs, so a scratch root there reads as a live path moving
# under some innocent test running beside this one.
T="$(mktemp -d "${TMPDIR:-/tmp}/crabdbgview-XXXXXX")"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — $2"; }

PREFIX="$T/deskcrab"
LATEST="$PREFIX-debug.log"          # the well-known name: a symlink in production
SESSIONS="$PREFIX-sessions"         # session_register's registry, one file per pid
CONVO="$PREFIX-convo.txt"
OUT="$T/view.txt"
mkdir -p "$SESSIONS"

# One stream-json assistant text event, exactly the shape the CLI emits.
say() { # <file> <text> [append|truncate]
    local mode="${3:-append}"
    local line
    line="$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$2")"
    if [ "$mode" = truncate ]; then printf '%s\n' "$line" > "$1"
    else printf '%s\n' "$line" >> "$1"; fi
}

# A session takes its own stream log and points the well-known name at it —
# claim_debuglog, in the shape lib/common.sh actually writes it, symlink and
# all, plus the registration that says which KIND of session this is.
claim() { # <pid> <kind>
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$1" "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" 1 \
        > "$SESSIONS/$1"
    : > "$PREFIX-debug-$1.log"
    ln -sfn "$PREFIX-debug-$1.log" "$LATEST"
}

# What a turn appends to the conversation before the CLI is even started —
# convo_append_user, stamp and all.
heard() { # <text>
    printf 'User [%s]: %s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" >> "$CONVO"
}
answered() { # <text>
    printf 'Assistant [%s]: %s\n\n' "$(date '+%Y-%m-%d %H:%M')" "$1" >> "$CONVO"
}

# Wait (up to ~10 s) for text to show up in the view rather than sleeping a
# fixed amount: a slow machine must not turn a pass into a flake, and a real
# miss still fails in bounded time.
awaits() { # <text>
    local i=0
    while [ $i -lt 200 ]; do
        grep -qF -- "$1" "$OUT" && return 0
        sleep 0.05
        i=$(( i + 1 ))
    done
    return 1
}

count() { grep -cF -- "$1" "$OUT" || true; }

# Absence and exactly-once are only meaningful behind a barrier: "not there
# yet" and "never going to be there" look identical without one. Every such
# assertion below writes a fresh canary into a live stream, waits for it, and
# then leaves a couple of poll cycles of slack before it counts anything.
BARRIER=0
barrier() {
    BARRIER=$(( BARRIER + 1 ))
    say "$BARRIER_LOG" "BARRIER-$BARRIER"
    awaits "BARRIER-$BARRIER" || return 1
    sleep 0.2
}

echo "== a log that was already on disk at launch is history, not news =="
# 101 of these were live when the flood was measured. None of it happened in
# this window, and replaying it evicts the turn that did.
claim 900001 "desktop turn"
say "$PREFIX-debug-900001.log" "STALE-BEFORE-LAUNCH"
printf 'User [2026-08-07 09:00]: STALE-USER-LINE\n' >> "$CONVO"
answered "stale reply"

env -i PATH="$PATH" HOME="$T" LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8 \
    DESKCRAB_STATE_PREFIX="$PREFIX" "$VIEWER" > "$OUT" 2>&1 &
VIEWER_PID=$!
trap 'kill '"$VIEWER_PID"' 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.6

# Every later case writes its barrier here; it is a live session of its own.
claim 900002 "desktop turn"
BARRIER_LOG="$PREFIX-debug-900002.log"

barrier || fail "the viewer never started" "no output in $OUT"
[ "$(count STALE-BEFORE-LAUNCH)" = 0 ] \
    && ok "a log that predates the viewer is not replayed into it" \
    || fail "startup replay flood" "STALE-BEFORE-LAUNCH printed $(count STALE-BEFORE-LAUNCH) times"
[ "$(count STALE-USER-LINE)" = 1 ] \
    && ok "the conversation already in progress is summarised once, as Last heard" \
    || fail "startup convo replay" "STALE-USER-LINE printed $(count STALE-USER-LINE) times"

echo
echo "== the desk stream (a turn that starts after the viewer) =="
claim 900003 "desktop turn"
DESK="$PREFIX-debug-900003.log"
say "$DESK" "DESK-REPLY-ONE"
awaits DESK-REPLY-ONE && ok "a desk reply reaches the view" \
    || fail "desk reply missing" "not in $OUT"
grep -q "── desk" "$OUT" && ok "the desk stream is labelled as such" \
    || fail "no desk label" "expected a '── desk' header"

echo
echo "== what HE said, from the conversation file =="
# The CLI is handed the prompt as argv and echoes it in no event; this file is
# the only record there has ever been, and until now nothing read it twice.
heard "USER-SAID-CANARY-ALPHA"
awaits USER-SAID-CANARY-ALPHA && ok "a user message reaches the view" \
    || fail "no user-message path" "USER-SAID-CANARY-ALPHA not in $OUT"
barrier
[ "$(count USER-SAID-CANARY-ALPHA)" = 1 ] \
    && ok "the user message is shown exactly once" \
    || fail "user message repeated" "printed $(count USER-SAID-CANARY-ALPHA) times"
grep -q "❯ you said" "$OUT" && ok "the user message is attributed to him" \
    || fail "unattributed user message" "expected a '❯ you said' header"
# Her side of the conversation file is her stream's job; printing it from here
# too is how the same reply ends up in the window twice.
answered "ASSISTANT-BLOCK-CANARY"
barrier
[ "$(count ASSISTANT-BLOCK-CANARY)" = 0 ] \
    && ok "an assistant block in the conversation file is not printed a second time" \
    || fail "assistant block echoed" "printed $(count ASSISTANT-BLOCK-CANARY) times"

echo
echo "== the next turn claims the well-known name; the last one is not replayed =="
# claim_debuglog repoints $PREFIX-debug.log at each new session. Keyed by path
# rather than by inode, the viewer reopened the PREVIOUS session's file at byte
# zero the moment the symlink moved, and printed that whole turn again.
say "$DESK" "TURN-A-CANARY"
awaits TURN-A-CANARY || fail "turn A never showed" "TURN-A-CANARY not in $OUT"
claim 900004 "desktop turn"
DESK_B="$PREFIX-debug-900004.log"
say "$DESK_B" "TURN-B-CANARY"
awaits TURN-B-CANARY && ok "the turn that claims the symlink is followed" \
    || fail "turn B missing" "TURN-B-CANARY not in $OUT"
barrier
[ "$(count TURN-A-CANARY)" = 1 ] \
    && ok "the previous turn is not replayed when the symlink moves" \
    || fail "re-replay on symlink claim" "TURN-A-CANARY printed $(count TURN-A-CANARY) times"
# And the session that lost the symlink is still writing: a wake beside a desk
# turn is the ordinary case, and it must not go silent because somebody else
# now owns the well-known name.
say "$DESK" "TURN-A-STILL-TALKING"
awaits TURN-A-STILL-TALKING \
    && ok "a session keeps being followed after another claims the symlink" \
    || fail "stream dropped on symlink claim" "TURN-A-STILL-TALKING not in $OUT"

echo
echo "== a wake is labelled a wake =="
claim 900005 "autonomous wake"
say "$PREFIX-debug-900005.log" "WAKE-REPLY-CANARY"
awaits WAKE-REPLY-CANARY || fail "wake reply missing" "WAKE-REPLY-CANARY not in $OUT"
grep -q "── wake" "$OUT" \
    && ok "an autonomous wake is not presented as something he asked for" \
    || fail "wake mislabelled" "expected a '── wake' header"

echo
echo "== a second turn truncates its log in place =="
say "$DESK_B" "$(printf 'padding %.0s' $(seq 1 200))"   # push the cursor well past
awaits "padding padding" || true
say "$DESK_B" "DESK-REPLY-TWO" truncate                  # a recycled pid, from byte 0
awaits DESK-REPLY-TWO && ok "the turn after a truncation still reaches the view" \
    || fail "cursor stranded past EOF by truncation" "DESK-REPLY-TWO not in $OUT"

echo
echo "== a phone turn's private per-turn log =="
PHONE="$PREFIX-turn-$(python3 -c 'import uuid;print(uuid.uuid4().hex)').log"
say "$PHONE" "PHONE-REPLY-THREE"
awaits PHONE-REPLY-THREE && ok "a phone reply reaches the view" \
    || fail "phone turn followed nowhere" "PHONE-REPLY-THREE not in $OUT"
grep -q "── phone" "$OUT" && ok "the phone stream is labelled as such" \
    || fail "no phone label" "expected a '── phone' header"

echo
echo "== the same for a serverless \`crab remote\` turn =="
REMOTE="$PREFIX-remote-900006.log"
printf 'phone turn\t900006\t%s\t%s\t1\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(date +%s)" > "$SESSIONS/900006"
say "$REMOTE" "REMOTE-REPLY-FOUR"
awaits REMOTE-REPLY-FOUR && ok "a \`crab remote\` reply reaches the view" \
    || fail "remote turn followed nowhere" "REMOTE-REPLY-FOUR not in $OUT"

echo
echo "== the private log is drained even after it is deleted =="
say "$PHONE" "PHONE-REPLY-FIVE"
rm -f "$PHONE"
awaits PHONE-REPLY-FIVE && ok "words written just before the turn's log is unlinked survive" \
    || fail "drain-on-unlink" "PHONE-REPLY-FIVE not in $OUT"

echo
echo "== a line still being written is not read as two halves =="
# Exactly what a slow writer does: half the JSON object, a pause, the rest.
LINE="$(python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":"SPLIT-REPLY-SIX is one whole sentence"}]}}))')"
printf '%s' "${LINE:0:40}" >> "$DESK_B"
sleep 0.4
printf '%s\n' "${LINE:40}" >> "$DESK_B"
awaits "SPLIT-REPLY-SIX is one whole sentence" \
    && ok "a split write is reassembled and shown in full" \
    || fail "partial line dropped the reply" "SPLIT-REPLY-SIX not in $OUT"

echo
echo "== nothing is dropped when both streams write at once =="
PHONE2="$PREFIX-turn-$(python3 -c 'import uuid;print(uuid.uuid4().hex)').log"
say "$DESK_B" "CONCURRENT-DESK-SEVEN"
say "$PHONE2" "CONCURRENT-PHONE-SEVEN"
awaits CONCURRENT-DESK-SEVEN && awaits CONCURRENT-PHONE-SEVEN \
    && ok "interleaved desk and phone replies both appear" \
    || fail "interleaved streams" "one of the two is missing"

echo
echo "== the conversation file is compacted under the viewer =="
# compact_convo folds the oldest blocks into the summary and moves a new file
# into place: same tail, different inode. Nothing was said twice, so nothing may
# be printed twice — and the turn that lands after the rewrite is still new.
heard "COMPACT-KEEP-CANARY"
awaits COMPACT-KEEP-CANARY || fail "pre-compaction message missing" "COMPACT-KEEP-CANARY not in $OUT"
answered "reply before compaction"
tail -n +3 "$CONVO" > "$T/convo.new" && mv "$T/convo.new" "$CONVO"
barrier
[ "$(count COMPACT-KEEP-CANARY)" = 1 ] \
    && ok "compaction does not replay what is still in the file" \
    || fail "compaction replay" "COMPACT-KEEP-CANARY printed $(count COMPACT-KEEP-CANARY) times"
heard "COMPACT-AFTER-CANARY"
awaits COMPACT-AFTER-CANARY \
    && ok "a message after the compaction is still seen" \
    || fail "compaction dropped the follower" "COMPACT-AFTER-CANARY not in $OUT"
barrier
[ "$(count COMPACT-AFTER-CANARY)" = 1 ] \
    && ok "and seen exactly once" \
    || fail "post-compaction duplicate" "printed $(count COMPACT-AFTER-CANARY) times"

echo
echo "== and rotated away entirely =="
# rotate_convo moves the whole file to the archive after CONVO_TIMEOUT; the next
# turn starts a fresh conversation, whose first line IS new speech.
mv "$CONVO" "$T/archived-convo.txt"
heard "ROTATED-FRESH-CANARY"
awaits ROTATED-FRESH-CANARY \
    && ok "the first message of a fresh conversation is seen" \
    || fail "rotation lost the next message" "ROTATED-FRESH-CANARY not in $OUT"
barrier
[ "$(count ROTATED-FRESH-CANARY)" = 1 ] \
    && ok "and seen exactly once" \
    || fail "rotation replay" "printed $(count ROTATED-FRESH-CANARY) times"

echo
echo "== a turn that dies outside the JSON protocol is not silence =="
# The CLI runs with 2>&1 onto this same fd. A bad flag prints a usage block and
# nothing else; dropped for failing json.loads, that turn rendered as a blank
# window, which reads exactly like a turn that never started.
printf 'Usage: claude [options] [prompt]\n' >> "$DESK_B"
awaits "Usage: claude" \
    && ok "the CLI's own error text is shown rather than dropped" \
    || fail "non-JSON output dropped" "the usage block is not in $OUT"

echo
echo "== what a tool handed back =="
python3 -c 'import json;print(json.dumps({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"TOOL-RESULT-CANARY"}]}}))' >> "$DESK_B"
awaits TOOL-RESULT-CANARY \
    && ok "a tool result is rendered" \
    || fail "tool results invisible" "TOOL-RESULT-CANARY not in $OUT"

echo
echo "== the sandbox held =="
# Not "no live text appeared" — what the viewer has OPEN. A test for the live
# instance's viewer must be unable to reach the live instance's logs, and the
# only honest proof of that is its own file descriptors.
leaked_fds() {
    local f target
    for f in /proc/"$VIEWER_PID"/fd/*; do
        target="$(readlink "$f" 2>/dev/null)" || continue
        case "$target" in
            "$T"/*|/dev/*|/proc/*|anon_inode:*|socket:*|pipe:*|"") ;;
            *) printf '%s\n' "$target" ;;
        esac
    done
}
LEAKED="$(leaked_fds)"
[ -z "$LEAKED" ] \
    && ok "the viewer has nothing open outside its scratch prefix" \
    || fail "the view escaped its sandbox" "open outside $T: $(printf '%s' "$LEAKED" | tr '\n' ' ')"

kill $VIEWER_PID 2>/dev/null

echo
echo "== a stream that has gone quiet, and comes back =="
# A finished session's log sits on disk for three hours, so a viewer left open
# all day holds a hundred dead files and re-reads every one twenty times a
# second — measured at 5 % of a core to print nothing. A quiet stream is let go
# and watched by its size instead, which must lose nothing when it speaks
# again: not the words written before it went quiet, and not by repeating them.
# The idle threshold is turned right down here rather than waiting two minutes.
DOZE="$T/doze"
DOZE_OUT="$T/doze-view.txt"
mkdir -p "$DOZE-sessions"
env -i PATH="$PATH" HOME="$T" LC_ALL=C.UTF-8 PYTHONIOENCODING=utf-8 \
    DESKCRAB_STATE_PREFIX="$DOZE" DESKCRAB_DEBUG_IDLE_SECS=0.4 \
    "$VIEWER" > "$DOZE_OUT" 2>&1 &
DOZE_PID=$!
trap 'kill '"$VIEWER_PID"' '"$DOZE_PID"' 2>/dev/null; rm -rf "$T"' EXIT
sleep 0.5
DOZE_LOG="$DOZE-debug-900007.log"
: > "$DOZE_LOG"
say "$DOZE_LOG" "BEFORE-THE-DOZE"
OUT="$DOZE_OUT"
awaits BEFORE-THE-DOZE || fail "quiet-stream setup" "BEFORE-THE-DOZE not in $DOZE_OUT"
sleep 1.2                      # well past the idle threshold: the fd is let go
say "$DOZE_LOG" "AFTER-THE-DOZE"
awaits AFTER-THE-DOZE \
    && ok "a stream that went quiet is picked up again when it writes" \
    || fail "quiet stream dropped" "AFTER-THE-DOZE not in $DOZE_OUT"
sleep 0.2
[ "$(count BEFORE-THE-DOZE)" = 1 ] \
    && ok "and what it said before is not replayed" \
    || fail "quiet-stream replay" "BEFORE-THE-DOZE printed $(count BEFORE-THE-DOZE) times"
kill $DOZE_PID 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
