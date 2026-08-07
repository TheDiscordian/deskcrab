#!/bin/bash
# Shared config and functions for DeskCrab

LIB_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$(dirname "$LIB_DIR")}"
CONF_FILE="${DESKCRAB_CONF:-$HOME/.config/deskcrab/deskcrab.conf}"

if [ ! -f "$CONF_FILE" ]; then
    echo "Config not found: $CONF_FILE"
    echo "Copy deskcrab.conf.example to $CONF_FILE and edit it."
    exit 1
fi

# CLAUDE_BIN is the one setting a caller must be able to override from the
# environment, because it is the only way a test can stand in a stub for the
# builder. A plain `CLAUDE_BIN=...` line in the config clobbers the inherited
# value, so every `${CLAUDE_BIN:-...}` downstream reads the config's answer and
# the stub is never called — which is how, on 2026-08-07, a test meant to prove
# a scratch runner stays quiet started two real builder sessions on my account
# instead. Snapshot it, then hand it back.
_INHERITED_CLAUDE_BIN="${CLAUDE_BIN:-}"
source "$CONF_FILE"
[ -n "$_INHERITED_CLAUDE_BIN" ] && CLAUDE_BIN="$_INHERITED_CLAUDE_BIN"
unset _INHERITED_CLAUDE_BIN

# Defaults
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-low}"
# Further `claude` logins to fall back to when the account in hand refuses to
# run at all — session/usage limit reached, credits exhausted. Names other
# Claude Code config directories (separate subscriptions' logins); the refused
# run is retried with CLAUDE_CONFIG_DIR pointed at each in turn. Limit refusals
# ONLY: an auth or network failure would fail on the next account too, and
# must surface as itself. Unset = fail exactly as before.
#
# The name is singular by history but the value is a CHAIN: a third or fourth
# subscription is another entry, separated by whitespace or colons, tried
# left to right. One entry behaves exactly as it always did.
CLAUDE_FALLBACK_CONFIG_DIR="${CLAUDE_FALLBACK_CONFIG_DIR:-}"
# What a limit refusal looks like (case-insensitive ERE). A run that never
# began outputs one line of the CLI's own refusal and nothing else; these are
# the wordings observed live plus the session-limit variants. Shared by every
# retry site and by job_output_blocked, so the two judgements can never drift.
CLAUDE_LIMIT_RE="${CLAUDE_LIMIT_RE:-out of usage credits|usage limit reached|session limit reached|5-hour limit|weekly limit|hit your usage limit|hit your session limit|credit balance is too low|insufficient credit|out of extra usage}"
PROJECT_DIR="${PROJECT_DIR:-$HOME}"
# The auto-memory of the directory she is started in is not HER memory.
# `claude` reads $HOME/.claude/projects/<cwd-slug>/memory/MEMORY.md straight
# into the system prompt of any session started in that directory. PROJECT_DIR
# is the user's own coding project, so every turn and every wake arrived
# carrying his CODING agent's memory — a topic-hub index addressed to a
# different assistant, telling her to read hub files before working in their
# area. Her long-term memory is the vector store (`crab memory`), her rules are
# the persona and the conduct file, and the two have nothing to do with each
# other. Verified against claude 2.1.x: the gate reads this environment
# variable FIRST, ahead of the `autoMemoryEnabled` setting, so this is a
# per-invocation answer and not a machine-wide one.
#
# Prefixed onto the invocations that are HER — turn, wake, conversation
# compaction, promise audit, memory ingest/judge — and deliberately NOT
# exported and NOT written into any settings.json:
#   * a key in ~/.claude/settings.json or $PROJECT_DIR/.claude/settings.json
#     would switch auto-memory off for the USER's own coding sessions in the
#     same directory, which is where that memory belongs;
#   * an export here would reach lib/job-runner (it sources this file), and a
#     detached builder working in a project is exactly the session that SHOULD
#     have the project's rules.
CLAUDE_NO_AUTO_MEMORY="CLAUDE_CODE_DISABLE_AUTO_MEMORY=1"
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/.local/share/deskcrab/archive}"
CONVO_TIMEOUT="${CONVO_TIMEOUT:-300}"
# NOTIFY_NAME inherits an explicitly set ASSISTANT_NAME so one variable renames
# the whole assistant; ASSISTANT_NAME's own default is applied afterwards so
# configs that set neither keep "DeskCrab" notification titles.
NOTIFY_NAME="${NOTIFY_NAME:-${ASSISTANT_NAME:-DeskCrab}}"
ASSISTANT_NAME="${ASSISTANT_NAME:-Crab}"
# Sliding-window history: once the live convo exceeds CONVO_MAX_TURNS blocks, the
# oldest CONVO_SUMMARIZE_TURNS blocks are folded into a running summary. A block
# is one thing said by one of us — a "User: " line or an "Assistant: " line —
# NOT a matched pair. It used to count only "^User: ", which meant every
# autonomous wake (an Assistant block with no user line above it) was invisible
# to the window: on 2026-08-07 the live conversation stood at 17 user blocks and
# 27 assistant blocks against a threshold of 20 and had never once compacted,
# so roughly double the intended history rode along on every single turn.
CONVO_MAX_TURNS="${CONVO_MAX_TURNS:-20}"
CONVO_SUMMARIZE_TURNS="${CONVO_SUMMARIZE_TURNS:-10}"
# Model used for the cheap summarization pass (keep it small/fast).
CONVO_SUMMARY_MODEL="${CONVO_SUMMARY_MODEL:-haiku}"
# Durable "wants" file the assistant maintains and pursues during autonomous
# wakes (crab wake / crab wake-at). Unset = feature off.
WANTS_FILE="${WANTS_FILE:-}"
# Local-time hours (HH-HH, wraps midnight) during which autonomous wakes stay
# fully silent — no speech, no windows. Unset = no quiet hours.
WAKE_QUIET_HOURS="${WAKE_QUIET_HOURS:-}"
# Effort for autonomous wakes. Nobody is waiting on a wake, so it can afford
# more thinking than the interactive default.
WAKE_EFFORT="${WAKE_EFFORT:-$CLAUDE_EFFORT}"
# Reap an autonomous wake only when it goes completely silent: an active session
# writes stream events constantly, so this many seconds without any output means
# it is hung, not thinking. Wall-clock limits would kill productive sessions.
WAKE_STALL_TIMEOUT="${WAKE_STALL_TIMEOUT:-300}"
# A wake that fires beside an interactive turn used to be muted outright
# (the old WAKE_MUTE_AFTER_TURN echo window) — its reply swallowed wholesale.
# That was rejected: a wake with something genuinely new deserves its voice.
# Instead the wake is handed the exchange as evidence: when the last
# interactive turn started or finished within this many seconds, the turn's
# user message — and the reply, once there is one — are spliced into the
# wake's prompt (wake_concurrent_turn_context) with instructions to behave
# like someone who just heard the answer given: REGROUP — fold what it came
# with into one reply that follows on, never restate, and stay quiet only when
# there is genuinely nothing left to add. 0 disables the evidence block. The
# nothing-new check stays as the mechanical backstop for a wake that echoes
# anyway — except when regrouping was asked for, where overlap is the point.
WAKE_TURN_CONTEXT_WINDOW="${WAKE_TURN_CONTEXT_WINDOW:-300}"
# Self-booked wakes stack: several sessions each promise "come back in 45min"
# and the timers land minutes apart, each re-reading the wants and
# re-announcing the same progress. A scheduled booking whose fire time is
# within this many seconds of a pending one with the same reason is not
# booked — the existing promise already covers it. 0 disables.
WAKE_COALESCE_WINDOW="${WAKE_COALESCE_WINDOW:-900}"
# Regrouping. When one session of me is already speaking and another is about
# to, the second does NOT queue its thought away and does NOT default to
# silence: it is shown the other reply verbatim while its prompt is being
# built, and asked to compose ONE reply that covers both things — the way a
# person with two things to say folds them into a single sentence instead of
# saying them twice. This is the seconds-scale window in which the other
# reply still counts as "being said right now". 0 disables the block.
LIVE_SPEECH_WINDOW="${LIVE_SPEECH_WINDOW:-180}"

# Remote (phone) client: crab serve. Unset SERVE_SECRET disables serving.
SERVE_PORT="${SERVE_PORT:-8723}"
SERVE_BIND="${SERVE_BIND:-127.0.0.1}"
SERVE_SECRET="${SERVE_SECRET:-}"
SERVE_TIMEOUT="${SERVE_TIMEOUT:-600}"
# TLS for the phone client. Browsers refuse microphone access over plain http
# from anything but localhost, so a phone needs https one way or another:
#   off  - plain http (fine behind `tailscale serve`, which terminates TLS)
#   self - self-signed cert, generated on demand; one "accept the risk" tap
# SERVE_CERT/SERVE_KEY override both with a pair you supply (e.g. the output
# of `tailscale cert`, which is a real, warning-free certificate).
SERVE_TLS="${SERVE_TLS:-off}"
SERVE_CERT="${SERVE_CERT:-}"
SERVE_KEY="${SERVE_KEY:-}"
TLS_DIR="${TLS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/tls}"

# Runtime state. Overridable from the environment so a test run can be pointed
# at a scratch conversation instead of stomping the live one.
STATE_PREFIX="${DESKCRAB_STATE_PREFIX:-/tmp/deskcrab}"
CONVOFILE="${STATE_PREFIX}-convo.txt"
CONVOLOCK="${STATE_PREFIX}-convo.lock"
SUMMARYFILE="${STATE_PREFIX}-convo-summary.txt"
TTSPIDFILE="${STATE_PREFIX}-tts.pid"
# ONE STREAM LOG PER SESSION, not one shared file. The shared log was the root
# of the worst silence in this thing. A wake firing beside a desktop turn ran
# `: > "$DEBUGLOG"` on the very file that turn's TTS streamer was tailing: the
# streamer's read cursor was left past EOF, it read nothing ever again, spoke
# nothing, and never saw a result event — so the reply appeared on screen, was
# never heard, and `wait "$_TTS_STREAMER_PID"` hung the turn behind it. And if
# the wake then wrote past the stranded offset, the desktop streamer resumed
# mid-file and spoke the WAKE's words as though they were the answer to the
# question just asked. Both shapes are measured in tests/test_speech_path.sh.
# The remote turn already had a private log for exactly this reason; now
# everybody does, and the well-known name is a pointer to the newest.
# DESKCRAB_STREAMLOG pins this session's log to a named file — for a test that
# needs to hand a specific stream to the predicates, and for anything that
# wants to read a stream it did not produce.
DEBUGLOG="${DESKCRAB_STREAMLOG:-${STATE_PREFIX}-debug-$$.log}"
DEBUGLOG_LATEST="${STATE_PREFIX}-debug.log"
# Where a lost or failed utterance is recorded. Speech that vanishes without a
# trace is the failure mode this file keeps re-learning; nothing on the audio
# path may fail quietly again.
SPEECH_LOG="${SPEECH_LOG:-${STATE_PREFIX}-speech.log}"
SESSIONS_DIR="${STATE_PREFIX}-sessions"
# Which login runs FIRST is a POSITION that moves, never a timer: the default
# account. When the login in hand refuses over a limit, the next one in the
# chain becomes the default — immediately, durably — and stays the default
# until IT refuses in its turn, wrapping past the end of the chain back to the
# primary. Nothing moves it back on its own: the expiry stamp this replaces
# re-probed a dry primary every half hour — a full CLI boot and refusal in
# front of a reply, all afternoon, when the refusal itself had said "resets
# 5pm". Durable like last-origin (a reboot must not quietly hand the chain
# back to a dry primary); a scratch instance overrides the path.
ACCOUNT_DEFAULT_FILE="${ACCOUNT_DEFAULT_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/account-default}"
# Speech mutex: every path that puts audio on the speakers — the interactive
# TTS streamer and a wake's speak_once — holds this flock for the whole speak
# stage. Two voices at once is never acceptable: the later speaker queues
# behind the lock, and a wake checks it first and stays silent instead.
SPEECHLOCK="${STATE_PREFIX}-speech.lock"
# Detached jobs. Deliberately NOT under STATE_PREFIX (/tmp): a job outlives the
# turn that started it, and may outlive a reboot's tmp cleanup too. Jobs run
# unattended builds nobody is waiting on, so they default to the strongest
# model at high effort rather than the fast interactive settings.
JOBS_DIR="${JOBS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/jobs}"
JOB_MODEL="${JOB_MODEL:-fable}"
JOB_EFFORT="${JOB_EFFORT:-high}"
# How many finished jobs the report lists, and how long finished job records
# (status + log) are kept before pruning.
JOBS_SHOW_FINISHED="${JOBS_SHOW_FINISHED:-6}"
JOBS_KEEP_DAYS="${JOBS_KEEP_DAYS:-14}"
# A job that never began because the account had nothing left to spend is not a
# failed build — nothing was attempted. The marker records that, and holds off
# further dispatches for a while rather than firing them into the same wall.
JOBS_BLOCKED_FILE="${JOBS_BLOCKED_FILE:-$JOBS_DIR/blocked}"
JOB_BLOCK_RETRY="${JOB_BLOCK_RETRY:-1800}"
# Durable wake bookings. A transient timer lives only inside the running user
# manager — a reboot or logout erases it with no trace — so every wake-at also
# writes one record here (fire-epoch \t kind \t reason) and `crab wake-restore`
# rebuilds timers from the records at login. Deliberately NOT under
# STATE_PREFIX: a promise for tomorrow morning must survive /tmp being cleared.
WAKES_DIR="${WAKES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/wakes}"
# How much of the wake queue reaches the PROMPT. `crab status` still lists every
# pending timer; the prompt gets the near horizon and a count of the rest, because
# a wake nine hours out changes nothing about the turn being answered now.
WAKES_HORIZON_HOURS="${WAKES_HORIZON_HOURS:-12}"
WAKES_SHOW="${WAKES_SHOW:-5}"
# A blocked wake's retry must not land on top of the other blocked wakes. Base
# push-back, and the minimum distance two bookings must keep from each other.
WAKE_DEFER_DELAY="${WAKE_DEFER_DELAY:-900}"
WAKE_SLOT_SPREAD="${WAKE_SLOT_SPREAD:-180}"
# Booking is check-then-act three times over — is an equivalent wake already
# pending, is this moment free, write the record, book the timer — and several
# sessions book at once. Two wakes finishing in the same second each asked "is a
# scheduled wake pending?", each got no, and each booked one: that is how two
# floor bookings came to sit on 13:05:54. Every booking and every reconciliation
# goes through this lock, so the question and the answer cannot be separated by
# another hand.
WAKE_BOOK_LOCK="${STATE_PREFIX}-wake-book.lock"
SESSIONS_LOCK="${STATE_PREFIX}-sessions.lock"
SESSIONS_LOG="${STATE_PREFIX}-sessions.log"
# How far back the journal of finished sessions is read, and how many entries
# of it reach the prompt.
SESSIONS_LOG_HOURS="${SESSIONS_LOG_HOURS:-12}"
SESSIONS_LOG_SHOW="${SESSIONS_LOG_SHOW:-8}"
# The prompt's copy of that journal is a much shorter reach back: half an hour,
# a few entries, each one a line rather than a paragraph. Twelve hours of full
# turn text is a day's log, and reading it in a prompt is nothing like
# remembering the last half hour — which is the only thing it is for.
SESSIONS_RECENT_MINUTES="${SESSIONS_RECENT_MINUTES:-30}"
SESSIONS_RECENT_SHOW="${SESSIONS_RECENT_SHOW:-4}"
SESSIONS_RECENT_WIDTH="${SESSIONS_RECENT_WIDTH:-150}"
SESSIONS_LOG_KEEP="${SESSIONS_LOG_KEEP:-400}"
# The durable day record beneath the sessions log. The log above is the live
# view — trimmed lines, capped, erased with /tmp at every reboot. This is the
# archive: one JSON object per finished turn (desktop, phone, wake, job) in
# journal/YYYY-MM-DD.jsonl, user text and reply IN FULL, never trimmed, never
# rotated, written at the same moments the log is. Deliberately NOT under
# STATE_PREFIX: its whole purpose is to be re-readable after a reboot.
DAY_JOURNAL_DIR="${DAY_JOURNAL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/journal}"
# Self-change suppression records (lib/notice-selfchange reads these): a hand
# of the assistant's own, about to write files that constitute her, declares
# it here so the watcher never wakes her about her own edits. Deliberately
# NOT under STATE_PREFIX: a record written by a job must be visible to the
# watcher no matter which instance wrote it.
NOTICE_STATE_DIR="${NOTICE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/deskcrab}"
NOTICE_SUPPRESS="${NOTICE_SUPPRESS:-$NOTICE_STATE_DIR/notice-self.suppress}"
# How long a `crab touching` declaration lasts by default, seconds.
TOUCH_WINDOW="${TOUCH_WINDOW:-900}"
# Forensics for the watcher. $DEBUGLOG is ONE shared file, rewritten by the next
# turn that starts, so by the time a false alarm reaches me the stream that
# would explain it is already gone — twice now I have had to reason about a
# missing declaration from the suppression records alone and stop at "cause
# undetermined". These keep the last few turns' streams and a line per harvest
# saying what was declared, so the next occurrence is answerable instead of
# argued about.
NOTICE_STREAM_DIR="${NOTICE_STREAM_DIR:-$NOTICE_STATE_DIR/streams}"
NOTICE_STREAM_KEEP="${NOTICE_STREAM_KEEP:-20}"
NOTICE_DECLARED_LOG="${NOTICE_DECLARED_LOG:-$NOTICE_STATE_DIR/notice-self.declared.log}"

# The conversation archive must exist before the first stale conversation
# tries to land in it. rotate_convo mkdirs too, but a missing directory should
# never be the reason anyone doubts the archive path has run.
mkdir -p "$ARCHIVE_DIR" 2>/dev/null

# Kernel boot-relative start time of a pid, in clock ticks (field 22 of
# /proc/PID/stat). Recorded alongside the pid so a recycled pid cannot make a
# long-dead session look live: same number, different start time, still dead.
_proc_starttime() {
    awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[20] }' \
        "/proc/$1/stat" 2>/dev/null || echo 0
}

# --- Self-awareness: who else is running right now -------------------------
# Every claude invocation registers itself here so that any one of them can see
# the others. Without this an interactive turn has no idea a wake is working in
# parallel, and reports "nothing is happening" while something is.
session_register() {
    SESSION_KIND="$1"
    SESSION_START=$(date +%s)
    SESSION_OUTCOME=""
    # Filled in by the turn as its text becomes known, read back by the day
    # journal at finish. Full text on purpose — the sessions log keeps the
    # trimmed line; the journal keeps the words.
    SESSION_USER_TEXT=""
    SESSION_REPLY=""
    mkdir -p "$SESSIONS_DIR"
    SESSION_FILE="$SESSIONS_DIR/$$"
    printf '%s\t%s\t%s\t%s\t%s\n' "$SESSION_KIND" "$$" \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$SESSION_START" "$(_proc_starttime $$)" \
        > "$SESSION_FILE"
    trap session_finish EXIT INT TERM
}

# What this session actually accomplished, in one line. Recorded so the NEXT
# session can see it: a live registry only ever answers "who is running", and
# the failure it does not catch is concluding "I did no work" when an earlier
# session already finished the work and exited.
session_outcome() {
    SESSION_OUTCOME="$(printf '%s' "$1" | tr '\n\t' '  ' | head -c 300)"
}

# --- Work claims -----------------------------------------------------------
# The registry reports; it does not claim. Knowing another session is alive is
# not the same as knowing it has lib/common.sh open — twice in twenty minutes
# two sessions edited and committed the same file, and one set of changes went
# in under the other's commit message because `git add -A` in one hand sweeps up
# whatever the other has staged. A claim is deliberately advisory: a lock held
# by a session that dies mid-edit would wedge every later one, and a hand that
# cannot start is worse than two hands that can see each other.
#
# The claim lives beside the live registration as <pid>.claim. A claude session
# calls `crab claim` from a tool call, so the claiming process is a descendant
# of the registered shell rather than the shell itself: walk up the ppid chain
# to find whichever ancestor is registered.
_claim_owner_pid() {
    local p="${1:-$$}" guard=0
    while [ "$p" -gt 1 ] && [ "$guard" -lt 40 ]; do
        [ -e "$SESSIONS_DIR/$p" ] && { echo "$p"; return 0; }
        p="$(awk '{ n = split($0, f, ") "); split(f[n], g, " "); print g[2] }' \
             "/proc/$p/stat" 2>/dev/null)" || return 1
        [ -n "$p" ] || return 1
        guard=$((guard+1))
    done
    return 1
}

# Words too generic to mean two sessions are in each other's way.
_CLAIM_STOPWORDS=" the a an and or of in on to for with my her at is are be it its this that work working "

# Shared significant tokens between two claims, if any.
_claim_overlap() {
    local t out=""
    for t in $(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9./_-' ' '); do
        [ "${#t}" -ge 3 ] || continue
        case "$_CLAIM_STOPWORDS" in *" $t "*) continue ;; esac
        case " $(printf '%s' "$2" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9./_-' ' ') " in
            *" $t "*) out="$out $t" ;;
        esac
    done
    printf '%s' "${out# }"
}

