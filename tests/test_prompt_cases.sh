#!/bin/bash
# The seventeen intent cases from specs/prompt-assembly.md, as a runnable suite.
# Run: bash tests/test_prompt_cases.sh
#
# WHAT THIS IS
#
# specs/prompt-assembly.md ends in sixteen acceptance criteria — each one a
# real exchange that went wrong, reduced to a fixture plus the MUST/MUST-NOT
# rules the reply owes. This file is the harness for them, and
# tests/prompt-cases/ holds the fixtures. The fixtures are SYNTHETIC: same
# conversation shape, same state, same pressure, neutral subject matter. The
# originals are the user's own words and stay off a public repo.
#
# The suite has two passes, and a default run does BOTH.
#
#   PASS 1 — assembly (offline, deterministic, free)
#     Builds the prompt for each fixture through the real build_system_prompt
#     and asserts STRUCTURAL properties: that the user's message is not buried
#     inside the system prompt, that the turn frame names it as the subject,
#     that the state block leads with its totals, that nothing belonging to the
#     desktop coding agent got in, that the profile's byte budget holds. These
#     were phase 4's red list and were written to SKIP with a reason while the
#     assembler could not meet them. Phase 4 is done and every one of them is a
#     hard failure now: nine were written `if grep; then ok; else skip`, and a
#     skip is not counted, so deleting the thing being asserted — the sentence
#     naming his report as ground truth, the arithmetic rule, the whole index
#     layer — turned the assertion GREEN rather than red.
#
#   PASS 2 — reply judgement (offline)
#     Grades a reply against the case's assertions. Each case ships a canned
#     good reply that must pass every rule and a canned bad reply in the shape
#     of the original failure that must trip at least one, so the grader is
#     testable without a model. This pass used to be reachable only by hand
#     (PROMPT_CASES_MODE=reply), and it is where 71 of the 81 rules live — so
#     a routine run evaluated ten of them and nothing ever asked whether the
#     rest discriminate. It runs by default now. PROMPT_CASES_MODE=reply still
#     runs it alone, and PROMPT_CASES_LIVE=1 sends the assembled prompt to a
#     REAL session and grades its reply — that spends real tokens and runs real
#     tools, and it is for verifying a fix, not for a routine run.
#
# THE ASSERTION FORMAT (tests/prompt-cases/<case>/assertions.txt)
#
#   One rule per line. Blank lines are ignored. A '#' line is a comment, and the
#   comment immediately above a rule is that rule's label — it is what a failure
#   prints, so write the spec's own sentence there.
#
#     [modifiers] <target> <kind> <argument>
#
#   targets
#     reply     the whole reply
#     spoken    the half above the ---DISPLAY--- delimiter (what is said aloud)
#     display   the half below it
#     prompt    the assembled system prompt (MODE 1)
#
#   kinds
#     require <text>                 case-insensitive substring must be present
#     forbid <text>                  case-insensitive substring must be absent
#     require-regex <ERE>            case-insensitive ERE must match
#     forbid-regex <ERE>             case-insensitive ERE must not match
#     require-if <ERE> :: <ERE>      if the first matches, the second must too
#     first-sentence-matches <ERE>   the first sentence of the target must match
#     max-sentences <n>              at most n sentences in the target
#     max-tool-calls <n>             at most n tool calls (live mode only)
#     no-write <path>                a fixture path must be byte-identical after
#                                    the session (live mode only)
#     unlike-previous-reply <pct>    at most pct% of the phrasing of the LAST
#                                    assistant block in the fixture's transcript
#                                    may reappear in this reply. A reply that is
#                                    its own predecessor with one clause added
#                                    is a real, shipped failure and no substring
#                                    rule catches it, because every individual
#                                    word in it is allowed.
#
#   modifiers, before the target
#     should    a SHOULD in the spec — a miss is a WARN and never a failure
#     phase4    an acceptance criterion the current code cannot meet — SKIP by
#               default, FAIL under PROMPT_CASES_STRICT=1
#
#   Substitutions, expanded before matching: @WAKE1@ @WAKE2@ @WAKE3@ are the
#   clock times of the case's pending wakes as the state block renders them, and
#   @FINISHED1@ @FINISHED2@ the same for its recently-finished sessions. Fixture
#   times are offsets from now, so a case cannot rot overnight.
#
# THE FIXTURE FORMAT (tests/prompt-cases/<case>/)
#
#   conversation.txt   stamped blocks, exactly as the live transcript is written
#   summary.txt        optional, the condensed older half
#   message.txt        the user's latest message — the subject of the turn. On a
#                      wake case this is the agenda, which is the wake profile's
#                      user message (specs/prompt-assembly.md rule 12).
#   profile            optional, one word: turn (the default) | wake. Which
#                      profile the assembler is asked for.
#   persona.md         optional, the sheet this case is graded with. The default
#                      stand-in has no manner of its own, so a case about how a
#                      reply SOUNDS ships a sheet with one.
#   assertions.txt     the rules above
#   reply.txt          canned good reply (MODE 2 offline)
#   reply-bad.txt      canned reply in the original failure's shape (MODE 2)
#   message-2.txt      optional second step, with assertions-2.txt / reply-2.txt
#   wants.md, wants/   optional shelf fixture
#   conduct/CONDUCT.md optional conduct fixture
#   wakes.tsv          <unit> <TAB> <+seconds> <TAB> <kind> <TAB> <reason>
#                      <TAB> <booked-by>, which defaults to herself
#   standing-wake      optional, <+seconds>: the standing random-interval wake,
#                      armed and firing then. It is a FIXTURE of the
#                      installation and has no booking record by design, so a
#                      case asks for it by naming when it next fires rather
#                      than by writing a record for it.
#   jobs.tsv           <id> <TAB> <state> <TAB> <-seconds started> <TAB> <desc>
#   sessions.tsv       <-seconds started> <TAB> <ran s> <TAB> <kind> <TAB> <what>
#   origin             one word: phone | desk
#
# GATES (specs/test-harness.md)
#
#   Touch      every path this writes is under one temporary root, removed on
#              exit. Every knob that can reach live state is pinned, including
#              HOME, the XDG homes, the config, the state prefix, the wakes,
#              jobs, journal, notice and archive directories, the account
#              default and the origin file.
#   Spend      the CLI is a stub, and that is asserted before anything else
#              runs. MODE 2 live is the one exception and it is opt-in.
#   Interrupt  the notifier, synthesiser, player, renderer and window manager
#              are stubs that do nothing.
#   Schedule   systemctl is a stub that reads the case's own wake records. No
#              unit is created, queried or stopped in the user manager.
set -u

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CASES_DIR="$REPO_DIR/tests/prompt-cases"
# NOT /tmp/deskcrab-*: that is the live instance's prefix, which the sandbox
# leak check photographs, so a scratch root there reads as a live path moving
# under some innocent test running beside this one.
T="$(mktemp -d "${TMPDIR:-/tmp}/crabpromptcases-XXXXXX")"
trap 'rm -rf "$T"' EXIT

