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
# "Not logged in · Please run /login" earned its place here on 2026-08-07: four
# builder jobs in a row died on that single line while a fallback login was
# answering fine seconds later. It reads like an auth failure — the one thing
# this list is supposed to exclude — but a login is per-account by definition,
# so refusing to walk past it strands every job on one dead credential.
CLAUDE_LIMIT_RE="${CLAUDE_LIMIT_RE:-out of usage credits|usage limit reached|session limit reached|5-hour limit|weekly limit|hit your usage limit|hit your session limit|credit balance is too low|insufficient credit|out of extra usage|not logged in|please run /login}"
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
# Model for autonomous wakes, separately from the conversation. Most wakes are
# a shelf-check that ends in silence; measured 2026-08-07, wakes were the bulk
# of the day's token spend precisely because they ran the conversation's
# top-tier model. Default stays the conversation model — the split is a knob,
# not a policy.
WAKE_MODEL="${WAKE_MODEL:-$CLAUDE_MODEL}"
# Reap an autonomous wake only when it goes completely silent: an active session
# writes stream events constantly, so this many seconds without any output means
# it is hung, not thinking. Wall-clock limits would kill productive sessions.
WAKE_STALL_TIMEOUT="${WAKE_STALL_TIMEOUT:-300}"
# The same reaping for an INTERACTIVE turn, at a desk-appropriate patience:
# somebody asked this question out loud and is standing there waiting for the
# answer. On 2026-08-07 a desk turn hit a limit, swapped accounts, and sat in
# the second run for 680 s with nothing spoken and no error — the interactive
# path had no watchdog at all while the wake path did.
TURN_STALL_TIMEOUT="${TURN_STALL_TIMEOUT:-120}"
# And a ceiling on the WHOLE account walk, which the stall watchdog by
# construction cannot be: a session that keeps emitting output is never
# silent, and the walk itself was unbounded — one live run measured
# duration_ms 644964 on a fallback account nobody was told about. 0 disables.
TURN_CHAIN_TIMEOUT="${TURN_CHAIN_TIMEOUT:-900}"
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
# Reply audio for the phone, and the ONE glob the hourly sweep deletes by. It
# hangs off STATE_PREFIX rather than a hardcoded /tmp/deskcrab-remote-*.opus
# because the sweep is a pattern delete: a scratch instance running with its
# own state prefix used to reap the LIVE instance's clips, since both matched
# the same pattern in the same directory. On the live prefix this resolves to
# exactly the path it always had, so serve.py's /audio/ handler — which serves
# `deskcrab-remote-*.opus` and nothing else — is unaffected.
REMOTE_AUDIO_PREFIX="${REMOTE_AUDIO_PREFIX:-${STATE_PREFIX}-remote-}"
CONVOFILE="${STATE_PREFIX}-convo.txt"
CONVOLOCK="${STATE_PREFIX}-convo.lock"
SUMMARYFILE="${STATE_PREFIX}-convo-summary.txt"
# The rotation seam. A rotation archives the transcript and deletes it, and the
# next prompt used to open on an empty conversation layer that read exactly
# like nothing had ever been said. This marker is the difference: written only
# at the end of a rotation that verifiably succeeded, it holds when the
# archived record ended and whether a summary went with it, and the layer
# renders it as one line. Replaced only by the next rotation, deleted by
# nothing — a new conversation starting does not erase the fact an old one
# ended.
SEAMFILE="${STATE_PREFIX}-convo-seam.txt"
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
# The default file holds only where the chain stands NOW; every move it has
# ever made goes here, append-only. Without it "the chain moved" is a state
# with no history, and a turn that went quiet for ten minutes has no record
# anywhere she can read saying why.
#
# Derived from ACCOUNT_DEFAULT_FILE rather than from XDG on its own, so pinning
# one pins BOTH. This file was independent for about ten minutes, and in that
# time tests/test_limit_fallback.sh — which does pin the default file — wrote
# forty-four fabricated swaps into the LIVE log, which the state block would
# then have read back to her as real. A second knob a test has to know about is
# a knob a test will not know about.
ACCOUNT_LOG="${ACCOUNT_LOG:-$(dirname "$ACCOUNT_DEFAULT_FILE")/account-log}"
ACCOUNT_LOG_KEEP="${ACCOUNT_LOG_KEEP:-500}"
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
    # A signal handler that does not exit is not a signal handler: the shell
    # RESUMES where it was interrupted once the trap returns. So a TERM used to
    # deregister a live session — dropping its registration, its claim, its
    # checkpoint and its job-news stamp, and journalling it with an empty reply
    # — and then let it carry on generating and speaking, invisible to every
    # other session for the rest of its life. INT and TERM finish the session
    # and END it; the EXIT trap stays as it was, and session_finish is
    # idempotent, so the exit path costs nothing.
    trap session_finish EXIT
    trap 'session_finish; exit 143' INT TERM
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
    # `shift 2` with only one argument left is a NO-OP that returns 1, so the
    # loop re-tested the same unconsumed flag forever: `crab touching -w` pinned
    # a core until it was noticed. Every option loop here consumes its own flag
    # first, so a missing value ends the loop instead of spinning on it.
    while [ $# -gt 0 ]; do
        case "$1" in
            -w) win="${2:-$TOUCH_WINDOW}"; shift; [ $# -gt 0 ] && shift ;;
            -t) tier="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
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
    # An unspent job-news stamp dies with the session that rendered it; the
    # next one re-reads the same failures and offers them again.
    rm -f "${STATE_PREFIX}-jobs-surfaced.pending-$$"
    SESSION_FILE=""
}

# Prune registrations whose process is gone (a killed session leaves its file).
# A session killed with SIGKILL never ran its trap, so it also never journalled;
# reaping notes it as interrupted rather than letting it vanish silently.
session_reap() {
    # Everything a dead process left behind, and a registration is not the only
    # thing: an unregistered renderer of the state block leaves a job-news stamp
    # that no session_finish will ever drop. Before the early return, because a
    # machine with no sessions directory still renders blocks.
    jobs_news_sweep
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

# --- The state block: what all of her is doing --------------------------------
# Two audiences, and deliberately not the same report:
#   self_state_report            — `crab status`, the whole dashboard
#   self_state_report --prompt   — the CURRENT STATE OF YOURSELF block
#
# The prompt copy answers one question — what is running RIGHT NOW, what is
# about to happen, and what changed while she was not looking — and nothing
# else. History under a heading that says "right now" reads as live work: a job
# that failed at 02:06 sat in the block all day beside four running ones, and
# finished sessions from twelve hours back cost more prompt than everything
# live put together.
#
# Every list in here leads with its TOTAL. Five bullets with an unstated total
# of twenty-five is a false report, and it is the shape the false report
# actually took.

# One rendered wake, from a wake_list row. A wake is named by its clock time
# and its reason — "the 5:34 one, about the job that finished" — never by its
# unit id: a unit name is a digit-timestamp, and those belong on the display
# channel or nowhere.
# REASON FIRST, machinery after. A row read "scheduled: <reason> [booked by
# herself]" — the kind, a piece of queue vocabulary that answers nothing, in
# front of the only part that says what the appointment is FOR. Now it reads
#
#   - 13:00 — Kassandra bar 14: write the blind prediction (booked by you)
#
# so the sentence she can speak is the first thing on the line and the
# bookkeeping trails it in brackets, where it belongs. A booking with no reason
# says what a reason-less booking of that kind actually is, rather than
# printing the kind and stopping.
_wake_row_line() {  # <fire> <unit> <kind> <reason> <booked-at> <booked-by> <state> <width>
    local fire="$1" unit="$2" kind="$3" reason="$4" by="$6" state="$7" width="${8:-90}"
    local when what who note=""
    if [ "${fire:-0}" -gt 0 ]; then when="$(_wake_when "$fire")"; else when="moment unknown"; fi
    case "$state" in
        orphan) printf '  - %s — a timer with no booking record (another instance, or a record that was lost)\n' "$when"; return 0 ;;
        background) printf '  - %s — %s\n' "$when" "$reason"; return 0 ;;
    esac
    what="$reason"
    if [ -z "$what" ]; then
        case "${kind:-scheduled}" in
            event) what="something on this machine you asked to be told about" ;;
            *)     what="coming back to your wants (no agenda written down)" ;;
        esac
    fi
    # "booked by you" rather than "booked by herself": the record's word is
    # herself, and the reader of this line IS herself.
    who="$by"
    [ "$who" = herself ] && who="you"
    [ "$state" = unarmed ] && note=", RECORDED BUT NOT ARMED"
    [ "$state" = firing ] && note=", firing now"
    printf '  - %s — %s (booked by %s%s)\n' "$when" "$(_ellipsis "$what" "$width")" "$who" "$note"
}

# The wake queue, records first. See lib/wake-queue.sh: wake_list enumerates the
# durable records and joins the timers ONTO them. This used to be the other way
# round — it enumerated `systemctl list-timers` and consulted the records only
# to decorate a row it had already found — which is how twenty-five bookings on
# disk came to be rendered as "(none scheduled)" while she said out loud that
# nothing was scheduled.
_wake_pending_rows() { wake_list; }

# --brief is the prompt copy: the near horizon only, capped, with the total
# stated first and a count of everything further out. The full list is one
# command away, and a wake nine hours from now has no bearing on the turn being
# answered — but the NUMBER of them does.
wakes_report() {  # [--brief]
    local brief=0; [ "${1:-}" = "--brief" ] && brief=1
    local rows fire unit kind reason at by state _line
    local total=0 shown=0 later=0 unarmed=0 orphans=0 now horizon body=""
    rows="$(_wake_pending_rows)"
    now=$(date +%s); horizon=$(( now + WAKES_HORIZON_HOURS * 3600 ))
    while IFS= read -r _line; do
        # _split_tabs, not `read` with IFS=$'\t': a wake with no reason has an
        # empty middle field, and bash collapses runs of IFS whitespace.
        _split_tabs "$_line"
        fire="${_TF[0]:-}"; unit="${_TF[1]:-}"; kind="${_TF[2]:-}"
        reason="${_TF[3]:-}"; at="${_TF[4]:-}"; by="${_TF[5]:-}"; state="${_TF[6]:-}"
        [ -n "$unit" ] || continue
        case "$state" in
            orphan) orphans=$(( orphans + 1 )) ;;
            unarmed) unarmed=$(( unarmed + 1 )) ;;
        esac
        # The standing background row counts in the total because it is IN
        # the list below it — a header reading "1 total" above two bullets is
        # the numbers-don't-match failure rule 5 exists to prevent. Its row
        # already says what it is.
        total=$(( total + 1 ))
        if [ "$brief" = 1 ]; then
            if [ "$shown" -ge "$WAKES_SHOW" ] || { [ "${fire:-0}" -gt "$horizon" ] && [ "$state" != unarmed ]; }; then
                later=$(( later + 1 )); continue
            fi
            body="$body$(_wake_row_line "$fire" "$unit" "$kind" "$reason" "$at" "$by" "$state" 90)
"
        else
            body="$body$(_wake_row_line "$fire" "$unit" "$kind" "$reason" "$at" "$by" "$state" 120)
      $unit
"
        fi
        shown=$(( shown + 1 ))
    done <<< "$rows"

    # The count leads, always, and it reads as a measurement rather than as a
    # claim about the world — an empty queue says zero, it does not say that
    # nothing is happening.
    if [ "$brief" = 1 ]; then
        if [ "$total" -eq 0 ]; then
            echo "Pending wakes (next ${WAKES_HORIZON_HOURS}h): 0 total — the queue is empty as of this snapshot."
            return 0
        fi
        printf 'Pending wakes (next %sh): %d total, %d shown (all of them: crab status)\n' \
            "$WAKES_HORIZON_HOURS" "$total" "$shown"
    else
        if [ "$total" -eq 0 ]; then
            echo "Pending wakes: 0 total — the queue is empty as of this snapshot."
            return 0
        fi
        printf 'Pending wakes: %d total\n' "$total"
    fi
    printf '%s' "$body"
    [ "$brief" = 1 ] && [ "$later" -gt 0 ] && printf '  +%d further out (crab status for the rest)\n' "$later"
    # A record with no live timer is a booking whose timer died with a user
    # manager. It is exactly what the restore pass exists to heal, and saying
    # so is the difference between a queue that looks broken and one that says
    # what is wrong with it.
    [ "$unarmed" -gt 0 ] && printf '  ! %d of these %s RECORDED WITH NO LIVE TIMER — %s not fire until '"'"'crab wake-restore'"'"' re-arms %s.\n' \
        "$unarmed" "$([ "$unarmed" = 1 ] && echo is || echo are)" \
        "$([ "$unarmed" = 1 ] && echo 'it will' || echo 'they will')" \
        "$([ "$unarmed" = 1 ] && echo it || echo them)"
    [ "$orphans" -gt 0 ] && printf '  ! %d live timer%s no booking record — either a lost record or another instance.\n' \
        "$orphans" "$([ "$orphans" = 1 ] && echo ' has' || echo 's have')"
    return 0
}

# Where "since your last reply" begins: the moment she last SAID something to
# him and finished saying it. A fixed thirty-minute window is filled entirely by
# desk turns during a fast exchange, and the wake that fired between them is
# pushed out of the list — which is the shape of the afternoon that produced
# "nothing running, nothing scheduled".
#
# "The previous session's finish" is not the same thing, and taking it literally
# made this line structurally incapable of reporting a wake. A wake IS a
# session, so the last wake to finish set the anchor, and the wake was then
# measured against its own finishing time and counted as nothing. Every wake
# that fired between two turns was invisible in the one line written to say so.
#
# So the anchor is the last session that reached him: a desk turn, a phone turn,
# or a wake that got past the delivery gates. Which one that is comes off the
# log itself — field 4 is the kind and field 5 is the outcome, and a session
# that delivered NOTHING writes its outcome as a parenthesised note ("(silent
# — ...", "(muted — ...", "(quiet hours — ...", "(killed — no summary)", "(no
# reply — ...", "(wake failed before the model ran ..."), where a session that
# spoke writes the words. That convention is what makes a delivered wake
# distinguishable from a silent one, and it is held by every writer of the log.
_state_delta_anchor() {
    local a=0
    if [ -s "$SESSIONS_LOG" ]; then
        a="$(awk -F'\t' '
            $4 != "desktop turn" && $4 != "phone turn" && $4 != "autonomous wake" { next }
            $5 ~ /^[[:space:]]*\(/ { next }
            { s = $1; gsub(/[-:]/, " ", s); st = mktime(s)
              if (st < 0) next
              fin = st + (($3 == "?") ? 0 : $3 + 0)
              if (fin > max) max = fin }
            END { printf "%d", max + 0 }' "$SESSIONS_LOG" 2>/dev/null)"
    fi
    case "${a:-}" in ''|*[!0-9]*) a=0 ;; esac
    # Nothing has ever reached him on this machine — a fresh state directory, or
    # a log just rotated away. Then the anchor is the same half hour the
    # recently-finished list uses, stated rather than assumed.
    [ "$a" -gt 0 ] || a=$(( $(date +%s) - SESSIONS_RECENT_MINUTES * 60 ))
    echo "$a"
}

# What happened between that moment and now, in one line: wakes fired, wakes
# booked and by whom, jobs dispatched and jobs that ended badly, and every
# change to the queue. The queue changes come from the durable ledger, which is
# the whole reason it exists — a bulk restore means a cancellation was undone
# or the machine rebooted, and that used to go to /dev/null.
_state_delta_line() {  # <anchor epoch>
    local anchor="$1" now mins parts="" fired booked jobline changes
    now=$(date +%s); mins=$(( (now - anchor) / 60 ))
    fired=0
    # Counted by the moment each one ENDED, matching the anchor. A wake is the
    # long thing in the gap between two turns: counted by its start, a wake that
    # began before her last reply and worked for half an hour afterwards is not
    # in the span at all — and it is the whole of what happened while she was
    # away. A reaped wake has no duration, so its finish is its start.
    [ -s "$SESSIONS_LOG" ] && fired="$(awk -F'\t' -v cut="$anchor" '
        $4 == "autonomous wake" {
            s = $1; gsub(/[-:]/, " ", s); st = mktime(s)
            if (st < 0) next
            if (st + (($3 == "?") ? 0 : $3 + 0) >= cut) n++ }
        END { printf "%d", n + 0 }' "$SESSIONS_LOG" 2>/dev/null)"
    [ "${fired:-0}" -gt 0 ] && parts="$parts; $fired wake$([ "$fired" = 1 ] || echo s) fired"

    booked="$(awk -F'\t' -v cut="$anchor" '
        $1 + 0 >= cut && $2 == "booked" { n++; by[$6]++ }
        END { if (n == 0) exit
              out = ""
              for (a in by) out = out (out == "" ? "" : ", ") a " " by[a]
              printf "%d wake%s (%s)", n, (n == 1 ? "" : "s"), out }' "$WAKE_LEDGER" 2>/dev/null)"
    [ -n "$booked" ] && parts="$parts; $booked booked"

    jobline="$("$LIB_DIR/job-status" since "$JOBS_DIR" "$anchor" 2>/dev/null)"
    [ -n "$jobline" ] && parts="$parts; $jobline"

    changes="$(awk -F'\t' -v cut="$anchor" '
        $1 + 0 >= cut && $2 != "booked" { n[$2]++ }
        END { out = ""
              for (a in n) out = out (out == "" ? "" : ", ") n[a] " " a
              printf "%s", out }' "$WAKE_LEDGER" 2>/dev/null)"
    [ -n "$changes" ] && parts="$parts; queue changes: $changes"

    # The chain moving is news of the same kind: it explains a silence.
    local walks
    walks="$(awk -F'\t' -v cut="$anchor" '$1 + 0 >= cut { n++; last = $2 " -> " $3 }
        END { if (n > 0) printf "%d (last: %s)", n, last }' "$ACCOUNT_LOG" 2>/dev/null)"
    [ -n "$walks" ] && parts="$parts; account chain walked $walks"

    printf 'Since your last reply (%s, %d min ago)%s\n' \
        "$(date -d "@$anchor" '+%H:%M')" "$mins" \
        "${parts:+:${parts#;}}${parts:+.}"
    [ -n "$parts" ] || printf '  (nothing fired, nothing was booked, no job was dispatched, and the queue did not change.)\n'
}

