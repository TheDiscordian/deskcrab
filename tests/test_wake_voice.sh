#!/bin/bash
# The register a wake is asked in. Run: bash tests/test_wake_voice.sh
#
# WHAT THIS IS FOR
#
# The wake agenda is the last text before she writes: the whole system prompt
# sits above it, and this is the sentence her first word answers. Until
# 2026-08-08 it was a work order — "Review your wants shelf… pick at most ONE
# want, and advance it… do not let this turn into a work or status session" —
# written in nobody's voice, and what came back was written in the same hand it
# was asked in: "Noted the two limits honestly. (quiet) Completed the review
# of…". Her conduct bans the word "honest" outright as a Claudism, and bans the
# status-report cadence; both were in her own night notes anyway, because the
# text nearest her generation modelled them.
#
# So the rewrite is hers. This file holds the two things that rewrite must never
# lose:
#
#   1. every OPERATIONAL rule the ticket carried — the silence contract, the
#      (quiet) marker, the filler sentences named one by one, the unattended
#      boundary, wake-at, the display channel, the journal. A rewording that
#      drops one of them is not a rewording, and the register is the only thing
#      that was allowed to move.
#   2. the register itself, in the only ways a shell can check it: the ticket's
#      own sentences do not come back, the agenda stays inside rule 12's
#      ceiling, and no text feeding her — the agenda, or any assembled prompt on
#      any profile — MODELS the word her conduct bans. Two lines may carry it
#      and neither models it: the conduct rule that names the ban, and a
#      transcript line, which is a quotation of something already said. The
#      sweep is proved to have teeth by planting the word and watching it come
#      back, because a sweep that has never failed is a sweep nobody has shown
#      reads anything.
#
# Asserted on what the CLI was actually HANDED, never on a grep of `crab`: a
# grep of the shipping file passes just as well when a sentence survives only in
# the comment beside the code that stopped emitting it.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

refute() { local desc="$1"; shift; if "$@"; then fail "$desc"; else ok "$desc"; fi; }
has() { grep -qiE -- "$2" <<<"$1"; }

D="$XDG_DATA_HOME/deskcrab"
mkdir -p "$D/conduct" "$D/wants" "$D/wakes"

cat > "$D/wants.md" <<'EOF'
# Wants

- 🎼 **Learn to read a score**
- 🌱 **Keep a window box**
EOF

# The conduct fixture carries the ban in the shape the live drawer writes it:
# the rule is a title, the word is named so the rule can be understood, and the
# body is one open away. This is the ONE line the sweep below is allowed to find.
cat > "$D/conduct/CONDUCT.md" <<'EOF'
# How I hold myself

> These bindings earn no pride when kept, only shame when broken.

- 🗣️ **Sound like myself** — never the word "honest"/"honesty" (a Claudism; say the thing plainly); no status-report cadence. → `sound-like-myself.md`
- 🎯 **Exactly TWO things I ask about** — the two, spelled out. → `two-things.md`
EOF
printf 'the body, which stays on disk\n' > "$D/conduct/sound-like-myself.md"
printf 'the body, which stays on disk\n' > "$D/conduct/two-things.md"

cat > "$SANDBOX/persona.md" <<'EOF'
## Who you are

Old, proud, fond of your own library, and brief. There is no register in which
you stop being yourself.
EOF

write_conf() {  # <quiet hours>
    cat > "$DESKCRAB_CONF" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$SANDBOX/home"
CUSTOM_PROMPT="$SANDBOX/persona.md"
WANTS_FILE="$D/wants.md"
WAKE_QUIET_HOURS="${1:-}"
EOF
}
write_conf ""

# The agenda is the CLI's last argument — the positional prompt — so the stub
# writes that argument, whole and alone. The shared claude log records argv as
# one flattened string, which would put the entire system prompt in front of
# every assertion below and make "the agenda contains X" mean "the prompt does".
sandbox_stub claude <<'STUB'
#!/bin/bash
printf '%s' "${@: -1}" > "$SANDBOX_AGENDA_FILE"
printf '%s\n' "$*" >> "${SANDBOX_CLAUDE_LOG:-/dev/null}"
case "$*" in
    *--output-format*)
        cat > /dev/null
        printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"stub reply."}]}}'
        printf '%s\n' '{"type":"result","result":"stub reply."}'
        ;;
    *) cat > /dev/null; printf 'stub reply.\n' ;;
esac
exit 0
STUB
export SANDBOX_AGENDA_FILE="$SANDBOX/witness/agenda.txt"

# What the CLI was handed for one wake. Truncated first, so what comes back
# belongs to this wake and no other.
agenda() {  # <kind> <reason>
    : > "$SANDBOX_AGENDA_FILE"
    WAKES_DIR="$D/wakes" "$SANDBOX_REPO/crab" wake "$1" "$2" >/dev/null 2>&1 || true
    cat "$SANDBOX_AGENDA_FILE" 2>/dev/null
}

A="$(agenda scheduled "")"
[ -n "$A" ] || die "the wake never reached the CLI, so there is no agenda to judge"

echo "every rule the ticket carried is still in the agenda she is handed:"

check "silence is asked for in words — no message text at all" \
    has "$A" 'ZERO message text'
for filler in "Nothing to say." "No message." "Nothing to report." \
              "Nothing new." "No update." "Staying quiet."; do
    check "the filler sentence is named: $filler" \
        grep -qF -- "$filler" <<<"$A"
done
check "and naming them is a prohibition, not a preference" has "$A" 'FORBIDDEN'
check "the reason is given: they are read out into the room" \
    has "$A" 'read out into his room|spoken aloud'
