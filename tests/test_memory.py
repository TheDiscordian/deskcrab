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
from datetime import datetime, timedelta

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


def days_ago(n):
    return (datetime.now().astimezone() - timedelta(days=n)).isoformat(
        timespec="seconds")


def fake_row(kind="note", sim=0.8, conf=1.0, created_days=0, used_days=None,
             uses=0, text="x", rec_id=1):
    return (rec_id, text, kind, 0, "self", "", conf, days_ago(created_days),
            days_ago(0), sim,
            None if used_days is None else days_ago(used_days), uses)


class TestScoreFormula(unittest.TestCase):
    # The 13:15 formula is deterministic — no store, no embedder.
    def setUp(self):
        self.now = datetime.now().astimezone()

    def test_directive_is_raw_cosine(self):
        row = fake_row(kind="directive", sim=0.6, created_days=400,
                       used_days=400, uses=50)
        self.assertEqual(memory.score_row(row, self.now), 0.6)

    def test_fresh_unused_note_scores_its_cosine(self):
        self.assertAlmostEqual(
            memory.score_row(fake_row(sim=0.8), self.now), 0.8, places=2)

    def test_decay_halves_at_half_life(self):
        row = fake_row(sim=0.8, used_days=memory.DECAY_HALF_LIFE_DAYS)
        self.assertAlmostEqual(memory.score_row(row, self.now), 0.4, places=2)

    def test_decay_counts_from_last_use_not_creation(self):
        # He caught this flaw: a memory used all the time must not fade like
        # one never used. Old note, used today -> no decay (only the boost).
        stale = fake_row(sim=0.8, created_days=400)
        lived = fake_row(sim=0.8, created_days=400, used_days=0, uses=1)
        self.assertLess(memory.score_row(stale, self.now), 0.1)
        self.assertGreater(memory.score_row(lived, self.now), 0.8)

    def test_boost_is_log_shaped_and_capped(self):
        s10 = memory.score_row(fake_row(sim=0.8, used_days=0, uses=10), self.now)
        s100 = memory.score_row(fake_row(sim=0.8, used_days=0, uses=100), self.now)
        self.assertGreater(s100, s10)          # a hundred beats ten...
        self.assertLess(s100, s10 * 2)         # ...by a little, not tenfold
        absurd = fake_row(sim=0.8, used_days=0, uses=10**9)
        self.assertLessEqual(memory.score_row(absurd, self.now),
                             0.8 * memory.REINFORCE_MAX_BOOST + 1e-9)

    def test_confidence_still_fades_the_score(self):
        weak = fake_row(sim=0.8, conf=0.5)
        self.assertAlmostEqual(memory.score_row(weak, self.now), 0.4, places=2)


class TestReinforce(StoreCase):
    # vec supplied by hand -> no embedder needed.
    def test_reinforce_stamps_use(self):
        rec_id = self.store.insert("n", vec=[0.1] * memory.EMBED_DIM)
        self.assertEqual(self.store.reinforce([rec_id, 999]), [rec_id])
        self.store.reinforce([rec_id])
        used, count = self.store.db.execute(
            "SELECT last_used_at, use_count FROM memories WHERE id=?",
            (rec_id,)).fetchone()
        self.assertIsNotNone(used)
        self.assertEqual(count, 2)

    def test_retrieval_never_reinforces(self):
        # Agreed guard: mere retrieval must not feed the boost — only the
        # explicit reinforce path may, or the loop feeds itself.
        self.store.insert("His character Xena is a Paladin.", topics="wow")
        self.store.search("which character does he play")
        used, count = self.store.db.execute(
            "SELECT last_used_at, use_count FROM memories WHERE id=1").fetchone()
        self.assertIsNone(used)
        self.assertEqual(count, 0)


