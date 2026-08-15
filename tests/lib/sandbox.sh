#!/bin/bash
# THE sandbox. Every test sources this file, first, before anything else:
#
#     . "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
#
# and gets a scratch instance that cannot reach the live one. specs/test-harness.md
# is the contract; this is its implementation.
#
# What sourcing it does, in order:
#
#   1. builds a temporary root under $TMPDIR and photographs the live state
#      (the data dir, the config dir, the state dir, the live /tmp prefix, and
#      the user manager's deskcrab units) while the real environment is still
#      in hand;
#   2. re-executes the test under `env -i` — the clean-environment model taken
#      from the old tests/test_notice_selfchange.sh, now applied to every test
#      rather than to one — with every knob that can reach live state pinned
#      into that root and a single stub directory at the head of PATH;
#   3. defines the one assertion idiom;
#   4. arms an exit trap that re-photographs the live state and FAILS THE TEST
#      LOUDLY if a single byte of it moved, whatever the assertions said.
#
# The four gates of specs/test-harness.md, and where each one lives here:
#
#   touch      every path a test writes is under $SANDBOX; the leak check at
#              exit is the proof rather than the promise.
#   spend      CLAUDE_BIN and `claude` both resolve to a stub. A configuration
#              that overwrites CLAUDE_BIN loses to the exported one, which is
#              the scar `run_claude` left in lib/common.sh on purpose.
#   interrupt  the notifier, the synthesiser, the player, the renderer and the
#              window manager are stubs, from ONE list, in ONE directory.
#   schedule   `systemd-run` is a stub that RECORDS a timer and never arms one,
#              and DBUS_SESSION_BUS_ADDRESS / XDG_RUNTIME_DIR are pinned away
#              from the session bus, so even an unstubbed caller cannot reach
#              the user manager. No test can book a wake into the live manager.
#              lib/wake-queue.sh holds the same gate from the other side — a
#              scratch WAKES_DIR writes its record and creates no unit — and
#              DESKCRAB_ALLOW_SCRATCH_BOOKING=1 is its documented opt-in for a
#              harness that HAS stubbed systemd-run. It is set here, so the
#              booking path runs in full and a test can assert on the argv the
#              stub recorded rather than on a call that never happened.
#
# One assertion idiom: ok / fail / check / check_eq / contains, counted, one
# summary line per file. `die` is for the files that were written fail-fast —
# it records the failure through the same counter and then stops, so the
# reporting is uniform even where the control flow has to abort.

# --------------------------------------------------------------------------
# The live paths that move under somebody else's hand.
#
# The leak check accuses whichever test was running when a live path moved, and
# that is right for every path but these: live processes write them on their
# own schedule, the whole time the suite runs. Nothing a test does can stop
# that, and nothing a test does causes it.
#
#   <live prefix>-phone-seen    serve.py touches it on EVERY authenticated
#                               /watch poll from a wake-capable client
#                               (lib/serve.py, `Path(PHONE_SEEN).touch()`), so
#                               its mtime moves every few seconds all day.
#   <live data>/webpush/        webpush.py rewrites the lock file whenever it
#                               takes the lock and replaces subscriptions.json
#                               atomically, which moves the directory's own
#                               mtime with it.
#   $SANDBOX_FOREIGN_LOGS       the debug logs of the sessions that were
#                               ALREADY AWAKE when this sandbox was built.
#                               Every session streams to its own
#                               <live prefix>-debug-*.log (lib/common.sh sets
#                               DEBUGLOG off its pid, the job runner off its
#                               job id) for as long as it runs, so a test run
#                               beside a live session was failed for that
#                               session's writing: observed 2026-08-11 01:45,
#                               deskcrab-debug-500570.log grew 52187 -> 52554
#                               under test_chess_wake_prompt, and 500570 was a
#                               live wake, not the test. Membership is
#                               computed ONCE, in phase 1 before the first
#                               photograph, and carried through the `env -i`
#                               boundary, so both photographs drop exactly the
#                               same paths. It is exact paths, never a name
#                               pattern: a debug log that APPEARS during the
#                               run still counts — a live path minted by the
#                               code under test is the hardcoded-path defect
#                               this check exists to catch.
#
# Excluded from BOTH photographs — the before and the after — because a path
# dropped from only one side reads as a deletion. Defined above the phase-1
# block on purpose: the file is re-entered under `env -i`, so a function
# defined here is the same function on both sides of that boundary.
#
# NOTHING ELSE goes in here. Every other live path that moves during a test is
# either the code under test writing where it should not, or another hand
# writing at the same moment, and both are things the suite must keep shouting
# about.
_sandbox_drop_external() {  # <live prefix> <live data dir>: a path filter
    awk -F'\t' -v seen="$1-phone-seen" -v push="$2/webpush" '
        BEGIN {
            n = split(ENVIRON["SANDBOX_FOREIGN_LOGS"], _f, "\n")
            for (i = 1; i <= n; i++) if (_f[i] != "") foreign[_f[i]] = 1
        }
        $1 == seen { next }
        $1 == push || index($1, push "/") == 1 { next }
        $1 in foreign { next }
        { print }'
}

