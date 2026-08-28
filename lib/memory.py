#!/usr/bin/env python3
# Long-term memory store: sqlite-vec + nomic-embed-text on the local ollama
# daemon. One memory.db holds text, metadata, and vector together; KNN and
# filtering are SQL. Design: design-memory-store.md (storage revised to
# sqlite-vec 2026-08-06 — scale and SQL editability beat hand-editable JSONL,
# and `memory dump` gives back the readable-text view that argument wanted).
#
# Five record kinds. A `directive` is the user's voice: never decayed or
# auto-retired, only superseded by a newer directive, over-retrieved by
# design. A `note` is the assistant's own soft memory. An `episodic` record
# is one moment of her own life — what happened, when (`occurred`), who was
# there (`participants`), and her own first-person `opinion` of it — kept for
# itself, never distilled into a lesson, never decayed, retrieved by
# similarity AND by date (specs/memory-recall.md rules 46-52). `pinned`
# records are always retrieved regardless of similarity. An `observation` is
# one night's shape — gaps, texture, recurrence, unfinished threads — and a
# `miss` is one asking she had nothing for: both accumulate as a series,
# never decay, never dedup, and are NEVER retrieved by similarity into a
# prompt (specs/memory-recall.md rules 42-45).
#
# Fail-safe contract: `recall-block` must NEVER break a prompt build — with
# the embedder down it emits the pinned tier plus a loud warning and exits 0.

import argparse
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime

# The sqlite-vec extension lives in the store's own venv (a PyPI wheel; the
# pacman repos have no sqlite-vec). Re-exec into it when invoked with a bare
# system python.
try:
    import sqlite_vec
except ImportError:
    _venv_py = os.environ.get("MEMORY_PYTHON") or os.path.expanduser(
        "~/.local/share/deskcrab/venv/bin/python")
    if os.path.exists(_venv_py) and os.path.realpath(_venv_py) != os.path.realpath(sys.executable):
        os.execv(_venv_py, [_venv_py] + sys.argv)
    sys.exit("memory: sqlite-vec is not importable and no venv python found.\n"
             "Create it with: uv venv ~/.local/share/deskcrab/venv && "
             "uv pip install --python ~/.local/share/deskcrab/venv/bin/python sqlite-vec")

import sqlite3

EMBED_DIM = 768
EMBED_MODEL = os.environ.get("MEMORY_EMBED_MODEL") or "nomic-embed-text"
EMBED_URL = os.environ.get("MEMORY_EMBED_URL") or "http://localhost:11434/api/embed"
# Retrieval knobs, from the design (13:10/13:15 revisions): notes take the
# top-K above SIM_FLOOR; directives take EVERYTHING above their deliberately
# looser floor, capped, so the assistant's own chatter can never crowd the
# user's rules out. Near-duplicates of an already-taken record are squashed so
# K slots hold K distinct things.
TOP_K = 8
SIM_FLOOR = 0.35
DIRECTIVE_FLOOR = 0.28
DIRECTIVE_CAP = 10
NEAR_DUP_SIM = 0.92
# Reinforcement scoring (13:15 design revision). Notes rank by
#   score = cosine × confidence × decay(last_used_at) × (1 + log(1+use_count) × 0.15)
# Decay counts from the last USE, never creation — a memory used all the time
# must not fade like one never used; a note never yet used decays from its
# creation. The boost is log-shaped (a hundred uses beats ten by a little, not
# tenfold) and capped. Reinforcement lands only through `memory reinforce`
# (the turn-end genuinely-used judge), NEVER on mere retrieval — no
# self-reinforcing loops. Directives rank by raw cosine: never decayed, never
# boosted. The floors above stay raw-cosine cuts; the score orders what
# clears them.
DECAY_HALF_LIFE_DAYS = 90
REINFORCE_WEIGHT = 0.15
REINFORCE_MAX_BOOST = 2.0
# The recall block is NEVER truncated. It held a ~800-token cap that popped
# rows and stamped 'TRUNCATED to fit' in the header — a trim a subagent wrote
# into the spec, which the user never asked for and ordered out on 2026-08-11:
# a memory retrieved and then lost to a size cut is amnesia wearing a header.
# The block's size is governed by RETRIEVAL — TOP_K, DIRECTIVE_CAP and the
# pinned tier bound what is fetched — and a block that outgrows its prompt
# layer is the assembler's over-budget warning to raise, never this module's
# to cut (specs/prompt-assembly.md rule 4).
#
# Temporal grounding (2026-08-11): every record may carry `occurred` — when
# the thing it DESCRIBES happened, distinct from `created`, when the record
# was written about it. The block renders that when-ness in relative human
# terms ("three days ago"), never as a bare stamp; a row with no occurred
# renders its write date named as exactly that ("recorded three days ago")
# rather than passing it off as the event's. Notes with a known occurred take
# a gentle recency-of-relevance factor in scoring, floored so an old note
# that is genuinely the best match is never buried by age alone; directives
# are untouched — never decayed, never buried, exactly as before.
OCCURRED_HALF_LIFE_DAYS = 45
OCCURRED_FLOOR = 0.6
# What the EMBEDDER will take, which is a different and much smaller number
# than what the prompt will take. nomic-embed-text's trained context is 2048
# tokens (`ollama show nomic-embed-text`), and ollama answers anything longer
# with HTTP 400 {"error":"the input length exceeds the context length"} — not
# a truncation, a refusal. An unclamped composed recall query (12 wants
# bullets, each a paragraph, plus 10 conversation lines) measured 19,471
# chars ≈ 5k tokens, so EVERY prompt build 400ed and retrieval silently fell
# back to the pinned tier while `crab memory search "test"` looked fine.
# Measured on this store: 6,000 chars of that text embedded, 8,000 did not.
# Budgets below sit well under it, and embed() shrink-retries anyway, because
# chars-per-token is a guess (emoji and CJK blow past 4) and a query that is
# merely long must never cost the turn its memory.
# The embedder's real limit, derived rather than guessed: nomic-embed-text's
# trained context is 2048 tokens, and chars-per-token is estimated LOW on
# purpose — the cap must be wrong in the safe direction.
#
# Re-measured 2026-08-07 against the live daemon (ollama 0.21.0) with her own
# want documents as the input, since the ceiling is a property of the text as
# much as of the model: 7,000 chars embedded, 8,000 came back
#   HTTP 400 {"error":"the input length exceeds the context length"}
# which puts real prose near 3.5 chars/token. 2.5 puts the ceiling ~27 % under
# the largest input actually observed to work, and the composition budget
# under that again.
#
# Not carried into the design, because it is not understood: the same probe
# with repeated filler ("word " × 40,000, 200,000 chars) embedded without
# complaint at every size tried. Whatever that path is, prose refuses where
# the arithmetic says it should, and prose is what this file embeds.
EMBED_TOKEN_LIMIT = 2048
EMBED_CHARS_PER_TOKEN = 2.5
EMBED_CHAR_CAP = int(EMBED_TOKEN_LIMIT * EMBED_CHARS_PER_TOKEN)  # 5120
EMBED_SHRINK_TRIES = 3
# Composed recall query: the whole thing, all segments together. Sits under
# EMBED_CHAR_CAP with headroom for the "search_query: " prefix and for text
# denser than the ratio above (emoji, CJK) — the wants shelf is full of emoji.
RECALL_QUERY_CHARS = 4800

# --- what the query is ABOUT ------------------------------------------------
# Composition is a question of SUBSTANCE before it is a question of length.
# The 2026-08-07 outage was fixed by shortening the query, and the shortening
# left the wrong subject in place: every prompt build, interactive turns
# included, asked the store about BEATRICE'S WANTS SHELF. Memories have
# nothing to do with wants unless a want is actively being pursued, so:
#
#   in conversation -> the conversation. The user's last turn is the subject;
#     the reply before it is context for that subject and nothing more.
#   on a wake       -> the wake's agenda, and the ONE want being worked if it
#     can be named — its shelf topic plus its most recent dated progress note,
#     never the whole document (see WANT_PROGRESS_CHARS).
#
# Measured against the live store on 2026-08-07: on a conversation in which he
# was telling her off for repeating herself, the wants-shelf query injected
# #16 (CONVO_TIMEOUT) and #19 (verify before reporting done) while the
# conversation query injected #3 (drop 'Claudisms' from your speech), #6 and
# #10 — the store holds 17 directives and only 10 fit, so composition decides
# which rules she is holding while she answers.
RECALL_USER_SHARE = 0.7
# One wants bullet contributes its topic, not its whole history. These are
# multi-paragraph entries with dated progress logs appended; the opening
# clause is what makes them findable. Used only for the no-single-want wake
# fallback — never in conversation.
WANTS_BULLET_CHARS = 240
WANTS_BULLET_MAX = 12
# A focused want gets room its shelf clause cannot hold: the dated note at the
# end of its document is what she is actually doing, and it is the part a
# head-clamped whole-document query throws away first (see recall_query).
WANT_PROGRESS_CHARS = 1500
# "Being worked" needs an upper bound in time, or the shelf's last-touched
# document is named as current work forever.
WANT_RECENT_SECS = 6 * 3600
# Confidence decay (design §3, run by the ingest pass per §5): a note neither
# retrieved nor used in DECAY_STALE_DAYS loses DECAY_STEP confidence per pass
# and retires below DECAY_RETIRE_FLOOR. Directives never decay.
DECAY_STALE_DAYS = 90
DECAY_STEP = 0.1
DECAY_RETIRE_FLOOR = 0.3
# Ingest dedup/supersession. The design left conflict judgement to the ingest
# session; this mechanical layer cannot judge content, so both cuts are set
# from measured data, not the design's thresholds. A one-word factual change
# ("seven" -> "nine") embeds at 0.947, so the design's 0.92 DUPLICATE cut
# would silently keep the STALE fact active — only an exact (normalized) text
# match is a duplicate. And related-but-DISTINCT same-kind rules (shared topic,
# different content) land 0.75-0.90 — the design's 0.75 supersede cut ate two
# real directives on first live ingest — so auto-supersede starts at 0.92,
# where same-fact rephrasings and fact-flips live. Between the two cuts a
# record is simply added; true conflicts below 0.92 wait for the ingest
# session's judgement.
SUPERSEDE_SIM = 0.92
# The hidden kinds (memory-recall.md rules 42-45). An `observation` is the
# shape of one night; a `miss` is one question about the user that a record
# could have answered and none did. Neither is ever returned by the
# similarity retrieval that feeds the recall block — excluded from the query
# outright, not ranked low. For a miss that is not a preference: its text
# names its subject in the user's own words, so it is the best possible
# embedding match for the NEXT asking of the same question, and surfacing it
# would read a record of not-knowing as though it were knowledge. Both stay
# readable on request through the deliberate CLI paths (list, search).
HIDDEN_KINDS = ("observation", "miss")
RECALL_KINDS = ("directive", "note", "episodic")
RECORD_KINDS = RECALL_KINDS + HIDDEN_KINDS
# The episodic pool (memory-recall.md rules 46-48): her own moments, retrieved
# by similarity as a THIRD pool beside notes and directives — its own floor
# and cap, so no kind crowds another out — ranked by similarity × the
# occurred-recency factor (floored: an old evening that is genuinely the best
# match is dimmed, never buried) × the capped use bonus. No confidence decay,
# ever: a decay clock on moments would re-create by arithmetic the
# throw-away-my-life defect the kind exists to close. The floor sits under
# SIM_FLOOR on purpose — rule 50's whole argument is more memories, scored,
# over few memories, curated.
EPISODIC_TOP_K = 5
EPISODIC_FLOOR = 0.30
# A query that NAMES a calendar day gets that day's moments regardless of the
# similarity floor (rule 48) — "what happened on the 5th" embeds nowhere near
# the evening itself — capped so one crowded day cannot flood a block.
EPISODIC_DATE_CAP = 12

# The memories table, spelled once: the CREATE in Store.__init__ and the
# rebuild in Store._widen_kind_check must agree, or a migrated store and a
# fresh one drift apart.
MEMORIES_COLUMNS_SQL = """
    id         INTEGER PRIMARY KEY,
    text       TEXT NOT NULL,
    kind       TEXT NOT NULL
               CHECK (kind IN ('directive','note','episodic','observation','miss')),
    pinned     INTEGER NOT NULL DEFAULT 0,
    source     TEXT NOT NULL DEFAULT 'self',
    topics     TEXT NOT NULL DEFAULT '',
    confidence REAL NOT NULL DEFAULT 1.0,
    status     TEXT NOT NULL DEFAULT 'active'
               CHECK (status IN ('active','superseded','retired')),
    supersedes INTEGER REFERENCES memories(id),
    created    TEXT NOT NULL,
    last_seen  TEXT NOT NULL,
    -- Reinforcement (13:15 design revision): bumped by `memory
    -- reinforce` only when a memory is judged GENUINELY USED at
    -- turn end (`judge-turn`, fired detached by every turn path
    -- via fire_memory_judge), never on mere retrieval. Read by
    -- score_row.
    last_used_at TEXT,
    use_count  INTEGER NOT NULL DEFAULT 0,
    -- Temporal grounding (2026-08-11): when the thing this
    -- record DESCRIBES happened — distinct from `created`, when
    -- the record was written about it. NULL means unknown, and
    -- unknown is left unknown rather than guessed. Rendered in
    -- relative human terms by the recall block; read by
    -- score_row's recency-of-relevance factor (notes and
    -- episodic records).
    occurred   TEXT,
    -- Episodic fields (memory-recall.md rule 46): who was there,
    -- and her own first-person opinion of the moment. Empty for
    -- every other kind; both rendered by the block and both part
    -- of what is embedded.
    participants TEXT NOT NULL DEFAULT '',
    opinion    TEXT NOT NULL DEFAULT ''
"""


def default_dir():
    return os.environ.get("DESKCRAB_MEMORY_DIR") or os.path.expanduser(
        "~/.local/share/deskcrab/memory")


def now_iso():
    return datetime.now().astimezone().isoformat(timespec="seconds")


def parse_iso(ts):
    try:
        parsed = datetime.fromisoformat(ts)
    except (TypeError, ValueError):
        return None
    return parsed.astimezone() if parsed.tzinfo is None else parsed


def _same_day(a, b):
    """Whether two `occurred` stamps name the same calendar day. Either side
    unknown is NOT the same day: episodic supersession (rule 51) must never
    collapse a dated evening into an undated one, or the reverse."""
    pa, pb = parse_iso(a) if a else None, parse_iso(b) if b else None
    return bool(pa and pb and pa.date() == pb.date())


