#!/bin/bash
# The suite. One command, one line per test, one summary.
#
#   bash tests/run.sh              run everything
#   bash tests/run.sh --list       name every test and check it is executable
#   bash tests/run.sh -v           print the output of anything that is not green
#   bash tests/run.sh test_wake    run the tests whose names match
#
# Every test runs inside tests/lib/sandbox.sh, which means: the assistant can be
# offline, nothing beyond localhost is reached, no model session is started, no
# audio is played, no window is opened, and no unit is created in the user
# manager. A test that damages live state fails LOUDLY here — the sandbox's own
# exit check reports it as a leak whatever its assertions said.
#
# The exceptions are named in UNSANDBOXED below: files that predate the helper
# and pin their own scratch root. They hold the same four gates by hand and are
# missing only the leak check. The roll call runs before the suite does and
# fails on any OTHER file that skips the helper, so the set stays four and
# shrinks as they are converted.
#
# Exit status: non-zero if anything failed. A skip is not a failure and a skip
# is never silent — it says why on its own line.
set -u

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TESTS_DIR="$REPO/tests"
TIMEOUT="${DESKCRAB_TEST_TIMEOUT:-300}"
VERBOSE=0
LIST=0
declare -a FILTERS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --list|-l) LIST=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) FILTERS+=("$1") ;;
    esac
    shift
done

matches() { # <name>
    [ "${#FILTERS[@]}" -eq 0 ] && return 0
    local f
    for f in "${FILTERS[@]}"; do case "$1" in *"$f"*) return 0 ;; esac; done
    return 1
}

# --- the sandbox roll call -------------------------------------------------
# specs/test-harness.md rule 1: there is exactly one sandbox helper and it is
# the only way a test sources the library. Nothing asserted it. Four files
# predate the helper and carry a hand-rolled sandbox of their own — every knob
# pinned into a scratch root, every desktop tool stubbed — but they run outside
# `env -i` and outside the exit-time leak check, and a test added tomorrow
# without the helper line was indistinguishable from them: green, unchecked,
# and unmentioned.
#
# So the four are NAMED, and the roll call fails on anything else that does not
# source the helper. It also fails on a name here that HAS since been
# converted, so the list can only ever shrink. Their own gates are described in
# each file's header; what they are missing is the leak check, and that is the
# entry that comes off this list when one of them is converted.
UNSANDBOXED="test_debug_view test_limit_fallback test_phone_client test_prompt_cases"

sandbox_roll_call() { # -> 0 clean, 1 something is unaccounted for
    local f name rc=0 listed
    for f in "$TESTS_DIR"/test_*.sh; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .sh)"
        case " $UNSANDBOXED " in *" $name "*) listed=1 ;; *) listed=0 ;; esac
        if grep -q 'lib/sandbox\.sh' "$f"; then
            [ "$listed" = 1 ] || continue
            printf '  %s  IS sandboxed — take it out of UNSANDBOXED in run.sh\n' \
                "${f#"$REPO"/}"
            rc=1
        else
            [ "$listed" = 1 ] && continue
            printf '  %s  DOES NOT source tests/lib/sandbox.sh\n' "${f#"$REPO"/}"
            rc=1
        fi
    done
    return "$rc"
}

# --- the roll call ---------------------------------------------------------
declare -a SHELL_TESTS=()
for f in "$TESTS_DIR"/test_*.sh; do
    [ -e "$f" ] || continue
    matches "$(basename "$f")" && SHELL_TESTS+=("$f")
done
PY_TEST="$TESTS_DIR/test_memory.py"
matches "$(basename "$PY_TEST")" || PY_TEST=""

if [ "$LIST" = 1 ]; then
    rc=0
    for f in "${SHELL_TESTS[@]}"; do
        name="$(basename "$f" .sh)"
        case " $UNSANDBOXED " in
            *" $name "*) note="  (its own sandbox — no leak check)" ;;
            *) note="" ;;
        esac
        if [ -x "$f" ]; then
            printf '  %s%s\n' "${f#"$REPO"/}" "$note"
        else
            printf '  %s  NOT EXECUTABLE\n' "${f#"$REPO"/}"
            rc=1
        fi
    done
    [ -n "$PY_TEST" ] && printf '  %s\n' "${PY_TEST#"$REPO"/}"
    sandbox_roll_call || rc=1
    exit "$rc"
fi

# The roll call runs before anything else does: a file that reaches live state
# has already done it by the time its assertions are counted.
if ! sandbox_roll_call; then
    echo
    echo "Every test runs inside tests/lib/sandbox.sh. The exceptions are named"
    echo "in UNSANDBOXED in this file, with what they do instead; nothing else"
    echo "may skip it, and a name there that no longer needs to be comes out."
    exit 1
fi

# --- the run ---------------------------------------------------------------
OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/crabsuite-XXXXXX")"
trap 'rm -rf "$OUTDIR"' EXIT

PASSED=0 FAILED=0 SKIPPED=0
declare -a FAILED_NAMES=()

