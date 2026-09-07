#!/bin/bash
# Joining is not searching — the bounded search under each root.
# specs/turn-pipeline.md rule 32bd. On 2026-09-07 at 03:27 the checker accused
# a kept promise: the reply named `bar57/reading-<date>.md`, the file stood
# under the Library root two directories down, and the disk record read
# "NOT found on disk" because every path-resolving section joined a root to
# the token instead of searching under it. The shared resolver
# (lib/promise_paths.py) keeps the plain join as the fast path and falls back
# to a bounded walk whose matches' trailing components equal the token; a
# token matching at two or more places is named found-in-multiple, never
# silently taken as the first; a token nowhere on disk still reads NOT found.
# Run: bash tests/test_promise_path_search.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
T="$SANDBOX"
W="$T/wakes"
mkdir -p "$W" "$T/repo/lib"

# The checker, copied (not linked — it resolves SCRIPT_DIR through its own
# path and would walk back to the real repo and its real crab), beside a door
# onto the real wake module. Same fixture as test_promise_check.sh.
cp "$REPO/lib/promise-check" "$T/repo/lib/promise-check"
chmod +x "$T/repo/lib/promise-check"
ln -sf "$REPO/lib/common.sh" "$T/repo/lib/common.sh"
ln -sf "$REPO/lib/wake-queue.sh" "$T/repo/lib/wake-queue.sh"
ln -sf "$REPO/lib/extract-response" "$T/repo/lib/extract-response"

cat > "$T/repo/crab" <<CRAB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/wake-calls"
[ "\${1:-}" = "wake-at" ] || exit 0
shift
source "$REPO/lib/common.sh" >/dev/null 2>&1
wake_book "\$@"
CRAB
chmod +x "$T/repo/crab"

# PROJECT_DIR is the turn's own workdir — a built-in root. The drawer under
# test nests THREE levels below it, where no plain join reaches.
HOUSE="$T/home/house"
DEEP="$HOUSE/a/b/c"
mkdir -p "$DEEP"
cat > "$DESKCRAB_CONF" <<CONF
PROJECT_DIR="$HOUSE"
PIPER_VOICE="$T/voice.onnx"
WHISPER_MODEL="$T/whisper.bin"
MEMORY_STORE=0
PROMISE_CHECK=1
CONF

export WAKES_DIR="$W"
export PROMISE_LEDGER="$T/ledger.jsonl"

