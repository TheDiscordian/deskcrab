#!/usr/bin/env python3
# Long-term memory store: sqlite-vec + nomic-embed-text on the local ollama
# daemon. One memory.db holds text, metadata, and vector together; KNN and
# filtering are SQL. Design: design-memory-store.md (storage revised to
# sqlite-vec 2026-08-06 — scale and SQL editability beat hand-editable JSONL,
# and `memory dump` gives back the readable-text view that argument wanted).
#
# Two record kinds. A `directive` is the user's voice: never decayed or
# auto-retired, only superseded by a newer directive, over-retrieved by
# design. A `note` is the assistant's own soft memory. `pinned` records are
# always retrieved regardless of similarity.
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
# Recall-block size (13:15 revision): ~800 tokens; when it truncates, the
# header says so. Lowest-ranked notes drop first, directives only after.
BLOCK_TOKEN_CAP = 800
CHARS_PER_TOKEN = 4
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
EMBED_CHAR_CAP = 5600
EMBED_SHRINK_TRIES = 3
# Composed recall query: the whole thing, all segments together.
RECALL_QUERY_CHARS = 4800
# One wants bullet contributes its topic, not its whole history. These are
# multi-paragraph entries with dated progress logs appended; the opening
# clause is what makes them findable.
WANTS_BULLET_CHARS = 240
WANTS_BULLET_MAX = 12
# When there is a conversation tail, the head (reason or wants) keeps this
# share of the budget and the tail takes the rest.
RECALL_HEAD_SHARE = 0.6
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


def score_row(row, now):
    """The 13:15 scoring formula. Notes:
    cosine × confidence × decay(last use) × (1 + log(1+use_count) × 0.15),
    decay exponential with a DECAY_HALF_LIFE_DAYS half-life counted from
    last_used_at (falling back to creation for a note never yet used), boost
    capped at REINFORCE_MAX_BOOST. Directives: raw cosine, untouched."""
    sim = row[9]
    if row[2] != "note":
        return sim
    ts = parse_iso(row[10] or row[7])
    days = max(0.0, (now - ts).total_seconds() / 86400) if ts else 0.0
    decay = 0.5 ** (days / DECAY_HALF_LIFE_DAYS)
    boost = min(1.0 + math.log1p(row[11] or 0) * REINFORCE_WEIGHT,
                REINFORCE_MAX_BOOST)
    return sim * row[6] * decay * boost


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


