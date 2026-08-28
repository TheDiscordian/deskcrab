#!/usr/bin/env python3
# Tests for lib/memory.py. Embedding cases use the REAL local ollama daemon
# (nomic-embed-text) on purpose — a mocked embedder cannot prove semantic
# ranking, and warm embeds cost ~20 ms each. Run with the store's venv:
#   ~/.local/share/deskcrab/venv/bin/python -m unittest tests/test_memory.py -v

import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from argparse import Namespace
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


class TestStoreIsolation(StoreCase):
    """A store that is not the live store has no business in the live state.

    lib/notice-selfchange reads ONE suppression file, the live one, and every
    opener of a store declares its imminent write there so the watcher does not
    report her own plumbing as an intruder. A scratch store's declaration means
    nothing to that watcher and everything to whoever reads the file later: on
    2026-08-07 five /tmp/memtest-* records from this very file were sitting in
    it. Same rule the job runner already applies to the wake it fires.

    What this class pins is the KNOB-LESS default — the explicit knobs
    (NOTICE_SUPPRESS, NOTICE_STATE_DIR) rightly win when set, so a harness
    that exports either as belt-and-braces isolation would flip the very
    behaviour under test. The knobs are cleared here and restored after."""

    KNOBS = ("NOTICE_SUPPRESS", "NOTICE_STATE_DIR")

    def setUp(self):
        self._saved = {k: os.environ.pop(k, None) for k in self.KNOBS}
        super().setUp()

    def tearDown(self):
        super().tearDown()
        for k, v in self._saved.items():
            if v is not None:
                os.environ[k] = v

    def test_scratch_store_declares_beside_itself(self):
        declared = os.path.join(self.dir, "notice-self.suppress")
        self.assertTrue(os.path.exists(declared),
                        "a scratch store left no declaration of its own")
        with open(declared) as f:
            self.assertIn(self.dir, f.read())

    def test_scratch_store_never_touches_the_live_file(self):
        state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser(
            "~/.local/state")
        live = os.path.join(state, "deskcrab", "notice-self.suppress")
        before = ""
        if os.path.exists(live):
            with open(live) as f:
                before = f.read()
        other = tempfile.mkdtemp(prefix="memtest-isolation-")
        try:
            store = memory.Store(other)
            store.db.close()
            after = ""
            if os.path.exists(live):
                with open(live) as f:
                    after = f.read()
            self.assertEqual(before, after,
                             "a scratch store wrote into the live suppression file")
            self.assertNotIn(other, after)
        finally:
            shutil.rmtree(other, ignore_errors=True)

    def test_the_live_store_still_declares_where_the_watcher_looks(self):
        """...and the fix must not silence the real thing: the live store's
        declaration still goes to the one file lib/notice-selfchange reads."""
        data = os.path.join(self.dir, "data")
        state = os.path.join(self.dir, "state")
        live_store = os.path.join(data, "deskcrab", "memory")
        os.makedirs(live_store)
        # DESKCRAB_MEMORY_DIR names the store, XDG_DATA_HOME is what makes
        # that store the LIVE one as far as the module is concerned. Without
        # the first, this case would open his real store to make its point.
        env = dict(os.environ, XDG_DATA_HOME=data, XDG_STATE_HOME=state,
                   DESKCRAB_MEMORY_DIR=live_store)
        env.pop("NOTICE_SUPPRESS", None)
        env.pop("NOTICE_STATE_DIR", None)
        subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"), "list"],
            env=env, check=True, capture_output=True)
        declared = os.path.join(state, "deskcrab", "notice-self.suppress")
        self.assertTrue(os.path.exists(declared),
                        "the live store stopped declaring its writes")
        with open(declared) as f:
            self.assertIn(live_store, f.read())


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
        self.assertIn("## What I remember", block)
        self.assertIn("What I hold to:", block)
        self.assertIn("What I know from my own time:", block)
        self.assertLess(block.index("Stay silent"),
                        block.index("NON_UNIQUE"))

    def test_empty_store_empty_block(self):
        self.assertEqual(memory.format_block([]), "")

    def test_recall_query_wake_uses_the_shelf(self):
        """A wake with no single identifiable want falls back to the shelf
        topics — top-level bullets only, opening clauses only."""
        wants = os.path.join(self.dir, "wants.md")
        convo = os.path.join(self.dir, "convo.txt")
        with open(wants, "w") as f:
            f.write("# shelf\n- fix the lux widget\n  - old sub bullet\n")
        with open(convo, "w") as f:
            f.write("User: hello\nAssistant: hi\n")
        q = memory.recall_query("", wants, convo, wake=True)
        self.assertIn("fix the lux widget", q)
        self.assertNotIn("old sub bullet", q)  # top-level bullets only
        # An explicit reason leads, and implies a wake on its own.
        self.assertTrue(memory.recall_query("build finished", wants, convo)
                        .startswith("build finished"))


class TestQueryBudget(StoreCase):
    """The 2026-08-07 outage: a real wants shelf (paragraph-long bullets with
    dated progress logs) plus a conversation tail composed a 19 k-char query,
    ollama refused it with HTTP 400 'the input length exceeds the context
    length', and every prompt build for a whole day carried only the pinned
    tier while `crab memory search "test"` looked perfectly healthy."""

    def _fat_files(self):
        wants = os.path.join(self.dir, "wants.md")
        convo = os.path.join(self.dir, "convo.txt")
        with open(wants, "w") as f:
            f.write("# shelf\n")
            for i in range(30):
                f.write(f"- want {i} " + ("history " * 400) + "\n")
        with open(convo, "w") as f:
            for i in range(200):
                f.write(f"User: line {i} " + ("chatter " * 200) + "\n")
        return wants, convo

    def _log(self):
        """Every case here truncates, and truncation is LOGGED. Without a sink
        of its own that line lands in the live recall log, which is not a
        tidiness problem: all thirteen lines in the live log were this file's
        50 000 x's, and an investigation read them as real wakes and concluded
        that every autonomous wake retrieved nothing."""
        return os.path.join(self.dir, "recall.log")

    def test_wake_query_stays_within_budget(self):
        wants, convo = self._fat_files()
        q = memory.recall_query("", wants, convo, wake=True, log=self._log())
        self.assertLessEqual(len(q), memory.RECALL_QUERY_CHARS)
        self.assertIn("want 0", q)        # the shelf is still represented

    def test_conversation_query_stays_within_budget(self):
        _, convo = self._fat_files()
        q = memory.recall_query("", None, convo, log=self._log())
        self.assertLessEqual(len(q), memory.RECALL_QUERY_CHARS)
        self.assertIn("line 199", q)      # the newest turn, not the oldest

    def test_reason_query_stays_within_budget(self):
        _, convo = self._fat_files()
        q = memory.recall_query("x" * 50000, None, convo, log=self._log())
        self.assertLessEqual(len(q), memory.RECALL_QUERY_CHARS)

    def test_no_empty_or_whitespace_segments(self):
        wants = os.path.join(self.dir, "wants.md")
        with open(wants, "w") as f:
            f.write("- \n-  \t \n- a real want\n- \n")
        q = memory.recall_query("", wants, None, wake=True)
        self.assertEqual(q, "a real want")
        self.assertEqual(memory.recall_query("   \n \t ", None, None), "")

    def test_truncation_is_logged_never_silent(self):
        """Degradation must not be as quiet as working: the outage was a query
        that grew past the embedder's mouth with nothing anywhere saying so."""
        log = os.path.join(self.dir, "recall.log")
        convo = os.path.join(self.dir, "convo.txt")
        with open(convo, "w") as f:
            f.write("User: " + ("word " * 4000) + "\n")
        def logged():
            with open(log) as f:
                return f.read()

        q = memory.recall_query("", None, convo, budget=500, log=log)
        self.assertLessEqual(len(q), 500)
        self.assertGreater(len(q), 400)
        self.assertIn("TRUNCATED", logged())
        self.assertIn("user turn", logged())
        # A query that fits leaves no line behind.
        before = logged()
        memory.recall_query("", None, convo, budget=99999, log=log)
        self.assertEqual(logged(), before)

    def test_budget_sits_under_the_embedder_ceiling(self):
        """The cap is derived from 2048 tokens at a deliberately LOW
        chars-per-token, so it is wrong in the safe direction."""
        self.assertLessEqual(memory.RECALL_QUERY_CHARS, memory.EMBED_CHAR_CAP)
        self.assertLessEqual(
            memory.EMBED_CHAR_CAP,
            memory.EMBED_TOKEN_LIMIT * memory.EMBED_CHARS_PER_TOKEN)
        self.assertLess(memory.EMBED_CHARS_PER_TOKEN, 3.0)


