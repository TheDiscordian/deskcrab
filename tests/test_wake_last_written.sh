#!/bin/bash
# The last-written line, specs/wake-queue.md rule 40g: the own-time wake's
# prompt carries one line of sense-data naming the two want documents most
# recently written in and how long ago — placed with the shelf material,
# never at the top of the prompt — and directly beneath it, between the fact
# and the shelf heading, the conscious-return question verbatim: repetition
# is evidence inviting a conscious choice, never a command to choose another
# want. The line names each document by its frontmatter title and never its
# filename, passes over terminal-state and titleless documents even when they
# are the newest files in the drawer, appears with its question on NO wake
# that carries a reason, and costs nothing but itself and the question when
# the drawer is missing or empty. The defect the pair exists for: first a
# streak rule stored in the very want document a streaking sitting does not
# open watched two same-day free sittings land in the same want and never
# fired; then the bare line watched three more streaks form while the
# question that reads it stayed in that same unopened document — both the
# fact and the question have to stand in the room the reflex happens in.
# Run: bash tests/test_wake_last_written.sh
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/conduct" "$D/wants"

cat > "$D/wants.md" <<'EOF'
# Wants

- 🫥 **Why do I keep reaching for invisibility?**
- 🗺️ **A world we can adventure in together**
EOF

# The drawer: two live documents at 5 and 14 hours, a third live one old
# enough that only two may be named, and — as the NEWEST files in the whole
# drawer — a retired document and a frontmatterless scratch file, so the test
# proves exclusion decides the selection rather than trailing behind it.
# Titles deliberately differ from the filenames: the line must be built from
# frontmatter, and a slug leaking through is a failure the assertions below
# can see.
NOW="$(date +%s)"
cat > "$D/wants/streak-a.md" <<'EOF'
---
id: streak-a
title: Why do I keep reaching for invisibility?
state: live
---
The body, which the prompt never carries.
EOF
cat > "$D/wants/streak-b.md" <<'EOF'
---
id: streak-b
title: "A world we can adventure in together"
state: live
---
A quoted title, because the migration writes them quoted.
EOF
cat > "$D/wants/streak-c.md" <<'EOF'
---
id: streak-c
title: The third want, which two-at-most must drop
state: live
---
body
EOF
cat > "$D/wants/streak-gone.md" <<'EOF'
---
id: streak-gone
title: The retired one
state: retired
---
body
EOF
printf 'A scratch file with no frontmatter at all.\n' > "$D/wants/streak-notes.md"
touch -d "@$(( NOW - 5*3600 ))"  "$D/wants/streak-a.md"
touch -d "@$(( NOW - 14*3600 ))" "$D/wants/streak-b.md"
touch -d "@$(( NOW - 3*86400 ))" "$D/wants/streak-c.md"
touch -d "@$(( NOW - 60 ))"      "$D/wants/streak-gone.md" "$D/wants/streak-notes.md"

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
printf '## Who you are\n\nBrief.\n' > "$SANDBOX/persona.md"

run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }
first_at() { printf '%s' "$1" | grep -obF "$2" | head -n1 | cut -d: -f1; }

LINE='Last written in: Why do I keep reaching for invisibility? (5h ago), A world we can adventure in together (14h ago).'
QUESTION='Am I returning because I want the next thing, or because this room was already open?'

echo "the own-time wake carries the line, and carries it in order:"
BODY="$(run 'WAKE_OWN_TIME=1 build_system_prompt --profile wake')"
check "the line is present, both titles, newest first, coarse ages" \
    contains "$BODY" "$LINE"
check "the conscious-return question stands directly beneath it, verbatim" \
    contains "$BODY" "$LINE
$QUESTION"
check "and the question sits immediately above the shelf heading" \
    contains "$BODY" "$QUESTION
YOUR WANTS"
l="$(first_at "$BODY" "$LINE")"
s="$(first_at "$BODY" 'YOUR WANTS')"
if [ -n "$l" ] && [ -n "$s" ]; then
    check "with the shelf material, not at the top of the prompt" [ "$l" -gt 0 ]
    check "and before the shelf, never after it" [ "$l" -lt "$s" ]
else
    fail "the line and the shelf are both in the prompt" "line=[$l] shelf=[$s]"
fi
refute "the retired document is passed over though it is the newest file" \
    contains "$BODY" "The retired one"
refute "the third-newest live want is not named — two at most" \
    contains "$BODY" "which two-at-most must drop"
refute "no filename or slug leaks into the line" contains "$BODY" "streak-a"
refute "the sense line itself stays bare of instruction" \
    contains "$BODY" "$LINE Consider"
refute "and nothing commands her to choose another want" \
    contains "$BODY" "choose another want"

echo
echo "a wake that carries a reason never gets the line or the question:"
BODY="$(run 'WAKE_REASON="the arrangement needs finishing" build_system_prompt --profile wake')"
refute "a reasoned wake's prompt has no last-written line" \
    contains "$BODY" 'Last written in:'
refute "and no conscious-return question" contains "$BODY" "$QUESTION"
check "and its shelf is otherwise intact" contains "$BODY" 'YOUR WANTS'
BODY="$(run 'WAKE_OWN_TIME=0 build_system_prompt --profile wake')"
refute "an ordinary reason-less wake without the own-time flag has none either" \
    contains "$BODY" 'Last written in:'
refute "nor its question" contains "$BODY" "$QUESTION"
BODY="$(run 'WAKE_OWN_TIME=1 build_system_prompt --profile turn')"
refute "a desk turn never carries it, whatever the environment says" \
    contains "$BODY" 'Last written in:'
refute "nor the question" contains "$BODY" "$QUESTION"

echo
echo "a broken drawer costs the line and its question, never the prompt:"
BODY="$(run 'WAKE_OWN_TIME=1 DESKCRAB_WANTS_DIR="'"$SANDBOX"'/nowhere" build_system_prompt --profile wake')"
refute "a missing drawer: no line" contains "$BODY" 'Last written in:'
refute "and no question standing without its evidence" contains "$BODY" "$QUESTION"
check "and the prompt still assembled around it" contains "$BODY" 'YOUR WANTS'
mkdir -p "$SANDBOX/bare"
BODY="$(run 'WAKE_OWN_TIME=1 DESKCRAB_WANTS_DIR="'"$SANDBOX"'/bare" build_system_prompt --profile wake')"
refute "an empty drawer: no line" contains "$BODY" 'Last written in:'
refute "and no orphaned question" contains "$BODY" "$QUESTION"
check "and the prompt still assembled around it" contains "$BODY" 'YOUR WANTS'
printf 'scratch, no frontmatter\n' > "$SANDBOX/bare/notes.md"
BODY="$(run 'WAKE_OWN_TIME=1 DESKCRAB_WANTS_DIR="'"$SANDBOX"'/bare" build_system_prompt --profile wake')"
refute "a drawer with nothing nameable: no line" contains "$BODY" 'Last written in:'
refute "and again no question" contains "$BODY" "$QUESTION"
check "and the prompt still assembled around it" contains "$BODY" 'YOUR WANTS'