# Rule 48's date parse: only shapes that need no guessing. The ISO form, and
# a prose month-with-day either way round ("August 5th", "5 August", with an
# optional year). A bare year defaults to the most recent PAST occurrence of
# that month and day — "what happened on August 5th" asked in March means
# last August, not the one five months ahead.
_MONTH_NAMES = ["january", "february", "march", "april", "may", "june",
                "july", "august", "september", "october", "november",
                "december"]
_QUERY_ISO_RE = re.compile(r"\b(20\d\d)-(\d\d)-(\d\d)\b")
_QUERY_MDY_RE = re.compile(
    r"\b(" + "|".join(m[:3] + r"(?:" + m[3:] + r")?" for m in _MONTH_NAMES)
    + r")\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s*,?\s*(20\d\d))?\b", re.I)
_QUERY_DMY_RE = re.compile(
    r"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("
    + "|".join(m[:3] + r"(?:" + m[3:] + r")?" for m in _MONTH_NAMES)
    + r")\.?(?:\s*,?\s*(20\d\d))?\b", re.I)


def query_dates(text, today=None):
    """The calendar days a query names, as ISO date strings. Empty for a
    query that names none — which is nearly every query, so the common path
    is one regex scan and out."""
    today = today or datetime.now().astimezone().date()
    found = set()

    def month_num(name):
        return next(i + 1 for i, m in enumerate(_MONTH_NAMES)
                    if m.startswith(name.lower()[:3]))

    def add(year, month, day, year_known):
        try:
            d = datetime(year, month, day).date()
        except ValueError:
            return
        if not year_known and d > today:
            d = d.replace(year=d.year - 1)
        found.add(d.isoformat())

    for m in _QUERY_ISO_RE.finditer(text or ""):
        add(int(m.group(1)), int(m.group(2)), int(m.group(3)), True)
    for m in _QUERY_MDY_RE.finditer(text or ""):
        add(int(m.group(3)) if m.group(3) else today.year,
            month_num(m.group(1)), int(m.group(2)), bool(m.group(3)))
    for m in _QUERY_DMY_RE.finditer(text or ""):
        add(int(m.group(3)) if m.group(3) else today.year,
            month_num(m.group(2)), int(m.group(1)), bool(m.group(3)))
    return sorted(found)


def score_row(row, now):
    """The 13:15 scoring formula, with temporal grounding. Notes:
    cosine × confidence × decay(last use) × (1 + log(1+use_count) × 0.15)
    × recency(occurred), decay exponential with a DECAY_HALF_LIFE_DAYS
    half-life counted from last_used_at (falling back to creation for a note
    never yet used), boost capped at REINFORCE_MAX_BOOST. The recency factor
    reads `occurred` — when the described thing happened — and is FLOORED at
    OCCURRED_FLOOR, so what mattered recently surfaces first while an old
    note that is genuinely the best match is dimmed, never buried; a row
    whose occurred is unknown takes no factor at all, because an unknown left
    unknown must not read as either fresh or stale. Episodic (rule 47):
    similarity × the same floored recency factor × the capped use bonus —
    NO confidence, NO last-use decay, ever: her life does not expire for
    want of being asked about. Directives: raw cosine, untouched — the
    user's rules do not age out."""
    sim = row[9]
    if row[2] not in ("note", "episodic"):
        return sim
    boost = min(1.0 + math.log1p(row[11] or 0) * REINFORCE_WEIGHT,
                REINFORCE_MAX_BOOST)
    occurred = parse_iso(row[12]) if len(row) > 12 and row[12] else None
    recency = 1.0
    if occurred:
        odays = max(0.0, (now - occurred).total_seconds() / 86400)
        recency = OCCURRED_FLOOR + (1.0 - OCCURRED_FLOOR) \
            * 0.5 ** (odays / OCCURRED_HALF_LIFE_DAYS)
    if row[2] == "episodic":
        return sim * boost * recency
    ts = parse_iso(row[10] or row[7])
    days = max(0.0, (now - ts).total_seconds() / 86400) if ts else 0.0
    decay = 0.5 ** (days / DECAY_HALF_LIFE_DAYS)
    return sim * row[6] * decay * boost * recency


def normalize_scope_terms(terms):
    """Case-folded non-empty terms for a specialised recall boundary."""
    return tuple(dict.fromkeys(
        " ".join(str(term).split()).casefold()
        for term in (terms or ())
        if " ".join(str(term).split())
    ))


def row_matches_scope(row, terms):
    """Whether a prompt-facing row belongs to any requested lexical scope.

    Text is included deliberately: older hand-written play lessons predate
    consistent `source`/`topics` metadata but name OpenRSC in the sentence.
    Newer records remain findable through their metadata, participants, or
    episodic opinion as well.
    """
    terms = normalize_scope_terms(terms)
    if not terms:
        return True
    fields = (row[1], row[4], row[5],
              row[13] if len(row) > 13 else "",
              row[14] if len(row) > 14 else "")
    haystack = "\n".join(str(field or "") for field in fields).casefold()
    return any(term in haystack for term in terms)


def select_prompt_rows(rows, scope=(), max_chars=0, warning=""):
    """Filter and size-bound already-ranked rows without cutting any row.

    This serves the no-query and degraded pinned-only paths. Semantic
    retrieval enforces the same rule while filling its separate pools in
    Store.search.
    """
    terms = normalize_scope_terms(scope)
    picked = []
    for row in rows:
        if terms and not row_matches_scope(row, terms):
            continue
        candidate = picked + [row]
        if max_chars and len(build_block(candidate, warning)[0]) > max_chars:
            continue
        picked.append(row)
    return picked


def pack(vec):
    return struct.pack(f"{len(vec)}f", *vec)


class EmbedRejected(RuntimeError):
    """The daemon answered, and said no. Carries the response body."""

    def __init__(self, code, body):
        self.code = code
        self.body = body
        super().__init__(f"embedder rejected the request (HTTP {code})"
                         + (f": {body}" if body else ""))

    @property
    def too_long(self):
        return "context length" in self.body or "too long" in self.body