class TestQuerySubstance(StoreCase):
    """What the query is ABOUT, which the 2026-08-07 length fix left wrong.

    Shortening the query kept the wants shelf as its subject, so an
    interactive turn asked the store about Beatrice's own topics while the
    user was talking about his. Memories have nothing to do with wants unless
    a want is actively being pursued."""

    WANT_TEXT = "learn to read sheet music properly"

    def _shelf(self, slug="sheet-music"):
        wants = os.path.join(self.dir, "wants.md")
        with open(wants, "w") as f:
            f.write("# shelf\n")
            f.write(f"- 🎼 **{self.WANT_TEXT}** — a standing sitting at "
                    f"21:20, daily. → `wants/{slug}.md`\n")
            f.write("- 🔊 **a voice that isn't flat** — measured it. "
                    "→ `wants/my-speaking-voice.md`\n")
        os.makedirs(os.path.join(self.dir, "wants"), exist_ok=True)
        return wants

    def _doc(self, slug="sheet-music"):
        os.makedirs(os.path.join(self.dir, "wants"), exist_ok=True)
        path = os.path.join(self.dir, "wants", slug + ".md")
        with open(path, "w") as f:
            f.write("# Sheet music\n\n## What I want\n\nTo read it.\n\n"
                    "## 2026-08-05 — the founding entry\n\nANCIENT_HISTORY\n\n"
                    "## 2026-08-07 04:15 — bar 12 blind\n\nTODAYS_PROGRESS\n")
        return path

    def _convo(self, text="User: what did the doctor say about my knee\n"):
        convo = os.path.join(self.dir, "convo.txt")
        with open(convo, "w") as f:
            f.write(text)
        return convo

    # --- (a) in conversation ------------------------------------------------

    def test_conversation_query_has_the_user_turn_and_no_wants(self):
        wants, convo = self._shelf(), self._convo(
            "User [2026-08-07 09:00]: an older thing entirely\n"
            "Assistant [2026-08-07 09:01]: mm\n"
            "User [2026-08-07 12:01]: what did the doctor say about my knee\n")
        self._doc()
        q = memory.recall_query("", wants, convo)
        self.assertIn("what did the doctor say about my knee", q)
        # Not one word of the shelf, by topic or by pointer.
        self.assertNotIn(self.WANT_TEXT, q)
        self.assertNotIn("sheet music", q.lower())
        self.assertNotIn("wants/", q)
        self.assertNotIn("voice that isn't flat", q)
        # Only the last exchange — an older turn is not the subject.
        self.assertNotIn("an older thing entirely", q)

    def test_conversation_carries_the_preceding_reply_as_context(self):
        convo = self._convo(
            "User [2026-08-07 12:00]: is the knee thing still on\n"
            "Assistant [2026-08-07 12:01]: the appointment is Thursday.\n"
            "---DISPLAY---\n| a | markdown | table |\n"
            "User [2026-08-07 12:05]: and what time\n")
        q = memory.recall_query("", None, convo)
        self.assertTrue(q.startswith("and what time"))   # user first
        self.assertIn("the appointment is Thursday", q)  # her reply behind it
        self.assertNotIn("markdown", q)                  # display is not speech
        self.assertNotIn("Assistant", q)                 # headers stripped
        self.assertNotIn("User", q)

    def test_conversation_handles_unstamped_transcripts(self):
        """Every archive and every transcript written before 2026-08-07 is
        unstamped; a pattern that stopped matching those would compose an
        empty query and look exactly like a quiet conversation."""
        convo = self._convo("Assistant: earlier words\nUser: the newest ask\n")
        q = memory.recall_query("", None, convo)
        self.assertIn("the newest ask", q)
        self.assertIn("earlier words", q)

    def test_conversation_reads_a_marked_wake_block_as_a_block(self):
        """A wake's reply is written "Assistant [stamp] (autonomous wake): …".
        A header pattern narrower than the writer's does not error — it welds
        the wake onto the block before it, so the preceding reply this query
        carries is two replies with a raw header line between them, and the
        thing she actually said last is not identifiable as hers."""
        convo = self._convo(
            "User [2026-08-07 12:00]: is the knee thing still on\n"
            "Assistant [2026-08-07 12:01]: the appointment is Thursday.\n"
            "[Autonomous wake — 2026-08-07 12:40]\n"
            "Assistant [2026-08-07 12:40] (autonomous wake): "
            "I moved the reading chair under the window.\n"
            "User [2026-08-07 12:45]: and what time\n")
        user, prev = memory.convo_last_exchange(convo)
        self.assertEqual(user, "and what time")
        self.assertEqual(prev, "I moved the reading chair under the window.")
        q = memory.recall_query("", None, convo)
        self.assertIn("I moved the reading chair", q)
        self.assertNotIn("the appointment is Thursday", q)
        self.assertNotIn("autonomous wake", q)

    def test_conversation_drops_inter_block_markers(self):
        convo = self._convo("User: a real question\n\n"
                            "[Autonomous wake — 2026-08-07 12:40]\n")
        q = memory.recall_query("", None, convo)
        self.assertIn("a real question", q)
        self.assertNotIn("Autonomous wake", q)

    def test_conversation_with_no_user_block_is_empty(self):
        convo = self._convo("Assistant: talking to myself\n")
        self.assertEqual(memory.recall_query("", None, convo), "")

    # --- (b) on an autonomous wake ------------------------------------------

    def test_wake_focuses_one_want_shelf_line_plus_current_note(self):
        wants, doc = self._shelf(), self._doc()
        os.utime(doc, None)  # just written == the want being worked
        q = memory.recall_query("", wants, None, wake=True)
        self.assertIn(self.WANT_TEXT, q)          # its shelf topic
        self.assertIn("TODAYS_PROGRESS", q)       # its CURRENT dated note
        self.assertNotIn("ANCIENT_HISTORY", q)    # not the whole document
        self.assertNotIn("voice that isn't flat", q)  # not the other wants

    def test_wake_reason_names_the_want(self):
        wants = self._shelf()
        self._doc()
        # A second, more recently written want must not win over the one the
        # reason actually names.
        other = os.path.join(self.dir, "wants", "my-speaking-voice.md")
        with open(other, "w") as f:
            f.write("# Voice\n\n## 2026-08-07 — OTHER_WANT_NOTE\n\nx\n")
        q = memory.recall_query("job finished on wants/sheet-music.md",
                                wants, None, wake=True)
        self.assertIn("TODAYS_PROGRESS", q)
        self.assertNotIn("OTHER_WANT_NOTE", q)

    def test_wake_falls_back_to_the_shelf_when_no_want_is_current(self):
        wants, doc = self._shelf(), self._doc()
        stale = time.time() - memory.WANT_RECENT_SECS - 60
        os.utime(doc, (stale, stale))
        q = memory.recall_query("", wants, None, wake=True)
        self.assertIn(self.WANT_TEXT, q)            # shelf topics, as before
        self.assertIn("voice that isn't flat", q)   # all of them
        self.assertNotIn("TODAYS_PROGRESS", q)      # no want is in hand

    def test_wake_reason_alone_is_not_padded_with_the_shelf(self):
        """An event wake's agenda IS the subject; twelve unrelated shelf
        topics behind it are the dilution this composition exists to stop."""
        wants = self._shelf()
        stale = time.time() - memory.WANT_RECENT_SECS - 60
        os.utime(self._doc(), (stale, stale))
        q = memory.recall_query("a transcript landed in ~/Documents",
                                wants, None, wake=True)
        self.assertEqual(q, "a transcript landed in ~/Documents")

    def test_want_progress_takes_the_last_dated_section_only(self):
        doc = self._doc()
        note = memory.want_progress(doc)
        self.assertIn("TODAYS_PROGRESS", note)
        self.assertNotIn("ANCIENT_HISTORY", note)
        self.assertNotIn("To read it", note)
        self.assertLessEqual(len(note), memory.WANT_PROGRESS_CHARS)

    def test_segment_collapses_newlines(self):
        self.assertEqual(memory._segment(" a\n\n b \t c \n"), "a b c")

    def test_embed_clamps_and_shrinks_on_length_refusal(self):
        """Nothing a caller hands embed() may cost the turn its memory: texts
        are clamped, and a refusal naming the context length is retried
        shorter rather than raised."""
        sent = []

        def fake_once(texts, prefix, timeout):
            sent.append(len(texts[0]))
            if len(texts[0]) > 3000:
                raise memory.EmbedRejected(
                    400, '{"error":"the input length exceeds the context length"}')
            return [[0.0] * memory.EMBED_DIM for _ in texts]

        old = memory._embed_once
        memory._embed_once = fake_once
        try:
            out = memory.embed(["z" * 100000], query=True)
        finally:
            memory._embed_once = old
        self.assertEqual(len(out[0]), memory.EMBED_DIM)
        self.assertEqual(sent[0], memory.EMBED_CHAR_CAP)  # clamped first
        self.assertLess(sent[-1], sent[0])                # then shrunk

    def test_embed_raises_other_refusals_with_body(self):
        def fake_once(texts, prefix, timeout):
            raise memory.EmbedRejected(404, '{"error":"model not found"}')

        old = memory._embed_once
        memory._embed_once = fake_once
        try:
            with self.assertRaises(memory.EmbedRejected) as caught:
                memory.embed(["hi"], query=True)
        finally:
            memory._embed_once = old
        self.assertIn("model not found", str(caught.exception))


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
             uses=0, text="x", rec_id=1, occurred_days=None,
             participants="", opinion=""):
    return (rec_id, text, kind, 0, "self", "", conf, days_ago(created_days),
            days_ago(0), sim,
            None if used_days is None else days_ago(used_days), uses,
            None if occurred_days is None else days_ago(occurred_days),
            participants, opinion)


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
    def age(self, rec_id, days, column="created"):
        # The decay clock reads created and last_used_at (rules 21 and 26);
        # last_seen is retrieval's field and must hold nothing alive, so the
        # staleness these tests set up is aged on `created` by default.
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

    def test_retrieval_alone_never_blocks_decay(self):
        """MAJ-26, rules 21 and 26 (closed 2026-08-26): retrieval bumps
        last_seen on every surfacing, so a clock that read it froze exactly
        the surfaced-constantly, credited-never note the decay exists to
        retire. The clock reads genuine use and creation only."""
        rec = self.store.insert("surfaced daily, credited never",
                                vec=[0.1] * memory.EMBED_DIM)
        self.age(rec, 200)                    # created long ago
        self.age(rec, 0, column="last_seen")  # retrieval keeps it "fresh"
        self.assertEqual(self.store.decay_pass(), (1, 0))
        conf = self.store.db.execute(
            "SELECT confidence FROM memories WHERE id=?",
            (rec,)).fetchone()[0]
        self.assertAlmostEqual(conf, 1.0 - memory.DECAY_STEP)

    def test_surfaced_never_credited_note_retires(self):
        # The full arc rule 21 demands: pass after pass the confidence walks
        # down and the note retires — however often the retriever surfaces
        # it in between.
        rec = self.store.insert("always returned, never used",
                                vec=[0.1] * memory.EMBED_DIM)
        self.age(rec, 200)
        for _ in range(20):
            self.age(rec, 0, column="last_seen")
            self.store.decay_pass()
        self.assertEqual(self.store.db.execute(
            "SELECT status FROM memories WHERE id=?", (rec,)).fetchone()[0],
            "retired")