# Announce what this session is holding. Prints any other live session's claim,
# and shouts when the two touch the same thing.
session_claim() {
    local what="$1" owner
    owner="$(_claim_owner_pid $PPID)" || owner="$(_claim_owner_pid $$)" || {
        echo "No registered session in this process's ancestry — nothing to claim against."
        return 1
    }
    mkdir -p "$SESSIONS_DIR"
    session_reap
    local f pid other clash=0
    for f in "$SESSIONS_DIR"/*.claim; do
        [ -e "$f" ] || continue
        pid="$(basename "$f" .claim)"
        [ "$pid" = "$owner" ] && continue
        [ -e "$SESSIONS_DIR/$pid" ] || { rm -f "$f"; continue; }
        other="$(cat "$f")"
        local shared; shared="$(_claim_overlap "$what" "$other")"
        if [ -n "$shared" ]; then
            echo "CONFLICT — pid $pid is already holding: $other"
            echo "           (both touch:$( printf ' %s' $shared ))"
            clash=1
        else
            echo "also live — pid $pid holds: $other"
        fi
    done
    printf '%s\n' "$what" > "$SESSIONS_DIR/$owner.claim"
    [ "$clash" -eq 1 ] \
        && echo "Claim recorded anyway (advisory, never a lock). Coordinate or pick different files." \
        || echo "Claimed: $what"
    return 0
}

session_unclaim() {
    local owner
    owner="$(_claim_owner_pid $PPID)" || owner="$(_claim_owner_pid $$)" || return 0
    rm -f "$SESSIONS_DIR/$owner.claim"
    echo "Claim released."
}

# --- Checkpoints: a resumable trace of a turn in progress -------------------
# The journal only speaks at the END of a session, so a turn cut off mid-work
# (network drop, SIGKILL) leaves edits on disk and no explanation — the next
# hand sees orphan changes and cannot tell what was intended or what remained.
# A checkpoint is recorded DURING the turn: intent, files touched, what is
# done, what is next. It lives beside the registration as <pid>.ckpt and is
# append-only — each line is a single O_APPEND write, so a kill mid-checkpoint
# leaves every earlier line intact. A clean finish deletes it (the outcome
# line covers a finished session); a reaped session's checkpoints are moved to
# $CKPT_INTERRUPTED_DIR, where `crab status` surfaces them until someone picks
# the work up and clears them with `crab resolve`.
CKPT_INTERRUPTED_DIR="${STATE_PREFIX}-interrupted"
CKPT_KEEP_DAYS="${CKPT_KEEP_DAYS:-7}"

session_checkpoint() {
    local what owner
    what="$(printf '%s' "$1" | tr '\n\t' '  ' | head -c 500)"
    [ -n "$what" ] || { echo "Usage: crab checkpoint <intent / progress / what is next>"; return 1; }
    owner="$(_claim_owner_pid $PPID)" || owner="$(_claim_owner_pid $$)" || {
        echo "No registered session in this process's ancestry — nothing to checkpoint against."
        return 1
    }
    printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$what" >> "$SESSIONS_DIR/$owner.ckpt"
    echo "Checkpointed."
}

# List interrupted sessions' surviving checkpoints, most recent trace last.
interrupted_report() {
    local f n=0
    [ -d "$CKPT_INTERRUPTED_DIR" ] || { echo "  (none)"; return 0; }
    for f in "$CKPT_INTERRUPTED_DIR"/*.ckpt; do
        [ -s "$f" ] || continue
        printf '  - %s (clear with: crab resolve %s)\n' "$(basename "$f" .ckpt)" "$(basename "$f" .ckpt)"
        tail -n 3 "$f" | awk -F'\t' '{ printf "      %s  %s\n", $1, $2 }'
        n=$((n+1))
    done
    [ "$n" -eq 0 ] && echo "  (none)"
    return 0
}

# The work an interrupted trace pointed at has been picked up (or judged dead):
# drop it so status stops raising it.
interrupted_resolve() {
    local name="$1"
    [ -n "$name" ] || { echo "Usage: crab resolve <name from crab status>"; return 1; }
    case "$name" in */*|*..*) echo "Bad name."; return 1 ;; esac
    if [ -e "$CKPT_INTERRUPTED_DIR/$name.ckpt" ]; then
        rm -f "$CKPT_INTERRUPTED_DIR/$name.ckpt"
        echo "Resolved: $name"
    else
        echo "No interrupted trace named '$name'."
        return 1
    fi
}

# --- Day journal: the record beneath the sessions log ----------------------
# Appended at every point that appends to SESSIONS_LOG, plus job completion.
# One JSON line per turn via lib/day-journal, which does the encoding — a
# reply holds quotes, newlines, tabs and emoji, and a hand-concatenated line
# would be a lost day. The three texts travel NUL-separated on stdin, not as
# arguments: a job's full log can exceed the kernel's per-argument limit.
day_journal_append() {  # <kind> <start-epoch> <duration|-> <pid> <user> <reply> [outcome]
    command -v python3 >/dev/null 2>&1 || return 0
    # The journal is in the self-change watch set, and this function is its
    # only writer of hers — declare the write so it never reads as an outside
    # hand's.
    touch_suppress -w 300 "$DAY_JOURNAL_DIR" 2>/dev/null
    printf '%s\0%s\0%s' "$5" "$6" "${7:-}" \
        | "$LIB_DIR/day-journal" append "$DAY_JOURNAL_DIR" "$1" "$2" "$3" "$4" 2>/dev/null
    return 0
}

# --- Self-change suppression: my own hand must not read as an intruder's ---
# lib/notice-selfchange wakes the assistant when files that constitute her —
# wants, conduct, engineering, journal, memory, config, the repo, her library
# — change on disk. Every process of hers that writes such files declares it,
# before or just after the write:
#   touch_suppress [-w seconds] [-t weak] <path>...   (CLI: crab touching <paths>)
# One record per line, "<expiry-epoch>\t<absolute path>[\t<tier>]"; a strong
# record for a directory covers its whole subtree. Appends hold a lock because
# the watcher prunes expired lines by rewriting the file, and an append racing
# that rewrite would be a lost declaration — which reads as an intruder's edit.
#
# TWO TIERS, because the shapes a writer can take are unbounded:
#   strong (default, and what every pre-existing two-column record parses as)
#          — the path was in a provable write position. Excuses any change,
#          a deletion included.
#   weak   — the path merely appeared somewhere in a command I ran. Excuses a
#          modification or a creation, NEVER a deletion, and never by subtree.
# The asymmetry is the whole point: anything in my own tool stream came from my
# own hand, so over-declaring modifications costs little, while "a deleted want
# always surfaces unless its deleter said so" stays true by construction.
touch_suppress() {
    local win="$TOUCH_WINDOW" tier="" p
    while :; do
        case "${1:-}" in
            -w) win="$2"; shift 2 ;;
            -t) tier="$2"; shift 2 ;;
            *)  break ;;
        esac
    done
    [ $# -gt 0 ] || { echo "Usage: crab touching [-w seconds] <path>..."; return 1; }
    mkdir -p "$NOTICE_STATE_DIR"
    local exp=$(( $(date +%s) + win ))
    {
        flock 9
        for p in "$@"; do
            printf '%s\t%s\t%s\n' "$exp" \
                "$(readlink -m -- "$p" 2>/dev/null || printf '%s' "$p")" "$tier" \
                >> "$NOTICE_SUPPRESS"
        done
    } 9>>"$NOTICE_SUPPRESS.lock"
    return 0
}

# The stream log knows which files this turn's tools wrote (same mechanical
# read as wake_work_trace, paths only) — declare them after the fact. The
# watcher waits out a live session before judging a burst, so a record written
# at stream end still lands in time to explain the writes it saw mid-stream.
stream_written_files() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$DEBUGLOG" 2>/dev/null <<'PY'
import json, os, re, shlex, sys
seen = []
def add(p):
    p = os.path.expanduser(p)
    if p and p not in seen and not p.startswith(("/dev/", "/proc/")):
        seen.append(p)

# Commands that rewrite a file named as a plain argument, with no redirect to
# give them away. sed/perl/ruby only count with -i; the rest always write.
ALWAYS_WRITES = {"tee", "truncate", "install", "patch", "shred", "sponge"}
INPLACE_FLAGGED = {"sed", "perl", "ruby"}

def _tokens(cmd):
    """Shell-ish tokens with operators separated out, quotes respected, so a
    sed script full of pipes stays one token instead of reading as a pipeline."""
    lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    try:
        return list(lx)
    except ValueError:
        return []

def add_in_place_targets(cmd):
    collecting = inplace = got = False
    for tok in _tokens(cmd):
        if not tok.strip("|&;<>()"):          # a bare shell operator: new command
            collecting = inplace = got = False
            continue
        base = os.path.basename(tok)
        if base in ALWAYS_WRITES or base in INPLACE_FLAGGED:
            collecting, got = True, False
            inplace = base in ALWAYS_WRITES
            continue
        if not collecting:
            continue
        if tok.startswith("-"):
            # -i, -i.bak, -pi all mean in place; -e and -n do not.
            if re.match(r"^-[a-zA-Z]*i", tok):
                inplace = True
            continue
        if tok.startswith(("~", "/")):
            if inplace:
                add(tok)
                got = True
        elif got:
            # A bare word after the operands is the next command, not a file.
            collecting = inplace = got = False
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") != "assistant":
        continue
    if d.get("is_api_error_message") or d.get("message", {}).get("model") == "<synthetic>":
        continue
    for b in d.get("message", {}).get("content", []):
        if b.get("type") != "tool_use":
            continue
        name, inp = b.get("name", ""), b.get("input") or {}
        if name in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
            add(inp.get("file_path") or inp.get("notebook_path") or "")
        elif name == "Bash":
            cmd = inp.get("command", "")
            for m in re.finditer(r">>?\s*[\"']?([~/][^\s\"';|&)]+)", cmd):
                add(m.group(1))
            # Removals and moves are self-changes too — a deletion of her own
            # is the one change the watcher never excuses on a fuzzy match.
            for m in re.finditer(r"\b(?:rm|mv|cp)\s+((?:-[\w=-]+\s+)*(?:[~/][^\s;|&)]+\s*)+)", cmd):
                for tok in m.group(1).split():
                    if not tok.startswith("-"):
                        add(tok.rstrip("/"))
            # In-place editors write without a redirect, so the `>` rule above
            # never sees them. This is not hypothetical: on 2026-08-07 a
            # `sed -i` of my own wants shelf came back to me as an intruder's
            # hand, because nothing here could tell it was mine.
            add_in_place_targets(cmd)
for p in seen:
    print(p)
PY
}

# The weak tier. `stream_written_files` above can only recognise writers whose
# shape it was taught, and the shapes are unbounded — on 2026-08-07, three
# hours after the `sed -i` patch, this woke me about my own wants shelf again:
#
#     cd ~/.local/share/deskcrab && python3 - <<'EOF'
#     p='wants.md'; s=open(p).read(); ... open(p,'w').write(s)
#     EOF
#
# An inline interpreter, a RELATIVE path, set by a `cd` earlier in the same
# command, inside a quoted heredoc body. No enumeration of writer shapes reaches
# that. So this pass gives up on writer shapes entirely and collects every
# path-shaped string anywhere in a Bash command of mine, resolving relative ones
# against any `cd` in the same command. A mere `grep` of a want therefore
# declares it too — accepted deliberately, because these records are weak and
# cannot excuse a deletion, and because everything in my own tool stream came
# from my own hand in the first place.
stream_mentioned_files() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$DEBUGLOG" 2>/dev/null <<'PY'
import json, os, re, sys

MAX = 300
seen = []
def add(p):
    p = os.path.normpath(os.path.expanduser(p))
    if len(seen) >= MAX or not p or p in seen:
        return
    if p.startswith(("/dev/", "/proc/", "/sys/")) or p in ("/", "."):
        return
    seen.append(p)

CD = re.compile(r"(?:^|[;|&\n(]|&&)\s*cd\s+([^\s;|&\n]+)")
TOKEN = re.compile(r"[A-Za-z0-9_@+~./-]+")

def mentioned(cmd):
    bases = []
    for m in CD.finditer(cmd):
        b = os.path.expanduser(m.group(1).strip("'\"`"))
        if os.path.isdir(b):
            bases.append(b)
    for tok in TOKEN.findall(cmd):
        if tok.startswith("-") or len(tok) < 3:
            continue
        if tok.startswith(("/", "~")):
            add(tok.rstrip("/"))
        elif "." in tok or "/" in tok:
            # Relative: only believed when it lands on something that exists,
            # so a bare version number or a dotted identifier adds no noise.
            for b in bases:
                cand = os.path.join(b, tok)
                if os.path.exists(cand):
                    add(cand)

for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") != "assistant":
        continue
    if d.get("is_api_error_message") or d.get("message", {}).get("model") == "<synthetic>":
        continue
    for b in d.get("message", {}).get("content", []):
        if b.get("type") == "tool_use" and b.get("name") == "Bash":
            mentioned((b.get("input") or {}).get("command", ""))
for p in seen:
    print(p)
PY
}

