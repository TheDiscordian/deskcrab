#!/bin/bash
# The player observer — specs/watchalong.md rules 8a–8h, on the real clock.
# Run: bash tests/test_watchalong_player.sh        (about two minutes of real clock)
#
# A headless MPRIS player (lib/watchalong_fixture.py player) sits on a PRIVATE session bus
# started here: it owns org.mpris.MediaPlayer2.watchalong_fixture, reports a position that
# advances on its own clock, names the source in its metadata, and is driven by lines appended
# to a control file. It plays nothing and opens nothing. The observer reads it the way it would
# read VLC or a browser, and every pause, seek, loss and return below reaches the session as an
# anchor the observer filed — never as a `pause`, `resume` or `anchor` command from this test.
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

export DESKCRAB_FFMPEG=/usr/bin/ffmpeg DESKCRAB_FFPROBE=/usr/bin/ffprobe \
    DESKCRAB_WHISPER_CLI=/usr/bin/whisper-cli DESKCRAB_MONTAGE=/usr/bin/montage
export DESKCRAB_WATCHALONG_DIR="$T/data/deskcrab/watchalong"
export WATCHALONG_WHISPER_MODEL="$T/no-such-model.bin"   # transcripts fail fast and honestly; not the subject here
unset WATCHALONG_CLOCK_FILE DBUS_SESSION_BUS_ADDRESS
WA() { python3 "$REPO/lib/watchalong" "$@"; }
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
status_json() { WA status --json > "$T/status.json"; }
sj() { jget "$T/status.json" "$1"; }
sess() { jget "$DESKCRAB_WATCHALONG_DIR/sessions/$(cat "$DESKCRAB_WATCHALONG_DIR/current")/session.json" "$1"; }
wait_for() {  # <seconds> <command...> — until the command succeeds
    local limit="$1" i=0; shift
    until "$@" 2>/dev/null; do [ "$i" -ge $((limit * 4)) ] && return 1; sleep 0.25; i=$((i + 1)); done
}
wait_log() {  # <count> <pattern> <file> [seconds] — until the file holds that many matching lines
    local n="$1" pat="$2" f="$3" limit="${4:-20}"
    wait_for "$limit" bash -c 'c="$(grep -c -- "$2" "$3" 2>/dev/null)"; [ "${c:-0}" -ge "$1" ]' _ "$n" "$pat" "$f"
}

echo "painting the private fixture (240 s, 10 s scenes, no speech):"
FX="$T/fixture"
python3 "$REPO/lib/watchalong_fixture.py" generate --out "$FX" --seconds 240 --scene-seconds 10 --no-speech >/dev/null 2>&1
check "the fixture was written" test -s "$FX/fixture.mp4"

echo
echo "no bus: a session with a player waits, autolaunches nothing, and says why (rule 8h):"
WA start --source "$FX/fixture.mp4" --title "No bus" --authorized-by "the test harness" --ttl 600 \
    --position 12 --player mpris > "$T/start1.txt" 2>&1
check "start succeeded without a bus" grep -q "^started " "$T/start1.txt"
status_json
check_eq "the anchor is his word" "$(sj "d['anchor']['basis']")" "user-stated"
check_eq "telemetry is waiting" "$(sj "d['telemetry']['state']")" "waiting"
check "with the reason" bash -c '[ "$(python3 -c "import json;print(json.load(open(\"$1\"))[\"telemetry\"][\"last_error\"])")" != None ]' _ "$T/status.json"
check "naming the missing bus" bash -c 'python3 "$1" status | grep -q "player: WAITING for mpris .*no session bus"' _ "$REPO/lib/watchalong"
check "no dbus-daemon was launched for it" bash -c '! pgrep -f "dbus-daemon.*autolaunc[h]" >/dev/null'
B="$(WA prompt-block)"
check "the layer says no player has been found yet" bash -c 'printf "%s" "$1" | grep -q "No player has been found yet (looking for mpris since"' _ "$B"
check "labels the number an ESTIMATE from his own anchor" bash -c 'printf "%s" "$1" | grep -q "Where he is: about 00:1[0-9].[0-9], an ESTIMATE — his own anchor at"' _ "$B"
check "and still names the command that files his word" bash -c 'printf "%s" "$1" | grep -q "file it with .lib/watchalong anchor"' _ "$B"
OUT="$(WA observe --once 2>&1)"; RC=$?
check_eq "a one-shot observe exits cleanly" "$RC" "0"
status_json
check_eq "and the session still waits" "$(sj "d['telemetry']['state']")" "waiting"
WA stop --reason "no bus" >/dev/null