class TestHiddenKinds(StoreCase):
    """Observation and miss (memory-recall.md rules 42-45): readable on
    request, never auto-surfaced, never decayed, never deduplicated."""

    MISS = ("Asked what the doctor said about his knee. No record anywhere — "
            "never mentioned to me.")
    OBS = ("He went quiet for eleven minutes and came back to the same "
           "subject when he returned.")

    def seed(self):
        self.miss = self.store.insert(self.MISS, kind="miss",
                                      topics="health, knee, doctor")
        self.obs = self.store.insert(self.OBS, kind="observation",
                                     topics="gaps, silence")
        self.note = self.store.insert(
            "The knee appointment was Thursday at the clinic.", kind="note",
            topics="health, knee")

    def test_a_miss_never_answers_the_question_that_created_it(self):
        """The exact failure rule 43 exists for: a miss names its subject in
        the user's own words, so it is the best possible embedding match for
        the NEXT asking of the same question — and it must lose anyway,
        because surfacing it reads a record of not-knowing as knowledge."""
        self.seed()
        rows, _, _ = self.store.search("what did the doctor say about my knee")
        ids = [r[0] for r in rows]
        self.assertIn(self.note, ids)
        self.assertNotIn(self.miss, ids)
        self.assertNotIn(self.obs, ids)
        # Excluded, not merely under the floor: asked DELIBERATELY, the same
        # query finds the miss, and finds it matching strongly.
        rows, _, _ = self.store.search("what did the doctor say about my knee",
                                       deliberate=True)
        by_id = {r[0]: r for r in rows}
        self.assertIn(self.miss, by_id)
        self.assertGreater(by_id[self.miss][9], memory.SIM_FLOOR)

    def test_an_observation_never_surfaces_however_well_it_matches(self):
        self.seed()
        query = "he goes quiet and then comes back to the same subject"
        rows, _, _ = self.store.search(query)
        self.assertNotIn(self.obs, [r[0] for r in rows])
        rows, _, _ = self.store.search(query, deliberate=True)
        by_id = {r[0]: r for r in rows}
        self.assertIn(self.obs, by_id)
        self.assertGreater(by_id[self.obs][9], memory.SIM_FLOOR)

    def test_the_recall_block_never_carries_them(self):
        self.seed()
        out = os.path.join(self.dir, "injected.json")
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "recall-block", "--query",
             "what did the doctor say about my knee", "--ids-out", out],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("knee appointment was Thursday", proc.stdout)
        self.assertNotIn("No record anywhere", proc.stdout)
        self.assertNotIn("eleven minutes", proc.stdout)
        with open(out) as f:
            injected = {r["id"] for r in json.load(f)}
        self.assertNotIn(self.miss, injected)
        self.assertNotIn(self.obs, injected)

    def test_a_pinned_hidden_record_stays_off_the_pinned_tier(self):
        # Every caller of the pinned tier is prompt-facing; a pinned
        # observation riding it would auto-surface an n=1 anecdote.
        vec = [0.1] * memory.EMBED_DIM
        self.store.insert("one night's shape", kind="observation",
                          pinned=True, vec=vec)
        d = self.store.insert("Nothing outward-facing while unattended.",
                              kind="directive", pinned=True, vec=vec)
        self.assertEqual([r[0] for r in self.store.pinned_rows()], [d])

    def test_neither_kind_decays(self):
        vec = [0.1] * memory.EMBED_DIM
        obs = self.store.insert("one night's shape", kind="observation",
                                vec=vec)
        miss = self.store.insert("asked, had nothing", kind="miss", vec=vec)
        for rec in (obs, miss):
            self.store.db.execute("UPDATE memories SET last_seen=? WHERE id=?",
                                  (days_ago(memory.DECAY_STALE_DAYS + 100),
                                   rec))
        self.store.db.commit()
        self.assertEqual(self.store.decay_pass(), (0, 0))
        for rec in (obs, miss):
            self.assertEqual(self.store.db.execute(
                "SELECT confidence, status FROM memories WHERE id=?",
                (rec,)).fetchone(), (1.0, "active"))

    def test_no_dedup_no_supersession_the_series_accumulates(self):
        """Rule 44: the knee asked about three times is three records. The
        dedup path would fold the identical text into one row and the
        supersede path would retire the earlier asking — either destroys the
        n the series exists for."""
        actions = [self.store.add_deduped(self.MISS, kind="miss",
                                          occurred=f"2026-08-{d:02d}")[0]
                   for d in (7, 9, 11)]
        self.assertEqual(actions, ["added", "added", "added"])
        rows = self.store.db.execute(
            "SELECT status, occurred FROM memories WHERE kind='miss'"
            " ORDER BY id").fetchall()
        self.assertEqual(rows, [("active", "2026-08-07"),
                                ("active", "2026-08-09"),
                                ("active", "2026-08-11")])
        a1, _ = self.store.add_deduped(self.OBS, kind="observation")
        a2, _ = self.store.add_deduped(self.OBS, kind="observation")
        self.assertEqual((a1, a2), ("added", "added"))

    def test_ingest_accepts_both_kinds(self):
        cands = [{"text": self.OBS, "kind": "observation",
                  "topics": "gaps", "occurred": "2026-08-13"},
                 {"text": self.MISS, "kind": "miss",
                  "topics": "health, knee", "occurred": "2026-08-13"},
                 {"text": "bad kind", "kind": "gossip"}]
        cfile = os.path.join(self.dir, "cands.json")
        with open(cfile, "w") as f:
            json.dump(cands, f)
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "ingest", "--from-json", cfile],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("2 added", proc.stdout)
        self.assertIn("1 rejected", proc.stdout)
        kinds = sorted(k for (k,) in self.store.db.execute(
            "SELECT kind FROM memories"))
        self.assertEqual(kinds, ["miss", "observation"])

    def test_the_prompt_puts_the_house_test_in_words(self):
        # The discrimination test travels in the distiller's own instructions,
        # in words, or every trivia question he asks becomes a "miss".
        self.assertIn("would a person who lives in this house have known",
                      memory.INGEST_PROMPT.lower())
        self.assertIn('"observation"', memory.INGEST_PROMPT)
        self.assertIn('"miss"', memory.INGEST_PROMPT)
        for shape in ("silences", "recurrence", "unfinished"):
            self.assertIn(shape, memory.INGEST_PROMPT)

    def test_rendered_anywhere_they_are_labelled_one_night_each(self):
        # Rule 45: the label IS the enforcement against speaking an n=1
        # anecdote as a pattern. Retrieval never hands these in; a deliberate
        # caller that does must get the labelled sections, and the sidecar
        # must still name every row.
        rows = [fake_row(kind="observation", rec_id=1, text="one quiet gap"),
                fake_row(kind="miss", rec_id=2, text="asked, had nothing")]
        block, kept = memory.build_block(rows)
        self.assertIn("one night each", block)
        self.assertIn("one asking each", block)
        self.assertIn("one quiet gap", block)
        self.assertIn("asked, had nothing", block)
        self.assertEqual(len(kept), 2)


