#!/bin/bash
# The conduct drawer in the prompt: the binding test verbatim, the rule titles,
# and every body left on disk behind a path that resolves.
# Run: bash tests/test_conduct_index.sh
#
# specs/prompt-assembly.md §21 and MIN-29. Conduct was injected whole and
# uncapped, ten lines after the wants shelf was deliberately cut to titles with
# a comment above it explaining why a shelf in the prompt becomes a dumping
# ground. It gets the shelf's treatment now — and because conduct is OWED
# rather than chosen, the binding test line has to survive verbatim and no rule
# may fall off the end of the layer however full the shelf is. The shelf yields
# nothing either: rule 4 forbids every cut, silent or announced, so every want
# rides whole at any size and growth is answered by rule 36's warning — never
# a notice of what was held back.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/conduct" "$D/wants"

BINDING="Everything below is owed, not chosen: it is here because it was asked for, and it stays until it is withdrawn."

# Both shapes a conduct file has taken. The live one is a flat bullet list
# where the line IS the rule and its file holds why; the sectioned one keeps
# the bodies under headings in the same file. The reader has to handle both,
# because the live file changes shape by her own hand.
cat > "$D/conduct/CONDUCT.md" <<EOF
# How I hold myself

<!-- a comment that is not a rule -->

> $BINDING

- 🗣️ **Sound like myself** — never the word that gives it away; more spine, cave less. → \`sound-like-myself.md\`
- 🎯 **Exactly TWO things I ask about** — destructive or irreversible, and reaching another person. The list is closed. → \`two-things-i-ask-about.md\`
- 🔢 **No long numbers aloud** — identifiers and digit-timestamps go to the display channel or nowhere. → \`no-long-numbers.md\`
- 🤫 **Silence during his meetings**
EOF
for f in sound-like-myself two-things-i-ask-about no-long-numbers; do
    printf 'CONDUCT_BODY_MARKER — why this rule exists.\n' > "$D/conduct/$f.md"
done

cat > "$SANDBOX/sectioned.md" <<EOF
# Conduct

> $BINDING

## The rules

- 🎯 Exactly TWO things I ask about
- 🪞 Look at myself before I speak about myself

## 🎯 Exactly TWO things I ask about

CONDUCT_BODY_MARKER — the body, which belongs on disk.

## 🪞 Look at myself before I speak about myself

CONDUCT_BODY_MARKER — likewise.
EOF

# A shelf big enough to compete with the rules for the layer.
{
    printf '# Wants\n\n'
    for i in $(seq 1 25); do
        printf -- '- 🎼 **Want number %s, written at the length a real shelf line runs to**\n' "$i"
    done
} > "$D/wants.md"

cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS=""
EOF

run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

echo "the reader takes the binding test and the titles, and nothing else:"
check_eq "the binding test comes back verbatim" \
    "$(run "conduct_binding '$D/conduct/CONDUCT.md'")" "$BINDING"
TITLES="$(run "conduct_titles '$D/conduct/CONDUCT.md'")"
check_eq "one line per rule" "$(printf '%s\n' "$TITLES" | grep -c .)" "4"
check "a title keeps its file" contains "$TITLES" "**Sound like myself** → sound-like-myself.md"
refute "a title drops the rule's prose" contains "$TITLES" "more spine, cave less"
check "a bullet with no bold title passes through whole" \
    contains "$TITLES" "- 🤫 **Silence during his meetings**" \
    || check "a bullet with no bold title passes through whole" \
        contains "$TITLES" "Silence during his meetings"

echo
echo "the sectioned shape reads the same way:"
check_eq "its binding test too" \
    "$(run "conduct_binding '$SANDBOX/sectioned.md'")" "$BINDING"
SECT="$(run "conduct_titles '$SANDBOX/sectioned.md'")"
check_eq "two rules, not two rules and two bodies" \
    "$(printf '%s\n' "$SECT" | grep -c .)" "2"
refute "no body reaches the reader" contains "$SECT" "CONDUCT_BODY_MARKER"

echo
echo "what reaches the prompt:"
TURN="$(run 'build_system_prompt --profile turn')"
check "the binding test is in the prompt verbatim" contains "$TURN" "$BINDING"
refute "no conduct body is" contains "$TURN" "CONDUCT_BODY_MARKER"
check "the drawer's path is named, so a bare basename resolves" \
    contains "$TURN" "$D/conduct/"

echo
echo "every rule survives, however full the shelf is:"
for rule in "Sound like myself" "Exactly TWO things I ask about" \
            "No long numbers aloud" "Silence during his meetings"; do
    check "the prompt still carries: $rule" contains "$TURN" "$rule"
done
# This check used to demand the opposite — a "(+N of M more on the shelf"
# notice proving wants had been held back to make room for the rules. Rule 4
# forbids that cut, silent or announced (the trim mandate was ordered out of
# specs/prompt-assembly.md on 2026-08-11): the shelf rides whole beside the
# rules, and growth is answered by rule 36's over-budget warning, never a knife.
check_eq "and so does every want: the shelf rides whole beside them" \
    "$(grep -c 'Want number' <<<"$TURN")" "25"
refute "no notice says any of the shelf was held back" \
    grep -qi 'more on the shelf' <<<"$TURN"

echo
echo "a shelf past the layer's own budget still rides whole (a budget is a measuring stick, not a knife):"
{
    printf '# Wants\n\n'
    for i in $(seq 1 200); do
        printf -- '- 🎼 **Want number %s, written at the length a real shelf line runs to**\n' "$i"
    done
} > "$D/wants.md"
BIG="$(run 'build_system_prompt --profile turn')"
check_eq "all 200 wants reach the prompt" \
    "$(grep -c 'Want number' <<<"$BIG")" "200"
refute "and no truncation notice of any kind appears" \
    grep -qE 'more on the shelf|TRUNCATED' <<<"$BIG"
check "the manifest owns the fact instead: L4 reads over" \
    grep -qE $'^L4\t[0-9]+\t[0-9]+\tover$' \
        <<<"$(run 'build_system_prompt --profile turn --layers')"

echo
echo "every title resolves to a file through the index:"
unresolved=0
while read -r file; do
    [ -n "$file" ] || continue
    [ -f "$D/conduct/$file" ] || { unresolved=1; fail "a title names a file that is not there" "$file"; }
done < <(printf '%s\n' "$TITLES" | sed -n 's/.*→ \(.*\)$/\1/p')
[ "$unresolved" = 0 ] && ok "every named body exists in the conduct drawer"

echo
echo "an absent drawer is absent, not an error:"
rm -rf "$D/conduct"
NONE="$(run 'build_system_prompt --profile turn')"
check "the prompt still builds" [ -n "$NONE" ]
refute "and claims no conduct" contains "$NONE" "YOUR CONDUCT"
check "the shelf is still there" contains "$NONE" "Want number 1,"