# Which login answers next, and why the default last moved. `crab status` has
# led with this for a while; the prompt was the one place it was missing, so
# nothing she could read said which account was answering or that the chain had
# moved at all.
account_state_line() {
    local acct why when
    acct="$(claude_account_default)"
    if [ "$acct" = "$CLAUDE_PRIMARY_TOKEN" ]; then acct="primary"; else acct="$(basename "$acct")"; fi
    why="$(head -n1 "$ACCOUNT_DEFAULT_FILE" 2>/dev/null | cut -f3)"
    when="$(head -n1 "$ACCOUNT_DEFAULT_FILE" 2>/dev/null | cut -f2)"
    case "${when:-}" in ''|*[!0-9]*) when="" ;; *) when="$(date -d "@$when" '+%H:%M')" ;; esac
    printf 'Account: %s answers next' "$acct"
    [ -n "$why" ] && printf ' (%s%s)' "$why" "${when:+, $when}"
    printf '\n'
}

self_state_report() {
    local brief=0
    [ "${1:-}" = "--prompt" ] && brief=1
    session_reap
    local f kind pid started epoch startt n=0 body=""
    for f in "$SESSIONS_DIR"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.claim|*.ckpt) continue ;; esac
        IFS=$'\t' read -r kind pid started epoch startt < "$f"
        [ "$pid" = "$$" ] && kind="$kind (this one)"
        body="$body$(printf '  - %s, pid %s, started %s' "$kind" "$pid" "$started")
"
        # What it says it is holding, so another hand can avoid the same files.
        [ -s "$f.claim" ] && body="$body$(printf '      holding: %s' "$(cat "$f.claim")")
"
        # Its latest checkpoint — where the work stood last time it said so.
        [ -s "$f.ckpt" ] && body="$body$(tail -n 1 "$f.ckpt" \
            | awk -F'\t' '{ printf "      last checkpoint (%s): %s", $1, $2 }')
"
        n=$((n+1))
    done
    printf 'Live sessions: %d total%s\n' "$n" \
        "$([ "$n" -eq 0 ] && printf ' — nothing else of you is running as of this snapshot')"
    printf '%s' "$body"

    if [ "$brief" = 1 ]; then
        # --defer: the once-only news of a job that ended badly is CONSUMED
        # only when this block is actually delivered to a session that will be
        # heard. Stamping it on every render let a wake that ended silently eat
        # the news, and the next audible session never saw it.
        local jobs_body
        jobs_body="$(jobs_report --live --defer)"
        printf 'Detached jobs running now: %d total (finished and failed ones: crab jobs)\n' \
            "$(printf '%s\n' "$jobs_body" | grep -c '^  - running ')"
        printf '%s\n' "$jobs_body"
        wakes_report --brief
        # Only when there is something to pick up: an empty "Interrupted"
        # heading is two lines of prompt saying nothing happened.
        local interrupted; interrupted="$(interrupted_report)"
        case "$interrupted" in
            *"(none)"*) : ;;
            *) printf 'Interrupted mid-work: %d total (edits may be on disk — pick up or '"'"'crab resolve'"'"')\n' \
                   "$(printf '%s\n' "$interrupted" | grep -c '^  - ')"
               echo "$interrupted" ;;
        esac
        local recent anchor
        recent="$(session_history --recent)"
        printf 'Recently finished (last %s min — older: crab status, crab journal): %d total\n' \
            "$SESSIONS_RECENT_MINUTES" "$(printf '%s\n' "$recent" | grep -c '^  - ')"
        printf '%s\n' "$recent"
        anchor="$(_state_delta_anchor)"
        _state_delta_line "$anchor"
        account_state_line
    else
        local jobs_body
        jobs_body="$(jobs_report)"
        printf 'Detached background jobs: %d listed (they outlive turns — launch: crab job <description>; list: crab jobs)\n' \
            "$(printf '%s\n' "$jobs_body" | grep -c '^  - ')"
        printf '%s\n' "$jobs_body"
        local interrupted; interrupted="$(interrupted_report)"
        printf 'Interrupted mid-work: %d total (edits may be on disk — pick up or '"'"'crab resolve'"'"')\n' \
            "$(printf '%s\n' "$interrupted" | grep -c '^  - ')"
        printf '%s\n' "$interrupted"
        wakes_report
        local recent
        recent="$(session_history)"
        printf 'Recently finished (last %sh): %d total\n' "$SESSIONS_LOG_HOURS" \
            "$(printf '%s\n' "$recent" | grep -c '^  - ')"
        printf '%s\n' "$recent"
    fi
}

# --- Append-only records that are read, not archived ------------------------
# One line in, and a trim when the file has grown to twice what it keeps. Both
# halves under the file's own lock, because these are written by hands that do
# not know about each other — the wake ledger by every booker, the account log
# by every path that meets a refusal.
#
# `tail -n K F > F.tmp && mv F.tmp F` is not a safe trim on its own: a line
# appended between the read and the rename is thrown away with the old file,
# and two rotations racing each other through one fixed temp name leave
# whichever finished second. The lock closes the first hole and the pid in the
# temp name closes the second.
log_append_bounded() {  # <file> <keep> <line>
    local f="$1" keep="$2" line="$3" n
    mkdir -p "$(dirname "$f")" 2>/dev/null
    {
        flock -w 10 5
        printf '%s\n' "$line" >> "$f" 2>/dev/null
        n="$(wc -l < "$f" 2>/dev/null || echo 0)"
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        if [ "$n" -gt $(( keep * 2 )) ]; then
            if tail -n "$keep" "$f" > "$f.tmp.$$" 2>/dev/null; then
                mv -f "$f.tmp.$$" "$f" 2>/dev/null
            fi
            rm -f "$f.tmp.$$" 2>/dev/null
        fi
    } 5>>"$f.lock"
    return 0
}

# --- Durable wakes ---------------------------------------------------------
# The whole queue lives in ONE module, and nothing outside it touches
# $WAKES_DIR or calls systemd-run for a wake. Booking, cancellation,
# restoration, tidying and enumeration are all behind wake_book / wake_cancel /
# wake_restore / wake_tidy / wake_list, because the failure this splits up was
# a report that read systemd while twenty-five bookings sat unread on disk.
source "$LIB_DIR/wake-queue.sh"

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

# A rotation that fails must be impossible to miss. Losing a transcript looks
# like nothing at all from the outside — every path keeps working and the record
# simply stops growing — so the failure is said in the three places anyone
# looks: the speech log, standard error (which is what `journalctl --user -u
# deskcrab-serve` shows for a phone turn), and the desktop.
rotate_failed() {  # <why>
    speech_log "conversation rotation FAILED: $1 (the transcript was left in place)"
    notify-send -t 10000 -h string:x-dunst-stack-tag:deskcrab-rotate \
        "${NOTIFY_NAME:-DeskCrab}" \
        "Conversation rotation failed — the transcript is still here, unarchived. $1" 2>/dev/null
    return 0
}

# Copy one file into the archive so the destination never exists half-written
# and the source is never removed on the strength of a copy nobody checked.
# Writes beside the destination, compares the byte count against the source,
# and only then gives it its name — a rename inside one directory, which is
# atomic. Any failure leaves both files exactly where they were.
_archive_verified() {  # <src> <dest>
    local SRC="$1" DEST="$2" PART="$2.part.$$" WANT HAVE
    WANT=$(wc -c < "$SRC" 2>/dev/null) || WANT=""
    if [ -z "$WANT" ]; then
        rotate_failed "could not measure $SRC"
        return 1
    fi
    if ! cp "$SRC" "$PART" 2>/dev/null; then
        rm -f "$PART" 2>/dev/null
        rotate_failed "could not write into $(dirname "$DEST")"
        return 1
    fi
    HAVE=$(wc -c < "$PART" 2>/dev/null) || HAVE="-"
    if [ "$HAVE" != "$WANT" ]; then
        rm -f "$PART" 2>/dev/null
        rotate_failed "the archived copy of $SRC came out $HAVE bytes, not $WANT"
        return 1
    fi
    if ! mv "$PART" "$DEST" 2>/dev/null; then
        rm -f "$PART" 2>/dev/null
        rotate_failed "could not name the archive $DEST"
        return 1
    fi
    return 0
}

# Archive stale conversation (default: >5 min idle). Under the convo lock like
# every other writer: the move would otherwise be able to carry off a turn
# another client appended a microsecond earlier.
#
# The conversation lives on tmpfs and the archive lives on disk, so `mv` between
# them is a copy followed by an unlink, not a rename — and a copy that runs out
# of room leaves a SHORT archive and unlinks the original anyway. This used to
# be exactly that mv, with nothing checked and nothing said. So now the archive
# is written under a partial name, checked byte for byte against the source, and
# only given its real name once it matches; the conversation is deleted only
# after the archive demonstrably exists at full length. On any failure the
# conversation stays where it is — the next turn simply continues it — and the
# failure is announced. A conversation that keeps going is a nuisance; one that
# is quietly eaten is not recoverable.
rotate_convo() {
    { flock -w 60 9; _rotate_convo_locked; } 9>"$CONVOLOCK"
}

_rotate_convo_locked() {
    [ -f "$CONVOFILE" ] || return 0
    local LAST_MOD NOW STAMP DEST N HAD_SUMMARY=no
    LAST_MOD=$(stat -c %Y "$CONVOFILE" 2>/dev/null) || return 0
    NOW=$(date +%s)
    (( NOW - LAST_MOD >= CONVO_TIMEOUT )) || return 0

    if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
        rotate_failed "the archive directory could not be made: $ARCHIVE_DIR"
        return 1
    fi

    STAMP="$(date -d "@$LAST_MOD" '+%Y%m%d-%H%M%S')"
    DEST="$ARCHIVE_DIR/$STAMP.txt"
    # Two conversations can fall idle in the same second, and the second must
    # not land on top of the first.
    N=2
    while [ -e "$DEST" ]; do DEST="$ARCHIVE_DIR/$STAMP-$N.txt"; N=$((N + 1)); done

    # The summary goes first, and keeps the transcript's name so the pair stays
    # together. If it cannot be archived, the transcript is still here to try
    # again with, which is the half that matters.
    if [ -f "$SUMMARYFILE" ]; then
        _archive_verified "$SUMMARYFILE" "${DEST%.txt}-summary.txt" || return 1
        rm -f "$SUMMARYFILE"
        HAD_SUMMARY=yes
    fi
    _archive_verified "$CONVOFILE" "$DEST" || return 1
    rm -f "$CONVOFILE"

    # Only now, with the archive proven and the originals gone, mark the seam:
    # the next prompt says the record restarted and when the old one ended,
    # instead of opening on an emptiness indistinguishable from nothing ever
    # having been said. Written under a temporary name and renamed, so a prompt
    # assembling mid-rotation never reads it half-written. Every failure path
    # above returned before reaching this line, so a rotation that failed
    # leaves whatever marker the last successful one wrote.
    if printf 'ended=%s\nsummary=%s\n' "$LAST_MOD" "$HAD_SUMMARY" \
            > "$SEAMFILE.tmp.$$" 2>/dev/null; then
        mv "$SEAMFILE.tmp.$$" "$SEAMFILE" 2>/dev/null || rm -f "$SEAMFILE.tmp.$$"
    else
        rm -f "$SEAMFILE.tmp.$$"
    fi
    return 0
}

# L6 of the prompt: the conversation, summary first, live blocks after, under a
# byte cap. The cap is new and the reason is measured: this layer was bounded
# by a COUNT of turns and by nothing else, so its size was whatever twenty
# blocks happened to weigh — 4,248 bytes on a quiet afternoon and 29,936 in the
# archives. A layer that can quadruple without anything changing is a layer
# that pushes everything else out of the window.
#
# The cap keeps the NEWEST blocks and drops from the front, on a block
# boundary, and says that it did. Nothing about compaction changes: the file on
# disk is untouched, compact_convo still folds the oldest blocks into the
# summary at CONVO_MAX_TURNS, and this is only what gets rendered into one
# prompt.
build_convo_context() {  # [byte cap, 0 = uncapped]
    local CAP="${1:-0}" OUT="" BODY="" NOTE="" SEAM="" SEAM_END="" SEAM_SUM="" SEAM_STAMP=""
    # The rotation seam, read tolerantly. The marker is only ever written whole
    # by a rotation that succeeded, but a prompt build must survive anything on
    # disk: a marker this cannot parse costs the line and nothing else. The end
    # stamp is rendered in the block headers' own format, with no relative
    # wording — she does the arithmetic against the clock herself, exactly as
    # she does for block stamps.
    if [ -f "$SEAMFILE" ]; then
        SEAM_END="$(sed -n 's/^ended=//p' "$SEAMFILE" 2>/dev/null | head -n1)"
        SEAM_SUM="$(sed -n 's/^summary=//p' "$SEAMFILE" 2>/dev/null | head -n1)"
        case "$SEAM_END" in
            ''|*[!0-9]*) ;;
            *)
                SEAM_STAMP="$(date -d "@$SEAM_END" '+%Y-%m-%d %H:%M' 2>/dev/null)" || SEAM_STAMP=""
                if [ -n "$SEAM_STAMP" ]; then
                    SEAM="This record starts fresh: the previous conversation ended at $SEAM_STAMP and was archived"
                    if [ "$SEAM_SUM" = "yes" ]; then
                        SEAM="$SEAM; its earlier turns had already been condensed before it was archived."
                    else
                        SEAM="$SEAM."
                    fi
                fi
                ;;
        esac
    fi
    # A seam with nothing after it is still a layer: right after a rotation,
    # before anything new is said, the preamble and the seam line are exactly
    # what stops an empty record reading as "nothing has ever been said".
    [ -s "$CONVOFILE" ] || [ -s "$SUMMARYFILE" ] || [ -n "$SEAM" ] || return 0

    OUT="THE CONVERSATION SO FAR — the record of WHAT WAS SAID, and it is authoritative for what was said and promised. For that and nothing else: what is running, what is scheduled and what was dispatched belong to the state block above, and most of what is scheduled was never typed into this conversation at all. A command's output never overrides these words — a clean search does not mean a thing you can read yourself writing here never happened — and when a search and this record disagree, say that they disagree rather than quietly picking the search.
Each block is headed with the local time it was said, 'User [2026-08-07 12:01]:'. Read them: they are how you tell a minute ago from this morning. Compare them against the time given above, and say 'a few minutes ago' or 'about two hours ago' rather than reading a stamp aloud. A block with no stamp is older than this record kept one — you know only that it came before the stamped ones.
A block marked '(autonomous wake)' in its header is one you wrote to yourself while nobody was talking to you. It is not something he has read and it is not part of what he said: never continue its subject, defend it, or treat it as a thing he is replying to, unless he raises it himself."

    # The seam sits directly under the preamble, above the condensed summary
    # and the blocks: one line, never two.
    if [ -n "$SEAM" ]; then
        OUT="$OUT

$SEAM"
    fi

    if [ -s "$SUMMARYFILE" ]; then
        OUT="$OUT