CHECK_LOG="$DESKCRAB_STATE_PREFIX-promise-check.log"
records()  { ls "$W"/*.wake 2>/dev/null | wc -l; }
ledger_n() { sandbox_count_in . "$T/ledger.jsonl"; }
claude_n() { sandbox_count_in . "$SANDBOX_CLAUDE_LOG"; }
reset()    { rm -f "$W"/*.wake "$W/ledger.log" "$T/wake-calls" "$T/ledger.jsonl" \
                   "$CHECK_LOG" "$SANDBOX_CLAUDE_LOG" "$T/model-stdin" \
                   "$DEEP"/*.md; }

# A stream log with no tool calls at all — the announcing turn's own record
# is empty, so only the disk can acquit.
SNAP_EMPTY="$T/snap-empty.jsonl"
cat > "$SNAP_EMPTY" <<'EOF'
{"type":"assistant","message":{"model":"real","content":[{"type":"text","text":"a reply whose turn ran no tools"}]}}
{"type":"result","result":"done"}
EOF
snap() { cp "$SNAP_EMPTY" "$T/snap-live.jsonl"; printf '%s' "$T/snap-live.jsonl"; }

# The judge stub is POISON on purpose: if the checker consults the model for
# a claim the artefact already backs, the stub convicts, and the ledger and
# wake assertions catch the false flag exactly as the live night did.
poison() {
sandbox_stub claude <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "${SANDBOX_CLAUDE_LOG}"
cat > "$T/model-stdin"
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"UNKEPT: \"whatever was claimed\" | the turn record shows nothing"}]}}'
printf '%s\n' '{"type":"result","result":"ok"}'
STUB
}

NOW="$(date +%s)"
CLAIM="I've written it up in \`c/thing.md\`."

echo "the 03:27 shape: a fresh file three levels under a root, named by its tail, acquits itself:"
reset; poison
printf '## tonight\nthe write-up\n' > "$DEEP/thing.md"
touch -d "@$(( NOW - 60 ))" "$DEEP/thing.md"
"$T/repo/lib/promise-check" turn wake "$NOW" 6001 "$(snap)" \
    "$T/ledger.jsonl" "$CLAIM" >/dev/null 2>&1
check_eq "the model was never called — the bounded search found the drawer" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked — no accusation" "$(ledger_n)$(records)" "00"
check "the trace names the resolved artefact" \
    grep -qF "backed: the artefact $DEEP/thing.md" "$CHECK_LOG"

echo
echo "a STALE deep file is judge evidence with its mtime, never a NOT-found accusation:"
reset; poison
printf 'old notes\n' > "$DEEP/thing.md"
touch -d "@$(( NOW - 7200 ))" "$DEEP/thing.md"
"$T/repo/lib/promise-check" turn wake "$NOW" 6002 "$(snap)" \
    "$T/ledger.jsonl" "$CLAIM" >/dev/null 2>&1
check_eq "the model WAS consulted — the mtime sits hours before the claim" "$(claude_n)" "1"
check "and the judge reads exists-with-mtime, not NOT-found" \
    grep -qF "c/thing.md — exists ($DEEP/thing.md), modified" "$T/model-stdin"
check "no NOT-found line accuses the token" \
    bash -c "! grep -qF 'c/thing.md — NOT found on disk' '$T/model-stdin'"

echo
echo "the same tail under TWO roots is named found-in-multiple, never silently the first:"
reset; poison
mkdir -p "$T/rootA/x/c" "$T/rootB/y/c"
printf 'copy one\n' > "$T/rootA/x/c/thing.md"
printf 'copy two\n' > "$T/rootB/y/c/thing.md"
touch -d "@$(( NOW - 60 ))" "$T/rootA/x/c/thing.md" "$T/rootB/y/c/thing.md"
echo "PROMISE_PATH_ROOTS='$T/rootA:$T/rootB'" >> "$DESKCRAB_CONF"
"$T/repo/lib/promise-check" turn wake "$NOW" 6003 "$(snap)" \
    "$T/ledger.jsonl" "$CLAIM" >/dev/null 2>&1
check_eq "ambiguity never acquits — the model WAS consulted" "$(claude_n)" "1"
check "the judge is told the match is ambiguous" \
    grep -qF "c/thing.md — found in MULTIPLE places" "$T/model-stdin"
check "naming the first candidate" grep -qF "$T/rootA/x/c/thing.md" "$T/model-stdin"
check "and the second" grep -qF "$T/rootB/y/c/thing.md" "$T/model-stdin"
rm -rf "$T/rootA" "$T/rootB"

echo
echo "a token nowhere on disk still reads NOT found — the search loosens nothing:"
reset; poison
"$T/repo/lib/promise-check" turn wake "$NOW" 6004 "$(snap)" \
    "$T/ledger.jsonl" "I've written it up in \`c/nowhere.md\`." >/dev/null 2>&1
check_eq "the model WAS consulted" "$(claude_n)" "1"
check_eq "and the flag lands: one ledger line, one wake" "$(ledger_n)$(records)" "11"
check "the judge reads the honest absence" \
    grep -qF "c/nowhere.md — NOT found on disk" "$T/model-stdin"

echo
echo "a shadow copy that embeds the original's path is a mirror, not ambiguity:"
reset; poison
printf '## tonight\nthe write-up\n' > "$DEEP/thing.md"
touch -d "@$(( NOW - 60 ))" "$DEEP/thing.md"
MIRROR="$T/data/deskcrab/self-shadows$DEEP"
mkdir -p "$MIRROR"
cp "$DEEP/thing.md" "$MIRROR/thing.md"
touch -d "@$(( NOW - 30 ))" "$MIRROR/thing.md"
"$T/repo/lib/promise-check" turn wake "$NOW" 6006 "$(snap)" \
    "$T/ledger.jsonl" "$CLAIM" >/dev/null 2>&1
check_eq "the model was never called — the mirror collapsed onto the original" "$(claude_n)" "0"
check_eq "nothing ledgered, nothing booked" "$(ledger_n)$(records)" "00"
check "the trace names the ORIGINAL, not the shadow" \
    grep -qF "backed: the artefact $DEEP/thing.md" "$CHECK_LOG"
rm -rf "$T/data/deskcrab/self-shadows"

echo
echo "the walk's walls hold: a drawer inside a hidden directory is not searched:"
reset; poison
mkdir -p "$HOUSE/.hidden/c"
printf 'unreachable\n' > "$HOUSE/.hidden/c/thing.md"
touch -d "@$(( NOW - 60 ))" "$HOUSE/.hidden/c/thing.md"
"$T/repo/lib/promise-check" turn wake "$NOW" 6005 "$(snap)" \
    "$T/ledger.jsonl" "$CLAIM" >/dev/null 2>&1
check_eq "the model WAS consulted — hidden directories stay outside the walk" "$(claude_n)" "1"
check "and the token reads NOT found" \
    grep -qF "c/thing.md — NOT found on disk" "$T/model-stdin"
