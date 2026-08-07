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


def pack(vec):
    return struct.pack(f"{len(vec)}f", *vec)


def embed(texts, query=False, timeout=30):
    """Embed a list of texts via the local ollama daemon. nomic-embed-text
    wants its task prefix: search_document at ingest, search_query at recall."""
    prefix = "search_query: " if query else "search_document: "
    req = urllib.request.Request(
        EMBED_URL,
        data=json.dumps({"model": EMBED_MODEL,
                         "input": [prefix + t for t in texts]}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        out = json.load(resp)["embeddings"]
    if len(out) != len(texts) or any(len(v) != EMBED_DIM for v in out):
        raise RuntimeError(f"embedder returned wrong shape (model {EMBED_MODEL})")
    return out


class Store:
    def __init__(self, directory=None):
        self.dir = directory or default_dir()
        os.makedirs(self.dir, exist_ok=True)
        self.path = os.path.join(self.dir, "memory.db")
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
                -- Reinforcement (13:15 design revision): bumped only when a
                -- memory is judged GENUINELY USED at turn end, never on mere
                -- retrieval. Schema-ready; the turn-end judge is not wired yet.
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
        """Raw KNN against active records: [(row, similarity)], best first."""
        total = self.db.execute(
            "SELECT count(*) FROM memories WHERE status='active'").fetchone()[0]
        if total == 0:
            return []
        # vec0 KNN cannot see the metadata table, so over-fetch and filter in
        # the join; the corpus is small enough that fetching every vector is
        # still sub-millisecond.
        rows = self.db.execute(
            "SELECT m.id, m.text, m.kind, m.pinned, m.source, m.topics,"
            "       m.confidence, m.created, m.last_seen, 1.0 - v.distance AS sim"
            " FROM memories_vec v JOIN memories m ON m.id = v.rowid"
            " WHERE v.embedding MATCH ? AND v.k = ? AND m.status = 'active'"
            " ORDER BY sim * m.confidence DESC",
            (pack(vec), max(k * 4, 64))).fetchall()
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
        """The retrieval rule from the design: top-K above SIM_FLOOR, plus
        every directive above the looser DIRECTIVE_FLOOR (capped), plus every
        pinned record; near-duplicates of an already-taken record squashed."""
        t0 = time.monotonic()
        qvec = embed([query], query=True)[0]
        t1 = time.monotonic()
        rows = self.knn(qvec, 0)
        picked, seen, taken = [], set(), 0
        for row in rows:
            if taken >= k or row[9] < SIM_FLOOR:
                break
            if self._near_dup(row, picked):
                continue
            picked.append(row)
            seen.add(row[0])
            taken += 1
        directives = 0
        for row in rows:
            if row[0] in seen:
                directives += row[2] == "directive"
                continue
            want = (row[2] == "directive" and row[9] >= DIRECTIVE_FLOOR
                    and directives < DIRECTIVE_CAP) or row[3]
            if want and not self._near_dup(row, picked):
                picked.append(row)
                seen.add(row[0])
                directives += row[2] == "directive"
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
            "       created, last_seen, 1.0"
            " FROM memories WHERE status='active' AND pinned=1"
            " ORDER BY kind DESC, id").fetchall()


# --- recall-block: the prompt-facing view -----------------------------------

def recall_query(reason, wants_file, convo_file):
    """Query formation when nobody asked anything: the wake's reason if it has
    one, else the wants shelf lines, plus the tail of the live conversation."""
    parts = []
    if reason:
        parts.append(reason)
    elif wants_file and os.path.isfile(wants_file):
        with open(wants_file, errors="replace") as f:
            bullets = [l.strip() for l in f if l.startswith("- ")]
        parts.extend(bullets[:12])
    if convo_file and os.path.isfile(convo_file):
        with open(convo_file, errors="replace") as f:
            tail = f.readlines()[-10:]
        parts.append(" ".join(l.strip() for l in tail))
    return "\n".join(p for p in parts if p).strip()


def format_block(rows, warning=""):
    if not rows and not warning:
        return ""
    out = ["## What you remember (retrieved, not exhaustive — "
           "'crab memory search <query>' for more)"]
    if warning:
        out.append(f"\n{warning}")
    directives = [r for r in rows if r[2] == "directive"]
    notes = [r for r in rows if r[2] == "note"]
    if directives:
        out.append("\nThings he has told you:")
        out.extend(f"- {r[1]} ({r[7][:10]})" for r in directives)
    if notes:
        out.append("\nThings you know from your own time:")
        out.extend(f"- {r[1]} ({r[7][:10]})" for r in notes)
    return "\n".join(out)


def cmd_recall_block(store, args):
    query = args.query or recall_query(args.reason, args.wants, args.convo)
    if not query:
        rows = store.pinned_rows()
        print(format_block(rows), end="" if not rows else "\n")
        return 0
    try:
        rows, _, _ = store.search(query)
    except (urllib.error.URLError, OSError, RuntimeError) as e:
        # Degraded recall, never silent amnesia: the pinned tier plus a loud
        # warning still reach the prompt.
        rows = store.pinned_rows()
        block = format_block(
            rows, f"WARNING: memory retrieval is DOWN ({e}); only pinned "
                  "records are shown. 'crab memory list' still works.")
        if block:
            print(block)
        return 0
    block = format_block(rows)
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


def extract_candidates(material, model):
    claude = os.environ.get("CLAUDE_BIN") or "claude"
    if not any(os.access(os.path.join(p, claude), os.X_OK)
               for p in os.environ.get("PATH", "").split(":")) \
            and not os.path.isfile(claude):
        claude = os.path.expanduser("~/.local/bin/claude")
    proc = subprocess.run(
        [claude, "-p", "--model", model, "--dangerously-skip-permissions"],
        input=INGEST_PROMPT + material, capture_output=True, text=True, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(f"claude exited {proc.returncode}: {proc.stderr.strip()[:200]}")
    body = proc.stdout.strip()
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
        flags = "".join((" pinned" if r[3] else "",))
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
    p.set_defaults(fn=cmd_recall_block)

    args = ap.parse_args()
    store = Store()
    sys.exit(args.fn(store, args))


if __name__ == "__main__":
    main()