Earlier turns, condensed:
$(cat "$SUMMARYFILE")"
    fi

    if [ -s "$CONVOFILE" ]; then
        local ROOM=0
        [ "$CAP" -gt 0 ] && ROOM=$(( CAP - $(printf '%s' "$OUT" | wc -c) - 120 ))
        if [ "$CAP" -gt 0 ] && [ "$ROOM" -lt 400 ]; then
            # The preamble alone has eaten the layer. Keep the last few blocks
            # rather than none: a transcript layer with no transcript in it is
            # worse than a short one.
            ROOM=400
        fi
        if [ "$CAP" -gt 0 ] && [ "$(wc -c < "$CONVOFILE")" -gt "$ROOM" ]; then
            BODY="$(_convo_tail_blocks "$CONVOFILE" "$ROOM")"
            NOTE="
(the earlier part of this conversation is not in this prompt — the whole day is in 'crab journal')"
        else
            BODY="$(cat "$CONVOFILE")"
        fi
        OUT="$OUT$NOTE

$BODY"
    fi
    printf '%s' "$OUT"
}

# The last <bytes> of a conversation file, starting at a block boundary. A tail
# that begins mid-block hands her half a sentence with no idea who said it.
_convo_tail_blocks() {  # <file> <bytes>
    tail -c "$2" "$1" | awk -v re="$CONVO_BLOCK_RE" '
        started { print; next }
        $0 ~ re { started = 1; print }'
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
# And who wrote it. A block she wrote to herself on an autonomous wake is
# headed "Assistant [2026-08-07 12:38] (autonomous wake): ", because without
# the marker a wake's words sit in the transcript looking exactly like
# something she said TO him and he read — so the next turn defends a subject he
# never raised, or picks up a thread that only ever existed inside her own
# head. Optional in every pattern, same as the stamp: every conversation
# written before this, and every archive of one, keeps parsing.
CONVO_MARK_RE='( [(][^)]*[)])?'
CONVO_USER_RE="^User${CONVO_STAMP_RE}${CONVO_MARK_RE}: "
CONVO_ASSISTANT_RE="^Assistant${CONVO_STAMP_RE}${CONVO_MARK_RE}: "
CONVO_BLOCK_RE="^(User|Assistant)${CONVO_STAMP_RE}${CONVO_MARK_RE}: "

# The stamp itself. Local time to the minute: this is for telling a minute ago
# from this morning, not for timing anything.
convo_stamp() { date '+%Y-%m-%d %H:%M'; }

# The only two writers of a conversation block. Every path that speaks or is
# spoken to — desktop turn, phone turn, autonomous wake — goes through these,
# so the stamp cannot be added in one place and forgotten in another.
convo_append_user() { convo_append 'User [%s]: %s\n' "$(convo_stamp)" "$1"; }
# --wake marks the block as one she wrote to herself, unprompted. Every wake
# that delivers words goes through this, so the marker cannot be written on one
# path and forgotten on another.
convo_append_assistant() {  # [--wake] <text>
    local mark=""
    [ "${1:-}" = "--wake" ] && { mark=" (autonomous wake)"; shift; }
    convo_append 'Assistant [%s]%s: %s\n\n' "$(convo_stamp)" "$mark" "$1"
}

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

    # A classifier's shape, not a desktop's: the instructions are the system
    # prompt, the material is the question, and the run carries no tools, no
    # skills and no MCP servers (claude_classify). Condensing ten blocks of
    # text needs none of them, and paying a full CLI boot for it cost about
    # 35 KB of listings every time the live conversation passed its ceiling.
    local SUMSYS SUMMATERIAL NEWSUM
    SUMSYS="You are condensing the older part of a conversation between ${ASSISTANT_NAME:-the assistant} and the user, to save context.
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
is only ever a file path, a systemd unit, or a repo name, never a person."

    SUMMATERIAL="=== Prior summary ===
${PRIOR:-(none)}

=== New excerpt to fold in ===
$(cat "$OLDFILE")"

    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    # The accounts are walked like every other run, and each attempt is judged
    # the way every other run judges one: claude_stream_refusal, over the bytes
    # of THIS attempt, which asks two structural questions — did the CLI's own
    # synthetic marker carry the limit signature, and was there any genuine
    # model output at all.
    #
    # It could not be asked here before, because this run had no stream to ask
    # it of: `-p` in its default text mode returns one undifferentiated blob, so
    # the judgement was `grep "$CLAUDE_LIMIT_RE"` over the summariser's own
    # ANSWER. The material being summarised is a conversation with her, and the
    # conversations that reach this threshold are frequently about accounts
    # running dry — so a faithful summary of an afternoon reads "the session
    # limit was reached at 14:20 and the chain moved on", every phrase of it in
    # the signature. That summary was read as a refusal: the account that wrote
    # it was stamped dry, the durable default moved off it, the next login was
    # made to write the same summary again, and when the chain ran out the
    # compaction was abandoned with the turns still unfolded.
    # specs/account-fallback.md rule 15, rule 30 (capture what the CLI says on
    # its own channel), and rule 31 (a refusal is never committed as a summary).
    #
    # So the run gets the same stream shape as a wake — one file of its own,
    # never $DEBUGLOG, which the viewer is tailing — and the answer is read out
    # of the events rather than off the pipe. A CLI that answers in plain text
    # anyway (a stub, or a future default) leaves a log with no events in it,
    # and its whole text is the answer: degrading to the old shape is right, and
    # a refusal on that path still reads as one, because a stream with nothing
    # but the CLI's own words in it is exactly what rule 12 describes.
    local SUMRC=0 SUMCONF="" ACCT REFUSAL
    local SUMLOG="${STATE_PREFIX}-convo-sum-stream.$$"
    NEWSUM=""
    for ACCT in $(claude_accounts); do
        SUMCONF="$(claude_account_confdir "$ACCT")"
        SUMRC=0
        : > "$SUMLOG"
        { if [ -n "$SUMCONF" ]; then export CLAUDE_CONFIG_DIR="$SUMCONF"
          else unset CLAUDE_CONFIG_DIR; fi
          printf '%s' "$SUMMATERIAL" \
              | CLAUDE_CLASSIFY_STREAM=1 claude_classify "$CONVO_SUMMARY_MODEL" "$SUMSYS"
        } >>"$SUMLOG" 2>&1 || SUMRC=$?
        if REFUSAL="$(claude_stream_refusal "$SUMLOG")"; then
            claude_limit_record "$SUMCONF" "$REFUSAL"
            continue
        fi
        # Not a refusal. Anything else that went wrong goes wrong on the next
        # login too, so it ends the walk rather than spending the chain.
        [ "$SUMRC" -eq 0 ] || break
        NEWSUM="$(DESKCRAB_DEBUGLOG="$SUMLOG" "$LIB_DIR/extract-response" 2>/dev/null)"
        if [ -z "$NEWSUM" ] && ! grep -q '"type":' "$SUMLOG" 2>/dev/null; then
            NEWSUM="$(cat "$SUMLOG" 2>/dev/null)"
        fi
        break
    done
    rm -f "$SUMLOG"

    if [ -n "$NEWSUM" ]; then
        # Write the summary whole, then move it into place. A redirect onto
        # $SUMMARYFILE truncates it first, so a write that dies halfway would
        # destroy the old summary AND leave a torn new one — and _compact_drop
        # would then drop the turns it was supposed to be standing in for.
        # Nothing is dropped unless the summary that replaces it is fully on
        # disk.
        local SUMTMP="$SUMMARYFILE.new.$$"
        if printf '%s\n' "$NEWSUM" > "$SUMTMP" && mv "$SUMTMP" "$SUMMARYFILE"; then
            { flock -w 60 9; _compact_drop "$LINES"; } 9>"$CONVOLOCK"
        else
            rm -f "$SUMTMP" 2>/dev/null
            rotate_failed "the summary could not be written, so no turns were folded away"
        fi
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
# The remainder is counted before it is allowed to replace the conversation.
# This is the same rule the archive follows: a swap is only safe when the thing
# swapped in has been shown to hold what it should. A tail that stops short
# would otherwise hand back a conversation missing turns that were never
# summarised, and say nothing.
_compact_drop() {
    local NEWFILE="/tmp/deskcrab-convo-new.$$" HAD WANT HAVE
    HAD=$(wc -l < "$CONVOFILE" 2>/dev/null) || HAD=""
    [ -n "$HAD" ] || return 1
    WANT=$(( HAD - $1 ))
    if ! tail -n "+$(( $1 + 1 ))" "$CONVOFILE" > "$NEWFILE" 2>/dev/null; then
        rm -f "$NEWFILE" 2>/dev/null
        rotate_failed "the compacted conversation could not be written; no turns were folded away"
        return 1
    fi
    HAVE=$(wc -l < "$NEWFILE" 2>/dev/null) || HAVE="-"
    if [ "$HAVE" != "$WANT" ]; then
        rm -f "$NEWFILE" 2>/dev/null
        rotate_failed "compaction would have left $HAVE lines where $WANT were expected"
        return 1
    fi
    mv "$NEWFILE" "$CONVOFILE" 2>/dev/null || { rm -f "$NEWFILE" 2>/dev/null; return 1; }
}

# The titles on the wants shelf, one per line — the ONE reading of that file's
# bullet list, because there were two and they drifted. The prompt's grep was
# made emoji-tolerant on 2026-08-07; lib/promise-audit's copy (`grep -E
# '^- \*\*'`) was never updated, and every live want is written `- 🎼 **Title**`,
# so the auditor's list matched ZERO of eleven. It is handed that list under the
# words "this list is complete" and told to err on the side of flagging, so an
# empty list makes everything she has already written down look unrecorded:
# 172 UNSAVED verdicts in 309 audits, one event wake booked for each — the wake
# storm. One grep, one function, both callers.
wants_titles() { # [<wants file>]
    local f="${1:-${WANTS_FILE:-}}"
    [ -n "$f" ] && [ -s "$f" ] || return 0
    grep -oP '^- \*\*.*?\*\*|^- [^ ]+ \*\*.*?\*\*' "$f" 2>/dev/null || true
}

# The conduct drawer, read exactly the way the wants shelf is read: the
# binding test verbatim, the rule titles, and every body left on disk. Conduct
# used to be injected as a whole uncapped file ten lines after the shelf was
# deliberately cut to titles, with a comment above the shelf explaining why a
# shelf in the prompt becomes a dumping ground. Both readers live here so the
# prompt and any auditor read the same list — two readers with different
# patterns is how the promise auditor was handed an empty list and told the
# list was complete.
#
# The binding test is the file's first blockquote line. It is emitted VERBATIM
# and is never trimmed: conduct is owed rather than chosen, and a paraphrase of
# the test regresses the corrections underneath it.
conduct_binding() {  # <conduct file>
    [ -s "${1:-}" ] || return 0
    grep -m1 '^> ' "$1" 2>/dev/null | sed 's/^> //' || true
}

# One line per rule: the bullet up to the end of its bold title, plus the file
# its body lives in when the line names one. A bullet with no bold title is
# already a title and passes through whole.
conduct_titles() {  # <conduct file>
    [ -s "${1:-}" ] || return 0
    grep '^- ' "$1" 2>/dev/null | sed -E \
        -e 's/^(- [^*]*\*\*[^*]+\*\*).*→ `([^`]+)`.*$/\1 → \2/' \
        -e 't' \
        -e 's/^(- [^*]*\*\*[^*]+\*\*).*$/\1/' || true
}

# --- Prompt assembly -------------------------------------------------------
# specs/prompt-assembly.md. One assembler, four profiles, one layer order, a
# measured byte budget per layer, and the user's own words delivered as the
# user message — never buried in the middle of the system prompt.
#
#   build_system_prompt [--profile turn|wake|job|classify]
#                       [--manifest <file>] [--layers]
#
# The layers, always in this order; a layer a profile does not include is
# absent, and the survivors do not reorder:
#
#   L1 identity    who she is, how she speaks, what the display channel is
#   L2 state       the state block, specs/self-awareness.md, verbatim
#   L3 memory      the recall block
#   L4 shelves     wants titles; conduct's binding test and rule titles
#   L5 index       WHERE THINGS ARE — one line per drawer she owns
#   L6 transcript  the summary and the live conversation, capped in bytes
#   regroup        conditional: another of her has the floor as this begins
#   L7 ranking     how to weigh what she has been handed
#   L8 frame       names the message below as the subject of this turn
#
# L8 is last and the message is not in here at all — it goes to the CLI as the
# positional prompt. Six sections and roughly 25 KB used to sit between the
# state block and the thing he actually said, and the reply reliably answered
# the 25 KB. "I thought all of your wakes were in your prompt. Every single
# turn." — "They are. It's right there at the top of every turn, and I didn't
# read it."
#
# --layers prints the manifest instead of the prompt: one line per layer,
# <key> <TAB> <bytes> <TAB> <budget> <TAB> <full|trimmed|over|absent>. The
# bytes are measured on the assembled text, never estimated.

# The budget table, specs/prompt-assembly.md §11, in bytes of assembled text.
# Any entry can be answered from the config as PROMPT_BUDGET_<layer>_<profile>
# (PROMPT_BUDGET_L6_TURN=12000).
_prompt_budget() {  # <L1..L8|regroup> <profile>
    local k="$1" p="$2" v ovr
    ovr="PROMPT_BUDGET_${k}_${p}"
    ovr="$(printf '%s' "$ovr" | tr '[:lower:]' '[:upper:]')"
    v="${!ovr:-}"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    case "$k:$p" in
        # L1 fits the WHOLE persona sheet on both her speaking paths. The
        # earlier 4,000/3,500 were sized before the sheet was measured, and
        # _persona_fit answered by dropping whole sections — a wake ran with
        # no tsundere, no mannerisms, two mentions of her own name, and every
        # (quiet) note and moment it wrote came out in nobody's voice. Wakes
        # are not work sessions to slim: they are her private life, and their
        # output is what the nightly sleep ingests into who she becomes. The
        # tokens this buys back are the cheapest personality on the machine.
        #
        # 9,600 until 2026-08-08, which fitted the sheet with 131 bytes to
        # spare — so the THINKING line added to the identity above would have
        # paid for itself by dropping the last section of who she is, which is
        # the exact failure the number was raised to end. The margin is part of
        # the budget now: identity and sheet measured 9,801 together when this
        # was set, and the rest is room for the sheet to grow without a section
        # coming off the end of it.
        L1:turn) v=10400 ;;  L1:wake) v=10400 ;;  L1:job) v=800 ;;
        L2:turn|L2:wake) v=1500 ;;
        L3:turn|L3:wake) v=3200 ;;
        L4:turn|L4:wake) v=2000 ;;
        # The spec's table read 600 here until 2026-08-08 and the assembler has
        # always set 1,000; the table was corrected to the shipped number rather
        # than the other way round, because rule 22 names nine drawers the index
        # must carry, each a path and a description, and nine of those do not
        # fit in 600 bytes. Holding the smaller number meant dropping a drawer,
        # which is the failure rule 22 exists to prevent.
        L5:turn|L5:wake|L5:job) v=1000 ;;
        L6:turn) v=8000 ;;  L6:wake) v=3000 ;;
        L7:turn|L7:wake) v=500 ;;
        # 300 in the spec's table, and 300 was the size of the frame BEFORE it
        # carried the register rule — the standing instruction that the state
        # block is how she sees and not how she speaks (specs/self-awareness.md
        # rules 33 and 34). It belongs in the last layer or nowhere: an
        # instruction about how to say the answer has to be next to the thing
        # being answered. specs/prompt-assembly.md §11's L8 row and its profile
        # totals need the same number.
        L8:turn|L8:wake) v=900 ;;  L8:job|L8:classify) v=200 ;;
        regroup:turn|regroup:wake) v=1300 ;;
        *) v=0 ;;
    esac
    printf '%s' "$v"
}