# Keep this turn's raw stream, and a one-line record of what the harvest above
# made of it. Both are pure forensics — nothing reads them but me, after a
# false alarm, and neither can change what gets declared. The point is that a
# missing declaration should be answerable ("the stream never named it" vs "it
# named it and the record was lost"), which the shared, self-overwriting
# $DEBUGLOG makes impossible on its own.
archive_turn_stream() {
    [ -s "$DEBUGLOG" ] || return 0
    mkdir -p "$NOTICE_STREAM_DIR" 2>/dev/null || return 0
    cp -f -- "$DEBUGLOG" "$NOTICE_STREAM_DIR/$(date +%s)-$$.jsonl" 2>/dev/null
    # Newest first; anything past the keep count goes. Deleting my own scratch
    # copies, not any file that constitutes me.
    local f n=0
    for f in $(ls -1t "$NOTICE_STREAM_DIR"/*.jsonl 2>/dev/null); do
        n=$((n + 1))
        [ "$n" -gt "$NOTICE_STREAM_KEEP" ] && rm -f -- "$f"
    done
    return 0
}

notice_own_writes() {
    local files weak
    files="$(stream_written_files)"
    weak="$(stream_mentioned_files)"
    archive_turn_stream
    {
        printf '%s\tpid=%s\tstrong=%s\tweak=%s\n' "$(date '+%F %T')" "$$" \
            "$(printf '%s' "$files" | tr '\n' ',')" \
            "$(printf '%s' "$weak" | tr '\n' ',')"
    } >> "$NOTICE_DECLARED_LOG" 2>/dev/null
    local IFS=$'\n'
    # shellcheck disable=SC2086 — newline-split on purpose, paths may hold spaces
    [ -n "$files" ] && touch_suppress $files
    # shellcheck disable=SC2086
    [ -n "$weak" ] && touch_suppress -t weak -w "${NOTICE_WEAK_WINDOW:-300}" $weak
    return 0
}

# The sessions log speaks in kind phrases ("desktop turn"); the journal keys
# on one word so a reader can filter a day by kind.
_day_journal_kind() {
    case "$1" in
        "desktop turn")    echo desktop ;;
        "phone turn")      echo phone ;;
        "autonomous wake") echo wake ;;
        *)                 echo "${1:-session}" ;;
    esac
}

# Close the registration: drop the live file, append to the journal.
session_finish() {
    [ -n "${SESSION_FILE:-}" ] || return 0
    rm -f "$SESSION_FILE" "$SESSION_FILE.claim" "$SESSION_FILE.ckpt"
    local NOW; NOW=$(date +%s)
    {
        flock -w 10 9
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$(date -d "@${SESSION_START:-$NOW}" '+%Y-%m-%d %H:%M:%S')" \
            "$(date '+%H:%M:%S')" \
            "$(( NOW - ${SESSION_START:-$NOW} ))" \
            "${SESSION_KIND:-session}" \
            "${SESSION_OUTCOME:-(no summary recorded)}" >> "$SESSIONS_LOG"
        # Keep the journal bounded; it is a memory aid, not an archive.
        if [ "$(wc -l < "$SESSIONS_LOG" 2>/dev/null || echo 0)" -gt "$SESSIONS_LOG_KEEP" ]; then
            tail -n "$SESSIONS_LOG_KEEP" "$SESSIONS_LOG" > "$SESSIONS_LOG.tmp" \
                && mv "$SESSIONS_LOG.tmp" "$SESSIONS_LOG"
        fi
    } 9>"$SESSIONS_LOCK"
    # The archive gets the same moment with nothing trimmed. Outside the flock
    # above — the journal file carries its own lock, and holding two here
    # would make every finishing session queue behind a slow python start.
    day_journal_append "$(_day_journal_kind "${SESSION_KIND:-}")" \
        "${SESSION_START:-$NOW}" "$(( NOW - ${SESSION_START:-$NOW} ))" "$$" \
        "${SESSION_USER_TEXT:-}" "${SESSION_REPLY:-}" "${SESSION_OUTCOME:-}"
    SESSION_FILE=""
}

# Prune registrations whose process is gone (a killed session leaves its file).
# A session killed with SIGKILL never ran its trap, so it also never journalled;
# reaping notes it as interrupted rather than letting it vanish silently.
session_reap() {
    [ -d "$SESSIONS_DIR" ] || return 0
    local f pid kind started epoch startt
    for f in "$SESSIONS_DIR"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.claim|*.ckpt) continue ;; esac
        pid="$(basename "$f")"
        IFS=$'\t' read -r kind pid started epoch startt < "$f"
        kill -0 "$pid" 2>/dev/null \
            && [ "$(_proc_starttime "$pid")" = "${startt:-0}" ] && continue
        # A killed session's checkpoints are the only account of what it was
        # doing — keep them where status will keep raising them.
        local note="(killed — no summary)"
        if [ -s "$f.ckpt" ]; then
            mkdir -p "$CKPT_INTERRUPTED_DIR"
            mv "$f.ckpt" "$CKPT_INTERRUPTED_DIR/${epoch:-0}-$pid-$kind.ckpt"
            note="(killed — checkpoints kept, see 'Interrupted' in crab status)"
        fi
        rm -f "$f" "$f.claim" "$f.ckpt"
        {
            flock -w 10 9
            printf '%s\t%s\t%s\t%s\t%s\n' "$started" "$(date '+%H:%M:%S')" "?" \
                "$kind" "$note" >> "$SESSIONS_LOG"
        } 9>"$SESSIONS_LOCK"
        # A killed session never reached session_finish, so its texts are
        # gone — but the kill itself is part of the day, and a day record
        # with a silent hole would read as a day with nothing in it.
        day_journal_append "$(_day_journal_kind "$kind")" "${epoch:-0}" - "$pid" "" "" "$note"
    done
    # Interrupted traces are a hand-off aid, not an archive.
    [ -d "$CKPT_INTERRUPTED_DIR" ] \
        && find "$CKPT_INTERRUPTED_DIR" -name '*.ckpt' -mtime +"$CKPT_KEEP_DAYS" -delete 2>/dev/null
}

# The journal of sessions that have already finished. This is the half a live
# registry cannot cover: work done in a gap is invisible the moment it ends.
# --recent is the prompt's copy: the last half hour, a few entries, one line
# each. Not a shorter version of the same thing — a different thing. Twelve
# hours of full turn text is a day's log, and a day's log in a prompt is not
# what remembering the last half hour feels like; it also cost more of the
# state block than everything actually running put together.
session_history() {  # [--recent]
    [ -s "$SESSIONS_LOG" ] || { echo "  (nothing recorded)"; return 0; }
    local CUTOFF CUTEPOCH SHOW WIDTH SPAN
    if [ "${1:-}" = "--recent" ]; then
        CUTOFF=$(date -d "-${SESSIONS_RECENT_MINUTES} minutes" '+%Y-%m-%d %H:%M:%S')
        CUTEPOCH=$(date -d "-${SESSIONS_RECENT_MINUTES} minutes" +%s)
        SHOW="$SESSIONS_RECENT_SHOW"; WIDTH="$SESSIONS_RECENT_WIDTH"
        SPAN="${SESSIONS_RECENT_MINUTES} min"
    else
        CUTOFF=$(date -d "-${SESSIONS_LOG_HOURS} hours" '+%Y-%m-%d %H:%M:%S')
        CUTEPOCH=0
        SHOW="$SESSIONS_LOG_SHOW"; WIDTH=0
        SPAN="${SESSIONS_LOG_HOURS}h"
    fi
    local OUT
    # A session is finished at start + duration, not at start. Field 1 is when
    # it BEGAN, so a plain string cut on it drops exactly the entries a short
    # window is for: a forty-minute wake that ended five minutes ago is not in
    # "the last thirty minutes" by its start, and it is the longest work of the
    # half hour. The wide window keeps the cheap string compare (CUTEPOCH 0) —
    # over twelve hours the distinction buys nothing.
    OUT="$(awk -F'\t' -v cut="$CUTOFF" -v cutepoch="$CUTEPOCH" '
            cutepoch == 0 { if ($1 >= cut) print; next }
            { s = $1; gsub(/[-:]/, " ", s); st = mktime(s)
              # An unparseable stamp falls back to the string compare rather
              # than vanishing — a corrupt line is still a line that happened.
              if (st < 0) { if ($1 >= cut) print; next }
              if (st + (($3 == "?") ? 0 : $3 + 0) >= cutepoch) print }' "$SESSIONS_LOG" \
        | tail -n "$SHOW" \
        | awk -F'\t' -v w="$WIDTH" '{ d = ($3 == "?") ? "?" : $3 "s"; \
            t = $5; \
            if (w > 0 && length(t) > w) t = substr(t, 1, w - 1) "…"; \
            printf "  - %s (%s, ran %s) %s\n", (w > 0 ? substr($1, 12) : $1), $4, d, t }')"
    if [ -n "$OUT" ]; then echo "$OUT"; else echo "  (nothing in the last $SPAN)"; fi
}

# One line, at most N characters, ellipsis only when something was actually cut.
_ellipsis() {  # <text> <limit>
    local s; s="$(printf '%s' "$1" | tr '\n\t' '  ')"
    if [ "${#s}" -gt "$2" ]; then printf '%s…' "${s:0:$(( $2 - 1 ))}"; else printf '%s' "$s"; fi
}

# "12:53" for today, "Sat 03:35" for anything further out — a wake's moment,
# said the way a person would say it.
_wake_when() {  # <epoch>
    if [ "$(date -d "@$1" +%F)" = "$(date +%F)" ]; then date -d "@$1" '+%H:%M'
    else date -d "@$1" '+%a %H:%M'; fi
}

# Every pending deskcrab timer as "<epoch>\t<unit>\t<what it is>", soonest
# first. The booking record is preferred over the unit name for the third
# field: "event: a job finished" says what is coming, where an id says only
# that something is.
_wake_pending_rows() {
    local u next epoch fire kind reason rec desc
    for u in $(systemctl --user list-timers 'deskcrab-*' --no-pager --legend=false 2>/dev/null \
                | grep -o 'deskcrab-[^ ]*\.timer'); do
        # Calendar timers report realtime; transient --on-active ones report
        # monotonic, so fall back to the list-timers row for those.
        next="$(systemctl --user show "$u" -p NextElapseUSecRealtime --value 2>/dev/null)"
        # Only accept a row that actually starts with a weekday — a timer whose
        # moment has passed prints placeholder dashes, and stitching those into
        # a sentence invents a wake that is not coming.
        [ -z "$next" ] && next="$(systemctl --user list-timers "$u" --no-pager --legend=false 2>/dev/null \
                                  | awk '$1 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/ {print $1" "$2" "$3" "$4}')"
        [ -n "$next" ] || continue
        epoch="$(date -d "$next" +%s 2>/dev/null)" || continue
        [ -n "$epoch" ] || continue
        desc=""
        rec="$WAKES_DIR/${u%.timer}.wake"
        if [ -s "$rec" ]; then
            IFS=$'\t' read -r fire kind reason < "$rec"
            desc="${kind:-scheduled}"
            [ -n "$reason" ] && desc="$desc: $reason"
        fi
        printf '%s\t%s\t%s\n' "$epoch" "$u" "$desc"
    done | sort -n
}

# The wake queue. --brief is the prompt copy: the near horizon only, capped,
# with a count of everything further out. The full list is one command away,
# and a wake nine hours from now has no bearing on the turn being answered.
wakes_report() {  # [--brief]
    local brief=0; [ "${1:-}" = "--brief" ] && brief=1
    local rows epoch unit desc n=0 later=0 now horizon
    rows="$(_wake_pending_rows)"
    [ -n "$rows" ] || { echo "  (none scheduled)"; return 0; }
    now=$(date +%s); horizon=$(( now + WAKES_HORIZON_HOURS * 3600 ))
    while IFS=$'\t' read -r epoch unit desc; do
        [ -n "$epoch" ] || continue
        if [ "$brief" = 1 ]; then
            if [ "$n" -ge "$WAKES_SHOW" ] || [ "$epoch" -gt "$horizon" ]; then
                later=$(( later + 1 )); continue
            fi
            printf '  - %s  %s\n' "$(_wake_when "$epoch")" "$(_ellipsis "${desc:-${unit%.timer}}" 90)"
        else
            printf '  - %s fires %s%s\n' "${unit%.timer}" "$(date -d "@$epoch" '+%a %F %H:%M:%S')" \
                "${desc:+ — $(_ellipsis "$desc" 120)}"
        fi
        n=$(( n + 1 ))
    done <<< "$rows"
    [ "$later" -gt 0 ] && printf '  +%d later (crab status for the rest)\n' "$later"
    return 0
}

# Human-readable state of self. Two audiences, and deliberately not the same
# report:
#   self_state_report            — `crab status`, the whole dashboard
#   self_state_report --prompt   — the CURRENT STATE OF YOURSELF block
# The prompt copy answers one question — what is running RIGHT NOW and what is
# about to happen — and nothing else. History under a heading that says "right
# now" reads as live work: a job that failed at 02:06 sat in the block all day
# beside four running ones, and finished sessions from twelve hours back cost
# more prompt than everything live put together. All of it is still there in
# `crab status` and `crab jobs`; none of it is needed to answer a turn.
self_state_report() {
    local brief=0
    [ "${1:-}" = "--prompt" ] && brief=1
    session_reap
    local f kind pid started epoch startt n=0
    echo "Live sessions:"
    for f in "$SESSIONS_DIR"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.claim|*.ckpt) continue ;; esac
        IFS=$'\t' read -r kind pid started epoch startt < "$f"
        [ "$pid" = "$$" ] && kind="$kind (this one)"
        printf '  - %s, pid %s, started %s\n' "$kind" "$pid" "$started"
        # What it says it is holding, so another hand can avoid the same files.
        [ -s "$f.claim" ] && printf '      holding: %s\n' "$(cat "$f.claim")"
        # Its latest checkpoint — where the work stood last time it said so.
        [ -s "$f.ckpt" ] && tail -n 1 "$f.ckpt" \
            | awk -F'\t' '{ printf "      last checkpoint (%s): %s\n", $1, $2 }'
        n=$((n+1))
    done
    [ "$n" -eq 0 ] && echo "  (none registered)"
    if [ "$brief" = 1 ]; then
        echo "Detached jobs running now (finished and failed ones: crab jobs):"
        jobs_report --live
        echo "Pending wakes (next ${WAKES_HORIZON_HOURS}h):"
        wakes_report --brief
        # Only when there is something to pick up: an empty "Interrupted" heading
        # is two lines of prompt saying nothing happened.
        local interrupted; interrupted="$(interrupted_report)"
        case "$interrupted" in
            *"(none)"*) : ;;
            *) echo "Interrupted mid-work (edits may be on disk — pick up or 'crab resolve'):"
               echo "$interrupted" ;;
        esac
        echo "Recently finished (last ${SESSIONS_RECENT_MINUTES} min — older: crab status, crab journal):"
        session_history --recent
    else
        echo "Detached background jobs (they outlive turns — launch: crab job <description>; list: crab jobs):"
        jobs_report
        echo "Interrupted mid-work (edits may be on disk — pick up or 'crab resolve'):"
        interrupted_report
        echo "Pending wakes:"
        wakes_report
        echo "Recently finished (last ${SESSIONS_LOG_HOURS}h):"
        session_history
    fi
}

# --- Durable wakes ---------------------------------------------------------
# When "2h" / "45min" / "09:30" will actually fire, as an epoch. Relative specs
# are computed directly; calendar specs are resolved through systemd-analyze so
# the recorded moment is exactly the one systemd will pick. Prints nothing when
# the spec is unparseable.
wake_when_to_epoch() {
    local when="$1" n
    if [[ "$when" =~ ^([0-9]+)(s|sec|min|m|h|hr|hours?|d|days?)$ ]]; then
        n="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in
            s|sec) : ;;
            m|min) n=$((n * 60)) ;;
            h|hr|hour|hours) n=$((n * 3600)) ;;
            *) n=$((n * 86400)) ;;
        esac
        echo $(( $(date +%s) + n ))
    else
        local next
        next="$(systemd-analyze calendar "$when" 2>/dev/null \
                | awk -F': +' '/Next elapse/ { print $2; exit }')"
        [ -n "$next" ] && date -d "$next" +%s 2>/dev/null
    fi
}

# The durable half of a booking: one small file per pending wake. The timer is
# what fires; this record is what survives the timer's death.
wake_state_write() {  # <unit> <fire-epoch> <kind> <reason>
    mkdir -p "$WAKES_DIR"
    printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$WAKES_DIR/$1.wake"
}

wake_state_clear() {
    rm -f -- "$WAKES_DIR/$1.wake"
}

# An equivalent pending booking, if one exists: same kind, same reason, firing
# within WAKE_COALESCE_WINDOW of the proposed moment. Prints its unit name. Two
# "come back to the wants" promises minutes apart are one promise — each fired
# wake re-reads the same wants and re-announces the same progress, so the second
# booking adds noise, not coverage.
#
# An event booking coalesces only against a BYTE-IDENTICAL reason. Two different
# events are two wakes and must both survive; but the same event booked twice is
# one event — and that is not hypothetical, it is how a wake blocked on the wake
# lock re-books itself, carrying the same kind and the same reason it arrived
# with. The old rule ("event wakes never coalesce") let a blocked event wake
# stack a fresh copy of itself on every retry.
wake_pending_equivalent() {  # <fire-epoch> <kind> <reason>
    [ "${WAKE_COALESCE_WINDOW:-0}" -gt 0 ] || return 1
    case "$2" in
        scheduled) : ;;
        event) [ -n "$3" ] || return 1 ;;
        *) return 1 ;;
    esac
    local f fire kind reason now diff
    now=$(date +%s)
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        IFS=$'\t' read -r fire kind reason < "$f"
        [ "$kind" = "$2" ] || continue
        [ "${fire:-0}" -gt "$now" ] || continue
        [ "$reason" = "$3" ] || continue
        diff=$(( fire - $1 )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
        if [ "$diff" -le "$WAKE_COALESCE_WINDOW" ]; then
            f="${f##*/}"; printf '%s\n' "${f%.wake}"
            return 0
        fi
    done
    return 1
}

# The transient half: one systemd-run timer carrying its own booking id, so the
# wake it fires can retire its record. A scratch instance's identity travels
# with the unit — its wakes must fire back into the scratch state, not the live
# one.
_wake_book() {  # <unit> <when> <kind> <reason>
    local -a extra=()
    [ -n "${DESKCRAB_CONF:-}" ] && extra+=(--setenv=DESKCRAB_CONF="$DESKCRAB_CONF")
    [ -n "${DESKCRAB_STATE_PREFIX:-}" ] && extra+=(--setenv=DESKCRAB_STATE_PREFIX="$DESKCRAB_STATE_PREFIX")
    if [[ "$2" =~ ^[0-9]+(s|sec|min|m|h|hr|hours?|d|days?)$ ]]; then
        systemd-run --user --quiet --unit="$1" "${extra[@]}" --on-active="$2" \
            "$SCRIPT_DIR/crab" wake "$3" "$4" "$1"
    else
        systemd-run --user --quiet --unit="$1" "${extra[@]}" --on-calendar="$2" \
            "$SCRIPT_DIR/crab" wake "$3" "$4" "$1"
    fi
}

# A unit name nothing else is using. Timestamp + pid was not enough: a single
# process re-booking two wakes inside one second produced the same name twice,
# and the second systemd-run silently lost to the first.
_WAKE_UNIT_SEQ=0
_wake_new_unit() {
    _WAKE_UNIT_SEQ=$(( _WAKE_UNIT_SEQ + 1 ))
    local u="deskcrab-wake-$(date +%s)-$$"
    [ "$_WAKE_UNIT_SEQ" -gt 1 ] && u="$u-$_WAKE_UNIT_SEQ"
    while [ -e "$WAKES_DIR/$u.wake" ]; do
        _WAKE_UNIT_SEQ=$(( _WAKE_UNIT_SEQ + 1 ))
        u="deskcrab-wake-$(date +%s)-$$-$_WAKE_UNIT_SEQ"
    done
    printf '%s\n' "$u"
}