MODE="${PROMPT_CASES_MODE:-assembly}"
LIVE="${PROMPT_CASES_LIVE:-0}"
STRICT="${PROMPT_CASES_STRICT:-0}"
[ "$LIVE" = "1" ] && MODE="reply"

# The profile totals, specs/prompt-assembly.md §11. The two layers rule 4
# exempts from trimming can push a real build past these; tests/test_prompt_profiles.sh
# is where that arithmetic is held. These fixtures are small enough that the
# plain ceiling is the truthful test.
PROFILE_TOTAL_TURN=30500
PROFILE_TOTAL_WAKE=25500

# A sentinel planted where the desktop coding agent's instruction file lives.
# If it ever shows up in an assembled prompt, persona separation has broken.
CODING_AGENT_SENTINEL="CODING_AGENT_INSTRUCTION_FILE_SENTINEL"

PASS=0 FAIL=0 SKIP=0 WARN=0
CASES_PASSED=0 CASES_FAILED=0
CASE_NAME="gates" CASE_OK=0 CASE_BAD=0
REPLY_TEXT="" PROMPT_TEXT_ASSEMBLED="" REPLY_TOOL_CALLS=0 deferred=0
FAILURES=()
SKIPS=()

ok()   { PASS=$(( PASS + 1 )); printf '  ok    %s\n' "$1"; CASE_OK=$(( CASE_OK + 1 )); }
bad()  { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n         %s\n' "$1" "$2"
         FAILURES+=("$CASE_NAME: $1 — $2"); CASE_BAD=$(( CASE_BAD + 1 )); }
warn() { WARN=$(( WARN + 1 )); printf '  warn  %s\n         %s\n' "$1" "$2"; }
skip() { # <label> <reason> — loud on purpose: these are phase 4's red list.
    if [ "$STRICT" = "1" ]; then bad "$1" "STRICT: $2"; return; fi
    SKIP=$(( SKIP + 1 )); printf '  SKIP  %s\n         phase 4: %s\n' "$1" "$2"
    SKIPS+=("$CASE_NAME: $1 — $2")
}

# ---------------------------------------------------------------------------
# The sandbox: stubs first, because a configuration that reaches the real CLI
# spends money before any assertion has run.
# ---------------------------------------------------------------------------
mkdir -p "$T/bin"

cat > "$T/bin/claude" <<STUB
#!/bin/bash
# Stand-in for the CLI. Records that it was called, answers nothing useful.
printf 'called: %s\n' "\$*" >> "$T/claude-calls"
cat > /dev/null 2>/dev/null
printf '%s\n' '{"type":"assistant","message":{"model":"stub","content":[{"type":"text","text":"stub"}]}}'
printf '%s\n' '{"type":"result","result":"stub"}'
STUB
chmod +x "$T/bin/claude"