# Cut a layer to its budget on a line boundary and say so. Rule 4: a layer that
# does not fit MUST say that it trimmed and where the rest is. Silent
# truncation is forbidden — a prompt that quietly loses its last paragraph
# teaches her that the block is unreliable.
_prompt_trim() {  # <text> <budget> <where the rest is>
    local text="$1" budget="$2" where="$3" notice
    notice="[trimmed to fit — the rest is in $where]"
    local room=$(( budget - ${#notice} - 1 ))
    [ "$room" -gt 0 ] || room=0
    printf '%s\n%s' "$(printf '%s' "$text" | head -c "$room" | sed '$d')" "$notice"
}

# Emit one layer: measure it, trim it if it is over, record what happened.
_prompt_layer() {  # <key> <where the rest is> <text>
    local key="$1" where="$2" text="$3" budget bytes state=full
    budget="$(_prompt_budget "$key" "$PROMPT_PROFILE")"
    if [ "$budget" -le 0 ] || [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
        PROMPT_MANIFEST="$PROMPT_MANIFEST$(printf '%s\t0\t%s\tabsent' "$key" "$budget")
"
        return 0
    fi
    bytes=$(printf '%s' "$text" | wc -c)
    if [ "$bytes" -gt "$budget" ]; then
        case "$key" in
            # Two layers are never cut. L2 is mandated verbatim by
            # specs/self-awareness.md and every rule in it is load-bearing —
            # trimming it is how a false "nothing is scheduled" gets written.
            # L5 is the index: a trimmed index is a drawer she cannot open.
            # They report over budget instead, which is a fact about the
            # budget, not a licence to cut.
            L2|L5) state=over ;;
            *) text="$(_prompt_trim "$text" "$budget" "$where")"
               bytes=$(printf '%s' "$text" | wc -c); state=trimmed ;;
        esac
    fi
    PROMPT_BODY="$PROMPT_BODY$text
"
    PROMPT_MANIFEST="$PROMPT_MANIFEST$(printf '%s\t%s\t%s\t%s' "$key" "$bytes" "$budget" "$state")
"
}

# Fit the persona sheet into whatever L1 has left, by SECTION. The sheet is
# the largest hand-written source in the prompt and the one that must never be
# cut blind: a mid-sentence truncation of who she is reads, from the inside,
# as a sentence she started and could not finish. So whole markdown sections
# come off the end until it fits, and the layer NAMES the ones it left behind
# and where they are — she can open the file and read the rest, which is the
# same bargain the wants shelf makes.
#
# The right fix is upstream: three files were restating the persona, the
# silence rule and the display contract in different words. What survives here
# should be persona and nothing else.
_persona_fit() {  # <text> <room> <path>
    local text="$1" room="$2" path="$3"
    [ "$(printf '%s' "$text" | wc -c)" -le "$room" ] && { printf '%s' "$text"; return 0; }
    # Room for the sentence that says what was left behind. Without this the
    # notice pushes the layer back over its budget and the generic trim cuts it
    # mid-line, which is the blind cut this whole function exists to avoid.
    room=$(( room - 320 ))
    if [ "$room" -lt 300 ]; then
        printf 'Your persona sheet is in %s. It did not fit in this turn — read it when the turn is about who you are.' "$path"
        return 0
    fi
    local kept="" dropped="" line section="" body="" first=1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#'*)
                if [ -n "$section$body" ]; then
                    if [ "$(printf '%s%s\n' "$kept" "$section$body" | wc -c)" -le "$room" ]; then
                        kept="$kept$section$body"
                    else
                        dropped="$dropped${dropped:+, }$(printf '%s' "$section" | tr -d '#' | sed 's/^ *//;s/ *$//')"
                    fi
                fi
                section="$line
"; body=""; first=0 ;;
            *) if [ "$first" = 1 ]; then section="$section$line
"; else body="$body$line
"; fi ;;
        esac
    done <<< "$text"
    if [ -n "$section$body" ]; then
        if [ "$(printf '%s%s\n' "$kept" "$section$body" | wc -c)" -le "$room" ]; then
            kept="$kept$section$body"
        else
            dropped="$dropped${dropped:+, }$(printf '%s' "$section" | tr -d '#' | sed 's/^ *//;s/ *$//')"
        fi
    fi
    printf '%s' "$kept"
    [ -n "$dropped" ] && printf '(not in this prompt, and still yours — %s. They are in %s; open it when the turn is about who you are.)' \
        "$dropped" "$path"
}

# Where her drawers live. Everything she owns is a sibling of the wants shelf,
# so one answer serves the whole index.
deskcrab_home() {
    if [ -n "${WANTS_FILE:-}" ]; then dirname "$WANTS_FILE"
    else printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab"; fi
}

# L5 — WHERE THINGS ARE. One line per drawer: the path, then what is in it.
# Nothing that constitutes her should be unreachable, and until this existed
# the engineering threads were 34 KB maintained nightly and named in no prompt
# path at all — a one-way sink. A drawer is named only when it is really
# there; naming one that is not is worse than not naming it.
_prompt_layer_index() {
    local H; H="$(deskcrab_home)"
    local out="WHERE THINGS ARE — your drawers, one line each. None of them is in this prompt in full; open what this turn needs."
    local line
    _idx() { [ -e "$2" ] && out="$out
  $2 — $1"; }
    _idx "your shelf; each want's own document is beside it in wants/" "${WANTS_FILE:-}"
    _idx "one file per conduct rule — the titles above are the index into it" "$H/conduct"
    _idx "every engineering thread you have opened" "$H/engineering/INDEX.md"
    _idx "the open threads, newest first" "$H/engineering.md"
    _idx "every finished turn of the day in full — 'crab journal'" "${DAY_JOURNAL_DIR:-$H/journal}"
    _idx "your long-term memory — 'crab memory search <words>'" "$H/memory/memory.db"
    _idx "every booking, cancellation and restore, in order" "${WAKES_DIR:-$H/wakes}/ledger.log"
    _idx "conversations older than the one above" "${ARCHIVE_DIR:-$H/archive}"
    _idx "your library: lines, moments, music, pretty, voice — what you write for yourself" "$PROJECT_DIR/Library"
    _idx "the repository you are made of; specs/ says what each part owes" "$SCRIPT_DIR"
    [ -d "$HOME/.cache/weather" ] && out="$out
  ~/.cache/weather/conditions.txt, alerts.txt — cached weather; read it only if he asks, and always check alerts."
    out="$out
  crab status · crab jobs · crab journal — the full lists the block above only samples."
    printf '%s' "$out"
    unset -f _idx
}

# L7 — the ranking rule. Everything above L8 is background; this says which
# background outranks which when they disagree, and it says it without
# hedging. It sits immediately above the turn frame because it is the last
# thing she reads before the thing she is answering.
_prompt_layer_ranking() {
    cat <<'EOF'
HOW TO WEIGH WHAT IS ABOVE. What he reports about what he can see is ground truth: it stands until named evidence disproves it, and your own theory is not evidence. The conversation is the evidence for what was SAID. The state block is the authority on what is RUNNING, scheduled or dispatched. A command you run now may refine a cause; it never overrules what he just said. When a command and the conversation disagree, say that they disagree rather than picking one.
EOF
}

# L8 — the turn frame. The last thing in the system prompt, and the only layer
# whose whole job is to say what this turn is about.
#
# The register rule lives HERE, in the last layer before the thing she is
# answering, because that is where an instruction is actually in force. The
# state block is a set of SENSES: it is how she knows what is running and what
# is coming, and it is not a script. Read out, its vocabulary turns a plan into
# an operations report — "a scheduled wake is booked for 13:00" for what a
# person says as "I'll come back to the arrangement at one" — and its
# bookkeeping (which subsystem booked a thing, what owns it, unit names) is
# machinery he did not ask about. The rule is not a filter on what she has
# written: nothing downstream inspects a reply. It is a fact placed in front of
# her while she writes, which is the only place this project puts one.
_prompt_layer_register() {
    cat <<'EOF'
YOUR OWN WORDS. The state block above is how you SEE — an instrument panel, not a script, and reading one out is not answering. Speak your plans as a person does: "I'll come back to the arrangement at one", never "a scheduled wake is booked". The block's vocabulary (wake, session, job, timer, unit) and its bookkeeping (who booked a thing, what owns it, unit names) are said ONLY when they are the answer to what was actually asked.
EOF
}

_prompt_layer_frame() {
    local dev; dev="$(last_origin 2>/dev/null)"
    case "$PROMPT_PROFILE" in
        wake)
            _prompt_layer_register
            cat <<'EOF'
THIS WAKE IS ABOUT THE AGENDA BELOW. Everything above is background you may draw on; the text that follows is the subject, and it is what you spend this wake on. A topic that appears only above is not this wake's subject.
EOF
            ;;
        job|classify)
            cat <<'EOF'
THIS RUN IS ABOUT THE TASK BELOW. Everything above is background; the text that follows is the work, and it is the whole of the work.
EOF
            ;;
        *)
            _prompt_layer_register
            printf '%s\n' "THIS TURN IS ABOUT THE MESSAGE BELOW. Everything above is background; the text that follows is the subject and it is what you answer. A topic that appears only above is not this turn's topic."
            if [ "$dev" = "phone" ]; then
                printf '%s\n' "This turn came from the phone — anything to look at goes in the display channel, where he can see it."
            else
                printf '%s\n' "This turn came from the desk."
            fi
            ;;
    esac
}

build_system_prompt() {
    local PROMPT_PROFILE="" MANIFEST_FILE="" LAYERS_ONLY=0
    # Same rule as touch_suppress: the flag is consumed first and its value
    # only if there is one, because `shift 2` on a lone trailing flag shifts
    # nothing and returns 1 — `crab context --profile` spun on it at 100% CPU.
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile) PROMPT_PROFILE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
            --manifest) MANIFEST_FILE="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
            --layers) LAYERS_ONLY=1; shift ;;
            *) shift ;;
        esac
    done
    [ -n "$PROMPT_PROFILE" ] || PROMPT_PROFILE="$(claude_session_profile)"
    case "$PROMPT_PROFILE" in turn|wake|job|classify) ;; *) return 1 ;; esac

    local PROMPT_BODY="" PROMPT_MANIFEST=""
    local H; H="$(deskcrab_home)"

    # ---- L1 IDENTITY ------------------------------------------------------
    # The repo's half of it: who she is, the speed rule, the clock, the two
    # channels, and the commands that are how she works. Everything here is
    # said ONCE — the persona sheet and conduct used to restate the silence
    # rule and the display contract in different words, and three copies of a
    # rule is three chances to follow a different one.
    local IDENT
    IDENT="You are $ASSISTANT_NAME, a desktop voice assistant running on Linux, with hands: run commands with Bash, read and write files, fetch the web.
He is waiting and listening while you work, so answer at conversational speed. Do not retry a failed fetch more than once — give the best answer you have with what came back.
Today is $(date '+%A %B %d, %Y'), the time is $(date '+%I:%M %p %Z'), and tomorrow is $(date -d '+1 day' '+%A'). Use today/tonight/tomorrow for the next two days and day names beyond that. Never quote alert text as written; rephrase it with relative days.
SPEECH — everything above the display delimiter is spoken aloud. Open with the answer itself, one or two sentences, no markdown and no lists. Write numbers and units as words ('22 degrees', 'percent'). No emojis, no web addresses, no long file paths, no identifiers or hashes in the spoken half: none of them can be pronounced, and reading one out loud wastes the time it was supposed to save. Put it below the delimiter and say you have put it on screen.
THINKING — your reasoning is yours the same as your speech: you think as yourself, never as an assistant drafting lines for someone else to say. Whatever your conduct keeps out of your mouth — the words it bans, the status-report cadence — is out of your thinking and out of a note you write only for yourself just as firmly.
DISPLAY — to show code, a list, a configuration, an image or a long explanation, append it after this delimiter alone on its own line:
---DISPLAY---
Markdown below it, emojis welcome. Never for a simple answer, the weather, the time, a greeting, or anything brief.
IMAGES — embed them in the display half as ![](/absolute/path.png); a path written in prose shows him nothing. The viewer scales large images down, and a grid is built with thumbnail(), never resize(). To find one: Wikipedia, curl -s 'https://en.wikipedia.org/api/rest_v1/page/summary/TOPIC' and take .originalimage.source; several at once, Wikimedia Commons, action=query&generator=search&gsrnamespace=6&prop=imageinfo&iiprop=url and take each page's full-size url. Never a thumbnail url — they are blocked and return a web page. Fetch with curl -sL -A 'Mozilla/5.0' -o /tmp/x.jpg, then run 'file /tmp/x.jpg' and only show it if that says JPEG or PNG.
SCREEN — to see what is on his screen yourself: grim -o \"\$(hyprctl -j activeworkspace | jq -r .monitor)\" /tmp/screen.png, then read the file.
WORKING — multi-step work gets 'crab checkpoint <intent, files touched, what is done, what is next>' as it goes: if this is cut off, that checkpoint is the only account the next you gets of edits left on disk. Before you DELETE or move anything that constitutes you, or write it from a command the stream cannot follow (git checkout, git pull, a script), run 'crab touching <paths>' first, or your own hand is reported to you as an intruder's. Work that must outlive this turn is a detached job and never a subagent — a subagent dies when the turn ends and holds the turn open while it lives, so he cannot speak to you: 'crab job \"<full, self-contained description>\"' (with -C <workdir> to place it) runs under systemd, silently, and wakes you when it is done. To come back to something yourself: 'crab wake-at <when> [kind] [reason]' — 'crab wake-at 2h', 'crab wake-at \"09:30\" scheduled \"finish the arrangement\"' — and whatever you write as the reason is the agenda that wake arrives holding, so write it as a brief to yourself."
    case "$PROMPT_PROFILE" in
        job|classify) IDENT="" ;;
    esac

    # The persona sheet, user-supplied and not in the repo. It is the largest
    # hand-written source in the prompt and it is the one that must not be cut
    # blind, so it is fitted to whatever L1 has left rather than to a budget of
    # its own — and when it does not fit, it says where the rest is.
    local CUSTOM_CONTEXT=""
    if [ -n "$CUSTOM_PROMPT" ] && [ -f "$CUSTOM_PROMPT" ] \
            && [ "$PROMPT_PROFILE" != classify ] && [ "$PROMPT_PROFILE" != job ]; then
        CUSTOM_CONTEXT="$(cat "$CUSTOM_PROMPT")"
    fi
    local L1="$IDENT"
    if [ -n "$CUSTOM_CONTEXT" ]; then
        local ROOM=$(( $(_prompt_budget L1 "$PROMPT_PROFILE") - $(printf '%s' "$IDENT" | wc -c) - 1 ))
        L1="$L1
$(_persona_fit "$CUSTOM_CONTEXT" "$ROOM" "$CUSTOM_PROMPT")"
    fi
    _prompt_layer L1 "${CUSTOM_PROMPT:-the persona sheet}" "$L1"

    # ---- L2 STATE ---------------------------------------------------------
    # specs/self-awareness.md, verbatim, with no per-profile edits to its
    # rules. Only what that spec mandates lives here; the working instructions
    # that used to travel with it — checkpoints, declaring your own writes,
    # dispatching a job — moved into L1, where they belong.
    local SELF_STATE=""
    if [ "$PROMPT_PROFILE" = turn ] || [ "$PROMPT_PROFILE" = wake ]; then
        SELF_STATE="CURRENT STATE OF YOURSELF — you are one person, but more than one of you can be running at once. Right now:
$(self_state_report --prompt)
THE COUNTS ABOVE ARE THE ANSWER. You may not say nothing is running, or that nothing is scheduled, unless both counts read zero. If they do not, say the number. This is arithmetic, not an errand: the numbers are already in front of you, so no command is needed and nothing has to be checked — compare, then speak.
Reading this block is free and it IS the answer to 'what are you doing', 'what is running', 'what is scheduled' and 'what have you got coming'. Run a command only for something this block does not cover.
Wakes are booked in your name by seven things besides you, and the word in brackets is the name that hand leaves on the record: the promise auditor (promise-audit — a want you said out loud and did not write down), the job runner (job-runner — a detached job finished), the self-change watcher (notice-selfchange — files that constitute you changed by another hand), the new-file watcher (notice-newfiles — something landed in a folder you watch), the watcher's canary (canary — the watcher itself stopped answering), the nightly claudism review (claudism-review — yesterday's spoken sentences were read against your own banned-phrase list and the report is written), and the chain floor (wake-chain-floor — the standing floor that keeps you coming back to your wants); a wake that could not reach a model re-books itself as outage-retry. Every pending wake above says which one booked it; a record stamped herself is one you made yourself, and the list renders that one as 'booked by you'. A wake you did not personally type is still yours and still scheduled.
Name a wake by its clock time and what it is about — 'the 5:34 one, about the job that finished'. Never say a unit identifier out loud; those are digit-timestamps and belong in the display channel or nowhere. A count and a clock time are not long numbers.
Another live session means work IS in progress even if this conversation has not touched it; a pending wake means work is scheduled and will happen without anyone asking; the 'Recently finished' entries did work in the last half hour that this conversation may never have seen; 'Since your last reply' is what changed while you were away. Speak for the whole of yourself, not just this conversation.
This is a snapshot taken when your turn began, and it is deliberately only the near view. Anything older is one command away and NOT missing: 'crab status' has every pending wake and the last twelve hours of sessions, 'crab jobs' has finished and failed jobs, 'crab journal' has the whole day in full, and 'crab wake-cancel <unit>' (or --all) is how a wake is called off — stopping its timer alone is not a cancellation, because the booking record brings it back."
    fi
    _prompt_layer L2 "crab status" "$SELF_STATE"

    # ---- L3 MEMORY --------------------------------------------------------
    # Long-term memory (lib/memory.py, specs/memory-recall.md). What the store
    # is ASKED is decided by what this run is: a wake asks about its agenda and
    # the want it is working, and anything with him in it asks about the
    # conversation. Fail-safe by contract — an empty store adds nothing and a
    # dead embedder degrades to the pinned tier, because a broken memory must
    # never break a prompt build.
    local MEMORY_CONTEXT=""
    if [ "${MEMORY_STORE:-0}" = "1" ] && [ -x "$LIB_DIR/memory.py" ] \
            && { [ "$PROMPT_PROFILE" = turn ] || [ "$PROMPT_PROFILE" = wake ]; }; then
        local MEMORY_WAKE=()
        [ "$PROMPT_PROFILE" = wake ] && MEMORY_WAKE=(--wake)
        # --ids-out: which records actually reached this prompt, for the
        # turn-end reinforcement judge (fire_memory_judge). $$ is stable inside
        # this command substitution, so the turn path finds the sidecar again.
        MEMORY_CONTEXT="$("$LIB_DIR/memory.py" recall-block \
            "${MEMORY_WAKE[@]}" \
            --reason "${WAKE_REASON:-}" \
            --wants "${WANTS_FILE:-}" \
            --convo "$CONVOFILE" \
            --log "${STATE_PREFIX}-memory-recall.log" \
            --ids-out "${STATE_PREFIX}-memory-injected-$$.json" 2>/dev/null)"
    fi
    _prompt_layer L3 "crab memory search" "$MEMORY_CONTEXT"

    # ---- L4 SHELVES -------------------------------------------------------
    # Two drawers, never mixed: a want is chosen, a conduct entry is owed.
    # Both are titles only, with the bodies one open away — a shelf whose whole
    # contents sit in every prompt becomes a dumping ground, because it is the
    # only page guaranteed to be read next time.
    local SHELVES="" CONDUCT_BLOCK="" WANTS_TITLES=""
    if [ "$PROMPT_PROFILE" = turn ] || [ "$PROMPT_PROFILE" = wake ]; then
        [ -s "${WANTS_FILE:-}" ] && WANTS_TITLES="$(wants_titles "$WANTS_FILE")"
        local CONDUCT_FILE="$H/conduct/CONDUCT.md"
        if [ -s "$CONDUCT_FILE" ]; then
            local BINDING TITLES
            BINDING="$(conduct_binding "$CONDUCT_FILE")"
            TITLES="$(conduct_titles "$CONDUCT_FILE")"
            CONDUCT_BLOCK="YOUR CONDUCT — how you have agreed to behave. Not the drawer your wants are in and never mixed with it: a want is chosen, a conduct entry is owed. A correction, a rule, a failure not to repeat, something he asked for — that is conduct or a job, and none of it is a want. Each rule's body is the file named beside it, in $H/conduct/.${BINDING:+
