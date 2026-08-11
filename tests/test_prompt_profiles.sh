#!/bin/bash
# The four profiles: which layers each one carries, in what order, at what
# measured size, against which budget. Run: bash tests/test_prompt_profiles.sh
#
# specs/prompt-assembly.md asks for exactly this file. The sixteen intent
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
ORDER="L1 L2 L3 L4 L5 L6 regroup dispute L7 L8"
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

# The profile TOTALS of specs/prompt-assembly.md §11. Nothing compared a
# profile's sum to the table until now: the per-layer loop above skips the two
# exempt layers, so a layer budget could be raised, or a tenth layer added,
# without any assertion noticing what it did to the whole prompt. Rule 4 says
# the total bounds the layers that can be trimmed — so an exempt layer's
# overrun is added to the allowance and everything else has to fit under it.
# A profile whose sum drifts fails here and the table is what it is measured
# against; if the assembler is right, the table moves, in the same commit.
# These are the TABLE's totals, verbatim — §11 says the two state the same
# numbers on purpose. Until 2026-08-09 this function held numbers 400 under
# the table: the 2026-08-08 L4 raise moved the spec alone, which is exactly
# the drift the paragraph above forbids.
total_budget() { case "$1" in turn) echo 33900 ;; wake) echo 26500 ;;
                              job) echo 2000 ;; classify) echo 200 ;; esac; }
for p in turn wake job classify; do
    man="$(run "build_system_prompt --profile $p --layers")"
    bytes="$(run "build_system_prompt --profile $p" | wc -c)"
    slack="$(printf '%s\n' "$man" \
             | awk -F'\t' '($1 == "L2" || $1 == "L5") && $2 > $3 { n += $2 - $3 }
                           END { print n + 0 }')"
    allowed=$(( $(total_budget "$p") + slack ))
    check "$p: the assembled prompt is inside the table's total ($bytes of $allowed)" \
        [ "$bytes" -le "$allowed" ]
done

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

echo
echo "the wake's user message is the wake's agenda:"

# Rule 12. The agenda reaches the model as the USER message and nowhere else,
# so this reads what the CLI was actually handed rather than what the shell
# assembled — the stub records its whole argv, and the message is the
# positional prompt. The defect this covers: `crab wake` injected the reason
# only when the kind was `event`, so a scheduled appointment booked WITH a
# reason ("crab wake-at 09:30 'finish the arrangement'") woke her on generic
# wants boilerplate, under a frame telling her the agenda was below it. The
# reason survived the queue, the record and the normaliser, and was then shown
# to nobody.
mkdir -p "$XDG_DATA_HOME/deskcrab/wakes"
# The stub records its whole argv, prompt and all, and the argv spans lines —
# so this reads the file rather than a line of it. Truncated first, so what
# comes back belongs to this wake and no other.
wake_msg() {  # <kind> <reason> — everything crab handed the CLI
    : > "$SANDBOX_CLAUDE_LOG"
    WAKES_DIR="$XDG_DATA_HOME/deskcrab/wakes" \
        "$SANDBOX_REPO/crab" wake "$1" "$2" >/dev/null 2>&1 || true
    cat "$SANDBOX_CLAUDE_LOG" 2>/dev/null
}

AGENDA="finish the arrangement for the second movement"
MSG="$(wake_msg scheduled "$AGENDA")"
check "a scheduled wake booked with a reason carries it" contains "$MSG" "$AGENDA"
check "and names it as this session's agenda" \
    contains "$MSG" "That is this session's agenda"

MSG="$(wake_msg event "$AGENDA")"
check "an event wake still carries its reason" contains "$MSG" "$AGENDA"

# The timer's own wake has no agenda and must not invent one.
MSG="$(wake_msg scheduled "")"
refute "a reasonless wake says nothing about an agenda it does not have" \
    contains "$MSG" "That is this session's agenda"
check "and it still knows where it came from" \
    contains "$MSG" "from a wake you scheduled yourself"

echo
echo "nothing is ever cut, and over budget is said out loud (rules 4 and 36):"
# The 2026-08-09 mechanism — a conf override pins L1 under the sheet — must
# now cost NOTHING: the sheet rides whole, the manifest says `over`, and no
# warning fires while the total still fits. 5,000 is well under the
# ~3,400-byte identity header plus the fixture's 40-section sheet.
BODY="$(run 'PROMPT_BUDGET_L1_TURN=5000 build_system_prompt --profile turn')"
check "a layer past its budget still carries its whole content" \
    contains "$BODY" "## Section 40"
refute "and no trim marker appears anywhere in the body" \
    contains "$BODY" "[trimmed to fit"
state="$(run 'PROMPT_BUDGET_L1_TURN=5000 build_system_prompt --profile turn --layers' \
         | awk -F'\t' '$1 == "L1" { print $4 }')"
check_eq "the manifest calls it over — never trimmed, never cut" "$state" "over"
check "a layer over its budget alone leaves no standing record while the total fits" \
    [ ! -s "$DESKCRAB_STATE_PREFIX-prompt-cuts.txt" ]
man="$(run 'PROMPT_BUDGET_L1_TURN=5000 build_system_prompt --profile turn --layers')"
refute "no manifest state anywhere reads trimmed or cut" \
    grep -qE '	(trimmed|cut)$' <<<"$man"

# The TOTAL running past the profile's target is the warned condition: the
# prompt itself opens with the fact, the record stands for the outside, and
# still nothing is cut.
SQUEEZE='PROMPT_BUDGET_L1_TURN=500 PROMPT_BUDGET_L2_TURN=100 PROMPT_BUDGET_L4_TURN=100 PROMPT_BUDGET_L5_TURN=100 PROMPT_BUDGET_L6_TURN=1000 PROMPT_BUDGET_L7_TURN=100 PROMPT_BUDGET_L8_TURN=100'
BODY="$(run "$SQUEEZE build_system_prompt --profile turn")"
check "an over-budget total is announced inside the prompt" \
    contains "$BODY" "PROMPT OVER BUDGET"
check "the warning says nothing was cut" \
    contains "$BODY" "Nothing was cut"
check "and names the largest layers" \
    contains "$BODY" "The largest layers:"
check "the whole persona sheet is still in the over-budget prompt" \
    contains "$BODY" "## Section 40"
check "the over-budget build left the standing record" \
    [ -s "$DESKCRAB_STATE_PREFIX-prompt-cuts.txt" ]
check "which carries the measured total" \
    contains "$(cat "$DESKCRAB_STATE_PREFIX-prompt-cuts.txt" 2>/dev/null || true)" \
             "total="
check "the next build's state block renders the record" \
    contains "$(run "$SQUEEZE build_system_prompt --profile turn")" \
             "PROMPT OVER BUDGET — the last assembled prompt"
# The overrides removed — the code defaults again — the build fits, and the
# record goes with it.
run 'build_system_prompt --profile turn' >/dev/null
check "a build inside the target removes the record" \
    [ ! -s "$DESKCRAB_STATE_PREFIX-prompt-cuts.txt" ]
refute "and the prompt after it carries no warning" \
    contains "$(run 'build_system_prompt --profile turn')" "PROMPT OVER BUDGET"