echo
echo "a private session bus and the headless player:"
BUS_SOCK="$T/run/bus.sock"
BUS_ADDR="$(/usr/bin/dbus-daemon --session --fork --address="unix:path=$BUS_SOCK" --print-address=1 --print-pid=3 3>"$T/bus.pid")"
check "the bus is up" test -S "$BUS_SOCK"
sandbox_at_exit "kill \$(cat '$T/bus.pid') 2>/dev/null"
export DBUS_SESSION_BUS_ADDRESS="$BUS_ADDR"
CTL="$T/control"; PLOG="$T/player.log"
: > "$CTL"
player() {  # <position> [extra args...] — start the fixture player; waits until it is on the bus
    local n; n="$(grep -c "player up" "$PLOG" 2>/dev/null)"; n="${n:-0}"
    python3 "$REPO/lib/watchalong_fixture.py" player --source "$FX/fixture.mp4" --control "$CTL" \
        --position "$1" --log "$PLOG" "${@:2}" </dev/null >/dev/null 2>&1 &
    PPID_FX=$!
    sandbox_at_exit "kill $PPID_FX 2>/dev/null"
    wait_log $((n + 1)) "player up" "$PLOG" 10
}
player 30
check "the player owns its MPRIS name" grep -q "player up as org.mpris.MediaPlayer2.watchalong_fixture: Playing at 30\.[0-9]" "$PLOG"
check "nothing was played" test ! -s "$SANDBOX_PLAYED_LOG"

echo
echo "start looks at the player once and opens on its real position (rules 8a, 8b):"
WA start --source "$FX/fixture.mp4" --title "Fixture" --authorized-by "the test harness, watching on the fixture player" \
    --ttl 600 --position 0 --player mpris > "$T/start2.txt" 2>&1
check "start succeeded" grep -q "^started " "$T/start2.txt"
check "and says the observer re-anchored to the player" grep -q "observer: epoch 2 — player watchalong fixture (plays nothing): playing at 00:30" "$T/start2.txt"
status_json
check_eq "epoch 2: the player's position replaced his nominal zero" "$(sj "d['epoch']")" "2"
check_eq "with basis player-telemetry" "$(sj "d['anchor']['basis']")" "player-telemetry"
check "at about thirty seconds" bash -c '[ "$(python3 -c "import json;print(int(json.load(open(\"$1\"))[\"anchor\"][\"position\"]))")" = 30 ]' _ "$T/status.json"
check_eq "telemetry connected" "$(sj "d['telemetry']['state']")" "connected"
check_eq "the source checked as the same file" "$(sj "d['telemetry']['source_verified']")" "same file"
check "status names the player" bash -c 'python3 "$1" status | grep -q "player: CONNECTED watchalong fixture (plays nothing), Playing at 00:30"' _ "$REPO/lib/watchalong"
B="$(WA prompt-block)"
check "the layer says the position is READ FROM HIS PLAYER" bash -c 'printf "%s" "$1" | grep -q "Where he is: about 00:3[0-9].[0-9], READ FROM HIS PLAYER watchalong fixture (plays nothing) — its last reading was 00:30"' _ "$B"
check "that a pause or a seek files itself" bash -c 'printf "%s" "$1" | grep -q "A pause or a seek on that player is seen within a few seconds and files itself as a new anchor; do not ask him where he is"' _ "$B"
check "and that his word still outranks the reading" bash -c 'printf "%s" "$1" | grep -q "If he says otherwise, his word outranks the reading"' _ "$B"
check "it no longer claims to read no player" bash -c 'printf "%s" "$1" | grep -vq "reads no player"' _ "$B"

echo
echo "the observer loop files what the player does, and nothing is said to it (rules 8b, 8d):"
OLOG="$T/observer.log"
WA observe --loop --poll 0.5 --log "$OLOG" </dev/null >/dev/null 2>&1 &
OPID=$!
sandbox_at_exit "kill $OPID 2>/dev/null"
check "the loop is running" kill -0 "$OPID"
R0="$(sess "d['telemetry']['readings']")"
check "readings accumulate without opening an epoch" wait_for 10 bash -c '[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"telemetry\"][\"readings\"])" "$1")" -ge $(($2 + 4)) ]' _ "$DESKCRAB_WATCHALONG_DIR/sessions/$(cat "$DESKCRAB_WATCHALONG_DIR/current")/session.json" "$R0"
check_eq "still epoch 2" "$(sess "d['epoch']")" "2"
EST="$(WA estimate | python3 -c 'import json,sys; print(json.load(sys.stdin)["estimate"])')"
PPOS="$(python3 - "$PLOG" <<'EOF'
import re, sys, time
# the player's own position now: 30 + elapsed since "player up" on its monotonic clock
for line in open(sys.argv[1]):
    m = re.search(r"mono=([0-9.]+) player up .*: Playing at ([0-9.]+)", line)
    if m: t0, p0 = float(m.group(1)), float(m.group(2))