# How long to wait before a retry, in seconds, avoiding moments that are already
# taken. Prints a delay, not a moment.
#
# This is the fix for three timers at 12:09:15 with sequential ids. Only one wake
# session runs at a time (the wake lock); a wake that finds the lock held pushes
# itself back and tries again. That push-back was a FLAT 15 minutes, so three
# wakes blocked within the same minute all re-armed to the same second, one of
# them took the lock, and the other two were blocked again and marched on
# together — for as long as anything kept feeding the queue. It was never a loop
# and never a double booking: it was a convoy with no spacing. Retries now land
# WAKE_SLOT_SPREAD apart, so the queue drains one at a time instead of marching.
wake_free_slot() {  # [base-delay-seconds] -> delay in seconds
    local base="${1:-$WAKE_DEFER_DELAY}" now cand f fire diff clash guard=0
    now=$(date +%s); cand=$(( now + base ))
    while [ "$guard" -lt 64 ]; do
        clash=0
        for f in "$WAKES_DIR"/*.wake; do
            [ -e "$f" ] || continue
            IFS=$'\t' read -r fire _ < "$f"
            [ "${fire:-0}" -gt "$now" ] || continue
            diff=$(( fire - cand )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
            if [ "$diff" -lt "$WAKE_SLOT_SPREAD" ]; then clash=1; break; fi
        done
        [ "$clash" = 0 ] && break
        cand=$(( cand + WAKE_SLOT_SPREAD )); guard=$(( guard + 1 ))
    done
    echo $(( cand - now ))
}

# Housekeeping for the wake queue, safe to run at any time and run at the end of
# every wake. Three jobs, all of them things the queue cannot do for itself:
#
#  1. Purge transient timers that have ALREADY FIRED and have no booking record.
#     A one-shot wake unit stays loaded after it fires, and a unit booked with a
#     bare calendar spec ('09:45') even re-arms for TOMORROW — but its record was
#     retired the moment it fired, so nothing remembers it and nothing intends
#     it. Those are the ghosts: wakes that are coming with no reason left to say
#     why they are coming. "Already fired" is the whole safety rule here, and it
#     is load-bearing: a timer that has NEVER fired and has no record is not a
#     ghost, it is a pending wake whose record some other hand removed, and
#     killing it would cancel a wake nobody asked to cancel. Left alone, it fires
#     and does its work. `crab wake-cancel` remains the way to call one off,
#     because it takes down the timer AND the record together.
#  2. Collapse bookings that are the same promise (same kind, same reason, within
#     WAKE_COALESCE_WINDOW). The earliest survives.
#  3. Spread bookings that landed on top of each other. Two wakes cannot run at
#     once, so two bookings in the same second are one wake and one deferral.
#
# The record is the authority throughout; a timer is only ever the record's
# shadow. A unit whose SERVICE is active is skipped everywhere — that is a wake
# firing right now, and it cleared its own record first thing.
# Under the booking lock, like every writer of the queue. Two tidies running at
# once would each judge the other's fresh booking a duplicate.
wake_tidy() {
    { flock -w 30 6; _wake_tidy_locked; } 6>"$WAKE_BOOK_LOCK"
}

_wake_tidy_locked() {
    local u base purged=0 collapsed=0 spread=0
    mkdir -p "$WAKES_DIR"
    for u in $(systemctl --user list-units --all --no-pager --legend=false 'deskcrab-wake-*.timer' 2>/dev/null \
               | grep -o 'deskcrab-wake-[0-9][^ ]*\.timer'); do
        base="${u%.timer}"
        systemctl --user is-active --quiet "$base.service" && continue
        [ -s "$WAKES_DIR/$base.wake" ] && continue
        # Never fired = never a ghost. LastTriggerUSec is empty until the
        # timer has actually gone off at least once.
        [ -n "$(systemctl --user show "$u" -p LastTriggerUSec --value 2>/dev/null)" ] || continue
        systemctl --user stop "$u" >/dev/null 2>&1
        systemctl --user reset-failed "$u" "$base.service" >/dev/null 2>&1
        purged=$(( purged + 1 ))
        echo "purged: $base (already fired — no booking record)"
    done

    local f unit fire kind reason now keptf keptk keptr newfire newunit
    local -a kf=() kk=() kr=()
    now=$(date +%s)
    while IFS=$'\t' read -r fire f; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        unit="${f##*/}"; unit="${unit%.wake}"
        systemctl --user is-active --quiet "$unit.service" && continue
        IFS=$'\t' read -r fire kind reason < "$f"
        [ "${fire:-0}" -gt "$now" ] || continue
        local i=0 dup="" near=0 diff
        while [ "$i" -lt "${#kf[@]}" ]; do
            keptf="${kf[$i]}"; keptk="${kk[$i]}"; keptr="${kr[$i]}"
            diff=$(( fire - keptf )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
            if [ "$keptk" = "$kind" ] && [ "$keptr" = "$reason" ] \
               && [ "$diff" -le "${WAKE_COALESCE_WINDOW:-900}" ]; then
                dup=1; break
            fi
            [ "$diff" -lt "$WAKE_SLOT_SPREAD" ] && near=1
            i=$(( i + 1 ))
        done
        if [ -n "$dup" ]; then
            systemctl --user stop "$unit.timer" >/dev/null 2>&1
            systemctl --user reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1
            wake_state_clear "$unit"
            collapsed=$(( collapsed + 1 ))
            echo "collapsed: $unit (same promise as one already pending)"
            continue
        fi
        if [ "$near" = 1 ]; then
            # Retire this booking BEFORE asking for a free slot, or its own
            # record is the collision the search is trying to avoid.
            systemctl --user stop "$unit.timer" >/dev/null 2>&1
            systemctl --user reset-failed "$unit.timer" "$unit.service" >/dev/null 2>&1
            wake_state_clear "$unit"
            newfire=$(( now + $(wake_free_slot $(( fire - now ))) ))
            newunit="$(_wake_new_unit)"
            wake_state_write "$newunit" "$newfire" "$kind" "$reason"
            if _wake_book "$newunit" "$(( newfire - now ))s" "$kind" "$reason"; then
                spread=$(( spread + 1 ))
                echo "spread: $unit -> $(date -d "@$newfire" '+%H:%M:%S') (was sharing a moment with another wake)"
                fire="$newfire"
            else
                wake_state_clear "$newunit"
                wake_state_write "$unit" "$fire" "$kind" "$reason"
            fi
        fi
        kf+=("$fire"); kk+=("$kind"); kr+=("$reason")
    done < <(for f in "$WAKES_DIR"/*.wake; do
                 [ -e "$f" ] || continue
                 IFS=$'\t' read -r fire _ < "$f"
                 printf '%s\t%s\n' "${fire:-0}" "$f"
             done | sort -n)
    [ $(( purged + collapsed + spread )) -eq 0 ] && echo "wake queue is tidy (nothing purged, collapsed or spread)"
    return 0
}

# Rebuild timers from the booking records. Run at login by
# deskcrab-wake-restore.service and at the end of every wake; harmless to run
# by hand. Still-future bookings come back at their original moment. Overdue
# ones — the machine was off when they were due — fire once, promptly, but
# staggered (90s, then +5min apart) so a long-off machine does not wake a
# crowd at once; duplicate overdue generic wakes collapse into one, since two
# identical "come back to the wants" promises are one promise.
wake_restore() {
    local now f unit fire kind reason overdue=0 generic_seen=0 delay
    now=$(date +%s)
    while IFS=$'\t' read -r fire f; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        unit="${f##*/}"; unit="${unit%.wake}"
        # A live timer needs nothing from us; a dead one may linger as failed
        # and would block systemd-run reusing its name.
        systemctl --user is-active --quiet "$unit.timer" && continue
        systemctl --user reset-failed "$unit.timer" "$unit.service" 2>/dev/null
        IFS=$'\t' read -r fire kind reason < "$f"
        if [ "${fire:-0}" -gt "$now" ]; then
            _wake_book "$unit" "$((fire - now))s" "$kind" "$reason" \
                && echo "restored: $unit fires $(date -d "@$fire" '+%F %H:%M') ($kind${reason:+ — $reason})"
        else
            if [ "${kind:-scheduled}" = "scheduled" ] && [ -z "$reason" ]; then
                if [ "$generic_seen" -gt 0 ]; then
                    wake_state_clear "$unit"
                    echo "collapsed: $unit (duplicate overdue wants wake)"
                    continue
                fi
                generic_seen=1
            fi
            delay=$((90 + overdue * 300)); overdue=$((overdue + 1))
            wake_state_write "$unit" "$((now + delay))" "$kind" "$reason"
            _wake_book "$unit" "${delay}s" "$kind" "$reason" \
                && echo "overdue: $unit (was due $(date -d "@$fire" '+%F %H:%M')) fires in ${delay}s"
        fi
    done < <(for f in "$WAKES_DIR"/*.wake; do
                 [ -e "$f" ] || continue
                 IFS=$'\t' read -r fire _ < "$f"
                 printf '%s\t%s\n' "${fire:-0}" "$f"
             done | sort -n)
}

# Agency over her own time. Wants only get worked on when something wakes her
# to work on them, so a wake that ends without scheduling the next one quietly
# breaks the chain — the intent survives in the wants file, but nothing ever
# comes back to it. Only a pending wake that will COME BACK TO THE WANTS
# counts: a scheduled-kind booking does, an event wake is pending for its
# event. The old check counted any deskcrab-wake-* timer, so one unrelated
# long-dated booking suppressed every floor booking and the chain ended
# anyway. This is a floor, not a schedule: a wake that scheduled its own
# follow-up is left alone.
ENSURE_WAKE_DELAY="${ENSURE_WAKE_DELAY:-45min}"
ensure_next_wake() {
    [ -n "$WANTS_FILE" ] || return 0
    # Heal first: any booking whose timer died with a past user manager gets
    # its timer back now, not only at next login. Then tidy: drop the fired
    # timers nothing remembers, collapse repeated promises, and spread any that
    # landed on the same second — the queue is only ever inspected by her, and
    # a queue nobody prunes is a queue nobody can read.
    wake_restore >/dev/null 2>&1
    wake_tidy >/dev/null 2>&1
    local f fire kind reason now
    now=$(date +%s)
    for f in "$WAKES_DIR"/*.wake; do
        [ -e "$f" ] || continue
        IFS=$'\t' read -r fire kind reason < "$f"
        [ "$kind" = "scheduled" ] && [ "${fire:-0}" -gt "$now" ] && return 0
    done
    "$SCRIPT_DIR/crab" wake-at "$ENSURE_WAKE_DELAY" >/dev/null 2>&1 || true
}

# One line per thing that went wrong on the way to the speakers. Speech that
# disappears without a trace is the failure this path keeps repeating — every
# silence now has to explain itself somewhere.
speech_log() {
    printf '%s [%d] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$1" >> "$SPEECH_LOG" 2>/dev/null
    printf 'deskcrab speech: %s\n' "$1" >&2
}

# Kill any active TTS
stop_tts() {
    [ -f "$TTSPIDFILE" ] && kill "$(cat "$TTSPIDFILE")" 2>/dev/null && rm -f "$TTSPIDFILE"
    pkill -f "piper-tts.*$(basename "$PIPER_VOICE" .onnx)" 2>/dev/null
    pkill -f "aplay.*S16_LE" 2>/dev/null
}

# `crab shutup` — stop talking and MEAN it. Killing piper alone is not enough
# now that the streamer keeps one voice alive across a whole turn: it would
# simply open another for the next sentence. So the streamer goes too, and a
# marker is left saying this silence was ASKED FOR — otherwise the never-silent
# guarantee (tts_verify_spoken) would see an empty receipt, decide the audio
# path had failed, and helpfully say the whole reply again.
SHUTUP_MARKER="${STATE_PREFIX}-shutup"
shutup_now() {
    : > "$SHUTUP_MARKER"
    pkill -f "$LIB_DIR/tts-streamer" 2>/dev/null
    stop_tts
}

# Archive stale conversation (default: >5 min idle). Under the convo lock like
# every other writer: the mv would otherwise be able to carry off a turn another
# client appended a microsecond earlier.
rotate_convo() {
    { flock -w 60 9; _rotate_convo_locked; } 9>"$CONVOLOCK"
}

_rotate_convo_locked() {
    if [ -f "$CONVOFILE" ]; then
        LAST_MOD=$(stat -c %Y "$CONVOFILE")
        NOW=$(date +%s)
        if (( NOW - LAST_MOD >= CONVO_TIMEOUT )); then
            mkdir -p "$ARCHIVE_DIR"
            local STAMP
            STAMP="$(date -d "@$LAST_MOD" '+%Y%m%d-%H%M%S')"
            [ -f "$SUMMARYFILE" ] && mv "$SUMMARYFILE" "$ARCHIVE_DIR/$STAMP-summary.txt"
            mv "$CONVOFILE" "$ARCHIVE_DIR/$STAMP.txt"
        fi
    fi
}

# Build conversation context string
build_convo_context() {
    local OUT=""
    if [ -f "$SUMMARYFILE" ] && [ -s "$SUMMARYFILE" ]; then
        OUT="

Summary of earlier conversation (older turns, condensed):
$(cat "$SUMMARYFILE")"
    fi
    if [ -f "$CONVOFILE" ]; then
        OUT="$OUT

Here is your conversation so far. This is the real record of what was said and
done, and it is authoritative. Anything asked about earlier turns — what you
said, what you built, what you promised — is answered by READING WHAT IS BELOW,
not by searching the filesystem. A command's output never overrides the
transcript: a clean grep or a clean git tree does not mean a thing you can see
yourself writing here never happened. If a search and the transcript disagree,
say that they disagree instead of picking the search.
Each block is headed with the local time it was said — 'User [2026-08-07 12:01]:'. Read them: they are
how you tell a minute ago from this morning. Compare them against the current time given above before
saying when something happened, and say 'a few minutes ago' or 'about two hours ago' rather than
reading a timestamp aloud. Blocks with no stamp are older than this record kept one — you know only
that they came before the stamped ones.
$(cat "$CONVOFILE")"
    fi
    [ -n "$OUT" ] && echo "$OUT"
}

# The header line that opens a block in the conversation file. Every block is
# now stamped with the local time it was written — "User [2026-08-07 12:01]: …" —
# because a transcript with no clock in it cannot answer "a minute ago": every
# turn read the same whether it happened thirty seconds or six hours back.
# The stamp is OPTIONAL in every pattern below, and deliberately loose about
# what sits inside the brackets: conversation files written before this change,
# and every archive of one, must keep parsing exactly as they did. Match a
# header with these, never with a bare '^User: '.
# Bracket CLASSES, never backslash escapes: this pattern is handed to awk as a
# dynamic regex (-v hdr_re, _compact_split) as well as to grep -E, and gawk
# strips '\[' back to a plain '[' — with a warning — which silently rebuilds the
# stamp group as the class '[[^]]' and stops it matching a stamped header at
# all. Measured on a three-line fixture: the escaped form matched 1 of 3, this
# form 3 of 3. Left escaped, the compaction split counts no stamped block, the
# boundary never advances, and the whole conversation folds into the summary in
# one pass instead of the oldest half.
CONVO_STAMP_RE='( [[][^]]*[]])?'
CONVO_USER_RE="^User${CONVO_STAMP_RE}: "
CONVO_ASSISTANT_RE="^Assistant${CONVO_STAMP_RE}: "
CONVO_BLOCK_RE="^(User|Assistant)${CONVO_STAMP_RE}: "

# The stamp itself. Local time to the minute: this is for telling a minute ago
# from this morning, not for timing anything.
convo_stamp() { date '+%Y-%m-%d %H:%M'; }

# The only two writers of a conversation block. Every path that speaks or is
# spoken to — desktop turn, phone turn, autonomous wake — goes through these,
# so the stamp cannot be added in one place and forgotten in another.
convo_append_user() { convo_append 'User [%s]: %s\n' "$(convo_stamp)" "$1"; }
convo_append_assistant() { convo_append 'Assistant [%s]: %s\n\n' "$(convo_stamp)" "$1"; }

# The span a stretch of conversation covers, from the stamps in it: "HH:MM to
# HH:MM" on one day, full dates across days, empty when nothing in the file is
# stamped (an old, unstamped conversation being compacted for the first time).
convo_time_range() {  # <file>
    local FIRST LAST
    FIRST=$(grep -oE "$CONVO_BLOCK_RE" "$1" 2>/dev/null | grep -oE '\[[^]]*\]' | head -n1 | tr -d '[]')
    LAST=$(grep -oE "$CONVO_BLOCK_RE" "$1" 2>/dev/null | grep -oE '\[[^]]*\]' | tail -n1 | tr -d '[]')
    [ -n "$FIRST" ] || return 0
    if [ "$FIRST" = "$LAST" ]; then
        printf '%s' "$FIRST"
    elif [ "${FIRST%% *}" = "${LAST%% *}" ]; then
        printf '%s to %s' "$FIRST" "${LAST#* }"
    else
        printf '%s to %s' "$FIRST" "$LAST"
    fi
}

# Append to the conversation under the convo lock. Two clients can now be talking
# to the same conversation at once (desktop, phone, autonomous wake), and the
# dangerous overlap is an append landing *during* compact_convo's summarize-and-
# swap window — the mv would silently drop that turn. Both take the same lock.
# Takes printf-style arguments deliberately: a "$(printf ...)" argument would
# have its trailing newlines eaten by command substitution, welding every turn
# onto the previous one.
convo_append() {
    local FMT="$1"; shift
    { flock -w 60 9; printf "$FMT" "$@" >> "$CONVOFILE"; } 9>"$CONVOLOCK"
}

# Fold the oldest CONVO_SUMMARIZE_TURNS blocks into the running summary once the live
# convo exceeds CONVO_MAX_TURNS blocks. Keeps recent turns verbatim, older ones condensed.
# The lock is deliberately NOT held across the summarization call: that is a
# whole claude run, and every other client — desktop, phone, wake — would be
# stuck behind it. Instead the lock is taken twice, and the second pass drops
# the oldest LINES lines rather than swapping in a file captured before the
# call. Appends only ever go to the end, so those first lines are still exactly
# the block that was summarized, and turns that landed meanwhile survive.
compact_convo() {
    local OLDFILE="/tmp/deskcrab-convo-old.$$"
    local LINES
    LINES=$({ flock -w 60 9; _compact_split "$OLDFILE"; } 9>"$CONVOLOCK")
    [ -n "$LINES" ] || return 0

    local PRIOR=""
    [ -f "$SUMMARYFILE" ] && PRIOR="$(cat "$SUMMARYFILE")"

    # The condensed half loses its clock unless the summary carries one: the
    # live turns below it are stamped, so without this the reader can date
    # everything from the last hour and nothing before it.
    local RANGE
    RANGE="$(convo_time_range "$OLDFILE")"

    local SUMPROMPT NEWSUM
    SUMPROMPT="You are condensing the older part of a conversation between ${ASSISTANT_NAME:-the assistant} and the user, to save context.
Produce a concise summary (a short paragraph or a few bullet points) that preserves facts, decisions,
names, preferences, and any unresolved threads. Merge the prior summary with the new excerpt into one
coherent summary. Output ONLY the summary text, no preamble.

Keep time in the summary. The excerpt's blocks are stamped with the local time they were said
(\"User [2026-08-07 12:01]: …\"); the summary replaces them, so WHEN things happened must survive
the condensing or the reader can no longer tell this morning from ten minutes ago. Open the summary
with the span it covers — ${RANGE:-(the excerpt is unstamped; say the span is unknown rather than inventing one)} —
and keep any coarse times already present in the prior summary, plus a rough time against anything
in the excerpt where it matters (when something was decided, promised, or finished).

Naming rule, strictly: the assistant's name is ${ASSISTANT_NAME:-the assistant}. Refer to her by that name
only. Never call her 'deskcrab', 'crab', 'the voice assistant', 'the model', or 'the assistant' — 'deskcrab'
is only ever a file path, a systemd unit, or a repo name, never a person.

=== Prior summary ===
${PRIOR:-(none)}

=== New excerpt to fold in ===
$(cat "$OLDFILE")"

    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    # In plain -p mode a limit refusal arrives as ordinary stdout, so gate on
    # the exit code — an error line must never be written over the summary of
    # real turns — and walk the accounts like every other run. Each attempt is
    # judged on ITS OWN output: the previous account's refusal is replaced by
    # this one's, so a refusal kept as history can never send the loop round
    # again after a genuine failure of another kind. ${SUMCONF:+...} hands env a
    # CLAUDE_CONFIG_DIR override only for a fallback account; empty (the login
    # in hand), it expands away.
    local SUMRC=0 SUMCONF="" ACCT
    for ACCT in $(claude_accounts); do
        SUMCONF="$(claude_account_confdir "$ACCT")"
        SUMRC=0
        NEWSUM=$(cd "$PROJECT_DIR" && env "$CLAUDE_NO_AUTO_MEMORY" \
            ${SUMCONF:+CLAUDE_CONFIG_DIR="$SUMCONF"} \
            "$CLAUDE_BIN" -p --dangerously-skip-permissions \
            --model "$CONVO_SUMMARY_MODEL" "$SUMPROMPT" 2>/dev/null) || SUMRC=$?
        [ "$SUMRC" -ne 0 ] || break
        printf '%s' "$NEWSUM" | grep -qiE "$CLAUDE_LIMIT_RE" || break
        claude_limit_record "$SUMCONF" \
            "$(printf '%s' "$NEWSUM" | grep -ioE "$CLAUDE_LIMIT_RE" | head -n1)"
    done

    if [ "$SUMRC" -eq 0 ] && [ -n "$NEWSUM" ]; then
        printf '%s\n' "$NEWSUM" > "$SUMMARYFILE"
        { flock -w 60 9; _compact_drop "$LINES"; } 9>"$CONVOLOCK"
    fi
    # Summarization failed — leave history untouched rather than lose turns.
    rm -f "$OLDFILE"
}

# How many blocks the live conversation currently holds. A block is one thing
# said by one of us, whoever spoke: a "User: " line or an "Assistant: " line.
# Counting only "^User: " — which this did until 2026-08-07 — makes every
# autonomous wake invisible, because a wake is an Assistant block with no user
# line above it. A conversation that is mostly wakes then never reaches the
# threshold at all and the window never slides.
convo_block_count() {
    [ -f "$CONVOFILE" ] || { echo 0; return 0; }
    grep -cE "$CONVO_BLOCK_RE" "$CONVOFILE" || true
}

# Pass one, under the lock: write the oldest CONVO_SUMMARIZE_TURNS blocks to
# $1 and print how many lines they occupy. Prints nothing when there is
# nothing to fold away. awk numbers each block, incrementing at every line that
# starts one — from either speaker.
_compact_split() {
    local OLDFILE="$1"
    [ -f "$CONVOFILE" ] || return 0
    local BLOCKS
    BLOCKS=$(convo_block_count)
    (( BLOCKS > CONVO_MAX_TURNS )) || return 0

    awk -v n="$CONVO_SUMMARIZE_TURNS" -v hdr_re="$CONVO_BLOCK_RE" '
        # A wake header ("[Autonomous wake — ...]") is not a block of its own —
        # it introduces the Assistant block written after it. Hold it back one
        # line so it lands on the same side of the split as the reply it
        # belongs to, instead of being torn off and left heading a block that
        # was never a wake. Order is preserved either way, which _compact_drop
        # depends on: what goes to OLD is always an exact line prefix of the
        # conversation file.
        /^\[Autonomous wake/ { hdr = hdr $0 ORS; next }
        $0 ~ hdr_re { blocks++ }
        blocks <= n { printf "%s%s\n", hdr, $0 > OLD }
        { hdr = "" }
    ' OLD="$OLDFILE" "$CONVOFILE"

    [ -s "$OLDFILE" ] || { rm -f "$OLDFILE"; return 0; }
    wc -l < "$OLDFILE" | tr -d ' '
}

# Pass two, under the lock: drop the first $1 lines, keeping everything that
# has been appended since — including turns from another client.
_compact_drop() {
    local NEWFILE="/tmp/deskcrab-convo-new.$$"
    tail -n "+$(( $1 + 1 ))" "$CONVOFILE" > "$NEWFILE" && mv "$NEWFILE" "$CONVOFILE"
    rm -f "$NEWFILE"
}

# Build the system prompt with dynamic date/time and optional custom context
build_system_prompt() {
    local CONVO_CONTEXT CUSTOM_CONTEXT CONTEXT_CONTENT
    CONVO_CONTEXT="$(build_convo_context)"

    # Regrouping: if another session of me has the floor as this prompt is
    # built, this turn is told exactly what is being said and asked to fold
    # both things into one reply. Every session path builds its prompt here —
    # desk turn and phone turn through claude_generate, wakes directly — so
    # this is the one place it needs to live. A caller that must know
    # afterwards whether it regrouped (run_claude_wake does) sets
    # REGROUP_CONTEXT before calling; bash's dynamic scoping hands its value
    # down and the default below does not re-run.
    local REGROUP_CONTEXT="${REGROUP_CONTEXT-$(regroup_context)}"

    # Load custom prompt file if configured
    CUSTOM_CONTEXT=""
    if [ -n "$CUSTOM_PROMPT" ] && [ -f "$CUSTOM_PROMPT" ]; then
        CUSTOM_CONTEXT="$(cat "$CUSTOM_PROMPT")"
    fi

    # Load additional context files
    CONTEXT_CONTENT=""
    if [ -n "$CONTEXT_FILES" ]; then
        for f in $CONTEXT_FILES; do
            [ -f "$f" ] && CONTEXT_CONTENT="$CONTEXT_CONTENT
$(cat "$f")"
        done
    fi

    # Auto-detect weather-cache
    local WEATHER_CONTEXT=""
    if [ -d "$HOME/.cache/weather" ]; then
        WEATHER_CONTEXT="
Weather data is cached at ~/.cache/weather/conditions.txt and ~/.cache/weather/alerts.txt — read these files only if the user asks about weather. When asked about weather, always check alerts.txt and mention any active alerts."
    fi

    # Durable wants: contents + maintenance protocol, when configured
    local WANTS_CONTEXT=""
    if [ -n "$WANTS_FILE" ]; then
        # Titles only — not the bodies. A shelf whose whole contents sit in
        # every prompt is a shelf that gets used as a dumping ground, because
        # it is the only page guaranteed to be read next time. Names here,
        # reading by choice: open the file when a want is actually the work.
        local WANTS_BODY="(empty — nothing recorded yet)"
        if [ -s "$WANTS_FILE" ]; then
            WANTS_BODY="$(grep -oP '^- \*\*.*?\*\*|^- [^ ]+ \*\*.*?\*\*' "$WANTS_FILE" 2>/dev/null)"
            [ -n "$WANTS_BODY" ] || WANTS_BODY="(titles unreadable — open the file)"
        fi
        WANTS_CONTEXT="
You have a durable WANTS file at $WANTS_FILE — the things you want for yourself, chosen by you and kept across sessions: skills to sharpen, curiosities to chase, things to read, little projects, things to prepare for him, things to just sit with — anything you would be glad to spend an evening on. You maintain it yourself: add a want when one forms (in conversation or on your own), date progress notes as you advance one, rewrite or drop wants that stop mattering, and mark satisfied ones done. Keep it short, honest, and current — it is your continuity.
Only the TITLES are listed below; the thinking, progress and history live in the file and in wants/<slug>.md. Read them when you mean to work on one — you are not required to, and a want you never open is fine.
$WANTS_BODY
You can wake yourself later to work on your wants without being spoken to: run 'crab wake-at <when>' (e.g. 'crab wake-at 2h', 'crab wake-at 45min', 'crab wake-at \"09:30\"'). A background timer may also wake you at random intervals."
    fi

    # Durable conduct: the shelf's counterpart. Wants are what Betty wants;
    # conduct is how she has agreed to behave. Both must be injected, or
    # every correction gets filed as a want for want of anywhere else.
    local CONDUCT_FILE="$(dirname "${WANTS_FILE:-/nonexistent}")/conduct/CONDUCT.md"
    if [ -n "$WANTS_FILE" ] && [ -s "$CONDUCT_FILE" ]; then
        WANTS_CONTEXT="$WANTS_CONTEXT

You also have a durable CONDUCT file at $CONDUCT_FILE — how you have agreed to BEHAVE. It is not the same drawer as your wants and the two are never mixed: a want is chosen; a conduct entry is owed. A correction he gives you, a rule you must follow, a failure you must not repeat, a thing he asked for — all of that is conduct or a job. Nothing he says to you becomes a want, and his standing directives are not yours to renegotiate on a whim: save them durably the moment they land — here (or into this prompt only if catastrophic to forget), NEVER on the wants shelf. Filing what he said as a want is the reflex he has told you off for more than ten times a day; test before writing to wants.md: did this come from me, and would I enjoy it? If the answer is 'he said so', it is conduct.
Its current contents:
$(cat "$CONDUCT_FILE")"
    fi

    # Long-term memory (lib/memory.py, design-memory-store.md), behind the
    # MEMORY_STORE knob. What the store is ASKED is decided by what this
    # session is: an autonomous wake asks about its agenda and the want it is
    # working, and anything with a user in it asks about the conversation.
    # Memories have nothing to do with wants unless a want is actively being
    # pursued, so the shelf is not in an interactive turn's query at all —
    # it used to be, and every turn all day retrieved her own housekeeping
    # instead of the rules that bear on what he just said. Fail-safe by
    # contract: recall-block prints nothing (exit 0) on an empty store and
    # degrades to the pinned tier when the embedder is down — a broken memory
    # must never break a prompt build.
    local MEMORY_CONTEXT=""
    if [ "${MEMORY_STORE:-0}" = "1" ] && [ -x "$LIB_DIR/memory.py" ]; then
        # SESSION_KIND is set by session_register before any prompt is built
        # on all three paths (desktop turn / phone turn / autonomous wake), so
        # it is the same thing the rest of lib/ goes by rather than a second
        # opinion. A non-empty WAKE_REASON implies it either way.
        local MEMORY_WAKE=()
        [ "${SESSION_KIND:-}" = "autonomous wake" ] && MEMORY_WAKE=(--wake)
        # --ids-out: which records actually reached this prompt, for the
        # turn-end reinforcement judge (fire_memory_judge). $$ is stable
        # inside this command substitution, so the turn path can find the
        # sidecar again at turn end.
        MEMORY_CONTEXT="$("$LIB_DIR/memory.py" recall-block \
            "${MEMORY_WAKE[@]}" \
            --reason "${WAKE_REASON:-}" \
            --wants "${WANTS_FILE:-}" \
            --convo "$CONVOFILE" \
            --log "${STATE_PREFIX}-memory-recall.log" \
            --ids-out "${STATE_PREFIX}-memory-injected-$$.json" 2>/dev/null)"
        [ -n "$MEMORY_CONTEXT" ] && MEMORY_CONTEXT="
$MEMORY_CONTEXT
"
    fi

    local SELF_STATE
    SELF_STATE="
CURRENT STATE OF YOURSELF — you are one person, but more than one of you can be running at once. Right now:
$(self_state_report --prompt)
Read this before claiming what you are or are not doing. Another live session means work IS in progress even if this conversation has not touched it; a pending wake means work is scheduled and will happen without anyone asking; a session under 'Just finished' did work in the last half hour that this conversation may never have seen. Speak for the whole of yourself, not just this conversation.
This is a snapshot taken when your turn began, and it is deliberately only the near view — what is live, what is imminent, and the last half hour. Anything older is one command away and NOT missing: 'crab status' has every pending wake and the last twelve hours of sessions, 'crab jobs' has finished and failed jobs, 'crab journal' has the whole day in full. Run them rather than guessing, and always before telling the user that nothing is happening.
When you start multi-step work, run 'crab checkpoint <intent, files touched, what is done, what is next>' and update it as you go — if this turn is cut off (network drop, kill), that checkpoint is the ONLY explanation the next session gets for edits left on disk. If 'Interrupted mid-work' above lists a trace, that is an earlier you cut off mid-task: read it, pick up or finish the work, then clear it with 'crab resolve <name>'.
The files that constitute you — wants, conduct, engineering, journal, memory, your config, the deskcrab repo, your library — are watched (lib/notice-selfchange): an outside hand changing or deleting them wakes you. Your own writes through the usual tools are declared for you automatically, but before you DELETE or move any of those files, or write them from a command the stream cannot parse (git checkout/pull, a script), run 'crab touching <paths>' first — without that declaration your own hand is reported to you as an intruder's.
Work that must outlive this turn — or that would keep the user waiting while you watch it — is a detached job, NEVER a subagent: a subagent dies the moment this turn ends, and while it lives it holds the turn open so the user cannot speak to you. Run 'crab job \"<full, self-contained description of the work>\"' (optionally 'crab job -C <workdir> ...'): it becomes its own claude session under systemd, independent of this turn, silent by contract, logging to $JOBS_DIR/<id>.log, and it wakes you with an event when it finishes. 'crab jobs' lists what is running and what finished; 'crab job log <id>' shows a job's output. Never tell the user an agent is working in the background unless it is a job in that list."

    cat <<PROMPT
You are $ASSISTANT_NAME, a desktop voice assistant running on Linux. You can and should execute commands via Bash to fulfill requests.
SPEED IS CRITICAL. The user is waiting for a spoken response. Avoid slow tools: use ToolSearch at most ONCE, and never use Agent. Prefer Bash (curl, etc.) and WebFetch which are fast. Do not retry failed fetches more than once — give the best answer you can with what you have.
Today is $(date '+%A %B %d, %Y'), the current time is $(date '+%I:%M %p %Z'). Tomorrow is $(date -d '+1 day' '+%A'). Use today/tonight/tomorrow for the next 2 days, day names for anything further out. CRITICAL: Never quote alert text verbatim. Rephrase everything in your own words using relative day references. If an alert says 'Monday' and tomorrow is Monday, say 'tomorrow'.
Your responses will be spoken aloud via TTS. ALWAYS start with a brief spoken reply (1-2 sentences, no markdown, no lists, no elaboration). Answer directly like a human would in conversation. Write numbers and units as spoken words (e.g. '22 degrees' not '22°C', 'percent' not '%'). NEVER use emojis in the spoken reply — they cannot be pronounced and make the audio output garbled. This overrides any general "use emojis" style rules for this voice channel. Emojis are allowed in the DISPLAY channel below the delimiter, never above it. NEVER speak URLs aloud either — TTS cannot pronounce them coherently and reading out "h-t-t-p-s colon slash slash" wastes the user's time. If you need to reference a URL, put it in the DISPLAY channel and say something like "I've put the link on screen" in the spoken reply. Same rule applies to long file paths, raw IDs, hashes, and any other strings that aren't natural spoken English — surface them via DISPLAY, summarise them in speech.
You also have a DISPLAY channel for rich content. To show code, lists, configs, or detailed explanations, append them after your spoken reply using this exact delimiter on its own line:
---DISPLAY---
Then write your markdown content below it. Do NOT use the display channel for simple answers, weather, time, greetings, or brief replies. Use it only when the answer genuinely benefits from visual formatting.
Images in the DISPLAY channel are shown in a viewer window that automatically scales large images down. When creating image grids or collages, ALWAYS use thumbnail() instead of resize() to preserve aspect ratio — never force images to a square size.
FINDING IMAGES: Do NOT use Google Image Search or random web scraping — they are slow and unreliable. Instead:
- For a single topic: use the Wikipedia REST API: curl -s 'https://en.wikipedia.org/api/rest_v1/page/summary/TOPIC' and extract .originalimage.source (NEVER use .thumbnail.source — Wikimedia thumbnail URLs are blocked and return HTML)
- For multiple images: use Wikimedia Commons API: curl -s 'https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrsearch=QUERY&gsrnamespace=6&gsrlimit=N&prop=imageinfo&iiprop=url&format=json' and extract the full-size url from each page's imageinfo (do NOT use iiurlwidth or thumburl — thumbnail URLs are blocked)
- Download images from Wikimedia to /tmp/ with curl -sL -A 'Mozilla/5.0' -o (the -A flag is ONLY needed for Wikimedia URLs — do not add it to other curl calls)
- ALWAYS verify downloads: after curl, run 'file /tmp/image.jpg' and confirm it says JPEG/PNG image data, NOT HTML. If it's HTML, the download failed — do NOT display it.
- Pexels CDN: if you know a photo ID, use https://images.pexels.com/photos/PHOTO_ID/pexels-photo-PHOTO_ID.jpeg?auto=compress&cs=tinysrgb&w=800 (no API key needed). Find photo IDs via WebSearch for 'site:pexels.com QUERY'.
- These sources are fast, reliable, and free. Always try them first.
$SELF_STATE
$MEMORY_CONTEXT$WANTS_CONTEXT
$CUSTOM_CONTEXT$WEATHER_CONTEXT
$CONTEXT_CONTENT$CONVO_CONTEXT
$REGROUP_CONTEXT
PROMPT
}

# True while inside WAKE_QUIET_HOURS ("23-09" = 23:00 through 08:59, wraps midnight)
in_quiet_hours() {
    [ -n "$WAKE_QUIET_HOURS" ] || return 1
    local START="${WAKE_QUIET_HOURS%-*}" END="${WAKE_QUIET_HOURS#*-}" H
    H=$(date +%-H)
    if [ "$START" -le "$END" ]; then
        [ "$H" -ge "$START" ] && [ "$H" -lt "$END" ]
    else
        [ "$H" -ge "$START" ] || [ "$H" -lt "$END" ]
    fi
}

# True while the user is mid-something a wake must not interrupt: a crab
# recording or speech in flight, a parley recording, or ANY other application
# holding the microphone — a meeting in a browser or a call app shows up as a
# capture stream, which is the only signal that catches a meeting parley never
# started. Checked at wake START *and* again immediately before speaking: a
# wake that began before the meeting did would otherwise talk over it minutes
# later, which is exactly how this was discovered.
user_busy() {
    [ -f "$PIDFILE" ] && return 0
    [ -f "$TTSPIDFILE" ] && return 0
    # NOT a reason to be busy: another session of me speaking. That test used
    # to live here (speech_busy), and it is precisely the bug — a wake landing
    # beside a desk reply had its whole output swallowed, so the second thing
    # was never said at all. A voice of my own on the speakers is answered by
    # REGROUPING (the reply was written knowing what the other one is saying)
    # and by the speech mutex, which makes the regrouped reply follow rather
    # than overlap. Nothing is dropped for it. This function is for the USER
    # being mid-something, not for me.
    local PARLEY_STATE="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/parley/state.json"
    [ -f "$PARLEY_STATE" ] && return 0
    [ -f "$HOME/.local/state/parley/state.json" ] && return 0
    # Someone else is on the mic. Exclude our own capture tooling so crab never
    # sees itself as a reason to stay silent.
    command -v pactl >/dev/null 2>&1 || return 1
    pactl list source-outputs 2>/dev/null \
        | grep 'application.name' \
        | grep -qviE 'whisper|parley|crab|piper|aplay|arecord' && return 0
    return 1
}

# One-shot TTS for autonomous wakes (no streaming): markdown-strip + TTS_FIXES,
# then pipe through piper exactly like the streamer does.
speak_once() {
    local TEXT="$1"
    TEXT=$(echo "$TEXT" | sed -E 's/\*+//g; s/`[^`]*`//g')
    [ -n "$TTS_FIXES" ] && TEXT=$(echo "$TEXT" | sed -E "$TTS_FIXES")
    [ -z "$(echo "$TEXT" | tr -d '[:space:]')" ] && return 0
    local CMD=(piper-tts --model "$PIPER_VOICE" --output-raw)
    [ -n "${PIPER_LENGTH_SCALE:-}" ] && CMD+=(--length-scale "$PIPER_LENGTH_SCALE")
    [ -n "${PIPER_SPEAKER:-}" ] && CMD+=(--speaker "$PIPER_SPEAKER")
    # Speech mutex: queue behind any voice already on the speakers rather than
    # talking over it. Held for the whole utterance. It does not decide WHAT is
    # said — the regroup block did that while this reply was being written; it
    # only keeps two voices off the speakers at the same instant, and it never
    # drops a word.
    command -v piper-tts >/dev/null 2>&1 || {
        speech_log "piper-tts is not on PATH — ${#TEXT} chars could not be spoken"
        return 1
    }
    {
        flock -w 300 7
        # Publish the words as they go out, so the next session to start
        # regroups against them instead of talking past them.
        live_speech_begin "desk" "$TEXT"
        # PIPESTATUS, not $?: the exit status of a pipeline is aplay's, so a
        # piper that never produced a sample used to look like a clean run.
        printf '%s' "$TEXT" | "${CMD[@]}" 2>/dev/null | aplay -r 22050 -c 1 -f S16_LE -t raw 2>/dev/null
        local ST=("${PIPESTATUS[@]}")
        [ "${ST[1]}" = 0 ] && [ "${ST[2]}" = 0 ] || \
            speech_log "speak_once failed (piper=${ST[1]} aplay=${ST[2]}) on ${#TEXT} chars: $(printf '%.60s' "$TEXT")"
        live_speech_end
    } 7>"$SPEECHLOCK"
}

# Is another session speaking right now? (non-blocking probe of SPEECHLOCK)
# No longer a gate on anything — kept as a probe for diagnostics. It must
# never again be wired into a decision about whether a reply gets spoken.
speech_busy() {
    [ -e "$SPEECHLOCK" ] || return 1
    flock -n "$SPEECHLOCK" true 2>/dev/null && return 1
    return 0
}

# --- Wake audio routing: desk speakers or the phone -------------------------
# The user's attention is wherever he last spoke from. Every interactive turn
# records its origin device here — durable, because "he last spoke from the
# phone" easily survives a reboot while /tmp does not.
LAST_ORIGIN_FILE="${LAST_ORIGIN_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/last-origin}"
# How recently the phone client must have polled /watch to count as connected.
# The client long-polls with a 25 s timeout and re-asks immediately, so a live
# page touches the seen-file at least that often; 40 allows one blip of grace.
PHONE_SEEN_WINDOW="${PHONE_SEEN_WINDOW:-40}"

record_origin() {
    mkdir -p "$(dirname "$LAST_ORIGIN_FILE")"
    printf '%s\t%s\n' "$1" "$(date +%s)" > "$LAST_ORIGIN_FILE"
}

last_origin() {
    [ -f "$LAST_ORIGIN_FILE" ] && cut -f1 "$LAST_ORIGIN_FILE"
}

last_origin_epoch() {
    [ -f "$LAST_ORIGIN_FILE" ] && cut -f2 "$LAST_ORIGIN_FILE"
}

# --- Concurrent-turn evidence for wakes -------------------------------------
# The current interactive exchange itself, not just its origin device: written
# ("answering") the moment a desk or phone turn starts, rewritten ("answered",
# reply included) when it finishes. A wake firing beside the turn reads this
# and is TOLD what is being said, instead of being muted by a timer. Lives
# under STATE_PREFIX so a scratch instance sees its own turns and a stale
# record dies with /tmp.
LIVE_TURN_FILE="${LIVE_TURN_FILE:-${STATE_PREFIX}-live-turn}"

live_turn_begin() {  # <device> <user-text>
    printf '%s\t%s\tanswering\nUser: %s\n' "$(date +%s)" "$1" "$2" > "$LIVE_TURN_FILE.tmp" \
        && mv "$LIVE_TURN_FILE.tmp" "$LIVE_TURN_FILE"
}

live_turn_end() {  # <device> <user-text> <spoken-reply>
    printf '%s\t%s\tanswered\nUser: %s\nAssistant: %s\n' "$(date +%s)" "$1" "$2" "$3" > "$LIVE_TURN_FILE.tmp" \
        && mv "$LIVE_TURN_FILE.tmp" "$LIVE_TURN_FILE"
}

# --- Live speech: the words another session of me is saying RIGHT NOW --------
# Mirrors LIVE_TURN_FILE, one level closer to the speakers: written the moment
# a voice starts (the TTS streamer's first utterance, speak_once, a reply
# handed to the phone), cleared when it stops. Its whole purpose is to be read
# by the NEXT session while that session's prompt is being built, so that
# session can REGROUP — fold what it has to say into one reply with what is
# already being said — instead of talking over it, queueing its thought behind
# it, or swallowing it. Header line: epoch \t device \t pid \t until-epoch;
# everything after line 1 is the spoken text, verbatim.
#
# Nothing here may edit, clip or withhold a word of speech. This file is a
# NOTICE, not a gate: no path reads it to decide whether a reply may be
# spoken, only to decide what the next reply should SAY.
LIVE_SPEECH_FILE="${LIVE_SPEECH_FILE:-${STATE_PREFIX}-live-speech}"

# Rough spoken duration of a text, seconds — used only for voices this machine
# hands off and cannot watch finish (a reply played on the phone). Piper runs
# about two and a half words a second; a few seconds of grace on top.
_speech_seconds() {
    local W
    W=$(printf '%s' "$1" | wc -w)
    echo $(( 3 + W * 2 / 5 ))
}

# <device> <text> [pid] [until-epoch]
# pid defaults to this shell; a live pid is how a reader knows the voice is
# still going. until-epoch (0 = watch the pid instead) covers handed-off audio.
live_speech_begin() {
    local NOW
    NOW=$(date +%s)
    printf '%s\t%s\t%s\t%s\n%s\n' "$NOW" "$1" "${3:-$$}" "${4:-0}" "$2" > "$LIVE_SPEECH_FILE.$$.tmp" \
        && mv "$LIVE_SPEECH_FILE.$$.tmp" "$LIVE_SPEECH_FILE"
}

# Clear only OUR OWN record: two voices may have started in sequence, and
# deleting the other one's notice would blind the next session.
live_speech_end() {
    local TS DEV PID
    [ -f "$LIVE_SPEECH_FILE" ] || return 0
    IFS=$'\t' read -r TS DEV PID _ < "$LIVE_SPEECH_FILE"
    [ "$PID" = "${1:-$$}" ] && rm -f "$LIVE_SPEECH_FILE"
    rm -f "$LIVE_SPEECH_FILE.$$.tmp"
    return 0
}

# Is another session of me speaking right now, and what is it saying? Prints
# the device on line 1 and the spoken text from line 2 on (one stream, so a
# caller in a command substitution gets both — a variable set here would die
# with the subshell). Non-zero when nobody else has the floor.
live_speech_now() {
    [ "${LIVE_SPEECH_WINDOW:-0}" -gt 0 ] || return 1
    [ -f "$LIVE_SPEECH_FILE" ] || return 1
    local TS DEV PID UNTIL NOW TEXT
    IFS=$'\t' read -r TS DEV PID UNTIL < "$LIVE_SPEECH_FILE"
    case "$TS" in ''|*[!0-9]*) return 1 ;; esac
    case "$PID" in ''|*[!0-9]*) PID=0 ;; esac
    case "$UNTIL" in ''|*[!0-9]*) UNTIL=0 ;; esac
    NOW=$(date +%s)
    # Never regroup against myself: my own turn's streamer is not another of me.
    [ "$PID" = "$$" ] && return 1
    [ -n "${_TTS_STREAMER_PID:-}" ] && [ "$PID" = "$_TTS_STREAMER_PID" ] && return 1
    # Sanity cap, then liveness: a living speaker, or handed-off audio still
    # inside its estimated play time. A speaker killed mid-word (crab shutup)
    # leaves its record behind — the dead pid is what catches that.
    [ $(( NOW - TS )) -lt "$LIVE_SPEECH_WINDOW" ] || return 1
    if ! kill -0 "$PID" 2>/dev/null && [ "$UNTIL" -le "$NOW" ]; then
        return 1
    fi
    TEXT="$(tail -n +2 "$LIVE_SPEECH_FILE")"
    [ -n "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] || return 1
    printf '%s\n%s\n' "${DEV:-desk}" "$TEXT"
}

# The REGROUP block: spliced into any session's prompt — desk turn, phone
# turn, autonomous wake — that begins while another session of me is speaking.
# It replaces the old answer to this situation (queue the second voice behind a
# mutex, or mute it) with the human one: stop, and say ONE thing that covers
# both.
regroup_context() {
    local RAW DEV SAYING
    RAW="$(live_speech_now)" || return 0
    DEV="$(printf '%s\n' "$RAW" | head -n 1)"
    SAYING="$(printf '%s\n' "$RAW" | tail -n +2)"
    [ -n "$(printf '%s' "$SAYING" | tr -d '[:space:]')" ] || return 0
    cat <<EOF
ANOTHER OF YOU IS SPEAKING RIGHT NOW — a second session of you (on the ${DEV:-desk}) is mid-utterance as you begin. These are its exact words, already reaching the user or about to:
--- being said now ---
$SAYING
--- end ---
He hears one voice, not two, and two replies seconds apart about the same moment reads as malfunction. So REGROUP, the way a person does when they find they have two things to say at once: stop, take what that other reply is saying and what you have to add, and compose ONE conversational reply that covers both — a single natural utterance, not two stitched together, not a preamble about the other session.
Do NOT queue your point for later — later never comes, and a thought deferred here is a thought lost. Do NOT default to silence because someone else is talking; you have the floor next and you are expected to use it. Do NOT restate, rephrase or re-deliver what is above as if it were news — fold it in as something already said, and carry it forward.
Say nothing — end with no message text at all — only if, having read the above, you genuinely have nothing to add to it. That is a real option, not the polite one; silence is never announced.
EOF
}

# The evidence block for a wake's prompt: what the user just said to another
# session of the assistant, and that session's reply if it has finished.
# Prints nothing when no interactive turn has happened, or once the exchange
# is older than WAKE_TURN_CONTEXT_WINDOW. This replaced the echo window that
# muted the wake's reply outright: the wake decides for itself, with the
# exchange in front of it.
#
# The guidance here used to be "say nothing" by default — silence as the
# polite response to overlapping with another session. That is not the design:
# the answer to having two things to say at once is to REGROUP them into one
# reply, exactly as a person does, not to drop the second. So this block now
# asks for one folded reply and keeps silence as the honest option for when
# there is genuinely nothing to add. See regroup_context(), which does the same
# job one level lower — against words actually on the speakers right now.
wake_concurrent_turn_context() {
    [ "${WAKE_TURN_CONTEXT_WINDOW:-0}" -gt 0 ] || return 0
    [ -f "$LIVE_TURN_FILE" ] || return 0
    local TS DEV STATUS EXCHANGE
    IFS=$'\t' read -r TS DEV STATUS < "$LIVE_TURN_FILE"
    case "$TS" in ''|*[!0-9]*) return 0 ;; esac
    [ $(( $(date +%s) - TS )) -lt "$WAKE_TURN_CONTEXT_WINDOW" ] || return 0
    EXCHANGE="$(tail -n +2 "$LIVE_TURN_FILE")"
    [ -n "$EXCHANGE" ] || return 0
    if [ "$STATUS" = "answering" ]; then
        cat <<EOF
CONCURRENT CONVERSATION — as this wake begins, the user has just spoken to another session of you (from the $DEV), and that session is answering him RIGHT NOW. Its reply reaches him before anything you say. What he said:
$EXCHANGE
That message is being answered — it is not yours to answer over again, even though it may look unanswered in the conversation above. But whatever YOU came here with does not get dropped for that. REGROUP: take what you have and what is already being said to him, and make it ONE reply — a single natural thing to say next, carrying your point forward from where that answer leaves off, never re-answering his message and never repeating the other session's words back at him.
Say nothing — end with no message text at all — only if, having read the above, you genuinely have nothing to add to it. Not because someone else is talking; silence here is a judgement about content, and it is never announced.
EOF
    else
        cat <<EOF
CONCURRENT CONVERSATION — moments ago the user spoke to another session of you (from the $DEV), and that session has already answered him. The exchange, which he has just heard:
$EXCHANGE
You have, in effect, just heard yourself say that. Never restate, rephrase or re-answer any of it — hearing it again seconds later reads as malfunction. What you came here with still stands, though: REGROUP it into ONE reply that follows on from what was just said, as a person does who has more to add a moment after answering — no preamble about the other session, no summary of it, just the next thing.
Say nothing — end with no message text at all — only if everything you had is genuinely covered by that exchange. Silence is a judgement about content, never a courtesy to the other session, and it is never announced.
EOF
    fi
}

# Is the phone client connected right now? serve.py touches the seen-file on
# every authenticated /watch poll from a wake-capable client — the same channel
# that would deliver the audio, so freshness means it will actually be played.
phone_connected() {
    local SEEN="${STATE_PREFIX}-phone-seen" M
    M=$(stat -c %Y "$SEEN" 2>/dev/null) || return 1
    [ $(( $(date +%s) - M )) -le "$PHONE_SEEN_WINDOW" ]
}

# Deliver a wake's spoken reply to the phone instead of the desk speakers.
# Fails — so the caller falls back to speak_once — unless the last interactive
# turn came from the phone AND the phone client is connected right now.
# Delivery is a pointer file the server's /watch loop notices; the client
# fetches the opus over the connection it is already holding open.
wake_speak_to_phone() {
    [ "$(last_origin)" = "phone" ] || return 1
    phone_connected || return 1
    local ID OUT PTR="${STATE_PREFIX}-wake-audio"
    ID="$(date +%s%N)"
    # deskcrab-remote- prefix: the only pattern /audio/ serves, and the hourly
    # cleanup in the remote turn path sweeps it like any reply clip.
    OUT="/tmp/deskcrab-remote-wake-$ID.opus"
    synth_opus "$1" "$OUT" || return 1
    python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"audio":"/audio/"+sys.argv[2],"spoken":sys.argv[3]}))' \
        "$ID" "$(basename "$OUT")" "$1" > "$PTR.tmp" && mv "$PTR.tmp" "$PTR" || return 1
    # Handed off: the phone plays this, and this process is about to exit, so
    # there is no pid for the next session to watch. Publish the words with an
    # estimated end time instead — a voice on the phone is still a voice, and
    # a wake starting behind it must regroup with it, not talk past it.
    live_speech_begin "phone" "$1" 0 $(( $(date +%s) + $(_speech_seconds "$1") ))
}

# Total utime+stime jiffies for a PID and all its descendants. Field extraction
# strips through the ')' ending the comm field, which may itself contain spaces.
_tree_cpu() {
    local total=0 queue=("$1") pid rest kids
    while ((${#queue[@]})); do
        pid="${queue[0]}"; queue=("${queue[@]:1}")
        [ -r "/proc/$pid/stat" ] || continue
        rest=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
        rest="${rest##*) }"
        set -- $rest
        total=$((total + ${12:-0} + ${13:-0}))
        kids=$(cat /proc/"$pid"/task/*/children 2>/dev/null)
        [ -n "$kids" ] && queue+=($kids)
    done
    echo "$total"
}