class TestDecayPass(StoreCase):
    def age(self, rec_id, days, column="last_seen"):
        self.store.db.execute(f"UPDATE memories SET {column}=? WHERE id=?",
                              (days_ago(days), rec_id))
        self.store.db.commit()

    def test_stale_note_loses_confidence_fresh_note_does_not(self):
        vec = [0.1] * memory.EMBED_DIM
        stale = self.store.insert("stale", vec=vec)
        fresh = self.store.insert("fresh", vec=vec)
        self.age(stale, memory.DECAY_STALE_DAYS + 10)
        self.assertEqual(self.store.decay_pass(), (1, 0))
        confs = dict(self.store.db.execute(
            "SELECT id, confidence FROM memories"))
        self.assertAlmostEqual(confs[stale], 0.9)
        self.assertEqual(confs[fresh], 1.0)

    def test_recent_use_blocks_decay(self):
        rec = self.store.insert("used often", vec=[0.1] * memory.EMBED_DIM)
        self.age(rec, 200)
        self.age(rec, 1, column="last_used_at")
        self.assertEqual(self.store.decay_pass(), (0, 0))

    def test_note_retires_below_floor(self):
        rec = self.store.insert("fading", vec=[0.1] * memory.EMBED_DIM)
        self.store.db.execute("UPDATE memories SET confidence=0.35 WHERE id=?",
                              (rec,))
        self.age(rec, 200)
        self.assertEqual(self.store.decay_pass(), (0, 1))
        conf, status = self.store.db.execute(
            "SELECT confidence, status FROM memories WHERE id=?",
            (rec,)).fetchone()
        self.assertEqual(status, "retired")
        self.assertLess(conf, memory.DECAY_RETIRE_FLOOR)

    def test_directives_never_decay(self):
        rec = self.store.insert("his rule", kind="directive",
                                vec=[0.1] * memory.EMBED_DIM)
        self.age(rec, 400)
        self.assertEqual(self.store.decay_pass(), (0, 0))
        self.assertEqual(self.store.db.execute(
            "SELECT confidence, status FROM memories WHERE id=?",
            (rec,)).fetchone(), (1.0, "active"))


class TestSearchScoring(StoreCase):
    def test_directives_do_not_crowd_note_slots(self):
        # Two pools, queried separately: the note pool is notes-only, so a
        # high-similarity directive cannot spend one of the K note slots.
        self.store.insert("His character Xena is a Paladin on DiscoWoW.",
                          kind="note", topics="wow")
        self.store.insert("When he asks about WoW, check DiscoWoW highscores.",
                          kind="directive")
        self.store.insert("Never spend gold from his WoW characters.",
                          kind="directive")
        rows, _, _ = self.store.search("which WoW character does he play", k=1)
        self.assertIn("note", [r[2] for r in rows])

    def test_decay_reranks_and_reinforce_recovers(self):
        vec_a = self.store.embed_text(
            "His character Xena is a Paladin on the DiscoWoW server.")
        a = self.store.insert("His character Xena is a Paladin on the "
                              "DiscoWoW server.", topics="wow", vec=vec_a)
        b = self.store.insert("DiscoWoW runs on a WotLK 3.3.5a private "
                              "server core.", topics="wow")

        def order(rows):
            ids = [r[0] for r in rows if r[2] == "note"]
            return ids.index(a) < ids.index(b)

        query = "which character does he play on DiscoWoW"
        rows, _, _ = self.store.search(query)
        self.assertTrue(order(rows))  # raw similarity favours the Xena note
        # Age the Xena note far past the half-life (never used -> decays from
        # creation): the fresher note must outrank it.
        self.store.db.execute("UPDATE memories SET created=? WHERE id=?",
                              (days_ago(400), a))
        self.store.db.commit()
        rows, _, _ = self.store.search(query)
        self.assertFalse(order(rows))
        # One genuine use resets the decay clock: back on top.
        self.store.reinforce([a])
        rows, _, _ = self.store.search(query)
        self.assertTrue(order(rows))


