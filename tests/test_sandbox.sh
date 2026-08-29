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
# directory, the account state file, the day journal directory, the state
# home, the data home, and the recorder pid file — plus the homes and the
# runtime directory that everything else is derived from.
for knob in DESKCRAB_CONF DESKCRAB_STATE_PREFIX WAKES_DIR JOBS_DIR \
            DESKCRAB_MEMORY_DIR ACCOUNT_STATE_FILE DAY_JOURNAL_DIR \
            XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME \
            XDG_RUNTIME_DIR DESKCRAB_PIDFILE HOME TMPDIR ARCHIVE_DIR \
            NOTICE_STATE_DIR CLAUDE_BIN \
            DESKCRAB_GAME_STATE_DIR OPENRSC_STATE_DIR DESKCRAB_OPENRSC_STATE_DIR
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
out="$(sandbox_bash 'printf "%s|%s|%s" "$WAKES_DIR" "$JOBS_DIR" "$ACCOUNT_STATE_FILE"')"
check_eq "common.sh derives its paths from the pinned knobs" \
    "$out" "$WAKES_DIR|$JOBS_DIR|$ACCOUNT_STATE_FILE"
out="$(sandbox_bash 'printf "%s" "$CONVOFILE"')"
check_eq "the conversation is the sandbox's own" \
    "$out" "$DESKCRAB_STATE_PREFIX-convo.txt"

echo
echo "the leak photograph excludes exactly the named live organs, and nothing else:"
# Each dropped path is one specs/test-harness.md rule 9 names with its writer:
# the phone server's seen-file and webpush store, the prefix-choice log, the
# resident game session's state directory, the token ledger, the live chess
# games/selfplay/reflex store, the wake queue's own ledger line, the watcher's
# cycle files, the jobs directory's own mtime line, and a running builder's
# stream triplet. Everything else stays in, and this is where "everything
# else" is held: the filter is fed a photograph by hand, so no live path has
# to move to prove what it does.
RUNNING_ID="20990101-000000-1"; FINISHED_ID="20990101-000000-2"
photo="$(
    export SANDBOX_RUNNING_JOBS="$SANDBOX_LIVE_DATA/jobs/$RUNNING_ID.log
$SANDBOX_LIVE_DATA/jobs/$RUNNING_ID.json
$SANDBOX_LIVE_DATA/jobs/$RUNNING_ID.lock"
    printf '%s\t0\t1\n' \
    "$SANDBOX_LIVE_PREFIX-phone-seen" \
    "$SANDBOX_LIVE_PREFIX-phone-seen.bak" \
    "$SANDBOX_LIVE_PREFIX-convo.txt" \
    "$SANDBOX_LIVE_PREFIX-game" \
    "$SANDBOX_LIVE_PREFIX-game/state.json" \
    "$SANDBOX_LIVE_PREFIX-gamely" \
    "$SANDBOX_LIVE_DATA/webpush" \
    "$SANDBOX_LIVE_DATA/webpush/subscriptions.json" \
    "$SANDBOX_LIVE_DATA/webpushed-elsewhere" \
    "$SANDBOX_LIVE_DATA/metrics" \
    "$SANDBOX_LIVE_DATA/metrics/tokens-2026-01-01.jsonl" \
    "$SANDBOX_LIVE_DATA/metricsish" \
    "$SANDBOX_LIVE_DATA/chess/games" \
    "$SANDBOX_LIVE_DATA/chess/games/some-game.json" \
    "$SANDBOX_LIVE_DATA/chess/selfplay/night.log" \
    "$SANDBOX_LIVE_DATA/chess/reflex.db" \
    "$SANDBOX_LIVE_DATA/chess/reflex.db-wal" \
    "$SANDBOX_LIVE_DATA/chess/reflex.db.bak" \
    "$SANDBOX_LIVE_DATA/chess/record.py" \
    "$SANDBOX_LIVE_DATA/wakes/deskcrab-wake-1.wake" \
    "$SANDBOX_LIVE_DATA/wakes/ledger.log" \
    "$SANDBOX_LIVE_DATA/jobs" \
    "$SANDBOX_LIVE_DATA/jobs/$RUNNING_ID.log" \
    "$SANDBOX_LIVE_DATA/jobs/$RUNNING_ID.json" \
    "$SANDBOX_LIVE_DATA/jobs/$FINISHED_ID.log" \
    "$SANDBOX_LIVE_STATE/notice-self.heartbeat" \
    "$SANDBOX_LIVE_STATE/notice-self.pending" \
    "$SANDBOX_LIVE_STATE/notice-self.log" \
    "$SANDBOX_LIVE_STATE/notice-self.snap" \
    "$SANDBOX_LIVE_STATE/notice-self.suppress" \
    "$SANDBOX_LIVE_PREFIX-prefix.log" \
    | _sandbox_drop_external "$SANDBOX_LIVE_PREFIX" "$SANDBOX_LIVE_DATA" \
    | cut -f1)"
