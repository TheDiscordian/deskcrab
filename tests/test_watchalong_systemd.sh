#!/bin/bash
# The production launch path for the reader unit — specs/watchalong.md rules 3, 8f and 25 —
# against a REAL user manager. Run: bash tests/test_watchalong_systemd.sh
#
# `start --launch-reader` hands the reader loop to `systemd-run --user` as a transient unit, and
# `stop` ends it through `systemctl --user stop`. The sandbox's stub records those calls and arms
# nothing, which is right for every other test and proves nothing about this path. So this file
# starts a PRIVATE user manager — the real systemd binary, under this test's own root, with a
# unit path holding nothing but its own transient units (the tests/test_wake_reload_drift.sh
# recipe) — and runs the real systemd-run and systemctl against it. The live manager stays out of
# reach as it always has; everything started here dies with the test.
#
# The unit's reader cuts and reviews a private synthetic source, and its observer thread follows
# a headless MPRIS fixture player on a private bus whose address is forwarded into the unit. A
# pause made on that player reaches the session as the unit's own anchor. Nothing is played.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
for tool in /usr/bin/ffmpeg /usr/bin/ffprobe /usr/bin/montage /usr/bin/dbus-daemon; do
    [ -x "$tool" ] || sandbox_skip "$tool is not installed"
done
python3 -c 'import PIL, numpy' 2>/dev/null || sandbox_skip "python3 PIL/numpy are not installed"
python3 -c 'import gi; gi.require_version("Gio", "2.0"); from gi.repository import Gio' 2>/dev/null \
    || sandbox_skip "PyGObject (gi.repository.Gio) is not installed; the observer cannot read a bus"

# --- the private manager (the recipe of tests/test_wake_reload_drift.sh) ---------------------
M="$T/mgr"
mkdir -p "$M/run" "$M/home" "$M/units" "$T/realbin"
chmod 700 "$M/run"
REAL_RUN="$(PATH=/usr/bin:/bin command -v systemd-run 2>/dev/null)"
REAL_CTL="$(PATH=/usr/bin:/bin command -v systemctl 2>/dev/null)"
SYSTEMD_BIN=""
for _c in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    [ -x "$_c" ] && { SYSTEMD_BIN="$_c"; break; }
done
[ -n "$REAL_RUN" ] && [ -n "$REAL_CTL" ] && [ -n "$SYSTEMD_BIN" ] ||
    sandbox_skip "no systemd on this box — the launch this test performs needs a real user manager"
for _t in default basic shutdown exit; do
    printf '[Unit]\nDescription=private test manager (%s)\n' "$_t" > "$M/units/$_t.target"
done
env -i PATH="$PATH" HOME="$M/home" XDG_RUNTIME_DIR="$M/run" \
    XDG_CONFIG_HOME="$M/home/.config" XDG_DATA_HOME="$M/home/.local/share" \
    SYSTEMD_UNIT_PATH="$M/run/systemd/transient:$M/units" \
    setsid "$SYSTEMD_BIN" --user --log-target=console > "$M/mgr.log" 2>&1 &
MGR_PID=$!
mgr_stop() {
    kill -s RTMIN+24 "$MGR_PID" 2>/dev/null
    local n=0
    while kill -0 "$MGR_PID" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$(( n + 1 )); done
    kill -KILL "$MGR_PID" 2>/dev/null
    chmod -R u+rwx "$M" 2>/dev/null
}
sandbox_at_exit mgr_stop
_n=0
until [ -S "$M/run/systemd/private" ] || ! kill -0 "$MGR_PID" 2>/dev/null || [ "$_n" -ge 100 ]; do
    sleep 0.1; _n=$(( _n + 1 ))
done
[ -S "$M/run/systemd/private" ] && kill -0 "$MGR_PID" 2>/dev/null ||
    sandbox_skip "a private user manager could not be started here ($(tail -1 "$M/mgr.log" 2>/dev/null))"