# The live timers, photographed so that only what a TEST could change shows up
# as a difference. `list-timers` renders two columns that move on their own —
# LEFT counts down and PASSED counts up — so a pending live timer made every
# run of every test longer than a second report a leak it had not caused. The
# zone matters for the same reason: the before photograph is taken out here in
# the real environment and the after one inside the sandbox, where TZ is
# whatever the caller had, so an unset TZ rendered the two halves in different
# zones and diffed every line. Both are pinned, and the durations are struck
# out; an absolute time, a unit appearing, and a unit going away all still read
# as the differences they are.
_sandbox_timers_photo() {  # <out file>
    env TZ=UTC LC_ALL=C /usr/bin/systemctl --user list-timers 'deskcrab-*' \
        --all --no-legend 2>/dev/null \
        | sed -E 's/\b[0-9]+(y|month|w|d|h|min|ms|us|s)\b//g; s/ +/ /g' \
        | LC_ALL=C sort > "$1"
}

# --------------------------------------------------------------------------
# Phase 1: the real environment. Build the root, photograph what is live, and
# hand the test to a clean environment.
# --------------------------------------------------------------------------
if [ -z "${DESKCRAB_SANDBOX_ROOT:-}" ]; then
    _sb_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _sb_repo="$(cd "$_sb_lib/../.." && pwd)"
    _sb_self="$(readlink -f "$0")"
    _sb_name="$(basename "$_sb_self" .sh)"
    _sb_root="$(mktemp -d "${TMPDIR:-/tmp}/crabtest-$_sb_name-XXXXXX")"

    mkdir -p \
        "$_sb_root/home" "$_sb_root/tmp" "$_sb_root/bin" "$_sb_root/conf" \
        "$_sb_root/state" "$_sb_root/run" "$_sb_root/cache" "$_sb_root/config" \
        "$_sb_root/data/deskcrab/jobs" "$_sb_root/data/deskcrab/wakes" \
        "$_sb_root/data/deskcrab/journal" "$_sb_root/data/deskcrab/memory" \
        "$_sb_root/data/deskcrab/archive" "$_sb_root/data/deskcrab/tls" \
        "$_sb_root/xdgstate/deskcrab" "$_sb_root/leak" "$_sb_root/witness"

    # The live paths, named once. The leak check reads these and nothing else
    # writes them; they are the only live paths this file ever touches, and it
    # only ever reads them.
    _sb_live_data="${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab"
    _sb_live_state="${XDG_STATE_HOME:-$HOME/.local/state}/deskcrab"
    _sb_live_conf="$(dirname "${DESKCRAB_CONF:-$HOME/.config/deskcrab/deskcrab.conf}")"
    _sb_live_prefix="/tmp/deskcrab"

    # One photograph function, used before and after. Metadata only: name,
    # size, mtime — a rewrite that keeps the size still moves the mtime, and
    # the account state file is exactly that shape.
    _sb_photo() { # <out>
        {
            find "$_sb_live_data" "$_sb_live_state" "$_sb_live_conf" \
                -printf '%p\t%s\t%T@\n' 2>/dev/null
            find "$(dirname "$_sb_live_prefix")" -maxdepth 1 \
                -name "$(basename "$_sb_live_prefix")*" \
                ! -path "$_sb_root*" \
                -printf '%p\t%s\t%T@\n' 2>/dev/null
        } | _sandbox_drop_external "$_sb_live_prefix" "$_sb_live_data" \
          | LC_ALL=C sort > "$1"
        /usr/bin/systemctl --user list-units 'deskcrab-*' --all --no-legend \
            2>/dev/null | LC_ALL=C sort > "$1.units"
        _sandbox_timers_photo "$1.timers"
    }
    # The already-awake sessions' debug logs, enumerated ONCE, here, before the
    # first photograph, so the before and the after drop exactly the same
    # paths. Exported now (awk reads it through ENVIRON) and passed through the
    # `env -i` boundary below. The comment above _sandbox_drop_external carries
    # the why.
    SANDBOX_FOREIGN_LOGS=""
    for _sb_foreign in "$_sb_live_prefix"-debug-*.log; do
        [ -e "$_sb_foreign" ] || continue
        SANDBOX_FOREIGN_LOGS="$SANDBOX_FOREIGN_LOGS$_sb_foreign"$'\n'
    done
    export SANDBOX_FOREIGN_LOGS

    _sb_photo "$_sb_root/leak/before"

    # A configuration has to exist — lib/common.sh refuses to load without one
    # — so the sandbox writes the smallest possible honest configuration: the
    # project directory and the two model files, nothing else. Every other knob
    # keeps its shipped default, because a scratch configuration that turns
    # features off is a scratch configuration that tests something else. A test
    # that needs its own settings overwrites this file.
    cat > "$_sb_root/conf/deskcrab.conf" <<CONF