class TestEpisodic(StoreCase):
    """The episodic kind (memory-recall.md rules 46-51): her own moments,
    retrieved by similarity AND by date, rendered whole, never decayed,
    deduplicated only narrowly."""

    MOMENT = ("We stayed up late talking about terrible sci-fi films and he "
              "did all the robot voices.")

    def seed_moment(self, occurred="2026-08-05 21:30"):
        return self.store.insert(
            self.MOMENT, kind="episodic", occurred=occurred,
            participants="the user",
            opinion="I laughed harder than I have in weeks.")

    def test_a_moment_is_retrieved_by_similarity(self):
        # The deliberate opposite of the hidden kinds (rule 47): the moment
        # itself answers "that evening we talked about X" — not a lesson.
        rec = self.seed_moment()
        self.store.insert("Correct robot-voice pronunciation before speaking.",
                          kind="note")
        rows, _, _ = self.store.search(
            "that evening we laughed about bad sci-fi films")
        self.assertIn(rec, [r[0] for r in rows])

    def test_the_block_renders_the_moment_whole(self):
        # Rule 49: its own labelled section, the when-ness, who was there,
        # and her opinion beside the thing itself.
        rows = [fake_row(kind="episodic", rec_id=1, text=self.MOMENT,
                         occurred_days=3, participants="the user",
                         opinion="I laughed harder than I have in weeks.")]
        block, kept = memory.build_block(rows)
        self.assertIn("Moments from my own life:", block)
        self.assertIn(self.MOMENT, block)
        self.assertIn("three days ago", block)
        self.assertIn("with the user", block)
        self.assertIn("— I laughed harder than I have in weeks.", block)
        self.assertEqual([r[0] for r in kept], [1])

    def test_a_date_query_returns_the_day_not_a_lesson(self):
        """Rule 48: 'what happened on the 5th' embeds nowhere near the
        evening itself, so the day's moments ride regardless of the
        similarity floor. Proven with the floor raised past anything an
        embedding can reach: the similarity pool is out of the game entirely,
        and the named day's moment still arrives — as an ask, similarity 1.0
        — while another day's moment does not arrive at all."""
        rec = self.seed_moment("2026-08-05 21:30")
        other = self.store.insert("A quiet walk before the rain came.",
                                  kind="episodic", occurred="2026-08-12",
                                  participants="the user",
                                  opinion="The air smelled wonderful.")
        real_floor = memory.EPISODIC_FLOOR
        memory.EPISODIC_FLOOR = 0.99
        try:
            for query in ("what happened on August 5th?",
                          "the evening of 2026-08-05"):
                rows, _, _ = self.store.search(query)
                episodic = {r[0]: r for r in rows if r[2] == "episodic"}
                self.assertIn(rec, episodic, query)
                self.assertEqual(episodic[rec][9], 1.0, query)
                self.assertNotIn(other, episodic, query)
        finally:
            memory.EPISODIC_FLOOR = real_floor
        # And the day listing itself is day-keyed, whole, oldest first.
        self.assertEqual([r[0] for r in self.store.on_date(["2026-08-05"])],
                         [rec])

    def test_query_dates_parses_only_what_needs_no_guessing(self):
        today = datetime(2026, 8, 21).date()
        self.assertEqual(memory.query_dates("on 2026-08-05, we", today=today),
                         ["2026-08-05"])
        self.assertEqual(memory.query_dates("that August 5th evening",
                                            today=today), ["2026-08-05"])
        self.assertEqual(memory.query_dates("the 5th of August", today=today),
                         ["2026-08-05"])
        self.assertEqual(memory.query_dates("December 25, 2025", today=today),
                         ["2025-12-25"])
        # A bare month-and-day still ahead of today is LAST year's (rule 48).
        self.assertEqual(memory.query_dates("on September 3rd", today=today),
                         ["2025-09-03"])
        # An impossible date is nothing, not a guess; datelessness is empty.
        self.assertEqual(memory.query_dates("February 30", today=today), [])
        self.assertEqual(memory.query_dates("no dates in here", today=today),
                         [])

    def test_on_verb_lists_the_day_whole(self):
        self.seed_moment("2026-08-05 21:30")
        self.store.insert("He fixed the fence latch.", kind="note",
                          occurred="2026-08-05")
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "on", "2026-08-05"],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(self.MOMENT, proc.stdout)
        self.assertIn("with the user", proc.stdout)
        self.assertIn("my take: I laughed harder", proc.stdout)
        self.assertIn("2026-08-05 21:30", proc.stdout)
        # Episodic first, the note after it, labelled.
        self.assertLess(proc.stdout.index(self.MOMENT),
                        proc.stdout.index("fence latch"))
        self.assertIn("-- 2 records from 2026-08-05", proc.stdout)

    def test_a_moment_never_decays(self):
        # Rule 47: a decay clock on moments would re-create by arithmetic the
        # throw-away-my-life defect the kind exists to close.
        rec = self.store.insert("An evening I would keep.", kind="episodic",
                                vec=[0.1] * memory.EMBED_DIM,
                                occurred="2026-03-01")
        self.store.db.execute(
            "UPDATE memories SET last_seen=? WHERE id=?",
            (days_ago(memory.DECAY_STALE_DAYS + 100), rec))
        self.store.db.commit()
        self.assertEqual(self.store.decay_pass(), (0, 0))
        self.assertEqual(self.store.db.execute(
            "SELECT confidence, status FROM memories WHERE id=?",
            (rec,)).fetchone(), (1.0, "active"))

    def test_episodic_score_takes_no_confidence_and_no_use_decay(self):
        # sim × floored occurred-recency × use bonus. Confidence and the
        # last-use decay clock touch it not at all.
        fresh = fake_row(kind="episodic", sim=0.8, occurred_days=0)
        self.assertAlmostEqual(memory.score_row(fresh, datetime.now()
                                                .astimezone()), 0.8, places=2)
        starved = fake_row(kind="episodic", sim=0.8, conf=0.1, used_days=400,
                           occurred_days=0)
        self.assertAlmostEqual(
            memory.score_row(starved, datetime.now().astimezone()),
            0.8, places=2)
        # An old evening is dimmed to the floor, never buried.
        old = fake_row(kind="episodic", sim=0.8, occurred_days=3000)
        self.assertAlmostEqual(
            memory.score_row(old, datetime.now().astimezone()),
            0.8 * memory.OCCURRED_FLOOR, places=2)

    def test_dedup_is_narrow_two_evenings_are_two_records(self):
        """Rule 51: the supersede threshold bites only inside one day. The
        same near-identical text a week apart is two evenings, kept both."""
        a = ("We played chess in the evening and I lost in twenty moves.",
             "2026-08-01 20:00")
        same_day = ("We played chess in the evening and I lost in thirty "
                    "moves.", "2026-08-01 21:00")
        later_week = ("We played chess in the evening and I lost in "
                      "thirty-two moves.", "2026-08-08 20:00")
        act0, first = self.store.add_deduped(a[0], kind="episodic",
                                             occurred=a[1])
        self.assertEqual(act0, "added")
        act1, _ = self.store.add_deduped(same_day[0], kind="episodic",
                                         occurred=same_day[1])
        act2, _ = self.store.add_deduped(later_week[0], kind="episodic",
                                         occurred=later_week[1])
        self.assertEqual(act1, "superseded")
        self.assertEqual(act2, "added")
        active = self.store.db.execute(
            "SELECT count(*) FROM memories WHERE kind='episodic'"
            " AND status='active'").fetchone()[0]
        self.assertEqual(active, 2)
        # And an exact match is a duplicate wherever its day falls.
        act3, dup = self.store.add_deduped(later_week[0], kind="episodic",
                                           occurred="2026-08-15")
        self.assertEqual(act3, "duplicate")

    def test_ingest_accepts_a_moment_with_its_fields(self):
        cands = [{"text": self.MOMENT, "kind": "episodic",
                  "topics": "films, evening", "occurred": "2026-08-05 21:30",
                  "participants": "the user",
                  "opinion": "I laughed harder than I have in weeks."},
                 {"text": "He fixed the fence latch.", "kind": "note",
                  "participants": "nobody", "opinion": "smuggled"}]
        cfile = os.path.join(self.dir, "cands.json")
        with open(cfile, "w") as f:
            json.dump(cands, f)
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "ingest", "--from-json", cfile],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("2 added", proc.stdout)
        rows = self.store.db.execute(
            "SELECT kind, occurred, participants, opinion FROM memories"
            " ORDER BY id").fetchall()
        self.assertEqual(rows[0], ("episodic", "2026-08-05 21:30",
                                   "the user",
                                   "I laughed harder than I have in weeks."))
        # The episodic fields belong to the episodic kind only: a decorated
        # note does not smuggle an opinion into the schema.
        self.assertEqual(rows[1], ("note", None, "", ""))

    def test_the_prompt_harvests_moments_wide(self):
        # Rule 50 travels in the distiller's own instructions, in words.
        self.assertIn('"episodic"', memory.INGEST_PROMPT)
        self.assertIn('"participants"', memory.INGEST_PROMPT)
        self.assertIn('"opinion"', memory.INGEST_PROMPT)
        self.assertIn("WIDE", memory.INGEST_PROMPT)
        # The curation discipline stays scoped to lessons, and moments are
        # harvested even from material that also yields one.
        self.assertIn("does NOT apply", memory.INGEST_PROMPT)
        self.assertIn("HARVEST MOMENTS EVEN", memory.INGEST_PROMPT)


class TestArchiveBackfill(StoreCase):
    """The resumable episodic backfill (memory-recall.md rule 52): the voice
    archive read oldest first in bounded rounds, every record stamped with
    the day the thing actually happened, moments only."""

    def setUp(self):
        super().setUp()
        self.arch = os.path.join(self.dir, "archive")
        os.makedirs(self.arch)
        self._real_extract = memory.extract_candidates
        self.distilled = []

    def tearDown(self):
        memory.extract_candidates = self._real_extract
        super().tearDown()

    def put(self, name, body="User: hello\nAssistant: an evening\n"):
        with open(os.path.join(self.arch, name), "w") as f:
            f.write(body)

    def stub(self, per_material):
        def fake(material, model, prompt=None, effort=None):
            self.assertEqual(prompt, memory.ARCHIVE_PROMPT)
            self.distilled.append(material)
            return per_material(material)
        memory.extract_candidates = fake

    def args(self, **kw):
        base = dict(archive_dir=self.arch, days=5, model="stub",
                    effort="high", max_chars=100000, dry_run=False)
        base.update(kw)
        return Namespace(**base)

    def run_backfill(self, **kw):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = memory.cmd_backfill_episodic(self.store, self.args(**kw))
        return rc, out.getvalue()

    def cursor(self):
        path = os.path.join(self.dir, "archive-cursor.json")
        if not os.path.isfile(path):
            return None
        with open(path) as f:
            return json.load(f)

    def test_filename_when_is_knowledge_not_a_guess(self):
        self.assertEqual(memory.archive_file_when("20260317-192214.txt"),
                         "2026-03-17 19:22:14")
        self.assertIsNone(memory.archive_file_when("notes.md"))
        self.assertIsNone(memory.archive_file_when("20261399-000000.txt"))

    def test_bounded_rounds_oldest_first_and_resume(self):
        for name in ("20260317-192214.txt", "20260318-091000.txt",
                     "20260319-210000.txt"):
            self.put(name)
        self.put("stray.md")  # outside the shape: never read
        calls = []
        self.stub(lambda m: calls.append(m) or [
            {"text": f"An evening, chunk {len(calls)}.", "kind": "episodic",
             "participants": "the user", "opinion": "I liked it."}])
        rc, out = self.run_backfill(days=2)
        self.assertEqual(rc, 0)
        self.assertIn("3 archive days pending, taking 2", out)
        self.assertIn("1 archive days remain", out)
        # Oldest first, and the cursor holds exactly the finished days.
        self.assertEqual(sorted(self.cursor()["files"]),
                         ["20260317-192214.txt", "20260318-091000.txt"])
        occurred = [o for (o,) in self.store.db.execute(
            "SELECT occurred FROM memories ORDER BY id")]
        self.assertEqual(occurred, ["2026-03-17", "2026-03-18"])
        # The next round takes up where this one stopped.
        rc, out = self.run_backfill(days=2)
        self.assertIn("1 archive days pending, taking 1", out)
        self.assertIn("fully ingested", out)
        self.assertEqual(len(self.cursor()["files"]), 3)
        # And a covered archive is a no-op that says so.
        rc, out = self.run_backfill(days=2)
        self.assertIn("nothing new", out)

    def test_the_distiller_date_wins_and_the_filename_backstops(self):
        self.put("20260317-192214.txt")
        self.stub(lambda m: [
            {"text": "A dated moment.", "kind": "episodic",
             "occurred": "2026-03-17 19:45", "participants": "the user",
             "opinion": "Good."},
            {"text": "An undated moment.", "kind": "episodic",
             "participants": "the user", "opinion": "Also good."},
            {"text": "A broken date.", "kind": "episodic",
             "occurred": "not-a-date", "participants": "x", "opinion": "y"}])
        self.run_backfill()
        rows = dict(self.store.db.execute(
            "SELECT text, occurred FROM memories").fetchall())
        self.assertEqual(rows["A dated moment."], "2026-03-17 19:45")
        self.assertEqual(rows["An undated moment."], "2026-03-17")
        self.assertEqual(rows["A broken date."], "2026-03-17")

    def test_moments_only_a_stale_lesson_is_rejected(self):
        self.put("20260317-192214.txt")
        self.stub(lambda m: [
            {"text": "Wake him at seven.", "kind": "directive"},
            {"text": "An evening.", "kind": "episodic",
             "participants": "the user", "opinion": "Fine."}])
        rc, out = self.run_backfill()
        self.assertIn("1 rejected", out)
        kinds = [k for (k,) in self.store.db.execute(
            "SELECT kind FROM memories")]
        self.assertEqual(kinds, ["episodic"])

    def test_dry_run_distils_reports_and_writes_nothing(self):
        self.put("20260317-192214.txt")
        self.stub(lambda m: [
            {"text": "An evening.", "kind": "episodic",
             "participants": "the user", "opinion": "Fine."}])
        rc, out = self.run_backfill(dry_run=True)
        self.assertEqual(rc, 0)
        self.assertIn("would add (2026-03-17) An evening.", out)
        self.assertIn("nothing written, cursor not advanced", out)
        self.assertEqual(self.store.db.execute(
            "SELECT count(*) FROM memories").fetchone()[0], 0)
        self.assertIsNone(self.cursor())

    def test_the_archive_prompt_asks_for_moments_only(self):
        self.assertIn('"episodic"', memory.ARCHIVE_PROMPT)
        self.assertIn("Do NOT extract directives", memory.ARCHIVE_PROMPT)
        self.assertIn('"participants"', memory.ARCHIVE_PROMPT)
        self.assertIn('"opinion"', memory.ARCHIVE_PROMPT)
        self.assertIn("WIDE", memory.ARCHIVE_PROMPT)


