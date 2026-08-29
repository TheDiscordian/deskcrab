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
#   <live prefix>-prefix.log    rule 13b's witness: EVERY live run that loads
#                               the library appends its one prefix-choice
#                               line here — wakes, job steps, the bridge, the
#                               entry script — so it moves whenever the live
#                               instance breathes. The code-under-test side
#                               is held elsewhere: the sandbox pins
#                               DESKCRAB_PREFIX_LOG (rule 2), and
#                               test_state_prefix_isolation greps its choice
#                               lines out of the PINNED log, so a regression
#                               that ignored the pin goes red there.
#   <live prefix>-game/         the resident game session's state: its engine
#                               rewrites engine-state.json, state.json,
#                               player-engine-state.json and player-runner.json
#                               about every TWO SECONDS for as long as it plays
#                               — hours — pausing only for the length of its
#                               model calls. That cadence defeats the second
#                               look deterministically: quiet at the before
#                               photograph (mid-call), one burst mid-test,
#                               quiet again through any settle window (the
#                               next call) — which is exactly how one
#                               acceptance run on 2026-08-29 accused it
#                               settled while the immediate retry excused it
#                               still-moving. The code-under-test side is
#                               held by the pins: the sandbox exports
#                               DESKCRAB_GAME_STATE_DIR, OPENRSC_STATE_DIR
#                               and DESKCRAB_OPENRSC_STATE_DIR into its own
#                               root, and the game suites read their fixtures
#                               and actions back through the pin.
#   <live data>/metrics/        the token ledger (lib/token_ledger.py): one
#                               record appended per live model attempt, from
#                               EVERY live hand — wakes, builders, the chess
#                               movers — for as long as the machine is awake.
#                               DESKCRAB_METRICS_DIR is pinned; the metrics
#                               suite reads through the pin.
#   <live data>/chess/games/
#   <live data>/chess/selfplay/
#   <live data>/chess/reflex.db (+ -journal/-wal)
#                               the resident chess bridge and any running
#                               bench write these move by move and game by
#                               game, with model-call pauses between strokes.
#                               Chess code resolves its home through the
#                               pinned HOME/XDG homes and DESKCRAB_CHESS_DIR;
#                               the chess suites read their games and reflex
#                               rows back through those pins. The rest of the
#                               live chess directory stays photographed.
#   <live data>/wakes/ledger.log
#                               the live queue's own ledger: one line per
#                               live booking, firing and tidy (lib/wake-queue
#                               .sh). ONLY the ledger — booking records stay
#                               photographed, because a booking landing in
#                               the live directory is precisely the quarry.
#   <live data>/jobs            the directory's own mtime line: every sidecar
#                               update is a tmp-and-rename inside it
#                               (lib/job-status), so it moves whenever any
#                               live builder breathes. The FILES under it
#                               stay photographed, except the triplets below.
#   $SANDBOX_RUNNING_JOBS       the stream triplet — <id>.log, <id>.json,
#                               <id>.lock — of each live builder whose
#                               sidecar said "running" with a live pid when
#                               the sandbox was built (enumerated once, like
#                               the foreign logs). A sandboxed test cannot
#                               start a REAL builder: the dispatch gates
#                               refuse a scratch jobs directory and
#                               systemd-run is stubbed. Finished and dead
#                               jobs' files stay photographed.
#   <live state>/notice-self.{heartbeat,pending,log,snap,judged,reported}
#                               the self-change watcher's own cycle files
#                               (lib/notice-selfchange), rewritten on every
#                               trigger of its path unit — and the path unit
#                               triggers on ANY write to the watched
#                               directories, so during live activity they
#                               move about once a minute all day
#                               (lib/canary-selfchange polls exactly this).
#                               No cadence of theirs fits the second look's
#                               windows, and no test causes any of them.
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
# about. The leak check's SECOND LOOK (further down) is what keeps this list
# this short: it tells the two authors apart by time where time can tell them
# apart, excusing BY NAME what is still moving after a test has finished
# instead of growing this list one quietened failure at a time.
_sandbox_drop_external() {  # <live prefix> <live data dir> [<live state dir>]:
                            # a path filter ($3 defaults to the exported knob)
    awk -F'\t' -v seen="$1-phone-seen" -v push="$2/webpush" \
        -v plog="$1-prefix.log" -v game="$1-game" \
        -v metrics="$2/metrics" -v cgames="$2/chess/games" \
        -v cself="$2/chess/selfplay" -v creflex="$2/chess/reflex.db" \
        -v wledger="$2/wakes/ledger.log" -v jobsdir="$2/jobs" \
        -v state="${3:-${SANDBOX_LIVE_STATE:-}}" '
        BEGIN {
            n = split(ENVIRON["SANDBOX_FOREIGN_LOGS"], _f, "\n")
            for (i = 1; i <= n; i++) if (_f[i] != "") foreign[_f[i]] = 1
            n = split(ENVIRON["SANDBOX_RUNNING_JOBS"], _j, "\n")
            for (i = 1; i <= n; i++) if (_j[i] != "") foreign[_j[i]] = 1
            n = split("heartbeat pending log snap judged reported", _w, " ")
            for (i = 1; i <= n; i++) watcher[state "/notice-self." _w[i]] = 1
        }
        $1 == seen { next }
        $1 == push || index($1, push "/") == 1 { next }
        $1 == plog { next }
        $1 == game || index($1, game "/") == 1 { next }
        $1 == metrics || index($1, metrics "/") == 1 { next }
        $1 == cgames || index($1, cgames "/") == 1 { next }
        $1 == cself || index($1, cself "/") == 1 { next }
        $1 == creflex || $1 == creflex "-journal" || $1 == creflex "-wal" { next }
        $1 == wledger { next }
        $1 == jobsdir { next }
        $1 in watcher { next }
        $1 in foreign { next }
        { print }'
}