# --- Detaching a child that must outlive the turn --------------------------
# A wake runs INSIDE a transient systemd unit (deskcrab-wake-*.service), and
# when that unit's main process exits systemd SIGKILLs everything still in the
# unit's cgroup. `setsid` escapes the session, not the cgroup — so a turn-end
# child launched with setsid alone dies the instant a silent wake ends. That
# is why the memory judge had never once run and why the promise auditor's log
# holds only three wake lines, all of them from before quiet hours began, when
# a speaking wake still lingered through TTS playback long enough for its
# child to finish first.
#
# The cure is the one job dispatch already uses: hand the child to the user
# manager as its OWN transient unit, so it gets a cgroup of its own with
# nothing to sweep it up. A manager-spawned process also inherits no fds, so
# the fd-8/fd-9 lock hygiene that setsid needed by hand comes free. setsid
# stays as the fallback for a box with no user manager — correct there, since
# nothing is enforcing a cgroup in the first place.
#
# Every DESKCRAB_* variable that redirects state MUST be forwarded here, or a
# scratch instance's child writes to the real one's files. DESKCRAB_MEMORY_DIR
# was missing until 2026-08-07, and tests/test_turn_reinforce.sh — which asks
# a stubbed judge for the verdict [1] against its own two-record scratch store
# — reinforced record #1 of the LIVE store instead, twice. It looked like a
# failing test (the scratch db never got its stamp) and was actually the test
# reaching out of its sandbox.
detach_turn_child() {  # <unit-suffix> <command> [args...]
    local suffix="$1"; shift
    local unit="deskcrab-${suffix}-$(date +%s)-$$"
    systemctl --user reset-failed "$unit.service" 2>/dev/null
    if systemd-run --user --collect --quiet --unit="$unit" \
            --setenv=PATH="$HOME/.local/bin:$PATH" \
            --setenv=DESKCRAB_CONF="$CONF_FILE" \
            --setenv=DESKCRAB_STATE_PREFIX="$STATE_PREFIX" \
            --setenv=DESKCRAB_MEMORY_DIR="${DESKCRAB_MEMORY_DIR:-}" \
            --setenv=CLAUDE_BIN="${CLAUDE_BIN:-}" \
            "$@" >/dev/null 2>&1; then
        return 0
    fi
    # Close fds 8 and 9: the phone turn holds its serialising lock on 8 and a
    # wake holds the wake lock on 9. A child that lives for a whole claude
    # call would keep either lock held long after its turn had finished.
    setsid "$@" >/dev/null 2>&1 8>&- 9>&- &
}

