#!/usr/bin/env python3
# Tests for lib/memory.py. Embedding cases use the REAL local ollama daemon
# (nomic-embed-text) on purpose — a mocked embedder cannot prove semantic
# ranking, and warm embeds cost ~20 ms each. Run with the store's venv:
#   ~/.local/share/deskcrab/venv/bin/python -m unittest tests/test_memory.py -v

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "memory", os.path.join(REPO, "lib", "memory.py"))
memory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory)


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="memtest-")
        self.store = memory.Store(self.dir)

    def tearDown(self):
        self.store.db.close()
        shutil.rmtree(self.dir, ignore_errors=True)


class TestBasics(StoreCase):
    def test_add_and_list(self):
        rec_id = self.store.insert("His character Xena is a Paladin.",
                                   kind="note", topics="wow")
        self.assertEqual(rec_id, 1)
        row = self.store.db.execute(
            "SELECT text, kind, pinned, source, status FROM memories WHERE id=1"
        ).fetchone()
        self.assertEqual(row, ("His character Xena is a Paladin.", "note", 0,
                               "self", "active"))
        vec = self.store.db.execute(
            "SELECT count(*) FROM memories_vec WHERE rowid=1").fetchone()[0]
        self.assertEqual(vec, 1)

    def test_kind_constraint(self):
        with self.assertRaises(Exception):
            self.store.db.execute(
                "INSERT INTO memories (text, kind, created, last_seen)"
                " VALUES ('x', 'gossip', 'now', 'now')")

    def test_pinned_flag_stored(self):
        self.store.insert("Never speak during meetings.", kind="directive",
                          pinned=True)
        self.assertEqual(len(self.store.pinned_rows()), 1)


class TestSearch(StoreCase):
    def setUp(self):
        super().setUp()
        self.store.insert("His character Xena is a Paladin on the DiscoWoW server.",
                          kind="note", topics="wow, gaming")
        self.store.insert("Waybar is restarted with systemctl --user restart waybar.",
                          kind="note", topics="waybar")
        self.store.insert("The weather cache refreshes every fifteen minutes.",
                          kind="note", topics="weather")

    def test_relevant_record_ranks_first(self):
        rows, embed_ms, knn_ms = self.store.search(
            "which World of Warcraft character does he play")
        self.assertTrue(rows)
        self.assertIn("Xena", rows[0][1])
        self.assertGreater(rows[0][9], 0.5)
        self.assertGreater(embed_ms, 0)
        self.assertGreater(knn_ms, 0)

    def test_search_bumps_last_seen(self):
        before = self.store.db.execute(
            "SELECT last_seen FROM memories WHERE id=1").fetchone()[0]
        rows, _, _ = self.store.search("wow paladin character")
        after = self.store.db.execute(
            "SELECT last_seen FROM memories WHERE id=1").fetchone()[0]
        self.assertIn(1, [r[0] for r in rows])
        self.assertGreaterEqual(after, before)

    def test_near_duplicate_squashed(self):
        # Two records saying the same thing must not spend two retrieval
        # slots: the second is squashed at >= NEAR_DUP_SIM to the first.
        self.store.insert("His character Xena is a Paladin on DiscoWoW.",
                          kind="note", topics="wow, gaming")
        rows, _, _ = self.store.search("which character does he play in WoW")
        xena_rows = [r for r in rows if "Xena" in r[1]]
        self.assertEqual(len(xena_rows), 1)

    def test_directive_over_retrieval(self):
        # A directive that would lose the top-k cut must still surface when it
        # clears DIRECTIVE_FLOOR. Force the cut with k=1 on a related query.
        self.store.insert("When he asks about WoW rankings, always check the "
                          "DiscoWoW highscores first.", kind="directive")
        rows, _, _ = self.store.search("look up a World of Warcraft character", k=1)
        kinds = [r[2] for r in rows]
        self.assertIn("directive", kinds)
        self.assertGreater(len(rows), 1)


class TestDedupSupersede(StoreCase):
    def test_duplicate_bumps_not_inserts(self):
        a1, id1 = self.store.add_deduped("He prefers Celsius, never Fahrenheit.",
                                         kind="note")
        a2, id2 = self.store.add_deduped("He prefers Celsius, never Fahrenheit.",
                                         kind="note")
        self.assertEqual((a1, a2), ("added", "duplicate"))
        self.assertEqual(id1, id2)
        count = self.store.db.execute("SELECT count(*) FROM memories").fetchone()[0]
        self.assertEqual(count, 1)

    def test_conflicting_record_supersedes(self):
        _, old_id = self.store.add_deduped(
            "Wake him at seven in the morning on weekdays.", kind="directive")
        action, new_id = self.store.add_deduped(
            "Wake him at nine in the morning on weekdays.", kind="directive")
        self.assertEqual(action, "superseded")
        old = self.store.db.execute(
            "SELECT status FROM memories WHERE id=?", (old_id,)).fetchone()[0]
        link = self.store.db.execute(
            "SELECT supersedes FROM memories WHERE id=?", (new_id,)).fetchone()[0]
        self.assertEqual(old, "superseded")
        self.assertEqual(link, old_id)
        # The superseded record is gone from retrieval; the newer one answers.
        rows, _, _ = self.store.search("what time should he be woken up")
        ids = [r[0] for r in rows]
        self.assertIn(new_id, ids)
        self.assertNotIn(old_id, ids)

    def test_related_but_distinct_rules_both_stay(self):
        # Regression for the first live ingest: two directives sharing a topic
        # but stating DIFFERENT rules (measured 0.81) must both stay active —
        # the old 0.75 auto-supersede cut ate one of them.
        a1, id1 = self.store.add_deduped(
            "Builder tasks go to Fable agents and are dispatched the moment "
            "they are identified.", kind="directive")
        a2, id2 = self.store.add_deduped(
            "Builder tasks are never framed as being done for him — they are "
            "your own work.", kind="directive")
        self.assertEqual((a1, a2), ("added", "added"))
        statuses = [r[0] for r in self.store.db.execute(
            "SELECT status FROM memories WHERE id IN (?,?)", (id1, id2))]
        self.assertEqual(statuses, ["active", "active"])

    def test_different_kind_never_dedups(self):
        a1, _ = self.store.add_deduped("The lux sensor lives on the i2c bus.",
                                       kind="note")
        a2, _ = self.store.add_deduped("The lux sensor lives on the i2c bus.",
                                       kind="directive")
        self.assertEqual((a1, a2), ("added", "added"))