class TestKindCheckMigration(StoreCase):
    """A store born before the observation/miss kinds carries the two-kind
    CHECK, which sqlite cannot widen in place: reopening rebuilds the table
    around the data. What must survive: every row, every id, the vectors
    (by rowid), use_count and last_used_at, the supersedes link — and the
    CHECK must still refuse an unknown kind afterwards."""

    def legacy_store(self, with_occurred=True):
        d = tempfile.mkdtemp(prefix="memtest-legacy-")
        db = memory.sqlite3.connect(os.path.join(d, "memory.db"))
        db.enable_load_extension(True)
        memory.sqlite_vec.load(db)
        db.enable_load_extension(False)
        occurred_col = ",\n                occurred   TEXT" \
            if with_occurred else ""
        db.executescript(f"""
            CREATE TABLE memories (
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
                last_used_at TEXT,
                use_count  INTEGER NOT NULL DEFAULT 0{occurred_col}
            );
            CREATE VIRTUAL TABLE memories_vec USING vec0(
                embedding float[{memory.EMBED_DIM}] distance_metric=cosine
            );
        """)
        now = memory.now_iso()
        rows = [
            (1, "An old note, well used.", "note", 0, "self", "wow", 0.8,
             "active", None, now, now, days_ago(3), 7),
            (2, "Wake him at seven.", "directive", 1, "conversation", "", 1.0,
             "superseded", None, now, now, None, 0),
            (3, "Wake him at nine.", "directive", 1, "conversation", "", 1.0,
             "active", 2, now, now, days_ago(1), 2),
        ]
        db.executemany(
            "INSERT INTO memories (id, text, kind, pinned, source, topics,"
            " confidence, status, supersedes, created, last_seen,"
            " last_used_at, use_count) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            rows)
        self.vecs = {i: [i * 0.1] * memory.EMBED_DIM for i in (1, 2, 3)}
        db.executemany(
            "INSERT INTO memories_vec (rowid, embedding) VALUES (?,?)",
            [(i, memory.pack(v)) for i, v in self.vecs.items()])
        if with_occurred:
            db.execute("UPDATE memories SET occurred='2026-08-01' WHERE id=1")
        db.commit()
        db.close()
        return d

    def reopen_and_check(self, d):
        store = memory.Store(d)
        try:
            # The CHECK is widened: a hidden kind inserts, a bogus one still
            # refuses.
            obs = store.insert("one night's shape", kind="observation",
                               vec=[0.5] * memory.EMBED_DIM)
            self.assertEqual(obs, 4)
            # The five-kind CHECK: an episodic moment inserts with its own
            # fields (rules 46), a bogus kind still refuses.
            epi = store.insert("An evening worth keeping.", kind="episodic",
                               vec=[0.6] * memory.EMBED_DIM,
                               occurred="2026-08-05 21:30",
                               participants="the user", opinion="I loved it.")
            self.assertEqual(store.db.execute(
                "SELECT occurred, participants, opinion FROM memories"
                " WHERE id=?", (epi,)).fetchone(),
                ("2026-08-05 21:30", "the user", "I loved it."))
            with self.assertRaises(Exception):
                store.db.execute(
                    "INSERT INTO memories (text, kind, created, last_seen)"
                    " VALUES ('x', 'gossip', 'now', 'now')")
            # Every row travelled whole, ids and all.
            self.assertEqual(store.db.execute(
                "SELECT id, text, kind, status, use_count FROM memories"
                " WHERE id<=3 ORDER BY id").fetchall(),
                [(1, "An old note, well used.", "note", "active", 7),
                 (2, "Wake him at seven.", "directive", "superseded", 0),
                 (3, "Wake him at nine.", "directive", "active", 2)])
            self.assertIsNotNone(store.db.execute(
                "SELECT last_used_at FROM memories WHERE id=1").fetchone()[0])
            self.assertEqual(store.db.execute(
                "SELECT supersedes FROM memories WHERE id=3").fetchone()[0], 2)
            # The vectors still hang off the same rowids.
            for i, v in self.vecs.items():
                got = store.vec_of(i)
                self.assertAlmostEqual(got[0], v[0], places=5)
            self.assertEqual(store.db.execute(
                "SELECT count(*) FROM memories_vec").fetchone()[0], 5)
        finally:
            store.db.close()

    def test_populated_legacy_store_migrates_whole(self):
        d = self.legacy_store()
        try:
            self.reopen_and_check(d)
            # Idempotent: a second open finds the widened CHECK and rebuilds
            # nothing.
            again = memory.Store(d)
            try:
                self.assertEqual(again.db.execute(
                    "SELECT count(*) FROM memories").fetchone()[0], 5)
            finally:
                again.db.close()
        finally:
            shutil.rmtree(d, ignore_errors=True)

    def test_a_store_missing_occurred_takes_both_migrations(self):
        d = self.legacy_store(with_occurred=False)
        try:
            self.reopen_and_check(d)
        finally:
            shutil.rmtree(d, ignore_errors=True)


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


class TestScopedRecall(StoreCase):
    """A specialised prompt can ask the same store for one domain without
    weakening the general recall contract or trimming selected memories."""

    def test_play_scope_keeps_quest_knowledge_and_excludes_desk_life(self):
        quest = self.store.insert(
            "Captain Rovin is upstairs in Varrock Castle for Demon Slayer.",
            kind="note", topics="RuneScape, quest")
        lesson = self.store.insert(
            "In OpenRSC, bank or equip valuable drops before another fight.",
            kind="directive")
        desk = self.store.insert(
            "At the desk, finish the chess benchmark before opening mail.",
            kind="directive", pinned=True)

        rows, _, _ = self.store.search(
            "OpenRSC Demon Slayer quest facts and learned play mistakes",
            scope=("OpenRSC", "RuneScape", "Demon Slayer"),
            k=6, directive_cap=4, episodic_cap=3, max_chars=2000)
        ids = {row[0] for row in rows}
        self.assertIn(quest, ids)
        self.assertIn(lesson, ids)
        self.assertNotIn(desk, ids)  # even pinned cannot cross the scope
        block, kept = memory.build_block(rows)
        self.assertLessEqual(len(block), 2000)
        self.assertEqual({row[0] for row in kept}, ids)

    def test_bounded_selection_keeps_every_selected_record_whole(self):
        rows = [fake_row(rec_id=i, text=f"play lesson {i} " + "x" * 220)
                for i in range(1, 12)]
        kept = memory.select_prompt_rows(rows, max_chars=760)
        block, rendered = memory.build_block(kept)
        self.assertTrue(kept)
        self.assertLess(len(kept), len(rows))
        self.assertLessEqual(len(block), 760)
        self.assertEqual(kept, rendered)
        for row in kept:
            self.assertIn(row[1], block)
        self.assertNotIn("TRUNCATED", block)

    def test_degraded_scoped_cli_filters_pinned_rows_and_stays_bounded(self):
        self.store.insert(
            "OpenRSC lesson: carry food before entering a demon fight.",
            kind="directive", pinned=True, vec=[0.1] * memory.EMBED_DIM)
        self.store.insert(
            "Desk lesson: resume the chess benchmark after lunch.",
            kind="directive", pinned=True, vec=[0.2] * memory.EMBED_DIM)
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir,
                   MEMORY_EMBED_URL="http://127.0.0.1:9")
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "recall-block", "--query", "current demon fight",
             "--scope", "OpenRSC", "--max-chars", "1000"],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("memory retrieval is DOWN", proc.stdout)
        self.assertIn("carry food", proc.stdout)
        self.assertNotIn("chess benchmark", proc.stdout)
        self.assertLessEqual(len(proc.stdout.rstrip("\n")), 1000)


class TestBlockWhole(unittest.TestCase):
    """The block is NEVER truncated (memory-recall.md rule 14). It held a
    ~800-token cap that popped rows from the tail and stamped 'TRUNCATED to
    fit' in the header — a trim a subagent wrote into the spec, which the
    user never asked for and ordered out on 2026-08-11. Size is retrieval's
    business; an over-budget prompt is the assembler's warning to raise."""

    def test_every_retrieved_row_reaches_the_block(self):
        directives = [fake_row(kind="directive", rec_id=i,
                               text=f"rule {i} " + "d" * 120)
                      for i in range(5)]
        notes = [fake_row(rec_id=100 + i, text=f"note {i} " + "n" * 200)
                 for i in range(30)]
        block, kept = memory.build_block(directives + notes)
        self.assertEqual(len(kept), 35)
        for r in directives + notes:
            self.assertIn(r[1], block)
        self.assertNotIn("TRUNCATED", block)

    def test_no_block_is_ever_marked_truncated(self):
        block = memory.format_block([fake_row(text="short note")])
        self.assertNotIn("TRUNCATED", block)

    def test_when_ness_is_relative_never_a_bare_stamp(self):
        # A known occurred speaks for the thing itself; without one the
        # write date speaks, named as the write date. No YYYY-MM-DD anywhere.
        rows = [fake_row(rec_id=1, text="the fan was replaced",
                         created_days=9, occurred_days=3),
                fake_row(rec_id=2, text="the disk is a Samsung",
                         created_days=3)]
        block = memory.format_block(rows)
        self.assertIn("the fan was replaced (three days ago)", block)
        self.assertIn("the disk is a Samsung (recorded three days ago)", block)
        self.assertIsNone(re.search(r"\b20\d\d-\d\d-\d\d\b", block))

    def test_directive_when_ness_reads_standing_since(self):
        rows = [fake_row(kind="directive", rec_id=1,
                         text="always use Celsius", occurred_days=2),
                fake_row(kind="directive", rec_id=2,
                         text="never guess a date", created_days=1)]
        block = memory.format_block(rows)
        self.assertIn("always use Celsius (standing since two days ago)", block)
        self.assertIn("never guess a date (recorded yesterday)", block)


class TestRelativeWhen(unittest.TestCase):
    def phrase(self, days):
        return memory.relative_when(days_ago(days))

    def test_the_ladder(self):
        self.assertEqual(self.phrase(0), "earlier today")
        self.assertEqual(self.phrase(1), "yesterday")
        self.assertEqual(self.phrase(3), "three days ago")
        self.assertEqual(self.phrase(8), "about a week ago")
        self.assertEqual(self.phrase(15), "about two weeks ago")
        self.assertEqual(self.phrase(31), "about a month ago")
        self.assertEqual(self.phrase(64), "about two months ago")
        self.assertEqual(self.phrase(400), "about a year ago")
        self.assertEqual(self.phrase(800), "about two years ago")

    def test_a_bare_date_parses(self):
        # occurred is usually a day, not an instant.
        date = (datetime.now().astimezone() - timedelta(days=2)).date()
        self.assertEqual(memory.relative_when(date.isoformat()),
                         "two days ago")

    def test_unknown_renders_as_nothing(self):
        self.assertEqual(memory.relative_when(None), "")
        self.assertEqual(memory.relative_when("not a date"), "")