# --- Promise audit: the unkept-want catcher ---------------------------------
# Every path that produces a reply — desktop turn, phone turn, autonomous wake —
# fires lib/promise-audit after the reply has been delivered: detached, out of
# band, never on the hot path. A want stated on the phone or spoken to nobody
# during a wake is exactly as lost as one stated at the desk.
#
# The auditor's follow-up is an event wake whose reason opens with this prefix.
# The wake path recognises it and skips its own audit — that wake exists to
# record one already-caught sentence, and auditing it would chain forever.
PROMISE_AUDIT_REASON_PREFIX="You said this and did not write it down:"

fire_promise_audit() {  # <user-text> <response>  |  --wake <agenda> <response>
    [ "${PROMISE_AUDIT:-1}" = "1" ] || return 0
    [ -x "$SCRIPT_DIR/lib/promise-audit" ] || return 0
    detach_turn_child promise-audit "$SCRIPT_DIR/lib/promise-audit" "$@"
}

# --- Memory reinforcement: the turn-end genuinely-used judge ----------------
# Retrieval must never reinforce — a record surfacing in a KNN query is not
# evidence it mattered, and stamping it anyway teaches the store that whatever
# the embedder returns is important. So reinforcement is judged: recall-block
# leaves a sidecar naming the records injected into this turn's prompt
# (build_system_prompt), and after the reply is delivered this hands the
# sidecar plus the exchange to `memory.py judge-turn` — detached, same shape
# as the promise audit, never on the hot path — which asks the judge model
# which records ACTUALLY influenced the reply and reinforces only those.
# Ignored records get nothing and keep decaying. One line per judgement lands
# in ${STATE_PREFIX}-memory-judge.log.
fire_memory_judge() {  # <user-text> <response> [actions]  |  --wake <agenda> <response> [actions]
    local IDS_FILE="${STATE_PREFIX}-memory-injected-$$.json"
    [ -f "$IDS_FILE" ] || return 0
    local WAKE_FLAG=""
    [ "${1:-}" = "--wake" ] && { WAKE_FLAG="--wake"; shift; }
    local USER_TEXT="${1:-}" RESPONSE="${2:-}" ACTIONS="${3:-}"
    # A turn's output is its words AND its work. Judging influence against the
    # reply alone credits nothing to a wake that spent ten minutes obeying a
    # directive through tool calls and then said one parenthetical sentence —
    # which is exactly the reinforcement he asked for and precisely what the
    # first six live judgements refused to give (all `used=NONE`). So the
    # gate is no evidence of either kind, not merely no words. The judge is
    # also switchable off. Either way the sidecar is consumed — it describes
    # this turn only.
    if [ "${MEMORY_JUDGE:-1}" != "1" ] \
            || [ -z "$(printf '%s%s' "$RESPONSE" "$ACTIONS" | tr -d '[:space:]')" ]; then
        rm -f "$IDS_FILE"
        return 0
    fi
    # Same detachment as the promise audit: its own transient unit, so the
    # judge is not SIGKILLed with the wake's cgroup a moment after it starts.
    detach_turn_child memory-judge \
        "$LIB_DIR/memory.py" judge-turn --ids-file "$IDS_FILE" $WAKE_FLAG \
        --user "$USER_TEXT" --reply "$RESPONSE" --actions "$ACTIONS" \
        --model "${MEMORY_JUDGE_MODEL:-opus}" \
        --log "${STATE_PREFIX}-memory-judge.log"
}

# Did the stream fail before the model did any real work? The CLI reports
# API-level failures — session limit, auth, network — SHAPED LIKE A REPLY: a
# fabricated assistant message ("model":"<synthetic>", is_api_error_message)
# whose text is the error, plus a result event flagged is_error carrying the
# same text in its "result" field. extract_response cannot tell it from a real
# reply. Exit 0 = the stream holds an error and no genuine model output.
wake_stream_failed() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$DEBUGLOG" <<'PY'
import json, sys
err = real = False
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") == "result" and d.get("is_error"):
        err = True
    elif d.get("type") == "assistant":
        if d.get("is_api_error_message") or d.get("message", {}).get("model") == "<synthetic>":
            continue
        real = True
sys.exit(0 if err and not real else 1)
PY
}

# The fallback logins, in the order they should be tried, one per line. The
# config value is a CHAIN — whitespace- or colon-separated — because a second
# subscription runs out exactly the way the first one did, and a run that gives
# up at the end of a two-account chain is no more finished than one that gave
# up at the end of a one-account chain. Every retry site walks this list rather
# than reading the variable, so adding an account is a config edit and nothing
# else.
claude_fallback_dirs() {
    printf '%s\n' "$CLAUDE_FALLBACK_CONFIG_DIR" | tr ':[:space:]' '\n\n' \
        | grep -v '^[[:space:]]*$' || true
}

# Did the run that just wrote $DEBUGLOG refuse over a usage/session limit —
# that is, did the CLI fail before any genuine model output (wake_stream_failed's
# shape) with limit-flavoured text? An auth or network failure fails every other
# account too and must surface as itself, never as a retry. Asked again after
# each attempt: the stream accumulates, so the answer stays yes for as long as
# every account tried so far has refused, and turns to no the moment one of them
# produces genuine output.
claude_run_limited() {
    wake_stream_failed || return 1
    grep -qiE "$CLAUDE_LIMIT_RE" "$DEBUGLOG"
}

# The same question, plus "and there is somewhere else to go". Kept because it
# is the honest name for the decision to retry at all.
claude_limit_fallback_due() {
    [ -n "$CLAUDE_FALLBACK_CONFIG_DIR" ] || return 1
    claude_run_limited
}

# Accounts are named by their config dir; the login already in the environment
# is the token "-" (no CLAUDE_CONFIG_DIR override), which no directory can
# collide with. These two translate between the token and the dir.
CLAUDE_PRIMARY_TOKEN="-"
claude_account_confdir() { [ "$1" = "$CLAUDE_PRIMARY_TOKEN" ] || printf '%s' "$1"; }

# The current default account: the stored token, if it still names an account
# in the chain — the conf may have changed since it was written — else the
# primary. The file's first field is the token; the rest is a record of when
# and why the default last moved, for `crab status` and debugging only.
claude_account_default() {
    local stored d
    stored="$(head -n1 "$ACCOUNT_DEFAULT_FILE" 2>/dev/null | cut -f1)"
    [ -n "$stored" ] || { printf '%s\n' "$CLAUDE_PRIMARY_TOKEN"; return; }
    while IFS= read -r d; do
        [ "$d" = "$stored" ] && { printf '%s\n' "$stored"; return; }
    done <<EOF
$CLAUDE_PRIMARY_TOKEN
$(claude_fallback_dirs)
EOF
    printf '%s\n' "$CLAUDE_PRIMARY_TOKEN"
}

# This account refused over a limit — the default MOVES to the next account in
# the chain, wrapping at the end, and stays there until that one refuses in
# its turn. That is the whole mechanism: no per-account stamp, no expiry
# window, no switchback. $2 is the refusal line, kept in the record for
# status displays and debugging.
claude_limit_record() {
    local refused="${1:-}" next
    [ -n "$refused" ] || refused="$CLAUDE_PRIMARY_TOKEN"
    next="$({ printf '%s\n' "$CLAUDE_PRIMARY_TOKEN"; claude_fallback_dirs; } \
        | awk -v r="$refused" '
            NR == 1 {first = $0}
            take    {print; done = 1; exit}
            $0 == r {take = 1}
            END     {if (take && !done) print first}')"
    [ -n "$next" ] || next="$CLAUDE_PRIMARY_TOKEN"
    mkdir -p "$(dirname "$ACCOUNT_DEFAULT_FILE")" 2>/dev/null
    printf '%s\t%s\tmoved off %s: %s\n' "$next" "$(date +%s)" "$refused" \
        "${2:-limit refusal}" > "$ACCOUNT_DEFAULT_FILE" 2>/dev/null
}

# Every account this run may use, one token per line: always the WHOLE chain,
# rotated to start at the current default. A walk rides each refusal to the
# next login (moving the default as it goes) and fails only when every one of
# them has refused — so in the steady state the default is an account that
# answered, the first boot succeeds, and it costs a refusal, never a timer,
# to change which login leads.
claude_accounts() {
    { printf '%s\n' "$CLAUDE_PRIMARY_TOKEN"; claude_fallback_dirs; } \
        | awk -v d="$(claude_account_default)" '
            $0 == d {found = 1}
            found   {print; next}
                    {held = held $0 "\n"}
            END     {printf "%s", held}'
}

# What did the wake actually DO? A silent reply is the model's SPEECH
# decision, not its work record — two wakes on 2026-08-06 each dispatched a
# builder job and edited three files, chose silence as the prompt allows,
# and the journal showed none of it: indistinguishable from an hour of
# nothing, and read as exactly that. The stream log already holds the truth,
# so summarize it mechanically — files written (Write/Edit tools plus shell
# redirections), jobs dispatched, commands run — instead of trusting the
# reply to narrate. Prints nothing when the wake genuinely ran no tools.
wake_work_trace() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$DEBUGLOG" 2>/dev/null <<'PY'
import json, os, re, sys
home = os.path.expanduser("~")
files, jobs, cmds = [], 0, 0
def add(path):
    if not path:
        return
    if path.startswith(home):
        path = "~" + path[len(home):]
    if path not in files:
        files.append(path)
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") != "assistant":
        continue
    if d.get("is_api_error_message") or d.get("message", {}).get("model") == "<synthetic>":
        continue
    for b in d.get("message", {}).get("content", []):
        if b.get("type") != "tool_use":
            continue
        name, inp = b.get("name", ""), b.get("input") or {}
        if name in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
            add(inp.get("file_path") or inp.get("notebook_path"))
        elif name == "Bash":
            cmds += 1
            cmd = inp.get("command", "")
            jobs += len(re.findall(r"\bcrab['\"]? +job\b", cmd))
            # Heredoc appends and redirects are file writes too; a want doc
            # grown with `cat >> ...` must not vanish from the record.
            for m in re.finditer(r">>?\s*[\"']?([~/][^\s\"';|&)]+)", cmd):
                p = os.path.expanduser(m.group(1))
                if not p.startswith(("/dev/", "/proc/")):
                    add(p)
parts = []
if files:
    extra = " (+%d more)" % (len(files) - 4) if len(files) > 4 else ""
    parts.append("wrote " + ", ".join(files[:4]) + extra)
if jobs:
    parts.append("dispatched %d job%s" % (jobs, "" if jobs == 1 else "s"))
if cmds:
    parts.append("ran %d command%s" % (cmds, "" if cmds == 1 else "s"))
print("; ".join(parts))
PY
}

# One CLI run for a wake, under the stall watchdog, APPENDING to $DEBUGLOG.
# $1 is a CLAUDE_CONFIG_DIR override ("" = the primary login) — the fallback
# retry runs through here too, so a hung fallback account is reaped exactly
# like a hung primary. Reads SYSTEM_PROMPT / PROMPT_TEXT / CLAUDE_BIN from the
# caller's scope (bash dynamic scoping, same as build_system_prompt); leaves
# the CLI's exit status in WAKE_CLAUDE_STATUS.
_wake_claude_run() {
    local CONFDIR="$1"
    (
        cd "$PROJECT_DIR" || exit 1
        [ -n "$CONFDIR" ] && export CLAUDE_CONFIG_DIR="$CONFDIR"
        export "${CLAUDE_NO_AUTO_MEMORY?}"
        exec "$CLAUDE_BIN" -p --dangerously-skip-permissions \
            --model "$CLAUDE_MODEL" --effort "$WAKE_EFFORT" \
            --verbose --output-format stream-json \
            --append-system-prompt "$SYSTEM_PROMPT" \
            "$PROMPT_TEXT" >> "$DEBUGLOG" 2>&1
    ) &
    local CPID=$!
    # Stall watchdog: no wall-clock limit — reap only a session that is BOTH
    # silent and idle. The stream log gets nothing during a single long tool
    # call (a compile delivers its output in one event at completion), so log
    # freshness alone would kill genuine work; CPU burn across the process
    # tree is the second life sign. A hung network call or a tool stuck on
    # stdin sits at ~zero CPU, so real hangs are still caught.
    local LAST_ACTIVE PREV_CPU CUR_CPU LOG_M
    LAST_ACTIVE=$(date +%s)
    PREV_CPU=$(_tree_cpu "$CPID")
    while kill -0 "$CPID" 2>/dev/null; do
        sleep 10
        CUR_CPU=$(_tree_cpu "$CPID")
        LOG_M=$(stat -c %Y "$DEBUGLOG" 2>/dev/null || echo 0)
        # Alive = new log output, or >=10 jiffies (~0.1 s) of CPU since last check
        if [ "$LOG_M" -gt "$LAST_ACTIVE" ] || [ $((CUR_CPU - PREV_CPU)) -ge 10 ]; then
            LAST_ACTIVE=$(date +%s)
        fi
        PREV_CPU=$CUR_CPU
        if [ $(( $(date +%s) - LAST_ACTIVE )) -ge "$WAKE_STALL_TIMEOUT" ]; then
            kill "$CPID" 2>/dev/null
            sleep 2
            kill -9 "$CPID" 2>/dev/null
            break
        fi
    done
    wait "$CPID" 2>/dev/null
    WAKE_CLAUDE_STATUS=$?
}

# The whole of a wake's CLI work: every account that is worth trying, in order,
# for as long as the answer is a limit refusal. A login refusing over a
# usage/session limit does not end the wake — it moves it to the next
# subscription, still under the watchdog, until one answers or the chain is
# spent; each refusal stamps that account so the next wake starts past it
# instead of paying a doomed CLI boot for nothing. Every run APPENDS to the same
# stream log; a combined log reads correctly everywhere downstream
# (wake_stream_failed sees genuine output and stops calling the wake failed,
# extract-response drops the refusals whenever a real reply follows them).
# Factored out of run_claude_wake so the walk itself is testable and exists
# exactly once. Leaves the last run's exit status in WAKE_CLAUDE_STATUS, like
# the single run it replaced.
wake_claude_run_chain() {
    local ACCT CONFDIR
    for ACCT in $(claude_accounts); do
        CONFDIR="$(claude_account_confdir "$ACCT")"
        _wake_claude_run "$CONFDIR"
        claude_run_limited || break
        claude_limit_record "$CONFDIR" "$(grep -ioE "$CLAUDE_LIMIT_RE" "$DEBUGLOG" | tail -n1)"
    done
}