for gone in "$SANDBOX_LIVE_PREFIX-phone-seen" "$SANDBOX_LIVE_DATA/webpush" \
            "$SANDBOX_LIVE_DATA/webpush/subscriptions.json"; do
    check "dropped, because a live phone server writes it: ${gone##*/}" \
        bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" "$gone"
done
for gone in "$SANDBOX_LIVE_STATE/notice-self.heartbeat" \
            "$SANDBOX_LIVE_STATE/notice-self.pending" \
            "$SANDBOX_LIVE_STATE/notice-self.log" \
            "$SANDBOX_LIVE_STATE/notice-self.snap"; do
    check "dropped, because the live watcher cycles it on its own schedule: ${gone##*/}" \
        bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" "$gone"
done
check "dropped, because every live library load appends its 13b line: prefix.log" \
    bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" \
    "$SANDBOX_LIVE_PREFIX-prefix.log"
for gone in "$SANDBOX_LIVE_PREFIX-game" "$SANDBOX_LIVE_PREFIX-game/state.json"; do
    check "dropped, because the resident game engine rewrites it every two seconds: ${gone##*/}" \
        bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" "$gone"
done
for gone in "$SANDBOX_LIVE_DATA/metrics" \
            "$SANDBOX_LIVE_DATA/metrics/tokens-2026-01-01.jsonl"; do
    check "dropped, because the token ledger records every live attempt: ${gone##*/}" \
        bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" "$gone"
done
for gone in "$SANDBOX_LIVE_DATA/chess/games" \
            "$SANDBOX_LIVE_DATA/chess/games/some-game.json" \
            "$SANDBOX_LIVE_DATA/chess/selfplay/night.log" \
            "$SANDBOX_LIVE_DATA/chess/reflex.db" \
            "$SANDBOX_LIVE_DATA/chess/reflex.db-wal"; do
    check "dropped, because the live chess hands write it move by move: ${gone##*/}" \
        bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" "$gone"
done
check "dropped, because the live queue ledgers its own bookings: ledger.log" \
    bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" \
    "$SANDBOX_LIVE_DATA/wakes/ledger.log"
check "dropped, because live sidecar updates rename inside it: the jobs dir line" \
    bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" \
    "$SANDBOX_LIVE_DATA/jobs"
for gone in "$SANDBOX_LIVE_DATA/jobs/$RUNNING_ID.log" \
            "$SANDBOX_LIVE_DATA/jobs/$RUNNING_ID.json"; do
    check "dropped, because a running builder streams it: ${gone##*/}" \
        bash -c '! printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" "$gone"