def _notice_touch(directory, window=900):
    """Declare an imminent write for lib/notice-selfchange (crab touching).

    sqlite touches memory.db on ~every open — WAL checkpoints, last_seen
    bumps — and every opener of this store is the assistant's own plumbing,
    so the declaration happens here rather than at each call site. Same
    record format and lock as touch_suppress in lib/common.sh.
    """
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    sup = os.path.join(state, "deskcrab", "notice-self.suppress")
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
            CREATE TABLE IF NOT EXISTS memories (
                id         INTEGER PRIMARY KEY,
                text       TEXT NOT NULL,
                kind       TEXT NOT NULL CHECK (kind IN ('directive','note')),
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
                use_count  INTEGER NOT NULL DEFAULT 0
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS memories_vec USING vec0(
                embedding float[{EMBED_DIM}] distance_metric=cosine
            );
        """)

    def embed_text(self, rec_text, topics=""):
        body = rec_text if not topics else f"{rec_text} [topics: {topics}]"
        return embed([body])[0]

    def insert(self, text, kind="note", pinned=False, source="self",
               topics="", vec=None):
        if vec is None:
            vec = self.embed_text(text, topics)
        now = now_iso()
        cur = self.db.execute(
            "INSERT INTO memories (text, kind, pinned, source, topics, created, last_seen)"
            " VALUES (?,?,?,?,?,?,?)",
            (text, kind, 1 if pinned else 0, source, topics, now, now))
        self.db.execute("INSERT INTO memories_vec (rowid, embedding) VALUES (?,?)",
                        (cur.lastrowid, pack(vec)))
        self.db.commit()
        return cur.lastrowid

    def knn(self, vec, k):
        """Raw KNN against active records: rows with cosine similarity at
        index 9, best raw similarity first."""
        # Superseded/retired rows keep their vectors (history is kept), so the
        # KNN budget must span the WHOLE vec table or low-similarity active
        # rows fall off the end of the join filter. The corpus is small enough
        # that fetching every vector is still sub-millisecond.
        total = self.db.execute("SELECT count(*) FROM memories_vec").fetchone()[0]
        if total == 0:
            return []
        rows = self.db.execute(
            "SELECT m.id, m.text, m.kind, m.pinned, m.source, m.topics,"
            "       m.confidence, m.created, m.last_seen, 1.0 - v.distance AS sim,"
            "       m.last_used_at, m.use_count"
            " FROM memories_vec v JOIN memories m ON m.id = v.rowid"
            " WHERE v.embedding MATCH ? AND v.k = ? AND m.status = 'active'"
            " ORDER BY sim DESC",
            (pack(vec), total)).fetchall()
        return rows[:k] if k else rows

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

    def search(self, query, k=TOP_K):
        """The retrieval rule from the design's 13:15 revision — two pools
        with different floors, queried separately so the assistant's own
        chatter can never crowd the user's rules out: notes take the top-K
        above SIM_FLOOR ranked by the reinforcement score, directives take
        everything above the deliberately looser DIRECTIVE_FLOOR (capped, raw
        cosine — never decayed or boosted), and every pinned record rides
        along regardless. Near-duplicates of an already-taken record are
        squashed so K slots hold K distinct things."""
        t0 = time.monotonic()
        qvec = embed([query], query=True)[0]
        t1 = time.monotonic()
        rows = self.knn(qvec, 0)
        now = datetime.now().astimezone()
        picked, seen = [], set()

        def take(row):
            if row[0] not in seen and not self._near_dup(row, picked):
                picked.append(row)
                seen.add(row[0])
                return True
            return False

        notes = sorted((r for r in rows if r[2] == "note" and r[9] >= SIM_FLOOR),
                       key=lambda r: score_row(r, now), reverse=True)
        taken = 0
        for row in notes:
            if taken >= k:
                break
            taken += take(row)
        directives = 0
        for row in rows:
            if directives >= DIRECTIVE_CAP:
                break
            if row[2] == "directive" and row[9] >= DIRECTIVE_FLOOR:
                directives += take(row)
        for row in self.pinned_rows():
            if row[0] not in seen:
                picked.append(row)
                seen.add(row[0])
        t2 = time.monotonic()
        if picked:
            now = now_iso()
            self.db.executemany("UPDATE memories SET last_seen=? WHERE id=?",
                                [(now, r[0]) for r in picked])
            self.db.commit()
        return picked, (t1 - t0) * 1000, (t2 - t1) * 1000

    def add_deduped(self, text, kind="note", pinned=False, source="self", topics=""):
        """Insert with the ingest rules: same-kind exact text -> skip and bump
        last_seen; same-kind similar-but-different -> the new record
        supersedes the old. Returns (action, id)."""
        vec = self.embed_text(text, topics)
        best = None
        for row in self.knn(vec, 5):
            if row[2] == kind:
                best = row
                break
        if best and " ".join(best[1].split()).lower() == " ".join(text.split()).lower():
            self.db.execute("UPDATE memories SET last_seen=? WHERE id=?",
                            (now_iso(), best[0]))
            self.db.commit()
            return "duplicate", best[0]
        if best and best[9] >= SUPERSEDE_SIM:
            new_id = self.insert(text, kind, pinned, source, topics, vec=vec)
            self.db.execute(
                "UPDATE memories SET status='superseded' WHERE id=?", (best[0],))
            self.db.execute(
                "UPDATE memories SET supersedes=? WHERE id=?", (best[0], new_id))
            self.db.commit()
            return "superseded", new_id
        return "added", self.insert(text, kind, pinned, source, topics, vec=vec)

    def pinned_rows(self):
        return self.db.execute(
            "SELECT id, text, kind, pinned, source, topics, confidence,"
            "       created, last_seen, 1.0, last_used_at, use_count"
            " FROM memories WHERE status='active' AND pinned=1"
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
        """§3 soft decay, run by the ingest pass (§5): an active note neither
        retrieved nor used in DECAY_STALE_DAYS loses DECAY_STEP confidence;
        below DECAY_RETIRE_FLOOR it flips to retired. Directives never decay."""
        now = datetime.now().astimezone()
        decayed, retired = 0, 0
        for rec_id, conf, seen, used in self.db.execute(
                "SELECT id, confidence, last_seen, last_used_at FROM memories"
                " WHERE status='active' AND kind='note'").fetchall():
            stamps = [t for t in (parse_iso(seen), parse_iso(used)) if t]
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


def recall_query(reason, wants_file, convo_file, budget=RECALL_QUERY_CHARS):
    """Query formation when nobody asked anything: the wake's reason if it has
    one, else the wants shelf lines, plus the tail of the live conversation.

    Composed under a budget, because the embedder has a hard 2048-token
    context and answers anything past it with a 400 rather than truncating —
    the unclamped version of this function composed ~19 k chars and took
    retrieval down to the pinned tier without a single failed command to show
    for it. Each wants bullet contributes its opening clause only; the
    conversation tail is kept from its END, since the most recent words are
    what the turn is actually about."""
    head = []
    if reason:
        head.append(_segment(reason, budget))
    elif wants_file and os.path.isfile(wants_file):
        with open(wants_file, errors="replace") as f:
            head = [_segment(l[2:], WANTS_BULLET_CHARS)
                    for l in f if l.startswith("- ")]
        head = [b for b in head if b][:WANTS_BULLET_MAX]
    head = [h for h in head if h]

    tail = ""
    if convo_file and os.path.isfile(convo_file):
        with open(convo_file, errors="replace") as f:
            tail = _segment(" ".join(f.readlines()[-10:]))

    parts, used = [], 0
    head_cap = int(budget * RECALL_HEAD_SHARE) if tail else budget
    for h in head:
        if used + len(h) + 1 > head_cap:
            break
        parts.append(h)
        used += len(h) + 1
    if tail:
        room = budget - used - 1
        if room > 0:
            parts.append(tail[-room:])
    return "\n".join(parts).strip()


def build_block(rows, warning=""):
    """The recall block plus the rows that actually made it in — truncation
    drops rows, and the reinforcement judge must only ever see records that
    genuinely reached the prompt."""
    if not rows and not warning:
        return "", []
    directives = [r for r in rows if r[2] == "directive"]
    notes = [r for r in rows if r[2] == "note"]
    # ~BLOCK_TOKEN_CAP-token cap (13:15 revision): if it truncates, the header
    # says so. Lowest-ranked notes drop first; directives are expensive to
    # miss, so they go only when notes are already gone.
    truncated = False
    while True:
        out = ["## What you remember (retrieved, not exhaustive"
               + (", TRUNCATED to fit" if truncated else "")
               + " — 'crab memory search <query>' for more)"]
        if warning:
            out.append(f"\n{warning}")
        if directives:
            out.append("\nThings he has told you:")
            out.extend(f"- {r[1]} ({r[7][:10]})" for r in directives)
        if notes:
            out.append("\nThings you know from your own time:")
            out.extend(f"- {r[1]} ({r[7][:10]})" for r in notes)
        block = "\n".join(out)
        if len(block) <= BLOCK_TOKEN_CAP * CHARS_PER_TOKEN \
                or not (notes or directives):
            return block, directives + notes
        truncated = True
        (notes or directives).pop()


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
    query = args.query or recall_query(args.reason, args.wants, args.convo)
    if not query:
        rows = store.pinned_rows()
        block, kept = build_block(rows)
        write_ids_out(args.ids_out, kept)
        print(block, end="" if not rows else "\n")
        return 0
    try:
        rows, _, _ = store.search(query)
    except (urllib.error.URLError, OSError, RuntimeError) as e:
        # Degraded recall, never silent amnesia: the pinned tier plus a loud
        # warning still reach the prompt.
        rows = store.pinned_rows()
        block, kept = build_block(
            rows, f"WARNING: memory retrieval is DOWN ({e}); only pinned "
                  "records are shown. 'crab memory list' still works.")
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

INGEST_PROMPT = """You are distilling one day of a desktop assistant's \
conversations into her long-term memory store. From the material below, \
extract ONLY what earns a permanent record:
- the user stated or corrected a preference, rule, or standing instruction \
-> kind "directive", written in second person about him ("He wants...", \
"Stay silent when...")
- the assistant finished, discovered, or was proven wrong about something \
she would otherwise re-derive -> kind "note"
- a stable fact about the machine, a person, or a project -> kind "note"
Do NOT record: transient state, step-by-step narration, anything scoped to a \
single conversation, greetings, weather, or anything a file on disk already \
answers. Few good records beat many weak ones; an empty day is a valid answer.

Reply with ONLY a JSON array (no prose, no code fence):
[{"text": "...", "kind": "directive"|"note", "topics": "comma,separated"}]

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
    """Transcription files not yet ingested (tracked by name+size)."""
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
            body = f.read(cap)
        chunks.append(f"[transcript {name}]\n{body}")
        seen[name] = size
    return chunks


def claude_bin():
    claude = os.environ.get("CLAUDE_BIN") or "claude"
    if not any(os.access(os.path.join(p, claude), os.X_OK)
               for p in os.environ.get("PATH", "").split(":")) \
            and not os.path.isfile(claude):
        claude = os.path.expanduser("~/.local/bin/claude")
    return claude


def run_claude(prompt, model, timeout=600):
    # CLAUDE_CODE_DISABLE_AUTO_MEMORY: the ingest distiller and the turn judge
    # inherit whatever directory their caller was in, and `claude` reads that
    # directory's auto-memory index into the system prompt. That index is the
    # USER's coding agent's memory; this store is hers, and the two must not
    # seed each other. Same knob and same reasoning as CLAUDE_NO_AUTO_MEMORY in
    # lib/common.sh, applied here because nothing shell-side wraps these runs.
    env = dict(os.environ, CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    proc = subprocess.run(
        [claude_bin(), "-p", "--model", model, "--dangerously-skip-permissions"],
        input=prompt, capture_output=True, text=True, timeout=timeout, env=env)
    if proc.returncode != 0:
        raise RuntimeError(f"claude exited {proc.returncode}: {proc.stderr.strip()[:200]}")
    return proc.stdout.strip()


def extract_candidates(material, model):
    body = run_claude(INGEST_PROMPT + material, model)
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
        material = "\n\n".join(chunks)[-args.max_chars:]
        print(f"ingest: {len(chunks)} new chunks, {len(material)} chars "
              f"-> {args.model} for judgement...")
        candidates = extract_candidates(material, args.model)

    counts = {"added": 0, "duplicate": 0, "superseded": 0, "rejected": 0}
    for cand in candidates:
        text = (cand.get("text") or "").strip()
        kind = cand.get("kind", "note")
        if not text or kind not in ("directive", "note"):
            counts["rejected"] += 1
            continue
        action, rec_id = store.add_deduped(
            text, kind=kind, source=cand.get("source", "conversation"),
            topics=cand.get("topics", ""))
        counts[action] += 1
        print(f"  {action} #{rec_id} [{kind}] {text[:80]}")

    if not args.dry_run:
        with open(cursor_path, "w") as f:
            json.dump(cursor, f, indent=1)
    print(f"ingest: {counts['added']} added, {counts['superseded']} superseded, "
          f"{counts['duplicate']} duplicates, {counts['rejected']} rejected"
          + (" (dry run — cursor not advanced)" if args.dry_run else ""))
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
prose, no code fence. [] is a common and correct answer.
"""


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
                args.model, timeout=120)
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as e:
            jlog(f"judge failed ({e})")
            return 0
        m = re.search(r"\[[\d,\s]*\]", body)
        if not m:
            jlog(f"unparseable verdict: {body[:120]!r}")
            return 0
        # Only ids that were actually injected can be reinforced — a judge
        # hallucinating an id must not stamp an unrelated record.
        allowed = {r["id"] for r in injected}
        used = [i for i in json.loads(m.group(0)) if i in allowed]
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
    if args.no_dedup:
        rec_id = store.insert(text, args.kind, args.pin, args.source, args.topics)
        action = "added"
    else:
        action, rec_id = store.add_deduped(text, args.kind, args.pin,
                                           args.source, args.topics)
    print(f"{action} #{rec_id} [{args.kind}]")
    return 0


def cmd_search(store, args):
    query = " ".join(args.query).strip()
    rows, embed_ms, knn_ms = store.search(query, k=args.n)
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
        "       supersedes, created, last_seen FROM memories ORDER BY id").fetchall()
    for r in rows:
        print(f"#{r[0]} [{r[2]}]{' PINNED' if r[3] else ''} "
              f"status={r[7]} confidence={r[6]:g} source={r[4]}")
        if r[5]:
            print(f"  topics: {r[5]}")
        if r[8]:
            print(f"  supersedes: #{r[8]}")
        print(f"  created {r[9]}  last_seen {r[10]}")
        print(f"  {r[1]}")
        print()
    print(f"-- {len(rows)} records in {store.path}")
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
    p.add_argument("--kind", choices=("directive", "note"), default="note")
    p.add_argument("--pin", action="store_true")
    p.add_argument("--source", default="conversation")
    p.add_argument("--topics", default="")
    p.add_argument("--no-dedup", action="store_true")
    p.add_argument("text", nargs="+")
    p.set_defaults(fn=cmd_add)

    p = sub.add_parser("search", help="semantic search")
    p.add_argument("-n", type=int, default=TOP_K)
    p.add_argument("query", nargs="+")
    p.set_defaults(fn=cmd_search)

    p = sub.add_parser("list", help="list records")
    p.add_argument("--kind", choices=("directive", "note"))
    p.add_argument("--all", action="store_true", help="include superseded/retired")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("dump", help="whole store as readable text")
    p.set_defaults(fn=cmd_dump)

    p = sub.add_parser("forget", help="retire a record by id")
    p.add_argument("id", type=int)
    p.set_defaults(fn=cmd_forget)

    p = sub.add_parser("reinforce",
                       help="mark records genuinely used this turn "
                            "(bumps last_used_at and use_count)")
    p.add_argument("ids", type=int, nargs="+")
    p.set_defaults(fn=cmd_reinforce)

    p = sub.add_parser("ingest", help="distil new journal/transcript text into records")
    p.add_argument("--journal-dir",
                   default=os.path.expanduser("~/.local/share/deskcrab/journal"))
    p.add_argument("--transcripts-dir",
                   default=os.path.expanduser("~/Documents/Transcriptions"))
    p.add_argument("--from-json", help="pre-judged candidates file (skips the model)")
    p.add_argument("--model",
                   default=os.environ.get("MEMORY_INGEST_MODEL") or "sonnet")
    p.add_argument("--max-chars", type=int, default=150000)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_ingest)

    p = sub.add_parser("recall-block", help="prompt block for a wake (fail-safe)")
    p.add_argument("--query", default="")
    p.add_argument("--reason", default="")
    p.add_argument("--wants", default="")
    p.add_argument("--convo", default="")
    p.add_argument("--ids-out", default="",
                   help="write the injected records (id/kind/text JSON) here "
                        "for the turn-end judge")
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