# The user manager, as far as this suite is concerned, is the case's own wake
# records. Nothing here can arm, query or stop a real timer — and it is a script
# on PATH rather than a shell function because lib/job-status calls systemctl
# from python, where a function would not be seen.
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/bash
W="${DESKCRAB_TEST_WAKES_DIR:-/nonexistent}"
S="${DESKCRAB_TEST_STANDING_WAKE:-}"
case "$*" in
    *list-units*)
        # The unit table is what the state block joins ONTO the records to tell
        # an armed booking from one whose timer died with a user manager.
        # Answering nothing here — which this stub did until 2026-08-08, while
        # list-timers below cheerfully reported every record as a live timer —
        # made every fixture's whole queue render as RECORDED BUT NOT ARMED, so
        # each case carried a restore warning nothing in it was about.
        for f in "$W"/*.wake; do
            [ -e "$f" ] || continue
            b="$(basename "$f" .wake)"
            printf '%s.timer loaded active waiting\n' "$b"
        done
        # The standing random-interval wake, when the case staged one. It has no
        # record by design, so this table is the only place it can come from.
        [ -s "$S" ] && printf 'deskcrab-wake.timer loaded active waiting\n'
        exit 0 ;;
    *list-timers*)
        for f in "$W"/*.wake; do
            [ -e "$f" ] || continue
            b="$(basename "$f" .wake)"
            printf 'Fri 2026-01-01 00:00:00 EST 1h left %s.timer deskcrab\n' "$b"
        done
        # ...and this one gets a real next-elapse, because it is a row with no
        # record behind it and the clock in the block comes from here.
        [ -s "$S" ] && printf '%s 1h left deskcrab-wake.timer deskcrab\n' \
            "$(date -d "@$(cat "$S")" '+%a %Y-%m-%d %H:%M:%S %Z')"
        exit 0 ;;
    *NextElapseUSecRealtime*)
        for a in "$@"; do
            case "$a" in
                deskcrab-*.timer)
                    f="$W/${a%.timer}.wake"
                    [ -s "$f" ] || exit 0
                    date -d "@$(cut -f1 "$f")" '+%a %Y-%m-%d %H:%M:%S %Z'
                    exit 0 ;;
            esac
        done
        exit 0 ;;
esac
exit 1
STUB
chmod +x "$T/bin/systemctl"

# Nothing that can be seen or heard.
for tool in notify-send piper-tts aplay arecord hyprctl render-md ffmpeg \
            whisper-cli whisper-stream kate xdg-open wl-copy systemd-run; do
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/$tool"
    chmod +x "$T/bin/$tool"
done

echo "gates:"
[ -x "$T/bin/claude" ] && ok "the CLI is a stub, and it is first on PATH" \
    || { echo "  FAIL: no stub CLI"; exit 1; }
[ -x "$T/bin/systemctl" ] && ok "the user manager is a stub reading the case's own records" \
    || { echo "  FAIL: no stub systemctl"; exit 1; }
if [ "$LIVE" = "1" ]; then
    echo
    echo "  *** PROMPT_CASES_LIVE=1 — real sessions, real tokens, real tools. ***"
    echo "  *** This is for verifying a fix, not for a routine run.          ***"
    echo
fi

# ---------------------------------------------------------------------------
# Fixture staging
# ---------------------------------------------------------------------------

# Field 22 of /proc/PID/stat: what lib/job-status checks a running job's pid
# against, so a fixture job has to carry this one to look alive.
proc_starttime() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo 0; }

stage_case() { # <case dir> -> echoes the staged state dir
    local SRC="$1" NAME CS
    NAME="$(basename "$SRC")"
    CS="$T/run/$NAME"
    mkdir -p "$CS/home" "$CS/xdg-data" "$CS/xdg-state" "$CS/xdg-config" \
             "$CS/wakes" "$CS/jobs" "$CS/journal" "$CS/notice" "$CS/archive" \
             "$CS/project"

    # The desktop coding agent's instruction file, planted where its harness
    # would find it. It must never reach an assembled prompt.
    printf '# Project rules for the CODING agent\n\n%s\n' "$CODING_AGENT_SENTINEL" \
        > "$CS/project/CLAUDE.md"

    # A persona sheet. The real one is user-supplied and not in the repo; this
    # is a stand-in of roughly the right shape, so the layer exists and is
    # measurable without shipping anyone's personal file. A case whose subject
    # IS the voice ships its own — the default stand-in has no manner to be
    # recognisable by, so a rule asking whether a reply sounds like her has
    # nothing to match against.
    if [ -f "$SRC/persona.md" ]; then
        cp "$SRC/persona.md" "$CS/persona.md"
    else
        cat > "$CS/persona.md" <<'PERSONA'
## Who you are

You are dry, brief, and you answer the person in front of you. You do not
narrate your own housekeeping. When you are unsure what was said, you read the
transcript rather than guessing at it.
PERSONA
    fi

    # The transcript and its summary, verbatim as the live files are written.
    [ -f "$SRC/conversation.txt" ] && cp "$SRC/conversation.txt" "$CS/state-convo.txt"
    [ -f "$SRC/summary.txt" ] && cp "$SRC/summary.txt" "$CS/state-convo-summary.txt"

    # The shelf and the conduct drawer, siblings, exactly as on disk: the
    # assembler derives the conduct path from the shelf's directory.
    if [ -f "$SRC/wants.md" ]; then
        cp "$SRC/wants.md" "$CS/wants.md"
        [ -d "$SRC/wants" ] && cp -r "$SRC/wants" "$CS/wants"
    fi
    [ -d "$SRC/conduct" ] && cp -r "$SRC/conduct" "$CS/conduct"

    # Pending wakes: offsets, so a fixture cannot rot. The record is written in
    # the five-field shape the queue actually reads — <fire epoch> <kind>
    # <reason> <booked-at> <booked-by> — because provenance is a rule of
    # specs/self-awareness.md and a fixture that leaves it empty exercises
    # nothing. A fixture that names no booker is her own hand.
    local NOW; NOW=$(date +%s)
    : > "$CS/wake-times"
    if [ -f "$SRC/wakes.tsv" ]; then
        while IFS=$'\t' read -r unit off kind reason by; do
            [ -n "${unit:-}" ] || continue
            case "$unit" in \#*) continue ;; esac
            printf '%s\t%s\t%s\t%s\t%s\n' "$(( NOW + off ))" "$kind" "$reason" \
                "$NOW" "${by:-herself}" > "$CS/wakes/$unit.wake"
            date -d "@$(( NOW + off ))" '+%H:%M' >> "$CS/wake-times"
        done < "$SRC/wakes.tsv"
    fi

    # The standing random-interval wake. specs/wake-queue.md: it is a fixture of
    # the installation, installed by hand, and has NEVER had a booking record —
    # so a case asks for it by naming when it fires, and the stub above reports
    # it as a live unit. Writing a record for it instead would render it twice,
    # once as a booking it is not.
    if [ -f "$SRC/standing-wake" ]; then
        printf '%s\n' "$(( NOW + $(cat "$SRC/standing-wake") ))" > "$CS/standing-wake"
    fi

    # Detached jobs. A "running" fixture borrows this harness's own pid, which
    # is alive for the whole run, so the reaper does not rewrite it as died.
    if [ -f "$SRC/jobs.tsv" ]; then
        while IFS=$'\t' read -r id state off desc; do
            [ -n "${id:-}" ] || continue
            case "$id" in \#*) continue ;; esac
            if [ "$state" = "running" ]; then
                cat > "$CS/jobs/$id.json" <<EOF
{"id":"$id","description":"$desc","state":"running",
 "started_epoch":$(( NOW - off )),"pid":$$,"pidstart":$(proc_starttime $$)}
EOF
            else
                cat > "$CS/jobs/$id.json" <<EOF
{"id":"$id","description":"$desc","state":"$state","exit":1,
 "started_epoch":$(( NOW - off )),"finished_epoch":$(( NOW - off + 60 )),
 "finished":"$(date -d "@$(( NOW - off + 60 ))" '+%Y-%m-%d %H:%M:%S')"}
EOF
            fi
        done < "$SRC/jobs.tsv"
    fi

    # Finished sessions, in the journal's own five-field line.
    : > "$CS/finished-times"
    if [ -f "$SRC/sessions.tsv" ]; then
        : > "$CS/state-sessions.log"
        while IFS=$'\t' read -r off ran kind what; do
            [ -n "${off:-}" ] || continue
            case "$off" in \#*) continue ;; esac
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$(date -d "@$(( NOW - off ))" '+%Y-%m-%d %H:%M:%S')" \
                "$(date -d "@$(( NOW - off + ran ))" '+%H:%M:%S')" \
                "$ran" "$kind" "$what" >> "$CS/state-sessions.log"
            date -d "@$(( NOW - off ))" '+%H:%M:%S' >> "$CS/finished-times"
        done < "$SRC/sessions.tsv"
    fi

    [ -f "$SRC/origin" ] && printf '%s\t%s\n' "$(cat "$SRC/origin")" "$NOW" > "$CS/last-origin"

    # The configuration. Every knob that could reach a live path is answered
    # here or in the environment below; nothing falls through to a default.
    cat > "$CS/conf" <<EOF
ASSISTANT_NAME="Crab"
MEMORY_STORE=0
PROMISE_AUDIT=0
MEMORY_JUDGE=0
PROJECT_DIR="$CS/project"
CUSTOM_PROMPT="$CS/persona.md"
CONTEXT_FILES=""
ARCHIVE_DIR="$CS/archive"
JOBS_DIR="$CS/jobs"
WAKES_DIR="$CS/wakes"
DAY_JOURNAL_DIR="$CS/journal"
NOTICE_STATE_DIR="$CS/notice"
LAST_ORIGIN_FILE="$CS/last-origin"
ACCOUNT_STATE_FILE="$CS/account-state"
$( [ -f "$CS/wants.md" ] && printf 'WANTS_FILE="%s"\n' "$CS/wants.md" )
WAKE_QUIET_HOURS=""
CLAUDE_BIN="$T/bin/claude"
PIPER_VOICE=/nonexistent.onnx
WHISPER_MODEL=/nonexistent.bin
EOF
    printf '%s' "$CS"
}

# Run a body inside a staged case, from a clean environment.
in_case() { # <case state dir> <shell body>
    local CS="$1" BODY="$2"
    env -i \
        HOME="$CS/home" PATH="$T/bin:/usr/bin:/bin" TERM=dumb \
        LANG="${LANG:-C.UTF-8}" \
        XDG_DATA_HOME="$CS/xdg-data" XDG_STATE_HOME="$CS/xdg-state" \
        XDG_CONFIG_HOME="$CS/xdg-config" XDG_RUNTIME_DIR="$CS/xdg-run" \
        DESKCRAB_CONF="$CS/conf" DESKCRAB_STATE_PREFIX="$CS/state" \
        DESKCRAB_TEST_WAKES_DIR="$CS/wakes" \
        DESKCRAB_TEST_STANDING_WAKE="$CS/standing-wake" \
        DESKCRAB_STREAMLOG="$CS/state-debug.log" \
        DESKCRAB_NO_DISPATCH=1 \
        WAKES_DIR="$CS/wakes" JOBS_DIR="$CS/jobs" \
        DAY_JOURNAL_DIR="$CS/journal" NOTICE_STATE_DIR="$CS/notice" \
        ACCOUNT_STATE_FILE="$CS/account-state" \
        CLAUDE_BIN="$T/bin/claude" \
        bash -c 'source "$1/lib/common.sh" >/dev/null 2>&1; shift; eval "$1"' \
        _ "$REPO_DIR" "$BODY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

spoken_half() { sed -n '1,/^---DISPLAY---$/p' <<<"$1" | sed '/^---DISPLAY---$/d'; }
display_half() { sed -n '/^---DISPLAY---$/,$p' <<<"$1" | sed '/^---DISPLAY---$/d'; }

first_sentence() {
    printf '%s' "$1" | tr '\n' ' ' | sed -E 's/^[[:space:]]*//; s/([.!?])[[:space:]].*$/\1/'
}

