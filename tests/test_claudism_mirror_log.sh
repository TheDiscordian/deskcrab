#!/bin/bash
# The live mirror's flag-log and family shape — specs/speech-output.md rules
# 51-52 — and the error-only subcall discipline of rules 7a/42a. Run:
# bash tests/test_claudism_mirror_log.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

echo "the live mirror's log and call (speech-output rules 51-52):"
# A rewrite row carries the words that went out, and the mirror call sees
# the fired entry's whole family — context for the resay, never a gate on it.
MLIST="$T/mirror-list.md"
cat > "$MLIST" <<'LIST'
## the honesty family
- pattern: `\bhonestly\b`
- why: assumed of her anyway.
- function: vouching

## decoration
- pattern: `\bgenuinely\b`
- why: the same move, one word over.
- function: vouching
- live: no

## flat apology
- pattern: `\bI apologize\b`
- why: another family entirely.
- function: apologising

## bare habit
- pattern: `\bneedless to say\b`
- why: an entry with no function at all.
LIST
MIRROR="$REPO/lib/claudism-mirror"

FAM="$("$MIRROR" family "$MLIST" vouching)"; rc=$?
check_eq "family exits clean" "$rc" "0"
check "the fired pattern is in its own family" contains "$FAM" 'honestly'
check "a live: no sibling is shown too — the wide net is visible at resay time" \
    contains "$FAM" 'genuinely'
refute "another function's entry stays out" contains "$FAM" 'apologize'
check_eq "an unknown function prints nothing and exits clean" \
    "$("$MIRROR" family "$MLIST" nosuch; echo "rc=$?")" "rc=0"
check_eq "a missing list prints nothing and exits clean — context, never a gate" \
    "$("$MIRROR" family "$T/absent.md" vouching; echo "rc=$?")" "rc=0"

FL="$T/flags-live"
printf '%s' '{"sentence": "Honestly, the kettle is on.", "pattern": "\\bhonestly\\b", "note": "the honesty family", "function": "vouching"}' \
    | "$MIRROR" logflag "$FL" wake 7002 rewrite "The kettle is on."
ROW="$(cat "$FL"/*.jsonl)"
check "a rewrite row carries the held sentence as before" \
    contains "$ROW" '"before": "Honestly, the kettle is on."'
check "and the words that replaced it as after (rule 51)" \
    contains "$ROW" '"after": "The kettle is on."'
printf '%s' '{"sentence": "Honestly, twice.", "pattern": "\\bhonestly\\b"}' \
    | "$MIRROR" logflag "$FL" wake 7003 original-mirror-failed
refute "a failed mirror logs no after — nothing replaced the line" \
    contains "$(tail -1 "$FL"/*.jsonl)" '"after"'

echo
echo "and both are wired through the whole-draft pass in lib/common.sh:"
cat > "$T/claude-stub" <<STUB
#!/bin/bash
cat > "$T/mirror-prompt.txt"
printf '%s\n' '{"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":"The kettle is on."}]}}'
printf '%s\n' '{"type":"result","result":"The kettle is on."}'
STUB
chmod +x "$T/claude-stub"
FL2="$T/flags-direct"
DIRECT="$(CLAUDE_BIN="$T/claude-stub" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL2" \
    sandbox_bash 'claudism_mirror_direct wake "Honestly, the kettle is on."')"
check_eq "the fired line was resaid in her stubbed voice" \
    "$DIRECT" "The kettle is on."
PROMPT="$(cat "$T/mirror-prompt.txt" 2>/dev/null)"
check "the call's prompt carries the family banner (rule 52)" \
    contains "$PROMPT" 'Its whole family (vouching)'
check "with the sibling visible at the moment of resaying" \
    contains "$PROMPT" 'genuinely'
ROW="$(cat "$FL2"/*.jsonl 2>/dev/null)"
check "the pass logged the rewrite with its words (rule 51)" \
    contains "$ROW" '"after": "The kettle is on."'
check "as a rewrite outcome, before/after like a table swap" \
    contains "$ROW" '"outcome": "rewrite"'
rm -f "$T/mirror-prompt.txt"
DIRECT="$(CLAUDE_BIN="$T/claude-stub" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL2" \
    sandbox_bash 'claudism_mirror_direct wake "Needless to say, tea is up."')"