# The running builders' stream triplets, for the list above. Read from the
# sidecars the way lib/job-status writes them: a "state": "running" line and a
# "pid" that is alive right now. Unit-held by tests/test_sandbox.sh against a
# crafted jobs directory, so no live sidecar has to exist to prove it.
_sandbox_running_jobs() {  # <live jobs dir> — triplet paths, one per line
    local _rj_sc _rj_pid
    for _rj_sc in "$1"/*.json; do
        [ -e "$_rj_sc" ] || continue
        grep -q '"state": *"running"' "$_rj_sc" 2>/dev/null || continue
        _rj_pid="$(sed -n 's/^ *"pid": *\([0-9][0-9]*\).*/\1/p' "$_rj_sc" \
            | head -1)"
        [ -n "$_rj_pid" ] && kill -0 "$_rj_pid" 2>/dev/null || continue
        printf '%s\n' "${_rj_sc%.json}.log" "$_rj_sc" "${_rj_sc%.json}.lock"
    done
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

    # Rule 19's door (specs/test-harness.md). The after-the-fact checks —
    # tests/test_exec_bits.sh and `run.sh --list` — name a fault some commit
    # already created, and three days after they landed a new test landed
    # 100644 anyway, because nothing obliged its author to run them between
    # the add and the commit. What every author IS obliged to run is the new
    # test itself (rule 18: red before the fix), and every test walks through
    # here first — so this is where a bad mode stops. Refuse before building
    # anything: a test file missing the bit on disk, or one its repository
    # holds staged or committed 100644 (the chmod-after-add shape, which the
    # disk no longer shows). `git ls-files` is a read of the index, nothing
    # more; a file outside any repository is judged on its disk bit alone.
    if [ ! -x "$_sb_self" ]; then
        echo "  FAIL: $_sb_name is not executable — chmod +x '$_sb_self'" \
             "and commit the mode change (specs/test-harness.md rule 19)"
        exit 1
    fi
    _sb_mode="$(cd "$(dirname "$_sb_self")" 2>/dev/null && \
        git ls-files -s -- "$_sb_self" 2>/dev/null | awk '{ print $1; exit }')"
    if [ "$_sb_mode" = "100644" ]; then
        echo "  FAIL: $_sb_name is staged or committed mode 100644 —" \
             "chmod +x '$_sb_self' and \`git add\` it again, so the" \
             "committed mode is 100755 (specs/test-harness.md rule 19)"
        exit 1
    fi
    unset _sb_mode

    _sb_root="$(mktemp -d "${TMPDIR:-/tmp}/crabtest-$_sb_name-XXXXXX")"

    mkdir -p \
        "$_sb_root/home" "$_sb_root/tmp" "$_sb_root/bin" "$_sb_root/conf" \
        "$_sb_root/state" "$_sb_root/state/game" \
        "$_sb_root/run" "$_sb_root/cache" "$_sb_root/config" \
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
        # The moment first, in the photograph's own clock: the second look's
        # hot-before evidence measures a live path's mtime against it.
        date +%s.%N > "$1.at"
        {
            find "$_sb_live_data" "$_sb_live_state" "$_sb_live_conf" \
                -printf '%p\t%s\t%T@\n' 2>/dev/null
            find "$(dirname "$_sb_live_prefix")" -maxdepth 1 \
                -name "$(basename "$_sb_live_prefix")*" \
                ! -path "$_sb_root*" \
                -printf '%p\t%s\t%T@\n' 2>/dev/null
        } | _sandbox_drop_external "$_sb_live_prefix" "$_sb_live_data" \
                                   "$_sb_live_state" \
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

    # The running builders' stream triplets, enumerated the same way, at the
    # same moment, for the same reason: both photographs must drop exactly the
    # same paths. The comment above _sandbox_drop_external carries the why.
    SANDBOX_RUNNING_JOBS="$(_sandbox_running_jobs "$_sb_live_data/jobs")"
    export SANDBOX_RUNNING_JOBS

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
        SANDBOX_RUNNING_JOBS="$SANDBOX_RUNNING_JOBS" \
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
        CODEX_BIN="$_sb_root/bin/codex" \
        DESKCRAB_CODEX_STATE="$_sb_root/data/deskcrab/codex-state" \
        DESKCRAB_ALLOW_SCRATCH_BOOKING=1 \
        DESKCRAB_SANDBOX_SETTLE="${DESKCRAB_SANDBOX_SETTLE:-}" \
        DESKCRAB_SANDBOX_VIGIL="${DESKCRAB_SANDBOX_VIGIL:-}" \
        DESKCRAB_GAME_STATE_DIR="$_sb_root/state/game" \
        OPENRSC_STATE_DIR="$_sb_root/state/game" \
        DESKCRAB_OPENRSC_STATE_DIR="$_sb_root/state/game" \
        MEMORY_PYTHON="$_sb_venv" \
        SANDBOX_CODEX_LOG="$_sb_root/witness/codex.log" \
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
_sandbox_photo_after() {  # [<out basename>], default $SANDBOX/leak/after —
                          # the second look photographs a third time, elsewhere
    local _pa_out="${1:-$SANDBOX/leak/after}"
    date +%s.%N > "$_pa_out.at"
    {
        find "$SANDBOX_LIVE_DATA" "$SANDBOX_LIVE_STATE" "$SANDBOX_LIVE_CONF" \
            -printf '%p\t%s\t%T@\n' 2>/dev/null
        find "$(dirname "$SANDBOX_LIVE_PREFIX")" -maxdepth 1 \
            -name "$(basename "$SANDBOX_LIVE_PREFIX")*" \
            ! -path "$SANDBOX*" \
            -printf '%p\t%s\t%T@\n' 2>/dev/null
    } | _sandbox_drop_external "$SANDBOX_LIVE_PREFIX" "$SANDBOX_LIVE_DATA" \
      | LC_ALL=C sort > "$_pa_out.raw"
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
    cp "$_pa_out.raw" "$_pa_out"
    env XDG_RUNTIME_DIR="$SANDBOX_REAL_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$SANDBOX_REAL_DBUS" \
        /usr/bin/systemctl --user list-units 'deskcrab-*' --all --no-legend \
        2>/dev/null | LC_ALL=C sort > "$_pa_out.units"
    XDG_RUNTIME_DIR="$SANDBOX_REAL_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$SANDBOX_REAL_DBUS" \
        _sandbox_timers_photo "$_pa_out.timers"
}

# --- the second look -------------------------------------------------------
# The photograph can prove THAT a live path moved, never WHOSE hand moved it,
# and rule 9 of specs/test-harness.md says the harness may only accuse. For
# weeks the accusation fell on whichever test was running when ANY live hand
# wrote: the night the exec-bit record was being proven, the game harness was
# rewriting its /tmp state every two seconds until dawn and the selfplay
# bench kept the live games directory moving, so every run of every suite
# wore the LEAK verdict, exit 2, whatever its assertions had found. A
# sentinel that fires on every run is not a sentinel — the genuine red that
# motivated all this sat on screen dressed in the same verdict as the
# weather, and was dismissed with it.
#
# What tells the two hands apart is TIME. When the photographs differ, the
# harness waits a settle interval (DESKCRAB_SANDBOX_SETTLE seconds, default
# five — longer than the fastest known live writer's cadence) and photographs
# a THIRD time. The test is finished by then — its at-exit hooks have run,
# its assertions are counted — so a path still moving between the second and
# third photographs is being written by something that is not this test.
# Those paths are excused from the verdict and NAMED, one per line, because a
# silent exclusion is how gates go blind. Motion evidence flows one level
# between a directory and its direct children — a directory's mtime IS a
# function of them — so a settled game file under a still-moving live games
# directory is that live writer's earlier stroke, excused with it, while a
# settled SIBLING (the planted-leak shape) never is: siblings are separate
# writers. Everything else that moved during the run and then fell quiet
# stays accused, exactly as before.
#
# The residual ambiguity is owned, not hidden: a cold burst writer that
# landed one stroke mid-test and went quiet inside the settle window is still
# accused (a hand reads the verdict), and a background FILE writer LEAKED by
# the code under test would excuse itself here — the witness logs and the
# persistent units hold that shape, and the excused list prints either way so
# a reader can see what was forgiven.

# The identity of a photograph line: the path for the path photograph (its
# first tab field), the unit name for the units and timers photographs (the
# first whitespace token that says deskcrab — list-units may lead with a
# marker glyph, list-timers with the absolute times). `-` for a line with no
# identity; such a line is never excused.
_sandbox_photo_keys() {  # <photo> — one key per line, aligned with the file
    awk -F'\t' '{
        key = "-"
        if (NF >= 2) key = $1
        else {
            n = split($0, w, /[[:space:]]+/)
            for (i = 1; i <= n; i++)
                if (w[i] ~ /deskcrab/) { key = w[i]; break }
        }
        print key
    }' "$1"
}

