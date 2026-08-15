#!/usr/bin/env bash
# A wake the session limit cuts off MID-RUN is a failed run, never a reply.
#
# The incident this holds the line against (2026-08-11, 00:17): a wake nine
# tool calls deep hit the five-hour limit. The CLI closed the stream with a
# synthetic assistant message — "You've hit your session limit · resets
# 1:30am" — and a final result line carrying is_error and no type field at
# all. The genuine tool calls before the cut made every judgement read the
# stream as a run that happened: the synthetic text was extracted as the
# reply, journalled as the wake's own words, surfaced in her voice, and
# nothing retried. The thought the wake was mid-way through was lost.
#
# What the contract demands instead (specs/account-fallback.md rules 12a and
# 12c, specs/wake-queue.md rule 23):
#   1. with credit elsewhere, the walk rides the cut to the next login AT
#      ONCE and the fallback's reply is the wake — nothing waits for a reset;
#   2. with the whole chain cut, the wake journals a failed run naming the
#      session limit, appends nothing to the conversation, and re-books
#      itself through the outage-retry path so the agenda survives.
#
# Everything here is stubbed, silent, and confined to the sandbox, exactly as
# tests/test_silent_wake.sh runs: run_claude_wake is called directly, in its
# own process, with PIDFILE set by hand.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"

FALLBACK_REPLY="The greenhouse latch could use a look before the frost comes back."
LIMIT_LINE="You've hit your session limit · resets 1:30am"

# The stub claude, cut shape: genuine tool work, then the CLI's own limit —
# the observed 2.1.219 stream, including the type-less is_error line. On the
# fallback login it answers instead.
FB="$WORK/fb-login"
mkdir -p "$FB"
sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
if [ "\${CLAUDE_CONFIG_DIR:-}" = "$FB" ]; then
    printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"$FALLBACK_REPLY"}]}}'
    printf '%s\n' '{"type":"result"}'
    exit 0
fi
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}'
printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"'"$LIMIT_LINE"'"}]}}'
printf '%s\n' '{"is_error":true,"duration_api_ms":31572,"num_turns":9}'
exit 1
EOF

cat > "$DESKCRAB_CONF" <<EOF
MEMORY_STORE=0
MEMORY_JUDGE=0
PROMISE_AUDIT=0
PROMISE_CHECK=0
CLAUDISM_CAPTURE=0
CLAUDE_BIN="$SANDBOX_BIN/claude"
WANTS_FILE="$WORK/wants.md"
WAKE_QUIET_HOURS=""
EOF
printf '# Wants\n\n- a want, so the wake path is enabled at all\n' > "$WORK/wants.md"

# Each wake runs as its own process, exactly as `crab wake` runs it, so the
# per-session stream log and the session record behave as they do live.
wake() { # <reason> [CLAUDE_FALLBACK_CONFIG_DIR value]
    env ${2:+CLAUDE_FALLBACK_CONFIG_DIR="$2"} bash -c '
        . "$1/lib/common.sh"
        PIDFILE="$2"
        WAKE_REASON="$3"
        run_claude_wake "(Autonomous wake — test)"
    ' _ "$REPO" "$PIDFILE" "$1" >/dev/null 2>&1
}

# shellcheck source=/dev/null
source "$REPO/lib/common.sh"          # for CONVOFILE, SESSIONS_LOG, WAKES_DIR
PIDFILE="$WORK/rec.pid"
rm -f "$PIDFILE"

# --- 1. the whole chain is cut: a failed run, a re-book, and no reply ------
: > "$CONVOFILE"
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
wake "a thought about the greenhouse latch"

grep -qi "session limit" "$CONVOFILE" \
    && die "the CLI's limit text entered the conversation as her words: $(cat "$CONVOFILE")"
[ -s "$CONVOFILE" ] \
    && die "a cut wake left something in the conversation: $(cat "$CONVOFILE")"
grep -q "session-limit cut it off mid-run" "$SESSIONS_LOG" \
    || die "the journal did not record the cut as a failed run: $(tail -n3 "$SESSIONS_LOG" 2>/dev/null)"

REBOOK="$(grep -l "outage-retry" "$WAKES_DIR"/*.wake 2>/dev/null | head -n1)"
[ -n "$REBOOK" ] \
    || die "no outage-retry re-book was written: $(ls "$WAKES_DIR" 2>/dev/null)"
grep -q "greenhouse latch" "$REBOOK" \
    || die "the re-book lost the wake's agenda: $(cat "$REBOOK")"