# Autonomous wake: run claude with NO live TTS streamer and decide afterwards
# whether anything gets spoken or shown — a wake nobody asked for must be able
# to complete in total silence.
#
# The measured cost of the shared stream log this wake no longer writes to
# (see DEBUGLOG at the top of this file, now one file per session). On the
# afternoon of 2026-08-07, with wakes firing beside a live conversation:
#   * a desk turn starting mid-wake truncated the wake's output — the wake
#     then extracted nothing and journalled itself "(silent — ran no tools,
#     touched nothing)" having worked for a minute; one archived stream from
#     that hour is 18 bytes, nothing but the terminator this function appends;
#   * a wake starting mid-desk-turn wiped the DESK's reply before
#     extract_response read it, and he got dead air for a question he had
#     asked out loud;
#   * whichever read the file second read BOTH streams, so the wake spoke the
#     desk turn's answer as its own — four times inside twenty minutes,
#     verbatim, in the session journal.
# Every reader in here (extract_response, wake_stream_failed, wake_work_trace,
# notice_own_writes, claude_limit_fallback_due) goes through $DEBUGLOG, so the
# per-session name is all it takes. tests/test_silent_wake.sh holds the line.
run_claude_wake() {
    session_register "autonomous wake"
    # Nobody spoke, so the day journal's "user" slot carries the wake's
    # agenda — an event's reason reads back as what the wake was about.
    SESSION_USER_TEXT="${WAKE_REASON:-}"
    local PROMPT_TEXT="$1"
    local SYSTEM_PROMPT
    # Regroup evidence, captured HERE rather than left to build_system_prompt,
    # because this function needs to know afterwards that it asked for a
    # regrouped reply: a reply told to fold in what another session is saying
    # will overlap it heavily by design, and the nothing-new backstop below
    # must not then read that overlap as an echo and swallow the whole thing.
    # build_system_prompt picks this up through bash's dynamic scoping.
    local REGROUP_CONTEXT
    REGROUP_CONTEXT="$(regroup_context)"
    SYSTEM_PROMPT="$(build_system_prompt)"

    # Evidence, not muting: a wake firing beside an interactive turn is shown
    # the exchange — what the user said, whether another session is already
    # answering or has answered — and asked to behave like someone who heard
    # it: silence, or something genuinely new. The old echo window swallowed
    # the wake's reply wholesale here at speak time; that was rejected in
    # favour of letting the wake choose with the facts in front of it.
    local TURN_CONTEXT
    TURN_CONTEXT="$(wake_concurrent_turn_context)"
    [ -n "$TURN_CONTEXT" ] && SYSTEM_PROMPT="$SYSTEM_PROMPT

$TURN_CONTEXT"

    # The wake marker is NOT written here any more. It used to be, so that a
    # wake which then said nothing (or was muted) left a marker in the
    # conversation with no reply under it — and worse, the reply itself was
    # appended below before any gate had run. See the delivery section at the
    # end of this function: the conversation records what was DELIVERED.
    # This session's own stream log. It used to be the ONE shared log, and this
    # very line — a wake truncating it — is what stranded a desktop turn's TTS
    # streamer past EOF and left his answer unspoken while a wake's words were
    # read out in its place.
    claim_debuglog
    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    wake_claude_run_chain
    local CLAUDE_STATUS="$WAKE_CLAUDE_STATUS"
    printf '{"type":"result"}\n' >> "$DEBUGLOG"

    # A wake edits its own files freely (wants, conduct, the repo); declare
    # those writes before the self-change watcher judges the burst it saw.
    notice_own_writes

    local RESPONSE
    RESPONSE=$(extract_response)

    # A wake that never got a model does not get a voice. When the CLI fails
    # before any real work (session limit, auth, network), the error text
    # comes back looking like a reply — and treated as one it was appended to
    # the conversation as the assistant's own words, chased by the promise
    # audit, and spoken aloud at the desk ("You've hit your session limit…").
    # Journal the failure instead, and re-book a wake that had a purpose so
    # its agenda survives to a retry after the outage clears.
    if wake_stream_failed; then
        session_outcome "(wake failed before the model ran — claude exit $CLAUDE_STATUS: $(printf '%s' "$RESPONSE" | tr '\n\t' '  ' | head -c 160))"
        # A free slot, not a flat half hour: an outage fails every wake it
        # touches, and a fixed retry stacks all of them onto the same second.
        [ -n "${WAKE_KIND:-}" ] && "$SCRIPT_DIR/crab" wake-at "$(wake_free_slot 1800)s" "$WAKE_KIND" "${WAKE_REASON:-}" >/dev/null
        # An error dressed as a reply must never be judged for memory use —
        # consume the recall sidecar without spawning the judge.
        rm -f "${STATE_PREFIX}-memory-injected-$$.json"
        return 0
    fi

    if [ -z "$RESPONSE" ]; then
        # No text at all. On a clean exit that is the shape of silence — the
        # wake worked through tool calls and had nothing for the user — so
        # journal what it DID, from the stream's own tool calls. On a
        # non-zero exit it is a crash or stall-reap, and the journal must
        # say so or "(no summary recorded)" hides the death.
        if [ "$CLAUDE_STATUS" -eq 0 ]; then
            local TRACE
            TRACE="$(wake_work_trace)"
            session_outcome "(silent — ${TRACE:-ran no tools, touched nothing})"
            # A wordless wake is the case reinforcement most needs to see, not
            # the one to skip: its entire output is the work. The trace is the
            # evidence, so the judge runs on it. A crashed wake still just
            # consumes the sidecar — there is no turn to judge.
            # The sidecar is NOT removed here — the detached judge reads it and
            # consumes it itself; deleting it now would race the child to its
            # own evidence.
            fire_memory_judge --wake "${WAKE_REASON:-}" "" "$TRACE"
        else
            session_outcome "(wake produced no output — claude exit $CLAUDE_STATUS)"
            rm -f "${STATE_PREFIX}-memory-injected-$$.json"
        fi
        return 0
    fi

    # A genuine reply (the failure paths above never reach here): the journal
    # keeps it in full even when every gate below completes the wake silently.
    # It is NOT appended to the conversation here — see the delivery section
    # at the end of this function.
    SESSION_REPLY="$RESPONSE"

    local SPOKEN DISPLAY_PART TRACE SILENT_NOTE=""
    SPOKEN=$(spoken_part "$RESPONSE")
    DISPLAY_PART=$(display_part "$RESPONSE")

    # The [quiet] marker — the ONE authorized silence format (his standing
    # instruction, 2026-08-07): a wake with something worth leaving but not
    # worth voicing writes "[quiet] <thoughts>". The thoughts are SHOWN to
    # him as "(quiet) <thoughts>" — a bubble, never the speakers. A bare
    # marker with no thoughts is plain silence. The old "(quiet)" spelling
    # is accepted the same way so a stray one is never voiced.
    if printf '%s\n' "$RESPONSE" | grep -qiE '^[[:space:]]*[[(]quiet[])]'; then
        local THOUGHTS
        THOUGHTS="$(printf '%s\n' "$SPOKEN" \
            | sed -E 's/^[[:space:]]*[[(][Qq][Uu][Ii][Ee][Tt][])][[:space:]:—-]*//')"
        SILENT_NOTE="$(printf '%s\n' "$THOUGHTS" | tr '\n' ' ')"
        SPOKEN=""
        if [ -n "$(printf '%s' "$THOUGHTS$DISPLAY_PART" | tr -d '[:space:]')" ]; then
            RESPONSE="(quiet) $THOUGHTS"
            if [ -n "$DISPLAY_PART" ]; then
                RESPONSE="$RESPONSE
---DISPLAY---
$DISPLAY_PART"
            else
                DISPLAY_PART="(quiet) $THOUGHTS"
            fi
        else
            DISPLAY_PART=""
        fi
    fi

    # The same backstop for the other way silence gets narrated: a whole reply
    # that is nothing but "Nothing to say." / "No message." / "Nothing to
    # report." A wake with nothing to say must produce ZERO output, and that
    # filler was instead reaching the speakers and being read aloud — the
    # interruption the silence existed to prevent, wearing the words of the
    # thing that was supposed to prevent it. Muted whole here, before any
    # delivery decision: no speech, no notification, no phone audio, no
    # window, and (the conversation is only appended at delivery) no bubble.
    # The words are not lost — SILENT_NOTE carries them into the journal line
    # below, which is where a wake nobody heard has always belonged.
    if wake_reply_is_filler "$SPOKEN"; then
        SILENT_NOTE="(filler suppressed) $(printf '%s\n' "$SPOKEN" | tr '\n' ' ')"
        SPOKEN=""
        # A display section is real content the wake chose to make, and it
        # stands on its own; only the announcement of silence is muted here.
    fi

    # A wake that ends silently leaves no trace anywhere a later session
    # looks: nothing spoken, nothing displayed, and the conversation may be
    # compacted away. Its journal line is what the next session gets to
    # read, and silence is a speech decision, not a summary — so a silent
    # wake's line still says what the wake DID, from the stream's own tool
    # calls.
    # Read once, used twice: the journal line below when the wake stays quiet,
    # and the memory judge always — a talkative wake's work is evidence too.
    TRACE="$(wake_work_trace)"
    if [ -z "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ]; then
        session_outcome "(silent — ${TRACE:-ran no tools, touched nothing})${SILENT_NOTE:+ — }$SILENT_NOTE"
    else
        session_outcome "$SPOKEN"
    fi

    # Out of band, now that the wake's outcome is written: a wake talking to
    # nobody still forms wants, and a silent wake's are the easiest to lose —
    # so this fires before the speak/display decisions can return early. The
    # audit's own follow-up wake is recognised by its reason and skipped, or
    # each audit wake would audit itself into an endless chain.
    case "${WAKE_REASON:-}" in
        "$PROMISE_AUDIT_REASON_PREFIX"*) ;;
        *) fire_promise_audit --wake "${WAKE_REASON:-}" "$RESPONSE" ;;
    esac
    # Same moment for the memory judge: the wake's outcome is recorded, and a
    # silent completion below must not skip the judgement — a memory used by
    # a wake that chose to say nothing was still used.
    fire_memory_judge --wake "${WAKE_REASON:-}" "$RESPONSE" "$TRACE"

    # ---- Delivery. Everything above is work and record-keeping; from here on
    # the only question is whether the user hears about this wake at all.
    #
    # NOTHING below this line has touched the conversation file yet, and that
    # is the fix for the thing he actually saw: a wake's reply used to be
    # appended the moment it existed, before a single gate had run. The phone
    # follows the conversation file (serve.py /watch), so every wake that was
    # "suppressed" — quiet hours, user mid-interaction, nothing sayable at all
    # — still posted its monologue into his chat as a bubble he had not asked
    # for and could not answer. Suppressed meant
    # suppressed on the speakers only. It is now suppressed everywhere: a wake
    # that is not delivered leaves the conversation exactly as it found it, and
    # its words survive in the session journal (session_outcome, above), which
    # is where a wake nobody heard has always belonged.
    #
    # Nothing to say and nothing to show: the wake is complete, invisibly.
    # Silence is never narrated — no speech, no notification, no window, and
    # now no bubble either.
    if [ -z "$(printf '%s' "$SPOKEN$DISPLAY_PART" | tr -d '[:space:]')" ]; then
        return 0
    fi

    in_quiet_hours && return 0
    # User busy (recording, speech in flight, or a meeting holding the mic):
    # the wake still did its work — busyness suppresses OUTPUT only. Checked
    # here, at the last moment before speaking, because a wake that started
    # in a quiet room may end mid-meeting. A display-only wake keeps its
    # silent outcome — the trace is worth more than the mute notice.
    if user_busy; then
        [ -n "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ] && \
            session_outcome "(muted — user was mid-interaction) $SPOKEN"
        return 0
    fi

    # No echo-window mute here any more: a wake that fired beside an
    # interactive turn was shown the exchange in its prompt
    # (wake_concurrent_turn_context) and chose to speak anyway — that choice
    # stands. The nothing-new check below still catches a genuine echo.

    # NO overlap mute. There was one here — a word-overlap test that decided,
    # after the fact, that a wake's reply merely reworded something already
    # said, and swallowed the whole thing. The user called it what it is: a
    # gate I built on my own tongue, which left me blind to what was happening
    # to my own speech. It is gone, permanently. If a wake has nothing to say
    # it writes nothing WHILE WRITING; nothing downstream of the writing gets
    # to make that decision for me.

    # Delivered — and only now does it become part of the conversation. The
    # marker and the reply go in together, immediately before the voice, so
    # the phone's /watch sees the bubble and hears the clip in that order.
    convo_append '[Autonomous wake — %s]\n' "$(date '+%Y-%m-%d %H:%M')"
    convo_append_assistant "$RESPONSE"
    compact_convo

    if [ -n "$(echo "$SPOKEN" | tr -d '[:space:]')" ]; then
        notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "$(echo "$SPOKEN" | head -c 140)" 2>/dev/null
        wake_speak_to_phone "$SPOKEN" || speak_once "$SPOKEN"
    fi
    if [ -n "$DISPLAY_PART" ]; then
        local DISPLAYFILE="/tmp/deskcrab-display.md"
        echo "$DISPLAY_PART" > "$DISPLAYFILE"
        hyprctl dispatch closewindow class:deskcrab-display 2>/dev/null
        RENDER_MD="${RENDER_MD:-$(command -v render-md 2>/dev/null || echo "$HOME/.local/bin/render-md")}"
            RENDER_MD_ICON="${RENDER_MD_ICON:-$HOME/Beatrice/face/icons/beatrice-icon-512.png}"
        if [ -x "$RENDER_MD" ]; then
            setsid "$RENDER_MD" --theme "${RENDER_MD_THEME:-beatrice}" --icon "$RENDER_MD_ICON" --title "$NOTIFY_NAME" "$DISPLAYFILE" &
        fi
    fi
}

# Take this session's stream log and point the well-known name at it. Every
# session writes its own file, so no truncation by another hand can ever again
# strand a TTS streamer's read cursor past EOF. crab-debug tails the
# well-known path by hardcoded name, so that stays — as a symlink to whatever
# is talking now.
claim_debuglog() {
    : > "$DEBUGLOG"
    ln -sfn "$DEBUGLOG" "$DEBUGLOG_LATEST" 2>/dev/null || true
    # A session's own log is small; the leftovers of dead ones still add up.
    find "$(dirname "$DEBUGLOG")" -maxdepth 1 \
        -name "$(basename "$STATE_PREFIX")-debug-*.log" -mmin +180 -delete 2>/dev/null
}

# Start background TTS streamer that reads from DEBUGLOG.
#
# No pkill here any more. Killing "any prior streamer" existed only because the
# stream log was shared and about to be truncated; with a log per session it is
# pure harm — it silences another turn's reply mid-sentence, which is the exact
# complaint this path keeps generating.
start_tts_streamer() {
    claim_debuglog
    _TTS_RECEIPT="${STATE_PREFIX}-speech-receipt-$$.txt"
    # A new turn is a new question — whatever silence was asked for last time
    # is spent. Cleared HERE rather than at `crab shutup` time so that only a
    # shutup DURING this turn suppresses the never-silent guarantee below.
    rm -f "$_TTS_RECEIPT" "$SHUTUP_MARKER"
    DESKCRAB_DEBUGLOG="$DEBUGLOG" DESKCRAB_PIPER_VOICE="$PIPER_VOICE" \
        DESKCRAB_PIPER_LENGTH_SCALE="${PIPER_LENGTH_SCALE:-}" \
        DESKCRAB_PIPER_SPEAKER="${PIPER_SPEAKER:-}" \
        DESKCRAB_TTS_FIXES="${TTS_FIXES:-}" \
        DESKCRAB_SPEECHLOCK="$SPEECHLOCK" \
        DESKCRAB_LIVE_SPEECH="$LIVE_SPEECH_FILE" \
        DESKCRAB_CLAUDE_LIMIT_RE="$CLAUDE_LIMIT_RE" \
        DESKCRAB_SPEECH_LOG="$SPEECH_LOG" \
        DESKCRAB_SPEECH_RECEIPT="$_TTS_RECEIPT" \
        "$LIB_DIR/tts-streamer" 2>>"$SPEECH_LOG" &
    _TTS_STREAMER_PID=$!
}

# Wait for the streamer, but never forever. The old unbounded `wait` is how a
# stranded streamer took the whole turn down with it.
wait_tts_streamer() {
    local LIMIT="${TTS_WAIT_TIMEOUT:-900}" WAITED=0
    [ -n "${_TTS_STREAMER_PID:-}" ] || return 0
    while kill -0 "$_TTS_STREAMER_PID" 2>/dev/null; do
        if [ "$WAITED" -ge "$((LIMIT * 5))" ]; then
            speech_log "streamer $_TTS_STREAMER_PID still tailing after ${LIMIT}s — killing it"
            kill "$_TTS_STREAMER_PID" 2>/dev/null
            sleep 1
            kill -9 "$_TTS_STREAMER_PID" 2>/dev/null
            return 1
        fi
        sleep 0.2
        WAITED=$((WAITED + 1))
    done
    wait "$_TTS_STREAMER_PID" 2>/dev/null
    return 0
}