print(p0 + (time.monotonic() - t0))
EOF
)"
check "the estimate tracks the player's own position within a second" python3 -c 'import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 1.0 else 1)' "$EST" "$PPOS"

echo pause >> "$CTL"
check "the player paused (its own log)" wait_log 1 "applied: pause" "$PLOG"
check "the observer saw it" wait_log 1 "observer: epoch 3 — player watchalong fixture (plays nothing): paused at 00:3" "$OLOG"
status_json
check_eq "epoch 3, paused" "$(sj "(d['epoch'], d['playing'])")" "(3, False)"
check_eq "filed by the observer, not a hand" "$(sj "d['anchor']['basis']")" "player-telemetry"
check "the note says what it saw" bash -c '[ "$(python3 -c "import json;print(json.load(open(\"$1\"))[\"anchor\"][\"quote\"])")" != "" ]' _ "$T/status.json"
E1="$(sj "round(d['estimate'], 1)")"; sleep 1.2; status_json
check_eq "the estimate is frozen" "$(sj "round(d['estimate'], 1)")" "$E1"
B="$(WA prompt-block)"
check "the layer says PAUSED, by the player's report" bash -c 'printf "%s" "$1" | grep -q "Where he is: PAUSED at 00:3[0-9].[0-9] — his player watchalong fixture (plays nothing) reports Paused since"' _ "$B"
check "and that the observer will see it play again" bash -c 'printf "%s" "$1" | grep -q "which the observer sees on its own"' _ "$B"

echo "seek 5" >> "$CTL"
check "a seek back while paused is an anchor" wait_log 1 "observer: epoch 4 — player watchalong fixture (plays nothing): seeked back from about 00:3[0-9].[0-9] to 00:05.0 (paused)" "$OLOG"
echo resume >> "$CTL"
check "a resume is an anchor, re-opening the chain where it was paused" wait_log 1 "observer: epoch 5 — player watchalong fixture (plays nothing): resumed from 00:05.0" "$OLOG"
status_json
check_eq "epoch 5, playing from five seconds" "$(sj "(d['epoch'], d['playing'], int(d['anchor']['position']))")" "(5, True, 5)"

echo
echo "a pending packet is superseded by an observed seek (rules 7, 8b):"
check "the estimate reaches fifteen seconds" wait_for 20 bash -c '[ "$(python3 "$1" estimate | python3 -c "import json,sys; print(int(json.load(sys.stdin)[\"estimate\"]))")" -ge 15 ]' _ "$REPO/lib/watchalong"
OUT="$(WA extract --min 6 --max 10 2>&1)"
check "a packet was cut in epoch 5" bash -c 'printf "%s" "$1" | grep -q "^e005-.* ok: "' _ "$OUT"
PA="$(printf '%s' "$OUT" | awk '{ print $1 }')"
check "and is pending" bash -c 'python3 "$1" packets | grep -q "^$2 pending "' _ "$REPO/lib/watchalong" "$PA"
echo "seek 40" >> "$CTL"
check "a forward seek while playing is an anchor" wait_log 1 "observer: epoch 6 — player watchalong fixture (plays nothing): seeked forward from about 00:1[0-9].[0-9] to 00:4[0-9].[0-9] (playing)" "$OLOG"
check "the pending packet is superseded" bash -c 'python3 "$1" packets | grep -q "^$2 superseded "' _ "$REPO/lib/watchalong" "$PA"
OUT="$(WA review "$PA" --reviewer hand:test --observation "x" 2>&1)"; RC=$?
check_eq "and cannot be reviewed" "$RC" "2"
check "stale epoch" bash -c 'printf "%s" "$1" | grep -q "stale epoch"' _ "$OUT"
check "the extraction cursor moved to where he went" bash -c '[ "$(python3 "$1" status --json | python3 -c "import json,sys; print(int(json.load(sys.stdin)[\"extraction_cursor\"]))")" = 40 ]' _ "$REPO/lib/watchalong"