ln -s "$REAL_RUN" "$T/realbin/systemd-run"
ln -s "$REAL_CTL" "$T/realbin/systemctl"
ctl() { XDG_RUNTIME_DIR="$M/run" "$REAL_CTL" --user "$@" 2>/dev/null; }
check_eq "the private manager is up and holds no watchalong unit" \
    "$(ctl list-units --all --no-legend 'deskcrab-watchalong-*' | wc -l)" "0"

# --- the bus, the fixture, the player ------------------------------------------------------
export DESKCRAB_FFMPEG=/usr/bin/ffmpeg DESKCRAB_FFPROBE=/usr/bin/ffprobe \
    DESKCRAB_WHISPER_CLI=/usr/bin/whisper-cli DESKCRAB_MONTAGE=/usr/bin/montage
export DESKCRAB_WATCHALONG_DIR="$T/data/deskcrab/watchalong"
export WATCHALONG_WHISPER_MODEL="$T/no-such-model.bin"
unset WATCHALONG_CLOCK_FILE
BUS_SOCK="$T/run/bus.sock"
BUS_ADDR="$(/usr/bin/dbus-daemon --session --fork --address="unix:path=$BUS_SOCK" --print-address=1 --print-pid=3 3>"$T/bus.pid")"
check "the private bus is up" test -S "$BUS_SOCK"
sandbox_at_exit "kill \$(cat '$T/bus.pid') 2>/dev/null"
export DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR"
# The module, with the real systemd tools first on PATH and the private manager's runtime dir —
# both forwarded into the unit it launches, with the bus address (rule 8h, the data section).
WA() { PATH="$T/realbin:$PATH" XDG_RUNTIME_DIR="$M/run" python3 "$REPO/lib/watchalong" "$@"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
wait_for() { local limit="$1" i=0; shift; until "$@" 2>/dev/null; do [ "$i" -ge $((limit * 4)) ] && return 1; sleep 0.25; i=$((i + 1)); done; }
wait_log() { local n="$1" pat="$2" f="$3" limit="${4:-20}"
    wait_for "$limit" bash -c 'c="$(grep -c -- "$2" "$3" 2>/dev/null)"; [ "${c:-0}" -ge "$1" ]' _ "$n" "$pat" "$f"; }

echo "painting the private fixture (60 s, no speech):"
FX="$T/fixture"
python3 "$REPO/lib/watchalong_fixture.py" generate --out "$FX" --seconds 60 --scene-seconds 10 --no-speech >/dev/null 2>&1
check "the fixture was written" test -s "$FX/fixture.mp4"
CTL="$T/control"; PLOG="$T/player.log"; : > "$CTL"
python3 "$REPO/lib/watchalong_fixture.py" player --source "$FX/fixture.mp4" --control "$CTL" --position 0 --log "$PLOG" \
    </dev/null >/dev/null 2>&1 &
PPID_FX=$!
sandbox_at_exit "kill $PPID_FX 2>/dev/null"
check "the fixture player is on the private bus" wait_log 1 "player up" "$PLOG" 10

echo
echo "start --launch-reader puts the reader unit into the manager through the real systemd-run:"
WA start --source "$FX/fixture.mp4" --title "Fixture, unit" \
    --authorized-by "the test harness, on a private manager" --ttl 600 --player mpris --launch-reader fixture \
    > "$T/start.txt" 2>&1
check "start succeeded" grep -q "^started " "$T/start.txt"
SID="$(cat "$DESKCRAB_WATCHALONG_DIR/current")"
SJ="$DESKCRAB_WATCHALONG_DIR/sessions/$SID/session.json"
UNIT="deskcrab-watchalong-$SID"
check_eq "the launch returned 0" "$(jget "$SJ" "d['reader_launch']['rc']")" "0"
check_eq "and the session names its unit" "$(jget "$SJ" "d['reader_unit']")" "$UNIT"
check "start printed the unit" grep -q "reader unit $UNIT" "$T/start.txt"
check "the sandbox's stub was NOT what ran" test ! -s "$SANDBOX_SYSTEMD_LOG"
check_eq "the manager lists the unit active" "$(ctl show "$UNIT.service" -p ActiveState --value)" "active"
MAINPID="$(ctl show "$UNIT.service" -p MainPID --value)"
check "with a main process" bash -c '[ "${1:-0}" -gt 0 ] && kill -0 "$1"' _ "$MAINPID"
check "which is the reader loop" bash -c 'tr "\0" " " < "/proc/$1/cmdline" | grep -q "watchalong reader --loop --reviewer fixture"' _ "$MAINPID"
check "carrying the forwarded environment: the scratch data dir" bash -c 'tr "\0" "\n" < "/proc/$1/environ" | grep -qx "DESKCRAB_WATCHALONG_DIR=$2"' _ "$MAINPID" "$DESKCRAB_WATCHALONG_DIR"
check "and the private bus address" bash -c 'tr "\0" "\n" < "/proc/$1/environ" | grep -qx "DBUS_SESSION_BUS_ADDRESS=$2"' _ "$MAINPID" "$DBUS_SESSION_BUS_ADDRESS"
check "the unit's reader keeps a log in the session" wait_log 1 "observer started for mpris" "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/reader.log" 10
check "status names the unit" bash -c 'PATH="$2:$PATH" XDG_RUNTIME_DIR="$3" python3 "$1" status | grep -q "reader unit: $4"' _ "$REPO/lib/watchalong" "$T/realbin" "$M/run" "$UNIT"

echo
echo "the unit works unattended: a receipt lands, and a pause on the player is its observer's anchor:"
check "a receipt lands from inside the unit" wait_for 45 bash -c '[ "$(ls "$1/sessions/$2/receipts/" 2>/dev/null | wc -l)" -ge 1 ]' _ "$DESKCRAB_WATCHALONG_DIR" "$SID"
R1="$(ls "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/receipts/" | head -1)"
check_eq "filed by the fixture decoder" "$(jget "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/receipts/$R1" "d['reviewer']")" "fixture-decoder"
echo pause >> "$CTL"
check "the player paused" wait_log 1 "applied: pause" "$PLOG"
check "the unit's observer thread filed it" wait_log 1 "observer: epoch [0-9]* — player watchalong fixture (plays nothing): paused at" "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/reader.log" 10
check_eq "the session is paused by player telemetry" "$(jget "$SJ" "(d['anchor']['playing'], d['anchor']['basis'])")" "(False, 'player-telemetry')"
check "and the next prompt block says so" bash -c 'PATH="$2:$PATH" XDG_RUNTIME_DIR="$3" python3 "$1" prompt-block | grep -q "Where he is: PAUSED at .* his player watchalong fixture (plays nothing) reports Paused"' _ "$REPO/lib/watchalong" "$T/realbin" "$M/run"

echo
echo "stop ends the unit through the real systemctl, and --collect leaves nothing behind (rule 3):"
WA stop --reason "end of the unit test" > "$T/stop.txt" 2>&1
check "stop reported" grep -q "^stopped $SID" "$T/stop.txt"
check "the unit is gone from the manager" wait_for 20 bash -c '[ "$(XDG_RUNTIME_DIR="$2" "$1" --user list-units --all --no-legend "$3.service" 2>/dev/null | wc -l)" = 0 ]' _ "$REAL_CTL" "$M/run" "$UNIT"
check "its process is gone" wait_for 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$MAINPID"
check "the reader log says why it ended: the unit was stopped, or the session was gone" grep -Eq "reader: SIGTERM — the unit was stopped; exiting|session (STOPPED|INACTIVE): exiting" "$DESKCRAB_WATCHALONG_DIR/sessions/$SID/reader.log"
check_eq "the record is stopped" "$(jget "$SJ" "d['state']")" "stopped"
check_eq "no watchalong unit remains" "$(ctl list-units --all --no-legend 'deskcrab-watchalong-*' | wc -l)" "0"

echo
echo "nothing here speaks, plays or notifies (rule 26):"
check "no synthesiser input" test ! -s "$SANDBOX_SPOKEN_LOG"
check "no player call" test ! -s "$SANDBOX_PLAYED_LOG"
check "no notification" test ! -s "$SANDBOX_NOTIFY_LOG"
echo quit >> "$CTL"