PROJECT_DIR="$_sb_root/home"
PIPER_VOICE="$_sb_root/voice.onnx"
WHISPER_MODEL="$_sb_root/whisper.bin"
CONF

    # The stub list, installed once, at the head of PATH. One file per tool in
    # tests/lib/stubs; a test that needs different behaviour from one of them
    # overwrites it in place with sandbox_stub, so there is still only ever one
    # stub directory.
    cp "$_sb_lib/stubs/"* "$_sb_root/bin/"
    chmod +x "$_sb_root/bin/"*

    # sqlite-vec lives in a venv keyed off $HOME, and $HOME is about to move.
    # Naming the interpreter by absolute path keeps lib/memory.py from
    # re-executing itself into an interpreter that does not exist — the same
    # silent re-exec that makes a bare `pytest` in this repo exit 1 with no
    # output at all. Read-only use of a live path: an interpreter, not state.
    _sb_venv="${MEMORY_PYTHON:-$HOME/.local/share/deskcrab/venv/bin/python}"
    [ -x "$_sb_venv" ] || _sb_venv=""

    exec env -i \
        DESKCRAB_SANDBOX_ROOT="$_sb_root" \
        DESKCRAB_SANDBOX_REPO="$_sb_repo" \
        DESKCRAB_SANDBOX_LIB="$_sb_lib" \
        DESKCRAB_SANDBOX_NAME="$_sb_name" \
        SANDBOX_LIVE_DATA="$_sb_live_data" \
        SANDBOX_LIVE_STATE="$_sb_live_state" \
        SANDBOX_LIVE_CONF="$_sb_live_conf" \
        SANDBOX_LIVE_PREFIX="$_sb_live_prefix" \
        SANDBOX_FOREIGN_LOGS="$SANDBOX_FOREIGN_LOGS" \
        SANDBOX_REAL_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
        SANDBOX_REAL_DBUS="${DBUS_SESSION_BUS_ADDRESS:-}" \
        HOME="$_sb_root/home" \
        PATH="$_sb_root/bin:$PATH" \
        TMPDIR="$_sb_root/tmp" \
        TERM="${TERM:-dumb}" LANG="${LANG:-C.UTF-8}" TZ="${TZ:-}" \
        XDG_DATA_HOME="$_sb_root/data" \
        XDG_STATE_HOME="$_sb_root/xdgstate" \
        XDG_CONFIG_HOME="$_sb_root/config" \
        XDG_CACHE_HOME="$_sb_root/cache" \
        XDG_RUNTIME_DIR="$_sb_root/run" \
        DESKCRAB_CONF="$_sb_root/conf/deskcrab.conf" \
        DESKCRAB_STATE_PREFIX="$_sb_root/state/deskcrab" \
        DESKCRAB_PREFIX_LOG="$_sb_root/witness/prefix-choice.log" \
        DESKCRAB_PIDFILE="$_sb_root/run/deskcrab.pid" \
        ACCOUNT_STATE_FILE="$_sb_root/data/deskcrab/account-state" \
        DESKCRAB_MEMORY_DIR="$_sb_root/data/deskcrab/memory" \
        WAKES_DIR="$_sb_root/data/deskcrab/wakes" \
        JOBS_DIR="$_sb_root/data/deskcrab/jobs" \
        DAY_JOURNAL_DIR="$_sb_root/data/deskcrab/journal" \
        DESKCRAB_METRICS_DIR="$_sb_root/data/deskcrab/metrics" \
        ARCHIVE_DIR="$_sb_root/data/deskcrab/archive" \
        NOTICE_STATE_DIR="$_sb_root/xdgstate/deskcrab" \
        CLAUDE_BIN="$_sb_root/bin/claude" \
        COCOON_BWRAP="$_sb_lib/cocoon-passthru" \
        DESKCRAB_ALLOW_SCRATCH_BOOKING=1 \
        MEMORY_PYTHON="$_sb_venv" \
        SANDBOX_SYSTEMD_LOG="$_sb_root/witness/systemd-run.log" \
        SANDBOX_SYSTEMCTL_LOG="$_sb_root/witness/systemctl.log" \
        SANDBOX_NOTIFY_LOG="$_sb_root/witness/notify.log" \
        SANDBOX_SPOKEN_LOG="$_sb_root/witness/spoken.log" \
        SANDBOX_PLAYED_LOG="$_sb_root/witness/played.log" \
        SANDBOX_DISPLAY_LOG="$_sb_root/witness/display.log" \
        SANDBOX_CLAUDE_LOG="$_sb_root/witness/claude.log" \
        bash "$_sb_self" "$@"