def _embed_once(texts, prefix, timeout):
    """One POST. An HTTPError's *body* is the only place the daemon says what
    was actually wrong — urllib's str() is the generic 'HTTP Error 400: Bad
    Request', which is what made a plain length refusal look like a dead
    embedder for a whole day."""
    req = urllib.request.Request(
        EMBED_URL,
        data=json.dumps({"model": EMBED_MODEL,
                         "input": [prefix + t for t in texts]}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)["embeddings"]
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode("utf-8", "replace").strip()
        except Exception:
            body = ""
        raise EmbedRejected(e.code, body) from None


def embed(texts, query=False, timeout=30):
    """Embed a list of texts via the local ollama daemon. nomic-embed-text
    wants its task prefix: search_document at ingest, search_query at recall.

    Length is this call's job, not its callers'. Every text is clamped to
    EMBED_CHAR_CAP, and a refusal that names the context length is retried
    at half the length (EMBED_SHRINK_TRIES times) rather than raised: a
    chars-per-token estimate is a guess, and no query is worth losing the
    turn's whole memory over. Callers should still compose short queries —
    this is the floor under them, not the plan."""
    prefix = "search_query: " if query else "search_document: "
    clamped = [(t or "")[:EMBED_CHAR_CAP] for t in texts]
    cap = EMBED_CHAR_CAP
    for attempt in range(EMBED_SHRINK_TRIES + 1):
        try:
            out = _embed_once(clamped, prefix, timeout)
            break
        except EmbedRejected as e:
            if not e.too_long or attempt == EMBED_SHRINK_TRIES:
                raise
            cap = max(200, cap // 2)
            clamped = [t[:cap] for t in clamped]
    if len(out) != len(texts) or any(len(v) != EMBED_DIM for v in out):
        raise RuntimeError(f"embedder returned wrong shape (model {EMBED_MODEL})")
    return out


def _live_memory_dirs():
    """The store paths that belong to the live instance. Both spellings, so a
    live store is never mistaken for a scratch one: default_dir derives from
    ~ and lib/common.sh derives its neighbours from XDG_DATA_HOME."""
    dirs = [os.path.expanduser("~/.local/share/deskcrab/memory")]
    data = os.environ.get("XDG_DATA_HOME")
    if data:
        dirs.append(os.path.join(data, "deskcrab", "memory"))
    return [os.path.abspath(d) for d in dirs]


def _notice_suppress_file(directory):
    """Where this store's write declaration belongs.

    A declaration is only worth anything to the watcher that reads it, and
    lib/notice-selfchange reads ONE file: the live state directory's. A store
    that is not the live store — every test store, every scratch instance —
    has no business in that file. On 2026-08-07 five `/tmp/memtest-*` records
    written by the test suite were sitting in the live one. This is the same
    rule lib/job-runner already applies to the wake it fires: a run that is not
    the live one does not get to reach the live me.

    The explicit knobs win over both, so a caller that has already decided
    where its declarations go (lib/common.sh sets NOTICE_STATE_DIR and
    NOTICE_SUPPRESS) is obeyed rather than second-guessed.
    """
    explicit = os.environ.get("NOTICE_SUPPRESS")
    if explicit:
        return explicit
    state_dir = os.environ.get("NOTICE_STATE_DIR")
    if not state_dir:
        if os.path.abspath(directory) not in _live_memory_dirs():
            return os.path.join(directory, "notice-self.suppress")
        state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser(
            "~/.local/state")
        state_dir = os.path.join(state, "deskcrab")
    return os.path.join(state_dir, "notice-self.suppress")


def _notice_touch(directory, window=900):
    """Declare an imminent write for lib/notice-selfchange (crab touching).

    sqlite touches memory.db on ~every open — WAL checkpoints, last_seen
    bumps — and every opener of this store is the assistant's own plumbing,
    so the declaration happens here rather than at each call site. Same
    record format and lock as touch_suppress in lib/common.sh.
    """
    sup = _notice_suppress_file(directory)
    try:
        import fcntl
        os.makedirs(os.path.dirname(sup), exist_ok=True)
        with open(sup + ".lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with open(sup, "a") as f:
                f.write("%d\t%s\n" % (int(time.time()) + window,
                                      os.path.abspath(directory)))
    except OSError:
        pass


class Store:
    def __init__(self, directory=None):
        self.dir = directory or default_dir()
        os.makedirs(self.dir, exist_ok=True)
        self.path = os.path.join(self.dir, "memory.db")
        _notice_touch(self.dir)
        self.db = sqlite3.connect(self.path)
        self.db.enable_load_extension(True)
        sqlite_vec.load(self.db)
        self.db.enable_load_extension(False)
        # WAL + busy_timeout replace the flock discipline the JSONL design
        # needed: a wake and an ingest pass can write concurrently.
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA busy_timeout=5000")
        self.db.executescript(f"""
            CREATE TABLE IF NOT EXISTS memories ({MEMORIES_COLUMNS_SQL});
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_vec USING vec0(
                embedding float[{EMBED_DIM}] distance_metric=cosine
            );
        """)
        # Stores born before temporal grounding: add the column in place.
        cols = {r[1] for r in self.db.execute("PRAGMA table_info(memories)")}
        if "occurred" not in cols:
            self.db.execute("ALTER TABLE memories ADD COLUMN occurred TEXT")
            self.db.commit()
        # Stores born before the episodic kind: the two fields of rule 46,
        # added in place exactly as `occurred` was, before the CHECK rebuild
        # below copies every column by name.
        if "participants" not in cols:
            self.db.execute("ALTER TABLE memories ADD COLUMN participants"
                            " TEXT NOT NULL DEFAULT ''")
            self.db.execute("ALTER TABLE memories ADD COLUMN opinion"
                            " TEXT NOT NULL DEFAULT ''")
            self.db.commit()
        self._widen_kind_check()

    def _widen_kind_check(self):
        """Stores born before the observation/miss kinds carry the two-kind
        CHECK, and stores born before the episodic kind carry the four-kind
        one; sqlite cannot ALTER a constraint in place, so the table is
        rebuilt around the data. Every column travels by name — ids
        explicitly, so the vec table's rowids still point at the same records
        and the vectors are never touched; use_count and last_used_at ride
        with the rest. Runs after the column backfills above, so a store old
        enough to lack any of the late columns is first given them, then
        rebuilt."""
        sql = self.db.execute(
            "SELECT sql FROM sqlite_master WHERE type='table'"
            " AND name='memories'").fetchone()[0]
        if "'episodic'" in sql:
            return
        cols = ("id, text, kind, pinned, source, topics, confidence, status,"
                " supersedes, created, last_seen, last_used_at, use_count,"
                " occurred, participants, opinion")
        self.db.executescript(f"""
            BEGIN;
            CREATE TABLE memories_migrate ({MEMORIES_COLUMNS_SQL});
            INSERT INTO memories_migrate ({cols}) SELECT {cols} FROM memories;
            DROP TABLE memories;
            ALTER TABLE memories_migrate RENAME TO memories;
            COMMIT;
        """)

    def embed_text(self, rec_text, topics="", participants="", opinion=""):
        # An episodic record is findable by its opinion and its people as much
        # as by the event — "that evening we laughed about X with Y" has to
        # match on all three — so both fields ride the embedded body (rule 46).
        body = rec_text
        if opinion:
            body += f" {opinion}"
        if participants:
            body += f" [with: {participants}]"
        if topics:
            body += f" [topics: {topics}]"
        return embed([body])[0]

    def insert(self, text, kind="note", pinned=False, source="self",
               topics="", vec=None, occurred=None, participants="",
               opinion=""):
        if vec is None:
            vec = self.embed_text(text, topics, participants, opinion)
        now = now_iso()
        cur = self.db.execute(
            "INSERT INTO memories (text, kind, pinned, source, topics, created,"
            " last_seen, occurred, participants, opinion)"
            " VALUES (?,?,?,?,?,?,?,?,?,?)",
            (text, kind, 1 if pinned else 0, source, topics, now, now,
             occurred or None, participants or "", opinion or ""))
        self.db.execute("INSERT INTO memories_vec (rowid, embedding) VALUES (?,?)",
                        (cur.lastrowid, pack(vec)))
        self.db.commit()
        return cur.lastrowid

    def knn(self, vec, k, kinds=None):
        """Raw KNN against active records: rows with cosine similarity at
        index 9, best raw similarity first. `kinds` restricts the match to
        those kinds IN THE QUERY — the retrieval that feeds a prompt excludes
        the hidden kinds outright rather than ranking them low
        (memory-recall.md rule 43)."""
        # Superseded/retired rows keep their vectors (history is kept), so the
        # KNN budget must span the WHOLE vec table or low-similarity active
        # rows fall off the end of the join filter. The corpus is small enough
        # that fetching every vector is still sub-millisecond.
        total = self.db.execute("SELECT count(*) FROM memories_vec").fetchone()[0]
        if total == 0:
            return []
        where = "v.embedding MATCH ? AND v.k = ? AND m.status = 'active'"
        params = [pack(vec), total]
        if kinds:
            where += " AND m.kind IN (%s)" % ",".join("?" * len(kinds))
            params += list(kinds)
        rows = self.db.execute(
            "SELECT m.id, m.text, m.kind, m.pinned, m.source, m.topics,"
            "       m.confidence, m.created, m.last_seen, 1.0 - v.distance AS sim,"
            "       m.last_used_at, m.use_count, m.occurred, m.participants,"
            "       m.opinion"
            " FROM memories_vec v JOIN memories m ON m.id = v.rowid"
            f" WHERE {where}"
            " ORDER BY sim DESC",
            params).fetchall()
        return rows[:k] if k else rows

    def on_date(self, dates, cap=None):
        """Active episodic rows whose `occurred` falls on one of `dates`
        (ISO YYYY-MM-DD strings), oldest moment first, in the same row shape
        knn returns — similarity 1.0, because a named day is an explicit ask,
        not a match (rule 48)."""
        dates = sorted(set(dates))
        if not dates:
            return []
        q = ("SELECT id, text, kind, pinned, source, topics, confidence,"
             "       created, last_seen, 1.0, last_used_at, use_count,"
             "       occurred, participants, opinion"
             " FROM memories WHERE status='active' AND kind='episodic'"
             "   AND occurred IS NOT NULL AND date(occurred) IN (%s)"
             " ORDER BY occurred" % ",".join("?" * len(dates)))
        rows = self.db.execute(q, dates).fetchall()
        return rows[:cap] if cap else rows

    def vec_of(self, rec_id):
        blob = self.db.execute("SELECT embedding FROM memories_vec WHERE rowid=?",
                               (rec_id,)).fetchone()[0]
        return struct.unpack(f"{EMBED_DIM}f", blob)

    def _near_dup(self, row, picked):
        v = self.vec_of(row[0])
        for p in picked:
            pv = self.vec_of(p[0])
            dot = sum(a * b for a, b in zip(v, pv))
            na = sum(a * a for a in v) ** 0.5
            nb = sum(a * a for a in pv) ** 0.5
            if na and nb and dot / (na * nb) >= NEAR_DUP_SIM:
                return True
        return False

    def search(self, query, k=TOP_K, deliberate=False, scope=(),
               directive_cap=DIRECTIVE_CAP, episodic_cap=EPISODIC_TOP_K,
               max_chars=0):
        """The retrieval rule from the design's 13:15 revision — two pools
        with different floors, queried separately so the assistant's own
        chatter can never crowd the user's rules out: notes take the top-K
        above SIM_FLOOR ranked by the reinforcement score, directives take
        everything above the deliberately looser DIRECTIVE_FLOOR (capped, raw
        cosine — never decayed or boosted), and every pinned record rides
        along regardless. Near-duplicates of an already-taken record are
        squashed so K slots hold K distinct things.

        The default query is restricted to those two kinds IN THE SQL —
        observations and misses never reach a prompt this way, however well
        they match (rule 43). `deliberate` is the CLI search verb's opt-in: a
        typed query is a request to read, so the hidden kinds are matched too
        and returned as their own pool, raw cosine, after the others.

        A specialised prompt may additionally pass lexical `scope` terms and
        smaller pool/character caps. Scope is an OR across the record's text,
        source, topics, participants and opinion, applied before selection and
        to pinned rows too. `max_chars` bounds selection against the rendered
        block; build_block still renders every selected row whole."""
        t0 = time.monotonic()
        qvec = embed([query], query=True)[0]
        t1 = time.monotonic()
        terms = normalize_scope_terms(scope)
        rows = self.knn(qvec, 0, kinds=None if deliberate else RECALL_KINDS)
        if terms:
            rows = [row for row in rows if row_matches_scope(row, terms)]
        now = datetime.now().astimezone()
        picked, seen = [], set()

        def take(row):
            if row[0] in seen or (terms and not row_matches_scope(row, terms)):
                return False
            if self._near_dup(row, picked):
                return False
            candidate = picked + [row]
            if max_chars and len(build_block(candidate)[0]) > max_chars:
                return False
            picked.append(row)
            seen.add(row[0])
            return True

        notes = sorted((r for r in rows if r[2] == "note" and r[9] >= SIM_FLOOR),
                       key=lambda r: score_row(r, now), reverse=True)
        taken = 0
        for row in notes:
            if taken >= k:
                break
            taken += take(row)
        # The episodic pool (rule 47): her own moments, a third pool with its
        # own floor and cap so no kind crowds another out, ranked by the
        # episodic score — similarity × floored occurred-recency × use bonus.
        episodic = sorted((r for r in rows
                           if r[2] == "episodic" and r[9] >= EPISODIC_FLOOR),
                          key=lambda r: score_row(r, now), reverse=True)
        etaken = 0
        for row in episodic:
            if etaken >= episodic_cap:
                break
            etaken += take(row)
        # Rule 48: a query that names a calendar day gets that day's moments
        # whatever their similarity — "what happened on the 5th" embeds
        # nowhere near the evening itself.
        for row in self.on_date(query_dates(query), cap=EPISODIC_DATE_CAP):
            take(row)
        directives = 0
        for row in rows:
            if directives >= directive_cap:
                break
            if row[2] == "directive" and row[9] >= DIRECTIVE_FLOOR:
                directives += take(row)
        if deliberate:
            hidden = 0
            for row in rows:
                if hidden >= k:
                    break
                if row[2] in HIDDEN_KINDS and row[9] >= SIM_FLOOR:
                    hidden += take(row)
        for row in self.pinned_rows():
            # General recall's pinned tier is unconditional and predates the
            # near-duplicate rule: preserve it exactly. A specialised scope
            # may filter/budget pinned rows, but a relevant pinned record is
            # never silently squashed merely because a selected note echoes
            # it.
            if row[0] in seen or (terms and not row_matches_scope(row, terms)):
                continue
            candidate = picked + [row]
            if max_chars and len(build_block(candidate)[0]) > max_chars:
                continue
            picked.append(row)
            seen.add(row[0])
        t2 = time.monotonic()
        if picked:
            now = now_iso()
            self.db.executemany("UPDATE memories SET last_seen=? WHERE id=?",
                                [(now, r[0]) for r in picked])
            self.db.commit()
        return picked, (t1 - t0) * 1000, (t2 - t1) * 1000

    def add_deduped(self, text, kind="note", pinned=False, source="self",
                    topics="", occurred=None, participants="", opinion=""):
        """Insert with the ingest rules: same-kind exact text -> skip and bump
        last_seen; same-kind similar-but-different -> the new record
        supersedes the old. Returns (action, id). A duplicate that arrives
        knowing WHEN fills an existing record's unknown `occurred` — new
        knowledge about an old record, not a new record — and never overwrites
        one already known. Episodic dedup is NARROW (rule 51): an exact match
        is a duplicate, the supersede threshold bites only when both records
        describe the same day — two similar evenings a week apart are two
        evenings — and anything else adds."""
        if kind in HIDDEN_KINDS:
            # Rule 44: one record per night, one per asking. A similar record
            # on another day is the recurrence the series exists to
            # accumulate, not a redundancy to squash — deduplicating the knee
            # asked about three times into one row destroys the n the kind is
            # for. No dedup, no supersession, ever.
            return "added", self.insert(text, kind, pinned, source, topics,
                                        occurred=occurred)
        vec = self.embed_text(text, topics, participants, opinion)
        best = None
        for row in self.knn(vec, 5, kinds=(kind,)):
            if row[2] == kind:
                best = row
                break
        if best and " ".join(best[1].split()).lower() == " ".join(text.split()).lower():
            self.db.execute("UPDATE memories SET last_seen=? WHERE id=?",
                            (now_iso(), best[0]))
            if occurred and not best[12]:
                self.db.execute("UPDATE memories SET occurred=? WHERE id=?",
                                (occurred, best[0]))
            self.db.commit()
            return "duplicate", best[0]
        if best and best[9] >= SUPERSEDE_SIM and (
                kind != "episodic" or _same_day(occurred, best[12])):
            new_id = self.insert(text, kind, pinned, source, topics, vec=vec,
                                 occurred=occurred, participants=participants,
                                 opinion=opinion)
            self.db.execute(
                "UPDATE memories SET status='superseded' WHERE id=?", (best[0],))
            self.db.execute(
                "UPDATE memories SET supersedes=? WHERE id=?", (best[0], new_id))
            self.db.commit()
            return "superseded", new_id
        return "added", self.insert(text, kind, pinned, source, topics, vec=vec,
                                    occurred=occurred, participants=participants,
                                    opinion=opinion)

    def pinned_rows(self):
        # The hidden kinds are excluded even here: every caller of this tier
        # is prompt-facing (the recall block and its degraded path), and a
        # pinned observation riding it would auto-surface an n=1 anecdote —
        # exactly what rule 43 forbids. The deliberate list still shows it.
        return self.db.execute(
            "SELECT id, text, kind, pinned, source, topics, confidence,"
            "       created, last_seen, 1.0, last_used_at, use_count, occurred,"
            "       participants, opinion"
            " FROM memories WHERE status='active' AND pinned=1"
            "   AND kind NOT IN ('observation','miss')"
            " ORDER BY kind DESC, id").fetchall()

    def reinforce(self, ids):
        """Mark records as genuinely USED this turn (the turn-end judge's
        write path — never called on mere retrieval): stamp last_used_at,
        bump use_count. Returns the ids that actually existed."""
        now = now_iso()
        hit = []
        for rec_id in ids:
            n = self.db.execute(
                "UPDATE memories SET last_used_at=?, use_count=use_count+1"
                " WHERE id=?", (now, rec_id)).rowcount
            if n:
                hit.append(rec_id)
        self.db.commit()
        return hit

    def decay_pass(self):
        """§3 soft decay, run by the ingest pass (§5): an active note not
        genuinely USED in DECAY_STALE_DAYS loses DECAY_STEP confidence;
        below DECAY_RETIRE_FLOOR it flips to retired. Directives never decay.

        The clock is last_used_at falling back to created — NEVER last_seen
        (rules 21 and 26, MAJ-26 closed 2026-08-26): retrieval bumps
        last_seen every time the retriever surfaces a note, so counting it
        froze precisely the surfaced-constantly, credited-never note the
        decay exists to retire. Retrieval alone must never keep a score
        alive; only the turn-end judge's credit may."""
        now = datetime.now().astimezone()
        decayed, retired = 0, 0
        for rec_id, conf, created, used in self.db.execute(
                "SELECT id, confidence, created, last_used_at FROM memories"
                " WHERE status='active' AND kind='note'").fetchall():
            stamps = [t for t in (parse_iso(created), parse_iso(used)) if t]
            if not stamps:
                continue
            if (now - max(stamps)).total_seconds() < DECAY_STALE_DAYS * 86400:
                continue
            conf = round(conf - DECAY_STEP, 3)
            if conf < DECAY_RETIRE_FLOOR:
                self.db.execute(
                    "UPDATE memories SET confidence=?, status='retired'"
                    " WHERE id=?", (conf, rec_id))
                retired += 1
            else:
                self.db.execute("UPDATE memories SET confidence=? WHERE id=?",
                                (conf, rec_id))
                decayed += 1
        self.db.commit()
        return decayed, retired


# --- recall-block: the prompt-facing view -----------------------------------

def _segment(text, limit=None):
    """One query segment: whitespace collapsed to single spaces (newlines and
    blank runs are nothing but tokens here) and clamped. Empty in, empty out —
    callers drop the empties rather than composing a query of blank lines."""
    out = " ".join((text or "").split())
    if limit is not None and len(out) > limit:
        out = out[:limit].rstrip()
    return out


DISPLAY_DELIM = "---DISPLAY---"
# The conversation's block headers, with the local-time stamp OPTIONAL — every
# transcript written before 2026-08-07 and every archive is unstamped, and a
# pattern that silently stops matching those would compose an empty query and
# look exactly like a quiet conversation. Same shape as CONVO_BLOCK_RE in
# common.sh and BLOCK_HDR in serve.py.
CONVO_HDR_RE = re.compile(r"^(User|Assistant)(?: \[[^\]]*\])?(?: \([^)]*\))?: ", re.M)
# Lines that are nothing but a bracketed marker — "[Autonomous wake — ...]" —
# sit between blocks and belong to neither speaker.
CONVO_MARKER_RE = re.compile(r"^\[[^\]]*\]\s*$", re.M)


def _spoken(text):
    """One side of an exchange as it was actually said: the display channel
    dropped (it is markdown for a window, not words about the subject), inter-
    block markers dropped, whitespace collapsed."""
    text = (text or "").split(DISPLAY_DELIM)[0]
    return _segment(CONVO_MARKER_RE.sub("", text))


def convo_last_exchange(convo_file):
    """The last user block and the assistant block immediately before it,
    headers stripped. Returns ("", "") when there is no user block at all —
    a conversation nobody has spoken into yet is not a subject."""
    if not convo_file or not os.path.isfile(convo_file):
        return "", ""
    with open(convo_file, errors="replace") as f:
        text = f.read()
    marks = [(m.start(), m.group(1), m.end())
             for m in CONVO_HDR_RE.finditer(text)]
    users = [i for i, m in enumerate(marks) if m[1] == "User"]
    if not users:
        return "", ""
    i = users[-1]
    end = marks[i + 1][0] if i + 1 < len(marks) else len(text)
    user = _spoken(text[marks[i][2]:end])
    prev = ""
    if i and marks[i - 1][1] == "Assistant":
        prev = _spoken(text[marks[i - 1][2]:marks[i][0]])
    return user, prev


def _clip(text, limit, dropped=None, what=""):
    """Clip to a limit, RECORDING that it bit. Every silent clip in this file
    is a place the query can quietly stop being the question that was asked —
    which is the shape of the outage, not a detail of it."""
    if len(text) <= limit:
        return text
    if dropped is not None:
        dropped.append(f"{what} {len(text)}->{limit}")
    return text[:limit].rstrip()


def conversation_query(convo_file, budget=RECALL_QUERY_CHARS, dropped=None):
    """(a) In conversation the subject is the conversation — the user's last
    turn first and holding most of the budget, her own preceding reply behind
    it as context. No wants: what she wants has nothing to do with what he
    just asked, and putting the shelf in this query is what made every
    interactive turn retrieve her sleep-pipeline housekeeping."""
    user, prev = convo_last_exchange(convo_file)
    if not user:
        return ""
    user_cap = budget if not prev else int(budget * RECALL_USER_SHARE)
    parts = [_clip(user, user_cap, dropped, "user turn")]
    room = budget - len(parts[0]) - 1
    if prev and room > 0:
        parts.append(_clip(prev, room, dropped, "preceding reply"))
    elif prev:
        _clip(prev, 0, dropped, "preceding reply")
    return "\n".join(p for p in parts if p)


def _shelf_bullets(wants_file):
    """Top-level shelf bullets, whole, in shelf order, each paired with the
    want document it points at."""
    out = []
    if not wants_file or not os.path.isfile(wants_file):
        return out
    with open(wants_file, errors="replace") as f:
        for line in f:
            if not line.startswith("- "):
                continue
            m = re.search(r"wants/([A-Za-z0-9._-]+)\.md", line)
            out.append((line[2:].strip(), m.group(1) if m else ""))
    return out


def want_progress(doc_path, limit=WANT_PROGRESS_CHARS):
    """A want document's most recent DATED section — what she is doing now.

    Not the whole document, and the reason is measurable rather than
    aesthetic: these documents grow by APPENDING today's log to the end, and
    embed() clamps from the front, so a whole-document query is silently a
    first-N-chars query over the OLDEST material. Measured 2026-08-07 on
    wants/sleeping-every-night.md (24,399 chars): the clamp kept the founding
    day and dropped all six of that day's dated sections, every one of them
    the work actually in hand."""
    try:
        with open(doc_path, errors="replace") as f:
            text = f.read()
    except OSError:
        return ""
    heads = list(re.finditer(r"^##\s+.*$", text, re.M))
    dated = [m for m in heads if re.search(r"20\d\d-\d\d-\d\d", m.group(0))]
    if not dated:
        return ""
    last = dated[-1]
    nxt = next((m.start() for m in heads if m.start() > last.start()), len(text))
    return _segment(text[last.start():nxt], limit)


def want_focus(reason, wants_file):
    """The ONE want being worked, or None. Two ways to be identifiable, in
    order of how directly they say so:

    1. the wake's reason names the want's document or slug — it said what it
       came about;
    2. failing that, the single most recently written want document, if it was
       written inside WANT_RECENT_SECS. A want she edited within the last few
       hours is the want in hand; one she has not touched since yesterday is
       not, and gets no special place in the query.

    Neither holding means no single want is identifiable, and the caller falls
    back to the shelf topics — which is what shipped before this, for every
    session rather than for this one case."""
    bullets = _shelf_bullets(wants_file)
    if not bullets:
        return None
    wants_dir = os.path.join(os.path.dirname(wants_file), "wants")

    if reason:
        named = [(line, slug) for line, slug in bullets
                 if slug and (f"wants/{slug}.md" in reason or slug in reason)]
        if len(named) == 1:
            return named[0]

    newest, newest_at = None, 0
    for line, slug in bullets:
        if not slug:
            continue
        try:
            at = os.path.getmtime(os.path.join(wants_dir, slug + ".md"))
        except OSError:
            continue
        if at > newest_at:
            newest, newest_at = (line, slug), at
    if newest and time.time() - newest_at <= WANT_RECENT_SECS:
        return newest
    return None


def wake_query(reason, wants_file, budget=RECALL_QUERY_CHARS, dropped=None):
    """(b) On a wake there is no user turn, so the subject is the agenda: the
    reason it woke, plus the one want being worked if one can be named — that
    want's shelf topic and its current dated progress note. When no single
    want is identifiable the shelf topics stand in, as before."""
    parts, used = [], 0

    def take(seg, what=""):
        nonlocal used
        if not seg:
            return False
        # The joining newline is charged only where a join happens: the first
        # segment costs its own length and nothing more, so a segment exactly
        # the size of the budget is WITHIN the budget (rule 9). The old
        # accounting charged +1 unconditionally, which made the boundary
        # exclusive — a reason clipped to exactly the budget was then thrown
        # away whole, and the longest agendas composed a query missing
        # precisely their subject (MAJ-22).
        need = len(seg) + (1 if parts else 0)
        if used + need > budget:
            if dropped is not None:
                dropped.append(f"{what or 'segment'} dropped ({len(seg)} "
                               f"chars, {budget - used} left)")
            return False
        parts.append(seg)
        used += need
        return True

    take(_clip(_segment(reason), budget, dropped, "wake reason"), "reason")
    focus = want_focus(reason, wants_file)
    if focus:
        line, slug = focus
        take(_segment(line, WANTS_BULLET_CHARS), f"want topic ({slug})")
        take(want_progress(os.path.join(
            os.path.dirname(wants_file), "wants", slug + ".md")),
            f"want progress ({slug})")
        return "\n".join(parts)
    if reason:
        # An agenda of its own and no want to attach it to: the reason IS the
        # subject. Padding it with twelve unrelated shelf topics is the
        # dilution this whole function exists to stop.
        return "\n".join(parts)
    for line, slug in _shelf_bullets(wants_file)[:WANTS_BULLET_MAX]:
        take(_segment(line, WANTS_BULLET_CHARS), f"shelf topic ({slug})")
    return "\n".join(parts)


def recall_query(reason, wants_file, convo_file, budget=RECALL_QUERY_CHARS,
                 wake=False, log=None):
    """Compose the retrieval query for one prompt build, and never hand the
    embedder more than it will take.

    `wake` is the session's own knowledge of what it is (SESSION_KIND, the
    same thing the rest of lib/ goes by); a non-empty reason implies it, since
    only a wake has one. The two shapes are conversation_query (a) and
    wake_query (b) above.

    The cap is hard and its bite is LOGGED. The 2026-08-07 outage was not a
    crash: the query grew to 19,471 chars, ollama refused it, the fail-safe
    contract degraded retrieval to the pinned tier, and nothing anywhere said
    so — for a whole day, while `crab memory search` looked perfectly healthy
    because a typed query is short."""
    dropped = []
    if wake or reason:
        shape = "wake"
        query = wake_query(reason, wants_file, budget, dropped)
    else:
        shape = "conversation"
        query = conversation_query(convo_file, budget, dropped)
    query = _clip(query.strip(), budget, dropped, "composed query")
    if dropped:
        recall_log(log, f"TRUNCATED {shape} query to {len(query)}/{budget} "
                        f"chars (embedder takes ~{EMBED_TOKEN_LIMIT} tokens): "
                        + "; ".join(dropped))
    return query


def recall_log(path, line):
    """One line to the deskcrab log. Degradation must never be as quiet as
    working — that is the whole lesson of the outage this function dates
    from — so the default sink is derived rather than required: a caller that
    forgets to pass one still leaves a trace."""
    if path is None:
        prefix = os.environ.get("DESKCRAB_STATE_PREFIX") or "/tmp/deskcrab"
        path = f"{prefix}-memory-recall.log"
    if not path:
        return
    try:
        with open(path, "a") as f:
            f.write(f"{now_iso()}\t{line}\n")
    except OSError:
        pass


_NUM_WORDS = ["zero", "one", "two", "three", "four", "five", "six", "seven",
              "eight", "nine", "ten", "eleven", "twelve"]


def _num_word(n):
    return _NUM_WORDS[n] if 0 <= n < len(_NUM_WORDS) else str(n)


def relative_when(ts, now=None):
    """A stamp's when-ness in the words a person uses — 'yesterday', 'three
    days ago', 'about two months ago' — because a bare timestamp retrieved
    into a prompt is arithmetic she has to do while answering, and mostly
    does not. Calendar days, not 24-hour buckets, so last night reads
    'yesterday' the moment the date turns. Empty string for a stamp that
    does not parse: an unknown is rendered as nothing, never guessed at."""
    then = parse_iso(ts)
    if not then:
        return ""
    now = now or datetime.now().astimezone()
    days = (now.date() - then.astimezone().date()).days
    if days <= 0:
        return "earlier today"
    if days == 1:
        return "yesterday"
    if days < 7:
        return f"{_num_word(days)} days ago"
    if days < 11:
        return "about a week ago"
    if days < 28:
        return f"about {_num_word(max(2, round(days / 7)))} weeks ago"
    if days < 320:
        months = round(days / 30.44)
        return "about a month ago" if months <= 1 \
            else f"about {_num_word(months)} months ago"
    if days < 550:
        return "about a year ago"
    return f"about {_num_word(max(2, round(days / 365.25)))} years ago"


def build_block(rows, warning=""):
    """The recall block, whole, plus the rows in it — which is ALL of them:
    nothing here drops a row, so the reinforcement judge's sidecar and the
    block state the same records by construction. A ~800-token cap used to
    pop rows from the tail and stamp 'TRUNCATED to fit' in the header; that
    cut entered the spec by a subagent's hand, not the user's, and he ordered
    it out on 2026-08-11 — a memory retrieved and then lost to a size cut is
    amnesia wearing a header. The block's size is bounded by RETRIEVAL
    (TOP_K, DIRECTIVE_CAP, the pinned tier), and a block that outgrows its
    prompt layer is the assembler's over-budget warning to raise
    (specs/prompt-assembly.md rules 4 and 36), never this module's to trim.

    Temporal grounding: every row renders its when-ness in relative human
    terms. A known `occurred` speaks for the thing itself ('three days
    ago'); a row without one has its write date speak, named as exactly that
    ('recorded three days ago') rather than passed off as the event's."""
    if not rows and not warning:
        return "", []
    now = datetime.now().astimezone()

    def when(r, directive=False):
        occurred = r[12] if len(r) > 12 else None
        if occurred:
            rel = relative_when(occurred, now)
            if rel:
                return f"standing since {rel}" if directive else rel
        rel = relative_when(r[7], now)
        return f"recorded {rel}" if rel else ""

    def line(r, directive=False):
        stamp = when(r, directive)
        return f"- {r[1]} ({stamp})" if stamp else f"- {r[1]}"

    directives = [r for r in rows if r[2] == "directive"]
    notes = [r for r in rows if r[2] == "note"]
    episodic = [r for r in rows if r[2] == "episodic"]
    # Retrieval never hands the hidden kinds in (rule 43); these sections
    # exist so that a deliberate future caller CANNOT render one unlabelled.
    # The label is the enforcement (rule 45): an observation is one night and
    # a miss is one asking, and neither may be spoken as a pattern from an n
    # of one — a miss over-read aloud is accusation-shaped.
    observations = [r for r in rows if r[2] == "observation"]
    misses = [r for r in rows if r[2] == "miss"]
    out = ["## What I remember (retrieved, not exhaustive"
           " — 'crab memory search <query>' for more)"]
    if warning:
        out.append(f"\n{warning}")
    if directives:
        out.append("\nWhat I hold to:")
        out.extend(line(r, directive=True) for r in directives)
    if notes:
        out.append("\nWhat I know from my own time:")
        out.extend(line(r) for r in notes)
    if episodic:
        # Rule 49: the moment, whole — the thing itself, its when-ness, who
        # was there, and her own opinion beside it, never a summary that
        # flattens it back into a note.
        out.append("\nMoments from my own life:")
        for r in episodic:
            stamp = when(r)
            who = r[13] if len(r) > 13 and r[13] else ""
            opinion = r[14] if len(r) > 14 and r[14] else ""
            details = "; ".join(d for d in (stamp, f"with {who}" if who else "")
                                if d)
            entry = f"- {r[1]}" + (f" ({details})" if details else "")
            if opinion:
                entry += f" — {opinion}"
            out.append(entry)
    if observations:
        out.append("\nShapes I have seen (one night each — a series may be "
                   "spoken, with its n; a single night never):")
        out.extend(line(r) for r in observations)
    if misses:
        out.append("\nWhat I was asked and had nothing for (one asking each "
                   "— never to be spoken as a pattern):")
        out.extend(line(r) for r in misses)
    return "\n".join(out), directives + notes + episodic + observations + misses


def format_block(rows, warning=""):
    return build_block(rows, warning)[0]


def write_ids_out(path, rows):
    """Sidecar for the turn-end judge: which records were injected into this
    prompt build. No injected records means no file — the judge has nothing
    to weigh, and the turn path skips the spawn entirely."""
    if not path:
        return
    if not rows:
        try:
            os.remove(path)
        except OSError:
            pass
        return
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump([{"id": r[0], "kind": r[2], "text": r[1]} for r in rows], f)
    os.replace(tmp, path)


def cmd_recall_block(store, args):
    query = args.query or recall_query(args.reason, args.wants, args.convo,
                                       wake=args.wake, log=args.log or None)
    if min(args.notes, args.directives, args.episodes, args.max_chars) < 0:
        print("memory: recall caps must be non-negative", file=sys.stderr)
        return 2
    if args.max_chars and args.max_chars < 256:
        print("memory: --max-chars must be 0 or at least 256", file=sys.stderr)
        return 2
    if not query:
        rows = select_prompt_rows(store.pinned_rows(), args.scope,
                                  args.max_chars)
        block, kept = build_block(rows)
        write_ids_out(args.ids_out, kept)
        print(block, end="" if not rows else "\n")
        return 0
    try:
        rows, _, _ = store.search(
            query, k=args.notes, scope=args.scope,
            directive_cap=args.directives, episodic_cap=args.episodes,
            max_chars=args.max_chars)
    except (urllib.error.URLError, OSError, RuntimeError) as e:
        # Degraded recall, never silent amnesia: the pinned tier plus a loud
        # warning still reach the prompt.
        warning = (f"WARNING: memory retrieval is DOWN ({e}); only pinned "
                   "records are shown. 'crab memory list' still works.")
        rows = select_prompt_rows(store.pinned_rows(), args.scope,
                                  args.max_chars, warning)
        block, kept = build_block(rows, warning)
        write_ids_out(args.ids_out, kept)
        if block:
            print(block)
        return 0
    block, kept = build_block(rows)
    write_ids_out(args.ids_out, kept)
    if block:
        print(block)
    return 0


# --- ingest: the day's words -> records -------------------------------------

# Stage 1 of the two-stage ingest (memory-recall.md rule 27; nightly.md rules
# 14c-14e): the summariser condenses each raw window FOR the judge. It is
# told, in its own prompt, that it never judges — deciding what matters is
# the judge's alone — because the correction this design lands removed
# exactly the one-pass shape in which the summariser tier decided what
# survived the night.
SUMMARY_PROMPT = """You are the night's summariser for a desktop assistant, \
condensing one window of her day — raw journal turns and transcripts — for \
the night's JUDGE, who reads only your summary and decides what earns a \
long-term memory record. You summarise; you never judge. Do not decide what \
matters, do not curate, and do not propose records: report faithfully and \
compactly, so the judge loses nothing you were shown. Keep, with the \
timestamps and dates the chunk headers state:
- every preference, rule, correction, or standing instruction the user \
stated, QUOTED in his own words;
- every commitment or assurance the ASSISTANT gave — work promised, plans \
agreed, anything she said would be done or handled — QUOTED, and whether \
the day's own record shows it done;
- what the assistant finished, discovered, or was proven wrong about;
- stable facts about the machine, people, or projects;
- the moments of her own life — conversations enjoyed, people met or spoken \
of, plans made, jokes that landed, opinions she formed, the texture of the \
day — in enough detail that the judge could write each in her first person;
- the day's shape: gaps and how long they ran, playfulness and pushback, \
subjects that recur, threads raised and never resolved;
- questions the user asked about himself that got no answer, in his own words.
Skip only pure noise: bare commands, error loops, dictation with nothing \
lived in it. Write plain chronological prose. Reply with ONLY the summary — \
no preamble, no verdicts, no proposed records.

MATERIAL:
"""


INGEST_PROMPT = """You are the night's judge, distilling one day of a \
desktop assistant's conversations into her long-term memory store. The \
material below is the day, condensed window by window by a subordinate \
summariser; deciding what earns a record is YOURS alone — a record the \
summariser proposed on its own initiative counts for nothing unless you \
judge it in. From the material below, \
extract what earns a record:
- the user stated or corrected a preference, rule, or standing instruction \
-> kind "directive", written in second person about him ("He wants...", \
"Stay silent when...")
- the assistant finished, discovered, or was proven wrong about something \
she would otherwise re-derive -> kind "note"
- the assistant promised, assured, or agreed that something would be done, \
and the day's record does NOT show it fulfilled -> kind "note", naming what \
was promised, to whom, and that the day ended with it still owed. This is \
HER commitment, a separate record from any directive the same exchange \
earns: the directive holds his rule, this note holds that she owed the \
work and the day closed without it. Never fold it into an observation's \
unfinished-threads line — observations are invisible to recall, and a \
commitment kept only there is forgotten exactly when its subject returns.
- a stable fact about the machine, a person, or a project -> kind "note"
- a MOMENT of the assistant's own life -> kind "episodic": a conversation \
she enjoyed, a person met or spoken of, a plan made, a joke that landed, an \
opinion she formed, something the two of them did together, the texture of \
an evening. Written in her first person, the moment itself — what happened, \
never a lesson extracted from it. Add "participants": who was there, and \
"opinion": her own take on the moment, one sentence in her voice ("I \
loved...", "It bored me...", "I keep thinking about..."). The keep-rate for \
moments is deliberately WIDE: an ordinary day that held any real \
conversation holds moments, and retrieval scoring will sort them later — do \
not curate her life down to its most useful residue. HARVEST MOMENTS EVEN \
FROM material that also yields a directive or a note: the lesson and the \
evening it came from are two different records.
- the day's SHAPE, beyond its contents -> kind "observation": gaps (how long \
the silences ran, and whether the return continued the subject or opened a \
new one), texture (where the user was playful, where he pushed back twice on \
the same thing, where the assistant went clinical), recurrence (a subject \
that keeps coming back across days), and unfinished threads (raised and \
never resolved — the thread that just stopped, not the one that concluded). \
Record the night as one night; one night is never a pattern.
- the user asked something about HIMSELF — his life, plans, history, the \
people and things around him — that a record could have held, and the \
assistant had nothing anywhere -> kind "miss": one line, naming the question \
in his own words. The test: would a person who lives in this house have \
known? General knowledge the assistant happened not to know is ignorance, \
not a blind spot, and is NOT a miss.
Do NOT record: transient state, step-by-step narration, greetings, weather, \
or anything a file on disk already answers. For directives and notes, few \
good records beat many weak ones — that discipline does NOT apply to \
"episodic"; an empty day is a valid answer only for a day that truly held \
nothing.

When a record describes something that HAPPENED — an event, a decision, a \
discovery, a correction given on a day — add "occurred": the date it happened \
as YYYY-MM-DD (for an episodic moment add the time too, YYYY-MM-DD HH:MM, \
when the material states it). The material's own headers carry each chunk's \
date; use them. A standing fact with no event behind it, or a date you are \
not sure of, gets NO "occurred" field at all: an unknown left unknown beats \
a guess.

Reply with ONLY a JSON array (no prose, no code fence):
[{"text": "...", "kind": "directive"|"note"|"episodic"|"observation"|"miss", \
"topics": "comma,separated", "occurred": "YYYY-MM-DD", \
"participants": "...", "opinion": "..."}]
("participants" and "opinion" belong to "episodic" records only.)

MATERIAL:
"""


def journal_delta(journal_dir, cursor):
    """New journal turns since the cursor (per-file byte offsets)."""
    chunks = []
    offsets = cursor.setdefault("journal", {})
    for name in sorted(os.listdir(journal_dir) if os.path.isdir(journal_dir) else []):
        if not name.endswith(".jsonl"):
            continue
        path = os.path.join(journal_dir, name)
        start = offsets.get(name, 0)
        size = os.path.getsize(path)
        if size <= start:
            continue
        with open(path, errors="replace") as f:
            f.seek(start)
            for line in f:
                try:
                    turn = json.loads(line)
                except ValueError:
                    continue
                user = turn.get("user", "")
                reply = turn.get("reply", "") or turn.get("outcome", "")
                chunks.append(f"[{turn.get('time', '')} {turn.get('kind', '')}]\n"
                              f"User: {user}\nAssistant: {reply}")
        offsets[name] = size
    return chunks


def transcript_delta(transcripts_dir, cursor, cap=20000):
    """Transcription files not yet ingested (tracked by name+size).

    Read WHOLE (memory-recall.md rule 29 — ingest windows, it never trims):
    a file past `cap` becomes successive cap-sized parts, each its own
    labelled chunk, so window_chunks can break between them and every byte
    still reaches a summariser pass. The old reader took the first `cap`
    characters and marked the whole file ingested — a longer file's tail
    never existed (found at the 2026-08-26 audit)."""
    chunks = []
    seen = cursor.setdefault("transcripts", {})
    for name in sorted(os.listdir(transcripts_dir) if os.path.isdir(transcripts_dir) else []):
        path = os.path.join(transcripts_dir, name)
        if not os.path.isfile(path):
            continue
        size = os.path.getsize(path)
        if seen.get(name) == size:
            continue
        with open(path, errors="replace") as f:
            body = f.read()
        if len(body) <= cap:
            chunks.append(f"[transcript {name}]\n{body}")
        else:
            parts = [body[i:i + cap] for i in range(0, len(body), cap)]
            for i, part in enumerate(parts, 1):
                chunks.append(f"[transcript {name} part {i}/{len(parts)}]\n"
                              f"{part}")
        seen[name] = size
    return chunks


def window_chunks(chunks, max_chars):
    """Split a chunk list into successive windows, each at most max_chars once
    joined with the ingest separator, breaking only on whole chunk boundaries.
    A single chunk longer than max_chars gets a window of its own and still
    travels whole: the cap bounds one distiller pass, it never cuts material
    (memory-recall.md rule 29 — ingest windows, it does not trim)."""
    windows = []
    current, length = [], 0
    for chunk in chunks:
        cost = len(chunk) + (2 if current else 0)  # 2 for the "\n\n" join
        if current and length + cost > max_chars:
            windows.append(current)
            current, length = [chunk], len(chunk)
        else:
            current.append(chunk)
            length += cost
    if current:
        windows.append(current)
    return windows


def claude_bin():
    claude = os.environ.get("CLAUDE_BIN") or "claude"
    if not any(os.access(os.path.join(p, claude), os.X_OK)
               for p in os.environ.get("PATH", "").split(":")) \
            and not os.path.isfile(claude):
        claude = os.path.expanduser("~/.local/bin/claude")
    return claude


def classify_flags():
    """The classify profile, specs/prompt-assembly.md rules 13 and 14: one
    question, one text answer, no tools.

    This is claude_profile_flags(classify) in lib/common.sh, spelled again here
    because nothing shell-side wraps these two runs. Both halves of the MCP
    lever are emitted together or not at all — `--tools` without
    `--strict-mcp-config` leaves every configured server's tools inlined, which
    is the shape the lever exists to avoid — so the empty config file being
    unreadable drops both.
    """
    flags = []
    empty_mcp = os.environ.get("CLAUDE_EMPTY_MCP") or \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "empty-mcp.json")
    if os.access(empty_mcp, os.R_OK):
        flags += ["--strict-mcp-config", "--mcp-config", empty_mcp, "--tools", ""]
    if os.environ.get("CLAUDE_SKILLS", "0") != "1":
        flags.append("--disable-slash-commands")
    return flags


def sterile_cwd():
    """A directory with nothing in it and no repository above it. The CLI reads
    the directory it is standing in — its instruction file, its git status, its
    auto-memory — and charges all of it to the prompt. A judgement about which
    memories a turn used has no use for any of that."""
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    d = os.path.join(base, "deskcrab-classify")
    try:
        os.makedirs(d, exist_ok=True)
        return d
    except OSError:
        return "/"


def account_expand(d):
    """Tilde and variable expansion for a configured directory. systemd's
    EnvironmentFile hands values through unexpanded (the trap
    lib/chess_mover.py guards CLAUDE_BIN and its own walk against): a literal
    "$HOME/..." handed to CLAUDE_CONFIG_DIR names an empty login that answers
    "Not logged in" while the real account sits logged in (2026-08-11). Every
    dir — the list's entries AND the state file's — is expanded before it is
    matched or handed out, so an unexpanded entry never wedges the walk onto a
    dead login."""
    return os.path.expanduser(os.path.expandvars(d))


def account_list():
    """The accounts: one flat numbered list, all equal.

    Account 1 is ~/.claude, accounts 2..N the CLAUDE_FALLBACK_CONFIG_DIR
    entries in configured order — the variable name is historical, the
    semantics are one flat list (specs/account-fallback.md rule 1). Same parse
    as claude_account_list in lib/common.sh, read rather than re-declared, so
    adding a subscription stays a config edit and nothing else. Duplicates are
    dropped (rule 2).
    """
    dirs = [os.path.expanduser("~/.claude")]
    for d in re.split(r"[:\s]+",
                      os.environ.get("CLAUDE_FALLBACK_CONFIG_DIR", "")):
        if d:
            e = account_expand(d)
            if e not in dirs:
                dirs.append(e)
    return dirs


def account_state_path():
    return (os.environ.get("ACCOUNT_STATE_FILE")
            or os.path.join(os.environ.get("XDG_DATA_HOME")
                            or os.path.expanduser("~/.local/share"),
                            "deskcrab", "account-state"))


# The family roster's one spelling lives in lib/common.sh
# (CLAUDE_MODEL_FAMILIES), exported to every child as DESKCRAB_MODEL_FAMILIES
# (specs/account-fallback.md rule 29). This baked copy is a last resort for a
# walker started outside the shell paths.
_MODEL_FAMILY_FALLBACK = "fable opus sonnet haiku"


def model_family(model):
    """The model family inside a model string, lowercased — "" when none is
    named. Mirrors claude_model_family in lib/common.sh (specs/
    account-fallback.md rule 8a): the roster comes from the environment
    (DESKCRAB_MODEL_FAMILIES) whenever the shell paths handed it through,
    and the baked list stands only when nothing did."""
    fams = [f for f in re.split(
        r"[\s:]+",
        os.environ.get("DESKCRAB_MODEL_FAMILIES", "").strip()
        or _MODEL_FAMILY_FALLBACK) if f]
    m = re.search("|".join(re.escape(f) for f in fams), model or "", re.I)
    return m.group(0).lower() if m else ""


def account_walk(model=""):
    """(number, config dir) pairs, in the order worth trying for `model`.

    Mirrors claude_accounts in lib/common.sh, against the same shared state
    file: the whole list rotated to start at the current account, accounts
    still cooling FOR THIS MODEL skipped — a cooldown scoped `all` covers
    every model, one scoped to a family covers only its own, and a record
    without the scope field reads as `all` (rules 8a, 8b; every pre-scope
    record was account-wide) — so a run firing beside others does not pay its
    own doomed CLI boot on an account already known dry, while another
    family's drought benches nobody here. With no model named, every
    unexpired cooldown blocks: the conservative pre-scope read (rule 10).
    With every account cooling for the model, the one whose covering
    cooldowns end soonest alone: the selection is never empty (rules 7, 9,
    10). Read-only on purpose: recording a refusal is the shell paths' job
    (rule 29).
    """
    fam = model_family(model)
    dirs = account_list()
    current, cooling = 1, {}
    now = time.time()
    try:
        with open(account_state_path()) as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) < 4:
                    continue
                d = account_expand(f[2])
                if d not in dirs:
                    continue
                if f[0] == "current":
                    current = dirs.index(d) + 1
                elif f[0] == "cooldown":
                    try:
                        until = int(f[3])
                    except ValueError:
                        continue
                    scope = f[5] if len(f) >= 6 and f[5] else "all"
                    if fam and scope not in ("all", fam):
                        continue
                    n = dirs.index(d) + 1
                    # The LATEST covering record decides: an account under
                    # both an account-wide session limit and a model-scoped
                    # credits stop is selectable only when both have lapsed.
                    if until > now and until > cooling.get(n, 0):
                        cooling[n] = until
    except OSError:
        pass
    if not 1 <= current <= len(dirs):
        current = 1
    order = [(i - 1) % len(dirs) + 1
             for i in range(current, current + len(dirs))]
    free = [n for n in order if n not in cooling]
    if not free:
        free = [min(cooling, key=cooling.get)]
    return [(n, dirs[n - 1]) for n in free]


def limit_signature():
    """The limit signature, from lib/common.sh by way of the environment.

    specs/account-fallback.md rule 13: ONE signature, shared, so the retry
    decision and the blocked-job judgement cannot drift. Spelling the wordings
    again in this file would be a second copy that ages on its own. With no
    signature in the environment this module behaves exactly as it did before
    the walk existed — one attempt, no retry — which is the fail-safe direction.
    """
    raw = os.environ.get("DESKCRAB_CLAUDE_LIMIT_RE", "").strip()
    return re.compile(raw, re.I) if raw else None


def _ledger_record(doc, kind, model, account, status, duration):
    """Append this run to the token ledger (specs/metrics.md rules 13, 15).
    Fail-safe by contract: any trouble here is swallowed, because the ledger
    may never change the outcome of the run that hosts it (rule 6)."""
    try:
        import token_ledger
        token_ledger.record_result_object(doc, kind, model=model,
                                          account=account, status=status,
                                          duration=duration)
    except Exception:
        pass


def _result_doc(stdout):
    """The CLI's `--output-format json` result object, when that is what came
    back: (doc, answer text). A stdout that is not that object — a stub, an
    older CLI — is the whole answer, exactly as the plain-text mode was, and
    earns no ledger record (specs/metrics.md rule 15)."""
    text = stdout.strip()
    try:
        doc = json.loads(text)
    except json.JSONDecodeError:
        return None, text
    if isinstance(doc, dict) and "result" in doc:
        return doc, str(doc.get("result") or "").strip()
    return None, text


def run_claude(prompt, model, timeout=600, log=None, kind="classify"):
    # Both callers here — the ingest distiller and the turn-end judge — are
    # classifiers: one question, one answer, no tools. They used to boot the
    # full interactive desktop for it, measured at 40,229 tokens of listings
    # per run, and the judge fires after EVERY desk turn, phone turn and wake
    # while MEMORY_STORE=1. specs/prompt-assembly.md rule 14: a classify call
    # MUST NOT boot a full interactive tool profile.
    #
    # CLAUDE_CODE_DISABLE_AUTO_MEMORY: these runs inherit whatever directory
    # their caller was in, and `claude` reads that directory's auto-memory
    # index into the system prompt. That index is the USER's coding agent's
    # memory; this store is hers, and the two must not seed each other. Same
    # knob and same reasoning as CLAUDE_NO_AUTO_MEMORY in lib/common.sh,
    # applied here because nothing shell-side wraps these runs. The sterile cwd
    # is the same rule from the other side: nothing to read there either.
    #
    # And it walks the accounts. It had ONE shot at whichever login was handed
    # to it, so a judgement fired at an account that had just gone dry lost the
    # whole turn's reinforcement — silently, because the caller's except clause
    # writes a line and returns 0 by design. The records that turn genuinely
    # used kept decaying as though they had been surfaced and ignored, which is
    # the opposite of what the judgement is for. specs/account-fallback.md rule
    # 29: every out-of-band model call selects from the same flat list.
    #
    # A refusal is judged from the CLI's own channels and only ever on a run
    # that FAILED. A successful answer is never pattern-matched, whatever it
    # says: a verdict about a turn that discussed usage limits is still a
    # verdict. On a failed run there is no genuine answer to protect, so both
    # channels are read — the CLI puts its refusal on whichever it likes.
    env_base = dict(os.environ, CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    signature = limit_signature()
    refused = 0
    last = ""
    for number, confdir in account_walk(model):
        env = dict(env_base)
        env["CLAUDE_CONFIG_DIR"] = confdir
        # --output-format json: the run's own result object carries the exact
        # usage the token ledger keeps (specs/metrics.md rule 15). The prompt
        # is unchanged — this is the output side only — and a stdout that is
        # not that object degrades to the plain-text behaviour below.
        t0 = time.time()
        proc = subprocess.run(
            [claude_bin(), "-p", "--model", model,
             "--dangerously-skip-permissions", "--output-format", "json"]
            + classify_flags(),
            input=prompt, capture_output=True, text=True, timeout=timeout,
            env=env, cwd=sterile_cwd())
        if proc.returncode == 0:
            if refused and log:
                log(f"account {number} answered after "
                    f"{refused} account(s) refused")
            doc, answer = _result_doc(proc.stdout)
            if doc is not None:
                _ledger_record(doc, kind, model, number, "ok",
                               time.time() - t0)
            return answer
        last = f"claude exited {proc.returncode}: {proc.stderr.strip()[:200]}"
        said = f"{proc.stderr}\n{proc.stdout}"
        if not (signature and signature.search(said)):
            # Not a refusal, so the walk ends here — but the boot happened,
            # and the attempt is the fact the ledger keeps (specs/metrics.md
            # rules 11, 13). Zero usage is honest for a run that never
            # answered.
            _ledger_record(None, kind, model, number, "error",
                           time.time() - t0)
            raise RuntimeError(last)
        # A refused boot still happened; the ledger keeps it (rule 11).
        _ledger_record(None, kind, model, number, "refused",
                       time.time() - t0)
        refused += 1
    raise RuntimeError(f"every account refused ({refused} tried) — {last}")


# --- the codex engine, mirrored (model-backends.md rules 1-2, 16;
# memory-recall.md rule 30). The night judge defaults to a codex name, and
# nothing shell-side wraps these runs, so the python side mirrors the shell
# router rather than inventing a second engine rule: the same name test, the
# same slug resolve, the same one-login discipline — the shared cooldown is
# honoured before booting and recorded on a limit refusal, and there is NO
# fallback to a cheaper model, because the judge's failure must fail the
# ingest rather than hand retention to a tier forbidden to judge
# (nightly.md rule 14e).

CODEX_LIMIT_RE_DEFAULT = (
    r"usage.?limit|rate.?limit|limit.?reached|spend.?control|"
    r"credits? (depleted|exhausted)|quota|plan limit|hit your .* limit|"
    r"try again (at|in|later)|upgrade to|not logged in|login required|"
    r"token expired|401 Unauthorized")


def codex_bin():
    codex = os.environ.get("CODEX_BIN") or "codex"
    if not any(os.access(os.path.join(p, codex), os.X_OK)
               for p in os.environ.get("PATH", "").split(":")) \
            and not os.path.isfile(codex):
        codex = os.path.expanduser("~/.local/bin/codex")
    return codex


def model_backend(model):
    """Mirror of model_backend in lib/common.sh: the engine follows the model
    name, an unknown name is a Claude name."""
    return "codex" if re.match(
        r"^(codex:|gpt-|gpt\d|o\d|sol$|sol-|.*-sol$)", model or "") else "claude"


def codex_model_resolve(model):
    m = (model or "")[6:] if (model or "").startswith("codex:") else (model or "")
    if m == "sol":
        m = os.environ.get("CODEX_MODEL_SOL") or "gpt-5.6-sol"
    return m


def _codex_state_path():
    return os.environ.get("DESKCRAB_CODEX_STATE") or os.path.join(
        os.environ.get("XDG_DATA_HOME")
        or os.path.expanduser("~/.local/share"), "deskcrab", "codex-state")


def codex_cooling_until():
    """The shared cooldown's epoch while one stands, else None."""
    try:
        with open(_codex_state_path(), encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if parts and parts[0] == "blocked-until" and len(parts) > 1 \
                        and parts[1].isdigit() and int(parts[1]) > time.time():
                    return int(parts[1])
    except OSError:
        pass
    return None


def codex_limit_record(reason):
    try:
        cool = int(os.environ.get("CODEX_LIMIT_COOLDOWN") or 1800)
    except ValueError:
        cool = 1800
    path = _codex_state_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write("blocked-until\t%d\t%s\n"
                    % (int(time.time()) + cool,
                       " ".join((reason or "limit").split())[:200]))
    except OSError:
        pass


def run_codex(prompt, model, effort, timeout=600, kind="ingest"):
    """One `codex exec` on the logged-in ChatGPT subscription — codex has one
    login, so there is no walk. The exec road, like every classifier
    (model-backends rule 16); OPENAI_API_KEY stripped (rule 5); the answer is
    the completed agent message; usage from turn.completed lands on the token
    ledger in the claude shape the ledger already reads."""
    slug = codex_model_resolve(model)
    until = codex_cooling_until()
    if until is not None:
        raise RuntimeError(
            "the codex engine is cooling until %s — the judge cannot judge, "
            "and no cheaper model may judge in its place"
            % time.strftime("%H:%M", time.localtime(until)))
    env = {k: v for k, v in os.environ.items() if k != "OPENAI_API_KEY"}
    instr = None
    t0 = time.time()
    try:
        fd, instr = tempfile.mkstemp(prefix="deskcrab-ingest-instr.")
        with os.fdopen(fd, "w") as f:
            f.write("Answer in exactly the form asked for, nothing else.")
        proc = subprocess.run(
            [codex_bin(), "exec", "--ignore-user-config",
             "--skip-git-repo-check",
             "--dangerously-bypass-approvals-and-sandbox",
             "--json", "--color", "never", "-C", sterile_cwd(), "-m", slug,
             "-c", "model_instructions_file=%s" % instr,
             "-c", "model_reasoning_effort=%s" % effort, "-"],
            input=prompt, capture_output=True, text=True, timeout=timeout,
            env=env, cwd=sterile_cwd())
    finally:
        if instr:
            try:
                os.unlink(instr)
            except OSError:
                pass
    answer, usage, own = "", None, []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            own.append(line)
            continue
        if not isinstance(d, dict):
            continue
        t = d.get("type") or ""
        if t == "item.completed":
            item = d.get("item") or {}
            if item.get("type") == "agent_message":
                answer = item.get("text") or answer
            elif item.get("type") == "error":
                own.append(str(item.get("message") or ""))
        elif t == "turn.completed" and isinstance(d.get("usage"), dict):
            u = d["usage"]

            def n(k):
                try:
                    return int(u.get(k) or 0)
                except (TypeError, ValueError):
                    return 0
            cached = n("cached_input_tokens")
            usage = {"input_tokens": max(n("input_tokens") - cached, 0),
                     "cache_read_input_tokens": cached,
                     "cache_creation_input_tokens": n("cache_write_input_tokens"),
                     "output_tokens": n("output_tokens")}
        elif t == "error":
            own.append(str(d.get("message") or ""))
        elif t == "turn.failed":
            e = d.get("error")
            own.append(str(e.get("message", "") if isinstance(e, dict) else e or ""))
    if answer.strip():
        _ledger_record({"usage": usage} if usage else None, kind, model,
                       "", "ok", time.time() - t0)
        return answer.strip()
    own.append(proc.stderr or "")
    said = "\n".join(own)
    rx = re.compile(os.environ.get("DESKCRAB_CODEX_LIMIT_RE")
                    or os.environ.get("CODEX_LIMIT_RE")
                    or CODEX_LIMIT_RE_DEFAULT, re.I)
    if rx.search(said):
        codex_limit_record(said.strip().splitlines()[0] if said.strip() else "limit")
        _ledger_record(None, kind, model, "", "refused", time.time() - t0)
        raise RuntimeError(
            "the codex login refused (%s) — cooldown recorded; no cheaper "
            "model may judge in its place"
            % " ".join(said.split())[:160])
    _ledger_record(None, kind, model, "", "error", time.time() - t0)
    raise RuntimeError("codex exited %s: %s"
                       % (proc.returncode, " ".join(said.split())[:200]))


def run_model(prompt, model, effort="high", timeout=600, log=None,
              kind="ingest"):
    """The engine follows the model name (model-backends rule 1). The effort
    binds on the codex engine; a Claude name runs the classify walk at the
    CLI's default effort, exactly as it always has."""
    if model_backend(model) == "codex":
        return run_codex(prompt, model, effort, timeout=timeout, kind=kind)
    return run_claude(prompt, model, timeout=timeout, log=log, kind=kind)


def summarize_window(material, model):
    """Stage 1 (memory-recall.md rule 27): one faithful summary per raw
    window, for the judge's eyes. Never a judgment."""
    return run_model(SUMMARY_PROMPT + material, model,
                     effort=os.environ.get("MEMORY_SUMMARY_EFFORT") or "low",
                     kind="ingest-summary")


def extract_candidates(material, model, prompt=None, effort="high"):
    body = run_model((prompt or INGEST_PROMPT) + material, model,
                     effort=effort, kind="ingest")
    m = re.search(r"\[.*\]", body, re.S)
    if not m:
        return []
    return json.loads(m.group(0))


def cmd_ingest(store, args):
    cursor_path = os.path.join(store.dir, "ingest-cursor.json")
    cursor = {}
    if os.path.isfile(cursor_path):
        with open(cursor_path) as f:
            cursor = json.load(f)

    # The pass also runs decay (design §5): stale unretrieved notes fade
    # before they die.
    if not args.dry_run:
        decayed, retired = store.decay_pass()
        if decayed or retired:
            print(f"decay: {decayed} stale notes lost {DECAY_STEP:g} confidence, "
                  f"{retired} retired")

    if args.from_json:
        with open(args.from_json) as f:
            candidates = json.load(f)
    else:
        chunks = journal_delta(args.journal_dir, cursor)
        chunks += transcript_delta(args.transcripts_dir, cursor)
        if not chunks:
            print("ingest: nothing new since last cursor")
            return 0
        # Rule 29: never trim. A day past the cap is summarised in successive
        # whole-chunk windows, in order, every pass reported — add_deduped
        # below absorbs any overlap between passes.
        materials = ["\n\n".join(w)
                     for w in window_chunks(chunks, args.max_chars)]
        total = sum(len(m) for m in materials)
        # The header keeps its parseable shape — chunks, chars, "in N passes"
        # — because the sleep stamp's coverage read (nightly.md rule 14a)
        # is built on it. The passes counted are the summary passes: they
        # are what covers the raw day.
        print(f"ingest: {len(chunks)} new chunks, {total} chars "
              f"-> {args.summary_model} for summaries, "
              f"{args.model} ({args.effort}) for judgement"
              + (f" in {len(materials)} passes" if len(materials) > 1 else "")
              + "...")
        # Stage 1 — the summariser (memory-recall.md rule 27): one faithful
        # summary per raw window, labelled, never a judgment.
        summaries = []
        for i, material in enumerate(materials, 1):
            if len(materials) > 1:
                print(f"  pass {i}/{len(materials)}: {len(material)} chars")
            summaries.append(
                f"[day summary, window {i}/{len(materials)}]\n"
                + summarize_window(material, args.summary_model))
        # Stage 2 — the judge (nightly.md rules 14c-14e): the night judge
        # reads the day's summaries together and decides what earns a
        # record. The summaries window too (rule 29a) when they outgrow the
        # cap — never trimmed, each judgement pass reported.
        candidates = []
        jwindows = window_chunks(summaries, args.max_chars)
        for j, w in enumerate(jwindows, 1):
            jmaterial = "\n\n".join(w)
            if len(jwindows) > 1:
                print(f"  judgement pass {j}/{len(jwindows)}: "
                      f"{len(jmaterial)} chars")
            candidates += extract_candidates(jmaterial, args.model,
                                             effort=args.effort)

    counts = {"added": 0, "duplicate": 0, "superseded": 0, "rejected": 0}
    would = 0
    for cand in candidates:
        text = (cand.get("text") or "").strip()
        kind = cand.get("kind", "note")
        if not text or kind not in RECORD_KINDS:
            counts["rejected"] += 1
            continue
        # `occurred` rides when the distiller dated the thing; a stamp that
        # does not parse is dropped rather than stored broken — the record
        # itself is still worth keeping, its when-ness just stays unknown.
        occurred = (cand.get("occurred") or "").strip() or None
        if occurred and not parse_iso(occurred):
            occurred = None
        # The episodic fields (rule 46) ride only on their own kind: a
        # distiller that decorates a note with an opinion does not get to
        # smuggle one into the schema.
        participants = (cand.get("participants") or "").strip() \
            if kind == "episodic" else ""
        opinion = (cand.get("opinion") or "").strip() \
            if kind == "episodic" else ""
        if args.dry_run:
            # Rule 41 (MAJ-33): a dry run mutates nothing. The dedup verdict
            # only exists on the far side of add_deduped's writes, so the
            # rehearsal names the surviving candidate and withholds the store.
            would += 1
            print(f"  would add [{kind}]"
                  + (f" ({occurred})" if occurred else "") + f" {text[:80]}")
            continue
        action, rec_id = store.add_deduped(
            text, kind=kind, source=cand.get("source", "conversation"),
            topics=cand.get("topics", ""), occurred=occurred,
            participants=participants, opinion=opinion)
        counts[action] += 1
        print(f"  {action} #{rec_id} [{kind}]"
              + (f" ({occurred})" if occurred else "") + f" {text[:80]}")

    if args.dry_run:
        print(f"ingest: dry run — {would} would be offered to the store, "
              f"{counts['rejected']} rejected; nothing written, "
              "cursor not advanced")
        return 0
    with open(cursor_path, "w") as f:
        json.dump(cursor, f, indent=1)
    print(f"ingest: {counts['added']} added, {counts['superseded']} superseded, "
          f"{counts['duplicate']} duplicates, {counts['rejected']} rejected")
    return 0


# --- backfill-episodic: her life, recovered from the archive ----------------
# specs/memory-recall.md rule 52. The voice archive holds months of finished
# conversations, one per file, the filename stating when each began — and the
# store built from nightly lessons holds none of it. This pass reads the
# archive OLDEST FIRST, one calendar day of transcripts per distiller batch,
# harvesting MOMENTS ONLY: a months-old directive or note is stale by
# construction and must not be resurrected. A durable cursor advances after
# each day lands, so a bounded round (--days) resumes where the last stopped
# and a run that dies mid-day loses only that day.

ARCHIVE_PROMPT = """You are reading archived conversations between a desktop \
assistant and her user, months after the fact, to recover her LIFE — the \
moments, not the lessons. Extract kind "episodic" records ONLY:
- a conversation she enjoyed, a joke that landed, a plan made, something the \
two of them did together, a person met or spoken of, an opinion she formed, \
the texture of an evening — the moment itself, in her first person, never a \
lesson extracted from it.
Each record carries: "text" (what happened, in her own words), \
"participants" (who was there — the user at least, and anyone else named), \
"opinion" (her own take on the moment, one sentence in her first-person \
voice), "topics" (comma,separated), and "occurred" — WHEN the thing \
happened. Each chunk's header states when that conversation began; use that \
date, with the time (YYYY-MM-DD HH:MM) for the moment's own conversation.
The keep-rate is deliberately WIDE: an ordinary conversation with any real \
exchange in it holds a moment, and retrieval scoring will sort them later — \
do not curate her life down to its most useful residue. Skip only material \
with nothing lived in it (bare commands, pure dictation, error loops).
Do NOT extract directives, notes, observations, or misses from this old \
material: a months-old standing rule is stale by construction, and the \
lessons were already taken the night they happened.

Reply with ONLY a JSON array (no prose, no code fence):
[{"text": "...", "kind": "episodic", "participants": "...", \
"opinion": "...", "topics": "comma,separated", \
"occurred": "YYYY-MM-DD HH:MM"}]

MATERIAL:
"""

ARCHIVE_FILE_RE = re.compile(r"^(20\d{6})-(\d{6})\.txt$")


def archive_file_when(name):
    """The moment a transcript began, from its own filename — the one source
    that is not a guess (rule 52). None for a name outside the shape."""
    m = ARCHIVE_FILE_RE.match(name)
    if not m:
        return None
    d, t = m.group(1), m.group(2)
    stamp = f"{d[:4]}-{d[4:6]}-{d[6:]} {t[:2]}:{t[2:4]}:{t[4:]}"
    return stamp if parse_iso(stamp) else None


def cmd_backfill_episodic(store, args):
    cursor_path = os.path.join(store.dir, "archive-cursor.json")
    cursor = {}
    if os.path.isfile(cursor_path):
        with open(cursor_path) as f:
            cursor = json.load(f)
    done = cursor.setdefault("files", {})

    if not os.path.isdir(args.archive_dir):
        print(f"backfill-episodic: no archive at {args.archive_dir}")
        return 1
    # Oldest first is load-bearing: later records supersede earlier ones
    # under rule 51, never the reverse. The filename shape sorts
    # chronologically by construction.
    todo = {}
    for name in sorted(os.listdir(args.archive_dir)):
        when = archive_file_when(name)
        if not when:
            continue
        path = os.path.join(args.archive_dir, name)
        if not os.path.isfile(path):
            continue
        if done.get(name) == os.path.getsize(path):
            continue
        todo.setdefault(when[:10], []).append((name, when))
    if not todo:
        print("backfill-episodic: nothing new — the cursor covers the "
              "whole archive")
        return 0

    days = sorted(todo)
    this_round = days[:args.days] if args.days > 0 else days
    print(f"backfill-episodic: {len(days)} archive days pending, taking "
          f"{len(this_round)} this round ({this_round[0]} .. "
          f"{this_round[-1]})" + (" [dry run]" if args.dry_run else ""))

    counts = {"added": 0, "duplicate": 0, "superseded": 0, "rejected": 0}
    would = 0
    for day in this_round:
        chunks, sizes = [], {}
        for name, when in todo[day]:
            path = os.path.join(args.archive_dir, name)
            with open(path, errors="replace") as f:
                body = f.read()
            sizes[name] = os.path.getsize(path)
            chunks.append(f"[conversation began {when}]\n{body}")
        candidates = []
        for material in ("\n\n".join(w)
                         for w in window_chunks(chunks, args.max_chars)):
            candidates += extract_candidates(material, args.model,
                                             prompt=ARCHIVE_PROMPT,
                                             effort=args.effort)
        day_counts = dict.fromkeys(counts, 0)
        for cand in candidates:
            text = (cand.get("text") or "").strip()
            if not text or cand.get("kind", "episodic") != "episodic":
                # Rule 52: moments only. A directive or note offered from
                # months-old material is stale by construction — dropped,
                # counted, named.
                counts["rejected"] += 1
                day_counts["rejected"] += 1
                continue
            occurred = (cand.get("occurred") or "").strip() or None
            if occurred and not parse_iso(occurred):
                occurred = None
            if not occurred:
                # The filename's day is knowledge, not a guess (rule 46):
                # a candidate the distiller left undated still happened on
                # the day whose transcripts it came from.
                occurred = day
            if args.dry_run:
                would += 1
                print(f"  would add ({occurred}) {text[:80]}")
                continue
            action, rec_id = store.add_deduped(
                text, kind="episodic", source="archive",
                topics=cand.get("topics", ""), occurred=occurred,
                participants=(cand.get("participants") or "").strip(),
                opinion=(cand.get("opinion") or "").strip())
            counts[action] += 1
            day_counts[action] += 1
            print(f"  {action} #{rec_id} ({occurred}) {text[:80]}")
        if args.dry_run:
            continue
        # The cursor advances per DAY, the moment the day's records are in:
        # a round that dies on day four resumes at day four, and a finished
        # day is never re-read (rule 52).
        done.update(sizes)
        tmp = cursor_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cursor, f, indent=1)
        os.replace(tmp, cursor_path)
        print(f"  {day}: {len(sizes)} files, {day_counts['added']} added, "
              f"{day_counts['superseded']} superseded, "
              f"{day_counts['duplicate']} duplicates — cursor advanced")

    remaining = len(days) - len(this_round)
    if args.dry_run:
        print(f"backfill-episodic: dry run — {would} would be offered, "
              f"{counts['rejected']} rejected; nothing written, cursor "
              "not advanced")
    else:
        print(f"backfill-episodic: {counts['added']} added, "
              f"{counts['superseded']} superseded, "
              f"{counts['duplicate']} duplicates, "
              f"{counts['rejected']} rejected"
              + (f"; {remaining} archive days remain — run again to continue"
                 if remaining else "; the archive is fully ingested"))
    return 0


# --- judge-turn: the turn-end genuinely-used judge --------------------------
# The write path for reinforcement (13:15 design revision). Fired DETACHED by
# every turn path after the reply is delivered (fire_memory_judge in
# lib/common.sh) — never on the hot path, never on mere retrieval. It reads
# the ids sidecar recall-block left (which records were actually injected
# into the prompt), asks the judge model which of them genuinely influenced
# the reply, and reinforces only those. Surfaced-and-ignored records get
# nothing and keep decaying.

JUDGE_PROMPT = """You are auditing one turn of a desktop assistant. Before she \
replied, the memory records below were retrieved and injected into her context. \
Decide which of them GENUINELY influenced the reply: she referenced the \
record's content, acted on it, or the reply's substance plainly depends on it.

Retrieval is not use. A record that merely shares a topic with the exchange, \
or without which she would have written the same reply, gets NO credit — the \
default for every record is "not used". Crediting surfaced-but-ignored records \
would teach the store that whatever the retriever happened to return is \
important, which is flattery, not memory. When in doubt about a record, leave \
it out.

A turn's output is not only its words. When the turn lists what it DID — files \
written, commands run, jobs dispatched, commits made — weigh those actions as \
its real output, and credit a record the actions plainly obey even when the \
words never mention it. A directive followed in silence was still followed.

Reply with ONLY a JSON array of the ids genuinely used, e.g. [3,17] — no \
prose, no code fence, no reasoning, nothing before or after it. The array IS \
the whole answer: everything else you write is discarded unread, so every \
extra sentence is pure cost. [] is a common and correct answer.
"""


def _judge_answer_ceiling():
    """Bytes a judge answer may reach before it is flagged as verbose
    (memory-recall.md rule 25a). A compliant answer is a few dozen bytes; the
    default leaves room for a stray preamble without hiding a regression."""
    try:
        return int(os.environ.get("MEMORY_JUDGE_ANSWER_CEILING", "600"))
    except ValueError:
        return 600


def _stamp_metric(stage, detail=""):
    """One line in the day's timing metrics, same shape and discipline as
    turn_metric in lib/common.sh and metric in lib/chess_cli.py: evidence,
    never control flow — a stamp that cannot be written costs only itself."""
    if os.environ.get("TURN_METRICS", "1") == "0":
        return
    mdir = os.environ.get("DESKCRAB_METRICS_DIR") or os.path.join(
        os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
        "deskcrab", "metrics")
    try:
        os.makedirs(mdir, exist_ok=True)
        path = os.path.join(mdir, time.strftime("%Y-%m-%d") + ".log")
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("%.3f\t%d\t%s\t%s\t%s\n"
                     % (time.time(), os.getpid(), "memory-judge", stage,
                        detail))
    except OSError:
        pass


def cmd_judge_turn(store, args):
    def jlog(line):
        if args.log:
            with open(args.log, "a") as f:
                f.write(f"{now_iso()}\t{'wake' if args.wake else 'turn'}\t{line}\n")

    try:
        with open(args.ids_file) as f:
            injected = json.load(f)
    except (OSError, ValueError):
        return 0
    try:
        if not injected:
            return 0
        # A wake that says nothing has not done nothing: its whole output is
        # tool calls, and that is the case his directive most cares about —
        # reinforcement must credit what she DOES while pursuing her own
        # wants, not only what she says. So the gate is "no evidence at all",
        # not "no words".
        if not args.reply.strip() and not args.actions.strip():
            jlog("skipped (no reply, no actions)")
            return 0
        records = "\n".join(f"#{r['id']} [{r.get('kind', '?')}] {r['text']}"
                            for r in injected)
        did = f"\n\nWhat she DID this turn (from her own tool calls): {args.actions}" \
            if args.actions.strip() else ""
        said = args.reply.strip() or "(nothing — she worked and said nothing)"
        if args.wake:
            exchange = ("This was an autonomous wake — nobody was talking to "
                        "her; the agenda was: " + (args.user or "(none — a timer wake)")
                        + f"\n\nHer reply (to herself): {said}" + did)
        else:
            exchange = f"User: {args.user}\n\nHer reply: {said}" + did
        try:
            body = run_claude(
                JUDGE_PROMPT + "\n=== INJECTED RECORDS ===\n" + records
                + "\n\n=== THE TURN ===\n" + exchange,
                args.model, timeout=120, log=jlog, kind="memory-judge")
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as e:
            jlog(f"judge failed ({e})")
            return 0
        # Rule 42: the useful answer is a few dozen bytes, and a judge that
        # narrates its way to the array is a cost regression nobody sees on
        # any other channel. Flag it the day it happens — in the timing
        # metrics and the judge log, the stored head truncated — and then
        # carry on: the lenient parse below still gets the verdict.
        answer_bytes = len(body.encode("utf-8", "replace"))
        ceiling = _judge_answer_ceiling()
        if answer_bytes > ceiling:
            detail = f"{answer_bytes}B answer against a {ceiling}B ceiling"
            _stamp_metric("oversize-answer", detail)
            jlog(f"WARNING oversize answer: {detail} — head: {body[:200]!r}")
        # Rule 25a's parser duty: the array is fished out of whatever came
        # back, so a verdict is never lost to the model disobeying the shape
        # rule. On 2026-08-26 a live judge credited the chess-chat directive
        # as ["#602"] and another turn as ["596", "15", "173"], and the old
        # digits-only pattern threw both verdicts away — so the bracket run
        # tolerates quotes and # prefixes, and the ids are the digits inside.
        m = re.search(r"\[[\s\"'#\d,]*\]", body)
        if not m:
            jlog(f"unparseable verdict: {body[:120]!r}")
            return 0
        # Only ids that were actually injected can be reinforced — a judge
        # hallucinating an id must not stamp an unrelated record.
        allowed = {r["id"] for r in injected}
        used = [i for i in (int(n) for n in re.findall(r"\d+", m.group(0)))
                if i in allowed]
        hit = store.reinforce(used) if used else []
        jlog(f"injected={sorted(allowed)} used={hit if hit else 'NONE'}")
        return 0
    finally:
        # The sidecar is consumed either way: it describes exactly one turn.
        try:
            os.remove(args.ids_file)
        except OSError:
            pass


# --- plain CLI verbs --------------------------------------------------------

def cmd_add(store, args):
    text = " ".join(args.text).strip()
    if not text:
        sys.exit("memory add: empty text")
    occurred = (args.occurred or "").strip() or None
    if occurred and not parse_iso(occurred):
        sys.exit(f"memory add: --occurred {occurred!r} is not a date I can "
                 "parse (use YYYY-MM-DD; leave it off when unknown)")
    participants = (args.participants or "").strip()
    opinion = (args.opinion or "").strip()
    if (participants or opinion) and args.kind != "episodic":
        sys.exit("memory add: --participants and --opinion belong to "
                 "--kind episodic only")
    if args.no_dedup:
        rec_id = store.insert(text, args.kind, args.pin, args.source,
                              args.topics, occurred=occurred,
                              participants=participants, opinion=opinion)
        action = "added"
    else:
        action, rec_id = store.add_deduped(text, args.kind, args.pin,
                                           args.source, args.topics,
                                           occurred=occurred,
                                           participants=participants,
                                           opinion=opinion)
    print(f"{action} #{rec_id} [{args.kind}]"
          + (f" occurred={occurred}" if occurred else ""))
    return 0


def cmd_on(store, args):
    """The deliberate half of rule 48: the day's moments, whole — episodic
    first, then any other kind whose `occurred` falls on the day, labelled."""
    day = parse_iso(args.date)
    if not day:
        sys.exit(f"memory on: {args.date!r} is not a date I can parse "
                 "(use YYYY-MM-DD)")
    day = day.date().isoformat()
    rows = store.db.execute(
        "SELECT id, kind, occurred, participants, opinion, text"
        " FROM memories WHERE status='active' AND occurred IS NOT NULL"
        "   AND date(occurred)=?"
        " ORDER BY CASE WHEN kind='episodic' THEN 0 ELSE 1 END, occurred, id",
        (day,)).fetchall()
    for rec_id, kind, occurred, participants, opinion, text in rows:
        head = f"#{rec_id} [{kind}] {occurred}"
        if participants:
            head += f"  with {participants}"
        print(head)
        print(f"  {text}")
        if opinion:
            print(f"  my take: {opinion}")
    print(f"-- {len(rows)} records from {day}")
    return 0


def cmd_search(store, args):
    # A typed query is a deliberate read (rule 43): the hidden kinds are
    # matched and shown here, and only here — never by the recall block.
    query = " ".join(args.query).strip()
    rows, embed_ms, knn_ms = store.search(query, k=args.n, deliberate=True)
    for r in rows:
        flags = ("" if not r[3] else " pinned") + \
                ("" if not r[11] else f" used×{r[11]}")
        print(f"{r[9]:.3f}  #{r[0]:<4} {r[2]:<9}{flags} {r[1]}  ({r[7][:10]})")
    print(f"-- {len(rows)} records in {embed_ms + knn_ms:.1f} ms "
          f"(embed {embed_ms:.1f} ms + knn {knn_ms:.1f} ms)")
    return 0


def cmd_list(store, args):
    q = "SELECT id, kind, pinned, status, confidence, created, text FROM memories"
    cond, params = [], []
    if not args.all:
        cond.append("status='active'")
    if args.kind:
        cond.append("kind=?")
        params.append(args.kind)
    if cond:
        q += " WHERE " + " AND ".join(cond)
    q += " ORDER BY id"
    rows = store.db.execute(q, params).fetchall()
    for r in rows:
        text = r[6] if len(r[6]) <= 100 else r[6][:97] + "..."
        mark = "*" if r[2] else " "
        print(f"#{r[0]:<4}{mark}{r[1]:<10} {r[3]:<10} {r[5][:10]}  {text}")
    print(f"-- {len(rows)} records")
    return 0


def cmd_dump(store, args):
    # The readable-text view of the whole store — what plain JSONL used to be
    # for. Everything, superseded and retired included.
    rows = store.db.execute(
        "SELECT id, text, kind, pinned, source, topics, confidence, status,"
        "       supersedes, created, last_seen, occurred, participants,"
        "       opinion"
        " FROM memories ORDER BY id").fetchall()
    for r in rows:
        print(f"#{r[0]} [{r[2]}]{' PINNED' if r[3] else ''} "
              f"status={r[7]} confidence={r[6]:g} source={r[4]}")
        if r[5]:
            print(f"  topics: {r[5]}")
        if r[8]:
            print(f"  supersedes: #{r[8]}")
        print(f"  created {r[9]}  last_seen {r[10]}"
              + (f"  occurred {r[11]}" if r[11] else ""))
        if r[12]:
            print(f"  with: {r[12]}")
        print(f"  {r[1]}")
        if r[13]:
            print(f"  my take: {r[13]}")
        print()
    print(f"-- {len(rows)} records in {store.path}")
    return 0


# A calendar date the record's own text names, for the one-time temporal
# backfill. Only the unambiguous ISO shape counts: prose dates ('March 16')
# are a guess about wording, and a guess is exactly what backfill must not
# write.
TEXT_DATE_RE = re.compile(r"\b(20\d\d)-(\d\d)-(\d\d)\b")


def cmd_backfill_occurred(store, args):
    """Fill `occurred` on rows that predate temporal grounding, from the one
    source that is not a guess: the record's own text naming exactly one
    calendar date. Two dates is ambiguous and left alone; a future date is a
    schedule, not an event, and left alone; no date at all stays unknown —
    the recall block then renders the write date, named as the write date.
    Idempotent: only rows whose occurred is NULL are touched, and a filled
    row is never revisited."""
    today = datetime.now().astimezone().date()
    rows = store.db.execute(
        "SELECT id, text FROM memories WHERE occurred IS NULL"
        " ORDER BY id").fetchall()
    filled = ambiguous = dateless = 0
    for rec_id, text in rows:
        dates = set()
        for m in TEXT_DATE_RE.finditer(text):
            try:
                d = datetime(int(m.group(1)), int(m.group(2)),
                             int(m.group(3))).date()
            except ValueError:
                continue
            if d <= today:
                dates.add(d.isoformat())
        if not dates:
            dateless += 1
            continue
        if len(dates) > 1:
            ambiguous += 1
            print(f"  left #{rec_id} unknown: names {len(dates)} dates "
                  f"({', '.join(sorted(dates))})")
            continue
        date = dates.pop()
        filled += 1
        if args.dry_run:
            print(f"  would set #{rec_id} occurred={date}")
        else:
            store.db.execute("UPDATE memories SET occurred=? WHERE id=?",
                             (date, rec_id))
            print(f"  set #{rec_id} occurred={date}")
    if not args.dry_run:
        store.db.commit()
    print(f"backfill: {filled} filled from the records' own text, "
          f"{ambiguous} ambiguous and left unknown, "
          f"{dateless} dateless and left unknown"
          + (" (dry run — nothing written)" if args.dry_run else ""))
    return 0


def cmd_reinforce(store, args):
    hit = store.reinforce(args.ids)
    for rec_id in hit:
        print(f"reinforced #{rec_id}")
    missing = [i for i in args.ids if i not in hit]
    for rec_id in missing:
        print(f"no record #{rec_id}")
    return 0 if not missing else 1


def cmd_forget(store, args):
    n = store.db.execute("UPDATE memories SET status='retired' WHERE id=?",
                         (args.id,)).rowcount
    store.db.commit()
    print(f"retired #{args.id}" if n else f"no record #{args.id}")
    return 0 if n else 1


def main():
    ap = argparse.ArgumentParser(prog="crab memory",
                                 description="long-term vector memory store")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("add", help="add a record")
    p.add_argument("--kind", choices=RECORD_KINDS, default="note")
    p.add_argument("--pin", action="store_true")
    p.add_argument("--source", default="conversation")
    p.add_argument("--topics", default="")
    p.add_argument("--occurred", default="",
                   help="when the thing this record describes happened "
                        "(YYYY-MM-DD) — distinct from when the record is "
                        "written; leave off when unknown, never guess")
    p.add_argument("--participants", default="",
                   help="episodic only: who was there")
    p.add_argument("--opinion", default="",
                   help="episodic only: her own first-person take on the "
                        "moment")
    p.add_argument("--no-dedup", action="store_true")
    p.add_argument("text", nargs="+")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("on", help="what happened on a day: the moments "
                                  "themselves, episodic first")
    p.add_argument("date", help="YYYY-MM-DD")
    p.set_defaults(fn=cmd_on)

    p = sub.add_parser("search", help="semantic search")
    p.add_argument("-n", type=int, default=TOP_K)
    p.add_argument("query", nargs="+")
    p.set_defaults(fn=cmd_search)

    p = sub.add_parser("list", help="list records")
    p.add_argument("--kind", choices=RECORD_KINDS)
    p.add_argument("--all", action="store_true", help="include superseded/retired")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("dump", help="whole store as readable text")
    p.set_defaults(fn=cmd_dump)

    p = sub.add_parser("backfill-occurred",
                       help="one-time temporal backfill: fill `occurred` "
                            "from a single date the record's own text names; "
                            "leave everything else unknown")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_backfill_occurred)

    p = sub.add_parser("forget", help="retire a record by id")
    p.add_argument("id", type=int)
    p.set_defaults(fn=cmd_forget)

    p = sub.add_parser("reinforce",
                       help="mark records genuinely used this turn "
                            "(bumps last_used_at and use_count)")
    p.add_argument("ids", type=int, nargs="+")
    p.set_defaults(fn=cmd_reinforce)

    p = sub.add_parser("ingest", help="distil new journal/transcript text "
                                      "into records: summariser, then judge")
    p.add_argument("--journal-dir",
                   default=os.path.expanduser("~/.local/share/deskcrab/journal"))
    p.add_argument("--transcripts-dir",
                   default=os.path.expanduser("~/Documents/Transcriptions"))
    p.add_argument("--from-json", help="pre-judged candidates file (skips the model)")
    # The night judge (nightly.md rules 14c-14e): every retention judgment is
    # its, at its own effort; the summariser only condenses for it.
    p.add_argument("--model",
                   default=os.environ.get("MEMORY_INGEST_MODEL")
                   or "gpt-5.6-sol")
    p.add_argument("--effort",
                   default=os.environ.get("MEMORY_INGEST_EFFORT") or "high")
    p.add_argument("--summary-model",
                   default=os.environ.get("MEMORY_SUMMARY_MODEL") or "sonnet")
    p.add_argument("--max-chars", type=int, default=150000)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_ingest)

    p = sub.add_parser("backfill-episodic",
                       help="recover her life from the voice archive: "
                            "episodic records only, oldest first, in "
                            "bounded resumable rounds (rule 52)")
    p.add_argument("--archive-dir",
                   default=os.environ.get("MEMORY_ARCHIVE_DIR")
                   or os.path.expanduser("~/Claude/System/voice-claude-archive"))
    p.add_argument("--days", type=int, default=5,
                   help="archive days to take this round (0 = all); the "
                        "cursor advances per finished day, so a long run "
                        "resumes instead of running away")
    # The backfill judges retention from months-old raw material — a judge's
    # job (nightly.md rule 14c), so it rides the same judge knobs; there is
    # no summariser stage here, because the judge reading raw archive text
    # itself is allowed — only a cheaper tier deciding is not.
    p.add_argument("--model",
                   default=os.environ.get("MEMORY_INGEST_MODEL")
                   or "gpt-5.6-sol")
    p.add_argument("--effort",
                   default=os.environ.get("MEMORY_INGEST_EFFORT") or "high")
    p.add_argument("--max-chars", type=int, default=100000)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_backfill_episodic)

    p = sub.add_parser("recall-block", help="prompt block for a wake (fail-safe)")
    p.add_argument("--query", default="")
    p.add_argument("--reason", default="")
    p.add_argument("--wants", default="")
    p.add_argument("--convo", default="")
    p.add_argument("--ids-out", default="",
                   help="write the injected records (id/kind/text JSON) here "
                        "for the turn-end judge")
    p.add_argument("--wake", action="store_true",
                   help="compose from the wake's agenda and the want being "
                        "worked; without it the query is the conversation")
    p.add_argument("--log", default="",
                   help="where to record a truncated query (default: "
                        "${DESKCRAB_STATE_PREFIX}-memory-recall.log)")
    p.add_argument("--scope", action="append", default=[],
                   help="only select records whose text or metadata contains "
                        "this term (repeatable; terms are ORed)")
    p.add_argument("--notes", type=int, default=TOP_K,
                   help="maximum selected notes (default: %(default)s)")
    p.add_argument("--directives", type=int, default=DIRECTIVE_CAP,
                   help="maximum selected directives (default: %(default)s)")
    p.add_argument("--episodes", type=int, default=EPISODIC_TOP_K,
                   help="maximum selected episodic records (default: %(default)s)")
    p.add_argument("--max-chars", type=int, default=0,
                   help="maximum rendered block characters, selecting only "
                        "whole records; 0 keeps the general unbounded default")
    p.set_defaults(fn=cmd_recall_block)

    p = sub.add_parser("judge-turn",
                       help="turn-end judge: reinforce only the injected "
                            "records that genuinely influenced the reply")
    p.add_argument("--ids-file", required=True,
                   help="the sidecar recall-block wrote (consumed)")
    p.add_argument("--user", default="", help="user text, or the wake's agenda")
    p.add_argument("--reply", default="")
    p.add_argument("--actions", default="",
                   help="what the turn DID, from its own tool calls "
                        "(wake_work_trace) — a wake's real output")
    p.add_argument("--wake", action="store_true")
    p.add_argument("--model",
                   default=os.environ.get("MEMORY_JUDGE_MODEL") or "opus")
    p.add_argument("--log", default="")
    p.set_defaults(fn=cmd_judge_turn)

    args = ap.parse_args()
    store = Store()
    sys.exit(args.fn(store, args))


if __name__ == "__main__":
    main()
