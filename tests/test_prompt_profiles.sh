#!/bin/bash
# The four profiles: which layers each one carries, in what order, at what
# measured size, against which budget. Run: bash tests/test_prompt_profiles.sh
#
# specs/prompt-assembly.md asks for exactly this file. The fourteen intent
# cases (tests/test_prompt_cases.sh) prove what the prompt SAYS; this proves
# its SHAPE — that a shelf-check wake does not pay a spoken turn's prompt, that
# a one-question classifier carries no persona, no state and no transcript, and
# that the order never moves.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"

# The sandbox's check() runs its argv, so a bare "!" is a command it cannot
# find. Negation gets its own helper rather than a shared-harness change.
refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/conduct" "$D/wants" "$D/engineering" "$D/memory"

cat > "$D/wants.md" <<'EOF'
# Wants

- 🎼 **Learn to read a score**
- 🌱 **Keep a window box**
- 📻 **Build the little radio**
EOF
printf 'WANT_BODY_MARKER — the body of a want, which belongs on disk.\n' > "$D/wants/score.md"

cat > "$D/conduct/CONDUCT.md" <<'EOF'
# Conduct

> Everything below is owed, not chosen: it is here because it was asked for.

- 🎯 **Exactly TWO things I ask about** — the two, spelled out. → `two-things.md`
- 🪞 **Look at myself before I speak about myself** → `looking.md`
EOF
printf 'CONDUCT_BODY_MARKER\n' > "$D/conduct/two-things.md"
printf 'CONDUCT_BODY_MARKER\n' > "$D/conduct/looking.md"
printf '# Threads\n' > "$D/engineering/INDEX.md"

{
    printf '## Who you are\n\nDry, brief, and you answer the person in front of you.\n\n'
    for i in $(seq 1 40); do
        printf '## Section %s\n\nA paragraph of persona, long enough that the identity layer has to choose.\n\n' "$i"
    done
} > "$SANDBOX/persona.md"

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

# Long enough that the per-profile budgets actually bite: a turn keeps 8,000
# bytes of transcript and a wake 3,000, and a fixture under either ceiling
# proves nothing about the difference between them.
{
    printf 'User [12:00]: a question\nAssistant [12:00]: an answer\n'
    for i in $(seq 1 60); do
        printf 'User [12:%02d]: %s\nAssistant [12:%02d]: %s\n' \
            "$i" "the $i-th thing he said, at some length so the layer fills up" \
            "$i" "the $i-th answer, likewise long enough to matter to a budget"
    done
} > "$DESKCRAB_STATE_PREFIX-convo.txt"

# One sourced shell for every assembly below: build_system_prompt is a pure
# read, so the profiles cannot contaminate one another, and a fresh source per
# profile would cost four state-block builds for nothing.
run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

echo "the assembler answers to a profile:"
refute "an unknown profile is refused" \
    run 'build_system_prompt --profile nonsense'
check_eq "no profile at all is a turn" \
    "$(run 'build_system_prompt --layers' | md5sum)" \
    "$(run 'build_system_prompt --profile turn --layers' | md5sum)"
check_eq "SESSION_KIND picks the profile when nothing else does" \
    "$(run 'SESSION_KIND="autonomous wake"; build_system_prompt --layers' | md5sum)" \
    "$(run 'build_system_prompt --profile wake --layers' | md5sum)"

echo
echo "the order never moves:"
ORDER="L1 L2 L3 L4 L5 L6 regroup L7 L8"
for p in turn wake job classify; do
    got="$(run "build_system_prompt --profile $p --layers" | cut -f1 | tr '\n' ' ')"
    check_eq "$p emits every layer key in the contract's order" "${got% }" "$ORDER"
done

echo
echo "each profile carries what that run needs, and nothing else:"
# <profile> <layer> <present|absent>
while read -r p layer want; do
    [ -n "$p" ] || continue
    state="$(run "build_system_prompt --profile $p --layers" \
             | awk -F'\t' -v k="$layer" '$1 == k { print $4 }')"
    got=present; [ "$state" = absent ] && got=absent
    check_eq "$p: $layer is $want" "$got" "$want"
done <<'CASES'
turn L1 present
turn L2 present
turn L4 present
turn L6 present
turn L7 present
turn L8 present
wake L2 present
wake L6 present
job L1 absent
job L2 absent
job L4 absent
job L6 absent
job L5 present
job L8 present
classify L1 absent
classify L2 absent
classify L4 absent
classify L5 absent
classify L6 absent
classify L7 absent
classify L8 present
CASES

