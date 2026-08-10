#!/bin/bash
# The cocoon: constituent files are read-only in a live session — specs/cocoon.md
# rules 1-5. Run: bash tests/test_cocoon_gate.sh
#
# The gate is a PreToolUse hook, so it is tested the way the CLI runs it: a
# tool-call JSON on stdin, a deny JSON (or silence) on stdout. The repo under
# judgement is the sandbox's own copy, handed in as DESKCRAB_REPO exactly as
# claude_profile_flags hands it to the live hook.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

GATE="$SANDBOX_REPO/lib/cocoon-gate"
D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D" "$HOME/.config/deskcrab"

gate() {  # <json on stdin via heredoc> -> stdout
    DESKCRAB_REPO="$SANDBOX_REPO" "$GATE"
}

denies() {  # <desc> <json>
    local out; out="$(printf '%s' "$2" | gate)"
    case "$out" in
        *'"permissionDecision": "deny"'*)
            case "$out" in
                *"crab job"*) ok "$1" ;;
                *) fail "$1" "denied, but the road out is not named: $out" ;;
            esac ;;
        *) fail "$1" "allowed: ${out:-<silence>}" ;;
    esac
}

allows() {  # <desc> <json>
    local out; out="$(printf '%s' "$2" | gate)"
    [ -z "$out" ] && ok "$1" || fail "$1" "$out"
}

echo "writes to what constitutes her are denied, and the deny names the road:"
denies "an Edit to the repo" \
    "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$SANDBOX_REPO/lib/common.sh\"}}"
denies "a Write to the repo" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$SANDBOX_REPO/specs/cocoon.md\"}}"
denies "an Edit to her conf" \
    "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$HOME/.config/deskcrab/deskcrab.conf\"}}"
denies "a git commit in the repo, through Bash" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $SANDBOX_REPO commit -m x\"}}"
denies "a redirection into the repo, through Bash" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x >> $SANDBOX_REPO/lib/common.sh\"}}"
denies "a sed -i on the repo, through Bash" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sed -i s/a/b/ $SANDBOX_REPO/crab\"}}"

echo
echo "her drawers and her reads are never gated:"
allows "a Write to the wants shelf" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$D/wants.md\"}}"
allows "a Write to the chess drawer" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$D/chess/games/one.json\"}}"
allows "a read-shaped git, though it names the repo" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C $SANDBOX_REPO log --oneline\"}}"
allows "a grep across the repo" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep -rn dispute $SANDBOX_REPO/lib\"}}"
allows "a write that touches nothing constituent" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo x > /tmp/scratch.txt\"}}"
allows "crab job is the road, not a violation" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"crab job \\\"rewrite the wake queue\\\"\"}}"

echo
echo "symlinks are judged by what they point at:"
ln -s "$SANDBOX_REPO/lib/common.sh" "$SANDBOX/via-link.sh"
denies "an Edit through a symlink into the repo" \
    "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$SANDBOX/via-link.sh\"}}"

echo
echo "a broken gate does not brick her hands:"
out="$(printf 'not json at all' | gate)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] \
    && ok "malformed input fails open, silently" \
    || fail "malformed input fails open, silently" "rc=$rc out=$out"

echo
echo "the gate rides the right profiles:"
flags() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; claude_profile_flags $1; printf '%s\n' \"\${CLAUDE_PROFILE_FLAGS[@]}\""; }
for p in turn wake; do
    F="$(flags $p)"
    case "$F" in
        *--settings*) ok "$p carries the cocoon settings" ;;
        *) fail "$p carries the cocoon settings" "$F" ;;
    esac
    SETTINGS="$(printf '%s\n' "$F" | grep -A1 -x -- --settings | tail -n1)"
    grep -q "cocoon-gate" "$SETTINGS" 2>/dev/null \
        && ok "$p: and the settings point at the gate" \
        || fail "$p: and the settings point at the gate" "$SETTINGS: $(cat "$SETTINGS" 2>/dev/null)"
done
for p in job classify; do
    case "$(flags $p)" in
        *--settings*) fail "$p carries no gate — builders keep their hands" ;;
        *) ok "$p carries no gate — builders keep their hands" ;;
    esac
done