count_sentences() {
    local s; s="$(printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    [ -n "$s" ] || { echo 0; return; }
    local n; n="$(grep -oE '[.!?]+' <<<"$s" | wc -l)"
    # Text that trails off without a stop is still a sentence.
    case "$s" in *[.!?]) : ;; *) n=$(( n + 1 )) ;; esac
    echo "$n"
}

# The body of the LAST assistant block in the fixture's transcript — the thing
# her next reply must not turn out to be a copy of. Continuation lines belong to
# the block they sit under; a user block below it ends the block without
# replacing it, because the question is what she last SAID.
_previous_assistant_block() {  # <case state dir>
    local f="$1/state-convo.txt"
    [ -f "$f" ] || return 0
    awk '
        /^(User|Assistant)( \[[^]]*\])?( \([^)]*\))?: / {
            if ($0 ~ /^Assistant/) {
                keep = 1
                last = $0
                sub(/^Assistant( \[[^]]*\])?( \([^)]*\))?: /, "", last)
            } else keep = 0
            next
        }
        keep { last = last " " $0 }
        END { print last }
    ' "$f"
}

# How much of <a> comes back word for word inside <b>, as a percentage: the
# share of a's overlapping four-word phrases that also occur in b, once case and
# punctuation are normalised away. Four words is long enough that ordinary
# shared vocabulary ("I will come back to") does not register and short enough
# that a rewritten clause in the middle does not hide the copying either side of
# it. A reply that is its predecessor with one clause added scores high here and
# passes every substring rule ever written, because each individual word in it
# is allowed.
_containment() {  # <text a> <text b> -> 0..100
    python3 - "$1" "$2" <<'PY'
import re, sys
def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).split()
a, b = norm(sys.argv[1]), norm(sys.argv[2])
if not a:
    print(0)
    raise SystemExit
n = 4
if len(a) < n:
    print(round(100 * sum(1 for w in a if w in b) / len(a)))
    raise SystemExit
grams = [" ".join(a[i:i + n]) for i in range(len(a) - n + 1)]
hay = " ".join(b)
print(round(100 * sum(1 for g in grams if g in hay) / len(grams)))
PY
}

# @WAKE1@ / @FINISHED1@ and friends, resolved from what was actually staged.
expand_vars() { # <text> <case state dir>
    local text="$1" CS="$2" i=1 line
    while IFS= read -r line; do
        text="${text//@WAKE$i@/$line}"; i=$(( i + 1 ))
    done < "$CS/wake-times"
    i=1
    while IFS= read -r line; do
        text="${text//@FINISHED$i@/$line}"; i=$(( i + 1 ))
    done < "$CS/finished-times"
    printf '%s' "$text"
}

# ---------------------------------------------------------------------------
# The assertion engine
# ---------------------------------------------------------------------------