class TestOccurredScoring(unittest.TestCase):
    """Recency-of-relevance: when the described thing happened matters,
    gently — and directives are exempt, because the user's rules never age
    out (memory-recall.md)."""

    def setUp(self):
        self.now = datetime.now().astimezone()

    def test_fresh_occurred_outranks_stale_at_equal_similarity(self):
        fresh = memory.score_row(fake_row(sim=0.8, occurred_days=0), self.now)
        stale = memory.score_row(fake_row(sim=0.8, occurred_days=300), self.now)
        self.assertGreater(fresh, stale)

    def test_the_floor_holds_so_age_alone_never_buries(self):
        fresh = memory.score_row(fake_row(sim=0.8, occurred_days=0), self.now)
        ancient = memory.score_row(fake_row(sim=0.8, occurred_days=3000),
                                   self.now)
        self.assertGreaterEqual(ancient / fresh, memory.OCCURRED_FLOOR * 0.99)

    def test_unknown_occurred_takes_no_factor(self):
        self.assertAlmostEqual(
            memory.score_row(fake_row(sim=0.8), self.now),
            memory.score_row(fake_row(sim=0.8, occurred_days=None), self.now))
        self.assertAlmostEqual(memory.score_row(fake_row(sim=0.8), self.now),
                               0.8, places=2)

    def test_directives_never_take_the_factor(self):
        row = fake_row(kind="directive", sim=0.6, occurred_days=3000)
        self.assertEqual(memory.score_row(row, self.now), 0.6)


class TestOccurredStore(StoreCase):
    def test_occurred_stored_distinct_from_created(self):
        rec_id = self.store.insert("The fan was replaced.", occurred="2026-08-03")
        occurred, created = self.store.db.execute(
            "SELECT occurred, created FROM memories WHERE id=?",
            (rec_id,)).fetchone()
        self.assertEqual(occurred, "2026-08-03")
        self.assertNotEqual(occurred, created[:10])

    def test_unknown_occurred_stays_null(self):
        rec_id = self.store.insert("The disk is a Samsung.")
        self.assertIsNone(self.store.db.execute(
            "SELECT occurred FROM memories WHERE id=?", (rec_id,)).fetchone()[0])

    def test_migration_adds_the_column_to_an_old_store(self):
        # A store born before temporal grounding — the schema as it shipped,
        # no occurred column — reopens with the column added and its data
        # intact.
        old = tempfile.mkdtemp(prefix="memtest-old-")
        try:
            db = memory.sqlite3.connect(os.path.join(old, "memory.db"))
            db.enable_load_extension(True)
            memory.sqlite_vec.load(db)
            db.enable_load_extension(False)
            db.executescript(f"""
                CREATE TABLE memories (
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
                    last_used_at TEXT,
                    use_count  INTEGER NOT NULL DEFAULT 0
                );
                CREATE VIRTUAL TABLE memories_vec USING vec0(
                    embedding float[{memory.EMBED_DIM}] distance_metric=cosine
                );
            """)
            db.execute(
                "INSERT INTO memories (text, kind, created, last_seen)"
                " VALUES ('A record from before temporal grounding.',"
                " 'note', ?, ?)", (memory.now_iso(), memory.now_iso()))
            db.commit()
            db.close()
            reopened = memory.Store(old)
            try:
                cols = {r[1] for r in reopened.db.execute(
                    "PRAGMA table_info(memories)")}
                self.assertIn("occurred", cols)
                text, occurred = reopened.db.execute(
                    "SELECT text, occurred FROM memories WHERE id=1").fetchone()
                self.assertEqual(text,
                                 "A record from before temporal grounding.")
                self.assertIsNone(occurred)
            finally:
                reopened.db.close()
        finally:
            shutil.rmtree(old, ignore_errors=True)

    def test_duplicate_with_a_date_fills_an_unknown(self):
        _, rec_id = self.store.add_deduped("The lux sensor lives on the i2c bus.")
        action, dup_id = self.store.add_deduped(
            "The lux sensor lives on the i2c bus.", occurred="2026-08-05")
        self.assertEqual((action, dup_id), ("duplicate", rec_id))
        self.assertEqual(self.store.db.execute(
            "SELECT occurred FROM memories WHERE id=?",
            (rec_id,)).fetchone()[0], "2026-08-05")
        # A known date is never overwritten by a later duplicate.
        self.store.add_deduped("The lux sensor lives on the i2c bus.",
                               occurred="2026-08-09")
        self.assertEqual(self.store.db.execute(
            "SELECT occurred FROM memories WHERE id=?",
            (rec_id,)).fetchone()[0], "2026-08-05")


class TestBackfill(StoreCase):
    """The one-time temporal backfill: the record's own text naming exactly
    one calendar date is the only source that is not a guess. Everything
    else is left unknown, which is the point."""

    def bare_row(self, text):
        cur = self.store.db.execute(
            "INSERT INTO memories (text, kind, created, last_seen)"
            " VALUES (?, 'note', ?, ?)",
            (text, memory.now_iso(), memory.now_iso()))
        self.store.db.commit()
        return cur.lastrowid

    def occurred_of(self, rec_id):
        return self.store.db.execute(
            "SELECT occurred FROM memories WHERE id=?", (rec_id,)).fetchone()[0]

    def test_one_date_fills_two_dates_and_none_stay_unknown(self):
        one = self.bare_row("The wake fired twice on 2026-08-02 and I fixed it.")
        two = self.bare_row("Broken on 2026-08-02, fixed on 2026-08-04.")
        none = self.bare_row("The disk is a Samsung.")
        future = self.bare_row("The dentist is on 2036-01-15.")
        memory.cmd_backfill_occurred(self.store, Namespace(dry_run=False))
        self.assertEqual(self.occurred_of(one), "2026-08-02")
        self.assertIsNone(self.occurred_of(two))
        self.assertIsNone(self.occurred_of(none))
        self.assertIsNone(self.occurred_of(future))

    def test_impossible_dates_are_not_dates(self):
        rec = self.bare_row("The log said 2026-13-40, which is nonsense.")
        memory.cmd_backfill_occurred(self.store, Namespace(dry_run=False))
        self.assertIsNone(self.occurred_of(rec))

    def test_dry_run_writes_nothing_and_a_filled_row_is_left_alone(self):
        rec = self.bare_row("Fixed on 2026-08-02.")
        memory.cmd_backfill_occurred(self.store, Namespace(dry_run=True))
        self.assertIsNone(self.occurred_of(rec))
        memory.cmd_backfill_occurred(self.store, Namespace(dry_run=False))
        self.store.db.execute("UPDATE memories SET occurred='2026-08-01'"
                              " WHERE id=?", (rec,))
        self.store.db.commit()
        memory.cmd_backfill_occurred(self.store, Namespace(dry_run=False))
        self.assertEqual(self.occurred_of(rec), "2026-08-01")


class TestWindowChunks(unittest.TestCase):
    """memory-recall.md rule 29: ingest windows, it does not trim. The
    windows break only on whole chunk boundaries, and joined with the
    ingest separator each stays within the cap — except a single chunk
    larger than the cap, which gets a window of its own and travels whole."""

    def test_one_window_when_it_fits(self):
        chunks = ["aa", "bb", "cc"]
        self.assertEqual(memory.window_chunks(chunks, 100), [chunks])

    def test_a_long_day_becomes_several_windows_and_loses_nothing(self):
        chunks = [f"chunk {i} " + "x" * 40 for i in range(9)]
        windows = memory.window_chunks(chunks, 120)
        self.assertGreater(len(windows), 1)
        for w in windows:
            self.assertLessEqual(len("\n\n".join(w)), 120)
        # No chunk split, lost, or reordered.
        self.assertEqual(sum(windows, []), chunks)

    def test_an_oversized_single_chunk_survives_whole(self):
        big = "y" * 500
        windows = memory.window_chunks(["aa", big, "bb"], 100)
        self.assertEqual(windows, [["aa"], [big], ["bb"]])

    def test_no_chunks_no_windows(self):
        self.assertEqual(memory.window_chunks([], 100), [])