# specs/wake-queue.md rule 23a: a walk the limits ended does not re-book into
# the drought it just measured. The cut cooled the only account for the
# session window (~5 h), so the re-book is due around that expiry — never on
# the half-hour outage slot that produced the 2026-08-15 morning's
# eight-second refusal/re-book ping-pong. Upper bound is the cap plus jitter.
DUE="$(cut -f1 "$REBOOK" 2>/dev/null | head -n1)"
IN=$(( ${DUE:-0} - $(date +%s) ))
[ "$IN" -ge 17000 ] && [ "$IN" -le 21800 ] \
    || die "the re-book ignores the cooldown expiry: due in ${IN}s (record: $(cat "$REBOOK"))"

# --- 2. credit elsewhere: the fallback answers and the thought gets said ---
: > "$CONVOFILE"
rm -f "$WAKES_DIR"/*.wake 2>/dev/null
wake "the same thought, with a second login configured" "$FB"

grep -q "$FALLBACK_REPLY" "$CONVOFILE" \
    || die "the fallback's reply never reached the conversation: $(cat "$CONVOFILE")"
grep -qi "session limit" "$CONVOFILE" \
    && die "account 1's cut leaked into the conversation beside the reply: $(cat "$CONVOFILE")"
ls "$WAKES_DIR"/*.wake >/dev/null 2>&1 \
    && grep -q "outage-retry" "$WAKES_DIR"/*.wake 2>/dev/null \
    && die "a wake the fallback carried still re-booked itself: $(ls "$WAKES_DIR")"

# Account 1 was cooled by the first scenario's cut — that record is exactly
# why THIS wake made no doomed boot on it — so the NEXT wake leads with
# account 2 too: the selection skips the cooling account (rules 7 and 10).
# Asked of the selection itself, not read off the current line: the current
# never moved here because nothing refused in this scenario, and that is the
# design — a cooldown, not a re-cut, is what spares the boot.
grep -q "^cooldown	1	" "$ACCOUNT_STATE_FILE" 2>/dev/null \
    || die "the first scenario's cut left no cooldown for account 1: $(cat "$ACCOUNT_STATE_FILE" 2>/dev/null || echo "no record")"
NEXT="$(env CLAUDE_FALLBACK_CONFIG_DIR="$FB" bash -c '. "$1/lib/common.sh"; claude_account_pick' _ "$REPO" 2>/dev/null)"
[ "$NEXT" = "2" ] \
    || die "the next wake would not lead with account 2: pick=$NEXT, state: $(cat "$ACCOUNT_STATE_FILE" 2>/dev/null || echo "no record")"

# --- 3. a mixed walk keeps the ordinary outage slot (wake-queue rule 23a) --
# Account 1 is cut; the second login dies on the network with no limit text
# and no output. The walk was NOT wholly refused — its last attempt is an
# outage nothing measured a clearing time for — so the re-book stays on the
# free half-hour slot, never the cooldown-keyed wait. Judged from the walk's
# own per-attempt outcomes: the whole-log re-grep read this exact stream
# (account 1's limit text standing, nothing genuine after it) as a drought
# and parked the agenda on a ~5-hour cooldown the network death never earned.
NETDEAD="$WORK/netdead-login"
mkdir -p "$NETDEAD"
sandbox_stub claude <<EOF
#!/usr/bin/env bash
cat > /dev/null
if [ "\${CLAUDE_CONFIG_DIR:-}" = "$NETDEAD" ]; then
    echo "curl: (6) could not resolve host" >&2
    exit 6
fi
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"true"}}]}}'
printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"'"$LIMIT_LINE"'"}]}}'
printf '%s\n' '{"is_error":true,"duration_api_ms":31572,"num_turns":9}'
exit 1
EOF
: > "$CONVOFILE"
rm -f "$WAKES_DIR"/*.wake "$ACCOUNT_STATE_FILE" 2>/dev/null
wake "a mixed walk: a cut, then a network death" "$NETDEAD"

grep -qi "session limit" "$CONVOFILE" \
    && die "the mixed walk's cut leaked into the conversation: $(cat "$CONVOFILE")"
REBOOK="$(grep -l "outage-retry" "$WAKES_DIR"/*.wake 2>/dev/null | head -n1)"
[ -n "$REBOOK" ] \
    || die "the mixed walk never re-booked: $(ls "$WAKES_DIR" 2>/dev/null)"
DUE="$(cut -f1 "$REBOOK" 2>/dev/null | head -n1)"
IN=$(( ${DUE:-0} - $(date +%s) ))
[ "$IN" -ge 60 ] && [ "$IN" -le 4000 ] \
    || die "a mixed walk took the drought's wait: due in ${IN}s (record: $(cat "$REBOOK"))"

ok "a cut chain journals a failed run and re-books through outage-retry"
ok "a fallback with credit carries the wake and nothing re-books"
ok "a mixed walk re-books on the ordinary outage slot, not the drought's"