class TestRecallBlock(StoreCase):
    def test_block_groups_by_kind(self):
        self.store.insert("Stay silent during his meetings.", kind="directive")
        self.store.insert("The render-md NON_UNIQUE fix landed on main.",
                          kind="note")
        rows, _, _ = self.store.search("meetings and render-md work")
        block = memory.format_block(rows)
        self.assertIn("## What you remember", block)
        self.assertIn("Things he has told you:", block)
        self.assertIn("Things you know from your own time:", block)
        self.assertLess(block.index("Stay silent"),
                        block.index("NON_UNIQUE"))

    def test_empty_store_empty_block(self):
        self.assertEqual(memory.format_block([]), "")

    def test_recall_query_from_wants_and_convo(self):
        wants = os.path.join(self.dir, "wants.md")
        convo = os.path.join(self.dir, "convo.txt")
        with open(wants, "w") as f:
            f.write("# shelf\n- fix the lux widget\n  - old sub bullet\n")
        with open(convo, "w") as f:
            f.write("User: hello\nAssistant: hi\n")
        q = memory.recall_query("", wants, convo)
        self.assertIn("fix the lux widget", q)
        self.assertNotIn("old sub bullet", q)  # top-level bullets only
        self.assertIn("hello", q)
        # An explicit reason wins over the wants shelf.
        self.assertTrue(memory.recall_query("build finished", wants, convo)
                        .startswith("build finished"))


class TestFailSafe(StoreCase):
    def test_embedder_down_degrades_to_pinned(self):
        self.store.insert("Nothing outward-facing while unattended.",
                          kind="directive", pinned=True)
        env = dict(os.environ,
                   DESKCRAB_MEMORY_DIR=self.dir,
                   MEMORY_EMBED_URL="http://127.0.0.1:9")  # nothing listens
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "recall-block", "--query", "anything at all"],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("WARNING: memory retrieval is DOWN", proc.stdout)
        self.assertIn("Nothing outward-facing", proc.stdout)

    def test_embedder_down_search_fails_loudly(self):
        old = memory.EMBED_URL
        memory.EMBED_URL = "http://127.0.0.1:9"
        try:
            with self.assertRaises(Exception):
                self.store.search("anything")
        finally:
            memory.EMBED_URL = old


class TestIngest(StoreCase):
    def test_journal_delta_and_cursor(self):
        jdir = os.path.join(self.dir, "journal")
        os.makedirs(jdir)
        turns = [{"time": "2026-08-06T10:00:00-0400", "kind": "phone",
                  "user": "please always use Celsius", "reply": "of course"},
                 {"time": "2026-08-06T11:00:00-0400", "kind": "wake",
                  "user": "", "reply": "", "outcome": "(silent — ran no tools)"}]
        path = os.path.join(jdir, "2026-08-06.jsonl")
        with open(path, "w") as f:
            for t in turns:
                f.write(json.dumps(t) + "\n")
        cursor = {}
        chunks = memory.journal_delta(jdir, cursor)
        self.assertEqual(len(chunks), 2)
        self.assertIn("please always use Celsius", chunks[0])
        self.assertEqual(cursor["journal"]["2026-08-06.jsonl"],
                         os.path.getsize(path))
        # Nothing new -> nothing returned; an appended turn -> only the delta.
        self.assertEqual(memory.journal_delta(jdir, cursor), [])
        with open(path, "a") as f:
            f.write(json.dumps({"time": "t", "kind": "desktop",
                                "user": "new turn", "reply": "yes"}) + "\n")
        delta = memory.journal_delta(jdir, cursor)
        self.assertEqual(len(delta), 1)
        self.assertIn("new turn", delta[0])

    def test_transcript_delta_tracks_size(self):
        tdir = os.path.join(self.dir, "transcripts")
        os.makedirs(tdir)
        with open(os.path.join(tdir, "meeting.txt"), "w") as f:
            f.write("we all agreed the deadline is Friday")
        cursor = {}
        chunks = memory.transcript_delta(tdir, cursor)
        self.assertEqual(len(chunks), 1)
        self.assertIn("deadline is Friday", chunks[0])
        self.assertEqual(memory.transcript_delta(tdir, cursor), [])

    def test_ingest_from_json_cli(self):
        cands = [{"text": "He wants DevDocs work kept off weekends.",
                  "kind": "directive", "topics": "scheduling"},
                 {"text": "", "kind": "note"},              # rejected: empty
                 {"text": "bad kind", "kind": "gossip"}]    # rejected: kind
        cfile = os.path.join(self.dir, "cands.json")
        with open(cfile, "w") as f:
            json.dump(cands, f)
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "ingest", "--from-json", cfile],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("1 added", proc.stdout)
        self.assertIn("2 rejected", proc.stdout)
        row = memory.Store(self.dir).db.execute(
            "SELECT kind, source FROM memories").fetchone()
        self.assertEqual(row, ("directive", "conversation"))


if __name__ == "__main__":
    unittest.main()
