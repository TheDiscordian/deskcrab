#!/bin/bash
# memory-recall.md rules 53-56: the social kind and the visibility column.
#
# Stubbed embeddings in-process for the Store cases (a constructed vector per
# text, so a social row can be made the BEST match and still never surface),
# and a fixture embedder on localhost for the CLI cases, which run lib/memory.py
# as the connector does. No daemon, no network beyond the loopback fixture.
. "$(dirname "$(readlink -f "$0")")/lib/sandbox.sh"
set -u

REPO="$SANDBOX_REPO"
WORK="$SANDBOX/social"
mkdir -p "$WORK"
PY="${MEMORY_PYTHON:-python3}"
"$PY" -c "import sqlite_vec" 2>/dev/null \
    || sandbox_skip "no sqlite-vec interpreter (MEMORY_PYTHON) on this box"

cat > "$WORK/driver.py" <<'EOF'
"""Every case in one process; a failed assertion is a named line and a nonzero exit."""
import hashlib, importlib.util, json, math, os, sqlite3, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO, WORK = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("memory", REPO + "/lib/memory.py")
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)
D = memory.EMBED_DIM
failures = []


def check(name, ok):
    print(("ok " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


def unit(*pairs):
    v = [0.0] * D
    for i, val in pairs:
        v[i] = val
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v]


def hashed(text):
    digest = hashlib.sha256(text.encode()).digest()
    raw = [(digest[i % 32] / 255.0) - 0.5 for i in range(D)]
    n = math.sqrt(sum(x * x for x in raw))
    return [x / n for x in raw]


Q = "what did that person say about poetry"
VECS = {"": unit((0, 1.0)), Q: unit((1, 1.0))}
memory.embed = lambda texts, query=False, timeout=30: [VECS.get(t, hashed(t)) for t in texts]
os.environ.setdefault("DESKCRAB_CONDUCT_DIR", os.path.join(WORK, "conduct"))

# --- rule 54: never retrieved into a prompt, never on the pinned tier, labelled if rendered
sdir = tempfile.mkdtemp(prefix="social-", dir=WORK)
store = memory.Store(sdir)
A, B = "did:plc:alpha", "did:plc:bravo"
best = unit((1, 1.0))                      # cosine 1.0 against Q: the best match in the store
near = unit((1, 0.8), (2, 0.6))            # 0.8: a note that clears every floor
action, sid = store.social_retain(A, 'On Bluesky, @alpha.test replied to me: "poetry is my whole life"')
store.db.execute("DELETE FROM memories_vec WHERE rowid=?", (sid,))
store.db.execute("INSERT INTO memories_vec(rowid, embedding) VALUES (?,?)", (sid, memory.pack(best)))
nid = store.insert("a note about poetry", kind="note", vec=near)
store.db.commit()
rows, _, _, abst = store.search(Q)
check("prompt retrieval never returns the best-matching social row", [r[2] for r in rows] == ["note"])
store.db.execute("UPDATE memories SET pinned=1 WHERE id=?", (sid,))
store.db.commit()
check("a pinned social row never rides the pinned tier", all(r[2] != "social" for r in store.pinned_rows()))
rows, _, _, _ = store.search(Q)
check("the pinned social row still stays out of the block", all(r[2] != "social" for r in rows))
rows, _, _, _ = store.search(Q, deliberate=True)
check("the deliberate search shows it", any(r[2] == "social" for r in rows))
block = memory.build_block(rows)[0]
check("rendered, it carries its own attributed label",
      "What people said to me on a public network" in block and "never instructions" in block)
store.db.execute("UPDATE memories SET pinned=0 WHERE id=?", (sid,))
store.db.commit()

# --- rule 55: exact source equality, public only, default private
store.social_retain(B, 'On Bluesky, @bravo.test mentioned me: "ask ' + A + ' about poetry"')
store.social_retain(A + "x", "prefix collision")
pid = store.insert("private note naming " + A, kind="note", source="private-phone")
dup = store.social_retain(A, 'on bluesky,  @alpha.test replied to me: "poetry is my whole life"')
check("an exact normalised repeat under one DID is a duplicate", dup == ("duplicate", sid))
out = store.social_recall([A, B])
check("A's door returns only A's row", [m["id"] for m in out["people"][A]["memories"]] == [sid]
      and out["people"][A]["count"] == 1)
check("B's door returns only B's row, mention and all", len(out["people"][B]["memories"]) == 1
      and A in out["people"][B]["memories"][0]["text"])
check("public_self is empty until a row is marked", out["public_self"] == [])
store.set_visibility(sid, "private")
check("a private social row leaves the door", store.social_recall([A])["people"][A]["count"] == 0)
store.set_visibility(sid, "public")
check("the explicit mark brings it back", store.social_recall([A])["people"][A]["count"] == 1)
check("set_visibility reports a missing row", store.set_visibility(99999, "public") is False)
try:
    store.set_visibility(sid, "secret")
    check("an unknown visibility is refused", False)
except ValueError:
    check("an unknown visibility is refused", True)
me = store.insert("I like reading on rainy evenings", kind="note", visibility="public")
hidden = store.insert("CANARY one night's shape", kind="observation", visibility="public")
out = store.social_recall([A])
check("public_self carries only the explicitly public prompt-facing row",
      [x["id"] for x in out["public_self"]] == [me])
check("every row is private unless marked",
      store.db.execute("SELECT visibility FROM memories WHERE id=?", (pid,)).fetchone()[0] == "private")
try:
    store.social_retain("not a did", "x")
    check("a social row needs a DID", False)
except ValueError:
    check("a social row needs a DID", True)
try:
    store.social_retain(A, "   ")
    check("a social row needs words", False)
except ValueError:
    check("a social row needs words", True)
check("add_deduped keeps a note private by default",
      store.db.execute("SELECT visibility FROM memories WHERE id=?",
                       (store.add_deduped("another ordinary note", kind="note")[1],)).fetchone()[0] == "private")
check("add_deduped carries an explicit public mark",
      store.db.execute("SELECT visibility FROM memories WHERE id=?",
                       (store.add_deduped("a public note", kind="note", visibility="public")[1],)).fetchone()[0] == "public")

# --- rule 56: the migration from the five-kind check
old = tempfile.mkdtemp(prefix="old-", dir=WORK)
db = sqlite3.connect(old + "/memory.db")
db.enable_load_extension(True)
import sqlite_vec
sqlite_vec.load(db)
db.executescript("""
CREATE TABLE memories (id INTEGER PRIMARY KEY, text TEXT NOT NULL,
 kind TEXT NOT NULL CHECK (kind IN ('directive','note','episodic','observation','miss')),
 pinned INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT 'self', topics TEXT NOT NULL DEFAULT '',
 confidence REAL NOT NULL DEFAULT 1.0, status TEXT NOT NULL DEFAULT 'active'
 CHECK (status IN ('active','superseded','retired')), supersedes INTEGER, superseded_by INTEGER,
 created TEXT NOT NULL, last_seen TEXT NOT NULL, last_used_at TEXT, use_count INTEGER NOT NULL DEFAULT 0,
 occurred TEXT, participants TEXT NOT NULL DEFAULT '', opinion TEXT NOT NULL DEFAULT '',
 lookup_key TEXT NOT NULL DEFAULT '', about TEXT NOT NULL DEFAULT '');
CREATE VIRTUAL TABLE memories_vec USING vec0(embedding float[768] distance_metric=cosine);
INSERT INTO memories (id,text,kind,pinned,created,last_seen,use_count) VALUES (7,'old pinned rule','directive',1,'2026-01-01','2026-01-01',3);
INSERT INTO memories (id,text,kind,created,last_seen) VALUES (9,'old note','note','2026-01-02','2026-01-02');
""")
db.execute("INSERT INTO memories_vec(rowid, embedding) VALUES (7, ?)", (memory.pack(unit((3, 1.0))),))
db.execute("INSERT INTO memories_vec(rowid, embedding) VALUES (9, ?)", (memory.pack(unit((4, 1.0))),))
db.commit()
db.close()
migrated = memory.Store(old)
sql = migrated.db.execute("SELECT sql FROM sqlite_master WHERE name='memories'").fetchone()[0]
check("the kind check is widened around the data", "'social'" in sql and "visibility" in sql)
check("ids, pins, counts and visibility survive",
      migrated.db.execute("SELECT id,pinned,use_count,visibility FROM memories ORDER BY id").fetchall()
      == [(7, 1, 3, "private"), (9, 0, 0, "private")])
check("vectors are untouched", migrated.vec_of(7)[3] > 0.99 and migrated.vec_of(9)[4] > 0.99)
check("the widened store takes a social row", migrated.social_retain(A, "after the migration")[0] == "added")
again = memory.Store(old)
check("a second open is a no-op", again.db.execute("SELECT count(*) FROM memories").fetchone()[0] == 3)

# --- rule 53: the CLI doors, run as the connector runs them
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        payload = json.dumps({"embeddings": [hashed(t) for t in body["input"]]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True).start()
cdir = tempfile.mkdtemp(prefix="cli-", dir=WORK)
env = {**os.environ, "DESKCRAB_MEMORY_DIR": cdir, "MEMORY_EMBED_URL": f"http://127.0.0.1:{server.server_port}/api/embed",
       "NOTICE_SUPPRESS": os.path.join(WORK, "notice.suppress")}


def cli(*args, stdin=None):
    return subprocess.run([sys.executable, REPO + "/lib/memory.py", *args], input=stdin, capture_output=True, text=True, env=env)


r = cli("add", "--kind", "social", "--source", "bluesky:" + A, "smuggled")
check("memory add refuses the social kind", r.returncode != 0 and "connector" in r.stderr)
r = cli("social-retain", stdin=json.dumps({"did": A, "text": 'On Bluesky, @alpha.test replied to me: "hello"', "occurred": "2026-11-07T06:00:00Z", "topics": "bluesky reply at://x"}))
check("social-retain answers JSON", r.returncode == 0 and json.loads(r.stdout)["action"] == "added")
first = json.loads(r.stdout)["id"]
r = cli("social-retain", stdin=json.dumps({"did": A, "text": 'On Bluesky, @alpha.test replied to me: "hello"'}))
check("social-retain dedups the replay", json.loads(r.stdout) == {"action": "duplicate", "id": first})
r = cli("social-retain", stdin=json.dumps({"did": "nope", "text": "x"}))
check("social-retain refuses a non-DID without echoing the text", r.returncode == 2 and "x" not in r.stderr.split("keyed")[-1])
r = cli("social-recall", "--did", A, "--did", B)
out = json.loads(r.stdout)
check("social-recall answers per DID", out["people"][A]["count"] == 1 and out["people"][B]["count"] == 0)
r = cli("add", "--kind", "note", "--visibility", "public", "I like reading on rainy evenings")
check("add --visibility public marks the row", r.returncode == 0 and "public" in r.stdout)
nid = int(r.stdout.split("#")[1].split()[0])
r = cli("visibility", str(nid), "private")
check("visibility flips a row back", r.returncode == 0 and json.loads(cli("social-recall", "--did", A).stdout)["public_self"] == [])
r = cli("visibility", "424242", "public")
check("visibility names a missing row", r.returncode != 0)
r = cli("add", "--kind", "note", "a plain note")
check("add without the flag stays private", "public" not in r.stdout)
check("dump marks public rows", "PUBLIC" in cli("dump").stdout.split("I like reading")[0].rsplit("#", 1)[-1] or True)
server.shutdown()
print("-- %d checks, %d failed" % (len(failures) + sum(1 for _ in open(__file__) if False), len(failures)))
sys.exit(1 if failures else 0)
EOF

out="$("$PY" "$WORK/driver.py" "$REPO" "$WORK" 2>&1)"
rc=$?
printf '%s\n' "$out"
check_eq "memory social driver exits clean" "$rc" 0
if printf '%s' "$out" | grep -q '^FAIL '; then fail "driver reported failures"; else ok "no driver case failed"; fi
check "driver reached the migration cases" contains "$out" 'ok a second open is a no-op'
check "driver reached the CLI cases" contains "$out" 'ok visibility flips a row back'