echo
echo "the player goes away: lost, the estimate from its last reading, retrying (rule 8e):"
echo quit >> "$CTL"
check "the player left the bus" wait_log 1 "player down" "$PLOG"
check "the observer says LOST, with the reason" wait_log 1 "observer: LOST — player watchalong_fixture left the bus" "$OLOG" 15
status_json
check_eq "telemetry lost" "$(sj "d['telemetry']['state']")" "lost"
check_eq "the epoch is unchanged" "$(sj "d['epoch']")" "6"
E2="$(sj "d['estimate']")"
check "the estimate keeps running from the last reading" wait_for 5 bash -c '[ "$(python3 "$1" estimate | python3 -c "import json,sys; print(json.load(sys.stdin)[\"estimate\"] > float(sys.argv[1]) + 0.5)" "$2")" = True ]' _ "$REPO/lib/watchalong" "$E2"
B="$(WA prompt-block)"
check "the layer says the player went away, when, and what the number rests on" bash -c 'printf "%s" "$1" | grep -q "an ESTIMATE — his player watchalong fixture (plays nothing) went away at [0-9:]* ([0-9]* s ago; player watchalong_fixture left the bus) and this is its last reading, playing at 00:4[0-9].[0-9] plus elapsed time"' _ "$B"
check "and that a pause or a seek cannot be seen meanwhile" bash -c 'printf "%s" "$1" | grep -q "Since then a pause or a seek cannot be seen; the observer is retrying"' _ "$B"
check "status says LOST since" bash -c 'python3 "$1" status | grep -q "player: LOST watchalong fixture (plays nothing) since"' _ "$REPO/lib/watchalong"

echo
echo "the player comes back where the estimate says: the epoch is kept (rule 8e):"
EST="$(WA estimate | python3 -c 'import json,sys; print(json.load(sys.stdin)["estimate"])')"
: > "$CTL"
player "$EST"
check "the observer reconnected" wait_log 1 "observer: CONNECTED to watchalong fixture" "$OLOG" 15
check "readings resume" wait_for 10 bash -c '[ "$(python3 "$1" status --json | python3 -c "import json,sys; print(json.load(sys.stdin)[\"telemetry\"][\"state\"])")" = connected ]' _ "$REPO/lib/watchalong"
status_json
check_eq "still epoch 6: an agreeing return is no seek" "$(sj "d['epoch']")" "6"
check "and the layer reads from the player again" bash -c 'python3 "$1" prompt-block | grep -q "READ FROM HIS PLAYER"' _ "$REPO/lib/watchalong"

echo
echo "the player comes back somewhere else: a resync anchor (rule 8e):"
echo quit >> "$CTL"
check "gone again" wait_log 2 "player down" "$PLOG"
check "lost again" wait_log 2 "observer: LOST" "$OLOG" 15
: > "$CTL"
player 20 --paused
check "the observer reconnected and re-anchored" wait_log 1 "observer: epoch 7 — player watchalong fixture (plays nothing): paused at 00:20.0 (the session had playing at" "$OLOG" 15
status_json
check_eq "epoch 7, paused at twenty" "$(sj "(d['epoch'], d['playing'], int(d['anchor']['position']))")" "(7, False, 20)"
check_eq "the resync is named as the last action" "$(sj "d['telemetry']['last_action']['kind']")" "connected"

echo
echo "the wrong file: mismatch, not followed, then followed again (rule 8c):"
echo resume >> "$CTL"
check "playing again (epoch 8)" wait_log 1 "observer: epoch 8 — player watchalong fixture (plays nothing): resumed from 00:20.0" "$OLOG"
echo "url file:///somewhere/else/another-episode.mkv" >> "$CTL"
check "the observer says MISMATCH and names both" wait_log 1 "observer: MISMATCH — watchalong fixture (plays nothing) (org.mpris.MediaPlayer2.watchalong_fixture) is playing file:///somewhere/else/another-episode.mkv, not the source fixture.mp4; not followed" "$OLOG"
echo "seek 50" >> "$CTL"
check "the player seeked" wait_log 2 "applied: seek" "$PLOG"
sleep 1.5
status_json
check_eq "no anchor was filed from the wrong file" "$(sj "d['epoch']")" "8"
check_eq "telemetry mismatch" "$(sj "d['telemetry']['state']")" "mismatch"
B="$(WA prompt-block)"
check "the layer says the player is on something else and the number is an estimate" bash -c 'printf "%s" "$1" | grep -q "an ESTIMATE — the player.s last anchor at .*His player watchalong fixture (plays nothing) is on something else (file:///somewhere/else/another-episode.mkv), not this source, so it is not followed; the observer keeps checking it"' _ "$B"
echo "url file://$FX/fixture.mp4" >> "$CTL"
check "back on the source: connected, and the seek it made meanwhile is a resync anchor" wait_log 1 "observer: epoch 9 — player watchalong fixture (plays nothing): playing at 00:5[0-9].[0-9] (the session had playing at 00:2" "$OLOG"
status_json
check_eq "epoch 9, following again" "$(sj "(d['epoch'], d['telemetry']['state'])")" "(9, 'connected')"

