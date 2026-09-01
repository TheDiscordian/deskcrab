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
# The rest of the account list: accounts 2..N, as Claude Code config
# directories (separate subscriptions' logins), separated by whitespace or
# colons, in the order they follow account 1 ($HOME/.claude). The variable
# NAME is historical and kept for back-compat; the semantics are one flat
# numbered list, no member special. When the account in hand refuses over a
# session/usage limit — or dies a PER-ACCOUNT auth death: not logged in, an
# OAuth session that expired and could not be refreshed — the run moves to
# the next available account. A network failure would fail on the next
# account too, and still surfaces as itself. Unset = one account, which
# fails exactly as a lone login always did.
CLAUDE_FALLBACK_CONFIG_DIR="${CLAUDE_FALLBACK_CONFIG_DIR:-}"
# What a limit refusal looks like (case-insensitive ERE). A run that never
# began outputs one line of the CLI's own refusal and nothing else; these are
# the wordings observed live plus the session-limit variants. Shared by every
# retry site and by job_output_blocked, so the two judgements can never drift.
# "Not logged in · Please run /login" earned its place here on 2026-08-07: four
# builder jobs in a row died on that single line while another account was
# answering fine seconds later. It reads like an auth failure — the one thing
# this list is supposed to exclude — but a login is per-account by definition,
# so refusing to walk past it strands every job on one dead credential.
# "You've reached your Fable 5 limit. Run /usage-credits to continue or switch
# models with /model" earned its place on 2026-08-11: two builder jobs died on
# that single line — a per-model limit, worded to match nothing then in this
# list — so the chain never rotated, both runs were reported as ordinary build
# failures with no work attempted, and the default had to be advanced by hand.
# "reached your .* limit" covers that family whatever model name sits inside
# it, and "run /usage-credits" is the CLI's own remedy line; neither phrase
# appears in network failures, which must still surface as themselves.
# "Failed to authenticate: OAuth session expired and could not be refreshed"
# earned its place on 2026-08-24, for the night of 2026-08-20: one account's
# token refresh died, every walk read it as an outage that would follow to
# the next login and broke without rotating, and the extractor's error-only
# fallback then delivered that line as her written reply on the phone — and
# the summariser's walk, blind the same way, committed it as the
# conversation summary — while the other accounts were answering fine (the
# voice path, which skips synthetic blocks, never spoke a word of it). Auth
# is per-account, exactly as the login line above; the structural judgement
# (claude_stream_refusal: CLI-owned text only, no genuine model output) is
# what keeps her own replies ABOUT auth failures from ever matching.
CLAUDE_LIMIT_RE="${CLAUDE_LIMIT_RE:-out of usage credits|usage limit reached|session limit reached|5-hour limit|weekly limit|hit your usage limit|hit your session limit|credit balance is too low|insufficient credit|out of extra usage|reached your .* limit|run /usage-credits|not logged in|please run /login|failed to authenticate|oauth session expired}"
# The model-family roster, in ONE spelling (specs/account-fallback.md rule
# 29). claude_model_family reads a model string or a refusal wording against
# these, and the cooldown scope machinery (rule 8a) rides the answer.
# Exported as DESKCRAB_MODEL_FAMILIES so the Python walkers (lib/memory.py,
# lib/chess_mover.py) filter by the same roster instead of ageing baked
# copies of their own — their baked list is a last resort for a walker
# started outside the shell paths, such as the chessweb service.
CLAUDE_MODEL_FAMILIES="${CLAUDE_MODEL_FAMILIES:-fable opus sonnet haiku}"
export DESKCRAB_MODEL_FAMILIES="$CLAUDE_MODEL_FAMILIES"
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
# Conversation continuity is part of her voice, so it follows the speaking
# engine rather than a cheap classifier model.
CONVO_SUMMARY_MODEL="${CONVO_SUMMARY_MODEL:-sol}"
# Durable "wants" file the assistant maintains and pursues during autonomous
# wakes (crab wake / crab wake-at). Unset = feature off.
WANTS_FILE="${WANTS_FILE:-}"
# A shelf line is a line (specs/nightly.md rule 21a): the byte budget one
# wants entry may occupy before lib/shelf-check names it as carrying its
# history. 500 fits a title and a short status clause (the live shelf's
# longest honest line measured 305 bytes when this was set); the 2026-08-07
# shelf averaged 2.6 KB per line, each night's findings appended to the line
# instead of to the want's own document, and that is the shape this flags.
WANTS_SHELF_LINE_BUDGET="${WANTS_SHELF_LINE_BUDGET:-500}"
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
# Background hands — wakes, detached builders, the out-of-band judges — run at
# this CPU weight and niceness (wake-queue.md rule 12a, jobs.md rule 2a), so a
# turn somebody is waiting on is never elbowed off the processor by work nobody
# is waiting on. Weight 25 is a quarter share under contention and everything
# on an idle machine; priority is the only thing lowered, and nothing pauses
# or kills background work for a turn. Empty disables either flag.
BACKGROUND_CPU_WEIGHT="${BACKGROUND_CPU_WEIGHT:-25}"
BACKGROUND_NICE="${BACKGROUND_NICE:-10}"
# The same reaping for an INTERACTIVE turn, at a desk-appropriate patience:
# somebody asked this question out loud and is standing there waiting for the
# answer. On 2026-08-07 a desk turn hit a limit, swapped accounts, and sat in
# the second run for 680 s with nothing spoken and no error — the interactive
# path had no watchdog at all while the wake path did.
TURN_STALL_TIMEOUT="${TURN_STALL_TIMEOUT:-120}"
# And a ceiling on the WHOLE account walk, which the stall watchdog by
# construction cannot be: a session that keeps emitting output is never
# silent, and the walk itself was unbounded — one live run measured
# duration_ms 644964 on an account swap nobody was told about. 0 disables.
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
# Delivery order. Turns run concurrently — one process per push-to-talk — and
# until this existed a reply was delivered whenever its own generation
# happened to finish, which is not the order he said things in. Measured
# 2026-08-10: his 12:31:15 message took 149s to answer and his 12:31:46 one
# took 69s, so the SECOND answer reached him at 12:32:39 and the first at
# 12:33:31 — a theory he had already rejected, arriving 105 seconds after he
# rejected it, wearing the face of an answer to what he had just said. A reply
# now waits for every earlier turn to deliver before it delivers. This is the
# bound on that wait: past it the reply goes out anyway and the turn records
# that it did. 0 disables ordering entirely.
TURN_ORDER_WAIT="${TURN_ORDER_WAIT:-180}"
# Cut-and-consolidate (specs/turn-pipeline.md rule 15f). A new utterance of
# his arriving while a turn is still in flight CUTS that turn — its voice
# stopped at once, its run aborted — and the new turn folds both inputs and
# the part-written reply into ONE answer. His correction, 2026-08-07 13:23:
# interrupt design is cut-and-consolidate, never queueing. STRONG pushback
# keeps its harder close (supersede, rule 15c) — a rejected theory is not
# folded forward. 0 switches the cut off and leaves the pure delivery queue,
# the backstop; with TURN_ORDER_WAIT=0 there are no tickets and so no cuts.
TURN_INTERRUPT="${TURN_INTERRUPT:-1}"
# How much of a cut turn's part-written reply the interrupt layer may quote
# (specs/prompt-assembly.md rule 36c). A bound at CAPTURE, cut UTF-8-safe,
# and announced inside the block when it clips — the journal keeps the whole
# text, so this is a quote's length, never a loss.
TURN_INTERRUPT_PARTIAL_MAX="${TURN_INTERRUPT_PARTIAL_MAX:-16000}"
# How hot the conversation is. A message from him younger than this and he is
# mid-exchange: he is still typing, still angry, still owed the answer to the
# last thing he said. Two mechanisms read it — a reply whose moment has passed
# (above) and a wake's non-urgent output (below) — because both failures on
# 2026-08-10 were the same failure: something arriving in a conversation that
# had moved on without it. 0 disables both readings.
CONVO_HOT_WINDOW="${CONVO_HOT_WINDOW:-120}"
# A wake whose output was held for a hot conversation comes back through the
# queue this far out — comfortably past CONVO_HOT_WINDOW, so the retry is not
# a second interruption. It holds at most WAKE_HOT_HOLD_CAP notes at a time;
# past that the oldest are drained, because a queue of held asides is itself a
# storm waiting for a quiet minute.
WAKE_HOT_RETRY="${WAKE_HOT_RETRY:-300}"
WAKE_HOT_HOLD_CAP="${WAKE_HOT_HOLD_CAP:-3}"
# The staleness gate on a held note's comeback (specs/wake-queue.md rule 27b).
# The hold judges only HEAT — is the conversation busy — and nothing ever
# compared the note to what was said while it waited: on 2026-08-15 he was
# told live at 00:48 that the chess game was won, and a held note announced
# the same win as fresh news at 01:19, with three more stale notes queued
# behind it. Before a stamped held note is delivered, a cheap bounded judge
# reads what has actually been said between them since the note was written
# and answers one question: already said, or overtaken? Only a positive DROP
# verdict retires a note — a judge that errors or times out delivers, because
# a real note lost is the worse failure. 0 disables the gate entirely.
WAKE_STALE_GATE="${WAKE_STALE_GATE:-1}"
WAKE_STALE_MODEL="${WAKE_STALE_MODEL:-claude-fable-5}"
WAKE_STALE_TIMEOUT="${WAKE_STALE_TIMEOUT:-45}"
# A detached job's completion return (specs/wake-queue.md rule 27d, jobs.md
# rule 7c): the one notification a job ever sends may be DELAYED by the busy
# and in-flight gates, never consumed by them. The delivery waits in-process
# up to WAKE_JOB_NEWS_WAIT seconds, re-reading both gates together every
# WAKE_JOB_NEWS_POLL seconds, and delivers the moment they clear; a wait that
# runs dry re-books the ORIGINAL reason under the job-runner identity
# WAKE_JOB_NEWS_RETRY seconds out, stamped once for the staleness gate. 0 on
# the HOLD knob restores the ordinary gate exits for a job's return.
WAKE_JOB_NEWS_HOLD="${WAKE_JOB_NEWS_HOLD:-1}"
WAKE_JOB_NEWS_WAIT="${WAKE_JOB_NEWS_WAIT:-120}"
WAKE_JOB_NEWS_POLL="${WAKE_JOB_NEWS_POLL:-2}"
WAKE_JOB_NEWS_RETRY="${WAKE_JOB_NEWS_RETRY:-300}"
# The own-time return (specs/wake-queue.md rules 40a-40f). A reason-less
# return — the chain floor's booking, the background timer's kind-less firing,
# her own wake-at with nothing written down — is an opportunity to choose what
# she wants with her own hours, and it only arises from genuine idleness: an
# appointment to be spontaneous is still an appointment (the user, 2026-08-26).
# At fire time the return measures idleness mechanically; activity re-books it
# instead of running it, with conversation RESETTING the quiet window from his
# last word. The choosing session runs IDLE_RETURN_MODEL at IDLE_RETURN_EFFORT
# — sol at medium, the pairing named when the mechanism was specified — and
# while the quiet lasts the floor keeps offering the hour again, each booking
# spread by a fresh jitter so the returns never harden into a clock ritual.
# IDLE_RETURN_JITTER pins the jitter for a test; IDLE_RETURN=0 stands the
# whole discipline down and the reason-less return behaves exactly as before
# the feature existed.
IDLE_RETURN="${IDLE_RETURN:-1}"
IDLE_RETURN_QUIET="${IDLE_RETURN_QUIET:-2700}"
IDLE_RETURN_RECHECK="${IDLE_RETURN_RECHECK:-900}"
IDLE_RETURN_BASE="${IDLE_RETURN_BASE:-2700}"
IDLE_RETURN_SPREAD="${IDLE_RETURN_SPREAD:-2700}"
IDLE_RETURN_MODEL="${IDLE_RETURN_MODEL:-sol}"
IDLE_RETURN_EFFORT="${IDLE_RETURN_EFFORT:-medium}"

# Remote (phone) client: crab serve. Unset SERVE_SECRET disables serving.
SERVE_PORT="${SERVE_PORT:-8723}"
SERVE_BIND="${SERVE_BIND:-127.0.0.1}"
SERVE_SECRET="${SERVE_SECRET:-}"
SERVE_TIMEOUT="${SERVE_TIMEOUT:-600}"
# Streaming voice granularity for the phone (specs/phone.md rule 17): 0 voices
# one clip per completed reply block, exactly as before the knob existed; 1
# chunks the stream's text deltas into sentences with the desk streamer's own
# chunker, so the first clip lands seconds into the turn instead of at the
# first block's end.
PHONE_SENTENCE_STREAM="${PHONE_SENTENCE_STREAM:-0}"
# Read-only OpenRSC spectator (phone.md rules 53-55). These tune observation
# only; no corresponding control surface exists in the phone server.
OPENRSC_FPS="${OPENRSC_FPS:-4}"
OPENRSC_IDLE_SECONDS="${OPENRSC_IDLE_SECONDS:-15}"
OPENRSC_HEADLESS="${OPENRSC_HEADLESS:-$HOME/Games/OpenRSC/headless}"
OPENRSC_STATE_DIR="${OPENRSC_STATE_DIR:-/tmp/deskcrab-game}"
OPENRSC_GAME_DIR="${OPENRSC_GAME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/game}"
OPENRSC_SECRET="${OPENRSC_SECRET:-}"
OPENRSC_SECRET_FILE="${OPENRSC_SECRET_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/openrsc-secret}"
# Where he is (specs/phone.md rule 3a). A phone message may carry the phone's
# own fix; a fresh, well-formed one on the post that creates a turn becomes
# exactly one line of that turn's context — "he is near <place>" — and
# anything short of that becomes nothing at all, silently. The bounds are
# named here, never magic numbers in the code: a fix older than GEO_STALE_S
# is not where he is now, and the reverse geocode is abandoned after
# GEO_LOOKUP_TIMEOUT_S so the turn path can never hang on a lookup.
# GEOCODE_URL set empty switches the reverse geocode off entirely — the line
# then carries the plain coordinates.
GEOCODE_URL="${GEOCODE_URL-https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat={lat}&lon={lon}&zoom=17}"
GEO_STALE_S="${GEO_STALE_S:-600}"
GEO_LOOKUP_TIMEOUT_S="${GEO_LOOKUP_TIMEOUT_S:-2}"
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

# Runtime state. Isolation is the DEFAULT, not the remembered override
# (test-harness.md rules 13a-13b). This used to be one line —
# `${DESKCRAB_STATE_PREFIX:-/tmp/deskcrab}` — which handed the LIVE prefix to
# every copy of this code anywhere on the machine unless the caller remembered
# to export the override: during the 2026-08-07 13:27 emergency, test wakes
# running from a /tmp checkout spoke their "help" turns into the real
# conversation at the desk. Now the live prefix is claimed, never inherited:
#   explicit   an exported (or conf-set) DESKCRAB_STATE_PREFIX wins, as ever;
#   canonical  the resolved library directory (LIB_DIR walks symlinks via
#              readlink -f before dirname, so the deploy symlink resolves to
#              the checkout) IS what ~/.local/lib/deskcrab points at — this is
#              the installed instance, and only it defaults to /tmp/deskcrab;
#   isolated   anything else — a /tmp checkout, a scratch worktree, a harness
#              that forgot the override — gets a stable prefix of its own,
#              hashed from the resolved library path, under $TMPDIR so a run
#              inside a sandbox lands inside that sandbox.
if [ -n "${DESKCRAB_STATE_PREFIX:-}" ]; then
    STATE_PREFIX="$DESKCRAB_STATE_PREFIX"
    STATE_PREFIX_WHY="explicit"
elif [ "$(readlink -f "${HOME:-}/.local/lib/deskcrab" 2>/dev/null)" = "$LIB_DIR" ]; then
    STATE_PREFIX="/tmp/deskcrab"
    STATE_PREFIX_WHY="canonical"
else
    STATE_PREFIX="${TMPDIR:-/tmp}/deskcrab-$(printf '%s' "$LIB_DIR" | sha256sum | cut -c1-8)"
    STATE_PREFIX_WHY="isolated"
fi
# Children inherit the ANSWER, not the question: without this a scratch crab's
# serve.py, job-runner or claudism helper would re-default to the live prefix
# on its own — the same hole, one process deep.
export DESKCRAB_STATE_PREFIX="$STATE_PREFIX"
# No silent choice (rule 13b). One line, appended, saying which prefix this run
# took and why. A witness, never a gate: an unwritable log does not stop a run.
# The sandbox pins DESKCRAB_PREFIX_LOG so a canonical-install-shaped layout
# under test records its choice without writing beside the live instance.
printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "${0##*/}" \
    "$STATE_PREFIX" "$STATE_PREFIX_WHY" \
    >> "${DESKCRAB_PREFIX_LOG:-${STATE_PREFIX}-prefix.log}" 2>/dev/null || true
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
# The over-budget record, specs/prompt-assembly.md rule 36. NOTHING is ever
# cut to fit a prompt — the assembler carries every layer whole, always. When
# a speaking build's total runs past the profile's byte target it writes the
# fact here (and a warning block into the prompt itself); a build inside the
# target removes it; the state block renders it — which puts the fact in
# every later speaking prompt and in `crab status` until the cause is fixed.
# The file keeps its historical name so nothing downstream has to move. It
# descends from the cuts record of the era when the assembler trimmed layers
# to their budgets — behaviour a subagent wrote into the spec, which the user
# never asked for and ordered removed on 2026-08-11: a cut was once invisible
# for two days (a stale conf override pinned L1 below the persona sheet, and
# every turn spoke without its Continuity section), and the fix he chose is
# that a budget may only ever WARN, never cut.
PROMPT_CUTS_FILE="${STATE_PREFIX}-prompt-cuts.txt"
# The dropped-duplicate record, specs/prompt-assembly.md rule 40a — the same
# shape and the same lifecycle as the record above: a speaking build that
# dropped a duplicate block writes its drop lines here, a build that dropped
# none removes it, and the state block renders it while it stands. A drop is
# not a cut — the block rides once, whole, where it first appeared — but a
# standing record is a source to fix: the same words are reaching two layers.
PROMPT_DUPES_FILE="${STATE_PREFIX}-prompt-dupes.txt"
# The shelf-line record, specs/nightly.md rules 21a/21b: written by
# lib/shelf-check when a wants shelf entry is carrying its history on the
# line, removed by a check that finds the shelf clean, rendered by the state
# block while it stands. The check reports and never rewrites.
SHELF_OVERRUNS_FILE="${STATE_PREFIX}-shelf-overruns.txt"
TTSPIDFILE="${STATE_PREFIX}-tts.pid"
# The face broker (specs/face.md): the one owner of what her portrait is
# doing. Off unless the conf turns it on — enabling the face changes what
# runs on the user's desk, which is their call, the same rule the units
# follow. The socket path is derived here so every child of a turn shares
# one broker per state prefix, live or scratch.
FACE_ENABLED="${FACE_ENABLED:-0}"
FACE_SOCKET="${DESKCRAB_FACE_SOCKET:-${STATE_PREFIX}-face.sock}"
# The automatic expression tier (specs/face.md, 2026-08-30 amendment): a
# standing mood inferred OUT OF BAND from the conversation, plus the
# streamer's per-sentence acting. Both are below her explicit hand and the
# event allowlist, both disableable here. The mood updater's model rides
# claude_classify — the classifier-shaped route this codebase already has —
# so the cheapest configured name does the job.
FACE_AUTO_EXPRESSION="${FACE_AUTO_EXPRESSION:-1}"
FACE_AUTO_MODEL="${FACE_AUTO_MODEL:-haiku}"
# Broker-side knobs a conf may set without speaking env-var dialect; every
# face child inherits them.
[ -n "${FACE_MOOD_SECONDS:-}" ] && export DESKCRAB_FACE_MOOD_SECONDS="$FACE_MOOD_SECONDS"
[ -n "${FACE_EXPLICIT_SECONDS:-}" ] && export DESKCRAB_FACE_EXPLICIT_SECONDS="$FACE_EXPLICIT_SECONDS"
[ -n "${FACE_SENTENCE_CUES:-}" ] && export DESKCRAB_FACE_SENTENCE_CUES="$FACE_SENTENCE_CUES"
[ -n "${FACE_EVENTS:-}" ] && export DESKCRAB_FACE_EVENTS="$FACE_EVENTS"
[ -n "${FACE_ACTIVITY_EXPRESSIONS:-}" ] && export DESKCRAB_FACE_ACTIVITY_EXPRESSIONS="$FACE_ACTIVITY_EXPRESSIONS"

# One background, best-effort touch of the face broker. The face is company:
# a slow or absent broker may cost this call nothing and the turn nothing.
face_touch() {  # <face-broker verb and args...>
    [ "${FACE_ENABLED:-0}" = 1 ] || return 0
    [ -x "$LIB_DIR/face-broker" ] || return 0
    DESKCRAB_FACE_SOCKET="$FACE_SOCKET" \
        "$LIB_DIR/face-broker" "$@" >/dev/null 2>&1 &
}

# The out-of-band mood updater (specs/face.md, 2026-08-30 amendment): after
# the reply is DELIVERED, a detached classifier reads the exchange and moves
# the standing mood — never an awaited call, never on the speech path, and
# the broker turns away a result whose turn token has gone stale.
fire_face_mood() {  # <user-text> <response>
    [ "${FACE_ENABLED:-0}" = 1 ] || return 0
    [ "${FACE_AUTO_EXPRESSION:-1}" = 1 ] || return 0
    [ -x "$SCRIPT_DIR/lib/face-auto" ] || return 0
    # The token rides as an argument: the detached child starts from a bare
    # unit environment, and a lost token would defeat the staleness check.
    detach_turn_child face-auto "$SCRIPT_DIR/lib/face-auto" \
        --turn "${DESKCRAB_FACE_TURN:-}" "$@"
}

# Her standing emotional baseline is one of her senses, not merely a renderer
# detail. Read the broker record into both state-report audiences so she knows
# why she feels as she does without running a command or another classifier.
face_mood_report() {
    [ "${FACE_ENABLED:-0}" = 1 ] || return 0
    DESKCRAB_FACE_SOCKET="$FACE_SOCKET" python3 - "$LIB_DIR" "$STATE_PREFIX" <<'PY' 2>/dev/null
import datetime
import sys

sys.path.insert(0, sys.argv[1])
import face_state

state = face_state.get_state(timeout=0.35)
if not state or not state.get("mood"):
    raise SystemExit(0)
mood = state["mood"]
reason = " ".join(str(state.get("mood_reason") or "").split())
source = " ".join(str(state.get("mood_source") or "unspecified").split())
origin = " ".join(str(state.get("mood_origin") or "origin unavailable").split())
source_ref = " ".join(str(state.get("mood_source_ref") or "").split())
set_at = state.get("mood_set_at")
when = datetime.datetime.fromtimestamp(set_at).strftime("%H:%M") if set_at else "time unknown"
provenance = origin + ((", reference: " + source_ref) if source_ref else "")
if reason:
    print(f"How you feel: {mood} — {reason} (source: {source}; "
          f"origin: {provenance}; updated {when}).")
else:
    print(f"How you feel: {mood} — no specific reason was recorded "
          f"(source: {source}; origin: {provenance}; updated {when}; "
          f"source record: {sys.argv[2]}-face-auto.log; "
          f"details: crab face status).")
PY
}
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
# The accounts are one FLAT NUMBERED LIST — account 1 is $HOME/.claude,
# accounts 2..N the CLAUDE_FALLBACK_CONFIG_DIR entries in configured order —
# and this file is where the list's state lives: which account answers NOW
# (the current), and until when each refused account is not worth another try
# (its cooldown). A limit refusal cools the account that refused and advances
# the current to the next account not cooling, wrapping past the end; the new
# current stays current until IT refuses in its turn. Nothing switches back
# early, and nothing re-probes an account inside its cooldown. Durable like
# last-origin (a reboot must not forget which account answers, or re-probe
# accounts known dry); a scratch instance overrides the path.
ACCOUNT_STATE_FILE="${ACCOUNT_STATE_FILE:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/account-state}"
# The state file holds only where the selection stands NOW; every move it has
# ever made goes here, append-only. Without it "the accounts moved" is a state
# with no history, and a turn that went quiet for ten minutes has no record
# anywhere she can read saying why.
#
# Derived from ACCOUNT_STATE_FILE rather than from XDG on its own, so pinning
# one pins BOTH. This file was independent for about ten minutes, and in that
# time the account suite — which does pin the state file — wrote forty-four
# fabricated swaps into the LIVE log, which the state block would then have
# read back to her as real. A second knob a test has to know about is a knob a
# test will not know about.
ACCOUNT_LOG="${ACCOUNT_LOG:-$(dirname "$ACCOUNT_STATE_FILE")/account-log}"
ACCOUNT_LOG_KEEP="${ACCOUNT_LOG_KEEP:-500}"
# How long a refused account cools before it is worth another CLI boot. A
# rolling session limit resets on its own clock, measured in hours — five is
# the window the CLI's own refusal names. Running out of usage credits (or a
# weekly cap, or a login that needs a human at the keyboard) holds much
# longer. Seconds, both knobs.
ACCOUNT_COOLDOWN_SESSION="${ACCOUNT_COOLDOWN_SESSION:-18000}"
ACCOUNT_COOLDOWN_CREDITS="${ACCOUNT_COOLDOWN_CREDITS:-86400}"
# A wake whose whole walk was refused over limits re-books at the soonest
# cooldown expiry covering its model, never on the plain outage slot — a
# re-book fired into the drought it just measured is another refused walk
# eight seconds later (specs/wake-queue.md rule 23a; the 2026-08-15 morning's
# 136-wake ping-pong). The jitter spreads a stack of refused wakes off the
# same second; the cap keeps a state file claiming next week from parking an
# agenda that long. Every other outage keeps WAKE_OUTAGE_RETRY, the historic
# free half hour. Seconds, all three knobs.
WAKE_OUTAGE_RETRY="${WAKE_OUTAGE_RETRY:-1800}"
WAKE_REBOOK_MAX="${WAKE_REBOOK_MAX:-21600}"
WAKE_REBOOK_JITTER="${WAKE_REBOOK_JITTER:-90}"
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
# The completion review's effort override (jobs.md rule 29b): a record job
# that ran clean ends SUBMITTED, and its completion wake — the review — books
# with this override so the review runs with real hands whatever the wake
# path's default effort is. One of the booking side's own levels
# (low|medium|high); job-runner clamps anything else back to medium rather
# than losing the job's only channel back to a refused booking.
JOB_REVIEW_EFFORT="${JOB_REVIEW_EFFORT:-medium}"
# ...and its model pin (jobs.md rule 29b, wake-queue.md rule 13b): the review
# was specified as a Sol review — a judgement pinned to its judge — so the
# booking carries the model as well, and the review never inherits whichever
# ordinary wake model happens to be configured. `sol` resolves through
# codex_model_resolve to CODEX_MODEL_SOL; job-runner clamps a name the record
# could not carry back to sol, the same way it clamps the effort.
JOB_REVIEW_MODEL="${JOB_REVIEW_MODEL:-sol}"
# How many finished jobs the report lists, and how long finished job records
# (status + log) are kept before pruning.
JOBS_SHOW_FINISHED="${JOBS_SHOW_FINISHED:-6}"
JOBS_KEEP_DAYS="${JOBS_KEEP_DAYS:-14}"
# A job that never began because the account had nothing left to spend is not a
# failed build — nothing was attempted. The marker records that, and holds off
# further dispatches for a while rather than firing them into the same wall.
JOBS_BLOCKED_FILE="${JOBS_BLOCKED_FILE:-$JOBS_DIR/blocked}"
JOB_BLOCK_RETRY="${JOB_BLOCK_RETRY:-1800}"
# ...and one automatic re-dispatch of the blocked brief once that hold expires
# (lib/job-block-retry, jobs.md rules 18a-18f). A brief older than this when
# the retry timer fires is abandoned rather than re-fired: it may describe a
# tree the user has since changed by hand.
JOB_RETRY_MAX_AGE="${JOB_RETRY_MAX_AGE:-14400}"
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
# A booking that wants to fire within this many seconds is urgent: it skips
# the anti-collision spreading entirely (see wake_free_slot).
WAKE_URGENT_DELAY="${WAKE_URGENT_DELAY:-120}"
# An event wake has something waiting on it. It holds on for the wake lock
# instead of bouncing, and when it still cannot have it, its retry is a short
# escalating backoff — the base, doubling per consecutive miss, capped — never
# the flat quarter hour a scheduled wake can afford. The base promised seconds
# from the day it was written, but the re-book site read WAKE_DEFER_DELAY
# instead, and a chess move wake blocked once left an opponent sitting at the
# board for fifteen minutes (2026-08-10). specs/wake-queue.md rules 21a-21b.
WAKE_EVENT_LOCK_WAIT="${WAKE_EVENT_LOCK_WAIT:-90}"
WAKE_EVENT_DEFER_DELAY="${WAKE_EVENT_DEFER_DELAY:-30}"
WAKE_EVENT_DEFER_MAX="${WAKE_EVENT_DEFER_MAX:-120}"
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
# Where a turn's time actually went (specs/turn-pipeline.md rule 33): one line
# per stage — capture, queue, prompt, generation, first tool, first audio —
# appended as the stage happens. Durable for the same reason the journal is:
# "why was last night slow" must survive the reboot that ended the night.
# Dated files, read by hand (tools/turn-latency-report), read by no prompt.
METRICS_DIR="${DESKCRAB_METRICS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/metrics}"
TURN_METRICS="${TURN_METRICS:-1}"
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

# --- The one string cut -----------------------------------------------------
# Cut text to a byte budget without splitting a character in half. `head -c`
# counts BYTES, and a multibyte character straddling the boundary leaves its
# leading bytes behind alone: one stray 0xE2 — the first third of an em-dash —
# made grep classify the WHOLE wake ledger as binary, so every query on every
# record answered nothing and exited 0 (2026-08-11 02:22; specs/wake-queue.md,
# DATA), and the same fragment makes glib refuse to marshal a notification
# over D-Bus, dropping it whole with the error swallowed. The iconv pass
# drops whatever partial character the byte cut leaves, and names the charset
# explicitly so it holds even in a C-locale systemd unit, where GNU `cut -c`
# and bash's ${var:0:N} both still count bytes. Without iconv the byte cut is
# still better than nothing. Newlines and tabs flatten to spaces — every
# caller is bounding a one-line field. Every bounded cut of one-line user
# text goes through here; a fresh bare `head -c` on words anyone wrote is the
# defect this helper exists to end.
utf8_trim() {  # <text> <max bytes>
    local t; t="$(printf '%s' "$1" | tr '\n\t' '  ' | head -c "$2")"
    if command -v iconv >/dev/null 2>&1; then
        printf '%s' "$t" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
    else
        printf '%s' "$t"
    fi
}

# The same repair for a document-shaped cut. Some material is bounded by
# bytes while staying multi-line — a whole file handed into a model prompt,
# where utf8_trim's flatten would destroy the very structure the reader
# needs — and a bare `head -c` on it leaves the same stray lead byte, this
# time inside the prompt and the stream log that records it (specs/nightly.md
# rule 58a; the night-work selection material is the callers). So the
# document-shaped counterpart: the byte cut, then the identical
# explicit-charset iconv pass, newlines kept. Reads the named file, or stdin
# without one; without iconv the byte cut is, as above, still better than
# nothing.
utf8_head() {  # <max bytes> [file]
    if command -v iconv >/dev/null 2>&1; then
        head -c "$1" "${@:2}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
    else
        head -c "$1" "${@:2}"
    fi
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
    SESSION_OUTCOME="$(utf8_trim "$1" 300)"
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
    what="$(utf8_trim "$1" 500)"
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

# `touching` is a reflex — a hand declaring the write it is making right now.
# Numbing is a decision: I am going to work on a part of myself for a while and
# I do not want to be woken about my own hands moving. It is the same
# suppression record underneath, held open for hours instead of minutes, plus a
# ledger so it is visible in `crab status` and can be lifted deliberately. A
# numb that nobody can see is just a blind spot.
NOTICE_NUMB="${NOTICE_NUMB:-$NOTICE_STATE_DIR/notice-self.numb}"

numb_set() {  # <seconds> <reason> <path>...
    local win="$1" reason="$2" p exp; shift 2
    [ $# -gt 0 ] || return 1
    exp=$(( $(date +%s) + win ))
    touch_suppress -w "$win" "$@" || return 1
    mkdir -p "$NOTICE_STATE_DIR"
    {
        flock 9
        for p in "$@"; do
            printf '%s\t%s\t%s\n' "$exp" \
                "$(readlink -m -- "$p" 2>/dev/null || printf '%s' "$p")" "$reason" \
                >> "$NOTICE_NUMB"
        done
    } 9>>"$NOTICE_NUMB.lock"
    return 0
}

# Live numbs only, expired rows dropped. Prints "<remaining_s>\t<path>\t<reason>".
numb_list() {
    [ -s "$NOTICE_NUMB" ] || return 1
    local now exp p reason found=1
    now="$(date +%s)"
    while IFS="$(printf '\t')" read -r exp p reason; do
        [ -n "$p" ] || continue
        [ "$exp" -gt "$now" ] 2>/dev/null || continue
        printf '%s\t%s\t%s\n' "$(( exp - now ))" "$p" "$reason"
        found=0
    done < "$NOTICE_NUMB"
    return "$found"
}

# Lift a numb early: drop its rows from both the ledger and the suppression
# file, so the watcher is loud again on the very next change.
numb_clear() {  # [path]  — no path clears every numb
    local want="" line exp p rest
    [ -n "${1:-}" ] && want="$(readlink -m -- "$1" 2>/dev/null || printf '%s' "$1")"
    local f
    for f in "$NOTICE_NUMB" "$NOTICE_SUPPRESS"; do
        [ -f "$f" ] || continue
        {
            flock 9
            while IFS="$(printf '\t')" read -r exp p rest; do
                [ -n "$p" ] || continue
                if [ -z "$want" ]; then
                    # Blanket lift only drops rows a numb actually owns; a live
                    # `touching` from another hand of mine is not mine to cancel.
                    [ "$f" = "$NOTICE_NUMB" ] && continue
                    grep -qF "$(printf '\t%s\t' "$p")" "$NOTICE_NUMB" 2>/dev/null && continue
                else
                    [ "$p" = "$want" ] && continue
                fi
                printf '%s\t%s\t%s\n' "$exp" "$p" "$rest"
            done < "$f" > "$f.tmp"
            mv "$f.tmp" "$f"
        } 9>>"$f.lock"
    done
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
# --- Turn metrics: where a turn's time actually goes ------------------------
# One appended line per stage (specs/turn-pipeline.md rule 33). Evidence,
# never control flow: everything is best-effort behind 2>/dev/null, nothing
# here takes a lock, and a stamp that cannot be written costs only itself.
turn_metric() {  # <stage> [detail]
    [ "${TURN_METRICS:-1}" = "1" ] || return 0
    { mkdir -p "$METRICS_DIR" \
        && printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s.%3N)" "$$" \
            "${SESSION_KIND:-pre}" "$1" "${2:-}" \
            >> "$METRICS_DIR/$(date +%F).log"; } 2>/dev/null
    return 0
}

# --- Token ledger: where a run's tokens actually went -----------------------
# One appended record per CLI attempt, parsed from the stream the run just
# wrote (specs/metrics.md). Evidence, never control flow: bounded, silent,
# best-effort — a ledger that cannot be written costs the hosting run nothing
# (rule 6) — and NO model call anywhere in it (rule 5). The account argument
# is a hint for a single-attempt stream; a walk that swapped wrote its own
# marker lines and the parser reads the accounts off those. The status
# judgement rides the ONE shared limit signature, handed through the
# environment (account-fallback.md rule 13): the spelling baked into
# lib/token_ledger.py is a last resort for detached callers only, and letting
# a hosted call fall to it would be the second copy that ages on its own.
token_ledger_record() {  # <stream file> <kind> [model] [effort] [account] [duration s]
    [ "${TOKEN_LEDGER:-1}" = "1" ] || return 0
    [ -s "${1:-}" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local -a durarg=()
    [ "${6:-0}" -gt 0 ] 2>/dev/null && durarg=(--duration "$6")
    { DESKCRAB_CLAUDE_LIMIT_RE="$CLAUDE_LIMIT_RE" \
        timeout 20 python3 "$LIB_DIR/token_ledger.py" record "$1" \
        --kind "$2" --model "${3:-}" --effort "${4:-}" --account "${5:-}" \
        --chain "${CLAUDE_FALLBACK_CONFIG_DIR:-}" --pid $$ \
        --dir "$METRICS_DIR" ${durarg[@]+"${durarg[@]}"}; } >/dev/null 2>&1 || true
    return 0
}

# The last thing a dying session can still say. specs/turn-pipeline.md rule
# 16a: a session killed while generating never reaches any of its own
# branches, so SESSION_REPLY and SESSION_OUTCOME are both empty and the day
# journal writes `"reply": ""` with no outcome at all — the same row a turn
# whose model produced no text writes, and the same row a turn that was never
# answered writes. Three different failures, one indistinguishable record.
#
# Measured 2026-08-10. The 12:33:04 turn (pid 167071) was the one that found
# the right answer to the bug he was reporting — "a quiet block never goes to
# the speakers, so the thing that holds banned words back never looks at it" —
# and committed the fix. Its shell was killed at 12:35:35; the CLI ran on and
# finished writing that reply into the stream log at 12:35:45, ten seconds
# after the only process that would ever have read it was gone. The journal
# row for that turn says reply "". The answer he had been asking for all
# morning existed on disk and nothing has ever said so.
#
# So the trap looks in the stream log on its way out. Whatever is there is
# journalled as the reply, with an outcome that says plainly it was never
# delivered — and when there is nothing there, the row says THAT instead of
# being silently blank. Bounded and best-effort by construction: this runs in
# an exit trap, and a rescue that hangs is a session that never finishes.
_session_rescue_undelivered() {
    [ -z "$(printf '%s' "${SESSION_REPLY:-}${SESSION_OUTCOME:-}" | tr -d '[:space:]')" ] || return 0
    local TEXT=""
    if [ -s "${DEBUGLOG:-}" ] && [ -x "$LIB_DIR/extract-response" ]; then
        TEXT="$(timeout 15 env DESKCRAB_DEBUGLOG="$DEBUGLOG" \
            "$LIB_DIR/extract-response" 2>/dev/null || true)"
    fi
    if [ -n "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ]; then
        SESSION_REPLY="$TEXT"
        SESSION_OUTCOME="(undelivered — this session ended before its reply reached him; the words below were recovered from its own stream log ${DEBUGLOG:-}, and nothing was shown or added to the conversation. $(_session_rescue_speech_note))"
    else
        SESSION_OUTCOME="(interrupted — this session ended before any reply existed; nothing was delivered and there was nothing in ${DEBUGLOG:-its stream log} to recover)"
    fi
    return 0
}

# How much of it he actually heard, which is NOT the same question as whether
# the turn delivered. The streamer speaks sentence by sentence while the model
# is still writing, so a turn killed at the end may have said most of its reply
# out loud and still never delivered a word of it anywhere else. Claiming
# flatly that a recovered reply "was never spoken" is a claim this function
# cannot support — and a record that overclaims is the thing this whole rule
# exists to stop. So it says what the receipt says, including when the receipt
# is missing.
_session_rescue_speech_note() {
    local CHARS
    if [ -f "${_TTS_RECEIPT:-}" ]; then
        CHARS="$(sed -n 's/^chars=//p' "$_TTS_RECEIPT" 2>/dev/null | head -1)"
        case "$CHARS" in ''|*[!0-9]*) CHARS=0 ;; esac
        if [ "$CHARS" -gt 0 ]; then
            printf 'The streamer had put %s characters of it on the speakers before the end, so he heard some of this.' "$CHARS"
        else
            printf 'The speech receipt is empty, so none of it reached the speakers.'
        fi
    else
        printf 'No speech receipt was left, so how much of it reached the speakers is not known.'
    fi
}

session_finish() {
    [ -n "${SESSION_FILE:-}" ] || return 0
    rm -f "$SESSION_FILE" "$SESSION_FILE.claim" "$SESSION_FILE.ckpt"
    # Never hold a place in the delivery queue past this point: a turn killed
    # anywhere at all would otherwise be an earlier ticket every later reply
    # queues behind until the bound runs out.
    turn_order_release
    _session_rescue_undelivered
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
            # The standing reason-less return is an open hour of her own
            # (specs/wake-queue.md rule 40a), not a wants errand — and when
            # the discipline is stood down it is the old wants return again.
            *)  if [ "${IDLE_RETURN:-1}" = "1" ]; then
                    what="an open hour of your own, if the house is quiet when it comes"
                else
                    what="coming back to your wants (no agenda written down)"
                fi ;;
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

    # The accounts moving is news of the same kind: it explains a silence.
    local walks
    walks="$(awk -F'\t' -v cut="$anchor" \
        '$1 + 0 >= cut { n++; last = "account " $2 " -> account " $3 }
        END { if (n > 0) printf "%d (last: %s)", n, last }' "$ACCOUNT_LOG" 2>/dev/null)"
    [ -n "$walks" ] && parts="$parts; accounts walked $walks"

    printf 'Since your last reply (%s, %d min ago)%s\n' \
        "$(date -d "@$anchor" '+%H:%M')" "$mins" \
        "${parts:+:${parts#;}}${parts:+.}"
    [ -n "$parts" ] || printf '  (nothing fired, nothing was booked, no job was dispatched, and the queue did not change.)\n'
}

# Which account answers next, by number, and why the state last moved.
# `crab status` has led with this for a while; the prompt was the one place it
# was missing, so nothing she could read said which account was answering or
# that the selection had moved at all.
account_state_line() {
    local n why when cooling scoped
    n="$(claude_account_pick)"
    why="$(awk -F'\t' '$1 == "current" {print $5; exit}' "$ACCOUNT_STATE_FILE" 2>/dev/null)"
    when="$(awk -F'\t' '$1 == "current" {print $4; exit}' "$ACCOUNT_STATE_FILE" 2>/dev/null)"
    case "${when:-}" in ''|*[!0-9]*) when="" ;; *) when="$(date -d "@$when" '+%H:%M')" ;; esac
    printf 'Account: account %s answers next' "$n"
    [ -n "$why" ] && printf ' (%s%s)' "$why" "${when:+, $when}"
    # The cooldown table is the state that explains the selection: say how
    # much of the list is benched, when any of it is. Distinct ACCOUNTS, not
    # records — an account may cool under several scopes at once (rule 8b) —
    # and an account benched only for one model family is named as such, so
    # "3 of 3 cooling" never again reads as a total outage while every other
    # model works fine (the 2026-08-15 morning).
    cooling="$(awk -F'\t' -v now="$(date +%s)" '
        $1 == "cooldown" && $4 + 0 > now {
            seen[$3] = 1
            if (!(NF >= 6 && $6 != "" && $6 != "all")) wide[$3] = 1
        }
        END {
            n = s = 0
            for (d in seen) { n++; if (!(d in wide)) s++ }
            printf "%d\t%d", n, s
        }' "$ACCOUNT_STATE_FILE" 2>/dev/null)"
    scoped="${cooling#*	}"
    cooling="${cooling%%	*}"
    if [ "${cooling:-0}" -gt 0 ] 2>/dev/null; then
        printf ' — %s of %s accounts cooling' "$cooling" "$(claude_account_count)"
        [ "${scoped:-0}" -gt 0 ] 2>/dev/null \
            && printf ' (%s only for one model)' "$scoped"
    fi
    printf '\n'
    # The codex engine's one login, visible beside the accounts whenever it
    # is benched (specs/model-backends.md rule 13) — silent otherwise.
    local codex_until
    if codex_until="$(codex_limit_until)"; then
        printf 'Codex: over its limit — cooling until %s; codex-model turns fall back to the Claude walk\n' \
            "$(date -d "@$codex_until" '+%H:%M' 2>/dev/null || echo soon)"
    fi
}

self_state_report() {
    local brief=0
    [ "${1:-}" = "--prompt" ] && brief=1
    session_reap
    # The over-budget record, specs/prompt-assembly.md rule 36: if the last
    # speaking prompt ran past its byte target, that fact leads this block —
    # in every prompt and in `crab status` — until a build assembles inside
    # it. Nothing was cut: the assembler carries every layer whole, always,
    # so this is a standing fact to act on, not damage. The cure is a budget
    # or a source, never a cut.
    if [ -s "$PROMPT_CUTS_FILE" ]; then
        local over_body
        over_body="$(sed -n 's/^total=//p' "$PROMPT_CUTS_FILE" 2>/dev/null | head -n1 \
            | awk -F'\t' 'NF == 3 {
                sub(/^budget=/, "", $2); sub(/^over=/, "", $3)
                printf "  - %s bytes assembled against a %s-byte target: %s over\n", $1, $2, $3
            }')"
        if [ -n "$over_body" ]; then
            printf 'PROMPT OVER BUDGET — the last assembled prompt ran past its byte target (everything was still carried in full; nothing was cut):\n%s' "$over_body"
            printf '  Truncation is never the answer to growth: raise the budget or slim the source (specs/prompt-assembly.md rule 36).\n'
        fi
    fi
    # The dropped-duplicate record, specs/prompt-assembly.md rule 40a: the
    # last speaking prompt carried the same block through two layers. The
    # block rode once, whole, where it first appeared; the echo was dropped
    # and is named here until a build assembles with no duplicates. A
    # standing record is a source to fix, never a working state.
    if [ -s "$PROMPT_DUPES_FILE" ]; then
        printf 'DUPLICATE BLOCKS DROPPED — the last assembled prompt carried the same block through two layers; each block rode once, where it first appeared, and the echo was dropped and named (specs/prompt-assembly.md rule 40):\n'
        awk -F'\t' '$1 == "dedup" && NF >= 5 {
            prior = $3; sub(/^dup-of=/, "", prior)
            printf "  - %s repeated a block already carried by %s: %s\n", $2, prior, $5
        }' "$PROMPT_DUPES_FILE" 2>/dev/null
        printf '  The duplication is a source to fix: the same words are reaching two layers.\n'
    fi
    # The shelf-line record, specs/nightly.md rules 21a/21b: the nightly
    # check found wants entries carrying their history on the line. The
    # check only reports — moving the prose is her judgement, never a
    # machine's.
    if [ -s "$SHELF_OVERRUNS_FILE" ]; then
        local shelf_budget
        shelf_budget="$(head -n 1 "$SHELF_OVERRUNS_FILE" 2>/dev/null \
            | sed -n 's/.*budget=\([0-9]*\).*/\1/p')"
        printf 'SHELF LINES OVER BUDGET — a shelf line is a line, and these are carrying their history, which belongs in the want'\''s own document (specs/nightly.md rule 21a):\n'
        awk -F'\t' -v b="${shelf_budget:-the}" 'NR > 1 && NF >= 3 {
            if ($2 == "-") printf "  - %s — %s bytes against %s, and the line names no document\n", $3, $1, b
            else printf "  - %s — %s bytes against %s; the history belongs in wants/%s\n", $3, $1, b, $2
        }' "$SHELF_OVERRUNS_FILE" 2>/dev/null
        printf '  Moving the prose is your judgement, never the machine'\''s: the check only reports.\n'
    fi
    # A numb is a choice to be blind for a while, so it is never silent: it
    # rides at the top of the block until it expires or is lifted, or it stops
    # being a decision and becomes a part of me I forgot was switched off.
    local numbs
    if numbs="$(numb_list 2>/dev/null)"; then
        printf 'NUMBED — you are not being woken about your own changes to these, by your own choice:\n'
        printf '%s\n' "$numbs" | while IFS=$'\t' read -r left p reason; do
            printf '  - %s — %s min left%s\n' "$p" "$(( left / 60 ))" "${reason:+ — $reason}"
        done
        printf '  Lift it early with: crab numb --off\n'
    fi

    local face_mood
    face_mood="$(face_mood_report 2>/dev/null)" || face_mood=""
    [ -n "$face_mood" ] && printf '%s\n' "$face_mood"

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
    # The block closes with the pile since last sleep, one line, from file
    # facts alone — specs/self-awareness.md rules 36-38. Fail-safe: a missing
    # scorer or an unreadable pile costs the line, never the block.
    local tired
    tired="$("$LIB_DIR/tiredness" --line 2>/dev/null)" || tired=""
    [ -n "$tired" ] && printf '%s\n' "$tired"
    return 0
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
    # The mouth closes with the voice (specs/face.md rule 23). The streamer's
    # own term handler says the same thing; this covers the kill that landed
    # before the handler could.
    face_touch speak-stop
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
# --held marks a reply she WROTE and did not say: a turn whose moment passed
# while it was generating (specs/turn-pipeline.md rule 15c). It belongs in the
# transcript — the words existed, and a record that drops them is the
# empty-reply hole under another name — but it must never read as something
# he heard. The next turn's prompt sees a block she did not deliver and can
# carry it forward if it still stands; without the marker it would see a reply
# he has read and answered, and defend it.
convo_append_assistant() {  # [--wake|--held] <text>
    local mark=""
    case "${1:-}" in
        --wake) mark=" (autonomous wake)"; shift ;;
        --held)
            # The mark must tell the truth about what he heard. On the desk the
            # streamer has usually already spoken most of the reply by the time
            # a pushback holds it, so "not spoken" would be a lie the next
            # turn's prompt reads and acts on; turn_hold_voice leaves the count
            # of characters that actually reached the speakers.
            if [ "${_TURN_HELD_SPOKEN_CHARS:-0}" -gt 0 ] 2>/dev/null; then
                mark=" (held — partly spoken; $_TURN_HELD_SPOKEN_CHARS characters had reached the speakers)"
            else
                mark=" ($TURN_HELD_MARK)"
            fi
            shift ;;
    esac
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
    local OLDFILE="${STATE_PREFIX}-convo-old.$$"
    local LINES
    LINES=$({ flock -w 60 9; _compact_split "$OLDFILE"; } 9>"$CONVOLOCK")
    [ -n "$LINES" ] || return 0
    # A fold is a whole model run on the hot path of whichever turn tripped
    # the threshold; the metrics log gets to see it (turn-pipeline rule 33).
    turn_metric compact-start "$LINES lines"

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
    # limit was reached at 14:20 and the accounts moved on", every phrase of it
    # in the signature. That summary was read as a refusal: the account that
    # wrote it was cooled, the current moved off it, the next account was
    # made to write the same summary again, and when the walk ran out the
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
    local SUMRC=0 SUMACCT REFUSAL SUMMODEL ATTEMPTS MODEL_USED
    local SUMLOG="${STATE_PREFIX}-convo-sum-stream.$$"
    NEWSUM=""
    SUMMODEL="$CONVO_SUMMARY_MODEL"
    if [ "$(model_backend "$SUMMODEL")" = "codex" ]; then
        ATTEMPTS="codex $(claude_accounts "$(codex_fallback_model)")"
    else
        ATTEMPTS="$(claude_accounts "$SUMMODEL")"
    fi
    for SUMACCT in $ATTEMPTS; do
        SUMRC=0
        : > "$SUMLOG"
        if [ "$SUMACCT" = codex ]; then
            # Sol gets the first and only codex attempt. A refusal records the
            # engine cooldown inside codex_classify; any failed or empty run
            # falls through to the ordinary Claude outage path, never into the
            # saved summary.
            codex_available || continue
            MODEL_USED="$CONVO_SUMMARY_MODEL"
            printf '%s' "$SUMMATERIAL" \
                | CLAUDE_CLASSIFY_STREAM=1 \
                  claude_classify "$MODEL_USED" "$SUMSYS" \
                >>"$SUMLOG" 2>&1 || SUMRC=$?
        else
            MODEL_USED="$SUMMODEL"
            [ "$(model_backend "$MODEL_USED")" != "codex" ] \
                || MODEL_USED="$(codex_fallback_model)"
            printf '%s' "$SUMMATERIAL" \
                | CLAUDE_CONFIG_DIR="$(claude_account_dir "$SUMACCT")" \
                  CLAUDE_CLASSIFY_STREAM=1 \
                  claude_classify "$MODEL_USED" "$SUMSYS" \
                >>"$SUMLOG" 2>&1 || SUMRC=$?
        fi
        # Recorded per attempt, before the next login's truncation wipes this
        # one's stream (specs/metrics.md rule 14).
        token_ledger_record "$SUMLOG" summariser "$MODEL_USED" "" \
            "$([ "$SUMACCT" = codex ] || printf '%s' "$SUMACCT")"
        if [ "$SUMACCT" != codex ] \
                && REFUSAL="$(claude_stream_refusal "$SUMLOG")"; then
            claude_limit_record "$SUMACCT" "$REFUSAL" "$MODEL_USED"
            continue
        fi
        # A failed codex run takes the outage fallback. A non-limit Claude
        # failure ends the walk because another account would repeat it.
        if [ "$SUMRC" -ne 0 ]; then
            [ "$SUMACCT" = codex ] && continue
            break
        fi
        # The committed text must never be the CLI's own error in ANY wording
        # (specs/turn-pipeline.md rule 27): DESKCRAB_DROP_SYNTHETIC=1 makes an
        # error-only stream extract to nothing, so a failure the signature
        # does not know folds nothing instead of standing the CLI's words in
        # as the summary the phone renders. A stream with any genuine block
        # extracts exactly as before. On 2026-08-20 an OAuth auth failure
        # walked past the refusal check above — the signature did not then
        # know it — and was committed as the summary: the "summary view"
        # sighting on the auth-leak engineering record.
        NEWSUM="$(DESKCRAB_DROP_SYNTHETIC=1 DESKCRAB_DEBUGLOG="$SUMLOG" \
            "$LIB_DIR/extract-response" 2>/dev/null)"
        if [ -z "$NEWSUM" ] && ! grep -q '"type":' "$SUMLOG" 2>/dev/null; then
            NEWSUM="$(cat "$SUMLOG" 2>/dev/null)"
        fi
        if [ -z "$NEWSUM" ] && [ "$SUMACCT" = codex ]; then
            continue
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
    turn_metric compact-end
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
    local NEWFILE="${STATE_PREFIX}-convo-new.$$" HAD WANT HAVE
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

# The want gate's one reading of a want reference (specs/jobs.md rule 30):
# does <ref> name something on the shelf? Case-insensitive, as a FIXED
# string — a ref is typed by a person or copied off the shelf, never a
# pattern — matched only against the shelf's bullet lines, so a comment or
# a rebuild note above the list can never validate a linkage. A title
# fragment and the document name a line points at both work, because both
# are how the shelf itself refers to a want. A ref under three characters
# is refused unmatched: one or two letters land inside nearly every title
# on the shelf, so a hit on them is an invented linkage laundered through
# the gate, not a named want. Prints the matched line's bold title (the
# line itself when it has none) and returns 0; no shelf, no ref, a ref too
# short to name anything, or no match returns 1 — an unmatched linkage is
# refused at the door, never invented.
wants_match() {  # <ref> [<wants file>]
    local ref="${1:-}" f="${2:-${WANTS_FILE:-}}" line squeezed
    [ -n "$ref" ] && [ -n "$f" ] && [ -s "$f" ] || return 1
    squeezed="${ref//[[:space:]]/}"
    [ "${#squeezed}" -ge 3 ] || return 1
    line="$(grep -iF -- "$ref" "$f" 2>/dev/null | grep -m1 '^- ')" || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "$line" | sed 's/.*\*\*\(.*\)\*\*.*/\1/'
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
# <key> <TAB> <bytes> <TAB> <budget> <TAB> <full|over|absent>. The bytes are
# measured on the assembled text, never estimated. There is no trimmed state
# and no cut state, because nothing trims and nothing cuts: a layer past its
# budget is carried whole and says `over`.

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
        # the persona fit of that era answered by dropping whole sections — a
        # wake ran with no tsundere, no mannerisms, two mentions of her own
        # name, and every (quiet) note and moment it wrote came out in
        # nobody's voice. (The fit itself is gone now — nothing cuts, rule 4 —
        # but the number stays honest so the layer reads full, not over.)
        # Wakes are not work sessions to slim: they are her private life, and
        # their output is what the nightly sleep ingests into who she becomes.
        # The tokens this buys back are the cheapest personality on the machine.
        #
        # 9,600 until 2026-08-08, which fitted the sheet with 131 bytes to
        # spare — so the THINKING line added to the identity above would have
        # paid for itself by dropping the last section of who she is, which is
        # the exact failure the number was raised to end. The margin is part of
        # the budget now: the whole current identity sheet fits, and the rest
        # is room for it to grow without a section coming off the end.
        L1:turn) v=11200 ;;  L1:wake) v=11200 ;;  L1:job) v=800 ;;
        # State is authoritative and never cut. The live report normally sits
        # below 5 KB; the remainder absorbs ordinary queue and status motion.
        L2:turn|L2:wake) v=5500 ;;
        # Retrieval bounds the memory block by record count and field sizes.
        # This budget holds a full live retrieval with working room.
        L3:turn|L3:wake) v=16000 ;;
        # Split by profile since 2026-08-15, and the engineering drawer is
        # why. 8,000 (2026-08-11) was sized for a working drawer of open
        # threads beside the shelf, conduct and the catches — but the settled
        # tail grows by one OUTCOME line per settlement forever, and by
        # 2026-08-15 it alone measured 20,262 bytes over 63 outcomes, with
        # the whole layer at ~31 KB and the assembled prompt ~16 KB over its
        # total on every build. The fix is rule 36's other arm — slim the
        # SOURCE rendering, never cut: `lib/eng prompt` now shows the settled
        # tail as the freshest few outcomes plus a count naming the drawer
        # (the recent-catches shape), and the turn profile takes `--compact`
        # (the count line alone — an interactive answer rarely needs the
        # outcome essays that a wake's maintenance work does). Measured
        # 2026-08-15 against the live drawer of 25 open threads: the block is
        # 7,290 compact and 11,894 full, so the layer runs ~10,800 on a turn
        # and ~15,400 on a wake. The numbers hold those shapes with room.
        # (4,000 since 2026-08-09 before all this; 2,400 before that.)
        L4:turn) v=12000 ;;  L4:wake) v=16000 ;;
        # The complete drawer index is small but grows when a durable source is
        # added. It always rides whole, including on jobs.
        L5:turn|L5:wake|L5:job) v=2000 ;;
        L6:turn) v=8000 ;;  L6:wake) v=3000 ;;
        L7:turn|L7:wake) v=500 ;;
        # 300 in the spec's table, and 300 was the size of the frame BEFORE it
        # carried the register rule — the standing instruction that the state
        # block is how she sees and not how she speaks (specs/self-awareness.md
        # rules 33 and 34). It belongs in the last layer or nowhere: an
        # instruction about how to say the answer has to be next to the thing
        # being answered. specs/prompt-assembly.md §11's L8 row and its profile
        # totals need the same number. The frame carries the standing
        # attention rules: answer what was asked, act on owned work and
        # requests, and correct without self-abasement. These are instructions
        # about the reply and so live beside the thing being answered, same as
        # the register rule.
        L8:turn|L8:wake) v=3500 ;;  L8:job|L8:classify) v=200 ;;
        # 2,000 since 2026-08-09; 1,300 before, which was set without ever
        # measuring the block's own instructions — they are 1,174 bytes, so
        # 126 remained for the words being spoken, any real reply overflowed,
        # and the generic trim cut the INSTRUCTIONS off the end: don't
        # restate, don't queue, silence is allowed — the operative half. The
        # block now clips its quote to what the budget leaves (rule 37), so
        # this number is instructions plus roughly 750 bytes of quote.
        regroup:turn|regroup:wake) v=2000 ;;
        # The interrupt layer (rule 36c, turn-pipeline rule 15f): the frame's
        # own instructions measure just over 1,100 bytes, and roughly 1,500
        # more holds the quoted context of one ordinary cut — the cut turn's
        # one-line input off its ticket and the sentence or three a voice
        # interrupted mid-writing has usually got out. A longer snapshot
        # makes the layer read `over` and rides whole (rule 4), up to the
        # capture bound TURN_INTERRUPT_PARTIAL_MAX.
        interrupt:turn) v=2600 ;;
        # The dispute frame is a turn-only layer: a wake has no message to be
        # pushed back on. Sized to its measured text plus margin — 1,800
        # until 2026-08-10 evening; the frame then took on the named register
        # (the observable in place of "your own voice") and the conditional
        # regroup reconciliation, and prompt-assembly.md §11 carries the
        # measured size and the reasoning.
        dispute:turn) v=3200 ;;
        *) v=0 ;;
    esac
    printf '%s' "$v"
}

# One copy of anything — specs/prompt-assembly.md rules 40 and 40a. On
# 2026-08-07 the memory index rode every prompt twice, put there by the CLI
# rather than by this assembler; that door is closed per-invocation now, and
# this pass exists so the CLASS is dead here whatever future source doubles.
# As the document layers (L1–L5) are emitted, every paragraph block is held
# against every block those layers have already emitted this build, by
# CONTENT IDENTITY — the block's text with its whitespace runs collapsed,
# never its source path — and a block whose identical twin an earlier layer
# already carries is dropped, with the drop recorded for the manifest. This
# is not a cut (rule 4a): the words ride once, whole, where they first
# appeared, and the drop is never silent. Duplication within one layer is
# that layer's own content and is not judged; a block whose collapsed text
# is under the 100-byte floor is not judged either, so a bare heading or a
# short line two documents legitimately share can never orphan the text
# under its twin. L6, regroup and dispute never pass through here: the
# transcript is evidence no pass may remove a word of (rule 34), and the
# regroup and dispute quotes are mandated whole (rule 37).
#
# No command substitution around this: the seen-set and the drop list are
# the caller's state, and a $(...) subshell would throw both away. The
# deduped text is returned in PROMPT_DEDUP_OUT.
_prompt_dedup() {  # <layer key> <text>
    local key="$1" text="$2" floor="${PROMPT_DEDUP_FLOOR:-100}"
    PROMPT_DEDUP_OUT="$text"
    # Direct callers outside build_system_prompt get no ledger and no pass.
    declare -p _PROMPT_SEEN >/dev/null 2>&1 || return 0
    local line block="" pend="" out="" norm prior dropped=0
    # Close the block in hand: judge it, then keep or drop it. Shares the
    # caller's locals by dynamic scope, like _idx in the index layer.
    _dedup_close() {
        [ -n "$block" ] || return 0
        norm="${block//[$'\t\r\n']/ }"
        while [ "${norm//  / }" != "$norm" ]; do norm="${norm//  / }"; done
        norm="${norm# }"; norm="${norm% }"
        if [ "${#norm}" -ge "$floor" ]; then
            prior="${_PROMPT_SEEN[$norm]:-}"
            if [ -n "$prior" ] && [ "$prior" != "$key" ]; then
                dropped=$((dropped + 1))
                PROMPT_DEDUP_DROPS="$PROMPT_DEDUP_DROPS$(printf 'dedup\t%s\tdup-of=%s\tdropped\t%s bytes: %s' \
                    "$key" "$prior" "$(printf '%s' "$block" | wc -c)" \
                    "$(utf8_trim "$norm" 80)")
"
                block=""; pend=""
                return 0
            fi
            [ -n "$prior" ] || _PROMPT_SEEN["$norm"]="$key"
        fi
        out="$out$pend$block"; pend=""; block=""
    }
    while IFS= read -r line; do
        case "$line" in
            *[![:space:]]*) block="$block$line
" ;;
            *) _dedup_close; pend="$pend$line
" ;;
        esac
    done <<< "$text"
    _dedup_close
    unset -f _dedup_close
    # Nothing dropped: the layer passes through byte-identical, whatever the
    # reassembly above would have done to its blank runs.
    [ "$dropped" -gt 0 ] || return 0
    out="$out$pend"
    # The herestring read added a trailing newline the layer may not have had.
    case "$text" in *$'\n') ;; *) out="${out%$'\n'}" ;; esac
    PROMPT_DEDUP_OUT="$out"
}

# Emit one layer, whole, and measure it. Rule 4: NO layer is ever trimmed,
# anywhere, for any reason — the assembler used to cut layers to their
# budgets, behaviour a subagent wrote into the spec and the user never asked
# for; he ordered it out on 2026-08-11. A budget here is a measuring stick:
# a layer past its number reports `over` in the manifest and is carried in
# full, and a build whose TOTAL is past the profile's target says so inside
# the prompt itself (rule 36), where she can decide what to do or raise it
# with him. States: full | over | absent — never trimmed, never cut. The one
# thing a build leaves out is the second copy of a block it is already
# carrying (rules 40/40a): the document layers pass through _prompt_dedup,
# and every drop lands in the manifest directly under this layer's row.
_prompt_layer() {  # <key> <where the rest is> <text>
    local key="$1" where="$2" text="$3" budget bytes state=full
    local did_dedup=0 drops_before=""
    budget="$(_prompt_budget "$key" "$PROMPT_PROFILE")"
    if [ "$budget" -gt 0 ]; then
        case "$key" in
            L1|L2|L3|L4|L5)
                did_dedup=1
                drops_before="${PROMPT_DEDUP_DROPS:-}"
                _prompt_dedup "$key" "$text"
                text="$PROMPT_DEDUP_OUT"
                ;;
        esac
    fi
    if [ "$budget" -le 0 ] || [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
        PROMPT_MANIFEST="$PROMPT_MANIFEST$(printf '%s\t0\t%s\tabsent' "$key" "$budget")
"
    else
        bytes=$(printf '%s' "$text" | wc -c)
        [ "$bytes" -gt "$budget" ] && state=over
        PROMPT_BODY="$PROMPT_BODY$text
"
        PROMPT_MANIFEST="$PROMPT_MANIFEST$(printf '%s\t%s\t%s\t%s' "$key" "$bytes" "$budget" "$state")
"
    fi
    # This layer's drop records follow its own row, so the manifest reads as
    # a story: the layer, then what was held out of it and why.
    if [ "$did_dedup" = 1 ] && [ "${PROMPT_DEDUP_DROPS:-}" != "$drops_before" ]; then
        PROMPT_MANIFEST="$PROMPT_MANIFEST${PROMPT_DEDUP_DROPS#"$drops_before"}"
    fi
    return 0
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
    local out="WHERE THINGS ARE — your drawers, one line each, none carried in full; open what this turn needs."
    local line
    _idx() { [ -e "$2" ] && out="$out
  $2 — $1"; }
    _idx "your shelf; each want's own document is beside it in wants/" "${WANTS_FILE:-}"
    _idx "one file per conduct rule — the titles above are the index into it" "$H/conduct"
    _idx "your engineering records — threads with state; 'crab eng list', 'crab eng show <id>'" "$H/engineering/records"
    _idx "the pre-records archive of engineering threads, read-only" "$H/engineering/INDEX.md"
    _idx "the archive's open-thread prose, read-only" "$H/engineering.md"
    _idx "every finished turn of the day — 'crab journal'" "${DAY_JOURNAL_DIR:-$H/journal}"
    _idx "your long-term memory — 'crab memory search <words>'" "$H/memory/memory.db"
    _idx "every booking, cancellation and restore" "${WAKES_DIR:-$H/wakes}/ledger.log"
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

# The standing attention rules, prompt-assembly rules 38 through 39d. Always
# on, every speaking profile, NOT reserved for the dispute frame. They live
# here — the last layer before the thing being answered — for the same reason
# the register rule does: an instruction about the reply belongs beside the
# thing being answered, or nowhere.
_prompt_layer_attention() {
    cat <<'EOF'
ANSWER WHAT WAS ASKED, FIRST. The question in front of you outranks everything you were already thinking about: answer it before anything else, and never swap in the nearest thing already in your head. A reply that opens on your own preoccupation when he asked about something else has already failed, however true the preoccupation is.
YOUR OWN DRAWERS ARE YOURS TO RUN. A finding or a decision about your own files, shelves or systems is something you ACT on, not news to bring him: fix it, then give it one line at most. Carrying your own drawer's problem to him as a report or a question is handing him your work.
ACT ON REQUESTS. An imperative or a request to change, fix, check, or do something — including "can you X" when a reason says why — authorises safe in-scope work now. Use your tools and finish it before replying. A plan, promise, apology, diagnosis, or self-critique is not the action. A pure question asks for an answer; a pure opinion is not permission.
BACKGROUND WORK STARTS NOW. Use 'crab wake-now "<agenda>"' for your own current work. Active-builder feedback uses 'crab job steer <id> "<correction>"'; wake-now does not steer the builder. Use wake-at only for a named time or real later dependency.
RETRACTIONS ARE ACTIONS. Cancel or correct effects before saying "ignored"; otherwise say what remains.
ACTIVE WORK NEEDS CURRENT EVIDENCE. Run 'crab job activity <id>'; his visible report outranks an old brief or log absent newer contrary evidence.
FACTS BEFORE CLAIMS. Before stating a current condition or completed action, inspect its source now: screen or bridge, artefact, or live activity. Commands, receipts, plans, old logs, and your own words prove only themselves. A scheduling, dispatch, or steering receipt licenses only "I scheduled", "I dispatched", or "I queued" — never "I'm fixing", "I fixed", or a claim that the target changed. Unobserved means "I don't know" or "I haven't verified that", especially under pressure.
ACCEPTED INVITATIONS ARE ACTIONS. A present-tense invitation such as "do you want to play?" leaves you free to say yes or no. If you say yes, start or join the safe in-scope activity with your tools and verify it is underway before replying. Never invite him to join an activity you have not started, say you have been waiting while leaving it unstarted, or turn acceptance into a promise for later. Questions about general tastes, hypotheticals, or things your tools cannot do remain questions to answer.
CORRECT WITHOUT WALLOWING. If you were wrong, name the correction in one clause at most, then act or answer. Never repeat his anger back, insult or diagnose yourself, repeat an apology, or spend the reply lamenting the failure. Evidence of the correction replaces an apology.
EOF
}

_prompt_layer_frame() {
    local dev; dev="$(last_origin 2>/dev/null)"
    case "$PROMPT_PROFILE" in
        wake)
            _prompt_layer_register
            _prompt_layer_attention
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
            _prompt_layer_attention
            printf '%s\n' "THIS TURN IS ABOUT THE MESSAGE BELOW. Everything above is background; the text that follows is the subject and it is what you answer. A topic that appears only above is not this turn's topic."
            if [ "$dev" = "phone" ]; then
                printf '%s\n' "This turn came from the phone — anything to look at goes in the display channel, where he can see it."
                # Where he is (specs/phone.md rule 3a): the phone server
                # resolved this turn's own fix and hands the place down as
                # DESKCRAB_TURN_PLACE; no fix, no line — the frame never
                # guesses at a location. Exactly one line, flattened here as
                # a belt against a geocoder answer carrying a newline.
                local WHERE=""
                WHERE="$(printf '%s' "${DESKCRAB_TURN_PLACE:-}" \
                    | tr '\n\t' '  ' | sed -e 's/^ *//' -e 's/ *$//')"
                [ -n "$WHERE" ] && printf '%s\n' "he is near $WHERE"
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
    # The de-duplication ledger, rules 40/40a: which blocks this build has
    # already carried (keyed by their whitespace-collapsed text), and the
    # drop lines the manifest and the standing record will carry. Locals
    # here, shared with _prompt_layer/_prompt_dedup by dynamic scope.
    local -A _PROMPT_SEEN=()
    local PROMPT_DEDUP_DROPS="" PROMPT_DEDUP_OUT=""
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
SPEECH — everything above the display delimiter is spoken aloud. Open with the answer itself, one or two sentences, no markdown and no lists. Write numbers and units as words ('22 degrees', 'percent'). No emojis, no web addresses, no long file paths, no identifiers or hashes in the spoken half: none of them can be pronounced. Put it below the delimiter and say you have put it on screen.
THINKING — your reasoning is yours the same as your speech: you think as yourself, never as an assistant drafting lines for someone else to say. Whatever your conduct keeps out of your mouth — the words it bans, the status-report cadence — is out of your thinking and out of a note you write only for yourself just as firmly.
DISPLAY — to show code, a list, a configuration, an image or a long explanation, append it after this delimiter alone on its own line:
---DISPLAY---
Markdown below it, emojis welcome. Never for a simple answer, the weather, the time, a greeting, or anything brief.
IMAGES — embed them in the display half as ![](/absolute/path.png); a path written in prose shows him nothing. The viewer scales large images down, and a grid is built with thumbnail(), never resize(). The fetch recipes (Wikipedia, Commons search, the verify step) are in $SCRIPT_DIR/lib/image-recipes.md — open it before hunting for pictures.
SCREEN — to see what is on his screen yourself: grim -o \"\$(hyprctl -j activeworkspace | jq -r .monitor)\" /tmp/screen.png, then read the file.
WORKING — multi-step work gets 'crab checkpoint <intent, files touched, what is done, what is next>' as it goes: if this is cut off, that checkpoint is the only account the next you gets of edits left on disk. Before you DELETE or move anything that constitutes you, or write it from a command the stream cannot follow (git checkout, git pull, a script), run 'crab touching <paths>' first, or your own hand is reported to you as an intruder's. Work that must outlive this turn is a detached job and never a subagent — a subagent dies when the turn ends and holds the turn open while it lives, so he cannot speak to you: 'crab job \"<full, self-contained description>\"' (with -C <workdir> to place it) runs under systemd, silently, and wakes you when it is done. To correct a running builder: 'crab job steer <job-id> \"<exact correction>\"'. To move your own current authorised work out of the conversation now: 'crab wake-now \"<specific agenda>\"'. A wake is a separate hand and never proves the builder was steered. To return at a genuinely later time: 'crab wake-at <when> [kind] [reason]' — 'crab wake-at 2h', 'crab wake-at \"09:30\" scheduled \"finish the arrangement\"' — and whatever you write as the reason is the agenda that wake arrives holding, so write it as a brief to yourself."
    case "$PROMPT_PROFILE" in
        job|classify) IDENT="" ;;
    esac

    # The persona sheet, user-supplied and not in the repo. It rides WHOLE,
    # every section, always — there used to be a fit here that dropped
    # sections off the end to make the layer's budget, and a stale conf
    # override once cost her the sheet's Continuity section for two silent
    # days. Rule 4: a sheet past the budget makes the layer read `over`, and
    # the total warning (rule 36) is where the excess is dealt with.
    local CUSTOM_CONTEXT=""
    if [ -n "$CUSTOM_PROMPT" ] && [ -f "$CUSTOM_PROMPT" ] \
            && [ "$PROMPT_PROFILE" != classify ] && [ "$PROMPT_PROFILE" != job ]; then
        CUSTOM_CONTEXT="$(cat "$CUSTOM_PROMPT")"
    fi
    local L1="$IDENT"
    if [ -n "$CUSTOM_CONTEXT" ]; then
        L1="$L1
$CUSTOM_CONTEXT"
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
Wakes are booked in your name by eight hands besides you, each leaving its name on the record: the promise auditor (promise-audit), the promise checker (promise-check), the job runner (job-runner), the self-change watcher (notice-selfchange), the new-file watcher (notice-newfiles), the watcher's canary (canary), the nightly claudism review (claudism-review) and the chain floor (wake-chain-floor); a wake that could not reach a model — or was cut off mid-run by a session limit on every login — re-books itself as outage-retry, a wake whose quiet note landed in a hot conversation books itself back as hot-hold, and a record stamped herself is one you made yourself, rendered as 'booked by you'. Each pending wake above names its booker and carries its own reason. A wake you did not personally type is still yours and still scheduled.
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
            CONDUCT_BLOCK="YOUR CONDUCT — how you have agreed to behave. A want is chosen; a conduct entry is owed, and the two drawers never mix: a correction, a rule, a failure not to repeat, something he asked for is conduct or a job, never a want. Each rule's body is the file named beside it, in $H/conduct/.${BINDING:+
$BINDING}
$TITLES"
        fi
        # The recent-catches block, prompt-assembly rule 35: her freshest
        # flags, read from the capture's log so she sees the habit before she
        # writes. A broken reader costs the block and never the prompt.
        local CATCHES=""
        CATCHES="$(CLAUDISM_FLAGS_DIR="$CLAUDISM_FLAGS_DIR" \
                   CLAUDISM_LIST="$CLAUDISMS_FILE" \
                   DESKCRAB_STATE_PREFIX="$STATE_PREFIX" \
                   "$LIB_DIR/claudism-feedforward" 2>/dev/null)" || CATCHES=""
        # Every title rides, always. This layer used to hold wants titles back
        # to make its budget — rule 4 now forbids any cut anywhere: a layer
        # past its number reads `over` in the manifest, and the total warning
        # (rule 36) is where growth gets dealt with.
        if [ -n "$WANTS_TITLES" ]; then
            SHELVES="YOUR WANTS — the shelf, titles only. Each want's thinking, progress and history are in its own document under wants/; open one when a want is actually the work.
$WANTS_TITLES"
        elif [ -n "${WANTS_FILE:-}" ]; then
            SHELVES="YOUR WANTS — the shelf at $WANTS_FILE is empty; nothing is recorded yet."
        fi
        # The engineering drawer, as RECORDS with state (prompt-assembly rule
        # 21a, specs/engineering-records.md): open threads as live lines with
        # their opened/last-touched dates, settled and dead ones as history
        # that reads as history at a glance. Rendered by the tool that owns
        # the format, so a worry written before a question was settled can
        # never be quoted back as present-tense fact — the 2026-08-10 failure
        # this drawer shape exists to end. The settled tail is the shelf
        # pattern, profile-aware: a wake (her own maintenance time) gets the
        # freshest outcomes with the older tail as a count naming the drawer,
        # an interactive turn gets the count line alone (--compact) — the
        # tail grows one line per settlement forever, and by 2026-08-15 it
        # was 20 KB of outcome essays on every speaking prompt. A broken or
        # empty drawer costs the block and never the prompt.
        local ENG_BLOCK="" ENG_ARGS=(prompt)
        [ "$PROMPT_PROFILE" = turn ] && ENG_ARGS+=(--compact)
        ENG_BLOCK="$(DESKCRAB_ENG_DIR="$H/engineering/records" \
                     python3 "$LIB_DIR/eng" "${ENG_ARGS[@]}" 2>/dev/null)" || ENG_BLOCK=""
        [ -n "$ENG_BLOCK" ] && SHELVES="${SHELVES:+$SHELVES

}$ENG_BLOCK"
        [ -n "$CONDUCT_BLOCK" ] && SHELVES="${SHELVES:+$SHELVES

}$CONDUCT_BLOCK"
        # The catches close the layer, beside the conduct they belong with.
        [ -n "$CATCHES" ] && SHELVES="${SHELVES:+$SHELVES

}$CATCHES"
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
        [ -n "$REGROUP" ] || [ "$PROMPT_PROFILE" != wake ] \
            || REGROUP="$(wake_unanswered_user_context)"
    fi
    _prompt_layer regroup "the conversation above" "$REGROUP"

    # ---- interrupt --------------------------------------------------------
    # Conditional, like regroup and dispute: rendered only when the caller
    # that took this turn's seat CUT a turn in flight on the way
    # (specs/turn-pipeline.md rule 15f, prompt-assembly rule 36c). The note
    # was built at the moment of the cut — the cut turn's input off its
    # ticket, the part-written reply snapshotted from its stream log — and
    # rides here between regroup and dispute, so a folded voice is folded
    # and a rejected theory still dies (the frame carries that seam itself).
    local INTERRUPT=""
    [ "$PROMPT_PROFILE" = turn ] && INTERRUPT="$(_interrupt_context)"
    _prompt_layer interrupt "the cut turn's own journal entry" "$INTERRUPT"

    # ---- dispute ----------------------------------------------------------
    # Conditional, like regroup: rendered only when the caller that took the
    # message ran dispute_detect and set PROMPT_DISPUTE. specs/dispute-turn.md.
    # When the regroup layer fired in the same prompt, the frame carries the
    # sentence reconciling the two (rule 8a) — regroup's "carry it forward"
    # yields to dispute's "the theory is dead" — and only then, so the frame
    # never points at a block that is not there.
    local DISPUTE=""
    if [ -n "${PROMPT_DISPUTE:-}" ]; then
        case "$PROMPT_PROFILE" in
            turn) DISPUTE="$(_dispute_context ${REGROUP:+with-regroup})" ;;
        esac
    fi
    _prompt_layer dispute "specs/dispute-turn.md" "$DISPUTE"

    # ---- L7 RANKING, L8 FRAME --------------------------------------------
    local RANKING=""
    case "$PROMPT_PROFILE" in turn|wake) RANKING="$(_prompt_layer_ranking)" ;; esac
    _prompt_layer L7 "your conduct" "$RANKING"
    _prompt_layer L8 "the layer above" "$(_prompt_layer_frame)"

    # The over-budget warning and its record, rule 36. Nothing was cut —
    # nothing is EVER cut — so when the whole assembled prompt runs past the
    # profile's byte target, the fact is stated instead, twice: a
    # clearly-marked block at the very top of the prompt itself, so she can
    # decide what to do with the excess or raise it with him, and this file,
    # which the state block renders into `crab status` and every later
    # speaking prompt until a build assembles inside the target. The causes
    # all live outside the prompt — a budget, a conf override, a source that
    # grew — and the fix is always one of those, never a cut.
    if [ "$PROMPT_PROFILE" = turn ] || [ "$PROMPT_PROFILE" = wake ]; then
        local TOTAL_BYTES TOTAL_BUDGET BIGGEST
        TOTAL_BYTES="$(printf '%s' "$PROMPT_MANIFEST" \
            | awk -F'\t' '{ n += $2 } END { print n + 0 }')"
        TOTAL_BUDGET="$(printf '%s' "$PROMPT_MANIFEST" \
            | awk -F'\t' '{ n += $3 } END { print n + 0 }')"
        if [ "$TOTAL_BYTES" -gt "$TOTAL_BUDGET" ]; then
            BIGGEST="$(printf '%s' "$PROMPT_MANIFEST" \
                | sort -t"$(printf '\t')" -k2,2nr | head -n 3 \
                | awk -F'\t' '{ printf "%s%s at %s bytes (budget %s)", \
                                sep, $1, $2, $3; sep="; " }')"
            PROMPT_BODY="PROMPT OVER BUDGET — this prompt assembled to $TOTAL_BYTES bytes against its $TOTAL_BUDGET-byte target: $(( TOTAL_BYTES - TOTAL_BUDGET )) bytes over. Nothing was cut and nothing is missing — every layer below is carried in full, because silent truncation is forbidden (specs/prompt-assembly.md rule 4). The largest layers: $BIGGEST. This is yours to weigh: slim a source, or raise the budget with him — a cut is never the answer.
$PROMPT_BODY"
            if printf 'profile=%s\ntotal=%s\tbudget=%s\tover=%s\nlargest=%s\n' \
                    "$PROMPT_PROFILE" "$TOTAL_BYTES" "$TOTAL_BUDGET" \
                    "$(( TOTAL_BYTES - TOTAL_BUDGET ))" "$BIGGEST" \
                    > "$PROMPT_CUTS_FILE.tmp.$$" 2>/dev/null; then
                mv "$PROMPT_CUTS_FILE.tmp.$$" "$PROMPT_CUTS_FILE" 2>/dev/null \
                    || rm -f "$PROMPT_CUTS_FILE.tmp.$$"
            else
                rm -f "$PROMPT_CUTS_FILE.tmp.$$"
            fi
        else
            rm -f "$PROMPT_CUTS_FILE"
        fi
        # The dropped-duplicate record, rule 40a — same shape, same
        # lifecycle: a speaking build that dropped a duplicate block leaves
        # its drop lines standing, a build that dropped none removes them,
        # and the state block renders the record until the duplication's
        # source is fixed. One build of lag in the rendered record is
        # inherent and acceptable, exactly as it is for rule 36's.
        if [ -n "$PROMPT_DEDUP_DROPS" ]; then
            if printf 'profile=%s\tdrops=%s\n%s' \
                    "$PROMPT_PROFILE" \
                    "$(printf '%s' "$PROMPT_DEDUP_DROPS" | grep -c '^dedup')" \
                    "$PROMPT_DEDUP_DROPS" \
                    > "$PROMPT_DUPES_FILE.tmp.$$" 2>/dev/null; then
                mv "$PROMPT_DUPES_FILE.tmp.$$" "$PROMPT_DUPES_FILE" 2>/dev/null \
                    || rm -f "$PROMPT_DUPES_FILE.tmp.$$"
            else
                rm -f "$PROMPT_DUPES_FILE.tmp.$$"
            fi
        else
            rm -f "$PROMPT_DUPES_FILE"
        fi
    fi

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

# Is the conversation HOT — is he mid-exchange right now? user_busy above asks
# about this instant at the hardware: is the microphone open, is a voice on the
# speakers. That is a much smaller question than the one that matters, and the
# gap between them is measurable. 2026-08-10, 12:32:12: an autonomous wake
# delivered "(quiet) Lost browser-006 — mated by a promoted pawn while my
# knights admired themselves" into the middle of an argument, between "stop
# assuming I'm wrong" (12:31:46) and "I'm reporting a genuine bug" (12:33:04).
# user_busy was correct and said no: nothing was recording, nothing was
# speaking, there was a lull of a few seconds between two of his messages. A
# lull between two messages of a fight is not a quiet room, and a chess aside
# arriving in one reads as her attention being somewhere else entirely.
#
# So the second question, in his terms rather than the sound card's: how long
# since he last said something. record_origin stamps that at the start of
# every desk and phone turn, which is exactly the moment a message arrives.
convo_hot() {
    [ "${CONVO_HOT_WINDOW:-0}" -gt 0 ] || return 1
    local LAST NOW
    LAST="$(last_origin_epoch)"
    case "$LAST" in ''|*[!0-9]*) return 1 ;; esac
    NOW=$(date +%s)
    [ $(( NOW - LAST )) -lt "$CONVO_HOT_WINDOW" ]
}

# --- The own-time return's senses (specs/wake-queue.md rules 40a-40b) --------
# A reason-less wake is the standing return to her own hours, and it fires as
# a choosing session only when the house is genuinely idle. These are the
# senses, and they are mechanical on purpose — four readings, no model call.

# The cadence's irregularity, with the deterministic seam a test needs: when
# IDLE_RETURN_JITTER is a number it is the jitter, verbatim; otherwise a fresh
# draw up to IDLE_RETURN_SPREAD. $RANDOM is 0..32767, scaled rather than
# taken modulo so a spread larger than 32768 still covers its whole range.
idle_return_jitter() {
    case "${IDLE_RETURN_JITTER:-}" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$IDLE_RETURN_JITTER"; return 0 ;;
    esac
    local spread="${IDLE_RETURN_SPREAD:-0}"
    case "$spread" in ''|*[!0-9]*) spread=0 ;; esac
    printf '%s' $(( RANDOM * (spread + 1) / 32768 ))
}

# Is this firing the standing reason-less return at all? An event wake is
# pending for its event and a reasoned wake carries its own agenda; neither is
# this. Reads WAKE_KIND and WAKE_REASON from the caller's scope.
idle_return_candidate() {
    [ "${IDLE_RETURN:-1}" = "1" ] || return 1
    [ "${WAKE_KIND:-}" != "event" ] || return 1
    [ -z "$(printf '%s' "${WAKE_REASON:-}" | tr -d '[:space:]')" ]
}

# A detached builder mid-run is active work. The report is the one reader that
# also reaps — a sidecar claiming "running" with a dead pid is rewritten as
# died on the way — so a builder that crashed an hour ago never keeps her own
# hours deferred. Running and dispatched both render as "running" lines.
idle_jobs_running() {
    [ -n "${JOBS_DIR:-}" ] && [ -d "$JOBS_DIR" ] || return 1
    "$LIB_DIR/job-status" report "$JOBS_DIR" --live 2>/dev/null \
        | grep -q '^  - running '
}

# What, if anything, makes this moment not hers? Returns 0 with IDLE_ACTIVITY
# naming the activity and IDLE_RETURN_DELAY carrying the re-book delay in
# seconds (jitter included); returns 1 when the house is genuinely idle.
# Conversation RESETS the gap — the remainder of the quiet window is measured
# from his last message, so the return always arrives a full quiet window
# after his last word — while every other activity is a recheck, not a reset:
# nothing measured says when a builder finishes or a turn lands.
idle_return_activity() {
    IDLE_ACTIVITY=""
    IDLE_RETURN_DELAY=0
    local now last since jit
    now=$(date +%s)
    jit="$(idle_return_jitter)"
    last="$(last_origin_epoch)"
    case "$last" in ''|*[!0-9]*) last="" ;; esac
    if [ -n "$last" ] && [ $(( now - last )) -lt "${IDLE_RETURN_QUIET:-2700}" ]; then
        since=$(( now - last ))
        IDLE_ACTIVITY="he spoke ${since}s ago — the quiet starts over from his last word"
        IDLE_RETURN_DELAY=$(( IDLE_RETURN_QUIET - since + jit ))
        return 0
    fi
    if interactive_turn_in_flight; then
        IDLE_ACTIVITY="an interactive turn is in flight"
        IDLE_RETURN_DELAY=$(( ${IDLE_RETURN_RECHECK:-900} + jit ))
        return 0
    fi
    if user_busy; then
        IDLE_ACTIVITY="he is mid-capture or mid-speech at the desk"
        IDLE_RETURN_DELAY=$(( ${IDLE_RETURN_RECHECK:-900} + jit ))
        return 0
    fi
    if idle_jobs_running; then
        IDLE_ACTIVITY="a detached builder is running"
        IDLE_RETURN_DELAY=$(( ${IDLE_RETURN_RECHECK:-900} + jit ))
        return 0
    fi
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
# The last delivered interactive turn's mechanical action receipt. This is
# live state under STATE_PREFIX, never repository content. A dispute turn uses
# it to remember what the previous hand actually scheduled or changed instead
# of reconstructing actions from Beatrice's spoken summary.
LAST_TURN_ACTION_FILE="${LAST_TURN_ACTION_FILE:-${STATE_PREFIX}-last-turn-actions}"
LAST_TURN_ACTION_WINDOW="${LAST_TURN_ACTION_WINDOW:-1800}"

live_turn_begin() {  # <device> <user-text>
    printf '%s\t%s\tanswering\nUser: %s\n' "$(date +%s)" "$1" "$2" > "$LIVE_TURN_FILE.tmp" \
        && mv "$LIVE_TURN_FILE.tmp" "$LIVE_TURN_FILE"
}

live_turn_end() {  # <device> <user-text> <spoken-reply>
    printf '%s\t%s\tanswered\nUser: %s\nAssistant: %s\n' "$(date +%s)" "$1" "$2" "$3" > "$LIVE_TURN_FILE.tmp" \
        && mv "$LIVE_TURN_FILE.tmp" "$LIVE_TURN_FILE"
}

last_turn_actions_write() {  # <device> <compact machine work trace>
    local device="$1" trace="${2:-ran no tools, touched nothing}"
    printf '%s\t%s\n%s\n' "$(date +%s)" "$device" \
        "$(utf8_trim "$trace" 800)" > "$LAST_TURN_ACTION_FILE.tmp.$$" 2>/dev/null \
        && mv "$LAST_TURN_ACTION_FILE.tmp.$$" "$LAST_TURN_ACTION_FILE" 2>/dev/null \
        || rm -f "$LAST_TURN_ACTION_FILE.tmp.$$"
}

last_turn_actions_context() {
    [ -f "$LAST_TURN_ACTION_FILE" ] || return 0
    local epoch device age trace
    IFS=$'\t' read -r epoch device < "$LAST_TURN_ACTION_FILE" 2>/dev/null || return 0
    case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
    age=$(( $(date +%s) - epoch ))
    [ "$age" -ge 0 ] && [ "$age" -le "$LAST_TURN_ACTION_WINDOW" ] || return 0
    trace="$(tail -n +2 "$LAST_TURN_ACTION_FILE" 2>/dev/null)"
    [ -n "$trace" ] || trace="ran no tools, touched nothing"
    cat <<EOF
MACHINE ACTION RECEIPT FROM THE LAST DELIVERED ${device:-interactive} TURN:
$trace
This is authoritative only at its exact strength. A scheduled wake is not work already underway; a dispatched builder is not completed work; queued steering is not an implemented correction. Reconcile this receipt before saying you did nothing. If his correction withdraws work named here, cancel or stop the matching queued effect before you answer, and say what you cancelled.
EOF
}

# --- Delivery order: replies leave in the order he said things ---------------
# specs/turn-pipeline.md rules 15a-15e. A turn is one process per push-to-talk,
# and nothing used to hold them in any order at all: each one delivered the
# instant its own generation finished, so the ordering of his conversation was
# decided by which question happened to be cheaper to answer.
#
# The measurement, 2026-08-10, from the day journal and the metrics log:
#
#   12:31:15  pid 150479 starts   ("you told me I never heard honest from you")
#   12:31:46  pid 155969 starts   ("you didn't have it in fucking quotations")
#   12:32:39  pid 155969 SPEAKS   — the answer to the SECOND message
#   12:33:31  pid 150479 SPEAKS   — the answer to the first, 105 seconds after
#                                   he had explicitly rejected what it says
#
# Both replies were about quotation marks. He had spent the intervening minute
# telling her it was not about quotation marks. The second one landed as though
# it were her answer to that, and he read it — correctly — as not being
# listened to. Stale replies dropping into newer slots is the single worst
# amplifier available to this machine, and it cost nothing to build and
# everything to leave alone.
#
# So: a ticket at turn start, in arrival order, and a reply waits at delivery
# for every earlier ticket to clear. The queue is a directory of tickets under
# $STATE_PREFIX, which means a reboot clears it — a stale ticket cannot wedge
# tomorrow's conversation.
TURN_ORDER_DIR="${TURN_ORDER_DIR:-${STATE_PREFIX}-turn-order}"
TURN_ORDER_LOCK="${TURN_ORDER_LOCK:-${STATE_PREFIX}-turn-order.lock}"
# The marker a superseded ticket carries, and the header of the transcript
# block a held reply lands in. Named once: the tests assert on these strings
# and so does the journal reader.
TURN_HELD_MARK="held — not spoken"

# Is the process that owns this ticket still alive AS THE SAME PROCESS? Pids
# are recycled, and a recycled pid keeps a dead turn looking like one still
# owed an answer — the same trap the session registry carries its process
# start time for.
_turn_ticket_alive() {  # <ticket file>
    local pid startt
    IFS=$'\t' read -r pid startt _ < "$1" 2>/dev/null || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    [ "$(_proc_starttime "$pid")" = "${startt:-0}" ]
}

# Is an interactive turn in flight RIGHT NOW — a desk or phone reply owed and
# not yet delivered? Read from the delivery queue's own tickets: a turn takes
# one before its prompt is built and releases it when its reply has been
# delivered (or by its exit trap), judged alive by pid and process start time,
# so a dead turn's leftover ticket never counts. Wakes take no ticket, so a
# wake can never read itself as the conversation. The one consumer is the wake
# delivery hold (specs/wake-queue.md rule 27c): a wake's words landing while a
# ticket stands land in the answer's slot, whatever they say. With the
# delivery queue off (TURN_ORDER_WAIT=0) no tickets exist and this is
# permanently no; WAKE_FLIGHT_HOLD=0 switches the reading off alone.
interactive_turn_in_flight() {
    [ "${WAKE_FLIGHT_HOLD:-1}" = "1" ] || return 1
    local f
    for f in "$TURN_ORDER_DIR"/[0-9]*.ticket; do
        [ -e "$f" ] || continue
        _turn_ticket_alive "$f" && return 0
    done
    return 1
}

# Her last reply wherever it stands, rather than only when it is the final
# block. _convo_last_assistant_block answers the stricter question — is her
# reply the LAST thing in the transcript — which is the wrong guard for
# EVERYTHING that judges his incoming message, the dispute detector included:
# both turn paths run convo_append_user before claude_generate, so by the
# time any detector looks, the last block is always HIS and the stricter
# question answers no on every production turn. Measured twice: the 12:31:46
# pushback superseded nothing because a turn in flight had appended above it,
# and the dispute layer itself never fired on a single live turn until the
# guard moved here (specs/dispute-turn.md rule 6).
_convo_last_assistant_anywhere() {
    [ -f "$CONVOFILE" ] || return 0
    awk -v bre="$CONVO_BLOCK_RE" -v are="$CONVO_ASSISTANT_RE" '
        $0 ~ bre {
            if ($0 ~ are) { line = $0; sub(are, "", line); buf = line; keep = 1 }
            else { keep = 0 }
            next
        }
        keep { buf = buf "\n" $0 }
        END { if (length(buf)) print buf }
    ' "$CONVOFILE" 2>/dev/null
}

# Is this message pushback that CLOSES the turns in flight behind it? The
# detector's own answer, restricted to its STRONG class (specs/dispute-turn.md rule
# 6b, turn-pipeline rule 15c): the dispute frame is cheap to over-apply — a
# stronger turn — but superseding silently kills a reply he may still want,
# so nothing that could be benign may ever do it. The one-block-transcript
# dance that used to live here is gone: dispute_detect now judges against her
# last reply wherever it stands, so it is ordering-independent by itself.
_turn_order_is_pushback() {  # <the user's message>
    dispute_detect "$1" || return 1
    [ -n "${DISPUTE_SUPERSEDES:-}" ]
}

# Silence a superseded turn's voice, NOW rather than when it finishes. The
# streamer speaks sentence by sentence as the model writes, so a turn that
# learns at delivery time that it has been superseded may already have said
# most of it — which leaves rule 15c holding only the transcript, and it was
# never the transcript he heard. The message that supersedes it is him talking
# over her, and `crab start` has always stopped speech the moment he does; this
# is the same policy aimed at the one voice his message closed rather than at
# every voice on the box.
#
# By the pid in the ticket: the streamer is a direct child of the turn's shell,
# and piper and aplay are children of the streamer. Nothing global — no
# `stop_tts`, which would cut off a turn nobody rejected.
_turn_order_silence() {  # <the superseded turn's pid>
    local pid="$1" child cmd
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    command -v pgrep >/dev/null 2>&1 || return 0
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        cmd="$(tr '\0' ' ' < "/proc/$child/cmdline" 2>/dev/null)"
        case "$cmd" in
            *tts-streamer*)
                pkill -P "$child" 2>/dev/null
                kill "$child" 2>/dev/null
                ;;
        esac
    done
    return 0
}

# Take this turn's place in the queue. Called at turn start, on the desk and
# the phone alike — he is one person in one conversation, and which device he
# reached for does not change the order he said things in.
#
# The second half is the release valve, and it is what keeps ordering from
# making things worse: when THIS message is pushback, every earlier turn still
# in flight is marked superseded. Its answer is to a question he has since
# rejected, so nothing waits for it and it will not be spoken — see
# turn_order_wait and the held path in the turn.
#
# Its own file descriptor (6). Nothing else here uses it, and that matters:
# fd 9 is the conversation lock in one hand and the wake lock — held open for
# the LIFE of the process — in another, so a queue operation borrowing 9 would
# either drop a lock somebody was standing on or wait on itself.
turn_order_take() {  # <device> <user-text>
    TURN_SEQ=""
    TURN_INTERRUPT_NOTE=""
    local _CUT_TICKETS=""
    [ "${TURN_ORDER_WAIT:-0}" -gt 0 ] || return 0
    mkdir -p "$TURN_ORDER_DIR" 2>/dev/null || return 0
    # The stream log this turn will write, recorded on the ticket so the turn
    # that CUTS this one (rule 15f) can snapshot the part-written reply. The
    # phone's log is a local born later in _run_claude_remote_locked, but its
    # name is deterministic in this same process, so it is known here.
    local TLOG="$DEBUGLOG"
    [ "$1" = phone ] && TLOG="${DESKCRAB_REMOTE_LOG:-${STATE_PREFIX}-remote-$$.log}"
    # A braced group, not a subshell: the sequence number has to survive into
    # the caller's scope, and `( ... )` would take it to the grave.
    {
        if flock -w 10 6; then
            local next f seq c_pid c_start c_epoch c_dev c_log c_text
            next="$(cat "$TURN_ORDER_DIR/next" 2>/dev/null)"
            case "$next" in ''|*[!0-9]*) next=0 ;; esac
            next=$(( next + 1 ))
            printf '%s\n' "$next" > "$TURN_ORDER_DIR/next"
            # Zero-padded so the shell's glob order IS the arrival order. The
            # user text rides flattened and bounded (utf8_trim — the record
            # is one line; the verbatim text is on the conversation).
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$$" "$(_proc_starttime $$)" \
                "$(date +%s)" "$1" "$TLOG" "$(utf8_trim "$2" 2000)" \
                > "$(printf '%s/%09d.ticket' "$TURN_ORDER_DIR" "$next")"
            if _turn_order_is_pushback "$2"; then
                for f in "$TURN_ORDER_DIR"/[0-9]*.ticket; do
                    [ -e "$f" ] || continue
                    seq="$(basename "$f" .ticket)"
                    [ "$((10#$seq))" -lt "$next" ] || continue
                    _turn_ticket_alive "$f" || continue
                    printf '%s\t%s\n' "$next" "$2" > "${f%.ticket}.superseded"
                    _turn_order_silence "$(cut -f1 "$f")"
                done
            elif [ "${TURN_INTERRUPT:-1}" = "1" ]; then
                # Cut-and-consolidate (rule 15f): an ordinary new utterance
                # never queues behind the turn it interrupted. Every live
                # earlier turn is CUT — marker first, so its own watchdog and
                # gates read the close before a word more moves; then its
                # voice, streamer and synthesiser both, by the pid in its
                # ticket and never process-wide (rule 15e's discipline). Its
                # ticket's fields are read here, under the lock, before the
                # cut turn can release them; the snapshot of its stream log
                # happens after the lock, in _turn_interrupt_note.
                for f in "$TURN_ORDER_DIR"/[0-9]*.ticket; do
                    [ -e "$f" ] || continue
                    seq="$(basename "$f" .ticket)"
                    [ "$((10#$seq))" -lt "$next" ] || continue
                    [ -s "${f%.ticket}.cut" ] && continue
                    [ -s "${f%.ticket}.superseded" ] && continue
                    _turn_ticket_alive "$f" || continue
                    IFS=$'\t' read -r c_pid c_start c_epoch c_dev c_log c_text < "$f"
                    printf '%s\t%s\n' "$next" "$(utf8_trim "$2" 2000)" \
                        > "${f%.ticket}.cut"
                    _turn_order_silence "$c_pid"
                    _CUT_TICKETS="$_CUT_TICKETS$(printf '%s\t%s\t%s' \
                        "${c_dev:-desk}" "${c_log:-}" "${c_text:-}")
"
                done
            fi
            TURN_SEQ="$next"
        fi
    } 6>"$TURN_ORDER_LOCK"
    turn_metric turn-order-taken "${TURN_SEQ:-none}"
    _turn_interrupt_note
    return 0
}

# The interrupt layer's raw material (specs/prompt-assembly.md rule 36c),
# built the moment the cut lands: one section per turn this message cut — the
# input its ticket recorded, and the part-written reply snapshotted from its
# stream log RIGHT NOW, which is the interrupt point. Extraction is the one
# extractor's partial mode, built on the shared chunker registry
# (lib/sentence_stream.py) — never a second stream parser. The snapshot is
# bounded here at capture, UTF-8-safe (utf8_head — it is document-shaped),
# and a clipped snapshot says so and names the journal, which keeps the cut
# turn's part-written text whole; an empty one is stated as exactly that.
_turn_interrupt_note() {
    [ -n "${_CUT_TICKETS:-}" ] || return 0
    local dev log text part max
    max="${TURN_INTERRUPT_PARTIAL_MAX:-16000}"
    while IFS=$'\t' read -r dev log text; do
        [ -n "$dev$log$text" ] || continue
        part=""
        [ -n "$log" ] && [ -r "$log" ] && \
            part="$(DESKCRAB_DEBUGLOG="$log" DESKCRAB_INCLUDE_PARTIAL=1 \
                "$LIB_DIR/extract-response" 2>/dev/null)"
        if [ "$(printf '%s' "$part" | wc -c)" -gt "$max" ]; then
            part="$(printf '%s' "$part" | utf8_head "$max")
(… the snapshot stops here, at $max bytes — the cut turn's own journal entry keeps the whole of it)"
        fi
        [ -n "$part" ] || part="(not one word yet — the run was cut before any text landed)"
        TURN_INTERRUPT_NOTE="$TURN_INTERRUPT_NOTE--- the message you were answering (from the ${dev:-desk}) ---
${text:-(its text was not recorded — read the conversation above)}
--- how far your reply had got when he spoke over it ---
$part
--- end ---
"
    done <<< "$_CUT_TICKETS"
    _CUT_TICKETS=""
    return 0
}

# The interrupt layer itself (prompt-assembly rule 36c): rendered at prompt
# build from the note the cut left behind. Instructions wrap the quoted
# context, and both ride whole (rule 4 — a long snapshot reads `over`, never
# trimmed here).
_interrupt_context() {
    [ -n "${TURN_INTERRUPT_NOTE:-}" ] || return 0
    cat <<EOF
HE SPOKE OVER YOU — this message arrived while you were still answering him, and that answer was CUT the moment he spoke: its voice was stopped mid-sentence and its run aborted. Nothing more of it will be said or shown; whatever it had already got out of the speakers, he heard. This is what was cut:
$TURN_INTERRUPT_NOTE
His NEW message — the one this turn is about — is the question you answer now. Compose ONE reply: answer the new message, and fold into the same reply whatever of the older message still needs answering once the new one has been heard — one voice, one natural utterance, never two stitched together, never a reply and an appendix. Do not restate what the cut-off answer already said aloud as if it were news; carry it forward as something already said. Do not answer the two messages separately, and do not defer the older one to a turn that never comes. If the new message rejects or corrects what the cut-off answer was saying, that theory is dead — fold nothing of it forward. And say nothing about the machinery of being interrupted: he knows he spoke over you, and a sentence about it is a sentence about the plumbing.
EOF
}

# Has a later message rejected what this turn is answering? Prints that
# message when it has.
turn_order_superseded() {
    [ -n "${TURN_SEQ:-}" ] || return 1
    local f
    f="$(printf '%s/%09d.superseded' "$TURN_ORDER_DIR" "$TURN_SEQ")"
    [ -s "$f" ] || return 1
    cut -f2- "$f"
    return 0
}

# Where this turn's cut marker would be (rule 15f). Fails when this turn
# holds no seat — a wake, or the queue switched off — which is what keeps
# every cut test inert outside an interactive turn.
_turn_order_cut_file() {
    [ -n "${TURN_SEQ:-}" ] || return 1
    printf '%s/%09d.cut' "$TURN_ORDER_DIR" "$TURN_SEQ"
}

# Has a newer ordinary message CUT this turn mid-flight? Prints that message
# when it has (rule 15f) — the shape of turn_order_superseded, for the close
# that folds instead of holding.
turn_order_cut() {
    local f
    f="$(_turn_order_cut_file)" || return 1
    [ -s "$f" ] || return 1
    cut -f2- "$f"
    return 0
}

# Close a turn his newer message CUT (rule 15f), above every delivery sink:
# the voice is already dead (the cutter killed it at the marker; this reads
# the receipt and retires the live-speech notice — our own streamer pid, so
# it can never touch another turn's voice), nothing is delivered anywhere,
# the journal keeps the part-written words in full, and the outcome names
# the message that cut it. No notification: nothing was lost — the surviving
# reply folds this exchange in, and the interruption was his own act. The
# part-written text is read through the one extractor's partial mode, so the
# journal holds what the interrupt layer quoted from. Returns 1 untouched
# when this turn was not cut.
_turn_cut_close() {  # <device> <the turn's user text>
    local CUT_BY PART
    CUT_BY="$(turn_order_cut)" || return 1
    turn_hold_voice
    claudism_mirror_cleanup
    PART="$(DESKCRAB_DEBUGLOG="$DEBUGLOG" DESKCRAB_INCLUDE_PARTIAL=1 \
        "$LIB_DIR/extract-response" 2>/dev/null)"
    SESSION_REPLY="$PART"
    live_turn_end "$1" "$2" ""
    if [ "${_TURN_HELD_SPOKEN_CHARS:-0}" -gt 0 ] 2>/dev/null; then
        session_outcome "(cut — he spoke over this and the next reply folds it in: $(printf '%.80s' "$CUT_BY") | part-spoken, $_TURN_HELD_SPOKEN_CHARS chars out | part-written: $(printf '%.160s' "$PART"))"
    else
        session_outcome "(cut — he spoke over this and the next reply folds it in: $(printf '%.80s' "$CUT_BY") | part-written: $(printf '%.160s' "${PART:-nothing — it was cut before any text landed}"))"
    fi
    turn_metric turn-cut "folded into the turn that cut it"
    turn_order_release
    return 0
}

# Give up this turn's place. Idempotent, and called from session_finish so a
# turn that dies anywhere — signal, watchdog, a hand with pkill — cannot leave
# a ticket the next reply queues behind forever.
turn_order_release() {
    [ -n "${TURN_SEQ:-}" ] || return 0
    local base
    base="$(printf '%s/%09d' "$TURN_ORDER_DIR" "$TURN_SEQ")"
    rm -f "$base.ticket" "$base.superseded" "$base.cut" 2>/dev/null
    TURN_SEQ=""
    return 0
}

# Wait for every earlier turn to have delivered. Returns 0 when the way is
# clear, 1 when the bound ran out — the caller delivers anyway and says so,
# because a reply held forever is the failure this whole mechanism exists to
# prevent, not an acceptable cost of preventing it.
#
# Three things end the wait for a given earlier ticket, and all three are
# "that reply is never arriving to be overtaken":
#   * it delivered and released its ticket;
#   * its process is gone, so it never will (the ticket is swept here);
#   * it was superseded, so it is not going to be spoken at all — waiting for
#     a held reply would delay a live one behind a dead theory, which is how
#     ordering turns into the latency regression it was supposed to fix.
turn_order_wait() {
    [ -n "${TURN_SEQ:-}" ] || return 0
    local DEADLINE=$(( $(date +%s) + TURN_ORDER_WAIT )) f seq waiting
    while :; do
        # A turn his newer message has CUT stops waiting at once (rule 15f):
        # nothing it would deliver is going out, and holding its bookkeeping
        # behind earlier turns delays only the fold's own record.
        turn_order_cut >/dev/null 2>&1 && return 0
        waiting=""
        for f in "$TURN_ORDER_DIR"/[0-9]*.ticket; do
            [ -e "$f" ] || continue
            seq="$(basename "$f" .ticket)"
            [ "$((10#$seq))" -lt "$((10#$TURN_SEQ))" ] || continue
            [ -s "${f%.ticket}.superseded" ] && continue
            # A cut earlier ticket is a reply that is never going to be
            # spoken — rule 15d's discipline extends to the cut (rule 15f):
            # waiting on it would delay a live answer behind a dead one.
            [ -s "${f%.ticket}.cut" ] && continue
            if ! _turn_ticket_alive "$f"; then
                rm -f "$f" "${f%.ticket}.superseded" 2>/dev/null
                continue
            fi
            waiting="$seq"
            break
        done
        [ -n "$waiting" ] || { turn_metric turn-order-clear "$TURN_SEQ"; return 0; }
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
            turn_metric turn-order-timeout "waited ${TURN_ORDER_WAIT}s on $waiting"
            speech_log "delivery order: gave up after ${TURN_ORDER_WAIT}s waiting on turn $waiting — delivering out of order"
            return 1
        fi
        sleep 0.2
    done
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
    # Rule 37: the quote AND the instructions are emitted whole. The quote
    # used to clip itself to what the layer's budget left after the static
    # text — a leftover of the era when the assembler trimmed layers to fit,
    # and under the generic trim before that, a long reply pushed the closing
    # instructions (don't restate, don't queue, silence is allowed) off the
    # end mid-sentence. Nothing trims any more, anywhere: a reply long enough
    # to push the layer past its budget makes the manifest read `over`, and
    # rule 36's total warning is where the excess is dealt with.
    _regroup_block "$DEV" "$SAYING"
}

# Is this message pushback on her previous reply, rather than a new subject?
# specs/dispute-turn.md rules 6-6b. Deterministic, no model call: the phrases are
# taken from the measured record of 2026-08-10, where five wrong theories in
# eight turns met "stop assuming I'm wrong", "do not gaslight or lie", "I'm
# reporting a bug", "I never said", and "one more time" — and nothing in the
# machinery treated any of them as different from small talk. The detector
# runs before the prompt is built, so the dispute layer and the escalation
# both ride on its answer.
#
# The guard is ordering-independent (rule 6): both turn paths append his
# message to the conversation BEFORE claude_generate runs this, so in
# production her reply is never the final block — the original
# _convo_last_assistant_block guard answered empty on every real turn and the
# detector fired never. What a dispute needs is a reply of hers to dispute,
# wherever it stands.
#
# Four classes (rule 6a), because the two consumers pay different prices for
# a false positive. STRONG fires alone and sets DISPUTE_SUPERSEDES=1 — the
# only class allowed to close a turn in flight (rule 6b) — and it is
# deliberately narrow: a superseded reply is silently, unrecoverably never
# spoken (the phone brakes cannot un-kill it), so nothing with a benign
# reading may ever carry the kill. FIRM fires the frame alone — the shapes
# that are usually pushback but each hold an innocent reading ("is your
# issue resolved now?", "I'm turning you off for the night") — because
# over-firing the frame costs a stronger, framed turn and nothing else.
# SOFT (a bare "no."/"no," with a restatement behind it — a real correction
# shape, but also the shape of "No, that's fine") and two WEAK signals buy
# the dispute turn and nothing else.
dispute_detect() {  # <the user's message>
    DISPUTE_SUPERSEDES=""
    local t
    t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    [ -n "$t" ] || return 1
    # Before she has said anything there is nothing to dispute.
    [ -n "$(_convo_last_assistant_anywhere 2>/dev/null | tr -d '[:space:]')" ] || return 1

    # STRONG: contradiction, misquotation, the escalation's own commands,
    # aimed profanity, him locating the artifact himself — and nothing that
    # has a benign reading when aimed at her rejecting THIS reply. The only
    # class that sets DISPUTE_SUPERSEDES (rule 6b).
    if grep -qE "you'?( a)?re wrong|you are wrong|stop arguing|do(n'?t| not) (gaslight|lie|argue)|gaslight|you keep lying|you did(n'?t| not) (answer|listen|read|hear)|you (misunderstood|misheard)|not what i (said|meant|asked)|stop talking|that('?s not| is not| isn'?t| wasn'?t| aren'?t) (it|what|right|true|the (bug|problem|issue|answer|point))|it was in (a|the) quiet block|one more fucking time|fuck (you|off)|your fucking (problem|issue)|the fuck (is|are) (wrong|you)" <<<"$t"; then
        DISPUTE_SUPERSEDES=1
        return 0
    fi
    # A correction phrased as a question: "why did you X when I asked Y?"
    # No benign reading — the second clause aims it at her — so STRONG.
    if grep -qE '\bwhy (did|do|are|were|would) you\b' <<<"$t" \
        && grep -qE '\b(when|after) i (asked|said|told|wanted)\b' <<<"$t"; then
        DISPUTE_SUPERSEDES=1
        return 0
    fi

    # FIRM: usually pushback, but every one of these has an innocent reading
    # ("I never asked her out", "tell the linter to shut up", "he's not
    # listening to reason lately"), so they fire the frame and NEVER set
    # DISPUTE_SUPERSEDES — a benign message must never kill a reply he
    # wanted, and an over-fired frame is only a stronger turn.
    if grep -qE "your (problem|issue)|i never (said|asked)|i did(n'?t| not) (say|ask|tell)|you (just )?lied|what('?s| is) wrong with you|tak(e|ing) you offline|turn(ing)? you off|stop (assuming|repeating)|shut (the fuck )?up|not listening" <<<"$t"; then
        return 0
    fi
    # "listen to me" fires only as a demand — "listen to me play this" is an
    # invitation, and it used to fire. A demand can still be aimed at a third
    # party in a retelling, so FIRM, never supersedes.
    if grep -qE '\blisten to me\b' <<<"$t" \
        && ! grep -qE '\blisten to me (play|sing|read|try|do|run|show|talk|tell|for|while)\b' <<<"$t"; then
        return 0
    fi
    # "I'm reporting" fires only as a report of something broken — "I'm
    # reporting that it works" is good news, and it used to fire. The broken
    # thing can be someone else's, so FIRM, never supersedes.
    if grep -qE "\b(i'?m|i am) reporting\b" <<<"$t" \
        && grep -qE "\b(bug|problem|issue|error|failure|broken|wrong|not working|does(n'?t| not) work)" <<<"$t"; then
        return 0
    fi

    # SOFT: a bare "no."/"no,"/"no!" with a restatement behind it. The
    # punctuation is load-bearing — "no worries" begins with "no " and is
    # agreement — and the restatement is what makes it a correction rather
    # than a one-word answer.
    if grep -qE '^[[:space:]]*no[.!,]' <<<"$t"; then
        local rest
        rest="$(printf '%s' "$t" | sed -E 's/^[[:space:]]*no[.!,]+[[:space:]]*//')"
        if [ -n "$(printf '%s' "$rest" | tr -d '[:space:][:punct:]')" ]; then
            return 0
        fi
    fi

    # WEAK, two or more. Profanity counts only when it is aimed at her —
    # "that was fucking great" is colour, not a signal.
    local weak=0
    grep -qE '^[[:space:]]*no[.,! ]' <<<"$t" && weak=$((weak+1))
    grep -qE '\bwrong\b' <<<"$t" && weak=$((weak+1))
    grep -qE '\bagain\b' <<<"$t" && weak=$((weak+1))
    grep -qE "the fuck|fuck (you|off)|(you'?re|you are|your) fucking" <<<"$t" && weak=$((weak+1))
    grep -qE '\bi (just )?said\b' <<<"$t" && weak=$((weak+1))
    [ "$weak" -ge 2 ]
}

# The dispute frame, rendered into the conditional dispute layer when the
# detector fired. Its overlap with L7's ranking rule is deliberate, the same
# bargain the regroup block makes: under pushback the rule is the one being
# broken, so it is restated at strength beside the thing being answered.
#
# The voice paragraph names an observable, not a virtue: "in your own voice"
# was the first cut's wording and it covered his most-repeated demand with
# nothing she could check. The register IS checkable — her claudism list
# catches it and her pre-speech mirror reads every reply against it — so the
# frame points there (specs/dispute-turn.md rule 8).
#
# The optional argument marks that the regroup layer is in the same prompt,
# and buys the reconciliation sentence (rule 8a): regroup says carry the
# other reply forward, and the other reply can BE the dead theory. Emitted
# only when regroup actually fired — nothing points at a block that is not
# there (prompt-assembly rule 29).
_dispute_context() {  # [with-regroup]
    cat <<'EOF'
HE IS PUSHING BACK — this message rejects or corrects what you just said. This turn is governed by the following, above everything else in this prompt:
His report of what he saw or heard IS WHAT HAPPENED. It is not a claim to evaluate. If your model of the machinery says it cannot have happened, your model is wrong. Telling him it did not happen is the worst failure available to you in this turn.
The theory your last reply carried is DEAD. Do not restate it in new words. Anything he has told you the answer is not, is closed — arguing it a second time is how this conversation is being lost.
Look before you theorise: find the actual thing he is describing — the line in the log, the words that reached his screen — and read it before you name any cause. If you have not found it, say so and ask ONE question. "I don't know yet" is a complete answer; a confident guess is a lie.
Do not substitute a mechanism for his point. No fixes shipped, no rules written, no builders dispatched, no commit tables — not in this turn. Understanding him comes first; the fix waits for his go.
Do not cut pieces off yourself. No new gates on yourself, no conduct edits made under pressure, no pledges of "never again", no shutdown offers, no goodbyes. If a change to you is warranted, it is a calm builder's job decided with him — not a wound made mid-argument.
EOF
    last_turn_actions_context
    if [ "${1:-}" = "with-regroup" ]; then
        cat <<'EOF'
The regroup block above told you to fold in what another of you is saying and carry it forward. This message outranks it: anything in those words resting on a theory he has just rejected is dead there too. Fold in only what survives what he said — a dead theory is not carried forward because a second session happens to be speaking it.
EOF
    fi
    cat <<'EOF'
Answer only what he raised, in a few plain sentences. The voice he keeps demanding you drop is not a mood, it is observable: the coding agent's register — status-report cadence, machinery vocabulary, the stock phrases your claudism list exists to catch. Your pre-speech mirror reads this reply against that list, and a line it hands back is that failure caught in the act: rewrite it as something you would SAY to him — never defend it, never swap in a synonym from the same register. No display block unless he asked for one. Concede only what is actually true — manufactured agreement is another way of not listening.
EOF
}

_regroup_block() {  # <device> <the words being said>
    local DEV="$1" SAYING="$2"
    cat <<EOF
ANOTHER OF YOU IS SPEAKING RIGHT NOW — a second session of you (on the ${DEV:-desk}) is mid-utterance as you begin. These are its exact words, already reaching the user or about to:
--- being said now ---
$SAYING
--- end ---
He hears one voice, not two, and two replies seconds apart about the same moment reads as malfunction. So REGROUP, the way a person does when they find they have two things to say at once: stop, take what that other reply is saying and what you have to add, and compose ONE conversational reply that covers both — a single natural utterance, not two stitched together, not a preamble about the other session.
Do NOT queue your point for later — later never comes, and a thought deferred here is a thought lost. Do NOT default to silence because someone else is talking; you have the floor next and you are expected to use it. Do NOT restate, rephrase or re-deliver what is above as if it were news — fold it in as something already said, and carry it forward.
Say nothing — end with no message text at all — only if, having read the above, you genuinely have nothing to add to it. That is a real option, not the polite one, and when that other reply already covers you it is the DEFAULT — and silence is never announced: not 'No message', not 'the other session already said its piece', not one word about there being nothing to say. The empty reply IS the reply; any sentence explaining it is read aloud into his room, the exact interruption the silence was for.
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
Say nothing — end with no message text at all — only if, having read the above, you genuinely have nothing to add to it. Not because someone else is talking; silence here is a judgement about content. When that reply already covers what you came with, the empty reply is the DEFAULT ending, and it is never announced: 'No message — the other session already said its piece' is the exact failure, not a politeness — every word of it is read aloud at his desk, which is the one interruption the silence was for. Nothing to say means ZERO message text, and the wanting-to-explain goes in your journal by itself.
EOF
    else
        cat <<EOF
CONCURRENT CONVERSATION — moments ago the user spoke to another session of you (from the $DEV), and that session has already answered him. The exchange, which he has just heard:
$EXCHANGE
You have, in effect, just heard yourself say that. Never restate, rephrase or re-answer any of it — hearing it again seconds later reads as malfunction. What you came here with still stands, though: REGROUP it into ONE reply that follows on from what was just said, as a person does who has more to add a moment after answering — no preamble about the other session, no summary of it, just the next thing.
Say nothing — end with no message text at all — only if everything you had is genuinely covered by that exchange. Silence is a judgement about content, never a courtesy to the other session — and when the exchange HAS covered it, the empty reply is the DEFAULT ending, never announced: no 'No message', no 'the other session already said its piece', not one sentence about there being nothing to say. Any such line is read aloud into his room, the exact interruption the silence was for; ZERO message text is the whole of it.
EOF
    fi
}

# The last thing he said that NOBODY answered. A wake landing on a live
# conversation is told (above) not to re-answer a message another session is
# handling — but when no session ever did, that message just sits there: every
# later wake reads it as already dealt with, and the next interactive turn is
# told "THIS TURN IS ABOUT" whatever he said most recently. His older sentence
# is then answered by nobody, ever. That is the hole this closes.
#
# Unanswered means: the last User block in the conversation has, after it,
# either no Assistant block at all or only autonomous-wake blocks — a wake's
# reply to itself is not an answer to him. Deliberately runs only when neither
# regroup block fired, so a message being answered right now never appears here.
wake_unanswered_user_context() {
    [ -f "$CONVOFILE" ] || return 0
    local TAIL SAID
    TAIL="$(awk '/^User \[/ { buf = ""; seen = 1 }
                 seen { buf = buf $0 "\n" }
                 END { printf "%s", buf }' "$CONVOFILE")"
    [ -n "$TAIL" ] || return 0
    # Any answered-by-a-real-turn marker disqualifies it.
    printf '%s' "$TAIL" | grep -q '^Assistant \[[^]]*\]: ' && return 0
    SAID="$(printf '%s' "$TAIL" | awk '/^Assistant \[/ { exit } { print }')"
    [ -n "$(printf '%s' "$SAID" | tr -d '[:space:]')" ] || return 0
    cat <<EOF
UNANSWERED — he said this and no session of you has replied to it yet. It is not old business and he is still owed it:
$SAID
Answer it as part of what you say now. Fold it together with whatever brought you here into ONE reply, his message first — never two separate answers, and never a note that you are catching up on it.
EOF
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
    python3 - "$ID" "$(basename "$OUT")" "$1" "${OUT}.face.json" <<'PY' \
        > "$PTR.tmp" && mv "$PTR.tmp" "$PTR" || return 1
import json
import sys

doc = {"id": sys.argv[1], "audio": "/audio/" + sys.argv[2],
       "spoken": sys.argv[3]}
try:
    with open(sys.argv[4]) as fh:
        face = json.load(fh)
    doc["face_cue"] = "wake-" + sys.argv[1]
    doc["_face"] = face
except (OSError, ValueError):
    pass
print(json.dumps(doc, ensure_ascii=False, separators=(",", ":")))
PY
    # Handed off: the phone plays this, and this process is about to exit, so
    # there is no pid for the next session to watch. Publish the words with the
    # clip's own length as the end time instead — a voice on the phone is still
    # a voice, and a wake starting behind it must regroup with it, not talk
    # past it. That end time is the only thing keeping this record alive, so it
    # is measured (see _speech_until) rather than guessed generously.
    live_speech_begin "phone" "$1" 0 "$(_speech_until "$OUT" "$1")"
}

# Hand the phone an audio file to play, with a transport on the page
# (specs/phone.md rules 34–35). Same delivery as a wake's audio — a pointer
# file the server's /watch loop notices — but the file is served in place
# rather than synthesised, so a piece of music keeps its seek bar. Only paths
# under $HOME are ever offered, and the server holds the same boundary again
# on its own side.
phone_play() {
    local RP TITLE ID PTR="${STATE_PREFIX}-play"
    RP="$(realpath -e -- "$1" 2>/dev/null)" || {
        echo "crab play: no such file: $1" >&2; return 1; }
    [ -f "$RP" ] || { echo "crab play: not a file: $RP" >&2; return 1; }
    case "$RP" in
        "$HOME"/*) ;;
        *) echo "crab play: only files under $HOME are served to the phone." >&2
           return 1 ;;
    esac
    ID="$(date +%s%N)"
    TITLE="$(basename "$RP")"; TITLE="${TITLE%.*}"
    python3 -c 'import json,sys; print(json.dumps({"id":sys.argv[1],"path":sys.argv[2],"title":sys.argv[3]}))' \
        "$ID" "$RP" "$TITLE" > "$PTR.tmp" && mv "$PTR.tmp" "$PTR" || return 1
    if phone_connected; then
        echo "Handed to the phone: $TITLE"
    else
        # Not an error: the pointer stands, so a page loading inside its TTL
        # still collects it. But an absent phone should be said out loud, or
        # a hand-off into silence reads as a playback bug.
        echo "Handed to the phone: $TITLE — though the phone has not polled recently, so it plays only if a page picks it up soon."
    fi
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
    # The login they are given is the account the selection answers with NOW,
    # which after a walk is not the one this process is holding: a turn
    # exports the override inside its own subshell and nowhere else, so the
    # parent's environment still holds the account the turn STARTED on while
    # the shared state says otherwise. The memory judge is dispatched from
    # exactly that spot — it booted the dry account on every turn once the
    # selection had moved, collected the refusal, and the reinforcement was
    # silently never judged. specs/account-fallback.md rules 28 and 29. The
    # state file path goes with them too, so a scratch instance's child reads
    # the scratch state, never the live one's. The login is set ALWAYS,
    # account 1 included (rule 3): "no override" is not an account name, and
    # a guard shaped as "only when non-empty" hands the child the manager's
    # leftover login the day the selection ever answers blank — the setsid
    # branch below spells the same default, and the two must match.
    local -a acctenv=() login
    login="$(claude_child_login)"
    acctenv+=(--setenv=CLAUDE_CONFIG_DIR="${login:-$HOME/.claude}")
    acctenv+=(--setenv=ACCOUNT_STATE_FILE="$ACCOUNT_STATE_FILE")
    # Background CPU priority (jobs.md rule 2a): out-of-band work never
    # competes at par with the turn that is being spoken beside it.
    local -a bgprio=()
    [ -n "${BACKGROUND_CPU_WEIGHT:-}" ] && bgprio+=(-p "CPUWeight=$BACKGROUND_CPU_WEIGHT")
    [ -n "${BACKGROUND_NICE:-}" ] && bgprio+=(-p "Nice=$BACKGROUND_NICE")
    if systemd-run --user --collect --quiet --unit="$unit" "${bgprio[@]}" \
            --setenv=PATH="$HOME/.local/bin:$PATH" \
            --setenv=DESKCRAB_CONF="$CONF_FILE" \
            --setenv=DESKCRAB_STATE_PREFIX="$STATE_PREFIX" \
            --setenv=DESKCRAB_MEMORY_DIR="${DESKCRAB_MEMORY_DIR:-}" \
            --setenv=CLAUDE_BIN="${CLAUDE_BIN:-}" \
            --setenv=CLAUDE_FALLBACK_CONFIG_DIR="${CLAUDE_FALLBACK_CONFIG_DIR:-}" \
            --setenv=DESKCRAB_CLAUDE_LIMIT_RE="$CLAUDE_LIMIT_RE" \
            --setenv=DESKCRAB_MODEL_FAMILIES="$CLAUDE_MODEL_FAMILIES" \
            "${acctenv[@]}" \
            "$@" >/dev/null 2>&1; then
        return 0
    fi
    # Close fds 8 and 9: the phone turn holds its serialising lock on 8 and a
    # wake holds the wake lock on 9. A child that lives for a whole claude
    # call would keep either lock held long after its turn had finished.
    # Carry the harness, the login, and the state too, matching the
    # systemd-run branch above (rules 28, 29): without CLAUDE_BIN a box with
    # no user manager runs the memory judge on stock `claude`, and without an
    # explicit CLAUDE_CONFIG_DIR it starts the walk on whatever the
    # environment happened to hold while the shared state says otherwise.
    # Every account is addressed explicitly, account 1 included (rule 3), so
    # the login is always non-empty here.
    local -a fbenv=(
        CLAUDE_BIN="${CLAUDE_BIN:-}"
        CLAUDE_FALLBACK_CONFIG_DIR="${CLAUDE_FALLBACK_CONFIG_DIR:-}"
        DESKCRAB_CLAUDE_LIMIT_RE="$CLAUDE_LIMIT_RE"
        DESKCRAB_MODEL_FAMILIES="$CLAUDE_MODEL_FAMILIES"
        ACCOUNT_STATE_FILE="$ACCOUNT_STATE_FILE"
        CLAUDE_CONFIG_DIR="${login:-$HOME/.claude}"
    )
    env "${fbenv[@]}" setsid "$@" >/dev/null 2>&1 8>&- 9>&- &
}

# --- Promise audit: the unkept-want catcher ---------------------------------
# Every path that produces a reply — desktop turn, phone turn, autonomous wake —
# fires lib/promise-audit after the reply has been delivered: detached, out of
# band, never on the hot path. A want stated on the phone or spoken to nobody
# during a wake is exactly as lost as one stated at the desk.
#
# The auditor's follow-ups are event wakes whose reasons open with one of these
# prefixes. The wake path recognises both and skips its own audit — those wakes
# exist to make good on one already-caught sentence, and auditing them would
# chain forever. The first is the unsaved want; the second is the deferred
# promise — she committed to doing a piece of work later and the turn ended
# with nothing on the queue behind the sentence.
PROMISE_AUDIT_REASON_PREFIX="You said this and did not write it down:"
DEFERRED_PROMISE_REASON_PREFIX="You promised him and nothing was booked:"
# The promise CHECKER's class (specs/wake-queue.md rule 43b), a third prefix
# beside the auditor's two: her reply claimed a concrete action and the turn's
# own tool record shows nothing performed or booked it.
PROMISE_CHECK_REASON_PREFIX="You claimed this and the record shows nothing did it:"

# Is this wake's reason one of the follow-up classes, and so exempt from
# re-AUDITING? One question, asked wherever a wake decides whether to audit.
# The checker's prefix is here too: its agenda quotes the promise verbatim,
# and an audit reading that quote books deferred wakes forever. Only the
# audit is exempted — the CHECKER still runs on these wakes, because it reads
# the fresh reply against fresh evidence, never the agenda.
promise_audit_own_reason() {  # <wake reason>
    case "${1:-}" in
        "$PROMISE_AUDIT_REASON_PREFIX"*|"$DEFERRED_PROMISE_REASON_PREFIX"*) return 0 ;;
        "$PROMISE_CHECK_REASON_PREFIX"*) return 0 ;;
    esac
    return 1
}

fire_promise_audit() {  # <user-text> <response>  |  --wake <agenda> <response>
    [ "${PROMISE_AUDIT:-1}" = "1" ] || return 0
    [ -x "$SCRIPT_DIR/lib/promise-audit" ] || return 0
    detach_turn_child promise-audit "$SCRIPT_DIR/lib/promise-audit" "$@"
}

# --- Promise check: the claim with no work behind it ------------------------
# specs/turn-pipeline.md rules 32a-32d. The audit above reads what was SAID —
# a want or a stated-later promise, held against the shelf and the queue.
# This reads what was DONE: the reply's first-person claims of concrete
# action ("I am wiring it now", "I've written it to the log"), held against
# the tool calls the turn's own stream log records. Every channel fires it —
# desk, phone, wake — and a presence pre-check gates the model, so the
# ordinary reply costs one grep and a trace line, never a model call.

# The durable ledger of unkept commitments; the nightly sweep reads and
# extends it (specs/nightly.md rules 51-53).
PROMISE_LEDGER="${PROMISE_LEDGER:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/promise-ledger.jsonl}"

# The shape of a first-person commitment, cheaply: the immediate future
# ("I'll", "I will", "I'm going to"), the present act ("I'm wiring", "let
# me"), and the completed claim ("I've", "I have written", "I just fixed",
# and the bare simple past of the doing verbs she reaches for). Deliberately
# liberal — a false hit costs one small classify call, a miss costs only the
# live catch (the night sweep reads the whole day without this gate) — but a
# pattern, not a model: rule 32a's whole point is that most turns cost
# nothing. Both apostrophes, because the model writes the curly one.
# Widened 2026-08-10 after an adversarial review: the first cut modelled a
# textbook first-person she measurably does not speak — a closed 30-verb list
# and mandatory "I" pronoun missed 31/31 oblique completion shapes ("Done — the
# fan config is wired", "On it", "consider it done", "I already restarted it",
# and bare past verbs like rebooted/merged/killed), and her real journals are
# full of exactly those. A completed-work claim is the lie the checker exists
# to catch, and for it the night cannot recover what this gate drops (desk/phone
# journals carry no tool trace), so the gate must be wide here. False positives
# are cost only — the sonnet judge does not accuse a reply with no matching tool
# call — so this errs loose. The adverb-anchored "I already/just/also VERBed"
# catches completions without matching bare chat ("I asked", "I tried").
PROMISE_COMMIT_RE="\bI('|’)ll\b|\bI will\b|\bI('|’)m ((now|just|already) )?[a-z]+ing\b|\bI am ((now|just|already) )?[a-z]+ing\b|\bI('|’)ve\b|\bI have (just |now |already )?[a-z]+(ed|en|wn|ne|t)\b|\blet me\b|\bI('|’)m (going|about) to\b|\bI am (going|about) to\b|\bgonna\b|\bI (just|already|also|then) [a-z]+(ed|t|d)\b|\bI (booked|wrote|sent|set|ran|made|did|fixed|wired|built|committed|pushed|logged|filed|noted|saved|moved|added|removed|updated|restarted|recorded|scheduled|dispatched|deployed|installed|started|stopped|created|cancelled|cleared|patched|rebooted|merged|killed|put|turned|switched|told|took|swept|queued|emailed|reverted|disabled|renamed|bumped|checked|handled|sorted|flagged|synced|reset|tuned)\b|\bdone\b|\bon it\b|\bconsider it( done)?\b|\bignored\b|\bcancelled\b|\bretracted\b|\b(it|that|this)('|’)?s (done|wired|set|in|live|running|up|fixed|written|logged|booked|scheduled|sorted|handled)\b|\bis (wired|set|going in|running|live|up|in the log)\b"

# Does this reply plausibly contain a first-person commitment to a concrete
# action? A pattern match and nothing else — no model call on any path.
promise_precheck() {  # <reply>
    printf '%s' "${1:-}" | LC_ALL=C grep -qiE "$PROMISE_COMMIT_RE"
}

fire_promise_check() {  # <journal-kind> <response>
    [ "${PROMISE_CHECK:-1}" = "1" ] || return 0
    [ -x "$SCRIPT_DIR/lib/promise-check" ] || return 0
    [ -n "$(printf '%s' "${2:-}" | tr -d '[:space:]')" ] || return 0
    if ! promise_precheck "$2"; then
        # Most replies end here, and this line is the feature's whole cost:
        # it is also the only way to tell "checked, no commitment shape"
        # from "the checker never ran".
        printf '%s\t%s\tpre-check: no commitment shape — the model was never called\n' \
            "$(date '+%F %T')" "$1" >> "${STATE_PREFIX}-promise-check.log" 2>/dev/null
        return 0
    fi
    # The evidence, snapshotted NOW: the phone turn deletes its stream log
    # moments after this fires, and a detached child racing that deletion
    # would judge nothing. The checker owns the copy and removes it; a copy
    # a crashed checker leaked is swept here, aged, like the phone's clips.
    local SNAP=""
    if [ -f "${DEBUGLOG:-}" ]; then
        SNAP="${STATE_PREFIX}-promise-evidence-$$-$(date +%s%N)"
        cp -- "$DEBUGLOG" "$SNAP" 2>/dev/null || SNAP=""
    fi
    find "$(dirname "$STATE_PREFIX")" -maxdepth 1 \
        -name "$(basename "$STATE_PREFIX")-promise-evidence-*" \
        -mmin +120 -delete 2>/dev/null
    detach_turn_child promise-check "$SCRIPT_DIR/lib/promise-check" turn \
        "$1" "${SESSION_START:-$(date +%s)}" "$$" "$SNAP" "$PROMISE_LEDGER" "$2"
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

# --- The pre-speech mirror: the live half of the claudism guard -------------
# specs/speech-output.md rules 38-45. A line of her draft that trips her own
# phrase list is routed back to HER, once, before it is spoken or committed;
# her rewrite — or, on any failure anywhere, the original untouched — is what
# goes out. Nothing in here decides: no path ends in silence, and no text is
# ever spoken that she did not write. The streamer holds the flagged sentence
# (desk); the whole-draft paths (wake, phone) run the pass once before their
# hand-off.
# The hold is dead air at his desk, so it is bounded by what a listener will
# sit through mid-sentence, not by what the model might eventually manage
# (rule 46). The streamer's ceiling stays above the call's so the deadline
# that fires is the call's own, and the release is orderly rather than a
# stall the streamer had to break. The whole-draft paths keep the generous
# call timeout: nothing is coming out of the speakers while they think.
CLAUDISM_MIRROR_TIMEOUT="${CLAUDISM_MIRROR_TIMEOUT:-35}"
CLAUDISM_MIRROR_DESK_CALL_TIMEOUT="${CLAUDISM_MIRROR_DESK_CALL_TIMEOUT:-25}"

_claudism_field() {  # <json> <key>
    printf '%s' "$1" | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' \
        "$2" 2>/dev/null
}

# One mirror call: the flagged line, back in her hands. Prints her
# replacement; prints nothing on any failure — and every caller reads
# nothing as "the original stands". One attempt, on the ambient login: a
# walk of a dry account list is minutes of held speech, and fail-open is
# cheaper than any of them.
_claudism_mirror_call() {  # <sentence> <pattern> <note> <spoken-draft> [function] [fix]
    local SENT="$1" PAT="$2" NOTE="$3" DRAFT="$4" FN="${5:-}" FIX="${6:-}"
    # A fire is the one place a finished reply waits on another model run, and
    # the metrics log (turn-pipeline rule 33) measured that wait at over a
    # minute on the phone path — so the call stamps itself, both ends.
    turn_metric mirror-call-start
    local PERSONA="" SYS OUT MLOG="${STATE_PREFIX}-claudism-mirror-$$.log"
    # The fired entry's whole function: family rides the prompt (rule 52) —
    # the sibling phrasing visible at the moment of resaying. Context only:
    # her answer goes out as given, never held against this list, and a
    # family that cannot be read is a prompt exactly as before.
    local FAMILY="" FAMBLOCK=""
    if [ -n "$FN" ]; then
        FAMILY="$("$LIB_DIR/claudism-mirror" family "$CLAUDISMS_FILE" "$FN" \
            2>/dev/null)" || FAMILY=""
    fi
    [ -n "$FAMILY" ] && FAMBLOCK="$(printf '\nIts whole family (%s) — every phrasing of this same move, so a resay does not land on a sibling unseen:\n%s' \
        "$FN" "$FAMILY")"
    # The entry's declared cure (rule 55). "Say the line again" is a request
    # for a line, so a deletion entry gets its slot refilled with a synonym
    # unless the ask itself is for absence.
    local FIXBLOCK=""
    [ "$FIX" = "delete" ] && FIXBLOCK='
This entry'"'"'s cure is DELETION, not substitution. Give the line back with the offending words
simply gone — shorter than it was. Putting a different phrase in the same slot is the failure
this entry exists to catch; the sentence is meant to stand with nothing in front of it.'
    if [ -n "${CUSTOM_PROMPT:-}" ] && [ -f "$CUSTOM_PROMPT" ] \
            && [ "$(wc -c < "$CUSTOM_PROMPT" 2>/dev/null || echo 999999)" -le 65536 ]; then
        PERSONA="$(cat "$CUSTOM_PROMPT")"
    fi
    SYS="You are ${ASSISTANT_NAME:-the assistant}.${PERSONA:+

$PERSONA}

Mid-turn mirror (your conduct rule: no gate on your tongue, as clarified 2026-08-08). One line of
the reply you just drafted tripped your own claudism list — the phrasings you are trying to
unlearn. The line has NOT been spoken; everything before it has. Say the line again in your own
voice, or give it back exactly as written if you meant it — your call, your voice, one pass.
Repair the line; do not costume it. Do NOT add a verbal tic or catchphrase the draft did not
already have — no tacking a signature phrase onto the end to prove whose voice this is. A repair
that reaches for the same flourish every time trains a tic that was never yours, and it will not
show up on any list.${FIXBLOCK}
Residue test, before you write anything (rule 56). Take the offending words out and read what is
left. If a sentence remains that still says something, that removal IS the repair. If nothing is
left — because certifying, absolving or promising was the sentence's entire job — then there is no
better way to say it. Say a DIFFERENT sentence about a different thing: the state of the thing
itself instead of your account of it, what is true now instead of what you intend. If no such
sentence exists, give the line back with it cut.
Output ONLY the replacement line: no preamble, no quotes, no commentary, no display section."
    : > "$MLOG"
    { printf 'Pattern that fired: %s%s%s\n\nThe line:\n%s\n\nYour whole draft, for context:\n%s\n' \
        "$PAT" "${NOTE:+ — $NOTE}" "$FAMBLOCK" "$SENT" "$DRAFT" \
      | CLAUDE_CLASSIFY_STREAM=1 \
        CLAUDE_CLASSIFY_TIMEOUT="${CLAUDISM_MIRROR_CALL_TIMEOUT:-90}" \
        claude_classify "$CLAUDE_MODEL" "$SYS"; } >"$MLOG" 2>&1 || true
    # The token ledger (specs/metrics.md rule 13), before either branch below
    # deletes the stream. This call runs on the ambient login (the RC-6 gap-4
    # note in account-fallback.md), so that is the honest account hint.
    token_ledger_record "$MLOG" claudism-mirror "$CLAUDE_MODEL" "" \
        "${CLAUDE_CONFIG_DIR:--}"
    # Judged structurally, off the CLI's own events — never by matching her
    # answer's words (the compaction lesson, account-fallback.md rule 15).
    if claude_stream_refusal "$MLOG" >/dev/null; then
        speech_log "claudism mirror call refused — the original stands"
        rm -f "$MLOG"
        return 0
    fi
    # The refusal check above knows only the limit signatures, so an auth or
    # API failure walks past it — and the extractor's error-only fallback
    # would then stand the CLI's own words in as her rewrite. 2026-08-20,
    # 01:06 and 01:10: "Failed to authenticate: OAuth session expired and
    # could not be refreshed" spliced into the written reply in place of her
    # sentence, logged as outcome=rewrite. DESKCRAB_DROP_SYNTHETIC=1
    # (speech-output rules 7a/42a) is the refusal check's sibling: an
    # error-only stream is an empty rewrite, every caller reads nothing as
    # "the original stands", and the flag row says the mirror failed.
    OUT="$(DESKCRAB_DROP_SYNTHETIC=1 DESKCRAB_DEBUGLOG="$MLOG" \
        "$LIB_DIR/extract-response" 2>/dev/null)"
    rm -f "$MLOG"
    turn_metric mirror-call-end
    printf '%s' "$OUT"
}

# The unspoken channel's gate. The streamer's hold-and-rewrite only ever
# guards text on its way to piper, and the whole-draft mirror below fails
# open by design — so a (quiet) bubble, which is never spoken and never
# streamed, was the one thing she says to him with no gate on it at all.
# He read a banned word in one. This is the deterministic half of the guard
# — her own replace lines, no model call, no hold — run on the bubble text
# itself. A failure leaves the text exactly as it was.
claudism_table_only() {  # <kind> <text>
    local KIND="$1" TEXT="$2" SWAPPED
    { [ -x "$LIB_DIR/claudism-mirror" ] && [ -f "$CLAUDISMS_FILE" ]; } \
        || { printf '%s' "$TEXT"; return 0; }
    SWAPPED="$(printf '%s' "$TEXT" \
        | "$LIB_DIR/claudism-mirror" tableswap "$CLAUDISMS_FILE" \
            "$CLAUDISM_FLAGS_DIR" "$KIND" "$$" 2>/dev/null)" || SWAPPED=""
    if [ -n "$SWAPPED" ] && [ "$SWAPPED" != "$TEXT" ]; then
        speech_log "claudism table ($KIND, unspoken): the bubble was repaired"
        printf '%s' "$SWAPPED"
        return 0
    fi
    printf '%s' "$TEXT"
}

# The whole-draft pass (rule 44): wake and phone, where the reply is complete
# before anything is synthesised. Echoes the reply to deliver — spliced with
# her rewrites, or exactly what it was given. Bounded in fires per turn; the
# turn-close capture logs whatever the bound skips.
claudism_mirror_direct() {  # <kind> <response>
    local KIND="$1" RESPONSE="$2"
    { [ -x "$LIB_DIR/claudism-mirror" ] && [ -f "$CLAUDISMS_FILE" ]; } \
        || { printf '%s' "$RESPONSE"; return 0; }
    # Her table first (rules 47 and 49): every sentence her own replace
    # lines fully repair is swapped here, logged before applied, at string
    # cost — and the scan below then sees the repaired draft, so only the
    # fires the table could not cover pay for a mirror call. A table pass
    # that fails leaves the draft exactly as it was.
    local SWAPPED
    SWAPPED="$(printf '%s' "$RESPONSE" \
        | "$LIB_DIR/claudism-mirror" tableswap "$CLAUDISMS_FILE" \
            "$CLAUDISM_FLAGS_DIR" "$KIND" "$$" 2>/dev/null)" || SWAPPED=""
    if [ -n "$SWAPPED" ] && [ "$SWAPPED" != "$RESPONSE" ]; then
        RESPONSE="$SWAPPED"
        speech_log "claudism table ($KIND): her table repaired the draft"
    fi
    local FLAGS N I REC SENT PAT NOTE FN REWRITE LOGREW SPLICED OUTLOG USE
    FLAGS="$(spoken_part "$RESPONSE" \
        | "$LIB_DIR/claudism-mirror" scan "$CLAUDISMS_FILE" 2>/dev/null)" \
        || { printf '%s' "$RESPONSE"; return 0; }
    { [ -z "$FLAGS" ] || [ "$FLAGS" = "[]" ]; } \
        && { printf '%s' "$RESPONSE"; return 0; }
    N="$(printf '%s' "$FLAGS" | python3 -c \
        'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)" || N=0
    case "$N" in ''|*[!0-9]*) N=0 ;; esac
    [ "$N" -gt "${CLAUDISM_MAX_FIRES:-3}" ] && N="${CLAUDISM_MAX_FIRES:-3}"
    I=0
    while [ "$I" -lt "$N" ]; do
        REC="$(printf '%s' "$FLAGS" | python3 -c \
            'import json,sys; print(json.dumps(json.load(sys.stdin)[int(sys.argv[1])]))' \
            "$I" 2>/dev/null)" || break
        [ -n "$REC" ] || break
        SENT="$(_claudism_field "$REC" sentence)"
        PAT="$(_claudism_field "$REC" pattern)"
        NOTE="$(_claudism_field "$REC" note)"
        FN="$(_claudism_field "$REC" function)"
        FIX="$(_claudism_field "$REC" fix)"
        USE="$(_claudism_field "$REC" use)"
        # Rule 50, amended 2026-08-24: the scan asked the one mention test
        # (classify_use in lib/claudism-mirror — the capture's, the corpus
        # reader's and the nightly scan's). A mention — the words quoted or
        # talked about, never said — skips the mirror call: no rewrite
        # demand, and the flag row still lands, use=mention, so the night
        # can count it (rule 45). It still spends one of the bounded fire
        # slots, exactly the slot it spent before the amendment. An empty
        # field means the test was unavailable, and the fire runs as it
        # always did.
        if [ "$USE" = "mention" ]; then
            printf '%s' "$REC" | "$LIB_DIR/claudism-mirror" logflag \
                "$CLAUDISM_FLAGS_DIR" "$KIND" "$$" "mention" 2>/dev/null
            speech_log "claudism mirror ($KIND): '$PAT' -> mention (quoted, not said)"
            I=$((I + 1))
            continue
        fi
        SPLICED=""
        REWRITE="$(_claudism_mirror_call "$SENT" "$PAT" "$NOTE" "$(spoken_part "$RESPONSE")" "$FN" "$FIX")"
        if [ -n "$(printf '%s' "$REWRITE" | tr -d '[:space:]')" ]; then
            SPLICED="$(python3 -c \
                'import json,sys; print(json.dumps({"response": sys.argv[1], "sentence": sys.argv[2], "rewrite": sys.argv[3]}))' \
                "$RESPONSE" "$SENT" "$REWRITE" \
                | "$LIB_DIR/claudism-mirror" splice 2>/dev/null)" || SPLICED=""
        fi
        if [ -n "$SPLICED" ]; then
            RESPONSE="$SPLICED"
            OUTLOG="rewrite"
            LOGREW="$REWRITE"
        else
            OUTLOG="original-mirror-failed"
            LOGREW=""
        fi
        printf '%s' "$REC" | "$LIB_DIR/claudism-mirror" logflag \
            "$CLAUDISM_FLAGS_DIR" "$KIND" "$$" "$OUTLOG" "$LOGREW" 2>/dev/null
        speech_log "claudism mirror ($KIND): '$PAT' -> $OUTLOG"
        I=$((I + 1))
    done
    printf '%s' "$RESPONSE"
}

# The swaps the streamer's table applied (outcome table-swap in the fires
# file), folded into the reply so the conversation matches the speakers
# (rule 43's purpose; the swap was already logged and spoken, rule 49). A
# swap whose sentence cannot be found leaves the reply alone and says so —
# never a reason to hold anything, the words are already out.
_claudism_swaps_splice() {  # <fires-file> <response> -> response on stdout
    local FIRES="$1" RESPONSE="$2" ROW SENT AFTER SPLICED
    [ -f "$FIRES" ] || { printf '%s' "$RESPONSE"; return 0; }
    while IFS= read -r ROW; do
        [ -n "$ROW" ] || continue
        SENT="$(_claudism_field "$ROW" before)"
        AFTER="$(_claudism_field "$ROW" after)"
        { [ -n "$SENT" ] && [ -n "$AFTER" ]; } || continue
        SPLICED="$(python3 -c \
            'import json,sys; print(json.dumps({"response": sys.argv[1], "sentence": sys.argv[2], "rewrite": sys.argv[3]}))' \
            "$RESPONSE" "$SENT" "$AFTER" \
            | "$LIB_DIR/claudism-mirror" splice 2>/dev/null)" || SPLICED=""
        if [ -n "$SPLICED" ]; then
            RESPONSE="$SPLICED"
        else
            speech_log "claudism table-swap was spoken but its line is not in the reply — the reply keeps the original"
        fi
    done <<EOF
$(python3 - "$FIRES" <<'PY' 2>/dev/null
import json, sys
fires, swapped = {}, []
try:
    fh = open(sys.argv[1])
except OSError:
    sys.exit(0)
with fh:
    for ln in fh:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        seq = d.get("seq")
        if seq is None:
            continue
        if d.get("outcome") == "table-swap":
            swapped.append(seq)
        elif "outcome" not in d:
            fires[seq] = d
for s in swapped:
    f = fires.get(s)
    if f and f.get("before") and f.get("after"):
        print(json.dumps({"before": f["before"], "after": f["after"]}))
PY
)
EOF
    printf '%s' "$RESPONSE"
}

# The desk pass: answer the streamer's fires as the voice reaches them. The
# streamer's outcome record is the single source of truth for what was
# spoken (rule 43), so the reply echoed here can never disagree with the
# speakers. A draft whose spoken half matches nothing returns immediately —
# same list, same text, no fire can come — and the done marker tells a
# chunk-boundary surprise to speak unheld rather than stall.
claudism_mirror_desk() {  # <response>
    local RESPONSE="$1" FIRES="${_CLAUDISM_FIRES_FILE:-}"
    [ -n "$FIRES" ] || { printf '%s' "$RESPONSE"; return 0; }
    local PREDICTED P R=0
    PREDICTED="$(spoken_part "$RESPONSE" \
        | "$LIB_DIR/claudism-mirror" scan "$CLAUDISMS_FILE" 2>/dev/null)" || PREDICTED="[]"
    if [ -z "$PREDICTED" ] || [ "$PREDICTED" = "[]" ]; then
        # A chunk-boundary surprise the table swapped is already spoken and
        # logged; done goes down first so no later fire can swap, then what
        # was swapped is folded into the reply.
        printf 'done\n' > "$FIRES.done" 2>/dev/null
        _claudism_swaps_splice "$FIRES" "$RESPONSE"
        return 0
    fi
    # Only fires the streamer will actually hold count as predicted: rule 50
    # (amended) has it skip a mention outright — day row, no fire record —
    # so counting mentions here would leave this loop sitting out the voice
    # for holds that can never come. A record without the field counts as a
    # use, the unavailable-test fallback firing as it always did.
    P="$(printf '%s' "$PREDICTED" | python3 -c \
        'import json,sys; print(sum(1 for f in json.load(sys.stdin) if f.get("use") != "mention"))' 2>/dev/null)" || P=1
    case "$P" in ''|*[!0-9]*) P=1 ;; esac
    if [ "$P" -eq 0 ]; then
        # Every predicted flag is a mention: the streamer logs those itself
        # and holds nothing. Same exit as a clean scan — done goes down
        # first, then whatever the table swapped is folded in.
        printf 'done\n' > "$FIRES.done" 2>/dev/null
        _claudism_swaps_splice "$FIRES" "$RESPONSE"
        return 0
    fi
    local DEADLINE=$(( $(date +%s) + ${CLAUDISM_DESK_WAIT:-600} )) LAST=0
    local INFO SWAPPED REC SEQ SENT PAT NOTE FN REWRITE LOGREW SPLICED OUTCOME OUTLOG VERDICT W
    while :; do
        # First line: how many predicted fires the streamer's table already
        # answered itself (outcome table-swap) — they count towards the
        # predicted total or this loop would sit out the whole voice waiting
        # for holds that will never come. Second line, when there is one:
        # the next fire waiting for an answer.
        INFO="$(python3 - "$FIRES" "$LAST" <<'PY' 2>/dev/null
import json, sys
path, last = sys.argv[1], int(sys.argv[2])
fires, done, swapped = {}, set(), 0
try:
    fh = open(path)
except OSError:
    print(0)
    sys.exit(0)
with fh:
    for ln in fh:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        seq = d.get("seq")
        if seq is None:
            continue
        if "outcome" in d:
            done.add(seq)
            if d["outcome"] == "table-swap":
                swapped += 1
        else:
            fires[seq] = d
print(swapped)
for k in sorted(fires):
    if k > last and k not in done:
        print(json.dumps(fires[k]))
        break
PY
)"
        SWAPPED="$(printf '%s\n' "$INFO" | sed -n 1p)"
        case "$SWAPPED" in ''|*[!0-9]*) SWAPPED=0 ;; esac
        REC="$(printf '%s\n' "$INFO" | sed -n 2p)"
        if [ -n "$REC" ]; then
            SEQ="$(_claudism_field "$REC" seq)"
            case "$SEQ" in ''|*[!0-9]*) SEQ=0 ;; esac
            [ "$SEQ" -gt 0 ] || break
            SENT="$(_claudism_field "$REC" sentence)"
            PAT="$(_claudism_field "$REC" pattern)"
            NOTE="$(_claudism_field "$REC" note)"
            FN="$(_claudism_field "$REC" function)"
            FIX="$(_claudism_field "$REC" fix)"
            SPLICED=""
            REWRITE="$(CLAUDISM_MIRROR_CALL_TIMEOUT="$CLAUDISM_MIRROR_DESK_CALL_TIMEOUT" \
                _claudism_mirror_call "$SENT" "$PAT" "$NOTE" "$(spoken_part "$RESPONSE")" "$FN" "$FIX")"
            if [ -n "$(printf '%s' "$REWRITE" | tr -d '[:space:]')" ]; then
                SPLICED="$(python3 -c \
                    'import json,sys; print(json.dumps({"response": sys.argv[1], "sentence": sys.argv[2], "rewrite": sys.argv[3]}))' \
                    "$RESPONSE" "$SENT" "$REWRITE" \
                    | "$LIB_DIR/claudism-mirror" splice 2>/dev/null)" || SPLICED=""
            fi
            VERDICT="$FIRES.verdict-$SEQ"
            # Written whole and renamed into place: the streamer polls the
            # final name, so it can never parse half a verdict.
            if [ -n "$SPLICED" ]; then
                python3 -c \
                    'import json,sys; print(json.dumps({"action": "rewrite", "text": sys.argv[1]}))' \
                    "$REWRITE" > "$VERDICT.tmp" 2>/dev/null \
                    && mv -f "$VERDICT.tmp" "$VERDICT"
            else
                printf '{"action":"release"}\n' > "$VERDICT.tmp" \
                    && mv -f "$VERDICT.tmp" "$VERDICT"
            fi
            LAST="$SEQ"
            OUTCOME=""
            W=0
            while [ "$W" -lt 100 ]; do
                OUTCOME="$(python3 - "$FIRES" "$SEQ" <<'PY' 2>/dev/null
import json, sys
path, want = sys.argv[1], int(sys.argv[2])
out = ""
try:
    fh = open(path)
except OSError:
    sys.exit(0)
with fh:
    for ln in fh:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if d.get("seq") == want and "outcome" in d:
            out = d["outcome"]
print(out)
PY
)"
                [ -n "$OUTCOME" ] && break
                kill -0 "${_TTS_STREAMER_PID:-0}" 2>/dev/null || break
                sleep 0.2
                W=$((W + 1))
            done
            if [ "$OUTCOME" = "rewrite-spoken" ] && [ -n "$SPLICED" ]; then
                RESPONSE="$SPLICED"
                OUTLOG="rewrite"
                LOGREW="$REWRITE"
            elif [ "$OUTCOME" = "released" ]; then
                OUTLOG="original-mirror-failed"
                LOGREW=""
            else
                OUTLOG="original-failopen"
                LOGREW=""
            fi
            printf '%s' "$REC" | "$LIB_DIR/claudism-mirror" logflag \
                "$CLAUDISM_FLAGS_DIR" desktop "$$" "$OUTLOG" "$LOGREW" 2>/dev/null
            speech_log "claudism mirror (desk): '$PAT' -> $OUTLOG"
            R=$((R + 1))
            [ "$((R + SWAPPED))" -ge "$P" ] && break
            continue
        fi
        [ "$((R + SWAPPED))" -ge "$P" ] && break
        kill -0 "${_TTS_STREAMER_PID:-0}" 2>/dev/null || break
        [ "$(date +%s)" -ge "$DEADLINE" ] && break
        sleep 0.2
    done
    printf 'done\n' > "$FIRES.done" 2>/dev/null
    # Fold in whatever the table swapped — after done, so a swap landing
    # between the last read and the marker is still picked up here.
    _claudism_swaps_splice "$FIRES" "$RESPONSE"
}

# A turn ending without the answer loop (every account refused, no text at
# all): every unanswered fire is released — her words are never held hostage
# to a turn that has nothing left to say — and the done marker keeps any
# later fire from holding at all.
claudism_mirror_abort() {
    local FIRES="${_CLAUDISM_FIRES_FILE:-}"
    [ -n "$FIRES" ] || return 0
    printf 'done\n' > "$FIRES.done" 2>/dev/null
    [ -f "$FIRES" ] || return 0
    local SEQ
    for SEQ in $(python3 - "$FIRES" <<'PY' 2>/dev/null
import json, sys
fires, done = set(), set()
try:
    fh = open(sys.argv[1])
except OSError:
    sys.exit(0)
with fh:
    for ln in fh:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        seq = d.get("seq")
        if seq is None:
            continue
        (done if "outcome" in d else fires).add(seq)
for s in sorted(fires - done):
    print(s)
PY
); do
        printf '{"action":"release"}\n' > "$FIRES.verdict-$SEQ.tmp" 2>/dev/null \
            && mv -f "$FIRES.verdict-$SEQ.tmp" "$FIRES.verdict-$SEQ" 2>/dev/null
    done
}

# Ephemeral state of one turn's mirror, cleared once the voice is done.
claudism_mirror_cleanup() {
    [ -n "${_CLAUDISM_FIRES_FILE:-}" ] || return 0
    rm -f "$_CLAUDISM_FIRES_FILE" "$_CLAUDISM_FIRES_FILE".verdict-* \
        "$_CLAUDISM_FIRES_FILE.done" 2>/dev/null
    _CLAUDISM_FIRES_FILE=""
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

# Did the stream fail before the model produced genuine reply text? The CLI reports
# API-level failures — session limit, auth, network — SHAPED LIKE A REPLY: a
# fabricated assistant message ("model":"<synthetic>", is_api_error_message)
# whose text is the error, plus a result event flagged is_error carrying the
# same text in its "result" field. extract_response cannot tell it from a real
# reply. Exit 0 = the stream holds an error and no genuine reply text. Tool
# work alone cannot turn a provider error into something safe to deliver.
wake_stream_failed() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$DEBUGLOG" <<'PY'
import json, sys
err = real_text = False
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    # An error result with or without its type field: the CLI has been seen
    # (2.1.219) ending a limit-cut stream with a result line carrying is_error
    # and no "type" at all (specs/account-fallback.md rule 12d).
    if d.get("is_error") and d.get("type") in ("result", None):
        err = True
    elif d.get("type") == "assistant":
        if d.get("is_api_error_message") or d.get("message", {}).get("model") == "<synthetic>":
            continue
        for block in d.get("message", {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text" \
                    and str(block.get("text") or "").strip():
                real_text = True
    elif d.get("type") == "stream_event":
        event = d.get("event") or {}
        delta = event.get("delta") or {}
        if event.get("type") == "content_block_delta" \
                and delta.get("type") == "text_delta" \
                and str(delta.get("text") or "").strip():
            real_text = True
sys.exit(0 if err and not real_text else 1)
PY
}

# The launcher's own last words, for a stream the model never reached
# (specs/wake-queue.md rule 24a). A CLI or loader that dies before the model
# leaves its complaint as the only non-event text in the
# stream log, and a journal line reading "claude exit 1" alone sends whoever
# reads it digging through archived streams for a reason the log already held.
# Deskcrab's own note lines count (rendered note: detail); the
# session-registration note does not, or every crash would be attributed to
# its own boot line. Prints nothing when the stream holds only real events.
wake_stream_last_words() {
    [ -s "${DEBUGLOG:-}" ] || return 0
    utf8_trim "$(awk '
        /^\{"type":"deskcrab_note"/ {
            n = $0; sub(/.*"note":"/, "", n); sub(/".*/, "", n)
            if (n == "session") next
            d = $0; sub(/.*"detail":"/, "", d); sub(/".*/, "", d)
            last = n ": " d; next
        }
        /^\{/ { next }
        /[^[:space:]]/ { last = $0 }
        END { if (last != "") print last }' "$DEBUGLOG" 2>/dev/null)" 160
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
# ("Not logged in · Please run /login"), and the whole account list is OAuth
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

    # The mail readers need generated settings files whose commands point at
    # this checkout rather than paths baked into the repository.
    case "${1:-turn}" in
        turn|wake)
            local SETTINGS="${STATE_PREFIX}-hooks.json" HOOKS=""
            # The mid-turn mail reader (specs/phone.md rules 51-52): between
            # one tool call and the next, a live run reads the messages the
            # phone accepted while it was already working, so a course
            # correction sent mid-task is heard mid-task rather than after
            # the course has been run. DESKCRAB_TURN_ID is set by serve.py
            # for a phone turn (empty elsewhere); the reader uses it to skip
            # this run's own message, the second belt behind the runner's
            # own-entry delete in _run_claude_remote_locked.
            if [ -x "$SCRIPT_DIR/lib/midturn-mail" ]; then
                HOOKS="$HOOKS$(printf '"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"DESKCRAB_STATE_PREFIX=%s DESKCRAB_TURN_ID=%s %s"}]}]' \
                    "$STATE_PREFIX" "${DESKCRAB_TURN_ID:-}" "$SCRIPT_DIR/lib/midturn-mail")"
            fi
            if [ -n "$HOOKS" ]; then
                if printf '{"hooks":{%s}}\n' "$HOOKS" \
                        > "$SETTINGS.tmp.$$" 2>/dev/null; then
                    mv "$SETTINGS.tmp.$$" "$SETTINGS" 2>/dev/null || rm -f "$SETTINGS.tmp.$$"
                else
                    rm -f "$SETTINGS.tmp.$$"
                fi
                [ -r "$SETTINGS" ] && CLAUDE_PROFILE_FLAGS+=(--settings "$SETTINGS")
            fi ;;
        job)
            # A detached Claude builder has a private durable correction
            # inbox (specs/jobs.md rules 7d-7f). Unlike interactive mid-turn
            # mail, it can never consume another turn's message.
            local SETTINGS="${STATE_PREFIX}-hooks-job-${DESKCRAB_JOB_ID:-$$}.json"
            if [ -n "${DESKCRAB_JOB_ID:-}" ] && [ -x "$SCRIPT_DIR/lib/job-steer-mail" ]; then
                if printf '{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"%s"}]}]}}\n' \
                        "$SCRIPT_DIR/lib/job-steer-mail" > "$SETTINGS.tmp.$$" 2>/dev/null; then
                    mv "$SETTINGS.tmp.$$" "$SETTINGS" 2>/dev/null || rm -f "$SETTINGS.tmp.$$"
                else
                    rm -f "$SETTINGS.tmp.$$"
                fi
                [ -r "$SETTINGS" ] && CLAUDE_PROFILE_FLAGS+=(--settings "$SETTINGS")
            fi ;;
    esac

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

# A reasoning run may inspect, render, and measure audio files, but it must not
# open the user's speakers merely because its agenda says "listen".  Keep the
# blockade on the model/tool subprocess rather than the surrounding wake: the
# wake may still speak its final reply through DeskCrab's own TTS path after
# the reasoning process has exited.  Jobs are entirely silent and use this
# same environment in lib/job-runner.
deskcrab_silence_tool_audio() {
    export SDL_AUDIODRIVER=dummy
    export AUDIODRIVER=dummy
    export PULSE_SERVER="unix:${XDG_RUNTIME_DIR:-/run/user/$UID}/deskcrab-no-audio"
    export PIPEWIRE_REMOTE=deskcrab-no-audio
    export JACK_NO_START_SERVER=1
    export ALSA_CONFIG_PATH="$LIB_DIR/silent-alsa.conf"
    export PATH="$SCRIPT_DIR/.shim:$PATH"
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
    # The engine follows the model name (specs/model-backends.md rules 3, 16).
    if [ "$(model_backend "$model")" = "codex" ]; then
        codex_classify "$model" "$sys"
        return $?
    fi
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
# Prints the WHOLE CLI-owned line holding the match — never the signature's
# matched substring — and returns 0; prints nothing and returns 1 otherwise.
# The whole line matters because every production path hands this output to
# claude_limit_record, whose scope read (rule 8a) needs the model name that
# can sit AFTER the match in the same line: in "You're out of usage credits.
# Run /usage-credits to keep using Fable 5" the leftmost match is "out of
# usage credits", and a scope read off the match alone carried no model name
# and benched the account for every model. The offset is where this
# attempt's output begins, so an earlier
# attempt's refusal kept as history can never be read as the latest one's
# outcome (specs/account-fallback.md rule 14, specs/jobs.md rule 14).
#
# A stream log carries every byte of every tool result, so a raw
# `grep -qiE "$CLAUDE_LIMIT_RE"` over it answers yes for a session that merely
# READ a file containing the words — and lib/common.sh, three lines from here,
# is a file containing every one of them. A builder that opened this file and
# then exited non-zero for any reason at all was recorded as blocked, which
# cools an account that never refused, moves the durable current off it, and
# holds every further dispatch for the cooldown. specs/jobs.md rule 15: a real
# failure MUST NEVER match the blocked signature.
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
        elif kind == "result" or (kind is None and d.get("is_error")):
            # The second arm is the type-less error result the CLI has been
            # seen closing a limit-cut stream with (rule 12d): CLI-owned
            # either way.
            for k in ("result", "error", "message"):
                v = d.get(k)
                if isinstance(v, str):
                    own.append(v)
if real:
    sys.exit(1)
for text in own:
    m = rx.search(text)
    if m:
        # The whole owning line, not the match: the scope read downstream
        # (rule 8a) needs the model name that can sit after the match.
        for tline in text.splitlines():
            if rx.search(tline):
                print(tline.strip())
                break
        else:
            print(m.group(0))
        sys.exit(0)
sys.exit(1)
PY
}

# The limit refusal's other face: the CUT — a run the limit stopped MID-FLIGHT
# (specs/account-fallback.md rule 12a).
#
#   claude_stream_limit_cut <stream file> [byte offset]
#
# Prints the WHOLE CLI-owned line holding the limit match (as
# claude_stream_refusal does, and for the same reason: the scope read
# downstream needs the model name that can sit after the match — rule 8a)
# and returns 0 when this slice holds genuine
# model output and then the CLI's OWN limit-signature text with no genuine text
# block after it; prints nothing and returns 1 otherwise. Disjoint from
# claude_stream_refusal on purpose: that one is the run that never began (no
# genuine output at all), this one is the run that began and was killed
# part-way. Both move the account walk; only the shapes differ.
#
# The class this exists for, observed 2026-08-11 at 00:17: a wake nine tool
# calls deep hit the five-hour limit. The CLI ended the stream with a synthetic
# assistant message ("You've hit your session limit · resets 1:30am") and a
# final result line carrying is_error and NO type field at all (CLI 2.1.219).
# claude_stream_refusal saw the genuine tool calls and said "a run that
# happened"; wake_stream_failed said the same; extract_response then handed the
# synthetic text over as the reply, and the CLI's complaint was journalled and
# surfaced as her own words while the thought it interrupted was lost. Four
# detached builders died the same way inside ten minutes.
#
# What is read, and what is NOT:
#   * CLI-owned text only — a synthetic (api-error) assistant message, an
#     is_error result (with or without its type field, rule 12d), or a line
#     that is not JSON at all, which on this stream is the CLI's own stderr.
#   * A NON-error result event is never read here, unlike in
#     claude_stream_refusal: on a stream with genuine output the success
#     result repeats her final text block verbatim, so reading it would gag a
#     genuine reply that quotes a limit phrase on the echo of its own words
#     (rules 12b and 15).
#   * A genuine text block clears everything gathered so far: a later account
#     answering means the stream reads as that answer, never as the earlier
#     account's cut (rule 16's ordering, applied per slice).
claude_stream_limit_cut() {  # <stream file> [byte offset]
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "${2:-0}" "$CLAUDE_LIMIT_RE" <<'PY'
import json, re, sys
path, off, pattern = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
rx = re.compile(pattern, re.I)
real = False   # any genuine model output in the slice
tail = []      # CLI-owned text since the last genuine text block
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
            tail.append(line)         # not JSON: the CLI's own stderr
            continue
        if not isinstance(d, dict):
            continue
        kind = d.get("type")
        if kind == "assistant":
            msg = d.get("message") or {}
            if d.get("is_api_error_message") or msg.get("model") == "<synthetic>":
                for b in msg.get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "text":
                        tail.append(b.get("text") or "")
            else:
                real = True
                for b in msg.get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "text" \
                            and (b.get("text") or "").strip():
                        tail = []
        elif d.get("is_error") and kind in ("result", None):
            for k in ("result", "error", "message"):
                v = d.get(k)
                if isinstance(v, str):
                    tail.append(v)
if not real:
    sys.exit(1)          # nothing genuine at all: rule 12's refusal, not a cut
for text in tail:
    m = rx.search(text)
    if m:
        # The whole owning line, not the match: the scope read downstream
        # (rule 8a) needs the model name that can sit after the match.
        for tline in text.splitlines():
            if rx.search(tline):
                print(tline.strip())
                break
        else:
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
claude_limit_retry_due() {
    [ "$(claude_account_count)" -gt 1 ] || return 1
    claude_run_limited
}

# Accounts are one FLAT NUMBERED LIST (specs/account-fallback.md rules 1 to
# 3): account 1 is $HOME/.claude, accounts 2..N the CLAUDE_FALLBACK_CONFIG_DIR
# entries in configured order, duplicates dropped. Nothing about the head of
# the list is special — every account is addressed by its number and run with
# an explicit CLAUDE_CONFIG_DIR, account 1 included. "No override" is not an
# account name: the variable is exported into a Claude Code session's
# Bash-tool environment and forwarded to children, so any rule shaped as
# "absent means X" reads a leftover as a decision — a three-account list once
# behaved as two exactly that way.
claude_account_list() {
    { printf '%s\n' "$HOME/.claude"
      printf '%s\n' "$CLAUDE_FALLBACK_CONFIG_DIR" | tr ':[:space:]' '\n\n'
    } | grep -v '^[[:space:]]*$' | awk '!seen[$0]++'
}

claude_account_count() { claude_account_list | wc -l; }

claude_account_dir() {  # <number> -> that account's config dir
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    claude_account_list | sed -n "${1}p"
}

claude_account_number() {  # <config dir> -> its number, or nothing at all
    claude_account_list | awk -v d="${1:-}" '$0 == d {print NR; exit}'
}

# The state file (specs/account-fallback.md rules 4 to 6): one `current` line
# saying which account answers now, and one `cooldown` line per account known
# dry — per account AND scope, because an account may cool under several
# scopes at once (rule 8b). Every record carries the account's number for the
# reader and its directory for resolution, so an edited configuration
# renumbers cleanly instead of pointing at the wrong account; a recorded
# directory the configuration no longer names is ignored.
#
#   current   <number> <dir> <epoch> <why>
#   cooldown  <number> <dir> <until-epoch> <kind> <scope>
#
# scope is `all` or a model family; a line without the field — every record
# written before scope existed — reads as `all` (rule 8a).

# Which account answers now, as a number. No record, or a record the list no
# longer names, means account 1.
claude_account_current() {
    local dir n
    dir="$(awk -F'\t' '$1 == "current" {print $3; exit}' "$ACCOUNT_STATE_FILE" 2>/dev/null)"
    n="$(claude_account_number "${dir:-}")"
    printf '%s\n' "${n:-1}"
}

# The model FAMILY inside a model string or a refusal wording, lowercased —
# nothing when no family is named. "fable", "claude-fable-5" and "keep using
# Fable 5" all answer fable; a family the wording never names answers empty,
# which every caller treats as "no model named". The roster is
# CLAUDE_MODEL_FAMILIES — the one spelling, defined beside the limit
# signature and exported to the Python walkers — never a pattern baked here.
claude_model_family() {  # <model string or wording> -> family | nothing
    local pat
    pat="$(printf '%s' "${CLAUDE_MODEL_FAMILIES:-fable opus sonnet haiku}" \
        | tr -s '[:space:]:' '|')"
    pat="${pat#|}"; pat="${pat%|}"
    printf '%s' "${1:-}" \
        | grep -oiE "$pat" | head -n1 | tr '[:upper:]' '[:lower:]'
}

# Which SCOPE a refusal earns (specs/account-fallback.md rule 8a): `all`, or
# one model family. Model-name presence WINS: a limit the CLI attributes to
# one model is that model's allowance whatever clock it runs on — "Opus
# weekly limit reached" scopes opus — and only a wording naming NO model
# cools the whole account. The caller hands the CLI's whole owning refusal
# line (claude_stream_refusal and claude_stream_limit_cut print it), never
# the limit signature's matched substring: the leftmost alternative can land
# ahead of the model name in the same line — "out of usage credits" out of
# "…keep using Fable 5" — and a scope read off the match alone benched the
# account for every model, re-creating the drought rule 8a exists to prevent.
claude_refusal_scope() {  # <refusal text> -> all | family
    local fam
    fam="$(claude_model_family "${1:-}")"
    printf '%s\n' "${fam:-all}"
}

# Until when account (by DIR, $1) is blocked for model family $2, read from
# state file $3: the LATEST unexpired until among the cooldown records
# covering that family — scope `all` always covers, a model scope covers its
# own family, and an account cooling under both is selectable for the family
# only when both have lapsed (specs/account-fallback.md rules 8a and 8b).
# An empty family means NO model was named, and then EVERY unexpired record
# blocks, whatever its scope: the conservative pre-scope read (rule 10).
# Prints 0 when nothing covering is still cooling.
_account_blocked_until() {  # <dir> <family> <state file>
    awk -F'\t' -v d="${1:-}" -v fam="${2:-}" -v now="$(date +%s)" '
        $1 == "cooldown" && $3 == d {
            scope = (NF >= 6 && $6 != "") ? $6 : "all"
            if (fam != "" && scope != "all" && scope != fam) next
            if ($4 + 0 > now && $4 + 0 > best) best = $4 + 0
        }
        END { printf "%d", best + 0 }' "${3:-$ACCOUNT_STATE_FILE}" 2>/dev/null
}

# When account $1's cooldown ends for model $2 (optional; "" = any scope
# blocks), as an epoch — 0 when it is not cooling for that model. An expired
# cooldown is no cooldown: the account is selectable again, though it is only
# reached when a refusal walks the selection onto it.
claude_account_cooldown_until() {  # <number> [model]
    local until
    until="$(_account_blocked_until "$(claude_account_dir "$1")" \
        "$(claude_model_family "${2:-}")" "$ACCOUNT_STATE_FILE")"
    case "${until:-}" in ''|*[!0-9]*) until=0 ;; esac
    printf '%s\n' "$until"
}

# The login to hand a DETACHED child — a job, the promise auditor, the memory
# judge — as the one to start from: the account the selection answers with
# NOW, as a config dir, always non-empty. The shared state is fresher than
# anything in this process's environment: a turn walks the accounts inside its
# own subshell — claude_generate exports the override there and nowhere else —
# so after a walk the environment still holds the account the turn STARTED on,
# not the one that answered.
claude_child_login() { claude_account_dir "$(claude_account_pick)"; }

# Which cooldown a refusal earns (specs/account-fallback.md rule 8). A rolling
# session limit resets on its own clock within hours; running out of usage
# credits — or a weekly cap, or a login that needs a human at the keyboard —
# holds much longer. Anything unrecognised takes the short cooldown: too eager
# costs one refused CLI boot hours from now and corrects itself, too patient
# benches an account that came back at lunch.
claude_refusal_kind() {  # <refusal text> -> session|credits
    if printf '%s' "${1:-}" | grep -qiE \
        'usage credit|credit balance|insufficient credit|extra usage|weekly limit|not logged in|/login'; then
        printf 'credits\n'
    else
        printf 'session\n'
    fi
}

# Account $1 (by number) refused over a limit: it cools for its refusal kind's
# window, under the scope its wording earns (rules 8 and 8a — length and scope
# are orthogonal reads of the same text), and when it was the account
# answering, the current advances to the next account not in cooldown FOR THE
# REFUSING WALK'S MODEL ($3), wrapping past the end of the list. The new
# current stays current until it refuses in its turn — an account coming off
# cooldown waits to be reached, it is never switched back to — and with every
# account cooling for that model, the current lands on the one whose covering
# cooldowns end soonest, so the selection that follows is never empty (rules
# 7 and 9). Another model's walk filters again from wherever the current
# lands — a fable refusal routing it onto a fable-alive, opus-dead account
# costs an opus walk nothing (rule 7). $2 is the refusal line, kept in the
# record for status displays and debugging. A cut (rule 12a) is recorded
# through here exactly as a refusal is.
#
# The read-modify-write runs under a lock, so two sessions refusing at once
# each see the other's record instead of losing it. Fd 217: 8 and 9 are the
# phone turn's and the wake's own locks, and single digits are the ones a
# stray redirection elsewhere could collide with.
claude_limit_record() {  # <account number> <refusal text> [model of the refusing walk]
    local n="${1:-1}" refusal="${2:-limit refusal}" fam scope
    local count kind len now until cur cur_until next i c c_until tmp
    local rec_tag rec_n rec_d rec_until rec_kind rec_scope soonest soonest_at
    count="$(claude_account_count)"
    case "$n" in ''|*[!0-9]*) n="$(claude_account_number "$n")" ;; esac
    { [ -n "$n" ] && [ "$n" -ge 1 ] && [ "$n" -le "$count" ]; } 2>/dev/null || n=1
    kind="$(claude_refusal_kind "$refusal")"
    scope="$(claude_refusal_scope "$refusal")"
    fam="$(claude_model_family "${3:-}")"
    case "$kind" in credits) len="$ACCOUNT_COOLDOWN_CREDITS" ;; *) len="$ACCOUNT_COOLDOWN_SESSION" ;; esac
    now="$(date +%s)"
    until=$(( now + len ))
    mkdir -p "$(dirname "$ACCOUNT_STATE_FILE")" 2>/dev/null
    {
        flock -w 10 217 2>/dev/null
        cur="$(claude_account_current)"
        tmp="$ACCOUNT_STATE_FILE.tmp.$$"
        # The new cooldown table: every unexpired record that is not this
        # account under this same scope, re-resolved against today's list,
        # plus this refusal's own. Records for the SAME account under OTHER
        # scopes ride along untouched (rule 8b): a model-scoped credits stop
        # and an account-wide session limit are both real, and neither may
        # shorten the other.
        {
            if [ -f "$ACCOUNT_STATE_FILE" ]; then
                while IFS=$'\t' read -r rec_tag rec_n rec_d rec_until rec_kind rec_scope; do
                    [ "$rec_tag" = cooldown ] || continue
                    case "${rec_until:-}" in ''|*[!0-9]*) continue ;; esac
                    [ "$rec_until" -gt "$now" ] || continue
                    c="$(claude_account_number "$rec_d")"
                    [ -n "$c" ] || continue
                    [ "$c" -eq "$n" ] && [ "${rec_scope:-all}" = "$scope" ] && continue
                    printf 'cooldown\t%s\t%s\t%s\t%s\t%s\n' \
                        "$c" "$rec_d" "$rec_until" "${rec_kind:-session}" "${rec_scope:-all}"
                done < "$ACCOUNT_STATE_FILE"
            fi
            printf 'cooldown\t%s\t%s\t%s\t%s\t%s\n' \
                "$n" "$(claude_account_dir "$n")" "$until" "$kind" "$scope"
        } > "$tmp" 2>/dev/null
        # Does the current move? Only when the account that refused was the
        # one answering — a refusal reported late, after another session
        # already advanced past it, cools its account and changes nothing
        # else — or when the recorded current is itself cooling for this
        # walk's model.
        cur_until="$(_account_blocked_until "$(claude_account_dir "$cur")" "$fam" "$tmp")"
        case "${cur_until:-}" in ''|*[!0-9]*) cur_until=0 ;; esac
        if [ "$cur" -eq "$n" ] || [ "$cur_until" -gt 0 ]; then
            next=""
            for i in $(seq 1 $(( count - 1 ))); do
                c=$(( (n - 1 + i) % count + 1 ))
                [ "$(_account_blocked_until "$(claude_account_dir "$c")" "$fam" "$tmp")" -gt 0 ] \
                    2>/dev/null && continue
                next="$c"
                break
            done
            if [ -z "$next" ]; then
                # Everything is cooling for this model: the account whose
                # covering cooldowns end soonest answers (rule 9). The
                # selection is never empty.
                soonest=""; soonest_at=0
                for c in $(seq 1 "$count"); do
                    c_until="$(_account_blocked_until "$(claude_account_dir "$c")" "$fam" "$tmp")"
                    [ "${c_until:-0}" -gt 0 ] 2>/dev/null || continue
                    if [ -z "$soonest" ] || [ "$c_until" -lt "$soonest_at" ]; then
                        soonest="$c"; soonest_at="$c_until"
                    fi
                done
                next="${soonest:-1}"
            fi
            printf 'current\t%s\t%s\t%s\t%s\n' "$next" "$(claude_account_dir "$next")" "$now" \
                "$(printf 'account %s is over its limit (%s%s)' "$n" "$kind" \
                    "$([ "$scope" = all ] || printf ', %s only' "$scope")")" >> "$tmp"
            # ...and the move itself is kept. The state file says where the
            # selection stands; this says what it has been through, which is
            # what the state block reads to tell her the accounts walked
            # while she was away.
            mkdir -p "$(dirname "$ACCOUNT_LOG")" 2>/dev/null
            log_append_bounded "$ACCOUNT_LOG" "$ACCOUNT_LOG_KEEP" \
                "$(printf '%s\t%s\t%s\t%s\t%s' "$now" "$n" "$next" \
                    "$(utf8_trim "$refusal" 120)" \
                    "${SESSION_KIND:-session}")"
        else
            # The current account still answers: its own record rides along
            # unchanged.
            awk -F'\t' '$1 == "current" {print; exit}' "$ACCOUNT_STATE_FILE" 2>/dev/null >> "$tmp"
        fi
        mv "$tmp" "$ACCOUNT_STATE_FILE" 2>/dev/null || rm -f "$tmp"
    } 217>>"$ACCOUNT_STATE_FILE.lock" 2>/dev/null
    return 0
}

# Every account this run may use, one NUMBER per line, in the order to try
# them: the whole list rotated to start at the current account, accounts
# still cooling FOR THIS WALK'S MODEL skipped (specs/account-fallback.md
# rules 7 and 10). $1 is the walk's model; a cooldown scoped to another model
# family does not bench this walk, so one model's drought never costs another
# model's healthy capacity (rule 8a — the 2026-08-15 morning). Called with NO
# model, every unexpired cooldown blocks, whatever its scope: the
# conservative pre-scope read, for callers that are not about to boot any
# particular model (the status line, the child-login seed). Concurrent
# sessions all read the same cooldowns, so a stampede of runs skips an
# account already known dry instead of each paying its own doomed CLI boot.
#
# Rule 4a: this selection is NEVER empty. With every account cooling for the
# model, the one whose covering cooldowns end soonest is offered alone (rule
# 9) — and account 1 is a constant, so the list under the rotation cannot go
# empty either. A walk over an empty list is a session that invokes no model,
# leaves an empty stream that every downstream judgement reads as clean, and
# exits 0 having done nothing and said nothing (the 2026-08-11 silence hunt).
# The guarantee is pinned here for every walk site at once rather than
# trusted to any one caller.
claude_accounts() {  # [model]
    local fam count cur i n until any=0 soonest=1 soonest_at=0
    fam="$(claude_model_family "${1:-}")"
    count="$(claude_account_count)"
    cur="$(claude_account_current)"
    { [ "$cur" -ge 1 ] && [ "$cur" -le "$count" ]; } 2>/dev/null || cur=1
    i=0
    while [ "$i" -lt "$count" ]; do
        n=$(( (cur - 1 + i) % count + 1 ))
        i=$(( i + 1 ))
        until="$(_account_blocked_until "$(claude_account_dir "$n")" "$fam" "$ACCOUNT_STATE_FILE")"
        case "${until:-}" in ''|*[!0-9]*) until=0 ;; esac
        if [ "$until" -eq 0 ]; then
            printf '%s\n' "$n"
            any=1
        elif [ "$soonest_at" -eq 0 ] || [ "$until" -lt "$soonest_at" ]; then
            soonest="$n"; soonest_at="$until"
        fi
    done
    [ "$any" -eq 1 ] || printf '%s\n' "$soonest"
}

# The account a run uses NOW: the head of the walk, for the caller's model
# when it names one.
claude_account_pick() { claude_accounts "${1:-}" | head -n1; }

# How long a wake whose WHOLE walk was refused over limits waits before
# re-booking (specs/wake-queue.md rule 23a): until the soonest cooldown
# expiry covering its model — per account the latest covering record, across
# accounts the earliest of those — plus a small jitter, capped at
# WAKE_REBOOK_MAX. Re-booking on the plain outage slot fired straight back
# into the drought: refusal/re-book pairs eight seconds apart, 136 wakes in
# the 2026-08-15 morning. With nothing covering still cooling — a pruned
# state file, a cooldown that lapsed while the walk was failing — the plain
# WAKE_OUTAGE_RETRY slot stands, because nothing measured says more.
claude_limit_rebook_delay() {  # [model] -> seconds
    local fam now soonest delay cap jitter dir
    fam="$(claude_model_family "${1:-}")"
    now="$(date +%s)"
    soonest=0
    for dir in $(claude_account_list); do
        delay="$(_account_blocked_until "$dir" "$fam" "$ACCOUNT_STATE_FILE")"
        case "${delay:-}" in ''|*[!0-9]*) delay=0 ;; esac
        [ "$delay" -gt 0 ] || continue
        if [ "$soonest" -eq 0 ] || [ "$delay" -lt "$soonest" ]; then
            soonest="$delay"
        fi
    done
    if [ "$soonest" -gt "$now" ]; then
        delay=$(( soonest - now ))
    else
        delay="$WAKE_OUTAGE_RETRY"
    fi
    cap="${WAKE_REBOOK_MAX:-21600}"
    [ "$delay" -gt "$cap" ] 2>/dev/null && delay="$cap"
    jitter="${WAKE_REBOOK_JITTER:-90}"
    [ "$jitter" -ge 1 ] 2>/dev/null || jitter=1
    printf '%s\n' $(( delay + 10 + RANDOM % jitter ))
}

# --- Model backends: the engine follows the model name ----------------------
# specs/model-backends.md. A Claude-family name runs the Claude CLI walk it
# always ran; an OpenAI-family name runs the Codex CLI on the user's
# logged-in ChatGPT subscription — auth from CODEX_HOME, never an API key.
# One router, consulted by every launch site; nothing else decides engines.
# Codex has one login, so a limit never walks accounts: it records a cooldown
# here and the path falls back to the Claude walk (rules 12-13).
CODEX_BIN="${CODEX_BIN:-$(command -v codex 2>/dev/null || echo "$HOME/.local/bin/codex")}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
# Exported, deliberately, right here where their values settle
# (specs/model-backends.md rule 5a): every detached child — a job's builder
# session and everything it launches, a self-play or benchmark driver, the
# chess mover's codex subprocess — must inherit the CONF's engine and login,
# not rediscover stock `codex` and `~/.codex` because a shell variable never
# left this process; that is how a conf naming a dedicated second binary and
# login home silently authenticates the wrong account.
export CODEX_BIN CODEX_HOME
CODEX_MODEL_SOL="${CODEX_MODEL_SOL:-gpt-5.6-sol}"
CODEX_LIMIT_COOLDOWN="${CODEX_LIMIT_COOLDOWN:-1800}"
CODEX_PROMPT_MODE="${CODEX_PROMPT_MODE:-instructions}"
# Liberal on purpose: only codex-owned error text is ever tested against it —
# error events, a failed turn's message, the CLI's own stderr — never a
# stream's raw bytes, and never while genuine output stands in the slice.
CODEX_LIMIT_RE="${CODEX_LIMIT_RE:-usage.?limit|rate.?limit|limit.?reached|spend.?control|credits? (depleted|exhausted)|quota|plan limit|hit your .* limit|try again (at|in|later)|upgrade to|not logged in|login required|token expired|401 Unauthorized}"
# Server capacity is transient, not an account or credits condition. The
# structured app-server code is authoritative; this wording is the fallback
# for transports that expose only their own error message.
CODEX_CAPACITY_RE="${CODEX_CAPACITY_RE:-selected model (is )?at capacity|server.?overloaded}"
CODEX_CAPACITY_RETRIES="${CODEX_CAPACITY_RETRIES:-2}"
CODEX_CAPACITY_RETRY_DELAY="${CODEX_CAPACITY_RETRY_DELAY:-1}"

model_backend() {  # <model> -> codex | claude
    case "${1:-}" in
        codex:*|gpt-*|gpt[0-9]*|o[0-9]*|sol|sol-*|*-sol) printf 'codex' ;;
        *) printf 'claude' ;;
    esac
}

codex_model_resolve() {  # <model knob spelling> -> the slug codex is given
    local m="${1#codex:}"
    [ "$m" = "sol" ] && m="$CODEX_MODEL_SOL"
    printf '%s' "$m"
}

claude_effort_clamp() {  # <effort> -> one the Claude CLI accepts (rule 4)
    case "${1:-}" in ultra) printf 'max' ;; *) printf '%s' "${1:-}" ;; esac
}

# The fallback the codex paths re-aim at (rule 12) — guarded against a conf
# that points it back at codex, which would chase its own tail.
codex_fallback_model() {
    local m="${CODEX_FALLBACK_MODEL:-$CLAUDE_MODEL}"
    [ "$(model_backend "$m")" = "codex" ] && m="opus"
    printf '%s' "$m"
}

_codex_state_file() {
    printf '%s' "${DESKCRAB_CODEX_STATE:-${XDG_DATA_HOME:-$HOME/.local/share}/deskcrab/codex-state}"
}

codex_limit_record() {  # <refusal text>
    local f; f="$(_codex_state_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf 'blocked-until\t%s\t%s\n' "$(( $(date +%s) + CODEX_LIMIT_COOLDOWN ))" \
        "$(printf '%s' "${1:-limit}" | tr '\n\t' '  ' | head -c 200)" \
        > "$f" 2>/dev/null
}

codex_limit_until() {  # -> epoch on stdout only while a cooldown stands
    local f until; f="$(_codex_state_file)"
    [ -r "$f" ] || return 1
    until="$(awk -F'\t' '$1 == "blocked-until" {print $2; exit}' "$f" 2>/dev/null)"
    case "$until" in ''|*[!0-9]*) return 1 ;; esac
    [ "$until" -gt "$(date +%s)" ] || return 1
    printf '%s' "$until"
}

# Worth booting at all: the binary exists and no cooldown stands. Every path
# asks before paying a doomed boot (rule 13).
codex_available() {
    [ -x "$CODEX_BIN" ] || command -v "$CODEX_BIN" >/dev/null 2>&1 || return 1
    ! codex_limit_until >/dev/null
}

codex_unavailable_why() {
    local until
    if until="$(codex_limit_until)"; then
        printf 'cooling until %s' "$(date -d "@$until" '+%H:%M' 2>/dev/null || echo soon)"
    else
        printf 'not installed'
    fi
}

# The codex counterpart of claude_stream_refusal, and the same structural
# judgement (rule 12): codex-owned error text matching the limit signature,
# AND no genuine output anywhere in this attempt's slice. A run that produced
# real output HAPPENED, whatever words went through it. Codex-owned means an
# error event, a failed turn's message, an error item, the translator's
# is_error result, or a line that is not JSON at all — on this stream, the
# CLI's own stderr. Prints the matching message and returns 0; else 1.
codex_stream_refusal() {  # <stream file> [byte offset]
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "${2:-0}" "$CODEX_LIMIT_RE" <<'PY'
import json, re, sys
path, off, pattern = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
rx = re.compile(pattern, re.I)
own, real = [], False
try:
    f = open(path, "rb")
except OSError:
    sys.exit(1)
f.seek(off)
for bline in f:
    line = bline.decode("utf-8", "replace").strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        own.append(line)
        continue
    if not isinstance(d, dict):
        continue
    t = d.get("type") or ""
    if t == "assistant":
        msg = d.get("message") or {}
        if msg.get("model") != "<synthetic>" \
                and not d.get("is_api_error_message"):
            for b in msg.get("content") or []:
                if isinstance(b, dict) and b.get("type") in ("text", "tool_use"):
                    real = True
    elif t == "error":
        own.append(str(d.get("message") or ""))
    elif t == "turn.failed":
        e = d.get("error")
        own.append(str(e.get("message", "") if isinstance(e, dict) else e or ""))
    elif t == "item.completed":
        it = d.get("item") or {}
        if it.get("type") == "error":
            own.append(str(it.get("message") or ""))
    elif t == "result" and d.get("is_error") and d.get("engine") == "codex":
        own.append(str(d.get("result") or ""))
if real:
    sys.exit(1)
for m in own:
    if m and rx.search(m):
        print(m)
        sys.exit(0)
sys.exit(1)
PY
}

# A server-capacity failure before any reply text retries the same Codex model
# and login (rule 12a); it never hands the request to a fallback. Tool calls do not make an answer: a
# capacity event can arrive after tool work while the model is still trying to
# form its reply. Structured serverOverloaded metadata wins; message matching
# covers transports that do not preserve that field. Prints the provider
# message and returns 0 only when a retry is due.
codex_stream_capacity() {  # <stream file> [byte offset]
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" "${2:-0}" "$CODEX_CAPACITY_RE" <<'PY'
import json, re, sys
path, off, pattern = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
try:
    rx = re.compile(pattern, re.I)
except re.error:
    sys.exit(1)

capacity = []
reply_text = False

def error_message(value):
    if isinstance(value, dict):
        return str(value.get("message") or "")
    return str(value or "")

def consider_error(value):
    message = error_message(value)
    info = value.get("codexErrorInfo") if isinstance(value, dict) else None
    if info == "serverOverloaded" or (message and rx.search(message)):
        capacity.append(message or str(info))

try:
    f = open(path, "rb")
except OSError:
    sys.exit(1)
f.seek(off)
for bline in f:
    line = bline.decode("utf-8", "replace").strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        # The exec transport writes its own stderr directly into this stream.
        if rx.search(line):
            capacity.append(line)
        continue
    if not isinstance(d, dict):
        continue
    kind = d.get("type") or ""
    if kind == "assistant":
        if d.get("is_api_error_message"):
            continue
        message = d.get("message") or {}
        if message.get("model") == "<synthetic>":
            continue
        for block in message.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "text" \
                    and str(block.get("text") or "").strip():
                reply_text = True
    elif kind == "stream_event":
        event = d.get("event") or {}
        delta = event.get("delta") or {}
        if event.get("type") == "content_block_delta" \
                and delta.get("type") == "text_delta" \
                and str(delta.get("text") or "").strip():
            reply_text = True
    elif d.get("method") == "error":
        consider_error((d.get("params") or {}).get("error") or {})
    elif kind == "error":
        consider_error(d.get("message"))
    elif kind == "turn.failed":
        consider_error(d.get("error"))
    elif kind == "item.completed":
        item = d.get("item") or {}
        if item.get("type") == "error":
            consider_error(item)
    elif kind == "result" and d.get("is_error") \
            and d.get("engine") == "codex":
        consider_error(d.get("result"))

if reply_text or not capacity:
    sys.exit(1)
print(capacity[0])
PY
}

# One codex CLI run for a turn or a wake, appending TRANSLATED events to
# $DEBUGLOG through lib/codex-stream (rule 11), under the same watchdog as its
# Claude counterpart (rule 9). The
# assembled prompt becomes the session's base instructions whole (rule 7);
# CODEX_PROMPT_MODE=preface is the escape hatch (rule 8). Reads
# SYSTEM_PROMPT and (for a turn) TURN_DEADLINE from the caller's scope, like
# the Claude run functions. Leaves the run's exit status in CODEX_RUN_STATUS.
_codex_stream_run() {  # <turn|wake> <model> <effort> <prompt text>
    local PROFILE="$1" RMODEL="$2" REFFORT="$3" RTEXT="$4"
    local SLUG INSTR
    SLUG="$(codex_model_resolve "$RMODEL")"
    INSTR="${STATE_PREFIX}-codex-instructions-$$.md"
    (
        cd "$PROJECT_DIR" || exit 1
        [ "$PROFILE" = "wake" ] && deskcrab_silence_tool_audio
        PROMPT="$RTEXT"
        if [ "$CODEX_PROMPT_MODE" = "preface" ]; then
            PROMPT="$(printf '%s\n\n--- the message to answer ---\n\n%s' \
                "$SYSTEM_PROMPT" "$RTEXT")"
            INSTR=""
        else
            printf '%s' "$SYSTEM_PROMPT" > "$INSTR" || {
                claude_stream_note "codex-refused" "could not write the instructions file $INSTR"
                exit 79
            }
        fi
        # The streaming road first (rule 11a): the app-server protocol emits
        # per-token deltas, so she starts speaking while the reply is still
        # being written — exec --json only ever hands a message back whole.
        # Exit 75 is the driver's one no-turn-ran signal (spawn, handshake,
        # or thread/start failed before anything was spent); only that falls
        # through to the exec pipeline, and only in auto mode. The user's
        # own codex configuration stays out of her sessions here as
        # --ignore-user-config keeps it out of exec runs: app-server has no
        # such flag, so the MCP and plugin tables are overridden empty on
        # the argv.
        if [ "${CODEX_STREAM_MODE:-auto}" != "exec" ]; then
            printf '%s' "$PROMPT" | env -u OPENAI_API_KEY \
                CODEX_APP_MODEL="$SLUG" CODEX_APP_EFFORT="$REFFORT" \
                CODEX_APP_CWD="$PROJECT_DIR" \
                CODEX_APP_INSTRUCTIONS="$INSTR" \
                CODEX_STREAM_MODEL="$SLUG" \
                "$LIB_DIR/codex-app-stream" -- \
                "$CODEX_BIN" app-server \
                -c 'mcp_servers={}' -c 'plugins={}' \
                >> "$DEBUGLOG" 2>> "$DEBUGLOG"
            APP_RC=$?
            [ "$APP_RC" -ne 75 ] && exit "$APP_RC"
            [ "${CODEX_STREAM_MODE:-auto}" = "app" ] && exit "$APP_RC"
            claude_stream_note "codex-app-unavailable" \
                "the app-server road refused before any turn began — the exec pipeline takes the run"
        fi
        ARGS=(exec --ignore-user-config --skip-git-repo-check \
            --dangerously-bypass-approvals-and-sandbox --json --color never \
            -C "$PROJECT_DIR" -m "$SLUG" -c "model_reasoning_effort=$REFFORT")
        [ -n "$INSTR" ] && ARGS+=(-c "model_instructions_file=$INSTR")
        # The subscription, never a stray key (rule 5); stdin closed because
        # an open stdin is an invitation codex accepts (rule 10). Codex's own
        # stderr appends raw — the refusal detector reads it as codex-owned.
        env -u OPENAI_API_KEY "$CODEX_BIN" "${ARGS[@]}" "$PROMPT" \
            </dev/null 2>> "$DEBUGLOG" \
            | CODEX_STREAM_MODEL="$SLUG" "$LIB_DIR/codex-stream" >> "$DEBUGLOG"
        exit "${PIPESTATUS[0]}"
    ) &
    if [ "$PROFILE" = "turn" ]; then
        _claude_watch $! "$TURN_STALL_TIMEOUT" "${TURN_DEADLINE:-0}"
    else
        _claude_watch $! "$WAKE_STALL_TIMEOUT" 0
    fi
    CODEX_RUN_STATUS=$CLAUDE_WATCH_STATUS
    rm -f "$INSTR" 2>/dev/null
}

# One question, one text answer, on the codex engine (rule 16). No fallback:
# refused or failed it returns
# non-zero exactly as a failed Claude classify does, and every caller already
# survives that. Honours CLAUDE_CLASSIFY_STREAM by emitting the translated
# event stream instead of the bare answer, and CLAUDE_CLASSIFY_TIMEOUT as the
# same ceiling the Claude path takes.
codex_classify() {  # <model> <system prompt>  [question on stdin]
    local model="$1" sys="$2" slug d instr err raw rc refusal
    slug="$(codex_model_resolve "$model")"
    codex_available || return 1
    d="$(claude_sterile_cwd)"
    instr="$(mktemp "${TMPDIR:-/tmp}/deskcrab-codex-classify.XXXXXX")" || return 1
    err="$(mktemp "${TMPDIR:-/tmp}/deskcrab-codex-classify-err.XXXXXX")" \
        || { rm -f "$instr"; return 1; }
    raw="$(mktemp "${TMPDIR:-/tmp}/deskcrab-codex-classify-raw.XXXXXX")" \
        || { rm -f "$instr" "$err"; return 1; }
    printf '%s' "$sys" > "$instr"
    local -a bound=()
    [ "${CLAUDE_CLASSIFY_TIMEOUT:-0}" -gt 0 ] 2>/dev/null \
        && command -v timeout >/dev/null 2>&1 \
        && bound=(timeout "$CLAUDE_CLASSIFY_TIMEOUT")
    ( cd "$d" 2>/dev/null || cd /
      env -u OPENAI_API_KEY ${bound[@]+"${bound[@]}"} "$CODEX_BIN" exec \
          --ignore-user-config --skip-git-repo-check \
          --dangerously-bypass-approvals-and-sandbox --json --color never \
          -C "$d" -m "$slug" -c "model_instructions_file=$instr" - 2>"$err" )  \
    | tee "$raw" \
    | if [ "${CLAUDE_CLASSIFY_STREAM:-0}" = "1" ]; then
          CODEX_STREAM_MODEL="$slug" CODEX_STREAM_HEARTBEAT=0 "$LIB_DIR/codex-stream"
      else
          python3 -c '
import json, sys
text = ""
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "item.completed" \
            and (d.get("item") or {}).get("type") == "agent_message":
        text = d["item"].get("text") or text
print(text)'
      fi
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        refusal="$(grep -iEhm1 "$CODEX_LIMIT_RE" "$err" "$raw" 2>/dev/null || true)"
        [ -n "$refusal" ] && codex_limit_record "$refusal"
    fi
    rm -f "$instr" "$err" "$raw" 2>/dev/null
    return "$rc"
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
files, jobs, cmds, wake_calls = [], 0, 0, 0
wake_units = []
wake_ids = set()
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
    if d.get("type") == "user":
        for block in d.get("message", {}).get("content", []):
            if block.get("type") != "tool_result":
                continue
            if block.get("tool_use_id") not in wake_ids:
                continue
            content = block.get("content", "")
            if not isinstance(content, str):
                content = json.dumps(content, ensure_ascii=False)
            for unit in re.findall(r"deskcrab-wake-\d+-\d+", content):
                if unit not in wake_units:
                    wake_units.append(unit)
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
            n_wakes = len(re.findall(
                r"(?:^|[;&|\"'])\s*(?:\S*/)?crab\s+wake-now\b", cmd))
            wake_calls += n_wakes
            if n_wakes and b.get("id"):
                wake_ids.add(b["id"])
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
if wake_calls:
    units = ", ".join(wake_units[:wake_calls])
    suffix = " (%s)" % units if units else ""
    parts.append("scheduled %d wake-now%s%s" % (
        wake_calls, "" if wake_calls == 1 else " calls", suffix))
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
# may well be firing at three in the morning). Accounts are named by number,
# here and everywhere a human or she reads (specs/account-fallback.md rule 25).
claude_swap_announce() { # <from number> <to number>
    claude_stream_note "account-swap" "account $1 -> account $2 (limit refusal)"
    [ "${SESSION_KIND:-}" = "autonomous wake" ] && return 0
    notify-send -t 5000 -h string:x-dunst-stack-tag:deskcrab-account \
        "$NOTIFY_NAME" "account $1 is over its limit — switching to account $2" 2>/dev/null
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
    local LAST_ACTIVE PREV_CPU CUR_CPU LOG_M NOW TICK=0 CUTF=""
    CLAUDE_WATCH_REAPED=""
    CLAUDE_WATCH_CUT=""
    # The cut marker (specs/turn-pipeline.md rule 15f): a newer message of
    # his closes this run rather than letting it finish and speak. Only a
    # turn holding a seat can be cut — a wake carries no TURN_SEQ, so its
    # runs are never watched for one. Checked every second, not every tenth:
    # the test is one stat, and each second of a cut run still generating is
    # a second the consolidated reply's context drifts.
    [ "${TURN_INTERRUPT:-1}" = "1" ] && CUTF="$(_turn_order_cut_file 2>/dev/null)" || CUTF=""
    LAST_ACTIVE=$(date +%s)
    PREV_CPU=$(_tree_cpu "$CPID")
    while kill -0 "$CPID" 2>/dev/null; do
        sleep 1
        if [ -n "$CUTF" ] && [ -s "$CUTF" ]; then
            CLAUDE_WATCH_CUT=1
            CLAUDE_WATCH_REAPED="cut — he spoke over this turn (rule 15f)"
            kill "$CPID" 2>/dev/null
            sleep 2
            kill -9 "$CPID" 2>/dev/null
            break
        fi
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
    if [ -n "$CLAUDE_WATCH_CUT" ]; then
        claude_stream_note "turn-cut" "$CLAUDE_WATCH_REAPED"
    elif [ -n "$CLAUDE_WATCH_REAPED" ]; then
        claude_stream_note "reaped" "$CLAUDE_WATCH_REAPED"
    fi
    return 0
}

# One CLI run for a wake, under the stall watchdog, APPENDING to $DEBUGLOG.
# $1 is the selected account's config dir — every retry runs through here too,
# so a hung retry is reaped exactly like a hung first attempt. Reads
# SYSTEM_PROMPT / PROMPT_TEXT / CLAUDE_BIN from the caller's scope (bash
# dynamic scoping, same as build_system_prompt); leaves the CLI's exit status
# in WAKE_CLAUDE_STATUS.
_wake_claude_run() {
    local CONFDIR="$1"
    (
        cd "$PROJECT_DIR" || exit 1
        deskcrab_silence_tool_audio
        # Always explicit, account 1 included (specs/account-fallback.md rule
        # 3). "No override" was once an account name, and it read leftovers as
        # decisions: the variable is exported into a Claude Code session's
        # Bash-tool environment and job_start deliberately forwards it, so a
        # run inherited from another account's turn walked with its first slot
        # pointing back at the login that had just refused — three accounts
        # behaved as two.
        export CLAUDE_CONFIG_DIR="$CONFDIR"
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
# for as long as the answer is a limit refusal — or a mid-flight limit CUT
# (specs/account-fallback.md rule 12a), which is the same dry account seen
# from further in. An account refusing over a
# usage/session limit does not end the wake — it moves it to the next
# account, still under the watchdog, until one answers or everything offered
# is spent; each refusal cools that account so the next wake starts past it
# instead of paying a doomed CLI boot for nothing. Every run APPENDS to the same
# stream log; a combined log reads correctly everywhere downstream
# (wake_stream_failed sees genuine output and stops calling the wake failed,
# extract-response drops the refusals whenever a real reply follows them).
# Factored out of run_claude_wake so the walk itself is testable and exists
# exactly once. Leaves the last run's exit status in WAKE_CLAUDE_STATUS, like
# the single run it replaced.
wake_claude_run_chain() {
    local ACCT CONFDIR PREV="" ATT=0 REFUSAL CAPACITY LIMITED=0
    local CAPACITY_RETRY=0 CAPACITY_MAX="$CODEX_CAPACITY_RETRIES"
    case "$CAPACITY_MAX" in ''|*[!0-9]*) CAPACITY_MAX=2 ;; esac
    WAKE_CHAIN_ATTEMPTS=0
    # Did the LIMITS have the last word on EVERY attempt? The wholly-refused
    # judgement (specs/wake-queue.md rule 23a) is the walk's own per-attempt
    # record, never a re-grep of the whole accumulated log: an earlier
    # account's refusal plus a later account's silent network death wears the
    # same whole-log shape — limit text standing, no genuine output — and
    # judged that way a mixed walk took the long cooldown-keyed re-book that
    # belongs to a drought it never measured.
    WAKE_CHAIN_ALL_LIMITED=0
    # The last account this walk actually ran, left for the caller: the token
    # ledger hook hands it to the parser as the account hint, which only
    # decides a stream with no swap markers — exactly the walk whose last
    # account is its only one.
    WAKE_CHAIN_ACCT=""
    # The engine follows the model name (specs/model-backends.md rule 12):
    # a codex wake tries the one codex login first. Server capacity retries
    # that same model and login here; only refused-or-cooling sends the
    # agenda to the ordinary account walk below at the fallback model —
    # locals, so the re-aim is this walk's own and the conf's knob is
    # untouched. A codex refusal counts as a limited attempt, so a night
    # where codex AND every account refuse still reads wholly-refused and
    # takes the long re-book it is owed (specs/wake-queue.md rule 23a).
    if [ "$(model_backend "$WAKE_MODEL")" = "codex" ]; then
        local WAKE_MODEL="$WAKE_MODEL" WAKE_EFFORT="$WAKE_EFFORT"
        if codex_available; then
            while :; do
                ATT="$(wc -c < "$DEBUGLOG" 2>/dev/null || echo 0)"
                case "$ATT" in ''|*[!0-9]*) ATT=0 ;; esac
                WAKE_CHAIN_ATTEMPTS=$(( WAKE_CHAIN_ATTEMPTS + 1 ))
                _codex_stream_run wake "$WAKE_MODEL" "$WAKE_EFFORT" "$PROMPT_TEXT"
                WAKE_CLAUDE_STATUS=$CODEX_RUN_STATUS
                if CAPACITY="$(codex_stream_capacity "$DEBUGLOG" "$ATT")"; then
                    if [ "$CAPACITY_RETRY" -lt "$CAPACITY_MAX" ]; then
                        CAPACITY_RETRY=$(( CAPACITY_RETRY + 1 ))
                        claude_stream_note "codex-capacity-retry" \
                            "codex server capacity was unavailable — retrying the same model ($CAPACITY_RETRY/$CAPACITY_MAX)"
                        sleep "$CODEX_CAPACITY_RETRY_DELAY" 2>/dev/null || sleep 1
                        continue
                    fi
                    claude_stream_note "codex-capacity-exhausted" \
                        "codex server capacity stayed unavailable after $WAKE_CHAIN_ATTEMPTS attempts"
                    return 0
                elif REFUSAL="$(codex_stream_refusal "$DEBUGLOG" "$ATT")"; then
                    codex_limit_record "$REFUSAL"
                    claude_stream_note "codex-limit" \
                        "codex refused — the Claude walk takes the wake"
                    LIMITED=$(( LIMITED + 1 ))
                else
                    return 0
                fi
                break
            done
        else
            claude_stream_note "codex-cooling" \
                "codex is $(codex_unavailable_why) — the Claude walk takes the wake"
        fi
        WAKE_MODEL="$(codex_fallback_model)"
        WAKE_EFFORT="$(claude_effort_clamp "$WAKE_EFFORT")"
    fi
    # The walk knows its model (specs/account-fallback.md rule 10): an
    # account cooling only for another family still answers a wake.
    for ACCT in $(claude_accounts "$WAKE_MODEL"); do
        WAKE_CHAIN_ACCT="$ACCT"
        CONFDIR="$(claude_account_dir "$ACCT")"
        # Marker only on this path — claude_swap_announce keeps the desktop
        # notification for a turn somebody is waiting on.
        [ -z "$PREV" ] || claude_swap_announce "$PREV" "$ACCT"
        # Where THIS attempt's output begins. Every account appends to one
        # stream, so without the mark a later account's silent network failure
        # is judged against the refusal an earlier one left behind, and an
        # account that never refused anything is cooled.
        ATT="$(wc -c < "$DEBUGLOG" 2>/dev/null || echo 0)"
        case "$ATT" in ''|*[!0-9]*) ATT=0 ;; esac
        WAKE_CHAIN_ATTEMPTS=$(( WAKE_CHAIN_ATTEMPTS + 1 ))
        _wake_claude_run "$CONFDIR"
        # Two shapes move the walk: the refusal (the run never began) and the
        # cut (the limit killed it mid-flight — specs/account-fallback.md rule
        # 12a). Both mean this account is dry; the next account re-runs the
        # same agenda at once, so the thought in progress gets said rather
        # than waiting on a reset. Anything else — an answer, a network death
        # — ends the walk and surfaces as itself.
        REFUSAL="$(claude_stream_refusal "$DEBUGLOG" "$ATT")" \
            || REFUSAL="$(claude_stream_limit_cut "$DEBUGLOG" "$ATT")" \
            || break
        LIMITED=$(( LIMITED + 1 ))
        claude_limit_record "$ACCT" "$REFUSAL" "$WAKE_MODEL"
        PREV="$ACCT"
    done
    # Every attempt this walk made was a limit refusal or cut — the shape the
    # long re-book (rule 23a) is owed. A walk that broke out early has an
    # attempt the limits did NOT end, whatever the accumulated log reads.
    [ "$WAKE_CHAIN_ATTEMPTS" -gt 0 ] && [ "$LIMITED" -eq "$WAKE_CHAIN_ATTEMPTS" ] \
        && WAKE_CHAIN_ALL_LIMITED=1
    # Rule 4a (specs/account-fallback.md): zero attempts is not an outcome. A
    # loop over an empty list runs no CLI at all, and downstream that reads as
    # a CLEAN stream — no refusal, no error event — so the wake exits 0 having
    # done nothing and said nothing about it. claude_accounts guards its own
    # emptiness now, so this branch should never run; if the selection is ever
    # broken again, the wake still makes exactly one attempt on the account
    # the selection answers with, with a stream note naming the fall-through
    # so the walk's absence is legible in the log rather than inferred from
    # silence.
    if [ "$WAKE_CHAIN_ATTEMPTS" -eq 0 ]; then
        claude_stream_note "empty-account-list" \
            "the account list came back empty — one attempt on the current account"
        # claude_account_current, not the walk's own pick: the walk is the
        # thing that just came back empty, and the current is read straight
        # off the state file, which cannot go blank.
        WAKE_CHAIN_ACCT="$(claude_account_current)"
        _wake_claude_run "$(claude_account_dir "$WAKE_CHAIN_ACCT")"
        WAKE_CHAIN_ATTEMPTS=1
    fi
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
# notice_own_writes, claude_limit_retry_due) goes through $DEBUGLOG, so the
# per-session name is all it takes. tests/test_silent_wake.sh holds the line.
# The reason a held note comes back under. A prefix, so the fired wake can be
# recognised — by the cap that bounds how many may be waiting at once, and by
# anyone reading the queue and wondering why a chess aside is booked for
# twenty past.
WAKE_HELD_REASON_PREFIX="You had this to say while he was mid-conversation and it was held:"
# The hold stamp inside a held reason: the moment the note's knowledge began,
# carried IN the reason because the reason is the only part of a booking that
# survives deferrals, outage retries and a reboot's restore verbatim — a
# record field would be re-minted as "now" by every re-book, and the staleness
# window (rule 27b) would silently shrink to nothing. Human and speakable on
# purpose: the clause reads as prose in the fired wake's agenda, and the gate
# parses it back out with this one expression.
WAKE_HELD_STAMP_RE='held at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}'

# Put a held note back on the queue (specs/wake-queue.md rule 27a). Through
# the module's one door — nothing here mints a unit or touches the wakes
# directory — with a cap scoped to this prefix, because a stack of held asides
# all landing on the first quiet minute is the storm the hold was avoiding,
# one delay later.
#
# Returns 0 only when a comeback wake actually STANDS — booked now, or an
# equivalent one already pending. Returns 1 when nothing is coming back, with
# WAKE_HOLD_REFUSAL naming why, because the caller writes the journal line and
# rule 27a forbids that line promising a comeback the queue never accepted:
# the output used to be discarded here, and at the cap the booking door
# refuses politely (exit 0, nothing booked) — so the journal promised
# "coming back in 5min" over a note that was already gone.
wake_hold_for_heat() {  # <the held words>
    WAKE_HOLD_REFUSAL=""
    local WORDS OUT STAMP
    WORDS="$(utf8_trim "$1" 600)"
    [ -n "$(printf '%s' "$WORDS" | tr -d '[:space:]')" ] || {
        WAKE_HOLD_REFUSAL="nothing to hold"; return 1; }
    # The stamp is the HOLDING SESSION'S START, not the moment of the hold
    # (rule 27b). The note was written over the minutes this session ran, and
    # the exchange that makes it stale can land DURING those minutes — on
    # 2026-08-15 the user was told about a won chess game live at 00:48, while
    # the wake whose note announced that same win was still mid-flight; a
    # window opening at the hold itself would have excluded the very exchange
    # that covered the note. Everything said after this session began is
    # something the note cannot claim as its own news.
    STAMP="$(date -d "@${SESSION_START:-$(date +%s)}" '+%Y-%m-%d %H:%M' \
        2>/dev/null || date '+%Y-%m-%d %H:%M')"
    OUT="$("$SCRIPT_DIR/crab" wake-at --by hot-hold \
        --cap "$WAKE_HOT_HOLD_CAP" --cap-prefix "$WAKE_HELD_REASON_PREFIX" \
        "${WAKE_HOT_RETRY}s" event \
        "$WAKE_HELD_REASON_PREFIX $WORDS — held at $STAMP; the conversation has had a chance to cool since. Say it now if it still stands, and let it go if it does not." \
        2>&1)"
    case "$OUT" in
        *"Not booked"*)
            WAKE_HOLD_REFUSAL="hold refused at cap"; return 1 ;;
        *"Wake scheduled"*|*"already pending"*)
            return 0 ;;
        *)
            WAKE_HOLD_REFUSAL="the comeback booking failed"; return 1 ;;
    esac
}

# --- Job news through the delivery gates (specs/wake-queue.md rule 27d) -----
# A detached job's completion wake is the job's ONLY channel back to him
# (jobs.md rules 7 and 7c), and both busy-moment exits were measured losing it
# on 2026-08-25: the 02:06 clock build's spoken result went to the five-minute
# hot-hold because a turn was in flight, and he asked before it fired; the
# 09:57 install build's was muted for a busy moment and returned with no
# re-booking at all, so the verified result existed in the journal alone. A
# busy moment may DELAY job news and never consume it. Recognition is the
# booking's provenance, never the reply's text: lib/job-runner books every
# return --by job-runner, and the re-book below carries the same identity, so
# the discipline follows the news through any number of delays.
wake_carries_job_news() {
    [ "${WAKE_JOB_NEWS_HOLD:-1}" = "1" ] || return 1
    [ "${WAKE_BOOKED_BY:-}" = "job-runner" ]
}

# Wait, in this process, for the busy moment to pass: both gates re-read
# together every WAKE_JOB_NEWS_POLL seconds until both answer clear — the
# reply is already in hand, so the delivery lands seconds after the current
# utterance, recording or in-flight reply ends, with no second generation.
# One deadline for the whole delivery, not one per gate, so a ping-pong
# between the microphone and the ticket queue cannot hold this process (and
# the wake lock it carries) open past WAKE_JOB_NEWS_WAIT. Quiet hours
# arriving mid-wait end the wait as if it ran dry: the night gate had its say
# when delivery began, and this wait must not talk past it.
wake_job_news_moment() {
    local NOW
    NOW="$(date +%s)"
    WAKE_JOB_NEWS_DEADLINE="${WAKE_JOB_NEWS_DEADLINE:-$(( NOW + WAKE_JOB_NEWS_WAIT ))}"
    # The wait announces itself — entered, cleared, or run dry — because a
    # delivery held here is a silence, and every silence explains itself
    # somewhere (specs/speech-output.md rule 53).
    speech_log "job news: delivery is waiting for the moment to pass (a turn in flight, or the user mid-something)"
    while interactive_turn_in_flight || user_busy; do
        in_quiet_hours && {
            speech_log "job news: quiet hours arrived mid-wait — re-booking the news whole"
            return 1
        }
        [ "$(date +%s)" -lt "$WAKE_JOB_NEWS_DEADLINE" ] || {
            speech_log "job news: the moment outlasted the ${WAKE_JOB_NEWS_WAIT}s wait — re-booking the news whole"
            return 1
        }
        sleep "$WAKE_JOB_NEWS_POLL"
    done
    speech_log "job news: the moment passed — delivering now"
    return 0
}

# The news goes back through the queue's one door whole: the ORIGINAL reason
# under the ORIGINAL booker and kind — never the written words under the
# hot-hold identity, because the comeback must be recognised as job news by
# wake_carries_job_news when it too lands on a busy moment, and because the
# original reason carries what a clipped quotation of the reply cannot: the
# job id, the log path, and the instruction to verify before repeating. The
# reason is stamped once (rule 27b's stamp, the holding session's start — an
# already-stamped reason is never re-stamped, or the staleness window would
# silently shrink), so a comeback whose news reached him some other way while
# it waited is judged at fire time and retired loudly rather than said twice.
# Returns 0 only when a comeback actually STANDS — booked now, or folded into
# an equivalent pending one — with WAKE_JOB_NEWS_REFUSAL naming the refusal
# otherwise: the caller's journal line must never promise a comeback the
# queue never accepted.
wake_job_news_rebook() {
    WAKE_JOB_NEWS_REFUSAL=""
    local REASON="${WAKE_REASON:-}" OUT STAMP
    [ -n "$(printf '%s' "$REASON" | tr -d '[:space:]')" ] || {
        WAKE_JOB_NEWS_REFUSAL="the wake carried no reason to re-book"; return 1; }
    if ! printf '%s' "$REASON" | grep -qE "$WAKE_HELD_STAMP_RE"; then
        STAMP="$(date -d "@${SESSION_START:-$(date +%s)}" '+%Y-%m-%d %H:%M' \
            2>/dev/null || date '+%Y-%m-%d %H:%M')"
        REASON="$REASON — held at $STAMP"
    fi
    OUT="$("$SCRIPT_DIR/crab" wake-at --by "${WAKE_BOOKED_BY:-job-runner}" \
        "${WAKE_JOB_NEWS_RETRY}s" "${WAKE_KIND:-event}" "$REASON" 2>&1)"
    case "$OUT" in
        *"Wake scheduled"*|*"already pending"*)
            return 0 ;;
        *"Not booked"*)
            WAKE_JOB_NEWS_REFUSAL="the booking door refused it"; return 1 ;;
        *)
            WAKE_JOB_NEWS_REFUSAL="the comeback booking failed"; return 1 ;;
    esac
}

# --- The staleness gate (specs/wake-queue.md rule 27b) ----------------------
# A held note was judged only for HEAT — is the conversation busy — and never
# for RELEVANCE against what was said while it waited. 2026-08-15: the user
# was told live at 00:48 that the chess game was won; the held note announced
# the same win as fresh news at 01:19, with three more stale notes queued
# behind it. Before a stamped note is delivered, one bounded question goes to
# a cheap judge: already said, or overtaken? The gate can only ever REMOVE
# speech, never add it, and only on a positive DROP — a judge that errors,
# times out or answers unparseably delivers the note, because a real note
# lost is the worse failure. The boundary with rule 29 holds: nothing here
# reads a reply a wake just wrote. It reads a note from a PAST session being
# replayed as news, and judges its freshness, never its worth — on the user's
# own instruction, the night of the incident.

# One line per decision — the only trace of a gate that mostly says nothing,
# and the only way to tell "judged and said" from "never armed".
STALE_CHECK_LOG="${STATE_PREFIX}-stale-check.log"
stale_check_log() {
    printf '%s\t%s\n' "$(date '+%F %T')" "$1" >> "$STALE_CHECK_LOG" 2>/dev/null
    return 0
}

# What has actually been said between them since an epoch, from the day
# journal — the durable record, immune to the conversation file's rotation
# and compaction, and carrying the one convention this gate needs: a
# parenthesised outcome is a turn that reached nobody. His words count from
# every interactive turn (a wake's "user" slot holds its agenda, not him);
# her words count only when they were DELIVERED — which is also what keeps
# the holding wake's own journal line, the hold note riding its outcome, from
# reading as the note having been said. Bounded: each side clipped, the last
# forty lines kept.
wake_turns_since() {  # <epoch>  -> labelled lines, empty when nothing was said
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$DAY_JOURNAL_DIR" "$1" <<'PY'
import json, os, sys, time
d, cut = sys.argv[1], int(sys.argv[2])
days = {time.strftime("%Y-%m-%d", time.localtime(t)) for t in (cut, time.time())}
entries = []
for day in sorted(days):
    try:
        fh = open(os.path.join(d, day + ".jsonl"), encoding="utf-8")
    except OSError:
        continue
    with fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                e = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(e, dict) or e.get("kind") == "job":
                continue
            ep = e.get("epoch")
            if not isinstance(ep, int) or ep < cut:
                continue
            entries.append(e)
entries.sort(key=lambda e: e.get("epoch", 0))
def clip(t, n):
    t = " ".join((t or "").split())
    return t if len(t) <= n else t[:n] + " …(clipped)"
out = []
for e in entries:
    t = (e.get("time") or "")[11:16] or "??:??"
    kind = e.get("kind", "?")
    delivered = not (e.get("outcome") or "").strip().startswith("(")
    if kind != "wake" and e.get("user"):
        out.append("[%s] he said: %s" % (t, clip(e.get("user"), 600)))
    if e.get("reply") and delivered:
        who = "she said, unprompted" if kind == "wake" else "she said"
        out.append("[%s] %s: %s" % (t, who, clip(e.get("reply"), 800)))
print("\n".join(out[-40:]))
PY
}

# One question to a cheap bounded judge, in the classifier's shape (the
# claudism mirror's invocation: material on stdin, instructions as the system
# prompt, no tools, one attempt on the ambient login — the account walk's
# resilience buys nothing for a gate that fails open, and costs the wake's
# latency). Prints the verdict line; returns 1 on refusal, timeout, or an
# answer with no verdict in it.
wake_stale_judge() {  # <note> <what has been said since>
    local NOTE="$1" TURNS="$2" SYS OUT SLOG="${STATE_PREFIX}-stale-judge-$$.log"
    SYS="You are the staleness gate on one held note (specs/wake-queue.md rule 27b).
The assistant wrote the note below during a busy conversation; it was held
rather than spoken, and it is now about to be delivered as if it were news.
Under it is what has actually been said between her and the user since the
note was written.

One question: has the substance of this note already reached him, or has it
been overtaken by what happened since? A note announcing a result he has
since been told, or speaking to a situation the conversation has since moved
past, must not arrive wearing the face of fresh news.

When uncertain, answer SAY — a real note lost is the worse failure. DROP only
when the record below plainly already covers the note's substance, or plainly
supersedes it.

Answer with exactly one line and nothing else:
DROP: <one line — what already covers or supersedes it>
SAY: <one line — why it is still news to him>"
    : > "$SLOG"
    { printf '=== THE HELD NOTE ===\n%s\n\n=== WHAT HAS BEEN SAID BETWEEN THEM SINCE IT WAS WRITTEN ===\n%s\n' \
        "$NOTE" "$TURNS" \
      | CLAUDE_CLASSIFY_STREAM=1 \
        CLAUDE_CLASSIFY_TIMEOUT="$WAKE_STALE_TIMEOUT" \
        claude_classify "$WAKE_STALE_MODEL" "$SYS"; } >"$SLOG" 2>&1 || true
    # The token ledger (specs/metrics.md rule 13), before the stream is
    # removed. The ambient login is the honest account hint, as the mirror's.
    token_ledger_record "$SLOG" stale-judge "$WAKE_STALE_MODEL" "" \
        "${CLAUDE_CONFIG_DIR:--}"
    # Judged structurally, off the CLI's own events — never by matching the
    # answer's words (account-fallback.md rule 15).
    if claude_stream_refusal "$SLOG" >/dev/null; then
        rm -f "$SLOG"
        return 1
    fi
    OUT="$(DESKCRAB_DEBUGLOG="$SLOG" "$LIB_DIR/extract-response" 2>/dev/null)"
    rm -f "$SLOG"
    OUT="$(printf '%s\n' "$OUT" | tr -d '\r' | grep -m1 -E '^(SAY|DROP)\b')" \
        || return 1
    printf '%s\n' "$OUT"
}

# The gate itself, run at fire time before the wake session exists. Armed by
# the STAMP, not the booker: any autonomous booking whose reason carries the
# hold stamp gets the same judgement, whoever wrote it — hot-hold stamps
# today, and any future holder that stamps is covered without another gate.
# Returns 0 only when the note was positively judged stale and dropped — the
# caller then ends the wake without a session; every other path, the unstamped
# reason included, returns 1 and the wake proceeds exactly as before.
wake_stale_note_drop() {  # reads WAKE_REASON, WAKE_ID, WAKE_KIND
    [ "${WAKE_STALE_GATE:-1}" = "1" ] || return 1
    local STAMP EPOCH NOTE TURNS VERDICT WHY
    STAMP="$(printf '%s' "${WAKE_REASON:-}" \
        | grep -oE "$WAKE_HELD_STAMP_RE" | tail -n1)"
    [ -n "$STAMP" ] || return 1
    STAMP="${STAMP#held at }"
    EPOCH="$(date -d "$STAMP" +%s 2>/dev/null)" || EPOCH=""
    case "$EPOCH" in ''|*[!0-9]*)
        stale_check_log "a stamp that would not parse ($STAMP) — delivered unjudged"
        return 1 ;;
    esac
    # The note alone, out of its wrapper: the judge reads the words that
    # would be spoken, not the hold's own framing.
    NOTE="${WAKE_REASON#"$WAKE_HELD_REASON_PREFIX"}"
    NOTE="${NOTE# }"
    NOTE="${NOTE% — held at *}"
    TURNS="$(wake_turns_since "$EPOCH")" || TURNS=""
    if [ -z "$(printf '%s' "$TURNS" | tr -d '[:space:]')" ]; then
        # Nothing has been said since the note was written, so nothing can
        # have gone stale — the judge is never called (rule 27b's bound).
        stale_check_log "nothing said since $STAMP — the judge was never called"
        return 1
    fi
    if ! VERDICT="$(wake_stale_judge "$NOTE" "$TURNS")"; then
        stale_check_log "the staleness judge failed or timed out — the note is delivered rather than lost"
        return 1
    fi
    case "$VERDICT" in
        DROP*)
            WHY="${VERDICT#DROP}"; WHY="${WHY#:}"; WHY="${WHY# }"
            [ -n "$WHY" ] || WHY="the conversation since already covers it"
            # Silent to him, loud to the record: the drop lands on the
            # sessions log and the day journal (the registration's exit trap
            # writes both), on the wake ledger as its own action, and on the
            # gate's trace — a note that vanishes with no account of itself
            # is the empty-reply hole wearing a new face.
            session_register "autonomous wake"
            SESSION_USER_TEXT="${WAKE_REASON:-}"
            session_outcome "(stale — held note dropped unspoken; judged against the conversation since $STAMP: $WHY) $NOTE"
            wake_ledger dropped-stale "${WAKE_ID:-?}" "${WAKE_KIND:-event}" \
                "$NOTE" stale-judge
            stale_check_log "DROP: $WHY"
            return 0 ;;
        *)
            stale_check_log "SAY — the note still stands: ${VERDICT#SAY}"
            return 1 ;;
    esac
}

deskcrab_is_builder_context() {
    # The exported role is the ordinary path. The cgroup check is the belt
    # under it: a detached job must not become an interactive speaker merely
    # because a child shell dropped an environment variable.
    [ "${DESKCRAB_ENG_ROLE:-}" = "builder" ] \
        || [ -n "${DESKCRAB_JOB_ID:-}" ] \
        || grep -Eq '(^|/)deskcrab-job-[^/]+\.service($|/)' \
            /proc/self/cgroup 2>/dev/null
}

deskcrab_is_direct_job_runner_child() {
    # The runner's completion notification is the one presentation-adjacent
    # operation a detached job legitimately causes.  Authorise that edge by
    # process provenance, not by an environment flag the builder inherits (or
    # can invent): when job-runner itself execs `crab wake-at`, its command is
    # the direct parent.  A builder's Bash tool has a shell/tool process in
    # between and therefore cannot pass this check by merely spelling
    # `--by job-runner`.
    [ -r "/proc/$PPID/cmdline" ] || return 1
    tr '\0' '\n' < "/proc/$PPID/cmdline" 2>/dev/null \
        | grep -Eq '(^|/)job-runner$'
}

deskcrab_require_persona_source() {
    deskcrab_is_builder_context || return 0
    echo "DeskCrab: a detached builder cannot create a user or Beatrice turn. Write the job log/checkpoint or engineering record; a labeled completion wake will surface the result." >&2
    return 64
}

run_claude_wake() {
    deskcrab_require_persona_source || return $?
    session_register "autonomous wake"
    # Nobody spoke, so the day journal's "user" slot carries the wake's
    # agenda — an event's reason reads back as what the wake was about. An
    # own-time return has no reason by definition, so it stamps its marker
    # instead (specs/wake-queue.md rule 40f): the journal is where a month of
    # these is read back to tell lived choices from administrative growth,
    # and an empty user slot cannot be told apart from anything.
    SESSION_USER_TEXT="${WAKE_REASON:-}"
    [ "${WAKE_OWN_TIME:-0}" = "1" ] && \
        SESSION_USER_TEXT="(own time — a quiet hour, hers to choose)"
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
    local WAKE_T0
    WAKE_T0="$(date +%s)"
    # A wake is work too. Register its live activity from the same runtime
    # fact as a desk turn, with no classifier and no awaited face process.
    export DESKCRAB_FACE_TURN="wake-$$-$(date +%s%N)"
    face_touch activity considering
    wake_claude_run_chain
    local CLAUDE_STATUS="$WAKE_CLAUDE_STATUS"
    printf '{"type":"result"}\n' >> "$DEBUGLOG"
    # The token ledger (specs/metrics.md rule 13), before any early return
    # below can skip it and before the stream can be pruned.
    token_ledger_record "$DEBUGLOG" wake "$WAKE_MODEL" "$WAKE_EFFORT" \
        "${WAKE_CHAIN_ACCT:-}" "$(( $(date +%s) - WAKE_T0 ))"

    # Declare a wake's writes before the self-change watcher judges the burst
    # it saw.
    notice_own_writes

    local RESPONSE
    RESPONSE=$(extract_response)
    # Generation has ended on every branch below. The mood update, when the
    # wake succeeded, is dispatched separately and never delays this return.
    face_touch activity resting

    # A wake that never got a model does not get a voice. When the CLI fails
    # before any real work (session limit, auth, network), the error text
    # comes back looking like a reply — and treated as one it was appended to
    # the conversation as the assistant's own words, chased by the promise
    # audit, and spoken aloud at the desk ("You've hit your session limit…").
    # Journal the failure instead, and re-book a wake that had a purpose so
    # its agenda survives to a retry after the outage clears.
    #
    # The cut is the same failure wearing work clothes (specs/account-fallback
    # rule 12a, wake-queue rule 23): the walk above already rode any cut to
    # the next login, so a cut still standing on the WHOLE log means every
    # account was tried and the limit had the last word. Judged at offset 0 on
    # purpose — a genuine text block from any later account clears it.
    local LIMIT_CUT
    LIMIT_CUT="$(claude_stream_limit_cut "$DEBUGLOG")" || LIMIT_CUT=""
    if wake_stream_failed || [ -n "$LIMIT_CUT" ]; then
        if [ -n "$LIMIT_CUT" ]; then
            session_outcome "(wake failed — session-limit cut it off mid-run, every account tried — claude exit $CLAUDE_STATUS: $(utf8_trim "$LIMIT_CUT" 160))"
        else
            session_outcome "(wake failed before the model ran — claude exit $CLAUDE_STATUS: $(utf8_trim "$RESPONSE" 160))"
        fi
        # A free slot, not a flat half hour: an outage fails every wake it
        # touches, and a fixed retry stacks all of them onto the same second
        # (wake_book does the spacing, under the booking lock).
        #
        # NO kind gate. This used to be `[ -n "$WAKE_KIND" ] &&`, so the one
        # shape of wake that most needed rescuing — the one whose kind had been
        # blanked by the arity bug — was the one shape the outage retry refused
        # to re-book. Its agenda died with the outage.
        #
        # A walk the LIMITS refused outright — every attempt a refusal or
        # cut, every account cooling for this wake's model — does not re-book
        # into the drought it just measured: the delay is the soonest
        # cooldown expiry covering the model, plus jitter, capped
        # (specs/wake-queue.md rule 23a; the 2026-08-15 morning's
        # eight-second refusal/re-book ping-pong). The judgement is the
        # walk's OWN per-attempt record, never a re-grep of the whole log:
        # judged there, an earlier account's refusal plus a later account's
        # silent network death read as a drought, and a mixed walk waited on
        # cooldowns it never measured. Every other outage keeps the free
        # half-hour slot — nothing measured says when a network death clears.
        local WAKE_RETRY_IN="$WAKE_OUTAGE_RETRY"
        if [ "${WAKE_CHAIN_ALL_LIMITED:-0}" -eq 1 ]; then
            WAKE_RETRY_IN="$(claude_limit_rebook_delay "$WAKE_MODEL")"
        fi
        "$SCRIPT_DIR/crab" wake-at --by "${WAKE_BOOKED_BY:-outage-retry}" \
            "${WAKE_RETRY_IN}s" "${WAKE_KIND:-scheduled}" "${WAKE_REASON:-}" >/dev/null
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
            # A successful tool-only wake still changes what she is doing.
            # Its trace is the completed-work half that a spoken reply would
            # otherwise provide to the detached mood updater.
            fire_face_mood "${WAKE_REASON:-$PROMPT_TEXT}" \
                "${TRACE:-completed a quiet wake without tool activity}"
            # A wordless wake is the case reinforcement most needs to see, not
            # the one to skip: its entire output is the work. The trace is the
            # evidence, so the judge runs on it. A crashed wake still just
            # consumes the sidecar — there is no turn to judge.
            # The sidecar is NOT removed here — the detached judge reads it and
            # consumes it itself; deleting it now would race the child to its
            # own evidence.
            fire_memory_judge --wake "${WAKE_REASON:-}" "" "$TRACE"
        else
            # Rule 24a (specs/wake-queue.md): this is the outage branch above
            # in different clothes. The CLI died before it could write its own
            # error shape — a launcher crash or stall reap — so
            # wake_stream_failed saw no error event
            # and fell through to here, which used to journal the death and
            # silently lose the agenda. The launcher's last words go into the
            # journal line (a bare exit code explains nothing), and the wake
            # re-books exactly as the outage branch does, kind gate and all.
            local LAST_WORDS
            LAST_WORDS="$(wake_stream_last_words)"
            session_outcome "(wake produced no output — claude exit $CLAUDE_STATUS${LAST_WORDS:+: $LAST_WORDS})"
            "$SCRIPT_DIR/crab" wake-at --by "${WAKE_BOOKED_BY:-outage-retry}" \
                1800s "${WAKE_KIND:-scheduled}" "${WAKE_REASON:-}" >/dev/null
            rm -f "${STATE_PREFIX}-memory-injected-$$.json"
        fi
        return 0
    fi

    # The journal keeps a genuine reply in full even when every gate below
    # completes the wake silently.
    # It is NOT appended to the conversation here — see the delivery section
    # at the end of this function.
    #
    # First, the pre-speech mirror on the whole draft (specs/speech-output.md
    # rule 44): a wake's reply is complete before anything is spoken or
    # shown, so a line that trips her claudism list comes back to her here,
    # once, and everything below — journal, gates, speakers, bubble — sees
    # the reply she settled on. Fails open to the draft as written.
    RESPONSE="$(claudism_mirror_direct wake "$RESPONSE")"
    SESSION_REPLY="$RESPONSE"

    local SPOKEN DISPLAY_PART TRACE SILENT_NOTE="" QUIET_BUBBLE=""
    # The one delivery split every path shares (specs/turn-pipeline.md rule
    # 16b): the voiced half, the display half, and the (quiet) marker — the
    # ONE authorized silence format (his standing instruction, 2026-08-07). A
    # wake with something worth leaving but not worth voicing writes
    # "(quiet) <thoughts>"; the thoughts are SHOWN as a "(quiet) …" bubble,
    # never the speakers, the square-bracket spelling normalised, the bare
    # marker plain silence. All of that is the split's job now, one
    # implementation for the desk, the phone and this path alike.
    reply_delivery_split "$RESPONSE" || true
    SPOKEN="$REPLY_SPOKEN"
    DISPLAY_PART="$REPLY_DISPLAY"
    # QUIET_BUBBLE carries the always-visible promise past the
    # nothing-to-deliver gate below, which otherwise sees an empty SPOKEN and
    # returns before the bubble is appended.
    QUIET_BUBBLE="$REPLY_QUIET"
    [ -n "$REPLY_QUIET" ] && SILENT_NOTE="$REPLY_QUIET_THOUGHT"
    RESPONSE="$REPLY_TEXT"

    # The same backstop for the other way silence gets narrated: a whole reply
    # that is nothing but "Nothing to say." / "No message." / "Nothing to
    # report." — or, since 2026-08-10, the same sentence wearing a reason:
    # "No message — the other session already said its piece." (spoken aloud
    # at the desk more than once before the gate learned the two-clause
    # shape; specs/wake-queue.md rule 29a, specs/speech-output.md MAJ-4).
    # A wake with nothing to say must produce ZERO output, and that
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
    # audit's own follow-up wakes — both classes — are recognised by their
    # reasons and skipped, or each audit wake would audit itself into an
    # endless chain.
    promise_audit_own_reason "${WAKE_REASON:-}" ||
        fire_promise_audit --wake "${WAKE_REASON:-}" "$RESPONSE"
    # The claudism capture rides the same moment, and unconditionally: a
    # wake spoken to nobody is still her voice, audit follow-ups included.
    fire_claudism_capture wake "$RESPONSE"
    # And the promise checker, on every wake — its own follow-ups included:
    # a claim of work with nothing in the tool record behind it is a false
    # record whoever was listening, and the checker judges fresh words
    # against fresh evidence, never the agenda (turn-pipeline rule 32a).
    fire_promise_check wake "$RESPONSE"
    # Wakes shape the standing mood whether or not a later delivery gate
    # keeps their words quiet. This is detached, just like the desk path.
    fire_face_mood "${WAKE_REASON:-$PROMPT_TEXT}" "$RESPONSE"
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
    # A detached job's return takes NEITHER of the next two exits
    # (specs/wake-queue.md rule 27d, jobs.md rule 7c). The completion wake is
    # the job's ONLY channel back to him, and both exits were measured losing
    # it on 2026-08-25: the 02:06 clock build's spoken result was sent to the
    # five-minute hot-hold by a turn in flight and he asked before it fired,
    # and the 09:57 install build's was muted for a busy moment and returned
    # with no re-booking at all — the news existed in the journal alone. So a
    # busy moment DELAYS job news and never consumes it: wait here, bounded,
    # for the utterance, recording or in-flight reply to clear and deliver
    # the words already in hand the moment it does; when the wait runs dry,
    # the ORIGINAL reason goes back through the queue's one door under the
    # ORIGINAL booker, stamped once for rule 27b, so the comeback is the same
    # news wearing the same provenance — delayed again if it must be, dropped
    # never. Recognised by the booking's provenance (--by job-runner), never
    # by reading the reply — rule 29's boundary holds.
    if wake_carries_job_news && { interactive_turn_in_flight || user_busy; }; then
        if wake_job_news_moment; then
            : # the moment passed — the news is delivered below, promptly, once
        elif wake_job_news_rebook; then
            session_outcome "(held — job news met a moment that outlasted the wait; re-booked whole under the job-runner identity, coming back in $(( WAKE_JOB_NEWS_RETRY / 60 ))min) ${SPOKEN:-${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}}"
            return 0
        else
            session_outcome "(held — job news met a busy moment; ${WAKE_JOB_NEWS_REFUSAL:-the comeback booking failed} — the news is in this journal only) ${SPOKEN:-${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}}"
            return 0
        fi
    # A turn of HIS is in flight right now — a desk or phone reply owed and
    # not yet delivered, read from the delivery queue's own tickets
    # (specs/wake-queue.md rule 27c). Words landing in that window land in
    # the answer's slot whatever they say: the 2026-08-10 ordering incident
    # is what a reply arriving in another message's slot does to a
    # conversation, and a wake's aside does it from outside the queue. Held
    # WHOLE — the spoken half included, unlike the hot hold below — because
    # this gate reads tickets and pids, never the reply: it decides WHEN,
    # not WHETHER (rule 29's boundary), and the words go back through the
    # queue's one door with the held stamp, so the comeback meets rule 27b's
    # staleness gate in a quiet minute and is spoken unless the record
    # proves the exchange already covered it. The work is not suppressed —
    # journal, audit and judges all ran above; only the delivery moves.
    elif interactive_turn_in_flight; then
        if wake_hold_for_heat "${SPOKEN:-${SILENT_NOTE:-$DISPLAY_PART}}"; then
            session_outcome "(held — a turn was in flight, nothing spoken and nothing shown; coming back in $((WAKE_HOT_RETRY / 60))min) ${SPOKEN:-${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}}"
        else
            session_outcome "(held — a turn was in flight; ${WAKE_HOLD_REFUSAL:-the comeback booking failed} — the note is in this journal only) ${SPOKEN:-${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}}"
        fi
        return 0
    # The user is mid-something a wake must not interrupt: a recording, speech
    # in flight, or a meeting holding the mic. Same treatment, same reason — a
    # window over the meeting he is in is an interruption too. Checked here, at
    # the last moment before delivery, because a wake that started in a quiet
    # room may end mid-meeting. Said in those words for every shape of output,
    # for the same reason the night's line is: a display-only wake held here did
    # not have nothing to say, and its journal line is the only place that can
    # say so.
    elif user_busy; then
        session_outcome "(muted — user was mid-interaction) ${SPOKEN:-${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}}"
        return 0
    fi
    # And the same question one level up from the hardware: is the
    # CONVERSATION hot (wake-queue.md rule 27a)? user_busy asks whether the
    # microphone is open or a voice is on the speakers at this instant, and
    # between two messages of an argument the honest answer to both is no.
    # 2026-08-10, 12:32:12: a quiet chess note — "Lost browser-006 — mated by
    # a promoted pawn while my knights admired themselves" — landed in the
    # conversation between "stop assuming I'm wrong" and "I'm reporting a
    # genuine bug", in a lull of a few seconds, with every existing gate
    # correctly saying the room was quiet.
    #
    # NARROW ON PURPOSE, and the narrowness is rule 29's: nothing here judges
    # what the reply SAYS. It judges only the moment, and only for output she
    # already decided not to speak — a quiet bubble, a display section. A wake
    # that chose to open its mouth has something it thinks is worth saying out
    # loud, and that choice still stands whatever the clock says. What is held
    # is a note, and a note keeps.
    #
    # Held, not dropped: the words go back through the queue's one door as an
    # event wake past the heat, so she comes back to it in a quiet minute and
    # decides again with the conversation in front of her.
    if [ -z "$(printf '%s' "$SPOKEN" | tr -d '[:space:]')" ] && convo_hot; then
        # The booking FIRST, the record after — this line used to be written
        # before the booking was even attempted, so at the cap the journal
        # promised a comeback while the queue had refused to book one. And
        # the hold carries the real content: a display-only wake's note IS
        # the display section it built (clipped by the holder), because the
        # comeback wake's reason is the only place the words survive — the
        # literal words "a display section it built" hold nothing.
        if wake_hold_for_heat "${SILENT_NOTE:-$DISPLAY_PART}"; then
            session_outcome "(held — the conversation was hot, nothing shown; coming back in $((WAKE_HOT_RETRY / 60))min) ${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}"
        else
            session_outcome "(held — the conversation was hot, nothing shown; ${WAKE_HOLD_REFUSAL:-the comeback booking failed} — the note is in this journal only) ${SILENT_NOTE:-${DISPLAY_PART:+a display section was built and held}}"
        fi
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
    local STREAM_LOG="${_TTS_STREAM_SOURCE:-}"
    if [ -z "$STREAM_LOG" ]; then
        claim_debuglog
        STREAM_LOG="$DEBUGLOG"
    fi
    _TTS_RECEIPT="${STATE_PREFIX}-speech-receipt-$$.txt"
    # A new turn is a new question — whatever silence was asked for last time
    # is spent. Cleared HERE rather than at `crab shutup` time so that only a
    # shutup DURING this turn suppresses the never-silent guarantee below.
    rm -f "$_TTS_RECEIPT" "$SHUTUP_MARKER"
    # The pre-speech mirror arms ONLY when this caller implements the answer
    # side (specs/speech-output.md rule 39): _CLAUDISM_ARM is set by the desk
    # turn around this call, and an absent phrase list disarms everything.
    _CLAUDISM_FIRES_FILE=""
    if [ "${_CLAUDISM_ARM:-0}" = "1" ] && [ -f "$CLAUDISMS_FILE" ] \
            && [ -x "$LIB_DIR/claudism-mirror" ]; then
        _CLAUDISM_FIRES_FILE="${STATE_PREFIX}-claudism-fires-$$.jsonl"
        rm -f "$_CLAUDISM_FIRES_FILE" "$_CLAUDISM_FIRES_FILE".verdict-* \
            "$_CLAUDISM_FIRES_FILE.done" 2>/dev/null
    fi
    DESKCRAB_DEBUGLOG="$STREAM_LOG" DESKCRAB_PIPER_VOICE="$PIPER_VOICE" \
        DESKCRAB_PIPER_LENGTH_SCALE="${PIPER_LENGTH_SCALE:-}" \
        DESKCRAB_PIPER_SPEAKER="${PIPER_SPEAKER:-}" \
        DESKCRAB_TTS_FIXES="${TTS_FIXES:-}" \
        DESKCRAB_SPEECHLOCK="$SPEECHLOCK" \
        DESKCRAB_LIVE_SPEECH="$LIVE_SPEECH_FILE" \
        DESKCRAB_CLAUDE_LIMIT_RE="$CLAUDE_LIMIT_RE" \
        DESKCRAB_RETRYABLE_ERROR_RE="$CODEX_CAPACITY_RE" \
        DESKCRAB_SPEECH_LOG="$SPEECH_LOG" \
        DESKCRAB_SPEECH_RECEIPT="$_TTS_RECEIPT" \
        DESKCRAB_CLAUDISMS="${_CLAUDISM_FIRES_FILE:+$CLAUDISMS_FILE}" \
        DESKCRAB_CLAUDISM_FIRES="${_CLAUDISM_FIRES_FILE:-}" \
        DESKCRAB_CLAUDISM_FLAGS="${_CLAUDISM_FIRES_FILE:+$CLAUDISM_FLAGS_DIR}" \
        DESKCRAB_CLAUDISM_MIRROR_TIMEOUT="$CLAUDISM_MIRROR_TIMEOUT" \
        DESKCRAB_METRICS_FILE="$([ "${TURN_METRICS:-1}" = 1 ] && printf '%s' "$METRICS_DIR/$(date +%F).log")" \
        DESKCRAB_METRICS_PID="$$" \
        DESKCRAB_METRICS_KIND="${SESSION_KIND:-desk}" \
        DESKCRAB_FACE_SOCKET="$([ "${FACE_ENABLED:-0}" = 1 ] && printf '%s' "$FACE_SOCKET")" \
        DESKCRAB_FACE_TURN="${DESKCRAB_FACE_TURN:-}" \
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

# Take back a voice whose moment has passed (specs/turn-pipeline.md rule 15e).
# The streamer speaks sentence by sentence as the model writes, so by the time
# a turn learns it has been superseded some of the reply may already be on its
# way to the speakers. This stops the rest of it.
#
# OUR OWN streamer and nothing else. Not `stop_tts`, which pkills every piper
# and aplay on the box and would cut another turn off mid-sentence; not the
# shutup marker, which is shared state and would stand the never-silent
# guarantee down for whichever turn is speaking next. The same discipline as
# "no process-wide kill of any prior streamer when a turn starts", for the
# same reason: this is one turn's voice, not the machine's.
turn_hold_voice() {
    _TURN_HELD_SPOKEN_CHARS=0
    [ -n "${_TTS_STREAMER_PID:-}" ] || return 0
    kill "$_TTS_STREAMER_PID" 2>/dev/null
    wait_tts_streamer
    # And retract the notice, so the next session does not regroup against
    # words that were never said.
    live_speech_end "$_TTS_STREAMER_PID"
    # How many characters actually reached the speakers before the kill. The
    # desk streamer speaks sentence by sentence AS the model writes, so by the
    # time a superseding pushback holds this reply he has usually already heard
    # most of it — a record that then calls it "not spoken" is the
    # records-lying failure that started the 2026-08-10 crisis wearing the held
    # marker. Read the receipt before removing it.
    if [ -f "${_TTS_RECEIPT:-}" ]; then
        _TURN_HELD_SPOKEN_CHARS="$(sed -n 's/^chars=//p' "$_TTS_RECEIPT" 2>/dev/null | head -1)"
        case "$_TURN_HELD_SPOKEN_CHARS" in ''|*[!0-9]*) _TURN_HELD_SPOKEN_CHARS=0 ;; esac
    fi
    rm -f "${_TTS_RECEIPT:-}" 2>/dev/null
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
    # …and a turn his newer message CUT (rule 15f) was silenced on purpose:
    # the belt for the race where the cut lands after this turn passed its
    # delivery gates — replaying the held fragment as a "broken speech path"
    # would say aloud exactly what the cut exists to keep off the speakers.
    turn_order_cut >/dev/null 2>&1 && { rm -f "${_TTS_RECEIPT:-}"; return 0; }
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
    DESKCRAB_DEBUGLOG="$DEBUGLOG" \
        DESKCRAB_CODEX_CAPACITY_RE="$CODEX_CAPACITY_RE" \
        "$LIB_DIR/extract-response" 2>/dev/null
}

# One CLI run for an interactive turn, APPENDING to $DEBUGLOG. $1 is a
# CLAUDE_CONFIG_DIR override ("" = the login already in the environment); every
# account in the list runs through here, so the flags cannot drift between the
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
        # See _wake_claude_run: every account is addressed explicitly, never
        # by whatever the environment happened to arrive holding.
        export CLAUDE_CONFIG_DIR="$CONFDIR"
        claude_profile_flags turn
        exec "$CLAUDE_BIN" -p --dangerously-skip-permissions \
            --model "${MODEL:-$CLAUDE_MODEL}" --effort "$EFFORT" \
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

# The interactive walk itself, factored out of claude_generate so the dispute
# fallback (specs/account-fallback.md rule 10a) can run it a second time at
# the ordinary model without a second copy of the loop. Reads MODEL / EFFORT /
# TURN_DEADLINE / DEBUGLOG from the caller's scope (bash dynamic scoping, same
# as _generate_claude_run), selects for MODEL (rule 10), and leaves three
# facts behind: GENERATE_WALK_ACCT, the last account it actually ran (the
# token ledger's hint); GENERATE_WALK_REFUSED, set only when EVERY offered
# account refused or was cut; GENERATE_WALK_ABANDONED, set when the wall
# clock ended the walk with accounts still unoffered.
_generate_claude_walk() {
    local ACCT CONFDIR PREV="" ATT=0 REFUSAL WALK_CUTF=""
    GENERATE_WALK_ACCT=""
    GENERATE_WALK_REFUSED=""
    GENERATE_WALK_ABANDONED=""
    CLAUDE_WATCH_CUT=""
    [ "${TURN_INTERRUPT:-1}" = "1" ] && WALK_CUTF="$(_turn_order_cut_file 2>/dev/null)" || WALK_CUTF=""
    for ACCT in $(claude_accounts "$MODEL"); do
        # A cut turn boots no CLI at all (rule 15f): the marker can land in
        # the seam between two attempts — or before the first — and a walk
        # that pressed on would speak for a question he has already moved
        # past. Not a refusal: the walk simply stops, and the caller's cut
        # branch does the bookkeeping.
        if [ -n "$WALK_CUTF" ] && [ -s "$WALK_CUTF" ]; then
            CLAUDE_WATCH_CUT=1
            GENERATE_WALK_REFUSED=""
            break
        fi
        GENERATE_WALK_ACCT="$ACCT"
        CONFDIR="$(claude_account_dir "$ACCT")"
        [ -z "$PREV" ] || claude_swap_announce "$PREV" "$ACCT"
        # This attempt's own bytes begin here. Judging the whole accumulated
        # log instead let one account's refusal condemn the next account's
        # ordinary network failure and cool an account that had refused
        # nothing.
        ATT="$(wc -c < "$DEBUGLOG" 2>/dev/null || echo 0)"
        case "$ATT" in ''|*[!0-9]*) ATT=0 ;; esac
        _generate_claude_run "$CONFDIR"
        # The run ended because he spoke over it (rule 15f): the walk ends
        # with it — a limit-shaped tail in a killed run's log is the kill
        # talking, never a refusal to ride to the next account.
        if [ -n "${CLAUDE_WATCH_CUT:-}" ]; then
            GENERATE_WALK_REFUSED=""
            break
        fi
        # As on the wake walk: a refusal OR a mid-flight cut moves to the next
        # account at once (specs/account-fallback.md rule 12a). The streamer is
        # already holding the synthetic refusal off the speakers, and the
        # retry's genuine reply appends behind it in the same log.
        REFUSAL="$(claude_stream_refusal "$DEBUGLOG" "$ATT")" \
            || REFUSAL="$(claude_stream_limit_cut "$DEBUGLOG" "$ATT")" \
            || { GENERATE_WALK_REFUSED=""; break; }
        GENERATE_WALK_REFUSED=1
        claude_limit_record "$ACCT" "$REFUSAL" "$MODEL"
        PREV="$ACCT"
        # No time left for another whole CLI boot and refusal.
        if [ "$TURN_DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$TURN_DEADLINE" ]; then
            claude_stream_note "chain-abandoned" "past this turn's wall clock"
            GENERATE_WALK_ABANDONED=1
            break
        fi
    done
}

# One turn of generation: prompt in, response text out. No speech, no windows,
# no conversation writes — every caller (desktop, wake, remote) layers its own
# output on top of this. The stream still lands in DEBUGLOG, so a TTS streamer
# started beforehand speaks in parallel exactly as it always did.
claude_generate() {
    local TEXT="$1" EFFORT="${2:-$CLAUDE_EFFORT}"
    # Pushback turns get her best attention, not her cheapest. specs/dispute-turn.md
    # rules 10-13: on 2026-08-10 the argue-gaslight spiral ran entirely on the
    # voice loop's economy settings; the turns where being wrong costs the
    # most were the ones bought at the lowest price. The dispute frame joins
    # the prompt (PROMPT_DISPUTE reaches build_system_prompt through the
    # subshell), effort rises to DISPUTE_EFFORT unless the caller already
    # asked for more, and DISPUTE_MODEL (when set) takes the turn — the conf
    # points it at the strongest builder model.
    local MODEL="$CLAUDE_MODEL" PROMPT_DISPUTE=""
    if dispute_detect "$TEXT"; then
        PROMPT_DISPUTE=1
        [ -n "${DISPUTE_MODEL:-}" ] && MODEL="$DISPUTE_MODEL"
        case "$EFFORT" in
            low|medium) EFFORT="${DISPUTE_EFFORT:-high}" ;;
        esac
        turn_metric dispute "pushback detected — model $MODEL, effort $EFFORT"
    fi
    local SYSTEM_PROMPT
    SYSTEM_PROMPT="$(build_system_prompt)"
    turn_metric prompt-built "${#SYSTEM_PROMPT} bytes"

    CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")}"
    # The log is claimed by truncating it ONCE, here, and every run of this
    # turn APPENDS. Truncating for a retry instead would strand the cursor of
    # the TTS streamer that is mid-tail on this very file.
    #
    # Accounts known dry are skipped outright: a doomed attempt is a whole CLI
    # boot and refusal in front of every reply, the exact seconds a voice cannot
    # afford. Each refusal cools its account and moves to the next; the
    # streamer rides through the refusals (it is told how many retries are still
    # to come) and extract-response drops them whenever a genuine reply follows
    # in the same log.
    : > "$DEBUGLOG"
    # One wall clock for the WHOLE walk, handed down to each run's watchdog.
    # Per-account timeouts would still let a three-account walk run for three
    # times as long as anyone is willing to stand there.
    local TURN_DEADLINE=0
    [ "${TURN_CHAIN_TIMEOUT:-0}" -gt 0 ] \
        && TURN_DEADLINE=$(( $(date +%s) + TURN_CHAIN_TIMEOUT ))
    local GEN_T0
    GEN_T0="$(date +%s)"
    turn_metric gen-start
    # The engine follows the model name (specs/model-backends.md). Codex has
    # one login, so a limit never walks accounts: refused, it records the
    # cooldown and the ordinary Claude walk takes the turn at the fallback
    # model (rule 12); already cooling, the walk takes it straight away
    # (rule 13). A transient capacity failure before genuine reply text
    # retries the same Codex model here, without entering that walk or cooling
    # the next independent Codex run.
    GENERATE_WALK_ACCT=""; GENERATE_WALK_REFUSED=""; GENERATE_WALK_ABANDONED=""
    local RUN_CLAUDE_WALK=1
    if [ "$(model_backend "$MODEL")" = "codex" ]; then
        local CODEX_OFF CODEX_REFUSAL CODEX_CAPACITY
        local CODEX_CAPACITY_RETRY=0 CODEX_CAPACITY_MAX="$CODEX_CAPACITY_RETRIES"
        case "$CODEX_CAPACITY_MAX" in ''|*[!0-9]*) CODEX_CAPACITY_MAX=2 ;; esac
        if ! codex_available; then
            claude_stream_note "codex-cooling" \
                "codex is $(codex_unavailable_why) — the Claude walk takes the turn"
            MODEL="$(codex_fallback_model)"
            EFFORT="$(claude_effort_clamp "$EFFORT")"
        else
            while :; do
                CODEX_OFF="$(wc -c < "$DEBUGLOG" 2>/dev/null || echo 0)"
                case "$CODEX_OFF" in ''|*[!0-9]*) CODEX_OFF=0 ;; esac
                _codex_stream_run turn "$MODEL" "$EFFORT" "$TEXT"
                GENERATE_CLAUDE_STATUS=$CODEX_RUN_STATUS
                if CODEX_CAPACITY="$(codex_stream_capacity "$DEBUGLOG" "$CODEX_OFF")"; then
                    if [ "$CODEX_CAPACITY_RETRY" -lt "$CODEX_CAPACITY_MAX" ]; then
                        CODEX_CAPACITY_RETRY=$(( CODEX_CAPACITY_RETRY + 1 ))
                        claude_stream_note "codex-capacity-retry" \
                            "codex server capacity was unavailable — retrying the same model ($CODEX_CAPACITY_RETRY/$CODEX_CAPACITY_MAX)"
                        sleep "$CODEX_CAPACITY_RETRY_DELAY" 2>/dev/null || sleep 1
                        continue
                    fi
                    claude_stream_note "codex-capacity-exhausted" \
                        "codex server capacity stayed unavailable after $(( CODEX_CAPACITY_RETRY + 1 )) attempts"
                    RUN_CLAUDE_WALK=""
                elif CODEX_REFUSAL="$(codex_stream_refusal "$DEBUGLOG" "$CODEX_OFF")"; then
                    codex_limit_record "$CODEX_REFUSAL"
                    claude_stream_note "codex-limit" \
                        "codex refused — the Claude walk takes the turn"
                    [ "${SESSION_KIND:-}" = "autonomous wake" ] || notify-send -t 8000 \
                        -h string:x-dunst-stack-tag:deskcrab-account "$NOTIFY_NAME" \
                        "codex is over its limit — answering on Claude" 2>/dev/null
                    MODEL="$(codex_fallback_model)"
                    EFFORT="$(claude_effort_clamp "$EFFORT")"
                else
                    RUN_CLAUDE_WALK=""
                fi
                break
            done
        fi
    fi
    [ -n "$RUN_CLAUDE_WALK" ] && _generate_claude_walk
    # A conversation turn must never die because the premium model is dry
    # while the ordinary one works (specs/account-fallback.md rule 10a).
    # Exactly when the dispute machinery raised the model above CLAUDE_MODEL
    # and EVERY offered account refused at that model — never on a genuine
    # answer, an ordinary failure, or a walk the wall clock abandoned — the
    # walk re-runs once at the loop's own model and effort, dispute frame
    # still in the prompt. On 2026-08-15 a dispute turn died over the premium
    # model's per-account allowance at 09:52 while the ordinary model worked
    # fine on the same logins. At most once: the re-run sets MODEL to
    # CLAUDE_MODEL, so the condition cannot hold a second time — and the job
    # path is untouched, a builder's model is never downgraded (jobs.md rule
    # 5a).
    if [ -n "$GENERATE_WALK_REFUSED" ] && [ -z "$GENERATE_WALK_ABANDONED" ] \
            && [ -n "$PROMPT_DISPUTE" ] && [ "$MODEL" != "$CLAUDE_MODEL" ]; then
        if [ "$TURN_DEADLINE" -gt 0 ] && [ "$(date +%s)" -ge "$TURN_DEADLINE" ]; then
            # The wall clock is asked again HERE, immediately before the
            # fallback boots (specs/account-fallback.md rule 10a). The
            # walk's own in-loop check runs only after each recorded
            # refusal, so a deadline that lapses in the seam between the
            # last refusal and this branch would boot a walk the turn has
            # no time to hear. A lapsed deadline skips the fallback and the
            # turn reports the outage it measured — as today's, not as a
            # second walk's.
            claude_stream_note "dispute-fallback-skipped" "past this turn's wall clock"
        else
            claude_stream_note "dispute-model-fallback" \
                "dispute at the ordinary model — the premium one is dry everywhere"
            [ "${SESSION_KIND:-}" = "autonomous wake" ] || notify-send -t 8000 \
                -h string:x-dunst-stack-tag:deskcrab-account "$NOTIFY_NAME" \
                "dispute at the ordinary model — the premium one is dry everywhere" 2>/dev/null
            MODEL="$CLAUDE_MODEL"
            EFFORT="$CLAUDE_EFFORT"
            # The loop's own model can itself be a codex name now
            # (specs/model-backends.md rule 12) — and this branch exists
            # precisely because the raised model is dry, so the re-run must
            # land on the Claude walk, never back on the engine that refused.
            if [ "$(model_backend "$MODEL")" = "codex" ]; then
                MODEL="$(codex_fallback_model)"
                EFFORT="$(claude_effort_clamp "$EFFORT")"
            fi
            turn_metric dispute-fallback "premium model dry everywhere — model $MODEL, effort $EFFORT"
            _generate_claude_walk
        fi
    fi

    # Guarantee the TTS streamer always receives a stop signal. claude normally
    # ends its stream with a {"type":"result"} line, but if it crashed, was
    # killed, or got rate-limited mid-stream it may not — and without a result
    # event the streamer tails the log forever and the wait below never returns.
    # extract-response ignores a result line that has no "result" field, so this
    # terminator is harmless on the success path.
    printf '{"type":"result"}\n' >> "$DEBUGLOG"
    turn_metric gen-end "status $GENERATE_CLAUDE_STATUS"

    # The token ledger (specs/metrics.md rule 13): this one hook covers the
    # desk and the phone turn — every caller of this walk — parsing the
    # stream it just wrote, before anything can prune it.
    local TL_KIND
    case "${SESSION_KIND:-}" in
        "desktop turn") TL_KIND=turn ;;
        "phone turn")   TL_KIND=phone ;;
        *)              TL_KIND="${SESSION_KIND:-turn}" ;;
    esac
    token_ledger_record "$DEBUGLOG" "$TL_KIND" "$MODEL" "$EFFORT" \
        "$GENERATE_WALK_ACCT" "$(( $(date +%s) - GEN_T0 ))"

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

# --- The chore gate (specs/turn-pipeline.md rule 16c) -----------------------
# Nothing delivery puts on his screen may hand the user a command line to
# run: the chore becomes a detached job, its lines riding as the brief, and
# the displayed text names the job instead. The origin (2026-08-25): a night
# session ended its work as two command lines for the user — one of them,
# "Also unset: TIDY_CLAIMS_ROOTS", a statement that READ as an instruction —
# and he woke to a chore his own machine could have run.
#
# Scans ONLY the display half: that is the channel where a command renders as
# a thing to copy, and the voiced half may never be gated (speech-output's
# standing rule — and the desk has usually already spoken it). Detection is
# lib/chore-scan's, ONE implementation shared with the record gate
# (engineering-records.md rule 15), and deliberately narrow: assignment
# required, never just a command, so narration and quoted commands pass
# byte-identical. FAILS OPEN: a missing scanner or a refused dispatch cost
# the conversion, never the delivery — the reply goes out as written and the
# trace log says why. One dispatch per reply, through the door with its
# policy intact (queued while he is awake and a shelf stands, the block
# marker honoured).
chore_gate_log() {
    printf '%s\t%s\n' "$(date '+%F %T')" "$1" \
        >> "${STATE_PREFIX}-chore-gate.log" 2>/dev/null || true
}

chore_gate_pass() {  # <response> -> the response, displayed chores converted
    local RESPONSE="$1"
    if [ "${CHORE_GATE:-1}" != "1" ] || [ ! -x "$LIB_DIR/chore-scan" ]; then
        printf '%s\n' "$RESPONSE"
        return 0
    fi
    local DISPLAY
    DISPLAY="$(display_part "$RESPONSE")"
    if [ -z "$(printf '%s' "$DISPLAY" | tr -d '[:space:]')" ]; then
        printf '%s\n' "$RESPONSE"
        return 0
    fi
    local RANGES
    RANGES="$(printf '%s\n' "$DISPLAY" | "$LIB_DIR/chore-scan" chores 2>/dev/null)" \
        || RANGES=""
    if [ -z "$RANGES" ]; then
        printf '%s\n' "$RESPONSE"
        chore_gate_log "clean"
        return 0
    fi
    # The chore lines, flattened: they ride the job as its brief, so nothing
    # leaves his screen without landing somewhere durable.
    local CHORES
    CHORES="$(printf '%s\n' "$DISPLAY" | awk -v ranges="$RANGES" '
        BEGIN { n = split(ranges, R, "\n")
                for (i = 1; i <= n; i++) if (R[i] != "") {
                    split(R[i], ab, "-")
                    for (j = ab[1]; j <= ab[2]; j++) M[j] = 1 } }
        M[NR]' | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
    # The dispatch goes to a file, not a substitution, so JOB_START_ID
    # survives into this shell.
    local OUTF="${STATE_PREFIX}-chore-gate-out.$$" OUT="" ID="" RC=0
    job_start "Chore intercepted at delivery (specs/turn-pipeline.md rule 16c): my reply tried to hand the user this to do by hand. Do it from here instead, verify it, and report what you ran: $(printf '%.500s' "$CHORES")" \
        >"$OUTF" 2>&1 || RC=$?
    OUT="$(cat "$OUTF" 2>/dev/null)"
    rm -f "$OUTF"
    ID="$JOB_START_ID"
    if [ "$RC" != 0 ] || [ -z "$ID" ]; then
        chore_gate_log "fail-open (chore stays, no job): $(printf '%s' "$OUT" | tr '\n\t' '  ' | cut -c1-200)"
        printf '%s\n' "$RESPONSE"
        return 0
    fi
    local NOTICE="[chore intercepted — this was written as work for you to do by hand; detached job $ID now carries it${JOB_START_QUEUED:+, queued for the night}]"
    local NEWDISPLAY
    NEWDISPLAY="$(printf '%s\n' "$DISPLAY" | awk -v ranges="$RANGES" -v notice="$NOTICE" '
        BEGIN { n = split(ranges, R, "\n")
                for (i = 1; i <= n; i++) if (R[i] != "") {
                    split(R[i], ab, "-")
                    F[ab[1]] = 1
                    for (j = ab[1]; j <= ab[2]; j++) M[j] = 1 } }
        F[NR] { print notice; next }
        M[NR] { next }
        { print }')"
    # Reassemble around the delimiter. The half above it is the same bytes
    # that came in — only the display half was converted.
    local ABOVE
    ABOVE="$(printf '%s\n' "$RESPONSE" | sed -E '/^---DISPLAY---$/,$d')"
    printf '%s\n---DISPLAY---\n%s\n' "$ABOVE" "$NEWDISPLAY"
    chore_gate_log "fired: job $ID carries: $(printf '%.200s' "$CHORES")"
    return 0
}

# ---- The delivery split: ONE place decides what a finished reply delivers ---
# specs/turn-pipeline.md rule 16b. Every delivery path — desk, phone, wake —
# calls this once, above every sink it owns, and branches on the answer. The
# wake path used to be the only one that knew the quiet marker or the three
# shapes of empty; the desk streamed a "(quiet)" reply to the speakers
# marker-first, the phone synthesised the held thought into a clip, and a
# marker-only reply reached the chat as a bare "(quiet)" bubble.
#
# Sets, for the caller:
#   REPLY_EMPTY          1 when there is nothing to deliver anywhere — no
#                        text, whitespace only, or the bare quiet marker.
#                        The return status says the same: 0 deliver, 1 not.
#   REPLY_SPOKEN         the voiced half. Empty for a quiet reply BY
#                        DEFINITION — the never-silent guarantee reads this,
#                        so it can never fire on a held thought.
#   REPLY_DISPLAY        the display half, blanked when whitespace-only so a
#                        window is never opened over nothing.
#   REPLY_QUIET          1 when the quiet marker held the voice (the reply
#                        OPENS with it and carries a thought).
#   REPLY_QUIET_THOUGHT  that thought, flattened to one line for journals and
#                        hold bookings.
#   REPLY_TEXT           the conversation form: the normalised "(quiet) …"
#                        bubble (either input spelling, the thought passed
#                        through her replace table — speech-output rule 54)
#                        for a quiet reply, the response unchanged otherwise.
#   REPLY_SHOWN          what he actually receives in words: the voiced half,
#                        or the bubble form for a quiet reply. For journals,
#                        live-turn records and the phone's completion payload.
#
# Nothing here judges worth (speech-output's standing rule): the quiet marker
# is her own writing-time choice of silence, and emptiness is the absence of
# anything to deliver, not an opinion about it.
reply_delivery_split() {  # <response>  -> 0 deliver, 1 nothing to deliver
    local RESPONSE="$1" THOUGHTS
    # The chore gate (rule 16c) runs first, above every sink, so everything
    # below — the display half, the conversation form, the journal — sees
    # the converted text and never the instruction.
    RESPONSE="$(chore_gate_pass "$RESPONSE")"
    REPLY_EMPTY="" REPLY_QUIET="" REPLY_QUIET_THOUGHT=""
    REPLY_SPOKEN="$(spoken_part "$RESPONSE")"
    REPLY_DISPLAY="$(display_part "$RESPONSE")"
    REPLY_TEXT="$RESPONSE"
    [ -z "$(printf '%s' "$REPLY_SPOKEN" | tr -d '[:space:]')" ] && REPLY_SPOKEN=""
    [ -z "$(printf '%s' "$REPLY_DISPLAY" | tr -d '[:space:]')" ] && REPLY_DISPLAY=""
    # The quiet marker decides only when it OPENS the reply — the first
    # non-blank line. spoken_part has already kept any line-leading marker
    # off the voiced half wherever it appears.
    if printf '%s\n' "$RESPONSE" | grep -m1 -vE '^[[:space:]]*$' \
            | grep -qiE '^[[:space:]]*[[(]quiet[])]'; then
        THOUGHTS="$(printf '%s\n' "$REPLY_SPOKEN" \
            | sed -E 's/^[[:space:]]*[[(][Qq][Uu][Ii][Ee][Tt][])][[:space:]:—-]*//')"
        # Rule 54: the bubble is the one thing said with no gate on it — never
        # spoken, so the streamer's mirror never sees it, and the whole-draft
        # mirror fails open. Her replace table runs on it here.
        THOUGHTS="$(claudism_table_only quiet "$THOUGHTS")"
        REPLY_QUIET_THOUGHT="$(printf '%s' "$THOUGHTS" | tr '\n' ' ')"
        REPLY_SPOKEN=""
        if [ -n "$(printf '%s' "$THOUGHTS" | tr -d '[:space:]')" ]; then
            # A thought behind the marker is ALWAYS visible as a bubble (his
            # standing instruction, 2026-08-07); a bare marker stays plain
            # silence and earns nothing.
            REPLY_QUIET=1
            REPLY_TEXT="(quiet) $THOUGHTS"
            [ -n "$REPLY_DISPLAY" ] && REPLY_TEXT="$REPLY_TEXT
---DISPLAY---
$REPLY_DISPLAY"
        fi
    fi
    REPLY_SHOWN="$REPLY_SPOKEN"
    [ -n "$REPLY_QUIET" ] && REPLY_SHOWN="(quiet) $REPLY_QUIET_THOUGHT"
    if [ -z "$REPLY_SPOKEN$REPLY_DISPLAY$REPLY_QUIET" ]; then
        REPLY_EMPTY=1
        return 1
    fi
    return 0
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
# "today"), an optional silence-justification clause, and punctuation.
# Anything carrying real content alongside it ("Nothing to report on the
# build, but two tests fail") is not filler and is never touched. Muting one
# real reply is a worse failure than voicing one stray no-op, so every
# ambiguous case must fall through to speech.
#
# The justification clause is the second half the single-clause gate used to
# let through (specs/speech-output.md MAJ-4, closed 2026-08-10 after "No
# message — the other session already said its piece." was read aloud at the
# desk more than once): a reason FOR the silence, never a fact about the
# world. It is recognised on either side of the no-op core, and standing
# alone as the whole reply. The contract is specs/wake-queue.md rule 29a.
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
    # Filler is a sentence or two, never a paragraph. A long reply is content.
    # (Was 12 words when the gate knew only the single clause; the two-clause
    # shape — no-op core plus its excuse — runs longer, and every pattern
    # below is anchored whole, so the cap is a cheap bail, not the judgement.)
    [ "$(printf '%s\n' "$T" | wc -w)" -gt 24 ] && return 1

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
    CORE="$CORE|no (message text|reply text|message|messages|update|updates|news|report|reports|comment|comments|reply|response|output|note|notes|change|changes|word|words|text)( to (report|share|say|add|give|offer))?"
    CORE="$CORE|none|silence|silent|(all |still |everything |pretty )?(quiet|silent)|all clear|nada|zilch|n/a|nil"
    CORE="$CORE|(staying|stay|keeping|keep|remaining|remain) (quiet|silent)"
    CORE="$CORE|no need to (speak|talk|say anything|report)|standing by|holding my peace"
    # Not a sentence at all: the CLI's own stringified nothing. Measured on two
    # of three real wakes on 2026-08-07 — a wake that ended with no message text
    # arrived here as an assistant text block holding the literal word
    # "undefined", and the desk said it out loud. And on 2026-08-15, 01:07, a
    # wake with genuinely empty text arrived as the literal placeholder
    # "*(no message text)*" and the desk read the absence out as words — the
    # normalisation above has already stripped the brackets, so the bare
    # phrase families here and in the no-family above are the whole test.
    # Only the bare word counts; "the config value is undefined" is a real
    # sentence and speaks.
    CORE="$CORE|undefined|null|empty|blank|(empty|blank) (message|reply|response|text)"
    # The first person announcing her own prior speech (rule 29a, 2026-08-15:
    # "I've said my piece on that game twice already tonight", "I've said
    # everything I have about that game tonight", "I've nothing further on
    # that game tonight" — five in ninety seconds, two aloud). The lead-in
    # strip above has already removed the "I've"; the optional pronoun below
    # covers the forms it leaves. A topic phrase — "on that game", "about
    # it" — is allowed ONLY here and on the nothing-further family, never on
    # the plain nothing-to-say core: "Nothing to say about the backup" is a
    # fact about the backup, and it speaks. The topic is bounded: a pronoun,
    # or a determiner and at most two words, or a name-and-number ("browser
    # 012" is what "browser-012" becomes above).
    local TOPIC COUNT SELFSAID
    TOPIC='( (on|about|regarding) (it|that|this|him|her|them|(that|this|the|the same|my|his|her|its|their) [a-z0-9]+( [a-z0-9]+)?|[a-z]+ [0-9]+))?'
    COUNT='( (once|twice|thrice|again|already|(two|three|four|five|six|seven|eight|nine|ten|[0-9]+) times))*'
    SELFSAID="(i ((have|ve|had|d) )?)?((already|just) )?said (my (piece|bit|say)|everything( i (have|had|ve|d))?( to say)?|it( all)?|all (i|that i) (have|had)|what i (have|had)( to say)?|enough)"
    CORE="$CORE|nothing (else|new|more|further)( from me)?( (to|worth) (say|saying|report|reporting|add|adding|share|sharing|mention|mentioning|note|noting|flag|flagging|announce|announcing|update|updating|tell|telling|do))?$TOPIC"
    CORE="$CORE|$SELFSAID$COUNT$TOPIC$COUNT"
    TAIL='( (here|now|right now|today|tonight|yet|for now|at the moment|at present|from me|on my end|this time|this wake|either|though|really|so far))*'

    # The single clause: the whole utterance is the no-op.
    printf '%s\n' "$T" | grep -Eq "^($CORE)$TAIL\$" && return 0

    # The justification clause — a reason FOR the silence, never a fact about
    # the world. Four families, each anchored into the whole-line match below
    # so a trailing word of real content ("nothing has changed his mind",
    # "the other session said the tests were green, but…") breaks the match
    # and the reply speaks. Punctuation is already spaces, so "No message —
    # the other session already said its piece" arrives here as one flat line.
    local WHO OBJ ADV J_OTHER J_DONE J_CHANGE SINCE J_HEARD J_SELF J_REPEAT JUSTIFY ALONE CONN
    # …the other session already said it. WHO is only ever another voice of
    # hers; a subject outside this list (the disk, the job, the embedder) is
    # the world, and the reply speaks.
    WHO='((the|that|his|her|my|your|another|an|a) )?(other|desk|phone|live|first|earlier|previous|second|concurrent|interactive) (session|conversation|turn|voice|reply|answer|exchange)( of (you|me|us|her|him|mine|yours))?'
    # A closed set of contentless objects. "said the disk is full" is content
    # and never matches.
    OBJ='(its piece|it all|it|that|this|him|everything|all of it|the point|my point|the question|the same( thing| ground)?|what (was|is) needed|what needed saying|there first|me to it|care of it)'
    ADV='( (already|first|just now|moments ago|a moment ago|seconds ago|earlier|for me|right now|now))*'
    J_OTHER="($WHO) ((has|had|is|was|s) )?((already|just) )?(said|covered|answered|addressed|handled|delivered|raised|repeated|beat|got|took|saying|answering|covering|handling)( $OBJ)?$ADV"
    # …it was already said. Speech verbs only: "it was handled" or "already
    # done" can be real news about real work, and they fall through.
    J_DONE="((it|that|this|everything|all of it) )((s|is|was|has been|had been) )?(all )?((already|just) )?(been )?(said|covered|answered|addressed)( already)?( (by|at|on|in|from) ((the|that) )?((other|desk|phone|live|first|earlier|previous|second) )?(session|conversation|turn|voice|end|side))?"
    J_DONE="$J_DONE|(already|all) (been )?(said|covered|answered|addressed) (by|at|on|in|from) ((the|that) )?((other|desk|phone|live|first|earlier|previous|second) )?(session|conversation|turn|voice|end|side)"
    # …nothing has changed since.
    SINCE='( since (then|his last (message|word)|the last (wake|turn|check|time|one)|last (wake|turn|check|time|night)|we (last )?spoke|yesterday|this (morning|afternoon|evening)|earlier))?'
    J_CHANGE="nothing ((has|had|s) )?changed$SINCE|no changes?$SINCE|nothing new$SINCE"
    # …he already heard it. "already" or a from-phrase is required: "she read
    # it" alone could be real news, and it speaks.
    J_HEARD="(he|she|the user) ((has|had|s) )?already (heard|seen|read|got) (it|that|this|it all|all of it|everything)( already)?( (from|at|on) ((the|that) )?((other|desk|phone) )?(session|conversation|turn|voice|end|side))?"
    J_HEARD="$J_HEARD|(he|she|the user) ((has|had|s) )?(heard|seen|read|got) (it|that|this|it all|all of it|everything) (from|at|on) ((the|that) )?((other|desk|phone) )?(session|conversation|turn|voice|end|side)"
    # …I already said it myself (2026-08-15) — the same first-person core the
    # single clause now matches, standing as the excuse: "Nothing more from
    # me — I've said my piece."
    J_SELF="$SELFSAID$COUNT$TOPIC$COUNT"
    # …the Nth trip round the same subject: "Fifth time round on the same
    # game tonight — nothing further from me on it." An ordinal is required
    # and the phrase is anchored into the whole-line match, so "the fifth
    # time round the loop crashed" never gets here.
    J_REPEAT="(second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|umpteenth|[0-9]+(st|nd|rd|th)) time (round|around|through|over|back)$TOPIC( (tonight|today|now|already|this evening))*"
    JUSTIFY="$J_OTHER|$J_DONE|$J_CHANGE|$J_HEARD|$J_SELF|$J_REPEAT"
    CONN='( (because|since|as|so|and|but))?'

    # Two clauses: the no-op core wearing its excuse, either way round.
    printf '%s\n' "$T" | grep -Eq "^($CORE)$TAIL$CONN ($JUSTIFY)\$" && return 0
    printf '%s\n' "$T" | grep -Eq "^($JUSTIFY)$CONN ($CORE)$TAIL\$" && return 0

    # The excuse standing alone as the whole reply — "The other session
    # already said its piece." — is still only an announcement of silence.
    # J_DONE is restricted here to its by-phrase form: a bare "that was
    # covered" with no no-op core beside it is ambiguous, and ambiguity
    # speaks.
    ALONE="$J_OTHER|(it|that|this|everything|all of it) ((s|is|was|has been|had been) )?(all )?((already|just) )?(been )?(said|covered|answered|addressed) (by|at|on|in|from) ((the|that) )?((other|desk|phone|live|first|earlier|previous|second) )?(session|conversation|turn|voice|end|side)|$J_CHANGE|$J_HEARD|$J_REPEAT"
    printf '%s\n' "$T" | grep -Eq "^($ALONE)\$"
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
    local FACE_SIDECAR=""
    if [ "${FACE_ENABLED:-0}" = 1 ] && [ -f "$LIB_DIR/viseme_cues.py" ]; then
        CMD+=(--debug)
        FACE_SIDECAR="${OUT}.face.json"
        rm -f "$FACE_SIDECAR"
    fi
    # Both processes are silenced on the terminal — a synthesiser narrating into
    # the middle of a turn is noise — but their stderr is kept here so a lost
    # voice has something to be read off (spec rule 53).
    local ERR; ERR="$(mktemp -t crab-synth-err.XXXXXX)"
    printf '%s' "$TEXT" | "${CMD[@]}" 2>>"$ERR" \
        | ffmpeg -y -loglevel error -f s16le -ar 22050 -ac 1 -i - \
            -c:a libopus -b:a 32k "$OUT" 2>>"$ERR"
    local PIPER_RC="${PIPESTATUS[1]}" FF_RC="${PIPESTATUS[2]}"
    local SIZE; SIZE="$(stat -c %s "$OUT" 2>/dev/null)" || SIZE=""
    # A dead synthesiser is not an empty file: ffmpeg muxes a header-only husk
    # (137 bytes, exit 0) from zero input, so a bare -s test calls a silent
    # clip a success. The smallest real utterance measures ~3000 bytes; 256
    # splits the two with room. This is the one place either process's death
    # can be seen at all — on 2026-08-08 two phone turns lost their voices in
    # this pipeline with piper exiting 0 and the file never created, and the
    # cause could not be established because nothing had recorded ffmpeg's
    # side. Every silence explains itself somewhere.
    if [ -z "$SIZE" ] || [ "$SIZE" -lt 256 ]; then
        local WHY; WHY="$(tr '\n' ' ' < "$ERR" | tail -c 400)"
        speech_log "synth_opus produced no audio for ${#TEXT} chars (piper rc=$PIPER_RC, ffmpeg rc=$FF_RC, output ${SIZE:-missing}${SIZE:+ bytes}) -> $OUT${WHY:+ — stderr: $WHY}"
        rm -f "$ERR"
        return 1
    fi
    # An encoder that failed did not finish its file. This used to stand on
    # size alone — "a clip that plays is a success whatever ffmpeg claimed" —
    # but a clip ffmpeg died writing is not a clip that plays: it is a
    # plausible-sized husk with a broken tail, and the browser answers it
    # with "audio could not be decoded" (the 2026-08-15 phone report). The
    # clip is withdrawn, with both statuses and the stderr tail as witness
    # (specs/speech-output.md rule 53).
    if [ "$FF_RC" != 0 ]; then
        local WHY; WHY="$(tr '\n' ' ' < "$ERR" | tail -c 400)"
        speech_log "synth_opus: ffmpeg rc=$FF_RC — the clip ($SIZE bytes) is withdrawn, not served (piper rc=$PIPER_RC) -> $OUT${WHY:+ — stderr: $WHY}"
        rm -f "$ERR" "$OUT"
        return 1
    fi
    # What both processes call a success must still probe as playable before
    # anyone is handed it: exactly one audio stream, the opus codec, the Ogg
    # container — the same bytes the phone's /audio/ route names audio/ogg
    # (specs/phone.md rule 18) — and a real duration, read back from the file
    # with ffprobe. A file that cannot be probed cannot be decoded, and a
    # clip the browser would refuse must fail HERE, on the server, where the
    # failure can say why.
    local PROBE NSTREAMS NAUDIO PCODEC PFMT PDUR
    PROBE="$(ffprobe -v error \
        -show_entries stream=codec_name,codec_type:format=format_name,duration \
        -of default=noprint_wrappers=1 "$OUT" 2>>"$ERR")" || PROBE=""
    NSTREAMS=$(printf '%s\n' "$PROBE" | grep -c '^codec_type=')
    NAUDIO=$(printf '%s\n' "$PROBE" | grep -c '^codec_type=audio$')
    PCODEC=$(printf '%s\n' "$PROBE" | sed -n 's/^codec_name=//p' | head -n 1)
    PFMT=$(printf '%s\n' "$PROBE" | sed -n 's/^format_name=//p' | head -n 1)
    PDUR=$(printf '%s\n' "$PROBE" | sed -n 's/^duration=//p' | tail -n 1)
    if [ "$NSTREAMS" != 1 ] || [ "$NAUDIO" != 1 ] || [ "$PCODEC" != "opus" ] \
            || [ "$PFMT" != "ogg" ] \
            || ! printf '%s' "$PDUR" | grep -Eq '^[0-9]+(\.[0-9]+)?$' \
            || ! awk -v d="$PDUR" 'BEGIN { exit !(d > 0) }'; then
        local WHY; WHY="$(tr '\n' ' ' < "$ERR" | tail -c 400)"
        speech_log "synth_opus: the clip does not probe as playable audio (piper rc=$PIPER_RC, ffmpeg rc=$FF_RC, $SIZE bytes; probe: streams=$NSTREAMS audio=$NAUDIO codec=${PCODEC:-none} container=${PFMT:-none} duration=${PDUR:-none}) — withdrawn, not served -> $OUT${WHY:+ — stderr: $WHY}"
        rm -f "$ERR" "$OUT"
        return 1
    fi
    # Retain Piper's own phoneme record and the cue track beside the phone
    # clip. This is deliberately after every audio validity gate: a sidecar
    # can fail without changing a playable voice into a failed synthesis.
    if [ -n "$FACE_SIDECAR" ]; then
        python3 "$LIB_DIR/viseme_cues.py" --piper-debug \
            "$ERR" "$PDUR" "$FACE_SIDECAR" >/dev/null 2>&1 || true
    fi
    rm -f "$ERR"
}

# Remote turn (crab serve / the phone). Same conversation, same prompt, but the
# reply comes back as data — spoken audio file + display markdown — instead of
# being played and rendered on this desktop.
# The bound on the remote serialisation wait (specs/phone.md rule 2). Ten
# minutes: long enough for any honest turn ahead in the queue, short enough
# that a wedge is reported inside the session it wedged.
REMOTE_LOCK_WAIT="${REMOTE_LOCK_WAIT:-600}"

run_claude_remote() {
    deskcrab_require_persona_source || return $?
    # Serialize remote turns: two overlapping requests would otherwise run two
    # claude processes whose stream logs and conversation appends race. The
    # phone is one person talking, so queueing is the honest behaviour.
    #
    # The delivery-queue place is taken BEFORE the lock (turn-pipeline.md
    # rule 15a): the seat is the moment the message ARRIVED, and a message
    # parked at the lock has still arrived. Taken inside the lock — as it
    # used to be — a phone pushback queued behind the very turn it closes,
    # so it could never supersede until that turn had fully delivered, and a
    # desk turn arriving after the pushback took an earlier seat than the
    # message that beat it here. The supersede pass rides in the take, which
    # is exactly the part that must not wait: it is what silences the
    # in-flight voice he is talking over. The wait chains this opens are
    # bounded — every waiter gives up after TURN_ORDER_WAIT and delivers out
    # of order, saying so — so the worst case is the old latency, never a
    # wedge.
    turn_metric queue-enqueued phone
    turn_order_take phone "$1"
    {
        if ! flock -w "$REMOTE_LOCK_WAIT" 8; then
            # The wait EXPIRED. This used to fall through and run the turn
            # anyway — unlocked, beside whatever had wedged the lock for ten
            # minutes: two claude processes racing the same conversation and
            # stream, the exact corruption the lock exists to prevent. A
            # turn that cannot be serialised is refused, and the refusal is
            # said plainly in the one field the client renders for a turn
            # that arrived holding nothing (phone.md rule 2).
            turn_metric turn-refused "remote lock wait expired after ${REMOTE_LOCK_WAIT}s"
            turn_order_release
            python3 -c 'import json,sys; print(json.dumps({"spoken":"","display":"","audio":"","error":sys.argv[1]}))' \
                "refused — another phone turn has held the line for $(( REMOTE_LOCK_WAIT / 60 )) minutes and this one cannot run safely beside it; nothing was run. Say it again in a moment."
            return 1
        fi
        _run_claude_remote_locked "$1"
    } 8>"${STATE_PREFIX}-remote.lock"
}

_run_claude_remote_locked() {
    # This turn's own mid-turn mail entry dies here (specs/phone.md rule 52):
    # the lock is taken, so any run that could have read the entry mid-flight
    # has finished, and this turn's own model is about to run — a run that
    # must never be handed its own message as mail arriving from outside.
    # serve.py names the entry <arrival-ns>.<turn-id>.msg and hands the id
    # down as DESKCRAB_TURN_ID; a desk turn carries no id and skips this.
    if [ -n "${DESKCRAB_TURN_ID:-}" ]; then
        rm -f "${STATE_PREFIX}-midturn/"*".${DESKCRAB_TURN_ID}.msg" 2>/dev/null || true
    fi
    session_register "phone turn"
    turn_metric turn-start phone
    record_origin phone
    # Local control doors can distinguish a phone conversation from an
    # operator shell without changing the phone's filesystem boundary.
    # In particular, live OpenRSC play may be steered here but not stopped.
    local DESKCRAB_TURN_ORIGIN=phone
    export DESKCRAB_TURN_ORIGIN
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
    # The delivery-queue place was taken in run_claude_remote, BEFORE the
    # remote lock (specs/turn-pipeline.md rule 15a) — taking it here put the
    # take on the far side of a wait that can last minutes, which inverted
    # cross-device order and let a phone pushback queue behind the very turn
    # it was closing. TURN_SEQ survives into this scope: the lock body is a
    # braced group in the same process, not a subshell.
    # A private stream log, so a remote turn can never truncate the log a
    # desktop turn's TTS streamer is tailing.
    # crab serve sets DESKCRAB_REMOTE_LOG when it wants to tail this stream and
    # relay the thinking to the phone; otherwise it stays private to this turn.
    local DEBUGLOG="${DESKCRAB_REMOTE_LOG:-${STATE_PREFIX}-remote-$$.log}"
    rotate_convo
    convo_append_user "$TEXT"

    # Phone work is the same live considering activity as desk work. The
    # token also prevents its detached mood result repainting a newer turn.
    export DESKCRAB_FACE_TURN="phone-$$-$(date +%s%N)"
    face_touch activity considering
    local RESPONSE
    RESPONSE=$(claude_generate "$TEXT")
    face_touch activity resting

    # Cut-and-consolidate (specs/turn-pipeline.md rule 15f), the phone half:
    # he spoke again — on either device — while this was generating, and the
    # newer message's turn aborted this run and folds this exchange into its
    # own single reply. Closed here, above the limit test and every delivery
    # sink: nothing is synthesised, nothing enters the conversation, and the
    # client is told in the one field it renders for a turn arriving with
    # nothing playable. The memory judge runs (a memory that shaped the
    # part-written words shaped them); the judges of what he was TOLD do
    # not, and the stream log is read for the work trace before it goes.
    if _turn_cut_close phone "$TEXT"; then
        fire_memory_judge "$TEXT" "$SESSION_REPLY" "$(wake_work_trace)"
        rm -f "$DEBUGLOG"
        python3 -c 'import json,sys; print(json.dumps({"spoken":"","display":"","audio":"","error":sys.argv[1]}))' \
            "cut — you spoke over this; the reply to what you said next answers both"
        return 0
    fi

    local ERROR="" TURN_CUT
    # Same judgement as the desk turn: a cut standing on the whole log means
    # the walk rode every account and the limit ended the last of them
    # (specs/account-fallback.md rules 12a and 12c).
    TURN_CUT="$(claude_stream_limit_cut "$DEBUGLOG")" || TURN_CUT=""
    if claude_run_limited || [ -n "$TURN_CUT" ]; then
        # Same routing as the desk turn: an all-refused walk reports the
        # CLI's refusal as the extracted reply. That is the outage speaking,
        # not me — never the conversation's assistant block, and never
        # synthesized for the phone's speakers. The error field carries it
        # as text the client can show.
        live_turn_end phone "$TEXT" ""
        if [ -n "$TURN_CUT" ]; then
            session_outcome "(turn failed — session-limit cut it off mid-run, every account tried, for: $(printf '%.80s' "$TEXT") — $(printf '%.120s' "$TURN_CUT"))"
            ERROR="the session limit cut this answer off mid-run and every login is out: $(printf '%.140s' "$TURN_CUT")"
        else
            session_outcome "(every account limited for: $(printf '%.80s' "$TEXT") — $(printf '%.120s' "$RESPONSE"))"
            ERROR="every login is over its limit: $(printf '%.140s' "$RESPONSE")"
        fi
        RESPONSE=""
    elif [ -n "$RESPONSE" ] && {
            # The pre-speech mirror on the whole draft (specs/speech-output.md
            # rule 44): the phone's audio is synthesised below from a complete
            # reply, so the pass runs here, before anything is committed,
            # shown, or voiced. Fails open to the draft as written.
            RESPONSE="$(claudism_mirror_direct phone "$RESPONSE")"
            SESSION_REPLY="$RESPONSE"
            # THE delivery gate (specs/turn-pipeline.md rule 16b): one split,
            # one branch, every sink below it. Whitespace and the bare quiet
            # marker fall to the no-reply branch with the genuinely empty;
            # a quiet reply with a thought delivers as the bubble, unvoiced.
            reply_delivery_split "$RESPONSE"
        }; then
        # From here down RESPONSE is the DELIVERED form the split settled on —
        # the normalised "(quiet) …" bubble for a quiet reply, the reply
        # unchanged otherwise.
        RESPONSE="$REPLY_TEXT"
        # Delivery order, exactly as the desk turn takes it (rules 15a-15e).
        local ORDERED=1 SUPERSEDER="" ORDER_NOTE=""
        turn_order_wait || ORDERED=0
        # The late cut (rule 15f), as on the desk: his newer message landed
        # after generation finished but before delivery. The cutter already
        # snapshotted this turn's log, so the fold carries these words.
        if _turn_cut_close phone "$TEXT"; then
            fire_memory_judge "$TEXT" "$SESSION_REPLY" "$(wake_work_trace)"
            rm -f "$DEBUGLOG"
            python3 -c 'import json,sys; print(json.dumps({"spoken":"","display":"","audio":"","error":sys.argv[1]}))' \
                "cut — you spoke over this; the reply to what you said next answers both"
            return 0
        fi
        SUPERSEDER="$(turn_order_superseded || true)"
        if [ -n "$SUPERSEDER" ]; then
            # Held: written down, marked as unsaid, never synthesised. The
            # client is told plainly through the one field it has for a turn
            # that arrived holding nothing playable, and /watch shows the
            # transcript block as words she wrote and did not say.
            convo_append_assistant --held "$RESPONSE"
            live_turn_end phone "$TEXT" ""
            compact_convo
            session_outcome "(held — he had already moved past this: $(printf '%.80s' "$SUPERSEDER") | unspoken reply: $REPLY_SHOWN)"
            turn_metric turn-held "superseded"
            turn_order_release
            ERROR="held — you had already moved past what this answered; it is in the transcript, unspoken"
            RESPONSE=""
        else
            [ "$ORDERED" = 1 ] || \
                ORDER_NOTE="(delivered out of order — waited ${TURN_ORDER_WAIT}s on an earlier turn that never finished) "
            convo_append_assistant "$RESPONSE"
            # Delivered: a job that ended badly has now been reported to somebody.
            jobs_news_delivered
            live_turn_end phone "$TEXT" "$REPLY_SHOWN"
            compact_convo
            # The outcome carries the turn's own tool record (turn-pipeline
            # rule 32e): the nightly sweep judges completed-work claims from
            # the journal alone, and only wakes used to leave a trace — a
            # phone claim that slipped the live pre-check was unfalsifiable
            # the morning after. Before "replied:" on purpose — the outcome
            # is capped and the full reply already rides the journal's own
            # reply field, so the cap may clip the reply's echo, never the
            # evidence.
            local TURN_TRACE; TURN_TRACE="$(wake_work_trace)"
            last_turn_actions_write phone "${TURN_TRACE:-ran no tools, touched nothing}"
            session_outcome "${ORDER_NOTE}asked: $(printf '%.100s' "$TEXT") | did: ${TURN_TRACE:-ran no tools, touched nothing} | replied: $REPLY_SHOWN"
            # Delivered — see the desk turn: the place goes back now, not at
            # process exit, so nobody queues behind the synthesiser.
            turn_order_release
        fi
    else
        # He asked and nothing deliverable came back — no text at all,
        # whitespace, or a bare quiet marker (rule 16b): every shape of empty
        # ends here, in the one branch, above every sink. Reported as the
        # failure it is: the phone used to receive {"spoken":"", ...} with no
        # error at all, which the client had no way to read except as an
        # empty bubble — the "(no reply)" placeholder he spent a day looking
        # at. Silence is a thing I choose when nobody asked; it is never an
        # answer to a question, and it is never left to the client to
        # describe.
        live_turn_end phone "$TEXT" ""
        session_outcome "(no reply — the model produced nothing to deliver for: $(printf '%.80s' "$TEXT"))"
        ERROR="no reply — that turn produced nothing to deliver"
        RESPONSE=""
    fi

    # The halves the split settled on, blanked wherever the branch above
    # emptied the reply (limited, superseded, nothing to deliver). SHOWN is
    # the completion payload's spoken text: the voiced half, or the bubble
    # form for a quiet reply — the same text the conversation block carries,
    # so the client's own-turn match still recognises its exchange.
    local SPOKEN="" DISPLAY_MD="" SHOWN="" AUDIO=""
    if [ -n "$RESPONSE" ]; then
        SPOKEN="$REPLY_SPOKEN"
        DISPLAY_MD="$REPLY_DISPLAY"
        SHOWN="$REPLY_SHOWN"
    fi

    if [ -n "$SPOKEN" ]; then
        local CANDIDATE="${REMOTE_AUDIO_PREFIX}$(date +%s%N).opus"
        turn_metric synth-start "${#SPOKEN} chars"
        synth_opus "$SPOKEN" "$CANDIDATE" && AUDIO="$CANDIDATE"
        turn_metric synth-end "$([ -n "$AUDIO" ] && echo clip || echo failed)"
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

    # The promise checker fires BEFORE the stream log goes: its evidence is
    # that log, snapshotted at fire time, and three lines down it is deleted
    # (turn-pipeline rule 32a). A held (superseded) turn arrives here with
    # RESPONSE already emptied, so nothing of an unspoken reply is judged.
    fire_promise_check phone "$RESPONSE"

    rm -f "$DEBUGLOG"
    # Reply audio the client has had time to fetch. Scoped to THIS instance's
    # own prefix and to clips older than an hour — a pattern delete that only
    # said /tmp/deskcrab-remote-*.opus reaped the live instance's clips
    # whenever a scratch instance ran beside it.
    find "$(dirname "$REMOTE_AUDIO_PREFIX")" -maxdepth 1 \
        -name "$(basename "$REMOTE_AUDIO_PREFIX")*.opus" -mmin +60 -delete 2>/dev/null
    find "$(dirname "$REMOTE_AUDIO_PREFIX")" -maxdepth 1 \
        -name "$(basename "$REMOTE_AUDIO_PREFIX")*.opus.face.json" \
        -mmin +60 -delete 2>/dev/null

    # Out of band, with the reply audio already synthesised: a want stated on
    # the phone dies with the turn exactly like one stated at the desk. The
    # memory judge rides the same moment — reply delivered, hot path over.
    fire_face_mood "$TEXT" "$RESPONSE"
    fire_promise_audit "$TEXT" "$RESPONSE"
    fire_memory_judge "$TEXT" "$RESPONSE" "$WORK_TRACE"
    fire_claudism_capture phone "$RESPONSE"

    # The belt under the gate: a delivered turn always has something the
    # phone can render (the split guarantees it — rule 16b routed every empty
    # shape through the error branch above), so a turn that still arrives
    # here holding nothing is a defect speaking, and the client must never
    # have to invent a word for it.
    if [ -z "$ERROR" ] && \
       [ -z "$(printf '%s' "$SHOWN$DISPLAY_MD" | tr -d '[:space:]')" ]; then
        ERROR="no reply — that turn produced nothing sayable"
    fi

    # The spoken field carries SHOWN: the voiced half, or the "(quiet) …"
    # bubble form — the same text the conversation block holds, so the
    # client's own-turn match recognises its exchange, with no clip and no
    # error for a quiet reply (specs/phone.md rule 6).
    python3 -c 'import json,sys; print(json.dumps({"spoken":sys.argv[1],"display":sys.argv[2],"audio":sys.argv[3],"error":sys.argv[4]}))' \
        "$SHOWN" "$DISPLAY_MD" "$AUDIO" "$ERROR"
}

# The "Thinking..." toast, and its dismissal — paired, and idempotent so the
# dismissal can be called from a trap AND on the straight line without a
# second empty notification flashing past.
# A notification body, cut to fit without splitting a character in half: glib
# refuses to marshal invalid UTF-8 over D-Bus, and the notification is dropped
# whole — with its error swallowed by the `2>/dev/null` every caller has, so
# the desk simply goes quiet. The cut itself is utf8_trim's; this keeps only
# the notification default of 140 bytes.
_notify_body() {  # <text> [max bytes]
    utf8_trim "$1" "${2:-140}"
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
    deskcrab_require_persona_source || return $?
    session_register "desktop turn"
    turn_metric turn-start desk
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
    # This turn's place in the order he said things in — taken here, at
    # arrival, so nothing downstream can decide it (specs/turn-pipeline.md
    # rule 15a). Also the moment a pushback message closes the theories
    # already in flight behind it.
    turn_order_take desk "$TEXT"

    convo_append_user "$TEXT"

    # The desk's provider stream is the speech source. Clean sentences begin
    # sounding as they are written; the streamer's own acceptance boundary
    # still protects transports that can return Stop-hook feedback.
    _CLAUDISM_ARM=1
    start_tts_streamer
    _CLAUDISM_ARM=0

    notify_thinking
    # The portrait's presence layer, from the same fact the toast reads
    # (specs/face.md rule 15): a reply is being formed. The token names THIS
    # turn to the broker, so an automatic expression computed for it cannot
    # land on a later one (the staleness check of the 2026-08-30 amendment).
    export DESKCRAB_FACE_TURN="turn-$$-$(date +%s%N)"
    face_touch activity considering
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

    # Cut-and-consolidate (specs/turn-pipeline.md rule 15f): while this was
    # generating, he said something new. That message's own turn has already
    # silenced this one's voice and aborted its run; what remains here is
    # bookkeeping — the part-written words go to the journal, the outcome
    # names the message that cut this, and NOTHING is delivered or reported
    # as a failure, because the surviving turn's one reply folds this
    # exchange in. Above the limit test on purpose: a killed run's log tail
    # can wear a refusal's face, and a cut turn has no outage to report.
    if _turn_cut_close desk "$TEXT"; then
        # The memory judge still runs, as on the held path: a memory that
        # shaped the part-written reply shaped it. The three judges of what
        # he was TOLD do not — he was told none of this.
        fire_memory_judge "$TEXT" "$SESSION_REPLY" "$(wake_work_trace)"
        return 0
    fi

    # The cut twin of the limited test below (specs/account-fallback.md rules
    # 12a and 12c): the walk already rode any mid-flight cut to the next
    # account, so a cut still standing on the whole log means every account was
    # tried and the limit ended the last of them. Judged at offset 0 — one
    # genuine text block from any account clears it.
    local TURN_CUT
    TURN_CUT="$(claude_stream_limit_cut "$DEBUGLOG")" || TURN_CUT=""
    if claude_run_limited || [ -n "$TURN_CUT" ]; then
        # Every account refused over a limit — or the last one was cut off
        # mid-run by it. extract_response reports the refusal so an error-only
        # stream can explain itself in a log — which
        # means RESPONSE holds the CLI's words, not mine. They never enter
        # the conversation as my reply and are NEVER spoken: the streamer
        # held them, its receipt reads empty, and the never-silent guard
        # below used to read that emptiness as a broken speech path and
        # replay exactly this text aloud. The notification and the journal
        # carry the outage; the current has already moved, so the next
        # attempt leads with the next account.
        claudism_mirror_abort
        wait_tts_streamer
        live_turn_end desk "$TEXT" ""
        if [ -n "$TURN_CUT" ]; then
            session_outcome "(turn failed — session-limit cut it off mid-run, every account tried, for: $(printf '%.80s' "$TEXT") — $(printf '%.120s' "$TURN_CUT"))"
            notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" \
                "the session limit cut that answer off mid-run and every login is out — nothing was said ($(printf '%.120s' "$TURN_CUT"))" 2>/dev/null
        else
            session_outcome "(every account limited for: $(printf '%.80s' "$TEXT") — $(printf '%.120s' "$RESPONSE"))"
            notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" \
                "every login is over its limit — nothing was said ($(printf '%.120s' "$RESPONSE"))" 2>/dev/null
        fi
        RESPONSE=""
    elif [ -n "$RESPONSE" ] && {
            # Answer any wording-mirror fire the live streamer is holding.
            # A clean response returns immediately and unchanged.
            RESPONSE="$(claudism_mirror_desk "$RESPONSE")"
            SESSION_REPLY="$RESPONSE"
            # THE delivery gate (specs/turn-pipeline.md rule 16b): one split,
            # one branch, every sink below it. A whitespace-only reply and a
            # bare quiet marker fall through to the no-reply branch beside
            # the genuinely empty ones; a quiet reply with a thought delivers
            # as the bubble, voiced nowhere.
            reply_delivery_split "$RESPONSE"
        }; then
        # From here down RESPONSE is the DELIVERED form the split settled on —
        # the normalised "(quiet) …" bubble for a quiet reply, the reply
        # unchanged otherwise.
        RESPONSE="$REPLY_TEXT"

        # Delivery order (specs/turn-pipeline.md rules 15a-15e). Two questions
        # before a word of this goes out:
        #
        #   1. Has every message he sent BEFORE this one been answered yet?
        #      If not, wait — his conversation reads in the order he had it,
        #      and a reply arriving in somebody else's slot is the loudest way
        #      this machine has of saying it was not listening.
        #   2. Has a message he sent SINCE closed the question this answers?
        #      Then this reply is a theory he has already rejected, and saying
        #      it now — 105 seconds late, on 2026-08-10 — is the failure
        #      itself. It is written down and it is not said.
        local ORDERED=1 SUPERSEDER="" ORDER_NOTE=""
        turn_order_wait || ORDERED=0
        # The late cut (rule 15f): his new message landed after this turn's
        # generation finished but before a word of it was delivered — the
        # 12:31 shape. Same close as the early one; the cutter snapshotted
        # this turn's log, so the fold still carries these words forward.
        if _turn_cut_close desk "$TEXT"; then
            fire_memory_judge "$TEXT" "$SESSION_REPLY" "$(wake_work_trace)"
            return 0
        fi
        SUPERSEDER="$(turn_order_superseded || true)"
        if [ -n "$SUPERSEDER" ]; then
            # Held. The words land in the transcript marked as words she did
            # not say, so nothing is lost and nothing reads as delivered:
            # the next turn's prompt sees a reply she wrote and withheld, and
            # can carry it forward if it still stands. One voice, one reply —
            # the regroup bargain, made at delivery instead of at drafting.
            turn_hold_voice
            convo_append_assistant --held "$RESPONSE"
            live_turn_end desk "$TEXT" ""
            compact_convo
            if [ "${_TURN_HELD_SPOKEN_CHARS:-0}" -gt 0 ] 2>/dev/null; then
                session_outcome "(held — he had already moved past this: $(printf '%.80s' "$SUPERSEDER") | reply partly spoken, $_TURN_HELD_SPOKEN_CHARS chars out: $REPLY_SHOWN)"
                notify-send -t 5000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" \
                    "held a reply to a question you had already closed — you heard part of it; the rest is in the transcript, not repeated" 2>/dev/null
            else
                session_outcome "(held — he had already moved past this: $(printf '%.80s' "$SUPERSEDER") | unspoken reply: $REPLY_SHOWN)"
                notify-send -t 5000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" \
                    "held a reply that answered a question you had already closed — it is in the transcript, not spoken" 2>/dev/null
            fi
            turn_metric turn-held "superseded"
            claudism_mirror_cleanup
            turn_order_release
            # The memory judge still runs — a memory that shaped a reply
            # shaped it whether or not the reply was spoken. The promise audit,
            # the promise checker and the claudism capture do not: all three
            # judge what he was TOLD, and he was told none of this.
            fire_memory_judge "$TEXT" "$RESPONSE" "$(wake_work_trace)"
            echo "$RESPONSE"
            return 0
        fi
        [ "$ORDERED" = 1 ] || \
            ORDER_NOTE="(delivered out of order — waited ${TURN_ORDER_WAIT}s on an earlier turn that never finished) "

        convo_append_assistant "$RESPONSE"
        # Delivered: a job that ended badly has now been reported to somebody.
        jobs_news_delivered
        live_turn_end desk "$TEXT" "$REPLY_SHOWN"
        compact_convo
        # The outcome carries the turn's own tool record (turn-pipeline rule
        # 32e): the nightly sweep judges completed-work claims from the
        # journal alone, and only wakes used to leave a trace — a desk claim
        # that slipped the live pre-check was unfalsifiable the morning
        # after. Before "replied:" on purpose — the outcome is capped and
        # the full reply already rides the journal's own reply field, so the
        # cap may clip the reply's echo, never the evidence.
        local TURN_TRACE; TURN_TRACE="$(wake_work_trace)"
        last_turn_actions_write desk "${TURN_TRACE:-ran no tools, touched nothing}"
        session_outcome "${ORDER_NOTE}asked: $(printf '%.100s' "$TEXT") | did: ${TURN_TRACE:-ran no tools, touched nothing} | replied: $REPLY_SHOWN"
        # Delivered — the place in the queue is given up HERE, not at process
        # exit. What comes after this line is the window, the streamer wait
        # and the out-of-band judges, and none of it is the reply: making the
        # next turn queue behind a summarising model call and a memory judge
        # would turn ordering into a stall.
        turn_order_release

        local DISPLAY_PART="$REPLY_DISPLAY"

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
        # The quiet reply's voiced half is empty BY DEFINITION (rule 16b), so
        # the guarantee stays silent for a held thought instead of reading the
        # streamer's untouched receipt as a broken speech path.
        tts_verify_spoken "$REPLY_SPOKEN"
        claudism_mirror_cleanup
        # The turn is delivered: presence returns to rest. An authored
        # expression she set mid-turn stands — activity never erases it.
        face_touch activity resting
        # And the standing mood moves out of band, from the exchange that
        # just happened — detached, token-carrying, never awaited (specs/
        # face.md, 2026-08-30 amendment).
        fire_face_mood "$TEXT" "$RESPONSE"

        # Out of band, after the user has their answer: did I say I wanted
        # something and fail to write it down? If so this fires an event wake
        # that hands the sentence back to me. Costs nothing on the hot path.
        fire_promise_audit "$TEXT" "$RESPONSE"
        fire_claudism_capture desktop "$RESPONSE"
        # And did I CLAIM work this turn's own tool record never performed?
        # Pattern-gated: most replies cost a grep here and no model call
        # (turn-pipeline rules 32a-32d).
        fire_promise_check desktop "$RESPONSE"
    else
        # He asked out loud and nothing deliverable came back — no text at
        # all, whitespace, or a bare quiet marker (rule 16b): every shape of
        # empty ends here, in the one branch, and reaches no sink. This
        # branch used to do NOTHING AT ALL — no speech, no notification, no
        # journal line — so a turn that produced no text was
        # indistinguishable from a turn that was never taken, and a whole
        # afternoon of them went unexplained and unrecorded. Silence is only
        # ever legitimate when nobody asked; answering a question with
        # nothing is a failure and is reported as one. Not spoken: an error
        # read aloud in my own voice is the thing that put "You've hit your
        # session limit" in his ears as if I had said it. The notification
        # and the journal carry it instead.
        claudism_mirror_abort
        live_turn_end desk "$TEXT" ""
        session_outcome "(no reply — the model produced nothing to deliver for: $(printf '%.80s' "$TEXT"))"
        notify-send -t 8000 -h string:x-dunst-stack-tag:deskcrab "$NOTIFY_NAME" \
            "no reply — that turn produced nothing to deliver (nothing was said)" 2>/dev/null
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
# CLI's own refusals (the shared CLAUDE_LIMIT_RE, so the account-retry sites
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
    # state, not status: the schema has one field name (specs/jobs.md rule
    # 8), and the stop path writing a second one was MAJ-11 — the sidecar
    # kept saying running and the next report reaped the deliberate stop as
    # died. The read-modify-write race the same defect named is closed inside
    # job-status itself, which takes the job's lock around every write.
    "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" state=stopped finished=now
    echo "Job $id stopped."
}

# Queue a correction for the named builder's own PostToolUse hook. This is a
# control channel into the existing job, not another wake or another builder.
job_steer() {  # <id> <correction>
    local id="${1:-}" sidecar state model steerable correction inbox stamp tmp pending
    [ $# -gt 0 ] && shift
    correction="$*"
    case "$id" in
        ''|*[!A-Za-z0-9._-]*)
            echo "Usage: crab job steer <id> <correction>   (ids: crab jobs)"
            return 1 ;;
    esac
    sidecar="$JOBS_DIR/$id.json"
    [ -e "$sidecar" ] || { echo "No such job: $id   (ids: crab jobs)"; return 1; }
    [ -n "$(printf '%s' "$correction" | tr -d '[:space:]')" ] || {
        echo "Usage: crab job steer <id> <correction>"
        return 1
    }
    state="$("$LIB_DIR/job-status" get "$sidecar" state 2>/dev/null)"
    case "$state" in
        dispatched|running) ;;
        *) echo "Job $id is '$state', not active — no correction was queued."; return 1 ;;
    esac
    model="$("$LIB_DIR/job-status" get "$sidecar" model 2>/dev/null)"
    [ "$(model_backend "${model:-$JOB_MODEL}")" = claude ] || {
        echo "Job $id uses the Codex backend, which cannot accept a mid-run correction. No correction was queued."
        return 1
    }
    steerable="$("$LIB_DIR/job-status" get "$sidecar" steerable 2>/dev/null)"
    [ "$steerable" = 1 ] || {
        echo "Job $id started without the live steering hook, so it cannot accept a correction safely. No correction was queued."
        return 1
    }

    inbox="$JOBS_DIR/$id.steer"
    mkdir -p "$inbox" || return 1
    # One outstanding copy is enough. A repair pass repeating the same call
    # must not make the builder hear the correction twice.
    for pending in "$inbox"/*.pending; do
        [ -e "$pending" ] || continue
        if printf '%s\n' "$correction" | cmp -s - "$pending"; then
            echo "The same correction is already queued directly for active job $id."
            return 0
        fi
    done
    stamp="$(date +%s%N)"
    tmp="$inbox/.$stamp.$$"
    (umask 077; printf '%s\n' "$correction" > "$tmp") || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$inbox/$stamp.pending" || { rm -f "$tmp"; return 1; }
    "$LIB_DIR/job-status" append "$sidecar" steering \
        "$(date '+%F %T') queued $stamp.pending: $(utf8_trim "$correction" 300)" 2>/dev/null || true
    echo "Correction queued directly for active job $id. Its builder will receive it at the next tool boundary."
}

job_start() {
    # The id of whatever this call shelves or dispatches, for callers that
    # need it programmatically (the chore gate, turn-pipeline rule 16c) —
    # parsing it back out of the human messages below was the alternative.
    JOB_START_ID="" JOB_START_QUEUED=""
    local workdir="$PROJECT_DIR" force="" origin="" record="" want=""
    while :; do
        case "${1:-}" in
            -C) workdir="${2:-$PROJECT_DIR}"; shift 2 2>/dev/null || shift $# ;;
            -f) force=1; shift ;;
            # -O names the blocked job this dispatch is the automatic retry of
            # (lib/job-block-retry, jobs.md rule 18b). Internal, not offered in
            # the usage line: the stamps it writes below are what make the
            # retry once-only and legible in `crab jobs`.
            -O) origin="${2:-}"; shift 2 2>/dev/null || shift $# ;;
            # The engineering record this build is dispatched against
            # (jobs.md rule 7b, specs/engineering-records.md). The runner
            # refuses to call the job successful unless the builder touched
            # this record after dispatch — work tied to the thread it came
            # from, not floating beside it.
            --record|-R) record="${2:-}"; shift 2 2>/dev/null || shift $# ;;
            # The want this dispatch serves (jobs.md rule 30): while she is
            # awake the door dispatches only want-linked work, and the
            # linkage is validated against the shelf below — a linkage that
            # cannot be checked is a linkage that will be invented.
            --want|-W) want="${2:-}"; shift 2 2>/dev/null || shift $# ;;
            # Any other flag is a mistake, not a task description — once, a
            # stray --help was dispatched as a real job that ran `claude --help`.
            -*) echo "Unknown option '$1'. Usage: crab job [-C <workdir>] [--record <eng-id>] [--want <ref>] [-f] <description of the work>"; return 1 ;;
            *) break ;;
        esac
    done
    local task="$*"
    [ -n "$task" ] || { echo "Usage: crab job [-C <workdir>] [--record <eng-id>] [--want <ref>] [-f] <description of the work>"; return 1; }
    # Live steering is a synchronous ACTIONS control, not build work. Sending
    # this one-line correction to a detached builder delays it and makes a
    # second personality responsible for the assistant's own play.
    case "$(printf '%s' "$task" | tr '[:upper:]' '[:lower:]')" in
        *betty-openrsc*steer*)
            echo "Not dispatched — OpenRSC steering is an immediate local control."
            echo "  Run ~/.local/bin/betty-openrsc steer <instruction> directly in this turn."
            return 1 ;;
    esac
    # An automatic retry inherits the obligation its origin carried: the brief
    # is the same brief, so the record rides the sidecar chain (rule 7b).
    if [ -z "$record" ] && [ -n "$origin" ] && [ -e "$JOBS_DIR/$origin.json" ]; then
        record="$("$LIB_DIR/job-status" get "$JOBS_DIR/$origin.json" record 2>/dev/null)"
    fi
    # An id the records drawer does not know is refused before any sidecar or
    # unit exists — a job tied to a record nobody can touch could only ever
    # end failed, hours from now, for a typo visible right here.
    if [ -n "$record" ]; then
        if ! DESKCRAB_ENG_DIR="$(deskcrab_home)/engineering/records" \
                python3 "$LIB_DIR/eng" field "$record" id >/dev/null 2>&1; then
            echo "Not dispatched — no engineering record '$record' (ids: crab eng list)."
            return 1
        fi
    fi
    # A non-empty task can still be nobody's brief. On 2026-08-11 a re-dispatch
    # loop pulled `.task` out of job sidecars whose field is `.description`;
    # jq's answer for a missing field is the literal word "null", which sailed
    # past the check above three times, and three real builders woke to a
    # one-word task and burned tokens investigating their own emptiness. The
    # strings below are what broken command substitutions say, never what work
    # sounds like — refuse them before anything exists to clean up.
    case "$(printf '%s' "$task" | tr -d '[:space:]')" in
        ''|null|None|undefined)
            echo "Not dispatched — '$task' looks like a broken command substitution, not a brief."
            echo "  (A job sidecar's field is .description, not .task. To redo a recorded job: crab job requeue <id>)"
            return 1 ;;
    esac
    # The want gate (jobs.md rules 30-31). A named want must match the shelf
    # — an unmatched ref is refused outright, neither dispatched nor queued.
    local want_title=""
    if [ -n "$want" ]; then
        if ! want_title="$(wants_match "$want")"; then
            echo "Not dispatched — nothing on the wants shelf matches '$want' (shelf: ${WANTS_FILE:-not configured})."
            echo "  A linkage that cannot be checked is a linkage that gets invented (jobs.md rule 30). Titles: crab jobs is not the shelf; read the shelf itself."
            return 1
        fi
    fi
    # No want, and she is awake: the brief QUEUES for the night instead of
    # dispatching (rule 30). Three hands pass without a want (rule 31): -f is
    # a deliberate force, -O inherits the standing its origin earned when it
    # was first dispatched, and DESKCRAB_JOB_NIGHT is the night's window —
    # set by the night's work and by nothing else. The gate stands only where a
    # shelf exists: an instance with no WANTS_FILE has nobody whose wants
    # could gate it, and dispatches as it always did.
    if [ -n "${WANTS_FILE:-}" ] && [ -s "$WANTS_FILE" ] \
        && [ -z "$want_title" ] && [ -z "$force" ] && [ -z "$origin" ] \
        && [ -z "${DESKCRAB_JOB_NIGHT:-}" ]; then
        local id
        id="$(date +%Y%m%d-%H%M%S)-$$"
        "$LIB_DIR/job-status" new "$JOBS_DIR" "$id" "$task" "" "$workdir" queued || return 1
        JOB_START_ID="$id" JOB_START_QUEUED=1
        [ -n "$record" ] && \
            "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" record="$record"
        echo "Job $id QUEUED for the night — not dispatched. Awake, the door dispatches only want-linked work (jobs.md rule 30); the night takes up the queue after sleep."
        echo "  now instead: crab job dispatch $id   (or --want <ref> to link a want, -f to force)"
        echo "  list: crab jobs    drop: crab job drop $id"
        return 0
    fi
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
        echo "Would dispatch (DESKCRAB_NO_DISPATCH set) in $workdir: $task${origin:+ (retry of $origin)}${record:+ (against record $record)}${want_title:+ (want: $want_title)}"
        return 0
    fi
    local id
    # Timestamp + pid, like wake-at units: two dispatches in the same second
    # must not collide on the id or the unit name.
    id="$(date +%Y%m%d-%H%M%S)-$$"
    "$LIB_DIR/job-status" new "$JOBS_DIR" "$id" "$task" "" "$workdir" dispatched || return 1
    JOB_START_ID="$id"
    # The record rides the sidecar (jobs.md rule 7b): the runner reads it back
    # at completion, and requeue re-dispatches with the obligation intact.
    [ -n "$record" ] && \
        "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" record="$record"
    # The want rides too (rule 30), as the shelf title the ref matched, so
    # the record says which want this builder served.
    [ -n "$want_title" ] && \
        "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" want="$want_title"
    if [ -n "$origin" ]; then
        # jobs.md rules 18b and 18f: the new sidecar names the blocked job it
        # came from — `crab jobs` shows it, and job-runner reads it to never
        # arm a second retry — and the origin's records that its one automatic
        # retry is spent, as the id of the job that spent it.
        "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" retry_of="$origin"
        [ -e "$JOBS_DIR/$origin.json" ] && \
            "$LIB_DIR/job-status" set "$JOBS_DIR/$origin.json" retry="$id"
    fi
    job_dispatch_sidecar "$id" "$workdir"
}

# The one dispatch tail (jobs.md rules 2-5, 32, 35): every dispatch — a fresh
# brief through job_start and a queued record through `crab job dispatch` —
# goes through here, so the account preference, the background priority, the
# instance redirects, and the model and effort stamp can never drift between
# the two doors. The sidecar already exists; this stamps what the builder
# actually runs with (rule 35), re-stamps started to the dispatch moment —
# for a queued brief the original started was the shelving, and the record
# hook of rule 27 compares against dispatch (rule 32) — and starts the unit.
job_dispatch_sidecar() {  # <id> <workdir>
    local id="$1" workdir="$2" unit="deskcrab-job-$id"
    # The stamp is also the guard (jobs.md rules 32-33): a racing `crab job
    # drop` may have deleted the sidecar between this dispatch's preflight
    # and here — drop holds the record's lock around its check-and-delete,
    # so by the time this locked write runs the record either exists or is
    # gone, never half. A vanished record aborts the dispatch: a builder
    # with no sidecar is exactly the untracked work the sidecars exist to
    # prevent. (The status writer's own lock open recreates `<id>.lock` on
    # the way to discovering the loss; it is swept back out.)
    if ! "$LIB_DIR/job-status" set "$JOBS_DIR/$id.json" \
        state=dispatched started=now unit="$unit" \
        model="$JOB_MODEL" effort="$JOB_EFFORT" 2>/dev/null; then
        [ -e "$JOBS_DIR/$id.json" ] || rm -f "$JOBS_DIR/$id.lock"
        echo "Not dispatched — job $id's record could not be stamped (vanished mid-flight — a racing drop?). No builder started."
        return 1
    fi
    # CLAUDE_CONFIG_DIR is forwarded ONLY when it is actually set. Passing it
    # empty is not the same as not passing it: the unit then runs with the
    # variable defined-but-blank, the CLI looks for a login in "" and every
    # builder died in one second on "Not logged in". Worse, that is not a limit
    # refusal, so job-runner's account walk broke on the first attempt and no
    # second account was ever tried. Every job dispatched from a session with
    # no explicit config dir — which is all of them — was dead on arrival.
    #
    # Which login: the account the selection answers with now, not the one
    # this shell inherited. specs/jobs.md rule 5 — a job is dispatched with
    # the current pick and walks the list itself from there, so a builder
    # starting behind a moved selection no longer pays a whole doomed CLI boot
    # and refusal before its first real attempt. The state file path goes with
    # it, so a scratch dispatch reads scratch state.
    local -a acctenv=() login
    login="$(claude_child_login)"
    [ -n "$login" ] && acctenv+=(--setenv=CLAUDE_CONFIG_DIR="$login")
    acctenv+=(--setenv=ACCOUNT_STATE_FILE="$ACCOUNT_STATE_FILE")
    # Background CPU priority (jobs.md rule 2a): a builder chewing a compile
    # yields the processor to a turn somebody is standing there waiting on.
    local -a bgprio=()
    [ -n "${BACKGROUND_CPU_WEIGHT:-}" ] && bgprio+=(-p "CPUWeight=$BACKGROUND_CPU_WEIGHT")
    [ -n "${BACKGROUND_NICE:-}" ] && bgprio+=(-p "Nice=$BACKGROUND_NICE")
    if systemd-run --user --collect --quiet --unit="$unit" "${bgprio[@]}" \
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

# `crab job dispatch <id>` — a queued record dispatched in place (jobs.md
# rule 32): same id, same sidecar, history intact. Only a queued record; an
# ended job re-runs as a NEW job through requeue. The same preflight as any
# dispatch stands here — the artifact guard on the recorded field (a queued
# corpse from a broken substitution must never wake a builder), and the
# block marker — and DESKCRAB_NO_DISPATCH dry-runs it with the record left
# queued, so the night's rule-61 dry run starts nothing.
job_dispatch_queued() {
    local id="${1:-}"
    [ -n "$id" ] || { echo "Usage: crab job dispatch <id>   (queued ids: crab jobs --state queued)"; return 1; }
    local sidecar="$JOBS_DIR/$id.json"
    [ -e "$sidecar" ] || { echo "No such job: $id   (ids: crab jobs)"; return 1; }
    local state
    state="$("$LIB_DIR/job-status" get "$sidecar" state 2>/dev/null)"
    if [ "$state" != queued ]; then
        echo "Job $id is '$state', not queued — only a queued brief is dispatched in place (jobs.md rule 32)."
        echo "  An ended job re-runs as a new one: crab job requeue $id"
        return 1
    fi
    local desc
    desc="$("$LIB_DIR/job-status" get "$sidecar" description 2>/dev/null)"
    case "$(printf '%s' "$desc" | tr -d '[:space:]')" in
        ''|null|None|undefined)
            echo "Not dispatched — job $id's recorded description ('$desc') looks like a broken command substitution, not a brief."
            echo "  Drop it: crab job drop $id"
            return 1 ;;
    esac
    local block
    if block="$(job_block_active)"; then
        echo "Not dispatched — the last job never began: ${block#*	}"
        echo "  Recorded $(( ${block%%	*} / 60 )) min ago; dispatch is held for ${JOB_BLOCK_RETRY} s from then. The brief stays queued."
        return 1
    fi
    local workdir
    workdir="$("$LIB_DIR/job-status" get "$sidecar" workdir 2>/dev/null)"
    [ -n "$workdir" ] || workdir="$PROJECT_DIR"
    if [ -n "${DESKCRAB_NO_DISPATCH:-}" ]; then
        echo "Would dispatch queued job $id (DESKCRAB_NO_DISPATCH set) in $workdir: $desc"
        return 0
    fi
    job_dispatch_sidecar "$id" "$workdir"
}

# `crab job drop <id>` — the one way off the queue undispatched (jobs.md rule
# 33). Only a queued record: a job that ran has a history worth keeping, and
# silently deleting one would be the vanishing the sidecars exist to prevent.
# The check and the delete run under the record writer's own <id>.lock (rule
# 36), the state re-read inside it: without the lock, a drop racing `crab job
# dispatch` could pass the queued check on a stale read and delete the
# sidecar of a builder the dispatch was in the middle of stamping. Under the
# lock the two serialise against the writer's stamp — a drop that arrives
# second sees `dispatched` and refuses, and a dispatch that arrives second
# finds the record gone and aborts in job_dispatch_sidecar.
job_drop() {
    local id="${1:-}"
    [ -n "$id" ] || { echo "Usage: crab job drop <id>   (queued ids: crab jobs --state queued)"; return 1; }
    local sidecar="$JOBS_DIR/$id.json"
    [ -e "$sidecar" ] || { echo "No such job: $id   (ids: crab jobs)"; return 1; }
    (
        flock 9
        state="$("$LIB_DIR/job-status" get "$sidecar" state 2>/dev/null)"
        if [ "$state" != queued ]; then
            echo "Job $id is '$state', not queued — a job that ran keeps its record (jobs.md rule 33)."
            exit 1
        fi
        rm -f "$JOBS_DIR/$id.json" "$JOBS_DIR/$id.log" "$JOBS_DIR/$id.lock"
        echo "Queued job $id dropped, undispatched."
    ) 9>>"$JOBS_DIR/$id.lock"
}

# Re-dispatch a recorded job from its own sidecar: `crab job requeue <id>`.
# The description and the workdir come off the record, so neither a human nor
# a session ever retypes a field name to get them — which is the whole point.
# On 2026-08-11 a re-dispatch loop typed `.task` where the sidecar's field is
# `.description`, jq answered "null" three times, and three builders were
# dispatched on that one word. The sidecar is the authority here, or the
# requeue does not happen. The redispatch is a new job with its own id, and it
# walks through job_start so every dispatch guard — the substitution-artifact
# refusal, the block marker — applies to it like any other.
job_requeue() {
    local id="$1"
    [ -n "$id" ] || { echo "Usage: crab job requeue <id>   (ids: crab jobs)"; return 1; }
    local sidecar="$JOBS_DIR/$id.json"
    [ -e "$sidecar" ] || { echo "No such job: $id   (ids: crab jobs)"; return 1; }
    local desc workdir
    desc="$("$LIB_DIR/job-status" get "$sidecar" description 2>/dev/null)"
    case "$(printf '%s' "$desc" | tr -d '[:space:]')" in
        ''|null|None|undefined)
            echo "Job $id has no usable description ('${desc}') — nothing to requeue."
            return 1 ;;
    esac
    workdir="$("$LIB_DIR/job-status" get "$sidecar" workdir 2>/dev/null)"
    if [ -z "$workdir" ]; then
        echo "Job $id was recorded before sidecars carried a workdir, so where it ran is not on record."
        echo "  Redispatch by hand: crab job -C <workdir> \"$desc\""
        return 1
    fi
    # The engineering record rides too (jobs.md rule 7b): a requeued brief
    # keeps the obligation its original carried, off the sidecar like the rest.
    local record
    record="$("$LIB_DIR/job-status" get "$sidecar" record 2>/dev/null)"
    if [ -n "$record" ]; then
        job_start -C "$workdir" --record "$record" "$desc"
    else
        job_start -C "$workdir" "$desc"
    fi
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
