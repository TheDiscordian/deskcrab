#!/usr/bin/env bash
# A volume-control window is not a person on the microphone.
# Run: bash tests/test_user_busy_mic.sh
#
# specs/wake-queue.md rule 27f. From 2026-10-24 22:36 to 2026-10-30 03:07 a
# pavucontrol window left open held 88 source-outputs — every one a peak meter,
# application.name "PulseAudio Volume Control", media.name "Peak detect" — and
# user_busy's microphone branch, one grep over the whole listing for any
# application name outside whisper|parley|crab|piper|aplay|arecord, called it
# a person mid-capture. Every own-time return for six nights was deferred
# "he is mid-capture or mid-speech at the desk", 230 times, with nobody at the
# desk at all.
#
# The reading is now made one stream at a time, and a peak meter never counts.
# The cases here are the whole boundary, each against a deterministic pactl
# listing under tests/data/pactl/ (pipewire-pulse's shape, taken from the live
# listing with the personal fields scrubbed, and PulseAudio's own shape):
#
#    1. nothing but pavucontrol's meters reads NOT busy — the pipewire shape,
#       the PulseAudio shape, and each of the window's marks standing alone
#    2. a browser, a meeting app and a recorder on the microphone each read
#       busy — the control half, without which case 1 proves nothing
#    3. the same captures beside the meters in one listing still read busy:
#       the judgement is per stream, so ignoring the meters hides nothing
#    4. the existing own-tooling exclusions still hold, alone and beside the
#       meters — and do not excuse a browser capture beside them
#    5. the line is the meter, never the monitor or the cork: a screen
#       recorder taking the desktop's audio and a corked browser capture both
#       still count; a nameless loopback output and an empty listing do not
#    6. a pactl that cannot reach the server reads not busy, as before
#    7. the readings that stand before the microphone — the push-to-talk
#       pidfile, the speech pidfile, a parley recording — each still say busy
#       over an idle listing
#
# Everything here is stubbed and confined to the sandbox: the only pactl on
# PATH is the stub, re-pointed at a fixture per case.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -o pipefail

REPO="$SANDBOX_REPO"
WORK="$SANDBOX"
FIX="$REPO/tests/data/pactl"

# The stub pactl answers `list source-outputs` with one fixture, verbatim, and
# records what it was asked so a case can prove the gate reached it at all.
listing() {  # <fixture basename>
    [ -f "$FIX/$1" ] || die "fixture missing: $FIX/$1"
    sandbox_stub pactl <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/pactl-asked.txt"
[ "\$1 \$2" = "list source-outputs" ] || exit 1
cat "$FIX/$1"
STUB
}

# user_busy exactly as a wake calls it: lib/common.sh sourced in the scratch
# instance, PIDFILE set by hand because `crab` sets it, not the library.
busy() {  # [PIDFILE] — 0 busy, 1 not
    bash -c '
        . "$1/lib/common.sh" >/dev/null 2>&1
        PIDFILE="$2"
        user_busy
    ' _ "$REPO" "${1:-$WORK/absent.pid}"
}

check_not_busy() {  # <desc> <fixture>
    listing "$2"
    if busy; then fail "$1" "busy"; else ok "$1"; fi
}
check_busy() {  # <desc> <fixture>
    listing "$2"
    if busy; then ok "$1"; else fail "$1" "not busy"; fi
}

echo "1. nothing but pavucontrol's peak meters is nobody on the microphone:"
check_not_busy "three pipewire-pulse meters — a sink monitor, a real input, a second monitor — read not busy" \
    pavucontrol-peaks-pipewire.txt
check_not_busy "PulseAudio's own shape of the same window reads not busy" \
    pavucontrol-peaks-pulseaudio.txt
check_not_busy "the application name alone marks a meter" mark-app-name-only.txt
check_not_busy "media.name \"Peak detect\" alone marks a meter" mark-media-name-only.txt
check_not_busy "the pavucontrol binary alone marks a meter" mark-binary-only.txt
check_not_busy "the pavucontrol application id alone marks a meter" mark-app-id-only.txt
check_not_busy "pipewire-pulse's resample.peaks alone marks a meter" mark-resample-peaks-only.txt
check_not_busy "PulseAudio's \"Resample method: peaks\" alone marks a meter" mark-resample-method-only.txt
check "the gate did ask pactl for the source outputs" \
    grep -q '^list source-outputs$' "$WORK/pactl-asked.txt"

echo "2. a genuine capture is still a person on the microphone:"
check_busy "a browser on the microphone reads busy" browser-capture.txt
check_busy "a meeting app on the microphone reads busy" meeting-capture.txt
check_busy "a recorder on the microphone reads busy" recorder-capture.txt

echo "3. the meters beside a capture hide nothing — the judgement is per stream:"
check_busy "meters around a browser capture: busy" mixed-peaks-and-browser.txt
check_busy "a meter before a meeting capture: busy" mixed-peaks-and-meeting.txt
check_busy "two meters then a recorder: busy" mixed-peaks-and-recorder.txt

echo "4. the own-tooling exclusions stand, and excuse nothing but her own tooling:"
check_not_busy "whisper, parley, crab, piper, aplay and arecord together read not busy" \
    own-tooling.txt
check_not_busy "the same six between two meters read not busy" own-tooling-and-peaks.txt
check_busy "whisper beside a browser capture does not excuse the browser" \
    own-tooling-and-browser.txt

echo "5. the line is the meter, never the monitor and never the cork:"
check_busy "a screen recorder taking the desktop's audio still counts" \
    recorder-monitor-capture.txt
check_busy "a corked browser capture — a muted microphone in a meeting — still counts" \
    browser-capture-corked.txt
check_not_busy "a nameless loopback output is not a person, as it never was" \
    nameless-loopback.txt
check_not_busy "an empty listing is not busy" empty.txt

echo "6. a pactl that cannot reach the server:"
sandbox_stub pactl <<STUB
#!/usr/bin/env bash
echo "Connection failure: Connection refused" >&2
exit 1
STUB
if busy; then fail "an unreachable server reads not busy" "busy"
else ok "an unreachable server reads not busy"; fi

echo "7. the readings before the microphone still stand over an idle listing:"
listing pavucontrol-peaks-pipewire.txt
touch "$WORK/held.pid"
if busy "$WORK/held.pid"; then ok "the push-to-talk pidfile says busy"
else fail "the push-to-talk pidfile says busy" "not busy"; fi
rm -f "$WORK/held.pid"
touch "${DESKCRAB_STATE_PREFIX}-tts.pid"
if busy; then ok "the speech pidfile says busy"
else fail "the speech pidfile says busy" "not busy"; fi
rm -f "${DESKCRAB_STATE_PREFIX}-tts.pid"
mkdir -p "$XDG_RUNTIME_DIR/parley"
echo '{}' > "$XDG_RUNTIME_DIR/parley/state.json"
if busy; then ok "a parley recording says busy"
else fail "a parley recording says busy" "not busy"; fi
rm -f "$XDG_RUNTIME_DIR/parley/state.json"
if busy; then fail "and with all three gone the meters alone are still not busy" "busy"
else ok "and with all three gone the meters alone are still not busy"; fi