done
for kept in "$SANDBOX_LIVE_PREFIX-phone-seen.bak" "$SANDBOX_LIVE_PREFIX-convo.txt" \
            "$SANDBOX_LIVE_PREFIX-gamely" \
            "$SANDBOX_LIVE_DATA/webpushed-elsewhere" \
            "$SANDBOX_LIVE_DATA/metricsish" \
            "$SANDBOX_LIVE_DATA/chess/reflex.db.bak" \
            "$SANDBOX_LIVE_DATA/chess/record.py" \
            "$SANDBOX_LIVE_DATA/wakes/deskcrab-wake-1.wake" \
            "$SANDBOX_LIVE_DATA/jobs/$FINISHED_ID.log" \
            "$SANDBOX_LIVE_STATE/notice-self.suppress"; do
    check "kept, because a leak is a leak: ${kept##*/}" \
        bash -c 'printf "%s\n" "$1" | grep -qxF "$2"' _ "$photo" "$kept"
done

echo
echo "a running builder is one whose sidecar says so and whose pid is alive:"
# The enumeration feeds the filter above. Against a crafted jobs directory, in
# lib/job-status's own shape: only "running" with a live pid earns the
# triplet; a dead pid on a stale sidecar and a finished state both stay
# photographed. This test's own pid plays the live builder.
FAKEJOBS="$SANDBOX/fakejobs"
mkdir -p "$FAKEJOBS"
printf '{\n "state": "running",\n "pid": %s,\n "pidstart": 1\n}\n' "$$" \
    > "$FAKEJOBS/j-running.json"
printf '{\n "state": "running",\n "pid": 999999999\n}\n' \
    > "$FAKEJOBS/j-stale.json"
printf '{\n "state": "collected",\n "pid": %s\n}\n' "$$" \
    > "$FAKEJOBS/j-done.json"
triplets="$(_sandbox_running_jobs "$FAKEJOBS")"
for want in "$FAKEJOBS/j-running.log" "$FAKEJOBS/j-running.json" \
            "$FAKEJOBS/j-running.lock"; do
    check "the live builder's triplet carries ${want##*/}" \
        bash -c 'printf "%s\n" "$1" | grep -qxF "$2"' _ "$triplets" "$want"
done
check "a running sidecar with a dead pid earns nothing" \
    bash -c '! printf "%s\n" "$1" | grep -qF "j-stale"' _ "$triplets"
check "a finished sidecar with a live pid earns nothing" \
    bash -c '! printf "%s\n" "$1" | grep -qF "j-done"' _ "$triplets"

echo
echo "a live path that did not exist before is a leak too:"
# The photograph used to drop every path under the live prefix it had not seen
# in the BEFORE shot, on the reasoning that a new /tmp file might belong to
# somebody else. The result was that an edit to a live file counted and an
# addition beside it did not — and the defect class the sweep below it exists
# for (a state file re-hardcoded to /tmp/deskcrab-something) CREATES a file.
# The one shape the gate was written to catch was the one shape it could not
# see. Proved against a fake live tree, so the real one is never written.
FAKE="$SANDBOX/fakelive"
mkdir -p "$FAKE/root/leak" "$FAKE/tmp" "$FAKE/data" "$FAKE/state" "$FAKE/conf"
: > "$FAKE/tmp/deskcrab-something-hardcoded"
(
    # SANDBOX moves with the rest: the photograph excludes this run's own root
    # by prefix, and the fake live tree has to sit outside whatever that is.
    export SANDBOX="$FAKE/root"
    export SANDBOX_LIVE_PREFIX="$FAKE/tmp/deskcrab"
    export SANDBOX_LIVE_DATA="$FAKE/data"
    export SANDBOX_LIVE_STATE="$FAKE/state"
    export SANDBOX_LIVE_CONF="$FAKE/conf"
    _sandbox_photo_after
)
check "a file that appeared beside the live prefix is in the photograph" \
    grep -q 'deskcrab-something-hardcoded' "$FAKE/root/leak/after"

echo
echo "a stub can be replaced without a second stub directory:"
sandbox_stub claude <<'STUB'
#!/bin/bash
printf 'replaced\n'
STUB
check_eq "sandbox_stub overwrites in place" "$("$CLAUDE_BIN")" "replaced"
check_eq "and PATH still has exactly one stub directory" \
    "$(command -v claude)" "$SANDBOX_BIN/claude"