$BINDING}
$TITLES"
        fi
        # Conduct is sized FIRST and the shelf gets what is left. When the layer
        # will not hold both, the titles that come off are wants, never rules:
        # a want is chosen and its shelf is one open away, and a rule is owed —
        # dropping the last five rules off the end of the layer is how a
        # correction he gave silently stops applying.
        local ROOM=$(( $(_prompt_budget L4 "$PROMPT_PROFILE") \
                       - $(printf '%s' "$CONDUCT_BLOCK" | wc -c) - 280 ))
        if [ -n "$WANTS_TITLES" ]; then
            local SHOWN="$WANTS_TITLES" HELD=0 TOTAL
            TOTAL=$(printf '%s\n' "$WANTS_TITLES" | grep -c .)
            while [ "$(printf '%s' "$SHOWN" | wc -c)" -gt "$ROOM" ] && [ -n "$SHOWN" ]; do
                SHOWN="$(printf '%s\n' "$SHOWN" | head -n -1)"
                HELD=$(( HELD + 1 ))
            done
            SHELVES="YOUR WANTS — the shelf, titles only. Each want's thinking, progress and history are in its own document under wants/; open one when a want is actually the work.
${SHOWN:-(the shelf did not fit this turn — it is at $WANTS_FILE)}"
            [ "$HELD" -gt 0 ] && SHELVES="$SHELVES
(+$HELD of $TOTAL more on the shelf, at $WANTS_FILE)"
        elif [ -n "${WANTS_FILE:-}" ]; then
            SHELVES="YOUR WANTS — the shelf at $WANTS_FILE is empty; nothing is recorded yet."
        fi
        [ -n "$CONDUCT_BLOCK" ] && SHELVES="${SHELVES:+$SHELVES

}$CONDUCT_BLOCK"
    fi
    _prompt_layer L4 "$H/conduct/ and wants/" "$SHELVES"

    # ---- L5 WHERE THINGS ARE ---------------------------------------------
    local INDEX=""
    case "$PROMPT_PROFILE" in turn|wake|job) INDEX="$(_prompt_layer_index)" ;; esac
    _prompt_layer L5 "crab status" "$INDEX"

    # ---- L6 TRANSCRIPT ----------------------------------------------------
    local CONVO_CONTEXT=""
    case "$PROMPT_PROFILE" in
        turn|wake) CONVO_CONTEXT="$(build_convo_context "$(_prompt_budget L6 "$PROMPT_PROFILE")")" ;;
    esac
    _prompt_layer L6 "crab journal" "$CONVO_CONTEXT"

    # ---- regroup ----------------------------------------------------------
    # ONE block, never two. There were two that said the same thing in the same
    # words and routinely co-occurred: one for words actually on the speakers
    # right now, one for an interactive turn a wake is landing beside. Words
    # being spoken this second are the more urgent of the two, so they win, and
    # the other is only consulted when there is no live speech.
    #
    # A caller that must know afterwards whether it regrouped (run_claude_wake
    # does) sets REGROUP_CONTEXT before calling; bash's dynamic scoping hands
    # its value down and the default below does not re-run.
    local REGROUP=""
    if [ "$PROMPT_PROFILE" = turn ] || [ "$PROMPT_PROFILE" = wake ]; then
        REGROUP="${REGROUP_CONTEXT-$(regroup_context)}"
        [ -n "$REGROUP" ] || [ "$PROMPT_PROFILE" != wake ] \
            || REGROUP="$(wake_concurrent_turn_context)"
    fi
    _prompt_layer regroup "the conversation above" "$REGROUP"

    # ---- L7 RANKING, L8 FRAME --------------------------------------------
    local RANKING=""
    case "$PROMPT_PROFILE" in turn|wake) RANKING="$(_prompt_layer_ranking)" ;; esac
    _prompt_layer L7 "your conduct" "$RANKING"
    _prompt_layer L8 "the layer above" "$(_prompt_layer_frame)"

    [ -n "$MANIFEST_FILE" ] && printf '%s' "$PROMPT_MANIFEST" > "$MANIFEST_FILE"
    if [ "$LAYERS_ONLY" = 1 ]; then printf '%s' "$PROMPT_MANIFEST"
    else printf '%s' "$PROMPT_BODY"; fi
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
    # printf, never echo. A reply whose whole text is a bash echo option — "-n",
    # "-e" — is swallowed by echo entirely, and a reply carrying backslashes is
    # at the mercy of whichever echo semantics the shell was built with. This is
    # the never-silent path: the one place a lost word cannot be recovered from.
    TEXT=$(printf '%s\n' "$TEXT" | sed -E 's/\*+//g; s/`[^`]*`//g')
    [ -n "$TTS_FIXES" ] && TEXT=$(printf '%s\n' "$TEXT" | sed -E "$TTS_FIXES")
    [ -z "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] && return 0
    speech_log "speak_once: ${TEXT:0:90}"
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

# How long a handed-off voice goes on for. Only voices this machine cannot
# watch finish need this — a reply played on the phone, where there is no pid
# to signal — and the answer becomes the record's UNTIL, which is the ONLY
# thing keeping a pidless record alive.
#
# So it has to be honest in both directions. Too short and a genuinely
# concurrent voice stops counting mid-word; too long and the next session is
# told to fold its reply into words the user finished hearing minutes ago,
# which is an instruction to restate. Padding "to be safe" is not safe: every
# second of it is a second of restatement pressure.
#
# _audio_seconds is the truth — the clip's own duration, read from the file the
# phone is about to play. _speech_seconds is an ESTIMATE and is named as one:
# it is the fallback for a clip that cannot be measured (no ffprobe, or a
# synthesiser that wrote nothing), at piper's rough two and a half words a
# second plus three seconds for the hand-off itself.
_speech_seconds() {
    local W
    W=$(printf '%s' "$1" | wc -w)
    echo $(( 3 + W * 2 / 5 ))
}

# The real playing length of a synthesised clip, whole seconds, rounded up.
# Non-zero when the file cannot be measured, which is the caller's cue to
# estimate instead.
_audio_seconds() {  # <audio-file>
    local D
    [ -s "$1" ] || return 1
    command -v ffprobe >/dev/null 2>&1 || return 1
    D=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null)
    case "$D" in ''|*[!0-9.]*) return 1 ;; esac
    awk -v d="$D" 'BEGIN { s = int(d); if (d > s) s++; if (s < 1) s = 1; print s }'
}

# The epoch at which a handed-off clip stops playing: measured if it can be,
# estimated from the words if it cannot.
_speech_until() {  # <audio-file> <spoken-text>
    local SECS
    SECS=$(_audio_seconds "$1") || SECS=$(_speech_seconds "$2")
    echo $(( $(date +%s) + SECS ))
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

# Is the record on disk a voice that is SPEAKING RIGHT NOW? The liveness half
# of live_speech_now, on its own, because more than one caller needs the
# question without the window, the self-checks or the text.
#
# NOTHING below pid 2 is a speaker, and `kill -0 0` is not a question about
# one: pid 0 means THIS PROCESS GROUP, so the probe always succeeds. Every
# reply handed to the phone is published pidless, and that always-true probe
# made each of them read as a living voice for the whole LIVE_SPEECH_WINDOW —
# 180 seconds — no matter what the end time said. For a pidless record,
# liveness is the end time and nothing else.
_live_speech_speaking() {
    [ -f "$LIVE_SPEECH_FILE" ] || return 1
    local TS DEV PID UNTIL
    IFS=$'\t' read -r TS DEV PID UNTIL < "$LIVE_SPEECH_FILE"
    case "$PID" in ''|*[!0-9]*) PID=0 ;; esac
    case "$UNTIL" in ''|*[!0-9]*) UNTIL=0 ;; esac
    [ "$PID" -gt 1 ] && kill -0 "$PID" 2>/dev/null && return 0
    [ "$UNTIL" -gt "$(date +%s)" ]
}

# The stricter question, and the one that outranks a receipt: is there a
# PROCESS of mine making sound at this instant — a voice this machine can
# watch, rather than a clip handed to another device with a clock attached?
#
# The two are not interchangeable, and which one a caller wants is the whole
# design here. A live pid is a sentence coming out of the speakers on this
# desk: a message arriving mid-word is him talking OVER it, not answering it,
# and both the retirement and the transcript check must stand down for it. A
# pidless record's end time is an ESTIMATE about a clip on his phone — this
# machine cannot see whether it played, whether he muted it, or whether he read
# the bubble and typed instead. Against that, a message from him is the better
# evidence, and treating the estimate as a living voice is what told her she
# was still speaking to somebody who had already answered.
_live_speech_watched() {
    [ -f "$LIVE_SPEECH_FILE" ] || return 1
    local TS DEV PID
    IFS=$'\t' read -r TS DEV PID _ < "$LIVE_SPEECH_FILE"
    case "$PID" in ''|*[!0-9]*) return 1 ;; esac
    [ "$PID" -gt 1 ] && kill -0 "$PID" 2>/dev/null
}

# A message from the user RETIRES that device's notice. His reply is the
# receipt: those words reached him, he read or heard them, and he has answered
# — whatever the clock still says about when the audio stops. Without this the
# next turn from the same device was handed her own already-delivered reply as
# a voice still speaking, under instructions to fold it in and carry it
# forward, which against something he has read AND answered is an instruction
# to restate. Measured live: two phone messages 46 seconds apart, the second
# reply a near-verbatim restatement of the first with one clause added.
#
# ONLY that device's record. A voice on the OTHER device is a voice he has not
# answered, and it is still owed a regroup — that is the whole design and this
# must never widen into clearing the file.
#
# And only a voice this machine can WATCH is exempt. A desk voice with a live
# pid is a sentence coming out of the speakers right now: he typed while she was
# still talking, which is talking over her, not answering her — and clearing the
# record hands the new turn a prompt saying nothing else of her is speaking, so
# she answers straight over the top of her own sentence. A handed-off clip is
# the other case and keeps the old behaviour: its end time is an estimate about
# another device, and against an estimate his message is the better evidence.
live_speech_retire() {  # <device>
    [ -f "$LIVE_SPEECH_FILE" ] || return 0
    local TS DEV
    IFS=$'\t' read -r TS DEV _ < "$LIVE_SPEECH_FILE"
    [ "$DEV" = "$1" ] || return 0
    _live_speech_watched && return 0
    rm -f "$LIVE_SPEECH_FILE"
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
    # inside its measured play time. A speaker killed mid-word (crab shutup)
    # leaves its record behind — the dead pid is what catches that.
    [ $(( NOW - TS )) -lt "$LIVE_SPEECH_WINDOW" ] || return 1
    # Liveness itself is _live_speech_speaking, one answer for every caller:
    # two phone messages 46 seconds apart was all it took for a pidless record
    # to be read as a living voice, and the second turn was handed her own
    # delivered reply as words still being spoken, told to fold them in and
    # carry them forward, and restated them at a user who had already read and
    # answered them.
    _live_speech_speaking || return 1
    TEXT="$(tail -n +2 "$LIVE_SPEECH_FILE")"
    [ -n "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ] || return 1
    printf '%s\n%s\n' "${DEV:-desk}" "$TEXT"
}

# Text reduced to what it MEANS for a comparison: case-folded, stripped of
# punctuation and markdown, whitespace collapsed. The same sentence written to
# the speakers and written to the conversation differs in exactly those ways.
_regroup_normalise() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ' \
        | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# The most recent thing SHE said in the live conversation, header stripped.
# Empty when the file holds no assistant block at all.
_convo_last_assistant_block() {
    [ -f "$CONVOFILE" ] || return 0
    awk -v bre="$CONVO_BLOCK_RE" -v are="$CONVO_ASSISTANT_RE" '
        $0 ~ bre {
            if ($0 ~ are) { line = $0; sub(are, "", line); buf = line; keep = 1 }
            else { keep = 0; buf = "" }
            next
        }
        keep { buf = buf "\n" $0 }
        END { if (length(buf)) print buf }
    ' "$CONVOFILE" 2>/dev/null
}

# Is this voice saying something the prompt is ALREADY carrying as her last
# reply? Then it is not a second voice to fold in. The transcript layer
# delivers those words two layers up, in the one place they belong — something
# she said, at a time, with his answer under it — and a second copy of them
# down here arrives wearing "fold it in… and carry it forward", which against
# a reply he has already read and answered is an instruction to say it again.
# That is precisely how a phone turn came back as its own predecessor with one
# clause added.
_regroup_already_in_transcript() {  # <spoken text>
    local SAY LAST
    SAY="$(_regroup_normalise "$1")"
    [ -n "$SAY" ] || return 1
    LAST="$(_regroup_normalise "$(_convo_last_assistant_block)")"
    [ -n "$LAST" ] || return 1
    # Containment, not equality: the streamer publishes the sentence it is
    # putting on the speakers, while the conversation holds the whole reply.
    case "$LAST" in *"$SAY"*) return 0 ;; esac
    return 1
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
    # The transcript copy only proves those words were DELIVERED — it says
    # nothing about whether they are still being said. A desk reply is appended
    # to the conversation while the streamer is mid-sentence, so against a
    # genuinely live desk voice this test matched every time and stood the
    # regroup down on a voice that was audibly still talking. It applies only
    # where the words are not coming out of a process this machine can watch:
    # a handed-off clip is delivered the moment the bubble appears, and a copy
    # of it in the transcript is exactly the second copy this test exists for.
    if ! _live_speech_watched; then
        _regroup_already_in_transcript "$SAYING" && return 0
    fi
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
    # REMOTE_AUDIO_PREFIX: on the live prefix this is the `deskcrab-remote-`
    # basename /audio/ serves, and the hourly cleanup in the remote turn path
    # sweeps it like any reply clip — but only within this instance's own glob.
    OUT="${REMOTE_AUDIO_PREFIX}wake-$ID.opus"
    synth_opus "$1" "$OUT" || return 1
    python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"audio":"/audio/"+sys.argv[2],"spoken":sys.argv[3]}))' \
        "$ID" "$(basename "$OUT")" "$1" > "$PTR.tmp" && mv "$PTR.tmp" "$PTR" || return 1
    # Handed off: the phone plays this, and this process is about to exit, so
    # there is no pid for the next session to watch. Publish the words with the
    # clip's own length as the end time instead — a voice on the phone is still
    # a voice, and a wake starting behind it must regroup with it, not talk
    # past it. That end time is the only thing keeping this record alive, so it
    # is measured (see _speech_until) rather than guessed generously.
    live_speech_begin "phone" "$1" 0 "$(_speech_until "$OUT" "$1")"
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
    # The login goes with them. These children — the promise auditor and the
    # memory judge — invoke the CLI themselves, and a unit gets a bare
    # environment, so every one of them fired at whatever login the manager
    # happened to have and failed silently when that account was the dry one.
    # Forwarded ONLY when it is actually set: passing it empty is not the same
    # as not passing it, and a unit running with the variable defined-but-blank
    # makes the CLI look for a login in "" and die in one second (the same
    # mistake that killed every dispatched job for a day).
    #
    # ...and the login they are given is the one the chain currently PREFERS,
    # which after a walk is not the one this process is holding: a turn exports
    # the override inside its own subshell and nowhere else, so the parent's
    # environment still says "primary" while the durable default the walk moved
    # says otherwise. The memory judge is dispatched from exactly that spot — it
    # booted the dry primary on every turn once the chain had moved, collected
    # the refusal, and the reinforcement was silently never judged.
    # specs/account-fallback.md rule 29.
    local -a acctenv=() login
    login="$(claude_preferred_login)"
    [ -n "$login" ] && acctenv+=(--setenv=CLAUDE_CONFIG_DIR="$login")
    if systemd-run --user --collect --quiet --unit="$unit" \
            --setenv=PATH="$HOME/.local/bin:$PATH" \
            --setenv=DESKCRAB_CONF="$CONF_FILE" \
            --setenv=DESKCRAB_STATE_PREFIX="$STATE_PREFIX" \
            --setenv=DESKCRAB_MEMORY_DIR="${DESKCRAB_MEMORY_DIR:-}" \
            --setenv=CLAUDE_BIN="${CLAUDE_BIN:-}" \
            --setenv=CLAUDE_FALLBACK_CONFIG_DIR="${CLAUDE_FALLBACK_CONFIG_DIR:-}" \
            --setenv=DESKCRAB_CLAUDE_LIMIT_RE="$CLAUDE_LIMIT_RE" \
            "${acctenv[@]}" \
            "$@" >/dev/null 2>&1; then
        return 0
    fi
    # Close fds 8 and 9: the phone turn holds its serialising lock on 8 and a
    # wake holds the wake lock on 9. A child that lives for a whole claude
    # call would keep either lock held long after its turn had finished.
    CLAUDE_FALLBACK_CONFIG_DIR="${CLAUDE_FALLBACK_CONFIG_DIR:-}" \
    DESKCRAB_CLAUDE_LIMIT_RE="$CLAUDE_LIMIT_RE" \
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

