#!/usr/bin/env bash
# Tests for the sliding-window conversation compaction in lib/common.sh —
# specifically that a TURN MEANS A TURN, whoever spoke.
#
# The gap these were written for: _compact_split counted only lines beginning
# "^User: ", so an autonomous wake — an "Assistant: " block with no user line
# above it — was invisible to the window. A conversation that is mostly wakes
# never reached the threshold and never compacted once: on 2026-08-07 the live
# file held 17 user blocks and 27 assistant blocks against CONVO_MAX_TURNS=20,
# and the trim had never fired, so roughly double the intended history rode
# along on every turn.
#
# Everything here is confined to a mktemp dir with its own DESKCRAB_STATE_PREFIX
# and a stub claude — no real summarizer call, no live conversation touched.
# Run: bash tests/test_convo_compaction.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO_DIR="$SANDBOX_REPO"
T="$SANDBOX"

# The stub summarizer: records the prompt it was handed (so a test can prove the
# folded blocks actually reached it) and answers with a fixed summary.
sandbox_stub claude <<EOF
#!/usr/bin/env bash
printf '%s' "\${!#}" > "$T/summary-prompt.txt"
printf 'CONDENSED SUMMARY\n'
EOF
cat > "$DESKCRAB_CONF" <<EOF
PROJECT_DIR="$T"
SESSIONS_LOG="$T/sessions.log"
WANTS_FILE=""
PROMISE_AUDIT=0
MEMORY_STORE=0
EOF

# shellcheck source=/dev/null
source "$REPO_DIR/lib/common.sh" >/dev/null 2>&1

# --- fixture -----------------------------------------------------------------
# A conversation shaped like the real one that never compacted: a handful of
# real exchanges, then a long run of autonomous wakes talking to nobody. The
# user-block count stays well under CONVO_MAX_TURNS on purpose — that is the
# whole point. Under the old "^User: "-only counter this file is invisible to
# the window no matter how long it gets.
#
# STAMP controls which block header format the fixture is written in. Both must
# work: blocks are stamped ("User [2026-08-07 12:01]: …") since 2026-08-07, and
# every conversation and archive written before that is unstamped. The stamped
# case is not decoration — gawk silently mangles a '\['-escaped dynamic regex,
# so a pattern that greps stamped headers perfectly can count none of them
# inside the split, which is invisible to an unstamped fixture.
STAMP=0
_hdr() { # <speaker> -> the block header prefix
    if [ "$STAMP" = "1" ]; then printf '%s [2026-08-07 12:01]: ' "$1"
    else printf '%s: ' "$1"; fi
}

build_convo() { # <n-exchanges> <n-wakes>
    local ex="$1" wakes="$2" i
    : > "$CONVOFILE"
    for (( i = 1; i <= ex; i++ )); do
        printf '%squestion %d\n' "$(_hdr User)" "$i" >> "$CONVOFILE"
        printf '%sanswer %d\n\n' "$(_hdr Assistant)" "$i" >> "$CONVOFILE"
    done
    for (( i = 1; i <= wakes; i++ )); do
        printf '[Autonomous wake — 2026-08-07 %02d:00]\n' "$(( i % 24 ))" >> "$CONVOFILE"
        printf '%swake thought %d\n\n' "$(_hdr Assistant)" "$i" >> "$CONVOFILE"
    done
}

# Counted independently of the code under test — a literal alternation, not the
# shared CONVO_BLOCK_RE, so a broken pattern cannot agree with itself.
blocks() { grep -cE '^(User|Assistant)( \[[^]]*\])?: ' "$CONVOFILE"; }

reset() { rm -f "$SUMMARYFILE" "$T/summary-prompt.txt"; }

# Strip whichever header form a block carries, so the assertions below are about
# the compaction and not about the stamp.
body() { sed -E 's/^(User|Assistant)( \[[^]]*\])?: //'; }

# Everything below runs twice: once over the unstamped block format every
# conversation used before 2026-08-07 (and every archive still does), once over
# the stamped one written since.
for STAMP in 0 1; do
FMT=$( [ "$STAMP" = 1 ] && echo "stamped" || echo "unstamped" )
echo "=== $FMT blocks ==="

# --- 1. the bug: wake-only blocks must count toward the window ----------------
echo "wake blocks count toward the window:"
reset
CONVO_MAX_TURNS=20 CONVO_SUMMARIZE_TURNS=10
build_convo 6 16          # 6 user + 6 assistant + 16 wake assistant = 28 blocks
check_eq "[$FMT] fixture stays under the OLD user-only threshold" \
    "$(( $(grep -cE '^User( \[[^]]*\])?: ' "$CONVOFILE") <= CONVO_MAX_TURNS ? 1 : 0 ))" "1"
check_eq "[$FMT] fixture is over the real block threshold" "$(blocks)" "28"

compact_convo

if [ -s "$SUMMARYFILE" ]; then
    ok "[$FMT] compaction fired on a wake-heavy conversation"
else
    fail "[$FMT] compaction never fired — the counter still ignores wake blocks"
fi
check_eq "[$FMT] summary holds the summarizer output" \
    "$(cat "$SUMMARYFILE" 2>/dev/null)" "CONDENSED SUMMARY"
