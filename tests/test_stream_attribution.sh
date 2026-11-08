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
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

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
    sandbox_bash 'DEBUGLOG="'"$T"'/stream.jsonl" stream_written_files' \
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

# ---------------------------------------------------------------------------
# The weak tier: stream_mentioned_files. Writer shapes are unbounded, so this
# pass stops guessing at them and takes every path-shaped string in a command,
# resolving relative ones against a `cd` in the same command. Its records
# cannot excuse a deletion, which is what makes the generosity safe.
parse_weak() { # <command>
    python3 - "$1" "$T/stream.jsonl" <<'PY'
import json, sys
open(sys.argv[2], "w").write(json.dumps({
    "type": "assistant",
    "message": {"model": "m", "content": [
        {"type": "tool_use", "name": "Bash", "input": {"command": sys.argv[1]}}]},
}) + "\n")
PY
    sandbox_bash 'DEBUGLOG="'"$T"'/stream.jsonl" stream_mentioned_files' \
        | sort | tr '\n' ' ' | sed 's/ *$//'
}
has_weak() { # <desc> <command> <path that must appear>
    local got; got="$(parse_weak "$2")"
    case " $got " in *" $3 "*) ok "$1" ;; *) fail "$1" "$got" ;; esac
}
lacks_weak() { # <desc> <command> <path that must NOT appear>
    local got; got="$(parse_weak "$2")"
    case " $got " in *" $3 "*) fail "$1" "$got" ;; *) ok "$1" ;; esac
}

mkdir -p "$T/data"
: > "$T/data/wants.md"

echo "== the weak tier catches what no writer list can =="
# The exact 2026-08-07 02:23 command, in miniature: inline interpreter,
# relative path, quoted heredoc body, cwd set by a cd in the same command.
has_weak "heredoc python with a cd and a relative path" \
    "$(printf 'cd %s && python3 - <<%sEOF%s\np = %swants.md%s\nopen(p, %sw%s).write(s)\nEOF' \
        "$T/data" "'" "'" "'" "'" "'" "'")" \
    "$T/data/wants.md"
has_weak "an absolute path anywhere in a command is declared" \
    "grep -n foo $T/data/wants.md"                     "$T/data/wants.md"
lacks_weak "a relative name that resolves to nothing is not invented" \
    "cd $T/data && cat nosuch.md"                      "$T/data/nosuch.md"
lacks_weak "/dev is never declared"  "cat /dev/null"   "/dev/null"

echo "== the harvest keeps its own evidence =="
# A false alarm is only answerable if the stream that caused it survives the
# next turn. notice_own_writes archives it and records what it declared; both
# are forensics, so the test is that they EXIST and say the right thing, not
# that they change any declaration.
FT="$T/forensics"
mkdir -p "$FT"
: > "$FT/target.md"
python3 - "$FT" > "$T/fstream.jsonl" <<'PY2'
import json, sys
print(json.dumps({"type": "assistant", "message": {"model": "m", "content": [
    {"type": "tool_use", "name": "Write", "input": {"file_path": sys.argv[1] + "/target.md"}}]}}))
PY2

run_harvest() {
    sandbox_bash '
      DEBUGLOG="'"$T"'/fstream.jsonl"
      NOTICE_STATE_DIR="'"$FT"'"; NOTICE_SUPPRESS="'"$FT"'/sup"
      NOTICE_STREAM_DIR="'"$FT"'/streams"; NOTICE_DECLARED_LOG="'"$FT"'/declared.log"
      NOTICE_STREAM_KEEP="'"${1:-20}"'"
      notice_own_writes'
}

run_harvest
n=$(ls -1 "$FT/streams"/*.jsonl 2>/dev/null | wc -l)
[ "$n" -eq 1 ] && ok "the turn's stream is archived" || fail "the turn's stream is archived" "$n"
if grep -q "target.md" "$FT/streams"/*.jsonl 2>/dev/null; then
    ok "the archived copy is the stream itself"
else
    fail "the archived copy is the stream itself" "$(ls "$FT/streams" 2>/dev/null)"
fi
if grep -q "strong=$FT/target.md	weak=$" "$FT/declared.log" 2>/dev/null; then
    ok "the declared log names what was declared"
else
    fail "the declared log names what was declared" "$(cat "$FT/declared.log" 2>/dev/null)"
fi
if grep -q "$FT/target.md" "$FT/sup" 2>/dev/null; then
    ok "forensics did not disturb the declaration itself"
else
    fail "forensics did not disturb the declaration itself" "$(cat "$FT/sup" 2>/dev/null)"
fi

# Rotation: the archive is scratch and must not grow without bound.
for i in 1 2 3; do sleep 1; run_harvest 2; done
n=$(ls -1 "$FT/streams"/*.jsonl 2>/dev/null | wc -l)
[ "$n" -le 2 ] && ok "the archive is pruned to the keep count" \
                || fail "the archive is pruned to the keep count" "$n"