_sandbox_drop_keys() {  # <keys file> <photo> — the photo minus those keys' lines
    paste <(_sandbox_photo_keys "$2") "$2" | awk -F'\t' -v keys="$1" '
        BEGIN { while ((getline k < keys) > 0)
                    if (k != "" && k != "-") drop[k] = 1 }
        { key = $1; sub(/^[^\t]*\t/, ""); if (!(key in drop)) print }'
}

# sandbox_second_look <before> <after> <settle> <out prefix> — 0 when every
# difference between <before> and <after> is confined to keys with foreign
# evidence, or one directory level from one that has it. Three kinds of
# evidence, each causally clean:
#
#   still moving   the key changed again between <after> and <settle>. The
#                  test was finished; this cannot be its writing.
#   hot before     the key's mtime in <before> sits within the settle
#                  interval of the moment that photograph was taken (read
#                  from "<before>.at" when the photograph left one). The
#                  test had not run yet; whoever wrote it then is real and
#                  active, and the bench's burst writers — quiet longer than
#                  any settle interval mid-model-call — are exactly this
#                  shape. A photograph without a stamp gets no hot excuses.
#   transient unit the key is a -<moment>-<pid> stamped unit, the shape
#                  systemd-run mints for wakes, jobs and the watchers. Inside
#                  the sandbox the user manager is unreachable by
#                  construction — no session bus, a pinned runtime dir,
#                  stubbed tools — so no test can put one in the REAL
#                  manager, and the self-change watcher's two-minute defer
#                  cycle was handing a settled flap to whichever test
#                  spanned it. A persistent unit's change stays accused.
#
# Evidence flows one directory level, parent to child and child to parent —
# a directory's mtime IS a function of its direct children — so a settled
# game file under a hot or still-moving live games directory is that live
# writer's earlier stroke. A settled SIBLING (the planted-leak shape) is
# never excused: siblings are separate writers.
#
# Writes <out>.excused (the keys forgiven, one per line) and <out>.diff
# (what remains accused; empty when clean). Public: the state-prefix
# isolation test holds its own photograph pair to the same standard.
sandbox_second_look() {
    local before="$1" after="$2" settle="$3" out="$4"
    local t0=""
    [ -f "$before.at" ] && t0="$(cat "$before.at")"
    LC_ALL=C comm -3 "$after" "$settle" 2>/dev/null \
        | sed 's/^\t//' > "$out.changed"
    _sandbox_photo_keys "$out.changed" | grep -v '^-$' \
        | LC_ALL=C sort -u > "$out.stillmoving"
    if [ -n "$t0" ]; then
        awk -F'\t' -v t0="$t0" -v hot="${DESKCRAB_SANDBOX_SETTLE:-5}" \
            'NF >= 3 && (t0 - $3) <= hot { print $1 }' "$before" \
            | LC_ALL=C sort -u > "$out.hot"
    else
        : > "$out.hot"
    fi
    diff "$before" "$after" 2>/dev/null \
        | sed -n 's/^[<>] //p' > "$out.disputed"
    _sandbox_photo_keys "$out.disputed" | grep -v '^-$' \
        | LC_ALL=C sort -u > "$out.disputedkeys"
    awk -v still="$out.stillmoving" -v hotf="$out.hot" '
        function dirof(p) { sub(/\/[^\/]*$/, "", p); return p }
        function transient_unit(k) {
            if (k ~ /^\//) return 0
            return (k ~ /-1[0-9]{9}-[0-9]+/ ||
                    k ~ /-20[0-9]{6}-[0-9]{6}-[0-9]+/)
        }
        BEGIN {
            while ((getline k < still) > 0) if (k != "") ev[k] = 1
            while ((getline k < hotf) > 0) if (k != "") ev[k] = 1
        }
        { keys[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++)
                if (transient_unit(keys[i])) ev[keys[i]] = 1
            for (k in ev) evdir[dirof(k)] = 1
            for (i = 1; i <= NR; i++) {
                k = keys[i]
                if (k in ev || dirof(k) in ev || k in evdir) print k
            }
        }
    ' "$out.disputedkeys" > "$out.excused"
    _sandbox_drop_keys "$out.excused" "$before" > "$out.before"
    _sandbox_drop_keys "$out.excused" "$after" > "$out.after"
    diff "$out.before" "$out.after" > "$out.diff" 2>/dev/null
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
    _sandbox_photo_after "$SANDBOX/leak/after"
    local what moved=0 leaked=0 churned=0
    for what in "" ".units" ".timers"; do
        diff -q "$SANDBOX/leak/before$what" "$SANDBOX/leak/after$what" \
            >/dev/null 2>&1 || moved=1
    done
    [ "$moved" = 0 ] && return 0

    # Something moved: the second look, held open as a VIGIL. Only a run that
    # already differs pays for it; a clean run never sleeps. A live writer's
    # quiet stretch can outlast any single settle interval — the game engine
    # and the bench movers go silent for the length of a model call, which is
    # how one acceptance run accused a path settled that its immediate retry
    # excused still-moving — so while anything is still accused the harness
    # keeps waiting one settle interval and photographing again, up to
    # DESKCRAB_SANDBOX_VIGIL seconds in total. The comparison is against the
    # LATEST photograph, so a stroke in any round is evidence in every later
    # one. The vigil ends the moment nothing is left accused; a path still
    # silent when it runs out has had the whole window to show a foreign
    # hand, and keeps the accusation.
    local settle="${DESKCRAB_SANDBOX_SETTLE:-5}"
    local rounds round
    rounds="$(awk -v v="${DESKCRAB_SANDBOX_VIGIL:-60}" -v s="$settle" \
        'BEGIN { r = (s + 0 > 0) ? int(v / s) : 1; print (r < 1) ? 1 : r }')"
    for (( round = 1; round <= rounds; round++ )); do
        sleep "$settle"
        _sandbox_photo_after "$SANDBOX/leak/settle"
        leaked=0
        for what in "" ".units" ".timers"; do
            diff -q "$SANDBOX/leak/before$what" "$SANDBOX/leak/after$what" \
                >/dev/null 2>&1 && continue
            sandbox_second_look \
                "$SANDBOX/leak/before$what" "$SANDBOX/leak/after$what" \
                "$SANDBOX/leak/settle$what" "$SANDBOX/leak/look$what" \
                || leaked=1
        done
        [ "$leaked" = 0 ] && break
    done
    for what in "" ".units" ".timers"; do
        diff -q "$SANDBOX/leak/before$what" "$SANDBOX/leak/after$what" \
            >/dev/null 2>&1 && continue
        if [ -s "$SANDBOX/leak/look$what.diff" ]; then
            [ "$leaked" = 1 ] && [ "$moved" = 1 ] && {
                echo
                echo "  LEAK: live state moved while this test ran. What moved:"
                moved=2
            }
            sed 's/^/    /' "$SANDBOX/leak/look$what.diff" | head -40
        fi
        [ -s "$SANDBOX/leak/look$what.excused" ] && {
            [ "$churned" = 0 ] && {
                echo
                echo "  churn: these moved while the test ran and were STILL moving"
                echo "  after it finished — another hand's writing, not this test's;"
                echo "  excused from the verdict, named so nothing is silent:"
            }
            churned=1
            sed 's/^/    /' "$SANDBOX/leak/look$what.excused"
        }
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
        echo "  Every path this test writes is under its own root, and whatever"
        echo "  kept moving after the test finished has been excused above as"
        echo "  another hand's churn — so a path accused here moved while this"
        echo "  test ran and then FELL SILENT. That is either a hardcoded live"
        echo "  path in the code under test or a concurrent hand's one-shot"
        echo "  write — an unsandboxed run in another shell, or the live"
        echo "  instance between strokes. The paths above say which to chase."
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