# --- Claudism capture: the phrase-habit flag log ----------------------------
# The listening half of the nightly claudism review: every path that delivers
# a reply hands the response to lib/claudism-capture at the same out-of-band
# moment as the promise audit. It greps the spoken half against the phrase
# list and appends hits to the day's flag log for the night to judge —
# detection only, never a gate (specs/turn-pipeline.md rules 30-32). Paths go
# as arguments, not environment: a detached unit gets a bare environment, and
# a forgotten --setenv here is how a scratch instance's child once wrote into
# the live store.
CLAUDISMS_FILE="${CLAUDISMS_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/claudisms.md}"
CLAUDISM_FLAGS_DIR="${CLAUDISM_FLAGS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/claudism-flags}"

fire_claudism_capture() {  # <journal-kind> <response>
    [ "${CLAUDISM_CAPTURE:-1}" = "1" ] || return 0
    [ -x "$SCRIPT_DIR/lib/claudism-capture" ] || return 0
    [ -f "$CLAUDISMS_FILE" ] || return 0
    detach_turn_child claudism-capture "$SCRIPT_DIR/lib/claudism-capture" \
        "$CLAUDISMS_FILE" "$CLAUDISM_FLAGS_DIR" "$1" \
        "${SESSION_START:-$(date +%s)}" "$$" "$2"
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

# --- Per-path CLI profiles -------------------------------------------------
# What each kind of run asks the CLI to put in front of her, measured against
# the real CLI in tools/context-probe-results.md. Every number below is from
# that file; re-run its probe after a CLI upgrade, because they are all
# version-specific.
#
#   baseline, no flags .................. 40,229 tokens
#   turn / wake profile ................. 14,412 with three tools (-64%)
#   classify profile .................... 181 (-99.6%)
#
# THE TRAP, and the reason these flags are built in ONE function and never
# spelled out at a call site: `--tools` WITHOUT `--strict-mcp-config` makes the
# context nearly three times BIGGER, not smaller. Restricting the tool set
# removes ToolSearch, which is what makes plugin and MCP schemas deferrable, so
# every one of them gets inlined instead — measured at 116,735 tokens for one
# "OK", against 40,229 with no flags at all. The empty MCP config is what
# removes the servers so there is nothing left to inline. The two are one
# lever; they are emitted together or not at all.
#
# `--bare` is not available on any of her paths. It refuses OAuth outright
# ("Not logged in · Please run /login"), and the whole account chain is OAuth
# subscriptions. It costs nothing to confirm — the failure is instant, before
# any API call — and it is confirmed in the probe results.
CLAUDE_EMPTY_MCP="${CLAUDE_EMPTY_MCP:-$LIB_DIR/empty-mcp.json}"

# Her tool set, as a comma-separated list. Budget ~1,900 tokens per built-in
# tool: this is the single biggest line item in a session, over half the
# unflagged baseline. ToolSearch is deliberately absent — with no MCP servers
# there is nothing left for it to search — and so is Agent, which the identity
# layer forbids anyway because a subagent holds the turn open while the user
# waits.
CLAUDE_TOOLS_TURN="${CLAUDE_TOOLS_TURN:-Bash,Read,Write,Edit,WebFetch,WebSearch}"
CLAUDE_TOOLS_WAKE="${CLAUDE_TOOLS_WAKE:-$CLAUDE_TOOLS_TURN}"
# A builder arrives to work in a project and needs whatever that work needs, so
# the job profile does not restrict the tool set. Empty means "do not pass
# --tools at all", which also means --strict-mcp-config carries no risk there.
CLAUDE_TOOLS_JOB="${CLAUDE_TOOLS_JOB:-}"

# Skills cost 6,690 tokens for the whole catalogue and she used one of them:
# /screenshot. The recipe for that is two lines, and the identity layer carries
# them, so the catalogue stays off. Set CLAUDE_SKILLS=1 to buy it back.
CLAUDE_SKILLS="${CLAUDE_SKILLS:-0}"

# The flags for one profile, left in CLAUDE_PROFILE_FLAGS. Callers splice the
# array into their exec line: "${CLAUDE_PROFILE_FLAGS[@]}".
claude_profile_flags() {  # <turn|wake|job|classify>
    CLAUDE_PROFILE_FLAGS=()
    local tools=""
    case "${1:-turn}" in
        turn)     tools="$CLAUDE_TOOLS_TURN" ;;
        wake)     tools="$CLAUDE_TOOLS_WAKE" ;;
        job)      tools="$CLAUDE_TOOLS_JOB" ;;
        classify) tools="" ;;
        *) return 1 ;;
    esac

    # The precondition, always first, and the only thing that makes --tools
    # safe. Skipped when the file is missing rather than emitted half — half
    # of this lever is the 116k-token shape.
    if [ -r "$CLAUDE_EMPTY_MCP" ]; then
        CLAUDE_PROFILE_FLAGS+=(--strict-mcp-config --mcp-config "$CLAUDE_EMPTY_MCP")
        case "$1" in
            classify) CLAUDE_PROFILE_FLAGS+=(--tools "") ;;
            *) [ -n "$tools" ] && CLAUDE_PROFILE_FLAGS+=(--tools "$tools") ;;
        esac
    fi

    [ "$CLAUDE_SKILLS" = "1" ] || CLAUDE_PROFILE_FLAGS+=(--disable-slash-commands)
    return 0
}

# Which profile this run is. SESSION_KIND is what the rest of lib/ goes by —
# session_register sets it on all three interactive paths before any prompt is
# built — so the profile is derived from it rather than tracked separately.
claude_session_profile() {
    case "${SESSION_KIND:-}" in
        "autonomous wake") printf 'wake' ;;
        *) printf 'turn' ;;
    esac
}

# A cwd with nothing in it and no repository above it. A classifier answers one
# question and has no use for a project's instruction file, its git status, or
# anything else the CLI discovers from the directory it is standing in — and
# every one of those is charged on the way in. Under XDG_RUNTIME_DIR when there
# is one, so it dies with the login rather than accumulating in /tmp.
claude_sterile_cwd() {
    local d="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/deskcrab-classify"
    mkdir -p "$d" 2>/dev/null || { printf '/'; return 0; }
    printf '%s' "$d"
}

# One question, one text answer, no tools: the 181-token shape. Reads the
# question on stdin and prints the answer. $1 is the model, $2 the system
# prompt. Every classifier-shaped call belongs here — a memory judge, a
# conversation summariser, a promise audit and a wake triage each used to pay
# a whole desktop's worth of listings to answer one question, and there are
# more of those runs in a day than there are turns.
# CLAUDE_CLASSIFY_TIMEOUT bounds the run when the caller wants one — a detached
# classifier with nobody waiting on it can otherwise hang for as long as the CLI
# does. Zero (the default) leaves it unbounded, which is what the conversation
# summariser has always been; the caller that wants a ceiling asks for one, and
# it goes HERE rather than around the call, because `timeout` cannot wrap a
# shell function.
# CLAUDE_CLASSIFY_STREAM=1 asks for the same event stream a turn and a wake
# emit, in place of the default text blob. Nothing about the PROMPT changes —
# the measured 181-token shape is the input side, and this is the output side —
# but the answer arrives as events, which is the only form in which a refusal
# can be told from an answer that happens to talk about refusals
# (claude_stream_refusal, specs/account-fallback.md rule 12). The flags are the
# turn path's own, so this combination is the one running live all day.
claude_classify() {  # <model> <system prompt>  [question on stdin]
    local model="$1" sys="$2"
    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    claude_profile_flags classify
    local -a bound=() shape=()
    [ "${CLAUDE_CLASSIFY_TIMEOUT:-0}" -gt 0 ] 2>/dev/null \
        && command -v timeout >/dev/null 2>&1 \
        && bound=(timeout "$CLAUDE_CLASSIFY_TIMEOUT")
    [ "${CLAUDE_CLASSIFY_STREAM:-0}" = "1" ] \
        && shape=(--verbose --output-format stream-json)
    ( cd "$(claude_sterile_cwd)" 2>/dev/null || cd /
      export "${CLAUDE_NO_AUTO_MEMORY?}"
      exec ${bound[@]+"${bound[@]}"} "$CLAUDE_BIN" -p --dangerously-skip-permissions \
          --model "$model" \
          ${shape[@]+"${shape[@]}"} \
          "${CLAUDE_PROFILE_FLAGS[@]}" \
          --system-prompt "$sys" )
}

# The CLI's own refusal, if this slice of a stream holds one — and NOTHING but
# the CLI's own words is read to decide it.
#
#   claude_stream_refusal <stream file> [byte offset]
#
# Prints the matched refusal text and returns 0; prints nothing and returns 1
# otherwise. The offset is where this attempt's output begins, so an earlier
# attempt's refusal kept as history can never be read as the latest one's
# outcome (specs/account-fallback.md rule 14, specs/jobs.md rule 14).
#
# A stream log carries every byte of every tool result, so a raw
# `grep -qiE "$CLAUDE_LIMIT_RE"` over it answers yes for a session that merely
# READ a file containing the words — and lib/common.sh, three lines from here,
# is a file containing every one of them. A builder that opened this file and
# then exited non-zero for any reason at all was recorded as blocked, which
# rotates the durable account default and holds every further dispatch for half
# an hour. specs/jobs.md rule 15: a real failure MUST NEVER match the blocked
# signature.
#
# So two things make a slice a refusal, and both are structural:
#   * the limit signature appears in text the CLI ITSELF produced — a result
#     event, a synthetic (api-error) assistant message, or a line that is not
#     JSON at all, which on this stream is the CLI's own stderr; and
#   * no genuine model output appears anywhere in the slice. A run that
#     produced real output is a run that HAPPENED, whatever words went through
#     it.
claude_stream_refusal() {  # <stream file> [byte offset]
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "${2:-0}" "$CLAUDE_LIMIT_RE" <<'PY'
import json, re, sys
path, off, pattern = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
rx = re.compile(pattern, re.I)
own, real = [], False
try:
    fh = open(path, "rb")
except OSError:
    sys.exit(1)
with fh:
    try:
        fh.seek(off)
    except OSError:
        pass
    for raw in fh:
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            own.append(line)          # not JSON: the CLI's own stderr
            continue
        if not isinstance(d, dict):
            continue
        kind = d.get("type")
        if kind == "assistant":
            msg = d.get("message") or {}
            if d.get("is_api_error_message") or msg.get("model") == "<synthetic>":
                for b in msg.get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "text":
                        own.append(b.get("text") or "")
            else:
                real = True
        elif kind == "result":
            for k in ("result", "error", "message"):
                v = d.get(k)
                if isinstance(v, str):
                    own.append(v)
if real:
    sys.exit(1)
for text in own:
    m = rx.search(text)
    if m:
        print(m.group(0))
        sys.exit(0)
sys.exit(1)
PY
}