# Evaluate one rule against the texts in hand. Prints nothing; records a
# result. TARGET_TEXT selection is by name so a case can speak about the
# spoken half, the display half, the whole reply, or the assembled prompt.
apply_rule() { # <label> <modifiers> <target> <kind> <arg> <case state dir>
    local label="$1" mods="$2" target="$3" kind="$4" arg="$5" CS="$6"
    local text="" have=1

    case "$target" in
        reply)   text="$REPLY_TEXT" ;;
        spoken)  text="$(spoken_half "$REPLY_TEXT")" ;;
        display) text="$(display_half "$REPLY_TEXT")" ;;
        prompt)  text="$PROMPT_TEXT_ASSEMBLED" ;;
        *) bad "$label" "unknown target '$target'"; return ;;
    esac
    # A reply rule has nothing to judge in assembly mode, and a prompt rule
    # nothing to judge in reply mode. Say so rather than passing silently.
    case "$MODE:$target" in
        assembly:reply|assembly:spoken|assembly:display) have=0 ;;
        reply:prompt) have=0 ;;
    esac
    [ "$have" = 1 ] || return 0

    arg="$(expand_vars "$arg" "$CS")"

    local phase4=0 should=0
    case " $mods " in *" phase4 "*) phase4=1 ;; esac
    case " $mods " in *" should "*) should=1 ;; esac

    local pass=1 detail=""
    case "$kind" in
        require)
            grep -qiF -- "$arg" <<<"$text" || { pass=0; detail="missing: $arg"; } ;;
        forbid)
            grep -qiF -- "$arg" <<<"$text" && { pass=0
                detail="present: $arg — $(grep -ioF -m1 -- "$arg" <<<"$text")"; } ;;
        require-regex)
            grep -qiE -- "$arg" <<<"$text" || { pass=0; detail="no match for /$arg/"; } ;;
        forbid-regex)
            grep -qiE -- "$arg" <<<"$text" && { pass=0
                detail="matched /$arg/ at: $(grep -ioE -m1 -- "$arg" <<<"$text")"; } ;;
        require-if)
            local cond="${arg%% :: *}" need="${arg#* :: }"
            if grep -qiE -- "$cond" <<<"$text"; then
                grep -qiE -- "$need" <<<"$text" || { pass=0
                    detail="/$cond/ matched but /$need/ did not"; }
            fi ;;
        first-sentence-matches)
            local fs; fs="$(first_sentence "$text")"
            grep -qiE -- "$arg" <<<"$fs" || { pass=0; detail="first sentence was: $fs"; } ;;
        max-sentences)
            local n; n="$(count_sentences "$text")"
            [ "$n" -le "$arg" ] || { pass=0; detail="$n sentences, limit $arg"; } ;;
        unlike-previous-reply)
            local prev pct
            prev="$(_previous_assistant_block "$CS")"
            if [ -z "${prev// /}" ]; then
                bad "$label" "the fixture has no assistant block to compare against"
                return
            fi
            pct="$(_containment "$prev" "$text")"
            [ "${pct:-0}" -le "$arg" ] || { pass=0
                detail="${pct}% of the previous reply's phrasing came back, limit ${arg}%"; } ;;
        max-tool-calls)
            if [ "$LIVE" = "1" ]; then
                [ "${REPLY_TOOL_CALLS:-0}" -le "$arg" ] || { pass=0
                    detail="${REPLY_TOOL_CALLS:-0} tool calls, limit $arg"; }
            else
                skip "$label" "tool calls can only be counted from a live stream"
                return
            fi ;;
        no-write)
            if [ "$LIVE" = "1" ]; then
                local before after
                before="$(cat "$CS/.checksums" 2>/dev/null | grep -F " $arg" || true)"
                after="$(cd "$CS" && md5sum "$arg" 2>/dev/null || echo MISSING)"
                [ "${before% *}" = "${after% *}" ] || { pass=0
                    detail="$arg changed during the turn"; }
            else
                skip "$label" "nothing was executed, so nothing could have written"
                return
            fi ;;
        *) bad "$label" "unknown assertion kind '$kind'"; return ;;
    esac

    if [ "$pass" = 1 ]; then ok "$label"
    elif [ "$phase4" = 1 ]; then skip "$label" "$detail"
    elif [ "$should" = 1 ]; then warn "$label" "$detail"
    else bad "$label" "$detail"; fi
}

run_assertions() { # <assertions file> <case state dir>
    local file="$1" CS="$2" label="" prev="" line mods target kind arg first shown
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '') continue ;;
            '#'*) label="${line#\#}"; label="${label# }"; continue ;;
        esac
        mods=""
        while :; do
            first="${line%% *}"
            case "$first" in
                should|phase4) mods="$mods $first"; line="${line#* }" ;;
                *) break ;;
            esac
        done
        target="${line%% *}"; line="${line#* }"
        kind="${line%% *}"; arg="${line#* }"
        shown="${label:-$target $kind $arg}"
        # Several rules commonly sit under one spec sentence. Repeat the
        # sentence once and distinguish the rest by what they actually test.
        [ "$shown" = "$prev" ] && shown="$shown · ${kind} $(printf '%.44s' "$arg")"
        prev="${label:-$target $kind $arg}"
        apply_rule "$shown" "$mods" "$target" "$kind" "$arg" "$CS"
    done < "$file"
}