class TestBlockCap(unittest.TestCase):
    def test_block_truncates_notes_first_and_says_so(self):
        directives = [fake_row(kind="directive", rec_id=i,
                               text=f"rule {i} " + "d" * 120)
                      for i in range(5)]
        notes = [fake_row(rec_id=100 + i, text=f"note {i} " + "n" * 200)
                 for i in range(30)]
        block = memory.format_block(directives + notes)
        self.assertLessEqual(
            len(block), memory.BLOCK_TOKEN_CAP * memory.CHARS_PER_TOKEN)
        self.assertIn("TRUNCATED", block)
        for r in directives:  # notes drop first; his rules survive
            self.assertIn(r[1], block)

    def test_small_block_is_not_marked_truncated(self):
        block = memory.format_block([fake_row(text="short note")])
        self.assertNotIn("TRUNCATED", block)

    def test_kept_rows_match_the_block(self):
        # The judge sidecar must list exactly what reached the prompt: a note
        # truncated out of the block must not be judgeable.
        directives = [fake_row(kind="directive", rec_id=i,
                               text=f"rule {i} " + "d" * 120)
                      for i in range(5)]
        notes = [fake_row(rec_id=100 + i, text=f"note {i} " + "n" * 200)
                 for i in range(30)]
        block, kept = memory.build_block(directives + notes)
        self.assertLess(len(kept), 35)
        for r in kept:
            self.assertIn(r[1], block)
        dropped = [r for r in directives + notes if r not in kept]
        self.assertTrue(dropped)
        for r in dropped:
            self.assertNotIn(r[1], block)


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


class TestRecallBlockIds(StoreCase):
    def test_ids_out_lists_the_injected_records(self):
        a = self.store.insert("His character Xena is a Paladin on DiscoWoW.",
                              kind="note", topics="wow")
        self.store.insert("The weather cache refreshes every fifteen minutes.",
                          kind="note", topics="weather")
        out = os.path.join(self.dir, "injected.json")
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "recall-block", "--query", "which WoW character does he play",
             "--ids-out", out],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(out) as f:
            injected = json.load(f)
        self.assertIn(a, [r["id"] for r in injected])
        for r in injected:  # every listed record really is in the block
            self.assertIn(r["text"], proc.stdout)

    def test_empty_store_writes_no_sidecar(self):
        out = os.path.join(self.dir, "injected.json")
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "recall-block", "--query", "anything", "--ids-out", out],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(out))

    def test_degraded_path_still_reports_pinned(self):
        # Embedder down -> pinned records still reach the prompt, so they are
        # still judgeable and the sidecar must say so.
        p = self.store.insert("Nothing outward-facing while unattended.",
                              kind="directive", pinned=True,
                              vec=[0.1] * memory.EMBED_DIM)
        out = os.path.join(self.dir, "injected.json")
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir,
                   MEMORY_EMBED_URL="http://127.0.0.1:9")
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "recall-block", "--query", "anything", "--ids-out", out],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(out) as f:
            self.assertEqual([r["id"] for r in json.load(f)], [p])