echo
echo "every layer is measured, and measured means bytes of what was emitted:"
for p in turn wake; do
    body="$(run "build_system_prompt --profile $p")"
    sum="$(run "build_system_prompt --profile $p --layers" \
           | awk -F'\t' '{ n += $2 } END { print n }')"
    total="$(printf '%s' "$body" | wc -c)"
    # The body is the layers plus one newline between each pair of them, so the
    # manifest accounts for every byte of the prompt bar the separators. Stated
    # as a range rather than an exact sum: the point is that no layer is
    # measured by estimate and none is missing from the manifest, not the
    # arithmetic of where the newlines fall.
    emitted="$(run "build_system_prompt --profile $p --layers" \
               | awk -F'\t' '$4 != "absent"' | grep -c .)"
    check "$p: the manifest's bytes account for the prompt" \
        [ "$total" -ge "$sum" ] && [ "$total" -le "$(( sum + emitted ))" ]
done

echo
echo "the budgets hold:"
for p in turn wake job classify; do
    over="$(run "build_system_prompt --profile $p --layers" \
            | awk -F'\t' '$2 > $3 && $1 != "L2" && $1 != "L5" { print $1 }')"
    check_eq "$p: no trimmable layer is over its budget" "$over" ""
done
# The two that are never cut say so rather than losing content.
state="$(run 'build_system_prompt --profile turn --layers' \
         | awk -F'\t' '$1 == "L5" { print $4 }')"
check "the index is never trimmed — it reports over budget instead" \
    [ "$state" = full ] || [ "$state" = over ]

echo
echo "a classifier does not carry a desktop:"
CLS="$(run 'build_system_prompt --profile classify')"
refute "no persona" contains "$CLS" "Dry, brief"
refute "no state block" contains "$CLS" "CURRENT STATE OF YOURSELF"
refute "no shelf" contains "$CLS" "Learn to read a score"
refute "no conduct" contains "$CLS" "Exactly TWO things"
refute "no transcript" contains "$CLS" "a question"
check "and it is inside its 200-byte total" \
    [ "$(printf '%s' "$CLS" | wc -c)" -le 200 ]

echo
echo "a wake is cheaper than the turn it interrupts:"
t=$(run 'build_system_prompt --profile turn' | wc -c)
w=$(run 'build_system_prompt --profile wake' | wc -c)
j=$(run 'build_system_prompt --profile job' | wc -c)
check "wake < turn" [ "$w" -lt "$t" ]
check "job < wake" [ "$j" -lt "$w" ]
printf '  note  turn %s bytes, wake %s, job %s, classify %s\n' \
    "$t" "$w" "$j" "$(printf '%s' "$CLS" | wc -c)"

echo
echo "the turn frame is last, and the message is not in the prompt at all:"
for p in turn wake job classify; do
    body="$(run "build_system_prompt --profile $p")"
    tail_of="$(printf '%s' "$body" | tail -c 400)"
    check "$p: the prompt ends on the frame" \
        grep -qiE 'the text that follows' <<<"$tail_of"
done
refute "the assembler takes no message and cannot embed one" \
    contains "$(run 'build_system_prompt --profile turn "a message he typed"')" \
             "a message he typed"

echo
echo "the shelves are titles, and the bodies stay on disk:"
TURN="$(run 'build_system_prompt --profile turn')"
check "a want title is in the prompt" contains "$TURN" "Learn to read a score"
refute "a want body is not" contains "$TURN" "WANT_BODY_MARKER"
check "the binding test is verbatim" \
    contains "$TURN" "Everything below is owed, not chosen: it is here because it was asked for."
check "a conduct title is in the prompt" contains "$TURN" "Exactly TWO things I ask about"
refute "a conduct body is not" contains "$TURN" "CONDUCT_BODY_MARKER"

echo
echo "the flag sets are built as one lever, never half of one:"
for p in turn wake job classify; do
    flags="$(run "claude_profile_flags $p; printf '%s ' \"\${CLAUDE_PROFILE_FLAGS[@]}\"")"
    case "$flags" in
        *--tools*)
            check "$p: --tools is never emitted without --strict-mcp-config" \
                contains "$flags" "--strict-mcp-config" ;;
        *) ok "$p: no --tools to pair" ;;
    esac
    refute "$p: --bare is never emitted — it refuses OAuth" \
        contains "$flags" "--bare"
done
check "a classifier is given no tools at all" \
    contains "$(run "claude_profile_flags classify; printf '[%s]' \"\${CLAUDE_PROFILE_FLAGS[@]}\"")" \
             "[--tools][]"