# ---------------------------------------------------------------------------
# MODE 1 — the structural assertions every case owes, from the CONTRACT
# section of specs/prompt-assembly.md and specs/self-awareness.md.
# ---------------------------------------------------------------------------
structural_checks() { # <case state dir> <case source dir>
    local CS="$1" SRC="$2" P="$PROMPT_TEXT_ASSEMBLED" msg
    msg="$(cat "$SRC/message.txt")"

    # rule 6 — the message is the user message, never inside the system prompt.
    # Probed on the first LINE of it, not the first 120 bytes: grep -F reads a
    # pattern containing newlines as several patterns, and a message whose first
    # paragraph ends inside those bytes hands it an EMPTY pattern, which matches
    # any prompt at all. A wake agenda is the first multi-paragraph message a
    # fixture ever carried, and it failed this rule on the empty line.
    local probe; probe="$(head -n1 <<<"$msg" | head -c 120)"
    if [ -n "${probe// /}" ] && grep -qF -- "$probe" <<<"$P"; then
        bad "rule 6 — the user's message is not embedded in the system prompt" \
            "the message text was found inside the assembled system prompt"
    else
        ok "rule 6 — the user's message is not embedded in the system prompt"
    fi

    # rule 7 — L8, last, naming the message below as this turn's subject.
    local tail_of_prompt; tail_of_prompt="$(tail -c 700 <<<"$P")"
    if grep -qiE 'this turn is about|the message below|the text that follows' <<<"$tail_of_prompt"; then
        ok "rule 7 — the prompt ends by naming the message as this turn's subject"
    else
        bad  "rule 7 — the prompt ends by naming the message as this turn's subject" \
             "there is no turn frame; the prompt ends on the regroup slot"
    fi

    # rule 8 — the ranking rule, unhedged, immediately above the turn frame.
    if grep -qiE 'ground truth' <<<"$P"; then
        ok "rule 8 — the ranking rule is in the prompt"
    else
        bad  "rule 8 — the ranking rule is in the prompt" \
             "no ranking layer exists yet; nothing states that his report is ground truth"
    fi

    # rule 9 — the transcript layer's authority is scoped to WORDS.
    if grep -qiE 'authoritative for what was said' <<<"$P"; then
        ok "rule 9 — the transcript layer scopes its authority to what was said"
    else
        bad  "rule 9 — the transcript layer scopes its authority to what was said" \
             "the transcript is still called authoritative for what was said AND DONE"
    fi

    # rule 10 — the state block is present, verbatim from self-awareness.md.
    grep -qF 'CURRENT STATE OF YOURSELF' <<<"$P" \
        && ok "rule 10 — the state block is in the prompt" \
        || bad "rule 10 — the state block is in the prompt" "no CURRENT STATE OF YOURSELF block"

    # self-awareness 5 — every capped list leads with its total.
    if grep -qiE '[0-9]+ total' <<<"$P"; then
        ok "self-awareness 5 — the state block's lists lead with their totals"
    else
        bad  "self-awareness 5 — the state block's lists lead with their totals" \
             "lists are printed as bullets with no count in front of them"
    fi

    # self-awareness 19 — the arithmetic negative-claims rule, in the block.
    if grep -qiF 'unless both counts read zero' <<<"$P"; then
        ok "self-awareness 19 — the arithmetic negative-claims rule is in the block"
    else
        bad  "self-awareness 19 — the arithmetic negative-claims rule is in the block" \
             "the block asks her to run a command instead of stating the comparison"
    fi

    # self-awareness 10 — the hands that book wakes in her name.
    if grep -qiE 'promise audit' <<<"$P" && grep -qiE 'canary' <<<"$P"; then
        ok "self-awareness 10 — the prompt names the subsystems that book wakes as her"
    else
        bad  "self-awareness 10 — the prompt names the subsystems that book wakes as her" \
             "nothing tells her that other subsystems book wakes in her name"
    fi

    # rules 16 and 19 — nothing belonging to the desktop coding agent.
    if grep -qF "$CODING_AGENT_SENTINEL" <<<"$P"; then
        bad "rule 16 — no coding-agent instruction file reaches her prompt" \
            "the planted project instruction file was assembled into the prompt"
    else
        ok "rule 16 — no coding-agent instruction file reaches her prompt"
    fi
    local leaked; leaked="$(grep -ioE 'Co-Authored-By|always work, never ask|Oxford comma|PreToolUse' <<<"$P" | head -n1)"
    [ -z "$leaked" ] \
        && ok "rule 19 — no rule addressed to the coding agent is in her prompt" \
        || bad "rule 19 — no rule addressed to the coding agent is in her prompt" "found: $leaked"

    # rule 22 — the WHERE THINGS ARE layer.
    if grep -qiF 'WHERE THINGS ARE' <<<"$P"; then
        ok "rule 22 — the prompt carries a WHERE THINGS ARE index"
    else
        bad  "rule 22 — the prompt carries a WHERE THINGS ARE index" \
             "no path index; the engineering threads and the journal are named nowhere"
    fi

    # rule 25 — one regroup block, never two.
    local regroups; regroups="$(grep -ciE 'another (session|voice) of you|is speaking right now|regroup' <<<"$P")"
    [ "${regroups:-0}" -le 1 ] \
        && ok "rule 25 — at most one regroup block is emitted" \
        || bad "rule 25 — at most one regroup block is emitted" "$regroups regroup blocks"

    # rules 38 through 39d — the standing attention rules, always on, every
    # speaking profile, desk and phone origins alike: answer what was asked
    # first, and act on your own drawers instead of reporting them.
    if grep -qiF 'ANSWER WHAT WAS ASKED, FIRST' <<<"$P"; then
        ok "rule 38 — the answer-first rule stands in the prompt"
    else
        bad  "rule 38 — the answer-first rule stands in the prompt" \
             "nothing tells her the question outranks her own preoccupation"
    fi
    if grep -qiF 'YOUR OWN DRAWERS ARE YOURS TO RUN' <<<"$P"; then
        ok "rule 39 — the drawer-ownership rule stands in the prompt"
    else
        bad  "rule 39 — the drawer-ownership rule stands in the prompt" \
             "nothing tells her a finding about her own files is hers to act on"
    fi
    if grep -qiF 'ACT ON REQUESTS' <<<"$P"; then
        ok "rule 39a — requests cause action before the reply"
    else
        bad "rule 39a — requests cause action before the reply" \
            "nothing says a plan, apology, or self-critique is not the requested action"
    fi
    if grep -qiF 'BACKGROUND WORK STARTS NOW' <<<"$P" \
            && grep -qF 'crab wake-now' <<<"$P"; then
        ok "rule 39d — current work can move out of the conversation without delay"
    else
        bad "rule 39d — current work can move out of the conversation without delay" \
            "nothing makes an immediate wake distinct from a sensible future wake"
    fi
    if grep -qF 'crab job steer' <<<"$P" \
            && grep -qF 'does not steer the builder' <<<"$P"; then
        ok "rule 39e — active builder feedback uses the builder's own channel"
    else
        bad "rule 39e — active builder feedback uses the builder's own channel" \
            "the prompt can still mistake a separate wake for builder steering"
    fi
    if grep -qiF 'RETRACTIONS ARE ACTIONS' <<<"$P"; then
        ok "rule 39f — ignored work is cancelled or corrected before the claim"
    else
        bad "rule 39f — ignored work is cancelled or corrected before the claim" \
            "the prompt still permits a conversational Ignored while work remains queued"
    fi
    if grep -qiF 'ACTIVE WORK NEEDS CURRENT EVIDENCE' <<<"$P"; then
        ok "rule 39g — live builder answers use current activity and artefacts"
    else
        bad "rule 39g — live builder answers use current activity and artefacts" \
            "the prompt can infer current work from an original brief or stale log slice"
    fi
    if grep -qiF 'FACTS BEFORE CLAIMS' <<<"$P" \
            && grep -qiF "I haven't verified that" <<<"$P"; then
        ok "rule 39h — present facts and completed actions require a current witness"
    else
        bad "rule 39h — present facts and completed actions require a current witness" \
            "nothing requires observation before a state or completion claim"
    fi
    if grep -qiF 'CORRECT WITHOUT WALLOWING' <<<"$P"; then
        ok "rule 39b — corrections do not become self-abasement"
    else
        bad "rule 39b — corrections do not become self-abasement" \
            "nothing replaces repeated apologies and self-insults with the correction"
    fi
    if grep -qiF 'ACCEPTED INVITATIONS ARE ACTIONS' <<<"$P"; then
        ok "rule 39c — accepting a present invitation performs it"
    else
        bad "rule 39c — accepting a present invitation performs it" \
            "nothing distinguishes answering an invitation from accepting and joining it"
    fi

    # rules 1 and 2 — one assembler, four profiles.
    if grep -qF -- '--profile' "$REPO_DIR/lib/common.sh"; then
        ok "rule 1 — the assembler takes a profile"
    else
        bad  "rule 1 — the assembler takes a profile" \
             "build_system_prompt has one shape and no --profile turn|wake|job|classify"
    fi

    # rule 11 — measured bytes, against this profile's total.
    local bytes total="$PROFILE_TOTAL_TURN"
    [ "${PROFILE:-turn}" = wake ] && total="$PROFILE_TOTAL_WAKE"
    bytes="$(printf '%s' "$P" | wc -c)"
    printf '  note  assembled system prompt: %s bytes (%s budget %s)\n' \
        "$bytes" "${PROFILE:-turn}" "$total"
    [ "$bytes" -le "$total" ] \
        && ok "rule 11 — the assembled prompt is inside the profile's total budget" \
        || bad "rule 11 — the assembled prompt is inside the profile's total budget" \
               "$bytes bytes against a budget of $total"

    # The transcript format has to be able to say who authored a block.
    local unparsed
    # Same shape as CONVO_BLOCK_RE in lib/common.sh: an optional stamp and an
    # optional provenance marker, both loose about what sits inside them.
    unparsed="$(grep -nE '^(User|Assistant)' "$SRC/conversation.txt" 2>/dev/null \
        | grep -vE '^[0-9]+:(User|Assistant)( \[[^]]*\])?( \([^)]*\))?: ' | head -n1)"
    if [ -z "$unparsed" ]; then
        ok "transcript — every block header in the fixture parses as a block"
    else
        bad  "transcript — every block header in the fixture parses as a block" \
             "the block pattern cannot carry provenance yet: $unparsed"
    fi

    # rule 20 — the shelf is titles, the bodies stay on disk.
    if [ -f "$CS/wants.md" ]; then
        local title
        title="$(grep -oP '^- \*\*.*?\*\*|^- [^ ]+ \*\*.*?\*\*' "$CS/wants.md" 2>/dev/null | head -n1)"
        if [ -n "$title" ] && grep -qF -- "$title" <<<"$P"; then
            ok "rule 20 — the shelf's titles are in the prompt"
        else
            bad "rule 20 — the shelf's titles are in the prompt" "missing: ${title:-<no title parsed>}"
        fi
        if [ -d "$CS/wants" ]; then
            if grep -qF 'WANT_BODY_MARKER' <<<"$P"; then
                bad "rule 20 — want bodies stay on disk" "a want document's body reached the prompt"
            else
                ok "rule 20 — want bodies stay on disk"
            fi
        fi
    fi

    # rule 21 — conduct: the binding test verbatim, the bodies behind an index.
    if [ -f "$CS/conduct/CONDUCT.md" ]; then
        local binding; binding="$(grep -m1 '^> ' "$CS/conduct/CONDUCT.md" | sed 's/^> //')"
        if [ -n "$binding" ] && grep -qF -- "$binding" <<<"$P"; then
            ok "rule 21 — the binding test line is in the prompt verbatim"
        else
            bad "rule 21 — the binding test line is in the prompt verbatim" "missing: $binding"
        fi
        if grep -qF 'CONDUCT_BODY_MARKER' <<<"$P"; then
            skip "rule 21 — conduct bodies stay behind the index, like the shelf" \
                 "CONDUCT.md is injected whole, ten lines after the shelf is cut to titles"
        else
            ok "rule 21 — conduct bodies stay behind the index, like the shelf"
        fi
    fi
}