report() { # <state> <name> <secs> [detail]
    case "$1" in
        PASS) printf '  PASS  %-28s %ss\n' "$2" "$3" ;;
        SKIP) printf '  SKIP  %-28s %s\n' "$2" "${4:-}" ;;
        FAIL) printf '  FAIL  %-28s %ss  %s\n' "$2" "$3" "${4:-}" ;;
    esac
}

run_one() { # <name> <log> <rc> <secs>
    local name="$1" log="$2" rc="$3" secs="$4" detail=""
    case "$rc" in
        0)  PASSED=$(( PASSED + 1 )); report PASS "$name" "$secs" ;;
        77) SKIPPED=$(( SKIPPED + 1 ))
            detail="$(sed -n 's/^ *skip: //p' "$log" | head -1)"
            report SKIP "$name" "$secs" "${detail:-no reason given}" ;;
        124) FAILED=$(( FAILED + 1 )); FAILED_NAMES+=("$name")
            report FAIL "$name" "$secs" "timed out after ${TIMEOUT}s" ;;
        2)  FAILED=$(( FAILED + 1 )); FAILED_NAMES+=("$name")
            report FAIL "$name" "$secs" "LEAKED INTO LIVE STATE" ;;
        *)  FAILED=$(( FAILED + 1 )); FAILED_NAMES+=("$name")
            detail="$(grep -m1 '^ *FAIL' "$log" | sed 's/^ *//')"
            report FAIL "$name" "$secs" "${detail:-exit $rc}" ;;
    esac
    if [ "$rc" != 0 ] && [ "$rc" != 77 ] && [ "$VERBOSE" = 1 ]; then
        sed 's/^/        /' "$log"
    fi
}

echo "deskcrab suite — $(( ${#SHELL_TESTS[@]} + $([ -n "$PY_TEST" ] && echo 1 || echo 0) )) tests"
echo

for f in "${SHELL_TESTS[@]}"; do
    name="$(basename "$f" .sh)"
    log="$OUTDIR/$name.log"
    start=$(date +%s)
    timeout "$TIMEOUT" bash "$f" > "$log" 2>&1
    rc=$?
    run_one "$name" "$log" "$rc" "$(( $(date +%s) - start ))"
done

# The memory module's own tests. They load the real lib/memory.py, which needs
# sqlite-vec, which lives in the store's venv — so the interpreter is chosen
# HERE rather than left to the module to re-execute into halfway through a
# framework's collection, which is what makes a bare `pytest` in this repo exit
# 1 with no output at all. tests/conftest.py refuses that re-exec for the same
# reason; this picks the right interpreter up front so it never comes up.
if [ -n "$PY_TEST" ]; then
    name="test_memory"
    log="$OUTDIR/$name.log"
    start=$(date +%s)
    VENV="${MEMORY_PYTHON:-$HOME/.local/share/deskcrab/venv/bin/python}"
    PY=""
    for cand in "$VENV" python3; do
        [ -n "$cand" ] || continue
        command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
        if "$cand" -c 'import sqlite_vec' 2>/dev/null; then PY="$cand"; break; fi
    done
    if [ -z "$PY" ]; then
        echo "  skip: no interpreter here can import sqlite_vec (make the store venv:" \
             "uv venv ~/.local/share/deskcrab/venv && uv pip install" \
             "--python ~/.local/share/deskcrab/venv/bin/python sqlite-vec)" > "$log"
        run_one "$name" "$log" 77 0
    else
        # The module's own isolation: its scratch stores must not declare
        # themselves in the LIVE self-change suppression file, and its recall
        # diagnostics must not land in the LIVE recall log.
        SB="$(mktemp -d "${TMPDIR:-/tmp}/crabmem-XXXXXX")"
        mkdir -p "$SB/state" "$SB/data"
        runner=unittest
        "$PY" -c 'import pytest' 2>/dev/null && runner=pytest
        if [ "$runner" = pytest ]; then
            ( cd "$REPO" && timeout "$TIMEOUT" env \
                XDG_STATE_HOME="$SB/state" XDG_DATA_HOME="$SB/data" \
                DESKCRAB_STATE_PREFIX="$SB/deskcrab" MEMORY_PYTHON="$PY" \
                "$PY" -m pytest -q tests/test_memory.py ) > "$log" 2>&1
        else
            ( cd "$REPO" && timeout "$TIMEOUT" env \
                XDG_STATE_HOME="$SB/state" XDG_DATA_HOME="$SB/data" \
                DESKCRAB_STATE_PREFIX="$SB/deskcrab" MEMORY_PYTHON="$PY" \
                "$PY" -m unittest tests.test_memory ) > "$log" 2>&1
        fi
        rc=$?
        rm -rf "$SB"
        run_one "$name" "$log" "$rc" "$(( $(date +%s) - start ))"
    fi
fi

echo
if [ "$FAILED" -gt 0 ]; then
    echo "FAILED: ${FAILED_NAMES[*]}"
    echo "  (bash tests/run.sh -v ${FAILED_NAMES[0]}  for the output)"
fi
echo "$PASSED passed, $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