class TestJudgeTurn(StoreCase):
    """The turn-end genuinely-used judge, with the judge model stubbed: the
    claude binary is a script echoing a canned verdict, so what is under test
    is the plumbing — judged subset reinforced, ignored records untouched,
    sidecar consumed, hallucinated ids rejected."""

    def setUp(self):
        super().setUp()
        vec = [0.1] * memory.EMBED_DIM
        self.used = self.store.insert("His character Xena is a Paladin.",
                                      vec=vec)
        self.ignored = self.store.insert("The lux sensor lives on the i2c bus.",
                                         vec=vec)
        self.log = os.path.join(self.dir, "judge.log")

    def stub_claude(self, verdict):
        # The prompt the judge builds is kept, so a test can assert what the
        # model was actually shown rather than only what it answered.
        path = os.path.join(self.dir, "claude-stub")
        self.seen_prompt = os.path.join(self.dir, "judge-prompt.txt")
        with open(path, "w") as f:
            f.write(f"#!/bin/sh\ncat >'{self.seen_prompt}'\n"
                    f"printf '%s\\n' '{verdict}'\n")
        os.chmod(path, 0o755)
        return path

    def judge(self, verdict, ids=None, reply="Xena is your Paladin.",
              actions=""):
        ids_file = os.path.join(self.dir, "injected.json")
        rows = [(self.used, "note"), (self.ignored, "note")] \
            if ids is None else ids
        with open(ids_file, "w") as f:
            json.dump([{"id": i, "kind": k, "text": "t"} for i, k in rows], f)
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir,
                   CLAUDE_BIN=self.stub_claude(verdict))
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "judge-turn", "--ids-file", ids_file, "--user", "who do I play",
             "--reply", reply, "--actions", actions, "--log", self.log],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return ids_file

    def usage(self, rec_id):
        return self.store.db.execute(
            "SELECT use_count, last_used_at FROM memories WHERE id=?",
            (rec_id,)).fetchone()

    def test_judged_subset_reinforced_ignored_untouched(self):
        ids_file = self.judge(f"[{self.used}]")
        count, stamp = self.usage(self.used)
        self.assertEqual(count, 1)
        self.assertIsNotNone(stamp)
        self.assertEqual(self.usage(self.ignored), (0, None))
        # The sidecar describes one turn and is consumed by the judgement.
        self.assertFalse(os.path.exists(ids_file))
        with open(self.log) as f:
            self.assertIn(f"used=[{self.used}]", f.read())

    def test_none_verdict_reinforces_nothing(self):
        self.judge("[]")
        self.assertEqual(self.usage(self.used), (0, None))
        self.assertEqual(self.usage(self.ignored), (0, None))
        with open(self.log) as f:
            self.assertIn("used=NONE", f.read())

    def test_hallucinated_ids_are_rejected(self):
        # The judge may only reinforce what was actually injected — an id from
        # outside the sidecar must not stamp an unrelated record.
        self.judge(f"[{self.used}, {self.ignored}, 999]",
                   ids=[(self.used, "note")])
        self.assertEqual(self.usage(self.used)[0], 1)
        self.assertEqual(self.usage(self.ignored), (0, None))

    def test_no_reply_and_no_actions_skips_the_model(self):
        ids_file = self.judge(f"[{self.used}]", reply="  ")
        self.assertEqual(self.usage(self.used), (0, None))
        self.assertFalse(os.path.exists(ids_file))
        with open(self.log) as f:
            self.assertIn("skipped (no reply, no actions)", f.read())

    def test_wordless_turn_is_judged_on_its_actions(self):
        # The case the directive exists for: a wake whose whole output is tool
        # calls. Words are not the only evidence a record was obeyed, so an
        # empty reply plus a work trace must still reach the judge.
        ids_file = self.judge(f"[{self.used}]", reply="",
                              actions="wrote ~/notes.md; ran 4 commands")
        self.assertEqual(self.usage(self.used)[0], 1)
        self.assertFalse(os.path.exists(ids_file))
        with open(self.log) as f:
            self.assertIn(f"used=[{self.used}]", f.read())

    def test_actions_reach_the_judge_prompt(self):
        # Not merely accepted as a flag — actually put in front of the model.
        self.judge("[]", reply="a word",
                   actions="wrote ~/canary-marker.md; ran 9 commands")
        with open(self.seen_prompt) as f:
            self.assertIn("wrote ~/canary-marker.md; ran 9 commands", f.read())

    def test_reinforcement_lands_in_the_score(self):
        # End state of the whole path: the judged record now outranks its
        # pre-judgement self in score_row.
        now = datetime.now().astimezone()
        self.store.db.execute("UPDATE memories SET created=? WHERE id=?",
                              (days_ago(120), self.used))
        self.store.db.commit()

        def score():
            row = self.store.db.execute(
                "SELECT id, text, kind, pinned, source, topics, confidence,"
                "       created, last_seen, 0.8, last_used_at, use_count"
                " FROM memories WHERE id=?", (self.used,)).fetchone()
            return memory.score_row(row, now)

        before = score()
        self.judge(f"[{self.used}]")
        self.assertGreater(score(), before)


if __name__ == "__main__":
    unittest.main()