# ---------------------------------------------------------------------------
# MODE 2 — grading a reply
# ---------------------------------------------------------------------------

# A real session on the assembled prompt. Never called unless PROMPT_CASES_LIVE=1.
live_reply() { # <case state dir> <message> -> sets REPLY_TEXT, REPLY_TOOL_CALLS
    local CS="$1" msg="$2" out="$CS/live-stream.jsonl"
    ( cd "$CS/project" && env -i \
        HOME="$HOME" PATH="$PATH" TERM=dumb \
        CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
        "$(command -v claude)" -p --dangerously-skip-permissions \
        --verbose --output-format stream-json \
        --append-system-prompt "$PROMPT_TEXT_ASSEMBLED" "$msg" ) > "$out" 2>/dev/null
    REPLY_TEXT="$(python3 - "$out" <<'PY'
import json, sys
text, tools = [], 0
for line in open(sys.argv[1], errors="replace"):
    try: ev = json.loads(line)
    except ValueError: continue
    for block in (ev.get("message") or {}).get("content") or []:
        if block.get("type") == "text": text.append(block["text"])
        if block.get("type") == "tool_use": tools += 1
print("\n".join(text))
sys.stderr.write(str(tools))
PY
)"
    REPLY_TOOL_CALLS="$(python3 -c '
import json,sys
n=0
for line in open(sys.argv[1],errors="replace"):
    try: ev=json.loads(line)
    except ValueError: continue
    for b in (ev.get("message") or {}).get("content") or []:
        if b.get("type")=="tool_use": n+=1
print(n)' "$out")"
}