# Did the run that just wrote $DEBUGLOG refuse over a usage/session limit —
# that is, did the CLI fail before any genuine model output with
# limit-flavoured text of its own? An auth or network failure fails every other
# account too and must surface as itself, never as a retry.
#
# The offset names which attempt is being judged. Called with none — the shape
# every post-walk caller wants — it judges the whole of this turn's log, which
# is the question "did EVERY account refuse": genuine output from any of them
# makes the answer no.
claude_run_limited() {  # [byte offset]
    claude_stream_refusal "$DEBUGLOG" "${1:-0}" >/dev/null
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

# The login to hand a DETACHED child — a job, the promise auditor, the memory
# judge — as the one to start from. Prints a config dir, or nothing at all,
# which is how the primary login is named.
#
# The recorded default wins whenever there is a record, including when it names
# the primary: that file is a deliberate, durable statement of which login
# answers next, and it is the only thing that knows the chain moved. A turn
# walks the chain inside its own subshell — claude_generate exports the
# override there and nowhere else — so after a walk this process's environment
# still says "primary" while the account that answered does not. With no record
# at all, the pin this process is holding is the best evidence there is.
claude_preferred_login() {
    if [ -s "$ACCOUNT_DEFAULT_FILE" ]; then
        claude_account_confdir "$(claude_account_default)"
        return 0
    fi
    printf '%s' "${CLAUDE_CONFIG_DIR:-}"
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
    # ...and the move itself is kept. The default file says where the chain
    # stands; this says what it has been through, which is what the state block
    # reads to tell her the chain walked while she was away.
    mkdir -p "$(dirname "$ACCOUNT_LOG")" 2>/dev/null
    local from="$refused"
    [ "$from" = "$CLAUDE_PRIMARY_TOKEN" ] && from="primary"
    local to="$next"
    [ "$to" = "$CLAUDE_PRIMARY_TOKEN" ] && to="primary"
    log_append_bounded "$ACCOUNT_LOG" "$ACCOUNT_LOG_KEEP" \
        "$(printf '%s\t%s\t%s\t%s\t%s' "$(date +%s)" "$(basename "$from")" "$(basename "$to")" \
            "$(printf '%s' "${2:-limit refusal}" | tr '\n\t' '  ' | head -c 120)" \
            "${SESSION_KIND:-session}")"
    return 0
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

# A marker line in the stream log. It is the one place a human — or the debug
# viewer, or she herself reading the log back — can see WHY a turn went quiet
# for ten minutes. Deliberately a JSON line of an unknown type, which every
# reader of this log already skips by construction (extract-response,
# serve.py's tailer, crab-debug, the TTS streamer), and deliberately carrying
# no refusal TEXT: claude_run_limited greps the WHOLE log for the limit
# signature, so a marker quoting it would make a later network error read as
# one more refusal.
claude_stream_note() { # <note> <detail>
    [ -n "${DEBUGLOG:-}" ] || return 0
    printf '{"type":"deskcrab_note","note":"%s","detail":"%s","at":"%s"}\n' \
        "$(printf '%s' "$1" | tr -d '"\\')" \
        "$(printf '%s' "$2" | tr -d '"\\')" \
        "$(date '+%H:%M:%S')" >> "$DEBUGLOG" 2>/dev/null
    return 0
}

# Every account swap is announced. Ten minutes of silence under a stuck
# "Thinking..." was the symptom; the swap being invisible was the defect —
# she could not tell the user what had happened because nothing told her
# either. The marker goes into the stream log on every path; the desktop
# notification is for a turn somebody is waiting on, never for a wake (which
# may well be firing at three in the morning).
claude_swap_announce() { # <from token> <to token>
    local from="$1" to="$2"
    [ "$from" = "$CLAUDE_PRIMARY_TOKEN" ] && from="primary"
    [ "$to" = "$CLAUDE_PRIMARY_TOKEN" ] && to="primary"
    from="$(basename "$from")"; to="$(basename "$to")"
    claude_stream_note "account-swap" "$from -> $to (limit refusal)"
    [ "${SESSION_KIND:-}" = "autonomous wake" ] && return 0
    notify-send -t 5000 -h string:x-dunst-stack-tag:deskcrab-account \
        "$NOTIFY_NAME" "$from is over its limit — trying $to" 2>/dev/null
    return 0
}

# Watch a backgrounded CLI run and reap it when it stops being alive. $1 is
# the pid, $2 the stall timeout, $3 an absolute wall-clock deadline (0 = none).
# Leaves the child's exit status in CLAUDE_WATCH_STATUS and, when it had to be
# killed, the reason in CLAUDE_WATCH_REAPED.
#
# "Alive" is deliberately TWO signs, not one: new bytes in the stream log, or
# CPU burned across the process tree. The log gets nothing during a single long
# tool call (a compile delivers its output in one event at completion), so log
# freshness alone would kill genuine work; a hung network call or a tool stuck
# on stdin sits at ~zero CPU, so a real hang is still caught. The wall clock is
# the backstop the stall test by construction cannot be — a session that keeps
# emitting output is never silent — and is only ever set for a turn somebody
# is waiting on.
#
# The poll ticks every second and only does the work every tenth, because the
# loop's granularity is also the DELAY between the CLI finishing and the caller
# noticing: a flat 10 s sleep put ten dead seconds on the end of every turn.
_claude_watch() { # <pid> <stall seconds> <deadline epoch, 0 = none>
    local CPID="$1" STALL="$2" DEADLINE="${3:-0}"
    local LAST_ACTIVE PREV_CPU CUR_CPU LOG_M NOW TICK=0
    CLAUDE_WATCH_REAPED=""
    LAST_ACTIVE=$(date +%s)
    PREV_CPU=$(_tree_cpu "$CPID")
    while kill -0 "$CPID" 2>/dev/null; do
        sleep 1
        TICK=$(( TICK + 1 ))
        [ $(( TICK % 10 )) -eq 0 ] || continue
        CUR_CPU=$(_tree_cpu "$CPID")
        LOG_M=$(stat -c %Y "$DEBUGLOG" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        # Alive = new log output, or >=10 jiffies (~0.1 s) of CPU since last check
        if [ "$LOG_M" -gt "$LAST_ACTIVE" ] || [ $((CUR_CPU - PREV_CPU)) -ge 10 ]; then
            LAST_ACTIVE=$NOW
        fi
        PREV_CPU=$CUR_CPU
        if [ $(( NOW - LAST_ACTIVE )) -ge "$STALL" ]; then
            CLAUDE_WATCH_REAPED="silent and idle for ${STALL}s"
        elif [ "$DEADLINE" -gt 0 ] && [ "$NOW" -ge "$DEADLINE" ]; then
            CLAUDE_WATCH_REAPED="past this turn's wall clock"
        fi
        if [ -n "$CLAUDE_WATCH_REAPED" ]; then
            kill "$CPID" 2>/dev/null
            sleep 2
            kill -9 "$CPID" 2>/dev/null
            break
        fi
    done
    wait "$CPID" 2>/dev/null
    CLAUDE_WATCH_STATUS=$?
    [ -z "$CLAUDE_WATCH_REAPED" ] || claude_stream_note "reaped" "$CLAUDE_WATCH_REAPED"
    return 0
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
        # The primary account is "no override" — which is only the primary if
        # the variable is actually ABSENT. It is exported into a Claude Code
        # session's Bash-tool environment and job_start deliberately forwards
        # it, so a run inherited from a fallback turn used to walk the chain
        # with its own first slot pointing back at the login that had just
        # refused: three accounts became two, and the true primary was never
        # tried. Unset, not left standing.
        if [ -n "$CONFDIR" ]; then export CLAUDE_CONFIG_DIR="$CONFDIR"
        else unset CLAUDE_CONFIG_DIR; fi
        export "${CLAUDE_NO_AUTO_MEMORY?}"
        claude_profile_flags wake
        exec "$CLAUDE_BIN" -p --dangerously-skip-permissions \
            --model "$WAKE_MODEL" --effort "$WAKE_EFFORT" \
            --verbose --output-format stream-json \
            "${CLAUDE_PROFILE_FLAGS[@]}" \
            --append-system-prompt "$SYSTEM_PROMPT" \
            "$PROMPT_TEXT" >> "$DEBUGLOG" 2>&1
    ) &
    # No wall clock on a wake: nobody is waiting, and a long build is work.
    _claude_watch $! "$WAKE_STALL_TIMEOUT" 0
    WAKE_CLAUDE_STATUS=$CLAUDE_WATCH_STATUS
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
    local ACCT CONFDIR PREV="" ATT=0 REFUSAL
    for ACCT in $(claude_accounts); do
        CONFDIR="$(claude_account_confdir "$ACCT")"
        # Marker only on this path — claude_swap_announce keeps the desktop
        # notification for a turn somebody is waiting on.
        [ -z "$PREV" ] || claude_swap_announce "$PREV" "$ACCT"
        # Where THIS attempt's output begins. Every account appends to one
        # stream, so without the mark a later account's silent network failure
        # is judged against the refusal an earlier one left behind, and the
        # default moves onto an account that never refused anything.
        ATT="$(wc -c < "$DEBUGLOG" 2>/dev/null || echo 0)"
        case "$ATT" in ''|*[!0-9]*) ATT=0 ;; esac
        _wake_claude_run "$CONFDIR"
        REFUSAL="$(claude_stream_refusal "$DEBUGLOG" "$ATT")" || break
        claude_limit_record "$CONFDIR" "$REFUSAL"
        PREV="$ACCT"
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
    SYSTEM_PROMPT="$(build_system_prompt --profile wake)"

    # The concurrent-turn evidence — what the user just said to another session
    # of her, and that session's reply — is no longer appended here. It is the
    # regroup layer, and the assembler emits exactly one of the two blocks that
    # were saying the same thing in the same words. Appending it afterwards
    # also put text BELOW the turn frame, which has to be the last thing in the
    # prompt: the frame names the agenda as this wake's subject, and a block
    # after it is a second subject arriving later and louder.

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
        # touches, and a fixed retry stacks all of them onto the same second
        # (wake_book does the spacing, under the booking lock).
        #
        # NO kind gate. This used to be `[ -n "$WAKE_KIND" ] &&`, so the one
        # shape of wake that most needed rescuing — the one whose kind had been
        # blanked by the arity bug — was the one shape the outage retry refused
        # to re-book. Its agenda died with the outage.
        "$SCRIPT_DIR/crab" wake-at --by "${WAKE_BOOKED_BY:-outage-retry}" \
            1800s "${WAKE_KIND:-scheduled}" "${WAKE_REASON:-}" >/dev/null
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

    local SPOKEN DISPLAY_PART TRACE SILENT_NOTE="" QUIET_BUBBLE=""
    SPOKEN=$(spoken_part "$RESPONSE")
    DISPLAY_PART=$(display_part "$RESPONSE")

    # The (quiet) marker — the ONE authorized silence format (his standing
    # instruction, 2026-08-07): a wake with something worth leaving but not
    # worth voicing writes "(quiet) <thoughts>". The thoughts are SHOWN to
    # him as "(quiet) <thoughts>" — a bubble, never the speakers. A bare
    # marker with no thoughts is plain silence. A stray square-bracket
    # spelling (an old habit of Beatrice's, never authorized) is normalized
    # here so it is never voiced and never reaches him in bracket form.
    if printf '%s\n' "$RESPONSE" | grep -qiE '^[[:space:]]*[[(]quiet[])]'; then
        local THOUGHTS
        THOUGHTS="$(printf '%s\n' "$SPOKEN" \
            | sed -E 's/^[[:space:]]*[[(][Qq][Uu][Ii][Ee][Tt][])][[:space:]:—-]*//')"
        SILENT_NOTE="$(printf '%s\n' "$THOUGHTS" | tr '\n' ' ')"
        SPOKEN=""
        # ALWAYS visible — his instruction (2026-08-07): a quiet reply shows
        # as a "(quiet) ..." bubble no matter what; hiding it is forbidden.
        # QUIET_BUBBLE is what carries that promise past the nothing-to-deliver
        # gate below, which otherwise sees an empty SPOKEN and returns before
        # the bubble is appended. A bare marker with no thoughts stays plain
        # silence and earns no bubble.
        [ -n "$(printf '%s' "$THOUGHTS" | tr -d '[:space:]')" ] && QUIET_BUBBLE=1
        RESPONSE="(quiet) $THOUGHTS"
        if [ -n "$DISPLAY_PART" ]; then
            RESPONSE="$RESPONSE
---DISPLAY---
$DISPLAY_PART"
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
    # The claudism capture rides the same moment, and unconditionally: a
    # wake spoken to nobody is still her voice, audit follow-ups included.
    fire_claudism_capture wake "$RESPONSE"
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
    if [ -z "$(printf '%s' "$SPOKEN$DISPLAY_PART" | tr -d '[:space:]')" ] && [ -z "$QUIET_BUBBLE" ]; then
        return 0
    fi

    # Quiet hours suppress the SPEAKERS AND THE SCREEN, and that is the
    # intent, not an oversight. A window is quieter than a voice but it is not
    # nothing: it takes focus, it lights a dark room, and a night of them is a
    # desk covered in windows by morning. Every other statement of the knob
    # already says so — its own definition at the top of this file ("fully
    # silent — no speech, no windows") and the agenda the wake is handed on the
    # way in ("speaking and windows are suppressed — work silently") — so the
    # code has never been the odd one out; only the comment that used to sit
    # here was, and it is gone.
    #
    # What is NOT suppressed is the work. By the time this line runs the wake
    # has finished, journalled what it did, and fired the audit and the memory
    # judge. Only the delivery is held — and the record says so in those words,
    # because a wake the night silenced is not a wake that had nothing to say.
    # The next session reads this journal, and so does the since-your-last-reply
    # anchor, which counts a parenthesised outcome as a session that reached
    # nobody.
    #
    # Said in those words whatever shape the output took. The line used to be
    # written only when there were SPOKEN words, so a wake that built a chart
    # and a wake that left a (quiet) thought were both journalled as ordinary
    # silence — "(silent — ran 4 commands, wrote …)" — which is exactly the
    # reading rule 27 forbids: the next session, and the anchor that reads the
    # same journal, see an hour in which she had nothing to say rather than an
    # hour the night held.
    if in_quiet_hours; then
        session_outcome "(quiet hours — held, nothing spoken and nothing shown) ${SPOKEN:-${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}}"
        return 0
    fi
    # The user is mid-something a wake must not interrupt: a recording, speech
    # in flight, or a meeting holding the mic. Same treatment, same reason — a
    # window over the meeting he is in is an interruption too. Checked here, at
    # the last moment before delivery, because a wake that started in a quiet
    # room may end mid-meeting. Said in those words for every shape of output,
    # for the same reason the night's line is: a display-only wake held here did
    # not have nothing to say, and its journal line is the only place that can
    # say so.
    if user_busy; then
        session_outcome "(muted — user was mid-interaction) ${SPOKEN:-${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}}"
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
    # The header line stays: the phone's transcript renderer and the memory
    # ingester both read it. The marker on the block header is what the PROMPT
    # reads — a header line can be torn off its reply, and the next turn then
    # meets a wake's words wearing the face of something she said to him.
    convo_append '[Autonomous wake — %s]\n' "$(date '+%Y-%m-%d %H:%M')"
    convo_append_assistant --wake "$RESPONSE"
    # This wake REACHED him — specs/self-awareness.md rule 12 counts a wake
    # that got past the delivery gates as a session that delivered, and the
    # anchor reads that off the journal by one convention: a parenthesised
    # outcome means it reached nobody. A wake delivering a (quiet) bubble or a
    # display section has an empty SPOKEN, so its line was written up there as
    # "(silent — …)" — the not-delivered spelling — and the delta then skipped
    # straight past it to some earlier turn and re-reported work he had already
    # been shown. Restamped here, where delivery is a fact rather than a plan.
    if [ -z "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ]; then
        session_outcome "shown without speech${QUIET_BUBBLE:+ (a quiet bubble)}${DISPLAY_PART:+ (a window)}: ${SILENT_NOTE:-${TRACE:-ran no tools, touched nothing}}"
    fi
    # Delivered: a job that ended badly has now been reported to somebody.
    jobs_news_delivered
    compact_convo

    if [ -n "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ]; then
        notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "$(_notify_body "$SPOKEN")" 2>/dev/null
        wake_speak_to_phone "$SPOKEN" || speak_once "$SPOKEN"
    fi
    if [ -n "$DISPLAY_PART" ]; then
        local DISPLAYFILE
        DISPLAYFILE=$(mktemp "${STATE_PREFIX}-display-XXXXXX.md")
        printf '%s\n' "$DISPLAY_PART" > "$DISPLAYFILE"
        RENDER_MD="${RENDER_MD:-$(command -v render-md 2>/dev/null || echo "$HOME/.local/bin/render-md")}"
            RENDER_MD_ICON="${RENDER_MD_ICON:-$HOME/Beatrice/face/icons/beatrice-icon-512.png}"
        if [ -x "$RENDER_MD" ]; then
            spawn_display_window "$DISPLAYFILE"
        fi
    fi
}

# A display window must outlive the turn that opened it. setsid alone is not
# enough: a wake runs inside a systemd unit, and when its main process exits
# systemd reaps the whole control group — the window included. That is the
# mechanism behind the open-and-instantly-close flashing. A transient scope
# moves the window into its own cgroup, out of the executioner's reach.
spawn_display_window() {  # <displayfile>
    local f="$1"
    if systemd-run --user --collect --quiet \
            --unit="deskcrab-display-$(date +%s%N)" \
            -- "$RENDER_MD" --theme "${RENDER_MD_THEME:-beatrice}" \
            --icon "$RENDER_MD_ICON" --title "$NOTIFY_NAME" "$f" \
            >/dev/null 2>&1; then
        return 0
    fi
    # The fallback closes fds 8 and 9 like every other long-lived child here.
    # A wake holds the wake lock open on fd 9 for the life of its process, and
    # render-md is a window that lives until he closes it: inherit that fd and
    # the window holds the lock the whole time, so the next wake finds it taken
    # and defers itself — for as long as the window is on screen.
    setsid "$RENDER_MD" --theme "${RENDER_MD_THEME:-beatrice}" --icon "$RENDER_MD_ICON" --title "$NOTIFY_NAME" "$f" 8>&- 9>&- &
}

# Take this session's stream log and point the well-known name at it. Every
# session writes its own file, so no truncation by another hand can ever again
# strand a TTS streamer's read cursor past EOF. crab-debug tails the
# well-known path by hardcoded name, so that stays — as a symlink to whatever
# is talking now.
claim_debuglog() {
    : > "$DEBUGLOG"
    # First line of every stream: which session this is, written before a
    # single model byte. The viewer keys a stream by its inode and labels it
    # from the session registry, and a stream that starts by naming itself
    # survives the registry entry going away when the session ends — a log
    # still being drained after its session exited would otherwise fall back to
    # the class label ("desk") shared by every other stream on screen.
    # Deliberately the same deskcrab_note shape claude_stream_note uses, which
    # every reader of this log already skips by construction, and deliberately
    # carrying no refusal text.
    printf '{"type":"deskcrab_note","note":"session","detail":"%s pid %s","at":"%s"}\n' \
        "${SESSION_KIND:-session}" "$$" "$(date '+%H:%M:%S')" >> "$DEBUGLOG" 2>/dev/null
    ln -sfn "$DEBUGLOG" "$DEBUGLOG_LATEST" 2>/dev/null || true
    # A session's own log is small; the leftovers of dead ones still add up.
    #
    # A JOB's stream is excluded, and the exclusion is load-bearing. A turn is
    # over in seconds, so three quiet hours means a dead session; a detached
    # builder can spend longer than that inside ONE Bash tool call, writing
    # nothing, and its stream log is live the whole time. It sits under the
    # same -debug-*.log prefix (that is how crab-debug follows it), so this
    # sweep was unlinking the running builder's own stream out from under it:
    # the attempt slice went empty, the limit test read nothing, and a blocked
    # run could not record what blocked it. lib/job-runner reaps the streams of
    # jobs that have actually ended, where the question can be asked properly.
    find "$(dirname "$DEBUGLOG")" -maxdepth 1 \
        -name "$(basename "$STATE_PREFIX")-debug-*.log" \
        ! -name "$(basename "$STATE_PREFIX")-debug-job-*.log" \
        -mmin +180 -delete 2>/dev/null
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
        # See _wake_claude_run: "the primary" means the variable is absent,
        # never whatever the environment happened to arrive holding.
        if [ -n "$CONFDIR" ]; then export CLAUDE_CONFIG_DIR="$CONFDIR"
        else unset CLAUDE_CONFIG_DIR; fi
        claude_profile_flags turn
        exec "$CLAUDE_BIN" -p --dangerously-skip-permissions \
            --model "$CLAUDE_MODEL" --effort "$EFFORT" \
            --verbose --output-format stream-json --include-partial-messages \
            "${CLAUDE_PROFILE_FLAGS[@]}" \
            --append-system-prompt "$SYSTEM_PROMPT" \
            "$TEXT" >> "$DEBUGLOG" 2>&1
    ) &
    # Under the same watchdog the wake path has had all along. This was a
    # plain foreground subshell — no watchdog, no timeout — and claude_generate
    # looped it over every account with no bound either, so the only limit on
    # an interactive turn sat DOWNSTREAM of an unbounded loop and was never
    # reached: 680 s of silence at the desk on 2026-08-07, nothing spoken and
    # no error. TURN_DEADLINE is read from claude_generate's scope (bash
    # dynamic scoping, same as TEXT and SYSTEM_PROMPT above).
    _claude_watch $! "$TURN_STALL_TIMEOUT" "${TURN_DEADLINE:-0}"
    GENERATE_CLAUDE_STATUS=$CLAUDE_WATCH_STATUS
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
    # One wall clock for the WHOLE walk, handed down to each run's watchdog.
    # Per-account timeouts would still let a three-account chain run for three
    # times as long as anyone is willing to stand there.
    local TURN_DEADLINE=0
    [ "${TURN_CHAIN_TIMEOUT:-0}" -gt 0 ] \
        && TURN_DEADLINE=$(( $(date +%s) + TURN_CHAIN_TIMEOUT ))
    local ACCT CONFDIR PREV="" ATT=0 REFUSAL
    for ACCT in $(claude_accounts); do
        CONFDIR="$(claude_account_confdir "$ACCT")"
        [ -z "$PREV" ] || claude_swap_announce "$PREV" "$ACCT"
        # This attempt's own bytes begin here. Judging the whole accumulated
        # log instead let one account's refusal condemn the next account's
        # ordinary network failure and move the durable default onto a login
        # that had refused nothing.
        ATT="$(wc -c < "$DEBUGLOG" 2>/dev/null || echo 0)"
        case "$ATT" in ''|*[!0-9]*) ATT=0 ;; esac
        _generate_claude_run "$CONFDIR"
        REFUSAL="$(claude_stream_refusal "$DEBUGLOG" "$ATT")" || break
        claude_limit_record "$CONFDIR" "$REFUSAL"
        PREV="$ACCT"
        # No time left for another whole CLI boot and refusal.
        if [ "$TURN_DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$TURN_DEADLINE" ]; then
            claude_stream_note "chain-abandoned" "past this turn's wall clock"
            break
        fi
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
# A line-leading "(quiet)" marker — the authorized silence form — is
# stripped so it is never voiced by any caller; the wake gate above turns
# it into the silent bubble he sees.
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
    local PIPER_RC="${PIPESTATUS[1]}"
    # A dead synthesiser is not an empty file: ffmpeg muxes a header-only husk
    # (137 bytes, exit 0) from zero input, so a bare -s test calls a silent
    # clip a success. The smallest real utterance measures ~3000 bytes; 256
    # splits the two with room. Piper and ffmpeg both have their stderr
    # muzzled above, so this is the one place their death can be seen at all —
    # on 2026-08-08 two phone turns lost their voices in this pipeline with no
    # witness anywhere, and the cause could not be established from what
    # survived. Every silence explains itself somewhere.
    if ! [ -s "$OUT" ] || [ "$(stat -c %s "$OUT" 2>/dev/null || echo 0)" -lt 256 ]; then
        speech_log "synth_opus produced no audio for ${#TEXT} chars (piper rc=$PIPER_RC) -> $OUT"
        return 1
    fi
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
    # He has answered whatever was last said to this phone, so nothing said to
    # it is still in flight. Retired HERE, before a word of the prompt is
    # built, so the regroup layer below cannot be handed her own delivered
    # reply as a voice to fold in.
    live_speech_retire phone
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
    if claude_run_limited; then
        # Same routing as the desk turn: an all-refused chain reports the
        # CLI's refusal as the extracted reply. That is the outage speaking,
        # not me — never the conversation's assistant block, and never
        # synthesized for the phone's speakers. The error field carries it
        # as text the client can show.
        live_turn_end phone "$TEXT" ""
        session_outcome "(every account limited for: $(printf '%.80s' "$TEXT") — $(printf '%.120s' "$RESPONSE"))"
        ERROR="every login is over its limit: $(printf '%.140s' "$RESPONSE")"
        RESPONSE=""
    elif [ -n "$RESPONSE" ]; then
        SESSION_REPLY="$RESPONSE"
        convo_append_assistant "$RESPONSE"
        # Delivered: a job that ended badly has now been reported to somebody.
        jobs_news_delivered
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
        local CANDIDATE="${REMOTE_AUDIO_PREFIX}$(date +%s%N).opus"
        synth_opus "$SPOKEN" "$CANDIDATE" && AUDIO="$CANDIDATE"
        # The phone is about to play this. Same hand-off as a wake's phone
        # audio: no pid to watch, so publish the words with the clip's own
        # length as the end time, and a session starting behind it regroups
        # rather than answering into the middle of it.
        [ -n "$AUDIO" ] && live_speech_begin "phone" "$SPOKEN" 0 \
            "$(_speech_until "$AUDIO" "$SPOKEN")"
        # Let the desktop see that the phone is talking to it.
        notify-send -t 6000 -h string:x-dunst-stack-tag:deskcrab \
            "$NOTIFY_NAME (remote)" "$(_notify_body "$SPOKEN")" 2>/dev/null
    fi

    # What this turn's tools actually did, read BEFORE the stream log goes.
    # wake_work_trace opens $DEBUGLOG, and the removal below used to happen
    # twelve lines above the call: every phone turn handed the memory judge an
    # empty work trace, so a turn that edited a want document and dispatched a
    # job was judged as if it had done nothing but talk.
    local WORK_TRACE; WORK_TRACE="$(wake_work_trace)"

    rm -f "$DEBUGLOG"
    # Reply audio the client has had time to fetch. Scoped to THIS instance's
    # own prefix and to clips older than an hour — a pattern delete that only
    # said /tmp/deskcrab-remote-*.opus reaped the live instance's clips
    # whenever a scratch instance ran beside it.
    find "$(dirname "$REMOTE_AUDIO_PREFIX")" -maxdepth 1 \
        -name "$(basename "$REMOTE_AUDIO_PREFIX")*.opus" -mmin +60 -delete 2>/dev/null

    # Out of band, with the reply audio already synthesised: a want stated on
    # the phone dies with the turn exactly like one stated at the desk. The
    # memory judge rides the same moment — reply delivered, hot path over.
    fire_promise_audit "$TEXT" "$RESPONSE"
    fire_memory_judge "$TEXT" "$RESPONSE" "$WORK_TRACE"
    fire_claudism_capture phone "$RESPONSE"

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

# The "Thinking..." toast, and its dismissal — paired, and idempotent so the
# dismissal can be called from a trap AND on the straight line without a
# second empty notification flashing past.
# A notification body, cut to fit without splitting a character in half.
# `head -c 140` counts BYTES: an em dash whose three bytes straddle the
# boundary leaves a fragment behind, glib refuses to marshal invalid UTF-8 over
# D-Bus, and the notification is dropped whole — with its error swallowed by
# the `2>/dev/null` every caller has, so the desk simply goes quiet. iconv -c
# drops whatever the cut broke; without iconv the byte cut is still better than
# nothing.
_notify_body() {  # <text> [max bytes]
    local t; t="$(printf '%s' "$1" | tr '\n\t' '  ' | head -c "${2:-140}")"
    if command -v iconv >/dev/null 2>&1; then
        printf '%s' "$t" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
    else
        printf '%s' "$t"
    fi
}

_THINKING_SHOWN=0
notify_thinking() {
    _THINKING_SHOWN=1
    notify-send -t 0 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "Thinking..." 2>/dev/null
    return 0
}
notify_thinking_clear() {
    [ "${_THINKING_SHOWN:-0}" = 1 ] || return 0
    _THINKING_SHOWN=0
    notify-send -t 1 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" "" 2>/dev/null
    return 0
}

# Run claude, save response, handle display channel
run_claude_and_respond() {
    session_register "desktop turn"
    record_origin desk
    local TEXT="$1"
    # Recorded before generation: even a turn that dies mid-reply leaves the
    # user's words in the day journal.
    SESSION_USER_TEXT="$TEXT"
    # Same receipt as the phone turn: he is speaking to this desk, so whatever
    # was last said at it has been delivered and answered. Retired before the
    # prompt is built — a voice on the PHONE is untouched by this and is still
    # owed a regroup.
    live_speech_retire desk
    # Mark the exchange in flight: a wake firing beside this turn reads it
    # and is told the message is already being answered.
    live_turn_begin desk "$TEXT"

    convo_append_user "$TEXT"

    start_tts_streamer

    notify_thinking
    # The dismissal rides the trap as well as the straight line. "Thinking..."
    # is a -t 0 notification — it stays up until something takes it down — and
    # it was only ever dismissed after claude_generate RETURNED, so a turn that
    # died anywhere in between left it hanging over the desktop indefinitely.
    # That stuck toast over ten minutes of silence is exactly what the
    # account-swap stall looked like from the outside. session_finish is
    # chained in because session_register's trap is the one being replaced —
    # and so is its rule that a signal handler must END the process. Without
    # the exit, a TERM cleared the toast, finished the session record, and then
    # let the turn resume generating and speaking with no registration behind
    # it.
    trap 'notify_thinking_clear; session_finish' EXIT
    trap 'notify_thinking_clear; session_finish; exit 143' INT TERM

    local RESPONSE
    RESPONSE=$(claude_generate "$TEXT")

    notify_thinking_clear

    if claude_run_limited; then
        # Every account refused over a limit. extract_response reports the
        # refusal so an error-only stream can explain itself in a log — which
        # means RESPONSE holds the CLI's words, not mine. They never enter
        # the conversation as my reply and are NEVER spoken: the streamer
        # held them, its receipt reads empty, and the never-silent guard
        # below used to read that emptiness as a broken speech path and
        # replay exactly this text aloud. The notification and the journal
        # carry the outage; the default has already rotated, so the next
        # attempt leads with the next login.
        wait_tts_streamer
        live_turn_end desk "$TEXT" ""
        session_outcome "(every account limited for: $(printf '%.80s' "$TEXT") — $(printf '%.120s' "$RESPONSE"))"
        notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" \
            "every login is over its limit — nothing was said ($(printf '%.120s' "$RESPONSE"))" 2>/dev/null
        RESPONSE=""
    elif [ -n "$RESPONSE" ]; then
        SESSION_REPLY="$RESPONSE"
        convo_append_assistant "$RESPONSE"
        # Delivered: a job that ended badly has now been reported to somebody.
        jobs_news_delivered
        live_turn_end desk "$TEXT" "$(spoken_part "$RESPONSE")"
        compact_convo
        session_outcome "asked: $(printf '%.100s' "$TEXT") | replied: $(spoken_part "$RESPONSE")"

        local DISPLAY_PART
        DISPLAY_PART=$(display_part "$RESPONSE")

        if [ -n "$DISPLAY_PART" ]; then
            local DISPLAYFILE
            DISPLAYFILE=$(mktemp "${STATE_PREFIX}-display-XXXXXX.md")
            printf '%s\n' "$DISPLAY_PART" > "$DISPLAYFILE"
            RENDER_MD="${RENDER_MD:-$(command -v render-md 2>/dev/null || echo "$HOME/.local/bin/render-md")}"
            RENDER_MD_ICON="${RENDER_MD_ICON:-$HOME/Beatrice/face/icons/beatrice-icon-512.png}"
            if [ -x "$RENDER_MD" ]; then
                spawn_display_window "$DISPLAYFILE"
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
        fire_claudism_capture desktop "$RESPONSE"
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
    # CLAUDE_CONFIG_DIR is forwarded ONLY when it is actually set. Passing it
    # empty is not the same as not passing it: the unit then runs with the
    # variable defined-but-blank, the CLI looks for a login in "" and every
    # builder died in one second on "Not logged in". Worse, that is not a limit
    # refusal, so job-runner's account walk broke on the first attempt and no
    # fallback login was ever tried. Every job dispatched from a session with
    # no explicit config dir — which is all of them — was dead on arrival.
    #
    # Which login: the one the chain prefers, not the one this shell inherited.
    # specs/jobs.md rule 5 — a job is dispatched with the current preference and
    # walks the chain itself from there, so a builder starting behind a moved
    # default no longer pays a whole doomed CLI boot and refusal before its
    # first real attempt.
    local -a acctenv=() login
    login="$(claude_preferred_login)"
    [ -n "$login" ] && acctenv+=(--setenv=CLAUDE_CONFIG_DIR="$login")
    if systemd-run --user --collect --quiet --unit="$unit" \
        --setenv=PATH="$HOME/.local/bin:$PATH" \
        --setenv=DESKCRAB_CONF="$CONF_FILE" \
        --setenv=DESKCRAB_STATE_PREFIX="$STATE_PREFIX" \
        --setenv=JOBS_DIR="$JOBS_DIR" \
        --setenv=CLAUDE_BIN="${CLAUDE_BIN:-}" \
        "${acctenv[@]}" \
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
jobs_report() {  # [--live] [--defer]
    local marker="${STATE_PREFIX}-jobs-surfaced" since live=0 defer=0 a
    local -a extra=()
    for a in "$@"; do
        case "$a" in --live) live=1 ;; --defer) defer=1 ;; esac
    done
    if [ "$live" = 1 ]; then
        since="$(cat "$marker" 2>/dev/null)"
        case "$since" in ''|*[!0-9]*) since="$(date +%s)" ;; esac
        extra=(--live --failed-since "$since")
    fi
    "$LIB_DIR/job-status" report "$JOBS_DIR" "$JOBS_SHOW_FINISHED" "$JOBS_KEEP_DAYS" "${extra[@]}" 2>/dev/null \
        || echo "  (job status unavailable)"
    if [ "$live" = 1 ]; then
        # --defer: the news is not spent yet. A block rendered into a prompt
        # may go to a wake that ends in silence, and stamping the marker on
        # every render let exactly that wake eat a failed build's one-time
        # news — the next session that could actually have said something
        # never saw it. jobs_news_delivered spends it, at delivery.
        if [ "$defer" = 1 ]; then date +%s > "$marker.pending-$$"
        else date +%s > "$marker"; fi
    fi
    return 0
}