echo
echo "the second look tells the two hands apart by time:"
# The mechanics against crafted photographs, no live path involved. Three
# paths moved during a run: a directory a live writer keeps rewriting, a file
# inside that directory whose own next write is minutes away, and a lone file
# that moved once and sat still. By the settle photograph only the directory
# is still moving. The excuse must cover the directory (it moved again), the
# file inside it (its directory is demonstrably a live hand's traffic —
# motion evidence flows one level, parent to child and child to parent,
# because a directory's mtime IS a function of its direct children), and
# NEVER the lone sibling: siblings are separate writers, and a settled
# sibling is exactly the planted-leak shape.
LOOK="$SANDBOX/look"
mkdir -p "$LOOK"
printf '/fake/games\t1\t100.0\n/fake/games/one.json\t1\t100.0\n/fake/planted\t1\t100.0\n' \
    > "$LOOK/before"
printf '/fake/games\t1\t105.0\n/fake/games/one.json\t2\t104.0\n/fake/planted\t2\t104.0\n' \
    > "$LOOK/after"
printf '/fake/games\t1\t109.0\n/fake/games/one.json\t2\t104.0\n/fake/planted\t2\t104.0\n' \
    > "$LOOK/settle"
if sandbox_second_look "$LOOK/before" "$LOOK/after" "$LOOK/settle" "$LOOK/one"; then
    fail "a settled path with no moving relative must stay accused"
else
    ok "the settled lone path keeps the verdict red"
fi
check "the accusation names the planted path" \
    grep -q '/fake/planted' "$LOOK/one.diff"
check "the accusation does not name the still-moving directory" \
    bash -c '! grep -q "/fake/games	" "$1.diff"' _ "$LOOK/one"
check "the accusation does not name the file inside that directory" \
    bash -c '! grep -q "/fake/games/one.json" "$1.diff"' _ "$LOOK/one"
check "the excused list names the moving directory" \
    grep -qx '/fake/games' "$LOOK/one.excused"
check "the excused list names the file under the moving directory" \
    grep -qx '/fake/games/one.json' "$LOOK/one.excused"
check "the excused list does not forgive the planted path" \
    bash -c '! grep -qx "/fake/planted" "$1.excused"' _ "$LOOK/one"

# ...and with nothing settled in the dispute, the verdict is clean.
printf '/fake/games\t1\t100.0\n' > "$LOOK/b2"
printf '/fake/games\t1\t105.0\n' > "$LOOK/a2"
printf '/fake/games\t1\t109.0\n' > "$LOOK/s2"
check "a dispute made only of churn is no leak at all" \
    sandbox_second_look "$LOOK/b2" "$LOOK/a2" "$LOOK/s2" "$LOOK/two"

# A path that was already HOT when the before photograph was taken is a
# foreign writer's, causally: the test had not run yet. The bench's burst
# writers pause longer than any settle interval mid-model-call, so the
# settle look alone kept accusing them; their giveaway is that they were
# written seconds before the photograph. A cold path that moved is still a
# leak.
printf '/fake/hotlog\t1\t99.0\n/fake/coldpast\t1\t10.0\n' > "$LOOK/h.before"
printf '100.5' > "$LOOK/h.before.at"
printf '/fake/hotlog\t2\t103.0\n/fake/coldpast\t2\t103.5\n' > "$LOOK/h.after"
cp "$LOOK/h.after" "$LOOK/h.settle"
if sandbox_second_look "$LOOK/h.before" "$LOOK/h.after" "$LOOK/h.settle" "$LOOK/hot"; then
    fail "a cold path that moved and settled must stay accused"
else
    ok "the cold mover keeps the verdict red"
fi
check "the hot-before path is excused by name" \
    grep -qx '/fake/hotlog' "$LOOK/hot.excused"
check "the accusation names the cold path, not the hot one" \
    bash -c 'grep -q "/fake/coldpast" "$1.diff" && ! grep -q "/fake/hotlog" "$1.diff"' \
    _ "$LOOK/hot"

