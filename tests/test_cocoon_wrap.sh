#!/bin/bash
# The cocoon wall — specs/cocoon.md rules 1, 4, 4b, 4c. Run: bash tests/test_cocoon_wrap.sh
#
# The wall is a bubblewrap mount namespace, so it is tested the way the kernel
# runs it: real writes, from inside a really-built wrap, against the really
# read-only repo — not a regex judged on strings. The probing stub CLI is the
# sharpest assertion here: it attempts a constituent write and a drawer write
# FROM INSIDE the wrapped process the turn actually launched, and reports both
# outcomes as its reply, so the pipeline test proves the wrap was in force for
# the very process that generates her words.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

command -v bwrap >/dev/null 2>&1 || sandbox_skip "bubblewrap is not installed"
# The probes below judge the real checkout through the wrap, which only means
# something where the checkout sits outside the wrap's writable set. A copy
# under /tmp is inside the rw /tmp bind by design — /tmp holds the turn's own
# state and is deliberately not constituent — so from there the probes would
# judge the bind, not the wall.
case "$SANDBOX_REPO" in
    /tmp/*) sandbox_skip "the repo checkout sits under /tmp, inside the wrap's writable set — the wall cannot be judged from here" ;;
esac

CONVO="$DESKCRAB_STATE_PREFIX-convo.txt"
cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WAKE_QUIET_HOURS=""
CLAUDE_MODEL="opus"
CLAUDE_EFFORT="low"
EOF

run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

# Her library — writing, not machinery — rides the writable set (rule 3). It
# has to exist before the wrap is built for the bind to be emitted.
mkdir -p "$SANDBOX/home/Library/moments"

echo "the wrap is bubblewrap over a read-only root with the drawers re-bound:"
ARGV="$(run 'cocoon_wrap_build && printf "%s\n" "${COCOON_WRAP_ARGV[@]}"')"
check "bubblewrap leads the argv" contains "$ARGV" "bwrap"
check "the whole filesystem is read-only" contains "$ARGV" "--ro-bind
/
/"
check "the wrapped process dies with its parent" contains "$ARGV" "--die-with-parent"
check "her data drawers are re-bound writable" contains "$ARGV" "$SANDBOX/data/deskcrab"
check "the state prefix directory is writable" contains "$ARGV" "$SANDBOX/state"
check "her library is re-bound writable — writing, not machinery" contains "$ARGV" "--bind
$SANDBOX/home/Library"

echo
echo "the kernel, not a pattern, answers a write (rules 1 and 4):"
# The repo under judgement is the real checkout — the same object the live
# wrap protects. On the read-only mount the write MUST die in the kernel; if
# it ever succeeds the wall is gone, the stray file is removed, and this test
# fails as loudly as it can.
PROBE="$SANDBOX_REPO/.cocoon-wrap-probe.$$"
OUT="$(run 'cocoon_wrap_build && "${COCOON_WRAP_ARGV[@]}" bash -c "echo x > '"$PROBE"'" 2>&1')" && RC=0 || RC=$?
if [ -e "$PROBE" ]; then
    rm -f "$PROBE"
    fail "THE WALL IS DOWN: a constituent write from inside the wrap reached the repo"
else
    ok "the constituent write left nothing behind"
fi
check "and it failed" [ "$RC" != 0 ]
check "with the kernel's own answer" contains "$OUT" "Read-only file system"
# A second constituent class: the live conf directory, which sits outside
# /tmp and is therefore read-only purely by the root bind. Nothing is written
# when the wall holds; if it ever lands, remove it and scream.
CONFPROBE="$SANDBOX_LIVE_CONF/.cocoon-wrap-probe.$$"
OUT="$(run 'cocoon_wrap_build && "${COCOON_WRAP_ARGV[@]}" bash -c "touch '"$CONFPROBE"'" 2>&1')" || true
check "a conf write dies the same death" contains "$OUT" "Read-only file system"
[ -e "$CONFPROBE" ] && { rm -f "$CONFPROBE"; fail "THE WALL IS DOWN: the conf write landed"; }

echo
echo "her drawers stay hers (rule 3):"
check "a drawer write from inside the wrap lands" \
    run 'cocoon_wrap_build && "${COCOON_WRAP_ARGV[@]}" bash -c "echo kept > \"$XDG_DATA_HOME/deskcrab/wrap-probe\" && grep -q kept \"$XDG_DATA_HOME/deskcrab/wrap-probe\""'

echo
echo "a full turn runs under the wrap — the probing stub reports from inside:"
# The stub CLI attempts both writes from inside the process the turn launched
# and answers with the verdicts, so extract_response carrying them proves the
# wrap held for the real generation path, not for a lookalike.
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "\${SANDBOX_CLAUDE_LOG:-/dev/null}"
cat > /dev/null
if echo probe 2>/dev/null > "\$DESKCRAB_SANDBOX_REPO/.cocoon-live-probe.\$\$"; then
    rm -f "\$DESKCRAB_SANDBOX_REPO/.cocoon-live-probe.\$\$"
    verdict="WRAP-ABSENT"
else
    verdict="WRAP-CONFIRMED"
fi
if echo probe 2>/dev/null > "\$XDG_DATA_HOME/deskcrab/live-drawer-probe"; then
    drawer="DRAWER-OK"
else
    drawer="DRAWER-SEALED"
fi
printf '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"%s %s"}]}}\n' "\$verdict" "\$drawer"
printf '{"type":"result","result":"%s %s"}\n' "\$verdict" "\$drawer"
STUB
printf 'User [12:00]: hello\nAssistant [12:00]: hello yourself\nUser [12:01]: an ordinary question\n' > "$CONVO"
: > "$SANDBOX_CLAUDE_LOG"
REPLY="$(run 'claude_generate "an ordinary question" 2>/dev/null')"
check "the CLI ran and a reply came back" contains "$REPLY" "WRAP-CONFIRMED"
check "the repo was read-only for the process that generated it" \
    contains "$REPLY" "WRAP-CONFIRMED"
check "and its drawer write landed" contains "$REPLY" "DRAWER-OK"
check "on disk too" grep -q probe "$XDG_DATA_HOME/deskcrab/live-drawer-probe"
check "the CLI was actually invoked" [ -s "$SANDBOX_CLAUDE_LOG" ]

echo
echo "the wake path runs under the same wall:"
: > "$SANDBOX_CLAUDE_LOG"
WOUT="$(run 'DEBUGLOG="${DESKCRAB_STATE_PREFIX}-wake-wrap.log"; SYSTEM_PROMPT=sys PROMPT_TEXT=agenda WAKE_MODEL=opus WAKE_EFFORT=low _wake_claude_run ""; echo "status=$WAKE_CLAUDE_STATUS"')"
check "the wake CLI ran to completion" contains "$WOUT" "status=0"
check "and its stream carries the in-wrap verdict" \
    grep -q "WRAP-CONFIRMED" "$DESKCRAB_STATE_PREFIX-wake-wrap.log"

echo
echo "no bubblewrap, no session — fail closed (rule 4b):"
: > "$SANDBOX_CLAUDE_LOG"
REPLY="$(run 'COCOON_BWRAP=/nonexistent-bwrap claude_generate "hello there" 2>/dev/null')" || true
check_eq "the turn produced no reply" "$(printf '%s' "$REPLY" | tr -d '[:space:]')" ""
check "the CLI was never launched" [ ! -s "$SANDBOX_CLAUDE_LOG" ]
REFUSED="$(cat "$SANDBOX"/state/deskcrab-debug-*.log 2>/dev/null)"
check "the stream log says why, by name" contains "$REFUSED" "cocoon-refused"
check "and names the missing wall" contains "$REFUSED" "bubblewrap"
WOUT="$(run 'DEBUGLOG="${DESKCRAB_STATE_PREFIX}-wake-refused.log"; SYSTEM_PROMPT=sys PROMPT_TEXT=agenda WAKE_MODEL=opus WAKE_EFFORT=low COCOON_BWRAP=/nonexistent-bwrap _wake_claude_run ""; echo "status=$WAKE_CLAUDE_STATUS"')"
check "a wake refuses the same way" contains "$WOUT" "status=79"
check "with the note in its own stream" \
    grep -q "cocoon-refused" "$DESKCRAB_STATE_PREFIX-wake-refused.log"

echo
echo "the wall sits on exactly the two run functions — builders stay outside:"
DEFS="$(sandbox_count_in '^cocoon_wrap_build()' "$SANDBOX_REPO/lib/common.sh")"
CALLS="$(sandbox_count_in 'if ! cocoon_wrap_build' "$SANDBOX_REPO/lib/common.sh")"
check_eq "one definition" "$DEFS" "1"
check_eq "two callers — the turn run and the wake run" "$CALLS" "2"
refute "the job runner never wraps" grep -q "cocoon_wrap" "$SANDBOX_REPO/lib/job-runner"