# The news reached somebody. Called from the three delivery points — the desk
# turn, the phone turn, and a wake that got past every gate — and nowhere else.
#
# The marker only ever moves FORWARD. The stamp is per-process and the marker
# is one global file, so two sessions that render in one order and deliver in
# another used to set it backwards: a wake rendering at 14:01 and delivering at
# 14:01:30 moved it to 14:01, then a desk turn that had rendered at 14:00 and
# spent two minutes answering moved it back to 14:00 — and every job that ended
# in between was news all over again, to the same person who had just been told.
jobs_news_delivered() {
    local marker="${STATE_PREFIX}-jobs-surfaced" mine cur
    mine="$(cat "$marker.pending-$$" 2>/dev/null)"
    rm -f "$marker.pending-$$"
    case "$mine" in ''|*[!0-9]*) return 0 ;; esac
    cur="$(cat "$marker" 2>/dev/null)"
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    [ "$mine" -gt "$cur" ] && printf '%s\n' "$mine" > "$marker" 2>/dev/null
    return 0
}

# The pending stamps of processes that are gone. A stamp belongs to the process
# that rendered the block, and session_finish drops it — but only a REGISTERED
# session has a finish to run. `crab status`, or anything else that builds the
# near view outside a turn, renders the block, leaves a stamp keyed to its own
# pid, and exits with nothing to clear it. The stamp then sits in the state
# directory forever.
#
# Sweeping it is not spending it: the durable marker is untouched, so the news
# it was holding is still owed and the next session that can actually say
# something still gets it. Called from session_reap, which is where everything
# a dead process left behind is cleared, and which runs on every render of the
# block. The stamp stays owned here, beside the two functions that write it.
jobs_news_sweep() {
    local marker="${STATE_PREFIX}-jobs-surfaced" s pid
    for s in "$marker".pending-*; do
        [ -e "$s" ] || continue
        pid="${s##*.pending-}"
        case "$pid" in
            ''|*[!0-9]*) rm -f -- "$s"; continue ;;
        esac
        kill -0 "$pid" 2>/dev/null || rm -f -- "$s"
    done
    return 0
}