# The units photograph speaks the same language: its key is the unit name,
# wherever list-units put it on the line (a failed unit wears a ● marker).
printf '  deskcrab-fake.service loaded active running A fake service\n' > "$LOOK/u.before"
printf 'x deskcrab-fake.service loaded failed failed A fake service\n' > "$LOOK/u.after"
cp "$LOOK/u.after" "$LOOK/u.settle"
if sandbox_second_look "$LOOK/u.before" "$LOOK/u.after" "$LOOK/u.settle" "$LOOK/u1"; then
    fail "a unit that changed state and settled must stay accused"
else
    ok "a settled unit change keeps the verdict red"
fi
printf '  deskcrab-fake.service loaded active running A fake service\n' > "$LOOK/u.settle2"
check "a unit still changing at the settle photograph is excused by name" \
    sandbox_second_look "$LOOK/u.before" "$LOOK/u.after" "$LOOK/u.settle2" "$LOOK/u2"
check "and the excuse carries the unit name, not the whole line" \
    grep -qx 'deskcrab-fake.service' "$LOOK/u2.excused"

# A transient-stamped unit — the -<moment>-<pid> shape systemd-run mints for
# wakes, jobs and the watchers — is live lifecycle by construction: inside
# the sandbox the user manager is unreachable (no bus, pinned runtime dir,
# stubbed tools), so no test can put one in the real manager, and the
# watcher's two-minute defer cycle was handing settled flaps to whichever
# test spanned it. Excused whatever its window; a persistent unit (above)
# keeps the full accusation.
: > "$LOOK/t.before"
printf '  deskcrab-wake-1787000000-4242.timer loaded active waiting a wake\n' \
    > "$LOOK/t.after"
cp "$LOOK/t.after" "$LOOK/t.settle"
check "a transient-stamped unit is live lifecycle, never a leak" \
    sandbox_second_look "$LOOK/t.before" "$LOOK/t.after" "$LOOK/t.settle" "$LOOK/t1"
check "and it is excused by its unit name" \
    grep -qx 'deskcrab-wake-1787000000-4242.timer' "$LOOK/t1.excused"

echo
echo "and holds live under a churn writer — red stays red, a leak stays a leak:"
# The live shape this answers: on 2026-08-28/29 the game harness rewrote
# /tmp/deskcrab-game every two seconds until dawn and the selfplay bench kept
# the live games directory moving, so EVERY suite run wore the LEAK verdict,
# exit 2, whatever its assertions found — a genuine red (the 100644 test
# mode) was dressed as the weather and dismissed with it. A writer of exactly
# that cadence runs across both children below and keeps writing after each
# exits. The churn file is this test's own live write, created and removed
# between the outer photographs (the live-clips bargain), and the outer run
# leans on the same second look it is proving — which is the point.
CHURN="/tmp/deskcrab-churn-crabtest$$"
( while [ -d "$SANDBOX" ]; do touch "$CHURN"; sleep 0.4; done; rm -f "$CHURN" ) &
CHURN_PID=$!
sandbox_at_exit "kill $CHURN_PID 2>/dev/null; rm -f '$CHURN'"

CHILD_RED="$SANDBOX/tmp/child-red-beside-writer.sh"
cat > "$CHILD_RED" <<CHILD
#!/bin/bash
. "$SANDBOX_REPO/tests/lib/sandbox.sh"
sleep 1
ok "one green so the counts are real"
fail "a genuine red planted on purpose"
CHILD
chmod +x "$CHILD_RED"
OUT="$(env -u DESKCRAB_SANDBOX_ROOT -u DESKCRAB_SANDBOX_REPO \
        -u DESKCRAB_SANDBOX_LIB -u DESKCRAB_SANDBOX_NAME \
        DESKCRAB_SANDBOX_SETTLE=2 DESKCRAB_SANDBOX_VIGIL=4 \
        bash "$CHILD_RED" 2>&1)" && RC=0 || RC=$?
check_eq "the red child exits 1 — an assertion failure, not churn's exit 2" \
    "$RC" "1"
check "its FAIL line is unmistakable in the output" \
    contains "$OUT" "FAIL: a genuine red planted on purpose"