check_eq "[$FMT] oldest CONVO_SUMMARIZE_TURNS blocks were dropped" "$(blocks)" "18"

# The 10 folded blocks are the 6 exchanges' first 10 blocks: U1 A1 .. U5 A5.
check_eq "[$FMT] folded block reached the summarizer" \
    "$(grep -c 'answer 5$' "$T/summary-prompt.txt")" "1"
check_eq "[$FMT] kept block was NOT folded" \
    "$(grep -c 'answer 6$' "$T/summary-prompt.txt")" "0"
check_eq "[$FMT] first surviving block is the 11th" \
    "$(head -1 "$CONVOFILE" | body)" "question 6"
check_eq "[$FMT] first surviving block is still a user block" \
    "$(head -1 "$CONVOFILE" | cut -c1-4)" "User"
check_eq "[$FMT] last block survived untouched" \
    "$(grep -c 'wake thought 16$' "$CONVOFILE")" "1"

# --- 2. a wake header stays with the reply it introduces ----------------------
# The header is not a block of its own; if the split tears it off, the surviving
# conversation opens with a bare "Assistant:" that reads as a reply to whatever
# came before it, and the wake it belonged to is gone from the record.
echo "wake headers stay attached to their reply:"
reset
CONVO_MAX_TURNS=6 CONVO_SUMMARIZE_TURNS=4
build_convo 2 6           # 2 user + 2 assistant + 6 wake assistant = 10 blocks
compact_convo
check_eq "[$FMT] trimmed to the remaining blocks" "$(blocks)" "6"
check_eq "[$FMT] surviving convo opens with its wake header" \
    "$(head -1 "$CONVOFILE" | cut -c1-16)" "[Autonomous wake"
check_eq "[$FMT] every surviving wake block still has a header" \
    "$(grep -c '^\[Autonomous wake' "$CONVOFILE")" "6"
check_eq "[$FMT] no header was orphaned into the summary" \
    "$(grep -c '^\[Autonomous wake' "$T/summary-prompt.txt")" "0"

# --- 3. an all-wake conversation compacts too ---------------------------------
# The pathological case: not one user line in the file. Under the old counter
# this could grow without bound forever.
echo "a conversation of nothing but wakes:"
reset
CONVO_MAX_TURNS=10 CONVO_SUMMARIZE_TURNS=5
build_convo 0 14
check_eq "[$FMT] no user blocks at all" \
    "$(grep -cE '^User( \[[^]]*\])?: ' "$CONVOFILE")" "0"
compact_convo
check_eq "[$FMT] compaction still fired" \
    "$(cat "$SUMMARYFILE" 2>/dev/null)" "CONDENSED SUMMARY"
check_eq "[$FMT] oldest 5 wake blocks folded away" "$(blocks)" "9"
check_eq "[$FMT] wake 5 was folded" "$(grep -c 'wake thought 5$' "$CONVOFILE")" "0"
check_eq "[$FMT] wake 6 was kept" "$(grep -c 'wake thought 6$' "$CONVOFILE")" "1"

# --- 4. under the threshold, nothing happens ----------------------------------
# The counter got looser; it must not have got trigger-happy. A conversation at
# exactly the threshold is not over it.
echo "at or under the threshold nothing is trimmed:"
reset
CONVO_MAX_TURNS=20 CONVO_SUMMARIZE_TURNS=10
build_convo 4 12          # exactly 20 blocks
check_eq "[$FMT] fixture sits exactly on the threshold" "$(blocks)" "20"
BEFORE="$(md5sum < "$CONVOFILE")"
compact_convo
check_eq "[$FMT] convo untouched" "$(md5sum < "$CONVOFILE")" "$BEFORE"
check_eq "[$FMT] no summary written" \
    "$([ -f "$SUMMARYFILE" ] && echo yes || echo no)" "no"
check_eq "[$FMT] summarizer never called" \
    "$([ -f "$T/summary-prompt.txt" ] && echo yes || echo no)" "no"

# --- 5. a failed summarization loses nothing ----------------------------------
# compact_convo drops the old lines only after the summarizer answers. If the
# model call fails, the history must stay whole rather than evaporate.
echo "a failed summarizer never drops history:"
reset
mv "$T/bin/claude" "$T/bin/claude.ok"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/claude"
chmod +x "$T/bin/claude"
CONVO_MAX_TURNS=10 CONVO_SUMMARIZE_TURNS=5
build_convo 2 12
BEFORE="$(md5sum < "$CONVOFILE")"
compact_convo
check_eq "[$FMT] convo intact after a failed summary" "$(md5sum < "$CONVOFILE")" "$BEFORE"
mv "$T/bin/claude.ok" "$T/bin/claude"

# --- 6. the compaction must be quiet ------------------------------------------
# A dynamic-regex warning on stderr is not cosmetic here: gawk printing
# "escape sequence \[ treated as plain [" is it telling you the pattern it
# actually compiled is not the one written, which is exactly how a stamped
# block stops being counted.
echo "compaction writes nothing to stderr:"
reset
CONVO_MAX_TURNS=10 CONVO_SUMMARIZE_TURNS=5
build_convo 3 10
check_eq "[$FMT] no warnings from the split" "$(compact_convo 2>&1 >/dev/null)" ""

done