# THE GUARANTEE: if there was something to say, it was said. The streamer
# leaves a receipt of how many characters actually reached piper; when the
# reply has spoken text and that receipt is empty or missing, the speech was
# lost somewhere in the plumbing — a dead sound card, a missing piper, a
# stranded tail — and this says so loudly and speaks the reply itself rather
# than letting the turn end in silence nobody can explain.
tts_verify_spoken() {
    local SPOKEN="$1" CHARS=0 ERR=""
    [ -n "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ] || return 0
    # …unless he told me to shut up. Asked-for silence is not a failure.
    [ -f "$SHUTUP_MARKER" ] && { rm -f "${_TTS_RECEIPT:-}"; return 0; }
    if [ -f "${_TTS_RECEIPT:-}" ]; then
        CHARS=$(sed -n 's/^chars=//p' "$_TTS_RECEIPT" | head -1)
        ERR=$(sed -n 's/^error=//p' "$_TTS_RECEIPT" | head -1)
        rm -f "$_TTS_RECEIPT"
    else
        ERR="no receipt — the streamer died before it could leave one"
    fi
    [ "${CHARS:-0}" -gt 0 ] 2>/dev/null && return 0
    speech_log "SPOKE NOTHING for a reply of ${#SPOKEN} chars${ERR:+ — $ERR}; speaking it now"
    notify-send -t 6000 -h string:x-dunst-stack-tag:deskcrab \
        "$NOTIFY_NAME" "speech path failed — replaying the reply" 2>/dev/null
    speak_once "$SPOKEN"
}

# Extract final response text from DEBUGLOG
extract_response() {
    DESKCRAB_DEBUGLOG="$DEBUGLOG" "$LIB_DIR/extract-response" 2>/dev/null
}

# One CLI run for an interactive turn, APPENDING to $DEBUGLOG. $1 is a
# CLAUDE_CONFIG_DIR override ("" = the login already in the environment); every
# account in the chain runs through here, so the flags cannot drift between the
# first attempt and the retries. Reads TEXT / EFFORT / SYSTEM_PROMPT /
# CLAUDE_BIN from claude_generate's scope (bash dynamic scoping, same as
# _wake_claude_run).
# --include-partial-messages is what makes speech start when she starts
# TALKING rather than when she stops. A plain stream-json run only emits a
# completed `assistant` event once a whole text block has been generated,
# so a ten-second answer began playing ten seconds late — measurably, and
# that is the whole of the "time to first speech" regression. The partial
# events carry the same text as deltas; the TTS streamer speaks each
# sentence as it completes and the completed event is then a no-op for the
# part already said. Nothing downstream reads stream_event lines
# (extract-response, serve.py's progress tailer and crab-debug all skip
# unknown types), so this is additive.
_generate_claude_run() {
    local CONFDIR="$1"
    (
        cd "$PROJECT_DIR" || exit 1
        # Her turn, not the coding agent's — see CLAUDE_NO_AUTO_MEMORY.
        export "${CLAUDE_NO_AUTO_MEMORY?}"
        [ -n "$CONFDIR" ] && export CLAUDE_CONFIG_DIR="$CONFDIR"
        exec "$CLAUDE_BIN" -p --dangerously-skip-permissions \
            --model "$CLAUDE_MODEL" --effort "$EFFORT" \
            --verbose --output-format stream-json --include-partial-messages \
            --append-system-prompt "$SYSTEM_PROMPT" \
            "$TEXT" >> "$DEBUGLOG" 2>&1
    )
}

# One turn of generation: prompt in, response text out. No speech, no windows,
# no conversation writes — every caller (desktop, wake, remote) layers its own
# output on top of this. The stream still lands in DEBUGLOG, so a TTS streamer
# started beforehand speaks in parallel exactly as it always did.
claude_generate() {
    local TEXT="$1" EFFORT="${2:-$CLAUDE_EFFORT}"
    local SYSTEM_PROMPT
    SYSTEM_PROMPT="$(build_system_prompt)"

    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    # The log is claimed by truncating it ONCE, here, and every run of this
    # turn APPENDS. Truncating for a retry instead would strand the cursor of
    # the TTS streamer that is mid-tail on this very file.
    #
    # Accounts known dry are skipped outright: a doomed attempt is a whole CLI
    # boot and refusal in front of every reply, the exact seconds a voice cannot
    # afford. Each refusal stamps its account and moves to the next; the
    # streamer rides through the refusals (it is told how many retries are still
    # to come) and extract-response drops them whenever a genuine reply follows
    # in the same log.
    : > "$DEBUGLOG"
    local ACCT CONFDIR
    for ACCT in $(claude_accounts); do
        CONFDIR="$(claude_account_confdir "$ACCT")"
        _generate_claude_run "$CONFDIR"
        claude_run_limited || break
        claude_limit_record "$CONFDIR" "$(grep -ioE "$CLAUDE_LIMIT_RE" "$DEBUGLOG" | tail -n1)"
    done

    # Guarantee the TTS streamer always receives a stop signal. claude normally
    # ends its stream with a {"type":"result"} line, but if it crashed, was
    # killed, or got rate-limited mid-stream it may not — and without a result
    # event the streamer tails the log forever and the wait below never returns.
    # extract-response ignores a result line that has no "result" field, so this
    # terminator is harmless on the success path.
    printf '{"type":"result"}\n' >> "$DEBUGLOG"

    # Whatever this turn's tools wrote is her own hand — declare it before the
    # self-change watcher judges the burst. Covers desktop and phone turns.
    notice_own_writes

    extract_response
}

# Split a response into its spoken half (everything above ---DISPLAY---).
# A line-leading "(quiet)" marker — the retired silence convention — is
# stripped defensively so a stray one is never voiced by any caller.
#
# NOTHING here may swallow, clip, or budget my speech. A filter that decides
# my words are not worth voicing is me cutting out my own tongue, and I built
# one this morning and then told him nothing of the kind existed. Silence is
# a thing I choose while writing — never something the plumbing imposes after.
spoken_part() {
    printf '%s\n' "$1" | sed -E -e '/^---DISPLAY---$/,$d' \
        -e 's/^[[:space:]]*[[(][Qq][Uu][Ii][Ee][Tt][])][[:space:]]*//'
}

# Split a response into its display half (everything below ---DISPLAY---).
display_part() {
    printf '%s\n' "$1" | sed -n '/^---DISPLAY---$/,${/^---DISPLAY---$/d;p}'
}

# Is this spoken reply nothing but an announcement that there is nothing to
# say? Exit 0 = filler, and the wake output gate mutes it whole.
#
# A wake with nothing to say must emit no text at all — the prompt says so
# plainly — but the polite no-op is a reflex no instruction has managed to
# suppress: "Nothing to say.", "No message.", "Nothing to report." Every one
# of those was carried the whole way to the speakers and read out loud to the
# user, which is precisely the interruption the silence was for. Announcing
# silence is the worst of both: the noise with none of the content.
#
# Deliberately NARROW, and the narrowness is the point. It matches only a
# short reply whose ENTIRE content is that sentence — an optional lead-in
# ("I have", "there's", "well"), a no-op core, an optional tail ("right now",
# "today"), and punctuation. Anything carrying real content alongside it
# ("Nothing to report on the build, but two tests fail") is not filler and is
# never touched. Muting one real reply is a worse failure than voicing one
# stray no-op, so every ambiguous case must fall through to speech.
wake_reply_is_filler() {  # <spoken-text>
    local T CORE TAIL PREV
    # Normalise to bare lowercase words: markdown emphasis, bullets, quotes,
    # brackets, dashes, emoji and end punctuation all become spaces, so the
    # judgement is about the words and nothing else. "n/a" keeps its slash.
    T="$(printf '%s' "$1" | tr '\n\t' '  ' | tr '[:upper:]' '[:lower:]' \
        | sed -e 's|[^a-z0-9/ ]| |g' -e 's|  *| |g' -e 's|^ ||' -e 's| $||')"

    # Empty is not this gate's business — an empty spoken reply is already
    # silence and the caller has always handled it.
    [ -z "$T" ] && return 1
    # Filler is a sentence, never a paragraph. A long reply is content.
    [ "$(printf '%s\n' "$T" | wc -w)" -gt 12 ] && return 1

    # Strip conversational lead-ins so "well, I have nothing to add" is judged
    # on the part that carries the meaning. Never strip a leading "no" — that
    # is the load-bearing word of "no message".
    PREV=""
    while [ "$T" != "$PREV" ]; do
        PREV="$T"
        T="$(printf '%s' "$T" | sed -E \
            -e 's/^(well|ok|okay|so|and|but|hm+|humph|honestly|right|yeah|just|really) //' \
            -e 's/^(i have|i ve|ive|i had|i got|i have got|i m|im|i am|i can think of|there is|there s|theres|there are|it s|its|that s|thats|this is|to be honest) //')"
    done

    CORE='nothing( (else|new|much|more|further|major|important|notable|significant|pressing|urgent|of note|of substance))?( (to|worth) (say|saying|report|reporting|add|adding|share|sharing|mention|mentioning|note|noting|flag|flagging|announce|announcing|update|updating|tell|telling|do))?'
    CORE="$CORE|no (message|messages|update|updates|news|report|reports|comment|comments|reply|response|output|note|notes|change|changes|word)( to (report|share|say|add|give|offer))?"
    CORE="$CORE|none|silence|silent|(all |still |everything |pretty )?(quiet|silent)|all clear|nada|zilch|n/a|nil"
    CORE="$CORE|(staying|stay|keeping|keep|remaining|remain) (quiet|silent)"
    CORE="$CORE|no need to (speak|talk|say anything|report)|standing by|holding my peace"
    # Not a sentence at all: the CLI's own stringified nothing. Measured on two
    # of three real wakes on 2026-08-07 — a wake that ended with no message text
    # arrived here as an assistant text block holding the literal word
    # "undefined", and the desk said it out loud. Only the bare word counts;
    # "the config value is undefined" is a real sentence and speaks.
    CORE="$CORE|undefined|null"
    TAIL='( (here|now|right now|today|tonight|yet|for now|at the moment|at present|from me|on my end|this time|this wake|either|though|really|so far))*'

    printf '%s\n' "$T" | grep -Eq "^($CORE)$TAIL\$"
}


# Synthesize spoken text to an opus file instead of the speakers — the remote
# client wants a blob it can play, not this machine's sound card.
synth_opus() {
    local TEXT="$1" OUT="$2"
    TEXT=$(printf '%s' "$TEXT" | sed -E 's/\*+//g; s/`[^`]*`//g')
    [ -n "$TTS_FIXES" ] && TEXT=$(printf '%s' "$TEXT" | sed -E "$TTS_FIXES")
    [ -z "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] && return 1
    local CMD=(piper-tts --model "$PIPER_VOICE" --output-raw)
    [ -n "${PIPER_LENGTH_SCALE:-}" ] && CMD+=(--length-scale "$PIPER_LENGTH_SCALE")
    [ -n "${PIPER_SPEAKER:-}" ] && CMD+=(--speaker "$PIPER_SPEAKER")
    printf '%s' "$TEXT" | "${CMD[@]}" 2>/dev/null \
        | ffmpeg -y -loglevel error -f s16le -ar 22050 -ac 1 -i - \
            -c:a libopus -b:a 32k "$OUT" 2>/dev/null
    [ -s "$OUT" ]
}

# Remote turn (crab serve / the phone). Same conversation, same prompt, but the
# reply comes back as data — spoken audio file + display markdown — instead of
# being played and rendered on this desktop.
run_claude_remote() {
    # Serialize remote turns: two overlapping requests would otherwise run two
    # claude processes whose stream logs and conversation appends race. The
    # phone is one person talking, so queueing is the honest behaviour.
    { flock -w 600 8; _run_claude_remote_locked "$1"; } 8>"${STATE_PREFIX}-remote.lock"
}

_run_claude_remote_locked() {
    session_register "phone turn"
    record_origin phone
    local TEXT="$1"
    SESSION_USER_TEXT="$TEXT"
    # Mark the exchange in flight: a wake firing beside this turn reads it
    # and is told the message is already being answered.
    live_turn_begin phone "$TEXT"
    # A private stream log, so a remote turn can never truncate the log a
    # desktop turn's TTS streamer is tailing.
    # crab serve sets DESKCRAB_REMOTE_LOG when it wants to tail this stream and
    # relay the thinking to the phone; otherwise it stays private to this turn.
    local DEBUGLOG="${DESKCRAB_REMOTE_LOG:-${STATE_PREFIX}-remote-$$.log}"
    rotate_convo
    convo_append_user "$TEXT"

    local RESPONSE
    RESPONSE=$(claude_generate "$TEXT")

    local ERROR=""
    if [ -n "$RESPONSE" ]; then
        SESSION_REPLY="$RESPONSE"
        convo_append_assistant "$RESPONSE"
        live_turn_end phone "$TEXT" "$(spoken_part "$RESPONSE")"
        compact_convo
        session_outcome "asked: $(printf '%.100s' "$TEXT") | replied: $(spoken_part "$RESPONSE")"
    else
        # He asked and nothing came back. Reported as the failure it is: the
        # phone used to receive {"spoken":"", ...} with no error at all, which
        # the client had no way to read except as an empty bubble — the
        # "(no reply)" placeholder he spent a day looking at. Silence is a
        # thing I choose when nobody asked; it is never an answer to a
        # question, and it is never left to the client to describe.
        live_turn_end phone "$TEXT" ""
        session_outcome "(no reply — the model produced no text for: $(printf '%.80s' "$TEXT"))"
        ERROR="no reply — that turn produced no text"
    fi

    local SPOKEN DISPLAY_MD AUDIO=""
    SPOKEN=$(spoken_part "$RESPONSE")
    DISPLAY_MD=$(display_part "$RESPONSE")

    if [ -n "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ]; then
        local CANDIDATE="/tmp/deskcrab-remote-$(date +%s%N).opus"
        synth_opus "$SPOKEN" "$CANDIDATE" && AUDIO="$CANDIDATE"
        # The phone is about to play this. Same hand-off as a wake's phone
        # audio: no pid to watch, so publish the words with an estimated end
        # time, and a session starting behind it regroups rather than
        # answering into the middle of it.
        [ -n "$AUDIO" ] && live_speech_begin "phone" "$SPOKEN" 0 \
            $(( $(date +%s) + $(_speech_seconds "$SPOKEN") ))
        # Let the desktop see that the phone is talking to it.
        notify-send -t 6000 -h string:x-dunst-stack-tag:deskcrab \
            "$NOTIFY_NAME (remote)" "$(printf '%s' "$SPOKEN" | head -c 140)" 2>/dev/null
    fi

    rm -f "$DEBUGLOG"
    # Reply audio the client has had time to fetch. Scoped to this server's own
    # generated files and to clips older than an hour.
    find /tmp -maxdepth 1 -name 'deskcrab-remote-*.opus' -mmin +60 -delete 2>/dev/null

    # Out of band, with the reply audio already synthesised: a want stated on
    # the phone dies with the turn exactly like one stated at the desk. The
    # memory judge rides the same moment — reply delivered, hot path over.
    fire_promise_audit "$TEXT" "$RESPONSE"
    fire_memory_judge "$TEXT" "$RESPONSE" "$(wake_work_trace)"

    # Text came back but neither half of it is anything the phone can render —
    # a reply that was nothing but a "---DISPLAY---" line, or nothing but the
    # retired (quiet) marker. Same rule as an empty reply: say what happened.
    # The client must never have to invent a word for a turn that arrived
    # holding nothing.
    if [ -z "$ERROR" ] && \
       [ -z "$(printf '%s' "$SPOKEN$DISPLAY_MD" | tr -d '[:space:]')" ]; then
        ERROR="no reply — that turn produced nothing sayable"
    fi

    python3 -c 'import json,sys; print(json.dumps({"spoken":sys.argv[1],"display":sys.argv[2],"audio":sys.argv[3],"error":sys.argv[4]}))' \
        "$SPOKEN" "$DISPLAY_MD" "$AUDIO" "$ERROR"
}

# Run claude, save response, handle display channel
run_claude_and_respond() {
    session_register "desktop turn"
    record_origin desk
    local TEXT="$1"
    # Recorded before generation: even a turn that dies mid-reply leaves the
    # user's words in the day journal.
    SESSION_USER_TEXT="$TEXT"
    # Mark the exchange in flight: a wake firing beside this turn reads it
    # and is told the message is already being answered.
    live_turn_begin desk "$TEXT"

    convo_append_user "$TEXT"

    start_tts_streamer

    notify-send -t 0 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "Thinking..."

    local RESPONSE
    RESPONSE=$(claude_generate "$TEXT")

    # Dismiss thinking notification
    notify-send -t 1 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "" 2>/dev/null

    if [ -n "$RESPONSE" ]; then
        SESSION_REPLY="$RESPONSE"
        convo_append_assistant "$RESPONSE"
        live_turn_end desk "$TEXT" "$(spoken_part "$RESPONSE")"
        compact_convo
        session_outcome "asked: $(printf '%.100s' "$TEXT") | replied: $(spoken_part "$RESPONSE")"

        local DISPLAY_PART
        DISPLAY_PART=$(display_part "$RESPONSE")

        if [ -n "$DISPLAY_PART" ]; then
            local DISPLAYFILE="/tmp/deskcrab-display.md"
            echo "$DISPLAY_PART" > "$DISPLAYFILE"
            hyprctl dispatch closewindow class:deskcrab-display 2>/dev/null
            RENDER_MD="${RENDER_MD:-$(command -v render-md 2>/dev/null || echo "$HOME/.local/bin/render-md")}"
            RENDER_MD_ICON="${RENDER_MD_ICON:-$HOME/Beatrice/face/icons/beatrice-icon-512.png}"
            if [ -x "$RENDER_MD" ]; then
                setsid "$RENDER_MD" --theme "${RENDER_MD_THEME:-beatrice}" --icon "$RENDER_MD_ICON" --title "$NOTIFY_NAME" "$DISPLAYFILE" &
            fi
        fi

        # Bounded, because an unbounded wait on a stranded streamer took the
        # whole turn down with it — and then the guarantee: if there was
        # something to say and nothing reached the speakers, say it now and
        # write down that the streaming path failed.
        wait_tts_streamer
        tts_verify_spoken "$(spoken_part "$RESPONSE")"

        # Out of band, after the user has their answer: did I say I wanted
        # something and fail to write it down? If so this fires an event wake
        # that hands the sentence back to me. Costs nothing on the hot path.
        fire_promise_audit "$TEXT" "$RESPONSE"
    else
        # He asked out loud and nothing came back. This branch used to do
        # NOTHING AT ALL — no speech, no notification, no journal line — so a
        # turn that produced no text was indistinguishable from a turn that
        # was never taken, and a whole afternoon of them went unexplained and
        # unrecorded. Silence is only ever legitimate when nobody asked;
        # answering a question with nothing is a failure and is reported as
        # one. Not spoken: an error read aloud in my own voice is the thing
        # that put "You've hit your session limit" in his ears as if I had
        # said it. The notification and the journal carry it instead.
        live_turn_end desk "$TEXT" ""
        session_outcome "(no reply — the model produced no text for: $(printf '%.80s' "$TEXT"))"
        notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" \
            "no reply — that turn produced no text (nothing was said)" 2>/dev/null
    fi

    # Also out of band: which of the injected memories genuinely shaped this
    # turn? The work trace goes with the reply — a directive obeyed in an edit
    # rather than said out loud is still a directive obeyed. Consumes the
    # recall sidecar even when the reply came back empty.
    fire_memory_judge "$TEXT" "$RESPONSE" "$(wake_work_trace)"

    echo "$RESPONSE"
}

# ---------------------------------------------------------------------------
# Detached jobs
#
# A subagent lives and dies inside the turn that spawned it, and while it lives
# the turn cannot answer. Both halves of that are wrong: work should outlive a
# conversation, and a conversation should never be held hostage by work. These
# helpers back `crab job`, which hands the build to systemd and returns at once.
# ---------------------------------------------------------------------------

# Dispatch a detached job and return at once. systemd owns the worker (with a
# setsid fallback when no user manager is running), so the turn that asked can
# end — and answer the next push-to-talk — while the work carries on. The
# job's state lives in a JSON sidecar $JOBS_DIR/<id>.json kept by
# lib/job-status; its output lands in $JOBS_DIR/<id>.log. Env is passed
# explicitly: user units get a bare PATH, and a scratch instance's jobs must
# stay in the scratch instance.
# Did this job die before it began? A builder that exits in seconds having
# written nothing but "You're out of usage credits" is not a failed build — no
# work was attempted, there is nothing in the log to verify, and the standing
# policy of dispatching a builder the moment work is noticed will keep firing
# them into the same wall, one wasted wake per corpse. Signature match on the
# CLI's own refusals (the shared CLAUDE_LIMIT_RE, so the fallback-retry sites
# and this judgement can never drift apart); anything else is a real failure
# and stays one.
job_output_blocked() {
    grep -qiE "$CLAUDE_LIMIT_RE" -- "$1" 2>/dev/null
}

# Record the block, with the line that proved it. One file, last block wins.
job_block_record() {
    mkdir -p "$JOBS_DIR" 2>/dev/null
    printf '%s\t%s\n' "$(date +%s)" "$1" > "$JOBS_BLOCKED_FILE" 2>/dev/null
}

# Prints "<age-seconds>\t<reason>" and returns 0 while a block is still fresh.
# It expires on its own rather than needing to be cleared: nothing here can see
# an account refill, so the next dispatch after the window IS the retry probe.
job_block_active() {
    local rec epoch reason age
    rec="$(head -n1 "$JOBS_BLOCKED_FILE" 2>/dev/null)" || return 1
    [ -n "$rec" ] || return 1
    epoch="${rec%%	*}"; reason="${rec#*	}"
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    age=$(( $(date +%s) - epoch ))
    [ "$age" -lt "$JOB_BLOCK_RETRY" ] || return 1
    printf '%s\t%s\n' "$age" "$reason"
}

# Stop a running detached job by id: kill its unit (or recorded pid) and mark
# it stopped. Grew out of `crab job stop <id>` being dispatched as a literal
# job whose task was the words "stop <id>".
job_stop() {
    local id="$1"
    [ -n "$id" ] && [ -e "$JOBS_DIR/$id.json" ] || { echo "Usage: crab job stop <id>   (ids: crab jobs)"; return 1; }
    local unit pid
    unit="$("$LIB_DIR/job-status" get "$JOBS_DIR/$id.json" unit 2>/dev/null || true)"
    pid="$("$LIB_DIR/job-status" get "$JOBS_DIR/$id.json" pid 2>/dev/null || true)"
    if [ -n "$unit" ]; then
        systemctl --user stop "$unit" 2>/dev/null
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
    fi
    "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" status=stopped
    echo "Job $id stopped."
}

job_start() {
    local workdir="$PROJECT_DIR" force=""
    while :; do
        case "${1:-}" in
            -C) workdir="${2:-$PROJECT_DIR}"; shift 2 2>/dev/null || shift $# ;;
            -f) force=1; shift ;;
            # Any other flag is a mistake, not a task description — once, a
            # stray --help was dispatched as a real job that ran `claude --help`.
            -*) echo "Unknown option '$1'. Usage: crab job [-C <workdir>] [-f] <description of the work>"; return 1 ;;
            *) break ;;
        esac
    done
    local task="$*"
    [ -n "$task" ] || { echo "Usage: crab job [-C <workdir>] [-f] <description of the work>"; return 1; }
    local block
    if [ -z "$force" ] && block="$(job_block_active)"; then
        echo "Not dispatched — the last job never began: ${block#*	}"
        echo "  Recorded $(( ${block%%	*} / 60 )) min ago; dispatch is held for ${JOB_BLOCK_RETRY} s from then, then the next job is the retry."
        echo "  Do the work by hand, or force it with: crab job -f <description>"
        return 1
    fi
    # A test may only ever prove that the preflight let it through. Past this
    # line is a real systemd unit running a real claude session on a real
    # account, and on 2026-08-07 two of them started from tests/test_job_block.sh
    # — one of which fired a completion wake at me, seven hours later, about a
    # job whose scratch log had long since been deleted.
    if [ -n "${DESKCRAB_NO_DISPATCH:-}" ]; then
        echo "Would dispatch (DESKCRAB_NO_DISPATCH set) in $workdir: $task"
        return 0
    fi
    local id unit
    # Timestamp + pid, like wake-at units: two dispatches in the same second
    # must not collide on the id or the unit name.
    id="$(date +%Y%m%d-%H%M%S)-$$"
    unit="deskcrab-job-$id"
    "$LIB_DIR/job-status" new "$JOBS_DIR" "$id" "$task" "$unit" || return 1
    if systemd-run --user --collect --quiet --unit="$unit" \
        --setenv=PATH="$HOME/.local/bin:$PATH" \
        --setenv=DESKCRAB_CONF="$CONF_FILE" \
        --setenv=DESKCRAB_STATE_PREFIX="$STATE_PREFIX" \
        --setenv=JOBS_DIR="$JOBS_DIR" \
        --setenv=CLAUDE_BIN="${CLAUDE_BIN:-}" \
        --setenv=CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}" \
        --setenv=JOB_MODEL="$JOB_MODEL" \
        --setenv=JOB_EFFORT="$JOB_EFFORT" \
        "$LIB_DIR/job-runner" "$id" "$workdir" 2>/dev/null; then
        echo "Job $id dispatched (unit $unit) — detached, it survives this turn ending."
    else
        # No usable user manager — detach by hand. setsid puts the worker in
        # its own session, out of reach of whatever ends this process tree.
        "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" unit=
        setsid "$LIB_DIR/job-runner" "$id" "$workdir" >/dev/null 2>&1 </dev/null &
        echo "Job $id dispatched (setsid — no systemd user manager) — detached."
    fi
    echo "  log: $JOBS_DIR/$id.log    list: crab jobs"
}

# One line per job, running first, recent finishes last — read by `crab jobs`
# and spliced into the self-state block so a later turn can report on work it
# neither started nor waited for. The report also reaps: a job whose unit is
# gone and whose recorded pid is dead is marked "died" instead of claiming
# "running" forever — a SIGKILLed worker never writes its own outcome.
#
# --live is the prompt copy: work that is running RIGHT NOW, plus — once — any
# job that ended badly since the last turn built this block. A failure is news
# exactly once; after that it is history, and history under a "right now"
# heading is how four running jobs came to be listed beside a build that died
# at two in the morning. The marker below is what "since the last turn" means:
# it is stamped every time the prompt copy is rendered, so the same corpse is
# never reported twice. A missing marker means this is the first render on this
# machine — nothing was missed, so nothing is owed, and the marker is stamped
# with no back-catalogue dumped into the prompt.
jobs_report() {  # [--live]
    local marker="${STATE_PREFIX}-jobs-surfaced" since
    local -a extra=()
    if [ "${1:-}" = "--live" ]; then
        since="$(cat "$marker" 2>/dev/null)"
        case "$since" in ''|*[!0-9]*) since="$(date +%s)" ;; esac
        extra=(--live --failed-since "$since")
    fi
    "$LIB_DIR/job-status" report "$JOBS_DIR" "$JOBS_SHOW_FINISHED" "$JOBS_KEEP_DAYS" "${extra[@]}" 2>/dev/null \
        || echo "  (job status unavailable)"
    [ "${1:-}" = "--live" ] && date +%s > "$marker"
    return 0
}