check "its summary counts the red" contains "$OUT" "1 passed, 1 failed"
check "the churn is named as churn, in the note's own words" \
    contains "$OUT" "were STILL moving"
check "...and the churning path is on the excused list" contains "$OUT" "$CHURN"
check "no LEAK verdict was worn" \
    bash -c 'case "$1" in *LEAK*) exit 1;; *) exit 0;; esac' _ "$OUT"

PLANT="/tmp/deskcrab-planted-crabtest$$"
CHILD_LEAK="$SANDBOX/tmp/child-leak-beside-writer.sh"
cat > "$CHILD_LEAK" <<CHILD
#!/bin/bash
. "$SANDBOX_REPO/tests/lib/sandbox.sh"
printf 'one write, then silence' > "$PLANT"
sleep 1
ok "assertions all green; the photograph must still convict"
CHILD
chmod +x "$CHILD_LEAK"
OUT2="$(env -u DESKCRAB_SANDBOX_ROOT -u DESKCRAB_SANDBOX_REPO \
        -u DESKCRAB_SANDBOX_LIB -u DESKCRAB_SANDBOX_NAME \
        DESKCRAB_SANDBOX_SETTLE=2 DESKCRAB_SANDBOX_VIGIL=4 \
        bash "$CHILD_LEAK" 2>&1)" && RC2=0 || RC2=$?
rm -f "$PLANT"
check_eq "the leaking child still exits 2 through the whole vigil" "$RC2" "2"
check "the verdict names the planted path" contains "$OUT2" "$PLANT"
check "the churner is excused beside it, not mistaken for the leak" \
    contains "$OUT2" "were STILL moving"

echo
echo "a burst writer that misses the first settle window is excused by a later round:"
# The intermittent shape the single settle look could not close: a live hand
# writes once mid-test, then sits quiet through the whole first settle window
# — a game engine or a bench mover inside a model call — and its next stroke
# lands seconds later. The vigil keeps photographing while anything is still
# accused, so that later stroke is evidence too. The child signals its body's
# start and end through the outer sandbox; the outer writer strokes once
# mid-body (the dispute) and once five seconds after the body ends — past the
# first settle window at DESKCRAB_SANDBOX_SETTLE=2, inside the vigil at
# DESKCRAB_SANDBOX_VIGIL=14.
BURST="/tmp/deskcrab-burst-crabtest$$"
START="$SANDBOX/tmp/burst-child-started"
DONE="$SANDBOX/tmp/burst-child-done"
CHILD_BURST="$SANDBOX/tmp/child-beside-burst-writer.sh"
cat > "$CHILD_BURST" <<CHILD
#!/bin/bash
. "$SANDBOX_REPO/tests/lib/sandbox.sh"
: > "$START"
sleep 2
: > "$DONE"
ok "the burst writer's strokes are not this child's doing"
CHILD
chmod +x "$CHILD_BURST"
(
    while [ ! -e "$START" ] && [ -d "$SANDBOX" ]; do sleep 0.1; done
    touch "$BURST"
    while [ ! -e "$DONE" ] && [ -d "$SANDBOX" ]; do sleep 0.1; done
    sleep 5
    touch "$BURST"
) &
BURST_PID=$!
sandbox_at_exit "kill $BURST_PID 2>/dev/null; rm -f '$BURST'"
OUT3="$(env -u DESKCRAB_SANDBOX_ROOT -u DESKCRAB_SANDBOX_REPO \
        -u DESKCRAB_SANDBOX_LIB -u DESKCRAB_SANDBOX_NAME \
        DESKCRAB_SANDBOX_SETTLE=2 DESKCRAB_SANDBOX_VIGIL=14 \
        bash "$CHILD_BURST" 2>&1)" && RC3=0 || RC3=$?
rm -f "$BURST"
check_eq "the burst-writer child exits 0 — the vigil outlasted the quiet stretch" \
    "$RC3" "0"
check "and the burst path is excused by name" contains "$OUT3" "$BURST"