fi

# --------------------------------------------------------------------------
# Phase 2: inside the sandbox.
# --------------------------------------------------------------------------
SANDBOX="$DESKCRAB_SANDBOX_ROOT"
SANDBOX_REPO="$DESKCRAB_SANDBOX_REPO"
SANDBOX_BIN="$SANDBOX/bin"
SANDBOX_NAME="$DESKCRAB_SANDBOX_NAME"

PASS=0 FAIL=0
_SANDBOX_ABORTED=""
_SANDBOX_SKIPPED=""

# Counted on disk as well as in the shell: several tests do their work inside a
# subshell (a `set +eu` island around a sourced lib/common.sh, a pipeline), and
# a counter incremented in a subshell is a counter the summary never sees. The
# witness files are what the summary reads.
ok() {
    PASS=$(( PASS + 1 )); echo "  ok: $1"
    printf '%s\n' "$1" >> "$SANDBOX/witness/passes"
}
# The private spelling exists so die() cannot be caught in mutual recursion: a
# test that shadows fail() with its own fail(){ die ...; } otherwise turns any
# failing assertion into fail -> die -> fail -> ... — a silent segfault where
# the failure message should have been (found live in test_silent_wake.sh).
_sandbox_fail() {
    FAIL=$(( FAIL + 1 ))
    if [ $# -gt 1 ]; then echo "  FAIL: $1 — got [$2]"; else echo "  FAIL: $1"; fi
    printf '%s\n' "$1" >> "$SANDBOX/witness/failures"
}
fail() { _sandbox_fail "$@"; }

# check <desc> <cmd...> — the command's exit status is the assertion.
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else fail "$desc"; fi; }

# check_eq <desc> <got> <want>
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "got [$2] want [$3]"; fi; }

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# die <desc> [got] — for the files written fail-fast. Counted like any other
# failure so the summary reads the same, then the test stops where it stood.
die() { _sandbox_fail "$@"; _SANDBOX_ABORTED=1; exit 1; }

# sandbox_skip <reason> — this box cannot run the test. Says why, out loud, and
# exits 77, which the runner reports as a skip rather than a pass. A silent
# skip is a green run that proved nothing.
sandbox_skip() { echo "  skip: $1"; _SANDBOX_SKIPPED=1; exit 77; }

# sandbox_need_ollama — the embedder cases run against the real local daemon on
# purpose: a mocked embedder cannot prove semantic ranking.
sandbox_need_ollama() {
    local url="${MEMORY_EMBED_URL:-http://localhost:11434/api/embed}"
    curl -fsS -m 3 -o /dev/null "${url%/api/embed}/api/tags" 2>/dev/null ||
        sandbox_skip "the local ollama embedder is not answering (${url})"
}