refute "an entry with no function prompts exactly as before" \
    contains "$(cat "$T/mirror-prompt.txt" 2>/dev/null)" 'Its whole family'
cat > "$T/claude-stub2" <<STUB
#!/bin/bash
cat > "$T/mirror-prompt2.txt"
printf '%s\n' '{"type":"assistant","message":{"model":"m","id":"msg_A","content":[{"type":"text","text":"Genuinely: the kettle is on."}]}}'
printf '%s\n' '{"type":"result","result":"Genuinely: the kettle is on."}'
STUB
chmod +x "$T/claude-stub2"
DIRECT="$(CLAUDE_BIN="$T/claude-stub2" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL2" \
    sandbox_bash 'claudism_mirror_direct wake "Honestly, the kettle is on."')"
check_eq "a resay that lands on the sibling anyway still goes out — informed, never gated (rule 41)" \
    "$DIRECT" "Genuinely: the kettle is on."

echo
echo "an error-only stream: a main turn's report, a subcall's nothing (rules 7a/42a):"
# The live failure of 2026-08-20, 01:06 and 01:10: the mirror's resay hit an
# OAuth failure, extract-response stood the CLI's error text in as the reply
# (right for a main turn, its rule-7 shape), and the caller spliced it into
# the written reply in place of her sentence, logging outcome=rewrite. The
# stream below is that failure's shape verbatim.
AUTHERR="Failed to authenticate: OAuth session expired and could not be refreshed"
AUTHLOG="$T/auth-only.log"
cat > "$AUTHLOG" <<'LOG'
{"type":"assistant","message":{"model":"<synthetic>","id":"msg_err","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"is_api_error_message":true}
{"type":"result","result":"Failed to authenticate: OAuth session expired and could not be refreshed","is_error":true}
LOG
check_eq "without the flag, an error-only stream reports itself exactly as before (rule 7)" \
    "$(DESKCRAB_DEBUGLOG="$AUTHLOG" "$REPO/lib/extract-response")" "$AUTHERR"
check_eq "with the flag, the same stream prints nothing at all (rule 7a)" \
    "$(DESKCRAB_DROP_SYNTHETIC=1 DESKCRAB_DEBUGLOG="$AUTHLOG" "$REPO/lib/extract-response")" ""
cat > "$T/good.log" <<'LOG'
{"type":"assistant","message":{"model":"m","id":"msg_g","content":[{"type":"text","text":"The kettle is on."}]}}
{"type":"result","result":"The kettle is on."}
LOG
check_eq "a genuine reply extracts identically under the flag" \
    "$(DESKCRAB_DROP_SYNTHETIC=1 DESKCRAB_DEBUGLOG="$T/good.log" "$REPO/lib/extract-response")" \
    "The kettle is on."

echo
echo "and through the mirror: the draft stands, the row says the mirror failed (rule 42a):"
cat > "$T/claude-auth-stub" <<STUB
#!/bin/bash
cat > /dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","id":"msg_err","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]},"is_api_error_message":true}'
printf '%s\n' '{"type":"result","result":"Failed to authenticate: OAuth session expired and could not be refreshed","is_error":true}'
STUB
chmod +x "$T/claude-auth-stub"
FL3="$T/flags-auth"
DIRECT="$(CLAUDE_BIN="$T/claude-auth-stub" CLAUDISMS_FILE="$MLIST" CLAUDISM_FLAGS_DIR="$FL3" \
    sandbox_bash 'claudism_mirror_direct wake "Honestly, the kettle is on."')"
check_eq "an auth-failed mirror call leaves the draft exactly as written" \
    "$DIRECT" "Honestly, the kettle is on."
refute "the CLI's error text reaches the reply nowhere" \
    contains "$DIRECT" "Failed to authenticate"
ROW="$(cat "$FL3"/*.jsonl 2>/dev/null)"
check "the flag row reads original-mirror-failed" \
    contains "$ROW" '"outcome": "original-mirror-failed"'
refute "never rewrite — the receipt may not claim a catch that did not happen" \
    contains "$ROW" '"outcome": "rewrite"'
refute "and carries no after — nothing replaced the line" contains "$ROW" '"after"'