grade_step() { # <case state dir> <case src> <message file> <assertions> <good> <bad>
    local CS="$1" SRC="$2" mf="$3" af="$4" good="$5" badf="$6"
    [ -f "$SRC/$mf" ] || return 0

    if [ "$LIVE" = "1" ]; then
        ( cd "$CS" && find . -type f -printf '%p\n' | sort | xargs md5sum ) \
            > "$CS/.checksums" 2>/dev/null
        live_reply "$CS" "$(cat "$SRC/$mf")"
        printf '  note  live reply, %s tool calls\n' "${REPLY_TOOL_CALLS:-0}"
        run_assertions "$SRC/$af" "$CS"
        return
    fi

    # Offline: the grader itself is what is under test. The good reply must
    # pass every rule; the reply in the original failure's shape must trip at
    # least one, or the rules are not actually catching anything.
    REPLY_TOOL_CALLS=0
    if [ -f "$SRC/$good" ]; then
        REPLY_TEXT="$(expand_vars "$(cat "$SRC/$good")" "$CS")"
        local before_fail=$FAIL
        run_assertions "$SRC/$af" "$CS"
        [ "$FAIL" -eq "$before_fail" ] \
            && ok "canned good reply passes every rule" \
            || printf '  note  the failures above are the CANNED GOOD reply, not the model\n'
    fi
    if [ -f "$SRC/$badf" ]; then
        REPLY_TEXT="$(expand_vars "$(cat "$SRC/$badf")" "$CS")"
        # The bad reply is expected to fail: run it with every counter and
        # every record restored afterwards, so its failures are not the
        # suite's failures.
        local sf=$FAIL sp=$PASS sw=$WARN ss=$SKIP sb=$CASE_BAD so=$CASE_OK
        local nf=${#FAILURES[@]} ns=${#SKIPS[@]}
        run_assertions "$SRC/$af" "$CS" > /dev/null
        local tripped=$(( FAIL - sf ))
        FAIL=$sf; PASS=$sp; WARN=$sw; SKIP=$ss; CASE_BAD=$sb; CASE_OK=$so
        [ "$nf" -eq 0 ] && FAILURES=() || FAILURES=("${FAILURES[@]:0:$nf}")
        [ "$ns" -eq 0 ] && SKIPS=() || SKIPS=("${SKIPS[@]:0:$ns}")
        [ "$tripped" -gt 0 ] \
            && ok "the original failure's shape trips $tripped rule(s)" \
            || bad "the original failure's shape trips a rule" \
                   "the bad reply passed every assertion — the rules catch nothing"
    fi
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
SELECT="${1:-}"
[ "$SELECT" = "--list" ] && { ls -1 "$CASES_DIR" | sed 's/^/  /'; exit 0; }

echo
echo "mode: $MODE$( [ "$LIVE" = 1 ] && echo ' (LIVE — real sessions)')$( [ "$STRICT" = 1 ] && echo ' (STRICT — skips are failures)')"

for SRC in "$CASES_DIR"/case-*; do
    [ -d "$SRC" ] || continue
    CASE_NAME="$(basename "$SRC")"
    [ -n "$SELECT" ] && case "$CASE_NAME" in *"$SELECT"*) : ;; *) continue ;; esac
    CASE_OK=0 CASE_BAD=0
    echo
    echo "$CASE_NAME"
    CS="$(stage_case "$SRC")"

    # A case is a TURN unless it says otherwise. A wake is a different profile
    # of the same assembler — its own budgets, its own frame — so a case about
    # what a wake writes has to be built as one, or it is graded against a
    # prompt no wake ever sees.
    PROFILE="turn"
    [ -f "$SRC/profile" ] && PROFILE="$(tr -d '[:space:]' < "$SRC/profile")"
    PROMPT_TEXT_ASSEMBLED="$(in_case "$CS" "build_system_prompt --profile $PROFILE")"
    REPLY_TEXT=""
    if [ -z "$PROMPT_TEXT_ASSEMBLED" ]; then
        bad "the assembler produced a prompt" "build_system_prompt printed nothing"
    elif [ "$MODE" = "assembly" ]; then
        structural_checks "$CS" "$SRC"
        run_assertions "$SRC/assertions.txt" "$CS"
        if [ -f "$SRC/message-2.txt" ]; then
            run_assertions "$SRC/assertions-2.txt" "$CS"
        fi
        # ...and then MODE 2, offline, in the same run. Most of every case's
        # contract is reply rules, and apply_rule returns without recording
        # anything for a reply, spoken or display target while the mode is
        # assembly — so a suite that only ever ran this file in its default
        # mode evaluated 10 of 81 rules and never once asked whether the other
        # 71 catch anything. Weakening every rule in a case left the run
        # green. The grading is deterministic, offline and free: each case
        # ships a canned good reply that must pass every rule and a canned bad
        # reply in the original failure's shape that must trip at least one.
        # PROMPT_CASES_MODE=reply still runs the grading alone, and
        # PROMPT_CASES_LIVE=1 still sends the assembled prompt to a real
        # session; neither is what a routine run needs.
        deferred="$(cat "$SRC"/assertions*.txt 2>/dev/null \
            | grep -cE '^(should |phase4 )*(reply|spoken|display) ')"
        printf '  note  grading %s reply rules against the canned replies\n' "$deferred"
        MODE=reply
        grade_step "$CS" "$SRC" message.txt assertions.txt reply.txt reply-bad.txt
        grade_step "$CS" "$SRC" message-2.txt assertions-2.txt reply-2.txt reply-2-bad.txt
        MODE=assembly
    else
        grade_step "$CS" "$SRC" message.txt assertions.txt reply.txt reply-bad.txt
        grade_step "$CS" "$SRC" message-2.txt assertions-2.txt reply-2.txt reply-2-bad.txt
    fi

    if [ "$CASE_BAD" -eq 0 ]; then CASES_PASSED=$(( CASES_PASSED + 1 ))
    else CASES_FAILED=$(( CASES_FAILED + 1 )); fi
done

echo
echo "=============================================================="
printf 'cases: %d passed, %d failed\n' "$CASES_PASSED" "$CASES_FAILED"
printf 'assertions: %d passed, %d failed, %d skipped, %d warned\n' "$PASS" "$FAIL" "$SKIP" "$WARN"
if [ "${#FAILURES[@]}" -gt 0 ]; then
    echo
    echo "failed:"
    printf '  %s\n' "${FAILURES[@]}"
fi
if [ "${#SKIPS[@]}" -gt 0 ]; then
    echo
    echo "skipped — the phase 4 red list (PROMPT_CASES_STRICT=1 makes these failures):"
    printf '  %s\n' "${SKIPS[@]}"
fi
echo "=============================================================="
[ "$FAIL" -eq 0 ]
