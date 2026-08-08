#!/bin/bash
# The harness tests itself. Run: bash tests/test_sandbox.sh
#
# specs/test-harness.md asks for exactly this file: the helper pins every knob
# in the list, a test that tries to write a live path fails, a test that tries
# to book a real wake fails, a test that tries to start a real model session
# fails. Everything below is about the sandbox, not about DeskCrab.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

echo "every knob points inside the sandbox:"

# The list is the contract's list, in the contract's order: the config path,
# the state prefix, the wakes directory, the jobs directory, the memory
# directory, the account default file, the day journal directory, the state
# home, the data home, and the recorder pid file — plus the homes and the
# runtime directory that everything else is derived from.
for knob in DESKCRAB_CONF DESKCRAB_STATE_PREFIX WAKES_DIR JOBS_DIR \
            DESKCRAB_MEMORY_DIR ACCOUNT_DEFAULT_FILE DAY_JOURNAL_DIR \
            XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME \
            XDG_RUNTIME_DIR DESKCRAB_PIDFILE HOME TMPDIR ARCHIVE_DIR \
            NOTICE_STATE_DIR CLAUDE_BIN
do
    val="$(eval printf '%s' "\"\${$knob:-}\"")"
    case "$val" in
        "$SANDBOX"/*) ok "$knob is inside the sandbox" ;;
        "")           fail "$knob is unset" ;;
        *)            fail "$knob points outside the sandbox" "$val" ;;
    esac
done

# The fourth gate's opt-in: lib/wake-queue.sh refuses to create a unit from a
# scratch wakes directory unless a harness that has stubbed systemd-run says so.
check "the scratch-booking opt-in is set, so bookings are observable" \
    [ "${DESKCRAB_ALLOW_SCRATCH_BOOKING:-}" = 1 ]

# The clean environment is not a strip: nothing here unsets a variable the
# shipping code should be unsetting itself.
check "the developer's account choice is not inherited" \
    [ -z "${CLAUDE_CONFIG_DIR:-}" ]
check "the session bus is out of reach" \
    [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]

echo
echo "the desktop is stubbed from one directory:"
for tool in notify-send piper-tts aplay render-md hyprctl kitty ffmpeg \
            whisper-cli whisper-stream claude systemd-run systemctl; do
    got="$(command -v "$tool" 2>/dev/null)"
    check_eq "$tool resolves to the stub" "$got" "$SANDBOX_BIN/$tool"
done

echo
echo "the gates hold:"

# Spend. The CLI answers in the shape its callers parse, and it is a stub.
out="$("$CLAUDE_BIN" -p hello < /dev/null)"
check_eq "the CLI is the stub, not the real one" "$out" "stub reply."
check "and the attempt is on the record" \
    grep -q . "$SANDBOX_CLAUDE_LOG"

# Schedule. A booking is recorded and no unit is created.
systemd-run --user --quiet --unit=deskcrab-wake-selftest \
    --on-active=3600s /bin/true
check "a wake booking is accepted by the stub" [ "$?" = 0 ]
check "the booking was recorded" \
    grep -q "deskcrab-wake-selftest" "$SANDBOX_SYSTEMD_LOG"
check "no unit reached the user manager" \
    bash -c '! env XDG_RUNTIME_DIR="$SANDBOX_REAL_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$SANDBOX_REAL_DBUS" \
        /usr/bin/systemctl --user list-units "deskcrab-wake-selftest*" \
        --all --no-legend 2>/dev/null | grep -q deskcrab-wake-selftest'

# ...and the caller's cannot-defer branch is reachable on purpose.
sandbox_systemd_rc 1
systemd-run --user --quiet --unit=x --on-active=60s /bin/true
check "sandbox_systemd_rc turns a booking into a refusal" [ "$?" = 1 ]
sandbox_systemd_rc 0

# A detached child is refused so the caller takes its own setsid fallback —
# the shipped path, and the one that keeps the child inside this environment.
systemd-run --user --collect --quiet --unit=deskcrab-judge-selftest /bin/true
check "an immediate dispatch falls back to the caller's own setsid" [ "$?" = 1 ]

# Interrupt. Nothing reaches the speakers or the screen.
printf 'a sentence\n' | piper-tts > /dev/null
check "speech goes to the witness log, not the speakers" \
    grep -q "a sentence" "$SANDBOX_SPOKEN_LOG"
notify-send "a title" "a body"
check "notifications go to the witness log, not the desktop" \
    grep -q "a title" "$SANDBOX_NOTIFY_LOG"

echo
echo "the library loads against the sandbox, not the live instance:"
out="$(sandbox_bash 'printf "%s|%s|%s" "$WAKES_DIR" "$JOBS_DIR" "$ACCOUNT_DEFAULT_FILE"')"
check_eq "common.sh derives its paths from the pinned knobs" \
    "$out" "$WAKES_DIR|$JOBS_DIR|$ACCOUNT_DEFAULT_FILE"
out="$(sandbox_bash 'printf "%s" "$CONVOFILE"')"
check_eq "the conversation is the sandbox's own" \
    "$out" "$DESKCRAB_STATE_PREFIX-convo.txt"

echo
echo "a stub can be replaced without a second stub directory:"
sandbox_stub claude <<'STUB'
#!/bin/bash
printf 'replaced\n'
STUB
check_eq "sandbox_stub overwrites in place" "$("$CLAUDE_BIN")" "replaced"
check_eq "and PATH still has exactly one stub directory" \
    "$(command -v claude)" "$SANDBOX_BIN/claude"