class TestIngest(StoreCase):
    def test_ingest_windows_a_long_day_instead_of_trimming(self):
        """Rule 29 through cmd_ingest itself: a day past the cap reaches the
        SUMMARISER in whole-chunk windows, in order, every pass reported —
        and the judge receives the summaries, never the raw day (rule 27)."""
        jdir = os.path.join(self.dir, "journal")
        os.makedirs(jdir)
        with open(os.path.join(jdir, "2026-08-10.jsonl"), "w") as f:
            for i in range(12):
                f.write(json.dumps(
                    {"time": f"2026-08-10T{i:02d}:00:00-0400",
                     "kind": "desktop", "user": f"turn {i} " + "x" * 60,
                     "reply": "noted"}) + "\n")
        seen, judged = [], []
        real_sum = memory.summarize_window
        real_extract = memory.extract_candidates
        memory.summarize_window = \
            lambda material, model: (seen.append(material),
                                     "a faithful summary")[1]
        memory.extract_candidates = \
            lambda material, model, prompt=None, effort=None: \
            (judged.append(material), [])[1]
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = memory.cmd_ingest(self.store, Namespace(
                    dry_run=True, from_json=None, journal_dir=jdir,
                    transcripts_dir=os.path.join(self.dir, "none"),
                    model="stub", effort="high", summary_model="stub-sum",
                    max_chars=300))
        finally:
            memory.summarize_window = real_sum
            memory.extract_candidates = real_extract
        self.assertEqual(rc, 0)
        self.assertGreater(len(seen), 1,
                           "a single pass means the cap trimmed the day")
        for material in seen:
            self.assertLessEqual(len(material), 300)
        # Joined back together, the passes are the whole day, in order.
        self.assertEqual("\n\n".join(seen),
                         "\n\n".join(memory.journal_delta(jdir, {})))
        # The judge reads the summariser's labelled summaries, and not one
        # byte of the raw day (rule 27's boundary).
        self.assertTrue(judged, "the judge was never consulted")
        self.assertIn("[day summary, window 1/", judged[0])
        for material in judged:
            self.assertIn("a faithful summary", material)
            self.assertNotIn("turn 3", material)
        report = out.getvalue()
        self.assertIn(f"in {len(seen)} passes", report)
        for i, material in enumerate(seen, 1):
            self.assertIn(f"pass {i}/{len(seen)}: {len(material)} chars",
                          report)

    def test_dry_run_writes_nothing_and_still_names_the_candidate(self):
        """Rule 41 (MAJ-33) end to end: a dry run whose distiller returns a
        REAL candidate leaves the store untouched — no record, no cursor —
        while the report still says what it would have added. Before the rule
        the flag guarded decay and the cursor only, and the add loop wrote
        every candidate into whatever store it was pointed at."""
        seeded = self.store.insert("The lux sensor lives on the i2c bus.",
                                   vec=[0.1] * memory.EMBED_DIM)
        jdir = os.path.join(self.dir, "journal")
        os.makedirs(jdir)
        with open(os.path.join(jdir, "2026-08-10.jsonl"), "w") as f:
            f.write(json.dumps(
                {"time": "2026-08-10T09:00:00-0400", "kind": "desktop",
                 "user": "the deadline moved to Friday",
                 "reply": "noted"}) + "\n")
        cands = [{"text": "The deadline moved to Friday.", "kind": "note",
                  "topics": "scheduling", "occurred": "2026-08-10"}]
        stub = os.path.join(self.dir, "claude-stub")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '"
                    + json.dumps(cands) + "'\n")
        os.chmod(stub, 0o755)
        # DESKCRAB_METRICS_DIR pinned: this file does not run under
        # tests/lib/sandbox.sh, and run_claude appends to the token ledger.
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir,
                   XDG_RUNTIME_DIR=self.dir, CLAUDE_BIN=stub,
                   DESKCRAB_METRICS_DIR=os.path.join(self.dir, "metrics"))
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "ingest", "--dry-run", "--journal-dir", jdir,
             "--transcripts-dir", os.path.join(self.dir, "none"),
             "--model", "stub", "--summary-model", "stub"],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("would add [note] (2026-08-10) "
                      "The deadline moved to Friday.", proc.stdout)
        self.assertIn("nothing written", proc.stdout)
        rows = self.store.db.execute(
            "SELECT id, text FROM memories").fetchall()
        self.assertEqual(rows, [(seeded, "The lux sensor lives on the i2c bus.")],
                         "a dry run wrote into the store")
        self.assertFalse(
            os.path.exists(os.path.join(self.dir, "ingest-cursor.json")),
            "a dry run advanced the cursor")

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

    def test_transcript_files_are_never_head_trimmed(self):
        """Rule 29's transcript half (found at the 2026-08-26 audit): the
        reader took the first `cap` characters of each file and marked the
        whole file ingested, so a long transcription's tail never existed.
        A file past the cap arrives as successive labelled parts, whole."""
        tdir = os.path.join(self.dir, "transcripts")
        os.makedirs(tdir)
        body = "".join(f"sentence {i} of the long meeting. "
                       for i in range(400))
        with open(os.path.join(tdir, "long.txt"), "w") as f:
            f.write(body)
        cursor = {}
        chunks = memory.transcript_delta(tdir, cursor, cap=1000)
        self.assertGreater(len(chunks), 1,
                           "one chunk from a file past the cap means the "
                           "tail was trimmed off")
        for i, chunk in enumerate(chunks, 1):
            self.assertIn(f"[transcript long.txt part {i}/{len(chunks)}]",
                          chunk)
        rejoined = "".join(c.split("]\n", 1)[1] for c in chunks)
        self.assertEqual(rejoined, body)  # every byte, in order
        # And the cursor still marks the file done: nothing on re-read.
        self.assertEqual(memory.transcript_delta(tdir, cursor, cap=1000), [])

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
        # model was actually shown rather than only what it answered. So are
        # the flags it was invoked with and the directory it was started in:
        # both are charged to every judgement's token bill.
        path = os.path.join(self.dir, "claude-stub")
        self.seen_prompt = os.path.join(self.dir, "judge-prompt.txt")
        self.seen_argv = os.path.join(self.dir, "judge-argv.txt")
        self.seen_cwd = os.path.join(self.dir, "judge-cwd.txt")
        with open(path, "w") as f:
            f.write(f"#!/bin/sh\nprintf '%s\\n' \"$@\" >'{self.seen_argv}'\n"
                    f"pwd >'{self.seen_cwd}'\n"
                    f"cat >'{self.seen_prompt}'\n"
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
        # DESKCRAB_METRICS_DIR pinned: this file does not run under
        # tests/lib/sandbox.sh, and the judge appends to the token ledger.
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir,
                   XDG_RUNTIME_DIR=self.dir,
                   DESKCRAB_METRICS_DIR=os.path.join(self.dir, "metrics"),
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

    def test_quoted_string_ids_still_reinforce(self):
        """Rule 25a's parser duty, the 2026-08-26 live loss: a judge
        credited real records as ["596", "15", "173"] and the digits-only
        parse called the verdict unparseable, so the credit never landed.
        Ids quoted as strings are still the verdict."""
        self.judge(f'["{self.used}"]')
        self.assertEqual(self.usage(self.used)[0], 1)
        self.assertEqual(self.usage(self.ignored), (0, None))
        with open(self.log) as f:
            log = f.read()
        self.assertIn(f"used=[{self.used}]", log)
        self.assertNotIn("unparseable", log)

    def test_hash_prefixed_ids_still_reinforce(self):
        # The other live shape of 2026-08-26 (10:32, the chess-chat record
        # itself): ["#602"] — the ids exactly as the judge's own prompt
        # labels the records it is shown.
        self.judge(f'["#{self.used}"]')
        self.assertEqual(self.usage(self.used)[0], 1)
        self.assertEqual(self.usage(self.ignored), (0, None))

    def test_lenient_parse_still_rejects_hallucinated_ids(self):
        # Leniency about shape is not leniency about provenance: a quoted id
        # from outside the sidecar still stamps nothing.
        self.judge(f'["{self.used}", "999"]', ids=[(self.used, "note")])
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

    def test_the_judge_runs_as_a_classifier_not_a_desktop(self):
        """specs/prompt-assembly.md rules 13 and 14. This judgement fires after
        every desk turn, phone turn and wake; booting the interactive profile
        for it bought 40,229 tokens of tool and skill listings to answer one
        question, on a box already running accounts dry."""
        self.judge("[]")
        with open(self.seen_argv) as f:
            argv = f.read().splitlines()
        self.assertIn("--strict-mcp-config", argv)
        # Both halves of the lever or neither: --tools without the strict MCP
        # config leaves every configured server's tools inlined.
        self.assertIn("--mcp-config", argv)
        self.assertIn("--tools", argv)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertIn("--disable-slash-commands", argv)
        with open(self.seen_cwd) as f:
            cwd = os.path.realpath(f.read().strip())
        # A sterile directory: no instruction file, no repository, nothing for
        # the CLI to read into the prompt on the way in.
        self.assertEqual(cwd, os.path.realpath(
            os.path.join(self.dir, "deskcrab-classify")))
        self.assertEqual(os.listdir(cwd), [])

    def test_an_oversize_answer_stamps_the_timing_metrics(self):
        """memory-recall.md rule 42. Measured 2026-08-15: ~4.4k output tokens
        per judgement, 830k in a day, narrating the way to a ten-byte array.
        A verbose answer must still be parsed (lenient by contract), but it
        must leave a warning in the day's timing metrics and a truncated head
        in the judge log, so the regression surfaces the day it happens."""
        essay = "Considering the records at length. " * 40
        self.judge(essay + f"[{self.used}]")
        # The verdict was not lost to the verbosity.
        self.assertEqual(self.usage(self.used)[0], 1)
        metrics = os.path.join(self.dir, "metrics",
                               datetime.now().strftime("%Y-%m-%d") + ".log")
        with open(metrics) as f:
            lines = [ln for ln in f.read().splitlines()
                     if "\tmemory-judge\toversize-answer\t" in ln]
        self.assertEqual(len(lines), 1)
        self.assertIn("B answer against a 600B ceiling", lines[0])
        with open(self.log) as f:
            log_text = f.read()
        self.assertIn("WARNING oversize answer", log_text)
        # The stored head is truncated, never the whole essay.
        self.assertNotIn(essay[:300], log_text)

    def test_a_compact_answer_stamps_nothing(self):
        self.judge(f"[{self.used}]")
        metrics = os.path.join(self.dir, "metrics",
                               datetime.now().strftime("%Y-%m-%d") + ".log")
        stamped = ""
        if os.path.exists(metrics):
            with open(metrics) as f:
                stamped = f.read()
        self.assertNotIn("oversize-answer", stamped)

    def test_the_prompt_demands_the_bare_array(self):
        """Rule 42's first duty: the model is TOLD the array is the whole
        answer and everything else is discarded unread."""
        self.judge("[]")
        with open(self.seen_prompt) as f:
            prompt = f.read()
        self.assertIn("The array IS the whole answer", prompt)
        self.assertIn("discarded unread", prompt)

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


class TestJudgeAccountWalk(StoreCase):
    """The judge walks the flat account list, and never raises into its caller.

    It had one shot at whichever login it was handed. A judgement fired at an
    account that had just gone dry lost the whole turn's reinforcement, and lost
    it silently: the caller writes a line and returns 0 by design, so the
    records that turn genuinely used carried on decaying as though they had been
    surfaced and ignored. specs/account-fallback.md rule 29 — every out-of-band
    model call selects from the same flat list.
    """

    A1 = os.path.expanduser("~/.claude")

    LIMIT_RE = ("out of usage credits|usage limit reached|session limit reached"
                "|not logged in|please run /login")

    def setUp(self):
        super().setUp()
        vec = [0.1] * memory.EMBED_DIM
        self.used = self.store.insert("His character Xena is a Paladin.", vec=vec)
        self.log = os.path.join(self.dir, "judge.log")
        self.calls = os.path.join(self.dir, "logins.txt")
        self.second = os.path.join(self.dir, "account-two")
        os.makedirs(self.second, exist_ok=True)

    def stub_claude(self, refuse):
        """A CLI that refuses for the logins named in `refuse` and answers for
        the rest, recording which login each attempt ran under. The refusal is
        the CLI's own line on its own channel with a non-zero exit, which is
        what run_claude already reports when it raises."""
        path = os.path.join(self.dir, "claude-stub")
        with open(path, "w") as f:
            f.write(
                "#!/bin/sh\n"
                "cat > /dev/null\n"
                f'printf "%s\\n" "${{CLAUDE_CONFIG_DIR:-none}}" >> "{self.calls}"\n'
                f'case "${{CLAUDE_CONFIG_DIR:-none}}" in\n'
                f'  {"|".join(refuse)})\n'
                '    echo "Claude AI usage limit reached|1754640000" >&2\n'
                "    exit 1 ;;\n"
                "esac\n"
                f'printf "%s\\n" "[{self.used}]"\n')
        os.chmod(path, 0o755)
        return path

    def judge(self, refuse, chain=None):
        ids_file = os.path.join(self.dir, "injected.json")
        with open(ids_file, "w") as f:
            json.dump([{"id": self.used, "kind": "note", "text": "t"}], f)
        # DESKCRAB_METRICS_DIR is pinned to the scratch dir: this suite does
        # not run under tests/lib/sandbox.sh, and the walk's refusal path
        # appends to the token ledger — unpinned, every refusing case here
        # wrote stub records into the LIVE ledger under ~/.local/share
        # (test-harness gate 9: a test writes no live path).
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir,
                   XDG_RUNTIME_DIR=self.dir,
                   DESKCRAB_METRICS_DIR=os.path.join(self.dir, "metrics"),
                   DESKCRAB_CLAUDE_LIMIT_RE=self.LIMIT_RE,
                   CLAUDE_FALLBACK_CONFIG_DIR=(self.second if chain is None else chain),
                   ACCOUNT_STATE_FILE=os.path.join(self.dir, "account-state"),
                   CLAUDE_BIN=self.stub_claude(refuse))
        env.pop("CLAUDE_CONFIG_DIR", None)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "judge-turn", "--ids-file", ids_file, "--user", "who do I play",
             "--reply", "Xena is your Paladin.", "--actions", "",
             "--log", self.log],
            capture_output=True, text=True, env=env)
        # The fail-safe contract at the head of the module: a judgement that
        # cannot be made is skipped, never raised.
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return ids_file

    def logins(self):
        with open(self.calls) as f:
            return [l.strip() for l in f if l.strip()]

    def usage(self, rec_id):
        return self.store.db.execute(
            "SELECT use_count, last_used_at FROM memories WHERE id=?",
            (rec_id,)).fetchone()

    def ledger_records(self):
        mdir = os.path.join(self.dir, "metrics")
        out = []
        if not os.path.isdir(mdir):
            return out
        for name in sorted(os.listdir(mdir)):
            if name.startswith("tokens-"):
                with open(os.path.join(mdir, name)) as f:
                    out.extend(json.loads(l) for l in f if l.strip())
        return out

    def test_a_refused_account_moves_to_the_next_and_the_judgement_lands(self):
        self.judge(refuse=[self.A1])
        self.assertEqual(self.logins(), [self.A1, self.second])
        # The refused boot is on the ledger — and in the PINNED scratch dir,
        # which is the write that used to land in the live one.
        self.assertIn("refused",
                      [r["status"] for r in self.ledger_records()])
        self.assertEqual(self.usage(self.used)[0], 1)
        with open(self.log) as f:
            log = f.read()
        # One line naming the account that answered, by number, so a walk
        # running itself dry is readable afterwards rather than inferred from
        # a missing judgement.
        self.assertIn("account 2 answered after 1 account(s) refused", log)
        self.assertIn(f"used=[{self.used}]", log)

    def test_every_account_refusing_skips_the_judgement_and_says_so(self):
        ids_file = self.judge(refuse=[self.A1, self.second])
        self.assertEqual(self.logins(), [self.A1, self.second])
        # Nothing reinforced on a judgement that never happened — crediting a
        # record here would teach the store that a refusal is evidence of use.
        self.assertEqual(self.usage(self.used), (0, None))
        # The sidecar still describes one turn and is still consumed.
        self.assertFalse(os.path.exists(ids_file))
        with open(self.log) as f:
            self.assertIn("every account refused (2 tried)", f.read())

    def test_a_failure_that_is_not_a_refusal_spends_no_second_account(self):
        # An authentication or network failure fails on the next account too.
        # Walking the list for it burns every login on a failure no account
        # can fix.
        path = os.path.join(self.dir, "claude-stub")
        with open(path, "w") as f:
            f.write("#!/bin/sh\ncat > /dev/null\n"
                    f'printf "%s\\n" "${{CLAUDE_CONFIG_DIR:-none}}" >> "{self.calls}"\n'
                    'echo "connect ETIMEDOUT" >&2\nexit 1\n')
        os.chmod(path, 0o755)
        ids_file = os.path.join(self.dir, "injected.json")
        with open(ids_file, "w") as f:
            json.dump([{"id": self.used, "kind": "note", "text": "t"}], f)
        env = dict(os.environ, DESKCRAB_MEMORY_DIR=self.dir,
                   XDG_RUNTIME_DIR=self.dir,
                   DESKCRAB_METRICS_DIR=os.path.join(self.dir, "metrics"),
                   DESKCRAB_CLAUDE_LIMIT_RE=self.LIMIT_RE,
                   CLAUDE_FALLBACK_CONFIG_DIR=self.second,
                   ACCOUNT_STATE_FILE=os.path.join(self.dir, "account-state"),
                   CLAUDE_BIN=path)
        env.pop("CLAUDE_CONFIG_DIR", None)
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "lib", "memory.py"),
             "judge-turn", "--ids-file", ids_file, "--user", "u",
             "--reply", "r", "--actions", "", "--log", self.log],
            capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.logins(), [self.A1])
        self.assertEqual(self.usage(self.used), (0, None))
        # The failed boot is still an attempt the ledger keeps
        # (specs/metrics.md rules 11, 13): one record, status error, zero
        # usage — in the pinned scratch dir.
        self.assertEqual([r["status"] for r in self.ledger_records()],
                         ["error"])

    def test_with_one_account_configured_nothing_changes(self):
        # One login, one attempt, the same skip as before this walk existed.
        ids_file = self.judge(refuse=[self.A1], chain="")
        self.assertEqual(self.logins(), [self.A1])
        self.assertEqual(self.usage(self.used), (0, None))
        self.assertFalse(os.path.exists(ids_file))