# sandbox_at_exit <command> — run this before the sandbox is torn down. For
# the tests that start something of their own (a server, a streamer) and have
# to stop it. The exit trap belongs to the harness, so a test that installs its
# own would disarm the leak check.
_SANDBOX_AT_EXIT=()
sandbox_at_exit() { _SANDBOX_AT_EXIT+=("$1"); }

# sandbox_stub <name> — replace one stub, reading the new body on stdin.
# The stub directory stays the only one; nothing else goes on PATH.
sandbox_stub() {
    cat > "$SANDBOX_BIN/$1"
    chmod +x "$SANDBOX_BIN/$1"
}

# sandbox_bash <body> — source lib/common.sh in a scratch instance and run the
# body in it. This is the invoker that was copy-pasted across eight sites in
# five files; the copies drifted, which is how one of them lost its account
# default pin and rewrote the live one.
sandbox_bash() {
    bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$SANDBOX_REPO" "$*"
}

# Matching lines, as ONE number. `grep -c ... || echo 0` is not that: on zero
# matches grep prints its own 0 AND exits 1, so the fallback fires as well and
# the answer comes back as the two lines "0" and "0" — which no comparison,
# no -eq and no reader survives. Absence is asserted by counting, so a count
# has to be a number whether the file is missing, empty, or simply has no
# match. Two test files had already written this helper for themselves.
sandbox_count_in() {  # <pattern> <file>
    local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; printf '%s' "${n:-0}"
}

# What the schedule gate saw. A booking attempt is recorded, never armed.
sandbox_systemd_calls() { cat "$SANDBOX_SYSTEMD_LOG" 2>/dev/null; }
sandbox_systemd_count() { sandbox_count_in . "$SANDBOX_SYSTEMD_LOG"; }
# What a booking attempt returns. 0 (a timer was accepted) by default; a test
# that needs the caller's cannot-defer branch sets 1.
sandbox_systemd_rc() { printf '%s' "$1" > "$SANDBOX/witness/systemd-run.rc"; }

# --- the leak check --------------------------------------------------------
# Photographed with the real session bus, which the test itself cannot see: the
# stub systemctl is first on PATH and DBUS_SESSION_BUS_ADDRESS is not set
# inside the sandbox at all.
_sandbox_photo_after() {
    {
        find "$SANDBOX_LIVE_DATA" "$SANDBOX_LIVE_STATE" "$SANDBOX_LIVE_CONF" \
            -printf '%p\t%s\t%T@\n' 2>/dev/null
        find "$(dirname "$SANDBOX_LIVE_PREFIX")" -maxdepth 1 \
            -name "$(basename "$SANDBOX_LIVE_PREFIX")*" \
            ! -path "$SANDBOX*" \
            -printf '%p\t%s\t%T@\n' 2>/dev/null
    } | _sandbox_drop_external "$SANDBOX_LIVE_PREFIX" "$SANDBOX_LIVE_DATA" \
      | LC_ALL=C sort > "$SANDBOX/leak/after.raw"
    # A NEW path under the live prefix is a leak like any other. This used to
    # drop them — an edit to a live file counted, an addition beside it did
    # not — on the reasoning that a new /tmp file might belong to another test
    # or another process. It cannot belong to another test: the find above
    # matches the live prefix by name and every scratch root is `crabtest-*`
    # somewhere else, so the only two things that can put a `deskcrab*` file in
    # /tmp are the live instance and the code under test writing a hardcoded
    # path. Those are the same two candidates an EDIT already has, and the
    # message below names both.
    #
    # It matters because the defect class the phone-audio sweep was written for
    # — a state file re-hardcoded to /tmp/deskcrab-something — creates a file
    # rather than editing one, so the gate was blind to precisely the shape it
    # exists to catch. Under the live data, state and config directories
    # nothing was ever dropped; the prefix is now read the same way.
    cp "$SANDBOX/leak/after.raw" "$SANDBOX/leak/after"
    env XDG_RUNTIME_DIR="$SANDBOX_REAL_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$SANDBOX_REAL_DBUS" \
        /usr/bin/systemctl --user list-units 'deskcrab-*' --all --no-legend \
        2>/dev/null | LC_ALL=C sort > "$SANDBOX/leak/after.units"
    XDG_RUNTIME_DIR="$SANDBOX_REAL_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$SANDBOX_REAL_DBUS" \
        _sandbox_timers_photo "$SANDBOX/leak/after.timers"
}

