#!/bin/bash
# Tests for stream_written_files in lib/common.sh — the parser that reads a
# finished stream log and works out which of her own files this session wrote,
# so the self-change watcher does not report her own hand as an intruder's.
# Run: bash tests/test_stream_attribution.sh
#
# The gap these were written for: on 2026-08-07 a `sed -i` of the wants shelf
# went undeclared (only redirects and rm/mv/cp were parsed) and woke her about
# her own edit. Under-detection means a false alarm; over-detection is worse —
# it would silence a real outside change — so the "must NOT match" cases below
# carry as much weight as the positive ones.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d /tmp/deskcrab-attrtest.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0 FAIL=0
ok()   { PASS=$(( PASS + 1 )); echo "  ok: $1"; }
fail() { FAIL=$(( FAIL + 1 )); echo "  FAIL: $1 — got [$2]"; }

# Build a one-line stream log holding a single Bash tool_use, then ask
# common.sh what it thinks was written.
parse() { # <command>
    python3 - "$1" "$T/stream.jsonl" <<'PY'
import json, sys
open(sys.argv[2], "w").write(json.dumps({
    "type": "assistant",
    "message": {"model": "m", "content": [
        {"type": "tool_use", "name": "Bash", "input": {"command": sys.argv[1]}}]},
}) + "\n")
PY
    # DEBUGLOG must be set AFTER sourcing — common.sh assigns its own.
    bash -c \
        'source "$1/lib/common.sh" >/dev/null 2>&1; DEBUGLOG="$2" stream_written_files' \
        _ "$REPO_DIR" "$T/stream.jsonl" \
        | tr '\n' ' ' | sed 's/ *$//'
}

expect() { # <desc> <command> <expected space-separated paths>
    local got; got="$(parse "$2")"
    [ "$got" = "$3" ] && ok "$1" || fail "$1" "$got"
}

echo "== in-place editors are her own hand =="
expect "sed -i names its file"        "sed -i 's|a|b|' /home/x/wants.md"      "/home/x/wants.md"
expect "sed -i.bak counts too"        "sed -i.bak -e 's/x/y/' /home/x/f.md"   "/home/x/f.md"
expect "perl -pi -e counts"           "perl -pi -e 's/a/b/' /home/x/g.md"     "/home/x/g.md"
expect "tee writes"                   "echo hi | tee /home/x/h.md"            "/home/x/h.md"
expect "truncate writes"              "truncate -s 0 /home/x/i.md"            "/home/x/i.md"

echo "== readers are not writers =="
expect "sed without -i is a read"     "sed -n '1,5p' /home/x/f.md"            ""
expect "grep is a read"               "grep -n foo /home/x/l.md"              ""
expect "a following command is not an operand" \
                                      "sed -i 's/a/b/' /home/x/k.md; cat /home/x/other.md" \
                                      "/home/x/k.md"

echo "== the older rules still hold =="
expect "redirects still parse"        "echo x > /home/x/j.md"                 "/home/x/j.md"
expect "rm still parses"              "rm -f /home/x/gone.md"                 "/home/x/gone.md"

echo "== the shape that actually caught her out =="
expect "heredoc append plus a sed -i in one command yields both" \
    "$(printf 'cat >> /home/x/note.md <<%sEOF%s\ntext with | pipes and /slashes\nEOF\nsed -i %ss|old|new|%s /home/x/wants.md' "'" "'" "'" "'")" \
    "/home/x/note.md /home/x/wants.md"

echo "== malformed input never explodes =="
expect "unbalanced quote yields nothing, not a traceback" \
                                      "sed -i 's/a/b/ /home/x/m.md"           ""

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