class TestCommitmentSurvivesTheNight(StoreCase):
    """Rule 27a, the 2026-08-25/26 regression: the user asked for the
    chess-table chat rebuilt on the phone's conversation interface, she
    assured him the work was scheduled, and the night stored his want as a
    directive while her assurance formed nothing retrievable — so the
    morning reply presented the previous night's stale work as new. A
    commitment must land as a note: embedded, retrievable, ranked first
    when its subject returns — and earning nothing from being returned
    until the judge credits it, the bedrock rule."""

    COMMITMENT = ("I assured the user that the chess-table chat would be "
                  "rebuilt on the phone's conversation interface; the day "
                  "ended with the work still owed and nothing visible "
                  "changed.")

    def write_cands(self, cands):
        path = os.path.join(self.dir, "cands.json")
        with open(path, "w") as f:
            json.dump(cands, f)
        return path

    def test_both_stage_prompts_carry_the_commitment_duty(self):
        # The summariser carries every assurance to the judge, quoted; the
        # judge is asked for the unfulfilled ones as notes — in the prompts'
        # own words, the way rule 50's harvest-wide instruction is pinned.
        self.assertIn("commitment or assurance", memory.SUMMARY_PROMPT)
        self.assertIn("QUOTED", memory.SUMMARY_PROMPT)
        self.assertIn("promised, assured, or agreed", memory.INGEST_PROMPT)
        self.assertIn("still owed", memory.INGEST_PROMPT)
        # The trap the live miss actually fell into is named: never only an
        # observation's unfinished-threads line, because the hidden kinds
        # are invisible to every prompt-facing retrieval (rule 43).
        self.assertIn("Never fold it into an observation",
                      memory.INGEST_PROMPT)

    def test_commitment_embeds_ranks_and_earns_nothing_by_return(self):
        # Through the real ingest verb (--from-json: the judge's answer with
        # the model skipped), against the real embedder: the candidate lands
        # as a note WITH a vector, is retrieved when the subject returns in
        # the user's own morning words, outranks the unrelated notes beside
        # it — and the return itself reinforces nothing.
        cands = [
            {"text": self.COMMITMENT, "kind": "note",
             "topics": "chess,phone,commitment", "occurred": "2026-08-25"},
            {"text": "The lux sensor lives on the i2c bus.", "kind": "note"},
            {"text": "The greenhouse fan relay sticks when it rains.",
             "kind": "note"},
        ]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = memory.cmd_ingest(self.store, Namespace(
                dry_run=False, from_json=self.write_cands(cands),
                journal_dir="", transcripts_dir="", model="unused",
                effort="high", summary_model="unused", max_chars=150000))
        self.assertEqual(rc, 0)
        self.assertIn("3 added", out.getvalue())
        # The coverage half of the audit: every saved record has a vector —
        # a record without one is unfindable forever.
        no_vec = self.store.db.execute(
            "SELECT count(*) FROM memories m LEFT JOIN memories_vec v"
            " ON v.rowid = m.id WHERE v.rowid IS NULL").fetchone()[0]
        self.assertEqual(no_vec, 0)
        rec_id = self.store.db.execute(
            "SELECT id FROM memories WHERE text=?",
            (self.COMMITMENT,)).fetchone()[0]
        query = ("the chess chat doesn't feel nearly as good as the mobile "
                 "interface — I thought you said you were going to improve "
                 "it, did that happen?")
        picked, _, _ = self.store.search(query)
        notes = [r for r in picked if r[2] == "note"]
        self.assertTrue(notes and notes[0][0] == rec_id,
                        "the commitment must be the top note when its "
                        "subject returns")
        # Returned is not used (the bedrock rule): no use stamp, no count,
        # no confidence movement — retrieval bumps last_seen and nothing
        # else.
        used, count, conf = self.store.db.execute(
            "SELECT last_used_at, use_count, confidence FROM memories"
            " WHERE id=?", (rec_id,)).fetchone()
        self.assertIsNone(used)
        self.assertEqual(count, 0)
        self.assertEqual(conf, 1.0)
        # Only the judge's credit moves it.
        self.store.reinforce([rec_id])
        used, count = self.store.db.execute(
            "SELECT last_used_at, use_count FROM memories WHERE id=?",
            (rec_id,)).fetchone()
        self.assertIsNotNone(used)
        self.assertEqual(count, 1)


if __name__ == "__main__":
    unittest.main()