check "the one authorized silent form is the (quiet) marker with a thought behind it" \
    grep -qF -- '(quiet)' <<<"$A"
check "a bare marker is refused" has "$A" "bare '\(quiet\)'"
check "everything written as message text is said out loud" has "$A" 'SPOKEN ALOUD'
check "the display channel is still offered" has "$A" 'display section'
check "one want, not the whole shelf" has "$A" 'take one|pick one|one want'
check "the want's own document is where dated progress goes" \
    has "$A" 'wants/<slug>\.md'
check "and a dated thought has somewhere to go when nothing moves" \
    has "$A" 'moments/'
check "leaving nothing behind is the outcome to avoid" \
    has "$A" 'leaving not one line|leaving nothing'
check "work bigger than one sitting books its own next sitting" \
    has "$A" 'crab wake-at'
check "the stall reaper's terms are stated" has "$A" 'no output AND no CPU'
check "and long idle work is told where to run" has "$A" 'background'
check "nothing leaves the machine while she is unattended" \
    has "$A" 'no messages, no mail, no pushes|nothing leaves'
check "and nothing is deleted" has "$A" 'delete nothing'
check "the journal is written from her tools, so it needs no narrating" \
    has "$A" 'journaled'

echo
echo "and it is written in her voice, not a work order's:"

# The ticket's own sentences. Their return is the reversion this file exists to
# catch, so they are named rather than described.
for ticket in "Review your wants shelf" "pick at most ONE want" \
              "do not let this turn into a work or status session" \
              "wrap up deliberately" "prefer background execution"; do
    refute "the work order's sentence is gone: $ticket" \
        grep -qiF -- "$ticket" <<<"$A"
done
refute "the agenda does not model the word her conduct bans" \
    has "$A" '\bhonest(ly|y)?\b'
check "it addresses her, in the second person" has "$A" '\byour own\b|\byou\b'
# specs/prompt-assembly.md §11: the wake agenda is the wake profile's user
# message and it is budgeted like any other layer.
BYTES="$(printf '%s' "$A" | wc -c)"
printf '  note  the agenda is %s bytes (ceiling 3,600)\n' "$BYTES"
check "it is inside the agenda's own ceiling" [ "$BYTES" -le 3600 ]

echo
echo "the agenda notes carry their own subject, in the same voice:"

REASON="finish the arrangement for the second movement"
A="$(agenda scheduled "$REASON")"
check "an appointment she booked arrives holding what she booked it for" \
    grep -qF -- "$REASON" <<<"$A"
check "and it is named as this session's agenda" \
    grep -qF -- "That is this session's agenda" <<<"$A"
check "with the shelf offered only as the fallback" has "$A" 'shelf'
check "in her register — her own appointment, hers to keep" \
    has "$A" 'your own appointment'

A="$(agenda event "$REASON")"
check "an event wake carries what happened" grep -qF -- "$REASON" <<<"$A"
check "and it too is this session's agenda" \
    grep -qF -- "That is this session's agenda" <<<"$A"
check "which comes before the shelf" has "$A" 'before the shelf'

A="$(agenda scheduled "")"
refute "a reasonless wake invents no agenda" \
    grep -qF -- "That is this session's agenda" <<<"$A"
check "and it still knows where it came from" \
    has "$A" 'from a wake you scheduled yourself'

write_conf "$(date +%-H)-$(( ($(date +%-H) + 2) % 24 ))"
A="$(agenda scheduled "")"
check "a night wake is told what the quiet hours will do to it" \
    grep -qF -- "speaking and windows are suppressed" <<<"$A"
check "and that the words it writes are kept rather than said" \
    has "$A" 'held and kept in the journal'
write_conf ""

echo
echo "no assembled prompt models the banned word at her:"

run() { sandbox_bash "source '$SANDBOX_REPO/lib/common.sh' >/dev/null 2>&1; $1"; }

# Two lines are allowed to carry the word and neither of them models it at her:
# the conduct rule that names the ban (the drawer speaking about its own rule),
# and a transcript line, which is a quotation of something already said. Every
# other line is the prompt teaching her the word.
sweep() {  # <profile> -> the lines that model it
    run "build_system_prompt --profile $1" \
        | grep -iE '\bhonest(ly|y)?\b' \
        | while IFS= read -r line; do
              grep -qF -- "$line" "$D/conduct/CONDUCT.md" 2>/dev/null && continue
              grep -qF -- "$line" "$DESKCRAB_STATE_PREFIX-convo.txt" 2>/dev/null && continue
              printf '%s\n' "$line"
          done
}

check "conduct did reach the prompt, so the sweep is reading a full one" \
    grep -qF -- 'Sound like myself' <<<"$(run 'build_system_prompt --profile turn')"

for p in turn wake job classify; do
    check_eq "$p: nothing in the assembled prompt models the word at her" \
        "$(sweep "$p")" ""
done

# And the sweep has teeth: plant the word where a prompt layer would carry it
# and it has to come back. A sweep that has never once failed is a sweep nobody
# has proved reads anything.
cp "$SANDBOX/persona.md" "$SANDBOX/persona.orig"
printf '\nBe honest with him about what you got through tonight.\n' >> "$SANDBOX/persona.md"
check "a planted instruction is caught" [ -n "$(sweep turn)" ]
mv "$SANDBOX/persona.orig" "$SANDBOX/persona.md"
check_eq "and the sweep is clean again once it is removed" "$(sweep turn)" ""
