#!/bin/bash
# One copy of anything — specs/prompt-assembly.md rules 40 and 40a. A build
# that carries the same paragraph block through two document layers emits it
# once, names the drop in the manifest under the layer it was dropped from,
# and leaves the standing record the state block renders; a build with no
# duplication emits no `dedup` lines and removes the record; a block under
# the floor is never judged; and the transcript layer is exempt, because no
# pass may remove a word of the evidence.
# Run: bash tests/test_prompt_dedup.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/conduct" "$D/wants" "$D/engineering" "$D/memory"

cat > "$D/wants.md" <<'EOF'
# Wants

- 🎼 **Learn to read a score** → score.md
- 🌱 **Keep a window box** → window-box.md
- 📻 **Build the little radio** → radio.md
EOF

cat > "$D/conduct/CONDUCT.md" <<'EOF'
# Conduct

> Everything below is owed, not chosen: it is here because it was asked for.

- 🎯 **Exactly TWO things I ask about** — the two, spelled out. → `two-things.md`
- 🪞 **Look at myself before I speak about myself** → `looking.md`
EOF

# A transcript line long enough to clear the dedup floor, used twice below:
# once as a conversation line, once as a persona paragraph. The evidence
# layer is exempt from the pass, so both copies must ride.
EVIDENCE='User [12:00]: the same one hundred and thirty byte sentence, said once by him and once quoted whole inside the persona sheet below.'

cat > "$SANDBOX/persona.md" <<EOF
## Who you are

Dry, brief, and you answer the person in front of you, at some length so that
this paragraph clears the de-duplication floor without any padding tricks.

$EVIDENCE
EOF
cp "$SANDBOX/persona.md" "$SANDBOX/persona.orig.md"

cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
CUSTOM_PROMPT="$SANDBOX/persona.md"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS=""
EOF

printf '%s\nAssistant [12:01]: an answer\n' "$EVIDENCE" \
    > "$DESKCRAB_STATE_PREFIX-convo.txt"

REC="$DESKCRAB_STATE_PREFIX-prompt-dupes.txt"
run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

echo "a build with no duplication: an empty drop list, no record, no warning:"
man="$(run 'build_system_prompt --profile turn --layers')"
refute "no dedup line in the manifest" grep -q '^dedup	' <<<"$man"
check "no standing record" [ ! -s "$REC" ]
body="$(run 'build_system_prompt --profile turn')"
refute "and the state block renders nothing about duplicates" \
    contains "$body" "DUPLICATE BLOCK"

echo
echo "the transcript layer is exempt — the evidence rides even when L1 has the same words:"
n="$(grep -cxF -- "$EVIDENCE" <<<"$body")"
check_eq "the shared sentence appears in both L1 and L6" "$n" "2"

echo
echo "the same block through two layers is emitted once, and the drop is named:"
# Self-maintaining fixture: take the wants block exactly as the assembler
# emitted it into L4, and plant that block verbatim in the persona sheet, so
# the test never hard-codes the layer's own wording.
BLK="$(printf '%s\n' "$body" | sed -n '/^YOUR WANTS/,/^[[:space:]]*$/p' | awk 'NF')"
check "the wants block was found in the clean build" [ -n "$BLK" ]
check "and it clears the 100-byte floor" [ "$(printf '%s' "$BLK" | wc -c)" -ge 100 ]
FIRST="$(printf '%s\n' "$BLK" | head -n 1)"
printf '\n%s\n' "$BLK" >> "$SANDBOX/persona.md"

body2="$(run 'build_system_prompt --profile turn')"
n="$(grep -cxF -- "$FIRST" <<<"$body2")"
check_eq "the duplicated block appears exactly once in the build" "$n" "1"
check "the rest of the shelves layer survives the drop" \
    contains "$body2" "Exactly TWO things I ask about"
man2="$(run 'build_system_prompt --profile turn --layers')"
check "the manifest names the drop: from L4, already carried by L1" \
    grep -qP '^dedup\tL4\tdup-of=L1\tdropped\t' <<<"$man2"
check "the drop line carries the block's size in bytes" \
    grep -qP '^dedup\t.*\t[0-9]+ bytes' <<<"$man2"
check "the drop line sits under the row of the layer it was dropped from" \
    grep -qPz 'L4\t[0-9]+\t[0-9]+\t[a-z]+\ndedup\tL4\t' <<<"$man2"
check "the speaking build left the standing record" [ -s "$REC" ]
check "which carries the same drop line" \
    grep -qP '^dedup\tL4\tdup-of=L1' "$REC"

echo
echo "the state block renders the record while it stands:"
body3="$(run 'build_system_prompt --profile turn')"
check "the next build's state block names the drop" \
    contains "$body3" "DUPLICATE BLOCK"
check "and says which layer repeated which" \
    contains "$body3" "L4 repeated a block already carried by L1"
check "crab status carries the same fact" \
    contains "$(run 'self_state_report')" "DUPLICATE BLOCK"

echo
echo "the duplication removed, the record goes with it:"
cp "$SANDBOX/persona.orig.md" "$SANDBOX/persona.md"
man3="$(run 'build_system_prompt --profile turn --layers')"
refute "no dedup line once the source is fixed" grep -q '^dedup	' <<<"$man3"
check "a clean speaking build removes the record" [ ! -s "$REC" ]
body4="$(run 'build_system_prompt --profile turn')"
n="$(grep -cxF -- "$FIRST" <<<"$body4")"
check_eq "and the block is back in its own layer, once" "$n" "1"
refute "with no duplicate warning left in the state block" \
    contains "$body4" "DUPLICATE BLOCK"

echo
echo "the floor: a short twin is never judged, a long one is:"
man4="$(run 'PROMPT_PROFILE=turn
    declare -A _PROMPT_SEEN=(); PROMPT_DEDUP_DROPS=""; PROMPT_DEDUP_OUT=""
    PROMPT_BODY=""; PROMPT_MANIFEST=""
    _prompt_layer L1 here "a short twin line"
    _prompt_layer L4 here "a short twin line"
    printf "%s" "$PROMPT_MANIFEST"')"
refute "a twin under 100 normalised bytes is not dropped" \
    grep -q '^dedup	' <<<"$man4"
check "and the second layer still emits it" \
    grep -qP '^L4\t[1-9]' <<<"$man4"
LONG="$(printf 'the same long twin sentence rides here %.0s' $(seq 1 4))"
man5="$(run "PROMPT_PROFILE=turn
    declare -A _PROMPT_SEEN=(); PROMPT_DEDUP_DROPS=\"\"; PROMPT_DEDUP_OUT=\"\"
    PROMPT_BODY=\"\"; PROMPT_MANIFEST=\"\"
    _prompt_layer L1 here \"$LONG\"
    _prompt_layer L4 here \"$LONG\"
    printf '%s' \"\$PROMPT_MANIFEST\"")"
check "a twin over the floor is dropped and recorded" \
    grep -qP '^dedup\tL4\tdup-of=L1\tdropped\t' <<<"$man5"
check "a layer whose every block was a twin manifests absent, with the drop naming why" \
    grep -qP '^L4\t0\t[0-9]+\tabsent' <<<"$man5"