echo
echo "a copy of the same name elsewhere is followed and said so (rule 8c):"
echo "url file:///media/nas/show/fixture.mp4" >> "$CTL"
check "the observer stays connected" wait_for 5 bash -c '[ "$(python3 "$1" status --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[\"telemetry\"][\"state\"], d[\"telemetry\"][\"source_verified\"])")" = "connected by name" ]' _ "$REPO/lib/watchalong"
check "and the layer says the match is by name" bash -c 'python3 "$1" prompt-block | grep -q "READ FROM HIS PLAYER watchalong fixture (plays nothing) (it names a file of the same name, matched by name)"' _ "$REPO/lib/watchalong"

echo
echo "stop under the lock: the observer honours it and resurrects nothing (rules 3, 8f, 8g):"
SJ="$DESKCRAB_WATCHALONG_DIR/sessions/$(cat "$DESKCRAB_WATCHALONG_DIR/current")/session.json"
check "the lock file exists beside the record" test -e "$(dirname "$SJ")/.lock"
WA stop --reason "end of the player test" >/dev/null
check "the observer loop exited" wait_for 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$OPID"
check "saying the session was stopped" grep -q "observer: session STOPPED: exiting\|observer: no session: exiting" "$OLOG"
check_eq "the record says stopped" "$(jget "$SJ" "d['state']")" "stopped"
echo pause >> "$CTL"
check "the player paused after the stop" wait_log 2 "applied: pause" "$PLOG"
sleep 1
check_eq "and nothing wrote the record again" "$(jget "$SJ" "(d['state'], d['epoch'])")" "('stopped', 9)"

echo
echo "the observer as the reader's thread: one process, both jobs (rule 8f):"
: > "$CTL"
echo quit >> "$CTL"
check "the old player is gone" wait_log 3 "player down" "$PLOG"
: > "$CTL"
player 0
WA start --source "$FX/fixture.mp4" --title "Fixture, reader" --authorized-by "the test harness" --ttl 600 --player mpris >/dev/null 2>&1
SID2="$(cat "$DESKCRAB_WATCHALONG_DIR/current")"
RLOG="$T/reader.log"
WA reader --loop --reviewer fixture --interval 1 --min 6 --max 10 --log "$RLOG" </dev/null >/dev/null 2>&1 &
RPID=$!
sandbox_at_exit "kill $RPID 2>/dev/null"
check "the reader announces its observer" wait_log 1 "observer started for mpris" "$RLOG"
check "a receipt lands while the observer polls" wait_for 40 bash -c '[ "$(ls "$1/sessions/$2/receipts/" 2>/dev/null | wc -l)" -ge 1 ]' _ "$DESKCRAB_WATCHALONG_DIR" "$SID2"
echo pause >> "$CTL"
check "the observer thread files the pause from inside the reader" wait_log 1 "observer: epoch [0-9]* — player watchalong fixture (plays nothing): paused at" "$RLOG"
status_json
check_eq "the session is paused by player telemetry" "$(sj "(d['playing'], d['anchor']['basis'])")" "(False, 'player-telemetry')"
check "the reader then cuts nothing new" wait_log 1 "nothing new" "$RLOG" 10
check_eq "and the earlier receipt is history" "$(sj "(d['receipts_this_epoch'], d['receipts_earlier'] >= 1)")" "(0, True)"
B="$(WA prompt-block)"
check "the layer says PAUSED by the player and that earlier looks are history" bash -c 'printf "%s" "$1" | grep -q "PAUSED at .* his player watchalong fixture (plays nothing) reports Paused" && printf "%s" "$1" | grep -q "they are history now"' _ "$B"
WA stop --reason "done" >/dev/null
check "the reader exited" wait_for 15 bash -c '! kill -0 "$1" 2>/dev/null' _ "$RPID"
check "and its observer with it" grep -q "observer: session STOPPED: exiting\|observer: no session: exiting\|observer: stopping with the reader" "$RLOG"

echo
echo "nothing here speaks, plays or notifies (rule 26):"
check "no synthesiser input" test ! -s "$SANDBOX_SPOKEN_LOG"
check "no player call" test ! -s "$SANDBOX_PLAYED_LOG"
check "no notification" test ! -s "$SANDBOX_NOTIFY_LOG"
echo quit >> "$CTL"