# There used to be a sweep here that DELETED any /tmp/deskcrab-remote-*.opus
# the run had added, reasoning that shipping code hangs its reply audio off
# STATE_PREFIX now, so a new clip under the live prefix could only be a leaked
# hardcoded path. The reasoning missed the other author: the LIVE phone server
# mints exactly those clips on its own schedule, whenever somebody is talking
# to it, and on 2026-08-11 the sweep deleted three clips the live server had
# synthesised and not yet served — the spoken reply cut out mid-sentence on
# the phone, with a replay control pointing at a file this harness had
# destroyed. The two authors write the same path and the harness cannot tell
# them apart, so it may only accuse (test-harness.md rule 9): the photograph
# diff below names the file, the run fails, and a hand that read the verdict
# does the cleaning. A stray clip is collected by the live instance's own
# hourly sweep. Held by tests/test_sandbox_live_clips.sh.

_sandbox_leak_check() {  # -> 0 clean, 1 leaked
    _sandbox_photo_after
    local leaked=0 what
    for what in "" ".units" ".timers"; do
        if ! diff -q "$SANDBOX/leak/before$what" "$SANDBOX/leak/after$what" \
                >/dev/null 2>&1; then
            [ "$leaked" = 0 ] && {
                echo
                echo "  LEAK: live state moved while this test ran. What moved:"
            }
            leaked=1
            diff "$SANDBOX/leak/before$what" "$SANDBOX/leak/after$what" \
                2>/dev/null | sed 's/^/    /' | head -40
        fi
    done
    return "$leaked"
}

# --- the exit trap ---------------------------------------------------------
# Runs whatever happened: assertions counted, a fail-fast abort, or an error
# under `set -e`. The leak check has the last word — a test that damaged the
# live instance fails even with every assertion green.
_sandbox_finish() {
    local rc="$?"
    local leaked=0 _cmd
    for _cmd in ${_SANDBOX_AT_EXIT[@]+"${_SANDBOX_AT_EXIT[@]}"}; do
        eval "$_cmd" >/dev/null 2>&1 || true
    done
    # Through the helper, not `grep -c … || echo`: on zero matches grep prints
    # its own 0 AND exits non-zero, so the fallback fires too and the count
    # comes back as two lines. That is the exact defect sandbox_count_in was
    # written to warn about, and it was reproduced here, one screen below the
    # warning — with the summary line and every `-gt` test downstream of it.
    PASS="$(sandbox_count_in . "$SANDBOX/witness/passes")"
    FAIL="$(sandbox_count_in . "$SANDBOX/witness/failures")"
    [ "$FAIL" -gt 0 ] && [ "$rc" = 0 ] && rc=1
    _sandbox_leak_check || leaked=1
    echo
    if [ -n "$_SANDBOX_SKIPPED" ] && [ "$leaked" = 0 ] && [ "$FAIL" = 0 ]; then
        echo "$SANDBOX_NAME: skipped"
        rm -rf "$SANDBOX"
        exit 77
    fi
    if [ "$leaked" = 1 ]; then
        echo "  Every path this test writes is under its own root, so a live"
        echo "  path that moved is either a hardcoded path in the code under"
        echo "  test or another hand writing at the same moment — an unsandboxed"
        echo "  run in another shell, or the live instance itself. The paths"
        echo "  above say which."
        echo "$SANDBOX_NAME: LEAKED into live state — $PASS passed, $FAIL failed"
        rc=2
    elif [ "$FAIL" -gt 0 ]; then
        echo "$SANDBOX_NAME: $PASS passed, $FAIL failed"
        rc=1
    elif [ -n "$_SANDBOX_ABORTED" ]; then
        echo "$SANDBOX_NAME: aborted — $PASS passed, $FAIL failed"
        [ "$rc" = 0 ] && rc=1
    elif [ "$rc" != 0 ]; then
        echo "$SANDBOX_NAME: exited $rc — $PASS passed, $FAIL failed"
    else
        echo "$SANDBOX_NAME: $PASS passed, $FAIL failed"
    fi
    rm -rf "$SANDBOX"
    exit "$rc"
}
trap _sandbox_finish EXIT
